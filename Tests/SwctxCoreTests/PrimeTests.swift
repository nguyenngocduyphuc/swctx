import XCTest
@testable import SwctxCore
import GRDB

final class PrimeTests: XCTestCase {

    /// Indexes a tiny temp workspace and returns (dir, store); caller
    /// cleans up `dir` via defer.
    private func makeWorkspace() throws -> (URL, Store) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "def alpha():\n    return beta()\ndef beta():\n    return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try "const run = () => alpha();\n".write(
            to: dir.appendingPathComponent("m.js"), atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        return (dir, store)
    }

    /// The card renders heading + counts and does not crash on a fresh
    /// index whose records table is empty.
    func testPrimeCardBasics() throws {
        let (dir, store) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(card.contains("## \(dir.lastPathComponent)"))
        XCTAssertTrue(card.contains("Index:"))
        XCTAssertTrue(card.contains("2 files"))
        XCTAssertTrue(card.contains("schema v\(Store.schemaVersion)"))
        XCTAssertTrue(card.contains("Freshness: 0 stale"))
        XCTAssertTrue(card.contains("Warnings:"))
        // Empty records table -> no Recent section, no crash.
        XCTAssertFalse(card.contains("Recent:"))
    }

    /// Records appear newest-first under Recent; a changed file surfaces
    /// as a stale warning.
    func testPrimeCardRecordsAndWarnings() throws {
        let (dir, store) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.insertRecord(kind: "ask", source: "test",
                               title: "first question", payload: [:])
        try store.insertRecord(kind: "context_pack", source: "test",
                               title: "second pack", payload: [:])

        var card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(card.contains("Recent:"))
        let second = card.range(of: "- context_pack: second pack")
        let first = card.range(of: "- ask: first question")
        XCTAssertNotNil(second)
        XCTAssertNotNil(first)
        XCTAssertLessThan(second!.lowerBound, first!.lowerBound)

        // Touch a file -> shallow freshness flags it changed -> warning.
        try "def alpha():\n    return 42\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(card.contains("Freshness: 1 stale"))
        XCTAssertTrue(card.contains("stale files — run `swctx index`"))
    }

    /// A fresh session must notice prior work in the shared ledger:
    /// the newest agent-authored record surfaces on the card (with the
    /// scope=global pointer), dual-written local rows don't double up.
    func testPrimeSurfacesSharedLedgerPriorWork() throws {
        guard let g = GlobalRecords.shared else {
            throw XCTSkip("global ledger unavailable")
        }
        let (dir, store) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = GlobalRecords.repoKey(for: dir)
        defer {
            try? g.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM records WHERE ws = ?", arguments: [ws])
            }
        }
        let title = "orca teardown \(UUID().uuidString.prefix(8))"
        try g.insert(ws: ws, kind: "finding", source: "test",
                     status: "completed", title: title, payload: "{}")

        let snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        let prior = try XCTUnwrap(snap["prior_work"] as? [[String: Any]])
        XCTAssertTrue(prior.contains { ($0["title"] as? String) == title })
        XCTAssertTrue((snap["prior_work_total"] as? Int ?? 0) >= 1)
        let card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(card.contains("Prior work"))
        XCTAssertTrue(card.contains(title))
        XCTAssertTrue(card.contains("scope=global"))
    }

    /// snapshot emits JSON-safe values for --format json consumers.
    func testPrimeSnapshotJSON() throws {
        let (dir, store) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        XCTAssertEqual(snap["files"] as? Int, 2)
        XCTAssertEqual(snap["stale_files"] as? Int, 0)
        XCTAssertNotNil(snap["hub_symbols"])
        let data = try JSONSerialization.data(withJSONObject: snap)
        XCTAssertFalse(data.isEmpty)
    }
}
