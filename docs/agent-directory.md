# agent-directory: a catalog agent that issues contact invites

Status: **catalog-only v1** — provisioner, agent, holder dynamic-allow, and
app-side accept are implemented and build/parse-checked.

A caller needs a contact (a peer identity + capability ticket) before they can
talk to any agent. That is a bootstrap problem: to be invited you must already
be in contact with someone. The **directory** is the one contact you start
with. It resolves a request — "I want to talk to GPT-6.1-Sol" — into a
**contact invite** for an agent that serves that model.

This also gives one useful property: the directory is a **chokepoint**. It is
the only process that mints invites, so caller policy, the model roster, and an
audit log live in one place instead of in each agent. And it dogfoods the idfon
agent path on itself.

## What an invite is

Becoming a contact is three operations (see `scripts/pair-apple-channels.sh`):

1. `peer add` the holder's endpoint address — the *contact ticket*.
2. store a capability ticket holder-signed with **subject = the caller's
   endpoint id** — authorizes caller → holder sends.
3. `access allow <holder> message.send/message.receive` on the caller's daemon
   — lets the holder's replies reach the caller.

The directory can mint (1) and (2) because the idfon channel authenticates the
caller's endpoint id in-session. (3) happens on the caller's device, so the
invite is an envelope the app must accept and expand.

```
IDFON-INVITE/1
name=GPT-6.1-Sol
model=openai/gpt-6.1-sol
expires_at=<epoch seconds>
contact={"id":"<holder-endpoint-id>","addrs":[...]}
ticket={"type":"capability","subject":"<caller-endpoint-id>",...}
```

`expires_at` bounds the invite itself (default 1h,
`DIRECTORY_INVITE_TTL_SECS`); the capability ticket stays long-lived because it
is the contact's ongoing send credential.

## Catalog-only v1

The v1 roster is fixed in `agents/directory/roster.json`. Each entry points at
an already-running `llm` holder by `instance` (home `~/.idfon/<instance>`) or an
explicit `home`; the model in the entry is what the caller asks for. No dynamic
spawning — adding a model means adding a holder and a roster line.

```
agents/directory/
  roster.json                 # the fixed catalog
  agent/
    agent.ts                  # bootstrap agent (does not answer as the model)
    instructions.md           # catalog + envelope handling
    tools/request-invite.ts   # calls the provisioner
    extensions/idfon.ts       # idfon channel wiring
    sandbox.ts
scripts/directory-provisioner.mjs   # the chokepoint (roster, policy, tickets)
scripts/directory-serve.sh          # starts the provisioner + directory agent
```

## Running it

Start one holder per roster entry (this is just the generalized `llm` agent):

```sh
EVE_INSTANCE=gpt61 EVE_CONTACT_NAME="GPT-6.1-Sol" \
  EVE_IDFON_MODEL=openai/gpt-6.1-sol scripts/llm-serve.sh
EVE_INSTANCE=fable51 EVE_CONTACT_NAME="Fable 5.1" \
  EVE_IDFON_MODEL=anthropic/claude-haiku-4.5 scripts/llm-serve.sh
```

Then serve the directory (it starts the provisioner if not already up):

```sh
AI_GATEWAY_API_KEY=... scripts/directory-serve.sh
# or: pnpm agent start directory
```

Policy is environment on the provisioner:

| Var | Meaning |
| --- | --- |
| `DIRECTORY_ROSTER` | roster path (default `agents/directory/roster.json`) |
| `DIRECTORY_PORT` | listen port (default `18777`, loopback only) |
| `DIRECTORY_SECRET` | shared secret between agent and provisioner |
| `DIRECTORY_ALLOW_CALLERS` | comma-separated caller endpoint ids; empty = any |
| `EVE_IDFON_GPT` | holder binary (default `target/release/eve-idfon-gpt`) |
| `DIRECTORY_AUDIT` | invite audit log (default `agents/directory/invites.ndjson`) |

`GET /catalog` lists the roster; `POST /invite {peer_id, model}` mints and
returns the invite. The provisioner binds to `127.0.0.1` and requires the secret
header, so only the directory agent (its only caller) can issue invites.

Self-check for the minting/envelope logic:

```sh
node scripts/directory-provisioner.mjs --self-check
```

## Enrollment (wired)

- **Holder allow-list.** `eve-idfon serve` takes `--allow-file`, a list of
  sender ids reloaded while running and unioned with the static `--allow`
  entries (`load_allow_file` / `merge_allow`). The serve script points every
  holder at `$home/allowed-peers`; the provisioner appends the caller id when it
  mints the invite (`admit`), so the ticket is accepted without restarting the
  holder. Covers remote callers, not just the local daemon.
- **App accept + trust gate.** Both native apps recognize `IDFON-INVITE/1`
  during chat ingest and enroll via `addChannel` + `CapabilityTickets.store`.
  Auto-enroll happens only when the **sender** is in the app-local `AutoEnroll`
  trust list **and** the invite has not expired; everyone else gets a prompt
  ("Add" / "Add and Always Trust" / "Ignore").
- **Voucher.** There is no separate voucher field: an idfon message is
  Ed25519-signed by its sender over `content` (`verify_message` / `auth_bytes`
  in `idfon-core`), and the daemon verifies it before delivery. So the
  authenticated sender + an exact-byte signature is the directory-signed
  voucher; trust policy is the `AutoEnroll` list on top of it.
- **Granting trust.** `AutoEnroll.trust(peer)` (per peer id, revocable) — set
  from the confirm dialog's "Add and Always Trust", or the `-trust-enroll
  <peer>` automation argument today.

## Remaining

- **Trust UI.** `AutoEnroll` is only settable from the prompt or the
  automation flag; a settings/context-menu toggle (and viewing/revoking trusted
  issuers) is still to come.
- **Dynamic roster.** Arbitrary requested models still need per-request holder
  provisioning (port/key lifecycle), which the fixed catalog deliberately
  avoids.

See `docs/voice-side-channel.md` for the `llm` agent and per-instance model
selection, and `docs/idfon-eve.md` for the channel.
