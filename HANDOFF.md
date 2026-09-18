# swctx — Handoff & Status

Date: 2026-09-18 (3rd pass: dual-engine + Phase A-D) · Status: **working, verified end-to-end on 6 workspaces**

## 2026-09-18 — Dual-engine + Phase B/C/D

**Coverage:** swctx + ctxe cùng index 6 workspace (8.P8, 21.linkeldn,
22.site-M, 12.CMS, 25.event-qr-checkin, 18.CRM-Nam-Pham) + NP_AI_macos root
(swctx-only, 61 files) + 4 worktree active. 6 launchd watchers swctx
(`com.swctx.watch.{p8,linkeldn,sitem,cms,qr,crm}`) + ctxe daemon 6 watches.

**Phase B — edge kinds mới** (`Analyzer`/`Indexer`):
- `instantiates`: callee viết hoa (`Foo()`) → edge song song `calls`.
- `uses_type`: `typeRefTypes` per-profile (swift `type_annotation`/`type`/
  `user_type`/`return_type`/`constructed_type`, ts/tsx `type_annotation`,
  python `type`); uppercase-only + `Languages.typeDenylist`; dedupe per
  `line:name` vì node kinds lồng nhau.
- `extends`: post-resolution relabel — `implements` edge resolve tới
  concrete type (class/struct/enum) → `extends`; protocol/interface/trait
  giữ `implements`; repair ngược khi target đổi kind.
- `find_usages` default kinds: calls/implements/extends/instantiates/uses_type.
- Edge counts sau reindex: site-M 50558 (extends 144, instantiates 9160,
  uses_type 5583), linkeldn 26997, P8 20549.

**Phase C — `swctx ask <path> "q"`**: context_pack → spawn agent CLI
headless (auto: claude→codex→gemini, `--agent`/`$SWCTX_ASK_AGENT` chọn,
`--timeout` default 300s) → answer in ra stdout + `records` row kind=`ask`.
Verified live trên 25.event-qr-checkin. Chỉ CLI — cố ý KHÔNG làm MCP tool
(tránh agent→agent recursion).

**Phase D**:
- `swctx install-agent [--dry-run]`: merge `mcpServers.swctx` vào claude/
  gemini/cursor/windsurf/devin JSON + `[mcp_servers.swctx]` TOML cho codex.
  Idempotent, `.bak` backup, absolute path. Đã register cả 6 clients.
- `.swctxignore`: đọc cạnh `.gitignore` (`Indexer.loadIgnorePatterns`),
  cùng syntax, chỉ ảnh hưởng swctx.

**Fixes trong lượt:** `discoverFiles` realpath (firmlink `/tmp`→`/private/tmp`
làm nested files mất prefix → không index được); exact-symbol RRF leg trong
`Search.hybrid` (vector noise từ đè def chunks — case `trimmed`/`SiteCleanup`
trên site-M); `.gitignore` `dir/*/` matcher (vendors 33k files bị index);
status shallow freshness (P8 9.7s→2.7s); `index_workspace.dry_run`,
`use_workspace_root`, `get_workspace_tree` filters, `graph_paths.strategy`,
`find_usages.definition_symbol_id`, `get_record.include_payload`,
metadata-first `include_content=false` defaults; `bench.py --auto` tự pick
probe symbols từ index (kind function/class, in-degree 3-200, exclude
vendors/archive/legacy/outputs).

**Tests 26/26 pass.** Binary release rebuilt; cả 6 client MCP configs đã
có `swctx` (claude/devin trước đó, gemini/cursor/windsurf/codex mới).

---

## 2026-09-17 — Pass 2 (giữ nguyên bên dưới)

Date: 2026-09-17 (2nd pass: review + fixes) · Status: **working, verified end-to-end on P8**

## Vị trí lưu trữ local

| Thứ | Đường dẫn |
|---|---|
| Source (repo riêng, nested) | `/Users/phuongnam/02.AI/NP_AI_macos/tools/swctx/` |
| Binary release | `tools/swctx/.build/release/swctx` (~22MB) |
| Index data | `~/.swctx/indexes/<key>/index.db` (P8 key `6e09ad5e9099`) |
| Workspace registry | `~/.swctx/workspaces.json` |
| Embedding model | `~/.swctx/models/bge-base-en-v1.5/` (model.mlpackage + compiled .mlmodelc + vocab.txt) |
| Benchmark | `tools/swctx/bench/bench.py` → `bench/results.json` |

**Git:** repo riêng trong `tools/swctx/` (`.git` riêng — không làm bẩn workspace cha).
Tất cả files đã `git add` (staged, ~130 files) nhưng **chưa commit** — máy chưa
set `user.name`/`user.email`. Anh commit hộ hoặc cho phép set repo-local identity.

## swctx là gì

Bản Swift/macOS local của [ctxe](https://ctxe.dev): index repo → SQLite
(FTS5 + vectors + symbol graph) → 18 MCP tools cho agent CLI (Devin/Claude/Codex).
Không cloud, không credits, không LLM server — phần "não" là agent CLI gọi MCP.

```
files → discovery(.gitignore-aware) → tree-sitter chunk → symbols/edges
     → SQLite FTS5 + bge-768 vectors → MCP tools → agent CLI tự reason
```

## Stack

- Swift 6.2, SPM; GRDB 7.11 (SQLite+WAL), swift-argument-parser,
  modelcontextprotocol/swift-sdk 0.12.1
- tree-sitter runtime + 12 grammars vendored C (swift/py/js/ts/tsx/go/rust/
  json/yaml/html/css/bash); markdown/text = heuristic
- Embeddings: **bge-base-en-v1.5 CoreML** 768-d on-device
  (`swctx model` cài ~210MB một lần); fallback `NLEmbedding` 512-d
- Ranking: FTS5 bm25 ‖ cosine → RRF(k=60) + symbol/path boosts + archive penalty
- Concurrency: vectors tính ngoài write-txn; busy_timeout 10s; migrate no-op
  khi schema đã current

## Trạng thái index P8 (`8.P8_SEO_Clean`) — verify thật

```
files: 4,753 · chunks: 32,536 · symbols: 42,140
edges: 17,677 — calls 14,685 (54.6% resolved; 5,610 có qualifier)
              imports 2,971 (9.4%) · implements 21 (toàn external bases → 0)
resolved total: 8,294 · vectors: 32,536/32,536 (bge-768, 100%)
```

Lưu ý khi đọc số: `symbols` gồm cả markdown headings (22.4k) + json
top-level keys (12k) — code symbols thật ~7.8k. Resolve rate thấp là
chủ động (better NULL than wrong); `find_usages` vẫn match `dst_name`
trên edge chưa resolve.

## A/B vs ctxe trên P8 (`bench/bench.py` — chạy lại bất cứ lúc nào)

| Case | swctx | ctxe | Kết quả |
|---|---|---|---|
| find_definitions ×2 | **47.5ms** exact | 2.044ms exact | swctx ~×43 |
| find_usages pull_gsc | 11.3ms exact | 11.1ms exact | hòa |
| inspect_path + query | **570ms** exact | 1.351ms related | swctx cả latency lẫn chất |
| search equiv | **253ms** exact | 872ms related | swctx |
| vn_docs_hybrid | **194ms** exact | 928ms related | swctx |
| vn_docs_semantic | **143ms** related | 887ms related | swctx ~×6 |
| exact_symbol_hybrid | **187ms** exact | 870ms **miss** | swctx |
| get_impact | **7.6ms** | 10.5ms | swctx |
| graph_expand | **10.6ms** | 23.6ms | swctx |
| records_probe | **6.1ms** | 9.4ms | swctx |
| graph_neighbors | 17.3ms | **7.3ms** | ctxe nhanh hơn, ngang chất |
| fast_understand | **381ms** | 56.733ms | không đối xứng: ctxe chạy LLM 2-pass server-side |

Latency semantic paths của swctx giảm rõ sau `Embedder.shared` +
pathFilter-vào-SQL (inspect_path 2.076→570ms, search 537→253ms).
Mỗi case 1 mẫu — đọc định hướng, không phải số cam kết.

Tool surface: **18 = 18** (verify qua live `tools/list` ctxe 0.4.4) —
16 tools parity; mỗi bên 2 tools riêng: swctx có `search` (workspace-wide)
+ `context_pack` (deterministic); ctxe có `ask_context`/`compose_answer`
(LLM server-side — cố ý bỏ) + `graph_paths.strategy` (chưa port).

## Verify

```sh
swift build -c release   # sạch
swift test               # 14/14 pass
python3 bench/bench.py   # A/B suite → results.json
```

## Bugs nghiêm trọng đã bắt & sửa (đừng re-introduce)

1. `DirectoryEnumerator.skipDescendants()` trên **file** → mất ~80% P8
   (953→4.750 files sau fix). Chỉ gọi trên directory.
2. WordPiece cap sau-append → seq 514 > model max 512 → ~37% chunks
   (long chunks!) skip embed lặng. Cap per-piece.
3. Embed inference trong write-txn → mọi query `database is locked`.
   Tính vectors ngoài txn.
4. CoreML transient: sau ~16k inferences `prediction` fail → `embedAll`
   recreate `Embedder()` + retry skip-set (max 2).
5. Arbitrary global edge resolve (`cands[0]`) → resolve sai file.
   Giờ 3-pass: same-file → imported → unambiguous-only.
6. `inspect_path` rerank chỉ trên window `limit` đầu — giờ delegate
   `Search.hybrid` + `pathFilter` (pool mặc định 150).

## Còn mở / đường nâng tiếp

- Denylist residuals tiếp (`getattr` chains, `close`…).
- Vietnamese semantic yếu hơn ctxe (bge-en) — FTS đang gánh; cân nhắc
  multilingual-e5-small CoreML nếu cần.
- `graph_paths` chưa có ctxe `strategy` arg; BFS load full resolved-edge
  table vào RAM mỗi call — OK ~17k edges, cần frontier-batched queries
  khi ~100k+.
- Qualified-call resolution chỉ map qualifier→file (import alias/module
  stem); `Type.static()` khi Type là symbol cùng file chưa được resolve
  qua qualifier (rơi về same-file pass).

## Đã xong trong review pass (2026-09-17)

- `edges.qualifier` **populated**: Analyzer bắt receiver root-ident
  (`m.f()` → `m`), resolveEdges thêm qualified pass (alias→module→file).
  `self/cls/this/super` đi qua same-file pass như cũ.
- `Embedder.shared` — process-wide instance cho mọi query path
  (trước ~0.3s CoreML init mỗi call; `get_status` gọi 2 lần).
- `search mode=semantic` giờ honor `path` (dispatch trước drop pathFilter).
- `graph_neighbors`/`get_impact`/`graph_paths` có `include_content`;
  `graph_paths` có `max_paths`.
- `insertRecord` cap 1000 rows/workspace (ledger không phình vô hạn).
- `list_workspaces` prune entry trỏ path đã xóa.
- `embedAll` chặn mixed-dim: stored vectors ≠ model dim → error bảo
  `embed --reindex` (trước: NLEmbedding fallback có thể lẫn 512-d vào
  index 768-d, search im lặng miss).
- MCP error path encode JSON đúng (trước interpolate tay — vỡ khi
  message chứa quote).
- `mcp-config` emit absolute binary path (PATH lookup + cwd fallback).
- Watcher: `stop()` không còn deadlock khi gọi từ chính event queue.
- Tests 11 → 14: +resolveEdges passes, +records round-trip,
  +semantic pathFilter regression.

**Lưu ý vận hành:** Analyzer/extraction upgrade cần `swctx index --force`
một lần — incremental không re-parse file cũ (đã xảy ra: implements
extraction land nhưng index cũ giữ 0 implements edges cho tới khi force).

## Week 0/1 (2026-09-18) — schema v3 + auto + budget

- **Repo có commit đầu tiên** (`main`, local identity `Devin`).
- **schema v3**: `symbols.norm_kind` — kind ngữ nghĩa (`struct/enum/class/
  protocol/extension/variable/function/method/...`), raw node type giữ trong
  `kind`. Vendored swift grammar emit `class_declaration` cho cả struct/enum/
  extension/actor → Analyzer tách bằng decl keyword trong `declText` (256B
  đầu). `find_definitions` trả `kind`=norm + `raw_kind`. Migration tự backfill
  từ `signature`; `--force` cho path `declText` đầy đủ.
- **`extends` relabel** giờ chạy trên norm kinds (`concreteTypeKinds` /
  `abstractTypeKinds` trong Languages). Hệ quả: site-M từng có ~144 `extends`
  sai — target là `extension` decls (raw `class_declaration` cũ bị đếm nhầm
  concrete); giờ giữ `implements` (conservative, đúng hơn).
- **`search mode=auto`** (default, CLI + MCP): `Search.identifierLike` →
  identifier (snake/CamelCase/`::`/dotted/path, 1 token) = hybrid không vector
  leg (deterministic + nhanh hơn; miss trắng thì fallback full hybrid 1 lần);
  prose → hybrid. Response có `resolved_mode`. `identifier` cũng là mode tường
  minh. Nguồn gốc: audit Grok — `mode=semantic` đơn độc miss `SiteCleanup`.
- **Output budget**: mọi tool nhận `max_tokens` (~4 chars/token), hard cap
  64KB luôn áp. Truncate `content/payload/snippet` theo nấc 2048→512→128
  trước, rồi trim array lớn nhất theo nửa đuôi; meta có `truncation_applied`,
  `content_status` (full|truncated|error), `omitted{items,reason,limit_bytes}`;
  không fit được → `E_OUTPUT_TOO_LARGE`. Tất cả qua `SwctxTools.call` wrapper
  (`callRaw` giữ logic gốc).
- Tests 26 → 31.

## Week 2-3 (2026-09-18, 5 agent song song)

- **`put_record`** (tool 19): agent-writable memory — kind allowlist
  (note/finding/decision/todo/context_pack/ask), dual-write workspace records
  + global ledger `~/.swctx/records.db` (`ws` = key của main checkout qua
  `git rev-parse --git-common-dir` → worktree chia sẻ memory với root).
  `list_records`/`search_records` có `scope`: workspace|global|all (union
  dedup theo kind+title+payload).
- **Per-kind record quotas** thay FIFO 1000: context_pack 500, ask 300,
  agent kinds 200, khác 100 — telemetry churn không evict note của agent.
- **`swctx prime`/`brief`**: Markdown context card ~300 token (branch,
  counts, freshness qua `Indexer.freshness`, watcher alive qua pgrep,
  hub symbols theo resolved-edge degree, 5 records gần nhất, warnings).
  `--format json`. Unindexed path → exit 2, không tạo DB rỗng.
- **Force reindex giữ embeddings**: snapshot `(embedText,dim,vec)` vào TEMP
  table trước wipe, restore `INSERT OR IGNORE` join theo exact embed-text
  (path+symbol+content prefix 1800 — đổi path thì re-embed, đúng). Report
  `vectorsPreserved`. P8 force trước đây mất 87% vectors → giờ không.
- **Watcher git-lock backoff**: `.git/index.lock` (kể cả worktree `gitdir:`)
  → defer 5s ×3 rồi mới fire.
- **`graph_paths` frontier-batched**: BFS từng level, `src_chunk IN` ≤500
  ids/query — không load full edge table; `all_simple` query neighbors
  per-node thay vì preload adjacency.
- Tests 31 → 45 (FleetMemory 5, Prime 3, IndexOps 3, GraphPaths 3 — mỗi
  feature 1 test file riêng).

### Bench (bench/ — gold recall + edge audit, chạy thật)

- `bench/gold_queries.json` — 36 câu đã verify đáp án (3 ws × 6 def + 6
  search); `bench/recall.py` — recall@5 qua CLI `search` + `find_definitions`
  MCP persistent session; append `bench/results.csv` (timestamped rows).
- **Kết quả**: swctx search 35/36 = 0.972 (miss duy nhất là near-miss file
  liên quan); `find_definitions` cả hai 18/18. ctxe không có workspace search
  — `inspect_path` scoped 7/18, và trên 2 ws lớn trả **cùng vài hub file cho
  mọi query** (degenerate retrieval).
- **`bench/edge-audit.md` — ctxe 2.38x resolved edges chủ yếu là nhiễu**:
  42% edge ctxe không có trong swctx (75% là `field_of` swctx không emit).
  Sample 100 edge: **real 2, type_ref 38, phantom 60** — phantom = resolve
  sai target (`snapshots.contains`→URL-matcher, `.map`→struct property,
  13 edge có dst_name không hề xuất hiện trong src chunk). Kết luận:
  "better NULL than wrong" đúng — không đuổi edge count.

### Wire-contract fix (2026-09-18, audit opus phát hiện)

- **`obj()` từng flatten params thành sibling keys của `type`/`required`**
  — không có `properties` wrapper → strict clients (Anthropic API) reject
  `put_record` ("schema/title must be string"), 18 tools khai báo 0 params.
  Fix tập trung trong `obj()`: `type`/`required` ở root, còn lại vào
  `properties`. Verify qua `tools/list` thật.
- **`prime` giờ là tool thứ 20** (trước chỉ CLI) — `format=markdown|json`.
- `instructions` server viết lại: encode workflow prime → search → fetch
  → put_record (inject tự động vào mọi agent context).
- `SchemaContractTests` (4 tests): mọi schema là draft-07 object, required ⊆
  properties, reserved keywords không chứa object ở root, prime có mặt.
- Bài học: bench/test phải đi **qua MCP**, không quanh nó — 0.972 đo qua
  CLI path, wire path chưa từng được test tới giờ này.

## Quy ước vận hành

- `swctx index <path>` incremental; `--force` full; `swctx embed` bù vectors;
  `swctx watch` auto-reindex (FSEvents; `/tmp` không bắn event tin cậy).
- stdout = protocol/JSON only; logs → stderr (MCP correctness).
- Model weights KHÔNG commit vào repo (`.gitignore` → `~/.swctx/`).
- Không index `.env`/secrets (denylist trong discovery).
