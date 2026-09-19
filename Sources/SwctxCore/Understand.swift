import Foundation
import GRDB

/// Deterministic, no-LLM "understand this workspace" digest — the local answer
/// to ctxe's fast_understand anchor. One read pass over the index: counts,
/// language mix, graph hubs, hot files, call/import communities, recent files,
/// and (optionally) the top semantic matches for a query.
public enum Understand {

    /// Union-find over resolved-edge chunk ids for community detection.
    private final class UnionFind {
        private var parent: [Int64: Int64] = [:]
        private var rank: [Int64: Int] = [:]

        private func add(_ x: Int64) {
            if parent[x] == nil { parent[x] = x; rank[x] = 0 }
        }

        func find(_ x: Int64) -> Int64 {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }

        func union(_ a: Int64, _ b: Int64) {
            add(a); add(b)
            let ra = find(a), rb = find(b)
            if ra == rb { return }
            if (rank[ra] ?? 0) < (rank[rb] ?? 0) {
                parent[ra] = rb
            } else {
                parent[rb] = ra
                if rank[ra] == rank[rb] { rank[ra] = (rank[ra] ?? 0) + 1 }
            }
        }

        func components() -> [[Int64]] {
            var groups: [Int64: [Int64]] = [:]
            for x in parent.keys { groups[find(x), default: []].append(x) }
            return Array(groups.values)
        }
    }

    /// Keep head for symbol names ("…" marks truncation).
    static func truncHead(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    /// Keep tail for paths — the informative end survives ("…" marks truncation).
    static func truncTail(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : "…" + s.suffix(n - 1)
    }

    static func topDir(_ path: String) -> String {
        guard let i = path.firstIndex(of: "/") else { return "(root)" }
        return String(path[path.startIndex..<i])
    }

    public static func digest(store: Store, query: String? = nil) throws -> [String: Any] {
        var out: [String: Any] = ["workspace": store.workspaceRoot.path]
        try store.pool.read { db in
            out["files_total"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
            out["chunks_total"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            out["symbols_total"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM symbols") ?? 0

            out["languages"] = try Row.fetchAll(db, sql: """
                SELECT lang, COUNT(*) AS c FROM files GROUP BY lang ORDER BY c DESC, lang LIMIT 8
                """).map { r -> [String: Any] in
                    ["lang": (r["lang"] as? String) ?? "",
                     "files": (r["c"] as? Int64) ?? 0]
                }

            // Top symbols by resolved in-degree: symbol rows joined to edges
            // through their chunk (e.dst_chunk = s.chunk_id), counting incoming.
            out["hub_symbols"] = try Row.fetchAll(db, sql: """
                SELECT s.name, f.path, COUNT(e.id) AS deg
                FROM symbols s
                JOIN edges e ON e.dst_chunk = s.chunk_id
                JOIN files f ON f.id = s.file_id
                GROUP BY s.id ORDER BY deg DESC, s.id LIMIT 15
                """).map { r -> [String: Any] in
                    ["name": truncHead((r["name"] as? String) ?? "", 28),
                     "deg": (r["deg"] as? Int64) ?? 0,
                     "file": truncHead((((r["path"] as? String) ?? "") as NSString).lastPathComponent, 24)]
                }

            // Files with the most distinct resolved-edge endpoint chunks.
            out["hot_files"] = try Row.fetchAll(db, sql: """
                SELECT f.path, COUNT(DISTINCT c.id) AS eps
                FROM files f JOIN chunks c ON c.file_id = f.id
                WHERE c.id IN (
                    SELECT src_chunk FROM edges WHERE dst_chunk IS NOT NULL
                    UNION
                    SELECT dst_chunk FROM edges WHERE dst_chunk IS NOT NULL)
                GROUP BY f.id ORDER BY eps DESC, f.path LIMIT 10
                """).map { r -> [String: Any] in
                    ["path": truncTail((r["path"] as? String) ?? "", 40),
                     "endpoints": (r["eps"] as? Int64) ?? 0]
                }

            // Connected components of the resolved call/import graph (union-find).
            let uf = UnionFind()
            for r in try Row.fetchAll(db, sql:
                "SELECT src_chunk, dst_chunk FROM edges WHERE dst_chunk IS NOT NULL") {
                if let a = r["src_chunk"] as? Int64, let b = r["dst_chunk"] as? Int64 {
                    uf.union(a, b)
                }
            }
            var chunkPath: [Int64: String] = [:]
            chunkPath.reserveCapacity(4096)
            for r in try Row.fetchAll(db, sql: """
                SELECT c.id, f.path FROM chunks c JOIN files f ON f.id = c.file_id
                """) {
                if let id = r["id"] as? Int64 { chunkPath[id] = (r["path"] as? String) ?? "" }
            }
            let comps = uf.components().sorted { $0.count > $1.count }
            var communities: [[String: Any]] = []
            for comp in comps.prefix(8) {
                var fileSet: Set<String> = []
                for cid in comp {
                    if let p = chunkPath[cid], !p.isEmpty { fileSet.insert(p) }
                }
                var hist: [String: Int] = [:]
                for f in fileSet { hist[topDir(f), default: 0] += 1 }
                let label = hist.max { a, b in
                    a.value != b.value ? a.value < b.value : a.key > b.key
                }?.key ?? "?"
                communities.append(["label": truncHead(label, 28), "size": comp.count])
            }
            out["communities"] = communities

            out["recent_files"] = try Row.fetchAll(db, sql: """
                SELECT path, mtime FROM files ORDER BY mtime DESC, path LIMIT 10
                """).map { r -> [String: Any] in
                    ["path": truncTail((r["path"] as? String) ?? "", 40),
                     "mtime": Int((r["mtime"] as? Double) ?? 0)]
                }
        }

        if let q = query, !q.isEmpty {
            let hits = try Search.hybrid(store: store, embedder: store.embedder, query: q, limit: 5)
            out["relevant"] = hits.map { h -> [String: Any] in
                var d: [String: Any] = [
                    "chunk_id": h.chunkID,
                    "path": truncTail(h.path, 40),
                    "score": (h.score * 1000).rounded() / 1000,
                ]
                if let s = h.symbol { d["symbol"] = truncHead(s, 28) }
                return d
            }
        }
        return out
    }
}
