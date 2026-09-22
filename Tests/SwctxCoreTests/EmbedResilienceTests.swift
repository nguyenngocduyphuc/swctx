import XCTest
@testable import SwctxCore
import GRDB

/// `swctx embed --reindex` used to commit `DELETE FROM embeddings` before a
/// single replacement vector existed, then re-embed in bounded batches — a
/// SIGTERM mid-run (19 min into a real reindex) left the index with ZERO
/// vectors: the wipe was durable, the replacements weren't. The pre-wipe
/// `vec_snapshot` is now persistent, so the next embed pass re-attaches
/// whatever the killed run never rewrote (same-dim rows only — a model
/// switch falls through to fresh embeds at the active dim).
final class EmbedResilienceTests: SwctxTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Recognizable blob at `dim`: first two floats carry seeds so a
    /// restored vector is byte-identifiable (same pattern as IndexOpsTests).
    private func blob(dim: Int, _ a: Float, _ b: Float) -> Data {
        var vec = [Float](repeating: 0, count: dim)
        vec[0] = a
        vec[1] = b
        return vec.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func vectorsByChunk(_ store: Store) throws -> [Int64: Data] {
        try store.pool.read { db in
            var out: [Int64: Data] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT chunk_id, vec FROM embeddings") {
                guard let cid = r["chunk_id"] as? Int64 else { continue }
                out[cid] = r["vec"] as? Data
            }
            return out
        }
    }

    private func distinctDims(_ store: Store) throws -> [Int64] {
        try store.pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT DISTINCT dim FROM embeddings ORDER BY dim")
        }
    }

    private func chunkCount(_ store: Store) throws -> Int {
        try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
        }
    }

    private func tableExists(_ store: Store, _ name: String) throws -> Bool {
        try store.pool.read { db in
            (try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = ?
                """, arguments: [name]) ?? 0) > 0
        }
    }

    /// Index two tiny files with the real embedder, then overwrite every
    /// stored vector with a recognizable synthetic blob at the active dim —
    /// restores are byte-observable afterwards.
    private func indexedWorkspace() throws
        -> (dir: URL, store: Store, indexer: Indexer, dim: Int) {
        let embedder = Embedder()
        guard embedder.isAvailable else {
            throw XCTSkip("no embedding model available in test environment")
        }
        let dir = try tempDir()
        try "def alpha():\n    return 1\n\ndef helper():\n    return alpha() + 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def beta():\n    return 2\n".write(
            to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        let indexer = Indexer(store: store, embedder: embedder)
        try indexer.run(force: true)
        let dim = embedder.dimension
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM embeddings")
            for r in try Row.fetchAll(db, sql: "SELECT id, content FROM chunks") {
                guard let cid = r["id"] as? Int64,
                      let content = r["content"] as? String else { continue }
                try db.execute(
                    sql: "INSERT INTO embeddings(chunk_id, dim, vec) VALUES(?,?,?)",
                    arguments: [cid, dim,
                                blob(dim: dim, Float(content.utf8.count),
                                     Float(content.utf8.first ?? 0))])
            }
        }
        return (dir, store, indexer, dim)
    }

    private func cleanup(_ dir: URL, _ store: Store) {
        try? FileManager.default.removeItem(at: dir)
        // Index DBs live under ~/.swctx/indexes/<key>/, not the temp dir.
        try? FileManager.default.removeItem(
            at: Store.indexURL(forKey: store.workspaceKey).deletingLastPathComponent())
    }

    /// The incident: snapshot committed, `DELETE FROM embeddings` committed,
    /// then the process died before any batch finished. The next embed pass
    /// must put the old vectors back instead of leaving the index empty.
    func testKilledReindexRestoresBackedUpVectors() throws {
        let (dir, store, indexer, _) = try indexedWorkspace()
        defer { cleanup(dir, store) }
        let before = try vectorsByChunk(store)
        XCTAssertGreaterThan(before.count, 0)

        // Stage the kill state through the real path — these are the first
        // two statements `embedAll(reindex: true)` runs; "SIGTERM" lands
        // right after them, before a single batch commits.
        try indexer.snapshotEmbeddings()
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM embeddings")
        }
        XCTAssertTrue(try tableExists(store, "vec_snapshot"))
        XCTAssertEqual(try vectorsByChunk(store).count, 0)

        // The rerun (`swctx embed`) restores from the snapshot, embeds
        // nothing fresh, and cleans the snapshot up.
        XCTAssertEqual(0, try indexer.embedAll())
        XCTAssertEqual(0, try indexer.pendingEmbeddings())
        XCTAssertEqual(try vectorsByChunk(store), before)
        XCTAssertFalse(try tableExists(store, "vec_snapshot"))
    }

    /// A clean `--reindex` rewrites every vector and drops the backup — it
    /// may only linger when the run never reached the end.
    func testCompletedReindexReembedsAllAndDropsBackup() throws {
        let (dir, store, indexer, dim) = try indexedWorkspace()
        defer { cleanup(dir, store) }
        let chunks = try chunkCount(store)
        let before = try vectorsByChunk(store)
        XCTAssertGreaterThan(chunks, 0)

        XCTAssertEqual(chunks, try indexer.embedAll(reindex: true))
        XCTAssertEqual(0, try indexer.pendingEmbeddings())
        XCTAssertFalse(try tableExists(store, "vec_snapshot"))
        XCTAssertEqual(try distinctDims(store), [Int64(dim)])
        // Synthetic placeholders were replaced by real model output.
        XCTAssertNotEqual(try vectorsByChunk(store), before)
    }

    /// Kill landing AFTER some batches committed: the restore fills only
    /// chunks still missing a vector — committed batch rows keep their
    /// freshly-embedded vectors (INSERT OR IGNORE on the chunk_id PK).
    func testRestorePreservesVectorsCommittedBeforeTheKill() throws {
        let (dir, store, indexer, dim) = try indexedWorkspace()
        defer { cleanup(dir, store) }
        let before = try vectorsByChunk(store)
        let kept = try XCTUnwrap(before.keys.sorted().first)
        let fresh = blob(dim: dim, 4242, 7777)
        XCTAssertNotEqual(before[kept], fresh)

        try indexer.snapshotEmbeddings()
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM embeddings")
            // One "batch" made it before the kill.
            try db.execute(
                sql: "INSERT INTO embeddings(chunk_id, dim, vec) VALUES(?,?,?)",
                arguments: [kept, dim, fresh])
        }

        XCTAssertEqual(0, try indexer.embedAll())
        var after = try vectorsByChunk(store)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after[kept], fresh)
        after.removeValue(forKey: kept)
        var want = before
        want.removeValue(forKey: kept)
        XCTAssertEqual(after, want)
    }

    /// Killed model-switch reindex: the snapshot's dim doesn't match the
    /// active model, so nothing old is restorable — the pass must drop the
    /// useless snapshot and embed everything fresh at the active dim.
    func testForeignDimBackupIsSkippedAndReembeddedFresh() throws {
        let (dir, store, indexer, dim) = try indexedWorkspace()
        defer { cleanup(dir, store) }
        let oldDim = dim + 8
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM embeddings")
            for cid in try Int64.fetchAll(db, sql: "SELECT id FROM chunks") {
                try db.execute(
                    sql: "INSERT INTO embeddings(chunk_id, dim, vec) VALUES(?,?,?)",
                    arguments: [cid, oldDim, blob(dim: oldDim, 1, 2)])
            }
        }
        try indexer.snapshotEmbeddings()
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM embeddings")
        }

        let chunks = try chunkCount(store)
        XCTAssertEqual(chunks, try indexer.embedAll())
        XCTAssertEqual(0, try indexer.pendingEmbeddings())
        XCTAssertEqual(try distinctDims(store), [Int64(dim)])
        XCTAssertFalse(try tableExists(store, "vec_snapshot"))
    }

    /// No staged snapshot: embedAll stays the no-op it always was on a
    /// fully-embedded index — the recovery path must not touch it.
    func testEmbedAllWithoutBackupIsNoop() throws {
        let (dir, store, indexer, _) = try indexedWorkspace()
        defer { cleanup(dir, store) }
        let before = try vectorsByChunk(store)
        XCTAssertFalse(try tableExists(store, "vec_snapshot"))
        XCTAssertEqual(0, try indexer.embedAll())
        XCTAssertEqual(try vectorsByChunk(store), before)
    }
}
