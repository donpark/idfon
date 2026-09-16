# idfon-eve-channel

Eve ingress **channel** that makes an idfon peer a first-class Eve agent
contact. The caller authenticates with its idfon endpoint key instead of a
bearer token, and the agent needs no public endpoint, DNS name, or TLS cert.

A human idfon client and another agent reach the channel the same way: they
send `message.send` over iroh, the provider's endpoint holder verifies the
peer, and the turn lands in an Eve session with the peer as the principal.

## Requirements

- Node.js >= 24 (Eve's requirement)
- A holder binary for your platform. It ships as an optional platform package
  (`idfon-eve-channel-{darwin,linux}-{arm64,x64}`) and is resolved
automatically; there is no Windows package (the holder's IPC is a Unix socket).
  For an unsupported platform or a self-built holder, pass `--holder-command`
  (or set `IDFON_EVE_CHANNEL_HOLDER`) pointing at
  `cargo build --release -p idfon-eve-channel` output from the
  [idfon workspace](https://github.com/donpark/idfon).

## Install

```sh
npm install idfon-eve-channel
```

With pnpm inside the idfon workspace:

```sh
pnpm add idfon-eve-channel --filter <your-eve-app>
```

## Use in an Eve app

```ts
// agent/extensions/idfon.ts
import idfon from "idfon-eve-channel";

export default idfon({
  bridgeUrl: "http://127.0.0.1:18766",
  secret: process.env.IDFON_CHANNEL_SECRET!,
});
```

`bridgeUrl` must point at the local bridge (loopback only). The channel
handler requires the same `secret` on every request.

The `idfon__send`, `idfon__put`, `idfon__publish-live`, and
`idfon__stop-live` tools are available at `idfon-eve-channel/tools`.

## Run the managed sidecar

`managed.mjs` owns the holder and bridge as child processes, takes a lock on
the socket, forwards termination, and cleans up on exit. Eve 0.55 has no
custom-channel startup hook, so this is the deployment entrypoint.

```sh
npx idfon-eve-channel \
  --key-file  ~/.config/idfon/eve.key \
  --socket    /run/user/$UID/idfon-eve.sock \
  --blob-dir  ~/.local/share/idfon/eve-blobs \
  --target    http://127.0.0.1:52776 \
  --secret    "$IDFON_CHANNEL_SECRET" \
  --port      18766
```

`--holder-command` defaults to the installed platform package's binary (with a
repo-layout fallback for checkouts). Pass `--allow <PEER_ID>` (repeatable) to
admit peers, and `--live-ttl-secs` to cap abandoned live publishers
(default 3600).

## License

MIT OR Apache-2.0. See `LICENSE-MIT` and `LICENSE-APACHE`.