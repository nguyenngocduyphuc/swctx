"""simulate_patch — unified diff in, broken dependents out (port of
SwctxCore/Simulate.swift). Read-only; never mutates the index.

Two change classes: signature (name redeclared on the + side) / removed
(name gone) → every edge targeting the symbol is a break candidate; and
body hunks (no decl line removed) → dependents of the enclosing symbol.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from .store import Store

_FILE_RX = re.compile(r"^\+\+\+ b/(.+)$", re.M)
_HUNK_RX = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,(\d+))? @@", re.M)


@dataclass
class Hunk:
    old_start: int
    new_start: int
    removed: list[str] = field(default_factory=list)
    added: list[str] = field(default_factory=list)


@dataclass
class FileDiff:
    path: str
    hunks: list[Hunk] = field(default_factory=list)


def parse_diff(text: str) -> list[FileDiff]:
    files: list[FileDiff] = []
    cur: FileDiff | None = None
    hunk: Hunk | None = None

    def flush() -> None:
        nonlocal cur, hunk
        if cur is not None:
            if hunk is not None:
                cur.hunks.append(hunk)
            files.append(cur)
        cur = None
        hunk = None

    for line in text.splitlines():
        if line.startswith("+++ b/"):
            flush()
            cur = FileDiff(path=line[6:])
            continue
        m = _HUNK_RX.match(line)
        if m:
            if cur is not None and hunk is not None:
                cur.hunks.append(hunk)
            hunk = Hunk(old_start=int(m.group(1)), new_start=int(m.group(2)))
            continue
        if hunk is not None:
            if line.startswith("-") and not line.startswith("---"):
                hunk.removed.append(line[1:])
            elif line.startswith("+") and not line.startswith("+++"):
                hunk.added.append(line[1:])
    flush()
    return files


# First-capture-group regexes that pull a declared name out of a source
# line, keyed by language id (discover.lang_of values).
_DECL_RX: dict[str, list[re.Pattern]] = {
    "swift": [
        re.compile(r"\b(?:func|init|deinit|subscript|var|let|typealias)\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:class|struct|enum|protocol|actor|extension)\s+([A-Za-z_]\w*)"),
    ],
    "python": [
        re.compile(r"\bdef\s+([A-Za-z_]\w*)"),
        re.compile(r"\bclass\s+([A-Za-z_]\w*)"),
    ],
    "javascript": [
        re.compile(r"\bfunction\s+([A-Za-z_]\w*)"),
        re.compile(r"\bclass\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:const|let|var)\s+([A-Za-z_]\w*)\s*="),
    ],
    "typescript": [
        re.compile(r"\bfunction\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:class|interface|type|enum)\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:const|let|var)\s+([A-Za-z_]\w*)\s*[:=]"),
    ],
    "tsx": [
        re.compile(r"\bfunction\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:class|interface|type|enum)\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:const|let|var)\s+([A-Za-z_]\w*)\s*[:=]"),
    ],
    "go": [
        re.compile(r"\bfunc\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"),
        re.compile(r"\btype\s+([A-Za-z_]\w*)"),
    ],
    "rust": [
        re.compile(r"\bfn\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:struct|enum|trait|union)\s+([A-Za-z_]\w*)"),
    ],
    "bash": [re.compile(r"^\s*([A-Za-z_]\w*)\s*\(\s*\)")],
    "java": [
        re.compile(r"\b(?:class|interface|enum|record)\s+([A-Za-z_]\w*)"),
        re.compile(r"^\s*(?:public|private|protected|static|final|"
                   r"synchronized|abstract|@\w+\s*)+[\w<>\[\], ?]+\s+"
                   r"([A-Za-z_]\w*)\s*\("),
    ],
    "kotlin": [
        re.compile(r"\bfun\s+(?:[\w.]+\.)?([A-Za-z_]\w*)"),
        re.compile(r"\b(?:class|interface|object|enum class)\s+([A-Za-z_]\w*)"),
    ],
    "ruby": [
        re.compile(r"\bdef\s+([A-Za-z_]\w*[!?=]?)"),
        re.compile(r"\b(?:class|module)\s+([A-Za-z_]\w*)"),
    ],
    "php": [
        re.compile(r"\bfunction\s+([A-Za-z_]\w*)"),
        re.compile(r"\b(?:class|interface|trait|enum)\s+([A-Za-z_]\w*)"),
    ],
}

_TEST_RX = re.compile(r"(?i)(test|tests|spec|__tests__|testing)")


def _removed_decls(lang: str | None, lines: list[str]) -> list[str]:
    rxs = _DECL_RX.get(lang or "", [])
    out: list[str] = []
    seen: set[str] = set()
    for line in lines:
        for rx in rxs:
            for m in rx.finditer(line):
                name = m.group(1)
                if name not in seen:
                    seen.add(name)
                    out.append(name)
    return out


def _lang_of(path: str) -> str | None:
    from .discover import lang_of
    return lang_of(path)


_PARAMS_RX = re.compile(r"[A-Za-z_]\w*\s*\(([^)]*)\)")


def _param_count(decl_line: str, name: str) -> int | None:
    """Rough arity from a declaration line: `name(a, b=1)` → 2."""
    i = decl_line.find(name + "(")
    if i < 0:
        return None
    m = _PARAMS_RX.search(decl_line, i)
    if not m:
        return None
    inner = m.group(1).strip()
    if not inner:
        return 0
    # strip defaults/generics noise; count top-level commas
    return inner.count(",") + 1


def run(store: Store, diff: str, max_callers: int = 50) -> dict:
    file_diffs = parse_diff(diff)
    if not file_diffs:
        return {"files_changed": 0, "symbols": [], "body_changes": [],
                "risk": {}, "note": "no unified-diff hunks parsed"}

    def def_chunks(name: str) -> set[int]:
        return {r[0] for r in store.db.execute(
            "SELECT chunk_id FROM symbols WHERE name=?", (name,))}

    def dependents(name: str, kinds: list[str],
                   defs: set[int]) -> list[dict]:
        ph = ",".join("?" * len(kinds))
        rows = store.db.execute(
            f"SELECT e.line, e.kind, c.file_id AS path, e.src_chunk, "
            f"e.dst_chunk "
            f"FROM edges e JOIN chunks c ON c.id = e.src_chunk "
            f"WHERE e.dst_name = ? AND e.kind IN ({ph}) "
            f"ORDER BY path LIMIT ?",
            [name, *kinds, max_callers]).fetchall()
        return [{"path": r[2], "line": r[0], "edge": r[1],
                 "chunk_id": r[3],
                 "resolved": r[4] in defs if r[4] is not None else False}
                for r in rows]

    symbols: list[dict] = []
    body_changes: list[dict] = []

    for fd in file_diffs:
        lang = _lang_of(fd.path)
        removed = [ln for h in fd.hunks for ln in h.removed]
        added = [ln for h in fd.hunks for ln in h.added]
        decls = _removed_decls(lang, removed)
        added_decls = set(_removed_decls(lang, added))

        for name in decls:
            defs = def_chunks(name)
            # arity change: `-` decl vs `+` decl param counts
            arity = None
            if name in added_decls:
                old = next((ln for ln in removed if name + "(" in ln), "")
                new = next((ln for ln in added if name + "(" in ln), "")
                po, pn = _param_count(old, name), _param_count(new, name)
                if po is not None and pn is not None and po != pn:
                    arity = f"{po}→{pn}"
            entry = {
                "name": name, "file": fd.path,
                "change": "signature" if name in added_decls else "removed",
                "definitions": len(defs),
                "callers": dependents(
                    name, ["calls", "instantiates", "uses_type"], defs),
                "implementers": dependents(
                    name, ["implements", "extends"], defs),
            }
            if arity:
                entry["arity"] = arity
            symbols.append(entry)

        for h in fd.hunks:
            if _removed_decls(lang, h.removed):
                continue
            if not h.removed and not h.added:
                continue
            row = store.db.execute(
                "SELECT id, symbol_name FROM chunks WHERE file_id = ? "
                "AND start_line <= ? AND end_line >= ? "
                "ORDER BY (end_line - start_line) ASC LIMIT 1",
                (fd.path, h.old_start, h.old_start)).fetchone()
            if not row:
                continue
            sym = row[1] or "?"
            body_changes.append({
                "file": fd.path, "old_line": h.old_start,
                "enclosing_symbol": sym, "enclosing_chunk": row[0],
                "dependent_callers": [] if sym == "?" else dependents(
                    sym, ["calls", "instantiates", "uses_type"],
                    def_chunks(sym)),
            })

    all_callers = [c for s in symbols for c in s["callers"]]
    broken = {c["path"] for c in all_callers}
    test_files = {p for p in broken if _TEST_RX.search(p)}
    resolved_n = sum(1 for c in all_callers if c["resolved"])
    return {
        "files_changed": len(file_diffs),
        "symbols": symbols,
        "body_changes": body_changes,
        "risk": {
            "broken_call_sites": len(all_callers),
            "resolved_call_sites": resolved_n,
            "affected_prod_files": sorted(broken - test_files),
            "affected_test_files": sorted(test_files),
        },
        "note": "static approximation — dynamic dispatch, string-keyed "
                "lookups and macro-generated code are not modeled",
    }
