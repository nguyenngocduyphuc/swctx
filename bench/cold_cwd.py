#!/usr/bin/env python3
"""cold_cwd.py — cold-cwd smoke: `swctx mcp` spawned from an UNINDEXED
working directory must still answer workspace-less tools/call.

P0 regression guard (see HANDOFF.md): `tools/call` without `workspace`
auto-resolves the nearest indexed ancestor of the server process cwd; the
ancestor walk used to spin on `/` -> `/..` forever, so any MCP client
launched outside an indexed tree wedged on its first call and never
answered. Unit tests only ever ran inside indexed trees — this script
drives the real wire path (initialize -> notifications/initialized ->
tools/call, newline-delimited JSON-RPC) with cwd=/tmp against the
RELEASE binary:

    python3 bench/cold_cwd.py          # exit 0 pass / 1 fail

Checks (each bounded by a 15s response deadline — a wedge fails, never
hangs):

  a) tools/call get_status {}                      -> result whose payload
                                                    reports meta.indexed
                                                    == false
  b) tools/call list_records {scope:"global",limit:3} -> result whose
                                                    payload has a
                                                    "records" array

Stdlib only. Points at .build/arm64-apple-macosx/release/swctx relative
to the repo root (swift build -c release).
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from bench import MCPSession, PROTOCOL_VERSION  # noqa: E402

RELEASE_BIN = os.path.join(REPO, ".build", "arm64-apple-macosx",
                           "release", "swctx")
TIMEOUT = 15


class ColdCwdSession(MCPSession):
    """MCPSession with an explicit spawn cwd — the variable under test."""

    def __init__(self, argv, cwd, timeout=TIMEOUT):
        super().__init__("swctx", argv, timeout=timeout)
        self._cwd = cwd

    def start(self):
        self.proc = subprocess.Popen(
            self.argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=self._cwd,
        )
        resp = self.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "swctx-cold-cwd", "version": "0.1"},
            },
        )
        if resp is None or "result" not in resp:
            raise RuntimeError(f"{self.name}: initialize failed: {resp!r}")
        self.server_info = resp["result"].get("serverInfo", {})
        self.notify("notifications/initialized")


def call_payload(session, tool, arguments):
    """tools/call -> (payload_dict, error_str). A single deadline'd request
    — no retries: retrying a wedged server would only queue more requests
    behind the hang, and 'no response at all' is exactly the regression
    this script exists to catch."""
    resp = session.request(
        "tools/call", {"name": tool, "arguments": arguments},
        timeout=TIMEOUT)
    if resp is None:
        return None, f"no response within {TIMEOUT}s (server wedged)"
    if "error" in resp:
        return None, (f"rpc {resp['error'].get('code')}: "
                      f"{resp['error'].get('message')}")
    result = resp.get("result", {})
    raw = "\n".join(c.get("text", "") for c in result.get("content", [])
                    if c.get("type") == "text")
    try:
        payload = json.loads(raw)
    except ValueError:
        return None, f"non-JSON tool payload: {raw[:200]}"
    if result.get("isError"):
        return None, f"tool isError: {raw[:200]}"
    return payload, None


def main():
    if not os.access(RELEASE_BIN, os.X_OK):
        print(f"cold_cwd: FAIL release binary missing: {RELEASE_BIN} "
              f"(run `swift build -c release`)", file=sys.stderr)
        return 1

    session = ColdCwdSession([RELEASE_BIN, "mcp"], cwd="/tmp")
    try:
        session.start()
    except Exception as e:
        print(f"cold_cwd: FAIL `swctx mcp` start from /tmp: {e}",
              file=sys.stderr)
        return 1

    ok = True
    try:
        payload, err = call_payload(session, "get_status", {})
        indexed = (payload or {}).get("meta", {}).get("indexed")
        if err or indexed is not False:
            ok = False
            print("gate get_status:      FAIL "
                  f"{err or f'meta.indexed={indexed!r} (want false)'}",
                  file=sys.stderr)
        else:
            print("gate get_status:      PASS meta.indexed=false from "
                  "unindexed cwd", file=sys.stderr)

        payload, err = call_payload(
            session, "list_records", {"scope": "global", "limit": 3})
        records = (payload or {}).get("records")
        if err or not isinstance(records, list):
            ok = False
            print("gate list_records:    FAIL "
                  f"{err or 'payload has no records array'}",
                  file=sys.stderr)
        else:
            print(f"gate list_records:    PASS records[{len(records)}] "
                  f"(scope=global, no workspace)", file=sys.stderr)
    finally:
        session.stop()

    print(f"cold_cwd: {'PASS' if ok else 'FAIL'}", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
