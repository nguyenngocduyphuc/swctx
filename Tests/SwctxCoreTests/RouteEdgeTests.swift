import XCTest
@testable import SwctxCore
import GRDB

/// Cross-boundary API links: a `fetch('/api/x')` call site must resolve
/// to the chunk holding the backend route def (`@app.get('/api/x')`),
/// via the route symbol the analyzer emits. The link then behaves like
/// any call edge — find_usages, graph_neighbors, get_impact all see it.
final class RouteEdgeTests: XCTestCase {

    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("web"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("api"), withIntermediateDirectories: true)
        // Backend: FastAPI-style route defs.
        try """
        from fastapi import FastAPI
        app = FastAPI()

        @app.get("/api/users")
        def list_users():
            return []

        @app.post("/api/users/{uid}/ban")
        def ban_user(uid: str):
            return {"ok": True}
        """.write(to: dir.appendingPathComponent("api/main.py"),
                  atomically: true, encoding: .utf8)
        // Frontend: fetch call sites, incl. one parameterized route.
        try """
        export async function loadUsers() {
            const res = await fetch('/api/users');
            return res.json();
        }

        export async function ban(uid) {
            return fetch(`/api/users/${uid}/ban`, { method: 'POST' });
        }
        """.write(to: dir.appendingPathComponent("web/client.ts"),
                  atomically: true, encoding: .utf8)
        // Noise control: a file path literal is not an api_call.
        try "GIT=/usr/bin/git\n".write(
            to: dir.appendingPathComponent("api/env.sh"),
            atomically: true, encoding: .utf8)
        try Indexer(store: Store(workspaceRoot: dir)).run(force: true)
        return dir
    }

    private func store(_ dir: URL) throws -> Store {
        try Store(workspaceRoot: dir)
    }

    /// The route def becomes a `route` symbol; the call site's api_call
    /// edge resolves to the handler chunk.
    func testFetchResolvesToRouteDef() throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir)

        // Route symbols exist.
        let routes = try s.pool.read { db in
            try String.fetchAll(db, sql:
                "SELECT name FROM symbols WHERE kind = 'route' ORDER BY name")
        }
        XCTAssertEqual(routes, ["/api/users", "/api/users/{uid}/ban"])

        // api_call edges from client.ts resolve to api/main.py chunks.
        let rows = try s.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sf.path AS src, df.path AS dst
                FROM edges e
                JOIN chunks sc ON sc.id = e.src_chunk
                JOIN files sf ON sf.id = sc.file_id
                LEFT JOIN chunks dc ON dc.id = e.dst_chunk
                LEFT JOIN files df ON df.id = dc.file_id
                WHERE e.kind = 'api_call' ORDER BY e.id
                """)
        }
        let resolved = rows.filter {
            ($0["src"] as? String) == "web/client.ts"
                && ($0["dst"] as? String) == "api/main.py"
        }
        // fetch('/api/users') resolves; the ${uid} template literal
        // legitimately does not (v1 doesn't normalize path params).
        XCTAssertEqual(resolved.count, 1)
    }

    /// A bare "/api/..." literal links too; filesystem paths don't.
    func testLiteralFallbackAndPathNoise() throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        const HELP = '/api/users';
        const BIN = '/usr/bin/git';
        """.write(to: dir.appendingPathComponent("web/help.ts"),
                  atomically: true, encoding: .utf8)
        try Indexer(store: try store(dir)).run(force: false)
        let s = try store(dir)
        let dsts = try s.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT e.dst_name FROM edges e
                JOIN chunks c ON c.id = e.src_chunk
                JOIN files f ON f.id = c.file_id
                WHERE f.path = 'web/help.ts' AND e.kind = 'api_call'
                """)
        }
        XCTAssertEqual(dsts, ["/api/users"])
        // And it resolved to the handler.
        let resolved = try s.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM edges e
                JOIN chunks c ON c.id = e.src_chunk
                JOIN files f ON f.id = c.file_id
                WHERE f.path = 'web/help.ts' AND e.kind = 'api_call'
                  AND e.dst_chunk IS NOT NULL
                """)
        }
        XCTAssertEqual(resolved, 1)
    }

    /// The def line itself must not self-report as a call site.
    func testDefLineIsNotACallSite() throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir)
        let selfCalls = try s.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM edges e
                JOIN chunks c ON c.id = e.src_chunk
                JOIN files f ON f.id = c.file_id
                WHERE f.path = 'api/main.py' AND e.kind = 'api_call'
                """)
        }
        XCTAssertEqual(selfCalls, 0)
    }
}
