# vn_model_spike — multilingual embedding model spike for swctx

Date: 2026-09-18 · spike outcome measured on the live `8.P8_SEO_Clean` +
`18.CRM-Nam-Pham` indexes · swctx bin: `.build/release/swctx`

## TL;DR

**Adopt `distiluse-base-multilingual-cased-v2`** — with honest expectations.
The Vietnamese semantic leg went from provably dead (bert-uncased vocab →
`[UNK]` noise, 0/14 by construction) to a working leg: every VN probe target
improved ~10–50× in vector rank (e.g. 9864→144, 13492→631 of 32644 chunks)
and one query is now rescued outright (crm-06, rank 1). It is also ~2.5×
faster per embed (6.9ms vs 18.6ms p50) at the same 768-d/storage layout.

But recall@5 barely moved: semantic VN 0/14 → 1/14, auto VN 5/14 → 5/14.
The spike's real finding: **after the tokenizer fix, vector recall on this
corpus is ranking/chunking-bound, not model-bound** — exactly the bound the
baseline probe predicted. The next lever is ranking/fusion/chunking work,
not another embedding model. The English control regressed (rank 5 → 99),
so EN-only workspaces may prefer to stay on bge — the per-index binding
supports mixing.

## Why distiluse and not the brief's first choice

The brief preferred `paraphrase-multilingual-MiniLM-L12-v2` on the premise
that its vocab is multilingual-BERT WordPiece. **That premise is wrong** —
verified against its `tokenizer.json`: the model uses a **Unigram
(SentencePiece) tokenizer**, 250037-entry vocab, `<s>`/`</s>`/`<unk>`
specials. A drop-in CoreML package does exist
(`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2@a39062b`,
`coreml/feature-extraction/float32_model.mlpackage`) but our WordPiece
tokenizer cannot feed it, and porting a Unigram Viterbi tokenizer +
precompiled-charsmap normalizer is the same "tokenizer port" the brief
declared out of spike scope for bge-m3.

Surveyed alternatives:

| model | CoreML package | tokenizer | verdict |
|---|---|---|---|
| paraphrase-multilingual-MiniLM-L12-v2 | ✅ official | Unigram SentencePiece | needs tokenizer port — out of scope |
| multilingual-e5-small (4 ports) | ✅ community | XLM-R SentencePiece BPE | same blocker |
| granite-embedding-97m-multilingual | ✅ experimental | SentencePiece BPE | same blocker |
| bge-m3 (4 ports) | ✅ community | XLM-R SentencePiece | excluded by brief |
| LaBSE | ❌ none | WordPiece (bert, 500k vocab) | convertible, heavy |
| **distiluse-base-multilingual-cased-v2** | ❌ none → **converted** | **WordPiece bert-multilingual-cased, 119k** | ✅ chosen |

distiluse-v2: DistilBERT 6-layer, 768-d, mean pooling, `vocab.txt` ships in
the HF repo, `do_lower_case:false`/`tokenize_chinese_chars:true` — our
WordPiece tokenizer covers it by adding a cased mode (no lowercasing, CJK
chars split to single tokens). Covers 50+ languages incl. Vietnamese.

## Acquisition & verification

Converted locally (no prebuilt package exists):

```
venv (python3.12) + torch 2.14 + transformers 4.46.3 + coremltools 9.0
m = DistilBertModel.from_pretrained("sentence-transformers/distiluse-base-multilingual-cased-v2")
traced = torch.jit.trace(wrapper_returning_last_hidden_state, (ids_i32, mask_i32))
ct.convert(traced,
    inputs=[TensorType("input_ids", (1, RangeDim(1,512)), int32),
            TensorType("attention_mask", (1, RangeDim(1,512)), int32)],
    outputs=[TensorType("last_hidden_state")],
    compute_precision=FLOAT32, minimum_deployment_target=macOS15,
    convert_to="mlprogram")
→ ~/.swctx/models/distiluse-base-multilingual-cased-v2/model.mlpackage (514MB fp32)
```

Note: coremltools ≥6 has no ONNX frontend, so ONNX→mlpackage is out; the
PyTorch-trace path above is the working recipe (transformers 5.x hits an
unimplemented `new_ones` op — pin 4.46.x). `vocab.txt` +
`tokenizer_config.json` downloaded from the same HF repo.

**Parity check**: CoreML `last_hidden_state` == transformers output exactly
(max abs diff 0.0, cosine 1.0) on 4 texts; mean-pooled cosine VN↔EN
paraphrase 0.81 vs 0.10–0.20 for unrelated text. The Swift search path
reproduces the same top-15 scores to 3 decimals, so the ported tokenizer is
output-equivalent to HF's on these inputs.

## Implementation (all inside owned files)

- `BGEEmbedder.swift` — now spec-driven: `EmbeddingModelSpec{id, dim,
  dirName, cased, pooling}` + `WordPieceTokenizer` (uncased = current exact
  behavior; cased = no lowercase, CJK split). `embed()` feeds only the
  inputs the model declares (DistilBERT has no `token_type_ids`), resolves
  the output by name (`hidden_states`→`last_hidden_state`→first
  dim-matching multiarray), and pools per spec (CLS or attention-mask mean).
- `Embedder.swift` — model registry + selection precedence
  `index binding > --model flag > SWCTX_MODEL > default(bge)`.
  `Embedder()` instances get a *fresh* backend (Indexer's
  `embedder = Embedder()` CoreML-failure retry must really recreate the
  MLModel); only `Embedder.shared` uses the backend cache and re-resolves
  the active model per call, so query paths follow the opened index.
- `Store.swift` — `meta.embedding_model`/`embedding_dim` written once at DB
  creation (guarded `files==0` so schema-migrated legacy DBs aren't
  mislabelled); absent = legacy bge/768. `Store.init` publishes the binding
  (`Embedder.bindModel`) so `Search.semantic(store:embedder:shared)` uses
  the index's model without touching Search/Tools. `setEmbeddingBinding`
  for explicit re-bind.
- `main.swift` — `swctx index|embed --model <id>` (+`SWCTX_MODEL`);
  flag-on-bound-index mismatch errors with the `--reindex` remedy;
  `embed --reindex --model X` wipes + rebinds. `swctx model list` /
  `model install <id> [--from <mlpackage>]` (bge downloads prebuilt;
  distiluse needs `--from` since no public conversion exists).

## Numbers

Probe (`bench/vn_probe.py`, recall@5, same binary, same corpus):

| scope | fts | semantic | auto |
|---|---|---|---|
| VN before (bge) | 5/14 (36%) | **0/14 (0%)** | 5/14 (36%) |
| VN after (distiluse) | 5/14 (36%) | **1/14 (7%)** | 5/14 (36%) |
| EN before / after | 1/2 | 1/2 → 0/2 | 1/2 |

Vector rank of expected file (identical chunks, direct cosine over all
32644 stored vectors — verified equals the CLI path):

| query | bge rank | distiluse rank |
|---|---|---|
| seo-01 vi | 9864 | **144** |
| seo-02 vi | 5039 | **1908** |
| seo-03 vi | 3931 | **171** |
| seo-04 vi | 4953 | **294** |
| seo-05 vi | 4975 | **1120** |
| seo-06 vi | 13492 | **631** |
| seo-07 vi | 1795 | **852** |
| seo-08 en | **5** | 99 |

Every VN target improved ~10–50× and now sits in the top 0.4–6% — the leg
produces real ordering instead of noise. It still doesn't crack top-5 on
this dense corpus (top VN hits score 0.45–0.55 vs targets 0.16–0.43).
`crm-06` (VN query → VN-prose doc `DANG_NHAP.md`) is now a semantic rank-1
hit — the first VN query ever rescued by the vector leg.

Per-embed latency (BGEEmbedder.embed, warm, ~600-char chunk text, n=40):

| model | p50 | p95 |
|---|---|---|
| bge-base-en-v1.5 | 18.6 ms | 27.0 ms |
| distiluse-multilingual | **6.9 ms** | 10.1 ms |

Re-embed wall time: SEO 32644 chunks ≈ 8 min (~70 chunks/s), CRM 1151 ≈ 16 s.

## Caveats / honest bound

- recall@5 needs literal top-5; targets reaching top-0.5% still miss. The
  corpus is unusually dense (32k chunks, ~46% VN-marked markdown), and
  bge→distiluse also shifts EN quality down (en_control 5→99) — distiluse
  is older/weaker on English than bge-en.
- The score distributions differ (bge compresses 0.6–0.8, distiluse
  spreads 0.16–0.55); RRF fusion is rank-based so unaffected, but raw-score
  interpretation isn't comparable across models.
- `auto` fusion did not improve net recall and can still push an FTS #1 out
  of the top-5 (crm-06 auto `-` vs fts `1`) — a ranking problem, not a
  model problem.
- `Embedder.shared` follows the most-recently-opened Store's binding — a
  pragmatic seam because `Search.semantic` gets the embedder, not the
  store's model. In the long-lived MCP server interleaving workspaces with
  different bound models could in theory flip the shared backend mid-call;
  every tool call opens its Store immediately before searching, so this is
  safe in practice (noted for when search code is next touched).
- Mid-run CoreML transient failure observed at ~16k predictions in one
  process (embed() starts returning nil for all inputs). The pre-existing
  `embedder = Embedder()` retry now genuinely recreates the model again
  (the backend-cache bug I introduced is fixed); `swctx embed` in a fresh
  process completed the remainder. Worth a batching/restart strategy if
  embed passes grow.

## Verdict

**Adopt.** The swap repairs a leg that was mathematically dead for
Vietnamese (0% by construction → working ordering, occasional wins, top
~1% ranks everywhere) at strictly lower cost (2.5× faster, same dim and
storage, per-index opt-in). It does not by itself reach good VN recall —
after this change the bottleneck is ranking/chunking/fusion, which is the
correct next work item and is only worth doing once vectors carry real VN
signal.

Adopt path per workspace: `swctx embed --reindex --model
distiluse-base-multilingual-cased-v2 <ws>` (this spike left the two probe
workspaces bound to it). Roll back: same command with
`--model bge-base-en-v1.5`, or restore `index.db.bge-bak` beside each
index.db (`~/.swctx/indexes/{6e09ad5e9099,b1617b66c781}/`).
EN-only workspaces: do nothing — legacy indexes stay on bge by default.
