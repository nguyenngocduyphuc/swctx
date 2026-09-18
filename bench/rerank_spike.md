# rerank_spike — cross-encoder rerank stage for swctx

Date: 2026-09-19 · measured on the live `8.P8_SEO_Clean` + `18.CRM-Nam-Pham`
indexes · swctx bin: `.build/release/swctx` · model:
`amberoad/bert-multilingual-passage-reranking-msmarco` → CoreML fp16

## TL;DR

**Conditional ADOPT — as a pinned/promote stage, not a pure rescoring.**
The pipeline works end-to-end (CoreML parity verified, ~14 ms/pair,
~0.4 s per 30-candidate query) and the signal is real: it rescued
`seo-01` (pool rank 10 → 2) and `seo-07` (6 → 4) in the final snapshot,
and deeper-pool rescues on earlier snapshots (46 → 2, 43 → 1). But
**pure rescoring is net-neutral** (recall@5 8/16 → 8/16): the model is a
2019-era multilingual-uncased MS MARCO ranker trained on English *prose*,
and its prose-bias actively demotes correct code hits (`seo-02` 1 → 13,
`crm-02` 3 → 6). Pinning the top-1..3 hybrid hits and reranking the tail
captures the upside at **9/16 (+1)** with only `crm-02` lost.

Two structural bounds cap everything: only **10/16** expected files ever
reach the 30-candidate pool (rerank cannot rescue what fusion never
fetches), and the model itself is the weak link — a stronger multilingual
reranker (`bge-reranker-v2-m3`) is the obvious upgrade but needs a
SentencePiece tokenizer port, the same blocker `vn_model_spike.md` hit
for MiniLM/e5/bge-m3 embeddings.

## Acquisition & conversion

HF repo files: `config.json` (BertForSequenceClassification, 2 labels —
classifier weight verified `(2,768)`), `vocab.txt` (105,879 entries),
`pytorch_model.bin` (669 MB). Despite the model card's "single value"
prose, the checkpoint really is a 2-logit classifier; English sanity
pairs confirm **logit[1] = relevant** ("capital of france" + Paris doc →
`[−3.03, +2.96]`).

```
venv (python3.12) + torch 2.14.0 + transformers 4.46.3 + coremltools 9.0
m = BertForSequenceClassification.from_pretrained(src)
traced = torch.jit.trace(wrapper_returning_logits,
                         (ids_i32, mask_i32, types_i32))
ct.convert(traced,
    inputs=[TensorType("input_ids",       (1, RangeDim(1,512)), int32),
            TensorType("attention_mask",  (1, RangeDim(1,512)), int32),
            TensorType("token_type_ids",  (1, RangeDim(1,512)), int32)],
    outputs=[TensorType("logits")],
    compute_precision=FLOAT16, minimum_deployment_target=macOS15,
    convert_to="mlprogram")
→ ~/.swctx/models/amberoad-bert-multilingual-reranking-msmarco/model.mlpackage (319 MB fp16)
```

Script: `bench/convert_reranker.py` (parity check built in: max |logit
diff| vs transformers = 0.0105 across 3 pairs — fp16 rounding, ranking
identical).

**Shape failures (worth recording):**
- `RangeDim(1,16)` on the **batch** dim converted "successfully" but
  produced *input-invariant* logits (identical `[−0.38, 0.81]` for every
  input — the embedding gather silently disconnected). Dynamic batch is
  not trustworthy here; verify parity, don't trust exit codes.
- `EnumeratedShapes([(1,512),(8,512),(16,512)])` fails inside the ct 9.0
  torch frontend: the int32→int64 input casts hit
  `_cast → only 0-dimensional arrays can be converted to Python scalars`.
- Working recipe: batch fixed at 1, seq `RangeDim(1,512)`; Swift batches
  via `MLModel.predictions(fromBatch:)` (MLArrayBatchProvider, chunks of
  16) — real batch API, no dynamic batch dim needed.

## Tokenizer — required a WordPiece change

`WordPieceTokenizer` gained `stripAccents` + `splitCJK` flags (defaults
preserve existing behavior — bge-uncased and distiluse paths are
unchanged). The multilingual-**uncased** vocab contains **zero accented
forms** (verified: no combining marks under NFD anywhere in 105,879
entries), so HF's `BasicTokenizer` recipe for this family is lowercase +
accent strip + CJK split. Without the strip, "kiểm/chấm/đội" tokenize to
`[UNK]` — the VN collapse all over again. `đ/Đ` survive stripping (no
canonical decomposition — the vocab treats đ as a base letter and even
has `đuoc`, `đong`, `đoi`).

`tokenizePair(a,b)` added: `[CLS] a [SEP] b [SEP]` with segment ids
(0 through the first SEP, 1 after) and HF `longest_first` truncation to
512 total — drops tail pieces of the longer side.

## Implementation

- `Sources/SwctxCore/Reranker.swift` (new) — lazy `Reranker.shared` +
  `warm()`; `score(query:doc:)` → logit[1]; `scoreAll` batches of 16 via
  `predictions(fromBatch:)`; `docContext(path:symbol:content:)` = path +
  symbol + first 10 lines of the chunk, ≤1800 chars (the 512-token budget
  is shared with the query; the head is where a chunk's identifying text
  lives). Output resolved by name `logits`, fp16 read via NSNumber
  accessor.
- `Sources/SwctxCore/BGEEmbedder.swift` — tokenizer flags +
  `tokenizePair` (above). Existing init signatures unchanged.
- `Sources/swctx/main.swift` — `swctx rerank <ws> <q> [--limit N]
  [--batch B]`: mirrors `search --mode auto` leg selection
  (identifier-shaped → `includeVector:false` + empty-pool fallback),
  builds the candidate pool via **`Search.hybridCandidates(limit:N,
  poolLimit:N)`** — the seam Worker B added for exactly this stage —
  joins `chunks.content` for doc text, reranks, prints JSON
  (`rank`, `hybrid_rank`, `score`, `path`, … + `rerank_ms`,
  `ms_per_pair`).
- `bench/rerank_eval.py` — per-query baseline (`search --mode auto
  --limit 5`) vs rerank pool → top-5; file-level recall@5, pool ceiling,
  latency; saves full hit lists for offline strategy simulation.

## Numbers (final snapshot)

Baseline `Search` code changed twice mid-spike (concurrent worker); the
authoritative run below is one clean snapshot (`Search.swift`
7459907b…, `swctx` rebuilt once, all 32 CLI calls on that binary). An
earlier snapshot under a weaker baseline read 6/16 → 7/16 (+1) at pool
30 and 6/16 → 8/16 (+2) at pool 50 — direction consistent.

| id | lang | baseline rank@5 | rerank rank@5 | pool ceiling |
|---|---|---|---|---|
| seo-01 | vi | — | **2** | 10 |
| seo-02 | vi | 1 | 10 ✗ | 1 |
| seo-03 | vi | 1 | 1 | 1 |
| seo-04 | vi | — | — | — |
| seo-05 | vi | — | — | — |
| seo-06 | vi | — | — | — |
| seo-07 | vi | — | **4** | 6 |
| seo-08 | en | 3 | 1 | 2 |
| crm-01 | vi | — | — | — |
| crm-02 | vi | 3 | 6 ✗ | 16 |
| crm-03 | vi | 2 | 1 | 2 |
| crm-04 | vi | — | — | — |
| crm-05 | vi | 1 | 2 | 1 |
| crm-06 | vi | 1 | 2 | 1 |
| crm-07 | vi | 1 | 2 | 1 |
| crm-08 | en | — | — | — |

**recall@5: baseline 8/16 (50%) → rerank 8/16 (50%), Δ 0**
gained `seo-01`, `seo-07` · lost `seo-02`, `crm-02`
pool coverage 10/16 · VN 7/14 → 7/14 · EN 1/2 → 1/2

**Integration strategies** (simulated offline from saved hit lists):

| strategy | recall@5 | note |
|---|---|---|
| pure rescoring | 8/16 | Δ0 — demotes top hits (seo-02 1→10) |
| **pin top-1** | **9/16** | **+1** — head pinned, tail reranked |
| pin top-2 / top-3 | 9/16 | +1 (same; crm-02 unrescuable) |
| pin top-5 | 8/16 | pinning eats the rescue slots |
| promote score>2 only | 9/16 | +1 |
| blend 0.5·score + 0.5·rank | 9/16 | +1 |

Every safe variant converges to **+1/16**: two real rescues minus
`crm-02`, which the model refuses to rank above prose docs no matter the
scheme. **pool=50** arm: coverage 11/16, recall 8/16 → 8/16 pure
(rescues `crm-01` 10→1 but drops `seo-02` 1→13 — net wash); pin-1 there
would land ~9-10/16.

**Latency** (release build, M-series, fp16, seq ≈ actual pair length):
13.9 ms/pair p50 (16.8 p95) · **417 ms p50 per 30-pair query** (505 p95)
· 657 ms for 50. Model load+compile ~1 s once per process (`warm()`).
Baseline `search --mode auto` runs ~0.54 s warm on the CRM workspace, so
a 30-pair rerank adds ~75% end latency per call — smaller inside the
long-lived MCP server where both models stay warm.

## Caveats / honest bound

- n=16, Δ=+1: directional, not statistically tight. The per-query moves
  (10→2, 6→4 rescues; 1→13, 3→6 demotions) are the real signal.
- Doc-side input = path + symbol + first ~10 lines (≤1800 chars) — file
  names like `cham_cong.py` are strong tokens for a file-level metric;
  chunk-level precision may differ.
- Prose-bias is structural, not a threshold problem: MS MARCO training
  prefers passage-like text; audit/markdown chunks outrank correct code
  on borderline queries (`crm-02`, `seo-02`).
- `pool coverage` is the dominant bound — 6/16 expected files never
  reach the 30/50-candidate pool; a better reranker cannot fix recall
  there (fusion/legs/chunking problem, same conclusion as
  `vn_model_spike.md`).
- `Reranker.shared` lazy singleton; CLI constructs a fresh instance per
  process — the MCP path would use `shared` (one ~1 s load ever).

## Verdict

**ADOPT the stage in pinned form; treat this model as the floor.**

- Ship as **pin top-1..3 + rerank tail** (or score>2 promote-only):
  measured +1/16 with one regression (`crm-02`) vs pure rescoring's ±0
  with two. Never replace the top hits outright — this model demotes
  correct code hits.
- The seam is already there (`Search.hybridCandidates` + `chunks.content`);
  `swctx rerank` is the reference implementation, `Reranker.shared` the
  drop-in for `Tools.search` if the lead wants it live.
- Cost: 319 MB on disk, ~1 s one-time load, ~0.4 s per 30-pair query —
  acceptable for agent-facing search.
- **Re-spike with `bge-reranker-v2-m3` when a SentencePiece tokenizer
  lands** — it is the standard multilingual upgrade (VN-native, trained
  on code-adjacent data); this amberoad model is the honest lower bound.
  `bench/rerank_eval.py` makes that a one-command re-measurement.
- If the bar for adoption is "+2 or more on n=16," the honest read of
  this model is REJECT — the stage design is still validated and the
  eval harness stands.

## Rollback / reproduce

Model lives outside the repo (`~/.swctx/models/amberoad-bert-
multilingual-reranking-msmarco/`); deleting it makes `swctx rerank`
error cleanly and touches nothing else. `Reranker.swift`, the
`RerankCmd` subcommand, and the tokenizer flags are additive — removing
them reverts to exact prior behavior (`stripAccents`/`splitCJK` default
off; `tokenizePair` unused). Reproduce:
`python3 bench/convert_reranker.py --src <hf-dir> --out ~/.swctx/models/
amberoad-bert-multilingual-reranking-msmarco/model.mlpackage --install`
then `python3 bench/rerank_eval.py --pool 30`.

## Final eval on merged Phase A/B code (2026-09-19, bench/rerank_eval_final.json)

Re-run after the ranking-signal merge (BM25F + PageRank + coverage), as
the spike baseline had been a moving target:

- Baseline auto recall@5 on final code: **8/16** (BM25F batch added +1
  over the 7/16 path-boost baseline).
- Pure rescoring of the 30-pool: **net-neutral 8/16→8/16** — gained
  seo-01 (-→2) and seo-07 (-→4), demoted seo-02 (1→10) and crm-02
  (3→6). Confirms the spike finding that un-pinned rescoring hurts
  already-correct code hits.
- Pinned production mode (top-3 fused hits pinned, tail rescored —
  what `search rerank=true` does): simulated from the recorded pool +
  scores → **9/16 (+1)**: seo-01 and seo-07 gained, crm-02 still lost
  (its best chunk sits at pool rank 25 — outside the pin and scored
  only 1.21; short-VN-query weakness of mBERT-2019, not a design flaw).
- Latency: 13.8ms/pair p50 → ~0.4s per call. `rerank` stays opt-in.
