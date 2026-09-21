# swctx-py — local semantic code index + MCP server (Python, cross-platform)

Pure-local port of the swctx engine for **Windows, Linux and macOS** — no
cloud, no API keys, no credits. Agents connect over MCP stdio; retrieval is
hybrid (SQLite FTS5 + ONNX embeddings + symbol/path/lexicon legs, RRF-fused).

## Install

```sh
pip install .            # from this directory
# or: pipx install . / uv tool install .
swctx-py model install   # downloads bge-base-en-v1.5 ONNX (~420MB) from HF
# weak machines / CI: swctx-py model install potion-multi-int8 (~83MB, ~1ms/embed)
```

Optional AST-aware chunking (recommended — symbol-level chunks):

```sh
pip install ".[ast]"   # tree-sitter-language-pack wheels (win/linux/mac)
```

Without it, indexing falls back to overlapping line windows — everything
still works, symbol tools are just weaker.

## Use

```sh
swctx-py index /path/to/repo          # incremental index + embed
swctx-py search /path/to/repo "query" # CLI sanity check
swctx-py status /path/to/repo
swctx-py watch /path/to/repo          # polling watcher (mtime, ~2s)
swctx-py mcp                          # stdio MCP server
swctx-py simulate /path --diff f.patch  # pre-flight a diff: broken callers/implementers/tests
swctx-py coverage /path --symbol foo    # which tests call foo
swctx-py coverage /path --file tests/test_x.py  # what this test covers
cat crash.log | swctx-py trace /path          # stack frames -> indexed symbols
swctx-py outline /path src/foo.py             # file symbol map, no bodies
```

MCP client config:

```json
{ "mcpServers": { "swctx-py": { "command": "swctx-py", "args": ["mcp"] } } }
```

## MCP tools

`prime` (orientation card — call first) · `get_status` · `list_workspaces` ·
`index_workspace` · `search` · `fetch_chunks` · `find_definitions` ·
`find_usages` · `workspace_tree` · `search_records` · `simulate_patch`
(speculative diff → broken dependents, via the call/extends edge graph) ·
`test_coverage` (symbol↔test map over the same edges: `symbol_name` →
covering tests, `path` → covered production symbols) · `trace_lookup`
(stack trace → indexed frames + suspects, `recent_commit`-flagged) ·
`outline` + `fetch_chunks mode=signature` (task-aware slicing: shapes,
not bodies)

## What it does

- **Incremental index** per workspace: sha256 change detection, tree-sitter
  symbol chunks (12 languages) or line windows, symbol table.
- **Hybrid retrieval**: FTS5 BM25 + ONNX vector cosine + exact-symbol leg +
  filename-intent path probe, fused by reciprocal rank.
- **Cross-language filename atoms**: deterministic EN↔VN lexicon — an English
  query like *"detecting when an agent finished"* still finds
  `BietXong.swift`; Vietnamese queries like *"sổ cái ghi nhận việc"* find
  `LedgerReader.swift`. Gated on the corpus actually containing VN filename
  morphemes so pure-English repos are unaffected.
- **Records + usage telemetry**: `usage_events` and `records` tables give
  agents operational history (what was searched, what was fetched).
- **Light**: model loads lazily and is released after embedding bursts.

Data lives in `~/.swctx-py/` (indexes per workspace, models, catalog).

## Models

| id | dim | langs | note |
|---|---|---|---|
| `bge-base-en-v1.5` (default) | 768 | en | fast CPU embedder |
| `distiluse-base-multilingual-cased-v2` | 768 | 50+ incl. vi | best balance for VN repos |
| `bge-m3` | 1024 | 100+ | heavy — ~450ms/embed on CPU |
| `potion-multi-int8` | 128 | 101 incl. vi | static tier (Model2Vec, distilled from bge-m3) — ~83MB, ~1ms/embed, no neural inference; trades some semantic depth for ~50x faster indexing |

`swctx-py model install [id]` downloads the ONNX export + tokenizer from
HuggingFace. Per-index binding: `swctx-py index <path> --model <id>`.

## Differences vs the Swift original

The Swift build (repo root) runs CoreML on Apple Neural Engine and adds the
full planner/graph/impact toolset. This port targets portability: CPU ONNX
embeddings, the same retrieval shape and lexicon legs, and the core MCP
toolset, plus a regex-based call/extends edge graph powering
`simulate_patch` (speculative diff pre-flight). BFS graph traversal
(`graph_paths`/`get_impact`) and the ask/evidence planner are not ported yet.
