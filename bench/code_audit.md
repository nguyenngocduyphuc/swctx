# Code audit — OpenCodeReview deterministic pass (2026-09-19)

Tool: `vendors/open-code-review` (Alibaba) in `delegate` mode — ocr resolved the
Swift/Python precision-first rules and selected the review scope; the host agent
performed the review. No LLM provider was configured for ocr itself.

Scope reviewed (project-owned code only):

- `Sources/SwctxCore/` — all 20 Swift files: TSWrapper, Embedder, BGEEmbedder,
  SPTokenizer, MCPServer, Analyzer, Store, Search, Indexer, Watcher, Tools,
  GlobalRecords, ContextPack, Prime, Understand, Gc, Reranker(+V2/V3), Languages.
- `Sources/swctx/main.swift` — CLI dispatch, ask/install-agent/mcp-config.
- `Tests/SwctxCoreTests/` — 18 files, ~3.5k lines (grep + targeted reads).
- `bench/` — MCPSession (bench.py), recall_mcp.py, engine_ab.py, nightly.sh;
  model eval/converter scripts scanned.

Excluded: vendored tree-sitter generated C grammars (`CGrammars/`), JSON
artifacts, docs. HEAD at audit: `751cf16`.

## Findings

### F1 — `install-agent` can register a dead executable path (medium-high)

`Sources/swctx/main.swift` ~829-832: the installed `command` is derived from
`CommandLine.arguments[0]` + `standardizingPath`, falling back to cwd. Invoked
via PATH, `argv[0]` is just `swctx` → the generated client configs point at
`$PWD/swctx`, which does not exist → all six MCP client registrations fail
silently at next client start.

`McpConfigCmd` resolves PATH correctly; `install-agent` does not — an internal
inconsistency, not a missing feature.

Fix: resolve `argv[0]` through PATH when it has no slash (share the helper
with `McpConfigCmd`), or install the absolute path of the running binary
(`ProcessInfo.processInfo.arguments[0]` is equally affected — resolve via
`which`-style PATH scan).

### F2 — malformed vector sidecar can crash the process (medium)

`Search.swift` ~346 (`readVectorSidecar`): `Int(n)` traps when the stored
`UInt64` count exceeds `Int.max`, and `off + cnt*8 + cnt*dim*4` is evaluated in
`Int` arithmetic that can overflow before the bounds comparison. A corrupt or
hand-crafted `vectors.bin` kills the MCP server instead of falling back to DB
blobs.

Fix: guard `n <= Int64.max`/`Int.max` before `Int(n)`; compute the required
byte size with `multipliedReportingOverflow`/`addingReportingOverflow` (or
check `cnt <= (fileSize - off) / (8 + dim*4)` division-first), and on any
failure return nil → existing blob path handles it.

### F3 — process-global embedding-model binding cross-talks workspaces (medium, latent)

`Embedder.swift` `bindModel` writes a process-wide `boundID`; `Store.init`
calls it per opened index. One `swctx mcp` process serving two workspaces whose
indexes carry different `meta.embedding_model` bindings lets the second open
rebind the shared embedder → workspace A's semantic leg embeds queries in the
wrong vector space → silent semantic misses (no error).

Currently benign: all six live indexes bind `distiluse`. Latent: first
mixed-model index makes it real.

Fix: make the model binding per-Store (embedder instance or model id carried
on the Store and threaded through `Search.hybrid`), or at minimum detect the
mismatch and log/refuse rather than silently rebind.

### F4 — `swctx ask` pipe-buffer deadlock (medium)

`main.swift` `AskCmd.spawn`: `waitUntilExit()` runs before
`readDataToEndOfFile()` on stdout/stderr. An agent CLI writing >64KB (pipe
buffer) to either stream blocks in `write()`, never exits → outer timeout kills
it → the answer is lost and reported as timeout.

The correct pattern already exists in `Prime.probe` (drain pipes on a
background queue, then wait). Fix: reuse it.

### F5 — SPTokenizer protobuf length trap (low-medium)

`SPTokenizer.swift` ~679 `ProtoReader.fieldData`: varint length → `Int(len)`
traps on values > `Int.max` (varint admits up to ~2^70). A malformed model
file crashes instead of throwing `malformedModel`.

Fix: `guard len <= UInt64(Int.max), Int(len) <= remaining` before slicing.

### F6 — BGEEmbedder assumes fp32 CoreML output (low-medium, latent)

`BGEEmbedder.swift` ~317/326/330: `hidden.dataPointer.withMemoryRebound(to:
Float.self)` with no `dataType` check. An fp16-output model yields silent
garbage embeddings (no error). `Reranker.swift` already handles this correctly
via the `NSNumber` accessor (`logits[...].floatValue` converts fp16).

Current models verified fp32 — latent hazard for future model swaps.

Fix: `guard hidden.dataType == .float32` (fail loud) or read via NSNumber
accessor like the reranker.

### F7 — FSEvents callback use-after-free (low, narrow)

`Watcher.swift` ~68-70: context stores `Unmanaged.passUnretained(self)`; a
callback queued before `FSEventStreamInvalidate` but delivered after the
watcher deallocs calls `takeUnretainedValue()` on freed memory. `watch` mode
keeps the watcher alive for process lifetime, so the window is mainly
test/stop-then-drop paths.

Fix: `passRetained` + `release()` after invalidate-and-set-nil ordering, or a
weak-box context.

### F8 — analyzer transparent-recursion depth bypass (low)

`Analyzer.swift` `emitChunks`: recursion through `transparentTypes` ignores the
`depth < 3` cap (`||` branch). Pathologically deep generated input could
overflow the stack during indexing.

Fix: enforce an absolute depth cap (e.g. 64) on the transparent path too.

### Observations (checked, no defect)

- SQL: every interpolated identifier/value found is parameterized or built
  from `Int64` placeholders — no injection surface.
- `Indexer.embedAll` ordering (restore → snapshot → delete → dim-guard → loop)
  is correct; snapshot survives process death as designed (W7).
- `Watcher` drift check reads `grdb_migrations` (durable) not just `meta` (W8);
  `Store.migrate` no longer stamps schema_version downward (90087a3).
- `MCPServer` deadline wrapper single-resume slot is correct; wedged-op
  continues in background (documented).
- `Prime.probe` drains pipes before wait — the pattern `AskCmd` should share.
- `bench/` scripts: subprocess all list-form, no shell=True/eval/secrets;
  engine_ab fairness rules are explicit and enforced.
- `GlobalRecords.git` uses the read-after-exit pattern but `rev-parse` output
  is <<64KB — safe today, worth sharing the `Prime.probe` helper anyway.
- `Prime.watcherAlive` prefix match (`contains(root.path)`) can false-positive
  on sibling dirs sharing a path prefix (`/tmp/x` vs `/tmp/xyz`) — cosmetic.
- `bench.py` `MCPSession.request`: `readline()` after `select` can block past
  the deadline on a partial line — harness-only, low.
- Embed text truncation diverges at the boundary: Swift `.prefix(1800)`
  (graphemes) vs SQL `substr(…,1800)` (code points) — restore-key mismatch
  only on combining-mark boundaries; rare, noted.

## Resolution — all findings fixed (2026-09-19, same day)

| # | Fix | Test evidence |
|---|---|---|
| F1 | `resolveExecutableOnPATH` shared by `mcp-config` + `install-agent` | manual: PATH-invoked `install-agent` now writes real absolute path |
| F2 | `Int(exactly:)` + division-first bound before any multiply | `testSidecarRejectsCountBeyondIntMax`, `…OverflowingCount`, `…TruncatedPayload`, `…RoundTripsValidData` |
| F3 | `Store.embedder` → `Embedder.instance(forModelID:)` — per-model pinned instance via shared backend cache; all ~20 `Embedder.shared` call sites migrated (`shared`/`bindModel` kept for compat, no longer on any query path) | `testStoreEmbedderPinsIndexModel` |
| F4 | `AskCmd.spawn` drains stdout+stderr concurrently via DispatchGroup before waiting | code-reviewed; pattern now matches `Prime.probe` |
| F5 | `fieldData`: `Int(exactly:)` + `n <= data.count - pos` | `testSPTokenizerRejectsGiantFieldLength` |
| F6 | `guard hidden.dataType == .float32` before `withMemoryRebound` | covered by existing embed tests (fp32 path unchanged) |
| F7 | `passRetained(self)` + release in `stopOnQueue` after invalidate on the same serial queue | code-reviewed (no FSEvents test harness) |
| F8 | absolute `depth > 64` cap at `emitChunks` entry — covers transparent-type bypass AND oversized-split recursion | existing analyzer tests unchanged/pass |

**LLM second pass** (ocr scan via agy-CLI shim, Search.swift pilot):

- CONFIRMED F2 (independent re-derivation).
- NEW REAL BUG fixed: `raw.bindMemory(to: Float.self)` on SQLite BLOB /
  `Embedder.vector(from:)` — `bindMemory` requires 4-byte alignment a `Data`
  buffer does not guarantee → both sites now `copyBytes` into aligned array
  storage (`testVectorFromUnalignedBlobDecodes`).
- PARTIALLY REAL: `SELECT DISTINCT … ORDER BY lower(s.name)` — does not
  error on SQLite 3.43 (verified live), but multi-symbol joins made
  def-first ranking non-deterministic → `GROUP BY` + `MIN(CASE…)`
  (`testSymbolHitsRankDeterministicWithMultiMatch`).
- REJECTED: `SQLITE_LIMIT_VARIABLE_NUMBER` (SQLite ≥3.32 allows 32766 vars;
  RRF candidate set is bounded far below), `group.wait()` thread starvation
  (standard GCD pattern; dispatched legs never depend on the caller thread).

Gate: `swift test` 123/123 green (115 + 8 new audit regressions).
