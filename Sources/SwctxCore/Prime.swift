import Foundation
import GRDB

/// `swctx prime` — a compact Markdown "context card" (~300-400 tokens) an
/// agent can paste into its prompt to orient in a workspace instantly:
/// heading + git branch, index counts, freshness, watcher state, hub symbols
/// by resolved-edge degree, recent records, and actionable warnings. Every
/// section degrades silently — the only hard failure is an unindexed
/// workspace, which the CLI layer rejects before reaching here.
public enum Prime {

    /// Run `bin args`, return trimmed stdout. nil on spawn failure, nonzero
    /// exit, empty output, or timeout — probes must never break the card.
    static func probe(_ bin: String, _ args: [String], timeout: Int = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let sem = DispatchSemaphore(value: 0)
        // Dedicated Thread — a GCD block can sit unscheduled under load
        // and turn the timeout into a queue-latency measurement.
        Thread {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            sem.signal()
        }.start()
        if sem.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Tri-state watcher probe: nil = could not determine, true/false =
    /// alive/dead. `pgrep -fl` prints `pid argv`; a watcher counts as alive
    /// only when its command line names this workspace root, so a watch on a
    /// different workspace does not report a false positive.
    static func watcherAlive(root: URL) -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-fl", "swctx watch"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let sem = DispatchSemaphore(value: 0)
        // Dedicated Thread — same GCD-starvation hazard as `probe`.
        Thread {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            sem.signal()
        }.start()
        if sem.wait(timeout: .now() + .seconds(5)) == .timedOut {
            p.terminate()
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").contains { $0.contains(root.path) }
    }

    /// "Since your last session": diff the worktree against the newest
    /// global-ledger anchor for this repo (checkpoint or any head-stamped
    /// record — the last agent contact). `git diff --name-only <sha>`
    /// covers committed AND dirty tracked edits; `git status --porcelain`
    /// adds untracked files. Repo-relative paths drop the cwd prefix for
    /// the `indexed` mark (files table is workspace-relative). Every git
    /// probe degrades silently: a base whose diff fails reports
    /// `note: diff unavailable`, and no anchor at all → nil → the payload
    /// emits `since_last_session: null`.
    static func sinceLastSession(store: Store, root: URL) -> [String: Any]? {
        guard let g = GlobalRecords.shared,
              let base = try? g.latestCheckpoint(
                  ws: GlobalRecords.repoKey(for: root))
        else { return nil }
        var sect: [String: Any] = [
            "base_sha": base.headSHA,
            "base_kind": base.kind,
            "base_title": Understand.truncHead(base.title, 60),
            "base_at": base.createdAt,
        ]
        // Run diff/status at the repo root so both emit repo-relative
        // paths (status.relativePaths is cwd-relative otherwise).
        let repoRoot = GlobalRecords.git(["rev-parse", "--show-toplevel"],
                                         cwd: root)
            .map { URL(fileURLWithPath: $0) } ?? root
        if let head = GlobalRecords.git(["rev-parse", "HEAD"], cwd: repoRoot),
           !head.isEmpty {
            sect["head_sha"] = head
        }
        let prefix = GlobalRecords.git(["rev-parse", "--show-prefix"],
                                       cwd: root) ?? ""
        var changed: [(path: String, untracked: Bool)] = []
        var seen = Set<String>()
        var diffOK = false
        if let diff = GlobalRecords.git(
            ["diff", "--name-only", base.headSHA], cwd: repoRoot) {
            diffOK = true
            for p in diff.split(separator: "\n").map(String.init)
            where !p.isEmpty && seen.insert(p).inserted {
                changed.append((p, false))
            }
        }
        if let st = GlobalRecords.git(["status", "--porcelain"],
                                      cwd: repoRoot) {
            for line in st.split(separator: "\n") where line.hasPrefix("??") {
                var p = String(line.dropFirst(3))
                if p.count > 1, p.hasPrefix("\""), p.hasSuffix("\"") {
                    p = String(p.dropFirst().dropLast())
                }
                if !p.isEmpty, seen.insert(p).inserted {
                    changed.append((p, true))
                }
            }
        }
        guard diffOK else {
            sect["note"] = "diff unavailable"
            return sect
        }
        sect["changed_total"] = changed.count
        let relPaths = changed.map {
            $0.path.hasPrefix(prefix)
                ? String($0.path.dropFirst(prefix.count)) : $0.path
        }
        let indexed = (try? store.pool.read { db -> Set<String> in
            guard !relPaths.isEmpty else { return [] }
            let ph = relPaths.map { _ in "?" }.joined(separator: ",")
            return Set(try String.fetchAll(db, sql:
                "SELECT path FROM files WHERE path IN (\(ph))",
                arguments: StatementArguments(
                    relPaths.map { $0 as DatabaseValueConvertible })))
        }) ?? []
        sect["changed"] = changed.prefix(10).enumerated().map { (i, c) in
            var d: [String: Any] = [
                "path": c.path, "indexed": indexed.contains(relPaths[i])]
            if c.untracked { d["untracked"] = true }
            return d
        }
        return sect
    }

    /// Top-3 fleet records whose text names this workspace — decisions
    /// and findings filed under a sibling repo's ws still apply to this
    /// checkout. A floor (≥2 term-hits when the name has ≥2 terms) keeps
    /// generic names from surfacing noise, and names with no ≥3-char
    /// token ("ai", "21") skip the section entirely. `shown` carries
    /// titles the card already lists so each record appears once.
    static func relevantRecords(root: URL, excluding shown: Set<String>)
        -> [[String: Any]]? {
        guard let g = GlobalRecords.shared else { return nil }
        let terms = GlobalRecords.foldedTerms(root.lastPathComponent)
        guard terms.contains(where: { $0.count >= 3 }) else { return nil }
        guard let hits = try? g.searchRanked(
            query: root.lastPathComponent,
            kinds: ["decision", "note", "finding"], limit: 8)
        else { return nil }
        let floor = min(2.0, Double(terms.count))
        let top = hits.filter {
            (($0["score"] as? Double) ?? 0) >= floor
                && !shown.contains(($0["title"] as? String) ?? "")
        }.prefix(3)
        guard !top.isEmpty else { return nil }
        return top.map {
            ["id": ($0["id"] as? Int64) ?? -1,
             "ws": ($0["ws"] as? String) ?? "",
             "kind": ($0["kind"] as? String) ?? "",
             "title": Understand.truncHead(($0["title"] as? String) ?? "", 60)]
        }
    }

    /// Everything the card (and --format json) needs, gathered once.
    public static func snapshot(store: Store, root: URL) throws -> [String: Any] {
        var out: [String: Any] = ["workspace": root.path, "name": root.lastPathComponent]
        if let branch = probe("/usr/bin/git",
                              ["-C", root.path, "rev-parse", "--abbrev-ref", "HEAD"]) {
            out["branch"] = branch
        }
        // Recent-record rows are fetched inside the read but judged by
        // staleCheck after it — the check opens its own read + git probe.
        var recent: [Row] = []
        try store.pool.read { db in
            out["schema"] = try String.fetchOne(db, sql:
                "SELECT value FROM meta WHERE key = 'schema_version'") ?? "?"
            out["files"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
            out["chunks"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            out["symbols"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM symbols") ?? 0
            out["edges"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges") ?? 0
            out["vectors"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0
            if let t = try Double.fetchOne(db, sql: "SELECT MAX(indexed_at) FROM files") {
                out["last_indexed_at"] = t
            }
            // Hub symbols by resolved-edge in+out degree: incoming via
            // e.dst_chunk (resolved only), outgoing via e.src_chunk.
            out["hub_symbols"] = try Row.fetchAll(db, sql: """
                SELECT name, SUM(d) AS deg FROM (
                    SELECT s.id AS sid, s.name AS name, COUNT(*) AS d
                    FROM symbols s JOIN edges e ON e.dst_chunk = s.chunk_id
                    WHERE s.chunk_id IS NOT NULL GROUP BY s.id
                    UNION ALL
                    SELECT s.id, s.name, COUNT(*)
                    FROM symbols s JOIN edges e ON e.src_chunk = s.chunk_id
                    WHERE s.chunk_id IS NOT NULL GROUP BY s.id
                ) GROUP BY sid ORDER BY deg DESC, sid LIMIT 8
                """).map { r -> [String: Any] in
                    ["name": Understand.truncHead((r["name"] as? String) ?? "", 28),
                     "deg": (r["deg"] as? Int64) ?? 0]
                }
            // Records table may be absent on pre-v2 DBs — degrade to [].
            recent = (try? Row.fetchAll(db, sql: """
                SELECT kind, title, head_sha, anchors
                FROM records ORDER BY (kind = 'commit'), id DESC LIMIT 5
                """)) ?? []
        }
        // Staleness marking: the card flags records whose captured anchors
        // no longer verify, and the count feeds a warning below.
        let checks = store.staleCheck(recent.map {
            (headSHA: $0["head_sha"] as? String,
             anchors: Store.decodeAnchors($0["anchors"] as? String))
        })
        var staleRecords = 0
        out["records"] = recent.indices.map { i -> [String: Any] in
            var d: [String: Any] = [
                "kind": (recent[i]["kind"] as? String) ?? "",
                "title": Understand.truncHead((recent[i]["title"] as? String) ?? "", 60),
            ]
            if checks[i].stale { d["stale"] = true; staleRecords += 1 }
            return d
        }
        out["stale_records"] = staleRecords
        // Prior work: the shared ledger aggregates agent-authored memory
        // from every checkout/workspace of this repo. Surfacing its newest
        // rows lets a fresh session notice a sibling project already
        // investigated the same subject instead of redoing it — the agent
        // follows up with search_records scope=global.
        if let g = GlobalRecords.shared,
           let rows = try? g.pool.read({ db in
               try Row.fetchAll(db, sql: """
                   SELECT kind, title FROM records
                   WHERE kind IN ('note','finding','decision','todo',
                                  'session_checkpoint')
                   ORDER BY id DESC LIMIT 3
                   """)
           }), !rows.isEmpty {
            let total = (try? g.pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM records
                    WHERE kind IN ('note','finding','decision','todo',
                                   'session_checkpoint')
                    """)
            }) ?? rows.count
            // put_record dual-writes: skip titles the workspace ledger
            // already surfaced in `records` so the card shows each once.
            let shown = Set(recent.compactMap { $0["title"] as? String })
            let others = rows.filter {
                !shown.contains((($0["title"] as? String) ?? ""))
            }
            out["prior_work_total"] = total
            out["prior_work"] = others.map { r -> [String: Any] in
                ["kind": (r["kind"] as? String) ?? "",
                 "title": Understand.truncHead(
                    (r["title"] as? String) ?? "", 60)]
            }
        }
        // Resume: newest session_checkpoint FOR THIS REPO carries a
        // next-step so the incoming session picks up exactly where the
        // last one stopped. The ws predicate matters — an unscoped newest
        // row made every workspace inherit some other repo's resume line.
        if let g = GlobalRecords.shared,
           let row = try? g.pool.read({ db in
               try Row.fetchOne(db, sql: """
                   SELECT title, payload FROM records
                   WHERE kind='session_checkpoint' AND ws = ?
                   ORDER BY id DESC LIMIT 1
                   """, arguments: [GlobalRecords.repoKey(for: root)])
           }) {
            var resume = (row["title"] as? String) ?? ""
            if let payload = (row["payload"] as? String)?.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: payload)
                       as? [String: Any],
               let next = obj["next"] as? String, !next.isEmpty {
                resume += " → next: " + Understand.truncHead(next, 120)
            }
            out["resume"] = resume
        }
        // Session resume: the diff since the newest head-stamped ledger
        // row for this repo. Always present — null when no prior session
        // left an anchor (or the global ledger is unavailable).
        out["since_last_session"] = Self.sinceLastSession(store: store,
                                                        root: root) ?? NSNull()
        // Fleet memory relevant to THIS workspace by name — distinct from
        // prior_work (newest rows) and records (this workspace's ledger):
        // a decision filed under another repo still applies here.
        var shownTitles = Set(recent.compactMap { $0["title"] as? String })
        shownTitles.formUnion((out["prior_work"] as? [[String: Any]] ?? [])
            .compactMap { $0["title"] as? String })
        if let rel = Self.relevantRecords(root: root, excluding: shownTitles) {
            out["relevant_records"] = rel
        }
        // Freshness: the same shallow stat probe get_status runs by default
        // (indexed rows only — no directory walk).
        let indexer = Indexer(store: store, embedder: store.embedder)
        if let f = try? indexer.freshness(deep: false) {
            out["stale_files"] = f.staleCount
            out["changed_files"] = f.changedPaths.count
            out["deleted_files"] = f.deletedPaths.count
        }
        out["pending_embeddings"] = (try? indexer.pendingEmbeddings()) ?? 0
        if let alive = watcherAlive(root: root) { out["watcher_alive"] = alive }

        var warnings: [String] = []
        if let stale = out["stale_files"] as? Int, stale > 0 {
            // Staleness as a feature: the warning says it, and the
            // reindex_command field lets an agent act without composing
            // the command itself.
            warnings.append("\(stale) stale files — run `swctx index \(root.path)`")
            out["reindex_command"] = "swctx index \(root.path)"
        }
        if let n = out["stale_records"] as? Int, n > 0 {
            warnings.append(
                "\(n) stale record\(n == 1 ? "" : "s") — verify against current code")
        }
        let chunks = (out["chunks"] as? Int) ?? 0
        let pending = (out["pending_embeddings"] as? Int) ?? 0
        if chunks > 0, Double(pending) / Double(chunks) > 0.10 {
            warnings.append("\(pending) chunks missing vectors — run `swctx embed`")
        }
        if out["watcher_alive"] as? Bool == false {
            warnings.append("watcher not running — `swctx watch \(root.path)`")
        }
        if let t = out["last_indexed_at"] as? Double {
            let days = Int((Date().timeIntervalSince1970 - t) / 86400)
            if days > 7 { warnings.append("index is \(days)d old — run `swctx index`") }
        }
        out["warnings"] = warnings
        return out
    }

    /// Terse Markdown rendering of `snapshot`.
    public static func card(store: Store, root: URL) throws -> String {
        let s = try snapshot(store: store, root: root)
        var md = "## \(s["name"] as? String ?? root.lastPathComponent)\n"
        if let b = s["branch"] as? String { md += "Branch: \(b)\n" }
        let chunks = (s["chunks"] as? Int) ?? 0
        let vectors = (s["vectors"] as? Int) ?? 0
        md += "Index: \(s["files"] ?? 0) files · \(chunks) chunks"
            + " · \(s["symbols"] ?? 0) symbols · \(s["edges"] ?? 0) edges"
            + " · \(vectors)/\(chunks) vectors · schema v\(s["schema"] ?? "?")\n"
        if let stale = s["stale_files"] as? Int {
            md += "Freshness: \(stale) stale"
                + " (\(s["changed_files"] ?? 0) changed · \(s["deleted_files"] ?? 0) deleted)\n"
        }
        if let alive = s["watcher_alive"] as? Bool {
            md += "Watcher: \(alive ? "alive" : "not running")\n"
        }
        if let hubs = s["hub_symbols"] as? [[String: Any]], !hubs.isEmpty {
            md += "Hub symbols: " + hubs.map {
                "\($0["name"] ?? "") (\($0["deg"] ?? 0))"
            }.joined(separator: ", ") + "\n"
        }
        if let recs = s["records"] as? [[String: Any]], !recs.isEmpty {
            md += "Recent:\n"
            for r in recs {
                md += "- \((r["kind"] as? String) ?? ""): \((r["title"] as? String) ?? "")"
                if r["stale"] as? Bool == true { md += " ·stale" }
                md += "\n"
            }
        }
        if let resume = s["resume"] as? String, !resume.isEmpty {
            md += "Resume: \(resume)\n"
        }
        if let sls = s["since_last_session"] as? [String: Any] {
            let sha7 = String(((sls["base_sha"] as? String) ?? "").prefix(7))
            let changed = (sls["changed"] as? [[String: Any]]) ?? []
            let n = (sls["changed_total"] as? Int) ?? changed.count
            md += "Since last session (\((sls["base_kind"] as? String) ?? "?")"
                + " @\(sha7)): \(n) changed\n"
            for f in changed {
                var tag = ""
                if f["untracked"] as? Bool == true { tag = " (untracked)" }
                else if f["indexed"] as? Bool == false { tag = " (not indexed)" }
                md += "- \((f["path"] as? String) ?? "")\(tag)\n"
            }
        }
        if let rel = s["relevant_records"] as? [[String: Any]], !rel.isEmpty {
            md += "Relevant records (get_record scope=global):\n"
            for r in rel {
                md += "- \((r["kind"] as? String) ?? ""): "
                    + "\((r["title"] as? String) ?? "")\n"
            }
        }
        if let prior = s["prior_work"] as? [[String: Any]], !prior.isEmpty {
            md += "Prior work (\(s["prior_work_total"] ?? prior.count) shared records"
                + " — search_records scope=global):\n"
            for r in prior {
                md += "- \((r["kind"] as? String) ?? ""): \((r["title"] as? String) ?? "")\n"
            }
        }
        let warnings = (s["warnings"] as? [String]) ?? []
        md += "Warnings:\n"
        if warnings.isEmpty { md += "- none\n" }
        for w in warnings { md += "- \(w)\n" }
        return md
    }
}
