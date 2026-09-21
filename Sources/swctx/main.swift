import ArgumentParser
import Darwin
import Foundation
import GRDB
import MCP
import SwctxCore

typealias MCPValue = MCP.Value

@main
struct Swctx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swctx",
        abstract: "Local semantic code index + MCP server (Swift reimplementation of the ctxe model).",
        version: "0.1.0",
        subcommands: [IndexCmd.self, StatusCmd.self, PrimeCmd.self, SearchCmd.self, RerankCmd.self, Rerank2Cmd.self, Rerank3Cmd.self, TreeCmd.self, EmbedCmd.self, DiscoverCmd.self, WatchCmd.self, WatchAllCmd.self, AskCmd.self, AnswerCmd.self, SimulateCmd.self, ModelCmd.self, McpCmd.self, McpConfigCmd.self, InstallAgentCmd.self, GcCmd.self, StatsCmd.self],
        defaultSubcommand: nil)
}

struct IndexCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index",
        abstract: "Index a workspace directory incrementally.")
    @Argument(help: "Workspace path (default: current directory)") var path: String = "."
    @Flag(name: .long, help: "Full re-index, ignoring cached hashes") var force = false
    @Flag(name: .long, help: "Report what would change without writing") var dryRun = false
    @Flag(name: .long, help: "Skip the post-index embedding pass (pending chunks stay for `swctx embed`)") var skipEmbed = false
    @Flag(name: .long, help: "Enable the trigram substring index for this workspace (adds ~40-45% index size)") var trigram = false
    @Option(name: .long, help: "Embedding model id (see `swctx model list`); default: index binding, else SWCTX_MODEL, else bge-base-en-v1.5") var model: String?
    @Option(name: .long, help: "Output format: human | json") var format: String = "human"

    func run() async throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        if let model {
            guard Embedder.spec(for: model) != nil else {
                throw ValidationError("unknown embedding model '\(model)' (see `swctx model list`)")
            }
            Embedder.selectModel(model)
        }
        let store = try Store(workspaceRoot: root)
        if dryRun {
            let report = try Indexer(store: store).dryRun()
            if format == "json" {
                print(String(data: try JSONEncoder().encode(report), encoding: .utf8)!)
            } else {
                print("Would index \(report.filesTotal) files: \(report.filesNew) new, \(report.filesChanged) changed, \(report.filesUnchanged) unchanged, \(report.filesDeleted) deleted")
            }
            return
        }
        // The index's recorded binding wins over flag/env — mixing vector
        // spaces inside one index silently zeroes the semantic leg.
        if let bound = store.embeddingModel, let model, bound != model {
            throw ValidationError(
                "index is bound to embedding model '\(bound)'; "
                    + "run `swctx embed --reindex --model \(model) \(root.path)` to re-embed under '\(model)'")
        }
        let modelID = store.embeddingModel ?? Embedder.activeModelID
        guard let spec = Embedder.spec(for: modelID) else {
            throw ValidationError("unknown embedding model '\(modelID)' (see `swctx model list`)")
        }
        if store.embeddingModel == nil {
            // First index of this workspace: record the binding in meta.
            try store.setEmbeddingBinding(modelID: spec.id, dim: spec.dim)
        }
        if trigram, !store.trigramEnabled {
            try store.setTrigramEnabled(true)
        }
        let indexer = Indexer(store: store, embedder: Embedder(modelID: spec.id))
        FileHandle.standardError.write("swctx: indexing \(root.path)\n".data(using: .utf8)!)
        let report = try indexer.run(force: force, autoEmbed: !skipEmbed) { msg in
            FileHandle.standardError.write("swctx: \(msg)\n".data(using: .utf8)!)
        }
        if format == "json" {
            let data = try JSONEncoder().encode(report)
            print(String(data: data, encoding: .utf8)!)
        } else {
            print("Indexed \(report.filesIndexed) files (\(report.filesUnchanged) unchanged, \(report.filesDeleted) deleted)")
            print("  chunks=\(report.chunks) symbols=\(report.symbols) edges=\(report.edges) resolved=\(report.edgesResolved) vectors=\(report.embeddedChunks) preserved=\(report.vectorsPreserved)")
            if report.pendingEmbeddings > 0 {
                print("  pending embeddings: \(report.pendingEmbeddings) — run `swctx embed` to fill")
            }
            print("  \(report.durationMs)ms")
            if !report.errors.isEmpty {
                print("  errors: \(report.errors.count) (first: \(report.errors.first ?? ""))")
            }
        }
    }
}

struct GcCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gc",
        abstract: "Collect orphaned indexes under ~/.swctx/indexes (dry-run unless --yes).")
    @Flag(name: .long, help: "Actually delete (default: dry-run report)") var yes = false
    @Option(name: .long, help: "Safety window in hours — skip entries touched more recently") var minAgeHours: Double = 1
    @Option(name: .long, help: "Output format: human | json") var format: String = "human"

    func run() throws {
        let report = Gc.run(yes: yes, minAgeSeconds: minAgeHours * 3600)
        if format == "json" {
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            return
        }
        let orphans = report["orphans"] as? [[String: Any]] ?? []
        for o in orphans.prefix(15) {
            print("  \(o["key"] ?? "")  \(o["chunks"] ?? 0) chunks  \(o["bytes"] ?? 0)B  \(o["workspace"] ?? "")")
        }
        if orphans.count > 15 { print("  … and \(orphans.count - 15) more") }
        let mb = (report["collectable_bytes"] as? Int ?? 0) / 1_000_000
        print("\(report["orphaned"] ?? 0) orphaned of \(report["total_indexes"] ?? 0) indexes "
            + "(\(report["recent_skipped"] ?? 0) skipped: recent), "
            + "registry dead: \(report["registry_dead"] ?? 0), "
            + (yes ? "deleted \(report["deleted"] ?? 0), freed \(mb)MB"
                   : "collectable \(mb)MB — re-run with --yes to delete"))
    }
}

struct StatsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats",
        abstract: "Usage telemetry from the fleet ledger (~/.swctx/records.db): per-tool calls, latency percentiles, zero-hit search queries.")
    @Option(name: .long, help: "Output format: human | json") var format: String = "human"
    @Option(name: .long, help: "Max zero-hit queries to list") var limit: Int = 20

    func run() throws {
        guard let g = GlobalRecords.shared else {
            throw ValidationError("global ledger unavailable: ~/.swctx is not writable")
        }
        let stats = try g.usageStats()
        let zeroHit = try g.zeroHitQueries(limit: limit)
        if format == "json" {
            let obj: [String: Any] = [
                "tools": stats.map {
                    ["tool": $0.tool, "calls": $0.calls, "errors": $0.errors,
                     "avg_ms": $0.avgMs, "p50_ms": $0.p50Ms,
                     "p95_ms": $0.p95Ms] as [String: Any]
                },
                "zero_hit_queries": zeroHit.map {
                    ["query": $0.query, "count": $0.count]
                },
            ]
            let data = try JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if stats.isEmpty {
            print("no usage events recorded yet")
            return
        }
        print("\(stats.reduce(0) { $0 + $1.calls }) calls, "
            + "\(stats.reduce(0) { $0 + $1.errors }) errors")
        for s in stats {
            print("  \(s.tool): \(s.calls) calls, \(s.errors) errors, "
                + "avg \(Int(s.avgMs))ms, p50 \(s.p50Ms)ms, p95 \(s.p95Ms)ms")
        }
        if !zeroHit.isEmpty {
            print("zero-hit search queries:")
            for z in zeroHit {
                print("  \(z.count)x \(z.query)")
            }
        }
    }
}

struct StatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "Show index health and counts.")
    @Argument(help: "Workspace path") var path: String = "."

    func run() async throws {
        let out = try await SwctxTools.call(name: "get_status",
            arguments: ["workspace": .string(URL(fileURLWithPath: path).standardizedFileURL.path)])
        print(out)
    }
}

struct PrimeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prime",
        abstract: "Print a compact Markdown context card for an indexed workspace.",
        aliases: ["brief"])
    @Argument(help: "Workspace path") var path: String = "."
    @Option(name: .long, help: "Output format: md | json") var format: String = "md"

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            FileHandle.standardError.write(
                "swctx: not a directory: \(root.path)\n".data(using: .utf8)!)
            throw ExitCode(2)
        }
        // Store's initializer creates the DB, so the existence check must
        // come first — unindexed workspace is the only hard error here.
        guard FileManager.default.fileExists(
            atPath: Store.indexURL(forKey: Store.key(for: root)).path) else {
            FileHandle.standardError.write(
                "swctx: workspace not indexed: \(root.path) — run `swctx index` first\n"
                    .data(using: .utf8)!)
            throw ExitCode(2)
        }
        let store = try Store(workspaceRoot: root)
        if format == "json" {
            let obj = try Prime.snapshot(store: store, root: store.workspaceRoot)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(try Prime.card(store: store, root: store.workspaceRoot))
        }
    }
}

struct SearchCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search",
        abstract: "Hybrid search over indexed chunks.")
    @Argument(help: "Workspace path") var path: String
    @Argument(help: "Query") var query: String
    @Option(name: .long) var mode: String = "auto"
    @Option(name: .long) var limit: Int = 10

    func run() async throws {
        let out = try await SwctxTools.call(name: "search", arguments: [
            "workspace": .string(URL(fileURLWithPath: path).standardizedFileURL.path),
            "query": .string(query),
            "mode": .string(mode),
            "limit": .int(limit),
        ])
        print(out)
    }
}

/// `swctx rerank` — reranker spike CLI: hybrid candidate pool → cross-
/// encoder rescore. Mirrors `search --mode auto`'s leg selection
/// (identifier-shaped queries skip the vector leg, with the same empty-
/// pool fallback) so the comparison is the rerank stage itself.
struct RerankCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rerank",
        abstract: "Hybrid search, then cross-encoder rerank of the candidate pool (spike).")
    @Argument(help: "Workspace path") var path: String
    @Argument(help: "Query") var query: String
    @Option(name: .long, help: "Candidate pool size to rerank (default 30)") var limit: Int = 30
    @Option(name: .long, help: "Rerank batch size") var batch: Int = 16

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(
            atPath: Store.indexURL(forKey: Store.key(for: root)).path) else {
            FileHandle.standardError.write(
                "swctx: workspace not indexed: \(root.path) — run `swctx index` first\n"
                    .data(using: .utf8)!)
            throw ExitCode(2)
        }
        guard Reranker.isInstalled else {
            throw ValidationError(
                "reranker model not installed at \(Reranker.modelDir.path) "
                    + "(convert via bench/convert_reranker.py)")
        }
        let store = try Store(workspaceRoot: root)
        let identifier = Search.identifierLike(query)
        // Pool legs must match the production search path (limit*3 = 15
        // per leg for a 5-hit page) — passing the 30-pool size as `limit`
        // would deepen each leg to 90 and fuse a different ordering than
        // the one `search` produces (the limit*12 rejection pattern).
        var hits = try Search.hybridCandidates(
            store: store, embedder: store.embedder, query: query,
            limit: 5, poolLimit: limit,
            pathFilter: nil, includeVector: !identifier)
        if identifier && hits.isEmpty {
            hits = try Search.hybridCandidates(
                store: store, embedder: store.embedder, query: query,
                limit: 5, poolLimit: limit)
        }
        guard !hits.isEmpty else {
            print("{\"query\":\(jsonStr(query)),\"pool\":0,\"hits\":[]}")
            return
        }
        // Chunk text for the doc side — content is stored on chunks.
        let chunkIDs = hits.map { $0.chunkID }
        let contents = try await store.pool.read { db -> [Int64: String] in
            let ph = chunkIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, content FROM chunks WHERE id IN (\(ph))",
                arguments: StatementArguments(chunkIDs))
            var out: [Int64: String] = [:]
            for r in rows {
                if let id = r["id"] as? Int64 { out[id] = (r["content"] as? String) ?? "" }
            }
            return out
        }
        let docs = hits.map {
            Reranker.docWindows(path: $0.path, symbol: $0.symbol,
                                content: contents[$0.chunkID] ?? "")
        }
        let reranker = try Reranker()
        reranker.warm()
        let t0 = Date()
        let scores = reranker.scoreAllMax(query: query, windows: docs, batchSize: batch)
        let rerankMs = Date().timeIntervalSince(t0) * 1000
        let ranked = zip(hits.indices, scores)
            .map { (i: $0.0, score: $0.1 ?? -.infinity) }
            .sorted { $0.score > $1.score }
        var items: [[String: Any]] = []
        for (rank, r) in ranked.enumerated() {
            let h = hits[r.i]
            var d: [String: Any] = [
                "rank": rank + 1, "hybrid_rank": r.i + 1,
                "chunk_id": h.chunkID, "path": h.path,
                "start_line": h.startLine, "end_line": h.endLine,
            ]
            if let s = scores[r.i] { d["score"] = Double(s) }
            if let s = h.symbol { d["symbol"] = s }
            if let k = h.kind { d["kind"] = k }
            items.append(d)
        }
        let payload: [String: Any] = [
            "query": query, "mode": identifier ? "identifier" : "hybrid",
            "pool": hits.count, "rerank_ms": rerankMs,
            "ms_per_pair": rerankMs / Double(max(1, hits.count)),
            "hits": items,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private func jsonStr(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s) else {
            return "\"\""
        }
        return String(decoding: d, as: UTF8.self)
    }
}

/// `swctx rerank2` — reranker-v2 spike CLI: same candidate pool and
/// output shape as `rerank`, rescored by bge-reranker-v2-m3 (XLM-R
/// cross-encoder) instead of the amberoad mBERT model.
struct Rerank2Cmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rerank2",
        abstract: "Hybrid search, then bge-reranker-v2-m3 rerank of the candidate pool (spike).")
    @Argument(help: "Workspace path") var path: String
    @Argument(help: "Query") var query: String
    @Option(name: .long, help: "Candidate pool size to rerank (default 30)") var limit: Int = 30
    @Option(name: .long, help: "Rerank batch size") var batch: Int = 16

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(
            atPath: Store.indexURL(forKey: Store.key(for: root)).path) else {
            FileHandle.standardError.write(
                "swctx: workspace not indexed: \(root.path) — run `swctx index` first\n"
                    .data(using: .utf8)!)
            throw ExitCode(2)
        }
        guard RerankerV2.isInstalled else {
            throw ValidationError(
                "reranker-v2 model not installed at \(RerankerV2.modelDir.path) "
                    + "(convert via bench/convert_reranker_v2m3.py)")
        }
        let store = try Store(workspaceRoot: root)
        let identifier = Search.identifierLike(query)
        var hits = try Search.hybridCandidates(
            store: store, embedder: store.embedder, query: query,
            limit: 5, poolLimit: limit,
            pathFilter: nil, includeVector: !identifier)
        if identifier && hits.isEmpty {
            hits = try Search.hybridCandidates(
                store: store, embedder: store.embedder, query: query,
                limit: 5, poolLimit: limit)
        }
        guard !hits.isEmpty else {
            print("{\"query\":\(jsonStr(query)),\"pool\":0,\"hits\":[]}")
            return
        }
        let chunkIDs = hits.map { $0.chunkID }
        let contents = try await store.pool.read { db -> [Int64: String] in
            let ph = chunkIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, content FROM chunks WHERE id IN (\(ph))",
                arguments: StatementArguments(chunkIDs))
            var out: [Int64: String] = [:]
            for r in rows {
                if let id = r["id"] as? Int64 { out[id] = (r["content"] as? String) ?? "" }
            }
            return out
        }
        let docs = hits.map {
            RerankerV2.docWindows(path: $0.path, symbol: $0.symbol,
                                  content: contents[$0.chunkID] ?? "")
        }
        let reranker = try RerankerV2()
        reranker.warm()
        let t0 = Date()
        let scores = reranker.scoreAllMax(query: query, windows: docs, batchSize: batch)
        let rerankMs = Date().timeIntervalSince(t0) * 1000
        let ranked = zip(hits.indices, scores)
            .map { (i: $0.0, score: $0.1 ?? -.infinity) }
            .sorted { $0.score > $1.score }
        var items: [[String: Any]] = []
        for (rank, r) in ranked.enumerated() {
            let h = hits[r.i]
            var d: [String: Any] = [
                "rank": rank + 1, "hybrid_rank": r.i + 1,
                "chunk_id": h.chunkID, "path": h.path,
                "start_line": h.startLine, "end_line": h.endLine,
            ]
            if let s = scores[r.i] { d["score"] = Double(s) }
            if let s = h.symbol { d["symbol"] = s }
            if let k = h.kind { d["kind"] = k }
            items.append(d)
        }
        let payload: [String: Any] = [
            "query": query, "mode": identifier ? "identifier" : "hybrid",
            "pool": hits.count, "rerank_ms": rerankMs,
            "ms_per_pair": rerankMs / Double(max(1, hits.count)),
            "hits": items,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private func jsonStr(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s) else {
            return "\"\""
        }
        return String(decoding: d, as: UTF8.self)
    }
}

/// `swctx rerank3` — reranker-v3 spike CLI: same candidate pool and
/// output shape as `rerank`/`rerank2`, rescored by
/// jina-reranker-v2-base-multilingual (XLM-R base cross-encoder)
/// instead of the amberoad mBERT / bge-reranker-v2-m3 models.
struct Rerank3Cmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rerank3",
        abstract: "Hybrid search, then jina-reranker-v2-base-multilingual rerank of the candidate pool (spike).")
    @Argument(help: "Workspace path") var path: String
    @Argument(help: "Query") var query: String
    @Option(name: .long, help: "Candidate pool size to rerank (default 30)") var limit: Int = 30
    @Option(name: .long, help: "Rerank batch size") var batch: Int = 16

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(
            atPath: Store.indexURL(forKey: Store.key(for: root)).path) else {
            FileHandle.standardError.write(
                "swctx: workspace not indexed: \(root.path) — run `swctx index` first\n"
                    .data(using: .utf8)!)
            throw ExitCode(2)
        }
        guard RerankerV3.isInstalled else {
            throw ValidationError(
                "reranker-v3 model not installed at \(RerankerV3.modelDir.path) "
                    + "(convert via bench/convert_reranker_v3.py)")
        }
        let store = try Store(workspaceRoot: root)
        let identifier = Search.identifierLike(query)
        var hits = try Search.hybridCandidates(
            store: store, embedder: store.embedder, query: query,
            limit: 5, poolLimit: limit,
            pathFilter: nil, includeVector: !identifier)
        if identifier && hits.isEmpty {
            hits = try Search.hybridCandidates(
                store: store, embedder: store.embedder, query: query,
                limit: 5, poolLimit: limit)
        }
        guard !hits.isEmpty else {
            print("{\"query\":\(jsonStr(query)),\"pool\":0,\"hits\":[]}")
            return
        }
        let chunkIDs = hits.map { $0.chunkID }
        let contents = try await store.pool.read { db -> [Int64: String] in
            let ph = chunkIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, content FROM chunks WHERE id IN (\(ph))",
                arguments: StatementArguments(chunkIDs))
            var out: [Int64: String] = [:]
            for r in rows {
                if let id = r["id"] as? Int64 { out[id] = (r["content"] as? String) ?? "" }
            }
            return out
        }
        let docs = hits.map {
            RerankerV3.docWindows(path: $0.path, symbol: $0.symbol,
                                  content: contents[$0.chunkID] ?? "")
        }
        let reranker = try RerankerV3()
        reranker.warm()
        let t0 = Date()
        let scores = reranker.scoreAllMax(query: query, windows: docs, batchSize: batch)
        let rerankMs = Date().timeIntervalSince(t0) * 1000
        let ranked = zip(hits.indices, scores)
            .map { (i: $0.0, score: $0.1 ?? -.infinity) }
            .sorted { $0.score > $1.score }
        var items: [[String: Any]] = []
        for (rank, r) in ranked.enumerated() {
            let h = hits[r.i]
            var d: [String: Any] = [
                "rank": rank + 1, "hybrid_rank": r.i + 1,
                "chunk_id": h.chunkID, "path": h.path,
                "start_line": h.startLine, "end_line": h.endLine,
            ]
            if let s = scores[r.i] { d["score"] = Double(s) }
            if let s = h.symbol { d["symbol"] = s }
            if let k = h.kind { d["kind"] = k }
            items.append(d)
        }
        let payload: [String: Any] = [
            "query": query, "mode": identifier ? "identifier" : "hybrid",
            "pool": hits.count, "rerank_ms": rerankMs,
            "ms_per_pair": rerankMs / Double(max(1, hits.count)),
            "hits": items,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private func jsonStr(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s) else {
            return "\"\""
        }
        return String(decoding: d, as: UTF8.self)
    }
}

struct TreeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tree",
        abstract: "List indexed files.")
    @Argument(help: "Workspace path") var path: String
    @Option(name: .long) var root: String = ""

    func run() async throws {
        var args: [String: MCPValue] = [
            "workspace": .string(URL(fileURLWithPath: path).standardizedFileURL.path)
        ]
        if !root.isEmpty { args["root"] = .string(root) }
        let out = try await SwctxTools.call(name: "get_workspace_tree", arguments: args)
        print(out)
    }
}

struct EmbedCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "embed",
        abstract: "Fill pending on-device embeddings for an indexed workspace (index auto-embeds; this covers `index --skip-embed` and partial runs).")
    @Argument(help: "Workspace path") var path: String = "."
    @Flag(name: .long, help: "Drop all stored vectors and re-embed every chunk") var reindex = false
    @Option(name: .long, help: "Embedding model id (see `swctx model list`); default: index binding, else SWCTX_MODEL, else bge-base-en-v1.5") var model: String?

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if let model {
            guard Embedder.spec(for: model) != nil else {
                throw ValidationError("unknown embedding model '\(model)' (see `swctx model list`)")
            }
            Embedder.selectModel(model)
        }
        let store = try Store(workspaceRoot: root)
        // Requested model wins when rebinding; otherwise the index's
        // recorded binding wins over flag/env — mixing vector spaces
        // inside one index silently zeroes the semantic leg.
        let modelID = model ?? store.embeddingModel ?? Embedder.activeModelID
        guard let spec = Embedder.spec(for: modelID) else {
            throw ValidationError("unknown embedding model '\(modelID)' (see `swctx model list`)")
        }
        if let bound = store.embeddingModel, let model, bound != model, !reindex {
            throw ValidationError(
                "index is bound to embedding model '\(bound)'; "
                    + "add --reindex to wipe and re-embed under '\(model)'")
        }
        if store.embeddingModel != spec.id {
            try store.setEmbeddingBinding(modelID: spec.id, dim: spec.dim)
        }
        let indexer = Indexer(store: store, embedder: Embedder(modelID: spec.id))
        let pending = reindex
            ? (try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chunks") ?? 0 })
            : try indexer.pendingEmbeddings()
        FileHandle.standardError.write("swctx: \(pending) chunks to embed\n".data(using: .utf8)!)
        guard pending > 0 else { print("{\"embedded\":0,\"pending\":0}"); return }
        let total = try indexer.embedAll(reindex: reindex) { done in
            FileHandle.standardError.write("swctx: embedded \(done)\n".data(using: .utf8)!)
        }
        print("{\"embedded\":\(total),\"pending\":\(try indexer.pendingEmbeddings())}")
    }
}

struct DiscoverCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "discover",
        abstract: "Debug: list what file discovery would index, grouped by top-level dir.")
    @Argument(help: "Workspace path") var path: String = "."

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let store = try Store(workspaceRoot: root)
        let files = Indexer(store: store).discoverFiles()
        var hist: [String: Int] = [:]
        for f in files { hist[f.split(separator: "/").first.map(String.init) ?? f, default: 0] += 1 }
        print("total: \(files.count)")
        for (k, v) in hist.sorted(by: { $0.value > $1.value }) { print("  \(v)\t\(k)") }
    }
}

/// `swctx watch` is dual-purpose. With a workspace path it foregrounds
/// one IndexWatcher exactly as it always has (scripts and muscle memory
/// rely on it). With a lifecycle verb it manages the shared
/// `com.swctx.watchd` daemon that runs `swctx watch-all` — the single
/// LaunchAgent replacing the per-workspace com.swctx.watch.* plists:
///   install    write ~/Library/LaunchAgents/com.swctx.watchd.plist and
///              `launchctl bootstrap` it (one login item, one notification)
///   uninstall  bootout + remove the plist
///   restart    `launchctl kickstart -k` — apply watchd.json edits
///   status     plist presence, launchd state, configured workspaces
///   add/remove <path>   edit ~/.swctx/watchd.json (dedupe, resolve symlinks)
struct WatchCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch",
        abstract: "Watch a workspace via FSEvents and keep its index fresh (foreground). Lifecycle verbs manage the shared com.swctx.watchd daemon instead: `swctx watch install|uninstall|restart|status` or `swctx watch add|remove <path>`. Any other argument is a workspace path.")
    @Argument(help: "Workspace path — or a lifecycle verb: install | uninstall | restart | status | add | remove")
    var path: String = "."
    @Argument(help: "Workspace path for the `add`/`remove` verbs") var target: String?
    @Flag(name: .long, help: "Run a single incremental index pass and exit (no watching)") var once = false

    func run() async throws {
        switch path {
        case "add":
            guard let target else {
                throw ValidationError("`swctx watch add` needs a workspace path")
            }
            let r = try Watchd.addWorkspace(target)
            print(r.added
                ? "watching \(Watchd.normalize(target).path) "
                    + "(\(r.workspaces.count) total — `swctx watch restart` to apply)"
                : "already watched: \(Watchd.normalize(target).path)")
        case "remove":
            guard let target else {
                throw ValidationError("`swctx watch remove` needs a workspace path")
            }
            let r = try Watchd.removeWorkspace(target)
            print(r.removed
                ? "removed \(Watchd.normalize(target).path) "
                    + "(\(r.workspaces.count) left — `swctx watch restart` to apply)"
                : "not in \(Watchd.listURL.path): \(Watchd.normalize(target).path)")
        case "install", "uninstall", "restart", "status":
            guard target == nil else {
                throw ValidationError("`swctx watch \(path)` takes no path argument")
            }
            let lines: [String]
            switch path {
            case "install":
                let bin = resolveExecutableOnPATH(CommandLine.arguments[0])
                lines = try Watchd.install(binaryPath: bin)
            case "uninstall": lines = Watchd.uninstall()
            case "restart":   lines = try Watchd.restart()
            default:          lines = Watchd.status()
            }
            for line in lines { print(line) }
        default:
            guard target == nil else {
                throw ValidationError("unexpected extra argument '\(target!)'")
            }
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let store = try Store(workspaceRoot: root)
            let watcher = IndexWatcher(store: store)
            if once {
                try watcher.indexOnce()
                return
            }
            try await watcher.start()
        }
    }
}

/// `swctx watch-all` — the process `com.swctx.watchd` actually runs.
/// Reads the workspace list at ~/.swctx/watchd.json and holds one
/// IndexWatcher per entry, each on its own Swift task. A watcher whose
/// start throws is logged and dropped — one bad workspace must not kill
/// the fleet — while a watcher's schema-drift abort() still takes the
/// whole process down so launchd respawns watchd into the new binary.
struct WatchAllCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch-all",
        abstract: "Watch every workspace in ~/.swctx/watchd.json from one process (run by the com.swctx.watchd LaunchAgent — see `swctx watch install`).")

    func run() async throws {
        let workspaces = try Watchd.loadWorkspaces()
        guard !workspaces.isEmpty else {
            FileHandle.standardError.write(
                ("swctx: watch-all: no workspaces in \(Watchd.listURL.path) — "
                    + "add one with `swctx watch add <path>` and install the "
                    + "daemon with `swctx watch install`\n").data(using: .utf8)!)
            throw ExitCode(2)
        }
        var watchers: [(path: String, watcher: IndexWatcher)] = []
        for path in workspaces {
            do {
                let store = try Store(workspaceRoot: URL(fileURLWithPath: path))
                watchers.append((path, IndexWatcher(store: store)))
            } catch {
                FileHandle.standardError.write(
                    "swctx: watch-all: skipping \(path): \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
        }
        guard !watchers.isEmpty else {
            FileHandle.standardError.write(
                "swctx: watch-all: every listed workspace failed to open\n"
                    .data(using: .utf8)!)
            throw ExitCode(1)
        }
        FileHandle.standardError.write(
            ("swctx: watch-all: \(watchers.count) workspace(s) active: "
                + "\(watchers.map { $0.path }.joined(separator: ", "))\n")
                .data(using: .utf8)!)
        // IndexWatcher.start() never returns once streaming, so the group
        // ends only when every watcher has died. Exit non-zero in that
        // case: the daemon is useless with zero live watchers.
        await withTaskGroup(of: Void.self) { group in
            for (path, watcher) in watchers {
                group.addTask {
                    do {
                        try await watcher.start()
                        FileHandle.standardError.write(
                            "swctx: watch-all: watcher for \(path) exited\n"
                                .data(using: .utf8)!)
                    } catch {
                        FileHandle.standardError.write(
                            ("swctx: watch-all: watcher for \(path) failed: "
                                + "\(error.localizedDescription)\n").data(using: .utf8)!)
                    }
                }
            }
            await group.waitForAll()
        }
        FileHandle.standardError.write(
            "swctx: watch-all: all watchers ended — exiting\n".data(using: .utf8)!)
        throw ExitCode(1)
    }
}

struct ModelCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "model",
        abstract: "Manage on-device embedding models (BERT-family CoreML).",
        subcommands: [ModelListCmd.self, ModelInstallCmd.self],
        defaultSubcommand: ModelListCmd.self)
}

struct ModelListCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list",
        abstract: "List known embedding models and install status.")

    func run() throws {
        for spec in Embedder.models {
            let status = spec.isInstalled ? "installed" : "not installed"
            print("\(spec.id)\n    \(spec.dim)-d · \(status) · \(spec.displayName)\n    \(spec.modelDir.path)")
        }
        if let env = ProcessInfo.processInfo.environment["SWCTX_MODEL"], !env.isEmpty {
            print("SWCTX_MODEL=\(env)")
        }
    }
}

struct ModelInstallCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install",
        abstract: "Install an embedding model into ~/.swctx/models/.")
    @Argument(help: "Model id (see `swctx model list`)") var id: String = Embedder.defaultModelID
    @Option(name: .long, help: "Path to a locally converted model.mlpackage (for models without a prebuilt download)") var from: String?

    func run() async throws {
        guard let spec = Embedder.spec(for: id) else {
            throw ValidationError("unknown embedding model '\(id)' (see `swctx model list`)")
        }
        let dir = spec.modelDir
        if spec.isInstalled {
            print("installed: \(dir.path) (\(spec.id), \(spec.dim)-d)")
            return
        }
        switch spec.id {
        case Embedder.bgeSpec.id:
            // Prebuilt CoreML port (rsvalerio/bge-base-en-v1.5-coreml, MIT).
            try await downloadAll(base: "https://huggingface.co/rsvalerio/bge-base-en-v1.5-coreml/resolve/main",
                                  files: ["vocab.txt", "tokenizer_config.json",
                                          "model.mlpackage/Manifest.json",
                                          "model.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                                          "model.mlpackage/Data/com.apple.CoreML/weights/weight.bin"],
                                  into: dir)
        case Embedder.distiluseSpec.id:
            // Tokenizer files come from HF; the mlpackage must be supplied
            // locally (--from) — no public prebuilt conversion exists. See
            // bench/vn_model_spike.md for the coremltools conversion recipe.
            try await downloadAll(base: "https://huggingface.co/sentence-transformers/distiluse-base-multilingual-cased-v2/resolve/main",
                                  files: ["vocab.txt", "tokenizer_config.json"],
                                  into: dir)
            guard let from else {
                FileHandle.standardError.write("""
                    swctx: vocab.txt installed but no prebuilt model.mlpackage exists for \(spec.id).
                    Convert it with coremltools (ONNX → mlpackage), then either:
                      swctx model install \(spec.id) --from /path/to/model.mlpackage
                    or copy the package to \(dir.path)/model.mlpackage
                    """.data(using: .utf8)!)
                throw ExitCode(2)
            }
            let src = URL(fileURLWithPath: from)
            guard FileManager.default.fileExists(
                atPath: src.appendingPathComponent("Manifest.json").path) else {
                throw ValidationError("--from is not a .mlpackage directory: \(from)")
            }
            let dst = dir.appendingPathComponent("model.mlpackage")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        default:
            throw ValidationError("no installer for model '\(spec.id)'")
        }
        guard spec.isInstalled else {
            throw ValidationError("install incomplete: \(dir.path) missing model.mlpackage or vocab.txt")
        }
        print("installed: \(dir.path) (\(spec.id), \(spec.dim)-d)")
    }

    private func downloadAll(base: String, files: [String], into dir: URL) async throws {
        for f in files {
            let dst = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileHandle.standardError.write("swctx: downloading \(f)\n".data(using: .utf8)!)
            guard let url = URL(string: "\(base)/\(f)") else { continue }
            let (tmp, _) = try await URLSession.shared.download(from: url)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
    }
}

struct AskCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ask",
        abstract: "Answer a question from indexed evidence via a local agent CLI (no cloud, no credits).")
    @Argument(help: "Workspace path (default: current directory)") var path: String = "."
    @Argument(help: "Question to answer") var query: String
    @Option(name: .long, help: "Agent CLI: auto | claude | codex | gemini") var agent: String = "auto"
    @Option(name: .long, help: "Evidence chunk budget") var budget: Int = 12
    @Option(name: .long, help: "Agent timeout seconds") var timeout: Int = 300

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let store = try Store(workspaceRoot: root)
        let pack = try ContextPack.pack(store: store, query: query,
                                        budget: budget, expand: true, pathFilter: nil)
        let evidence = pack["evidence"] as? [[String: Any]] ?? []
        var ev = ""
        for e in evidence {
            let loc = "\(e["path"] ?? ""):\(e["start_line"] ?? 0)-\(e["end_line"] ?? 0)"
            let sym = e["symbol"] as? String ?? ""
            let why = e["why"] as? String ?? ""
            ev += "\n--- \(loc) \(sym) (\(why)) [chunk \(e["chunk_id"] ?? 0)]\n"
            if let c = e["content"] as? String { ev += c + "\n" }
        }
        let prompt = """
        Answer the question about the codebase at \(root.path) using the evidence \
        pack retrieved from its local semantic index. Cite every claim as \
        `path:line`; if the evidence is insufficient, say exactly what is missing \
        rather than guessing. If swctx tools are available you may call \
        fetch_chunks for more context. Answer in the language of the question.

        QUESTION: \(query)

        EVIDENCE PACK (\(evidence.count) chunks):
        \(ev)
        """
        let (bin, args) = try Self.resolveAgent(agent)
        FileHandle.standardError.write(
            "swctx: asking via \(bin) (\(evidence.count) evidence chunks)\n"
                .data(using: .utf8)!)
        let answer = try Self.spawn(bin, argv: args + [prompt], timeout: timeout)
        print(answer)
        _ = try? store.insertRecord(kind: "ask", source: "cli", title: query,
            payload: ["answer": answer, "agent": bin,
                      "evidence_chunks": evidence.count])
    }

    /// auto order: claude -> codex -> gemini; $SWCTX_ASK_AGENT overrides.
    static func resolveAgent(_ choice: String) throws -> (String, [String]) {
        let cliArgs: [String: [String]] = [
            "claude": ["-p"],
            "codex": ["exec"],
            "gemini": ["-p"],
        ]
        let env = ProcessInfo.processInfo.environment["SWCTX_ASK_AGENT"]
        let order: [String]
        switch choice {
        case "auto": order = env.map { [$0] } ?? ["claude", "codex", "gemini"]
        default: order = [choice]
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for name in order {
            guard let argv = cliArgs[name] else {
                throw ValidationError("unknown agent '\(name)' (claude|codex|gemini)")
            }
            for dir in pathDirs {
                let cand = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: cand) {
                    return (cand, argv)
                }
            }
        }
        throw ValidationError("no agent CLI found on PATH (tried: \(order.joined(separator: ", ")))")
    }

    /// Run `bin argv`, prompt as last argv element; timeout kills the
    /// child's whole process group. posix_spawn + POSIX_SPAWN_SETPGROUP is
    /// used instead of Process because a forking agent hides descendants
    /// from kill(pid) — kill(-pgid) reaches the entire tree, and the group
    /// is assigned at spawn time so there is no setpgid-after-exec race.
    /// Both pipes drain CONCURRENTLY with the wait: a child writing more
    /// than the ~64KB pipe buffer blocks in write() and never exits.
    static func spawn(_ bin: String, argv: [String], timeout: Int) throws -> String {
        let out = Pipe()
        let err = Pipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions,
            out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions,
            err.fileHandleForWriting.fileDescriptor, 2)
        for h in [out.fileHandleForReading, out.fileHandleForWriting,
                  err.fileHandleForReading, err.fileHandleForWriting] {
            posix_spawn_file_actions_addclose(&actions, h.fileDescriptor)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var sflags: Int16 = 0
        posix_spawnattr_getflags(&attr, &sflags)
        posix_spawnattr_setflags(&attr, sflags | Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)   // own group: pgid == child pid

        var pid: pid_t = 0
        var cargs = ([bin] + argv).map { strdup($0) }
            + [nil as UnsafeMutablePointer<CChar>?]
        defer { cargs.forEach { free($0) } }
        let rc = cargs.withUnsafeMutableBufferPointer { cargv in
            posix_spawnp(&pid, bin, &actions, &attr, cargv.baseAddress,
                         environ)
        }
        // Parent drops its write ends so read sees EOF when the last
        // child-side writer (direct or descendant) closes.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        guard rc == 0 else {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            throw ValidationError("cannot spawn \(bin): errno \(rc)")
        }

        // NSMutableData: a class reference, so the drain closures mutate
        // through it without capturing a var (keeps Sendable checks quiet).
        final class WaitStatus { var raw: Int32 = -1 }
        let wstatus = WaitStatus()
        let outData = NSMutableData()
        let errData = NSMutableData()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global().async {
            outData.append(out.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }
        drain.enter()
        DispatchQueue.global().async {
            errData.append(err.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var st: Int32 = 0
            _ = waitpid(pid, &st, 0)
            wstatus.raw = st
            sem.signal()
        }
        if sem.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            // Whole-group SIGTERM, short grace, then whole-group SIGKILL —
            // TERM-ignoring children AND their descendants all die.
            kill(-pid, SIGTERM)
            _ = sem.wait(timeout: .now() + .milliseconds(300))
            kill(-pid, SIGKILL)
            // Closing our read ends unblocks drain workers stuck in
            // readDataToEndOfFile if any survivor still held the pipe.
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = drain.wait(timeout: .now() + .seconds(2))
            throw ValidationError("agent timed out after \(timeout)s")
        }
        // Same bound on the success path: an exited child whose descendants
        // keep a pipe write-end open must not hang `ask` or leak the drains.
        if drain.wait(timeout: .now() + .seconds(5)) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = drain.wait(timeout: .now() + .seconds(2))
        }
        let text = String(decoding: outData as Data, as: UTF8.self)
        let st = wstatus.raw
        let statusDesc = (st & 0x7f == 0)
            ? "exited \(Int((st >> 8) & 0xff))" : "killed by signal \(st & 0x7f)"
        guard st & 0x7f == 0, (st >> 8) & 0xff == 0 else {
            let e = String(decoding: errData as Data, as: UTF8.self)
            throw ValidationError("\(bin) \(statusDesc): \(e.prefix(400))")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `swctx answer` (W12): thin wrapper over the same SwctxTools `answer`
/// path the MCP tool uses — evidence pack → local Ollama JSON synthesis
/// → server-side citation validation → durable `kind=ask` record.
/// `--expected-path` is an eval-harness oracle: recorded for scoring,
/// never shown to the model.
struct AnswerCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "answer",
        abstract: "Answer a question over indexed evidence — cited JSON via a local LLM (Ollama, default) or an agent CLI backend (--backend cli:agy|claude|codex|…), no cloud credits.")
    @Option(name: .long, help: "Workspace path (default: current directory)") var workspace: String = "."
    @Option(name: .long, help: "Question to answer") var query: String
    @Option(name: .long, help: "Ollama model (default qwen2.5:3b; env SWCTX_ANSWER_MODEL)") var model: String?
    @Option(name: .long, help: "Synthesis backend: ollama (default) | cli:<name> — agent CLI (agy, claude, codex, qwen, opencode…); env SWCTX_ANSWER_BACKEND/SWCTX_ANSWER_CLI") var backend: String?
    @Option(name: .long, help: "Per-attempt model timeout seconds (one format-retry allowed)") var timeout: Int = Answer.defaultTimeoutSeconds
    @Flag(name: .long, help: "Bounded planner loop: iterate retrieval (≤4 rounds, VN+EN query variants) before answering — rescue mode for retrieval misses") var plan = false
    @Option(name: .long, help: "Planner total wall-clock seconds (default 60; ~20s per planner call)") var planTimeout: Int = Answer.defaultPlanTimeoutSeconds
    @Option(name: .long, help: "Eval oracle path — recorded only, never shown to the model") var expectedPath: String?
    @Option(name: .long, help: "Output format: json | human") var format: String = "json"

    func run() async throws {
        var args: [String: MCPValue] = [
            "workspace": .string(workspace),
            "query": .string(query),
            "timeout": .int(timeout),
            "source": .string("cli"),
        ]
        if let model { args["model"] = .string(model) }
        if let backend { args["backend"] = .string(backend) }
        if plan {
            args["plan"] = .bool(true)
            args["plan_timeout"] = .int(planTimeout)
        }
        if let expectedPath { args["expected_path"] = .string(expectedPath) }
        let out = try await SwctxTools.call(name: "answer", arguments: args)
        if format == "json" {
            print(out)
            return
        }
        guard let d = try? JSONSerialization.jsonObject(with: Data(out.utf8))
                as? [String: Any] else {
            print(out)
            return
        }
        if let a = d["answer"] as? String { print(a) }
        else { print("(no answer — \(d["limitations"] as? String ?? "unknown"))") }
        for c in (d["citations"] as? [[String: Any]]) ?? [] {
            print("  [\(c["evidence_id"] ?? "")] \(c["path"] ?? ""):\(c["start_line"] ?? "")-\(c["end_line"] ?? "")")
        }
        if let lim = d["limitations"] as? String, !lim.isEmpty {
            FileHandle.standardError.write("limitations: \(lim)\n".data(using: .utf8)!)
        }
    }
}

struct SimulateCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "simulate",
        abstract: "Pre-flight a unified diff: which callers/implementers/tests would break.")
    @Argument(help: "Workspace path (default: current directory)") var path: String = "."
    @Option(name: .long, help: "Path to a .diff/.patch file (default: read stdin)") var diff: String?
    @Option(name: .long, help: "Max callers per symbol") var maxCallers: Int = 50

    func run() throws {
        let text: String
        if let diff {
            text = try String(contentsOfFile: diff, encoding: .utf8)
        } else {
            text = String(data: FileHandle.standardInput.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let store = try Store(workspaceRoot: root)
        let result = try Simulate.run(store: store, diff: text, maxCallers: maxCallers)
        let data = try JSONSerialization.data(withJSONObject: result,
                                              options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}

struct McpCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp",
        abstract: "Run the MCP server on stdio (point your agent CLI at this command).")

    func run() async throws {
        try await MCPServer.run()
    }
}

/// Resolve the running binary to an absolute path: a bare `swctx` invoked
/// via PATH arrives as argv[0] with no slash, and a plain cwd fallback would
/// point client configs at a file that does not exist. Shared by
/// `mcp-config` and `install-agent` — both write `command:` paths.
private func resolveExecutableOnPATH(_ argv0: String) -> String {
    var resolved = (argv0 as NSString).standardizingPath
    if !resolved.hasPrefix("/") {
        if !argv0.contains("/") {
            for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":") {
                let cand = "\(dir)/\(argv0)"
                if FileManager.default.isExecutableFile(atPath: cand) {
                    resolved = cand
                    break
                }
            }
        }
        if !resolved.hasPrefix("/") {
            // argv0 told us nothing usable — ask the kernel for the real
            // binary path rather than fabricating cwd/argv0 (which may not
            // exist when argv0 was customized).
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            var size = UInt32(buf.count)
            if _NSGetExecutablePath(&buf, &size) == 0 {
                let path = String(decoding: buf.prefix(while: { $0 != 0 })
                    .map { UInt8(bitPattern: $0) }, as: UTF8.self)
                resolved = (path as NSString).standardizingPath
            } else {
                resolved = FileManager.default.currentDirectoryPath + "/" + resolved
            }
        }
    }
    return resolved
}

struct McpConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp-config",
        abstract: "Print MCP client config snippet for this binary.")

    func run() throws {
        let resolved = resolveExecutableOnPATH(CommandLine.arguments[0])
        print("""
        {
          "mcpServers": {
            "swctx": {
              "command": "\(resolved)",
              "args": ["mcp"]
            }
          }
        }
        """)
    }
}

struct InstallAgentCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install-agent",
        abstract: "Register swctx as an MCP server in known agent CLI configs (idempotent).")
    @Flag(name: .long, help: "Preview changes without writing") var dryRun = false

    /// JSON configs keyed at top-level `mcpServers`; codex uses a TOML block.
    static let jsonClients: [(name: String, path: String)] = [
        ("claude", "~/.claude.json"),
        ("gemini", "~/.gemini/settings.json"),
        ("cursor", "~/.cursor/mcp.json"),
        ("windsurf", "~/.codeium/windsurf/mcp_config.json"),
        ("devin", "~/.config/devin/mcp_config.json"),
    ]
    static let tomlClients: [(name: String, path: String)] = [
        ("codex", "~/.codex/config.toml"),
    ]

    func run() throws {
        let bin = resolveExecutableOnPATH(CommandLine.arguments[0])
        let entry: [String: Any] = ["command": bin, "args": ["mcp"]]
        for client in Self.jsonClients {
            let url = URL(fileURLWithPath: (client.path as NSString).expandingTildeInPath)
            var root: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            } else if FileManager.default.fileExists(atPath: url.path) {
                print("\(client.name): \(url.path) exists but is not a JSON object — skipped")
                continue
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            if servers["swctx"] != nil {
                print("\(client.name): already registered")
                continue
            }
            servers["swctx"] = entry
            root["mcpServers"] = servers
            if dryRun {
                print("\(client.name): would add swctx to \(url.path)")
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.copyItem(
                    at: url, to: url.appendingPathExtension("bak"))
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("\(client.name): registered swctx in \(url.path)")
        }
        for client in Self.tomlClients {
            let url = URL(fileURLWithPath: (client.path as NSString).expandingTildeInPath)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if existing.contains("[mcp_servers.swctx]") {
                print("\(client.name): already registered")
                continue
            }
            let block = "\n[mcp_servers.swctx]\ncommand = \"\(bin)\"\nargs = [\"mcp\"]\n"
            if dryRun {
                print("\(client.name): would append mcp_servers.swctx to \(url.path)")
                continue
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.copyItem(
                    at: url, to: url.appendingPathExtension("bak"))
            }
            try (existing + block).write(to: url, atomically: true, encoding: .utf8)
            print("\(client.name): appended [mcp_servers.swctx] to \(url.path)")
        }
    }
}
