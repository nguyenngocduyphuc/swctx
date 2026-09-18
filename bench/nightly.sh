#!/bin/bash
# nightly.sh — scheduled bench gate for swctx, run by launchd
# (com.swctx.bench.plist, ~03:30 nightly).
#
#   1. bench/cold_cwd.py          — cold-cwd smoke: `swctx mcp` from an
#                                   unindexed cwd must still answer
#                                   workspace-less tools/call (P0 wedge
#                                   regression guard).
#   2. bench/recall_mcp.py --ratchet — MCP-wire recall@5 + p95 latency +
#                                   tool-schema golden gates.
#
# Each failing gate appends one timestamped line to
# ~/.swctx/bench_failures.log; the script exits non-zero if any gate
# failed. All gate output streams to stdout/stderr for launchd's
# StandardOutPath/StandardErrorPath logs.
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1   # repo root
LOG="$HOME/.swctx/bench_failures.log"
mkdir -p "$HOME/.swctx"

rc_all=0
run_gate() {
    name="$1"; shift
    "$@"
    rc=$?
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    if [ "$rc" -ne 0 ]; then
        printf '%s FAIL %s rc=%d\n' "$ts" "$name" "$rc" >> "$LOG"
        printf '%s FAIL %s rc=%d (logged -> %s)\n' "$ts" "$name" "$rc" "$LOG"
        rc_all=1
    else
        printf '%s PASS %s\n' "$ts" "$name"
    fi
}

run_gate cold_cwd python3 bench/cold_cwd.py
run_gate recall_ratchet python3 bench/recall_mcp.py --ratchet
# VN retrieval regression net: folded-tail-fill baseline is 10/16 auto;
# gate at 9 catches a one-query regression.
run_gate vn_probe python3 bench/vn_probe.py --gate 9 --no-report

exit "$rc_all"
