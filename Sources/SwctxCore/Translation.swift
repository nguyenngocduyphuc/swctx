import CryptoKit
import Foundation

/// vn→en translation assist (W11): a small local Ollama model turns a
/// diacritic-carrying Vietnamese query into a few English search terms,
/// which feed one extra lexical/path candidate leg in
/// `Search.hybridCandidates`. The leg is a rescue — never on the critical
/// path of the first result: a hard deadline (~800ms) kills the whole
/// subprocess group, and any failure/timeout/Ollama-absent case silently
/// degrades to the baseline legs. No translated semantic leg, no query
/// rewrite — the terms only build an FTS MATCH.
public enum Translation {
    /// Prompt contract version — part of the cache key, so a prompt change
    /// invalidates old entries without touching the file format.
    static let promptVersion = "v5"

    /// `SWCTX_TRANSLATE=0` disables the leg entirely (the probe's baseline
    /// arm; also the kill switch if a host has a broken Ollama).
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SWCTX_TRANSLATE"] != "0"
    }
    static var model: String {
        ProcessInfo.processInfo.environment["SWCTX_TRANSLATE_MODEL"]
            ?? "qwen2.5:3b"
    }
    /// Result deadline in milliseconds — how long fusion may wait for the
    /// leg beyond the real legs (~800ms; measured warm qwen2.5:3b calls run
    /// ~400-700ms). Past this the result ships without translated terms.
    static var deadlineMs: Int {
        Int(ProcessInfo.processInfo.environment["SWCTX_TRANSLATE_MS"] ?? "")
            ?? 800
    }
    /// Hard cap for the subprocess itself, in milliseconds. Deliberately
    /// longer than `deadlineMs`: a generation that misses the result window
    /// is cancelled FOR THAT RESULT but allowed to finish so its terms land
    /// in the cache for the next query — killing it mid-flight would make
    /// the leg dead code on hardware where a cold model load alone exceeds
    /// the result deadline. The cap still guarantees a hung `ollama run`
    /// dies; the whole process group is killed.
    static var spawnCapMs: Int {
        Int(ProcessInfo.processInfo.environment["SWCTX_TRANSLATE_SPAWN_MS"] ?? "")
            ?? 6000
    }

    /// Cheap deterministic gate: the query carries diacritic-bearing
    /// letters. Same criterion as `foldedVariantTokens` — foldText folds
    /// case AND diacritics, so comparing against lowercased() isolates the
    /// diacritic part ("Đăng nhập" → "dang nhap" ≠ "đăng nhập"; "CRM"
    /// folds to itself; ASCII/emoji/CJK never fire).
    static func needsTranslation(_ query: String) -> Bool {
        enabled && Search.foldText(query) != query.lowercased()
    }

    /// Tokens that must survive translation verbatim: identifier-shaped
    /// whitespace tokens (snake_case, paths, dotted/hyphenated names,
    /// letter-digit mixes like GA4/D1, camelCase, ALLCAPS). Returned in
    /// query order, deduped; callers compare against the model's echoed
    /// `protected_tokens` list.
    static func protectedTokens(_ query: String) -> [String] {
        let edge = CharacterSet(charactersIn: ".,;:!?\"'(){}[]<>")
        var out: [String] = []
        var seen: Set<String> = []
        for raw in query.components(separatedBy: .whitespacesAndNewlines) {
            let t = raw.trimmingCharacters(in: edge)
            guard t.count >= 2 else { continue }
            let shaped = t.range(of: #"[_/.:\-]"#, options: .regularExpression) != nil
                || t.range(of: #"[a-zA-Z][0-9]|[0-9][a-zA-Z]|[a-z][A-Z]|[A-Z]{2,}"#,
                           options: .regularExpression) != nil
            if shaped, seen.insert(t).inserted { out.append(t) }
            if out.count >= 12 { break }
        }
        return out
    }

    static func prompt(for query: String) -> String {
        // Single-line, capped — the query travels as one argv element.
        let q = String(query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(400))
        // One-shot example: qwen2.5:3b without a demonstration tends to
        // return english_terms: [] and dump the whole query into
        // protected_tokens (observed live). The example pins both the JSON
        // shape and the translation behavior.
        return """
        Translate a Vietnamese code-search query into English search terms \
        and guess the filename vocabulary of the file it describes.
        Query: bộ não phân tích SEO đọc dữ liệu GSC GA4 rồi gọi DeepSeek sinh hành động
        Reply: {"english_terms": ["SEO brain", "GSC GA4 data", "DeepSeek actions"], "filename_terms": ["brain", "seo_brain", "bo_nao", "phan_tich", "analyze"], "protected_tokens": ["SEO", "GSC", "GA4", "DeepSeek"]}
        Rules: english_terms has 2-4 short terms (1-2 words each) an English \
        code search can match. filename_terms has 6-14 likely filename \
        atoms — lowercase ASCII snake_case or single words — covering BOTH \
        English and unaccented Vietnamese for each key concept, plus the \
        parts of every compound ("link_health" -> "link", "health"). \
        Filename jargon by task — emit cluster words as STANDALONE \
        single tokens ("health", not just "health_check"): \
        summary->digest,recap,brief,so_tay,tom_tat; \
        check->health,audit,scan,kiem_tra; importer->ingest,nap; \
        doc->sop,workflow,playbook,quy_trinh; controller->ctl,cmd. \
        protected_tokens copies identifiers, file names, paths and \
        acronyms from the query EXACTLY character-for-character (never \
        translate them); [] if none. Reply with ONLY the JSON object, \
        one line.
        Query: \(q)
        Reply:
        """
    }

    // MARK: - VN lexicon (deterministic morpheme map)

    /// Folded-VN phrase → English filename terms. The 3B translator is
    /// nondeterministic — the SAME prompt rendered "bộ não" as "brain"
    /// in one run and "cognitive engine" in another — but filename
    /// probes need a stable atom to be useful. This table is the
    /// retrieval equivalent of accent folding: a fixed lexical
    /// resource, matched on whitespace boundaries of the folded query.
    /// Longest phrase wins; single-word entries only fill in when no
    /// phrase covered that token. Terms land in `plannerProbeAtoms`
    /// like model translations do — rare ones become solo path probes.
    static let vnLexicon: [(String, [String])] = [
        // phrases first — a 2-3 word unit is the reliable signal
        ("bo nao", ["brain"]),
        ("doi ham", ["fleet"]),
        ("doi ngu", ["team", "roster"]),
        ("nhat ky", ["log", "journal"]),
        ("thoi gian thuc", ["live", "realtime"]),
        ("tinh trang", ["status"]),
        ("trang thai", ["status"]),
        ("liet ke", ["list"]),
        ("hoat dong", ["activity"]),
        ("phan tich", ["analysis"]),
        ("du lieu", ["data"]),
        ("bao cao", ["report"]),
        ("kich ban", ["script"]),
        ("tap lenh", ["script"]),
        ("nguoi dung", ["user"]),
        ("nhan vien", ["employee", "staff"]),
        ("nhan su", ["hr", "staff"]),
        ("khach hang", ["customer"]),
        ("don hang", ["order"]),
        ("hoa don", ["invoice"]),
        ("thanh toan", ["payment"]),
        ("giao dich", ["transaction"]),
        ("cham cong", ["attendance"]),
        ("tinh luong", ["payroll", "salary"]),
        ("ton kho", ["inventory"]),
        ("nha cung cap", ["supplier", "vendor"]),
        ("thong bao", ["notification"]),
        ("canh bao", ["alert"]),
        ("lich su", ["history"]),
        ("theo doi", ["monitor", "track"]),
        ("giam sat", ["monitor"]),
        ("kiem tra", ["check"]),
        ("danh gia", ["review"]),
        ("dong bo", ["sync"]),
        ("sao luu", ["backup"]),
        ("khoi phuc", ["restore", "recovery"]),
        ("lap lich", ["schedule"]),
        ("len lich", ["schedule"]),
        ("lich trinh", ["schedule"]),
        ("dang nhap", ["login"]),
        ("dang xuat", ["logout"]),
        ("mat khau", ["password"]),
        ("thu muc", ["folder", "directory"]),
        ("trang web", ["site", "website"]),
        ("bai viet", ["post", "article"]),
        ("noi dung", ["content"]),
        ("tieu de", ["title"]),
        ("mo ta", ["description"]),
        ("hieu suat", ["performance"]),
        ("tu khoa", ["keyword"]),
        ("tim kiem", ["search"]),
        ("xep hang", ["rank", "ranking"]),
        ("thong ke", ["stats"]),
        ("cong cu", ["tool"]),
        ("tu dong", ["auto", "automation"]),
        ("xac thuc", ["auth"]),
        ("bao mat", ["security"]),
        ("san pham", ["product"]),
        ("ke hoach", ["plan"]),
        ("su kien", ["event"]),
        ("diem danh", ["attendance", "checkin"]),
        ("ghi so", ["ledger"]),
        ("cong no", ["debt"]),
        ("tuyen dung", ["recruit"]),
        ("so cai", ["ledger", "book"]),
        ("giao viec", ["gui", "assign", "task"]),
        ("doc", ["read", "reader"]),
        ("phan hoi", ["feedback"]),
        ("bi chan", ["blocked"]),
        ("ap dung", ["apply"]),
        ("goi y", ["suggest", "recommend"]),
        ("minh hoa", ["illustrate", "illustration"]),
        ("sinh anh", ["image"]),
        ("noi bo", ["internal"]),
        ("danh muc", ["catalog", "category"]),
        ("danh sach", ["list"]),
        ("quan ly", ["manage", "admin"]),
        ("cai dat", ["config", "settings"]),
        ("cau hinh", ["config"]),
        ("tai khoan", ["account"]),
        ("phan quyen", ["permission", "role"]),
        ("chuc nang", ["feature", "function"]),
        ("giao dien", ["ui", "interface"]),
        ("truy van", ["query"]),
        ("ket noi", ["connect", "connection"]),
        ("tin nhan", ["message"]),
        ("binh luan", ["comment"]),
        ("gio hang", ["cart"]),
        ("thanh vien", ["member"]),
        ("hop dong", ["contract"]),
        ("bao gia", ["quote"]),
        ("quy trinh", ["workflow", "process"]),
        ("lo trinh", ["roadmap"]),
        ("phe duyet", ["approve", "approval"]),
        ("mac dinh", ["default"]),
        ("co san", ["available", "existing"]),
        ("tai len", ["upload"]),
        ("tai xuong", ["download"]),
        ("dang ky", ["register", "signup"]),
        ("quen mat khau", ["reset", "password"]),
        ("nhap lieu", ["input", "entry"]),
        ("xuat file", ["export"]),
        ("nhap file", ["import"]),
        ("sap xep", ["sort"]),
        ("cap nhat", ["update"]),
        // single-word fallbacks — only when the phrase missed.
        // NOTE: no "nao" entry — "nào" (which) is a function word and
        // folding makes it indistinguishable from "não" (brain); the
        // "bo nao" phrase above carries the brain mapping safely.
        // Same reason: no "dang" (đang/progressive vs đăng/post) and no
        // "mau" (màu/color vs mẫu/template) — both fire on function words.
        ("luong", ["salary", "payroll"]),
        ("kho", ["warehouse", "stock"]),
        ("loi", ["error", "bug"]),
        ("tep", ["file"]),
        ("anh", ["image"]),
        ("lich", ["schedule"]),
        ("chon", ["select"]),
        ("tao", ["create"]),
        ("them", ["add"]),
        ("xoa", ["delete", "remove"]),
        ("sua", ["edit", "fix"]),
        ("gui", ["send", "submit"]),
        ("loc", ["filter"]),
    ]

    /// English terms from the lexicon for `query`, matched on token
    /// boundaries of the folded query. Free, deterministic — never a
    /// model call. Longest patterns first so "thoi gian thuc" beats a
    /// bare "thuc".
    static func lexiconTerms(for query: String) -> [String] {
        let folded = " " + Search.foldText(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        var out: [String] = []
        var seen: Set<String> = []
        for (pattern, terms) in vnLexicon.sorted(by: {
            $0.0.count > $1.0.count
        }) where folded.contains(" \(pattern) ") {
            for t in terms where seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    /// Tool-suffix conventions for command-shaped queries. This corpus
    /// names its CLIs `*_ctl`/`p8ctl`/`sitectl` — a suffix the path
    /// tokenizer can't expose to prefix probes and a 3B emits only on
    /// a lucky roll. Deterministic atoms cost one LIKE scan each.
    static func commandSuffixAtoms(for query: String) -> [String] {
        let folded = " " + Search.foldText(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        let triggers = [" lenh ", " command ", " cli ", " tool ",
                        " tien ich ", " cong cu "]
        return triggers.contains(where: { folded.contains($0) })
            ? ["ctl", "cli", "cmd"] : []
    }

    // MARK: - EN→VN lexicon (the missing direction)

    /// English phrase/word → folded-VN filename atoms. The mirror of
    /// `vnLexicon`: an English query against a repo whose files are named
    /// in Vietnamese ("detecting when work finishes" → BietXong.swift)
    /// carries zero VN atoms, so the filename probe and folded FTS can
    /// never reach them. These atoms feed the same probe path the
    /// vnLexicon terms use — deterministic, free, no model call.
    /// Longest EN pattern wins on word boundaries of the lowercased
    /// query; values are FOLDED VN atoms (diacritics stripped), matching
    /// `pathTokenString` output.
    static let enLexicon: [(String, [String])] = [
        // multi-word first
        ("one after another", ["noi", "tiep", "tuan", "tu"]),
        ("daily report", ["bao", "cao", "ngay"]),
        ("assigned work", ["giao", "gui", "viec", "xong"]),
        ("finished", ["xong", "hoan", "thanh"]),
        ("detecting", ["biet", "phat", "hien"]),
        ("detect", ["biet", "phat", "hien"]),
        ("assign", ["giao", "gui", "viec"]),
        ("task", ["viec", "cong"]),
        ("job", ["viec", "cong"]),
        ("work", ["viec", "cong"]),
        ("report", ["bao", "cao"]),
        ("summary", ["tom", "tat", "tong", "hop"]),
        ("daily", ["ngay", "hang"]),
        ("command", ["lenh"]),
        ("sequential", ["noi", "tiep", "tuan", "tu"]),
        ("chain", ["noi", "tiep", "chuoi"]),
        ("schedule", ["hen", "lich"]),
        ("remind", ["nhac", "hen"]),
        ("notification", ["thong", "bao"]),
        ("ledger", ["so", "ghi"]),
        ("read", ["doc", "xem"]),
        ("record", ["ghi", "nhat", "ky"]),
        ("log", ["nhat", "ky", "ghi"]),
        ("count", ["dem"]),
        ("token", ["token"]),
        ("session", ["phien"]),
        ("history", ["lich", "su"]),
        ("conversation", ["hoi", "thoai"]),
        ("chat", ["hoi", "thoai"]),
        ("kanban", ["kanban", "bang"]),
        ("board", ["bang"]),
        ("keyboard", ["phim"]),
        ("shortcut", ["tat", "phim"]),
        ("config", ["cai", "dat", "cau", "hinh"]),
        ("settings", ["cai", "dat"]),
        ("monitor", ["giam", "sat", "theo", "doi"]),
        ("resource", ["tai", "nguyen"]),
        ("store", ["kho", "luu"]),
        ("employee", ["nhan", "vien"]),
        ("staff", ["nhan", "vien"]),
        ("customer", ["khach", "hang"]),
        ("order", ["don", "hang"]),
        ("invoice", ["hoa", "don"]),
        ("payment", ["thanh", "toan"]),
        ("search", ["tim", "kiem"]),
        ("sync", ["dong", "bo"]),
        ("backup", ["sao", "luu"]),
        ("login", ["dang", "nhap"]),
        ("password", ["mat", "khau"]),
        ("file", ["tep", "tin"]),
        ("folder", ["thu", "muc"]),
        ("user", ["nguoi", "dung"]),
        ("team", ["doi", "nhom"]),
        ("event", ["su", "kien"]),
        ("attendance", ["diem", "danh"]),
        ("checkin", ["diem", "danh"]),
        ("error", ["loi"]),
        ("image", ["anh", "hinh"]),
        ("title", ["tieu", "de"]),
        ("content", ["noi", "dung"]),
        ("keyword", ["tu", "khoa"]),
        ("security", ["bao", "mat"]),
        ("auth", ["xac", "thuc"]),
        ("auto", ["tu", "dong"]),
        ("performance", ["hieu", "suat"]),
        ("feedback", ["phan", "hoi"]),
        ("blocked", ["bi", "chan"]),
        ("plan", ["ke", "hoach"]),
        ("tool", ["cong", "cu"]),
        ("alert", ["canh", "bao"]),
        ("check", ["kiem", "tra"]),
        ("review", ["danh", "gia"]),
        ("restore", ["khoi", "phuc"]),
        ("website", ["trang", "web"]),
        ("article", ["bai", "viet"]),
        ("description", ["mo", "ta"]),
        ("product", ["san", "pham"]),
        ("supplier", ["nha", "cung", "cap"]),
        ("inventory", ["ton", "kho"]),
        ("warehouse", ["kho"]),
        ("salary", ["luong", "tinh"]),
        ("payroll", ["cham", "cong", "luong"]),
        ("internal", ["noi", "bo"]),
    ]

    /// Folded-VN atoms for an English query, matched on word boundaries.
    /// Fires regardless of query language — patterns are English words so
    /// a VN query simply matches nothing.
    static func vnTerms(for query: String) -> [String] {
        let folded = " " + query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        var out: [String] = []
        var seen: Set<String> = []
        for (pattern, terms) in enLexicon.sorted(by: {
            $0.0.count > $1.0.count
        }) where folded.contains(" \(pattern) ") {
            for t in terms where seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    /// VN morphemes seen in filenames — union of both lexicons' atom
    /// vocabularies. Used to detect whether a corpus actually names files
    /// in Vietnamese (BietXong.swift has no diacritics, so the diacritic
    /// gate can't see it); only then is the EN→VN leg worth its atoms.
    static let vnMorphemes: Set<String> = {
        var s = Set<String>()
        for (k, _) in vnLexicon {
            for t in k.split(separator: " ") { s.insert(String(t)) }
        }
        for (_, vs) in enLexicon {
            for v in vs { s.insert(v) }
        }
        return s
    }()

    private static let vnCorpusCache = VNCorpusCache()

    final class VNCorpusCache: @unchecked Sendable {
        private var map: [ObjectIdentifier: Bool] = [:]
        private let lock = NSLock()
        func get(_ store: Store) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return map[ObjectIdentifier(store)]
        }
        func put(_ store: Store, _ v: Bool) {
            lock.lock(); defer { lock.unlock() }
            map[ObjectIdentifier(store)] = v
        }
    }

    /// True when ≥1 indexed file's folded path tokens contain a VN
    /// morpheme. One basename scan per Store, cached for the process —
    /// file lists change under the watcher but a corpus's language mix
    /// is stable enough for a session.
    static func corpusHasVNFilenames(store: Store) -> Bool {
        if let c = vnCorpusCache.get(store) { return c }
        let paths = (try? store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM files")
        }) ?? []
        var found = false
        outer: for p in paths {
            for tok in Search.pathTokenString(p).split(separator: " ") {
                if vnMorphemes.contains(String(tok)) { found = true; break outer }
            }
        }
        vnCorpusCache.put(store, found)
        return found
    }

    // MARK: - Cache (bounded LRU, outside the index DB)

    /// One small JSON file shared by all workspaces
    /// (~/.swctx/translate_cache.json; SWCTX_TRANSLATE_CACHE overrides, used
    /// by tests). Key = sha256(promptVersion | model | normalized query) —
    /// the index `meta` table is never touched. Cap ~500 entries,
    /// oldest-use evicted; the file is a derived cache, safe to delete.
    final class Cache: @unchecked Sendable {
        private struct Entry: Codable {
            var t: [String]      // english_terms
            var f: [String]?     // filename_terms (reformulation atoms)
            var u: TimeInterval  // last use
        }
        private struct File: Codable {
            var v: Int
            var e: [String: Entry]
        }
        private let url: URL
        private let cap: Int
        private let lock = NSLock()
        private var entries: [String: Entry]?
        private var dirty = false

        init(url: URL, cap: Int = 500) {
            self.url = url
            self.cap = cap
        }

        func get(_ key: String) -> [String]? {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            guard var e = entries?[key] else { return nil }
            e.u = Date().timeIntervalSince1970
            entries?[key] = e
            return e.t
        }

        /// filename_terms for the same cache key — nil when the entry
        /// predates the reformulation prompt (v4+ writes both lists).
        func getFilenameTerms(_ key: String) -> [String]? {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            guard var e = entries?[key] else { return nil }
            e.u = Date().timeIntervalSince1970
            entries?[key] = e
            return e.f
        }

        func put(_ key: String, terms: [String],
                 filenames: [String] = []) {
            lock.lock(); defer { lock.unlock() }
            // Merge-on-write: this process's in-memory map can be older than
            // the file (another swctx process put() in between), while the
            // in-memory map holds fresher use-times from get() touches that
            // were never persisted. Keep disk entries but let the newest
            // use-time win per key, so a stale rewrite neither drops their
            // entries nor revives an evicted ordering.
            let mem = entries
            entries = nil
            loadLocked()
            if let mem {
                for (k, v) in mem
                where v.u > (entries?[k]?.u ?? 0) {
                    entries?[k] = v
                }
            }
            entries?[key] = Entry(t: terms, f: filenames.isEmpty ? nil : filenames,
                                  u: Date().timeIntervalSince1970)
            while (entries?.count ?? 0) > cap,
                  let oldest = entries?.min(by: { $0.value.u < $1.value.u })?.key {
                entries?.removeValue(forKey: oldest)
            }
            persistLocked()
        }

        private func loadLocked() {
            if entries != nil { return }
            entries = [:]
            guard let data = try? Data(contentsOf: url),
                  let f = try? JSONDecoder().decode(File.self, from: data),
                  f.v == 1 else { return }
            entries = f.e
        }

        private func persistLocked() {
            guard let entries else { return }
            let f = File(v: 1, e: entries)
            guard let data = try? JSONEncoder().encode(f) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static let sharedCache = Cache(url: defaultCacheURL())

    /// Mutable process state behind one lock — the enum itself stays
    /// stateless so Swift 6 concurrency checks pass. Holds the failure
    /// cooldown window plus the test-seam cache override.
    final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var cooldownUntil = Date.distantPast
        var cacheOverride: Cache?
        var round2CacheOverride: Cache?
    }
    static let state = StateBox()
    /// Test seam — when set, lookups consult this cache instead of the
    /// shared file. Never set in production paths.
    static var cacheOverride: Cache? {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.cacheOverride }
        set { state.lock.lock(); state.cacheOverride = newValue; state.lock.unlock() }
    }
    static var activeCache: Cache { cacheOverride ?? sharedCache }
    /// Same seam for the round-2 cache.
    static var round2CacheOverride: Cache? {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.round2CacheOverride }
        set { state.lock.lock(); state.round2CacheOverride = newValue; state.lock.unlock() }
    }
    static var activeRound2Cache: Cache { round2CacheOverride ?? round2Cache }

    static func defaultCacheURL() -> URL {
        if let p = ProcessInfo.processInfo.environment["SWCTX_TRANSLATE_CACHE"],
           !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return Store.baseDir().appendingPathComponent("translate_cache.json")
    }

    static func cacheKey(_ query: String) -> String {
        let norm = query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let d = SHA256.hash(
            data: Data("\(promptVersion)\u{0}\(model)\u{0}\(norm)".utf8))
        return d.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Failure cooldown

    /// Two windows: a FAST failure (spawn error, nonzero exit, connect
    /// refused) means Ollama is down — sit out a minute. A timeout usually
    /// means the model is still loading daemon-side — retry soon, because
    /// the daemon typically finishes the load after our client dies.
    private static let failCooldownSeconds: TimeInterval = 60
    private static let timeoutCooldownSeconds: TimeInterval = 8

    private static func inCooldown() -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return Date() < state.cooldownUntil
    }
    private static func tripCooldown(_ seconds: TimeInterval) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.cooldownUntil = Date().addingTimeInterval(seconds)
    }

    /// Test seam — clears cooldown and the cache override.
    static func resetForTesting() {
        state.lock.lock()
        state.cooldownUntil = .distantPast
        state.cacheOverride = nil
        state.round2CacheOverride = nil
        state.lock.unlock()
    }

    // MARK: - Ollama subprocess

    /// `ollama` binary: SWCTX_OLLAMA override (tests point it at a stub
    /// script) — when set it is authoritative: an explicit-but-missing
    /// path means "unavailable", not PATH fallback. Otherwise PATH scan,
    /// same convention as AskCmd.resolveAgent.
    static func ollamaBin() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let c = env["SWCTX_OLLAMA"], !c.isEmpty {
            return FileManager.default.isExecutableFile(atPath: c) ? c : nil
        }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let cand = "\(dir)/ollama"
            if FileManager.default.isExecutableFile(atPath: cand) { return cand }
        }
        return nil
    }

    /// English terms for a diacritic query, or nil on any failure — never
    /// throws, never blocks past the deadline. Order: gate → cache →
    /// cooldown → spawn → validate → store. SWCTX_TRANSLATE_DEBUG=1 logs
    /// skip/failure reasons to stderr (bench debugging; silent by default).
    static func englishTerms(for query: String) -> [String]? {
        func dbg(_ s: String) {
            if ProcessInfo.processInfo.environment["SWCTX_TRANSLATE_DEBUG"] == "1" {
                FileHandle.standardError.write(
                    "swctx-translate: \(s)\n".data(using: .utf8)!)
            }
        }
        guard needsTranslation(query) else { return nil }
        let key = cacheKey(query)
        if let hit = activeCache.get(key) { return hit }
        guard !inCooldown() else { dbg("cooldown"); return nil }
        guard let bin = ollamaBin() else { dbg("no ollama bin"); return nil }
        // Up to two generations, terms unioned: a 3B model's per-roll term
        // choice varies a lot — one roll drops "worker", the next drops
        // "image". Merging both rolls widens the path-atom net; the FTS
        // leg's own ranking keeps extra atoms cheap. Malformed output only
        // costs the attempt. Attempts run on the background leg — the
        // result deadline is enforced by the caller's wait, not here.
        var merged: [String] = []
        var mergedFilenames: [String] = []
        var seen: Set<String> = []
        var seenFile: Set<String> = []
        for _ in 0...1 {
            switch spawn(bin, argv: ["run", model, prompt(for: query)],
                         timeoutMs: spawnCapMs) {
            case .ok(let raw):
                guard let reply = parseReply(raw, query: query) else {
                    dbg("invalid output: \(raw.prefix(160))")
                    continue
                }
                for t in reply.terms where seen.insert(t.lowercased()).inserted {
                    merged.append(t)
                }
                // Reformulation guesses ride the same roll — two
                // generations union the same way terms do.
                for t in reply.filenames
                where seenFile.insert(t.lowercased()).inserted {
                    mergedFilenames.append(t)
                }
            case .timedOut:
                dbg("timeout \(spawnCapMs)ms")
                tripCooldown(timeoutCooldownSeconds)
            case .failed:
                dbg("spawn/run failed")
                tripCooldown(failCooldownSeconds)
                return merged.isEmpty ? nil
                    : finalize(merged, filenames: mergedFilenames, key: key)
            }
            if inCooldown() { break }
        }
        return merged.isEmpty ? nil
            : finalize(merged, filenames: mergedFilenames, key: key)
    }

    /// Reformulation atoms guessed by the model — READS the cache only.
    /// The filename vocabulary rides the `englishTerms` generation (one
    /// prompt, two lists), so callers check this AFTER the translation
    /// leg has run; a nil means no roll landed in time and the query
    /// proceeds on baseline terms.
    static func filenameTerms(for query: String) -> [String]? {
        guard needsTranslation(query) else { return nil }
        return activeCache.getFilenameTerms(cacheKey(query))
    }

    private static func finalize(_ terms: [String], filenames: [String],
                                 key: String) -> [String] {
        let capped = Array(terms.prefix(6))
        activeCache.put(key, terms: capped,
                        filenames: Array(filenames.prefix(16)))
        if ProcessInfo.processInfo.environment["SWCTX_TRANSLATE_DEBUG"] == "1" {
            FileHandle.standardError.write(
                "swctx-translate: terms=\(capped) files=\(filenames.prefix(16))\n"
                    .data(using: .utf8)!)
        }
        return capped
    }

    /// Subprocess outcome: `.ok(stdout)` only on a clean exit-0. Timeout
    /// is reported separately from other failures because it implies a
    /// slow-but-alive daemon (worth retrying soon) while `.failed`
    /// implies absent/down (worth sitting out).
    enum SpawnResult: Equatable {
        case ok(String)
        case failed
        case timedOut
    }

    /// `ollama run` leaks terminal-control bytes into piped stdout — its
    /// spinner redraws mid-stream (ESC[<n>D back-n + ESC[K clear-to-EOL),
    /// leaving half-written tokens inside the JSON (observed live:
    /// `"protected_\x1B[11D\x1B[K\n" protected_tokens"`). Reconstruct what
    /// a terminal would show: a line buffer where CSI nD/nC/nG move the
    /// cursor, K truncates to EOL, \r returns to column 0, printable bytes
    /// write at the cursor (overwriting), and other CSI sequences are
    /// ignored. Approximate for multi-byte columns — fine: the result is
    /// still validated as JSON before use.
    static func unspin(_ s: String) -> String {
        var lines: [[UInt8]] = [[]]
        var cur = 0
        let bytes = [UInt8](s.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B, i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "[") {
                var j = i + 2
                var num = ""
                while j < bytes.count,
                      bytes[j] == UInt8(ascii: "?") || bytes[j] == UInt8(ascii: ";")
                      || (bytes[j] >= UInt8(ascii: "0") && bytes[j] <= UInt8(ascii: "9")) {
                    num.append(Character(UnicodeScalar(bytes[j])))
                    j += 1
                }
                if j < bytes.count {
                    let n = max(1, num.split(separator: ";").first
                        .flatMap { Int($0) } ?? 1)
                    switch bytes[j] {
                    case UInt8(ascii: "D"): cur = max(0, cur - n)
                    case UInt8(ascii: "C"): cur += n
                    case UInt8(ascii: "G"): cur = max(0, n - 1)
                    case UInt8(ascii: "K"):
                        if cur < lines[lines.count - 1].count {
                            lines[lines.count - 1].removeSubrange(cur...)
                        }
                    default: break  // other CSI (hide cursor, colours): ignore
                    }
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }
            if b == UInt8(ascii: "\r") { cur = 0; i += 1; continue }
            if b == UInt8(ascii: "\n") { lines.append([]); cur = 0; i += 1; continue }
            while lines[lines.count - 1].count < cur {
                lines[lines.count - 1].append(UInt8(ascii: " "))
            }
            if cur < lines[lines.count - 1].count {
                lines[lines.count - 1][cur] = b
            } else {
                lines[lines.count - 1].append(b)
            }
            cur += 1
            i += 1
        }
        return lines.map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
    }

    /// Parse + validate model output. Rejects: empty/oversized stdout
    /// (the model rambled — a real answer is a few hundred bytes), no JSON
    /// object, empty english_terms, or a `protected_tokens` list that does
    /// not echo every protected token extracted from the ORIGINAL query
    /// verbatim — an altered identifier means the model rewrote the query,
    /// so the whole translation is discarded.
    static func parseTerms(_ raw: String, query: String) -> [String]? {
        parseReply(raw, query: query)?.terms
    }

    /// Full parse: english_terms (content-leg vocabulary) plus
    /// filename_terms (guessed filename atoms for the path probe —
    /// the reformulation leg). english_terms still validates the
    /// whole reply: a model that breaks the translation contract gets
    /// its filename guesses discarded with it.
    static func parseReply(_ raw: String,
                           query: String) -> (terms: [String],
                                              filenames: [String])? {
        guard !raw.isEmpty, raw.utf8.count <= 8192 else { return nil }
        let text = unspin(raw)
        guard let l = text.firstIndex(of: "{") else { return nil }
        // Small repair pass: observed outputs can drop the final `}` (or
        // the `]}` pair) under the token cap — try the verbatim span first,
        // then single-suffix repairs. Everything still goes through full
        // validation, so a repair can only recover a well-formed prefix.
        var obj: [String: Any]?
        if let r = text.lastIndex(of: "}"), l < r {
            obj = try? JSONSerialization.jsonObject(
                with: Data(text[l...r].utf8)) as? [String: Any]
        }
        if obj == nil {
            for suffix in ["}", "]}", "\"]}"] {
                if let o = try? JSONSerialization.jsonObject(
                    with: Data((text[l...] + suffix).utf8)) as? [String: Any] {
                    obj = o
                    break
                }
            }
        }
        guard let obj else { return nil }
        // unspin reconstruction can leave a redraw space inside a key
        // (" protected_tokens") — trim keys before field lookup.
        var norm: [String: Any] = [:]
        norm.reserveCapacity(obj.count)
        for (k, v) in obj {
            norm[k.trimmingCharacters(in: .whitespaces)] = v
        }
        guard let arr = norm["english_terms"] as? [Any] else { return nil }
        let required = Set(protectedTokens(query))
        if !required.isEmpty {
            // Every protected token from the ORIGINAL query must survive
            // verbatim somewhere in the reply. Accepted forms: a whole
            // array entry, or an atom inside a multi-word english_term
            // (observed live: "h2 headers missing images" carries h2). A
            // missing or rewritten token still rejects.
            let termStrings = arr.compactMap { $0 as? String }
            let termAtoms = termStrings.flatMap {
                $0.components(separatedBy: CharacterSet.alphanumerics.inverted)
            }.filter { !$0.isEmpty }
            let prot = (norm["protected_tokens"] as? [Any]) ?? []
            let got = Set(prot.compactMap { $0 as? String })
                .union(termStrings).union(termAtoms)
            guard required.isSubset(of: got) else { return nil }
        }
        var terms: [String] = []
        var seen: Set<String> = []
        for item in arr {
            guard terms.count < 12 else { break }
            guard let s = (item as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  s.count >= 2, s.count <= 64,
                  s.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _\-]*$"#,
                          options: .regularExpression) != nil,
                  seen.insert(s.lowercased()).inserted else { continue }
            terms.append(s)
        }
        guard !terms.isEmpty else { return nil }
        // filename_terms: same token shape, optional — older cached
        // prompt versions emitted none and degrade to [].
        var filenames: [String] = []
        if let farr = norm["filename_terms"] as? [Any] {
            for item in farr {
                guard filenames.count < 16 else { break }
                guard let s = (item as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      s.count >= 2, s.count <= 40,
                      s.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _\-]*$"#,
                              options: .regularExpression) != nil,
                      seen.insert(s.lowercased()).inserted else { continue }
                filenames.append(s)
            }
        }
        return (terms, filenames)
    }

    /// `ollama run <model> <prompt>` under a hard deadline. Same spawn
    /// shape as AskCmd.spawn — posix_spawn + POSIX_SPAWN_SETPGROUP puts
    /// the child in its own process group at spawn time (no setpgid race),
    /// both pipes drain concurrently with the wait (a >64KB write would
    /// otherwise block the child in write() forever), and timeout kills
    /// the whole group so descendants die with it. `.ok(stdout)` on a
    /// clean exit-0 only — the caller degrades silently either way.
    static func spawn(_ bin: String, argv: [String], timeoutMs: Int) -> SpawnResult {
        let out = Pipe()
        let err = Pipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // stdin is /dev/null, never inherited — inside `swctx mcp` our own
        // stdin is the JSON-RPC pipe and a reading child would eat client
        // requests.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
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
        posix_spawnattr_setpgroup(&attr, 0)   // own group: pgid == child pid

        var pid: pid_t = 0
        var cargs = ([bin] + argv).map { strdup($0) }
            + [nil as UnsafeMutablePointer<CChar>?]
        defer { cargs.forEach { free($0) } }
        let rc = cargs.withUnsafeMutableBufferPointer { cargv in
            posix_spawnp(&pid, bin, &actions, &attr, cargv.baseAddress,
                         environ)
        }
        // Parent drops its write ends so read sees EOF when the last
        // child-side writer (direct or descendant) closes.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        guard rc == 0 else {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            return .failed
        }

        // NSMutableData: a class reference, so the drain closures mutate
        // through it without capturing a var (keeps Sendable checks quiet).
        final class WaitStatus { var raw: Int32 = -1 }
        let wstatus = WaitStatus()
        let outData = NSMutableData()
        let errData = NSMutableData()
        let drain = DispatchGroup()
        // Drains and the waiter all run on dedicated Threads — a GCD
        // block can sit unscheduled under load, so the timeout would
        // measure queue latency (then SIGKILL a live group) and pipe
        // bytes could go undrained past the grace bound.
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
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            // Whole-group SIGTERM, short grace, then whole-group SIGKILL —
            // TERM-ignoring children AND their descendants all die.
            kill(-pid, SIGTERM)
            _ = sem.wait(timeout: .now() + .milliseconds(300))
            kill(-pid, SIGKILL)
            // Closing our read ends unblocks drain workers stuck in
            // readDataToEndOfFile if any survivor still held the pipe.
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = drain.wait(timeout: .now() + .seconds(2))
            return .timedOut
        }
        // Same bound on the success path: an exited child whose descendants
        // keep a pipe write-end open must not hang the caller or leak the
        // drains.
        if drain.wait(timeout: .now() + .seconds(5)) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = drain.wait(timeout: .now() + .seconds(2))
        }
        let st = wstatus.raw
        guard st & 0x7f == 0, (st >> 8) & 0xff == 0 else { return .failed }
        return .ok(String(decoding: outData as Data, as: UTF8.self))
    }

    // MARK: - Round-2 reformulation

    /// Second local model pass for queries whose round-1 filename probe
    /// found nothing confident: the model sees the query and the paths
    /// round-1 actually returned, then either PICKS the answering file
    /// by number or names the vocabulary of the file that should exist
    /// (`missing_terms`). Same discipline as the translation leg — one
    /// cached generation, a result deadline that never gates the first
    /// answer, and silent degradation on every failure. The pick only
    /// reorders paths we already returned; the missing atoms feed a
    /// second `plannerPathProbe` as champion-eligible weak atoms (never
    /// surgical — a model guess must not crown).
    static let round2PromptVersion = "r2v6"

    /// `SWCTX_ROUND2=0` disables the pass; `SWCTX_TRANSLATE=0` also kills
    /// it (same model-call kill switch).
    static var round2Enabled: Bool {
        enabled
            && ProcessInfo.processInfo.environment["SWCTX_ROUND2"] != "0"
    }
    /// How long a result may wait for the generation. The model is
    /// typically warm from the round-1 translation, so one roll lands
    /// in ~300-700ms; cold loads miss the window but still finish (the
    /// spawn cap) and cache for the next query.
    static var round2DeadlineMs: Int {
        Search.envInt("SWCTX_ROUND2_MS", 1500)
    }

    /// Separate cache file — keyed on the QUERY only. Keying on the
    /// shown paths proliferated entries: fused-order jitter (embedder
    /// timing, partial rolls) rekeys the same question and each new key
    /// re-rolls the model — the bench observed one query generating
    /// three different atom sets. A stale entry under a changed index
    /// is harmless: guessed atoms are only probed, never trusted.
    static let round2Cache = Cache(url: defaultRound2CacheURL())

    static func defaultRound2CacheURL() -> URL {
        if let p = ProcessInfo.processInfo.environment["SWCTX_ROUND2_CACHE"],
           !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return Store.baseDir().appendingPathComponent("round2_cache.json")
    }

    static func round2Key(_ query: String) -> String {
        let norm = query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let material = "\(round2PromptVersion)\u{0}\(model)\u{0}\(norm)"
        let d = SHA256.hash(data: Data(material.utf8))
        return d.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func round2Prompt(for query: String,
                             seenPaths: [String]) -> String {
        let q = String(query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(400))
        // Kind tags per path — a 3B asked for a "script" will otherwise
        // pick a .json manifest whose name merely mentions the thing
        // (observed live: all_article_links.json chosen over the tool).
        let list = seenPaths.enumerated()
            .map { "\($0.offset + 1). \($0.element) [\(kindTag($0.element))]" }
            .joined(separator: "\n")
        // The pick is a NUMBER, not a path echo — a 3B model cannot
        // reproduce long paths verbatim reliably, and a digit is the
        // strictest possible contract.
        return """
        A code search returned these files for the query below. Which file \
        answers it? If none fits, what filename SHOULD the answering file have?
        Query: \(q)
        Files:
        \(list)
        Reply: {"pick": <file number 1-\(seenPaths.count), or 0 if none answers the query>, "missing_terms": ["<filename atom>", ...]}
        Rules: pick the file whose NAME does the job the query asks — when \
        the query wants a tool/command/script that produces something, a \
        listed data/output file of that something is NOT the answer: pick \
        0 and name the producer in missing_terms (e.g. the mesh builder is \
        "sitectl" or "site_ctl", not "entity.json"). missing_terms has 0-6 \
        lowercase ASCII filename atoms — snake_case or single words — the \
        filename vocabulary of the file that SHOULD exist. They must be NEW \
        names, not atoms already present in the listed filenames — echoing \
        a shown name wastes the turn (the search already found that file). \
        Filename jargon: \
        command/tool->ctl,cmd,cli; workflow/process->workflow,sop,quy_trinh; \
        apply/inject->apply,inject,insert; sync/unify->sync,unify,merge,dong_bo; \
        summary->digest,so_tay,tom_tat,nhat_ky; check->health,audit,kiem_tra. \
        [] when a pick was made. Reply with ONLY the JSON object, one line.
        Reply:
        """
    }

    /// Coarse file-kind tag for the round-2 pick list: code / doc /
    /// data / config / other, from the extension only.
    static func kindTag(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "ts", "tsx", "js", "jsx", "swift", "go", "rs", "sh",
             "rb", "java", "kt", "c", "cc", "cpp", "m", "mm", "mjs":
            return "code"
        case "md", "txt", "rst", "adoc", "html":
            return "doc"
        case "json", "jsonl", "csv", "tsv", "yaml", "yml", "xml", "sql":
            return "data"
        case "toml", "ini", "conf", "cfg", "env":
            return "config"
        default: return "other"
        }
    }

    /// Names-only variant for later rolls: NO result list — a 3B shown
    /// ten paths anchors on them and echoes a shown filename as its
    /// "missing" guess (observed live: the seo-10 roll emitted
    /// "internal-link-check", a listed file's own name). Asking only for
    /// the missing filename keeps the roll's entropy on vocabulary.
    static func round2NamesPrompt(for query: String) -> String {
        let q = String(query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(400))
        return """
        A code search for this query found only loosely related files — the \
        file that truly answers it was missed. Guess that file's NAME.
        Query: \(q)
        Reply: {"missing_terms": ["<filename atom>", ...]}
        Rules: 3-8 lowercase ASCII filename atoms — snake_case or single \
        words — the naming vocabulary of the file that SHOULD exist. \
        Filename jargon: command/tool->ctl,cmd,cli; \
        workflow/process->workflow,sop,quy_trinh; \
        apply/inject->apply,inject,insert; \
        sync/unify->sync,unify,merge,dong_bo; \
        summary->digest,so_tay,tom_tat,nhat_ky; \
        check->health,audit,kiem_tra. Cover both the action verb and the object \
        ("apply internal links" -> apply,inject,link,internal_link). \
        Reply with ONLY the JSON object, one line.
        Reply:
        """
    }

    /// Parse + validate a round-2 reply. pick must be an Int inside
    /// 1...seenPaths.count (0 = "none answered"); missing_terms follows
    /// the filename_terms token rules. A reply breaking the contract is
    /// discarded wholesale — same posture as `parseReply`.
    static func parseRound2(_ raw: String,
                            seenPaths: [String]) -> (atoms: [String],
                                                   pick: String?)? {
        guard !raw.isEmpty, raw.utf8.count <= 4096 else { return nil }
        let text = unspin(raw)
        guard let l = text.firstIndex(of: "{") else { return nil }
        var obj: [String: Any]?
        if let r = text.lastIndex(of: "}"), l < r {
            obj = try? JSONSerialization.jsonObject(
                with: Data(text[l...r].utf8)) as? [String: Any]
        }
        if obj == nil {
            for suffix in ["}", "]}", "\"]}"] {
                if let o = try? JSONSerialization.jsonObject(
                    with: Data((text[l...] + suffix).utf8)) as? [String: Any] {
                    obj = o
                    break
                }
            }
        }
        guard let obj else { return nil }
        var pick: String?
        // JSONSerialization yields NSNumber; accept "3" too (models do).
        let pickNum: Int? = (obj["pick"] as? NSNumber)?.intValue
            ?? (obj["pick"] as? String).flatMap(Int.init)
        if let n = pickNum, n >= 1, n <= seenPaths.count {
            pick = seenPaths[n - 1]
        }
        var atoms: [String] = []
        var seen: Set<String> = []
        if let arr = obj["missing_terms"] as? [Any] {
            for item in arr {
                guard atoms.count < 8 else { break }
                guard let s = (item as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      s.count >= 2, s.count <= 40,
                      s.range(of: #"^[A-Za-z0-9][A-Za-z0-9_\-]*$"#,
                              options: .regularExpression) != nil,
                      seen.insert(s.lowercased()).inserted else { continue }
                atoms.append(s)
            }
        }
        guard pick != nil || !atoms.isEmpty else { return nil }
        return (atoms, pick)
    }

    /// Round-2 atoms + pick for (query, seenPaths), or nil. Blocking
    /// caller path: cache hit returns immediately; a miss spawns ONE
    /// generation on a background queue and waits `deadlineMs` — the
    /// generation itself is allowed `spawnCapMs` so a late answer still
    /// lands in cache for the next identical window.
    static func round2(query: String, seenPaths: [String],
                       deadlineMs: Int? = nil) -> (atoms: [String],
                                                   pick: String?)? {
        @Sendable func dbg(_ s: String) {
            if ProcessInfo.processInfo.environment["SWCTX_TRANSLATE_DEBUG"] == "1" {
                FileHandle.standardError.write(
                    "swctx-round2: \(s)\n".data(using: .utf8)!)
            }
        }
        guard round2Enabled, !seenPaths.isEmpty else { return nil }
        let key = round2Key(query)
        if let atoms = activeRound2Cache.get(key) {
            return (atoms, activeRound2Cache.getFilenameTerms(key)?.first)
        }
        guard !inCooldown() else { dbg("cooldown"); return nil }
        guard let bin = ollamaBin() else { dbg("no ollama bin"); return nil }
        let deadline = deadlineMs ?? round2DeadlineMs
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { sema.signal() }
            // Three rolls of two kinds: roll 1 judges the shown list
            // (pick + missing atoms); rolls 2-3 run the names-only
            // prompt — no list to anchor on, so their entropy stays on
            // vocabulary instead of echoing shown names. Atoms union,
            // first non-zero pick wins. Each roll's merge lands in the
            // cache immediately — a deadline that cuts roll 3 still
            // leaves earlier rolls usable for this query AND the next.
            var mergedAtoms: [String] = []
            var mergedPick: String?
            var seenAtom: Set<String> = []
            for roll in 0..<3 {
                let prompt = roll == 0
                    ? round2Prompt(for: query, seenPaths: seenPaths)
                    : round2NamesPrompt(for: query)
                switch spawn(bin, argv: ["run", model, prompt],
                             timeoutMs: spawnCapMs) {
                case .ok(let raw):
                    guard let r = parseRound2(raw, seenPaths: seenPaths)
                    else {
                        dbg("invalid output: \(raw.prefix(160))")
                        continue
                    }
                    for a in r.atoms
                    where seenAtom.insert(a.lowercased()).inserted {
                        mergedAtoms.append(a)
                    }
                    if mergedPick == nil { mergedPick = r.pick }
                    if !mergedAtoms.isEmpty || mergedPick != nil {
                        activeRound2Cache.put(
                            key, terms: mergedAtoms,
                            filenames: mergedPick.map { [$0] } ?? [])
                    }
                case .timedOut:
                    dbg("timeout \(spawnCapMs)ms")
                    tripCooldown(timeoutCooldownSeconds)
                case .failed:
                    dbg("spawn/run failed")
                    tripCooldown(failCooldownSeconds)
                }
                if inCooldown() { break }
            }
        }
        if deadline > 0 {
            _ = sema.wait(timeout: .now() + .milliseconds(deadline))
        }
        // Read the cache again either way — a slow generation that beat
        // neither deadline nor cap is nil now but cached for next time;
        // a just-late one may have landed between wait and read.
        guard let atoms = activeRound2Cache.get(key) else { return nil }
        return (atoms, activeRound2Cache.getFilenameTerms(key)?.first)
    }
}
