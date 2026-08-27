# NuPhone Communication Model

NuPhone is not limited to the classic phone-call or audio/video-chat model. It should support many loosely coupled ways for people and groups to communicate, with fine-grained control over how each capability reaches the recipient.

## Core idea

Communication is a set of independently controlled capabilities, not one monolithic call state.

A person may grant another person or group the ability to:

- send text
- deliver an asynchronous voice message
- open a live audio channel
- send video
- interrupt them
- invite others into a group
- record or retain media

The product decides how each capability behaves locally. A sender being authorized to use a capability does not automatically mean that the recipient must play it, be interrupted, or accept every related action.

## Capability grants

A grant describes what a peer or group is allowed to do and how long that permission lasts.

At minimum, a grant should define:

```text
subject     → individual or group
capability  → the specific action permitted
direction   → inbound, outbound, or both
lifetime    → one-time, expiring, leased, or persistent
scope       → which conversation, channel, or context it applies to
```

Capabilities should remain separate. For example, permission to send text should not imply permission to open live audio, interrupt, record, or add participants.

Grants need to be revocable. The recipient should be able to disable a capability immediately, without having to negotiate with or receive cooperation from the sender.

## Local UX policy

The recipient controls what happens when an authorized capability is exercised. Possible policies include:

- auto-accept and play
- notify before playing
- queue for later
- play silently or show only a notification
- allow only during a schedule
- allow only when the recipient is available
- record for later review
- reject

Policy should be configurable per person, group, capability, and context. A global emergency stop should always be available for live inbound media.

## Communication modes

NuPhone should treat these as distinct modes that can be combined when useful:

### Direct messaging

Text and other small events delivered to an individual or group. Delivery, read state, ordering, and retention are separate product decisions.

### Asynchronous voice

A sender records audio and makes it available for later playback. The recipient does not need to be present when it is sent.

### Live inbound voice

An authorized person or group can speak to the recipient without the recipient answering each time. This is an always-available speaker capability, not necessarily a phone call. The recipient needs clear active-state feedback, independent volume/mute controls, and an immediate revoke/stop action.

### Interactive conversation

Both sides can participate in a live exchange, with explicit controls for who may speak, listen, interrupt, or add participants.

### Group and broadcast modes

A group may have different roles and permissions. Some members may speak, some may listen, and some may be able to interrupt or moderate. Broadcasting should not be conflated with a group call.

## Separation of concerns

Keep these concepts independent:

```text
identity and relationships
        ↓
capability grants
        ↓
local UX policy
        ↓
communication mode
        ↓
transport and media delivery
```

The underlying networking technology is an implementation detail. It may provide transports for live bytes, messages, events, stored media, or replicated state, but it should not define NuPhone’s product model.

## Privacy and safety requirements

Always-available communication is powerful and must be obvious and reversible:

- show when live audio is active
- show who is currently able to speak or listen
- provide a local kill switch
- make microphone and speaker state visible
- support immediate grant revocation
- support expiry and scheduled availability
- distinguish authorized access from currently active access
- keep recording permission separate from speaking permission
- do not treat possession of contact or connection information as authorization

The default should favor user control and predictable behavior. An authorized sender may be allowed to attempt delivery, but local policy remains the final decision about playback, interruption, recording, and persistence.

## Design principle

NuPhone should feel less like answering calls and more like configuring trusted communication channels: each person or group can be given precisely defined ways to reach you, while you retain control over when and how those channels affect your attention.
