import ArgumentParser
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
        subcommands: [IndexCmd.self, StatusCmd.self, PrimeCmd.self, SearchCmd.self, RerankCmd.self, TreeCmd.self, EmbedCmd.self, DiscoverCmd.self, WatchCmd.self, AskCmd.self, ModelCmd.self, McpCmd.self, McpConfigCmd.self, InstallAgentCmd.self, GcCmd.self],
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
        var hits = try Search.hybridCandidates(
            store: store, embedder: Embedder.shared, query: query,
            limit: limit, poolLimit: limit,
            pathFilter: nil, includeVector: !identifier)
        if identifier && hits.isEmpty {
            hits = try Search.hybridCandidates(
                store: store, embedder: Embedder.shared, query: query,
                limit: limit, poolLimit: limit)
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
            Reranker.docContext(path: $0.path, symbol: $0.symbol,
                                content: contents[$0.chunkID] ?? "")
        }
        let reranker = try Reranker()
        reranker.warm()
        let t0 = Date()
        let scores = reranker.scoreAll(query: query, docs: docs, batchSize: batch)
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

struct WatchCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch",
        abstract: "Watch a workspace via FSEvents and keep its index fresh (foreground).")
    @Argument(help: "Workspace path") var path: String = "."
    @Flag(name: .long, help: "Run a single incremental index pass and exit (no watching)") var once = false

    func run() async throws {
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

    /// Run `bin argv`, prompt as last argv element; timeout kills the child.
    static func spawn(_ bin: String, argv: [String], timeout: Int) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = argv
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            p.terminate()
            throw ValidationError("agent timed out after \(timeout)s")
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ValidationError("\(bin) exited \(p.terminationStatus): \(e.prefix(400))")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct McpCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp",
        abstract: "Run the MCP server on stdio (point your agent CLI at this command).")

    func run() async throws {
        try await MCPServer.run()
    }
}

struct McpConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp-config",
        abstract: "Print MCP client config snippet for this binary.")

    func run() throws {
        let bin = CommandLine.arguments[0]
        var resolved = (bin as NSString).standardizingPath
        if !resolved.hasPrefix("/") {
            // Bare name invoked via PATH, or a relative path: resolve to absolute.
            if !bin.contains("/") {
                for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "")
                    .split(separator: ":") {
                    let cand = "\(dir)/\(bin)"
                    if FileManager.default.isExecutableFile(atPath: cand) {
                        resolved = cand
                        break
                    }
                }
            }
            if !resolved.hasPrefix("/") {
                resolved = FileManager.default.currentDirectoryPath + "/" + resolved
            }
        }
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
        var bin = (CommandLine.arguments[0] as NSString).standardizingPath
        if !bin.hasPrefix("/") {
            bin = FileManager.default.currentDirectoryPath + "/" + bin
        }
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
