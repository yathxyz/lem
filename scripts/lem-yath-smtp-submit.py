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
import html
import ipaddress
import os
import re
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
MAX_ATTACHMENT_BYTES = 7 * 1024 * 1024
MAX_ATTACHMENTS = 16
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 1025

MML_ATTACHMENT = re.compile(
    r'<#part type="([A-Za-z0-9][A-Za-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*)" '
    r'filename="([^"\r\n]*)" disposition=attachment>[ \t]*'
)


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


def attachment_bytes(encoded_path: str) -> tuple[Path, bytes]:
    path_text = html.unescape(encoded_path)
    if not path_text or any(character in path_text for character in "\r\n\x00"):
        raise SubmitError("attachment path is malformed")
    path = Path(os.path.abspath(os.path.expanduser(path_text)))
    try:
        before = path.lstat()
    except OSError as error:
        raise SubmitError(f"could not inspect attachment: {path}") from error
    if not stat.S_ISREG(before.st_mode):
        raise SubmitError(f"attachment is not a regular file: {path}")
    if before.st_size > MAX_ATTACHMENT_BYTES:
        raise SubmitError("attachment exceeds the 7 MiB composition limit")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SubmitError(f"could not read attachment: {path}") from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (
                opened.st_dev,
                opened.st_ino,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
            )
            != (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            )
            or opened.st_size > MAX_ATTACHMENT_BYTES
        ):
            raise SubmitError(f"attachment changed or is unsafe: {path}")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            data = stream.read(MAX_ATTACHMENT_BYTES + 1)
        after = os.fstat(descriptor)
        if (
            (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            )
            != (
                opened.st_dev,
                opened.st_ino,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
            )
            or len(data) != opened.st_size
        ):
            raise SubmitError(f"attachment changed while being read: {path}")
    finally:
        os.close(descriptor)
    if len(data) > MAX_ATTACHMENT_BYTES:
        raise SubmitError("attachment exceeds the 7 MiB composition limit")
    return path, data


def expand_mml_attachments(message) -> None:
    payload = message.get_payload(decode=True)
    if payload is None:
        payload = b""
    charset = message.get_content_charset() or "utf-8"
    try:
        body = payload.decode(charset)
    except (LookupError, UnicodeDecodeError) as error:
        raise SubmitError("message body is not valid text") from error

    cleaned_lines: list[str] = []
    attachments: list[tuple[str, str]] = []
    for line in body.splitlines(keepends=True):
        marker = line.rstrip("\r\n")
        if marker.startswith("<#!part"):
            cleaned_lines.append(line.replace("<#!part", "<#part", 1))
        elif marker.startswith("<#part"):
            match = MML_ATTACHMENT.fullmatch(marker)
            if match is None:
                raise SubmitError("attachment marker is malformed")
            attachments.append((match.group(1), match.group(2)))
            if len(attachments) > MAX_ATTACHMENTS:
                raise SubmitError("message contains more than 16 attachments")
        else:
            cleaned_lines.append(line)
    if not attachments:
        return

    subtype = message.get_content_subtype()
    message.clear_content()
    message.set_content(
        "".join(cleaned_lines), subtype=subtype, charset="utf-8", cte="8bit"
    )
    aggregate = 0
    for content_type, encoded_path in attachments:
        path, data = attachment_bytes(encoded_path)
        aggregate += len(data)
        if aggregate > MAX_ATTACHMENT_BYTES:
            raise SubmitError("attachments exceed the 7 MiB aggregate limit")
        maintype, subtype = content_type.split("/", 1)
        message.add_attachment(
            data, maintype=maintype, subtype=subtype, filename=path.name
        )


def escape_mml_text(text: str) -> str:
    """Quote literal attachment-looking lines while text remains editable."""
    return "".join(
        line.replace("<#part", "<#!part", 1)
        if line.rstrip("\r\n").startswith("<#part")
        else line
        for line in text.splitlines(keepends=True)
    )


def parsed_composition(raw: bytes, *, validate_addresses: bool = True):
    message = BytesParser(policy=email.policy.SMTP).parsebytes(raw)
    if message.defects:
        raise SubmitError("message headers are malformed")
    if validate_addresses:
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
    return message


def normalized_message(raw: bytes):
    message = parsed_composition(raw)
    expand_mml_attachments(message)
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
    if not message.is_multipart() and message.get("Content-Transfer-Encoding") is None:
        message["Content-Transfer-Encoding"] = "8bit"
    wire = message.as_bytes(policy=email.policy.SMTP)
    if len(wire) > MAX_MESSAGE_BYTES:
        raise SubmitError("normalized message exceeds the 10 MiB submission limit")
    return envelope_from, recipients, wire


def prepared_draft(
    raw: bytes,
    reply_query: str | None = None,
    forward_query: str | None = None,
) -> bytes:
    """Return a MIME snapshot suitable for ``notmuch insert +draft``."""
    # Drafts are intentionally allowed to contain unfinished recipient fields;
    # normalized_message performs the strict address checks before any send.
    message = parsed_composition(raw, validate_addresses=False)
    expand_mml_attachments(message)
    for name in (
        "Date",
        "Message-ID",
        "X-Notmuch-Emacs-Draft",
        "X-Lem-Yath-Reply-Query",
        "X-Lem-Yath-Forward-Query",
    ):
        while message.get(name) is not None:
            del message[name]
    if reply_query is not None and forward_query is not None:
        raise SubmitError("a draft cannot be both a reply and a forward")
    for label, query, header_name in (
        ("reply", reply_query, "X-Lem-Yath-Reply-Query"),
        ("forward", forward_query, "X-Lem-Yath-Forward-Query"),
    ):
        if query is None:
            continue
        if (
            not query
            or len(query) > 4096
            or any(character in query for character in "\r\n\x00")
        ):
            raise SubmitError(f"draft {label} query is malformed")
        message[header_name] = query
    message["Date"] = email.utils.formatdate(localtime=True)
    message["Message-ID"] = email.utils.make_msgid(idstring="draft")
    message["X-Notmuch-Emacs-Draft"] = "True"
    if message.get("MIME-Version") is None:
        message["MIME-Version"] = "1.0"
    if message.get("Content-Type") is None:
        message["Content-Type"] = "text/plain; charset=utf-8"
    if not message.is_multipart() and message.get("Content-Transfer-Encoding") is None:
        message["Content-Transfer-Encoding"] = "8bit"
    wire = message.as_bytes(policy=email.policy.SMTP)
    if len(wire) > MAX_MESSAGE_BYTES:
        raise SubmitError("draft snapshot exceeds the 10 MiB limit")
    return wire


def decoded_text(part) -> str:
    payload = part.get_payload(decode=True)
    if payload is None:
        payload = b""
    charset = part.get_content_charset() or "utf-8"
    try:
        return payload.decode(charset)
    except (LookupError, UnicodeDecodeError) as error:
        raise SubmitError("draft body is not valid text") from error


def private_draft_directory(value: str) -> Path:
    directory = Path(value)
    try:
        info = directory.lstat()
    except OSError as error:
        raise SubmitError("could not inspect the draft attachment directory") from error
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o077
    ):
        raise SubmitError("draft attachment directory must be owner-private")
    return directory


def safe_attachment_name(value: str | None, index: int) -> str:
    name = (value or f"attachment-{index}").replace("\\", "/").rsplit("/", 1)[-1]
    if (
        not name
        or name in {".", ".."}
        or any(character in name for character in "\r\n\x00")
    ):
        name = f"attachment-{index}"
    return name[:200]


def write_draft_attachment(
    directory: Path, filename: str, data: bytes, index: int
) -> Path:
    stem, suffix = os.path.splitext(filename)
    for collision in range(1000):
        name = filename if collision == 0 else f"{stem}-{collision + 1}{suffix}"
        path = directory / name
        flags = (
            os.O_CREAT
            | os.O_EXCL
            | os.O_WRONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            descriptor = os.open(path, flags, 0o600)
        except FileExistsError:
            continue
        except OSError as error:
            raise SubmitError(f"could not create draft attachment {index}") from error
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb", closefd=False) as stream:
                stream.write(data)
                stream.flush()
        finally:
            os.close(descriptor)
        return path
    raise SubmitError("could not allocate a unique draft attachment name")


def resumed_draft(raw: bytes, directory_value: str) -> bytes:
    """Restore one saved MIME draft to editable text plus MML markers."""
    if len(raw) > MAX_MESSAGE_BYTES:
        raise SubmitError("saved draft exceeds the 10 MiB limit")
    message = BytesParser(policy=email.policy.SMTP).parsebytes(raw)
    if message.defects:
        raise SubmitError("saved draft headers are malformed")
    draft_headers = message.get_all("X-Notmuch-Emacs-Draft", [])
    if len(draft_headers) != 1 or str(draft_headers[0]).strip().lower() != "true":
        raise SubmitError("message is not a Lem/Notmuch draft")

    directory = private_draft_directory(directory_value)
    body = ""
    attachment_parts = []
    if message.is_multipart():
        if message.get_content_type() != "multipart/mixed":
            raise SubmitError("saved draft has an unsupported MIME structure")
        body_parts = []
        for part in message.iter_parts():
            if part.get_content_disposition() == "attachment":
                attachment_parts.append(part)
            elif not part.is_multipart() and part.get_content_type() == "text/plain":
                body_parts.append(part)
            else:
                raise SubmitError("saved draft has an unsupported MIME part")
        if len(body_parts) != 1:
            raise SubmitError("saved draft must contain exactly one text body")
        body = decoded_text(body_parts[0])
    elif message.get_content_maintype() == "text":
        body = decoded_text(message)
    else:
        raise SubmitError("saved draft does not contain editable text")

    if len(attachment_parts) > MAX_ATTACHMENTS:
        raise SubmitError("saved draft contains more than 16 attachments")
    created: list[Path] = []
    markers: list[str] = []
    aggregate = 0
    try:
        for index, part in enumerate(attachment_parts, 1):
            data = part.get_payload(decode=True)
            if data is None:
                raise SubmitError("saved draft attachment is malformed")
            aggregate += len(data)
            if len(data) > MAX_ATTACHMENT_BYTES or aggregate > MAX_ATTACHMENT_BYTES:
                raise SubmitError("saved draft attachments exceed the 7 MiB limit")
            content_type = part.get_content_type()
            if MML_ATTACHMENT.fullmatch(
                f'<#part type="{content_type}" filename="x" disposition=attachment>'
            ) is None:
                raise SubmitError("saved draft attachment type is malformed")
            filename = safe_attachment_name(part.get_filename(), index)
            path = write_draft_attachment(directory, filename, data, index)
            created.append(path)
            markers.append(
                f'<#part type="{content_type}" '
                f'filename="{html.escape(os.fspath(path), quote=True)}" '
                "disposition=attachment>"
            )

        excluded = {
            "date",
            "message-id",
            "x-notmuch-emacs-draft",
            "mime-version",
            "content-type",
            "content-transfer-encoding",
        }
        headers = []
        for name, value in message.items():
            if name.lower() in excluded:
                continue
            text = str(value)
            if any(character in text for character in "\r\n\x00"):
                raise SubmitError(f"saved draft {name} header is malformed")
            headers.append(f"{name}: {text}")
        editable = (
            "\n".join(headers)
            + "\n\n"
            + escape_mml_text(body.replace("\r\n", "\n"))
        )
        if markers:
            if not editable.endswith("\n"):
                editable += "\n"
            editable += "\n".join(markers) + "\n"
        output = editable.encode("utf-8")
        if len(output) > MAX_MESSAGE_BYTES:
            raise SubmitError("resumed draft exceeds the 10 MiB limit")
        return output
    except Exception:
        for path in created:
            try:
                path.unlink()
            except OSError:
                pass
        raise


def prepared_forward(raw: bytes, directory_value: str) -> bytes:
    """Return the stock inline-forward shape with safe local attachment MML."""
    if len(raw) > MAX_MESSAGE_BYTES:
        raise SubmitError("message to forward exceeds the 10 MiB limit")
    message = BytesParser(policy=email.policy.SMTP).parsebytes(raw)
    if message.defects:
        raise SubmitError("message to forward has malformed headers")
    protected_types = {
        "multipart/signed",
        "multipart/encrypted",
        "application/pkcs7-mime",
        "application/x-pkcs7-mime",
    }
    if any(part.get_content_type() in protected_types for part in message.walk()):
        raise SubmitError("signed or encrypted messages require raw MIME forwarding")

    def header(name: str, *, required: bool = False) -> str:
        values = message.get_all(name, [])
        if required and len(values) != 1:
            raise SubmitError(f"message to forward requires exactly one {name} header")
        if len(values) > 1:
            raise SubmitError(f"message to forward has duplicate {name} headers")
        value = str(values[0]) if values else ""
        if any(character in value for character in "\r\n\x00"):
            raise SubmitError(f"message to forward has a malformed {name} header")
        return value

    from_value = header("From", required=True)
    subject = header("Subject")
    message_id = header("Message-ID", required=True)
    if not re.fullmatch(r"<[^<>\r\n]+>", message_id):
        raise SubmitError("message to forward has an invalid Message-ID")
    sender_name, sender_address = email.utils.parseaddr(from_value)
    source = sender_name or sender_address or "(nowhere)"
    forward_subject = f"[{source}] {subject}"

    body_part = message.get_body(preferencelist=("plain",))
    if body_part is None and not message.is_multipart() and message.get_content_type() == "text/plain":
        body_part = message
    if body_part is None or body_part.is_multipart():
        raise SubmitError("message to forward has no bounded text/plain body")
    body = escape_mml_text(decoded_text(body_part).replace("\r\n", "\n"))

    attachment_parts = [
        part
        for part in message.walk()
        if part.get_content_disposition() == "attachment"
    ]
    if len(attachment_parts) > MAX_ATTACHMENTS:
        raise SubmitError("message to forward contains more than 16 attachments")
    directory = private_draft_directory(directory_value)
    created: list[Path] = []
    markers: list[str] = []
    aggregate = 0
    try:
        for index, part in enumerate(attachment_parts, 1):
            if part.is_multipart():
                raise SubmitError("message to forward has an unsupported MIME attachment")
            data = part.get_payload(decode=True)
            if data is None:
                raise SubmitError("message to forward has a malformed attachment")
            aggregate += len(data)
            if len(data) > MAX_ATTACHMENT_BYTES or aggregate > MAX_ATTACHMENT_BYTES:
                raise SubmitError("forwarded attachments exceed the 7 MiB limit")
            content_type = part.get_content_type()
            if MML_ATTACHMENT.fullmatch(
                f'<#part type="{content_type}" filename="x" disposition=attachment>'
            ) is None:
                raise SubmitError("message to forward has an invalid attachment type")
            path = write_draft_attachment(
                directory, safe_attachment_name(part.get_filename(), index), data, index
            )
            created.append(path)
            markers.append(
                f'<#part type="{content_type}" '
                f'filename="{html.escape(os.fspath(path), quote=True)}" '
                "disposition=attachment>"
            )

        included_headers = []
        for name in ("From", "To", "Cc", "Date", "Subject"):
            value = header(name)
            if value:
                included_headers.append(f"{name}: {value}")
        forwarded = (
            "\n-------------------- Start of forwarded message --------------------\n"
            + "\n".join(included_headers)
            + "\n\n"
            + body
        )
        if not forwarded.endswith("\n"):
            forwarded += "\n"
        if markers:
            forwarded += "\n".join(markers) + "\n"
        forwarded += "-------------------- End of forwarded message --------------------\n"
        template = (
            f"To: \nSubject: {forward_subject}\nReferences: {message_id}\n\n"
            + forwarded
        )
        output = template.encode("utf-8")
        if len(output) > MAX_MESSAGE_BYTES:
            raise SubmitError("forward composition exceeds the 10 MiB limit")
        return output
    except Exception:
        for path in created:
            try:
                path.unlink()
            except OSError:
                pass
        raise


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
    arguments = sys.argv[1:]
    label = "SMTP submission failed"
    try:
        if not arguments:
            output = submit()
        elif arguments[:1] == ["--prepare-draft"] and len(arguments) <= 2:
            label = "Notmuch draft preparation failed"
            output = prepared_draft(
                bounded_stdin(), arguments[1] if len(arguments) == 2 else None
            )
        elif len(arguments) == 2 and arguments[0] == "--prepare-draft-forward":
            label = "Notmuch draft preparation failed"
            output = prepared_draft(bounded_stdin(), forward_query=arguments[1])
        elif len(arguments) == 2 and arguments[0] == "--resume-draft":
            label = "Notmuch draft resume failed"
            output = resumed_draft(bounded_stdin(), arguments[1])
        elif len(arguments) == 2 and arguments[0] == "--prepare-forward":
            label = "Notmuch forward preparation failed"
            output = prepared_forward(bounded_stdin(), arguments[1])
        else:
            raise SubmitError("unsupported helper arguments")
        sys.stdout.buffer.write(output)
        return 0
    except (SubmitError, OSError, smtplib.SMTPException, ssl.SSLError) as error:
        print(f"{label}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
