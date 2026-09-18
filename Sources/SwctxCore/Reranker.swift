import CoreML
import Foundation

/// Cross-encoder rerank stage (spike): amberoad/bert-multilingual-passage-
/// reranking-msmarco — BertForSequenceClassification on the multilingual-
/// uncased backbone (WordPiece vocab, 2 logits; score = logit[1]).
///
/// Weights: ~/.swctx/models/amberoad-bert-multilingual-reranking-msmarco/
///   {model.mlpackage, vocab.txt} — converted by bench/convert_reranker.py.
/// The mlpackage declares three inputs (input_ids, attention_mask,
/// token_type_ids) at (1, RangeDim(1,512)); pair token_type_ids carry the
/// segment signal (0 = query incl. [CLS]/first [SEP], 1 = doc + last [SEP]).
/// Batching uses MLModel.predictions(fromBatch:) over the batch-1 model —
/// a dynamic-batch conversion produced input-invariant logits (see spike
/// notes), so per-row predictions pipelined by the batch API it is.
public final class Reranker: @unchecked Sendable {
    public static let dirName = "amberoad-bert-multilingual-reranking-msmarco"
    public static var modelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swctx/models/\(dirName)")
    }
    public static var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("model.mlpackage/Manifest.json").path)
            && FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent("vocab.txt").path)
    }

    /// Process-wide lazy handle — model init costs ~0.3-1s, so callers share
    /// one instance. `nil` when the model isn't installed or fails to load.
    public static var shared: Reranker? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard isInstalled else { return nil }
        cached = try? Reranker()
        return cached
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Reranker?

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let inputNames: Set<String>
    private let outputName: String

    public init() throws {
        let dir = Reranker.modelDir
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

        // Multilingual-uncased vocab: lowercase + accent strip + CJK split —
        // HF's BasicTokenizer recipe for this family. The vocab holds zero
        // accented forms (đ/Đ are base letters, kept), so unmarked VN words
        // would collapse to [UNK] without the strip.
        guard let tok = WordPieceTokenizer(
            vocabAt: dir.appendingPathComponent("vocab.txt"),
            cased: false, stripAccents: true, splitCJK: true)
        else {
            throw NSError(domain: "swctx", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "missing/unreadable vocab.txt in \(dir.path)"])
        }
        tokenizer = tok

        inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        let outputs = model.modelDescription.outputDescriptionsByName
        if outputs["logits"] != nil {
            outputName = "logits"
        } else {
            // Fallback: first multiarray output whose last dim is 2 (the
            // relevance class count).
            outputName = outputs.first(where: {
                $0.value.type == .multiArray
                    && $0.value.multiArrayConstraint?.shape.last?.intValue == 2
            })?.key ?? outputs.keys.sorted().first ?? "logits"
        }
    }

    /// Pay the CoreML compile + first-prediction cost up front so measured
    /// pairs don't include it.
    public func warm() {
        _ = score(query: "warm", doc: "up")
    }

    // MARK: - Doc context

    /// Doc side of the pair: path + symbol + chunk head (declaration line,
    /// docstring, first ~10 lines) rather than the whole chunk — the
    /// 512-token budget is shared with the query, and the head is where a
    /// code chunk's identifying text lives.
    public static func docContext(path: String, symbol: String?, content: String,
                                  headLines: Int = 10, maxChars: Int = 1800) -> String {
        var ctx = path + "\n" + (symbol ?? "") + "\n"
        let head = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(headLines)
            .joined(separator: "\n")
        ctx += head
        if ctx.count > maxChars { ctx = String(ctx.prefix(maxChars)) }
        return ctx
    }

    /// Head + tail windows for long chunks, max-pooled at score time —
    /// the documented long-doc scheme (Cohere/Elastic: score per window,
    /// take max). Relevant code doesn't always sit in the head; the tail
    /// window catches matches at the end of big chunks. Short chunks
    /// produce a single window (identical to docContext).
    public static func docWindows(path: String, symbol: String?, content: String,
                                  headLines: Int = 10, tailLines: Int = 10,
                                  maxChars: Int = 1800) -> [String] {
        let head = docContext(path: path, symbol: symbol, content: content,
                              headLines: headLines, maxChars: maxChars)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > headLines + tailLines else { return [head] }
        var tail = path + "\n" + (symbol ?? "") + "\n"
        tail += lines.suffix(tailLines).joined(separator: "\n")
        if tail.count > maxChars { tail = String(tail.prefix(maxChars)) }
        return [head, tail]
    }

    // MARK: - Scoring

    /// Feature dict for one (query, doc) pair at its natural length — seq
    /// is RangeDim'd, so no padding is needed per row.
    private func features(for pair: (ids: [Int32], types: [Int32]))
        -> MLDictionaryFeatureProvider? {
        let seq = pair.ids.count
        guard seq > 0,
              let inputIDs = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                               dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                           dataType: .int32),
              let types = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                            dataType: .int32)
        else { return nil }
        let idPtr = inputIDs.dataPointer.assumingMemoryBound(to: Int32.self)
        let maskPtr = mask.dataPointer.assumingMemoryBound(to: Int32.self)
        let typePtr = types.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<seq {
            idPtr[i] = pair.ids[i]
            maskPtr[i] = 1
            typePtr[i] = pair.types[i]
        }
        var features: [String: MLFeatureValue] = [:]
        if inputNames.contains("input_ids") {
            features["input_ids"] = MLFeatureValue(multiArray: inputIDs)
        }
        if inputNames.contains("attention_mask") {
            features["attention_mask"] = MLFeatureValue(multiArray: mask)
        }
        if inputNames.contains("token_type_ids") {
            features["token_type_ids"] = MLFeatureValue(multiArray: types)
        }
        guard !features.isEmpty else { return nil }
        return try? MLDictionaryFeatureProvider(dictionary: features)
    }

    /// Read logit[1] (the "relevant" class) from a [1,2] logits multiarray;
    /// fp16 storage is converted by the NSNumber accessor.
    private func relevantLogit(_ logits: MLMultiArray) -> Float? {
        guard logits.count >= 2 else { return nil }
        return logits[[0, 1] as [NSNumber]].floatValue
    }

    /// logit[1] of one pair — ranking by raw logit is equivalent to
    /// softmax ranking for the 2-class head.
    public func score(query: String, doc: String) -> Float? {
        let pair = tokenizer.tokenizePair(query, doc)
        guard let provider = features(for: pair),
              let out = try? model.prediction(from: provider),
              let logits = out.featureValue(for: outputName)?.multiArrayValue
        else { return nil }
        return relevantLogit(logits)
    }

    /// Score (query, doc) pairs in groups of `batchSize` via the batch
    /// prediction API — pipelines the per-row predictions without needing
    /// a dynamic batch dim in the model.
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
                let pair = tokenizer.tokenizePair(query, docs[i])
                guard let p = features(for: pair) else { continue }
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
