# swctx self-tuning loop — kế hoạch khép kín

Mục tiêu: swctx tự đo → tự phát hiện yếu điểm → tự đề xuất tune → chỉ adopt
khi qua gate. Con người/agent chỉ phê duyệt, không tune tay.

Codex independent review 2026-09-20: **CHAN** — 3 fixes đã implement:

1. ~~Implicit gold từ fetch_chunks~~ → **biased**: fetch chứng minh
   "agent dùng thứ search tìm ra", không phải đáp án đúng. Sửa: đổi tên
   thành `implicit_utility` (positive-unlabeled data), tách khỏi `gold`
   manual; telemetry đã thêm `session`/`top_paths`/`arg_path` để link
   causal đúng (search → fetch cùng session, arg_path ∈ top_paths).
   `COUNT==1` không chứng minh organic — dùng session + không-lặp thay.
2. ~~Sweep trên cả 3 manifest~~ → **selection bias**: linkeldn/fleet đã
   thành validation chứ không blind. Sửa: `optimize.py --tune-on vn22`
   chỉ select trên tune set; holdouts confirm-only; exit 1 khi gate fail;
   stale output bị reject; p95 gate ±10%.
3. Điểm gãy đầu tiên = loop tự tối ưu trên tín hiệu biased của chính nó
   → holdout KHÔNG BAO GIỜ chọn knob; VERIFY pre-adoption, one-shot.

## Vòng lặp

```
SENSE ──► MINE ──► LABEL ──► SWEEP ──► GATE ──► ADOPT ──► VERIFY
usage      zero-hit  gold    optimize  4 gates  default   untouched
_events    +organic  vs      --tune-on  exit≠0            one-shot
           implicit_utility
```

### 1. SENSE — done [f530384 + telemetry enrichment]
`usage_events(ws, tool, latency_ms, hits, ok, query, session, top_paths,
arg_path, ts)`. session = UUID per MCP process; top_paths = JSON top-5
hit paths; arg_path = follow-up target (path hoặc chunk_ids JSON).
ctxe residual spend: `~/.ctxe/indexes/*/records.db` kind='ask'.

### 2. MINE — next: `bench/mine_queries.py`
- Zero-hit searches (hits=0) → manifest với expected_path=null (đếm
  zero-hit rate, không tính R@5).
- `implicit_utility`: search event E theo sau bởi fetch_chunks/
  inspect_path có arg_path ∈ E.top_paths trong CÙNG session+ws ⇒
  candidate gold với `confidence: implicit_utility`.
- Organic ≠ implicit: organic = query xuất hiện ở ≥1 session khác nhau
  (bench queries chạy 1 process lặp ×N, cùng session hoặc rõ pattern).

### 3. LABEL — implicit_utility ≠ gold
Stratified sample của implicit_utility cần verify tay trước khi merge
vào manifest `gold`. Manifest schema: `confidence: verified|implicit_utility`;
optimize.py có thể gác weight thấp hơn cho implicit.

### 4. SWEEP — done, gated
`optimize.py`: `--tune-on` selects winner; confirm manifests measured
for the gate only. Freshness: output file mtime phải > run start,
subprocess rc≠0 → harness exit 2.

### 5. GATE — code trong optimize.py, exit≠0 khi fail
1. best > baseline R@5 trên TUNE set
2. zero per-query R@5 regression trên MỌI manifest
3. confirm sets non-inferior (R@5 không tụt, margin 0)
4. search p95 tune-set không xấu >10%

### 6. ADOPT — bake default + `swift test` + HANDOFF note

### 7. VERIFY — one-shot, pre-adoption
Holdout chưa-từng-tune (workspace mới index). Tụt ⇒ rollback.

## Metric vận hành (đo được ngay)
- `ctxe-dependency rate` = asks mới/tuần → mục tiêu →0. Tuần này:
  ~42 ask thật (P8 22, site-M 11, linkeldn 5) + 48 bench.
- `zero-hit rate`, `organic implicit-utility coverage`, p50/p95 per
  tool (`swctx stats`: search p50 142ms vs ctxe ask p50 35s ≈ 250×).

## Việc còn lại (value order)
1. `bench/mine_queries.py` — đóng SENSE→SWEEP.
2. T7 nốt: watcher freshness + killed-reindex recovery.
3. T8/W15 reranker spike — gate: VN body-only R@5 tăng trên confirm,
   p95 < ~1.5s.
4. Arg-level parity (spec §22), edge kinds mở rộng.
