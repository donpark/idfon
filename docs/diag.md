# App diagnostics over iroh (`IDFON-DIAG/1`)

Design: GitHub issue #63. The 2026-10-23/24 wake saga showed the app's own
diagnostics are unreachable exactly when you need them: a locked phone needs a
Mac connection, and every question becomes an A/B guess. Iroh was the only
channel that worked all evening. Diagnostics now ride it.

## Protocol

`IDFON-DIAG/1\n{json}` in a `message.send` text to a monitor peer — same
envelope family as `IDFON-LIVE/1`/`IDFON-SESSION/1`
(`crates/idfon-protocol/src/diag.rs`). A report is
`{device, build, events: [{ts_ms, kind, detail}]}` with at most 64 events.
Cheap, async, best-effort, never on the call path. A failed send costs the
batch, never a call or a wake.

## App side

`Diag` (mac + iOS): a ring buffer flushed as one report. The monitor peer is
`-diagpeer <peerId>` at launch, else the saved one. Instrumentation today is
iOS-focused: PushKit token lifecycle, per-ref registration results (the 403
storm evidence), wake outcomes (presented / canceled / bar_owns / system_ring
/ reported_ring / bar_mode / skip_redelivery / skip_busy / skip_no_ids /
report_failed), and a launch config snapshot. Wake and registration flush
immediately — a woken process can die within ~1.5 s.

## Monitor side: the `monitor` agent

A plain Eve agent (`agents/monitor/`) that files reports and never minds:
the `file-diag` hook appends every report's events to
`~/.idfon/<agent>/diag/<device>.jsonl` (one JSON line per event; device and
build stamp attached), and reports get `<eve-empty-delivery/>` back — the app
sender is fire-and-forget. Any other message gets one line pointing at the
files.

```sh
scripts/monitor-serve.sh          # holder + bridge + eve, prints pairing
```

Point the app at it: `-diagpeer <holder-id>` plus the usual
`-pair-ticket` for the app's own capability ticket. A CLI send must attach
the ticket explicitly:

```sh
idfon send <holder-id> --text "IDFON-DIAG/1
{...}" --capability-ticket ~/.idfon/monitor/capability-ticket.json
```

Query is jq on the files — no new infra:

```sh
jq -c 'select(.kind == "wake")' ~/.idfon/monitor/diag/iphone.jsonl
```

Verified end-to-end 2026-10-27: daemon send → iroh → holder → bridge →
hook → filed events, with no reply delivered back.

## Open

- The filing agent's own rotation/retention (files grow unbounded today).
- Non-iOS instrumentation parity (the mac app only reports the config
  snapshot).
- A `monitor` query front-end if jq stops being enough.
