# swctx overnight master plan — 2026-09-19 00:52 → 07:00

CEO directive: autonomous loop — implement, test with evidence, self-improve
each iteration, spawn subagents, research GitHub/Reddit. Stop at 07:00.

## Objective

Raise measured retrieval quality + operational value of swctx without
breaking verified gates. Every change is adopted or rejected on
vn-probe + recall ratchet + test evidence — never on intuition.

## Fixed gates (must stay green)

- `swift test` — all tests
- `bench/vn_probe.py` — no regression vs current auto **11/16** (VN 10/14)
- `bench/recall_mcp.py --ratchet` — recall@5 ≥0.95, p95 ≤150ms, schema golden
- `bench/cold_cwd.py` — PASS

## Scoreboard (live)

```
start of night:        auto 8/16  (VN 7/14)
ITER-1 folded fill:    auto 10/16 (VN 9/14)
ITER-4 path-phrase:    auto 11/16 (VN 10/14)
semantic leg health:   sem=1/16 — near-dead on VN, main ceiling
remaining misses:      seo-04/05/06 (vocab gap), crm-04 (competition),
                       crm-08 (EN→VN symbol)
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
| Q15 | **multilingual-e5-base eval** (W6) | THE semantic gap | IN FLIGHT — quality near bge-m3 at ~52ms CPU torch (~fits gate) |
| Q16 | e5 prefix plumbing (embedQuery/embedDocument) | e5 adoption | ready-if-GO |
| Q9 | Merkle-tree sync | freshness | backlog |
| Q10 | per-intent recall reporting | eval depth | DONE — vn_probe splits by query_intent/path_signal |

## Worker assignments

- **W4:** bge-m3 offline eval — DONE, GO-quality/NO-GO-latency verdict.
- **W5:** jina reranker spike — DONE, REJECTED (artifacts committed).
- **W6:** e5-base offline eval — IN FLIGHT, same harness + gate.
- **W1/W2/W3:** complete (SentencePiece byte-exact; research; v2m3 rejected).

## Self-improvement loop

After each iteration: journal verdict → re-rank queue by measured
leverage → pick next. On gate failure: revert only the offending
change, record why, continue. On context pressure: keep journal
self-sufficient (numbers + file refs), compact plan.
