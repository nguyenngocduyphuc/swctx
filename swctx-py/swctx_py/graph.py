"""graph_neighbors / graph_expand / graph_paths / get_impact — BFS/DFS
walks over the resolved edge table. Port of the SwctxCore/Tools.swift
graph handlers: same arg names, caps and output shape.

Schema mapping vs the Swift index: chunks.file_id already stores the
relative path (no files join needed) and Swift's c.kind/c.symbol are
symbol_type/symbol_name here.
"""
# ruff: noqa: S608 — dynamic SQL interpolates only ?-placeholder counts
# (IN lists) and fixed column names; every value is a bound parameter.
from __future__ import annotations

import math

from .store import Store

# graph_expand BFS bound (depth <= 2) and result cap — Swift constants.
_EXPAND_DEPTH = 2
_EXPAND_CAP = 60
_PATH_BATCH = 500  # graph_paths frontier batch for IN() lists


def _kind_cond(edge_kinds: list[str] | None) -> tuple[str, list]:
    if not edge_kinds:
        return "", []
    ph = ",".join("?" * len(edge_kinds))
    return f" AND e.kind IN ({ph})", list(edge_kinds)


def _chunk_dict(row) -> dict:
    """chunk_meta row -> the Swift chunkDict shape: kind/symbol keys are
    omitted when NULL; content is merged by the caller when requested."""
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
    return d


def chunk_meta(store: Store, ids: list[int]) -> dict[int, dict]:
    """Hydrate neighbor chunk metadata — Set(ids).prefix(100) in Swift."""
    if not ids:
        return {}
    out: dict[int, dict] = {}
    for cid in list(dict.fromkeys(ids))[:100]:
        r = store.db.execute(
            "SELECT id, file_id, start_line, end_line, symbol_type, "
            "symbol_name FROM chunks WHERE id = ?", (cid,)).fetchone()
        if r:
            out[cid] = _chunk_dict(r)
    return out


def chunk_contents(store: Store, ids: list[int]) -> dict[int, str]:
    """Optional source bodies — ids.prefix(50) in Swift."""
    out: dict[int, str] = {}
    for cid in ids[:50]:
        r = store.db.execute(
            "SELECT content FROM chunks WHERE id = ?", (cid,)).fetchone()
        if r and r[0] is not None:
            out[cid] = r[0]
    return out


def neighbors(store: Store, chunk_id: int, direction: str = "both",
              edge_kinds: list[str] | None = None, depth: int = 1,
              limit: int = 20, include_content: bool = False) -> dict:
    """Call/import graph neighbors of a chunk; BFS when depth > 1.
    Unresolved edges (dst_chunk NULL) are emitted at their depth but
    can't be traversed further."""
    direction = direction or "both"
    limit = min(limit, 200)
    max_depth = min(depth, 3)
    cond, kind_params = _kind_cond(edge_kinds)
    out: list[dict] = []
    visited: set[int] = {chunk_id}
    frontier: list[int] = [chunk_id]
    d = 0
    while frontier and d < max_depth and len(out) < limit:
        d += 1
        ph = ",".join("?" * len(frontier))
        nxt: list[int] = []
        if direction != "incoming":
            rows = store.db.execute(
                "SELECT e.dst_chunk AS nid, e.kind, e.dst_name, e.line "
                f"FROM edges e WHERE e.src_chunk IN ({ph}){cond}",
                frontier + kind_params).fetchall()
            for nid, kind, dst_name, line in rows:
                out.append({"chunk_id": nid, "direction": "outgoing",
                            "edge_kind": kind or "", "dst_name": dst_name or "",
                            "line": line or 0, "depth": d})
                if nid is not None and nid not in visited:
                    visited.add(nid)
                    nxt.append(nid)
        if direction != "outgoing":
            rows = store.db.execute(
                "SELECT e.src_chunk AS nid, e.kind, e.dst_name, e.line "
                f"FROM edges e WHERE e.dst_chunk IN ({ph}){cond}",
                frontier + kind_params).fetchall()
            for nid, kind, dst_name, line in rows:
                out.append({"chunk_id": nid, "direction": "incoming",
                            "edge_kind": kind or "", "dst_name": dst_name or "",
                            "line": line or 0, "depth": d})
                if nid is not None and nid not in visited:
                    visited.add(nid)
                    nxt.append(nid)
        frontier = nxt
    if len(out) > limit:
        out = out[:limit]
    ids = [o["chunk_id"] for o in out if o["chunk_id"] is not None]
    meta = chunk_meta(store, ids)
    contents = chunk_contents(store, ids) if include_content else {}
    hydrated = []
    for o in out:
        o2 = dict(o)
        cid = o["chunk_id"]
        if cid is not None and cid in meta:
            m = dict(meta[cid])
            if cid in contents:
                m["content"] = contents[cid]
            o2["chunk"] = m
        hydrated.append(o2)
    return {"chunk_id": chunk_id, "neighbors": hydrated}


def expand(store: Store, seeds: list, mode: str = "related",
           include_content: bool = False) -> dict:
    """BFS from seed chunk_ids (depth <= 2) over resolved edges. Results
    carry depth, via and the seed's score decayed by 0.7^depth; dedupe by
    chunk_id keeps the smallest depth. Seeds never appear in results."""
    parsed: list[tuple[int, float]] = []
    seen_seeds: set[int] = set()
    for v in seeds[:50]:
        p = None
        if isinstance(v, dict) and isinstance(
                v.get("chunk_id"), (int, float)) and not isinstance(
                v.get("chunk_id"), bool):
            sc = v.get("score")
            p = (int(v["chunk_id"]),
                 float(sc) if isinstance(sc, (int, float))
                 and not isinstance(sc, bool) else 1.0)
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            p = (int(v), 1.0)
        if p and p[0] not in seen_seeds:
            seen_seeds.add(p[0])
            parsed.append(p)
    if not parsed:
        raise ValueError("missing required argument: seeds")
    cond, kind_params = ("", [])
    if mode in ("calls", "imports"):
        cond, kind_params = " AND e.kind = ?", [mode]
    # nid -> (depth, via, score, edge_kind)
    best: dict[int, tuple[int, int, float, str]] = {}
    in_graph = {sid for sid, _ in parsed}
    frontier = parsed
    depth = 0
    while frontier and depth < _EXPAND_DEPTH and len(best) < _EXPAND_CAP:
        depth += 1
        fids = [sid for sid, _ in frontier]
        ph = ",".join("?" * len(fids))
        score_of = {sid: sc for sid, sc in frontier}
        nxt: list[tuple[int, float]] = []

        # Defaults bind this level's loop vars (B023).
        def record(nid: int, via: int, kind: str, *,
                   _depth: int = depth, _score_of: dict = score_of,
                   _nxt: list = nxt) -> None:
            if len(best) >= _EXPAND_CAP:
                return
            s = _score_of.get(via, 1.0) * (0.7 ** _depth)
            if nid not in in_graph:
                in_graph.add(nid)
                best[nid] = (_depth, via, s, kind)
                _nxt.append((nid, _score_of.get(via, 1.0)))
            elif (nid in best and best[nid][0] == _depth
                  and s > best[nid][2]):
                best[nid] = (_depth, via, s, kind)

        # Same SQL shape as graph_neighbors, resolved edges only.
        for f, nid, kind in store.db.execute(
                "SELECT e.src_chunk AS f, e.dst_chunk AS nid, e.kind "
                "FROM edges e WHERE e.dst_chunk IS NOT NULL "
                f"AND e.src_chunk IN ({ph}){cond}",
                fids + kind_params):
            if f is not None and nid is not None:
                record(nid, f, kind or "")
        for f, nid, kind in store.db.execute(
                "SELECT e.dst_chunk AS f, e.src_chunk AS nid, e.kind "
                "FROM edges e WHERE e.dst_chunk IS NOT NULL "
                f"AND e.dst_chunk IN ({ph}){cond}",
                fids + kind_params):
            if f is not None and nid is not None:
                record(nid, f, kind or "")
        frontier = nxt
    ordered = sorted(
        best.items(),
        key=lambda kv: (kv[1][0], -kv[1][2], kv[0]))[:_EXPAND_CAP]
    ids = [cid for cid, _ in ordered]
    meta = chunk_meta(store, ids)
    contents = chunk_contents(store, ids) if include_content else {}
    results = []
    for cid, b in ordered:
        entry = {
            "chunk_id": cid, "depth": b[0], "via": b[1],
            # Swift .rounded() = half away from zero
            "score": math.floor(b[2] * 10000 + 0.5) / 10000,
            "edge_kind": b[3],
        }
        if cid in meta:
            m = dict(meta[cid])
            if cid in contents:
                m["content"] = contents[cid]
            entry["chunk"] = m
        results.append(entry)
    return {"mode": mode, "seed_count": len(parsed),
            "count": len(results), "results": results}


def paths(store: Store, from_chunk_id: int, to_chunk_id: int,
          max_hops: int = 5, max_paths: int = 3,
          strategy: str = "shortest",
          edge_kinds: list[str] | None = None,
          include_content: bool = False) -> dict:
    """Paths between two chunks through resolved call edges.
    strategy: shortest (frontier-batched BFS, default) | all | all_simple
    (DFS simple-path enumeration)."""
    max_hops = min(max_hops, 8)
    max_paths = min(max(max_paths, 1), 10)
    cond, kind_params = _kind_cond(edge_kinds)

    def edges_from(ids: list[int]) -> list[tuple[int, int]]:
        ph = ",".join("?" * len(ids))
        rows = store.db.execute(
            "SELECT e.src_chunk AS src, e.dst_chunk AS dst "
            "FROM edges e WHERE e.dst_chunk IS NOT NULL "
            f"AND e.src_chunk IN ({ph}){cond}",
            list(ids) + kind_params).fetchall()
        return [(s, dd) for s, dd in rows
                if s is not None and dd is not None]

    found_paths: list[list[int]] = []
    if strategy in ("all", "all_simple"):
        # DFS enumeration of simple paths (no repeated nodes), depth-first
        # so alternatives beyond the shortest are explored; neighbors are
        # queried per popped node.
        stack: list[list[int]] = [[from_chunk_id]]
        while stack and len(found_paths) < max_paths:
            path = stack.pop()
            last = path[-1]
            if last == to_chunk_id:
                found_paths.append(path)
                continue
            if len(path) > max_hops:
                continue
            in_path = set(path)
            for _src, dst in edges_from([last]):
                if dst not in in_path:
                    stack.append([*path, dst])
    else:
        # "shortest": level-by-level BFS — nodes are consumed once via
        # `seen`, a parent map replaces per-queue paths, and discovery of
        # the target exits before draining the level.
        parent: dict[int, int] = {}
        seen: set[int] = {from_chunk_id}
        frontier: list[int] = [from_chunk_id]
        depth = 0
        while frontier and depth < max_hops and to_chunk_id not in seen:
            nxt: list[int] = []
            i = 0
            while i < len(frontier) and to_chunk_id not in seen:
                batch = frontier[i:i + _PATH_BATCH]
                i += len(batch)
                for _src, dst in edges_from(batch):
                    if dst not in seen:
                        seen.add(dst)
                        parent[dst] = _src
                        nxt.append(dst)
            frontier = nxt
            depth += 1
        if to_chunk_id in seen:
            path = [to_chunk_id]
            while path[-1] in parent:
                path.append(parent[path[-1]])
            found_paths = [list(reversed(path))]
    all_ids = [cid for p in found_paths for cid in p]
    meta = chunk_meta(store, all_ids)
    contents = chunk_contents(store, all_ids) if include_content else {}
    payload = []
    for p in found_paths:
        node_list = []
        for cid in p:
            m = dict(meta.get(cid, {"chunk_id": cid}))
            if cid in contents:
                m["content"] = contents[cid]
            node_list.append({"chunk_id": cid, "chunk": m})
        payload.append(node_list)
    return {"paths": payload, "found": len(found_paths)}


def impact(store: Store, chunk_id: int, max_hops: int = 2,
           include_content: bool = False) -> dict:
    """Transitive dependents of a chunk — 'if I change this, what
    breaks?': BFS over incoming resolved edges."""
    max_hops = min(max_hops, 4)
    seen: set[int] = {chunk_id}
    affected: list[int] = []  # BFS discovery order (Swift uses a Set)
    frontier: list[int] = [chunk_id]
    hops = 0
    while frontier and hops < max_hops:
        ph = ",".join("?" * len(frontier))
        rows = store.db.execute(
            "SELECT DISTINCT src_chunk FROM edges "
            f"WHERE dst_chunk IN ({ph})", frontier).fetchall()
        nxt = [r[0] for r in rows if r[0] is not None and r[0] not in seen]
        seen.update(nxt)
        affected.extend(nxt)
        frontier = nxt
        hops += 1
    meta = chunk_meta(store, affected)
    contents = chunk_contents(store, affected) if include_content else {}
    dependents = []
    for cid in affected:
        m = dict(meta.get(cid, {"chunk_id": cid}))
        if cid in contents:
            m["content"] = contents[cid]
        dependents.append(m)
    return {"chunk_id": chunk_id, "max_hops": max_hops,
            "dependents": dependents}
