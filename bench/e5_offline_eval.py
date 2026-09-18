#!/usr/bin/env python3
"""Offline eval: does intfloat/multilingual-e5-base fix swctx's dead semantic leg
on Vietnamese queries?

Pure measurement — embeds index chunks + vn_queries with multilingual-e5-base
(e5 convention: "query: " / "passage: " prefixes, mean pooling over non-pad
tokens + L2 norm — the sentence-transformers e5 recipe) and reports cosine rank
of expected-file chunks.

Embeddings cached under /tmp/e5_eval/*.npy so re-runs are cheap.

Usage:
  e5_offline_eval.py                  # full eval on MPS (queries, corpus, ranks;
                                      #   also benches single-query MPS latency)
  e5_offline_eval.py --latency-only --device cpu
                                      # only bench single-query latency on the
                                      #   given device -> /tmp/e5_eval/latency_<dev>.json
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time

import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

CACHE = "/tmp/e5_eval"
os.makedirs(CACHE, exist_ok=True)

MODEL_ID = "intfloat/multilingual-e5-base"
MAX_LEN = 512
BATCH = 64
P8_FULL_BUDGET_S = 25 * 60  # fall back to stratified if projected past this
STRAT_SAMPLE = 5000

REPO = "/Users/phuongnam/02.AI/NP_AI_macos/tools/swctx"
# crm first: small corpus gives quick end-to-end feedback before the long P8 run
DBS = {
    "crm": "/Users/phuongnam/.swctx/indexes/b1617b66c781/index.db",
    "seo": "/Users/phuongnam/.swctx/indexes/6e09ad5e9099/index.db",
}
QUERIES_JSON = os.path.join(REPO, "bench/vn_queries.json")

# e5 model-card prefixes — MANDATORY (e5 without prefixes scores far worse)
Q_PREFIX = "query: "
P_PREFIX = "passage: "

LAT_QUERY = "script tính chấm công của nhân viên từ nhật ký hoạt động"


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


def mean_pool(last_hidden_state, attention_mask):
    """Mask-weighted mean of token embeddings over non-pad positions."""
    mask = attention_mask.unsqueeze(-1).float()
    summed = (last_hidden_state.float() * mask).sum(dim=1)
    return summed / mask.sum(dim=1).clamp(min=1e-9)


def embed_texts(texts, tok, model, device, label, checkpoint=None, quiet=False):
    """Mean pooling + L2 norm (e5 sentence-transformers recipe).
    Returns float32 [N, hidden]. Callers must pre-apply e5 prefixes."""
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
        emb = mean_pool(hs, enc["attention_mask"])
        emb = torch.nn.functional.normalize(emb, p=2, dim=1)
        out[i : i + len(batch)] = emb.float().cpu().numpy()
        done = min(i + BATCH, n)
        el = time.time() - t0
        rate = done / el if el else 0
        eta = (n - done) / rate if rate else 0
        if not quiet:
            print(
                f"  [{label}] {done}/{n} ({rate:.0f}/s, eta {eta:.0f}s)",
                flush=True,
            )
        if checkpoint and done >= checkpoint[0] and checkpoint[1] is None:
            checkpoint[1] = el  # time to embed checkpoint[0] texts
    return out


def bench_latency(tok, model, device, n_warm=2, n_timed=5):
    """Single-query embed latency: n_warm warmup calls then n_timed timed calls.
    Times tokenize + forward + mean-pool + normalize end to end."""
    text = Q_PREFIX + LAT_QUERY
    times = []
    for i in range(n_warm + n_timed):
        t0 = time.perf_counter()
        _ = embed_texts([text], tok, model, device, "lat", quiet=True)
        dt_ms = (time.perf_counter() - t0) * 1000.0
        if i >= n_warm:
            times.append(dt_ms)
    return times


def load_model(device):
    t0 = time.time()
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModel.from_pretrained(MODEL_ID)
    download_s = time.time() - t0
    if device == "mps":
        model = model.half()  # fp16 ~2x throughput on MPS; ranking unaffected
    model = model.to(device).eval()
    print(
        f"model loaded: {MODEL_ID}, hidden={model.config.hidden_size}, "
        f"dtype={next(model.parameters()).dtype}, load+dl {download_s:.1f}s",
        flush=True,
    )
    return tok, model, download_s


def latency_only(device):
    print(f"device={device} (latency-only)", flush=True)
    tok, model, _ = load_model(device)
    times = bench_latency(tok, model, device)
    res = {
        "device": device,
        "dtype": str(next(model.parameters()).dtype),
        "query": LAT_QUERY,
        "warmup": 2,
        "timed_ms": [round(t, 1) for t in times],
        "median_ms": round(float(np.median(times)), 1),
        "min_ms": round(min(times), 1),
        "max_ms": round(max(times), 1),
    }
    path = os.path.join(CACHE, f"latency_{device}.json")
    json.dump(res, open(path, "w"), indent=2)
    print(json.dumps(res, indent=2, ensure_ascii=False), flush=True)
    print("->", path)


def main():
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"device={device}", flush=True)
    wall0 = time.time()
    tok, model, download_s = load_model(device)

    queries = json.load(open(QUERIES_JSON))["queries"]
    stats = {"device": device, "model": MODEL_ID, "download_s": round(download_s, 1)}

    # ---- single-query latency on this device (before corpus hog) ----
    lat = bench_latency(tok, model, device)
    stats[f"latency_{device}_ms"] = {
        "timed": [round(t, 1) for t in lat],
        "median": round(float(np.median(lat)), 1),
        "min": round(min(lat), 1),
        "max": round(max(lat), 1),
    }
    json.dump(
        stats[f"latency_{device}_ms"],
        open(os.path.join(CACHE, f"latency_{device}.json"), "w"),
        indent=2,
    )
    print(
        f"single-query latency [{device}]: median {np.median(lat):.1f}ms "
        f"(min {min(lat):.1f}, max {max(lat):.1f})",
        flush=True,
    )

    # ---- queries ----
    q_cache = os.path.join(CACHE, "queries_emb.npy")
    if os.path.exists(q_cache):
        q_emb = np.load(q_cache)
        print("queries: loaded from cache")
    else:
        t0 = time.time()
        q_emb = embed_texts(
            [Q_PREFIX + q["query"] for q in queries], tok, model, device, "queries"
        )
        stats["queries_embed_s"] = round(time.time() - t0, 1)
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
            sel = chunks
            if ws == "seo" and len(chunks) > STRAT_SAMPLE * 2:
                # benchmark on first 512 chunks to decide full vs stratified
                bench_n = min(512, len(chunks))
                probe = [P_PREFIX + (c[5] or "") for c in chunks[:bench_n]]
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

            texts = [P_PREFIX + (c[5] or "") for c in sel]
            t0 = time.time()
            corpus = embed_texts(texts, tok, model, device, ws)
            stats[f"{ws}_embed_s"] = round(time.time() - t0, 1)
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
        lens = tok(
            [P_PREFIX + (c[5] or "") for c in sample], truncation=False
        )["input_ids"]
        over = sum(1 for l in lens if len(l) > MAX_LEN)
        corpus_meta[ws]["trunc_over_512_sample"] = f"{over}/{len(lens)}"
        json.dump(corpus_meta[ws], open(meta_path, "w"))

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

    stats["wall_total_s"] = round(time.time() - wall0, 1)
    json.dump(
        {"results": results, "corpus_meta": corpus_meta, "stats": stats},
        open(os.path.join(CACHE, "results.json"), "w"),
        indent=2,
        ensure_ascii=False,
    )
    json.dump(stats, open(os.path.join(CACHE, "run_stats.json"), "w"), indent=2)
    print("done ->", os.path.join(CACHE, "results.json"))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--latency-only", action="store_true")
    ap.add_argument("--device", choices=["cpu", "mps"], default=None)
    args = ap.parse_args()
    if args.latency_only:
        dev = args.device or ("mps" if torch.backends.mps.is_available() else "cpu")
        latency_only(dev)
    else:
        main()
