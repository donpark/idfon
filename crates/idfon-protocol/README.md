# crates/idfon-protocol

Versioned logical API types shared by the daemon and every client: messages and
peers, capabilities and tickets, call/live-call records, UI blocks, diagnostics,
and vCard contact cards. This crate owns the **wire shapes**; it owns no
transport, no storage, and no policy.

- **Kind:** library
- **Modules:** `artifacts`, `blocks`, `calls`, `diag`, `vcf`
- **Read more:** `docs/protocol.md` (daemon RPC), `docs/communication-model.md`

```sh
cargo test -p idfon-protocol
```
