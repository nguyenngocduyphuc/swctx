#!/usr/bin/env python3
"""Offline eval: does BAAI/bge-m3 fix swctx's dead semantic leg on Vietnamese queries?

Pure measurement — embeds index chunks + vn_queries with bge-m3 (CLS + L2 norm,
FlagEmbedding dense convention) and reports cosine rank of expected-file chunks.

Embeddings cached under /tmp/bgem3_eval/*.npy so re-runs are cheap.
"""
import json
import os
import re
import sqlite3
import sys
import time

import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

CACHE = "/tmp/bgem3_eval"
os.makedirs(CACHE, exist_ok=True)

MODEL_ID = "BAAI/bge-m3"
MAX_LEN = 512
BATCH = 64
P8_FULL_BUDGET_S = 25 * 60  # fall back to stratified if projected past this
STRAT_SAMPLE = 5000

REPO = "/Users/phuongnam/02.AI/NP_AI_macos/tools/swctx"
DBS = {
    "seo": "/Users/phuongnam/.swctx/indexes/6e09ad5e9099/index.db",
    "crm": "/Users/phuongnam/.swctx/indexes/b1617b66c781/index.db",
}
QUERIES_JSON = os.path.join(REPO, "bench/vn_queries.json")


def ws_key(workspace_path: str) -> str:
    return "seo" if "P8_SEO" in workspace_path else "crm"


def load_chunks(db_path):
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = con.execute(
        """SELECT c.id, f.path, c.idx, c.kind, c.symbol, c.content, c.tokens
           FROM chunks c JOIN files f ON f.id = c.file_id ORDER BY c.id"""
    ).fetchall()
    con.close()
    return rows


def query_tokens(query: str):
    return [t for t in re.split(r"[^\w]+", query.lower()) if len(t) >= 3]


def stratified_corpus(chunks, expected_paths, queries):
    """All expected-file chunks + stratified ~STRAT_SAMPLE chunks + chunks of files
    whose path matches any query token."""
    by_id = {c[0]: c for c in chunks}
    picked = set()
    # expected-file chunks
    for c in chunks:
        if c[1] in expected_paths:
            picked.add(c[0])
    # stratified sample: deterministic stride over files
    files = sorted({c[1] for c in chunks})
    stride = max(1, len(chunks) // STRAT_SAMPLE)
    for i, c in enumerate(chunks):
        if i % stride == 0:
            picked.add(c[0])
    # files matching any query token (path match)
    toks = set()
    for q in queries:
        toks.update(query_tokens(q["query"]))
    for c in chunks:
        p = c[1].lower()
        if any(t in p for t in toks):
            picked.add(c[0])
    return [by_id[i] for i in sorted(picked)]


def embed_texts(texts, tok, model, device, label, checkpoint=None):
    """CLS pooling + L2 norm (bge-m3 dense convention). Returns float32 [N,1024]."""
    n = len(texts)
    out = np.empty((n, model.config.hidden_size), dtype=np.float32)
    t0 = time.time()
    for i in range(0, n, BATCH):
        batch = texts[i : i + BATCH]
        enc = tok(
            batch,
            padding=True,
            truncation=True,
            max_length=MAX_LEN,
            return_tensors="pt",
        ).to(device)
        with torch.no_grad():
            hs = model(**enc).last_hidden_state
        cls = hs[:, 0]
        cls = torch.nn.functional.normalize(cls, p=2, dim=1)
        out[i : i + len(batch)] = cls.float().cpu().numpy()
        done = min(i + BATCH, n)
        el = time.time() - t0
        rate = done / el if el else 0
        eta = (n - done) / rate if rate else 0
        print(
            f"  [{label}] {done}/{n} ({rate:.0f}/s, eta {eta:.0f}s)",
            flush=True,
        )
        if checkpoint and done >= checkpoint[0] and checkpoint[1] is None:
            checkpoint[1] = el  # time to embed checkpoint[0] texts
    return out


def main():
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"device={device}", flush=True)
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModel.from_pretrained(MODEL_ID)
    if device == "mps":
        model = model.half()  # fp16 ~2x throughput on MPS; ranking unaffected
    model = model.to(device).eval()
    print(
        f"model loaded: {MODEL_ID}, hidden={model.config.hidden_size}, dtype={next(model.parameters()).dtype}",
        flush=True,
    )

    queries = json.load(open(QUERIES_JSON))["queries"]

    # ---- queries ----
    q_cache = os.path.join(CACHE, "queries_emb.npy")
    if os.path.exists(q_cache):
        q_emb = np.load(q_cache)
        print("queries: loaded from cache")
    else:
        q_emb = embed_texts([q["query"] for q in queries], tok, model, device, "queries")
        np.save(q_cache, q_emb)

    results = []  # per query dict
    corpus_meta = {}

    for ws, db in DBS.items():
        print(f"=== workspace {ws} ===", flush=True)
        chunks = load_chunks(db)
        print(f"total chunks in index: {len(chunks)}", flush=True)
        ws_queries = [q for q in queries if ws_key(q["workspace"]) == ws]
        expected_paths = {q["expected_path"] for q in ws_queries}

        ids_path = os.path.join(CACHE, f"{ws}_ids.npy")
        emb_path = os.path.join(CACHE, f"{ws}_emb.npy")
        meta_path = os.path.join(CACHE, f"{ws}_meta.json")

        if os.path.exists(ids_path) and os.path.exists(emb_path):
            corpus_ids = np.load(ids_path).tolist()
            corpus = np.load(emb_path)
            corpus_meta[ws] = json.load(open(meta_path))
            print(f"corpus: loaded from cache ({len(corpus_ids)} chunks)", flush=True)
        else:
            # benchmark on first 512 chunks to decide full vs stratified
            bench_n = min(512, len(chunks))
            ckpt = [bench_n, None]
            if ws == "seo" and len(chunks) > STRAT_SAMPLE * 2:
                # time a probe batch set first
                probe = [c[5] or "" for c in chunks[:bench_n]]
                t0 = time.time()
                _ = embed_texts(probe, tok, model, device, "seo-probe")
                probe_s = time.time() - t0
                proj = probe_s * len(chunks) / bench_n
                print(
                    f"probe: {bench_n} chunks in {probe_s:.1f}s -> full corpus ~{proj:.0f}s",
                    flush=True,
                )
                if proj > P8_FULL_BUDGET_S:
                    sel = stratified_corpus(chunks, expected_paths, ws_queries)
                    print(f"stratified fallback: {len(sel)} chunks", flush=True)
                else:
                    sel = chunks
            else:
                sel = chunks

            texts = [c[5] or "" for c in sel]
            corpus = embed_texts(texts, tok, model, device, ws)
            corpus_ids = [c[0] for c in sel]
            np.save(ids_path, np.array(corpus_ids, dtype=np.int64))
            np.save(emb_path, corpus)
            corpus_meta[ws] = {
                "total_chunks": len(chunks),
                "embedded_chunks": len(sel),
                "mode": "full" if len(sel) == len(chunks) else "stratified",
            }
            json.dump(corpus_meta[ws], open(meta_path, "w"))

        id_pos = {cid: i for i, cid in enumerate(corpus_ids)}

        # truncation estimate from swctx token counts (chars-based proxy) —
        # measure real tokenizer lengths on a sample
        sample = chunks[: min(500, len(chunks))]
        lens = tok([c[5] or "" for c in sample], truncation=False)["input_ids"]
        over = sum(1 for l in lens if len(l) > MAX_LEN)
        corpus_meta[ws]["trunc_over_512_sample"] = f"{over}/{len(lens)}"

        for qi, q in enumerate(queries):
            if ws_key(q["workspace"]) != ws:
                continue
            exp = q["expected_path"]
            exp_ids = [c[0] for c in chunks if c[1] == exp]
            exp_pos = [id_pos[i] for i in exp_ids if i in id_pos]
            sims = corpus @ q_emb[qi]
            if exp_pos:
                best_pos = max(exp_pos, key=lambda p: sims[p])
                best_sim = float(sims[best_pos])
                rank = int(1 + np.sum(sims > best_sim))
            else:
                best_pos, best_sim, rank = -1, float("nan"), -1
            results.append(
                {
                    "id": q["id"],
                    "ws": ws,
                    "query": q["query"],
                    "expected_path": exp,
                    "n_exp_chunks": len(exp_ids),
                    "n_exp_embedded": len(exp_pos),
                    "best_rank": rank,
                    "best_cos": round(best_sim, 4),
                    "top30": 0 < rank <= 30,
                    "top5": 0 < rank <= 5,
                }
            )
            print(
                f"  {q['id']}: rank={rank} cos={best_sim:.4f} exp_chunks={len(exp_ids)}",
                flush=True,
            )

    json.dump(
        {"results": results, "corpus_meta": corpus_meta},
        open(os.path.join(CACHE, "results.json"), "w"),
        indent=2,
        ensure_ascii=False,
    )
    print("done ->", os.path.join(CACHE, "results.json"))


if __name__ == "__main__":
    main()
