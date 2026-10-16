# iOS UI design (structural)

Status: **partially implemented** (branch `ui-refactor`) — the structural
core (§4–§7, §9, §11/D20, §12, §5) is built; the tail of §19 lists exactly
what remains.
Scope: the iOS app's screen structure, navigation, list/chat anatomy, sessions, and
identity UX. Visual system and the Live Activity Bar state machine remain in
`ui-design-notes.md` (that doc wins on bar/overlay visuals; this doc wins on
structure). The macOS adaptation is §13 (single-window, decided).

## 1. What the app is

idfon is a phone and a messenger fused into one app — and more: contacts can be
agents (coding agents, assistants), rooms hold realtime sessions, and the app is
usable both "phone-like" (start from who you want to reach) and "messenger-like"
(start from what arrived). The design must integrate two stock UX philosophies
without siloing them:

- **Phone app**: contact-centric. The people list is the substrate; tabs are
  lenses over it. The item's primary action is the call.
- **Messages app**: conversation-centric. Entry is recents; a row previews the
  last message; tap opens the chat.

idfon resolves this with three tabs (perspectives) that all converge on the chat
screen.

## 2. Principles

| # | Principle |
| --- | --- |
| P1 | One shell, three perspectives (Contacts / Messages / Projects). Every path converges on Chat. |
| P2 | Inline-first. Anything that can appear inline without conflict does; only payloads that earn their own space get a detail screen. |
| P3 | Activity intervals ("sessions" in the loose sense) are display grouping, not data objects. Live calls are the one crisp boundary hint. |
| P4 | Semantic zoom on the timeline: live → day → week → month → year. Drill expands; zoom collapses. Clutter is the enemy. |
| P5 | Agents are peers with a call button, not a settings feature. |
| P6 | A project is a typed chatroom (custom icon + metadata such as repo address), with users and agents as members. |
| P7 | Presentation derives from context: size × density × tool-needs → inline \| thread \| detail. |
| P8 | Each lens defines its rows' primary verb (Contacts → call-first, Messages/Projects → open). |
| P9 | Identity is implicit in normal flow but continuously legible and reachable from the symptom. Never the invisible-and-consequential buried setting. |
| P10 | Chrome is minimal and minimizable: long lists get the screen; the tab bar yields to scrolling. |
| P11 | Shape behavior through actions, never help text or warning copy. Gates, defaults, and constrained choices instead of prose. |
| P12 | When lost, follow iOS Phone, Messages, and Slack — the most commonly used phone/messaging apps on the platform, hence the most familiar patterns to users. Where this doc is silent, copy their behavior. Tie-breaker: equally good options → pick the one matching those apps. |

## 3. Object model (what the UI assumes)

```
Identity (Work/Personal/Private presets, user-created up to a cap; all
 identities are live at once — D20)
  └── Contact relationship (one identity per contact; never linked across identities)
        ├── human contact
        └── agent contact (permissions granted at add time; may delegate to sub-agents)

Room  (typed: chat | project; project carries icon + metadata, e.g. repo)
  ├── membership: users, agents, temporary guests ("deputies", bound to granter's lifecycle)
  ├── async session: messages, artifacts (the room's baseline)
  ├── live session: realtime call streams (audio/video; runs in parallel)
  ├── agent session: pi-pocket chat / ACP / terminal-driven TUI (runs in parallel)
  └── display grouping: bursts → threads, activity intervals → buckets (derived, not stored)
```

- A live call is a **session inside the room**, not a parallel universe: the room
  is where messages and artifacts flow asynchronously; the call is the realtime
  session within the same context.
- "Sessions" in the derived sense need no derivation engine: explicit events
  (calls) mark boundaries; everything else is a display concern (P3).
- **Tasks** (Codex-style active tasks under a project) are a future, deferred
  concept. See §16.

## 4. Shell

Three tabs, launch into the last used one:

```
[ Contacts ] [ Messages ] [ Projects ]
```

- **Tab bar**: minimal and minimizable on scroll so long lists stay uncluttered
  (P10). The stock minimize-on-scroll behavior (`tabBarMinimizeBehavior`) is
  iOS 26+; at our iOS 17 deployment target the tab bar is static — do not build
  a custom hiding tab bar (P12).
- **Filters**: a segmented toggle strip on list screens where useful — initial
  set `All | Favorites | Recents`, extensible with more segments. Favorites and
  Recents are filters, not tabs or sections (D7).
- Favorites = pinned contacts; Recents = interacted-with, most recent first.

## 5. List screens

### 5.1 Contacts tab

Row anatomy: avatar · name · **identity label** (which identity this relationship
uses — always visible, A8; informational — every identity is live, D20) ·
optional status.

- **Tap (default)**: opens the **chat screen** with the conversation's
  messages; the person screen (§6) is on the chat's title tap (D1, revised
  2026-10-14 after manual testing).
- **Tap (instant-call contacts)**: contact metadata can mark a contact as
  instantly callable (e.g. emergency contacts). Tap then **navigates to the chat
  screen and auto-starts the call** — the user sees navigation, then the call
  begins as the room's live session. No confirmation, no warning copy (P11).
- **Row Call button** (left of the chevron): dials — the same as tapping the
  row, then pressing the chat's call button.
- **Chrome (2026-10-14)**: Edit left-most, `+` top-right; the filter strip
  leads with **Recents** (the default filter); the Contacts title sits in the
  nav bar like Messages; the Edge/Relay settings and the identity picker are
  hidden until their purpose is decided.
- **Edit mode**: pin/unpin; delete; drag to reorder pinned. Nothing else
  (stock-app restraint).
- No cross-identity anything: the same human under two identities is two
  contacts; the UI never suggests they are one (A9).

### 5.2 Messages tab

Row anatomy: room identity (avatar/name) · **last-message preview** · timestamp ·
session indicators (e.g. a live-call badge when the room has an active session).

- **Tap**: opens the chat screen (lens verb = open, P8).
- **Edit mode**: select → mark unread / delete. That is the whole verb set.

### 5.3 Projects tab

Row anatomy: project icon · project name · **latest-message preview** ·
timestamp. Same row vocabulary as Messages (one row template app-wide).

- **Tap**: opens the project's chat screen — a project **is** its chatroom (D6);
  there is no channel list, no extra level.
- **Deferred (D5)**: a project row expands **in place** to show active tasks;
  selecting a task navigates to that task's chat log. Non-blocking constraints on
  today's UI: row layout must tolerate growing an expansion region later, and
  "task" must not be baked into the room model.

### 5.4 Flows and states the lists need

- **Empty / loading / error** on every list screen: first launch (no contacts
  yet), daemon not ready (retry when ready), load failure.
- **Add contact**: the flow that fixes the relationship's identity (§11) and,
  for agents, grants permissions (A7). Entered from the Contacts nav bar.
- **Add project**: name + icon + optional repo metadata (P6). Entered from the
  Projects nav bar.
- **Search** already exists (`PeerListViewController`) and stays on all list
  screens.

## 6. Person screen (contact hub)

Derived from the ledger (marked for review at implementation):

- Header: avatar, name, **identity label** (tap → identity detail, P9 "reachable
  from the symptom").
- **Primary action: Call** (big, thumb-reach). Secondary: **Message** → chat,
  **New session**.
- Agent contacts: permission scope shown here — decided at contact-add time
  (A7). Sub-agent delegation visibility lives here.
- Deputy grants (temporary guests this contact brought in) are managed here;
  they die with the granter's lifecycle (A6).
- Shared artifacts/transfers with this contact: reachable from here.
- The person screen already exists in code (`ContactDetailViewController`) and
  carries rename, speech-engine and turn-mode settings — those stay here.

## 7. Chat screen

The primary surface of the app (P2). Same screen for chats and projects; a
project's nav-bar title shows the project icon + name instead of a person.

### 7.1 Nav bar

```
Idle:     ‹ Back   [avatar] Name                       [call] [⋯]
Calling:  ‹ Back   [avatar] Name                 [call•active] [⋯]
In call:  ‹ Back   [avatar] Name                  [hang-up] [⋯]
Incoming: ‹ Back   [avatar] Name                [call·disabled] [⋯]
Blocked:  ‹ Back   [avatar] Name                [call·disabled] [⋯]
```

- **Back** → the list you came from.
- **Title = avatar + name, tappable → person screen** (the title is navigation,
  and identity is visible where you are — P9). The compact trailing cluster
  gives the title area more room.
- **One call button, states per the diagram (D8)**: idle `call` → `calling`
  (highlighted; tapping it cancels — the button reads hang-up from the moment
  the call goes out) → `hang-up` once established. When a call isn't
  available the button shows **disabled, never hidden**: an incoming ring
  (the Bar carries Answer/Decline), a call with another peer active
  elsewhere (the gate is visible, not absent — P11), and rooms/projects
  while room calls are disabled (docs/chatrooms.md). Rooms/projects get the
  same button: a live call is a session inside the room (§3). **Audio-first by
  design (D14)** — it relieves the stress of being seen unprepared; the user
  turns video on when ready (the live-call bar's camera toggle).
- **Overflow menu (`ellipsis.circle`)** at the far right — ☰ reads as a nav
  drawer (P12): **New Session** (starts a new thread in the chat — top-level,
  never nested in the current thread), **Share Screen** (starts a screenshare
  stream immediately; while sharing, it appears in the live-activity panel as a
  bar with a stop button — D18), **Chat Settings** (1:1: person settings,
  shared gallery, mute; room: members, invite, leave, gallery — §14). The
  overflow is the stable right-edge anchor — it never changes appearance —
  while the state-changing call button sits to its left and visually protrudes.
  Stable edge, changing button.
- **Live-call bar controls (D2)**: a **mute toggle** (mic on/off — the most
  urgent in-call switch, never buried in a route cycle), a **route button**
  (`AVRoutePickerView`/`UIMenu` listing the routes available right now —
  iPhone, Headphones, Speaker, CarPlay…; routes change at runtime, a fixed
  cycle cannot), a **camera button that toggles the video stream on/off**, and
  a **gear button** for advanced audio/video settings. Same row as the call
  stats, above the active live-activity (tray) rows. `ui-design-notes.md` §3 is
  superseded on
  this point: nav = start/stop the call, the bar = operate it.
- No "request screenshare" verb anywhere — a text message does that job (D3).

### 7.2 Vertical anatomy

```
┌──────────────────────────────────────┐
│ ‹ Back   [avatar] Name               │ nav bar (§7.1)
│ [● Live call ··· 03:42 · audio] [mic][route][cam] │ session bar: stats + A/V
│                                        │ toggles (D2) + tray rows below
│ ┌──────────────────────────────────┐ │
│ │ [Mar 3 – Mar 9 · 42 msgs, 1 call,│ │ bucket cards — older ranges (P4)
│ │  2 files]                        │ │
│ │ [Feb 24 – Mar 2 · …]             │ │
│ ├──────────────────────────────────┤ │
│ │ simple msg      simple msg       │ │ inline items (A5: a handful)
│ │ ▸ thread (7 msgs · 2m)           │ │ burst → thread item (P7)
│ │ ▸ agent session (3 turns · 4m)   │ │ agent work collapses to a thread
│ │ [artifact card]                  │ │ inline if simple, else detail
│ │ simple msg                       │ │ newest at the bottom
│ └──────────────────────────────────┘ │
│ [ + ]  Type a message…      [mic/send]│ composer (swapped slot)
└──────────────────────────────────────┘
  (tab bar hidden while in chat — D12)
```

- Newest at the bottom; agent threads append turn-by-turn at the end (user
  prompt → agent response, Codex style).
- The live-call bar sits under the nav bar while a call is active. Its row
  carries **call stats + mute/route/camera controls** (D2), with the transfer
  tray rows below it; starting and ending the call stays in the nav bar. Agent
  sessions are thread items (§10), not bars.
- **Passive minimize (D19)**: when the user scrolls up into older messages, the
  whole live-activity panel (call stats + activity items — our name, not
  ActivityKit's Live Activities) minimizes to the right-edge compact pill.
  Pill visuals and verbs follow the existing compact pill (`ui-design-notes.md`
  §6 — that doc wins on overlay visuals). Tapping the pill expands it; it never
  auto-re-expands on scroll (iOS convention). Mechanics: the pill **floats over
  content without safe-area-inset churn** (`applyContentInset` must not change
  on minimize — moving content re-triggers the scroll); compensate contentOffset
  if an inset change is unavoidable; the expand/collapse animation is
  interruptible.

### 7.2a Timeline visual grammar (D11)

The prototype's variant A won as the base (mockup on the throwaway branch
`prototype/ios-ui-chat-timeline`, not on the main line — variant-A screenshots
still owed, §18), with extensions:

- **Alignment shows the side, not the sender.** Our side right, their side left.
  This generalizes from 1:1 to **split chats** — two or more parties per side
  (e.g. us + our agent vs. them + their agent).
- **Sender identity is hidden in 1:1 chats.** When a side holds multiple
  identities, every message from that side shows **avatar + nick**.
- **Detail level sits between the prototype's A and B**: each message carries a
  small provenance caption (role + modality — e.g. `Agent · spoken`,
  `You · typed`) and a timestamp. Variant C's nested container detail is
  rejected: it becomes noise over the main text.
- **Color-coded card edges** (adopted from B): non-message cards carry a 3 pt
  left edge coding their kind at a glance — thread = blue, agent session =
  orange, artifact = green (semantic system colors so Dark Mode works; the edge
  clips to the card's corner radius). The edge is decoration, never the only
  signal — every card also carries a kind icon (§7.6). The card body stays
  light and quiet.
- **Ambient datelines**: slim, low-contrast date separators between days so the
  timeline's dates are scannable without relying on bucket cards.
- Non-message items (threads, agent sessions, artifacts, buckets) keep the
  light-card rhythm of A.

### 7.3 Timeline density rules (P7)

| Condition | Treatment |
| --- | --- |
| Small simple message, sparse traffic | Inline |
| Burst: several messages within a short window | Thread item → thread detail |
| Today / currently active range | Expanded inline |
| Older | Day → week → month → year bucket cards |
| Large payload, or needs special tools (web content, big images, terminal) | Detail screen |
| Live call / agent session active | Call bar inline (agent sessions are thread items, §10); collapsible via D19 |

Starting heuristic values (A3: keep it dumb and tunable):

- **Precedence** (the rules overlap; this order decides): recency guard →
  burst collapse → bucket cards. A burst within today can still collapse to a
  thread item; today never gets bucket cards; only ranges older than today do.
- **Burst** ≈ 5+ messages within 10 minutes → collapses to a thread item showing
  count + duration + last line. **Recency guard**: the collapse only fires on
  the older part of an exchange — "currently reading" = the rows on screen plus
  the last 10 minutes; that burst stays expanded.
- **Retroactive regrouping (D17)**: a message that stands alone inline can be
  pulled into a thread later, once concentrated activity warrants classifying
  it as part of that thread. Grouping is derived and can change over time; the
  underlying messages never move (P3) — only their presentation does.
- **Buckets**: today expanded; 1–7 days back → day cards; 8–30 days → week
  cards; 31 days–a year → month cards; older → year cards.
- Bucket card = **date-range label + short summary** (message count, calls,
  files, key events) — enough to recognize "when we talked about X" (A2).
- Do not inline unbounded history: cut for available room and probable intent;
  the user drills in when a bucket matters (P4).

### 7.3a Tuning the heuristics (minimal pass now, data-driven tuning deferred)

Do the cheap, high-value part now; the empirical pass waits for usage data:

1. **Conservative defaults — show over hide.** Under-collapse beats over-collapse:
   users tolerate clutter more than hidden content (matches P12 stock behavior —
   Messages collapses almost nothing). Buckets only bite well in the past.
2. **Recency guard** (§7.3) — the one rule that prevents the worst failure
   (content collapsing under the reader). Cheap and already specified.
3. **All knobs as named constants in one place** — no config UI (P11), but
   retuning later is a one-line change, not a hunt.

Deferred until there is data and in-use analysis: per-room adaptation,
telemetry, and any movement of the actual numbers.

Three knobs for that later pass; one global set first:

| Knob | Default | Too low / too aggressive | Too high / too passive |
| --- | --- | --- | --- |
| **Burst window** (N msgs / M min → thread item) | 5 / 10 min | a lively conversation hides behind one card | the timeline clutters with every exchange |
| **Bucket ages** (day/week/month/year thresholds) | today inline; ≤7d → day; ≤1y → week/month; older → year | drilling in constantly | scrolling past walls of text |
| **Inline budget** (A5) | 5 simple items | content escalates to detail screens too eagerly | screens get crowded |

Target state: per glance, ≤5 simple items and at most one card per date range. Tuning signals: drill-in rate (too much collapse), scroll-past rate
(too little), and A4 zoom/navigation events as opt-in telemetry.

### 7.3b Scroll stability (timeline engine)

Grouping changes after the fact (D17) and older buckets prepend; without these
rules the timeline jumps and loses the reader's place (today's
`syncMessages` → `reloadData()` + scroll-to-bottom does exactly that):

- Diffable data source with stable item IDs (thread ID = its first message ID).
- Keep the scroll anchor across prepends and regrouping (compensate
  contentOffset); never regroup rows that are on screen.
- Never auto-scroll when the user has scrolled up — show a **jump to latest**
  button instead (P12: Messages).
- "Return to the exact position" (§9) anchors on a message ID, not an offset.

### 7.4 Drill and expansion (A1)

- Drill down **expands in place** when the detail is small enough to not earn a
  screen. Full screen only when the payload's type/size demands it.
- The same size × density × tools test applies at every zoom level (it is one
  heuristic family).
- Zoom is user-driven most of the time; the app or an agent may drive it **with
  permission** — which makes the view (scroll position, zoom level, focus)
  addressable state, the same way a call can pull the screen to fullscreen (A4).

### 7.5 Composer

`[ + ]` attach (files/artifacts, photos, voice memo, invite agent) · text field ·
**one swapped mic/send slot** — empty text → mic, typed text → send, as in
Messages (the code already swaps) (D13). Recording is **tap to start, tap to
stop, then review** (stop / discard / play / send — the code's model), not
hold-to-talk. Keep the verb surface small (P11): what the room can accept is
offered, nothing more.

**Composer target (D21)**: the composer always posts to the room; a thread
detail view (§8) has its own composer that posts into that session. With the
keyboard up, the call panel stays minimized and the timeline yields the space.

**Text-first semantics (D15)**: sending a text message just sends — it requires
no call and starts no call. Recorded audio messages are messages (artifacts).
Live voice/video is the **call side channel** — like live streams and file
transfers — a parallel session in the room (A1), not a mode the composer
enters.

The **tab bar is hidden while the chat screen is open** (D12): even minimized it
would float over the composer, which owns the bottom edge. Back returns to the
list and the tabs.

### 7.6 Accessibility & Dynamic Type

- Card kind is never color-only (§7.2a): every colored edge also carries a kind
  icon (Differentiate Without Color).
- Mute/route/camera buttons carry `accessibilityValue` announcing current state
  ("Muted", "Video off").
- Collapsed thread and bucket cards get VoiceOver labels ("Thread, 7 messages,
  2 minutes") and a custom expand action.
- Dynamic Type: at accessibility sizes the nav title truncates before the
  trailing buttons do; timeline rows have no fixed heights.
- Tap targets ≥ 44 pt — the composer's mic/send affordance is 36 pt today and
  must grow (hit area at minimum).
- Reduce Motion: the D19 pill expand/collapse becomes instant or cross-fade.

## 8. Thread detail

A burst-derived or session-derived thread opens as a **thread detail view**:
the alternating turns (user prompt → agent response, or chat messages), full
size, newest appended at the end. Small threads expand in place (§7.4); long
agent/terminal logs get the detail screen. ACP panels and terminal-driven TUIs
are special agent-session renderings on this surface. **Threads never nest** —
every thread is top-level in the room timeline, and "New Session" starts
another top-level thread (D16) by writing the room's one **stored** grouping
boundary: a `session_start` marker event (D21). All other grouping stays
derived (P3/D17), and burst logic never merges across the marker.

## 9. Detail screens

Earned, never chosen: web content (`EdgeWebView`/`SandboxedArtifactWebView`),
large images/media, terminal/ACP sessions, artifact detail. Every detail screen
returns to the exact timeline position it came from.

## 10. Sessions in the room

| Session | Modality | UI |
| --- | --- | --- |
| Baseline chat | async | the timeline itself |
| Live call | realtime streams | call bar inline (ring/answer in the Bar today — §12), expandable to fullscreen `CallViewController`; controls per D2 (this doc supersedes `ui-design-notes.md` §3) |
| Agent session (pi-pocket) | async/turn-based | thread item → thread detail |
| Coding agent (ACP / terminal TUI) | streaming | thread item → detail screen |
| Transfer | streaming | inline progress row (`Session Tray`, `ui-design-notes.md` §4) |
| Screenshare | streaming | starts from the overflow menu's Share Screen item (D18); while active, a live-activity bar with a stop button |

Concurrent sessions are normal (a call runs alongside messages and agent work);
inline budget ≈ a handful of simple items at once — anything needing lots of room
escalates (A5).

## 11. Identity

- **First launch creates three preset identities**: **Work** (work activities),
  **Personal** (family and friends), **Private** (everything else, including
  public things the user does not want tied to work or personal life). Renamable
  (D4).
- **All identities are live at once (D20)**: one merged contact list, every
  line reachable regardless of what the user is doing. Identity is chosen **when
  adding a contact** (relationship time) and does not change after that; there
  is no app-wide "active identity" to switch (the code's global switcher and its
  tab resets go away — §19).
- **Every contact shows its identity** (A8) — informational, not a mode
  indicator.
- **No cross-identity linking** — hard invariant (A9). No contact merging, no
  cross-identity suggestions; agents carry only the context of the identity they
  act under.
- Users may create identities **up to a cap** (possibly permission- or
  payment-gated) — no minting hundreds of identities (A10).
- Management UI (rename, create, delete) is rare activity and lives behind the
  identity surfaces themselves — the Contacts nav-bar identity button today
  (`IdentityPickerViewController`, reworked per D20) — linked locally wherever
  identity shows ("reachable from the symptom", P9). No help text; the links
  are the affordance (P11). No dedicated Settings screen is added for this
  (§5.4).

## 12. Incoming calls

Incoming calls ring **in the Live Activity Bar** with Answer/Decline — this is
what ships today (`CallKitIncomingPresenter.isAvailable == false`). Answer →
the Bar opens the room's chat thread with the call running as its live session
(`LiveActivityController`); the fullscreen `CallViewController` is reached only
by expanding the inline video bar. Per `callkit-integration.md`,
`IncomingCallRouter` routes per-channel (`call_mode`: `bar` | `call_kit`) and
both presentation paths land in the room's live session on answer — the
CallKit path (gated on `CallKitIncomingPresenter.isAvailable`) would add the
full-screen ringing screen on `.incoming` and open the room from
`CXAnswerCallAction`.

**Schedule**: CallKit integration comes **after the UI refactor and TestFlight
approval** — though the code can be added at any time. Until then the Bar path
presents incoming calls.

## 13. macOS adaptation (D10)

**Single window.** One main window; it will be a while, if ever, before there are
enough users to complain about that. What matters is that surfaces stay
detachable *in design* so multi-window is cheap if it ever earns its keep.

- **Layout**: two-pane — a sidebar (Contacts / Messages / Projects + the same
  segmented filters as iOS) and the chat surface on the right. P10 becomes
  "sidebar collapsible".
- **Window-host-agnostic chat surface**: the room surface (nav row + session bars
  + timeline + composer) is self-contained and assumes nothing about being the
  only visible surface. It hosts in the sidebar stack today, in its own window
  later without rework.
- **App-level, not window-level**: the live activity overlay (cf.
  `ui-design-notes.md` §6), notifications, and A4's view-addressability must not
  be owned by any chat surface. The existing window-docked `OverlayPanel`
  (borderless `NSPanel`, sized to the bars, top spacer) satisfies this in a
  single window; only a true multi-window future would demand app-level
  adoption.
- **If multi-window ever arrives**: rooms in their own windows, detachable
terminal/ACP panels (they want width), and windows as identity compartments
  (a Private window beside a Work one — A9's wall becomes spatial).

### Mapping to the existing mac app (per `mac-architecture.md`)

The current shell is already single-window, so this is adaptation, not rebuild:

| Existing | New design |
| --- | --- |
| `SidebarViewController` (identity/status + actions) | stays; the three perspectives (Contacts / Messages / Projects) become its sections, identity stays visible here (A8) |
| `PeerTabsViewController` (Favorites/Recents/Contacts tabs) | tabs **dissolve into the D7 segmented filters** inside the Contacts section — same data, filter strip instead of tab bar |
| `DetailContainerViewController` → `ChatViewController` | this pair is the **window-host-agnostic chat surface** and the future detach unit; it assumes nothing about being the only visible surface |
| chat header idle actions (`Call`, share video, peer details) | becomes the nav-bar equivalent of §7.1: title (tap → person screen) + `[new session] [call] [⋯]` — same trailing order as D8 (call button left of the stable overflow); `.watching` remains mac-only (screen-watch verb, no iOS equivalent) |
| `OverlayPanel` → `LiveActivityBar` | unchanged mechanics (docked under the title bar, height → top spacer); `ui-design-notes.md` wins on visuals; no End verb in compact pill stays mac behavior |
| right-click Rename…/Delete… on peer rows | stays — the tiny edit surface of P11 restraint, matching stock patterns |

mac has no navigation stack today; the sidebar → detail split is the one
navigation move, which is exactly the Phone/Messages/Slack layout family (P12:
Slack is a sidebar + surface app on the mac).

## 14. Artifacts at scale

Voice use makes artifacts the **primary payload**, not an occasional card: voice
can carry neither large text nor images, so agents answer with artifacts and the
timeline fills with them. `idfon-artifacts.md` is authoritative for the artifact
model (cards, detail-by-kind, sandboxed web view, annotate→ask selectors,
immutable revisions, `metadata.spoken`/`alt`); this section is the UI
consequences of volume:

- **Artifact-aware timeline**: the segmented filter strip may extend into chats
  (e.g. All | Files | Images | Links) — **undecided**, see §18. Bucket summaries
  already count artifacts ("2 files", A2).
- **Revision grouping**: revisions (`metadata.revision_of`) collapse into one
  card with a revision count — no card per revision.
- **Gallery entry**: a per-room / per-person artifact view (on the person screen
  and in chat settings) so "that image from last week" is findable without
  scrolling the timeline.
- **One interaction model for humans and agents**: humans annotate→ask (reference
  chip in the composer), agents resolve the same selectors (`read_reference`).
  Seamless yet robust means both sides share the interaction surface, not that
  each gets its own.
- Cards stay compact (A5): an artifact card is a "simple" inline item — title,
  kind icon, small preview when local. Anything needing real room escalates per
  A1.

## 15. UI production: UI-specialty agents (v0)

**Deferred — separate track.** Not part of the UI refactor v0; move this
section to its own doc when the pipeline work resumes (its account-specific
details don't belong in an implementable UI spec).

Models differ in UI savviness, so UI generation is a **benchmarked pipeline**,
not a trusted reputation:

- **v0 (verified working)**: `POST https://api.v0.dev/v2/chats` with
  `V0_API_KEY` (server-side only). Models `v0-mini | v0-pro | v0-max |
  v0-max-fast`; streaming via `chats.createStream()`; attachments for design-doc
  snippets or screenshots; docs index at `v0.app/docs/llms.txt`. It generates
  web apps — a fit for idfon's web-content surfaces (`EdgeWebView`, sandboxed
  views); UIKit/SwiftUI screens remain hand-built.
- **Vercel AI Gateway** (`AI_GATEWAY_API_KEY`, 408 models) for candidate
  comparison — note v0 models are *not* exposed on the gateway for this account.
- **Benchmark**: fixed task set ("render the person screen of §6", …) run
  through identical prompts per candidate; screenshot-capable models
  (e.g. `gemini-2.5-flash-image`, `gemini-3-pro-image`) critique the rendered
  output. The pipeline is the asset; models are swappable.

## 16. Deferred: project tasks (D5)

Codex-style: a project row expands in place to show **active tasks**; selecting a
task opens its chat log. Deferred while the agentic side is being designed. The
design leaves no blockers:

- Project rows keep layout tolerance for an expansion region.
- "Task" is not part of the room model; when it lands it likely derives as a
  thread/session grouping (P3/P7) with its own chat log.

## 17. Decision ledger

| ID | Decision |
| --- | --- |
| D1 | Person-row tap: default opens the chat (the person screen is on the chat's title tap; revised 2026-10-14 after manual testing); a row Call button dials the chat's call; contact metadata may make a contact instantly callable (tap → chat + auto-call). |
| D2 | Call state lives in one nav button (call → calling/hang-up) beside a stable overflow menu; the live-call bar row carries call stats + a mute toggle, a route menu (the routes available right now), a video on/off toggle, and a gear for advanced A/V settings, above the tray rows. Nav starts/stops the call; the bar operates it. Mute is never a step in a route cycle. |
| D3 | No "request screenshare" feature — a text message does it. |
| D4 | Three preset identities (Work / Personal / Private) at first launch, renamable. |
| D5 | Project rows expand in place → active tasks → task chat log. Deferred; no blockers allowed. |
| D6 | A project is one chatroom screen; threads/sessions are the "chats" inside it. |
| D7 | Favorites/Recents are segmented filter toggles on list screens (room for more). |
| D8 | Nav bar trailing cluster: [Call/Calling/Hang-up] [overflow menu (`ellipsis.circle`)]; menu items: New Session (= new top-level thread in the chat; threads never nest), Share Screen (starts immediately), Chat Settings (1:1: person settings/gallery/mute; room: members/invite/leave/gallery). Overflow is the stable right-edge anchor; the changing call button sits left of it. |
| D9 | Inline budget: 5 simple items at once; anything needing lots of room is not simple (A5 restated as a rule). |
| D10 | macOS: single window, two-pane sidebar layout; chat surface stays window-host-agnostic and overlays app-level so multi-window remains cheap later. |
| D11 | Timeline visual grammar (variant A, **approved**): side-aligned bubbles (ours right / theirs left, extends to split chats); identity hidden in 1:1, avatar + nick when a side has multiple identities; message detail = provenance caption + timestamp (between prototype variants A and B); C's nested containers rejected as noise; non-message cards get color-coded left edges (thread=blue, agent=orange, artifact=green) and the timeline gets ambient datelines. |
| D12 | Tab bar hidden while the chat screen is open — even minimized it floats over the composer. |
| D13 | Composer carries a speech button for recorded audio messages. |
| D14 | Call modality is audio-first (kept): relieves the stress of being seen unprepared; video turns on when the user is ready. |
| D15 | Text-first composer semantics: a text message just sends (no call needed, none started); audio messages are artifacts; live voice/video is the call side channel, like streams and transfers. |
| D16 | Threads are top-level only — no nesting; "New Session" starts a new top-level thread. |
| D17 | Display grouping is derived and retroactive: a standalone message can later fold into a thread when activity concentrates; messages never move, only their presentation. |
| D18 | Screenshare lifecycle: start from the overflow menu's Share Screen item; while streaming it shows as a bar in the live-activity panel with a stop button. |
| D19 | Live-activity panel passively minimizes when scrolling up into history: collapses to the right-edge compact pill (`ui-design-notes.md` §6 wins on pill visuals/verbs), expands **on tap only** — no auto-re-expand on scrolling back down (iOS convention, P12). The pill floats over content without safe-area-inset churn; the animation is interruptible. |
| D20 | All identities are live at once: one merged contact list, every identity reachable simultaneously; identity is fixed at contact-add; no app-wide active identity. iOS runs the daemon endpoints for all preset identities (`IDFON_LAZY_IDENTITIES` stops gating them); the existing `default` identity migrates into the presets. |
| D21 | The only stored grouping boundary is a `session_start` marker event (written by "New Session"); all other grouping is derived (P3/D17) and never merges across the marker. Composer target: the room composer posts to the room; a thread detail view has its own composer posting into that session. |

Supporting answers: A1 escalate by detail type/size by expanding in place first;
A2 bucket = label + short summary; A3 dumb, tunable heuristics; A4 zoom/view is
agent-addressable with permission; A5 inline budget ≈ a handful (5) of simple
items; A6 deputies bound to the granter's lifecycle;
A7 agent permissions at contact-add (scope + moderation, no warning copy); A8
identity visible on contacts; A9 no cross-identity linking (invariant); A10
identity creation capped.

## 18. Open points

- Burst/bucket heuristic values: **minimal pass now** (conservative defaults,
  recency guard, named constants — §7.3a); data-driven tuning deferred until
  in-use analysis exists.
- CallKit integration is sequenced **after the UI refactor and TestFlight
  approval** (code may land earlier); the Bar path serves incoming calls until
  then.
- In-chat artifact filter strip (§14): keep or drop.
- D11's approved mockup lives only on `prototype/ios-ui-chat-timeline`; the
  variant-A reference screenshot is committed at
  `docs/mockups/ios-ui-timeline-variant-a.png`.
- §15's UI-production pipeline moves to its own doc when that work resumes.

## 19. Implementation mapping (current code)

The delta between the shipped iOS app and this design (from reading
`ChatViewController` and friends; for mac see §13's table):

| Existing (`ios/Idfon/`) | Design target |
| --- | --- |
| `ChatViewController` — one flat table + composer + memo/file/artifact/reference-chip + dial paths + remote-control envelopes (point/show/screenshot) | keep as the room surface; its flat table becomes the §7 timeline (thread items, bucket cards, density derivation). `syncMessages`'s `reloadData()` + scroll-to-bottom is replaced by the §7.3b engine. Mic/send already swap in one slot (§7.5). Reference chip, artifact open, and the envelope handlers already match the design. |
| `PeerListViewController` (hosts `ConversationsViewController` in the same file) | Contacts tab base — search, D7 filters, and tap → person screen (D1) are already here; add identity labels (A8). `ConversationsViewController` is the Messages tab base: it already mixes direct chats and rooms with unread counts; rows gain last-message previews and session badges. |
| `RoomsViewController` | Projects tab base; rows gain latest-message previews and the D5 expansion tolerance |
| `ContactDetailViewController` | grows into the §6 person screen (Call/Message actions already live here); keeps rename, speech-engine, turn-mode settings |
| `CallViewController` + `LiveActivityBar`/`Controller` | already the hybrid inline/fullscreen split (P2); `syncNavChrome`'s states (idle/active/incoming/blocked/rooms) become §7.1's table — rooms gain the call button; nav gains the D8 overflow menu; the bar row gains mute toggle + route menu + gear (D2). Answer already opens the chat thread (matches §12). |
| `AppNavigationController` / `OverlayWindow` | keep the Bar's top-inset mechanism; §7.3b/D19 forbid inset churn while scrolling |
| `ChatStore` (`recentChatIDs`, `unreadCount`, `markRead`) | backs the Messages rows; needs mark-unread plus the model deltas below |
| `ArtifactDetailViewController`, `SandboxedArtifactWebView`, `JSONRenderView` | already the §9 detail-screen machinery and inline render blocks |
| `OnDeviceAgentEditorViewController` | stays the agent-contact hub (§6's permission scope, A7) |
| `IdentityPickerViewController` | reworked per D20: identity *management* (D4 presets, rename, capped creation) — not a global switcher; `switchIdentity`'s tab resets and the "end the call first" alert go away |
| `VoiceCallRouting` / `IncomingCallRouter` | unchanged; §12's transition is their seam |

**Model deltas** (nothing in `Models.swift`/`chatrooms.md` carries these yet):

| Field | Owner |
| --- | --- |
| `Room.kind` (chat \| project), icon, repo metadata | `chatrooms.md` room model |
| `Room.pinned` (Favorites = pinned contacts) | contact/room model |
| contact `instant_call` flag (§5.1) | contact metadata |
| `session_start` marker event (D21) | room event log |
| message `side` for split chats (§7.2a) | derived from membership + "who is on which side" metadata |
| last-message preview (§5.2/§5.3) | derived in `ChatStore`, not stored |

New surfaces not in code: timeline grouping engine (§7.3–7.4 + §7.3b),
segmented filters (§4), the nav overflow menu + call-state button (§7.1),
artifact gallery/revision grouping (§14), empty/loading/error states and the
add-contact/add-project flows (§5.4).

**Implementation state (2026-10-12, branch `ui-refactor` — supersedes the
tables above where they disagree):** built = the shell (§4, incl. last-used
tab), the one row template and §5.1–5.3 rows (previews, session badge,
identity labels, Favorites/D7 pins + edit-mode reorder, instant-call tap),
§5.4 states + add-contact, §6 person screen actions + instant-call flag,
§7.1 nav chrome (incl. the D2 bar row: mute/route/camera), §7.2a/§7.3–7.4
timeline engine + D11 grammar + §7.3b scroll stability, D19 passive pill
minimize, §7.6 (card VoiceOver labels, 44 pt composer), §9, D21
(`session_start` markers + New Session, with mac parity), identity (§11 +
D20 end-to-end: presets, `default`→Personal migration, cap, management on
both apps, relationship-routed sends), the `pinned`/`instant_call` model
deltas, §14 (revision grouping + the artifact gallery, entered from the
person screen), and P6 (the `Room.kind`/icon/repo model + Add-project +
project icons in rows and the chat title).
**Still open:** split-chat `side` (needs the "who is on which side" metadata
design); §7.1's Share Screen (D18) and the D2 gear (both lack a
backend/surface); §8 thread detail + §10 agent sessions (unmodeled session
kinds); the §13 mac layout pass (sidebar three-perspective sections,
chat-header `[⋯]` overflow cluster — the segmented strips, identity labels,
and New Session are in); CallKit (sequenced later, §18).
**Decided (2026-10-12):** calling a room is a supported capability — this
doc's §7.1 stands and `docs/chatrooms.md`'s "voice is 1:1 only" exception was
wrong (now corrected). The live-call handler's room refusal is a **temporary
disable** until the multi-party details land; the room call button shows
**disabled** meanwhile.
