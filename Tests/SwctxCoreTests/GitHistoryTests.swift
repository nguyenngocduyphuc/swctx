import XCTest
@testable import SwctxCore
import GRDB

/// Git history → records ledger: non-git workspaces ingest nothing,
/// commits dedupe on re-run, and a workspace nested inside a parent
/// repo records workspace-relative paths (prefix stripped).
final class GitHistoryTests: SwctxTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    private func git(_ args: [String], cwd: URL) -> String? {
        GlobalRecords.git(args, cwd: cwd)
    }

    private func commit(_ dir: URL, _ msg: String) {
        _ = git(["add", "-A"], cwd: dir)
        _ = git(["-c", "user.email=swctx@test", "-c", "user.name=swctx",
                 "-c", "commit.gpgsign=false", "commit", "-m", msg], cwd: dir)
    }

    private func commitTitles(_ store: Store) -> [String] {
        (try? store.pool.read { db in
            try String.fetchAll(db, sql:
                "SELECT title FROM records WHERE kind='commit' ORDER BY id")
        }) ?? []
    }

    /// A plain directory is not a repo (and is not nested in one on a
    /// sane CI/tmp): ingest is a no-op, no commit rows appear.
    func testNonGitWorkspaceIngestsNothing() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("def f():\n    return 1\n", to: dir.appendingPathComponent("a.py"))
        let store = try Store(workspaceRoot: dir)
        XCTAssertEqual(GitHistory.ingest(store: store), 0)
        XCTAssertEqual(commitTitles(store), [])
    }

    /// A repo workspace ingests each commit once: `<sha12> <subject>`
    /// title, files in payload, and a second run inserts zero.
    func testIngestDedupesOnSecondRun() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard git(["init"], cwd: dir) != nil else {
            throw XCTSkip("git unavailable in test environment")
        }
        try write("def f():\n    return 1\n", to: dir.appendingPathComponent("a.py"))
        commit(dir, "add f")
        try write("def g():\n    return 2\n", to: dir.appendingPathComponent("b.py"))
        commit(dir, "add g")

        let store = try Store(workspaceRoot: dir)
        let n = GitHistory.ingest(store: store)
        XCTAssertEqual(n, 2)
        let titles = commitTitles(store)
        XCTAssertEqual(titles.count, 2)
        XCTAssertTrue(titles.contains { $0.hasSuffix(" add f") })
        XCTAssertTrue(titles.contains { $0.hasSuffix(" add g") })

        // Payload carries the touched file.
        let payload = try store.pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT payload FROM records
                WHERE kind='commit' AND title LIKE '% add g'
                """)
        }
        XCTAssertTrue(payload?.contains("\"b.py\"") ?? false)

        // Incremental head stored → re-run is a no-op.
        XCTAssertEqual(GitHistory.ingest(store: store), 0)
        XCTAssertEqual(commitTitles(store).count, 2)
    }

    /// Workspace nested inside a parent repo: log is scoped to the
    /// subtree and recorded paths drop the `sub/` prefix.
    func testNestedWorkspaceStripsPrefix() throws {
        let repo = try makeDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        guard git(["init"], cwd: repo) != nil else {
            throw XCTSkip("git unavailable in test environment")
        }
        let sub = repo.appendingPathComponent("sub")
        try write("root file\n", to: repo.appendingPathComponent("root.txt"))
        try write("def f():\n    return 1\n",
                  to: sub.appendingPathComponent("a.py"))
        commit(repo, "init root+sub")

        let store = try Store(workspaceRoot: sub)
        let n = GitHistory.ingest(store: store)
        XCTAssertGreaterThanOrEqual(n, 1)
        let payload = try store.pool.read { db in
            try String.fetchOne(db, sql:
                "SELECT payload FROM records WHERE kind='commit' LIMIT 1")
        }
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.contains("\"a.py\"") ?? false,
                      "workspace-relative path expected, got \(payload ?? "nil")")
        XCTAssertFalse(payload?.contains("sub/a.py") ?? true,
                       "repo prefix must be stripped")
        XCTAssertFalse(payload?.contains("root.txt") ?? true,
                       "files outside the workspace must not be recorded")
    }
}
