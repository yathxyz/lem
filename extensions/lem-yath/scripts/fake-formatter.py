#!/usr/bin/env python3
"""Deterministic fake Black used by the real-ncurses formatting harness.

The harness installs this file as ``black`` through a symlink at the front of
PATH.  It deliberately accepts Black's stdin protocol without trying to parse
Python.  Every invocation is recorded as one locked JSON line so the shell
test can prove argv boundaries, cwd, stdin, timeout wrapping, and invocation
counts without depending on terminal rendering.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--stdin-filename")
    parser.add_argument("input", nargs="?")
    arguments, unknown = parser.parse_known_args()
    arguments.unknown = unknown
    return arguments


def read_mode() -> str:
    mode_file = os.environ.get("LEM_YATH_FAKE_FORMATTER_MODE_FILE")
    if not mode_file:
        return "format"
    try:
        value = Path(mode_file).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return "format"
    return value or "format"


def parent_argv() -> list[str]:
    """Capture GNU timeout's argv while it is still our direct parent."""
    try:
        raw = Path(f"/proc/{os.getppid()}/cmdline").read_bytes()
    except OSError:
        return []
    return [part.decode("utf-8", "surrogateescape") for part in raw.split(b"\0") if part]


def append_event(event: dict[str, object]) -> None:
    event_path = os.environ.get("LEM_YATH_FAKE_FORMATTER_EVENTS")
    if not event_path:
        raise RuntimeError("LEM_YATH_FAKE_FORMATTER_EVENTS is required")
    path = Path(event_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(event, ensure_ascii=True, sort_keys=True) + "\n"
    with path.open("a", encoding="utf-8") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        stream.write(encoded)
        stream.flush()
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def format_source(source: str) -> str:
    """Apply a small idempotent edit whose prefix shifts point and mark."""
    source = source.replace("prefix_value=1", "prefix_value = 1")
    source = source.replace("TAIL_MARKER=2", "TAIL_MARKER = 2")
    marker = "# formatted by fake black\n"
    if marker not in source:
        index = source.find("prefix_value = 1")
        if index >= 0:
            source = source[:index] + marker + source[index:]
        else:
            source = marker + source
    # Black emits a final newline.  Like Emacs require-final-newline semantics,
    # insert_final_newline=false prevents editor-side insertion but does not
    # remove a newline supplied by a formatter.
    return source.rstrip("\n") + "\n"


def verify_event(arguments: list[str]) -> int:
    if len(arguments) != 4:
        sys.stderr.write(
            "usage: fake-formatter.py --verify-event EVENTS INDEX FILE BLACK\n"
        )
        return 2
    event_path, index_text, expected_file, expected_black = arguments
    try:
        index = int(index_text)
        events = [
            json.loads(line)
            for line in Path(event_path).read_text(encoding="utf-8").splitlines()
            if line
        ]
        event = events[index]
    except (OSError, ValueError, IndexError, json.JSONDecodeError) as error:
        sys.stderr.write(f"could not read formatter event: {error}\n")
        return 1

    formatter_argv = [
        "--quiet",
        "--stdin-filename",
        expected_file,
        "-",
    ]
    if event.get("argv") != formatter_argv:
        sys.stderr.write(f"unexpected formatter argv: {event.get('argv')!r}\n")
        return 1
    if event.get("stdin_filename") != expected_file:
        sys.stderr.write(
            f"stdin filename lost its argv boundary: {event.get('stdin_filename')!r}\n"
        )
        return 1
    if event.get("cwd") != str(Path(expected_file).parent):
        sys.stderr.write(f"unexpected formatter cwd: {event.get('cwd')!r}\n")
        return 1

    parent = event.get("parent_argv")
    if not isinstance(parent, list) or len(parent) != 9:
        sys.stderr.write(f"unexpected timeout argv: {parent!r}\n")
        return 1
    if Path(parent[0]).name != "timeout":
        sys.stderr.write(f"formatter was not wrapped by timeout: {parent!r}\n")
        return 1
    if parent[1:3] != ["--signal=TERM", "--kill-after=1"]:
        sys.stderr.write(f"unexpected timeout safety flags: {parent!r}\n")
        return 1
    try:
        if float(parent[3]) <= 0:
            raise ValueError
    except (TypeError, ValueError):
        sys.stderr.write(f"invalid formatter timeout: {parent[3]!r}\n")
        return 1
    black_candidates = {expected_black, str(Path(expected_black).resolve())}
    if parent[4] not in black_candidates or parent[5:] != formatter_argv:
        sys.stderr.write(f"unexpected command tail: {parent[4:]!r}\n")
        return 1
    return 0


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "--verify-event":
        return verify_event(sys.argv[2:])
    arguments = parse_args()
    source_bytes = sys.stdin.buffer.read()
    mode = read_mode()
    event = {
        "argv": sys.argv[1:],
        "cwd": os.getcwd(),
        "mode": mode,
        "parent_argv": parent_argv(),
        "pid": os.getpid(),
        "stdin_hex": source_bytes.hex(),
        "stdin_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "stdin_filename": arguments.stdin_filename,
        "unknown": arguments.unknown,
    }
    append_event(event)

    if mode == "fail":
        # Partial stdout must never be installed in the buffer.
        sys.stdout.write("PARTIAL-MUST-NOT-APPLY\n")
        sys.stdout.flush()
        sys.stderr.write("fake black failed deliberately (exit 23)\n")
        return 23
    if mode == "noop":
        sys.stdout.buffer.write(source_bytes)
        return 0
    if mode not in {"format", "format-spaces"}:
        sys.stderr.write(f"unknown fake formatter mode: {mode}\n")
        return 64

    try:
        source = source_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        sys.stderr.write(f"fake black received non-UTF-8 stdin: {error}\n")
        return 65
    formatted = format_source(source)
    if mode == "format-spaces":
        formatted = "".join(
            f"{line}   \n" for line in formatted.rstrip("\n").split("\n")
        )
    sys.stdout.write(formatted)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
