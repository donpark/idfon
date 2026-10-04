// Load an optional/bundlable package at runtime.
//
// The Eve bundler enforces that authored modules only import installed
// packages, which would force every voice provider and the Opus decoder to be
// present. This indirection is opaque to the bundler, so the agent builds
// without them and a missing package fails only when that path is used:
//
//   "Install it with your package manager to use this voice provider."
export const optionalImport = new Function("specifier", "return import(specifier)") as (
  specifier: string,
) => Promise<Record<string, unknown>>;
