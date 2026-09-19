# swctx — Bắt đầu ở đây

> **Một câu:** swctx là "Google cho chính code của mình" — một cỗ máy tìm
> kiếm ngữ nghĩa chạy hoàn toàn trên Mac, không cloud, không tốn xu,
> trả lời trong khoảng 100 mili-giây.

## Nó giải bài toán gì

Khi anh (hoặc agent AI) làm việc trong một repo lớn, câu hỏi thường gặp
là: *"đoạn code làm việc X nằm ở đâu?"*, *"hàm này được gọi từ những
đâu?"*, *"sửa chỗ này thì vỡ chỗ nào?"*. Cách cũ: grep, mở hàng chục
file, đoán. swctx trả lời trực tiếp bằng câu hỏi ngôn ngữ tự nhiên —
tiếng Việt cũng được — và trả về đúng file kèm thứ hạng.

## Nó đang chạy ở đâu

- **6 workspace đã được index** và theo dõi tự động (file sửa → tự cập
  nhật): `8.P8_SEO_Clean`, `18.CRM-Nam-Pham`, `21.linkeldn`,
  `22.site-M`, `12.CMS`, `25.event-qr-checkin`.
- **6 agent CLI đã cắm sẵn** (Claude, Devin, Codex, Gemini, Cursor,
  Windsurf): mở phiên agent trong workspace là agent tự có 20 công cụ
  swctx — không cần cài thêm gì.
- Dữ liệu nằm ở `~/.swctx/` (index + model). Source ở `tools/swctx/`.

## Độ tin cậy — nói thẳng

- Mỗi thay đổi đều qua đo lường thật trước khi nhận (xem
  `04-NHAT-KY-QUYET-DINH.md`): 6 cải tiến được nhận, 9 bị loại bỏ vì
  số liệu không chứng minh được lợi ích.
- Recall hiện tại: **13/22** trên bộ probe tiếng Việt; mạnh nhất khi
  câu hỏi khớp tên file/symbol (82%); yếu ở câu hỏi Việt mà mục tiêu
  toàn tiếng Anh (xem `05-GIOI-HAN.md`).
- 115 test tự động, 4 cổng kiểm định chạy hằng đêm (gate), toàn bộ xanh.

## Đọc tiếp theo vai trò

| Anh là... | Đọc |
|---|---|
| Người dùng cuối / CEO | `01-HUONG-DAN-SU-DUNG.md` |
| Người review kỹ thuật | `02-KIEN-TRUC.md` → `03-BANG-CHUNG.md` |
| Người đánh giá quyết định | `04-NHAT-KY-QUYET-DINH.md` → `06-SO-SANH-CTXE.md` + `swctx-vs-ctxe.xlsx` |
