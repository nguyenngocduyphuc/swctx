#!/usr/bin/env python3
"""mine_queries.py — mine usage_events into eval-manifest candidates.

Closes the SENSE->SWEEP half of the self-tuning loop (SELF_TUNING.md).
Two candidate classes, both written to one manifest:

- zero_hit: `search` calls with hits=0. expected_path=null — they feed
  the zero-hit-rate metric, never recall.
- implicit_utility: a `search` event followed, in the SAME session and
  workspace, by fetch_chunks/inspect_path whose arg_path resolves to a
  path inside that search's top_paths. Positive-unlabeled evidence —
  the agent opened a file search surfaced, which is NOT proof it was
  the right file (Codex review). Confidence stays `implicit_utility`
  until manually verified -> `verified`.

Bench traffic is filtered by text: queries matching a bench manifest
verbatim are tagged source=bench and excluded from candidates (bench
runs replay manifest text; organic queries don't).

Output: bench/mined_manifest.json + stdout summary.
Usage: python3 bench/mine_queries.py [--records ~/.swctx/records.db]
"""

import argparse
import glob
import json
import os
import sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
RECORDS = os.path.join(HOME, ".swctx", "records.db")
INDEXES = os.path.join(HOME, ".swctx", "indexes")

WS_NAMES = {
    "6e09ad5e9099": "8.P8_SEO_Clean", "9244bb1f135b": "21.linkeldn",
    "a4fc8115d18a": "22.site-M", "442abc5637c0": "25.event-qr",
    "b1617b66c781": "18.CRM", "56ada82ab9b2": "12.CMS",
    "d75cc574dfb7": "tools/swctx",
}
WS_ROOTS = {
    "6e09ad5e9099": "/Users/phuongnam/02.AI/NP_AI_macos/8.P8_SEO_Clean",
    "9244bb1f135b": "/Users/phuongnam/02.AI/NP_AI_macos/21.linkeldn",
    "a4fc8115d18a": "/Users/phuongnam/02.AI/NP_AI_macos/22.site-M",
    "442abc5637c0": "/Users/phuongnam/02.AI/NP_AI_macos/25.event-qr-checkin",
    "b1617b66c781": "/Users/phuongnam/02.AI/NP_AI_macos/18.CRM-Nam-Pham",
    "56ada82ab9b2": "/Users/phuongnam/02.AI/NP_AI_macos/12.CMS",
}


def bench_queries():
    """Query texts already in bench manifests -> source=bench."""
    out = set()
    for f in glob.glob(os.path.join(HERE, "*.json")):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        rows = d if isinstance(d, list) else d.get("queries", [])
        for q in rows:
            if isinstance(q, dict) and q.get("query"):
                out.add(q["query"].strip()[:200])
    return out


def chunk_paths(ws):
    """chunk_id -> file path for one workspace index."""
    db = os.path.join(INDEXES, ws, "index.db")
    if not os.path.exists(db):
        return {}
    con = sqlite3.connect(db)
    try:
        return {r[0]: r[1] for r in con.execute(
            "SELECT c.id, f.path FROM chunks c JOIN files f "
            "ON f.id = c.file_id")}
    except sqlite3.Error:
        return {}
    finally:
        con.close()


def resolve_arg(ws, tool, arg_path, cmap):
    """arg_path -> repo-relative path. fetch_chunks stores chunk_ids JSON;
    inspect_path/tree filters store a literal path."""
    if not arg_path:
        return None
    if arg_path.startswith("["):
        try:
            ids = json.loads(arg_path)
        except json.JSONDecodeError:
            return None
        for cid in ids:
            if cid in cmap:
                return cmap[cid]
        return None
    return arg_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--records", default=RECORDS)
    ap.add_argument("--out", default=os.path.join(HERE, "mined_manifest.json"))
    ap.add_argument("--min-sessions", type=int, default=1)
    args = ap.parse_args()

    con = sqlite3.connect(args.records)
    cols = {r[1] for r in con.execute("PRAGMA table_info(usage_events)")}
    if not {"session", "top_paths", "arg_path"} <= cols:
        print("usage_events lacks session/top_paths/arg_path — "
              "run a current swctx build once to migrate the ledger")
        return

    bench = bench_queries()
    rows = con.execute("""
        SELECT id, ts, ws, tool, hits, ok, query, session, top_paths,
               arg_path
        FROM usage_events ORDER BY session, id
    """).fetchall()
    con.close()

    cmaps = {}
    candidates, zero_hits, organic_seen = [], [], {}
    last_search = {}  # (session, ws) -> row
    bench_calls = 0
    for (eid, ts, ws, tool, hits, ok, query, sess, top, argp) in rows:
        if tool == "search" and query:
            q = query.strip()
            if q in bench:
                bench_calls += 1
                continue
            if sess:
                organic_seen.setdefault(q, set()).add(sess)
                last_search[(sess, ws)] = (eid, q, top)
            if hits == 0:
                zero_hits.append({"id": f"zh-{eid}", "query": q,
                                  "workspace": WS_ROOTS.get(ws, ws),
                                  "expected_path": None,
                                  "confidence": "zero_hit",
                                  "source": "usage"})
            continue
        # follow-up events: attribute to the most recent search in the
        # same session+ws when the follow-up target was in its top_paths
        if tool not in ("fetch_chunks", "inspect_path") or not sess:
            continue
        prior = last_search.get((sess, ws))
        if not prior or not prior[2]:
            continue
        if ws not in cmaps:
            cmaps[ws] = chunk_paths(ws)
        target = resolve_arg(ws, tool, argp, cmaps[ws])
        if not target:
            continue
        try:
            tops = json.loads(prior[2])
        except (json.JSONDecodeError, TypeError):
            continue
        if target in tops:
            candidates.append({"id": f"iu-{prior[0]}", "query": prior[1],
                               "workspace": WS_ROOTS.get(ws, ws),
                               "expected_path": target,
                               "confidence": "implicit_utility",
                               "source": "usage",
                               "evidence": f"{tool}:{eid}"})

    # organic = query text seen across >=1 real sessions and not a
    # verbatim bench query (already filtered); dedupe keep first
    seen, dedup = set(), []
    for c in candidates + zero_hits:
        key = (c["query"], c["workspace"])
        if key in seen:
            continue
        seen.add(key)
        c["sessions"] = len(organic_seen.get(c["query"], {1}))
        dedup.append(c)

    json.dump({"generated": __import__("datetime").datetime.now(
                  __import__("datetime").timezone.utc).isoformat(),
               "confidence_note": "implicit_utility is positive-unlabeled"
                                  " — verify before treating as gold",
               "queries": dedup},
              open(args.out, "w"), ensure_ascii=False, indent=1)
    print(f"mined {len(candidates)} implicit_utility, "
          f"{len(zero_hits)} zero_hit -> {len(dedup)} unique candidates "
          f"(excluded {bench_calls} bench-manifest calls)")
    by_conf = {}
    for c in dedup:
        by_conf[c["confidence"]] = by_conf.get(c["confidence"], 0) + 1
    print("by confidence:", by_conf)


if __name__ == "__main__":
    main()
