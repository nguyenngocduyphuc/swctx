"""Smoke test — index a tiny fixture workspace, assert retrieval paths."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from swctx_py.indexer import Indexer
from swctx_py.search import Searcher
from swctx_py.store import Store


def build(tmp: str):
    ws = Path(tmp)
    (ws / "src").mkdir()
    (ws / "src" / "BietXong.py").write_text(
        "def detect_agent_done():\n    return True\n")
    (ws / "src" / "BaoCaoNgay.py").write_text(
        "class DailyReport:\n    pass\n")
    (ws / "src" / "hello.py").write_text(
        "def hello_world():\n    print('hi')\n")
    s = Store(str(ws))
    stats = Indexer(s).run(skip_embed=True)
    assert stats["changed"] == 3
    return s


def test_all():
    with tempfile.TemporaryDirectory() as tmp:
        s = build(tmp)
        sr = Searcher(s)

        # FTS leg
        hits = sr.search("hello_world function")
        assert any("hello.py" in h["path"] for h in hits)

        # EN -> VN filename atoms (corpus has VN morphemes: biet, xong, bao, cao, ngay)
        hits = sr.search("detecting when work is finished")
        paths = [h["path"] for h in hits]
        assert any("BietXong" in p for p in paths), paths

        hits = sr.search("daily report")
        assert any("BaoCaoNgay" in h["path"] for h in hits), [h["path"] for h in hits]

        # definitions
        defs = sr.find_definitions("hello_world")
        assert defs and "hello.py" in defs[0]["path"]

        print("smoke OK")
        return 0


if __name__ == "__main__":
    raise SystemExit(test_all())
