"""Task-aware slicing — signature extraction shared by fetch_chunks
mode=signature and the outline tool (port of SwctxCore/Slice.swift).

Signature = leading lines until brackets balance (multi-line decls like
Swift/TS generics), capped at 6 lines, then `…` marks a sliced body.
"""
from __future__ import annotations

import re

_DECL_KW = re.compile(
    r"(?:func|def|class|struct|enum|fn|fun|function|sub|type|let|var|"
    r"const|public|private|static|extension|protocol|interface|trait|"
    r"impl|module|record|actor|init|void|int|async)\b[^\n]*\b")


def signature(content: str, symbol: str | None = None,
              max_lines: int = 6) -> str:
    """`symbol` anchors the scan: windowed chunks can start above the
    declaration (imports, constants), so seek the decl-looking line
    first, then accumulate until brackets balance."""
    lines = content.split("\n")
    if symbol:
        kw = _DECL_KW.pattern + re.escape(symbol)
        kw_rx = re.compile(kw)
        for i, ln in enumerate(lines):
            if (kw_rx.search(ln) or symbol + "(" in ln
                    or symbol + " =" in ln or symbol + ":" in ln):
                lines = lines[i:]
                break
    out: list[str] = []
    depth = 0
    saw_bracket = False
    for line in lines:
        out.append(line)
        for ch in line:
            if ch in "([<":
                depth += 1
                saw_bracket = True
            elif ch in ")]>":
                depth -= 1
        t = line.strip()
        if len(out) >= max_lines:
            break
        if (depth <= 0 and (saw_bracket or t.endswith(":") or
                            t.endswith("{") or t.endswith("=")
                            or len(out) >= 2)):
            break
    sig = "\n".join(out)
    if len(sig) < len(content):
        sig += "\n    …"
    return sig
