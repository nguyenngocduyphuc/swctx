"""answer — local synthesis over verified evidence (port of Answer.swift).

Retrieval packs cited chunks (`[E01] path=… start_line=… end_line=…`),
a synthesis backend answers with STRICT JSON {answer, citations,
limitations}, and a server-side validator rejects any citation whose
evidence_id is not in the pack (or whose path/lines disagree with it).
Default backend `auto`: first usable fleet CLI (agy → codex → claude —
subscription compose) else local Ollama (http://localhost:11434). Backend
absent/model missing → deterministic pack + structured limitation, never
a throw and never a paid service.

Port deltas vs the Swift engine: Ollama is reached over its HTTP API
(`/api/tags` probe + `/api/generate`, SWCTX_OLLAMA_HOST override) instead
of `ollama run` subprocesses — the no-auto-pull gate is unchanged; the
`plan` planner loop is not ported (single-shot compose only), and the
filename probe rides inside Searcher.search's fused path leg rather than
running as a separate prepended hit set.
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
import urllib.request
from dataclasses import dataclass

from . import records
from .graph import chunk_contents, chunk_meta
from .search import Searcher
from .store import Store

DEFAULT_MODEL = "qwen2.5:3b"
PROMPT_VERSION = "answer-v1"
# Per-attempt wall clock for one compose call; one format-retry means the
# worst case is 2x — sized to stay near the 120s MCP deadline.
DEFAULT_TIMEOUT = 60
# Evidence prompt budget (~4 chars/token estimate, same as max_tokens).
DEFAULT_EVIDENCE_TOKENS = 4000
# `<cli> --version` probe budget: healthy CLIs answer in well under a
# second; one that can't do it in 2s is not a usable compose path.
CLI_PROBE_TIMEOUT = 2
# Fleet CLI probe order for `auto` — subscription CLIs already paid for.
AUTO_CLI_ORDER = ("agy", "codex", "claude")

# Non-interactive argv prefixes per known agent CLI — the evidence prompt
# is appended last (port of Answer.cliArgTemplates).
CLI_ARG_TEMPLATES = {
    "agy": ["--dangerously-skip-permissions", "-p"],
    "claude": ["-p"],
    "codex": ["exec", "--skip-git-repo-check"],
    "qwen": ["--approval-mode", "yolo"],
    "opencode": ["run"],
    "grok": ["-p"],
    "gemini": ["-p"],
    "copilot": ["-p"],
    "cline": [],
}

# One local-model-class run at a time per process — a second concurrent
# `answer` waits rather than thrashing the model (Answer.runSemaphore).
_RUN_SEM = threading.Semaphore(1)

# Once-per-process probes: (cli/ollama) preflight verdicts + the resolved
# auto backend. CLI successes and all ollama verdicts are cached; a failed
# CLI probe re-runs next call so a transient miss can't pin ollama.
_preflight_lock = threading.Lock()
_preflight_cache: dict[str, tuple[bool, str]] = {}
_auto_probed = False
_auto_result: _Backend | None = None


@dataclass
class Evidence:
    """One packed evidence item; `id` is the stable handle the model cites."""
    id: str                 # "E01"
    chunk_id: int
    path: str
    start_line: int
    end_line: int
    why: str                # "direct" | "calls" | "called_by"
    symbol: str | None = None
    kind: str | None = None
    content: str = ""


@dataclass
class _Parsed:
    """Model output after JSON extraction + light normalization."""
    answer: str
    citations: list[dict]   # raw citation objects (may be partial)
    limitations: str


@dataclass
class _Backend:
    kind: str               # "ollama" | "cli"
    bin: str                # cli binary name/path ("" for ollama)
    model: str = ""         # ollama model
    argv: tuple = ()        # cli argv prefix

    @property
    def label(self) -> str:
        return (f"ollama:{self.model}" if self.kind == "ollama"
                else f"cli:{self.bin}")


# MARK: - Evidence pack


def _est_tokens(s: str) -> int:
    """~4 chars/token — same estimate apply_budget uses for max_tokens."""
    return (len(s) + 3) // 4


def _render(e: Evidence) -> str:
    """Invariant `[E01] path=… start_line=… end_line=…` handle + content."""
    h = f"[{e.id}] path={e.path} start_line={e.start_line} end_line={e.end_line}"
    if e.symbol:
        h += f" symbol={e.symbol}"
    return h + "\n" + e.content


class _PackBuilder:
    """Bounded pack accumulator: file-dedup, item cap and token budget in
    one place; every appended item mints the next sequential E-handle."""

    def __init__(self, token_budget: int, max_items: int):
        self.token_budget = token_budget
        self.token_ceiling = token_budget
        self.max_items = max_items
        self.items: list[Evidence] = []
        self.seen_chunks: set[int] = set()
        self.seen_files: set[str] = set()
        self.used_tokens = 0
        self.truncated = False

    def _fits(self, content: str) -> str | None:
        """Content (possibly trimmed) that fits the remaining token budget,
        or None when nothing meaningful fits."""
        remain = self.token_ceiling - self.used_tokens - 14  # handle line
        if _est_tokens(content) <= remain:
            return content
        chars = remain * 4
        if chars < 400:     # below this a trimmed tail is noise
            return None
        return content[:chars] + "\n…[truncated]"

    def append(self, *, path: str, chunk_id: int, start: int, end: int,
               why: str, symbol: str | None, kind: str | None,
               content: str) -> bool:
        """Append under the item cap AND token budget; False (and marks
        truncated) when either bound trips."""
        if len(self.items) >= self.max_items:
            self.truncated = True
            return False
        c = self._fits(content)
        if c is None:
            self.truncated = True
            return False
        self.items.append(Evidence(
            f"E{len(self.items) + 1:02d}", chunk_id, path, start, end,
            why, symbol, kind, c))
        self.used_tokens += _est_tokens(c) + 14
        if _est_tokens(c) < _est_tokens(content):
            self.truncated = True
        return True


def _one_hop(store: Store, seeds: list[int],
             per_seed: int = 2) -> list[tuple[int, str]]:
    """1-hop graph neighbors of the seeds (port of ContextPack.oneHop):
    outgoing callees ("calls") + incoming dependents ("called_by")."""
    out: list[tuple[int, str]] = []
    for seed in seeds:
        for (nid,) in store.db.execute(
                "SELECT dst_chunk FROM edges WHERE src_chunk = ? "
                "AND dst_chunk IS NOT NULL LIMIT ?", (seed, per_seed)):
            out.append((nid, "calls"))
        for (nid,) in store.db.execute(
                "SELECT src_chunk FROM edges WHERE dst_chunk = ? "
                "LIMIT ?", (seed, per_seed)):
            out.append((nid, "called_by"))
    return out


def build_pack(store: Store, query: str, path_filter: str | None = None,
               direct_max: int = 6, related_max: int = 3,
               token_budget: int = DEFAULT_EVIDENCE_TOKENS
               ) -> tuple[list[Evidence], bool]:
    """Retrieve + pack evidence: hybrid direct hits (file-deduped, ≤
    `direct_max`), then 1-hop call/called_by neighbors (≤ `related_max`).
    Item AND token budgets both apply; an oversize item is trimmed to the
    remaining budget rather than silently blowing the context window.

    `Searcher.search` is the port's retrieval entry — its fused legs
    already include the rarity-weighted filename probe (Swift runs the
    same probe as a separate first pass inside fillInitialPack)."""
    acc = _PackBuilder(token_budget, direct_max + related_max)
    hits = Searcher(store).search(query, limit=16, path_filter=path_filter,
                                  event_tool="answer")
    # Direct hits: file-deduped so the pack covers distinct sources.
    seeds: list[dict] = []
    for h in hits:
        if len(seeds) >= direct_max:
            break
        if h["chunk_id"] in acc.seen_chunks or h["path"] in acc.seen_files:
            continue
        acc.seen_chunks.add(h["chunk_id"])
        acc.seen_files.add(h["path"])
        seeds.append(h)
    for h in seeds:
        c = h.get("content") or ""
        if not c:
            continue
        acc.append(path=h["path"], chunk_id=h["chunk_id"],
                   start=h["lines"][0], end=h["lines"][1], why="direct",
                   symbol=h.get("symbol"), kind=h.get("kind"), content=c)

    # Related: 1-hop graph neighbors of the direct seeds, content
    # hydrated too — the model cannot call fetch_chunks.
    if seeds and len(acc.items) < acc.max_items:
        neighbors = _one_hop(store, [h["chunk_id"] for h in seeds], 2)
        rel_ids: list[int] = []
        rel_why: dict[int, str] = {}
        for nid, why in neighbors:
            if nid in acc.seen_chunks or len(rel_ids) >= related_max:
                continue
            acc.seen_chunks.add(nid)
            rel_ids.append(nid)
            rel_why[nid] = why
        meta = chunk_meta(store, rel_ids)
        contents = chunk_contents(store, rel_ids)
        for nid in rel_ids:
            m, c = meta.get(nid), contents.get(nid)
            if not m or not c:
                continue
            acc.append(path=m["path"], chunk_id=nid,
                       start=m["start_line"], end=m["end_line"],
                       why=rel_why[nid], symbol=m.get("symbol"),
                       kind=m.get("kind"), content=c)
    return acc.items, acc.truncated


# MARK: - Prompt


def build_prompt(query: str, evidence: list[Evidence],
                 retry: bool = False) -> str:
    """STRICT-JSON synthesis prompt. The schema spec sits AFTER the
    evidence (closest to generation): a small model reuses the last-seen
    pattern, and evidence chunks are full of JSON-shaped code it would
    otherwise echo back."""
    ev = "".join(_render(e) + "\n\n" for e in evidence)
    p = (
        "You answer questions about a codebase using ONLY the evidence "
        "below. The evidence is reference material — read it, never copy "
        "it.\n\n"
        f"QUESTION: {query}\n\n"
        "EVIDENCE:\n"
        f"{ev}"
        "Respond with a single JSON object and NOTHING else — no markdown "
        "fences, no prose around it. Exactly these keys:\n"
        '{"answer": "2-5 sentences answering the question, grounded in '
        'the evidence",\n'
        ' "citations": [{"evidence_id": "E01"}],\n'
        ' "limitations": "what the evidence does not cover, or empty '
        'string"}\n'
        "Rules: evidence is ordered most-relevant first — prefer items "
        "whose path or symbol matches terms in the question; every "
        "citation's evidence_id must be one of the [E..] handles above; "
        "if the evidence is insufficient, say what is missing in "
        '"limitations" instead of guessing; never invent file paths or '
        "line numbers; answer in the language of the question."
    )
    if retry:
        p += ('\nYour previous reply was not the required {"answer", '
              '"citations", "limitations"} JSON object. Reply with ONLY '
              "that JSON object — no other text.")
    return p


# MARK: - Model backend (ollama http | agent CLI)


def _ollama_host() -> str:
    return os.environ.get("SWCTX_OLLAMA_HOST") or "http://localhost:11434"


def resolve_model(explicit: str | None) -> str:
    """Explicit arg > SWCTX_ANSWER_MODEL > qwen2.5:3b (3B default)."""
    if explicit:
        return explicit
    return os.environ.get("SWCTX_ANSWER_MODEL") or DEFAULT_MODEL


def reset_preflight() -> None:
    """Test hook: clear the once-per-process preflight + auto caches."""
    global _auto_probed, _auto_result
    with _preflight_lock:
        _preflight_cache.clear()
    _auto_probed = False
    _auto_result = None


def resolve_backend(explicit: str | None,
                    model: str | None = None) -> tuple[_Backend, bool]:
    """backend spec: explicit arg > SWCTX_ANSWER_BACKEND >
    SWCTX_ANSWER_CLI > "auto" — the DEFAULT. `auto` probes AUTO_CLI_ORDER
    once per process and takes the first usable fleet CLI, else falls
    back to local ollama. Forms: "auto" | "ollama" | "cli" (binary via
    SWCTX_ANSWER_CLI, default "agy") | "cli:<bin>" | a bare CLI name.
    `auto` in the result flags that no explicit backend was chosen."""
    spec = explicit or os.environ.get("SWCTX_ANSWER_BACKEND", "")
    env_cli = os.environ.get("SWCTX_ANSWER_CLI", "")
    if not spec and env_cli:
        spec = f"cli:{env_cli}"
    if not spec or spec == "auto":
        cli = auto_detect_cli()
        if cli is not None:
            return cli, True
        return _Backend("ollama", "", model=resolve_model(model)), True
    if spec == "ollama":
        return _Backend("ollama", "", model=resolve_model(model)), False
    name = spec
    if spec == "cli":
        name = env_cli or "agy"
    elif spec.startswith("cli:"):
        name = spec[4:]
    return _Backend("cli", name,
                    argv=tuple(CLI_ARG_TEMPLATES.get(name, []))), False


def cli_probe(bin_: str,
              timeout: float = CLI_PROBE_TIMEOUT) -> tuple[bool, str]:
    """`<bin> --version` probe: PATH check first (zero subprocesses), then
    a bounded spawn. Success verdicts are cached so backend_available on
    the resolved backend doesn't pay a second subprocess; failures stay
    uncached so a later explicit backend gets a fresh probe."""
    if shutil.which(bin_) is None:
        return False, f"cli '{bin_}' not on PATH"
    key = f"cli\x1f{bin_}"
    with _preflight_lock:
        cached = _preflight_cache.get(key)
    if cached is not None:
        return cached
    try:
        spawn(bin_, ["--version"], timeout)
        result = (True, "ok")
    except Exception as e:
        result = (False, f"cli '{bin_}' unavailable: {e}")
    if result[0]:
        with _preflight_lock:
            _preflight_cache[key] = result
    return result


def auto_detect_cli() -> _Backend | None:
    """Probe AUTO_CLI_ORDER once per process — first CLI answering
    `--version` within CLI_PROBE_TIMEOUT wins. None = no usable fleet CLI
    (caller falls back to local ollama). Only a FOUND backend is pinned:
    a nil verdict re-probes next call (PATH scans are ~free)."""
    global _auto_probed, _auto_result
    with _preflight_lock:
        if _auto_probed:
            return _auto_result
    found = None
    for name in AUTO_CLI_ORDER:
        if cli_probe(name, CLI_PROBE_TIMEOUT)[0]:
            found = _Backend("cli", name,
                             argv=tuple(CLI_ARG_TEMPLATES.get(name, [])))
            break
    with _preflight_lock:
        if found is not None:
            _auto_probed = True
            _auto_result = found
    return found


def backend_available(backend: _Backend) -> tuple[bool, str]:
    """One probe per process: ollama checks daemon+model via /api/tags; a
    CLI backend just needs the binary on PATH answering --version."""
    if backend.kind == "ollama":
        return ollama_available(backend.model)
    return cli_probe(backend.bin, 15)


def call_model(backend: _Backend, prompt: str, timeout: float) -> str:
    """Prompt → raw model text for whichever backend is configured."""
    if backend.kind == "ollama":
        return _ollama_generate(backend.model, prompt, timeout)
    return spawn(backend.bin, [*backend.argv, prompt], timeout)


def ollama_available(model: str) -> tuple[bool, str]:
    """GET /api/tags proves the daemon AND lists already-local models —
    a missing model is never auto-pulled (the `ollama list` gate)."""
    host = _ollama_host()
    key = f"ollama\x1f{host}\x1f{model}"
    with _preflight_lock:
        if key in _preflight_cache:
            return _preflight_cache[key]
    try:
        with urllib.request.urlopen(f"{host}/api/tags",
                                    timeout=15) as r:
            data = json.loads(r.read().decode())
        names = [m.get("name", "") for m in data.get("models", [])]
        found = any(
            n == model or n == f"{model}:latest"
            or (":" not in model and n.startswith(f"{model}:"))
            for n in names)
        result = ((True, "ok") if found else
                  (False, f"model '{model}' not in `ollama list` "
                          "(no auto-pull)"))
    except Exception as e:
        result = (False, f"ollama unavailable: {e}")
    with _preflight_lock:
        _preflight_cache[key] = result
    return result


def _ollama_generate(model: str, prompt: str, timeout: float) -> str:
    """POST /api/generate — format:json mirrors `ollama run --format
    json`; stream:false returns one body whose `response` is the text."""
    body = json.dumps({"model": model, "prompt": prompt,
                       "stream": False, "format": "json"}).encode()
    req = urllib.request.Request(
        f"{_ollama_host()}/api/generate", data=body,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        raise RuntimeError(f"ollama generate failed: {e}") from e
    return (data.get("response") or "").strip()


def _kill_group(proc: subprocess.Popen) -> None:
    """TERM → KILL the child's whole process group (POSIX_SPAWN_SETPGROUP
    equivalent) so forking descendants can't escape; plain kill where
    process groups don't exist."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (AttributeError, ProcessLookupError, PermissionError, OSError):
        proc.terminate()
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=0.3)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (AttributeError, ProcessLookupError, PermissionError, OSError):
        proc.kill()
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=2)


def spawn(bin_: str, argv: list[str], timeout: float) -> str:
    """`bin argv`, capturing stdout — Popen with the child in its own
    process group (start_new_session) and concurrent pipe drain via
    communicate(); on timeout the whole group gets TERM→KILL."""
    try:
        proc = subprocess.Popen(
            [bin_, *argv], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True)
    except OSError as e:
        raise RuntimeError(f"cannot spawn {bin_}: {e}") from e
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        proc.communicate()
        raise RuntimeError(f"{bin_} timed out after {timeout}s") from None
    if proc.returncode != 0:
        raise RuntimeError(
            f"{bin_} exited {proc.returncode}: {(err or '')[:400]}")
    return out.strip()


# MARK: - Output parsing + citation validation

_ANSI_RX = re.compile("\x1b\\[[0-9;?]*[A-Za-z]")


def strip_ansi(s: str) -> str:
    """Terminal spinner/CSI sequences leak into piped stdout — strip
    before anything parses the text."""
    return _ANSI_RX.sub("", s)


def parse_answer(raw: str) -> _Parsed | None:
    """Extract the strict JSON object the model was asked for. Tolerates
    leading prose / ```json fences by slicing first-{ to last-};
    requires `answer` non-empty. None → caller may retry once."""
    s = strip_ansi(raw).strip()
    if s.startswith("```"):
        s = s.replace("```json", "").replace("```", "").strip()
    d = None
    try:
        v = json.loads(s)
        d = v if isinstance(v, dict) else None
    except ValueError:
        pass
    if d is None:
        lo, hi = s.find("{"), s.rfind("}")
        if lo != -1 and hi > lo:
            try:
                v = json.loads(s[lo:hi + 1])
                d = v if isinstance(v, dict) else None
            except ValueError:
                pass
    if d is None:
        return None
    answer = d.get("answer")
    if not isinstance(answer, str) or not answer.strip():
        return None
    # citations: objects preferred; bare "E01" strings normalize up.
    citations: list[dict] = []
    raw_cites = d.get("citations")
    for c in raw_cites if isinstance(raw_cites, list) else []:
        if isinstance(c, dict):
            citations.append(c)
        elif isinstance(c, str):
            citations.append({"evidence_id": c})
        elif isinstance(c, int):
            citations.append({"evidence_id": f"E{c}"})
    lim = d.get("limitations")
    return _Parsed(answer, citations,
                   lim if isinstance(lim, str) else "")


def normalize_evidence_id(v) -> str | None:
    """Normalize an evidence_id the model emitted: "E01", "e1", "1",
    "E-02" → "E01"/"E02". Anything non-numeric → None."""
    if isinstance(v, bool):
        s = "1" if v else "0"
    elif isinstance(v, int):
        s = str(v)
    elif isinstance(v, str):
        s = v
    else:
        return None
    s = (s.strip().upper().replace("E", "")
         .replace("-", "").replace("#", ""))
    if not re.fullmatch(r"[+]?[0-9]+", s):
        return None
    n = int(s)
    if n <= 0:
        return None
    return f"E{n:02d}"


def _citation_line(v) -> int | None:
    """Line-number coercion: JSON ints and integral floats qualify;
    bools, strings, objects and fractional floats → None (a wrong-TYPE
    assertion — the caller marks the citation invalid)."""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return None


def validate_citations(raw: list[dict], pack: list[Evidence]
                       ) -> tuple[list[dict], list[str], bool]:
    """Server-side validator: a citation counts ONLY when its evidence_id
    exists in the pack AND any path/line the model asserted matches the
    pack item verbatim — a model-invented path is invalid, never trusted.
    path/start_line/end_line stay OPTIONAL (the strict schema cites
    evidence_id only), but a field that IS present must carry the right
    JSON type. An explicit null reads as "not provided"."""
    by_id = {e.id: e for e in pack}
    resolved: list[dict] = []
    invalid: list[str] = []
    seen: set[str] = set()
    for c in raw:
        if not isinstance(c, dict):
            invalid.append(f"unparseable citation: {c}")
            continue
        cid = c["evidence_id"] if "evidence_id" in c else c.get("id")
        eid = normalize_evidence_id(cid)
        if eid is None:
            invalid.append(f"unparseable citation: {c}")
            continue
        ev = by_id.get(eid)
        if ev is None:
            invalid.append(f"{eid} not in evidence pack")
            continue
        problem = None
        if "path" in c and c["path"] is not None:
            if isinstance(c["path"], str):
                if c["path"] != ev.path:
                    problem = "path/line mismatch"
            else:
                problem = "path not a string"
        for key, expected in (("start_line", ev.start_line),
                              ("end_line", ev.end_line)):
            if problem is not None:
                break
            if key in c and c[key] is not None:
                i = _citation_line(c[key])
                if i is not None:
                    if i != expected:
                        problem = "path/line mismatch"
                else:
                    problem = f"{key} not a number"
        if problem:
            invalid.append(f"{eid} {problem}")
            continue
        if eid in seen:
            continue    # dup is harmless
        seen.add(eid)
        resolved.append({
            "evidence_id": eid, "chunk_id": ev.chunk_id,
            "path": ev.path, "start_line": ev.start_line,
            "end_line": ev.end_line})
    # Empty citation set is not "valid": the answer is unverifiable.
    return resolved, invalid, not invalid and bool(resolved)


# MARK: - Response budget

_HARD_CAP = 64 * 1024
_TRUNCATABLE = {"content", "payload", "snippet"}


def _truncate_strings(node, cap: int) -> bool:
    """Cut every content/payload/snippet string over `cap` (recursive over
    dicts + arrays). Returns True when anything was cut."""
    cut = False
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, str) and k in _TRUNCATABLE and len(v) > cap:
                node[k] = v[:cap] + "\n…[truncated]"
                cut = True
            elif isinstance(v, (dict, list)):
                cut = _truncate_strings(v, cap) or cut
    elif isinstance(node, list):
        for v in node:
            if isinstance(v, (dict, list)):
                cut = _truncate_strings(v, cap) or cut
    return cut


def _apply_budget(resp: dict, max_tokens: int | None) -> dict:
    """Response budget (port of SwctxTools.applyBudget): `max_tokens`
    (~4 chars/token) trims top-level arrays tail-first, then truncates
    oversized content strings; the hard cap returns E_OUTPUT_TOO_LARGE
    when even metadata cannot fit."""
    limit = (min(max_tokens * 4, _HARD_CAP) if max_tokens is not None
             else _HARD_CAP)

    def enc(d: dict) -> int:
        return len(json.dumps(d, ensure_ascii=False,
                              default=str).encode("utf-8"))

    size = enc(resp)
    omitted = 0
    truncated = False
    if size > limit:
        for cap in (2048, 512, 128):
            if size <= limit:
                break
            truncated = _truncate_strings(resp, cap) or truncated
            size = enc(resp)
        while size > limit:
            key = max(resp, key=lambda k:
                      len(resp[k]) if isinstance(resp[k], list) else -1)
            arr = resp.get(key)
            if not isinstance(arr, list) or not arr:
                break
            drop = max(1, len(arr) // 2)
            resp[key] = arr[:-drop]
            omitted += drop
            new_size = enc(resp)
            if new_size >= size:
                break
            size = new_size
        truncated = truncated or omitted > 0
    reason = "max_tokens" if max_tokens else "response_cap"
    if size > limit:
        return {"error": {
            "code": "E_OUTPUT_TOO_LARGE",
            "message": f"response {size}B exceeds limit {limit}B even "
                       "after trimming; narrow the query or raise "
                       "max_tokens"},
            "meta": {"truncation_applied": True,
                     "content_status": "error",
                     "omitted": {"items": omitted, "reason": reason,
                                 "limit_bytes": limit}}}
    meta = resp.get("meta") or {}
    meta["truncation_applied"] = truncated
    meta["content_status"] = "truncated" if truncated else "full"
    if omitted:
        meta["omitted"] = {"items": omitted, "reason": reason,
                           "limit_bytes": limit}
    resp["meta"] = meta
    return resp


# MARK: - Top level


def _finish(store: Store, query: str, model: str, backend: str,
            pack: list[Evidence], pack_truncated: bool,
            answer: str | None, resolved: list[dict], invalid: list[str],
            citation_valid: bool, attempts: int, ollama_ok: bool,
            raw_output: str | None, limitations: list[str],
            expected_path: str | None, source: str, t0: float) -> dict:
    """Assemble the response dict + write the durable kind=ask record.
    The record write is best-effort — a ledger failure must never lose
    the answer."""
    latency_ms = int((time.time() - t0) * 1000)
    evidence_dicts = []
    for e in pack:
        d: dict = {
            "evidence_id": e.id, "chunk_id": e.chunk_id, "path": e.path,
            "start_line": e.start_line, "end_line": e.end_line,
            "why": e.why}
        if e.symbol:
            d["symbol"] = e.symbol
        if e.kind:
            d["kind"] = e.kind
        d["content"] = e.content
        evidence_dicts.append(d)
    limitation_text = " | ".join(x for x in limitations if x)

    resp: dict = {
        "query": query, "model": model, "backend": backend,
        "prompt_version": PROMPT_VERSION,
        "answer": answer,
        "citations": resolved,
        "citation_valid": citation_valid,
        "limitations": limitation_text,
        "evidence": evidence_dicts,
        "evidence_truncated": pack_truncated,
        "ollama": {"available": ollama_ok, "attempts": attempts,
                   "latency_ms": latency_ms},
    }
    if invalid:
        resp["invalid_citations"] = invalid
    if raw_output is not None:
        resp["raw_output"] = raw_output[:4000]
    if expected_path:
        resp["expected_path"] = expected_path

    # Durable record — same ledger path as put_record: staleness
    # evidence (HEAD + resolving anchors) included.
    payload: dict = {
        "query": query, "model": model, "backend": backend,
        "prompt_version": PROMPT_VERSION,
        "evidence": [{"evidence_id": e.id, "chunk_id": e.chunk_id,
                      "path": e.path, "start_line": e.start_line,
                      "end_line": e.end_line} for e in pack],
        "citations": resolved,
        "invalid_citations": invalid,
        "citation_valid": citation_valid,
        "ollama_available": ollama_ok,
        "attempts": attempts,
        "latency_ms": latency_ms,
        "limitations": limitation_text,
    }
    if answer is not None:
        payload["answer"] = answer
    if expected_path:
        payload["expected_path"] = expected_path
    try:
        payload_json = json.dumps(payload, ensure_ascii=False)
        head = records.git(store.workspace, "rev-parse", "HEAD") or None
        try:
            anchors = records.record_anchors(
                store, query + "\n" + payload_json)
        except Exception:
            anchors = []
        rid = records.insert_ws(
            store, "ask", query, payload_json, source=source,
            status="completed", head_sha=head, anchors=anchors)
        resp["record_id"] = rid
    except Exception:
        pass
    return resp


def run(store: Store, query: str, model: str | None = None,
        timeout: int = DEFAULT_TIMEOUT, expected_path: str | None = None,
        source: str = "mcp", path_filter: str | None = None,
        backend_spec: str | None = None,
        max_tokens: int | None = None) -> dict:
    """Retrieve → (preflight) → backend → validate → record.
    `backend_spec` None/empty resolves "auto" — first usable fleet CLI
    (agy → codex → claude), else local ollama — and the resolved label
    ("cli:agy", "ollama:qwen2.5:3b"…) is recorded as `backend`. Backend-
    side failures degrade to the deterministic pack + a structured
    `limitations` field; only index/retrieval errors throw.
    `expected_path` is a harness oracle: echoed into the response and the
    durable record for scoring, NEVER into the prompt."""
    t0 = time.time()
    backend, auto = resolve_backend(backend_spec, model)
    # Records/reporting keep the bare model name for ollama; a CLI
    # backend reports itself ("cli:agy").
    model_id = (backend.label if backend.kind == "cli"
                else resolve_model(model))
    clamped = min(max(int(timeout), 5), 900)

    # maxItems = directMax + relatedMax inside build_pack (6 + 3).
    pack, pack_truncated = build_pack(store, query, path_filter)
    limitations: list[str] = []
    if pack_truncated:
        limitations.append("evidence pack trimmed to token budget")

    answer: str | None = None
    resolved: list[dict] = []
    invalid: list[str] = []
    citation_valid = False
    attempts = 0
    raw_output: str | None = None

    # Preflight once — synthesis shares the verdict.
    ok, detail = backend_available(backend)
    if not ok:
        if auto:
            # auto resolved nothing usable: say so plainly — the caller
            # must never suspect a silent paid-service route.
            limitations.append(
                "no compose backend available — auto probed fleet CLIs "
                f"({', '.join(AUTO_CLI_ORDER)}) then {backend.label}: "
                f"{detail} — deterministic evidence pack only")
        else:
            limitations.append(
                f"{backend.label} unavailable — deterministic evidence "
                f"pack only ({detail})")

    # One local-model-class run at a time — held across synthesis so a
    # concurrent caller degrades instead of double-loading the model.
    held = False
    if ok and pack:
        if not _RUN_SEM.acquire(timeout=clamped * 2 + 30):
            limitations.append(
                "another answer run held the local model semaphore")
            resp = _finish(store, query, model_id, backend.label, pack,
                           pack_truncated, None, [], [], False, 0, True,
                           None, limitations, expected_path, source, t0)
            return _apply_budget(resp, max_tokens)
        held = True
    try:
        if not pack:
            limitations.append("no evidence retrieved for query")
        elif ok:
            # The LAST successfully parsed attempt wins — a failed retry
            # keeps the earlier parse rather than throwing it away.
            model_limitations = ""
            for attempt in (1, 2):
                attempts = attempt
                prompt = build_prompt(query, pack, retry=attempt == 2)
                try:
                    out = call_model(backend, prompt, clamped)
                    raw_output = strip_ansi(out)
                except Exception as e:
                    limitations.append(
                        f"{backend.label} call failed: {e}")
                    break   # transport errors never retry
                parsed = parse_answer(out)
                if parsed is not None:
                    answer = parsed.answer
                    model_limitations = parsed.limitations
                    resolved, invalid, citation_valid = validate_citations(
                        parsed.citations, pack)
                    # Invalid citations spend the same single retry a
                    # malformed reply gets — attempt 2's result then
                    # stands, valid or not.
                    if citation_valid or attempt == 2:
                        break
                elif attempt == 2:
                    limitations.append(
                        "model output was not the required JSON after "
                        "1 format-retry")
            if model_limitations:
                limitations.append(model_limitations)
            if invalid:
                limitations.append(
                    f"{len(invalid)} citation(s) rejected: "
                    + "; ".join(invalid))
                if (answer is not None and not citation_valid
                        and attempts == 2):
                    limitations.append(
                        "citations still invalid after 1 retry")
            if answer is not None and not resolved and not invalid:
                limitations.append("model returned no usable citations")
    finally:
        if held:
            _RUN_SEM.release()

    resp = _finish(store, query, model_id, backend.label, pack,
                   pack_truncated, answer, resolved, invalid,
                   citation_valid, attempts, ok,
                   raw_output if answer is None else None,
                   limitations, expected_path, source, t0)
    return _apply_budget(resp, max_tokens)
