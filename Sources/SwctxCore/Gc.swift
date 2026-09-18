import Foundation
import GRDB

/// Garbage-collect orphaned indexes under ~/.swctx/indexes/<key>/.
/// An index is orphaned when its meta.workspace_root no longer exists on
/// disk (deleted worktrees, /tmp test fixtures, auto-resolved leftovers).
/// Live-and-unregistered indexes are reported but never collected.
public enum Gc {
    public struct Entry {
        public var key: String
        public var workspace: String?    // meta.workspace_root; nil = unreadable/corrupt
        public var chunks: Int
        public var bytes: Int
        public var live: Bool            // workspace path still on disk
        public var recentMtime: Bool     // touched within the safety window
    }

    static func indexesRoot() -> URL {
        Store.baseDir().appendingPathComponent("indexes")
    }

    /// Scan every index dir. `minAgeSeconds` is the safety window: an
    /// orphaned entry touched more recently is skipped (in-flight index,
    /// or a workspace deleted seconds ago that a watcher may recreate).
    public static func scan(minAgeSeconds: TimeInterval = 3600)
        -> (entries: [Entry], collectable: [Entry]) {
        let fm = FileManager.default
        guard let keys = try? fm.contentsOfDirectory(atPath: indexesRoot().path) else {
            return ([], [])
        }
        var entries: [Entry] = []
        for key in keys where key != ".DS_Store" {
            let dir = indexesRoot().appendingPathComponent(key)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let db = dir.appendingPathComponent("index.db")
            var e = Entry(key: key, workspace: nil, chunks: 0,
                          bytes: dirSize(dir), live: false, recentMtime: false)
            let probe = fm.fileExists(atPath: db.path) ? db : dir
            let mtime = (try? fm.attributesOfItem(atPath: probe.path))?[.modificationDate] as? Date
            e.recentMtime = (mtime ?? .distantPast).timeIntervalSinceNow > -minAgeSeconds
            if let q = openReadOnly(db) {
                e.workspace = try? q.read {
                    try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'workspace_root'")
                }
                e.chunks = (try? q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chunks") }) ?? 0
                if let ws = e.workspace {
                    var wsIsDir: ObjCBool = false
                    e.live = fm.fileExists(atPath: ws, isDirectory: &wsIsDir) && wsIsDir.boolValue
                }
            }
            entries.append(e)
        }
        let collectable = entries.filter { !$0.live && !$0.recentMtime }
        return (entries, collectable.sorted { $0.bytes > $1.bytes })
    }

    /// Scan (+ delete when `yes`) and prune dead registry entries.
    public static func run(yes: Bool, minAgeSeconds: TimeInterval = 3600) -> [String: Any] {
        let (entries, collectable) = scan(minAgeSeconds: minAgeSeconds)
        var freed = 0, deleted = 0
        if yes {
            for e in collectable {
                if (try? FileManager.default.removeItem(
                    at: indexesRoot().appendingPathComponent(e.key))) != nil {
                    freed += e.bytes; deleted += 1
                }
            }
        }
        let reg = Store.loadRegistry()
        let liveReg = reg.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
                && isDir.boolValue
        }
        if yes && liveReg.count != reg.count { Store.saveRegistry(liveReg) }
        return [
            "dry_run": !yes,
            "total_indexes": entries.count,
            "live": entries.filter(\.live).count,
            "orphaned": entries.filter { !$0.live }.count,
            "recent_skipped": entries.filter { !$0.live && $0.recentMtime }.count,
            "deleted": deleted,
            "freed_bytes": freed,
            "collectable_bytes": collectable.reduce(0) { $0 + $1.bytes },
            "registry_entries": reg.count,
            "registry_dead": reg.count - liveReg.count,
            "orphans": collectable.map {
                ["key": $0.key, "workspace": $0.workspace ?? "(unreadable)",
                 "chunks": $0.chunks, "bytes": $0.bytes] as [String: Any]
            },
        ]
    }

    static func dirSize(_ dir: URL) -> Int {
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let u as URL in en {
            total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    static func openReadOnly(_ db: URL) -> DatabaseQueue? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        var c = Configuration()
        c.readonly = true
        if let q = try? DatabaseQueue(path: db.path, configuration: c),
           (try? q.read { try Int.fetchOne($0, sql: "SELECT 1") }) != nil {
            return q
        }
        // A hot WAL journal can't be recovered by a read-only handle
        // (SQLITE_CANTOPEN). A normal open performs recovery — the same
        // thing the sqlite3 CLI does — so retry without the flag.
        return try? DatabaseQueue(path: db.path)
    }
}
