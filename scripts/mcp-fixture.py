#!/usr/bin/env python3
"""Fixture MCP server and stdio driver for the idfon-mcp M1 acceptance test.

Two modes:

  server            a minimal newline-delimited JSON-RPC MCP server implementing
                    server/discover, tools/list, tools/call (echo), and
                    subscriptions/listen (one notification, then idle)

  drive BIN PEER KEY  spawn `BIN connect --peer PEER --key-file KEY` and speak
                    MCP over its stdio, asserting the M1 acceptance checks

The server is a fixture, not a spec implementation: the bridge under test is a
byte pump, so this only has to be MCP-shaped enough to prove framing.
"""

import json
import os
import select
import subprocess
import sys
import time

PROTOCOL = "2026-07-28"
UNSUPPORTED_VERSION = -32022


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def run_server():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        version = (params.get("_meta") or {}).get("protocolVersion")
        # Fixture policy: reject an explicit unsupported version on any request.
        # Version rejection is the server's job; the bridge only relays it.
        if version is not None and version != PROTOCOL:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "error": {
                        "code": UNSUPPORTED_VERSION,
                        "message": f"Unsupported protocol version: {version}",
                    },
                }
            )
            continue
        if method == "server/discover":
            send(
                {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "result": {
                        "resultType": "complete",
                        "supportedVersions": [PROTOCOL],
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "idfon-mcp-fixture", "version": "0.1.0"},
                    },
                }
            )
        elif method == "tools/list":
            send(
                {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "result": {
                        "resultType": "complete",
                        "tools": [
                            {
                                "name": "echo",
                                "description": "echo a string",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {"text": {"type": "string"}},
                                    "required": ["text"],
                                },
                            }
                        ],
                    },
                }
            )
        elif method == "tools/call":
            arguments = params.get("arguments") or {}
            send(
                {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "result": {
                        "resultType": "complete",
                        "content": [{"type": "text", "text": str(arguments.get("text", ""))}],
                    },
                }
            )
        elif method == "subscriptions/listen":
            # Streaming request: emit one notification and stay open (no
            # result) until the peer closes the stream.
            send(
                {
                    "jsonrpc": "2.0",
                    "method": "subscriptions/event",
                    "params": {"event": "ready"},
                }
            )
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "error": {"code": -32601, "message": f"Method not found: {method}"},
                }
            )


class LineReader:
    """Reads newline-delimited bytes from a non-blocking fd with a timeout."""

    def __init__(self, fd):
        self.fd = fd
        self.buffer = b""

    def readline(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for a line")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                raise TimeoutError("timed out waiting for a line")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                line, self.buffer = self.buffer, b""
                return line or None
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return line


def run_drive(connect_args):
    proc = subprocess.Popen(
        connect_args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        bufsize=0,
    )
    reader = LineReader(proc.stdout.fileno())

    def request(obj):
        proc.stdin.write((json.dumps(obj, separators=(",", ":")) + "\n").encode())
        proc.stdin.flush()
        line = reader.readline(timeout=15)
        if line is None:
            raise AssertionError(f"stream closed before replying to {obj.get('method')}")
        return json.loads(line)

    try:
        # server/discover
        discover = request({"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {}})
        result = discover["result"]
        assert PROTOCOL in result["supportedVersions"], result
        assert result["resultType"] == "complete", result
        assert "tools" in result["capabilities"], result

        # tools/list
        listing = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        names = [tool["name"] for tool in listing["result"]["tools"]]
        assert "echo" in names, names

        # tools/call — the payload carries an escaped newline and quote, so a
        # re-framing pump would split the line and this read would break.
        text = "line1\\nline2 \"quoted\" \\u00e9\\ttab"
        echoed = request(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "echo", "arguments": {"text": text}},
            }
        )
        assert echoed["result"]["content"][0]["text"] == text, echoed

        # version mismatch -> relayed -32022
        mismatch = request(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/list",
                "params": {"_meta": {"protocolVersion": "1999-01-01"}},
            }
        )
        assert mismatch["error"]["code"] == UNSUPPORTED_VERSION, mismatch

        # subscriptions/listen — notification arrives, then the stream closes.
        proc.stdin.write(
            (
                json.dumps(
                    {"jsonrpc": "2.0", "id": 5, "method": "subscriptions/listen", "params": {}},
                    separators=(",", ":"),
                )
                + "\n"
            ).encode()
        )
        proc.stdin.flush()
        notification_line = reader.readline(timeout=15)
        assert notification_line is not None, "stream closed before the notification"
        notification = json.loads(notification_line)
        assert notification.get("method") == "subscriptions/event", notification
        assert notification["params"]["event"] == "ready", notification

        proc.stdin.close()
        assert proc.wait(timeout=15) == 0, f"connect exited with {proc.returncode}"
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def run_server_drive(binary, socket):
    """Drive `idfon-mcp-server` (the M4 adapter) as an MCP client."""
    proc = subprocess.Popen(
        [binary, "--socket", socket],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        bufsize=0,
    )
    reader = LineReader(proc.stdout.fileno())

    def request(obj):
        proc.stdin.write((json.dumps(obj, separators=(",", ":")) + "\n").encode())
        proc.stdin.flush()
        line = reader.readline(timeout=15)
        if line is None:
            raise AssertionError(f"adapter closed before {obj.get('method')}")
        return json.loads(line)

    def call(name, arguments):
        response = request(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            }
        )
        assert "error" not in response, response
        result = response["result"]
        return result.get("isError", False), result["content"][0]["text"]

    try:
        discover = request({"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {}})
        assert PROTOCOL in discover["result"]["supportedVersions"], discover
        assert "tools" in discover["result"]["capabilities"], discover

        listing = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        names = [tool["name"] for tool in listing["result"]["tools"]]
        assert "idfon.put_blob" in names and "idfon.send_message" in names, names

        is_error, text = call("idfon.list_peers", {})
        assert not is_error and "bob" in text, text

        is_error, text = call("idfon.put_blob", {"text": "hello blob"})
        assert not is_error, text
        assert json.loads(text).get("blob_ticket"), text

        # Consent is the daemon's: bob is granted, carol is not.
        is_error, text = call("idfon.send_message", {"to": "carol", "text": "nope"})
        assert is_error and "capability" in text.lower(), text

        is_error, text = call("idfon.send_message", {"to": "bob", "text": "hi from mcp"})
        assert not is_error, text
        assert json.loads(text).get("operation_id"), text
    finally:
        if proc.stdin:
            proc.stdin.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "server":
        run_server()
    elif len(sys.argv) == 5 and sys.argv[1] == "drive":
        run_drive([sys.argv[2], "connect", "--peer", sys.argv[3], "--key-file", sys.argv[4]])
    elif len(sys.argv) == 4 and sys.argv[1] == "drive-uds":
        run_drive([sys.argv[2], "connect", "--uds", sys.argv[3]])
    elif len(sys.argv) == 4 and sys.argv[1] == "drive-server":
        run_server_drive(sys.argv[2], sys.argv[3])
    else:
        print(
            "usage: mcp-fixture.py server | drive BIN PEER KEY | drive-uds BIN SOCKET | drive-server BIN DAEMON_SOCKET",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    main()