import XCTest
@testable import SwctxCore
import GRDB

/// simulate_patch — unified diff in, broken dependents out. Direct-SQL
/// fixture for precise control over files/chunks/edges (no indexer run).
final class SimulateTests: SwctxTestCase {

    /// Workspace: a.py defines greet+helper, b.py calls greet,
    /// tests/test_a.py also calls greet.
    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(workspaceRoot: dir)
        try store.pool.write { db in
            for (i, p) in ["a.py", "b.py", "tests/test_a.py"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO files(id, path, lang, sha, size, mtime, indexed_at)
                    VALUES(?, ?, 'python', 'x', 0, 0, 0)
                    """, arguments: [i + 1, p])
            }
            // a.py: chunk 1 = greet (lines 1-3), chunk 2 = helper (lines 5-7)
            for (id, sym, s, e) in [(1, "greet", 1, 3), (2, "helper", 5, 7)] {
                try db.execute(sql: """
                    INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                       kind, symbol, content, tokens)
                    VALUES(?,1,0,?,?, 'function', ?, 'x', 0)
                    """, arguments: [id, s, e, sym])
                try db.execute(sql: """
                    INSERT INTO symbols(file_id, chunk_id, name, kind, line)
                    VALUES(1,?,?,?,?)
                    """, arguments: [id, sym, "def", s])
            }
            // b.py chunk 3 calls greet at line 12; test chunk 4 calls greet
            for (id, fid, line) in [(3, 2, 12), (4, 3, 4)] {
                try db.execute(sql: """
                    INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                       kind, symbol, content, tokens)
                    VALUES(?,?,0,1,50,'function','caller','x',0)
                    """, arguments: [id, fid])
                try db.execute(sql: """
                    INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind, line)
                    VALUES(?,1,'greet','calls',?)
                    """, arguments: [id, line])
            }
        }
        return dir
    }

    private func sim(_ ws: URL, _ diff: String) throws -> [String: Any] {
        let store = try Store(workspaceRoot: ws)
        return try Simulate.run(store: store, diff: diff)
    }

    func testSignatureChangeFlagsCallersAndTests() throws {
        let ws = try makeWorkspace()
        let diff = """
        --- a/a.py
        +++ b/a.py
        @@ -1,3 +1,3 @@
        -def greet(name):
        +def greet(name, lang):
             return f"hi {name}"
        """
        let r = try sim(ws, diff)
        let syms = r["symbols"] as? [[String: Any]] ?? []
        XCTAssertEqual(syms.count, 1)
        XCTAssertEqual(syms[0]["name"] as? String, "greet")
        XCTAssertEqual(syms[0]["change"] as? String, "signature")
        XCTAssertEqual(syms[0]["arity"] as? String, "1→2")
        let callers = syms[0]["callers"] as? [[String: Any]] ?? []
        XCTAssertEqual(callers.count, 2)
        XCTAssertEqual(callers.first?["resolved"] as? Bool, true)
        let risk = r["risk"] as? [String: Any] ?? [:]
        XCTAssertEqual(risk["broken_call_sites"] as? Int, 2)
        XCTAssertEqual(risk["resolved_call_sites"] as? Int, 2)
        XCTAssertEqual(risk["affected_prod_files"] as? [String], ["b.py"])
        XCTAssertEqual(risk["affected_test_files"] as? [String], ["tests/test_a.py"])
    }

    func testRemovalMarkedRemoved() throws {
        let ws = try makeWorkspace()
        let diff = """
        --- a/a.py
        +++ b/a.py
        @@ -5,7 +5,0 @@
        -def helper():
        -    return 1
        """
        let r = try sim(ws, diff)
        let syms = r["symbols"] as? [[String: Any]] ?? []
        XCTAssertEqual(syms.first?["name"] as? String, "helper")
        XCTAssertEqual(syms.first?["change"] as? String, "removed")
        XCTAssertEqual((syms.first?["callers"] as? [Any])?.count, 0)
    }

    func testBodyHunkMapsToEnclosingSymbol() throws {
        let ws = try makeWorkspace()
        let diff = """
        --- a/a.py
        +++ b/a.py
        @@ -2,2 +2,2 @@
        -    return f"hi {name}"
        +    return f"hello {name}!"
        """
        let r = try sim(ws, diff)
        XCTAssertEqual((r["symbols"] as? [Any])?.count, 0)
        let body = r["body_changes"] as? [[String: Any]] ?? []
        XCTAssertEqual(body.first?["enclosing_symbol"] as? String, "greet")
        let deps = body.first?["dependent_callers"] as? [[String: Any]] ?? []
        XCTAssertEqual(deps.count, 2)
    }

    func testEmptyDiffIsGraceful() throws {
        let ws = try makeWorkspace()
        let r = try sim(ws, "not a diff\n")
        XCTAssertEqual(r["files_changed"] as? Int, 0)
    }
}
