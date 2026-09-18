# CtxE ↔ swctx — Comprehensive Behavior Spec & Parity Matrix

> **Compiled:** 2026-09-17 · **Subject:** ctxe 0.4.4 (installed, `aarch64-macos`) vs swctx 0.1.0
> (Swift/macOS reimplementation at `tools/swctx/`).
>
> **Evidence classes used throughout:**
> **[pub]** = public ctxe.dev docs (docs claim "0.3.6 current" — older than the installed binary);
> **[live]** = observed on the installed 0.4.4 binary (CLI help, `config list/show`, `tools/list`,
> filesystem artifacts, launchd plist); **[src]** = swctx source; **[bench]** = `bench/results.json`;
> **[inf]** = inference; **[?]** = unknown/unresolved.
>
> Where docs and runtime disagree, runtime wins and the item is marked **[live]**.

---

## 0. Source matrix

| Evidence | Location |
|---|---|
| Public docs (8 pages) | ctxe.dev/docs {cli-reference, mcp-integration, tools-reference, configuration, how-it-works, uninstall} **[pub]** |
| Binary | `~/.local/bin/ctxe`, sha256 `ee4c902bd9f7bcf723885178433bf3c8ba0a5ba1f227f95652ef121943b5c220` **[live]** |
| Update state | `~/.ctxe/coordination/updates/update.json` **[live]** |
| Workspace catalog | `~/.ctxe/workspaces/catalog.json` **[live]** |
| Artifact manifest | `~/.ctxe/indexes/<key>/.ctxe-artifacts.json` **[live]** |
| Daemon service | `~/Library/LaunchAgents/com.ctxe.daemon.plist` **[live]** |
| Config defaults | `ctxe config list` / `config show --format json` (134 lines, captured complete) **[live]** |
| MCP schemas | live `tools/list` dump, all 18 tools **[live]** |
| Index report | `ctxe index --format json` + MCP `index_workspace` captures **[live]** |
| swctx | `Sources/SwctxCore/*.swift`, `Sources/swctx/main.swift`, `Package.swift`, `Tests/`, `README.md`, `HANDOFF.md`, `bench/` **[src/bench]** |

---

## 1. Product model

| | ctxe 0.4.4 | swctx 0.1.0 |
|---|---|---|
| Runtime | Rust binary; cloud-backed index/enrich/Ask server at `api.tlelabs.com` **[live]** | Swift 6.2 / SPM binary; **100% local** **[src]** |
| Embeddings | Server-side `voyage-code-4`, **1024-d**, profile `server-embed-v2`, payload contract `v3-lossless-full-payload` **[live]** | On-device CoreML `bge-base-en-v1.5`, **768-d** (`~/.swctx/models/`, ~210 MB, `swctx model` installs from HF `rsvalerio/bge-base-en-v1.5-coreml`); fallback `NLEmbedding.sentenceEmbedding` **512-d**; mixed-dim indexes are rejected → `embed --reindex` **[src]** |
| Auth | OAuth browser flow (Google/GitHub chooser) → JWT + `ctxe_rt1.*` refresh token in `~/.ctxe/credentials.json` (+`credentials.refresh.lock`) **[live]** | None **[src]** |
| Cost | Credit-metered indexing/Ask; `402 insufficient_credit` (error string tham chiếu `ctxe wallet` nhưng lệnh **chưa ship** — probe 0.4.4 trả `unrecognized subcommand`), `blocked_credit` states **[live]** | Free, unbounded **[src]** |
| Privacy | Code + queries leave the machine for embed/enrich/ask | Nothing leaves the machine |
| "Brain" | Server-side planner/composer (`/v2/reason`; model reasoning server-owned, not configurable via `effort`) **[live]** | The calling agent CLI does all reasoning; swctx is retrieval-only **[src]** |
| Data root | `~/.ctxe/` | `~/.swctx/` |

## 2. Install / runtime inventory **[live]**

```
~/.local/bin/ctxe                       # installed binary (0.4.4)
~/.ctxe/
  config.toml(.lock)                    # global config layer (file absent → all defaults)
  credentials.json + .refresh.lock      # OAuth tokens
  daemon/{daemon.lock, watches.json.lock}   # watch ledger file not yet created
  workspaces/catalog.json(+.bak+.lock)  # accepted-workspace ledger
  coordination/updates/{update.json(.bak), owner.lock,
                        candidates/<sha256>/ctxe}   # staged self-update
  coordination/workspace-leases/<key>.{activity,generation.legacy-v1,lifecycle}.lock
  record_refs.db(+shm/wal,.schema.lock) # global record-ref → workspace ledger
  logs/ctxe-daemon.log
  indexes/<key>/{index.db(+shm+wal), index.lock,
                 records.db(+shm+wal), records.schema.lock,
                 .ctxe-artifacts.json}
```

`update.json` (schema `version:1`, `revision:14`) declares the release contract:
`index_schema: 28`, `embedding_profile: server-embed-v2`, `upstream_model: voyage-code-4`,
`embedding_dimension: 1024`, `chunker_version: ts-v1-chunk-v19`,
`embed_context_version: v3-lossless-full-payload`; `service.{present, enabled:false, running:false}`;
`phase: complete`; `launch_targets_verified / old_processes_drained / service_verified: true`.

## 3. Workspace catalog & artifacts **[live]**

`catalog.json` (`version:1`) entries: `{canonical_root, reserved_at, accepted_at,
artifacts:[{normalized_db_root, artifact_dir, workspace_key, manifest_path}],
lifecycle:{state:"active"}}`. Five active entries observed (incl. a `.worktrees/` path —
worktrees are first-class workspaces).

`.ctxe-artifacts.json` (`version:1`) pins `{canonical_root, artifact_dir, normalized_db_root,
workspace_key}` and an `allowed_names` allowlist: exact `.ctxe-artifacts.json`, `index.lock`,
`records.schema.lock`; sqlite_family `index.db`, `records.db`; `generated_index_sqlite_family`;
`index_generation_state`; `manifest_temp`.

**Workspace key** = 12 hex chars = first 6 bytes of SHA-256 over the canonicalized absolute path.
Confirmed identical across both engines: P8 → `6e09ad5e9099` in `~/.ctxe/indexes/` *and*
`~/.swctx/indexes/` **[live/src]** — swctx deliberately mirrors the scheme
(`Store.key(for:)`, Store.swift:13-16).

**Catalog ≠ watch intent ≠ authorization.** `list_workspaces` is an accepted-catalog ledger;
`daemon watch` intent is stored separately and reconciled by the daemon **[pub+live]**.

## 4. Configuration

### Layers & precedence **[pub+live]**

`embedded defaults → ~/.ctxe/config.toml (global) → <ws>/.ctxe/config.toml (workspace) → env vars`.
`config set/unset` target workspace layer by default, `--global` for global. `config show` merges
and redacts secrets. Neither `~/.ctxe/config.toml` nor `8.P8_SEO_Clean/.ctxe/config.toml` exists on
this machine → every observed value is `[default]` **[live]**.

### CLI **[pub+live]**

```
config get <DOT_PATH>            config set <KEY> <VALUE> [--global]
config unset <KEY> [--global]    config list [--section <S>]
config show [--format]           config path
```

### Complete default inventory **[live]** (134 keys; `config show` adds the 3 marked †)

```toml
[ask_v4]
compaction.context_pruning_threshold = 700000
compaction.max_compactions_per_session = 24
direct_cap = 1000
edge_confidence_threshold = 0.5
edge_excluded_types = []
edge_thresholds.calls = 0.6
edge_thresholds.imports = 0.7
effort = "min"                      # request-level default; effort is a round budget only
evidence_cluster.max_edges = 20000
evidence_cluster.max_hops = 3
evidence_cluster.max_nodes = 2000
explicit_tools.get_impact_default_hops = 2
explicit_tools.get_impact_max_hops = 4
explicit_tools.graph_paths_default_max_hops = 5
explicit_tools.graph_paths_default_max_paths = 3
explicit_tools.grep_regex_timeout_ms = 2000
follow_up.query_cooldown_rounds = 0
global_deadline_secs = 1200
live_output_budget_tokens = 20000
no_new_evidence_streak_limit = 2
promote_to_consider_cap = 2000
question_weight = 0.6               # † config-show-only
reason_model = null                 # † config-show-only (server-owned override slot)
related_cap = 2000
require_ipc_fence_for_fresh = true
rerank.rerank_parallelism = 4
retry_max_attempts = 3
rrf_k = 60.0                        # † config-show-only — same k as swctx
source_content_cap_tokens = 8192
tier_policy.cap = 20
tier_policy.connect_evidence_decay = 0.5
tier_policy.connect_evidence_hub_degree = 50
tier_policy.connect_evidence_max_hops = 3
tier_policy.top_k = 5
wait_for_indexing = false
wait_for_indexing_poll_interval_ms = 500
wait_for_indexing_timeout_secs = 30

[chunk_typing]   batch_size = 500

[chunking]
error_node_threshold = 0.3
max_lines = 200   max_tokens = 512
merge_threshold_lines = 10
min_lines = 5     min_tokens = 200

[community]
edge_thresholds = { calls .6, extends .6, field_of .7, implements .6,
                    instantiates .6, parameter_type .7, renders .6,
                    return_type .7, uses_type .7 }
enabled = true
health.max_giant_fraction = 0.2   health.max_singleton_fraction = 0.5
health.min_top_5_coverage = 0.01
max_iterations = 30
planner = { default_discover_top_n 5, default_top_k 10, discover_knn_k 150,
            discover_preview_per_community 3, discover_top_n_cap 10, enabled true,
            full_cap 60, full_member_order "file_path_line", top_k_cap 30 }
query = { max_member_fetch 200, max_members 50, score_decay 0.7, top_k 3 }
rebuild_debounce_secs = 60
resolution_gamma = 0.01           # resolution parameter → modularity-style detection [inf]
retrieval = { enabled true, expand_top_k 2, map_top_n 30,
              members_per_community 10, saturation_ratio 0.7, score_decay 0.7 }

[daemon]
file_debounce_secs = 10   flush_interval_secs = 30
initial_reconciliation_delay_secs = 60
latency_profile = "interactive"
startup_jitter_max_secs = 30      tick_window_secs = 5

[enrichment]   default_enabled = false   questions_per_chunk = 5

[general]
db_dir = "~/.ctxe/indexes"
ignore_patterns = [".*", "**/.*", "**/.*/**", "node_modules/**", "target/**",
                   "dist/**", "build/**", ".git/**", "*.lock", "*.min.js",
                   "*.min.css", "vendor/**", "__pycache__/**", ".venv/**",
                   "venv/**", ".idea/**", ".vscode/**"]
max_file_size_bytes = 1048576      # 1 MiB
skip_patterns = ["*_generated.*", "*.pb.go", "*_pb2.py"]
supported_extensions = ["rs","go","java","php","js","jsx","ts","mts","cts","tsx",
                        "py","pyi","mjs","cjs","c","h","md","dart","swift",
                        "svelte","vue","astro","mdx"]           # 23 extensions

[graph]
bundle_neighbors = true        default_mode = "related"     depth_decay = 0.5
edge_weights = { calls .8, exports .5, extends .85, field_of .5, implements .85,
                 imports .7, instantiates .7, parameter_type .6, renders .7,
                 return_type .6, uses_type .6 }              # 11 edge kinds
fallback_min_confidence = 0    graph_neighbor_cap = 0.8     low_recall_threshold = 3
max_candidate_count = 20       max_graph_neighbors = 20     max_hops = 2
min_edge_confidence = 0.6      promote_graph_to_results = false
resolution.checkpoint_wal_threshold_mb = 64                 track_provenance = false

[mcp]        expose_experimental_tools = true     # gates fast_understand/compose_answer [inf]
[pipeline]   foreground_deadline_secs = 1200      max_attempts = 3
[records]    default_list_limit = 20   max_payload_bytes = 2097152
             max_records = 0 (unbounded)   store_full_responses = true
[server]     embed_batch_size = 128   enrich_batch_size = 40   max_concurrency = 10
```

## 5. CLI surface **[pub+live]**

| Command | Flags | Notes |
|---|---|---|
| `login` | `--provider google\|github`, `-f` | OAuth → browser chooser |
| `whoami` / `logout` | `-f` | identity / revoke |
| `index [PATH]` | `--force --dry-run --watch --progress/--no-progress -f` | see §6 |
| `status [PATH]` | `-f` | read-only health; never migrates |
| `ask <QUERY>` | `--effort min\|medium\|high --full --progress/--no-progress -f` | same pipeline as MCP `ask_context` |
| `config …` | §4 | |
| `daemon watch\|unwatch <PATH>` | | durable intent; idempotent; unwatch preserves catalog+artifacts |
| `daemon list/status [-f]` · `enable [--now]` · `disable [--now]` · `start` · `stop` · `restart` | | lifecycle cmds take no path |
| `workspace remove <PATH>` | | destructive, resumable; keeps source files & config |
| `serve` | `--host` (loopback only) `--port` (4590) | local HTTP API for non-MCP clients |
| `mcp` | | stdio; client-owned child process; **not** a daemon |
| `dashboard` | `--port` (25006) `--no-open` | local web UI |
| `community --rebuild\|--stats` | | no path operand |
| `generate-chunk-type-exemplars [PATH]` | `--catalog-dir -o` | server-backed exemplar artifact |
| `classify-chunks [PATH]` | `--all --limit -f` | classify missing/stale embedded chunks |
| `classify-report [PATH]` | `-f` | persisted type distribution |
| `version` | `-f` | |
| `ignore list/check/preview/add/remove --workspace <P>` | `-f` | **[live]** surfaced by the installed `ctxe-index-project` skill; workspace-scoped ignore management |
| `update` | | **[live]** undocumented service entrypoint ("internal entrypoints intentionally not documented" **[pub]**). `wallet` probe → `unrecognized subcommand` (chưa ship); `mcp-config` là của **swctx**, không phải ctxe |
| `index --use-workspace-root` | | **[live]** CLI flag tồn tại (accept ancestor workspace cho explicit path) — docs không ghi |

`-f, --format` = `human | json | compact` on flagged commands only (not global).

## 6. `ctxe index` semantics **[pub+live]**

- Two-phase incremental pipeline: **(1) parse+publish locally** — discovery → ignore rules →
  tree-sitter chunks → symbols/edges → atomic commit; **(2) embed+enrich** — after the write txn
  ends, bounded batches to the server; *"network calls never run inside a database write
  transaction"* **[pub]**. swctx makes the same split for the same reason **[src]**.
- SHA-256-ish file hashing → changed-only reprocessing; `--force` ignores hashes.
- `--watch` is an **ordered composition**: foreground index → durable catalog activation → durable
  Watch Registry transition. It is *not* an in-process watcher and never enables/starts the daemon.
- Exit codes: `0` complete · `2` durable incomplete (pending embed/enrich or foreground timeout
  with a report) · nonzero hard failure · `1` if watch persistence/config fails *after* catalog
  activation (report stays valid; stderr explains) · if daemon notification fails, original
  0/2 preserved and next reconcile applies the intent.
- `--dry-run`: plan only, no writes/network: `{dry_run, files_discovered, would_index,
  would_delete, unchanged, db_available, would_index_files:[{path, reason:"new"}]}`.

### Index report JSON **[live]** (superset of swctx's)

`effective_workspace_root, files_discovered/_indexed/_unchanged/_deleted, chunks_created/
_embedded/_carried_over/_pending/_total, oversized_chunks_observed, resolved_edges_this_run,
summaries_generated/_pending, questions_generated/_pending, chunks_classified, enrich_call_failed,
embed_pending / enrich_pending / question_embed_pending {ready, backoff, unknown, deferred,
blocked_credit, permanent_error}, embed_status_unknown, enrich_status_unknown, earliest_retry_at,
catalog_registered, daemon_watch_command, incomplete, status, errors[], failed_paths[],
failed_deleted_paths[], duration_secs, meta{…}` — where `meta` = the shared response envelope
`{degradation_level, degraded_capabilities[], error_count, has_more, schema_version:"0.1.0",
status, truncation_applied, warning_count}`.

swctx `IndexReport` **[src]**: `workspace, filesTotal, filesIndexed, filesUnchanged, filesDeleted,
chunks, symbols, edges, edgesResolved, embeddedChunks, pendingEmbeddings, embeddingModel?,
durationMs, errors[]` — much thinner (no pending-state machine, no meta envelope, no per-phase
carry-over counters).

## 7. File discovery

| | ctxe **[live]** | swctx **[src]** |
|---|---|---|
| Extension gate | `general.supported_extensions` (23) — **no** json/yaml/html/css/sh/txt | `Languages.extMap` + `baseNames` (makefile/dockerfile/justfile→bash; gemfile/podfile→text) — **adds** json, yaml/yml, html/htm, css, sh/bash/zsh, txt, toml, markdown; **lacks** java, php, c, h, dart, svelte, vue, astro, mdx |
| Hidden | `.*`, `**/.*`, `**/.*/**` denylisted | every `.`-component skipped **except `.github`** |
| Dir denylist | node_modules, target, dist, build, .git, vendor, __pycache__, .venv/venv, .idea, .vscode | 26-name set adds `.build .next .nuxt env out DerivedData .pytest_cache .mypy_cache .tox site-packages Pods Carthage coverage .ctxe .swctx .cache .gradle .terraform` |
| File patterns | `*.lock`, `*.min.{js,css}`; skip `*_generated.*`, `*.pb.go`, `*_pb2.py` | `secretPatterns` (10: `.env credentials secret id_rsa id_ed25519 .pem .key .p12 .pfx .keystore`) — ctxe has **no visible secret denylist** [?] |
| `.gitignore` | honored **[pub]** (plus `ctxe ignore` managed patterns) | minimal subset: `dir/`, `*.ext`, `name`, `/anchored`; **no `!` negation** |
| Size cap | 1 048 576 B | 1 000 000 B (`maxFileSize`) |
| Binary sniff | unknown [?] | NUL byte in first 8 KiB → skipped with error note |
| Other caps | — | `maxFiles = 60_000` |
| Discovery count on P8 | ~3 094 files | 4 753 files (+54% — mostly json/yaml/html/css/sh/txt/toml) **[bench]** |

`ctxe` also has a JS/TS `module_routes` pass — parses package manifests for aliases/entry points
(observed WARN `manifests_skipped=2 manifests_read=3`) **[live]**. swctx approximates module
resolution via `packageIndexStems {__init__, index, mod}` mapping to the parent directory **[src]**.

## 8. Chunking

| | ctxe **[live]** | swctx **[src]** |
|---|---|---|
| Engine | tree-sitter `ts-v1-chunk-v19` + composite language profiles | vendored tree-sitter 0.25 runtime + 12 C grammars |
| Bounds | `min_lines 5 / max_lines 200 / min_tokens 200 / max_tokens 512 / merge_threshold_lines 10 / error_node_threshold 0.3` | `maxChunkLines 400`; window chunks `120` lines, `15` overlap |
| Strategy | syntax-aware decl chunks preserving context | top-level `chunkTypes` decls; oversized decls → child decls + gap windows; uncovered spans → window chunks; markdown → heading `section` chunks (>4 lines); text → windows |
| Data formats | unknown (not in extensions) | json/yaml/html/css get **window** chunks by design (per-pair chunking was "78% of chunks, pure noise") |
| Chunk typing | server exemplars + `classify-chunks`/`classify-report`/`chunk_typing.batch_size=500` | none (kind = node type) |

## 9. Symbols & edges

| | ctxe | swctx **[src]** |
|---|---|---|
| Edge taxonomy | **11 kinds** (config): `calls imports exports extends implements instantiates field_of parameter_type return_type uses_type renders` — older docs listed ~5 ("calls, implementations, imports, type usage, references"); snake_case `EdgeType` names per `find_usages` schema **[live]** | `calls`, `imports`, `implements` (+ `qualifier` column on call edges for `m.f()` receivers) |
| Symbols | per-language defs (counts: P8 19 920) **[live]** | `defTypes`+`defDepths` walk; python module-level `assignment`, json top-level `pair`, markdown `heading`s — non-code symbols inflate totals (P8: 42 140 total ≈ 7.8k code) **[src]** |
| Call denylist | unknown [?] | per-language builtin/stdlib sets (py ~90 names, js/go/rust/swift ~10-20); known FP residuals (`getattr` chains, `close`) **[src]** |
| Resolution | confidence-scored (`graph.min_edge_confidence .6`, `ask_v4.edge_thresholds`, `community.edge_thresholds` per kind); WAL-checkpointed resolver (`resolution.checkpoint_wal_threshold_mb 64`) | 4 deterministic passes re-run every index: **qualified** (import alias/module→files; `self/cls/this/super` excluded) → **same-file** → **imported-file** → **unambiguous-global** (exactly 1 defining file); ambiguous → `dst_chunk NULL` ("better NULL than wrong"). P8: 17 677 edges, 8 294 resolved (calls 54.6%) **[src]** |
| Confidence | per-edge confidence floats; thresholds everywhere | none — resolution is boolean |

## 10. Storage

| | ctxe **[live]** | swctx **[src]** |
|---|---|---|
| Layout | `index.db` + `records.db` **separate** (+ WAL/locks, schema.lock, manifest) | single `index.db` (records live inside) |
| Vector store | `sqlite-vec` **[pub]** | `embeddings(chunk_id, dim, vec BLOB)` + brute-force `vDSP` dot |
| FTS | SQLite FTS5 **[pub]** | `chunks_fts(content, symbol, path)` manual-sync; `records_fts` external-content synced |
| Schema | `index_schema: 28` (managed migrations; `records.schema.lock`; generation locks) | `meta.schema_version = 2`; GRDB migrator `v1`+`v2`; no-op when current |
| Known tables | not directly inspected **[?]** (behavior implies files/chunks/symbols/edges/embeddings + lifecycle state per `get_status`/`get_workspace_tree`) | `meta, files, chunks, symbols, edges(+qualifier), embeddings, chunks_fts, records, records_fts` |
| Concurrency | Ask reads latest commit while writer active **[pub]** | `DatabasePool` WAL + `busy_timeout 10s`; embeddings computed outside write txn |

## 11. Retrieval

| Component | ctxe | swctx **[src]** |
|---|---|---|
| FTS | FTS5 (bm25 implied) | FTS5: OR of `"tok"*` prefix terms (≥2 chars, ≤12), `bm25`, `snippet(«»)` |
| Vector | voyage-code-4 1024-d server-side | BGE-768 CLS-pooled L2-norm → cosine; threshold `>0.05`; embed text = `path\nsymbol\|kind\ncontent[:1800]` |
| Fusion | RRF `k=60`, `question_weight=0.6` | RRF `k=60`, both legs at `limit×3` + boosts: symbol-subtoken `+0.03/term`, path `+0.015/term`, `archive/` `-0.01`, boost cap `0.09` |
| Rerank | server-side; `rerank_parallelism 4`; `inspect_path` rerank pool 150/500 | none beyond RRF+boosts (`inspect_path` delegates to `Search.hybrid` with pool 150/500 — parity) |
| Graph expansion | `graph.max_hops 2`, `max_graph_neighbors 20`, `depth_decay 0.5`, per-kind `edge_weights`, `min_edge_confidence .6`, `bundle_neighbors`, `promote_graph_to_results false` | `graph_expand` depth ≤2, cap 60, decay `0.7^depth`, modes `related\|calls\|imports`, seeds `{chunk_id, score?}` ≤50 |
| Workspace-wide search | **none** — `inspect_path` requires a relative path (`""`/`"."` rejected) **[live]** | `search` tool = swctx-only **[src]** |

## 12. Ask pipeline (`ask_context` / `ctxe ask`) **[pub+live]**

Args: `workspace` (indexed root **or nested dir** — hard-scopes Ask, paths stay root-relative
**[live]**), `query`, `effort min|medium|high`, `compose bool`, `response_language` (≤256 B hint).

- `effort` = planner **round budget only**: min 3 / medium 6 / high 48; early-stop after
  `no_new_evidence_streak_limit` (2) dry rounds. Server owns model reasoning (`/v2/reason`).
- `compose:false` → collector: inspectable grouped source blocks; `compose:true` → synthesized
  report. **Both** omit hydrated `answer.evidence` → `fetch_chunks` for bodies, `get_record` for
  the durable payload. One terminal reason phase; unrendered evidence surfaces only in failure
  fallback.
- Guardrails: `global_deadline_secs 1200`, `retry_max_attempts 3`, `live_output_budget_tokens
  20000`, `source_content_cap_tokens 8192`, `direct_cap 1000`, `related_cap 2000`,
  `promote_to_consider_cap 2000`, `evidence_cluster{2000 nodes/20000 edges/3 hops}`,
  `tier_policy{cap 20, top_k 5, connect_evidence_*}`, `compaction{700k ctx threshold, ≤24/session}`,
  `require_ipc_fence_for_fresh`, `wait_for_indexing{false,500ms,30s}`,
  `edge_confidence_threshold .5`, `edge_thresholds{calls .6, imports .7}`, `edge_excluded_types`,
  `follow_up.query_cooldown_rounds 0`.
- **Evidence validity** captured at read time: `unchanged | changed | unverifiable | missing |
  partial | unavailable` — diagnostics about cited evidence only, not whole-workspace freshness.
- Records: every Ask persists `kind:"ask"` (`running→completed|failed`; `failure_code` ∈
  `collector_failed | composer_failed | ask_deadline_exceeded | insufficient_evidence | …`).
  Timeout recovery = `list_records(kind:ask,source:mcp)` → poll `get_record(id)`; never duplicate.
- `compose_answer(workspace, record_id)`: re-synthesizes **eligible** records (completed collector
  or completed fallback with those 3 failure codes); idempotent, atomic same-record mutation;
  needs `records.store_full_responses=true`; reads saved evidence, not the index/source.

`fast_understand(workspace, query)` **[live]**: **required** `query`; accepts nested dirs;
server-owned everything else; returns "bounded two-pass workspace orientation + routing brief"
with ordered typed **subjects** (route by cardinality) — server-side LLM (~57 s observed,
credit-consuming) vs swctx's deterministic digest (~0.4 s, `query` optional) **[bench/src]**.

## 13. Output-budget contract **[live]**

Shared `meta` envelope (`status`, `degradation_level`, `degraded_capabilities[]`, counts,
`has_more`, `truncation_applied`, `schema_version`). Content omission states:
`content_status = omitted_budget` (chunk body dropped, metadata kept), `payload_status =
not_requested | omitted_budget`, hard error `E_OUTPUT_TOO_LARGE` when even protected metadata
won't fit. Index `status` lifecycle values (tree filter): `all, ready, processing, retry_wait,
blocked_credit, error, empty`; chunk states: `active, embedded, pending_embedding, stale,
terminal_embedding, tombstone`. **swctx has no budget contract** — returns full payloads, can
produce very large responses **[src]**.

## 14. Records ledger

| | ctxe **[live]** | swctx **[src]** |
|---|---|---|
| Store | separate `records.db`; global `record_refs.db` for `ref` selector | `records` table in index.db |
| Selectors | `id` (ws-local int) **or** `ref` (global opaque; `public_id` alias); `include_payload` | `id` only; always full payload |
| Filters | `kind` (ask/memory/design_doc/…), `source` (cli/mcp/http), `status` (running/completed/failed) | same three filters |
| Paging | `limit` 1-100 default 20 (`records.default_list_limit`); offset; budgeted page sizes | `limit` 1-100 default 50; offset |
| Bounds | `max_payload_bytes 2 MiB`, `max_records 0` (∞), `store_full_responses true` | hard cap **1 000 rows/ws** (`insertRecord` tail-trim) |
| FTS | yes (`search_records`) | `records_fts` (title+payload), bm25 |

## 15. Community detection **[live]**

`community.enabled=true`; per-edge-kind confidence thresholds (§4); `max_iterations 30`;
`resolution_gamma 0.01` (resolution parameter ⇒ Louvain/Leiden-class algorithm **[inf]** — exact
algorithm unpublished **[?]**); `rebuild_debounce_secs 60`; health gates `max_giant_fraction .2`,
`max_singleton_fraction .5`, `min_top_5_coverage .01`; separate `planner`/`retrieval`/`query`
tuning blocks; `ctxe community --rebuild/--stats`; `get_status.community{count, largest_size,
publication_available, singleton_count, state}`.

swctx: no persistent community index — `fast_understand` computes union-find connected components
over resolved edges on the fly, labels top-8 by dominant top-dir **[src]**.

## 16. Daemon / watch **[pub+live]**

- LaunchAgent `com.ctxe.daemon` → `ctxe daemon run`; `RunAtLoad`; `KeepAlive.SuccessfulExit=false`
  (crash-only restart); `ThrottleInterval 30s`; `ProcessType Background`; `RUST_LOG=ctxe=info`;
  log → `~/.ctxe/logs/ctxe-daemon.log`. Installed **disabled & stopped**; `enable --now` required.
- Timing defaults: `file_debounce 10s`, `flush_interval 30s`, `initial_reconciliation_delay 60s`,
  `tick_window 5s`, `startup_jitter_max 30s`, `latency_profile interactive`.
- Watch intent ledger `~/.ctxe/daemon/watches.json` (currently absent — no watches) + lock;
  reconciled on daemon start/periodically; durable before daemon notification.
- Per-workspace coordination locks: `workspace-leases/<key>.{activity,generation.legacy-v1,
  lifecycle}.lock`.
- swctx: foreground `swctx watch <path>` — FSEvents (`FileEvents|NoDefer`, 0.5 s latency) →
  relevance filter mirroring discovery rules → 1.5 s debounce → incremental `Indexer.run` on a
  separate queue with rerun-coalescing; `--once` = single pass. No service manager, no durable
  intent **[src]**. (FSEvents unreliable under `/tmp` — documented.)

## 17. Managed update **[live]**

`coordination/updates/`: sha256-named staged candidate, `update.json` state machine
(`phase`, `workspaces[]`, `blockers[]`, drain/verify flags), `owner.lock`, `.bak`. Service
definition is drained+verified during update. swctx: manual `swift build` only.

## 18. MCP surface — 18 = 18 **[live/src]**

Docs promise "all 16 **public** tools"; live 0.4.4 exposes **18** (`fast_understand`,
`compose_answer` ride behind `mcp.expose_experimental_tools` **[inf]**). Both servers: stdio,
client-owned process. swctx server info: `name swctx, version 0.1.0`; ctxe: `name ctxe,
version 0.4.4`. `workspace` must be an absolute path on every workspace-bearing call; ctxe
additionally accepts **nested dirs** (hard-scope) on `ask_context`/`fast_understand`, and
`index_workspace.use_workspace_root` accepts the ancestor root.

ctxe-only MCP controls **[pub]**: `[mcp] exposed_tools` (non-empty list narrows the registry in
order; `["*"]` = all) and `expose_experimental_tools` (gates the 2 extra tools). Client config
per vendor documented: `~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json`,
`.vscode/mcp.json`, `~/.codeium/windsurf/mcp_config.json`. `index_workspace` là tool duy nhất
mutate state; 15 public tools còn lại read-only. swctx chưa có tool-filtering.

| ctxe arg surface | swctx | Δ |
|---|---|---|
| `ask_context(workspace, query, effort, compose, response_language)` | `context_pack(workspace, query, budget≤50, expand, path)` | different contract: LLM planner vs deterministic hybrid+1-hop pack (direct hits carry content; neighbors metadata; persists a record) |
| `compose_answer(workspace, record_id)` | — | intentionally absent |
| `get_status(workspace, groups[]∈{index,community,capabilities,embedding,freshness})` | `get_status(workspace)` | swctx returns one flat `meta{counts,languages,capabilities}`; no groups, no freshness scan, no lifecycle states |
| `list_workspaces(cursor, limit≤100)` | `list_workspaces()` | swctx: no paging; +prunes stale paths |
| `index_workspace(workspace, force, use_workspace_root)` | `index_workspace(workspace, force)` | missing `use_workspace_root` |
| `fetch_chunks(workspace, chunk_ids[], include_content=true)` | same | ctxe adds `omitted_budget`/`E_OUTPUT_TOO_LARGE` semantics |
| `find_definitions(workspace, symbols[1-20], include_content=true)` | same | ctxe returns `definition_symbol_id` usable as `find_usages` selector; swctx matches by name only |
| `find_usages(workspace, symbol_name\|definition_symbol_id, edge_kinds[]=calls+implements, limit≤1000, include_content)` | `find_usages(workspace, symbol_name, edge_kinds, limit≤200→cap, include_content)` | missing `definition_symbol_id`; ctxe max 1000 vs swctx 200 |
| `graph_neighbors(chunk_id, edge_kinds, direction, limit, include_content)` — **1-hop** | same + **`depth` 1–3 BFS** | swctx superset |
| `graph_expand(seeds[{chunk_id,score?}], mode, include_content)` | same | parity of contract; internals differ (ctxe uses graph cfg weights/confidence) |
| `graph_paths(from,to, edge_kinds, max_hops=5, max_paths=3, strategy=shortest\|all\|all_simple, include_content)` | same **− `strategy`**; caps 8 hops/10 paths | missing `strategy` |
| `get_impact(chunk_id, max_hops→clamp[2,4])` — docs ghi `include_content=false` nhưng **live schema đã bỏ arg này** | same + `include_content` default true | **swctx vượt** — ctxe live không còn include_content |
| `get_workspace_tree(workspace, root, max_depth, limit≤1000, cursor, query, status)` | `(workspace, root, limit≤1000, cursor)` | missing `max_depth`, `query`, `status` |
| `inspect_path(workspace, path, query, offset, limit, rerank_pool_size=150/500, include_content)` | same | parity (both reject absolute/`..`; swctx limit≤200) |
| `get_record(workspace, id\|ref, include_payload=true)` | `get_record(workspace, id)` | missing `ref`/`public_id`/`include_payload` |
| `list_records(workspace, kind, source, status, limit≤100, offset)` | same | parity |
| `search_records(workspace, query, kind, source, status, limit, offset)` | same | parity |
| `fast_understand(workspace, query`**required**`)` | `fast_understand(workspace, query?)` | LLM two-pass subjects vs deterministic digest (counts, langs, hub symbols, hot files, union-find communities, recent files, optional top-5) |
| — | `search(workspace, query, mode=hybrid\|fts\|semantic, path, limit≤100)` | **swctx-only** |
| — | `context_pack(…)` | **swctx-only** |

## 19. P8 benchmark (`bench/results.json`, 2026-09-17, single-sample) **[bench]**

| Case | swctx | ctxe | Note |
|---|---|---|---|
| find_definitions | **47.5 ms** exact | 2044 ms exact | same hits |
| find_usages | 11.3 ms exact | 11.1 ms exact | tie |
| inspect_path+query | **570 ms** exact | 1351 ms related | ctxe top-5 all `_legacy` |
| search_equiv | **253 ms** exact | 872 ms related | ctxe path-scoped proxy |
| vn_docs_hybrid | **194 ms** exact | 928 ms related | |
| vn_docs_semantic | **143 ms** related | 887 ms related | ~×6 |
| exact_symbol_hybrid | **187 ms** exact | 870 ms **miss** | swctx hit ctxe missed |
| get_impact | **7.6 ms** | 10.5 ms | |
| graph_expand | **10.6 ms** (24 hits) | 23.6 ms (5 hits) | |
| records_probe | **6.1 ms** | 9.4 ms | |
| graph_neighbors | 17.3 ms | **7.3 ms** | ctxe faster |
| fast_understand | 381 ms | 56 733 ms | **asymmetric**: ctxe = 2-pass server LLM; swctx = local digest |

Caveats: 1 sample each; ctxe cold-start `runtime acquisition timed out after 5000 ms` absorbed by
warmup+retries; `ask_context` deliberately not benchmarked (credit-consuming planner).

## 20. Intentional divergences (not defects)

Cloud vs local · server embeddings vs on-device BGE/NLEmbedding · server LLM Ask vs agent-CLI
reasoning (`context_pack` is the inspectable half) · OAuth/credits vs none · launchd daemon vs
foreground watcher · split index/records DBs vs one DB · confidence-scored graph vs boolean
resolution · budgeted output contract vs raw full payloads · managed update vs manual rebuild.

## 21. Where swctx exceeds ctxe (captured evidence only)

1. **Latency**: won 10/12 cases; some large margins (defs ~×43, semantic ~×6).
2. **Workspace-wide `search`** — no ctxe equivalent.
3. **`graph_neighbors` depth 1–3** — ctxe is 1-hop.
3b. **`get_impact include_content`** — ctxe live schema đã bỏ arg này (docs còn ghi).
4. **`context_pack`** — deterministic, replayable, free.
5. **Index richness on P8** — 4 753 files / 32 536 chunks / 42 140 symbols / 17 677 edges /
   100 % vectors vs ctxe's 3 094 files / 16 500 chunks / 19 920 symbols — driven by broader
   extension set (json/yaml/html/css/sh/txt/toml) + markdown-heading/json-key symbols.
6. **Determinism & inspectability** — plain SQLite, no server variance, no credits, works offline.
7. **Stale-entry pruning** in `list_workspaces`; **secret denylist**; `.github` indexing.

## 22. swctx gaps — prioritized for a local personal app

| # | Gap | Effort | Value |
|---|---|---|---|
| 1 | ~~Agent discovery~~ **done**: registered in `~/.config/devin/mcp_config.json` + `~/.claude.json`; `skills/swctx/SKILL.md` exists | — | highest |
| 2 | `graph_paths.strategy`; `tree.{max_depth,query,status}`; `find_usages.definition_symbol_id`; `get_record.{ref,include_payload}`; `index_workspace.use_workspace_root`; `list_workspaces` paging | low | parity |
| 3 | `index --dry-run` | low | parity |
| 4 | Output-budget contract (`omitted_budget`, `E_OUTPUT_TOO_LARGE`, `meta` envelope) | medium | avoids giant responses |
| 5 | Edge kinds `exports/extends/instantiates/field_of/parameter_type/return_type/uses_type/renders` + per-edge confidence | medium | recall for usages/impact/expand |
| 6 | Watch-intent ledger + launchd integration | medium | freshness without a terminal |
| 7 | `ignore` tooling + per-ws config file | medium | convenience |
| 8 | `get_status` groups + `freshness` scan + lifecycle states | low-medium | diagnostic parity |
| 9 | Persistent community index (ctxe runs detection; swctx computes components ad hoc) | medium | understand/retrieval quality |
| 10 | `ask_context`/`compose_answer` planner, effort tiers, evidence-validity states, ask records w/ failure codes | high | **deliberately out of scope** — agent CLI reasons |
| 11 | `serve` HTTP, `dashboard`, `community` CLI, chunk classification, update/auth, `mcp-config` client auto-registration | high | nice-to-have/N-A for personal app |
| 12 | Non-goal language coverage (java/php/c/h/dart/svelte/vue/astro/mdx) | high | only if needed |

## 23. Unknowns / recommended probes **[?]**

- ctxe `index.db`/`records.db` table schemas (read-only `sqlite3 .schema` on a copied DB).
- Reranker model, enrich payload format, Ask planner internals, community algorithm name.
- Whether `references`/`type_usage` doc terms map to `uses_type`/`renders` config kinds.
- ctxe binary-file handling, `.gitignore` negation support, secret-file policy.
- `question_weight`/`reason_model` semantics (present in `show`, absent in `list`).
- Env-var naming: config precedence kể cả env vars nhưng không có `CTXE_*` name nào được
  capture (chỉ installer-only `CTXE_VERSION`, `CTXE_NONINTERACTIVE`, `RUST_LOG`).
- MCP handshake strictness: ctxe rmcp exit 1 nếu first message không phải `initialize`
  (EOF/ping/tools-list đều fail) — swctx cần probe tương tự.

## 24. Repro commands

```sh
ctxe version; ctxe config list; ctxe config show --format json
ctxe index <p> --format json   # rich report; --dry-run for plan
ctxe daemon status --format json; ctxe community --stats
ctxe mcp  → tools/list          # 18 tools
swctx index <p> --format json; swctx status <p>; swctx discover <p>
swctx mcp → tools/list          # 18 tools
python3 tools/swctx/bench/bench.py   # A/B suite
```
