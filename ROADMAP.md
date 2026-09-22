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

## Phase 1 — Reroute calls (baseline displacement ĐÃ có, không cần đo thêm)

Grok audit 2026-09-22 đã đo sẵn từ ledgers thật:

- `usage_events`: **search=781** (fleet đã chuyển retrieval sang swctx),
  **answer=0** (chưa ai gọi synthesis swctx), checkpoint=2
- ctxe `kind=ask` records: **126** và ĐANG TĂNG (42 ở ledger 09-18 → 126 hôm nay)

Vậy việc của phase này không phải "đo" mà là **đổi đường gọi**:

- `answer` MCP default → auto-detect fleet CLI (`cli:agy|codex|claude`),
  fallback ctxe compose chỉ khi không có CLI nào khả dụng.
- Skill `swctx` + AGENTS.md: cấm `ask_context` khi `search`/`context_pack`
  đã đủ (câu bounded) — chỉ cho phép ctxe ask cho multi-round planner thật.
- Sau 14 ngày đọc lại 2 ledger: ctxe ask phải GIẢM so với 126.

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

## Kill criteria tổng (Grok audit, sharpened)

- **Dừng research retrieval** nếu vòng in_body pre-register không thêm ≥3 query
  `in_body_only` vào R@5 trên linkeldn+fleet gộp, HOẶC bất kỳ query nào đã R@5
  rơi khỏi top-5.
- **Dừng đầu tư ngoài bảo trì** nếu sau 14 ngày reroute, ctxe `ask` không giảm
  so với baseline 126 trong khi swctx `answer` vẫn ~0 — nghĩa là fleet không đi
  qua đường mới, tune thêm không đổi hóa đơn.
- **Kill ngay một thay đổi ranking** nếu p95 search linkeldn vượt 2× median
  hiện tại (537ms) mà R@5 không tăng.
- **Không kill binary** vì edge-resolve 23% hay simulate_patch tĩnh — search
  local đã có người dùng (781 calls) và hòa ctxe trên 48 query mù ở R@5.
- **Không mở embedder/reranker mới** (4 embedder + 3 reranker đã thua latency
  hoặc neutral) trừ khi một miss mới chứng minh gold không vào candidate pool.

## Unified dispatch (gộp governance vụn)

Repo đang vá governance theo incident: cmux có `cmux_gui.py` (5 lớp kiểm),
orca có receipt `turn_started`/`retry-request`, 1devtool tách `submit`/`team`,
và `scripts/hooks/terminal_route_gate.py` vừa thêm lớp inject. Hướng đúng là
một `dispatch` entry point duy nhất: detect-self → match project cwd → send →
verify receipt → monitor, bọc cả 3 backend — mỗi backend chỉ khai capability
khác nhau (receipt có/không, queue, read/wait). Làm sau Phase 0, khi ba hệ đã
ổn định contract.

## Operational rules mới (từ audit)

- **`swctx watch restart` sau mỗi lần rebuild binary** — daemon 06:32 chạy
  binary cũ suốt 2 commit (eb41bff, tokenizer) vì không ai restart; launchd
  chỉ respawn khi crash. Cân nhắc `watch install` kiểm binary-hash-vs-running.
- Fix `CTXE_REPLACEMENT.md` + `docs/05-GIOI-HAN.md` khi có JSON regenerate —
  hai file đang overclaim ("100% replacement feasible", "không build planner").
- `bench/tool_schemas.golden.json` còn 20 tools — actual là 26; artifact gate
  cũ không đọc bởi test Swift.
