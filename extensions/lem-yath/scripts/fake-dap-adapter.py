#!/usr/bin/env python3
"""Deterministic stdio DAP adapter used by the installed-Lem acceptance gate."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, BinaryIO


INPUT: BinaryIO = sys.stdin.buffer
OUTPUT: BinaryIO = sys.stdout.buffer
SEQUENCE = 1
REPORT = Path(os.environ["LEM_YATH_DAP_ADAPTER_REPORT"])
SOURCE = os.environ["LEM_YATH_DAP_FILE"]


def read_exactly(length: int) -> bytes | None:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = INPUT.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_message() -> dict[str, Any] | None:
    headers: dict[str, str] = {}
    while True:
        line = INPUT.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers["content-length"])
    body = read_exactly(length)
    if body is None:
        return None
    return json.loads(body.decode("utf-8"))


def send(message: dict[str, Any], *, fragmented: bool = False) -> None:
    global SEQUENCE
    message.setdefault("seq", SEQUENCE)
    SEQUENCE += 1
    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
    frame = f"Content-Length: {len(body)}\r\n\r\n".encode() + body
    if fragmented and len(frame) > 11:
        OUTPUT.write(frame[:7])
        OUTPUT.flush()
        OUTPUT.write(frame[7:11])
        OUTPUT.flush()
        OUTPUT.write(frame[11:])
    else:
        OUTPUT.write(frame)
    OUTPUT.flush()


def response(request: dict[str, Any], body: dict[str, Any] | None = None) -> None:
    message: dict[str, Any] = {
        "type": "response",
        "request_seq": request["seq"],
        "success": True,
        "command": request["command"],
    }
    if body is not None:
        message["body"] = body
    send(message)


def event(name: str, body: dict[str, Any] | None = None, *, fragmented: bool = False) -> None:
    message: dict[str, Any] = {"type": "event", "event": name}
    if body is not None:
        message["body"] = body
    send(message, fragmented=fragmented)


def log_request(request: dict[str, Any]) -> None:
    with REPORT.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(request, ensure_ascii=False, sort_keys=True))
        stream.write("\n")


def stop(reason: str = "step", *, include_thread: bool = True) -> None:
    body: dict[str, Any] = {"reason": reason, "allThreadsStopped": True}
    if include_thread:
        body["threadId"] = 1
    event("stopped", body)


def breakpoint_response(request: dict[str, Any]) -> dict[str, Any]:
    requested = request.get("arguments", {}).get("breakpoints", [])
    base = 100 if request.get("command") == "setFunctionBreakpoints" else 10
    breakpoints = []
    for index, item in enumerate(requested):
        breakpoint = {
                "id": index + base,
                "verified": True,
                "message": "verified by λ adapter",
        }
        if "line" in item:
            breakpoint["line"] = item["line"]
        breakpoints.append(breakpoint)
    return {"breakpoints": breakpoints}


def main() -> int:
    while request := read_message():
        log_request(request)
        if request.get("type") == "response":
            continue
        command = request.get("command")
        if command == "initialize":
            response(
                request,
                {
                    "supportsConfigurationDoneRequest": True,
                    "supportsFunctionBreakpoints": True,
                    "supportsRestartFrame": True,
                    "supportsRestartRequest": True,
                    "supportsGotoTargetsRequest": True,
                    "supportsReadMemoryRequest": True,
                    "supportsDisassembleRequest": True,
                    "supportsTerminateRequest": True,
                    "supportsSteppingGranularity": True,
                    "exceptionBreakpointFilters": [
                        {"filter": "uncaught", "label": "Uncaught", "default": True},
                        {"filter": "raised", "label": "Raised", "default": False},
                    ],
                },
            )
        elif command in ("launch", "attach"):
            response(request)
            event("initialized", fragmented=True)
            event("initialized")
        elif command == "setBreakpoints":
            response(request, breakpoint_response(request))
        elif command == "setFunctionBreakpoints":
            response(request, breakpoint_response(request))
        elif command == "setExceptionBreakpoints":
            response(request, {"breakpoints": []})
        elif command == "configurationDone":
            response(request)
            send(
                {
                    "type": "request",
                    "command": "runInTerminal",
                    "arguments": {
                        "args": ["ignored"],
                        "argsCanBeInterpretedByShell": True,
                    },
                }
            )
            event(
                "breakpoint",
                {
                    "reason": "changed",
                    "breakpoint": {
                        "id": 100,
                        "verified": True,
                        "message": "function event from λ adapter",
                    },
                },
            )
            event("output", {"category": "stdout", "output": "hello λ debugger\n"}, fragmented=True)
            stop("breakpoint")
        elif command == "threads":
            response(request, {"threads": [{"id": 1, "name": "main λ"}]})
        elif command == "stackTrace":
            response(
                request,
                {
                    "stackFrames": [
                        {
                            "id": 101,
                            "name": "main",
                            "source": {"name": "main.py", "path": SOURCE},
                            "line": 3,
                            "column": 1,
                            "instructionPointerReference": "0x1000",
                        },
                        {
                            "id": 102,
                            "name": "caller",
                            "source": {"name": "main.py", "path": SOURCE},
                            "line": 1,
                            "column": 1,
                        },
                    ],
                    "totalFrames": 2,
                },
            )
        elif command == "scopes":
            response(
                request,
                {"scopes": [{"name": "Locals", "variablesReference": 100, "expensive": False}]},
            )
        elif command == "variables":
            response(
                request,
                {
                    "variables": [
                        {"name": "answer", "value": "42", "type": "int", "variablesReference": 0},
                        {"name": "greeting", "value": "λ", "type": "str", "variablesReference": 0},
                    ]
                },
            )
        elif command == "evaluate":
            expression = request.get("arguments", {}).get("expression", "")
            response(request, {"result": f"value({expression}) λ", "type": "str", "variablesReference": 0})
        elif command == "next":
            arguments = request.get("arguments", {})
            if arguments.get("granularity") != "line" or "singleThread" in arguments:
                send(
                    {
                        "type": "response",
                        "request_seq": request["seq"],
                        "success": False,
                        "command": command,
                        "message": "invalid optional stepping arguments",
                    }
                )
            else:
                event("continued", {"threadId": 1, "allThreadsContinued": True})
                stop(command)
                response(request, {"allThreadsContinued": True})
        elif command in ("continue", "stepIn", "stepOut", "restartFrame", "goto"):
            response(request, {"allThreadsContinued": True})
            event("continued", {"threadId": 1, "allThreadsContinued": True})
            stop(command)
        elif command == "pause":
            response(request)
            stop("pause")
        elif command == "restart":
            restart_arguments = request.get("arguments", {}).get("arguments")
            if isinstance(restart_arguments, dict):
                response(request)
                stop("restart", include_thread=False)
            else:
                send(
                    {
                        "type": "response",
                        "request_seq": request["seq"],
                        "success": False,
                        "command": command,
                        "message": "restart arguments were not wrapped",
                    }
                )
        elif command == "gotoTargets":
            response(request, {"targets": [{"id": 900, "label": "line target", "line": 4}]})
        elif command == "readMemory":
            response(request, {"address": "0x1000", "data": "AQIDBA==", "unreadableBytes": 0})
        elif command == "disassemble":
            response(
                request,
                {
                    "instructions": [
                        {"address": "0x1000", "instruction": "nop", "symbol": "main"},
                        {"address": "0x1001", "instruction": "ret"},
                    ]
                },
            )
        elif command == "terminate":
            response(request)
            event("terminated")
        elif command == "disconnect":
            response(request)
            return 0
        else:
            send(
                {
                    "type": "response",
                    "request_seq": request["seq"],
                    "success": False,
                    "command": command or "",
                    "message": f"unsupported test request: {command}",
                }
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
