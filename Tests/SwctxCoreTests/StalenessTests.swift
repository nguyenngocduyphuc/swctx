import XCTest
@testable import SwctxCore
import GRDB
import MCP

/// Record staleness: put_record captures git HEAD + resolving anchors,
/// reads flag a record only when HEAD moved AND an anchor stopped
/// resolving, prime marks stale records, and every tool response can
/// carry the TTL-cached meta.stale health line.
final class StalenessTests: SwctxTestCase {

    /// Temp workspace holding one indexed symbol (`alpha_target` in a.py)
    /// and one nested file (sub/keeper.py). No git — callers add it.
    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "def alpha_target():\n    return 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def keep_me():\n    return alpha_target()\n".write(
            to: dir.appendingPathComponent("sub/keeper.py"),
            atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)
        return dir
    }

    /// makeWorkspace + `git init` and one commit so HEAD exists. Returns
    /// nil when git cannot run in this environment (caller XCTSkips).
    private func makeGitWorkspace() throws -> URL? {
        let dir = try makeWorkspace()
        guard GlobalRecords.git(["init"], cwd: dir) != nil,
              GlobalRecords.git(["add", "-A"], cwd: dir) != nil,
              GlobalRecords.git(
                ["-c", "user.email=swctx@test", "-c", "user.name=swctx",
                 "-c", "commit.gpgsign=false", "commit", "-m", "init"],
                cwd: dir) != nil
        else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return dir
    }

    /// Commit all pending changes; returns the new HEAD.
    private func commitAll(_ dir: URL) -> String? {
        guard GlobalRecords.git(["add", "-A"], cwd: dir) != nil else { return nil }
        return GlobalRecords.git(
            ["-c", "user.email=swctx@test", "-c", "user.name=swctx",
             "-c", "commit.gpgsign=false", "commit", "-m", "drift"], cwd: dir)
            .flatMap { _ in GlobalRecords.git(["rev-parse", "HEAD"], cwd: dir) }
    }

    /// Remove this test's rows from the real shared ledger.
    private func cleanupGlobal(ws: String) {
        try? GlobalRecords.shared?.pool.write { db in
            try db.execute(sql: "DELETE FROM records WHERE ws = ?", arguments: [ws])
        }
    }

    private func jsonDict(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func firstRecord(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(
            ((try jsonDict(out))["records"] as? [[String: Any]])?.first)
    }

    private func put(_ dir: URL, title: String, payload: String) async throws -> Int {
        let out = try await SwctxTools.call(name: "put_record", arguments: [
            "workspace": .string(dir.path), "kind": .string("note"),
            "title": .string(title), "payload": .string(payload)])
        return try XCTUnwrap((try jsonDict(out))["record_id"] as? Int)
    }

    /// Anchor capture keeps only what resolves: the real symbol and the
    /// real nested path survive; a fake symbol and a missing path drop.
    /// Non-git workspace → head_sha stays absent.
    func testAnchorExtractionKeepsOnlyResolvable() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { cleanupGlobal(ws: GlobalRecords.repoKey(for: dir)) }

        let id = try await put(dir, title: "anchor probe",
                               payload: "touches alpha_target and sub/keeper.py; "
                                        + "ignore bogus_symbol_xyz and nope/missing.py")
        let got = try await SwctxTools.call(name: "get_record", arguments: [
            "workspace": .string(dir.path), "id": .int(id)])
        let rec = try XCTUnwrap((try jsonDict(got))["record"] as? [String: Any])
        XCTAssertEqual(Set(rec["anchors"] as? [String] ?? []),
                       ["alpha_target", "sub/keeper.py"])
        XCTAssertNil(rec["head_sha"], "non-git workspace must not capture a head")
        XCTAssertEqual(rec["stale"] as? Bool, false)
    }

    /// The stale verdict needs BOTH a moved HEAD and a broken anchor.
    /// Between the drift commit and the reindex the old index still
    /// resolves the symbol — no flag until the index proves it gone.
    func testStaleFlagAfterCodeChange() async throws {
        guard let dir = try makeGitWorkspace() else {
            throw XCTSkip("git unavailable in test environment")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { cleanupGlobal(ws: GlobalRecords.repoKey(for: dir)) }

        let id = try await put(dir, title: "alpha_target contract",
                               payload: "see sub/keeper.py for the caller")

        var rec = try await firstRecord(SwctxTools.call(name: "list_records", arguments: [
            "workspace": .string(dir.path)]))
        XCTAssertEqual(rec["stale"] as? Bool, false, "fresh record must not flag")
        XCTAssertEqual(rec["head_sha"] as? String,
                       GlobalRecords.git(["rev-parse", "HEAD"], cwd: dir))

        // Drift: alpha_target removed from a.py, HEAD moves, index rebuilt.
        try "def beta_new():\n    return 2\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(commitAll(dir))

        rec = try await firstRecord(SwctxTools.call(name: "list_records", arguments: [
            "workspace": .string(dir.path)]))
        XCTAssertEqual(rec["stale"] as? Bool, false,
                       "pre-reindex the old index still resolves the anchor")

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: false)

        rec = try await firstRecord(SwctxTools.call(name: "list_records", arguments: [
            "workspace": .string(dir.path)]))
        XCTAssertEqual(rec["stale"] as? Bool, true)
        let reasons = rec["stale_reasons"] as? [String] ?? []
        XCTAssertTrue(reasons.contains { $0.contains("head moved") })
        XCTAssertTrue(reasons.contains { $0.contains("alpha_target") })
        // The surviving path anchor is not listed as missing.
        XCTAssertFalse(reasons.contains { $0.contains("sub/keeper.py") })

        // get_record + search_records carry the same verdict.
        let got = try await SwctxTools.call(name: "get_record", arguments: [
            "workspace": .string(dir.path), "id": .int(id)])
        XCTAssertEqual(((try jsonDict(got))["record"] as? [String: Any])?["stale"]
                       as? Bool, true)
        let found = try await firstRecord(SwctxTools.call(name: "search_records", arguments: [
            "workspace": .string(dir.path), "query": .string("contract")]))
        XCTAssertEqual(found["stale"] as? Bool, true)

        // scope=all (workspace row + deduped global copy) flags identically.
        if GlobalRecords.shared != nil {
            let all = try await firstRecord(SwctxTools.call(name: "list_records", arguments: [
                "workspace": .string(dir.path), "scope": .string("all")]))
            XCTAssertEqual(all["stale"] as? Bool, true)
        }
    }

    /// Head movement alone never flags: a record with no anchors has
    /// nothing to verify against, even after a commit + reindex.
    func testNoAnchorRecordNeverStale() async throws {
        guard let dir = try makeGitWorkspace() else {
            throw XCTSkip("git unavailable in test environment")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { cleanupGlobal(ws: GlobalRecords.repoKey(for: dir)) }

        _ = try await put(dir, title: "deploy quirk",
                          payload: "puma restart clears it")

        try "def beta_new():\n    return 2\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(commitAll(dir))
        try Indexer(store: Store(workspaceRoot: dir)).run(force: false)

        let rec = try await firstRecord(SwctxTools.call(name: "list_records", arguments: [
            "workspace": .string(dir.path)]))
        XCTAssertNotNil(rec["head_sha"], "git workspace still captures head")
        XCTAssertEqual(rec["stale"] as? Bool, false)
        XCTAssertEqual(rec["stale_reasons"] as? [String] ?? [], [])
    }

    /// meta.stale: absent while the index matches disk, present once a
    /// source file drifts, gone again after index_workspace (which also
    /// clears the 30s TTL cache so its own response reads fresh).
    func testMetaStaleHealthLine() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        SwctxTools.invalidateStaleCache()

        var meta = (try jsonDict(await SwctxTools.call(
            name: "get_workspace_tree",
            arguments: ["workspace": .string(dir.path)])))["meta"] as? [String: Any]
        XCTAssertEqual(meta?["truncation_applied"] as? Bool, false)
        XCTAssertNil(meta?["stale"], "fresh index must not carry meta.stale")

        // Drift one file on disk; the TTL cache is bypassed explicitly.
        try "def alpha_target():\n    return 99\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        SwctxTools.invalidateStaleCache()
        meta = (try jsonDict(await SwctxTools.call(
            name: "get_workspace_tree",
            arguments: ["workspace": .string(dir.path)])))["meta"] as? [String: Any]
        let stale = try XCTUnwrap(meta?["stale"] as? [String: Any])
        XCTAssertEqual(stale["stale_files"] as? Int, 1)
        XCTAssertTrue((stale["hint"] as? String ?? "").contains("index_workspace"))

        // index_workspace re-scans post-run: its own response is fresh.
        let indexed = try await SwctxTools.call(name: "index_workspace", arguments: [
            "workspace": .string(dir.path)])
        XCTAssertNil(((try jsonDict(indexed))["meta"] as? [String: Any])?["stale"])
    }

    /// prime marks a stale recent record with `·stale`, counts it in the
    /// snapshot, and surfaces a warning.
    func testPrimeMarksStaleRecords() async throws {
        guard let dir = try makeGitWorkspace() else {
            throw XCTSkip("git unavailable in test environment")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { cleanupGlobal(ws: GlobalRecords.repoKey(for: dir)) }

        _ = try await put(dir, title: "alpha_target contract",
                          payload: "see sub/keeper.py for the caller")
        let store = try Store(workspaceRoot: dir)
        var snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        XCTAssertEqual(snap["stale_records"] as? Int, 0)
        XCTAssertFalse(try Prime.card(store: store, root: store.workspaceRoot)
            .contains("·stale"))

        try "def beta_new():\n    return 2\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(commitAll(dir))
        try Indexer(store: store).run(force: false)

        snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        XCTAssertEqual(snap["stale_records"] as? Int, 1)
        let warnings = snap["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.contains { $0.contains("stale record") })
        let card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(card.contains("- note: alpha_target contract ·stale"))
    }

    /// since_last_session is repo-scoped: a head-stamped checkpoint filed
    /// under a DIFFERENT ws never becomes this workspace's resume anchor;
    /// once this repo leaves its own stamped record, the section anchors
    /// to it (any kind counts — a note is still the last agent contact).
    func testSinceLastSessionIsRepoScoped() async throws {
        guard let dir = try makeGitWorkspace() else {
            throw XCTSkip("git unavailable in test environment")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = GlobalRecords.repoKey(for: dir)
        defer { cleanupGlobal(ws: ws) }
        let store = try Store(workspaceRoot: dir)

        let otherWs = "other-\(UUID().uuidString.prefix(8))"
        defer { cleanupGlobal(ws: otherWs) }
        try GlobalRecords.shared?.insert(
            ws: otherWs, kind: "session_checkpoint", source: "test",
            status: "completed", title: "foreign session", payload: "{}",
            headSHA: GlobalRecords.git(["rev-parse", "HEAD"], cwd: dir))
        var snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        XCTAssertTrue(snap["since_last_session"] is NSNull,
                      "a foreign ws anchor must not resume this workspace")

        _ = try await put(dir, title: "local note", payload: "p")
        snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        let sls = try XCTUnwrap(snap["since_last_session"] as? [String: Any])
        XCTAssertEqual(sls["base_kind"] as? String, "note")
        XCTAssertEqual(sls["base_title"] as? String, "local note")
        XCTAssertEqual(sls["changed_total"] as? Int, 0)
        XCTAssertEqual((sls["changed"] as? [[String: Any]])?.count, 0)
    }
}
