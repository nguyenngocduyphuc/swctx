# Overnight journal — 2026-09-19

## ITER-1 (00:52–01:35): FTS diacritic expansion → folded tail-fill — ADOPTED

**Hypothesis:** VN queries can't reach ASCII index text (unicode61 folds
case only; đ U+0111 never folds even with remove_diacritics=2).

**Attempt 1 — unscoped query-side expansion (REJECTED):** emitting
`"xac"*` variants into the shared FTS MATCH dropped auto 8/16→7/16 —
folded noise occupied slots in the `limit*3=15` window and pushed
seo-02's expected file out of the fused pool. Same mechanism as the
rejected `limit*12`: extra candidates in a shared window always cost.

**Attempt 2 — folded column at 0.6 weight, same-window (REJECTED):**
v6 migration adding `folded` col; still 7/16 — cheap weight reduces
noise score but not noise COUNT in the window.

**Attempt 3 — folded rescue as tail-filler (ADOPTED):** `fts()` runs
primary query first; when under-filled, a column-scoped
`folded : "term"*` query tops it up. Folded matches can never displace
real hits — the trigram contract, applied to diacritics.

**Measured:**
- vn_probe auto: **8/16 → 10/16 (62%)**; VN 7/14 → **9/14 (64%)**
- seo-02 restored, seo-01 gained (2), seo-07 gained (3 — folded fill
  surfaced WORKFLOW.md into the FTS leg); zero regressions
- fts leg 7/16 → 8/16; ratchet PASS 0.9722 / p95 100.6ms / schema 20;
  cold_cwd PASS; 85/85 tests + `testFoldedTailFillRescuesDiacriticQuery`

**Weighted-RRF sweep (REJECTED):** global w_sem↑ hurt in every combo
(6/16); w_fts↑ neutral. Per agy review + W2 research: uniform RRF stays;
score-normalized fusion rejected outright (pool truncation means rank
140–800 targets never reach ANY fusion formula; cosine-vs-BM25
min-max breaks). `SWCTX_RRF_W` env hook kept for future sweeps.

**Files:** Store.swift (v6 folded col, schemaVersion=6),
Indexer.swift (folded insert), Search.swift (ftsQuery revert,
ftsFoldedQuery, ftsRun two-tier, 4-col bm25), RankingSignalTests.

## Research inputs landed

- W2 scan: `remove_diacritics=2` exists since SQLite 3.27 (our 3.43.2
  has it) but **never folds đ** → app-level folded column was correct.
- Reranker upgrade path: Qwen3-Reranker-0.6B (best VN+code, Apache-2.0,
  needs Qwen BPE) vs bge-reranker-v2-m3 (SentencePiece — W1 port in
  flight, has published CoreML recipe). ViRanker is VN-specific BGE-M3.
- Reranker doc feeding: head-segment + sliding-window max-pool is the
  documented best practice (Elastic/Cohere) — feeds ITER-4 clipping.
- Fusion: arXiv 2210.11934 tuned convex-combination ≥ RRF but needs
  calibration data we don't have; Dancer (TSE'24) fusion on code
  searchers +35-550% MRR — worth revisiting when we have more legs.

## Queue after ITER-1

1. ~~Q1 FTS diacritic expansion~~ → DONE as folded tail-fill (+2/16)
2. ~~Q2 weighted RRF~~ → REJECTED by measurement
3. W1 SentencePiece port → in flight (unlocks bge-reranker-v2-m3)
4. Q4 reranker clipping (head+window max-pool) → next
5. Q5 engine_eval records wiring → next
6. Q6 nightly += vn_probe → next
7. Q7 p95 clawback (100.6ms — BM25F+folded cost) → after
8. NEW: per-class fusion (VN-diacritic-gated sem boost) — agy's
   remaining variant; low priority after folded tail-fill landed
9. NEW: Qwen3-Reranker-0.6B spike (needs BPE tokenizer port — second
   tokenizer; evaluate vs bge-v2-m3 once W1 lands)
10. NEW: CodeRankEmbed-137M embedding spike (nomic BERT → may load
    with existing WordPiece tokenizer; code-specialized embedder)

## ITER-2 (01:10–01:40): reranker windows + engine_eval + nightly + pool-semantics fix — ADOPTED

**Found+fixed a real bug:** `swctx rerank` CLI passed `limit: 30` into
hybridCandidates → legs fetched 90-deep — exactly the rejected
`limit*12` pattern (deep noise fuses a DIFFERENT ordering than the
baseline page; crm-02's expected sat at pool rank 25 while baseline
rank 3). Fixed to `limit: 5, poolLimit: N` — pool now extends the
production ordering, pin semantics are meaningful. MCP path was
already correct.

**docWindows + scoreAllMax (head+tail, max-pool):** per Cohere/Elastic
long-doc practice. Cost ~2x/pair on long chunks (17.6→~20ms).

**engine_eval wiring:** divergence-triggered `put_record
kind=engine_eval` (baseline_top5 vs rerank_top5 + ms + head_sha +
anchors, dual-write). Verified live over MCP wire: "sổ tay ghi chú"
diverged → 1 record written. No-op reranks record nothing.

**nightly += vn_probe --gate 9:** VN regression net (baseline 10/16).

**Honest rerank verdict after folded tail-fill:** baseline absorbed
the reranker's previous +1 — pinned mode on consistent pool is now
NEUTRAL 10/16 (zero gains, zero losses). Pure rescore still −1.
Rerank stays opt-in; its remaining value is hard-NL rescue, not a
default win. mBERT-2019 ceiling confirmed — the lever is a stronger
reranker (W1's SentencePiece → bge-reranker-v2-m3), not more tuning
of this model.

**Tests:** 86/86 (SPTokenizerTests excluded — W1 in flight).

## ITER-3 — Vector-cache latency clawback (~02:00)

**Change (ADOPT):** process-level `VectorCache` for the semantic leg.
Store is created per tool call, so the 32K×768 float32 matrix (~100MB on
P8) was re-read + re-joined from SQLite on EVERY semantic/hybrid call.
Now: contiguous matrix cached per workspace (LRU×4, 512MB cap), validated
by `meta.embeddings_epoch` nonce (Indexer bumps once per index/embed run),
scored in one `cblas_sgemv`, and chunk metadata fetched only for top-k
instead of joined for all 32K rows.

**Measured (persistent MCP, P8 32,677 chunks):**
- semantic warm: ~130ms → ~50ms (2.6×; residual ≈ query-embed inference)
- hybrid warm: ~160ms → ~80-140ms typical
- profile: embeddings blob scan 56ms/py-loop was the dominant leg cost;
  metadata fetch 0.3ms, min/max pagerank 0.7ms
- ratchet: PASS — recall@5 0.9722 unchanged, p95 105.7ms, schema golden PASS
- vn_probe: auto 10/16, vi 9/14 — unchanged (rank wiggles inside score
  ties: sgemv reduces in different fp order than vDSP_dotpr)
- tests: 99/99 (testEmbeddingsEpochSignatureChanges, testVectorCacheBox)

**Known limits (honest):** one-shot CLI calls don't benefit (cache dies
with the process); legacy indexes without an epoch get a count/max-id
signature that misses same-id re-embeds until the next index run; first
semantic call per workspace still pays the full matrix load (~60-130ms).
Candidate next lever: mmap'd matrix file beside index.db so cold CLI
calls skip the blob decode too.

**Rejected during profiling:** none — but confirmed folded tail-fill is
already gated (`hits.count < limit`), no wasted second query.

Pending: W3 bge-reranker-v2-m3 CoreML spike (f8e96b7a) still running.

## ITER-4 (~02:10–02:35): folded-path rescue variants → path_tokens PHRASE leg — ADOPTED (+1/16)

**Target:** crm-01-style misses where the only signal is the folded
FILENAME (`cham_cong.py` for query "chấm công"). Verified in SQLite:
`path_tokens : "cham cong"` phrase matches all 22 cham_cong chunks.

**Rejected variants (all zero-sum at n=16):**
1. Folded term-OR merged into primary MATCH → 7/16 (path noise floods
   window — same limit*12 mechanism)
2. Folded-path hits appended to fts leg tail → 9/16 (weak leg-ranks
   can't rescue but still displace seo-07 — asymmetric failure)
3. Symbol-leg folded subtoken probe → dead end (cham_cong.py symbols
   are merge_events/build_payload — filename tokens aren't IN symbols)
4. Dedicated folded-path term-OR leg (w sweep 0.4-1.0, file-dedup,
   no-double-dip boost) → every config 10/16: rescues crm-01 OR keeps
   seo-07, never both — HANDOFF doc's filename match on "quy trinh
   chuan" is equally strong; rescue & displacer sit at same fused
   threshold. STRUCTURAL: crm-01 and seo-07 are mirror cases.
5. Phrase leg on `folded` column (weight 0.6) → 10/16 identical to
   baseline: phrase matches exist but bm25 score too weak, expected
   file ranked 11 inside the leg, below the cap-5 dedup cut.

**ADOPTED — adjacent folded PHRASE on path_tokens column:**
`ftsFoldedPhraseQuery` emits `path_tokens : "cham cong"` per adjacent
token pair whose fold differs (diacritic queries only), OR'd, fed as a
4th RRF leg (cap 5, weight 0.8, file-deduped). Phrase precision kills
the term-OR flood; path_tokens weight 2.5 gives filename intent real
score; leg separation keeps it out of the fts window entirely.

**Measured:** vn_probe auto **10/16 → 11/16 (69%)**, VN 9/14 →
**10/14 (71%)** — crm-01 rescued miss→rank 2, seo-07 kept at rank 5
(pushed but not displaced). All prior hits held. Ratchet PASS
(0.9722, p95 125.7ms, schema 20). 102/102 tests.

**Remaining misses (5):** seo-04/05/06 (cross-language vocab gap —
"ảnh"↔"image" needs better multilingual semantic, W3 in flight),
crm-04 (dong_vong.py — folded path term exists but phrase "dong vong"
never adjacent in query), crm-08 (en_control symbol lookup gap).

**Lesson:** at n=16 the folded-PATH space is zero-sum UNLESS precision
is phrase-level AND scoring column is path_tokens (not folded 0.6).
Term-OR on any column = flood; phrase on weak column = no rank.

### ITER-4 addendum (~02:45): pair-window fix + crm-04 diagnosis + W3 verdict

- **Bug fix kept:** `foldedPhraseQuery` used `toks.prefix(12)` which
  truncated tail pairs — crm-04's "đóng vòng" sits at tokens 13-14 and
  was never emitted. Now iterates all pairs, caps at 16 emitted terms.
  Probe unchanged (11/16) but coverage is strictly more correct.
- **crm-04 diagnosed, not fixable lexically:** `path_tokens:"dong vong"`
  matches dong_vong.py at leg rank 2, but its RRF contribution
  (0.8/62 ≈ 0.013) can't reach fused top-5 (~0.05) against genuine
  content matches (CEO/đối-soát prose docs). Raising the leg weight
  ~4x would re-trigger seo-07 displacement — same zero-sum wall.
- **seo-06 confirmed pure vocab gap:** query "đội hạm" vs file
  "doi-ngu" (đội ngũ) — different words, no fold bridge exists.
- **W3 bge-reranker-v2-m3 spike: REJECTED** (bench/reranker_v2m3_
  spike.md): 7/16 vs baseline 10/16, 0 gains/3 losses, 2817ms/pair
  (~160x amberoad), CPU-bound 81.5s/call. Domain mismatch — prose-
  biased cross-encoder. Code kept as opt-in reference (`rerank2`),
  not wired to MCP. Both available multilingual rerankers now proven
  prose-biased → rerank path closed pending a code-aware model.

**Remaining 5 misses are semantic/vocab-bound** (seo-04 ảnh↔image,
seo-05 entity mesh, seo-06 đội hạm↔đội ngũ, crm-08 EN→VN symbol,
crm-04 competition). Lexical iteration exhausted at 11/16 — next
lever is embedding-side (CodeRankEmbed/bge-m3 via SPTokenizer, or a
code-aware reranker), not more FTS surgery.

## ITER-5 (~03:05): parallel search legs — ADOPTED (latency only)

**Change:** `hybridCandidates` runs fts + semantic + symbol + phrase
legs concurrently via DispatchGroup on a global queue (no signature
change — stays sync throws). DatabasePool gives each read its own
connection; query-embed inference (CoreML ~35ms CPU) overlaps FTS IO.
Error behavior preserved: first error throws after group.wait().

**Measured (persistent MCP, P8, warm):**
- VN hybrid "quy trình chuẩn…": ~150-165ms → 105-125ms (~30%)
- VN hybrid "chấm công…": ~143-165ms → 94-99ms (~35%)
- EN hybrid "canonical check": ~80-90ms → 73-97ms (marginal — EN legs
  already cheap; first-call slightly worse: concurrent cold cache load)
- vn_probe: 11/16 — identical recall (same legs, same hits, only timing
  changed). Ratchet PASS 0.9722 / schema 20. p95 135ms (vs 125.7 — the
  ratchet p95 includes non-search + colder calls; under gate, logged).
- 102/102 tests.

**Honest note:** the remaining VN hybrid cost is now fts-bound (~60-80ms
for 12-token OR × 4 bm25f columns) — semantic+phrase hide inside it.
Next latency lever would be FTS-side (smaller window, co-term stats),
not more parallelism.

**W4 (bge-m3 offline eval, 2f35bd1f): in flight.**

### ITER-5b (~03:20): vector sidecar file — ADOPTED (cold-start)

`vectors.v1.bin` beside index.db: flat header(magic|dim|count|sig) +
ids + row-major matrix, validated by the same embeddings_epoch
signature. Cold semantic calls skip 32K blob decodes — one sequential
~100MB read. Self-heals: first blob-path load writes it atomically;
epoch bump → signature mismatch → ignored + rewritten.

**Measured (P8, cold CLI):** semantic search 3.21s → 0.92s (3.5x;
residual is model load + embed). Scores identical — vn_probe 11/16,
composition unchanged. Test: testVectorSidecarRoundTrip (round-trip +
stale-sig + dim + truncation rejects). Cost: +100MB disk per index.

### Ops check (~03:40): watcher binary drift — FIXED

Found: the 6 launchd watchers had been running since ~21:40 — before
the v6 folded-column migration (01:08). They held the pre-v6 binary
image; any file event would have written new chunks with an EMPTY
`folded` column → folded tail-fill silently weakening per-file.
Restarted all 6 via `launchctl kickstart -k` (jobs unchanged — no
consolidation). `swctx status` on P8: healthy, 1 stale file pending,
pending_embeddings=0. Lesson for runbook: watchers must be restarted
after any schema-migration release — worth a `--watchers-restart`
hint in `index` output or install_agent docs.

### ITER-6 (~04:00): vn_queries expansion 16→22 — eval instrument upgrade

Added 6 verified queries (expected files confirmed indexed + read for
purpose): seo-09/10 (vn_to_en hard), seo-11 (in_path doc), crm-09
(in_path code), crm-10 (en→VN file), crm-11 (vn_to_en).

**New baseline: 13/22 (59%), VN 12/19, in_path 9/11 vs in_body_only
4/11, vn_to_en 0/5.**

Immediate information yield:
1. **Phrase leg generalizes** — seo-11 (ke-hoach.md) and crm-09
   (kiem_he_thiet_ke.py) both hit rank 1 on files never seen during
   tuning. The mechanism isn't overfit to cham_cong.
2. **vn_to_en 0/5** — the semantic ceiling quantified: every VN→EN-file
   query misses on all legs. This is THE number a multilingual
   embedder must move (W4 measures exactly this).
3. **New failure class found:** crm-10 fts=4 auto=- — a real fts-leg
   hit displaced out of the fused top-5 by other legs' noise. The
   opposite failure of rescue-miss: fusion DAMAGE, not absence.
   Candidate lever if it recurs: single-leg hit protection (a chunk
   ranked top-5 in ANY leg keeps a floor), but n=1 — watch first.

n=22 makes zero-sum conclusions weaker — the instrument was the
bottleneck for the last few iterations, now less so.

Correction: crm-10 is NOT fusion damage — fts leg rank 4 → fused ~0.015
vs cutoff ~0.078 (dominated by higher fts ranks + multi-leg hits). A
competitive miss, not displacement; the "single-leg floor" idea is
unnecessary at this evidence level.

Nightly gate updated: --gate 9 → --gate 12 (baseline 13/22 on the
expanded probe — catches one-query regression).

### Research note (~04:20): jina-reranker-v2-base-multilingual

Vera (local Rust code-search, BM25+vector+rerank, MRR@10 0.28→0.60)
uses `jinaai/jina-reranker-v2-base-multilingual` as its cross-encoder —
a third multilingual reranker candidate we have NOT tried (XLM-R →
SPTokenizer already proven byte-exact). Their embedder is
jina-embeddings-v5-text-nano-retrieval with CodeRankEmbed-onnx as the
code-specific option (better retrieval, slower indexing — same tradeoff
we'd face). Takeaway: our two reranker failures (amberoad + v2m3) are
model-choice failures, not a wrong architecture — the next reranker
spike should be jina-v2-base-multilingual via the existing SPTokenizer.

### ITER-7 (~05:20–06:10): bge-m3 embedder + jina reranker — hai verdict NO-GO-vì-latency

**bge-m3 embedder (W4 GO-quality → production NO-GO-latency).**
W4's offline eval crossed the quality gate decisively: bge-m3 (CLS+L2,
1024-d) rescued **4/5 dead-leg misses** into top-30 — seo-04 r11,
seo-05 r1, seo-06 r1, crm-04 r5 — where distiluse scores 1/22. Caveat
from W4 confirmed by design: must stay an additive leg (pure dense
regresses 3 currently-passing queries; ours is additive via RRF — fine).

Adoption path executed: EmbeddingModelSpec +tokenizer kind (wordpiece|
sentencepiece), BGEEmbedder dispatches to SPTokenizer (W1's byte-exact
XLM-R tokenizer — reused, no new tokenizer code), spec registered,
convert_bgem3.py produced the mlpackage with **cos(HF,CoreML)=0.9999+**.

Then production reality killed it: **~410ms/embed on every compute unit**
(CPU_ALL/GPU/NE — XLM-R 24L/1024H runs CPU-bound under CoreML on this
machine; 1151-chunk CRM re-embed ran ~19min before SIGTERM, ~1s/chunk).
3-7x over the p95=150ms query gate → REJECTED as live embedder, same
shape as v2m3: quality clears the bar, latency clears nothing. Spec
stays registered (opt-in offline use); CRM index restored from backup
(the killed re-embed had wiped its vectors — incident noted: batch-2000
single-transaction re-embed is all-or-nothing on kill).

**jina-reranker-v2-base-multilingual (W5): 13/22 → 13/22 net-neutral.**
gained crm-10, lost crm-01; 1566ms/pair (~100x amberoad's 15ms). Third
reranker REJECTED — the pattern is now conclusive on this hardware:
cross-encoders trade hits symmetrically here at 50-200x latency cost.
Vera's +0.32 MRR does not transfer to our VN docs+code corpus.

**Next lever (W6 in flight)**: `intfloat/multilingual-e5-base` (278M,
768-d, mean-pooling + query:/passage: prefixes) — quality near bge-m3
class at ~half the size → plausibly inside the latency gate. Same
offline harness, same >=2-misses gate.

**Miss-class map after tonight** (13/22 baseline, probe n=22):
- in_path 9/11 — folded-phrase leg owns this class
- in_body_only 4/11 — semantic-bound
- vn_to_en 0/5 — the wall: needs a working multilingual vector space
- symbol_lookup 2/4
