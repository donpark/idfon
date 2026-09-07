# Draft issues for github.com/vercel-labs/native

Style matched to #425 (area prefix, repro-first, exact error text, Notes
with suggested fixes). Environment common to all three:

    - native 0.10.1 (`064ca98`), CLI reports `native 0.10.1 (commit 064ca98, automation protocol 0x51f7889bbe3305e7)`
    - macOS 26.6.2 (arm64), Xcode 26.6
    - Zig 0.16.0, Node v24.20.0

Repro for #1/#2 needs nothing beyond `native init` — any TypeScript-core
app fails identically.

---

## 1 — filed: https://github.com/vercel-labs/native/issues/428

**Title:** `ios: native dev --target ios fails to link — zig-built archive members not 8-byte aligned for Apple ld`

An embed static library built by the iOS dev loop is rejected by
Xcode's linker before the app can ever run: `native dev --target ios`
fails on **every** TypeScript-core app at the host-compile step, with a
low-level `ld` error about archive member alignment. The `zig build lib`
step itself succeeds; the failure happens when the toolkit-owned UIKit
host is linked against the archive it just produced.

## Repro

```bash
native init demo && cd demo
native dev --target ios
```

**Expected:** the embed library builds, the UIKit host compiles and
links, the app installs and launches in the simulator.

**Actual:**

```
native dev (ios): compiling the toolkit UIKit host
ld: 64-bit mach-o member 'libIdfon_zcu.o' not 8-byte aligned in '.native/embed/aarch64-ios-simulator/lib/libIdfon.a'
clang: error: linker command failed with exit code 1 (use -v to see invocation)
native (ios): `xcrun` step failed
```

Modern ld64 requires 64-bit mach-o archive members to be 8-byte aligned;
the archive zig emits doesn't guarantee that. Xcode 26.6's ld enforces
it.

## Workaround

Extract the members and repack with `libtool` before the link:

```sh
mkdir repack && cd repack
xcrun ar x ../libIdfon.a
chmod 644 *.o          # members extract with mode 000
rm -f __.SYMDEF*
xcrun libtool -static -o ../libIdfon-aligned.a *.o
```

**Gotcha for the fix:** repacking *from the archive directly*
(`libtool -static -o out.a in.a`) is not equivalent — it silently drops
members, and the linked app then fails with all 48 `_native_sdk_app_*`
C-API symbols undefined. Members must be extracted first, then repacked
from the individual `.o` files. Worth an assertion after any repack
(`nm -g` still finds `_native_sdk_app_create`).

## Notes

- Fix lives in `src/tooling/ios.zig` (and the xcodeproj packaging path):
  repack the embed archive after `buildEmbedLib`, before the clang link.
  Cheap relative to the build.
- The alignment failure and the UBSan failure (sibling issue) are
  independent — fixing one does not unblock `native dev --target ios`;
  both must be fixed for the dev loop to complete.

---

## 2 — filed: https://github.com/vercel-labs/native/issues/429

**Title:** `ios: Debug builds fail to link — core archive references UBSan runtime the host link never provides`

With the archive-alignment failure worked around, `native dev --target
ios` in **Debug** still fails at the same clang link: the scriptc
runtime objects inside the Debug core archive reference
`___ubsan_handle_*`, but the toolkit's host link command provides no
sanitizer runtime. ReleaseFast builds are unaffected (no UBSan
references), which is presumably why the dev loop's release path was
never exercised against this.

## Repro

Same as the sibling issue: any app, `native dev --target ios`, after
working around the archive alignment. The link then fails with ~13
undefined-symbol families, e.g.:

```
Undefined symbols for architecture arm64:
  "___ubsan_handle_add_overflow", referenced from:
      _scr_bytes_from_str in libIdfon.a[8](scr_bytes.o)
  "___ubsan_handle_type_mismatch_v1", referenced from:
      _scr_arr_new in libIdfon.a[6](scr_array.o)
  ... (shift_out_of_bounds, mul/sub/negate_overflow, out_of_bounds,
       pointer_overflow, load_invalid_value, builtin_unreachable, ...)
```

## Control

`native build` for the same app in ReleaseFast links fine — the UBSan
references are Debug-only.

## Workaround (verified)

Link the simulator ubsan runtime into the app and bundle it:

```sh
UB=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_iossim_dynamic.dylib
xcrun lipo -thin arm64 "$UB" -output "$APP/libclang_rt.ubsan_iossim_dynamic.dylib"
# add to the host clang command:
#   $APP/libclang_rt.ubsan_iossim_dynamic.dylib -rpath @executable_path
# then codesign both the dylib and the .app
```

## Notes

Suggested fixes, either works:

- (a) link the ubsan runtime for Debug builds (the bundle assembly is
  already in `ios.zig`, so embedding the dylib + `-rpath
  @executable_path` fits the existing flow), or
- (b) compile the scriptc runtime objects without sanitizers so Debug
  archives carry no UBSan references — simpler, removes the dylib
  dependency entirely.

---

## 3 — filed: https://github.com/vercel-labs/native/issues/430

**Title:** `ts-core: no official way to route Cmd.request into native code — patch-only on desktop, impossible on mobile`

A TypeScript core reaches the host with `Cmd.request(name, ...)`, which
routes through `runtime.effects.HostCallBinding`. `HostCallBinding` is a
public type and `bindHostCalls()` is public runtime API, but **no
generated path ever installs an app-authored binding** — every generated
entry point either wires the service carriers or `null`, and `null`
rejects all non-reserved host requests
(`src/runtime/effects.zig`: `if (!fake and self.host_calls == null ...)
return self.rejectStartedHost(...)`).

So for the SDK's default authoring path, apps whose effects go beyond
the built-in command set — custom IPC to a native daemon/service,
BLE/hardware, proprietary vendor SDKs — cannot route commands into
native code at all. The `src/services` escape hatch doesn't apply:
services are TypeScript and can never reach C FFI.

## What each target does today

- **Desktop:** the generated runner hardcodes the choice
  (`src/app_runner/ts_core_main.zig`):
  ```zig
  .host_calls = if (comptime use_pool)
      pool_transport.binding()
  else if (comptime use_child)
      child_transport.binding()
  else
      null,   // no app-authored binding possible
  ```
  Real apps doing native effects work around this by patching the
  generated runner in zig-cache after the build stages it (add an
  `@import` of a host module, wire its `binding()` in). Undocumented and
  fragile, but possible.

- **Mobile:** the staged mobile wiring
  (`src/app_runner/ts_core_mobile.zig`) sets `host_calls` from the
  in-process service pool only. There is no generated file an app can
  plausibly patch — it stages fresh from the SDK template on every
  build — so this is impossible, not just undocumented.

- **The C ABI shows the intended pattern but stops short:**
  `native_sdk_app_set_audio_service` / `_set_credential_service` /
  `_set_image_service` are native-side registration seams, but there is
  no host-call equivalent. `bindHostCalls()` is only reachable by an
  embedder that owns the runtime loop — and the iOS tier deliberately
  owns it (`src/tooling/ios.zig`: "the toolkit owns the entire iOS
  app"), locking embedders out of the one API that would solve this.

- A **Zig core** avoids the problem by construction (its logic is native
  code and calls FFI directly), which makes the gap specific to TS
  cores — the default path.

## Notes / proposal

A small symmetric seam in both generated runners. We run this today
(against 0.10.1) on mobile and are happy to turn it into a PR:

- `AppOptions.mobile_host` (or a manifest declaration — may be cleaner):
  a module exposing `binding()` with the same contract as the desktop
  runner's `host_calls` value, plus its include dirs / object files.
- The build graph imports it into the staged mobile wiring as
  `app_host`; the wiring references it under a comptime flag so apps
  without it never touch the import. Implementation note from doing
  this: the generated options module must be created **once** and shared
  between the exports and app modules — a file may belong to only one
  zig module.
- Desktop mirrors it in the generated runner's `else null` fallback.

Happy to reshape to whatever fits (manifest-declared host module seems
most in keeping with app.json/app.zon being the single source of app
truth).
