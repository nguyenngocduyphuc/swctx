# bge-m3 offline eval — Vietnamese semantic-leg probe

- Model: `BAAI/bge-m3` (XLM-RoBERTa-large, 1024-dim dense, CLS + L2 norm — FlagEmbedding convention)
- Device: mps, dtype fp16 (corpus) / fp32 (queries), batch 64, max_len 512 (truncated)
- Snapshot size on disk: ~4.3 GB (dense `pytorch_model.bin` ≈ 2.27 GB; also ships onnx/sparse/colbert heads)
- Embeddings cached at `/tmp/bgem3_eval/` (seo_ids/seo_emb (32677x1024), crm_ids/crm_emb (1151x1024), queries_emb (16x1024))
- Wall clock: ~37 min total (download 53s; embed seo ~30min @ ~18-20 chunks/s, crm ~64s, queries <1s; scoring <1s)

## Corpus

- `seo`: 32677/32677 chunks embedded (full); chunks >512 tokens in 500-sample: 17/500
- `crm`: 1151/1151 chunks embedded (full); chunks >512 tokens in 500-sample: 161/500

## Per-query cosine rank of best expected-file chunk

| id | lang/tags | expected_path | exp chunks | best cos | rank | top-30 | top-5 |
|---|---|---|---|---|---|---|---|
| seo-01 | vi/vn_to_vn | `scripts/p8_canonical_check.py` | 4 | 0.5617 | 117 | — | — |
| seo-02 | vi/vn_to_vn | `scripts/p8_link_health.py` | 6 | 0.5788 | 16 | ✅ | — |
| seo-03 | vi/vn_to_vn | `scripts/p8_utm_builder.py` | 2 | 0.6264 | 1 | ✅ | ✅ |
| seo-04 **(miss)** | vi/vn_to_en | `scripts/p8_image_worker.py` | 19 | 0.5427 | 11 | ✅ | — |
| seo-05 **(miss)** | vi/vn_to_en | `factory/sitectl.py` | 7 | 0.6786 | 1 | ✅ | ✅ |
| seo-06 **(miss)** | vi/vn_to_vn | `docs-fleet/doi-ngu.md` | 1 | 0.5483 | 1 | ✅ | ✅ |
| seo-07 | vi/vn_to_vn | `WORKFLOW.md` | 19 | 0.6155 | 9 | ✅ | — |
| seo-08 | en/en_control | `scripts/p8_fix_featured_images.py` | 11 | 0.6628 | 1 | ✅ | ✅ |
| crm-01 | vi/vn_to_vn | `crm-nam-pham/09-build/cham_cong.py` | 12 | 0.5711 | 3 | ✅ | ✅ |
| crm-02 | vi/vn_to_vn | `crm-nam-pham/09-build/so_tay.py` | 20 | 0.5562 | 32 | — | — |
| crm-03 | vi/vn_to_vn | `crm-nam-pham/09-build/tin_lead.py` | 5 | 0.5611 | 38 | — | — |
| crm-04 **(miss)** | vi/vn_to_vn | `crm-nam-pham/09-build/dong_vong.py` | 6 | 0.5923 | 5 | ✅ | ✅ |
| crm-05 | vi/vn_to_vn | `crm-nam-pham/functions/_middleware.js` | 28 | 0.5217 | 4 | ✅ | ✅ |
| crm-06 | vi/vn_to_vn | `crm-nam-pham/07-docs/DANG_NHAP.md` | 8 | 0.6907 | 1 | ✅ | ✅ |
| crm-07 | vi/vn_to_vn | `crm-nam-pham/09-build/nap_serp.py` | 10 | 0.5894 | 2 | ✅ | ✅ |
| crm-08 **(miss)** | en/en_control | `crm-nam-pham/09-build/ghi_so.py` | 2 | 0.4941 | 153 | — | — |

## Summary

- top-30 pool entry: **12/16** queries; top-5: **9/16**
- Of the 5 current misses (seo-04, seo-05, seo-06, crm-04, crm-08): **4 enter top-30** (seo-04, seo-05, seo-06, crm-04)

## Verdict: **GO**

≥2 misses rescued → proceed to CoreML conversion spike for bge-m3 dense leg.

## Caveats

- **Regressions under pure dense:** 3 currently-passing queries do NOT enter top-30 by cosine alone — seo-01 (rank 117), crm-02 (rank 32), crm-03 (rank 38). bge-m3 dense must be *additive* to the hybrid (BM25/path_tokens) leg, not a replacement.
- crm-08 (en_control, en→vi target `ghi_so.py:ghi_quyet_dinh`) stays a miss at rank 153 — cross-lingual en→vi still weak here; its only 2 chunks, and `ghi_quyet_dinh` (689 swctx tokens) is likely >512-token-truncated.
- Dense CLS only — bge-m3's sparse/Multi-Vec (ColBERT-style) heads unused; hybrid would likely do better.
- Chunks truncated at 512 tokens (seo: 17/500 sampled >512; crm: 161/500 >512 — VN docstring-heavy chunks tokenize long); long functions lose their tails.
- fp16 on MPS for corpus embeddings; queries fp32. Rank effect negligible.
- No instruction prefix on queries (bge-m3 does not use one for short queries — matches FlagEmbedding default).
- Rank measured against ALL corpus chunks including same-file siblings — pool-entry proxy for hybrid retrieval.
- CRM corpus is small (1,151 chunks vs 32,677 on P8) — top-N comparisons across workspaces are not apples-to-apples.
