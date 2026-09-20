# CTXE → swctx — Replacement Ledger

> **Purpose:** ctxe is credit-metered. This file records exactly what each paid
> function is, what it costs, and what swctx covers — so that when ctxe spending
> stops, nothing is silently lost.
> Compiled 2026-09-18 against ctxe 0.4.4 + swctx 0.1.0. Evidence classes as in
> CTXE_SPEC.md: **[live]** observed, **[bench]** measured, **[src]** source.

---

## 1. The ctxe bill — what actually consumes credits

ctxe charges for **server work**, not local reads. Local index.db reads are
free per call — but useless without the paid index behind them.

| Function | Server work | Credit meter | swctx replacement | Status |
|---|---|---|---|---|
| `index_workspace` | `voyage-code-4` embeddings + enrich, per file | **paid every index/refresh** | `swctx index` — tree-sitter + on-device BGE CoreML | **replaced** — free, unbounded |
| `ask_context` | `/v2/reason` planner, 3–48 rounds + compose | **paid per Ask** | `swctx answer` (extractive pack) + `context_pack` + `--plan` (local planner) | **retrieval replaced**; prose synthesis weaker — see §3 |
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
Failed asks still consumed planner rounds before failing.

## 3. Replacement coverage — measured

**Retrieval surface: fully replaced.** Deterministic union (search ∨ answer,
no LLM) = 21/22 on the 22-query VN benchmark; +`find_definitions` = **22/22
MCP surface** — parity with the ctxe paired union at zero marginal cost.
Commits `3b450b2`/`4126a2c`/`2bc455a`; artifact `bench/union_results.json`.

**The only remaining paid dependency: LLM prose synthesis — and it is not
a real gap.** See §5.

## 4. "When the money stops" checklist

If ctxe credentials lapse / credits run out:

| Loss | Covered by | Ready? |
|---|---|---|
| Index refresh on file change | 6 launchd swctx watchers (already running) | yes |
| `find_definitions`/`find_usages`/graph/records/inspect_path | swctx MCP — same tool names, same agent config | yes |
| Workspace orientation | `fast_understand` digest | yes |
| Evidence packs for questions | `answer` / `context_pack` | yes (22/22 measured) |
| Investigation reports | **the calling agent itself** — Devin/agy/Claude reads the pack and writes | yes — see §5 |

## 5. Feasibility of 100% replacement — the agent-is-the-brain argument

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

**Therefore the §3 "gap" resolves to:** ctxe's paid synthesis is redundant
when the consumer is an agent CLI. It would only matter for a
*non-agent* consumer (a script wanting prose with no LLM in the loop) —
not this workflow.

### Residual risks (honest — quality margins, not structural gaps)

| Risk | Mitigation |
|---|---|
| Parity measured on one 22-query set, tuned against it | Blind holdout on an untuned repo (todo #10) |
| Only P8 + CRM measured | Extend index + bench to remaining workspaces |
| `voyage-code-4` (1024-d) vs BGE (768-d) embedding quality | Measured parity so far; reranker (W15) if a gap appears |
| Headless prose reports with no agent | Local model via `answer --plan`; or accept absence |

**Verdict: 100% replacement is feasible today for agent-driven work.**
Nothing ctxe sells is structurally irreplaceable — the two paid brains are
duplicates of the caller. The only open work is *evidence breadth*
(blind holdout, more repos), not new capability.
