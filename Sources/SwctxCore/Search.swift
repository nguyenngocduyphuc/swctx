import Accelerate
import Foundation
import GRDB

public struct SearchHit: Sendable {
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

    /// Query tokens whose diacritic fold differs ("chấm" → "cham",
    /// "công" → "cong"). unicode61 folds case but never folds đ (U+0111),
    /// so Vietnamese needs these app-level variants.
    static func foldedVariantTokens(_ raw: String) -> [String] {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        var out: [String] = []
        var seen: Set<String> = []
        for t in tokens.prefix(12) {
            let f = foldText(t)
            if f != t.lowercased(), f.count >= 2, seen.insert(f).inserted {
                out.append(f)
            }
        }
        return out
    }

    /// Folded-only variant query scoped to the `folded` column — one term
    /// per diacritic-differing token. Column-scoped on purpose: folded
    /// matches score only through the cheap folded column and the leg is
    /// used strictly as a tail-filler after real hits — extra candidates
    /// in the shared window measurably displace borderline real hits.
    static func ftsFoldedQuery(_ raw: String) -> String? {
        let terms = foldedVariantTokens(raw).map { "folded : \"\($0)\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// Folded adjacent-token PHRASES on path_tokens: "chấm công"
    /// probes path_tokens : "cham cong" — matching folded snake_case
    /// filenames like cham_cong.py. Phrases are far more discriminating
    /// than term-OR probes: term-level folded matches flooded windows
    /// with common VN path tokens on every earlier attempt, while a
    /// phrase on the 2.5-weighted path column gives filename intent a
    /// real score without touching the fts window.
    static func foldedPhraseQuery(_ raw: String) -> String? {
        let toks = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        var terms: [String] = []
        var seen: Set<String> = []
        for pair in zip(toks, toks.dropFirst()) {
            guard terms.count < 16 else { break }
            let f = foldText(pair.0 + " " + pair.1)
            if f != (pair.0 + " " + pair.1).lowercased(),
               f.count >= 3, seen.insert(f).inserted {
                terms.append("path_tokens : \"\(f)\"")
            }
        }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// BM25F column weights for chunks_fts(content, path_tokens,
    /// symbol_names, folded). Order must match the CREATE TABLE column
    /// order exactly — body hits are baseline, path/symbol hits outrank
    /// them, and folded-only matches are deliberately cheap so variant
    /// noise can't outrank real hits.
    static let ftsColumnWeights: (content: Double, path: Double, symbol: Double, folded: Double) =
        (1.0, 2.5, 5.0, 0.6)

    /// Post-hoc boost magnitudes (all inside the 0.09 cap, tuned on
    /// bench/vn_probe.py — RRF scores total ~0.05, so boosts must stay
    /// small to adjust order without drowning the fused signal).
    static let coverageWeight = 0.01        // per DISTINCT folded term present
    static let coverageCap = 0.03           // sub-cap on the coverage term
    static let pagerankWeight = 0.02        // × min-max normalized file rank
    static let depthPenaltyPerSegment = 0.005
    /// Folded-phrase rescue leg weight — below the real legs; it exists
    /// to surface diacritic phrase matches, not outrank them.
    static let phraseLegWeight = 0.8

    /// Per-leg RRF weights (fts, semantic, symbol). Defaults are uniform;
    /// `SWCTX_RRF_W="f,s,y"` overrides for bench sweeps only — tuned
    /// values get baked in as new defaults once measured, not left
    /// env-dependent.
    static func fusionWeights() -> (fts: Double, sem: Double, sym: Double) {
        if let s = ProcessInfo.processInfo.environment["SWCTX_RRF_W"] {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 3, p.allSatisfy({ $0 >= 0 }) {
                return (p[0], p[1], p[2])
            }
        }
        return (1.0, 1.0, 1.0)
    }

    public static func fts(store: Store, query: String, limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        guard let match = ftsQuery(query) else { return [] }
        var hits = try ftsRun(store: store, match: match, limit: limit,
                              pathFilter: pathFilter)
        // Folded rescue as tail-filler only (same contract as the trigram
        // leg): when real hits under-fill the request, column-scoped
        // folded matches top it up. They can never displace real hits —
        // mixing them into the shared window measurably pushed
        // borderline files out of the fused pool (seo-02, vn_probe).
        if hits.count < limit, let fmatch = ftsFoldedQuery(query) {
            hits += try ftsRun(store: store, match: fmatch,
                               limit: limit - hits.count, pathFilter: pathFilter,
                               excluding: Set(hits.map { $0.chunkID }))
        }
        return hits
    }

    private static func ftsRun(store: Store, match: String, limit: Int,
                               pathFilter: String? = nil,
                               excluding: Set<Int64> = []) throws -> [SearchHit] {
        let w = ftsColumnWeights
        return try store.pool.read { db in
            var sql = """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol,
                       bm25(chunks_fts, \(w.content), \(w.path), \(w.symbol), \(w.folded)) AS rank,
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
            if !excluding.isEmpty {
                sql += " AND c.id NOT IN (\(excluding.map { String($0) }.joined(separator: ",")))"
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

    /// Process-level cache for the semantic leg's vector matrix. Stores are
    /// created per tool call, so the matrix must outlive them; entries are
    /// validated by `Store.embeddingsSignature()` (one tiny meta read) and
    /// evicted LRU. Scores are identical to a fresh read — same float32s —
    /// so this changes latency, not ranking.
    struct CachedVectors {
        var signature: String
        var dim: Int
        var ids: [Int64]
        var matrix: [Float]  // ids.count × dim, row-major contiguous
        var lastUse: Date
    }
    static let vectorCache = VectorCacheBox()

    /// All mutable state is behind `lock`; entries are value types never
    /// mutated after storage — safe to share across the MCP server's tasks.
    final class VectorCacheBox: @unchecked Sendable {
        private var lock = NSLock()
        private var entries: [String: CachedVectors] = [:]
        private let maxEntries = 4
        private let maxBytes = 512 << 20

        func cached(key: String, signature: String, dim: Int) -> CachedVectors? {
            lock.lock(); defer { lock.unlock() }
            guard var e = entries[key],
                  e.signature == signature, e.dim == dim else { return nil }
            e.lastUse = Date(); entries[key] = e
            return e
        }
        func store(key: String, entry: CachedVectors) {
            guard entry.matrix.count * 4 <= maxBytes else { return }
            lock.lock(); defer { lock.unlock() }
            entries[key] = entry
            if entries.count > maxEntries,
               let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }

    /// Brute-force cosine over stored (normalized) embeddings.
    public static func semantic(store: Store, embedder: Embedder, query: String,
                                limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        guard let qv = embedder.embed(query) else { return [] }
        if pathFilter != nil {
            return try semanticFiltered(store: store, qv: qv, limit: limit,
                                        pathFilter: pathFilter!)
        }
        let key = Store.key(for: store.workspaceRoot)
        let sig = try store.embeddingsSignature()
        var entry = vectorCache.cached(key: key, signature: sig, dim: qv.count)
        if entry == nil {
            entry = try loadVectors(store: store, signature: sig, dim: qv.count)
            if let e = entry { vectorCache.store(key: key, entry: e) }
        }
        guard let e = entry, !e.ids.isEmpty else { return [] }

        // All dots in one BLAS call (matrix row-major, qv unit-length).
        let n = e.ids.count
        var scores = [Float](repeating: 0, count: n)
        e.matrix.withUnsafeBufferPointer { m in
            qv.withUnsafeBufferPointer { q in
                scores.withUnsafeMutableBufferPointer { s in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(e.dim),
                                1.0, m.baseAddress!, Int32(e.dim),
                                q.baseAddress!, 1, 0.0, s.baseAddress!, 1)
                }
            }
        }
        var scored: [(Int64, Float)] = []
        scored.reserveCapacity(64)
        for i in 0..<n where scores[i] > 0.05 {
            scored.append((e.ids[i], scores[i]))
        }
        scored.sort { $0.1 > $1.1 }
        let top = scored.prefix(limit)
        guard !top.isEmpty else { return [] }

        // Chunk metadata only for the handful of winners — the old query
        // joined path/lines for every row in the corpus.
        let topIDs = top.map { $0.0 }
        let ph = topIDs.map { _ in "?" }.joined(separator: ",")
        let metaRows = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                FROM chunks c JOIN files f ON f.id = c.file_id
                WHERE c.id IN (\(ph))
                """, arguments: StatementArguments(topIDs))
        }
        var meta: [Int64: Row] = [:]
        meta.reserveCapacity(metaRows.count)
        for r in metaRows {
            if let id = r["id"] as? Int64 { meta[id] = r }
        }
        return top.compactMap { (cid, score) in
            guard let row = meta[cid] else { return nil }
            return SearchHit(
                chunkID: cid, path: (row["path"] as? String) ?? "",
                startLine: Int((row["start_line"] as? Int64) ?? 0),
                endLine: Int((row["end_line"] as? Int64) ?? 0),
                kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                score: Double(score), snippet: "")
        }
    }

    /// Load the vector matrix, keeping only rows whose stored dim matches
    /// the active model (mixed-dim guard). A flat sidecar file beside
    /// index.db (validated by the same epoch signature) lets cold starts
    /// skip 32K blob decodes: one sequential ~100MB read replaces the
    /// row-by-row SQLite fetch. The sidecar is host-endian — a local
    /// derived cache, never exchanged.
    private static let sidecarMagic: [UInt8] = Array("SWVCTRX1".utf8)

    private static func loadVectors(store: Store, signature: String,
                                    dim: Int) throws -> CachedVectors? {
        let sidecar = Store.indexURL(forKey: store.workspaceKey)
            .deletingLastPathComponent()
            .appendingPathComponent("vectors.v1.bin")
        if let e = readVectorSidecar(url: sidecar, signature: signature, dim: dim) {
            return e
        }
        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT chunk_id, dim, vec FROM embeddings")
        }
        guard !rows.isEmpty else { return nil }
        var ids: [Int64] = []
        var matrix: [Float] = []
        ids.reserveCapacity(rows.count)
        matrix.reserveCapacity(rows.count * dim)
        for row in rows {
            guard let blob = row["vec"] as? Data,
                  let d = row["dim"] as? Int64, Int(d) == dim,
                  let cid = row["chunk_id"] as? Int64,
                  blob.count == dim * 4 else { continue }
            ids.append(cid)
            blob.withUnsafeBytes { raw in
                matrix.append(contentsOf: raw.bindMemory(to: Float.self))
            }
        }
        guard ids.count == matrix.count / dim else { return nil }
        let entry = CachedVectors(signature: signature, dim: dim, ids: ids,
                                  matrix: matrix, lastUse: Date())
        try? writeVectorSidecar(url: sidecar, entry: entry)
        return entry
    }

    /// Sidecar layout: magic(8) | dim(u32le) | count(u64le) | sigLen(u16le)
    /// | sig | ids(count×i64) | matrix(count×dim×f32). Any mismatch on
    /// magic/dim/signature → nil, caller falls back to the blob path.
    static func readVectorSidecar(url: URL, signature: String,
                                          dim: Int) -> CachedVectors? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var off = sidecarMagic.count
        guard data.count > off + 14,
              data[0..<off].elementsEqual(sidecarMagic) else { return nil }
        func u32() -> UInt32? {
            guard off + 4 <= data.count else { return nil }
            defer { off += 4 }
            return data[off..<off + 4].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }.littleEndian
        }
        func u64() -> UInt64? {
            guard off + 8 <= data.count else { return nil }
            defer { off += 8 }
            return data[off..<off + 8].withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self)
            }.littleEndian
        }
        func u16() -> UInt16? {
            guard off + 2 <= data.count else { return nil }
            defer { off += 2 }
            return data[off..<off + 2].withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self)
            }.littleEndian
        }
        guard let d = u32(), let n = u64(), let sigLen = u16(),
              Int(d) == dim, off + Int(sigLen) <= data.count,
              String(decoding: data[off..<off + Int(sigLen)], as: UTF8.self) == signature
        else { return nil }
        off += Int(sigLen)
        let cnt = Int(n)
        guard off + cnt * 8 + cnt * dim * 4 == data.count else { return nil }
        let ids = [Int64](unsafeUninitializedCapacity: cnt) { buf, done in
            data.copyBytes(to: buf, from: off..<off + cnt * 8)
            done = cnt
        }
        off += cnt * 8
        let matrix = [Float](unsafeUninitializedCapacity: cnt * dim) { buf, done in
            data.copyBytes(to: buf, from: off..<off + cnt * dim * 4)
            done = cnt * dim
        }
        return CachedVectors(signature: signature, dim: dim, ids: ids,
                             matrix: matrix, lastUse: Date())
    }

    static func writeVectorSidecar(url: URL, entry: CachedVectors) throws {
        var d = Data()
        d.reserveCapacity(24 + entry.signature.count + entry.ids.count * 8
                          + entry.matrix.count * 4)
        d.append(contentsOf: sidecarMagic)
        withUnsafeBytes(of: UInt32(entry.dim).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(entry.ids.count).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(entry.signature.utf8.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: entry.signature.utf8)
        entry.ids.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        entry.matrix.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        try d.write(to: url, options: .atomic)
    }

    /// Rare path-filtered variant: keeps the joined-row scan so the filter
    /// applies before scoring (the cache holds no paths).
    private static func semanticFiltered(store: Store, qv: [Float], limit: Int,
                                         pathFilter: String) throws -> [SearchHit] {
        let rows = try store.pool.read { db in
            let prefix = pathFilter.hasSuffix("/") ? pathFilter : pathFilter + "/"
            return try Row.fetchAll(db, sql: """
                SELECT e.chunk_id, e.dim, e.vec, f.path, c.start_line, c.end_line,
                       c.kind, c.symbol
                FROM embeddings e
                JOIN chunks c ON c.id = e.chunk_id
                JOIN files f ON f.id = c.file_id
                WHERE (f.path = ? OR f.path LIKE ?)
                """, arguments: StatementArguments([pathFilter, prefix + "%"]))
        }
        var scored: [(Int64, Float)] = []
        scored.reserveCapacity(rows.count)
        var byID: [Int64: Row] = [:]
        for row in rows {
            guard let blob = row["vec"] as? Data, let dim = row["dim"] as? Int64 else { continue }
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

    /// Space-joined folded path tokens for the FTS `path_tokens` column:
    /// alnum-split, then camelCase subtokens (split BEFORE folding loses
    /// the case signal), all diacritic-folded — "ui/getUser.py" indexes
    /// as "ui get user py".
    static func pathTokenString(_ path: String) -> String {
        var out: [String] = []
        for raw in path.components(separatedBy: CharacterSet.alphanumerics.inverted)
        where !raw.isEmpty {
            out.append(foldText(raw))
            for sub in symbolTokens(raw) { out.append(foldText(sub)) }
        }
        return out.joined(separator: " ")
    }

    /// Space-joined tokens for the FTS `symbol_names` column: each name
    /// contributes its folded raw form plus folded subtokens, so both
    /// "resolveedges" and "resolve edges" queries reach "resolveEdges".
    static func symbolTokenString(_ names: [String]) -> String {
        var out: [String] = []
        for n in names where !n.isEmpty {
            out.append(foldText(n))
            for t in symbolTokens(n) { out.append(foldText(t)) }
        }
        return out.joined(separator: " ")
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
        try hybridCandidates(store: store, embedder: embedder, query: query,
                             limit: limit, poolLimit: limit,
                             pathFilter: pathFilter, includeVector: includeVector)
    }

    /// The fused candidate pool BEFORE the final limit cut: same legs,
    /// RRF and post-hoc boosts as `hybrid`, but returns up to `poolLimit`
    /// scored rows so a later rerank stage can rescore the full pool
    /// instead of only the visible page. When the fused pool under-fills
    /// `poolLimit`, trigram substring hits top it up (they never join
    /// RRF — substring noise is too loose for the fused score).
    public static func hybridCandidates(store: Store, embedder: Embedder, query: String,
                                        limit: Int, poolLimit: Int,
                                        pathFilter: String? = nil,
                                        includeVector: Bool = true) throws -> [SearchHit] {
        // Legs run concurrently: DatabasePool serves each read on its own
        // connection and query-embed inference (CoreML, CPU-bound) overlaps
        // the FTS IO. Sequential legs measured ~150ms warm on VN hybrid;
        // parallel legs cost ~max(fts, embed+cache) instead of the sum.
        let bag = LegBag()
        let group = DispatchGroup()
        let legQueue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        legQueue.async {
            defer { group.leave() }
            do { bag.fts = try fts(store: store, query: query, limit: limit * 3, pathFilter: pathFilter) }
            catch { bag.note(error) }
        }
        if includeVector {
            group.enter()
            legQueue.async {
                defer { group.leave() }
                do { bag.vec = try semantic(store: store, embedder: embedder, query: query, limit: limit * 3, pathFilter: pathFilter) }
                catch { bag.note(error) }
            }
        }
        group.enter()
        legQueue.async {
            defer { group.leave() }
            do { bag.sym = try symbolHits(store: store, query: query, limit: limit * 3, pathFilter: pathFilter) }
            catch { bag.note(error) }
        }
        // Folded-phrase rescue leg (diacritic queries only — ASCII folds
        // are identity so EN legs are unchanged). Adjacent-token phrases
        // on path_tokens are far more discriminating than term-OR folded
        // probes: "chấm công" → path_tokens : "cham cong" reaches
        // cham_cong.py-style filenames, while single-token folded probes
        // flooded windows on every earlier attempt (merged OR: 7/16,
        // appended: 9/16, dedicated term leg: 10/16 net-zero). Capped at
        // 5, file-deduped — a phrase match is a file-level signal.
        if let pq = foldedPhraseQuery(query) {
            group.enter()
            legQueue.async {
                defer { group.leave() }
                do {
                    let raw = try ftsRun(store: store, match: pq, limit: 15,
                                         pathFilter: pathFilter)
                    var seenFiles: Set<String> = []
                    var out: [SearchHit] = []
                    for h in raw where seenFiles.insert(h.path).inserted {
                        out.append(h)
                        if out.count == 5 { break }
                    }
                    bag.phrase = out
                } catch { bag.note(error) }
            }
        }
        group.wait()
        if let e = bag.error { throw e }
        let ftsHits = bag.fts, vecHits = bag.vec, symHits = bag.sym, phraseHits = bag.phrase
        let w = fusionWeights()
        var rrf: [Int64: Double] = [:]
        for (i, h) in ftsHits.enumerated() { rrf[h.chunkID, default: 0] += w.fts / (60 + Double(i) + 1) }
        for (i, h) in vecHits.enumerated() { rrf[h.chunkID, default: 0] += w.sem / (60 + Double(i) + 1) }
        // Exact-symbol leg gets full leg weight: an identifier token is a
        // strong intent signal, so its definitions deserve top placement.
        for (i, h) in symHits.enumerated() { rrf[h.chunkID, default: 0] += w.sym / (60 + Double(i) + 1) }
        for (i, h) in phraseHits.enumerated() {
            rrf[h.chunkID, default: 0] += Search.phraseLegWeight / (60 + Double(i) + 1)
        }
        var byID: [Int64: SearchHit] = [:]
        for h in ftsHits + vecHits + symHits + phraseHits { byID[h.chunkID] = h }

        let terms = Set(query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }.prefix(12))
        // Folded term set for path matching only: substring matching on the
        // raw path produced phantom boosts ("quantri" inside unrelated paths)
        // and accented VN terms could never match ASCII path tokens.
        let termsFolded = Set(terms.map(foldText))

        // Static-signal metadata for the whole fused pool in one batched
        // read: chunk content (atom coverage) + file PageRank, plus the
        // index-wide pagerank span for [0,1] normalization.
        var candText: [Int64: String] = [:]
        var candPR: [Int64: Double] = [:]
        var prMin = 0.0, prSpan = 0.0
        if !rrf.isEmpty {
            let ids = Array(rrf.keys)
            try store.pool.read { db in
                let ph = ids.map { _ in "?" }.joined(separator: ",")
                for r in try Row.fetchAll(db, sql: """
                    SELECT c.id, c.content, f.pagerank
                    FROM chunks c JOIN files f ON f.id = c.file_id
                    WHERE c.id IN (\(ph))
                    """, arguments: StatementArguments(ids)) {
                    guard let cid = r["id"] as? Int64 else { continue }
                    candText[cid] = (r["content"] as? String) ?? ""
                    candPR[cid] = (r["pagerank"] as? Double) ?? 0
                }
                if let r = try Row.fetchOne(db, sql:
                    "SELECT MIN(pagerank) AS mn, MAX(pagerank) AS mx FROM files") {
                    prMin = (r["mn"] as? Double) ?? 0
                    prSpan = max(0, ((r["mx"] as? Double) ?? 0) - prMin)
                }
            }
        }

        let scored = rrf.map { (cid, score) -> (Int64, Double) in
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
            // Atom coverage: +0.01 per DISTINCT folded query term present
            // in the candidate's folded token set (content+symbol+path),
            // sub-capped at +0.03 — on 10+ term natural-language queries
            // raw term-count saturates and would drown the fused score.
            let hayTokens = Set(foldText(
                    (candText[cid] ?? "") + " " + (h.symbol ?? "") + " " + h.path)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 })
            boost += min(Search.coverageWeight * Double(termsFolded.intersection(hayTokens).count),
                         Search.coverageCap)
            // File-graph PageRank: small static prior so hub definitions
            // beat same-name dead files, 0 when the index is unranked.
            if prSpan > 0, let pr = candPR[cid] {
                boost += Search.pagerankWeight * ((pr - prMin) / prSpan)
            }
            // Depth penalty (zoekt root-importance): −0.005 per path
            // segment beyond the first — deep vendored paths sink.
            let segments = h.path.split(
                separator: "/", omittingEmptySubsequences: true).count
            boost -= Search.depthPenaltyPerSegment * Double(max(0, segments - 1))
            return (cid, score + min(boost, 0.09))
        }.sorted { $0.1 > $1.1 }

        var out = scored.prefix(poolLimit).compactMap { (cid, score) -> SearchHit? in
            guard var h = byID[cid] else { return nil }
            h.score = score
            return h
        }
        // Trigram fallback: only when the fused pool under-fills the
        // request — mid-token substrings (e.g. "edgeshelper" inside
        // "resolveEdgesHelper") never reach the prefix FTS legs.
        if out.count < poolLimit {
            out += try trigramHits(store: store, query: query,
                                   limit: poolLimit - out.count,
                                   excluding: Set(out.map { $0.chunkID }),
                                   pathFilter: pathFilter)
        }
        return out
    }

    /// Substring-level fallback leg over the trigram FTS table. Each
    /// query term ≥3 chars becomes a quoted trigram phrase (a mid-token
    /// substring match; the tokenizer folds case only, so folded variants
    /// are added to reach diacritic-folded content).
    static func trigramHits(store: Store, query: String, limit: Int,
                            excluding: Set<Int64> = [],
                            pathFilter: String? = nil) throws -> [SearchHit] {
        // Opt-in leg: the trigram index costs ~40-45% of DB size and is
        // populated only on indexes with meta.trigram=1. Skip entirely on
        // indexes that never enabled it (empty table = no signal anyway).
        guard store.trigramEnabled else { return [] }
        var atoms: [String] = []
        var seen: Set<String> = []
        for raw in query.components(separatedBy: CharacterSet.alphanumerics.inverted) {
            for v in [raw, foldText(raw)] where v.count >= 3 {
                if seen.insert(v).inserted { atoms.append(v) }
            }
            if atoms.count >= 12 { break }
        }
        guard !atoms.isEmpty else { return [] }
        let match = atoms.prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")
        return try store.pool.read { db in
            var sql = """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol,
                       bm25(chunks_trigram) AS rank
                FROM chunks_trigram
                JOIN chunks c ON c.id = chunks_trigram.rowid
                JOIN files f ON f.id = c.file_id
                WHERE chunks_trigram MATCH ?
                """
            var args: [DatabaseValueConvertible] = [match]
            if let p = pathFilter, !p.isEmpty {
                sql += " AND f.path LIKE ?"
                args.append(p.hasSuffix("/") ? p + "%" : p + "/%")
            }
            if !excluding.isEmpty {
                let excl = excluding.map { String($0) }.joined(separator: ",")
                sql += " AND c.id NOT IN (\(excl))"
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchHit(
                    chunkID: (row["id"] as? Int64) ?? -1, path: (row["path"] as? String) ?? "",
                    startLine: Int((row["start_line"] as? Int64) ?? 0), endLine: Int((row["end_line"] as? Int64) ?? 0),
                    kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                    score: -((row["rank"] as? Double) ?? 0), snippet: "")
            }
        }
    }

    /// Result bag for the concurrent legs in `hybridCandidates`. Each
    /// property is written by exactly one leg closure and read only after
    /// `group.wait()`, which establishes the happens-before edge; the lock
    /// guards only the error slot (any leg may fail).
    private final class LegBag: @unchecked Sendable {
        var fts: [SearchHit] = []
        var vec: [SearchHit] = []
        var sym: [SearchHit] = []
        var phrase: [SearchHit] = []
        private var _err: Error?
        private let lock = NSLock()
        func note(_ e: Error) { lock.lock(); if _err == nil { _err = e }; lock.unlock() }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _err }
    }
}
