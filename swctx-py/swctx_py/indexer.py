"""Indexer — incremental, sha256 change detection, lazy embedder."""
from __future__ import annotations

import hashlib
import os
import time
from pathlib import Path

import numpy as np

from . import chunker, discover, edges
from .embedder import Embedder, MODELS_KNOWN, model_installed
from .fold import fold_text, path_token_string, symbol_token_string
from .store import Store


def _sha(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


class Indexer:
    def __init__(self, store: Store):
        self.store = store
        self._embedder: Embedder | None = None

    def _emb(self, model_id: str) -> Embedder:
        if self._embedder is None or self._embedder.model_id != model_id:
            self._embedder = Embedder(model_id)
        return self._embedder

    def run(self, force: bool = False, skip_embed: bool = False,
            model_id: str | None = None) -> dict:
        s = self.store
        model_id = model_id or s.meta("embedding_model") or "bge-base-en-v1.5"
        if s.meta("embedding_model") is None:
            s.set_meta("embedding_model", model_id)
            s.set_meta("embedding_dim", str(MODELS_KNOWN[model_id]["dim"]))
        t0 = time.time()
        found = discover.discover(s.workspace)
        known = {r[0]: r[1] for r in s.db.execute("SELECT path, sha FROM files")}
        changed = removed = 0
        seen: set[str] = set()

        for rel, _mtime in found:
            seen.add(rel)
            fp = Path(s.workspace) / rel
            try:
                sha = _sha(fp)
            except OSError:
                continue
            if not force and known.get(rel) == sha:
                continue
            self._index_file(rel, fp, sha)
            changed += 1

        for rel in set(known) - seen:
            self._delete_file(rel)
            removed += 1

        self._backfill_edges()
        if changed or removed or s.meta("edges_resolved") != "1":
            self._resolve_edges()
            s.set_meta("edges_resolved", "1")

        embedded = 0
        if not skip_embed and model_installed(model_id):
            embedded = self.embed_all(model_id)
        stats = {"changed": changed, "removed": removed,
                 "embedded": embedded, "ms": int((time.time() - t0) * 1000)}
        s.set_meta("last_index", str(time.time()))
        s.set_meta("file_count", str(len(found)))
        return stats

    def _index_file(self, rel: str, fp: Path, sha: str) -> None:
        s = self.store
        try:
            text = fp.read_text(errors="replace")
        except OSError:
            return
        self._delete_file(rel, commit=False)
        lang = discover.lang_of(rel)
        s.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?)",
                     (rel, sha, fp.stat().st_mtime, lang))
        ptoks = path_token_string(rel)
        for ch in chunker.chunk(rel, lang, text):
            cur = s.db.execute(
                "INSERT INTO chunks (file_id,start_line,end_line,symbol_name,"
                "symbol_type,content,path_tokens,symbol_tokens)"
                " VALUES (?,?,?,?,?,?,?,?)",
                (rel, ch["start"], ch["end"], ch["symbol"], ch["type"],
                 ch["content"], ptoks,
                 symbol_token_string([ch["symbol"]] if ch["symbol"] else [])))
            cid = cur.lastrowid
            if s.fts_ok:
                s.db.execute(
                    "INSERT INTO fts_chunks (content,path_tokens,symbol_tokens,"
                    "folded,chunk_id) VALUES (?,?,?,?,?)",
                    (ch["content"], ptoks,
                     symbol_token_string([ch["symbol"]] if ch["symbol"] else []),
                     fold_text(ch["content"]), cid))
            if ch["symbol"]:
                s.db.execute(
                    "INSERT INTO symbols VALUES (?,?,?,?,?)",
                    (ch["symbol"], ch["type"], cid, rel, ch["start"]))
            s.db.executemany(
                "INSERT INTO edges(src_chunk,dst_name,kind,line) "
                "VALUES (?,?,?,?)",
                [(cid, n, k, ln)
                 for n, k, ln in edges.extract(ch["content"], lang,
                                               ch["start"])])
        s.db.commit()

    def _delete_file(self, rel: str, commit: bool = True) -> None:
        s = self.store
        ids = [r[0] for r in s.db.execute(
            "SELECT id FROM chunks WHERE file_id=?", (rel,))]
        if ids:
            q = ",".join("?" * len(ids))
            s.db.execute(f"DELETE FROM embeddings WHERE chunk_id IN ({q})", ids)
            s.db.execute(f"DELETE FROM symbols WHERE chunk_id IN ({q})", ids)
            s.db.execute(f"DELETE FROM edges WHERE src_chunk IN ({q})", ids)
            if s.fts_ok:
                s.db.execute(f"DELETE FROM fts_chunks WHERE chunk_id IN ({q})", ids)
            s.db.execute(f"DELETE FROM chunks WHERE id IN ({q})", ids)
        s.db.execute("DELETE FROM files WHERE path=?", (rel,))
        if commit:
            s.db.commit()

    def _backfill_edges(self) -> None:
        """One-time edge pass for indexes built before the edges table —
        extracts from stored chunk content, no file re-read needed."""
        s = self.store
        if s.meta("edges_built") == "1":
            return
        rows = s.db.execute(
            "SELECT c.id, c.content, c.start_line, f.lang "
            "FROM chunks c JOIN files f ON f.path = c.file_id").fetchall()
        s.db.execute("DELETE FROM edges")
        for cid, content, start, lang in rows:
            s.db.executemany(
                "INSERT INTO edges(src_chunk,dst_name,kind,line) "
                "VALUES (?,?,?,?)",
                [(cid, n, k, ln)
                 for n, k, ln in edges.extract(content or "", lang, start)])
        s.set_meta("edges_built", "1")
        s.db.commit()

    def _resolve_edges(self) -> None:
        """Fill dst_chunk by symbol name — prefer a same-file definition."""
        s = self.store
        s.db.execute("""
            UPDATE edges SET dst_chunk = (
                SELECT s.chunk_id FROM symbols s
                JOIN chunks c ON c.id = edges.src_chunk
                WHERE s.name = edges.dst_name
                ORDER BY (s.file_id = c.file_id) DESC, s.chunk_id
                LIMIT 1)
            WHERE dst_chunk IS NULL
              AND EXISTS (SELECT 1 FROM symbols s
                          WHERE s.name = edges.dst_name)
            """)
        s.db.commit()

    def embed_all(self, model_id: str) -> int:
        """Embed all pending chunks, then release the model (RAM hygiene)."""
        s = self.store
        rows = s.db.execute(
            "SELECT c.id, c.content FROM chunks c LEFT JOIN embeddings e "
            "ON e.chunk_id=c.id WHERE e.chunk_id IS NULL").fetchall()
        if not rows:
            return 0
        emb = self._emb(model_id)
        done = 0
        try:
            for i in range(0, len(rows), 64):
                batch = rows[i:i + 64]
                vecs = emb.embed([r[1] for r in batch])
                s.db.executemany(
                    "INSERT OR REPLACE INTO embeddings VALUES (?,?)",
                    [(r[0], v.astype(np.float32).tobytes())
                     for r, v in zip(batch, vecs)])
                s.db.commit()
                done += len(batch)
        finally:
            self._embedder = None  # release model — watchers stay light
        return done
