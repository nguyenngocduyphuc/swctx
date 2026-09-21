# Landscape research — local semantic code search MCP engines

NotebookLM deep-research digest (37 imported sources, 2026-09-21).
Notebook: `swctx landscape — local code context engines`
(`8e6295b6-dd7c-400d-a675-a94de3e1a45f`). Full generated report is in
the notebook; this file keeps the decision-grade distillation.

## What the market already commoditized

Every serious local engine converges on the same stack — **none of these
are differentiators anymore**:

- tree-sitter AST chunking (+4.3pt R@5 vs fixed windows)
- hybrid dense+BM25 with RRF fusion (k=60)
- incremental index via file hashes + fs watchers
- symbol tables + call/import/inherit edge graph, recursive-CTE traversal
- MCP stdio server, ~10-20 tools
- optional cross-encoder rerank

Engines surveyed: semantic-code-mcp (LanceDB+ONNX nomic-embed-code),
semcode (Qdrant, git-history collections, framework-aware symbols),
salfatigroup/mcp-code-search (sqlite-vec + e5-large-instruct),
sdsrs/code-graph-mcp (Rust, sqlite-vec+FTS5, recursive CTE call graphs,
HTTP route tracing), zilliztech/claude-context (Milvus cloud),
minishlab/semble (Model2Vec static, ~500ms index / ~1ms query / <50MB),
elastic/semantic-code-search-mcp (Elasticsearch+ELSER), Grapuco (cloud,
blast-radius + rename preview), ctxe (commercial planner+compose).

## Where swctx sits vs the field

Already table-stakes (have): AST chunks, FTS5+vector+RRF, incremental
sha index, watchers, MCP, edges graph, token budget.

Still distinctive (measured or shipped):

1. **CoreML/ANE embeddings** — everyone else is ONNX/Candle/Ollama CPU.
   ~12ms embed on Neural Engine; nothing else touches the ANE.
2. **EN↔VN filename lexicon + corpus-gated probe** — no other engine
   ships cross-language filename atoms; measured 8/13 → 13/13 R@5 on an
   unseen VN-named repo.
3. **Session memory ledger** (`put_record` + staleness anchors on
   git SHA/symbols) — closest analogue is context-graph exploration
   logging in semantic-code-mcp, but without anchor staleness.
4. **Self-tuning loop** (usage_events → mine_queries → optimize →
   4-gate adoption) — nobody else measures themselves.
5. **`simulate_patch`** (this release) — speculative diff pre-flight.
   Grapuco's blast-radius is the nearest concept but analyzes committed
   code only and is cloud-hosted; no local engine simulates mutations.
6. **Measured head-to-head vs a commercial engine** (ctxe, 48q blind
   holdout) — nobody publishes comparative eval.

## Gaps the research surfaced (not yet in swctx)

| Opportunity | Who has pieces | Difficulty |
|---|---|---|
| Git-history indexing (temporal NL queries: "what changed, why") | semcode | low — commits → records/chunks |
| Ultra-light static embedder tier (Model2Vec-style, <50MB, ~1ms) | semble | medium — new model backend |
| Framework-aware symbols (FastAPI routes, Spring, React components) | semcode, code-graph-mcp | medium — per-framework extractors |
| Cold-start progress payloads (structured indexing status, not silence) | edelauna | low — protocol nicety |
| Runtime/stack-trace → AST grounding | nobody | high — new ingestion path |
| Cross-boundary API/schema edges (frontend fetch ↔ backend route ↔ table) | partial (route tracing) | medium-high — new edge kinds |
| Task-aware slicing (drop irrelevant bodies, keep signatures) | nobody | medium — chunker variant |
| Test-coverage map (symbol ↔ executed tests) | nobody | high — needs coverage data |

## Recommendations (ranked by value/effort)

1. **simulate_patch v1** — deepen what we just shipped: AST-parsed added
   side (param-count break detection), resolved-edge filtering to cut
   name-collision noise, test-file proximity scoring. It's the flagship
   differentiator; make it precise.
2. **Git-history records** — cheap (`git log` → records ledger), gives
   temporal queries no local engine does well except semcode.
3. **Framework route edges** — `fetch('/api/x')` ↔ `@app.get('/api/x')`
   ↔ handler; the single most common agent question class.
4. **Static-embedder tier** — optional `potion`-class model for tiny
   machines/CI where 420MB ONNX is too heavy; also the right answer for
   Windows ARM/low-RAM users.
5. Defer runtime-state grounding until the above land (biggest build
   cost, smallest immediate user base).

## Numbers worth remembering

- AST chunking over fixed windows: **+4.3pt R@5** (semantic-code-mcp eval)
- Semantic retrieval token savings vs file-dumping: **40-99%**
- sqlite-vec brute-force: ~45ms @1M vectors — fine for local single-dev
- semble proof point: static Model2Vec ≈ neural quality, 380× faster index
  — embedding model choice is a product tier decision, not a fixed cost
