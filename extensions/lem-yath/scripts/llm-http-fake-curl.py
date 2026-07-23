#!/usr/bin/env python3
"""Credential-free fake curl for the Lem Perplexity/Copilot acceptance test."""

import fcntl
import json
import os
from pathlib import Path
import sys
import time


log = Path(os.environ["LEM_YATH_LLM_HTTP_LOG"])
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

if url.endswith("/login/device/code"):
    print(json.dumps({
        "device_code": "device-secret",
        "user_code": "ABCD-EFGH",
        "verification_uri": "https://github.com/login/device",
        "expires_in": 60,
        "interval": 1,
    }))
elif url.endswith("/login/oauth/access_token"):
    poll = next_number("oauth")
    if poll == 1:
        print(json.dumps({"error": "authorization_pending"}))
    else:
        print(json.dumps({"access_token": "github-access-secret"}))
elif url.endswith("/copilot_internal/v2/token"):
    renewal = next_number("renewal")
    print(json.dumps({
        "token": f"copilot-session-secret-{renewal}",
        "expires_at": int(time.time()) + 3600,
    }))
elif url.endswith("api.perplexity.ai/chat/completions"):
    print('data: {"choices":[{"delta":{"content":"Perplexity "}}]}', flush=True)
    print('data: {"choices":[{"delta":{"content":"answer"}}],"citations":["https://example.test/one","https://example.test/two"]}', flush=True)
    print("data: [DONE]", flush=True)
elif url.endswith("api.githubcopilot.com/chat/completions"):
    chat = next_number("copilot-chat")
    print(f'data: {{"choices":[{{"delta":{{"content":"Copilot answer {chat}"}}}}]}}', flush=True)
    print("data: [DONE]", flush=True)
else:
    print("unexpected fake curl URL", file=sys.stderr)
    raise SystemExit(22)
