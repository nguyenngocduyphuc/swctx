# swctx — Handoff & Status

Date: 2026-09-19 (overnight loop + SWE-2 wave) · Status: **working, verified end-to-end on 6 workspaces**

## 2026-09-19 — SWE-2 wave (4 worker song song, ~13:00)

Bốn gap còn lại sau review → cả 4 đã đóng (3 adopted, 1 measured-reject):

- **`embed --reindex` kill-safe** (`2a80b14`): `vec_snapshot` thành bảng
  thật (sống sót process death), snapshot-trước-wipe một committed unit,
  `embedAll()` entry restore phần chưa re-embed (dim guard giữ
  model-switch fresh). All-or-nothing incident đêm qua đã đóng.
  5 EmbedResilienceTests. Residual: same-dim kill → vectors cũ restore
  (index usable ngay, re-embed cần `swctx embed --reindex` mới);
  restore chỉ chạy khi có embed pass.
- **Watcher schema-drift** (`09c1978` + `90087a3`): `indexOnce()` exit
  qua `abort()` khi index schema mới hơn binary — detection đọc
  grdb_migrations ledger (sống sót meta-downgrade); `abort()` là cái
  chết duy nhất respawn được cả 2 KeepAlive policy của 6 plist.
  `Store.migrate` không còn stamp version xuống trên superseded index.
- **swctx↔ctxe A/B** (`9be4b95`): `bench/engine_ab.py` — paired run
  22-query probe qua cả hai MCP. Kết quả: parity chỉ ở
  `find_definitions` (3/4=3/4); ctxe **không có NL retrieval surface**
  (tree raw 0/11, token-sweep 3/11); 7 query không có ctxe surface nào;
  `ask_context` record-view hit 4/4 gồm cả vn_to_en misses của swctx —
  L2 rescue đúng chỗ L1 yếu, giá 200-600× latency + credits + record
  hop. Union 17/22 vs swctx-only 14/22. **L1/L2 thesis có paired data.**
- **e5-large-instruct** (`d2691ed`, W9): REJECTED — MPS 21.6ms trong
  gate nhưng 5 rescued / 5 evicted = net churn 0. Semantic-model map
  đóng: 4 model (distiluse, e5-base, e5-large, bge-m3) không cái nào
  đủ cả quality lẫn latency. Levers còn: CodeRankEmbed, distill bge-m3,
  translation-assisted retrieval.

## 2026-09-19 — Overnight retrieval loop (ITER-1 → ITER-8)

**Scoreboard**: vn probe 16→22 queries; auto recall **8/16 → 13/22**
(baseline mới). Gates xanh: 115/115 tests · ratchet 0.9722 · p95 ~102-116ms ·
schema golden 20 tools · cold_cwd PASS · vn gate `--gate 12`.

**Adopted** (chi tiết `bench/overnight/JOURNAL.md`):
- **Folded Vietnamese rescue** (schema v6): cột `folded` FTS riêng +
  `foldText` app-level (unicode61 không fold đ/Đ). Tail-fill only khi
  window thiếu — +2/16.
- **Folded path-phrase leg**: adjacent folded-token phrases probe
  `path_tokens` (precision > term-OR — 5 variants khác đều rejected).
  +1/16, zero regression.
- **Parallel hybrid legs** (DispatchGroup, DatabasePool concurrent
  reads): VN hybrid 150→95-125ms; ratchet p95 →102.5ms.
- **Vector sidecar** `vectors.v1.bin`: cold first-call 3.2→0.9s
  (epoch-validated, self-healing).
- **LegBag + SearchHit: Sendable** — zero-warning parallel section.
- **Engine_eval records**: `put_record` allowlist + rerank-divergence
  trigger ghi record so engine.
- **`swctx embed --reindex --model`**: dim-mix guard + vec_snapshot
  restore path.

**Rejected (measured, artifacts kept)**:
- `swctx rerank` amberoad mBERT: pinned +1 lúc n=16, absorb bởi folded
  legs → neutral; opt-in.
- `swctx rerank2` bge-reranker-v2-m3: 7/16, 2817ms/pair, prose-bias.
- `swctx rerank3` jina-reranker-v2-base-multilingual: 13/22 neutral,
  1567ms/pair. **3/3 rerankers rejected — losses domain-bound
  (prose-vs-code), không phải capacity.**
- `bge-m3` embedder: offline eval GO (rescue 4/5 dead-leg misses) NHƯNG
  ~410ms/embed mọi compute unit → 3-7× quá gate p95. Spec registered
  (opt-in); `--model bge-m3` works nhưng không phải live default.
- 5 folded-rescue variants khác (merged OR, appended, dedicated leg,
  dedup, no-double-dip) — zero-sum displacement ở n=16.

**e5-base verdict (ITER-8)**: REJECTED — 1/9 rescued + 5 regressions,
cosine nén 0.78-0.89. Latency đẹp (MPS 10ms) nhưng recall không qua.

**Miss map (13/22)**: in_path 9/11 (phrase leg owns) · in_body_only
4/11 (semantic-bound) · vn_to_en 0/5 (needs real multilingual vectors)
· symbol_lookup 2/4.

**Ops notes**: watcher drift + all-or-nothing reindex ĐÃ FIX ở SWE-2
wave (xem section trên) — binary cũ giờ tự abort() cho launchd
respawn; reindex bị kill thì `swctx embed` tiếp theo tự restore.
`.worktrees/` ignored.

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

### Staleness suite + auto-embed + ratchet (2026-09-18, 4 agent song song)

- **Record invalidation** (schema v4): `records` + global ledger có
  `head_sha` + `anchors` (JSON, ≤10 — symbol/path resolvable tại lúc ghi).
  Record = stale khi HEAD đổi VÀ ≥1 anchor không còn resolve — head đổi
  một mình không flag ("better NULL than wrong"). Batch-check ≤2 query
  per response, áp dụng cả scope=all. `prime` đánh dấu `·stale` + count.
- **`meta.stale` trên mọi tool response** khi index lệch filesystem —
  `Indexer.freshness(deep:false)` + cache 30s/workspace, `index_workspace`
  tự invalidate key sau run. Không bao giờ silent-stale kiểu ctxe.
- **Auto-embed tail**: `index` giờ embed HẾT pending chunks (loop
  embedAll, cap 50 batch ~100k) — hết bước `swctx embed` tay. Embed lỗi
  → `report.errors`, không fail index. `--skip-embed` / `skip_embed` arg
  opt-out. `embedMaxBatches` thay `embedBatchLimit` cũ.
- **MCP-wire recall**: `bench/recall_mcp.py` — 36 gold qua persistent
  `swctx mcp` stdio. Kết quả **0.9722 = CLI chính xác**, p95 53-58ms.
  `--ratchet`: fail nếu recall<0.95, p95>150ms, hoặc schema lệch
  `bench/tool_schemas.golden.json` (regen: `--write-golden`).
- **`bench/vn-probe.md` — phát hiện quan trọng**: semantic leg 0/14 trên
  query tiếng Việt (bge-base-**en**-v1.5 vocab English-only → VN text
  thành [UNK] noise); FTS 36% nhờ unicode61 fold dấu. Model đa ngôn ngữ
  (bge-m3-class) đáng đổi HƠN kỳ vọng — experiment tiếp: re-embed 1 ws
  bằng multilingual model rồi chạy lại vn_probe.
- Tests 49 → 57 (StalenessTests 5 + IndexOps +3 auto-embed).

## Quy ước vận hành

- `swctx index <path>` incremental; `--force` full; `swctx embed` bù vectors (index tự embed hết pending);
  `swctx watch` auto-reindex (FSEvents; `/tmp` không bắn event tin cậy).
- stdout = protocol/JSON only; logs → stderr (MCP correctness).
- Model weights KHÔNG commit vào repo (`.gitignore` → `~/.swctx/`).
- Không index `.env`/secrets (denylist trong discovery).

### Audit follow-up fixes (2026-09-18, post-d5685f1)

- **P0 ancestor-walk infinite loop (pre-existing):** `indexedAncestor` walked
  parents via `deletingLastPathComponent` with a `parent == self` stop — but
  Foundation returns `/..` for the parent of `/` on this macOS, so any
  `tools/call` without `workspace` from a cwd with no indexed ancestor spun
  forever (each iteration paying a `checkResourceIsReachable` syscall).
  Verified by process sample + standalone repro (`/` → `/..` → `/../..` …).
  Fix: terminate when the parent stops shrinking + 64-deep bound. Any agent
  terminal opened outside an indexed tree wedged its swctx server on the
  first no-workspace call — the same class of silent wedge that hurt ctxe.
- **`scope=global`/`all` no longer needs a workspace:** when auto-resolution
  finds no index, the global ledger still answers (all repos, `ws` field on
  each row) instead of erroring not-indexed; explicit workspace keeps the
  per-repo filter. Verified live: `list_records`/`search_records`/`get_status`
  from an unindexed cwd all respond.
- **`swctx gc`:** collects orphaned indexes under `~/.swctx/indexes/` —
  orphan = `meta.workspace_root` no longer on disk; dry-run by default,
  `--yes` deletes, 1h mtime safety window, dead registry entries pruned.
  Read-only GRDB can't open hot-WAL DBs (SQLITE_CANTOPEN on recovery) —
  probe falls back to a normal open; that fallback is what kept two live
  384MB worktree indexes out of the orphan list. First real run: 678
  collected, ~112MB freed, 22 live kept.
- **Unbounded-loop audit (P0 follow-up):** swept every `while`/`repeat`/
  recursion/traversal in `SwctxCore` — all terminate (bound, visited-set,
  shrinking measure, or finite structure). `graph_paths` BFS confirmed:
  `seen` set + `depth < maxHops` + ≤500-id frontier batches. Only remaining
  `while true` loops are intentional: `embedAll` (attempted==0 / retry cap /
  batch cap) and the watcher keep-alive (cancellable `Task.sleep`).
- **`get_record scope=workspace|global|all`:** same contract as
  list/search_records — `global` reads this repo's shared ledger
  (`AND ws = ?` when a workspace resolves, unfiltered when none does);
  `all` tries workspace first then global; a missing index under
  auto-resolution is fine for global/all (store=nil). Record ids are
  **per-ledger namespaces** — `put_record` returns the workspace
  `record_id` only (the global copy has its own id; read it back via
  `scope=global` list/search). Global rows carry `ws` naming the repo key.
  `context_pack` rows are workspace-local by design (payload references
  per-index chunk ids).
- **MCP `tools/call` deadline:** every tool call races a per-tool deadline
  (60s default, `index_workspace` 1800s for auto-embed on large trees) in
  `MCPServer.withDeadline`. A wedged handler — including a non-cooperative
  CPU loop that ignores cancellation — still answers the client with
  `{"error":{"code":"E_DEADLINE_EXCEEDED"}}` + `isError:true`; the leaked
  task is cancelled and abandoned. This is the systemic fix for the
  ancestor-walk wedge class: even an unknown future hang cannot silence
  the server.
- **Cold-cwd wire guard:** `McpColdCwdTests` spawns `swctx mcp` with cwd in
  an unindexed temp dir and asserts no-workspace `tools/call` responses
  arrive inside a bounded window; `bench/cold_cwd.py` runs the same check
  against the release binary. Nightly gate: `bench/nightly.sh` (cold-cwd +
  `recall_mcp.py --ratchet`) is installed as `com.swctx.bench` at 03:30 —
  failures append `~/.swctx/bench_failures.log`.
- **Multilingual embeddings (vn-probe follow-up):** `distiluse-base-
  multilingual-cased-v2` adopted as a second supported model — converted
  to CoreML (bit-exact vs HF), WordPiece-compatible via the tokenizer's
  new cased mode, mean pooling, 768-d. Model choice is a **per-index
  binding** (`meta.embedding_model`/`embedding_dim`, written once at
  fresh-DB creation; legacy DBs implicitly bge/768). Precedence: index
  binding > `--model` > `SWCTX_MODEL` > default; MCP calls follow the
  bound model via `Embedder.shared` re-resolution. `swctx model` now
  lists; `model install [<id>] [--from dir]` installs. Measured A/B on
  the same chunks (bench/vn_model_spike.md): VN semantic recall@5 0/14→
  1/14 but target-vector ranks improved ~10–50× (leg repaired; recall@5
  now ranking-bound), embed ~2.5× faster (p95 10.1ms vs 27ms), pure-EN
  rank regressed — keep bge on English-heavy workspaces. P8_SEO_Clean +
  18.CRM-Nam-Pham are bound to distiluse (`index.db.bge-bak` beside each
  DB; rollback `swctx embed --reindex --model bge-base-en-v1.5`).
- **Folded token-boundary path boost (2026-09-18):** `Search.hybrid`'s
  path boost was raw `lp.contains(term)` — phantom substring boosts and
  accented VN terms never matched ASCII path tokens. Now `foldText`
  (diacritic+case fold, explicit đ/Đ→d) applied to both query terms and
  per-path tokens split on non-alphanumerics; boost stays 0.015/token.
  Measured on the 16-query vn-probe: `crm-06` miss→rank 1, auto 6/16→
  **7/16** (VN 5/14→**6/14**), zero regressions; matches the offline
  simulation. Covered by `testFoldText` + `testPathBoostFoldedTokenBoundary`.
  **Rejected after measurement:** widening the vector-leg candidate window
  `limit*3→limit*12` — deep vector noise (ranks 15-60) diluted RRF and
  regressed auto to 6/16 (lost seo-08); true targets sit at vector ranks
  ~140-800, unreachable anyway. Next VN lever is weighted fusion or
  query rewriting, not window size. Ratchet still PASS (0.9722, p95
  46.1ms, 20-tool golden); cold_cwd PASS; 78/78 tests.

## 2026-09-19 — Phase A/B: BM25F + PageRank + coverage + trigram(opt-in) + reranker(opt-in)

Merged two worker lines (reranker spike + ranking signals); every claim
below is measured on the live indexes, not simulated.

- **BM25F field scoring (adopted):** `chunks_fts` now has 3 columns —
  `content`, `path_tokens`, `symbol_names` — scored with weighted
  `bm25()` (note: bm25 returns negative; sign flipped). Migration v5
  rebuilds FTS and backfills path/symbol columns for existing chunks.
- **File PageRank (adopted):** `Indexer.updatePageRank()` runs after
  edge resolution — file nodes, arcs from resolved chunk edges, result
  stored in `files.pagerank` and consumed as a plain join in ranking.
- **Atom coverage + depth penalty (adopted):** coverage capped at 0.03;
  shallower path wins ties (`testDepthPenaltyPrefersShallower`).
- **Candidate-pool API:** `Search.hybridCandidates` returns the fused
  pool before the limit cut — this is what the rerank stage consumes
  (pool 30), deliberately NOT the rejected `limit*12` RRF widening:
  reranker re-orders by content score so wide-pool noise self-demotes.
- **Trigram substring leg (opt-in, off by default):** FTS5 trigram
  table exists (SQLite 3.43.2 supports it) but only populates when
  `meta.trigram=1` via `swctx index --trigram`; search leg gated on the
  flag. Reason: populated trigram cost ~45% index size (P8 719→684MB
  after reclaim, CRM 15→12MB) and on the vn-probe it never fired — the
  fused pool never under-filled. Enable per-workspace if substring
  lookup proves needed (`testTrigramFallbackOnlyUnderFull` +
  `testTrigramDisabledByDefault` cover both sides).
- **Cross-encoder reranker (opt-in):** `amberoad/bert-multilingual-
  passage-reranking-msmarco` → CoreML at `~/.swctx/models/amberoad-
  bert-multilingual-reranking-msmarco/` (WordPiece, pair-encoding with
  token_type_ids, relevant-class logit). `search` tool param
  `rerank:true` + `swctx rerank` CLI; pin top-3 fused hits, rerank the
  rest of the 30-pool. **Measured on final merged code**
  (bench/rerank_eval_final.json): pure rescoring net-neutral 8/16→8/16
  (gained seo-01/seo-07, demoted seo-02/crm-02 — confirms the spike's
  "pure rescore hurts code hits" finding); pinned mode sim 8/16→
  **9/16** (+1: gains kept, crm-02 still lost — its best chunk sat at
  pool rank 25, mBERT-2019 scores short VN queries weak). ~14ms/pair,
  ~0.4s/call — opt-in only, default search unchanged.
- **vn-probe on final code: auto 7/16→8/16 (50%), VN 6/14→7/14**;
  crm-06 semantic leg now hits (sem=1). Ratchet PASS (0.9722,
  schema 20 tools incl. new `rerank` param, cold_cwd PASS) — but p95
  moved 46→111ms from BM25F+PageRank+coverage work; under the 150ms
  gate, logged as a real latency cost of the ranking batch.
- **85/85 tests.** New: `Reranker.swift`, `RankingSignalTests` (7),
  `bench/convert_reranker.py`, `bench/rerank_eval.py`,
  `bench/rerank_spike.md`.

## 2026-09-19 — Overnight loop ITER-1..5 (autonomous, measured)

Full experiment log: `bench/overnight/JOURNAL.md`. Only adopted changes
are listed here; every rejected variant (and why) is in the journal.

**Scoreboard: vn-probe auto 8/16 → 11/16 (69%), VN 7/14 → 10/14.**

- **Folded column + tail-fill (adopted, +2/16):** `chunks_fts` v6 adds a
  4th column `folded` (app-level foldText — đ U+0111 never folds via
  unicode61/remove_diacritics). `Search.fts()` runs primary first; when
  under-filled, `folded : "term"*` tops up — folded matches can never
  displace real hits (same contract as the opt-in trigram leg).
- **Folded path-phrase leg (adopted, +1/16):** `foldedPhraseQuery` emits
  adjacent-token `path_tokens : "cham cong"` phrases for
  diacritic-changing pairs only, fed as a 4th RRF leg (cap 5, weight
  0.8, file-deduped). Rescues filename-intent VN queries (crm-01)
  without the term-OR flooding that killed 5 cheaper variants. Phrase
  precision + the 2.5-weighted path column is the working combination.
- **Parallel legs (adopted):** `hybridCandidates` runs fts/semantic/
  symbol/phrase concurrently on a DispatchGroup — DatabasePool serves
  concurrent reads, embed inference overlaps FTS IO. VN hybrid
  ~150ms → ~95-125ms warm. Latency-only; hits identical.
- **Vector sidecar (adopted):** `vectors.v1.bin` beside index.db — flat
  epoch-validated matrix dump written after the first blob-path load.
  Cold semantic CLI call 3.2s → 0.92s. +100MB disk per index.
- **Process-level vector cache (adopted, ITER-3):** row-major matrix
  cached per workspace (LRU×4, 512MB cap), validated by
  `meta.embeddings_epoch` nonce, one `cblas_sgemv` per query, metadata
  fetched for top-k only. Semantic warm ~130ms → ~50ms.
- **engine_eval records:** divergence between baseline top-5 and rerank
  top-5 writes `put_record kind=engine_eval` (dual scope) — paired-data
  flywheel is live.
- **nightly += vn_probe --gate:** VN regression net wired.

**Rejected on measurement (see journal for the full table):**
- Weighted/score-normalized RRF — global sem weight hurt every combo.
- amberoad mBERT reranker: after folded tail-fill, pinned mode is
  NEUTRAL (pool-semantics fix exposed the earlier +1 as an artifact).
- bge-reranker-v2-m3 (W3 spike): 7/16 vs 10/16 baseline, 0 gains,
  2817ms/pair CPU-bound — prose-biased cross-encoder, domain mismatch.
  Kept as opt-in `rerank2` reference impl only.

**Semantic leg is the real ceiling:** sem=1/16 on the probe. The 5
remaining misses (seo-04/05/06, crm-04, crm-08) are cross-language
vocabulary gaps, not lexical — `in_path` queries now 7/9 while
`in_body_only` is 4/7. Lever: a better multilingual embedder (bge-m3
offline eval in flight) — not more FTS surgery.

**Tokenizer asset:** `SPTokenizer.swift` — SentencePiece unigram port
verified byte-exact vs the real BGE-M3 vocab (250K pieces). Unlocks
bge-m3/XLM-R-class models when the embedder spike lands.
