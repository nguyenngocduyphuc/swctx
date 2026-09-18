import Foundation
import GRDB
import MCP

extension Value {
    var str: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var int: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arr: [Value]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var dbl: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }
    var obj: [String: Value]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var strList: [String]? { arr?.compactMap(\.str) }
}

public enum ToolError: Error, LocalizedError {
    case missingArg(String)
    case workspaceNotFound(String)
    case notIndexed(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .missingArg(let a): return "missing required argument: \(a)"
        case .workspaceNotFound(let p): return "workspace path is not a directory: \(p)"
        case .notIndexed(let p): return "workspace not indexed yet, run index_workspace first: \(p)"
        case .unknownTool(let t): return "unknown tool: \(t)"
        }
    }
}

public enum SwctxTools {
    /// Nearest ancestor directory (starting at `dir`) that already has an
    /// index, or nil when none is found up to the filesystem root.
    static func indexedAncestor(of dir: URL) -> URL? {
        var d = dir
        while true {
            if FileManager.default.fileExists(
                atPath: Store.indexURL(forKey: Store.key(for: d)).path) { return d }
            let p = d.deletingLastPathComponent()
            if p.path == d.path { return nil }
            d = p
        }
    }

    /// `workspace` may be omitted, "auto" or ".": then the nearest indexed
    /// ancestor of the server process cwd wins (MCP clients spawn `swctx mcp`
    /// with the project as working directory, so cwd tracks the session's
    /// project). `use_workspace_root` does the same ancestor walk for an
    /// explicit nested path instead of treating it as its own workspace.
    static func workspace(_ args: [String: Value]) throws -> URL {
        let w = args["workspace"]?.str
        if w == nil || w == "auto" || w == "." {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .resolvingSymlinksInPath()
            return indexedAncestor(of: cwd) ?? cwd
        }
        let raw = w!
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError.workspaceNotFound(raw)
        }
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        if args["use_workspace_root"]?.bool == true,
           let root = indexedAncestor(of: url) {
            return root
        }
        return url
    }

    static func store(_ args: [String: Value], requireIndex: Bool = true) throws -> Store {
        let url = try workspace(args)
        let key = Store.key(for: url)
        let dbURL = Store.indexURL(forKey: key)
        if requireIndex && !FileManager.default.fileExists(atPath: dbURL.path) {
            throw ToolError.notIndexed(url.path)
        }
        return try Store(workspaceRoot: url)
    }

    static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func chunkDict(_ row: Row, content: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "chunk_id": (row["id"] as? Int64) ?? -1,
            "path": (row["path"] as? String) ?? "",
            "start_line": (row["start_line"] as? Int64) ?? 0,
            "end_line": (row["end_line"] as? Int64) ?? 0,
        ]
        if let k = row["kind"] as? String { d["kind"] = k }
        if let s = row["symbol"] as? String { d["symbol"] = s }
        if content, let c = row["content"] as? String { d["content"] = c }
        return d
    }

    // MARK: - Tool implementations

    static func getStatus(_ args: [String: Value]) throws -> String {
        let url = try workspace(args)
        let key = Store.key(for: url)
        let dbURL = Store.indexURL(forKey: key)
        var out: [String: Any] = ["workspace": url.path, "key": key]
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            out["indexed"] = false
            return json(["meta": out])
        }
        let store = try Store(workspaceRoot: url)
        let counts = try store.pool.read { db -> [String: Any] in
            [
                "files": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0,
                "chunks": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0,
                "symbols": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM symbols") ?? 0,
                "edges": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges") ?? 0,
                "edges_resolved": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE dst_chunk IS NOT NULL") ?? 0,
                "vectors": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0,
            ]
        }
        let langs = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT lang, COUNT(*) c FROM files GROUP BY lang ORDER BY c DESC")
                .map { ["lang": ($0["lang"] as? String) ?? "", "files": ($0["c"] as? Int64) ?? 0] }
        }
        let lastIndexed = try store.pool.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(indexed_at) FROM files")
        }
        out["indexed"] = true
        out["counts"] = counts
        out["languages"] = langs
        if let t = lastIndexed { out["last_indexed_at"] = t }
        let vecAvail = Embedder.shared.isAvailable
        out["capabilities"] = [
            "fts": true, "vector_search": vecAvail,
            "graph": true, "semantic": vecAvail,
        ]
        // Freshness: stat indexed rows every call (~0.1s on 5k files) for
        // changed/deleted — the trust signal. `freshness="deep"` additionally
        // runs the directory walk to report new_files (seconds on a large
        // tree). Agents should treat stale_files > 0 as "run index_workspace
        // before trusting".
        let indexer = Indexer(store: store, embedder: Embedder.shared)
        let deep = args["freshness"]?.str == "deep"
        if let f = try? indexer.freshness(deep: deep) {
            var freshness: [String: Any] = [
                "stale_files": f.staleCount,
                "changed_files": f.changedPaths.count,
                "deleted_files": f.deletedPaths.count,
            ]
            if deep { freshness["new_files"] = f.addedPaths.count }
            out["freshness"] = freshness
        }
        out["pending_embeddings"] = (try? indexer.pendingEmbeddings()) ?? 0
        return json(["meta": out])
    }

    static func indexWorkspace(_ args: [String: Value]) throws -> String {
        let url = try workspace(args)
        let store = try Store(workspaceRoot: url)
        let indexer = Indexer(store: store)
        if args["dry_run"]?.bool == true {
            let report = try indexer.dryRun()
            let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
            return json(obj)
        }
        let report = try indexer.run(force: args["force"]?.bool ?? false) { _ in }
        let data = try JSONEncoder().encode(report)
        let obj = try JSONSerialization.jsonObject(with: data)
        return json(obj)
    }

    static func listWorkspaces(_ args: [String: Value]) throws -> String {
        // Prune registry entries whose workspace path no longer exists.
        let entries = Store.loadRegistry()
        let live = entries.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
                && isDir.boolValue
        }
        if live.count != entries.count { Store.saveRegistry(live) }
        let limit = min(max(args["limit"]?.int ?? 100, 1), 100)
        let cursor = max(args["cursor"]?.int ?? 0, 0)
        let page = Array(live.dropFirst(cursor).prefix(limit))
        return json(["workspaces": page.map {
            ["path": $0.path, "key": $0.key, "last_indexed_at": $0.lastIndexedAt] as [String: Any]
        }, "total": live.count,
            "next_cursor": cursor + page.count < live.count ? cursor + page.count : NSNull()])
    }

    static func search(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let q = args["query"]?.str else { throw ToolError.missingArg("query") }
        let limit = min(args["limit"]?.int ?? 20, 100)
        let mode = args["mode"]?.str ?? "hybrid"
        let pathFilter = args["path"]?.str
        let hits: [SearchHit]
        switch mode {
        case "fts": hits = try Search.fts(store: store, query: q, limit: limit, pathFilter: pathFilter)
        case "semantic": hits = try Search.semantic(store: store, embedder: Embedder.shared, query: q, limit: limit, pathFilter: pathFilter)
        default: hits = try Search.hybrid(store: store, embedder: Embedder.shared, query: q, limit: limit, pathFilter: pathFilter)
        }
        let items = hits.map { h -> [String: Any] in
            var d: [String: Any] = [
                "chunk_id": h.chunkID, "path": h.path,
                "start_line": h.startLine, "end_line": h.endLine, "score": h.score,
            ]
            if let k = h.kind { d["kind"] = k }
            if let s = h.symbol { d["symbol"] = s }
            if !h.snippet.isEmpty { d["snippet"] = h.snippet }
            return d
        }
        return json(["query": q, "mode": mode, "hits": items])
    }

    static func findDefinitions(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let syms = args["symbols"]?.strList, !syms.isEmpty else {
            throw ToolError.missingArg("symbols")
        }
        let includeContent = args["include_content"]?.bool ?? false
        let result = try store.pool.read { db -> [[String: Any]] in
            try syms.prefix(20).map { name in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT s.id AS symbol_id, s.name, s.kind, s.line, s.signature, f.path, c.id AS chunk_id
                    FROM symbols s JOIN files f ON f.id = s.file_id
                    LEFT JOIN chunks c ON c.id = s.chunk_id
                    WHERE s.name = ? ORDER BY s.id LIMIT 25
                    """, arguments: [name])
                var group: [String: Any] = ["symbol": name]
                group["definitions"] = rows.map { r -> [String: Any] in
                    var d: [String: Any] = [
                        "path": (r["path"] as? String) ?? "", "line": (r["line"] as? Int64) ?? 0,
                        "kind": (r["kind"] as? String) ?? "",
                        "symbol_id": (r["symbol_id"] as? Int64) ?? -1,
                    ]
                    if let sig = r["signature"] as? String { d["signature"] = sig }
                    if let cid = r["chunk_id"] as? Int64 { d["chunk_id"] = cid }
                    return d
                }
                return group
            }
        }
        if includeContent {
            // attach chunk bodies for resolved chunk ids
            var ids: [Int64] = []
            for g in result {
                if let defs = g["definitions"] as? [[String: Any]] {
                    for d in defs { if let cid = d["chunk_id"] as? Int64 { ids.append(cid) } }
                }
            }
            let contents = try chunkContents(store: store, ids: ids)
            var enriched: [[String: Any]] = []
            for g in result {
                var g2 = g
                if var defs = g["definitions"] as? [[String: Any]] {
                    for i in defs.indices {
                        if let cid = defs[i]["chunk_id"] as? Int64, let c = contents[cid] {
                            defs[i]["content"] = c
                        }
                    }
                    g2["definitions"] = defs
                }
                enriched.append(g2)
            }
            return json(["results": enriched])
        }
        return json(["results": result])
    }

    static func chunkContents(store: Store, ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        return try store.pool.read { db in
            var out: [Int64: String] = [:]
            for id in ids.prefix(50) {
                if let c: String = try String.fetchOne(db,
                    sql: "SELECT content FROM chunks WHERE id = ?", arguments: [id]) {
                    out[id] = c
                }
            }
            return out
        }
    }

    static func findUsages(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        let kinds = args["edge_kinds"]?.strList
            ?? ["calls", "implements", "extends", "instantiates", "uses_type"]
        let limit = min(args["limit"]?.int ?? 50, 1000)
        let includeContent = args["include_content"]?.bool ?? false
        var sql: String
        var params: [DatabaseValueConvertible] = []
        var label: String
        if let dsid = args["definition_symbol_id"]?.int {
            // Pinpoint selector: usages of one exact definition = resolved
            // incoming edges to that definition's chunk. Unresolved
            // dst_name matches stay out — they cannot be attributed to this
            // specific definition over a same-named sibling.
            let sym = try store.pool.read { db in
                try Row.fetchOne(db, sql: "SELECT name, chunk_id FROM symbols WHERE id = ?",
                                 arguments: [dsid])
            }
            guard let sym else {
                return json(["error": "definition_symbol_id not found",
                             "definition_symbol_id": dsid])
            }
            label = (sym["name"] as? String) ?? ""
            guard let chunk = sym["chunk_id"] as? Int64 else {
                return json(["symbol": label, "definition_symbol_id": dsid, "usages": [Any]()])
            }
            sql = """
                SELECT DISTINCT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                FROM edges e JOIN chunks c ON c.id = e.src_chunk JOIN files f ON f.id = c.file_id
                WHERE e.dst_chunk = ?
                """
            params = [chunk]
        } else {
            guard let name = args["symbol_name"]?.str else {
                throw ToolError.missingArg("symbol_name|definition_symbol_id")
            }
            label = name
            sql = """
                SELECT DISTINCT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                FROM edges e JOIN chunks c ON c.id = e.src_chunk JOIN files f ON f.id = c.file_id
                WHERE (e.dst_name = ? OR e.dst_chunk IN (SELECT chunk_id FROM symbols WHERE name = ?))
                """
            params = [name, name]
        }
        if !kinds.isEmpty {
            sql += " AND e.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
            params += kinds
        }
        sql += " LIMIT ?"
        params.append(limit)
        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(params))
        }
        var usages = rows.map { r -> [String: Any] in
            [
                "chunk_id": (r["id"] as? Int64) ?? -1, "path": (r["path"] as? String) ?? "",
                "start_line": (r["start_line"] as? Int64) ?? 0, "end_line": (r["end_line"] as? Int64) ?? 0,
                "kind": (r["kind"] as? String) ?? NSNull(), "symbol": (r["symbol"] as? String) ?? NSNull(),
            ]
        }
        if includeContent {
            let contents = try chunkContents(store: store, ids: usages.compactMap { $0["chunk_id"] as? Int64 })
            for i in usages.indices {
                if let cid = usages[i]["chunk_id"] as? Int64 { usages[i]["content"] = contents[cid] }
            }
        }
        return json(["symbol": label, "usages": usages])
    }

    static func fetchChunks(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let ids = args["chunk_ids"]?.arr?.compactMap({ Int64($0.int ?? -1) }),
              !ids.isEmpty else { throw ToolError.missingArg("chunk_ids") }
        let includeContent = args["include_content"]?.bool ?? true
        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                \(includeContent ? ", c.content" : "")
                FROM chunks c JOIN files f ON f.id = c.file_id
                WHERE c.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids.map { $0 as DatabaseValueConvertible }))
        }
        return json(["chunks": rows.map { chunkDict($0, content: includeContent) }])
    }

    static func inspectPath(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let path = args["path"]?.str else { throw ToolError.missingArg("path") }
        if path.hasPrefix("/") || path.contains("..") {
            return json(["error": "path must be relative, no '..' allowed"])
        }
        let limit = min(args["limit"]?.int ?? 50, 200)
        let offset = args["offset"]?.int ?? 0
        let includeContent = args["include_content"]?.bool ?? false
        let like = path.isEmpty ? "%" : (path.hasSuffix("/") ? path + "%" : path + "/%")
        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                \(includeContent ? ", c.content" : "")
                FROM chunks c JOIN files f ON f.id = c.file_id
                WHERE f.path LIKE ? OR f.path = ?
                ORDER BY f.path, c.idx LIMIT ? OFFSET ?
                """, arguments: [like, path, limit, offset])
        }
        // Optional query: hybrid-rank across the whole path subtree, not just
        // the first `limit` rows in path order. `rerank_pool_size` widens the
        // candidate pool; `offset` slices the ranked pool (ctxe parity).
        if let query = args["query"]?.str, !query.isEmpty {
            let poolSize = min(args["rerank_pool_size"]?.int ?? 150, 500)
            let hits = try Search.hybrid(store: store, embedder: Embedder.shared,
                                         query: query, limit: poolSize, pathFilter: path)
            let sliced = Array(hits.dropFirst(max(0, offset)).prefix(limit))
            var rowsById: [Int64: Row] = [:]
            try store.pool.read { db in
                for h in sliced {
                    if let r = try Row.fetchOne(db, sql: """
                        SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                        \(includeContent ? ", c.content" : "")
                        FROM chunks c JOIN files f ON f.id = c.file_id WHERE c.id = ?
                        """, arguments: [h.chunkID]) {
                        rowsById[h.chunkID] = r
                    }
                }
            }
            var chunks: [[String: Any]] = []
            for h in sliced {
                guard let r = rowsById[h.chunkID] else { continue }
                var d = chunkDict(r, content: includeContent)
                d["score"] = h.score
                chunks.append(d)
            }
            return json(["chunks": chunks, "reranked": true])
        }
        return json(["chunks": rows.map { chunkDict($0, content: includeContent) },
                     "reranked": false])
    }

    static func workspaceTree(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        let root = args["root"]?.str ?? ""
        let limit = min(args["limit"]?.int ?? 200, 1000)
        let cursor = max(args["cursor"]?.int ?? 0, 0)
        let like = root.isEmpty ? "%" : (root.hasSuffix("/") ? root + "%" : root + "/%")
        var conds = ["f.path LIKE ?"]
        var params: [DatabaseValueConvertible] = [like]
        if let q = args["query"]?.str, !q.isEmpty {
            conds.append("f.path LIKE ?")
            params.append("%\(q)%")
        }
        if let d = args["max_depth"]?.int {
            // Path components relative to root: slashes(path) + 1 - slashes(root).
            let rootDepth = root.isEmpty ? 0 : root.split(separator: "/").count
            conds.append("(LENGTH(f.path) - LENGTH(REPLACE(f.path, '/', '')) + 1 - \(rootDepth)) <= \(max(d, 0))")
        }
        let whereSQL = " WHERE " + conds.joined(separator: " AND ")
        let selectSQL = """
            SELECT f.path, f.lang, f.size,
                   (SELECT COUNT(*) FROM chunks c WHERE c.file_id = f.id) AS chunks,
                   (SELECT COUNT(*) FROM symbols s WHERE s.file_id = f.id) AS symbols
            FROM files f\(whereSQL)
            """
        func fileDict(_ r: Row) -> [String: Any] {
            ["path": (r["path"] as? String) ?? "", "lang": (r["lang"] as? String) ?? "",
             "size": (r["size"] as? Int64) ?? 0,
             "chunks": (r["chunks"] as? Int64) ?? 0, "symbols": (r["symbols"] as? Int64) ?? 0]
        }
        if let status = args["status"]?.str, !status.isEmpty {
            // Disk-backed filter — compare each matched row against the
            // freshness scan, then paginate in memory (totals stay correct).
            let rows = try store.pool.read { db in
                try Row.fetchAll(db, sql: selectSQL + " ORDER BY f.path",
                                 arguments: StatementArguments(params))
            }
            // Tree only lists indexed rows, so the shallow scan (changed +
            // deleted) suffices — new-on-disk files have no row to filter.
            let f = try Indexer(store: store, embedder: Embedder.shared).freshness(deep: false)
            let stale = f.changedPaths.union(f.deletedPaths)
            let filtered = rows.filter {
                let isStale = stale.contains(($0["path"] as? String) ?? "")
                return status == "stale" ? isStale : !isStale
            }
            let page = filtered.dropFirst(cursor).prefix(limit).map { fileDict($0) }
            return json(["total_files": filtered.count, "files": page,
                         "next_cursor": cursor + page.count < filtered.count
                            ? cursor + page.count : NSNull()])
        }
        let (rows, total) = try store.pool.read { db in
            let t = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM files f\(whereSQL)", arguments: StatementArguments(params)) ?? 0
            let r = try Row.fetchAll(db, sql: selectSQL + " ORDER BY f.path LIMIT ? OFFSET ?",
                                     arguments: StatementArguments(params + [limit, cursor]))
            return (r, t)
        }
        return json(["total_files": total, "files": rows.map { fileDict($0) },
                     "next_cursor": cursor + rows.count < total ? cursor + rows.count : NSNull()])
    }

    static func graphNeighbors(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let cid = args["chunk_id"]?.int else { throw ToolError.missingArg("chunk_id") }
        let direction = args["direction"]?.str ?? "both"
        let limit = min(args["limit"]?.int ?? 20, 200)
        let maxDepth = min(args["depth"]?.int ?? 1, 3)
        let kinds = args["edge_kinds"]?.strList ?? []
        var cond = ""
        var kindParams: [DatabaseValueConvertible] = []
        if !kinds.isEmpty {
            cond = " AND e.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
            kindParams = kinds
        }
        var out: [[String: Any]] = []
        try store.pool.read { db in
            // BFS expansion up to maxDepth; unresolved edges (dst_chunk NULL)
            // are emitted at their depth but can't be traversed further.
            var visited: Set<Int64> = [Int64(cid)]
            var frontier: [Int64] = [Int64(cid)]
            var depth = 0
            while !frontier.isEmpty, depth < maxDepth, out.count < limit {
                depth += 1
                let placeholders = frontier.map { _ in "?" }.joined(separator: ",")
                var next: [Int64] = []
                if direction != "incoming" {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT e.dst_chunk AS nid, e.kind, e.dst_name, e.line
                        FROM edges e WHERE e.src_chunk IN (\(placeholders)) \(cond)
                        """, arguments: StatementArguments(frontier + kindParams))
                    for r in rows {
                        let nid = r["nid"] as? Int64
                        out.append(["chunk_id": nid ?? NSNull(), "direction": "outgoing",
                                    "edge_kind": (r["kind"] as? String) ?? "",
                                    "dst_name": (r["dst_name"] as? String) ?? "",
                                    "line": (r["line"] as? Int64) ?? 0, "depth": depth])
                        if let nid, !visited.contains(nid) { visited.insert(nid); next.append(nid) }
                    }
                }
                if direction != "outgoing" {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT e.src_chunk AS nid, e.kind, e.dst_name, e.line
                        FROM edges e WHERE e.dst_chunk IN (\(placeholders)) \(cond)
                        """, arguments: StatementArguments(frontier + kindParams))
                    for r in rows {
                        let nid = r["nid"] as? Int64
                        out.append(["chunk_id": nid ?? NSNull(), "direction": "incoming",
                                    "edge_kind": (r["kind"] as? String) ?? "",
                                    "dst_name": (r["dst_name"] as? String) ?? "",
                                    "line": (r["line"] as? Int64) ?? 0, "depth": depth])
                        if let nid, !visited.contains(nid) { visited.insert(nid); next.append(nid) }
                    }
                }
                frontier = next
            }
            if out.count > limit { out = Array(out.prefix(limit)) }
        }
        // hydrate neighbor chunk metadata (+ optional source bodies)
        let ids = out.compactMap { $0["chunk_id"] as? Int64 }
        let meta = try chunkMeta(store: store, ids: ids)
        let includeContent = args["include_content"]?.bool ?? false
        let contents = includeContent ? try chunkContents(store: store, ids: ids) : [:]
        let hydrated = out.map { o -> [String: Any] in
            var o2 = o
            if let id = o["chunk_id"] as? Int64, var m = meta[id] {
                if let c = contents[id] { m["content"] = c }
                o2["chunk"] = m
            }
            return o2
        }
        return json(["chunk_id": cid, "neighbors": hydrated])
    }

    static func chunkMeta(store: Store, ids: [Int64]) throws -> [Int64: [String: Any]] {
        guard !ids.isEmpty else { return [:] }
        return try store.pool.read { db in
            var m: [Int64: [String: Any]] = [:]
            for id in Set(ids).prefix(100) {
                if let r = try Row.fetchOne(db, sql: """
                    SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                    FROM chunks c JOIN files f ON f.id = c.file_id WHERE c.id = ?
                    """, arguments: [id]) {
                    m[id] = chunkDict(r, content: false)
                }
            }
            return m
        }
    }

    static func graphPaths(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let from = args["from_chunk_id"]?.int,
              let to = args["to_chunk_id"]?.int else {
            throw ToolError.missingArg("from_chunk_id/to_chunk_id")
        }
        let maxHops = min(args["max_hops"]?.int ?? 5, 8)
        let maxPaths = min(max(args["max_paths"]?.int ?? 3, 1), 10)
        let includeContent = args["include_content"]?.bool ?? false
        let strategy = args["strategy"]?.str ?? "shortest"
        let kinds = args["edge_kinds"]?.strList ?? []
        let paths = try store.pool.read { db -> [[Int64]] in
            var adj: [Int64: [Int64]] = [:]
            let kindCond = kinds.isEmpty ? "" :
                " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
            let rows = try Row.fetchAll(db, sql:
                "SELECT src_chunk, dst_chunk FROM edges WHERE dst_chunk IS NOT NULL\(kindCond)",
                arguments: StatementArguments(kinds.map { $0 as DatabaseValueConvertible }))
            for r in rows {
                guard let src = r["src_chunk"] as? Int64, let dst = r["dst_chunk"] as? Int64 else { continue }
                adj[src, default: []].append(dst)
            }
            if strategy == "all" || strategy == "all_simple" {
                // DFS enumeration of simple paths (no repeated nodes), depth-
                // first so alternatives beyond the shortest are explored.
                var found: [[Int64]] = []
                var stack: [[Int64]] = [[Int64(from)]]
                while let path = stack.popLast(), found.count < maxPaths {
                    let last = path.last!
                    if last == Int64(to) { found.append(path); continue }
                    if path.count > maxHops { continue }
                    let inPath = Set(path)
                    for next in adj[last] ?? [] where !inPath.contains(next) {
                        stack.append(path + [next])
                    }
                }
                return found
            }
            // "shortest": BFS — nodes are consumed once, so paths found are
            // the shortest per reachable ordering.
            var found: [[Int64]] = []
            var queue: [[Int64]] = [[Int64(from)]]
            var seen: Set<Int64> = [Int64(from)]
            while let path = queue.first, found.count < maxPaths {
                queue.removeFirst()
                let last = path.last!
                if last == Int64(to) { found.append(path); continue }
                if path.count > maxHops { continue }
                for next in adj[last] ?? [] where !seen.contains(next) {
                    seen.insert(next)
                    queue.append(path + [next])
                }
            }
            return found
        }
        let allIDs = paths.flatMap { $0 }
        let meta = try chunkMeta(store: store, ids: allIDs)
        let contents = includeContent ? try chunkContents(store: store, ids: allIDs) : [:]
        let payload = paths.map { p in p.map { cid -> [String: Any] in
            var m = meta[cid] ?? ["chunk_id": cid]
            if let c = contents[cid] { m["content"] = c }
            return ["chunk_id": cid, "chunk": m] as [String: Any]
        } }
        return json(["paths": payload, "found": paths.count])
    }

    static func getImpact(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let cid = args["chunk_id"]?.int else { throw ToolError.missingArg("chunk_id") }
        let maxHops = min(args["max_hops"]?.int ?? 2, 4)
        // transitive incoming edges (dependents)
        let affected = try store.pool.read { db -> [Int64] in
            var seen: Set<Int64> = [Int64(cid)]
            var frontier: [Int64] = [Int64(cid)]
            var hops = 0
            while !frontier.isEmpty && hops < maxHops {
                let q = frontier.map { _ in "?" }.joined(separator: ",")
                let next = try Int64.fetchAll(db, sql:
                    "SELECT DISTINCT src_chunk FROM edges WHERE dst_chunk IN (\(q))",
                    arguments: StatementArguments(frontier))
                    .filter { !seen.contains($0) }
                seen.formUnion(next)
                frontier = next
                hops += 1
            }
            seen.remove(Int64(cid))
            return Array(seen)
        }
        let meta = try chunkMeta(store: store, ids: affected)
        let includeContent = args["include_content"]?.bool ?? false
        let contents = includeContent ? try chunkContents(store: store, ids: affected) : [:]
        return json(["chunk_id": cid, "max_hops": maxHops,
                     "dependents": affected.map { id -> [String: Any] in
                         var m = meta[id] ?? ["chunk_id": id]
                         if let c = contents[id] { m["content"] = c }
                         return m
                     }])
    }

    static func contextPack(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let q = args["query"]?.str else { throw ToolError.missingArg("query") }
        let budget = min(args["budget"]?.int ?? 12, 50)
        let expand = args["expand"]?.bool ?? true
        let result = try ContextPack.pack(store: store, query: q, budget: budget,
                                          expand: expand, pathFilter: args["path"]?.str)
        // Persist the pack as a durable record (ctxe parity: records store Ask
        // runs). try? degrades silently on pre-v2 indexes without the table.
        let evidence = (result["evidence"] as? [[String: Any]]) ?? []
        _ = try? store.insertRecord(kind: "context_pack", source: "mcp",
                                title: q.isEmpty ? "(no query)" : q,
                                payload: ["evidence_count": evidence.count,
                                          "chunk_ids": evidence.compactMap { $0["chunk_id"] as? Int64 }])
        return json(result)
    }

    // MARK: - graph_expand / fast_understand / records

    /// BFS from all seed chunk_ids (depth ≤ 2) over resolved edges. Each result
    /// carries depth, via (the chunk it was reached from) and the seed's score
    /// decayed by 0.7^depth. Dedupes by chunk_id keeping the smallest depth.
    static func graphExpand(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let seedVals = args["seeds"]?.arr, !seedVals.isEmpty else {
            throw ToolError.missingArg("seeds")
        }
        var seeds: [(id: Int64, score: Double)] = []
        var seedSeen: Set<Int64> = []
        for v in seedVals.prefix(50) {
            let parsed: (Int64, Double)?
            if let o = v.obj, let cid = o["chunk_id"]?.int {
                parsed = (Int64(cid), o["score"]?.dbl ?? 1.0)
            } else if let cid = v.int {
                parsed = (Int64(cid), 1.0)
            } else {
                parsed = nil
            }
            if let p = parsed, !seedSeen.contains(p.0) {
                seedSeen.insert(p.0)
                seeds.append(p)
            }
        }
        guard !seeds.isEmpty else { throw ToolError.missingArg("seeds") }
        let mode = args["mode"]?.str ?? "related"
        let includeContent = args["include_content"]?.bool ?? false
        let cap = 60
        var cond = ""
        var kindParams: [DatabaseValueConvertible] = []
        if mode == "calls" || mode == "imports" {
            cond = " AND e.kind = ?"
            kindParams = [mode]
        }
        var best: [Int64: (depth: Int, via: Int64, score: Double, kind: String)] = [:]
        try store.pool.read { db in
            var inGraph = Set(seeds.map(\.id))
            var frontier = seeds
            var depth = 0
            while !frontier.isEmpty, depth < 2, best.count < cap {
                depth += 1
                let fids = frontier.map(\.id)
                let ph = fids.map { _ in "?" }.joined(separator: ",")
                let fparams = fids.map { $0 as DatabaseValueConvertible }
                let scoreOf = Dictionary(uniqueKeysWithValues: frontier.map { ($0.id, $0.score) })
                var next: [(id: Int64, score: Double)] = []
                func record(_ nid: Int64, via f: Int64, kind: String) {
                    guard best.count < cap else { return }
                    let s = (scoreOf[f] ?? 1.0) * pow(0.7, Double(depth))
                    if !inGraph.contains(nid) {
                        inGraph.insert(nid)
                        best[nid] = (depth, f, s, kind)
                        next.append((nid, scoreOf[f] ?? 1.0))
                    } else if let b = best[nid], b.depth == depth, s > b.score {
                        best[nid] = (depth, f, s, kind)
                    }
                }
                // Same SQL shape as graphNeighbors, resolved edges only.
                for r in try Row.fetchAll(db, sql: """
                    SELECT e.src_chunk AS f, e.dst_chunk AS nid, e.kind
                    FROM edges e WHERE e.dst_chunk IS NOT NULL
                    AND e.src_chunk IN (\(ph)) \(cond)
                    """, arguments: StatementArguments(fparams + kindParams)) {
                    guard let f = r["f"] as? Int64, let nid = r["nid"] as? Int64 else { continue }
                    record(nid, via: f, kind: (r["kind"] as? String) ?? "")
                }
                for r in try Row.fetchAll(db, sql: """
                    SELECT e.dst_chunk AS f, e.src_chunk AS nid, e.kind
                    FROM edges e WHERE e.dst_chunk IS NOT NULL
                    AND e.dst_chunk IN (\(ph)) \(cond)
                    """, arguments: StatementArguments(fparams + kindParams)) {
                    guard let f = r["f"] as? Int64, let nid = r["nid"] as? Int64 else { continue }
                    record(nid, via: f, kind: (r["kind"] as? String) ?? "")
                }
                frontier = next
            }
        }
        let sorted = best.sorted { a, b in
            a.value.depth != b.value.depth
                ? a.value.depth < b.value.depth
                : (a.value.score != b.value.score ? a.value.score > b.value.score : a.key < b.key)
        }.prefix(cap)
        let ids = sorted.map(\.key)
        let meta = try chunkMeta(store: store, ids: ids)
        let contents = includeContent ? try chunkContents(store: store, ids: ids) : [:]
        let results = sorted.map { (cid, b) -> [String: Any] in
            var d: [String: Any] = [
                "chunk_id": cid, "depth": b.depth, "via": b.via,
                "score": (b.score * 10000).rounded() / 10000,
                "edge_kind": b.kind,
            ]
            if var m = meta[cid] {
                if includeContent, let c = contents[cid] { m["content"] = c }
                d["chunk"] = m
            }
            return d
        }
        return json(["mode": mode, "seed_count": seeds.count,
                     "count": results.count, "results": results])
    }

    static func fastUnderstand(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        let digest = try Understand.digest(store: store, query: args["query"]?.str)
        return json(digest)
    }

    static func recordDict(_ row: Row, includePayload: Bool = true) -> [String: Any] {
        var d: [String: Any] = [
            "id": (row["id"] as? Int64) ?? -1,
            "kind": (row["kind"] as? String) ?? "",
            "source": (row["source"] as? String) ?? "",
            "status": (row["status"] as? String) ?? "",
            "title": (row["title"] as? String) ?? "",
            "created_at": (row["created_at"] as? Double) ?? 0,
        ]
        guard includePayload else { return d }
        if let p = row["payload"] as? String,
           let obj = try? JSONSerialization.jsonObject(with: Data(p.utf8)) {
            d["payload"] = obj
        } else {
            d["payload"] = (row["payload"] as? String) ?? ""
        }
        return d
    }

    static func recordFilters(_ args: [String: Value], alias: String) -> (String, [DatabaseValueConvertible]) {
        var clauses: [String] = []
        var params: [DatabaseValueConvertible] = []
        if let k = args["kind"]?.str, !k.isEmpty {
            clauses.append("\(alias)kind = ?"); params.append(k)
        }
        if let s = args["source"]?.str, !s.isEmpty {
            clauses.append("\(alias)source = ?"); params.append(s)
        }
        if let s = args["status"]?.str, !s.isEmpty {
            clauses.append("\(alias)status = ?"); params.append(s)
        }
        return (clauses.joined(separator: " AND "), params)
    }

    static func getRecord(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let id = args["id"]?.int else { throw ToolError.missingArg("id") }
        do {
            guard let row = try store.pool.read({ db in
                try Row.fetchOne(db, sql: """
                    SELECT id, kind, source, status, title, payload, created_at
                    FROM records WHERE id = ?
                    """, arguments: [id])
            }) else {
                return json(["error": "record not found", "id": id])
            }
            return json(["record": recordDict(
                row, includePayload: args["include_payload"]?.bool ?? true)])
        } catch {
            return json(["error": "records unavailable: \(error.localizedDescription)"])
        }
    }

    static func listRecords(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        let limit = min(max(args["limit"]?.int ?? 50, 1), 100)
        let offset = max(args["offset"]?.int ?? 0, 0)
        let (whereSQL, params) = recordFilters(args, alias: "")
        let whereClause = whereSQL.isEmpty ? "" : " WHERE \(whereSQL)"
        do {
            let (rows, total) = try store.pool.read { db in
                let t = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records\(whereClause)",
                                         arguments: StatementArguments(params)) ?? 0
                let r = try Row.fetchAll(db, sql: """
                    SELECT id, kind, source, status, title, payload, created_at
                    FROM records\(whereClause) ORDER BY id DESC LIMIT ? OFFSET ?
                    """, arguments: StatementArguments(params + [limit, offset]))
                return (r, t)
            }
            return json(["records": rows.map { recordDict($0) }, "total": total])
        } catch {
            return json(["error": "records unavailable: \(error.localizedDescription)"])
        }
    }

    static func searchRecords(_ args: [String: Value]) throws -> String {
        let store = try store(args)
        guard let q = args["query"]?.str else { throw ToolError.missingArg("query") }
        let limit = min(max(args["limit"]?.int ?? 50, 1), 100)
        let offset = max(args["offset"]?.int ?? 0, 0)
        guard let match = Search.ftsQuery(q) else {
            return json(["records": [Any](), "total": 0])
        }
        let (filterSQL, filterParams) = recordFilters(args, alias: "r.")
        let whereClause = filterSQL.isEmpty ? "" : " AND \(filterSQL)"
        do {
            let (rows, total) = try store.pool.read { db in
                let t = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM records_fts JOIN records r ON r.id = records_fts.rowid
                    WHERE records_fts MATCH ?\(whereClause)
                    """, arguments: StatementArguments([match] + filterParams)) ?? 0
                let r = try Row.fetchAll(db, sql: """
                    SELECT r.id, r.kind, r.source, r.status, r.title, r.payload, r.created_at,
                           bm25(records_fts) AS rank
                    FROM records_fts JOIN records r ON r.id = records_fts.rowid
                    WHERE records_fts MATCH ?\(whereClause)
                    ORDER BY rank LIMIT ? OFFSET ?
                    """, arguments: StatementArguments([match] + filterParams + [limit, offset]))
                return (r, t)
            }
            return json(["records": rows.map { recordDict($0) }, "total": total])
        } catch {
            return json(["error": "records unavailable: \(error.localizedDescription)"])
        }
    }

    public static func call(name: String, arguments: [String: Value]) async throws -> String {
        switch name {
        case "context_pack": return try contextPack(arguments)
        case "get_status": return try getStatus(arguments)
        case "index_workspace": return try indexWorkspace(arguments)
        case "list_workspaces": return try listWorkspaces(arguments)
        case "search": return try search(arguments)
        case "find_definitions": return try findDefinitions(arguments)
        case "find_usages": return try findUsages(arguments)
        case "fetch_chunks": return try fetchChunks(arguments)
        case "inspect_path": return try inspectPath(arguments)
        case "get_workspace_tree": return try workspaceTree(arguments)
        case "graph_neighbors": return try graphNeighbors(arguments)
        case "graph_expand": return try graphExpand(arguments)
        case "graph_paths": return try graphPaths(arguments)
        case "get_impact": return try getImpact(arguments)
        case "fast_understand": return try fastUnderstand(arguments)
        case "get_record": return try getRecord(arguments)
        case "list_records": return try listRecords(arguments)
        case "search_records": return try searchRecords(arguments)
        default: throw ToolError.unknownTool(name)
        }
    }
}
