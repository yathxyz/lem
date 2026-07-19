#!/usr/bin/env python3
"""One-shot STARTTLS/AUTH SMTP server for the submission acceptance test."""

from __future__ import annotations

import base64
import json
import os
import socket
import ssl
from pathlib import Path


PORT_FILE = Path(os.environ["LEM_YATH_SMTP_TEST_PORT_FILE"])
CAPTURE = Path(os.environ["LEM_YATH_SMTP_TEST_CAPTURE"])
CERT = os.environ["LEM_YATH_SMTP_TEST_CERT"]
KEY = os.environ["LEM_YATH_SMTP_TEST_KEY"]
USERNAME = os.environ["LEM_YATH_SMTP_TEST_USERNAME"]
PASSWORD = os.environ["LEM_YATH_SMTP_TEST_PASSWORD"]


def line(stream) -> bytes:
    value = stream.readline(65537)
    if not value or len(value) > 65536:
        raise RuntimeError("invalid SMTP command")
    return value.rstrip(b"\r\n")


def reply(stream, value: bytes) -> None:
    stream.write(value + b"\r\n")
    stream.flush()


def serve() -> None:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    PORT_FILE.write_text(str(listener.getsockname()[1]))
    connection, _ = listener.accept()
    listener.close()
    connection.settimeout(20)
    stream = connection.makefile("rwb", buffering=0)
    reply(stream, b"220 fake.local ESMTP")
    authenticated = False
    tls_active = False
    mail_from = None
    recipients: list[str] = []
    while True:
        command = line(stream)
        upper = command.upper()
        if upper.startswith((b"EHLO ", b"HELO ")):
            reply(stream, b"250-fake.local")
            reply(stream, b"250-STARTTLS")
            reply(stream, b"250 AUTH PLAIN LOGIN")
        elif upper == b"STARTTLS":
            reply(stream, b"220 Ready to start TLS")
            stream.close()
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(CERT, KEY)
            connection = context.wrap_socket(connection, server_side=True)
            connection.settimeout(20)
            stream = connection.makefile("rwb", buffering=0)
            tls_active = True
        elif upper.startswith(b"AUTH PLAIN"):
            if not tls_active:
                reply(stream, b"538 Encryption required")
                continue
            encoded = command.split(maxsplit=2)[2] if len(command.split()) >= 3 else b""
            if not encoded:
                reply(stream, b"334 ")
                encoded = line(stream)
            decoded = base64.b64decode(encoded).split(b"\x00")
            authenticated = decoded[-2:] == [USERNAME.encode(), PASSWORD.encode()]
            reply(stream, b"235 Authentication successful" if authenticated else b"535 Authentication failed")
        elif upper == b"AUTH LOGIN":
            if not tls_active:
                reply(stream, b"538 Encryption required")
                continue
            reply(stream, b"334 VXNlcm5hbWU6")
            username = base64.b64decode(line(stream)).decode()
            reply(stream, b"334 UGFzc3dvcmQ6")
            password = base64.b64decode(line(stream)).decode()
            authenticated = (username, password) == (USERNAME, PASSWORD)
            reply(stream, b"235 Authentication successful" if authenticated else b"535 Authentication failed")
        elif upper.startswith(b"MAIL FROM:"):
            if not authenticated:
                reply(stream, b"530 Authentication required")
                continue
            mail_from = command[len(b"MAIL FROM:") :].decode()
            reply(stream, b"250 OK")
        elif upper.startswith(b"RCPT TO:"):
            recipients.append(command[len(b"RCPT TO:") :].decode())
            reply(stream, b"250 OK")
        elif upper == b"DATA":
            reply(stream, b"354 End data with <CR><LF>.<CR><LF>")
            chunks: list[bytes] = []
            while True:
                value = stream.readline(65537)
                if value == b".\r\n":
                    break
                if not value or len(value) > 65536:
                    raise RuntimeError("invalid SMTP data")
                chunks.append(value[1:] if value.startswith(b"..") else value)
            CAPTURE.write_text(
                json.dumps(
                    {
                        "tls": tls_active,
                        "authenticated": authenticated,
                        "mail_from": mail_from,
                        "recipients": recipients,
                        "message": b"".join(chunks).decode("utf-8"),
                    }
                )
            )
            reply(stream, b"250 Accepted")
        elif upper == b"QUIT":
            reply(stream, b"221 Bye")
            break
        else:
            reply(stream, b"502 Unsupported")
    stream.close()
    connection.close()


if __name__ == "__main__":
    serve()
