#!/usr/bin/env python3
"""Credential-free stdio MCP fixture for fetch and dockerized GitHub paths."""

import json
import os
import pathlib
import sys
import time


server = "github" if "run" in sys.argv[1:] else "fetch"
log_dir = pathlib.Path(os.environ["HOME"]) / "mcp-test-log"
log_dir.mkdir(parents=True, exist_ok=True)

(log_dir / f"{server}.startup.json").write_text(
    json.dumps(
        {
            "argv": sys.argv[1:],
            "environment": sorted(os.environ),
            "github_token": os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN"),
            "toolsets": os.environ.get("GITHUB_TOOLSETS"),
            "read_only": os.environ.get("GITHUB_READ_ONLY"),
        }
    )
)


def record(message):
    with (log_dir / f"{server}.requests.jsonl").open("a") as stream:
        stream.write(json.dumps(message, separators=(",", ":")) + "\n")


def send(message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


def result(request_id, value):
    send({"jsonrpc": "2.0", "id": request_id, "result": value})


for line in sys.stdin:
    message = json.loads(line)
    record(message)
    method = message.get("method")
    request_id = message.get("id")

    if method == "initialize":
        send({"jsonrpc": "2.0", "id": f"{server}-ping", "method": "ping"})
        ping_response = json.loads(sys.stdin.readline())
        record(ping_response)
        assert ping_response == {
            "jsonrpc": "2.0",
            "id": f"{server}-ping",
            "result": {},
        }
        version = "2025-06-18" if server == "fetch" else "2025-11-25"
        result(
            request_id,
            {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": f"fake-{server}", "version": "1"},
            },
        )
    elif method == "notifications/initialized":
        continue
    elif method == "tools/list":
        cursor = (message.get("params") or {}).get("cursor")
        if server == "fetch" and cursor is None:
            result(
                request_id,
                {
                    "tools": [
                        {
                            "name": "fetch",
                            "description": "Fetch a URL without modifying it.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {"url": {"type": "string"}},
                                "required": ["url"],
                            },
                        }
                    ],
                    "nextCursor": "fetch-page-2",
                },
            )
        elif server == "fetch" and cursor == "fetch-page-2":
            result(
                request_id,
                {
                    "tools": [
                        {
                            "name": "fetch.headers",
                            "description": "Inspect response headers.",
                            "inputSchema": {"type": "object"},
                        }
                    ]
                },
            )
        elif server == "github":
            result(
                request_id,
                {
                    "tools": [
                        {
                            "name": "get_me",
                            "description": "Return the authenticated GitHub user.",
                            "inputSchema": {"type": "object"},
                            "annotations": {"readOnlyHint": True},
                        }
                    ]
                },
            )
        else:
            raise AssertionError(f"unexpected cursor: {cursor!r}")
    elif method == "tools/call":
        params = message["params"]
        arguments = params.get("arguments", {})
        if arguments.get("url") == "delay":
            time.sleep(30)
        if server == "fetch" and params["name"] == "fetch":
            result(
                request_id,
                {
                    "content": [
                        {"type": "text", "text": "FETCH-FIRST"},
                        {"type": "text", "text": "FETCH-SECOND"},
                    ],
                    "structuredContent": {"url": arguments.get("url")},
                    "isError": False,
                },
            )
        elif server == "fetch" and params["name"] == "fetch.headers":
            result(
                request_id,
                {
                    "content": [
                        {
                            "type": "resource_link",
                            "uri": "https://example.invalid/headers",
                            "name": "headers",
                        }
                    ]
                },
            )
        elif server == "github" and params["name"] == "get_me":
            result(
                request_id,
                {"content": [{"type": "text", "text": "GITHUB-READONLY"}]},
            )
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32602, "message": "unknown fixture tool"},
                }
            )
    else:
        send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "unknown fixture method"},
            }
        )
