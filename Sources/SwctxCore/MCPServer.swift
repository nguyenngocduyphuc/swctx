import Foundation
import MCP

/// stdio MCP server exposing the index/retrieval tools. Any MCP-capable agent
/// CLI (Claude Code, Codex, Devin, Cursor...) connects by spawning `swctx mcp`.
public enum MCPServer {
    /// Build a JSON-Schema object: `type`/`required` stay at the schema
    /// root, every other pair is a declared property. A flat layout puts
    /// e.g. `title` (a reserved schema keyword) at the root holding an
    /// object — strict clients reject the whole tool on load.
    static func obj(_ pairs: [(String, Value)]) -> Value {
        var props: [(String, Value)] = []
        var top: [(String, Value)] = [("type", .string("object"))]
        for (k, v) in pairs {
            if k == "type" || k == "required" { top.append((k, v)) }
            else { props.append((k, v)) }
        }
        top.append(("properties", .object(Dictionary(props, uniquingKeysWith: { a, _ in a }))))
        return .object(Dictionary(top, uniquingKeysWith: { a, _ in a }))
    }
    static func str(_ s: String) -> Value { .string(s) }
    static func prop(_ type: String, _ desc: String) -> Value {
        .object(["type": .string(type), "description": .string(desc)])
    }

    static var wsProp: (String, Value) {
        ("workspace", prop("string", "Absolute project path; omit or \"auto\" to resolve the nearest indexed ancestor of the server process cwd"))
    }
    static var uwrProp: (String, Value) {
        ("use_workspace_root", prop("boolean", "Resolve a nested path up to its indexed workspace root"))
    }
    static var budgetProp: (String, Value) {
        ("max_tokens", prop("integer", "Optional response budget (~4 chars/token); arrays trim tail-first, meta.omitted reports drops. Hard cap ~64KB always applies"))
    }

    public static var toolList: [Tool] {
        [
            Tool(
                name: "get_status",
                description: "Read workspace index state: counts, capability health, freshness (stale/changed/deleted files vs index), pending embeddings. Call first; if freshness.stale_files > 0 run index_workspace before trusting results. freshness=\"deep\" additionally scans the disk for new files.",
                inputSchema: obj([wsProp,
                                  ("freshness", prop("string", "\"deep\" = full directory scan incl. new files (slower; default stats indexed files only)")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "fast_understand",
                description: "Deterministic workspace digest — counts, language mix, hub symbols, hot files, call-graph communities, recent files; optional query adds top-5 relevant chunks. No LLM.",
                inputSchema: obj([wsProp,
                                  ("query", prop("string", "Optional query to also surface top-5 relevant chunks")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "index_workspace",
                description: "Create or update the workspace index. Parses files, extracts symbols and call/import edges, embeds chunks on-device. Embeds ALL pending chunks by default — pass skip_embed to defer to `swctx embed`.",
                inputSchema: obj([wsProp, uwrProp,
                                  ("force", prop("boolean", "Full re-index, ignoring cached hashes")),
                                  ("dry_run", prop("boolean", "Report what would change without writing")),
                                  ("skip_embed", prop("boolean", "Skip the auto-embed tail; fill later with swctx embed")),
                                  budgetProp, ("type", .string("object"))])),
            Tool(
                name: "list_workspaces",
                description: "List workspaces that have been indexed on this machine.",
                inputSchema: obj([("limit", prop("integer", "1-100, default 100")),
                                  ("cursor", prop("integer", "Offset")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "search",
                description: "Hybrid full-text + semantic search over indexed code chunks. Modes: auto (default — identifier-shaped queries take the deterministic FTS+symbol path, prose takes full fusion), hybrid, fts, semantic, identifier. Returns metadata + snippet; use fetch_chunks for full source.",
                inputSchema: obj([wsProp,
                                  ("query", prop("string", "Natural-language or keyword query")),
                                  ("mode", prop("string", "auto (default) | hybrid | fts | semantic | identifier")),
                                  ("path", prop("string", "Optional relative path prefix to scope results")),
                                  ("limit", prop("integer", "Max hits, default 20")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("query")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "find_definitions",
                description: "Resolve symbol names to definition locations (path, line, signature, symbol_id, chunk_id). Metadata-first; include_content or fetch_chunks for source.",
                inputSchema: obj([wsProp,
                                  ("symbols", prop("array", "1-20 symbol names")),
                                  ("include_content", prop("boolean", "Include chunk source (default false)")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("symbols")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "find_usages",
                description: "Find chunks that call/import/implement a symbol via reverse graph edges. definition_symbol_id (from find_definitions) pins one exact definition; symbol_name matches by name.",
                inputSchema: obj([wsProp,
                                  ("symbol_name", prop("string", "Symbol to locate usages for")),
                                  ("definition_symbol_id", prop("integer", "Pin an exact definition (symbols.id); resolved edges only")),
                                  ("edge_kinds", prop("array", "calls | imports | implements; default calls")),
                                  ("limit", prop("integer", "Default 50, max 1000")),
                                  ("include_content", prop("boolean", "Default false")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "fetch_chunks",
                description: "Read full source for chunk IDs returned by other tools.",
                inputSchema: obj([wsProp,
                                  ("chunk_ids", prop("array", "Integer chunk IDs")),
                                  ("include_content", prop("boolean", "Default true")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("chunk_ids")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "inspect_path",
                description: "Browse indexed chunks under a relative file/directory path; optional query reranks them semantically.",
                inputSchema: obj([wsProp,
                                  ("path", prop("string", "Relative file or directory path")),
                                  ("query", prop("string", "Optional semantic rerank query")),
                                  ("limit", prop("integer", "Default 50, max 200")),
                                  ("offset", prop("integer", "Pagination offset")),
                                  ("rerank_pool_size", prop("integer", "Query-mode candidate pool, default 150, max 500")),
                                  ("include_content", prop("boolean", "Default false")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("path")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "get_workspace_tree",
                description: "Paginated list of indexed files with chunk/symbol counts.",
                inputSchema: obj([wsProp,
                                  ("root", prop("string", "Optional relative subtree root")),
                                  ("max_depth", prop("integer", "Max path components below root")),
                                  ("query", prop("string", "Substring filter on file path")),
                                  ("status", prop("string", "stale | fresh — disk-vs-index comparison")),
                                  ("limit", prop("integer", "Files per page, default 200")),
                                  ("cursor", prop("integer", "File offset")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "graph_neighbors",
                description: "Call/import graph neighbors of a chunk; BFS expansion when depth > 1.",
                inputSchema: obj([wsProp,
                                  ("chunk_id", prop("integer", "Seed chunk ID")),
                                  ("edge_kinds", prop("array", "Edge type filter")),
                                  ("direction", prop("string", "incoming | outgoing | both")),
                                  ("depth", prop("integer", "BFS hops, 1-3, default 1")),
                                  ("limit", prop("integer", "Default 20")),
                                  ("include_content", prop("boolean", "Include neighbor chunk source (default false)")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("chunk_id")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "graph_expand",
                description: "BFS-expand a scored seed set through the resolved call/import graph (depth ≤ 2, cap 60). Results carry depth, via and decayed score.",
                inputSchema: obj([wsProp,
                                  ("seeds", prop("array", "Non-empty array of {chunk_id, score?}")),
                                  ("mode", prop("string", "related (default) | calls | imports")),
                                  ("include_content", prop("boolean", "Default false")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("seeds")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "graph_paths",
                description: "Paths between two chunks through resolved call edges. strategy: shortest (BFS, default) | all_simple (DFS simple-path enumeration).",
                inputSchema: obj([wsProp,
                                  ("from_chunk_id", prop("integer", "")),
                                  ("to_chunk_id", prop("integer", "")),
                                  ("max_hops", prop("integer", "Default 5")),
                                  ("max_paths", prop("integer", "Default 3, max 10")),
                                  ("strategy", prop("string", "shortest | all | all_simple")),
                                  ("edge_kinds", prop("array", "")),
                                  ("include_content", prop("boolean", "Default false")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("from_chunk_id"), .string("to_chunk_id")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "context_pack",
                description: "Deterministic multi-round retrieval: hybrid hits plus one-hop call-graph expansion. Returns grouped evidence (direct hits carry source; neighbors are metadata — fetch_chunks for bodies). Local no-LLM equivalent of ctxe ask_context compose=false.",
                inputSchema: obj([wsProp,
                                  ("query", prop("string", "Natural-language or keyword query")),
                                  ("budget", prop("integer", "Max evidence items, default 12")),
                                  ("expand", prop("boolean", "Include 1-hop call/called_by neighbors (default true)")),
                                  ("path", prop("string", "Optional relative path prefix filter")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("query")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "get_impact",
                description: "Transitive dependents of a chunk — 'if I change this, what breaks?'.",
                inputSchema: obj([wsProp,
                                  ("chunk_id", prop("integer", "")),
                                  ("max_hops", prop("integer", "Default 2, max 4")),
                                  ("include_content", prop("boolean", "Default false")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("chunk_id")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "get_record",
                description: "Retrieve one durable workspace record by its integer ID.",
                inputSchema: obj([wsProp,
                                  ("id", prop("integer", "Workspace-local record ID")),
                                  ("include_payload", prop("boolean", "Include full payload (default true)")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("id")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "list_records",
                description: "List durable records (context packs, ask runs, agent notes) with optional kind/source/status filters and pagination. scope=workspace (default) reads the workspace ledger; scope=global reads the repo-wide ledger shared by all git worktrees; scope=all unions both, workspace rows first.",
                inputSchema: obj([wsProp,
                                  ("kind", prop("string", "Record kind filter")),
                                  ("source", prop("string", "cli | mcp | http")),
                                  ("status", prop("string", "running | completed | failed")),
                                  ("scope", prop("string", "workspace (default) | global (repo-wide ledger, shared across worktrees) | all (union)")),
                                  ("limit", prop("integer", "1-100, default 50")),
                                  ("offset", prop("integer", "Pagination offset")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "search_records",
                description: "Full-text search over record titles and payloads; same filters, scope and pagination as list_records.",
                inputSchema: obj([wsProp,
                                  ("query", prop("string", "Full-text search query")),
                                  ("kind", prop("string", "Record kind filter")),
                                  ("source", prop("string", "cli | mcp | http")),
                                  ("status", prop("string", "running | completed | failed")),
                                  ("scope", prop("string", "workspace (default) | global (repo-wide ledger, shared across worktrees) | all (union)")),
                                  ("limit", prop("integer", "1-100, default 50")),
                                  ("offset", prop("integer", "Pagination offset")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("query")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "put_record",
                description: "Write a durable agent-authored record (fleet memory): persists to the workspace ledger AND the repo-wide ledger shared by all git worktrees of this repository. Use for notes, findings, decisions and todos other agents should see.",
                inputSchema: obj([wsProp,
                                  ("kind", prop("string", "note | finding | decision | todo | context_pack | ask")),
                                  ("title", prop("string", "Short record title")),
                                  ("payload", prop("string", "Record body (plain text or JSON)")),
                                  ("status", prop("string", "running | completed | failed — default completed")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("kind"), .string("title"), .string("payload")]))])),
            Tool(
                name: "prime",
                description: "Orientation card for this workspace (~300 tokens): branch, index counts, freshness, watcher state, hub symbols, recent records, warnings. Call FIRST at session start — cheaper and broader than get_status + fast_understand + list_records separately. format=json returns the structured snapshot instead of markdown.",
                inputSchema: obj([wsProp,
                                  ("format", prop("string", "markdown (default) | json")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
        ]
    }

    public static func run() async throws {
        let server = Server(
            name: "swctx",
            version: "0.1.0",
            instructions: "Local semantic code index (free, on-device, ms-level). Workflow: 1) prime — call FIRST for the workspace orientation card (freshness, watcher, hub symbols, recent records, warnings; workspace arg optional — resolves to nearest indexed ancestor of server cwd). If the card warns the index is stale, run index_workspace before trusting retrieval. 2) search (mode=auto handles identifier vs prose automatically), find_definitions/find_usages/graph_* for structure, fetch_chunks to read source bodies — list tools return metadata only. 3) put_record at task end for decisions/findings other agents should inherit; search_records scope=global reads fleet memory shared across git worktrees. All tools accept max_tokens to bound response size.",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolList)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let out = try await SwctxTools.call(name: params.name,
                                                    arguments: params.arguments ?? [:])
                return CallTool.Result(content: [.text(text: out, annotations: nil, _meta: nil)])
            } catch {
                let errJson = (try? JSONSerialization.data(
                    withJSONObject: ["error": error.localizedDescription]))
                    .flatMap { String(data: $0, encoding: .utf8) }
                    ?? "{\"error\":\"unknown\"}"
                return CallTool.Result(
                    content: [.text(text: errJson, annotations: nil, _meta: nil)],
                    isError: true)
            }
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
