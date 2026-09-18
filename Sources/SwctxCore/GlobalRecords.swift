import Foundation
import GRDB

/// Repo-wide records ledger at ~/.swctx/records.db — same columns as the
/// per-workspace records table plus `ws`, the repo-identity key (Store.key
/// of the main checkout). Every git worktree of one repository shares `ws`,
/// so agent-authored records follow the repo, not the checkout.
public final class GlobalRecords: @unchecked Sendable {
    public let pool: DatabasePool

    /// Shared ledger; nil when ~/.swctx is not writable — global operations
    /// then degrade silently to workspace-only.
    public static let shared = try? GlobalRecords()

    public static func dbURL() -> URL {
        Store.baseDir().appendingPathComponent("records.db")
    }

    public init() throws {
        try FileManager.default.createDirectory(
            at: Store.baseDir(), withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(10)
        pool = try DatabasePool(path: Self.dbURL().path, configuration: config)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS records(
                    id INTEGER PRIMARY KEY,
                    ws TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    source TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'completed',
                    title TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    head_sha TEXT,
                    anchors TEXT);
                """)
            // In-place upgrade for ledgers created before the staleness
            // columns existed — same columns as the workspace records
            // table (Store schema v4).
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(records)")
                .compactMap { $0["name"] as? String }
            for col in ["head_sha", "anchors"] where !cols.contains(col) {
                try db.execute(
                    sql: "ALTER TABLE records ADD COLUMN \(col) TEXT")
            }
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS idx_records_ws ON records(ws)")
            try db.create(virtualTable: "records_fts", ifNotExists: true,
                          using: FTS5()) { t in
                t.column("title")
                t.column("payload")
                t.synchronize(withTable: "records")
            }
        }
    }

    /// Insert one shared record; the per-(ws, kind) quota mirrors Store's.
    /// headSHA/anchors are the same staleness evidence put_record writes
    /// to the workspace ledger.
    @discardableResult
    public func insert(ws: String, kind: String, source: String, status: String,
                       title: String, payload: String,
                       headSHA: String? = nil,
                       anchors: [String]? = nil) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO records(ws, kind, source, status, title, payload,
                                    created_at, head_sha, anchors)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, arguments: [ws, kind, source, status, title, payload,
                                 Date().timeIntervalSince1970, headSHA,
                                 Store.encodeAnchors(anchors ?? [])])
            let id = db.lastInsertedRowID
            try db.execute(sql: """
                DELETE FROM records WHERE ws = ? AND kind = ? AND id NOT IN (
                    SELECT id FROM records WHERE ws = ? AND kind = ?
                    ORDER BY id DESC LIMIT ?)
                """, arguments: [ws, kind, ws, kind, Store.recordQuota(for: kind)])
            return id
        }
    }

    /// Repo identity for `ws`: the main checkout's Store.key. In a linked
    /// worktree `git rev-parse --git-common-dir` resolves back to the main
    /// checkout's .git dir, so all worktrees of one repo share the key.
    /// Non-git dirs (or any git failure) keep the workspace's own key.
    public static func repoKey(for workspaceRoot: URL) -> String {
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        return Store.key(for: mainCheckout(of: root) ?? root)
    }

    static func mainCheckout(of root: URL) -> URL? {
        guard let out = git(["rev-parse", "--git-common-dir"], cwd: root),
              !out.isEmpty else { return nil }
        let url = out.hasPrefix("/")
            ? URL(fileURLWithPath: out)
            : root.appendingPathComponent(out)
        let common = url.resolvingSymlinksInPath().standardizedFileURL
        // Standard layout: the common dir is <main>/.git — its parent is the
        // main checkout. Anything else (bare repo, submodule git dir,
        // custom GIT_DIR) leaves the workspace as its own identity.
        guard common.lastPathComponent == ".git" else { return root }
        return common.deletingLastPathComponent()
    }

    /// `git args` in `cwd` → trimmed stdout on exit 0; nil on missing git,
    /// non-zero exit, or a >5s stall. /usr/bin/env finds git on any PATH.
    static func git(_ args: [String], cwd: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = cwd
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + .seconds(5)) == .timedOut {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                      as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
