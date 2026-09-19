import XCTest
@testable import SwctxCore
import GRDB

/// IndexWatcher schema-drift contract: when the live index was migrated
/// past this binary's `Store.schemaVersion` (a newer `swctx index` ran
/// in place), the watcher must self-terminate so launchd respawns it
/// into the current binary instead of writing rows in the stale layout —
/// the pre-v6 watchers' empty `folded` writes were the incident.
final class WatcherDriftTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Newer index schema → exit (respawn into the newer binary).
    func testNewerIndexSchemaRequiresExit() {
        XCTAssertTrue(IndexWatcher.shouldExitForSchema(indexVersion: 7, binaryVersion: 6))
        XCTAssertTrue(IndexWatcher.shouldExitForSchema(
            indexVersion: Store.schemaVersion + 1, binaryVersion: Store.schemaVersion))
    }

    /// Matching schema → keep running (the normal case).
    func testEqualIndexSchemaDoesNotExit() {
        XCTAssertFalse(IndexWatcher.shouldExitForSchema(indexVersion: 6, binaryVersion: 6))
        XCTAssertFalse(IndexWatcher.shouldExitForSchema(
            indexVersion: Store.schemaVersion, binaryVersion: Store.schemaVersion))
    }

    /// Older index schema → keep running; Store.init migrates forward
    /// at open, so the watcher proceeds normally.
    func testOlderIndexSchemaDoesNotExit() {
        XCTAssertFalse(IndexWatcher.shouldExitForSchema(indexVersion: 5, binaryVersion: 6))
        XCTAssertFalse(IndexWatcher.shouldExitForSchema(
            indexVersion: Store.schemaVersion - 1, binaryVersion: Store.schemaVersion))
    }

    /// The version read takes the max of meta.schema_version and the
    /// grdb_migrations ledger: an older binary's migrate() rewrites the
    /// meta row down to its own version, but can never delete the newer
    /// migration's ledger row — the drift evidence must survive that.
    func testIndexSchemaVersionSurvivesMetaDowngrade() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(workspaceRoot: dir)
        defer {
            try? FileManager.default.removeItem(
                at: Store.indexURL(forKey: store.workspaceKey).deletingLastPathComponent())
        }
        let watcher = IndexWatcher(store: store)

        // Fresh index: meta row and applied ledger agree with the binary.
        XCTAssertEqual(watcher.indexSchemaVersion(), Store.schemaVersion)

        // Simulate the post-migration state after an older binary opened
        // the DB: ledger carries "v<N+1>", meta row rewritten down.
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES(?)",
                           arguments: ["v\(Store.schemaVersion + 1)"])
            try db.execute(sql: "UPDATE meta SET value = ? WHERE key = 'schema_version'",
                           arguments: [String(Store.schemaVersion - 1)])
        }
        guard let indexVersion = watcher.indexSchemaVersion() else {
            return XCTFail("indexSchemaVersion returned nil on a live index")
        }
        XCTAssertEqual(indexVersion, Store.schemaVersion + 1)
        XCTAssertTrue(IndexWatcher.shouldExitForSchema(
            indexVersion: indexVersion, binaryVersion: Store.schemaVersion))
    }
}
