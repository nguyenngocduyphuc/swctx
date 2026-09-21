"""Static-embedder tier (Model2Vec potion-multi-int8) — skips cleanly
when the ~83MB model is not installed."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from swctx_py.embedder import Embedder, model_installed
from swctx_py.indexer import Indexer
from swctx_py.search import Searcher
from swctx_py.store import Store


def test_all():
    if not model_installed("potion-multi-int8"):
        print("static embed SKIP (model not installed)")
        return 0

    e = Embedder("potion-multi-int8")
    v = e.embed(["def greet(name): return hi",
                 "tim kiem ma nguon", "x"])
    assert v.shape == (3, 128), v.shape
    assert np.allclose(np.linalg.norm(v, axis=1), 1.0, atol=1e-5)

    with tempfile.TemporaryDirectory() as tmp:
        ws = Path(tmp)
        (ws / "a.py").write_text(
            "def greet(name):\n    return f'hi {name}'\n")
        s = Store(str(ws))
        stats = Indexer(s).run(model_id="potion-multi-int8")
        assert stats["embedded"] > 0, stats
        assert s.meta("embedding_model") == "potion-multi-int8"
        hits = Searcher(s).search("greeting function", 5)
        assert hits and hits[0]["path"] == "a.py", hits

    print("static embed OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(test_all())
