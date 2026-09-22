import XCTest
@testable import SwctxCore
import GRDB

/// Operational fixes: `index --force` must preserve vectors of unchanged
/// chunks (the wipe used to cascade-delete every embedding and the bounded
/// embed batch only refilled a fraction), and the watcher must defer
/// reindexing while git holds the index lock.
final class IndexOpsTests: SwctxTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Force reindex deletes every file row and ON DELETE CASCADE takes
    /// the chunks' embeddings with it; chunks whose embedded text is
    /// unchanged must get their stored vector back.
    func testForceReindexPreservesVectors() throws {
        let embedder = Embedder()
        guard embedder.isAvailable else {
            throw XCTSkip("no embedding model available in test environment")
        }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def alpha():\n    return 1\n\ndef helper():\n    return alpha() + 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def beta():\n    return 2\n".write(
            to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        let indexer = Indexer(store: store, embedder: embedder)
        try indexer.run(force: true)

        // Replace whatever the model embedded with recognizable synthetic
        // vectors at the active dim, derived from content so same-text
        // chunks share a blob — restoration is then byte-observable.
        let dim = embedder.dimension
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM embeddings")
            for r in try Row.fetchAll(db, sql: "SELECT id, content FROM chunks") {
                guard let cid = r["id"] as? Int64,
                      let content = r["content"] as? String else { continue }
                var vec = [Float](repeating: 0, count: dim)
                vec[0] = Float(content.utf8.count)
                vec[1] = Float(content.utf8.first ?? 0)
                try db.execute(
                    sql: "INSERT INTO embeddings(chunk_id, dim, vec) VALUES(?,?,?)",
                    arguments: [cid, dim,
                                vec.withUnsafeBufferPointer { Data(buffer: $0) }])
            }
        }
        var beforeByContent: [String: (dim: Int64, vec: Data)] = [:]
        var beforeCount = 0
        try store.pool.read { db in
            for r in try Row.fetchAll(db, sql: """
                SELECT c.content, e.dim, e.vec
                FROM embeddings e JOIN chunks c ON c.id = e.chunk_id
                """) {
                beforeByContent[(r["content"] as? String) ?? ""] =
                    ((r["dim"] as? Int64) ?? -1, (r["vec"] as? Data) ?? Data())
                beforeCount += 1
            }
        }
        XCTAssertGreaterThan(beforeCount, 0)

        // Unchanged workspace: every vector comes back byte-identical.
        let report = try indexer.run(force: true)
        XCTAssertEqual(report.vectorsPreserved, beforeCount)
        XCTAssertEqual(report.pendingEmbeddings, 0)
        let after = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.content, e.dim, e.vec
                FROM embeddings e JOIN chunks c ON c.id = e.chunk_id
                """)
        }
        XCTAssertEqual(after.count, beforeCount)
        for r in after {
            let want = try XCTUnwrap(beforeByContent[(r["content"] as? String) ?? ""])
            XCTAssertEqual((r["dim"] as? Int64) ?? -1, want.dim)
            XCTAssertEqual((r["vec"] as? Data) ?? Data(), want.vec)
        }

        // A file edit: surviving chunks restore, rewritten ones re-embed —
        // either way the index ends with full vector coverage again.
        try "def beta():\n    return 99\n\ndef gamma():\n    return 3\n".write(
            to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        let report2 = try indexer.run(force: true)
        XCTAssertGreaterThan(report2.vectorsPreserved, 0)
        let counts = try store.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0)
        }
        XCTAssertEqual(counts.0, counts.1)
    }

    /// `swctx index` auto-embeds: a fresh run drains every pending chunk,
    /// not just a bounded first batch — pendingEmbeddings ends at 0.
    func testIndexAutoEmbedsAllPending() throws {
        let embedder = Embedder()
        guard embedder.isAvailable else {
            throw XCTSkip("no embedding model available in test environment")
        }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def alpha():\n    return 1\n\ndef helper():\n    return alpha() + 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def beta():\n    return 2\n".write(
            to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        let report = try Indexer(store: store, embedder: embedder).run(force: true)
        XCTAssertEqual(report.pendingEmbeddings, 0)
        XCTAssertGreaterThan(report.embeddedChunks, 0)
        let counts = try store.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0)
        }
        XCTAssertGreaterThan(counts.0, 0)
        XCTAssertEqual(counts.0, counts.1)
        XCTAssertEqual(report.embeddedChunks, counts.1)
    }

    /// `index --skip-embed` keeps the old bounded behavior: no embed pass
    /// runs, every chunk stays pending for a later `swctx embed`.
    func testIndexSkipEmbedLeavesPending() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def alpha():\n    return 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        let report = try Indexer(store: store).run(force: true, autoEmbed: false)
        XCTAssertEqual(report.embeddedChunks, 0)
        XCTAssertNil(report.embeddingModel)
        let chunks = try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
        }
        XCTAssertGreaterThan(chunks, 0)
        XCTAssertEqual(report.pendingEmbeddings, chunks)
    }

    /// Embed failure must not fail the index: a stored vector at a foreign
    /// dim trips embedAll's mixed-dim guard, the error lands in
    /// report.errors, and the still-uncovered chunk reports as pending.
    func testIndexEmbedFailureDoesNotFailIndex() throws {
        let embedder = Embedder()
        guard embedder.isAvailable else {
            throw XCTSkip("no embedding model available in test environment")
        }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def alpha():\n    return 1\n\ndef helper():\n    return alpha() + 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def beta():\n    return 2\n".write(
            to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        let indexer = Indexer(store: store, embedder: embedder)
        try indexer.run(force: true)
        let embedded = try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0
        }
        XCTAssertGreaterThanOrEqual(embedded, 2)

        // Corrupt one vector's dim (trips the mixed-dim guard next run)
        // and strip another chunk's vector (stays pending, honestly).
        try store.pool.write { db in
            try db.execute(sql: """
                UPDATE embeddings SET dim = dim + 1
                WHERE chunk_id = (SELECT MIN(chunk_id) FROM embeddings)
                """)
            try db.execute(sql: """
                DELETE FROM embeddings
                WHERE chunk_id = (SELECT MAX(chunk_id) FROM embeddings)
                """)
        }

        let report = try indexer.run(force: false)
        XCTAssertEqual(report.filesUnchanged, 2)
        XCTAssertEqual(report.embeddedChunks, 0)
        XCTAssertEqual(report.pendingEmbeddings, 1)
        XCTAssertTrue(report.errors.contains { $0.contains("dim") },
                      "expected dim-guard error, got \(report.errors)")
    }

    /// `.git` as a directory: the lock is `<root>/.git/index.lock`.
    func testGitLockPlainRepo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(IndexWatcher.gitLockPath(forRoot: dir))
        XCTAssertFalse(IndexWatcher.isGitLocked(root: dir))

        let git = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let lock = git.appendingPathComponent("index.lock")
        XCTAssertEqual(IndexWatcher.gitLockPath(forRoot: dir)?.path, lock.path)
        // A real .git without an in-flight operation is not locked.
        XCTAssertFalse(IndexWatcher.isGitLocked(root: dir))
        try "".write(to: lock, atomically: true, encoding: .utf8)
        XCTAssertTrue(IndexWatcher.isGitLocked(root: dir))
    }

    /// Worktree/submodule layout: `.git` is a file holding
    /// `gitdir: <path>` and the lock lives inside that real git dir —
    /// both absolute and root-relative forms resolve.
    func testGitLockWorktreeFile() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // Absolute gitdir, as `git worktree add` writes it.
        let gitdir = base.appendingPathComponent("main/.git/worktrees/wt1")
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        let wt = base.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(gitdir.path)\n".write(
            to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(IndexWatcher.gitLockPath(forRoot: wt)?.path,
                       gitdir.appendingPathComponent("index.lock").path)
        XCTAssertFalse(IndexWatcher.isGitLocked(root: wt))
        try "".write(to: gitdir.appendingPathComponent("index.lock"),
                     atomically: true, encoding: .utf8)
        XCTAssertTrue(IndexWatcher.isGitLocked(root: wt))

        // Root-relative gitdir resolves against the workspace root.
        let rel = base.appendingPathComponent("rel-wt")
        try FileManager.default.createDirectory(at: rel, withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/wt1\n".write(
            to: rel.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(IndexWatcher.gitLockPath(forRoot: rel)?.path,
                       gitdir.appendingPathComponent("index.lock").path)
        XCTAssertTrue(IndexWatcher.isGitLocked(root: rel))
    }
}
