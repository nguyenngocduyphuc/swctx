# swctx overnight master plan — 2026-09-19 00:52 → 07:00 (+ SWE-2 wave ~13:00)

CEO directive: autonomous loop — implement, test with evidence, self-improve
each iteration, spawn subagents, research GitHub/Reddit. Stop at 07:00.
SWE-2 wave (post-review): 4 parallel workers close the remaining gaps —
embed kill-safety, watcher drift, e5-large eval, swctx↔ctxe A/B.

## Objective

Raise measured retrieval quality + operational value of swctx without
breaking verified gates. Every change is adopted or rejected on
vn-probe + recall ratchet + test evidence — never on intuition.

## Fixed gates (must stay green)

- `swift test` — all tests (115)
- `bench/vn_probe.py --gate 12` — no regression vs current auto **13/22**
- `bench/recall_mcp.py --ratchet` — recall@5 ≥0.95, p95 ≤150ms, schema golden
- `bench/cold_cwd.py` — PASS

## Scoreboard (live)

```
start of night:        auto 8/16  (VN 7/14)
ITER-1 folded fill:    auto 10/16 (VN 9/14)
ITER-4 path-phrase:    auto 11/16 (VN 10/14)
probe n=22 (ITER-6):   auto 13/22 (VN 12/19, in_path 9/11, vn_to_en 0/5)
semantic leg health:   sem=1/22 — near-dead on VN, main ceiling
A/B paired (W10):      union swctx+ctxe 17/22; ask_context record-view
                       rescued all sampled swctx misses incl. vn_to_en
```

## Iteration ledger

Each iteration records in JOURNAL.md: hypothesis, diff, measured result,
verdict (ADOPT/REJECT), next lever. Failed experiments stay recorded —
they are evidence, not waste.

## Queue (re-ranked each iteration)

| # | Item | Lever for | Status |
|---|------|-----------|--------|
| Q1 | FTS diacritic handling → folded col + tail-fill + path-phrase leg | VN recall | DONE (+3/16) |
| Q2 | Weighted/score-normalized RRF | fusion | REJECTED (measured) |
| Q3 | SentencePiece port → reranker-v2-m3 spike | rerank ceiling | DONE — v2m3 REJECTED (prose-biased, 160x slower) |
| Q4-Q6 | reranker windows, engine_eval, nightly vn gate | quality/ops | DONE |
| Q7 | p95 clawback | ops | DONE — vector cache + sidecar + parallel legs → p95 102.5ms |
| Q11 | **bge-m3 embedder offline eval** | semantic gap | DONE — GO on recall (4/5 rescued) but REJECTED on latency (~410ms/embed CPU) |
| Q12 | mmap vector matrix beside index.db | cold latency | DONE — sidecar vectors.v1.bin, cold 3.2→0.9s |
| Q13 | CodeRankEmbed-137M spike | semantic gap | backlog — e5-base tried first (bigger, proven multilingual) |
| Q14 | **jina-reranker-v2 spike** (W5) | rerank ceiling | DONE — REJECTED (13/22 neutral, 1567ms/pair). 3/3 rerankers out |
| Q15 | **multilingual-e5-base eval** (W6) | THE semantic gap | DONE — REJECTED (1/9 rescued, 5 regressions, cosine nén 0.78-0.89) |
| Q16 | e5 prefix plumbing (embedQuery/embedDocument) | e5 adoption | ready-if-GO (e5-large still candidate) |
| Q17 | **embed --reindex kill-safety** (W7) | ops | DONE `2a80b14` — persistent vec_snapshot, restore-on-entry |
| Q18 | **watcher schema-drift exit** (W8) | ops | DONE `09c1978`+`90087a3` — ledger check + abort(), Store meta guard |
| Q19 | **e5-large-instruct eval** (W9) | THE semantic gap | DONE `d2691ed` — REJECTED: 5/9 rescued but 5 evicted = net churn 0; MPS 21.6ms inside gate |
| Q20 | **swctx↔ctxe A/B harness** (W10) | dual-engine goal | DONE `9be4b95` — union 17/22, L1/L2 thesis confirmed by paired data |
| Q9 | Merkle-tree sync | freshness | backlog |
| Q10 | per-intent recall reporting | eval depth | DONE — vn_probe splits by query_intent/path_signal |

## Worker assignments

- **W7:** embed kill-safety — DONE, persistent snapshot adopted (`2a80b14`).
- **W8:** watcher drift — DONE, ledger+abort adopted (`09c1978`); lead Store guard `90087a3`.
- **W9:** e5-large-instruct eval — DONE, REJECTED (net churn 0; `d2691ed`).
- **W10:** A/B harness — DONE (`9be4b95`): parity only at find_definitions;
  ctxe no NL-retrieval surface; L2 rescues L1 misses at 200-600× cost.
- **W4/W5/W6:** complete (bge-m3 NO-GO latency; jina REJECTED; e5-base REJECTED).
- **W1/W2/W3:** complete (SentencePiece byte-exact; research; v2m3 rejected).

## Self-improvement loop

After each iteration: journal verdict → re-rank queue by measured
leverage → pick next. On gate failure: revert only the offending
change, record why, continue. On context pressure: keep journal
self-sufficient (numbers + file refs), compact plan.
