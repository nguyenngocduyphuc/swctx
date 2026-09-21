Góp ý ctxe — từ vận hành thực tế

Chào Bác,

Như Bác biết em hay mày mò, dạo này em build một bản local tương tự để
học hỏi và chạy đối chiếu với ctxe trên chính các workspace thật của
em, khoảng một tuần nay. Em đo hai bên bằng cùng một bộ câu hỏi luôn.
Có mấy điều em nghĩ Bác nên biết — số liệu đo được kèm theo hết ạ,
không chém.

## Trước hết — điểm ctxe làm rất tốt

- Recall tiếng Việt trong body code rất mạnh — test của em cho 17/19,
  stack đa ngôn ngữ rõ ràng là điểm khác biệt, nên giữ chắc.
- `compose_answer` tái tổng hợp từ record đã lưu — rất hay.
- Planner nhiều vòng trên câu hỏi rộng/mơ hồ: khi hội tụ được thì kết
  quả giàu hơn hẳn các cách retrieval đơn giản.

## Còn mấy chỗ em vấp trong lúc dùng

**1. Chưa có search tool thuần — chỗ này em thấy đáng tiếc nhất.**

Mọi câu hỏi tự nhiên đều phải đi qua `ask_context` = planner + LLM.
Mà đa số việc agent cần chỉ là "biến X nằm file nào" — không cần
synthesis. Em đếm trong records của chính mình: **~42 asks/tuần**.
Phần lớn trong đó lẽ ra chỉ cần một `search` lexical/hybrid trả kết quả
trong vài chục ms. Có tool đó thì server của Bác cũng đỡ tải LLM — đôi
bên cùng có lợi ạ.

**2. Latency của planner hơi nặng cho vòng lặp agent.**

p50 **~35 giây** một ask, p95 tới **~122s**. Agent cần hỏi dò 3-4 câu
liên tiếp thì chờ khá lâu. Bản chất retrieval chỉ vài ms — chi phí nằm ở
các vòng planner chạy tuần tự. Nếu chạy song song các leg +
early-return khi đủ confidence + giới hạn số vòng thì xử được phần lớn ạ.

**3. Chưa phân biệt được convention filename.**

Em test trên repo có nhiều `page.tsx`: `checkin/page.tsx` vs
`events/page.tsx` — yếu tố phân biệt nằm ở **tên thư mục**, không phải
tên file. Nhóm câu hỏi ý-đồ-tên-file em đo được 16/24. Cách fix khá rẻ:
weight path atoms + split camelCase.

**4. Kết quả không deterministic.**

Cùng một query, hai lần chạy ra kết quả khác nhau. User không debug
được, không regression-test được, và khó tin kết quả. Em nghĩ retrieval
nên deterministic, chỉ synthesis mới cần nondeterminism. Bonus nữa:
deterministic thì cache được — mà trong ~42 asks/tuần của em có khá
nhiều câu gần giống nhau, cache theo query-embedding cắt được cả
latency lẫn chi phí server của Bác.

**5. Ask fail vẫn trừ rounds.**

Em thấy 3 ask trong records kết thúc ở trạng thái `failed` nhưng rounds
vẫn bị tiêu. Về cảm giác người dùng thì hơi chua — timeout/lỗi không nên
tính như ask thành công ạ.

**6. Vài bug cụ thể em tái hiện được** (đo trên index.db, có lệnh repro —
chi tiết em để trong file kỹ thuật kèm theo):

- `find_definitions("SiteCleanup")` bỏ sót enum top-level — chunk import
  nuốt mất dòng mở `enum {` nên symbol không được bind
- `inspect_path` + query chỉ rerank trong 150 chunk đầu theo thứ tự
  path — file sort xa là miss cứng
- `ctxe daemon` chết êm: `KeepAlive.SuccessfulExit=0` nên thoát sạch thì
  không restart, watch ngừng mà không báo, status hiện
  `stale (19 pending)` trong khi user tưởng đang live
- `find_definitions`/`find_usages` — lookup SQLite local mà 84-221ms,
  đáng lẽ ~10ms; nếu đang đi vòng qua server thì nên có fast-path local

**7. Mất mạng là mất hết.** OAuth + server là hard dependency. Index đã
sync sẵn mà offline cũng không search được — hơi phí. Fallback trên
cached-index là đủ dùng rồi ạ.

**8. User không xem được usage của chính mình.** Con số 42 asks/tuần em
phải tự đào `record_refs.db` mới ra. Cho user một dashboard nhỏ về
ask/chi phí — transparency là feature giữ chân mà chi phí làm thấp.

## Một gap em vừa phát hiện — đáng kiểm tra phía ctxe

Query tiếng Anh vào file đặt tên tiếng Việt: em test trên repo engine
chưa từng index, nhóm này miss hết (0/3). Phía em fix bằng lexicon
deterministic không tốn chi phí gì — "finished"→{xong,biet},
"daily report"→{bao,cao,ngay}, "command"→{lenh} — đưa vào leg probe
filename, gate theo corpus có morpheme Việt hay không; điểm repo unseen
từ 8/13 lên 13/13. Bác check thử ctxe có dính gap tương tự không ạ.

## Về cách đo — nếu Bác cần

Em đo bằng manifest `{query, expected_paths}`, hash khóa trước khi chấm
nên kết quả không bị tune theo chính nó; chấm R@1/R@5/R@10 + MRR; và
test trên cả repo chưa từng index để lộ gap mà repo quen thuộc không
thấy. Nếu Bác muốn em gửi bộ manifest + script chấm để tự verify trên
máy Bác thì em gửi ngay ạ.

Tóm lại, theo em ba thứ đáng làm trước: **search tool thuần +
path-aware ranking + deterministic retrieval**. Cả ba đều nhẹ về
engineering mà impact trải nghiệm lớn. Cần data gì thêm Bác cứ nói, em
giữ đầy đủ hết ạ.

Em cảm ơn Bác — ctxe thật sự là nguồn cảm hứng để em build bản local
này.
