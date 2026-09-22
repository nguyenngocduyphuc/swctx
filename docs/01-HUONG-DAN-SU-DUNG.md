# Hướng dẫn sử dụng

## Cách 1 — Qua agent AI (khuyên dùng, không cần nhớ lệnh)

Mở phiên Claude / Devin / Codex / Gemini / Cursor / Windsurf trong một
workspace đã index. Agent tự có các công cụ swctx; cứ hỏi bình thường:

- *"script tính chấm công của nhân viên từ nhật ký hoạt động"*
- *"hàm `push_gsc` được gọi từ những đâu?"*
- *"sửa `handleCheckout` thì những file nào bị ảnh hưởng?"*
- *"đọc cho anh nội dung chunk X"*

Agent sẽ tự gọi `search`, `find_definitions`, `find_usages`,
`get_impact`, `fetch_chunks`… — 20 tool tất cả. Quy tắc routing đã cài
vào skill: **mọi việc tìm-đọc-đồ-thị đi qua swctx (miễn phí)**; chỉ câu
hỏi cần tổng hợp suy luận sâu mới gọi ctxe (`ask_context`, trả credits).

## Cách 2 — Dùng tay qua CLI

```bash
BIN=tools/swctx/.build/release/swctx

# Thẻ định hướng workspace (~300 token: branch, số lượng, độ tươi,
# symbol trung tâm, ghi chú gần nhất, cảnh báo)
$BIN prime /path/to/workspace

# Tìm kiếm ngữ nghĩa (mode mặc định "auto" tự chọn đường đi)
$BIN search /path/to/workspace "đối soát quyết định CEO với việc thật"

# Tìm định nghĩa / nơi sử dụng một symbol
$BIN defs /path/to/workspace ten_ham_hoac_class
$BIN usages /path/to/workspace ten_ham

# Sức khỏe index (số chunk/vector/file stale)
$BIN status /path/to/workspace

# Index tay khi cần (thường không cần — watcher tự làm)
$BIN index /path/to/workspace          # incremental
$BIN index /path/to/workspace --force  # build lại từ đầu
$BIN embed /path/to/workspace          # bù vector còn thiếu
```

## Cách 3 — Bộ nhớ chung giữa các phiên (fleet memory)

Agent có thể ghi/đọc ghi chú bền qua `put_record` / `search_records`:
quyết định, phát hiện, todo — tồn tại qua phiên và chia sẻ giữa các
worktree của cùng repo. Ghi chú tự gắn anchor (symbol/path) và tự đánh
dấu `·stale` khi code đổi làm anchor không còn resolve.

## Những gì tự động — không cần làm

- **6 watcher** (launchd `com.swctx.watch.*`) theo dõi file thay đổi và
  re-index incremental. Nếu watcher chạy binary cũ hơn schema index, nó
  tự chết để launchd nạp binary mới — không còn ghi dữ liệu lệch schema.
- **`embed --reindex` an toàn với kill**: snapshot vector trước khi xóa;
  bị SIGTERM giữa chừng thì lần `swctx embed` sau tự phục hồi.
- **Cổng đêm** (`com.swctx.bench`): cold-start, recall ratchet, probe
  tiếng Việt — hỏng gì thì log `~/.swctx/logs/`.

## File `.swctxignore`

Đặt cạnh `.gitignore` trong workspace, cùng cú pháp — loại file/thư mục
khỏi index của swctx mà không đụng git.

## Recipes — ba tool proactive trên index thật

Ba tool này đọc index (không ghi), dùng được cả khi chưa sửa code.
Gọi qua agent (Cách 1) hoặc CLI/`swctx mcp`.

### 1. Kiểm tra ảnh hưởng trước khi sửa — `simulate_patch`

```bash
# Diff đang có trên working tree hoặc từ một commit
git -C /path/to/workspace diff > /tmp/change.diff
$BIN simulate /path/to/workspace --diff /tmp/change.diff

# hoặc qua stdin
git show HEAD~3 | $BIN simulate /path/to/workspace
# qua agent: "simulate_patch với diff này trên workspace X"
```

Output tốt: mỗi `changed_symbols` có `path`, `symbol`, `kind`,
`callers` (kèm `line` + symbol của nơi gọi) và `tests` bị ảnh hưởng. `body_changes` liệt kê hunk chỉ đổi thân hàm; với chunk lớn
không có symbol riêng thì `enclosing_symbol`/`enclosing_kind` chỉ ra
declaration chứa nó (`symbol_source: "owner_decl"`). Đổi signature thì
`risk` báo arity và call-site sẽ gãy. File bị xóa giữ đúng path của nó.

### 2. Test nào cover symbol này — `test_coverage`

```
# qua agent: "test_coverage symbol_name=LocalStore trên workspace X"
#        hoặc "test_coverage path=Tests/.../LibraryRetrievalTests.swift"
```

- `symbol_name` → các test chunk gọi/instantiate symbol đó, gộp một
  dòng per chunk: `edges` (các loại edge), `call_lines` (dòng gọi
  thật). Chỉ file có `test`/`spec` trong path được tính.
- `path` (trỏ file test) → các symbol non-test mà file đó cover qua
  call edge đã resolve.
- Giới hạn: static approximation — dynamic dispatch, test gọi qua
  chuỗi/string-key không được mô hình; method test trong chunk cỡ
  class được quy về chunk chứa nó.

### 3. Dán crash trace — `trace_lookup`

```
# qua agent: "trace_lookup trace=<toàn bộ stack trace>" hoặc
#            "trace_lookup trace_file=/tmp/crash.txt"
```

Parse Python (`File "...", line N`), JS/TS (`at ... (path:line)`),
Go (`path:line +0x`), generic `path:line`, và Swift fatal error
(`file /path/x.swift, line N`). Path tuyệt đối/CI (`/Users/ci/build/
repo/...`) được suffix-match về path relative trong index.

Output tốt: mỗi frame có `matched`, `path` trong index, `chunk_id`,
`symbol` (`symbol_source: "owner_decl"` nếu frame rơi vào chunk
window và symbol được suy từ declaration chứa nó). Frame không khớp
(thư viện ngoài) vẫn được liệt kê với `matched: false`. `suspects`
= caller của frame khớp sâu nhất, kèm `recent_commit` nếu vùng đó
vừa bị commit đụng tới.
