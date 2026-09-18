# swctx overnight master plan — 2026-09-19 00:52 → 07:00

CEO directive: autonomous loop — implement, test with evidence, self-improve
each iteration, spawn subagents, research GitHub/Reddit. Stop at 07:00.

## Objective

Raise measured retrieval quality + operational value of swctx without
breaking verified gates. Every change is adopted or rejected on
vn-probe + recall ratchet + test evidence — never on intuition.

## Fixed gates (must stay green)

- `swift test` — all tests
- `bench/vn_probe.py` — no regression vs current auto 8/16 (VN 7/14)
- `bench/recall_mcp.py --ratchet` — recall@5 ≥0.95, p95 ≤150ms, schema golden
- `bench/cold_cwd.py` — PASS

## Iteration ledger

Each iteration records in JOURNAL.md: hypothesis, diff, measured result,
verdict (ADOPT/REJECT), next lever. Failed experiments stay recorded —
they are evidence, not waste.

## Queue (re-ranked each iteration)

| # | Item | Lever for | Status |
|---|------|-----------|--------|
| Q1 | FTS query-side diacritic expansion (folded term OR-union, mirrors trigram approach; index-side remove_diacritics unavailable — SQLite 3.43.2 < 3.45) | VN recall | ITER-1 |
| Q2 | Weighted RRF fusion (per-leg weights; symbol leg ↑ for identifier-ish queries, sem leg ↑ for NL queries) — the lever agy flagged vs rejected window widening | VN + EN recall | ITER-1 |
| Q3 | SentencePiece tokenizer port → unlock bge-reranker-v2-m3 + bge-m3 (fixes crm-02-class losses; agy review recommended when needed) | reranker ceiling | worker-W1 |
| Q4 | Reranker doc clipping (~400 tok around symbol; agy flagged >512 truncation noise) | reranker quality | ITER-4 |
| Q5 | engine_eval paired records wired into rerank path (convention exists, unused) | paired-data flywheel | ITER-4 |
| Q6 | nightly.sh += vn_probe (regression net for VN leg) | ops | ITER-4 |
| Q7 | p95 latency clawback (46→111ms from BM25F batch — profile hot query) | ops | ITER-5 |
| Q8 | GitHub/Reddit research: 2025-26 on-device multilingual rerankers, RRF weighting evidence, FTS diacritic tricks | plan input | worker-W2 |
| Q9 | Merkle-tree sync (claude-context) — watcher miss safety net | freshness | backlog |
| Q10 | intent tags in vn_queries → per-intent recall reporting | eval depth | backlog |

## Worker assignments

- **W1 (subagent_general, bg):** SentencePiece unigram tokenizer port —
  `Sources/SwctxCore/SPTokenizer.swift` + tests validating token IDs
  against Python sentencepiece reference on bge-m3 vocab. Isolated
  files; no edits to Search/Store/Tools.
- **W2 (subagent_explore, bg):** research scan — newest multilingual
  rerankers runnable on-device (CoreML/ONNX small), weighted-RRF
  evidence, FTS5 diacritic workarounds, code-retrieval SOTA 2025-26.
  Read-only; returns cited findings.
- **agy (orca terminal):** design review of Q2 weighted-fusion plan
  before implement (second set of eyes on the fusion math).

## Self-improvement loop

After each iteration: journal verdict → re-rank queue by measured
leverage → pick next. On gate failure: revert only the offending
change, record why, continue. On context pressure: keep journal
self-sufficient (numbers + file refs), compact plan.
