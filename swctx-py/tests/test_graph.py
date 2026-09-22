"""graph_paths / graph_neighbors / graph_expand / get_impact /
inspect_path — mirrors Tests/SwctxCoreTests/GraphPathsTests.swift:
a direct-SQL fixture gives precise edge control and deterministic chunk
ids/row order without running the indexer."""
import json
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from swctx_py.fold import fold_text, path_token_string, symbol_token_string
from swctx_py.mcp_server import call
from swctx_py.store import Store


def make_workspace(tmp: str, chunks: dict, edges: list,
                   files: tuple = ("g.py",)) -> Store:
    """Temp workspace + direct-SQL fixture. `edges` holds
    (src, dst|None, kind) — dst None models an unresolved edge."""
    s = Store(tmp)
    for fp in files:
        s.db.execute(
            "INSERT INTO files(path, sha, mtime, lang) VALUES(?,?,0,?)",
            (fp, "x", "python"))
    for cid, (fp, sym) in chunks.items():
        s.db.execute(
            "INSERT INTO chunks(id, file_id, start_line, end_line,"
            " symbol_name, symbol_type, content, path_tokens,"
            " symbol_tokens) VALUES(?,?,1,2,?,'function',?,?,?)",
            (cid, fp, sym, f"def {sym}(): pass",
             path_token_string(fp), symbol_token_string([sym])))
        s.db.execute(
            "INSERT INTO symbols(name, type, chunk_id, file_id, line)"
            " VALUES(?,?,?,?,1)", (sym, "function", cid, fp))
    for src, dst, kind in edges:
        s.db.execute(
            "INSERT INTO edges(src_chunk, dst_chunk, dst_name, kind,"
            " line) VALUES(?,?,?,?,1)",
            (src, dst, chunks.get(dst, (None, "?"))[1], kind))
    if s.fts_ok:
        for cid, (fp, sym) in chunks.items():
            s.db.execute(
                "INSERT INTO fts_chunks(content, path_tokens,"
                " symbol_tokens, folded, chunk_id) VALUES(?,?,?,?,?)",
                (f"def {sym}(): pass", path_token_string(fp),
                 symbol_token_string([sym]),
                 fold_text(f"def {sym}(): pass"), cid))
    s.db.commit()
    return s


def _path_ids(out: str):
    payload = json.loads(out)
    paths = [[n["chunk_id"] for n in p] for p in payload["paths"]]
    return payload["found"], paths


def _paths(tmp, frm, to, **extra):
    args = {"workspace": tmp, "from_chunk_id": frm, "to_chunk_id": to}
    args.update(extra)
    return _path_ids(call("graph_paths", args))


def test_shortest_picks_direct_route():
    """a -> b -> c plus the a -> c shortcut: shortest picks the direct
    route (a, c), never the longer a -> b -> c detour."""
    with tempfile.TemporaryDirectory() as tmp:
        make_workspace(tmp, {1: ("g.py", "a"), 2: ("g.py", "b"),
                             3: ("g.py", "c")},
                       [(1, 2, "calls"), (2, 3, "calls"), (1, 3, "calls")])
        found, paths = _paths(tmp, 1, 3)
        assert found == 1
        assert paths == [[1, 3]]


def test_all_simple_enumerates_both_paths():
    """Same graph, strategy=all_simple: both simple paths enumerated."""
    with tempfile.TemporaryDirectory() as tmp:
        make_workspace(tmp, {1: ("g.py", "a"), 2: ("g.py", "b"),
                             3: ("g.py", "c")},
                       [(1, 2, "calls"), (2, 3, "calls"), (1, 3, "calls")])
        found, paths = _paths(tmp, 1, 3, strategy="all_simple",
                              max_paths=10)
        assert found == 2
        assert {tuple(p) for p in paths} == {(1, 3), (1, 2, 3)}


def test_wide_frontier_beyond_batch():
    """600-node fan-out: the level-1 frontier exceeds the 500-id batch
    size, so traversal must issue >1 IN() query for that level — and the
    target is reachable only through a mid in the second batch. An
    `imports` shortcut checks edge_kinds still filters frontier scans."""
    with tempfile.TemporaryDirectory() as tmp:
        chunks = {1: ("g.py", "root"), 602: ("g.py", "target")}
        edges = []
        for i in range(600):
            mid = i + 2  # mids: 2..601
            chunks[mid] = ("g.py", f"mid_{i}")
            edges.append((1, mid, "calls"))
        edges.append((601, 602, "calls"))  # only the last mid reaches target
        edges.append((1, 602, "imports"))  # non-calls shortcut for the filter
        make_workspace(tmp, chunks, edges)

        found, paths = _paths(tmp, 1, 602, edge_kinds=["calls"])
        assert found == 1
        assert paths == [[1, 601, 602]]

        # Unfiltered: the imports edge is a resolved edge like any other —
        # it wins as the 1-hop path.
        found, paths = _paths(tmp, 1, 602)
        assert found == 1
        assert paths == [[1, 602]]


def test_paths_no_route_and_validation():
    with tempfile.TemporaryDirectory() as tmp:
        make_workspace(tmp, {1: ("g.py", "a"), 2: ("g.py", "b")},
                       [])  # no edges
        found, paths = _paths(tmp, 1, 2)
        assert found == 0 and paths == []
        # from == to: BFS sees the target immediately -> [from]
        found, paths = _paths(tmp, 1, 1)
        assert found == 1 and paths == [[1]]
        with pytest.raises(ValueError, match="from_chunk_id"):
            call("graph_paths", {"workspace": tmp, "from_chunk_id": 1})


def test_neighbors_directions_and_unresolved():
    """Outgoing/incoming/both legs, BFS depth, and unresolved edges
    (dst_chunk NULL) emitted but never traversed."""
    with tempfile.TemporaryDirectory() as tmp:
        # 4 -> 1 -> 2 -> 3 plus an unresolved 1 -> ? edge and an
        # imports edge 1 -> 5 for the kind filter.
        make_workspace(
            tmp,
            {1: ("g.py", "a"), 2: ("g.py", "b"), 3: ("g.py", "c"),
             4: ("g.py", "d"), 5: ("g.py", "e")},
            [(4, 1, "calls"), (1, 2, "calls"), (2, 3, "calls"),
             (1, None, "calls"), (1, 5, "imports")])

        out = json.loads(call("graph_neighbors", {
            "workspace": tmp, "chunk_id": 1, "direction": "outgoing"}))
        assert out["chunk_id"] == 1
        assert [(n["chunk_id"], n["direction"], n["edge_kind"], n["depth"])
                for n in out["neighbors"]] == [
            (2, "outgoing", "calls", 1),
            (None, "outgoing", "calls", 1),
            (5, "outgoing", "imports", 1)]
        # hydrated chunk metadata attaches to resolved ids only
        by_id = {n["chunk_id"]: n for n in out["neighbors"]}
        assert by_id[2]["chunk"]["symbol"] == "b"
        assert by_id[2]["chunk"]["path"] == "g.py"
        assert by_id[2]["chunk"]["kind"] == "function"
        assert "chunk" not in by_id[None]
        assert by_id[None]["dst_name"] == "?"

        out = json.loads(call("graph_neighbors", {
            "workspace": tmp, "chunk_id": 1, "direction": "incoming"}))
        assert [(n["chunk_id"], n["direction"]) for n in out["neighbors"]
                ] == [(4, "incoming")]

        # both = outgoing rows then incoming rows per level
        out = json.loads(call("graph_neighbors", {
            "workspace": tmp, "chunk_id": 1}))
        assert [n["direction"] for n in out["neighbors"]] == [
            "outgoing", "outgoing", "outgoing", "incoming"]

        # depth=2 BFS: 2's outgoing edge reaches 3 (4 is visited already
        # via the incoming leg? no — 4 only appears on incoming legs).
        out = json.loads(call("graph_neighbors", {
            "workspace": tmp, "chunk_id": 1, "direction": "outgoing",
            "depth": 2}))
        assert [n["chunk_id"] for n in out["neighbors"]] == [
            2, None, 5, 3]
        assert out["neighbors"][-1]["depth"] == 2

        # edge_kinds filter
        out = json.loads(call("graph_neighbors", {
            "workspace": tmp, "chunk_id": 1,
            "edge_kinds": ["imports"]}))
        assert [(n["chunk_id"], n["edge_kind"])
                for n in out["neighbors"]] == [(5, "imports")]

        with pytest.raises(ValueError, match="chunk_id"):
            call("graph_neighbors", {"workspace": tmp})


def test_expand_decay_via_and_modes():
    """BFS from seeds over resolved edges: depth<=2, score decays by
    0.7^depth, `via` records the parent; seeds never appear in results."""
    with tempfile.TemporaryDirectory() as tmp:
        # 1 -> 2 -> 3 -> 4 plus an imports edge 1 -> 5
        make_workspace(
            tmp,
            {1: ("g.py", "a"), 2: ("g.py", "b"), 3: ("g.py", "c"),
             4: ("g.py", "d"), 5: ("g.py", "e")},
            [(1, 2, "calls"), (2, 3, "calls"), (3, 4, "calls"),
             (1, 5, "imports")])

        out = json.loads(call("graph_expand", {
            "workspace": tmp,
            "seeds": [{"chunk_id": 1, "score": 1.0}]}))
        assert out["mode"] == "related"
        assert out["seed_count"] == 1
        by_id = {r["chunk_id"]: r for r in out["results"]}
        assert set(by_id) == {2, 3, 5}  # 4 is depth 3 -> out of range
        assert by_id[2]["depth"] == 1 and by_id[2]["via"] == 1
        assert by_id[2]["score"] == pytest.approx(0.7, abs=1e-4)
        assert by_id[3]["depth"] == 2 and by_id[3]["via"] == 2
        assert by_id[3]["score"] == pytest.approx(0.49, abs=1e-4)
        assert by_id[5]["edge_kind"] == "imports"
        assert by_id[2]["chunk"]["symbol"] == "b"
        # sorted by depth asc, score desc
        depths = [r["depth"] for r in out["results"]]
        assert depths == sorted(depths)

        # mode=calls excludes the imports edge
        out = json.loads(call("graph_expand", {
            "workspace": tmp, "seeds": [1], "mode": "calls"}))
        assert {r["chunk_id"] for r in out["results"]} == {2, 3}

        # int seeds accepted; dedupe by chunk_id
        out = json.loads(call("graph_expand", {
            "workspace": tmp, "seeds": [1, 1, {"chunk_id": 1}]}))
        assert out["seed_count"] == 1

        with pytest.raises(ValueError, match="seeds"):
            call("graph_expand", {"workspace": tmp, "seeds": []})


def test_impact_transitive_dependents():
    """get_impact: transitive incoming edges (dependents) bounded by
    max_hops."""
    with tempfile.TemporaryDirectory() as tmp:
        # 1 calls 2 calls 3 calls 4 — dependents of 4: {3, 2, 1} by hops
        make_workspace(
            tmp,
            {1: ("g.py", "a"), 2: ("g.py", "b"), 3: ("g.py", "c"),
             4: ("g.py", "d")},
            [(1, 2, "calls"), (2, 3, "calls"), (3, 4, "calls")])

        out = json.loads(call("get_impact", {
            "workspace": tmp, "chunk_id": 4, "max_hops": 1}))
        assert out["max_hops"] == 1
        assert [d["chunk_id"] for d in out["dependents"]] == [3]
        assert out["dependents"][0]["symbol"] == "c"

        out = json.loads(call("get_impact", {
            "workspace": tmp, "chunk_id": 4}))
        assert {d["chunk_id"] for d in out["dependents"]} == {2, 3}

        out = json.loads(call("get_impact", {
            "workspace": tmp, "chunk_id": 4, "max_hops": 4}))
        assert {d["chunk_id"] for d in out["dependents"]} == {1, 2, 3}

        out = json.loads(call("get_impact", {
            "workspace": tmp, "chunk_id": 1}))
        assert out["dependents"] == []


def test_inspect_path_browse_limit_and_query():
    with tempfile.TemporaryDirectory() as tmp:
        make_workspace(
            tmp,
            {1: ("src/a.py", "alpha"), 2: ("src/a.py", "beta"),
             3: ("src/sub/b.py", "gamma"), 4: ("top.py", "delta")},
            [],
            files=("src/a.py", "src/sub/b.py", "top.py"))

        # directory browse: chunks under src/, ordered by path then id
        out = json.loads(call("inspect_path", {
            "workspace": tmp, "path": "src"}))
        assert out["reranked"] is False
        assert [(c["path"], c["chunk_id"]) for c in out["chunks"]] == [
            ("src/a.py", 1), ("src/a.py", 2), ("src/sub/b.py", 3)]
        assert "content" not in out["chunks"][0]
        assert out["chunks"][0]["symbol"] == "alpha"
        assert out["chunks"][0]["kind"] == "function"

        # exact file
        out = json.loads(call("inspect_path", {
            "workspace": tmp, "path": "src/sub/b.py"}))
        assert [c["chunk_id"] for c in out["chunks"]] == [3]

        # include_content + pagination
        out = json.loads(call("inspect_path", {
            "workspace": tmp, "path": "src", "include_content": True,
            "limit": 1, "offset": 1}))
        assert [c["chunk_id"] for c in out["chunks"]] == [2]
        assert "def beta" in out["chunks"][0]["content"]

        # query mode: hybrid rerank scoped to the subtree
        out = json.loads(call("inspect_path", {
            "workspace": tmp, "path": "src", "query": "gamma"}))
        assert out["reranked"] is True
        assert out["chunks"] and out["chunks"][0]["chunk_id"] == 3
        assert "score" in out["chunks"][0]

        # absolute / traversal paths are rejected
        for bad in ("/abs/path", "../up", "a/../../b"):
            out = json.loads(call("inspect_path", {
                "workspace": tmp, "path": bad}))
            assert "error" in out

        with pytest.raises(ValueError, match="path"):
            call("inspect_path", {"workspace": tmp})


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
