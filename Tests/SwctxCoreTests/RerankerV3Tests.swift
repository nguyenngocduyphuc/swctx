import XCTest
@testable import SwctxCore

/// Tests for `RerankerV3` (jina-reranker-v2-base-multilingual,
/// XLM-R-base cross-encoder).
///
/// `tokenizePair` is asserted byte-for-byte against HF
/// `XLMRobertaTokenizer` pair encodings captured from transformers
/// 4.46.3 on the real model (see bench/convert_reranker_v3.py):
/// XLM-R convention `<s> q </s></s> d </s>` = [0] + q + [2,2] + d + [2]
/// with the fairseq id mapping (spm unk → 3, other spm ids → id+1).
/// The reference ids match RerankerV2Tests' exactly — jina's
/// tokenizer.json unigram vocab is byte-identical to BGE-M3's
/// sentencepiece.bpe.model (verified piece-for-piece during the
/// conversion spike).
///
/// All tests XCTSkip when
/// ~/.swctx/models/jina-reranker-v2-base-multilingual/ is absent —
/// instantiating RerankerV3 loads the ~531MB mlpackage, so this stays
/// opt-in on machines without the spike artifacts.
final class RerankerV3Tests: SwctxTestCase {

    private func loadReranker(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> RerankerV3? {
        guard RerankerV3.isInstalled else {
            try XCTSkipUnless(false,
                "jina-reranker-v2-base-multilingual not installed at \(RerankerV3.modelDir.path)",
                file: file, line: line)
            return nil
        }
        return try RerankerV3()
    }

    /// Reference ids from transformers 4.46.3 XLMRobertaTokenizer
    /// (jinaai/jina-reranker-v2-base-multilingual tokenizer.json):
    ///   tok(q, d, truncation="longest_first", max_length=512)
    private let references: [(q: String, d: String, ids: [Int32])] = [
        ("hàm tạo mảnh tin telegram báo có lead mới hôm qua",
         "crm-nam-pham/09-build/tin_lead.py\nformat_fragment\n"
         + "def format_fragment(lead):\n    return f'new lead: {lead}'",
         [0, 126215, 7217, 170032, 2478, 5501, 25561, 9216, 524, 37105,
          3633, 26094, 2799, 2, 2, 8374, 39, 9, 9239, 9, 14612, 39, 63142,
          9, 177149, 64, 2311, 454, 133, 712, 5, 6493, 9384, 454, 6000,
          177, 674, 8, 420, 9384, 454, 6000, 177, 674, 132, 133, 712,
          2077, 30646, 1238, 25, 54936, 37105, 12, 10666, 133, 712, 8152,
          25, 2]),
        ("script kiểm tra canonical url",
         "scripts/p8_canonical_check.py\ncheck_canonical\nCheck whether "
         + "google is selecting a different canonical URL.",
         [0, 26499, 19595, 1152, 74413, 21533, 6, 25002, 2, 2, 26499, 7,
          64, 254, 1019, 454, 38938, 19, 21533, 454, 78292, 5, 6493, 12765,
          454, 38938, 19, 21533, 38679, 36766, 26484, 83, 36849, 214, 10,
          12921, 74413, 21533, 31862, 5, 2]),
        ("warm", "up", [0, 24814, 2, 2, 1257, 2]),
    ]

    func testTokenizePairMatchesHF() throws {
        guard let r = try loadReranker() else { return }
        for (q, d, expected) in references {
            XCTAssertEqual(r.tokenizePair(q, d), expected,
                           "mismatch for \(q.debugDescription)")
        }
    }

    func testTokenizePairTruncation() throws {
        guard let r = try loadReranker() else { return }
        // Budget = maxTokens - 4 specials; longest side (doc) shrinks
        // first under longest_first truncation.
        let ids = r.tokenizePair("q", String(repeating: "từ ", count: 2000))
        XCTAssertEqual(ids.count, RerankerV3.maxTokens)
        XCTAssertEqual(ids.first, 0)
        XCTAssertEqual(ids.last, 2)
        // specials: [0] q [2,2] d [2] → tiny q leaves the </s></s> pair
        // at fixed positions 2-3.
        XCTAssertEqual(ids[2], 2)
        XCTAssertEqual(ids[3], 2)
    }

    /// End-to-end single-pair score — validates CoreML path + logit
    /// extraction. Only asserts a finite score (ordering is the eval's
    /// job); keeps runtime to one forward pass.
    func testScoreProducesFiniteLogit() throws {
        guard let r = try loadReranker() else { return }
        let s = r.score(query: "warm", doc: "up")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.isFinite)
    }
}
