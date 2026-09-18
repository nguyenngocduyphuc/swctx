import Foundation
import GRDB
import CryptoKit

/// One SQLite database per indexed workspace, stored under ~/.swctx/indexes/<key>/.
public final class Store: @unchecked Sendable {
    public let pool: DatabasePool
    public let workspaceRoot: URL
    public let workspaceKey: String

    public static let schemaVersion = 3

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
        try migrator.migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?), ('workspace_root', ?), ('created_at', ?)",
                arguments: [String(Store.schemaVersion), workspaceRoot.path, String(Date().timeIntervalSince1970)])
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

    /// Insert one record with a pre-encoded payload (raw text or JSON) and
    /// explicit status, then apply the per-kind eviction bound.
    @discardableResult
    public func insertRecord(kind: String, source: String, status: String,
                             title: String, payloadJSON: String) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO records(kind, source, status, title, payload, created_at)
                VALUES(?,?,?,?,?,?)
                """, arguments: [kind, source, status, title, payloadJSON,
                                 Date().timeIntervalSince1970])
            let id = db.lastInsertedRowID
            try db.execute(sql: """
                DELETE FROM records WHERE kind = ? AND id NOT IN (
                    SELECT id FROM records WHERE kind = ?
                    ORDER BY id DESC LIMIT ?)
                """, arguments: [kind, kind, Store.recordQuota(for: kind)])
            return id
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
