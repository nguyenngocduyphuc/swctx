#!/usr/bin/env python3
"""ask_medium_misses.py — ctxe ask_context at effort=medium over all
current swctx-search misses. Full-credit eval: medium = up to 6 planner
rounds (vs min=3 in the capped probe). Harvests both live wire paths and
the free durable-record evidence.

Usage: python3 ask_medium_misses.py [--effort medium] [--timeout 120]
"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import MCPSession                     # noqa: E402
from engine_ab import (cx_record_evidence,       # noqa: E402
                       collect_file_paths, rank_of)

RESULTS = os.path.join(HERE, "engine_ab_results.json")
OUT = os.path.join(HERE, "ask_medium_results.json")


def cx_ask_effort(session, ws, query, expected, limit, timeout, effort):
    t0 = time.monotonic()
    resp = session.request(
        "tools/call",
        {"name": "ask_context",
         "arguments": {"workspace": ws, "query": query,
                       "compose": False, "effort": effort}},
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
            return {"rank": 0, "paths": [], "latency_ms": round(lat, 1),
                    "status": "error", "error": raw[:300]}, None
        return {"rank": rank_of(expected, collect_file_paths(payload)),
                "paths": collect_file_paths(payload)[:limit],
                "latency_ms": round(lat, 1), "status": "ok"}, \
               payload.get("record_id")
    if resp is not None:
        err = f"rpc {resp['error'].get('code')}: {resp['error'].get('message')}"
        return {"rank": 0, "paths": [], "latency_ms": round(lat, 1),
                "status": "error", "error": err}, None
    return {"rank": 0, "paths": [], "latency_ms": round(lat, 1),
            "status": "timeout"}, None


def main():
    effort = "medium"
    timeout = 120
    if "--effort" in sys.argv:
        effort = sys.argv[sys.argv.index("--effort") + 1]
    if "--timeout" in sys.argv:
        timeout = int(sys.argv[sys.argv.index("--timeout") + 1])

    res = json.load(open(RESULTS))
    misses = [q for q in res["queries"]
              if not (q["results"].get("swctx:search") or {}).get("rank")]
    print(f"{len(misses)} swctx misses: {[q['id'] for q in misses]}")

    cx = MCPSession("ctxe", ["ctxe", "mcp"], timeout=timeout)
    cx.start()
    out = []
    for q in misses:
        ws, query, exp = q["workspace"], q["query"], q["expected_path"]
        print(f"ask {q['id']} (effort={effort}) …", flush=True)
        live, rid = cx_ask_effort(cx, ws, query, exp, 5, timeout, effort)
        rec = cx_record_evidence(cx, ws, query, exp, 5, record_id=rid)
        out.append({"id": q["id"], "workspace": ws, "query": query,
                    "expected": exp, "live": live, "record": rec})
        print(f"  live rank={live['rank']} status={live['status']} "
              f"lat={live['latency_ms']}ms | record rank={rec.get('rank')} "
              f"status={rec.get('status')} id={rec.get('id')}", flush=True)

    hits_live = sum(1 for o in out if o["live"]["rank"])
    hits_rec = sum(1 for o in out if (o["record"] or {}).get("rank"))
    summary = {"effort": effort, "n": len(out),
               "live_hits": hits_live, "record_hits": hits_rec}
    print(json.dumps(summary))
    json.dump({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "effort": effort, "summary": summary, "misses": out},
              open(OUT, "w"), indent=1, ensure_ascii=False)
    cx.stop()


if __name__ == "__main__":
    main()
