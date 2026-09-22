import XCTest
@testable import SwctxCore
import GRDB
import MCP

/// Fleet memory: put_record dual-write (workspace ledger + repo-wide shared
/// ledger), per-kind record quotas, scoped list/search reads, and the
/// non-git repoKey fallback.
final class FleetMemoryTests: SwctxTestCase {
    /// Temp workspace with an index (the records table requires schema v2+).
    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-fleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "def f():\n    return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)
        return dir
    }

    /// Remove this test's rows from the real shared ledger — test
    /// workspaces get unique repo keys, so nothing else is touched.
    private func cleanupGlobal(ws: String) {
        try? GlobalRecords.shared?.pool.write { db in
            try db.execute(sql: "DELETE FROM records WHERE ws = ?", arguments: [ws])
        }
    }

    private func jsonDict(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    /// put_record returns record_id/kind/scope; the row lands in the
    /// workspace records table AND the shared ledger under the repo key.
    func testPutRecordRoundTrip() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = GlobalRecords.repoKey(for: dir)
        defer { cleanupGlobal(ws: ws) }

        let out = try await SwctxTools.call(name: "put_record", arguments: [
            "workspace": .string(dir.path), "kind": .string("note"),
            "title": .string("deploy quirk"),
            "payload": .string("puma restart clears it"),
        ])
        let payload = try jsonDict(out)
        let id = try XCTUnwrap(payload["record_id"] as? Int)
        XCTAssertEqual(payload["kind"] as? String, "note")

        // Workspace copy is readable via get_record.
        let got = try await SwctxTools.call(name: "get_record", arguments: [
            "workspace": .string(dir.path), "id": .int(id)])
        let rec = try XCTUnwrap(
            (try jsonDict(got))["record"] as? [String: Any])
        XCTAssertEqual(rec["title"] as? String, "deploy quirk")
        XCTAssertEqual(rec["payload"] as? String, "puma restart clears it")
        XCTAssertEqual(rec["source"] as? String, "mcp")
        XCTAssertEqual(rec["status"] as? String, "completed")

        // Shared-ledger copy tagged with the repo identity.
        guard let global = GlobalRecords.shared else {
            throw XCTSkip("global ledger unavailable")
        }
        XCTAssertEqual(payload["scope"] as? String, "workspace+global")
        XCTAssertEqual(payload["ws"] as? String, ws)
        let titles = try await global.pool.read { db in
            try String.fetchAll(db, sql:
                "SELECT title FROM records WHERE ws = ?", arguments: [ws])
        }
        XCTAssertTrue(titles.contains("deploy quirk"))
    }

    /// Kinds outside the allowlist throw a clear error; every listed kind
    /// is accepted.
    func testPutRecordKindAllowlist() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { cleanupGlobal(ws: GlobalRecords.repoKey(for: dir)) }

        do {
            _ = try await SwctxTools.call(name: "put_record", arguments: [
                "workspace": .string(dir.path), "kind": .string("bogus"),
                "title": .string("t"), "payload": .string("p")])
            XCTFail("invalid kind must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("bogus"))
        }
        for kind in ["note", "finding", "decision", "todo", "context_pack", "ask"] {
            let out = try await SwctxTools.call(name: "put_record", arguments: [
                "workspace": .string(dir.path), "kind": .string(kind),
                "title": .string("t-\(kind)"), "payload": .string("p")])
            XCTAssertNil(try jsonDict(out)["error"], "kind \(kind) rejected")
        }
    }

    /// Per-kind quota: >cap inserts of a telemetry kind evict only their
    /// own oldest rows — an agent-authored note is untouched.
    func testPerKindQuotaEviction() throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(workspaceRoot: dir)

        let noteID = try store.insertRecord(kind: "note", source: "test",
                                            title: "keep me", payload: ["x": 1])
        // Unlisted kinds get the default quota (100): 101 inserts evict one.
        for i in 0..<101 {
            try store.insertRecord(kind: "telemetry", source: "test",
                                   title: "ev-\(i)", payload: ["i": i])
        }
        let (noteAlive, telemetryCount, ev0) = try store.pool.read { db in
            let n = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM records WHERE id = ?", arguments: [noteID]) ?? 0
            let c = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM records WHERE kind = 'telemetry'") ?? 0
            let z = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM records WHERE title = 'ev-0'") ?? 0
            return (n, c, z)
        }
        XCTAssertEqual(noteAlive, 1)
        XCTAssertEqual(telemetryCount, 100)
        XCTAssertEqual(ev0, 0)  // oldest telemetry row evicted, note kept
    }

    /// scope=global reads the shared repo ledger; scope=all unions
    /// workspace-first with the dual-written copy deduped.
    func testGlobalScopeListing() async throws {
        guard GlobalRecords.shared != nil else {
            throw XCTSkip("global ledger unavailable")
        }
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = GlobalRecords.repoKey(for: dir)
        defer { cleanupGlobal(ws: ws) }

        _ = try await SwctxTools.call(name: "put_record", arguments: [
            "workspace": .string(dir.path), "kind": .string("finding"),
            "title": .string("fleet finding alpha"),
            "payload": .string("shared across worktrees")])
        // A global-only row (written by a peer worktree, say) rides along.
        _ = try GlobalRecords.shared?.insert(
            ws: ws, kind: "note", source: "mcp", status: "completed",
            title: "peer worktree note", payload: "came from another checkout")

        let g = try jsonDict(await {
            try await SwctxTools.call(name: "list_records", arguments: [
                "workspace": .string(dir.path), "scope": .string("global")])
        }())
        let gRecs = g["records"] as? [[String: Any]] ?? []
        XCTAssertTrue(gRecs.contains {
            ($0["title"] as? String) == "fleet finding alpha"
                && ($0["ws"] as? String) == ws })
        XCTAssertTrue(gRecs.contains {
            ($0["title"] as? String) == "peer worktree note" })

        // scope=all: workspace copy first, identical global copy deduped,
        // the global-only peer note appended after workspace rows.
        let all = try jsonDict(await {
            try await SwctxTools.call(name: "list_records", arguments: [
                "workspace": .string(dir.path), "scope": .string("all")])
        }())
        let allRecs = all["records"] as? [[String: Any]] ?? []
        XCTAssertEqual(
            allRecs.filter { ($0["title"] as? String) == "fleet finding alpha" }.count, 1)
        XCTAssertEqual(
            allRecs.filter { ($0["title"] as? String) == "peer worktree note" }.count, 1)
        if let peerIdx = allRecs.firstIndex(where: {
            ($0["title"] as? String) == "peer worktree note" }),
           let alphaIdx = allRecs.firstIndex(where: {
            ($0["title"] as? String) == "fleet finding alpha" }) {
            XCTAssertLessThan(alphaIdx, peerIdx)
        } else {
            XCTFail("expected both records in scope=all")
        }
        XCTAssertEqual(all["total"] as? Int, allRecs.count)

        // search_records honors scope too.
        let s = try jsonDict(await {
            try await SwctxTools.call(name: "search_records", arguments: [
                "workspace": .string(dir.path), "query": .string("peer worktree"),
                "scope": .string("global")])
        }())
        XCTAssertTrue((s["records"] as? [[String: Any]] ?? []).contains {
            ($0["title"] as? String) == "peer worktree note" })
        // The workspace ledger knows nothing of the peer note (prefix match
        // may still hit the finding's "worktrees" payload — assert the peer
        // row itself is absent).
        let wsSearch = try jsonDict(await {
            try await SwctxTools.call(name: "search_records", arguments: [
                "workspace": .string(dir.path), "query": .string("peer worktree")])
        }())
        XCTAssertFalse((wsSearch["records"] as? [[String: Any]] ?? []).contains {
            ($0["title"] as? String) == "peer worktree note" })
    }

    /// Non-git directory: no common-dir answer → the workspace's own key is
    /// the repo identity (records stay scoped to this workspace).
    func testNonGitFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-fleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(GlobalRecords.mainCheckout(of: dir.resolvingSymlinksInPath()))
        XCTAssertEqual(GlobalRecords.repoKey(for: dir),
                       Store.key(for: dir.resolvingSymlinksInPath()))
    }
}
