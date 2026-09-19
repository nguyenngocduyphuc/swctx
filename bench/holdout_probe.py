#!/usr/bin/env python3
"""holdout_probe.py — frozen holdout evaluation set for swctx.

Runs every query in bench/holdout_queries.json through ONE persistent
`swctx mcp` session (MCPSession from bench.py, same as engine_ab.py) and
measures file-level recall@5: 1 if the verified expected_path appears in
the top-5 hit paths, ranked as returned. This set is the exit-gate
holdout from docs/07-KE-HOACH-TOI-UU.md ("frozen vn_probe + holdout mới,
không dùng holdout để tune") — it must NEVER be used to tune retrieval.

Primary metric: `search` (mode=auto) recall@5 — the search-only baseline.
Secondary, clearly separated: for symbol_lookup queries the probe also
calls `find_definitions` with expected_symbol — the "search+find_defs"
baseline leg the exit gate tracks.

Pre-flight (hard): asserts every expected_path exists on disk and every
required schema key is present; queries whose expected file is missing
from the workspace's sqlite index are run but flagged verified=false.

Output: per-query table + aggregates on stdout (overall, per workspace,
lang, tag, query_intent, path_signal) and a JSON results file at
bench/holdout_results.json (--out).

Stdlib only. Usage:

    python3 bench/holdout_probe.py                       # run + write JSON
    python3 bench/holdout_probe.py --swctx-bin .build/release/swctx
    python3 bench/holdout_probe.py --limit 10 --out /tmp/h.json
    python3 bench/holdout_probe.py --gate 12             # exit 1 if ALL < N
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession  # noqa: E402  (reuse the proven stdio client)

DEFAULT_QUERIES = os.path.join(HERE, "holdout_queries.json")
DEFAULT_OUT = os.path.join(HERE, "holdout_results.json")
DEFAULT_SWCTX_BIN = os.path.join(HERE, "..", ".build", "debug", "swctx")
INDEXES_DIR = os.path.expanduser("~/.swctx/indexes")

REQUIRED_KEYS = {
    "id", "workspace", "kind", "lang", "tags",
    "query_intent", "path_signal", "query", "expected_path",
}
VALID_INTENTS = {"concept_flow", "symbol_lookup"}
VALID_PSIG = {"in_path", "in_body_only"}


def norm_path(p):
    return (p or "").strip().lstrip("./")


def rank_of(expected, paths):
    try:
        return paths.index(expected) + 1
    except ValueError:
        return 0


def pct(hits, n):
    return f"{hits}/{n} ({100.0 * hits / n:.0f}%)" if n else "0/0"


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return 0.0
    mid = len(xs) // 2
    return xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2


# ----------------------------------------------------------------------
# Spec validation + preflight
# ----------------------------------------------------------------------

def validate_spec(spec):
    """Hard schema check — same required keys as vn_queries.json."""
    assert isinstance(spec, dict) and isinstance(spec.get("queries"), list), \
        "spec must be an object with a 'queries' list"
    ids = set()
    for q in spec["queries"]:
        missing = REQUIRED_KEYS - set(q)
        assert not missing, f"{q.get('id', '?')}: missing keys {missing}"
        assert q["kind"] == "search", f"{q['id']}: kind must be 'search'"
        assert q["query_intent"] in VALID_INTENTS, \
            f"{q['id']}: bad query_intent {q['query_intent']!r}"
        assert q["path_signal"] in VALID_PSIG, \
            f"{q['id']}: bad path_signal {q['path_signal']!r}"
        assert q["id"] not in ids, f"duplicate id {q['id']}"
        ids.add(q["id"])
        if q["query_intent"] == "symbol_lookup":
            assert q.get("expected_symbol"), \
                f"{q['id']}: symbol_lookup requires expected_symbol"
    return spec["queries"]


def assert_expected_on_disk(queries):
    """Hard assert: every expected_path exists under its workspace."""
    missing = []
    for q in queries:
        q["expected_path"] = norm_path(q["expected_path"])
        if not os.path.exists(os.path.join(q["workspace"],
                                           q["expected_path"])):
            missing.append(f"{q['id']}: {q['workspace']}/"
                           f"{q['expected_path']}")
    assert not missing, "expected_path not on disk:\n  " + "\n  ".join(missing)


def ws_index_key(bin_path, workspace, timeout=60):
    """`swctx status` -> meta.key (index dir name) or None."""
    try:
        proc = subprocess.run([bin_path, "status", workspace],
                              capture_output=True, text=True, timeout=timeout)
        if proc.returncode != 0:
            return None
        return json.loads(proc.stdout).get("meta", {}).get("key")
    except Exception:
        return None


def indexed_paths(bin_path, workspace):
    """Set of paths in the workspace's index files table (or None)."""
    key = ws_index_key(bin_path, workspace)
    if not key:
        return None
    db = os.path.join(INDEXES_DIR, key, "index.db")
    if not os.path.exists(db):
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = con.execute("SELECT path FROM files").fetchall()
        con.close()
        return {norm_path(r[0]) for r in rows}
    except Exception:
        return None


def indexed_symbols(bin_path, workspace):
    """Set of symbol names in the index (or None)."""
    key = ws_index_key(bin_path, workspace)
    if not key:
        return None
    db = os.path.join(INDEXES_DIR, key, "index.db")
    if not os.path.exists(db):
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = con.execute("SELECT DISTINCT name FROM symbols").fetchall()
        con.close()
        return {r[0] for r in rows}
    except Exception:
        return None


# ----------------------------------------------------------------------
# MCP calls
# ----------------------------------------------------------------------

def start_swctx(bin_path, workspaces):
    s = MCPSession("swctx", [bin_path, "mcp"], timeout=60)
    s.start()
    if not s.tools:
        s.stop()
        raise RuntimeError("swctx mcp tools/list failed")
    for ws in workspaces:  # warm index + embedder like engine_ab does
        s.call_tool("search",
                    {"workspace": ws,
                     "query": "warmup load index and embedder",
                     "mode": "auto", "limit": 1}, retries=0, timeout=60)
    return s


def sw_search(session, ws, query, limit):
    payload, lat, err = session.call_tool(
        "search", {"workspace": ws, "query": query, "mode": "auto",
                   "limit": limit}, timeout=60)
    if err:
        return [], lat, err
    return [norm_path(h.get("path")) for h in payload.get("hits", [])], \
        lat, None


def sw_find_defs(session, ws, symbol, limit):
    payload, lat, err = session.call_tool(
        "find_definitions",
        {"workspace": ws, "symbols": [symbol], "include_content": False},
        timeout=60)
    if err:
        return [], lat, err
    paths = [norm_path(d.get("path")) for r in payload.get("results", [])
             for d in r.get("definitions", [])]
    return paths[:limit], lat, None


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Frozen holdout probe for swctx over MCP")
    ap.add_argument("--queries", default=DEFAULT_QUERIES)
    ap.add_argument("--swctx-bin", default=DEFAULT_SWCTX_BIN)
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help="JSON results path (default bench/holdout_results.json)")
    ap.add_argument("--no-find-defs", action="store_true",
                    help="skip the find_definitions leg on symbol_lookup "
                         "queries (pure search-only baseline)")
    ap.add_argument("--gate", type=int, default=None,
                    help="exit non-zero when ALL-scope search recall@5 "
                         "hits < N")
    args = ap.parse_args()

    spec = json.load(open(args.queries))
    queries = validate_spec(spec)
    assert_expected_on_disk(queries)

    workspaces = []
    for q in queries:
        if q["workspace"] not in workspaces:
            workspaces.append(q["workspace"])

    # ---- soft verification: index membership (run anyway, flag drift) ----
    idx_paths, idx_syms = {}, {}
    for ws in workspaces:
        idx_paths[ws] = indexed_paths(args.swctx_bin, ws)
        idx_syms[ws] = indexed_symbols(args.swctx_bin, ws)
    for q in queries:
        ws = q["workspace"]
        in_index = (idx_paths[ws] is None) or \
            (q["expected_path"] in idx_paths[ws])
        sym_ok = True
        if q.get("expected_symbol") and idx_syms[ws] is not None:
            sym_ok = q["expected_symbol"] in idx_syms[ws]
        q["verified"] = bool(in_index and sym_ok)
        q["verify_detail"] = {"in_index": in_index, "symbol_indexed": sym_ok}

    # ---- run the probe ----
    session = start_swctx(args.swctx_bin, workspaces)
    try:
        for i, q in enumerate(queries):
            exp = q["expected_path"]
            res = {}
            paths, lat, err = sw_search(session, q["workspace"],
                                        q["query"], args.limit)
            res["search"] = {
                "hits": paths, "rank": rank_of(exp, paths),
                "recall": int(bool(rank_of(exp, paths))),
                "latency_ms": round(lat or 0, 1),
                **({"error": err} if err else {}),
            }
            if q["query_intent"] == "symbol_lookup" and not args.no_find_defs:
                dpaths, dlat, derr = sw_find_defs(
                    session, q["workspace"], q["expected_symbol"], args.limit)
                res["find_definitions"] = {
                    "symbol": q["expected_symbol"],
                    "hits": dpaths, "rank": rank_of(exp, dpaths),
                    "recall": int(bool(rank_of(exp, dpaths))),
                    "latency_ms": round(dlat or 0, 1),
                    **({"error": derr} if derr else {}),
                }
            q["results"] = res
            fd = res.get("find_definitions", {}).get("rank")
            print(f"[{i + 1}/{len(queries)}] {q['id']} "
                  f"search={res['search']['rank'] or '-'}"
                  + (f" find_defs={fd or '-'}"
                     if "find_definitions" in res else ""),
                  file=sys.stderr)
    finally:
        session.stop()

    # ---- aggregate ----
    def recall(rows, tool="search"):
        n = len(rows)
        hits = sum(r["results"][tool]["recall"] for r in rows
                   if tool in r["results"])
        got = sum(1 for r in rows if tool in r["results"])
        return {"hits": hits, "n": got,
                "recall": round(hits / got, 4) if got else None}

    scopes = {"ALL": queries}
    for q in queries:
        scopes.setdefault(
            os.path.basename(q["workspace"].rstrip("/")), []).append(q)
    for lang in sorted({q["lang"] for q in queries}):
        scopes[f"lang={lang}"] = [q for q in queries if q["lang"] == lang]
    for tag in sorted({t for q in queries for t in q["tags"]}):
        scopes[f"tag={tag}"] = [q for q in queries if tag in q["tags"]]
    for field in ("query_intent", "path_signal"):
        for v in sorted({q.get(field) for q in queries if q.get(field)}):
            scopes[f"{field}={v}"] = \
                [q for q in queries if q.get(field) == v]

    by_scope = []
    for name, rows in scopes.items():
        row = {"scope": f"{name} (n={len(rows)})", "search": recall(rows)}
        fd_rows = [r for r in rows if "find_definitions" in r["results"]]
        if fd_rows:
            row["find_definitions"] = recall(fd_rows, "find_definitions")
        by_scope.append(row)

    lat = [q["results"]["search"]["latency_ms"] for q in queries]
    misses = [{"id": q["id"], "query": q["query"],
               "expected_path": q["expected_path"],
               "tags": q["tags"], "path_signal": q["path_signal"]}
              for q in queries if not q["results"]["search"]["rank"]]

    data = {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "swctx_bin": os.path.abspath(args.swctx_bin),
        "queries_file": os.path.abspath(args.queries),
        "limit": args.limit,
        "holdout": True,
        "note": "frozen holdout — do NOT tune on these numbers",
        "workspaces": spec.get("workspaces", {}),
        "aggregate": {
            "by_scope": by_scope,
            "search_recall_at_%d" % args.limit: recall(queries),
            "search_latency_ms_median": round(median(lat), 1),
            "search_misses": misses,
        },
        "queries": [{
            "id": q["id"], "workspace": q["workspace"], "lang": q["lang"],
            "tags": q["tags"], "target_type": q.get("target_type"),
            "query_intent": q["query_intent"], "path_signal": q["path_signal"],
            "query": q["query"], "expected_path": q["expected_path"],
            **({"expected_symbol": q["expected_symbol"]}
               if q.get("expected_symbol") else {}),
            "verified": q["verified"], "verify_detail": q["verify_detail"],
            "results": q["results"],
        } for q in queries],
    }

    if args.out:
        with open(args.out, "w") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
        print(f"wrote {args.out}", file=sys.stderr)

    # ---- stdout report ----
    print(f"{'id':9} {'lang':4} {'tags':16} {'intent':14} {'psig':12} "
          f"{'search':>6} {'fdefs':>6}  expected")
    for q in queries:
        fd = q["results"].get("find_definitions", {})
        flag = "" if q["verified"] else " *UNVERIFIED*"
        print(f"{q['id']:9} {q['lang']:4} {','.join(q['tags']):16} "
              f"{q['query_intent']:14} {q['path_signal']:12} "
              f"{q['results']['search']['rank'] or '-':>6} "
              f"{(fd.get('rank') or '-') if fd else '-':>6}  "
              f"{q['expected_path']}{flag}")
    print()
    print(f"recall@{args.limit} by scope (search leg):")
    for row in by_scope:
        s = row["search"]
        line = f"  {row['scope']:34} {pct(s['hits'], s['n'])}"
        if "find_definitions" in row:
            f = row["find_definitions"]
            line += f"   find_defs {pct(f['hits'], f['n'])}"
        print(line)
    print(f"\nmedian search latency {data['aggregate']['search_latency_ms_median']} ms")

    if args.gate is not None:
        allhits = recall(queries)["hits"]
        if allhits < args.gate:
            print(f"GATE FAIL: ALL recall {allhits} < {args.gate}",
                  file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
