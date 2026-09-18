import CoreML
import Foundation

/// Cross-encoder rerank stage (spike v3):
/// jinaai/jina-reranker-v2-base-multilingual —
/// XLMRobertaForSequenceClassification on an XLM-R base backbone
/// (12L/768H, ~278M params, ONE relevance logit; score = logit[0] —
/// jina's compute_score applies sigmoid for probabilities but
/// raw-logit ordering is identical).
///
/// Weights: ~/.swctx/models/jina-reranker-v2-base-multilingual/
///   {model.mlpackage, sentencepiece.bpe.model} — converted by
///   bench/convert_reranker_v3.py. The mlpackage declares two inputs
///   (input_ids, attention_mask) at (1, RangeDim(1,1024)) — XLM-R has
///   no token_type_ids.
///
/// Two caveats vs v2m3 (see the converter docstring):
///   * The HF repo ships jina's own modeling code (fused mixer.Wqkv,
///     einops) whose traced graph hits a coremltools aten::Int
///     failure — the safetensors are remapped into the stock HF class
///     instead (verified bit-identical, ≤3e-7, vs jina's forward).
///   * The repo ships no .model file — but its tokenizer.json unigram
///     vocab is byte-identical to BGE-M3's sentencepiece.bpe.model
///     (same XLM-R 250k vocab family), so that file is installed here
///     and the same SPTokenizer + fairseq id mapping applies:
///     spm unk(0) → 3, every other spm id → id + 1.
///
/// Pair encoding is the XLM-R convention `<s> q </s></s> d </s>`:
///   [0] + q + [2,2] + d + [2]
/// identical to RerankerV2 (verified vs jina compute_score's tokenizer
/// call and tokenizer.json's pair template; no query/doc prefixes).
///
/// Batching mirrors Reranker/RerankerV2: MLModel.predictions(fromBatch:)
/// over the batch-1 model (dynamic-batch conversion produced
/// input-invariant logits on the amberoad spike — same workaround).
public final class RerankerV3: @unchecked Sendable {
    public static let dirName = "jina-reranker-v2-base-multilingual"
    public static var modelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swctx/models/\(dirName)")
    }
    public static var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("model.mlpackage/Manifest.json").path)
            && FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent("sentencepiece.bpe.model").path)
    }

    /// Process-wide lazy handle — model init costs several seconds at
    /// 278M params, so callers share one instance. `nil` when the model
    /// isn't installed or fails to load.
    public static var shared: RerankerV3? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard isInstalled else { return nil }
        cached = try? RerankerV3()
        return cached
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: RerankerV3?

    /// HF special ids (config.json / tokenizer_config.json): the model
    /// pads at runtime, we never emit pad — sequences go in unpadded.
    private static let clsID: Int32 = 0   // <s>
    private static let sepID: Int32 = 2   // </s>
    private static let unkID: Int32 = 3   // <unk>
    /// Pair budget: specials cost 4 (<s> + </s></s> + </s>). The
    /// mlpackage seq axis is RangeDim(1,1024) and jina's rerank()
    /// defaults to max_length=1024, but CPU inference cost grows
    /// ~quadratically, so we cap at 512 like RerankerV2 — our doc
    /// windows (~1800 chars) fit that budget in practice.
    static let maxTokens = 512

    private let model: MLModel
    private let tokenizer: SPTokenizer
    private let inputNames: Set<String>
    private let outputName: String

    public init() throws {
        let dir = RerankerV3.modelDir
        let pkg = dir.appendingPathComponent("model.mlpackage")
        let compiled = dir.appendingPathComponent("model.mlmodelc")
        let modelURL: URL
        if FileManager.default.fileExists(atPath: compiled.path) {
            modelURL = compiled
        } else {
            let tmp = try MLModel.compileModel(at: pkg)
            if let _ = try? FileManager.default.moveItem(at: tmp, to: compiled) {
                modelURL = compiled
            } else {
                modelURL = tmp
            }
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: cfg)
        tokenizer = try SPTokenizer(
            modelURL: dir.appendingPathComponent("sentencepiece.bpe.model"))

        inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        let outputs = model.modelDescription.outputDescriptionsByName
        if outputs["logits"] != nil {
            outputName = "logits"
        } else {
            // Fallback: first multiarray output (single-logit head →
            // last dim is 1).
            outputName = outputs.first(where: {
                $0.value.type == .multiArray
            })?.key ?? outputs.keys.sorted().first ?? "logits"
        }
    }

    /// Pay the CoreML compile + first-prediction cost up front so
    /// measured pairs don't include it.
    public func warm() {
        _ = score(query: "warm", doc: "up")
    }

    // MARK: - Doc context (shared recipe with Reranker)

    public static func docContext(path: String, symbol: String?, content: String,
                                  headLines: Int = 10, maxChars: Int = 1800) -> String {
        Reranker.docContext(path: path, symbol: symbol, content: content,
                            headLines: headLines, maxChars: maxChars)
    }

    public static func docWindows(path: String, symbol: String?, content: String,
                                  headLines: Int = 10, tailLines: Int = 10,
                                  maxChars: Int = 1800) -> [String] {
        Reranker.docWindows(path: path, symbol: symbol, content: content,
                            headLines: headLines, tailLines: tailLines,
                            maxChars: maxChars)
    }

    // MARK: - Scoring

    /// spm internal id → HF id (fairseq +1 offset; spm unk → HF unk 3).
    @inline(__always) private func hfID(_ spmID: Int32) -> Int32 {
        spmID == tokenizer.unkID ? Self.unkID : spmID + 1
    }

    /// `<s> q </s></s> d </s>` pair encoding, HF "longest_first"
    /// truncation: drop tail pieces from the longer side until both
    /// fit (4 specials reserve from maxTokens).
    func tokenizePair(_ q: String, _ d: String) -> [Int32] {
        var qIDs = tokenizer.encode(q, maxLen: Self.maxTokens,
                                    addSpecialTokens: false).ids.map(hfID)
        var dIDs = tokenizer.encode(d, maxLen: Self.maxTokens,
                                    addSpecialTokens: false).ids.map(hfID)
        let budget = Self.maxTokens - 4
        while qIDs.count + dIDs.count > budget {
            if qIDs.count >= dIDs.count { qIDs.removeLast() }
            else { dIDs.removeLast() }
        }
        var ids: [Int32] = [Self.clsID]
        ids.append(contentsOf: qIDs)
        ids.append(Self.sepID); ids.append(Self.sepID)
        ids.append(contentsOf: dIDs)
        ids.append(Self.sepID)
        return ids
    }

    /// Feature dict for one pair at its natural length — seq is
    /// RangeDim'd, so no padding per row.
    private func features(for ids: [Int32]) -> MLDictionaryFeatureProvider? {
        let seq = ids.count
        guard seq > 0,
              let inputIDs = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                               dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                           dataType: .int32)
        else { return nil }
        let idPtr = inputIDs.dataPointer.assumingMemoryBound(to: Int32.self)
        let maskPtr = mask.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<seq {
            idPtr[i] = ids[i]
            maskPtr[i] = 1
        }
        var features: [String: MLFeatureValue] = [:]
        if inputNames.contains("input_ids") {
            features["input_ids"] = MLFeatureValue(multiArray: inputIDs)
        }
        if inputNames.contains("attention_mask") {
            features["attention_mask"] = MLFeatureValue(multiArray: mask)
        }
        guard !features.isEmpty else { return nil }
        return try? MLDictionaryFeatureProvider(dictionary: features)
    }

    /// Single-logit head: logit[0] is the relevance score (sigmoid for
    /// probability would preserve ordering).
    private func relevantLogit(_ logits: MLMultiArray) -> Float? {
        guard logits.count >= 1 else { return nil }
        return logits[[0, 0] as [NSNumber]].floatValue
    }

    public func score(query: String, doc: String) -> Float? {
        let ids = tokenizePair(query, doc)
        guard let provider = features(for: ids),
              let out = try? model.prediction(from: provider),
              let logits = out.featureValue(for: outputName)?.multiArrayValue
        else { return nil }
        return relevantLogit(logits)
    }

    /// Score (query, doc) pairs in groups of `batchSize` via the batch
    /// prediction API — pipelines the per-row predictions.
    public func scoreAll(query: String, docs: [String],
                         batchSize: Int = 16) -> [Float?] {
        var scores = [Float?](repeating: nil, count: docs.count)
        var start = 0
        while start < docs.count {
            let end = min(start + max(1, batchSize), docs.count)
            var providers: [MLFeatureProvider] = []
            providers.reserveCapacity(end - start)
            var batchIdx: [Int] = []
            for i in start..<end {
                let ids = tokenizePair(query, docs[i])
                guard let p = features(for: ids) else { continue }
                providers.append(p)
                batchIdx.append(i)
            }
            if let results = try? model.predictions(
                fromBatch: MLArrayBatchProvider(array: providers)) {
                for (j, i) in batchIdx.enumerated() {
                    guard let logits = results.features(at: j)
                            .featureValue(for: outputName)?.multiArrayValue
                    else { continue }
                    scores[i] = relevantLogit(logits)
                }
            }
            start = end
        }
        return scores
    }

    /// Max-pooled multi-window scoring: flattens every candidate's
    /// windows into one batch, then returns each candidate's best
    /// window score. Nil windows never win a candidate's max.
    public func scoreAllMax(query: String, windows: [[String]],
                            batchSize: Int = 16) -> [Float?] {
        var flat: [String] = []
        var spans: [(Int, Int)] = []  // [start, count) per candidate
        for w in windows {
            spans.append((flat.count, w.count))
            flat += w
        }
        let flatScores = scoreAll(query: query, docs: flat, batchSize: batchSize)
        return spans.map { (s, n) in
            (0..<n).compactMap { flatScores[s + $0] }.max()
        }
    }
}
