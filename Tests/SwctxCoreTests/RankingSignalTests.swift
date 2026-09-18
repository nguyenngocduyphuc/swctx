import XCTest
@testable import SwctxCore
import GRDB

/// Ranking signals (v5): BM25F column weights, file-graph PageRank,
/// atom coverage, depth penalty, trigram fallback gating, and the
/// candidate-pool API. All fixtures index with autoEmbed=false so no
/// CoreML model is needed — the semantic leg just returns empty.
final class RankingSignalTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// BM25F: a term hit in the 5.0-weighted symbol_names column must
    /// outrank a higher-tf hit in the 1.0-weighted content column —
    /// the same rows unweighted order the other way, so the weighting
    /// itself is what changes the ranking.
    func testBM25FWeightsSymbolOverContent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // a.py: term appears many times in body text, no symbol.
        try write((0 ..< 10).map { _ in "# quixotic" }.joined(separator: "\n") + "\n",
                  to: dir.appendingPathComponent("a.py"))
        // b.py: term once in body, once as the defined symbol name.
        try write("def quixotic():\n    return 1\n",
                  to: dir.appendingPathComponent("b.py"))
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        // Unweighted bm25 puts the content-heavy chunk first (verified
        // fixture ordering — the weight flip below is the signal).
        let unweightedFirst = try store.pool.read { db -> String? in
            try Row.fetchOne(db, sql: """
                SELECT f.path FROM chunks_fts
                JOIN chunks c ON c.id = chunks_fts.rowid
                JOIN files f ON f.id = c.file_id
                WHERE chunks_fts MATCH '"quixotic"'
                ORDER BY bm25(chunks_fts) LIMIT 1
                """).map { $0["path"] as? String } ?? nil
        }
        XCTAssertEqual("a.py", unweightedFirst)

        let hits = try Search.fts(store: store, query: "quixotic", limit: 5)
        XCTAssertEqual(2, hits.count)
        XCTAssertEqual("b.py", hits[0].path,
                       "symbol_names hit must outrank content-tf under BM25F weights")
        XCTAssertEqual("a.py", hits[1].path)
    }

    /// PageRank: an edge into hub.py raises its file rank over an
    /// unreferenced same-content file, and the hybrid boost orders the
    /// hub chunk first when every other signal ties.
    func testPageRankBoostsHubOverOrphan() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("def hubfunc():\n    return 1\n",
                  to: dir.appendingPathComponent("hub.py"))
        try write("def orphfunc():\n    return 1\n",
                  to: dir.appendingPathComponent("orphan.py"))
        try write("from hub import hubfunc\nx = hubfunc()\n",
                  to: dir.appendingPathComponent("callers.py"))
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        let pr = try store.pool.read { db -> [String: Double] in
            var m: [String: Double] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT path, pagerank FROM files") {
                m[(r["path"] as? String) ?? ""] = (r["pagerank"] as? Double) ?? 0
            }
            return m
        }
        XCTAssertGreaterThan(pr["hub.py"] ?? 0, pr["orphan.py"] ?? 0,
                             "referenced file must outrank unreferenced file")

        // Identical term coverage in both bodies: PageRank is the only
        // differing signal, so the hub chunk must win.
        let hits = try Search.hybrid(store: store, embedder: Embedder(),
                                     query: "def return", limit: 5)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual("hub.py", hits[0].path)
    }

    /// Atom coverage: the chunk containing BOTH distinct query terms
    /// beats a chunk repeating only one of them, even at higher tf.
    func testAtomCoveragePrefersMultiTerm() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("alpha beta\n", to: dir.appendingPathComponent("a.py"))
        try write("alpha alpha alpha alpha alpha alpha\n",
                  to: dir.appendingPathComponent("b.py"))
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        let hits = try Search.hybrid(store: store, embedder: Embedder(),
                                     query: "alpha beta", limit: 5)
        XCTAssertEqual(2, hits.count)
        XCTAssertEqual("a.py", hits[0].path,
                       "two-term coverage must beat one-term tf")
    }

    /// Depth penalty: identical content at root outranks the same chunk
    /// three directories down (−0.005 per segment beyond the first).
    func testDepthPenaltyPrefersShallower() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "def marker_zqx():\n    return 'uniqalpha'\n"
        try write(body, to: dir.appendingPathComponent("a.py"))
        try write(body, to: dir.appendingPathComponent("deep/nested/dir/b.py"))
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        let hits = try Search.hybrid(store: store, embedder: Embedder(),
                                     query: "zqx uniqalpha", limit: 5)
        XCTAssertEqual(2, hits.count)
        XCTAssertEqual("a.py", hits[0].path,
                       "root file must outrank deep file on identical content")
    }

    /// Trigram fallback: fires only when the fused pool under-fills the
    /// request. Mid-token substrings unreachable by prefix FTS are the
    /// intended rescue; a full fused pool must never see them appended.
    func testTrigramFallbackOnlyUnderFull() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("def resolveEdgesHelper():\n    pass\n",
                  to: dir.appendingPathComponent("one.py"))
        try write("x = 'zzresolvezz'\n",
                  to: dir.appendingPathComponent("two.py"))
        let store = try Store(workspaceRoot: dir)
        try store.setTrigramEnabled(true)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        // Mid-token substring: no FTS/symbol leg can reach it, so the
        // fused pool is empty and trigram supplies the only hit.
        let hits = try Search.hybrid(store: store, embedder: Embedder(),
                                     query: "edgeshelper", limit: 5)
        XCTAssertEqual(1, hits.count)
        XCTAssertEqual("one.py", hits[0].path)

        // Fused pool of 1 < limit 5: trigram tops up the substring-only
        // file as a tail hit.
        let filled = try Search.hybrid(store: store, embedder: Embedder(),
                                       query: "resolve", limit: 5)
        XCTAssertEqual(2, filled.count)
        XCTAssertEqual("one.py", filled[0].path)
        XCTAssertEqual("two.py", filled[1].path)

        // Same query at limit 1: pool is full, trigram must not fire.
        let capped = try Search.hybrid(store: store, embedder: Embedder(),
                                       query: "resolve", limit: 1)
        XCTAssertEqual(1, capped.count)
        XCTAssertEqual("one.py", capped[0].path)
    }

    /// Trigram is opt-in: without `meta.trigram=1` the leg never runs,
    /// so mid-token substrings stay unreachable (storage stays cheap).
    func testTrigramDisabledByDefault() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("def resolveEdgesHelper():\n    pass\n",
                  to: dir.appendingPathComponent("one.py"))
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        XCTAssertFalse(store.trigramEnabled)
        let hits = try Search.hybrid(store: store, embedder: Embedder(),
                                     query: "edgeshelper", limit: 5)
        XCTAssertEqual(0, hits.count)
    }

    /// Folded tail-fill: a diacritic query reaches ASCII-folded index
    /// text through the folded column, but only after real hits — a
    /// file matching the original terms must always outrank a
    /// folded-only rescue.
    func testFoldedTailFillRescuesDiacriticQuery() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("def xac_thuc_dang_nhap(token):\n    return verify(token)\n",
                  to: dir.appendingPathComponent("auth_ascii.py"))
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        // "xác thực đăng nhập" has no un-folded match in ASCII code —
        // only the folded rescue can reach it.
        let hits = try Search.fts(store: store, query: "xác thực đăng nhập", limit: 5)
        XCTAssertEqual(1, hits.count)
        XCTAssertEqual("auth_ascii.py", hits[0].path)
    }

    /// Candidate-pool API: returns the full fused pool before the limit
    /// cut — more rows than `limit` whenever the pool is bigger.
    func testCandidatePoolReturnsMoreThanLimit() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0 ..< 4 {
            try write("x = 'sharedterm \(i)'\n",
                      to: dir.appendingPathComponent("f\(i).py"))
        }
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        let page = try Search.hybrid(store: store, embedder: Embedder(),
                                     query: "sharedterm", limit: 2)
        XCTAssertEqual(2, page.count)
        let pool = try Search.hybridCandidates(store: store, embedder: Embedder(),
                                               query: "sharedterm", limit: 2,
                                               poolLimit: 10)
        XCTAssertGreaterThan(pool.count, page.count)
        XCTAssertEqual(4, pool.count)
    }
}

extension RankingSignalTests {
    /// The cache-validation signature must change whenever the writer bumps
    /// the epoch — otherwise the process-level vector cache would serve a
    /// stale matrix after reindex.
    func testEmbeddingsEpochSignatureChanges() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(workspaceRoot: dir)
        let legacy = try store.embeddingsSignature()
        XCTAssertTrue(legacy.hasPrefix("legacy:"), "no epoch yet → \(legacy)")
        try store.bumpEmbeddingsEpoch()
        let s1 = try store.embeddingsSignature()
        try store.bumpEmbeddingsEpoch()
        let s2 = try store.embeddingsSignature()
        XCTAssertNotEqual(legacy, s1)
        XCTAssertNotEqual(s1, s2, "each bump must produce a fresh nonce")
    }

    /// Cache mechanics: signature + dim validation, LRU eviction at 4.
    func testVectorCacheBox() {
        let box = Search.VectorCacheBox()
        func entry(_ sig: String, dim: Int = 2) -> Search.CachedVectors {
            Search.CachedVectors(signature: sig, dim: dim,
                                 ids: [1, 2], matrix: [1, 0, 0, 1],
                                 lastUse: Date())
        }
        XCTAssertNil(box.cached(key: "w", signature: "a", dim: 2))
        box.store(key: "w", entry: entry("a"))
        XCTAssertNotNil(box.cached(key: "w", signature: "a", dim: 2))
        XCTAssertNil(box.cached(key: "w", signature: "b", dim: 2),
                     "epoch changed → stale entry rejected")
        XCTAssertNil(box.cached(key: "w", signature: "a", dim: 3),
                     "dim mismatch → rejected (model switched)")
        box.store(key: "w", entry: entry("b"))
        XCTAssertNotNil(box.cached(key: "w", signature: "b", dim: 2),
                        "re-stored under the new epoch")
        // LRU cap: 4 more distinct workspaces evict "w".
        for i in 0 ..< 4 { box.store(key: "w\(i)", entry: entry("x")) }
        XCTAssertNil(box.cached(key: "w", signature: "b", dim: 2))
    }

    /// Sidecar round-trip: same ids/matrix/signature back, and a stale
    /// signature or wrong dim rejects the file (falls back to blobs).
    func testVectorSidecarRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-sidecar-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = Search.CachedVectors(
            signature: "epoch-abc", dim: 3,
            ids: [10, 20, 30],
            matrix: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, -0.7, -0.8, -0.9],
            lastUse: Date())
        try Search.writeVectorSidecar(url: url, entry: entry)
        let back = Search.readVectorSidecar(url: url, signature: "epoch-abc", dim: 3)
        XCTAssertNotNil(back)
        XCTAssertEqual(back?.ids, entry.ids)
        XCTAssertEqual(back?.matrix, entry.matrix)
        XCTAssertNil(Search.readVectorSidecar(url: url, signature: "epoch-zzz", dim: 3),
                     "stale epoch → reject")
        XCTAssertNil(Search.readVectorSidecar(url: url, signature: "epoch-abc", dim: 4),
                     "dim mismatch → reject")
        // Truncated file → reject, no crash.
        var d = try Data(contentsOf: url)
        d.removeSubrange((d.count - 16)..<d.count)
        try d.write(to: url)
        XCTAssertNil(Search.readVectorSidecar(url: url, signature: "epoch-abc", dim: 3))
    }
}
