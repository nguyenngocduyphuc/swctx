"""MCP stdio server — swctx-py tools for agent CLIs."""
from __future__ import annotations

import json
import os
import time

from .indexer import Indexer
from .search import Searcher
from .store import CATALOG, Store


def _store(workspace: str, create: bool = False) -> Store:
    return Store(workspace, create=create)


def _j(x) -> str:
    return json.dumps(x, ensure_ascii=False, indent=1, default=str)


def tool_defs() -> list[dict]:
    ws = {"type": "string", "description": "absolute workspace path"}
    return [
        {"name": "get_status", "description": "Index state, counts, freshness.",
         "inputSchema": {"type": "object", "properties": {"workspace": ws},
                         "required": ["workspace"]}},
        {"name": "list_workspaces", "description": "Indexed workspace registry.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "index_workspace", "description": "Create/update index (mutating).",
         "inputSchema": {"type": "object", "properties": {"workspace": ws},
                         "required": ["workspace"]}},
        {"name": "search", "description": "Hybrid semantic+lexical search. The primary retrieval tool.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "query": {"type": "string"},
             "limit": {"type": "integer", "default": 10}},
             "required": ["workspace", "query"]}},
        {"name": "fetch_chunks", "description": "Fetch full chunk bodies by id.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "chunk_ids": {"type": "array", "items": {"type": "integer"}}},
             "required": ["workspace", "chunk_ids"]}},
        {"name": "find_definitions", "description": "Exact symbol definitions.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "name": {"type": "string"}},
             "required": ["workspace", "name"]}},
        {"name": "find_usages", "description": "Chunks referencing a symbol name.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "name": {"type": "string"}},
             "required": ["workspace", "name"]}},
        {"name": "workspace_tree", "description": "Directory tree of the workspace.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "depth": {"type": "integer", "default": 3}},
             "required": ["workspace"]}},
        {"name": "prime", "description": "Compact orientation card — call first each session.",
         "inputSchema": {"type": "object", "properties": {"workspace": ws},
                         "required": ["workspace"]}},
        {"name": "search_records", "description": "Search durable records/usage history.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "query": {"type": "string"}},
             "required": ["workspace", "query"]}},
        {"name": "simulate_patch",
         "description": "Pre-flight a unified diff: declarations changed/removed plus every indexed caller/implementer/test that would break — before writing the patch.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "diff": {"type": "string", "description": "Unified-diff text"},
             "diff_file": {"type": "string", "description": "Path to .diff/.patch"},
             "max_callers": {"type": "integer", "default": 50}},
             "required": ["workspace"]}},
        {"name": "test_coverage",
         "description": "Static test<->symbol map over call edges. symbol_name -> test chunks that exercise it; path -> non-test symbols that file covers.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "symbol_name": {"type": "string"},
             "path": {"type": "string",
                      "description": "test file — lists covered symbols"},
             "limit": {"type": "integer", "default": 50}},
             "required": ["workspace"]}},
    ]


def call(name: str, args: dict) -> str:
    ws = args.get("workspace", "")
    if name == "list_workspaces":
        cat = json.loads(CATALOG.read_text()) if CATALOG.exists() else {}
        return _j([{"key": k, "path": v["path"],
                    "updated_at": v.get("updated_at")} for k, v in cat.items()])
    if name == "index_workspace":
        stats = Indexer(Store(ws)).run()
        return _j(stats)

    s = _store(ws)
    if name == "get_status":
        n_files = s.db.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        n_chunks = s.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        n_vec = s.db.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
        return _j({"workspace": ws, "key": s.key, "files": n_files,
                   "chunks": n_chunks, "embedded": n_vec,
                   "model": s.meta("embedding_model"),
                   "fts": s.fts_ok,
                   "last_index": s.meta("last_index")})
    if name == "search":
        return _j(Searcher(s).search(args["query"],
                                     int(args.get("limit", 10))))
    if name == "fetch_chunks":
        ids = [int(i) for i in args["chunk_ids"]]
        marks = ",".join("?" * len(ids))
        rows = s.db.execute(
            f"SELECT id,file_id,start_line,end_line,content FROM chunks "
            f"WHERE id IN ({marks})", ids).fetchall()
        s.log_event("fetch_chunks", "", arg_path="",
                    top_paths=";".join(r[1] for r in rows[:5]),
                    hit_count=len(rows))
        return _j([{"chunk_id": r[0], "path": r[1], "lines": [r[2], r[3]],
                    "content": r[4]} for r in rows])
    if name == "find_definitions":
        return _j(Searcher(s).find_definitions(args["name"]))
    if name == "find_usages":
        return _j(Searcher(s).find_usages(args["name"]))
    if name == "workspace_tree":
        depth = int(args.get("depth", 3))
        rows = [r[0] for r in s.db.execute("SELECT path FROM files")]
        return _j(_tree(rows, depth))
    if name == "prime":
        n_files = s.db.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        n_chunks = s.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        syms = [r[0] for r in s.db.execute(
            "SELECT name, COUNT(*) c FROM symbols GROUP BY name "
            "ORDER BY c DESC LIMIT 10")]
        langs = s.db.execute(
            "SELECT lang, COUNT(*) c FROM files GROUP BY lang "
            "ORDER BY c DESC LIMIT 8").fetchall()
        return (f"workspace: {ws}\nkey: {s.key}\nfiles: {n_files} "
                f"chunks: {n_chunks} model: {s.meta('embedding_model')}\n"
                f"langs: {langs}\nhub symbols: {syms}\n"
                f"last_index: {s.meta('last_index')}")
    if name == "search_records":
        q = f"%{args['query']}%"
        rows = s.db.execute(
            "SELECT kind,title,body,created_at FROM records "
            "WHERE title LIKE ? OR body LIKE ? "
            "ORDER BY (kind='commit'), id DESC LIMIT 20",
            (q, q)).fetchall()
        evs = s.db.execute(
            "SELECT tool,query,top_paths,hit_count,ts FROM usage_events "
            "WHERE query LIKE ? ORDER BY id DESC LIMIT 20", (q,)).fetchall()
        return _j({"records": rows, "usage": evs})
    if name == "simulate_patch":
        from . import simulate
        diff = args.get("diff") or ""
        if not diff and args.get("diff_file"):
            try:
                diff = open(args["diff_file"], encoding="utf-8").read()
            except OSError:
                return _j({"error": f"cannot read {args['diff_file']}"})
        if not diff.strip():
            return _j({"error": "missing diff or diff_file"})
        return _j(simulate.run(s, diff, int(args.get("max_callers", 50))))
    if name == "test_coverage":
        from . import coverage
        return _j(coverage.run(
            s, symbol_name=args.get("symbol_name"),
            path=args.get("path"),
            limit=int(args.get("limit", 50))))
    return _j({"error": f"unknown tool {name}"})


def _tree(paths: list[str], depth: int) -> dict:
    root: dict = {}
    for p in sorted(paths):
        parts = p.split("/")[:depth]
        node = root
        for part in parts:
            node = node.setdefault(part, {})
    return root


def serve() -> None:
    import asyncio
    import mcp.server.stdio
    import mcp.types as types
    from mcp.server.lowlevel import NotificationOptions, Server
    from mcp.server.models import InitializationOptions

    server = Server("swctx-py")

    @server.list_tools()
    async def _list():
        return [types.Tool(**t) for t in tool_defs()]

    @server.call_tool()
    async def _call(name: str, arguments: dict):
        import asyncio
        text = await asyncio.to_thread(call, name, arguments or {})
        return [types.TextContent(type="text", text=text)]

    async def _main():
        async with mcp.server.stdio.stdio_server() as (r, w):
            await server.run(r, w, InitializationOptions(
                server_name="swctx-py",
                server_version="0.1.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={})))
    asyncio.run(_main())
