#!/usr/bin/env python3
"""TYGER EARS sidecar: the real turn-taker as a child process (docs/voice-tyger.md, Shape 2).

Runs the `nineninesix/tyger` bundle through tyger-s2s's own ReferenceEars (their
scripts/validate/reference.py — same rules.py as the live engine) on the CPU, and
serves decisions over stdio as JSON lines. The relay (tyger-relay.mjs) is MOUTH:
it feeds the caller's mic and what the caller was hearing (the model's second ear),
and acts on the decisions.

    -> {"op": "open", "thresholds": {"ep_thr": 0.91, ...}}
    <- {"ok": true}
    -> {"op": "feed", "mode": "listen"|"speaking",
        "user": "<b64 i16le 16 kHz mono, 320 ms>", "agent": "<same>"}
    <- {"ok": true, "events": [ {"kind": "ENDPOINT", "transcript": ..., ...}, ... ]}
    -> {"op": "close"}
    <- {"ok": true}

Also `--listen <port>`: the same JSON-lines protocol over a TCP socket instead of stdio,
so the sidecar can run on a GPU box while the relay stays beside the bridge
(`TYGER_EARS_CMD=tcp://host:port`). Events are rules.py's (FRAME noise dropped):
PARTIAL, ENDPOINT (transcript filled), BARGE (onset_s), BACKCHANNEL (partial hint).
`mode` is the app's floor state — the model is never asked to guess it. Env: TYGER_S2S
(tyger-s2s clone), TYGER_BUNDLE.
"""
import base64
import json
import os
import socket
import sys

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))

import numpy as np  # noqa: E402
import torch  # noqa: E402

from app.plugins.ears.tyger.session import EarsSession  # noqa: E402
from validate.reference import ReferenceEars  # noqa: E402

KNOWN = {k for k in EarsSession.__init__.__code__.co_varnames[1:] if k != "self"}


def pcm(b64):
    return np.frombuffer(base64.b64decode(b64), "<i2").astype(np.float32) / 32768.0


def serve(rline, send):
    torch.set_num_threads(os.cpu_count() or 8)
    # mps: Apple GPU, real-time on M-series (~222 ms/hop vs ~730 on cpu); cpu is the fallback.
    ears = ReferenceEars(os.environ["TYGER_BUNDLE"], device=os.environ.get("TYGER_EARS_DEVICE", "cpu"))
    sess = None
    for line in rline:
        req = json.loads(line)
        op = req.get("op")
        if op == "open":
            thresholds = {k: v for k, v in (req.get("thresholds") or {}).items() if k in KNOWN}
            sess = EarsSession(0, **thresholds)
            send({"ok": True})
        elif op == "feed":
            events = [e for e in ears.feed(sess, pcm(req["user"]), pcm(req["agent"]), req["mode"]) if e["kind"] != "FRAME"]
            send({"ok": True, "events": events})
        elif op == "close":
            send({"ok": True})
            return
        else:
            send({"ok": False, "error": f"unknown op {op!r}"})


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--listen":
        port = int(sys.argv[2])
        with socket.create_server(("127.0.0.1", port)) as server:
            print(json.dumps({"listening": port}), flush=True)
            conn, _ = server.accept()  # one sidecar, one relay
            rfile = conn.makefile("r")
            send = lambda m: (conn.sendall((json.dumps(m) + "\n").encode()))  # noqa: E731
            serve(rfile, send)
        return
    send = lambda m: (print(json.dumps(m), flush=True))  # noqa: E731
    serve(sys.stdin, send)


if __name__ == "__main__":
    main()
