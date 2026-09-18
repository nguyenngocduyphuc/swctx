# ctxe — Field feedback (2026-09-18)

Tested ctxe 0.4.4 against a local reimplementation (`swctx`) on 6 real
workspaces. Findings below are reproducible on this machine; each has a
repro command and DB-level evidence. Ordered by user impact.

## 1. `find_definitions` misses a top-level enum (chunker boundary bug)

**Workspace:** `/Users/phuongnam/02.AI/NP_AI_macos/22.site-M`
(index key `a4fc8115d18a`)
**Symbol:** `enum SiteCleanup` declared at `Sources/SiteM/SiteCleanup.swift:24`,
plus `extension SiteCleanup` at `SiteCleanup+Stores.swift:5`.

**Expected:** `find_definitions("SiteCleanup")` returns both declaration
sites (the enum is the canonical definition).
**Actual:** only the extension is returned — the enum never became a symbol.

**Root cause (index.db evidence):**

```
-- chunks for SiteCleanup.swift
4918 | 0 |  1-  1 | CryptoKit | import
4919 | 1 |  2-  2 | Foundation| import
4920 | 2 |  3- 24 | SQLite3   | import      <- import chunk END at line 24
4921 | 3 | 24- 29 | NULL      | NULL        <- enum opener, no symbol bound
4922 | 4 | 29- 65 | Plan      | struct
```

- Chunk 4920 (`import SQLite3`, lines 3→24) absorbs the `enum SiteCleanup {`
  opening line into its tail.
- Chunk 4921 (lines 24→29) carries no `symbol_name`/`symbol_type`.
- `SELECT * FROM symbols WHERE name='SiteCleanup'` → exactly one row:
  `chunk_id=4873, symbol_type='class', line=5` (the extension file).
- Members *inside* the enum (`Plan`, `Entry`, fields, `render`, …) are
  extracted — the container itself is not.
- The same file's *nested* enum (`SiteCleanupError`, line 389) IS a symbol.

Looks like: when a file-level preamble chunk overlaps the opening line of
the first declaration, the declaration symbol is never bound to any chunk.
`enum` may not be the only affected decl kind — worth a sweep:
`chunks WHERE symbol_name IS NULL AND content LIKE 'enum %'` etc.

**Also in `symbols`:** the extension row is typed `class` — extension
declarations should probably be their own kind.

## 2. `inspect_path` + `query` reranks a 150-chunk path-order window

Measured response on site-M (`path="Sources/SiteM"`, `query="SiteCleanup"`,
`limit=3`): `total_chunks_under_path=3628`, `next_offset=150`, top-3 hits =
`AgentService`/`AIVisibilityStore` — all unrelated; the actual `SiteCleanup`
file sorts after `Agent*`/`AI*` and never entered the rerank pool.

So `inspect_path`+query is deterministic-miss for any symbol whose path
sorts beyond the window. Suggest reranking the full subtree (or at least
FTS-prefiltering the pool) rather than path-order truncation. (ctxe spec
docs mention `rerank pool 150/500` — the 150 cap bit here.)

## 3. `ctxe daemon` stopped; watches are intent-only

`ctxe daemon status` → `Daemon: Stopped (not running)`, `Autostart: enabled`,
`Manager activity: inactive`, `runs=5`, last clean exit ~11.5h before check.
launchd has `KeepAlive.SuccessfulExit=0` — a clean exit is not restarted,
so the daemon silently stops watching. `ctxe status` then reports
`stale (19 pending)` on a workspace the user believes is live.

Options: `KeepAlive` unconditionally (with throttle), an `on_demand`
restart, or surfacing "daemon down" prominently in `ctxe status` /
`get_status` output rather than only `stale_files`.

## 4. Local-symbol lookups cost ~130-220ms (server round-trip?)

`find_definitions` / `find_usages` measure 84-221ms on this machine for
what appears to be a local SQLite symbol lookup. A plain index read should
be ~5-15ms. If these calls round-trip the server (auth/telemetry/rerank),
consider a pure-local fast path for definition/usage lookup — these are
the highest-frequency agent calls.

## 5. No workspace-wide non-LLM search

There is no MCP/CLI equivalent of "search the whole workspace for a
string/symbol" without `ask_context` (credit-metered) or `inspect_path`
(requires a path, rerank-windowed — see #2). Agents doing "find where X
lives" need a bounded lexical/hybrid `search` tool. swctx's free
`search(workspace, query, mode)` is the most-called tool in practice.

## 6. Clarify billing surface for retrieval calls

Per instructions, retrieval tools (`find_definitions`, `inspect_path`,
`search_records`, `list_workspaces`) may be credit-metered. If basic
retrieval is metered, agents will route around ctxe for everyday lookups —
the meter should ideally apply only to server-side LLM work
(`ask_context`, `fast_understand`, `compose_answer`, re-embedding).

---

## Measured comparison summary (for context, not a bug list)

| Case | swctx | ctxe | Source |
|---|---|---|---|
| `find_definitions` (2 syms, 2 ws) | 10-17ms | 84-221ms | 3 independent auditors |
| hybrid search | 35-49ms | 1.9-2.7s (inspect_path+query) | same |
| `SiteCleanup` def recall | both decl sites | extension only | all 3 auditors |
| freshness at audit time | stale_files=0 | 19+11 pending (daemon down) | same |
| `fast_understand` | ~0.4s deterministic | ~57s LLM (richer output) | bench |
| resolved edges | 15.2k (site-M) | 37.1k (site-M) | quality of extra edges unproven |
| symbols extracted | 18.7k | 9.7k | swctx includes non-code symbols |

ctxe strengths worth keeping: `ask_context` planner multi-round,
`compose_answer` record re-synthesis, confidence-scored edge graph,
community detection, budget contract (`omitted_budget`,
`E_OUTPUT_TOO_LARGE`), global `ref` record selectors, managed update.

## Repro environment

- ctxe 0.4.4 (`~/.local/bin/ctxe`), signed in, trial credits
- swctx local build (`tools/swctx/.build/release/swctx`)
- Both indexes live under `~/.ctxe/indexes/` and `~/.swctx/indexes/`
  keyed by the same workspace hash (`a4fc8115d18a` = 22.site-M)
- Full spec/parity audit: `tools/swctx/CTXE_SPEC.md` (536 lines, [live]
  verified sections)
