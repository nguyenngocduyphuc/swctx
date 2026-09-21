# swctx-py — local semantic code index + MCP server (Python, cross-platform)

Pure-local port of the swctx engine for **Windows, Linux and macOS** — no
cloud, no API keys, no credits. Agents connect over MCP stdio; retrieval is
hybrid (SQLite FTS5 + ONNX embeddings + symbol/path/lexicon legs, RRF-fused).

## Install

```sh
pip install .            # from this directory
# or: pipx install . / uv tool install .
swctx-py model install   # downloads bge-base-en-v1.5 ONNX (~420MB) from HF
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
```

MCP client config:

```json
{ "mcpServers": { "swctx-py": { "command": "swctx-py", "args": ["mcp"] } } }
```

## MCP tools

`prime` (orientation card — call first) · `get_status` · `list_workspaces` ·
`index_workspace` · `search` · `fetch_chunks` · `find_definitions` ·
`find_usages` · `workspace_tree` · `search_records`

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

`swctx-py model install [id]` downloads the ONNX export + tokenizer from
HuggingFace. Per-index binding: `swctx-py index <path> --model <id>`.

## Differences vs the Swift original

The Swift build (repo root) runs CoreML on Apple Neural Engine and adds the
full planner/graph/impact toolset. This port targets portability: CPU ONNX
embeddings, the same retrieval shape and lexicon legs, and the core MCP
toolset. Graph traversal (`callers`/`callees`/`impact`) and the ask/evidence
planner are not ported yet.
