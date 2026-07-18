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
import socket
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
    parser.add_argument("--symbol-prefix")
    parser.add_argument("--symbol-file", default="symbols.fixture")
    parser.add_argument("--symbol-score-base", type=float)
    parser.add_argument("--workspace-symbol-delay-ms", type=int, default=0)
    parser.add_argument("--workspace-symbol-failure-query", default="explode")
    parser.add_argument("--tcp-port", type=int)
    parser.add_argument("--port-file", type=Path)
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
        symbol_prefix: str | None,
        symbol_file: str,
        symbol_score_base: float | None,
        workspace_symbol_delay_ms: int,
        workspace_symbol_failure_query: str,
    ) -> None:
        self.event_path = event_path
        self.initialize_delay = initialize_delay_ms / 1000
        self.shutdown_delay = shutdown_delay_ms / 1000
        self.shutdown_delay_ms = shutdown_delay_ms
        self.publish_diagnostics = publish_diagnostics
        self.symbol_prefix = symbol_prefix
        self.symbol_file = symbol_file
        self.symbol_score_base = symbol_score_base
        self.workspace_symbol_delay = workspace_symbol_delay_ms / 1000
        self.workspace_symbol_delay_ms = workspace_symbol_delay_ms
        self.workspace_symbol_failure_query = workspace_symbol_failure_query
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

    def progress_notification(
        self,
        kind: str,
        percentage: int | None = None,
        token: str = "fixture-index",
    ) -> dict[str, Any]:
        value: dict[str, Any] = {"kind": kind}
        if kind == "begin":
            value["title"] = "Indexing fixture"
            value["message"] = "Starting"
        elif kind == "report":
            value["message"] = "Scanning"
        elif kind == "end":
            value["message"] = "Finished"
        if percentage is not None:
            value["percentage"] = percentage
        return {
            "jsonrpc": "2.0",
            "method": "$/progress",
            "params": {"token": token, "value": value},
        }

    def error(
        self, request_id: object, code: int, message: str
    ) -> dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        }

    def workspace_symbols(self, query: str) -> list[dict[str, Any]]:
        target_uri = self.root_uri.rstrip("/") + "/" + self.symbol_file
        container = Path(self.root_path).name.replace("-", " ").title()
        folded_query = query.casefold()
        if "slowalpha" in folded_query:
            query_prefix = "Stale"
        elif "beta" in folded_query:
            query_prefix = "Beta"
        elif "explode" in folded_query:
            query_prefix = "Explode"
        else:
            query_prefix = "Alpha"
        prefix = f"{self.symbol_prefix or ''}{query_prefix}"
        symbols = [
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
        if self.symbol_score_base is not None:
            for offset, symbol in enumerate(symbols):
                symbol["score"] = self.symbol_score_base - offset
        return symbols

    def handle(self, message: dict[str, Any]) -> dict[str, Any] | None:
        method = message.get("method")
        params = message.get("params") or {}
        request_id = message.get("id")

        if method is None and request_id in {
            "fixture-progress-create",
            "fixture-progress-secondary-create",
        }:
            token = (
                "fixture-index"
                if request_id == "fixture-progress-create"
                else "fixture-secondary"
            )
            self.log(
                "PROGRESS_CREATE_RESPONSE",
                result=message.get("result"),
                token=token,
            )
            return self.progress_notification(
                "begin", 10 if token == "fixture-index" else 63, token
            )

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
                        "documentSymbolProvider": True,
                        "codeActionProvider": True,
                        "executeCommandProvider": {
                            "commands": ["lem-yath.fixture.apply"]
                        },
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
            self.log(
                "DID_OPEN",
                uri=uri,
                language_id=document.get("languageId", ""),
            )
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

        if method == "textDocument/documentSymbol":
            document = params.get("textDocument") or {}
            uri = str(document.get("uri") or "")
            self.log("DOCUMENT_SYMBOL", uri=uri)
            if uri.endswith("/two.fixture"):
                return self.response(
                    request_id,
                    [
                        {
                            "name": "LegacyMethod",
                            "kind": 6,
                            "location": {
                                "uri": uri,
                                "range": {
                                    "start": {"line": 0, "character": 0},
                                    "end": {"line": 0, "character": 3},
                                },
                            },
                            "containerName": "LegacyClass",
                        }
                    ],
                )
            return self.response(
                request_id,
                [
                    {
                        "name": "AlphaClass",
                        "kind": 5,
                        "range": {
                            "start": {"line": 39, "character": 0},
                            "end": {"line": 41, "character": 0},
                        },
                        "selectionRange": {
                            "start": {"line": 39, "character": 0},
                            "end": {"line": 39, "character": 10},
                        },
                        "children": [
                            {
                                "name": "AlphaMethod",
                                "kind": 6,
                                "range": {
                                    "start": {"line": 40, "character": 0},
                                    "end": {"line": 40, "character": 22},
                                },
                                "selectionRange": {
                                    "start": {"line": 40, "character": 4},
                                    "end": {"line": 40, "character": 15},
                                },
                            }
                        ],
                    }
                ],
            )

        if method == "textDocument/codeAction":
            document = params.get("textDocument") or {}
            action_range = params.get("range") or {}
            start = action_range.get("start") or {}
            end = action_range.get("end") or {}
            uri = str(document.get("uri") or "")
            self.log(
                "CODE_ACTION",
                uri=uri,
                start_line=start.get("line", ""),
                start_character=start.get("character", ""),
                end_line=end.get("line", ""),
                end_character=end.get("character", ""),
            )
            return self.response(
                request_id,
                [
                    {
                        "title": "Apply fixture action",
                        "kind": "quickfix",
                        "command": {
                            "title": "Apply fixture action",
                            "command": "lem-yath.fixture.apply",
                            "arguments": [uri],
                        },
                    }
                ],
            )

        if method == "workspace/executeCommand":
            command = str(params.get("command") or "")
            arguments = params.get("arguments") or []
            self.log(
                "EXECUTE_COMMAND",
                command=command,
                argument_count=len(arguments),
            )
            return self.response(request_id, None)

        if method == "workspace/symbol":
            query = str(params.get("query") or "")
            self.log("WORKSPACE_SYMBOL", query=query)
            if query == self.workspace_symbol_failure_query:
                return self.error(
                    request_id, -32001, "fixture workspace-symbol failure"
                )
            if query == "slowalpha":
                self.log("WORKSPACE_SYMBOL_DELAY", query=query, delay_ms=900)
                time.sleep(0.9)
            elif self.workspace_symbol_delay:
                self.log(
                    "WORKSPACE_SYMBOL_DELAY",
                    query=query,
                    delay_ms=self.workspace_symbol_delay_ms,
                )
                time.sleep(self.workspace_symbol_delay)
            return self.response(request_id, self.workspace_symbols(query))

        if method == "$/cancelRequest":
            self.log("CANCEL_REQUEST", request_id=params.get("id", ""))
            return None

        if method == "lem-yath/progressBegin":
            self.log("PROGRESS_TRIGGER", kind="begin")
            return {
                "jsonrpc": "2.0",
                "id": "fixture-progress-create",
                "method": "window/workDoneProgress/create",
                "params": {"token": "fixture-index"},
            }

        if method == "lem-yath/progressReport":
            self.log("PROGRESS_TRIGGER", kind="report")
            return self.progress_notification("report", 37)

        if method == "lem-yath/progressReportNoPercentage":
            self.log("PROGRESS_TRIGGER", kind="report-no-percentage")
            return self.progress_notification("report")

        if method == "lem-yath/progressSecondBegin":
            self.log("PROGRESS_TRIGGER", kind="second-begin")
            return {
                "jsonrpc": "2.0",
                "id": "fixture-progress-secondary-create",
                "method": "window/workDoneProgress/create",
                "params": {"token": "fixture-secondary"},
            }

        if method == "lem-yath/progressSecondEnd":
            self.log("PROGRESS_TRIGGER", kind="second-end")
            return self.progress_notification(
                "end", token="fixture-secondary"
            )

        if method == "lem-yath/progressEnd":
            self.log("PROGRESS_TRIGGER", kind="end")
            return self.progress_notification("end")

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

    def run(self, input_stream: BinaryIO, output_stream: BinaryIO) -> int:
        try:
            while True:
                message = read_message(input_stream)
                if message is None:
                    self.log("EOF")
                    return 0
                response = self.handle(message)
                if response is not None:
                    write_message(output_stream, response)
        except EOFError:
            return 0
        except Exception as error:
            self.log("SERVER_ERROR", detail=repr(error))
            return 1


def main() -> int:
    args = parse_args()
    server = FixtureServer(
        args.events,
        args.initialize_delay_ms,
        args.shutdown_delay_ms,
        args.publish_diagnostics,
        args.symbol_prefix,
        args.symbol_file,
        args.symbol_score_base,
        args.workspace_symbol_delay_ms,
        args.workspace_symbol_failure_query,
    )
    if args.tcp_port is None:
        return server.run(sys.stdin.buffer, sys.stdout.buffer)

    if args.port_file is None:
        raise SystemExit("--port-file is required with --tcp-port")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", args.tcp_port))
        listener.listen(1)
        args.port_file.write_text(
            f"{listener.getsockname()[1]}\n", encoding="ascii"
        )
        connection, _address = listener.accept()
        with connection:
            with connection.makefile("rb") as input_stream:
                with connection.makefile("wb") as output_stream:
                    return server.run(input_stream, output_stream)


if __name__ == "__main__":
    raise SystemExit(main())
