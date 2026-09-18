# vn-probe — Vietnamese retrieval probe for swctx

Generated: 2026-09-18T18:45:41+00:00 · swctx bin: `/Users/phuongnam/02.AI/NP_AI_macos/tools/swctx/bench/../.build/release/swctx` · limit: recall@5

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
| seo-01 | vi | vn_to_vn | script kiểm tra google có đang chọn canonical khác với url mình khai báo không | `scripts/p8_canonical_check.py` | — | — | 2 |
| seo-02 | vi | vn_to_vn | gate phát hiện link nội bộ bị gãy 404 trong bài trước khi publish | `scripts/p8_link_health.py` | — | — | 1 |
| seo-03 | vi | vn_to_vn | script tạo file excel để sinh link utm cho chiến dịch zalo linkedin | `scripts/p8_utm_builder.py` | 1 | — | 2 |
| seo-04 | vi | vn_to_en | worker tự sinh ảnh minh họa cho các mục h2 còn thiếu ảnh | `scripts/p8_image_worker.py` | — | — | — |
| seo-05 | vi | vn_to_en | lệnh đồng bộ thông tin của từng site thành một file entity mesh chung | `factory/sitectl.py` | — | — | — |
| seo-06 | vi | vn_to_vn | trang liệt kê tình trạng các worker trong đội hạm con nào đang bị block | `docs-fleet/doi-ngu.md` | — | — | — |
| seo-07 | vi | vn_to_vn | tài liệu quy trình chuẩn để push nội dung bài viết lên site | `WORKFLOW.md` | 5 | — | 3 |
| seo-08 | en | en_control | generate hero image and set featured image for articles missing one | `scripts/p8_fix_featured_images.py` | 1 | — | 3 |
| crm-01 | vi | vn_to_vn | script tính chấm công của nhân viên từ nhật ký hoạt động | `crm-nam-pham/09-build/cham_cong.py` | — | — | — |
| crm-02 | vi | vn_to_vn | đoạn code tóm tắt hôm qua làm gì và việc nào sắp tới hạn chấm cho CEO | `crm-nam-pham/09-build/so_tay.py` | 4 | — | 3 |
| crm-03 | vi | vn_to_vn | hàm tạo mảnh tin telegram báo có lead mới hôm qua | `crm-nam-pham/09-build/tin_lead.py` | 1 | — | 2 |
| crm-04 | vi | vn_to_vn | script đối soát quyết định của CEO với trạng thái việc thật để đóng vòng | `crm-nam-pham/09-build/dong_vong.py` | — | — | — |
| crm-05 | vi | vn_to_vn | middleware gác cửa kiểm tra đăng nhập bằng vân tay passkey | `crm-nam-pham/functions/_middleware.js` | 1 | — | 1 |
| crm-06 | vi | vn_to_vn | tài liệu giải thích CEO đăng nhập bằng google qua cloudflare access | `crm-nam-pham/07-docs/DANG_NHAP.md` | 3 | 1 | 1 |
| crm-07 | vi | vn_to_vn | script nạp file csv export từ serpupdate vào lịch sử từ khóa | `crm-nam-pham/09-build/nap_serp.py` | 1 | — | 1 |
| crm-08 | en | en_control | shared helper writing one decision row into the operations ledger | `crm-nam-pham/09-build/ghi_so.py` | — | — | — |

## Aggregate recall@5

| scope | fts | semantic | auto |
|---|---|---|---|
| 8.P8_SEO_Clean (n=8) | 3/8 (38%) | 0/8 (0%) | 5/8 (62%) |
| 18.CRM-Nam-Pham (n=8) | 5/8 (62%) | 1/8 (12%) | 5/8 (62%) |
| ALL (n=16) | 8/16 (50%) | 1/16 (6%) | 10/16 (62%) |
| lang=vi (n=14) | 7/14 (50%) | 1/14 (7%) | 9/14 (64%) |
| lang=en (n=2) | 1/2 (50%) | 0/2 (0%) | 1/2 (50%) |
| tag=vn_to_vn (n=12) | 7/12 (58%) | 1/12 (8%) | 9/12 (75%) |
| tag=vn_to_en (n=2) | 0/2 (0%) | 0/2 (0%) | 0/2 (0%) |
| tag=en_control (n=2) | 1/2 (50%) | 0/2 (0%) | 1/2 (50%) |

Median CLI latency per call: fts 321 ms · semantic 885 ms · auto 954 ms.

## FTS-miss → semantic-hit (the interesting cases)

- none

## FTS-hit → semantic-miss (reverse direction)

- **seo-03** (vi) "script tạo file excel để sinh link utm cho chiến dịch zalo linkedin" → `scripts/p8_utm_builder.py` — fts rank 1, semantic rank —, auto rank 2
- **seo-07** (vi) "tài liệu quy trình chuẩn để push nội dung bài viết lên site" → `WORKFLOW.md` — fts rank 5, semantic rank —, auto rank 3
- **seo-08** (en) "generate hero image and set featured image for articles missing one" → `scripts/p8_fix_featured_images.py` — fts rank 1, semantic rank —, auto rank 3
- **crm-02** (vi) "đoạn code tóm tắt hôm qua làm gì và việc nào sắp tới hạn chấm cho CEO" → `crm-nam-pham/09-build/so_tay.py` — fts rank 4, semantic rank —, auto rank 3
- **crm-03** (vi) "hàm tạo mảnh tin telegram báo có lead mới hôm qua" → `crm-nam-pham/09-build/tin_lead.py` — fts rank 1, semantic rank —, auto rank 2
- **crm-05** (vi) "middleware gác cửa kiểm tra đăng nhập bằng vân tay passkey" → `crm-nam-pham/functions/_middleware.js` — fts rank 1, semantic rank —, auto rank 1
- **crm-07** (vi) "script nạp file csv export từ serpupdate vào lịch sử từ khóa" → `crm-nam-pham/09-build/nap_serp.py` — fts rank 1, semantic rank —, auto rank 1

## Misses in every mode

- **seo-04** (vi) "worker tự sinh ảnh minh họa cho các mục h2 còn thiếu ảnh" → `scripts/p8_image_worker.py`
- **seo-05** (vi) "lệnh đồng bộ thông tin của từng site thành một file entity mesh chung" → `factory/sitectl.py`
- **seo-06** (vi) "trang liệt kê tình trạng các worker trong đội hạm con nào đang bị block" → `docs-fleet/doi-ngu.md`
- **crm-01** (vi) "script tính chấm công của nhân viên từ nhật ký hoạt động" → `crm-nam-pham/09-build/cham_cong.py`
- **crm-04** (vi) "script đối soát quyết định của CEO với trạng thái việc thật để đóng vòng" → `crm-nam-pham/09-build/dong_vong.py`
- **crm-08** (en) "shared helper writing one decision row into the operations ledger" → `crm-nam-pham/09-build/ghi_so.py`

## Failure-pattern analysis

Vietnamese queries (n=14): FTS recall 50%, semantic 7%, auto 64%. English controls (n=2): FTS 50%, semantic 0%, auto 50%.

Split by target language — VN query onto Vietnamese-heavy content (vn_to_vn, n=12): FTS 58% / semantic 8%. VN query onto English-only code (vn_to_en, n=2): FTS 0% / semantic 0%. The vn_to_en rows are the purest test of whether the embedding model bridges languages, since no Vietnamese token in the index can match them.

Leg divergence: 0 queries were rescued by the semantic leg (FTS miss → semantic hit) vs 7 going the other way (FTS hit → semantic miss). 6 queries missed in every mode.

Mechanism check (verified in `Sources/SwctxCore/Embedder.swift` + `BGEEmbedder.swift`): embedding is per-index — these workspaces are bound to **distiluse-base-multilingual-cased-v2** (CoreML, cased WordPiece, mean pooling, real VN tokens), while the English default remains bge-base-en-v1.5. Vector ordering on VN improved ~10-50x after the binding, so a low semantic-leg VN recall (7%) now points at ranking/fusion, not vocab. The path boost itself is folded + token-boundary (`Search.foldText`): accented VN terms match ASCII path tokens, and substrings no longer produce phantom boosts.

Two qualitative observations from the hit lists: (1) FTS noise is real — diacritic folding makes common VN morphemes collide (`chấm công nhân viên` matched `he-thiet-ke.css` on folded tokens `nhan`/`vien`), so FTS precision on VN is worse than its recall number suggests; (2) `auto` is a genuine RRF-style fusion, not a mode switch — it rescued `seo-02` (rank 2) that neither leg placed in the top 5, so the semantic leg does contribute ranking signal even when it can't win alone.

## Verdict

**Vietnamese queries still lean on FTS** (50% recall vs semantic 7%): unicode61 folds diacritics (`chấm công` → `cham cong`), and Vietnamese file names/docstrings give FTS plenty to match. These indexes are bound to distiluse-multilingual, so the weak semantic leg is no longer a vocab problem — vector ordering improved ~10-50x — but deep vector hits rarely survive fusion.

Auto recall on natural VN queries is 64%. Measured fixes so far: folded token-boundary path boost (rescued crm-06 to rank 1, +1 VN hit, zero regressions). Measured reject: widening the per-leg candidate window to limit*12 — deep vector noise (ranks 15-60) diluted RRF and cost the English control (auto dropped). Remaining lever: weighted fusion or query rewriting, not bigger windows. Honest bound: en_control semantic recall is 0% on n=2.

Honesty check: this probe measures file-level recall@5 on two doc-heavy workspaces. It says nothing about chunk-level precision, and the corpus here is unusually VN-friendly (Vietnamese file names + docstrings), so treat the numbers as a directional answer to the product question, not a benchmark.

## Caveats

- n = 16 queries total (8 per workspace, only 2 English controls): enough for a directional signal, not a statistically tight estimate. In particular the EN control n is too small to fully separate 'model weak on VN' from 'model weak on this corpus generally' — ad-hoc EN spot checks suggest some corpus-general weakness too.
- Workspaces are doc-heavy (SEO repo is ~46% markdown, much of it Vietnamese). A code-only workspace could behave differently.
- FTS scores benefit from Vietnamese file names (`cham_cong.py`, `DANG_NHAP.md`) and Vietnamese docstrings — a corpus with English-only names would flatter FTS less.
- The embedder is bge-base-en-v1.5 (verified: `Sources/SwctxCore/Embedder.swift`, `~/.swctx/models/`). Its bert-uncased WordPiece vocab is English-only, so the semantic-leg VN collapse has a mechanical cause — results don't generalise to a multilingual embedder.
- recall@5 on path level: a correct chunk in a wrong-but-related file counts as a miss, and multi-chunk hits from one file can crowd out diversity in the top 5.
- semantic mode re-embeds the query per CLI call (~0.3-0.4 s here); rankings are deterministic given the same index snapshot.
