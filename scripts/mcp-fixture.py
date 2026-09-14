#!/usr/bin/env python3
"""Fixture MCP server and stdio driver for the idfon-mcp M1 acceptance test.

Two modes:

  server            a minimal newline-delimited JSON-RPC MCP server implementing
                    server/discover, tools/list, tools/call (echo), and
                    subscriptions/listen (acknowledged + one list_changed
                    notification, then idle)

  drive BIN PEER KEY  spawn `BIN connect --peer PEER --key-file KEY` and speak
                    MCP over its stdio, asserting the M1 acceptance checks

The server is a fixture, not a full spec implementation, but it follows the
2026-07-28 `_meta` rules (required per-request version/capabilities,
`serverInfo` under `_meta`, the `subscriptions/listen` acknowledgment) so the
tests exercise a conformant counterpart rather than a home-grown shape.
"""

import json
import os
import select
import subprocess
import sys
import time

PROTOCOL = "2026-07-28"
UNSUPPORTED_VERSION = -32022
INVALID_PARAMS = -32602

# Reserved `_meta` keys (MCP 2026-07-28, basic/index#_meta).
META_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"
META_SUBSCRIPTION_ID = "io.modelcontextprotocol/subscriptionId"


def client_meta():
    """The `_meta` every client request MUST carry."""
    return {
        META_VERSION: PROTOCOL,
        META_CLIENT_INFO: {"name": "idfon-fixture", "version": "0.1.0"},
        META_CLIENT_CAPABILITIES: {},
    }


def server_meta():
    return {META_SERVER_INFO: {"name": "idfon-mcp-fixture", "version": "0.1.0"}}


def meta_error(req, code, message, data=None):
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": req.get("id"), "error": error}


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
        if rid is None:
            # Notification; nothing to answer.
            continue
        meta = params.get("_meta") or {}
        # Missing required `_meta` is malformed; wrong version is -32022. Both
        # are the server's decision: the bridge only relays them.
        if META_VERSION not in meta or META_CLIENT_CAPABILITIES not in meta:
            send(
                meta_error(
                    req,
                    INVALID_PARAMS,
                    "missing required _meta fields (protocolVersion, clientCapabilities)",
                )
            )
            continue
        version = meta.get(META_VERSION)
        if version != PROTOCOL:
            send(
                meta_error(
                    req,
                    UNSUPPORTED_VERSION,
                    "Unsupported protocol version",
                    {"supported": [PROTOCOL], "requested": version},
                )
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
                        "_meta": server_meta(),
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
                        "_meta": server_meta(),
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
                        "_meta": server_meta(),
                    },
                }
            )
        elif method == "subscriptions/listen":
            # Streaming request. The server MUST acknowledge first, then it MAY
            # stream notifications the client asked for; all carry the
            # subscription id in `_meta`. Stay open (no result) until the peer
            # closes the stream.
            requested = params.get("notifications") or {}
            acknowledged = {k: requested[k] for k in ("toolsListChanged",) if requested.get(k)}
            send(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/subscriptions/acknowledged",
                    "params": {
                        "_meta": {META_SUBSCRIPTION_ID: rid},
                        "notifications": acknowledged,
                    },
                }
            )
            if requested.get("toolsListChanged"):
                send(
                    {
                        "jsonrpc": "2.0",
                        "method": "notifications/tools/list_changed",
                        "params": {"_meta": {META_SUBSCRIPTION_ID: rid}},
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
        params = obj.setdefault("params", {})
        params.setdefault("_meta", client_meta())
        proc.stdin.write((json.dumps(obj, separators=(",", ":")) + "\n").encode())
        proc.stdin.flush()
        line = reader.readline(timeout=15)
        if line is None:
            raise AssertionError(f"stream closed before replying to {obj.get('method')}")
        return json.loads(line)

    try:
        # server/discover (result identity lives under `_meta`).
        discover = request({"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {}})
        result = discover["result"]
        assert PROTOCOL in result["supportedVersions"], result
        assert result["resultType"] == "complete", result
        assert "tools" in result["capabilities"], result
        assert result["_meta"][META_SERVER_INFO]["name"] == "idfon-mcp-fixture", result

        # tools/list
        listing = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        names = [tool["name"] for tool in listing["result"]["tools"]]
        assert "echo" in names, names
        assert listing["result"]["_meta"][META_SERVER_INFO]["name"] == "idfon-mcp-fixture", listing

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

        # missing required `_meta` -> -32602, malformed
        malformed = request(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/list",
                "params": {"_meta": {}},
            }
        )
        assert malformed["error"]["code"] == INVALID_PARAMS, malformed

        # version mismatch -> relayed -32022 with the supported list
        mismatch = request(
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/list",
                "params": {
                    "_meta": {
                        META_VERSION: "1999-01-01",
                        META_CLIENT_CAPABILITIES: {},
                    }
                },
            }
        )
        assert mismatch["error"]["code"] == UNSUPPORTED_VERSION, mismatch
        assert mismatch["error"]["data"]["requested"] == "1999-01-01", mismatch
        assert PROTOCOL in mismatch["error"]["data"]["supported"], mismatch

        # subscriptions/listen — ack first, then a requested notification, both
        # tagged with the subscription id.
        proc.stdin.write(
            (
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 6,
                        "method": "subscriptions/listen",
                        "params": {
                            "_meta": client_meta(),
                            "notifications": {"toolsListChanged": True},
                        },
                    },
                    separators=(",", ":"),
                )
                + "\n"
            ).encode()
        )
        proc.stdin.flush()
        ack_line = reader.readline(timeout=15)
        assert ack_line is not None, "stream closed before the ack"
        ack = json.loads(ack_line)
        assert ack["method"] == "notifications/subscriptions/acknowledged", ack
        assert ack["params"]["_meta"][META_SUBSCRIPTION_ID] == 6, ack
        assert ack["params"]["notifications"]["toolsListChanged"] is True, ack
        notification_line = reader.readline(timeout=15)
        assert notification_line is not None, "stream closed before the notification"
        notification = json.loads(notification_line)
        assert notification["method"] == "notifications/tools/list_changed", notification
        assert notification["params"]["_meta"][META_SUBSCRIPTION_ID] == 6, notification

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
        params = obj.setdefault("params", {})
        params.setdefault("_meta", client_meta())
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
        assert discover["result"]["_meta"][META_SERVER_INFO]["name"] == "idfon-mcp-server", discover

        listing = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        names = [tool["name"] for tool in listing["result"]["tools"]]
        assert "idfon.put_blob" in names and "idfon.send_message" in names, names
        assert listing["result"]["_meta"][META_SERVER_INFO]["name"] == "idfon-mcp-server", listing

        # Conformance: missing required `_meta` -> -32602; wrong version -> -32022.
        malformed = request(
            {"jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": {"_meta": {}}}
        )
        assert malformed["error"]["code"] == INVALID_PARAMS, malformed
        mismatched = request(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/list",
                "params": {"_meta": {META_VERSION: "1999-01-01", META_CLIENT_CAPABILITIES: {}}},
            }
        )
        assert mismatched["error"]["code"] == UNSUPPORTED_VERSION, mismatched
        assert PROTOCOL in mismatched["error"]["data"]["supported"], mismatched

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