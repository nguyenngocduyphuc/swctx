"""MCP stdio server — swctx-py tools for agent CLIs."""
from __future__ import annotations

import json
import os

from .indexer import Indexer
from .search import Searcher
from .store import CATALOG, Store, index_path


def _indexed_ancestor(d: str) -> str | None:
    """Nearest ancestor directory (starting at `d`) that already has an
    index — port of SwctxTools.indexedAncestor."""
    for _ in range(64):
        if index_path(d).exists():
            return d
        p = os.path.dirname(d)
        if len(p) >= len(d):
            return None
        d = p
    return None


def _resolve_workspace(ws: str | None,
                       use_workspace_root: bool = False) -> str:
    """`workspace` may be omitted, "auto" or ".": then the nearest indexed
    ancestor of the server process cwd wins. `use_workspace_root` does the
    same ancestor walk for an explicit nested path. Port of
    SwctxTools.workspace."""
    if ws is None or ws in ("", "auto", "."):
        cwd = os.path.realpath(os.getcwd())
        return _indexed_ancestor(cwd) or cwd
    if not os.path.isdir(ws):
        raise NotADirectoryError(
            f"workspace path is not a directory: {ws}")
    url = os.path.realpath(ws)
    if use_workspace_root:
        return _indexed_ancestor(url) or url
    return url


def _store(workspace: str, create: bool = False,
           use_workspace_root: bool = False) -> Store:
    return Store(_resolve_workspace(workspace, use_workspace_root),
                 create=create)


def _j(x) -> str:
    return json.dumps(x, ensure_ascii=False, indent=1, default=str)


def tool_defs() -> list[dict]:
    # Swift wsProp: `workspace` is never in `required` — omit/auto/./
    # resolve to the nearest indexed ancestor of the server cwd.
    ws = {"type": "string",
          "description": "Absolute project path; omit or \"auto\" to "
                         "resolve the nearest indexed ancestor of the "
                         "server process cwd"}
    uwr = {"type": "boolean",
           "description": "Resolve a nested path up to its indexed "
                          "workspace root"}
    return [
        {"name": "get_status", "description": "Index state, counts, freshness.",
         "inputSchema": {"type": "object", "properties": {"workspace": ws}}},
        {"name": "list_workspaces", "description": "Indexed workspace registry.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "index_workspace", "description": "Create/update index (mutating).",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "use_workspace_root": uwr}}},
        {"name": "search", "description": "Hybrid semantic+lexical search. The primary retrieval tool.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "query": {"type": "string"},
             "limit": {"type": "integer", "default": 10}},
             "required": ["query"]}},
        {"name": "answer",
         "description": "Local synthesis over verified evidence: packs cited chunks [E01]…, then asks the resolved backend for STRICT JSON {answer, citations, limitations}. Default backend auto: first usable fleet CLI (agy→codex→claude — subscription compose), else local Ollama. Server-side citation validation rejects ids outside the pack. No backend available → deterministic evidence pack + limitation, never an error. Writes a durable kind=ask record; response `backend` reports which one ran.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "query": {"type": "string",
                       "description": "Natural-language question about the codebase"},
             "model": {"type": "string",
                       "description": "Ollama model override (default qwen2.5:3b; env SWCTX_ANSWER_MODEL)"},
             "backend": {"type": "string", "default": "auto",
                         "description": "auto (default) — probe fleet CLIs agy→codex→claude (PATH + <cli> --version, first usable wins), else local 'ollama'. Explicit 'ollama' | 'cli:<name>' (cli:agy, cli:codex…) pins one. Env: SWCTX_ANSWER_BACKEND / SWCTX_ANSWER_CLI."},
             "timeout": {"type": "integer", "default": 60,
                         "description": "Per-attempt compose seconds (one format-retry allowed)"},
             "path": {"type": "string",
                      "description": "Optional relative path prefix filter for retrieval"},
             "expected_path": {"type": "string",
                               "description": "Eval-harness oracle path — recorded for scoring only, never shown to the model"},
             "max_tokens": {"type": "integer",
                            "description": "Optional response budget (~4 chars/token); arrays trim tail-first, meta.omitted reports drops. Hard cap ~64KB always applies"}},
             "required": ["query"]}},
        {"name": "fetch_chunks", "description": "Fetch full chunk bodies by id. mode=signature returns declaration lines only (~10% tokens).",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "mode": {"type": "string",
                      "description": "full (default) | signature"},
             "chunk_ids": {"type": "array", "items": {"type": "integer"}}},
             "required": ["chunk_ids"]}},
        {"name": "outline", "description": "One file -> symbol map (kind, lines, signature), no bodies.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "path": {"type": "string"}},
             "required": ["path"]}},
        {"name": "inspect_path",
         "description": "Browse indexed chunks under a relative file/directory path; optional query reranks them semantically.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "path": {"type": "string",
                      "description": "Relative file or directory path"},
             "query": {"type": "string",
                       "description": "Optional semantic rerank query"},
             "limit": {"type": "integer", "default": 50},
             "offset": {"type": "integer",
                        "description": "Pagination offset"},
             "rerank_pool_size": {"type": "integer", "default": 150,
                                  "description": "Query-mode candidate pool, max 500"},
             "include_content": {"type": "boolean", "default": False}},
             "required": ["path"]}},
        {"name": "graph_neighbors",
         "description": "Call/import graph neighbors of a chunk; BFS expansion when depth > 1.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "chunk_id": {"type": "integer", "description": "Seed chunk ID"},
             "edge_kinds": {"type": "array", "items": {"type": "string"},
                            "description": "Edge type filter"},
             "direction": {"type": "string",
                           "description": "incoming | outgoing | both"},
             "depth": {"type": "integer", "default": 1,
                       "description": "BFS hops, 1-3"},
             "limit": {"type": "integer", "default": 20},
             "include_content": {"type": "boolean", "default": False}},
             "required": ["chunk_id"]}},
        {"name": "graph_expand",
         "description": "BFS-expand a scored seed set through the resolved call/import graph (depth <= 2, cap 60). Results carry depth, via and decayed score.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "seeds": {"type": "array",
                       "description": "Non-empty array of {chunk_id, score?}"},
             "mode": {"type": "string",
                      "description": "related (default) | calls | imports"},
             "include_content": {"type": "boolean", "default": False}},
             "required": ["seeds"]}},
        {"name": "graph_paths",
         "description": "Paths between two chunks through resolved call edges. strategy: shortest (BFS, default) | all_simple (DFS simple-path enumeration).",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "from_chunk_id": {"type": "integer"},
             "to_chunk_id": {"type": "integer"},
             "max_hops": {"type": "integer", "default": 5},
             "max_paths": {"type": "integer", "default": 3},
             "strategy": {"type": "string",
                          "description": "shortest | all | all_simple"},
             "edge_kinds": {"type": "array", "items": {"type": "string"}},
             "include_content": {"type": "boolean", "default": False}},
             "required": ["from_chunk_id", "to_chunk_id"]}},
        {"name": "get_impact",
         "description": "Transitive dependents of a chunk — 'if I change this, what breaks?'.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "chunk_id": {"type": "integer"},
             "max_hops": {"type": "integer", "default": 2},
             "include_content": {"type": "boolean", "default": False}},
             "required": ["chunk_id"]}},
        {"name": "find_definitions", "description": "Exact symbol definitions.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "name": {"type": "string"}},
             "required": ["name"]}},
        {"name": "find_usages", "description": "Chunks referencing a symbol name.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "name": {"type": "string"}},
             "required": ["name"]}},
        {"name": "workspace_tree", "description": "Directory tree of the workspace.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "depth": {"type": "integer", "default": 3}}}},
        {"name": "prime", "description": "Compact orientation card — call first each session.",
         "inputSchema": {"type": "object", "properties": {"workspace": ws}}},
        {"name": "get_record",
         "description": "Retrieve one durable record by its integer ID. scope=workspace (default) reads the workspace ledger; scope=global reads the repo-wide ledger shared by all git worktrees (no indexed workspace needed); scope=all checks workspace first then global.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "id": {"type": "integer", "description": "Record ID"},
             "scope": {"type": "string",
                       "description": "workspace (default) | global | all"},
             "include_payload": {"type": "boolean", "default": True}},
             "required": ["id"]}},
        {"name": "list_records",
         "description": "List durable records (context packs, ask runs, agent notes) with optional kind/source/status filters and pagination. scope=workspace (default) reads the workspace ledger; scope=global reads the repo-wide ledger shared by all git worktrees; scope=all unions both, workspace rows first.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "kind": {"type": "string", "description": "Record kind filter"},
             "source": {"type": "string",
                        "description": "cli | mcp | http"},
             "status": {"type": "string",
                        "description": "running | completed | failed"},
             "scope": {"type": "string",
                       "description": "workspace (default) | global | all"},
             "limit": {"type": "integer", "default": 50},
             "offset": {"type": "integer",
                        "description": "Pagination offset"}}}},
        {"name": "search_records", "description": "Search durable records/usage history. scope=global reads the cross-workspace ledger.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "query": {"type": "string"},
             "scope": {"type": "string", "enum": ["workspace", "global"],
                       "default": "workspace"}},
             "required": ["query"]}},
        {"name": "put_record", "description": "Write an agent-authored record (note/finding/decision/todo/session_checkpoint) to the workspace + shared ledger — other sessions inherit it via prime.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws, "kind": {"type": "string"},
             "title": {"type": "string"}, "payload": {"type": "string"},
             "status": {"type": "string", "default": "completed"}},
             "required": ["kind", "title", "payload"]}},
        {"name": "checkpoint", "description": "Session checkpoint — call before ending work: auto-captures HEAD/branch/dirty files + your summary/next-step so the next session resumes instead of re-discovering.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "summary": {"type": "string",
                         "description": "What was done/decided this session"},
             "next": {"type": "string",
                      "description": "Exact next step for whoever resumes"},
             "files": {"type": "array", "items": {"type": "string"},
                       "description": "Files touched (default: git status)"}},
             "required": ["summary"]}},
        {"name": "simulate_patch",
         "description": "Pre-flight a unified diff: declarations changed/removed plus every indexed caller/implementer/test that would break — before writing the patch.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "diff": {"type": "string", "description": "Unified-diff text"},
             "diff_file": {"type": "string", "description": "Path to .diff/.patch"},
             "max_callers": {"type": "integer", "default": 50}}}},
        {"name": "test_coverage",
         "description": "Static test<->symbol map over call edges. symbol_name -> test chunks that exercise it; path -> non-test symbols that file covers.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "symbol_name": {"type": "string"},
             "path": {"type": "string",
                      "description": "test file — lists covered symbols"},
             "limit": {"type": "integer", "default": 50}}}},
        {"name": "trace_lookup",
         "description": "Paste a crash stack trace -> frames resolved to indexed chunks (file:line -> enclosing symbol) + suspects: callers of the deepest matched frame, flagged when recently commit-touched.",
         "inputSchema": {"type": "object", "properties": {
             "workspace": ws,
             "trace": {"type": "string", "description": "Raw stack-trace text"},
             "trace_file": {"type": "string",
                            "description": "Path to a file with the trace"}}}},
    ]


def call(name: str, args: dict) -> str:
    ws = args.get("workspace", "")
    if name == "list_workspaces":
        cat = json.loads(CATALOG.read_text()) if CATALOG.exists() else {}
        return _j([{"key": k, "path": v["path"],
                    "updated_at": v.get("updated_at")} for k, v in cat.items()])
    if name == "index_workspace":
        stats = Indexer(Store(_resolve_workspace(ws))).run()
        return _j(stats)
    # scope=global/all reads resolve the store leniently (unindexed
    # workspaces still answer from the shared ledger) — handle before the
    # strict _store() below.
    if name == "get_record":
        from . import records as _rec
        return _j(_rec.get_record(args, _store))
    if name == "list_records":
        from . import records as _rec
        return _j(_rec.list_records(args, _store))

    s = _store(ws, use_workspace_root=bool(args.get("use_workspace_root")))
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
    if name == "answer":
        from . import answer as _ans
        q = args.get("query")
        if not isinstance(q, str) or not q.strip():
            raise ValueError("missing required argument: query")
        mt = args.get("max_tokens")
        return _j(_ans.run(
            s, q, model=args.get("model") or None,
            timeout=int(args.get("timeout") or _ans.DEFAULT_TIMEOUT),
            expected_path=args.get("expected_path") or None,
            path_filter=args.get("path") or None,
            backend_spec=args.get("backend") or None,
            max_tokens=(int(mt) if isinstance(mt, (int, float))
                        and not isinstance(mt, bool) else None)))
    if name == "fetch_chunks":
        ids = [int(i) for i in args["chunk_ids"]]
        marks = ",".join("?" * len(ids))
        rows = s.db.execute(
            f"SELECT id,file_id,start_line,end_line,content FROM chunks "
            f"WHERE id IN ({marks})", ids).fetchall()
        s.log_event("fetch_chunks", "", arg_path="",
                    top_paths=";".join(r[1] for r in rows[:5]),
                    hit_count=len(rows))
        if args.get("mode") == "signature":
            from .slice import signature
            rows2 = s.db.execute(
                f"SELECT c.id, c.file_id, c.start_line, c.end_line, "
                f"c.content, c.symbol_name FROM chunks c "
                f"WHERE c.id IN ({marks})", ids).fetchall()
            return _j([{"chunk_id": r[0], "path": r[1],
                        "lines": [r[2], r[3]],
                        "signature": signature(r[4], symbol=r[5])}
                       for r in rows2])
        return _j([{"chunk_id": r[0], "path": r[1], "lines": [r[2], r[3]],
                    "content": r[4]} for r in rows])
    if name == "outline":
        from .slice import signature
        rows = s.db.execute(
            "SELECT id, start_line, end_line, symbol_type, symbol_name, "
            "content FROM chunks WHERE file_id = ? ORDER BY id",
            (args["path"],)).fetchall()
        if not rows:
            return _j({"error": "path not indexed or has no chunks — "
                       "use workspace_tree/inspect for directories"})
        return _j({"path": args["path"], "symbols": [
            {"chunk_id": r[0], "kind": r[3] or "", "symbol": r[4],
             "lines": f"{r[1]}-{r[2]}",
             "signature": signature(r[5], symbol=r[4])}
            for r in rows]})
    if name == "inspect_path":
        from . import inspect_path as _ip
        path = args.get("path")
        if not isinstance(path, str):
            raise ValueError("missing required argument: path")
        if path.startswith("/") or ".." in path:
            return _j({"error": "path must be relative, no '..' allowed"})
        return _j(_ip.run(
            s, path, query=args.get("query") or None,
            limit=int(args.get("limit", 50)),
            offset=int(args.get("offset", 0)),
            rerank_pool_size=int(args.get("rerank_pool_size", 150)),
            include_content=bool(args.get("include_content", False))))
    if name == "graph_neighbors":
        from . import graph
        cid = args.get("chunk_id")
        if not isinstance(cid, (int, float)) or isinstance(cid, bool):
            raise ValueError("missing required argument: chunk_id")
        return _j(graph.neighbors(
            s, int(cid), direction=args.get("direction") or "both",
            edge_kinds=args.get("edge_kinds") or None,
            depth=int(args.get("depth", 1)),
            limit=int(args.get("limit", 20)),
            include_content=bool(args.get("include_content", False))))
    if name == "graph_expand":
        from . import graph
        seeds = args.get("seeds")
        if not isinstance(seeds, list) or not seeds:
            raise ValueError("missing required argument: seeds")
        return _j(graph.expand(
            s, seeds, mode=args.get("mode") or "related",
            include_content=bool(args.get("include_content", False))))
    if name == "graph_paths":
        from . import graph
        fr, to = args.get("from_chunk_id"), args.get("to_chunk_id")
        if (not isinstance(fr, (int, float)) or isinstance(fr, bool)
                or not isinstance(to, (int, float))
                or isinstance(to, bool)):
            raise ValueError(
                "missing required argument: from_chunk_id/to_chunk_id")
        return _j(graph.paths(
            s, int(fr), int(to),
            max_hops=int(args.get("max_hops", 5)),
            max_paths=int(args.get("max_paths", 3)),
            strategy=args.get("strategy") or "shortest",
            edge_kinds=args.get("edge_kinds") or None,
            include_content=bool(args.get("include_content", False))))
    if name == "get_impact":
        from . import graph
        cid = args.get("chunk_id")
        if not isinstance(cid, (int, float)) or isinstance(cid, bool):
            raise ValueError("missing required argument: chunk_id")
        return _j(graph.impact(
            s, int(cid), max_hops=int(args.get("max_hops", 2)),
            include_content=bool(args.get("include_content", False))))
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
        out = (f"workspace: {ws}\nkey: {s.key}\nfiles: {n_files} "
               f"chunks: {n_chunks} model: {s.meta('embedding_model')}\n"
               f"langs: {langs}\nhub symbols: {syms}\n"
               f"last_index: {s.meta('last_index')}")
        # Cross-workspace memory: newest shared records + the latest
        # session checkpoint's next-step so a fresh session can resume
        # instead of re-discovering.
        from . import records as _rec
        kinds = ("note", "finding", "decision", "todo", "session_checkpoint")
        priors = _rec.recent(kinds, 3)
        if priors:
            out += (f"\nprior_work ({_rec.count(kinds)} shared records —"
                    " search_records scope=global):")
            for r in priors:
                out += f"\n- {r['kind']}: {r['title'][:60]}"
        ck = _rec.recent(("session_checkpoint",), 1)
        if ck:
            try:
                nxt = json.loads(ck[0]["payload"]).get("next", "")
            except (ValueError, AttributeError):
                nxt = ""
            out += (f"\nresume: {ck[0]['title'][:80]}"
                    + (f" → next: {nxt[:120]}" if nxt else ""))
        return out
    if name == "search_records":
        if args.get("scope") == "global":
            from . import records as _rec
            return _j({"records": _rec.search(args["query"]),
                       "scope": "global"})
        q = f"%{args['query']}%"
        rows = s.db.execute(
            "SELECT kind,title,payload,created_at FROM records "
            "WHERE title LIKE ? OR payload LIKE ? "
            "ORDER BY (kind='commit'), id DESC LIMIT 20",
            (q, q)).fetchall()
        evs = s.db.execute(
            "SELECT tool,query,top_paths,hit_count,ts FROM usage_events "
            "WHERE query LIKE ? ORDER BY id DESC LIMIT 20", (q,)).fetchall()
        return _j({"records": rows, "usage": evs})
    if name in ("put_record", "checkpoint"):
        from . import records as _rec
        if name == "put_record":
            kind = args.get("kind") or ""
            if not kind:
                raise ValueError("missing required argument: kind")
            if kind not in _rec._KINDS:
                raise ValueError(
                    f"unknown record kind '{kind}' — allowed: "
                    + ", ".join(sorted(_rec._KINDS)))
            title = args.get("title") or ""
            if not title:
                raise ValueError("missing required argument: title")
            payload = args.get("payload")
            if not isinstance(payload, str):
                raise ValueError("missing required argument: payload")
            status = args.get("status") or "completed"
        else:
            summary = args.get("summary") or ""
            if not summary:
                raise ValueError("missing required argument: summary")
            kind = "session_checkpoint"
            status = "completed"
            # Understand.truncHead(summary, 80): head + "…" marker
            title = summary if len(summary) <= 80 else summary[:79] + "…"
            payload = json.dumps(_rec.checkpoint_payload(
                s.workspace, summary, args.get("next") or "",
                args.get("files")), ensure_ascii=False)
        # Staleness evidence: current HEAD (absent outside git) + the
        # symbol/path anchors title+payload verifiably mentions.
        head = _rec.git(s.workspace, "rev-parse", "HEAD") or None
        anchors = _rec.record_anchors(s, title + "\n" + payload)
        rid = _rec.insert_ws(s, kind, title, payload, source="mcp",
                             status=status, head_sha=head,
                             anchors=anchors)
        ws_key = _rec.repo_key(s.workspace)
        gid = _rec.insert(ws_key, kind, title, payload,
                          head_sha=head or "", status=status,
                          anchors=anchors)
        return _j({"record_id": rid,
                   "kind": kind,
                   "scope": "workspace+global" if gid else "workspace",
                   "ws": ws_key})
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
    if name == "trace_lookup":
        from . import trace
        text = args.get("trace") or ""
        if not text and args.get("trace_file"):
            try:
                text = open(args["trace_file"], encoding="utf-8").read()
            except OSError:
                return _j({"error": f"cannot read {args['trace_file']}"})
        return _j(trace.run(s, text))
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
