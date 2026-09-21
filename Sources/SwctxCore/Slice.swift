import Foundation

/// Task-aware slicing: return a chunk's declaration without its body.
/// Signature = leading lines until brackets balance (multi-line decls
/// like Swift/TS generics) capped at 6 lines, then `…`.
public enum Slice {

    /// `symbol` anchors the scan: windowed chunks can start above the
    /// declaration (imports, constants), so we first seek the line that
    /// looks like `… decl-kw symbol …` / `symbol(` / `symbol =`.
    public static func signature(of content: String, symbol: String? = nil,
                                 maxLines: Int = 6) -> String {
        var lines = content.split(separator: "\n",
                                  omittingEmptySubsequences: false)
            .map(String.init)
        if let sym = symbol, !sym.isEmpty,
           let idx = lines.firstIndex(where: {
               $0.range(of: #"(?:func|def|class|struct|enum|fn|fun|function|sub|type|let|var|const|public|private|static|extension|protocol|interface|trait|impl|module|record|actor|init|void|int|async)\b[^\n]*\b"# + NSRegularExpression.escapedPattern(for: sym),
                        options: .regularExpression) != nil
               || $0.contains(sym + "(") || $0.contains(sym + " =") || $0.contains(sym + ":")
           }) {
            lines = Array(lines[idx...])
        }
        var out: [String] = []
        var depth = 0
        var sawBracket = false
        for s in lines {
            out.append(s)
            for ch in s {
                switch ch {
                case "(", "[", "<": depth += 1; sawBracket = true
                case ")", "]", ">": depth -= 1
                default: break
                }
            }
            let t = s.trimmingCharacters(in: .whitespaces)
            if out.count >= maxLines { break }
            if depth <= 0,
               sawBracket || t.hasSuffix(":") || t.hasSuffix("{")
               || t.hasSuffix("=") || out.count >= 2 {
                break
            }
        }
        var sig = out.joined(separator: "\n")
        if sig.count < content.count { sig += "\n    …" }
        return sig
    }
}
