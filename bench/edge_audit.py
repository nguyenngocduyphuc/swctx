#!/usr/bin/env python3
"""edge_audit.py — extract ctxe resolved edges absent from swctx (site-M).

"Absent" = no swctx edge from the SAME source file to the same dst_name
(loose match; kind ignored). Dumps a stratified sample with src/dst chunk
context for manual classification into real / phantom / type_ref.

Usage: python3 bench/edge_audit.py [--db-suffix a4fc8115d18a] [--n 100]
"""

import argparse
import json
import random
import sqlite3

SW = "/Users/phuongnam/.swctx/indexes/{k}/index.db"
CX = "/Users/phuongnam/.ctxe/indexes/{k}/index.db"


def swctx_edges(db):
    con = sqlite3.connect(db)
    rows = con.execute(
        """SELECT fs.path, e.dst_name, e.kind, e.dst_chunk, fd.path
           FROM edges e
           JOIN chunks sc ON sc.id = e.src_chunk
           JOIN files fs ON fs.id = sc.file_id
           LEFT JOIN chunks dc ON dc.id = e.dst_chunk
           LEFT JOIN files fd ON fd.id = dc.file_id""").fetchall()
    con.close()
    return rows


def ctxe_edges(db):
    con = sqlite3.connect(db)
    rows = con.execute(
        """SELECT e.id, fs.path, e.target_name, e.edge_type, e.confidence,
                  e.source_chunk_id, e.target_chunk_id, fd.path
           FROM symbol_edges e
           JOIN chunks sc ON sc.id = e.source_chunk_id
           JOIN files fs ON fs.id = sc.file_id
           JOIN chunks dc ON dc.id = e.target_chunk_id
           JOIN files fd ON fd.id = dc.file_id
           WHERE e.target_chunk_id IS NOT NULL""").fetchall()
    con.close()
    return rows


def chunk_map(db, id_col="id"):
    con = sqlite3.connect(db)
    out = {}
    for cid, sl, el, sym, content in con.execute(
            "SELECT id, start_line, end_line, symbol_name, content FROM chunks"):
        out[cid] = {"start_line": sl, "end_line": el,
                    "symbol": sym, "content": content}
    con.close()
    return out


def swctx_chunk_map(db):
    con = sqlite3.connect(db)
    out = {}
    for cid, sl, el, sym, content in con.execute(
            "SELECT id, start_line, end_line, symbol, content FROM chunks"):
        out[cid] = {"start_line": sl, "end_line": el,
                    "symbol": sym, "content": content}
    con.close()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", default="a4fc8115d18a")
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="/tmp/edge_sample.json")
    args = ap.parse_args()

    sw_rows = swctx_edges(SW.format(k=args.key))
    cx_rows = ctxe_edges(CX.format(k=args.key))

    sw_pairs = {(p, n) for (p, n, k, dc, dp) in sw_rows}
    sw_pairs_resolved = {(p, n) for (p, n, k, dc, dp) in sw_rows
                         if dc is not None}
    sw_triples = {(p, n, dp) for (p, n, k, dc, dp) in sw_rows
                  if dc is not None}

    absent = []
    for (eid, spath, tname, etype, conf, scid, dcid, dpath) in cx_rows:
        if (spath, tname) in sw_pairs:
            continue  # swctx has an edge from this file to this name
        absent.append({"id": eid, "src_path": spath, "target_name": tname,
                       "edge_type": etype, "confidence": conf,
                       "src_chunk_id": scid, "dst_chunk_id": dcid,
                       "dst_path": dpath,
                       # did swctx even emit the (unresolved) edge name?
                       "swctx_has_any_edge_to_name":
                       any(n == tname for (p, n) in sw_pairs if p == spath),
                       })

    print(f"swctx edges: {len(sw_rows)} "
          f"(resolved pairs {len(sw_pairs_resolved)})")
    print(f"ctxe resolved edges: {len(cx_rows)}")
    print(f"ctxe resolved edges absent from swctx (src_file+name): "
          f"{len(absent)}")
    by_type = {}
    for a in absent:
        by_type[a["edge_type"]] = by_type.get(a["edge_type"], 0) + 1
    print("absent by edge_type:", by_type)

    # stratified sample ~n proportional to type counts
    rng = random.Random(args.seed)
    sample = []
    for etype, cnt in sorted(by_type.items(), key=lambda kv: -kv[1]):
        pool = [a for a in absent if a["edge_type"] == etype]
        take = max(3, round(args.n * cnt / len(absent))) if pool else 0
        take = min(take, len(pool))
        sample += rng.sample(pool, take)
    rng.shuffle(sample)
    sample = sample[:args.n]

    cm = chunk_map(CX.format(k=args.key))
    for a in sample:
        sc = cm.get(a["src_chunk_id"], {})
        dc = cm.get(a["dst_chunk_id"], {})
        a["src_lines"] = [sc.get("start_line"), sc.get("end_line")]
        a["dst_lines"] = [dc.get("start_line"), dc.get("end_line")]
        a["dst_symbol"] = dc.get("symbol")
        a["src_chunk"] = sc.get("content", "")[:4000]
        a["dst_chunk"] = dc.get("content", "")[:4000]
        a["name_in_src"] = a["target_name"] in a["src_chunk"]
        a["name_in_dst"] = a["target_name"] in a["dst_chunk"]

    json.dump({"absent_total": len(absent), "by_type": by_type,
               "sample": sample}, open(args.out, "w"), indent=1)
    print(f"sampled {len(sample)} -> {args.out}")


if __name__ == "__main__":
    main()
