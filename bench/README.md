# bench — swctx vs ctxe A/B benchmark

Reproducible, stdlib-only Python 3 harness that spawns both engines as MCP
stdio servers and runs the same query suite against each, recording latency,
top-5 hits and a relevance label (`exact` / `related` / `miss`).

## Run

```bash
cd tools/swctx
python3 bench/bench.py                  # P8 curated suite, writes bench/results.json
python3 bench/bench.py --skip-ctxe      # swctx only
python3 bench/bench.py --skip-swctx     # ctxe only
python3 bench/bench.py --workspace /abs/path --out /tmp/results.json
python3 bench/bench.py --auto           # auto-derived cases on any workspace
```

Requirements: `tools/swctx/.build/release/swctx` built (`swift build -c
release`), `ctxe` on PATH, and the target workspace indexed by both tools
(default workspace: `/Users/phuongnam/02.AI/NP_AI_macos/8.P8_SEO_Clean`).

## Case modes

- **Curated (default workspace only)** — the P8-specific suite below with
  hand-picked symbols and expected paths.
- **Auto (`--auto`, or automatically for any non-default `--workspace`)** —
  probe symbols are picked from the swctx index itself: top code symbols by
  resolved incoming `calls` edges (`auto_probe_symbols`), restricted to
  `python/swift/typescript/javascript/tsx/go/rust` files so both engines
  could plausibly have indexed them. Ground truth is therefore real: every
  probed symbol provably has callers, and `find_usages` empty → genuine
  `miss`. Judges become parameterized (`judge_defs_covering`,
  `judge_nonempty`, `judge_file_hit`). Per-run output goes to a separate
  `--out` file (e.g. `bench/results-21.json`) so runs form a timeseries.

## How it works

1. Spawns `swctx mcp` and `ctxe mcp` (ctxe's MCP entrypoint confirmed via
   `ctxe mcp --help`). Speaks line-delimited JSON-RPC:
   `initialize` → `notifications/initialized` → `tools/list`/`tools/call`.
   A `get_status` warmup call is issued per server before timing (it also
   absorbs ctxe's cold "runtime acquisition timed out after 5000 ms" spin-up;
   tool calls additionally retry transient errors up to 2 times).
2. Per case it prints `server, latency ms, top-5 (path:line · symbol ·
   #chunk_id), relevance`, then a markdown table to stdout and machine JSON
   to `bench/results.json`.

## Query suite (encoded in `bench.py`)

| Case | swctx call | ctxe call | Relevance judge |
|---|---|---|---|
| `find_definitions` | `find_definitions symbols=[detect_keyword_cannibalization, pull_gsc]` | same | exact if both symbols resolve |
| `find_usages` | `find_usages symbol_name=pull_gsc` | same | exact if pull_fleet/main/test callers found |
| `inspect_path` | `inspect_path path=scripts query="aggregate GSC impressions and clicks by page"` | same | exact if top-5 hits p8_analytics_pull / gsc_task / p8_daily_report / p8_opportunity_scorer |
| `search_equiv` | `search query="detect keyword cannibalization…"` (workspace-wide) | `inspect_path path=scripts` same query | same judge |
| `graph_neighbors` | seed = `src_chunk` of first resolved `calls` edge in `~/.swctx/indexes/<sha256(realpath)[:12]>/index.db`, direction outgoing | seed = `pull_gsc` chunk_id returned by ctxe's own `find_definitions`, direction incoming | exact if ≥1 resolved neighbor |

Relevance labels are heuristic and encoded per case in `bench.py` (`judge_*`
functions) — adjust expectations there if the workspace changes.

## Known tool-surface differences (verified 2026-09-15: ctxe 0.4.4, swctx 0.1.0)

- **ctxe has no bare `search` tool.** Its closest free/local equivalent is
  `inspect_path` with `query`, which is *path-scoped* — `path=""` is rejected
  ("invalid or unsafe path") and `path="."` returns zero chunks, so there is
  no workspace-wide retrieval without naming a directory. The `search_equiv`
  case therefore scopes ctxe to `path="scripts"`.
- **`ask_context` is skipped on purpose.** It is ctxe's server-backed,
  goal-driven evidence planner and consumes account credits (requires
  `ctxe login`); it is not a free/local retrieval primitive, so benchmarking
  it against swctx's local `search` would conflate retrieval quality with a
  paid LLM planner. swctx's local analogue is `context_pack` (deterministic,
  no LLM) — also not exercised here.
- **`graph_neighbors` seeds differ by construction** (per spec): swctx's seed
  comes straight from its SQLite `edges` table (first resolved `calls` edge,
  direction `outgoing`); ctxe's seed is a chunk_id from its own
  `find_definitions` response (direction `incoming`). Both engines are
  exercised on their own data, so the case measures API/graph health and
  latency, not identical-subgraph recall.
- **ctxe `graph_neighbors` has no `depth` parameter** (BFS lives in
  `graph_expand`/`graph_paths`); swctx supports `depth` 1–3. The bench uses
  depth-1 semantics on both.
- **Result shapes differ**: ctxe returns `file_path`/`symbol_name` and a
  `meta` envelope (content budget, degradation level); swctx returns
  `path`/`symbol`. `extract()` in `bench.py` normalizes both into
  `{loc, symbol, chunk_id, score}` hits.
- ctxe's first tool call after spawn can fail with `runtime acquisition …
  timed out after 5000 ms` while its runtime warms up; the harness' warmup
  call + retry handles this — it is a startup artifact, not a benchmark
  signal.

## Gold recall set (2026-09-18)

- `bench/gold_queries.json` — 36 verified queries across 22.site-M,
  21.linkeldn, 25.event-qr-checkin (6 `definition` + 6 `search` each).
  Definition symbols were mined from the swctx `symbols` table (mix of
  high in-degree and in-degree≤1 obscure defs); search expectations were
  verified by reading the target files.
- `bench/recall.py` — runs every gold query through
  `swctx search --mode auto --limit 5` (CLI per query) plus
  `find_definitions` over one persistent `swctx mcp` stdio session for
  definition-kind queries. ctxe is evaluated too (`find_definitions`
  like-for-like; search-kind via `inspect_path` scoped to the expected
  file's top dir — an assist, not comparable recall). Prints per-query +
  aggregate JSON, appends `timestamp,engine,workspace,kind,recall_at_5,
  n_queries,notes` rows to `bench/results.csv`.
- `bench/edge-audit.md` + `bench/edge_audit.py`, `bench/edge_classify.py`,
  `bench/edge_sample_verdicts.json` — 100-edge audit of ctxe resolved
  edges absent from swctx's site-M index (verdict: mostly phantom
  resolutions + deliberately-skipped field/type edges, ~2% genuine).

## MCP-wire recall + CI ratchet (2026-09-18)

`bench/recall.py` measures the CLI path (`swctx search`, one process per
query). The fleet only ever calls MCP tools, so `bench/recall_mcp.py`
runs the SAME 36 gold queries entirely through one persistent `swctx mcp`
stdio session — `tools/call search` (`mode=auto`, `limit=5`) on all
queries, plus `tools/call find_definitions` on definition-kind. One
discarded warmup call per workspace absorbs first-call index/embedder
load so recorded latencies are steady-state.

```bash
python3 bench/recall_mcp.py             # run + append results.csv
python3 bench/recall_mcp.py --no-csv    # run without touching CSV
python3 bench/recall_mcp.py --ratchet   # CI gates; exit !=0 on failure
```

CSV rows are labelled `swctx:search-mcp` / `swctx:find-defs-mcp` —
compare like-with-like against the CLI `swctx:search` rows by engine
name. First MCP-wire run: search recall@5 = 0.9722 (35/36), identical to
the CLI path; same single miss (`lib/gas.ts` query on event-qr-checkin).

**Ratchet gates** (verdict + per-gate lines on stderr, JSON still on
stdout; implies `--no-csv`):

- `recall@5` — `swctx:search-mcp` recall over all 36 gold queries must be
  >= `--min-recall` (default 0.95, i.e. at most one miss).
- `p95-latency` — p95 across every per-query MCP call (search +
  find_definitions, ~54 samples) must be <= `--max-p95-ms` (default 150).
- `schema-golden` — live `tools/list` `{name, inputSchema}` must equal
  `bench/tool_schemas.golden.json` (`--golden` to override). Catches
  silent tool-surface regressions like the flat-schema bug.

`bench/tool_schemas.golden.json` is a canonical dump (sorted by name,
sorted keys) of the 20 tools' `{name, inputSchema}` from a live
`tools/list`. Regenerate after an INTENTIONAL surface change:

```bash
python3 bench/recall_mcp.py --write-golden
```

Check just the schema gate without a recall run (cheap, exit !=0 on
diff): `python3 bench/recall_mcp.py --check-schema`.

## Output

- `bench/results.json` — full machine record: server argv/info, seeds used,
  per-run `{case, server, tool, latency_ms, relevance, hits[5], hit_count}`,
  blockers if a server couldn't start.
- stdout — human run log plus a markdown summary table (pipe to a file to
  keep it).

## Sample result (2026-09-15 run)

| Case | swctx | ctxe |
|---|---|---|
| find_definitions | 10.2 ms · exact | 529.8 ms · exact |
| find_usages | 20.5 ms · exact | 11.4 ms · exact |
| inspect_path (scripts, GSC query) | 1233.6 ms · exact (pull_gsc, _gsc_totals…) | 2487.3 ms · related (top-5 all `_legacy` audit chunks) |
| search_equiv | 405.3 ms · exact (detect_keyword_cannibalization #1) | 1028.2 ms · related (path-scoped; legacy files) |
| graph_neighbors | 12.1 ms · exact | 7.5 ms · exact |

Both engines agree exactly on definitions and usages; the divergence shows
up on semantic reranking (`inspect_path`) where swctx surfaces the live
GSC pipeline files and ctxe's top-5 is dominated by `scripts/_legacy`
chunks.

## Nightly ratchet (installed 2026-09-22)

`com.swctx.benchd` LaunchAgent runs `bench/nightly.sh` daily at 03:05:
`recall_mcp.py --ratchet` over the frozen gold set → timestamped JSON +
history.log under `bench/nightly/`; on gate failure a `finding` record
is written to the global ledger (surfaces in `prime` next session).

    bash bench/install_nightly.sh   # install/refresh
    launchctl kickstart gui/$(id -u)/com.swctx.benchd   # run now
    cat bench/nightly/history.log   # timeseries

First run already caught signal: recall 34/36 — two vocabulary-bridge
misses (acronym `gas`, suffix `+Comparison` vs parent) recorded as
finding #105 — evidence for the probe-layer design, not gold-set tuning.
