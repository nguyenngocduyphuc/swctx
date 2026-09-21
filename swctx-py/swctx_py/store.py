"""SQLite store — per-workspace index under ~/.swctx-py/indexes/<key>/index.db."""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
from pathlib import Path

HOME = Path.home() / ".swctx-py"
INDEXES = HOME / "indexes"
MODELS = HOME / "models"
CATALOG = HOME / "workspaces.json"

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS files (
    path TEXT PRIMARY KEY, sha TEXT, mtime REAL, lang TEXT);
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY, file_id TEXT, start_line INT, end_line INT,
    symbol_name TEXT, symbol_type TEXT, content TEXT,
    path_tokens TEXT, symbol_tokens TEXT);
CREATE TABLE IF NOT EXISTS symbols (
    name TEXT, type TEXT, chunk_id INT, file_id TEXT, line INT);
CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);
CREATE TABLE IF NOT EXISTS edges (
    id INTEGER PRIMARY KEY AUTOINCREMENT, src_chunk INT, dst_chunk INT,
    dst_name TEXT, kind TEXT, line INT);
CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src_chunk);
CREATE INDEX IF NOT EXISTS idx_edges_name ON edges(dst_name);
CREATE TABLE IF NOT EXISTS embeddings (
    chunk_id INTEGER PRIMARY KEY, vec BLOB);
CREATE TABLE IF NOT EXISTS records (
    id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, title TEXT,
    body TEXT, created_at REAL);
CREATE TABLE IF NOT EXISTS usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, tool TEXT,
    session TEXT, query TEXT, arg_path TEXT, top_paths TEXT, hit_count INT);
"""


def workspace_key(path: str) -> str:
    return hashlib.sha256(os.path.abspath(path).encode()).hexdigest()[:12]


def index_path(path: str) -> Path:
    return INDEXES / workspace_key(path) / "index.db"


class Store:
    def __init__(self, workspace: str, create: bool = True):
        self.workspace = os.path.abspath(workspace)
        self.key = workspace_key(self.workspace)
        db_path = index_path(self.workspace)
        if not create and not db_path.exists():
            raise FileNotFoundError(f"no index for {self.workspace} — run: swctx-py index {self.workspace}")
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(db_path), check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        self.fts_ok = self._probe_fts()
        if self.fts_ok:
            self.db.execute(
                "CREATE VIRTUAL TABLE IF NOT EXISTS fts_chunks USING fts5("
                "content, path_tokens, symbol_tokens, folded, chunk_id UNINDEXED)")
        self._vn_corpus: bool | None = None
        self.register()

    def _probe_fts(self) -> bool:
        try:
            self.db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS _fts_probe USING fts5(x)")
            self.db.execute("DROP TABLE IF EXISTS _fts_probe")
            return True
        except sqlite3.OperationalError:
            return False

    def register(self) -> None:
        HOME.mkdir(parents=True, exist_ok=True)
        cat = {}
        if CATALOG.exists():
            try:
                cat = json.loads(CATALOG.read_text())
            except Exception:
                cat = {}
        cat[self.key] = {"path": self.workspace, "updated_at": time.time()}
        CATALOG.write_text(json.dumps(cat, indent=1))

    def meta(self, k: str, default: str | None = None) -> str | None:
        row = self.db.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
        return row[0] if row else default

    def set_meta(self, k: str, v: str) -> None:
        self.db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (k, v))
        self.db.commit()

    def log_event(self, tool: str, session: str, query: str = "",
                  arg_path: str = "", top_paths: str = "", hit_count: int = 0) -> None:
        self.db.execute(
            "INSERT INTO usage_events (ts,tool,session,query,arg_path,top_paths,hit_count)"
            " VALUES (?,?,?,?,?,?,?)",
            (time.time(), tool, session, query, arg_path, top_paths, hit_count))
        self.db.commit()

    def corpus_has_vn_filenames(self, path_tokens_of) -> bool:
        """True when ≥1 indexed path carries a VN morpheme (cached)."""
        from .lexicon import VN_MORPHEMES
        if self._vn_corpus is not None:
            return self._vn_corpus
        found = False
        for (p,) in self.db.execute("SELECT path FROM files"):
            if VN_MORPHEMES.intersection(path_tokens_of(p).split()):
                found = True
                break
        self._vn_corpus = found
        return found
