# Multi-device conversation implementation plan

## Invariants

- Account IDs identify logical peers and conversations.
- Endpoint IDs identify concrete devices and remain valid for direct/ephemeral communication.
- A conversation is an account participant set; a 1:1 chat is a two-account conversation and a room has more participants.
- `topic_id` is transport/synchronization metadata, not the conversation's identity.
- The sender chooses delivery targets. Endpoint metadata may guide that choice but does not impose policy.
- A logical message keeps one `message_id` across endpoint copies; receivers deduplicate by logical message identity, not endpoint.

## Stages

1. **Protocol model**
   - Preserve `Peer.id` as the logical/account reference where available.
   - Extend device metadata with optional label, class, capabilities, and address metadata.
   - Add conversation participant/kind types only where current room/direct state cannot already represent them.
   - Keep endpoint IDs usable as explicit direct targets and for legacy records.

2. **Peer/device operations**
   - Add incremental `peer.device.add`, `peer.device.update`, and `peer.device.remove` operations.
   - Do not require clients to replace the complete device array for one change.
   - Treat legacy `endpoint_id`/`endpoint_addr` fields as the primary device.

3. **Delivery policy**
   - Add a small policy shape: one, failover, or all; optionally restricted by endpoint IDs or device class.
   - Preserve current primary-first/failover behavior as the default.
   - Support explicit endpoint sends without resolving/fanning out the whole account.

4. **Conversation delivery**
   - Refactor ordinary messages to resolve account participants, then select endpoint targets according to sender policy.
   - Keep direct chats and rooms on the same message, deduplication, authorization, and event paths.
   - Validate sender membership and account/device authorization independently.

5. **Tickets and clients**
   - Include account ID, endpoint ID, endpoint address, device class, and capabilities in contact/device tickets.
   - Update iOS, Native/macOS/Windows, CLI, MCP, Eve, and scripts to avoid using endpoint IDs as durable account IDs.
   - Pairing another device updates one peer instead of creating a duplicate contact.

6. **Calls and MCP**
   - Keep MCP grants account-scoped while validating the concrete remote endpoint.
   - Make live calls endpoint-targeted by default; add explicit ring/fallback policy only when the UI needs it.

7. **Durability and sync**
   - Add mailbox delivery after account/device routing is stable.
   - Add operation/event log union and deterministic replay before push wake.

## Tests

- Legacy peer records deserialize unchanged.
- One account with multiple endpoints supports explicit endpoint, failover, and fan-out delivery.
- Copies share one logical message ID and deduplicate.
- Grants can be account-wide or endpoint-specific.
- Every enrolled endpoint authenticates; unknown/revoked endpoints fail.
- Direct conversations and rooms share message delivery and deduplication behavior.
- Pairing a second device updates an existing peer.
- MCP authorizes the account and validates the endpoint.
- Calls select one endpoint unless an explicit multi-ring policy is requested.

## Immediate next increment

Add incremental peer-device operations and device metadata, then update the CLI/native/iOS pairing paths to use account ID plus endpoint ID separately. Keep the existing wire fields and legacy behavior during migration.
