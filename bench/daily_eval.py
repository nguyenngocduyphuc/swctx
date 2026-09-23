#!/usr/bin/env python3
"""daily_eval.py — swctx quality tracker for daily use.

Runs every eval set through ONE persistent `swctx mcp` session and appends
one line to bench/quality_ledger.jsonl — the time series IS the tracker.
Exit 1 when any set regresses vs the previous ledger line.

Sets (all measured identically: search mode=auto, recall@1/@5, latency):
  vn-tuning   bench/vn_queries.json      — the 22q set retrieval was tuned on;
                                          sanity canary, NOT the quality claim
  holdout     bench/holdout_queries.json — frozen, never tuned; the honest
                                          generalization number
  live-misses kind=miss records in ~/.swctx/records.db — real failures filed
                                          by `swctx miss` / put_record during
                                          daily use; grows itself

Miss records: payload JSON needs "expected_path"; workspace comes from
payload "workspace" or the ws key resolved via ~/.swctx/workspaces.json.

Usage:
    python3 bench/daily_eval.py                 # run + append ledger
    python3 bench/daily_eval.py --no-ledger     # measure only
    python3 bench/daily_eval.py --history 14    # print last N ledger lines
"""

import argparse
import json
import math
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession  # noqa: E402

SWCTX_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")
LEDGER = os.path.join(HERE, "quality_ledger.jsonl")
RECORDS_DB = os.path.expanduser("~/.swctx/records.db")
WORKSPACES_JSON = os.path.expanduser("~/.swctx/workspaces.json")


def norm_path(p):
    return (p or "").strip().lstrip("./")


def percentile(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    return s[max(1, math.ceil(q / 100.0 * len(s))) - 1]


def median(vals):
    s = sorted(v for v in vals if v is not None)
    if not s:
        return None
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m - 1] + s[m]) / 2


def load_set(path):
    spec = json.load(open(path))
    return [{"id": q["id"], "workspace": q["workspace"],
             "query": q["query"],
             "expected": norm_path(q.get("expected_path"))}
            for q in spec["queries"]]


def ws_key_to_path():
    try:
        return {w["key"]: w["path"]
                for w in json.load(open(WORKSPACES_JSON))}
    except Exception:
        return {}


def load_misses():
    """kind=miss records -> live gold queries (deduped, newest first)."""
    if not os.path.exists(RECORDS_DB):
        return []
    key2path = ws_key_to_path()
    try:
        db = sqlite3.connect(f"file:{RECORDS_DB}?mode=ro", uri=True)
        rows = db.execute(
            "select ws, title, payload from records "
            "where kind='miss' order by id desc").fetchall()
        db.close()
    except sqlite3.Error:
        return []
    out, seen = [], set()
    for ws_key, title, payload in rows:
        try:
            pay = json.loads(payload)
        except (ValueError, TypeError):
            pay = {}
        ws = pay.get("workspace") or key2path.get(ws_key)
        exp = norm_path(pay.get("expected_path", ""))
        if not ws or not exp or not title:
            continue
        if (ws, title, exp) in seen:
            continue
        seen.add((ws, title, exp))
        out.append({"id": f"miss-{len(out) + 1}", "workspace": ws,
                    "query": title, "expected": exp})
    return out


def git_sha():
    try:
        return subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=os.path.join(HERE, ".."), capture_output=True,
            text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def run_set(session, queries, limit=5):
    """returns per-query rows + aggregate."""
    rows, lats = [], []
    for q in queries:
        t0 = time.monotonic()
        payload, _, err = session.call_tool(
            "search", {"workspace": q["workspace"], "query": q["query"],
                       "mode": "auto", "limit": limit},
            retries=0, timeout=60)
        lat = (time.monotonic() - t0) * 1000.0
        lats.append(lat)
        paths = [norm_path(h.get("path"))
                 for h in (payload or {}).get("hits", [])]
        rank = paths.index(q["expected"]) + 1 if q["expected"] in paths else 0
        rows.append({"id": q["id"], "rank": rank,
                     "status": "error" if err else "ok",
                     **({"error": err} if err else {})})
    hits = sum(1 for r in rows if r["rank"])
    top1 = sum(1 for r in rows if r["rank"] == 1)
    return rows, {
        "n": len(rows), "hits": hits, "top1": top1,
        "recall_at_5": round(hits / len(rows), 4) if rows else None,
        "recall_at_1": round(top1 / len(rows), 4) if rows else None,
        "p50_ms": round(median(lats) or 0, 1),
        "p95_ms": round(percentile(lats, 95) or 0, 1),
        "misses": [r["id"] for r in rows if not r["rank"]],
    }


def main():
    ap = argparse.ArgumentParser(description="swctx daily quality tracker")
    ap.add_argument("--swctx-bin", default=SWCTX_BIN)
    ap.add_argument("--no-ledger", action="store_true")
    ap.add_argument("--history", type=int, default=0,
                    help="print last N ledger lines and exit")
    args = ap.parse_args()

    if args.history:
        try:
            lines = open(LEDGER).read().strip().splitlines()[-args.history:]
        except FileNotFoundError:
            print("(no ledger yet)")
            return 0
        for ln in lines:
            d = json.loads(ln)
            sets = "  ".join(
                f"{k}={v.get('hits')}/{v.get('n')}"
                f"@{round((v.get('recall_at_5') or 0) * 100)}%"
                f" p95={v.get('p95_ms')}ms"
                for k, v in d["sets"].items())
            print(f"{d['ts'][:16]}  {d.get('sha','?'):8s}  {sets}")
        return 0

    sets = {
        "vn-tuning": load_set(os.path.join(HERE, "vn_queries.json")),
        "holdout": load_set(os.path.join(HERE, "holdout_queries.json")),
        "live-misses": load_misses(),
    }

    s = MCPSession("swctx", [args.swctx_bin, "mcp"], timeout=60)
    s.start()
    if not s.tools:
        print("swctx mcp start failed", file=sys.stderr)
        return 2

    # Warm durable caches before measuring — steady state (see engine_ab).
    for queries in sets.values():
        for q in queries:
            try:
                s.call_tool("search", {"workspace": q["workspace"],
                                       "query": q["query"], "mode": "auto",
                                       "limit": 1}, retries=0, timeout=60)
            except Exception:
                pass

    out_sets, detail = {}, {}
    for name, queries in sets.items():
        if not queries:
            out_sets[name] = {"n": 0, "hits": 0, "recall_at_5": None,
                              "note": "empty set"}
            continue
        rows, agg = run_set(s, queries)
        out_sets[name] = agg
        detail[name] = rows
    s.stop()

    line = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "sha": git_sha(), "sets": out_sets}

    prev = None
    if os.path.exists(LEDGER):
        try:
            prev = json.loads(open(LEDGER).read().strip().splitlines()[-1])
        except (ValueError, IndexError):
            prev = None

    # ---- report ----
    print(f"swctx daily eval  {line['ts'][:19]}  sha={line['sha']}")
    regress = []
    for name, agg in out_sets.items():
        if agg.get("n") == 0:
            print(f"  {name:12s}  (empty)")
            continue
        p = (prev or {}).get("sets", {}).get(name) or {}
        delta = ""
        if p.get("recall_at_5") is not None and agg["recall_at_5"] is not None:
            d = round(agg["recall_at_5"] - p["recall_at_5"], 4)
            delta = f"  {'+' if d >= 0 else ''}{d} vs last"
            if d < 0:
                regress.append(name)
        print(f"  {name:12s}  {agg['hits']}/{agg['n']} "
              f"r@5={agg['recall_at_5']} r@1={agg['recall_at_1']} "
              f"p50={agg['p50_ms']}ms p95={agg['p95_ms']}ms{delta}")
        if agg["misses"]:
            print(f"               miss: {', '.join(agg['misses'])}")

    if not args.no_ledger:
        with open(LEDGER, "a") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
        print(f"  ledger -> {os.path.relpath(LEDGER)}")

    if regress:
        print(f"REGRESSION vs previous line: {', '.join(regress)}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
