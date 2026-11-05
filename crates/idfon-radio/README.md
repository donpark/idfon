# crates/idfon-radio

A talk-radio station's programme: the schedule, its clips, and the frames a
transport pumps. This crate owns what plays and when and knows nothing about who
is listening — an idfon one-way call is one adapter, HLS/HTTP would be another.

Playback is call-relative (`Programme::sync` against the clock, then
`Programme::frame` until the queue is fed), so this is a programme, not a timer.

- **Kind:** library
- **Modules:** `programming`, `clip`, `menu`
- **Read more:** `docs/live-radio.md`

```sh
cargo test -p idfon-radio
```
