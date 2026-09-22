import XCTest
@testable import SwctxCore
import GRDB

/// Crash-resilience for damaged indexes: a corrupt index.db is moved to
/// `index.db.corrupt-<unix_ts>` and rebuilt empty instead of crashing the
/// CLI or the watchd daemon; `gc` runs `PRAGMA integrity_check` per index
/// and quarantines damaged dirs; `Indexer` stamps `meta.last_index_at`
/// for `watch status` freshness. All fixtures live under the shared
/// SWCTX_HOME test home — the real ~/.swctx is never touched.
final class CorruptionTests: SwctxTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Index dir for a workspace, computed exactly the way Store does.
    private func indexDir(for workspace: URL) -> URL {
        let key = Store.key(for: workspace.resolvingSymlinksInPath())
        return Store.indexURL(forKey: key).deletingLastPathComponent()
    }

    /// A file that looks like SQLite (valid header magic + page size)
    /// but whose b-tree page is garbage — trips SQLITE_CORRUPT /
    /// "database disk image is malformed" rather than NOTADB.
    private func malformedHeaderDB() -> Data {
        var header = Data(count: 100)
        header.replaceSubrange(0..<16, with: "SQLite format 3\0".utf8)
        header[16] = 0x10; header[17] = 0x00          // page size 4096
        header[18] = 1; header[19] = 1                // file format versions
        header[21] = 64; header[22] = 32; header[23] = 32
        header[31] = 2                                // db size = 2 pages
        header[59] = 1                                // UTF-8
        return header + Data(repeating: 0xAB, count: 4096 - 100 + 4096)
    }

    /// The result codes that must trigger quarantine vs propagate.
    func testCorruptionClassification() {
        XCTAssertTrue(Store.isCorruptionError(
            DatabaseError(resultCode: .SQLITE_CORRUPT)))
        XCTAssertTrue(Store.isCorruptionError(
            DatabaseError(resultCode: .SQLITE_NOTADB)))
        XCTAssertTrue(Store.isCorruptionError(
            DatabaseError(resultCode: .SQLITE_CORRUPT_INDEX)))
        XCTAssertTrue(Store.isCorruptionError(
            DatabaseError(resultCode: .SQLITE_IOERR,
                          message: "database disk image is malformed")))
        XCTAssertFalse(Store.isCorruptionError(
            DatabaseError(resultCode: .SQLITE_BUSY)))
        XCTAssertFalse(Store.isCorruptionError(
            DatabaseError(resultCode: .SQLITE_CANTOPEN)))
        XCTAssertFalse(Store.isCorruptionError(
            NSError(domain: "swctx-test", code: 1)))
    }

    /// Spec case: garbage bytes at index.db — Store must quarantine the
    /// file to `index.db.corrupt-<ts>` and open a fresh working store.
    func testGarbageDBQuarantinedAndRebuilt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = indexDir(for: dir)
        try FileManager.default.createDirectory(
            at: indexDir, withIntermediateDirectories: true)
        let db = indexDir.appendingPathComponent("index.db")
        try Data(repeating: 0xAB, count: 4096).write(to: db)
        // A stale WAL beside the garbage db follows it into quarantine.
        try Data(repeating: 0xCD, count: 128).write(
            to: indexDir.appendingPathComponent("index.db-wal"))

        let store = try Store(workspaceRoot: dir)   // must not throw
        defer {
            try? FileManager.default.removeItem(at: indexDir)
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: indexDir.deletingLastPathComponent().path)) ?? []
            for n in names where n.hasPrefix("\(store.workspaceKey).corrupt-") {
                try? FileManager.default.removeItem(
                    at: indexDir.deletingLastPathComponent()
                        .appendingPathComponent(n))
            }
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: indexDir.path)
        // The corrupt db dir itself keeps only the rebuilt files; the
        // moved-aside files carry the .corrupt-<ts> suffix in the same dir.
        XCTAssertTrue(names.contains("index.db"))
        XCTAssertTrue(names.contains { $0.hasPrefix("index.db.corrupt-") },
                      "expected quarantine file in \(names)")
        XCTAssertTrue(names.contains { $0.hasPrefix("index.db-wal.corrupt-") },
                      "expected quarantined WAL in \(names)")

        // Fresh store is fully working: schema migrated, reads/writes fine.
        let counts = try store.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? -1,
             try String.fetchOne(db, sql:
                "SELECT value FROM meta WHERE key = 'schema_version'"))
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, String(Store.schemaVersion))
    }

    /// Valid header + malformed interior exercises the SQLITE_CORRUPT
    /// branch (vs NOTADB for pure garbage) — same quarantine contract.
    func testMalformedDBQuarantinedAndRebuilt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = indexDir(for: dir)
        try FileManager.default.createDirectory(
            at: indexDir, withIntermediateDirectories: true)
        try malformedHeaderDB().write(
            to: indexDir.appendingPathComponent("index.db"))

        let store = try Store(workspaceRoot: dir)
        defer {
            try? FileManager.default.removeItem(at: indexDir)
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: indexDir.deletingLastPathComponent().path)) ?? []
            for n in names where n.hasPrefix("\(store.workspaceKey).corrupt-") {
                try? FileManager.default.removeItem(
                    at: indexDir.deletingLastPathComponent()
                        .appendingPathComponent(n))
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: indexDir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("index.db.corrupt-") },
                      "expected quarantine file in \(names)")
        XCTAssertEqual(try store.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM files")
        }, 0)
    }

    /// Reopening a healthy index must not quarantine anything — the
    /// retry path fires only on corruption.
    func testHealthyReopenLeavesNoQuarantineFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = indexDir(for: dir)
        defer { try? FileManager.default.removeItem(at: indexDir) }
        _ = try Store(workspaceRoot: dir)
        _ = try Store(workspaceRoot: dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: indexDir.path)
        XCTAssertFalse(names.contains { $0.contains(".corrupt-") },
                       "unexpected quarantine file in \(names)")
    }

    /// A non-corruption failure must propagate, not quarantine: index.db
    /// as a *directory* fails open with CANTOPEN — Store throws and the
    /// entry is left in place.
    func testNonCorruptionErrorPropagates() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = indexDir(for: dir)
        defer { try? FileManager.default.removeItem(at: indexDir) }
        try FileManager.default.createDirectory(
            at: indexDir.appendingPathComponent("index.db"),
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try Store(workspaceRoot: dir))
        let names = try FileManager.default.contentsOfDirectory(atPath: indexDir.path)
        XCTAssertFalse(names.contains { $0.contains(".corrupt-") },
                       "non-corruption error must not quarantine: \(names)")
    }

    /// `gc` integrity-checks every index dir: a healthy live index is
    /// untouched while a corrupt one is renamed `<key>.corrupt-<ts>` and
    /// dropped from the registry — dry-run reports but does not move.
    func testGcIntegrityCheckQuarantinesCorruptIndex() throws {
        let ws = try tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = try Store(workspaceRoot: ws)     // healthy index
        let healthyDir = indexDir(for: ws)
        defer { try? FileManager.default.removeItem(at: healthyDir) }

        let fm = FileManager.default
        let corruptKey = "deadbeefc0ffee"
        let corruptDir = Store.baseDir()
            .appendingPathComponent("indexes/\(corruptKey)")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        try malformedHeaderDB().write(
            to: corruptDir.appendingPathComponent("index.db"))
        defer {
            try? fm.removeItem(at: corruptDir)
            let names = (try? fm.contentsOfDirectory(
                atPath: corruptDir.deletingLastPathComponent().path)) ?? []
            for n in names where n.hasPrefix("\(corruptKey).corrupt-") {
                try? fm.removeItem(
                    at: corruptDir.deletingLastPathComponent()
                        .appendingPathComponent(n))
            }
        }

        // Registry: live workspace for the corrupt key + the healthy one.
        var reg = Store.loadRegistry()
        reg.append(Store.WorkspaceEntry(
            path: ws.path, key: corruptKey,
            lastIndexedAt: Date().timeIntervalSince1970))
        if !reg.contains(where: { $0.key == store.workspaceKey }) {
            reg.append(Store.WorkspaceEntry(
                path: ws.path, key: store.workspaceKey,
                lastIndexedAt: Date().timeIntervalSince1970))
        }
        Store.saveRegistry(reg)

        // Dry-run: corruption is reported, nothing is moved.
        let dry = Gc.run(yes: false, minAgeSeconds: 3600)
        XCTAssertGreaterThanOrEqual(dry["corrupt"] as? Int ?? 0, 1)
        XCTAssertEqual(dry["quarantined"] as? Int ?? 0, 0)
        XCTAssertTrue(fm.fileExists(atPath: corruptDir.path),
                      "dry-run must not quarantine")

        let report = Gc.run(yes: true, minAgeSeconds: 3600)
        XCTAssertGreaterThanOrEqual(report["integrity_checked"] as? Int ?? 0, 2)
        XCTAssertGreaterThanOrEqual(report["corrupt"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(report["quarantined"] as? Int ?? 0, 1)
        let reported = (report["corrupt_indexes"] as? [[String: Any]]) ?? []
        XCTAssertTrue(reported.contains { $0["key"] as? String == corruptKey },
                      "corrupt_indexes must list \(corruptKey): \(reported)")

        // Dir renamed aside; healthy index untouched.
        XCTAssertFalse(fm.fileExists(atPath: corruptDir.path))
        let siblings = try fm.contentsOfDirectory(
            atPath: corruptDir.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains {
            $0.hasPrefix("\(corruptKey).corrupt-")
        }, "expected quarantined dir in \(siblings)")
        XCTAssertTrue(fm.fileExists(atPath:
            healthyDir.appendingPathComponent("index.db").path))

        // Registry: corrupt key dropped, healthy live entry kept.
        let after = Store.loadRegistry()
        XCTAssertFalse(after.contains { $0.key == corruptKey })
        XCTAssertTrue(after.contains { $0.key == store.workspaceKey })
    }

    /// End of an index pass stamps `meta.last_index_at`/`last_index_files`;
    /// `watch status` renders them through the read-only freshness probe.
    func testIndexPassStampsFreshnessForWatchStatus() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer {
            try? FileManager.default.removeItem(at: indexDir(for: dir))
        }
        try "def alpha():\n    return 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true,
            encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true, autoEmbed: false)

        let meta = try store.pool.read { db in
            (try String.fetchOne(db, sql:
                "SELECT value FROM meta WHERE key = 'last_index_at'"),
             try String.fetchOne(db, sql:
                "SELECT value FROM meta WHERE key = 'last_index_files'"))
        }
        let ts = try XCTUnwrap(meta.0.flatMap(Double.init))
        XCTAssertEqual(ts, Date().timeIntervalSince1970, accuracy: 60)
        XCTAssertEqual(meta.1.flatMap(Int.init), 1)

        let note = Watchd.indexFreshness(for: dir.path)
        XCTAssertTrue(note.contains("last indexed"), note)
        XCTAssertTrue(note.contains("1 files"), note)

        // A workspace with no index reports as such — the read-only
        // probe must not create one.
        let bare = try tempDir()
        defer { try? FileManager.default.removeItem(at: bare) }
        XCTAssertEqual(Watchd.indexFreshness(for: bare.path), " — no index")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: indexDir(for: bare).path))
    }
}
