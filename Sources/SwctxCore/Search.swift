import Accelerate
import Foundation
import GRDB

public struct SearchHit {
    public var chunkID: Int64
    public var path: String
    public var startLine: Int
    public var endLine: Int
    public var kind: String?
    public var symbol: String?
    public var score: Double
    public var snippet: String
}

public enum Search {
    /// Build a safe FTS5 MATCH query: OR of quoted tokens with prefix matching.
    static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(12).map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    public static func fts(store: Store, query: String, limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        guard let match = ftsQuery(query) else { return [] }
        return try store.pool.read { db in
            var sql = """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol,
                       bm25(chunks_fts) AS rank,
                       snippet(chunks_fts, 0, '«', '»', ' … ', 24) AS snippet
                FROM chunks_fts
                JOIN chunks c ON c.id = chunks_fts.rowid
                JOIN files f ON f.id = c.file_id
                WHERE chunks_fts MATCH ?
                """
            var args: [DatabaseValueConvertible] = [match]
            if let p = pathFilter, !p.isEmpty {
                sql += " AND f.path LIKE ?"
                args.append(p.hasSuffix("/") ? p + "%" : p + "/%")
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchHit(
                    chunkID: (row["id"] as? Int64) ?? -1, path: (row["path"] as? String) ?? "",
                    startLine: Int((row["start_line"] as? Int64) ?? 0), endLine: Int((row["end_line"] as? Int64) ?? 0),
                    kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                    score: -((row["rank"] as? Double) ?? 0), snippet: (row["snippet"] as? String) ?? "")
            }
        }
    }

    /// Brute-force cosine over stored (normalized) embeddings.
    public static func semantic(store: Store, embedder: Embedder, query: String,
                                limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        guard let qv = embedder.embed(query) else { return [] }
        let rows = try store.pool.read { db in
            var sql = """
                SELECT e.chunk_id, e.dim, e.vec, f.path, c.start_line, c.end_line,
                       c.kind, c.symbol
                FROM embeddings e
                JOIN chunks c ON c.id = e.chunk_id
                JOIN files f ON f.id = c.file_id
                """
            var args: [DatabaseValueConvertible] = []
            if let f = pathFilter {
                let prefix = f.hasSuffix("/") ? f : f + "/"
                sql += " WHERE (f.path = ? OR f.path LIKE ?)"
                args.append(f)
                args.append(prefix + "%")
            }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        var scored: [(Int64, Float)] = []
        scored.reserveCapacity(rows.count)
        var byID: [Int64: Row] = [:]
        for row in rows {
            guard let blob = row["vec"] as? Data, let dim = row["dim"] as? Int64 else { continue }
            // Score straight off the blob bytes — identical to Embedder.vector +
            // dot (prefix(dim) clamp, count-guarded vDSP_dotpr) minus the copy.
            let s: Float = blob.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                let n = min(Int(dim), floats.count)
                guard n == qv.count, let base = floats.baseAddress else { return 0 }
                var result: Float = 0
                vDSP_dotpr(qv, 1, base, 1, &result, vDSP_Length(n))
                return result
            }
            if s > 0.05, let cid = row["chunk_id"] as? Int64 {
                scored.append((cid, s))
                byID[cid] = row
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).compactMap { (cid, score) in
            guard let row = byID[cid] else { return nil }
            return SearchHit(
                chunkID: cid, path: (row["path"] as? String) ?? "", startLine: Int((row["start_line"] as? Int64) ?? 0),
                endLine: Int((row["end_line"] as? Int64) ?? 0), kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                score: Double(score), snippet: "")
        }
    }

    /// Split an identifier into lowercase subtokens ("runPipeline" -> [run, pipeline]).
    static func symbolTokens(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var cur = ""
        for ch in s {
            if ch.isUppercase, let last = cur.last, last.isLowercase {
                out.insert(cur.lowercased()); cur = ""
            }
            if ch.isLetter || ch.isNumber { cur.append(ch) } else if !cur.isEmpty {
                out.insert(cur.lowercased()); cur = ""
            }
        }
        if !cur.isEmpty { out.insert(cur.lowercased()) }
        return out
    }

    /// Accent-fold for path/term matching: diacritic-insensitive + case fold,
    /// plus explicit đ/Đ → d (standalone letters Unicode folding leaves intact).
    static func foldText(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
    }

    /// Chunks defining a symbol whose name exactly equals a query token
    /// (identifier-lookup intent). Prose docs mentioning the word never
    /// appear in this leg, so vector noise cannot bury real definitions.
    static func symbolHits(store: Store, query: String, limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        var terms = Set(query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }.prefix(12))
        let whole = query.trimmingCharacters(in: .whitespaces)
        if whole.count >= 2, !whole.contains(" ") { terms.insert(whole.lowercased()) }
        guard !terms.isEmpty else { return [] }
        return try store.pool.read { db in
            var sql = """
                SELECT DISTINCT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                FROM symbols s
                JOIN chunks c ON c.id = s.chunk_id
                JOIN files f ON f.id = c.file_id
                WHERE lower(s.name) IN (\(terms.map { _ in "?" }.joined(separator: ",")))
                """
            var args: [DatabaseValueConvertible] = terms.map { $0 as DatabaseValueConvertible }
            if let p = pathFilter, !p.isEmpty {
                sql += " AND f.path LIKE ?"
                args.append((p.hasSuffix("/") ? p + "%" : p + "/%") as DatabaseValueConvertible)
            }
            // Def-chunks (the chunk's own symbol is the match) rank first.
            sql += " ORDER BY CASE WHEN lower(c.symbol) = lower(s.name) THEN 0 ELSE 1 END, f.path LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchHit(
                    chunkID: (row["id"] as? Int64) ?? -1, path: (row["path"] as? String) ?? "",
                    startLine: Int((row["start_line"] as? Int64) ?? 0), endLine: Int((row["end_line"] as? Int64) ?? 0),
                    kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                    score: 0, snippet: "")
            }
        }
    }

    /// Identifier-shaped lookup (snake_case, CamelCase, `::`, dotted or
    /// path-like single token). Such queries are definition lookups, so the
    /// vector leg adds cost and noise without upside.
    public static func identifierLike(_ query: String) -> Bool {
        let t = query.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" "), t.count >= 2 else { return false }
        if t.range(of: #"[_:.\\/\-]"#, options: .regularExpression) != nil { return true }
        // camelCase or ALLCAPS signal: an uppercase letter that is not the
        // leading character of a plain Capitalized word still counts.
        return t.range(of: #"[a-z][A-Z]|[A-Z][a-z]+[A-Z]|^[A-Z][a-z]*$"#, options: .regularExpression) != nil
    }

    /// Reciprocal-rank fusion of FTS + semantic hits, with deterministic
    /// symbol/path boosts and a small legacy-archive penalty. `includeVector`
    /// false skips embedding entirely (identifier lookups).
    public static func hybrid(store: Store, embedder: Embedder, query: String,
                              limit: Int, pathFilter: String? = nil,
                              includeVector: Bool = true) throws -> [SearchHit] {
        let ftsHits = try fts(store: store, query: query, limit: limit * 3, pathFilter: pathFilter)
        let vecHits = includeVector
            ? try semantic(store: store, embedder: embedder, query: query, limit: limit * 3, pathFilter: pathFilter)
            : []
        let symHits = try symbolHits(store: store, query: query, limit: limit * 3, pathFilter: pathFilter)
        var rrf: [Int64: Double] = [:]
        for (i, h) in ftsHits.enumerated() { rrf[h.chunkID, default: 0] += 1.0 / (60 + Double(i) + 1) }
        for (i, h) in vecHits.enumerated() { rrf[h.chunkID, default: 0] += 1.0 / (60 + Double(i) + 1) }
        // Exact-symbol leg gets full leg weight: an identifier token is a
        // strong intent signal, so its definitions deserve top placement.
        for (i, h) in symHits.enumerated() { rrf[h.chunkID, default: 0] += 1.0 / (60 + Double(i) + 1) }
        var byID: [Int64: SearchHit] = [:]
        for h in ftsHits + vecHits + symHits { byID[h.chunkID] = h }

        let terms = Set(query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }.prefix(12))
        // Folded term set for path matching only: substring matching on the
        // raw path produced phantom boosts ("quantri" inside unrelated paths)
        // and accented VN terms could never match ASCII path tokens.
        let termsFolded = Set(terms.map(foldText))
        return rrf.map { (cid, score) -> (Int64, Double) in
            guard let h = byID[cid] else { return (cid, score) }
            var boost = 0.0
            if let sym = h.symbol {
                let st = symbolTokens(sym)
                boost += 0.03 * Double(terms.intersection(st).count)
            }
            let lp = h.path.lowercased()
            let pathTokens = Set(foldText(h.path)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 })
            boost += 0.015 * Double(termsFolded.intersection(pathTokens).count)
            if lp.hasPrefix("archive/") { boost -= 0.01 }
            return (cid, score + min(boost, 0.09))
        }.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { (cid, score) in
            guard var h = byID[cid] else { return nil }
            h.score = score
            return h
        }
    }
}
