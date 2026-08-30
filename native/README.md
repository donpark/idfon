# Native

A native app authored in TypeScript and markup: the logic lives in
`src/core.ts` (Model, Msg, update - the app-core subset, compiled to
native code at build time; no JS runtime ships in the binary) and the
view in `src/app.native`. There is no Zig in this tree and nothing to
configure: the build detects `src/core.ts` and wires everything.

## The loop

```sh
native dev --core   # fastest: run the core's logic under node -
                    # dispatch messages as JSON lines, watch the model
                    # and effect transcript (not a renderer)
native dev          # build and run the real app (markup hot reload)
native check        # verify core.ts (subset checker) + markup + app.json
native build        # ReleaseFast binary in zig-out/bin/
native test         # the app's test suite
pnpm --filter @nufon/native launch
                    # build with SDK runtime tracing off, package, and open
native package --target macos --binary "zig-out/bin/Nufon" --output "Nufon.app"
                    # create a Finder-launchable macOS app bundle
./zig-out/bin/Nufon
                    # raw binary; native diagnostics go to /tmp/nufon-<pid>.log
rm -f /tmp/nufon-*.log
cat /tmp/nufon-<pid>.log
                    # inspect one process's Iroh diagnostics
```

Edit `src/core.ts` for behavior, `src/app.native` for the home view,
`src/windows/*.native` for secondary windows, and `app.json` for
windows/identity/permissions. Audio media status, verified behavior, and
remaining production tasks are documented in [`../docs/audio-media.md`](../docs/audio-media.md). The home view restores the default identity,
starts its endpoint, and shows that identity's connections. Selecting an
identity copies its full Iroh ticket. Double-clicking or pressing Enter on a
connection opens its chat window; incoming messages open the receiving chat
window automatically. Pressing Call publishes live audio and sends the live
ticket to the selected peer; the peer subscribes automatically. Ending the call
on either side stops both the local publisher and the remote subscription.
Markup binds the model's field names exactly as core.ts
wrote them (`tickCount` -> `{tickCount}`), and exported single-model helpers
bind as derived values (`{total}`).

## Try the core loop

```sh
printf '%s\n' '{"kind":"increment"}' '{"kind":"toggle_ticking"}' '{"advance":3000}' | native dev --core
```

## Editor support

Stock editor TypeScript just works: `package.json` and `tsconfig.json`
are the editor-and-versioning surface (the tsconfig mirrors the checker's
own options, so editor errors match `native check`), and
`node_modules/@native-sdk/core` is a CLI-managed copy of the SDK package
so `@native-sdk/core` resolves with full IntelliSense. Builds never read
any of it — delete node_modules and every `native` verb still works; the
next `native check`/`dev`/`build` puts it back. Running `npm install`
is optional for the same reason: the CLI materializes and refreshes the
package itself, and an install simply lands the identical content once
`@native-sdk/core` is on npm.

## Known limitations

The Iroh host still starts detached native worker threads for the receiver
accept loop and sender requests. The packaged app carries a matching `nufond`
binary beside the GUI executable; development launches look in the workspace
build locations first. Each endpoint bind generates a fresh identity,
which allows two blindly launched app instances to connect after copying the
receiver's current ticket. Shutdown currently does not cancel and join
every worker before the process exits. If a worker is blocked in endpoint or
stream I/O, closing the window or stopping `native dev native` can leave the
app running or make exit appear to hang until the Iroh timeout expires.

Media files and live broadcast names are scoped to the selected peer under
`NATIVE_SDK_APP_DATA_DIR/conversations/<scope>`. Active media resources remain
process-global until multi-session media ownership is implemented. Recording
messages use a versioned metadata envelope and persist deduplicated BlobTickets
in `recording-history.log`; full durable chat history and capability
authorization are still pending.

For development, inspect per-process diagnostics with:

```sh
cat /tmp/nufon-<pid>.log
```

and close leftover instances with:

```sh
pkill -x "Nufon"
```

This is a lifecycle limitation in `src/iroh_ffi.zig`; it does not affect the
normal bind/send protocol while the app is running.

## Packaging and size

`native build` creates a raw executable. Use `native package` to create a
Finder-launchable `.app` bundle; launching the raw executable may open a
Terminal window on macOS. The build links the optimized Rust Iroh archive
(`target/release/libiroh_c_ffi.a`), so the packaged app is roughly 26 MB on
macOS. WebKit is a system framework dependency of the Native SDK's macOS host,
not a framework or WebView payload bundled in the app.

## Requirements

Node.js 24+ on PATH (the TypeScript frontend
and the core compiler run at build time; your shipped binary carries
none of it).
