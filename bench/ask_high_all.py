#!/usr/bin/env python3
"""ask_high_all.py — ctxe ask_context at effort="high" over ALL 22 vn probes.

True-ceiling baseline: high = up to 48 planner rounds (min=3, medium=6).
For each ask we harvest (a) the live wire response — often truncated under
the output budget — and (b) the FREE durable-record evidence via
list_records -> get_record (the full hydrated evidence per spec).

Timeout recovery (per ctxe Ask spec): an MCP client timeout does NOT mean
the server-side Ask died — it keeps running and updating its durable
record. So on timeout we do NOT retry the ask; we poll list_records /
get_record for the newest matching {query} for up to RECOVERY_BUDGET_S
seconds until the record reaches a terminal status.

Record matching: before each ask we snapshot the newest ask-record id for
that workspace (prev_newest). During polling we accept an item whose
query/title matches our query[:80] (strict), or — when no item carries a
matching query string — the first item whose id differs from prev_newest
(fresh). We never accept prev_newest itself, so a stale completed record
from an earlier run cannot be mistaken for ours.

Writes bench/ask_high_results.json after EVERY query (merge per id), so a
crash mid-run keeps completed queries; reruns resume by skipping ids that
already have a result row.

Usage: python3 ask_high_all.py [--timeout 480] [--recovery 600]
           [--queries vn_queries.json] [--out ask_high_results.json]
           [--only seo-01,seo-02] [--force]
"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession                          # noqa: E402
from engine_ab import collect_file_paths, rank_of, norm_path  # noqa: E402

QUERIES = os.path.join(HERE, "vn_queries.json")
OUT = os.path.join(HERE, "ask_high_results.json")
EFFORT = "high"
WIRE_TIMEOUT = 480          # live ask_context wire timeout (s)
RECOVERY_BUDGET = 600       # post-timeout record poll budget (s)
POLL_EVERY = 15             # poll interval (s)
TERMINAL_BAD = ("failed", "error", "cancelled", "canceled")


# ----------------------------------------------------------------------
# ctxe calls
# ----------------------------------------------------------------------

def cx_ask_high(session, ws, query, timeout):
    """Fire ask_context effort=high. Returns (live_dict, record_id).
    live_dict carries 'paths' (unscored), status, latency_ms."""
    t0 = time.monotonic()
    resp = session.request(
        "tools/call",
        {"name": "ask_context",
         "arguments": {"workspace": ws, "query": query,
                       "compose": False, "effort": EFFORT}},
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
            return {"paths": [], "latency_ms": round(lat, 1),
                    "status": "error", "error": raw[:300]}, None
        return {"paths": collect_file_paths(payload),
                "latency_ms": round(lat, 1), "status": "ok",
                "payload_keys": sorted(payload.keys())[:20]}, \
            payload.get("record_id")
    if resp is not None:
        err = f"rpc {resp['error'].get('code')}: {resp['error'].get('message')}"
        return {"paths": [], "latency_ms": round(lat, 1),
                "status": "error", "error": err}, None
    return {"paths": [], "latency_ms": round(lat, 1),
            "status": "timeout"}, None


def list_ask_records(session, ws):
    """list_records -> (items, err). items newest-first."""
    lr, _, lerr = session.call_tool(
        "list_records",
        {"workspace": ws, "kind": "ask", "source": "mcp", "limit": 10},
        retries=0, timeout=30)
    items = (lr or {}).get("items") or (lr or {}).get("records") or []
    return items, lerr


def newest_record_id(session, ws, retries=4):
    """Newest ask-record id for ws, retrying transient runtime-acquisition
    failures (cold ctxe runtime returns an rpc error for ~5s)."""
    for attempt in range(retries):
        items, lerr = list_ask_records(session, ws)
        if lerr is None:
            return (items[0].get("id") or items[0].get("record_id")
                    if items else None)
        time.sleep(4)
    return None


def find_ask_record(session, ws, query, prev_newest, exclude):
    """Locate OUR ask record: strict query match first, else a record
    newer than prev_newest. Never returns prev_newest, an excluded id, or
    an older same-query record (queries repeat across benchmark runs)."""
    items, lerr = list_ask_records(session, ws)
    for it in items:  # strict: newest record matching our query only
        if (it.get("query") or it.get("title") or "")[:80] == query[:80]:
            rid = it.get("id") or it.get("record_id")
            if rid != prev_newest and rid not in exclude:
                return rid, lerr, "query"
            break  # newest same-query record is excluded/prev -> ours
            # not registered yet; an older match would be stale
    for it in items:  # fresh: created after our ask started
        rid = it.get("id") or it.get("record_id")
        if rid is not None and rid != prev_newest and rid not in exclude:
            return rid, lerr, "fresh"
    return None, lerr, None


def _iso_to_epoch(s):
    try:
        from datetime import datetime, timezone
        return datetime.fromisoformat(
            s.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except Exception:
        return None


def read_ask_record(session, ws, rid):
    """get_record -> (status, paths, err, created_epoch, payload_query).
    Never raises."""
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
    paths = collect_file_paths(pay) if st == "completed" and pay else []
    return (st, paths, gerr, _iso_to_epoch(recd.get("created_at") or ""),
            pay.get("query"))


def poll_record(session, ws, query, rid, prev_newest, ask_t0, deadline):
    """Poll list_records/get_record until terminal or deadline. A matched
    record is only accepted as ours when its created_at >= ask_t0-90s and
    (when hydrated) its payload.query matches our query — stale records
    from earlier runs are excluded and the search continues.
    Returns {id, status, paths?, match, polls, err?}."""
    polls, match, exclude = 0, ("known" if rid is not None else None), set()
    last = {"id": rid, "status": "running" if rid else "no-record"}
    while time.monotonic() < deadline:
        polls += 1
        if rid is None:
            rid, lerr, match = find_ask_record(session, ws, query,
                                               prev_newest, exclude)
            last = {"id": rid, "status": "no-record", "match": match,
                    **({"list_err": lerr} if lerr else {})}
            if rid is None:
                time.sleep(POLL_EVERY)
                continue
        st, paths, gerr, cts, pquery = read_ask_record(session, ws, rid)
        stale = (cts is not None and cts < ask_t0 - 90) or \
            (pquery and pquery[:80] != query[:80])
        if stale:
            exclude.add(rid)
            rid = None
            last = {"id": None, "status": "no-record",
                    "note": "excluded stale/wrong record"}
            time.sleep(POLL_EVERY)
            continue
        last = {"id": rid, "status": st, "match": match,
                **({"get_err": gerr} if gerr else {})}
        if st == "completed":
            last["paths"] = paths
            last["polls"] = polls
            return last
        if st in TERMINAL_BAD:
            last["polls"] = polls
            return last
        time.sleep(POLL_EVERY)
    last["polls"] = polls
    last["recovery"] = "budget-exhausted"
    return last


# ----------------------------------------------------------------------
# incremental result file
# ----------------------------------------------------------------------

def load_prior(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}


def save(path, results, order, extra):
    qs = [results[qid] for qid in order if qid in results]
    hits = sum(1 for q in qs if q.get("hit"))
    lats = [q["latency_s"] for q in qs if q.get("latency_s") is not None]
    doc = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
           "effort": EFFORT, "compose": False,
           "wire_timeout_s": extra["wire_timeout"],
           "recovery_budget_s": extra["recovery"],
           "summary": {"n_done": len(qs), "n_total": len(order),
                       "hits": hits,
                       "mean_latency_s": round(sum(lats) / len(lats), 1)
                       if lats else None,
                       "max_latency_s": round(max(lats), 1)
                       if lats else None},
           "ctxe_index": extra.get("ctxe_index", {}),
           "queries": qs}
    errs = [str(q.get("error") or q.get("live", {}).get("error") or "")
            for q in qs]
    if qs and all("insufficient_credit" in e or "quota_exceeded" in e
                  for e in errs):
        doc["summary"]["blocked"] = (
            "ctxe account insufficient_credit (402 quota_exceeded): "
            "no ask_context executed — top up the ctxe wallet and rerun "
            "(error rows are retried automatically)")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


# ----------------------------------------------------------------------
# driver
# ----------------------------------------------------------------------

def argval(flag, default, cast=str):
    if flag in sys.argv:
        return cast(sys.argv[sys.argv.index(flag) + 1])
    return default


def main():
    qpath = argval("--queries", QUERIES)
    out_path = argval("--out", OUT)
    wire_timeout = argval("--timeout", WIRE_TIMEOUT, int)
    recovery = argval("--recovery", RECOVERY_BUDGET, int)
    only = argval("--only", "")
    only = {s.strip() for s in only.split(",") if s.strip()}
    force = "--force" in sys.argv

    spec = json.load(open(qpath))
    queries = [q for q in spec["queries"]
               if not only or q["id"] in only]
    order = [q["id"] for q in queries]

    prior = load_prior(out_path)
    results = {} if force else {q["id"]: q for q in prior.get("queries", [])}
    # rows that reached a real ask outcome count as done; rows that failed
    # at the dispatch/rpc level (e.g. insufficient_credit) are retried on
    # rerun so a topped-up wallet can resume with a bare invocation.
    done = {qid for qid, r in results.items()
            if r.get("status") not in (None, "error")}
    todo = [q for q in queries if q["id"] not in done]
    print(f"{len(queries)} queries, {len(done)} already done, "
          f"{len(todo)} to run", flush=True)
    if not todo:
        save(out_path, results, order,
             {"wire_timeout": wire_timeout, "recovery": recovery})
        print("nothing to do")
        return

    cx = MCPSession("ctxe", ["ctxe", "mcp"], timeout=wire_timeout)
    cx.start()
    print("ctxe mcp up:", cx.server_info, flush=True)

    # preflight index membership (verification only — never a query input)
    # an index counts as present when base.indexed is true; state may be
    # "Ready" or "Degraded" (stale/pending chunks) — both are retrievable.
    # get_status can return an E_STATUS_TIMEOUT payload (meta.status=error)
    # on a cold runtime, so retry until a base block appears.
    ctxe_index = {}
    for ws in dict.fromkeys(q["workspace"] for q in queries):
        base, err, attempts = {}, None, 0
        for attempts in range(1, 4):
            payload, _, err = cx.call_tool("get_status", {"workspace": ws},
                                           retries=1, timeout=90)
            if payload and payload.get("base"):
                base = payload["base"]
                break
            if payload and payload.get("status_error"):
                err = payload["status_error"].get("code")
            time.sleep(3)
        ok = bool(base.get("indexed") and base.get("db_exists", True))
        ctxe_index[ws] = {"indexed": ok, "state": base.get("state"),
                          "attempts": attempts,
                          **({"error": err} if err and not ok else {}),
                          **({"files": base.get("indexed_files")}
                             if ok else {})}
        print(f"  index {ws}: "
              f"{base.get('state') if ok else 'ABSENT'} "
              f"files={base.get('indexed_files')} attempts={attempts}",
              flush=True)

    extra = {"wire_timeout": wire_timeout, "recovery": recovery,
             "ctxe_index": ctxe_index}
    prev_newest = {}  # ws -> newest ask-record id before our ask

    for i, q in enumerate(todo):
        qid, ws, query = q["id"], q["workspace"], q["query"]
        expected = norm_path(q["expected_path"])
        print(f"[{i + 1}/{len(todo)}] {qid} ask(high) …", flush=True)
        t0 = time.monotonic()

        row = {"id": qid, "workspace": ws, "query": query,
               "expected_path": expected, "hit": False, "rank": 0,
               "latency_s": None, "top_paths": [], "record_id": None}

        if not ctxe_index.get(ws, {}).get("indexed"):
            row.update(status="not-indexed", latency_s=0.0,
                       error="workspace index not Ready")
            results[qid] = row
            save(out_path, results, order, extra)
            continue

        if ws not in prev_newest:
            prev_newest[ws] = newest_record_id(cx, ws)

        ask_t0 = time.time()  # wall clock, for record created_at check
        live, rid = cx_ask_high(cx, ws, query, wire_timeout)
        row["live"] = live
        row["record_id"] = rid

        # durable record: one read when live came back, poll on timeout
        if live["status"] == "ok" and rid is not None:
            st, paths, gerr, cts, pq = read_ask_record(cx, ws, rid)
            rec = {"id": rid, "status": st, "match": "record_id",
                   **({"get_err": gerr} if gerr else {}),
                   **({"paths": paths} if st == "completed" else {})}
            if st != "completed":  # rare: still finishing server-side
                rec = poll_record(cx, ws, query, rid, prev_newest[ws],
                                  ask_t0, time.monotonic() + 120)
        elif live["status"] == "timeout":
            rec = poll_record(cx, ws, query, rid, prev_newest[ws], ask_t0,
                              time.monotonic() + recovery)
            if rec.get("status") == "completed":
                row["status"] = "timeout-recovered"
        elif live["status"] == "ok":  # ok but no record_id in payload
            rec = poll_record(cx, ws, query, None, prev_newest[ws],
                              ask_t0, time.monotonic() + 120)
        else:
            rec = {"id": rid, "status": "skipped",
                   "note": "ask errored at rpc/tool level"}

        row["record"] = rec
        if rec.get("id"):
            row["record_id"] = rec["id"]
        prev_newest[ws] = row["record_id"] or prev_newest[ws]
        row["latency_s"] = round(time.monotonic() - t0, 1)

        # score: prefer the full durable-record evidence; live paths fill in
        rec_paths = rec.get("paths") or []
        live_paths = live.get("paths") or []
        evidence = rec_paths if rec_paths else live_paths
        rank = rank_of(expected, evidence)
        if not rank and expected in live_paths:
            rank = live_paths.index(expected) + 1
            evidence = live_paths
        row["hit"] = bool(rank)
        row["rank"] = rank
        row["top_paths"] = evidence[:5]
        if "status" not in row:
            if live["status"] == "error":
                row["status"] = "error"
                row["error"] = live.get("error")
            elif rec.get("status") in TERMINAL_BAD:
                row["status"] = "record-failed"
                row["error"] = f"ask record status={rec.get('status')}"
            elif rec.get("status") == "completed" or live["status"] == "ok":
                row["status"] = "ok"
            else:
                row["status"] = "error"
                row["error"] = (f"unresolved: live={live['status']} "
                                f"record={rec.get('status')} "
                                f"{rec.get('recovery', '')}")
        results[qid] = row
        save(out_path, results, order, extra)
        print(f"  -> hit={row['hit']} rank={row['rank']} "
              f"status={row['status']} lat={row['latency_s']}s "
              f"rec={row['record_id']}", flush=True)

        # resurrect the session if the server died
        if cx.proc.poll() is not None:
            print("  ctxe process died — restarting session", flush=True)
            cx = MCPSession("ctxe", ["ctxe", "mcp"], timeout=wire_timeout)
            cx.start()
            prev_newest.clear()

    cx.stop()
    qs = [results[qid] for qid in order if qid in results]
    hits = sum(1 for q in qs if q.get("hit"))
    lats = [q["latency_s"] for q in qs if q.get("latency_s")]
    print("\n==== effort=high, all queries ====")
    for q in qs:
        print(f"  {q['id']:8s} {'HIT ' if q['hit'] else 'miss'} "
              f"rank={q['rank']} {q['latency_s']}s {q['expected_path']}")
    if lats:
        print(f"hits {hits}/{len(qs)}  "
              f"mean_lat={sum(lats) / len(lats):.1f}s  "
              f"max_lat={max(lats):.1f}s")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
