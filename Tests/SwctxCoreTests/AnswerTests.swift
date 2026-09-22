import XCTest
@testable import SwctxCore
import GRDB

/// W12 `swctx answer`: evidence pack → local Ollama → cited JSON +
/// server-side citation validation + durable `kind=ask` record.
/// Ollama itself is never required here — a fake `ollama` shell script
/// (subcommands handled: list/run) stands in via the `ollamaBin:` seam,
/// which is also how the "Ollama absent" path is exercised.
final class AnswerTests: SwctxTestCase {

    /// Temp workspace with a couple of indexed files.
    private func makeWorkspace() throws -> (URL, Store) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-answer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        /// Summarize a record row into display text.
        func tom_tat(_ row: String) -> String {
            return row.uppercased()
        }
        """.write(to: dir.appendingPathComponent("tomtat.swift"),
                  atomically: true, encoding: .utf8)
        try "def helper():\n    return summarize('x')\n".write(
            to: dir.appendingPathComponent("helper.py"),
            atomically: true, encoding: .utf8)
        let store = try Store(workspaceRoot: dir)
        _ = try Indexer(store: store).run(force: true)
        return (dir, store)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A fake `ollama` executable: `list` advertises qwen2.5:3b; `run`
    /// bumps a count file, captures the prompt (last argv element) into
    /// `prompt_<n>.txt`, then prints `reply_<n>.txt` for the n-th call
    /// (per-attempt scripting) falling back to `reply.txt`.
    @discardableResult
    private func fakeOllama(dir: URL) throws -> String {
        let script = """
        #!/bin/sh
        case "$1" in
          list)
            echo "NAME            ID    SIZE    MODIFIED"
            echo "qwen2.5:3b      aaa   1.9GB   now"
            exit 0
            ;;
          run)
            n=$(( $(cat "\(dir.path)/count" 2>/dev/null || echo 0) + 1 ))
            echo $n > "\(dir.path)/count"
            for last in "$@"; do :; done
            printf '%s' "$last" > "\(dir.path)/prompt_${n}.txt"
            if [ -f "\(dir.path)/reply_${n}.txt" ]; then
              cat "\(dir.path)/reply_${n}.txt"
            else
              cat "\(dir.path)/reply.txt"
            fi
            exit 0
            ;;
        esac
        exit 1
        """
        let bin = dir.appendingPathComponent("fake-ollama.sh")
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return bin.path
    }

    private let goodJSON = """
        {"answer": "tom_tat uppercases a row for display.",
         "citations": [{"evidence_id": "E01"}],
         "limitations": ""}
        """

    private func writeReply(_ text: String, to dir: URL, name: String = "reply.txt") throws {
        try text.write(to: dir.appendingPathComponent(name),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - citation validator (pure)

    private func samplePack() -> [Answer.Evidence] {
        [
            Answer.Evidence(id: "E01", chunkID: 10, path: "a.swift",
                            startLine: 1, endLine: 4, why: "direct",
                            symbol: "tom_tat", kind: "function",
                            content: "func tom_tat…"),
            Answer.Evidence(id: "E02", chunkID: 22, path: "b.py",
                            startLine: 10, endLine: 20, why: "calls",
                            symbol: nil, kind: nil, content: "…"),
        ]
    }

    func testCitationValidatorAcceptsValid() {
        let v = Answer.validateCitations(
            [["evidence_id": "E01"], ["evidence_id": "e2"]],
            pack: samplePack())
        XCTAssertTrue(v.valid)
        XCTAssertEqual(v.resolved.count, 2)
        XCTAssertEqual(v.resolved[0]["path"] as? String, "a.swift")
        XCTAssertEqual(v.resolved[1]["evidence_id"] as? String, "E02")
        XCTAssertTrue(v.invalid.isEmpty)
    }

    func testCitationValidatorRejectsOutOfPack() {
        let v = Answer.validateCitations([["evidence_id": "E99"]],
                                         pack: samplePack())
        XCTAssertFalse(v.valid)
        XCTAssertTrue(v.resolved.isEmpty)
        XCTAssertEqual(v.invalid.count, 1)
    }

    /// A model-invented path on a real evidence_id is still invalid —
    /// citations must match the pack's path/lines verbatim.
    func testCitationValidatorRejectsInventedPathAndLine() {
        let v = Answer.validateCitations(
            [["evidence_id": "E01", "path": "/etc/passwd"],
             ["evidence_id": "E01", "path": "a.swift", "start_line": 1,
              "end_line": 4],
             ["evidence_id": "E02", "start_line": 999]],
            pack: samplePack())
        XCTAssertFalse(v.valid)
        XCTAssertEqual(v.resolved.count, 1)
        XCTAssertEqual(v.resolved[0]["evidence_id"] as? String, "E01")
        XCTAssertEqual(v.invalid.count, 2)
    }

    func testCitationValidatorEmptyIsInvalid() {
        let v = Answer.validateCitations([], pack: samplePack())
        XCTAssertFalse(v.valid)
    }

    /// A field that IS present must carry the right JSON type — wrong
    /// types are malformed assertions (invalid), never silently skipped:
    /// start_line "99" (string), path {} (object), end_line true (bool),
    /// start_line 10.5 (fractional). Backward compat: an absent field
    /// stays fine (id-only citation resolves), an explicit JSON null
    /// reads as "not provided", and an integral double (10.0) coerces.
    func testCitationValidatorRejectsWrongTypes() {
        let v = Answer.validateCitations(
            [["evidence_id": "E01", "start_line": "99"],
             ["evidence_id": "E01", "path": ["x": 1]],
             ["evidence_id": "E01", "end_line": true],
             ["evidence_id": "E02", "start_line": 10.5],
             ["evidence_id": "E01", "path": NSNull()],
             ["evidence_id": "E02", "start_line": 10.0]],
            pack: samplePack())
        XCTAssertFalse(v.valid)
        XCTAssertEqual(v.resolved.count, 2)
        XCTAssertEqual(v.resolved[0]["evidence_id"] as? String, "E01")
        XCTAssertEqual(v.resolved[1]["evidence_id"] as? String, "E02")
        XCTAssertEqual(v.invalid.count, 4)
        XCTAssertTrue(v.invalid.contains { $0.contains("not a number") })
        XCTAssertTrue(v.invalid.contains { $0.contains("not a string") })
    }

    // MARK: - prompt builder

    func testBuildPromptRendersHandlesAndNeverOracle() {
        let prompt = Answer.buildPrompt(
            query: "what does tom_tat do", evidence: samplePack(),
            retry: false)
        XCTAssertTrue(prompt.contains("[E01] path=a.swift start_line=1 end_line=4"))
        XCTAssertTrue(prompt.contains("what does tom_tat do"))
        XCTAssertTrue(prompt.contains("\"answer\""))
        XCTAssertTrue(prompt.contains("\"citations\""))
        XCTAssertTrue(prompt.contains("\"limitations\""))
        // expected_path is not even a parameter of the prompt builder —
        // the oracle can only leak via a regression that adds it.
        XCTAssertFalse(prompt.contains("expected_path"))
        XCTAssertFalse(prompt.contains("oracle"))
    }

    // MARK: - run() seams

    /// Ollama binary absent → deterministic pack + structured limitation,
    /// no throw; the run is still persisted as a kind=ask record.
    func testOllamaAbsentReturnsDeterministicPack() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b",
            ollamaBin: "/nonexistent/swctx-answer-test-ollama",
            timeout: 15, source: "test")
        let ollama = resp["ollama"] as? [String: Any]
        XCTAssertEqual(ollama?["available"] as? Bool, false)
        XCTAssertEqual(ollama?["attempts"] as? Int, 0)
        XCTAssertTrue(resp["answer"] is NSNull)
        // Deterministic fallback: the evidence pack is still returned.
        let evidence = resp["evidence"] as? [[String: Any]] ?? []
        XCTAssertFalse(evidence.isEmpty)
        XCTAssertEqual(evidence.first?["evidence_id"] as? String, "E01")
        XCTAssertFalse((resp["limitations"] as? String ?? "").isEmpty)
        XCTAssertTrue((resp["limitations"] as? String ?? "")
            .contains("ollama unavailable"))
        XCTAssertNotNil(resp["record_id"])
    }

    /// Happy path through a fake ollama: strict JSON in → parsed answer,
    /// resolved citations, citation_valid, durable ask record.
    func testRecordWrittenOnSuccess() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply(goodJSON, to: dir)
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin,
            timeout: 15, source: "test")
        XCTAssertEqual(resp["answer"] as? String,
                       "tom_tat uppercases a row for display.")
        XCTAssertEqual(resp["citation_valid"] as? Bool, true)
        let citations = resp["citations"] as? [[String: Any]] ?? []
        XCTAssertEqual(citations.first?["path"] as? String, "tomtat.swift")
        let ollama = resp["ollama"] as? [String: Any]
        XCTAssertEqual(ollama?["available"] as? Bool, true)
        XCTAssertEqual(ollama?["attempts"] as? Int, 1)

        // Durable record: kind=ask, full eval fields in payload.
        let recordID = try XCTUnwrap(resp["record_id"] as? Int64)
        let row = try store.pool.read { db in
            try Row.fetchOne(db, sql:
                "SELECT kind, source, status, title, payload FROM records WHERE id = ?",
                arguments: [recordID])
        }
        XCTAssertEqual(row?["kind"] as? String, "ask")
        XCTAssertEqual(row?["source"] as? String, "test")
        XCTAssertEqual(row?["status"] as? String, "completed")
        let payload = try JSONSerialization.jsonObject(
            with: Data((row?["payload"] as? String ?? "").utf8))
            as? [String: Any]
        XCTAssertEqual(payload?["model"] as? String, "qwen2.5:3b")
        XCTAssertEqual(payload?["prompt_version"] as? String,
                       Answer.promptVersion)
        XCTAssertEqual(payload?["citation_valid"] as? Bool, true)
        XCTAssertNotNil(payload?["latency_ms"])
        XCTAssertNotNil(payload?["evidence"])
        XCTAssertNotNil(payload?["limitations"])
    }

    /// Malformed first reply → exactly one format-retry, then the
    /// corrected second reply is used.
    func testMalformedOutputRetriesOnce() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("Sorry, I cannot help with that. Definitely not JSON.",
                       to: dir, name: "reply_1.txt")
        try writeReply(goodJSON, to: dir, name: "reply_2.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin,
            timeout: 15, source: "test")
        let ollama = resp["ollama"] as? [String: Any]
        XCTAssertEqual(ollama?["attempts"] as? Int, 2)
        XCTAssertEqual(resp["answer"] as? String,
                       "tom_tat uppercases a row for display.")
        XCTAssertEqual(resp["citation_valid"] as? Bool, true)
    }

    /// Malformed twice → one retry is all you get; the caller gets the
    /// deterministic pack + limitation, not an exception.
    func testMalformedTwiceDegradesToPack() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("totally not json {{", to: dir)
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin,
            timeout: 15, source: "test")
        let ollama = resp["ollama"] as? [String: Any]
        XCTAssertEqual(ollama?["attempts"] as? Int, 2)
        XCTAssertTrue(resp["answer"] is NSNull)
        XCTAssertTrue((resp["limitations"] as? String ?? "")
            .contains("format-retry"))
        XCTAssertFalse((resp["evidence"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertNotNil(resp["raw_output"])
        XCTAssertNotNil(resp["record_id"])
    }

    /// Invalid citation from the model → answer kept, citation_valid false,
    /// limitation flags the rejection.
    func testInvalidCitationFlagsAnswer() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"answer": "x",
             "citations": [{"evidence_id": "E77"}],
             "limitations": ""}
            """, to: dir)
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin,
            timeout: 15, source: "test")
        XCTAssertEqual(resp["answer"] as? String, "x")
        XCTAssertEqual(resp["citation_valid"] as? Bool, false)
        XCTAssertTrue((resp["limitations"] as? String ?? "")
            .contains("rejected"))
        XCTAssertFalse((resp["invalid_citations"] as? [String] ?? []).isEmpty)
    }

    /// Invalid citations spend the same single retry a malformed reply
    /// gets: bad citation on attempt 1, clean JSON on attempt 2 →
    /// resolved and citation_valid.
    func testInvalidCitationRetriesOnce() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"answer": "first try",
             "citations": [{"evidence_id": "E77"}],
             "limitations": ""}
            """, to: dir, name: "reply_1.txt")
        try writeReply(goodJSON, to: dir, name: "reply_2.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin,
            timeout: 15, source: "test")
        let ollama = resp["ollama"] as? [String: Any]
        XCTAssertEqual(ollama?["attempts"] as? Int, 2)
        XCTAssertEqual(resp["answer"] as? String,
                       "tom_tat uppercases a row for display.")
        XCTAssertEqual(resp["citation_valid"] as? Bool, true)
        XCTAssertTrue((resp["invalid_citations"] as? [String] ?? []).isEmpty)
    }

    /// Still invalid after the retry → the answer is returned anyway
    /// (existing contract) but flagged on every surface:
    /// citation_valid=false, invalid_citations lists the rejection,
    /// limitations spell out the retry was exhausted, and the durable
    /// record carries the same fields.
    func testInvalidCitationRetryExhaustedKeepsAnswer() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"answer": "x",
             "citations": [{"evidence_id": "E01", "start_line": "oops"}],
             "limitations": ""}
            """, to: dir)
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin,
            timeout: 15, source: "test")
        let ollama = resp["ollama"] as? [String: Any]
        XCTAssertEqual(ollama?["attempts"] as? Int, 2)
        XCTAssertEqual(resp["answer"] as? String, "x")
        XCTAssertEqual(resp["citation_valid"] as? Bool, false)
        let lim = resp["limitations"] as? String ?? ""
        XCTAssertTrue(lim.contains("rejected"))
        XCTAssertTrue(lim.contains("still invalid after 1 retry"))
        XCTAssertFalse((resp["invalid_citations"] as? [String] ?? []).isEmpty)
        // The durable record marks it too.
        let recordID = try XCTUnwrap(resp["record_id"] as? Int64)
        let payloadStr = try store.pool.read { db in
            try String.fetchOne(db, sql:
                "SELECT payload FROM records WHERE id = ?",
                arguments: [recordID])
        }
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data((payloadStr ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(payload["citation_valid"] as? Bool, false)
        XCTAssertFalse((payload["invalid_citations"] as? [String] ?? [])
            .isEmpty)
        XCTAssertEqual(payload["attempts"] as? Int, 2)
    }

    /// The harness oracle `expected_path` must never reach the model:
    /// the fake ollama captures the exact argv prompt and the oracle
    /// marker must be absent from it (while still recorded in the
    /// response for scoring).
    func testExpectedPathNeverReachesPrompt() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply(goodJSON, to: dir)
        Answer.resetPreflightCache()
        let oracle = "secret_oracle_marker/zzz.swift"
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin,
            timeout: 15, expectedPath: oracle, source: "test")
        // Oracle is echoed into the response for the harness…
        XCTAssertEqual(resp["expected_path"] as? String, oracle)
        // …but absent from every prompt actually sent (retry included).
        for n in 1...2 {
            let f = dir.appendingPathComponent("prompt_\(n).txt")
            guard FileManager.default.fileExists(atPath: f.path),
                  let sent = try? String(contentsOf: f, encoding: .utf8)
            else { continue }
            XCTAssertFalse(sent.contains(oracle),
                           "oracle leaked into prompt attempt \(n)")
            XCTAssertFalse(sent.contains("expected_path"))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("prompt_1.txt").path))
    }
}
