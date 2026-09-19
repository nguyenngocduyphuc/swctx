# Nhật ký quyết định — nhận hay loại đều có bằng chứng

Quy tắc của project: **đo trước, quyết sau**. Mỗi ý tưởng chạy qua cùng
một probe; nhận khi số liệu thắng baseline, loại khi không — và giữ lại
artifacts để sau này ai đó không phải thử lại.

## Đã NHẬN (adopted)

| Thay đổi | Bằng chứng |
|---|---|
| Cột `folded` (schema v6) + tail-fill | auto 8→10/16; cứu query có dấu, zero regression |
| Chân folded path-phrase | 10→11/16; `chấm công` → `cham_cong.py` rank 2 |
| Chân hybrid chạy song song (LegBag) | VN latency 150→95–125ms; ratchet p95 102.5ms |
| Vector sidecar `vectors.v1.bin` | cold start 3.2s → 0.9s |
| Probe mở rộng 16→22 câu + split theo intent/path | bản đồ miss định lượng |
| `vec_snapshot` bền (embed kill-safe) | sự cố CRM 0-vector không tái diễn; 5 test |
| Watcher drift-exit qua ledger | binary cũ tự chết, launchd nạp bản mới |
| Store giữ nguyên schema mới hơn | không còn xóa evidence drift |
| `Sendable` + LegBag cho parallel legs | sạch warning concurrency |

## Đã LOẠI (rejected — đo được, artifacts giữ lại)

| Ứng viên | Số liệu | Vì sao loại |
|---|---|---|
| reranker amberoad mBERT | neutral | domain prose≠code |
| bge-reranker-v2-m3 | 7/16 · 2817ms/cặp | chậm 200×, thiên prose |
| jina-reranker-v2 | 13/22 neutral · 1567ms/cặp | pattern chốt: cross-encoder không thắng trên phần cứng này |
| bge-m3 embedder | cứu 4/5 miss NHƯNG ~410ms/embed | quá gate p95 3–7× |
| e5-base | 1/9 cứu + 5 regression | cosine nén, yếu đúng lớp vn_to_en |
| e5-large-instruct | 5 cứu / **5 đuổi** = net 0 | churn thuần — latency đẹp không cứu được |
| 5 biến thể folded khác | zero-sum ở n=16 | cộng chỗ này trừ chỗ kia |
| Weight tuning RRF toàn cục | mọi combo ≤ baseline | uniform RRF giữ |

## Bài học rút ra từ các lần loại

1. **Thêm ứng viên vào cửa sổ chung luôn có giá** — mọi biến thể "nhồi
   thêm hit vào pool" đều đẩy hit thật ra ngoài. Chỉ chân riêng có
   rank riêng (phrase leg) mới cộng được.
2. **Reranker prose-bias không chữa được code** — 3/3 cross-encoder đều
   neutral-to-negative; giá latency 50–200×. Đóng hướng này.
3. **Model đa ngôn ngữ không có cái nào đủ cả hai** — bge-m3 tốt nhưng
   chậm, e5 nhanh nhưng churn. Xem `05-GIOI-HAN.md`.
