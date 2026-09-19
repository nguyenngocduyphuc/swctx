#!/usr/bin/env python3
"""ocr_llm_shim.py — OpenAI-compatible HTTP bridge to a local agent CLI.

open-code-review (vendors/open-code-review) only speaks HTTP provider
protocols (anthropic / openai chat-completions / openai-responses /
bedrock). No API key is provisioned on this machine, but agent CLIs are
(`agy`, `claude`, `codex`, `gemini`). This shim exposes a minimal
`POST /v1/chat/completions` that forwards the rendered prompt to
`agy -p` and wraps the reply in the OpenAI response envelope, so

    ocr config set provider agy-local
    ocr config set custom_providers.agy-local.url http://127.0.0.1:8765/v1
    ocr config set custom_providers.agy-local.protocol openai
    ocr config set custom_providers.agy-local.api_key local
    ocr config set model agy

lets `ocr review`/`ocr scan` run through the local agent with zero API
spend.

Function-calling bridge: ocr drives reviews through OpenAI `tools` —
the request carries tool definitions and expects `tool_calls` in the
response, then feeds results back as `role:"tool"` messages. Agent CLIs
return plain text, so the shim (a) renders the tool schemas into the
prompt with an explicit "reply with the JSON envelope only" contract,
(b) translates `role:"tool"` history into text blocks, and (c) parses
the reply's JSON object back into OpenAI `tool_calls`. One stricter
in-band retry happens when tools were offered but the reply did not
parse.

Requests are serialized behind a lock: agent CLIs rate-limit and ocr's
retry semantics mean a parallel burst would just thrash.

Stdlib only. Usage:

    python3 bench/ocr_llm_shim.py [--port 8765] [--cli "agy -p"]
"""

import argparse
import json
import re
import shlex
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CALL_TIMEOUT = 280  # under ocr's 300s request timeout

TOOL_CONTRACT = """
You are being called by a code-review tool that speaks OpenAI function
calling. You do NOT have real function calling — emulate it:

AVAILABLE TOOLS (JSON Schema):
%s

REPLY CONTRACT — output EXACTLY ONE of these two JSON objects, no
markdown fences, no prose before or after:

1. To call tools:
{"tool_calls": [{"name": "<tool_name>", "arguments": {<args matching the schema>}}]}

2. When completely finished (final answer):
{"final": "<your answer text>"}
"""

RETRY_CONTRACT = """
Your previous reply was not the required JSON envelope. Reply with ONLY:
{"tool_calls": [{"name": "<tool_name>", "arguments": {...}}]}
or, if completely done:
{"final": "<text>"}
"""


def extract_json(text):
    """First balanced {...} object in the reply, tolerant of fences/prose."""
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    cand = m.group(1) if m else None
    if cand is None:
        start = text.find("{")
        if start < 0:
            return None
        depth, end = 0, -1
        in_str, esc = False, False
        for i in range(start, len(text)):
            ch = text[i]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end < 0:
            return None
        cand = text[start:end + 1]
    try:
        return json.loads(cand)
    except ValueError:
        return None


def render_messages(req):
    """Flatten OpenAI messages (incl. tool results) into one text prompt."""
    parts = []
    for m in req.get("messages", []):
        role = m.get("role", "user")
        c = m.get("content")
        if isinstance(c, list):  # openai content-parts shape
            c = "".join(p.get("text", "") for p in c
                        if isinstance(p, dict))
        c = c or ""
        if role == "tool":
            parts.append(f"[tool result: {m.get('name', '?')}]\n{c}")
        elif role == "assistant" and m.get("tool_calls"):
            calls = [{"name": tc.get("function", {}).get("name"),
                      "arguments": tc.get("function", {}).get("arguments")}
                     for tc in m["tool_calls"]]
            parts.append(f"[assistant]\n{c}\n"
                         f"(called: {json.dumps(calls, ensure_ascii=False)})")
        else:
            parts.append(f"[{role}]\n{c}")
    return "\n\n".join(parts)


def call_cli(cli_argv, prompt):
    """One CLI turn. Returns (text, error_dict_or_None)."""
    try:
        proc = subprocess.run(cli_argv + [prompt], capture_output=True,
                              text=True, timeout=CALL_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, {"message": "cli call timeout", "type": "timeout"}
    except Exception as e:
        return None, {"message": str(e), "type": "server_error"}
    if proc.returncode != 0 and not proc.stdout.strip():
        return None, {"message": f"cli rc={proc.returncode}: "
                                 f"{proc.stderr[:300]}",
                      "type": "server_error"}
    return proc.stdout.strip(), None


def make_handler(cli_argv):
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def _json(self, body, code=200):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *a):  # quiet default stderr access log
            pass

        def do_GET(self):
            if self.path.rstrip("/") == "/v1/models":
                self._json({"object": "list", "data": [
                    {"id": "agy", "object": "model",
                     "created": 0, "owned_by": "local-cli"}]})
            else:
                self.send_error(404)

        def _chat(self, req):
            tools = req.get("tools") or []
            prompt = render_messages(req)
            if tools:
                defs = json.dumps([
                    {"name": t.get("function", {}).get("name"),
                     "description":
                         t.get("function", {}).get("description", ""),
                     "parameters":
                         t.get("function", {}).get("parameters", {})}
                    for t in tools], ensure_ascii=False, indent=1)
                prompt += TOOL_CONTRACT % defs
            with lock:
                text, err = call_cli(cli_argv, prompt)
                if err is None and tools:
                    parsed = extract_json(text or "")
                    if not (parsed and (parsed.get("tool_calls")
                                        or parsed.get("final")
                                        is not None)):
                        # one stricter in-band retry
                        text, err = call_cli(
                            cli_argv, prompt + RETRY_CONTRACT)
            return text, err, bool(tools)

        def do_POST(self):
            if self.path != "/v1/chat/completions":
                self.send_error(404)
                return
            try:
                n = int(self.headers.get("Content-Length") or 0)
                req = json.loads(self.rfile.read(n) or b"{}")
            except Exception as e:
                self._json({"error": {"message": f"bad request: {e}",
                                      "type": "invalid_request_error"}},
                           code=400)
                return
            text, err, had_tools = self._chat(req)
            if err:
                code = 504 if err["type"] == "timeout" else 502
                self._json({"error": err}, code=code)
                return
            msg = {"role": "assistant", "content": None}
            finish = "stop"
            parsed = extract_json(text or "")
            if had_tools and parsed and parsed.get("tool_calls"):
                tcs = []
                for i, tc in enumerate(parsed["tool_calls"][:8]):
                    args = tc.get("arguments", {})
                    tcs.append({
                        "id": f"call_shim_{i}",
                        "type": "function",
                        "function": {
                            "name": tc.get("name", "?"),
                            "arguments": (args if isinstance(args, str)
                                          else json.dumps(
                                              args, ensure_ascii=False)),
                        },
                    })
                msg["tool_calls"] = tcs
                finish = "tool_calls"
            elif had_tools and parsed and parsed.get("final") is not None:
                msg["content"] = str(parsed["final"])
            else:
                msg["content"] = text or "(empty cli reply)"
            self._json({
                "id": f"chatcmpl-shim-{int(time.time())}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": req.get("model", "agy"),
                "choices": [{"index": 0, "message": msg,
                             "finish_reason": finish}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0,
                          "total_tokens": 0},
            })

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--cli", default="agy -p",
                    help="agent CLI invocation; prompt appended as last arg")
    args = ap.parse_args()
    cli_argv = shlex.split(args.cli)
    srv = ThreadingHTTPServer((args.host, args.port), make_handler(cli_argv))
    print(f"ocr shim: http://{args.host}:{args.port}/v1 -> {cli_argv} <prompt>",
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
