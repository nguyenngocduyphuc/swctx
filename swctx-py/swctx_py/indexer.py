"""Indexer — incremental, sha256 change detection, lazy embedder."""
from __future__ import annotations

import hashlib
import time
from pathlib import Path

import numpy as np

from . import chunker, discover, edges
from .embedder import MODELS_KNOWN, Embedder, model_installed
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
        # Explicit --model wins over the stored choice; a dim change makes
        # existing vectors stale, so wipe them when the model differs.
        if s.meta("embedding_model") != model_id:
            if s.meta("embedding_model") is not None:
                s.db.execute("DELETE FROM embeddings")
                s.db.commit()
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
        routes_added = self._backfill_routes()
        if changed or removed or routes_added \
                or s.meta("edges_resolved") != "1":
            self._resolve_edges()
            s.set_meta("edges_resolved", "1")

        stats_commits = self._ingest_git()

        embedded = 0
        if not skip_embed and model_installed(model_id):
            embedded = self.embed_all(model_id)
        stats = {"changed": changed, "removed": removed,
                 "embedded": embedded, "commits": stats_commits,
                 "ms": int((time.time() - t0) * 1000)}
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
            # Route defs become `route` symbols so api_call edges from
            # fetch('/api/x') resolve through the generic name join.
            s.db.executemany(
                "INSERT INTO symbols VALUES (?,?,?,?,?)",
                [(p, "route", cid, rel, ln)
                 for p, ln in edges.route_defs(ch["content"], lang,
                                               ch["start"])])
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
            # api_call rows are owned by _backfill_routes (paired with the
            # `route` symbols it inserts) — skip them here so the two
            # passes can't double-insert.
            s.db.executemany(
                "INSERT INTO edges(src_chunk,dst_name,kind,line) "
                "VALUES (?,?,?,?)",
                [(cid, n, k, ln)
                 for n, k, ln in edges.extract(content or "", lang, start)
                 if k != "api_call"])
        s.set_meta("edges_built", "1")
        s.db.commit()

    def _backfill_routes(self) -> bool:
        """One-time route pass for indexes predating route extraction:
        inserts `route` symbols + `api_call` edges from stored chunks —
        no file re-read. Returns True when rows were added so the caller
        forces a resolution pass (edges_resolved may already be set)."""
        s = self.store
        if s.meta("routes_built") == "1":
            return False
        # Idempotent: prior partial output (interrupted run) is rebuilt.
        s.db.execute("DELETE FROM edges WHERE kind='api_call'")
        s.db.execute("DELETE FROM symbols WHERE type='route'")
        rows = s.db.execute(
            "SELECT c.id, c.content, c.start_line, c.file_id, f.lang "
            "FROM chunks c JOIN files f ON f.path = c.file_id").fetchall()
        for cid, content, start, file_id, lang in rows:
            s.db.executemany(
                "INSERT INTO symbols VALUES (?,?,?,?,?)",
                [(p, "route", cid, file_id, ln)
                 for p, ln in edges.route_defs(content or "", lang, start)])
            s.db.executemany(
                "INSERT INTO edges(src_chunk,dst_name,kind,line) "
                "VALUES (?,?,'api_call',?)",
                [(cid, n, ln)
                 for n, k, ln in edges.extract(content or "", lang, start)
                 if k == "api_call"])
        s.set_meta("routes_built", "1")
        s.db.commit()
        return bool(rows)

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

    def _ingest_git(self, limit: int = 300) -> int:
        """git log -> commit records (temporal queries via search_records).

        Incremental via meta git_history_head; rebase falls back to a
        bounded walk with per-sha dedup. Non-git workspaces return 0.
        """
        import json as _json
        import subprocess
        s = self.store

        def git(*a: str) -> str | None:
            try:
                r = subprocess.run(["git", "-C", s.workspace, *a],
                                   capture_output=True, text=True,
                                   timeout=60)
                return r.stdout if r.returncode == 0 else None
            except (OSError, subprocess.TimeoutExpired):
                return None

        if git("rev-parse", "--git-dir") is None:
            return 0
        # nested workspace inside a bigger repo: scope log to this subtree
        # and strip the repo-relative prefix so paths stay workspace-relative
        prefix = (git("rev-parse", "--show-prefix") or "").strip()

        def gitlog(spec: list[str]) -> str | None:
            return git("log", *spec,
                       "--format=\x1e%H\x1f%s\x1f%an\x1f%aI",
                       "--name-only", "--", ".")

        head = s.meta("git_history_head")
        spec = [f"{head}..HEAD"] if head else ["-n", str(limit)]
        out = gitlog(spec)
        if out is None and head:
            out = gitlog(["-n", str(limit)])
        if not out:
            return 0

        known = {r[0] for r in s.db.execute(
            "SELECT substr(title,1,12) FROM records WHERE kind='commit'")}
        inserted = 0
        newest: str | None = None
        for block in out.split("\x1e"):
            lines = [ln for ln in block.splitlines() if ln.strip()]
            if not lines:
                continue
            f = lines[0].split("\x1f")
            if len(f) < 4:
                continue
            sha = f[0]
            if newest is None:
                newest = sha
            if sha[:12] in known:
                continue
            files = [ln[len(prefix):] for ln in lines[1:]
                     if ln.startswith(prefix)][:50]
            body = _json.dumps({"sha": sha, "author": f[2], "date": f[3],
                                "files": files})
            from . import records as _rec
            _rec.insert_ws(s, "commit", f"{sha[:12]} {f[1]}", body,
                           source="git")
            inserted += 1
        if newest:
            s.set_meta("git_history_head", newest)
        s.db.commit()
        return inserted

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
