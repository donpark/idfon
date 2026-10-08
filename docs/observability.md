# Unified telemetry and the external-agent seam

How idfon can make triage tractable across many interacting decentralized
processes — daemon, CLI, GUIs, holder, bridge, MCP, and **third-party agents we
do not own** — without turning observability into a hard dependency on a hosted
service, and without shipping telemetry over the peer network.

> Status: **as-built**, 2026-10-05. P0 (shared subscriber + boundary wide
> events), P1 (correlation seam), and P2 (opt-in OTLP on the non-dylib
> binaries + `telemetry` capability) are implemented; §8 records the phases and
> §10 lists what is still open. Grounds every claim in the code as it stands.

## 1. Problem

A single logical flow — an A2A card request, a voice turn, a live call —
crosses several processes, and the fan-out is growing:

- `idfond` daemons (one per identity; in-process on iOS, `docs/daemon.md`),
- the macOS GUI's daemon subprocess and the CLI (which auto-spawns daemons),
- the `idfon-gateway` / `idfon-h3` HTTP/3 provider,
- `idfon-mcp` / `idfon-mcp-server`,
- the `eve-idfon` holder/bridge that fronts each agent,
- the JS agents themselves (`agents/*`), which may be written and hosted by
  someone else.

Today triage means hopping disjoint, unstructured logs:
`/tmp/idfon-<pid>.log` (GUI/FFI), `/tmp/idfon-holder-<pid>.log`,
`~/.idfon/<instance>/holder.log`, `bridge.log`, `agents/*/eve.log`. There is no
single correlation id joining those files, so "what led to this behavior?"
cannot be answered exactly. `docs/troubleshooting.md` documents this pain entry
by entry. P0–P2 below close most of that gap: one subscriber, one `trace` id,
and structured seam events.

## 2. What exists today

- **Logging is unified and structured.** Diagnostic output in the daemon,
  holder, MCP bridge, `idfon-core`, `idfon-voice`, and `idfon-voice-agent` now
  goes through `tracing` with named fields, tagged `idfon.daemon` /
  `idfon.holder` / `idfon.mcp` / `idfon.core` / `idfon.voice` /
  `idfon.voice.metrics`. The one shared subscriber lives in
  `crates/idfon-telemetry` and is installed by the daemon, CLI, holder, MCP
  bridge/server, and the FFI app entry point. `idfon-edge` runs its own
  subscriber and tags per-request logs `idfon.edge.access` (its counters are
  also served at `GET /metrics`). Residual `println!` are
  user-facing output contracts (CLI results, endpoint tickets), not logs.
- **Agent-side logs are structured too.** The node bridge scripts emit
  single-line JSON on stderr tagged `idfon.bridge` / `idfon.managed` /
  `idfon.live-relay`, and the Eve extension logs `idfon.agent`; the holder now
  passes `trace` on `turn.in`/`status.in`/`input.in` so agent logs join the
  trace. The native Swift apps log through an `IdfonLog` helper
  (`os.Logger`, subsystem `app.idfon`, category = source file), filterable with
  e.g. `log stream --predicate 'subsystem == "app.idfon"'`.
- **The correlation keys are carried.** The protocol has always carried
  `message_id`, `idempotency_key`, `operation_id`, and `in_reply_to`
  (`crates/idfon-protocol/src/lib.rs`, `crates/eve-idfon/src/lib.rs`), plus
  authenticated `peer_id` / `endpoint_id` on every crossing. The daemon mints a
  `trace` and the holder echoes it (P1), and every seam event is tagged with it,
  so one `trace` id joins the files above.
- **The seams are owned by us.** Every inbound crossing lands in a known
  handler on our side: `handle_message`, `handle_reply`, `handle_status`,
  `handle_input`, `handle_peer_send` (`crates/eve-idfon/src/lib.rs`), the MCP
  bridge over `idfon/mcp/1`, and the A2A `IDFON-*` envelopes.
- **We do not own the agents.** Third-party agents are opaque processes we
  cannot instrument. Any design that assumes otherwise is dead on arrival.

## 3. Principles

1. **Trace internal components fully; bracket external ones.** For code we own,
   spans, context propagation, and optional OTLP export are cheap and standard.
   For code we don't, we never see inside — we log the request we sent and the
   reply (or silence) we got, keyed by the contract ids already present. The
   black box becomes a labeled, timed edge instead of a hole.
2. **Offer, don't require.** Nothing about observability may be a precondition
   for an agent to work. A non-participating agent behaves exactly as today;
   we simply lose the interior and keep the boundary.
3. **Offline-first.** idfon is P2P and must work with no server. Telemetry
   export is opt-in and no-ops when unconfigured. Disk logs remain the local
   source of truth.
4. **The identity anchors trust, not the trace id.** A peer's self-asserted
   correlation/trace value is untrusted input. Trust continues to come from the
   authenticated `peer_id` / capability-ticket subject we already verify.

## 4. The seam contract

Two optional additions, both ignorable:

- **Correlation field.** An optional `trace` (W3C `traceparent` shape) on the
  message/call envelope and on the A2A `IDFON-*` payloads. When present, our
  spans continue the caller's trace; when absent, we mint one and the agent is
  a boundary edge.
- **Capability negotiation.** A `telemetry: none | correlate | inject` value
  carried on the message envelope and the A2A payload, so each side knows what
  the other will do and can degrade gracefully. The MCP bridge is a pure byte
  pump with no handshake, so it is not a negotiation point.

Participation has two levels, and both are offered because they unlock
different things:

| Level | What the agent does | What we get | Friction |
| --- | --- | --- | --- |
| `none` | nothing | boundary edge: sent-at, replied-at, latency, timeout | zero |
| `correlate` | echoes ids / `traceparent` | exact cross-process sequence + labeled agent edge | one field |
| `inject` | emits its own spans into the same trace/collector | the agent's interior sequence too | SDK/export |

Offering only `inject` yields few adopters; `correlate` carries most of the
triage value and is the on-ramp to `inject`.

## 5. Boundary wide event

The cheapest and most valuable unit is **one canonical wide event per boundary
crossing**, emitted on our side with no cooperation required. One structured
line at each handler above, carrying every id we already have: `message_id`,
`in_reply_to`, `conversation`, `call_id` / `turn_id`, `peer_id`, ticket
subject, direction, outcome, latency. This is the join key that makes any
distributed trace usable, and it works for every third party immediately.

"A reply was expected by T and did not arrive" is a first-class outcome, not a
gap. The events carry the ids and direction today; latency/outcome are only
partial (status is on the reply/status events, not a measured duration).

## 6. OTLP externalization (opt-in)

- `idfon-telemetry` has an `otlp` feature: with `IDFON_OTEL_ENDPOINT` set it
  adds an OTLP/HTTP batch span exporter, sampled at `IDFON_OTEL_SAMPLE_RATIO`
  (default `0.1`), and installs a `TraceContextPropagator` so W3C context from
  the envelope's `trace` becomes the span's remote parent. Unset ⇒ the layer is
  inert. Never a hard dependency on a reachable collector.
- The feature is enabled only by the non-dylib binaries (holder, MCP, CLI); the
  daemon dylib stays lean on mobile. Long-lived holder/MCP processes are the
  intended exporters; a short-lived CLI run may exit before the batch flushes,
  so treat the CLI as file-first even with an endpoint set.
- Self-host for dev:

  ```sh
  docker run --rm -p 4318:4318 otel/opentelemetry-collector:latest
  IDFON_OTEL_ENDPOINT=http://127.0.0.1:4318/v1/traces eve-idfon-voice ...
  ```

  Or run the scripted live check against a real collector (skips without
  docker): `./scripts/otel-e2e.sh` (also runs in the `observability` CI job).

  No SaaS, so the budget is a local container. Sample aggressively; never span
  per media frame or per datagram.
- A span is exported end to end (verified by an integration test that stands up
  a throwaway TCP collector). `idfon_telemetry::flush()` / `shutdown()` are
  called on a clean holder exit so the final batch is not lost.
- `inject`-level agent spans go straight to the collector from the agent;
  idfon does not ingest them, so cardinality is bounded by the collector and no
  extra trust is placed in them. Keep them distinguishable from idfon-observed
  spans (separate `service.name` / attributes) so a bad actor cannot forge
  causality in the unified view. This path is not yet exercised by a test.

## 7. Non-goals

- **No telemetry over iroh to peers.** Shipping OTEL over the peer network is
  self-blinding (it rides the exact network you're triaging), reinvents a worse
  collector (no retention/query/dedup), invites backpressure and forged input,
  and invents a transport third parties won't implement. iroh is only
  considered as a *transport to our own trusted collector* from a NATed node,
  and even then only if plain OTLP/HTTPS is blocked.
- **No OTEL SDK wired into every crate** as a prerequisite.
- **No requirement that third-party agents run our stack.**

## 8. Phasing

1. **P0 — internal spine (done 2026-10-05).** New leaf crate
   `idfon-telemetry` holds the one shared, idempotent subscriber (env filter
   `IDFON_LOG` > `RUST_LOG` > `IROH_C_LOG` > default; sink `IDFON_LOG_FILE` or
   stderr). Wired into the daemon, CLI, holder, MCP bridge/server, and the FFI
   app entry point; the holder dropped its `iroh-c-ffi` dependency. CLI-spawned
   daemon stderr is captured to `<data_dir>/idfond.log`. Boundary wide events
   (`target: "idfon.seam"`) are emitted at the `eve-idfon` message/reply/status/
   input/peer_send seams, and all diagnostic `eprintln!` across the daemon,
   holder, core, voice, voice-agent, and MCP bridge were converted to
   structured `tracing` fields (residual `println!` are stdout contracts).
2. **P1 — correlate (done 2026-10-05).** Optional `MessageEnvelope.trace`
   (unsigned W3C-traceparent shape, so attaching/echoing it never invalidates
   the sender's signature) and an optional `trace=` line on `IDFON-A2A/1`
   payloads. The daemon mints a trace per outbound flow (a caller-supplied
   `trace` param wins); the holder reads inbound traces, logs them on the seam
   events, and echoes them onto replies/status; the daemon logs them on receive.
   The `telemetry` capability is advertised (see P2); explicitly acting on a
   peer's advertised mode is still deferred (§10).
3. **P2 — inject + export (done 2026-10-05).** `idfon-telemetry` gains an
   optional `otlp` feature: `IDFON_OTEL_ENDPOINT` adds an OTLP/HTTP batch span
   exporter, sampled at `IDFON_OTEL_SAMPLE_RATIO` (default 0.1), with a
   `TraceContextPropagator` for W3C context and a provider kept alive for the
   process. The feature is enabled only by the non-dylib binaries (holder,
   MCP, CLI) so the daemon dylib stays lean on mobile. The inbound seam is
   instrumented with a span whose parent is the sender's `trace`
   (`set_remote_parent`). `telemetry` advertises this process's level via
   `idfon_telemetry::mode()` (`inject` when exporting, else `correlate`). An
   integration test proves a span reaches a collector; the holder flushes on
   clean shutdown. Inbound spans carry the caller's `trace` as parent; replies,
   status, input, and peer_send are instrumented on the outbound side, with the
   minted trace used both as the span root and the envelope `trace`. Daemon-side
   spans are intentionally omitted (the lean daemon does not export).

## 9. Trust, privacy, licensing

- Default off; explicit consent; no data leaves the device without it.
- Third-party agents may be proprietary/hosted and carry data-license
  constraints — keep the authoritative wide event on our side of the seam and
  do not require ingesting theirs.
- A hosted collector is control-plane infrastructure. Per the project's
  licensing decision it lives in the private tree, never the public repo.

## 10. Open questions

- Explicitly acting on a peer's advertised `telemetry` mode (today it is
  advertised and logged only; see the P2 gap above).
- Sampling policy for `inject`-level agent spans, and the cap on
  agent-reported cardinality.
- Whether the boundary wide event should also be JSON by sink, beyond the
  current `tracing` fmt output.

Decided in P1/P2: correlation rides `MessageEnvelope.trace` plus a `trace=`
line on `IDFON-A2A/1`; `telemetry` is per-message on the envelope.
