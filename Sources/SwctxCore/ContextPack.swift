import Foundation
import GRDB

/// Deterministic multi-round evidence packer — the local, no-LLM equivalent of
/// ctxe's `ask_context` (compose=false): lexical+semantic retrieval, then one
/// graph hop of expansion so an external agent gets both the answer chunks and
/// the call-graph context around them, with provenance per item.
public enum ContextPack {

    /// - direct hits carry full `content`; expanded neighbors carry metadata only
    ///   (agent calls fetch_chunks for bodies it actually needs).
    public static func pack(store: Store, query: String, budget: Int,
                            expand: Bool, pathFilter: String?) throws -> [String: Any] {
        let embedder = store.embedder
        let hits = try Search.hybrid(store: store, embedder: embedder, query: query,
                                     limit: max(budget, 8), pathFilter: pathFilter)
        var evidence: [[String: Any]] = []
        var seen: Set<Int64> = []
        var directIDs: [Int64] = []
        // Reserve ~1/3 of the budget for graph-expanded neighbors.
        let directCap = expand ? max(3, budget * 2 / 3) : budget
        for h in hits where !seen.contains(h.chunkID) && directIDs.count < directCap {
            seen.insert(h.chunkID)
            directIDs.append(h.chunkID)
            var d: [String: Any] = [
                "chunk_id": h.chunkID, "path": h.path,
                "start_line": h.startLine, "end_line": h.endLine,
                "score": h.score, "why": "direct",
            ]
            if let k = h.kind { d["kind"] = k }
            if let s = h.symbol { d["symbol"] = s }
            if !h.snippet.isEmpty { d["snippet"] = h.snippet }
            evidence.append(d)
        }

        var truncated = false
        if expand && !directIDs.isEmpty {
            let cap = max(2, budget / max(1, directIDs.count))
            let neighbors = try oneHop(store: store, seeds: directIDs, perSeed: cap)
            for n in neighbors where !seen.contains(n.id) {
                if evidence.count >= budget { truncated = true; break }
                seen.insert(n.id)
                var d: [String: Any] = [
                    "chunk_id": n.id, "path": n.path,
                    "start_line": n.startLine, "end_line": n.endLine,
                    "why": n.why, "via_chunk_id": n.via,
                ]
                if let k = n.kind { d["kind"] = k }
                if let s = n.symbol { d["symbol"] = s }
                evidence.append(d)
            }
        }
        if evidence.count > budget {
            evidence = Array(evidence.prefix(budget))
            truncated = true
        }
        // hydrate content for direct hits only
        let contents = try contents(store: store, ids: directIDs)
        for i in evidence.indices where evidence[i]["why"] as? String == "direct" {
            if let cid = evidence[i]["chunk_id"] as? Int64, let c = contents[cid] {
                evidence[i]["content"] = c
            }
        }
        return [
            "query": query, "hits_considered": hits.count,
            "evidence": evidence, "truncated": truncated,
        ]
    }

    struct Neighbor {
        var id: Int64; var via: Int64; var why: String
        var path: String; var startLine: Int; var endLine: Int
        var kind: String?; var symbol: String?
    }

    /// Outgoing callees ("calls") + incoming dependents ("called_by"), per seed.
    static func oneHop(store: Store, seeds: [Int64], perSeed: Int) throws -> [Neighbor] {
        try store.pool.read { db in
            var out: [Neighbor] = []
            for seed in seeds {
                let callees = try Row.fetchAll(db, sql: """
                    SELECT e.dst_chunk AS nid FROM edges e
                    WHERE e.src_chunk = ? AND e.dst_chunk IS NOT NULL LIMIT ?
                    """, arguments: [seed, perSeed])
                let callers = try Row.fetchAll(db, sql: """
                    SELECT e.src_chunk AS nid FROM edges e
                    WHERE e.dst_chunk = ? LIMIT ?
                    """, arguments: [seed, perSeed])
                for r in callees {
                    if let id = r["nid"] as? Int64 {
                        out.append(Neighbor(id: id, via: seed, why: "calls",
                                            path: "", startLine: 0, endLine: 0))
                    }
                }
                for r in callers {
                    if let id = r["nid"] as? Int64 {
                        out.append(Neighbor(id: id, via: seed, why: "called_by",
                                            path: "", startLine: 0, endLine: 0))
                    }
                }
            }
            // hydrate metadata
            let ids = out.map(\.id)
            guard !ids.isEmpty else { return out }
            let q = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                FROM chunks c JOIN files f ON f.id = c.file_id WHERE c.id IN (\(q))
                """, arguments: StatementArguments(ids))
            var meta: [Int64: Row] = [:]
            for r in rows { if let id = r["id"] as? Int64 { meta[id] = r } }
            for i in out.indices {
                guard let r = meta[out[i].id] else { continue }
                out[i].path = (r["path"] as? String) ?? ""
                out[i].startLine = Int((r["start_line"] as? Int64) ?? 0)
                out[i].endLine = Int((r["end_line"] as? Int64) ?? 0)
                out[i].kind = r["kind"] as? String
                out[i].symbol = r["symbol"] as? String
            }
            return out.filter { !$0.path.isEmpty }
        }
    }

    static func contents(store: Store, ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let q = ids.map { _ in "?" }.joined(separator: ",")
        return try store.pool.read { db in
            var m: [Int64: String] = [:]
            for r in try Row.fetchAll(db, sql:
                "SELECT id, content FROM chunks WHERE id IN (\(q))",
                arguments: StatementArguments(ids)) {
                if let id = r["id"] as? Int64 { m[id] = r["content"] as? String }
            }
            return m
        }
    }
}
