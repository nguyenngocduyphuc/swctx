import Foundation
import GRDB

/// Speculative patch analysis (v0): parse a unified diff, map removed
/// declaration lines to indexed symbols, then surface every indexed dependent
/// that would break — before the patch is ever written to disk.
///
/// Two change classes:
///   - signature/removed: a `-` line declares a symbol → all edges targeting
///     that symbol name are broken references (callers, instantiations,
///     type uses, implementers).
///   - body: hunk touches no declaration → the enclosing chunk's symbol keeps
///     its signature but its behavior changed → dependents are risk, not
///     compile errors.
public enum Simulate {

    public struct Hunk {
        public var oldStart: Int
        public var newStart: Int
        public var newCount: Int
        public var removedLines: [String]
        public var addedLines: [String]
    }

    public struct FileDiff {
        public var path: String
        public var hunks: [Hunk]
    }

    // MARK: - unified diff parsing

    private static let fileRx = try! NSRegularExpression(
        pattern: #"^\+\+\+ b/(.+)$"#, options: .anchorsMatchLines)
    private static let hunkRx = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,(\d+))? @@"#, options: .anchorsMatchLines)

    public static func parseDiff(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var cur: FileDiff?
        var hunk: Hunk?
        func flush() {
            if var f = cur {
                if let h = hunk { f.hunks.append(h) }
                files.append(f)
            }
            cur = nil; hunk = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let m = fileRx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line) {
                flush()
                cur = FileDiff(path: String(line[r]), hunks: [])
                continue
            }
            if let m = hunkRx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let ro = Range(m.range(at: 1), in: line),
               let rn = Range(m.range(at: 2), in: line) {
                if var f = cur, let h = hunk { f.hunks.append(h); cur = f }
                let cnt = m.range(at: 3).location != NSNotFound
                    ? Range(m.range(at: 3), in: line).map { Int(line[$0]) ?? 1 } ?? 1 : 1
                hunk = Hunk(oldStart: Int(line[ro]) ?? 0,
                            newStart: Int(line[rn]) ?? 0,
                            newCount: cnt, removedLines: [], addedLines: [])
                continue
            }
            if hunk != nil {
                if line.hasPrefix("-") && !line.hasPrefix("---") {
                    hunk?.removedLines.append(String(line.dropFirst()))
                } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    hunk?.addedLines.append(String(line.dropFirst()))
                }
            }
        }
        flush()
        return files
    }

    // MARK: - declaration extraction from removed lines

    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p)
    }

    /// First-capture-group regexes that pull a declared symbol name out of a
    /// source line, keyed by language id (Languages.extMap values).
    private static let declRx: [String: [NSRegularExpression]] = [
        "swift": [
            rx(#"\b(?:func|init|deinit|subscript|var|let|typealias)\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:class|struct|enum|protocol|actor|extension)\s+([A-Za-z_]\w*)"#)],
        "python": [
            rx(#"\bdef\s+([A-Za-z_]\w*)"#),
            rx(#"\bclass\s+([A-Za-z_]\w*)"#)],
        "javascript": [
            rx(#"\bfunction\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:class)\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:const|let|var)\s+([A-Za-z_]\w*)\s*="#)],
        "typescript": [
            rx(#"\bfunction\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:class|interface|type|enum)\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:const|let|var)\s+([A-Za-z_]\w*)\s*[:=]"#)],
        "tsx": [
            rx(#"\bfunction\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:class|interface|type|enum)\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:const|let|var)\s+([A-Za-z_]\w*)\s*[:=]"#)],
        "go": [
            rx(#"\bfunc\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#),
            rx(#"\btype\s+([A-Za-z_]\w*)"#)],
        "rust": [
            rx(#"\bfn\s+([A-Za-z_]\w*)"#),
            rx(#"\b(?:struct|enum|trait|union)\s+([A-Za-z_]\w*)"#)],
        "bash": [
            rx(#"^\s*([A-Za-z_]\w*)\s*\(\s*\)"#)],
    ]

    /// Symbol names whose declarations appear in `lines` (removed `-` lines).
    public static func removedDecls(path: String, lines: [String]) -> [String] {
        guard let lang = Languages.languageID(forPath: path),
              let regexes = declRx[lang] else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for line in lines {
            for re in regexes {
                for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line))
                where m.numberOfRanges > 1 {
                    if let r = Range(m.range(at: 1), in: line) {
                        let name = String(line[r])
                        if seen.insert(name).inserted { out.append(name) }
                    }
                }
            }
        }
        return out
    }

    // MARK: - impact lookup against the index

    private static let testPathRx = try! NSRegularExpression(
        pattern: #"(?i)(test|tests|spec|__tests__|testing)"#, options: [])

    private static func isTestPath(_ p: String) -> Bool {
        testPathRx.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil
    }

    private static let paramsRx = try! NSRegularExpression(
        pattern: #"[A-Za-z_]\w*\s*\(([^)]*)\)"#)

    /// Rough arity from a declaration line: `name(a, b = 1)` → 2.
    static func paramCount(_ line: String, name: String) -> Int? {
        guard let i = line.range(of: name + "(") else { return nil }
        let tail = String(line[i.lowerBound...])
        guard let m = paramsRx.firstMatch(
            in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let r = Range(m.range(at: 1), in: tail) else { return nil }
        let inner = tail[r].trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return 0 }
        return inner.filter { $0 == "," }.count + 1
    }

    /// Run simulation against a store. `diff` is unified-diff text.
    /// Returns a JSON-encodable dictionary.
    public static func run(store: Store, diff: String,
                           maxCallers: Int = 50) throws -> [String: Any] {
        let fileDiffs = parseDiff(diff)
        guard !fileDiffs.isEmpty else {
            return ["files_changed": 0, "symbols": [],
                    "body_changes": [], "risk": [:],
                    "note": "no unified-diff hunks parsed"]
        }

        struct SymHit {
            var name: String; var file: String; var changeKind: String
            var definitions = 0; var arity: String?
            var callers: [[String: Any]] = []
            var implementers: [[String: Any]] = []
        }
        var symbols: [SymHit] = []
        var bodyChanges: [[String: Any]] = []

        try store.pool.read { db in
            func defChunks(_ name: String) throws -> Set<Int64> {
                Set(try Int64.fetchAll(db, sql:
                    "SELECT chunk_id FROM symbols WHERE name = ?",
                    arguments: [name]))
            }
            func dependents(of name: String, kinds: [String],
                            defs: Set<Int64>) throws -> [[String: Any]] {
                let ph = kinds.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = [name]
                args.append(contentsOf: kinds)
                return try Row.fetchAll(db, sql: """
                    SELECT e.line, e.kind, f.path, e.src_chunk, e.dst_chunk
                    FROM edges e
                    JOIN chunks c ON c.id = e.src_chunk
                    JOIN files f ON f.id = c.file_id
                    WHERE e.dst_name = ? AND e.kind IN (\(ph))
                    ORDER BY f.path LIMIT ?
                    """, arguments: StatementArguments(args + [maxCallers]))
                    .map { ["path": ($0["path"] as? String) ?? "",
                            "line": ($0["line"] as? Int) ?? 0,
                            "edge": ($0["kind"] as? String) ?? "",
                            "chunk_id": ($0["src_chunk"] as? Int64) ?? -1,
                            "resolved": ($0["dst_chunk"] as? Int64)
                                .map { defs.contains($0) } ?? false] }
            }

            for fd in fileDiffs {
                let removed = fd.hunks.flatMap { $0.removedLines }
                let decls = removedDecls(path: fd.path, lines: removed)
                let addedDecls = Set(removedDecls(path: fd.path,
                    lines: fd.hunks.flatMap { $0.addedLines }))

                // Same name redeclared on the + side = signature changed;
                // absent = symbol removed outright. Both can break callers.
                for name in decls {
                    let defs = try defChunks(name)
                    var hit = SymHit(name: name, file: fd.path,
                        changeKind: addedDecls.contains(name)
                            ? "signature" : "removed")
                    hit.definitions = defs.count
                    // arity change: `-` decl vs `+` decl param counts
                    if addedDecls.contains(name),
                       let old = fd.hunks.flatMap({ $0.removedLines })
                           .first(where: { $0.contains(name + "(") }),
                       let new = fd.hunks.flatMap({ $0.addedLines })
                           .first(where: { $0.contains(name + "(") }),
                       let po = paramCount(old, name: name),
                       let pn = paramCount(new, name: name), po != pn {
                        hit.arity = "\(po)→\(pn)"
                    }
                    hit.callers = try dependents(of: name,
                        kinds: ["calls", "instantiates", "uses_type"],
                        defs: defs)
                    hit.implementers = try dependents(of: name,
                        kinds: ["implements", "extends"], defs: defs)
                    symbols.append(hit)
                }

                // Body-only hunks: locate enclosing indexed chunk by oldStart.
                for h in fd.hunks where removedDecls(path: fd.path,
                                                     lines: h.removedLines).isEmpty {
                    if h.removedLines.isEmpty && h.addedLines.isEmpty { continue }
                    let row = try Row.fetchOne(db, sql: """
                        SELECT c.id, c.symbol, c.start_line, c.end_line
                        FROM chunks c JOIN files f ON f.id = c.file_id
                        WHERE f.path = ? AND c.start_line <= ? AND c.end_line >= ?
                        ORDER BY (c.end_line - c.start_line) ASC LIMIT 1
                        """, arguments: [fd.path, h.oldStart, h.oldStart])
                    guard let row else { continue }
                    let sym = (row["symbol"] as? String) ?? "?"
                    bodyChanges.append([
                        "file": fd.path,
                        "old_line": h.oldStart,
                        "enclosing_symbol": sym,
                        "enclosing_chunk": row["id"] as Int64,
                        "dependent_callers": sym == "?" ? [] :
                            try dependents(of: sym,
                                kinds: ["calls", "instantiates", "uses_type"],
                                defs: defChunks(sym))])
                }
            }
        }

        let allCallers = symbols.flatMap { $0.callers }
        let brokenFiles = Set(allCallers.compactMap { $0["path"] as? String })
        let testFiles = brokenFiles.filter { isTestPath($0) }
        let prodFiles = brokenFiles.subtracting(testFiles)

        return [
            "files_changed": fileDiffs.count,
            "symbols": symbols.map { s in
                var d = ["name": s.name, "file": s.file,
                         "change": s.changeKind,
                         "definitions": s.definitions,
                         "callers": s.callers,
                         "implementers": s.implementers] as [String: Any]
                if let a = s.arity { d["arity"] = a }
                return d
            },
            "body_changes": bodyChanges,
            "risk": [
                "broken_call_sites": allCallers.count,
                "resolved_call_sites": allCallers
                    .filter { ($0["resolved"] as? Bool) == true }.count,
                "affected_prod_files": prodFiles.sorted(),
                "affected_test_files": testFiles.sorted(),
            ],
            "note": "static approximation — dynamic dispatch, string-keyed " +
                    "lookups and macro-generated code are not modeled",
        ]
    }
}
