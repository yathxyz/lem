#!/usr/bin/env python3
"""Credential-free OpenRouter model-catalog fixture."""

import fcntl
import json
import os
from pathlib import Path
import sys


log = Path(os.environ["LEM_YATH_LLM_MODELS_LOG"])
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

print(json.dumps({
    "data": [
        {"id": "provider/new"},
        {"id": ""},
        {"id": 42},
        {"id": "openrouter/auto"},
        {"id": "provider/new"},
        {"id": "provider/second"},
    ],
}))
