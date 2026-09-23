#!/usr/bin/env python3
"""recall_mcp.py — gold-set recall@5 measured entirely over the MCP wire.

bench/recall.py proved `swctx search` (CLI, one process per query) recall
= 0.972 on the gold set, but the fleet only ever calls the MCP tools — and
the wire-contract audit showed the tool schemas were malformed at one
point, so the MCP path is what must be benchmarked and ratcheted. This
script runs the SAME 36 gold queries through ONE persistent `swctx mcp`
stdio session:

  * every query       -> tools/call "search" {workspace, query,
                         mode:"auto", limit:5}
  * kind="definition" -> additionally tools/call "find_definitions"
                         {workspace, symbols:[query], include_content:false}

One warmup `search` + `find_definitions` call per workspace (results
discarded) absorbs first-call index/embedder load, so recorded latencies
are steady-state — matching how the fleet uses a long-lived server.

Output: JSON (per-query records + per-workspace summary + overall
aggregate incl. p95 latency) on stdout; appends rows with
engine=swctx:search-mcp / swctx:find-defs-mcp to bench/results.csv unless
--no-csv or --ratchet (CSV `swctx:search` rows are the CLI path — compare
like-with-like by engine name).

Ratchet (CI gate) — exits non-zero if ANY gate fails; emits per-gate
lines + a one-line verdict to stderr:

    python3 bench/recall_mcp.py --ratchet
      a) swctx:search-mcp recall@5 over all gold queries < --min-recall (0.95)
      b) p95 per-query MCP call latency > --max-p95-ms (150)
      c) live tools/list {name,inputSchema} != --golden file
         (catches silent tool-surface regressions like the flat-schema bug)

Golden tool-surface file (bench/tool_schemas.golden.json):

    python3 bench/recall_mcp.py --write-golden   # regenerate after an
                                                 # INTENTIONAL surface change
    python3 bench/recall_mcp.py --check-schema   # schema gate only (cheap)

Stdlib only. Other usage:

    python3 bench/recall_mcp.py --no-csv    # run, don't touch results.csv
"""

import argparse
import csv
import json
import math
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession, PROTOCOL_VERSION  # noqa: E402
from recall import (  # noqa: E402  (reuse proven helpers + constants)
    CSV_HEADER, DEFAULT_CSV, DEFAULT_GOLD, DEFAULT_SWCTX_BIN,
    norm_path, swctx_mcp_find_defs)

DEFAULT_GOLDEN = os.path.join(HERE, "tool_schemas.golden.json")
ENGINE_SEARCH = "swctx:search-mcp"
ENGINE_DEFS = "swctx:find-defs-mcp"


# ----------------------------------------------------------------------
# Retrieval (MCP wire path)
# ----------------------------------------------------------------------

def swctx_mcp_search(session, workspace, query, limit, timeout=60):
    """tools/call `search` (mode=auto); return (paths, latency_ms, error)."""
    payload, latency, err = session.call_tool(
        "search",
        {"workspace": workspace, "query": query, "mode": "auto",
         "limit": limit},
        timeout=timeout)
    if err:
        return [], latency, err
    paths = [norm_path(h.get("path")) for h in payload.get("hits", [])]
    return paths[:limit], latency, None


# ----------------------------------------------------------------------
# Golden tool-schema helpers
# ----------------------------------------------------------------------

def canonical_tools(tools_map):
    """{name: inputSchema} -> [{name, inputSchema}] sorted by name."""
    return [{"name": n, "inputSchema": tools_map[n]}
            for n in sorted(tools_map)]


def golden_doc(tools_map):
    return {"server": "swctx",
            "protocol_version": PROTOCOL_VERSION,
            "tool_count": len(tools_map),
            "tools": canonical_tools(tools_map)}


def load_golden(path):
    """Return (tools_list, error). Accepts the canonical doc or a bare
    sorted [{name,inputSchema}] list."""
    try:
        with open(path) as f:
            doc = json.load(f)
    except Exception as e:
        return None, f"golden unreadable: {e}"
    tools = doc.get("tools") if isinstance(doc, dict) else doc
    if not isinstance(tools, list):
        return None, "golden has no 'tools' list"
    return tools, None


def schema_diff(golden_tools, live_map):
    """Human-readable diffs between golden [{name,inputSchema}] and live
    {name: inputSchema}; [] == identical."""
    diffs = []
    g_by = {t["name"]: t.get("inputSchema", {}) for t in golden_tools}
    for n in sorted(set(g_by) - set(live_map)):
        diffs.append(f"tool removed from live: {n}")
    for n in sorted(set(live_map) - set(g_by)):
        diffs.append(f"tool added in live: {n}")
    for n in sorted(set(g_by) & set(live_map)):
        if g_by[n] != live_map[n]:
            diffs.append(f"inputSchema changed: {n}")
    return diffs


# ----------------------------------------------------------------------
# Stats
# ----------------------------------------------------------------------

def percentile(vals, q):
    """Nearest-rank percentile (p95 of 54 -> rank 52)."""
    if not vals:
        return None
    s = sorted(vals)
    k = max(1, math.ceil(q / 100.0 * len(s)))
    return s[k - 1]


# ----------------------------------------------------------------------
# Session
# ----------------------------------------------------------------------

def start_swctx(bin_path, workspaces):
    """Start `swctx mcp`; warm each workspace (index open + embedder) so
    per-query latencies are steady-state. Returns (session, error)."""
    try:
        s = MCPSession("swctx", [bin_path, "mcp"], timeout=60)
        s.start()
    except Exception as e:
        return None, f"swctx mcp start failed: {e}"
    if not s.tools:
        s.stop()
        return None, "swctx mcp tools/list failed or returned no tools"
    for ws in workspaces:
        # multi-word query forces resolved_mode=hybrid -> loads embedder
        s.call_tool("search",
                    {"workspace": ws,
                     "query": "warmup load index and embedder",
                     "mode": "auto", "limit": 1},
                    retries=0, timeout=60)
        s.call_tool("find_definitions",
                    {"workspace": ws, "symbols": ["__warmup__"],
                     "include_content": False},
                    retries=0, timeout=60)
    return s, None


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="gold recall@5 over the swctx MCP wire path")
    ap.add_argument("--gold", default=DEFAULT_GOLD)
    ap.add_argument("--csv", default=DEFAULT_CSV)
    ap.add_argument("--no-csv", action="store_true")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--swctx-bin", default=DEFAULT_SWCTX_BIN)
    ap.add_argument("--tag", default="", help="extra note suffix for CSV")
    ap.add_argument("--golden", default=DEFAULT_GOLDEN,
                    help="tool_schemas.golden.json path")
    ap.add_argument("--write-golden", action="store_true",
                    help="dump live tools/list {name,inputSchema} to "
                         "--golden and exit (regenerates the golden file)")
    ap.add_argument("--check-schema", action="store_true",
                    help="run only the schema gate vs --golden; exit "
                         "non-zero on any diff")
    ap.add_argument("--ratchet", action="store_true",
                    help="CI mode: run recall + all gates, verdict + "
                         "per-gate results to stderr, exit non-zero on "
                         "failure (implies --no-csv)")
    ap.add_argument("--min-recall", type=float, default=0.95,
                    help="ratchet gate a: min search recall@5 (0.95)")
    ap.add_argument("--max-p95-ms", type=float, default=150.0,
                    help="ratchet gate b: max p95 per-query latency ms "
                         "(150)")
    args = ap.parse_args()

    # ---- schema-only modes: no recall run ----
    if args.write_golden or args.check_schema:
        s = MCPSession("swctx", [args.swctx_bin, "mcp"], timeout=60)
        try:
            s.start()
        except Exception as e:
            print(f"swctx mcp start failed: {e}", file=sys.stderr)
            return 1
        if not s.tools:
            s.stop()
            print("swctx mcp tools/list failed", file=sys.stderr)
            return 1
        if args.write_golden:
            doc = golden_doc(s.tools)
            with open(args.golden, "w") as f:
                f.write(json.dumps(doc, indent=1, sort_keys=True) + "\n")
            print(f"wrote {doc['tool_count']} tools -> {args.golden}",
                  file=sys.stderr)
            s.stop()
            return 0
        # --check-schema
        golden_tools, gerr = load_golden(args.golden)
        if gerr:
            s.stop()
            print(f"gate schema-golden: FAIL {gerr} "
                  f"(regenerate: python3 bench/recall_mcp.py "
                  f"--write-golden)", file=sys.stderr)
            print("schema: FAIL", file=sys.stderr)
            return 1
        diffs = schema_diff(golden_tools, s.tools)
        s.stop()
        if diffs:
            print(f"gate schema-golden: FAIL {len(diffs)} diff(s)",
                  file=sys.stderr)
            for d in diffs:
                print(f"  - {d}", file=sys.stderr)
            print("schema: FAIL", file=sys.stderr)
            return 1
        print(f"gate schema-golden: PASS {len(s.tools)} tools match "
              f"{args.golden}", file=sys.stderr)
        print("schema: PASS", file=sys.stderr)
        return 0

    # ---- recall run over one persistent MCP session ----
    gold = json.load(open(args.gold))
    queries = gold["queries"]
    workspaces = []
    for q in queries:
        if q["workspace"] not in workspaces:
            workspaces.append(q["workspace"])

    session, serr = start_swctx(args.swctx_bin, workspaces)
    if serr:
        print(f"session error: {serr}", file=sys.stderr)
        if args.ratchet:
            print("gate recall@5:       FAIL no session", file=sys.stderr)
            print("gate p95-latency:    FAIL no session", file=sys.stderr)
            print("gate schema-golden:  FAIL no session", file=sys.stderr)
            print("ratchet: FAIL (mcp session start)", file=sys.stderr)
        return 1

    # Warm durable translation/round-2 caches before measuring — a cold
    # roll races the result deadline and still writes the cache, so a
    # one-shot pass measures roll luck. Production MCP is long-lived;
    # steady state IS warm cache. Results and latency discarded.
    for q in queries:
        try:
            session.call_tool(
                "search", {"workspace": q["workspace"],
                           "query": q["query"], "mode": "auto",
                           "limit": 1}, timeout=60)
        except Exception:
            pass

    records = []
    latencies = []          # every per-query MCP call (both tools)
    for q in queries:
        ws, kind, query = q["workspace"], q["kind"], q["query"]
        expected = norm_path(q.get("expected_path"))
        rec = {"workspace": ws, "kind": kind, "query": query,
               "expected_path": expected, "results": {}}

        paths, lat, err = swctx_mcp_search(session, ws, query, args.limit)
        if lat is not None:
            latencies.append(lat)
        rec["results"][ENGINE_SEARCH] = {
            "hits": paths, "latency_ms": round(lat or 0, 1),
            "recall": int(expected in paths),
            **({"error": err} if err else {})}

        if kind == "definition":
            paths, lat, err = swctx_mcp_find_defs(
                session, ws, query, args.limit, timeout=60)
            if lat is not None:
                latencies.append(lat)
            rec["results"][ENGINE_DEFS] = {
                "hits": paths, "latency_ms": round(lat or 0, 1),
                "recall": int(expected in paths),
                **({"error": err} if err else {})}

        records.append(rec)

    live_tools = dict(session.tools)  # snapshot before stop
    session.stop()

    # ---- aggregate: per (engine, workspace, kind) + overall per engine ----
    groups = {}
    agg = {}
    for rec in records:
        ws_base = os.path.basename(rec["workspace"].rstrip("/"))
        for tool, r in rec["results"].items():
            key = (tool, ws_base, rec["kind"])
            groups.setdefault(key, [0, 0])
            groups[key][0] += r["recall"]
            groups[key][1] += 1
            a = agg.setdefault(tool, {"hits": 0, "n": 0, "errors": 0,
                                      "lat": []})
            a["hits"] += r["recall"]
            a["n"] += 1
            a["errors"] += int("error" in r)
            if r.get("latency_ms"):
                a["lat"].append(r["latency_ms"])

    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    summary = []
    for (tool, ws_base, kind), (hits, n) in sorted(groups.items()):
        summary.append({"engine": tool, "workspace": ws_base, "kind": kind,
                        "recall_at_5": round(hits / n, 4) if n else 0.0,
                        "n_queries": n, "hits": hits})
    aggregate = {}
    for tool, a in sorted(agg.items()):
        aggregate[tool] = {
            "recall_at_5": round(a["hits"] / a["n"], 4) if a["n"] else 0.0,
            "n_queries": a["n"], "hits": a["hits"], "errors": a["errors"],
            "p95_latency_ms": round(percentile(a["lat"], 95) or 0, 1)}

    p95_all = percentile(latencies, 95)
    out = {"timestamp": ts, "transport": "mcp", "limit": args.limit,
           "p95_latency_ms_all_calls": round(p95_all or 0, 1),
           "n_calls": len(latencies),
           "aggregate": aggregate,
           "summary": summary, "queries": records}
    print(json.dumps(out, indent=1))

    # ---- append CSV (never under --ratchet) ----
    if not args.no_csv and not args.ratchet:
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(CSV_HEADER)
            for row in summary:
                if row["engine"] == ENGINE_SEARCH:
                    notes = ("mcp `tools/call search` mode=auto "
                             "(persistent stdio session)")
                else:
                    notes = ("mcp `tools/call find_definitions` "
                             "(persistent stdio session)")
                if args.tag:
                    notes += f"; {args.tag}"
                w.writerow([ts, row["engine"], row["workspace"],
                            row["kind"], row["recall_at_5"],
                            row["n_queries"], notes])
        print(f"appended {len(summary)} rows -> {args.csv}",
              file=sys.stderr)

    # ---- ratchet gates ----
    if args.ratchet:
        ok = True
        sa = aggregate.get(ENGINE_SEARCH, {"recall_at_5": 0.0, "hits": 0,
                                         "n_queries": 0})
        g1 = sa["recall_at_5"] >= args.min_recall
        ok &= g1
        print(f"gate recall@5:       {'PASS' if g1 else 'FAIL'} "
              f"{sa['recall_at_5']:.4f} ({sa['hits']}/{sa['n_queries']}) "
              f">= {args.min_recall}", file=sys.stderr)

        g2 = p95_all is not None and p95_all <= args.max_p95_ms
        ok &= g2
        print(f"gate p95-latency:    {'PASS' if g2 else 'FAIL'} "
              f"{round(p95_all or 0, 1)}ms <= {args.max_p95_ms}ms "
              f"(n={len(latencies)} calls)", file=sys.stderr)

        golden_tools, gerr = load_golden(args.golden)
        if gerr:
            ok = False
            print(f"gate schema-golden:  FAIL {gerr} "
                  f"(regenerate: python3 bench/recall_mcp.py "
                  f"--write-golden)", file=sys.stderr)
        else:
            diffs = schema_diff(golden_tools, live_tools)
            if diffs:
                ok = False
                print(f"gate schema-golden:  FAIL {len(diffs)} diff(s)",
                      file=sys.stderr)
                for d in diffs:
                    print(f"  - {d}", file=sys.stderr)
            else:
                print(f"gate schema-golden:  PASS {len(live_tools)} "
                      f"tools match {args.golden}", file=sys.stderr)

        print(f"ratchet: {'PASS' if ok else 'FAIL'}", file=sys.stderr)
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
