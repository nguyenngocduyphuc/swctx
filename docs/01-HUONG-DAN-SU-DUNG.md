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
