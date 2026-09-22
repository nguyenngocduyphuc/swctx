# swctx — Lộ trình thay thế và vượt ctxe

Date: 2026-09-22 · Status: post-audit (Codex round-2 done, Grok full audit đang chạy)
Mục tiêu gốc: cắt credit ctxe mà không mất năng lực agent — rồi vượt ctxe ở các
tính năng chủ động mà ctxe không có.

## Bối cảnh đã verify (không phải claims)

- Retrieval ngang ctxe trên holdout: linkeldn R@1 15–15 hòa (evidence-pack),
  fleet thua 10–14; `answer` cited qua `cli:agy` thắng R@1 cả 2 set (17v15, 15v14)
- Latency local ~ms vs ctxe ~29s/ask; compose `cli:*` 0đ thêm
- Thừa ctxe: simulate_patch, test_coverage, trace_lookup, checkpoint/session
  memory, records fleet-wide, watchd 1-daemon freshness, 12 workspace indexed
- Thiếu ctxe: server-side planner multi-round (ask_context), corpus-scale
  reranker, organic usage data

## Phase 0 — Reliability gate (tuần 1) — chặn lỗi tin cậy trước khi scale

| Việc | Evidence | Effort |
|---|---|---|
| `GlobalRecords.git` drain pipe song song + reap timeout + fake-git regression test | codex round-2: deadlock khi output >64KB → flake testPrimeMarksStaleRecords | 0.5d |
| Citation validator strict: reject schema sai kiểu, không trả answer khi `citation_valid=false` | codex: bypass được bằng citation thiếu path | 0.5d |
| `Watchd.loadWorkspaces` phân biệt missing-file vs read-error (P2 residual) | codex round-2 | 0.25d |
| `gc` dọn 5,218 orphan indexes / ~879MB reclaimable; thêm integrity_check + quarantine | codex | 1d |
| SQLite corrupt → quarantine file, không crash daemon | audit note | 0.5d |

Gate: full suite xanh 3 lần chạy liên tiếp (flake phải chết), 0 orphan sau gc.

## Phase 1 — Displacement measurement (tuần 1–2, song song Phase 0)

Đây là metric quyết định, không phải benchmark:

- `answer` MCP default → auto-detect fleet CLI backend (`cli:agy|codex|claude`)
  thay vì cần flag; fallback ctxe compose chỉ khi không có CLI nào.
- Usage ledger đã có → thêm `swctx stats --weekly`: đếm ctxe `ask_context`/
  `compose_answer` calls vs swctx calls trên máy anh (parse cả hai phía).
- **Kill-switch (codex+grok đồng thuận): 2 tuần mà ctxe-ask không giảm → dừng
  đầu tư retrieval, swctx chỉ còn vai trò local search miễn phí.**

## Phase 2 — Rescue `in_body_only` (tuần 2–4)

Slice thua thật: fleet pack R@1 3/11 vs ctxe 9/11; linkeldn ctxe slice này
R@5 13/13, swctx miss 3 — đây là thứ ctxe bán tiền.

- **Graph one-hop leg vào `search`**: ContextPack đã expand 1-hop (callers/
  callees/imports) — đưa làm leg phụ có cap, không prepend. Grok round-2 chỉ ra
  `search` hiện không đi qua ContextPack.
- **Concept-flow leg**: chunk-level semantic đã có; thêm docstring/comment
  weighting cho `target_type=doc` misses (vn set vn_to_vn class).
- **Lexicon loop**: mine_queries → VN queries miss thật → bổ sung entry
  (đã làm tay +34 entries ở ce0856c; automate qua usage_events).
- **Discipline**: frozen holdout — 70 câu hiện có chỉ đo, không tune. Probe
  corpus-gate 150 đã nhìn linkeldn → đóng băng, không sweep thêm.

## Phase 3 — Vượt ctxe: tính năng chủ động (tháng 2+)

ctxe là passive index — chờ được hỏi. swctx có thể chủ động vì local+free+watchd:

1. **Prime nâng cấp**: orientation card đã có → thêm "since your last session"
   (git diff → impacted files → precomputed evidence pack). ctxe không có
   cross-session memory.
2. **Auto-checkpoint**: SessionEnd hook → `swctx checkpoint` tự ghi summary +
   dirty files; session sau `prime` có resume-line ngay. Không cần agent nhớ.
3. **Watch-driven precompute**: watcher đã có per-workspace → sau mỗi
   incremental index, refresh hub-symbol PageRank + dirty-path context packs;
   agent hỏi thì trả ngay, không phải đợi compute.
4. **Staleness as feature**: `prime` cảnh báo stale → auto-offer reindex;
   freshness telemetry làm SLA hiển thị (ctxe không báo stale rõ).
5. **Records → decision memory**: đã có global ledger; thêm `search_records`
   ranking + `prime` surface top decisions liên quan cwd (terminal_route_gate
   là ví dụ đầu: ops knowledge phải sống ở đây, không chỉ AGENTS.md).
6. **Fleet CLI compose mặc định**: `answer` qua subscription CLIs — bằng chứng
   cited-R@1 đã thắng ctxe compose; làm cho nó là default trơn, không phải flag.
7. **agent-facing tools ctxe thiếu**: simulate_patch (dry-run impact),
   test_coverage (query → tests liên quan), trace_lookup (log/error → code) —
   harden + viết recipes vào skill để agent dùng thay vì đọc tay.

## Nguyên tắc vận hành (chống scope creep)

- Mỗi phase có gate đo được; fail gate → dừng phase, báo anh — không lùi mục
  tiêu lặng lẽ.
- Không thêm ngôn ngữ indexer mới khi chưa thắng `in_body_only` trên ngôn ngữ
  đã có (audit đồng thuận).
- Bench chỉ đo trên frozen holdouts; tune constants trên mined organic queries.
- py-port parity kèm mỗi thay đổi retrieval (lexicon đã port ce0856c).

## Kill criteria tổng

Dừng đầu tư nếu sau Phase 1+2: (a) ctxe-ask volume không giảm 2 tuần liên tiếp,
(b) `in_body_only` R@1 fleet không cải thiện sau 1 lần thử pre-registered,
(c) reliability gate không xanh ổn định. Lúc đó swctx vẫn giữ giá trị local
search miễn phí — không mất gì ngoài thời gian dev.
