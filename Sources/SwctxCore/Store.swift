import Foundation
import GRDB
import CryptoKit

/// One SQLite database per indexed workspace, stored under ~/.swctx/indexes/<key>/.
public final class Store: @unchecked Sendable {
    public let pool: DatabasePool
    public let workspaceRoot: URL
    public let workspaceKey: String

    public static let schemaVersion = 2

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
        try migrator.migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?), ('workspace_root', ?), ('created_at', ?)",
                arguments: [String(Store.schemaVersion), workspaceRoot.path, String(Date().timeIntervalSince1970)])
        }
    }

    // MARK: - Records

    /// Insert one record and return its row id. The payload is JSON-encoded;
    /// the records_fts sync trigger indexes title + payload automatically.
    @discardableResult
    public func insertRecord(kind: String, source: String, title: String,
                             payload: [String: Any]) throws -> Int64 {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(decoding: data, as: UTF8.self)
        return try pool.write { db in
            try db.execute(sql: """
                INSERT INTO records(kind, source, title, payload, created_at)
                VALUES(?,?,?,?,?)
                """, arguments: [kind, source, title, json,
                                 Date().timeIntervalSince1970])
            let id = db.lastInsertedRowID
            // Bound the ledger: keep the newest 1000 rows per workspace.
            try db.execute(sql: """
                DELETE FROM records WHERE id NOT IN (
                    SELECT id FROM records ORDER BY id DESC LIMIT 1000)
                """)
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
