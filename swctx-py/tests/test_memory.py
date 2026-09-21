"""Session memory — checkpoint -> prime resume + global search_records."""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from swctx_py import records
from swctx_py.mcp_server import call


def _build(tmp: str):
    from test_smoke import build
    return build(tmp)


def test_checkpoint_resume():
    with tempfile.TemporaryDirectory() as tmp:
        _build(tmp)
        out = json.loads(call("checkpoint", {
            "workspace": tmp,
            "summary": "session memory shipped",
            "next": "verify swift parity"}))
        assert out["kind"] == "session_checkpoint"
        assert out["record_id"]
        # prime surfaces the checkpoint's next-step as resume:
        card = call("prime", {"workspace": tmp})
        assert "session memory shipped" in card
        assert "next: verify swift parity" in card
        # search_records scope=global finds it from the shared ledger
        got = json.loads(call("search_records", {
            "workspace": tmp, "query": "session memory",
            "scope": "global"}))
        assert any("session memory shipped" in r["title"]
                   for r in got["records"])
        # cleanup test rows from the real shared ledger
        db = records._connect()
        db.execute("DELETE FROM records WHERE title = ?",
                   ("session memory shipped",))
        db.commit()
        db.close()


def test_put_record_allowlist():
    with tempfile.TemporaryDirectory() as tmp:
        _build(tmp)
        bad = json.loads(call("put_record", {
            "workspace": tmp, "kind": "bogus", "title": "t",
            "payload": "p"}))
        assert "error" in bad
        for kind in ("note", "finding", "decision", "todo"):
            out = json.loads(call("put_record", {
                "workspace": tmp, "kind": kind, "title": f"t-{kind}",
                "payload": "p"}))
            assert "error" not in out, kind
        db = records._connect()
        db.execute("DELETE FROM records WHERE title LIKE 't-%'")
        db.commit()
        db.close()


if __name__ == "__main__":
    test_checkpoint_resume()
    test_put_record_allowlist()
    print("test_memory OK")
