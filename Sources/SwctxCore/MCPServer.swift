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
                                  ("rerank", prop("boolean", "Cross-encoder rerank of a 30-candidate pool; top-3 fused hits stay pinned. Adds ~0.4s/call; use for hard natural-language queries when plain results look off")),
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
                description: "Read full source for chunk IDs returned by other tools. mode=signature returns declaration lines only (~10% tokens) when the shape is enough.",
                inputSchema: obj([wsProp,
                                  ("chunk_ids", prop("array", "Integer chunk IDs")),
                                  ("include_content", prop("boolean", "Default true")),
                                  ("mode", prop("string", "full (default) | signature — declaration lines only")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("chunk_ids")]))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "outline",
                description: "One file -> its symbol map: kind, line range, signature — no bodies. The cheap answer to 'what is in this file' before fetching bodies.",
                inputSchema: obj([wsProp,
                                  ("path", prop("string", "Relative file path (exact file; use inspect_path for directories)")),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("path")]))]),
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
                name: "answer",
                description: "Local synthesis over verified evidence (W12): packs cited chunks [E01]…, then asks a local Ollama model (default qwen2.5:3b) for STRICT JSON {answer, citations, limitations}. Server-side citation validation rejects ids outside the pack. Ollama absent/model missing → deterministic evidence pack + limitation, never an error. Writes a durable kind=ask record.",
                inputSchema: obj([wsProp,
                                  ("query", prop("string", "Natural-language question about the codebase")),
                                  ("model", prop("string", "Ollama model override (default qwen2.5:3b; env SWCTX_ANSWER_MODEL)")),
                                  ("timeout", prop("integer", "Per-attempt Ollama seconds, default 60 (one format-retry allowed)")),
                                  ("plan", prop("boolean", "Bounded planner loop (≤4 rounds, ≤3 queries/round): iterates retrieval before answering — rescue mode for retrieval misses. Default off = single-shot.")),
                                  ("plan_timeout", prop("integer", "Planner total wall-clock seconds, default 60 (~20s per planner call)")),
                                  ("path", prop("string", "Optional relative path prefix filter for retrieval")),
                                  ("expected_path", prop("string", "Eval-harness oracle path — recorded for scoring only, never shown to the model")),
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
                name: "simulate_patch",
                description: "Pre-flight a unified diff: symbols whose declarations change or vanish, plus every indexed caller/implementer/test that would break — before writing the patch.",
                inputSchema: obj([wsProp,
                                  ("diff", prop("string", "Unified-diff text (git diff format)")),
                                  ("diff_file", prop("string", "Path to a .diff/.patch file — alternative to inline diff")),
                                  ("max_callers", prop("integer", "Default 50 per symbol")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "test_coverage",
                description: "Static test<->symbol map over call edges. symbol_name -> test chunks that exercise it (which tests to run for a change); path -> non-test symbols that file covers (what a test actually tests).",
                inputSchema: obj([wsProp,
                                  ("symbol_name", prop("string", "Symbol to find covering tests for")),
                                  ("path", prop("string", "Test file path — lists the symbols it covers")),
                                  ("limit", prop("integer", "Default 50, max 200")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "trace_lookup",
                description: "Paste a crash stack trace -> each frame resolved to its indexed chunk (file:line -> enclosing symbol), app frames flagged vs library noise, plus suspects: callers of the deepest matched frame, marked when recently commit-touched.",
                inputSchema: obj([wsProp,
                                  ("trace", prop("string", "Raw stack-trace text (Python/JS/Go/generic path:line)")),
                                  ("trace_file", prop("string", "Path to a file containing the trace")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
            Tool(
                name: "get_record",
                description: "Retrieve one durable record by its integer ID. scope=workspace (default) reads the workspace ledger; scope=global reads the repo-wide ledger shared by all git worktrees (no indexed workspace needed); scope=all checks workspace first then global.",
                inputSchema: obj([wsProp,
                                  ("id", prop("integer", "Workspace-local record ID")),
                                  ("scope", prop("string", "workspace (default) | global (repo-wide ledger, shared across worktrees) | all (union)")),
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
                name: "checkpoint",
                description: "Session checkpoint — call before ending work. Auto-captures HEAD, branch and dirty files around your summary + next-step, then dual-writes the workspace and repo-wide ledgers. The next session's prime card surfaces it as `resume:` so work continues instead of re-discovering.",
                inputSchema: obj([wsProp,
                                  ("summary", prop("string", "What was done/decided this session — becomes the record title")),
                                  ("next", prop("string", "Exact next step for whoever resumes")),
                                  ("files", .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                                   "description": .string("Files touched (default: git status --porcelain)")])),
                                  budgetProp, ("type", .string("object")),
                                  ("required", .array([.string("summary")]))])),
            Tool(
                name: "prime",
                description: "Orientation card for this workspace (~300 tokens): branch, index counts, freshness, watcher state, hub symbols, recent records, warnings. Call FIRST at session start — cheaper and broader than get_status + fast_understand + list_records separately. format=json returns the structured snapshot instead of markdown.",
                inputSchema: obj([wsProp,
                                  ("format", prop("string", "markdown (default) | json")),
                                  budgetProp, ("type", .string("object"))]),
                annotations: .init(readOnlyHint: true)),
        ]
    }

    // MARK: - tools/call deadline

    /// Per-tool wall-clock budget for `tools/call`. A slow or wedged tool
    /// must never hang the response: once the budget expires the client
    /// gets E_DEADLINE_EXCEEDED instead of silence. Tools absent from the
    /// map get `defaultDeadline`; `index_workspace` earns 30 min because
    /// auto-embed on 30K+ chunk workspaces legitimately takes many minutes.
    static let defaultDeadline: Duration = .seconds(60)
    static let toolDeadlines: [String: Duration] = [
        "index_workspace": .seconds(1800),
        // Local LLM inference: default 60s/attempt + one format-retry;
        // `--plan` adds up to a 60s planner loop ahead of synthesis.
        "answer": .seconds(240),
    ]

    /// Thrown when a tool exceeds its deadline; the CallTool handler maps
    /// it to the `E_DEADLINE_EXCEEDED` error envelope.
    struct DeadlineError: Error, LocalizedError {
        let tool: String
        let deadline: Duration
        var errorDescription: String? {
            "tool \(tool) exceeded \(MCPServer.secondsString(deadline))s deadline"
        }
    }

    /// Render a `Duration` as the `N` in "exceeded Ns deadline": integral
    /// when whole ("60"), else decimal ("0.05").
    static func secondsString(_ d: Duration) -> String {
        let c = d.components
        guard c.attoseconds != 0 else { return "\(c.seconds)" }
        return String(format: "%g", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }

    /// One-shot result slot for `withDeadline`: resumes the parked
    /// continuation exactly once, whichever finishes first — the operation
    /// or the cancellation handler on deadline. A result landing before
    /// the continuation installs is parked and replayed on install.
    final class ResultSlot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        private var resumed = false

        func install(_ c: CheckedContinuation<T, Error>) {
            lock.lock()
            if let r = result {
                resumed = true
                lock.unlock()
                c.resume(with: r)
                return
            }
            continuation = c
            lock.unlock()
        }

        func finish(_ r: Result<T, Error>) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            if let c = continuation {
                resumed = true
                lock.unlock()
                c.resume(with: r)
            } else {
                result = r
                lock.unlock()
            }
        }

        func cancel() { finish(.failure(CancellationError())) }
    }

    /// Race `operation` against `deadline`; the first finisher wins and the
    /// loser is cancelled via `group.cancelAll()`. The operation runs in an
    /// unstructured task whose result a group child awaits through the
    /// cancellation-aware `ResultSlot`: a wedged call may keep running in
    /// the background after the deadline fires — the guarantee is a timely
    /// client response, not task termination. (Task-group teardown awaits
    /// all children; parking the operation itself inside the group would
    /// keep the response hostage to a wedge that never yields.)
    static func withDeadline<T: Sendable>(
        _ deadline: Duration, tool: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let slot = ResultSlot<T>()
        let work = Task {
            do { slot.finish(.success(try await operation())) }
            catch { slot.finish(.failure(error)) }
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { slot.install($0) }
                } onCancel: {
                    slot.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw DeadlineError(tool: tool, deadline: deadline)
            }
            defer { group.cancelAll(); work.cancel() }
            return try await group.next()!
        }
    }

    // MARK: - usage telemetry

    /// Top-level result-array key per tool, for the usage_events `hits`
    /// column. Tools not listed (or without the array) record NULL.
    static let hitsArrayKey: [String: String] = [
        "search": "hits",
        "fetch_chunks": "chunks",
        "inspect_path": "chunks",
        "find_usages": "usages",
        "graph_neighbors": "neighbors",
        "graph_expand": "results",
        "graph_paths": "paths",
        "get_impact": "dependents",
        "context_pack": "evidence",
        "answer": "evidence",
        "get_workspace_tree": "files",
        "list_workspaces": "workspaces",
        "list_records": "records",
        "search_records": "records",
    ]

    /// One UUID per MCP server process — groups usage_events into agent
    /// sessions so mined implicit-utility labels are causally ordered.
    static let sessionID = UUID().uuidString

    /// Pull the telemetry fields out of a finished call. `ok` flips false
    /// when the call threw AND when the body carries an {"error": …}
    /// envelope (E_OUTPUT_TOO_LARGE, "record not found", …). `hits` is the
    /// result count where cheaply known — find_definitions sums the
    /// per-symbol `definitions` arrays, the rest read one array key.
    /// `topPaths` captures the top-5 hit paths so a later fetch/inspect
    /// call can be linked back to the query that surfaced the file;
    /// `argPath` is that follow-up's target (path or chunk_ids JSON).
    static func usageFields(tool: String, args: [String: Value], body: String,
                            threw: Bool) -> (ok: Bool, hits: Int?, query: String?,
                                             topPaths: String?, argPath: String?) {
        let dict = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
            as? [String: Any]
        let ok = !threw && dict?["error"] == nil
        var hits: Int? = nil
        var topPaths: String? = nil
        if let dict {
            if tool == "find_definitions",
               let groups = dict["results"] as? [[String: Any]] {
                hits = groups
                    .map { ($0["definitions"] as? [Any])?.count ?? 0 }
                    .reduce(0, +)
            } else if let key = hitsArrayKey[tool] {
                let arr = dict[key] as? [Any]
                hits = arr?.count
                let paths = (arr ?? []).prefix(5).compactMap {
                    ($0 as? [String: Any])?["path"] as? String
                }
                if !paths.isEmpty,
                   let j = try? JSONSerialization.data(withJSONObject: paths) {
                    topPaths = String(data: j, encoding: .utf8)
                }
            }
        }
        var argPath = args["path"]?.str ?? args["id"]?.int.map { "\($0)" }
        if argPath == nil,
           let ids = args["chunk_ids"]?.arr?.compactMap({ $0.int }),
           !ids.isEmpty,
           let j = try? JSONSerialization.data(withJSONObject: ids) {
            argPath = String(data: j, encoding: .utf8)
        }
        return (ok, hits, args["query"]?.str, topPaths, argPath)
    }

    /// Fleet usage ledger: one row per tools/call in
    /// ~/.swctx/records.db usage_events. Fire-and-forget off the response
    /// path — a nil/unwritable ledger or a failed insert degrades
    /// silently and must never break or delay a call.
    static func recordUsage(tool: String, args: [String: Value], body: String,
                            threw: Bool, latencyMs: Int) {
        DispatchQueue.global().async {
            guard let g = GlobalRecords.shared else { return }
            let f = usageFields(tool: tool, args: args, body: body, threw: threw)
            // ws mirrors records.ws: the repo key of the resolved
            // workspace, "" when the call never resolved one.
            let ws = (try? SwctxTools.workspace(args))
                .map { GlobalRecords.repoKey(for: $0) } ?? ""
            _ = try? g.insertUsage(ws: ws, tool: tool, latencyMs: latencyMs,
                                   hits: f.hits, ok: f.ok, query: f.query,
                                   session: sessionID, topPaths: f.topPaths,
                                   argPath: f.argPath)
        }
    }

    public static func run() async throws {
        let server = Server(
            name: "swctx",
            version: "0.1.0",
            instructions: "Local semantic code index (free, on-device, ms-level). Workflow: 1) prime — call FIRST for the workspace orientation card (freshness, watcher, hub symbols, recent records, warnings; workspace arg optional — resolves to nearest indexed ancestor of server cwd). If the card warns the index is stale, run index_workspace before trusting retrieval. 2) search (mode=auto handles identifier vs prose automatically), find_definitions/find_usages/graph_* for structure, fetch_chunks to read source bodies — list tools return metadata only. 3) checkpoint at task end — one call saves summary+next-step with HEAD/branch/dirty files so the next session resumes via prime's `resume:` line; put_record for standalone decisions/findings; search_records scope=global reads fleet memory shared across git worktrees. All tools accept max_tokens to bound response size.",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolList)
        }
        await server.withMethodHandler(CallTool.self) { params in
            let name = params.name
            let args = params.arguments ?? [:]
            let t0 = CFAbsoluteTimeGetCurrent()
            var body = ""
            var threw = false
            defer {
                recordUsage(tool: name, args: args, body: body, threw: threw,
                            latencyMs: Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))
            }
            do {
                let out = try await withDeadline(
                    toolDeadlines[name] ?? defaultDeadline, tool: name) {
                    try await SwctxTools.call(name: name, arguments: args)
                }
                body = out
                return CallTool.Result(content: [.text(text: out, annotations: nil, _meta: nil)])
            } catch let e as DeadlineError {
                threw = true
                let errJson = (try? JSONSerialization.data(
                    withJSONObject: ["error": [
                        "code": "E_DEADLINE_EXCEEDED",
                        "message": e.localizedDescription,
                    ]]))
                    .flatMap { String(data: $0, encoding: .utf8) }
                    ?? "{\"error\":{\"code\":\"E_DEADLINE_EXCEEDED\",\"message\":\"deadline\"}}"
                return CallTool.Result(
                    content: [.text(text: errJson, annotations: nil, _meta: nil)],
                    isError: true)
            } catch {
                threw = true
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
