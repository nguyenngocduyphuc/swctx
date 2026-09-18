#!/usr/bin/env python3
"""rerank_eval.py — cross-encoder rerank spike evaluation for swctx.

For every query in bench/vn_queries.json runs:
  baseline : swctx search <ws> <q> --mode auto --limit 5   (hybrid as-is)
  rerank   : swctx rerank <ws> <q> --limit 30             (pool of 30,
             rescored; file-level top-5 taken after rerank)

Metric: file-level recall@5 — expected_path appearing in the first 5
distinct hit paths (rank = position of first matching path).

Per query recorded: baseline rank, rerank rank, whether/where the
expected file sat in the 30-candidate pool (its best hybrid_rank —
"pool ceiling"), rerank latency (total ms + ms/pair), and CLI wall time.

    python3 bench/rerank_eval.py                  # table on stdout
    python3 bench/rerank_eval.py --json           # machine-readable
    python3 bench/rerank_eval.py --out file.json  # also save raw data
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_QUERIES = os.path.join(HERE, "vn_queries.json")
DEFAULT_SWCTX_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")


def norm_path(p):
    return (p or "").strip().lstrip("./")


def run_cli(argv, timeout=180):
    t0 = time.monotonic()
    try:
        proc = subprocess.run(argv, capture_output=True, text=True,
                              timeout=timeout)
    except Exception as e:
        return None, (time.monotonic() - t0) * 1000, f"spawn/run error: {e}"
    ms = (time.monotonic() - t0) * 1000
    if proc.returncode != 0:
        return None, ms, f"exit {proc.returncode}: {proc.stderr[:300]}"
    try:
        return json.loads(proc.stdout), ms, None
    except ValueError:
        return None, ms, f"non-JSON output: {proc.stdout[:200]}"


def path_rank(expected, hits):
    """1-based rank of `expected` among distinct hit paths."""
    seen = []
    for h in hits:
        p = norm_path(h.get("path"))
        if p not in seen:
            seen.append(p)
    try:
        return seen.index(expected) + 1
    except ValueError:
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queries", default=DEFAULT_QUERIES)
    ap.add_argument("--swctx-bin", default=DEFAULT_SWCTX_BIN)
    ap.add_argument("--limit", type=int, default=5,
                    help="baseline search limit / recall cutoff")
    ap.add_argument("--pool", type=int, default=30,
                    help="rerank candidate pool size")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--out")
    args = ap.parse_args()

    spec = json.load(open(args.queries))
    queries = spec["queries"]

    rows = []
    for i, r in enumerate(queries):
        exp = norm_path(r["expected_path"])
        ws, q = r["workspace"], r["query"]

        base, base_ms, base_err = run_cli(
            [args.swctx_bin, "search", ws, q,
             "--mode", "auto", "--limit", str(args.limit)])
        rr, rr_ms, rr_err = run_cli(
            [args.swctx_bin, "rerank", ws, q,
             "--limit", str(args.pool)])

        base_hits = (base or {}).get("hits", [])
        rr_hits = (rr or {}).get("hits", [])
        base_rank = path_rank(exp, base_hits)
        rr_rank = path_rank(exp, rr_hits)
        # Pool ceiling: best fused rank the expected file reached inside
        # the candidate pool (0 = absent → rerank could not rescue it).
        pool_ranks = [h["hybrid_rank"] for h in rr_hits
                      if norm_path(h.get("path")) == exp
                      and "hybrid_rank" in h]
        pool_rank = min(pool_ranks) if pool_ranks else 0

        rows.append({
            "id": r["id"], "lang": r["lang"], "tags": r.get("tags", []),
            "query": q, "expected_path": exp,
            "base_rank": base_rank, "rerank_rank": rr_rank,
            "pool_rank": pool_rank, "pool": (rr or {}).get("pool", 0),
            "rerank_ms": (rr or {}).get("rerank_ms"),
            "ms_per_pair": (rr or {}).get("ms_per_pair"),
            "cli_ms": rr_ms,
            # ordered hit lists for offline strategy simulation
            "base_paths": [norm_path(h.get("path")) for h in base_hits],
            "rerank_hits": [{"path": norm_path(h.get("path")),
                             "hybrid_rank": h.get("hybrid_rank"),
                             "score": h.get("score")}
                            for h in rr_hits],
            **({"base_err": base_err} if base_err else {}),
            **({"rerank_err": rr_err} if rr_err else {}),
        })
        print(f"[{i + 1}/{len(queries)}] {r['id']} "
              f"base={base_rank or '-'} rerank={rr_rank or '-'} "
              f"pool={pool_rank or '-'} "
              f"({(rr or {}).get('ms_per_pair', 0):.1f}ms/pair)"
              + (f"  ERR {base_err or rr_err}" if (base_err or rr_err) else ""),
              file=sys.stderr)

    n = len(rows)
    base_hit = sum(1 for r in rows if 0 < r["base_rank"] <= args.limit)
    rr_hit = sum(1 for r in rows if 0 < r["rerank_rank"] <= args.limit)
    in_pool = sum(1 for r in rows if r["pool_rank"])
    vi = [r for r in rows if r["lang"] == "vi"]
    en = [r for r in rows if r["lang"] == "en"]
    gained = [r["id"] for r in rows
              if 0 < r["rerank_rank"] <= args.limit
              and not 0 < r["base_rank"] <= args.limit]
    lost = [r["id"] for r in rows
            if 0 < r["base_rank"] <= args.limit
            and not 0 < r["rerank_rank"] <= args.limit]
    lat = sorted(r["ms_per_pair"] for r in rows if r["ms_per_pair"])
    lat5 = sorted(r["rerank_ms"] for r in rows if r["rerank_ms"])

    agg = {
        "n": n,
        "base_recall": (base_hit, n, round(base_hit / n, 4)),
        "rerank_recall": (rr_hit, n, round(rr_hit / n, 4)),
        "vi_base": (sum(1 for r in vi if 0 < r["base_rank"] <= args.limit),
                    len(vi)),
        "vi_rerank": (sum(1 for r in vi if 0 < r["rerank_rank"] <= args.limit),
                      len(vi)),
        "en_base": (sum(1 for r in en if 0 < r["base_rank"] <= args.limit),
                    len(en)),
        "en_rerank": (sum(1 for r in en if 0 < r["rerank_rank"] <= args.limit),
                      len(en)),
        "pool_coverage": (in_pool, n),
        "gained": gained, "lost": lost,
        "ms_per_pair_p50": lat[len(lat) // 2] if lat else None,
        "ms_per_pair_p95": lat[int(len(lat) * .95)] if lat else None,
        "rerank_ms_p50": lat5[len(lat5) // 2] if lat5 else None,
        "rerank_ms_p95": lat5[int(len(lat5) * .95)] if lat5 else None,
    }

    if args.json:
        print(json.dumps({"queries": rows, "aggregate": agg},
                         indent=1, ensure_ascii=False))
    else:
        print(f"\n{'id':8} {'base':>4} {'rerank':>6} {'pool':>5} "
              f"{'ms/pair':>8}  expected")
        for r in rows:
            print(f"{r['id']:8} {r['base_rank'] or '-':>4} "
                  f"{r['rerank_rank'] or '-':>6} {r['pool_rank'] or '-':>5} "
                  f"{(r['ms_per_pair'] or 0):>8.1f}  {r['expected_path']}")
        print(f"\nrecall@{args.limit}: baseline {base_hit}/{n} "
              f"({100 * base_hit / n:.0f}%)  rerank {rr_hit}/{n} "
              f"({100 * rr_hit / n:.0f}%)   delta {rr_hit - base_hit:+d}")
        print(f"  vi: {agg['vi_base'][0]}/{agg['vi_base'][1]} → "
              f"{agg['vi_rerank'][0]}/{agg['vi_rerank'][1]}   "
              f"en: {agg['en_base'][0]}/{agg['en_base'][1]} → "
              f"{agg['en_rerank'][0]}/{agg['en_rerank'][1]}")
        print(f"  pool coverage (expected file inside top-{args.pool} "
              f"candidates): {in_pool}/{n}")
        print(f"  gained: {gained or 'none'}   lost: {lost or 'none'}")
        if lat:
            print(f"  rerank latency: {agg['ms_per_pair_p50']:.1f}ms/pair p50 "
                  f"({agg['ms_per_pair_p95']:.1f} p95); "
                  f"total {agg['rerank_ms_p50']:.0f}ms p50 "
                  f"({agg['rerank_ms_p95']:.0f} p95)")

    if args.out:
        with open(args.out, "w") as f:
            json.dump({"queries": rows, "aggregate": agg}, f,
                      indent=1, ensure_ascii=False)
        print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
