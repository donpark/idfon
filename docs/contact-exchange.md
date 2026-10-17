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

## Policy notes

- Imports apply the same default grants as Add Contact (the four chat
  capabilities); the CLI `contact import` does not grant (CLI parity with
  `peer add`).
- `contact.import` upserts per card (re-import is idempotent) and aborts on a
  card that fails `peer.add` validation; foreign vCards are skipped.

## Open items / risks

- Whether Apple's Contacts preserves `URL` verbatim across its own re-export is
  unverified on-device (high confidence; X-properties are not trusted at all,
  hence the two slots). One manual AirDrop round-trip confirms.
- QR scanning on macOS is out (no camera UX); phone scans the mac's code.
- Matching NameDrop'd contacts (phone/email) to peers needs phone/email in the
  peer model — deferred; the tap-through URL covers the flow.
