# iOS SDK patches (ios-trial)

The `native` CLI binary is prebuilt, but the SDK's build graph and mobile
wiring templates are **source** compiled per app build. Two files in
`@native-sdk/cli` are patched (generic, upstream-able seams) and copies are
kept here because node_modules is not a repo — re-copy after reinstalling:

```
ios-sdk-patches/build_app.zig      -> ~/.nvm/versions/node/v24.20.0/lib/node_modules/@native-sdk/cli/build/app.zig
ios-sdk-patches/ts_core_mobile.zig -> ~/.nvm/versions/node/v24.20.0/lib/node_modules/@native-sdk/cli/src/app_runner/ts_core_mobile.zig
```

## build_app.zig: `mobile_host` seam

- `AppOptions.mobile_host: ?MobileHostConfig` — a module exposing
  `binding()` (same contract as the desktop generated runner's
  `host_calls` seam), imported into the staged mobile wiring as
  `app_host`. `MobileHostConfig` carries the root file, include dirs,
  link_libc, and object files (the Rust static archive).
- The staged mobile options gain `custom_host = true` so the template can
  reference the import without breaking apps that don't declare it
  (module files may only belong to one module, so the options module is
  created once and shared).

## ts_core_mobile.zig: consume the seam

```zig
const use_app_host = mobile_build_options.custom_host;
const app_host = if (use_app_host) @import("app_host") else struct {};
...
if (comptime (!use_pool and use_app_host)) {
    core_options.host_calls = app_host.binding();
}
```

This mirrors the desktop generated runner, which falls back to the app's
custom host binding when no service pool/child carrier is staged — on
mobile there was previously no way to handle commands like
`idfond.request` at all.
