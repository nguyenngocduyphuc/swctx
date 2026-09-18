import XCTest
@testable import SwctxCore
import GRDB

/// Multilingual embedding spike coverage: the model registry, per-index
/// meta binding, cased-vs-uncased WordPiece tokenization, and — when the
/// weights are installed — a real Vietnamese retrieval signal check plus
/// per-model embed latency (printed for bench/vn_model_spike.md).
final class MultilingualEmbedderTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Selection state is process-global; restore it so tests don't leak
    /// a model choice into each other or into other suites.
    private func withSelection<T>(_ explicit: String?, bound: String?,
                                  _ body: () throws -> T) rethrows -> T {
        Embedder.selectModel(explicit)
        Embedder.bindModel(bound)
        defer {
            Embedder.selectModel(nil)
            Embedder.bindModel(nil)
        }
        return try body()
    }

    // MARK: - Registry

    func testModelRegistryCoversBothModels() {
        XCTAssertEqual(Embedder.models.count, 2)
        let bge = Embedder.spec(for: "bge-base-en-v1.5")
        let ml = Embedder.spec(for: "distiluse-base-multilingual-cased-v2")
        XCTAssertEqual(bge?.dim, 768)
        XCTAssertEqual(bge?.cased, false)
        XCTAssertEqual(bge?.pooling, .cls)
        XCTAssertEqual(ml?.dim, 768)
        XCTAssertEqual(ml?.cased, true)
        XCTAssertEqual(ml?.pooling, .mean)
        XCTAssertNil(Embedder.spec(for: "no-such-model"))
        XCTAssertEqual(Embedder.defaultModelID, "bge-base-en-v1.5")
    }

    // MARK: - Selection precedence

    func testActiveModelPrecedence() throws {
        try withSelection("distiluse-base-multilingual-cased-v2", bound: nil) {
            // explicit flag beats the default when no index binding exists
            XCTAssertEqual(Embedder.activeModelID, "distiluse-base-multilingual-cased-v2")
            // an index binding beats the explicit flag
            Embedder.bindModel("bge-base-en-v1.5")
            XCTAssertEqual(Embedder.activeModelID, "bge-base-en-v1.5")
            // clearing the binding falls back to the explicit choice
            Embedder.bindModel(nil)
            XCTAssertEqual(Embedder.activeModelID, "distiluse-base-multilingual-cased-v2")
        }
        XCTAssertEqual(Embedder.activeModelID, Embedder.defaultModelID)
    }

    // MARK: - Tokenizer (vocab-only, no CoreML needed)

    private func vocabURL(_ spec: EmbeddingModelSpec) -> URL {
        spec.modelDir.appendingPathComponent("vocab.txt")
    }

    func testCasedTokenizerKeepsCaseAndAccents() throws {
        let spec = Embedder.distiluseSpec
        guard FileManager.default.fileExists(atPath: vocabURL(spec).path) else {
            throw XCTSkip("distiluse vocab.txt not installed")
        }
        let cased = try XCTUnwrap(
            WordPieceTokenizer(vocabAt: vocabURL(spec), cased: true))
        let uncased = try XCTUnwrap(
            WordPieceTokenizer(vocabAt: vocabURL(spec), cased: false))

        // "Kiểm" (capital K + stacked diacritics) exists in the multilingual
        // cased vocab as itself; uncased mode lowercases to "kiểm".
        let casedIDs = cased.tokenize("Kiểm tra")
        let uncasedIDs = uncased.tokenize("Kiểm tra")
        XCTAssertNotEqual(casedIDs, uncasedIDs, "cased vs uncased must tokenize differently")
        XCTAssertFalse(casedIDs.contains(100), "VN word should not collapse to [UNK]")

        // CJK: cased mode splits each ideograph into its own token.
        let cjk = cased.tokenize("中文测试")
        XCTAssertGreaterThanOrEqual(cjk.count - 2, 2, "each CJK char is a token")
    }

    func testVietnameseTokensResolveInMultilingualVocab() throws {
        let spec = Embedder.distiluseSpec
        guard FileManager.default.fileExists(atPath: vocabURL(spec).path) else {
            throw XCTSkip("distiluse vocab.txt not installed")
        }
        let tok = try XCTUnwrap(
            WordPieceTokenizer(vocabAt: vocabURL(spec), cased: true))
        // The phrase that produced ~all-UNK under bert-uncased must now yield
        // real subwords — count non-UNK interior tokens.
        let ids = tok.tokenize("script kiểm tra chấm công của nhân viên")
        let interior = ids.dropFirst().dropLast()
        let unks = interior.filter { $0 == 100 }.count
        XCTAssertLessThan(unks, interior.count / 2,
                          "Vietnamese should tokenize to real subwords, got \(unks)/\(interior.count) UNK")
    }

    // MARK: - Per-index meta binding

    func testStoreRecordsAndReadsEmbeddingBinding() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def f():\n    return 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)

        try withSelection("distiluse-base-multilingual-cased-v2", bound: nil) {
            let store = try Store(workspaceRoot: dir)
            XCTAssertEqual(store.embeddingModel, "distiluse-base-multilingual-cased-v2")
            XCTAssertEqual(store.embeddingDim, 768)
            // Meta rows exist and survived the init.
            let meta = try store.pool.read { db in
                try Row.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'embedding_model'")
            }
            XCTAssertEqual(meta?["value"] as? String, "distiluse-base-multilingual-cased-v2")

            // Rebind updates meta + the process selection.
            try store.setEmbeddingBinding(modelID: "bge-base-en-v1.5", dim: 768)
            XCTAssertEqual(store.embeddingModel, "bge-base-en-v1.5")
            XCTAssertEqual(Embedder.activeModelID, "bge-base-en-v1.5")
        }
    }

    func testLegacyIndexWithoutBindingStaysDefault() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def f():\n    return 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        // Simulate a pre-binding index: strip the meta rows.
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM meta WHERE key IN ('embedding_model','embedding_dim')")
        }
        try withSelection(nil, bound: nil) {
            let reopened = try Store(workspaceRoot: dir)
            XCTAssertNil(reopened.embeddingModel)
            XCTAssertNil(reopened.embeddingDim)
            // An unbound index must not leave a stale binding behind.
            XCTAssertEqual(Embedder.activeModelID, Embedder.defaultModelID)
        }
    }

    // MARK: - Real-model behaviour (weights required)

    func testMultilingualEmbeddingSeparatesVNSemantics() throws {
        guard Embedder.distiluseSpec.isInstalled,
              let bge = try? BGEEmbedder(spec: Embedder.distiluseSpec) else {
            throw XCTSkip("distiluse model not installed")
        }
        guard let vnQuery = bge.embed("script kiểm tra google có đang chọn canonical khác"),
              let enSame = bge.embed("check whether google picks a different canonical url"),
              let vnSame = bge.embed("kiểm tra google có chọn canonical khác không"),
              let unrelated = bge.embed("món phở bò tái nạm sài gòn")
        else { return XCTFail("embed returned nil") }
        XCTAssertEqual(vnQuery.count, 768)
        // Same-meaning sentences must outrank unrelated ones — the property
        // bge-base-en cannot have on Vietnamese text.
        XCTAssertGreaterThan(Embedder.dot(vnQuery, vnSame), Embedder.dot(vnQuery, unrelated))
        XCTAssertGreaterThan(Embedder.dot(vnQuery, enSame), Embedder.dot(vnQuery, unrelated))
        XCTAssertGreaterThan(Embedder.dot(vnQuery, vnSame), 0.5)
    }

    /// Per-model embed latency: prints p50/p95 in ms — the numbers quoted in
    /// bench/vn_model_spike.md. Skipped when weights are absent.
    func testEmbedLatencyPerModel() throws {
        let text = """
            scripts/p8_canonical_check.py
            check_canonical
            """ + """
            Check whether google is selecting a different canonical URL than
            the one declared in the page head. Fetches each live URL, reads
            the rendered canonical tag, and diffs against the declared value.
            """
        for spec in Embedder.models {
            guard spec.isInstalled,
                  let bge = try? BGEEmbedder(spec: spec) else {
                print("LAT \(spec.id): skipped (not installed)")
                continue
            }
            _ = bge.embed(text) // warm
            var times: [Double] = []
            for _ in 0..<40 {
                let t0 = Date()
                _ = bge.embed(text)
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
            times.sort()
            let p50 = times[times.count / 2]
            let p95 = times[Int(Double(times.count) * 0.95)]
            let line = String(
                format: "LAT %@ p50=%.1fms p95=%.1fms (n=%d)",
                spec.id, p50, p95, times.count)
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            print(line)
            XCTAssertFalse(times.isEmpty)
        }
    }
}
