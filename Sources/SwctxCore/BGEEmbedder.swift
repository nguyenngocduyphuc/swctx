import CoreML
import Foundation
import Accelerate

/// A BERT-family CoreML embedding model: WordPiece tokenizer + last-hidden-state
/// pooling. Configured per model by `EmbeddingModelSpec`; the tokenizers differ
/// only in casing (uncased vocab → lowercase, cased vocab → keep case/accents,
/// split CJK chars per HF `tokenize_chinese_chars`).
public struct EmbeddingModelSpec: Sendable {
    public enum Pooling: Sendable { case cls, mean }
    public enum Tokenizer: Sendable { case wordpiece, sentencepiece }
    /// Meta/CLI identifier, e.g. "bge-base-en-v1.5".
    public let id: String
    /// Embedding dimension (hidden size).
    public let dim: Int
    /// Directory under ~/.swctx/models/ holding model.mlpackage + vocab file.
    public let dirName: String
    /// true → cased vocab: no lowercasing/accent stripping, CJK chars split.
    public let cased: Bool
    /// cls → vector at position 0; mean → attention-mask-weighted mean.
    public let pooling: Pooling
    /// wordpiece → vocab.txt + WordPieceTokenizer; sentencepiece →
    /// sentencepiece.bpe.model + SPTokenizer (XLM-R family: bge-m3).
    public let tokenizer: Tokenizer
    public let displayName: String

    public init(id: String, dim: Int, dirName: String, cased: Bool,
                pooling: Pooling, tokenizer: Tokenizer = .wordpiece,
                displayName: String) {
        self.id = id
        self.dim = dim
        self.dirName = dirName
        self.cased = cased
        self.pooling = pooling
        self.tokenizer = tokenizer
        self.displayName = displayName
    }

    public var modelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swctx/models/\(dirName)")
    }

    public var vocabFileName: String {
        tokenizer == .sentencepiece ? "sentencepiece.bpe.model" : "vocab.txt"
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("model.mlpackage/Manifest.json").path)
            && FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent(vocabFileName).path)
    }
}

/// Pure-Swift WordPiece tokenizer (HF basic tokenizer + greedy longest-match
/// wordpiece). `cased` switches the two model families we ship: uncased
/// (bge-base-en, lowercases) vs cased multilingual (distiluse, keeps case and
/// splits CJK chars into single tokens like HF's `tokenize_chinese_chars`).
struct WordPieceTokenizer {
    let vocab: [String: Int32]
    let cased: Bool
    /// HF BasicTokenizer accent strip (NFD → drop combining marks). Every
    /// uncased HF model applies it; it stays off for bge-uncased so existing
    /// indexes keep their tokenization, on for multilingual-uncased vocabs
    /// that contain no accented forms at all (đ/Đ are base letters there —
    /// đ has no canonical decomposition, so it survives).
    let stripAccents: Bool
    /// Split CJK ideographs into single-char tokens (HF
    /// `tokenize_chinese_chars`). Defaults to `cased` — the original rule.
    let splitCJK: Bool
    static let maxTokens = 512

    init(vocab: [String: Int32], cased: Bool,
         stripAccents: Bool = false, splitCJK: Bool? = nil) {
        self.vocab = vocab
        self.cased = cased
        self.stripAccents = stripAccents
        self.splitCJK = splitCJK ?? cased
    }

    init?(vocabAt url: URL, cased: Bool,
          stripAccents: Bool = false, splitCJK: Bool? = nil) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var v: [String: Int32] = [:]
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            v[String(line)] = Int32(i)
        }
        guard !v.isEmpty else { return nil }
        self.init(vocab: v, cased: cased,
                  stripAccents: stripAccents, splitCJK: splitCJK)
    }

    func tokenize(_ text: String) -> [Int32] {
        var ids: [Int32] = [vocab["[CLS]"] ?? 101]
        // Cap per-piece (not per-token): checking after a whole token lets ids
        // overshoot maxTokens, and the model rejects seq > 512 at prediction.
        outer: for basic in basicTokens(text) {
            for piece in wordPieces(basic) {
                ids.append(piece)
                if ids.count >= WordPieceTokenizer.maxTokens - 1 { break outer }
            }
        }
        ids.append(vocab["[SEP]"] ?? 102)
        return ids
    }

    /// [CLS] a [SEP] b [SEP] pair encoding with segment ids — 0 for the
    /// a-side (CLS + a + first SEP), 1 for the b-side (+ last SEP). HF
    /// "longest_first" truncation: drop tail pieces from the longer side
    /// until both fit (3 specials reserve from maxTokens).
    func tokenizePair(_ a: String, _ b: String)
        -> (ids: [Int32], types: [Int32]) {
        var aPieces = basicTokens(a).flatMap { wordPieces($0) }
        var bPieces = basicTokens(b).flatMap { wordPieces($0) }
        let budget = WordPieceTokenizer.maxTokens - 3
        while aPieces.count + bPieces.count > budget {
            if aPieces.count >= bPieces.count { aPieces.removeLast() }
            else { bPieces.removeLast() }
        }
        var ids: [Int32] = [vocab["[CLS]"] ?? 101]
        var types: [Int32] = [0]
        ids.append(contentsOf: aPieces)
        types.append(contentsOf: [Int32](repeating: 0, count: aPieces.count))
        ids.append(vocab["[SEP]"] ?? 102); types.append(0)
        ids.append(contentsOf: bPieces)
        types.append(contentsOf: [Int32](repeating: 1, count: bPieces.count))
        ids.append(vocab["[SEP]"] ?? 102); types.append(1)
        return (ids, types)
    }

    /// Uncased mode: lowercase (+ optional accent strip), split on
    /// whitespace+punct (BERT basic tokenizer). Cased mode: same split but
    /// no lowercasing/stripping. CJK ideographs are broken out as
    /// single-char tokens when `splitCJK` (HF `tokenize_chinese_chars`).
    private func basicTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        func flush() {
            if !cur.isEmpty { tokens.append(cur); cur = "" }
        }
        var source = cased ? text : text.lowercased()
        if stripAccents { source = source.decomposedStringWithCanonicalMapping }
        for scalar in source.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD
                || CharacterSet.controlCharacters.contains(scalar) { continue }
            if stripAccents && CharacterSet.nonBaseCharacters.contains(scalar) {
                continue
            }
            if splitCJK && WordPieceTokenizer.isCJK(scalar) {
                flush()
                tokens.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                cur.append(Character(scalar))
            } else if CharacterSet.whitespaces.contains(scalar) || scalar == " " {
                flush()
            } else {
                flush()
                tokens.append(String(scalar))
            }
        }
        flush()
        return tokens
    }

    /// CJK Unified Ideographs + extensions (HF basic tokenizer ranges).
    private static func isCJK(_ s: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
            || (0x20000...0x2A6DF).contains(s.value) || (0x2A700...0x2B73F).contains(s.value)
            || (0x2B740...0x2B81F).contains(s.value) || (0x2B820...0x2CEAF).contains(s.value)
            || (0xF900...0xFAFF).contains(s.value) || (0x2F800...0x2FA1F).contains(s.value)
    }

    /// Greedy longest-match WordPiece; unmatchable tokens -> [UNK].
    private func wordPieces(_ token: String) -> [Int32] {
        if token.count > 100 { return [vocab["[UNK]"] ?? 100] }
        var chars = Array(token)
        var out: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var hit: String?
            while start < end {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if vocab[sub] != nil { hit = sub; break }
                end -= 1
            }
            guard let h = hit, let id = vocab[h] else {
                return [vocab["[UNK]"] ?? 100]
            }
            out.append(id)
            start = end
        }
        return out
    }
}

/// CoreML embedding model (BERT-family WordPiece, configurable pooling).
/// Default weights: ~/.swctx/models/bge-base-en-v1.5/{model.mlpackage,vocab.txt}
/// (rsvalerio/bge-base-en-v1.5-coreml, MIT); multilingual variant:
/// distiluse-base-multilingual-cased-v2 (converted locally via coremltools).
public final class BGEEmbedder: @unchecked Sendable {
    /// Kept for source compatibility — the default model's install dir.
    public static let modelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".swctx/models/bge-base-en-v1.5")

    public static var isInstalled: Bool { Embedder.bgeSpec.isInstalled }

    public let spec: EmbeddingModelSpec
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer?
    /// SentencePiece tokenizer for XLM-R-family models (bge-m3) — mutually
    /// exclusive with `tokenizer` above, selected by `spec.tokenizer`.
    private let spTokenizer: SPTokenizer?
    /// Model inputs actually fed (distilbert lacks token_type_ids).
    private let inputNames: Set<String>
    /// Output feature carrying [1,seq,dim] hidden states (or [1,dim] pooled).
    private let outputName: String

    public init(spec: EmbeddingModelSpec = Embedder.bgeSpec) throws {
        self.spec = spec
        let dir = spec.modelDir
        let pkg = dir.appendingPathComponent("model.mlpackage")
        // Compile once, cache .mlmodelc next to the package.
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

        switch spec.tokenizer {
        case .wordpiece:
            guard let tok = WordPieceTokenizer(
                vocabAt: dir.appendingPathComponent("vocab.txt"), cased: spec.cased)
            else {
                throw NSError(domain: "swctx", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "missing/unreadable vocab.txt in \(dir.path)"])
            }
            tokenizer = tok
            spTokenizer = nil
        case .sentencepiece:
            spTokenizer = try SPTokenizer(
                modelURL: dir.appendingPathComponent("sentencepiece.bpe.model"))
            tokenizer = nil
        }

        inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        // Prefer known hidden-state names, else first multiarray output whose
        // last dimension matches the spec's embedding dim.
        let outputs = model.modelDescription.outputDescriptionsByName
        if outputs["hidden_states"] != nil { outputName = "hidden_states" }
        else if outputs["last_hidden_state"] != nil { outputName = "last_hidden_state" }
        else if outputs["embedding"] != nil { outputName = "embedding" }
        else {
            outputName = outputs.first(where: {
                $0.value.type == .multiArray
                    && $0.value.multiArrayConstraint?.shape.last?.intValue == spec.dim
            })?.key ?? outputs.keys.sorted().first ?? "hidden_states"
        }
    }

    public var dimension: Int { spec.dim }
    public var modelName: String { spec.id }
    var cased: Bool { spec.cased }

    func tokenize(_ text: String) -> [Int32] {
        if let sp = spTokenizer { return sp.encode(text, maxLen: 512).ids }
        return tokenizer?.tokenize(text) ?? []
    }

    // MARK: - Inference

    /// L2-normalized embedding — dot product of two outputs equals cosine.
    /// Feeds only the inputs the model declares (token_type_ids is skipped for
    /// distilbert). Pooling per spec: CLS position or attention-mask mean.
    public func embed(_ text: String) -> [Float]? {
        // CoreML prediction allocates autoreleased ObjC temporaries per call
        // (MLMultiArray inputs, feature providers, prediction output, ANE
        // buffers). In a bulk embed loop nothing drains them until the
        // process exits — past ~16k calls the ANE stack is exhausted and
        // every prediction fails, and a recreated Embedder cannot recover
        // because the leak is process-level. Drain per call instead.
        autoreleasepool { embedImpl(text) }
    }

    private func embedImpl(_ text: String) -> [Float]? {
        let ids = tokenize(String(text.prefix(6000)))
        let seq = ids.count
        guard let inputIDs = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                               dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                           dataType: .int32),
              let types = try? MLMultiArray(shape: [1, NSNumber(value: seq)],
                                            dataType: .int32)
        else { return nil }
        let idPtr = inputIDs.dataPointer.assumingMemoryBound(to: Int32.self)
        let maskPtr = mask.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<seq { idPtr[i] = ids[i]; maskPtr[i] = 1 }
        // token_type_ids stays zeroed.

        var features: [String: MLFeatureValue] = [:]
        if inputNames.contains("input_ids") { features["input_ids"] = MLFeatureValue(multiArray: inputIDs) }
        if inputNames.contains("attention_mask") { features["attention_mask"] = MLFeatureValue(multiArray: mask) }
        if inputNames.contains("token_type_ids") { features["token_type_ids"] = MLFeatureValue(multiArray: types) }
        guard !features.isEmpty,
              let provider = try? MLDictionaryFeatureProvider(dictionary: features),
              let out = try? model.prediction(from: provider),
              let hidden = out.featureValue(for: outputName)?.multiArrayValue
        else { return nil }
        // The decoders below rebind dataPointer as Float — an fp16/fp64
        // output would silently produce garbage vectors instead of failing.
        guard hidden.dataType == .float32 else { return nil }

        var vec: [Float]
        if hidden.shape.count <= 2 {
            // Already-pooled output [1,dim] or [dim].
            let dim = hidden.count
            vec = [Float](repeating: 0, count: dim)
            hidden.dataPointer.withMemoryRebound(to: Float.self, capacity: dim) { ptr in
                for i in 0..<dim { vec[i] = ptr[i] }
            }
        } else {
            // [1, seq, dim] hidden states.
            let dim = hidden.shape[2].intValue
            vec = [Float](repeating: 0, count: dim)
            switch spec.pooling {
            case .cls:
                hidden.dataPointer.withMemoryRebound(to: Float.self, capacity: dim) { ptr in
                    for i in 0..<dim { vec[i] = ptr[i] }
                }
            case .mean:
                hidden.dataPointer.withMemoryRebound(to: Float.self,
                                                     capacity: seq * dim) { ptr in
                    var weightSum: Float = 0
                    for t in 0..<seq where maskPtr[t] > 0 {
                        weightSum += 1
                        let row = ptr + t * dim
                        vec.withUnsafeMutableBufferPointer { dst in
                            vDSP_vadd(dst.baseAddress!, 1, row, 1,
                                      dst.baseAddress!, 1, vDSP_Length(dim))
                        }
                    }
                    if weightSum > 0 {
                        var inv = 1 / weightSum
                        vDSP_vsmul(vec, 1, &inv, &vec, 1, vDSP_Length(dim))
                    }
                }
            }
        }
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        var scale = 1 / sqrtf(max(norm, 1e-9))
        vDSP_vsmul(vec, 1, &scale, &vec, 1, vDSP_Length(vec.count))
        return vec
    }
}
