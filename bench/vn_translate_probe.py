#!/usr/bin/env python3
"""vn_translate_probe.py — paired ablation for the W11 vn->en translation leg.

Runs every query in bench/vn_queries.json through `search` (mode=auto,
limit=5) over MCP stdio on ONE swctx binary, twice:

  * baseline arm — server spawned with SWCTX_TRANSLATE=0 (leg disabled);
  * translation arm — default env; the leg fires on diacritic-carrying
    queries only. Pass 1 runs all queries cold (the ~800ms result deadline
    usually ships baseline while Ollama still generates — the leg then
    fills ~/.swctx/translate_cache.json in the background); pass 2 reruns
    them warm against the filled cache. The cache file is deleted before
    the arm unless --keep-cache, so cold means cold.

Metrics: recall@5 on expected_path per arm (per-query table + totals +
per-query regression list) and latency p50/p95 split — baseline arm vs
translation arm, and cold-vs-warm inside the translation arm.

The default binary is the DEBUG build (.build/debug/swctx) — fine for a
probe; absolute latencies are not release numbers. With Ollama down the
probe still runs and verifies graceful degradation (arms identical); with
Ollama up it measures the real rescue. Stdlib only.

    python3 bench/vn_translate_probe.py
    python3 bench/vn_translate_probe.py --swctx-bin .build/release/swctx
    python3 bench/vn_translate_probe.py --keep-cache --json
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession  # noqa: E402  (main-guarded; no import side effects)

DEFAULT_QUERIES = os.path.join(HERE, "vn_queries.json")
DEFAULT_SWCTX_BIN = os.path.join(HERE, "..", ".build", "debug", "swctx")
CACHE_FILE = os.path.expanduser("~/.swctx/translate_cache.json")


def norm_path(p):
    return (p or "").strip().lstrip("./")


def rank_of(expected, paths):
    try:
        return paths.index(expected) + 1
    except ValueError:
        return 0


def pctile(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return 0.0
    k = max(0, min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1)))))
    return xs[k]


def ollama_status():
    """(binary_on_path, daemon_reachable, model_present)."""
    if not shutil.which("ollama"):
        return (False, False, False)
    try:
        proc = subprocess.run(["ollama", "list"], capture_output=True,
                              text=True, timeout=10)
        if proc.returncode != 0:
            return (True, False, False)
        return (True, True, "qwen2.5:3b" in proc.stdout)
    except Exception:
        return (True, False, False)


def search_paths(session, workspace, query, limit):
    payload, latency, err = session.call_tool(
        "search", {"workspace": workspace, "query": query,
                   "mode": "auto", "limit": limit},
        retries=0, timeout=60)
    if err:
        return [], latency, err
    return [norm_path(h.get("path")) for h in payload.get("hits", [])], latency, None


def main():
    ap = argparse.ArgumentParser(description="W11 vn->en translation leg ablation")
    ap.add_argument("--queries", default=DEFAULT_QUERIES)
    ap.add_argument("--swctx-bin", default=DEFAULT_SWCTX_BIN)
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--keep-cache", action="store_true",
                    help="do not delete ~/.swctx/translate_cache.json first")
    ap.add_argument("--xlate-env", action="append", default=[],
                    metavar="K=V", help="extra env for the translation-arm "
                    "server (e.g. SWCTX_OLLAMA=/nonexistent simulates absent)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    spec = json.load(open(args.queries))
    queries = spec["queries"]
    binpath = os.path.abspath(args.swctx_bin)
    build_kind = "debug" if "/debug/" in binpath else (
        "release" if "/release/" in binpath else "custom")
    obin, daemon, model = ollama_status()
    print(f"swctx bin: {binpath} ({build_kind} build — "
          f"{'OK for probe, not release latency' if build_kind == 'debug' else 'release numbers'})",
          file=sys.stderr)
    print(f"ollama: bin={'yes' if obin else 'NO'} "
          f"daemon={'up' if daemon else 'DOWN'} "
          f"qwen2.5:3b={'present' if model else 'MISSING'}",
          file=sys.stderr)
    if not (obin and daemon and model):
        print("  -> translation leg will degrade to baseline; recall delta "
              "expected ~0 (graceful-degradation check)", file=sys.stderr)

    if not args.keep_cache:
        for suffix in ("", "-shm", "-wal"):
            try:
                os.remove(CACHE_FILE + suffix)
            except FileNotFoundError:
                pass
        print("cleared translate cache for cold measurement", file=sys.stderr)

    # Baseline arm: leg disabled via env on the spawned server process.
    saved = os.environ.get("SWCTX_TRANSLATE")
    os.environ["SWCTX_TRANSLATE"] = "0"
    base = MCPSession("swctx-base", [binpath, "mcp"], timeout=120)
    base.start()
    if saved is None:
        del os.environ["SWCTX_TRANSLATE"]
    else:
        os.environ["SWCTX_TRANSLATE"] = saved
    xlate_env = {}
    for kv in args.xlate_env:
        k, _, v = kv.partition("=")
        xlate_env[k] = v
    saved_x = {k: os.environ.get(k) for k in xlate_env}
    os.environ.update(xlate_env)
    xlate = MCPSession("swctx-xlate", [binpath, "mcp"], timeout=120)
    xlate.start()
    for k, v in saved_x.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    if xlate_env:
        print(f"xlate-arm env overrides: {xlate_env}", file=sys.stderr)

    try:
        # Pass 1: baseline + cold translation call per query. The result
        # deadline (~800ms) means a slow Ollama generation ships baseline
        # hits, but the subprocess still finishes and fills the cache —
        # pass 2 (seconds later) measures the cache-warm leg.
        for i, r in enumerate(queries):
            q, ws = r["query"], r["workspace"]
            exp = norm_path(r.get("expected_path"))
            r["expected_path"] = exp

            bpaths, blat, berr = search_paths(base, ws, q, args.limit)
            cpaths, clat, cerr = search_paths(xlate, ws, q, args.limit)
            r["base"] = {"rank": rank_of(exp, bpaths),
                         "latency_ms": round(blat or 0, 1),
                         **({"error": berr} if berr else {})}
            r["xlate"] = {"rank": rank_of(exp, cpaths),
                          "latency_cold_ms": round(clat or 0, 1),
                          **({"error": cerr} if cerr else {})}
            print(f"[{i + 1}/{len(queries)} cold] {r['id']} "
                  f"base={r['base']['rank'] or '-'} "
                  f"xlate={r['xlate']['rank'] or '-'} "
                  f"({r['xlate']['latency_cold_ms']:.0f}ms)", file=sys.stderr)
        for i, r in enumerate(queries):
            wpaths, wlat, werr = search_paths(
                xlate, r["workspace"], r["query"], args.limit)
            r["xlate"]["warm_rank"] = rank_of(r["expected_path"], wpaths)
            r["xlate"]["latency_warm_ms"] = round(wlat or 0, 1)
            if werr:
                r["xlate"]["error"] = werr
            print(f"[{i + 1}/{len(queries)} warm] {r['id']} "
                  f"xlate={r['xlate']['warm_rank'] or '-'} "
                  f"({r['xlate']['latency_warm_ms']:.0f}ms)", file=sys.stderr)
    finally:
        base.stop()
        xlate.stop()

    n = len(queries)
    b_hit = sum(1 for r in queries if r["base"]["rank"])
    xc_hit = sum(1 for r in queries if r["xlate"]["rank"])
    xw_hit = sum(1 for r in queries if r["xlate"].get("warm_rank"))
    vi = [r for r in queries if r.get("lang") == "vi"]
    v2e = [r for r in vi if "vn_to_en" in r.get("tags", [])]
    b_hit_vi = sum(1 for r in vi if r["base"]["rank"])
    xc_hit_vi = sum(1 for r in vi if r["xlate"]["rank"])
    xw_hit_vi = sum(1 for r in vi if r["xlate"].get("warm_rank"))
    b_hit_v2e = sum(1 for r in v2e if r["base"]["rank"])
    xc_hit_v2e = sum(1 for r in v2e if r["xlate"]["rank"])
    xw_hit_v2e = sum(1 for r in v2e if r["xlate"].get("warm_rank"))
    improved = [r for r in queries
                if not r["base"]["rank"] and r["xlate"].get("warm_rank")]
    # A regression is a baseline hit that disappears — check both arms
    # separately: a warm-only miss still counts (the steady-state leg
    # pushed the target out), same for a cold-only miss.
    regressed = [r for r in queries
                 if r["base"]["rank"] and (not r["xlate"]["rank"]
                                           or not r["xlate"].get("warm_rank"))]
    rank_shift = [r for r in queries
                  if r["base"]["rank"] and r["xlate"].get("warm_rank")
                  and r["base"]["rank"] != r["xlate"]["warm_rank"]]

    lat_all_base = [r["base"]["latency_ms"] for r in queries]
    lat_x_cold = [r["xlate"]["latency_cold_ms"] for r in queries]
    lat_x_warm = [r["xlate"]["latency_warm_ms"] for r in queries]
    lat_vi_base = [r["base"]["latency_ms"] for r in vi]
    lat_vi_cold = [r["xlate"]["latency_cold_ms"] for r in vi]
    lat_vi_warm = [r["xlate"]["latency_warm_ms"] for r in vi]

    summary = {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "swctx_bin": binpath, "build": build_kind, "limit": args.limit,
        "ollama": {"bin": obin, "daemon": daemon, "qwen2.5:3b": model},
        "recall": {
            "all": {"base": b_hit, "xlate_cold": xc_hit,
                    "xlate_warm": xw_hit, "n": n},
            "lang=vi": {"base": b_hit_vi, "xlate_cold": xc_hit_vi,
                        "xlate_warm": xw_hit_vi, "n": len(vi)},
            "tag=vn_to_en": {"base": b_hit_v2e, "xlate_cold": xc_hit_v2e,
                             "xlate_warm": xw_hit_v2e, "n": len(v2e)},
        },
        "improved": [r["id"] for r in improved],
        "regressed": [r["id"] for r in regressed],
        "rank_shifted": [
            {"id": r["id"], "base": r["base"]["rank"],
             "xlate": r["xlate"]["warm_rank"]} for r in rank_shift],
        "latency_ms": {
            "base_all": {"p50": pctile(lat_all_base, 50),
                         "p95": pctile(lat_all_base, 95)},
            "xlate_all_cold": {"p50": pctile(lat_x_cold, 50),
                               "p95": pctile(lat_x_cold, 95)},
            "xlate_all_warm": {"p50": pctile(lat_x_warm, 50),
                               "p95": pctile(lat_x_warm, 95)},
            "base_vi": {"p50": pctile(lat_vi_base, 50),
                        "p95": pctile(lat_vi_base, 95)},
            "xlate_vi_cold": {"p50": pctile(lat_vi_cold, 50),
                              "p95": pctile(lat_vi_cold, 95)},
            "xlate_vi_warm": {"p50": pctile(lat_vi_warm, 50),
                              "p95": pctile(lat_vi_warm, 95)},
        },
    }

    if args.json:
        print(json.dumps({"summary": summary, "queries": queries},
                         indent=1, ensure_ascii=False))
        return

    print(f"\n{'id':8} {'base':>4} {'xcold':>5} {'xwarm':>5} {'cold_ms':>8} {'warm_ms':>8}  expected")
    for r in queries:
        print(f"{r['id']:8} {r['base']['rank'] or '-':>4} "
              f"{r['xlate']['rank'] or '-':>5} "
              f"{r['xlate'].get('warm_rank') or '-':>5} "
              f"{r['xlate']['latency_cold_ms']:>8.0f} "
              f"{r['xlate'].get('latency_warm_ms', 0):>8.0f}  {r['expected_path']}")
    print(f"\nrecall@{args.limit}  ALL base {b_hit}/{n} | xlate-cold {xc_hit}/{n} "
          f"| xlate-warm {xw_hit}/{n}")
    print(f"               vi  base {b_hit_vi}/{len(vi)} | xlate-cold {xc_hit_vi}/{len(vi)} "
          f"| xlate-warm {xw_hit_vi}/{len(vi)}")
    print(f"          vn_to_en  base {b_hit_v2e}/{len(v2e)} | xlate-cold {xc_hit_v2e}/{len(v2e)} "
          f"| xlate-warm {xw_hit_v2e}/{len(v2e)}")
    print(f"rescued(warm): {[r['id'] for r in improved] or 'none'}   "
          f"regressed: {[(r['id'], r['base']['rank'], r['xlate']['rank'], r['xlate'].get('warm_rank')) for r in regressed] or 'none'}   "
          f"rank-shifted: {[(r['id'], r['base']['rank'], r['xlate']['warm_rank']) for r in rank_shift] or 'none'}")
    lm = summary["latency_ms"]
    print(f"latency p50/p95 ms — base(all): {lm['base_all']['p50']:.0f}/"
          f"{lm['base_all']['p95']:.0f}   xlate(all) cold: "
          f"{lm['xlate_all_cold']['p50']:.0f}/{lm['xlate_all_cold']['p95']:.0f} "
          f"warm: {lm['xlate_all_warm']['p50']:.0f}/{lm['xlate_all_warm']['p95']:.0f}")
    print(f"latency p50/p95 ms — base(vi): {lm['base_vi']['p50']:.0f}/"
          f"{lm['base_vi']['p95']:.0f}   xlate(vi) cold: "
          f"{lm['xlate_vi_cold']['p50']:.0f}/{lm['xlate_vi_cold']['p95']:.0f} "
          f"warm: {lm['xlate_vi_warm']['p50']:.0f}/{lm['xlate_vi_warm']['p95']:.0f}")
    print(f"cache file: {CACHE_FILE} "
          f"({'exists, ' + str(os.path.getsize(CACHE_FILE)) + 'B' if os.path.exists(CACHE_FILE) else 'absent'})")


if __name__ == "__main__":
    main()
