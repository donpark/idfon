# Media adaptation: measurement + network adaptation for live calls

Why: MVP focus is human↔human calls, where robustness of the audio/video streams
comes first, then quality. Two capabilities are missing:

1. **Measure and track** reliability/quality of live audio and video streams.
2. **Adapt** to changing network conditions (Wi-Fi↔cellular transitions,
   congestion): scale video down (720p→480p→360p, fullscreen→square), use Opus's
   responsive-bandwidth features, and automatically shed video when audio is
   breaking up.

Part A is the field knowledge (how modern VoIP does this); part B is our stack
reviewed against it; part C is the prioritized test/change list.

Cross-cutting requirement (B2): media configuration must be **dynamic and
demand-based** — quality *and form* reconfigured during a call from network
condition and application needs, not fixed at call start.

## A. How modern VoIP handles this

### A1. The signals everybody measures

- **Round-trip time + min RTT**: only the *difference* between current RTT and
  the idle-path minimum means "queueing". Absolute RTT is propagation + queue.
- **Loss rate and loss *bursts***: isolated loss and a 300 ms burst are the same
  average and a completely different user experience. RFC 3611 (RTCP-XR) burst/
  gap loss metrics exist exactly for this: burst/gap densities and durations.
- **Jitter** (RFC 3550 interarrival jitter) and, more useful, **arrival
  histogram percentiles** — jitter buffers size to a percentile, not a mean.
- **Goodput / throughput estimate** — what actually arrived vs what could flow.
- **Freeze/underrun events** — frames not rendered in time (video), audio
  buffer underruns (WebRTC `concealedSamples`, `jitterBufferDelay`,
  `freezeCount`, `pauseCount`, `framesDropped` in `getStats()`).
- **MOS / R-factor** (ITU-T G.107 E-model) as the summary score that folds
  latency, loss burstiness and codec together. Benchmarks for humans:
  ITU-T G.114 (one-way): 0–150 ms acceptable for most applications, 150–400 ms
  acceptable with growing impact, > 400 ms unacceptable; jitter < 30 ms;
  loss < 1 %.

### A2. Audio: Opus features for responsive bandwidth

- **Adaptive bitrate** (ABR): encoder target bitrate driven by a bandwidth
  estimate. In WebRTC this is REMB/TWCC feedback → GCC → `setParameters({maxBitrate})`.
  Speech stays intelligible down to ~6–8 kbps (narrowband), so audio can always
  be squeezed before it is dropped.
- **In-band FEC** (Opus SILK LBRR, RFC 6716): each packet carries a copy of the
  previous packet's low-bitrate encoding. On a single loss, the decoder
  reconstructs from the *next* packet (one packet delay, no retransmit). Huge
  win on Wi-Fi burst loss; costs ~20–30 % bitrate at equal quality.
- **DTX + comfort noise**: Opus goes near-silent during pauses (callers talk
  ~40–60 % of the time). Saves that fraction of bandwidth for video.
- **PLC** (packet loss concealment): every Opus decoder does it — conceal short
  gaps, never emit clicks/silence at a gap boundary.
- **RED** (RFC 2198, "opus-red" in WebRTC): wrap the last 1–2 packets as
  redundancy in the next one. Similar purpose to FEC, works across codecs.
- **Jitter buffer** (the classic NetEQ design): adaptive target delay from
  measured arrival jitter; merges buffer + PLC + time-compression/expansion
  (accelerate/decelerate playout to keep the buffer on target) + comfort noise.
  The buffer should *shrink* on good paths (latency!) and *grow* on bad ones.
- **20 ms frames** default; 40–60 ms frames when bandwidth-bound (fewer packet
  headers, more coding efficiency), at the cost of loss granularity.

### A3. Video: degrade resolution before it breaks

- **Simulcast / SVC**: the sender encodes 2–3 renditions (or one scalable
  stream); the receiver or an SFU switches rungs. WebRTC does simulcast
  (3 encodings), SVC (VP9/AV1 spatial + temporal layers), and "quality scaling"
  (encoder drops internal resolution/framerate on its own).
- **Degradation preference**: `maintain-framerate` (drop resolution first) vs
  `maintain-resolution` (drop fps first) vs balanced. FaceTime/Zoom-style
  behavior on bad links: lower resolution and fps gradually, never stall.
- **Recovery**: keyframe requests (PLI/FIR) after loss, NACK+RTX retransmission
  for reference frames only, "skip frame" instead of queueing up.
- **Shed video before audio**: when the estimate can't carry audio + minimal
  video, the policy in production systems (FaceTime, WhatsApp, Teams) is to
  drop the video stream entirely — audio is the call. Reverse when conditions
  recover (often *not* automatic — most apps wait for the user).
- **A/V sync**: lip-sync via common timestamps; video late by more than a
  frame budget is dropped, not delayed.

### A4. Congestion control

- **Delay-based first**: GCC (Google Congestion Control — the WebRTC default,
  hybrid delay + loss), SCReAM (RFC 8298, designed for video), NADA (RFC 8698).
  Delay-based controllers back off on *queue build-up* before loss appears.
- **Pacing**: send smoothed, never in bursts (bursts create loss on Wi-Fi and
  cellular uplinks even at the right average rate).
- **Priority**: under congestion, allocate to audio first, then base video
  layer, then enhancement layers. MoQ formalizes this as object priorities +
  "newest wins" delivery (drop stale objects rather than queue them).
- The controller runs at the *sender*; the receiver's contribution is
  feedback (loss, arrival times, RTT). On a one-way-saturated link the
  receiver can only see: bytes arriving (goodput), RTT inflation through the
  ACK path, and ACK loss as a proxy for path loss.

### A5. Wi-Fi ↔ cellular and cell-to-cell transitions

The core problem: an IP address change kills the 5-tuple.

- **TCP flows die**; **UDP flows die** unless the protocol handles migration.
- **WebRTC/ICE**: has no migration — recovery is an **ICE restart**
  (renegotiation + new candidate gathering + connectivity checks), seconds of
  media outage, and it needs the signaling channel to survive. Keepalives
  (STUN, 15–30 s) keep NAT bindings alive but do not help when the address
  changes.
- **QUIC** built connection migration in from day one: connection IDs decouple
  the connection from the 5-tuple; a new path is validated with
  PATH_CHALLENGE/PATH_RESPONSE and the connection continues on it.
  Multipath QUIC (draft-ietf-quic-multipath) runs both paths at once — the
  make-before-break ideal for Wi-Fi→cellular handoff.
- **Apple platform**: `NWPathMonitor`/`pathUpdateHandler` reports interface
  changes *before* traffic fails; `NWConnection.multipathServiceType`
  (`.interactive`) gives MPTCP for TCP flows. UDP apps must react themselves:
  pre-emptively rebind or migrate when `NWPathMonitor` says the interface
  changed. iOS "WiFi Assist" makes the switch *sudden and unilateral*.
- **Relay fallback**: when direct paths die mid-call, a relay path (TURN in
  WebRTC, iroh relays here) should take over without tearing the call down.
- **Cell-to-cell** (tower handoff, CGNAT rebind): usually the address survives
  but latency and loss spike for 1–3 s and MTU can change. The right response
  is congestion-control backoff + jitter-buffer growth, *not* a reconnect.
- Production apps also **duplicate critical packets** across paths during
  handoff (e.g. MPTCP DAPS — duplicate data ACK per path, RFC 8684) and
  **pre-warm** the target path (e.g. FaceTime's multipath, WhatsApp's calls).

## B. Our stack today (reviewed)

Transport is **MoQ (media over QUIC) over iroh 1.4** (moq crates via
`Frando/moq` `iroh-live-3` + `n0-computer/iroh-live` de7f43b). The media plane
is `crates/idfon-live-media` (call plumbing), `crates/iroh-c-ffi/src/media.rs`
(shell capture adapter), `src/video.rs` (video receive), and
`crates/idfon-media` (headless test harness).

### What already exists (better than expected)

- **Path-aware transport**: iroh 1.x connections expose `conn.paths()` with a
  selected path, `is_relay()` distinction and per-path stats. Path migration
  (direct↔relay, address change) is a transport capability, and
  `iroh-live/src/util.rs` folds it into `NetworkSignals` (rtt, `min_rtt`
  *per path id*, `rtt_samples`, `loss_rate`, `goodput_bps`, `delivery_bps` —
  the publisher's own capacity estimate carried on the wire —,
  `congestion_events`) with correct freshness semantics.
- **Receiver rendition adaptation**: `moq-media/src/adaptive.rs` (1661 lines)
  is a real ladder controller — sustained-hold downgrade on loss/queueing/
  goodput-ratio, emergency drop-to-lowest on loss spikes, upgrade probes with
  cooldowns, rtt-baseline-per-path so a relay fallback doesn't read as a
  permanent queue. Wired in `iroh-c-ffi/src/video.rs:232`
  (`track.enable_adaptation(subscription.signals().clone())`).
- **Opus knobs exist in moq-audio**: `encode::Options` has `bitrate`, `fec`,
  `dtx`, `frame_duration` (2.5–60 ms).
- **Audio playout**: `PacedPlayback` (crates/idfon-media/src/seam.rs) —
  50 ms prebuffer after startup/underrun, 20 ms pacing chunks, drop-oldest
  back to 50 ms above a 250 ms ceiling (anti-bloat), plus a sink-side
  ~50 ms device buffer and target-latency trimming.
- **Measurement hooks, headless**: `ListenStats` (idfon-media/src/live.rs) —
  startup_ms, arrival_jitter_ms (stddev of intervals), max_gap_ms,
  stalls_over_100ms, missing_packets (pts holes), prebuffer_ms — and the
  per-frame timing CSV in media.rs (`frame,arrival_us,...,sink_buffered_ms`).
  Bench harnesses exist (`docs/benchmarks.md`, `scripts/relay-bench.sh`,
  `scripts/voice-latency-report.sh`).

### Gaps against the goals

1. **Video has a ladder mechanism but no ladder.** Live calls publish a single
   rendition (`iroh-c-ffi/src/media.rs:399`, `vec![VideoRendition::new("video")]`,
   fixed 720x1280 RGBA pushed from the shell). The 180p/360p/720p simulcast
   ladder exists only on the *file* publish path (crates/idfon-media/src/video.rs).
   `enable_adaptation` with one rendition can only choose that one — the
   user-visible 720p→480p→360p (or fullscreen→square) degradation does not
   exist yet for calls.
2. **Opus FEC/DTX off, bitrate static.** `AudioOptions::default()` =
   `fec: false, dtx: false`; bitrate is a process-global `BITRATE` const
   (32 kbps/channel) set only manually (`media_audio_set_bitrate`). No
   feedback-driven audio ABR even though `NetworkSignals.delivery_bps` /
   `goodput_bps` are sitting right there.
3. **No persistent quality tracking.** The counters (`AUDIO_QUEUE_UNDERRUN_SAMPLES`,
   `VIDEO_FRAMES_CONSUMED`, ListenStats) go to `eprintln!` logs or headless
   harness runs. Nothing per-call is recorded (telemetry crate exists:
   `docs/observability.md`), no trend over time, no way to answer "did calls
   get better/worse this release". `Diag` (`docs/diag.md`) could carry a
   per-call quality summary.
4. **Wi-Fi→cellular breakage is reproduced but not diagnosed.** The user sees
   audio/video breakup and freeze after the transition. Candidate causes:
   (a) path switchover latency or failure in iroh on interface loss (no new
   direct candidates; relay path must take over);
   (b) media-layer stall that never recovers: MoQ on QUIC streams
   head-of-line-blocks behind the gap and the receive side re-prebuffers 50 ms
   then plays the backlog late (only partly mitigated by drop-oldest);
   (c) RTT-baseline/path switch confusing adaptation. Unknown which.
5. **No app-level network awareness.** No `NWPathMonitor` anywhere in ios/ or
   mac/ — we learn about interface changes only after media breaks. Modern
   apps pre-adapt (shrink video, grow jitter buffer) on the *notification*.
6. **No shedding policy.** Nothing turns video off automatically to rescue
   audio (the FaceTime rule), and nothing turns it back on.
7. **Jitter buffer target is fixed** (50 ms) instead of adaptive to measured
   jitter; fine on clean LAN, wrong on cellular.
8. **No burst/gap loss metric** — `arrival_jitter_ms` + `stalls_over_100ms`
   are the right shape but not tracked per call; nothing computes an R-factor/
   MOS-like summary.

## B2. Dynamic media configuration (quality and form)

Modern clients do not configure a call once; they hold a **media profile** that
both drivers below can move at any time mid-call:

- **Network condition** (N): the adaptation loop of A3/A4 — bitrate, fps,
  resolution rung, jitter-buffer target, video on/off.
- **Application need** (A): what the call *is* right now — audio call (waveform,
  no video), video call (bar → fullscreen), watch-together (receive-side video
  priority), stereo vs mono (media quality: music vs speech), agent/voice-agent
  calls (latency-first, no video), voice messages (offline, higher quality
  tolerated). The app decides the *form* it wants and the ceiling it is willing
  to pay for; the network loop picks within that.

Importantly, **the reconfiguration mechanism already exists** — this is the
same division of labor as WebRTC (`getStats`/`setParameters`/simulcast), done
at the MoQ layer (verified in the vendored `Frando/moq` `iroh-live-3` +
`n0-computer/iroh-live` de7f43b sources):

- The catalog is **dynamic mid-call**: `RemoteBroadcast` watches it
  (`Watchable<CatalogSnapshot>`); renditions can appear/change mid-session and
  the subscriber follows; the publisher can add/update tracks.
- **Video quality adaptation is done**: `VideoTrack::enable_adaptation`
  follows `NetworkSignals` with hysteresis (holds, cooldowns, probes,
  emergency drop-to-lowest), plus explicit `requested()`/`switched_to()`
  control and `enable_adaptation_with` for custom thresholds.
- **Audio is reconfigurable mid-stream**: `Producer::set_bitrate()` (Opus
  target while streaming), `fec`/`dtx`/`frame_duration` knobs.
- **Form/stream toggles** exist at our FFI (`media_live_set_audio_enabled`,
  `media_live_set_video_enabled`, `media_audio_set_bitrate`).

Do not build a new reconfiguration mechanism. The missing piece is the
**policy layer** — who moves which knob when — shaped like this:

1. **One profile state per call leg** (thin, no new apply path): video rung/
   fps/aspect (fullscreen→square→bar), audio bitrate/channels/frame duration,
   FEC/DTX, video on/off, jitter target. It *records* what the existing knobs
   were last set to and what the demand allows; the existing setters and
   `enable_adaptation` remain the only things that touch the media plane.
2. **Negotiation in the control plane**: `IDFON-LIVE/1` carries profile fields
   at invite today (codec, sample rate, stt/tts, sides); mid-call updates need
   the same envelope extended with `action=update` for wire-visible fields
   (form changes like fullscreen→square are receiver-local and need no wire
   change; stream additions/removals already exist as enable/disable).
3. **Convergence, not oscillation**: every automated change gets hysteresis
   (hold, cooldown, probe — already the adaptive.rs vocabulary) and every
   change — human or automatic — lands in the per-call quality record (C1) as
   an event with its trigger, so a bad call can be replayed.
4. **Degradation order is policy, applied by one state machine**: quality
   (bitrate/fps/rung) → form (aspect/layout) → channels (stereo→mono) →
   stream (video off) → codec mode (narrowband). Restore in reverse on
   sustained recovery. Application need sets where in this order the call is
   allowed to start and how far it may fall. Note the two adaptation loops
   must not fight: the video rendition loop (`adaptive.rs`) is autonomous
   within its rungs; the policy layer orders rung *ranges*, video on/off and
   the audio knobs.
   **The stereo step flips FEC**: stereo on = quality mode (FEC off, the
   stereo image is worth the bytes); auto stereo-off = resilience mode (FEC
   on: with mono there is no channel coupling to corrupt, and the measured
   recovery win is mono speech). So "turn off stereo" doubles as "turn on
   recovery", one step on the way down and the reverse on the way up.
   **Simulated stereo keeps the ear wide on a mono wire** (user idea,
   2026-10-28): the stereo step's middle rung transmits mono (FEC-safe,
   halves the bitrate) and the shell re-synthesizes the image at playback —
   Apple's 3D audio support (`AVAudioEnvironmentNode` listener/source
   positions, or a cheap Haas/decorrelation widener) with well-known spatial
   offsets. Receiver-local presentation, zero wire change, lives on the
   playback-bus seam like the form changes. Ladder: stereo → simulated
   stereo (mono payload + spatial render) → mono flat. **Battery is a gate,
   not an afterthought**: default to the cheap widener (a few delays and
   filters, negligible cost); the full `AVAudioEnvironmentNode` path, and
   head-tracked Spatial Audio especially, only if a battery measurement
   clears it — otherwise the rung degrades to plain mono rather than drain
   the phone. Caveats: the directionality is synthesized (not the real
   capture image), and the AEC echo reference must match the *rendered*
   output or the spatialization tails leak into the residual echo.

This subsumes the one-off adaptation items below: C4 (rendition ladder) is the
network-side rung mechanism, C7 (auto video-off) is one policy rule over the
profile, C8 (jitter target) is a profile field, C9 (NWPathMonitor) is just
another trigger.

### B2.1 Tie-in: LL-HLS (soon to come)

The dynamic profile work is deliberately transport-neutral because LL-HLS
support is coming, and the two line up almost exactly:

- **CMAF is the shared seam.** LL-HLS is CMAF parts (≈200 ms) + partial
  segments; our video pipeline is already fMP4/CMAF end to end
  (`video-media.md`). One encode → CMAF fragments → both the MoQ broadcast and
  the HLS packager. The rendition ladder should be produced *once* at this
  seam, not once per transport.
- **Catalog ≈ master playlist.** MoQ catalog renditions and
  `EXT-X-STREAM-INF` variants / rendition groups describe the same ladder;
  the profile's quality/form vocabulary must express both (bitrate/resolution
  rungs, audio variants like stereo/mono, form = which renditions are on offer).
- **ABR placement matches.** LL-HLS players switch variants client-side
  (throughput + buffer health, e.g. BOLA), like our receiver-side
  `enable_adaptation`. The policy layer should decide *rung ranges and demand*,
  leaving the switch mechanics to whichever receiver is active.
- **Reconfig ≈ variant switch.** Mid-call `action=update` semantics should map
  onto HLS variant-switch semantics: a codec-config change is a new init
  segment / discontinuity on the HLS side, so the same quality/form transition
  must be expressible in both. Do not let call-specific fields leak into the
  profile's core; keep them in the `IDFON-LIVE` envelope around it.

Practical rule: build the profile + ladder against the CMAF/rendition model
first (C4/C10), and the LL-HLS packager consumes the same objects. The
demand model (C11) gains an HLS mode (one-to-many watch, replay) alongside
the call modes.

### B2.2 Bi-directional connection health check (user-invoked)

A push-button health check that turns the quality record into advice and
actions:

- **Bi-directional**: the probe runs on both legs (each side measures its
  own downlink via `NetworkSignals`; results merge into one verdict),
  because a call is two broadcasts and either direction can be the sick
  one. A passive mode (read both ends' current records) plus a short active
  probe (a few seconds of paced traffic) covers in-call and pre-call use.
- **Entry points**: an in-call button ("check connection"), a contact-screen
  check before dialing, and optionally a connection-health agent that runs
  it conversationally and narrates the result (the `agents/bench` pattern;
  tips can ride the outbox tools like any agent output).
- **Output**: verdict + tips + **action buttons** that map 1:1 to policy
  degradations: Turn off video, Turn off stereo (mono halves the audio
  bitrate), Lower video quality, Relay only. Each button calls the same
  profile/policy seam as the automatic rules (B2.4), so a health check
  teaches the user what the auto-policy would do anyway, and every automatic
  change can be shown with its reverse button.
- **Tips are rules first**: thresholds over the quality record (uplink loss
  → suggest video off; RTT queueing → suggest relay; stereo + weak link →
  mono; jitter → the jitter-buffer note). An agent layer can narrate the
  same rules in words; it should not invent new remedies.
- **Seam: tracing is shared, presentation is per app.** The shared layer
  owns the pure health-check tracing feature only: the probe, the merge of
  both ends' records, and a structured result plus progress events. Each
  shell owns how it runs and renders that (iOS: a sheet with check progress
  and action buttons; mac and the native GUI their own). The result schema
  and progress events are the contract; the two sides improve
  independently and incrementally.

This is the on-demand consumer of the C1 capture controls (#42): the health
check is what makes the record actionable in the field.

## C. Prioritized: what to test and change

### Field report (user device, 2026-10-28) — the ladder validated by hand

Wi-Fi calls are very good. During the Wi-Fi→cellular transition audio breaks
up (crackling, skipping) and video freezes sporadically. Turning off video
**helps** but audio still crackles. Turning off stereo (with video off)
**stabilizes the audio**.

Read against the stack: the handover gap is one problem (C2), but "audio
still crackles with video off" says the *settling* cellular leg is the
second one: the path lands in a capacity/loss regime where 72–96 kbps
stereo audio alone does not fit. The user's manual sequence (video off →
stereo off) is the B2.4 ladder executing by hand, and each step worked in
the predicted order — video off frees the most bytes (helps), mono halves
the audio bitrate (stabilizes). Crackling is the silence-hole path: a lost
frame becomes a zeroed gap with click edges; the conceal fill (PLC/LBRR,
shipped in the fork branch) converts those to soft dropouts. What this
changes: the transition fix is not only gap-taming (C2) but post-handover
adaptation — audio ABR (C5), the jitter buffer (C8), and the redundancy
mode (D7.1) are what make the cellular leg stable without user action.

Measure first — everything below needs the same instrumentation to prove out.

1. **Per-call quality record** (measure). Emit a per-call JSON summary at
   hangup: ListenStats-style audio metrics + NetworkSignals timeline (rtt,
   min_rtt, loss_rate, goodput, path_type direct/relay, path switches) +
   video freeze/rendition-switch events → telemetry + `Diag`. Foundation for
   every other item and for "are we improving".
   **Landed 2026-10-28 (the measure slice)**: `idfon_media::health::CallRecord`
   — a 500 ms NetworkSignals timeline (rtt, min_rtt, loss, goodput,
   direct/relay), selected-path switches, and a decode-side arrival fold
   (frames, startup, arrival jitter, max gap, stalls > 100 ms, missing
   frames, capture underruns) plus a video-seen flag. It accumulates across
   re-subscribes, folds at `media_live_stop()`, is read-and-clear as JSON via
   `media_health_last_report`, and both shells ship it to `Diag` ("call"
   event) at hangup. Not built yet: the capture controls below and video
   freeze/rendition-switch events.
   **Capture controls** (required, not an afterthought): the record is
   switchable at three levels — a global on/off default, a per-identity
   override (per user/contact opt, the privacy-relevant axis), and an
   on-demand per-call switch for live diagnosis and validation (flip it on a
   running call, e.g. through `Diag`/IDFON-DIAG/1, read the growing record
   live, leave it on or off afterwards). The on-demand path is what makes
   field reports actionable without a rebuild. Default state and retention
   are policy decisions to settle with the user.
2. **Reproduce + diagnose the Wi-Fi→cellular breakage** (test then fix).
   Under link conditioning / real device transition, capture the quality
   record + iroh path events. Decide between (a) transport switchover,
   (b) MoQ/receive-buffer stall, (c) adaptation confusion. Fix the root cause
   once in the shared media plane. This is the top robustness item.
3. **Turn on Opus FEC + DTX for calls** (change, cheap). Two flags in
   `AudioOptions` at the call sites (idfon-live-media/src/lib.rs:554,
   iroh-c-ffi/src/media.rs:374). Verify loss resilience on an induced-loss
   harness (item 6). Expected: big robustness win for near-zero cost.
4. **Live-video rendition ladder** (change). Publish 2–3 renditions from the
   live capture path (downscale in Rust from the pushed RGBA — no camera
   changes needed) so `enable_adaptation` has rungs to pick; verify the
   720p→480p→360p degradation shows up under induced congestion.
5. **Audio ABR from NetworkSignals** (change, after 1–3). Drive the Opus
   bitrate with `delivery_bps`/`goodput_bps` headroom (clamp 8–64 kbps).
   Audio never breaks first.
   **Landed 2026-10-28**: `crates/iroh-c-ffi/src/abr.rs` drives the encoder's
   `BitrateControl` from `Session::send_bandwidth()` through the house rate
   policy (`moq_video::encode::rate`), clamped to 8–64 kbps per channel and
   never above configured — a caller who configured more (music via
   `media_audio_set_bitrate`) made that choice, so ABR stands down outside
   the band. The FEC-flip track rebuild re-attaches the same control
   (`media_audio_set_fec`).
6. **Loss/jitter/transition test harness** (test). Repeatable netem/link-
   conditioner profiles (clean, 1 % loss, bursty Wi-Fi, 300 kbps uplink,
   1 s blackhole = handover) run against the headless `ListenStats` path so
   every change here is regression-tested.
7. **Auto video-off policy** (change, after 4). Sustained audio degradation
   (stall rate / loss above thresholds) → drop the video track and tell the
   UI ("video paused to protect audio"); restore on sustained recovery.
8. **Adaptive jitter buffer** (change). PacedPlayback prebuffer target from
   recent arrival-jitter percentile (clamp ~30–150 ms) instead of fixed 50 ms.
9. **NWPathMonitor on ios/mac** (change). On interface change: announce it
   (quality record tag "transition"), proactively grow the jitter buffer and
   step video down one rung before the breakage hits.
10. **Media profile + policy layer** (change, per B2 — mostly wiring). Thin
    per-call profile state over the *existing* knobs (FFI setters,
    `Producer::set_bitrate`, `enable_adaptation`/`requested`);
    `IDFON-LIVE/1 action=update` for wire-visible fields; the B2.4 state
    machine. Items 3/4/7/8 then become profile fields + policy rules instead
    of separate features. Audio-side ABR (item 5) is the one knob with no
    existing driver — `set_bitrate` exists, the feedback loop does not.
11. **Demand model** (change, after 10). The app side declares the call mode
    (audio / video / watch / agent / stereo) as the profile's initial state and
    allowed degradation range; the policy state machine of B2.4 runs over it.
    `stereo-calls.md`'s stereo toggle is the first "form" input already in the
    UI.

Not doing now (deliberately): SVC/temporal layers (simulcast rungs suffice),
opus-RED (FEC first), MPTCP/multipath QUIC (transport work, revisit after 2),
MOS scoring beyond a simple E-model R-factor approximation.

## D. Use the stack; own the delta

Strategy: adopt the MoQ stack for everything it provides — do not rebuild it —
and investigate the areas that matter to human↔human calls but not to a
live-streaming project, where nothing is addressed or nothing is modern yet.

### Already modern upstream (use as-is, verified in sources)

- **BBR3** congestion control for media publishers (deliberately replacing
  iroh's CUBIC default — `iroh-live/src/util.rs`).
- **Capacity estimate on the wire** (`delivery_bps` / PROBE) plus
  `NetworkSignals` with honest freshness semantics (per-path `min_rtt`,
  `rtt_samples`, goodput vs estimate as lower/upper bounds).
- **Receiver rendition adaptation** with hysteresis, probes, emergency drops
  (`adaptive.rs`) — the video ABR loop is done.
- **Delivery model**: single-frame groups over unreliable QUIC datagrams (no
  head-of-line blocking; loss is dropped, not retransmitted) + reliable streams
  for larger groups, with skip-stalled-group semantics on the consumer side.
- **Dynamic catalog**, mid-stream `set_bitrate`, Opus `fec`/`dtx`/frame-duration
  knobs.
- **Per-frame timeline instrumentation** (`moq-media/src/stats.rs`: receive /
  decode / playout-release wall times, audio and video playout lag, EMA + ring
  buffers for a debug overlay).

### The delta — ours to investigate/build (ordered)

1. **Conversational latency budgets end-to-end** (investigate; feeds C1).
   Their world targets streaming latency; ours is ITU-T G.114 conversational:
   < 150 ms one-way glass-to-glass, audible-gap < 200 ms. Nothing measures the
   full chain (capture → encode → wire → decode → playout) as one budget.
   Combine their `stats.rs` Timeline with our `ListenStats` and instrument both
   app ends; decide where the budget is currently spent.
2. **Handover gap length, not handover existence** (investigate; sharpens C2).
   iroh path selection + relay fallback exists; the call-relevant number is the
   gap duration across Wi-Fi↔cellular. Sub-questions: how fast the selected
   path switches when the interface dies (make-before-break or not); whether
   the receive side skips to live after the gap (the audio consumer "skips what
   it already has" — verify video); how long BBR3 takes to re-find the rate
   after a multi-second blackout (post-idle startup undershoot is a known BBR
   behavior). Blackhole profile in the C6 harness answers all three.
3. **A/V sync lock** (build; new). `stats.rs` tracks audio and video playout
   lag *separately*; nothing locks them to one another at render. Lip-sync
   tolerance is roughly: audio may lead video ≤ 45 ms, video may lead ≤ 125 ms
   (ITU-R BT.1359-1). Ours to implement at playout (video slaved to the audio
   clock) and to measure in the quality record.
4. **Audio adaptation loop** (build; C5 + C3). `adaptive.rs` is video-only;
   the bitrate knob has a driver now (C5 landed 2026-10-28); `fec`/`dtx` are
   policy-only flips. The policy layer (B2) supplies the rest — no new
   mechanism.
5. **Quality persistence and summary** (build; C1). `stats.rs` is a live
   overlay (EMA + sparklines); the per-call record folds and logs at hangup
   now (C1 landed), but nothing persists the summaries, computes an
   R-factor/MOS-style score, or trends across releases. Ours.
6. **Own-edge relay quality** (investigate; new). They run on n0's public
   relays; we run `idfon-edge`. Verify how iroh selects relay paths, whether
   our edge is preferred/usable mid-call, and how direct→relay fallback reads
   in stats (their per-path `min_rtt` already avoids the "relay reads as a
   permanent queue" trap — confirm it fires in our topology).
7. **Redundancy level check before adding any** (investigate). In-band Opus
   FEC is available; modern WebRTC favors opus-red (RFC 2198) on top; on the
   datagram path there is no NACK/RTX. Decide by measurement on the C6 loss
   profiles — do not stack redundancy mechanisms speculatively.
8. **Upstream drift** (housekeeping, low). Frando/moq `iroh-live-3` branch +
   pinned `iroh-live` rev are moving targets; decide pin-vs-patch-vs-upstream-
   contribute before delta work accumulates private patches.

### Session findings (2026-10-28) — items D3, D6, D7, D8 investigated

**D3 A/V sync — implemented.** New `crates/iroh-c-ffi/src/av.rs`: a sync clock
anchored at every audio `playback.write` (media pts → wall time `now +
buffered()`, trim-adjusted), and a gate in `video_loop` before
`render.present`: early frames wait for the audio clock, frames > 250 ms late
are dropped, a > 250 ms-future anchor (audio stall) presents immediately.
No audio leg = old behavior. 5 unit tests cover the decision table. Skipped:
the asymmetric BT.1359 bias (aligned is inside both tolerances); periodic
re-anchor drift correction (anchors update every 20 ms anyway).

**D6 Own-edge relay — verified, gap found.** The call media plane cannot use
our relay today: `Endpoint::bind(presets::N0)` is hard-coded at the three
iroh-c-ffi media/video sites (media.rs:1329/1532/1568) and inside iroh-live's
`Live::from_env` itself; only the daemon transport honors
`IDFON_RELAY_URLS` (idfon-core/src/transport.rs) and the FFI
`EndpointConfig.relay_mode` is just `Disabled | Default` — there is no
surface on iOS/macOS to point calls at idfon-edge. All calls fall back to n0's
rate-limited public relays. Fix = extend the FFI relay config with a custom
relay map + app config surface, and thread it into the media endpoints.
Direct→relay fallback in stats is handled correctly upstream (per-path
`min_rtt` resets on path change — verified in their tests).

**D7 Redundancy — measured 2026-10-28 (Phonon speech, codec-level harness).**
Mechanism check first: DTX works end-to-end as-is (encoder `dtx: true`;
decode preserves activity through loss) — **enabled on both call sites
2026-10-28** (C3's DTX half shipped; FEC half gated on decode-side recovery).
**In-band Opus FEC buys nothing today**: at a hole the decode consumer
flushes the held tail and decodes the *next* packet normally; nothing calls
`opus_decode(..., decode_fec=1)` for the lost frame, and there is no PLC
either — a hole becomes silence at playout.

Measured (`scripts/opus-loss-fixture.sh` renders 16 s Phonon speech at 24 kHz
mono; `tests/opus_redundancy.rs` encodes 32 kbps/20 ms and injects frame
loss; segSNR vs clean decode, clamped [-10, 45]; hole_ms = active reference
audio replaced by silence):

| profile | none (today) | plc | fec + LBRR recovery | red (sim. RFC 2198) |
| --- | --- | --- | --- | --- |
| 2% random | 39.0 dB / 240 ms holes | 36.7 / 0 | 43.1 / 0 | 45.0 / 0 |
| 5% random | 35.2 / 440 ms holes | 30.3 / 0 | 41.6 / 0 | 45.0 / 0 |
| 10% random | 29.8 / 780 ms holes | 21.6 / 0 | 38.0 / 0 | 41.2 / 0 |
| burst 3% | 43.8 / 60 ms | 43.3 / 0 | 44.1 / 0 | 43.3 / 0 |
| blackhole 240 ms/3 s | 38.2 / 740 ms | 36.5 / 120 ms | 38.7 / 100 ms | 37.2 / 100 ms |

Wire cost measured: **fec = 1.0×** (LBRR is paid from inside the bitrate
budget), red = 2.0×.

**Decision: PLC + in-band FEC recovery, no red.** PLC is mandatory and free
(0 holes at random loss; its segSNR reads low because a concealment frame is
a plausible-but-wrong waveform — continuity is the perceptual win, and codec
PLC is what every real receiver runs). FEC recovery is the redundancy level
to add: same wire cost as today, quality near the red tier at ≤5% loss. Red
is rejected: 2× the bytes for +3–4 dB over FEC. Nothing reaches into
multi-frame blackholes beyond PLC's decay to silence (~100 ms residual) —
that is the handover-gap work (C2/C9), not redundancy.

Spec for the decode-side work (#39): at a detected hole, first try
`opus_decode(next_packet, decode_fec=1)` to recover the lost frame (needs
encoder FEC on — C3's other half), else `opus_decode(NULL)` PLC, in
moq-audio's consumer; contribute upstream to moq main per D8. **Filed as
moq-dev/moq#7130 (draft, 2026-10-28)**; the same change rides our pins on
donpark/moq branch `loss-recovery-0.0.23` (based on Frando `iroh-live-3`)
until that merges. Encoder side (#24): enable FEC with a **modest bitrate
bump (~32→36–40 kbps/channel)** —
LBRR is paid from inside the budget at fixed bitrate, so flat-rate FEC trades
a little primary quality for recovery (hidden behind the clean-pass SNR
clamp in the table above).

Verified against libopus source and docs (2026-10-28): `decide_fec` refuses
LBRR unless `useInBandFEC && packetLossPercentage > 0` and the rate clears a
per-bandwidth threshold (confirming the half-wired-knob finding), and never
codes it on CELT-only frames (SILK/hybrid only). Two knobs worth knowing:
a loss hint above 5% makes the encoder *narrow bandwidth* to fit LBRR when
the rate is short (our 10% hint is aggressive on starved links), and the
decoder-side contract (`opus.h`): for PLC/FEC recovery `frame_size` must be
exactly the missing duration "otherwise the decoder will not be in the
optimal state to decode the next incoming packet" (what `conceal_len` gives
us), and a packet without FEC data "is decoded as if it were lost" (one
call covers both).

**Stereo + FEC couples the channels (measured 2026-10-28).** With FEC on,
`decide_fec`'s own comment delivers the mechanism: above a 5% loss hint it
"decreases the bandwidth until it can enable FEC", and narrowed-band stereo
coding falls into coupled/intensity stereo, which leaks the channels into
each other (the stereo roundtrip test's 5:1 separation fails intermittently,
more under load; 6/6 clean with FEC off). The 48 kbps/ch floor hid the
common case but not every frame. Policy: **FEC is a mono-voice feature**
(flip it with the stereo step, see B2.4); stereo keeps the image.

### D7.1 The redundancy option space (DRED and beyond)

With libopus 1.5/1.6 there are now four redundancy mechanisms, and the
stereo step no longer has to mean "no recovery" (user framing, 2026-10-28):

| mechanism | stereo-safe | wire cost | needs | recovers |
| --- | --- | --- | --- | --- |
| in-band FEC (LBRR) | **no** (couples channels) | ~0 (steals the budget) | any libopus; **shipped** (mono resilience mode) | 1 frame |
| **DRED** (deep redundancy) | **yes** (additive payload; the primary is coded normally) | rate-controlled, ~0.3×(bitrate−20 kbps) at loss hint 10 | libopus **1.5+**; **shipped** (1.6.1, stereo quality mode) | up to **1 s** |
| transport-layer FEC (parity over the datagram groups) | yes (codec-independent, covers video too) | 10–30% parity | nothing (codec-independent) | one parity block |
| duplication / RFC 2198 red | yes | 2× audio | nothing | 1 frame |

Verified facts (opus-codec.org 1.5 demo, `opus_defines.h`, `opus.h`):
DRED is set with `OPUS_SET_DRED_DURATION` (max 10-ms redundant frames),
decodes through its own `opus_dred_*` state, **composes with LBRR**
("quality approaches that of the no-loss case"), older decoders ignore the
payload, and it is **not yet standardized** (1.5 and 1.6 payloads may
differ: both ends must pin the same libopus generation). Deep PLC is free
on top (decoder-only).

Design shape: one **redundancy mode** in the media profile (B2),
`off | inband | dred | transport`, chosen by the ladder and the call mode
(C11), same seam as the FEC flip (`media_audio_set_fec` today, the mode
knob tomorrow). Shipped 2026-10-30 as the two-flag approximation of that
mode split (`Settings::fec` + `Settings::dred`, flipped together by the
stereo step):

- mono voice: `inband` (shipped, the measured win).
- stereo/quality calls: `dred` — **shipped**: the stereo step keeps
  recovery without touching the image, and the 1 s span covers handover
  blackholes that no frame-level mechanism reaches. Stereo rates (≥ 96 kbps)
  afford DRED's chunk budget; mono resilience rates do not (see below).
- `transport` as the codec-independent floor: needs no codec, and is the
  only redundancy play that also covers **video** datagrams. Costs a parity
  block of latency unless run as a sliding window. Not built.
- `off` for recorders and anything that must show holes as sent (shipped:
  the recording path sets neither flag).

**Codec-version caveat (updated 2026-10-30).** The build now runs libopus
**1.6.1** (`opusic-sys`, vendored C): the fork's moq-audio codec backends
and `recover` moved off the 1.3.1 `unsafe-libopus` transpile (branch map in
`moq-fork.md`). DRED is wired end to end: `Settings::dred` embeds up to
`DRED_COVER` (120 ms), `Decoder::recover(next, frames_to_next)` rebuilds
each lost frame in `opus_demo` order (LBRR at the boundary frame, DRED at
the frame's offset, then concealment), family 0 decoding through the plain
Opus decoder so recovery keeps prediction continuity. Measured
(2026-10-30, stepped tones): DRED beats concealment 1.1–1.8×, the margin
thinning with depth (older latents are quantized coarser); the DRED chunk
budget is rate-controlled (`compute_dred_bitrate`) and the codec **drops
DRED entirely below ~2 chunks affordable** (~48 kbps at loss hint 10) —
exactly why the mode split above gives DRED to stereo rates and LBRR to
mono resilience. Both ends must pin the same libopus generation (DRED
payloads are not standardized). Still open: the single mode knob, the
`transport` tier, and a device CPU measurement of the DRED encoder before
shipping it on iPhone. The blackhole row above is likewise no longer a
1.3.1 result: on 1.6.1, DRED is the remedy for handover blackholes and
deep PLC upgrades the PLC tier for free.

**D8 Upstream drift — updated 2026-10-30.** The 2026-10-28 "stay pinned to
Frando" decision was superseded by upstream's history rewrite: moq-dev/moq
now carries two living, unrelated lines — `release` (our lineage; the
crates.io releases are cut from it, and iroh-live builds against those)
and a re-rooted `main`. We moved to `donpark/moq@loss-recovery-release`
(= `origin/release` + our loss-recovery/FEC/BitrateControl/codec patches)
and iroh-live `9abd29be` (`Frando/bump-moq-2`, released moq crates).
Branch map, the git-source unification rules, and the update procedure live
in `moq-fork.md`. Decision stands: keep the git pins (reproducible builds);
route delta work upstream so it survives the consolidation; review pins
monthly and before any media-plane feature work.

## Rebuild scope

Changes here touch `crates/idfon-media`, `crates/idfon-live-media`,
`crates/iroh-c-ffi` → Rust workspace + `libiroh_c_ffi.dylib` + both apps
(`docs/build.md`). Test harness work (items 1, 6) is headless-Rust-only.
The A/V sync gate (2026-10-28) touched `crates/iroh-c-ffi` only → rebuild the
dylib + both apps.
