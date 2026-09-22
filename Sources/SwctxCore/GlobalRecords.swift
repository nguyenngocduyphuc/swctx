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

    // MARK: - Ranked memory reads

    /// The newest ledger row for `ws` carrying a captured git HEAD — the
    /// baseline a session-resume diff anchors to. Any kind counts:
    /// checkpoint and put_record both stamp head_sha, so the base is the
    /// last agent contact, not just the last session_checkpoint. nil when
    /// this ws never left a git-stamped record (non-git dirs included).
    public func latestCheckpoint(ws: String) throws
        -> (kind: String, title: String, headSHA: String, createdAt: Double)? {
        try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT kind, title, head_sha, created_at FROM records
                WHERE ws = ? AND head_sha IS NOT NULL AND head_sha != ''
                ORDER BY id DESC LIMIT 1
                """, arguments: [ws])
        }.map { (kind: ($0["kind"] as? String) ?? "",
                 title: ($0["title"] as? String) ?? "",
                 headSHA: ($0["head_sha"] as? String) ?? "",
                 createdAt: ($0["created_at"] as? Double) ?? 0) }
    }

    /// Folded match terms: alnum-split → Search.foldText (diacritic + case
    /// + đ→d) → dedupe, ≥2 chars, ≤12 — same term shape ftsQuery emits.
    static func foldedTerms(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(Search.foldText)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
            .prefix(12).map { $0 }
    }

    /// Folded keyword relevance: +2 per distinct term hitting the title,
    /// +1 per term hitting the body (word-prefix semantics — "deploy"
    /// hits "deployment"), +2 when the folded term sequence appears as a
    /// phrase in the folded title. Diacritic-blind both ways, which the
    /// unicode61 records_fts index (case-fold only) cannot express.
    static func relevance(terms: [String], title: String,
                          payload: String) -> Double {
        func haystack(_ s: String) -> String {
            " " + Search.foldText(s)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ") + " "
        }
        let t = haystack(title), p = haystack(payload)
        var score = 0.0
        for term in terms {
            if t.contains(" \(term)") { score += 2 }
            if p.contains(" \(term)") { score += 1 }
        }
        if terms.count > 1,
           t.contains(" \(terms.joined(separator: " "))") { score += 2 }
        return score
    }

    /// Ranked read over the shared ledger — the memory layer behind
    /// `search_records` relevance (folded keyword score DESC) with
    /// recency (created_at, id) as the tiebreak. The ledger is
    /// quota-bounded, so scoring the newest `poolCap` rows under the
    /// filters in memory stays cheap while covering folded matches FTS
    /// misses. `ws` nil reads fleet-wide. Rows return recordDict-shaped
    /// dicts plus `score`.
    public func searchRanked(query: String, ws: String? = nil,
                             kinds: [String]? = nil,
                             source: String? = nil, status: String? = nil,
                             limit: Int = 50, offset: Int = 0,
                             poolCap: Int = 4000) throws -> [[String: Any]] {
        let terms = Self.foldedTerms(query)
        guard !terms.isEmpty else { return [] }
        var sql = """
            SELECT id, ws, kind, title, payload, created_at FROM records
            """
        var clauses: [String] = []
        var params: [DatabaseValueConvertible] = []
        if let ws, !ws.isEmpty { clauses.append("ws = ?"); params.append(ws) }
        if let kinds, !kinds.isEmpty {
            clauses.append(
                "kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
            params += kinds.map { $0 as DatabaseValueConvertible }
        }
        if let source, !source.isEmpty {
            clauses.append("source = ?"); params.append(source)
        }
        if let status, !status.isEmpty {
            clauses.append("status = ?"); params.append(status)
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(max(poolCap, limit + offset))
        let rows = try pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(params))
        }
        let scored = rows.compactMap { r -> (Row, Double)? in
            let s = Self.relevance(terms: terms,
                                   title: (r["title"] as? String) ?? "",
                                   payload: (r["payload"] as? String) ?? "")
            return s > 0 ? (r, s) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let a = ($0.0["created_at"] as? Double) ?? 0
            let b = ($1.0["created_at"] as? Double) ?? 0
            if a != b { return a > b }
            return (($0.0["id"] as? Int64) ?? 0) > (($1.0["id"] as? Int64) ?? 0)
        }
        return scored.dropFirst(max(0, offset)).prefix(max(1, limit)).map { (r, s) in
            var d: [String: Any] = [
                "id": (r["id"] as? Int64) ?? -1,
                "ws": (r["ws"] as? String) ?? "",
                "kind": (r["kind"] as? String) ?? "",
                "title": (r["title"] as? String) ?? "",
                "created_at": (r["created_at"] as? Double) ?? 0,
                "score": s,
            ]
            if let p = (r["payload"] as? String) {
                d["payload"] = (try? JSONSerialization.jsonObject(
                    with: Data(p.utf8))) ?? p
            }
            return d
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
    /// non-zero exit, or a >15s stall. /usr/bin/env finds git on any PATH.
    /// Both pipes drain concurrently with the wait (`git status
    /// --porcelain` on a big repo exceeds the 64KB pipe buffer — waiting
    /// for exit before reading deadlocks the child on a full pipe).
    /// Same discipline as `Watchd.launchctl`. `binary` is the test seam:
    /// pass an absolute path to run a stand-in for git.
    static func git(_ args: [String], cwd: URL,
                    binary: String = "git") -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [binary] + args
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
        // NSMutableData: class references — the drain closures mutate
        // through them without capturing vars (Sendable-safe).
        let outData = NSMutableData(), errData = NSMutableData()
        let drain = DispatchGroup()
        // Waits AND drains run on dedicated Threads, never GCD: under
        // parallel load a global() block can sit unscheduled — the waiter
        // then times out on an already-exited git, and an undrained pipe
        // would return status 0 with truncated output (worse than nil).
        // (terminationHandler is not a fix: NSTask.h leaves its execution
        // context undefined; Foundation has queued it on the same pool.)
        drain.enter()
        Thread {
            outData.append(out.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }.start()
        drain.enter()
        Thread {
            errData.append(err.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }.start()
        let sem = DispatchSemaphore(value: 0)
        Thread { p.waitUntilExit(); sem.signal() }.start()
        let timeout = ProcessInfo.processInfo.environment["SWCTX_GIT_TIMEOUT_S"]
            .flatMap(TimeInterval.init) ?? 15
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = sem.wait(timeout: .now() + .milliseconds(300))
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = drain.wait(timeout: .now() + .seconds(2))
            let e = String(decoding: errData as Data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var msg = "swctx: git \(args.joined(separator: " ")) "
                + "timed out after \(Int(timeout))s (cwd: \(cwd.path))"
            if !e.isEmpty { msg += ": \(e.suffix(400))" }
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
            return nil
        }
        _ = drain.wait(timeout: .now() + .seconds(5))
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: outData as Data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
