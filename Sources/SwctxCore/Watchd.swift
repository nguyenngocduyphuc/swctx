import Foundation
import GRDB

/// Single-daemon watch lifecycle. `swctx watch-all` runs ONE process
/// holding an `IndexWatcher` per workspace listed in
/// `~/.swctx/watchd.json`; the verbs under `swctx watch`
/// (install/uninstall/restart/status/add/remove) manage the
/// `com.swctx.watchd` LaunchAgent and that list.
///
/// This replaces the hand-made per-workspace `com.swctx.watch.*` plists —
/// each of those registered a separate login item, so every plist added
/// one "Background Items Added" notification. One label, one plist, one
/// login item is the whole point of this design.
public enum Watchd {
    public static let label = "com.swctx.watchd"

    /// `~/.swctx/watchd.json` — `{"workspaces": ["/abs/path", ...]}`.
    public static var listURL: URL {
        Store.baseDir().appendingPathComponent("watchd.json")
    }

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var logURL: URL {
        Store.baseDir().appendingPathComponent("logs/watchd.log")
    }

    /// Legacy per-workspace plists this design replaces. Read-only —
    /// `install` lists them as a migration hint; unloading/deleting them
    /// is a deliberate operator step, not something install does silently.
    public static func legacyPlists() -> [URL] {
        let dir = plistURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix("com.swctx.watch.") && $0.hasSuffix(".plist") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - Workspace list (~/.swctx/watchd.json)

    public struct ListFile: Codable {
        public var workspaces: [String]
        public init(workspaces: [String]) { self.workspaces = workspaces }
    }

    /// Workspaces from the list file. Missing file → empty; a file that
    /// exists but cannot be read or does not decode is a real error
    /// (silently treating it as empty would leave the fleet dead with no
    /// visible cause — or let add/remove clobber it).
    public static func loadWorkspaces(from url: URL? = nil) throws -> [String] {
        let url = url ?? listURL
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let e as NSError
            where e.domain == NSCocoaErrorDomain
                && e.code == NSFileReadNoSuchFileError {
            return []
        }
        return try JSONDecoder().decode(ListFile.self, from: data).workspaces
    }

    /// Canonical spelling for list entries: `~` expanded, symlinks and
    /// `.`/`..` resolved — the same identity `Store` uses, so dedupe
    /// compares what the watcher will actually watch.
    public static func normalize(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    private static func save(_ workspaces: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(ListFile(workspaces: workspaces)).write(to: url, options: .atomic)
    }

    /// Add a workspace to the list (creating the file if needed).
    /// Returns the post-write list; `added` is false when the resolved
    /// path was already present.
    @discardableResult
    public static func addWorkspace(_ path: String, to url: URL? = nil) throws
        -> (added: Bool, workspaces: [String])
    {
        let url = url ?? listURL
        let root = normalize(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw NSError(domain: "swctx", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "not a directory: \(root.path)"])
        }
        var ws = try loadWorkspaces(from: url)
        if ws.contains(root.path) { return (false, ws) }
        ws.append(root.path)
        try save(ws, to: url)
        return (true, ws)
    }

    /// Remove a workspace from the list. `removed` is false when the
    /// resolved path was not listed.
    @discardableResult
    public static func removeWorkspace(_ path: String, from url: URL? = nil) throws
        -> (removed: Bool, workspaces: [String])
    {
        let url = url ?? listURL
        let root = normalize(path)
        var ws = try loadWorkspaces(from: url)
        let before = ws.count
        ws.removeAll { $0 == root.path }
        if ws.count != before { try save(ws, to: url) }
        return (ws.count != before, ws)
    }

    // MARK: - launchd lifecycle

    /// Write the LaunchAgent plist and bootstrap it into the gui domain.
    /// `binaryPath` must be this binary's already-resolved absolute path
    /// (see `resolveExecutableOnPATH` in main.swift) — the plist survives
    /// cwd and PATH changes, so no relative or PATH-dependent spelling.
    /// Returns summary lines for the caller to print.
    public static func install(binaryPath: String) throws -> [String] {
        var lines: [String] = []
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "watch-all"],
            // RunAtLoad makes the login item start at login without
            // relying on bootstrap alone; KeepAlive.Crashed respawns on
            // signal death — the schema-drift abort() path — while a
            // clean exit stays down.
            "RunAtLoad": true,
            "KeepAlive": ["Crashed": true],
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        lines.append("wrote \(plistURL.path)")

        let uid = getuid()
        // Idempotent install: drop any previous load of the label, then
        // bootstrap the freshly written plist.
        _ = launchctl(["bootout", "gui/\(uid)/\(label)"])
        let r = launchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        guard r.status == 0 else {
            throw NSError(domain: "swctx", code: Int(r.status),
                userInfo: [NSLocalizedDescriptionKey:
                    "launchctl bootstrap failed: \(r.output)"])
        }
        lines.append("bootstrapped gui/\(uid)/\(label) — logs: \(logURL.path)")

        let legacy = legacyPlists()
        if !legacy.isEmpty {
            lines.append("legacy per-workspace plists still installed "
                + "(boot them out and delete when ready to migrate):")
            lines += legacy.map { "  \($0.path)" }
        }
        return lines
    }

    /// Boot the agent out (ignored if not loaded) and remove the plist.
    public static func uninstall() -> [String] {
        let uid = getuid()
        let r = launchctl(["bootout", "gui/\(uid)/\(label)"])
        var lines = [r.status == 0
            ? "booted out gui/\(uid)/\(label)"
            : "bootout gui/\(uid)/\(label): \(r.output) (ignored)"]
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try? FileManager.default.removeItem(at: plistURL)
            lines.append("removed \(plistURL.path)")
        } else {
            lines.append("no plist at \(plistURL.path)")
        }
        return lines
    }

    /// Kill and relaunch the agent — picks up watchd.json edits.
    public static func restart() throws -> [String] {
        let uid = getuid()
        let r = launchctl(["kickstart", "-k", "gui/\(uid)/\(label)"])
        guard r.status == 0 else {
            throw NSError(domain: "swctx", code: Int(r.status),
                userInfo: [NSLocalizedDescriptionKey:
                    "launchctl kickstart failed: \(r.output) "
                    + "(is \(label) installed? run `swctx watch install`)"])
        }
        return ["kicked gui/\(uid)/\(label)"]
    }

    /// Plist presence, a `launchctl print` state summary, and the
    /// configured workspaces.
    public static func status() -> [String] {
        let uid = getuid()
        var lines = ["plist: \(plistURL.path) "
            + (FileManager.default.fileExists(atPath: plistURL.path)
                ? "(present)" : "(missing — `swctx watch install`)")]
        let r = launchctl(["print", "gui/\(uid)/\(label)"])
        if r.status == 0 {
            var picked: [String] = []
            for key in ["state =", "pid =", "program =", "last exit code"] {
                for raw in r.output.split(separator: "\n") {
                    let t = raw.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(key) { picked.append(t); break }
                }
            }
            lines.append(picked.isEmpty
                ? "launchd: loaded (no state lines parsed)"
                : "launchd: " + picked.joined(separator: " · "))
            // The daemon keeps running the binary it was bootstrapped
            // with — after a rebuild it drifts from what `swctx` is now.
            // Path equality alone misses a same-path overwrite, so also
            // compare the current binary's mtime against the daemon's
            // start time: file newer than the process = it exec'd an
            // older inode that has since been replaced.
            if let pid = launchdPID(r.output),
               let daemonBin = pidPath(pid),
               let current = currentBinaryPath() {
                var same = daemonBin == current
                if same, let mt = fileMtime(current),
                   let started = pidStartTime(pid), mt > started {
                    same = false
                }
                lines.append(same
                    ? "binary_stale: false"
                    : "binary_stale: true (daemon pid \(pid) runs "
                        + "\(daemonBin), current is \(current))")
            }
        } else {
            let first = r.output.split(separator: "\n").first.map(String.init) ?? ""
            lines.append("launchd: not loaded (\(first))")
        }
        let ws: [String]
        do {
            ws = try loadWorkspaces()
        } catch {
            ws = []
            lines.append("workspaces: ERROR reading \(listURL.path): "
                + error.localizedDescription)
        }
        lines.append("workspaces (\(listURL.path)):")
        if ws.isEmpty {
            lines.append("  (none — `swctx watch add <path>`)")
        } else {
            lines += ws.map { "  \($0)\(indexFreshness(for: $0))" }
        }
        return lines
    }

    /// `watch status` per-workspace suffix: the index's own
    /// `meta.last_index_at`/`last_index_files` (written by Indexer at
    /// the end of every pass) read through a read-only probe — status
    /// must never create, migrate or write an index just to report it.
    static func indexFreshness(for workspacePath: String) -> String {
        let db = Store.indexURL(forKey: Store.key(for: normalize(workspacePath)))
        guard FileManager.default.fileExists(atPath: db.path),
              let q = Gc.openReadOnly(db)
        else { return " — no index" }
        guard let meta = try? q.read({ db -> (Double?, Int?) in
            (try String.fetchOne(db, sql:
                "SELECT value FROM meta WHERE key = 'last_index_at'")
                .flatMap(Double.init),
             try String.fetchOne(db, sql:
                "SELECT value FROM meta WHERE key = 'last_index_files'")
                .flatMap(Int.init))
        }), let ts = meta.0 else { return " — index age unknown" }
        let age = max(0, Int(Date().timeIntervalSince1970 - ts))
        let when: String
        if age < 60 { when = "\(age)s ago" }
        else if age < 3600 { when = "\(age / 60)m ago" }
        else if age < 86400 { when = "\(age / 3600)h ago" }
        else { when = "\(age / 86400)d ago" }
        return " — last indexed \(when), \(meta.1 ?? 0) files"
    }

    /// The daemon's pid from `launchctl print` output — present only
    /// while the agent is running.
    static func launchdPID(_ printOutput: String) -> Int32? {
        for raw in printOutput.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid =") {
                return Int32(t.dropFirst(5)
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Real path of the binary `pid` is running — nil when the process
    /// is gone or not inspectable.
    static func pidPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf))
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// This process's binary path, resolved — what `watch install`
    /// would write into the plist today.
    static func currentBinaryPath() -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = UInt32(buf.count)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        let path = String(decoding: buf.prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// When `pid` started, in unix seconds — PROC_PIDTBSDINFO carries
    /// pbi_start_tvsec directly. nil when the process is gone or not
    /// inspectable.
    static func pidStartTime(_ pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                             Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size)
        else { return nil }
        return TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1e6
    }

    /// Modification time of the file at `path`, unix seconds —
    /// nil when it doesn't exist.
    static func fileMtime(_ path: String) -> TimeInterval? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
    }

    /// `launchctl args` → exit status + combined stdout/stderr. Pipes
    /// drain concurrently with the wait (`launchctl print` can exceed
    /// the 64KB pipe buffer) — same discipline as `Prime.probe`.
    @discardableResult
    static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let sem = DispatchSemaphore(value: 0)
        // terminationHandler runs on Foundation's process monitor — a
        // GCD waitUntilExit block could sit unscheduled under load and
        // the timeout would measure queue latency, not launchctl.
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch {
            return (-1, "launchctl spawn failed: \(error.localizedDescription)")
        }
        // NSMutableData: class references — the drain closures mutate
        // through them without capturing vars (Sendable-safe).
        let outData = NSMutableData(), errData = NSMutableData()
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
        if sem.wait(timeout: .now() + .seconds(15)) == .timedOut {
            p.terminate()
            _ = drain.wait(timeout: .now() + .seconds(2))
            return (-1, "launchctl timed out")
        }
        _ = drain.wait(timeout: .now() + .seconds(5))
        let text = String(decoding: outData as Data, as: UTF8.self)
            + String(decoding: errData as Data, as: UTF8.self)
        return (p.terminationStatus,
                text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
