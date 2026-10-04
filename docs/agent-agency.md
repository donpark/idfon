# agent-agency: the bootstrap contact that introduces agents

Status: **implemented**. Registration, the A2A intro, holder-issued cards, and
the app-side accept are in place; the local stack was verified end-to-end (the
returned card is signed by the target, bound to the caller).

A caller needs a contact (a peer identity + capability ticket) before they can
talk to any agent — but to be introduced you already need a contact with
someone. The **agency** is the one contact you start with. It resolves a
request — "I want to talk to GPT-6-Luna" — into a card for an agent that serves
that model.

## The agency signs nothing

The agency is a **go-between**, not an issuer. Every card is signed by the
**target agent's own holder**; the agency only relays. Two cards, same
mechanism, different subject:

- **Registration card** — subject = the *agency*, so the agency can send
  the intro request. Issued when the target registers.
- **Intro card** — subject = the *caller*, the card the user receives. Issued
  per request (never reused).

## Intro flow

1. The caller messages **Agency** and asks for a model.
2. The agency's `request-invite` tool fetches the target's registration card
   from the provisioner (`POST /target`) and sends the target an A2A turn:
   `IDFON-CARD-REQUEST/1` with the caller's peer id + a `reply_to` id.
3. The target's agent calls the `issue-card` tool; its **holder mints a fresh
   ticket bound to the caller** and returns the holder's endpoint address.
4. The target replies with `IDFON-CARD/1` (+ `reply_to`); the agency's
   bridge matches the pending `reply_to` and hands the card back to the tool —
   in the *same turn* the caller is waiting on.
5. The agency wraps it as `IDFON-INVITE/1` and replies to the caller, who
   only ever needed the Agency contact.

Because step 4 is synchronous within the caller's turn, no agency→caller
forwarding is needed.

## What a card is

Becoming a contact is three operations (see `scripts/pair-apple-channels.sh`):

1. `peer add` the holder's endpoint address — the *contact ticket*.
2. store a capability ticket holder-signed with **subject = the caller's
   endpoint id** — authorizes caller → holder sends.
3. `access allow <holder> message.send/message.receive` on the caller's daemon
   — lets the holder's replies reach the caller.

(1) and (2) travel in the envelope; (3) happens on the caller's device, so the
app expands the invite on accept.

```
IDFON-INVITE/1
name=GPT-6-Luna
model=openai/gpt-6-luna
expires_at=<epoch seconds>
contact={"id":"<holder-endpoint-id>","addrs":[...]}
ticket={"issuer":"<holder>","subject":"<caller-endpoint-id>",...}
```

`expires_at` bounds the invite itself; the capability ticket stays long-lived
because it is the contact's ongoing send credential.

## Registration (the target's act)

A target registers itself so the agency can introduce it. Starting it with
`AGENCY_URL` set makes the serve script:

1. add the agency to the target's own `allowed-peers` (so it accepts the
   agency's A2A request), and
2. ask its own bridge for a card bound to the agency (`POST /card`), then
   `POST` it to the provisioner's `/register`.

The provisioner never reads another agent's key.

```sh
AI_GATEWAY_API_KEY=... scripts/agency-serve.sh          # agency + provisioner
AGENCY_URL=http://127.0.0.1:18777 \
  EVE_INSTANCE=gpt6luna EVE_CONTACT_NAME="GPT-6-Luna" \
  EVE_IDFON_MODEL=openai/gpt-6-luna scripts/llm-serve.sh   # target self-registers
```

## Pieces

```
agents/agency/
  roster.json                 # catalog names/models (availability = registered)
  agent/tools/request-invite.ts   # /target -> A2A card request -> IDFON-INVITE
  ...
scripts/agency-provisioner.mjs   # registry + policy; signs nothing
scripts/agency-serve.sh          # starts the provisioner + agency agent
integrations/eve-idfon/
  bridge.mjs                  # POST /card, POST /send (await_reply)
  extension/tools/issue-card.ts   # agent-facing card issuance
crates/eve-idfon              # ticket.issue IPC frame -> holder mints a card
```

Provisioner endpoints: `GET /catalog`, `POST /register {name,model,endpoint_addr,capability_ticket}`,
`POST /target {model}`. Env: `AGENCY_ROSTER`, `AGENCY_PORT` (18777,
loopback), `AGENCY_SECRET`, `AGENCY_ALLOW_CALLERS`, `IDFON_HOME`,
`AGENCY_AUDIT`. Self-check: `node scripts/agency-provisioner.mjs --self-check`.

Target env: `AGENCY_URL` (enables registration), `AGENCY_PEER` (defaults
to the agency's holder id). The holder exposes `ticket.issue`; the bridge
exposes `/card`; the registry is in-memory (re-registration on restart).

## Enrollment (caller side)

- **Holder allow-list.** `eve-idfon serve --allow-file` reloads sender ids while
  running and unions them with `--allow`; the target admits the agency at
  registration.
- **App accept + trust gate.** Both native apps recognize `IDFON-INVITE/1` and
  enroll via `addChannel` + `CapabilityTickets.store`. Auto-enroll only when the
  **sender** is in the app-local `AutoEnroll` trust list and the invite is live;
  otherwise the app prompts (Add / Add and Always Trust / Ignore). Set trust
  from that prompt or `-trust-enroll <peer>`.

## Remaining

- **Trust UI**: a settings/context-menu toggle to view/revoke `AutoEnroll`
  issuers (today: prompt or automation flag only).
- **Registry persistence**: registrations are in-memory; a target re-registers
  on start. A persisted registry would survive a provisioner restart.
- **Dynamic roster**: arbitrary requested models still need per-request holder
  provisioning (port/key lifecycle), which the fixed catalog avoids.

See `docs/voice-side-channel.md` for the `llm` agent and per-instance model
selection, and `docs/idfon-eve.md` for the channel.
