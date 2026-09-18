import XCTest
@testable import SwctxCore

/// Tests for `SPTokenizer` (SentencePiece unigram, XLM-R/BGE-M3 family).
///
/// Two layers of validation:
///
/// 1. Fixture tests — two tiny `.model` protobufs are constructed in-code
///    (hand-rolled wire writer below). All expected ids were verified against
///    the reference C++ implementation (`sentencepiece` 0.2.2, Python bindings)
///    by loading the exact same fixture bytes, so they are real ground truth,
///    not just self-consistency:
///      fixture 1 (plain unigram):
///        "ab"          -> [1,6,2]          "hello world" -> [1,11,12,2]
///        "zzz"         -> [1,3,0,2]        "a x"         -> [1,4,14,2]
///        "  a   b  "   -> [1,4,8,2]        "cab"         -> [1,3,0,5,7,2]
///        "a☕"         -> [1,4,0,2]        "Hello"       -> [1,15,2]
///        "b"           -> [1,8,2]
///      fixture 2 (byte_fallback=1, all 256 <0xNN> pieces at ids 5...260):
///        "a☕"   -> [1,3,4,231,157,154,2]     "☕" -> [1,3,231,157,154,2]
///        "ab"    -> [1,3,4,103,2]             "a☕b" -> [1,3,4,231,157,154,103,2]
///
/// 2. Real-model tests — when BGE-M3's `sentencepiece.bpe.model` is present
///    (env `SWCTX_SPM_MODEL`, default /tmp/spm_bgem3.model), the exact ids
///    below are asserted. They were produced by `sentencepiece` 0.2.2
///    `EncodeAsIds` wrapped in bos=1 / eos=2. The tests XCTSkip when the
///    file is absent so CI without the download still passes.
final class SPTokenizerTests: XCTestCase {

    // MARK: - Tiny protobuf wire writer (test-only)

    private func v(_ x: UInt64) -> [UInt8] {
        var n = x
        var out: [UInt8] = []
        while true {
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { b |= 0x80 }
            out.append(b)
            if n == 0 { return out }
        }
    }
    private func tag(_ f: Int, _ w: Int) -> [UInt8] { v(UInt64(f << 3 | w)) }
    private func fBytes(_ f: Int, _ b: [UInt8]) -> [UInt8] {
        tag(f, 2) + v(UInt64(b.count)) + b
    }
    private func fStr(_ f: Int, _ s: String) -> [UInt8] {
        fBytes(f, Array(s.utf8))
    }
    private func fF32(_ f: Int, _ x: Float) -> [UInt8] {
        var bits = x.bitPattern
        var out: [UInt8] = []
        for _ in 0..<4 { out.append(UInt8(bits & 0xFF)); bits >>= 8 }
        return tag(f, 5) + out
    }
    private func fVar(_ f: Int, _ x: UInt64) -> [UInt8] { tag(f, 0) + v(x) }
    private func fVar(_ f: Int, _ x: Int64) -> [UInt8] {
        tag(f, 0) + v(UInt64(bitPattern: x))
    }

    private func piece(_ s: String, _ score: Float, _ type: UInt64) -> [UInt8] {
        fStr(1, s) + fF32(2, score) + fVar(3, type)
    }

    /// Fixture 1: plain unigram, no charsmap, whitespace defaults on.
    private func fixtureModel() -> Data {
        let entries: [(String, Float, UInt64)] = [
            ("<unk>", 0, 2), ("<s>", 0, 3), ("</s>", 0, 3),
            ("\u{2581}", -0.1, 1), ("\u{2581}a", -1.0, 1), ("a", -1.0, 1),
            ("\u{2581}ab", -1.5, 1), ("b", -1.0, 1), ("\u{2581}b", -1.0, 1),
            ("\u{2581}he", -2.0, 1), ("llo", -3.0, 1),
            ("\u{2581}hello", -2.5, 1), ("\u{2581}world", -1.0, 1),
            ("x", -1.0, 1), ("\u{2581}x", -0.5, 1),
            ("\u{2581}Hello", -0.2, 1),
        ]
        var m: [UInt8] = []
        for e in entries { m += fBytes(1, piece(e.0, e.1, e.2)) }
        let ts = fVar(40, Int64(0)) + fVar(41, Int64(1)) + fVar(42, Int64(2))
            + fVar(43, Int64(-1))
        let ns = fVar(3, UInt64(1)) + fVar(4, UInt64(1)) + fVar(5, UInt64(1))
        m += fBytes(2, ts) + fBytes(3, ns)
        return Data(m)
    }

    /// Fixture 2: byte_fallback with all 256 `<0xNN>` BYTE pieces.
    private func byteFallbackModel() -> Data {
        var entries: [(String, Float, UInt64)] = [
            ("<unk>", 0, 2), ("<s>", 0, 3), ("</s>", 0, 3),
            ("\u{2581}", -0.1, 1), ("a", -1.0, 1),
        ]
        for i in 0..<256 {
            entries.append((String(format: "<0x%02X>", i), -20.0, 6))
        }
        var m: [UInt8] = []
        for e in entries { m += fBytes(1, piece(e.0, e.1, e.2)) }
        let ts = fVar(40, Int64(0)) + fVar(41, Int64(1)) + fVar(42, Int64(2))
            + fVar(43, Int64(-1)) + fVar(35, UInt64(1))
        let ns = fVar(3, UInt64(1)) + fVar(4, UInt64(1)) + fVar(5, UInt64(1))
        m += fBytes(2, ts) + fBytes(3, ns)
        return Data(m)
    }

    // MARK: - Fixture tests (always run)

    func testFixtureViterbiPicksBestPath() throws {
        let tok = try SPTokenizer(modelData: fixtureModel())
        // ▁ab (-1.5) beats ▁a+b (-2.0) and ▁+a+b.
        XCTAssertEqual(tok.encode("ab").ids, [1, 6, 2])
        // ▁hello (-2.5) beats ▁he+llo (-5.0).
        XCTAssertEqual(tok.encode("hello world").ids, [1, 11, 12, 2])
        XCTAssertEqual(tok.encode("Hello").ids, [1, 15, 2])
        XCTAssertEqual(tok.encode("b").ids, [1, 8, 2])
    }

    func testFixtureWhitespacePipeline() throws {
        let tok = try SPTokenizer(modelData: fixtureModel())
        // Leading/trailing spaces stripped, runs collapsed, one ▁ prefix.
        XCTAssertEqual(tok.encode("  a   b  ").ids, [1, 4, 8, 2])
        XCTAssertEqual(tok.encode("a x").ids, [1, 4, 14, 2])
        // Empty and whitespace-only input → no pieces, just specials.
        XCTAssertEqual(tok.encode("").ids, [1, 2])
        XCTAssertEqual(tok.encode("   ").ids, [1, 2])
    }

    func testFixtureUnknownMerging() throws {
        let tok = try SPTokenizer(modelData: fixtureModel())
        // Three unknown chars merge into ONE unk id.
        XCTAssertEqual(tok.encode("zzz").ids, [1, 3, 0, 2])
        // 'c' unk between known pieces stays a single unk.
        XCTAssertEqual(tok.encode("cab").ids, [1, 3, 0, 5, 7, 2])
        // ☕ (U+2615) unknown without byte fallback → single unk.
        XCTAssertEqual(tok.encode("a\u{2615}").ids, [1, 4, 0, 2])
    }

    func testFixtureMaxLenTruncation() throws {
        let tok = try SPTokenizer(modelData: fixtureModel())
        XCTAssertEqual(tok.encode("hello world", maxLen: 4).ids, [1, 11, 12, 2])
        XCTAssertEqual(tok.encode("hello world", maxLen: 3).ids, [1, 11, 2])
        XCTAssertEqual(tok.encode("hello world", maxLen: 2).ids, [1, 2])
        let r = tok.encode("hello world", maxLen: 3)
        XCTAssertEqual(r.attentionMask, [Int32](repeating: 1, count: 3))
        XCTAssertEqual(r.ids.count, r.attentionMask.count)
    }

    func testFixtureByteFallback() throws {
        let tok = try SPTokenizer(modelData: byteFallbackModel())
        XCTAssertTrue(tok.byteFallbackEnabled)
        // '☕' = UTF-8 E2 98 95 → byte piece ids 5+226, 5+152, 5+149.
        XCTAssertEqual(tok.encode("a\u{2615}").ids, [1, 3, 4, 231, 157, 154, 2])
        XCTAssertEqual(tok.encode("\u{2615}").ids, [1, 3, 231, 157, 154, 2])
        // 'b' unknown → <0x62> = id 5+0x62 = 103. No unk merging.
        XCTAssertEqual(tok.encode("ab").ids, [1, 3, 4, 103, 2])
        XCTAssertEqual(tok.encode("a\u{2615}b").ids,
                       [1, 3, 4, 231, 157, 154, 103, 2])
    }

    func testFixtureSpecialIDs() throws {
        let tok = try SPTokenizer(modelData: fixtureModel())
        XCTAssertEqual(tok.unkID, 0)
        XCTAssertEqual(tok.bosID, 1)
        XCTAssertEqual(tok.eosID, 2)
        XCTAssertEqual(tok.padID, -1)
        XCTAssertFalse(tok.byteFallbackEnabled)
        XCTAssertEqual(tok.id(forPiece: "<s>"), 1)
        XCTAssertEqual(tok.piece(id: 11), "\u{2581}hello")
        // No-specials encode for callers that wrap ids themselves.
        XCTAssertEqual(
            tok.encode("ab", addSpecialTokens: false).ids, [6])
    }

    func testMalformedAndBPEModelsThrow() throws {
        XCTAssertThrowsError(try SPTokenizer(modelData: Data([1, 2, 3])))
        // model_type = BPE (2) must be rejected.
        let bpe = fBytes(1, piece("a", -1.0, 1)) + fBytes(2, fVar(3, UInt64(2)))
        XCTAssertThrowsError(try SPTokenizer(modelData: Data(bpe))) { e in
            XCTAssertEqual(e as? SPTokenizer.SPError,
                           .unsupportedModelType(2))
        }
        // No pieces at all.
        XCTAssertThrowsError(try SPTokenizer(modelData: Data()))
    }

    // MARK: - Real BGE-M3 model (skips when absent)

    private var realModelURL: URL {
        let env = ProcessInfo.processInfo.environment
        return URL(fileURLWithPath:
            env["SWCTX_SPM_MODEL"] ?? "/tmp/spm_bgem3.model")
    }

    private func loadRealModel(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> SPTokenizer? {
        guard FileManager.default.fileExists(atPath: realModelURL.path) else {
            try XCTSkipUnless(false,
                "BGE-M3 sentencepiece.bpe.model not present at " +
                "\(realModelURL.path); set SWCTX_SPM_MODEL. " +
                "Fixture tests above still cover the port.",
                file: file, line: line)
            return nil
        }
        return try SPTokenizer(modelURL: realModelURL)
    }

    /// Reference ids from `sentencepiece` 0.2.2 on the real BGE-M3 model
    /// (`sp.EncodeAsIds` wrapped with bos=1/eos=2).
    private let reference: [(text: String, ids: [Int32])] = [
        ("Hello world", [1, 35377, 8998, 2]),
        ("The quick brown fox jumps over the lazy dog.",
         [1, 580, 63772, 119454, 5, 147796, 88202, 6, 644, 69, 20, 3284,
          10268, 4, 2]),
        ("Xin chào thế giới", [1, 53189, 113479, 3060, 7384, 2]),
        ("Tiếng Việt là một ngôn ngữ rất hay",
         [1, 116720, 3762, 579, 888, 88458, 52115, 3966, 2053, 2]),
        ("def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)",
         [1, 7, 419, 808, 274, 131, 18, 2076, 30645, 652, 2173, 652, 4425,
          115, 37075, 808, 274, 131, 18, 110217, 996, 808, 274, 131, 18, 8,
          10460, 2]),
        ("Hello  world\t tabs\r\nand newline",
         [1, 35377, 8998, 20927, 6, 135, 3524, 2255, 2]),
        ("ｶﾀｶﾅ ① ﬁle", [1, 5, 10044, 10792, 10044, 17455, 105, 11434, 2]),
        ("naïve café ☕ emoji",
         [1, 23, 9391, 271, 26215, 5, 245280, 27, 121504, 2]),
        ("hnhôi và chủ_nghĩa Việt Nam",
         [1, 1095, 6456, 68446, 543, 6656, 453, 448, 126, 32605, 10, 3762,
          2095, 2]),
        ("SELECT * FROM t WHERE x = 'v' -- comment",
         [1, 6754, 144831, 660, 562, 61606, 807, 600, 840, 30095, 1021, 2202,
          241, 333, 24, 4209, 6867, 2]),
    ]

    func testRealModelMetadata() throws {
        guard let tok = try loadRealModel() else { return }
        XCTAssertEqual(tok.vocabSize, 250_002 - 2)  // 250000
        XCTAssertEqual(tok.unkID, 0)
        XCTAssertEqual(tok.bosID, 1)
        XCTAssertEqual(tok.eosID, 2)
        XCTAssertEqual(tok.padID, -1)
        XCTAssertFalse(tok.byteFallbackEnabled)
        XCTAssertEqual(tok.normalizerName, "nmt_nfkc")
        XCTAssertEqual(tok.piece(id: 0), "<unk>")
        XCTAssertEqual(tok.piece(id: 1), "<s>")
        XCTAssertEqual(tok.piece(id: 2), "</s>")
    }

    func testRealModelEncodeMatchesReference() throws {
        guard let tok = try loadRealModel() else { return }
        for (text, expected) in reference {
            let r = tok.encode(text, maxLen: 512)
            XCTAssertEqual(r.ids, expected, "mismatch for \(text.debugDescription)")
            XCTAssertEqual(r.attentionMask.count, r.ids.count)
            XCTAssertTrue(r.attentionMask.allSatisfy { $0 == 1 })
        }
    }

    func testRealModelTruncation() throws {
        guard let tok = try loadRealModel() else { return }
        let full = reference[5].1  // [1, 35377, 8998, 20927, 6, 135, 3524, 2255, 2]
        // maxLen 5 → 3 content pieces + bos/eos.
        XCTAssertEqual(tok.encode(reference[5].0, maxLen: 5).ids,
                       [1, 35377, 8998, 20927, 2])
    }

    func testRealModelNormalizationEdgeCases() throws {
        guard let tok = try loadRealModel() else { return }
        // Charsmap: \u00A0 (NBSP) normalizes to space → same as "café emoji".
        XCTAssertEqual(tok.encode("café\u{00A0}emoji").ids,
                       tok.encode("café emoji").ids)
        // Fullwidth '！' → '!' via charsmap.
        XCTAssertEqual(tok.encode("hello！").ids,
                       tok.encode("hello!").ids)
        XCTAssertEqual(tok.encode("").ids, [1, 2])
        XCTAssertEqual(tok.encode("   ").ids, [1, 2])
    }
}
