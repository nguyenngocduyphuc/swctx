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
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            sem.signal()
        }
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
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            sem.signal()
        }
        if sem.wait(timeout: .now() + .seconds(5)) == .timedOut {
            p.terminate()
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").contains { $0.contains(root.path) }
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
                FROM records ORDER BY id DESC LIMIT 5
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
            warnings.append("\(stale) stale files — run `swctx index`")
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
        let warnings = (s["warnings"] as? [String]) ?? []
        md += "Warnings:\n"
        if warnings.isEmpty { md += "- none\n" }
        for w in warnings { md += "- \(w)\n" }
        return md
    }
}
