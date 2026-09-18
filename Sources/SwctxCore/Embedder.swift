import Foundation
import NaturalLanguage
import Accelerate

/// On-device sentence embeddings. Wraps a registry of BERT-family CoreML
/// models (`EmbeddingModelSpec`) with a three-level model selection:
///   per-index meta binding > explicit --model flag > SWCTX_MODEL env > default.
/// Falls back to NaturalLanguage's built-in 512-d sentence embedding when the
/// selected model isn't installed — no network at inference time either way.
public final class Embedder: @unchecked Sendable {
    /// Process-wide shared instance: model init costs ~0.3s (CoreML load +
    /// vocab parse), so query paths reuse this instead of paying it per call.
    /// Unlike `Embedder()`, `shared` re-resolves the active model on every
    /// call — it follows the index binding set by the most recently opened
    /// Store (search paths open their Store before touching `shared`).
    public static let shared = Embedder(dynamic: true)

    // MARK: - Model registry

    public static let defaultModelID = "bge-base-en-v1.5"

    public static let bgeSpec = EmbeddingModelSpec(
        id: "bge-base-en-v1.5", dim: 768, dirName: "bge-base-en-v1.5",
        cased: false, pooling: .cls,
        displayName: "bge-base-en-v1.5 (English, BERT uncased, CLS pooling)")

    public static let distiluseSpec = EmbeddingModelSpec(
        id: "distiluse-base-multilingual-cased-v2", dim: 768,
        dirName: "distiluse-base-multilingual-cased-v2",
        cased: true, pooling: .mean,
        displayName: "distiluse-base-multilingual-cased-v2 (multilingual 50+ langs incl. Vietnamese, cased, mean pooling)")

    public static let models: [EmbeddingModelSpec] = [bgeSpec, distiluseSpec]

    public static func spec(for id: String?) -> EmbeddingModelSpec? {
        models.first { $0.id == id }
    }

    // MARK: - Model selection state

    private static let lock = NSLock()
    /// Explicit `--model` flag / `Embedder.selectModel` choice.
    /// (nonisolated(unsafe): all access is under `lock`.)
    nonisolated(unsafe) private static var explicitID: String?
    /// Binding of the most recently opened Store (nil = unbound/legacy index).
    nonisolated(unsafe) private static var boundID: String?
    /// Lazily-constructed backends, one per model id (nil cached on failure).
    nonisolated(unsafe) private static var backends: [String: BGEEmbedder?] = [:]
    nonisolated(unsafe) private static var envChecked = false
    nonisolated(unsafe) private static var envID: String?

    /// CLI `--model`/`SWCTX_MODEL`-style explicit selection for this process.
    /// Unknown ids are ignored (callers validate against `spec(for:)` first).
    public static func selectModel(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        explicitID = id
    }

    /// Called by `Store.init` with the index's meta `embedding_model`
    /// (nil for legacy/unbound indexes). Per-index binding outranks the
    /// explicit/env selection for subsequent embeds in this process.
    public static func bindModel(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        boundID = id
    }

    /// Effective model id: index binding > explicit > SWCTX_MODEL > default.
    public static var activeModelID: String {
        lock.lock(); defer { lock.unlock() }
        if !envChecked {
            envID = ProcessInfo.processInfo.environment["SWCTX_MODEL"]
            envChecked = true
        }
        return boundID ?? explicitID ?? envID ?? defaultModelID
    }

    /// What the caller asked for regardless of any open index's binding:
    /// explicit > SWCTX_MODEL > default. Used when stamping a NEW index's
    /// meta binding so a previously opened index's model doesn't leak into
    /// an unrelated fresh DB in the same process.
    public static var requestedModelID: String {
        lock.lock(); defer { lock.unlock() }
        if !envChecked {
            envID = ProcessInfo.processInfo.environment["SWCTX_MODEL"]
            envChecked = true
        }
        return explicitID ?? envID ?? defaultModelID
    }

    /// Shared-cache backend lookup — used by `Embedder.shared` so query paths
    /// don't pay model load per call. Per-instance Embedders use
    /// `makeBackend` instead (fresh MLModel — see init).
    private static func backend(for id: String) -> BGEEmbedder? {
        lock.lock(); defer { lock.unlock() }
        if let cached = backends[id] { return cached }
        let b = makeBackend(for: id)
        backends[id] = b
        return b
    }

    /// Construct a backend without touching the cache — callers that need a
    /// genuinely new MLModel (Indexer's CoreML-failure retry does
    /// `embedder = Embedder()` to recover) get one.
    private static func makeBackend(for id: String) -> BGEEmbedder? {
        guard let spec = spec(for: id), spec.isInstalled else { return nil }
        return try? BGEEmbedder(spec: spec)
    }

    // MARK: - Instance

    /// nil → resolve `activeModelID` per call (only `shared` uses this).
    private let fixedModelID: String?
    /// Per-instance backend (non-dynamic only): a real fresh model so that
    /// recreating `Embedder()` recovers from transient CoreML failures —
    /// the static cache would hand the same broken MLModel back.
    private let ownBackend: BGEEmbedder?
    /// NLEmbedding fallback — used only when the selected CoreML model isn't
    /// installed. Always constructed (cheap handle) to keep `isAvailable`
    /// and the legacy no-model path unchanged.
    private let nl: NLEmbedding?

    /// Per-instance embedder bound to the model active at construction
    /// (or an explicit `modelID`). Indexer holds one of these so a whole
    /// embed pass stays on one vector space.
    public init(modelID: String? = nil, language: NLLanguage = .english) {
        let id = modelID ?? Embedder.activeModelID
        fixedModelID = id
        ownBackend = Embedder.makeBackend(for: id)
        nl = NLEmbedding.sentenceEmbedding(for: language)
    }

    private init(dynamic: Bool) {
        fixedModelID = nil
        ownBackend = nil
        nl = NLEmbedding.sentenceEmbedding(for: .english)
    }

    private var backend: BGEEmbedder? {
        fixedModelID == nil
            ? Embedder.backend(for: Embedder.activeModelID)
            : ownBackend
    }

    public var isAvailable: Bool { backend != nil || nl != nil }
    public var dimension: Int { backend?.dimension ?? nl?.dimension ?? 0 }
    public var modelName: String? {
        if let b = backend { return b.modelName }
        return nl != nil ? "NLEmbedding.sentence" : nil
    }

    /// L2-normalized embedding — dot product of two outputs equals cosine.
    public func embed(_ text: String) -> [Float]? {
        if let b = backend { return b.embed(text) }
        guard let vec = nl?.vector(for: text), !vec.isEmpty else { return nil }
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
