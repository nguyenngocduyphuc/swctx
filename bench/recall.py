#!/usr/bin/env python3
"""recall.py — gold-set recall@5 harness for swctx (and optionally ctxe).

Runs every query in bench/gold_queries.json through
`swctx search <ws> "<q>" --mode auto --limit 5` (the CLI, one process per
query — this is what the task specifies and also exercises the real user
entrypoint). For kind="definition" queries it ALSO calls `find_definitions`
over a persistent `swctx mcp` stdio session (one server for the whole run,
reused across workspaces — the workspace is a per-call argument, so there
is no reason to spawn per query).

ctxe is optional (--engine): it has no workspace-wide `search` tool (see
bench/README.md), so for kind="search" queries it is evaluated with
`inspect_path` scoped to the FIRST path component of the expected file —
the same convention bench.py uses for its `search_equiv` case. Those rows
are labelled `ctxe:inspect_path` and are an upper-bound assist, not
comparable workspace recall. kind="definition" uses `find_definitions`,
which is a fair like-for-like comparison.

Output: JSON (per-query records + aggregate summary) on stdout, and one
row per (engine:tool, workspace, kind) appended to bench/results.csv
(header: timestamp,engine,workspace,kind,recall_at_5,n_queries,notes).

Stdlib only. Usage:

    python3 bench/recall.py                  # both engines, appends CSV
    python3 bench/recall.py --engine swctx   # swctx only
    python3 bench/recall.py --no-csv         # don't touch results.csv
    python3 bench/recall.py --cli-only       # skip all MCP plumbing
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession  # noqa: E402  (reuse the proven stdio client)

DEFAULT_GOLD = os.path.join(HERE, "gold_queries.json")
DEFAULT_CSV = os.path.join(HERE, "results.csv")
DEFAULT_SWCTX_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")
CSV_HEADER = ["timestamp", "engine", "workspace", "kind",
              "recall_at_5", "n_queries", "notes"]


# ----------------------------------------------------------------------
# Retrieval backends
# ----------------------------------------------------------------------

def norm_path(p):
    return (p or "").strip().lstrip("./")


def swctx_cli_search(bin_path, workspace, query, limit, timeout=60):
    """Run `swctx search` CLI; return (paths, latency_ms, error)."""
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            [bin_path, "search", workspace, query,
             "--mode", "auto", "--limit", str(limit)],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception as e:  # timeout / spawn failure
        return [], None, f"cli spawn/run error: {e}"
    latency = (time.monotonic() - t0) * 1000.0
    if proc.returncode != 0:
        return [], latency, f"cli exit {proc.returncode}: {proc.stderr[:200]}"
    try:
        payload = json.loads(proc.stdout)
    except ValueError:
        return [], latency, f"cli non-JSON output: {proc.stdout[:200]}"
    paths = [norm_path(h.get("path")) for h in payload.get("hits", [])]
    return paths, latency, None


def swctx_mcp_find_defs(session, workspace, symbol, limit, timeout=30):
    payload, latency, err = session.call_tool(
        "find_definitions",
        {"workspace": workspace, "symbols": [symbol], "include_content": False},
        timeout=timeout)
    if err:
        return [], latency, err
    paths = []
    for r in payload.get("results", []):
        for d in r.get("definitions", []):
            paths.append(norm_path(d.get("path")))
    return paths[:limit], latency, None


def ctxe_mcp_find_defs(session, workspace, symbol, limit, timeout=45):
    payload, latency, err = session.call_tool(
        "find_definitions",
        {"workspace": workspace, "symbols": [symbol], "include_content": False},
        timeout=timeout)
    if err:
        return [], latency, err
    paths = []
    for d in payload.get("definitions", []):
        for c in d.get("chunks", []):
            paths.append(norm_path(c.get("file_path")))
    return paths[:limit], latency, None


def ctxe_mcp_inspect(session, workspace, scope_dir, query, limit, timeout=45):
    payload, latency, err = session.call_tool(
        "inspect_path",
        {"workspace": workspace, "path": scope_dir, "query": query,
         "include_content": False, "limit": limit},
        timeout=timeout)
    if err:
        return [], latency, err
    paths = [norm_path(c.get("file_path"))
             for c in payload.get("chunks", [])]
    return paths[:limit], latency, None


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------

def start_session(name, argv):
    try:
        s = MCPSession(name, argv, timeout=60)
        s.start()
        # warmup (absorbs ctxe cold-start 'runtime acquisition ... timed out')
        s.call_tool("get_status", {}, retries=2, timeout=60)
        return s, None
    except Exception as e:
        return None, f"{name} mcp start failed: {e}"


def main():
    ap = argparse.ArgumentParser(description="gold recall@5 harness")
    ap.add_argument("--gold", default=DEFAULT_GOLD)
    ap.add_argument("--csv", default=DEFAULT_CSV)
    ap.add_argument("--no-csv", action="store_true")
    ap.add_argument("--engine", choices=["both", "swctx", "ctxe"],
                    default="both")
    ap.add_argument("--cli-only", action="store_true",
                    help="only `swctx search` CLI; skip all MCP sessions")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--swctx-bin", default=DEFAULT_SWCTX_BIN)
    ap.add_argument("--ctxe-bin", default="ctxe")
    ap.add_argument("--tag", default="", help="extra note suffix for CSV")
    args = ap.parse_args()

    gold = json.load(open(args.gold))
    queries = gold["queries"]

    sessions = {}
    session_notes = {}
    if not args.cli_only:
        if args.engine in ("both", "swctx"):
            s, err = start_session(
                "swctx", [args.swctx_bin, "mcp"])
            sessions["swctx"] = s
            if err:
                session_notes["swctx"] = err
        if args.engine in ("both", "ctxe"):
            s, err = start_session("ctxe", [args.ctxe_bin, "mcp"])
            sessions["ctxe"] = s
            if err:
                session_notes["ctxe"] = err

    records = []
    for q in queries:
        ws, kind, query = q["workspace"], q["kind"], q["query"]
        expected = norm_path(q.get("expected_path"))
        rec = {"workspace": ws, "kind": kind, "query": query,
               "expected_path": expected, "results": {}}

        # --- swctx CLI search (all queries) ---
        if args.engine in ("both", "swctx"):
            paths, lat, err = swctx_cli_search(
                args.swctx_bin, ws, query, args.limit)
            rec["results"]["swctx:search"] = {
                "hits": paths, "latency_ms": round(lat or 0, 1),
                "recall": int(expected in paths),
                **({"error": err} if err else {})}

        # --- find_definitions via MCP (definition kind) ---
        if kind == "definition" and not args.cli_only:
            if sessions.get("swctx") and args.engine in ("both", "swctx"):
                paths, lat, err = swctx_mcp_find_defs(
                    sessions["swctx"], ws, q["query"], args.limit)
                rec["results"]["swctx:find_definitions"] = {
                    "hits": paths, "latency_ms": round(lat or 0, 1),
                    "recall": int(expected in paths),
                    **({"error": err} if err else {})}
            if sessions.get("ctxe") and args.engine in ("both", "ctxe"):
                paths, lat, err = ctxe_mcp_find_defs(
                    sessions["ctxe"], ws, q["query"], args.limit)
                rec["results"]["ctxe:find_definitions"] = {
                    "hits": paths, "latency_ms": round(lat or 0, 1),
                    "recall": int(expected in paths),
                    **({"error": err} if err else {})}

        # --- ctxe scoped inspect_path for search kind (assist only) ---
        if kind == "search" and not args.cli_only \
                and sessions.get("ctxe") and args.engine in ("both", "ctxe"):
            scope = expected.split("/")[0] if "/" in expected else ""
            if scope:
                paths, lat, err = ctxe_mcp_inspect(
                    sessions["ctxe"], ws, scope, query, args.limit)
                rec["results"]["ctxe:inspect_path"] = {
                    "hits": paths, "latency_ms": round(lat or 0, 1),
                    "recall": int(expected in paths),
                    "scoped_to": scope,
                    **({"error": err} if err else {})}
            else:
                rec["results"]["ctxe:inspect_path"] = {
                    "hits": [], "recall": 0, "skipped":
                    "expected file at workspace root; no dir scope"}

        records.append(rec)

    for s in sessions.values():
        if s:
            s.stop()

    # ---- aggregate ----
    groups = {}  # (engine_tool, ws_base, kind) -> [hits, n]
    for rec in records:
        ws_base = os.path.basename(rec["workspace"].rstrip("/"))
        for tool, r in rec["results"].items():
            if r.get("skipped"):
                continue
            key = (tool, ws_base, rec["kind"])
            groups.setdefault(key, [0, 0])
            groups[key][0] += r["recall"]
            groups[key][1] += 1

    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    summary = []
    for (tool, ws_base, kind), (hits, n) in sorted(groups.items()):
        summary.append({"engine": tool, "workspace": ws_base, "kind": kind,
                        "recall_at_5": round(hits / n, 4) if n else 0.0,
                        "n_queries": n, "hits": hits})

    out = {"timestamp": ts, "limit": args.limit,
           "session_notes": session_notes,
           "summary": summary, "queries": records}
    print(json.dumps(out, indent=1))

    # ---- append CSV ----
    if not args.no_csv:
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(CSV_HEADER)
            for row in summary:
                notes = []
                if row["engine"] == "swctx:search":
                    notes.append("cli `swctx search --mode auto`")
                elif row["engine"] == "ctxe:inspect_path":
                    notes.append("scoped assist: ctxe has no workspace "
                                 "search; inspect_path scoped to expected "
                                 "file's top dir")
                else:
                    notes.append("mcp")
                for eng, note in session_notes.items():
                    notes.append(f"{eng}: {note}")
                if args.tag:
                    notes.append(args.tag)
                w.writerow([ts, row["engine"], row["workspace"], row["kind"],
                            row["recall_at_5"], row["n_queries"],
                            "; ".join(notes)])
        print(f"appended {len(summary)} rows -> {args.csv}", file=sys.stderr)


if __name__ == "__main__":
    main()
