import Foundation
import NaturalLanguage
import Accelerate

/// On-device sentence embeddings. Prefers the bge-base-en-v1.5 CoreML model
/// when installed (`swctx model install`); falls back to NaturalLanguage's
/// built-in 512-d sentence embedding — no network at inference time either way.
public final class Embedder: @unchecked Sendable {
    /// Process-wide shared instance: BGE init costs ~0.3s (CoreML model load +
    /// vocab parse), so query paths reuse this instead of paying it per call.
    /// Indexer keeps its own instance — its CoreML-failure retry path
    /// recreates it. MLModel prediction is thread-safe.
    public static let shared = Embedder()

    private let bge: BGEEmbedder?
    private let embedding: NLEmbedding?

    public init(language: NLLanguage = .english) {
        if BGEEmbedder.isInstalled, let b = try? BGEEmbedder() {
            bge = b
            embedding = nil
        } else {
            bge = nil
            embedding = NLEmbedding.sentenceEmbedding(for: language)
        }
    }

    public var isAvailable: Bool { bge != nil || embedding != nil }
    public var dimension: Int { bge?.dimension ?? embedding?.dimension ?? 0 }
    public var modelName: String? {
        if bge != nil { return "bge-base-en-v1.5-coreml" }
        return embedding != nil ? "NLEmbedding.sentence" : nil
    }

    /// L2-normalized embedding — dot product of two outputs equals cosine.
    public func embed(_ text: String) -> [Float]? {
        if let bge { return bge.embed(text) }
        guard let vec = embedding?.vector(for: text), !vec.isEmpty else { return nil }
        var f = vec.map { Float($0) }
        var norm: Float = 0
        vDSP_svesq(f, 1, &norm, vDSP_Length(f.count))
        let scale = 1 / sqrtf(max(norm, 1e-9))
        var scaleVar = scale
        vDSP_vsmul(f, 1, &scaleVar, &f, 1, vDSP_Length(f.count))
        return f
    }

    public static func blob(_ vec: [Float]) -> Data {
        vec.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func vector(from blob: Data, dim: Int) -> [Float] {
        blob.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: Float.self).prefix(dim))
        }
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}
