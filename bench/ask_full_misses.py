#!/usr/bin/env python3
"""ask_full_misses.py — run ctxe ask_context over ALL swctx-missed queries.

engine_ab.py sampled 4 asks under a credit cap. This run covers the
remaining swctx-search misses so the L2 rescue rate is measured on the
full miss set, not a sample. For each ask: live wire view + the FREE
durable-record view (list_records -> get_record direct_evidence).
Also verifies compose_answer once on a completed record.

Usage: python3 ask_full_misses.py [--timeout 90]
"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession                    # noqa: E402
from engine_ab import (cx_ask, cx_record_evidence,  # noqa: E402
                       collect_file_paths, rank_of)

RESULTS = os.path.join(HERE, "engine_ab_results.json")
OUT = os.path.join(HERE, "ask_full_results.json")

def main():
    timeout = 90
    if "--timeout" in sys.argv:
        timeout = int(sys.argv[sys.argv.index("--timeout") + 1])

    res = json.load(open(RESULTS))
    # swctx-search misses with no prior ask sample
    misses = []
    for q in res["queries"]:
        swr = q["results"].get("swctx:search") or {}
        if swr.get("rank"):
            continue
        if any(k.startswith("ctxe:ask_context") for k in q["results"]):
            continue
        misses.append(q)
    print(f"{len(misses)} unsampled misses: {[q['id'] for q in misses]}")

    cx = MCPSession("ctxe", ["ctxe", "mcp"], timeout=timeout)
    cx.start()
    out = []
    for q in misses:
        ws, query, exp = q["workspace"], q["query"], q["expected_path"]
        print(f"ask {q['id']} …", flush=True)
        r = cx_ask(cx, ws, query, exp, 5, timeout)
        # durable-record evidence (free follow-up per spec)
        rec = cx_record_evidence(cx, ws, query, exp, 5,
                                 record_id=(r.get("record_id")
                                            if isinstance(r, dict) else None))
        row = {"id": q["id"], "workspace": ws, "query": query,
               "expected": exp,
               "live": {"rank": r.get("rank"), "paths": r.get("paths"),
                        "latency_ms": r.get("latency_ms"),
                        "status": r.get("status")},
               "record": rec}
        out.append(row)
        print(f"  live rank={r.get('rank')} status={r.get('status')} "
              f"| record rank={rec.get('rank')} status={rec.get('status')}"
              f" id={rec.get('id')}", flush=True)

    # compose_answer once on the newest completed ask record
    comp = None
    done = [o for o in out if (o["record"] or {}).get("status") == "completed"]
    rid = (done[0]["record"].get("id") if done else None)
    if rid:
        print(f"compose_answer on record {rid} …", flush=True)
        t0 = time.monotonic()
        resp = cx.request("tools/call", {"name": "compose_answer",
            "arguments": {"workspace": misses[0]["workspace"],
                          "record_id": rid}}, timeout=timeout)
        lat = (time.monotonic() - t0) * 1000
        body = ""
        if resp and "error" not in resp:
            texts = [c.get("text", "") for c in
                     resp.get("result", {}).get("content", [])
                     if c.get("type") == "text"]
            body = "\n".join(texts)
        comp = {"record_id": rid, "latency_ms": round(lat, 1),
                "keys": sorted(json.loads(body).keys()) if body[:1] == "{"
                        else None,
                "preview": body[:300]}
        print(f"  compose_answer: {comp['latency_ms']}ms keys={comp['keys']}")

    cx.stop()
    json.dump({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "timeout": timeout, "misses": out,
               "compose_answer": comp}, open(OUT, "w"), indent=1)
    print(f"\nwrote {OUT}")
    hits = sum(1 for o in out
               if (o["record"] or {}).get("rank"))
    print(f"record-evidence rescue: {hits}/{len(out)}")

if __name__ == "__main__":
    main()
