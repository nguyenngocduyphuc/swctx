"""answer — port of the W12 compose contract: strict-JSON extraction,
server-side citation validation (fake paths/ids dropped), one retry,
backend-dead fallback that still returns the deterministic pack, and the
kind=ask ledger write. The model/CLI boundary is monkeypatched — no real
CLI or subprocess calls happen in these tests."""
import json
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from swctx_py import answer as ans
from swctx_py.store import Store


def _indexed(tmp: str) -> Store:
    """Two indexed chunks (FTS + symbol rows) so retrieval builds a real
    evidence pack for query terms like 'def' or 'mysym'."""
    s = Store(tmp)
    s.db.execute(
        "INSERT INTO files(path, sha, mtime, lang) VALUES(?,?,0,?)",
        ("src/a.py", "x", "python"))
    s.db.execute(
        "INSERT INTO files(path, sha, mtime, lang) VALUES(?,?,0,?)",
        ("src/b.py", "y", "python"))
    s.db.execute(
        "INSERT INTO chunks(id, file_id, start_line, end_line,"
        " symbol_name, symbol_type, content) VALUES(1,'src/a.py',1,2,"
        " 'mysym','function','def mysym(): pass')")
    s.db.execute(
        "INSERT INTO chunks(id, file_id, start_line, end_line,"
        " symbol_name, symbol_type, content) VALUES(2,'src/b.py',1,3,"
        " 'helper','function','def helper():\n    return 1')")
    s.db.execute(
        "INSERT INTO symbols(name, type, chunk_id, file_id, line)"
        " VALUES('mysym','function',1,'src/a.py',1)")
    if s.fts_ok:
        s.db.execute(
            "INSERT INTO fts_chunks(content, path_tokens, symbol_tokens,"
            " folded, chunk_id) VALUES('def mysym(): pass','src a py',"
            " 'mysym','def mysym pass',1)")
        s.db.execute(
            "INSERT INTO fts_chunks(content, path_tokens, symbol_tokens,"
            " folded, chunk_id) VALUES('def helper(): return 1',"
            " 'src b py','helper','def helper return 1',2)")
    s.db.commit()
    return s


def _pack() -> list[ans.Evidence]:
    return [
        ans.Evidence(id="E01", chunk_id=1, path="src/a.py", start_line=1,
                     end_line=2, why="direct", symbol="mysym",
                     kind="function", content="def mysym(): pass"),
        ans.Evidence(id="E02", chunk_id=2, path="src/b.py", start_line=1,
                     end_line=3, why="direct", symbol="helper",
                     kind="function", content="def helper():\n    return 1"),
    ]


def _live_backend(monkeypatch):
    """Pretend the resolved backend probed healthy — call_model stays
    the only mockable edge."""
    monkeypatch.setattr(ans, "backend_available", lambda b: (True, "ok"))


def test_validate_citations_drops_fake_paths():
    pack = _pack()
    resolved, invalid, valid = ans.validate_citations([
        {"evidence_id": "E01", "path": "src/a.py"},      # exact — kept
        {"evidence_id": "E02", "path": "src/evil.py"},   # invented path
        {"evidence_id": "E99"},                          # outside the pack
        {"evidence_id": "e1"},                           # dup of E01 — dropped
    ], pack)
    assert [c["evidence_id"] for c in resolved] == ["E01"]
    assert resolved[0]["path"] == "src/a.py"
    assert any("E02 path/line mismatch" in i for i in invalid)
    assert any("E99 not in evidence pack" in i for i in invalid)
    assert valid is False    # rejected citations ⇒ not valid

    # Line assertions must match the pack verbatim; a wrong type or a
    # mismatched number is an invalid assertion, never silently skipped.
    resolved, invalid, valid = ans.validate_citations(
        [{"evidence_id": "E01", "start_line": 99},
         {"evidence_id": "E02", "start_line": "1"}], pack)
    assert resolved == []
    assert any("E01 path/line mismatch" in i for i in invalid)
    assert any("E02 start_line not a number" in i for i in invalid)
    assert valid is False

    # An id-only citation is valid; explicit null fields read as absent.
    resolved, invalid, valid = ans.validate_citations(
        [{"evidence_id": "E01", "path": None, "start_line": None}], pack)
    assert valid is True
    assert [c["evidence_id"] for c in resolved] == ["E01"]


def test_parse_answer_tolerates_fences_and_prose():
    fenced = '```json\n{"answer": "ok", "citations": [], "limitations": ""}\n```'
    p = ans.parse_answer(fenced)
    assert p is not None and p.answer == "ok"
    wrapped = ('Some prose first. {"answer": "real", '
               '"citations": ["E01", 2], "limitations": "none"} tail')
    p = ans.parse_answer(wrapped)
    assert p is not None
    assert [c["evidence_id"] for c in p.citations] == ["E01", "E2"]
    assert ans.parse_answer("no json at all") is None
    assert ans.parse_answer('{"answer": ""}') is None


def test_retry_once_on_malformed_then_valid(monkeypatch):
    """Attempt 1 not strict JSON → exactly one format-retry; attempt 2's
    valid reply wins and is reported."""
    with tempfile.TemporaryDirectory() as tmp:
        s = _indexed(tmp)
        _live_backend(monkeypatch)
        calls = []

        def fake_model(backend, prompt, timeout):
            calls.append(prompt)
            if len(calls) == 1:
                return "I think it does something"      # not JSON
            return json.dumps({
                "answer": "mysym returns None",
                "citations": [{"evidence_id": "E01"}],
                "limitations": ""})

        monkeypatch.setattr(ans, "call_model", fake_model)
        out = ans.run(s, "mysym", backend_spec="cli:fake")
        assert len(calls) == 2                          # exactly one retry
        assert "ONLY that JSON object" in calls[1]      # retry suffix
        assert out["answer"] == "mysym returns None"
        assert out["citation_valid"] is True
        assert out["ollama"]["attempts"] == 2
        assert out["backend"] == "cli:fake"
        assert "record_id" in out
        row = s.db.execute(
            "SELECT kind, source, status FROM records "
            "WHERE kind='ask'").fetchone()
        assert row == ("ask", "mcp", "completed")


def test_retry_once_on_invalid_citations(monkeypatch):
    """A hallucinated citation spends the same single retry; the second
    (clean) reply's validation result stands."""
    with tempfile.TemporaryDirectory() as tmp:
        s = _indexed(tmp)
        _live_backend(monkeypatch)
        calls = []

        def fake_model(backend, prompt, timeout):
            calls.append(prompt)
            if len(calls) == 1:
                return json.dumps({
                    "answer": "grounded-ish",
                    "citations": [{"evidence_id": "E01",
                                   "path": "src/invented.py"}],
                    "limitations": ""})
            return json.dumps({
                "answer": "grounded",
                "citations": [{"evidence_id": "E01"}],
                "limitations": ""})

        monkeypatch.setattr(ans, "call_model", fake_model)
        out = ans.run(s, "mysym", backend_spec="cli:fake")
        assert len(calls) == 2
        assert out["citation_valid"] is True
        assert "invalid_citations" not in out
        assert out["citations"][0]["path"] == "src/a.py"


def test_citations_still_invalid_after_retry_keeps_answer(monkeypatch):
    """Both attempts cite invented paths → the last parse still ships,
    flagged citation_valid=false with the rejection summary."""
    with tempfile.TemporaryDirectory() as tmp:
        s = _indexed(tmp)
        _live_backend(monkeypatch)
        calls = []

        def fake_model(backend, prompt, timeout):
            calls.append(prompt)
            return json.dumps({
                "answer": f"attempt {len(calls)}",
                "citations": [{"evidence_id": "E01",
                               "path": "src/nope.py"}],
                "limitations": ""})

        monkeypatch.setattr(ans, "call_model", fake_model)
        out = ans.run(s, "mysym", backend_spec="cli:fake")
        assert len(calls) == 2
        assert out["answer"] == "attempt 2"
        assert out["citation_valid"] is False
        assert out["citations"] == []
        assert any("path/line mismatch" in i
                   for i in out["invalid_citations"])
        assert "citations still invalid after 1 retry" in out["limitations"]


def test_backend_dead_returns_pack_without_throwing(monkeypatch):
    """Explicit cli backend whose binary is not on PATH: no subprocess is
    ever spawned, the pack still returns with a structured limitation."""
    with tempfile.TemporaryDirectory() as tmp:
        s = _indexed(tmp)
        monkeypatch.setattr(
            ans, "call_model",
            lambda *a, **k: pytest.fail("call_model must not run"))
        out = ans.run(s, "mysym",
                      backend_spec="cli:swctx-no-such-cli")
        assert out["answer"] is None
        assert out["citation_valid"] is False
        assert out["evidence"]                          # pack still ships
        assert "cli:swctx-no-such-cli unavailable — deterministic "\
               "evidence pack only" in out["limitations"]
        assert "not on PATH" in out["limitations"]
        assert out["ollama"]["attempts"] == 0
        assert "record_id" in out


def test_auto_finds_no_backend_reports_plainly(monkeypatch):
    """auto: no usable fleet CLI + ollama down → the limitation says the
    full probe path, never a silent route."""
    with tempfile.TemporaryDirectory() as tmp:
        s = _indexed(tmp)
        monkeypatch.setattr(ans, "auto_detect_cli", lambda: None)
        monkeypatch.setattr(ans, "ollama_available",
                            lambda m: (False, "ollama unavailable: probe"))
        out = ans.run(s, "mysym", backend_spec="auto")
        assert out["answer"] is None
        assert out["backend"] == "ollama:qwen2.5:3b"
        assert "no compose backend available — auto probed fleet CLIs "\
               "(agy, codex, claude)" in out["limitations"]
        assert out["evidence"]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
