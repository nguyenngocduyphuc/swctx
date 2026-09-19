#!/usr/bin/env python3
"""corruption_gate.py — W16 corruption-injection gate for swctx.

Copies a small REAL index (`~/.swctx/indexes/<key>/` for --source) into
the index slot of a throwaway workspace, injects corruption into the
COPY, and asserts the release binary degrades gracefully: a sane exit
code plus an error message or clean fallback — never a crash/trap
(SIGABRT=134 / SIGSEGV=139 / signals as negative returncodes) or a hang.

Injections (each on a fresh restore of the pristine copy):

  baseline              no corruption — proves the copied index serves
                        `search --mode semantic` (also materialises
                        vectors.v1.bin on copies that lack it)
  truncated_sidecar     vectors.v1.bin cut to half its size
  zeroed_sidecar        vectors.v1.bin overwritten with zeros (same len)
  db_tail_garbage       4 KiB of random bytes appended to index.db
  db_tail_garbage+status  same tail garbage, probed via `swctx status`
  missing_model         meta.embedding_model rebound to a model id that
                        is not installed -> `search --mode semantic`

The workspace key is read back from `swctx status <ws>` (meta.key) so the
gate always targets the same index dir the binary itself resolves —
Foundation's resolvingSymlinksInPath does not expand /var -> /private/var
on macOS temp dirs, which makes a Python-side sha256(realpath) guess the
wrong key.

Nothing under the source index is ever modified; the only writes land in
the scratch workspace's own index dir and both are removed on exit.
Stdlib only. Usage:

    python3 bench/corruption_gate.py
    python3 bench/corruption_gate.py --source /abs/indexed/workspace
    python3 bench/corruption_gate.py --bin .build/release/swctx
"""

import argparse
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_BIN = os.path.join(REPO, ".build", "release", "swctx")
DEFAULT_SOURCE = "/Users/phuongnam/02.AI/NP_AI_macos/18.CRM-Nam-Pham"
SWCTX_HOME = os.path.expanduser("~/.swctx")
INDEX_FILES = ("index.db", "index.db-shm", "index.db-wal", "vectors.v1.bin")
TIMEOUT = 60  # seconds per invocation — a wedge fails, never hangs
MISSING_MODEL = "w16-nonexistent-model"


def index_dir(key):
    return os.path.join(SWCTX_HOME, "indexes", key)


def binary_key(swctx, path):
    """Key the binary itself resolves for `path`, via `swctx status`
    (meta.key is reported even when nothing is indexed there yet)."""
    p = subprocess.run([swctx, "status", path], capture_output=True,
                       text=True, timeout=TIMEOUT)
    try:
        return json.loads(p.stdout)["meta"]["key"]
    except Exception:
        raise RuntimeError(
            f"cannot read workspace key from `swctx status {path}`: "
            f"rc={p.returncode} out={p.stdout[:200]!r} err={p.stderr[:200]!r}")


def copy_index(src_dir, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)
    for name in INDEX_FILES:
        src = os.path.join(src_dir, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(dst_dir, name))


def run_cmd(argv):
    """Return (rc, timed_out, output_tail). rc<0 = killed by signal."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=TIMEOUT)
        out = (p.stdout + "\n" + p.stderr).strip()
        tail = out.splitlines()[-1][:100] if out else ""
        return p.returncode, False, tail
    except subprocess.TimeoutExpired:
        return None, True, f"timeout >{TIMEOUT}s"


def verdict(rc, timed_out, tail):
    """Graceful = clean exit (0) or a normal error exit WITH a message.
    Crash signals (native or 128+sig shell style) and hangs are FAIL."""
    if timed_out:
        return "FAIL", "hang"
    if rc is None:
        return "FAIL", "no result"
    if rc < 0:
        return "FAIL", f"killed by signal {-rc} ({signal.Signals(-rc).name})"
    if rc in (128 + s for s in
              (signal.SIGILL, signal.SIGTRAP, signal.SIGABRT,
               signal.SIGFPE, signal.SIGBUS, signal.SIGSEGV)):
        return "FAIL", f"crash exit {rc}"
    if rc == 0:
        return "PASS", "clean exit" + (f" ({tail})" if tail else "")
    if tail:
        return "PASS", f"graceful error rc={rc} ({tail})"
    return "FAIL", f"silent failure rc={rc} (no output)"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--source", default=DEFAULT_SOURCE,
                    help="indexed workspace whose index is the corruption donor")
    ap.add_argument("--bin", default=DEFAULT_BIN,
                    help="swctx binary under test (default .build/release/swctx)")
    args = ap.parse_args()

    swctx = os.path.realpath(args.bin)
    if not os.path.isfile(swctx) or not os.access(swctx, os.X_OK):
        print(f"corruption_gate: binary not found/executable: {args.bin}\n"
              f"  build first: swift build -c release", file=sys.stderr)
        return 2
    try:
        src_key = binary_key(swctx, args.source)
    except RuntimeError as e:
        print(f"corruption_gate: {e}", file=sys.stderr)
        return 2
    src_index = index_dir(src_key)
    if not os.path.isfile(os.path.join(src_index, "index.db")):
        print(f"corruption_gate: no index for --source {args.source}\n"
              f"  expected {src_index}/index.db — run `swctx index` on it first",
              file=sys.stderr)
        return 2

    tmp = tempfile.mkdtemp(prefix="swctx-corruption-gate-")
    ws = os.path.join(tmp, "ws")
    pristine = os.path.join(tmp, "pristine")
    failures = 0
    try:
        os.makedirs(ws)
        # One real file so staleness/discovery probes have something to see.
        with open(os.path.join(ws, "probe.py"), "w") as f:
            f.write("def probe():\n    return 'swctx corruption gate'\n")
        live = index_dir(binary_key(swctx, ws))
        if os.path.exists(live):
            print(f"corruption_gate: {live} already exists — refusing to\n"
                  f"  clobber a real index dir", file=sys.stderr)
            return 2
        copy_index(src_index, pristine)
        copy_index(pristine, live)

        def reset_live():
            shutil.rmtree(live)
            copy_index(pristine, live)

        cases = [
            # name, injector, argv after [swctx]
            ("baseline", None,
             ["search", ws, "test", "--mode", "semantic", "--limit", "3"]),
            ("truncated_sidecar", "truncate",
             ["search", ws, "test", "--mode", "semantic", "--limit", "3"]),
            ("zeroed_sidecar", "zero",
             ["search", ws, "test", "--mode", "semantic", "--limit", "3"]),
            ("db_tail_garbage", "dbtail",
             ["search", ws, "test", "--mode", "hybrid", "--limit", "3"]),
            ("db_tail_garbage+status", "dbtail",
             ["status", ws]),
            ("missing_model", "model",
             ["search", ws, "test", "--mode", "semantic", "--limit", "3"]),
        ]

        print(f"binary  : {swctx}")
        print(f"source  : {args.source} (key {src_key})")
        print(f"scratch : {ws} (key {binary_key(swctx, ws)})")
        print()
        print(f"{'case':<24} {'cmd':<46} {'rc':>4}  {'verdict':<6} note")
        print("-" * 110)

        warmed = False
        for name, injector, argv in cases:
            reset_live()
            sidecar = os.path.join(live, "vectors.v1.bin")
            if injector == "truncate":
                if not os.path.isfile(sidecar):
                    print(f"{name:<24} {'-':<46} {'-':>4}  "
                          f"SKIP   no vectors.v1.bin to corrupt")
                    continue
                size = os.path.getsize(sidecar)
                with open(sidecar, "r+b") as f:
                    f.truncate(max(16, size // 2))
            elif injector == "zero":
                if not os.path.isfile(sidecar):
                    print(f"{name:<24} {'-':<46} {'-':>4}  "
                          f"SKIP   no vectors.v1.bin to corrupt")
                    continue
                with open(sidecar, "r+b") as f:
                    f.write(b"\x00" * os.path.getsize(sidecar))
            elif injector == "dbtail":
                with open(os.path.join(live, "index.db"), "ab") as f:
                    f.write(os.urandom(4096))
            elif injector == "model":
                db = sqlite3.connect(os.path.join(live, "index.db"))
                db.execute(
                    "INSERT OR REPLACE INTO meta(key, value) "
                    "VALUES('embedding_model', ?)", (MISSING_MODEL,))
                db.commit()
                db.close()

            rc, timed_out, tail = run_cmd([swctx] + argv)
            v, note = verdict(rc, timed_out, tail)
            if v == "FAIL":
                failures += 1
            cmd_s = "swctx " + " ".join(
                "ws" if a == ws else a for a in argv)
            print(f"{name:<24} {cmd_s:<46} "
                  f"{rc if rc is not None else '-':>4}  {v:<6} {note}")

            # A successful semantic run may (re)write the sidecar from the
            # blob path — stash it into pristine so the sidecar injections
            # have something to corrupt even when the donor index shipped
            # without one.
            if not warmed and os.path.isfile(sidecar):
                shutil.copy2(sidecar, os.path.join(pristine,
                                                 "vectors.v1.bin"))
                warmed = True
    finally:
        if 'live' in dir() and os.path.isdir(live):
            shutil.rmtree(live)
        shutil.rmtree(tmp, ignore_errors=True)

    print("-" * 110)
    if failures:
        print(f"corruption_gate: {failures} injection(s) NOT graceful — FAIL")
        return 1
    print("corruption_gate: all injections graceful — PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
