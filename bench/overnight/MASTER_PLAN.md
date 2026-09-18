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
| Q7 | p95 clawback | ops | PARTIAL — vector cache landed (sem 130→50ms); p95 now 125ms (phrase leg cost) |
| Q11 | **bge-m3 embedder offline eval** — embed 16 queries + full corpus via HF, measure cosine top-30/top-5 before any CoreML investment | THE semantic gap | ITER-5 (worker W4) |
| Q12 | mmap vector matrix beside index.db — cold CLI/MCP-start latency | cold latency | ITER-5 (lead) |
| Q13 | CodeRankEmbed-137M spike (nomic BERT, may fit WordPiece stack; code-specialized) | semantic gap | after Q11 signal |
| Q9 | Merkle-tree sync | freshness | backlog |
| Q10 | per-intent recall reporting | eval depth | backlog |

## Worker assignments

- **W4 (subagent_general, bg):** bge-m3 OFFLINE eval — no Swift changes.
  HF BAAI/bge-m3 in the conversion venv, embed 16 vn_queries + all
  chunks in both live index DBs, report per-query cosine rank of
  expected-file chunks (top-30 pool entry + top-5). Verdict gate:
  invest in CoreML only if it lifts ≥2 of the 5 misses into pool.

- **W1/W2/W3:** complete (SentencePiece landed byte-exact; research
  integrated; v2m3 spike rejected).

## Self-improvement loop

After each iteration: journal verdict → re-rank queue by measured
leverage → pick next. On gate failure: revert only the offending
change, record why, continue. On context pressure: keep journal
self-sufficient (numbers + file refs), compact plan.
