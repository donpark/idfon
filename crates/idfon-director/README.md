# crates/idfon-director

The thin voice-agent loop boundary: turns, tools, and trace are idfon-owned, and
the loop itself is delegated to `yoagent` so the harness stays swappable. The
tier seam is a `StreamProvider` — on device that is Apple Foundation Models
(`--features afm`), elsewhere any provider.

The portable contract (prompt sections, tool schemas, the trace record) is
documented and versioned; this crate is where that contract is enforced.

- **Kind:** library
- **Read more:** `docs/voice-agent-loop-contract.md`

```sh
cargo test -p idfon-director
```
