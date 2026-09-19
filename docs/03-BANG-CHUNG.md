# Bằng chứng đo lường

Mọi con số dưới đây đo trên máy thật, index thật, qua đường MCP thật —
không phải mô phỏng. Nguồn chi tiết: `bench/overnight/JOURNAL.md` và
các report trong `bench/`.

## Bộ dữ liệu đo

- **`bench/vn_queries.json`** — 22 câu hỏi (19 tiếng Việt, 3 tiếng Anh
  đối chứng) trên 2 workspace: P8 (32.678 chunk) và CRM (1.151 chunk).
  Mỗi câu có `expected_path` đã xác minh tay.
- **`bench/gold_queries.json`** — 36 câu gold (3 workspace × định
  nghĩa + tìm kiếm) dùng cho ratchet đêm.

## Kết quả tổng hợp

| Chỉ số | Giá trị | Ngữ cảnh |
|---|---|---|
| Recall@5 vn-probe | **13/22 (59%)** | baseline đêm 19/9 |
| — query khớp tên file (`in_path`) | **9/11 (82%)** | mạnh nhất |
| — query chỉ trong thân file | 4/11 (36%) | vùng yếu |
| — câu Việt → mục tiêu Anh (`vn_to_en`) | 0/5 | bức tường model |
| Recall@5 gold (36 câu, qua MCP) | **0.9722** | cổng ratchet |
| p95 latency hybrid | **~102–116 ms** | warm, trong gate ≤150ms |
| Cold-start đầu tiên | **0.9 s** | nhờ vector sidecar (trước 3.2s) |
| Test suite | **115/115** | swift test |
| Tool schema | 20/20 khớp golden | không drift wire |

## Hành trình cải thiện recall (đo từng bước)

| Bước | auto recall | Ghi chú |
|---|---|---|
| Đầu đêm (n=16) | 8/16 | baseline |
| + cột `folded` + tail-fill | 10/16 | cứu query có dấu |
| + chân phrase trên path | 11/16 | `chấm công` → `cham_cong.py` |
| Mở rộng probe n=22 | **13/22** | baseline hiện tại |

## Chi phí vận hành

- Watcher: 6 tiến trình launchd, mỗi cái ~vài MB RAM, FSEvents.
- Index P8: ~33k chunk + vector 768-d ≈ ~130MB sidecar + index.db.
- Embed batch chạy CPU (~7–11ms/chunk với model hiện tại).

## So sánh có cặp với ctxe

Xem `06-SO-SANH-CTXE.md` và file Excel `swctx-vs-ctxe.xlsx` — dữ liệu
từ `bench/engine_ab_results.json` (22 query chạy qua CẢ HAI engine).
