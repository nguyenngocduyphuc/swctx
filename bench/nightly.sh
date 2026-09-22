#!/bin/bash
# bench/nightly.sh — nightly recall ratchet for swctx.
# Runs the frozen gold-set MCP bench; on gate failure writes a
# `bench_alert` record into the global ledger over the MCP wire so the
# next `prime` surfaces it. No ctxe calls — this path is local/free.
# Install: bench/install_nightly.sh (writes + bootstraps the LaunchAgent).
set -u
cd "$(dirname "$0")/.."
OUTDIR="bench/nightly"
mkdir -p "$OUTDIR"
DAY="$(date +%F)"
JSON_OUT="$OUTDIR/$DAY.json"
LOG="$OUTDIR/history.log"

set -o pipefail
python3 bench/recall_mcp.py --ratchet >"$JSON_OUT" 2>"$OUTDIR/$DAY.stderr"
RC=$?
echo "$DAY rc=$RC" >> "$LOG"
if [ "$RC" -eq 0 ]; then exit 0; fi

# Ratchet failed → durable alert record via MCP (schema-agnostic path).
# put_record only accepts a fixed kind set — 'finding' is the right slot.
GATES="$(grep -E 'GATE|FAIL|recall|p95|schema' "$OUTDIR/$DAY.stderr" | head -8)"
GATES="$GATES" python3 - <<'PYEOF'
import os, sys
sys.path.insert(0, "bench")
from bench import MCPSession  # noqa: E402
from recall import DEFAULT_SWCTX_BIN  # noqa: E402

gates = os.environ.get("GATES", "").strip() or "see nightly stderr log"
payload = ("nightly ratchet gate failure\n" + gates)[:1800]
s = MCPSession("swctx", [DEFAULT_SWCTX_BIN, "mcp"], timeout=60)
try:
    s.start()
    body, _lat, err = s.call_tool("put_record", {
        "workspace": "/Users/phuongnam/02.AI/NP_AI_macos/tools/swctx",
        "kind": "finding", "title": "swctx recall ratchet FAILED",
        "payload": payload, "status": "failed",
    })
    print(f"bench_alert written: {err or body}", file=sys.stderr)
except Exception as e:  # alerting must never crash the job
    print(f"bench_alert write failed (ignored): {e}", file=sys.stderr)
finally:
    try:
        s.stop()
    except Exception:
        pass
PYEOF
exit "$RC"
