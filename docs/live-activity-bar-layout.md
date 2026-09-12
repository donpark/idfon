# Live Activity Bar — UIKit Layout Spec

Implements `docs/ui-design-notes.md` §2–§4, §6. Code: `ios/Idfon/LiveActivityBar.swift`
(view + model), `ios/Idfon/OverlayWindow.swift` (window-level host). Layout only —
call/daemon wiring is integration work (see "Integration contract").

## 1. Input model

```swift
struct LiveActivityBarModel: Equatable {
    enum Phase { case idle, calling, incoming, inCall }     // §3 states (State 2 removed)
    enum Density { case expanded, compact }                 // §6 densities
    struct Row { id; name; kind: .transfer(fraction, bytesPerSecond) | .stream(position, duration, paused) }
    let peerId: String; var handle: String                  // "@janedoe"
    var phase; var micOn; var camOn; var elapsed: TimeInterval; var rows: [Row]; var density
    var audioAvailable: Bool; var videoAvailable: Bool      // tracks the session carries (§3 State 3)
}
enum LiveActivityBarIntent { toggleMic, toggleCam, ping, end, answer, decline,
                             cancelRow(id), togglePauseRow(id), open }
```

The view is a pure function of the model: `bar.apply(model)`; it emits `onIntent`. It
holds no timers — the host advances `elapsed` and re-renders (≤1 Hz; `apply` is cheap).
No inline mic meter: the mic button's glyph is the mic state (§3 lists timer, toggles, End —
nothing else); a meter would cost 52pt of the handle's width for no information.

## 2. View hierarchy

```
OverlayWindow (UIWindow, level .normal+1, clear, hitTest pass-through)
└ rootViewController.view (clear)
  └ stack (UIStackView V, spacing 8, alignment .center)
    ├ LiveActivityBar            ← owning thread, expanded
    └ LiveActivityBar            ← other contacts' pills (§6)

LiveActivityBar (UIView; .secondarySystemBackground, continuous corners, soft shadow)
└ rootStack (V)
  ├ headerStack (H · margins 8/12/8/8 expanded, 4/16/4/4 compact)
  │ ├ identityStack (H, spacing 8)  dot(8×8) · textStack (V, .leading): titleLabel(headline) / statusLabel(mono digits)
  │ └ controlsStack (H, spacing 8)  mic · cam · decline · answer · verb   (each ≥44×44, capsule)
  ├ separator (hairline, .separator)
  └ trayStack (V)
    └ TrayRowView (H, margins 0/12/0/4)  icon · label(footnote, 2 lines) · pause(≥44) · Cancel|Stop(≥44)
```

## 3. Constraint intent

**Host (`OverlayWindow`)** — docks **below navigation chrome**, never over it (§6 Dock position).
- `stack.top = window.top + topClearance + 8` @ priority 750, where `topClearance` is the
  host-provided bottom edge of the top screen's nav bar in window points (0 = no nav bar).
- `stack.top ≥ safeArea.top + 8` @ required — the floor when there is no nav chrome.
- `stack.centerX = safeArea.centerX`.
- `stack.width = safeArea.width − 16` @ priority 750; `stack.width ≤ 560` @ required.
  → Compact widths: 8pt side gutters. Regular widths (iPad/landscape): capped at 560, centered.
- Output: `contentInset = stack.height + 16` (both gutters), 0 while hidden; measured in the
  host controller's `viewDidLayoutSubviews` (the stack's frame is applied there), published
  via `onContentInsetChange` only on change. The content window shifts down by exactly this.
- Per bar: `bar.width = stack.width`, active only when `density == .expanded`.
  Compact pills have no width constraint → intrinsic (hugging) width, centered by the stack.

**Bar**
- `rootStack` pinned to all four edges; every height is intrinsic (no fixed bar height).
- Handle and status stack vertically (`textStack`), so they never compete for width: the
  handle gets the whole identity width and the timer is always whole. Headline + subheadline
  (≈42pt) fits inside the 44pt control row, so the second line costs no height.
- `titleLabel` compression resistance `.defaultLow` → it is the only thing that truncates,
  and only when the handle exceeds its budget; controls never shrink.
- Controls: `width ≥ 44`, `height ≥ 44`.
- `dot` 8×8 fixed.
- Corner radius: expanded 16; compact `height/2` (set in `layoutSubviews`).

**Measured (iPhone 393pt, default text size)**: expanded header + 2 tray rows = 377×148,
header 60 tall. In-call header budget: margins 20 + controls 44·8·44·8·≈44 (End, icon only) +
spacing 12 → identity ≈197 → **handle budget ≈179pt** (`@janedoe` = 78pt), timer 41pt on its
own line. Compact pill for `03:42 @janedoe — 1 transfer, 1 stream` + End = 319×52.

End is **icon only** (`showsTitle: false`): the label wrapped and broke the control row, and
the icon alone is unambiguous next to the red fill. The Bar shows a callee *name* when the
peer-id → name map has one, else a shortened id — never the raw public key.

## 4. State → layout mapping

| Phase / density | dot | title / status | mic · cam | verb slot | tray |
| --- | --- | --- | --- | --- | --- |
| idle, expanded | hidden | `@janedoe` / — | hidden | **Ping** (bell, tint) | rows if any |
| calling, expanded | orange | `@janedoe` / `Calling…` | shown | **End** (red) | rows if any |
| incoming, expanded | orange | `@janedoe` / `Incoming call` | shown (pre-answer staging) | **Decline** (red) **Answer** (green); verb hidden | rows if any |
| inCall, expanded | red | `@janedoe` / `03:42` | shown, live toggles | **End** (red) | rows if any |
| any, compact | phase color | `● 03:42 @janedoe — 1 transfer` (one label; tap → `.open`) | hidden | End (icon only, **menu confirm**) or Decline/Answer; hidden when idle | hidden (summarised in label) |

Verb tap: idle → `.ping`; calling/inCall → `.end`. Compact End
uses `showsMenuAsPrimaryAction` with a single destructive "End Call" `UIAction` — the §6
confirmation with zero alert plumbing. Tray rows: transfer → `Cancel` → `.cancelRow(id)`;
stream → play/pause → `.togglePauseRow(id)`, `Stop` → `.cancelRow(id)`.

Row text: `Transferring "Archive.zip" (42%) - 12 MB/s` (ByteCountFormatter),
`Streaming "Demo_Track.mp3" (01:45 / 03:20)`. Clock: `mm:ss`, `h:mm:ss` past an hour.

**Track availability (§3 State 3).** `micOn`/`camOn` gate whether a stream is
*being sent*; `audioAvailable`/`videoAvailable` say whether the session carries
that stream at all. A call only publishes the tracks it was started with, so
the Bar **hides** a toggle whose track is absent (`model.audioAvailable ==
false` → no mic button in either density; `videoAvailable == false` → no cam
button): showing it would promise an unmute the call cannot do. Both default
true, so every call publishes them. The host fills them from the active machine's
`audioAvailable`/`videoAvailable`; `micOn`/`camOn` come from its
`audioEnabled`/`videoEnabled` on phase entry, and a toggle calls
`setAudioEnabled`/`setVideoEnabled` on that machine.

## 5. Dynamic Type, safe area, size classes

- Labels use text styles with `adjustsFontForContentSizeCategory`; the timer is
  `UIFontMetrics(.subheadline)`-scaled monospaced digits. `UIButton.Configuration` scales
  titles automatically. Nothing has a fixed height except the dot.
- Accessibility categories (expanded only): `headerStack.axis → .vertical`, alignment
  `.leading` — identity on one line, four controls on the next. Observed via
  `registerForTraitChanges([UITraitPreferredContentSizeCategory.self])` (iOS 17).
- Safe area: the host pins to its own root view's `safeAreaLayoutGuide` = scene insets, as
  the floor under `topClearance`. Bar-to-content coordination is one number in one place
  (`contentInset` → nav-controller subclass, §8), not per-screen.
- Size classes: only the 560pt cap + centering; the same hierarchy serves compact and
  regular. Landscape iPhone: safe-area leading/trailing widen the gutters automatically.
- Accessibility labels/values: Microphone on/off, Camera on/off, Ping/Call/End, Answer,
  Decline, Play/Pause; compact title carries `.button` trait.

## 6. Window layering & hit-testing

- `windowLevel = .normal + 1`: above the content window, below `.alert` (2000) and the
  keyboard. Sheets and pushes slide beneath; alerts and context menus present above.
  Docked at the top, the keyboard never reaches the Bar in practice; the level ordering is
  kept for the layering contract, not for keyboard coverage.
- The overlay cannot move another window's content: it *reports* `topClearance` needs
  (input) and `contentInset` (output); the content window applies them (§8).
- `hitTest` returns `nil` when the hit lands on the transparent root view (anything not a
  bar), so the app underneath stays fully interactive. `isHidden = true` when there are no
  models, so an empty overlay costs nothing.
- Incoming-call surface lives **inside the Bar** (§7 PROPOSAL 1); no second ringing window,
  so the CallKit path trivially cannot double-present — the host simply never produces
  `.incoming` for CallKit-mode connections.

## 7. Resolved open decisions (PROPOSALs)

1. **Incoming surface = inline Answer/Decline in the Bar, not a fullscreen ringing screen.**
   §6's own rationale for the Bar path ("doesn't hijack the screen") rules out fullscreen;
   Mic/Cam stay visible so the callee can stage before answering. The `.incoming` fullscreen
   present was retired when the Bar was integrated; `CallViewController` now exists only as
   the expanded video surface, presented from the chat's inline video bar.
2. **Outgoing-pending = `Calling…` status + red End (cancels).** Smallest possible state:
   same chrome as in-call minus the timer; no extra screen.
3. **Idle-state tray = identical rows under the Idle chrome.** Rows are state-independent
   in the model; nothing to design separately. Idle *pill* (rows but no call) shows the
   summary text with no End button.
4. **DECIDED (owner): dock = top, below the navigation bar, content shifts down.**
   WhatsApp/Telegram "return to call" style; never floats over nav chrome (§6 Dock
   position). Mechanism: `OverlayWindow.topClearance` (nav bar bottom, host-set) anchors
   the stack; `OverlayWindow.contentInset` (stack height + gutters) is what the host adds
   to `additionalSafeAreaInsets.top` of the visible content controller. Chosen over
   `contentInset` on scroll views (per-screen, misses non-scrolling screens) and over
   `additionalSafeAreaInsets` on the *nav controller* (would push the nav bar itself down).
5. **Pill End confirmation = one-item destructive `UIMenu`.** Native, no alert controller
   or presenter plumbing in the view.
6. **Multiple bars = vertical stack, host order.** Owning thread's expanded Bar first,
   other contacts' pills beneath (§6 Bob/Jane case). Daemon supports one call, so ≤2 in
   practice.

Not resolved (not layout-blocking): Stream-vs-Send trigger (§5 modal), call-end-mid-transfer
(model already allows rows with `phase == .idle`, so "transfer continues" needs no layout work).

## 8. Integration contract (implemented)

- `SceneDelegate`: builds a `UITabBarController` (Favorites / Recents / Contacts), each tab
  an `AppNavigationController`, then `LiveActivityController(windowScene:)` and
  `activity.tabBarController = tabs`. The controller owns the overlay and the strong
  scene-level reference; `overlay.onIntent` routes to `LiveCall` / `VideoCall` / transfer
  code / navigation (`.open` → push the peer's thread on the selected tab).
- **Tab awareness:** the controller is the `UITabBarControllerDelegate`. It resolves the
  selected tab's nav for density and `topClearance`, and re-anchors on tab switch, so a call
  whose thread is behind another tab renders as a compact pill.
- **Nav clearance + content shift (one owner: `LiveActivityController`, fanned out to every
  tab):**
  - `AppNavigationController` exposes `topClearance` (`navigationBar.frame.maxY`; a root
    tab's nav view shares the window origin, so this is already in window points),
    `applyContentInset(_:)`, and two callbacks: `onLayout` (fired in
    `viewDidLayoutSubviews` — push/pop, rotation, large-title collapse) and
    `onVisibleControllerChanged` (fired in `didShow`).
  - `LiveActivityController` sets `overlay.onContentInsetChange` **once** and fans the inset
    out to every tab's nav, and applies the current `overlay.contentInset` to a newly pushed
    controller in `didShow`. Each nav remembers its own inset so a push re-applies it.
    Children already have nav bar + status bar in their safe area, so the addition is exactly
    the Bar's height + gutters; scroll views and Auto Layout content follow the safe area for
    free.
  - Only the selected tab's `topClearance` is written (`syncClearance()`); an offscreen
    tab's layout pass reads the selected nav, so a stale write cannot move the Bar.
  - Modals: a sheet leaves the presenting nav bar in place, so clearance is unchanged. A
    full-screen presentation (e.g. `CallViewController`) has no nav bar; the host either
    hides the overlay (`render([])`) or sets `topClearance = 0` (Bar falls back to
    `safeArea.top + 8`). Still undecided; both are one line.
- Density rule: `.expanded` for the currently visible thread's peer, `.compact` otherwise.
- The `.incoming` fullscreen present was retired (see §7.1). `ChatViewController.videoBar`
  is **retained** — the inline video bar is the intended design (tap to expand) — so the
  earlier "retire it" line is superseded.

## 9. Verification

`ios/Checks/LiveActivityBarCheck/main.swift` — headless simulator run (command in file
header): model formatting, expanded fill width, handle/timer untruncated
and stacked with the header held at 60pt, pill hugging + capsule radius, per-state button
visibility (idle hides Mic/Cam, in-call shows them), intent routing. Passes on iPhone 17
simulator.

Typecheck the sources at the deployment target (`-target arm64-apple-ios17.0-simulator`).
Not verified: on-device visuals, VoiceOver traversal order, accessibility-size wrapping
(logic only), context-menu presentation from a non-key window, and `OverlayWindow` itself
(needs a `UIWindowScene`, which the headless spawn does not have — the clearance anchor and
`contentInset` reporting are verified only by typecheck and reasoning). The wiring is now in
place (§8); exercising it on device is the remaining step.
