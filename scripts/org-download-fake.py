#!/usr/bin/env python3
"""Network/display-free clipboard and curl backend for Org download tests."""

import json
import os
import pathlib
import sys


PNG = b"\x89PNG\r\n\x1a\nlem-yath-fixture"
program = pathlib.Path(sys.argv[0]).name
config = sys.stdin.read() if program == "curl" else ""
log = pathlib.Path(os.environ["LEM_YATH_ORG_DOWNLOAD_EXEC_LOG"])
with log.open("a", encoding="utf-8") as stream:
    stream.write(
        json.dumps(
            {"program": program, "argv": sys.argv[1:], "config": config},
            ensure_ascii=False,
        )
        + "\n"
    )

if program in {"wl-paste", "xclip"}:
    sys.stdout.buffer.write(PNG + program.encode("ascii"))
    raise SystemExit(0)

if program != "curl":
    raise SystemExit(64)

if "large.png" in config:
    sys.stdout.buffer.write(PNG + b"x" * 4096)
elif "not-image.png" in config:
    sys.stdout.buffer.write(b"plain text, not an image")
elif "failure.png" in config:
    raise SystemExit(22)
else:
    sys.stdout.buffer.write(PNG + b"curl")
