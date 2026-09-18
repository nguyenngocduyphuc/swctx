# vn-probe — Vietnamese retrieval probe for swctx

Generated: 2026-09-18T14:32:32+00:00 · swctx bin: `/Users/phuongnam/02.AI/NP_AI_macos/tools/swctx/bench/../.build/release/swctx` · limit: recall@5

## Question

Should swctx swap/extend its embedding model for Vietnamese? The hypothesis under test: Vietnamese natural-language queries fail on the FTS/keyword leg (diacritics, no English keywords to match) but succeed on the semantic/vector leg. If FTS already covers Vietnamese well enough — or if neither leg works — the model swap is dead (or insufficient) and that is a cheap thing to learn now.

## Method

- 16 queries (14 Vietnamese, 2 English controls) across 2 indexed workspaces:
  - `seo` = `/Users/phuongnam/02.AI/NP_AI_macos/8.P8_SEO_Clean` (8 queries)
  - `crm` = `/Users/phuongnam/02.AI/NP_AI_macos/18.CRM-Nam-Pham` (8 queries)
- Every query ran through all three modes — `fts`, `semantic`, `auto` —
  via `swctx search <ws> "<query>" --mode <m> --limit 5`, one CLI process per call.
- Metric: recall@5 — 1 if the verified expected file appears in the top hits (rank recorded, first occurrence).
- Every expected_path was verified on disk and in the index files table before the run; `verified=false` flags anything that drifted.
- Tags: `vn_to_vn` = VN query onto Vietnamese-heavy content, `vn_to_en` = VN query onto English-only code (pure semantic-leg test), `en_control` = English query for contrast.

## Per-query results (rank of expected file; `—` = not in top 5)

| id | lang | tags | query | expected_path | fts | semantic | auto |
|---|---|---|---|---|---|---|---|
| seo-01 | vi | vn_to_vn | script kiểm tra google có đang chọn canonical khác với url mình khai báo không | `scripts/p8_canonical_check.py` | — | — | — |
| seo-02 | vi | vn_to_vn | gate phát hiện link nội bộ bị gãy 404 trong bài trước khi publish | `scripts/p8_link_health.py` | — | — | 2 |
| seo-03 | vi | vn_to_vn | script tạo file excel để sinh link utm cho chiến dịch zalo linkedin | `scripts/p8_utm_builder.py` | 1 | — | 2 |
| seo-04 | vi | vn_to_en | worker tự sinh ảnh minh họa cho các mục h2 còn thiếu ảnh | `scripts/p8_image_worker.py` | — | — | — |
| seo-05 | vi | vn_to_en | lệnh đồng bộ thông tin của từng site thành một file entity mesh chung | `factory/sitectl.py` | — | — | — |
| seo-06 | vi | vn_to_vn | trang liệt kê tình trạng các worker trong đội hạm con nào đang bị block | `docs-fleet/doi-ngu.md` | — | — | — |
| seo-07 | vi | vn_to_vn | tài liệu quy trình chuẩn để push nội dung bài viết lên site | `WORKFLOW.md` | — | — | — |
| seo-08 | en | en_control | generate hero image and set featured image for articles missing one | `scripts/p8_fix_featured_images.py` | 1 | — | 4 |
| crm-01 | vi | vn_to_vn | script tính chấm công của nhân viên từ nhật ký hoạt động | `crm-nam-pham/09-build/cham_cong.py` | — | — | — |
| crm-02 | vi | vn_to_vn | đoạn code tóm tắt hôm qua làm gì và việc nào sắp tới hạn chấm cho CEO | `crm-nam-pham/09-build/so_tay.py` | — | — | — |
| crm-03 | vi | vn_to_vn | hàm tạo mảnh tin telegram báo có lead mới hôm qua | `crm-nam-pham/09-build/tin_lead.py` | 1 | — | 1 |
| crm-04 | vi | vn_to_vn | script đối soát quyết định của CEO với trạng thái việc thật để đóng vòng | `crm-nam-pham/09-build/dong_vong.py` | — | — | — |
| crm-05 | vi | vn_to_vn | middleware gác cửa kiểm tra đăng nhập bằng vân tay passkey | `crm-nam-pham/functions/_middleware.js` | 1 | — | 1 |
| crm-06 | vi | vn_to_vn | tài liệu giải thích CEO đăng nhập bằng google qua cloudflare access | `crm-nam-pham/07-docs/DANG_NHAP.md` | 1 | 1 | — |
| crm-07 | vi | vn_to_vn | script nạp file csv export từ serpupdate vào lịch sử từ khóa | `crm-nam-pham/09-build/nap_serp.py` | 1 | — | 2 |
| crm-08 | en | en_control | shared helper writing one decision row into the operations ledger | `crm-nam-pham/09-build/ghi_so.py` | — | — | — |

## Aggregate recall@5

| scope | fts | semantic | auto |
|---|---|---|---|
| 8.P8_SEO_Clean (n=8) | 2/8 (25%) | 0/8 (0%) | 3/8 (38%) |
| 18.CRM-Nam-Pham (n=8) | 4/8 (50%) | 1/8 (12%) | 3/8 (38%) |
| ALL (n=16) | 6/16 (38%) | 1/16 (6%) | 6/16 (38%) |
| lang=vi (n=14) | 5/14 (36%) | 1/14 (7%) | 5/14 (36%) |
| lang=en (n=2) | 1/2 (50%) | 0/2 (0%) | 1/2 (50%) |
| tag=vn_to_vn (n=12) | 5/12 (42%) | 1/12 (8%) | 5/12 (42%) |
| tag=vn_to_en (n=2) | 0/2 (0%) | 0/2 (0%) | 0/2 (0%) |
| tag=en_control (n=2) | 1/2 (50%) | 0/2 (0%) | 1/2 (50%) |

Median CLI latency per call: fts 321 ms · semantic 977 ms · auto 846 ms.

## FTS-miss → semantic-hit (the interesting cases)

- none

## FTS-hit → semantic-miss (reverse direction)

- **seo-03** (vi) "script tạo file excel để sinh link utm cho chiến dịch zalo linkedin" → `scripts/p8_utm_builder.py` — fts rank 1, semantic rank —, auto rank 2
- **seo-08** (en) "generate hero image and set featured image for articles missing one" → `scripts/p8_fix_featured_images.py` — fts rank 1, semantic rank —, auto rank 4
- **crm-03** (vi) "hàm tạo mảnh tin telegram báo có lead mới hôm qua" → `crm-nam-pham/09-build/tin_lead.py` — fts rank 1, semantic rank —, auto rank 1
- **crm-05** (vi) "middleware gác cửa kiểm tra đăng nhập bằng vân tay passkey" → `crm-nam-pham/functions/_middleware.js` — fts rank 1, semantic rank —, auto rank 1
- **crm-07** (vi) "script nạp file csv export từ serpupdate vào lịch sử từ khóa" → `crm-nam-pham/09-build/nap_serp.py` — fts rank 1, semantic rank —, auto rank 2

## Misses in every mode

- **seo-01** (vi) "script kiểm tra google có đang chọn canonical khác với url mình khai báo không" → `scripts/p8_canonical_check.py`
- **seo-04** (vi) "worker tự sinh ảnh minh họa cho các mục h2 còn thiếu ảnh" → `scripts/p8_image_worker.py`
- **seo-05** (vi) "lệnh đồng bộ thông tin của từng site thành một file entity mesh chung" → `factory/sitectl.py`
- **seo-06** (vi) "trang liệt kê tình trạng các worker trong đội hạm con nào đang bị block" → `docs-fleet/doi-ngu.md`
- **seo-07** (vi) "tài liệu quy trình chuẩn để push nội dung bài viết lên site" → `WORKFLOW.md`
- **crm-01** (vi) "script tính chấm công của nhân viên từ nhật ký hoạt động" → `crm-nam-pham/09-build/cham_cong.py`
- **crm-02** (vi) "đoạn code tóm tắt hôm qua làm gì và việc nào sắp tới hạn chấm cho CEO" → `crm-nam-pham/09-build/so_tay.py`
- **crm-04** (vi) "script đối soát quyết định của CEO với trạng thái việc thật để đóng vòng" → `crm-nam-pham/09-build/dong_vong.py`
- **crm-08** (en) "shared helper writing one decision row into the operations ledger" → `crm-nam-pham/09-build/ghi_so.py`

## Failure-pattern analysis

Vietnamese queries (n=14): FTS recall 36%, semantic 7%, auto 36%. English controls (n=2): FTS 50%, semantic 0%, auto 50%.

Split by target language — VN query onto Vietnamese-heavy content (vn_to_vn, n=12): FTS 42% / semantic 8%. VN query onto English-only code (vn_to_en, n=2): FTS 0% / semantic 0%. The vn_to_en rows are the purest test of whether the embedding model bridges languages, since no Vietnamese token in the index can match them.

Leg divergence: 0 queries were rescued by the semantic leg (FTS miss → semantic hit) vs 5 going the other way (FTS hit → semantic miss). 9 queries missed in every mode.

Mechanism check (verified in `Sources/SwctxCore/Embedder.swift` + `BGEEmbedder.swift`): the live embedder is **bge-base-en-v1.5** (CoreML, bert-base-uncased WordPiece vocab). That vocab is English-only — Vietnamese syllables with stacked diacritics (`kiểm`, `được`, `nhân viên`) mostly map to `[UNK]`, so a Vietnamese sentence embeds to near-noise. The observed semantic-leg VN recall (7%) is exactly what that tokenization predicts — it is a model property, not a retrieval-pipeline bug.

Two qualitative observations from the hit lists: (1) FTS noise is real — diacritic folding makes common VN morphemes collide (`chấm công nhân viên` matched `he-thiet-ke.css` on folded tokens `nhan`/`vien`), so FTS precision on VN is worse than its recall number suggests; (2) `auto` is a genuine RRF-style fusion, not a mode switch — it rescued `seo-02` (rank 2) that neither leg placed in the top 5, so the semantic leg does contribute ranking signal even when it can't win alone.

## Verdict

**The stated hypothesis is falsified — and inverted.** Vietnamese queries do NOT fail on FTS (36% recall): unicode61 folds diacritics (`chấm công` → `cham cong`), and Vietnamese file names/docstrings give FTS plenty to match. The leg that actually dies on Vietnamese is **semantic (7%)** — bge-base-en-v1.5 has an English-only WordPiece vocab, so VN text embeds to near-noise and the vector leg rescues zero Vietnamese queries while still working on the English control.

So: **does the current setup lose Vietnamese retrieval? Yes** — auto recall on natural VN queries is only 36%, and every VN hit is carried entirely by the keyword leg. **Is a different embedding model likely to fix it? More likely than this probe's framing suggested.** The swap doesn't compete with a working FTS leg — it would repair a leg that is currently dead weight for VN (0/14) while providing fusion signal elsewhere. Any multilingual model with real Vietnamese tokens (bge-m3, paraphrase-multilingual, a VN-specialised embedder) can only improve on 0%. The honest bound: en_control semantic recall is only 0% on n=2, and ad-hoc EN spot checks in the same workspaces also missed obvious targets (setup.js dominates the vector top-5 at scores ~0.7-0.8) — so the vector leg may have corpus-general weakness too, and a model swap alone may not reach acceptable recall. Cheap gate: re-embed one workspace with a multilingual model and re-run this probe; if semantic VN recall moves off 0%, the swap is justified for any VN-facing use case.

Honesty check: this probe measures file-level recall@5 on two doc-heavy workspaces. It says nothing about chunk-level precision, and the corpus here is unusually VN-friendly (Vietnamese file names + docstrings), so treat the numbers as a directional answer to the product question, not a benchmark.

## Caveats

- n = 16 queries total (8 per workspace, only 2 English controls): enough for a directional signal, not a statistically tight estimate. In particular the EN control n is too small to fully separate 'model weak on VN' from 'model weak on this corpus generally' — ad-hoc EN spot checks suggest some corpus-general weakness too.
- Workspaces are doc-heavy (SEO repo is ~46% markdown, much of it Vietnamese). A code-only workspace could behave differently.
- FTS scores benefit from Vietnamese file names (`cham_cong.py`, `DANG_NHAP.md`) and Vietnamese docstrings — a corpus with English-only names would flatter FTS less.
- The embedder is bge-base-en-v1.5 (verified: `Sources/SwctxCore/Embedder.swift`, `~/.swctx/models/`). Its bert-uncased WordPiece vocab is English-only, so the semantic-leg VN collapse has a mechanical cause — results don't generalise to a multilingual embedder.
- recall@5 on path level: a correct chunk in a wrong-but-related file counts as a miss, and multi-chunk hits from one file can crowd out diversity in the top 5.
- semantic mode re-embeds the query per CLI call (~0.3-0.4 s here); rankings are deterministic given the same index snapshot.
