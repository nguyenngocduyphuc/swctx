import XCTest
@testable import SwctxCore

final class WorkspaceResolutionTests: XCTestCase {

    /// Foundation can return "/.." for the parent of "/" — the old
    /// "parent == self" check then never fired and the ancestor walk
    /// spun upward forever (MCP calls without a resolvable workspace
    /// hung). Assert the walk terminates nil instead.
    func testIndexedAncestorTerminatesAtRoot() {
        let start = Date()
        let found = SwctxTools.indexedAncestor(
            of: URL(fileURLWithPath: "/nonexistent-swctx-\(UUID().uuidString)"))
        XCTAssertNil(found)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// scope=global reads the global ledger — it must not require a
    /// resolvable indexed workspace. An existing-but-unindexed path
    /// exercises the same notIndexed fallback as auto-resolution.
    func testGlobalScopeRecordsWithoutIndexedWorkspace() async throws {
        let out = try await SwctxTools.call(name: "list_records", arguments: [
            "scope": .string("global"), "workspace": .string("/tmp"),
        ])
        let p = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertNotNil(p?["records"] as? [Any])
        XCTAssertNil(p?["error"])
    }

    /// scope=all degrades to global-only when the workspace can't resolve.
    func testAllScopeDegradesWithoutIndexedWorkspace() async throws {
        let out = try await SwctxTools.call(name: "list_records", arguments: [
            "scope": .string("all"), "workspace": .string("/tmp"),
        ])
        let p = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertNotNil(p?["records"] as? [Any])
        XCTAssertNil(p?["error"])
    }
}
