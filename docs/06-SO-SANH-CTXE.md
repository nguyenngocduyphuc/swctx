# swctx ↔ ctxe — so sánh đối chiếu

> File Excel đi kèm: **`swctx-vs-ctxe.xlsx`** (3 sheet: Tổng quan,
> Benchmark có cặp, Verdicts). Dữ liệu nguồn:
> `bench/engine_ab_results.json` — 22 câu probe chạy qua cả hai MCP
> server, cùng workspace, cùng expected answer.

## Khác nhau căn bản — không phải hai cái giống nhau

| | **swctx** | **ctxe** |
|---|---|---|
| Vai trò | **L1 — phản xạ**: retrieval tức thì | **L2 — nhà tiên tri**: tổng hợp bằng LLM |
| Chạy ở đâu | 100% local trên Mac | engine local + server LLM |
| Chi phí | 0 đồng, không giới hạn | credits cho mỗi ask |
| Riêng tư | dữ liệu không rời máy | query/chunk đi lên server |
| Latency trả lời | ~10–120 ms | ask_context 20–60 s |

## Bản đồ so sánh được — đo thật, không đoán

ctxe **không có tool `search` tổng quát**. Harness phải so theo surface
tương đương, và đây chính là phát hiện quan trọng nhất:

| Bài toán | swctx | ctxe | Ai thắng |
|---|---|---|---|
| Tìm file bằng câu NL (22 câu VN probe) | **13/22 @ ~101ms** | không có surface (proxy tree: 3/11 @ 424ms) | **swctx áp đảo** |
| Tìm symbol (4 câu `find_definitions`) | 3/4 @ 12ms | 3/4 @ 7ms | **hòa** — cùng hit set |
| Query concept-flow chỉ trong thân file | 4/11 | **0 surface nào** (7 câu không có đường gọi) | swctx mặc định |
| Câu hỏi tổng hợp sâu (`ask_context`) | không có (cố ý) | 4/4 hit qua record — **gồm cả miss của swctx** | **ctxe** |
| Đồ thị (expand/neighbors/paths/impact) | có, ~10–25ms | có, tương đương | hòa |

## Con số chốt

- **Union coverage: 17/22** — cao hơn một mình swctx (14/22 kể cả
  find_definitions). Hai máy **bổ sung**, không thay thế nhau.
- `ask_context` (min effort) cứu được **cả 3 miss được sample của
  swctx**, trong đó có 2 câu `vn_to_en` mà mọi model local đều bó tay —
  đúng vai trò L2, giá 200–600× latency + credits + phải đi qua
  record hop.
- ctxe `inspect_path` không search được cả workspace; `workspace_tree`
  chỉ là filter path-substring — retrieval NL ở ctxe thực chất nằm hết
  trong `ask_context` (trả phí).

## Kết luận vận hành

1. **Mặc định mọi việc retrieval cho swctx** — nhanh hơn, miễn phí,
   phủ surface mà ctxe không có.
2. **ctxe chỉ cho `ask_context`/`compose_answer`** — khi câu hỏi cần
   suy luận nhiều file hoặc swctx miss (đặc biệt vn_to_en).
3. Routing này đã cài trong skill `swctx` mà mọi agent đọc.
