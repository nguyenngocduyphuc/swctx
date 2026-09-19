# Kế hoạch tối ưu — mục tiêu: swctx tốt hơn ctxe trên mọi trục đo được

> Nền: `06-SO-SANH-CTXE.md` + `bench/engine_ab.md` + `parity_probe`.
> Quy tắc: mọi hạng mục đều phải có gate đo được; không đoán, không thêm
> feature không có bằng chứng cần. Cập nhật 2026-09-19 sau khi đo full
> surface (22 tool) + full miss coverage (9/9 ask rescue).

## Bảng điểm hiện tại — đo thật

| Trục | swctx | ctxe | Trạng thái |
|---|---|---|---|
| NL retrieval | search 13/22 @ ~100ms, $0 | không có surface free | **swctx thắng** |
| find_definitions | 3/4 @ 12ms | 3/4 @ 7ms | hòa chất lượng, **thua 5ms** |
| find_usages | 3/2/0 | 3/1/0 | **swctx ≥** |
| inspect_path / fetch_chunks / graph | parity | parity | hòa |
| get_impact | dependents hydrated | chỉ hop+score | **swctx thắng** |
| list_workspaces | 23 (mọi index) | 9 (catalog) | khác semantics |
| Telemetry adoption | usage_events + `swctx stats` | không có | **swctx thắng** |
| Privacy/cost/ops | local-only, $0, 1 binary | server + credits + daemon | **swctx thắng** |
| **Synthesis** | context_pack deterministic | ask_context cứu **9/9 miss** | **ctxe thắng — gap lớn nhất** |
| **vn_to_en retrieval** | 0/5 | (cứu qua synthesis) | **ctxe thắng** |
| fast_understand | card deterministic | answer + planner LLM | **ctxe sâu hơn** |
| compose_answer | không có | verified live 10.5s | **ctxe-only** |

**Union 22/22** — nhưng mục tiêu mới: swctx một mình phải đạt coverage
đó local-only, ctxe chỉ còn là optional fallback.

## Workstreams — xếp theo expected value

### W11 · vn_to_en translation leg (retrieval gap lớn nhất, rẻ nhất)

- **Vấn đề đo được**: 5/22 miss toàn bộ là `vn_to_en` — query tiếng Việt,
  code tiếng Anh. 4 embedder multilingual đã chứng minh không cứu được
  (e5-large net 0, bge-m3 quality GO nhưng 410ms/embed vượt gate).
- **Phương án**: leg retrieval thứ 5 — dịch query VN→EN qua **Ollama
  local** (`qwen2.5:3b` đã pull sẵn, ~1-2s) → FTS/semantic trên bản dịch
  → RRF merge với leg gốc. Chỉ chạy khi query có dấu VN (phát hiện rẻ).
  Cache bản dịch vào `meta` để query lặp không trả giá.
- **Gate**: vn_probe ≥16/22 search-only (hiện 13/22, target cứu ≥3/5
  miss), p95 hybrid không vượt ~700ms warm (dịch async song song legs,
  hoặc pre-translate ngoài critical path), không regression câu có sẵn.
- **Fallback nếu probe fail**: từ điển thuật ngữ VN→EN curated cho domain
  (seo/crm/code) — thô nhưng deterministic, 0 latency.

### W12 · Local synthesis — `swctx answer` (beat ctxe ở sân nhà)

- **Vấn đề**: ctxe ask_context cứu 9/9 miss mà retrieval thuần không với
  tới. Đây là lý do duy nhất còn cần ctxe. swctx cần L2 của riêng mình.
- **Phương án**: tool `answer` mới —
  `search(expand)` + `graph_neighbors` + `fetch_chunks` → evidence pack
  → **Ollama local** (`qwen2.5:3b` mặc định ~1.9GB; `Qwopus 27B Q4` có
  sẵn cho quality mode) → answer kèm file citations → persist thành
  record (`put_record kind=ask`, đúng pattern durable-record của ctxe).
- **Gate**: chạy 9 miss hiện tại qua `swctx answer`, rescue ≥6/9 ở
  evidence level; answer phải cite đúng expected_path. Latency target
  <30s cho 3B model. Zero credits, zero network.
- **Rủi ro**: chất lượng 3B << server LLM — nếu rescue <6/9 thì thử
  Qwopus 27B (chậm hơn nhưng vẫn local), hoặc chấp nhận ctxe làm
  fallback đúng thiết kế L2.

### W13 · fast_understand nâng cấp (parity ctxe synthesis)

- Card deterministic hiện tại → optional `--synthesize` pipe qua Ollama
  → prose orientation như ctxe. Rẻ vì W12 đã có plumbing LLM.
- **Gate**: cùng query, output phải chứa ≥ cùng facts với card
  deterministic (không mất độ chính xác khi thêm prose).

### W14 · find_definitions latency parity (12ms → <8ms)

- Nhỏ nhưng là chỗ duy nhất ctxe nhanh hơn ở retrieval. Profile call
  path (index open? PRAGMA? symbol lookup join?) → trim. Chỉ làm khi
  profile chỉ ra headroom rõ; 12ms đã đủ nhanh cho agent.

### W15 · Reranker revisit — gated by telemetry

- usage_events đang thu. Khi đủ data (vài ngày), nhóm zero-hit queries
  theo class → nếu là "đúng file có trong top-10 nhưng rank thấp" thì
  reranker local (nhẹ, code-aware) mới có nghĩa. Không re-open trước
  khi có evidence — 3 cross-encoder đã bị loại bằng đo.

### W16 · Packaging + corruption gates (đã có trong plan cũ)

- `release.sh`: build → install → selftest → tag.
- Nightly inject corrupt sidecar/model → expect graceful, không crash.
- Giữ nguyên, làm sau W11/W12.

## Nguyên tắc không phá

1. Local-only: mọi thành phần mới chạy on-device (Ollama là local).
2. Telemetry không bao giờ nằm trên response path.
3. Không đụng index schema trừ khi migration có kế hoạch drift-safe.
4. Mọi claim "tốt hơn ctxe" phải kèm số đo trên probe/harness hiện có.
5. ctxe vẫn được giữ làm L2 fallback — win condition là "không cần",
   không phải "xóa".
