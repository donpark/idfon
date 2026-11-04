# Contact exchange (vCard, NameDrop substitute)

> **Status:** P0–P2 implemented (CLI + daemon + both apps). Apple's NameDrop
> itself is closed to third-party apps; this is the supported substitute.

## Why not NameDrop

NameDrop (iOS 17+) is system-level (NFC/AirDrop) and exchanges only name,
poster, and phone/email — with the system Contacts app, never with a third
party. There is no API to trigger, extend, or receive it, and CoreNFC is
reader-mode only on iOS. AirDrop routes a `.vcf` by its UTI (`public.vcard`)
straight into the Contacts import wizard — no app can intercept it.

So the card must **resolve itself from inside Contacts**: it carries the idfon
ticket twice (codec: `crates/idfon-protocol/src/vcf.rs`):

- `X-IDFON-TICKET` — the ticket JSON, for direct `.vcf` → idfon import.
- `URL:idfon://add/<base64url>` — a standard `URL` property (survives the
  Contacts round-trip, which may strip unknown X- properties) that deep-links
  into the app and adds the contact when tapped.

```text
give                          AirDrop / .vcf file           receive
idfon contact export  ──────►  OS routes on UTI  ──────►  Contacts wizard
My Card (QR + Share)                                          │
app "Share Contact Card"                                      ▼
                                                     saved into a contact
                                                              │
                    tap the idfon URL / open in Idfon / scan QR
                                                              ▼
                                    idfon://add/<ticket> → confirm → peer.add
```

## Surfaces

| Surface | Where |
|---|---|
| Codec (fold/escape/base64url) | `crates/idfon-protocol/src/vcf.rs` (tests: `tests/vcf.rs`) |
| `contact.export {ref?}` → `{vcard, link}`, `contact.import {text}` → `{peers}` | daemon (`docs/protocol.md` "Contact exchange"); `peer.add` also accepts `contact_ticket` and names the peer from its `label` |
| CLI `idfon contact export [--peer REF] [--out F]` / `idfon contact import [FILE\|-]` | `crates/idfon-cli` |
| `idfon://add/<base64url>` verb | `IdfonURL` (both apps); iOS `SceneDelegate`, mac `AppDelegate` |
| My Card (QR + Share + Save to Contacts) | iOS Contacts tab → Add menu → "My Card"; mac sidebar → "My Card…" (exports the active identity's card) |
| Share an identity's card (any line) | iOS Identities list → tap a row (swipe "Ticket" copies the raw ticket JSON); mac sidebar → identity submenu → "Share Contact Card…" |
| QR scan | iOS Add menu → "Scan QR Code" (mac has no scanner; show the code and let the phone scan) |
| `.vcf` document open ("Open in Idfon") | `CFBundleDocumentTypes` (`public.vcard`) in both Info.plists |
| Save to system Contacts (name + idfon URL) | `CNContactStore` (`NSContactsUsageDescription` in both Info.plists) |
| Share a peer's card | iOS contact detail → "…" menu; mac contact context menu |

The apps delegate all codec work to the daemon RPCs; the only client-side
decoding is base64url of the deep-link payload.

## Approval modal (the add flow)

Tapping an `idfon://add/` link opens the approval modal: the name is editable
(rename before adding) and the user either adds or **denies**. A protected
contact's envelope carries an `auth` block instead of a capability ticket:

```json
{ "contact": …, "auth": { "kind": "code", "label": "Admission code",
  "criteria": "…", "url": "http://<host>:<port>/redeem" } }
```

The modal shows the agent's `criteria`, collects the admission code, and
redeems it (`POST {code, subject}` with the device's own peer id) for the
sender-bound capability ticket — the `radio-admit.sh` contract
(`allowed-peers` + `ticket --subject <peer>`) with no console round-trip.
Codes are one-shot.

## The test-contacts page (testing without pairing)

`node scripts/test-contacts-page.mjs --serve` renders every holder identity
under `~/.idfon` as a card (QR + tap link) on the local network. Public agents
get subject-less tickets in the link; protected ones get a per-load admission
code that the modal redeems. This replaces the `-pair` / `-pair-ticket` +
`devicectl` pairing dance for testing (see `docs/live-radio.md` "Pairing the
iPhone"); the holder's sender binding stays.

## Policy notes

- Imports apply the same default grants as Add Contact (the four chat
  capabilities); the CLI `contact import` does not grant (CLI parity with
  `peer add`).
- `contact.import` upserts per card (re-import is idempotent) and aborts on a
  card that fails `peer.add` validation; foreign vCards are skipped.
- Capability tickets are **subject-bound** (`ticket.subject == sender peer id`
  at the holder's ingress): a device whose peer id rotates (reinstall) must
  re-redeem. The public page's subject-less bearer survives identity churn —
  that is what makes public stations robust for testing.

## Open items / risks

- Whether Apple's Contacts preserves `URL` verbatim across its own re-export is
  unverified on-device (high confidence; X-properties are not trusted at all,
  hence the two slots). One manual AirDrop round-trip confirms.
- QR scanning on macOS is out (no camera UX); phone scans the mac's code.
- Matching NameDrop'd contacts (phone/email) to peers needs phone/email in the
  peer model — deferred; the tap-through URL covers the flow.
