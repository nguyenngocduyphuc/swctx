# engine_ab — swctx vs ctxe head-to-head on the vn retrieval probe

Generated: 2026-09-19 · swctx 0.1.0 (`bench/../.build/release/swctx mcp`) ·
ctxe 0.4.4 (`ctxe mcp`) · MCP protocol 2024-11-05 over stdio ·
Data: `bench/engine_ab_results.json` · Harness: `bench/engine_ab.py`
(stdlib only, reuses `bench/bench.py` `MCPSession`)

## Question

The dual-engine thesis: **swctx = local fast retrieval (L1), ctxe =
server synthesis (L2)**. swctx's measured baseline on this probe is
13/22 (vn_probe, `search --mode auto`). ctxe's per-query file-recall had
never been measured head-to-head. This harness produces that first
comparison — and, just as importantly, documents exactly where the two
engines' surfaces do not overlap at all.

## Method — the comparability problem, made explicit

ctxe has **no `search` tool**. Its 18-tool MCP surface offers
`find_definitions`, `find_usages`, `inspect_path`, `fetch_chunks`,
`get_workspace_tree`, `ask_context`, `fast_understand`,
`compose_answer`, records and graph tools. swctx offers `search`
(hybrid NL+symbol) plus a similar symbol/graph set. Each probe query was
therefore mapped to the closest honest ctxe surface, labelled by
comparability tier:

| query class | n | swctx call | ctxe call | tier |
|---|---|---|---|---|
| `symbol_lookup` | 4 | `search` + `find_definitions` | `find_definitions` (same symbol input) | **PARITY** |
| `concept_flow` + `in_path` | 11 | `search` | `get_workspace_tree` (a) raw NL string → literal substring filter; (b) folded-token sweep, files ranked by distinct-token match count | **ASSIST** |
| `concept_flow` + `in_body_only` | 7 | `search` | *(none — see below)* | **NO-SURFACE** |
| sampled `concept_flow` | 4 | `search` | `ask_context` `compose:false effort:min` | **L2-SYNTH** |

Fairness rules enforced by the harness:

- **No call may consume the gold answer.** `inspect_path` is *not* scored
  anywhere: it is directory-scoped (`path:"."` returns 0 chunks,
  `path:""` is rejected as unsafe), so the only way to aim it is to pass
  the expected file's directory — which leaks where the answer lives.
  Verified on the live wire, not just the schema.
- The token-sweep adaptation feeds `get_workspace_tree` only tokens
  derived from the query (NFKD-folded, len≥3, ≤12 tokens) — the
  deterministic client-side workaround a ctxe operator would have to
  perform, because the raw NL string is a literal substring filter.
- `crm-10` (`symbol_lookup`, no `expected_symbol`) ran
  `find_definitions` on both engines with query-derived candidates
  `["realign","realign_issue_ids","realign_issues"]` — flagged `nosym`.
- Preflight: every `expected_path` was confirmed present in the **ctxe**
  index via a basename tree filter (22/22 verified — every ctxe miss
  below is a *retrieval* miss, not an indexing gap). Same role as
  vn_probe's index check; never a retrieval input.
- Credit discipline: `ask_context` hard-capped at 4 calls
  (`compose:false`, `effort:min`, `retries:0`). Everything else is
  local/cheap. On the one client-side timeout, the spec-sanctioned free
  recovery ran: `list_records(kind:ask)` → `get_record` — a local read,
  no new spend.

Metric: **file-recall@5** — rank of `expected_path` in the engine's
top-5 file paths (1-based; 0/— = absent).

## Reachable surface per engine

| | swctx (local, free) | ctxe (hybrid) |
|---|---|---|
| NL workspace retrieval | `search` (fts/semantic/auto hybrid) | **none free** — only `ask_context`/`fast_understand` (server LLM, credits) |
| symbol | `find_definitions`, `find_usages` | `find_definitions` (local), `find_usages` |
| path surface | `inspect_path` (path-scoped) | `get_workspace_tree` substring filter (local), `inspect_path` dir-scope + optional server-side NL rerank |
| chunks/records/graph | `fetch_chunks`, `graph_*`, `get_impact`, records | `fetch_chunks`, `graph_*`, `get_impact`, records |
| synthesis | `context_pack` (deterministic) | `ask_context`, `compose_answer` (server planner, credits) |
| index status | `get_status`, `fast_understand` | `get_status`, `list_workspaces` |

ctxe query-time embeddings run on `server-embed-v2` (provider
`ctxe-server`, 1024-dim): any ctxe call that embeds the *query*
(`inspect_path` rerank, `ask_context`, `fast_understand`) goes to the
server. `find_definitions`, `get_workspace_tree`, `fetch_chunks`,
records are pure local index lookups — free. Both workspaces were
ctxe-indexed and Ready: `8.P8_SEO_Clean` (3098 files, 16534 chunks),
`18.CRM-Nam-Pham` (83 files, 550 chunks).

## Comparison table — all 22 queries

Rank of expected file in top-5 (`—` = not present, `·` = surface not
run for that class, `n/s` = no ctxe surface exists). swctx numbers over
one persistent `swctx mcp` session; ctxe numbers over one persistent
`ctxe mcp` session.

| id | intent · path_signal | sw `search` | sw `find_defs` | cx `find_defs` | cx `tree raw` | cx `tree sweep` | cx `ask` (live) | cx `ask` (record) |
|---|---|---|---|---|---|---|---|---|
| seo-01 | concept · in_path | 2 | · | · | — | — | — | **1** |
| seo-02 | concept · in_path | 1 | · | · | — | — | · | · |
| seo-03 | concept · in_path | 2 | · | · | — | — | · | · |
| seo-04 | concept · in_path | — | · | · | — | — | · | · |
| seo-05 | concept · in_body | — | · | · | n/s | n/s | · | · |
| seo-06 | concept · in_body | — | · | · | n/s | n/s | · | · |
| seo-07 | concept · in_body | 5 | · | · | n/s | n/s | · | · |
| seo-08 | concept · in_path | 3 | · | · | — | — | · | · |
| crm-01 | concept · in_path | 2 | · | · | — | 1 | · | · |
| crm-02 | symbol · in_body | 3 | 1 | 1 | · | · | · | · |
| crm-03 | symbol · in_body | 2 | 1 | 1 | · | · | · | · |
| crm-04 | concept · in_path | — | · | · | — | — | — | **1** |
| crm-05 | concept · in_body | 1 | · | · | n/s | n/s | · | · |
| crm-06 | concept · in_path | 1 | · | · | — | — | · | · |
| crm-07 | concept · in_path | 1 | · | · | — | — | · | · |
| crm-08 | symbol · in_body | — | 1 | 1 | · | · | · | · |
| seo-09 | concept · in_body | — | · | · | n/s | n/s | timeout | **2** |
| seo-10 | concept · in_body | — | · | · | n/s | n/s | · | · |
| seo-11 | concept · in_path | 1 | · | · | — | 1 | · | · |
| crm-09 | concept · in_path | 1 | · | · | — | 1 | · | · |
| crm-10 | symbol · in_body (`nosym`) | — | — | — | · | · | · | · |
| crm-11 | concept · in_body | — | · | · | n/s | n/s | — | **1** |

## Aggregates

| surface | hits | n | recall@5 | p50 latency | p95 latency |
|---|---|---|---|---|---|
| swctx `search` (all queries) | 13 | 22 | **0.59** | 101 ms | 621 ms |
| swctx `search` on concept_flow | 11 | 18 | 0.61 | | |
| swctx `search` on symbol_lookup | 2 | 4 | 0.50 | | |
| swctx `find_definitions` (symbol class) | 3 | 4 | 0.75 | 12 ms | 15 ms |
| ctxe `find_definitions` (symbol class) | 3 | 4 | **0.75** | 7 ms | 7 ms |
| ctxe `tree` raw NL (in_path class) | 0 | 11 | 0.00 | 41 ms | 209 ms |
| ctxe `tree` token-sweep (in_path class) | 3 | 11 | 0.27 | 424 ms † | 1717 ms † |
| ctxe `ask_context` — live wire view | 0 | 4 | 0.00 | 20.3 s | 60.2 s |
| ctxe `ask_context` — durable-record view | 4 | 4 | **1.00** | (same calls) | |

† sweep latency = sum of the ≤12 per-token `get_workspace_tree`
substring calls that make up one scored query.

## The ask_context sample — live wire vs durable record

Four concept_flow queries sampled under the credit cap: one swctx-hit
sanity check (seo-01) + three swctx misses (seo-09, crm-04, crm-11 —
two of them `vn_to_en`, the class where swctx scores 0/5).

| query | sw `search` | live response paths | record `direct_evidence` | ask duration |
|---|---|---|---|---|
| seo-01 → `scripts/p8_canonical_check.py` | hit (2) | 2 files, expected **absent** | **rank 1** | 23.9 s |
| seo-09 → `scripts/p8_brain.py` | miss | *(client timeout @60 s)* | **rank 2** (record completed in 64.6 s) | 64.6 s |
| crm-04 → `crm-nam-pham/09-build/dong_vong.py` | miss | 0 file paths | **rank 1** | 12.6 s |
| crm-11 → `crm-nam-pham/09-build/log_activity_live.py` | miss | 0 file paths | **rank 1** | 16.8 s |

Two distinct findings here:

1. **The planner gathers the right file — 4/4.** Every sampled ask,
   including the three swctx missed entirely and both `vn_to_en`
   queries, placed the expected file in `direct_evidence` at rank 1–2.
   Server-side synthesis bridged the VN→EN semantic gap that swctx's
   local hybrid misses.
2. **The live `compose:false` wire response does not self-contain that
   evidence.** Payload keys are `answer`, `diagnostics`, `meta`,
   `outcome`, `planner`, `record_id`, `schema_version` — evidence is
   chunked-id'd and/or text-rendered under the 20 k-token output budget.
   seo-01's live response surfaced only 2 of its files (missing the
   expected one); crm-04/crm-11 surfaced zero `file_path` fields. The
   full hydrated evidence (`direct_evidence[].file_path`) persists in
   the durable ask record and is retrieved via `get_record` — free, but
   an extra hop every real client must make. `fetch_chunks` covers
   bodies the same way.

## Findings — where each engine wins, and where they don't overlap

- **PARITY surface (symbol_lookup, n=4): engines tie.** swctx and ctxe
  `find_definitions` returned identical results — both hit the defining
  file at rank 1 on crm-02, crm-03, crm-08; both missed crm-10, whose
  real symbol (`_apply_id_moves`) is unguessable from the query text.
  ctxe was marginally faster (p50 7 ms vs 12 ms) — both are local index
  lookups. Notably `find_definitions` rescued crm-08, which `search`
  missed on both engines: the symbol surface beats NL search when the
  query names a real symbol.
- **in_path concept_flow (n=11): swctx 9/11 vs ctxe-assist 3/11.**
  Raw NL against `get_workspace_tree` scored 0/11 — the filter is a
  literal path substring, not a query. The operator-adapted token sweep
  (fold each query token, substring-match, rank by distinct-token count)
  found crm-01, seo-11, crm-09 at rank 1 — all in the small 83-file
  index. On the 3098-file seo index, common tokens flood the candidate
  set (278–367 candidates per query) and the expected file loses to
  multi-token collisions — e.g. seo-01's `canonical` matched
  `p8_canonical_normalizer.py` and four `extract_*` files ahead of
  `p8_canonical_check.py`. The signal exists in ctxe's index; the
  *surface* cannot express an NL path query.
- **in_body_only concept_flow (n=7): ctxe has no free surface at all.**
  `inspect_path` refuses workspace scope; `get_workspace_tree` only sees
  paths; `find_usages`/`fetch_chunks` need ids from a prior call. The
  only NL-capable ctxe tool is the credit-metered planner.
- **L2 surface (n=4 sample): 4/4 on record view** — including all 3
  sampled swctx misses and both `vn_to_en` queries — at 12.6–64.6 s per
  call vs swctx's ~100 ms.
- **Coverage asymmetry**: every one of the 22 expected files exists in
  *both* indexes (verified). The misses are retrieval-surface misses,
  not corpus gaps.

## Verdict — the L1/L2 thesis, with data

**Confirmed, sharper than stated.** The split is not "two engines that
both retrieve" — it is one engine that retrieves and one that
synthesizes, with a thin sliver of overlap:

- On the **4 queries where a true parity surface exists**
  (`find_definitions`), the engines are equivalent — identical hit sets,
  comparable single-digit-ms latency. ctxe is a fine L1 *symbol* engine.
- On the **18 NL queries, ctxe has no L1 surface.** Its free tools
  answer "what file paths contain this literal substring" and "what
  chunks live under this directory" — not "which file does this
  question mean". swctx's `search` is the only NL retrieval surface in
  the pair, and it wins that uncontested job 13/22.
- Where swctx fails, **ctxe's L2 is a genuine rescue path, not a
  duplicate**: 3/3 sampled swctx misses were caught by `ask_context`
  evidence (plus 1/1 sampled hit re-confirmed). Cost: ~200–600× the
  latency (tens of seconds, server round-trips) and metered credits,
  plus a `get_record` hop to see what it actually gathered.
- The complementary pair covers more than either alone. swctx `search`
  misses 9/22; a ctxe surface was exercised on 6 of those and caught 4 —
  `crm-08` via `find_definitions` (swctx's own find_defs caught it too:
  the *symbol tool* beat NL search, on both engines), and `crm-04`,
  `seo-09`, `crm-11` via `ask_context`. Union coverage is **17/22**
  vs 14/22 for swctx search+find_defs alone. The 5 that escaped both
  engines — seo-04, seo-05, seo-06, seo-10, crm-10 — are mostly
  uncovered *by construction*: 3 of them have no free ctxe surface at
  all, seo-04 lost to token flooding, and crm-10's symbol is
  unguessable. Routing rule the data supports: swctx `search` first;
  on miss, `find_definitions` if the query names a symbol (free on both
  engines); only then `ask_context` for the residual NL misses.

## Caveats

- n=22 on two doc-heavy workspaces; the ask sample is n=4 and was
  *chosen* to include swctx misses — 4/4 is real but the sample is
  informative, not representative. An unbiased 4-sample would still
  show the surface asymmetry, which is the structural finding.
- The token-sweep is a client-side adaptation, not a native ctxe
  feature — its 3/11 is the ceiling of the free path surface when an
  operator does the query-to-substring translation ctxe won't do.
- `ask_context` "hit" is measured on the durable record's
  `direct_evidence` (what the planner gathered). The live
  `compose:false` wire under-reports it (0/4 here) — clients must
  follow up with `get_record`/`fetch_chunks`; count that as part of the
  tool's effective contract.
- ctxe embedding is server-side (`server-embed-v2`), so even ctxe's
  "local" retrieval carries a network dependency; find_defs/tree are
  exempt (no query embedding).
- One ask exceeded the 60 s client timeout (64.6 s server-side) —
  real-world calls need either a larger budget or the record-polling
  recovery the spec prescribes.
- All misses are retrieval misses: every expected file is verified
  present in both engines' indexes.

## Reproduce

```sh
python3 bench/engine_ab.py --out bench/engine_ab_results.json   # full run
python3 bench/engine_ab.py --no-ask                             # zero credits
python3 bench/engine_ab.py --ask-sample seo-01,crm-04           # custom sample (cap 4)
```

## Full-surface parity probe (parity_probe.py, 2026-09-19)

engine_ab.py scored the 4 contested retrieval surfaces. The remaining
shared tools were probed head-to-head for shape + correctness on the same
CRM workspace targets — coverage of the full ctxe tool list (18 tools):

| surface | swctx | ctxe | verdict |
|---|---|---|---|
| get_status | files/chunks/edges/vectors + freshness | indexed/files/schema_version + capabilities | parity (different key layout) |
| list_workspaces | n=23 (all indexed dirs) | n=9 (accepted catalog) | different semantics, both correct |
| find_usages tom_tat | n=3 | n=3 | parity |
| find_usages format_fragment | n=2 | n=1 | swctx finds one more use site |
| find_usages ghi_quyet_dinh | n=0 | n=0 | parity (unused symbol) |
| inspect_path dir | chunks=50 | chunks=50 | parity |
| fetch_chunks | round-trip ok (chunk 3230) | round-trip ok (chunk 394) | parity |
| graph_neighbors | neighbors w/ resolved dst_name + edge_kind | n=9 neighbors | parity (swctx names resolved symbols) |
| graph_expand | no results | no results | parity-empty for the probed chunk |
| get_impact | dependents w/ full chunk info | 3 items (hop+score, thin) | swctx payload more hydrated |
| list/search/get records | 0 records for CRM ws (none written) | items work (ask records present) | parity; content differs by usage |
| fast_understand | deterministic card: chunks/files/hot_files/hub_symbols/languages | server answer + planner + record_id | different natures — swctx free local card, ctxe synthesized answer |

Not probed individually: graph_paths (mechanical parity surface),
swctx get_workspace_tree (swctx callers use `search` instead),
compose_answer (ctxe-only; operates on an ask record — same synthesis
family as ask_context, which was sampled).

swctx-only tools (no ctxe counterpart): search, context_pack,
put_record, prime. ctxe-only: ask_context, compose_answer.

## ask_context full miss coverage (ask_full_misses.py, 2026-09-19)

The 4-call sample extended to ALL 9 swctx-search misses (credit spend
approved). Durable-record `direct_evidence` view:

| miss | live rank | record rank | note |
|---|---|---|---|
| seo-04 | — | **1** | rescued |
| seo-05 | 5 | **1** | rescued |
| seo-06 | 2 | **3** | rescued |
| seo-09 | timeout | **2** | rescued (earlier run) |
| seo-10 | — | **2** | rescued |
| crm-04 | — | **1** | rescued (earlier run) |
| crm-08 | — | **1** | also rescued FREE by find_definitions |
| crm-10 | — | **1** | rescued |
| crm-11 | — | **1** | rescued (earlier run) |

**Union coverage: 22/22 (100%).** swctx search alone 13/22 free ~100ms;
+1 via find_definitions (crm-08, free); the remaining 8 misses all
recovered by ctxe ask_context records (paid, 12–65 s). compose_answer
verified live: record 19 → answer+confidence+evidence in 10.5 s.
