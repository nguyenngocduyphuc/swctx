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

    /// Dependent rows must carry the real call-site line and the calling
    /// chunk's symbol — INTEGER columns arrive as Int64, not Int.
    func testCallersCarryLineAndCallerSymbol() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let diff = """
        --- a/a.py
        +++ b/a.py
        @@ -1,3 +1,3 @@
        -def greet(name):
        +def greet(name, lang):
        """
        let r = try sim(ws, diff)
        let callers = (r["symbols"] as? [[String: Any]])?
            .first?["callers"] as? [[String: Any]] ?? []
        XCTAssertEqual(callers.count, 2)
        let byPath = Dictionary(
            callers.map { (($0["path"] as? String) ?? "", $0) },
            uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byPath["b.py"]?["line"] as? Int64, 12)
        XCTAssertEqual(byPath["b.py"]?["symbol"] as? String, "caller")
        XCTAssertEqual(byPath["tests/test_a.py"]?["line"] as? Int64, 4)
    }

    /// `+++ /dev/null` deletes a file: its removed decls must attribute to
    /// the deleted path, not leak onto the previous file's hunks — and a
    /// removed line that itself starts with `--` stays hunk content.
    func testDeletedFileKeepsItsOwnPath() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let diff = """
        diff --git a/a.py b/a.py
        --- a/a.py
        +++ b/a.py
        @@ -1,2 +1,1 @@
        -def greet(name):
        --- flag-comment
        +def greet(name, lang):
        diff --git a/b.py b/b.py
        deleted file mode 100644
        --- a/b.py
        +++ /dev/null
        @@ -12,1 +0,0 @@
        -def prodCaller():
        """
        let r = try sim(ws, diff)
        let syms = r["symbols"] as? [[String: Any]] ?? []
        let byName = Dictionary(
            syms.map { (($0["name"] as? String) ?? "", $0) },
            uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["greet"]?["file"] as? String, "a.py")
        // the deleted file's decl keeps b.py — not misattributed to a.py
        XCTAssertEqual(byName["prodCaller"]?["file"] as? String, "b.py")
        XCTAssertEqual(byName["prodCaller"]?["change"] as? String, "removed")
        let files = r["files"] as? [String] ?? []
        XCTAssertEqual(files, ["a.py", "b.py"])
    }

    /// A hunk inside a symbol-less `window` chunk (oversized body split)
    /// still resolves an owner: nearest preceding container decl.
    func testWindowChunkFallsBackToOwningDecl() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = try Store(workspaceRoot: ws)
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                   kind, symbol, content, tokens)
                VALUES(9,1,0,10,20,'window',NULL,'x',0)
                """)
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line,
                                    norm_kind)
                VALUES(1,9,'outer','function_declaration',9,'function')
                """)
        }
        let diff = """
        --- a/a.py
        +++ b/a.py
        @@ -15,1 +15,1 @@
        -    x = 1
        +    x = 2
        """
        let r = try sim(ws, diff)
        let body = r["body_changes"] as? [[String: Any]] ?? []
        XCTAssertEqual(body.first?["enclosing_symbol"] as? String, "outer")
        XCTAssertEqual(body.first?["symbol_source"] as? String, "owner_decl")
        XCTAssertEqual(body.first?["enclosing_kind"] as? String, "window")
    }

    /// Nested decls: `inner` at :12 closes before the edited line :15 —
    /// its chunk end (14) < 15, so it cannot enclose the change. The
    /// owner is `outer` (:9, chunk ends 40). Without the chunk-end
    /// bound, `s.line <= ?` alone blames `inner` (Grok delta-review).
    func testNestedDeclBlamesEnclosingNotPrevious() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = try Store(workspaceRoot: ws)
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                   kind, symbol, content, tokens)
                VALUES(10,1,0,9,40,'function','outer','x',0)
                """)
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                   kind, symbol, content, tokens)
                VALUES(11,1,0,12,14,'function','inner','x',0)
                """)
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line,
                                    norm_kind)
                VALUES(1,10,'outer','function_declaration',9,'function')
                """)
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line,
                                    norm_kind)
                VALUES(1,11,'inner','function_declaration',12,'function')
                """)
        }
        let diff = """
        --- a/a.py
        +++ b/a.py
        @@ -15,1 +15,1 @@
        -    x = 1
        +    x = 2
        """
        let r = try sim(ws, diff)
        let body = r["body_changes"] as? [[String: Any]] ?? []
        XCTAssertEqual(body.first?["enclosing_symbol"] as? String, "outer")
    }

    /// Callers of a common name ("greet" here) sort resolved-first:
    /// edges pinned to the real def chunk outrank name-only matches,
    /// which otherwise flood the LIMIT with unrelated files (Grok
    /// delta-review finding).
    func testDependentsResolveBeforeNameOnlyMatches() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = try Store(workspaceRoot: ws)
        try store.pool.write { db in
            // zz.py calls the REAL greet (dst_chunk=1); aa.py/ab.py are
            // name-only edges (dst_chunk NULL) — alphabetically first,
            // so only resolved-first ordering surfaces the true caller.
            for (i, p) in ["zz.py", "aa.py", "ab.py"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO files(id, path, lang, sha, size, mtime,
                                      indexed_at)
                    VALUES(?, ?, 'python', 'x', 0, 0, 0)
                    """, arguments: [i + 4, p])
            }
            for (id, fid) in [(5, 4), (6, 5), (7, 6)] {
                try db.execute(sql: """
                    INSERT INTO chunks(id, file_id, idx, start_line,
                                       end_line, kind, symbol, content,
                                       tokens)
                    VALUES(?,?,0,1,50,'function','caller','x',0)
                    """, arguments: [id, fid])
            }
            try db.execute(sql: """
                INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind,
                                  line)
                VALUES(5,1,'greet','calls',7)
                """)
            for id in [6, 7] {
                try db.execute(sql: """
                    INSERT INTO edges(src_chunk, dst_chunk, dst_name,
                                      kind, line)
                    VALUES(?,NULL,'greet','calls',3)
                    """, arguments: [id])
            }
        }
        let diff = """
        --- a/a.py
        +++ b/a.py
        @@ -1,3 +1,3 @@
        -def greet(name):
        +def greet(name, lang):
        """
        let r = try sim(ws, diff)
        let callers = (r["symbols"] as? [[String: Any]])?
            .first?["callers"] as? [[String: Any]] ?? []
        let paths = callers.compactMap { $0["path"] as? String }
        // Resolved callers (b.py, tests/test_a.py, zz.py → dst_chunk=1)
        // precede the name-only aa.py/ab.py despite sorting after them.
        XCTAssertEqual(Array(paths.prefix(3)),
                       ["b.py", "tests/test_a.py", "zz.py"])
        XCTAssertEqual(Array(paths.suffix(2)), ["aa.py", "ab.py"])
    }

    func testEmptyDiffIsGraceful() throws {
        let ws = try makeWorkspace()
        let r = try sim(ws, "not a diff\n")
        XCTAssertEqual(r["files_changed"] as? Int, 0)
    }
}
