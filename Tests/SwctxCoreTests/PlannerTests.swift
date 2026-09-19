import XCTest
@testable import SwctxCore
import GRDB

/// `answer --plan` bounded planner loop: the model iterates retrieval
/// (STRICT JSON {"action":"search","queries":[≤3]} | {"action":"answer"})
/// before synthesis — the rescue path for retrieval misses.
/// Same seam as AnswerTests: a fake `ollama` shell script (list/run)
/// replies per-call from reply_<n>.txt — planner rounds consume
/// reply_1..k, the synthesis attempt consumes the next reply.
final class PlannerTests: XCTestCase {

    /// Workspace: tomtat.swift (initial-query target) + six files each
    /// carrying a unique token the planner can find deterministically.
    /// Indexed WITHOUT auto-embed so the semantic leg is empty — a
    /// gibberish query then provably returns zero hits (needed for the
    /// zero-growth early-stop test). All test queries stay pure ASCII:
    /// a diacritic would fire the W11 translation leg, which spawns its
    /// own Ollama subprocess off the SWCTX_OLLAMA env seam.
    private func makeWorkspace() throws -> (URL, Store) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-planner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("tomtat.swift", """
            /// Summarize a record row into display text.
            func tom_tat(_ row: String) -> String {
                return row.uppercased()
            }
            """),
            ("quazar.swift", "func quazar() -> Int { return 1 }\n"),
            ("brixel.py", "def brixel():\n    return 2\n"),
            ("corvax.py", "def corvax():\n    return 3\n"),
            ("delmor.py", "def delmor():\n    return 4\n"),
            ("ephor.py", "def ephor():\n    return 5\n"),
            ("zynth.py", "def zynth():\n    return 6\n"),
            ("sub/kiem_tra.py", "def kiem_tra():\n    return 7\n"),
            ("sub/other.py", "def other_fn():\n    return 8\n"),
        ]
        for (name, body) in files {
            let f = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: f.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try body.write(to: f, atomically: true, encoding: .utf8)
        }
        let store = try Store(workspaceRoot: dir)
        _ = try Indexer(store: store).run(force: true, autoEmbed: false)
        return (dir, store)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Fake `ollama`: `list` advertises qwen2.5:3b; `run` bumps a count
    /// file, captures the prompt (last argv element) into prompt_<n>.txt,
    /// then prints reply_<n>.txt (falling back to reply.txt). A reply
    /// whose first line is `SLEEP=<secs>` sleeps first — the deadline
    /// test uses it to burn the planner's wall budget mid-call.
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
            src="\(dir.path)/reply_${n}.txt"
            [ -f "$src" ] || src="\(dir.path)/reply.txt"
            first=$(head -n 1 "$src")
            case "$first" in
              SLEEP=*)
                sleep "${first#SLEEP=}"
                tail -n +2 "$src"
                ;;
              *)
                cat "$src"
                ;;
            esac
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

    private func writeReply(_ text: String, to dir: URL,
                            name: String = "reply.txt") throws {
        try text.write(to: dir.appendingPathComponent(name),
                       atomically: true, encoding: .utf8)
    }

    private func plannerDict(_ resp: [String: Any],
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(resp["planner"] as? [String: Any],
                      "response carries a planner trace", file: file,
                      line: line)
    }

    // MARK: - parsePlannerAction (pure)

    /// Malformed planner output → {"action":"answer"}; the loop must
    /// never crash on model noise.
    func testParsePlannerMalformedFallsToAnswer() {
        for raw in [
            "",
            "Let me think about this question first…",
            "{not json",
            "{\"action\":\"explode\"}",
            "[\"search\"]",
        ] {
            let r = Answer.parsePlannerAction(raw)
            XCTAssertEqual(r.action, .answer, "raw: \(raw)")
            XCTAssertTrue(r.malformed, "raw: \(raw)")
        }
        let ok = Answer.parsePlannerAction("{\"action\":\"answer\"}")
        XCTAssertEqual(ok.action, .answer)
        XCTAssertFalse(ok.malformed)
    }

    /// Query-explosion guard: >3 queries per round are rejected to 3.
    func testParsePlannerCapsQueriesAtThree() {
        let r = Answer.parsePlannerAction(
            "{\"action\":\"search\",\"queries\":[\"a\",\"b\",\"c\",\"d\",\"e\"]}")
        XCTAssertEqual(r.action, .search(["a", "b", "c"]))
        XCTAssertFalse(r.malformed)
    }

    /// Schema-valid but useless outputs still resolve safely.
    func testParsePlannerEdgeCases() {
        // search with no usable queries → answer (planner gave up)
        XCTAssertEqual(Answer.parsePlannerAction(
            "{\"action\":\"search\",\"queries\":[]}").action, .answer)
        // single-string query tolerated
        XCTAssertEqual(Answer.parsePlannerAction(
            "{\"action\":\"search\",\"query\":\"abc\"}").action,
            .search(["abc"]))
        // fenced JSON tolerated
        XCTAssertEqual(Answer.parsePlannerAction(
            "```json\n{\"action\":\"search\",\"queries\":[\"qq\"]}\n```")
            .action, .search(["qq"]))
    }

    func testNormalizePlannerQuery() {
        XCTAssertEqual(Answer.normalizePlannerQuery("  Quazar   Search "),
                       "quazar search")
        XCTAssertEqual(Answer.normalizePlannerQuery("quazar"), "quazar")
    }

    /// Planner prompt: handles only (never content), tried queries
    /// listed, harness oracle structurally absent (not a parameter).
    func testPlannerPromptHandlesOnlyNoContent() {
        let pack = [
            Answer.Evidence(id: "E01", chunkID: 10, path: "a.swift",
                            startLine: 1, endLine: 4, why: "direct",
                            symbol: "tom_tat", kind: "function",
                            content: "func tom_tat SECRET_CONTENT"),
        ]
        let prompt = Answer.buildPlannerPrompt(
            query: "what does tom_tat do", pack: pack,
            triedQueries: ["old search"],
            nearby: ["09-build/dong_vong.py", "09-build/ghi_so.py"],
            round: 2, maxRounds: 4)
        XCTAssertTrue(prompt.contains(
            "[E01] path=a.swift start_line=1 end_line=4"))
        XCTAssertFalse(prompt.contains("SECRET_CONTENT"))
        XCTAssertTrue(prompt.contains("\"old search\""))
        XCTAssertTrue(prompt.contains("Round 2 of 4"))
        XCTAssertTrue(prompt.contains("09-build/dong_vong.py"))
        XCTAssertFalse(prompt.contains("expected_path"))
    }

    /// Naming hints: siblings of pack dirs, excluding pack members;
    /// an empty pack falls back to the index's top-level layout.
    func testSiblingHints() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let e = Answer.Evidence(id: "E01", chunkID: 1, path: "sub/kiem_tra.py",
                                startLine: 1, endLine: 1, why: "direct",
                                symbol: nil, kind: nil, content: "")
        let hints = Answer.siblingHints(store: store, pack: [e],
                                        query: "kiem tra function")
        XCTAssertTrue(hints.contains("sub/other.py"))
        XCTAssertFalse(hints.contains("sub/kiem_tra.py"))
        // Empty pack → top-level layout sample (files at root qualify).
        let top = Answer.siblingHints(store: store, pack: [],
                                      query: "kiem tra")
        XCTAssertFalse(top.isEmpty)
    }

    /// Auto-variants: adjacent bigrams of the question, tail first —
    /// "…để đóng vòng" must offer "đóng vòng" first (that's the filename
    /// stem in this corpus).
    func testPlannerAutoVariantsTailFirst() {
        let v = Answer.plannerAutoVariants(
            "script đối soát quyết định của CEO với trạng thái việc thật để đóng vòng",
            limit: 3)
        XCTAssertEqual(v.first, "đóng vòng")
        XCTAssertEqual(v.count, 3)
    }

    // MARK: - loop integration (fake ollama)

    /// Malformed planner JSON → treated as {"action":"answer"} → the
    /// synthesis path still produces a real answer.
    func testPlannerMalformedJSONFallsToAnswer() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("I would search for things, but I refuse JSON.",
                       to: dir, name: "reply_1.txt")
        try writeReply(goodJSON, to: dir, name: "reply_2.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true)
        XCTAssertEqual(resp["answer"] as? String,
                       "tom_tat uppercases a row for display.")
        let planner = try plannerDict(resp)
        XCTAssertEqual(planner["stopped"] as? String, "answer")
        XCTAssertEqual(planner["rounds"] as? Int, 1)
        XCTAssertEqual(planner["malformed"] as? Int, 1)
    }

    /// Integration-side of the explosion guard: a 5-query reply runs
    /// only the first 3 searches.
    func testPlannerRunsAtMostThreeQueries() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"action":"search","queries":["quazar","brixel","corvax","delmor","ephor"]}
            """, to: dir, name: "reply_1.txt")
        try writeReply("{\"action\":\"answer\"}", to: dir, name: "reply_2.txt")
        try writeReply(goodJSON, to: dir, name: "reply_3.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true)
        let planner = try plannerDict(resp)
        // Auto-variants lead every round; "tom tat" is the only
        // stopword-free bigram in "what does tom_tat do".
        XCTAssertEqual(planner["queries_tried"] as? [String],
                       ["tom tat", "quazar", "brixel", "corvax"])
        XCTAssertEqual(planner["evidence_growth"] as? [Int], [3, 0])
    }

    /// Repeated queries dedupe on the normalized form — within a round
    /// AND across rounds.
    func testPlannerDedupesRepeatedQueries() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"action":"search","queries":["quazar"," Quazar ","brixel"]}
            """, to: dir, name: "reply_1.txt")
        try writeReply("""
            {"action":"search","queries":["quazar","corvax"]}
            """, to: dir, name: "reply_2.txt")
        try writeReply("{\"action\":\"answer\"}", to: dir, name: "reply_3.txt")
        try writeReply(goodJSON, to: dir, name: "reply_4.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true)
        let planner = try plannerDict(resp)
        // " Quazar " (round 1) and "quazar" (round 2) dedupe away;
        // "tom tat" is the sole surviving auto-variant.
        XCTAssertEqual(planner["queries_tried"] as? [String],
                       ["tom tat", "quazar", "brixel", "corvax"])
        XCTAssertEqual(planner["rounds"] as? Int, 3)
        XCTAssertEqual(planner["evidence_growth"] as? [Int], [2, 1, 0])
    }

    /// The loop honors the ≤4-round cap even when every round finds new
    /// evidence — then falls into synthesis regardless.
    func testPlannerRoundCapHonored() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        for (i, q) in ["quazar", "brixel", "corvax", "delmor"].enumerated() {
            try writeReply("{\"action\":\"search\",\"queries\":[\"\(q)\"]}",
                           to: dir, name: "reply_\(i + 1).txt")
        }
        try writeReply(goodJSON, to: dir, name: "reply_5.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true)
        let planner = try plannerDict(resp)
        XCTAssertEqual(planner["rounds"] as? Int, 4)
        XCTAssertEqual(planner["stopped"] as? String, "round_cap")
        XCTAssertEqual(planner["evidence_growth"] as? [Int],
                       [1, 1, 1, 1])
        XCTAssertEqual(resp["answer"] as? String,
                       "tom_tat uppercases a row for display.")
    }

    /// Two consecutive rounds yielding zero NEW evidence stop the loop
    /// early — no point burning the remaining rounds.
    func testPlannerZeroNewEvidenceEarlyStop() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"action":"search","queries":["zxqvjkwm blorfnotfound"]}
            """, to: dir, name: "reply_1.txt")
        try writeReply("""
            {"action":"search","queries":["qqqzzz nevermatch"]}
            """, to: dir, name: "reply_2.txt")
        try writeReply(goodJSON, to: dir, name: "reply_3.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true)
        let planner = try plannerDict(resp)
        XCTAssertEqual(planner["stopped"] as? String, "no_new_evidence")
        XCTAssertEqual(planner["rounds"] as? Int, 2)
        XCTAssertEqual(planner["evidence_growth"] as? [Int], [0, 0])
    }

    /// Deadline abort: the wall clock expires mid-loop → synthesis still
    /// runs over whatever evidence exists.
    func testPlannerDeadlineAbortStillAnswers() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        // Round-1 planner call sleeps ~4s of the 6s planner budget,
        // returns one search, and the loop-top deadline check ends the
        // loop before round 2 can spawn.
        try writeReply("""
            SLEEP=4
            {"action":"search","queries":["quazar"]}
            """, to: dir, name: "reply_1.txt")
        try writeReply(goodJSON, to: dir, name: "reply_2.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true, planTimeout: 6)
        let planner = try plannerDict(resp)
        XCTAssertEqual(planner["stopped"] as? String, "deadline")
        XCTAssertEqual(resp["answer"] as? String,
                       "tom_tat uppercases a row for display.")
    }

    /// The deadline guard itself, deterministic: a loop whose deadline
    /// already passed stops with "deadline" and zero executed rounds.
    func testPlanLoopExpiredDeadlineStopsImmediately() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let acc = Answer.PackBuilder(
            tokenBudget: Answer.defaultEvidenceTokens, maxItems: 12)
        let rep = Answer.planLoop(
            store: store, acc: acc, query: "what does tom_tat do",
            bin: "/nonexistent/ollama", model: "qwen2.5:3b",
            deadline: Date().addingTimeInterval(-1), pathFilter: nil)
        XCTAssertEqual(rep.stopped, "deadline")
        XCTAssertEqual(rep.rounds, 0)
        XCTAssertTrue(rep.queriesTried.isEmpty)
        XCTAssertTrue(rep.evidenceGrowth.isEmpty)
    }

    /// Planner-added evidence is a first-class pack citizen: the
    /// synthesis reply cites E02 — the item the planner round appended —
    /// and the validator resolves it to quazar.swift.
    func testPlannerGrownEvidenceIsCitable() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"action":"search","queries":["quazar"]}
            """, to: dir, name: "reply_1.txt")
        try writeReply("{\"action\":\"answer\"}", to: dir, name: "reply_2.txt")
        try writeReply("""
            {"answer": "quazar returns 1.",
             "citations": [{"evidence_id": "E02"}],
             "limitations": ""}
            """, to: dir, name: "reply_3.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true)
        let paths = (resp["evidence"] as? [[String: Any]] ?? [])
            .compactMap { $0["path"] as? String }
        XCTAssertTrue(paths.contains("tomtat.swift"))
        XCTAssertTrue(paths.contains("quazar.swift"))
        XCTAssertEqual(resp["citation_valid"] as? Bool, true)
        let citations = resp["citations"] as? [[String: Any]] ?? []
        XCTAssertEqual(citations.first?["path"] as? String, "quazar.swift")
        XCTAssertEqual(resp["answer"] as? String, "quazar returns 1.")
    }

    /// The durable kind=ask record carries the planner fields:
    /// planner_rounds / queries_tried / evidence_growth / planner_stopped.
    func testRecordContainsPlannerFields() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply("""
            {"action":"search","queries":["quazar","brixel"]}
            """, to: dir, name: "reply_1.txt")
        try writeReply("{\"action\":\"answer\"}", to: dir, name: "reply_2.txt")
        try writeReply(goodJSON, to: dir, name: "reply_3.txt")
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test", plan: true)
        let recordID = try XCTUnwrap(resp["record_id"] as? Int64)
        let payloadStr = try store.pool.read { db in
            try String.fetchOne(db, sql:
                "SELECT payload FROM records WHERE id = ?",
                arguments: [recordID])
        }
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data((payloadStr ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(payload["planner_rounds"] as? Int, 2)
        XCTAssertEqual(payload["queries_tried"] as? [String],
                       ["tom tat", "quazar", "brixel"])
        XCTAssertEqual(payload["evidence_growth"] as? [Int], [2, 0])
        XCTAssertEqual(payload["planner_stopped"] as? String, "answer")
    }

    /// Default off: without `plan` the response has no planner trace and
    /// the record carries no planner fields — single-shot behavior
    /// unchanged.
    func testPlanOffByDefaultSingleShot() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let bin = try fakeOllama(dir: dir)
        try writeReply(goodJSON, to: dir)
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b", ollamaBin: bin, timeout: 15,
            source: "test")
        XCTAssertNil(resp["planner"])
        XCTAssertEqual(resp["answer"] as? String,
                       "tom_tat uppercases a row for display.")
        let recordID = try XCTUnwrap(resp["record_id"] as? Int64)
        let payloadStr = try store.pool.read { db in
            try String.fetchOne(db, sql:
                "SELECT payload FROM records WHERE id = ?",
                arguments: [recordID])
        }
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data((payloadStr ?? "").utf8)) as? [String: Any])
        XCTAssertNil(payload["planner_rounds"])
    }

    // MARK: - filename probe (rare-atom path_tokens rescue)

    /// Probe atoms are folded ("đội"→"doi"), ≥3 chars, deduped.
    func testPlannerProbeAtomsFoldedFiltered() {
        let atoms = Search.plannerProbeAtoms(
            query: "Đội hạm con nào đang bị block",
            extraTerms: ["worker status", "block list"])
        XCTAssertTrue(atoms.contains("doi"))
        XCTAssertTrue(atoms.contains("ham"))
        XCTAssertTrue(atoms.contains("block"))
        XCTAssertTrue(atoms.contains("worker"))
        XCTAssertTrue(atoms.contains("status"))
        // 2-char atoms ("bi") dropped; no dupes.
        XCTAssertFalse(atoms.contains("bi"))
        XCTAssertEqual(atoms.count, Set(atoms).count)
    }

    /// A single RARE atom names the file even when the query's other
    /// atoms match nothing — the "seo brain" → p8_brain.py rescue.
    func testPlannerPathProbeRareAtom() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let hits = try Search.plannerPathProbe(
            store: store, atoms: ["brixel", "zzznomatch", "neverthere"])
        XCTAssertEqual(hits.map(\.path), ["brixel.py"])
    }

    /// Multi-atom coverage surfaces the file whose path shares the
    /// most query atoms — {sub,other} → sub/other.py though the query
    /// never names the file stem.
    func testPlannerPathProbeMultiAtomCoverage() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let hits = try Search.plannerPathProbe(
            store: store, atoms: ["sub", "other", "nomatch"])
        XCTAssertEqual(hits.first?.path, "sub/other.py")
    }

    /// Zero-coverage atoms yield nothing — a gibberish probe never
    /// invents evidence.
    func testPlannerPathProbeNoMatchReturnsEmpty() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let hits = try Search.plannerPathProbe(
            store: store, atoms: ["qqqzzz", "nevermatch"])
        XCTAssertTrue(hits.isEmpty)
    }

    /// Integration: collectPlannerEvidence on a query whose hybrid leg
    /// finds nothing still rescues via probeAtoms — a file the rare
    /// atom names lands in the pack as "planner-path" evidence.
    func testCollectPlannerEvidenceProbeRescue() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        let acc = Answer.PackBuilder(
            tokenBudget: Answer.defaultEvidenceTokens, maxItems: 12)
        let added = try Answer.collectPlannerEvidence(
            store: store, acc: acc, query: "zxqvjkwm blorfnotfound",
            pathFilter: nil, probeAtoms: ["brixel"])
        XCTAssertGreaterThanOrEqual(added, 1)
        let item = acc.items.first { $0.path == "brixel.py" }
        XCTAssertEqual(item?.why, "planner-path")
    }

    /// Ollama absent + plan → deterministic pack, planner recorded as
    /// skipped, never a throw.
    func testPlanWithOllamaAbsentDegrades() throws {
        let (dir, store) = try makeWorkspace()
        defer { cleanup(dir) }
        Answer.resetPreflightCache()
        let resp = try Answer.run(
            store: store, query: "what does tom_tat do",
            model: "qwen2.5:3b",
            ollamaBin: "/nonexistent/swctx-planner-test-ollama",
            timeout: 15, source: "test", plan: true)
        XCTAssertTrue(resp["answer"] is NSNull)
        XCTAssertFalse((resp["evidence"] as? [[String: Any]] ?? []).isEmpty)
        let planner = try plannerDict(resp)
        XCTAssertEqual(planner["stopped"] as? String, "ollama_unavailable")
        XCTAssertNotNil(resp["record_id"])
    }
}
