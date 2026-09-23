import Darwin
import Foundation
import GRDB

/// W12 `swctx answer` — local synthesis over verified evidence: hybrid
/// retrieval packs cited chunks (`[E01] path=… start_line=… end_line=…`),
/// a synthesis backend answers with STRICT JSON `{answer, citations,
/// limitations}`, and a server-side validator rejects any citation whose
/// evidence_id is not in the pack (or whose path/lines disagree with it).
/// Default backend is `auto`: first usable fleet CLI (agy → codex →
/// claude, free subscription compose) else local Ollama. Backend absent/
/// model missing → deterministic pack + structured limitation, never a
/// throw and never an auto-pull — and never a paid service.
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
    /// Planner bounds (`answer --plan`): ≤4 retrieval rounds, ≤3 queries per
    /// round, pack capped at 12 items, ~60s total wall deadline with ~20s
    /// per planner call — then synthesis runs over whatever evidence exists.
    public static let plannerMaxRounds = 4
    public static let plannerMaxQueriesPerRound = 3
    public static let plannerMaxEvidence = 12
    /// Each planner query contributes at most this many file-deduped items
    /// — breadth-first admission: every tried query gets its best file
    /// before any query spends a second slot of the ≤12-item pack.
    public static let plannerPerQueryCap = 2
    /// Deterministic question-derived variants tried alongside the model's
    /// queries each search round (rescue doesn't hinge on a 3B's guesses).
    public static let plannerAutoPerRound = 2
    /// Auto-variants run first and admit only their top file — they are
    /// precision probes, and the budget they leave behind is the model's
    /// to spend.
    public static let plannerAutoPerQueryCap = 1
    public static let defaultPlanTimeoutSeconds = 60
    public static let plannerCallTimeoutSeconds = 20
    /// Plan mode caps the initial fill at this many tokens — a couple of
    /// fat markdown chunks can otherwise spend the whole 4000-token
    /// budget before the planner's rescue queries get any room.
    public static let planInitialTokenCeiling = 2200
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

    /// Bounded pack accumulator shared by the initial retrieval pass and
    /// the planner's extra rounds: file-dedup, the item cap and the token
    /// budget live in one place, and every appended item mints the next
    /// sequential E-handle so planner additions are citable like any
    /// other evidence.
    final class PackBuilder {
        let tokenBudget: Int
        /// Soft token cap — plan mode lowers it for the initial fill so
        /// planner rounds inherit real headroom; restored to the full
        /// budget before the planner starts adding evidence.
        var tokenCeiling: Int
        var maxItems: Int
        private(set) var items: [Evidence] = []
        var seenChunks: Set<Int64> = []
        var seenFiles: Set<String> = []
        private(set) var usedTokens = 0
        private(set) var truncated = false

        init(tokenBudget: Int, maxItems: Int) {
            self.tokenBudget = tokenBudget
            self.tokenCeiling = tokenBudget
            self.maxItems = maxItems
        }

        /// True while another meaningful item could still be appended —
        /// item cap AND token ceiling both open. The planner's early-stop
        /// condition: a pack that can't grow ends the loop.
        var hasRoom: Bool {
            items.count < maxItems
                && tokenCeiling - usedTokens - 14 >= 100   // ≥400 chars
        }

        /// Returns content (possibly trimmed) that fits the remaining
        /// token budget, or nil when nothing meaningful fits.
        func fits(_ content: String) -> String? {
            let overhead = 14   // handle line ≈ 50 chars
            let remain = tokenCeiling - usedTokens - overhead
            let minChars = 400  // below this a trimmed tail is noise
            if estTokens(content) <= remain { return content }
            let chars = remain * 4
            guard chars >= minChars else { return nil }
            return String(content.prefix(chars)) + "\n…[truncated]"
        }

        /// Append one item under the item cap AND token budget; returns
        /// false (and marks `truncated`) when either bound trips.
        @discardableResult
        func append(path: String, chunkID: Int64, start: Int, end: Int,
                    why: String, symbol: String?, kind: String?,
                    content: String) -> Bool {
            guard items.count < maxItems, let c = fits(content) else {
                truncated = true
                return false
            }
            items.append(Evidence(
                id: String(format: "E%02d", items.count + 1),
                chunkID: chunkID, path: path, startLine: start,
                endLine: end, why: why, symbol: symbol, kind: kind,
                content: c))
            usedTokens += estTokens(c) + 14
            if estTokens(c) < estTokens(content) { truncated = true }
            return true
        }

        /// File-dedupe `hits` against the pack (a new chunk of an
        /// already-covered file is still skipped), hydrate content in one
        /// query, append in rank order. `cap` bounds items added from one
        /// call — the planner passes plannerPerQueryCap so one broad query
        /// can't flood the pack. Returns items actually added — the
        /// planner's zero-growth signal.
        @discardableResult
        func addSearchHits(store: Store, hits: [SearchHit],
                           why: String, cap: Int? = nil) throws -> Int {
            let cap = cap ?? maxItems
            var seeds: [SearchHit] = []
            for h in hits where seeds.count < cap {
                guard seenChunks.insert(h.chunkID).inserted,
                      seenFiles.insert(h.path).inserted else { continue }
                seeds.append(h)
            }
            let contents = try ContextPack.contents(
                store: store, ids: seeds.map(\.chunkID))
            var added = 0
            for h in seeds {
                guard let c = contents[h.chunkID], !c.isEmpty else { continue }
                guard append(path: h.path, chunkID: h.chunkID,
                             start: h.startLine, end: h.endLine, why: why,
                             symbol: h.symbol, kind: h.kind,
                             content: c) else { break }
                added += 1
            }
            return added
        }
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
        let acc = PackBuilder(tokenBudget: tokenBudget,
                              maxItems: directMax + relatedMax)
        try fillInitialPack(store: store, acc: acc, query: query,
                            pathFilter: pathFilter,
                            directMax: directMax, relatedMax: relatedMax)
        return (acc.items, acc.truncated)
    }

    /// The first retrieval pass into `acc` — kept separate from
    /// `buildPack` so `run` can keep the accumulator (and its seen-sets)
    /// for planner rounds that extend the same pack.
    static func fillInitialPack(store: Store, acc: PackBuilder,
                                query: String, pathFilter: String?,
                                directMax: Int = 6,
                                relatedMax: Int = 3) throws {
        // Filename probe FIRST: rare query atoms get a solo path_tokens
        // pass so a common term can't bury the file a rare atom names —
        // "bộ não … SEO" never says "brain", but if any query atom is
        // rare the file it names surfaces. It runs before hybrid because
        // broad hits would otherwise fill the pack and the surgical
        // filename match would be dropped. Cached translation terms
        // join for free — a cache lookup only, never a model call.
        let probe = try pathProbe(store: store, query: query,
                                  pathFilter: pathFilter)
        _ = try? acc.addSearchHits(store: store, hits: probe,
                                   why: "path-probe", cap: 6)

        let hits = try Search.hybrid(store: store, embedder: store.embedder,
                                     query: query, limit: 16,
                                     pathFilter: pathFilter)
        // Direct hits: file-deduped so the pack covers distinct sources.
        var directSeeds: [SearchHit] = []
        for h in hits where directSeeds.count < directMax {
            guard acc.seenChunks.insert(h.chunkID).inserted,
                  acc.seenFiles.insert(h.path).inserted else { continue }
            directSeeds.append(h)
        }
        // Hydrate direct content in one query, preserving rank order.
        let directContent = try ContextPack.contents(
            store: store, ids: directSeeds.map(\.chunkID))
        for h in directSeeds {
            guard let c = directContent[h.chunkID], !c.isEmpty else { continue }
            acc.append(path: h.path, chunkID: h.chunkID, start: h.startLine,
                       end: h.endLine, why: "direct", symbol: h.symbol,
                       kind: h.kind, content: c)
        }

        // Related: 1-hop graph neighbors of the direct seeds, content
        // hydrated too — the model cannot call fetch_chunks.
        if !directSeeds.isEmpty, acc.items.count < acc.maxItems {
            let neighbors = (try? ContextPack.oneHop(
                store: store, seeds: directSeeds.map(\.chunkID),
                perSeed: 2)) ?? []
            var relIDs: [Int64] = []
            var relByID: [Int64: ContextPack.Neighbor] = [:]
            for n in neighbors where !acc.seenChunks.contains(n.id)
                && relIDs.count < relatedMax {
                acc.seenChunks.insert(n.id)
                relIDs.append(n.id)
                relByID[n.id] = n
            }
            let relContent = try ContextPack.contents(store: store, ids: relIDs)
            for id in relIDs {
                guard let n = relByID[id], let c = relContent[id],
                      !c.isEmpty else { continue }
                acc.append(path: n.path, chunkID: n.id, start: n.startLine,
                           end: n.endLine, why: n.why, symbol: n.symbol,
                           kind: n.kind, content: c)
            }
        }
    }

    /// The filename probe shared by the initial fill and planner
    /// rounds: atoms of `query` merged with `extraAtoms` (the original
    /// question's atoms — VN filename atoms the model's English
    /// variants drop, e.g. "đội hạm" → "doi") plus that query's cached
    /// translation terms AND the deterministic VN lexicon (both lookups
    /// only, never a model call).
    static func pathProbe(store: Store, query: String,
                          pathFilter: String?,
                          extraAtoms: [String] = []) throws -> [SearchHit] {
        var terms = extraAtoms
        terms += Translation.lexiconTerms(for: query)
        // EN→VN rescue: an English query has no VN atoms to probe
        // BietXong/GuiViec-style filenames; the enLexicon supplies them.
        // Gated on the corpus actually using VN names so pure-English
        // repos never pay the extra atoms.
        if Translation.corpusHasVNFilenames(store: store) {
            terms += Translation.vnTerms(for: query)
        }
        if let t = Translation.activeCache.get(Translation.cacheKey(query)) {
            terms += t
        }
        // Reformulation leg: model-guessed filename vocabulary ("sổ tay"
        // → "so_tay","digest") — rides the translation roll, lands in
        // the same cache, stays weak+champion-eligible in the probe.
        let guessed = Translation.filenameTerms(for: query) ?? []
        let (atoms, weak, championless) = Search.plannerProbeAtomSets(
            query: query, extraTerms: terms, guessedTerms: guessed)
        guard !atoms.isEmpty else { return [] }
        return (try? Search.plannerPathProbe(
            store: store, atoms: atoms, weakAtoms: weak,
            championlessAtoms: championless,
            pathFilter: pathFilter)) ?? []
    }

    /// One planner search: the filename probe runs FIRST (`why=
    /// "planner-path"`) — a rare-atom stem match is the surgical signal
    /// and must not be crowded out by broad hybrid hits — then hybrid
    /// hits file-dedupe in (`why="planner"`). Returns NEW items
    /// appended — 0 means the query added nothing (early-stop streak).
    static func collectPlannerEvidence(store: Store, acc: PackBuilder,
                                       query: String,
                                       cap: Int = plannerPerQueryCap,
                                       pathFilter: String?,
                                       probeAtoms: [String] = []) throws -> Int {
        var added = 0
        let probe = try pathProbe(store: store, query: query,
                                  pathFilter: pathFilter,
                                  extraAtoms: probeAtoms)
        added += try acc.addSearchHits(store: store, hits: probe,
                                       why: "planner-path", cap: 6)
        let hits = try Search.hybrid(store: store, embedder: store.embedder,
                                     query: query, limit: 16,
                                     pathFilter: pathFilter)
        added += try acc.addSearchHits(store: store, hits: hits,
                                       why: "planner", cap: cap)
        return added
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

    // MARK: - Planner loop (`answer --plan`)

    /// Planner telemetry — recorded into the `kind=ask` record payload as
    /// planner_rounds / queries_tried / evidence_growth (+stopped reason).
    struct PlannerReport {
        var rounds = 0
        var queriesTried: [String] = []
        var evidenceGrowth: [Int] = []   // items added per executed round
        var malformed = 0                // planner outputs that weren't strict JSON
        var stopped = ""                 // answer|round_cap|deadline|no_new_evidence|pack_full|planner_error|ollama_unavailable|semaphore_busy
    }

    /// The planner's decision for one round.
    enum PlannerAction: Equatable {
        case search([String])
        case answer
    }

    /// Compact planner prompt: the question + evidence HANDLES only
    /// (id/path/lines — never content, keeping the prompt small) + the
    /// queries already tried so the model doesn't loop on repeats + a few
    /// real sibling paths so it can imitate the corpus's naming language
    /// (this corpus names files in Vietnamese snake_case — an honest `ls`
    /// signal, not an oracle). `expectedPath` stays a harness oracle —
    /// never a parameter here.
    static func buildPlannerPrompt(query: String, pack: [Evidence],
                                   triedQueries: [String],
                                   nearby: [String],
                                   round: Int, maxRounds: Int) -> String {
        var ev = ""
        for e in pack {
            ev += "[\(e.id)] path=\(e.path) start_line=\(e.startLine) end_line=\(e.endLine)\n"
        }
        if ev.isEmpty { ev = "(none yet)\n" }
        let tried = triedQueries.isEmpty
            ? "(none)"
            : triedQueries.map { "\"\($0)\"" }.joined(separator: ", ")
        var nb = ""
        for p in nearby { nb += p + "\n" }
        if nb.isEmpty { nb = "(none)\n" }
        return """
        You plan retrieval for a code search engine over a mixed \
        Vietnamese/English codebase.

        USER QUESTION: \(query)

        EVIDENCE COLLECTED SO FAR (handles only):
        \(ev)
        NEARBY INDEXED FILES (naming hints — imitate their language):
        \(nb)
        SEARCH QUERIES ALREADY TRIED: \(tried)

        Reply with ONE JSON object and nothing else:
        - the collected evidence is enough to answer → {"action":"answer"}
        - need more retrieval → \
        {"action":"search","queries":["<terms>","<terms>","<terms>"]}

        Each query is 2-6 words of real search terms — never a \
        placeholder like "q1". Spread the angles across queries: the \
        question's key nouns verbatim, the same idea in the OTHER \
        language (Vietnamese ↔ English), and snake_case identifier or \
        filename guesses matching the naming style above. To search a \
        hinted file, use its stem tokens — "foo-bar.md" → "foo bar", \
        "sync_users.py" → "sync users". \
        {"action":"search","queries":["<key nouns from the question>","<same idea in English>","<snake_case file guess>"]}
        Never repeat a tried query. Never reuse terms from these \
        instructions — only terms about THIS question. \
        Round \(round) of \(maxRounds).
        """
    }

    /// `ls`-style context for the planner: real indexed paths in the
    /// directories evidence already landed in (the target is often a
    /// sibling of a near-miss), ranked by basename/token overlap with the
    /// question so VN-derived names surface; plus a couple of top-level
    /// segments for orientation. Deterministic, path-only, ≤ `limit`.
    static func siblingHints(store: Store, pack: [Evidence], query: String,
                           limit: Int = 14) -> [String] {
        let packPaths = Set(pack.map(\.path))
        let qTerms = Set(Search.foldText(query)
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 })
        var dirs: [String] = []
        var seenDirs: Set<String> = []
        for e in pack {
            let d = (e.path as NSString).deletingLastPathComponent
            if !d.isEmpty, seenDirs.insert(d).inserted { dirs.append(d) }
            if dirs.count >= 3 { break }
        }
        var hints: [String] = []
        var hintSet: Set<String> = []
        for d in dirs {
            let esc = d.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let rows = (try? store.pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT path FROM files
                    WHERE path LIKE ? ESCAPE '\\' LIMIT 40
                    """, arguments: [esc + "/%"])
            }) ?? []
            // Rank by basename-token overlap with the question — a
            // sibling whose name shares a query noun is the likeliest
            // naming-convention hint (and often the miss itself).
            var scored: [(String, Int)] = []
            for r in rows {
                guard let p = r["path"] as? String,
                      !packPaths.contains(p) else { continue }
                let base = (p as NSString).lastPathComponent
                let bToks = Set(Search.foldText(base)
                    .components(separatedBy: .alphanumerics.inverted)
                    .filter { $0.count >= 2 && $0 != "py" && $0 != "md" })
                scored.append((p, bToks.intersection(qTerms).count))
            }
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            for (p, _) in scored.prefix(6) {
                if hintSet.insert(p).inserted { hints.append(p) }
                if hints.count >= limit { return hints }
            }
        }
        // A couple of top-level segments for orientation (also the sole
        // hint when the pack is empty or root-only).
        let topRows = (try? store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT path FROM files LIMIT 300")
        }) ?? []
        for r in topRows {
            guard let p = r["path"] as? String else { continue }
            let comps = p.split(separator: "/", omittingEmptySubsequences: true)
            // A directory hint — never a file already in the pack:
            // "a/b/c.py" → "a/b", "a/b.py" → "a", "b.py" → "b.py" (root).
            let seg = comps.count > 2
                ? comps.prefix(2).joined(separator: "/")
                : comps.count == 2
                    ? String(comps[0])
                    : p
            if hintSet.insert(seg).inserted { hints.append(seg) }
            if hints.count >= limit { break }
        }
        return hints
    }

    /// Deterministic question-derived variants: adjacent bigrams, tail
    /// first — in these mixed-VN questions the qualifier noun phrase that
    /// became the filename ("…để đóng vòng" → dong_vong.py) sits at the
    /// end. Pairs containing a function word ("into the", "đang bị") are
    /// skipped — they rank noise into the pack. Deduped, ≤ `limit`.
    static func plannerAutoVariants(_ query: String, limit: Int) -> [String] {
        let toks = query.components(separatedBy: .alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        var out: [String] = []
        var seen: Set<String> = []
        for pair in zip(toks, toks.dropFirst()).reversed() {
            if stopPair(pair.0, pair.1) { continue }
            let s = pair.0 + " " + pair.1
            if seen.insert(s.lowercased()).inserted { out.append(s) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Function words (EN + VN, stored folded) that make a bigram a
    /// noise probe. A pair is skipped when EITHER side is one —
    /// "operations ledger" survives, "the operations" doesn't.
    private static let autoStopwords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "for", "on", "at", "by",
        "with", "from", "into", "and", "or", "but", "is", "are", "was",
        "were", "be", "been", "it", "its", "that", "this", "one", "when",
        "while", "as", "do", "does",
        // Vietnamese, folded (để→de, của→cua, đang→dang, …)
        "va", "cua", "cho", "trong", "cac", "mot", "khi", "la", "bi",
        "dang", "con", "nao", "theo", "de", "voi", "thanh", "nhung",
        "moi", "tung",
    ]

    private static func stopPair(_ a: String, _ b: String) -> Bool {
        autoStopwords.contains(Search.foldText(a))
            || autoStopwords.contains(Search.foldText(b))
    }

    /// Parse the planner's STRICT JSON decision. Anything unparseable —
    /// prose, fences, wrong schema — degrades to {"action":"answer"} so a
    /// noisy model can never crash or wedge the loop. `queries` is capped
    /// at plannerMaxQueriesPerRound (query-explosion guard).
    static func parsePlannerAction(_ raw: String)
        -> (action: PlannerAction, malformed: Bool) {
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
              let action = (d["action"] as? String)?
                .trimmingCharacters(in: .whitespaces).lowercased()
        else { return (.answer, true) }
        guard action == "search" else {
            return (.answer, action != "answer")
        }
        var queries: [String] = []
        for q in (d["queries"] as? [Any]) ?? [] {
            guard let qs = q as? String else { continue }
            let t = qs.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { queries.append(t) }
        }
        // tolerate {"action":"search","query":"…"}
        if let single = d["query"] as? String {
            let t = single.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { queries.append(t) }
        }
        if queries.isEmpty { return (.answer, false) }
        return (.search(Array(queries.prefix(plannerMaxQueriesPerRound))),
                false)
    }

    /// Repeat-detection normalization: case- and whitespace-insensitive.
    static func normalizePlannerQuery(_ q: String) -> String {
        q.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Bounded retrieval-agent loop (≤ plannerMaxRounds). Each round the
    /// model sees the question + compact evidence handles + tried queries
    /// and answers strict JSON: {"action":"search","queries":[≤3]} or
    /// {"action":"answer"}. Stops on "answer", the round cap, the wall
    /// `deadline`, two consecutive zero-growth rounds, a full pack, or a
    /// transport error — the caller then synthesizes over whatever
    /// evidence exists. Reuses the same `spawn` subprocess path as
    /// synthesis; the run semaphore is already held by `run`.
    static func planLoop(store: Store, acc: PackBuilder, query: String,
                         backend: ModelBackend, deadline: Date,
                         pathFilter: String?) -> PlannerReport {
        var rep = PlannerReport()
        var triedNorm: Set<String> = []
        var zeroNewStreak = 0
        var autoLeft = plannerAutoVariants(query, limit: 32)
        // The original question's atoms ride along on every planner
        // query's filename probe — the model's English variants drop
        // VN filename atoms ("đội hạm" → "doi"), which are exactly the
        // rare atoms that name the target file. Its cached translation
        // terms join too (lookup only — the probe never spawns the
        // model), so "nhật ký" reaches "log" even if the planner never
        // emits an English query.
        let baseAtoms = Search.plannerProbeAtoms(
            query: query,
            extraTerms: Translation.lexiconTerms(for: query)
                + (Translation.activeCache.get(
                    Translation.cacheKey(query)) ?? []))
        /// One shared query-execution step for model queries and
        /// deterministic auto-variants: normalize → dedupe → record →
        /// hybrid + filename probe → file-deduped into the pack.
        /// Returns items added.
        func runQuery(_ q: String, cap: Int = plannerPerQueryCap) -> Int {
            let norm = normalizePlannerQuery(q)
            // Drop literal placeholders a small model echoes from the
            // schema ("q1", "<key nouns>") — never executed, never
            // recorded as tried.
            guard norm.count >= 3, !norm.contains("<"),
                  triedNorm.insert(norm).inserted else {
                return 0
            }
            // Only record queries that actually execute — a
            // deadline-blocked query wasn't tried.
            guard deadline.timeIntervalSinceNow > 0.2 else { return 0 }
            rep.queriesTried.append(q)
            return (try? collectPlannerEvidence(
                store: store, acc: acc, query: q, cap: cap,
                pathFilter: pathFilter, probeAtoms: baseAtoms)) ?? 0
        }
        rounds: for round in 1...plannerMaxRounds {
            // A useful round needs at least a couple of seconds — with
            // <2s left the per-call timeout would kill the call anyway.
            let remain = deadline.timeIntervalSinceNow
            guard remain > 2 else { rep.stopped = "deadline"; break }
            rep.rounds = round
            // Deterministic probes lead each round — tail-first bigrams
            // reach VN-derived filenames the model keeps circling, and
            // their hits land in the prompt the model is about to see.
            var added = 0
            for _ in 0..<plannerAutoPerRound {
                guard let v = autoLeft.first else { break }
                autoLeft.removeFirst()
                added += runQuery(v, cap: plannerAutoPerQueryCap)
            }
            // A pack that can't grow (item cap or token ceiling) —
            // skip the model call entirely.
            if !acc.hasRoom {
                rep.evidenceGrowth.append(added)
                rep.stopped = "pack_full"
                break rounds
            }
            let prompt = buildPlannerPrompt(
                query: query, pack: acc.items,
                triedQueries: rep.queriesTried,
                nearby: siblingHints(store: store, pack: acc.items,
                                     query: query),
                round: round, maxRounds: plannerMaxRounds)
            // One retry on transport failure — a cold model load or a
            // wedged generation can burn a 20s call; a second attempt
            // still leaves the loop bounded by the same wall deadline
            // (the per-attempt timeout is recomputed from what remains).
            var out: String? = nil
            for attempt in 0...1 {
                let callTimeout = min(
                    plannerCallTimeoutSeconds,
                    max(1, Int(deadline.timeIntervalSinceNow.rounded(.up))))
                do {
                    out = try callModel(backend, prompt: prompt,
                                        timeout: callTimeout)
                    break
                } catch {
                    if attempt == 1
                        || deadline.timeIntervalSinceNow < 5 {
                        rep.stopped = "planner_error"
                    }
                }
            }
            guard let out else {
                if rep.stopped.isEmpty { rep.stopped = "deadline" }
                break
            }
            let decision = parsePlannerAction(out)
            if decision.malformed { rep.malformed += 1 }
            switch decision.action {
            case .answer:
                rep.evidenceGrowth.append(added)
                rep.stopped = "answer"
                break rounds
            case .search(let queries):
                for q in queries { added += runQuery(q) }
                rep.evidenceGrowth.append(added)
                zeroNewStreak = added == 0 ? zeroNewStreak + 1 : 0
                if zeroNewStreak >= 2 {
                    rep.stopped = "no_new_evidence"
                    break rounds
                }
                if !acc.hasRoom {
                    rep.stopped = "pack_full"
                    break rounds
                }
            }
        }
        if rep.stopped.isEmpty { rep.stopped = "round_cap" }
        return rep
    }

    // MARK: - Model backend (ollama | agent CLI)

    /// Synthesis backend. `ollama` = fully-offline local model (the auto
    /// fallback). `cli` = an agent CLI from the user's subscription fleet
    /// (agy, claude, codex, qwen, opencode, grok…) — the CLI's configured
    /// model synthesizes over the evidence pack; no cloud credits, no
    /// local 3B quality ceiling.
    public enum ModelBackend {
        case ollama(bin: String, model: String)
        case cli(bin: String, argvPrefix: [String])

        var label: String {
            switch self {
            case .ollama(_, let model): return "ollama:\(model)"
            case .cli(let bin, _): return "cli:\(bin)"
            }
        }
    }

    /// Non-interactive argv prefixes per known agent CLI — the evidence
    /// prompt is appended last. Flags mirror the fleet's dispatch table:
    /// skip-permissions/yolo so a text-only synthesis can't block on a
    /// tool-approval prompt.
    static let cliArgTemplates: [String: [String]] = [
        "agy": ["--dangerously-skip-permissions", "-p"],
        "claude": ["-p"],
        "codex": ["exec", "--skip-git-repo-check"],
        "qwen": ["--approval-mode", "yolo"],
        "opencode": ["run"],
        "grok": ["-p"],
        "gemini": ["-p"],
        "copilot": ["-p"],
        "cline": [],
    ]

    /// Fleet CLI probe order for `auto` — the subscription CLIs already
    /// paid for, best compose quality first.
    static let autoCLIOrder = ["agy", "codex", "claude"]
    /// `<cli> --version` probe budget: agent CLIs answer in well under a
    /// second when healthy; a CLI that can't do it in 2s is not a usable
    /// non-interactive compose path anyway.
    static let cliProbeTimeoutSeconds = 2

    /// backend spec: explicit arg > SWCTX_ANSWER_BACKEND >
    /// SWCTX_ANSWER_CLI > an explicit `ollamaBin` (that parameter exists
    /// only to configure the local backend — passing one pins it; the
    /// test seam) > "auto" — the DEFAULT. "auto" probes `autoCLIOrder`
    /// once per process and takes the first usable fleet CLI, else falls
    /// back to local ollama. It never routes to a paid service.
    /// Forms: "auto" | "ollama" | "cli" (binary via SWCTX_ANSWER_CLI,
    /// default "agy") | "cli:<bin>" | a bare CLI name ("codex", "agy"…).
    /// `auto` in the result flags that no explicit backend was chosen —
    /// the caller reports "no compose backend available" when even the
    /// fallback probe fails.
    static func resolveBackend(_ explicit: String?, model: String?,
                               ollamaBin: String?)
        -> (backend: ModelBackend, auto: Bool) {
        var spec = explicit ?? ""
        if spec.isEmpty {
            spec = ProcessInfo.processInfo.environment["SWCTX_ANSWER_BACKEND"] ?? ""
        }
        let envCLI = ProcessInfo.processInfo.environment["SWCTX_ANSWER_CLI"] ?? ""
        if spec.isEmpty && !envCLI.isEmpty { spec = "cli:\(envCLI)" }
        if spec.isEmpty, let ollamaBin, !ollamaBin.isEmpty {
            spec = "ollama"
        }
        if spec.isEmpty || spec == "auto" {
            if let cli = autoDetectCLI() { return (cli, true) }
            return (.ollama(bin: resolveBin(ollamaBin),
                            model: resolveModel(model)), true)
        }
        if spec == "ollama" {
            return (.ollama(bin: resolveBin(ollamaBin),
                            model: resolveModel(model)), false)
        }
        var name = spec
        if spec == "cli" { name = envCLI.isEmpty ? "agy" : envCLI }
        else if spec.hasPrefix("cli:") { name = String(spec.dropFirst(4)) }
        return (.cli(bin: name,
                     argvPrefix: cliArgTemplates[name] ?? []), false)
    }

    /// Once-per-process auto-probe result — `autoProbed` distinguishes
    /// "not probed yet" from "probed, no fleet CLI usable".
    nonisolated(unsafe) private static var autoProbed = false
    nonisolated(unsafe) private static var autoResult: ModelBackend? = nil

    /// `which <bin>`, in-process: PATH scan for an executable file — the
    /// first half of the probe costs zero subprocesses. `getenv` (not
    /// ProcessInfo) so the check reads the same live `environ` posix_spawnp
    /// will resolve against; a `bin` containing "/" is a literal path —
    /// spawnp skips PATH search for those too.
    static func cliOnPath(_ bin: String) -> Bool {
        if bin.contains("/") {
            return FileManager.default.isExecutableFile(atPath: bin)
        }
        let path = getenv("PATH").map { String(cString: $0) } ?? ""
        for dir in path.split(separator: ":") {
            if FileManager.default.isExecutableFile(
                atPath: "\(dir)/\(bin)") { return true }
        }
        return false
    }

    /// `<bin> --version` probe: PATH check first, then a bounded spawn
    /// (concurrent pipe drain, process-group kill — the `spawn`
    /// discipline). Success verdicts are cached in `preflightCache` so
    /// `backendAvailable` on the resolved backend doesn't pay a second
    /// subprocess; failures stay uncached so a later explicit
    /// `--backend cli:x` gets a fresh probe instead of inheriting a
    /// transient miss from the auto scan.
    static func cliProbe(_ bin: String, timeout: Int)
        -> (ok: Bool, detail: String) {
        guard cliOnPath(bin) else {
            return (false, "cli '\(bin)' not on PATH")
        }
        let key = "cli\u{1f}\(bin)"
        preflightLock.lock()
        if let c = preflightCache[key] {
            preflightLock.unlock()
            return c
        }
        preflightLock.unlock()
        var result: (Bool, String)
        do {
            _ = try spawn(bin, argv: ["--version"], timeout: timeout)
            result = (true, "ok")
        } catch {
            result = (false, "cli '\(bin)' unavailable: \(error.localizedDescription)")
        }
        if result.0 {
            preflightLock.lock()
            preflightCache[key] = result
            preflightLock.unlock()
        }
        return result
    }

    /// Default backend: probe `autoCLIOrder` once per process — first
    /// CLI answering `--version` within `cliProbeTimeoutSeconds` wins.
    /// nil = no usable fleet CLI (caller falls back to local ollama).
    static func autoDetectCLI() -> ModelBackend? {
        preflightLock.lock()
        if autoProbed {
            let r = autoResult
            preflightLock.unlock()
            return r
        }
        preflightLock.unlock()
        var found: ModelBackend? = nil
        for name in autoCLIOrder
            where cliProbe(name, timeout: cliProbeTimeoutSeconds).ok {
            found = .cli(bin: name, argvPrefix: cliArgTemplates[name] ?? [])
            break
        }
        preflightLock.lock()
        // Only a FOUND backend is pinned for the process — caching the
        // negative would pin ollama for the process's life just because
        // every CLI happened to be down or slow at first probe. A nil
        // verdict re-probes next call (PATH scans are ~free).
        if let found {
            autoProbed = true
            autoResult = found
        }
        preflightLock.unlock()
        return found
    }

    /// One probe per process: ollama checks binary+model via `list`; a
    /// CLI backend just needs the binary on PATH answering `--version`.
    static func backendAvailable(_ backend: ModelBackend)
        -> (ok: Bool, detail: String) {
        switch backend {
        case .ollama(let bin, let model):
            return ollamaAvailable(bin: bin, model: model)
        case .cli(let bin, _):
            return cliProbe(bin, timeout: 15)
        }
    }

    /// Prompt → raw model text for whichever backend is configured.
    static func callModel(_ backend: ModelBackend, prompt: String,
                          timeout: Int) throws -> String {
        switch backend {
        case .ollama(let bin, let model):
            // --nowordwrap: without it `ollama run` rewraps output at
            // ~50 cols, injecting literal \n inside JSON string values.
            return try spawn(bin, argv: [
                "run", model, "--format", "json",
                "--hidethinking", "--nowordwrap", prompt,
            ], timeout: timeout)
        case .cli(let bin, let argvPrefix):
            return try spawn(bin, argv: argvPrefix + [prompt],
                             timeout: timeout)
        }
    }

    // MARK: - Ollama subprocess

    /// Cached preflight verdict per (binary, model) — the plan requires
    /// one probe per process, not per call.
    private static let preflightLock = NSLock()
    nonisolated(unsafe) private static var preflightCache:
        [String: (ok: Bool, detail: String)] = [:]

    /// Test hook: clear the once-per-process preflight cache AND the
    /// auto-backend probe verdict.
    static func resetPreflightCache() {
        preflightLock.lock(); defer { preflightLock.unlock() }
        preflightCache.removeAll()
        autoProbed = false
        autoResult = nil
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
        // Drains and the waiter all run on dedicated Threads — a GCD
        // block can sit unscheduled under load, making the timeout fire
        // on queue latency (and SIGKILL a live group) or leaving pipe
        // bytes undrained past the grace bound.
        drain.enter()
        Thread {
            outData.append(out.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }.start()
        drain.enter()
        Thread {
            errData.append(err.fileHandleForReading.readDataToEndOfFile())
            drain.leave()
        }.start()
        let sem = DispatchSemaphore(value: 0)
        Thread {
            var st: Int32 = 0
            _ = waitpid(pid, &st, 0)
            wstatus.raw = st
            sem.signal()
        }.start()
        if sem.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            kill(-pid, SIGTERM)
            _ = sem.wait(timeout: .now() + .milliseconds(300))
            kill(-pid, SIGKILL)
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = drain.wait(timeout: .now() + .seconds(2))
            throw ToolError.invalidArg("\(bin) timed out after \(timeout)s")
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

    /// Line-number coercion for a citation's start_line/end_line field:
    /// JSON ints and integral doubles qualify; bools, strings, objects
    /// and fractional doubles → nil (a wrong-TYPE assertion — the caller
    /// marks the citation invalid rather than skipping the field).
    static func citationLineNumber(_ v: Any) -> Int? {
        guard let n = v as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: n)
    }

    /// Server-side validator: a citation counts ONLY when its evidence_id
    /// exists in the pack AND any path/line the model asserted matches the
    /// pack item verbatim — a model-invented path is invalid, never trusted.
    /// path/start_line/end_line stay OPTIONAL (the strict schema cites
    /// `evidence_id` only — an id-only citation is valid), but a field
    /// that IS present must carry the right JSON type: `start_line:"99"`
    /// or `path:{…}` is a malformed assertion — invalid, never silently
    /// skipped. An explicit JSON null reads as "not provided".
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
            var problem: String? = nil
            if let p = c["path"], !(p is NSNull) {
                if let s = p as? String {
                    if s != ev.path { problem = "path/line mismatch" }
                } else { problem = "path not a string" }
            }
            for (key, expected) in [("start_line", ev.startLine),
                                    ("end_line", ev.endLine)]
                where problem == nil {
                if let v = c[key], !(v is NSNull) {
                    if let i = citationLineNumber(v) {
                        if i != expected { problem = "path/line mismatch" }
                    } else { problem = "\(key) not a number" }
                }
            }
            if let problem {
                invalid.append("\(id) \(problem)"); continue
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

    /// Retrieve → (preflight) → [planner] → backend → validate → record.
    /// `backendSpec` nil/empty resolves "auto" — first usable fleet CLI
    /// (agy → codex → claude), else local ollama — and the resolved label
    /// ("cli:agy", "ollama:qwen2.5:3b"…) is recorded as `backend` in the
    /// response and durable record. Backend-side failures degrade to the
    /// deterministic pack + a structured `limitations` field ("no compose
    /// backend available" when auto finds nothing); only index/retrieval
    /// errors throw.
    /// `plan` inserts the bounded planner loop between the initial pack
    /// and synthesis (default off = current single-shot behavior);
    /// `planTimeout` is the planner's total wall deadline — on expiry the
    /// loop aborts and synthesis runs over whatever evidence exists.
    /// `expectedPath` is a harness oracle: echoed into the response and the
    /// durable record for scoring, NEVER into the prompt.
    public static func run(store: Store, query: String, model: String? = nil,
                           ollamaBin: String? = nil, timeout: Int = defaultTimeoutSeconds,
                           expectedPath: String? = nil, source: String = "mcp",
                           pathFilter: String? = nil, plan: Bool = false,
                           planTimeout: Int = defaultPlanTimeoutSeconds,
                           backendSpec: String? = nil) throws -> [String: Any] {
        let t0 = Date()
        let resolved = resolveBackend(backendSpec, model: model,
                                      ollamaBin: ollamaBin)
        let backend = resolved.backend
        // Records/reporting keep the bare model name for ollama
        // (back-compat); a CLI backend reports itself ("cli:agy").
        let modelID: String
        if case .cli = backend { modelID = backend.label }
        else { modelID = resolveModel(model) }
        let clampedTimeout = min(max(timeout, 5), 900)
        let clampedPlanTimeout = min(max(planTimeout, 5), 900)

        // Warm the translation cache for VN-diacritic questions — the
        // filename probe consumes it below; cold cache would leave
        // "nhật ký"→"log"-style atoms unreachable in standalone
        // `answer` calls. Bounded by Translation's own spawn cap and
        // cooldown; failure is silent (probes use raw atoms only).
        if Translation.needsTranslation(query) {
            _ = Translation.englishTerms(for: query)
        }
        let acc = PackBuilder(tokenBudget: defaultEvidenceTokens,
                              maxItems: 6 + 3)   // directMax + relatedMax
        // Plan mode seeds a smaller initial pack AND caps its tokens —
        // the planner iterates retrieval into the reserved headroom, so
        // the first pass can't saturate the pack (a few fat chunks would
        // otherwise spend the whole budget before a rescue query runs).
        if plan { acc.tokenCeiling = Self.planInitialTokenCeiling }
        try fillInitialPack(store: store, acc: acc, query: query,
                            pathFilter: pathFilter,
                            directMax: plan ? 4 : 6,
                            relatedMax: plan ? 1 : 3)
        var limitations: [String] = []
        if acc.truncated {
            limitations.append("evidence pack trimmed to token budget")
        }

        var answer: String? = nil
        var resolvedCitations: [[String: Any]] = []
        var invalidCitations: [String] = []
        var citationValid = false
        var attempts = 0
        var rawOutput: String? = nil
        var planner: PlannerReport? = plan ? PlannerReport() : nil

        // Preflight once — the planner and synthesis share the verdict.
        let pre = backendAvailable(backend)
        let ollamaOK = pre.ok
        if !pre.ok {
            if resolved.auto {
                // auto resolved nothing usable: say so plainly — the
                // caller must never suspect a silent paid-service route.
                limitations.append("no compose backend available — auto probed fleet CLIs (\(Self.autoCLIOrder.joined(separator: ", "))) then \(backend.label): \(pre.detail) — deterministic evidence pack only")
            } else {
                limitations.append("\(backend.label) unavailable — deterministic evidence pack only (\(pre.detail))")
            }
            planner?.stopped = "ollama_unavailable"
        }

        // One 3B-class local run at a time — held across planner rounds
        // AND synthesis so a concurrent caller degrades instead of
        // double-loading the model.
        var heldSemaphore = false
        if pre.ok && (plan || !acc.items.isEmpty) {
            let waitBudget = DispatchTime.now()
                + .seconds(clampedTimeout * 2 + 30
                           + (plan ? clampedPlanTimeout : 0))
            guard runSemaphore.wait(timeout: waitBudget) == .success else {
                limitations.append("another answer run held the local model semaphore")
                planner?.stopped = "semaphore_busy"
                return finish(store: store, query: query, model: modelID,
                              backend: backend.label,
                              pack: acc.items, packTruncated: acc.truncated,
                              answer: nil, resolved: [], invalid: [],
                              citationValid: false, attempts: 0,
                              ollamaOK: true, rawOutput: nil,
                              limitations: limitations, expectedPath: expectedPath,
                              source: source, t0: t0, planner: planner)
            }
            heldSemaphore = true
        }
        defer { if heldSemaphore { runSemaphore.signal() } }

        // Bounded planner loop: iterate retrieval (VN+EN query variants,
        // identifier guesses) before answering — the rescue path for
        // retrieval misses the initial pack couldn't reach.
        if plan, pre.ok {
            acc.maxItems = plannerMaxEvidence
            acc.tokenCeiling = acc.tokenBudget   // planner phase gets the rest
            planner = planLoop(store: store, acc: acc, query: query,
                               backend: backend,
                               deadline: t0.addingTimeInterval(
                                   TimeInterval(clampedPlanTimeout)),
                               pathFilter: pathFilter)
        }
        let pack = acc.items

        if pack.isEmpty {
            limitations.append("no evidence retrieved for query")
        } else if pre.ok {
            // The LAST successfully parsed attempt wins — a failed retry
            // keeps the earlier parse rather than throwing the answer away.
            var modelLimitations = ""
            for attempt in 1...2 {
                attempts = attempt
                let prompt = buildPrompt(query: query, evidence: pack,
                                         retry: attempt == 2)
                do {
                    let out = try callModel(backend, prompt: prompt,
                                            timeout: clampedTimeout)
                    rawOutput = stripANSI(out)
                    if let parsed = parseAnswer(out) {
                        answer = parsed.answer
                        modelLimitations = parsed.limitations
                        let v = validateCitations(parsed.citations, pack: pack)
                        resolvedCitations = v.resolved
                        invalidCitations = v.invalid
                        citationValid = v.valid
                        // Invalid citations spend the same single retry a
                        // malformed reply gets — attempt 2's result then
                        // stands, valid or not.
                        if v.valid || attempt == 2 { break }
                    } else if attempt == 2 {
                        // malformed → exactly one format-retry
                        limitations.append("model output was not the required JSON after 1 format-retry")
                    }
                } catch {
                    limitations.append("\(backend.label) call failed: \(error.localizedDescription)")
                    break   // transport errors never retry
                }
            }
            if !modelLimitations.isEmpty {
                limitations.append(modelLimitations)
            }
            if !invalidCitations.isEmpty {
                limitations.append("\(invalidCitations.count) citation(s) rejected: "
                    + invalidCitations.joined(separator: "; "))
                if answer != nil && !citationValid && attempts == 2 {
                    limitations.append("citations still invalid after 1 retry")
                }
            }
            if answer != nil, resolvedCitations.isEmpty, invalidCitations.isEmpty {
                limitations.append("model returned no usable citations")
            }
        }

        return finish(store: store, query: query, model: modelID,
                      backend: backend.label, pack: pack,
                      packTruncated: acc.truncated, answer: answer,
                      resolved: resolvedCitations, invalid: invalidCitations,
                      citationValid: citationValid, attempts: attempts,
                      ollamaOK: ollamaOK, rawOutput: answer == nil ? rawOutput : nil,
                      limitations: limitations, expectedPath: expectedPath,
                      source: source, t0: t0, planner: planner)
    }

    /// Assemble the response dict + write the durable `kind=ask` record.
    /// The record write is `try?` — a ledger failure must never lose the
    /// answer (plan F5).
    static func finish(store: Store, query: String, model: String,
                       backend: String,
                       pack: [Evidence], packTruncated: Bool,
                       answer: String?, resolved: [[String: Any]],
                       invalid: [String], citationValid: Bool,
                       attempts: Int, ollamaOK: Bool, rawOutput: String?,
                       limitations: [String], expectedPath: String?,
                       source: String, t0: Date,
                       planner: PlannerReport? = nil) -> [String: Any] {
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
            "query": query, "model": model, "backend": backend,
            "prompt_version": promptVersion,
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
        if let planner {
            resp["planner"] = [
                "rounds": planner.rounds,
                "queries_tried": planner.queriesTried,
                "evidence_growth": planner.evidenceGrowth,
                "stopped": planner.stopped,
                "malformed": planner.malformed,
            ] as [String: Any]
        }

        // Durable record — same ledger path as contextPack/putRecord:
        // staleness evidence (HEAD + resolving anchors) included.
        var payload: [String: Any] = [
            "query": query, "model": model, "backend": backend,
            "prompt_version": promptVersion,
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
        if let planner {
            payload["planner_rounds"] = planner.rounds
            payload["queries_tried"] = planner.queriesTried
            payload["evidence_growth"] = planner.evidenceGrowth
            payload["planner_stopped"] = planner.stopped
            if planner.malformed > 0 {
                payload["planner_malformed"] = planner.malformed
            }
        }
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
