import XCTest
@testable import SwctxCore
import GRDB
import MCP

/// Usage telemetry ledger: usage_events in the global records DB
/// (GlobalRecords path-init seam keeps these off ~/.swctx).
final class UsageTelemetryTests: SwctxTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ledger at a temp path + the dir to clean up.
    private func tempLedger() throws -> (GlobalRecords, URL) {
        let dir = try tempDir()
        let g = try GlobalRecords(
            path: dir.appendingPathComponent("records.db").path)
        return (g, dir)
    }

    // MARK: - schema + insert

    func testUsageEventsTableCreatedOnFreshDB() throws {
        let (g, dir) = try tempLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try g.insertUsage(ws: "ws1", tool: "search", latencyMs: 12,
                          hits: 3, ok: true, query: "alpha")
        let row = try g.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM usage_events")
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["ws"] as? String, "ws1")
        XCTAssertEqual(row?["tool"] as? String, "search")
        XCTAssertEqual((row?["latency_ms"] as? Int64).map(Int.init), 12)
        XCTAssertEqual((row?["hits"] as? Int64).map(Int.init), 3)
        XCTAssertEqual((row?["ok"] as? Int64).map(Int.init), 1)
        XCTAssertEqual(row?["query"] as? String, "alpha")
        // records table must still be created alongside — both coexist.
        XCTAssertTrue(try g.pool.read { db in
            try db.tableExists("records")
        })
    }

    func testUsageEventsAddedToPreExistingLedger() throws {
        // A ledger created before usage_events existed (records only) must
        // gain the table on open — CREATE IF NOT EXISTS in the same write
        // block as the rest of the DDL.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("records.db").path
        let old = try DatabasePool(path: path)
        try old.write { db in
            try db.execute(sql: """
                CREATE TABLE records(
                    id INTEGER PRIMARY KEY,
                    ws TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    source TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'completed',
                    title TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    head_sha TEXT,
                    anchors TEXT);
                """)
        }
        let g = try GlobalRecords(path: path)
        try g.insertUsage(ws: "ws1", tool: "prime", latencyMs: 5,
                          hits: nil, ok: true, query: nil)
        let n = try g.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events")
        }
        XCTAssertEqual(n, 1)
    }

    // MARK: - aggregation

    func testUsageStatsPerTool() throws {
        let (g, dir) = try tempLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        for ms in [10, 20, 30, 40] {
            try g.insertUsage(ws: "ws1", tool: "search", latencyMs: ms,
                              hits: 1, ok: true, query: "q")
        }
        try g.insertUsage(ws: "ws1", tool: "search", latencyMs: 100,
                          hits: 0, ok: false, query: "q")
        for _ in 0..<2 {
            try g.insertUsage(ws: "ws2", tool: "prime", latencyMs: 50,
                              hits: nil, ok: true, query: nil)
        }
        let stats = try g.usageStats()
        XCTAssertEqual(stats.map(\.tool), ["search", "prime"],
                       "busiest tool first")
        let s = try XCTUnwrap(stats.first)
        XCTAssertEqual(s.calls, 5)
        XCTAssertEqual(s.errors, 1)
        XCTAssertEqual(s.avgMs, 40.0, accuracy: 0.001)
        XCTAssertEqual(s.p50Ms, 30)   // ceil(0.5*5)=3rd of [10,20,30,40,100]
        XCTAssertEqual(s.p95Ms, 100)  // ceil(0.95*5)=5th
        let p = try XCTUnwrap(stats.last)
        XCTAssertEqual(p.calls, 2)
        XCTAssertEqual(p.errors, 0)
        XCTAssertEqual(p.p50Ms, 50)
        XCTAssertEqual(p.p95Ms, 50)
    }

    func testPercentileEdgeCases() {
        XCTAssertEqual(GlobalRecords.percentile([], 0.5), 0)
        XCTAssertEqual(GlobalRecords.percentile([7], 0.5), 7)
        XCTAssertEqual(GlobalRecords.percentile([7], 0.95), 7)
        XCTAssertEqual(GlobalRecords.percentile([10, 20, 30, 40], 0.5), 20)
        XCTAssertEqual(GlobalRecords.percentile([10, 20, 30, 40], 0.95), 40)
    }

    func testZeroHitQueries() throws {
        let (g, dir) = try tempLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        for _ in 0..<3 {
            try g.insertUsage(ws: "ws1", tool: "search", latencyMs: 10,
                              hits: 0, ok: true, query: "flux capacitor")
        }
        try g.insertUsage(ws: "ws1", tool: "search", latencyMs: 10,
                          hits: 0, ok: true, query: "flux capacitor")
        // excluded: hits>0, a non-search tool, NULL query, failed calls
        // still count as zero-hit only when hits==0 (kept — the list is
        // "what returned nothing", regardless of ok).
        try g.insertUsage(ws: "ws1", tool: "search", latencyMs: 10,
                          hits: 2, ok: true, query: "flux capacitor")
        try g.insertUsage(ws: "ws1", tool: "find_usages", latencyMs: 10,
                          hits: 0, ok: true, query: "other")
        try g.insertUsage(ws: "ws1", tool: "search", latencyMs: 10,
                          hits: nil, ok: true, query: "nil-hits")
        let z = try g.zeroHitQueries()
        XCTAssertEqual(z.count, 1)
        XCTAssertEqual(z.first?.query, "flux capacitor")
        XCTAssertEqual(z.first?.count, 4)
    }

    func testQueryTruncatedAt200() throws {
        let (g, dir) = try tempLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "x", count: 500)
        try g.insertUsage(ws: "ws1", tool: "search", latencyMs: 1,
                          hits: 0, ok: true, query: long)
        let stored = try g.pool.read { db in
            try String.fetchOne(db, sql: "SELECT query FROM usage_events")
        }
        XCTAssertEqual(stored?.count, 200)
    }

    // MARK: - MCPServer.usageFields extraction

    func testUsageFieldsSearchCountsHits() throws {
        let body = #"{"hits":[{},{}],"meta":{}}"#
        let f = MCPServer.usageFields(
            tool: "search", args: ["query": .string("alpha")],
            body: body, threw: false)
        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.hits, 2)
        XCTAssertEqual(f.query, "alpha")
    }

    func testUsageFieldsZeroHitSearch() throws {
        let f = MCPServer.usageFields(
            tool: "search", args: ["query": .string("nothing")],
            body: #"{"hits":[],"meta":{}}"#, threw: false)
        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.hits, 0)
    }

    func testUsageFieldsFindDefinitionsSumsNested() throws {
        let body = #"{"results":[{"symbol":"a","definitions":[{},{}]},"#
            + #"{"symbol":"b","definitions":[]}]}"#
        let f = MCPServer.usageFields(
            tool: "find_definitions", args: [:], body: body, threw: false)
        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.hits, 2)
        XCTAssertNil(f.query)
    }

    func testUsageFieldsErrorEnvelopeNotOk() throws {
        // Tool returned a body but with an embedded error (e.g.
        // E_OUTPUT_TOO_LARGE or "record not found") — counts as not-ok.
        let f = MCPServer.usageFields(
            tool: "get_record", args: [:],
            body: #"{"error":"record not found","id":3}"#, threw: false)
        XCTAssertFalse(f.ok)
        XCTAssertNil(f.hits)
    }

    func testUsageFieldsThrownNotOk() throws {
        let f = MCPServer.usageFields(
            tool: "search", args: ["query": .string("q")],
            body: "", threw: true)
        XCTAssertFalse(f.ok)
        XCTAssertNil(f.hits)
    }

    func testUsageFieldsUnmappedToolNilHits() throws {
        let f = MCPServer.usageFields(
            tool: "prime", args: [:], body: #"{"card":"…"}"#, threw: false)
        XCTAssertTrue(f.ok)
        XCTAssertNil(f.hits)
    }
}
