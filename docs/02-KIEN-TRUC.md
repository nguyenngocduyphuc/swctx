# Kiến trúc — giải thích bằng lời

## Nhìn một lượt

```
file trong workspace
   → phát hiện file (tôn trọng .gitignore + .swctxignore)
   → tree-sitter cắt thành "chunk" theo cú pháp (hàm/class/khối MD)
   → bóc tách symbol (định nghĩa) + edge (gọi, import, kế thừa…)
   → ghi SQLite: FTS5 (từ khóa) + vector embedding (ngữ nghĩa)
   → 20 công cụ MCP để agent hỏi
```

Viết bằng Swift, chạy local, không gọi API nào ra ngoài máy.

## Hai đường tìm kiếm chạy song song rồi hợp nhất

Một câu hỏi được đi qua nhiều "chân" (leg) đồng thời:

1. **Chân từ khóa (FTS5/BM25F)** — match chữ trong nội dung, tên file,
   tên symbol; 4 cột có trọng số riêng.
2. **Chân ngữ nghĩa (vector)** — câu hỏi và chunk cùng nhúng thành
   vector bằng model chạy trên máy; gần nghĩa = gần vector.
3. **Chân symbol** — khớp chính xác tên hàm/class.
4. **Chân cứu tiếng Việt** — vì bộ tokenizer chuẩn không gập dấu `đ`,
   ta tự tạo cột "folded" (bỏ dấu hoàn toàn): *"chấm công"* vẫn tìm ra
   `cham_cong.py` — gồm tail-fill khi cửa sổ từ khóa thiếu kết quả và
   probe cụm-từ-liền-nhau trên tên file.

Bốn chân chạy **song song** (DispatchGroup) rồi trộn bằng RRF — mỗi chân
đóng góp theo thứ hạng, không chân nào được ghi đè chân khác. Thêm boost
nhẹ cho path/symbol khớp và phạt file archive.

## Lưu trữ

- **SQLite + GRDB** một file `index.db` mỗi workspace tại
  `~/.swctx/indexes/<key>/`: bảng files/chunks/symbols/edges/embeddings
  + FTS5 ảo + meta (schema_version, model binding, epoch).
- **Vector sidecar** `vectors.v1.bin` cạnh index: nạp ma trận vector
  một lần thay vì giải mã từng blob — cold-start 3.2s → 0.9s.
- **Model binding per-index**: index ghi nhận model đã embed; cấm trộn
  hai không-gian vector khác chiều/khác model.

## Watcher — tự động giữ index tươi

6 tiến trình launchd (`com.swctx.watch.{p8,linkeldn,sitem,cms,qr,crm}`),
FSEvents + debounce 1.5s → `Indexer.run` incremental. Có chống drift:
trước mỗi lượt index nó đọc `meta.schema_version` **và** sổ cái
`grdb_migrations`; nếu index mới hơn binary thì `abort()` để launchd
respawn bằng binary hiện tại — tránh binary cũ ghi lệch schema (sự cố
đã xảy ra: chunk mới để trống cột `folded`).

## An toàn vận hành

- **`embed --reindex` chịu được kill**: snapshot vector vào bảng
  `vec_snapshot` bền (không phải TEMP) trước khi xóa — chết giữa chừng
  thì lần embed sau tự gắn lại phần chưa re-embed, cùng-dim mới được
  gắn (đổi model → embed mới hoàn toàn, không trộn vector space).
- **`meta.stale`** trên mọi response khi index lệch filesystem.
- **Busy timeout + WAL**: nhiều tiến trình đọc/ghi êm.
- **Output budget**: mọi tool có `max_tokens`, cắt theo nấc, báo
  `truncation_applied` — không bao giờ trả về response quá lớn.

## Bề mặt MCP — 20 tool

`search` · `context_pack` · `fast_understand` · `fetch_chunks` ·
`find_definitions` · `find_usages` · `get_impact` · `get_record` ·
`get_status` · `get_workspace_tree` · `graph_expand` ·
`graph_neighbors` · `graph_paths` · `index_workspace` · `inspect_path` ·
`list_records` · `list_workspaces` · `prime` · `put_record` ·
`search_records`

`search` và `context_pack` là hai tool **không có đối trọng** phía ctxe;
ngược lại `ask_context`/`compose_answer` là hai tool ctxe mà swctx cố ý
không làm (đó là tầng L2, xem `06-SO-SANH-CTXE.md`).
