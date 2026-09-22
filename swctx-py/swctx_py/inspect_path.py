"""inspect_path — browse indexed chunks under a relative file/directory
path; optional query reranks them via the hybrid search legs scoped to
the subtree. Port of SwctxTools.inspectPath (same arg names, caps and
output shape; chunks.file_id is the path here)."""
# ruff: noqa: S608 — SQL interpolates only a fixed column list; all
# values are bound parameters.
from __future__ import annotations

from .search import Searcher
from .store import Store

_COLS = ("c.id, c.file_id, c.start_line, c.end_line, "
         "c.symbol_type, c.symbol_name")


def _chunk_dict(row, content: bool) -> dict:
    """Port of SwctxTools.chunkDict — kind/symbol omitted when NULL,
    content only when requested."""
    d = {
        "chunk_id": row[0] if row[0] is not None else -1,
        "path": row[1] or "",
        "start_line": row[2] or 0,
        "end_line": row[3] or 0,
    }
    if row[4] is not None:
        d["kind"] = row[4]
    if row[5] is not None:
        d["symbol"] = row[5]
    if content and row[6] is not None:
        d["content"] = row[6]
    return d


def run(store: Store, path: str, query: str | None = None,
        limit: int = 50, offset: int = 0, rerank_pool_size: int = 150,
        include_content: bool = False) -> dict:
    limit = min(limit, 200)
    pool_size = min(rerank_pool_size, 500)
    like = "%" if path == "" else (
        path + "%" if path.endswith("/") else path + "/%")
    extra = ", c.content" if include_content else ""
    rows = store.db.execute(
        f"SELECT {_COLS}{extra} FROM chunks c "
        "WHERE c.file_id LIKE ? OR c.file_id = ? "
        "ORDER BY c.file_id, c.id LIMIT ? OFFSET ?",
        (like, path, limit, offset)).fetchall()
    # Optional query: hybrid-rank across the whole path subtree, not just
    # the first `limit` rows in path order. `rerank_pool_size` widens the
    # candidate pool; `offset` slices the ranked pool.
    if query:
        hits = Searcher(store).search(
            query, pool_size, path_filter=path, event_tool="inspect_path")
        sliced = hits[max(0, offset):max(0, offset) + limit]
        chunks = []
        for h in sliced:
            r = store.db.execute(
                f"SELECT {_COLS}{extra} FROM chunks c WHERE c.id = ?",
                (h["chunk_id"],)).fetchone()
            if r is None:
                continue
            d = _chunk_dict(r, include_content)
            d["score"] = h["score"]
            chunks.append(d)
        return {"chunks": chunks, "reranked": True}
    return {"chunks": [_chunk_dict(r, include_content) for r in rows],
            "reranked": False}
