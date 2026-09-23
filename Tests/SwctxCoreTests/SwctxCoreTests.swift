import XCTest
@testable import SwctxCore
import Accelerate
import GRDB
import MCP

final class SwctxCoreTests: SwctxTestCase {
    func testAnalyzerSwift() throws {
        let src = """
        import Foundation

        /// Doc comment
        public struct FooService {
            let db: Database
            func fetchUser(id: Int) -> User { db.lookup(id) }
        }

        func helper() { print("hi") }
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "swift", path: "a.swift")
        XCTAssertFalse(r.chunks.isEmpty)
        XCTAssertTrue(r.symbols.contains { $0.name == "FooService" })
        XCTAssertTrue(r.symbols.contains { $0.name == "fetchUser" })
        XCTAssertTrue(r.edges.contains { $0.dstName == "lookup" || $0.dstName == "print" })
    }

    func testAnalyzerPython() throws {
        let src = """
        import os

        class Repo:
            def get(self, key):
                return self.store[key]

        def main():
            print(Repo())
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "python", path: "a.py")
        XCTAssertTrue(r.symbols.contains { $0.name == "Repo" })
        XCTAssertTrue(r.symbols.contains { $0.name == "get" })
        // print() is denylisted; the nested Repo() call still emits an edge.
        XCTAssertTrue(r.edges.contains { $0.kind == "calls" && $0.dstName == "Repo" })
        XCTAssertTrue(r.edges.contains { $0.kind == "imports" })
    }

    func testAnalyzerPythonCallDenylist() throws {
        let src = """
        class Worker:
            def run(self):
                print("start")
                n = len([1, 2])
                parser.add_argument("--x")
                return self._helper(n)

            def _helper(self, n):
                return n
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "python", path: "a.py")
        let calls = r.edges.filter { $0.kind == "calls" }.map { $0.dstName }
        XCTAssertFalse(calls.contains("print"))
        XCTAssertFalse(calls.contains("len"))
        XCTAssertFalse(calls.contains("add_argument"))
        // self._helper() still emits the terminal method name.
        XCTAssertTrue(calls.contains("_helper"))
    }

    func testAnalyzerJSCallDenylist() throws {
        let src = """
        function myFunc() { return 1; }
        console.log(myFunc());
        const m = require('./mod');
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "javascript", path: "a.js")
        let calls = r.edges.filter { $0.kind == "calls" }.map { $0.dstName }
        XCTAssertFalse(calls.contains("log"))
        XCTAssertFalse(calls.contains("require"))
        XCTAssertTrue(calls.contains("myFunc"))
    }

    func testAnalyzerTypeScript() throws {
        let src = """
        import { x } from './m';
        export function render(a: number): string { return fmt(a); }
        const z = () => render(1);
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "typescript", path: "a.ts")
        XCTAssertTrue(r.symbols.contains { $0.name == "render" })
        XCTAssertTrue(r.edges.contains { $0.dstName == "fmt" || $0.dstName == "render" })
    }

    func testBGEEmbedderSanity() throws {
        guard BGEEmbedder.isInstalled, let bge = try? BGEEmbedder() else {
            throw XCTSkip("bge-base-en-v1.5 not installed (swctx model install)")
        }
        // Determinism + unit norm.
        let a1 = bge.embed("function that writes rows into sqlite")!
        let a2 = bge.embed("function that writes rows into sqlite")!
        XCTAssertEqual(a1, a2)
        XCTAssertEqual(a1.count, 768)
        var norm: Float = 0
        vDSP_svesq(a1, 1, &norm, vDSP_Length(a1.count))
        XCTAssertEqual(sqrtf(norm), 1, accuracy: 0.01)
        // Semantic separation: related > unrelated.
        let related = bge.embed("insert a record into the database table")!
        let unrelated = bge.embed("recipe for chocolate cake")!
        let sRel = Embedder.dot(a1, related)
        let sUnrel = Embedder.dot(a1, unrelated)
        // bge space is anisotropic: unrelated pairs still sit ~0.6-0.7, so
        // assert the separation gap rather than an absolute unrelated ceiling.
        XCTAssertGreaterThan(sRel, 0.75)
        XCTAssertGreaterThan(sRel - sUnrel, 0.1)
        // Tokenizer: [CLS]...[SEP], in-vocab ids.
        let ids = bge.tokenize("hello world")
        XCTAssertEqual(ids.first, 101)
        XCTAssertEqual(ids.last, 102)
    }

    func testImplementsSwift() throws {
        let src = """
        struct S: Codable {}
        class C: Base, P {}
        enum E: Int, Q {}
        extension X: Y {}
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "swift", path: "a.swift")
        let impls = r.edges.filter { $0.kind == "implements" }.map { $0.dstName }
        XCTAssertTrue(impls.contains("Codable"))
        XCTAssertTrue(impls.contains("Base"))
        XCTAssertTrue(impls.contains("P"))
        XCTAssertTrue(impls.contains("Q"))
        XCTAssertTrue(impls.contains("Y"))
    }

    func testImplementsPython() throws {
        let src = """
        class Repo(Storage):
            pass

        class Multi(Base, mod.Mixin, metaclass=ABCMeta):
            pass

        class Plain(object):
            pass
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "python", path: "a.py")
        let impls = r.edges.filter { $0.kind == "implements" }.map { $0.dstName }
        XCTAssertTrue(impls.contains("Storage"))
        XCTAssertTrue(impls.contains("Base"))
        // Qualified base resolves to its leaf name.
        XCTAssertTrue(impls.contains("Mixin"))
        // keyword args are not bases; `object` is suppressed.
        XCTAssertFalse(impls.contains("metaclass"))
        XCTAssertFalse(impls.contains("ABCMeta"))
        XCTAssertFalse(impls.contains("object"))
    }

    func testImplementsTSX() throws {
        let src = """
        class A extends B implements I1, I2 {}
        abstract class C extends D {}
        interface IX extends IY {}
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "tsx", path: "a.tsx")
        let impls = r.edges.filter { $0.kind == "implements" }.map { $0.dstName }
        // extends + both implements targets.
        XCTAssertTrue(impls.contains("B"))
        XCTAssertTrue(impls.contains("I1"))
        XCTAssertTrue(impls.contains("I2"))
        // abstract class heritage and interface extends.
        XCTAssertTrue(impls.contains("D"))
        XCTAssertTrue(impls.contains("IY"))
    }

    func testImplementsRust() throws {
        let src = """
        impl Drawable for Circle {}
        impl Circle {}
        impl<T> G<T> for H<T> {}
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "rust", path: "a.rs")
        let impls = r.edges.filter { $0.kind == "implements" }.map { $0.dstName }
        XCTAssertTrue(impls.contains("Drawable"))
        // generic trait impl: base name, not the type parameter.
        XCTAssertTrue(impls.contains("G"))
        // inherent `impl Circle` emits no implements edge.
        XCTAssertFalse(impls.contains("Circle"))
        XCTAssertFalse(impls.contains("H"))
        XCTAssertFalse(impls.contains("T"))
    }

    func testIndexAndSearch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def alpha(): return beta()\ndef beta(): return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try "const run = () => alpha();\n".write(
            to: dir.appendingPathComponent("m.js"), atomically: true, encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        let report = try Indexer(store: store).run(force: true)
        XCTAssertEqual(report.filesIndexed, 2)
        XCTAssertGreaterThan(report.chunks, 0)

        let hits = try Search.fts(store: store, query: "alpha", limit: 5)
        XCTAssertFalse(hits.isEmpty)
    }

    /// foldText: case + diacritic fold for path/term matching, with explicit
    /// đ/Đ → d (Unicode diacritic folding leaves those letters intact).
    func testFoldText() {
        XCTAssertEqual(Search.foldText("Đăng Nhập"), "dang nhap")
        XCTAssertEqual(Search.foldText("Đường"), "duong")
        XCTAssertEqual(Search.foldText("CRM"), "crm")
        XCTAssertEqual(Search.foldText("xac_thuc"), "xac_thuc")
    }

    /// Path boost matches whole folded path tokens, not substrings: a VN
    /// query term must boost `dang_nhap.md`, while "quantri" must NOT boost
    /// `bequantri.md` (substring) — only the exact-token file wins.
    func testPathBoostFoldedTokenBoundary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "xac thuc nguoi dung qua he thong\n"
        for name in ["dang_nhap.md", "ghi_chu.md", "bequantri.md", "quantri_ghi_so.md"] {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        let emb = Embedder()

        let vn = try Search.hybrid(store: store, embedder: emb,
                                   query: "đăng nhập xác thực", limit: 4,
                                   includeVector: false)
        XCTAssertEqual(vn.first?.path, "dang_nhap.md")

        let sub = try Search.hybrid(store: store, embedder: emb,
                                    query: "quantri xac thuc", limit: 4,
                                    includeVector: false)
        XCTAssertEqual(sub.first?.path, "quantri_ghi_so.md")
        XCTAssertNotEqual(sub.first?.path, "bequantri.md")
    }

    /// Edge resolution precedence: qualified call via import alias, same-file
    /// `self.`, imported-file bare call, ambiguous cross-file name stays NULL.
    func testResolveEdgesPasses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def helper():\n    return 1\n".write(
            to: dir.appendingPathComponent("mod.py"), atomically: true, encoding: .utf8)
        try """
        import mod as m

        def run():
            return m.helper()
        """.write(to: dir.appendingPathComponent("caller.py"), atomically: true, encoding: .utf8)
        try """
        class Worker:
            def run(self):
                return self._h()

            def _h(self):
                return 1
        """.write(to: dir.appendingPathComponent("w.py"), atomically: true, encoding: .utf8)
        try "def dup():\n    return 1\n".write(
            to: dir.appendingPathComponent("d1.py"), atomically: true, encoding: .utf8)
        try "def dup():\n    return 2\n".write(
            to: dir.appendingPathComponent("d2.py"), atomically: true, encoding: .utf8)
        try "def use():\n    return dup()\n".write(
            to: dir.appendingPathComponent("user.py"), atomically: true, encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)

        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.dst_name, e.qualifier, sf.path AS src, df.path AS dst
                FROM edges e
                JOIN chunks sc ON sc.id = e.src_chunk
                JOIN files sf ON sf.id = sc.file_id
                LEFT JOIN chunks dc ON dc.id = e.dst_chunk
                LEFT JOIN files df ON df.id = dc.file_id
                WHERE e.kind = 'calls'
                """)
        }
        func find(_ name: String, src: String) -> Row? {
            rows.first { ($0["dst_name"] as? String) == name
                && ($0["src"] as? String) == src }
        }
        // m.helper() — qualifier 'm' resolves through `import mod as m`.
        let qualified = try XCTUnwrap(find("helper", src: "caller.py"))
        XCTAssertEqual(qualified["qualifier"] as? String, "m")
        XCTAssertEqual(qualified["dst"] as? String, "mod.py")
        // self._h() — same-file resolution.
        let selfCall = try XCTUnwrap(find("_h", src: "w.py"))
        XCTAssertEqual(selfCall["qualifier"] as? String, "self")
        XCTAssertEqual(selfCall["dst"] as? String, "w.py")
        // dup() defined in two files — stays unresolved rather than guessing.
        let ambiguous = try XCTUnwrap(find("dup", src: "user.py"))
        XCTAssertNil(ambiguous["dst"] as? String)
    }

    func testRecordsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(workspaceRoot: dir)

        let id = try store.insertRecord(kind: "context_pack", source: "test",
                                      title: "gsc pipeline", payload: ["n": 2])
        let (row, ftsHit) = try store.pool.read { db in
            let r = try Row.fetchOne(db, sql:
                "SELECT kind, title FROM records WHERE id = ?", arguments: [id])
            let h = try Int64.fetchOne(db, sql:
                "SELECT rowid FROM records_fts WHERE records_fts MATCH ?",
                arguments: ["\"gsc\""])
            return (r, h)
        }
        XCTAssertEqual(row?["kind"] as? String, "context_pack")
        XCTAssertEqual(ftsHit, id)
    }

    /// Regression: `search mode=semantic` must honor `path` (was dropped at
    /// dispatch). Requires the BGE model; skipped when not installed.
    func testSemanticSearchHonorsPath() async throws {
        guard BGEEmbedder.isInstalled else {
            throw XCTSkip("bge-base-en-v1.5 not installed (swctx model install)")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("b"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def fetch_weather():\n    return 'rain'\n".write(
            to: dir.appendingPathComponent("a/wx.py"), atomically: true, encoding: .utf8)
        try "def fetch_stocks():\n    return 'up'\n".write(
            to: dir.appendingPathComponent("b/st.py"), atomically: true, encoding: .utf8)

        let report = try Indexer(store: Store(workspaceRoot: dir)).run(force: true)
        XCTAssertGreaterThan(report.embeddedChunks, 0)

        let out = try await SwctxTools.call(name: "search", arguments: [
            "workspace": .string(dir.path), "query": .string("fetch"),
            "mode": .string("semantic"), "path": .string("a"), "limit": .int(10),
        ])
        let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let hits = payload?["hits"] as? [[String: Any]] ?? []
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { ($0["path"] as? String)?.hasPrefix("a/") == true })
    }

    /// Exact-symbol leg: a query token matching a symbol name must surface
    /// the defining chunk, and prose docs mentioning the word must not
    /// appear in the symbol leg at all (site-M "trimmed" regression).
    func testSymbolLegSurfacesDefinitions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "func trimmed() -> Int {\n    return 1\n}\n".write(
            to: dir.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        try "# Plan\n\ntrimmed trimmed trimmed scope trimmed notes trimmed.\n".write(
            to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        _ = try Indexer(store: store).run(force: true)

        let hits = try Search.symbolHits(store: store, query: "trimmed", limit: 10)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.path == "code.swift" })

        // A word that exists only in prose is not a symbol -> empty leg.
        let prose = try Search.symbolHits(store: store, query: "scope", limit: 10)
        XCTAssertTrue(prose.isEmpty)
    }

    /// get_status reports disk-vs-index drift: content edits and deletions
    /// count as stale, new files count separately, untouched is zero.
    func testStatusFreshness() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def a():\n    return 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def b():\n    return 2\n".write(
            to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)

        func freshness(deep: Bool = false) async throws -> [String: Any] {
            var args: [String: Value] = ["workspace": .string(dir.path)]
            if deep { args["freshness"] = .string("deep") }
            let out = try await SwctxTools.call(name: "get_status", arguments: args)
            let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
            return ((payload?["meta"] as? [String: Any])?["freshness"] as? [String: Any]) ?? [:]
        }
        var f = try await freshness()
        XCTAssertEqual(f["stale_files"] as? Int, 0)
        // Shallow scan does not walk the disk: no new_files key.
        XCTAssertNil(f["new_files"])

        try "def a():\n    return 99\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.py"))
        try "def c():\n    return 3\n".write(
            to: dir.appendingPathComponent("c.py"), atomically: true, encoding: .utf8)
        f = try await freshness()
        XCTAssertEqual(f["stale_files"] as? Int, 2)   // a.py changed + b.py deleted
        f = try await freshness(deep: true)
        XCTAssertEqual(f["new_files"] as? Int, 1)     // c.py
    }

    /// find_definitions returns a stable symbol_id and find_usages can pin
    /// usages to that exact definition via definition_symbol_id.
    func testDefinitionSymbolIdSelector() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def target():\n    return 1\n".write(
            to: dir.appendingPathComponent("lib.py"), atomically: true, encoding: .utf8)
        try "from lib import target\ndef run():\n    return target()\n".write(
            to: dir.appendingPathComponent("app.py"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)

        let defsOut = try await SwctxTools.call(name: "find_definitions", arguments: [
            "workspace": .string(dir.path), "symbols": .array([.string("target")]),
        ])
        let defsPayload = try JSONSerialization.jsonObject(with: Data(defsOut.utf8)) as? [String: Any]
        let defs = ((defsPayload?["results"] as? [[String: Any]])?.first)?["definitions"]
            as? [[String: Any]]
        let symID = try XCTUnwrap(defs?.first?["symbol_id"] as? Int)
        // Metadata-first default: no source body unless asked.
        XCTAssertNil(defs?.first?["content"])

        let useOut = try await SwctxTools.call(name: "find_usages", arguments: [
            "workspace": .string(dir.path),
            "definition_symbol_id": .int(symID),
        ])
        let usePayload = try JSONSerialization.jsonObject(with: Data(useOut.utf8)) as? [String: Any]
        let usages = usePayload?["usages"] as? [[String: Any]] ?? []
        XCTAssertTrue(usages.contains { ($0["path"] as? String) == "app.py" })
    }

    /// workspace resolution: omitted/"auto" walks up from cwd to the nearest
    /// indexed ancestor; a nested path with use_workspace_root does the same.
    func testWorkspaceAutoResolve() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        let nested = dir.appendingPathComponent("sub/dir")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def f():\n    return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)

        XCTAssertEqual(SwctxTools.indexedAncestor(of: nested)?.path, dir.path)
        let resolved = try SwctxTools.workspace([
            "workspace": .string(nested.path), "use_workspace_root": .bool(true)])
        XCTAssertEqual(resolved.path, dir.path)
    }

    /// get_workspace_tree filters: max_depth bounds components below root,
    /// query is a path substring match.
    func testWorkspaceTreeFilters() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("pkg/deep"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x = 1\n".write(to: dir.appendingPathComponent("top.py"),
                            atomically: true, encoding: .utf8)
        try "x = 2\n".write(to: dir.appendingPathComponent("pkg/mid.py"),
                            atomically: true, encoding: .utf8)
        try "x = 3\n".write(to: dir.appendingPathComponent("pkg/deep/low.py"),
                            atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)

        let out = try await SwctxTools.call(name: "get_workspace_tree", arguments: [
            "workspace": .string(dir.path), "max_depth": .int(1),
        ])
        let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let files = payload?["files"] as? [[String: Any]] ?? []
        XCTAssertEqual(files.compactMap { $0["path"] as? String }, ["top.py"])

        let out2 = try await SwctxTools.call(name: "get_workspace_tree", arguments: [
            "workspace": .string(dir.path), "query": .string("deep"),
        ])
        let payload2 = try JSONSerialization.jsonObject(with: Data(out2.utf8)) as? [String: Any]
        let files2 = payload2?["files"] as? [[String: Any]] ?? []
        XCTAssertEqual(files2.compactMap { $0["path"] as? String }, ["pkg/deep/low.py"])
    }

    /// graph_paths strategy=all_simple enumerates simple paths via DFS —
    /// including non-shortest routes that shortest/BFS would not return.
    func testGraphPathsAllSimple() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // a -> b -> d and a -> c -> d: two distinct simple paths.
        try """
        def a():
            return b() + c()
        def b():
            return d()
        def c():
            return d()
        def d():
            return 1
        """.write(to: dir.appendingPathComponent("g.py"), atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)

        func chunkID(of symbol: String) throws -> Int64 {
            try store.pool.read { db in
                try XCTUnwrap(Int64.fetchOne(db, sql: """
                    SELECT s.chunk_id FROM symbols s WHERE s.name = ? AND s.chunk_id IS NOT NULL
                    """, arguments: [symbol]))
            }
        }
        let out = try await SwctxTools.call(name: "graph_paths", arguments: [
            "workspace": .string(dir.path),
            "from_chunk_id": .int(Int(try chunkID(of: "a"))),
            "to_chunk_id": .int(Int(try chunkID(of: "d"))),
            "strategy": .string("all_simple"), "max_paths": .int(10),
        ])
        let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let paths = payload?["paths"] as? [[Any]] ?? []
        XCTAssertEqual(paths.count, 2)
    }

    /// index_workspace dry_run reports the pending change set without writes.
    func testIndexDryRun() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def a():\n    return 1\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)
        try "def a():\n    return 2\n".write(
            to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def n():\n    return 9\n".write(
            to: dir.appendingPathComponent("new.py"), atomically: true, encoding: .utf8)

        let out = try await SwctxTools.call(name: "index_workspace", arguments: [
            "workspace": .string(dir.path), "dry_run": .bool(true)])
        let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual(payload?["filesChanged"] as? Int, 1)
        XCTAssertEqual(payload?["filesNew"] as? Int, 1)
        // Dry-run wrote nothing: files table still has only the original row.
        let count = try await Store(workspaceRoot: dir).pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM files")
        }
        XCTAssertEqual(count, 1)
    }

    /// `.gitignore` `dir/*/` patterns must prune by the static prefix —
    /// a wildcard does not become literal text (root vendors/ regression).
    func testIgnorePatternDirStarSlash() throws {
        // Dir rels arrive with a trailing "/" (discoverFiles convention).
        XCTAssertTrue(Indexer.matches("vendors/*/", relPath: "vendors/foo/"))
        // Files UNDER an ignored dir match via the ancestor prefix —
        // the watcher depends on this for events inside ignored trees.
        XCTAssertTrue(Indexer.matches("vendors/*/", relPath: "vendors/foo/deep.txt"))
        // …but a bare FILE named "foo" at vendors level is not a dir.
        XCTAssertFalse(Indexer.matches("vendors/*/", relPath: "vendors/foo"))
        XCTAssertFalse(Indexer.matches("vendors/*/", relPath: "src/foo"))
        // Plain `dir/` keeps working.
        XCTAssertTrue(Indexer.matches("build/", relPath: "build/out.o"))
        // `*.x/` has no static prefix — it must glob the basename
        // (`*.egg-info/` in this repo's .gitignore once pruned EVERY
        // directory because the empty prefix produced a "//" contains-check
        // against dir relPaths that already end in "/").
        XCTAssertTrue(Indexer.matches("*.egg-info/", relPath: "pkg.egg-info/"))
        XCTAssertTrue(Indexer.matches("*.egg-info/", relPath: "sub/pkg.egg-info/"))
        XCTAssertFalse(Indexer.matches("*.egg-info/", relPath: "Sources/"))
        XCTAssertFalse(Indexer.matches("*.egg-info/", relPath: "Sources/Core.swift"))
        // Bare `*/` is git-consistent: it ignores every directory.
        XCTAssertTrue(Indexer.matches("*/", relPath: "anything/"))
        // …but directory-only patterns never match FILES — `*/` or
        // `*.egg-info/` must leave README.md / pkg.egg-info (a file)
        // alone (Grok delta-review).
        XCTAssertFalse(Indexer.matches("*/", relPath: "README.md"))
        XCTAssertFalse(Indexer.matches("*.egg-info/", relPath: "pkg.egg-info"))
        XCTAssertFalse(Indexer.matches("*.egg-info/", relPath: "sub/pkg.egg-info"))
        // `*/build/` is anchored: exactly one directory level deep —
        // `*` never crosses "/".
        XCTAssertTrue(Indexer.matches("*/build/", relPath: "foo/build/"))
        XCTAssertFalse(Indexer.matches("*/build/", relPath: "foo/bar/build/"))
        XCTAssertFalse(Indexer.matches("*/build/", relPath: "build/"))
    }

    /// Derivational stems bridge FTS prefix matching — "compare" can
    /// never reach "comparison" ("compar" diverges at char 7), so the
    /// stem is emitted as its own atom. Acronym atoms turn consecutive
    /// query words into filename initials ("google apps script"→"gas").
    func testStemAndAcronymAtoms() {
        XCTAssertEqual(Search.stemAtom("compare"), "compar")
        XCTAssertEqual(Search.stemAtom("comparison"), "compar")
        XCTAssertEqual(Search.stemAtom("comparing"), "compar")
        XCTAssertEqual(Search.stemAtom("posting"), "post")
        XCTAssertNil(Search.stemAtom("diff"))   // no suffix match
        XCTAssertNil(Search.stemAtom("run"))    // <5 chars
        let ac = Search.acronymAtoms(
            ["google", "apps", "script", "backend"])
        XCTAssertTrue(ac.contains("gas"))
        XCTAssertTrue(ac.contains("asb"))
        XCTAssertFalse(ac.contains("ga"))  // windows are 3-4 words
    }

    /// plannerProbeAtomSets: stems are weak AND championless (supporting
    /// evidence only); acronyms are weak (no surgical — prefix
    /// coincidences like "rat"→"rating") but keep champion rights
    /// (gas.ts is a deliberate name rescue).
    func testProbeAtomSetsPrivilegeTiers() {
        let (atoms, weak, championless) = Search.plannerProbeAtomSets(
            query: "compare two saved audit runs")
        XCTAssertTrue(atoms.contains("compar"))
        XCTAssertTrue(weak.contains("compar"))
        XCTAssertTrue(championless.contains("compar"))
        XCTAssertTrue(atoms.contains("compare"))
        XCTAssertFalse(weak.contains("compare"))
        let (atoms2, weak2, championless2) = Search.plannerProbeAtomSets(
            query: "google apps script backend")
        XCTAssertTrue(atoms2.contains("gas"))
        XCTAssertTrue(weak2.contains("gas"))
        XCTAssertFalse(championless2.contains("gas"))
    }

    /// Long glued query tokens emit weak+championless subword
    /// candidates — "serpupdate" must probe "serp" (the head that
    /// actually names nap_serp.py); short tokens emit none, and
    /// subwords never crown surgical or champion a file.
    func testProbeSubwordAtoms() {
        let (atoms, weak, championless) = Search.plannerProbeAtomSets(
            query: "script nạp file csv export từ serpupdate")
        XCTAssertTrue(atoms.contains("serp"))
        XCTAssertTrue(atoms.contains("serpupdate"))
        XCTAssertTrue(weak.contains("serp"))
        XCTAssertTrue(championless.contains("serp"))
        // Short tokens emit no subword candidates.
        let (atoms2, _, _) = Search.plannerProbeAtomSets(query: "cat dog")
        XCTAssertFalse(atoms2.contains("ca"))
        XCTAssertFalse(atoms2.contains("do"))
    }

    /// Reformulation guesses land as weak, champion-ELIGIBLE atoms —
    /// a guessed token that names a file is name evidence (the model
    /// pointed at that word), but it never earns surgical: a
    /// hallucination must not crown. Guesses emit ahead of stems so
    /// dense queries spend the 24-cap on real vocabulary first.
    func testProbeGuessedAtomsWeakChampionEligible() {
        let (atoms, weak, championless) = Search.plannerProbeAtomSets(
            query: "tóm tắt hoạt động hôm qua",
            guessedTerms: ["so_tay", "daily digest", "deadline"])
        XCTAssertTrue(atoms.contains("tay"))
        XCTAssertTrue(atoms.contains("digest"))
        XCTAssertTrue(atoms.contains("deadline"))
        // "so" is under the 3-char atom floor — compounds still land
        // via their longer part.
        XCTAssertFalse(atoms.contains("so"))
        for a in ["tay", "digest", "deadline", "daily"] {
            XCTAssertTrue(weak.contains(a), "\(a) must be weak")
            XCTAssertFalse(championless.contains(a),
                           "\(a) stays champion-eligible")
        }
        // Stems still derive from query atoms, not from guesses:
        // stemAtom("deadline") must NOT appear as a weak stem.
        XCTAssertFalse(atoms.contains("deadlin"))
    }

    /// A file fetched ONLY by a stem atom and scoring below the rank
    /// bar must not be champion-emitted; the same file fetched by an
    /// acronym atom IS champion-eligible (the filename IS the phrase's
    /// initials — a deliberate rescue, unlike morphology).
    func testProbeWeakAtomEarnsNoChampion() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("plan"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // "compare_runs" stem {compare,runs}: token "compare" stem-
        // claims atom "compar" → density 0.5 → rank 1.5 < 2.0 bar —
        // only a champion could save it.
        try "x = 1\n".write(
            to: dir.appendingPathComponent("plan/compare_runs.md"),
            atomically: true, encoding: .utf8)
        try "y = 2\n".write(
            to: dir.appendingPathComponent("plan/gas.ts"),
            atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        _ = try Indexer(store: store).run(force: true, autoEmbed: false)
        // Stem atom: no champion → dropped below the bar.
        let stemmed = try Search.plannerPathProbe(
            store: store, atoms: ["compar"],
            weakAtoms: ["compar"], championlessAtoms: ["compar"])
        XCTAssertTrue(stemmed.isEmpty)
        // Same atom full-privilege: champion rescues it.
        let full = try Search.plannerPathProbe(
            store: store, atoms: ["compar"])
        XCTAssertEqual(full.first?.path, "plan/compare_runs.md")
        // Acronym atom: weak (no surgical) but champion-eligible —
        // "gas" names plan/gas.ts, density 0.5 → below bar → champion.
        let acronym = try Search.plannerPathProbe(
            store: store, atoms: ["gas"], weakAtoms: ["gas"])
        XCTAssertEqual(acronym.first?.path, "plan/gas.ts")
    }

    /// Directory URLs from the enumerator carry a trailing "/", so `rel`
    /// for dirs arrives as "Sources/" — `rel + "/"` must not become "//"
    /// and match an empty-prefix `*/` pattern. Full-pipeline regression:
    /// a repo whose .gitignore has `*.egg-info/` must still index Sources/.
    func testStarSlashGitignoreDoesNotPruneAllDirs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("pkg.egg-info"), withIntermediateDirectories: true)
        try "def a(): return 1\n".write(
            to: dir.appendingPathComponent("Sources/x.py"), atomically: true,
            encoding: .utf8)
        try "def b(): return 2\n".write(
            to: dir.appendingPathComponent("pkg.egg-info/y.py"), atomically: true,
            encoding: .utf8)
        try "*.egg-info/\n*.pyc\n".write(
            to: dir.appendingPathComponent(".gitignore"), atomically: true,
            encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        let paths = try store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM files ORDER BY path")
        }
        XCTAssertEqual(paths, ["Sources/x.py"])
    }

    /// Constructor-like callees emit `instantiates` in addition to `calls`;
    /// lowercase functions emit `calls` only.
    func testInstantiatesEdge() throws {
        let src = """
        let a = Foo()
        let b = bar()
        let c = Baz()
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "swift", path: "a.swift")
        let inst = r.edges.filter { $0.kind == "instantiates" }.map { $0.dstName }
        let calls = r.edges.filter { $0.kind == "calls" }.map { $0.dstName }
        XCTAssertTrue(inst.contains("Foo"))
        XCTAssertTrue(inst.contains("Baz"))
        XCTAssertFalse(inst.contains("bar"))
        XCTAssertTrue(calls.contains("Foo"))
        XCTAssertTrue(calls.contains("bar"))
    }

    /// Type annotations emit `uses_type` for nominal (uppercase) types;
    /// denylisted builtins are suppressed.
    func testUsesTypeEdge() throws {
        let src = """
        let x: MyWidget = mk()
        func f(a: CustomThing, s: String, n: Int) -> Result<MyWidget, E> {}
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "swift", path: "a.swift")
        let refs = r.edges.filter { $0.kind == "uses_type" }.map { $0.dstName }
        XCTAssertTrue(refs.contains("MyWidget"))
        XCTAssertTrue(refs.contains("CustomThing"))
        XCTAssertFalse(refs.contains("String"))
        XCTAssertFalse(refs.contains("Int"))
        XCTAssertFalse(refs.contains("Result"))
    }

    /// Post-resolution relabel: inheritance to a resolved concrete type becomes
    /// `extends`; a resolved protocol/interface target stays `implements`.
    func testExtendsVsImplementsRelabel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        class Base {}
        interface I {}
        class Child extends Base {}
        class Impl implements I {}
        """.write(to: dir.appendingPathComponent("m.ts"), atomically: true,
                  encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, dst_name FROM edges
                WHERE kind IN ('extends','implements')
                """)
        }
        let kinds = Dictionary(rows.map { ($0["dst_name"] as! String,
                                           $0["kind"] as! String) },
                               uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(kinds["Base"], "extends")
        XCTAssertEqual(kinds["I"], "implements")
    }

    /// `.swctxignore` excludes files from indexing without touching `.gitignore`.
    func testSwctxIgnoreFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("secret"), withIntermediateDirectories: true)
        try "def hidden(): return 1\n".write(
            to: dir.appendingPathComponent("secret/x.py"), atomically: true,
            encoding: .utf8)
        try "def visible(): return 1\n".write(
            to: dir.appendingPathComponent("ok.py"), atomically: true, encoding: .utf8)
        try "secret/\n".write(
            to: dir.appendingPathComponent(".swctxignore"), atomically: true,
            encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        let paths = try store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM files ORDER BY path")
        }
        XCTAssertEqual(paths, ["ok.py"])
    }

    /// Swift's vendored grammar emits `class_declaration` for struct/enum/
    /// extension too — `norm` must split them via the decl keyword while
    /// `kind` keeps the raw node type.
    func testNormKinds() throws {
        let src = """
        public struct Widget {}
        enum Mode { case a }
        class Base {}
        protocol P { func pf() }
        func top() {}
        let answer = 42
        """
        let r = Analyzer.analyze(bytes: Array(src.utf8), languageID: "swift", path: "a.swift")
        func norm(_ name: String) -> String? {
            r.symbols.first { $0.name == name }?.norm
        }
        XCTAssertEqual(norm("Widget"), "struct")
        XCTAssertEqual(norm("Mode"), "enum")
        XCTAssertEqual(norm("Base"), "class")
        XCTAssertEqual(norm("P"), "protocol")
        XCTAssertEqual(norm("top"), "function")
        XCTAssertEqual(norm("answer"), "variable")
        XCTAssertEqual(r.symbols.first { $0.name == "Widget" }?.kind,
                       "class_declaration")
    }

    /// norm_kind persists through indexing and surfaces in find_definitions
    /// as `kind` with the raw node type retained as `raw_kind`.
    func testNormKindsPersisted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "struct Point { let x: Int }\nclass Box {}\n".write(
            to: dir.appendingPathComponent("m.swift"), atomically: true,
            encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        let rows: [Row] = try await store.pool.read {
            try Row.fetchAll($0, sql:
                "SELECT name, kind, norm_kind FROM symbols ORDER BY name")
        }
        let norm = Dictionary(uniqueKeysWithValues: rows.map {
            (($0["name"] as? String) ?? "", ($0["norm_kind"] as? String) ?? "")
        })
        XCTAssertEqual(norm["Point"], "struct")
        XCTAssertEqual(norm["Box"], "class")

        let out = try await SwctxTools.call(name: "find_definitions", arguments: [
            "workspace": .string(dir.path), "symbols": .array([.string("Point")]),
        ])
        let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let defs = ((payload?["results"] as? [[String: Any]])?.first)?["definitions"]
            as? [[String: Any]]
        XCTAssertEqual(defs?.first?["kind"] as? String, "struct")
        XCTAssertEqual(defs?.first?["raw_kind"] as? String, "class_declaration")
    }

    /// Schema v2 -> v3 upgrade: existing rows get norm_kind backfilled from
    /// kind + signature.
    func testNormKindBackfill() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "enum E { case a }\nstruct S {}\n".write(
            to: dir.appendingPathComponent("m.swift"), atomically: true,
            encoding: .utf8)

        let store = try Store(workspaceRoot: dir)
        try Indexer(store: store).run(force: true)
        // Simulate a pre-v3 index: norm_kind NULL + version 2, then reopen —
        // migrate() runs the backfill path.
        try store.pool.write { db in
            try db.execute(sql: "UPDATE symbols SET norm_kind = NULL")
            try db.execute(sql: "UPDATE meta SET value = '2' WHERE key = 'schema_version'")
        }
        _ = try Store(workspaceRoot: dir)
        let norm = try store.pool.read { db in
            try Row.fetchAll(db, sql:
                "SELECT name, norm_kind FROM symbols ORDER BY name")
        }
        let map = Dictionary(uniqueKeysWithValues: norm.map {
            (($0["name"] as? String) ?? "", ($0["norm_kind"] as? String) ?? "")
        })
        XCTAssertEqual(map["E"], "enum")
        XCTAssertEqual(map["S"], "struct")
    }

    /// mode=auto routes identifier-shaped queries to the deterministic
    /// FTS+symbol path and prose to full fusion; the response advertises the
    /// resolved mode.
    func testSearchModeAuto() async throws {
        XCTAssertTrue(Search.identifierLike("SiteCleanup"))
        XCTAssertTrue(Search.identifierLike("find_usages"))
        XCTAssertTrue(Search.identifierLike("Foo.Bar::baz"))
        XCTAssertTrue(Search.identifierLike("Sources/App.swift"))
        XCTAssertFalse(Search.identifierLike("how does login work"))
        XCTAssertFalse(Search.identifierLike("authentication"))
        XCTAssertFalse(Search.identifierLike(""))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def fetch_user():\n    return 1\n".write(
            to: dir.appendingPathComponent("m.py"), atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)

        let out = try await SwctxTools.call(name: "search", arguments: [
            "workspace": .string(dir.path), "query": .string("fetch_user"),
        ])
        let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual(payload?["mode"] as? String, "auto")
        XCTAssertEqual(payload?["resolved_mode"] as? String, "identifier")

        let nl = try await SwctxTools.call(name: "search", arguments: [
            "workspace": .string(dir.path), "query": .string("fetch a user record"),
        ])
        let nlPayload = try JSONSerialization.jsonObject(with: Data(nl.utf8)) as? [String: Any]
        XCTAssertEqual(nlPayload?["resolved_mode"] as? String, "hybrid")
    }

    /// Output-budget contract: max_tokens trims arrays tail-first and reports
    /// meta.omitted; an impossible budget yields E_OUTPUT_TOO_LARGE; every
    /// response carries truncation_applied + content_status.
    func testOutputBudget() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<40 {
            try "def fn_\(i)():\n    return \(i)\n".write(
                to: dir.appendingPathComponent("f\(i).py"), atomically: true,
                encoding: .utf8)
        }
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)

        // Unbudgeted: everything present, meta says full.
        let full = try await SwctxTools.call(name: "get_workspace_tree", arguments: [
            "workspace": .string(dir.path),
        ])
        let fullP = try JSONSerialization.jsonObject(with: Data(full.utf8)) as? [String: Any]
        XCTAssertEqual((fullP?["files"] as? [[String: Any]])?.count, 40)
        XCTAssertEqual((fullP?["meta"] as? [String: Any])?["truncation_applied"] as? Bool, false)
        XCTAssertEqual((fullP?["meta"] as? [String: Any])?["content_status"] as? String, "full")

        // Tight budget: files trimmed, omitted reported.
        let tight = try await SwctxTools.call(name: "get_workspace_tree", arguments: [
            "workspace": .string(dir.path), "max_tokens": .int(150),
        ])
        let tightP = try JSONSerialization.jsonObject(with: Data(tight.utf8)) as? [String: Any]
        let files = (tightP?["files"] as? [[String: Any]]) ?? []
        XCTAssertLessThan(files.count, 40)
        let meta = tightP?["meta"] as? [String: Any]
        XCTAssertEqual(meta?["truncation_applied"] as? Bool, true)
        let omitted = meta?["omitted"] as? [String: Any]
        XCTAssertEqual(omitted?["reason"] as? String, "max_tokens")
        XCTAssertEqual((omitted?["items"] as? Int) ?? 0, 40 - files.count)
        XCTAssertLessThanOrEqual(tight.utf8.count, 700)

        // Impossible budget: hard error envelope.
        let tiny = try await SwctxTools.call(name: "get_workspace_tree", arguments: [
            "workspace": .string(dir.path), "max_tokens": .int(1),
        ])
        let tinyP = try JSONSerialization.jsonObject(with: Data(tiny.utf8)) as? [String: Any]
        XCTAssertEqual((tinyP?["error"] as? [String: Any])?["code"] as? String,
                       "E_OUTPUT_TOO_LARGE")

        // Oversized single content truncates instead of dropping the chunk.
        let bigDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bigDir) }
        let body = "def big():\n" + (0..<400).map {
            "    # \($0) " + String(repeating: "x", count: 40)
        }.joined(separator: "\n")
        try body.write(to: bigDir.appendingPathComponent("big.py"),
                       atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: bigDir)).run(force: true)
        let chunks = try await SwctxTools.call(name: "inspect_path", arguments: [
            "workspace": .string(bigDir.path), "path": .string("big.py"),
        ])
        let chunksP = try JSONSerialization.jsonObject(with: Data(chunks.utf8)) as? [String: Any]
        let allChunks = (chunksP?["chunks"] as? [[String: Any]]) ?? []
        let chunkID = allChunks.max(by: {
            (($0["end_line"] as? Int) ?? 0) < (($1["end_line"] as? Int) ?? 0)
        })?["chunk_id"] as? Int
        let fetch = try await SwctxTools.call(name: "fetch_chunks", arguments: [
            "workspace": .string(bigDir.path),
            "chunk_ids": .array([.int(chunkID ?? -1)]),
            "max_tokens": .int(300),
        ])
        let fetchP = try JSONSerialization.jsonObject(with: Data(fetch.utf8)) as? [String: Any]
        let content = ((fetchP?["chunks"] as? [[String: Any]])?.first)?["content"] as? String
        XCTAssertNotNil(content)
        XCTAssertTrue(content?.contains("[truncated]") ?? false)
    }
}
