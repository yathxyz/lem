#!/usr/bin/env python3
"""Submit one RFC 822 message through the configured SMTP service.

The message is read from stdin and the exact normalized message accepted by
SMTP is written to stdout for Notmuch FCC.  Credentials are never accepted on
argv.  They come from a private authinfo file (including authinfo.gpg) or, for
explicitly managed environments, paired SMTP username/password variables.
"""

from __future__ import annotations

import email.policy
import email.utils
import ipaddress
import os
import shlex
import shutil
import smtplib
import ssl
import stat
import subprocess
import sys
from email.parser import BytesParser
from pathlib import Path


MAX_MESSAGE_BYTES = 10 * 1024 * 1024
MAX_AUTHINFO_BYTES = 1024 * 1024
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 1025


class SubmitError(RuntimeError):
    pass


def bounded_stdin() -> bytes:
    data = sys.stdin.buffer.read(MAX_MESSAGE_BYTES + 1)
    if len(data) > MAX_MESSAGE_BYTES:
        raise SubmitError("message exceeds the 10 MiB submission limit")
    if not data:
        raise SubmitError("message is empty")
    if b"\x00" in data:
        raise SubmitError("message contains a NUL byte")
    return data


def one_address(value: str, label: str) -> str:
    parsed = [address for _, address in email.utils.getaddresses([value]) if address]
    if len(parsed) != 1 or any(character in parsed[0] for character in "\r\n\x00"):
        raise SubmitError(f"{label} must contain exactly one valid address")
    return parsed[0]


def recipient_addresses(message) -> list[str]:
    values: list[str] = []
    for header in ("To", "Cc", "Bcc"):
        values.extend(message.get_all(header, []))
    result = [address for _, address in email.utils.getaddresses(values) if address]
    if not result or any(any(c in address for c in "\r\n\x00") for address in result):
        raise SubmitError("To, Cc, or Bcc must contain at least one valid address")
    return list(dict.fromkeys(result))


def normalized_message(raw: bytes):
    message = BytesParser(policy=email.policy.SMTP).parsebytes(raw)
    if message.defects:
        raise SubmitError("message headers are malformed")
    for name in ("From", "Sender", "To", "Cc", "Bcc"):
        for header in message.get_all(name, []):
            if getattr(header, "defects", ()):
                raise SubmitError(f"{name} contains a malformed address")
    if (
        len(message.get_all("From", [])) != 1
        or len(message.get_all("Sender", [])) > 1
    ):
        raise SubmitError("message must contain exactly one From and at most one Sender")
    if message.is_multipart() or message.get_content_maintype() != "text":
        raise SubmitError("only bounded text message composition is supported")
    from_value = message.get("Sender") or message.get("From")
    envelope_from = one_address(str(from_value), "From")
    recipients = recipient_addresses(message)
    while message.get("Bcc") is not None:
        del message["Bcc"]
    while message.get("Fcc") is not None:
        del message["Fcc"]
    if message.get("Date") is None:
        message["Date"] = email.utils.formatdate(localtime=True)
    if message.get("Message-ID") is None:
        message["Message-ID"] = email.utils.make_msgid()
    if message.get("MIME-Version") is None:
        message["MIME-Version"] = "1.0"
    if message.get("Content-Type") is None:
        message["Content-Type"] = "text/plain; charset=utf-8"
    if message.get("Content-Transfer-Encoding") is None:
        message["Content-Transfer-Encoding"] = "8bit"
    wire = message.as_bytes(policy=email.policy.SMTP)
    if len(wire) > MAX_MESSAGE_BYTES:
        raise SubmitError("normalized message exceeds the 10 MiB submission limit")
    return envelope_from, recipients, wire


def private_authinfo(path: Path) -> bytes:
    try:
        info = path.lstat()
    except OSError as error:
        raise SubmitError("could not inspect the SMTP authinfo file") from error
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise SubmitError("SMTP authinfo must be a regular file owned by the current user")
    if info.st_mode & 0o077:
        raise SubmitError("SMTP authinfo permissions must not grant group or other access")
    if info.st_size > MAX_AUTHINFO_BYTES:
        raise SubmitError("SMTP authinfo exceeds the 1 MiB limit")
    if path.suffix != ".gpg":
        return path.read_bytes()
    gpg = os.environ.get("LEM_YATH_GPG_PROGRAM") or shutil.which("gpg")
    if not gpg:
        raise SubmitError("gpg is required to read the encrypted SMTP authinfo file")
    try:
        result = subprocess.run(
            [gpg, "--quiet", "--decrypt", os.fspath(path)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SubmitError("could not decrypt the SMTP authinfo file") from error
    if result.returncode != 0 or len(result.stdout) > MAX_AUTHINFO_BYTES:
        raise SubmitError("could not decrypt the SMTP authinfo file")
    return result.stdout


def authinfo_candidates() -> list[Path]:
    configured = os.environ.get("LEM_YATH_SMTP_AUTHINFO")
    if configured:
        return [Path(configured).expanduser()]
    home = Path.home()
    return [home / ".authinfo.gpg", home / ".authinfo", home / ".netrc"]


def authinfo_entries(text: str) -> list[dict[str, str]]:
    try:
        tokens = shlex.split(text, comments=True, posix=True)
    except ValueError as error:
        raise SubmitError("SMTP authinfo contains malformed quoting") from error
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    index = 0
    while index < len(tokens):
        field = tokens[index]
        if field == "machine":
            if index + 1 >= len(tokens):
                raise SubmitError("SMTP authinfo has a machine without a name")
            current = {"machine": tokens[index + 1]}
            entries.append(current)
            index += 2
        elif field == "default":
            current = {"machine": "default"}
            entries.append(current)
            index += 1
        elif field == "macdef":
            raise SubmitError("SMTP authinfo macdef entries are not supported")
        elif current is None or index + 1 >= len(tokens):
            raise SubmitError("SMTP authinfo contains a field outside a machine entry")
        else:
            current[field] = tokens[index + 1]
            index += 2
    return entries


def authinfo_credentials(host: str, port: int) -> tuple[str, str] | None:
    exact_hosts = {host, f"{host}:{port}"}
    for path in authinfo_candidates():
        if not path.exists():
            continue
        try:
            text = private_authinfo(path).decode("utf-8")
        except UnicodeDecodeError as error:
            raise SubmitError("SMTP authinfo is not UTF-8 text") from error
        for fields in authinfo_entries(text):
            machine = fields.get("machine")
            entry_port = fields.get("port")
            host_matches = machine == "default" or machine in exact_hosts
            if not host_matches or (entry_port and entry_port != str(port)):
                continue
            username = fields.get("login") or fields.get("user")
            password = fields.get("password")
            if username and password:
                return username, password
    return None


def credentials(host: str, port: int) -> tuple[str, str] | None:
    username = os.environ.get("LEM_YATH_SMTP_USERNAME")
    password = os.environ.get("LEM_YATH_SMTP_PASSWORD")
    if bool(username) != bool(password):
        raise SubmitError("SMTP username and password variables must be set together")
    return (username, password) if username and password else authinfo_credentials(host, port)


def loopback_host(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def tls_context(host: str) -> ssl.SSLContext:
    ca_file = os.environ.get("LEM_YATH_SMTP_CA_FILE")
    if ca_file:
        return ssl.create_default_context(cafile=os.path.expanduser(ca_file))
    if loopback_host(host):
        # Proton Bridge normally presents a local, self-signed certificate.
        # This exception is deliberately confined to a loopback destination.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        return context
    return ssl.create_default_context()


def submit() -> bytes:
    raw = bounded_stdin()
    envelope_from, recipients, wire = normalized_message(raw)
    host = os.environ.get("LEM_YATH_SMTP_SERVER", DEFAULT_HOST).strip()
    try:
        port = int(os.environ.get("LEM_YATH_SMTP_PORT", str(DEFAULT_PORT)))
    except ValueError as error:
        raise SubmitError("LEM_YATH_SMTP_PORT must be an integer") from error
    if not host or not 1 <= port <= 65535:
        raise SubmitError("SMTP host or port is invalid")
    login = credentials(host, port)
    if login is None:
        raise SubmitError("no matching private SMTP authinfo credentials were found")
    with smtplib.SMTP(host, port, timeout=30) as smtp:
        smtp.ehlo_or_helo_if_needed()
        smtp.starttls(context=tls_context(host))
        smtp.ehlo()
        smtp.login(*login)
        smtp.sendmail(envelope_from, recipients, wire)
    return wire


def main() -> int:
    try:
        sys.stdout.buffer.write(submit())
        return 0
    except (SubmitError, OSError, smtplib.SMTPException, ssl.SSLError) as error:
        print(f"SMTP submission failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
