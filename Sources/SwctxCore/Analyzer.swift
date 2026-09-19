import CTreeSitter
import Foundation

public struct ChunkDraft {
    public var startLine: Int   // 1-based
    public var endLine: Int
    public var kind: String
    public var symbol: String?
    public var content: String
}

public struct SymbolDraft {
    public var name: String
    public var kind: String      // raw tree-sitter node type
    public var norm: String      // normalized semantic kind (Languages.normKind)
    public var line: Int
    public var signature: String
    public var chunkIndex: Int   // index into chunks, -1 if outside

    public init(name: String, kind: String, line: Int, signature: String,
                chunkIndex: Int, declText: String? = nil) {
        self.name = name
        self.kind = kind
        self.norm = Languages.normKind(kind, declText: declText ?? signature)
        self.line = line
        self.signature = signature
        self.chunkIndex = chunkIndex
    }
}

public struct EdgeDraft {
    public var kind: String      // calls | imports | implements
    public var dstName: String
    public var line: Int
    public var chunkIndex: Int
    /// Receiver/module ident for qualified calls (`m` in `m.f()`); nil for
    /// bare calls and non-call edges.
    public var qualifier: String? = nil
}

public struct AnalysisResult {
    public var chunks: [ChunkDraft] = []
    public var symbols: [SymbolDraft] = []
    public var edges: [EdgeDraft] = []
}

/// Syntax-aware analysis of a single source file: chunks, symbol defs, call/import edges.
public enum Analyzer {
    static let maxChunkLines = 400
    static let windowLines = 120
    static let windowOverlap = 15

    public static func analyze(bytes: [UInt8], languageID: String, path: String) -> AnalysisResult {
        var result = AnalysisResult()
        let source = String(decoding: bytes, as: UTF8.self)
        let lines = source.components(separatedBy: "\n")

        guard let profile = Languages.profile(languageID),
              !(profile.chunkTypes.isEmpty && profile.defTypes.isEmpty
                && profile.callTypes.isEmpty && profile.importTypes.isEmpty
                && profile.implTypes.isEmpty),
              let tsLang = profile.language,
              let parser = Parser(language: tsLang),
              let tree = parser.parse(bytes) else {
            result.chunks = heuristicChunks(lines: lines, languageID: languageID)
            if languageID == "markdown" {
                result.symbols = markdownSymbols(lines: lines, chunks: result.chunks)
            }
            return result
        }

        // ---- Chunks: top-level declarations + window-fill for uncovered gaps ----
        var declChunks: [ChunkDraft] = []
        emitChunks(node: tree.root, bytes: bytes, profile: profile, depth: 0, into: &declChunks)
        declChunks.sort { $0.startLine < $1.startLine }

        var chunks: [ChunkDraft] = []
        var cursor = 1
        for c in declChunks {
            if c.startLine > cursor, c.startLine - cursor > windowLines {
                chunks.append(contentsOf: windowChunks(lines: lines, from: cursor, to: c.startLine - 1))
            }
            chunks.append(c)
            cursor = max(cursor, c.endLine + 1)
        }
        if lines.count - cursor + 1 > windowLines {
            chunks.append(contentsOf: windowChunks(lines: lines, from: cursor, to: lines.count))
        }
        if chunks.isEmpty {
            chunks = heuristicChunks(lines: lines, languageID: languageID)
        }
        result.chunks = chunks

        // ---- Symbols + edges: full-tree walk (depth-tracked) ----
        var symbols: [SymbolDraft] = []
        var edges: [EdgeDraft] = []
        var emittedTypeRefs = Set<String>()
        var stack: [(TSNode, Int)] = [(tree.root, 0)]
        while let (node, depth) = stack.popLast() {
            let t = node.typeName
            if profile.defTypes.contains(t), depth <= (profile.defDepths[t] ?? Int.max) {
                if let raw = declaredName(of: node, in: bytes, profile: profile) {
                    // Strip quotes around data-format keys (json "key").
                    let name = raw.count > 1 && raw.hasPrefix("\"") && raw.hasSuffix("\"")
                        ? String(raw.dropFirst().dropLast()) : raw
                    if !name.isEmpty {
                        let text = node.text(in: bytes)
                        symbols.append(SymbolDraft(
                            name: name, kind: t, line: node.startRow + 1,
                            signature: firstLine(text),
                            chunkIndex: chunkIndex(forLine: node.startRow + 1, in: chunks),
                            declText: String(text.prefix(256))))
                    }
                }
            }
            if profile.callTypes.contains(t) {
                let callee = node.field("function") ?? firstNamedChild(of: node)
                let name = callee?.terminalIdentifier(in: bytes)
                if let name, !name.isEmpty, !profile.callDenylist.contains(name) {
                    edges.append(EdgeDraft(
                        kind: "calls", dstName: name, line: node.startRow + 1,
                        chunkIndex: chunkIndex(forLine: node.startRow + 1, in: chunks),
                        qualifier: callee.flatMap { callQualifier(of: $0, in: bytes) }))
                    // Uppercase callees are constructor-ish across the
                    // supported grammars (`Foo()`, `new Foo()`, `Foo(...)`);
                    // emit a parallel `instantiates` edge so constructor
                    // usages stay findable when `calls` is filtered out.
                    if name.first?.isUppercase == true {
                        edges.append(EdgeDraft(
                            kind: "instantiates", dstName: name,
                            line: node.startRow + 1,
                            chunkIndex: chunkIndex(forLine: node.startRow + 1,
                                                   in: chunks)))
                    }
                }
            }
            if profile.typeRefTypes.contains(t) {
                for tn in typeNamesIn(node, in: bytes) {
                    // Overlapping type node kinds (type_annotation > type >
                    // user_type) would emit the same ref several times.
                    let key = "\(node.startRow + 1):\(tn)"
                    if emittedTypeRefs.insert(key).inserted {
                        edges.append(EdgeDraft(
                            kind: "uses_type", dstName: tn,
                            line: node.startRow + 1,
                            chunkIndex: chunkIndex(forLine: node.startRow + 1,
                                                   in: chunks)))
                    }
                }
            }
            if profile.importTypes.contains(t) {
                let raw = firstLine(node.text(in: bytes))
                let dst = node.terminalIdentifier(in: bytes) ?? raw
                if !dst.isEmpty {
                    edges.append(EdgeDraft(
                        kind: "imports", dstName: dst, line: node.startRow + 1,
                        chunkIndex: chunkIndex(forLine: node.startRow + 1, in: chunks)))
                }
            }
            if profile.implTypes.contains(t) {
                // Nominal subtyping — no denylist: common protocols (Equatable,
                // Codable, ABC, ...) must still emit; unresolvable stdlib names
                // just stay NULL at resolution time.
                for dst in implementsTargets(of: node, in: bytes) {
                    edges.append(EdgeDraft(
                        kind: "implements", dstName: dst, line: node.startRow + 1,
                        chunkIndex: chunkIndex(forLine: node.startRow + 1, in: chunks)))
                }
            }
            var i = node.childCount - 1
            while i >= 0 {
                if let c = node.child(i) { stack.append((c, depth + 1)) }
                i -= 1
            }
        }
        result.symbols = symbols
        result.edges = edges
        return result
    }

    // MARK: - Chunk emission

    private static func emitChunks(node: TSNode, bytes: [UInt8], profile: LanguageProfile,
                                   depth: Int, into out: inout [ChunkDraft]) {
        // Absolute recursion cap: `transparentTypes` below deliberately
        // bypasses the depth<3 descent limit, so pathologically deep
        // (generated) input must not overflow the stack.
        if depth > 64 { return }
        let t = node.typeName
        if profile.chunkTypes.contains(t) {
            let lineCount = node.endRow - node.startRow + 1
            if lineCount <= maxChunkLines {
                out.append(ChunkDraft(
                    startLine: node.startRow + 1, endLine: node.endRow + 1,
                    kind: t, symbol: declaredName(of: node, in: bytes, profile: profile),
                    content: node.text(in: bytes)))
            } else {
                // Split oversized declarations into their child declarations + gap windows.
                var inner: [ChunkDraft] = []
                var i = 0
                while i < node.childCount {
                    if let c = node.child(i), c.isNamed {
                        if profile.chunkTypes.contains(c.typeName)
                            || profile.transparentTypes.contains(c.typeName) {
                            emitChunks(node: c, bytes: bytes, profile: profile,
                                       depth: depth + 1, into: &inner)
                        }
                    }
                    i += 1
                }
                if inner.isEmpty {
                    out.append(ChunkDraft(
                        startLine: node.startRow + 1, endLine: node.endRow + 1,
                        kind: t, symbol: declaredName(of: node, in: bytes, profile: profile),
                        content: node.text(in: bytes)))
                } else {
                    inner.sort { $0.startLine < $1.startLine }
                    let nodeText = node.text(in: bytes)
                    let nodeLines = nodeText.components(separatedBy: "\n")
                    var cur = node.startRow + 1
                    for ic in inner {
                        if ic.startLine > cur {
                            out.append(contentsOf: windowChunks(
                                lines: nodeLines, from: cur - node.startRow,
                                to: ic.startLine - node.startRow - 1, lineOffset: node.startRow))
                        }
                        out.append(ic)
                        cur = max(cur, ic.endLine + 1)
                    }
                    if node.endRow + 1 > cur {
                        out.append(contentsOf: windowChunks(
                            lines: nodeLines, from: cur - node.startRow,
                            to: node.endRow + 1 - node.startRow, lineOffset: node.startRow))
                    }
                }
            }
            return
        }
        if profile.transparentTypes.contains(t) || depth < 3 {
            var i = 0
            while i < node.childCount {
                if let c = node.child(i), c.isNamed {
                    emitChunks(node: c, bytes: bytes, profile: profile, depth: depth + 1, into: &out)
                }
                i += 1
            }
        }
    }

    /// Window chunks over absolute line range [from, to] (1-based, inclusive).
    private static func windowChunks(lines: [String], from: Int, to: Int,
                                     lineOffset: Int = 0) -> [ChunkDraft] {
        guard to >= from else { return [] }
        var out: [ChunkDraft] = []
        var start = from
        while start <= to {
            let end = min(start + windowLines - 1, to)
            let lo = max(start - 1 - lineOffset, 0)
            let hi = min(end - lineOffset, lines.count)
            guard lo < hi else { break }
            out.append(ChunkDraft(
                startLine: start, endLine: end, kind: "window", symbol: nil,
                content: lines[lo..<hi].joined(separator: "\n")))
            if end == to { break }
            start = end - windowOverlap + 1
        }
        return out
    }

    /// Heuristic chunks for languages without a grammar (markdown by headings, else windows).
    private static func heuristicChunks(lines: [String], languageID: String) -> [ChunkDraft] {
        if languageID == "markdown" {
            var out: [ChunkDraft] = []
            var start = 1
            for (i, l) in lines.enumerated() where l.hasPrefix("#") && i > 0 {
                if i - start + 1 > 4 {
                    out.append(ChunkDraft(startLine: start, endLine: i, kind: "section",
                                          symbol: nil, content: lines[(start - 1)..<i].joined(separator: "\n")))
                    start = i + 1
                }
            }
            if lines.count - start + 1 > 0 {
                out.append(ChunkDraft(startLine: start, endLine: lines.count, kind: "section",
                                      symbol: nil, content: lines[(start - 1)...].joined(separator: "\n")))
            }
            if !out.isEmpty { return out }
        }
        return windowChunks(lines: lines, from: 1, to: max(lines.count, 1))
    }

    /// Markdown `#`-headings as navigable symbols.
    private static func markdownSymbols(lines: [String], chunks: [ChunkDraft]) -> [SymbolDraft] {
        var out: [SymbolDraft] = []
        for (i, l) in lines.enumerated() where l.hasPrefix("#") {
            let text = l.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                out.append(SymbolDraft(
                    name: String(text.prefix(120)), kind: "heading", line: i + 1,
                    signature: String(l.prefix(200)),
                    chunkIndex: chunkIndex(forLine: i + 1, in: chunks)))
            }
        }
        return out
    }

    // MARK: - Helpers

    static func declaredName(of node: TSNode, in bytes: [UInt8],
                             profile: LanguageProfile) -> String? {
        for f in profile.nameFields {
            if let n = node.field(f)?.text(in: bytes), !n.isEmpty { return n }
        }
        var i = 0
        while i < node.childCount {
            if let c = node.child(i) {
                switch c.typeName {
                case "identifier", "type_identifier", "field_identifier",
                     "property_identifier", "simple_identifier":
                    let s = c.text(in: bytes)
                    if !s.isEmpty { return s }
                case "variable_declarator", "assignment", "init_declarator":
                    if let s = c.field("name")?.text(in: bytes), !s.isEmpty { return s }
                    if let s = c.terminalIdentifier(in: bytes) { return s }
                default:
                    break
                }
            }
            i += 1
        }
        return nil
    }

    /// Base/extended/implemented type names for a declaration node whose type
    /// is in `profile.implTypes`. Per-language shapes (verified against the
    /// vendored grammars):
    ///  - swift: `inheritance_specifier` children of `class_declaration` (this
    ///    grammar emits `class_declaration` for struct/class/enum/extension/
    ///    actor decls) and `protocol_declaration`.
    ///  - python: named children of the `class_definition`'s `argument_list`;
    ///    `keyword_argument`s (metaclass=...) are not bases; `object` skipped.
    ///  - ts/tsx: `class_heritage` → `extends_clause`/`implements_clause`
    ///    (class + abstract class), `extends_type_clause` (interface).
    ///  - rust: `impl_item`'s `trait` field — nil for inherent `impl Type`.
    static func implementsTargets(of node: TSNode, in bytes: [UInt8]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func emit(_ n: TSNode) {
            guard let s = nominalTypeName(of: n, in: bytes),
                  s != "object", seen.insert(s).inserted else { return }
            out.append(s)
        }
        // rust: `impl Trait for Type` — the trait field; inherent impls
        // (`impl Type {}`) have no trait field and emit nothing.
        if node.typeName == "impl_item" {
            if let trait = node.field("trait") { emit(trait) }
            return out
        }
        var i = 0
        while i < node.childCount {
            defer { i += 1 }
            guard let c = node.child(i), c.isNamed else { continue }
            switch c.typeName {
            case "inheritance_specifier":            // swift
                emit(c)
            case "argument_list":                    // python bases
                var j = 0
                while j < c.childCount {
                    if let a = c.child(j), a.isNamed,
                       a.typeName != "keyword_argument" {
                        emit(a)
                    }
                    j += 1
                }
            case "class_heritage":                   // ts/tsx classes
                var j = 0
                while j < c.childCount {
                    if let clause = c.child(j), clause.isNamed {
                        var k = 0
                        while k < clause.childCount {
                            if let t2 = clause.child(k), t2.isNamed { emit(t2) }
                            k += 1
                        }
                    }
                    j += 1
                }
            case "extends_type_clause":              // ts/tsx interfaces
                var j = 0
                while j < c.childCount {
                    if let t2 = c.child(j), t2.isNamed { emit(t2) }
                    j += 1
                }
            default:
                break
            }
        }
        return out
    }

    /// The name of a type node stripped to its resolvable base: plain
    /// identifiers as-is, qualified access to its leaf (`mod.Base` → `Base`,
    /// `a::Trait` → `Trait`), parameterized types to the generic head
    /// (`Box<T>`/`Generic[T]`/`J<K>` → `Box`/`Generic`/`J`).
    static func nominalTypeName(of node: TSNode, in bytes: [UInt8]) -> String? {
        switch node.typeName {
        case "identifier", "type_identifier", "property_identifier",
             "field_identifier", "simple_identifier":
            let s = node.text(in: bytes)
            return s.isEmpty ? nil : s
        case "member_expression", "attribute",
             "user_type", "scoped_type_identifier",
             "nested_type_identifier", "scoped_identifier", "type":
            // Qualified chains: leaf is the LAST identifier-ish child; skips
            // trailing `type_arguments` (`Mod.Proto` → Proto, `Box<Int>` →
            // Box since type_arguments yields nil and the scan continues).
            var i = node.childCount - 1
            while i >= 0 {
                if let c = node.child(i), c.isNamed,
                   let s = nominalTypeName(of: c, in: bytes) { return s }
                i -= 1
            }
            return nil
        case "generic_type", "subscript", "expression_with_type_arguments",
             "inheritance_specifier":
            // Base is the FIRST named child (`generic_type`/`subscript` head);
            // `inheritance_specifier` may lead with an `inheritance_modifier`
            // which resolves to nil, then the `user_type` child is found.
            var i = 0
            while i < node.childCount {
                if let c = node.child(i), c.isNamed,
                   let s = nominalTypeName(of: c, in: bytes) { return s }
                i += 1
            }
            return nil
        default:
            return nil
        }
    }

    /// Receiver root-identifier of a call callee: `parser.add_argument` →
    /// `parser`, `a.b.f` → `a`, `self._h` → `self`. Bare `f()` → nil.
    /// Covers python `attribute` (object field), js/ts `member_expression`
    /// (object), rust `field_expression`/`scoped_identifier` (value), go
    /// `selector_expression` (operand), swift `navigation_expression` (target).
    static func callQualifier(of callee: TSNode, in bytes: [UInt8]) -> String? {
        for f in ["object", "value", "operand", "target"] {
            if let recv = callee.field(f), let root = recv.rootIdentifier(in: bytes) {
                return root
            }
        }
        return nil
    }

    /// Capitalized type names inside an annotation node — covers the head
    /// plus generic parameters (`List[Foo]` yields List, Foo; denylist drops
    /// the builtin). Lowercase leaves are skipped: in annotations they are
    /// module/variable noise, not types.
    static func typeNamesIn(_ node: TSNode, in bytes: [UInt8]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var stack = [node]
        while let n = stack.popLast() {
            switch n.typeName {
            case "type_identifier", "identifier", "simple_identifier",
                 "field_identifier", "property_identifier":
                let s = n.text(in: bytes)
                if let f = s.first, f.isUppercase,
                   !Languages.typeDenylist.contains(s), seen.insert(s).inserted {
                    out.append(s)
                }
            default:
                var i = n.childCount - 1
                while i >= 0 {
                    if let c = n.child(i), c.isNamed { stack.append(c) }
                    i -= 1
                }
            }
        }
        return out
    }

    static func firstNamedChild(of node: TSNode) -> TSNode? {
        var i = 0
        while i < node.childCount {
            if let c = node.child(i), c.isNamed { return c }
            i += 1
        }
        return nil
    }

    static func firstLine(_ s: String) -> String {
        for line in s.split(separator: "\n", maxSplits: 8) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(200)) }
        }
        return String(s.prefix(200))
    }

    /// Chunk index containing a 1-based line; nearest preceding chunk if uncovered.
    static func chunkIndex(forLine line: Int, in chunks: [ChunkDraft]) -> Int {
        var best = -1
        for (i, c) in chunks.enumerated() {
            if line >= c.startLine && line <= c.endLine { return i }
            if c.startLine <= line { best = i }
        }
        return best == -1 && !chunks.isEmpty ? 0 : best
    }
}
