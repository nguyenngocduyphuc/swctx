"""Simulate test — edges backfill + diff impact on a tiny fixture."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from swctx_py.indexer import Indexer
from swctx_py.simulate import run
from swctx_py.store import Store


def build(tmp: str) -> Store:
    ws = Path(tmp)
    (ws / "a.py").write_text(
        "def greet(name):\n    return f'hi {name}'\n\n\ndef helper():\n"
        "    return 1\n")
    (ws / "b.py").write_text(
        "from a import greet\n\ndef main():\n    greet('x')\n")
    (ws / "test_a.py").write_text(
        "from a import greet\n\ndef test_greet():\n    assert greet('y')\n")
    s = Store(str(ws))
    Indexer(s).run(skip_embed=True)
    return s


def test_all():
    with tempfile.TemporaryDirectory() as tmp:
        s = build(tmp)

        # edges extracted
        n = s.db.execute("SELECT COUNT(*) FROM edges").fetchone()[0]
        assert n > 0

        # signature change: greet gains a param
        diff = ("--- a/a.py\n+++ b/a.py\n@@ -1,2 +1,2 @@\n"
                "-def greet(name):\n+def greet(name, lang):\n"
                "     return f'hi {name}'\n")
        r = run(s, diff)
        assert r["symbols"][0]["name"] == "greet"
        assert r["symbols"][0]["change"] == "signature"
        assert r["symbols"][0]["arity"] == "1→2"
        callers = r["symbols"][0]["callers"]
        assert len(callers) == 2, callers
        assert all(c["resolved"] for c in callers)
        risk = r["risk"]
        assert risk["broken_call_sites"] == 2
        assert risk["resolved_call_sites"] == 2
        assert risk["affected_prod_files"] == ["b.py"]
        assert risk["affected_test_files"] == ["test_a.py"]

        # removal
        diff = ("--- a/a.py\n+++ b/a.py\n@@ -5,2 +5,0 @@\n"
                "-def helper():\n-    return 1\n")
        r = run(s, diff)
        assert r["symbols"][0]["change"] == "removed"

        # body-only hunk maps to enclosing symbol
        diff = ("--- a/a.py\n+++ b/a.py\n@@ -2,1 +2,1 @@\n"
                "-    return f'hi {name}'\n+    return f'hello {name}!'\n")
        r = run(s, diff)
        assert r["body_changes"][0]["enclosing_symbol"] == "greet"
        assert len(r["body_changes"][0]["dependent_callers"]) == 2

        # test_coverage: symbol -> tests (only test_a.py, not b.py)
        from swctx_py.coverage import run as cov
        r = cov(s, symbol_name="greet")
        assert r["count"] == 1, r
        assert r["tests"][0]["path"] == "test_a.py"

        # test_coverage: path -> covers (greet in a.py, not test files)
        r = cov(s, path="test_a.py")
        assert r["count"] == 1, r
        assert r["covers"][0]["symbol"] == "greet"
        assert r["covers"][0]["path"] == "a.py"

        # trace_lookup: py frame resolves to greet's chunk; callers
        # of the crash site surface as suspects
        from swctx_py.trace import run as tr
        r = tr(s, 'Traceback (most recent call last):\n'
                 '  File "/x/site-packages/os.py", line 9, in makedirs\n'
                 '  File "/x/a.py", line 2, in greet\n')
        assert r["matched"] == 1, r
        assert r["frames"][1]["symbol"] == "greet"
        assert r["frames"][0]["matched"] is False
        assert any(sp["path"] == "b.py" for sp in r["suspects"])

        print("simulate + coverage + trace OK")
        return 0


if __name__ == "__main__":
    raise SystemExit(test_all())
