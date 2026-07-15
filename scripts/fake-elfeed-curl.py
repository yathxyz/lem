#!/usr/bin/env python3
"""Stateful, network-free Fever API subset for the Elfeed TUI test."""

from __future__ import annotations

import fcntl
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit


LOG = Path(os.environ["LEM_YATH_ELFEED_CURL_LOG"])
STATE = Path(os.environ["LEM_YATH_ELFEED_STATE"])


def append_log(record: dict) -> None:
    with LOG.open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(record) + "\n")


def update_unread_count() -> int:
    with STATE.open("r+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        data = json.load(stream)
        data["unread_requests"] += 1
        stream.seek(0)
        json.dump(data, stream)
        stream.write("\n")
        stream.truncate()
        return data["unread_requests"]


def unread_count() -> int:
    with STATE.open() as stream:
        fcntl.flock(stream, fcntl.LOCK_SH)
        return json.load(stream)["unread_requests"]


def item(item_id: int, title: str, html: str) -> dict:
    return {
        "id": item_id,
        "feed_id": 7,
        "title": title,
        "url": f"https://example.invalid/{item_id}?x=1&safe=touch%20PWNED",
        "html": html,
        "created_on_time": 1784156400,
    }


def items(ids: str) -> list[dict]:
    if ids == "101,102":
        refreshed = " refreshed" if unread_count() >= 2 else ""
        return [
            item(101, "First item", "<p>First body.</p>"),
            item(
                102,
                f"Second item{refreshed}",
                "<p>Second <strong>body</strong> &amp; decoded.</p>"
                "<script>hidden script</script><style>hidden style</style>",
            ),
        ]
    if ids == "201":
        return [item(201, "Stale generation item", "<p>Stale body.</p>")]
    if ids == "301":
        return [item(301, "Newest generation item", "<p>Newest body.</p>")]
    return []


def main() -> int:
    args = sys.argv[1:]
    secret = sys.stdin.read()
    append_log({"argv": args, "stdin": secret})
    if not args:
        return 2
    url = args[-1]
    query = urlsplit(url).query
    if query == "api&feeds":
        print(json.dumps({"feeds": [{"id": 7, "title": "Test Feed"}]}))
        return 0
    if query == "api&unread_item_ids":
        count = update_unread_count()
        if count == 3:
            time.sleep(2.5)
        if count in (1, 2):
            ids = "101,102"
        elif count == 3:
            ids = "201"
        elif count == 4:
            ids = "301"
        elif count == 5:
            ids = ""
        else:
            return 22
        print(json.dumps({"unread_item_ids": ids}))
        return 0
    marker = "api&items&with_ids="
    if query.startswith(marker):
        print(json.dumps({"items": items(query.removeprefix(marker))}))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
