"""Text folding + path/symbol tokenization — direct port of Search.swift."""
import re
import unicodedata

_ALNUM_SPLIT = re.compile(r"[^0-9a-zA-ZÀ-ỹĐđ]+")


def fold_text(s: str) -> str:
    """Diacritic-insensitive + case fold, plus explicit đ/Đ → d."""
    nfkd = unicodedata.normalize("NFKD", s)
    folded = "".join(c for c in nfkd if not unicodedata.combining(c))
    return folded.replace("đ", "d").replace("Đ", "d").lower()


def symbol_tokens(s: str) -> set[str]:
    """camelCase subtokens + non-alnum split, lowercased."""
    out: set[str] = set()
    cur = ""
    for ch in s:
        if ch.isupper() and cur and cur[-1].islower():
            out.add(cur.lower())
            cur = ""
        if ch.isalnum():
            cur += ch
        elif cur:
            out.add(cur.lower())
            cur = ""
    if cur:
        out.add(cur.lower())
    return out


def path_token_string(path: str) -> str:
    """Folded path tokens: alnum-split + camelCase subtokens.
    'ui/getUser.py' -> 'ui get user getuser py' (approximation of Swift impl:
    raw token kept folded too)."""
    out: list[str] = []
    for raw in _ALNUM_SPLIT.split(path):
        if not raw:
            continue
        out.append(fold_text(raw))
        for sub in symbol_tokens(raw):
            out.append(fold_text(sub))
    return " ".join(out)


def symbol_token_string(names: list[str]) -> str:
    out: list[str] = []
    for n in names:
        if not n:
            continue
        out.append(fold_text(n))
        for t in symbol_tokens(n):
            out.append(fold_text(t))
    return " ".join(out)


def query_terms(query: str, min_len: int = 2, cap: int = 12) -> list[str]:
    seen: dict[str, None] = {}
    for t in _ALNUM_SPLIT.split(fold_text(query)):
        if len(t) >= min_len:
            seen.setdefault(t)
    return list(seen)[:cap]
