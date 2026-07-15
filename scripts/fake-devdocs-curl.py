#!/usr/bin/env python3
"""Network-free DevDocs HTTP subset with deliberately out-of-order replies."""

from __future__ import annotations

import fcntl
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit


LOG = Path(os.environ["LEM_YATH_DEVDOCS_CURL_LOG"])


def log(args: list[str]) -> None:
    with LOG.open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(args) + "\n")


def index(entries: list[tuple[str, str]]) -> str:
    return json.dumps(
        {"entries": [{"name": name, "path": path} for name, path in entries]}
    )


def main() -> int:
    args = sys.argv[1:]
    log(args)
    if not args:
        return 2
    path = urlsplit(args[-1]).path
    if path == "/custom/index.json":
        print(index([("Custom.Entry", "guide/custom#entry")]))
        return 0
    if path == "/custom/guide/custom.html":
        print(
            "<article><h1>Custom Entry</h1><p>Decoded &amp; text.</p>"
            "<pre><code>safe();</code></pre><script>hidden script</script>"
            "<style>hidden style</style></article>"
        )
        return 0
    if path == "/rust/index.json":
        print(
            index(
                [
                    ("Vec::new", "std/vec/struct.Vec#method.new"),
                    (
                        "Vec::with_capacity",
                        "std/vec/struct.Vec#method.with_capacity",
                    ),
                ]
            )
        )
        return 0
    if path == "/rust/std/vec/struct.Vec.html":
        print("<main><h1>Vec</h1><p>Rust decoded &amp; body.</p></main>")
        return 0
    if path == "/slow/index.json":
        time.sleep(2.5)
        print(index([("Slow.Index", "guide/slow-index")]))
        return 0
    if path == "/slowpage/index.json":
        print(index([("Slow.Page", "guide/slow")]))
        return 0
    if path == "/slowpage/guide/slow.html":
        time.sleep(2.5)
        print("<main><p>Stale slow page.</p></main>")
        return 0
    if path in ("/broken/index.json", "/broken;touch PWNED/index.json"):
        return 22
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
