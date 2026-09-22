import XCTest
@testable import SwctxCore
import GRDB
import MCP

/// graph_paths traversal — frontier-batched BFS (shortest) and per-node
/// neighbor queries (all_simple) over the resolved-edge table.
final class GraphPathsTests: SwctxTestCase {
    /// Temp workspace + direct-SQL fixture: precise edge control and
    /// deterministic chunk ids/row order without running the indexer.
    private func makeWorkspace(
        chunks: [Int64: String],
        edges: [(src: Int64, dst: Int64, kind: String)]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(workspaceRoot: dir)
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO files(path, lang, sha, size, mtime, indexed_at)
                VALUES('g.py', 'python', 'x', 0, 0, 0)
                """)
            let fileID = db.lastInsertedRowID
            for (id, sym) in chunks.sorted(by: { $0.key < $1.key }) {
                try db.execute(sql: """
                    INSERT INTO chunks(id, file_id, idx, start_line, end_line,
                                       kind, symbol, content, tokens)
                    VALUES(?,?,0,1,2,'function',?,?,0)
                    """, arguments: [id, fileID, sym, "def \(sym)(): pass"])
            }
            for e in edges {
                try db.execute(sql: """
                    INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind, line)
                    VALUES(?,?,?,?,1)
                    """, arguments: [e.src, e.dst, chunks[e.dst] ?? "?", e.kind])
            }
        }
        return dir
    }

    /// Parse a graph_paths response into (found, paths as chunk-id lists).
    private func pathIDs(_ out: String) throws -> (found: Int, paths: [[Int]]) {
        let payload = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let paths = ((payload?["paths"] as? [[Any]]) ?? []).map { p in
            p.compactMap { ($0 as? [String: Any])?["chunk_id"] as? Int }
        }
        return (payload?["found"] as? Int ?? -1, paths)
    }

    private func graphPaths(_ dir: URL, from: Int, to: Int,
                            extra: [String: Value] = [:]) async throws -> (found: Int, paths: [[Int]]) {
        var args: [String: Value] = [
            "workspace": .string(dir.path),
            "from_chunk_id": .int(from), "to_chunk_id": .int(to),
        ]
        for (k, v) in extra { args[k] = v }
        let out = try await SwctxTools.call(name: "graph_paths", arguments: args)
        return try pathIDs(out)
    }

    /// a -> b -> c plus the a -> c shortcut: shortest picks the direct route
    /// (a, c), never the longer a -> b -> c detour.
    func testShortestPicksDirectRoute() async throws {
        let dir = try makeWorkspace(
            chunks: [1: "a", 2: "b", 3: "c"],
            edges: [(1, 2, "calls"), (2, 3, "calls"), (1, 3, "calls")])
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try await graphPaths(dir, from: 1, to: 3)
        XCTAssertEqual(r.found, 1)
        XCTAssertEqual(r.paths, [[1, 3]])
    }

    /// Same graph, strategy=all_simple: both simple paths are enumerated.
    func testAllSimpleEnumeratesBothPaths() async throws {
        let dir = try makeWorkspace(
            chunks: [1: "a", 2: "b", 3: "c"],
            edges: [(1, 2, "calls"), (2, 3, "calls"), (1, 3, "calls")])
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try await graphPaths(dir, from: 1, to: 3, extra: [
            "strategy": .string("all_simple"), "max_paths": .int(10),
        ])
        XCTAssertEqual(r.found, 2)
        XCTAssertEqual(Set(r.paths), Set([[1, 3], [1, 2, 3]]))
    }

    /// 600-node fan-out: the level-1 frontier exceeds the 500-id batch
    /// size, so traversal must issue >1 IN() query for that level — and the
    /// target is reachable only through a mid in the second batch. An
    /// `imports` shortcut checks edge_kinds still filters frontier scans.
    func testWideFrontierBeyondBatch() async throws {
        var chunks: [Int64: String] = [1: "root", 602: "target"]
        var edges: [(src: Int64, dst: Int64, kind: String)] = []
        for i in 0..<600 {
            let mid = Int64(i + 2) // mids: 2...601
            chunks[mid] = "mid_\(i)"
            edges.append((1, mid, "calls"))
        }
        edges.append((601, 602, "calls")) // only the last mid reaches target
        edges.append((1, 602, "imports")) // non-calls shortcut for the filter
        let dir = try makeWorkspace(chunks: chunks, edges: edges)
        defer { try? FileManager.default.removeItem(at: dir) }

        // calls-only: batches of the 600-wide frontier are scanned until
        // mid_599's edge lands target in the second batch.
        let filtered = try await graphPaths(dir, from: 1, to: 602, extra: [
            "edge_kinds": .array([.string("calls")]),
        ])
        XCTAssertEqual(filtered.found, 1)
        XCTAssertEqual(filtered.paths, [[1, 601, 602]])

        // Unfiltered: the imports edge is a resolved edge like any other —
        // it wins as the 1-hop path.
        let unfiltered = try await graphPaths(dir, from: 1, to: 602)
        XCTAssertEqual(unfiltered.found, 1)
        XCTAssertEqual(unfiltered.paths, [[1, 602]])
    }
}
