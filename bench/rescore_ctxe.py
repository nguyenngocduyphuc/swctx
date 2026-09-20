#!/usr/bin/env python3
"""rescore_ctxe.py — re-score the ctxe linkeldn leg from durable records.

ctxe_linkeldn.py v1 extracted paths from the raw MCP content text (the
serialized JSON envelope, whose literal \\n sequences corrupted tokens like
`nSources/...`) and parsed find_definitions with the wrong shape
(`definitions[].path` instead of `definitions[].chunks[].file_path`).
This scorer re-derives both legs from `~/.ctxe/indexes/<key>/records.db`
payloads — zero new asks, zero new credits.

Scoring contract (same as strict_score.py):
  - ask leg: paths are extracted from `payload.answer` markdown in order;
    candidates must contain `/` (repo-relative) and end at an extension
    word boundary (kills `Fingerprint.sha256`→`Fingerprint.sh` artifacts)
  - rank 0 = gold absent from extracted evidence paths
"""

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
INDEXES_DIR = os.path.expanduser("~/.ctxe/indexes")

# repo-relative path with a real source extension at a word boundary
PATH_RE = re.compile(
    r"((?:[\w\-.]+/)+[\w\-.]+\."
    r"(?:swift|py|md|json|ya?ml|toml|sh|txt|ts|js|html|css))"
    r"(?::\d+(?:-\d+)?)?(?![\w.])")


def norm_path(p):
    return (p or "").strip().lstrip("./")


def rank_of(expected, paths):
    try:
        return paths.index(norm_path(expected)) + 1
    except ValueError:
        return 0


def extract_paths(markdown):
    seen, out = set(), []
    for m in PATH_RE.finditer(markdown or ""):
        p = norm_path(m.group(1))
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def metrics(ranks):
    n = len(ranks)
    rec = lambda k: sum(1 for r in ranks if 0 < r <= k)
    mrr = sum(1.0 / r for r in ranks if r > 0) / n if n else 0.0
    return {"n": n, "recall@1": rec(1), "recall@5": rec(5),
            "recall@10": rec(10), "mrr": round(mrr, 4)}


def ws_index_key(workspace):
    """ctxe index key for a workspace = same hash as swctx's."""
    try:
        import subprocess
        proc = subprocess.run(
            [os.path.join(HERE, "..", ".build", "release", "swctx"),
             "status", workspace],
            capture_output=True, text=True, timeout=30)
        return json.loads(proc.stdout).get("meta", {}).get("key")
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queries", default=os.path.join(HERE, "linkeldn_holdout.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "linkeldn_ctxe_results.json"))
    args = ap.parse_args()

    queries = json.load(open(args.queries))["queries"]

    by_query = {}
    for ws in {q["workspace"] for q in queries}:
        key = ws_index_key(ws)
        if not key:
            continue
        db = os.path.join(INDEXES_DIR, key, "records.db")
        if not os.path.exists(db):
            continue
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = con.execute(
            "SELECT payload FROM records WHERE kind='ask' "
            "AND status='completed' ORDER BY id DESC LIMIT 80").fetchall()
        con.close()
        for (payload,) in rows:
            try:
                body = json.loads(payload)
            except ValueError:
                continue
            q = body.get("query")
            if q and q not in by_query:
                by_query[q] = body

    results = []
    for q in queries:
        gold = q["expected_path"]
        row = {"id": q["id"], "gold": gold,
               "query_intent": q["query_intent"],
               "path_signal": q["path_signal"], "lang": q["lang"]}
        body = by_query.get(q["query"])
        if body is None:
            row["ask_rank"] = 0
            row["ask_paths"] = []
            row["missing_record"] = True
        else:
            answer = body.get("answer", {})
            md = answer.get("answer", "") if isinstance(answer, dict) else str(answer)
            row["ask_paths"] = extract_paths(md)
            row["ask_rank"] = rank_of(gold, row["ask_paths"])
        results.append(row)
        print(f"{row['id']:8s} ask={row['ask_rank']:2d} "
              f"paths={len(row['ask_paths']):2d}")

    report = {
        "created": datetime.now(timezone.utc).isoformat(),
        "engine": "ctxe",
        "note": "rescored from records.db — v1 extraction bug fixed "
                "(literal \\n tokens + find_defs shape)",
        "legs": {"ask_context_min": metrics([r["ask_rank"] for r in results])},
        "results": results,
    }
    json.dump(report, open(args.out, "w"), ensure_ascii=False, indent=1)
    m = report["legs"]["ask_context_min"]
    print(f"\nctxe ask(min): n={m['n']} R@1={m['recall@1']} "
          f"R@5={m['recall@5']} R@10={m['recall@10']} MRR={m['mrr']}")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
