import CoreML
import Foundation
import Accelerate

/// A BERT-family CoreML embedding model: WordPiece tokenizer + last-hidden-state
/// pooling. Configured per model by `EmbeddingModelSpec`; the tokenizers differ
/// only in casing (uncased vocab → lowercase, cased vocab → keep case/accents,
/// split CJK chars per HF `tokenize_chinese_chars`).
public struct EmbeddingModelSpec: Sendable {
    public enum Pooling: Sendable { case cls, mean }
    /// Meta/CLI identifier, e.g. "bge-base-en-v1.5".
    public let id: String
    /// Embedding dimension (hidden size).
    public let dim: Int
    /// Directory under ~/.swctx/models/ holding model.mlpackage + vocab.txt.
    public let dirName: String
    /// true → cased vocab: no lowercasing/accent stripping, CJK chars split.
    public let cased: Bool
    /// cls → vector at position 0; mean → attention-mask-weighted mean.
    public let pooling: Pooling
    public let displayName: String

    public var modelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swctx/models/\(dirName)")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("model.mlpackage/Manifest.json").path)
            && FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent("vocab.txt").path)
    }
}

/// Pure-Swift WordPiece tokenizer (HF basic tokenizer + greedy longest-match
/// wordpiece). `cased` switches the two model families we ship: uncased
/// (bge-base-en, lowercases) vs cased multilingual (distiluse, keeps case and
/// splits CJK chars into single tokens like HF's `tokenize_chinese_chars`).
struct WordPieceTokenizer {
    let vocab: [String: Int32]
    let cased: Bool
    static let maxTokens = 512

    init(vocab: [String: Int32], cased: Bool) {
        self.vocab = vocab
        self.cased = cased
    }

    init?(vocabAt url: URL, cased: Bool) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var v: [String: Int32] = [:]
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            v[String(line)] = Int32(i)
        }
        guard !v.isEmpty else { return nil }
        self.init(vocab: v, cased: cased)
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

    /// Uncased mode: lowercase, split on whitespace+punct (BERT basic tokenizer).
    /// Cased mode: same split but no lowercasing, and CJK ideographs are broken
    /// out as single-char tokens (HF `tokenize_chinese_chars`).
    private func basicTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        func flush() {
            if !cur.isEmpty { tokens.append(cur); cur = "" }
        }
        let source = cased ? text : text.lowercased()
        for scalar in source.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD
                || CharacterSet.controlCharacters.contains(scalar) { continue }
            if cased && WordPieceTokenizer.isCJK(scalar) {
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
    private let tokenizer: WordPieceTokenizer
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

        guard let tok = WordPieceTokenizer(
            vocabAt: dir.appendingPathComponent("vocab.txt"), cased: spec.cased)
        else {
            throw NSError(domain: "swctx", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "missing/unreadable vocab.txt in \(dir.path)"])
        }
        tokenizer = tok

        inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        // Prefer known hidden-state names, else first multiarray output whose
        // last dimension matches the spec's embedding dim.
        let outputs = model.modelDescription.outputDescriptionsByName
        if outputs["hidden_states"] != nil { outputName = "hidden_states" }
        else if outputs["last_hidden_state"] != nil { outputName = "last_hidden_state" }
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

    func tokenize(_ text: String) -> [Int32] { tokenizer.tokenize(text) }

    // MARK: - Inference

    /// L2-normalized embedding — dot product of two outputs equals cosine.
    /// Feeds only the inputs the model declares (token_type_ids is skipped for
    /// distilbert). Pooling per spec: CLS position or attention-mask mean.
    public func embed(_ text: String) -> [Float]? {
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
