# ctxe — Góp ý từ vận hành thực tế

Hai vòng phản hồi dựa trên số liệu đo được trên cùng một máy.
Vòng 2 (2026-09-21): KPI vận hành sau ~1 tuần chạy song song hai engine.
Vòng 1 (2026-09-18): các lỗi cụ thể có thể tái hiện. Xếp theo mức ảnh hưởng
tới người dùng.

---

## Vòng 2 — So sánh KPI vận hành (2026-09-21)

Mọi con số đều đo thật, không ước lượng. Phương pháp: cùng một bộ câu hỏi
chạy mù trên cả hai engine (hash manifest khóa trước khi chấm), chấm
R@k/MRR bằng `tools/swctx/bench/strict_score.py`, latency đo wall-clock
trên các lượt gọi agent thật. Bộ harness mô tả ở cuối — dùng lại được cho
eval phía ctxe.

### Con số chính

| KPI | ctxe | swctx (bản local) | Ghi chú |
|---|---|---|---|
| Recall mù, holdout 48 câu | 38/48 R@5 | **39/48** | manifest khóa hash |
| Câu hỏi ý đồ tên file | 16/24 | **22/24** | gồm cả repo nhiều `page.tsx` |
| Semantic VN chỉ-trong-body | **17/19** | 13/19 | ctxe vẫn dẫn stratum này |
| Latency p50 mỗi ask | **~35s** (p95 ~122s) | ~142ms | wall-clock, call thật |
| Lượng ask quan sát | ~42 asks/tuần | — | từ `~/.ctxe/record_refs.db` |
| Ask fail quan sát được | 3 (vẫn trừ rounds) | — | records ghi trạng thái `failed` |
| Tính deterministic | không | có | cùng query → kết quả khác nhau |

### Đề xuất tính năng (theo thứ tự impact)

1. **Tool `search` thuần, không qua LLM.** Gap có impact cao nhất. Agent
   cần một đường tra cứu lexical/hybrid không chạy planner — đa số call
   hàng ngày ("X nằm ở đâu") không cần synthesis. Bonus: giảm luôn tải
   LLM phía server của anh.
2. **Ranking có nhận biết path/thư mục.** Miss tập trung ở repo nhiều
   convention: `checkin/page.tsx` vs `events/page.tsx` — yếu tố phân biệt
   nằm ở **tên thư mục**, không phải tên file. Nên weight path atoms,
   tách camelCase. swctx đã fix bằng một leg path-probe trong planner —
   rẻ và deterministic.
3. **Tầng retrieval deterministic.** Retrieval nên tái lập được;
   nondeterminism chỉ nên nằm ở synthesis. Khi đó user cache được,
   regression-test được, và tin kết quả hơn.
4. **Cache kết quả / similarity cache.** ~42 asks/tuần, nhiều câu gần
   trùng nhau giữa các phiên. Cache theo embedding của query sẽ cắt cả
   latency lẫn chi phí server của anh.
5. **Latency của planner.** p50 35s giết vòng lặp agent. Nên chạy song
   song các retrieval leg + early-return khi đủ confidence + giới hạn
   số vòng. Bản thân retrieval chỉ tốn vài ms — chi phí nằm ở các vòng
   planner tuần tự.
6. **Filename atoms đa ngôn ngữ.** Đo tuần này: query tiếng Anh vào file
   đặt tên tiếng Việt là điểm mù (0/3 trên một repo chưa từng index).
   Phía local fix bằng lexicon deterministic 0đ ("finished"→{xong,biet},
   "daily report"→{bao,cao,ngay}), gate theo corpus có morpheme Việt —
   unseen-repo từ 8/13 lên 13/13. Đáng kiểm tra gap tương tự phía ctxe.
7. **Chế độ degraded/offline.** Mất mạng hoặc lỗi OAuth = mất hết
   retrieval. Fallback trên index đã cache giúp sản phẩm sống được offline.
8. **Dashboard usage cho user.** Hiện user không tự xem được telemetry
   ask/chi phí của mình — con số 42 asks/tuần ở trên phải đào
   `record_refs.db` mới có.

### Điểm ctxe đang thắng thật

- Recall semantic VN chỉ-trong-body (17/19 vs 13/19) — stack đa ngôn
  ngữ là điểm khác biệt, nên giữ.
- `compose_answer` — tổng hợp lại từ records đã lưu.
- Planner nhiều vòng trên query rộng/mơ hồ, khi nó hội tụ được.

### Bộ harness đánh giá (dùng lại được)

Cơ chế chấm điểm phía trên, nếu hữu ích cho regression suite của anh:

- `bench/strict_score.py` — R@1/R@5/R@10 + MRR theo manifest
  `{query, expected_paths}`; hash manifest ghi trước khi chấm nên test
  không thể bị tune theo chính nó.
- `bench/optimize.py --tune-on/--confirm-on` — sweep tham số với tách
  tune/confirm + 4-gate (không cải thiện ⇒ reject).
- `bench/mine_queries.py` — đào `usage_events` thật (cặp search→fetch có
  quan hệ nhân quả, query zero-hit) thành manifest mới — eval lớn dần
  theo usage thật thay vì query viết tay.
- Kỷ luật unseen-repo: tune trên workspace quen, confirm một lần trên
  repo engine chưa từng index (`20.aiteam`, 13 câu mù — chính chỗ phát
  hiện gap EN→VN).

Các lỗi mức bug từ audit đầu giữ nguyên bên dưới.

---

## Vòng 1 — Các lỗi cụ thể tái hiện được (2026-09-18)

Đã test ctxe 0.4.4 đối chiếu bản local (`swctx`) trên 6 workspace thật.
Mỗi finding có lệnh repro và bằng chứng mức DB.

### 1. `find_definitions` bỏ sót enum top-level (lỗi ranh giới chunker)

**Workspace:** `22.site-M` (index key `a4fc8115d18a`)
**Symbol:** `enum SiteCleanup` khai báo tại
`Sources/SiteM/SiteCleanup.swift:24`, kèm `extension SiteCleanup` tại
`SiteCleanup+Stores.swift:5`.

**Kỳ vọng:** `find_definitions("SiteCleanup")` trả cả hai nơi khai báo.
**Thực tế:** chỉ trả extension — enum không bao giờ thành symbol.

**Bằng chứng trong index.db:** chunk `import SQLite3` (dòng 3→24) nuốt
dòng mở `enum SiteCleanup {`; chunk tiếp theo (24→29) không gắn
`symbol_name`. `symbols WHERE name='SiteCleanup'` chỉ có đúng 1 row —
dòng extension, và type ghi `class` (extension nên là kind riêng).
Enum lồng trong cùng file (`SiteCleanupError`, dòng 389) thì lại có
symbol — nên khả năng: khi chunk preamble trùm dòng mở của declaration
đầu tiên, symbol không được bind. `enum` có thể không phải loại decl
duy nhất bị — nên quét `chunks WHERE symbol_name IS NULL AND content
LIKE 'enum %'` và tương tự.

### 2. `inspect_path` + `query` rerank trong cửa sổ 150 chunk theo thứ tự path

site-M (`path="Sources/SiteM"`, `query="SiteCleanup"`, `limit=3`):
`total_chunks_under_path=3628`, `next_offset=150` — file `SiteCleanup`
sort sau `Agent*`/`AI*` nên không bao giờ vào pool rerank → miss cứng.
Nên rerank cả subtree, hoặc ít nhất FTS-prefilter pool trước khi cắt
window.

### 3. `ctxe daemon` chết âm thầm; watch chỉ là intent

`ctxe daemon status` → `Stopped`, `KeepAlive.SuccessfulExit=0` nên
thoát sạch sẽ không được restart — daemon ngừng watch mà không báo.
`ctxe status` khi đó báo `stale (19 pending)` trên workspace user tưởng
đang live. Nên `KeepAlive` vô điều kiện (kèm throttle), restart
on-demand, hoặc hiện "daemon down" rõ trong `ctxe status`/`get_status`
thay vì chỉ `stale_files`.

### 4. Lookup symbol local tốn ~130-220ms (round-trip server?)

`find_definitions`/`find_usages` đo 84-221ms cho một tra cứu SQLite
local — lẽ ra ~5-15ms. Nếu các call này đi vòng server (auth/telemetry/
rerank), nên có fast-path thuần local cho def/usage — đây là nhóm call
tần suất cao nhất của agent.

### 5. Không có search toàn-workspace không-LLM

Không có tương đương MCP/CLI cho "search cả workspace theo string/symbol"
mà không qua `ask_context` (trừ credit) hoặc `inspect_path` (cần sẵn
path, bị giới hạn window — xem #2). Agent làm "tìm X nằm đâu" cần một
tool `search` lexical/hybrid có giới hạn. `search(workspace, query,
mode)` miễn phí của swctx là tool được gọi nhiều nhất trong thực tế.

### 6. Làm rõ mặt tính phí cho retrieval calls

Theo tài liệu, các retrieval tool (`find_definitions`, `inspect_path`,
`search_records`, `list_workspaces`) có thể bị tính credit. Nếu retrieval
cơ bản bị meter, agent sẽ né ctxe cho lookup thường ngày — meter lý
tưởng chỉ nên áp cho phần LLM server (`ask_context`, `fast_understand`,
`compose_answer`, re-embedding).

---

## Bảng tổng hợp đo được (ngữ cảnh, không phải danh sách lỗi)

| Case | swctx | ctxe | Nguồn |
|---|---|---|---|
| `find_definitions` (2 syms, 2 ws) | 10-17ms | 84-221ms | 3 auditor độc lập |
| hybrid search | 35-49ms | 1.9-2.7s (inspect_path+query) | cùng trên |
| `SiteCleanup` def recall | cả 2 decl site | chỉ extension | cả 3 auditor |
| freshness lúc audit | stale_files=0 | 19+11 pending (daemon down) | cùng trên |
| `fast_understand` | ~0.4s deterministic | ~57s LLM (output giàu hơn) | bench |
| resolved edges | 15.2k (site-M) | 37.1k (site-M) | chất lượng edge thêm chưa chứng minh |
| symbols trích xuất | 18.7k | 9.7k | swctx gồm cả symbol non-code |

Điểm mạnh ctxe đáng giữ: planner `ask_context` nhiều vòng,
`compose_answer` tái tổng hợp từ record, edge graph có confidence,
community detection, budget contract (`omitted_budget`,
`E_OUTPUT_TOO_LARGE`), selector `ref` toàn cục, managed update.

## Môi trường repro

- ctxe 0.4.4 (`~/.local/bin/ctxe`), đã sign-in, trial credits
- swctx local build (`tools/swctx/.build/release/swctx`)
- Cả hai index nằm dưới `~/.ctxe/indexes/` và `~/.swctx/indexes/`
  cùng workspace hash (`a4fc8115d18a` = 22.site-M)
- Audit spec/parity đầy đủ: `tools/swctx/CTXE_SPEC.md`
