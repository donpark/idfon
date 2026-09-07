#!/usr/bin/env node
"use strict";
// Thin launcher: resolves the prebuilt platform binary and execs it with all
// arguments. The CLI itself (and the idfond daemon it auto-spawns from its own
// directory) does all the work; no logic lives here beyond platform selection.

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const packages = {
  "darwin-arm64": "idfon-darwin-arm64",
  "darwin-x64": "idfon-darwin-x64",
  "linux-arm64": "idfon-linux-arm64",
  "linux-x64": "idfon-linux-x64",
  // ponytail: no win32 — idfond IPC is a Unix socket (std::os::unix); add a
  // named-pipe transport to idfon-client first, then an idfon-win32-x64 package.
};

const key = `${process.platform}-${process.arch}`;
const pkg = packages[key];
if (!pkg) {
  console.error(`idfon: no prebuilt binary for ${key}`);
  console.error(`supported platforms: ${Object.keys(packages).join(", ")}`);
  process.exit(1);
}

let bin;
try {
  bin = path.join(
    path.dirname(require.resolve(`${pkg}/package.json`)),
    "bin",
    "idfon"
  );
} catch (err) {
  // Repo-layout fallback: platform packages sitting at npm/* without a
  // node_modules install (dev use, scripts/build-npm.sh output).
  const devBin = path.join(__dirname, "..", "..", pkg, "bin", "idfon");
  if (fs.existsSync(devBin)) {
    bin = devBin;
  } else {
    console.error(`idfon: platform package ${pkg} is not installed (${err.code || err.message})`);
    console.error("reinstall with: npm install idfon");
    process.exit(1);
  }
}

const args = process.argv.slice(2);
let child;
try {
  child = spawn(bin, args, { stdio: "inherit" });
} catch (err) {
  if (err.code === "EACCES") {
    // Some environments strip the exec bit from installed files.
    try {
      fs.chmodSync(bin, 0o755);
    } catch {}
    child = spawn(bin, args, { stdio: "inherit" });
  } else {
    throw err;
  }
}

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => child.kill(sig));
}
child.on("error", (err) => {
  console.error(`idfon: failed to run ${bin}: ${err.message}`);
  process.exit(1);
});
child.on("exit", (code, signal) => {
  process.exit(signal ? 1 : (code ?? 0));
});
