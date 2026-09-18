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
