import XCTest
@testable import SwctxCore
import GRDB

/// trace_lookup — stack text -> parsed frames -> indexed chunks.
final class TraceTests: XCTestCase {

    /// Workspace: src/app.py defines `run()` at lines 10-30, src/lib.py
    /// calls it (edge -> chunk 1). A commit record lists src/app.py.
    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(workspaceRoot: dir)
        try store.pool.write { db in
            for (i, p) in ["src/app.py", "src/lib.py"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO files(id, path, lang, sha, size, mtime, indexed_at)
                    VALUES(?, ?, 'python', 'x', 0, 0, 0)
                    """, arguments: [i + 1, p])
            }
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                   kind, symbol, content, tokens)
                VALUES(1,1,0,10,30,'function','run','x',0)
                """)
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line)
                VALUES(1,1,'run','def',10)
                """)
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                   kind, symbol, content, tokens)
                VALUES(2,2,0,1,20,'function','caller','x',0)
                """)
            try db.execute(sql: """
                INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind, line)
                VALUES(2,1,'run','calls',7)
                """)
            try db.execute(sql: """
                INSERT INTO records(kind, source, status, title, payload, created_at)
                VALUES('commit','git','completed','abc123 recent change',
                       '{"sha":"abc123","files":["src/app.py"]}', 0)
                """)
        }
        return dir
    }

    func testParsePythonTrace() {
        let trace = """
        Traceback (most recent call last):
          File "/srv/app/src/app.py", line 25, in run
            work()
          File "/usr/lib/python3.11/os.py", line 9, in makedirs
            mkdir()
        """
        let frames = Trace.parse(trace)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].path, "/srv/app/src/app.py")
        XCTAssertEqual(frames[0].line, 25)
        XCTAssertEqual(frames[0].symbolHint, "run")
    }

    func testParseJSAndGoFrames() {
        let js = "Error\n    at async main (/app/src/x.ts:10:5)\n    at /app/src/y.ts:3:1"
        let jsF = Trace.parse(js)
        XCTAssertEqual(jsF.count, 2)
        XCTAssertEqual(jsF[0].symbolHint, "main")
        XCTAssertEqual(jsF[0].path, "/app/src/x.ts")
        XCTAssertEqual(jsF[1].line, 3)

        let go = "panic: boom\nmain.run()\n\t/srv/src/app.go:37 +0x1f2"
        let goF = Trace.parse(go)
        XCTAssertEqual(goF.count, 1)
        XCTAssertEqual(goF[0].path, "/srv/src/app.go")
        XCTAssertEqual(goF[0].line, 37)
    }

    /// Container path `/app/src/app.py` suffix-matches `src/app.py`;
    /// line 25 lands inside chunk run(10-30); lib.py caller is suspect
    /// and app.py carries the recent_commit flag.
    func testResolveAndSuspects() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = try Store(workspaceRoot: ws)
        let trace = """
        Traceback (most recent call last):
          File "/usr/lib/python3.11/os.py", line 9, in makedirs
          File "/app/src/app.py", line 25, in run
        """
        let resolved = Trace.resolve(store: store, frames: Trace.parse(trace))
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0]["matched"] as? Bool, false)
        XCTAssertEqual(resolved[1]["matched"] as? Bool, true)
        XCTAssertEqual(resolved[1]["path"] as? String, "src/app.py")
        XCTAssertEqual(resolved[1]["symbol"] as? String, "run")

        let suspects = Trace.suspects(store: store, resolved: resolved)
        XCTAssertEqual(suspects.count, 1)
        XCTAssertEqual(suspects[0]["path"] as? String, "src/lib.py")
        // caller file is not the recently-committed one -> no flag
        XCTAssertNil(suspects[0]["recent_commit"])
    }

    func testEmptyTraceIsGraceful() async throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let out = try await SwctxTools.call(name: "trace_lookup", arguments: [
            "workspace": .string(ws.path),
            "trace": .string("no frames here")])
        let r = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(r["count"] as? Int, 0)
    }
}
