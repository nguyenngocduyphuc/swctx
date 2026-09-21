import Foundation
import GRDB

/// Git history → records ledger. Each commit becomes a `kind="commit"`
/// record (title: `<sha12> <subject>`, payload: author/date/files) so
/// `search_records` can answer temporal questions — "when did X change,
/// why". Commit rows carry no anchors/head_sha: a commit is an immutable
/// historical fact — files it touched being deleted later does not make
/// the record stale.
///
/// Incremental: meta `git_history_head` stores the last-ingested SHA; the
/// next run walks `<head>..HEAD`. Rebase/rewrite breaks the range → falls
/// back to a bounded full log with per-sha dedup.
public enum GitHistory {

    private static let fs = "\u{1f}"   // field sep
    private static let rs = "\u{1e}"   // record sep
    private static let headKey = "git_history_head"

    /// Ingest up to `limit` commits. Returns rows inserted.
    @discardableResult
    public static func ingest(store: Store, limit: Int = 300) -> Int {
        let root = store.workspaceRoot.path
        // rev-parse covers nested workspaces inside a bigger repo — .git
        // may live several levels up.
        guard runGit(root: root, args: ["rev-parse", "--git-dir"]) != nil
        else { return 0 }
        // Scope the log to this subtree and strip the repo-relative
        // prefix so recorded paths stay workspace-relative.
        let prefix = (runGit(root: root,
            args: ["rev-parse", "--show-prefix"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let head: String? = try? store.pool.read { db in
            try String.fetchOne(db, sql:
                "SELECT value FROM meta WHERE key = ?", arguments: [headKey])
        }
        var spec = head.map { ["\($0)..HEAD"] } ?? ["-n", "\(limit)"]
        var out = gitLog(root: root, spec: spec)
        if out == nil && head != nil {          // rebased: full walk + dedup
            spec = ["-n", "\(limit)"]
            out = gitLog(root: root, spec: spec)
        }
        guard let out, !out.isEmpty else { return 0 }

        let known = knownSHAs(store: store)
        var inserted = 0
        var newestSHA: String?
        for block in out.components(separatedBy: rs) {
            let lines = block.split(separator: "\n",
                                    omittingEmptySubsequences: true)
            guard let first = lines.first else { continue }
            let f = first.split(separator: fs)
            guard f.count >= 4 else { continue }
            let sha = String(f[0])
            if newestSHA == nil { newestSHA = sha }
            if known.contains(String(sha.prefix(12))) { continue }
            let files = lines.dropFirst().map { String($0) }
                .filter { !$0.isEmpty && $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
            let payload: [String: Any] = [
                "sha": sha, "author": String(f[2]), "date": String(f[3]),
                "files": files.prefix(50).map { $0 }]
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload) else { continue }
            _ = try? store.insertRecord(
                kind: "commit", source: "git", status: "completed",
                title: "\(sha.prefix(12)) \(f[1])",
                payloadJSON: String(decoding: data, as: UTF8.self))
            inserted += 1
        }
        if let newestSHA {
            try? store.pool.write { db in
                try db.execute(sql:
                    "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)",
                    arguments: [headKey, newestSHA])
            }
        }
        return inserted
    }

    private static func gitLog(root: String, spec: [String]) -> String? {
        runGit(root: root, args:
            ["log"] + spec +
            ["--format=\(rs)%H\(fs)%s\(fs)%an\(fs)%aI",
             "--name-only", "--", "."])
    }

    private static func runGit(root: String, args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root] + args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func knownSHAs(store: Store) -> Set<String> {
        (try? store.pool.read { db in
            Set(try String.fetchAll(db, sql:
                "SELECT substr(title,1,12) FROM records WHERE kind='commit'"))
        }) ?? []
    }
}
