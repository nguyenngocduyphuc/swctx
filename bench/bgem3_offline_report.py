#!/usr/bin/env python3
"""Render /tmp/bgem3_eval/results.json into bench/bgem3_offline_eval.md."""
import json
import os
import time

CACHE = "/tmp/bgem3_eval"
REPO = "/Users/phuongnam/02.AI/NP_AI_macos/tools/swctx"
MISSES = ["seo-04", "seo-05", "seo-06", "crm-04", "crm-08"]

data = json.load(open(os.path.join(CACHE, "results.json")))
results = data["results"]
meta = data["corpus_meta"]
stats = json.load(open(os.path.join(CACHE, "run_stats.json"))) if os.path.exists(
    os.path.join(CACHE, "run_stats.json")) else {}

lines = []
lines.append("# bge-m3 offline eval — Vietnamese semantic-leg probe")
lines.append("")
lines.append(f"- Model: `BAAI/bge-m3` (XLM-RoBERTa-large, 1024-dim dense, CLS + L2 norm — FlagEmbedding convention)")
lines.append(f"- Device: {stats.get('device','mps')}, dtype {stats.get('dtype','fp16')}, batch {stats.get('batch',64)}, max_len 512 (truncated)")
lines.append(f"- Snapshot size on disk: ~4.3 GB (dense `pytorch_model.bin` ≈ 2.27 GB; also ships onnx/sparse/colbert heads)")
lines.append(f"- Embeddings cached at `/tmp/bgem3_eval/` ({stats.get('cache_files','ids/emb npy per workspace + queries')})")
lines.append(f"- Wall clock: download {stats.get('download_s','~53')}s + embed {stats.get('embed_s','?')}s + scoring <1s")
lines.append("")
lines.append("## Corpus")
lines.append("")
for ws, m in meta.items():
    lines.append(
        f"- `{ws}`: {m['embedded_chunks']}/{m['total_chunks']} chunks embedded "
        f"({m['mode']}); chunks >512 tokens in 500-sample: {m.get('trunc_over_512_sample','?')}"
    )
lines.append("")
lines.append("## Per-query cosine rank of best expected-file chunk")
lines.append("")
lines.append("| id | lang/tags | expected_path | exp chunks | best cos | rank | top-30 | top-5 |")
lines.append("|---|---|---|---|---|---|---|---|")

import json as _j
queries = {q["id"]: q for q in _j.load(open(os.path.join(REPO, "bench/vn_queries.json")))["queries"]}
rescued = []
for r in results:
    q = queries[r["id"]]
    tags = ",".join(q.get("tags", []))
    miss = " **(miss)**" if r["id"] in MISSES else ""
    lines.append(
        f"| {r['id']}{miss} | {q['lang']}/{tags} | `{r['expected_path']}` | "
        f"{r['n_exp_chunks']} | {r['best_cos']:.4f} | {r['best_rank']} | "
        f"{'✅' if r['top30'] else '—'} | {'✅' if r['top5'] else '—'} |"
    )
    if r["id"] in MISSES and r["top30"]:
        rescued.append(r["id"])

n_top30 = sum(1 for r in results if r["top30"])
n_top5 = sum(1 for r in results if r["top5"])
lines.append("")
lines.append("## Summary")
lines.append("")
lines.append(f"- top-30 pool entry: **{n_top30}/16** queries; top-5: **{n_top5}/16**")
lines.append(f"- Of the 5 current misses (seo-04, seo-05, seo-06, crm-04, crm-08): "
             f"**{len(rescued)} enter top-30** {('(' + ', '.join(rescued) + ')') if rescued else ''}")
go = len(rescued) >= 2
lines.append("")
lines.append(f"## Verdict: **{'GO' if go else 'NO-GO'}**")
lines.append("")
if go:
    lines.append(f"≥2 misses rescued → proceed to CoreML conversion spike for bge-m3 dense leg.")
else:
    lines.append("Fewer than 2 misses enter top-30 by pure cosine — bge-m3 dense alone does not fix the VN semantic leg on this corpus.")
lines.append("")
lines.append("## Caveats")
lines.append("")
lines.append("- Dense CLS only — bge-m3's sparse/Multi-Vec (ColBERT-style) heads unused; hybrid would likely do better.")
lines.append("- Chunks truncated at 512 tokens (see per-workspace truncation stats); long functions lose their tails.")
lines.append("- fp16 on MPS for corpus embeddings; queries fp32. Rank effect negligible.")
lines.append("- No instruction prefix on queries (bge-m3 does not use one for short queries — matches FlagEmbedding default).")
lines.append("- Rank measured against ALL corpus chunks including same-file siblings — pool-entry proxy for hybrid retrieval.")
open(os.path.join(REPO, "bench/bgem3_offline_eval.md"), "w").write("\n".join(lines) + "\n")
print("wrote", os.path.join(REPO, "bench/bgem3_offline_eval.md"))
print("\n".join(lines))
