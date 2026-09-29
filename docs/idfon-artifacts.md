# Artifacts and multimodal references

> **Status:** the model, thread UI (iOS + mac), agent emit and resolve,
> references (text / image region / HTML element), and the sandboxed web view
> are landed. Remaining: json-render for structured results, time-range
> selection, and device/vision verification. Direction: 2026-09-29.

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
  gateway/WebView work connects: the detail view fetches bytes either from a
  local blob or through `idfon://<account>/artifacts/<id>`.
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

## Storage and transport

- Bytes live in `iroh-blobs`, content-addressed; the artifact record is the
  metadata around a ticket.
- The daemon keeps a per-identity **artifact registry** (like `MediaResource`),
  so the thread can list and re-open artifacts after a restart.
- Remote detail view uses the same gateway/MCP-resource path as any other
  idfon resource (`docs/idfon-gateway.md`): `idfon://<account>/artifacts/<id>`
  resolves to the blob. Live artifacts use stream tickets (MoQ), not blobs.

## Slices

1. **Model** — `artifacts.rs` types, validation, envelope codec, tests. *Landed.*
2. **Thread** — both apps parse the envelopes, render an artifact card, and
   open a detail screen (text/image). Message bodies are split into reply text
   plus trailing envelopes, so a transcript followed by an envelope renders as
   two items instead of raw text. *Landed (iOS + mac).*
3. **Agent emit** — the `add_artifact` tool stores bytes through the idfon
   bridge (`/blob/put`) and returns an `IDFON-ARTIFACT/1` envelope the model
   appends to its reply text; no holder or bridge change was needed. *Landed
   (ai-voice-chat).*
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
   image/PDF/audio/video as-is, with element selection. Remaining: json-render
   for structured results (or a native tree).
6. **Remote view** — gateway/`idfon://` fetch for artifacts not held locally.

Slices 2–4 are the demo: speak a question, get an artifact in the thread, open
it, point at a region, ask again by voice.

Manual runbook for the end-to-end pass: `docs/idfon-artifacts-testing.md`.
