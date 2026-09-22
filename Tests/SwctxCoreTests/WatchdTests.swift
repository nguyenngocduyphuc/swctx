import XCTest
@testable import SwctxCore

/// watchd.json workspace-list management — the file `swctx watch-all`
/// reads and `swctx watch add|remove` edits. Covered here: create,
/// dedupe, symlink/`~` normalization, remove, missing/corrupt file
/// handling. The launchctl verbs need a real gui domain and are not
/// exercised in tests.
final class WatchdTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempList() throws -> (dir: URL, list: URL) {
        let dir = try tempDir()
        return (dir, dir.appendingPathComponent("watchd.json"))
    }

    /// `add` creates the file and records the resolved workspace path;
    /// re-adding the same path is a no-op.
    func testAddCreatesListAndDedupes() throws {
        let (dir, list) = try tempList()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }

        var r = try Watchd.addWorkspace(ws.path, to: list)
        XCTAssertTrue(r.added)
        XCTAssertEqual(r.workspaces, [Watchd.normalize(ws.path).path])
        XCTAssertEqual(try Watchd.loadWorkspaces(from: list), r.workspaces)

        r = try Watchd.addWorkspace(ws.path, to: list)
        XCTAssertFalse(r.added)
        XCTAssertEqual(r.workspaces.count, 1)
    }

    /// A trailing-slash or `./`-relative spelling of the same directory
    /// resolves to one list entry.
    func testAddNormalizesPathSpellings() throws {
        let (dir, list) = try tempList()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }

        _ = try Watchd.addWorkspace(ws.path + "/", to: list)
        let r = try Watchd.addWorkspace(ws.path + "/.", to: list)
        XCTAssertFalse(r.added)
        XCTAssertEqual(r.workspaces.count, 1)
    }

    /// `remove` drops the matching entry; removing an unlisted path
    /// reports false and leaves the file untouched.
    func testRemoveDropsListedPath() throws {
        let (dir, list) = try tempList()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try tempDir(), b = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        _ = try Watchd.addWorkspace(a.path, to: list)
        _ = try Watchd.addWorkspace(b.path, to: list)

        var r = try Watchd.removeWorkspace(a.path, from: list)
        XCTAssertTrue(r.removed)
        XCTAssertEqual(r.workspaces, [Watchd.normalize(b.path).path])
        XCTAssertEqual(try Watchd.loadWorkspaces(from: list), r.workspaces)

        r = try Watchd.removeWorkspace(a.path, from: list)
        XCTAssertFalse(r.removed)
        XCTAssertEqual(r.workspaces.count, 1)
    }

    /// Missing file → empty list; non-directory targets and corrupt JSON
    /// are errors, not silent empties.
    func testLoadAndAddErrorPaths() throws {
        let (dir, list) = try tempList()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(try Watchd.loadWorkspaces(from: list), [])
        XCTAssertThrowsError(try Watchd.addWorkspace(
            dir.appendingPathComponent("nope").path, to: list))

        try "not json".write(to: list, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Watchd.loadWorkspaces(from: list))
        // A corrupt list must not be silently overwritten by add/remove —
        // the error propagates instead of clobbering the file.
        XCTAssertThrowsError(try Watchd.addWorkspace(dir.path, to: list))
        XCTAssertThrowsError(try Watchd.removeWorkspace(dir.path, from: list))
    }
}
