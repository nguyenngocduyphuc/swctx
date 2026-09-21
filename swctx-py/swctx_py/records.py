"""Shared records ledger — ~/.swctx-py/records.db across all workspaces.

Mirror of the Swift engine's GlobalRecords: agent-authored records
(notes, findings, decisions, session checkpoints) are visible from every
checkout of every indexed repo, so a fresh session inherits context
instead of redoing it. Workspace index DBs also keep their own copy —
the global ledger is the cross-repo layer.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import time
from pathlib import Path

from .store import HOME

_KINDS = {
    "note", "finding", "decision", "todo", "context_pack", "ask",
    "engine_eval", "session_checkpoint",
}


def _connect() -> sqlite3.Connection | None:
    try:
        HOME.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(str(HOME / "records.db"), timeout=10)
        db.execute(
            "CREATE TABLE IF NOT EXISTS records("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, ws TEXT NOT NULL,"
            "kind TEXT NOT NULL, source TEXT NOT NULL,"
            "status TEXT NOT NULL DEFAULT 'completed',"
            "title TEXT NOT NULL, payload TEXT NOT NULL,"
            "created_at REAL NOT NULL, head_sha TEXT)"
        )
        db.execute(
            "CREATE INDEX IF NOT EXISTS idx_grecords_ws ON records(ws)")
        return db
    except sqlite3.Error:
        return None


def repo_key(workspace: str) -> str:
    """Repo-identity key: git common-dir hash — worktrees share it."""
    try:
        r = subprocess.run(
            ["git", "-C", workspace, "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            import hashlib
            return hashlib.sha256(
                os.path.realpath(r.stdout.strip()).encode()).hexdigest()[:12]
    except (OSError, subprocess.TimeoutExpired):
        pass
    from .store import workspace_key
    return workspace_key(workspace)


def insert(ws: str, kind: str, title: str, payload: str,
           head_sha: str = "", source: str = "mcp") -> int | None:
    """Insert into the shared ledger. Returns row id or None (degraded)."""
    if kind not in _KINDS:
        raise ValueError(f"unknown record kind '{kind}'")
    db = _connect()
    if db is None:
        return None
    try:
        cur = db.execute(
            "INSERT INTO records(ws,kind,source,title,payload,created_at,"
            "head_sha) VALUES(?,?,?,?,?,?,?)",
            (ws, kind, source, title, payload, time.time(), head_sha or None))
        db.commit()
        return cur.lastrowid
    except sqlite3.Error:
        return None
    finally:
        db.close()


def recent(kinds: tuple[str, ...], limit: int = 3) -> list[dict]:
    db = _connect()
    if db is None:
        return []
    try:
        q = ",".join("?" * len(kinds))
        rows = db.execute(
            f"SELECT kind,title,payload FROM records WHERE kind IN ({q})"
            " ORDER BY id DESC LIMIT ?",
            (*kinds, limit)).fetchall()
        return [{"kind": k, "title": t, "payload": p} for k, t, p in rows]
    except sqlite3.Error:
        return []
    finally:
        db.close()


def count(kinds: tuple[str, ...]) -> int:
    db = _connect()
    if db is None:
        return 0
    try:
        q = ",".join("?" * len(kinds))
        return db.execute(
            f"SELECT COUNT(*) FROM records WHERE kind IN ({q})",
            kinds).fetchone()[0]
    except sqlite3.Error:
        return 0
    finally:
        db.close()


def search(query: str, limit: int = 20) -> list[dict]:
    db = _connect()
    if db is None:
        return []
    try:
        like = f"%{query}%"
        rows = db.execute(
            "SELECT ws,kind,title,payload,created_at FROM records "
            "WHERE title LIKE ? OR payload LIKE ? "
            "ORDER BY id DESC LIMIT ?", (like, like, limit)).fetchall()
        return [{"ws": w, "kind": k, "title": t, "payload": p, "ts": ts}
                for w, k, t, p, ts in rows]
    except sqlite3.Error:
        return []
    finally:
        db.close()


def git(workspace: str, *args: str) -> str:
    """Best-effort git probe — '' when not a repo or git missing."""
    try:
        r = subprocess.run(["git", "-C", workspace, *args],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def checkpoint_payload(workspace: str, summary: str, next_step: str,
                       files: list[str] | None = None) -> dict:
    """Auto-captured session context: HEAD, branch, dirty files."""
    dirty = git(workspace, "status", "--porcelain")
    touched = [ln[3:].strip() for ln in dirty.splitlines() if len(ln) > 3]
    return {
        "summary": summary,
        "next": next_step,
        "branch": git(workspace, "branch", "--show-current"),
        "dirty_files": (files or touched)[:50],
        "dirty_count": len(touched),
    }
