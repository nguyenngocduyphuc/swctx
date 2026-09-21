"""test_coverage — symbol<->test map over call edges (port of
SwctxCore Tools.testCoverage). Read-only; never mutates the index.

Two directions over the same edge data:
  symbol_name -> test chunks whose calls reach it ("which tests to run")
  path        -> non-test symbols that file exercises ("what it covers")
Static approximation: no dynamic dispatch, no string-keyed tests.
"""
from __future__ import annotations

from .simulate import _TEST_RX
from .store import Store

_NOTE = ("static call-edge map — dynamic dispatch and string-keyed "
         "tests are not modeled")


def run(store: Store, symbol_name: str | None = None,
        path: str | None = None, limit: int = 50) -> dict:
    limit = min(limit, 200)
    if symbol_name:
        rows = store.db.execute(
            "SELECT DISTINCT c.file_id, c.id, c.symbol_name, "
            "c.start_line, c.end_line, e.kind "
            "FROM edges e JOIN chunks c ON c.id = e.src_chunk "
            "WHERE (e.dst_name = ? OR e.dst_chunk IN "
            "(SELECT chunk_id FROM symbols WHERE name = ?)) "
            "ORDER BY c.file_id, e.line LIMIT ?",
            (symbol_name, symbol_name, limit * 4)).fetchall()
        tests = [{"chunk_id": r[1], "path": r[0], "symbol": r[2],
                  "lines": f"{r[3]}-{r[4]}", "edge": r[5]}
                 for r in rows if _TEST_RX.search(r[0])][:limit]
        return {"symbol": symbol_name, "tests": tests,
                "count": len(tests), "note": _NOTE}
    if path:
        rows = store.db.execute(
            "SELECT DISTINCT s.name, s.file_id, e.kind "
            "FROM edges e JOIN chunks c ON c.id = e.src_chunk "
            "JOIN symbols s ON s.chunk_id = e.dst_chunk "
            "WHERE c.file_id = ? AND e.dst_chunk IS NOT NULL "
            "ORDER BY s.name LIMIT ?", (path, limit * 4)).fetchall()
        covers = [{"symbol": r[0], "path": r[1], "edge": r[2]}
                  for r in rows if not _TEST_RX.search(r[1])][:limit]
        return {"path": path, "covers": covers,
                "count": len(covers), "note": _NOTE}
    return {"error": "missing symbol_name or path"}
