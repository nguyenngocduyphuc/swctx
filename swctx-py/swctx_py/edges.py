"""Edge extraction — regex-based call/inherit graph (v0, no tree-sitter).

Kinds mirror the Swift indexer: calls | implements | extends.
dst_name is always recorded; dst_chunk is resolved post-index.
Unresolved names cost a row but still power simulate_patch lookups.
"""
from __future__ import annotations

import re

CALL_RX = re.compile(r"\b([A-Za-z_]\w*)\s*\(")
_DECL_BEFORE = re.compile(
    r"\b(?:def|func|function|fn|sub|class|subscript|init|new|fun)\s*$")

# Control-flow / builtin / declaration words that look like calls.
DENY = frozenset({
    "if", "elif", "else", "for", "while", "do", "switch", "case", "match",
    "return", "yield", "break", "continue", "pass", "goto", "defer",
    "def", "func", "function", "fn", "class", "struct", "enum", "trait",
    "interface", "protocol", "extension", "actor", "impl", "type",
    "typealias", "namespace", "package", "mod", "use", "using", "import",
    "from", "require", "include", "export", "let", "var", "const",
    "static", "pub", "private", "protected", "public", "new", "delete",
    "try", "catch", "except", "finally", "raise", "throw", "throws",
    "assert", "await", "async", "with", "in", "is", "not", "and", "or",
    "true", "false", "none", "nil", "null", "undefined", "self", "this",
    "super", "init", "sizeof", "typeof", "where", "guard", "some", "any",
    "print", "println", "echo", "printf", "panic", "len", "str", "int",
    "float", "bool", "list", "dict", "set", "tuple", "range", "type",
    "isinstance", "hasattr", "getattr", "setattr", "enumerate", "zip",
    "map", "filter", "min", "max", "sum", "abs", "sorted", "open",
    "make", "append", "copy", "cap", "close", "select", "chan", "go",
    "void", "char", "long", "double", "string", "foreach", "elif",
    "endif", "then", "fi", "done", "esac", "until", "repeat",
})

# Inheritance/implements per language: (regex, kind). Applied per line.
_PY_BASES = re.compile(r"^\s*class\s+\w+\s*\(([^)]*)\)")
_TS_IMPL = re.compile(r"\b(extends|implements)\s+([A-Za-z_]\w*)")
_SW_INHERIT = re.compile(
    r"^\s*(?:public |private |internal |fileprivate |open |final |"
    r"indirect |nonisolated |@\w+\s+)*\s*(?:class|struct|enum|extension|"
    r"actor)\s+\w+[^:{]*:\s*([A-Za-z_]\w*)")
_RS_IMPL = re.compile(r"\bimpl\s+([A-Za-z_]\w*(?:::\w+)*)\s+for\s+")

_INHERIT = {
    "python": "py",
    "typescript": "ts", "tsx": "ts", "javascript": "ts",
    "swift": "sw", "rust": "rs",
}

# Prose/data formats produce call-edge noise — code languages only.
_CODE = frozenset({
    "python", "javascript", "typescript", "tsx", "swift", "go", "rust",
    "java", "ruby", "php", "kotlin", "bash", "html",
})

# Cross-boundary API links: route defs become `route` symbols, call
# sites become `api_call` edges keyed on the normalized path — the
# generic name-resolution pass then links fetch('/api/x') -> handler.
_ROUTE_DEF_RX = re.compile(
    r"(?:@[A-Za-z_][\w.]*|\b(?:app|router|server|api|bp|blueprint|web))"
    r"\s*[.\s]\s*"
    r"(?:get|post|put|patch|delete|head|options|route|use|add_route"
    r"|add_url_rule)\s*\(\s*[\"']([^\"']+)[\"']")
_ROUTE_CALL_RX = re.compile(
    r"\b(?:fetch|axios|request|apiFetch|apiClient|client|http|callApi"
    r"|apiCall)(?:\s*\.\s*(?:get|post|put|patch|delete|head|options"
    r"|request|fetch))?\s*\(\s*[`'\"]([^`'\"\s]+)")
# Bare literals only under a canonical API root — other leading-slash
# strings are file paths or prose.
_ROUTE_LIT_RX = re.compile(r"[\"'](/(?:api|v\d|graphql|auth)[^'\"\s]*)[\"']")
_API_ROOTS = frozenset(
    {"api", "graphql", "auth", "health", "status", "webhook", "oauth"})


def norm_route(raw: str) -> str | None:
    """Canonical route key: leading '/', no query/fragment/trailing '/'.
    Absolute URLs collapse to their path. Single-segment strings only
    pass under a known API root — '/ROOT'/'/FILE' are env vars."""
    p = raw.strip()
    m = re.match(r"^https?://[^/]+", p)
    if m:
        p = p[m.end():]
        if not p:
            return None
    for sep in ("?", "#"):
        if sep in p:
            p = p[:p.index(sep)]
    if not p.startswith("/"):
        p = "/" + p
    while len(p) > 1 and p.endswith("/"):
        p = p[:-1]
    if len(p) <= 1 or " " in p:
        return None
    first = p[1:].split("/", 1)[0]
    two_segs = len(first) < len(p) - 1
    api_root = (first.lower() in _API_ROOTS
                or (first.startswith("v") and first[1:].isdigit()))
    return p if two_segs or api_root else None


def route_defs(content: str, lang: str | None,
               base_line: int) -> list[tuple[str, int]]:
    """Route definitions in one chunk -> [(path, line)] for symbols."""
    if lang not in _CODE:
        return []
    out: list[tuple[str, int]] = []
    seen: set[tuple[str, int]] = set()
    for i, line in enumerate(content.splitlines()):
        for m in _ROUTE_DEF_RX.finditer(line):
            p = norm_route(m.group(1))
            if p and (p, base_line + i) not in seen:
                seen.add((p, base_line + i))
                out.append((p, base_line + i))
    return out


def extract(content: str, lang: str | None,
            base_line: int) -> list[tuple[str, str, int]]:
    """Return [(dst_name, kind, line)] for one chunk body."""
    if lang not in _CODE:
        return []
    out: list[tuple[str, str, int]] = []
    seen: set[tuple[str, int]] = set()
    for i, line in enumerate(content.splitlines()):
        ln = base_line + i
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "//", "*", "<!--")):
            continue
        for m in CALL_RX.finditer(line):
            name = m.group(1)
            if name.lower() in DENY or (name, ln) in seen:
                continue
            # skip declaration sites: `def f(`, `func f(`, `class F(`, `new F(`
            if _DECL_BEFORE.search(line[:m.start()]):
                continue
            seen.add((name, ln))
            out.append((name, "calls", ln))
        fam = _INHERIT.get(lang or "")
        if fam == "py":
            for m in _PY_BASES.finditer(line):
                for b in m.group(1).split(","):
                    b = b.strip().split(".")[-1].split("[")[0].strip()
                    if b and b[0].isalpha() and b not in ("object",):
                        out.append((b, "extends", ln))
        elif fam == "ts":
            for m in _TS_IMPL.finditer(line):
                out.append((m.group(2), m.group(1), ln))
        elif fam == "sw":
            for m in _SW_INHERIT.finditer(line):
                out.append((m.group(1), "implements", ln))
        elif fam == "rs":
            for m in _RS_IMPL.finditer(line):
                out.append((m.group(1).split("::")[-1], "implements", ln))
        # API call sites. Def lines emit a `route` symbol instead — the
        # literal pass must not turn '@app.get("/x")' into a self-call.
        is_def = _ROUTE_DEF_RX.search(line) is not None
        for m in _ROUTE_CALL_RX.finditer(line):
            p = norm_route(m.group(1))
            if p and (f"@{p}", ln) not in seen:
                seen.add((f"@{p}", ln))
                out.append((p, "api_call", ln))
        if not is_def:
            for m in _ROUTE_LIT_RX.finditer(line):
                p = norm_route(m.group(1))
                if p and (f"@{p}", ln) not in seen:
                    seen.add((f"@{p}", ln))
                    out.append((p, "api_call", ln))
    return out
