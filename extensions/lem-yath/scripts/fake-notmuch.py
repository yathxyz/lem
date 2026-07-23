#!/usr/bin/env python3
"""Network-free notmuch subset for the real-TUI mail acceptance test."""

from __future__ import annotations

import json
import os
import re
import sys
import email.policy
from email.parser import BytesParser
from email.message import EmailMessage
from pathlib import Path


LOG = Path(os.environ["LEM_YATH_NOTMUCH_LOG"])
STATE = Path(os.environ["LEM_YATH_NOTMUCH_STATE"])
INSERT_LOG = Path(os.environ["LEM_YATH_NOTMUCH_INSERT_LOG"])
DRAFT_LOG = Path(os.environ["LEM_YATH_NOTMUCH_DRAFT_LOG"])


def log(args: list[str]) -> None:
    with LOG.open("a") as stream:
        stream.write(json.dumps(args) + "\n")


def state() -> dict:
    return json.loads(STATE.read_text())


def save(value: dict) -> None:
    STATE.write_text(json.dumps(value) + "\n")


def message(
    message_id: str, sender: str, subject: str, body: list[dict], tags: list[str]
) -> dict:
    return {
        "id": message_id,
        "tags": tags,
        "headers": {
            "From": sender,
            "To": "Yanni <yanni@example.invalid>",
            "Date": "Wed, 15 Jul 2026 20:00:00 +0100",
            "Subject": subject,
        },
        "body": body,
    }


THREAD_MESSAGES = {
    "alpha": ["alpha@example.invalid"],
    "beta": [
        "payment+safe|touch@example.invalid",
        "reply/second?value@example.invalid",
    ],
    "protected": ["signed@example.invalid"],
}


def decoded_query_value(value: str) -> str:
    return json.loads(f'"{value}"')


def thread_from_query(query: str) -> str | None:
    match = re.fullmatch(r'thread:"((?:\\.|[^"\\])*)"', query)
    return decoded_query_value(match.group(1)) if match else None


def message_ids_from_query(query: str, data: dict | None = None) -> list[str]:
    thread_id = thread_from_query(query)
    if thread_id is not None:
        if data is not None and thread_id in data.get("drafts", {}):
            return [thread_id]
        return THREAD_MESSAGES.get(thread_id, [])
    return [
        decoded_query_value(match)
        for match in re.findall(r'id:"((?:\\.|[^"\\])*)"', query)
    ]


def show_tree(thread_id: str, data: dict) -> list:
    tags = data["tags"]
    if thread_id in data.get("drafts", {}):
        draft = BytesParser(policy=email.policy.default).parsebytes(
            data["drafts"][thread_id].encode()
        )
        body_part = draft.get_body(preferencelist=("plain",))
        body = body_part.get_content() if body_part is not None else ""
        value = {
            "id": thread_id,
            "tags": tags[thread_id],
            "headers": {
                "From": str(draft.get("From", "")),
                "To": str(draft.get("To", "")),
                "Date": str(draft.get("Date", "")),
                "Subject": str(draft.get("Subject", "")),
            },
            "body": [{"content-type": "text/plain", "content": body}],
        }
        return [[[value, []]]]
    if thread_id == "protected":
        protected = message(
            "signed@example.invalid",
            "Bob <bob@example.invalid>",
            "Signed message",
            [
                {
                    "content-type": "multipart/signed",
                    "content": [
                        {
                            "content-type": "text/plain",
                            "content": "Protected body.",
                        },
                        {
                            "content-type": "application/pgp-signature",
                            "content": "signature",
                        },
                    ],
                }
            ],
            data["tags"]["signed@example.invalid"],
        )
        return [[[protected, []]]]
    if thread_id != "beta":
        first = message(
            "alpha@example.invalid",
            "Alice <alice@example.invalid>",
            "First thread",
            [{"content-type": "text/plain", "content": "First plain body."}],
            tags["alpha@example.invalid"],
        )
        return [[[first, []]]]
    original = message(
        "payment+safe|touch@example.invalid",
        "Bob <bob@example.invalid>",
        "Second thread",
        [
            {
                "content-type": "multipart/mixed",
                "content": [
                    {"content-type": "text/plain", "content": "Primary plain body."},
                    {"content-type": "text/html", "content": "<p>ignored html</p>"},
                    {
                        "id": 7,
                        "content-type": "application/pdf",
                        "content-disposition": "attachment",
                        "filename": "quarterly report;safe.pdf",
                        "content-length": 1024,
                    },
                    {
                        "id": 8,
                        "content-type": "application/octet-stream",
                        "content-disposition": "attachment",
                        "filename": "../../archive;safe $(touch PWNED).bin",
                        "content-length": 64,
                    },
                ],
            }
        ],
        tags["payment+safe|touch@example.invalid"],
    )
    reply = message(
        "reply/second?value@example.invalid",
        "Yanni <yanni@example.invalid>",
        "Re: Second thread",
        [{"content-type": "text/plain", "content": "Reply plain body."}],
        tags["reply/second?value@example.invalid"],
    )
    return [[[original, [[reply, []]]]]]


def raw_message(message_id: str) -> bytes | None:
    if message_id == "signed@example.invalid":
        return Path(os.environ["LEM_YATH_NOTMUCH_SIGNED"]).read_bytes()
    if message_id == "payment+safe|touch@example.invalid":
        value = EmailMessage(policy=email.policy.SMTP)
        value["From"] = "Bob <bob@example.invalid>"
        value["To"] = "Yanni <yanni@example.invalid>"
        value["Cc"] = "Team <team@example.invalid>"
        value["Date"] = "Wed, 15 Jul 2026 20:00:00 +0100"
        value["Message-ID"] = f"<{message_id}>"
        value["Subject"] = "Second thread"
        value.set_content("Primary plain body.", charset="utf-8")
        value.add_attachment(
            Path(os.environ["LEM_YATH_NOTMUCH_PDF"]).read_bytes(),
            maintype="application",
            subtype="pdf",
            filename="quarterly report;safe.pdf",
        )
        return value.as_bytes()
    return None


def thread_tags(data: dict, thread_id: str) -> list[str]:
    if thread_id in data.get("drafts", {}):
        return list(data["tags"][thread_id])
    visible = [
        data["tags"][message_id]
        for message_id in THREAD_MESSAGES[thread_id]
        if "deleted" not in data["tags"][message_id]
    ]
    result = {tag for tags in visible for tag in tags}
    preferred = ["inbox", "unread", "flagged", "deleted"]
    return [tag for tag in preferred if tag in result] + sorted(result - set(preferred))


def apply_tag_changes(data: dict, query: str, changes: list[str]) -> None:
    for message_id in message_ids_from_query(query, data):
        tags = data["tags"][message_id]
        for change in changes:
            operation, tag = change[0], change[1:]
            if operation == "+" and tag not in tags:
                tags.append(tag)
            elif operation == "-" and tag in tags:
                tags.remove(tag)


def main() -> int:
    args = sys.argv[1:]
    log(args)
    if not args:
        return 2
    data = state()
    if args[:2] == ["config", "get"] and len(args) == 3:
        values = {
            "user.name": 'Yanni "Safe"',
            "user.primary_email": "yanni@example.invalid",
            "user.other_email": "alias@example.invalid",
        }
        if args[2] not in values:
            return 1
        print(values[args[2]])
        return 0
    if args[0] == "address":
        if (
            args[1:4]
            != [
                "--format=text",
                "--output=recipients",
                "--deduplicate=address",
            ]
            or len(args) != 5
        ):
            print("unexpected address options", file=sys.stderr)
            return 2
        query = args[4]
        match = re.fullmatch(
            r'\(from:"yanni@example\.invalid" or '
            r'from:"alias@example\.invalid"\) and \(to:([A-Za-z0-9_]{3})\*\)',
            query,
        )
        if not match:
            print("address requires the exact sent-mail prefix query", file=sys.stderr)
            return 2
        prefix = match.group(1).lower()
        candidates = {
            "ali": [
                "Alice Example <alice@example.invalid>",
                "Alina Safe; $(touch PWNED) <alina@example.invalid>",
            ],
            "tea": ["Team Address <team@example.invalid>"],
            "bob": ["Bob Example <bob@example.invalid>"],
        }
        if prefix == "err":
            print("injected address failure", file=sys.stderr)
            return 9
        for candidate in candidates.get(prefix, []):
            print(candidate)
        return 0
    if args[0] == "reply":
        if args[1:3] != ["--format=default", "--reply-to=sender"] and args[1:3] != [
            "--format=default",
            "--reply-to=all",
        ]:
            print("unexpected reply options", file=sys.stderr)
            return 2
        query = args[3]
        ids = message_ids_from_query(query, data)
        if not ids:
            print("reply requires an exact message or thread query", file=sys.stderr)
            return 2
        message_id = ids[-1]
        recipient = (
            "Bob <bob@example.invalid>"
            if message_id == "payment+safe|touch@example.invalid"
            else "Yanni <yanni@example.invalid>"
        )
        cc = "Cc: Team <team@example.invalid>\n" if args[2] == "--reply-to=all" else ""
        print(
            'From: "Yanni \\"Safe\\"" <yanni@example.invalid>\n'
            f"To: {recipient}\n"
            f"{cc}"
            "Subject: Re: Second thread\n"
            f"In-Reply-To: <{message_id}>\n"
            f"References: <{message_id}>\n\n"
            "On Wed, 15 Jul 2026, Bob wrote:\n"
            "> Primary plain body."
        )
        return 0
    if args[0] == "insert":
        if args == ["insert", "--create-folder", "--folder=drafts", "+draft"]:
            raw = sys.stdin.buffer.read()
            draft = BytesParser(policy=email.policy.default).parsebytes(raw)
            message_id = str(draft.get("Message-ID", ""))
            if (
                not re.fullmatch(r"<[^<>\r\n]+>", message_id)
                or str(draft.get("X-Notmuch-Emacs-Draft", "")).lower() != "true"
            ):
                print("invalid draft message", file=sys.stderr)
                return 2
            bare_id = message_id[1:-1]
            data.setdefault("drafts", {})[bare_id] = raw.decode()
            data["tags"][bare_id] = ["draft"]
            data["draft_inserts"] = data.get("draft_inserts", 0) + 1
            with DRAFT_LOG.open("ab") as stream:
                stream.write(json.dumps(raw.decode()).encode() + b"\n")
            save(data)
            return 0
        if args != ["insert", "--create-folder", "--folder=sent"]:
            print("unexpected insert invocation", file=sys.stderr)
            return 2
        raw = sys.stdin.buffer.read()
        failure = os.environ.get("LEM_YATH_NOTMUCH_FAIL_INSERT_ONCE")
        if failure and Path(failure).exists():
            Path(failure).unlink()
            print("injected FCC failure", file=sys.stderr)
            return 9
        with INSERT_LOG.open("ab") as stream:
            stream.write(json.dumps(raw.decode()).encode() + b"\n")
        data["inserts"] = data.get("inserts", 0) + 1
        save(data)
        return 0
    if args[0] == "search":
        query = args[-1]
        data["searches"] += 1
        save(data)
        if query == "tag:empty":
            print("[]")
            return 0
        if query == "tag:draft":
            rows = []
            for message_id, raw in data.get("drafts", {}).items():
                tags = data["tags"][message_id]
                if "draft" not in tags or "deleted" in tags:
                    continue
                draft = BytesParser(policy=email.policy.default).parsebytes(
                    raw.encode()
                )
                rows.append(
                    {
                        "thread": message_id,
                        "date_relative": "now",
                        "authors": "Yanni",
                        "subject": str(draft.get("Subject", "(no subject)")),
                        "tags": tags,
                    }
                )
            print(json.dumps(list(reversed(rows))))
            return 0
        refreshed = " refreshed" if data["searches"] > 1 else ""
        rows = [
            {
                "thread": "alpha",
                "date_relative": "today",
                "authors": "Alice",
                "subject": "First thread",
                "tags": thread_tags(data, "alpha"),
            },
            {
                "thread": "beta",
                "date_relative": "yesterday",
                "authors": "Bob",
                "subject": f"Second thread{refreshed}",
                "tags": thread_tags(data, "beta"),
            },
        ]
        rows = [row for row in rows if row["tags"]]
        if "tag:inbox" in query:
            rows = [row for row in rows if "inbox" in row["tags"]]
        print(json.dumps(rows))
        return 0
    if args[0] == "show":
        if any(argument.startswith("--part=") for argument in args):
            success = [
                "show",
                "--format=raw",
                "--part=7",
                'id:"payment+safe|touch@example.invalid"',
            ]
            if args == success:
                sys.stdout.buffer.write(
                    Path(os.environ["LEM_YATH_NOTMUCH_PDF"]).read_bytes()
                )
                return 0
            if args == [
                "show",
                "--format=raw",
                "--part=8",
                'id:"payment+safe|touch@example.invalid"',
            ]:
                sys.stdout.buffer.write(
                    Path(os.environ["LEM_YATH_NOTMUCH_BINARY"]).read_bytes()
                )
                return 0
            if args == ["show", "--format=raw", "--part=8", 'id:"bad@example.invalid"']:
                sys.stdout.buffer.write(b"not a pdf")
                return 0
            if args == [
                "show",
                "--format=raw",
                "--part=9",
                'id:"slow@example.invalid"',
            ]:
                import time

                time.sleep(5)
                sys.stdout.buffer.write(
                    Path(os.environ["LEM_YATH_NOTMUCH_PDF"]).read_bytes()
                )
                return 0
            print("unexpected raw-part invocation", file=sys.stderr)
            return 2
        if args[1:2] == ["--format=raw"] and len(args) == 3:
            ids = message_ids_from_query(args[2], data)
            if len(ids) == 1 and ids[0] in data.get("drafts", {}):
                sys.stdout.buffer.write(data["drafts"][ids[0]].encode())
                return 0
            if len(ids) == 1:
                raw = raw_message(ids[0])
                if raw is not None:
                    sys.stdout.buffer.write(raw)
                    return 0
            print("raw show requires an exact supported message", file=sys.stderr)
            return 2
        thread_id = thread_from_query(args[-1])
        if thread_id is None:
            print("show requires an exact thread query", file=sys.stderr)
            return 2
        print(json.dumps(show_tree(thread_id, data)))
        return 0
    if args[0] == "tag":
        try:
            separator = args.index("--")
            changes = args[1:separator]
            query = args[separator + 1]
        except (ValueError, IndexError):
            print("malformed tag invocation", file=sys.stderr)
            return 2
        if not changes or any(
            len(change) < 2 or change[0] not in "+-" for change in changes
        ):
            print("invalid tag changes", file=sys.stderr)
            return 2
        if "+failtag" in changes:
            print("injected tag failure", file=sys.stderr)
            return 9
        apply_tag_changes(data, query, changes)
        save(data)
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
