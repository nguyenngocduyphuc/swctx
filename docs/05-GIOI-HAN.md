# Giới hạn & lộ trình

## Giới hạn đã đo (nói thẳng)

1. **`vn_to_en` 0/5** — câu hỏi tiếng Việt mà file mục tiêu toàn tiếng
   Anh vẫn miss. Đã đo 4 model embedding + 3 reranker + 5 biến thể
   lexical: bức tường là **model-bound trên phần cứng này**, không phải
   thiếu thử. Cách duy nhất hiện có: đẩy câu đó lên ctxe `ask_context`
   (đo thật: cứu được cả 2 câu vn_to_en trong mẫu — giá ~20–60s +
   credits).
2. **`in_body_only` 4/11** — khi tín hiệu chỉ nằm trong thân file (không
   khớp tên file/symbol), lexical hết đòn. Cùng gốc với (1).
3. **Edge resolve 30–45%** — phần lớn edge `calls` chưa resolve được
   target. Đây là lựa chọn có chủ đích ("thà NULL còn hơn sai"): audit
   cho thấy 60% edge "nhiều hơn" của ctxe là phantom. `find_usages`
   vẫn match tên trên edge chưa resolve.
4. **`en_control` 1/3** — query tiếng Anh trên workspace tài liệu Việt
   cũng yếu (ít quan trọng vì corpus VN-first).
5. **Fleet memory mới ít dùng** — plumbing xong, 3 record; cần agent
   ghi nhiều hơn mới phát huy.

## Lộ trình đề xuất (theo leverage đã đo)

| Ưu tiên | Việc | Kỳ vọng |
|---|---|---|
| 1 | **Translation-assisted retrieval** — dịch cụm từ khóa VN→EN rồi chạy lexical | cứu một phần vn_to_en, rẻ, không cần model mới |
| 2 | **Distill/quantize bge-m3** (24L→nhỏ hơn hoặc int8) | giữ quality 4/5-rescue, đưa 410ms về trong gate |
| 3 | CodeRankEmbed spike | code-specialized — nhưng EN-bias, rủi ro với VN |
| 4 | Mở rộng paired A/B swctx↔ctxe (n hiện 22) | bản đồ phân công L1/L2 chính xác hơn |
| 5 | Merkle-tree sync giữa indexes | backlog freshness |
| 6 | CI on-commit (ngoài cổng đêm launchd) | khi có >1 contributor |

## Cái cố ý KHÔNG làm

- Không build planner/tổng hợp trong swctx — đó là việc của ctxe (L2)
  hoặc của agent. swctx chỉ làm retrieval thật tốt.
- Không đuổi edge count của ctxe — audit chứng minh phần nhiều hơn là
  nhiễu phantom.
- Không gộp 6 watcher thành 1 — mỗi workspace một tiến trình độc lập
  là feature (cô lập lỗi), không phải sự trùng lặp.
- Không đổi model mặc định sang bge-m3/e5 — đã đo: không đủ cả hai.
