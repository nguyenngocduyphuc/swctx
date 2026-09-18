# Spike: BAAI/bge-reranker-v2-m3 on vn_queries — REJECTED

Date: 2026-09-19 (W3 worker, overnight loop ITER-4)
Eval: `bench/rerank_eval_v2m3.py` → `bench/rerank_eval_v2m3.json`,
16 queries, recall@5 file-level, pool = `hybridCandidates` top-30
(same pool semantics as `rerank_eval_v2.json`; ran at eb689ec Search
semantics — comparable baseline 10/16).

## Numbers

| | baseline | amberoad mBERT (`rerank`) | bge-reranker-v2-m3 (`rerank2`) |
|---|---|---|---|
| recall@5 | **10/16 (62%)** | 9/16 (56%) | **7/16 (44%)** |
| ms/pair p50 | — | 17.6 | **2816.8** (p95 4651) |
| rerank total p50 | — | 503ms | 81,575ms |
| gained | — | none | none |
| lost | — | seo-02 | seo-02, seo-07, crm-02 |

Pool ceiling identical (10/16 expected files inside the 30-pool) —
the ceiling was not the bottleneck for either reranker.

v2m3 beats amberoad on 4 queries (seo-08, crm-05/06/07 — all rank-1
wins) and loses on 3. The losses are instructive: for `seo-02` it
ranked `PENDING_ACTIONS_REGISTRY.md` (+1.05) and an old handoff doc
(+0.96) over `p8_link_health.py` (−3.01); for `crm-02` it preferred
`HANDOFF-CRM-20260724.md` — semantically-correct NL answers, wrong
for code search. Its scoring is sharper/more confident than
amberoad's, which amplifies the prose-over-code bias that our
`path\nsymbol\ncode` doc format invites.

## Root cause: domain mismatch, not implementation

- Tokenizer: byte-exact vs HF `XLMRobertaTokenizer` (SPTokenizer
  + fairseq mapping `unk→3`, else `+1`); asserted on 3 pairs.
- Conversion parity: max |Δlogit| 0.0028 on 4 VN pairs.
- The model is trained for NL passage reranking; it confidently
  prefers prose docs over code files for "which script does X".

## Limitations (for any future retry)

- **CPU-bound**: traced HF graph (~1900 ops) schedules entirely on
  CPU under every `compute_units` — 0.4s @ seq64 → 12s @ seq1024.
  ANE residency requires the tcashel-style Conv2d/BC1S/LayerNormANE
  port + weight transfer (their recipe ports 12-layer
  bge-reranker-base, not v2-m3's 24-layer 568M).
- Eval pool ceiling 10/16 — rerank cannot rescue misses outside
  the pool.
- Init ~7–11s (1.1GB compile + first predict); `warm()` covers it.

## Artifacts kept (reference impl, opt-in only)

- `Sources/SwctxCore/RerankerV2.swift` — mirrors `Reranker`; pair
  encoding `[0]+q+[2,2]+d+[2]`, longest_first truncation at 512.
- `swctx rerank2` CLI (main.swift) — spike command, no MCP wiring.
- `Tests/SwctxCoreTests/RerankerV2Tests.swift` — 3 tests, XCTSkip
  when model absent.
- `bench/convert_reranker_v2m3.py` — jit.trace → ct.convert mlprogram
  fp16, `input_ids`+`attention_mask` int32 (1, RangeDim(1,1024)).
- Model dir `~/.swctx/models/bge-reranker-v2-m3/` (1.1GB mlpackage +
  1.1GB mlmodelc) — safe to delete; nothing references it in
  production paths.

## Consequence for roadmap

Cross-encoder reranking is not the next lever at this eval size —
both available multilingual rerankers are prose-biased. The 5
remaining probe misses are vocabulary/semantic-bound (seo-04/05/06,
crm-08) or competition-bound (crm-04). Next levers per W2 research:
a code-aware reranker/embedder (CodeRankEmbed-137M, nomic BERT —
may load on the existing WordPiece stack) or Qwen3-Reranker-0.6B
(needs a second tokenizer: Qwen BPE).
