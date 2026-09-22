"""get_record / list_records — mirrors Tests/SwctxCoreTests/
GetRecordScopeTests.swift: scope dispatch (workspace | global | all),
not-indexed leniency, validation, and staleness evidence fields."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from swctx_py import records
from swctx_py.mcp_server import call
from swctx_py.store import Store


def _indexed(tmp: str) -> Store:
    """Minimal index: one file + one chunk + one symbol, so anchor
    capture and staleness resolution have real rows to check."""
    s = Store(tmp)
    s.db.execute(
        "INSERT INTO files(path, sha, mtime, lang) VALUES(?,?,0,?)",
        ("src/a.py", "x", "python"))
    s.db.execute(
        "INSERT INTO chunks(id, file_id, start_line, end_line,"
        " symbol_name, symbol_type, content) VALUES(1,'src/a.py',1,2,"
        " 'mysym','function','def mysym(): pass')")
    s.db.execute(
        "INSERT INTO symbols(name, type, chunk_id, file_id, line)"
        " VALUES('mysym','function',1,'src/a.py',1)")
    s.db.commit()
    return s


def _put(tmp: str, title: str, kind: str = "note",
         payload: str = "p") -> dict:
    return json.loads(call("put_record", {
        "workspace": tmp, "kind": kind, "title": title,
        "payload": payload}))


def _global_id(ws_key: str, title: str) -> int:
    db = records._connect()
    try:
        return db.execute(
            "SELECT id FROM records WHERE ws = ? AND title = ?",
            (ws_key, title)).fetchone()[0]
    finally:
        db.close()


def _cleanup(ws_key: str) -> None:
    db = records._connect()
    try:
        db.execute("DELETE FROM records WHERE ws = ?", (ws_key,))
        db.commit()
    finally:
        db.close()


def test_get_record_scopes():
    """scope=global finds the shared-ledger copy by ITS OWN id (not the
    workspace id put_record returns) and emits the `ws` field; scope=all
    on the workspace id returns the workspace copy (no `ws`)."""
    with tempfile.TemporaryDirectory() as tmp:
        _indexed(tmp)
        ws_key = records.repo_key(tmp)
        put = _put(tmp, "scoped get probe", payload="two ledgers, two ids")
        ws_id = put["record_id"]
        assert put["scope"] == "workspace+global"
        gid = _global_id(ws_key, "scoped get probe")
        assert gid != ws_id

        # Default scope: workspace ledger by the returned id.
        got = json.loads(call("get_record", {
            "workspace": tmp, "id": ws_id}))
        rec = got["record"]
        assert rec["title"] == "scoped get probe"
        assert rec["kind"] == "note"
        assert rec["source"] == "mcp" and rec["status"] == "completed"
        assert "ws" not in rec
        assert rec["payload"] == "two ledgers, two ids"
        # staleness fields attach when the store resolves
        assert rec["stale"] is False and rec["stale_reasons"] == []

        # scope=global: the global ledger, by the global id — `ws` on it.
        g = json.loads(call("get_record", {
            "workspace": tmp, "id": gid, "scope": "global"}))
        assert g["record"]["title"] == "scoped get probe"
        assert g["record"]["ws"] == ws_key

        # scope=all on the workspace id hits the workspace ledger first.
        all_ = json.loads(call("get_record", {
            "workspace": tmp, "id": ws_id, "scope": "all"}))
        assert all_["record"]["title"] == "scoped get probe"
        assert "ws" not in all_["record"]

        # include_payload=false drops the payload key
        got = json.loads(call("get_record", {
            "workspace": tmp, "id": ws_id, "include_payload": False}))
        assert "payload" not in got["record"]

        # scope=workspace on a global-only id reports not found.
        miss = json.loads(call("get_record", {
            "workspace": tmp, "id": 999_999_999}))
        assert miss["error"] == "record not found"
        assert miss["id"] == 999_999_999
        _cleanup(ws_key)


def test_get_record_scope_leniency():
    """scope=global/all only need the global ledger — an unindexed
    workspace resolves leniently instead of throwing not-indexed;
    scope=workspace still requires the index."""
    with tempfile.TemporaryDirectory() as tmp, \
            tempfile.TemporaryDirectory() as bare:
        _indexed(tmp)
        ws_key = records.repo_key(tmp)
        _put(tmp, "lenient get probe")
        gid = _global_id(ws_key, "lenient get probe")

        # Unindexed workspace + scope=global: global ledger answers anyway.
        g = json.loads(call("get_record", {
            "workspace": bare, "id": gid, "scope": "global"}))
        assert g["record"]["title"] == "lenient get probe"

        # scope=all falls back to the same global row.
        all_ = json.loads(call("get_record", {
            "workspace": bare, "id": gid, "scope": "all"}))
        assert all_["record"]["title"] == "lenient get probe"

        # scope=workspace on the unindexed dir still throws not-indexed.
        with pytest.raises(FileNotFoundError, match="no index"):
            call("get_record", {"workspace": bare, "id": gid})
        _cleanup(ws_key)


def test_get_record_scope_validation():
    """A scope outside the allowlist is an invalid-arg error."""
    with tempfile.TemporaryDirectory() as tmp:
        _indexed(tmp)
        with pytest.raises(ValueError, match="scope"):
            call("get_record", {"workspace": tmp, "id": 1,
                                "scope": "bogus"})
        with pytest.raises(ValueError, match="id"):
            call("get_record", {"workspace": tmp})


def test_list_records_filters_scopes_and_paging():
    with tempfile.TemporaryDirectory() as tmp:
        s = _indexed(tmp)
        ws_key = records.repo_key(tmp)
        _put(tmp, "lr note 1", kind="note")
        _put(tmp, "lr finding", kind="finding")
        _put(tmp, "lr note 2", kind="note")
        # a commit row sorts last via ORDER BY (kind='commit'), id DESC
        records.insert_ws(s, "commit", "abc123 init", "{}", source="git")

        out = json.loads(call("list_records", {"workspace": tmp}))
        assert out["total"] == 4
        assert [r["title"] for r in out["records"]] == [
            "lr note 2", "lr finding", "lr note 1", "abc123 init"]
        rec = out["records"][0]
        assert rec["kind"] == "note" and rec["source"] == "mcp"
        assert "ws" not in rec and rec["stale"] is False

        # kind filter + pagination over total
        out = json.loads(call("list_records", {
            "workspace": tmp, "kind": "note", "limit": 1}))
        assert out["total"] == 2
        assert [r["title"] for r in out["records"]] == ["lr note 2"]
        out = json.loads(call("list_records", {
            "workspace": tmp, "kind": "note", "limit": 1, "offset": 1}))
        assert [r["title"] for r in out["records"]] == ["lr note 1"]

        out = json.loads(call("list_records", {
            "workspace": tmp, "source": "git"}))
        assert [r["title"] for r in out["records"]] == ["abc123 init"]

        # scope=global: repo-keyed rows carry `ws`, exclude the ws commit
        out = json.loads(call("list_records", {
            "workspace": tmp, "scope": "global"}))
        titles = [r["title"] for r in out["records"]]
        assert "lr note 2" in titles and "abc123 init" not in titles
        assert all(r["ws"] == ws_key for r in out["records"])

        # scope=all: dual-written rows dedupe to the workspace copies
        out = json.loads(call("list_records", {
            "workspace": tmp, "scope": "all"}))
        assert out["total"] == 4
        assert sum(t == "lr note 2" for t in
                   [r["title"] for r in out["records"]]) == 1

        with pytest.raises(ValueError, match="scope"):
            call("list_records", {"workspace": tmp, "scope": "bogus"})
        _cleanup(ws_key)


def test_list_records_global_leniency():
    """Unindexed workspace + scope=global/all reads the shared ledger;
    scope=workspace still errors."""
    with tempfile.TemporaryDirectory() as tmp, \
            tempfile.TemporaryDirectory() as bare:
        _indexed(tmp)
        ws_key = records.repo_key(tmp)
        _put(tmp, "lr lenient probe")
        out = json.loads(call("list_records", {
            "workspace": bare, "scope": "global"}))
        assert any(r["title"] == "lr lenient probe"
                   for r in out["records"])
        out = json.loads(call("list_records", {
            "workspace": bare, "scope": "all"}))
        assert any(r["title"] == "lr lenient probe"
                   for r in out["records"])
        with pytest.raises(FileNotFoundError):
            call("list_records", {"workspace": bare})
        _cleanup(ws_key)


@pytest.mark.skipif(shutil.which("git") is None, reason="git required")
def test_record_staleness_flags_moved_head_and_dead_anchor():
    """put_record captures HEAD + resolving anchors; a record flags stale
    only when HEAD moved AND an anchor stopped resolving."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "-C", tmp, "init", "-q"], check=True)
        subprocess.run(["git", "-C", tmp, "-c", "user.email=t@t",
                        "-c", "user.name=t", "commit", "-qm", "init",
                        "--allow-empty"], check=True)
        s = _indexed(tmp)
        ws_key = records.repo_key(tmp)

        put = _put(tmp, "stale probe",
                   payload="touched mysym, see src/a.py")
        rid = put["record_id"]
        # anchors captured: symbol mysym + path src/a.py
        got = json.loads(call("get_record", {
            "workspace": tmp, "id": rid}))
        assert got["record"]["head_sha"]
        assert set(got["record"]["anchors"]) == {"mysym", "src/a.py"}
        assert got["record"]["stale"] is False

        # HEAD moves + the symbol anchor stops resolving -> stale.
        s.db.execute("DELETE FROM symbols WHERE name='mysym'")
        s.db.commit()
        subprocess.run(["git", "-C", tmp, "-c", "user.email=t@t",
                        "-c", "user.name=t", "commit", "-qm", "two",
                        "--allow-empty"], check=True)
        got = json.loads(call("get_record", {
            "workspace": tmp, "id": rid}))
        rec = got["record"]
        assert rec["stale"] is True
        assert any("head moved" in r for r in rec["stale_reasons"])
        assert any("mysym" in r for r in rec["stale_reasons"])
        _cleanup(ws_key)


def test_record_quota_evicts_oldest_of_kind():
    """Per-kind bound: session_checkpoint keeps the newest 100 rows."""
    with tempfile.TemporaryDirectory() as tmp:
        s = _indexed(tmp)
        for i in range(105):
            records.insert_ws(s, "session_checkpoint", f"ck-{i}", "p")
        n = s.db.execute(
            "SELECT COUNT(*) FROM records "
            "WHERE kind='session_checkpoint'").fetchone()[0]
        assert n == 100
        # a different kind is untouched
        records.insert_ws(s, "note", "kept", "p")
        assert s.db.execute(
            "SELECT COUNT(*) FROM records WHERE kind='note'"
        ).fetchone()[0] == 1


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
