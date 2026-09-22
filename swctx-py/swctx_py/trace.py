"""trace_lookup — stack trace in, indexed frames out (port of
SwctxCore/Trace.swift). Pure read over files/chunks/symbols/edges.

Parses Python `File "p", line N, in fn`, JS/TS `at fn (p:N:C)`
(incl. `at async`, `[as alias]`), Go panic `p:N +0x…`, and a generic
`path.ext:N` fallback; suffix-matches trace paths to indexed files and
maps each frame to its enclosing chunk. Static only — inlined calls,
source maps and native frames are not recoverable.
"""
from __future__ import annotations

import json as _json
import re

from .store import Store

_PY_RX = re.compile(r'File "([^"]+)", line (\d+)(?:, in (\S+))?')
_JS_RX = re.compile(
    r"\bat\s+(?:async\s+)?"
    r"(?:([\w$.<>]+)\s+(?:\[as\s+\S+\]\s+)?\()?"
    r"((?:file://)?[^\s()]+?):(\d+)(?::\d+)?\)?")
_GO_RX = re.compile(r"^\s*(\S+\.go):(\d+)\s+\+0x[0-9a-fA-F]+", re.M)
_GENERIC_RX = re.compile(
    r"([A-Za-z0-9_./\\-]+\.(?:swift|py|js|jsx|ts|tsx|mjs|cjs|go|rs|java"
    r"|kt|rb|php|m|mm|c|cc|cpp|h|hpp)):(\d+)")


def parse(text: str) -> list[dict]:
    """Frames in textual order; generic fallback skips ranges already
    claimed by the specific formats."""
    frames: list[tuple[int, dict]] = []
    claimed: list[tuple[int, int]] = []

    def add(rx: re.Pattern, path_at: int, line_at: int, sym_at: int):
        for m in rx.finditer(text):
            if any(a <= m.start() < b or m.start() <= a < m.end()
                   for a, b in claimed):
                continue
            claimed.append(m.span())
            path = m.group(path_at) or ""
            try:
                line = int(m.group(line_at))
            except (TypeError, ValueError):
                line = 0
            sym = m.group(sym_at) if sym_at > 0 else None
            if not path or line <= 0:
                continue
            frames.append((m.start(), {
                "raw": m.group(0), "path": path, "line": line,
                "symbol_hint": sym}))

    add(_PY_RX, 1, 2, 3)
    add(_JS_RX, 2, 3, 1)
    add(_GO_RX, 1, 2, -1)
    add(_GENERIC_RX, 1, 2, -1)
    return [f for _, f in sorted(frames, key=lambda t: t[0])]


def resolve(store: Store, frames: list[dict]) -> list[dict]:
    paths = sorted(r[0] for r in store.db.execute("SELECT path FROM files"))
    out: list[dict] = []
    for f in frames:
        norm = f["path"].replace("file://", "").replace("\\", "/")
        tparts = norm.split("/")
        best = None
        for p in paths:
            if norm == p or norm.endswith("/" + p) or p.endswith("/" + norm):
                if best is None or len(p) > len(best):
                    best = p
            else:
                iparts = p.split("/")
                if (len(iparts) <= len(tparts)
                        and tparts[-len(iparts):] == iparts
                        and (best is None or len(p) > len(best))):
                    best = p
        rec = {"raw": f["raw"], "trace_path": f["path"],
               "line": f["line"], "matched": best is not None}
        if f.get("symbol_hint"):
            rec["symbol_hint"] = f["symbol_hint"]
        if best:
            rec["path"] = best
            row = store.db.execute(
                "SELECT id, symbol_name, start_line, end_line FROM chunks "
                "WHERE file_id = ? AND start_line <= ? AND end_line >= ? "
                "ORDER BY (end_line - start_line) ASC LIMIT 1",
                (best, f["line"], f["line"])).fetchone()
            if row:
                rec["chunk_id"] = row[0]
                rec["symbol"] = row[1]
                rec["span"] = f"{row[2]}-{row[3]}"
        out.append(rec)
    return out


def suspects(store: Store, resolved: list[dict]) -> list[dict]:
    last = next((r for r in reversed(resolved) if r.get("matched")), None)
    if not last or "chunk_id" not in last:
        return []
    rows = store.db.execute(
        "SELECT DISTINCT c.file_id, e.line, c.symbol_name "
        "FROM edges e JOIN chunks c ON c.id = e.src_chunk "
        "WHERE e.dst_chunk = ? AND e.kind IN "
        "('calls','instantiates','uses_type','api_call') "
        "ORDER BY c.file_id LIMIT 20", (last["chunk_id"],)).fetchall()
    recent: set[str] = set()
    for (body,) in store.db.execute(
            "SELECT payload FROM records WHERE kind='commit' "
            "ORDER BY id DESC LIMIT 20"):
        try:
            recent.update(_json.loads(body).get("files", []))
        except (ValueError, AttributeError):
            pass
    out = []
    for path, line, sym in rows:
        r = {"path": path, "line": line, "symbol": sym}
        if path in recent:
            r["recent_commit"] = True
        out.append(r)
    return out


def run(store: Store, trace: str) -> dict:
    frames = parse(trace)
    if not frames:
        return {"frames": [], "count": 0,
                "note": "no frames parsed — expected Python/JS/Go "
                        "traceback lines or path:line references"}
    resolved = resolve(store, frames)
    matched = [r for r in resolved if r["matched"]]
    return {
        "frames": resolved, "count": len(resolved),
        "matched": len(matched),
        "suspects": suspects(store, resolved),
        "note": "static mapping — inlined calls, source maps and "
                "native frames are not recoverable"}
