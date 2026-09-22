# Giới hạn & lộ trình

Cập nhật 2026-09-22 — mọi con số đo trên manifest đã đăng ký trước
(`bench/*.REGISTERED`) hoặc ledger thật, không phải cảm tính.

## Giới hạn đã đo (nói thẳng)

1. **`in_body_only` là stratum yếu nhất — và ctxe planner còn thắng
   thật.** Khi tín hiệu chỉ nằm trong thân file (không khớp tên
   file/symbol): vn22 `search` R@5 8/11 (miss seo-07, crm-02, crm-08);
   linkeldn blind union 10/13 vs ctxe 13/13; fleet union 7/11 vs ctxe
   9/11 (paired Sep-20). Nguyên nhân đã chứng minh là **pool coverage**
   (gold không vào candidate pool) — 3/3 reranker bị reject vì không
   rerank được cái fusion chưa surface. Hướng fix: leg mới (graph
   one-hop, concept-flow, lexicon mine từ usage), không phải model lớn
   hơn.
2. **`vn_to_en` đã đóng — không còn là 0/5.** Nhờ `enLexicon` (EN→VN
   filename atoms) + acronym tokenizer + vnLexicon +34: holdout
   unseen-repo aiteam 8/13 → 13/13 R@5, zero regression trên 3 manifest.
   Miss còn lại của vn22 giờ là vn_to_vn: seo-02 (in_path, rank 8),
   seo-07 + crm-02 (body-only).
3. **Edge resolve còn thấp (đa số `calls` chưa có target)** — lựa chọn
   có chủ đích ("thà NULL còn hơn sai"): audit cho thấy phần edge
   "nhiều hơn" của ctxe chủ yếu là phantom. `find_usages` vẫn match tên
   trên edge chưa resolve.
4. **`en_control` 2/3** — query tiếng Anh trên corpus VN-first yếu hơn
   (crm-08 miss body-only). Ít quan trọng vì fleet là VN-first.
5. **Synthesis chưa được fleet dùng thật** — `usage_events`:
   search=**781**, answer=**0**; ctxe `kind=ask`=**126** và đang tăng.
   `answer --backend cli:*` đo thắng cited-R@1 (linkeldn 17v15, fleet
   15v14) nhưng đó là khả năng, chưa phải displacement — reroute là
   Phase 1.
6. **Không có server-side planner/reranker** — ctxe còn giữ multi-round
   planner (3–48 vòng) + corpus-scale reranker. swctx cố ý để reasoning
   cho agent gọi MCP; `answer --plan`/`cli:*` chạy loop đó local, nhưng
   chất lượng trên câu multi-hop rối mới chỉ đo qua proxy cited-R@1.

## Lộ trình đề xuất (theo leverage đã đo)

| Ưu tiên | Việc | Kỳ vọng |
|---|---|---|
| 1 | **Reroute `answer` → `cli:*` mặc định** (Phase 1): auto-detect fleet CLI, ctxe compose chỉ fallback | ctxe ask < 126 sau 14 ngày |
| 2 | **Cứu `in_body_only`** (Phase 2): graph one-hop leg vào `search`, docstring/comment weighting, lexicon mine từ `usage_events` zero-hit | đóng gap 10/13 vs 13/13 trên slice body-only |
| 3 | Giữ discipline frozen holdout: 70+ câu chỉ đo, tune trên mined queries | không overfit manifest |
| 4 | Merkle-tree sync giữa indexes | backlog freshness |
| 5 | CI on-commit (ngoài cổng đêm launchd) | khi có >1 contributor |

Đã thử và reject (artifacts trong `bench/`): 4 embedder mới (bge-m3,
e5-base, e5-large, distiluse-as-default), 3 reranker (amberoad,
bge-reranker-v2-m3, jina-v3) — losses là domain-bound/pool-bound, không
phải capacity.

## Cái cố ý KHÔNG làm

- Không build **server-side** planner/compose trả phí — reasoning là
  việc của agent gọi MCP, hoặc `answer --backend cli:*` trên fleet CLI
  subscription sẵn có. (swctx CÓ planner loop local; cái không làm là
  đưa nó lên server metered.)
- Không đuổi edge count của ctxe — audit chứng minh phần nhiều hơn là
  nhiễu phantom.
- Không gộp watchd thành nhiều daemon — một `com.swctx.watchd` duy nhất
  là đủ; per-workspace watcher trong cùng process vẫn cô lập lỗi.
- Không đổi model mặc định — đã đo 4 ứng viên, không cái nào đủ cả
  quality lẫn latency gate.
