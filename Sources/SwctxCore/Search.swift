import Accelerate
import Foundation
import GRDB

public struct SearchHit: Sendable {
    public var chunkID: Int64
    public var path: String
    public var startLine: Int
    public var endLine: Int
    public var kind: String?
    public var symbol: String?
    public var score: Double
    public var snippet: String
}

public enum Search {
    /// Build a safe FTS5 MATCH query: OR of quoted tokens with prefix
    /// matching, plus morphology/acronym variants. `"compare"*` alone
    /// never reaches "comparison" and "google apps script" never names
    /// gas.ts — the extra OR terms cost nothing per-query (one MATCH,
    /// wider vocabulary) and OR'd tail terms can't outrank real hits.
    static func ftsQuery(_ raw: String) -> String? {
        var tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        // Function words are OR-noise that floods the window with docs
        // matching only "của"/"the" — drop them BEFORE the 12-token cap
        // so content terms further right still reach the query
        // ("…ba mươi giờ không cập nhật thì báo telegram": "telegram"
        // was token 13, previously cut).
        let content = tokens.filter {
            let f = foldText($0)
            return !vnStopwords.contains(f) && !enStopwords.contains(f)
        }
        if !content.isEmpty { tokens = content }
        guard !tokens.isEmpty else { return nil }
        let prim = Array(tokens.prefix(12))
        var clauses = prim.map { "\"\($0)\"*" }
        var seen = Set(prim.map { $0.lowercased() })
        var variants = 0
        for t in prim where variants < 10 {
            let l = t.lowercased()
            for v in [singularAtom(l), stemAtom(l)].compactMap({ $0 })
            where variants < 10 && seen.insert(v).inserted {
                clauses.append("\"\(v)\"*")
                variants += 1
            }
        }
        // Acronyms scope to path_tokens: initials are filename-shaped
        // evidence ("google apps script" → gas.ts), not content terms.
        for ac in acronymAtoms(prim.map { $0.lowercased() }).prefix(6)
        where !seen.contains(ac) {
            clauses.append("path_tokens : \"\(ac)\"*")
        }
        return clauses.joined(separator: " OR ")
    }

    /// Test-path heuristic shared by the probe demotion and the fused
    /// post-hoc penalty: test files share the subject's vocabulary but
    /// are rarely the answer to a NL query.
    static func isTestLikePath(_ lp: String) -> Bool {
        lp.hasPrefix("tests/") || lp.hasPrefix("test/")
            || lp.hasPrefix("__tests__/")
            || lp.contains("/tests/") || lp.contains("/test/")
            || lp.contains("/__tests__/")
            || lp.contains(".test.") || lp.contains(".spec.")
            || lp.contains("_test.")
            || lp.lowercased().contains(".mock.")
            || (lp as NSString).lastPathComponent.lowercased()
                .hasPrefix("test-")
            || (lp as NSString).lastPathComponent.lowercased()
                .hasPrefix("test_")
    }

    /// Query tokens whose diacritic fold differs ("chấm" → "cham",
    /// "công" → "cong"). unicode61 folds case but never folds đ (U+0111),
    /// so Vietnamese needs these app-level variants.
    static func foldedVariantTokens(_ raw: String) -> [String] {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        var out: [String] = []
        var seen: Set<String> = []
        for t in tokens.prefix(12) {
            let f = foldText(t)
            if f != t.lowercased(), f.count >= 2, seen.insert(f).inserted {
                out.append(f)
            }
        }
        return out
    }

    /// Folded-only variant query scoped to the `folded` column — one term
    /// per diacritic-differing token. Column-scoped on purpose: folded
    /// matches score only through the cheap folded column and the leg is
    /// used strictly as a tail-filler after real hits — extra candidates
    /// in the shared window measurably displace borderline real hits.
    static func ftsFoldedQuery(_ raw: String) -> String? {
        let terms = foldedVariantTokens(raw).map { "folded : \"\($0)\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// Folded adjacent-token PHRASES on path_tokens: "chấm công"
    /// probes path_tokens : "cham cong" — matching folded snake_case
    /// filenames like cham_cong.py. Phrases are far more discriminating
    /// than term-OR probes: term-level folded matches flooded windows
    /// with common VN path tokens on every earlier attempt, while a
    /// phrase on the 2.5-weighted path column gives filename intent a
    /// real score without touching the fts window.
    static func foldedPhraseQuery(_ raw: String) -> String? {
        let toks = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        var terms: [String] = []
        var seen: Set<String> = []
        for pair in zip(toks, toks.dropFirst()) {
            guard terms.count < 16 else { break }
            let f = foldText(pair.0 + " " + pair.1)
            if f != (pair.0 + " " + pair.1).lowercased(),
               f.count >= 3, seen.insert(f).inserted {
                terms.append("path_tokens : \"\(f)\"")
            }
        }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// FTS5 MATCH for translated english_terms (W11): each term's alnum
    /// atoms OR'd with prefix matching across all bm25-weighted columns,
    /// plus adjacent-atom phrases scoped to path_tokens — "image worker"
    /// reaches p8_image_worker.py-style filenames, the same filename-intent
    /// trick as the folded-phrase leg. Terms arrive pre-validated
    /// (alnum/space/hyphen only), so the quoted atoms are safe.
    static func ftsTranslatedQuery(_ terms: [String]) -> String? {
        var clauses: [String] = []
        var seen: Set<String> = []
        var atoms = 0
        for t in terms.prefix(8) {
            let toks = t.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 && !enStopwords.contains($0) }
            for tok in toks where atoms < 20 && seen.insert(tok).inserted {
                clauses.append("\"\(tok)\"*")
                atoms += 1
                // Light singularization: translated terms arrive as natural
                // English plurals ("links", "activities") but path atoms are
                // snake_case stems ("link"). FTS5 prefix match can't strip
                // suffixes, so offer the stripped form as an extra atom.
                if tok.count >= 4, let sing = singularAtom(tok),
                   seen.insert(sing).inserted {
                    clauses.append("\"\(sing)\"*")
                }
            }
            for pair in zip(toks, toks.dropFirst())
            where seen.insert("p:\(pair.0) \(pair.1)").inserted {
                clauses.append("path_tokens : \"\(pair.0) \(pair.1)\"")
            }
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " OR ")
    }

    /// Singular form of an English atom for FTS — "activities"→"activity",
    /// "links"→"link". The atom is always used with `*` prefix matching, so
    /// an over-stripped stem is harmless ("statu"* still reaches status) —
    /// only "ies"→"y" needs real plural handling.
    static func singularAtom(_ tok: String) -> String? {
        if tok.hasSuffix("ies"), tok.count >= 5 {
            return String(tok.dropLast(3)) + "y"
        }
        if tok.hasSuffix("s"), !tok.hasSuffix("ss"), tok.count >= 4 {
            return String(tok.dropLast(1))
        }
        return nil
    }

    /// Derivational suffixes, longest-first: the first matching suffix
    /// wins, so "ational" must precede "ation"/"al" and "ities" before
    /// "ies"/"s".
    static let stemSuffixes = [
        "ational", "ation", "ition", "tion", "sion", "ison",
        "ments", "ment", "ities", "ity", "ness",
        "ings", "ing", "ied", "ies",
        "ful", "ous", "ive", "ize", "ise", "ely",
        "ers", "ors", "es", "ed", "ly", "al", "ic", "er", "or",
        "e", "s", "y",
    ]

    /// Light derivational stem — ONE suffix-strip pass. FTS5 prefix
    /// `"x"*` requires the query atom to be a PREFIX of the indexed
    /// token, so "compare" never reaches "comparison" (they diverge at
    /// char 7). "compare"→"compar" and "comparison"→"compar" share the
    /// stem, so `compar*` covers the whole morphology family at once;
    /// over-stripped stems stay harmless under prefix matching.
    static func stemAtom(_ tok: String) -> String? {
        guard tok.count >= 5 else { return nil }
        for suf in stemSuffixes
        where tok.hasSuffix(suf) && tok.count - suf.count >= 3 {
            return String(tok.dropLast(suf.count))
        }
        return nil
    }

    /// Acronym atoms — initials of consecutive-word windows, len 3-4:
    /// "google apps script" → "gas" reaches gas.ts/GAS_PROTOCOL-style
    /// paths the words themselves never name. Generated blind (no corpus
    /// lookup); consumers gate on existence — the path probe's DF filter
    /// drops atoms that name nothing, and bare OR clauses just never
    /// match. Windows keep raw token order; ≥2-char members only.
    static func acronymAtoms(_ tokens: [String]) -> [String] {
        let words = tokens.filter { $0.count >= 2 }
        var out: [String] = []
        var seen: Set<String> = []
        for w in [3, 4] where words.count >= w {
            for i in 0...(words.count - w) {
                let ac = words[i..<(i + w)].map { $0.prefix(1) }.joined()
                if ac.allSatisfy({ $0.isLetter }), seen.insert(ac).inserted {
                    out.append(ac)
                }
            }
        }
        return out
    }

    /// The translation leg's FTS half: translated terms through
    /// `ftsTranslatedQuery`, then file-deduped and capped at 5 — a
    /// translation match is a file-level signal, same contract as the
    /// folded-phrase leg. Filename intent leads: a path_tokens-scoped atom
    /// pass runs before the full-column pass because generic terms
    /// ("user", "data") flood content matches and would bury a filename
    /// hit like log_activity_live.py (observed at raw rank 15+).
    static func translatedLegHits(store: Store, terms: [String],
                                  pathFilter: String? = nil) throws -> [SearchHit] {
        guard let match = ftsTranslatedQuery(terms) else { return [] }
        var pathAtoms = ftsTranslatedAtoms(terms)
        if pathAtoms.count > 8 { pathAtoms = Array(pathAtoms.prefix(8)) }
        var raw: [SearchHit] = []
        if !pathAtoms.isEmpty {
            let pathMatch = "path_tokens : ("
                + pathAtoms.map { "\"\($0)\"*" }.joined(separator: " OR ") + ")"
            raw += try ftsRun(store: store, match: pathMatch, limit: 10,
                              pathFilter: pathFilter)
        }
        raw += try ftsRun(store: store, match: match, limit: 20,
                          pathFilter: pathFilter)
        var seenFiles: Set<String> = []
        var out: [SearchHit] = []
        for h in raw where seenFiles.insert(h.path).inserted {
            out.append(h)
            if out.count == 5 { break }
        }
        return out
    }

    /// Deduplicated atom list for the path-scoped pass — same atomization
    /// and singularization as `ftsTranslatedQuery`, without the clauses.
    static func ftsTranslatedAtoms(_ terms: [String]) -> [String] {
        var atoms: [String] = []
        var seen: Set<String> = []
        for t in terms.prefix(12) {
            for tok in t.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter({ $0.count >= 2 }) where seen.insert(tok).inserted {
                atoms.append(tok)
                if tok.count >= 4, let sing = singularAtom(tok),
                   seen.insert(sing).inserted {
                    atoms.append(sing)
                }
            }
        }
        return atoms
    }

    /// Vietnamese function words — folded forms. They add atoms that
    /// only ever match junk ("dang" → định-dạng slugs) while crowding
    /// real atoms out of the probe cap. Grammatical words only; a
    /// content word never belongs here even if it is usually noise.
    static let vnStopwords: Set<String> = [
        "cac", "con", "dang", "trong", "that", "roi", "kem", "cho",
        "voi", "cua", "mot", "nhung", "khi", "nhu", "van", "chi",
        "toi", "theo", "den", "ra", "vao", "len", "tren", "duoi",
        "giua", "ngoai", "vay", "thi", "ma", "la", "va", "hoac",
        "hay", "neu", "vi", "boi", "do", "da", "se", "rat", "qua",
        "lam", "nen", "cung", "deu", "moi", "tung", "bi", "co",
        "khong", "duoc", "nay", "kia", "day", "gi", "ai", "thu",
    ]

    /// English function words — same role as `vnStopwords` for the fts
    /// lane. Kept separate so probe-atom callers that want VN-only
    /// filtering keep their current contract.
    static let enStopwords: Set<String> = [
        "the", "an", "of", "to", "in", "for", "on", "at", "by", "with",
        "from", "into", "and", "or", "but", "is", "are", "was", "were",
        "be", "been", "it", "its", "that", "this", "one", "when", "while",
        "as", "do", "does", "over", "under", "inside",
    ]

    /// Atom pool for the planner filename probe: extra terms FIRST —
    /// they are the curated rescue vocabulary (VN lexicon, cached
    /// translations) added precisely because the raw query lacks them —
    /// then the query's own folded atoms minus stopwords ("đội hạm" →
    /// "doi ham"). Same atomization/singularization as the translation
    /// leg; ≥3 chars — 2-char prefixes match half the corpus. Cap 24:
    /// a dense VN question plus lexicon terms needs the headroom.
    static func plannerProbeAtoms(query: String,
                                  extraTerms: [String] = []) -> [String] {
        plannerProbeAtomSets(query: query, extraTerms: extraTerms).atoms
    }

    /// Probe atoms plus privilege tiers. Two derived classes join the
    /// query's own atoms:
    /// - acronym atoms ("google apps script" → "gas"): probe + claim +
    ///   champion, but NO sole-carrier/surgical — an acronym prefix is
    ///   coincidence-prone ("rat" ← "run and track" hits "rating"), so
    ///   they rescue below-bar names but never crown a file surgical.
    /// - derivational stems ("compare" → "compar"): probe + claim only
    ///   — no surgical and no champion; a stem match is supporting
    ///   evidence, not a name.
    /// - model-guessed filename terms ("sổ tay" → "so_tay","digest"):
    ///   the reformulation leg. Same privilege as acronyms — a guessed
    ///   token that names a file IS name evidence (champion-eligible)
    ///   but never surgical: a model hallucination must not crown.
    /// Stems precede acronyms in emission order: stems are ~1 per real
    /// atom while acronym windows grow ~2× tokens — acronym-first order
    /// pushed every stem past the 24-cap on dense queries.
    static func plannerProbeAtomSets(query: String,
                                     extraTerms: [String] = [],
                                     guessedTerms: [String] = [])
        -> (atoms: [String], weak: Set<String>, championless: Set<String>) {
        var out: [String] = []
        var weak: Set<String> = []
        var championless: Set<String> = []
        var seen: Set<String> = []
        for a in ftsTranslatedAtoms(extraTerms)
                + ftsTranslatedAtoms([foldText(query)])
                    .filter({ !vnStopwords.contains($0) })
        where a.count >= 3 && seen.insert(a).inserted {
            out.append(a)
        }
        // Base atoms close here — stems derive from real query terms
        // only, not model guesses (stemming a guess compounds noise).
        let baseAtoms = Array(out)
        for a in ftsTranslatedAtoms(guessedTerms)
        where a.count >= 3 && seen.insert(a).inserted {
            out.append(a)
            weak.insert(a)
            // Model guesses fetch+claim only — never a champion slot:
            // "workflow" lands in nearly every roll, and a championed
            // guess buries fused hits on untuned queries (holdout).
            championless.insert(a)
        }
        let qToks = foldText(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !vnStopwords.contains($0) }
        for a in baseAtoms {
            if let s = stemAtom(a), s.count >= 3, seen.insert(s).inserted {
                out.append(s)
                weak.insert(s)
                championless.insert(s)
            }
        }
        // Subword candidates for long glued tokens: "serpupdate" never
        // matches path token "serp" (prefix match is one-directional),
        // so a compound query word can hide a file literally named by
        // its head ("nap_serp.py"). Emit len 4-7 prefixes/suffixes of
        // tokens len>=8 — the path-DF oracle self-filters candidates
        // that name nothing. Same tier as stems: fetch + claim only.
        // Emitted before acronyms: a subword that survives path-DF names
        // a real file, while acronym initials are coincidence-prone and
        // their ~2×token window count would consume the 24-cap first.
        for t in qToks where t.count >= 8 {
            for len in 4...min(7, t.count - 1) {
                for cand in [String(t.prefix(len)), String(t.suffix(len))]
                where seen.insert(cand).inserted {
                    out.append(cand)
                    weak.insert(cand)
                    championless.insert(cand)
                }
            }
        }
        for ac in acronymAtoms(qToks)
        where ac.count >= 3 && seen.insert(ac).inserted {
            out.append(ac)
            weak.insert(ac)
        }
        return (Array(out.prefix(24)), weak, championless)
    }

    /// Planner filename probe. A multi-term query lets one common atom
    /// flood the fused ranking ("seo brain" buried p8_brain.py past the
    /// pack cutoff), so each atom whose PATH-match file count is low
    /// gets a solo pass on path_tokens — inside a shared OR window a
    /// popular atom's rows crowd the rare atom's out entirely. The solo
    /// pass ANDs the path anchor with an OR over the three atoms that
    /// are rarest in CONTENT — path names the file, folded content
    /// still has to speak the question's language:
    /// `path_tokens:"doi"* AND folded:(ham OR liet OR worker)` reaches
    /// doi-ngu.md while "chuyển đổi số" manifest reports (also "doi")
    /// lack all three. Bare path probe is the fallback when the AND
    /// comes up empty. File-deduped, ranked by distinct path coverage.
    /// Env-tunable probe knobs — `bench/optimize.py` sweeps these; the
    /// defaults are the measured winners, envs exist for bench sweeps
    /// only (same contract as SWCTX_RRF_W / SWCTX_XLATE_W).
    static func envInt(_ name: String, _ def: Int) -> Int {
        ProcessInfo.processInfo.environment[name]
            .flatMap(Int.init) ?? def
    }
    static func envDouble(_ name: String, _ def: Double) -> Double {
        ProcessInfo.processInfo.environment[name]
            .flatMap(Double.init) ?? def
    }

    /// Result of `plannerPathProbe`: emitted hits plus the count of
    /// trailing below-bar champions. Emit order is strong-first —
    /// `scored` sorts surgical then rank-descending, so every emitted
    /// hit with rank ≥ bar precedes all below-bar champions; the dir/
    /// basename caps preserve that relative order. Callers that merge
    /// probe hits into a fused window use `strongCount` to give weak
    /// champions tail slots instead of the head.
    struct ProbeResult {
        var hits: [SearchHit]
        var belowBarCount: Int
        /// Emitted hits with name evidence AND coverage confidence —
        /// surgical (sole-carrier stem) at or above the rank bar. Zero
        /// means the probe could only fetch coverage-flood hits or weak
        /// name guesses: the round-2 reformulation trigger.
        var confidentCount: Int
        /// Like confidentCount but only counts hits whose surgical
        /// carrier atom is DETERMINISTIC (query/lexicon/derived — no
        /// cache- or model-fed vocabulary). Gates that decide whether a
        /// model leg runs must use this: a cache-warmth-dependent gate
        /// flips eligibility between runs on the same query.
        var detConfident: Int = 0
        /// Co-occurrence-mined sibling atoms (corpus naming convention:
        /// "cloudflare" co-names p8_cloudflare_purge.py → "purge").
        /// Rescue vocabulary only — feeding them through the probe's
        /// fetch lane lets archive floods reach the strong head.
        var expansionAtoms: [String] = []
        var strongCount: Int { hits.count - belowBarCount }
        var champions: ArraySlice<SearchHit> { hits.dropFirst(strongCount) }
        static let empty = ProbeResult(hits: [], belowBarCount: 0,
                                       confidentCount: 0)
    }

    /// Merge probe hits into a fused result window. Strong probe hits
    /// (surgical or rank ≥ bar) lead up to `cap`; below-bar champions
    /// are name-guess tail coverage — at most `champPrepend` lead, the
    /// rest append after the fused hits. When the emitted set is all
    /// champions at the flood line (default: the prepend cap itself —
    /// a champion set that could fill the whole window means generic
    /// name fodder), no champion leads at all (crm-02: six below-bar
    /// champions buried the fused rank-5 answer).
    static func mergeProbeHits(_ hits: [SearchHit],
                               probe: ProbeResult,
                               cap: Int = 6,
                               champPrepend: Int = 1,
                               flood: Int = 6) -> [SearchHit] {
        guard !probe.hits.isEmpty else { return hits }
        var prepend = champPrepend
        if probe.strongCount == 0 && probe.belowBarCount >= flood {
            prepend = 0
        }
        let probePaths = Set(probe.hits.map(\.path))
        return Array(probe.hits.prefix(min(cap, probe.strongCount)))
            + Array(probe.champions.prefix(prepend))
            + hits.filter { !probePaths.contains($0.path) }
            + Array(probe.champions.dropFirst(prepend))
    }

    /// Single-slot tail rescue. A rescue candidate may take at most ONE
    /// slot and only from a fused occupant whose basename shares no
    /// token with the deterministic query atoms — a file fusion never
    /// name-justified. The protected prefix (default 2) is never
    /// touched; a fully name-corroborated window admits nothing. This
    /// replaces champion-prepend: on untuned queries a plausible-but-
    /// wrong champion (package.json via "package", trang.html via
    /// "trang") was evicting fused gold.
    static func tailRescue(_ hits: [SearchHit],
                           candidates: [SearchHit],
                           verifiedPaths: Set<String> = [],
                           stemExPaths: Set<String> = [],
                           matchCount: [String: Int] = [:],
                           queryNameAtoms: Set<String>,
                           limit: Int, protect: Int = 2) -> [SearchHit] {
        guard !candidates.isEmpty else { return hits }
        let have = Set(hits.map(\.path))
        // A candidate whose basename the window already shows adds no
        // name evidence — a second entity.json in another directory is
        // the same name. Eligibility requires a NEW basename as well
        // as a new path.
        let windowBases = Set(hits.map {
            ($0.path as NSString).lastPathComponent })
        func eligible(_ h: SearchHit) -> Bool {
            !have.contains(h.path)
                && !windowBases.contains(
                    (h.path as NSString).lastPathComponent)
        }
        var out = hits
        if out.count < limit {
            if let r = candidates.first(where: eligible) {
                out.append(r)
            }
            return out
        }
        if ProcessInfo.processInfo.environment["SWCTX_PROBE_DEBUG"] == "1" {
            FileHandle.standardError.write(
                ("rescue: cands=\(candidates.map(\.path)) "
                    + "verified=\(verifiedPaths) "
                    + "occ=\(out.map { ($0.path as NSString).lastPathComponent })\n")
                    .data(using: .utf8)!)
        }
        func uncorroborated(_ path: String) -> Bool {
            let base = (path as NSString).lastPathComponent
            // Fusion name-justified this hit via the INDEX's tokens,
            // which camel-split (RankStore → rank, store). Speak the
            // same language — split on case FIRST, then fold — or every
            // camelCase occupant looks unjustified and becomes
            // evictable.
            var toks = Set(base.split(
                omittingEmptySubsequences: true,
                whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() })
            for t in base.split(
                omittingEmptySubsequences: true,
                whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                toks.formUnion(symbolTokens(String(t)))
            }
            return toks.isDisjoint(with: queryNameAtoms)
        }
        // Pass 1: the best candidate may take the weakest slot whose
        // occupant fusion never name-justified. Verified evidence wins
        // over unverified guesses when both compete for the slot —
        // ordered by matched-atom coverage so a two-concept name beats
        // a single translated word.
        let byEvidence: (SearchHit, SearchHit) -> Bool = { a, b in
            let ca = matchCount[a.path] ?? 0, cb = matchCount[b.path] ?? 0
            if ca != cb { return ca > cb }
            let sa = stemExPaths.contains(a.path),
                sb = stemExPaths.contains(b.path)
            if sa != sb { return sa }
            return a.path < b.path
        }
        for i in stride(from: limit - 1, through: protect, by: -1)
        where uncorroborated(out[i].path) {
            let r = candidates.filter({
                eligible($0) && verifiedPaths.contains($0.path)
            }).sorted(by: byEvidence).first
                ?? candidates.first(where: eligible)
            guard let r else { return out }
            out[i] = r
            return out
        }
        // Pass 2: every tail occupant is name-justified — only a
        // CONTENT-VERIFIED candidate may still displace, and only the
        // weakest slot. Order by matched-atom coverage first: a file
        // named by TWO of the query's concepts (p8_cloudflare_purge ←
        // cloudflare+purge) is a better answer than a single-atom
        // stem hit (WORKFLOW.md ← one translated word); stem-equality
        // and pool order break ties.
        let verified = candidates.filter {
            eligible($0) && verifiedPaths.contains($0.path)
        }
        guard let r = verified.sorted(by: byEvidence).first else {
            if ProcessInfo.processInfo.environment["SWCTX_PROBE_DEBUG"] == "1" {
                FileHandle.standardError.write(
                    ("rescue p2: none eligible+verified of "
                        + "\(candidates.count) cands; verified=\(verifiedPaths)\n")
                        .data(using: .utf8)!)
            }
            return out
        }
        out[limit - 1] = r
        return out
    }

    static func plannerPathProbe(store: Store, atoms: [String],
                                 weakAtoms: Set<String> = [],
                                 championlessAtoms: Set<String> = [],
                                 detAtoms: Set<String> = [],
                                 pathFilter: String? = nil,
                                 rareMaxFiles: Int = 60,
                                 midMaxFiles: Int = 200,
                                 limit: Int = 10) throws -> ProbeResult {
        let rareMaxFiles = envInt("SWCTX_PROBE_RARE", rareMaxFiles)
        let midMaxFiles = envInt("SWCTX_PROBE_MID", midMaxFiles)
        guard !atoms.isEmpty else { return .empty }
        func fileCount(_ match: String) -> Int {
            (try? store.pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT c.file_id) FROM chunks_fts
                    JOIN chunks c ON c.id = chunks_fts.rowid
                    WHERE chunks_fts MATCH ?
                    """, arguments: [match])
            }) ?? 0
        }
        // DF counting is 2×|atoms| independent read-only round-trips —
        // the probe's dominant cost on dense queries (~48 sequential
        // COUNTs ≈ 100ms+ tail). DatabasePool readers run concurrently
        // under WAL, so path-DF and content-DF fan out together.
        var pathDFMutable: [String: Int] = [:]
        var contentDFMutable: [String: Int] = [:]
        let dfLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: atoms.count) { i in
            let a = atoms[i]
            let p = fileCount("path_tokens : \"\(a)\"*")
            let c = fileCount("folded : \"\(a)\"*")
            dfLock.lock()
            pathDFMutable[a] = p
            contentDFMutable[a] = c
            dfLock.unlock()
        }
        let pathDF = pathDFMutable
        let contentDF = contentDFMutable
        // Sole-carrier rarity is only meaningful against a corpus where
        // uniqueness surprises. On a ~120-file index nearly every path
        // token is DF=1, so "surgical" would crown random names — gate
        // the bonus on corpus size. Swept on all 3 manifests (optimize.
        // py): 150 separates CRM (~120 files, surgical=junk) from
        // linkeldn (186 files, surgical=p8-style DF1 names) — 57/70 vs
        // 56/70 at 500, zero per-query regressions.
        let corpusFiles = (try? store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
        }) ?? 0
        let rarityMatters = corpusFiles >= envInt("SWCTX_PROBE_CORPUS", 150)
        // Two tiers: RARE atoms (≤rareMaxFiles files) get the AND-folded
        // probe plus a bare path fallback; MID atoms (≤midMaxFiles) get
        // the AND-folded probe ONLY — a bare "apply" probe returns 84
        // files, but `apply* AND folded:(suggest|internal|link)` isolates
        // ghost_link_builder_apply.py because the content must still
        // speak the question's language. HIGH-DF atoms (>midMax, e.g.
        // "link" at 218) still probe AND-folded — the content fold IS
        // the flood control; `link* AND folded:(404|broken)` reaches
        // p8_link_health.py where the bare gate dropped the atom.
        let probed = atoms.filter { (pathDF[$0] ?? 0) > 0 }
        guard !probed.isEmpty else { return .empty }
        // Content-DF orders the folded-AND discriminators — an atom rare
        // in paths but common in prose ("dang", "trang") narrows nothing.
        // (Counted in the parallel DF pass above.)
        // Results merge in ATOM ORDER, not completion order: `seenFiles`
        // keeps the first-seen chunk per path and the final tiebreak is
        // hit.score — concurrent append order made marginal hits flaky
        // (BriefAudience dropped at random between bench runs).
        var perAtom: [[SearchHit]?] = Array(repeating: nil, count: probed.count)
        var firstFetchError: Error?
        let fetchLock = NSLock()
        // Each probed atom's AND-folded fetch is independent; ~20 of
        // them sequential was the other half of the probe tail.
        DispatchQueue.concurrentPerform(iterations: probed.count) { i in
            let a = probed[i]
            // Discriminators must be atoms the target plausibly
            // CONTAINS, not merely rare ones: lowest content-DF picks
            // words absent from every file ("illustrate"), which ANDs
            // the target away. Blend 3 rarest + 2 most common — the
            // common atoms ("link", "internal") are what the target's
            // content actually speaks.
            let others = atoms.filter { $0 != a }
                .sorted { (contentDF[$0] ?? 0) != (contentDF[$1] ?? 0)
                    ? (contentDF[$0] ?? 0) < (contentDF[$1] ?? 0)
                    : $0 < $1 }
            // Anchors past the rare band need RARE-ONLY
            // discriminators — common atoms in the OR (file, data)
            // match every path a DF-42 anchor names, so the 20-row
            // cap fills on bm25 before sitectl.py:
            // `site* AND (mesh|collection|pool)` keeps only paths
            // whose content speaks the question's rarest words.
            // Zero-DF guesses are filtered — they'd AND the target
            // away. Truly rare anchors keep the blend: the anchor
            // alone already narrows to a handful, and its rare
            // companions can be absent from the target entirely,
            // so common words carry the fold there.
            var disc = Array(others.prefix(3)) + Array(others.suffix(5))
            var tight = false
            if (pathDF[a] ?? 0) > rareMaxFiles / 4 {
                let rare = others.filter { (contentDF[$0] ?? 0) > 0 }
                    .prefix(4).map { $0 }
                if !rare.isEmpty { disc = rare; tight = true }
            }
            var hits: [SearchHit] = []
            do {
                if !disc.isEmpty {
                    let and = "path_tokens : \"\(a)\"* AND folded : ("
                        + disc.map { "\"\($0)\"*" }.joined(separator: " OR ")
                        + ")"
                    hits = try ftsFileProbe(store: store, match: and,
                                            limit: 20, pathFilter: pathFilter)
                }
                // The target may speak only common vocabulary — retry
                // with the full blend when the tight fold found
                // nothing.
                if tight && hits.isEmpty {
                    let blend = Array(others.prefix(3))
                        + Array(others.suffix(5))
                    if !blend.isEmpty {
                        let and = "path_tokens : \"\(a)\"* AND folded : ("
                            + blend.map { "\"\($0)\"*" }
                                .joined(separator: " OR ") + ")"
                        hits = try ftsFileProbe(store: store, match: and,
                                                limit: 20,
                                                pathFilter: pathFilter)
                    }
                }
                // Bare fallback only for atoms rare enough to trust it —
                // a bare `site*` (DF 42) refloods the window the tight
                // fold just emptied, so name-only evidence is only
                // believable for single-digit-DF atoms.
                if hits.isEmpty, pathDF[a]! <= rareMaxFiles / 4 {
                    hits = try ftsFileProbe(store: store,
                                            match: "path_tokens : \"\(a)\"*",
                                            limit: 20, pathFilter: pathFilter)
                }
            } catch {
                fetchLock.lock()
                if firstFetchError == nil { firstFetchError = error }
                fetchLock.unlock()
                return
            }
            fetchLock.lock()
            perAtom[i] = hits
            fetchLock.unlock()
            if ProcessInfo.processInfo.environment["SWCTX_PROBE_DEBUG"] == "1" {
                FileHandle.standardError.write(
                    "probe atom=\(a) hits=\(hits.map(\.path))\n".data(using: .utf8)!)
            }
        }
        var raw: [SearchHit] = []
        // Anchor atoms that fetched each path via a content-verified
        // (AND-folded) probe — enables glued-name coverage below.
        var viaAnd: [String: Set<String>] = [:]
        for i in 0..<probed.count {
            for h in perAtom[i] ?? [] {
                raw.append(h)
                viaAnd[h.path, default: []].insert(probed[i])
            }
        }
        if raw.isEmpty, let e = firstFetchError { throw e }
        var seenFiles: Set<String> = []
        var scored: [(hit: SearchHit, surgical: Bool, detSurgical: Bool,
                      effectiveCover: Int, stemDensity: Double,
                      rank: Double, idfScore: Double,
                      atoms: Set<String>, stemLen: Int)] = []
        let atomSet = Set(atoms)
        // The atom a covered token claims: its own form if it is an
        // atom, else its singular ("issues" → "issue"). One token = one
        // match — a "status" token covered by atoms {status, statu}
        // counts once.
        func claimedAtom(_ token: String) -> String? {
            if atomSet.contains(token) { return token }
            if let s = singularAtom(token), atomSet.contains(s) {
                return s
            }
            // Stem equality credits morphology: path token "comparison"
            // claims probe atom "compar" (stem of "compare") — without
            // it a stem-fetched file scores coverage 0 on its own name.
            if let s = stemAtom(token), atomSet.contains(s) {
                return s
            }
            return nil
        }
        func idf(_ atom: String) -> Double {
            let df = pathDF[atom] ?? 0
            return df > 0 ? 1.0 / Double(df) : 0
        }
        for h in raw where seenFiles.insert(h.path).inserted {
            // Coverage = distinct path TOKENS the query explains, IDF-
            // weighted: a rare atom ("doi", DF 20) outweighs a common
            // one ("worker", DF 49). Directory tokens count at half
            // weight — inherited context, not the file's own name.
            let pathTokens = Set(pathTokenString(h.path)
                .components(separatedBy: " ").filter { !$0.isEmpty })
            // CamelCase stems must split too — LocalP8SourceAdapter is
            // one glued token otherwise, so source/adapter never count
            // as stem coverage and the file scores dir-only ec1 (the
            // linkeldn regression). Insert a boundary before each
            // upper-case letter that follows a lower-case/digit, then
            // fold and split as usual.
            let stemRaw = ((h.path as NSString).lastPathComponent
                as NSString).deletingPathExtension
            var splitStem = ""
            splitStem.reserveCapacity(stemRaw.count + 8)
            var prevIsLowerOrDigit = false
            for ch in stemRaw {
                if ch.isUppercase && prevIsLowerOrDigit {
                    splitStem.append(" ")
                }
                splitStem.append(ch)
                prevIsLowerOrDigit = ch.isLowercase || ch.isNumber
            }
            let stemTokens = Set(
                foldText(splitStem)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty })
            var idfScore = 0.0
            var stemCover = 0
            var dirCovered = false
            var matchedAtoms: [String] = []
            // Glued names: "sitectl" embeds "site" — no exact token,
            // but the AND probe that fetched it already verified the
            // content speaks the question's language, so the anchor's
            // proper prefix counts as a name claim (≥4 chars guards
            // against "con"→"content"-style junk; bare-fallback hits
            // never reach this branch).
            let anchors = (viaAnd[h.path] ?? []).sorted()
            for t in pathTokens {
                guard let a = claimedAtom(t) ?? anchors.first(where: {
                    $0.count >= 4 && t.count > $0.count
                        && t.hasPrefix($0)
                }) else { continue }
                matchedAtoms.append(a)
                if stemTokens.contains(t) {
                    idfScore += idf(a)
                    stemCover += 1
                } else {
                    idfScore += 0.5 * idf(a)
                    dirCovered = true
                }
            }
            // The path_tokens prefix probe can return files that never
            // name the atom ("blockquote" for "block") — a hit with
            // zero token coverage is noise, not a filename intent.
            guard stemCover > 0 || !matchedAtoms.isEmpty else { continue }
            // A sole-carrier atom lives in exactly one path (path-DF = 1):
            // "brain" names only p8_brain.py — the file IS the concept.
            // DF ≤ 2 proved too generous: twin copies of one script under
            // _legacy/ dirs share DF 2 yet name nothing rare.
            // Weak (stem/acronym-derived) atoms never count as sole
            // carriers: a derived atom that happens to name one file is
            // not the query concept — acronym "rat" must not crown
            // AhrefsDomainRatingService surgical for "run and track".
            let soleCarrier = rarityMatters && matchedAtoms.contains {
                (pathDF[$0] ?? 0) == 1 && !weakAtoms.contains($0)
            }
            // Effective coverage = distinct stem tokens explained, plus
            // ONE bonus for any directory-level agreement: doi-ngu.md
            // ({doi} stem + {fleet} dir = 2) beats every one-token
            // decoy, while a backup slug can't stack dir atoms to pass
            // ghost_link_builder_apply.py's own two-stem-token name.
            let effectiveCover = stemCover + (dirCovered ? 1 : 0)
            // Stem density — the fraction of the filename's own tokens
            // the query explains — breaks near-ties toward the file
            // whose name IS the concept (ghost_link_builder_apply
            // {link,apply}/4 = 0.5 vs 2150-pre-apply-stage-a 1/5 = 0.2).
            let stemDensity = stemTokens.isEmpty ? 0.0
                : Double(stemCover) / Double(stemTokens.count)
            // Continuous rank, no tiers: cover + density + sole-carrier.
            // Tiered orders whack-a-mole'd — fp-first crowned one-rare-
            // atom junk over canonical_check (seo-01), ec-first buried
            // p8_brain's DF-1 hit under 58 plausible ec2 files (seo-09).
            // Additive scoring prices both: brain = 1+0.5+1 = 2.5 beats
            // analysis-dir ec2+sd0.12 = 2.12; canonical = 3+0.67 = 3.67
            // beats minh-bach 2+0.25 = 2.25.
            // Whole-name claim: the file's stem IS one atom
            // (WORKFLOW.md ← "workflow") — the canonical doc for the
            // concept, not a multi-token neighbour. Beats partial-token
            // coverage (ec2/sd0.4) but stays below true multi-atom names.
            let wholeName = stemTokens.count == 1 && stemCover == 1
            let rank = Double(effectiveCover) + stemDensity
                + (soleCarrier ? 1.0 : 0.0)
                + (wholeName ? 0.75 : 0.0)
            // Surgical: the file's STEM carries a sole-carrier atom —
            // p8_brain is the only path naming "brain", so it is the
            // concept, not a plausible neighbour. Dir-only sole atoms
            // (chong-lap/index.html ← "duyet") don't qualify: the name
            // itself must claim the concept.
            let stemAtoms = stemTokens.compactMap { claimedAtom($0) }
            // A test file naming the atom is real but weaker intent
            // evidence: it verifies the subject, it is not the subject.
            // Demote below same-coverage source files and strip surgical.
            let testLike = isTestLikePath(h.path.lowercased())
            // Archived/legacy copies demote on the same scale: probe
            // dedupes by basename, so rank order decides WHICH twin of
            // p8_image_worker.py emits — the live one must win
            // (vn-probe seo-04/seo-10 missed to _legacy/ copies).
            let archiveDepth = h.path.lowercased()
                .split(separator: "/", omittingEmptySubsequences: true)
                .dropLast()
                .filter { seg in
                    seg.components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .contains { Search.archiveDirTokens.contains($0) }
                }.count
            // Surgical's sole-carrier atom must contain a letter: a
            // pure-numeric token ("404") uniquely naming a file marks a
            // recovery batch or report artifact (T1_2_media_404_recovery
            // .json crowned over p8_link_health.py), never a concept.
            let surgical = !testLike && rarityMatters
                && stemAtoms.contains {
                    (pathDF[$0] ?? 0) == 1 && !weakAtoms.contains($0)
                        && $0.rangeOfCharacter(from: .letters) != nil
                }
            // Deterministic-carrier surgical: same sole-carrier test but
            // the carrier must come from cache-free vocabulary — the
            // round-2 gate reads this so a warm/cold translation cache
            // can't flip eligibility between runs.
            let detSurgical = !testLike && rarityMatters
                && stemAtoms.contains {
                    (pathDF[$0] ?? 0) == 1 && !weakAtoms.contains($0)
                        && detAtoms.contains($0)
                        && $0.rangeOfCharacter(from: .letters) != nil
                }
            scored.append((h, surgical, detSurgical, effectiveCover,
                           stemDensity,
                           rank - (testLike ? 0.5 : 0)
                               - 0.5 * Double(archiveDepth),
                           idfScore,
                           Set(matchedAtoms), stemTokens.count))
        }
        scored.sort {
            if $0.surgical != $1.surgical { return $0.surgical }
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.effectiveCover != $1.effectiveCover {
                return $0.effectiveCover > $1.effectiveCover
            }
            if $0.stemDensity != $1.stemDensity {
                return $0.stemDensity > $1.stemDensity
            }
            if $0.idfScore != $1.idfScore {
                return $0.idfScore > $1.idfScore
            }
            if $0.atoms.count != $1.atoms.count {
                return $0.atoms.count > $1.atoms.count
            }
            if $0.stemLen != $1.stemLen { return $0.stemLen < $1.stemLen }
            if $0.hit.score != $1.hit.score {
                return $0.hit.score > $1.hit.score
            }
            return $0.hit.path < $1.hit.path
        }
        if ProcessInfo.processInfo.environment["SWCTX_PROBE_DEBUG"] == "1" {
            FileHandle.standardError.write(
                ("probe ranked: " + scored.map {
                    "\($0.hit.path) sc=\($0.surgical) ec=\($0.effectiveCover) sd=\(String(format: "%.2f", $0.stemDensity)) rk=\(String(format: "%.2f", $0.rank))"
                }.joined(separator: " | ") + "\n").data(using: .utf8)!)
        }
        // Per-directory cap + basename dedup: generated backup/manifest
        // dirs hold dozens of near-identical slugs that all inherit the
        // same dir tokens, and verify/report pipelines scatter copies of
        // one artifact under per-item dirs (internal-link-check.json ×N).
        // Two per directory and one per basename keep representatives.
        // Surgical bar: a probe hit earns its slot only when the name
        // actually matches the intent — fingerprint atom, two explained
        // tokens (stem+dir), or a stem that IS the query concept
        // (density ≥ 0.5). Below the bar the probe is noise — emitting
        // it just crowds out good fusion hits (measured: seo-01 fell
        // rank 1→5 when unfiltered probe rows were prepended).
        // Per-atom champions: each probed atom keeps its best candidate
        // even below the rank bar — vaid_issues.py (rk 1.5) is the only
        // path naming "issue", and dropping it forfeits the whole atom's
        // intent. Champions append AFTER ranked hits, so they surface as
        // tail coverage, never displace stronger names.
        var championFor: [String: String] = [:]  // atom -> path
        for s in scored {
            // Stem atoms earn no champion: a below-bar file named by a
            // derived stem is noise, not a rescued name — champions
            // exist for atoms the query actually said (incl. acronyms:
            // "gas"→gas.ts is a deliberate name rescue).
            for a in s.atoms
            where championFor[a] == nil && !championlessAtoms.contains(a) {
                championFor[a] = s.hit.path
            }
        }
        var dirCount: [String: Int] = [:]
        var seenBasenames: Set<String> = []
        var out: [SearchHit] = []
        var belowBar = 0
        var confident = 0
        var detConfident = 0
        let rankBar = envDouble("SWCTX_PROBE_BAR", 2.0)
        for s in scored {
            // Champions emit even at sd 0: Next.js pages carry intent in
            // the DIRECTORY (attendance/page.tsx stem "page" is generic)
            // — dir coverage is the only signal the convention gives.
            let isChampion = championFor.values.contains(s.hit.path)
            guard s.rank >= rankBar || isChampion else { continue }
            let dir = (s.hit.path as NSString).deletingLastPathComponent
            let base = (s.hit.path as NSString).lastPathComponent
            if (dirCount[dir] ?? 0) >= 2 { continue }
            guard seenBasenames.insert(base).inserted else { continue }
            dirCount[dir] = (dirCount[dir] ?? 0) + 1
            if s.rank < rankBar { belowBar += 1 }
            if s.surgical && s.rank >= rankBar { confident += 1 }
            if s.detSurgical && s.rank >= rankBar { detConfident += 1 }
            out.append(s.hit)
            if out.count >= limit { break }
        }
        // Co-occurrence expansion: a rare deterministic atom's filename
        // siblings are the corpus's own naming convention ("cloudflare"
        // co-names `p8_cloudflare_purge.py` → sibling "purge" is the
        // vocabulary the query lacked). One hop, deterministic atoms
        // only — guessed/stem atoms would expand hallucinations. New
        // atoms are weak + championless: they fetch and claim evidence
        // but can never crown; rare-only (pathDF ≤ rareMaxFiles) keeps
        // the expansion identifying rather than generic. Runs ONLY when
        // the probe's own vocabulary found nothing confident — the same
        // weak-evidence condition that triggers round-2 — so easy
        // queries never pay the mining cost.
        var expansionAtoms: [String] = []
        if detConfident == 0 {
            let coocCap = envInt("SWCTX_COOC_CAP", 30)
            var expanded = 0
            var sibDFCache: [String: Int] = [:]
            let expandBudget = envInt("SWCTX_COOC_MAX", 8)
            // Phase 1 (parallel): fetch each expandable atom's co-name
            // vocabulary. A LIKE scan over `files` (a few thousand
            // rows) beats an FTS prefix scan per atom here; sibling
            // mining only needs the matching paths, which carry the
            // same tokens the index's path_tokens column was built
            // from. Rarest atoms first — they are the identifying
            // vocabulary whose siblings matter.
            let expandable = atoms.filter {
                detAtoms.contains($0)
                    && (pathDF[$0] ?? 0) >= 1
                    && (pathDF[$0] ?? 0) <= coocCap
            }.sorted {
                (pathDF[$0] ?? 0) != (pathDF[$1] ?? 0)
                    ? (pathDF[$0] ?? 0) < (pathDF[$1] ?? 0)
                    : $0 < $1
            }
            var sibDFs = [String: [String: Int]](
                minimumCapacity: expandable.count)
            let sibLock = NSLock()
            DispatchQueue.concurrentPerform(
                iterations: expandable.count) { i in
                let a = expandable[i]
                let paths = (try? store.pool.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT path FROM files WHERE path LIKE ?
                        LIMIT 60
                        """, arguments: ["%\(a)%"])
                }) ?? []
                var siblingDF: [String: Int] = [:]
                for tl in paths {
                    var perFile = Set<String>()
                    for t in tl.components(
                        separatedBy: .alphanumerics.inverted)
                    where t.count >= 3 {
                        let f = foldText(t)
                        if f != a, !atoms.contains(f),
                           !vnStopwords.contains(f),
                           !enStopwords.contains(f) {
                            perFile.insert(f)
                        }
                    }
                    for t in perFile { siblingDF[t, default: 0] += 1 }
                }
                sibLock.lock()
                sibDFs[a] = siblingDF
                sibLock.unlock()
            }
            // Phase 2 (serial): most-conventional siblings first
            // (co-name frequency across the atom's files); each
            // candidate costs one fileCount, so check only the local
            // top-6 and memoize — the same sibling recurs across atoms
            // ("store", "service"). Counts fan out once in parallel
            // over the unique top-6 union.
            var orderedSibs: [[String]] = []
            var allSibs: [String] = []
            var seenSib: Set<String> = []
            for a in expandable {
                let top = (sibDFs[a] ?? [:]).sorted(by: {
                    $0.value != $1.value
                        ? $0.value > $1.value : $0.key < $1.key
                }).map(\.key).prefix(6).map { $0 }
                orderedSibs.append(top)
                for s in top where seenSib.insert(s).inserted {
                    allSibs.append(s)
                }
            }
            DispatchQueue.concurrentPerform(
                iterations: allSibs.count) { i in
                let g = fileCount("path_tokens : \"\(allSibs[i])\"*")
                sibLock.lock()
                sibDFCache[allSibs[i]] = g
                sibLock.unlock()
            }
            for top in orderedSibs where expanded < expandBudget {
                for sib in top where expanded < expandBudget {
                    let g = sibDFCache[sib] ?? 0
                    if g >= 1, g <= rareMaxFiles {
                        expansionAtoms.append(sib)
                        expanded += 1
                    }
                }
            }
        }
        var pr = ProbeResult(hits: out, belowBarCount: belowBar,
                             confidentCount: confident)
        pr.detConfident = detConfident
        pr.expansionAtoms = expansionAtoms
        return pr
    }

    /// File-level FTS probe: one row per FILE (the chunk achieving the
    /// best bm25 for the match), so a many-chunked file can't crowd the
    /// row window. bm25() must be evaluated on MATCH rows — it throws
    /// inside GROUP BY — so the inner subquery materializes scores via
    /// `LIMIT -1` and the outer groups + picks each file's min-rank
    /// chunk (SQLite bare-column-from-min-row semantics). Used by
    /// `plannerPathProbe` where candidates are filenames, not chunks.
    private static func ftsFileProbe(store: Store, match: String,
                                     limit: Int,
                                     pathFilter: String? = nil) throws
        -> [SearchHit] {
        let w = ftsColumnWeights
        return try store.pool.read { db in
            var sql = """
                SELECT sub.id, f.path, sub.start_line, sub.end_line,
                       sub.kind, sub.symbol, MIN(sub.rank) AS rank,
                       sub.snippet
                FROM (
                    SELECT c.id, c.file_id, c.start_line, c.end_line,
                           c.kind, c.symbol,
                           bm25(chunks_fts, \(w.content), \(w.path), \(w.symbol), \(w.folded)) AS rank,
                           snippet(chunks_fts, 0, '«', '»', ' … ', 24) AS snippet
                    FROM chunks_fts
                    JOIN chunks c ON c.id = chunks_fts.rowid
                    WHERE chunks_fts MATCH ?
                    LIMIT -1
                ) sub
                JOIN files f ON f.id = sub.file_id
                """
            var args: [DatabaseValueConvertible] = [match]
            if let p = pathFilter, !p.isEmpty {
                sql += " WHERE f.path LIKE ?"
                args.append(p.hasSuffix("/") ? p + "%" : p + "/%")
            }
            sql += " GROUP BY sub.file_id ORDER BY rank, f.path LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql,
                arguments: StatementArguments(args)).map { row in
                SearchHit(
                    chunkID: (row["id"] as? Int64) ?? -1,
                    path: (row["path"] as? String) ?? "",
                    startLine: Int((row["start_line"] as? Int64) ?? 0),
                    endLine: Int((row["end_line"] as? Int64) ?? 0),
                    kind: row["kind"] as? String,
                    symbol: row["symbol"] as? String,
                    score: -((row["rank"] as? Double) ?? 0),
                    snippet: (row["snippet"] as? String) ?? "")
            }
        }
    }

    /// Substring path probe for MODEL-GUESSED atoms (round-2): FTS
    /// path_tokens only prefix-matches forward, so a guessed atom that
    /// lives as a filename SUFFIX is unreachable — "ctl" can't reach
    /// "sitectl" though it names exactly that convention. A LIKE scan
    /// over the files table is the honest semantics for a guessed atom;
    /// the table is small enough that per-atom LIKEs cost ~ms. Hits are
    /// fragment matches, not stem evidence — callers should treat them
    /// as below-bar champions, never surgical.
    static func pathSubstringProbe(store: Store, atoms: [String],
                                   strictAtoms: [String] = [],
                                   pathFilter: String? = nil,
                                   contentTerms: [String] = [],
                                   perAtom: Int = 5,
                                   limit: Int = 5)
        throws -> [(hit: SearchHit, atoms: Set<String>,
                    exact: Bool, stemEx: Bool, strictOnly: Bool,
                    corroborated: Bool)] {
        // path → (hit, atomDF, exact, basenameHits, matchedAtoms). A
        // file whose NAME contains several guessed atoms is the
        // guess corroborated; a dir-component match is weaker.
        var cands: [String: (hit: SearchHit, df: Int, exact: Bool,
                             stemEx: Bool, baseHits: Int,
                             matched: Set<String>,
                             strictOnly: Bool)] = [:]
        // strictAtoms are short query syllables ("doi", "ngu"): a
        // VN compound name splits into 3-char tokens no ≥4 rule can
        // keep, so they demand the strictest evidence — the atom
        // must be a FULL token of the basename itself.
        let plan = atoms.prefix(envInt("SWCTX_SUBSTR_ATOMS", 20))
            .map { ($0, false) }
            + strictAtoms.prefix(6).map { ($0, true) }
        let dfCap = envInt("SWCTX_SUBSTR_DF", 25)
        // Per-atom COUNT+SELECT are independent LIKE scans over the
        // small files table — ~26 of them serial were the substr lane's
        // whole cost, so fan out on separate readers like the probe's
        // DF fan-out.
        var fetched: [(atom: String, strict: Bool,
                       total: Int, rows: [Row])?] =
            Array(repeating: nil, count: plan.count)
        var firstFetchError: Error?
        let fetchLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: plan.count) { i in
            let (atom, strict) = plan[i]
            guard atom.count >= 3 else { return }
            do {
                let res = try store.pool.read {
                    db -> (Int, [Row]) in
                    var whereSql = "f.path LIKE ?"
                    var args: [DatabaseValueConvertible] = ["%\(atom)%"]
                    if let p = pathFilter, !p.isEmpty {
                        whereSql += " AND f.path LIKE ?"
                        args.append(
                            p.hasSuffix("/") ? p + "%" : p + "/%")
                    }
                    let total = (try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM files f WHERE \(whereSql)
                        """,
                        arguments: StatementArguments(args))) ?? 0
                    guard total > 0 else { return (0, []) }
                    // Flood-atom guard: a "name guess" substring present
                    // in dozens of paths names nothing ("site" reaches
                    // sitectl but also half the corpus). Over-cap atoms
                    // degrade to the strictest evidence: the atom must
                    // be a FULL token of the basename — frequency
                    // doesn't matter for an exact name ("workflow" →
                    // WORKFLOW.md, "hoach" → ke-hoach.md both qualify).
                    let exactOnly = !strict && total > dfCap
                    var rows: [Row] = []
                    if exactOnly {
                        var exactSql = """
                            SELECT f.path, MIN(c.id) AS cid
                            FROM files f
                            JOIN chunks c ON c.file_id = f.id
                            WHERE f.path LIKE ?
                            """
                        var exactArgs: [DatabaseValueConvertible] =
                            ["%\(atom)%"]
                        if let p = pathFilter, !p.isEmpty {
                            exactSql += " AND f.path LIKE ?"
                            exactArgs.append(
                                p.hasSuffix("/") ? p + "%" : p + "/%")
                        }
                        exactSql += """
                             GROUP BY f.id ORDER BY f.mtime DESC
                            LIMIT ?
                            """
                        exactArgs.append(perAtom * 4)
                        rows = try Row.fetchAll(db, sql: exactSql,
                            arguments: StatementArguments(exactArgs))
                    } else {
                        rows = try Row.fetchAll(db, sql: """
                            SELECT f.path, MIN(c.id) AS cid
                            FROM files f
                            JOIN chunks c ON c.file_id = f.id
                            WHERE \(whereSql)
                            GROUP BY f.id ORDER BY f.mtime DESC
                            LIMIT ?
                            """, arguments: StatementArguments(
                                args + [strict ? perAtom * 4 : perAtom]))
                    }
                    return (total, rows)
                }
                fetched[i] = (atom, strict, res.0, res.1)
            } catch {
                fetchLock.lock()
                if firstFetchError == nil { firstFetchError = error }
                fetchLock.unlock()
            }
        }
        return try store.pool.read { db in
            for item in fetched {
                guard let (atom, strict, total, rows) = item,
                      total > 0 else { continue }
                let exactOnly = !strict && total > dfCap
                for row in rows {
                    guard let path = row["path"] as? String else { continue }
                    let base = path.split(separator: "/").last
                        .map(String.init) ?? path
                    // Basename tokens: raw alnum split UNION camelCase
                    // subtokens — the index emits both ("localstore" and
                    // "local","store" for LocalStore.swift), so a glued
                    // guessed atom still matches its glued name while a
                    // camel subtoken of the query ("audit" from
                    // AuditRunIdentifier) reaches its camelCase host.
                    var baseTokSet = Set(
                        base.lowercased().split(
                            omittingEmptySubsequences: true,
                            whereSeparator: {
                                !$0.isLetter && !$0.isNumber })
                            .map(String.init))
                    for rawTok in base.split(
                        omittingEmptySubsequences: true,
                        whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                        for sub in symbolTokens(String(rawTok)) {
                            baseTokSet.insert(
                                foldText(sub).lowercased())
                        }
                    }
                    let baseToks = baseTokSet
                    if strict || exactOnly {
                        // Full-token basename match only — the atom
                        // names a file, not a fragment of one ("doi" in
                        // "doi-ngu.md", "hoach" in "ke-hoach.md", never
                        // a dir component or glued tail).
                        guard baseToks.contains(where: { $0 == atom })
                        else { continue }
                    } else {
                        // Suffix-of-token only: exact and prefix matches
                        // are the FTS probe's job (`atom*` on
                        // path_tokens) — what it can never reach is a
                        // guessed atom living as a token SUFFIX ("ctl"
                        // in "sitectl"). Mid-token fragments are noise
                        // ("merge" in "emergency").
                        let toks = path.lowercased().split(
                            omittingEmptySubsequences: true,
                            whereSeparator: {
                                !$0.isLetter && !$0.isNumber })
                        guard toks.contains(where: { $0.hasSuffix(atom) })
                        else { continue }
                    }
                    let isBase = strict
                        || base.lowercased().contains(atom)
                    // Token-exact name: the atom is a FULL basename
                    // token ("hoach" in ke-hoach.md) — surgical-grade
                    // name evidence in any scan mode.
                    let exactTok = strict || exactOnly
                        || baseToks.contains(where: { $0 == atom })
                    // Stem-equality is the strongest name evidence:
                    // the atom IS the file's whole name ("workflow"
                    // → WORKFLOW.md), not one token of a compound
                    // stem ("site" in site_build_playbook). Strip
                    // non-alphanumerics — Swift extension files carry
                    // "+" ("AuditSustainability+.swift") which must
                    // not break equality.
                    let stem = base.lowercased()
                        .split(separator: ".").first.map(String.init) ?? ""
                    let stemEx = stem.filter { $0.isLetter || $0.isNumber } == atom
                    if var c = cands[path] {
                        c.matched.insert(atom)
                        c.baseHits += isBase ? 1 : 0
                        c.df = min(c.df, total)
                        c.exact = c.exact || exactTok
                        c.stemEx = c.stemEx || stemEx
                        c.strictOnly = c.strictOnly && strict
                        cands[path] = c
                    } else {
                        cands[path] = (SearchHit(
                            chunkID: (row["cid"] as? Int64) ?? -1,
                            path: path,
                            startLine: 0, endLine: 0,
                            kind: nil, symbol: nil,
                            score: 0.5,
                            snippet: ""), total, exactTok, stemEx,
                            isBase ? 1 : 0, [atom], strict)
                    }
                }
            }
            guard !cands.isEmpty else { return [] }
            // Name fragments alone can't rank `sitectl` over `p8ctl` —
            // the candidates' CONTENT against the translated terms is
            // the discriminator the fused head already trusts. One FTS
            // pass over the small candidate set, best rank per file.
            var contentRank: [String: Double] = [:]
            let terms = contentTerms.filter { $0.count >= 3 }.prefix(12)
            if !terms.isEmpty {
                let match = terms.map { "content : \"\($0)\"" }
                    .joined(separator: " OR ")
                let ph = cands.keys.map { _ in "?" }.joined(separator: ",")
                let w = ftsColumnWeights
                // bm25() throws inside GROUP BY — materialize per-chunk
                // ranks in a LIMIT -1 subquery first (same workaround
                // as ftsFileProbe), then pick each file's best.
                let rows = try? Row.fetchAll(db, sql: """
                    SELECT f.path, MIN(sub.rank) AS rank
                    FROM (
                        SELECT c.file_id,
                               bm25(chunks_fts, \(w.content), \(w.path),
                                    \(w.symbol), \(w.folded)) AS rank
                        FROM chunks_fts
                        JOIN chunks c ON c.id = chunks_fts.rowid
                        WHERE chunks_fts MATCH ?
                        LIMIT -1
                    ) sub
                    JOIN files f ON f.id = sub.file_id
                    WHERE f.path IN (\(ph))
                    GROUP BY f.path
                    """, arguments: StatementArguments(
                        [match] + cands.keys.map { $0 }))
                for row in rows ?? [] {
                    if let p = row["path"] as? String,
                       let r = row["rank"] as? Double {
                        contentRank[p] = r
                    }
                }
            }
            // Order: live files before archive/test copies (a guessed
            // name means the live file, not its stale twin), then
            // content-corroborated (bm25 asc), most guessed atoms in
            // the basename, rarest atom.
            func stale(_ p: String) -> Bool {
                let lp = p.lowercased()
                if isTestLikePath(lp) { return true }
                // Segment-tokenized like the fused demotion —
                // "_archive-genspark" counts; "archive.py" is a name.
                // vendors/ demotes too: third-party plugin docs are
                // reference material, never the rescue target.
                return lp.split(separator: "/").dropLast().contains {
                    $0.components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .contains {
                            archiveDirTokens.contains($0)
                                || $0 == "vendors" || $0 == "vendor"
                        }
                }
            }
            // Stem coverage: which fraction of the file's stem tokens
            // the matched atoms name. The champion discriminator —
            // "nap"+"serp" cover nap_serp.py's whole stem while a
            // REVIEW_NAP_* doc matches one incidental token; equal-DF
            // near-ties on content bm25 resolve by who owns the name.
            func stemCoverage(
                _ c: (hit: SearchHit, df: Int, exact: Bool,
                      stemEx: Bool, baseHits: Int,
                      matched: Set<String>, strictOnly: Bool)
            ) -> Double {
                let base = c.hit.path.split(separator: "/").last
                    .map(String.init) ?? c.hit.path
                let stem = base.split(separator: ".").first ?? ""
                let toks = Set(stem.lowercased().split(
                    omittingEmptySubsequences: true,
                    whereSeparator: {
                        !$0.isLetter && !$0.isNumber
                    }).map(String.init))
                guard !toks.isEmpty else { return 0 }
                return Double(toks.intersection(c.matched).count)
                    / Double(toks.count)
            }
            var stemCov: [String: Double] = [:]
            for (p, c) in cands { stemCov[p] = stemCoverage(c) }
            let ordered = cands.values.sorted { a, b in
                let sa = stale(a.hit.path), sb = stale(b.hit.path)
                if sa != sb { return !sa }
                // Corroboration tier: real name evidence (non-strict
                // exact) or content support. A bare 3-char strict-token
                // match ("doi" in bay-cua-noi-doi) is a common VN
                // syllable — without content speaking the query it is
                // noise, so it sinks below every corroborated cand.
                let ra = contentRank[a.hit.path]
                let rb = contentRank[b.hit.path]
                let ca = (a.exact && !a.strictOnly) || ra != nil
                let cb = (b.exact && !b.strictOnly) || rb != nil
                if ca != cb { return ca }
                let va = stemCov[a.hit.path] ?? 0
                let vb = stemCov[b.hit.path] ?? 0
                if va != vb { return va > vb }
                if a.stemEx != b.stemEx { return a.stemEx }
                switch (ra, rb) {
                case let (x?, y?): if x != y { return x < y }
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if a.baseHits != b.baseHits { return a.baseHits > b.baseHits }
                if a.matched.count != b.matched.count {
                    return a.matched.count > b.matched.count
                }
                if a.df != b.df { return a.df < b.df }
                return a.hit.path < b.hit.path
            }
            // Strict-only candidates with zero content corroboration
            // are pure syllable noise — drop them from emission (they
            // would still occupy the head slot whenever no better cand
            // exists).
            let kept = ordered.filter {
                !$0.strictOnly || contentRank[$0.hit.path] != nil
            }
            if ProcessInfo.processInfo.environment["SWCTX_PROBE_DEBUG"] == "1" {
                FileHandle.standardError.write(
                    "substr atoms=\(atoms)+\(strictAtoms) cands=\(kept.prefix(limit).map { "\($0.hit.path)|cr=\(contentRank[$0.hit.path] ?? 0)|cov=\(stemCov[$0.hit.path] ?? 0)|df=\($0.df)|st=\(stale($0.hit.path))|m=\($0.matched.sorted())" })\n"
                        .data(using: .utf8)!)
            }
            return kept.prefix(limit).map {
                ($0.hit, $0.matched, $0.exact, $0.stemEx, $0.strictOnly,
                 contentRank[$0.hit.path] != nil)
            }
        }
    }

    /// BM25F column weights for chunks_fts(content, path_tokens,
    /// symbol_names, folded). Order must match the CREATE TABLE column
    /// order exactly — body hits are baseline, path/symbol hits outrank
    /// them, and folded-only matches are deliberately cheap so variant
    /// noise can't outrank real hits.
    static let ftsColumnWeights: (content: Double, path: Double, symbol: Double, folded: Double) =
        (1.0, 2.5, 5.0, 0.6)

    /// Post-hoc boost magnitudes (all inside the 0.09 cap, tuned on
    /// bench/vn_probe.py — RRF scores total ~0.05, so boosts must stay
    /// small to adjust order without drowning the fused signal).
    static let coverageWeight = 0.01        // per DISTINCT folded term present
    static let coverageCap = 0.03           // sub-cap on the coverage term
    static let pagerankWeight = 0.02        // × min-max normalized file rank
    static let depthPenaltyPerSegment = 0.005
    /// Archive/legacy dir-segment demotion — one per matching directory
    /// in the path ("_legacy/", "docs/archive/", "_archive-genspark/").
    /// Beats the old root-only "archive/" -0.01: archived twins must
    /// lose ties to live files, not merely drift down.
    static let archivePenaltyPerSegment = 0.03
    static let archiveDirTokens: Set<String> = [
        "archive", "archived", "legacy", "deprecated", "attic",
        "old", "backup", "backups", "snapshot", "snapshots",
    ]
    /// Folded-phrase rescue leg weight — below the real legs; it exists
    /// to surface diacritic phrase matches, not outrank them.
    static let phraseLegWeight = 0.8
    /// vn→en translation leg weight (W11) — below the real legs and the
    /// phrase leg: LLM-produced terms are a noisier signal than folded
    /// phrases from the query itself. SWCTX_XLATE_W overrides for bench
    /// sweeps only — tuned values get baked in as new defaults.
    static func xlateLegWeight() -> Double {
        if let s = ProcessInfo.processInfo.environment["SWCTX_XLATE_W"],
           let v = Double(s), v >= 0 { return v }
        return 0.7
    }

    /// Per-leg RRF weights (fts, semantic, symbol). Defaults are uniform;
    /// `SWCTX_RRF_W="f,s,y"` overrides for bench sweeps only — tuned
    /// values get baked in as new defaults once measured, not left
    /// env-dependent.
    static func fusionWeights() -> (fts: Double, sem: Double, sym: Double) {
        if let s = ProcessInfo.processInfo.environment["SWCTX_RRF_W"] {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 3, p.allSatisfy({ $0 >= 0 }) {
                return (p[0], p[1], p[2])
            }
        }
        return (1.0, 1.0, 1.0)
    }

    public static func fts(store: Store, query: String, limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        guard let match = ftsQuery(query) else { return [] }
        var hits = try ftsRun(store: store, match: match, limit: limit,
                              pathFilter: pathFilter)
        // Folded rescue as tail-filler only (same contract as the trigram
        // leg): when real hits under-fill the request, column-scoped
        // folded matches top it up. They can never displace real hits —
        // mixing them into the shared window measurably pushed
        // borderline files out of the fused pool (seo-02, vn_probe).
        if hits.count < limit, let fmatch = ftsFoldedQuery(query) {
            hits += try ftsRun(store: store, match: fmatch,
                               limit: limit - hits.count, pathFilter: pathFilter,
                               excluding: Set(hits.map { $0.chunkID }))
        }
        return hits
    }

    private static func ftsRun(store: Store, match: String, limit: Int,
                               pathFilter: String? = nil,
                               excluding: Set<Int64> = []) throws -> [SearchHit] {
        let w = ftsColumnWeights
        return try store.pool.read { db in
            var sql = """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol,
                       bm25(chunks_fts, \(w.content), \(w.path), \(w.symbol), \(w.folded)) AS rank,
                       snippet(chunks_fts, 0, '«', '»', ' … ', 24) AS snippet
                FROM chunks_fts
                JOIN chunks c ON c.id = chunks_fts.rowid
                JOIN files f ON f.id = c.file_id
                WHERE chunks_fts MATCH ?
                """
            var args: [DatabaseValueConvertible] = [match]
            if let p = pathFilter, !p.isEmpty {
                sql += " AND f.path LIKE ?"
                args.append(p.hasSuffix("/") ? p + "%" : p + "/%")
            }
            if !excluding.isEmpty {
                sql += " AND c.id NOT IN (\(excluding.map { String($0) }.joined(separator: ",")))"
            }
            sql += " ORDER BY rank, path LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchHit(
                    chunkID: (row["id"] as? Int64) ?? -1, path: (row["path"] as? String) ?? "",
                    startLine: Int((row["start_line"] as? Int64) ?? 0), endLine: Int((row["end_line"] as? Int64) ?? 0),
                    kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                    score: -((row["rank"] as? Double) ?? 0), snippet: (row["snippet"] as? String) ?? "")
            }
        }
    }

    /// Process-level cache for the semantic leg's vector matrix. Stores are
    /// created per tool call, so the matrix must outlive them; entries are
    /// validated by `Store.embeddingsSignature()` (one tiny meta read) and
    /// evicted LRU. Scores are identical to a fresh read — same float32s —
    /// so this changes latency, not ranking.
    struct CachedVectors {
        var signature: String
        var dim: Int
        var ids: [Int64]
        var matrix: [Float]  // ids.count × dim, row-major contiguous
        var lastUse: Date
    }
    static let vectorCache = VectorCacheBox()

    /// All mutable state is behind `lock`; entries are value types never
    /// mutated after storage — safe to share across the MCP server's tasks.
    final class VectorCacheBox: @unchecked Sendable {
        private var lock = NSLock()
        private var entries: [String: CachedVectors] = [:]
        private let maxEntries = 4
        private let maxBytes = 512 << 20

        func cached(key: String, signature: String, dim: Int) -> CachedVectors? {
            lock.lock(); defer { lock.unlock() }
            guard var e = entries[key],
                  e.signature == signature, e.dim == dim else { return nil }
            e.lastUse = Date(); entries[key] = e
            return e
        }
        func store(key: String, entry: CachedVectors) {
            guard entry.matrix.count * 4 <= maxBytes else { return }
            lock.lock(); defer { lock.unlock() }
            entries[key] = entry
            if entries.count > maxEntries,
               let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }

    /// Brute-force cosine over stored (normalized) embeddings.
    public static func semantic(store: Store, embedder: Embedder, query: String,
                                limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        guard let qv = embedder.embed(query) else { return [] }
        if pathFilter != nil {
            return try semanticFiltered(store: store, qv: qv, limit: limit,
                                        pathFilter: pathFilter!)
        }
        let key = Store.key(for: store.workspaceRoot)
        let sig = try store.embeddingsSignature()
        var entry = vectorCache.cached(key: key, signature: sig, dim: qv.count)
        if entry == nil {
            entry = try loadVectors(store: store, signature: sig, dim: qv.count)
            if let e = entry { vectorCache.store(key: key, entry: e) }
        }
        guard let e = entry, !e.ids.isEmpty else { return [] }

        // All dots in one BLAS call (matrix row-major, qv unit-length).
        let n = e.ids.count
        var scores = [Float](repeating: 0, count: n)
        e.matrix.withUnsafeBufferPointer { m in
            qv.withUnsafeBufferPointer { q in
                scores.withUnsafeMutableBufferPointer { s in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(e.dim),
                                1.0, m.baseAddress!, Int32(e.dim),
                                q.baseAddress!, 1, 0.0, s.baseAddress!, 1)
                }
            }
        }
        var scored: [(Int64, Float)] = []
        scored.reserveCapacity(64)
        for i in 0..<n where scores[i] > 0.05 {
            scored.append((e.ids[i], scores[i]))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let top = scored.prefix(limit)
        guard !top.isEmpty else { return [] }

        // Chunk metadata only for the handful of winners — the old query
        // joined path/lines for every row in the corpus.
        let topIDs = top.map { $0.0 }
        let ph = topIDs.map { _ in "?" }.joined(separator: ",")
        let metaRows = try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                FROM chunks c JOIN files f ON f.id = c.file_id
                WHERE c.id IN (\(ph))
                """, arguments: StatementArguments(topIDs))
        }
        var meta: [Int64: Row] = [:]
        meta.reserveCapacity(metaRows.count)
        for r in metaRows {
            if let id = r["id"] as? Int64 { meta[id] = r }
        }
        return top.compactMap { (cid, score) in
            guard let row = meta[cid] else { return nil }
            return SearchHit(
                chunkID: cid, path: (row["path"] as? String) ?? "",
                startLine: Int((row["start_line"] as? Int64) ?? 0),
                endLine: Int((row["end_line"] as? Int64) ?? 0),
                kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                score: Double(score), snippet: "")
        }
    }

    /// Load the vector matrix, keeping only rows whose stored dim matches
    /// the active model (mixed-dim guard). A flat sidecar file beside
    /// index.db (validated by the same epoch signature) lets cold starts
    /// skip 32K blob decodes: one sequential ~100MB read replaces the
    /// row-by-row SQLite fetch. The sidecar is host-endian — a local
    /// derived cache, never exchanged.
    private static let sidecarMagic: [UInt8] = Array("SWVCTRX1".utf8)

    private static func loadVectors(store: Store, signature: String,
                                    dim: Int) throws -> CachedVectors? {
        let sidecar = Store.indexURL(forKey: store.workspaceKey)
            .deletingLastPathComponent()
            .appendingPathComponent("vectors.v1.bin")
        if let e = readVectorSidecar(url: sidecar, signature: signature, dim: dim) {
            return e
        }
        let rows = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT chunk_id, dim, vec FROM embeddings")
        }
        guard !rows.isEmpty else { return nil }
        var ids: [Int64] = []
        var matrix: [Float] = []
        ids.reserveCapacity(rows.count)
        matrix.reserveCapacity(rows.count * dim)
        for row in rows {
            guard let blob = row["vec"] as? Data,
                  let d = row["dim"] as? Int64, Int(d) == dim,
                  let cid = row["chunk_id"] as? Int64,
                  blob.count == dim * 4 else { continue }
            ids.append(cid)
            // copyBytes into aligned array storage: `bindMemory` requires
            // 4-byte alignment a Data buffer does not guarantee.
            var floats = [Float](repeating: 0, count: dim)
            floats.withUnsafeMutableBytes { dst in
                blob.copyBytes(to: dst, from: 0..<dim * 4)
            }
            matrix.append(contentsOf: floats)
        }
        guard ids.count == matrix.count / dim else { return nil }
        let entry = CachedVectors(signature: signature, dim: dim, ids: ids,
                                  matrix: matrix, lastUse: Date())
        try? writeVectorSidecar(url: sidecar, entry: entry)
        return entry
    }

    /// Sidecar layout: magic(8) | dim(u32le) | count(u64le) | sigLen(u16le)
    /// | sig | ids(count×i64) | matrix(count×dim×f32). Any mismatch on
    /// magic/dim/signature → nil, caller falls back to the blob path.
    static func readVectorSidecar(url: URL, signature: String,
                                          dim: Int) -> CachedVectors? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var off = sidecarMagic.count
        guard data.count > off + 14,
              data[0..<off].elementsEqual(sidecarMagic) else { return nil }
        func u32() -> UInt32? {
            guard off + 4 <= data.count else { return nil }
            defer { off += 4 }
            return data[off..<off + 4].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }.littleEndian
        }
        func u64() -> UInt64? {
            guard off + 8 <= data.count else { return nil }
            defer { off += 8 }
            return data[off..<off + 8].withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self)
            }.littleEndian
        }
        func u16() -> UInt16? {
            guard off + 2 <= data.count else { return nil }
            defer { off += 2 }
            return data[off..<off + 2].withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self)
            }.littleEndian
        }
        guard let d = u32(), let n = u64(), let sigLen = u16(),
              Int(d) == dim, off + Int(sigLen) <= data.count,
              String(decoding: data[off..<off + Int(sigLen)], as: UTF8.self) == signature
        else { return nil }
        off += Int(sigLen)
        // `Int(n)` traps when n > Int.max, and `cnt*8 + cnt*dim*4` can
        // overflow Int before the bounds check — division-first bound is
        // safe: cnt*(8+dim*4) <= data.count-off implies no overflow.
        guard let cnt = Int(exactly: n),
              cnt <= (data.count - off) / (8 + dim * 4),
              off + cnt * 8 + cnt * dim * 4 == data.count else { return nil }
        let ids = [Int64](unsafeUninitializedCapacity: cnt) { buf, done in
            data.copyBytes(to: buf, from: off..<off + cnt * 8)
            done = cnt
        }
        off += cnt * 8
        let matrix = [Float](unsafeUninitializedCapacity: cnt * dim) { buf, done in
            data.copyBytes(to: buf, from: off..<off + cnt * dim * 4)
            done = cnt * dim
        }
        return CachedVectors(signature: signature, dim: dim, ids: ids,
                             matrix: matrix, lastUse: Date())
    }

    static func writeVectorSidecar(url: URL, entry: CachedVectors) throws {
        var d = Data()
        d.reserveCapacity(24 + entry.signature.count + entry.ids.count * 8
                          + entry.matrix.count * 4)
        d.append(contentsOf: sidecarMagic)
        withUnsafeBytes(of: UInt32(entry.dim).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(entry.ids.count).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(entry.signature.utf8.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: entry.signature.utf8)
        entry.ids.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        entry.matrix.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        try d.write(to: url, options: .atomic)
    }

    /// Rare path-filtered variant: keeps the joined-row scan so the filter
    /// applies before scoring (the cache holds no paths).
    private static func semanticFiltered(store: Store, qv: [Float], limit: Int,
                                         pathFilter: String) throws -> [SearchHit] {
        let rows = try store.pool.read { db in
            let prefix = pathFilter.hasSuffix("/") ? pathFilter : pathFilter + "/"
            return try Row.fetchAll(db, sql: """
                SELECT e.chunk_id, e.dim, e.vec, f.path, c.start_line, c.end_line,
                       c.kind, c.symbol
                FROM embeddings e
                JOIN chunks c ON c.id = e.chunk_id
                JOIN files f ON f.id = c.file_id
                WHERE (f.path = ? OR f.path LIKE ?)
                """, arguments: StatementArguments([pathFilter, prefix + "%"]))
        }
        var scored: [(Int64, Float)] = []
        scored.reserveCapacity(rows.count)
        var byID: [Int64: Row] = [:]
        for row in rows {
            guard let blob = row["vec"] as? Data, let dim = row["dim"] as? Int64,
                  let floats = Embedder.vector(from: blob, dim: Int(dim)),
                  floats.count == qv.count else { continue }
            var s: Float = 0
            floats.withUnsafeBufferPointer { f in
                vDSP_dotpr(qv, 1, f.baseAddress!, 1, &s, vDSP_Length(f.count))
            }
            if s > 0.05, let cid = row["chunk_id"] as? Int64 {
                scored.append((cid, s))
                byID[cid] = row
            }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.prefix(limit).compactMap { (cid, score) in
            guard let row = byID[cid] else { return nil }
            return SearchHit(
                chunkID: cid, path: (row["path"] as? String) ?? "", startLine: Int((row["start_line"] as? Int64) ?? 0),
                endLine: Int((row["end_line"] as? Int64) ?? 0), kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                score: Double(score), snippet: "")
        }
    }

    /// Split an identifier into lowercase subtokens ("runPipeline" -> [run, pipeline]).
    static func symbolTokens(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var cur = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            // Acronym-run boundary: "CMSRedirects" splits before the last
            // uppercase char of the run when a lowercase follows → "CMS" +
            // "Redirects"; "P8Catalog" splits at digit→upper when a
            // lowercase follows → "P8" + "Catalog".
            if ch.isUppercase, let last = cur.last,
               last.isLowercase
                || (cur.count > 1 && last.isUppercase
                    && i + 1 < chars.count && chars[i + 1].isLowercase)
                || (last.isNumber
                    && i + 1 < chars.count && chars[i + 1].isLowercase) {
                out.insert(cur.lowercased()); cur = ""
            }
            if ch.isLetter || ch.isNumber { cur.append(ch) } else if !cur.isEmpty {
                out.insert(cur.lowercased()); cur = ""
            }
        }
        if !cur.isEmpty { out.insert(cur.lowercased()) }
        return out
    }

    /// Accent-fold for path/term matching: diacritic-insensitive + case fold,
    /// plus explicit đ/Đ → d (standalone letters Unicode folding leaves intact).
    static func foldText(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
    }

    /// Space-joined folded path tokens for the FTS `path_tokens` column:
    /// alnum-split, then camelCase subtokens (split BEFORE folding loses
    /// the case signal), all diacritic-folded — "ui/getUser.py" indexes
    /// as "ui get user py".
    static func pathTokenString(_ path: String) -> String {
        var out: [String] = []
        for raw in path.components(separatedBy: CharacterSet.alphanumerics.inverted)
        where !raw.isEmpty {
            out.append(foldText(raw))
            for sub in symbolTokens(raw) { out.append(foldText(sub)) }
        }
        return out.joined(separator: " ")
    }

    /// Space-joined tokens for the FTS `symbol_names` column: each name
    /// contributes its folded raw form plus folded subtokens, so both
    /// "resolveedges" and "resolve edges" queries reach "resolveEdges".
    static func symbolTokenString(_ names: [String]) -> String {
        var out: [String] = []
        for n in names where !n.isEmpty {
            out.append(foldText(n))
            for t in symbolTokens(n) { out.append(foldText(t)) }
        }
        return out.joined(separator: " ")
    }

    /// Chunks defining a symbol whose name exactly equals a query token
    /// (identifier-lookup intent). Prose docs mentioning the word never
    /// appear in this leg, so vector noise cannot bury real definitions.
    static func symbolHits(store: Store, query: String, limit: Int, pathFilter: String? = nil) throws -> [SearchHit] {
        var terms = Set(query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }.prefix(12))
        let whole = query.trimmingCharacters(in: .whitespaces)
        if whole.count >= 2, !whole.contains(" ") { terms.insert(whole.lowercased()) }
        guard !terms.isEmpty else { return [] }
        return try store.pool.read { db in
            var sql = """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                FROM symbols s
                JOIN chunks c ON c.id = s.chunk_id
                JOIN files f ON f.id = c.file_id
                WHERE lower(s.name) IN (\(terms.map { _ in "?" }.joined(separator: ",")))
                """
            var args: [DatabaseValueConvertible] = terms.map { $0 as DatabaseValueConvertible }
            if let p = pathFilter, !p.isEmpty {
                sql += " AND f.path LIKE ?"
                args.append((p.hasSuffix("/") ? p + "%" : p + "/%") as DatabaseValueConvertible)
            }
            // Def-chunks (the chunk's own symbol is the match) rank first.
            // A chunk matching via several joined symbols must not rank
            // non-deterministically — GROUP BY + MIN picks the best rank.
            sql += """
                 GROUP BY c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol
                 ORDER BY MIN(CASE WHEN lower(c.symbol) = lower(s.name) THEN 0 ELSE 1 END), f.path, c.id
                 LIMIT ?
                """
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchHit(
                    chunkID: (row["id"] as? Int64) ?? -1, path: (row["path"] as? String) ?? "",
                    startLine: Int((row["start_line"] as? Int64) ?? 0), endLine: Int((row["end_line"] as? Int64) ?? 0),
                    kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                    score: 0, snippet: "")
            }
        }
    }

    /// Identifier-shaped lookup (snake_case, CamelCase, `::`, dotted or
    /// path-like single token). Such queries are definition lookups, so the
    /// vector leg adds cost and noise without upside.
    public static func identifierLike(_ query: String) -> Bool {
        let t = query.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" "), t.count >= 2 else { return false }
        if t.range(of: #"[_:.\\/\-]"#, options: .regularExpression) != nil { return true }
        // camelCase or ALLCAPS signal: an uppercase letter that is not the
        // leading character of a plain Capitalized word still counts.
        return t.range(of: #"[a-z][A-Z]|[A-Z][a-z]+[A-Z]|^[A-Z][a-z]*$"#, options: .regularExpression) != nil
    }

    /// Reciprocal-rank fusion of FTS + semantic hits, with deterministic
    /// symbol/path boosts and a small legacy-archive penalty. `includeVector`
    /// false skips embedding entirely (identifier lookups).
    public static func hybrid(store: Store, embedder: Embedder, query: String,
                              limit: Int, pathFilter: String? = nil,
                              includeVector: Bool = true) throws -> [SearchHit] {
        try hybridCandidates(store: store, embedder: embedder, query: query,
                             limit: limit, poolLimit: limit,
                             pathFilter: pathFilter, includeVector: includeVector)
    }

    /// The fused candidate pool BEFORE the final limit cut: same legs,
    /// RRF and post-hoc boosts as `hybrid`, but returns up to `poolLimit`
    /// scored rows so a later rerank stage can rescore the full pool
    /// instead of only the visible page. When the fused pool under-fills
    /// `poolLimit`, trigram substring hits top it up (they never join
    /// RRF — substring noise is too loose for the fused score).
    public static func hybridCandidates(store: Store, embedder: Embedder, query: String,
                                        limit: Int, poolLimit: Int,
                                        pathFilter: String? = nil,
                                        includeVector: Bool = true) throws -> [SearchHit] {
        // Legs run concurrently: DatabasePool serves each read on its own
        // connection and query-embed inference (CoreML, CPU-bound) overlaps
        // the FTS IO. Sequential legs measured ~150ms warm on VN hybrid;
        // parallel legs cost ~max(fts, embed+cache) instead of the sum.
        let bag = LegBag()
        let group = DispatchGroup()
        let legQueue = DispatchQueue.global(qos: .userInitiated)
        let legStart = Date()
        group.enter()
        legQueue.async {
            defer { group.leave() }
            do { bag.fts = try fts(store: store, query: query, limit: limit * 3, pathFilter: pathFilter) }
            catch { bag.note(error) }
        }
        if includeVector {
            group.enter()
            legQueue.async {
                defer { group.leave() }
                do { bag.vec = try semantic(store: store, embedder: embedder, query: query, limit: limit * 3, pathFilter: pathFilter) }
                catch { bag.note(error) }
            }
        }
        group.enter()
        legQueue.async {
            defer { group.leave() }
            do { bag.sym = try symbolHits(store: store, query: query, limit: limit * 3, pathFilter: pathFilter) }
            catch { bag.note(error) }
        }
        // Folded-phrase rescue leg (diacritic queries only — ASCII folds
        // are identity so EN legs are unchanged). Adjacent-token phrases
        // on path_tokens are far more discriminating than term-OR folded
        // probes: "chấm công" → path_tokens : "cham cong" reaches
        // cham_cong.py-style filenames, while single-token folded probes
        // flooded windows on every earlier attempt (merged OR: 7/16,
        // appended: 9/16, dedicated term leg: 10/16 net-zero). Capped at
        // 5, file-deduped — a phrase match is a file-level signal.
        if let pq = foldedPhraseQuery(query) {
            group.enter()
            legQueue.async {
                defer { group.leave() }
                do {
                    let raw = try ftsRun(store: store, match: pq, limit: 15,
                                         pathFilter: pathFilter)
                    var seenFiles: Set<String> = []
                    var out: [SearchHit] = []
                    for h in raw where seenFiles.insert(h.path).inserted {
                        out.append(h)
                        if out.count == 5 { break }
                    }
                    bag.phrase = out
                } catch { bag.note(error) }
            }
        }
        // vn→en translation leg (W11): fires only on diacritic-carrying
        // queries. The leg lives on a SEPARATE group waited with a timeout
        // of the ~800ms deadline's remainder — a slow Ollama can add at
        // most deadline-minus-real-legs latency, so translation is never
        // on the critical path of the first result. A leg that misses the
        // window is cancelled for this result but may still finish its
        // subprocess (hard-capped separately) to fill the term cache for
        // later queries. Failures degrade to baseline (try?/nil), never
        // to bag.error.
        let xlateBag = XlateBag()
        var xlateGroup: DispatchGroup?
        if Translation.needsTranslation(query) {
            let g = DispatchGroup()
            xlateGroup = g
            g.enter()
            legQueue.async {
                defer { g.leave() }
                guard let terms = Translation.englishTerms(for: query),
                      let hits = try? translatedLegHits(
                          store: store, terms: terms, pathFilter: pathFilter)
                else { return }
                xlateBag.set(hits, terms: terms)
            }
        }
        group.wait()
        if let e = bag.error { throw e }
        var xlateHits: [SearchHit] = []
        var xlateSourceTerms: [String] = []
        if let g = xlateGroup {
            let remainMs = Translation.deadlineMs
                - Int(Date().timeIntervalSince(legStart) * 1000)
            if remainMs > 0 {
                _ = g.wait(timeout: .now() + .milliseconds(remainMs))
            }
            xlateHits = xlateBag.hits
            xlateSourceTerms = xlateBag.terms
        }
        let ftsHits = bag.fts, vecHits = bag.vec, symHits = bag.sym, phraseHits = bag.phrase
        let w = fusionWeights()
        var rrf: [Int64: Double] = [:]
        for (i, h) in ftsHits.enumerated() { rrf[h.chunkID, default: 0] += w.fts / (60 + Double(i) + 1) }
        for (i, h) in vecHits.enumerated() { rrf[h.chunkID, default: 0] += w.sem / (60 + Double(i) + 1) }
        // Exact-symbol leg gets full leg weight: an identifier token is a
        // strong intent signal, so its definitions deserve top placement.
        for (i, h) in symHits.enumerated() { rrf[h.chunkID, default: 0] += w.sym / (60 + Double(i) + 1) }
        for (i, h) in phraseHits.enumerated() {
            rrf[h.chunkID, default: 0] += Search.phraseLegWeight / (60 + Double(i) + 1)
        }
        for (i, h) in xlateHits.enumerated() {
            rrf[h.chunkID, default: 0] += Search.xlateLegWeight() / (60 + Double(i) + 1)
        }
        var byID: [Int64: SearchHit] = [:]
        for h in ftsHits + vecHits + symHits + phraseHits + xlateHits { byID[h.chunkID] = h }
        // Translated-term evidence, scoped to the leg's own candidates: the
        // query-term boosts below can't see English atoms (the query is
        // Vietnamese), so an xlate-only file would carry a bare RRF share.
        // Re-scoring it on translated-atom path/coverage matches keeps the
        // leg's file-level signal meaningful without touching other
        // candidates' scores.
        let xlateIDs = Set(xlateHits.map { $0.chunkID })
        let xlateAtoms = Set(ftsTranslatedAtoms(
            xlateHits.isEmpty ? [] : xlateSourceTerms))

        let terms = Set(query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }.prefix(12))
        // Folded term set for path matching only: substring matching on the
        // raw path produced phantom boosts ("quantri" inside unrelated paths)
        // and accented VN terms could never match ASCII path tokens.
        let termsFolded = Set(terms.map(foldText))

        // Static-signal metadata for the whole fused pool in one batched
        // read: chunk content (atom coverage) + file PageRank, plus the
        // index-wide pagerank span for [0,1] normalization.
        var candText: [Int64: String] = [:]
        var candPR: [Int64: Double] = [:]
        var prMin = 0.0, prSpan = 0.0
        if !rrf.isEmpty {
            let ids = Array(rrf.keys)
            try store.pool.read { db in
                let ph = ids.map { _ in "?" }.joined(separator: ",")
                for r in try Row.fetchAll(db, sql: """
                    SELECT c.id, c.content, f.pagerank
                    FROM chunks c JOIN files f ON f.id = c.file_id
                    WHERE c.id IN (\(ph))
                    """, arguments: StatementArguments(ids)) {
                    guard let cid = r["id"] as? Int64 else { continue }
                    candText[cid] = (r["content"] as? String) ?? ""
                    candPR[cid] = (r["pagerank"] as? Double) ?? 0
                }
                if let r = try Row.fetchOne(db, sql:
                    "SELECT MIN(pagerank) AS mn, MAX(pagerank) AS mx FROM files") {
                    prMin = (r["mn"] as? Double) ?? 0
                    prSpan = max(0, ((r["mx"] as? Double) ?? 0) - prMin)
                }
            }
        }

        let scored = rrf.map { (cid, score) -> (Int64, Double) in
            guard let h = byID[cid] else { return (cid, score) }
            var boost = 0.0
            if let sym = h.symbol {
                let st = symbolTokens(sym)
                boost += 0.03 * Double(terms.intersection(st).count)
            }
            let lp = h.path.lowercased()
            let pathTokens = Set(foldText(h.path)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 })
            boost += 0.015 * Double(termsFolded.intersection(pathTokens).count)
            // Archive/legacy DIR segments demote: a "_legacy/" twin must
            // lose ties to the live same-name file, not outrank it
            // (vn-probe seo-04/seo-10 missed to archived copies).
            // Segment-tokenized — "_archive-genspark" counts as archive;
            // the filename itself is excluded ("archive.py" is a name).
            var archiveDepth = 0
            for seg in lp.split(separator: "/", omittingEmptySubsequences: true)
                .dropLast() {
                if seg.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .contains(where: { Search.archiveDirTokens.contains($0) }) {
                    archiveDepth += 1
                }
            }
            boost -= Search.archivePenaltyPerSegment * Double(archiveDepth)
            if isTestLikePath(lp) { boost -= 0.02 }
            // Atom coverage: +0.01 per DISTINCT folded query term present
            // in the candidate's folded token set (content+symbol+path),
            // sub-capped at +0.03 — on 10+ term natural-language queries
            // raw term-count saturates and would drown the fused score.
            let hayTokens = Set(foldText(
                    (candText[cid] ?? "") + " " + (h.symbol ?? "") + " " + h.path)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 })
            boost += min(Search.coverageWeight * Double(termsFolded.intersection(hayTokens).count),
                         Search.coverageCap)
            if xlateIDs.contains(cid) {
                // Path-atom evidence only. A coverage component on generic
                // English atoms ("gate", "user", "data") flooded wrong
                // files above correct baseline hits in bench — filename
                // intent is the precise half of the leg's signal.
                boost += 0.015 * Double(xlateAtoms.intersection(pathTokens).count)
            }
            // File-graph PageRank: small static prior so hub definitions
            // beat same-name dead files, 0 when the index is unranked.
            if prSpan > 0, let pr = candPR[cid] {
                boost += Search.pagerankWeight * ((pr - prMin) / prSpan)
            }
            // Depth penalty (zoekt root-importance): −0.005 per path
            // segment beyond the first — deep vendored paths sink.
            let segments = h.path.split(
                separator: "/", omittingEmptySubsequences: true).count
            boost -= Search.depthPenaltyPerSegment * Double(max(0, segments - 1))
            return (cid, score + min(boost, 0.09))
        }.sorted { $0.1 > $1.1 }

        var out = scored.prefix(poolLimit).compactMap { (cid, score) -> SearchHit? in
            guard var h = byID[cid] else { return nil }
            h.score = score
            return h
        }
        // Trigram fallback: only when the fused pool under-fills the
        // request — mid-token substrings (e.g. "edgeshelper" inside
        // "resolveEdgesHelper") never reach the prefix FTS legs.
        if out.count < poolLimit {
            out += try trigramHits(store: store, query: query,
                                   limit: poolLimit - out.count,
                                   excluding: Set(out.map { $0.chunkID }),
                                   pathFilter: pathFilter)
        }
        return out
    }

    /// Substring-level fallback leg over the trigram FTS table. Each
    /// query term ≥3 chars becomes a quoted trigram phrase (a mid-token
    /// substring match; the tokenizer folds case only, so folded variants
    /// are added to reach diacritic-folded content).
    static func trigramHits(store: Store, query: String, limit: Int,
                            excluding: Set<Int64> = [],
                            pathFilter: String? = nil) throws -> [SearchHit] {
        // Opt-in leg: the trigram index costs ~40-45% of DB size and is
        // populated only on indexes with meta.trigram=1. Skip entirely on
        // indexes that never enabled it (empty table = no signal anyway).
        guard store.trigramEnabled else { return [] }
        var atoms: [String] = []
        var seen: Set<String> = []
        for raw in query.components(separatedBy: CharacterSet.alphanumerics.inverted) {
            for v in [raw, foldText(raw)] where v.count >= 3 {
                if seen.insert(v).inserted { atoms.append(v) }
            }
            if atoms.count >= 12 { break }
        }
        guard !atoms.isEmpty else { return [] }
        let match = atoms.prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")
        return try store.pool.read { db in
            var sql = """
                SELECT c.id, f.path, c.start_line, c.end_line, c.kind, c.symbol,
                       bm25(chunks_trigram) AS rank
                FROM chunks_trigram
                JOIN chunks c ON c.id = chunks_trigram.rowid
                JOIN files f ON f.id = c.file_id
                WHERE chunks_trigram MATCH ?
                """
            var args: [DatabaseValueConvertible] = [match]
            if let p = pathFilter, !p.isEmpty {
                sql += " AND f.path LIKE ?"
                args.append(p.hasSuffix("/") ? p + "%" : p + "/%")
            }
            if !excluding.isEmpty {
                let excl = excluding.map { String($0) }.joined(separator: ",")
                sql += " AND c.id NOT IN (\(excl))"
            }
            sql += " ORDER BY rank, path LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchHit(
                    chunkID: (row["id"] as? Int64) ?? -1, path: (row["path"] as? String) ?? "",
                    startLine: Int((row["start_line"] as? Int64) ?? 0), endLine: Int((row["end_line"] as? Int64) ?? 0),
                    kind: row["kind"] as? String, symbol: row["symbol"] as? String,
                    score: -((row["rank"] as? Double) ?? 0), snippet: "")
            }
        }
    }

    /// Result bag for the concurrent legs in `hybridCandidates`. Each
    /// property is written by exactly one leg closure and read only after
    /// `group.wait()`, which establishes the happens-before edge; the lock
    /// guards only the error slot (any leg may fail).
    private final class LegBag: @unchecked Sendable {
        var fts: [SearchHit] = []
        var vec: [SearchHit] = []
        var sym: [SearchHit] = []
        var phrase: [SearchHit] = []
        private var _err: Error?
        private let lock = NSLock()
        func note(_ e: Error) { lock.lock(); if _err == nil { _err = e }; lock.unlock() }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _err }
    }

    /// Result slot for the translation leg — unlike the LegBag properties
    /// it can be read while its writer is still running (fusion proceeds
    /// past the deadline mid-flight), so the slot is lock-guarded rather
    /// than wait-ordered.
    private final class XlateBag: @unchecked Sendable {
        private var _hits: [SearchHit] = []
        private var _terms: [String] = []
        private let lock = NSLock()
        func set(_ h: [SearchHit], terms: [String]) {
            lock.lock(); _hits = h; _terms = terms; lock.unlock()
        }
        var hits: [SearchHit] { lock.lock(); defer { lock.unlock() }; return _hits }
        var terms: [String] { lock.lock(); defer { lock.unlock() }; return _terms }
    }
}
