#!/usr/bin/env python3
"""Small deterministic stdio language server for Lem lifecycle tests.

Protocol bytes are written only to stdout.  Human-readable events go to an
append-only file so stderr can remain empty and can never corrupt JSON-RPC.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import sys
import time
from typing import Any, BinaryIO
from urllib.parse import unquote, urlparse


class ProtocolError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--initialize-delay-ms", type=int, default=0)
    parser.add_argument("--shutdown-delay-ms", type=int, default=0)
    parser.add_argument("--publish-diagnostics", action="store_true")
    return parser.parse_args()


def read_message(stream: BinaryIO) -> dict[str, Any] | None:
    headers: dict[bytes, bytes] = {}
    while True:
        line = stream.readline()
        if line == b"":
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, separator, value = line.partition(b":")
        if not separator:
            raise ProtocolError(f"malformed header: {line!r}")
        headers[name.strip().lower()] = value.strip()

    try:
        length = int(headers[b"content-length"])
    except (KeyError, ValueError) as error:
        raise ProtocolError("missing or invalid Content-Length") from error

    body = stream.read(length)
    if len(body) != length:
        raise ProtocolError("truncated JSON-RPC body")
    value = json.loads(body.decode("utf-8"))
    if not isinstance(value, dict):
        raise ProtocolError("JSON-RPC message is not an object")
    return value


def write_message(stream: BinaryIO, value: dict[str, Any]) -> None:
    body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode(
        "utf-8"
    )
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    stream.write(body)
    stream.flush()


def uri_path(uri: str | None) -> str:
    if not uri:
        return ""
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        return uri
    return unquote(parsed.path)


class FixtureServer:
    def __init__(
        self,
        event_path: Path,
        initialize_delay_ms: int,
        shutdown_delay_ms: int,
        publish_diagnostics: bool,
    ) -> None:
        self.event_path = event_path
        self.initialize_delay = initialize_delay_ms / 1000
        self.shutdown_delay = shutdown_delay_ms / 1000
        self.shutdown_delay_ms = shutdown_delay_ms
        self.publish_diagnostics = publish_diagnostics
        self.pid = os.getpid()
        self.root_uri = ""
        self.root_path = ""
        self.log("START", cwd=os.getcwd())

    def log(self, event: str, **fields: object) -> None:
        self.event_path.parent.mkdir(parents=True, exist_ok=True)
        parts = [event, f"pid={self.pid}"]
        if self.root_path:
            parts.append(f"root_path={self.root_path}")
        for key, value in fields.items():
            clean = str(value).replace("\t", "\\t").replace("\n", "\\n")
            parts.append(f"{key}={clean}")
        line = "\t".join(parts) + "\n"
        with self.event_path.open("a", encoding="utf-8") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            stream.write(line)
            stream.flush()
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)

    def response(self, request_id: object, result: object) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    def error(
        self, request_id: object, code: int, message: str
    ) -> dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        }

    def workspace_symbols(self, query: str) -> list[dict[str, Any]]:
        target_uri = self.root_uri.rstrip("/") + "/symbols.fixture"
        container = Path(self.root_path).name.replace("-", " ").title()
        prefix = "Beta" if "beta" in query.casefold() else "Alpha"
        return [
            {
                "name": f"{prefix}Symbol",
                "kind": 12,
                "location": {
                    "uri": target_uri,
                    "range": {
                        "start": {"line": 2, "character": 4},
                        "end": {"line": 2, "character": 15},
                    },
                },
                "containerName": container,
            },
            {
                "name": f"{prefix}Constant",
                "kind": 14,
                "location": {
                    "uri": target_uri,
                    "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 8},
                    },
                },
                "containerName": container,
            },
        ]

    def handle(self, message: dict[str, Any]) -> dict[str, Any] | None:
        method = message.get("method")
        params = message.get("params") or {}
        request_id = message.get("id")

        if method == "initialize":
            self.root_uri = str(params.get("rootUri") or "")
            self.root_path = uri_path(self.root_uri)
            self.log("INITIALIZE", root_uri=self.root_uri)
            if self.initialize_delay:
                time.sleep(self.initialize_delay)
            return self.response(
                request_id,
                {
                    "capabilities": {
                        "positionEncoding": "utf-16",
                        "textDocumentSync": {
                            "openClose": True,
                            "change": 1,
                            "save": True,
                        },
                        "workspaceSymbolProvider": True,
                    },
                    "serverInfo": {"name": "lem-yath-fixture", "version": "1"},
                },
            )

        if method == "initialized":
            self.log("INITIALIZED")
            return None

        if method == "textDocument/didOpen":
            document = params.get("textDocument") or {}
            uri = str(document.get("uri") or "")
            self.log("DID_OPEN", uri=uri)
            if self.publish_diagnostics:
                self.log("PUBLISH_DIAGNOSTICS", uri=uri)
                return {
                    "jsonrpc": "2.0",
                    "method": "textDocument/publishDiagnostics",
                    "params": {
                        "uri": uri,
                        "diagnostics": [
                            {
                                "range": {
                                    "start": {"line": 0, "character": 0},
                                    "end": {"line": 0, "character": 1},
                                },
                                "severity": 1,
                                "source": "lem-yath-fixture",
                                "message": "fixture diagnostic",
                            }
                        ],
                    },
                }
            return None

        if method == "textDocument/didClose":
            document = params.get("textDocument") or {}
            self.log("DID_CLOSE", uri=document.get("uri", ""))
            return None

        if method == "textDocument/didSave":
            document = params.get("textDocument") or {}
            self.log("DID_SAVE", uri=document.get("uri", ""))
            return None

        if method == "textDocument/didChange":
            document = params.get("textDocument") or {}
            self.log("DID_CHANGE", uri=document.get("uri", ""))
            return None

        if method == "workspace/symbol":
            query = str(params.get("query") or "")
            self.log("WORKSPACE_SYMBOL", query=query)
            if query == "explode":
                return self.error(
                    request_id, -32001, "fixture workspace-symbol failure"
                )
            return self.response(request_id, self.workspace_symbols(query))

        if method == "shutdown":
            self.log("SHUTDOWN", delay_ms=self.shutdown_delay_ms)
            if self.shutdown_delay:
                time.sleep(self.shutdown_delay)
            return self.response(request_id, None)

        if method == "exit":
            self.log("EXIT")
            raise EOFError

        if method and request_id is not None:
            self.log("UNKNOWN_REQUEST", method=method)
            return self.response(request_id, None)

        if method:
            self.log("NOTIFICATION", method=method)
        return None

    def run(self) -> int:
        try:
            while True:
                message = read_message(sys.stdin.buffer)
                if message is None:
                    self.log("EOF")
                    return 0
                response = self.handle(message)
                if response is not None:
                    write_message(sys.stdout.buffer, response)
        except EOFError:
            return 0
        except Exception as error:
            self.log("SERVER_ERROR", detail=repr(error))
            return 1


def main() -> int:
    args = parse_args()
    return FixtureServer(
        args.events,
        args.initialize_delay_ms,
        args.shutdown_delay_ms,
        args.publish_diagnostics,
    ).run()


if __name__ == "__main__":
    raise SystemExit(main())
