# CTXE → swctx — Replacement Ledger

> **Purpose:** ctxe is credit-metered. This file records exactly what each paid
> function is, what it costs, and what swctx covers — so that when ctxe spending
> stops, nothing is silently lost.
> Compiled 2026-09-18 against ctxe 0.4.4 + swctx 0.1.0; **revised 2026-09-22**
> to measured state (blind-holdout numbers + live usage telemetry).
> Evidence classes as in CTXE_SPEC.md: **[live]** observed, **[bench]**
> measured, **[src]** source.

---

## 1. The ctxe bill — what actually consumes credits

ctxe charges for **server work**, not local reads. Local index.db reads are
free per call — but useless without the paid index behind them.

| Function | Server work | Credit meter | swctx replacement | Status |
|---|---|---|---|---|
| `index_workspace` | `voyage-code-4` embeddings + enrich, per file | **paid every index/refresh** | `swctx index` — tree-sitter + on-device BGE CoreML | **replaced** — free, unbounded |
| `ask_context` | `/v2/reason` planner, 3–48 rounds + compose | **paid per Ask** | `swctx answer` (extractive pack) + `context_pack` + `--plan`/`--backend cli:*` (local planner / agent-CLI synthesis) | **retrieval replaced**; cited-R@1 now ahead (§3); multi-round planner still ctxe's edge on `in_body_only` — see §3/§5 |
| `compose_answer` | server LLM re-synthesis of a record | **paid per compose** | none (intentionally absent) | **gap** — only needed if prose reports required |
| `fast_understand` | server LLM two-pass orientation (~57 s measured) | **paid per call** | `fast_understand` deterministic digest (~0.4 s) | **replaced** — free, ~140× faster; digest not LLM prose |
| 14 read-only tools (`find_definitions`, `find_usages`, `fetch_chunks`, `graph_neighbors/expand/paths`, `get_impact`, `inspect_path`, `get_status`, `list_workspaces`, `get_record`, `list_records`, `search_records`) | none — local index.db reads | free per call, **but require a paid index to exist** | full 18-tool MCP parity | **replaced** — 10/12 latency wins measured |

## 2. What has actually been paid (records.db evidence)

`~/.ctxe/indexes/*/records.db` — durable count of paid Asks:

| Workspace key | asks completed | failed |
|---|---|---|
| 6e09ad5e9099 (P8) | 22 | — |
| a4fc8115d18a (22.site-M) | 9 | 2 |
| 9244bb1f135b | 5 | — |
| b1617b66c781 | 5 | — |
| 029506dc2bd2 | 1 | — |
| c35016e51f6b | — | 1 |
| **Total** | **42** | **3** |

Plus every index build/refresh on 7 workspaces (embeddings metered per file).
Failed asks still consumed planner rounds before failing. **Update 2026-09-22:**
the fleet ledger count of ctxe `kind=ask` records reached **126 and rising**
(42 on 09-18 → 126 on 09-22) — the spend is ongoing, not historical.

## 3. Replacement coverage — measured (2026-09-22)

**Retrieval: measured parity on blind holdouts.** `search` leg R@5 on
pre-registered manifests that were never tuned (`bench/*.REGISTERED`):

| set | swctx `search` R@5 | ctxe union R@5 | source |
|---|---|---|---|
| linkeldn (25q, blind, 1 repo) | **23/25** | 23/25 | `bench/linkeldn_*_results.json` + HANDOFF 2026-09-22 |
| fleet (23q, blind, 3 repos) | **18/23** (R@10 20/23) | 15/23 | `bench/fleet_*_results.json` + HANDOFF 2026-09-22 |
| vn22 (tuned set — detector, not proof) | 18/22 | — | `bench/strict_results.json` |

Note: the JSON artifacts capture the Sep-20 binary (linkeldn 21/25, fleet
17/23); the Sep-22 acronym-tokenizer + vnLexicon (+34) changes lifted the
search leg to the figures above — deltas recorded in HANDOFF.md.

**Synthesis leg now measurable too:** `answer --backend cli:agy` cited-R@1
(rank of the gold path inside the model's resolved citations) **beats
ctxe's paid planner**: linkeldn **17 vs 15**, fleet **15 vs 14**
(`bench/*_holdout_agy_results.json` vs `*_ctxe_results.json`).

**Latency**: swctx `search` p50 ~142ms live (bench medians 537ms–1.6s by
corpus) vs ctxe `ask_context` **~29s/ask** measured (p50 20.3s no-compose,
35s live, p95 ~60s) — plus credits per call.

**Adoption telemetry (pre-reroute baseline, Grok audit):** `usage_events`
search=**781**, answer=**0**, checkpoint=2; ctxe `kind=ask`=**126**.
Retrieval is already displaced in practice; synthesis reroute is Phase 1
work (ROADMAP) — a baseline, not a result.

**swctx extras ctxe does not ship:** `simulate_patch` (speculative diff
pre-flight), `test_coverage` (symbol↔test map), `trace_lookup` (stack
trace → indexed frames), `checkpoint`/`put_record` cross-session memory
with a global ledger, single-daemon `watchd` freshness, `outline` +
`fetch_chunks mode=signature` slicing.

**ctxe still ahead — honest residual:**

- `in_body_only` VN stratum: ctxe union 13/13 on linkeldn's body-only
  slice vs swctx 10/13; fleet 9/11 vs swctx 7/11 (Sep-20 paired runs).
  Agent enumeration rescues the known misses by hand (T5) — not yet
  automatic.
- Server-side **multi-round planner** (`ask_context`, 3–48 rounds +
  corpus-scale reranker). swctx deliberately delegates reasoning to the
  calling agent; `answer --plan` / `--backend cli:*` covers the loop
  locally, but quality on messy multi-hop questions is unproven beyond
  the cited-R@1 proxy.
- `compose_answer` re-synthesis of a stored record — absent by design.

## 4. "When the money stops" checklist

If ctxe credentials lapse / credits run out:

| Loss | Covered by | Ready? |
|---|---|---|
| Index refresh on file change | 6 launchd swctx watchers (already running) | yes |
| `find_definitions`/`find_usages`/graph/records/inspect_path | swctx MCP — same tool names, same agent config | yes |
| Workspace orientation | `fast_understand` digest | yes |
| Evidence packs for questions | `answer` / `context_pack` | yes (blind-holdout R@5 23/25 + 18/23, §3) |
| Investigation reports | **the calling agent itself** — Devin/agy/Claude reads the pack and writes; `answer --backend cli:*` automates the same loop | yes — see §5 |

## 5. Can ctxe spending stop? — measured verdict

ctxe sells two server-side brains: the **planner** (`ask_context` rounds:
retrieve → reason → re-query) and the **composer** (`compose_answer`
prose). Both are billed per call in credits.

But every MCP caller in this fleet is already an LLM agent — Devin, agy,
Claude, Codex — paid as a flat subscription, not per query. The
agent-driven loop *is* a planner:

```
agent → swctx search → read evidence → next query → … → writes report
```

Equivalent to ctxe's internal planner, with two advantages: the model is
stronger than a server-side 3B-class reasoner, and it carries the full
task context ctxe never sees. swctx's `answer --plan` additionally ships
a local-model planner for headless use — zero credit either way.

**Therefore most of the paid synthesis is redundant** when the consumer is
an agent CLI — and `answer --backend cli:*` now runs that same loop inside
swctx with citation validation, measured ahead of ctxe on cited-R@1 (§3).
A paid planner would only matter for a *non-agent* consumer (a script
wanting prose with no LLM in the loop) — not this workflow.

### Residual risks (honest — quality margins, not structural gaps)

| Risk | Mitigation |
|---|---|
| `in_body_only` VN stratum still loses to ctxe's planner (§3) | Graph one-hop tried + failed preregistered gate (0 rescue/70 frozen q) — next attempt must be probe-layer/file-level scoring, not another weak fusion leg; agent enumeration (T5) meanwhile |
| Multi-round planner quality on messy multi-hop questions unproven | `answer --plan` / `cli:*` exists; gate = cited-R@1 staying ahead on new manifests |
| vn22 is tuned — a regression detector, not proof | Frozen blind manifests (linkeldn 25q, fleet 23q, aiteam 13q) decide claims |
| `voyage-code-4` (1024-d) vs BGE (768-d) embedding quality | Measured parity so far; reranker (W15) only if a gap reappears — 3/3 rerankers already rejected on evidence |
| Headless prose reports with no agent | `answer --backend ollama` (local) or `cli:*`; or accept absence |

**Verdict (2026-09-22): retrieval and the evidence-pack surface are
replaced on measured evidence** — blind-holdout parity-to-better at 0đ,
~142ms vs ~29s, and the cited `answer` leg already ahead of ctxe's paid
planner on R@1. **This is not yet a proven 100% replacement:**

- `in_body_only` VN queries remain ctxe's honest win; swctx mitigations
  (lexicon legs, agent enumeration) rescue by hand, not automatically.
- The displacement telemetry is a *baseline*: `answer`=0 means the fleet
  still pays for every synthesis call today. The kill-gate is the 14-day
  reroute read — ctxe `kind=ask` must fall below 126 before the bill is
  declared dead (ROADMAP Phase 1).
