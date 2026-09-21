"""Hybrid retrieval — FTS5 + cosine + exact-symbol + path probe + EN<->VN
lexicon legs, fused by RRF. Direct port of the swctx retrieval shape."""
from __future__ import annotations

import re
import sqlite3

import numpy as np

from .embedder import Embedder
from .fold import fold_text, path_token_string, query_terms, symbol_tokens
from .lexicon import lexicon_terms, vn_terms
from .store import Store

RRF_K = 60.0


def _fts_escape(term: str) -> str:
    return '"' + term.replace('"', ' ') + '"'


class Searcher:
    def __init__(self, store: Store):
        self.store = store
        self._embedder: Embedder | None = None
        self._vecs: np.ndarray | None = None
        self._vec_ids: np.ndarray | None = None

    # ---------- legs ----------

    def _fts_leg(self, query: str, limit: int) -> dict[int, float]:
        if not self.store.fts_ok:
            return {}
        terms = query_terms(query)
        if not terms:
            return {}
        q = " OR ".join(_fts_escape(t) for t in terms)
        try:
            rows = self.store.db.execute(
                "SELECT chunk_id, bm25(fts_chunks, 5.0, 2.0, 4.0, 1.0) s "
                "FROM fts_chunks WHERE fts_chunks MATCH ? ORDER BY s LIMIT ?",
                (q, limit)).fetchall()
        except sqlite3.OperationalError:
            return {}
        return {r[0]: -r[1] for r in rows}

    def _folded_leg(self, query: str, limit: int) -> dict[int, float]:
        """Folded-content tail-fill — rescues đ/diacritic queries FTS misses."""
        if not self.store.fts_ok:
            return {}
        terms = query_terms(query)
        if not terms:
            return {}
        q = "folded : " + " OR ".join(_fts_escape(t) for t in terms)
        try:
            rows = self.store.db.execute(
                "SELECT chunk_id, bm25(fts_chunks) s FROM fts_chunks "
                "WHERE fts_chunks MATCH ? ORDER BY s LIMIT ?",
                (q, limit)).fetchall()
        except sqlite3.OperationalError:
            return {}
        return {r[0]: -r[1] * 0.5 for r in rows}

    def _vector_leg(self, query: str, limit: int) -> dict[int, float]:
        model = self.store.meta("embedding_model", "bge-base-en-v1.5")
        if self._embedder is None:
            self._embedder = Embedder(model)
        if self._vecs is None:
            rows = self.store.db.execute(
                "SELECT chunk_id, vec FROM embeddings").fetchall()
            if not rows:
                return {}
            self._vec_ids = np.array([r[0] for r in rows])
            self._vecs = np.frombuffer(
                b"".join(r[1] for r in rows), dtype=np.float32
            ).reshape(len(rows), -1)
        try:
            qv = self._embedder.embed([query])[0]
        except Exception:
            return {}
        sims = self._vecs @ qv
        top = np.argpartition(-sims, min(limit, len(sims) - 1))[:limit]
        return {int(self._vec_ids[i]): float(sims[i]) for i in top}

    def _symbol_leg(self, query: str, limit: int) -> dict[int, float]:
        terms = set(query_terms(query))
        toks: set[str] = set()
        for t in terms:
            toks.add(t)
            toks.update(symbol_tokens(t))
        if not toks:
            return {}
        marks = ",".join("?" * len(toks))
        rows = self.store.db.execute(
            f"SELECT DISTINCT chunk_id FROM symbols WHERE lower(name) IN ({marks})"
            f" LIMIT ?", (*toks, limit)).fetchall()
        return {r[0]: 1.0 for r in rows}

    def _path_leg(self, query: str, limit: int) -> dict[int, float]:
        """Filename-intent probe — path atoms + EN->VN lexicon atoms when the
        corpus actually names files in Vietnamese."""
        atoms = query_terms(query)
        if self.store.corpus_has_vn_filenames(path_token_string):
            atoms += vn_terms(query)
        atoms += lexicon_terms(query)
        atoms = list(dict.fromkeys(a for a in atoms if len(a) >= 2))
        if not atoms:
            return {}
        # Rarity-aware per-file probe: an atom hitting many files is noise
        # (viec/cong/sources); the signal is rare atoms (biet/xong) and
        # files matching several of them. Weight = idf over file-level df,
        # best chunk per file only — mirrors the Swift planner probe.
        import math
        n_files = max(1, self.store.db.execute(
            "SELECT COUNT(*) FROM files").fetchone()[0])
        file_atoms: dict[str, set[str]] = {}
        file_best_chunk: dict[str, tuple[int, float]] = {}
        atom_idf: dict[str, float] = {}
        for atom in atoms[:24]:
            try:
                rows = self.store.db.execute(
                    "SELECT c.id, c.file_id, bm25(fts_chunks) s "
                    "FROM fts_chunks f JOIN chunks c ON c.id=f.chunk_id "
                    "WHERE fts_chunks MATCH ? ORDER BY s LIMIT 200",
                    (f"path_tokens : {_fts_escape(atom)}",)).fetchall()
            except sqlite3.OperationalError:
                continue
            if not rows:
                continue
            df = len({r[1] for r in rows})
            if df > max(8, n_files * 0.2):
                continue  # atom too common — pure noise
            atom_idf[atom] = math.log(1.0 + n_files / df)
            for cid, fid, s in rows:
                file_atoms.setdefault(fid, set()).add(atom)  # once per file
                cur = file_best_chunk.get(fid)
                if cur is None or -s > cur[1]:
                    file_best_chunk[fid] = (cid, -s)
        file_score = {fid: sum(atom_idf[a] for a in ats)
                      for fid, ats in file_atoms.items()}
        return {file_best_chunk[fid][0]: sc
                for fid, sc in sorted(
                    file_score.items(), key=lambda kv: -kv[1])[:limit]}

    # ---------- fuse ----------

    def search(self, query: str, limit: int = 10, session: str = "") -> list[dict]:
        pool = limit * 8
        path_leg = self._path_leg(query, pool)
        legs = [
            self._fts_leg(query, pool),
            self._vector_leg(query, pool),
            self._symbol_leg(query, pool),
            self._folded_leg(query, pool),
        ]
        score: dict[int, float] = {}
        for leg in legs:
            for rank, cid in enumerate(
                    sorted(leg, key=leg.get, reverse=True)):
                score[cid] = score.get(cid, 0.0) + 1.0 / (RRF_K + rank)
        # Filename probe is a direct bonus, not an equal RRF leg — files
        # matching several RARE path atoms (biet+xong) must outrank docs
        # that merely share common query words. Mirrors Answer.pathProbe.
        if path_leg:
            peak = max(path_leg.values())
            for cid, sc in path_leg.items():
                score[cid] = score.get(cid, 0.0) + 0.06 * (sc / peak)
        top = sorted(score, key=score.get, reverse=True)[:limit]
        if not top:
            self.store.log_event("search", session, query, hit_count=0)
            return []
        marks = ",".join("?" * len(top))
        rows = self.store.db.execute(
            f"SELECT id,file_id,start_line,end_line,symbol_name,content "
            f"FROM chunks WHERE id IN ({marks})", top).fetchall()
        by_id = {r[0]: r for r in rows}
        out = []
        for cid in top:
            r = by_id.get(cid)
            if r:
                out.append({"chunk_id": r[0], "path": r[1],
                            "lines": [r[2], r[3]], "symbol": r[4],
                            "score": round(score[cid], 4),
                            "content": r[5]})
        self.store.log_event(
            "search", session, query,
            top_paths=";".join(dict.fromkeys(o["path"] for o in out[:5])),
            hit_count=len(out))
        return out

    def find_definitions(self, name: str, limit: int = 10) -> list[dict]:
        rows = self.store.db.execute(
            "SELECT s.chunk_id,s.file_id,s.line,s.type,c.content FROM symbols s "
            "JOIN chunks c ON c.id=s.chunk_id WHERE lower(s.name)=? LIMIT ?",
            (name.lower(), limit)).fetchall()
        return [{"chunk_id": r[0], "path": r[1], "lines": [r[2], r[2]],
                 "symbol": name, "type": r[3], "content": r[4]} for r in rows]

    def find_usages(self, name: str, limit: int = 10) -> list[dict]:
        rows = self.store.db.execute(
            "SELECT id,file_id,start_line,end_line,content FROM chunks "
            "WHERE content LIKE ? LIMIT ?",
            (f"%{name}%", limit * 4)).fetchall()
        pat = re.compile(rf"\b{re.escape(name)}\b")
        out = []
        for r in rows:
            if pat.search(r[4]):
                out.append({"chunk_id": r[0], "path": r[1],
                            "lines": [r[2], r[3]], "content": r[4]})
            if len(out) >= limit:
                break
        return out
