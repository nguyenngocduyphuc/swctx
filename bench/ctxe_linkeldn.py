#!/usr/bin/env python3
"""ctxe_linkeldn.py — ctxe leg of the pre-registered 21.linkeldn paired holdout.

For each of the 25 frozen queries:
  - `ask_context` effort=min compose=false  → extract evidence file paths in
    answer text order, rank the gold path (ctxe's only NL retrieval surface;
    read-only tools need exact symbols/paths)
  - `find_definitions` (free leg) for symbol_lookup queries with
    expected_symbol

Same scoring contract as strict_score.py: rank 0 = gold absent from window.

    python3 bench/ctxe_linkeldn.py --out bench/linkeldn_ctxe_results.json
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession  # noqa: E402

PATH_RE = re.compile(r"((?:[\w\-.]+/)*[\w\-.]+\.(?:swift|py|md|json|ya?ml|toml|sh|txt|ts|js))(?::\d+(?:-\d+)?)?")


def norm_path(p):
    return (p or "").strip().lstrip("./")


def rank_of(expected, paths):
    try:
        return paths.index(norm_path(expected)) + 1
    except ValueError:
        return 0


def extract_paths(text):
    seen, out = set(), []
    for m in PATH_RE.finditer(text or ""):
        p = norm_path(m.group(1))
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queries", default=os.path.join(HERE, "linkeldn_holdout.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "linkeldn_ctxe_results.json"))
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    queries = json.load(open(args.queries))["queries"][:args.limit or None]
    sess = MCPSession("ctxe", ["ctxe", "mcp"], timeout=600)
    sess.start()

    rows = []
    for q in queries:
        ws, query, gold = q["workspace"], q["query"], q["expected_path"]
        row = {"id": q["id"], "gold": gold,
               "query_intent": q["query_intent"],
               "path_signal": q["path_signal"], "lang": q["lang"]}

        t0 = time.monotonic()
        resp = sess.request("tools/call", {
            "name": "ask_context",
            "arguments": {"workspace": ws, "query": query,
                          "effort": "min", "compose": False},
        }, timeout=540)
        lat = (time.monotonic() - t0) * 1000.0
        row["ask_ms"] = round(lat, 1)

        text = ""
        if resp and "result" in resp:
            text = "".join(i.get("text", "")
                           for i in resp["result"].get("content", [])
                           if i.get("type") == "text")
        row["ask_paths"] = extract_paths(text)
        row["ask_rank"] = rank_of(gold, row["ask_paths"])

        if q["query_intent"] == "symbol_lookup" and q.get("expected_symbol"):
            t0 = time.monotonic()
            resp = sess.request("tools/call", {
                "name": "find_definitions",
                "arguments": {"workspace": ws,
                              "symbols": [q["expected_symbol"]],
                              "include_content": False},
            }, timeout=60)
            row["find_defs_ms"] = round((time.monotonic() - t0) * 1000, 1)
            fd_paths = []
            if resp and "result" in resp:
                ftxt = "".join(i.get("text", "")
                               for i in resp["result"].get("content", [])
                               if i.get("type") == "text")
                try:
                    body = json.loads(ftxt)
                    for r in body.get("results", []):
                        for d in r.get("definitions", []):
                            fd_paths.append(norm_path(d.get("path")))
                except ValueError:
                    fd_paths = extract_paths(ftxt)
            row["find_defs_rank"] = rank_of(gold, fd_paths)

        row["union_rank"] = min(
            (r for r in (row["ask_rank"], row.get("find_defs_rank", 0))
             if r > 0), default=0)
        rows.append(row)
        print(f"{row['id']:8s} ask={row['ask_rank']:2d} "
              f"fd={row.get('find_defs_rank', '-')} u={row['union_rank']:2d} "
              f"({row['ask_ms']:.0f}ms)", flush=True)

    sess.stop()

    def metrics(ranks):
        n = len(ranks)
        rec = lambda k: sum(1 for r in ranks if 0 < r <= k)
        mrr = sum(1.0 / r for r in ranks if r > 0) / n if n else 0.0
        return {"n": n, "recall@1": rec(1), "recall@5": rec(5),
                "recall@10": rec(10), "mrr": round(mrr, 4)}

    report = {
        "created": datetime.now(timezone.utc).isoformat(),
        "engine": "ctxe",
        "legs": {
            "ask_context_min": metrics([r["ask_rank"] for r in rows]),
            "find_defs": metrics([r["find_defs_rank"] for r in rows
                                  if "find_defs_rank" in r]),
            "union": metrics([r["union_rank"] for r in rows]),
        },
        "latency_ms": {
            "ask_median": round(sorted(r["ask_ms"] for r in rows)[len(rows) // 2], 1),
        },
        "results": rows,
    }
    json.dump(report, open(args.out, "w"), ensure_ascii=False, indent=1)
    print("\n== ctxe strict metrics ==")
    for leg, m in report["legs"].items():
        print(f"{leg:16s} n={m['n']:2d} R@1={m['recall@1']:2d} "
              f"R@5={m['recall@5']:2d} R@10={m['recall@10']:2d} MRR={m['mrr']}")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
