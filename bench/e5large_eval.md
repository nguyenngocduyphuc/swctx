# multilingual-e5-large-instruct offline eval — Vietnamese semantic-leg probe

- Model: `intfloat/multilingual-e5-large-instruct` (XLM-RoBERTa-large, 24L, 1024-dim, ~560M; mean pooling over non-pad tokens + L2 norm; instruct convention per model card — queries get `Instruct: {task}\nQuery: {query}`, documents get NO prefix)
- Instruction used: `Given a code search query, retrieve relevant code and documentation chunks` (query-side only)
- Device: mps, dtype fp16, batch 64, max_len 512 (truncated)
- Snapshot size on disk: ~1.1 GB (hub `model.safetensors` is already fp16)
- Embeddings cached at `/tmp/e5large_eval/` (seo_ids/seo_emb 31302x1024 + seo_full_ids/seo_full_emb 32678x1024, crm_ids/crm_emb 1151x1024, queries_emb 22x1024; full-corpus rescore in `results_fullcorpus.json`)
- Wall clock: ~32.5 min total (download+load 51s; embed seo 1816s @ ~17 chunks/s + missing-1376 patch ~68s, crm 56s, queries 0.1s; scoring <1s) — ~3.5× slower corpus throughput than e5-base (~17 vs ~63 chunks/s), about same as bge-m3 (~18/s)

## Single-query embed latency (PyTorch lower bound; 2 warmup + 5 timed)

| device | dtype | median | min | max |
|---|---|---|---|---|
| mps | fp16 | **21.6 ms** | 21.3 | 21.9 |
| cpu | fp32 | **111.1 ms** | 107.4 | 116.1 |

vs e5-base 10.0/48.5 ms and bge-m3 ~410 ms/embed CPU → e5-large-instruct is ~3.7× faster CPU-side than bge-m3 despite the same 24L/1024-dim XLM-R-large backbone, and clears the 150 ms query gate in raw PyTorch fp32 — but with only ~26% headroom (e5-base had ~3×). Query text: `Instruct: ...\nQuery: script tính chấm công của nhân viên từ nhật ký hoạt động` (tokenize + forward + pool + normalize, end to end).

## Corpus

- `seo`: 32678/32678 chunks embedded (31302 via stratified fallback after probe projected ~1600s > 1500s budget — the "script" query token matches `scripts/` paths so the fallback covered 95.8%; remaining 1376 chunks embedded post-hoc and ranks re-scored against the FULL corpus — numbers below are full-corpus). Chunks >512 tokens in 500-sample: 17/500
- `crm`: 1151/1151 chunks embedded (full); chunks >512 tokens in 500-sample: 161/500

## Per-query cosine rank of best expected-file chunk

| id | lang/tags | expected_path | exp chunks | best cos | rank | top-30 | top-5 |
|---|---|---|---|---|---|---|---|
| seo-01 | vi/vn_to_vn | `scripts/p8_canonical_check.py` | 4 | 0.8939 | 95 | — | — |
| seo-02 | vi/vn_to_vn | `scripts/p8_link_health.py` | 6 | 0.8934 | 358 | — | — |
| seo-03 | vi/vn_to_vn | `scripts/p8_utm_builder.py` | 2 | 0.8693 | 363 | — | — |
| seo-04 **(miss)** | vi/vn_to_en | `scripts/p8_image_worker.py` | 19 | 0.8724 | 1065 | — | — |
| seo-05 **(miss)** | vi/vn_to_en | `factory/sitectl.py` | 7 | 0.8802 | 94 | — | — |
| seo-06 **(miss)** | vi/vn_to_vn | `docs-fleet/doi-ngu.md` | 1 | 0.9113 | 1 | ✅ | ✅ |
| seo-07 | vi/vn_to_vn | `WORKFLOW.md` | 19 | 0.9048 | 34 | — | — |
| seo-08 | en/en_control | `scripts/p8_fix_featured_images.py` | 11 | 0.8861 | 8 | ✅ | — |
| seo-09 **(miss)** | vi/vn_to_en | `scripts/p8_brain.py` | 10 | 0.8948 | 315 | — | — |
| seo-10 **(miss)** | vi/vn_to_en | `scripts/ghost_link_builder_apply.py` | 3 | 0.9012 | 25 | ✅ | — |
| seo-11 | vi/vn_to_vn | `docs-fleet/ke-hoach.md` | 10 | 0.8968 | 17 | ✅ | — |
| crm-01 | vi/vn_to_vn | `crm-nam-pham/09-build/cham_cong.py` | 12 | 0.8923 | 5 | ✅ | — |
| crm-02 | vi/vn_to_vn | `crm-nam-pham/09-build/so_tay.py` | 20 | 0.8873 | 43 | — | — |
| crm-03 | vi/vn_to_vn | `crm-nam-pham/09-build/tin_lead.py` | 5 | 0.9009 | 2 | ✅ | ✅ |
| crm-04 **(miss)** | vi/vn_to_vn | `crm-nam-pham/09-build/dong_vong.py` | 6 | 0.9009 | 8 | ✅ | — |
| crm-05 | vi/vn_to_vn | `crm-nam-pham/functions/_middleware.js` | 28 | 0.9142 | 1 | ✅ | ✅ |
| crm-06 | vi/vn_to_vn | `crm-nam-pham/07-docs/DANG_NHAP.md` | 8 | 0.9430 | 1 | ✅ | ✅ |
| crm-07 | vi/vn_to_vn | `crm-nam-pham/09-build/nap_serp.py` | 10 | 0.9085 | 1 | ✅ | ✅ |
| crm-08 **(miss)** | en/en_control | `crm-nam-pham/09-build/ghi_so.py` | 2 | 0.8228 | 36 | — | — |
| crm-09 | vi/vn_to_vn | `crm-nam-pham/09-build/kiem_he_thiet_ke.py` | 1 | 0.9300 | 1 | ✅ | ✅ |
| crm-10 **(miss)** | en/en_control | `crm-nam-pham/09-build/vaid_issues.py` | 5 | 0.8601 | 4 | ✅ | ✅ |
| crm-11 **(miss)** | vi/vn_to_en | `crm-nam-pham/09-build/log_activity_live.py` | 3 | 0.8797 | 17 | ✅ | — |

## Summary

- top-30 pool entry: **13/22** queries; top-5: **7/22**
- Of the 9 current misses (seo-04, seo-05, seo-06, seo-09, seo-10, crm-04, crm-08, crm-10, crm-11): **5 enter top-30** — seo-06 (rank 1), seo-10 (25), crm-04 (8), crm-10 (4), crm-11 (17). Gate was ≥3 → **PASS**.
- **Regressions under pure dense:** 5 currently-passing queries do NOT enter top-30 — seo-01 (95), seo-02 (358), seo-03 (363), seo-07 (34), crm-02 (43). Gate was <5 → **FAIL** (exactly at the boundary).
- Net pool entry vs current 13/22 hits: **13/22 — zero net gain**. The model rescues 5 misses but evicts 5 different current hits; improvement is churn, not lift.

## Miss-by-miss vs e5-base and bge-m3 (bge-m3 ran v1 set — 16 queries; seo-09/10, crm-09/10/11 not in it)

| miss | e5-lg-instruct rank | e5-base rank | bge-m3 rank | verdict |
|---|---|---|---|---|
| seo-04 | 1065 | 2196 | 11 ✅ | all fail but bge-m3 |
| seo-05 | 94 | 101 | 1 ✅ | all fail but bge-m3 |
| seo-06 | **1 ✅** | 39 | 1 ✅ | **rescued** |
| seo-09 | 315 | 513 | n/a | fails |
| seo-10 | **25 ✅** | 143 | n/a | **rescued** |
| crm-04 | **8 ✅** | 41 | 5 ✅ | **rescued** |
| crm-08 | 36 | 236 | 153 | near-miss, all fail |
| crm-10 | **4 ✅** | 10 ✅ | n/a | **rescued** (e5-base also had it) |
| crm-11 | **17 ✅** | 118 | n/a | **rescued** |

## Latency class check

Same architecture class as bge-m3 (XLM-R-large, 24 layers, 1024-dim) but measured single-query latency is far lower: **111.1 ms CPU fp32** vs bge-m3's ~410 ms and **21.6 ms MPS fp16**. It does NOT fall into bge-m3's latency trap at the PyTorch level — it clears the 150 ms gate, though with ~26% headroom vs e5-base's ~3×. (bge-m3's 410 ms figure came from a different bench context; treat the cross-model CPU comparison as indicative, not identical-harness.)

## Verdict: **NO-GO**

Rescue arm passes clearly (5/9 ≥ 3 — the instruct prefix is visibly stronger than e5-base: crm-04 41→8, crm-11 118→17, seo-06 39→1, seo-10 143→25) and latency clears the gate (111 ms CPU / 21.6 ms MPS), but the regression arm fails at exactly 5 evicted current hits (<5 required). The model trades misses for hits — 13/22 pool entries either way — so it is not a drop-in win for the semantic leg. Notably strong on the CRM corpus (10/11 top-30, seven at rank ≤2) but bleeds on the large English-heavy P8 corpus where vn_to_en remains the hard case (2/6 vn_to_en probes pass: seo-10, crm-11; seo-04 at 1065, seo-09 315, seo-05 94 still fail).

## Caveats

- e5-instruct cosine distribution is the most compressed yet — all best-expected-chunk cosines sit in 0.82–0.94 (vs e5-base 0.78–0.89, bge-m3 0.49–0.69). Model-card FAQ confirms this is expected (low-temperature InfoNCE); relative order still ranks, but boundary ranks are noise-sensitive.
- seo ranks re-scored against the FULL 32,678-chunk corpus after embedding the 1,376 chunks the stratified fallback skipped; no boundary flips vs the 31,302-chunk subset (seo-10 held 25, seo-07 stayed out at 34). Stratified-subset ranks preserved in `results_fullcorpus.json` as `best_rank_stratified_31302`.
- Regressions are not the same set as e5-base's (seo-01/03/07/11/crm-02 under e5-base): e5-large-instruct fixes seo-11 (38→17) but adds seo-02 (16→358) — churn is query-specific, not systematic.
- Query instruction was fixed for all 22 queries (`Given a code search query, retrieve relevant code and documentation chunks`); per-query instruction tuning could shift individual ranks.
- Chunks truncated at 512 tokens (seo: 17/500 sampled >512; crm: 161/500 >512 — VN docstring-heavy chunks tokenize long). Same cap as prior runs.
- fp16 on MPS for all embeddings including queries. Rank effect negligible. Hub safetensors are already fp16; CPU run upcasts to fp32 automatically.
- Rank measured against ALL corpus chunks including same-file siblings — pool-entry proxy for hybrid retrieval.
- CRM corpus is small (1,151 chunks vs 32,678 on P8) — top-N comparisons across workspaces are not apples-to-apples; the model looks markedly better on crm than on seo.
- Corpus throughput ~17 chunks/s MPS fp16 — bulk index embed of the 32.7k-chunk P8 workspace takes ~30 min; a CoreML/ANE conversion would be needed for interactive reindex budgets.
