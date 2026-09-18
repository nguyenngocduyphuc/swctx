import CoreML
import Foundation
import Accelerate

/// bge-base-en-v1.5 on CoreML (768-d, bert-uncased vocab, CLS pooling).
/// Weights: ~/.swctx/models/bge-base-en-v1.5/{model.mlpackage,vocab.txt}
/// (rsvalerio/bge-base-en-v1.5-coreml, MIT). Pure-Swift WordPiece tokenizer —
/// no tokenizer dependency needed for an uncased BERT vocab.
public final class BGEEmbedder: @unchecked Sendable {
    public static let modelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".swctx/models/bge-base-en-v1.5")
    static let maxTokens = 512

    private let model: MLModel
    private let vocab: [String: Int32]

    public static var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("model.mlpackage/Manifest.json").path)
            && FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent("vocab.txt").path)
    }

    public init() throws {
        let pkg = BGEEmbedder.modelDir.appendingPathComponent("model.mlpackage")
        // Compile once, cache .mlmodelc next to the package.
        let compiled = BGEEmbedder.modelDir.appendingPathComponent("model.mlmodelc")
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

        var v: [String: Int32] = [:]
        let text = try String(contentsOf: BGEEmbedder.modelDir.appendingPathComponent("vocab.txt"),
                              encoding: .utf8)
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            v[String(line)] = Int32(i)
        }
        vocab = v
    }

    public var dimension: Int { 768 }
    public var modelName: String { "bge-base-en-v1.5-coreml" }

    // MARK: - WordPiece tokenizer (bert-base-uncased)

    func tokenize(_ text: String) -> [Int32] {
        var ids: [Int32] = [vocab["[CLS]"] ?? 101]
        // Cap per-piece (not per-token): checking after a whole token lets ids
        // overshoot maxTokens, and the model rejects seq > 512 at prediction.
        outer: for basic in basicTokens(text) {
            for piece in wordPieces(basic) {
                ids.append(piece)
                if ids.count >= BGEEmbedder.maxTokens - 1 { break outer }
            }
        }
        ids.append(vocab["[SEP]"] ?? 102)
        return ids
    }

    /// Lowercase, strip accents/control chars, split on whitespace+punct (BERT basic tokenizer).
    private func basicTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        func flush() {
            if !cur.isEmpty { tokens.append(cur); cur = "" }
        }
        for scalar in text.lowercased().unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD
                || CharacterSet.controlCharacters.contains(scalar) { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
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

    // MARK: - Inference

    /// CLS-pooled, L2-normalized embedding (dot product == cosine).
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

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "attention_mask": MLFeatureValue(multiArray: mask),
            "token_type_ids": MLFeatureValue(multiArray: types),
        ]),
            let out = try? model.prediction(from: provider),
            let hidden = out.featureValue(for: "hidden_states")?.multiArrayValue
        else { return nil }

        // hidden: [1, seq, 768] — CLS = position 0.
        let dim = hidden.shape.count == 3 ? hidden.shape[2].intValue : hidden.shape.last!.intValue
        var vec = [Float](repeating: 0, count: dim)
        hidden.dataPointer.withMemoryRebound(to: Float.self, capacity: dim) { ptr in
            for i in 0..<dim { vec[i] = ptr[i] }
        }
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        var scale = 1 / sqrtf(max(norm, 1e-9))
        vDSP_vsmul(vec, 1, &scale, &vec, 1, vDSP_Length(vec.count))
        return vec
    }
}
