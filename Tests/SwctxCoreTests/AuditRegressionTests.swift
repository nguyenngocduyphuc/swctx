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

    func testVectorFromUnalignedBlobDecodes() throws {
        // Guaranteed-misaligned storage: bytesNoCopy over a malloc'd
        // pointer +1 — `bindMemory` on this address would trap outright.
        let floats: [Float] = [3.5, -1.25]
        let n = floats.count * 4
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n + 1, alignment: 16)
        defer { buf.deallocate() }
        floats.withUnsafeBufferPointer { f in
            buf.advanced(by: 1).copyMemory(
                from: UnsafeRawPointer(f.baseAddress!), byteCount: n)
        }
        let slice = Data(bytesNoCopy: buf.advanced(by: 1), count: n,
                         deallocator: .none)
        let v = try XCTUnwrap(Embedder.vector(from: slice, dim: 2))
        XCTAssertEqual(v, floats)
    }

    func testVectorRejectsWrongSizeBlob() {
        // A blob whose byte count is not dim*4 is corrupt — reject,
        // never zero-pad a short read into a plausible-looking vector.
        let floats: [Float] = [1.0, 2.0, 3.0]
        let full = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertNil(Embedder.vector(from: full.dropLast(2), dim: 3))
        XCTAssertNil(Embedder.vector(from: full, dim: 4))
        XCTAssertNil(Embedder.vector(from: Data(), dim: 0))
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

    func testSPTokenizerRejectsGiantTag() {
        // A tag varint encoding field >> Int.max: `Int(t >> 3)` trapped;
        // now tag() returns nil → parse ends → malformedModel thrown.
        var bytes: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x7F]
        bytes += [0x0A, 0x01, 0x61]   // a valid (pieces,len=1,"a") after
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
            // chunk 1 is the definition of `alpha`; chunk 2 joins the term
            // through MULTIPLE symbol rows — the shape the old DISTINCT +
            // ORDER BY s.name ranked non-deterministically.
            try db.execute(sql: """
                INSERT INTO chunks(id, file_id, idx, start_line, end_line, kind, symbol, content)
                VALUES(1, 1, 0, 1, 5, 'function', 'alpha', 'def alpha(): pass'),
                      (2, 1, 1, 6, 10, 'function', 'beta', 'def beta(): pass'),
                      (3, 1, 2, 11, 15, 'function', 'gamma', 'def gamma(): pass')
                """)
            try db.execute(sql: """
                INSERT INTO symbols(file_id, chunk_id, name, kind, line)
                VALUES(1, 1, 'alpha', 'function', 1),
                      (1, 2, 'alpha', 'reference', 6),
                      (1, 2, 'alpha', 'call', 8),
                      (1, 2, 'beta', 'function', 6),
                      (1, 3, 'alpha', 'reference', 12)
                """)
        }
        let hits = try Search.symbolHits(store: store, query: "alpha", limit: 10)
        // def-chunk first; remaining chunks in stable c.id order — the
        // full ordering is pinned, not just the winner.
        XCTAssertEqual(hits.map(\.chunkID), [1, 2, 3],
                       "def-first + deterministic tiebreak by chunk id")
        // Run twice: any residual join-order nondeterminism would flip it.
        XCTAssertEqual(try Search.symbolHits(store: store, query: "alpha", limit: 10)
                        .map(\.chunkID), [1, 2, 3])
        // Multi-term: chunk 2 joins 'alpha' rows (non-def, rank 1) AND its
        // own 'beta' def row (rank 0) — MIN must pick 0 across mixed rows
        // on ONE chunk, promoting it to def-rank.
        let multi = try Search.symbolHits(store: store, query: "alpha beta",
                                          limit: 10).map(\.chunkID)
        XCTAssertEqual(multi, [1, 2, 3],
                       "MIN across mixed def/non-def rows promotes the def row")
    }
}
