#!/usr/bin/env python3
"""Credential-free fake curl for native Codex and Grok OAuth acceptance."""

import base64
import fcntl
import json
import os
from pathlib import Path
import sys
import time


log = Path(os.environ["LEM_YATH_LLM_OAUTH_LOG"])
log.mkdir(parents=True, exist_ok=True)


def next_number(name: str) -> int:
    path = log / f"{name}.count"
    with path.open("a+", encoding="ascii") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        current = int(stream.read() or "0") + 1
        stream.seek(0)
        stream.truncate()
        stream.write(str(current))
        stream.flush()
        return current


def decode_value(line: str) -> tuple[str, str]:
    name, raw = line.split(" = ", 1)
    return name, json.loads(raw)


def jwt(payload: dict[str, object]) -> str:
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode().rstrip("=")
    return f"x.{encoded}.y"


def status(code: int) -> None:
    print(f"\n__LEM_YATH_HTTP_STATUS__:{code}", flush=True)


request_number = next_number("curl")
config_text = sys.stdin.read()
(log / f"curl.{request_number}.config").write_text(config_text, encoding="utf-8")
with (log / f"curl.{request_number}.argv").open("wb") as stream:
    for argument in sys.argv[1:]:
        stream.write(argument.encode() + b"\0")

options: dict[str, list[str]] = {}
for raw_line in config_text.splitlines():
    if " = " not in raw_line:
        continue
    name, value = decode_value(raw_line)
    options.setdefault(name, []).append(value)

url = options.get("url", [""])[-1]
body = options.get("data-binary", [""])[-1]

if url.endswith("/oauth/token"):
    form = dict(part.split("=", 1) for part in body.split("&") if "=" in part)
    grant = form.get("grant_type")
    refresh = next_number("codex-refresh") if grant == "refresh_token" else 0
    account = "acct-native-login" if grant == "authorization_code" else "acct-native"
    print(json.dumps({
        "access_token": jwt({"exp": int(time.time()) + 3600}),
        "id_token": jwt({
            "exp": int(time.time()) + 3600,
            "https://api.openai.com/auth": {"chatgpt_account_id": account},
        }),
        "refresh_token": (
            "codex-login-refresh-secret"
            if grant == "authorization_code"
            else f"codex-rotated-refresh-secret-{refresh}"
        ),
    }))
elif url.endswith("chatgpt.com/backend-api/codex/responses"):
    chat = next_number("codex-chat")
    if chat == 1:
        print(json.dumps({"error": {"message": "expired access"}}))
        status(401)
        raise SystemExit(22)
    if chat == 2:
        print("event: response.output_item.added", flush=True)
        print('data: {"type":"response.output_item.added","output_index":0,"item":{"id":"item-1","type":"function_call","call_id":"call-1","name":"project_root","arguments":""}}', flush=True)
        print(flush=True)
        print("event: response.function_call_arguments.delta", flush=True)
        print('data: {"type":"response.function_call_arguments.delta","item_id":"item-1","delta":"{}"}', flush=True)
        print(flush=True)
        print("event: response.completed", flush=True)
        print('data: {"type":"response.completed","response":{"usage":{"output_tokens":12}}}', flush=True)
        print(flush=True)
        status(200)
    else:
        print("event: response.output_text.delta", flush=True)
        print('data: {"type":"response.output_text.delta","delta":"Codex native answer"}', flush=True)
        print(flush=True)
        print("event: response.completed", flush=True)
        print('data: {"type":"response.completed","response":{"usage":{"output_tokens":7}}}', flush=True)
        print(flush=True)
        status(200)
elif url.endswith("cli-chat-proxy.grok.com/v1/chat/completions"):
    chat = next_number("grok-chat")
    if chat == 1:
        print('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"grok-call-1","type":"function","function":{"name":"project_root","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}', flush=True)
        print("data: [DONE]", flush=True)
        status(200)
    else:
        print('data: {"choices":[{"delta":{"content":"Grok native answer"},"finish_reason":"stop"}]}', flush=True)
        print("data: [DONE]", flush=True)
        status(200)
else:
    print("unexpected fake curl URL", file=sys.stderr)
    raise SystemExit(22)
