import XCTest
@testable import SwctxCore
import GRDB
import MCP

/// test_coverage — symbol<->test map over call edges. Direct-SQL
/// fixture: a.py defines greet, b.py (prod) calls it, tests/test_a.py
/// calls it too — only the test file must appear in symbol mode, and
/// file mode must map test_a.py -> greet while skipping prod callers.
final class TestCoverageTests: SwctxTestCase {

    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(workspaceRoot: dir)
        try store.pool.write { db in
            for (i, p) in ["a.py", "b.py", "tests/test_a.py"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO files(id, path, lang, sha, size, mtime, indexed_at)
                    VALUES(?, ?, 'python', 'x', 0, 0, 0)
                    """, arguments: [i + 1, p])
            }
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
            // caller chunks: b.py (prod, id 3) and test_a.py (id 4) both
            // call greet; the test also calls helper via an unresolved edge.
            for (id, fid, sym, line, dst) in
                [(3, 2, "prodCaller", 12, 1), (4, 3, "test_greet", 4, 1)] {
                try db.execute(sql: """
                    INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                       kind, symbol, content, tokens)
                    VALUES(?,?,0,1,50,'function',?,'x',0)
                    """, arguments: [id, fid, sym])
                try db.execute(sql: """
                    INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind, line)
                    VALUES(?,?, 'greet','calls',?)
                    """, arguments: [id, dst, line])
            }
            // unresolved mention — name-only edge still counts as coverage
            try db.execute(sql: """
                INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind, line)
                VALUES(4, NULL, 'helper', 'calls', 9)
                """)
        }
        return dir
    }

    private func call(_ ws: URL, _ args: [String: Value]) async throws
        -> [String: Any] {
        var a = args
        a["workspace"] = .string(ws.path)
        let out = try await SwctxTools.call(name: "test_coverage", arguments: a)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8))
                as? [String: Any])
    }

    /// symbol -> tests: only the test file appears, prod callers don't.
    func testSymbolToTests() async throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let r = try await call(ws, ["symbol_name": .string("greet")])
        let tests = try XCTUnwrap(r["tests"] as? [[String: Any]])
        XCTAssertEqual(tests.count, 1)
        XCTAssertEqual(tests.first?["path"] as? String, "tests/test_a.py")
        XCTAssertEqual(tests.first?["symbol"] as? String, "test_greet")
    }

    /// path -> covers: the test file resolves to greet in a.py.
    func testFileCovers() async throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let r = try await call(ws, ["path": .string("tests/test_a.py")])
        let covers = try XCTUnwrap(r["covers"] as? [[String: Any]])
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers.first?["symbol"] as? String, "greet")
        XCTAssertEqual(covers.first?["path"] as? String, "a.py")
    }

    /// A test chunk that both calls and instantiates the symbol is ONE
    /// entry — edge kinds merge, call-site lines collect per chunk.
    func testSymbolModeDedupesEdgeKinds() async throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = try Store(workspaceRoot: ws)
        try await store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind, line)
                VALUES(4, 1, 'greet', 'instantiates', 5)
                """)
        }
        let r = try await call(ws, ["symbol_name": .string("greet")])
        let tests = try XCTUnwrap(r["tests"] as? [[String: Any]])
        XCTAssertEqual(tests.count, 1)
        XCTAssertEqual(r["count"] as? Int, 1)
        let edges = tests.first?["edges"] as? [String] ?? []
        XCTAssertEqual(Set(edges), ["calls", "instantiates"])
        let callLines = tests.first?["call_lines"] as? [Int64] ?? []
        XCTAssertTrue(callLines.contains(4))
        XCTAssertTrue(callLines.contains(5))
    }

    /// path mode lists the edge's target name — not every sibling symbol
    /// sharing the resolved chunk (locals/tuple decls fan out otherwise).
    func testFileCoversOnlyEdgeTargets() async throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = try Store(workspaceRoot: ws)
        try await store.pool.write { db in
            // second symbol sharing greet's chunk + a tuple-pattern name —
            // neither is an edge target, so neither may surface.
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line)
                VALUES(1,1,'siblingLocal','property_declaration',2)
                """)
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line)
                VALUES(1,1,'(committed, _)','property_declaration',3)
                """)
        }
        let r = try await call(ws, ["path": .string("tests/test_a.py")])
        let covers = try XCTUnwrap(r["covers"] as? [[String: Any]])
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers.first?["symbol"] as? String, "greet")
        XCTAssertEqual(covers.first?["edges"] as? [String], ["calls"])
    }

    /// Missing both args -> ToolError.missingArg, not a crash.
    func testMissingArgs() async throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        do {
            _ = try await call(ws, [:])
            XCTFail("expected missingArg")
        } catch is ToolError {}
    }
}
