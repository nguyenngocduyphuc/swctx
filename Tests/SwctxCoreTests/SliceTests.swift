import XCTest
@testable import SwctxCore
import GRDB
import MCP

/// Task-aware slicing: signature extraction, fetch_chunks mode=signature,
/// outline tool.
final class SliceTests: SwctxTestCase {

    func testSignatureSingleLineDecl() {
        let src = "def greet(name):\n    return f'hi {name}'\n    return 2\n"
        XCTAssertEqual(Slice.signature(of: src),
                       "def greet(name):\n    …")
    }

    func testSignatureMultiLineDecl() {
        let src = "public func pack(\n    store: Store,\n    query: String\n) -> Pack {\n    return x\n}\n"
        let sig = Slice.signature(of: src)
        XCTAssertTrue(sig.hasPrefix("public func pack("))
        XCTAssertTrue(sig.contains(") -> Bool") == false) // stops at balance
        XCTAssertTrue(sig.contains(") -> Pack {"))
        XCTAssertFalse(sig.contains("return x"))
    }

    func testSignatureCapsLongDecls() {
        let src = (0..<20).map { "arg\($0): Int," }
            .joined(separator: "\n")
        let sig = Slice.signature(of: "func f(\n" + src + "\nbody\n")
        XCTAssertLessThanOrEqual(
            sig.components(separatedBy: "\n").count, 7) // 6 + ellipsis
    }

    /// outline + fetch_chunks mode=signature over a tiny fixture.
    func testOutlineAndFetchSignature() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-slice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(workspaceRoot: dir)
        try await store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO files(id, path, lang, sha, size, mtime, indexed_at)
                VALUES(1, 'a.py', 'python', 'x', 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                   kind, symbol, content, tokens)
                VALUES(1,1,0,1,3,'function','greet',
                       'def greet(name):\n    return f''hi''\n    x=1',0)
                """)
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                   kind, symbol, content, tokens)
                VALUES(2,1,1,5,6,'function','helper','def helper():\n    1',0)
                """)
        }
        let outline = try await SwctxTools.call(name: "outline", arguments: [
            "workspace": .string(dir.path), "path": .string("a.py")])
        let o = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(outline.utf8))
                as? [String: Any])
        let syms = try XCTUnwrap(o["symbols"] as? [[String: Any]])
        XCTAssertEqual(syms.count, 2)
        XCTAssertEqual(syms[0]["symbol"] as? String, "greet")
        XCTAssertEqual(syms[0]["signature"] as? String,
                       "def greet(name):\n    …")

        let fc = try await SwctxTools.call(name: "fetch_chunks", arguments: [
            "workspace": .string(dir.path),
            "chunk_ids": .array([.int(1)]),
            "mode": .string("signature")])
        let f = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fc.utf8))
                as? [String: Any])
        let ch = try XCTUnwrap(f["chunks"] as? [[String: Any]])
        XCTAssertEqual(ch[0]["signature"] as? String,
                       "def greet(name):\n    …")
        XCTAssertNil(ch[0]["content"])
    }

    /// Unknown path -> structured error, no crash.
    func testOutlineMissingPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-slice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Store(workspaceRoot: dir)
        let out = try await SwctxTools.call(name: "outline", arguments: [
            "workspace": .string(dir.path), "path": .string("nope.py")])
        let r = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8))
                as? [String: Any])
        XCTAssertNotNil(r["error"])
    }
}
