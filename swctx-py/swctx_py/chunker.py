"""Chunking — tree-sitter when available, line-window fallback otherwise."""
from __future__ import annotations

try:
    from tree_sitter_language_pack import get_parser  # type: ignore
    _HAVE_TS = True
except Exception:
    _HAVE_TS = False

TS_LANG = {
    "python": "python", "javascript": "javascript", "typescript": "typescript",
    "tsx": "tsx", "swift": "swift", "go": "go", "rust": "rust",
    "java": "java", "ruby": "ruby", "php": "php", "bash": "bash",
    "kotlin": "kotlin", "json": "json", "yaml": "yaml", "markdown": "markdown",
}

DEF_TYPES = {
    "python": {"function_definition", "class_definition"},
    "javascript": {"function_declaration", "class_declaration", "method_definition",
                   "generator_function_declaration", "lexical_declaration"},
    "typescript": {"function_declaration", "class_declaration", "method_definition",
                   "interface_declaration", "type_alias_declaration",
                   "enum_declaration", "lexical_declaration"},
    "tsx": {"function_declaration", "class_declaration", "method_definition",
            "interface_declaration", "type_alias_declaration",
            "enum_declaration", "lexical_declaration"},
    "swift": {"function_declaration", "class_declaration", "struct_declaration",
              "enum_declaration", "protocol_declaration", "extension_declaration",
              "init_declaration", "typealias_declaration"},
    "go": {"function_declaration", "method_declaration", "type_declaration"},
    "rust": {"function_item", "struct_item", "enum_item", "impl_item",
             "trait_item", "mod_item", "type_item"},
    "java": {"method_declaration", "class_declaration", "interface_declaration",
             "enum_declaration", "constructor_declaration"},
    "ruby": {"method", "class", "module", "singleton_method"},
    "php": {"function_definition", "class_declaration", "method_declaration"},
    "kotlin": {"function_declaration", "class_declaration", "object_declaration"},
}
MAX_CHUNK_LINES = 120
WINDOW = 60
OVERLAP = 15

# Regex symbol fallback — used when tree-sitter is unavailable so that
# find_definitions/find_usages still work on window chunks.
import re

_SYMBOL_RE = {
    "python": re.compile(r"^\s*(?:async\s+)?(?:def|class)\s+([A-Za-z_]\w*)"),
    "javascript": re.compile(
        r"^\s*(?:export\s+)?(?:async\s+)?(?:function\s+([A-Za-z_$]\w*)|class\s+([A-Za-z_$]\w*)|(?:const|let|var)\s+([A-Za-z_$]\w*)\s*=\s*(?:async\s*)?(?:\(|function))"),
    "typescript": re.compile(
        r"^\s*(?:export\s+)?(?:async\s+)?(?:function\s+([A-Za-z_$]\w*)|class\s+([A-Za-z_$]\w*)|interface\s+([A-Za-z_$]\w*)|(?:const|let|var)\s+([A-Za-z_$]\w*)\s*=\s*(?:async\s*)?(?:\(|function)|enum\s+([A-Za-z_$]\w*)|type\s+([A-Za-z_$]\w*)\s*=)"),
    "tsx": re.compile(
        r"^\s*(?:export\s+)?(?:async\s+)?(?:function\s+([A-Za-z_$]\w*)|class\s+([A-Za-z_$]\w*)|interface\s+([A-Za-z_$]\w*)|(?:const|let|var)\s+([A-Za-z_$]\w*)\s*=\s*(?:async\s*)?(?:\(|function)|enum\s+([A-Za-z_$]\w*)|type\s+([A-Za-z_$]\w*)\s*=)"),
    "swift": re.compile(
        r"^\s*(?:public|private|internal|fileprivate|open|static|final|override|mutating|nonmutating|@\w+\s*)*\s*(?:func\s+([A-Za-z_]\w*)|class\s+([A-Za-z_]\w*)|struct\s+([A-Za-z_]\w*)|enum\s+([A-Za-z_]\w*)|extension\s+([A-Za-z_]\w*)|protocol\s+([A-Za-z_]\w*))"),
    "go": re.compile(r"^func\s+(?:\(\w+\s+\*?\w+\)\s+)?([A-Za-z_]\w*)|^type\s+([A-Za-z_]\w*)"),
    "rust": re.compile(r"^\s*(?:pub\s+)?(?:fn\s+([A-Za-z_]\w*)|struct\s+([A-Za-z_]\w*)|enum\s+([A-Za-z_]\w*)|trait\s+([A-Za-z_]\w*)|impl\s+([A-Za-z_]\w*))"),
    "java": re.compile(r"^\s*(?:public|private|protected|static|final|abstract|\s)*\s*(?:class\s+([A-Za-z_]\w*)|interface\s+([A-Za-z_]\w*)|enum\s+([A-Za-z_]\w*))"),
    "ruby": re.compile(r"^\s*(?:def\s+([A-Za-z_]\w*[!?=]?)|class\s+([A-Za-z_]\w*)|module\s+([A-Za-z_]\w*))"),
    "php": re.compile(r"^\s*(?:public|private|protected|static|\s)*\s*(?:function\s+([A-Za-z_]\w*)|class\s+([A-Za-z_]\w*))"),
}


def _name_of(node, src: bytes) -> str:
    n = node.child_by_field_name("name")
    if n is None:
        for c in node.children:
            if c.type == "identifier" or c.type == "type_identifier":
                n = c
                break
    return src[n.start_byte:n.end_byte].decode("utf8", "replace") if n else ""


def _walk_defs(node, lang: str, src: bytes, out: list, depth: int = 0):
    deftypes = DEF_TYPES.get(lang, set())
    for child in node.children:
        if depth <= 3 and child.type in deftypes:
            out.append(child)
        _walk_defs(child, lang, src, out, depth + 1)


def chunk(path: str, lang: str, text: str) -> list[dict]:
    """Return [{start,end,symbol,type,content}] 1-based lines."""
    lines = text.splitlines()
    if not lines:
        return []
    if _HAVE_TS and lang in TS_LANG:
        try:
            return _ts_chunks(path, lang, text, lines)
        except Exception:
            pass
    return _window_chunks(lines, lang)


def _ts_chunks(path: str, lang: str, text: str, lines: list[str]) -> list[dict]:
    src = text.encode("utf8", "replace")
    parser = get_parser(TS_LANG[lang])
    tree = parser.parse(src)
    defs: list = []
    _walk_defs(tree.root_node, lang, src, defs)
    chunks: list[dict] = []
    covered = [False] * (len(lines) + 1)
    for d in defs:
        s, e = d.start_point[0] + 1, d.end_point[0] + 1
        if e - s > MAX_CHUNK_LINES:
            e = s + MAX_CHUNK_LINES
        for i in range(s, e + 1):
            covered[i] = True
        chunks.append({"start": s, "end": e,
                       "symbol": _name_of(d, src), "type": d.type,
                       "content": "\n".join(lines[s - 1:e])})
    # uncovered regions -> windows
    i = 1
    while i <= len(lines):
        while i <= len(lines) and covered[i]:
            i += 1
        j = i
        while j <= len(lines) and not covered[j] and j - i < WINDOW:
            j += 1
        if j > i:
            chunks.append({"start": i, "end": j - 1, "symbol": "",
                           "type": "", "content": "\n".join(lines[i - 1:j - 1])})
        i = j
    chunks.sort(key=lambda c: c["start"])
    return [c for c in chunks if c["content"].strip()]


def _window_chunks(lines: list[str], lang: str = "") -> list[dict]:
    out: list[dict] = []
    sym_re = _SYMBOL_RE.get(lang)
    i = 0
    while i < len(lines):
        j = min(len(lines), i + WINDOW)
        window = lines[i:j]
        content = "\n".join(window)
        if content.strip():
            sym = ""
            if sym_re:
                for ln in window:
                    m = sym_re.match(ln)
                    if m:
                        sym = next(g for g in m.groups() if g)
                        break
            out.append({"start": i + 1, "end": j, "symbol": sym,
                        "type": "def" if sym else "", "content": content})
        i += WINDOW - OVERLAP
    return out
