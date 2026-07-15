#!/usr/bin/env python3
"""Network-free notmuch subset for the real-TUI mail acceptance test."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


LOG = Path(os.environ["LEM_YATH_NOTMUCH_LOG"])
STATE = Path(os.environ["LEM_YATH_NOTMUCH_STATE"])


def log(args: list[str]) -> None:
    with LOG.open("a") as stream:
        stream.write(json.dumps(args) + "\n")


def state() -> dict[str, int]:
    return json.loads(STATE.read_text())


def save(value: dict[str, int]) -> None:
    STATE.write_text(json.dumps(value) + "\n")


def message(message_id: str, sender: str, subject: str, body: list[dict]) -> dict:
    return {
        "id": message_id,
        "headers": {
            "From": sender,
            "To": "Yanni <yanni@example.invalid>",
            "Date": "Wed, 15 Jul 2026 20:00:00 +0100",
            "Subject": subject,
        },
        "body": body,
    }


def show_tree(thread_id: str) -> list:
    original = message(
        "payment+safe;touch PWNED@example.invalid",
        "Bob <bob@example.invalid>",
        "Second thread",
        [
            {
                "content-type": "multipart/mixed",
                "content": [
                    {"content-type": "text/plain", "content": "Primary plain body."},
                    {"content-type": "text/html", "content": "<p>ignored html</p>"},
                ],
            }
        ],
    )
    reply = message(
        "reply/second?value@example.invalid",
        "Yanni <yanni@example.invalid>",
        "Re: Second thread",
        [{"content-type": "text/plain", "content": "Reply plain body."}],
    )
    if thread_id != "thread:beta":
        original["headers"]["Subject"] = "First thread"
        original["body"] = [
            {"content-type": "text/plain", "content": "First plain body."}
        ]
        return [[[original, []]]]
    return [[[original, [[reply, []]]]]]


def main() -> int:
    args = sys.argv[1:]
    log(args)
    if not args:
        return 2
    data = state()
    if args[0] == "search":
        query = args[-1]
        data["searches"] += 1
        save(data)
        if query == "tag:empty":
            print("[]")
            return 0
        refreshed = " refreshed" if data["searches"] > 1 else ""
        print(
            json.dumps(
                [
                    {
                        "thread": "thread:alpha",
                        "date_relative": "today",
                        "authors": "Alice",
                        "subject": "First thread",
                        "tags": ["inbox", "unread"],
                    },
                    {
                        "thread": "thread:beta",
                        "date_relative": "yesterday",
                        "authors": "Bob",
                        "subject": f"Second thread{refreshed}",
                        "tags": ["inbox"],
                    },
                ]
            )
        )
        return 0
    if args[0] == "show":
        print(json.dumps(show_tree(args[-1])))
        return 0
    if args == ["new"]:
        data["news"] += 1
        save(data)
        print("Processed 1 new message.")
        return 0
    print("unsupported fake notmuch invocation", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
