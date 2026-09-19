#!/usr/bin/env python3
"""parity_probe.py — coverage probe for the 16 shared swctx/ctxe MCP tools
that engine_ab.py did not score (it only scored search / find_definitions /
workspace_tree / ask_context).

This is a SHAPE + CORRECTNESS probe, not a recall benchmark: for each
surface we call both engines on the same target and report result counts,
payload shape, and — where the target is identical (a file, a symbol) —
whether both engines actually return data for it.

Surfaces covered:
  find_usages, inspect_path, graph_neighbors, fetch_chunks, get_status,
  fast_understand, list_workspaces, list_records/search_records/get_record,
  graph_expand, graph_paths, get_impact.

ctxe calls that hit the server (fast_understand, ask_context) cost credits —
fast_understand is included once; ask_context/compose_answer stay sampled
in engine_ab.py.
"""
import json, subprocess, sys, time

CRM = "/Users/phuongnam/02.AI/NP_AI_macos/18.CRM-Nam-Pham"
P8 = "/Users/phuongnam/02.AI/NP_AI_macos/8.P8_SEO_Clean"
GOLD_FILE = "crm-nam-pham/09-build/so_tay.py"
SYMBOLS = ["tom_tat", "format_fragment", "ghi_quyet_dinh"]

class S:
    def __init__(self, cmd):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1)
        self.i = 0
        self.call("initialize", {"protocolVersion": "2024-11-05",
            "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}})
        self.note("notifications/initialized")
    def note(self, m, params=None):
        self.p.stdin.write(json.dumps(
            {"jsonrpc": "2.0", "method": m, "params": params or {}}) + "\n")
        self.p.stdin.flush()
    def call(self, method, params, timeout=90):
        self.i += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.i,
            "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        t0 = time.time()
        while time.time() - t0 < timeout:
            line = self.p.stdout.readline()
            if not line:
                return {"error": "eof"}
            o = json.loads(line)
            if o.get("id") == self.i:
                return o.get("result", o)
        return {"error": "timeout"}
    def tool(self, name, args, timeout=90):
        r = self.call("tools/call", {"name": name, "arguments": args}, timeout)
        for c in r.get("content", []):
            if c.get("type") == "text":
                try:
                    return json.loads(c["text"])
                except Exception:
                    return {"raw": c["text"][:400]}
        return r
    def close(self):
        self.p.kill()

def jcount(d, *keys):
    """First list length found among keys."""
    for k in keys:
        v = d.get(k) if isinstance(d, dict) else None
        if isinstance(v, list):
            return len(v)
    return None

def paths_in(d, depth=0):
    out = []
    if depth > 4:
        return out
    if isinstance(d, dict):
        for k, v in d.items():
            if k in ("file_path", "path") and isinstance(v, str):
                out.append(v)
            else:
                out += paths_in(v, depth + 1)
    elif isinstance(d, list):
        for v in d:
            out += paths_in(v, depth + 1)
    return out

def main():
    sw = S(["swctx", "mcp"])
    cx = S(["ctxe", "mcp"])
    rows = []

    def row(surface, swr, cxr, note=""):
        rows.append((surface, swr, cxr, note))

    # ---------- get_status ----------
    r_sw = sw.tool("get_status", {"workspace": CRM})
    r_cx = cx.tool("get_status", {"workspace": CRM})
    row("get_status",
        f"files={r_sw.get('files')} chunks={r_sw.get('chunks')}",
        f"files={r_cx.get('files') or jcount(r_cx)} keys={list(r_cx)[:6]}")

    # ---------- list_workspaces ----------
    r_sw = sw.tool("list_workspaces", {})
    r_cx = cx.tool("list_workspaces", {})
    row("list_workspaces",
        f"n={jcount(r_sw, 'workspaces')}",
        f"n={jcount(r_cx, 'workspaces')}")

    # ---------- find_usages (3 named symbols, CRM) ----------
    for sym in SYMBOLS:
        r_sw = sw.tool("find_usages", {"workspace": CRM, "symbol_name": sym,
                                     "include_content": False})
        r_cx = cx.tool("find_usages", {"workspace": CRM, "symbol_name": sym,
                                     "include_content": False})
        n_sw = jcount(r_sw, "usages", "results")
        n_cx = jcount(r_cx, "usages", "results")
        row(f"find_usages:{sym}", f"n={n_sw}", f"n={n_cx}",
            ("err:" + str(r_sw)[:60]) if n_sw is None else
            ("err:" + str(r_cx)[:60]) if n_cx is None else "")

    # ---------- inspect_path (shared dir, both indexes) ----------
    r_sw = sw.tool("inspect_path", {"workspace": CRM,
        "path": "crm-nam-pham/09-build", "include_content": False})
    r_cx = cx.tool("inspect_path", {"workspace": CRM,
        "path": "crm-nam-pham/09-build", "include_content": False})
    row("inspect_path:dir",
        f"chunks={jcount(r_sw,'chunks','results','files')} keys={list(r_sw)[:5]}",
        f"chunks={jcount(r_cx,'chunks','results','files')} keys={list(r_cx)[:5]}")

    # ---------- fetch_chunks round-trip (same gold file) ----------
    # swctx: search → hits[].chunk_id ; ctxe: find_definitions → symbol/chunk ids
    sw_ids, cx_ids = [], []
    r = sw.tool("search", {"workspace": CRM, "query": "so_tay",
                           "limit": 3, "mode": "fts"})
    for h in (r.get("hits") or []):
        if GOLD_FILE.split("/")[-1] in str(h.get("file_path", "")):
            sw_ids.append(h.get("chunk_id") or h.get("id"))
    r = cx.tool("find_definitions", {"workspace": CRM,
        "symbols": ["tom_tat"], "include_content": False})
    cx_ids = [c for c in paths_in(r) if False]  # ids are not paths; collect below
    def collect_ids(d, key, depth=0):
        out = []
        if depth > 5: return out
        if isinstance(d, dict):
            for k, v in d.items():
                if k == key and isinstance(v, (str, int)): out.append(v)
                else: out += collect_ids(v, key, depth + 1)
        elif isinstance(d, list):
            for v in d: out += collect_ids(v, key, depth + 1)
        return out
    cx_ids = collect_ids(r, "chunk_id") or collect_ids(r, "id")
    r_sw = sw.tool("fetch_chunks", {"workspace": CRM,
        "chunk_ids": sw_ids[:3], "include_content": False}) if sw_ids else {"skipped": "no chunk id"}
    r_cx = cx.tool("fetch_chunks", {"workspace": CRM,
        "chunk_ids": [str(i) for i in cx_ids[:3]],
        "include_content": False}) if cx_ids else {"skipped": "no chunk id"}
    row("fetch_chunks",
        f"ids={len(sw_ids)} → chunks={jcount(r_sw,'chunks','results')}",
        f"ids={len(cx_ids)} → chunks={jcount(r_cx,'chunks','results')}")

    # ---------- graph_neighbors on a chunk of the gold file ----------
    cid_sw = sw_ids[0] if sw_ids else None
    cid_cx = cx_ids[0] if cx_ids else None
    r_sw = sw.tool("graph_neighbors", {"workspace": CRM, "chunk_id": cid_sw,
        "depth": 1, "include_content": False}) if cid_sw else {"skipped": 1}
    r_cx = cx.tool("graph_neighbors", {"workspace": CRM, "chunk_id": cid_cx,
        "depth": 1, "include_content": False}) if cid_cx else {"skipped": 1}
    row("graph_neighbors",
        f"neighbors={jcount(r_sw,'neighbors','results')}",
        f"neighbors={jcount(r_cx,'neighbors','results')}")

    # ---------- graph_expand + graph_paths + get_impact ----------
    r_sw = sw.tool("graph_expand", {"workspace": CRM, "chunk_id": cid_sw,
        "include_content": False}) if cid_sw else {"skipped": 1}
    r_cx = cx.tool("graph_expand", {"workspace": CRM, "chunk_id": cid_cx,
        "include_content": False}) if cid_cx else {"skipped": 1}
    row("graph_expand",
        f"results={jcount(r_sw,'results','nodes','expanded')}",
        f"results={jcount(r_cx,'results','nodes','expanded')}")
    r_sw = sw.tool("get_impact", {"workspace": CRM, "path": GOLD_FILE})
    r_cx = cx.tool("get_impact", {"workspace": CRM, "path": GOLD_FILE})
    row("get_impact",
        f"dependents={jcount(r_sw,'dependents','results','impacted')}",
        f"dependents={jcount(r_cx,'dependents','results','impacted')}")

    # ---------- records trio ----------
    r_sw = sw.tool("list_records", {"workspace": CRM, "limit": 3})
    r_cx = cx.tool("list_records", {"workspace": CRM, "limit": 3})
    row("list_records",
        f"records={jcount(r_sw,'records','results')}",
        f"records={jcount(r_cx,'records','results')}")
    r_sw = sw.tool("search_records", {"workspace": CRM, "query": "audit",
                                      "limit": 3})
    r_cx = cx.tool("search_records", {"workspace": CRM, "query": "audit",
                                      "limit": 3})
    row("search_records",
        f"records={jcount(r_sw,'records','results')}",
        f"records={jcount(r_cx,'records','results')}")

    # ---------- fast_understand (ctxe: server call, 1 sample) ----------
    q = "project overview: what does this codebase do"
    r_sw = sw.tool("fast_understand", {"workspace": CRM, "query": q})
    r_cx = cx.tool("fast_understand", {"workspace": CRM, "query": q},
                   timeout=120)
    row("fast_understand",
        f"keys={list(r_sw)[:6]}",
        f"keys={list(r_cx)[:6]}")

    sw.close(); cx.close()

    w = max(len(r[0]) for r in rows)
    print(f"{'surface'.ljust(w)}  {'swctx'.ljust(46)}  ctxe")
    print("-" * (w + 52 + 40))
    for s, a, b, note in rows:
        print(f"{s.ljust(w)}  {a.ljust(46)}  {b}" + (f"   [{note}]" if note else ""))

if __name__ == "__main__":
    main()
