"""File discovery — honors .gitignore-ish rules + .swctxignore, skips binary/large."""
from __future__ import annotations

import os
from pathlib import Path

CODE_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".swift", ".go", ".rs", ".java",
    ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".rb", ".php", ".kt",
    ".scala", ".sh", ".bash", ".zsh", ".md", ".markdown", ".json", ".yaml",
    ".yml", ".toml", ".sql", ".html", ".css", ".scss", ".vue", ".svelte",
}
SKIP_DIRS = {
    ".git", ".svn", "node_modules", ".build", "build", "dist", "out",
    "__pycache__", ".venv", "venv", ".next", ".nuxt", "target", ".idea",
    ".vscode", "DerivedData", ".gradle", "Pods", ".worktrees", "coverage",
    ".cache", "vendor",
}
MAX_FILE = 512 * 1024


def _load_ignores(root: Path) -> list[str]:
    pats: list[str] = []
    for name in (".swctxignore", ".gitignore"):
        f = root / name
        if f.exists():
            for line in f.read_text(errors="replace").splitlines():
                line = line.strip()
                if line and not line.startswith("#") and not line.startswith("!"):
                    pats.append(line)
    return pats


def _ignored(rel: str, pats: list[str]) -> bool:
    import fnmatch
    for pat in pats:
        p = pat.rstrip("/")
        if pat.endswith("/"):
            if rel.startswith(p + "/") or f"/{p}/" in rel:
                return True
        elif pat.startswith("/"):
            if fnmatch.fnmatch(rel, p.lstrip("/")) or rel == p.lstrip("/"):
                return True
        elif fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(os.path.basename(rel), pat) or rel.startswith(p + "/"):
            return True
    return False


def discover(root: str) -> list[tuple[str, float]]:
    """Return [(rel_path, mtime)] of indexable files."""
    rootp = Path(root)
    pats = _load_ignores(rootp)
    out: list[tuple[str, float]] = []
    for dirpath, dirnames, filenames in os.walk(rootp):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        rel_dir = os.path.relpath(dirpath, rootp)
        for fn in filenames:
            if fn.startswith("."):
                continue
            fp = os.path.join(dirpath, fn)
            rel = fn if rel_dir == "." else f"{rel_dir}/{fn}"
            rel = rel.replace(os.sep, "/")
            if Path(fn).suffix.lower() not in CODE_EXTS:
                continue
            try:
                st = os.stat(fp)
            except OSError:
                continue
            if st.st_size == 0 or st.st_size > MAX_FILE:
                continue
            if _ignored(rel, pats):
                continue
            out.append((rel, st.st_mtime))
    return out


def lang_of(path: str) -> str:
    return {
        ".py": "python", ".js": "javascript", ".jsx": "javascript",
        ".ts": "typescript", ".tsx": "tsx", ".swift": "swift",
        ".go": "go", ".rs": "rust", ".java": "java", ".rb": "ruby",
        ".php": "php", ".kt": "kotlin", ".sh": "bash", ".bash": "bash",
        ".md": "markdown", ".json": "json", ".yaml": "yaml", ".yml": "yaml",
    }.get(Path(path).suffix.lower(), "")


# Port of SwctxCore/Languages.swift extMap + baseNames — the "known
# extension" check behind record anchor capture.
_EXT_MAP = {
    "swift": "swift",
    "py": "python", "pyi": "python",
    "js": "javascript", "mjs": "javascript", "cjs": "javascript",
    "jsx": "tsx",
    "ts": "typescript", "mts": "typescript", "cts": "typescript",
    "tsx": "tsx",
    "go": "go", "rs": "rust", "json": "json",
    "yaml": "yaml", "yml": "yaml",
    "html": "html", "htm": "html", "css": "css",
    "sh": "bash", "bash": "bash", "zsh": "bash",
    "md": "markdown", "markdown": "markdown",
    "txt": "text", "toml": "text",
}
_BASE_NAMES = {
    "makefile": "bash", "dockerfile": "bash", "justfile": "bash",
    "gemfile": "text", "podfile": "text",
}


def language_id(path: str) -> str | None:
    """Extension/basename -> language id, None when unknown."""
    lower = path.replace("\\", "/").rsplit("/", 1)[-1].lower()
    if lower in _BASE_NAMES:
        return _BASE_NAMES[lower]
    if "." not in lower:
        return None
    ext = lower.rsplit(".", 1)[-1]
    if not ext:
        return None
    return _EXT_MAP.get(ext)
