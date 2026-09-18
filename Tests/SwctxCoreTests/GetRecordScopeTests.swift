import XCTest
@testable import SwctxCore

/// get_record scope dispatch: workspace ledger by default, repo-wide
/// global ledger under scope=global, workspace-first-then-global under
/// scope=all. The two ledgers are separate id namespaces — a dual-written
/// record has a different id in each.
final class GetRecordScopeTests: XCTestCase {
    /// Temp workspace with an index (the records table requires schema v2+).
    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-getrec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "def f():\n    return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)
        return dir
    }

    /// Existing directory that was never indexed — exercises the
    /// notIndexed → store=nil lenient path for global/all.
    private func makeUnindexedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-getrec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanupGlobal(ws: String) {
        try? GlobalRecords.shared?.pool.write { db in
            try db.execute(sql: "DELETE FROM records WHERE ws = ?", arguments: [ws])
        }
    }

    private func jsonDict(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    /// scope=global finds the shared-ledger copy by ITS OWN id (not the
    /// workspace id put_record returns) and emits the `ws` field;
    /// scope=all on the workspace id returns the workspace copy (no `ws`).
    func testGetRecordScopes() async throws {
        guard let global = GlobalRecords.shared else {
            throw XCTSkip("global ledger unavailable")
        }
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = GlobalRecords.repoKey(for: dir)
        defer { cleanupGlobal(ws: ws) }

        let put = try jsonDict(await {
            try await SwctxTools.call(name: "put_record", arguments: [
                "workspace": .string(dir.path), "kind": .string("note"),
                "title": .string("scoped get probe"),
                "payload": .string("two ledgers, two ids")])
        }())
        let wsID = try XCTUnwrap(put["record_id"] as? Int)
        // The dual-written global copy has its own id — fetch it.
        let globalID = try await global.pool.read { db in
            try Int.fetchOne(db, sql:
                "SELECT id FROM records WHERE ws = ? AND title = 'scoped get probe'",
                arguments: [ws])
        }
        let gid = try XCTUnwrap(globalID)

        // Default scope: workspace ledger by the returned id.
        let got = try jsonDict(await {
            try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(dir.path), "id": .int(wsID)])
        }())
        let rec = try XCTUnwrap(got["record"] as? [String: Any])
        XCTAssertEqual(rec["title"] as? String, "scoped get probe")
        XCTAssertNil(rec["ws"])

        // scope=global: the global ledger, by the global id — `ws` on the row.
        let g = try jsonDict(await {
            try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(dir.path), "id": .int(gid),
                "scope": .string("global")])
        }())
        let grec = try XCTUnwrap(g["record"] as? [String: Any])
        XCTAssertEqual(grec["title"] as? String, "scoped get probe")
        XCTAssertEqual(grec["ws"] as? String, ws)

        // scope=all on the workspace id hits the workspace ledger first.
        let all = try jsonDict(await {
            try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(dir.path), "id": .int(wsID),
                "scope": .string("all")])
        }())
        let arec = try XCTUnwrap(all["record"] as? [String: Any])
        XCTAssertEqual(arec["title"] as? String, "scoped get probe")

        // scope=workspace on a global-only id reports not found.
        let miss = try jsonDict(await {
            try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(dir.path), "id": .int(999_999_999)])
        }())
        XCTAssertEqual(miss["error"] as? String, "record not found")
    }

    /// scope=global/all only need the global ledger — an unindexed
    /// workspace resolves leniently (store=nil) instead of throwing
    /// not-indexed; scope=workspace still requires the index.
    func testGetRecordScopeLeniency() async throws {
        guard let global = GlobalRecords.shared else {
            throw XCTSkip("global ledger unavailable")
        }
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = GlobalRecords.repoKey(for: dir)
        defer { cleanupGlobal(ws: ws) }
        let bare = try makeUnindexedDir()
        defer { try? FileManager.default.removeItem(at: bare) }

        _ = try await SwctxTools.call(name: "put_record", arguments: [
            "workspace": .string(dir.path), "kind": .string("note"),
            "title": .string("lenient get probe"), "payload": .string("p")])
        let globalID = try await global.pool.read { db in
            try Int.fetchOne(db, sql:
                "SELECT id FROM records WHERE ws = ? AND title = 'lenient get probe'",
                arguments: [ws])
        }
        let gid = try XCTUnwrap(globalID)

        // Unindexed workspace + scope=global: global ledger answers anyway.
        let g = try jsonDict(await {
            try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(bare.path), "id": .int(gid),
                "scope": .string("global")])
        }())
        XCTAssertEqual(
            (g["record"] as? [String: Any])?["title"] as? String,
            "lenient get probe")

        // scope=all falls back to the same global row.
        let all = try jsonDict(await {
            try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(bare.path), "id": .int(gid),
                "scope": .string("all")])
        }())
        XCTAssertEqual(
            (all["record"] as? [String: Any])?["title"] as? String,
            "lenient get probe")

        // scope=workspace on the unindexed dir still throws not-indexed.
        do {
            _ = try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(bare.path), "id": .int(gid)])
            XCTFail("workspace scope on an unindexed dir must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not indexed"))
        }
    }

    /// A scope outside the allowlist is an invalid-arg error.
    func testGetRecordScopeValidation() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { cleanupGlobal(ws: GlobalRecords.repoKey(for: dir)) }
        do {
            _ = try await SwctxTools.call(name: "get_record", arguments: [
                "workspace": .string(dir.path), "id": .int(1),
                "scope": .string("bogus")])
            XCTFail("unknown scope must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("scope"))
        }
    }
}
