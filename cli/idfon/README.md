# idfon

Peer-to-peer content transfer and live audio over [iroh](https://www.iroh.computer).
`npx idfon` runs the CLI with no install; the npm package wraps prebuilt
platform binaries (no Node code, no compile step).

```sh
# daemon status / identity
npx idfon status

# peerless transfer: blob tickets via stdout
npx idfon put --file demo.mp4        # prints a BlobTicket
npx idfon get <ticket> --out demo.mp4

# peer-directed: chat, signaled blobs, 1:1 live audio
npx idfon send PEER --text "hello"
npx idfon send PEER --file demo.mp4
npx idfon send PEER --stream --file audio.wav
```

Supported platforms: macOS (arm64, x64), Linux (x64, arm64). The first command
starts a background daemon (`idfond`, shipped in the same package); see the
[repo](https://github.com/donpark/idfon) for the full CLI reference.
