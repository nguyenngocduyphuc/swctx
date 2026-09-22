import Foundation
import GRDB
import CryptoKit

public struct IndexReport: Codable, Sendable {
    public var workspace: String = ""
    public var filesTotal: Int = 0
    public var filesIndexed: Int = 0
    public var filesUnchanged: Int = 0
    public var filesDeleted: Int = 0
    public var chunks: Int = 0
    public var symbols: Int = 0
    public var edges: Int = 0
    public var edgesResolved: Int = 0
    public var embeddedChunks: Int = 0
    public var commitsIngested: Int = 0
    public var pendingEmbeddings: Int = 0
    /// Force reindex only: vectors re-attached from the pre-wipe snapshot.
    public var vectorsPreserved: Int = 0
    public var embeddingModel: String? = nil
    public var durationMs: Int = 0
    public var errors: [String] = []
}

public final class Indexer {
    let store: Store
    /// Lazy: Embedder() eagerly loads the ~900MB CoreML model at
    /// construction, so watchers sitting on a fully-embedded index must
    /// not pay that residency for zero pending chunks. Created on first
    /// embed need via requireEmbedder(); injected instances stay honored.
    var embedder: Embedder?

    static let denyDirs: Set<String> = [
        ".git", ".build", ".next", ".nuxt", ".venv", "venv", "env",
        "node_modules", "dist", "build", "out", "target", "DerivedData",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", "site-packages",
        "Pods", "Carthage", "vendor", "coverage", ".idea", ".ctxe", ".swctx",
        ".cache", ".gradle", ".terraform",
    ]

    static let secretPatterns: [String] = [
        ".env", "credentials", "secret", "id_rsa", "id_ed25519",
        ".pem", ".key", ".p12", ".pfx", ".keystore",
    ]

    static let maxFileSize = 1_000_000
    static let maxFiles = 60_000
    /// Cap on `embedAll` batches inside `run()` so a pathological store
    /// can't loop forever; `swctx embed` stays uncapped.
    static let embedMaxBatches = 50
    /// File stems that re-export a directory as a module: python __init__,
    /// js/ts index, rust mod.
    static let packageIndexStems: Set<String> = ["__init__", "index", "mod"]

    public init(store: Store, embedder: Embedder? = nil) {
        self.store = store
        self.embedder = embedder
    }

    /// Lazily create the embedder on first embed need; the returned
    /// instance stays cached for the whole pass so one vector space
    /// covers every batch.
    @discardableResult
    func requireEmbedder() -> Embedder {
        if let e = embedder { return e }
        let e = Embedder()
        embedder = e
        return e
    }

    // MARK: - Discovery

    static func isProbablySecret(_ name: String) -> Bool {
        let l = name.lowercased()
        return secretPatterns.contains { l.hasPrefix($0) || l.hasSuffix($0) || l.contains("secret") }
    }

    static func looksBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        return head.contains(0)
    }

    /// Minimal ignore-file support: `dir/`, `*.ext`, `name`, `/anchored`,
    /// plus `dir/*/` static-prefix pruning. Reads `.gitignore` and
    /// `.swctxignore` (the latter for index-only exclusions that must not
    /// alter git semantics).
    static func loadIgnorePatterns(root: URL) -> [String] {
        var out: [String] = []
        for name in [".gitignore", ".swctxignore"] {
            guard let text = try? String(
                contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            out += text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
                .map { $0.hasPrefix("/") ? String($0.dropFirst()) : String($0) }
        }
        return out
    }

    static func matches(_ pattern: String, relPath: String) -> Bool {
        let p = pattern
        if p.hasSuffix("/") {
            var dir = String(p.dropLast())
            // `dir/*/` style: prune by the static prefix before the first
            // wildcard ("vendors/*/" -> ignore everything under "vendors/").
            if let star = dir.firstIndex(of: "*") {
                dir = String(dir[dir.startIndex..<star])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return relPath == dir || relPath.hasPrefix(dir + "/")
                || relPath.contains("/" + dir + "/")
        }
        if p.contains("/") {
            return wildcardMatch(p, relPath)
        }
        // basename match
        let base = (relPath as NSString).lastPathComponent
        return wildcardMatch(p, base)
    }

    static func wildcardMatch(_ pattern: String, _ string: String) -> Bool {
        var regex = NSRegularExpression.escapedPattern(for: pattern)
        regex = regex.replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return string.range(of: "^\(regex)$", options: .regularExpression) != nil
    }

    /// URL-resource enumerator: directory entry attributes arrive prefetched
    /// in bulk (one getattrlistbulk per directory) instead of a stat per file.
    /// On a 100k-entry tree this is ~10x faster than `enumerator(atPath:)`.
    public func discoverFiles() -> [String] {
        let root = store.workspaceRoot
        let ignorePatterns = Indexer.loadIgnorePatterns(root: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: nil) else { return [] }
        var out: [String] = []
        // The URL enumerator yields children under the canonicalized root
        // (firmlinks/symlinks resolved, e.g. /tmp -> /private/tmp) while
        // root.path may keep the symlinked form — strip against both.
        var candidates = [root.path]
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(root.path, &buf) != nil {
            let canonical = String(cString: buf)
            if canonical != root.path { candidates.insert(canonical, at: 0) }
        }
        for case let url as URL in en {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let absPath = url.path(percentEncoded: false)
            let rel = candidates
                .first(where: { absPath.hasPrefix($0 + "/") })
                .map { String(absPath.dropFirst($0.count + 1)) }
                ?? url.lastPathComponent
            let comps = rel.split(separator: "/").map(String.init)
            let name = comps.last ?? rel
            // dot components skipped except .github
            let hidden = comps.contains(where: { $0.hasPrefix(".") && $0 != ".github" })
            if rv.isDirectory == true {
                // skipDescendants() is only valid on directories — calling it on a
                // file silently drops the remaining siblings in that directory.
                if hidden || Indexer.denyDirs.contains(name)
                    || ignorePatterns.contains(where: { Indexer.matches($0, relPath: rel + "/") }) {
                    en.skipDescendants()
                }
                continue
            }
            if hidden { continue }
            if rv.isRegularFile != true { continue }
            if Indexer.isProbablySecret(name) { continue }
            if ignorePatterns.contains(where: { Indexer.matches($0, relPath: rel) }) { continue }
            guard Languages.languageID(forPath: name) != nil else { continue }
            guard let size = rv.fileSize, size > 0,
                  size <= Indexer.maxFileSize else { continue }
            out.append(rel)
            if out.count >= Indexer.maxFiles { break }
        }
        return out.sorted()
    }

    // MARK: - Index

    @discardableResult
    public func run(force: Bool, autoEmbed: Bool = true,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> IndexReport {
        let started = Date()
        var report = IndexReport(workspace: store.workspaceRoot.path)
        let files = discoverFiles()
        report.filesTotal = files.count
        let discovered = Set(files)

        // A force reindex deletes every file row below, and ON DELETE
        // CASCADE takes the chunks' embeddings with it — the bounded embed
        // batch at the end then covers only a fraction of the workspace.
        // Snapshot the vectors first so unchanged chunks get theirs back.
        if force { try snapshotEmbeddings() }

        // Remove stale file rows
        let staleIDs: [Int64] = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path FROM files")
                .filter { !discovered.contains(($0["path"] as? String) ?? "") }
                .compactMap { $0["id"] as? Int64 }
        }
        if !staleIDs.isEmpty {
            try store.pool.write { db in
                for fid in staleIDs { try deleteFileRows(db: db, fileID: fid) }
            }
            report.filesDeleted = staleIDs.count
        }

        var toIndex: [(String, String)] = []  // (relPath, sha)
        for rel in files {
            let url = store.workspaceRoot.appendingPathComponent(rel)
            guard let data = try? Data(contentsOf: url),
                  !Indexer.looksBinary(data) else {
                report.errors.append("\(rel): unreadable or binary (path: \(url.path))")
                continue
            }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let existing: String? = try store.pool.read { db in
                try String.fetchOne(db, sql: "SELECT sha FROM files WHERE path = ?", arguments: [rel])
            }
            if !force, existing == sha {
                report.filesUnchanged += 1
                continue
            }
            toIndex.append((rel, sha))
        }

        for (rel, sha) in toIndex {
            do {
                try indexOneFile(rel: rel, sha: sha, report: &report)
            } catch {
                report.errors.append("\(rel): \(error.localizedDescription)")
            }
            if report.filesIndexed % 200 == 0 {
                progress("indexed \(report.filesIndexed)/\(toIndex.count)")
            }
        }

        // All chunk rows are re-inserted now: re-attach the snapshotted
        // vectors whose embedded text survived the wipe unchanged.
        if force {
            report.vectorsPreserved = try restoreEmbeddings()
        }

        // Resolve edges: dst_name -> symbols
        report.edgesResolved = try resolveEdges()

        // File-graph PageRank over the just-resolved edges: hub files
        // accumulate rank, hybrid reads it as a small static boost.
        try updatePageRank()

        // Embedding pass: keep embedding in bounded batches until no
        // pending chunks remain (capped at embedMaxBatches); `swctx embed`
        // fills whatever a mid-run failure or the cap leaves. Never fails
        // the index — embed errors land in report.errors.
        let pendingBefore = autoEmbed ? ((try? pendingEmbeddings()) ?? 0) : 0
        if autoEmbed, pendingBefore > 0, requireEmbedder().isAvailable {
            report.embeddingModel = embedder?.modelName
            do {
                report.embeddedChunks = try embedAll(
                    maxBatches: Indexer.embedMaxBatches
                ) { done in progress("embedded \(done)") }
            } catch {
                report.errors.append("embed: \(error.localizedDescription)")
            }
        }
        report.pendingEmbeddings = (try? pendingEmbeddings()) ?? 0
        if autoEmbed, report.pendingEmbeddings > 0 {
            report.errors.append(
                "embed: \(report.pendingEmbeddings) chunks still pending — run `swctx embed`")
        }
        // Release the embedder: a long-lived watcher holding the ~1GB
        // model idles it into swap/compressed RAM while the process still
        // owns the footprint. Next embed pass recreates it on demand.
        embedder = nil
        malloc_zone_pressure_relief(nil, 0)

        // Git history → commit records (temporal queries via
        // search_records; changed paths become staleness anchors).
        report.commitsIngested = GitHistory.ingest(store: store)

        report.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        try? store.bumpEmbeddingsEpoch()
        // Freshness stamp for `watch status` — written on every pass so
        // the daemon's per-workspace index age is queryable read-only.
        try? store.noteIndexed(files: report.filesTotal)
        Store.register(root: store.workspaceRoot)
        return report
    }

    private func deleteFileRows(db: Database, fileID: Int64) throws {
        let chunkIDs = try Int64.fetchAll(db,
            sql: "SELECT id FROM chunks WHERE file_id = ?", arguments: [fileID])
        if !chunkIDs.isEmpty {
            let q = chunkIDs.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM chunks_fts WHERE rowid IN (\(q))",
                           arguments: StatementArguments(chunkIDs))
            try db.execute(sql: "DELETE FROM chunks_trigram WHERE rowid IN (\(q))",
                           arguments: StatementArguments(chunkIDs))
        }
        try db.execute(sql: "DELETE FROM files WHERE id = ?", arguments: [fileID])
    }

    private func indexOneFile(rel: String, sha: String, report: inout IndexReport) throws {
        let url = store.workspaceRoot.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: url) else { return }
        let lang = Languages.languageID(forPath: url.lastPathComponent) ?? "text"
        let bytes = [UInt8](data)
        let analysis = Analyzer.analyze(bytes: bytes, languageID: lang, path: rel)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        try store.pool.write { db in
            if let oldID = try Int64.fetchOne(db,
                sql: "SELECT id FROM files WHERE path = ?", arguments: [rel]) {
                try deleteFileRows(db: db, fileID: oldID)
            }
            try db.execute(sql: """
                INSERT INTO files(path, lang, sha, size, mtime, indexed_at)
                VALUES(?,?,?,?,?,?)
                """, arguments: [rel, lang, sha, data.count, mtime,
                                 Date().timeIntervalSince1970])
            let fileID = db.lastInsertedRowID

            // Symbol names per chunk for the FTS `symbol_names` column:
            // the chunk's own symbol first, then every symbol row mapped
            // to it (deduped — the defining row usually points at itself).
            var namesByChunk: [Int: [String]] = [:]
            for s in analysis.symbols where s.chunkIndex >= 0 {
                namesByChunk[s.chunkIndex, default: []].append(s.name)
            }
            var chunkIDs: [Int64] = []
            for (i, c) in analysis.chunks.enumerated() {
                try db.execute(sql: """
                    INSERT INTO chunks(file_id, idx, start_line, end_line, kind, symbol, content, tokens)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, arguments: [fileID, i, c.startLine, c.endLine, c.kind,
                                     c.symbol, c.content, c.content.count / 4])
                let cid = db.lastInsertedRowID
                var seen: Set<String> = []
                let names = ((c.symbol.map { [$0] } ?? []) + (namesByChunk[i] ?? []))
                    .filter { seen.insert($0).inserted }
                let pathToks = Search.pathTokenString(rel)
                let symToks = Search.symbolTokenString(names)
                try db.execute(sql: """
                    INSERT INTO chunks_fts(rowid, content, path_tokens, symbol_names, folded)
                    VALUES(?,?,?,?,?)
                    """, arguments: [cid, c.content, pathToks, symToks,
                                     Search.foldText(c.content + " " + pathToks + " " + symToks)])
                if store.trigramEnabled {
                    try db.execute(sql: """
                        INSERT INTO chunks_trigram(rowid, content) VALUES(?,?)
                        """, arguments: [cid, c.content])
                }
                chunkIDs.append(cid)
            }

            for s in analysis.symbols {
                try db.execute(sql: """
                    INSERT INTO symbols(file_id, chunk_id, name, kind, line, signature, norm_kind)
                    VALUES(?,?,?,?,?,?,?)
                    """, arguments: [fileID,
                                     s.chunkIndex >= 0 ? chunkIDs[s.chunkIndex] : nil,
                                     s.name, s.kind, s.line, s.signature, s.norm])
            }
            for e in analysis.edges where e.chunkIndex >= 0 {
                try db.execute(sql: """
                    INSERT INTO edges(src_chunk, dst_name, kind, line, qualifier) VALUES(?,?,?,?,?)
                    """, arguments: [chunkIDs[e.chunkIndex], e.dstName, e.kind, e.line,
                                     e.qualifier])
            }
            report.chunks += analysis.chunks.count
            report.symbols += analysis.symbols.count
            report.edges += analysis.edges.count
        }
        report.filesIndexed += 1
    }

    /// SQL reconstruction of the text `embedPending` feeds the model for a
    /// chunk — `path + "\n" + (symbol ?? kind) + "\n" + content`, prefix
    /// 1800 — where `c` is the chunks row and `f` its files row. The
    /// snapshot key is this exact text, not just content: identical chunk
    /// bodies in different files embed differently via the path prefix.
    static let embedTextSQL = """
        substr(f.path || char(10) || COALESCE(c.symbol, c.kind, '') \
        || char(10) || c.content, 1, 1800)
        """

    /// Stage all stored vectors in a persistent table keyed by `embedTextSQL`
    /// so `restoreEmbeddings` can re-attach them after a force reindex
    /// recreates the chunk rows — or after a killed `embed --reindex` left
    /// its upfront `DELETE FROM embeddings` committed with no replacements.
    /// A real (non-TEMP) table is deliberate: the snapshot must survive
    /// process death to be any use, and `restoreEmbeddings` drops it once
    /// evaluated. Staging via SQL — no vector blobs pass through memory.
    /// The PK on `k` doubles as the restore join index and dedupes
    /// same-text rows.
    func snapshotEmbeddings() throws {
        try store.pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS vec_snapshot(
                    k TEXT PRIMARY KEY,
                    dim INTEGER NOT NULL,
                    vec BLOB NOT NULL)
                """)
            try db.execute(sql: "DELETE FROM vec_snapshot")
            try db.execute(sql: """
                INSERT OR REPLACE INTO vec_snapshot(k, dim, vec)
                SELECT \(Indexer.embedTextSQL), e.dim, e.vec
                FROM embeddings e
                JOIN chunks c ON c.id = e.chunk_id
                JOIN files f ON f.id = c.file_id
                """)
        }
    }

    /// Re-attach snapshotted vectors to chunks whose embedded text is
    /// unchanged, restoring only rows stored at the active model's dim —
    /// the same mixed-dim guard as `embedAll`. OR IGNORE keeps the count
    /// honest for files that kept their rows (unreadable under --force)
    /// and preserves vectors a killed reindex managed to commit. No-op
    /// when no snapshot is staged; a staged snapshot is dropped once
    /// evaluated. Returns the count restored.
    @discardableResult
    private func restoreEmbeddings() throws -> Int {
        try store.pool.write { db in
            let staged = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'vec_snapshot'
                """) ?? 0
            guard staged > 0 else { return 0 }
            // Without a working model the same-dim guard can't be
            // evaluated — keep the snapshot so a later run can restore it.
            let dim = requireEmbedder().dimension
            guard dim > 0 else { return 0 }
            // Dropped even when the INSERT throws: a poisoned snapshot
            // must not wedge every later embed pass.
            defer { try? db.execute(sql: "DROP TABLE vec_snapshot") }
            try db.execute(sql: """
                INSERT OR IGNORE INTO embeddings(chunk_id, dim, vec)
                SELECT c.id, s.dim, s.vec
                FROM chunks c
                JOIN files f ON f.id = c.file_id
                JOIN vec_snapshot s ON s.k = \(Indexer.embedTextSQL)
                WHERE s.dim = ?
                """, arguments: [dim])
            return db.changesCount
        }
    }

    /// Match edge dst_name to symbol rows in precedence passes:
    /// 0. qualified calls `q.f()` — resolve only inside the files q refers to
    ///    (imported module or import alias); a qualifier with no known target
    ///    stays NULL rather than risk a wrong-file link,
    /// 1. a symbol defined in the same file as the source chunk — handles
    ///    `self.method()`, module-level helpers, same-file class methods,
    /// 2. a symbol in a file the source file imports,
    /// 3. a global match only when exactly one file defines that name —
    ///    ambiguous cross-file names stay NULL (better unlinked than wrong).
    /// Matching runs in memory over bulk fetches (all symbols, all pending
    /// edges); each pass applies its resolutions as one batched UPDATE staged
    /// through a temp table — no per-edge queries over the edges table.
    private func resolveEdges() throws -> Int {
        // ---- Read phase: bulk-fetch every input once ----
        // basename (no ext, lowercased) -> file ids: "p8_daily.py" -> {"p8_daily": id}
        var baseToFiles: [String: Set<Int64>] = [:]
        var pathByFile: [Int64: String] = [:]
        // (src file, dst_name, absolute 1-based line) for every imports edge
        var importEdges: [(src: Int64, name: String, line: Int)] = []
        var candsByName: [String: [(file: Int64, chunk: Int64?)]] = [:]
        var filesByName: [String: Set<Int64>] = [:]
        var pending: [(id: Int64, name: String, qualifier: String?, srcFile: Int64)] = []
        try store.pool.read { db in
            for r in try Row.fetchAll(db, sql: "SELECT id, path FROM files") {
                guard let fid = r["id"] as? Int64, let path = r["path"] as? String else { continue }
                pathByFile[fid] = path
                let comps = (path as NSString).pathComponents
                let base = ((comps.last ?? path) as NSString)
                    .deletingPathExtension.lowercased()
                baseToFiles[base, default: []].insert(fid)
                // Package-index files also register under their directory
                // name so `import pkg` finds pkg/__init__.py, ui/index.ts,
                // foo/mod.rs (whose stems are "__init__"/"index"/"mod").
                if comps.count > 1, Indexer.packageIndexStems.contains(base) {
                    baseToFiles[comps[comps.count - 2].lowercased(), default: []].insert(fid)
                }
            }
            for r in try Row.fetchAll(db, sql: """
                SELECT DISTINCT c.file_id AS src, e.dst_name, e.line
                FROM edges e JOIN chunks c ON c.id = e.src_chunk WHERE e.kind = 'imports'
                """) {
                guard let src = r["src"] as? Int64,
                      let name = r["dst_name"] as? String,
                      let line = r["line"] as? Int64 else { continue }
                importEdges.append((src: src, name: name, line: Int(line)))
            }
            // name -> candidate (file, chunk) list for every symbol, fetched
            // once in symbol-id order so "first" picks are deterministic;
            // plus name -> set of files defining it (pass-3 ambiguity check).
            for r in try Row.fetchAll(db,
                sql: "SELECT name, file_id, chunk_id FROM symbols ORDER BY id") {
                guard let name = r["name"] as? String,
                      let file = r["file_id"] as? Int64 else { continue }
                candsByName[name, default: []]
                    .append((file: file, chunk: r["chunk_id"] as? Int64))
                filesByName[name, default: []].insert(file)
            }
            // All edges with their source file. Every edge is re-resolved from
            // scratch each run so stale picks left by older logic get repaired
            // rather than frozen in dst_chunk.
            for r in try Row.fetchAll(db, sql: """
                SELECT e.id, e.dst_name, e.qualifier, c.file_id AS src_file
                FROM edges e JOIN chunks c ON c.id = e.src_chunk
                """) {
                guard let eid = r["id"] as? Int64,
                      let name = r["dst_name"] as? String,
                      let src = r["src_file"] as? Int64 else { continue }
                pending.append((id: eid, name: name,
                                qualifier: r["qualifier"] as? String, srcFile: src))
            }
        }

        // ---- Compute phase: src file -> file ids it imports ----
        // An imports edge's dst_name is only the statement's leaf identifier —
        // `from m import f` stores 'f', `import x as y` stores the alias 'y',
        // `import a.b.c` stores 'c' — and its chunk often does not contain the
        // statement itself (short file headers emit no window chunk), so the
        // module tokens dst_name drops are recovered by re-reading the
        // statement's own line(s) from the source file: every identifier token
        // plus the leaf of quoted module paths; multi-line statements continue
        // while brackets stay open.
        var importsByFile: [Int64: Set<Int64>] = [:]
        // Per-src-file qualifier -> candidate files: every identifier token of
        // each import statement maps to same-named files, and the statement's
        // leaf (alias) maps to all of them — `import a.b as m` puts 'm', 'a'
        // and 'b' in scope for `m.f()`/`a.b.f()`.
        var qualToFiles: [Int64: [String: Set<Int64>]] = [:]
        var linesByFile: [Int64: [String]] = [:]
        var unreadableFiles: Set<Int64> = []
        for e in importEdges {
            var toks = Indexer.identTokens(e.name)
            if let rel = pathByFile[e.src] {
                if linesByFile[e.src] == nil && !unreadableFiles.contains(e.src) {
                    let url = store.workspaceRoot.appendingPathComponent(rel)
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        linesByFile[e.src] = text.components(separatedBy: "\n")
                    } else {
                        unreadableFiles.insert(e.src)
                    }
                }
                if let lines = linesByFile[e.src], lines.indices.contains(e.line - 1) {
                    var depth = 0
                    var i = e.line - 1
                    repeat {
                        toks += Indexer.identTokens(lines[i])
                        toks += Indexer.quotedModuleLeaves(lines[i])
                        depth += Indexer.bracketDelta(lines[i])
                        i += 1
                    } while depth > 0 && i < lines.count && i - (e.line - 1) < 8
                }
            }
            var stmtFiles = Set<Int64>()
            for tok in toks {
                if let files = baseToFiles[tok] {
                    importsByFile[e.src, default: []].formUnion(files)
                    qualToFiles[e.src, default: [:]][tok, default: []].formUnion(files)
                    stmtFiles.formUnion(files)
                }
            }
            qualToFiles[e.src, default: [:]][e.name.lowercased(), default: []]
                .formUnion(stmtFiles)
        }

        // Assign each pending edge to exactly one pass: (edge_id, dst_chunk).
        var passQ: [(Int64, Int64)] = []   // qualified call `q.f()`
        var pass1: [(Int64, Int64)] = []   // same-file
        var pass2: [(Int64, Int64)] = []   // imported-file
        var pass3: [(Int64, Int64)] = []   // unambiguous global
        for e in pending {
            guard let cands = candsByName[e.name] else { continue }
            if let q = e.qualifier?.lowercased(), !q.isEmpty,
               !Indexer.selfQualifiers.contains(q) {
                if let qf = qualToFiles[e.srcFile]?[q],
                   let c = cands.first(where: { qf.contains($0.file) && $0.chunk != nil }) {
                    passQ.append((e.id, c.chunk!))
                }
                continue
            }
            if let c = cands.first(where: { $0.file == e.srcFile && $0.chunk != nil }) {
                pass1.append((e.id, c.chunk!))
            } else if let imported = importsByFile[e.srcFile],
                      let c = cands.first(where: { imported.contains($0.file) && $0.chunk != nil }) {
                pass2.append((e.id, c.chunk!))
            } else if (filesByName[e.name]?.count ?? 0) == 1,
                      let c = cands.first(where: { $0.chunk != nil }) {
                pass3.append((e.id, c.chunk!))
            }
            // else: name undefined locally and defined in 2+ files — NULL.
        }

        // ---- Write phase: apply each pass as one batched UPDATE ----
        // Clear all dst_chunk first (edges that fail every pass must end NULL,
        // not keep a stale link), stage (edge_id, dst_chunk) pairs in a temp
        // table via chunked multi-row INSERTs, then a single UPDATE driven by
        // the staged rows.
        return try store.pool.write { db in
            try db.execute(sql: "UPDATE edges SET dst_chunk = NULL")
            try db.execute(sql: """
                CREATE TEMP TABLE IF NOT EXISTS edge_res(
                    edge_id INTEGER PRIMARY KEY,
                    dst_chunk INTEGER NOT NULL)
                """)
            var resolved = 0
            for pass in [passQ, pass1, pass2, pass3] where !pass.isEmpty {
                try db.execute(sql: "DELETE FROM edge_res")
                var i = 0
                while i < pass.count {
                    let slice = pass[i ..< min(i + 400, pass.count)]
                    let placeholders = slice.map { _ in "(?,?)" }.joined(separator: ",")
                    var flat: [Int64] = []
                    flat.reserveCapacity(slice.count * 2)
                    for (eid, dst) in slice { flat.append(eid); flat.append(dst) }
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO edge_res(edge_id, dst_chunk) VALUES \(placeholders)",
                        arguments: StatementArguments(flat))
                    i += slice.count
                }
                try db.execute(sql: """
                    UPDATE edges SET dst_chunk = (
                        SELECT r.dst_chunk FROM edge_res r WHERE r.edge_id = edges.id)
                    WHERE id IN (SELECT edge_id FROM edge_res)
                    """)
                resolved += pass.count
            }
            // Nominal-subtyping split: an `implements` edge whose resolved
            // target declares a concrete type (class/struct/enum) is really
            // `extends`; protocol/interface/trait targets stay `implements`.
            // Unresolved edges keep `implements` — no target to judge.
            // Norm kinds are language-agnostic, so the same rule works for
            // every grammar (swift's umbrella `class_declaration` already
            // resolved to struct/enum/... at insert time).
            let concrete = Languages.concreteTypeKinds.map { "'\($0)'" }.joined(separator: ",")
            let abstract = Languages.abstractTypeKinds.map { "'\($0)'" }.joined(separator: ",")
            try db.execute(sql: """
                UPDATE edges SET kind = 'extends'
                WHERE kind = 'implements' AND dst_chunk IS NOT NULL AND EXISTS (
                    SELECT 1 FROM symbols s
                    WHERE s.chunk_id = edges.dst_chunk AND s.name = edges.dst_name
                      AND s.norm_kind IN (\(concrete)))
                """)
            // Reverse repair: a stale `extends` (target re-declared as a
            // protocol/interface) goes back to `implements`.
            try db.execute(sql: """
                UPDATE edges SET kind = 'implements'
                WHERE kind = 'extends' AND dst_chunk IS NOT NULL AND EXISTS (
                    SELECT 1 FROM symbols s
                    WHERE s.chunk_id = edges.dst_chunk AND s.name = edges.dst_name
                      AND s.norm_kind IN (\(abstract)))
                """)
            return resolved
        }
    }

    /// File-graph PageRank over resolved chunk edges: node = file, arc
    /// src file -> dst file weighted by resolved edge count (parallel
    /// edges aggregate, self-links excluded — same-file calls carry no
    /// inter-file signal). Damping 0.85, up to 20 iterations or 1e-6
    /// max-delta convergence, dangling rank redistributed. Persisted on
    /// `files.pagerank` so the ranker reads it as a plain join; stored
    /// values are recomputed wholesale every index run.
    private func updatePageRank() throws {
        let (fileIDs, links) = try store.pool.read { db -> ([Int64], [(Int64, Int64)]) in
            let fids = try Int64.fetchAll(db, sql: "SELECT id FROM files")
            var links: [(Int64, Int64)] = []
            for r in try Row.fetchAll(db, sql: """
                SELECT sc.file_id AS src, dc.file_id AS dst
                FROM edges e
                JOIN chunks sc ON sc.id = e.src_chunk
                JOIN chunks dc ON dc.id = e.dst_chunk
                WHERE e.dst_chunk IS NOT NULL
                """) {
                guard let s = r["src"] as? Int64,
                      let d = r["dst"] as? Int64, s != d else { continue }
                links.append((s, d))
            }
            return (fids, links)
        }
        let n = fileIDs.count
        guard n > 0 else { return }
        var indexOf: [Int64: Int] = [:]
        indexOf.reserveCapacity(n)
        for (i, f) in fileIDs.enumerated() { indexOf[f] = i }
        var pairW: [Int: Double] = [:]
        for (s, d) in links {
            guard let si = indexOf[s], let di = indexOf[d] else { continue }
            pairW[si * n + di, default: 0] += 1
        }
        var outAdj = [[(Int, Double)]](repeating: [], count: n)
        var outDeg = [Double](repeating: 0, count: n)
        for (key, w) in pairW {
            let s = key / n, d = key % n
            outAdj[s].append((d, w))
            outDeg[s] += w
        }
        let damping = 0.85
        var pr = [Double](repeating: 1.0 / Double(n), count: n)
        var next = [Double](repeating: 0, count: n)
        for _ in 0..<20 {
            let base = (1 - damping) / Double(n)
            for i in 0..<n { next[i] = base }
            var dangling = 0.0
            for u in 0..<n {
                if outDeg[u] == 0 { dangling += pr[u]; continue }
                let share = damping * pr[u] / outDeg[u]
                for (v, w) in outAdj[u] { next[v] += share * w }
            }
            let danglingShare = damping * dangling / Double(n)
            var delta = 0.0
            for v in 0..<n {
                next[v] += danglingShare
                delta = max(delta, abs(next[v] - pr[v]))
            }
            swap(&pr, &next)
            if delta < 1e-6 { break }
        }
        // Persist via a staged temp table (same pattern as edge_res) —
        // one UPDATE over staged values, not n per-file statements.
        try store.pool.write { db in
            try db.execute(sql: """
                CREATE TEMP TABLE IF NOT EXISTS pr_vals(
                    file_id INTEGER PRIMARY KEY,
                    pr REAL NOT NULL)
                """)
            try db.execute(sql: "DELETE FROM pr_vals")
            var i = 0
            while i < n {
                let slice = fileIDs[i ..< min(i + 400, n)]
                let placeholders = slice.map { _ in "(?,?)" }.joined(separator: ",")
                var flat: [DatabaseValueConvertible] = []
                flat.reserveCapacity(slice.count * 2)
                for (j, f) in slice.enumerated() {
                    flat.append(f)
                    flat.append(pr[i + j])
                }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO pr_vals(file_id, pr) VALUES \(placeholders)",
                    arguments: StatementArguments(flat))
                i += slice.count
            }
            try db.execute(sql: """
                UPDATE files SET pagerank = (
                    SELECT r.pr FROM pr_vals r WHERE r.file_id = files.id)
                WHERE id IN (SELECT file_id FROM pr_vals)
                """)
            try db.execute(sql: "DELETE FROM pr_vals")
        }
    }

    /// Qualifiers that mean "this same object/module", not an import target:
    /// `self.f()`, `cls.f()`, `this.f()`, `super.f()` resolve via the normal
    /// same-file pass instead of the qualified-file pass.
    static let selfQualifiers: Set<String> = ["self", "cls", "this", "super"]

    /// Identifier-ish tokens of a string, lowercased — same split rule used
    /// for edge dst_name tokens.
    static func identTokens(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .map { $0.lowercased() }
    }

    /// Net bracket depth change of a line (`(`/`[`/`{` minus closers).
    static func bracketDelta(_ s: String) -> Int {
        var d = 0
        for ch in s {
            switch ch {
            case "(", "[", "{": d += 1
            case ")", "]", "}": d -= 1
            default: break
            }
        }
        return d
    }

    /// Leaf stems of quoted substrings in a source line: `'./mod'` -> `mod`,
    /// `"a/b/c.py"` -> `c`. Used to read module paths out of import statements.
    static func quotedModuleLeaves(_ line: String) -> [String] {
        var out: [String] = []
        var i = line.startIndex
        while i < line.endIndex {
            let q = line[i]
            guard q == "'" || q == "\"" || q == "`" else {
                i = line.index(after: i)
                continue
            }
            var j = line.index(after: i)
            while j < line.endIndex && line[j] != q { j = line.index(after: j) }
            let leaf = line[line.index(after: i)..<j]
                .split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            if !leaf.isEmpty {
                let stem = (leaf as NSString).deletingPathExtension
                out.append((stem.isEmpty ? leaf : stem).lowercased())
            }
            i = j
        }
        return out
    }

    // MARK: - Freshness / dry-run

    /// Disk-vs-index comparison. `changed` = indexed file whose content sha
    /// drifted (mtime/size gate, sha confirm); `added` = discovered but not
    /// indexed; `deleted` = indexed path gone from disk.
    public struct FreshnessReport: Sendable {
        public var changedPaths: Set<String> = []
        public var addedPaths: Set<String> = []
        public var deletedPaths: Set<String> = []
        public var unchangedCount: Int = 0
        /// Indexed rows that no longer reflect disk: changed + deleted.
        public var staleCount: Int { changedPaths.count + deletedPaths.count }
    }

    /// `deep: false` skips the directory walk: `addedPaths` is empty and the
    /// scan only stats indexed rows (~0.1s on a 5k-file workspace vs seconds
    /// for the full enumeration). `deep: true` additionally discovers files
    /// that are new on disk.
    public func freshness(deep: Bool = true) throws -> FreshnessReport {
        var report = FreshnessReport()
        let discovered = deep ? Set(discoverFiles()) : Set<String>()
        let indexed: [String: (sha: String, mtime: Double, size: Int64)] =
            try store.pool.read { db in
                var m: [String: (String, Double, Int64)] = [:]
                for r in try Row.fetchAll(db, sql: "SELECT path, sha, mtime, size FROM files") {
                    guard let p = r["path"] as? String else { continue }
                    m[p] = ((r["sha"] as? String) ?? "",
                            (r["mtime"] as? Double) ?? 0,
                            (r["size"] as? Int64) ?? 0)
                }
                return m
            }
        for (p, rec) in indexed {
            if deep {
                if !discovered.contains(p) { report.deletedPaths.insert(p) }
                continue
            }
            // Shallow scan: stat the indexed path directly.
            let url = store.workspaceRoot.appendingPathComponent(p)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            else {
                report.deletedPaths.insert(p)
                continue
            }
            let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let sz = Int64((attrs[.size] as? Int) ?? -1)
            if mt == rec.mtime && sz == rec.size { continue }
            guard let data = try? Data(contentsOf: url),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == rec.sha
            else { report.changedPaths.insert(p); continue }
        }
        for rel in discovered {
            guard let rec = indexed[rel] else {
                report.addedPaths.insert(rel)
                continue
            }
            let url = store.workspaceRoot.appendingPathComponent(rel)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mt = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let sz = Int64((attrs?[.size] as? Int) ?? -1)
            // The indexer keys on content sha, not mtime: a file whose
            // mtime/size are untouched is certainly unchanged, and one that
            // moved is only stale when its sha actually differs.
            if mt == rec.mtime && sz == rec.size {
                report.unchangedCount += 1
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == rec.sha
            else {
                report.changedPaths.insert(rel)
                continue
            }
            report.unchangedCount += 1
        }
        return report
    }

    public struct DryRunReport: Codable, Sendable {
        public var workspace: String = ""
        public var filesTotal: Int = 0
        public var filesNew: Int = 0
        public var filesChanged: Int = 0
        public var filesUnchanged: Int = 0
        public var filesDeleted: Int = 0
    }

    /// What `run()` would do, without touching the index.
    public func dryRun() throws -> DryRunReport {
        let f = try freshness()
        return DryRunReport(
            workspace: store.workspaceRoot.path,
            filesTotal: f.changedPaths.count + f.addedPaths.count + f.unchangedCount,
            filesNew: f.addedPaths.count,
            filesChanged: f.changedPaths.count,
            filesUnchanged: f.unchangedCount,
            filesDeleted: f.deletedPaths.count)
    }

    /// Number of chunks still missing vectors.
    public func pendingEmbeddings() throws -> Int {
        try store.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chunks c
                LEFT JOIN embeddings e ON e.chunk_id = c.id
                WHERE e.chunk_id IS NULL
                """) ?? 0
        }
    }

    /// Embed all remaining chunks, looping in bounded batches.
    /// `reindex: true` snapshots every stored vector, then drops them all
    /// (text format changed): a kill mid-run leaves the persistent snapshot
    /// behind so the next call restores whatever never got re-embedded,
    /// instead of stranding the index at zero vectors.
    /// `maxBatches > 0` caps the batch loop (index runs pass
    /// `embedMaxBatches`); `swctx embed` leaves it uncapped.
    /// Returns total embedded this call.
    @discardableResult
    public func embedAll(reindex: Bool = false, maxBatches: Int = 0,
                       progress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> Int {
        // Recover a reindex killed after its pre-wipe snapshot committed:
        // re-attach snapshotted vectors to chunks still missing one (same
        // dim only — a model-switch reindex falls through to fresh embeds).
        // Restored chunks stop being pending, so they keep the old vector
        // until an explicit --reindex rewrites them. No-op normally.
        _ = try restoreEmbeddings()
        if reindex {
            // Snapshot BEFORE the wipe, as one committed unit: a SIGTERM
            // anywhere in the batch loop then leaves the old vectors
            // restorable rather than committed-gone.
            try snapshotEmbeddings()
            try store.pool.write { db in try db.execute(sql: "DELETE FROM embeddings") }
        }
        // Refuse to mix vector spaces: stored vectors under a different dim
        // than the active model produces would silently score 0 in search.
        // `swctx embed --reindex` rebuilds them under the active model.
        if let dims = try store.pool.read({ db in
            try Int64.fetchAll(db, sql: "SELECT DISTINCT dim FROM embeddings")
        }).nilIfEmpty() {
            if dims.count > 1 || Int(dims[0]) != requireEmbedder().dimension {
                throw NSError(domain: "swctx", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "stored embeddings have dim=\(dims) but the active model produces \(requireEmbedder().dimension); run `swctx embed --reindex`"])
            }
        }
        var total = 0
        var skip: Set<Int64> = []
        var retries = 0
        var batches = 0
        while true {
            // Terminate on attempted==0, not embedded==0: a batch whose rows all
            // fail to embed must not stop the run while other rows remain.
            let (attempted, embedded) = try embedPending(
                limit: Indexer.embedderBatchSize, skip: skip, failed: &skip)
            if attempted == 0 { break }
            total += embedded
            progress(total)
            batches += 1
            if maxBatches > 0 && batches >= maxBatches { break }
            // CoreML predictions can start failing transiently after many
            // inferences in one process; recreate the embedder once and give
            // the skipped rows a second pass instead of abandoning them.
            if attempted > 0 && embedded == 0 {
                retries += 1
                if retries > 2 { break }
                skip.removeAll()
                embedder = Embedder()
            }
        }
        // Clean exit: any chunks still pending (batch cap, embedder
        // failures) embed fresh next run, so the snapshot has nothing left
        // to protect. Only a kill or a thrown batch leaves it in place
        // for the next call's restore.
        try? store.pool.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS vec_snapshot")
        }
        try? store.bumpEmbeddingsEpoch()
        // Drop the model on the way out — callers in long-lived processes
        // (watcher) must not keep ~1GB of MLModel alive between bursts.
        embedder = nil
        // Freed tensor/workspace pages stay in the malloc zones as dirty
        // memory; pressure relief hands them back to the OS so a watcher
        // actually shrinks after an embed burst instead of idling at
        // ~500MB RSS forever.
        malloc_zone_pressure_relief(nil, 0)
        return total
    }

    static let embedderBatchSize = 2_000

    /// Embeds up to `limit` unembedded chunks. `failed` accumulates chunk ids
    /// that produced no vector so callers can exclude them from later batches.
    /// Returns (rows attempted, vectors written).
    @discardableResult
    func embedPending(limit: Int, skip: Set<Int64> = [],
                      failed: inout Set<Int64>) throws -> (Int, Int) {
        let skipCond = skip.isEmpty ? ""
            : " AND c.id NOT IN (\(skip.map { String($0) }.joined(separator: ",")))"
        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, c.content, c.symbol, c.kind, f.path FROM chunks c
                JOIN files f ON f.id = c.file_id
                LEFT JOIN embeddings e ON e.chunk_id = c.id
                WHERE e.chunk_id IS NULL\(skipCond) LIMIT ?
                """, arguments: [limit])
        }
        guard !rows.isEmpty else { return (0, 0) }
        // Compute vectors outside the write transaction: embedding inference is
        // the slow part, and holding the write lock during it starves readers.
        var vectors: [(Int64, Int, Data)] = []
        vectors.reserveCapacity(rows.count)
        for row in rows {
            guard let cid = row["id"] as? Int64,
                  let content = row["content"] as? String else { continue }
            // Embed path + symbol + kind context: disambiguates same-named
            // symbols across files and grounds code in its module.
            let symbol = row["symbol"] as? String
            let path = (row["path"] as? String) ?? ""
            let kind = (row["kind"] as? String) ?? ""
            let text = (path + "\n" + (symbol ?? kind) + "\n" + content).prefix(1800)
            guard let vec = requireEmbedder().embed(String(text)) else { failed.insert(cid); continue }
            vectors.append((cid, vec.count, vec.withUnsafeBytes { Data($0) }))
        }
        try store.pool.write { db in
            for (cid, dim, blob) in vectors {
                try db.execute(sql: "INSERT OR REPLACE INTO embeddings(chunk_id, dim, vec) VALUES(?,?,?)",
                               arguments: [cid, dim, blob])
            }
        }
        try? store.bumpEmbeddingsEpoch()
        return (rows.count, vectors.count)
    }
}

private extension Array {
    func nilIfEmpty() -> Self? { isEmpty ? nil : self }
}
