import XCTest
@testable import SwctxCore
import GRDB

final class PrimeTests: SwctxTestCase {

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

    /// makeWorkspace + `git init` and one commit so HEAD exists. Returns
    /// nil when git cannot run in this environment (caller XCTSkips).
    private func makeGitWorkspace() throws -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-prime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "def alpha():\n    return beta()\ndef beta():\n    return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try "const run = () => alpha();\n".write(
            to: dir.appendingPathComponent("m.js"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)
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

    private func cleanupGlobal(ws: String) {
        try? GlobalRecords.shared?.pool.write { db in
            try db.execute(sql: "DELETE FROM records WHERE ws = ?", arguments: [ws])
        }
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
        XCTAssertTrue(card.contains(
            "stale files — run `swctx index \(store.workspaceRoot.path)`"))
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

    /// checkpoint writes a session_checkpoint record (workspace + shared
    /// ledger) and the next prime card surfaces its next-step as Resume.
    func testCheckpointSurfacesResume() async throws {
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
        let tag = UUID().uuidString.prefix(8)
        let out = try await SwctxTools.call(name: "checkpoint", arguments: [
            "workspace": .string(dir.path),
            "summary": .string("session memory work \(tag)"),
            "next": .string("ship swift engine \(tag)"),
        ])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8))
                as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "session_checkpoint")
        XCTAssertEqual(payload["scope"] as? String, "workspace+global")

        let snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        let resume = try XCTUnwrap(snap["resume"] as? String)
        XCTAssertTrue(resume.contains("session memory work \(tag)"))
        XCTAssertTrue(resume.contains("next: ship swift engine \(tag)"))
        let card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(card.contains("Resume:"))
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

    /// No prior session for this repo's ws → the key is present and
    /// emits a clean JSON null (fresh-checkout contract).
    func testSinceLastSessionNullWithoutAnchor() throws {
        let (dir, store) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        XCTAssertTrue(snap["since_last_session"] is NSNull,
                      "missing anchor must emit null, not a dropped key")
        // The card stays quiet — no empty section.
        XCTAssertFalse(try Prime.card(store: store, root: store.workspaceRoot)
            .contains("Since last session"))
    }

    /// The resume section diffs the worktree against the newest
    /// head-stamped ledger row: a committed change, a dirty tracked file
    /// and an untracked file all surface, each marked against the index.
    func testSinceLastSessionDiffsAgainstAnchor() async throws {
        guard let dir = try makeGitWorkspace() else {
            throw XCTSkip("git unavailable in test environment")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = GlobalRecords.repoKey(for: dir)
        defer { cleanupGlobal(ws: ws) }
        let base = try XCTUnwrap(
            GlobalRecords.git(["rev-parse", "HEAD"], cwd: dir))
        _ = try await SwctxTools.call(name: "checkpoint", arguments: [
            "workspace": .string(dir.path),
            "summary": .string("resume anchor \(UUID().uuidString.prefix(8))"),
        ])

        // committed change (m.js), dirty tracked file (m.py), untracked.
        try "const run = () => 2;\n".write(
            to: dir.appendingPathComponent("m.js"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(GlobalRecords.git(["add", "m.js"], cwd: dir))
        XCTAssertNotNil(GlobalRecords.git(
            ["-c", "user.email=swctx@test", "-c", "user.name=swctx",
             "-c", "commit.gpgsign=false", "commit", "-m", "second"], cwd: dir))
        try "def alpha():\n    return 9\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try "scratch\n".write(
            to: dir.appendingPathComponent("note.txt"), atomically: true,
            encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        let snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        let sls = try XCTUnwrap(snap["since_last_session"] as? [String: Any])
        XCTAssertEqual(sls["base_sha"] as? String, base)
        XCTAssertEqual(sls["base_kind"] as? String, "session_checkpoint")
        XCTAssertNotNil(sls["head_sha"])
        XCTAssertNotEqual(sls["head_sha"] as? String, base)
        XCTAssertEqual(sls["changed_total"] as? Int, 3)
        let changed = try XCTUnwrap(sls["changed"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(changed.count, 10)
        let byPath = Dictionary(uniqueKeysWithValues: changed.compactMap {
            d -> (String, [String: Any])? in
            guard let p = d["path"] as? String else { return nil }
            return (p, d)
        })
        XCTAssertEqual(byPath["m.js"]?["indexed"] as? Bool, true)
        XCTAssertEqual(byPath["m.py"]?["indexed"] as? Bool, true)
        XCTAssertNil(byPath["m.js"]?["untracked"])
        XCTAssertEqual(byPath["note.txt"]?["indexed"] as? Bool, false)
        XCTAssertEqual(byPath["note.txt"]?["untracked"] as? Bool, true)

        let card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(card.contains("Since last session"))
        XCTAssertTrue(card.contains("note.txt (untracked)"))
    }

    /// Staleness as a feature: once the index drifts, the payload carries
    /// the exact reindex command an agent can run — absent while fresh.
    func testReindexCommandWhenIndexStale() throws {
        let (dir, store) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        var snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        XCTAssertNil(snap["reindex_command"], "fresh index carries no command")

        try "def alpha():\n    return 42\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        XCTAssertEqual(snap["reindex_command"] as? String,
                       "swctx index \(store.workspaceRoot.path)")
        let card = try Prime.card(store: store, root: store.workspaceRoot)
        XCTAssertTrue(
            card.contains("run `swctx index \(store.workspaceRoot.path)`"))
    }

    /// Fleet memory names this workspace: a decision filed under ANOTHER
    /// repo's ws still surfaces here when its text carries the workspace
    /// name; unrelated rows and a bare single-letter name stay out.
    func testRelevantRecordsByWorkspaceName() throws {
        guard let g = GlobalRecords.shared else {
            throw XCTSkip("global ledger unavailable")
        }
        let tag = "otterhop\(UUID().uuidString.prefix(6).lowercased())"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(tag)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def f():\n    return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)

        let otherWs = "other-\(UUID().uuidString.prefix(8))"
        let myWs = GlobalRecords.repoKey(for: dir)
        defer {
            try? g.pool.write { db in
                try db.execute(sql: "DELETE FROM records WHERE ws IN (?, ?)",
                               arguments: [myWs, otherWs])
            }
        }
        try g.insert(ws: otherWs, kind: "decision", source: "test",
                     status: "completed",
                     title: "\(tag) gateway stays on retry budget",
                     payload: "chose 3 retries for \(tag)")
        try g.insert(ws: myWs, kind: "note", source: "test",
                     status: "completed",
                     title: "\(tag) ledger notes", payload: "local")
        try g.insert(ws: otherWs, kind: "note", source: "test",
                     status: "completed",
                     title: "unrelated deploy quirk", payload: "puma restart")
        // Newer filler rows push the matches out of prior_work's newest-3
        // window — otherwise they'd already be shown there and the
        // relevant section dedupes them out.
        for i in 0..<4 {
            try g.insert(ws: otherWs, kind: "note", source: "test",
                         status: "completed",
                         title: "filler \(i) \(UUID().uuidString.prefix(6))",
                         payload: "x")
        }

        let snap = try Prime.snapshot(store: store, root: store.workspaceRoot)
        let rel = try XCTUnwrap(snap["relevant_records"] as? [[String: Any]])
        let titles = rel.compactMap { $0["title"] as? String }
        XCTAssertTrue(titles.contains { $0.contains("gateway stays on retry") })
        XCTAssertTrue(titles.contains { $0.contains("ledger notes") })
        XCTAssertFalse(titles.contains { $0.contains("unrelated deploy") })
        // Strongest match first: the decision hits title AND body.
        XCTAssertEqual(rel.first?["kind"] as? String, "decision")
        // Follow-up id is the global ledger's own namespace.
        XCTAssertNotNil(rel.first?["id"])
        XCTAssertEqual(rel.first?["ws"] as? String, otherWs)
    }

    /// A name that folds to only short/generic tokens ("ai") would flood
    /// the card — the section stays absent entirely.
    func testRelevantRecordsSkipsGenericName() throws {
        XCTAssertNil(Prime.relevantRecords(
            root: URL(fileURLWithPath: "/tmp/ai"), excluding: []))
    }
}
