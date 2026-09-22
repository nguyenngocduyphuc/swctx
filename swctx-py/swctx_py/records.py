"""Shared records ledger — ~/.swctx-py/records.db across all workspaces.

Mirror of the Swift engine's GlobalRecords: agent-authored records
(notes, findings, decisions, session checkpoints) are visible from every
checkout of every indexed repo, so a fresh session inherits context
instead of redoing it. Workspace index DBs also keep their own copy —
the global ledger is the cross-repo layer.

This module also hosts the record read/write surface ported from
SwctxCore/Tools.swift: per-kind quotas, staleness evidence (head_sha +
anchors -> stale/stale_reasons), record_dict shaping, and the
get_record / list_records handlers.
"""
# ruff: noqa: S608 — dynamic SQL interpolates only ?-placeholder counts
# (IN lists) and fixed column/fragment names; every value is a bound
# parameter.
from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import time

from .store import HOME

_KINDS = {
    "note", "finding", "decision", "todo", "context_pack", "ask",
    "engine_eval", "session_checkpoint",
}

# Per-kind ledger bounds — eviction removes the oldest rows OF THAT KIND
# only (port of Store.recordKindQuota / recordDefaultQuota).
_QUOTA = {
    "context_pack": 500, "ask": 300, "note": 200, "finding": 200,
    "decision": 200, "todo": 200, "commit": 500,
}
_DEFAULT_QUOTA = 100

# Columns read by get_record/list_records. Missing columns (unmigrated
# ledgers) fall back to literals so the dict shape stays constant.
_WANTED = ("kind", "source", "status", "title", "payload", "created_at",
           "head_sha", "anchors")

_PATH_RX = re.compile(r"[A-Za-z0-9_.@\-]+(?:/[A-Za-z0-9_.@\-]+)+")
_IDENT_RX = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")


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
            "created_at REAL NOT NULL, head_sha TEXT,"
            "anchors TEXT)"
        )
        # In-place upgrade for ledgers created before the anchors column
        # existed (same block as the Swift GlobalRecords.openPool).
        cols = {r[1] for r in db.execute("PRAGMA table_info(records)")}
        for col in ("head_sha", "anchors"):
            if col not in cols:
                db.execute(f"ALTER TABLE records ADD COLUMN {col} TEXT")
        db.execute(
            "CREATE INDEX IF NOT EXISTS idx_grecords_ws ON records(ws)")
        db.commit()
        return db
    except sqlite3.Error:
        return None


def repo_key(workspace: str) -> str:
    """Repo-identity key for `ws`: the MAIN CHECKOUT's workspace key.
    In a linked worktree `git rev-parse --git-common-dir` resolves back to
    the main checkout's .git, so all worktrees of one repo share the key.
    Bare/non-standard layouts and non-git dirs keep the workspace's own
    key. Port of GlobalRecords.repoKey + mainCheckout."""
    from .store import workspace_key
    root = os.path.realpath(workspace)
    try:
        r = subprocess.run(
            ["git", "-C", workspace, "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=5)
        out = r.stdout.strip()
        if r.returncode == 0 and out:
            common = out if os.path.isabs(out) else os.path.join(root, out)
            common = os.path.realpath(common)
            if os.path.basename(common) == ".git":
                return workspace_key(os.path.dirname(common))
    except (OSError, subprocess.TimeoutExpired):
        pass
    return workspace_key(root)


def quota_for(kind: str) -> int:
    return _QUOTA.get(kind, _DEFAULT_QUOTA)


def encode_anchors(anchors: list[str] | None) -> str | None:
    """JSON array of anchors; None when empty so anchor-free records stay
    NULL (nothing verifiable -> never stale). Port of Store.encodeAnchors."""
    return json.dumps(anchors, ensure_ascii=False) if anchors else None


def decode_anchors(raw) -> list[str]:
    """Missing/malformed JSON decodes empty. Port of Store.decodeAnchors."""
    if not raw:
        return []
    try:
        arr = json.loads(raw)
    except (TypeError, ValueError):
        return []
    return arr if isinstance(arr, list) else []


def insert(ws: str, kind: str, title: str, payload: str,
           head_sha: str = "", source: str = "mcp",
           status: str = "completed",
           anchors: list[str] | None = None) -> int | None:
    """Insert into the shared ledger + per-(ws, kind) quota eviction.
    Returns row id or None (degraded)."""
    if kind not in _KINDS:
        raise ValueError(f"unknown record kind '{kind}'")
    db = _connect()
    if db is None:
        return None
    try:
        cur = db.execute(
            "INSERT INTO records(ws,kind,source,status,title,payload,"
            "created_at,head_sha,anchors) VALUES(?,?,?,?,?,?,?,?,?)",
            (ws, kind, source, status, title, payload, time.time(),
             head_sha or None, encode_anchors(anchors)))
        rid = cur.lastrowid
        q = quota_for(kind)
        db.execute(
            "DELETE FROM records WHERE ws=? AND kind=? AND id NOT IN ("
            "SELECT id FROM records WHERE ws=? AND kind=? "
            "ORDER BY id DESC LIMIT ?)", (ws, kind, ws, kind, q))
        db.commit()
        return rid
    except sqlite3.Error:
        return None
    finally:
        db.close()


def insert_ws(store, kind: str, title: str, payload_json: str, *,
              source: str = "mcp", status: str = "completed",
              head_sha: str | None = None,
              anchors: list[str] | None = None) -> int:
    """Insert one record into the workspace ledger + per-kind eviction.
    Port of Store.insertRecord."""
    cur = store.db.execute(
        "INSERT INTO records(kind,source,status,title,payload,created_at,"
        "head_sha,anchors) VALUES(?,?,?,?,?,?,?,?)",
        (kind, source, status, title, payload_json, time.time(),
         head_sha or None, encode_anchors(anchors)))
    rid = cur.lastrowid
    q = quota_for(kind)
    store.db.execute(
        "DELETE FROM records WHERE kind=? AND id NOT IN ("
        "SELECT id FROM records WHERE kind=? ORDER BY id DESC LIMIT ?)",
        (kind, kind, q))
    store.db.commit()
    return rid


def record_anchors(store, text: str) -> list[str]:
    """put_record anchor capture (port of SwctxTools.recordAnchors).
    Symbol anchors: identifier tokens (>=3 chars) that resolve in the
    symbols table; path anchors: '/'-bearing tokens with a known
    extension that resolve in the files table. Unresolvable mentions are
    dropped. Order-preserving, cap 10."""
    from .discover import language_id
    root_prefix = store.workspace + "/"
    masked = list(text)  # path spans blanked so identifiers inside skip
    path_cands: list[str] = []
    for m in _PATH_RX.finditer(text):
        for i in range(m.start(), m.end()):
            masked[i] = " "
        p = m.group(0)
        while p.startswith("./"):
            p = p[2:]
        if p.startswith(root_prefix):
            p = p[len(root_prefix):]
        p = p.rstrip("./")
        if not p or p.startswith("/") or p.startswith(".."):
            continue
        if language_id(p) is None:
            continue
        path_cands.append(p)
    path_uniq = list(dict.fromkeys(path_cands))[:100]
    sym_uniq = list(dict.fromkeys(_IDENT_RX.findall("".join(masked))))[:300]
    try:
        live_syms: set[str] = set()
        live_paths: set[str] = set()
        if sym_uniq:
            q = ",".join("?" * len(sym_uniq))
            live_syms = {r[0] for r in store.db.execute(
                f"SELECT name FROM symbols WHERE name IN ({q})",
                sym_uniq)}
        if path_uniq:
            q = ",".join("?" * len(path_uniq))
            live_paths = {r[0] for r in store.db.execute(
                f"SELECT path FROM files WHERE path IN ({q})",
                path_uniq)}
    except sqlite3.Error:
        return []
    out: list[str] = []
    for s in sym_uniq:
        if s in live_syms and len(out) < 10:
            out.append(s)
    for p in path_uniq:
        if p in live_paths and len(out) < 10:
            out.append(p)
    return out


def stale_check(store, rows: list[dict]) -> list[tuple[bool, list[str]]]:
    """Batch staleness verdicts (port of Store.staleCheck). A record flags
    only when the workspace git HEAD moved since capture AND >=1 anchor
    stopped resolving in the current index. Head alone never flags;
    anchor-free rows have nothing to verify against."""
    fresh: tuple[bool, list[str]] = (False, [])
    if not any(r.get("head_sha") and r.get("anchors") for r in rows):
        return [fresh] * len(rows)
    head = git(store.workspace, "rev-parse", "HEAD")
    if not head:
        return [fresh] * len(rows)
    moved = {i for i, r in enumerate(rows)
             if r.get("head_sha") and r["head_sha"] != head
             and r.get("anchors")}
    if not moved:
        return [fresh] * len(rows)
    sym_need: set[str] = set()
    path_need: set[str] = set()
    for i in moved:
        for a in rows[i]["anchors"]:
            (path_need if "/" in a else sym_need).add(a)
    # A failed lookup must not flag — unresolved-on-error reads as
    # "no evidence", not "everything broke".
    try:
        live_syms: set[str] = set()
        live_paths: set[str] = set()
        if sym_need:
            q = ",".join("?" * len(sym_need))
            live_syms = {r[0] for r in store.db.execute(
                f"SELECT name FROM symbols WHERE name IN ({q})",
                tuple(sym_need))}
        if path_need:
            q = ",".join("?" * len(path_need))
            live_paths = {r[0] for r in store.db.execute(
                f"SELECT path FROM files WHERE path IN ({q})",
                tuple(path_need))}
    except sqlite3.Error:
        return [fresh] * len(rows)
    out: list[tuple[bool, list[str]]] = []
    for i, r in enumerate(rows):
        if i not in moved:
            out.append(fresh)
            continue
        missing = [a for a in r["anchors"]
                   if a not in (live_paths if "/" in a else live_syms)]
        if not missing:
            out.append(fresh)
            continue
        old = r.get("head_sha") or ""
        out.append((True,
                    [f"head moved {old[:7]}→{head[:7]}"]
                    + [f"anchor '{a}' no longer resolves"
                       for a in missing]))
    return out


def with_staleness(recs: list[dict], store) -> list[dict]:
    """Attach `stale` + `stale_reasons` to each record dict in a response
    page (port of SwctxTools.withStaleness)."""
    if store is None or not recs:
        return recs
    checks = stale_check(store, [
        {"head_sha": r.get("head_sha"), "anchors": r.get("anchors") or []}
        for r in recs])
    return [{**r, "stale": c[0], "stale_reasons": c[1]}
            for r, c in zip(recs, checks, strict=True)]


def _rows(db: sqlite3.Connection, sql: str, params=()) -> list[dict]:
    cur = db.execute(sql, params)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r, strict=True)) for r in cur.fetchall()]


def _select_cols(db: sqlite3.Connection, want_ws: bool = False) -> str:
    """Column list matching the Swift recordDict SELECT, with literal
    fallbacks for ledgers that predate a column (constant shape)."""
    cols = {r[1] for r in db.execute("PRAGMA table_info(records)")}
    parts = ["id"]
    if want_ws:
        parts.append("ws" if "ws" in cols else "NULL AS ws")
    for c in _WANTED:
        if c in cols:
            parts.append(c)
        elif c == "payload" and "body" in cols:
            parts.append("body AS payload")
        elif c in ("head_sha", "anchors"):
            parts.append(f"NULL AS {c}")
        else:
            parts.append(f"'' AS {c}")
    return ", ".join(parts)


def record_dict(row: dict, include_payload: bool = True) -> dict:
    """Port of SwctxTools.recordDict — identical key set/omission rules."""
    d: dict = {
        "id": row.get("id") if row.get("id") is not None else -1,
        "kind": row.get("kind") or "",
        "source": row.get("source") or "",
        "status": row.get("status") or "",
        "title": row.get("title") or "",
        "created_at": row.get("created_at") or 0,
    }
    if "ws" in row and row["ws"] is not None:
        d["ws"] = row["ws"]
    # Staleness evidence is emitted only when present so anchor-free
    # records read exactly as before.
    h = row.get("head_sha")
    if "head_sha" in row and h:
        d["head_sha"] = h
    if "anchors" in row:
        anchors = decode_anchors(row.get("anchors"))
        if anchors:
            d["anchors"] = anchors
    if not include_payload:
        return d
    p = row.get("payload")
    if isinstance(p, str):
        try:
            d["payload"] = json.loads(p)
        except ValueError:
            d["payload"] = p
    else:
        d["payload"] = ""
    return d


def _content_key(r: dict) -> str:
    """Cross-ledger dedup identity: id and created_at differ between the
    workspace and global copies of one record (port of recordContentKey)."""
    return f"{r.get('kind') or ''}\x1f{r.get('title') or ''}\x1f" \
           f"{r.get('payload') or ''}"


def _filters(args: dict) -> tuple[str, list]:
    """kind/source/status WHERE fragments (port of recordFilters)."""
    clauses: list[str] = []
    params: list = []
    for key in ("kind", "source", "status"):
        v = args.get(key)
        if v:
            clauses.append(f"{key} = ?")
            params.append(v)
    return " AND ".join(clauses), params


def _lenient_store(store_fn, workspace: str,
                   use_workspace_root: bool = False):
    """scope=global/all only need the global ledger — a missing index
    resolves to None instead of erroring (Swift: catch notIndexed)."""
    try:
        return store_fn(workspace, use_workspace_root=use_workspace_root)
    except FileNotFoundError:
        return None


def get_record(args: dict, store_fn) -> dict:
    """Port of SwctxTools.getRecord: workspace ledger by default, the
    repo-wide global ledger under scope=global, workspace-first-then-
    global under scope=all. The two ledgers are separate id namespaces."""
    scope = args.get("scope") or "workspace"
    if scope not in ("workspace", "global", "all"):
        raise ValueError("scope must be workspace | global | all")
    uwr = bool(args.get("use_workspace_root"))
    if scope == "workspace":
        store = store_fn(args.get("workspace", ""), use_workspace_root=uwr)
    else:
        store = _lenient_store(store_fn, args.get("workspace", ""), uwr)
    ws_key = repo_key(store.workspace) if store is not None else None
    rid = args.get("id")
    if isinstance(rid, bool) or not isinstance(rid, (int, float)):
        raise ValueError("missing required argument: id")
    rid = int(rid)
    include_payload = args.get("include_payload", True)
    try:
        if scope != "global" and store is not None:
            rows = _rows(
                store.db,
                f"SELECT {_select_cols(store.db)} FROM records "
                "WHERE id = ?", (rid,))
            if rows:
                d = record_dict(rows[0], include_payload)
                return {"record": with_staleness([d], store)[0]}
        if scope != "workspace":
            db = _connect()
            if db is not None:
                try:
                    sql = (f"SELECT {_select_cols(db, want_ws=True)} "
                           "FROM records WHERE id = ?")
                    params: tuple = (rid,)
                    if ws_key is not None:
                        sql += " AND ws = ?"
                        params = (rid, ws_key)
                    rows = _rows(db, sql, params)
                finally:
                    db.close()
                if rows:
                    d = record_dict(rows[0], include_payload)
                    return {"record": with_staleness([d], store)[0]}
        return {"error": "record not found", "id": rid}
    except sqlite3.Error as e:
        return {"error": f"records unavailable: {e}"}


def list_records(args: dict, store_fn) -> dict:
    """Port of SwctxTools.listRecords: kind/source/status filters,
    (kind='commit')-last ordering, limit/offset paging. scope=all unions
    workspace-first then global, deduped on (kind, title, payload)."""
    scope = args.get("scope") or "workspace"
    if scope not in ("workspace", "global", "all"):
        raise ValueError("scope must be workspace | global | all")
    uwr = bool(args.get("use_workspace_root"))
    if scope == "workspace":
        store = store_fn(args.get("workspace", ""), use_workspace_root=uwr)
    else:
        store = _lenient_store(store_fn, args.get("workspace", ""), uwr)
    ws_key = repo_key(store.workspace) if store is not None else None
    limit = min(max(int(args.get("limit") or 50), 1), 100)
    offset = max(int(args.get("offset") or 0), 0)
    where_sql, params = _filters(args)
    where_clause = f" WHERE {where_sql}" if where_sql else ""
    ws_clause = (where_clause if ws_key is None else
                 f"{where_clause} AND ws = ?" if where_clause
                 else " WHERE ws = ?")
    ws_params = [ws_key] if ws_key is not None else []
    order = " ORDER BY (kind = 'commit'), id DESC"
    try:
        if scope == "all":
            ws_rows = (_rows(
                store.db,
                f"SELECT {_select_cols(store.db)} FROM records"
                f"{where_clause}{order}", params)
                if store is not None else [])
            merged = [record_dict(r) for r in ws_rows]
            seen = {_content_key(r) for r in ws_rows}
            db = _connect()
            if db is not None:
                try:
                    g_rows = _rows(
                        db,
                        f"SELECT {_select_cols(db, want_ws=True)} "
                        f"FROM records{ws_clause}{order}",
                        params + ws_params)
                finally:
                    db.close()
                for r in g_rows:
                    k = _content_key(r)
                    if k in seen:
                        continue
                    seen.add(k)
                    merged.append(record_dict(r))
            page = merged[offset:offset + limit]
            return {"records": with_staleness(page, store),
                    "total": len(merged)}
        if scope == "global":
            db = _connect()
            if db is None:
                return {"records": [], "total": 0}
            try:
                total = db.execute(
                    f"SELECT COUNT(*) FROM records{ws_clause}",
                    params + ws_params).fetchone()[0]
                rows = _rows(
                    db,
                    f"SELECT {_select_cols(db, want_ws=True)} "
                    f"FROM records{ws_clause}{order} LIMIT ? OFFSET ?",
                    [*params, *ws_params, limit, offset])
            finally:
                db.close()
            return {"records": with_staleness(
                        [record_dict(r) for r in rows], store),
                    "total": total}
        if store is None:
            return {"error": "workspace scope requires a resolvable "
                             "indexed workspace"}
        total = store.db.execute(
            f"SELECT COUNT(*) FROM records{where_clause}",
            params).fetchone()[0]
        rows = _rows(
            store.db,
            f"SELECT {_select_cols(store.db)} FROM records{where_clause}"
            f"{order} LIMIT ? OFFSET ?", [*params, limit, offset])
        return {"records": with_staleness(
                    [record_dict(r) for r in rows], store),
                "total": total}
    except sqlite3.Error as e:
        return {"error": f"records unavailable: {e}"}


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
    """Auto-captured session context (port of SwctxTools.checkpoint):
    summary, next, branch, dirty_files — `files` wins when given, else
    `git status --porcelain` truncated to 50."""
    dirty = git(workspace, "status", "--porcelain")
    touched = [ln[3:] for ln in dirty.splitlines() if len(ln) > 3]
    return {
        "summary": summary,
        "next": next_step,
        "branch": git(workspace, "branch", "--show-current"),
        "dirty_files": files if files else touched[:50],
    }
