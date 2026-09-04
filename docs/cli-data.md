# CLI data transfer and live streaming

The `nufon` CLI moves arbitrary data between two nufon endpoints with
bash-pipe semantics, and publishes live audio streams. File transfers ride
the daemon's blob path (`media.resource.put`/`media.resource.fetch` over
iroh-blobs), not the chat message path, so size is bounded by disk, not by
IPC frames. Live streaming rides iroh-live (`media.live.*` daemon methods).

## Commands

```sh
# Sender: pipe or --file. Prints a bare BlobTicket (one line) on success.
cat recording.wav | nufon put > ticket.txt
nufon put --file recording.wav

# Receiver: streams the blob to stdout (or --out FILE).
nufon get "$(cat ticket.txt)" > copy.wav
nufon get "$(cat ticket.txt)" --out copy.wav
```

- The BlobTicket is the capability: anyone holding it can fetch the data
  from the sender's endpoint. Distribute it over any channel (the GUI chat
  path, SSH, QR, out of band).
- `--resource-id ID` names the sender-side stored resource; without it a
  unique `data-<nanos>` id is generated.
- `--json` on `put` prints the full daemon response (includes
  `content_hash`, `size_bytes`).
- `--socket PATH` / `--identity ID` select the daemon and identity as usual.

## Chunking

The CLI splits transfers into 200 KB chunks:

- `put` appends `media.resource.put {append:true}` chunks and publishes with
  a final `{finish:true}` request, so payloads are not limited by the 1 MB
  IPC frame.
- `get` reads `media.resource.fetch {offset,length}` slices until
  `total_size` is reached. The receiver's blob store persists downloaded
  blobs, so only the first slice transfers over the network.
- One-shot put/fetch (single `bytes` array, no flags) still works for small
  payloads and is what the daemon unit tests cover.

## Retry behavior

A `fetch` may arrive before the sender's first pkarr publish has propagated
to the n0 discovery infrastructure. `blob::fetch` therefore retries with a
fresh endpoint (fresh DNS resolver) up to six times, one second apart, with
a 30 s timeout per download attempt.

## End-to-end test

`scripts/test-e2e.sh` starts two `nufond` endpoints in temp dirs and
exercises the CLI path end to end:

1. a one-chunk binary file (`--file` source, `--out` sink),
2. a 1.25 MB multi-chunk transfer through bash pipes on both ends,
3. a WAV audio file round trip.

Every case must be byte-identical (`cmp`) to its original.

```sh
scripts/test-e2e.sh
```

## Signaled transfer through the message path

`send-data`/`recv` close the loop: the BlobTicket travels through nufon's
own message path, so no side channel is needed.

```sh
# Sender endpoint (paired with the receiver; see pairing below):
cat data.bin | nufon send-data bob          # prints the BlobTicket on delivery
# Receiver endpoint:
nufon recv > data.bin                       # waits for the next data message
```

- `send-data PEER` stores the data as a blob, sends a versioned
  `NUFON-DATA/1` envelope (`ticket=`, `size=`) via `message.send`, and waits
  for the delivery operation to reach a terminal state before printing the
  ticket. `--retries N` covers transient connection handshakes.
- `recv` waits (default 60 s, `--timeout-ms`) for the next data message that
  arrives after it started, fetches the blob, and streams it to stdout or
  `--out FILE`. `--from PEER_ID` filters by sender. The declared size is
  verified against the fetched byte count.
- Received text messages that are not data envelopes are ignored, so `recv`
  coexists with normal chat traffic.

### Pairing two endpoints (CLI)

The first transfer between two fresh daemons needs three one-time steps per
direction: cross peer registration, and one grant each. A peer's id and
public key are the same value (hex of the Ed25519 public key), and
`context` exposes each endpoint's address.

```sh
# Peer info — run the same three lines against each daemon socket:
ctx() { nufon --socket "$1" context --json; }
EP=$(ctx /tmp/nufon-a/nufond.sock | jq -r .result.identity.endpoint_id)
PID=$(ctx /tmp/nufon-a/nufond.sock | jq -r .result.identity.public_key)   # == peer id
ADDR=$(ctx /tmp/nufon-a/nufond.sock | jq -r '.result.ticket | implode')   # EndpointAddr JSON

# On daemon A: register B as a peer and grant it the send capability
# (A's send gate checks a local message.send grant for B's peer id):
nufon --socket /tmp/nufon-a/nufond.sock add "$B_PID" --name bob \
  --endpoint-id "$B_EP" --endpoint-addr "$B_ADDR"
nufon --socket /tmp/nufon-a/nufond.sock grant --subject "$B_PID" \
  --capability message.send

# On daemon B: register A as a peer and grant it the receive capability
# (B's receive gate checks message.receive for A's peer id, or a verified
# capability ticket presented by the sender):
nufon --socket /tmp/nufon-b/nufond.sock add "$A_PID" --name alice \
  --endpoint-id "$A_EP" --endpoint-addr "$A_ADDR"
nufon --socket /tmp/nufon-b/nufond.sock grant --subject "$A_PID" \
  --capability message.receive
```

Alternatively, a sender can present a capability ticket issued by the
receiver instead of a local grant: `nufon ticket --subject SENDER_PEER_ID`
prints the ticket JSON, which `send --capability-ticket` accepts; a verified
ticket satisfies the receive gate and materializes grants on first delivery.

`scripts/test-e2e.sh` exercises the whole signaled flow (pairing,
`send-data`, `recv`) as its fourth case.

## Live audio streaming

`stream`/`listen` publish and consume live audio over iroh-live. Sources and
sinks are files — no microphone or GUI required (mic input is a later
extension).

```sh
# Publisher endpoint: streams FILE (or stdin) as a live broadcast.
# Prints a bare live ticket (one line) on success.
nufon stream --file speech.wav --loop > ticket.txt
cat song.flac | nufon stream > ticket.txt        # stdin is spooled by the CLI

# Listener endpoint: records the broadcast to stdout (or --out FILE).
nufon listen "$(cat ticket.txt)" > copy.wav
nufon listen "$(cat ticket.txt)" --out copy.wav --seconds 30
```

- The live ticket embeds the publisher's endpoint and broadcast name; it is
  the subscriber capability. No pairing, grants, or side channel needed —
  distribute it over any channel (chat, SSH, QR).
- `--loop` repeats the source indefinitely; without it the broadcast ends
  when the file does (the publisher stays reachable until stopped).
- `--name NAME` sets a stable broadcast name; default is
  `nufon-live-<nanos>`.
- `listen --seconds N` caps the capture window (default 15, max 600); the
  request returns when the window ends or the broadcast ends.
- `--json` on `stream` includes the publisher id and wall-clock anchor;
  on `listen` it includes duration, packet count, and arrival jitter.

### Publisher lifecycle

Publishers run inside the daemon and are kept in an in-memory registry
(not persisted across daemon restarts):

```sh
nufon stream --file speech.wav --loop --name radio    # prints the ticket
nufon publishers                                       # list running publishers
nufon stop-live live-<name>                            # graceful stop
```

`stop` sends the underlying iroh session a graceful shutdown before tearing
it down — dropping the session without it would break subscribers mid-
stream.

### Implementation notes

- The file source decodes through symphonia (WAV/MP3/FLAC, resampled to
  48 kHz stereo) and encodes to Opus. It never opens the microphone:
  iroh-live's `AudioBackend` (which grabs the default input device for
  echo cancellation) is only needed for live mic input, a later extension.
- The publisher must hold its broadcast for the session's lifetime;
  dropping it silently kills the catalog and new subscribers fail with a
  confusing `not found`. The daemon owns the session in a registry so this
  cannot happen across CLI invocations.
- `scripts/stream-e2e.sh` runs the whole flow between two fresh daemons
  with a synthetic pip pattern and reports decode jitter, packet-arrival
  jitter, and a latency estimate; `scripts/stream-e2e.sh speech.wav`
  substitutes a voice sample for quality listening.
