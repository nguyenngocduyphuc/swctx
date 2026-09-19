# Kế hoạch tối ưu — mục tiêu: swctx tốt hơn ctxe trên mọi trục đo được

> Nền: `06-SO-SANH-CTXE.md` + `bench/engine_ab.md` + `parity_probe`.
> Đã qua 1 vòng Codex review (`/tmp/codex-plan-result.md`, verdict RISKY)
> — bản này là v2 đã khóa gates theo findings F1-F7.
> Quy tắc: mọi hạng mục phải có gate đo được; không đoán.

## Decision record (trả lời F7 — supersede boundary cũ)

`docs/05-GIOI-HAN.md` trước ghi "không build synthesis/planner trong
swctx". **Quyết định mới (CEO, 2026-09-19): ctxe tốn credits → swctx
phải tự đủ L2 local-only.** W12 là product decision đã duyệt; cập nhật
05-GIOI-HAN.md khi W12 land. Win condition: ctxe trở thành optional
fallback, không còn required.

## Bảng điểm hiện tại — đo thật

| Trục | swctx | ctxe | Trạng thái |
|---|---|---|---|
| NL retrieval | search 13/22 @ ~100ms, $0 | không có surface free | **swctx thắng** |
| find_definitions | 3/4 @ 12ms | 3/4 @ 7ms | hòa chất lượng, thua 5ms |
| find_usages | 3/2/0 | 3/1/0 | **swctx ≥** |
| inspect_path / fetch_chunks / graph | parity | parity | hòa |
| get_impact | dependents hydrated | chỉ hop+score | **swctx thắng** |
| Telemetry adoption | usage_events + `swctx stats` | không có | **swctx thắng** |
| Privacy/cost/ops | local-only, $0, 1 binary | server + credits + daemon | **swctx thắng** |
| **Synthesis** | context_pack deterministic | ask_context cứu **9/9 miss** | **ctxe thắng — gap lớn nhất** |
| **vn_to_en retrieval** | 0/5 | (cứu qua synthesis) | **ctxe thắng** |
| fast_understand | card deterministic | answer + planner LLM | **ctxe sâu hơn** |
| compose_answer | không có | verified live 10.5s | **ctxe-only** |

## Exit gate (chốt theo F6 — milestone ≠ exit)

**Exit thật**: 22/22 evidence-level coverage **local-only** trên frozen
vn_probe + holdout mới (không dùng holdout để tune); mọi answer có
citation-valid; không regression trên pass set; zero-network proof.
Baseline giữ riêng: search-only · search+find_defs · +W11 · +W12-3B ·
+W12-27B — không gộp quality 27B với latency 3B.

Milestone: W11 ≥16/22 search-only · W12 rescue ≥6/9.

## W11 · vn_to_en translation leg (hardened F1+F2)

- Ollama `qwen2.5:3b`, output **structured**: `{english_terms: [...],
  protected_tokens: [...], confidence}` — không prose; giữ nguyên
  identifier/path/acronym; reject bản dịch rỗng/quá dài/đổi protected.
- **Hard deadline** cho translation (default ~800ms); quá deadline → trả
  kết quả gốc, leg dịch bị hủy — translation KHÔNG nằm trên critical
  path của kết quả đầu tiên.
- Bản dịch chỉ feed **lexical/path candidate leg** (FTS trên
  english_terms + path_tokens), file-deduped, top-K bounded, weight
  riêng đã tune — KHÔNG chạy translated semantic leg, không uniform
  weight. Query rewrite toàn bộ chỉ là ablation, không phải default.
- Gating: chỉ fire khi query có dấu VN (phát hiện rẻ, deterministic).
- Cache: LRU bounded **ngoài index** (file riêng dưới .swctx/ hoặc
  process cache), key = hash(normalized query + model digest + prompt
  version + mode), TTL + quota rõ — không ghi vô hạn vào `meta`.
- **Gates tách**: `search-original` p95 giữ nguyên ~100-700ms;
  `translation-assisted` đo p50/p95 riêng cold/warm; Ollama down/absent
  → degrade về baseline, không lỗi.
- **Ablation bắt buộc** trên all-22 + holdout: original ·
  +translation-FTS · +translation-hybrid — đo recall@5, per-query
  regression, rank shift.

## W12 · `swctx answer` — local synthesis (hardened F3+F4+F5)

- Contract: **answer trên evidence đã verified** (Codex option 1 —
  planner loop là follow-up riêng nếu W11+W12 không đủ coverage).
- Evidence pack: handle bất biến `[E01] path=… start_line=… end_line=…`
  + content; budget theo item VÀ token (4-8 direct chunks, 2-4 related,
  file-deduped, line window quanh hit); con số chọn bằng đo trên
  context window model.
- Output schema bắt buộc: `{answer, citations:[{evidence_id}],
  limitations}` — claim thiếu evidence phải nói insufficient.
- **Citation validator server-side**: mọi evidence_id phải tồn tại trong
  pack, path/line khớp; citation ngoài pack = invalid; retry đúng 1 lần
  prompt sửa format; không tự chữa path model bịa.
- Metrics tách: (a) target file có vào evidence không (retrieval),
  (b) citation validity, (c) answer đáp intent. `expected_path` không
  bao giờ vào prompt.
- Model policy: 3B default warm; 27B route khi validator fail / answer
  coverage thấp / hard-class query — đo riêng quality+latency từng model.
- Ops: preflight `ollama version` + model digest + memory; semaphore
  concurrency; timeout/kill rõ; **không auto-pull model trong response
  path**; Ollama absent → deterministic pack + structured limitation.
- Record `kind=ask`: query, model/digest, prompt version, legs, evidence
  ids+paths+lines, citations, validator result, latency, limitations;
  record failure không được mất answer.
- Tests: Ollama unavailable, timeout, malformed output, invalid
  citation, cancellation, record-write failure.

## W13 · fast_understand --synthesize (sau W12, tái dùng plumbing)

Card deterministic → optional LLM prose. Gate: output chứa ≥ cùng facts
với card, zero-network.

## W14 · find_definitions latency (12ms → <8ms)

Chỉ làm khi profile chỉ headroom rõ; 12ms đã đủ dùng được.

## W15 · Reranker revisit — gated by usage_events telemetry

Chờ data thật chỉ query class nào fail; 3 cross-encoder đã bị loại.

## W16 · Packaging + corruption gates

`release.sh` build→install→selftest→tag; nightly inject corrupt
sidecar/model expect graceful; **model-availability + Ollama-disabled
fallback là release gate của W12** (kéo sớm, không để cuối).
