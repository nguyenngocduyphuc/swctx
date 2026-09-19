import Darwin
import Foundation

/// W12 `swctx answer` — local synthesis over verified evidence: hybrid
/// retrieval packs cited chunks (`[E01] path=… start_line=… end_line=…`),
/// a local Ollama model answers with STRICT JSON `{answer, citations,
/// limitations}`, and a server-side validator rejects any citation whose
/// evidence_id is not in the pack (or whose path/lines disagree with it).
/// Ollama absent/model missing → deterministic pack + structured
/// limitation, never a throw and never an auto-pull.
public enum Answer {

    public static let defaultModel = "qwen2.5:3b"
    public static let promptVersion = "answer-v1"
    /// Per-attempt wall clock for one `ollama run`; one format-retry means
    /// the worst case is 2× — sized to stay near the 120s MCP deadline.
    public static let defaultTimeoutSeconds = 60
    /// Evidence prompt budget: qwen2.5:3b has a 32K context; reserving the
    /// bulk for prompt scaffold + generated answer leaves ~4K tokens of
    /// evidence as the measured fit (chars/4 estimate, same as max_tokens).
    public static let defaultEvidenceTokens = 4000
    /// One 3B-class local inference at a time per process — a second
    /// concurrent `answer` waits rather than thrashing the model.
    private static let runSemaphore = DispatchSemaphore(value: 1)

    /// One packed evidence item. `id` is the stable handle the model cites.
    struct Evidence: Sendable {
        var id: String          // "E01"
        var chunkID: Int64
        var path: String
        var startLine: Int
        var endLine: Int
        var why: String         // "direct" | "calls" | "called_by"
        var symbol: String?
        var kind: String?
        var content: String
    }

    /// Model output after JSON extraction + light normalization.
    struct ParsedAnswer {
        var answer: String
        var citations: [[String: Any]]   // raw citation objects (may be partial)
        var limitations: String
    }

    // MARK: - Evidence pack

    /// ~4 chars/token — same estimate `applyBudget` uses for max_tokens.
    static func estTokens(_ s: String) -> Int { (s.count + 3) / 4 }

    /// Render the invariant `[E01] path=… start_line=… end_line=…` handle
    /// line + content for one item.
    static func render(_ e: Evidence) -> String {
        var h = "[\(e.id)] path=\(e.path) start_line=\(e.startLine) end_line=\(e.endLine)"
        if let s = e.symbol, !s.isEmpty { h += " symbol=\(s)" }
        return h + "\n" + e.content
    }

    /// Retrieve + pack evidence: `Search.hybrid` direct hits (file-deduped,
    /// ≤ `directMax`), then 1-hop call/called_by neighbors (≤ `relatedMax`).
    /// Item AND token budgets both apply: items are added in rank order
    /// until either bound trips; an oversize item is trimmed to the
    /// remaining budget rather than silently blowing the context window.
    static func buildPack(store: Store, query: String, pathFilter: String?,
                          directMax: Int = 6, relatedMax: Int = 3,
                          tokenBudget: Int = defaultEvidenceTokens) throws
        -> (evidence: [Evidence], truncated: Bool) {
        let hits = try Search.hybrid(store: store, embedder: store.embedder,
                                     query: query, limit: 16,
                                     pathFilter: pathFilter)
        var pack: [Evidence] = []
        var seenChunks: Set<Int64> = []
        var seenFiles: Set<String> = []
        var usedTokens = 0
        var truncated = false
        var nextID = 1

        func fits(_ content: String) -> String? {
            // returns content (possibly trimmed) that fits the remaining
            // token budget, or nil when nothing meaningful fits
            let overhead = 14   // handle line ≈ 50 chars
            let remain = tokenBudget - usedTokens - overhead
            let minChars = 400  // below this a trimmed tail is noise
            if estTokens(content) <= remain { return content }
            let chars = remain * 4
            guard chars >= minChars else { return nil }
            return String(content.prefix(chars)) + "\n…[truncated]"
        }
        func append(path: String, chunkID: Int64, start: Int, end: Int,
                    why: String, symbol: String?, kind: String?,
                    content: String) {
            guard let c = fits(content) else { truncated = true; return }
            pack.append(Evidence(
                id: String(format: "E%02d", nextID), chunkID: chunkID,
                path: path, startLine: start, endLine: end, why: why,
                symbol: symbol, kind: kind, content: c))
            nextID += 1
            usedTokens += estTokens(c) + 14
            if estTokens(c) < estTokens(content) { truncated = true }
        }

        // Direct hits: file-deduped so the pack covers distinct sources.
        var directSeeds: [SearchHit] = []
        for h in hits where directSeeds.count < directMax {
            guard seenChunks.insert(h.chunkID).inserted,
                  seenFiles.insert(h.path).inserted else { continue }
            directSeeds.append(h)
        }
        // Hydrate direct content in one query, preserving rank order.
        let directContent = try ContextPack.contents(
            store: store, ids: directSeeds.map(\.chunkID))
        for h in directSeeds {
            guard let c = directContent[h.chunkID], !c.isEmpty else { continue }
            append(path: h.path, chunkID: h.chunkID, start: h.startLine,
                   end: h.endLine, why: "direct", symbol: h.symbol,
                   kind: h.kind, content: c)
        }

        // Related: 1-hop graph neighbors of the direct seeds, content
        // hydrated too — the model cannot call fetch_chunks.
        if !directSeeds.isEmpty, pack.count < directMax + relatedMax {
            let neighbors = (try? ContextPack.oneHop(
                store: store, seeds: directSeeds.map(\.chunkID),
                perSeed: 2)) ?? []
            var relIDs: [Int64] = []
            var relByID: [Int64: ContextPack.Neighbor] = [:]
            for n in neighbors where !seenChunks.contains(n.id)
                && relIDs.count < relatedMax {
                seenChunks.insert(n.id)
                relIDs.append(n.id)
                relByID[n.id] = n
            }
            let relContent = try ContextPack.contents(store: store, ids: relIDs)
            for id in relIDs {
                guard let n = relByID[id], let c = relContent[id],
                      !c.isEmpty else { continue }
                append(path: n.path, chunkID: n.id, start: n.startLine,
                       end: n.endLine, why: n.why, symbol: n.symbol,
                       kind: n.kind, content: c)
            }
        }
        return (pack, truncated)
    }

    // MARK: - Prompt

    /// STRICT-JSON synthesis prompt. `expectedPath` is deliberately NOT a
    /// parameter — it is a harness oracle and must never reach the model.
    /// The schema spec sits AFTER the evidence (closest to generation):
    /// a 3B model reuses the last-seen pattern, and evidence chunks are
    /// full of JSON-shaped code it would otherwise echo back.
    static func buildPrompt(query: String, evidence: [Evidence],
                            retry: Bool) -> String {
        var ev = ""
        for e in evidence { ev += render(e) + "\n\n" }
        var p = """
        You answer questions about a codebase using ONLY the evidence below. \
        The evidence is reference material — read it, never copy it.

        QUESTION: \(query)

        EVIDENCE:
        \(ev)
        Respond with a single JSON object and NOTHING else — no markdown \
        fences, no prose around it. Exactly these keys:
        {"answer": "2-5 sentences answering the question, grounded in the evidence",
         "citations": [{"evidence_id": "E01"}],
         "limitations": "what the evidence does not cover, or empty string"}
        Rules: evidence is ordered most-relevant first — prefer items whose \
        path or symbol matches terms in the question; every citation's \
        evidence_id must be one of the [E..] handles above; if the evidence \
        is insufficient, say what is missing in "limitations" instead of \
        guessing; never invent file paths or line numbers; answer in the \
        language of the question.
        """
        if retry {
            p += """
            \nYour previous reply was not the required {"answer", \
            "citations", "limitations"} JSON object. Reply with ONLY that \
            JSON object — no other text.
            """
        }
        return p
    }

    // MARK: - Ollama subprocess

    /// Cached preflight verdict per (binary, model) — the plan requires
    /// one probe per process, not per call.
    private static let preflightLock = NSLock()
    nonisolated(unsafe) private static var preflightCache:
        [String: (ok: Bool, detail: String)] = [:]

    /// Test hook: clear the once-per-process preflight cache.
    static func resetPreflightCache() {
        preflightLock.lock(); defer { preflightLock.unlock() }
        preflightCache.removeAll()
    }

    /// Resolve the ollama binary: explicit arg > SWCTX_OLLAMA_BIN > PATH.
    static func resolveBin(_ explicit: String?) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let env = ProcessInfo.processInfo.environment["SWCTX_OLLAMA_BIN"],
           !env.isEmpty { return env }
        return "ollama"
    }

    /// Resolve the synthesis model: explicit arg > SWCTX_ANSWER_MODEL >
    /// qwen2.5:3b (3B default; a 27B-class model is selectable for the
    /// quality route — measured separately, per plan v2).
    static func resolveModel(_ explicit: String?) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let env = ProcessInfo.processInfo.environment["SWCTX_ANSWER_MODEL"],
           !env.isEmpty { return env }
        return defaultModel
    }

    /// One probe per (bin, model): `ollama list` proves the binary AND the
    /// daemon, and the model column proves the model is already local —
    /// `ollama run` auto-pulls missing models, which this gate forbids.
    static func ollamaAvailable(bin: String, model: String)
        -> (ok: Bool, detail: String) {
        let key = "\(bin)\u{1f}\(model)"
        preflightLock.lock()
        if let c = preflightCache[key] {
            preflightLock.unlock()
            return c
        }
        preflightLock.unlock()
        var result: (Bool, String)
        do {
            let out = try spawn(bin, argv: ["list"], timeout: 15)
            var found = false
            for line in out.split(separator: "\n").dropFirst() {
                let name = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first.map(String.init) ?? ""
                if name == model || name == "\(model):latest"
                    || (!model.contains(":") && name.hasPrefix("\(model):")) {
                    found = true
                    break
                }
            }
            result = found
                ? (true, "ok")
                : (false, "model '\(model)' not in `ollama list` (no auto-pull)")
        } catch {
            result = (false, "ollama unavailable: \(error.localizedDescription)")
        }
        preflightLock.lock()
        preflightCache[key] = result
        preflightLock.unlock()
        return result
    }

    /// `bin argv`, capturing stdout — same shape as AskCmd.spawn: posix_spawnp
    /// + POSIX_SPAWN_SETPGROUP (pgid == child pid, no setpgid race), both
    /// pipes drained CONCURRENTLY with the wait so a >64KB write can't
    /// deadlock the child, and on timeout the whole process GROUP gets
    /// TERM→KILL so forking descendants can't escape.
    static func spawn(_ bin: String, argv: [String], timeout: Int) throws -> String {
        let out = Pipe()
        let err = Pipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions,
            out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions,
            err.fileHandleForWriting.fileDescriptor, 2)
        for h in [out.fileHandleForReading, out.fileHandleForWriting,
                  err.fileHandleForReading, err.fileHandleForWriting] {
            posix_spawn_file_actions_addclose(&actions, h.fileDescriptor)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var sflags: Int16 = 0
        posix_spawnattr_getflags(&attr, &sflags)
        posix_spawnattr_setflags(&attr, sflags | Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var pid: pid_t = 0
        var cargs = ([bin] + argv).map { strdup($0) }
            + [nil as UnsafeMutablePointer<CChar>?]
        defer { cargs.forEach { free($0) } }
        let rc = cargs.withUnsafeMutableBufferPointer { cargv in
            posix_spawnp(&pid, bin, &actions, &attr, cargv.baseAddress,
                         environ)
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        guard rc == 0 else {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            throw ToolError.invalidArg("cannot spawn \(bin): errno \(rc)")
        }

        final class WaitStatus { var raw: Int32 = -1 }
        let wstatus = WaitStatus()
        let outData = NSMutableData()
        let errData = NSMutableData()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global().async {
            outData.append(out.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }
        drain.enter()
        DispatchQueue.global().async {
            errData.append(err.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var st: Int32 = 0
            _ = waitpid(pid, &st, 0)
            wstatus.raw = st
            sem.signal()
        }
        if sem.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            kill(-pid, SIGTERM)
            _ = sem.wait(timeout: .now() + .milliseconds(300))
            kill(-pid, SIGKILL)
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = drain.wait(timeout: .now() + .seconds(2))
            throw ToolError.invalidArg("ollama timed out after \(timeout)s")
        }
        if drain.wait(timeout: .now() + .seconds(5)) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = drain.wait(timeout: .now() + .seconds(2))
        }
        let text = String(decoding: outData as Data, as: UTF8.self)
        let st = wstatus.raw
        let statusDesc = (st & 0x7f == 0)
            ? "exited \(Int((st >> 8) & 0xff))" : "killed by signal \(st & 0x7f)"
        guard st & 0x7f == 0, (st >> 8) & 0xff == 0 else {
            let e = String(decoding: errData as Data, as: UTF8.self)
            throw ToolError.invalidArg("\(bin) \(statusDesc): \(e.prefix(400))")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output parsing + citation validation

    /// `ollama run` leaks terminal spinner control sequences into stdout
    /// even when piped (observed mid-string inside generated JSON) —
    /// strip CSI sequences before anything parses the text.
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "",
            options: .regularExpression)
    }

    /// Extract the strict JSON object the model was asked for. Tolerates
    /// leading prose / ```json fences by slicing first-`{` to last-`}`;
    /// requires `answer` non-empty. Returns nil → caller may retry once.
    static func parseAnswer(_ raw: String) -> ParsedAnswer? {
        var s = stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var dict = (try? JSONSerialization.jsonObject(with: Data(s.utf8)))
            as? [String: Any]
        if dict == nil, let lo = s.firstIndex(of: "{"),
           let hi = s.lastIndex(of: "}"), hi > lo {
            dict = (try? JSONSerialization.jsonObject(
                with: Data(String(s[lo...hi]).utf8))) as? [String: Any]
        }
        guard let d = dict,
              let answer = d["answer"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // citations: objects preferred; bare "E01" strings normalize up.
        var citations: [[String: Any]] = []
        for c in (d["citations"] as? [Any]) ?? [] {
            if let o = c as? [String: Any] { citations.append(o) }
            else if let s = c as? String { citations.append(["evidence_id": s]) }
            else if let i = c as? Int { citations.append(["evidence_id": "E\(i)"]) }
        }
        return ParsedAnswer(
            answer: answer,
            citations: citations,
            limitations: (d["limitations"] as? String) ?? "")
    }

    /// Normalize an evidence_id the model emitted: "E01", "e1", "1",
    /// "E-02" → "E01"/"E02". Anything non-numeric returns nil.
    static func normalizeEvidenceID(_ raw: Any) -> String? {
        var s: String
        switch raw {
        case let i as Int: s = "\(i)"
        case let v as String: s = v
        default: return nil
        }
        s = s.trimmingCharacters(in: .whitespaces)
            .uppercased()
            .replacingOccurrences(of: "E", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "#", with: "")
        guard let n = Int(s), n > 0 else { return nil }
        return String(format: "E%02d", n)
    }

    /// Server-side validator: a citation counts ONLY when its evidence_id
    /// exists in the pack AND any path/line the model asserted matches the
    /// pack item verbatim — a model-invented path is invalid, never trusted.
    static func validateCitations(_ raw: [[String: Any]], pack: [Evidence])
        -> (resolved: [[String: Any]], invalid: [String], valid: Bool) {
        let byID = Dictionary(uniqueKeysWithValues: pack.map { ($0.id, $0) })
        var resolved: [[String: Any]] = []
        var invalid: [String] = []
        var seen: Set<String> = []
        for c in raw {
            guard let id = normalizeEvidenceID(c["evidence_id"] ?? c["id"] as Any) else {
                invalid.append("unparseable citation: \(c)"); continue
            }
            guard let ev = byID[id] else {
                invalid.append("\(id) not in evidence pack"); continue
            }
            var mismatch = false
            if let p = c["path"] as? String, p != ev.path { mismatch = true }
            if let sl = c["start_line"] as? Int, sl != ev.startLine { mismatch = true }
            if let sl = c["start_line"] as? Double, Int(sl) != ev.startLine { mismatch = true }
            if let el = c["end_line"] as? Int, el != ev.endLine { mismatch = true }
            if let el = c["end_line"] as? Double, Int(el) != ev.endLine { mismatch = true }
            if mismatch {
                invalid.append("\(id) path/line mismatch"); continue
            }
            guard seen.insert(id).inserted else { continue }  // dup is harmless
            resolved.append([
                "evidence_id": id, "chunk_id": ev.chunkID, "path": ev.path,
                "start_line": ev.startLine, "end_line": ev.endLine,
            ])
        }
        // Empty citation set is not "valid": the answer is unverifiable.
        // An honest insufficient-evidence answer still lands here — the
        // limitations field carries that nuance for the harness.
        return (resolved, invalid,
                invalid.isEmpty && !resolved.isEmpty)
    }

    // MARK: - Top level

    /// Retrieve → (preflight) → Ollama → validate → record. Ollama-side
    /// failures degrade to the deterministic pack + a structured
    /// `limitations` field; only index/retrieval errors throw.
    /// `expectedPath` is a harness oracle: echoed into the response and the
    /// durable record for scoring, NEVER into the prompt.
    public static func run(store: Store, query: String, model: String? = nil,
                           ollamaBin: String? = nil, timeout: Int = defaultTimeoutSeconds,
                           expectedPath: String? = nil, source: String = "mcp",
                           pathFilter: String? = nil) throws -> [String: Any] {
        let t0 = Date()
        let modelID = resolveModel(model)
        let bin = resolveBin(ollamaBin)
        let clampedTimeout = min(max(timeout, 5), 900)
        let packResult = try buildPack(store: store, query: query,
                                       pathFilter: pathFilter)
        let pack = packResult.evidence
        var limitations: [String] = []
        if packResult.truncated {
            limitations.append("evidence pack trimmed to token budget")
        }

        var answer: String? = nil
        var resolvedCitations: [[String: Any]] = []
        var invalidCitations: [String] = []
        var citationValid = false
        var attempts = 0
        var ollamaOK = false
        var rawOutput: String? = nil

        if pack.isEmpty {
            limitations.append("no evidence retrieved for query")
        } else {
            let pre = ollamaAvailable(bin: bin, model: modelID)
            ollamaOK = pre.ok
            if !pre.ok {
                limitations.append("ollama unavailable — deterministic evidence pack only (\(pre.detail))")
            } else {
                // One 3B-class local run at a time; a queued second caller
                // degrades instead of double-loading the model.
                let waitBudget = DispatchTime.now()
                    + .seconds(clampedTimeout * 2 + 30)
                guard runSemaphore.wait(timeout: waitBudget) == .success else {
                    limitations.append("another answer run held the local model semaphore")
                    return finish(store: store, query: query, model: modelID,
                                  pack: pack, packTruncated: packResult.truncated,
                                  answer: nil, resolved: [], invalid: [],
                                  citationValid: false, attempts: 0,
                                  ollamaOK: true, rawOutput: nil,
                                  limitations: limitations, expectedPath: expectedPath,
                                  source: source, t0: t0)
                }
                defer { runSemaphore.signal() }
                for attempt in 1...2 {
                    attempts = attempt
                    let prompt = buildPrompt(query: query, evidence: pack,
                                             retry: attempt == 2)
                    do {
                        // --nowordwrap: without it `ollama run` rewraps
                        // output at ~50 cols, injecting literal \n inside
                        // JSON string values and corrupting the payload.
                        let out = try spawn(bin, argv: [
                            "run", modelID, "--format", "json",
                            "--hidethinking", "--nowordwrap", prompt,
                        ], timeout: clampedTimeout)
                        rawOutput = stripANSI(out)
                        if let parsed = parseAnswer(out) {
                            answer = parsed.answer
                            let v = validateCitations(parsed.citations, pack: pack)
                            resolvedCitations = v.resolved
                            invalidCitations = v.invalid
                            citationValid = v.valid
                            if !parsed.limitations.isEmpty {
                                limitations.append(parsed.limitations)
                            }
                            break
                        }
                        // malformed → exactly one format-retry
                        if attempt == 2 {
                            limitations.append("model output was not the required JSON after 1 format-retry")
                        }
                    } catch {
                        limitations.append("ollama call failed: \(error.localizedDescription)")
                        break   // transport errors never retry
                    }
                }
                if !invalidCitations.isEmpty {
                    limitations.append("\(invalidCitations.count) citation(s) rejected: "
                        + invalidCitations.joined(separator: "; "))
                }
                if answer != nil, resolvedCitations.isEmpty, invalidCitations.isEmpty {
                    limitations.append("model returned no usable citations")
                }
            }
        }

        return finish(store: store, query: query, model: modelID, pack: pack,
                      packTruncated: packResult.truncated, answer: answer,
                      resolved: resolvedCitations, invalid: invalidCitations,
                      citationValid: citationValid, attempts: attempts,
                      ollamaOK: ollamaOK, rawOutput: answer == nil ? rawOutput : nil,
                      limitations: limitations, expectedPath: expectedPath,
                      source: source, t0: t0)
    }

    /// Assemble the response dict + write the durable `kind=ask` record.
    /// The record write is `try?` — a ledger failure must never lose the
    /// answer (plan F5).
    static func finish(store: Store, query: String, model: String,
                       pack: [Evidence], packTruncated: Bool,
                       answer: String?, resolved: [[String: Any]],
                       invalid: [String], citationValid: Bool,
                       attempts: Int, ollamaOK: Bool, rawOutput: String?,
                       limitations: [String], expectedPath: String?,
                       source: String, t0: Date) -> [String: Any] {
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        let evidenceDicts: [[String: Any]] = pack.map { e in
            var d: [String: Any] = [
                "evidence_id": e.id, "chunk_id": e.chunkID, "path": e.path,
                "start_line": e.startLine, "end_line": e.endLine, "why": e.why,
            ]
            if let s = e.symbol { d["symbol"] = s }
            if let k = e.kind { d["kind"] = k }
            d["content"] = e.content
            return d
        }
        let limitationText = limitations.filter { !$0.isEmpty }
            .joined(separator: " | ")

        var resp: [String: Any] = [
            "query": query, "model": model, "prompt_version": promptVersion,
            "answer": answer ?? NSNull(),
            "citations": resolved,
            "citation_valid": citationValid,
            "limitations": limitationText,
            "evidence": evidenceDicts,
            "evidence_truncated": packTruncated,
            "ollama": [
                "available": ollamaOK, "attempts": attempts,
                "latency_ms": latencyMs,
            ],
        ]
        if !invalid.isEmpty { resp["invalid_citations"] = invalid }
        if let rawOutput { resp["raw_output"] = String(rawOutput.prefix(4000)) }
        if let expectedPath { resp["expected_path"] = expectedPath }

        // Durable record — same ledger path as contextPack/putRecord:
        // staleness evidence (HEAD + resolving anchors) included.
        var payload: [String: Any] = [
            "query": query, "model": model, "prompt_version": promptVersion,
            "evidence": pack.map {
                ["evidence_id": $0.id, "chunk_id": $0.chunkID, "path": $0.path,
                 "start_line": $0.startLine, "end_line": $0.endLine] as [String: Any]
            },
            "citations": resolved,
            "invalid_citations": invalid,
            "citation_valid": citationValid,
            "ollama_available": ollamaOK,
            "attempts": attempts,
            "latency_ms": latencyMs,
            "limitations": limitationText,
        ]
        if let answer { payload["answer"] = answer }
        if let expectedPath { payload["expected_path"] = expectedPath }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let payloadJSON = String(data: data, encoding: .utf8) {
            let headSHA = GlobalRecords.git(["rev-parse", "HEAD"],
                                            cwd: store.workspaceRoot)
            let anchors = (try? SwctxTools.recordAnchors(
                store: store, text: query + "\n" + payloadJSON)) ?? []
            if let rid = try? store.insertRecord(
                kind: "ask", source: source, status: "completed",
                title: query, payloadJSON: payloadJSON,
                headSHA: headSHA, anchors: anchors) {
                resp["record_id"] = rid
            }
        }
        return resp
    }
}
