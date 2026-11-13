# Endpoint UX — the platform beneath contacts-as-endpoints

Status: **design**. Model background: [`communication-model.md`](communication-model.md).
Contact card exchange: [`contact-exchange.md`](contact-exchange.md). Web content
and WebMCP: [`webmcp-bridge.md`](webmcp-bridge.md), MCP control tiers:
[`mcp-control.md`](mcp-control.md).

This doc specifies the **inner-application infrastructure** for treating idfon
as a hybrid phone-browser: a browser for people, places, and things. It does
not normativize what each endpoint type does — endpoints are expected to
mediate, surprise, and even exasperate by design. What the platform must
guarantee is the machinery those behaviors run on.

## 1. Core idea

A contact is an identity plus a set of **typed endpoints**. An endpoint is a
URL (`idfon://…`, `https://…`, a stream ticket, …) with metadata: a type
(`phone | stream | page | video | thing | agent | …`, open set), a label, and a
`primary` marker. Tapping a contact dispatches to the primary endpoint's
default affordance; everything else is infrastructure the affordance runs on.
An endpoint may also address a **collection** (a folder) or a **static
resource** (a file — a media file, an OPML outline, an RSS feed); §2.6 covers
how those dispatch.

The endpoint record extends the vCard ticket (`X-IDFON-TICKET`) carried by
[`contact-exchange.md`](contact-exchange.md):

```text
type      open set of endpoint types
url       the endpoint address
primary   zero-or-one per contact (exactly one tap target)
label     optional display name
```

Validity: zero `primary` opens the generic detail view; two or more make the
record invalid and it is admitted only to the detail view (inert), never
dispatched. Unknown types get the generic detail view — never a guess.

## 2. Platform pieces

These are the parts the app must build once and every endpoint type reuses.

### 2.1 Endpoint registry and dispatch pipeline

One declarative mapping `type → handler + default affordance`, shared verbatim
by the UI and the agent (§2.5) so they cannot drift. A new endpoint type is a
registry entry plus a handover surface — no changes to tap handling, contact
lists, or agent wiring.

Tap flow, in order:

1. resolve the contact's `primary` endpoint (§1 validity),
2. trust gate (§2.2) decides how much friction the dispatch gets,
3. the type's handler mounts its handover surface (§2.3) with the affordance it
   requested — note *requested*: grants and local UX policy
   ([`communication-model.md`](communication-model.md) §Local UX policy) decide
   whether and when the affordance's effects actually happen. The platform
   mediates; it does not decide on the user's behalf.

### 2.2 Trust and friction store

Endpoint type is a *claim* by the contact; observed behavior is *evidence*.
The platform keeps a per-endpoint (and per-origin) interaction cache:

- declared metadata (type, issuer, age of the claim),
- history of past interactions (what happened on dispatch: what loaded, what
  ran, what the user did),
- a derived trust level driving **friction**.

Friction starts **high** for an unseen endpoint and **decays with use** as
trust builds: a first dispatch may present an inert preview or an explicit
confirmation; the hundredth dispatch of the same well-behaved radio stream
plays on tap. Friction gates *effects* (loading code, running tools,
actuating, announcing to third parties), not the screen the tap opens. Trust
is revocable — one bad interaction resets it. Cheap default: one bad
interaction raises friction; sustained good behavior lowers it.

### 2.3 Handover surfaces

A handover surface is the container a handler mounts in the detail view:
audio player, page host, video player, controls panel, chat. The contract the
platform guarantees each surface:

- **lifecycle**: mount/unmount, backgrounding, teardown (media stopped,
  nothing survives the surface),
- **state ownership**: playback/interaction state is the user's to stop at any
  time; the agent may drive the surface but never hold it,
- **agent hooks**: the surface exposes its verbs to the agent through the same
  registry (§2.5),
- **uniform chrome**: back, share, endpoint list, trust indicator — the
  phone-browser frame around every endpoint.

### 2.4 Pages and WebMCP

A `page` endpoint hands the surface to the page, which gains agency inside the
app. WebMCP tool exposure runs over the bridgehead in
[`webmcp-bridge.md`](webmcp-bridge.md) with its security measures and separate
`ui.serve`/`ui.tools` grants (agent→page and page→native remain distinct
directions); agent-side invocation is scoped by the MCP control tiers
([`mcp-control.md`](mcp-control.md)). The trust store (§2.2) applies to page
code and tools like any other endpoint effect.

### 2.5 Agent surface

The agent operates endpoints through verbs over the same registry: open,
play, stop, invoke, subscribe. Verb classes map to MCP control tiers once
(§2.4), not per endpoint type. The agent may choose among a contact's
endpoints and drive mounted surfaces; it gets no dispatch path the user
doesn't have, and no behavior rule outside this table.

### 2.6 Collections, files, and the viewer registry

Folders and files are ordinary endpoints; what they need is a **viewer
registry**: content type → viewer, parallel to the type → handler mapping in
§2.1. Content type is sniffed from the resource (URL suffix, headers, magic
bytes); a declared type in the endpoint record is a claim under §2.2.

- **Collection (`folder`)**: the handler mounts a **content screen** — the
  list of the collection's entries. Each entry dispatches through the same
  pipeline (§2.1), so a folder of feeds, files, and people browses exactly the
  way contacts do. Trust attaches to entries by their own URL/origin.
- **File (`file`)**: the handler mounts the viewer registered for the content
  type. Viewers are handover surfaces (§2.3) and reuse freely: the WKWebView
  surface renders OPML/RSS as pages, native players play media files, a
  generic renderer shows text.
- **Endpoint-bearing formats**: OPML, RSS, and kin are collections whose
  entries carry URLs. A viewer may admit entries as endpoints (subscribe)
  through the normal contact-admission path — the format is a folder of
  people, places, and things.
- **Unsupported types**: the generic file surface — metadata, save/share, and
  the agent verbs (§2.5) — never a guess at rendering.
- **Editors**: an editor is a viewer with a write path — same registry, keyed
  by the same content types (see §2.7).

### 2.7 Viewers, editors, and agent artifacts

The viewer/editor registry is also the app's **artifact capability matrix**:
the set of content types with a viewer or editor is exactly the set of
artifacts idfon agents can meaningfully produce, transform, and iterate on.
An artifact with no viewer is dead bytes; with one it lands, plays, renders,
subscribes, or opens for hand-fixing. Each viewer added lifts agent diversity
alongside human browsing — one registry entry, both surfaces.

- Agent-authored artifacts and agent edits dispatch like any endpoint effect:
  trust gate (§2.2), tiered verbs (§2.5), handover-surface contract (§2.3) —
  the agent drives the editor, the user holds the state and can hand-fix in
  place.
- Edit proposals from agents are reviewable (diff/preview) before they touch
  the artifact; the editor is where the user says yes or no.
- Creating a new artifact type means registering its viewer/editor and its
  verbs — the only extension point the platform needs for growing what agents
  can make.

## 3. Default affordances (sketch, not law)

| `type`  | tap opens             | notes                                  |
| ------- | --------------------- | -------------------------------------- |
| `phone` | call screen / CallKit | rings; never silently connects         |
| `stream`| audio player          | may start before navigation completes  |
| `page`  | page host             | hands control to the page (§2.4)       |
| `video` | video player          | like `stream`                          |
| `thing` | controls panel        | actuation is a tiered verb (§2.5)      |
| `agent` | conversation          | summons subject to local policy        |
| `folder`| content screen        | entries dispatch through the pipeline  |
| `file`  | viewer/editor by type | reuse: WKWebView for OPML/RSS, players for media |

These are starting hints for handlers. Trust (§2.2), grants, and local policy
override them; a type's real behavior is its handler's business.

## 4. Follow-ups (in order)

1. Schema landing: extend the ticket JSON in `vcf.rs` with the endpoint record
   and version it.
2. Trust store persistence + friction policy (initial conservative defaults).
3. Viewer/editor registry (content type → viewer|editor) + generic file
   surface; OPML/RSS subscribe flow.
4. Handover-surface contract as code; wire the iOS detail view
   ([`ios-ui-design.md`](ios-ui-design.md) §5.1) to the registry.
5. Agent verbs → MCP control tier mapping.
