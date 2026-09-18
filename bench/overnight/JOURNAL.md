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
