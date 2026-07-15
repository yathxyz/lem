#!/usr/bin/env python3
"""Stateful, network-free gh subset for the Forge TUI acceptance test."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


STATE = Path(os.environ["LEM_YATH_FORGE_FAKE_STATE"])
LOG = Path(os.environ["LEM_YATH_FORGE_FAKE_LOG"])


def load() -> dict:
    return json.loads(STATE.read_text())


def save(state: dict) -> None:
    STATE.write_text(json.dumps(state, indent=2) + "\n")


def option(args: list[str], name: str) -> str:
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return ""


def collection(state: dict, noun: str) -> list[dict]:
    return state["pullreqs" if noun == "pr" else "issues"]


def topic(items: list[dict], number: int) -> dict:
    return next(item for item in items if item["number"] == number)


def main() -> int:
    args = sys.argv[1:]
    with LOG.open("a") as stream:
        stream.write(json.dumps(args) + "\n")
    if len(args) < 2 or args[0] not in {"pr", "issue"}:
        print("unsupported fake-gh invocation", file=sys.stderr)
        return 2

    noun, verb = args[0], args[1]
    state = load()
    items = collection(state, noun)

    if verb == "list":
        requested = option(args, "--state")
        result = [item for item in items if requested == "all" or item["state"].lower() == requested]
        print(json.dumps(result))
        return 0

    if verb == "view":
        print(json.dumps(topic(items, int(args[2]))))
        return 0

    if verb == "create":
        number = max((item["number"] for item in items), default=0) + 1
        kind = "pullreq" if noun == "pr" else "issue"
        item = {
            "number": number,
            "title": option(args, "--title"),
            "body": option(args, "--body"),
            "author": {"login": "lem-test"},
            "state": "OPEN",
            "url": f"https://github.com/yath/test/{'pull' if noun == 'pr' else 'issues'}/{number}",
            "updatedAt": "2026-07-15T20:00:00Z",
            "comments": [],
        }
        if kind == "pullreq":
            item.update({"isDraft": False, "headRefName": "feature", "baseRefName": "main"})
        items.append(item)
        save(state)
        print(item["url"])
        return 0

    number = int(args[2])
    item = topic(items, number)
    if verb == "comment":
        item.setdefault("comments", []).append(
            {
                "author": {"login": "lem-test"},
                "createdAt": "2026-07-15T20:01:00Z",
                "body": option(args, "--body"),
            }
        )
    elif verb == "close":
        item["state"] = "CLOSED"
    elif verb == "reopen":
        item["state"] = "OPEN"
    else:
        print(f"unsupported fake-gh verb: {verb}", file=sys.stderr)
        return 2
    save(state)
    print(item["url"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
