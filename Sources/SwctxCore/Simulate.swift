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

    private static let diffGitRx = try! NSRegularExpression(
        pattern: #"^diff --git a/(.+) b/(.+)$"#, options: .anchorsMatchLines)
    private static let oldFileRx = try! NSRegularExpression(
        pattern: #"^--- (?:a/)?([^\t]+?)\s*$"#, options: .anchorsMatchLines)
    private static let newFileRx = try! NSRegularExpression(
        pattern: #"^\+\+\+ (?:b/)?([^\t]+?)\s*$"#, options: .anchorsMatchLines)
    private static let hunkRx = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#, options: .anchorsMatchLines)

    /// Parse unified diffs (git or plain `diff -u`). Hunk bodies are consumed
    /// by the declared line counts, so removed lines that themselves start
    /// with `---` stay content and `---`/`+++` after a hunk are headers again.
    /// Deleted files (`+++ /dev/null`) keep their `---` path; binary and
    /// mode-only files surface with zero hunks via `diff --git`.
    public static func parseDiff(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var cur: FileDiff?
        var hunk: Hunk?
        var oldRem = 0, newRem = 0
        var pendingOld: String?
        func flushHunk() {
            if var f = cur, let h = hunk { f.hunks.append(h); cur = f }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = cur { files.append(f) }
            cur = nil; pendingOld = nil
        }
        func group(_ m: NSTextCheckingResult, _ i: Int, in line: String) -> String? {
            guard m.range(at: i).location != NSNotFound,
                  let r = Range(m.range(at: i), in: line) else { return nil }
            return String(line[r])
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if hunk != nil && (oldRem > 0 || newRem > 0) {
                if line.hasPrefix("-") && oldRem > 0 {
                    hunk?.removedLines.append(String(line.dropFirst()))
                    oldRem -= 1
                    continue
                }
                if line.hasPrefix("+") && newRem > 0 {
                    hunk?.addedLines.append(String(line.dropFirst()))
                    newRem -= 1
                    continue
                }
                if line.hasPrefix("\\") { continue }   // "\ No newline" marker
                if line.hasPrefix(" ") || line.isEmpty {
                    oldRem = max(0, oldRem - 1)
                    newRem = max(0, newRem - 1)
                    continue
                }
                flushHunk()  // counts exhausted/malformed: re-read as header
            }
            if let m = diffGitRx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let p = group(m, 2, in: line) {
                flushFile()
                cur = FileDiff(path: p, hunks: [])
                continue
            }
            if let m = oldFileRx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                // `---` starts a new file in plain `diff -u` output (no
                // `diff --git` marker); after a git file header it just
                // names the pre-image for the `+++` line.
                if cur != nil && !(cur?.hunks.isEmpty ?? true) { flushFile() }
                pendingOld = group(m, 1, in: line).flatMap { $0 == "/dev/null" ? nil : $0 }
                continue
            }
            if let m = newFileRx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let p = group(m, 1, in: line) {
                if cur == nil { cur = FileDiff(path: "", hunks: []) }
                let prior = pendingOld ?? cur?.path ?? ""
                cur?.path = p == "/dev/null" ? prior : p
                continue
            }
            if let m = hunkRx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let ro = Range(m.range(at: 1), in: line),
               let rn = Range(m.range(at: 3), in: line) {
                flushHunk()
                let oldCnt = group(m, 2, in: line).flatMap { Int($0) } ?? 1
                let newCnt = group(m, 4, in: line).flatMap { Int($0) } ?? 1
                hunk = Hunk(oldStart: Int(line[ro]) ?? 0,
                            newStart: Int(line[rn]) ?? 0,
                            newCount: newCnt, removedLines: [], addedLines: [])
                oldRem = oldCnt; newRem = newCnt
                continue
            }
        }
        flushFile()
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

    static let testPathRx = try! NSRegularExpression(
        pattern: #"(?i)(test|tests|spec|__tests__|testing)"#, options: [])

    /// Shared test-path heuristic — Simulate risk split + test_coverage.
    static func isTestPath(_ p: String) -> Bool {
        testPathRx.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil
    }

    private static let paramsRx = try! NSRegularExpression(
        pattern: #"[A-Za-z_]\w*\s*\(([^)]*)\)"#)

    /// norm_kinds that can enclose a changed line — callables and type
    /// containers; locals (`variable`/`property`) and `heading`/`pair` do
    /// not own a region. Shared by Simulate body hunks and Trace frames.
    static let containerNormKinds = [
        "function", "method", "initializer", "subscript",
        "class", "struct", "enum", "union", "actor", "protocol", "extension",
    ]

    /// Nearest preceding container-kind declaration in `path` at or above
    /// `line`. Answers "which function/class owns this line" when the
    /// smallest containing chunk is a symbol-less `window` split of an
    /// oversized body — its declaring chunk sits far above the hunk.
    static func nearestDecl(_ db: Database, path: String, line: Int64)
        throws -> (name: String, line: Int64, kind: String)? {
        let ph = containerNormKinds.map { _ in "?" }.joined(separator: ",")
        var args: [DatabaseValueConvertible] = [path, line]
        args.append(contentsOf: containerNormKinds)
        guard let r = try Row.fetchOne(db, sql: """
            SELECT s.name, s.line, s.norm_kind
            FROM symbols s JOIN files f ON f.id = s.file_id
            WHERE f.path = ? AND s.line <= ? AND s.norm_kind IN (\(ph))
            ORDER BY s.line DESC, s.id DESC LIMIT 1
            """, arguments: StatementArguments(args)),
            let n = r["name"] as? String else { return nil }
        return (n, (r["line"] as? Int64) ?? 0, (r["norm_kind"] as? String) ?? "")
    }

    /// Merge the containing chunk's own `symbol` with the nearest container
    /// decl: a decl inside the chunk's span is more precise (a method nested
    /// in a class-sized chunk); for symbol-less `window` chunks the nearest
    /// decl above is the owning declaration. Returns (symbol, source) where
    /// source is "chunk" | "nested_decl" | "owner_decl".
    static func enclosingSymbol(chunkSymbol: String?, chunkStart: Int64,
                                decl: (name: String, line: Int64, kind: String)?)
        -> (String, String)? {
        if let d = decl, d.line >= chunkStart { return (d.name, "nested_decl") }
        if let s = chunkSymbol, !s.isEmpty { return (s, "chunk") }
        if let d = decl { return (d.name, "owner_decl") }
        return nil
    }

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
            return ["files_changed": 0, "files": [String](), "symbols": [],
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
                    SELECT e.line, e.kind, f.path, e.src_chunk, e.dst_chunk,
                           c.symbol AS src_symbol
                    FROM edges e
                    JOIN chunks c ON c.id = e.src_chunk
                    JOIN files f ON f.id = c.file_id
                    WHERE e.dst_name = ? AND e.kind IN (\(ph))
                    ORDER BY f.path, e.line LIMIT ?
                    """, arguments: StatementArguments(args + [maxCallers]))
                    .map { ["path": ($0["path"] as? String) ?? "",
                            "line": ($0["line"] as? Int64) ?? 0,
                            "edge": ($0["kind"] as? String) ?? "",
                            "symbol": ($0["src_symbol"] as? String) ?? NSNull(),
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
                        SELECT c.id, c.symbol, c.kind, c.start_line, c.end_line
                        FROM chunks c JOIN files f ON f.id = c.file_id
                        WHERE f.path = ? AND c.start_line <= ? AND c.end_line >= ?
                        ORDER BY (c.end_line - c.start_line) ASC LIMIT 1
                        """, arguments: [fd.path, h.oldStart, h.oldStart])
                    guard let row else { continue }
                    let decl = try nearestDecl(db, path: fd.path,
                                               line: Int64(h.oldStart))
                    let enc = enclosingSymbol(
                        chunkSymbol: row["symbol"] as? String,
                        chunkStart: (row["start_line"] as? Int64) ?? 0,
                        decl: decl)
                    var rec: [String: Any] = [
                        "file": fd.path,
                        "old_line": h.oldStart,
                        "enclosing_chunk": (row["id"] as? Int64) ?? -1,
                        "enclosing_kind": (row["kind"] as? String) ?? NSNull(),
                    ]
                    if let (sym, source) = enc {
                        rec["enclosing_symbol"] = sym
                        rec["symbol_source"] = source
                        rec["dependent_callers"] = try dependents(
                            of: sym,
                            kinds: ["calls", "instantiates", "uses_type"],
                            defs: defChunks(sym))
                    } else {
                        rec["enclosing_symbol"] = NSNull()
                        rec["dependent_callers"] = [[String: Any]]()
                    }
                    bodyChanges.append(rec)
                }
            }
        }

        let allCallers = symbols.flatMap { $0.callers }
        let bodyCallers = bodyChanges
            .flatMap { $0["dependent_callers"] as? [[String: Any]] ?? [] }
        // Dependents of body-changed symbols are not compile breaks, but
        // their files are still "affected" — fold them into the risk lists.
        let brokenFiles = Set(allCallers.compactMap { $0["path"] as? String })
        let affectedFiles = brokenFiles
            .union(bodyCallers.compactMap { $0["path"] as? String })
        let testFiles = affectedFiles.filter { isTestPath($0) }
        let prodFiles = affectedFiles.subtracting(testFiles)

        return [
            "files_changed": fileDiffs.count,
            "files": fileDiffs.map { $0.path },
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
                "body_change_call_sites": bodyCallers.count,
                "affected_prod_files": prodFiles.sorted(),
                "affected_test_files": testFiles.sorted(),
            ],
            "note": "static approximation — dynamic dispatch, string-keyed " +
                    "lookups and macro-generated code are not modeled",
        ]
    }
}
