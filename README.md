# swctx — local semantic code index + MCP server (Swift)

Swift reimplementation of the [ctxe](https://ctxe.dev) model, without the cloud
part: the "brain" is whatever agent CLI you already run (Devin / Claude Code /
Codex / Cursor) connecting over MCP stdio. swctx only does retrieval.

**Đọc cho người dùng / review (tiếng Việt): [`docs/00-BAT-DAU.md`](docs/00-BAT-DAU.md)**
— 6 file hoàn chỉnh + Excel so sánh ctxe (`docs/swctx-vs-ctxe.xlsx`).

## Quickstart (new machine)

Requirements: macOS (Apple Silicon recommended — embeddings run on the
Neural Engine), a Swift toolchain (Xcode or `xcode-select --install`),
Python 3 only if you want to convert extra models.

```sh
git clone https://github.com/nguyenngocduyphuc/swctx.git && cd swctx
swift build -c release
sudo cp .build/release/swctx /usr/local/bin/    # or any dir on PATH
swctx model install                              # ~210MB CoreML embedder from HF
swctx index /path/to/your/repo                   # incremental index + embed
swctx mcp                                        # stdio MCP server
```

Then point your agent CLI at it (`swctx install-agent` merges the config
for Claude Code / Codex / Gemini / Cursor / Windsurf / Devin), or add
manually:

```json
{ "mcpServers": { "swctx": { "command": "swctx", "args": ["mcp"] } } }
```

Cross-platform note: this repository also ships `swctx-py/` — a pure-Python
port (SQLite FTS5 + ONNX embeddings + MCP) that runs on Windows, Linux and
macOS. See `swctx-py/README.md`.

## What it does

- **Incremental index** per workspace: file discovery, SHA-256 change detection,
  tree-sitter syntax-aware chunks, symbol defs, call/import edges.
- **Hybrid retrieval**: SQLite FTS5 full-text + on-device embeddings, RRF fusion
  with symbol/path boosts. FTS is fielded (`content`, `path_tokens`,
  `symbol_names`, `folded`) and scored with weighted BM25; a file-PageRank
  over resolved call/import edges contributes a static signal; the legs
  (fts, semantic, symbol, folded-phrase) execute concurrently and fuse by
  reciprocal rank. Vietnamese diacritic queries get two app-level rescues
  (unicode61 never folds `đ`): a `folded`-column tail-fill that tops up an
  under-filled fts window, and a folded adjacent-phrase probe on
  `path_tokens` for filename intent (`chấm công` → `cham_cong.py`).
  Embedding backend is a **per-index model binding**
  (`meta.embedding_model`): **bge-base-en-v1.5** CoreML (768-d, default) or
  **distiluse-base-multilingual-cased-v2** (768-d, 50+ langs incl. Vietnamese —
  measured ~10–50× better target ranks on VN queries, ~2.5× faster embed,
  weaker on pure-English queries; see `bench/vn_model_spike.md`). Select with
  `--model` at index time or `swctx embed --reindex --model <id>`; weights
  live in `~/.swctx/models/`; falls back to `NLEmbedding.sentenceEmbedding`
  (512-d) if the bound model is not installed.
- **Knowledge graph**: `calls`/`imports`/`implements`/`extends`/
  `instantiates`/`uses_type` edges resolved to definition chunks;
  neighbors / paths / transitive impact. `extends` vs `implements` is
  split after resolution: concrete type targets become `extends`,
  protocol/interface/trait targets stay `implements`.
- **MCP server** on stdio with 21 tools; also usable directly as a CLI.

Languages: swift, python, javascript, typescript, tsx, go, rust, json, yaml,
html, css, bash, markdown/text. Data formats (json/yaml/html/css) get
window chunks, not per-element fragments; markdown headings, top-level
json keys and module-level assignments are indexed as symbols.

## Build

```sh
swift build            # debug
swift build -c release # release
```

Release: `scripts/release.sh` builds the release binary, self-tests it
(`--version` + `prime` on this repo), and verifies `~/.local/bin/swctx`
points at `.build/release/swctx` (mismatches are reported, never
repointed silently); `--tag` additionally creates annotated git tag
`v<version>`. `bench/nightly.sh` also runs `bench/corruption_gate.py`,
which injects index corruption into a throwaway index copy and fails if
the binary crashes instead of degrading gracefully.

## CLI

```sh
swctx index <path> [--force] [--skip-embed] [--model <id>] [--trigram] [--format json]
swctx status <path>
swctx search <path> "query" [--mode auto|identifier|hybrid|fts|semantic] [--limit N]
swctx rerank <path> "query" [--limit N]  # hybrid pool + amberoad cross-encoder rescore (opt-in spike)
swctx rerank2 <path> "query" [--limit N]  # same pool via bge-reranker-v2-m3 — measured REJECT on the vn probe (prose-biased, ~160x slower); kept as reference impl
swctx tree <path> [--root subdir]
swctx embed <path> [--reindex] [--model <id>]  # fill on-device vectors (index auto-embeds all pending; --skip-embed opts out)
swctx watch <path> [--once]      # FSEvents watcher: auto reindex on change (foreground)
swctx discover <path>            # debug: which files discovery would index
swctx model            # list known models + installed status
swctx model install [<id>] [--from <dir>]  # install the bge-base default (~210MB) or a converted CoreML dir
swctx ask <path> "question"   # evidence pack -> local agent CLI (claude/codex/gemini) -> cited answer + record
swctx simulate <path> [--diff file.patch]   # pre-flight a unified diff: broken callers/implementers/tests before writing
swctx mcp              # stdio MCP server
swctx mcp-config       # print client config snippet
swctx install-agent [--dry-run]  # register swctx MCP in claude/codex/gemini/cursor/windsurf/devin configs
swctx prime <path> [--format md|json]  # compact context card: counts, freshness, watcher, hub symbols, recent records (alias: brief)
swctx gc [--yes] [--min-age-hours N]   # collect orphaned indexes under ~/.swctx/indexes (dry-run first)
```

Index data lives in `~/.swctx/indexes/<workspace-key>/index.db`; workspace
registry in `~/.swctx/workspaces.json`.

File discovery honors `.gitignore` plus an optional `.swctxignore` at the
workspace root (same syntax: `dir/`, `*.ext`, `name`, `/anchored`,
`dir/*/`; comments `#` and blank lines ok; `!` negation is skipped).
`.swctxignore` only affects swctx, never git.

## Connect an agent CLI

Any MCP client: point it at the built binary, or run
`swctx install-agent` to merge the entry into known client configs
(idempotent; writes a `.bak` next to each file it changes).

```json
{
  "mcpServers": {
    "swctx": { "command": "/path/to/swctx", "args": ["mcp"] }
  }
}
```

## MCP tools

| Tool | Purpose |
|---|---|
| prime | ~300-token orientation card — call first each session (branch, counts, freshness, watcher, hub symbols, warnings); surfaces newest shared-ledger records + `Resume:` from the latest session checkpoint so a fresh session picks up where the last stopped |
| get_status | index state, counts, capabilities |
| fast_understand | deterministic workspace digest: langs, hub symbols, hot files, communities, recent files, optional `query` → top hybrid hits |
| index_workspace | create/update index (the only mutating tool); also ingests `git log` into `kind="commit"` records — sha, author, date, changed paths, workspace-relative for nested repos |
| list_workspaces | indexed workspace registry |
| search | `auto` (default): identifier-shaped queries take the deterministic FTS+symbol path, prose takes full hybrid fusion; explicit `identifier`/`hybrid`/`fts`/`semantic` also accepted; `resolved_mode` reports the pick. `rerank:true` (opt-in) rescues hard NL queries: pins the fused top-3 and cross-encoder-rescores the 30-candidate pool via the amberoad mBERT model — ~0.4s/call, neutral-to-+1 on the vn probe, off by default |
| find_definitions | symbol name → definition locations (`kind` = normalized kind like `struct`/`enum`, `raw_kind` = tree-sitter node type) |
| find_usages | reverse edges: callers/importers/implementers of a symbol |
| fetch_chunks | full source by chunk IDs; `mode=signature` returns declaration lines only (~10% tokens — read the shape when the body is not needed) |
| outline | one file → symbol map (kind, line range, signature) with no bodies — the cheap "what is in this file" |
| inspect_path | browse chunks under a path; `query` rerank, `offset`, `rerank_pool_size` |
| get_workspace_tree | paginated file list with counts |
| graph_neighbors | call/import/implements neighbors; `depth` 1-3 BFS; `include_content` |
| graph_expand | scored-seed neighborhood expansion (depth ≤2, score decay) |
| graph_paths | frontier-batched BFS paths between chunks (≤500-id queries, no full-table load); `max_hops`, `max_paths`, `include_content` |
| get_impact | transitive dependents ("what breaks if I change this"); `include_content` |
| *(edge kind)* | `api_call` links frontend call sites to backend route defs across files: `fetch('/api/users')` resolves to the chunk holding `@app.get('/api/users')` — route paths are indexed as `route` symbols, so `find_usages("/api/x")` and impact traversal cross the HTTP boundary for free |
| simulate_patch | speculative pre-flight: unified `diff`/`diff_file` → changed/removed declarations → every indexed caller, implementer and test that would break — before the patch touches disk |
| test_coverage | static test↔symbol map over call edges: `symbol_name` → test chunks that exercise it ("which tests to run for this change"); `path` → non-test symbols that file covers ("what this test actually tests") |
| trace_lookup | paste a crash stack trace (`trace`/`trace_file`) → Python/JS/Go/generic frames suffix-matched to indexed files and mapped to enclosing symbols; `suspects` = callers of the deepest matched frame, flagged when the file was touched by a recent commit |
| context_pack | deterministic multi-round retrieval: hybrid hits + 1-hop call-graph expansion; persists a `records` row |
| get_record | one record by id; `scope` (workspace default, global, all = workspace first then global); `stale` flag when anchors no longer resolve post-HEAD-move |
| list_records | records ledger, filters + pagination + `scope` (workspace/global/all); per-record `stale`/`stale_reasons` |
| search_records | FTS5 over record titles/payloads, same filters + `scope` + `stale` flags |
| put_record | agent-writable memory: kind + title + payload; dual-writes workspace + cross-worktree global ledger; captures git head_sha + resolvable anchors (symbols/paths) so later reads can flag stale |
| checkpoint | one-call session memory: `summary` + `next` + auto HEAD/branch/dirty-files → dual-write; the next session's `prime` card surfaces it as `Resume:` |

### Record scopes

The workspace ledger and the repo-wide global ledger are **separate id
namespaces** — the same integer `id` names a different record in each.
`put_record` dual-writes but returns only the workspace `record_id` (plus
`scope: workspace+global` when the shared write landed); the global copy
gets its own id — find it via `list_records`/`search_records scope=global`.
Global rows carry a `ws` field (the repo key), and scoped global reads
filter on it whenever a workspace resolves. `context_pack` records are
workspace-local by design: they reference per-index chunk ids.

### Staleness signaling

- Every tool response carries `meta.stale={stale_files,hint}` when the
  index is behind the filesystem (cheap cached check, ~30s TTL) — no
  silent stale reads.
- `put_record` captures `head_sha` + resolvable anchors; reads flag a
  record stale when HEAD moved AND an anchor stopped resolving
  (never on head alone). `prime` marks stale records and counts them.
- Git history lands in the same ledger: every `index_workspace` run
  ingests commits scoped to the workspace subtree (worktree/nested-repo
  aware, incremental via a stored head, dedup by sha). Commit rows are
  immutable facts — they carry no anchors so they never flag stale, and
  they sort last in `list_records`/`prime` so bulk history never floods
  agent-authored memory. Query them with `search_records` (e.g. "when did
  X land", "which commit touched file Y").

### Response budget

Every tool accepts `max_tokens` (≈4 chars/token). When a response exceeds the
budget — or the always-on ~64KB hard cap — oversized `content`/`payload`/
`snippet` strings are cut to a small excerpt first, then top-level arrays are
trimmed tail-first (hits are ranked, so the tail is the least valuable part).
Every response carries `meta.truncation_applied` + `meta.content_status`;
when items were dropped, `meta.omitted` reports `{items, reason, limit_bytes}`.
If even metadata can't fit, the tool returns `E_OUTPUT_TOO_LARGE` instead of
a multi-megabyte payload.

## Differences vs ctxe

- Tool surface is 25 (24 retrieval + index_workspace): 16 tools are shared parity; each side has tools the
  other lacks — swctx: `search` (workspace-wide retrieval), `context_pack`
  (deterministic evidence pack), `simulate_patch` (speculative diff
  pre-flight over the call graph), `test_coverage` (symbol↔test map),
  `trace_lookup` (stack trace → indexed frames), `outline` +
  `fetch_chunks mode=signature` (task-aware slicing); ctxe: `ask_context`,
  `compose_answer`
  (server-side LLM planner, consumes account credits).
- No cloud server, no OAuth, no credits — embeddings run on-device
  (bge-base CoreML, `NLEmbedding` fallback), planning/reasoning is done by
  your agent CLI, not by us.
- `swctx watch` covers the daemon-watch use case in-process (FSEvents + debounce +
  incremental reindex). Note: FSEvents does not reliably fire under `/tmp`.
- `context_pack` is the inspectable-evidence half of `ask_context`; the LLM
  compose/planner half stays in your agent CLI by design.
- Symbol extraction also covers markdown headings and top-level json keys —
  `symbols` counts include non-code entries by design.
- Incremental indexing skips unchanged files by SHA-256 — after an
  Analyzer/extraction upgrade (e.g. new edge kinds), run `swctx index --force`
  once to re-parse existing files.
