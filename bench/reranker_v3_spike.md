# Spike: jinaai/jina-reranker-v2-base-multilingual on vn_queries — REJECTED

Date: 2026-09-19 (third multilingual reranker candidate; Vera uses this
exact model for local code search and reports MRR@10 0.28→0.60)
Eval: `bench/rerank_eval_v3.py` → `bench/rerank_eval_v3.json`,
**22 queries** (expanded probe), recall@5 file-level, pool =
`hybridCandidates` top-30 — identical methodology to
`rerank_eval_v2m3.py` / `rerank_eval_v2.json`.

## Numbers

| | baseline | amberoad mBERT (`rerank`)† | bge-reranker-v2-m3 (`rerank2`)‡ | jina-v2-multilingual (`rerank3`) |
|---|---|---|---|---|
| recall@5 | **13/22 (59%)** | ~neutral (16-set) | 7/16 (44%) | **13/22 (59%)** |
| ms/pair p50 | — | 17.6 | 2816.8 | **1566.7** (p95 2057.9) |
| rerank total p50 | — | 503ms | 81,575ms | 33,321ms |
| gained | — | none | none | crm-10 |
| lost | — | seo-02 | seo-02, seo-07, crm-02 | crm-01 |

† amberoad was measured on the old 16-query set (~neutral, pinned
top-3 gain absorbed by folded legs); not re-run on 22 here.
‡ v2m3 ran at older Search semantics on the 16-query set — its 44%
number is not directly comparable to the 22-query baseline.

vi leg: 12/19 → 11/19; en leg: 1/3 → 2/3.
Pool ceiling: 15/22 expected files inside the 30-pool. Both baseline
and jina hit 13/15 in-pool — the ceiling was again not the
bottleneck; jina's single in-pool failure beyond the loss is crm-04
(expected at hybrid 17 → rerank 10).

## What jina does better than v2m3

Rank-1 precision on code is markedly sharper: it promotes the
expected file to rank 1 on 8 queries (seo-01, seo-03, seo-07, seo-08,
crm-03, crm-05, crm-06, seo-11, crm-09) — v2m3 managed this on 4.
Gains like crm-10 (hybrid 10 → rerank 3, with sibling code files
push_d1/pull_d1 taking the top-2) show it does prefer code when the
semantic match is strong. Code-trained lineage (Vera's results)
shows up in ranking *quality*, just not enough to clear the bar.

## Why it's still rejected

Same prose-over-code bias as v2m3, milder dose:

- **crm-01** (the loss, 2→10): `cham_cong.py` (−0.93) outscored by
  `audit-daily-checklist/notes.md` (−0.38) and three AUDIT_*.html/md
  docs — NL-plausible, wrong for code search.
- **seo-02** (1→5): the exact failure signature v2m3 exhibited —
  HANDOFF_CODEX_TO_CLAUDE (+0.74), PENDING_ACTIONS_REGISTRY (+0.43),
  DRIFT_LOG (+0.32) all ranked over `p8_link_health.py` (−0.12).
- **crm-02** (1→5) and **crm-04** (pool 17→rerank 10): same pattern —
  research/plan/audit prose outranks the target script.

Verdict criteria required ≥14/22 with zero losses, or ≥13/22 with
≥2 gains at ≤300ms/pair. Result: 13/22, +1 gain / −1 loss,
1566.7ms/pair p50 — REJECT on both quality and latency.

## Implementation (verified)

- Tokenizer: **byte-exact** vs HF tokenizer.json (SPTokenizer +
  fairseq mapping `unk→3`, else `+1`), asserted on 3 pairs
  (RerankerV3Tests). jina ships no `.model` — its unigram vocab is
  piece-for-piece identical to BGE-M3's `sentencepiece.bpe.model`
  (same XLM-R 250k family), which is what gets installed.
- Conversion parity: **max |Δlogit| 0.0019** on 4 pairs incl. 2
  Vietnamese; remapped-stock vs jina's own modeling code
  bit-identical (≤3e-7) — see caveats below.
- Pair encoding: standard XLM-R `[0]+q+[2,2]+d+[2]`, no query/doc
  prefixes; single logit → score (sigmoid would preserve ordering).

## Conversion caveats (for any future retry)

- Jina's `modeling_xlm_roberta.py` (fused `mixer.Wqkv`, einops
  `rearrange` inside attention) jit.traces fine but hits a
  coremltools `aten::Int` failure on shape scalars. Workaround in
  `bench/convert_reranker_v3.py`: remap safetensors into the STOCK
  HF `XLMRobertaForSequenceClassification`
  (`mixer.Wqkv`→`self.{q,k,v}` split, `emb_ln`→`embeddings.LayerNorm`,
  `mixer.out_proj`→`attention.output.dense`, `norm1/norm2`→LayerNorms,
  `mlp.fc1/fc2`→`intermediate/output.dense`, `encoder.layers.`→
  `encoder.layer.`), verified ≤3e-7 vs jina's forward — then the
  v2m3 recipe works unchanged.
- **CPU-bound**: ~1567ms/pair p50 (per scored pair incl. window
  expansion; ~850ms per actual forward). ~1.8× faster than v2m3's
  568M but still ≥1000ms/pair — opt-in only at that cost, same
  caveat as v2m3 (no ANE residency on the traced HF graph).
- Model: 531MB mlpackage fp16; init ~4-6s; `warm()` covers it.
- maxTokens=512 (pair budget), RangeDim(1,1024) declared.

## Artifacts

- `Sources/SwctxCore/RerankerV3.swift` — mirrors RerankerV2;
  dirName `jina-reranker-v2-base-multilingual`.
- `swctx rerank3` CLI (main.swift) — spike command, no MCP wiring.
- `Tests/SwctxCoreTests/RerankerV3Tests.swift` — 3 tests, XCTSkip
  when model absent.
- `bench/convert_reranker_v3.py` — remap→jit.trace→ct.convert
  mlprogram fp16, `--verify-jina` self-check.
- `bench/rerank_eval_v3.py` / `bench/rerank_eval_v3.json`.
- `~/.swctx/models/jina-reranker-v2-base-multilingual/` (531MB
  mlpackage + mlmodelc + spm) — safe to delete; nothing references
  it in production paths.

## Consequence for roadmap

All three multilingual cross-encoders are now measured: amberoad
mBERT ~neutral, bge-v2-m3 7/16 prose-biased, jina-v2 13/22 =baseline
with better rank-1 precision but identical prose bias on marginal
queries and ≥1s/pair cost. Cross-encoder reranking with general
multilingual rerankers is a dead end for this probe — the losses are
vocabulary/domain-bound, not model-capacity-bound. Any next lever
needs either a code-specific reranker or a different mechanism
(e.g., pool-side fixes for the 7 out-of-pool misses, which no
reranker can rescue).
