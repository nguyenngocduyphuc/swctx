"""Deterministic VN<->EN lexicon legs — port of Translation.swift.

Free, deterministic, no model call. enLexicon rescues English queries
against Vietnamese-named files (BietXong.swift) by producing folded VN
path atoms; vnLexicon does the reverse.
"""
from .fold import fold_text, _ALNUM_SPLIT

# folded-VN phrase -> English filename terms (longest match wins)
VN_LEXICON: list[tuple[str, list[str]]] = [
    ("bo nao", ["brain"]),
    ("doi ham", ["fleet"]),
    ("doi ngu", ["team", "roster"]),
    ("nhat ky", ["log", "journal"]),
    ("thoi gian thuc", ["live", "realtime"]),
    ("tinh trang", ["status"]),
    ("trang thai", ["status"]),
    ("liet ke", ["list"]),
    ("hoat dong", ["activity"]),
    ("phan tich", ["analysis"]),
    ("du lieu", ["data"]),
    ("bao cao", ["report"]),
    ("kich ban", ["script"]),
    ("tap lenh", ["script"]),
    ("nguoi dung", ["user"]),
    ("nhan vien", ["employee", "staff"]),
    ("nhan su", ["hr", "staff"]),
    ("khach hang", ["customer"]),
    ("don hang", ["order"]),
    ("hoa don", ["invoice"]),
    ("thanh toan", ["payment"]),
    ("giao dich", ["transaction"]),
    ("cham cong", ["attendance"]),
    ("tinh luong", ["payroll", "salary"]),
    ("ton kho", ["inventory"]),
    ("nha cung cap", ["supplier", "vendor"]),
    ("thong bao", ["notification"]),
    ("canh bao", ["alert"]),
    ("lich su", ["history"]),
    ("theo doi", ["monitor", "track"]),
    ("giam sat", ["monitor"]),
    ("kiem tra", ["check"]),
    ("danh gia", ["review"]),
    ("dong bo", ["sync"]),
    ("sao luu", ["backup"]),
    ("khoi phuc", ["restore", "recovery"]),
    ("lap lich", ["schedule"]),
    ("len lich", ["schedule"]),
    ("lich trinh", ["schedule"]),
    ("dang nhap", ["login"]),
    ("dang xuat", ["logout"]),
    ("mat khau", ["password"]),
    ("thu muc", ["folder", "directory"]),
    ("trang web", ["site", "website"]),
    ("bai viet", ["post", "article"]),
    ("noi dung", ["content"]),
    ("tieu de", ["title"]),
    ("mo ta", ["description"]),
    ("hieu suat", ["performance"]),
    ("tu khoa", ["keyword"]),
    ("tim kiem", ["search"]),
    ("xep hang", ["rank", "ranking"]),
    ("thong ke", ["stats"]),
    ("cong cu", ["tool"]),
    ("tu dong", ["auto", "automation"]),
    ("xac thuc", ["auth"]),
    ("bao mat", ["security"]),
    ("san pham", ["product"]),
    ("ke hoach", ["plan"]),
    ("su kien", ["event"]),
    ("diem danh", ["attendance", "checkin"]),
    ("ghi so", ["ledger"]),
    ("cong no", ["debt"]),
    ("tuyen dung", ["recruit"]),
    ("so cai", ["ledger", "book"]),
    ("giao viec", ["gui", "assign", "task"]),
    ("doc", ["read", "reader"]),
    ("phan hoi", ["feedback"]),
    ("bi chan", ["blocked"]),
    ("ap dung", ["apply"]),
    ("goi y", ["suggest", "recommend"]),
    ("minh hoa", ["illustrate", "illustration"]),
    ("sinh anh", ["image"]),
    ("noi bo", ["internal"]),
    # single-word fallbacks
    ("luong", ["salary", "payroll"]),
    ("kho", ["warehouse", "stock"]),
    ("loi", ["error", "bug"]),
    ("tep", ["file"]),
    ("anh", ["image"]),
    ("lich", ["schedule"]),
]

# English phrase/word -> folded-VN filename atoms
EN_LEXICON: list[tuple[str, list[str]]] = [
    ("one after another", ["noi", "tiep", "tuan", "tu"]),
    ("daily report", ["bao", "cao", "ngay"]),
    ("assigned work", ["giao", "gui", "viec", "xong"]),
    ("finished", ["xong", "hoan", "thanh"]),
    ("detecting", ["biet", "phat", "hien"]),
    ("detect", ["biet", "phat", "hien"]),
    ("assign", ["giao", "gui", "viec"]),
    ("task", ["viec", "cong"]),
    ("job", ["viec", "cong"]),
    ("work", ["viec", "cong"]),
    ("report", ["bao", "cao"]),
    ("summary", ["tom", "tat", "tong", "hop"]),
    ("daily", ["ngay", "hang"]),
    ("command", ["lenh"]),
    ("sequential", ["noi", "tiep", "tuan", "tu"]),
    ("chain", ["noi", "tiep", "chuoi"]),
    ("schedule", ["hen", "lich"]),
    ("remind", ["nhac", "hen"]),
    ("notification", ["thong", "bao"]),
    ("ledger", ["so", "ghi"]),
    ("read", ["doc", "xem"]),
    ("record", ["ghi", "nhat", "ky"]),
    ("log", ["nhat", "ky", "ghi"]),
    ("count", ["dem"]),
    ("token", ["token"]),
    ("session", ["phien"]),
    ("history", ["lich", "su"]),
    ("conversation", ["hoi", "thoai"]),
    ("chat", ["hoi", "thoai"]),
    ("kanban", ["kanban", "bang"]),
    ("board", ["bang"]),
    ("keyboard", ["phim"]),
    ("shortcut", ["tat", "phim"]),
    ("config", ["cai", "dat", "cau", "hinh"]),
    ("settings", ["cai", "dat"]),
    ("monitor", ["giam", "sat", "theo", "doi"]),
    ("resource", ["tai", "nguyen"]),
    ("store", ["kho", "luu"]),
    ("employee", ["nhan", "vien"]),
    ("staff", ["nhan", "vien"]),
    ("customer", ["khach", "hang"]),
    ("order", ["don", "hang"]),
    ("invoice", ["hoa", "don"]),
    ("payment", ["thanh", "toan"]),
    ("search", ["tim", "kiem"]),
    ("sync", ["dong", "bo"]),
    ("backup", ["sao", "luu"]),
    ("login", ["dang", "nhap"]),
    ("password", ["mat", "khau"]),
    ("file", ["tep", "tin"]),
    ("folder", ["thu", "muc"]),
    ("user", ["nguoi", "dung"]),
    ("team", ["doi", "nhom"]),
    ("event", ["su", "kien"]),
    ("attendance", ["diem", "danh"]),
    ("checkin", ["diem", "danh"]),
    ("error", ["loi"]),
    ("image", ["anh", "hinh"]),
    ("title", ["tieu", "de"]),
    ("content", ["noi", "dung"]),
    ("keyword", ["tu", "khoa"]),
    ("security", ["bao", "mat"]),
    ("auth", ["xac", "thuc"]),
    ("auto", ["tu", "dong"]),
    ("performance", ["hieu", "suat"]),
    ("feedback", ["phan", "hoi"]),
    ("blocked", ["bi", "chan"]),
    ("plan", ["ke", "hoach"]),
    ("tool", ["cong", "cu"]),
    ("alert", ["canh", "bao"]),
    ("check", ["kiem", "tra"]),
    ("review", ["danh", "gia"]),
    ("restore", ["khoi", "phuc"]),
    ("website", ["trang", "web"]),
    ("article", ["bai", "viet"]),
    ("description", ["mo", "ta"]),
    ("product", ["san", "pham"]),
    ("supplier", ["nha", "cung", "cap"]),
    ("inventory", ["ton", "kho"]),
    ("warehouse", ["kho"]),
    ("salary", ["luong", "tinh"]),
    ("payroll", ["cham", "cong", "luong"]),
    ("internal", ["noi", "bo"]),
]

# VN morphemes seen in filenames — union of both lexicons' atoms.
VN_MORPHEMES: set[str] = set()
for _pat, _ in VN_LEXICON:
    VN_MORPHEMES.update(_pat.split())
for _, _atoms in EN_LEXICON:
    VN_MORPHEMES.update(_atoms)


def _pad_folded(query: str) -> str:
    toks = [t for t in _ALNUM_SPLIT.split(fold_text(query)) if t]
    return " " + " ".join(toks) + " "


def _pad_lower(query: str) -> str:
    toks = [t for t in _ALNUM_SPLIT.split(query.lower()) if t]
    return " " + " ".join(toks) + " "


def lexicon_terms(query: str) -> list[str]:
    """English terms for a (folded) VN query — longest pattern first."""
    padded = _pad_folded(query)
    out: list[str] = []
    seen: set[str] = set()
    for pattern, terms in sorted(VN_LEXICON, key=lambda kv: -len(kv[0])):
        if f" {pattern} " in padded:
            for t in terms:
                if t not in seen:
                    seen.add(t)
                    out.append(t)
    return out


def vn_terms(query: str) -> list[str]:
    """Folded VN atoms for an English query — longest pattern first."""
    padded = _pad_lower(query)
    out: list[str] = []
    seen: set[str] = set()
    for pattern, terms in sorted(EN_LEXICON, key=lambda kv: -len(kv[0])):
        if f" {pattern} " in padded:
            for t in terms:
                if t not in seen:
                    seen.add(t)
                    out.append(t)
    return out
