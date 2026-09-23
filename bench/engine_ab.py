#!/usr/bin/env python3
"""engine_ab.py — head-to-head retrieval probe: swctx vs ctxe over MCP.

Runs the SAME 22-query vn probe (bench/vn_queries.json) through one
persistent `swctx mcp` session and one persistent `ctxe mcp` session, and
records per-query whether the expected file appears in each engine's
top-5 file paths.

The two engines do NOT expose the same surface, so comparability is
explicit per query class:

  query_intent      swctx tool            ctxe tool                 tier
  -------------     --------------------  ------------------------  ----------
  symbol_lookup     search +              find_definitions          PARITY
                    find_definitions      (symbols = expected_symbol
                                         or query-derived fallback)
  concept_flow      search                get_workspace_tree        ASSIST
  + in_path                               (a) raw NL query  -> literal
                                            substring filter (shows the
                                            surface cannot take NL)
                                          (b) folded-token sweep -> per-
                                            token substring, files ranked
                                            by distinct-token match count
  concept_flow      search                (none)                    NO-SURFACE
  + in_body_only                          inspect_path is dir-scoped
                                          ('.' returns 0 chunks, '' is
                                          rejected); the only workspace-
                                          wide NL surface is ask_context
  <=4 sampled       search                ask_context               L2-SYNTH
  concept_flow                            (compose:false, effort:min,
                                          credit-metered — sampled, not
                                          bulk-called)

Fairness rules:
  * No call may consume the gold answer. inspect_path is therefore NOT
    scored for in_path queries: scoping it to the expected file's
    directory would leak where the answer lives, and it refuses a
    workspace-wide scope.
  * tree token-sweep uses ONLY tokens from the query (folded, len>=3) —
    the deterministic client-side adaptation a ctxe operator must make,
    labelled ASSIST rather than PARITY.
  * crm-10 (symbol_lookup, no expected_symbol) runs find_definitions on
    both engines with query-derived candidates — labelled 'nosym'.
  * Preflight ctxe index membership per query via a basename tree filter
    (verification only — same role as vn_probe's index check, never a
    retrieval input).

Credit discipline: ask_context is called at most --ask-cap (4) times,
compose:false + effort:min, retries=0. On timeout the spec-sanctioned
FREE recovery runs once: list_records(kind:ask) -> get_record on the
newest matching record — a local read, no new spend.

Timeout: --ctxe-timeout (default 60s) per ctxe call; a timeout is
recorded as status 'timeout', never a crash.

Stdlib only. Usage:
    python3 bench/engine_ab.py                      # full run, JSON stdout
    python3 bench/engine_ab.py --no-ask             # zero-credit run
    python3 bench/engine_ab.py --out engine_ab_results.json
"""

import argparse
import json
import math
import os
import sys
import time
import unicodedata
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession  # noqa: E402  (reuse the proven stdio client)

DEFAULT_QUERIES = os.path.join(HERE, "vn_queries.json")
DEFAULT_SWCTX_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")
DEFAULT_CTXE_BIN = "ctxe"
ASK_CAP = 4
# Sample chosen for information value under the credit cap: one swctx-hit
# sanity check (seo-01) + three swctx-misses covering both workspaces,
# both path_signal classes and the vn_to_en tag.
DEFAULT_ASK_SAMPLE = ["seo-01", "seo-09", "crm-04", "crm-11"]
# symbol_lookup query without expected_symbol: candidates derived from
# the query text only ("realign local issue ids ...").
SYMBOL_FALLBACK = {"crm-10": ["realign", "realign_issue_ids",
                              "realign_issues"]}


# ----------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------

def norm_path(p):
    return (p or "").strip().lstrip("./")


def fold(s):
    """NFKD-fold + strip combining marks: 'kiểm tra đăng' -> 'kiem tra dang'."""
    return "".join(c for c in unicodedata.normalize("NFKD", (s or "").lower())
                   if not unicodedata.combining(c))


def tokens_of(query):
    """Folded query tokens, len>=3, deduped, order-preserving."""
    out, seen = [], set()
    for t in fold(query).replace("_", " ").replace("-", " ").split():
        t = "".join(ch for ch in t if ch.isalnum())
        if len(t) >= 3 and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def rank_of(expected, paths):
    try:
        return paths.index(expected) + 1
    except ValueError:
        return 0


def percentile(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    return s[max(1, math.ceil(q / 100.0 * len(s))) - 1]


def median(vals):
    s = sorted(v for v in vals if v is not None)
    if not s:
        return None
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m - 1] + s[m]) / 2


def collect_file_paths(payload):
    """Ordered, deduped file_path harvest from any ctxe payload.

    Direct-evidence keys are walked before related-evidence keys so the
    path order approximates engine ranking; unknown-but-file-bearing
    keys are walked last. Handles ask_context (direct_evidence /
    related_evidence / grouped blocks), inspect_path (chunks) and
    find_definitions shapes uniformly.
    """
    direct_keys = ("direct_evidence", "direct", "blocks", "groups",
                   "sources", "answer", "chunks", "definitions")
    related_keys = ("related_evidence", "related", "evidence")

    paths, seen = [], set()

    def walk(node):
        if isinstance(node, dict):
            fp = node.get("file_path") or node.get("path")
            if isinstance(fp, str) and fp and fp not in seen:
                seen.add(fp)
                paths.append(norm_path(fp))
            for v in node.values():
                if isinstance(v, (dict, list)):
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    if not isinstance(payload, dict):
        return paths
    consumed = set()
    for k in direct_keys + related_keys:
        if k in payload:
            consumed.add(k)
            walk(payload[k])
    for k, v in payload.items():
        if k not in consumed:
            walk(v)
    return paths


# ----------------------------------------------------------------------
# Engine calls — each returns a result dict
# ----------------------------------------------------------------------

def _res(paths, expected, latency, status="ok", **extra):
    r = {"paths": paths, "rank": rank_of(expected, paths),
         "latency_ms": round(latency, 1) if latency is not None else None,
         "status": status}
    r.update(extra)
    return r


def sw_search(session, ws, query, expected, limit):
    payload, lat, err = session.call_tool(
        "search", {"workspace": ws, "query": query, "mode": "auto",
                   "limit": limit}, timeout=60)
    if err:
        return _res([], expected, lat, "error", error=err)
    return _res([norm_path(h.get("path")) for h in payload.get("hits", [])],
                expected, lat)


def sw_find_defs(session, ws, symbols, expected, limit):
    payload, lat, err = session.call_tool(
        "find_definitions",
        {"workspace": ws, "symbols": symbols, "include_content": False},
        timeout=60)
    if err:
        return _res([], expected, lat, "error", error=err)
    paths = [norm_path(d.get("path")) for r in payload.get("results", [])
             for d in r.get("definitions", [])]
    return _res(paths[:limit], expected, lat, symbols=symbols)


def cx_find_defs(session, ws, symbols, expected, limit):
    payload, lat, err = session.call_tool(
        "find_definitions",
        {"workspace": ws, "symbols": symbols, "include_content": False},
        retries=1, timeout=60)
    if err:
        return _res([], expected, lat,
                    "timeout" if err and "timeout" in err else "error",
                    error=err, symbols=symbols)
    paths = [norm_path(c.get("file_path"))
             for d in payload.get("definitions", [])
             for c in d.get("chunks", [])]
    not_found = [s for s in payload.get("not_found", [])]
    return _res(paths[:limit], expected, lat, symbols=symbols,
                **({"not_found": not_found} if not_found else {}))


def cx_tree_files(session, ws, query, limit=1000):
    """get_workspace_tree substring filter -> flat ordered file paths."""
    payload, lat, err = session.call_tool(
        "get_workspace_tree",
        {"workspace": ws, "query": query, "limit": limit},
        retries=1, timeout=60)
    if err:
        return [], lat, err
    files = []
    for d in payload.get("directories", []):
        for f in d.get("files", []):
            files.append(norm_path(f.get("path")))
    # flat fallback shape (some builds return a bare files list)
    for f in payload.get("files", []):
        if isinstance(f, dict):
            files.append(norm_path(f.get("path")))
    return files, lat, None


def cx_tree_raw(session, ws, query, expected, limit):
    """Raw NL string as the path-substring filter (expected: no match)."""
    files, lat, err = cx_tree_files(session, ws, query, limit=50)
    if err:
        return _res([], expected, lat, "error", error=err)
    return _res(files[:limit], expected, lat, n_files=len(files))


def cx_tree_tokens(session, ws, tokens, expected, limit):
    """Folded-token substring sweep; rank files by distinct-token hits."""
    score, order, orig, lat_sum, errs = {}, {}, {}, 0.0, []
    for tok in tokens[:12]:
        files, lat, err = cx_tree_files(session, ws, tok, limit=1000)
        if lat:
            lat_sum += lat
        if err:
            errs.append(f"{tok}: {err}")
            continue
        for p in files:
            fp = fold(p)
            if fp not in score:
                order[fp] = len(order)
                orig[fp] = p
                score[fp] = set()
            score[fp].update(t for t in tokens if t in fp)
    ranked = sorted(score.items(),
                    key=lambda kv: (-len(kv[1]), order[kv[0]]))
    paths = [orig[fp] for fp, _ in ranked[:limit]]
    r = _res(paths, expected, lat_sum or None,
             "error" if errs and not score else "ok",
             n_candidates=len(score))
    if errs:
        r["errors"] = errs[:5]
    return r


def cx_record_evidence(session, ws, query, expected, limit, record_id=None):
    """FREE local read: resolve this ask's durable record and return the
    evidence file ranking (direct before related, deduped). The live
    ask_context response truncates evidence under the output budget and
    may carry only chunk IDs; the full hydrated evidence persists in the
    ask record — per spec, `get_record` is the sanctioned follow-up.
    Returns a dict; never raises."""
    out = {}
    try:
        rid = record_id
        if rid is None:
            lr, _, lerr = session.call_tool(
                "list_records",
                {"workspace": ws, "kind": "ask", "source": "mcp",
                 "limit": 10},
                retries=0, timeout=30)
            items = (lr or {}).get("items") \
                or (lr or {}).get("records") or []
            for it in items:  # newest first; match our query
                if (it.get("query") or it.get("title") or "")[:80] \
                        == query[:80]:
                    rid = it.get("id") or it.get("record_id")
                    break
            if rid is None and items:
                rid = items[0].get("id") or items[0].get("record_id")
            out["list_err"] = lerr
        if rid is None:
            out["status"] = "no-record"
            return out
        gr, _, gerr = session.call_tool(
            "get_record",
            {"workspace": ws, "id": rid, "include_payload": True},
            retries=0, timeout=30)
        recd = (gr or {}).get("record") or gr or {}
        pay = recd.get("payload") or {}
        if isinstance(pay, str):
            try:
                pay = json.loads(pay)
            except ValueError:
                pay = {}
        st = recd.get("status") or pay.get("progress", {}).get("status")
        out.update({"id": rid, "status": st, "get_err": gerr})
        if st == "completed" and pay:
            paths = collect_file_paths(pay)[:limit]
            out.update({"paths": paths, "rank": rank_of(expected, paths)})
    except Exception as e:
        out["error"] = str(e)[:120]
    return out


def cx_ask(session, ws, query, expected, limit, timeout):
    """ask_context compose:false effort:min. retries=0 — credit cap.
    `rank`/`paths` reflect the LIVE wire response; `record_evidence`
    adds the free get_record follow-up (what the ask actually gathered).
    On timeout the same record path is the spec-sanctioned recovery."""
    t0 = time.monotonic()
    resp = session.request(
        "tools/call",
        {"name": "ask_context",
         "arguments": {"workspace": ws, "query": query,
                       "compose": False, "effort": "min"}},
        timeout=timeout)
    lat = (time.monotonic() - t0) * 1000.0
    if resp is not None and "error" not in resp:
        result = resp.get("result", {})
        texts = [c.get("text", "") for c in result.get("content", [])
                 if c.get("type") == "text"]
        raw = "\n".join(texts)
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {"_raw": raw}
        if result.get("isError"):
            return _res([], expected, lat, "error", error=raw[:300])
        rec = _res(collect_file_paths(payload)[:limit], expected, lat,
                   payload_keys=sorted(payload.keys())[:20])
        rid = payload.get("record_id")
        rec["record_evidence"] = cx_record_evidence(
            session, ws, query, expected, limit, record_id=rid)
        return rec
    if resp is not None:  # rpc-level error
        err = f"rpc {resp['error'].get('code')}: {resp['error'].get('message')}"
        return _res([], expected, lat, "error", error=err)

    # ---- timeout: try the free record-ledger recovery once ----
    rec = {"rank": 0, "paths": [], "latency_ms": round(lat, 1),
           "status": "timeout"}
    rec["record_recovery"] = cx_record_evidence(
        session, ws, query, expected, limit)
    if rec["record_recovery"].get("status") == "completed":
        rec["status"] = "timeout-recovered"
    return rec


# ----------------------------------------------------------------------
# Sessions
# ----------------------------------------------------------------------

def start_swctx(bin_path, workspaces):
    try:
        s = MCPSession("swctx", [bin_path, "mcp"], timeout=60)
        s.start()
    except Exception as e:
        return None, f"swctx mcp start failed: {e}"
    if not s.tools:
        s.stop()
        return None, "swctx mcp tools/list failed"
    for ws in workspaces:
        s.call_tool("search",
                    {"workspace": ws,
                     "query": "warmup load index and embedder",
                     "mode": "auto", "limit": 1}, retries=0, timeout=60)
    return s, None


def start_ctxe(bin_path, workspaces):
    """Start ctxe mcp; get_status per workspace -> {ws: indexed_bool}."""
    try:
        s = MCPSession("ctxe", [bin_path, "mcp"], timeout=60)
        s.start()
    except Exception as e:
        return None, f"ctxe mcp start failed: {e}", {}
    if not s.tools:
        s.stop()
        return None, "ctxe mcp tools/list failed", {}
    indexed = {}
    for ws in workspaces:
        payload, _, err = s.call_tool("get_status", {"workspace": ws},
                                      retries=2, timeout=90)
        state = (payload or {}).get("base", {}).get("state")
        ok = bool(payload and payload.get("base", {}).get("indexed")
                  and state in ("Ready", "Degraded"))
        indexed[ws] = {"indexed": ok, "state": state,
                       **({"error": err} if err else {}),
                       **({"files": payload["base"].get("indexed_files")}
                          if ok else {})}
    return s, None, indexed


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="swctx vs ctxe head-to-head over MCP on the vn probe")
    ap.add_argument("--queries", default=DEFAULT_QUERIES)
    ap.add_argument("--swctx-bin", default=DEFAULT_SWCTX_BIN)
    ap.add_argument("--ctxe-bin", default=DEFAULT_CTXE_BIN)
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--ctxe-timeout", type=float, default=60.0,
                    help="per-call ctxe timeout seconds (default 60)")
    ap.add_argument("--engine", choices=["both", "swctx", "ctxe"],
                    default="both")
    ap.add_argument("--no-ask", action="store_true",
                    help="skip ask_context entirely (zero credits)")
    ap.add_argument("--ask-sample", default=",".join(DEFAULT_ASK_SAMPLE),
                    help="comma-separated query ids for ask_context "
                         f"(hard cap {ASK_CAP})")
    ap.add_argument("--out", default="",
                    help="also write the JSON report to this path")
    args = ap.parse_args()

    spec = json.load(open(args.queries))
    queries = spec["queries"]
    workspaces = []
    for q in queries:
        if q["workspace"] not in workspaces:
            workspaces.append(q["workspace"])

    sample = [s.strip() for s in args.ask_sample.split(",") if s.strip()]
    if len(sample) > ASK_CAP:
        print(f"warn: ask sample truncated to {ASK_CAP}", file=sys.stderr)
        sample = sample[:ASK_CAP]

    # ---- sessions ----
    sessions, notes = {}, {}
    if args.engine in ("both", "swctx"):
        s, err = start_swctx(args.swctx_bin, workspaces)
        sessions["swctx"] = s
        if err:
            notes["swctx"] = err
    ctxe_indexed = {}
    if args.engine in ("both", "ctxe"):
        s, err, ctxe_indexed = start_ctxe(args.ctxe_bin, workspaces)
        sessions["ctxe"] = s
        if err:
            notes["ctxe"] = err

    sw, cx = sessions.get("swctx"), sessions.get("ctxe")
    records = []
    lat_by_tool = {}

    # Warm the durable translation/round-2 caches before measuring: the
    # first cold run of a query races the result deadline (a 3B roll
    # that lands late still writes the cache), so a one-shot pass over
    # cold caches measures roll luck, not retrieval quality. Production
    # MCP is long-lived — steady state IS warm cache. Results discarded.
    if sw:
        for q in queries:
            try:
                sw.call_tool("search",
                             {"workspace": q["workspace"],
                              "query": q["query"], "mode": "auto",
                              "limit": 1}, timeout=60)
            except Exception:
                pass

    for i, q in enumerate(queries):
        qid, ws, query = q["id"], q["workspace"], q["query"]
        expected = norm_path(q.get("expected_path"))
        intent = q.get("query_intent", "")
        psig = q.get("path_signal", "")
        rec = {"id": qid, "workspace": ws, "lang": q.get("lang"),
               "tags": q.get("tags", []), "query_intent": intent,
               "path_signal": psig, "query": query,
               "expected_path": expected, "results": {}}
        R = rec["results"]

        def put(tool, res):
            R[tool] = res
            if res.get("latency_ms") is not None:
                lat_by_tool.setdefault(tool, []).append(res["latency_ms"])

        # ---------- preflight: is expected even in the ctxe index? ----
        if cx:
            base = expected.rsplit("/", 1)[-1]
            files, _, _ = cx_tree_files(cx, ws, base, limit=50)
            rec["ctxe_index_has_expected"] = expected in files

        # ---------- swctx search: all 22 queries --------------------
        if sw:
            put("swctx:search", sw_search(sw, ws, query, expected,
                                          args.limit))

        # ---------- symbol_lookup: parity via find_definitions ------
        if intent == "symbol_lookup":
            syms = ([q["expected_symbol"]] if q.get("expected_symbol")
                    else SYMBOL_FALLBACK.get(qid, []))
            if syms:
                if sw:
                    put("swctx:find_definitions",
                        sw_find_defs(sw, ws, syms, expected, args.limit))
                if cx:
                    if ctxe_indexed.get(ws, {}).get("indexed"):
                        put("ctxe:find_definitions",
                            cx_find_defs(cx, ws, syms, expected,
                                         args.limit))
                    else:
                        put("ctxe:find_definitions",
                            _res([], expected, None, "not-indexed"))
            else:
                for eng in ("swctx", "ctxe"):
                    if sessions.get(eng):
                        put(f"{eng}:find_definitions",
                            _res([], expected, None, "no-symbol"))

        # ---------- concept_flow ------------------------------------
        if intent == "concept_flow" and cx:
            if ctxe_indexed.get(ws, {}).get("indexed"):
                if psig == "in_path":
                    put("ctxe:workspace_tree(raw)",
                        cx_tree_raw(cx, ws, query, expected, args.limit))
                    put("ctxe:workspace_tree(token-sweep)",
                        cx_tree_tokens(cx, ws, tokens_of(query),
                                       expected, args.limit))
                elif qid not in sample:
                    put("ctxe:none",
                        {"paths": [], "rank": 0, "latency_ms": None,
                         "status": "no-surface",
                         "note": "no free workspace-wide NL retrieval; "
                                 "inspect_path needs a dir scope, "
                                 "ask_context costs credits"})
            else:
                put("ctxe:none", {"paths": [], "rank": 0,
                                  "latency_ms": None,
                                  "status": "not-indexed"})

        # ---------- ask_context sample (<=4, credit-metered) --------
        if cx and qid in sample and not args.no_ask:
            if ctxe_indexed.get(ws, {}).get("indexed"):
                put("ctxe:ask_context(min,nocompose)",
                    cx_ask(cx, ws, query, expected, args.limit,
                           args.ctxe_timeout))
            else:
                put("ctxe:ask_context(min,nocompose)",
                    _res([], expected, None, "not-indexed"))

        hits = {k: v.get("rank") or "-" for k, v in R.items()}
        print(f"[{i + 1}/{len(queries)}] {qid} "
              + " ".join(f"{k.split(':')[1].split('(')[0]}={v}"
                         for k, v in hits.items()),
              file=sys.stderr)
        records.append(rec)

    for s in sessions.values():
        if s:
            s.stop()

    # ---------- aggregates ----------
    def recall(rs, key):
        ran = [r for r in rs
               if key in r["results"]
               and r["results"][key].get("status") in
               ("ok", "timeout-recovered", "error", "timeout")]
        hits = sum(1 for r in ran if r["results"][key]["rank"])
        return {"n": len(ran), "hits": hits,
                "recall_at_5": round(hits / len(ran), 4) if ran else None}

    tools_seen = sorted({k for r in records for k in r["results"]})
    aggregate = {}
    for tool in tools_seen:
        aggregate[tool] = {
            "ALL": recall(records, tool),
            "concept_flow": recall(
                [r for r in records
                 if r["query_intent"] == "concept_flow"], tool),
            "symbol_lookup": recall(
                [r for r in records
                 if r["query_intent"] == "symbol_lookup"], tool),
            "in_path": recall(
                [r for r in records if r["path_signal"] == "in_path"],
                tool),
            "in_body_only": recall(
                [r for r in records
                 if r["path_signal"] == "in_body_only"], tool),
        }

    no_surface = [r["id"] for r in records
                  if any(v.get("status") == "no-surface"
                         for v in r["results"].values())]
    not_indexed = [r["id"] for r in records
                   if not r.get("ctxe_index_has_expected", True)]

    out = {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "probe": os.path.basename(args.queries), "limit": args.limit,
        "ask_sample": sample if not args.no_ask else [],
        "session_notes": notes,
        "ctxe_index": ctxe_indexed,
        "latency_ms": {
            t: {"p50": round(median(v) or 0, 1),
                "p95": round(percentile(v, 95) or 0, 1),
                "n_calls": len(v)}
            for t, v in sorted(lat_by_tool.items())},
        "ctxe_no_surface_queries": no_surface,
        "ctxe_index_missing_expected": not_indexed,
        "aggregate": aggregate,
        "queries": records,
    }
    text = json.dumps(out, indent=1, ensure_ascii=False)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
        print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
