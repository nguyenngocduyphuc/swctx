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

    /// bge-m3 (XLM-R 24L, SentencePiece, CLS) — adopted after the offline
    /// eval (bench/bgem3_offline_eval.md) rescued 4/5 dead-semantic-leg
    /// misses on the vn probe where distiluse scored 1/22.
    public static let bgem3Spec = EmbeddingModelSpec(
        id: "bge-m3", dim: 1024, dirName: "bge-m3",
        cased: true, pooling: .cls, tokenizer: .sentencepiece,
        displayName: "bge-m3 (XLM-R multilingual, SentencePiece, CLS pooling)")

    public static let models: [EmbeddingModelSpec] = [bgeSpec, distiluseSpec, bgem3Spec]

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
    /// Per-model Embedder instances for `Embedder.instance(forModelID:)`.
    nonisolated(unsafe) private static var instances: [String: Embedder] = [:]
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

    /// Process-wide instance pinned to one explicit model id — unlike
    /// `shared`, it never follows `bindModel`, so two Stores bound to
    /// different models in one MCP process each keep their own vector
    /// space. Backends still come from the shared cache (no per-instance
    /// MLModel reload). `Store.embedder` is built on this.
    public static func instance(forModelID id: String?) -> Embedder {
        lock.lock(); defer { lock.unlock() }
        let key = spec(for: id)?.id ?? defaultModelID
        if let e = instances[key] { return e }
        let e = Embedder(fixedShared: key)
        instances[key] = e
        return e
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

    /// Fixed-model instance whose backend comes from the shared cache —
    /// `instance(forModelID:)` only.
    private init(fixedShared id: String) {
        fixedModelID = id
        ownBackend = nil
        nl = NLEmbedding.sentenceEmbedding(for: .english)
    }

    private var backend: BGEEmbedder? {
        if let b = ownBackend { return b }
        return Embedder.backend(for: fixedModelID ?? Embedder.activeModelID)
    }

    /// The model id this instance embeds with — fixed/shared binding for
    /// store-pinned instances, process `activeModelID` for `shared`.
    /// Internal: exposed for tests asserting per-store model isolation.
    var resolvedModelID: String { fixedModelID ?? Embedder.activeModelID }

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
        // copyBytes into the array's own storage: `bindMemory` requires
        // 4-byte alignment that a Data buffer (e.g. a subdata slice
        // sharing a parent allocation at an offset) does not guarantee.
        var vec = [Float](repeating: 0, count: dim)
        vec.withUnsafeMutableBytes { dst in
            blob.copyBytes(to: dst, from: 0..<min(blob.count, dim * 4))
        }
        return vec
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}
