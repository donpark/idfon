// Thin wrappers over the prebuilt `idfon` CLI / `idfond` daemon (the npm
// `idfon` platform packages ship both — docs/npm-distribution.md). The bench
// vertical never compiles Rust: third-party agent developers run it against
// whatever prebuilt binaries they have.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// agents/bench/lib/ -> repo root (repo checkout only; npm installs resolve via
// IDFON_CLI or PATH).
export const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

function resolveBin(envVar: string, repoPath: string, name: string): string {
  const fromEnv = process.env[envVar];
  if (fromEnv) return fromEnv;
  const fromRepo = join(repoRoot, repoPath);
  if (existsSync(fromRepo)) return fromRepo;
  return name; // PATH (npm-installed `idfon` platform package)
}

/** `idfon` CLI: env IDFON_CLI, repo build, or PATH. */
export const idfonBin = () => resolveBin("IDFON_CLI", "target/release/idfon", "idfon");
/** `idfond` daemon: env IDFOND_BIN, repo build, or PATH. */
export const idfondBin = () => resolveBin("IDFOND_BIN", "target/release/idfond", "idfond");

export interface RunResult {
  stdout: string;
  stderr: string;
}

/** Run a command, capture output, throw on non-zero exit. */
export function run(
  bin: string,
  args: string[],
  opts: { env?: NodeJS.ProcessEnv; input?: string; timeoutMs?: number } = {},
): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const child = execFile(
      bin,
      args,
      {
        env: { ...process.env, ...opts.env },
        timeout: opts.timeoutMs ?? 120_000,
        maxBuffer: 64 * 1024 * 1024,
      },
      (error, stdout, stderr) => {
        if (error) {
          const detail = [stderr.trim(), stdout.trim()]
            .filter(Boolean)
            .join("\n") || error.message;
          reject(new Error(`${detail}\n(command: ${bin} ${args.join(" ")})`));
          return;
        }
        resolve({ stdout, stderr });
      },
    );
    if (opts.input !== undefined) child.stdin?.end(opts.input);
  });
}

/** Run the `idfon` CLI against a daemon socket (env IDFON_SOCKET selects one). */
export function idfon(
  args: string[],
  opts: { socket?: string; env?: NodeJS.ProcessEnv; input?: string; timeoutMs?: number } = {},
): Promise<RunResult> {
  const withSocket = opts.socket ? ["--socket", opts.socket, ...args] : args;
  return run(idfonBin(), withSocket, opts);
}

/** The `status --json` payload: identity, endpoint id, and endpoint addr. */
export async function daemonIdentity(socket: string): Promise<{
  endpointId: string;
  publicKey: string;
  endpointAddr: string;
}> {
  const { stdout } = await idfon(["status", "--json"], { socket });
  const parsed = JSON.parse(stdout);
  const result = parsed.result ?? parsed;
  // `ticket` serializes as a JSON array of byte values (jq: `implode`).
  const raw = result.ticket;
  const endpointAddr = Array.isArray(raw) ? String.fromCharCode(...raw) : String(raw);
  return {
    endpointId: result.identity.endpoint_id,
    publicKey: result.identity.public_key,
    endpointAddr,
  };
}

/** Poll until `status --json` answers, or throw. */
export async function waitReady(socket: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      await idfon(["status", "--json"], { socket, timeoutMs: 2_000 });
      return;
    } catch (error) {
      if (Date.now() > deadline) throw new Error(`daemon on ${socket} not ready: ${error}`);
      await new Promise((r) => setTimeout(r, 200));
    }
  }
}

/** Cross-pair two daemons exactly like scripts/test-e2e.sh does. */
export async function pair(a: string, b: string): Promise<void> {
  const idA = await daemonIdentity(a);
  const idB = await daemonIdentity(b);
  await idfon(["peer", "add", idB.publicKey, "--name", "bench-b", "--endpoint-id", idB.endpointId, "--endpoint-addr", idB.endpointAddr], { socket: a });
  await idfon(["peer", "add", idA.publicKey, "--name", "bench-a", "--endpoint-id", idA.endpointId, "--endpoint-addr", idA.endpointAddr], { socket: b });
  await idfon(["access", "allow", "--subject", idB.publicKey, "--capability", "message.send"], { socket: a });
  await idfon(["access", "allow", "--subject", idA.publicKey, "--capability", "message.receive"], { socket: b });
}

/** Millisecond timing of one async call. */
export async function timed<T>(fn: () => Promise<T>): Promise<{ ms: number; value: T }> {
  const started = performance.now();
  const value = await fn();
  return { ms: performance.now() - started, value };
}

/** Nearest-rank percentiles over ms samples. */
export function stats(samples: number[]): { p50: number; p95: number; max: number } {
  const ordered = [...samples].sort((x, y) => x - y);
  const at = (q: number) => ordered[Math.round(q * (ordered.length - 1))] ?? 0;
  return { p50: at(0.5), p95: at(0.95), max: ordered[ordered.length - 1] ?? 0 };
}
