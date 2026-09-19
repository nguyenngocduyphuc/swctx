import XCTest
@testable import SwctxCore
import GRDB

/// Regression tests for the OpenCodeReview audit findings
/// (bench/code_audit.md, 2026-09-19). Each test pins one fix:
/// corrupt-input crashes, deterministic SQL ranking, and per-store
/// embedder isolation.
final class AuditRegressionTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sidecar header writer matching Search.sidecarMagic layout:
    /// magic(8) | dim(u32le) | count(u64le) | sigLen(u16le) | sig | payload.
    private func sidecarData(dim: UInt32, count: UInt64, sig: String,
                             payloadBytes: Int = 0) -> Data {
        var d = Data("SWVCTRX1".utf8)
        withUnsafeBytes(of: dim.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: count.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(sig.utf8.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: sig.utf8)
        d.append(Data(count: payloadBytes))
        return d
    }

    // MARK: - F2: malformed vector sidecar must fail soft

    func testSidecarRejectsCountBeyondIntMax() throws {
        // count = 2^64-1: `Int(n)` would trap; Int(exactly:) fails soft.
        let url = try tempDir().appendingPathComponent("v.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try sidecarData(dim: 768, count: UInt64.max, sig: "sig")
            .write(to: url)
        XCTAssertNil(Search.readVectorSidecar(url: url, signature: "sig", dim: 768))
    }

    func testSidecarRejectsOverflowingCount() throws {
        // count small enough for Int but cnt*8+cnt*dim*4 overflows Int64 —
        // must return nil, not trap in the bounds arithmetic.
        let url = try tempDir().appendingPathComponent("v.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let huge = UInt64(Int64.max) / 8 + 1
        try sidecarData(dim: 768, count: huge, sig: "sig")
            .write(to: url)
        XCTAssertNil(Search.readVectorSidecar(url: url, signature: "sig", dim: 768))
    }

    func testSidecarRejectsTruncatedPayload() throws {
        let url = try tempDir().appendingPathComponent("v.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try sidecarData(dim: 4, count: 3, sig: "sig", payloadBytes: 10)
            .write(to: url)
        XCTAssertNil(Search.readVectorSidecar(url: url, signature: "sig", dim: 4))
    }

    func testSidecarRoundTripsValidData() throws {
        // A well-formed sidecar still parses — guard changes must not
        // reject the real cache path.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v.bin")
        let entry = Search.CachedVectors(
            signature: "sig", dim: 2, ids: [7, 9],
            matrix: [1.5, -2.0, 0.25, 4.0], lastUse: Date())
        try Search.writeVectorSidecar(url: url, entry: entry)
        let back = try XCTUnwrap(
            Search.readVectorSidecar(url: url, signature: "sig", dim: 2))
        XCTAssertEqual(back.ids, [7, 9])
        XCTAssertEqual(back.matrix, [1.5, -2.0, 0.25, 4.0])
    }

    // MARK: - Alignment: vector(from:) on an unaligned Data slice

    func testVectorFromUnalignedBlobDecodes() {
        // A Data slice sharing a parent buffer at a 2-byte offset is not
        // 4-byte aligned — bindMemory would trap; copyBytes decodes fine.
        let floats: [Float] = [3.5, -1.25]
        var raw = Data([0xAA, 0xBB])               // 2-byte pad
        floats.withUnsafeBufferPointer { raw.append(contentsOf: UnsafeRawBufferPointer($0)) }
        let slice = raw.subdata(in: 2..<raw.count) // unaligned view
        let v = Embedder.vector(from: slice, dim: 2)
        XCTAssertEqual(v, [3.5, -1.25])
    }

    // MARK: - F5: malformed SentencePiece model must throw, not trap

    func testSPTokenizerRejectsGiantFieldLength() {
        // field 1 (pieces), wire 2, length varint = ~2^70 > Int.max.
        // fieldData's old `Int(len)` trapped; now returns nil → throw.
        var bytes: [UInt8] = [0x0A]                 // tag(1,2)
        bytes += Array(repeating: 0xFF, count: 9)   // varint continuation
        bytes += [0x7F]                              // varint terminator
        XCTAssertThrowsError(try SPTokenizer(modelData: Data(bytes))) { e in
            guard case SPTokenizer.SPError.malformedModel = e else {
                return XCTFail("expected malformedModel, got \(e)")
            }
        }
    }

    // MARK: - F3: per-store embedder isolation

    func testStoreEmbedderPinsIndexModel() throws {
        // Two stores bound to different models must embed through their
        // OWN binding even when opened in one process — the old global
        // `Embedder.shared` followed the last-opened Store.
        let dirA = try tempDir()
        let dirB = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        Embedder.selectModel("bge-base-en-v1.5")
        defer { Embedder.selectModel(nil); Embedder.bindModel(nil) }
        let a = try Store(workspaceRoot: dirA)
        try a.setEmbeddingBinding(modelID: "bge-base-en-v1.5", dim: 768)
        let b = try Store(workspaceRoot: dirB)
        try b.setEmbeddingBinding(modelID: "bge-m3", dim: 1024)
        XCTAssertEqual(a.embedder.resolvedModelID, "bge-base-en-v1.5")
        XCTAssertEqual(b.embedder.resolvedModelID, "bge-m3")
        // Same binding -> same cached instance (no per-call model load).
        XCTAssertTrue(a.embedder === Embedder.instance(forModelID: "bge-base-en-v1.5"))
    }

    // MARK: - symbolHits: deterministic def-first ranking (GROUP BY + MIN)

    func testSymbolHitsRankDeterministicWithMultiMatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(workspaceRoot: dir)
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO files(id, path, lang, sha, size, mtime, indexed_at)
                VALUES(1, 'a.py', 'python', 'x', 1, 0, 0)
                """)
            // chunk 1 is the definition of `alpha`; chunk 2 merely mentions
            // it via another symbol row. Both join the query term.
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line, kind, symbol, content)
                VALUES(1, 1, 0, 1, 5, 'function', 'alpha', 'def alpha(): pass'),
                      (2, 1, 1, 6, 10, 'function', 'beta', 'def beta(): pass')
                """)
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line)
                VALUES(1, 1, 'alpha', 'function', 1),
                      (1, 2, 'alpha', 'reference', 6),
                      (1, 2, 'beta', 'function', 6)
                """)
        }
        let hits = try Search.symbolHits(store: store, query: "alpha", limit: 10)
        XCTAssertEqual(hits.map(\.chunkID).prefix(1), [1],
                       "def-chunk must rank first regardless of join order")
        XCTAssertEqual(hits.count, 2)
    }
}
