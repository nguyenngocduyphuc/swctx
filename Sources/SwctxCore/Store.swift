import Foundation
import GRDB
import CryptoKit

/// One SQLite database per indexed workspace, stored under ~/.swctx/indexes/<key>/.
public final class Store: @unchecked Sendable {
    public let pool: DatabasePool
    public let workspaceRoot: URL
    public let workspaceKey: String
    /// Per-index embedding model binding from `meta` — nil on legacy indexes
    /// (pre-binding DBs, implicitly bge-base-en/768). Set at index creation;
    /// read by search/embed paths so each index runs its own vector space.
    public private(set) var embeddingModel: String?
    public private(set) var embeddingDim: Int?
    /// `meta.trigram` — substring fallback leg opt-in (off by default).
    public private(set) var trigramEnabled = false

    public static let schemaVersion = 6

    public static func key(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func baseDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".swctx", isDirectory: true)
    }

    public static func indexURL(forKey key: String) -> URL {
        baseDir().appendingPathComponent("indexes/\(key)/index.db")
    }

    /// Open (creating if needed) the index DB for a workspace root.
    /// The root is symlink-resolved so discovery and queries share one identity.
    public init(workspaceRoot: URL) throws {
        let root = workspaceRoot.resolvingSymlinksInPath()
        self.workspaceRoot = root
        self.workspaceKey = Store.key(for: root)
        let dir = Store.indexURL(forKey: workspaceKey).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(10)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: Store.indexURL(forKey: workspaceKey).path, configuration: config)
        try migrate()
        // Publish this index's embedding-model binding to the process-wide
        // selection (nil = legacy → revert to flag/env/default). Search and
        // embed paths resolve their model after opening the Store, so the
        // index's recorded vector space wins over global defaults.
        let binding = try pool.read { db -> (String?, String?) in
            (try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'embedding_model'"),
             try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'embedding_dim'"))
        }
        embeddingModel = binding.0
        embeddingDim = binding.1.flatMap { Int($0) }
        Embedder.bindModel(embeddingModel)
        trigramEnabled = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'trigram'") == "1"
        }
    }

    /// Record (or update) the index's embedding-model binding in `meta` and
    /// activate it for this process. Called by `swctx index`/`swctx embed`
    /// when an index is created or deliberately re-bound via `--reindex`.
    public func setEmbeddingBinding(modelID: String, dim: Int) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO meta(key, value)
                VALUES('embedding_model', ?), ('embedding_dim', ?)
                """, arguments: [modelID, String(dim)])
        }
        embeddingModel = modelID
        embeddingDim = dim
        Embedder.bindModel(modelID)
    }

    /// Opt-in substring index (`chunks_trigram` ~40-45% of DB size): the
    /// fallback leg and index-time population are both gated on this flag.
    public func setTrigramEnabled(_ on: Bool) throws {
        try pool.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO meta(key, value) VALUES('trigram', ?)",
                arguments: [on ? "1" : "0"])
        }
        trigramEnabled = on
    }

    /// Random-nonce epoch for the process-level vector cache: every writer
    /// that mutates chunks/embeddings bumps it once per run, so a cached
    /// matrix is validated by one tiny meta read instead of re-reading
    /// ~100MB of vec blobs per query.
    public func bumpEmbeddingsEpoch() throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO meta(key, value)
                VALUES('embeddings_epoch', hex(randomblob(8)))
                """)
        }
    }

    /// Cache-validation signature: the epoch nonce on indexes written by
    /// this build; a legacy count/id fingerprint on older ones (misses
    /// same-id re-embeds until the next index run writes a real epoch).
    public func embeddingsSignature() throws -> String {
        try pool.read { db in
            if let v = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key='embeddings_epoch'") {
                return v
            }
            let n = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0
            let m = try Int64.fetchOne(db, sql: "SELECT MAX(chunk_id) FROM embeddings") ?? 0
            return "legacy:\(n):\(m)"
        }
    }

    private func migrate() throws {
        // Skip the write entirely when the schema is already current, so plain
        // queries never open a write transaction on an existing index.
        let current = try? pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'")
        }
        if current == String(Store.schemaVersion) { return }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE files(
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    lang TEXT NOT NULL,
                    sha TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    indexed_at REAL NOT NULL);
                CREATE TABLE chunks(
                    id INTEGER PRIMARY KEY,
                    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                    idx INTEGER NOT NULL,
                    start_line INTEGER NOT NULL,
                    end_line INTEGER NOT NULL,
                    kind TEXT,
                    symbol TEXT,
                    content TEXT NOT NULL,
                    tokens INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX idx_chunks_file ON chunks(file_id);
                CREATE TABLE symbols(
                    id INTEGER PRIMARY KEY,
                    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                    chunk_id INTEGER REFERENCES chunks(id) ON DELETE SET NULL,
                    name TEXT NOT NULL,
                    kind TEXT,
                    line INTEGER NOT NULL,
                    signature TEXT);
                CREATE INDEX idx_symbols_name ON symbols(name);
                CREATE TABLE edges(
                    id INTEGER PRIMARY KEY,
                    src_chunk INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                    dst_chunk INTEGER REFERENCES chunks(id) ON DELETE SET NULL,
                    dst_name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    line INTEGER NOT NULL);
                CREATE INDEX idx_edges_src ON edges(src_chunk);
                CREATE INDEX idx_edges_dst ON edges(dst_chunk);
                CREATE INDEX idx_edges_name ON edges(dst_name);
                CREATE TABLE embeddings(
                    chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
                    dim INTEGER NOT NULL,
                    vec BLOB NOT NULL);
                """)
            try db.create(virtualTable: "chunks_fts", using: FTS5()) { t in
                t.column("content")
                t.column("symbol")
                t.column("path")
            }
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE records(
                    id INTEGER PRIMARY KEY,
                    kind TEXT NOT NULL,
                    source TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'completed',
                    title TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    created_at REAL NOT NULL);
                """)
            // External-content FTS over records(title, payload); GRDB's
            // synchronize() emits content='records' plus __records_fts_ai/ad/au
            // triggers, so writes to records keep the index in sync.
            try db.create(virtualTable: "records_fts", using: FTS5()) { t in
                t.column("title")
                t.column("payload")
                t.synchronize(withTable: "records")
            }
            // Receiver/module qualifier for call edges (`m` in `m.f()`);
            // NULL = unqualified bare call. Column exists ahead of the
            // Analyzer EdgeDraft.qualifier field that will populate it.
            try db.execute(sql: "ALTER TABLE edges ADD COLUMN qualifier TEXT")
        }
        migrator.registerMigration("v3") { db in
            // Normalized semantic symbol kind alongside the raw tree-sitter
            // node type (`symbols.kind`); tool output reports norm + raw.
            try db.execute(sql: "ALTER TABLE symbols ADD COLUMN norm_kind TEXT")
        }
        migrator.registerMigration("v4") { db in
            // Record staleness evidence: git HEAD at capture + a compact
            // JSON array of anchors (symbol names / file paths the record
            // mentions). NULL = nothing verifiable — reads never flag on
            // head movement alone.
            try db.execute(sql: "ALTER TABLE records ADD COLUMN head_sha TEXT")
            try db.execute(sql: "ALTER TABLE records ADD COLUMN anchors TEXT")
        }
        migrator.registerMigration("v5") { db in
            // BM25F columns: split the old (content, symbol, path) fts
            // into (content, path_tokens, symbol_names) so bm25() can
            // weight each field (path/symbol matches outrank body hits).
            // Recreated + repopulated in place — no rebuild needed.
            try db.execute(sql: "DROP TABLE IF EXISTS chunks_fts")
            try db.create(virtualTable: "chunks_fts", using: FTS5()) { t in
                t.column("content")
                t.column("path_tokens")
                t.column("symbol_names")
            }
            // File-graph PageRank landing zone; Indexer recomputes it
            // after every resolveEdges pass (0 = unranked/legacy).
            try db.execute(sql:
                "ALTER TABLE files ADD COLUMN pagerank REAL NOT NULL DEFAULT 0")
            // Substring fallback leg. detail stays 'full': phrase queries
            // — the only form a trigram index answers — are rejected
            // under detail=column/none. The tokenizer folds case only;
            // remove_diacritics needs SQLite >= 3.45 (system libsqlite3
            // is older), so the query side adds folded variants instead.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE chunks_trigram
                USING fts5(content, tokenize='trigram')
                """)
            // Left empty: the trigram index costs ~40-45% of DB size and is
            // populated only when the index opts in via meta.trigram=1
            // (`swctx index --trigram`) — the fallback leg is gated on the
            // same flag, so the empty table costs nothing.
            // Repopulate chunks_fts from existing rows so migrated
            // indexes keep serving ranked FTS without a rebuild.
            var namesByChunk: [Int64: [String]] = [:]
            for r in try Row.fetchAll(db, sql:
                "SELECT chunk_id, name FROM symbols WHERE chunk_id IS NOT NULL") {
                guard let cid = r["chunk_id"] as? Int64,
                      let name = r["name"] as? String else { continue }
                namesByChunk[cid, default: []].append(name)
            }
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT c.id, c.content, c.symbol, f.path
                FROM chunks c JOIN files f ON f.id = c.file_id
                """)
            while let r = try cursor.next() {
                guard let cid = r["id"] as? Int64 else { continue }
                var seen: Set<String> = []
                let names = (((r["symbol"] as? String).map { [$0] } ?? [])
                    + (namesByChunk[cid] ?? []))
                    .filter { seen.insert($0).inserted }
                try db.execute(sql: """
                    INSERT INTO chunks_fts(rowid, content, path_tokens, symbol_names)
                    VALUES(?,?,?,?)
                    """, arguments: [
                        cid,
                        (r["content"] as? String) ?? "",
                        Search.pathTokenString((r["path"] as? String) ?? ""),
                        Search.symbolTokenString(names),
                    ])
            }
        }
        migrator.registerMigration("v6") { db in
            // Dedicated folded column: app-level foldText of every
            // searchable field. unicode61 remove_diacritics never folds
            // đ/Đ (U+0111 has no decomposition), so Vietnamese needs the
            // app-level fold — the same function folds query terms into
            // variant spellings (Search.ftsQuery). Column weight is
            // deliberately low (0.6): folded-only matches rescue diacritic
            // queries but cannot outrank real content/symbol hits, which
            // keeps variant noise out of the fused candidate window.
            try db.execute(sql: "DROP TABLE IF EXISTS chunks_fts")
            try db.create(virtualTable: "chunks_fts", using: FTS5()) { t in
                t.column("content")
                t.column("path_tokens")
                t.column("symbol_names")
                t.column("folded")
            }
            var namesByChunk: [Int64: [String]] = [:]
            for r in try Row.fetchAll(db, sql:
                "SELECT chunk_id, name FROM symbols WHERE chunk_id IS NOT NULL") {
                guard let cid = r["chunk_id"] as? Int64,
                      let name = r["name"] as? String else { continue }
                namesByChunk[cid, default: []].append(name)
            }
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT c.id, c.content, c.symbol, f.path
                FROM chunks c JOIN files f ON f.id = c.file_id
                """)
            while let r = try cursor.next() {
                guard let cid = r["id"] as? Int64 else { continue }
                var seen: Set<String> = []
                let names = (((r["symbol"] as? String).map { [$0] } ?? [])
                    + (namesByChunk[cid] ?? []))
                    .filter { seen.insert($0).inserted }
                let content = (r["content"] as? String) ?? ""
                let pathToks = Search.pathTokenString((r["path"] as? String) ?? "")
                let symToks = Search.symbolTokenString(names)
                try db.execute(sql: """
                    INSERT INTO chunks_fts(rowid, content, path_tokens, symbol_names, folded)
                    VALUES(?,?,?,?,?)
                    """, arguments: [
                        cid, content, pathToks, symToks,
                        Search.foldText(content + " " + pathToks + " " + symToks),
                    ])
            }
        }
        try migrator.migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?), ('workspace_root', ?), ('created_at', ?)",
                arguments: [String(Store.schemaVersion), workspaceRoot.path, String(Date().timeIntervalSince1970)])
            // Per-index embedding-model binding, recorded once at DB creation
            // from the caller's requested model (`--model` flag, SWCTX_MODEL,
            // or the default — never another open index's binding). Pre-
            // binding DBs keep the keys absent → implicit legacy bge/768.
            // The files==0 guard keeps a schema-migrated legacy index from
            // being mislabelled under whatever model is active mid-migration.
            let activeID = Embedder.requestedModelID
            let isFresh = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0) == 0
            if isFresh, let spec = Embedder.spec(for: activeID) {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('embedding_model', ?), ('embedding_dim', ?)",
                    arguments: [spec.id, String(spec.dim)])
            }
            // Backfill norm_kind for pre-v3 rows. `signature` (first decl
            // line) carries the keyword needed to split swift's umbrella
            // `class_declaration` into struct/enum/class/etc.
            if (try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM symbols WHERE norm_kind IS NULL") ?? 0) > 0 {
                let rows = try Row.fetchAll(db, sql:
                    "SELECT id, kind, signature FROM symbols WHERE norm_kind IS NULL")
                for r in rows {
                    try db.execute(
                        sql: "UPDATE symbols SET norm_kind = ? WHERE id = ?",
                        arguments: [
                            Languages.normKind(
                                (r["kind"] as? String) ?? "",
                                declText: r["signature"] as? String),
                            r["id"] as? Int64 ?? -1,
                        ])
                }
            }
        }
    }

    // MARK: - Records

    /// Per-kind ledger bounds — eviction removes the oldest rows OF THAT
    /// KIND only, so high-volume churn (context_pack/ask telemetry) can
    /// never push out agent-authored notes.
    public static let recordKindQuota: [String: Int] = [
        "context_pack": 500,
        "ask": 300,
        "note": 200,
        "finding": 200,
        "decision": 200,
        "todo": 200,
    ]
    public static let recordDefaultQuota = 100
    public static func recordQuota(for kind: String) -> Int {
        recordKindQuota[kind] ?? recordDefaultQuota
    }

    /// Insert one record and return its row id. The payload is JSON-encoded;
    /// the records_fts sync trigger indexes title + payload automatically.
    @discardableResult
    public func insertRecord(kind: String, source: String, title: String,
                             payload: [String: Any]) throws -> Int64 {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try insertRecord(kind: kind, source: source, status: "completed",
                                title: title,
                                payloadJSON: String(decoding: data, as: UTF8.self))
    }

    /// Compact anchors column: JSON array of strings, nil when empty so
    /// anchor-free records stay NULL (nothing verifiable → never stale).
    public static func encodeAnchors(_ anchors: [String]) -> String? {
        guard !anchors.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: anchors)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode the anchors column; missing/malformed JSON decodes empty.
    public static func decodeAnchors(_ json: String?) -> [String] {
        guard let json,
              let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                    as? [String]
        else { return [] }
        return arr
    }

    /// Insert one record with a pre-encoded payload (raw text or JSON) and
    /// explicit status, then apply the per-kind eviction bound. headSHA and
    /// anchors are the staleness evidence captured by put_record; both stay
    /// NULL for telemetry rows and non-git workspaces.
    @discardableResult
    public func insertRecord(kind: String, source: String, status: String,
                             title: String, payloadJSON: String,
                             headSHA: String? = nil,
                             anchors: [String]? = nil) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO records(kind, source, status, title, payload,
                                    created_at, head_sha, anchors)
                VALUES(?,?,?,?,?,?,?,?)
                """, arguments: [kind, source, status, title, payloadJSON,
                                 Date().timeIntervalSince1970, headSHA,
                                 Store.encodeAnchors(anchors ?? [])])
            let id = db.lastInsertedRowID
            try db.execute(sql: """
                DELETE FROM records WHERE kind = ? AND id NOT IN (
                    SELECT id FROM records WHERE kind = ?
                    ORDER BY id DESC LIMIT ?)
                """, arguments: [kind, kind, Store.recordQuota(for: kind)])
            return id
        }
    }

    // MARK: - Record staleness

    /// Batch staleness verdicts for one page of records. A record flags
    /// only when BOTH hold: the workspace git HEAD moved since capture
    /// AND ≥1 anchor stopped resolving in the current index (symbol gone
    /// from `symbols`, path gone from `files`). Head alone never flags —
    /// it moves on every commit — and anchor-free rows have nothing to
    /// verify against. One git probe per call, then at most two batched
    /// IN() lookups for the whole page (not per record).
    public func staleCheck(_ rows: [(headSHA: String?, anchors: [String])])
        -> [(stale: Bool, reasons: [String])] {
        let fresh: (stale: Bool, reasons: [String]) = (false, [])
        // Cheap gate: no row carries both evidence fields → nothing to do.
        guard rows.contains(where: { !($0.headSHA ?? "").isEmpty && !$0.anchors.isEmpty }),
              let head = GlobalRecords.git(["rev-parse", "HEAD"], cwd: workspaceRoot),
              !head.isEmpty
        else { return rows.map { _ in fresh } }
        var moved = Set<Int>()
        var symNeed = Set<String>(), pathNeed = Set<String>()
        for (i, r) in rows.enumerated() {
            guard let h = r.headSHA, !h.isEmpty, h != head, !r.anchors.isEmpty
            else { continue }
            moved.insert(i)
            for a in r.anchors {
                if a.contains("/") { pathNeed.insert(a) } else { symNeed.insert(a) }
            }
        }
        guard !moved.isEmpty else { return rows.map { _ in fresh } }
        // A failed lookup must not flag — unresolved-on-error reads as
        // "no evidence", not "everything broke".
        guard let resolved = try? pool.read({ db -> (Set<String>, Set<String>) in
            var syms = Set<String>(), paths = Set<String>()
            if !symNeed.isEmpty {
                let ph = symNeed.map { _ in "?" }.joined(separator: ",")
                syms = Set(try String.fetchAll(db, sql:
                    "SELECT name FROM symbols WHERE name IN (\(ph))",
                    arguments: StatementArguments(
                        symNeed.map { $0 as DatabaseValueConvertible })))
            }
            if !pathNeed.isEmpty {
                let ph = pathNeed.map { _ in "?" }.joined(separator: ",")
                paths = Set(try String.fetchAll(db, sql:
                    "SELECT path FROM files WHERE path IN (\(ph))",
                    arguments: StatementArguments(
                        pathNeed.map { $0 as DatabaseValueConvertible })))
            }
            return (syms, paths)
        }) else { return rows.map { _ in fresh } }
        let (liveSyms, livePaths) = resolved
        return rows.indices.map { i in
            guard moved.contains(i) else { return fresh }
            let missing = rows[i].anchors.filter {
                $0.contains("/") ? !livePaths.contains($0) : !liveSyms.contains($0)
            }
            guard !missing.isEmpty else { return fresh }
            let old = rows[i].headSHA ?? ""
            return (true,
                    ["head moved \(old.prefix(7))→\(head.prefix(7))"]
                        + missing.map { "anchor '\($0)' no longer resolves" })
        }
    }

    // MARK: - Registry (~/.swctx/workspaces.json)

    public struct WorkspaceEntry: Codable, Sendable {
        public var path: String
        public var key: String
        public var lastIndexedAt: Double
    }

    public static func registryURL() -> URL {
        baseDir().appendingPathComponent("workspaces.json")
    }

    public static func loadRegistry() -> [WorkspaceEntry] {
        guard let data = try? Data(contentsOf: registryURL()),
              let entries = try? JSONDecoder().decode([WorkspaceEntry].self, from: data)
        else { return [] }
        return entries
    }

    public static func saveRegistry(_ entries: [WorkspaceEntry]) {
        let dir = baseDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: registryURL(), options: .atomic)
        }
    }

    public static func register(root: URL) {
        var entries = loadRegistry()
        let key = Store.key(for: root)
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].lastIndexedAt = Date().timeIntervalSince1970
        } else {
            entries.append(WorkspaceEntry(path: root.path, key: key,
                                          lastIndexedAt: Date().timeIntervalSince1970))
        }
        saveRegistry(entries)
    }
}
