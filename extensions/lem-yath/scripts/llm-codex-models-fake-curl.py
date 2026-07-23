#!/usr/bin/env python3
"""Credential-free ChatGPT Codex model-probe fixture."""

import fcntl
import json
import os
from pathlib import Path
import re
import sys


log = Path(os.environ["LEM_YATH_LLM_CODEX_MODELS_LOG"])
log.mkdir(parents=True, exist_ok=True)

count_path = log / "curl.count"
with count_path.open("a+", encoding="ascii") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    stream.seek(0)
    request_number = int(stream.read() or "0") + 1
    stream.seek(0)
    stream.truncate()
    stream.write(str(request_number))
    stream.flush()

config = sys.stdin.read()
(log / f"curl.{request_number}.config").write_text(config, encoding="utf-8")
with (log / f"curl.{request_number}.argv").open("wb") as stream:
    for argument in sys.argv[1:]:
        stream.write(argument.encode() + b"\0")

match = re.search(r'^data-binary = (".*")$', config, re.MULTILINE)
if not match:
    print("missing request body", file=sys.stderr)
    raise SystemExit(2)

payload = json.loads(json.loads(match.group(1)))
model = payload.get("model")
statuses = {
    "gpt-5.4": 200,
    "gpt-5.3-codex": 429,
    "gpt-5.2-codex": 404,
    "gpt-5-codex": 400,
}
status = statuses.get(model, 400)

if status == 200:
    print('event: response.completed')
    print('data: {"type":"response.completed"}')
print(f"\n__LEM_YATH_HTTP_STATUS__:{status:03d}")
raise SystemExit(0 if status < 400 else 22)
