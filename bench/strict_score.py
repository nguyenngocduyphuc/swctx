#!/usr/bin/env python3
"""strict_score.py — strict per-leg retrieval metrics for the 22-query VN benchmark.

Replaces the union-binary headline (a hit at rank 9 counted the same as
rank 1) with rank-aware metrics per leg:

  search      `swctx search <ws> <q> --mode auto --limit 20`  (deterministic)
  answer      `swctx answer --workspace <ws> --query <q>`     (deterministic, no --plan)
  find_defs   MCP find_definitions for symbol_lookup queries  (deterministic)
  union       best rank across legs

Metrics per leg: Recall@1, Recall@5, Recall@10, MRR, median/p95 latency.
A rank beyond the window is recorded as 0 (miss) — no partial credit.

Stdlib only. Usage:

    python3 bench/strict_score.py                      # run + write JSON
    python3 bench/strict_score.py --swctx-bin .build/debug/swctx
    python3 bench/strict_score.py --limit 5 --out /tmp/s.json
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession  # noqa: E402

DEFAULT_QUERIES = os.path.join(HERE, "vn_queries.json")
DEFAULT_OUT = os.path.join(HERE, "strict_results.json")
DEFAULT_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")
SEARCH_WINDOW = 20


def norm_path(p):
    return (p or "").strip().lstrip("./")


def rank_of(expected, paths):
    try:
        return paths.index(norm_path(expected)) + 1
    except ValueError:
        return 0


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return 0.0
    mid = len(xs) // 2
    return xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2


def p95(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return 0.0
    return xs[min(len(xs) - 1, int(0.95 * len(xs)))]


def run_json(argv, timeout):
    t0 = time.monotonic()
    proc = subprocess.run(argv, capture_output=True, text=True,
                          timeout=timeout)
    lat = (time.monotonic() - t0) * 1000.0
    if proc.returncode != 0:
        return None, lat, proc.stderr[:200]
    try:
        return json.loads(proc.stdout), lat, None
    except ValueError:
        return None, lat, proc.stdout[:200]


def leg_search(bin_path, ws, query):
    payload, lat, err = run_json(
        [bin_path, "search", ws, query, "--mode", "auto",
         "--limit", str(SEARCH_WINDOW)], timeout=90)
    if err:
        return 0, lat, err
    return [norm_path(h.get("path")) for h in payload.get("hits", [])], lat, None


def leg_answer(bin_path, ws, query):
    payload, lat, err = run_json(
        [bin_path, "answer", "--workspace", ws, "--query", query,
         "--format", "json"], timeout=180)
    if err:
        return 0, lat, err
    return [norm_path(e.get("path")) for e in payload.get("evidence", [])], \
        lat, None


def leg_find_defs(sess, ws, symbol):
    """MCP find_definitions; return list of definition paths."""
    resp = sess.request("tools/call", {
        "name": "find_definitions",
        "arguments": {"workspace": ws, "symbols": [symbol],
                      "include_content": False},
    })
    if not resp or "result" not in resp:
        return []
    result = resp["result"]
    # MCP result content is a JSON text blob
    for item in result.get("content", []):
        if item.get("type") == "text":
            try:
                body = json.loads(item["text"])
            except ValueError:
                continue
            paths = []
            for r in body.get("results", []):
                for d in r.get("definitions", []):
                    paths.append(norm_path(d.get("path")))
            return paths
    return []


def metrics(ranks):
    n = len(ranks)
    rec = lambda k: sum(1 for r in ranks if 0 < r <= k)
    mrr = sum(1.0 / r for r in ranks if r > 0) / n if n else 0.0
    return {"n": n, "recall@1": rec(1), "recall@5": rec(5),
            "recall@10": rec(10), "mrr": round(mrr, 4)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queries", default=DEFAULT_QUERIES)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--swctx-bin", default=DEFAULT_BIN)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    spec = json.load(open(args.queries))
    queries = spec["queries"][:args.limit or None]

    sess = MCPSession("swctx", [args.swctx_bin, "mcp"], timeout=60)
    sess.start()

    rows = []
    for q in queries:
        ws, query, gold = q["workspace"], q["query"], q["expected_path"]
        row = {"id": q["id"], "gold": gold,
               "query_intent": q["query_intent"],
               "path_signal": q["path_signal"], "lang": q["lang"]}

        paths, lat, err = leg_search(args.swctx_bin, ws, query)
        row["search_rank"] = rank_of(gold, paths) if not err else 0
        row["search_ms"] = round(lat, 1)
        if err:
            row["search_err"] = err

        paths, lat, err = leg_answer(args.swctx_bin, ws, query)
        row["answer_rank"] = rank_of(gold, paths) if not err else 0
        row["answer_ms"] = round(lat, 1)
        if err:
            row["answer_err"] = err

        if q["query_intent"] == "symbol_lookup" and q.get("expected_symbol"):
            t0 = time.monotonic()
            paths = leg_find_defs(sess, ws, q["expected_symbol"])
            row["find_defs_rank"] = rank_of(gold, paths)
            row["find_defs_ms"] = round((time.monotonic() - t0) * 1000, 1)

        row["union_rank"] = min(
            (r for r in (row["search_rank"], row["answer_rank"],
                         row.get("find_defs_rank", 0)) if r > 0),
            default=0)
        rows.append(row)
        print(f"{row['id']:8s} s={row['search_rank']:2d} "
              f"a={row['answer_rank']:2d} "
              f"fd={row.get('find_defs_rank', '-')} "
              f"u={row['union_rank']:2d} "
              f"({row['search_ms']:.0f}ms/{row['answer_ms']:.0f}ms)")

    sess.stop()

    def agg(key):
        return metrics([r.get(key, 0) for r in rows])

    report = {
        "created": datetime.now(timezone.utc).isoformat(),
        "queries_file": os.path.basename(args.queries),
        "search_window": SEARCH_WINDOW,
        "legs": {
            "search": agg("search_rank"),
            "answer": agg("answer_rank"),
            "find_defs": metrics([r["find_defs_rank"] for r in rows
                                  if "find_defs_rank" in r]),
            "union": agg("union_rank"),
        },
        "latency_ms": {
            "search": {"median": round(median([r["search_ms"] for r in rows]), 1),
                       "p95": round(p95([r["search_ms"] for r in rows]), 1)},
            "answer": {"median": round(median([r["answer_ms"] for r in rows]), 1),
                       "p95": round(p95([r["answer_ms"] for r in rows]), 1)},
        },
        "results": rows,
    }
    json.dump(report, open(args.out, "w"), ensure_ascii=False, indent=1)
    print("\n== strict metrics ==")
    for leg, m in report["legs"].items():
        print(f"{leg:10s} n={m['n']:2d} R@1={m['recall@1']:2d} "
              f"R@5={m['recall@5']:2d} R@10={m['recall@10']:2d} MRR={m['mrr']}")
    print(f"search median {report['latency_ms']['search']['median']}ms "
          f"p95 {report['latency_ms']['search']['p95']}ms · "
          f"answer median {report['latency_ms']['answer']['median']}ms "
          f"p95 {report['latency_ms']['answer']['p95']}ms")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
