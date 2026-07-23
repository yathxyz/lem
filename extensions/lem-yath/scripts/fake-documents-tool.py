#!/usr/bin/env python3
"""Deterministic argv-only stand-in for the document reader subprocesses."""

import json
import os
import pathlib
import sys
import time


def log(tool: str, arguments: list[str]) -> None:
    with open(os.environ["LEM_YATH_DOCUMENTS_LOG"], "a", encoding="utf-8") as stream:
        json.dump([tool, *arguments], stream)
        stream.write("\n")


tool = pathlib.Path(sys.argv[0]).name
arguments = sys.argv[1:]
log(tool, arguments)

source = arguments[-1] if arguments else ""
if tool == "pdfinfo":
    print("Title: Safe Reader Fixture")
    print("Author: Lem Test")
    print("Pages: 3")
elif tool == "pdftotext":
    page = arguments[arguments.index("-f") + 1]
    sys.stdout.write(f"Extracted PDF page {page}\ncontrol:\x00\x1b\x7f\x9f safe\n")
elif tool == "pandoc":
    if "oversized.epub" in source:
        sys.stdout.write("X" * 4096)
    elif "slow.epub" in source:
        time.sleep(5)
        print("too late")
    else:
        print("# First Chapter")
        print()
        print("First EPUB body.")
        print()
        print("## Second Chapter")
        print()
        print("Second EPUB body.")
elif tool == "xdg-open":
    pass
else:
    print(f"unexpected fake tool name: {tool}", file=sys.stderr)
    raise SystemExit(64)
