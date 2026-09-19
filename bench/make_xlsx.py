#!/usr/bin/env python3
"""make_xlsx.py — rebuild docs/swctx-vs-ctxe.xlsx from measured evidence.

Sources: bench/engine_ab_results.json (paired probe), bench/parity_probe
output (full-surface coverage), bench/ask_full_results.json (full miss
coverage), model verdict docs. Regenerate after each benchmark run.
"""
import os
import openpyxl
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "docs", "swctx-vs-ctxe.xlsx")

# ---------- styles ----------
TITLE = Font(bold=True, size=14, color="1F3864")
H2 = Font(bold=True, size=11, color="1F3864")
HDR_FILL = PatternFill("solid", fgColor="1F3864")
HDR_FONT = Font(bold=True, color="FFFFFF", size=10)
SW_FILL = PatternFill("solid", fgColor="E2EFDA")   # green = swctx win
CX_FILL = PatternFill("solid", fgColor="FCE4D6")   # orange = ctxe win
PAR_FILL = PatternFill("solid", fgColor="FFF2CC")  # yellow = parity
THIN = Border(*[Side(style="thin", color="B0B0B0")] * 4)
WRAP = Alignment(wrap_text=True, vertical="top")

def sheet(wb, name, widths):
    ws = wb.create_sheet(name)
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w
    return ws

def header_row(ws, r, cols):
    for c, v in enumerate(cols, 1):
        cell = ws.cell(r, c, v)
        cell.fill, cell.font, cell.border = HDR_FILL, HDR_FONT, THIN
        cell.alignment = Alignment(wrap_text=True, vertical="center")

def put(ws, r, vals, fills=None):
    for c, v in enumerate(vals, 1):
        cell = ws.cell(r, c, v)
        cell.border, cell.alignment = THIN, WRAP
        if fills and fills[c - 1]:
            cell.fill = fills[c - 1]

wb = openpyxl.Workbook()
wb.remove(wb.active)

# ============ SHEET 1: Tổng quan ============
ws = sheet(wb, "Tong quan", [24, 42, 42, 34])
ws.cell(1, 1, "swctx vs ctxe — So sánh hai engine retrieval").font = TITLE
ws.cell(2, 1, "Nguồn: engine_ab (22 query VN) + parity_probe (18 tool) + "
    "ask_full_misses (9/9 miss) — đo trên MCP stdio thật, 2026-09-19"
    ).font = Font(italic=True, size=9, color="666666")
ws.cell(4, 1, "KẾT LUẬN NHANH").font = H2
put(ws, 5, ["Union coverage", "swctx search 13/22 (59%) free ~100ms",
    "ctxe ask_context cứu 9/9 miss còn lại",
    "Hai engine ghép đôi = 22/22 (100%) probe"],
    [None, SW_FILL, CX_FILL, PAR_FILL])
put(ws, 6, ["Điểm quyết định",
    "Mỗi query L1 trả lời ngay, không tốn gì",
    "L2 trả credits + 12-65s nhưng cứu cả vn_to_en",
    "Không thay thế — bổ sung"], [SW_FILL, None, CX_FILL, None])
header_row(ws, 8, ["Hạng mục", "swctx", "ctxe", "Ghi chú"])
rows = [
    ("Vai trò kiến trúc", "L1 — retrieval phản xạ (local)", "L2 — oracle synthesis (server LLM)", "Dual-engine by design"),
    ("Chạy ở đâu", "100% on-device Mac", "Index local + LLM server ctxe", "swctx offline hoàn toàn"),
    ("Chi phí / query", "$0 — không giới hạn", "Credits cho ask_context/fast_understand; symbol/tree/records free", "16/18 tool ctxe vẫn free local"),
    ("Privacy", "Query + code không rời máy", "Query + evidence gửi server khi ask", "swctx an toàn cho code nhạy cảm"),
    ("Latency retrieval", "p50 ~100ms, p95 ~620ms", "find_defs p50 7ms; tree 41ms", "ctxe nhanh hơn ở surface free"),
    ("Latency synthesis", "context_pack deterministic ~giây", "ask_context 12-65s + record hop", "ctxe sâu hơn nhưng chậm"),
    ("NL search ngữ nghĩa", "search: FTS+vector hybrid, recall 59%", "KHÔNG có surface NL retrieval free", "Điểm khác biệt lớn nhất"),
    ("vn → en gap", "0/5 (yếu điểm đã đo)", "ask_context cứu 2/2 vn_to_en sampled", "P2 roadmap của swctx"),
    ("Graph quality", "edges ít hơn nhưng đúng; get_impact hydrated", "edges nhiều hơn, get_impact thin (hop+score)", "swctx thực dụng hơn"),
    ("Records/memory", "GlobalRecords + usage_events ledger (mới)", "records + ask history server-side", "Parity cơ chế, khác phạm vi"),
    ("Telemetry adoption", "usage_events + swctx stats (P1, live)", "không có tương đương phía client", "swctx tự đo được adoption"),
    ("Cài đặt/vận hành", "1 binary, 6 watcher launchd, install-agent", "CLI + daemon + server dependency", "swctx đơn giản hơn nhiều"),
]
for i, r in enumerate(rows, 9):
    put(ws, i, r)
    if r[0] in ("NL search ngữ nghĩa", "Telemetry adoption", "Privacy", "Chi phí / query", "Cài đặt/vận hành"):
        ws.cell(i, 2).fill = SW_FILL
    elif r[0] in ("vn → en gap", "Latency retrieval", "Latency synthesis"):
        ws.cell(i, 3).fill = CX_FILL

# ============ SHEET 2: Benchmark ============
ws = sheet(wb, "Benchmark do that", [34, 10, 10, 11, 10, 10, 40])
ws.cell(1, 1, "Paired benchmark — 22 query VN, cùng workspace, file-recall@5"
    ).font = TITLE
ws.cell(2, 1, "Gold path KHÔNG truyền vào retrieval call; ctxe index đã "
    "verify chứa đủ 22/22 expected path trước khi chấm").font = Font(
    italic=True, size=9, color="666666")
header_row(ws, 4, ["Surface", "n", "Hits@5", "Recall@5", "p50 ms",
                   "p95 ms", "Nhận xét"])
bench = [
    ("swctx · search (hybrid)", 22, 13, "0.59", 101.4, 621.4,
     "Surface NL retrieval duy nhất free — L1 backbone", SW_FILL),
    ("swctx · search on concept_flow", 18, 11, "0.61", None, None,
     "Mạnh nhất ở path-aware (82%)", None),
    ("swctx · find_definitions", 4, 3, "0.75", 12.2, 14.8,
     "Parity ctxe", PAR_FILL),
    ("ctxe · find_definitions", 4, 3, "0.75", 6.7, 7.3,
     "Parity swctx, nhanh hơn ~2x", PAR_FILL),
    ("ctxe · workspace_tree raw NL", 11, 0, "0.00", 41.2, 208.7,
     "Substring filter — không phải semantic search", None),
    ("ctxe · workspace_tree token-sweep", 11, 3, "0.27", 424.2, 1717.1,
     "Workaround ≤12 calls/query — vẫn yếu", None),
    ("ctxe · ask_context live wire", 10, 2, "0.20", 20335.9, 60229.3,
     "Live response thiếu file_path — cần record hop", None),
    ("ctxe · ask_context durable record", 10, 9, "0.90", None, None,
     "9/10 (record 9/9 miss + seo-01); L2 rescue thật", CX_FILL),
]
for i, (s, n, h, r, p50, p95, note, fill) in enumerate(bench, 5):
    put(ws, i, [s, n, h, r, p50, p95, note],
        [fill, None, None, None, None, None, None])
ws.cell(14, 1, "Miss-rescue: 9/9 query swctx search miss đều được ctxe "
    "ask_context record cứu (rank 1-3); crm-08 còn được find_definitions "
    "cứu free.").font = H2

# ============ SHEET 3: Ma tran tinh nang ============
ws = sheet(wb, "Ma tran tinh nang", [22, 13, 13, 16, 46])
ws.cell(1, 1, "Toàn bộ tool surface — 20 swctx / 18 ctxe (16 shared)"
    ).font = TITLE
header_row(ws, 3, ["Tool", "swctx", "ctxe", "Verdict đo", "Chi tiết"])
tools = [
    ("search", "có", "—", "swctx-only", "NL hybrid retrieval — surface ctxe không có bản free"),
    ("context_pack", "có", "—", "swctx-only", "Deterministic context pack, không cần LLM"),
    ("put_record", "có", "—", "swctx-only", "Ghi record vào fleet ledger local"),
    ("prime", "có", "—", "swctx-only", "Warm embedder + index check nhanh"),
    ("ask_context", "—", "có", "ctxe-only", "Server synthesis — record cứu 9/9 miss; trả credits"),
    ("compose_answer", "—", "có", "ctxe-only", "Verified live: record 19 → answer+confidence, 10.5s"),
    ("find_definitions", "có", "có", "parity 3/4", "Cùng hit/miss cùng query; ctxe p50 7ms vs 12ms"),
    ("find_usages", "có", "có", "swctx ≥ ctxe", "tom_tat 3v3 · format_fragment 2v1 · ghi_quyet_dinh 0v0"),
    ("inspect_path", "có", "có", "parity", "50 chunks cùng dir; ctxe thêm has_more/mode"),
    ("fetch_chunks", "có", "có", "parity", "Round-trip cùng file so_tay.py cả 2 bên"),
    ("graph_neighbors", "có", "có", "parity+", "swctx resolve dst_name+edge_kind; ctxe 9 neighbors"),
    ("graph_expand", "có", "có", "parity-empty", "Cùng rỗng trên chunk probe"),
    ("graph_paths", "có", "có", "chưa probe", "Mechanical parity surface"),
    ("get_impact", "có", "có", "swctx hydrated", "swctx trả full chunk info; ctxe chỉ hop+score"),
    ("get_workspace_tree", "có", "có", "ctxe scored", "ctxe: substring filter (0% raw NL); swctx callers dùng search"),
    ("get_status", "có", "có", "parity", "Cả 2 báo indexed + counts; key layout khác"),
    ("list_workspaces", "có", "có", "khác semantics", "swctx 23 indexed dirs; ctxe 9 accepted catalog"),
    ("list_records", "có", "có", "parity", "ctxe có ask records; swctx ledger mới (usage_events)"),
    ("search_records", "có", "có", "parity", "Cả 2 đáp đúng shape; nội dung theo usage"),
    ("get_record", "có", "có", "parity", "Cả 2 fetch đúng; swctx error envelope sạch"),
    ("fast_understand", "có", "có", "khác bản chất", "swctx: card deterministic local free; ctxe: server synthesis trả credits"),
    ("index_workspace", "có", "có", "parity ops", "Cả 2 index workspace; khác backend"),
]
fmap = {"swctx-only": SW_FILL, "ctxe-only": CX_FILL, "parity": PAR_FILL,
        "parity 3/4": PAR_FILL, "parity+": PAR_FILL, "parity-empty": PAR_FILL,
        "parity ops": PAR_FILL, "swctx ≥ ctxe": SW_FILL,
        "swctx hydrated": SW_FILL, "ctxe scored": CX_FILL}
for i, (t, a, b, v, d) in enumerate(tools, 4):
    put(ws, i, [t, a, b, v, d], [None, None, None, fmap.get(v), None])
ws.freeze_panes = "A4"

# ============ SHEET 4: Model verdicts ============
ws = sheet(wb, "Verdicts model", [30, 12, 30, 16, 44])
ws.cell(1, 1, "Quyết định model/reranker — đo offline trước khi đổi"
    ).font = TITLE
header_row(ws, 3, ["Ứng viên", "Loại", "Kết quả đo", "Verdict", "Lý do"])
models = [
    ("distiluse-multi (live default)", "embedder", "sem leg 1/22 probe", "GIỮ (baseline)", "Nhanh ~7ms; VN yếu nhưng hybrid FTS gánh"),
    ("bge-m3 (568M, XLM-R)", "embedder", "cứu 4/5 miss · ~410ms/embed", "LOẠI (latency)", "Quality GO nhưng quá gate p95 3-7×"),
    ("e5-large-instruct (1.1G)", "embedder", "net churn 0 trên probe", "LOẠI", "Không cứu thêm miss nào — d2691ed"),
    ("reranker v2m3/v3 spike", "reranker", "đo trên worktree riêng", "TREO", "Chờ telemetry chỉ ra query class cần rerank"),
    ("translation vn→en (P2)", "retrieval fix", "ctxe ask cứu 2/2 vn_to_en", "PROBE TIẾP", "Lever duy nhất còn lại cho +5/22"),
]
for i, r in enumerate(models, 4):
    put(ws, i, r)

# ============ SHEET 5: Roadmap ============
ws = sheet(wb, "Gap va Roadmap", [10, 34, 44, 22])
ws.cell(1, 1, "Để swctx tối ưu hơn ctxe — gap đo được + việc tiếp theo"
    ).font = TITLE
header_row(ws, 3, ["Pri", "Việc", "Vì sao (bằng chứng)", "Trạng thái"])
road = [
    ("P1", "Usage telemetry trong MCP", "Đo adoption thật: tool nào được gọi, query nào 0-hit, p95 thật — usage_events ledger + swctx stats", "DONE 3ac98c7 · live"),
    ("P2", "vn_to_en translation probe", "0/5 vn_to_en — gap lớn nhất; ctxe synthesis cứu được chứng minh retrieval-side fix có giá trị", "NEXT — chờ telemetry + probe"),
    ("P3", "Release packaging", "release.sh: build→install→selftest→tag — đóng gói tái tạo được", "chưa làm"),
    ("P4", "Corruption-injection gates", "Inject sidecar/model corrupt vào nightly — khóa class bug audit tìm ra", "chưa làm"),
    ("—", "Synthesis cho swctx?", "ctxe ask cứu 9/9 miss — swctx context_pack deterministic chưa đủ sâu; cân nhắc optional LLM hook local", "quyết định sản phẩm"),
]
for i, r in enumerate(road, 4):
    put(ws, i, r)
    if r[0] == "P1":
        ws.cell(i, 4).fill = SW_FILL
    elif r[0] == "P2":
        ws.cell(i, 4).fill = PAR_FILL

wb.save(OUT)
print("wrote", OUT)
