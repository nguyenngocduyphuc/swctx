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
        public var corrupt: Bool         // integrity_check failed / unopenable+malformed
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
                          bytes: dirSize(dir), live: false, recentMtime: false,
                          corrupt: false)
            let probe = fm.fileExists(atPath: db.path) ? db : dir
            let mtime = (try? fm.attributesOfItem(atPath: probe.path))?[.modificationDate] as? Date
            e.recentMtime = (mtime ?? .distantPast).timeIntervalSinceNow > -minAgeSeconds
            if let q = openReadOnly(db) {
                e.workspace = try? q.read {
                    try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'workspace_root'")
                }
                e.chunks = (try? q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chunks") }) ?? 0
                e.corrupt = integrityCheckFailed(q)
                if let ws = e.workspace {
                    var wsIsDir: ObjCBool = false
                    e.live = fm.fileExists(atPath: ws, isDirectory: &wsIsDir) && wsIsDir.boolValue
                }
            } else {
                // An index.db that exists but can't be opened at all:
                // one raw probe separates corruption (quarantine) from
                // unrelated open failures (leave the flag clear).
                e.corrupt = provablyCorrupt(db)
            }
            entries.append(e)
        }
        // Corrupt indexes are quarantined by run(), never deleted as
        // orphans — the moved dir is evidence, not reclaimable garbage.
        let collectable = entries.filter { !$0.live && !$0.recentMtime && !$0.corrupt }
        return (entries, collectable.sorted { $0.bytes > $1.bytes })
    }

    /// Scan (+ quarantine corrupt / delete orphans when `yes`) and prune
    /// dead registry entries. Every index dir gets a `PRAGMA
    /// integrity_check`; a damaged one is renamed to
    /// `<key>.corrupt-<unix_ts>` and its registry entry dropped — the
    /// index is a derived cache and Store rebuilds it on next open.
    public static func run(yes: Bool, minAgeSeconds: TimeInterval = 3600) -> [String: Any] {
        let (entries, collectable) = scan(minAgeSeconds: minAgeSeconds)
        let corrupt = entries.filter(\.corrupt)
        // "Checked" = index.db was present at scan time. Counted before
        // the quarantine moves anything aside.
        let checked = entries.filter {
            FileManager.default.fileExists(atPath:
                indexesRoot().appendingPathComponent("\($0.key)/index.db").path)
        }.count
        var freed = 0, deleted = 0, quarantined = 0
        var quarantinedKeys = Set<String>()
        if yes {
            let ts = Int(Date().timeIntervalSince1970)
            for e in corrupt {
                let dir = indexesRoot().appendingPathComponent(e.key)
                let dest = indexesRoot()
                    .appendingPathComponent("\(e.key).corrupt-\(ts)")
                if (try? FileManager.default.moveItem(at: dir, to: dest)) != nil {
                    quarantined += 1
                    quarantinedKeys.insert(e.key)
                    FileHandle.standardError.write(
                        ("swctx: gc: quarantined corrupt index \(e.key) "
                            + "-> \(dest.path)\n").data(using: .utf8)!)
                }
            }
            for e in collectable {
                if (try? FileManager.default.removeItem(
                    at: indexesRoot().appendingPathComponent(e.key))) != nil {
                    freed += e.bytes; deleted += 1
                }
            }
            if !corrupt.isEmpty {
                FileHandle.standardError.write(
                    ("swctx: gc: integrity checked \(checked) index(es), "
                        + "quarantined \(quarantined) corrupt\n")
                        .data(using: .utf8)!)
            }
        }
        let reg = Store.loadRegistry()
        let liveReg = reg.filter { entry in
            // Quarantined keys leave the registry: nothing may keep
            // pointing at a damaged index dir.
            if quarantinedKeys.contains(entry.key) { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir)
                && isDir.boolValue
        }
        if yes && liveReg.count != reg.count { Store.saveRegistry(liveReg) }
        return [
            "dry_run": !yes,
            "total_indexes": entries.count,
            "live": entries.filter(\.live).count,
            "orphaned": entries.filter { !$0.live }.count,
            "recent_skipped": entries.filter { !$0.live && $0.recentMtime }.count,
            "integrity_checked": checked,
            "corrupt": corrupt.count,
            "quarantined": quarantined,
            "deleted": deleted,
            "freed_bytes": freed,
            "collectable_bytes": collectable.reduce(0) { $0 + $1.bytes },
            "registry_entries": reg.count,
            "registry_dead": reg.count - liveReg.count,
            "corrupt_indexes": corrupt.map {
                ["key": $0.key, "workspace": $0.workspace ?? "(unreadable)"]
            },
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

    /// `PRAGMA integrity_check` on an open index: true when the db is
    /// provably damaged — the pragma reports error rows, or reading it
    /// throws a corruption error. A non-corruption failure (busy, IO)
    /// proves nothing → false.
    static func integrityCheckFailed(_ q: DatabaseQueue) -> Bool {
        do {
            let rows = try q.read { db in
                try String.fetchAll(db, sql: "PRAGMA integrity_check")
            }
            return !rows.isEmpty && rows != ["ok"]
        } catch {
            return Store.isCorruptionError(error)
        }
    }

    /// Whether `db` exists and is provably corrupt although
    /// `openReadOnly` could not open it — one raw open separates
    /// SQLITE_CORRUPT/NOTADB from unrelated open failures (permissions).
    static func provablyCorrupt(_ db: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: db.path) else { return false }
        do {
            let q = try DatabaseQueue(path: db.path)
            return integrityCheckFailed(q)
        } catch {
            return Store.isCorruptionError(error)
        }
    }
}
