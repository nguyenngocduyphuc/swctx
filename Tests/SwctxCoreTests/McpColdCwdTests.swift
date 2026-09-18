import XCTest
import Foundation

/// P0 wire-level regression: a `tools/call` WITHOUT a `workspace` argument
/// from a cwd with no indexed ancestor used to hang the server forever —
/// `indexedAncestor` walked `/` -> `/..` -> `/../..` … because Foundation
/// reports `/..` as the parent of `/`, so the "parent == self" stop never
/// fired. Every pre-existing test ran inside an indexed tree, so only real
/// MCP clients spawned from unindexed directories hit the wedge.
///
/// This test spawns the actual debug `swctx mcp` executable with cwd=/tmp
/// (guaranteed unindexed) and speaks newline-delimited JSON-RPC over pipes —
/// the same wire path an agent CLI drives. Every read goes through poll()
/// with a ~15s deadline, so a regressed server fails an assertion instead
/// of hanging the test suite.
final class McpColdCwdTests: XCTestCase {

    /// Debug binary: `swift test` runs with the package root as cwd; the
    /// #filePath fallback keeps the lookup correct from any other cwd.
    private static func debugBinary() throws -> URL {
        let fromCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/swctx")
        let fromFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwctxCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
            .appendingPathComponent(".build/debug/swctx")
        for url in [fromCwd, fromFile] {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw XCTSkip("debug swctx binary not found — run `swift build` "
            + "(tried \(fromCwd.path), \(fromFile.path))")
    }

    /// Minimal newline-delimited JSON-RPC client over Foundation pipes —
    /// same wire shape as bench/bench.py's MCPSession. Reads are poll()-
    /// bounded so a wedged server yields nil, not a hang.
    private final class StdioRPC {
        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        private var buf = Data()
        /// 1-based id of the last request sent; also the id request() matched.
        private(set) var nextID = 0

        init(binary: URL, cwd: URL) throws {
            process.executableURL = binary
            process.arguments = ["mcp"]
            process.currentDirectoryURL = cwd
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func stop() {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        private func send(_ obj: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)  // NDJSON: one message per line
            try inPipe.fileHandleForWriting.write(contentsOf: data)
        }

        func notify(_ method: String) throws {
            try send(["jsonrpc": "2.0", "method": method])
        }

        /// Send a request; return the response carrying the matching `id`,
        /// or nil when the deadline passes with no response — the pre-fix
        /// wedge this test guards against. Non-JSON noise and messages with
        /// other ids are consumed and skipped.
        func request(_ method: String, _ params: [String: Any],
                     timeout: TimeInterval = 15) throws -> [String: Any]? {
            nextID += 1
            let rid = nextID
            try send(["jsonrpc": "2.0", "id": rid,
                      "method": method, "params": params])
            let deadline = Date().addingTimeInterval(timeout)
            let fd = outPipe.fileHandleForReading.fileDescriptor
            while true {
                while let line = takeLine() {
                    if let msg = try? JSONSerialization.jsonObject(with: line)
                        as? [String: Any],
                       (msg["id"] as? Int) == rid {
                        return msg
                    }
                }
                guard deadline.timeIntervalSinceNow > 0 else { return nil }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let waitMs = Int32(min(deadline.timeIntervalSinceNow, 1) * 1000)
                if poll(&pfd, 1, waitMs) > 0 {
                    // Readable (or hung-up): drain what is buffered now.
                    let chunk = outPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { return nil }  // EOF: server exited
                    buf.append(chunk)
                }
                // timeout slice or EINTR: loop until the deadline.
            }
        }

        private func takeLine() -> Data? {
            guard let nl = buf.firstIndex(of: 0x0A) else { return nil }
            defer { buf = Data(buf[buf.index(after: nl)...]) }
            return Data(buf[..<nl])
        }

        /// The tool payload travels as a JSON document inside
        /// result.content[].text — decode it back out.
        static func payload(_ resp: [String: Any]) -> [String: Any]? {
            let result = resp["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            let text = content?.compactMap { $0["text"] as? String }
                .joined(separator: "\n") ?? ""
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        }
    }

    /// Both calls below omit `workspace` and run against a server whose cwd
    /// is /tmp — pre-fix each produced NO response at all (the infinite
    /// ancestor walk). Worst-case runtime is one 15s deadline: a wedge fails
    /// the guard and skips the remaining calls, keeping the test <20s.
    func testToolCallsWithoutWorkspaceFromUnindexedCwd() throws {
        let rpc = try StdioRPC(binary: Self.debugBinary(),
                               cwd: URL(fileURLWithPath: "/tmp"))
        defer { rpc.stop() }

        // Same handshake a real MCP client performs.
        let initResp = try rpc.request("initialize", [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "swctx-cold-cwd-test", "version": "0.1"],
        ])
        XCTAssertNotNil(initResp?["result"],
                        "initialize got no result: \(String(describing: initResp))")
        try rpc.notify("notifications/initialized")

        // a) get_status {} — a result carrying indexed:false, not a hang,
        //    not an error.
        guard let statusResp = try rpc.request("tools/call",
            ["name": "get_status", "arguments": [String: Any]()]) else {
            XCTFail("get_status without workspace from unindexed cwd: no "
                + "response within 15s — ancestor-walk hang regressed")
            return
        }
        XCTAssertEqual(statusResp["id"] as? Int, rpc.nextID)
        XCTAssertNil(statusResp["error"], "get_status JSON-RPC error: \(statusResp)")
        let statusResult = statusResp["result"] as? [String: Any]
        XCTAssertFalse((statusResult?["isError"] as? Bool) ?? false,
                       "get_status returned isError: \(statusResp)")
        let status = try XCTUnwrap(StdioRPC.payload(statusResp),
                                   "get_status payload unparseable: \(statusResp)")
        let meta = status["meta"] as? [String: Any]
        XCTAssertEqual(meta?["indexed"] as? Bool, false,
                       "expected meta.indexed=false for /tmp: \(status)")

        // b) list_records scope=global — the global ledger needs no
        //    resolvable workspace, so a `records` array must come back even
        //    from an unindexed cwd.
        guard let recResp = try rpc.request("tools/call",
            ["name": "list_records",
             "arguments": ["scope": "global", "limit": 3]]) else {
            XCTFail("list_records scope=global from unindexed cwd: no "
                + "response within 15s — ancestor-walk hang regressed")
            return
        }
        XCTAssertEqual(recResp["id"] as? Int, rpc.nextID)
        XCTAssertNil(recResp["error"], "list_records JSON-RPC error: \(recResp)")
        let recResult = recResp["result"] as? [String: Any]
        XCTAssertFalse((recResult?["isError"] as? Bool) ?? false,
                       "list_records returned isError: \(recResp)")
        let recs = try XCTUnwrap(StdioRPC.payload(recResp),
                                 "list_records payload unparseable: \(recResp)")
        XCTAssertNotNil(recs["records"] as? [Any],
                        "list_records payload has no records array: \(recs)")
    }
}
