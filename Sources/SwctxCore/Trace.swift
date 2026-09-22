import Foundation
import GRDB

/// `trace_lookup` — stack trace in, indexed frames out. Parses the
/// common traceback formats (Python, JS/TS `at`, Go panic, generic
/// `path:line`), suffix-matches paths against indexed files, and maps
/// each frame to its enclosing chunk. Pure read; static only — inlined
/// calls, source maps and native frames are not recoverable.
public enum Trace {

    public struct Frame {
        public var raw: String
        public var path: String      // path as written in the trace
        public var line: Int
        public var symbolHint: String? // function name if the format carries one
    }

    // Python:  File "src/x.py", line 42, in fn
    private static let pyRx = try! NSRegularExpression(
        pattern: #"File "([^"]+)", line (\d+)(?:, in (\S+))?"#)
    // Swift/ObjC runtime: Fatal error: …: file /abs/x.swift, line 448
    private static let swiftRx = try! NSRegularExpression(
        pattern: #"\bfile\s+([^",\s=]+\.[A-Za-z0-9]+),\s*line\s+(\d+)"#,
        options: [.caseInsensitive])
    // JS/TS: at fn (src/x.ts:10:5) | at async fn (…) | at src/x.ts:10:5
    private static let jsRx = try! NSRegularExpression(
        pattern: #"\bat\s+(?:async\s+)?(?:([\w$.<>]+)\s+(?:\[as\s+\S+\]\s+)?\()?((?:file://)?[^\s()]+?):(\d+)(?::\d+)?\)?"#)
    // Go panic:   /path/file.go:37 +0x1f2   (function on previous line)
    private static let goRx = try! NSRegularExpression(
        pattern: #"^\s*(\S+\.go):(\d+)\s+\+0x[0-9a-fA-F]+"#, options: [.anchorsMatchLines])
    // Generic fallback: any `something.ext:N` — Swift/Java/Rust/C++/etc.
    private static let genericRx = try! NSRegularExpression(
        pattern: #"([A-Za-z0-9_./\\-]+\.(?:swift|py|js|jsx|ts|tsx|mjs|cjs|go|rs|java|kt|rb|php|m|mm|c|cc|cpp|h|hpp)):(\d+)"#)

    /// Parse frames in textual order. Specific formats run first; the
    /// generic `path:N` fallback skips ranges already claimed by them.
    public static func parse(_ text: String) -> [Frame] {
        var frames: [(Int, Frame)] = []
        var claimed: [NSRange] = []
        func add(_ rx: NSRegularExpression, pathAt: Int, lineAt: Int,
                 symAt: Int) {
            let ns = text as NSString
            for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if claimed.contains(where: {
                    NSIntersectionRange($0, m.range).length > 0 }) { continue }
                claimed.append(m.range)
                let path = m.range(at: pathAt).location != NSNotFound
                    ? ns.substring(with: m.range(at: pathAt)) : ""
                let line = m.range(at: lineAt).location != NSNotFound
                    ? Int(ns.substring(with: m.range(at: lineAt))) ?? 0 : 0
                let sym = symAt > 0 && m.range(at: symAt).location != NSNotFound
                    ? ns.substring(with: m.range(at: symAt)) : nil
                guard !path.isEmpty, line > 0 else { continue }
                frames.append((m.range.location,
                    Frame(raw: ns.substring(with: m.range),
                          path: path, line: line, symbolHint: sym)))
            }
        }
        add(pyRx, pathAt: 1, lineAt: 2, symAt: 3)
        add(swiftRx, pathAt: 1, lineAt: 2, symAt: -1)
        add(jsRx, pathAt: 2, lineAt: 3, symAt: 1)
        add(goRx, pathAt: 1, lineAt: 2, symAt: -1)
        add(genericRx, pathAt: 1, lineAt: 2, symAt: -1)
        return frames.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Trace paths are often absolute/container paths (/app/…, site-
    /// packages, node_modules). Match workspace files by longest path
    /// suffix; frames that match nothing are returned unmatched.
    public static func resolve(store: Store, frames: [Frame])
        -> [[String: Any]] {
        let paths: [String] = (try? store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM files ORDER BY path")
        }) ?? []
        var out: [[String: Any]] = []
        for f in frames {
            let norm = f.path
                .replacingOccurrences(of: "file://", with: "")
                .replacingOccurrences(of: "\\", with: "/")
            // Best suffix match: longest indexed path that ends the
            // trace path, or that the trace path ends with.
            var best: String?
            for p in paths {
                if norm == p || norm.hasSuffix("/" + p) || p.hasSuffix("/" + norm) {
                    if (best?.count ?? 0) < p.count { best = p }
                } else {
                    // component-wise suffix: "…/src/x.py" vs "src/x.py"
                    let t = norm.split(separator: "/"), ip = p.split(separator: "/")
                    if ip.count <= t.count,
                       Array(t.suffix(ip.count)) == ip,
                       (best?.count ?? 0) < p.count { best = p }
                }
            }
            var rec: [String: Any] = [
                "raw": f.raw, "trace_path": f.path, "line": f.line,
                "matched": best != nil]
            if let sym = f.symbolHint { rec["symbol_hint"] = sym }
            if let p = best {
                rec["path"] = p
                let row = try? store.pool.read({ db in
                    try Row.fetchOne(db, sql: """
                        SELECT c.id, c.symbol, c.start_line, c.end_line
                        FROM chunks c JOIN files f ON f.id = c.file_id
                        WHERE f.path = ? AND c.start_line <= ? AND c.end_line >= ?
                        ORDER BY (c.end_line - c.start_line) ASC LIMIT 1
                        """, arguments: [p, f.line, f.line])
                })
                if let row, let cid = row["id"] as? Int64 {
                    rec["chunk_id"] = cid
                    rec["span"] = "\((row["start_line"] as? Int64) ?? 0)-\((row["end_line"] as? Int64) ?? 0)"
                }
                // A decl nested inside the matched chunk (method inside a
                // class-sized chunk) is more precise than the chunk's own
                // symbol; for symbol-less `window` chunks the nearest decl
                // above is the owning declaration. Also covers matched
                // lines that land between chunks entirely.
                let decl = try? store.pool.read({ db in
                    try Simulate.nearestDecl(db, path: p, line: Int64(f.line))
                })
                if let enc = Simulate.enclosingSymbol(
                    chunkSymbol: row?["symbol"] as? String,
                    chunkStart: (row?["start_line"] as? Int64) ?? Int64(f.line),
                    decl: decl) {
                    rec["symbol"] = enc.0
                    rec["symbol_source"] = enc.1
                }
            }
            out.append(rec)
        }
        return out
    }

    /// Deepest matched app frame is the crash site; suspects are the indexed
    /// callers of that frame's symbol. Looked up by `dst_name` (not only
    /// `dst_chunk`): crash lines often land in symbol-less `window` chunks
    /// that no edge points at, and name-only edges carry unresolved callers
    /// too. `resolved` marks edges pinned to a same-named definition.
    static func suspects(store: Store, resolved: [[String: Any]])
        -> [[String: Any]] {
        guard let last = resolved.last(where: { ($0["matched"] as? Bool) == true })
        else { return [] }
        let sym = last["symbol"] as? String
        let cid = last["chunk_id"] as? Int64
        guard sym != nil || cid != nil else { return [] }
        var defs = Set<Int64>()
        let rows: [Row] = (try? store.pool.read { db in
            if let sym {
                defs = Set(try Int64.fetchAll(db, sql:
                    "SELECT chunk_id FROM symbols WHERE name = ?",
                    arguments: [sym]))
                return try Row.fetchAll(db, sql: """
                    SELECT DISTINCT f.path, e.line, c.symbol, e.dst_chunk
                    FROM edges e
                    JOIN chunks c ON c.id = e.src_chunk
                    JOIN files f ON f.id = c.file_id
                    WHERE e.dst_name = ? AND e.kind IN
                        ('calls','instantiates','uses_type','api_call')
                    ORDER BY f.path, e.line LIMIT 20
                    """, arguments: [sym])
            }
            return try Row.fetchAll(db, sql: """
                SELECT DISTINCT f.path, e.line, c.symbol, e.dst_chunk
                FROM edges e
                JOIN chunks c ON c.id = e.src_chunk
                JOIN files f ON f.id = c.file_id
                WHERE e.dst_chunk = ? AND e.kind IN
                    ('calls','instantiates','uses_type','api_call')
                ORDER BY f.path, e.line LIMIT 20
                """, arguments: [cid ?? -1])
        }) ?? []
        // Files touched by the most recent commits are statistically the
        // likelier break source — flag suspects on that list. Commit
        // records carry a `files` array in payload; LIKE-match is cheap.
        let recentPaths: Set<String> = (try? store.pool.read { db in
            let payloads = try String.fetchAll(db, sql: """
                SELECT payload FROM records WHERE kind = 'commit'
                ORDER BY id DESC LIMIT 20
                """)
            var set = Set<String>()
            for pl in payloads {
                guard let data = pl.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let ps = obj["files"] as? [String] else { continue }
                set.formUnion(ps)
            }
            return set
        }) ?? []
        return rows.map {
            let p = ($0["path"] as? String) ?? ""
            var r: [String: Any] = [
                "path": p,
                "line": ($0["line"] as? Int64) ?? 0,
                "symbol": ($0["symbol"] as? String) ?? NSNull(),
                "resolved": ($0["dst_chunk"] as? Int64)
                    .map { defs.contains($0) } ?? false]
            if recentPaths.contains(p) { r["recent_commit"] = true }
            return r
        }
        // Recently commit-touched callers triage first.
        .sorted { a, b in
            ((a["recent_commit"] as? Bool) == true) != ((b["recent_commit"] as? Bool) == true)
                ? (a["recent_commit"] as? Bool) == true
                : (a["path"] as? String ?? "") < (b["path"] as? String ?? "")
        }
    }
}
