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
        pool = try Self.openPool(at: Self.dbURL())
    }

    /// Ledger at an explicit path — the test seam; production uses dbURL().
    init(path: String) throws {
        pool = try Self.openPool(at: URL(fileURLWithPath: path))
    }

    private static func openPool(at url: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(10)
        let pool = try DatabasePool(path: url.path, configuration: config)
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
            // Fleet usage ledger: one row per MCP tools/call. Lives in the
            // global DB (not per-workspace indexes) so all workspaces share
            // it and no index schema bump is needed. `query` is truncated
            // at insert (~200 chars) — local-only data. `session` groups
            // calls from one MCP server process; `top_paths` is the JSON
            // top-5 hit paths for retrieval tools; `arg_path` is the
            // follow-up target (inspect_path.path / fetch_chunks chunk_ids)
            // so mined "implicit utility" labels are causally linked.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS usage_events(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    ws TEXT NOT NULL,
                    tool TEXT NOT NULL,
                    latency_ms INTEGER NOT NULL,
                    hits INTEGER,
                    ok INTEGER NOT NULL,
                    query TEXT,
                    session TEXT,
                    top_paths TEXT,
                    arg_path TEXT);
                """)
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS idx_usage_events_tool ON usage_events(tool)")
            // Column migrations for ledgers created before session/top_paths/
            // arg_path existed. CREATE IF NOT EXISTS won't add them.
            let ucols = try Row.fetchAll(db,
                sql: "PRAGMA table_info(usage_events)").map { $0["name"] as String }
            for c in ["session", "top_paths", "arg_path"] where !ucols.contains(c) {
                try db.execute(sql: "ALTER TABLE usage_events ADD COLUMN \(c) TEXT")
            }
        }
        return pool
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

    /// One MCP tools/call usage event. Callers wrap in try? — telemetry
    /// must never break a tool response. `query` is capped at 200 chars;
    /// `topPaths` is the JSON-encoded top-5 hit paths; `argPath` is the
    /// follow-up target argument (path or chunk_ids JSON).
    public func insertUsage(ws: String, tool: String, latencyMs: Int,
                            hits: Int?, ok: Bool, query: String?,
                            session: String? = nil, topPaths: String? = nil,
                            argPath: String? = nil) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage_events(ts, ws, tool, latency_ms, hits, ok, query,
                                         session, top_paths, arg_path)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """, arguments: [Date().timeIntervalSince1970, ws, tool, latencyMs,
                                 hits, ok, query.map { String($0.prefix(200)) },
                                 session, topPaths, argPath])
        }
    }

    /// `swctx stats` row: per-tool totals over usage_events.
    public struct UsageStat: Sendable {
        public let tool: String
        public let calls: Int
        public let errors: Int
        public let avgMs: Double
        public let p50Ms: Int
        public let p95Ms: Int
    }

    /// One zero-hit `search` query and how often it returned nothing.
    public struct ZeroHitQuery: Sendable {
        public let query: String
        public let count: Int
    }

    /// Per-tool usage aggregates, busiest first.
    public func usageStats() throws -> [UsageStat] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tool, COUNT(*) AS calls, SUM(1 - ok) AS errors,
                       AVG(latency_ms) AS avg_ms
                FROM usage_events GROUP BY tool ORDER BY calls DESC, tool
                """)
            return try rows.map { r in
                let tool = (r["tool"] as? String) ?? ""
                let lats = try Int.fetchAll(db, sql:
                    "SELECT latency_ms FROM usage_events WHERE tool = ? ORDER BY latency_ms",
                    arguments: [tool])
                return UsageStat(
                    tool: tool,
                    calls: (r["calls"] as? Int64).map(Int.init) ?? 0,
                    errors: (r["errors"] as? Int64).map(Int.init) ?? 0,
                    avgMs: (r["avg_ms"] as? Double) ?? 0,
                    p50Ms: Self.percentile(lats, 0.50),
                    p95Ms: Self.percentile(lats, 0.95))
            }
        }
    }

    /// Zero-hit search queries, most frequent first — the "agents asked,
    /// the index had nothing" list.
    public func zeroHitQueries(limit: Int = 20) throws -> [ZeroHitQuery] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT query, COUNT(*) AS c FROM usage_events
                WHERE tool = 'search' AND hits = 0 AND query IS NOT NULL
                GROUP BY query ORDER BY c DESC, query LIMIT ?
                """, arguments: [limit])
                .map { ZeroHitQuery(query: ($0["query"] as? String) ?? "",
                                    count: ($0["c"] as? Int64).map(Int.init) ?? 0) }
        }
    }

    /// Nearest-rank percentile over an ascending-sorted list; 0 when empty.
    static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1,
                      max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[idx]
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
        do {
            try p.run()
        } catch {
            // Transient spawn failure under parallel load — one retry after
            // a short beat. (StalenessTests flaked twice on this path.)
            usleep(50_000)
            do { try p.run() } catch { return nil }
        }
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
