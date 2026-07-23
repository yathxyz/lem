#!/usr/bin/env python3
"""Controllable Ruff stand-in used only by lint-test.sh."""

import os
import sys
import time


payload = sys.stdin.read()
event_path = os.environ["LEM_YATH_LINT_EVENTS"]
slow = "SLOW" in payload

with open(event_path, "a", encoding="utf-8") as stream:
    stream.write("slow-start\n" if slow else "fast-start\n")

if slow:
    time.sleep(5)
    print("-:1:1: F999 stale diagnostic")
else:
    print("-:2:1: F998 current diagnostic")

raise SystemExit(1)
