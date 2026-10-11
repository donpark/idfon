# Artifacts and multimodal references

> **Status:** the model, thread UI (iOS + mac), agent emit and resolve,
> references (text / image region / HTML element), the sandboxed web view, and
> the app-owned json-render renderer for structured results are landed.
> Remaining: time-range selection and device/vision verification. Direction:
> 2026-09-29.

Voice chat with an idfon agent is **multimodal chat**. A turn is not just text
or audio: the agent produces **artifacts** (a chart, a document, a JSON result,
a rendered report), they appear in the **chat thread** as openable items, the
user opens one in a **detail screen**, and — the part that makes it more than a
file attachment — the user can **point at a region of an artifact and ask about
it**. The next turn carries that selection, so the agent reasons about the exact
thing the user indicated rather than the artifact as a whole.

This is the product, not a later milestone. The pieces below are ordered so each
one is usable on its own.

## Data model

The types live in `crates/idfon-protocol/src/artifacts.rs` and travel as
message-text envelopes, so there is **no protocol-version bump**: a peer that
does not know them sees an unknown `IDFON-*/1` envelope as plain text.

- `Artifact { artifact_id, kind, mime, title, size_bytes, blob_ticket?,
  source_message_id?, conversation?, metadata, created_at }`.
  `kind` is a coarse `Document | Image | Audio | Video | Data | Html | Live`;
  `mime` stays authoritative. `metadata` carries renderer hints (a json-render
  catalog id, a live stream ticket, dimensions). A non-`Live` artifact must have
  a `blob_ticket`.
- `ArtifactSelector` — the selection, normalized so it survives zoom and
  different render sizes:
  - `Whole`
  - `Text { start, end, quote? }` (UTF-8 byte offsets)
  - `Region { x, y, width, height, page? }` (unit square)
  - `TimeRange { start_ms, end_ms }`
  - `JsonPointer { pointer }` (RFC 6901)
  - `Element { path }` (rendered markup)
- `ArtifactRef { artifact_id, selector, note? }`.
- `MessageReference { text, refs: [ArtifactRef] }` — a user turn that asks about
  one or more selections.

Envelopes: `IDFON-ARTIFACT/1\n<json>` (agent → thread) and
`IDFON-REF/1\n<json>` (user → agent). Decoders validate; an empty range, an
out-of-bounds region, an empty ref list, or a non-envelope body is rejected
rather than silently degraded.

## Thread UX

- An artifact renders as a **card** in the thread: title, kind icon, a small
  preview when the blob is already local, and an open affordance. It is a peer
  of the existing text/recording/file cells, not a replacement.
- **Detail screen:** full-screen render chosen by `kind` — text/markdown,
  image (zoom/pan), PDF (paged), audio/video (transport), structured data
  (json-render or a tree), HTML (the sandboxed web view). This is where the
  gateway/WebView work connects: HTML/SVG/PDF/media now **load the gateway URL**
  (`idfon://<account>/fs/<artifact_id>` served by `ArtifactGateway` — the
  loopback gateway with its direct→edge fallback, or the public edge directly),
  so relative subresources resolve and no bytes cross the app layer; a local
  cached/blob artifact still renders by byte injection. Text/images read bytes
  from the local blob or through the same gateway path.
- **Sandboxed web view:** untrusted HTML/SVG renders in a `WKWebView` whose only
  source is an in-memory custom scheme — non-persistent data store, no native
  bridge, content rule list blocking every other load, and navigation cancelled
  off-scheme. The same view renders images/PDF/audio/video as-is through a
  minimal shell, so media artifacts need no separate player. Element selection
  is implemented: in Select mode a tap computes the clicked element's byte range
  in the serialized document and sends it as a `Text` selector over the HTML
  source, so the existing text resolver handles it without an HTML parser.
- **Annotate → ask:** a tool in the detail screen selects a `selector` (drag a
  region, select text, mark a time range, tap a JSON node). The composer then
  shows a reference chip; the sent turn is a `MessageReference`. Voice is
  unaffected — you can speak the question with the chip attached.
- Artifacts are **immutable**; a revision is a new `artifact_id` with
  `metadata.revision_of`. The thread pins the id it was sent with.

## Agent side

- A tool (working name `add_artifact`) publishes an agent output: stores the
  bytes as a blob, builds an `Artifact`, and sends it as an `IDFON-ARTIFACT/1`
  turn. The holder already has `blob.put` and the `IDFON-DATA/1` path to reuse.
- On inbound `MessageReference`, the channel resolves each ref before the model
  sees the turn: slice the text range, extract the JSON subtree, or preview the
  whole artifact (`read_reference`), and pass the extracted content plus the
  reference as turn context. A region arrives already cropped as the turn's
  attachment; time-range selection is still unhandled. A `note` on the ref is
  user intent and is passed through.
- When a selection cannot be resolved (blob not local, peer offline), the agent
  still receives the selector and the `quote`/`metadata` so it can ask rather
  than hallucinate.

## Voice and artifacts

The artifact model is visual-first: it assumes a detail screen and a pointer. A
voice agent needs three things the visual model does not provide: a **spoken
projection**, a way to **select and navigate by voice**, and a **no-screen
fallback**. The two directions are complementary. Artifacts give voice something
durable and structured to point at. Voice gives artifacts an operational surface
that does not depend on a touchscreen.

### Spoken projection

An artifact needs a short, safe description a voice model can say without reading
the content. Add a convention on `metadata`:

- `metadata.spoken` — one to two sentences, speakable, set by the issuer
  (`add_artifact` or the app). It is a summary, not a truncation.
- `metadata.alt` — a text alternative for `Image`, `Data`, and `Html` artifacts.

The model speaks `metadata.spoken`, or falls back to `title` and `kind`. It never
reads the artifact body aloud. The app renders `metadata.alt` for assistive
technology. The same fields make an artifact usable on a voice-only channel and
usable to a blind user.

### Selection and navigation by voice

Selection is currently touch or mouse only. Voice needs a natural-language path
to the same selectors:

- Map a spoken phrase to a selector. "the second column" maps to a `Text` or
  `Region` selector, "the part about revenue" resolves to a `Text` selection,
  "skip to the error" maps to a `TimeRange` or `Text` selection.
- Confirm the resolved selector before the agent acts on it. A wrong selection is
  worse than a question.
- A voice-only channel has no tap to define "this". The app should send a
  **focus** signal (the artifact and revision the user is looking at), or the
  agent must ask.

### No-screen fallback

A recipient on a voice-only channel (a phone call, SMS) has no card to open. The
agent degrades the artifact by channel:

- speak `metadata.spoken` and offer to read a selected part aloud;
- send a rendered snapshot (image or PDF) to a channel that can show one;
- hold the artifact for later, and say so.

### Live artifacts

A `Live` artifact changes over time. Voice needs a narration policy: the model
announces a change only when it matters to the turn, never as a continuous feed,
and the user can mute the narration.

### Revisions

Artifacts are immutable, so a call can produce several revisions. The turn
contract should carry the revision the user is looking at, and the agent should
name the revision when it matters ("the version on screen now").

### Forms as artifacts

`IDFON-HITL/1` is a structured ask. It is close to an interactive artifact: it
has a schema, a renderer, a response, and a correlation id. Unifying the two
would let one renderer, one selector model, and one correlation path serve forms
and artifacts.

### Across channels

An artifact is idfon-native: bytes, a blob ticket, a gateway URL, selectors.
Exported to email, Slack, or SMS it loses the selectors, the interactivity, and
the idfon trust boundary. Each channel needs a representation it can carry (a
link, a rendered PDF, a static image) and a portable artifact reference so a
reply from another channel can correlate back.

### Accessibility

Charts, tables, and images need a spoken or structural form: alt text by default,
a table-to-speech path, a description for a chart, and structural navigation.
This is an accessibility requirement and the same machinery voice agents need.

Open questions: who sets `metadata.spoken` (issuer, blueprint/app, or the model);
whether `metadata` is the right home or a first-class `spoken` field; and how far
voice-to-selector resolution belongs in the agent versus the app.

## Storage and transport

- Bytes live in `iroh-blobs`, content-addressed; the artifact record is the
  metadata around a ticket.
- The daemon keeps a per-identity **artifact registry** (like `MediaResource`),
  so the thread can list and re-open artifacts after a restart.
- Remote detail view uses the same gateway/MCP-resource path as any other
  idfon resource (`docs/idfon-gateway.md`): `idfon://<account>/fs/<path>`
  resolves to the bytes. Live artifacts use stream tickets (MoQ), not blobs.

## Slices

1. **Model** — `artifacts.rs` types, validation, envelope codec, tests. *Landed.*
2. **Thread** — both apps parse the envelopes, render an artifact card, and
   open a detail screen (text/image). Message bodies are split into reply text
   plus trailing envelopes, so a transcript followed by an envelope renders as
   two items instead of raw text. *Landed (iOS + mac).*
3. **Agent emit** — the `add_artifact` tool stores bytes through the idfon
   bridge (`/blob/put`) and returns an `IDFON-ARTIFACT/1` envelope the model
   appends to its reply text; no holder or bridge change was needed. *Landed
   (live-voice).*
4. **Reference capture** — *landed (iOS + mac):* the detail screen selects an
   image region (drag) or a text range, the composer shows a reference chip, and
   the sent turn is an `IDFON-REF/1` message — typed, or riding along with a
   voice memo. (The holder's attachment parser stops at the next envelope, so a
   memo can carry a reference.) A ref carries the artifact's blob ticket, so it
   is self-contained. The channel's `read_reference` tool fetches the blob and
   resolves text ranges, JSON pointers, and whole-content previews. A region
   selection is cropped **app-side** (the app holds the pixels) and sent as the
   turn's attachment, so the agent gets the exact image; the tool returns the
   coordinates. Remaining: time-range selection and a confirmed vision path
   (the model must be able to see the cropped attachment).
5. **Rich renderers** — *landed:* a sandboxed web view for HTML/SVG and for
   image/PDF/audio/video as-is, with element selection; structured results
   render through the app-owned json-render catalog (`JSONRenderModel` /
   `JSONRenderView`, actions resolved by `RenderToolRegistry`).
6. **Remote view** — artifacts live in the app-side **session cache** with the
   session log (ephemeral, opt-in persist); opening one fetches by ticket, or
   from the owner's live shared root (`idfon://<peer>/fs/<path>`) when the bytes
   are not local. The daemon serves that shared root in place, no registry and no
   copy, so a delete/rename is reflected immediately and nothing is cached.
   Sharing is a local-file operation: fetch if remote, then the OS share sheet.
   The app-side `SessionStore` now holds the log + cached artifact bytes
   (ephemeral cache by default, opt-in `persistLogs`), so the daemon event store
   is only a transient buffer. The mac Sessions menu toggles `persistLogs`, and
   the artifact detail's **Save to Shared** writes the bytes into the served
   `Documents/Shared` directory. Remaining: per-session `resource.read` scoping
   only if a shared root ever holds more than one tenant.

Slices 2–4 are the demo: speak a question, get an artifact in the thread, open
it, point at a region, ask again by voice.

Manual runbook for the end-to-end pass: `docs/idfon-artifacts-testing.md`.
