# swctx — local semantic code index + MCP server (Swift)

Swift reimplementation of the [ctxe](https://ctxe.dev) model, without the cloud
part: the "brain" is whatever agent CLI you already run (Devin / Claude Code /
Codex / Cursor) connecting over MCP stdio. swctx only does retrieval.

## What it does

- **Incremental index** per workspace: file discovery, SHA-256 change detection,
  tree-sitter syntax-aware chunks, symbol defs, call/import edges.
- **Hybrid retrieval**: SQLite FTS5 full-text + on-device embeddings, RRF fusion
  with symbol/path boosts. Embedding backend: **bge-base-en-v1.5 CoreML**
  (768-d, `swctx model install` once — weights live in `~/.swctx/models/`);
  falls back to `NLEmbedding.sentenceEmbedding` (512-d) if not installed.
- **Knowledge graph**: `calls`/`imports`/`implements`/`extends`/
  `instantiates`/`uses_type` edges resolved to definition chunks;
  neighbors / paths / transitive impact. `extends` vs `implements` is
  split after resolution: concrete type targets become `extends`,
  protocol/interface/trait targets stay `implements`.
- **MCP server** on stdio with 20 tools; also usable directly as a CLI.

Languages: swift, python, javascript, typescript, tsx, go, rust, json, yaml,
html, css, bash, markdown/text. Data formats (json/yaml/html/css) get
window chunks, not per-element fragments; markdown headings, top-level
json keys and module-level assignments are indexed as symbols.

## Build

```sh
swift build            # debug
swift build -c release # release
```

## CLI

```sh
swctx index <path> [--force] [--skip-embed] [--format json]
swctx status <path>
swctx search <path> "query" [--mode auto|identifier|hybrid|fts|semantic] [--limit N]
swctx tree <path> [--root subdir]
swctx embed <path> [--reindex]   # fill on-device vectors (index auto-embeds all pending; --skip-embed opts out)
swctx watch <path> [--once]      # FSEvents watcher: auto reindex on change (foreground)
swctx discover <path>            # debug: which files discovery would index
swctx model            # install/status the bge-base embedding model (~210MB)
swctx ask <path> "question"   # evidence pack -> local agent CLI (claude/codex/gemini) -> cited answer + record
swctx mcp              # stdio MCP server
swctx mcp-config       # print client config snippet
swctx install-agent [--dry-run]  # register swctx MCP in claude/codex/gemini/cursor/windsurf/devin configs
swctx prime <path> [--format md|json]  # compact context card: counts, freshness, watcher, hub symbols, recent records (alias: brief)
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
| prime | ~300-token orientation card — call first each session (branch, counts, freshness, watcher, hub symbols, warnings) |
| get_status | index state, counts, capabilities |
| fast_understand | deterministic workspace digest: langs, hub symbols, hot files, communities, recent files, optional `query` → top hybrid hits |
| index_workspace | create/update index (the only mutating tool) |
| list_workspaces | indexed workspace registry |
| search | `auto` (default): identifier-shaped queries take the deterministic FTS+symbol path, prose takes full hybrid fusion; explicit `identifier`/`hybrid`/`fts`/`semantic` also accepted; `resolved_mode` reports the pick |
| find_definitions | symbol name → definition locations (`kind` = normalized kind like `struct`/`enum`, `raw_kind` = tree-sitter node type) |
| find_usages | reverse edges: callers/importers/implementers of a symbol |
| fetch_chunks | full source by chunk IDs |
| inspect_path | browse chunks under a path; `query` rerank, `offset`, `rerank_pool_size` |
| get_workspace_tree | paginated file list with counts |
| graph_neighbors | call/import/implements neighbors; `depth` 1-3 BFS; `include_content` |
| graph_expand | scored-seed neighborhood expansion (depth ≤2, score decay) |
| graph_paths | frontier-batched BFS paths between chunks (≤500-id queries, no full-table load); `max_hops`, `max_paths`, `include_content` |
| get_impact | transitive dependents ("what breaks if I change this"); `include_content` |
| context_pack | deterministic multi-round retrieval: hybrid hits + 1-hop call-graph expansion; persists a `records` row |
| get_record | one record by id; `stale` flag when anchors no longer resolve post-HEAD-move |
| list_records | records ledger, filters + pagination + `scope` (workspace/global/all); per-record `stale`/`stale_reasons` |
| search_records | FTS5 over record titles/payloads, same filters + `scope` + `stale` flags |
| put_record | agent-writable memory: kind + title + payload; dual-writes workspace + cross-worktree global ledger; captures git head_sha + resolvable anchors (symbols/paths) so later reads can flag stale |

### Staleness signaling

- Every tool response carries `meta.stale={stale_files,hint}` when the
  index is behind the filesystem (cheap cached check, ~30s TTL) — no
  silent stale reads.
- `put_record` captures `head_sha` + resolvable anchors; reads flag a
  record stale when HEAD moved AND an anchor stopped resolving
  (never on head alone). `prime` marks stale records and counts them.

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

- Tool surface is 20 (19 retrieval + index_workspace): 16 tools are shared parity; each side has two the
  other lacks — swctx: `search` (workspace-wide retrieval), `context_pack`
  (deterministic evidence pack); ctxe: `ask_context`, `compose_answer`
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
