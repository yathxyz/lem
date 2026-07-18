#!/usr/bin/env python3
"""Record Lem submission stdin and return a deterministic FCC message."""

from __future__ import annotations

import email.policy
import json
import os
import sys
from email.parser import BytesParser
from pathlib import Path


LOG = Path(os.environ["LEM_YATH_SMTP_FAKE_LOG"])


def main() -> int:
    raw = sys.stdin.buffer.read()
    message = BytesParser(policy=email.policy.SMTP).parsebytes(raw)
    if not message.get("From") or not message.get("To") or not message.get("Subject"):
        print("fake SMTP rejected missing headers", file=sys.stderr)
        return 1
    while message.get("Bcc") is not None:
        del message["Bcc"]
    message["Date"] = "Sat, 18 Jul 2026 12:00:00 +0100"
    message["Message-ID"] = "<lem-yath-sent@example.invalid>"
    wire = message.as_bytes(policy=email.policy.SMTP)
    with LOG.open("a") as stream:
        stream.write(json.dumps({"argv": sys.argv[1:], "input": raw.decode(), "wire": wire.decode()}) + "\n")
    sys.stdout.buffer.write(wire)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
