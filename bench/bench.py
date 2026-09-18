#!/usr/bin/env python3
"""bench.py — A/B benchmark harness: swctx vs ctxe over MCP stdio.

Spawns `swctx mcp` and `ctxe mcp`, runs the JSON-RPC handshake
(initialize -> notifications/initialized -> tools/call) and executes a fixed
query suite against both index engines, then prints a compact comparison and
writes machine-readable results to bench/results.json.

Stdlib only. Usage:

    python3 bench/bench.py                 # both tools
    python3 bench/bench.py --skip-ctxe     # swctx only
    python3 bench/bench.py --workspace /abs/path --out results.json

Tool-surface notes (verified 2026-09-15, ctxe 0.4.4 / swctx 0.1.0;
re-verified 2026-09-17 via live tools/list):
  * ctxe has NO bare `search` tool. Its closest free/local equivalent to
    swctx `search` is `inspect_path` with `query` (path-scoped only — an
    empty/"." path is rejected). `ask_context` exists but is the
    server-backed, credit-consuming planner (requires `ctxe login`), so it
    is intentionally skipped; see bench/README.md.
  * swctx has NO `ask_context`; `context_pack` is its local deterministic
    analogue but is not exercised here.
  * ctxe `graph_neighbors` has no `depth` parameter (BFS lives in
    `graph_expand`/`graph_paths`); swctx supports depth 1-3.
  * Cases that target tools missing from a server's live `tools/list`
    registry are recorded as skipped with status "n/a" — never as errors —
    so the suite keeps working while parity tools land.
"""

import argparse
import hashlib
import json
import os
import select
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WORKSPACE = "/Users/phuongnam/02.AI/NP_AI_macos/8.P8_SEO_Clean"
DEFAULT_SWCTX_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")
PROTOCOL_VERSION = "2024-11-05"

# --------------------------------------------------------------------------
# MCP stdio session
# --------------------------------------------------------------------------


class MCPSession:
    """Minimal line-delimited JSON-RPC client for an MCP stdio server."""

    def __init__(self, name, argv, timeout=120):
        self.name = name
        self.argv = argv
        self.timeout = timeout
        self._next_id = 0
        self.proc = None
        self.server_info = None
        self.tools = None  # {tool_name: inputSchema} from tools/list

    def start(self):
        self.proc = subprocess.Popen(
            self.argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        resp = self.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "swctx-bench", "version": "0.1"},
            },
        )
        if resp is None or "result" not in resp:
            raise RuntimeError(f"{self.name}: initialize failed: {resp!r}")
        self.server_info = resp["result"].get("serverInfo", {})
        self.notify("notifications/initialized")
        try:
            resp = self.request("tools/list", {})
            if resp and "result" in resp:
                self.tools = {
                    t["name"]: t.get("inputSchema", {})
                    for t in resp["result"].get("tools", [])
                }
        except Exception:
            self.tools = None  # registry unknown — do not gate on it

    def _send(self, msg):
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)

    def request(self, method, params=None, timeout=None):
        self._next_id += 1
        rid = self._next_id
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            r, _, _ = select.select([self.proc.stdout], [], [], 1.0)
            if not r:
                continue
            line = self.proc.stdout.readline()
            if not line:
                return None  # server exited
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue  # skip non-JSON noise on stdout
            if m.get("id") == rid:
                return m
        return None

    def call_tool(self, tool, arguments, retries=2, timeout=None):
        """Return (payload_dict, latency_ms, error_str). Retries transient
        failures (ctxe cold-start 'runtime acquisition ... timed out')."""
        last_err = None
        for attempt in range(1, retries + 2):
            t0 = time.monotonic()
            resp = self.request(
                "tools/call", {"name": tool, "arguments": arguments},
                timeout=timeout,
            )
            latency = (time.monotonic() - t0) * 1000.0
            if resp is None:
                last_err = "timeout (no response)"
            elif "error" in resp:
                last_err = f"rpc {resp['error'].get('code')}: {resp['error'].get('message')}"
            else:
                result = resp.get("result", {})
                texts = [
                    c.get("text", "")
                    for c in result.get("content", [])
                    if c.get("type") == "text"
                ]
                raw = "\n".join(texts)
                try:
                    payload = json.loads(raw)
                except ValueError:
                    payload = {"_raw": raw}
                if result.get("isError"):
                    last_err = raw[:300] or "tool error"
                else:
                    return payload, latency, None
            if attempt <= retries:
                time.sleep(2.0 * attempt)
        return None, None, last_err

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()


# --------------------------------------------------------------------------
# Result normalization — per (server, tool) extractors -> [{loc,symbol,chunk_id,score}]
# --------------------------------------------------------------------------


def _hits(rows):
    return rows[:5]


def extract(server, tool, payload):
    """Normalize a tool payload into a flat list of hit dicts."""
    out = []
    # Shapes handled identically on both servers (each branch tolerates the
    # other engine's variant so either side's implementation is picked up).
    if tool in ("list_records", "search_records", "get_record"):
        items = payload.get("items") or payload.get("records") or []
        if tool == "get_record" and not items:
            items = [payload["record"]] if payload.get("record") else (
                [payload] if payload.get("id") else [])
        for it in items:
            rid = it.get("id") or it.get("record_id")
            title = (it.get("query") or it.get("title")
                     or it.get("kind") or "")
            out.append({"loc": f"record:{rid}", "symbol": str(title)[:60]})
        if not out and payload.get("error"):
            out.append({"loc": "(records unavailable)",
                        "symbol": str(payload["error"])[:60]})
        elif not out and any(k in payload
                             for k in ("items", "records", "total")):
            out.append({"loc": "(empty ledger)", "symbol": "0 records"})
        return out
    if tool == "fast_understand":
        # ctxe: {"answer": {"subjects": [{subject, overview, start_here:
        #   [{chunk_id, file_path, ...}]}], "confidence"}}
        # swctx: deterministic digest — {files_total, chunks_total,
        #   hub_symbols, hot_files, communities, relevant?[{chunk_id,path}]}
        ans = payload.get("answer") or payload
        conf = ans.get("confidence")
        for s in ans.get("subjects", []) or []:
            sh = s.get("start_here") or []
            cid = sh[0].get("chunk_id") if sh else None
            loc = sh[0].get("file_path") if sh else None
            out.append({
                "loc": loc or str(s.get("subject") or "?")[:80],
                "symbol": str(s.get("subject") or "")[:60],
                "chunk_id": cid,
                "confidence": conf,
            })
        for r in payload.get("relevant", []) or []:
            out.append({
                "loc": r.get("path") or "-",
                "symbol": r.get("symbol"),
                "chunk_id": r.get("chunk_id"),
                "score": r.get("score"),
            })
        if not out and any(k in payload for k in
                           ("files_total", "hub_symbols", "communities")):
            out.append({
                "loc": "digest",
                "symbol": f"files:{payload.get('files_total')} "
                          f"chunks:{payload.get('chunks_total')} "
                          f"communities:{len(payload.get('communities') or [])}",
            })
        if not out:
            out.append({"loc": "(no subjects)", "symbol": "empty"})
        return out
    if tool == "graph_expand":
        # ctxe: {"bundles": [{"neighbors": [{"chunk": {"id", "file_id",
        #   "primary_symbol": {"name"}}, "relation", "score"}]}]} — ids only
        #   (no file_path) -> hydrated.
        # swctx: {"results": [{chunk_id, edge_kind, score, "chunk":
        #   {path, start_line, symbol}}]} — already hydrated.
        for b in payload.get("bundles", []):
            for n in b.get("neighbors", []):
                ch = n.get("chunk") or {}
                cid = ch.get("chunk_id") or ch.get("id")
                path = ch.get("file_path") or ch.get("path")
                sym = (ch.get("primary_symbol") or {}).get("name") \
                    or n.get("symbol_name") or ch.get("symbol")
                out.append({
                    "loc": (f"{path}:{ch.get('start_line')}" if path
                            else f"chunk:{cid}"),
                    "chunk_id": cid,
                    "symbol": sym,
                    "edge": n.get("relation") or n.get("edge_kind"),
                    "score": n.get("score"),
                    "_needs_hydration": not path,
                })
        for r in payload.get("results", []):
            ch = r.get("chunk") or {}
            cid = r.get("chunk_id") or ch.get("id")
            path = ch.get("path") or ch.get("file_path")
            out.append({
                "loc": (f"{path}:{ch.get('start_line')}" if path
                        else f"chunk:{cid}"),
                "chunk_id": cid,
                "symbol": ch.get("symbol") or r.get("symbol"),
                "edge": r.get("edge_kind") or r.get("relation"),
                "score": r.get("score"),
                "_needs_hydration": not path,
            })
        for n in payload.get("neighbors", []):  # flat fallback shape
            ch = n.get("chunk") or {}
            cid = n.get("chunk_id") or ch.get("chunk_id") or ch.get("id")
            path = ch.get("path") or ch.get("file_path") or n.get("file_path")
            out.append({
                "loc": path or f"chunk:{cid}",
                "chunk_id": cid,
                "symbol": (n.get("dst_name") or n.get("symbol_name")
                           or ch.get("symbol")),
                "edge": n.get("edge_kind") or n.get("relation"),
                "_needs_hydration": not path,
            })
        return out
    if server == "swctx":
        if tool == "find_definitions":
            for r in payload.get("results", []):
                for d in r.get("definitions", []):
                    out.append({
                        "loc": f"{d.get('path')}:{d.get('line')}",
                        "symbol": r.get("symbol"),
                        "chunk_id": d.get("chunk_id"),
                    })
        elif tool == "find_usages":
            for u in payload.get("usages", []):
                out.append({
                    "loc": f"{u.get('path')}:{u.get('start_line')}",
                    "symbol": u.get("symbol"),
                    "chunk_id": u.get("chunk_id"),
                })
        elif tool == "search":
            for h in payload.get("hits", []):
                out.append({
                    "loc": f"{h.get('path')}:{h.get('start_line')}",
                    "symbol": h.get("symbol"),
                    "chunk_id": h.get("chunk_id"),
                    "score": h.get("score"),
                })
        elif tool == "inspect_path":
            for c in payload.get("chunks", []):
                out.append({
                    "loc": f"{c.get('path')}:{c.get('start_line')}",
                    "symbol": c.get("symbol"),
                    "chunk_id": c.get("chunk_id"),
                    "score": c.get("score"),
                })
        elif tool == "graph_neighbors":
            for n in payload.get("neighbors", []):
                ch = n.get("chunk") or {}
                loc = (
                    f"{ch.get('path')}:{ch.get('start_line')}"
                    if ch.get("path")
                    else f"unresolved:{n.get('dst_name')}"
                )
                out.append({
                    "loc": loc,
                    "symbol": n.get("dst_name") or ch.get("symbol"),
                    "chunk_id": n.get("chunk_id"),
                    "edge": n.get("edge_kind"),
                })
        elif tool == "get_impact":
            # swctx: {"dependents": [{chunk_id, path, start_line, symbol...}]}
            for d in payload.get("dependents", []):
                out.append({
                    "loc": f"{d.get('path')}:{d.get('start_line')}",
                    "symbol": d.get("symbol"),
                    "chunk_id": d.get("chunk_id"),
                })
            if not out:
                out.append({"loc": "(0 dependents)", "symbol": "empty"})
    elif server == "ctxe":
        if tool == "find_definitions":
            for d in payload.get("definitions", []):
                for c in d.get("chunks", []):
                    out.append({
                        "loc": f"{c.get('file_path')}:{c.get('start_line')}",
                        "symbol": d.get("symbol"),
                        "chunk_id": c.get("chunk_id"),
                    })
            for s in payload.get("not_found", []):
                out.append({"loc": "-", "symbol": f"{s} (not_found)"})
        elif tool == "find_usages":
            for u in payload.get("usages", []):
                out.append({
                    "loc": u.get("file_path") or "-",
                    "symbol": u.get("symbol_name"),
                    "chunk_id": u.get("chunk_id"),
                })
        elif tool == "inspect_path":
            for c in payload.get("chunks", []):
                out.append({
                    "loc": f"{c.get('file_path')}:{c.get('start_line')}",
                    "symbol": c.get("symbol_name"),
                    "chunk_id": c.get("chunk_id"),
                    "score": c.get("score"),
                })
        elif tool == "graph_neighbors":
            for n in payload.get("neighbors", []):
                out.append({
                    "loc": n.get("file_path") or "-",
                    "symbol": n.get("symbol_name"),
                    "chunk_id": n.get("chunk_id"),
                    "edge": n.get("edge_kind"),
                })
        elif tool == "get_impact":
            # ctxe: {"chunk_ids": [...], "items": [{chunk_id, hop, score}]}
            # — bare ids only; loc/symbol filled by hydrate_hits().
            for it in payload.get("items", []) or payload.get("dependents", []):
                cid = it.get("chunk_id")
                out.append({
                    "loc": f"chunk:{cid}",
                    "chunk_id": cid,
                    "symbol": it.get("symbol_name") or it.get("symbol"),
                    "hop": it.get("hop"),
                    "score": it.get("score"),
                    "_needs_hydration": True,
                })
            if not out:
                out.append({"loc": "(0 dependents)", "symbol": "empty"})
    return out


# --------------------------------------------------------------------------
# Relevance judges — per case, assign exact / related / miss
# --------------------------------------------------------------------------

GSC_EXPECTED_PATHS = (
    "p8_analytics_pull.py",
    "gsc_task",
    "p8_daily_report.py",
    "p8_opportunity_scorer.py",
)


def judge_find_definitions(hits):
    resolved = {h["symbol"] for h in hits if h.get("chunk_id")}
    if {"detect_keyword_cannibalization", "pull_gsc"} <= resolved:
        return "exact"
    if resolved:
        return "related"
    return "miss"


def judge_find_usages(hits):
    if not hits:
        return "miss"
    callers = {h.get("symbol") or "" for h in hits}
    if any(s in callers for s in ("pull_fleet", "main")) or any(
        "test_" in s for s in callers
    ):
        return "exact"
    return "related"


def judge_gsc_query(hits):
    if not hits:
        return "miss"
    locs = " ".join(h.get("loc") or "" for h in hits)
    if any(p in locs for p in GSC_EXPECTED_PATHS):
        return "exact"
    return "related"


def judge_neighbors(hits):
    if not hits:
        return "miss"
    resolved = [h for h in hits if h.get("chunk_id")]
    if resolved:
        return "exact"
    return "related"


# Canonical Vietnamese docs for "quy trình xuất bản bài viết lên wordpress"
# (article-to-WordPress publishing workflow). Verified by inspection: these
# docs contain the VN publishing SOPs under docs/.
VN_EXPECTED_PATHS = (
    "P8_AUTOPUBLISH_WORKFLOW",    # 'Quy trình tự động đăng bài WordPress' SOP
    "WORDPRESS_PIPELINE",         # PLAN_P8_WORDPRESS_PIPELINE_3TIER
    "AUDIT_5_MUC_WORDPRESS",      # WordPress automation audit
    "SOP_1MKT_VAN_HANH",          # daily-ops SOP (Vietnamese)
    "MOI_TRUONG_VAN_HANH",        # environments SOP (Vietnamese)
    "OPERATIONAL_WORKFLOW",       # ops workflow guide/one-pager
    "PIPELINE_INVENTORY",         # P8_PIPELINE_INVENTORY.md
)


def judge_vn_docs(hits):
    """exact = canonical VN publishing doc in top-5; related = some markdown
    doc hit; miss = nothing."""
    if not hits:
        return "miss"
    locs = " ".join(h.get("loc") or "" for h in hits)
    if any(p in locs for p in VN_EXPECTED_PATHS):
        return "exact"
    if any(".md" in (h.get("loc") or "") for h in hits):
        return "related"
    return "miss"


def judge_symbol_rank1(hits):
    """exact = detect_keyword_cannibalization def chunk is rank 1;
    related = its file appears in top-5; else miss."""
    if not hits:
        return "miss"
    if "p8_opportunity_scorer.py:162" in (hits[0].get("loc") or ""):
        return "exact"
    if any("p8_opportunity_scorer.py" in (h.get("loc") or "") for h in hits):
        return "related"
    return "miss"


def judge_impact(hits):
    """Seed = pull_fleet chunk (first pull_gsc usage); its only dependent
    should be `main`. exact = 'main' among dependents; related = other
    resolved dependents; miss = empty."""
    real = [h for h in hits if h.get("chunk_id")]
    if not real:
        return "miss"
    syms = {h.get("symbol") for h in real}
    if "main" in syms:
        return "exact"
    return "related"


def judge_records(hits):
    """exact = ≥1 record row; related = well-formed empty ledger; miss =
    nothing parseable."""
    if any(str(h.get("loc") or "").startswith("record:") for h in hits):
        return "exact"
    if hits:
        return "related"
    return "miss"


def judge_subjects(hits):
    """fast_understand probe: exact = ≥1 routed subject; related = answered
    but no subjects; miss = nothing."""
    real = [h for h in hits if not str(h.get("loc") or "").startswith("(")]
    if real:
        return "exact"
    if hits:
        return "related"
    return "miss"


# --- Parameterized judges for auto-derived cases --------------------------

def judge_defs_covering(expected):
    """exact = every requested symbol resolved to a chunk; related = some;
    miss = none."""
    want = set(expected)
    def f(hits):
        resolved = {h["symbol"] for h in hits if h.get("chunk_id")}
        if want <= resolved:
            return "exact"
        if resolved:
            return "related"
        return "miss"
    return f


def judge_nonempty(hits):
    """exact = ≥1 resolved hit. Only used where the swctx index proves
    incoming edges exist, so an empty answer is a genuine miss."""
    if any(h.get("chunk_id") for h in hits):
        return "exact"
    return "miss"


def judge_file_hit(path):
    """exact = the symbol's defining file appears in top-5; related = any
    hit; miss = none."""
    def f(hits):
        if not hits:
            return "miss"
        if any(path in (h.get("loc") or "") for h in hits[:5]):
            return "exact"
        return "related"
    return f


# --------------------------------------------------------------------------
# Benchmark suite
# --------------------------------------------------------------------------


def swctx_index_db(workspace):
    key = hashlib.sha256(os.path.realpath(workspace).encode()).hexdigest()[:12]
    return os.path.expanduser(f"~/.swctx/indexes/{key}/index.db")


def swctx_graph_seed(workspace):
    """First resolved 'calls' edge src_chunk from the swctx index DB."""
    db = swctx_index_db(workspace)
    if not os.path.exists(db):
        return None
    for uri in (f"file:{db}?mode=ro", f"file:{db}?immutable=1"):
        try:
            con = sqlite3.connect(uri, uri=True)
            row = con.execute(
                "SELECT src_chunk FROM edges "
                "WHERE dst_chunk IS NOT NULL AND kind='calls' "
                "ORDER BY id LIMIT 1"
            ).fetchone()
            con.close()
            if row:
                return row[0]
        except sqlite3.Error:
            continue
    return None


def first_chunk_id(hits):
    for h in hits:
        if h.get("chunk_id"):
            return h["chunk_id"]
    return None


CODE_LANGS = ("python", "swift", "typescript", "javascript", "tsx",
              "go", "rust")
# Function/type-level kinds — property_declaration names ("trimmed",
# "workflow") are ubiquitous identifiers that make weak probe cases.
PROBE_KINDS = ("function_declaration", "function_definition",
               "class_declaration", "class_definition")


def auto_probe_symbols(workspace, limit=8):
    """Probe symbols for --auto mode, derived from the swctx index:
    function/class-level symbols with resolved incoming `calls` edges —
    ground truth by construction. Distinctive names only: in-degree is
    capped so ubiquitous identifiers (in-degree in the thousands) don't
    become trivially-generic cases. Falls back to the unfiltered top list
    when a small workspace has no qualifying symbols."""
    db = swctx_index_db(workspace)
    if not os.path.exists(db):
        return []

    def query(con, kinds, lo, hi):
        kind_filter = ("AND s.kind IN (%s)"
                       % ",".join("?" * len(kinds))) if kinds else ""
        return con.execute("""
            SELECT s.name, MIN(f.path) AS path, COUNT(*) AS c
            FROM edges e
            JOIN chunks dc ON dc.id = e.dst_chunk
            JOIN symbols s ON s.chunk_id = dc.id
            JOIN files f ON f.id = s.file_id
            WHERE e.kind = 'calls' AND LENGTH(s.name) >= 8
              AND f.lang IN (%s) %s
              AND f.path NOT LIKE 'vendors/%%'
              AND f.path NOT LIKE 'vendor/%%'
              AND f.path NOT LIKE '%%/archive/%%'
              AND f.path NOT LIKE 'archive/%%'
              AND f.path NOT LIKE '%%/_legacy/%%'
              AND f.path NOT LIKE 'node_modules/%%'
              AND f.path NOT LIKE 'outputs/%%'
            GROUP BY s.name HAVING c BETWEEN ? AND ?
            ORDER BY c DESC LIMIT ?
            """ % (",".join("?" * len(CODE_LANGS)), kind_filter),
            (*CODE_LANGS, *kinds, lo, hi, limit)).fetchall()

    rows = []
    for uri in (f"file:{db}?mode=ro", f"file:{db}?immutable=1"):
        try:
            con = sqlite3.connect(uri, uri=True)
            rows = query(con, PROBE_KINDS, 3, 200)
            if not rows:
                rows = query(con, (), 2, 10000)   # small-workspace fallback
            con.close()
            break
        except sqlite3.Error:
            continue
    stop = {"main", "init", "setup", "render", "update", "create"}
    return [(n, p, c) for n, p, c in rows if n.lower() not in stop]


def auto_cases(workspace, syms=None):
    """Workspace-agnostic suite: symbols, dirs and ground truth are derived
    from the swctx index itself, so any indexed workspace can be benched.
    Cases where a seed cannot be derived are skipped by the runner."""
    if syms is None:
        syms = auto_probe_symbols(workspace)
    name0, file0 = (syms[0][0], syms[0][1]) if syms else (None, None)
    dir0 = file0.split("/")[0] if file0 and "/" in file0 else (file0 or "")
    query0 = name0.replace("_", " ") if name0 else ""
    ws_name = os.path.basename(workspace.rstrip("/"))
    cases = [
        {
            "id": "find_definitions",
            "desc": f"resolve auto-picked symbols {[s[0] for s in syms[:2]]}",
            "judge": judge_defs_covering([s[0] for s in syms[:2]]),
            "swctx": ("find_definitions", {
                "workspace": workspace,
                "symbols": [s[0] for s in syms[:2]],
                "include_content": False,
            }) if syms else None,
            "ctxe": ("find_definitions", {
                "workspace": workspace,
                "symbols": [s[0] for s in syms[:2]],
                "include_content": False,
            }) if syms else None,
        },
        {
            "id": "find_usages",
            "desc": f"callers of '{name0}' (in-degree {syms[0][2] if syms else 0})",
            "judge": judge_nonempty,
            "swctx": ("find_usages", {
                "workspace": workspace, "symbol_name": name0,
                "include_content": False, "limit": 10,
            }) if name0 else None,
            "ctxe": ("find_usages", {
                "workspace": workspace, "symbol_name": name0,
                "include_content": False, "limit": 10,
            }) if name0 else None,
        },
        {
            # swctx searches workspace-wide; ctxe's local equivalent is
            # path-scoped inspect_path -> scope both to the def file's dir.
            "id": "search_symbol",
            "desc": f"query '{query0}' — expect {file0} in top-5",
            "judge": judge_file_hit(file0 or ""),
            "swctx": ("search", {
                "workspace": workspace, "query": query0, "limit": 10,
            }) if name0 else None,
            "ctxe": ("inspect_path", {
                "workspace": workspace, "path": dir0,
                "query": query0, "include_content": False, "limit": 10,
            }) if name0 else None,
            "note": "surface mismatch: ctxe has no bare search; "
                    "inspect_path scoped to the def file's dir",
        },
        {
            "id": "inspect_path",
            "desc": f"path='{dir0}' query='{name0}'",
            "judge": judge_file_hit(file0 or ""),
            "swctx": ("inspect_path", {
                "workspace": workspace, "path": dir0,
                "query": name0, "include_content": False, "limit": 10,
            }) if name0 else None,
            "ctxe": ("inspect_path", {
                "workspace": workspace, "path": dir0,
                "query": name0, "include_content": False, "limit": 10,
            }) if name0 else None,
        },
        {
            "id": "graph_neighbors",
            "desc": "1-hop neighbors of a resolved seed chunk",
            "judge": judge_neighbors,
            "swctx": ("graph_neighbors", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("swctx_seed"),
                "direction": "outgoing", "limit": 10,
            }),
            "ctxe": ("graph_neighbors", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("ctxe_seed"),
                "direction": "incoming",
                "include_content": False, "limit": 10,
            }),
        },
        {
            "id": "get_impact",
            "desc": "dependents of find_usages[0] chunk, max_hops=2",
            "judge": judge_neighbors,
            "hydrate": True,
            "swctx": ("get_impact", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("swctx_usage_seed"),
                "max_hops": 2,
            }),
            "ctxe": ("get_impact", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("ctxe_usage_seed"),
                "max_hops": 2,
            }),
        },
        {
            "id": "graph_expand",
            "desc": "seeded graph expansion (seeds=[{chunk_id,score}])",
            "judge": judge_neighbors,
            "hydrate": True,
            "swctx": lambda ctx: (
                "graph_expand", graph_expand_args(ctx, "swctx")),
            "ctxe": lambda ctx: (
                "graph_expand", graph_expand_args(ctx, "ctxe")),
        },
        {
            "id": "records_probe",
            "desc": "workspace records ledger (list_records on both)",
            "judge": judge_records,
            "swctx": lambda ctx: records_args(ctx, "swctx"),
            "ctxe": lambda ctx: records_args(ctx, "ctxe"),
        },
        {
            "id": "fast_understand",
            "desc": "understand-brief parity (ctxe LLM two-pass vs swctx "
                    "deterministic digest)",
            "judge": judge_subjects,
            "timeout": 300,
            "swctx": lambda ctx: (
                "fast_understand",
                schema_args(ctx, "swctx", "fast_understand",
                            f"main modules and entry points of {ws_name}")),
            "ctxe": lambda ctx: (
                "fast_understand",
                schema_args(ctx, "ctxe", "fast_understand",
                            f"main modules and entry points of {ws_name}")),
        },
    ]
    return [c for c in cases if c.get("swctx") is not None
            or c.get("ctxe") is not None]



def hydrate_hits(session, workspace, hits, cap=20):
    """Untimed fetch_chunks pass filling loc/symbol for hits whose payload
    only carried a bare chunk_id (marked `_needs_hydration` by extract()).
    Keeps get_impact/graph_expand dependent sets comparable across servers."""
    need = [h["chunk_id"] for h in hits
            if h.get("chunk_id") and h.get("_needs_hydration")]
    for h in hits:
        h.pop("_needs_hydration", None)
    if not need:
        return
    payload, _, err = session.call_tool(
        "fetch_chunks",
        {"workspace": workspace, "chunk_ids": need[:cap],
         "include_content": False},
        retries=0)
    if err or not payload:
        return
    meta = {}
    for c in payload.get("chunks", []) or payload.get("items", []):
        cid = c.get("chunk_id") or c.get("id")
        if cid is None:
            continue
        path = c.get("file_path") or c.get("path")
        line = c.get("start_line")
        sym = c.get("symbol_name") or c.get("symbol")
        meta[cid] = (f"{path}:{line}" if path else None, sym)
    for h in hits:
        m = meta.get(h.get("chunk_id"))
        if not m:
            continue
        loc, sym = m
        if loc and str(h.get("loc") or "").startswith("chunk:"):
            h["loc"] = loc
        if sym and not h.get("symbol"):
            h["symbol"] = sym


QUERY_LIKE_PARAMS = ("query", "request", "objective", "question",
                     "task", "prompt", "text")


def _schema_props(schema):
    """Normalize tool inputSchema -> {param: propdef}. ctxe uses JSON-Schema
    `properties`; swctx flattens prop defs to the schema's top level."""
    props = schema.get("properties")
    if isinstance(props, dict) and props:
        return props
    return {k: v for k, v in (schema or {}).items() if isinstance(v, dict)}


def schema_args(ctx, server, tool, query):
    """Build minimal args from the server's live inputSchema: required
    `workspace` gets the workspace path; other required params and any
    declared query-like param get the probe query string."""
    schema = (ctx.get("_schemas") or {}).get(server, {}).get(tool, {})
    props = _schema_props(schema)
    req = schema.get("required") or []
    args = {}
    for p in req:
        args[p] = ctx["_workspace"] if p == "workspace" else query
    for p in QUERY_LIKE_PARAMS:
        if p in props:
            args.setdefault(p, query)
    if "workspace" in props:
        args.setdefault("workspace", ctx["_workspace"])
    return args or {"workspace": ctx["_workspace"], "query": query}


def graph_expand_args(ctx, server):
    """Seed = first pull_gsc usage chunk. Both engines take
    seeds=[{chunk_id, score?}]; any other schema falls back to chunk_id."""
    seed = ctx.get(f"{server}_usage_seed")
    if seed is None:
        return {"chunk_id": None}
    schema = (ctx.get("_schemas") or {}).get(server, {}).get("graph_expand", {})
    props = _schema_props(schema)
    args = {"workspace": ctx["_workspace"]}
    if "seeds" in props or "seeds" in (schema.get("required") or []):
        args["seeds"] = [{"chunk_id": seed, "score": 1.0}]
        if "mode" in props:
            args["mode"] = "related"
        if "include_content" in props:
            args["include_content"] = False
    else:
        args["chunk_id"] = seed
    return args


def records_args(ctx, server):
    """Pick the first records-ledger tool the server actually exposes."""
    tools = (ctx.get("_schemas") or {}).get(server, {})
    for cand in ("list_records", "records", "list_workspace_records"):
        if cand in tools:
            props = _schema_props(tools[cand])
            args = {"workspace": ctx["_workspace"]}
            if "limit" in props:
                args["limit"] = 5
            return cand, args
    return "list_records", {"workspace": ctx["_workspace"], "limit": 5}


VN_QUERY = "quy trình xuất bản bài viết lên wordpress"
FU_QUERY = ("how does the GSC analytics pull pipeline work in "
            "scripts/p8_analytics_pull.py")


def build_cases(workspace):
    """Case specs. args may be a dict or a callable(ctx) -> dict so seeds can
    be resolved lazily after earlier cases ran."""
    q_gsc = "aggregate GSC impressions and clicks by page"
    return [
        {
            "id": "find_definitions",
            "desc": "resolve 2 known symbols",
            "judge": judge_find_definitions,
            "swctx": ("find_definitions", {
                "workspace": workspace,
                "symbols": ["detect_keyword_cannibalization", "pull_gsc"],
                "include_content": False,
            }),
            "ctxe": ("find_definitions", {
                "workspace": workspace,
                "symbols": ["detect_keyword_cannibalization", "pull_gsc"],
                "include_content": False,
            }),
        },
        {
            "id": "find_usages",
            "desc": "callers of pull_gsc",
            "judge": judge_find_usages,
            "swctx": ("find_usages", {
                "workspace": workspace,
                "symbol_name": "pull_gsc",
                "include_content": False,
                "limit": 10,
            }),
            "ctxe": ("find_usages", {
                "workspace": workspace,
                "symbol_name": "pull_gsc",
                "include_content": False,
                "limit": 10,
            }),
        },
        {
            "id": "inspect_path",
            "desc": f"path='scripts' query='{q_gsc}'",
            "judge": judge_gsc_query,
            "swctx": ("inspect_path", {
                "workspace": workspace, "path": "scripts",
                "query": q_gsc, "include_content": False, "limit": 10,
            }),
            "ctxe": ("inspect_path", {
                "workspace": workspace, "path": "scripts",
                "query": q_gsc, "include_content": False, "limit": 10,
            }),
        },
        {
            # ctxe has no workspace-wide `search`; inspect_path is the closest
            # free/local equivalent but is path-scoped. ask_context is skipped
            # (server-backed planner, consumes credits).
            "id": "search_equiv",
            "desc": "swctx search (workspace-wide) vs ctxe inspect_path "
                    "path='scripts' (closest local equivalent)",
            "judge": judge_gsc_query,
            "swctx": ("search", {
                "workspace": workspace,
                "query": "detect keyword cannibalization from GSC "
                         "query-level data",
                "limit": 10,
            }),
            "ctxe": ("inspect_path", {
                "workspace": workspace, "path": "scripts",
                "query": "detect keyword cannibalization from GSC "
                         "query-level data",
                "include_content": False, "limit": 10,
            }),
            "note": "surface mismatch: ctxe has no bare search; "
                    "ask_context skipped (credit/server-backed)",
        },
        {
            "id": "graph_neighbors",
            "desc": "1-hop neighbors of a resolved seed chunk",
            "judge": judge_neighbors,
            "swctx": ("graph_neighbors", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("swctx_seed"),
                "direction": "outgoing", "limit": 10,
            }),
            "ctxe": ("graph_neighbors", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("ctxe_seed"),
                "direction": "incoming",
                "include_content": False, "limit": 10,
            }),
        },
        {
            # Vietnamese-language doc retrieval. Both sides are scoped to
            # docs/ (ctxe inspect_path cannot search workspace-wide).
            "id": "vn_docs_hybrid",
            "desc": f"VN doc query scoped to docs/: '{VN_QUERY}'",
            "judge": judge_vn_docs,
            "swctx": ("search", {
                "workspace": workspace, "query": VN_QUERY,
                "mode": "hybrid", "path": "docs", "limit": 10,
            }),
            "ctxe": ("inspect_path", {
                "workspace": workspace, "path": "docs",
                "query": VN_QUERY, "include_content": False, "limit": 10,
            }),
            "note": "honest multilingual probe: swctx embeds with "
                    "English-only bge-base-en-v1.5; ctxe embeds "
                    "server-side. Hybrid mode lets FTS tokens carry "
                    "swctx; ctxe rerank may blend lexical pool + "
                    "semantic ordering.",
        },
        {
            # Same query, swctx semantic-only — isolates embedding quality.
            # (semantic mode honors `path` since the dispatch fix; both sides
            # are docs-scoped here.)
            "id": "vn_docs_semantic",
            "desc": f"same VN query, swctx mode=semantic, path=docs",
            "judge": judge_vn_docs,
            "swctx": ("search", {
                "workspace": workspace, "query": VN_QUERY,
                "mode": "semantic", "path": "docs", "limit": 10,
            }),
            "ctxe": ("inspect_path", {
                "workspace": workspace, "path": "docs",
                "query": VN_QUERY, "include_content": False, "limit": 10,
            }),
            "note": "embedding-isolation probe: bge-base-en (en-only) vs "
                    "ctxe server embeddings on Vietnamese text.",
        },
        {
            # Exact-symbol query — both should rank the def chunk #1.
            "id": "exact_symbol_hybrid",
            "desc": "exact-symbol query 'detect_keyword_cannibalization' — "
                    "expect p8_opportunity_scorer.py:162 at rank 1",
            "judge": judge_symbol_rank1,
            "swctx": ("search", {
                "workspace": workspace,
                "query": "detect_keyword_cannibalization",
                "limit": 10,
            }),
            "ctxe": ("inspect_path", {
                "workspace": workspace, "path": "scripts",
                "query": "detect_keyword_cannibalization",
                "include_content": False, "limit": 10,
            }),
        },
        {
            # Seed = usages[0] chunk of pull_gsc (the pull_fleet chunk).
            # Its dependents should be {main}. ctxe get_impact returns bare
            # chunk_ids — hydrated via fetch_chunks for comparability.
            "id": "get_impact",
            "desc": "dependents of find_usages[0] chunk (pull_fleet), "
                    "max_hops=2 — expect 'main'",
            "judge": judge_impact,
            "hydrate": True,
            "swctx": ("get_impact", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("swctx_usage_seed"),
                "max_hops": 2,
            }),
            "ctxe": ("get_impact", lambda ctx: {
                "workspace": workspace,
                "chunk_id": ctx.get("ctxe_usage_seed"),
                "max_hops": 2,
            }),
        },
        {
            # Seeded expansion — both engines take seeds=[{chunk_id,score?}].
            # swctx: BFS depth<=2, decay 0.7^d, results carry hydrated chunk
            # meta. ctxe: mode=related bundles, bare ids -> hydrated here.
            "id": "graph_expand",
            "desc": "seeded graph expansion (seeds=[{chunk_id,score}] "
                    "on both)",
            "judge": judge_neighbors,
            "hydrate": True,
            "swctx": lambda ctx: (
                "graph_expand", graph_expand_args(ctx, "swctx")),
            "ctxe": lambda ctx: (
                "graph_expand", graph_expand_args(ctx, "ctxe")),
        },
        {
            # Workspace records ledger. ctxe persists ask records; swctx's
            # records table degrades to {"error": "records unavailable"}
            # until its migration exists — handled as a marked hit.
            "id": "records_probe",
            "desc": "workspace records ledger (list_records on both)",
            "judge": judge_records,
            "swctx": lambda ctx: records_args(ctx, "swctx"),
            "ctxe": lambda ctx: records_args(ctx, "ctxe"),
        },
        {
            # ctxe fast_understand = server-backed two-pass routing brief
            # (~57 s observed). swctx fast_understand = deterministic
            # no-LLM digest (counts/hubs/communities + top-5 relevant).
            "id": "fast_understand",
            "desc": "understand-brief parity (ctxe LLM two-pass vs swctx "
                    "deterministic digest)",
            "judge": judge_subjects,
            "timeout": 300,
            "swctx": lambda ctx: (
                "fast_understand",
                schema_args(ctx, "swctx", "fast_understand", FU_QUERY)),
            "ctxe": lambda ctx: (
                "fast_understand",
                schema_args(ctx, "ctxe", "fast_understand", FU_QUERY)),
        },
    ]


# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------


def run_case(case, server_name, session, ctx):
    spec = case.get(server_name)
    if spec is None or session is None:
        return {"case": case["id"], "server": server_name, "skipped": True,
                "reason": "server not available / no equivalent tool"}
    if callable(spec):
        tool, args = spec(ctx)
    else:
        tool, args = spec
        if callable(args):
            args = args(ctx)
    # Tool-missing -> n/a, not failure: parity tools land over time.
    if session.tools is not None and tool not in session.tools:
        return {"case": case["id"], "server": server_name, "tool": tool,
                "skipped": True, "status": "n/a",
                "reason": f"n/a: '{tool}' not in {server_name} registry"}
    if any(v is None for v in args.values()):
        return {"case": case["id"], "server": server_name, "tool": tool,
                "skipped": True, "reason": "seed could not be resolved"}
    payload, latency, err = session.call_tool(
        tool, args, timeout=case.get("timeout"))
    if err:
        return {"case": case["id"], "server": server_name, "tool": tool,
                "ok": False, "error": err}
    hits = extract(server_name, tool, payload)
    if case.get("hydrate"):
        hydrate_hits(session, args.get("workspace", ""), hits)
    for h in hits:
        h.pop("_needs_hydration", None)
    relevance = case["judge"](hits)
    return {
        "case": case["id"], "server": server_name, "tool": tool,
        "ok": True, "latency_ms": round(latency, 1),
        "relevance": relevance, "hits": _hits(hits),
        "hit_count": len(hits),
    }


def fmt_hit(h):
    sym = h.get("symbol") or "-"
    cid = h.get("chunk_id")
    return f"{h.get('loc','-')}  {sym}" + (f"  #{cid}" if cid else "")


def print_run(r):
    if r.get("skipped"):
        print(f"  {r['server']:>6}  -- skipped ({r.get('reason','')})")
        return
    if not r.get("ok"):
        print(f"  {r['server']:>6}  !! error: {r.get('error')}")
        return
    print(f"  {r['server']:>6}  {r['latency_ms']:>8.1f} ms  [{r['relevance']}]")
    for i, h in enumerate(r["hits"], 1):
        print(f"         {i}. {fmt_hit(h)}")


def markdown_table(results):
    lines = [
        "| Case | Tool | Server | Latency (ms) | Top hits | Relevance |",
        "|---|---|---|---:|---|---|",
    ]
    for r in results:
        if r.get("skipped"):
            label = "n/a" if r.get("status") == "n/a" else "skipped"
            lines.append(
                f"| {r['case']} | {r.get('tool') or '-'} | {r['server']} | - "
                f"| {label}: {r.get('reason','')} | - |")
            continue
        if not r.get("ok"):
            lines.append(
                f"| {r['case']} | {r.get('tool','?')} | {r['server']} | - "
                f"| ERROR: {r.get('error','')} | miss |")
            continue
        tops = "<br>".join(
            f"`{h.get('loc','-')}` {h.get('symbol') or ''}".strip()
            for h in r["hits"][:3]
        )
        lines.append(
            f"| {r['case']} | {r['tool']} | {r['server']} "
            f"| {r['latency_ms']} | {tops} | {r['relevance']} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="swctx vs ctxe MCP benchmark")
    ap.add_argument("--workspace", default=DEFAULT_WORKSPACE)
    ap.add_argument("--swctx-bin", default=DEFAULT_SWCTX_BIN)
    ap.add_argument("--ctxe-bin", default="ctxe")
    ap.add_argument("--skip-ctxe", action="store_true")
    ap.add_argument("--skip-swctx", action="store_true")
    ap.add_argument("--auto", action="store_true",
                    help="Derive cases from the workspace index instead of "
                         "the P8-curated suite (default when --workspace is "
                         "not the P8 default)")
    ap.add_argument("--timeout", type=int, default=120,
                    help="per-call timeout seconds")
    ap.add_argument("--out", default=os.path.join(HERE, "results.json"))
    args = ap.parse_args()

    sessions = {}
    blockers = {}
    for name, argv in (
        ("swctx", [args.swctx_bin, "mcp"]),
        ("ctxe", [args.ctxe_bin, "mcp"]),
    ):
        if (name == "swctx" and args.skip_swctx) or \
           (name == "ctxe" and args.skip_ctxe):
            blockers[name] = "skipped by flag"
            continue
        try:
            s = MCPSession(name, argv, timeout=args.timeout)
            s.start()
            # Warmup + readiness check (untimed): also absorbs ctxe's cold
            # "runtime acquisition" spin-up.
            payload, _, err = s.call_tool(
                "get_status", {"workspace": args.workspace})
            if err:
                blockers[name] = f"get_status failed: {err}"
                s.stop()
                continue
            sessions[name] = s
            ver = (s.server_info or {}).get("version", "?")
            print(f"[bench] {name} mcp up (server v{ver})", file=sys.stderr)
        except FileNotFoundError:
            blockers[name] = f"binary not found: {argv[0]}"
        except Exception as e:  # noqa: BLE001
            blockers[name] = f"spawn/handshake failed: {e}"

    for n, b in blockers.items():
        print(f"[bench] {n}: {b}", file=sys.stderr)
    if not sessions:
        print("[bench] no servers available — aborting", file=sys.stderr)
        sys.exit(2)

    auto = args.auto or os.path.realpath(args.workspace) != os.path.realpath(
        DEFAULT_WORKSPACE)
    probes = auto_probe_symbols(args.workspace) if auto else []
    cases = (auto_cases(args.workspace, probes) if auto
             else build_cases(args.workspace))
    if auto:
        print(f"[bench] auto mode — probe symbols: "
              f"{[s[0] for s in probes[:3]] or 'none found'}",
              file=sys.stderr)
    ctx = {
        "swctx_seed": swctx_graph_seed(args.workspace),
        "_workspace": args.workspace,
        "_probe_symbol": probes[0][0] if probes else "pull_gsc",
        "_schemas": {n: (s.tools or {}) for n, s in sessions.items()},
    }
    results = []

    for case in cases:
        print(f"\n== {case['id']} — {case['desc']}")
        for name in ("swctx", "ctxe"):
            r = run_case(case, name, sessions.get(name), ctx)
            results.append(r)
            print_run(r)
            # resolve ctxe seed lazily from its own returned ids —
            # prefer the probed symbol's definition chunk (known to have
            # callers)
            if (name == "ctxe" and r.get("ok")
                    and ctx.get("ctxe_seed") is None
                    and case["id"] in ("find_definitions", "find_usages")):
                preferred = [h for h in r["hits"]
                             if h.get("symbol") == ctx.get("_probe_symbol")
                             and h.get("chunk_id")]
                ctx["ctxe_seed"] = (preferred[0]["chunk_id"] if preferred
                                    else first_chunk_id(r["hits"]))
            # per-server impact/expand seed: first resolved usage chunk of
            # pull_gsc (typically the pull_fleet chunk)
            if (r.get("ok") and case["id"] == "find_usages"
                    and ctx.get(f"{name}_usage_seed") is None):
                cid = first_chunk_id(r["hits"])
                if cid is not None:
                    ctx[f"{name}_usage_seed"] = cid

    for s in sessions.values():
        s.stop()

    doc = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "workspace": args.workspace,
        "servers": {
            n: {"argv": s.argv, "server_info": s.server_info,
                "tools": sorted(s.tools) if s.tools else None}
            for n, s in sessions.items()
        },
        "blockers": blockers,
        "seeds": {k: v for k, v in ctx.items() if not k.startswith("_")},
        "notes": {
            "ctxe_search": "ctxe has no bare `search`; inspect_path used as "
                           "closest local equivalent. ask_context skipped "
                           "(server-backed, consumes credits).",
            "swctx_ask": "swctx has no ask_context (context_pack is its "
                         "local analogue; not benchmarked).",
        },
        "results": results,
    }
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=2)
    print(f"\n[bench] wrote {args.out}\n")
    print(markdown_table(results))


if __name__ == "__main__":
    main()
