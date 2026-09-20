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

**The only remaining paid dependency: LLM prose synthesis.**
- `ask_context compose:true` produces reports swctx's extractive `answer`
  does not match in prose quality.
- If that capability is needed post-ctxe, the replacement path is a **local
  model** (self-hosted Qwopus/3B already used by `answer --plan` — zero
  credit), not another paid service.

## 4. "When the money stops" checklist

If ctxe credentials lapse / credits run out:

| Loss | Covered by | Ready? |
|---|---|---|
| Index refresh on file change | 6 launchd swctx watchers (already running) | yes |
| `find_definitions`/`find_usages`/graph/records/inspect_path | swctx MCP — same tool names, same agent config | yes |
| Workspace orientation | `fast_understand` digest | yes |
| Evidence packs for questions | `answer` / `context_pack` | yes (22/22 measured) |
| LLM-written investigation reports | nothing local yet — `compose_answer` equivalent | **the one real gap** |

**Bottom line:** 4/5 paid capabilities already replaced at 0 cost. The day
credits stop, retrieval keeps working untouched; the only thing that
disappears is server-written prose — and the fix for that is a local model,
not a subscription.
