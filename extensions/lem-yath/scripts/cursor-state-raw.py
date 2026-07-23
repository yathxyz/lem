#!/usr/bin/env python3
"""Capture bounded terminal output or assert its final DECSCUSR event."""

from __future__ import annotations

import re
import sys
from pathlib import Path

MAX_CAPTURE_BYTES = 8 * 1024 * 1024


def capture(path: Path) -> int:
    remaining = MAX_CAPTURE_BYTES
    with path.open("wb", buffering=0) as output:
        while remaining:
            chunk = sys.stdin.buffer.read1(min(65536, remaining))
            if not chunk:
                break
            output.write(chunk)
            remaining -= len(chunk)
    return 0


def assert_shape(path: Path, offset: int, expected: int) -> int:
    with path.open("rb") as stream:
        stream.seek(offset)
        data = stream.read(MAX_CAPTURE_BYTES + 1)
    if len(data) > MAX_CAPTURE_BYTES:
        print("terminal capture segment exceeds 8 MiB", file=sys.stderr)
        return 1
    events = [int(value) for value in re.findall(rb"\x1b\[([0-9]+) q", data)]
    if not events:
        return 1
    if events[-1] != expected:
        print(
            f"expected final cursor shape {expected}, got {events[-1]} "
            f"from events {events}",
            file=sys.stderr,
        )
        return 1
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "capture":
        return capture(Path(sys.argv[2]))

    if len(sys.argv) != 4:
        print(
            f"usage: {sys.argv[0]} capture RAW | RAW OFFSET EXPECTED",
            file=sys.stderr,
        )
        return 2

    path = Path(sys.argv[1])
    offset = int(sys.argv[2])
    expected = int(sys.argv[3])
    if offset < 0:
        print("offset must be non-negative", file=sys.stderr)
        return 2
    return assert_shape(path, offset, expected)


if __name__ == "__main__":
    raise SystemExit(main())
