"""swctx-py CLI — index / search / status / tree / model / mcp / watch."""
from __future__ import annotations

import argparse
import json
import sys
import time

from .embedder import MODELS_KNOWN, install_model, model_installed
from .indexer import Indexer
from .search import Searcher
from .store import Store


def main() -> None:
    p = argparse.ArgumentParser(prog="swctx-py",
                                description="Local semantic code index + MCP (cross-platform)")
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("index")
    pi.add_argument("path")
    pi.add_argument("--force", action="store_true")
    pi.add_argument("--skip-embed", action="store_true")
    pi.add_argument("--model", default=None)

    ps = sub.add_parser("search")
    ps.add_argument("path")
    ps.add_argument("query")
    ps.add_argument("--limit", type=int, default=10)

    pst = sub.add_parser("status")
    pst.add_argument("path")

    pt = sub.add_parser("tree")
    pt.add_argument("path")
    pt.add_argument("--depth", type=int, default=3)

    pm = sub.add_parser("model")
    pm.add_argument("action", choices=["list", "install"])
    pm.add_argument("id", nargs="?", default="bge-base-en-v1.5")

    sub.add_parser("mcp")

    pw = sub.add_parser("watch")
    pw.add_argument("path")
    pw.add_argument("--interval", type=float, default=2.0)
    pw.add_argument("--once", action="store_true")

    pim = sub.add_parser("simulate")
    pim.add_argument("path")
    pim.add_argument("--diff", default=None,
                     help="path to .diff/.patch (default: stdin)")
    pim.add_argument("--max-callers", type=int, default=50)

    pc = sub.add_parser("coverage")
    pc.add_argument("path")
    pc.add_argument("--symbol", default=None)
    pc.add_argument("--file", default=None,
                    help="test file — lists the symbols it covers")
    pc.add_argument("--limit", type=int, default=50)

    ptr = sub.add_parser("trace")
    ptr.add_argument("path")
    ptr.add_argument("--file", default=None,
                     help="trace file (default: stdin)")

    args = p.parse_args()

    if args.cmd == "index":
        stats = Indexer(Store(args.path)).run(
            force=args.force, skip_embed=args.skip_embed, model_id=args.model)
        print(json.dumps(stats))
    elif args.cmd == "search":
        for h in Searcher(Store(args.path, create=False)).search(
                args.query, args.limit):
            print(f"{h['score']:.4f} {h['path']}:{h['lines'][0]}-{h['lines'][1]}"
                  f" {h.get('symbol') or ''}")
    elif args.cmd == "status":
        s = Store(args.path, create=False)
        print(json.dumps({
            "files": s.db.execute("SELECT COUNT(*) FROM files").fetchone()[0],
            "chunks": s.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0],
            "embedded": s.db.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0],
            "model": s.meta("embedding_model"), "fts": s.fts_ok}))
    elif args.cmd == "tree":
        s = Store(args.path, create=False)
        rows = [r[0] for r in s.db.execute("SELECT path FROM files")]
        node: dict = {}
        for path in sorted(rows):
            cur = node
            for part in path.split("/")[: args.depth]:
                cur = cur.setdefault(part, {})
        print(json.dumps(node, indent=1))
    elif args.cmd == "model":
        if args.action == "list":
            for mid, spec in MODELS_KNOWN.items():
                mark = "installed" if model_installed(mid) else "missing"
                print(f"{mid} [{mark}] dim={spec['dim']} langs={spec['langs']}")
        else:
            d = install_model(args.id)
            print(f"installed {args.id} -> {d}")
    elif args.cmd == "mcp":
        from .mcp_server import serve
        serve()
    elif args.cmd == "watch":
        s = Store(args.path)
        idx = Indexer(s)
        while True:
            stats = idx.run()
            if stats["changed"] or stats["removed"]:
                print(f"[{time.strftime('%H:%M:%S')}] {stats}", flush=True)
            if args.once:
                break
            time.sleep(args.interval)
    elif args.cmd == "simulate":
        from . import simulate
        if args.diff:
            text = open(args.diff, encoding="utf-8").read()
        else:
            text = sys.stdin.read()
        s = Store(args.path, create=False)
        print(json.dumps(simulate.run(s, text, args.max_callers),
                         ensure_ascii=False, indent=1))
    elif args.cmd == "coverage":
        from . import coverage
        s = Store(args.path, create=False)
        print(json.dumps(coverage.run(s, symbol_name=args.symbol,
                                    path=args.file, limit=args.limit),
                         ensure_ascii=False, indent=1))
    elif args.cmd == "trace":
        from . import trace
        text = (open(args.file, encoding="utf-8").read() if args.file
                else sys.stdin.read())
        s = Store(args.path, create=False)
        print(json.dumps(trace.run(s, text), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
