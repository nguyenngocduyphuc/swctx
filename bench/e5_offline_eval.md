# multilingual-e5-base offline eval — Vietnamese semantic-leg probe

- Model: `intfloat/multilingual-e5-base` (XLM-RoBERTa-base, 768-dim, mean pooling over non-pad tokens + L2 norm; e5 prefixes `query: ` / `passage: ` — model-card mandatory)
- Device: mps, dtype fp16, batch 64, max_len 512 (truncated)
- Snapshot size on disk: ~1.1 GB (`model.safetensors` ≈ 1.12 GB)
- Embeddings cached at `/tmp/e5_eval/` (seo_ids/seo_emb (32678x768), crm_ids/crm_emb (1151x768), queries_emb (22x768))
- Wall clock: ~9.6 min total (download 26s; embed seo 522s @ ~63 chunks/s, crm 17s, queries 0.2s; scoring <1s) — ~4× faster corpus throughput than bge-m3 (~63 vs ~18 chunks/s)

## Single-query embed latency (PyTorch lower bound; 2 warmup + 5 timed)

| device | dtype | median | min | max |
|---|---|---|---|---|
| mps | fp16 | **10.0 ms** | 9.6 | 10.9 |
| cpu | fp32 | **48.5 ms** | 47.2 | 50.3 |

vs bge-m3 ~410 ms/embed CPU → e5-base is ~8× faster CPU-side and clears the 150 ms query gate with ~3× headroom even in raw PyTorch fp32; CoreML conversion would likely improve further. Query text: `query: script tính chấm công của nhân viên từ nhật ký hoạt động` (tokenize + forward + pool + normalize, end to end).

## Corpus

- `seo`: 32678/32678 chunks embedded (full); chunks >512 tokens in 500-sample: 17/500
- `crm`: 1151/1151 chunks embedded (full); chunks >512 tokens in 500-sample: 161/500

## Per-query cosine rank of best expected-file chunk

| id | lang/tags | expected_path | exp chunks | best cos | rank | top-30 | top-5 |
|---|---|---|---|---|---|---|---|
| seo-01 | vi/vn_to_vn | `scripts/p8_canonical_check.py` | 4 | 0.8461 | 352 | — | — |
| seo-02 | vi/vn_to_vn | `scripts/p8_link_health.py` | 6 | 0.8696 | 16 | ✅ | — |
| seo-03 | vi/vn_to_vn | `scripts/p8_utm_builder.py` | 2 | 0.8454 | 258 | — | — |
| seo-04 **(miss)** | vi/vn_to_en | `scripts/p8_image_worker.py` | 19 | 0.8248 | 2196 | — | — |
| seo-05 **(miss)** | vi/vn_to_en | `factory/sitectl.py` | 7 | 0.8454 | 101 | — | — |
| seo-06 **(miss)** | vi/vn_to_vn | `docs-fleet/doi-ngu.md` | 1 | 0.8373 | 39 | — | — |
| seo-07 | vi/vn_to_vn | `WORKFLOW.md` | 19 | 0.8659 | 51 | — | — |
| seo-08 | en/en_control | `scripts/p8_fix_featured_images.py` | 11 | 0.8569 | 3 | ✅ | ✅ |
| seo-09 **(miss)** | vi/vn_to_en | `scripts/p8_brain.py` | 10 | 0.8454 | 513 | — | — |
| seo-10 **(miss)** | vi/vn_to_en | `scripts/ghost_link_builder_apply.py` | 3 | 0.8487 | 143 | — | — |
| seo-11 | vi/vn_to_vn | `docs-fleet/ke-hoach.md` | 10 | 0.8476 | 38 | — | — |
| crm-01 | vi/vn_to_vn | `crm-nam-pham/09-build/cham_cong.py` | 12 | 0.8434 | 9 | ✅ | — |
| crm-02 | vi/vn_to_vn | `crm-nam-pham/09-build/so_tay.py` | 20 | 0.8415 | 54 | — | — |
| crm-03 | vi/vn_to_vn | `crm-nam-pham/09-build/tin_lead.py` | 5 | 0.8562 | 2 | ✅ | ✅ |
| crm-04 **(miss)** | vi/vn_to_vn | `crm-nam-pham/09-build/dong_vong.py` | 6 | 0.8343 | 41 | — | — |
| crm-05 | vi/vn_to_vn | `crm-nam-pham/functions/_middleware.js` | 28 | 0.8663 | 2 | ✅ | ✅ |
| crm-06 | vi/vn_to_vn | `crm-nam-pham/07-docs/DANG_NHAP.md` | 8 | 0.8949 | 1 | ✅ | ✅ |
| crm-07 | vi/vn_to_vn | `crm-nam-pham/09-build/nap_serp.py` | 10 | 0.8580 | 2 | ✅ | ✅ |
| crm-08 **(miss)** | en/en_control | `crm-nam-pham/09-build/ghi_so.py` | 2 | 0.7803 | 236 | — | — |
| crm-09 | vi/vn_to_vn | `crm-nam-pham/09-build/kiem_he_thiet_ke.py` | 1 | 0.8653 | 1 | ✅ | ✅ |
| crm-10 **(miss)** | en/en_control | `crm-nam-pham/09-build/vaid_issues.py` | 5 | 0.8252 | 10 | ✅ | — |
| crm-11 **(miss)** | vi/vn_to_en | `crm-nam-pham/09-build/log_activity_live.py` | 3 | 0.8245 | 118 | — | — |

## Summary

- top-30 pool entry: **9/22** queries; top-5: **6/22**
- Of the 9 current misses (seo-04, seo-05, seo-06, crm-04, crm-08, seo-09, seo-10, crm-10, crm-11): **1 enters top-30** — crm-10 (rank 10). Gate was ≥2 → **FAIL**.
- **Regressions under pure dense:** 5 currently-passing queries do NOT enter top-30 — seo-01 (rank 352), seo-03 (258), seo-07 (51), seo-11 (38), crm-02 (54).

## Miss-by-miss vs bge-m3 (bge-m3 ran v1 set — 16 queries; seo-09/10, crm-09/10/11 not in it)

| miss | e5-base rank | bge-m3 rank | verdict |
|---|---|---|---|
| seo-04 | 2196 | 11 ✅ | e5 much worse |
| seo-05 | 101 | 1 ✅ | e5 much worse |
| seo-06 | 39 | 1 ✅ | e5 worse (near-miss) |
| crm-04 | 41 | 5 ✅ | e5 worse (near-miss) |
| crm-08 | 236 | 153 | both fail |
| seo-09 | 513 | n/a | e5 fails |
| seo-10 | 143 | n/a | e5 fails |
| crm-10 | 10 ✅ | n/a | **e5 rescues** |
| crm-11 | 118 | n/a | e5 fails |

## Verdict: **NO-GO**

1/9 misses rescued (need ≥2) and 5 regressions on currently-passing queries — retrieval quality on the VN semantic leg is markedly worse than bge-m3 despite the far better latency profile (10 ms MPS / 48.5 ms CPU, ~8× faster than bge-m3 CPU and well under the 150 ms gate). e5-base solves the latency problem but not the recall problem.

## Caveats

- e5 cosine distribution is compressed (all best-expected-chunk cosines sit in a narrow 0.78–0.89 band vs bge-m3's 0.49–0.69 spread) — less discriminative on a code corpus where keyword/path cues dominate; ranking noise is higher.
- `vn_to_en` queries (pure semantic-leg test: VN query → English-only file) are where e5-base bleeds most: seo-04 rank 2196, seo-09 513, seo-10 143, seo-05 101, crm-11 118 — 5 of the 6 vn_to_en probes fail.
- Chunks truncated at 512 tokens (seo: 17/500 sampled >512; crm: 161/500 >512 — VN docstring-heavy chunks tokenize long); long functions lose their tails. Same cap as bge-m3 run.
- fp16 on MPS for all embeddings including queries. Rank effect negligible.
- e5 prefixes applied per model card (`query: ` / `passage: `); without them scores are known to degrade further.
- Rank measured against ALL corpus chunks including same-file siblings — pool-entry proxy for hybrid retrieval.
- CRM corpus is small (1,151 chunks vs 32,678 on P8) — top-N comparisons across workspaces are not apples-to-apples.
- CPU latency measured once under MPS load (52.0 ms median) and once idle (48.5 ms median); table reports the idle number.
- seo index had 32678 chunks (one more than the bge-m3 run's 32677 — index drifted slightly between runs).
