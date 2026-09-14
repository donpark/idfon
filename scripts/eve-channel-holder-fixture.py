#!/usr/bin/env python3
"""Small M1 IPC consumer: turn.in -> reply.out."""

import json
import socket
import struct
import sys


def recv_exact(stream, size):
    payload = bytearray()
    while len(payload) < size:
        chunk = stream.recv(size - len(payload))
        if not chunk:
            raise RuntimeError("truncated IPC frame")
        payload.extend(chunk)
    return bytes(payload)


def read_frame(stream):
    header = recv_exact(stream, 4)
    size = struct.unpack("<I", header)[0]
    return json.loads(recv_exact(stream, size))


def write_frame(stream, frame):
    payload = json.dumps(frame, separators=(",", ":")).encode()
    stream.sendall(struct.pack("<I", len(payload)) + payload)


sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
with sock:
    turn = read_frame(sock)
    assert turn["type"] == "turn.in", turn
    assert turn["peer_id"] == sys.argv[2], turn
    write_frame(
        sock,
        {
            "type": "reply.out",
            "in_reply_to": turn["message_id"],
            "text": "reply from eve holder",
        },
    )
    ack = read_frame(sock)
    assert ack["type"] == "reply.ack", ack
    print(json.dumps({"turn": turn, "ack": ack}))
