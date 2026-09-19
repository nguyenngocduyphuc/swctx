import CoreServices
import Foundation
import GRDB

/// Watches a workspace root with FSEvents and re-runs the incremental indexer
/// after a debounce window. Lightweight in-process equivalent of ctxe's
/// "daemon watch".
///
/// Concurrency: FSEvents callbacks and the debounce timer live on `queue`;
/// `Indexer.run` executes on `indexQueue` so event delivery is never blocked.
/// All mutable state below is touched only on `queue` (except `stream`,
/// written once in `start()` before events can arrive).
public final class IndexWatcher: @unchecked Sendable {
    private let store: Store
    private let indexer: Indexer
    private let debounce: TimeInterval
    private var ignorePatterns: [String]

    private static let queueKey = DispatchSpecificKey<Bool>()
    private let queue = DispatchQueue(label: "swctx.watch.events")
    private let indexQueue = DispatchQueue(label: "swctx.watch.index")
    private var stream: FSEventStreamRef?
    /// The callback context holds a retained self ref (see `start`); it is
    /// released in `stopOnQueue` only after the stream is invalidated, so a
    /// callback already queued on `queue` can never touch freed memory.
    private var streamInfo: UnsafeMutableRawPointer?
    private var pendingItem: DispatchWorkItem?
    private var indexing = false
    private var rerunRequested = false
    private var stopped = false
    private var gitLockRetries = 0

    /// Git holds `.git/index.lock` while mid-operation (rebase, checkout,
    /// commit); the files it touches flap rapidly and reindexing each
    /// event batch churns the index. A locked root defers the reindex by
    /// `gitLockDelay`, up to `gitLockMaxRetries` times, then proceeds
    /// anyway — a stuck lock must not stall watching forever.
    static let gitLockDelay: TimeInterval = 5
    static let gitLockMaxRetries = 3

    public init(store: Store, debounce: TimeInterval = 1.5) {
        self.store = store
        self.indexer = Indexer(store: store)
        self.debounce = debounce
        self.ignorePatterns = Indexer.loadIgnorePatterns(root: store.workspaceRoot)
        queue.setSpecific(key: IndexWatcher.queueKey, value: true)
    }

    deinit { stop() }

    private func note(_ msg: String) {
        FileHandle.standardError.write("swctx: \(msg)\n".data(using: .utf8)!)
    }

    /// One incremental indexing pass; prints the summary to stderr.
    @discardableResult
    public func indexOnce() throws -> IndexReport {
        exitIfIndexSchemaDrifted()
        let report = try indexer.run(force: false) { msg in self.note(msg) }
        note("watch: indexed \(report.filesIndexed) files (\(report.filesUnchanged) unchanged, \(report.filesDeleted) deleted) chunks=\(report.chunks) symbols=\(report.symbols) edges=\(report.edges) resolved=\(report.edgesResolved) in \(report.durationMs)ms")
        if !report.errors.isEmpty {
            note("watch: \(report.errors.count) errors (first: \(report.errors.first ?? ""))")
        }
        return report
    }

    /// Initial index, then stream FSEvents and reindex on change. Never returns.
    public func start() async throws {
        note("watch: indexing \(store.workspaceRoot.path)")
        _ = try indexOnce()

        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(self).toOpaque()
        streamInfo = context.info
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<IndexWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                if let p = CFArrayGetValueAtIndex(cfPaths, i) {
                    paths.append(Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String)
                }
            }
            var flags: [FSEventStreamEventFlags] = []
            flags.reserveCapacity(numEvents)
            for i in 0..<numEvents { flags.append(eventFlags[i]) }
            watcher.onEventBatch(paths: paths, flags: flags)
        }
        let createFlags = FSEventStreamCreateFlags(
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
                | UInt32(kFSEventStreamCreateFlagFileEvents)
                | UInt32(kFSEventStreamCreateFlagNoDefer))
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [store.workspaceRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, createFlags)
        else {
            // Balance the passRetained above — the stream never existed,
            // so no callback can still arrive; safe to release directly.
            if let info = context.info {
                streamInfo = nil
                Unmanaged<IndexWatcher>.fromOpaque(info).release()
            }
            throw NSError(domain: "swctx", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "FSEventStreamCreate failed"])
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            // Start failed: no events will ever arrive. Tear the stream
            // down and release the retained context instead of looping
            // forever with a dead watcher.
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            if let info = streamInfo {
                streamInfo = nil
                Unmanaged<IndexWatcher>.fromOpaque(info).release()
            }
            throw NSError(domain: "swctx", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "FSEventStreamStart failed"])
        }
        note("watch: streaming FSEvents on \(store.workspaceRoot.path) (debounce \(debounce)s)")

        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    public func stop() {
        // queue.sync from a block already running on `queue` (e.g. deinit
        // triggered inside an event callback) would deadlock — go async there.
        if DispatchQueue.getSpecific(key: IndexWatcher.queueKey) == true {
            queue.async { self.stopOnQueue() }
        } else {
            queue.sync { self.stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        stopped = true
        pendingItem?.cancel()
        pendingItem = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        // Callbacks dispatch on this serial `queue`, so once invalidate has
        // run here no queued callback can still fire — safe to balance the
        // passRetained from start().
        if let info = streamInfo {
            streamInfo = nil
            Unmanaged<IndexWatcher>.fromOpaque(info).release()
        }
    }

    // MARK: - Event filtering (runs on `queue`)

    private func onEventBatch(paths: [String], flags: [FSEventStreamEventFlags]) {
        var relevant = 0
        for (path, f) in zip(paths, flags) {
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                note("watch: workspace root moved or was replaced; index may be stale")
            }
            if isRelevant(path, flags: f) { relevant += 1 }
        }
        guard relevant > 0 else { return }
        scheduleFire()
    }

    /// Mirror `Indexer.discoverFiles` admission rules on a single changed path:
    /// hidden components (except .github), denyDirs, secrets and .gitignore are
    /// rejected; files additionally need a supported language extension.
    private func isRelevant(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            return true
        }
        let rootPath = store.workspaceRoot.path
        guard path != rootPath else { return true }  // the root dir itself changed
        guard path.hasPrefix(rootPath + "/") else { return false }
        let rel = String(path.dropFirst(rootPath.count + 1))
        let comps = rel.split(separator: "/").map(String.init)
        guard let name = comps.last else { return true }
        if comps.contains(where: { $0.hasPrefix(".") && $0 != ".github" }) { return false }
        if comps.contains(where: { Indexer.denyDirs.contains($0) }) { return false }
        if Indexer.isProbablySecret(name) { return false }
        if ignorePatterns.contains(where: { Indexer.matches($0, relPath: rel) }) { return false }
        // Directory-level events can hide bulk changes (a renamed/deleted dir's
        // files get no per-file events) — let them through; the incremental
        // reindex resolves what actually changed.
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
            return true
        }
        return Languages.languageID(forPath: name) != nil
    }

    // MARK: - Git lock

    /// Path of git's `index.lock` for a workspace root, or nil when the
    /// root is not a git work tree. `<root>/.git` as a directory means a
    /// plain repo; as a file it is the worktree/submodule pointer
    /// `gitdir: <path>` (absolute or root-relative) and the lock lives in
    /// the real git dir it names.
    static func gitLockPath(forRoot root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir)
        else { return nil }
        if isDir.boolValue {
            return dotGit.appendingPathComponent("index.lock")
        }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("gitdir:") else { continue }
            let p = line.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespaces)
            let gitDir = p.hasPrefix("/")
                ? URL(fileURLWithPath: p)
                : root.appendingPathComponent(p).standardizedFileURL
            return gitDir.appendingPathComponent("index.lock")
        }
        return nil
    }

    /// True while git holds the workspace's index lock.
    static func isGitLocked(root: URL) -> Bool {
        guard let lock = gitLockPath(forRoot: root) else { return false }
        return FileManager.default.fileExists(atPath: lock.path)
    }

    // MARK: - Schema drift
    //
    // A newer binary migrates the live index in place (Store.migrate), so
    // an outdated watcher must not keep running: it would keep writing
    // rows in the stale layout — the pre-v6 watchers appended chunks with
    // an empty `folded` column after the v6 migration, silently weakening
    // folded rescue per file. GRDB's migrator *tolerates* applied
    // migrations it does not know: an older binary opening a newer index
    // no-ops every migration, then Store.migrate rewrites
    // meta.schema_version down to its own Store.schemaVersion. The
    // durable drift evidence is therefore the grdb_migrations ledger
    // (its rows are never deleted), read together with the meta row.

    /// Pure decision: exit only when the on-disk index schema is
    /// strictly NEWER than this binary's `Store.schemaVersion`. Equal is
    /// the normal case; older needs no action — Store.init migrates it
    /// forward at open.
    static func shouldExitForSchema(indexVersion: Int, binaryVersion: Int) -> Bool {
        indexVersion > binaryVersion
    }

    /// Highest schema version the live index was migrated to: the max of
    /// `meta.schema_version` and every applied GRDB migration's `v<N>`
    /// number. An applied identifier this binary never registered (any
    /// non-"v<N>" id can only come from a newer binary) counts as one
    /// version beyond `Store.schemaVersion` — even when an older binary's
    /// migrate() already rewrote the meta row down. nil when the DB
    /// cannot be read; callers must not treat a read failure as drift.
    func indexSchemaVersion() -> Int? {
        try? store.pool.read { db in
            var version = try String.fetchOne(db,
                sql: "SELECT value FROM meta WHERE key = 'schema_version'")
                .flatMap(Int.init) ?? 0
            let known = Set((1...Store.schemaVersion).map { "v\($0)" })
            for id in try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations") {
                if id.hasPrefix("v"), let n = Int(id.dropFirst()) {
                    version = max(version, n)
                } else if !known.contains(id) {
                    version = max(version, Store.schemaVersion + 1)
                }
            }
            return version
        }
    }

    /// Runs at watcher start (indexOnce is start()'s first act) and
    /// before every Indexer.run — one meta+ledger read per batch. On
    /// forward drift it logs and self-terminates so launchd respawns the
    /// watcher into the current on-disk binary. Termination must be a
    /// crash-signal death, not a clean exit: the com.swctx.watch.* plists
    /// split KeepAlive — cms/crm/qr use {Crashed:true} (respawn only on
    /// signal death, launchd.plist(5)) while linkeldn/p8/sitem use
    /// {SuccessfulExit:false} (respawn on any non-clean termination).
    /// SIGABRT satisfies both policies; exit() would leave the Crashed
    /// group permanently dead.
    private func exitIfIndexSchemaDrifted() {
        guard let indexVersion = indexSchemaVersion(),
              IndexWatcher.shouldExitForSchema(indexVersion: indexVersion,
                                               binaryVersion: Store.schemaVersion)
        else { return }
        note("watch: index schema v\(indexVersion) newer than binary v\(Store.schemaVersion) — exiting for launchd restart")
        abort()
    }

    // MARK: - Debounce (runs on `queue`)

    private func scheduleFire(delay: TimeInterval? = nil) {
        pendingItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        pendingItem = item
        queue.asyncAfter(deadline: .now() + (delay ?? debounce), execute: item)
    }

    private func fire() {
        if stopped { return }
        if indexing {
            rerunRequested = true
            return
        }
        if IndexWatcher.isGitLocked(root: store.workspaceRoot) {
            gitLockRetries += 1
            if gitLockRetries <= IndexWatcher.gitLockMaxRetries {
                note("watch: git lock held — deferring reindex (\(gitLockRetries)/\(IndexWatcher.gitLockMaxRetries))")
                scheduleFire(delay: IndexWatcher.gitLockDelay)
                return
            }
            note("watch: git lock still held after \(gitLockRetries) deferrals — indexing anyway")
        }
        gitLockRetries = 0
        indexing = true
        indexQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.indexOnce()
            } catch {
                self.note("watch: reindex failed: \(error.localizedDescription)")
            }
            self.queue.async {
                self.indexing = false
                if self.rerunRequested {
                    self.rerunRequested = false
                    self.scheduleFire()
                }
            }
        }
    }
}
