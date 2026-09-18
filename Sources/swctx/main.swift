import ArgumentParser
import Foundation
import MCP
import SwctxCore

typealias MCPValue = MCP.Value

@main
struct Swctx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swctx",
        abstract: "Local semantic code index + MCP server (Swift reimplementation of the ctxe model).",
        version: "0.1.0",
        subcommands: [IndexCmd.self, StatusCmd.self, PrimeCmd.self, SearchCmd.self, TreeCmd.self, EmbedCmd.self, DiscoverCmd.self, WatchCmd.self, AskCmd.self, ModelCmd.self, McpCmd.self, McpConfigCmd.self, InstallAgentCmd.self],
        defaultSubcommand: nil)
}

struct IndexCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index",
        abstract: "Index a workspace directory incrementally.")
    @Argument(help: "Workspace path (default: current directory)") var path: String = "."
    @Flag(name: .long, help: "Full re-index, ignoring cached hashes") var force = false
    @Flag(name: .long, help: "Report what would change without writing") var dryRun = false
    @Flag(name: .long, help: "Skip the post-index embedding pass (pending chunks stay for `swctx embed`)") var skipEmbed = false
    @Option(name: .long, help: "Output format: human | json") var format: String = "human"

    func run() async throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let store = try Store(workspaceRoot: root)
        let indexer = Indexer(store: store)
        if dryRun {
            let report = try indexer.dryRun()
            if format == "json" {
                print(String(data: try JSONEncoder().encode(report), encoding: .utf8)!)
            } else {
                print("Would index \(report.filesTotal) files: \(report.filesNew) new, \(report.filesChanged) changed, \(report.filesUnchanged) unchanged, \(report.filesDeleted) deleted")
            }
            return
        }
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

    func run() async throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let store = try Store(workspaceRoot: root)
        let indexer = Indexer(store: store)
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

struct ModelCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "model",
        abstract: "Manage the on-device embedding model (bge-base-en-v1.5 CoreML).")

    func run() async throws {
        let dir = BGEEmbedder.modelDir
        if BGEEmbedder.isInstalled {
            print("installed: \(dir.path) (bge-base-en-v1.5-coreml, 768-d)")
            return
        }
        let base = "https://huggingface.co/rsvalerio/bge-base-en-v1.5-coreml/resolve/main"
        let files = [
            "vocab.txt", "tokenizer_config.json",
            "model.mlpackage/Manifest.json",
            "model.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "model.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        ]
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
        print("installed: \(dir.path) (bge-base-en-v1.5-coreml, 768-d)")
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
