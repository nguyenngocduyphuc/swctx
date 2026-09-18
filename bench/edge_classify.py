#!/usr/bin/env python3
"""edge_classify.py — auto-classify sampled ctxe-only edges (site-M).

Reads /tmp/edge_sample.json (from edge_audit.py), re-checks src/dst chunk
content from the ctxe DB, and emits a first-pass verdict per edge:
  phantom(no-src-ref) | phantom(bad-dst) | type_ref | real
Borderline verdicts are reviewed manually in edge-audit.md.
"""

import json
import re
import sqlite3
from collections import Counter

DB = "/Users/phuongnam/.ctxe/indexes/a4fc8115d18a/index.db"


def load_chunks():
    con = sqlite3.connect(DB)
    out = {}
    for cid, sl, el, sym, c in con.execute(
            "SELECT id,start_line,end_line,symbol_name,content FROM chunks"):
        out[cid] = {"sl": sl, "el": el, "sym": sym, "content": c}
    con.close()
    return out


CMAP = load_chunks()


def dst_defines(a):
    """Does the dst chunk plausibly DECLARE target_name (as its primary
    symbol or as a member declaration inside)?"""
    name = a["target_name"]
    dst = CMAP.get(a["dst_chunk_id"], {})
    if dst.get("sym") == name:
        return True
    c = dst.get("content", "")
    pat = re.compile(
        r"(\bfunc\s+|\bvar\s+|\blet\s+|\bcase\s+|\bstatic\s+\w+\s+|"
        r"\btypealias\s+|\bstruct\s+|\bclass\s+|\benum\s+|\bdef\s+|"
        r"\bconst\s+|\blet\s+|\bvar\s+|\bpublic\s+\w+\s+)"
        + re.escape(name) + r"\b|\b" + re.escape(name) + r"\s*:")
    return bool(pat.search(c))


def src_mentions(a):
    return a["target_name"] in CMAP.get(
        a["src_chunk_id"], {}).get("content", "")


def main():
    d = json.load(open("/tmp/edge_sample.json"))
    sample = d["sample"]
    out = []
    for i, a in enumerate(sample):
        insrc = src_mentions(a)
        ddef = dst_defines(a)
        if not insrc:
            verdict = "phantom(no-src-ref)"
        elif not ddef:
            verdict = "phantom(bad-dst)"
        elif a["edge_type"] in ("uses_type", "field_of"):
            verdict = "type_ref"
        else:
            verdict = "real"
        out.append({"i": i, "verdict": verdict, "insrc": insrc,
                    "ddef": ddef, **{k: a[k] for k in (
                        "edge_type", "target_name", "confidence",
                        "src_path", "dst_path", "src_lines",
                        "dst_lines", "dst_symbol")}})
    print(Counter(o["verdict"] for o in out))
    json.dump(out, open("/tmp/edge_verdicts.json", "w"), indent=1)
    for o in out:
        print(f"[{o['i']:2}] {o['verdict']:20} {o['edge_type']:9} "
              f"{o['target_name']:<24} conf={o['confidence']} "
              f"src={o['src_path']}:{o['src_lines'][0]} -> "
              f"{o['dst_path']}:{o['dst_lines'][0]} sym={o['dst_symbol']}")


if __name__ == "__main__":
    main()
