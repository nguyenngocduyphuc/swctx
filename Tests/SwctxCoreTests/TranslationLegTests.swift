import XCTest
@testable import SwctxCore

/// W11 vn→en translation leg: gate, prompt-contract validation, bounded
/// cache, subprocess deadline and the leg's FTS/cap behaviour — all
/// deterministic via SWCTX_OLLAMA stub scripts; the real Ollama is never
/// required.
final class TranslationLegTests: SwctxTestCase {
    private var savedEnv: [String: String?] = [:]

    override func tearDown() {
        for (k, v) in savedEnv {
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        savedEnv.removeAll()
        Translation.resetForTesting()
        super.tearDown()
    }

    private func setEnv(_ key: String, _ value: String?) {
        if savedEnv[key] == nil {
            savedEnv[key] = ProcessInfo.processInfo.environment[key]
        }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-xlate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An executable stub standing in for `ollama`: writes whatever stdout
    /// `body` produces when invoked as `ollama run <model> <prompt>`.
    private func stubOllama(in dir: URL, body: String) throws -> URL {
        let stub = dir.appendingPathComponent("ollama-stub.sh")
        try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    // MARK: gate

    /// The leg fires only on diacritic-carrying queries — the same
    /// criterion as foldedVariantTokens (đ/Đ count; case-only differences
    /// and plain ASCII/CJK do not).
    func testGateFiresOnlyOnDiacritics() {
        XCTAssertTrue(Translation.needsTranslation("đăng nhập hệ thống"))
        XCTAssertTrue(Translation.needsTranslation("script kiểm tra canonical"))
        XCTAssertTrue(Translation.needsTranslation("Đường dẫn"))
        XCTAssertFalse(Translation.needsTranslation("login flow"))
        XCTAssertFalse(Translation.needsTranslation("CRM tool"))
        XCTAssertFalse(Translation.needsTranslation("cham cong"))   // no marks
        XCTAssertFalse(Translation.needsTranslation("搜索"))
        setEnv("SWCTX_TRANSLATE", "0")
        XCTAssertFalse(Translation.needsTranslation("đăng nhập"))
    }

    // MARK: protected tokens

    func testProtectedTokenExtraction() {
        let toks = Translation.protectedTokens(
            "đọc dữ liệu GSC GA4 rồi gọi DeepSeek từ nap_serp.py")
        XCTAssertEqual(Set(toks), ["GSC", "GA4", "DeepSeek", "nap_serp.py"])
        XCTAssertTrue(Translation.protectedTokens("chấm công nhân viên").isEmpty)
        XCTAssertTrue(Translation.protectedTokens("gác cửa _middleware.js")
            .contains("_middleware.js"))
    }

    // MARK: response validation

    func testParseTermsValidatesShape() {
        let q = "sinh ảnh minh họa cho bài viết"
        // Clean JSON.
        XCTAssertEqual(
            Translation.parseTerms(
                #"{"english_terms":["hero image","image generation"],"protected_tokens":[]}"#,
                query: q),
            ["hero image", "image generation"])
        // Prose around the JSON is tolerated — the object is extracted.
        XCTAssertEqual(
            Translation.parseTerms(
                "Sure! {\"english_terms\":[\"login\"],\"protected_tokens\":[]} done",
                query: q),
            ["login"])
        // Rejects: empty, non-JSON, empty terms, oversized ramble.
        XCTAssertNil(Translation.parseTerms("", query: q))
        XCTAssertNil(Translation.parseTerms("no json here", query: q))
        XCTAssertNil(Translation.parseTerms(#"{"english_terms":[]}"#, query: q))
        XCTAssertNil(Translation.parseTerms(
            #"{"english_terms":["ok"],"protected_tokens":[]} "# +
            String(repeating: "x", count: 9000), query: q))
        // Unusable terms are filtered; if none survive, reject.
        XCTAssertNil(Translation.parseTerms(
            #"{"english_terms":["!!!","a"]}"#, query: q))
    }

    /// `ollama run` redraws its spinner into piped stdout mid-JSON
    /// (observed live: `"protected_\x1B[11D\x1B[K\n" protected_tokens"`).
    /// unspin must reconstruct the terminal-intended text so the object
    /// still parses — the erased fragment never reaches validation.
    func testUnspinReconstructsSpinnerRedraw() {
        let raw = "{\"english_terms\": [\"worker\", \"generate\"], "
            + "\"protected_\u{1B}[11D\u{1B}[K\n\" protected_tokens\": []}\n"
        XCTAssertEqual(
            Translation.parseTerms(raw, query: "chấm công"),
            ["worker", "generate"])
        // Plain output is untouched.
        XCTAssertEqual(Translation.unspin("plain text\n"), "plain text\n")
        // \r overwrite + forward/back cursor moves.
        XCTAssertEqual(Translation.unspin("ab\rZ"), "Zb")
    }

    /// A model that renames/drops a protected token rewrote the query —
    /// the whole translation is discarded.
    func testParseTermsRejectsAlteredProtectedTokens() {
        let q = "đọc dữ liệu GSC GA4 rồi gọi DeepSeek"
        XCTAssertNil(Translation.parseTerms(
            #"{"english_terms":["read data"],"protected_tokens":["GSC","ga4","DeepSeek"]}"#,
            query: q))                     // GA4 lowercased = altered
        XCTAssertNil(Translation.parseTerms(
            #"{"english_terms":["read data"],"protected_tokens":["GSC","DeepSeek"]}"#,
            query: q))                     // GA4 dropped
        XCTAssertNil(Translation.parseTerms(
            #"{"english_terms":["read data"]}"#, query: q))   // field missing
        XCTAssertNotNil(Translation.parseTerms(
            #"{"english_terms":["read data"],"protected_tokens":["GSC","GA4","DeepSeek","extra"]}"#,
            query: q))                     // extras allowed
        // A protected token filed under english_terms still counts —
        // verbatim presence is what matters, not which array (observed
        // live: qwen puts "DeepSeek" under english_terms).
        XCTAssertNotNil(Translation.parseTerms(
            #"{"english_terms":["read data","GSC","GA4","DeepSeek"],"protected_tokens":[]}"#,
            query: q))
        // No protected tokens in the query -> nothing required.
        XCTAssertNotNil(Translation.parseTerms(
            #"{"english_terms":["read data"]}"#, query: "chấm công"))
    }

    // MARK: cache

    func testCacheRoundTripAndLRUEviction() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.json")
        let c = Translation.Cache(url: url, cap: 3)
        c.put("a", terms: ["aa"]); c.put("b", terms: ["bb"]); c.put("c", terms: ["cc"])
        XCTAssertEqual(c.get("a"), ["aa"])      // touch a: b is now oldest
        c.put("d", terms: ["dd"])
        XCTAssertNil(c.get("b"))
        XCTAssertEqual(c.get("a"), ["aa"])
        XCTAssertEqual(c.get("d"), ["dd"])
        // Persistence: a fresh instance on the same file sees the entries.
        let c2 = Translation.Cache(url: url, cap: 3)
        XCTAssertEqual(c2.get("c"), ["cc"])
        // Cache key binds prompt version + model + normalized query.
        XCTAssertEqual(Translation.cacheKey("  Đăng   Nhập "),
                       Translation.cacheKey("đăng nhập"))
        XCTAssertNotEqual(Translation.cacheKey("đăng nhập"),
                          Translation.cacheKey("đăng xuất"))
    }

    // MARK: subprocess + deadline

    /// End-to-end via a stub `ollama`: terms flow through, and the second
    /// call is served from the cache file (stub invoked once).
    func testEnglishTermsViaStubbedOllama() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("calls")
        let stub = try stubOllama(in: dir, body: """
            echo x >> "\(counter.path)"
            printf '%s' '{"english_terms":["image worker","hero image"],"protected_tokens":[]}'
            """)
        setEnv("SWCTX_OLLAMA", stub.path)
        Translation.resetForTesting()
        Translation.cacheOverride = Translation.Cache(
            url: dir.appendingPathComponent("c.json"))

        XCTAssertEqual(Translation.englishTerms(for: "sinh ảnh minh họa"),
                       ["image worker", "hero image"])
        XCTAssertEqual(Translation.englishTerms(for: "sinh ảnh minh họa"),
                       ["image worker", "hero image"])
        let calls = (try? String(contentsOf: counter, encoding: .utf8)) ?? ""
        // A cold miss may spawn up to two generations (term union); the
        // warm call must not spawn at all.
        XCTAssertLessThanOrEqual(
            calls.components(separatedBy: "\n").filter { $0 == "x" }.count, 2,
            "second call must hit the cache")
    }

    /// Past the hard deadline the whole process group is killed and the
    /// caller gets nil inside a bounded window — never a hang.
    func testDeadlineKillsSubprocess() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("survived")
        // The child forks a descendant that writes a marker after the
        // deadline — group kill must take it down too.
        let stub = try stubOllama(in: dir, body: """
            (sleep 1; touch "\(marker.path)") &
            sleep 5
            """)
        setEnv("SWCTX_OLLAMA", stub.path)
        setEnv("SWCTX_TRANSLATE_SPAWN_MS", "300")
        Translation.resetForTesting()
        Translation.cacheOverride = Translation.Cache(
            url: dir.appendingPathComponent("c.json"))

        let t0 = Date()
        XCTAssertNil(Translation.englishTerms(for: "đăng nhập hệ thống"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        // Give the orphaned descendant a chance to write if it lived.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "descendant survived the process-group kill")
    }

    /// Ollama absent (binary missing) → nil, and cooldown keeps later
    /// calls off the subprocess path entirely.
    func testMissingOllamaDegrades() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        setEnv("SWCTX_OLLAMA", dir.appendingPathComponent("nope").path)
        Translation.resetForTesting()
        Translation.cacheOverride = Translation.Cache(
            url: dir.appendingPathComponent("c.json"))
        XCTAssertNil(Translation.englishTerms(for: "đăng nhập hệ thống"))
    }

    // MARK: leg shape + fusion integration

    func testTranslatedQueryShape() {
        let q = Search.ftsTranslatedQuery(["image worker", "hero image"])
        XCTAssertNotNil(q)
        XCTAssertTrue(q!.contains("\"image\"*"))
        XCTAssertTrue(q!.contains("\"worker\"*"))
        XCTAssertTrue(q!.contains("path_tokens : \"image worker\""))
        XCTAssertNil(Search.ftsTranslatedQuery([]))
        XCTAssertNil(Search.ftsTranslatedQuery(["x"]))   // <2 chars filtered
        // Plural atoms also emit their singular form — "links" must reach
        // a snake_case filename stem like ghost_link_builder_apply.py.
        let p = Search.ftsTranslatedQuery(["internal links"])
        XCTAssertTrue(p!.contains("\"links\"*"))
        XCTAssertTrue(p!.contains("\"link\"*"))
        XCTAssertTrue(p!.contains("path_tokens : \"internal links\""))
    }

    /// File-deduped, capped at 5 — same contract as the folded-phrase leg.
    func testTranslatedLegFileDedupeAndCap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<8 {
            try "def worker_\(i)():\n    return \(i)\n".write(
                to: dir.appendingPathComponent("f\(i).py"),
                atomically: true, encoding: .utf8)
        }
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        let hits = try Search.translatedLegHits(store: store, terms: ["worker"])
        XCTAssertEqual(hits.count, 5)
        XCTAssertEqual(Set(hits.map { $0.path }).count, hits.count)
    }

    /// The leg lands in the fused pool: a VN diacritic query whose folded
    /// terms cannot reach an English-named file is rescued once the stub
    /// supplies "image worker". Baseline arm (SWCTX_TRANSLATE=0) misses.
    func testLegRescuesVnQueryOnEnglishFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def render_card():\n    return draw()\n".write(
            to: dir.appendingPathComponent("image_worker.py"),
            atomically: true, encoding: .utf8)
        try "def unrelated():\n    return 0\n".write(
            to: dir.appendingPathComponent("other.py"),
            atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        let emb = Embedder()
        let q = "sinh ảnh minh họa cho bài viết"

        setEnv("SWCTX_TRANSLATE", "0")
        let baseline = try Search.hybridCandidates(
            store: store, embedder: emb, query: q, limit: 5, poolLimit: 5,
            includeVector: false)
        XCTAssertFalse(baseline.contains { $0.path == "image_worker.py" })

        let stub = try stubOllama(in: dir, body: """
            printf '%s' '{"english_terms":["image worker"],"protected_tokens":[]}'
            """)
        setEnv("SWCTX_OLLAMA", stub.path)
        setEnv("SWCTX_TRANSLATE", nil)
        Translation.resetForTesting()
        Translation.cacheOverride = Translation.Cache(
            url: dir.appendingPathComponent("c.json"))
        let hits = try Search.hybridCandidates(
            store: store, embedder: emb, query: q, limit: 5, poolLimit: 5,
            includeVector: false)
        XCTAssertTrue(hits.contains { $0.path == "image_worker.py" })
    }
}
