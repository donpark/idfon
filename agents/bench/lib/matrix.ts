// Relay A/B matrix over the real daemon stack (docs/benchmarks.md).
//
// Spawns two short-lived `idfond` daemons per relay config (the same env knobs
// the apps use: IDFON_RELAY_URLS / IDFON_RELAY_TOKEN / IDFON_RELAY_ONLY),
// pairs them the way scripts/test-e2e.sh does, and measures what a voice turn
// actually pays:
//
//   msg_ms     `send --text` -> `operation wait` (delivery ack): a fresh QUIC
//              connection + message envelope + ack, per message — the exact
//              per-turn transport cost
//   blob_mbps  `send --file` round trip (chunked transfer + delivery)
//
// `*-relay-only` rows force the relay path (IDFON_RELAY_ONLY drops IP
// transports), so the relay comparison is honest even on one host. The other
// rows take whatever path iroh picks (usually direct on one host). There is no
// selected-path introspection in the daemon CLI yet — see docs/benchmarks.md.
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, appendFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { idfon, idfondBin, pair, stats, timed, waitReady, repoRoot } from "./idfon.ts";

export interface MatrixRow {
  label: string;
  n?: number;
  msg_ms?: { p50: number; p95: number; max: number };
  stalls?: number;
  blob_mbps?: number;
  relay_urls?: string;
  relay_only?: boolean;
  error?: string;
}

export interface MatrixOpts {
  relayUrl?: string;
  count?: number;
  blobBytes?: number;
}

const DEFAULT_RELAY = "https://relay.idfon.net:8443";

/** Daemon env for matrix spawns: shared_token falls back to the local secret
 * file (~/.idfon/relay-token) so direct `bench.ts` and agent tools work too. */
function daemonEnv(): NodeJS.ProcessEnv {
  if (process.env.IDFON_RELAY_TOKEN) return process.env;
  const file = join(process.env.HOME ?? "", ".idfon", "relay-token");
  if (!existsSync(file)) return process.env;
  return { ...process.env, IDFON_RELAY_TOKEN: readFileSync(file, "utf8").trim() };
}

/**
 * Time one text message end to end (send -> delivery ack).
 * Returns null when the operation did not reach `delivered` in time — a stall,
 * recorded as such rather than blended into the percentiles.
 */
export async function messageRttMs(
  socket: string,
  peer: string,
  tag: string,
): Promise<number | null> {
  const { ms, value } = await timed(async () => {
    const { stdout } = await idfon(["--json", "send", peer, "--text", `BENCH-PING ${tag}`], { socket });
    const result = JSON.parse(stdout).result;
    const { stdout: waited } = await idfon(
      ["--json", "operation", "wait", String(result.operation_id), "--timeout-ms", "30000"],
      { socket, timeoutMs: 45_000 },
    );
    return JSON.parse(waited).result?.operation?.status;
  });
  return value === "delivered" ? ms : null;
}

/** Time a chunked blob transfer + delivery; returns Mbps of payload. */
export async function blobMbps(
  socket: string,
  peer: string,
  file: string,
  bytes: number,
): Promise<number> {
  const { ms } = await timed(() =>
    idfon(["--json", "send", peer, "--file", file], { socket, timeoutMs: 120_000 }),
  );
  return (bytes * 8) / (ms * 1000);
}

type MatrixResult = Pick<MatrixRow, "msg_ms" | "stalls" | "blob_mbps" | "n" | "error">;

/** The measurement body shared by the matrix and the rtt command. */
async function measureExchange(
  socket: string,
  peer: string,
  count: number,
  blobBytes: number,
): Promise<MatrixResult> {
  try {
    // Warmup: the first send can race the endpoint's initial pkarr publish
    // (DNS-negative-cached retries stall it); absorb that before timing.
    await messageRttMs(socket, peer, "warmup");
    const samples: number[] = [];
    let stalls = 0;
    for (let i = 0; i < count; i++) {
      const ms = await messageRttMs(socket, peer, `bench-${i}`);
      if (ms === null) stalls += 1;
      else samples.push(ms);
    }
    if (samples.length === 0) return { error: `all ${count} messages stalled (no delivery ack)`, stalls };
    const work = mkdtempSync(join(tmpdir(), "idfon-blob-"));
    try {
      const blob = join(work, "payload.bin");
      writeFileSync(blob, Buffer.alloc(blobBytes, 0x5a));
      const blob_mbps = await blobMbps(socket, peer, blob, blobBytes);
      return { msg_ms: stats(samples), stalls, blob_mbps, n: count };
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  } catch (error) {
    return { error: firstLine(error) };
  }
}

/** Measure one relay config against a fresh, freshly-paired daemon pair. */
export async function measurePair(
  label: string,
  env: NodeJS.ProcessEnv,
  opts: MatrixOpts,
): Promise<MatrixResult> {
  const count = opts.count ?? 10;
  const blobBytes = opts.blobBytes ?? 1024 * 1024;
  const work = mkdtempSync(join(tmpdir(), `idfon-matrix-${label}-`));
  const children: ChildProcess[] = [];
  const socket = (name: string) => join(work, `${name}.sock`);
  try {
    for (const name of ["a", "b"]) {
      const child = spawn(idfondBin(), ["--socket", socket(name), "--data-dir", join(work, name)], {
        env: { ...daemonEnv(), ...env },
        stdio: ["ignore", "pipe", "pipe"],
      });
      // Drain so a chatty daemon never blocks on a full pipe buffer.
      child.stdout?.on("data", () => {});
      child.stderr?.on("data", () => {});
      children.push(child);
    }
    await waitReady(socket("a"));
    await waitReady(socket("b"));
    await pair(socket("a"), socket("b"));
    return await measureExchange(socket("a"), "bench-b", count, blobBytes);
  } catch (error) {
    return { error: firstLine(error) };
  } finally {
    for (const child of children) child.kill("SIGTERM");
    rmSync(work, { recursive: true, force: true });
  }
}

function firstLine(error: unknown): string {
  return String(error instanceof Error ? error.message : error).split("\n")[0];
}

/** The default config matrix: N0 vs the private relay, natural vs forced. */
export async function runMatrix(opts: MatrixOpts): Promise<MatrixRow[]> {
  const relay = opts.relayUrl ?? DEFAULT_RELAY;
  const configs: Array<{ label: string; env: NodeJS.ProcessEnv }> = [
    { label: "n0", env: {} },
    { label: "n0-relay-only", env: { IDFON_RELAY_ONLY: "1" } },
    { label: "idfon", env: { IDFON_RELAY_URLS: relay } },
    { label: "idfon-relay-only", env: { IDFON_RELAY_URLS: relay, IDFON_RELAY_ONLY: "1" } },
  ];
  const rows: MatrixRow[] = [];
  for (const config of configs) {
    const result = await measurePair(config.label, config.env, opts);
    rows.push({
      label: config.label,
      relay_urls: config.env.IDFON_RELAY_URLS ?? "n0-default",
      relay_only: config.env.IDFON_RELAY_ONLY === "1",
      ...result,
    });
  }
  return rows;
}

/** Measure against an already-running daemon's peer (that daemon's config). */
export async function runRtt(opts: {
  socket?: string;
  peer: string;
  count?: number;
  blobBytes?: number;
}): Promise<MatrixRow[]> {
  const socket = opts.socket ?? process.env.IDFON_SOCKET ?? "/tmp/idfon/idfond.sock";
  const count = opts.count ?? 10;
  const result = await measureExchange(socket, opts.peer, count, opts.blobBytes ?? 1024 * 1024);
  return [{ label: `rtt:${opts.peer}`, ...result }];
}

export function formatMatrix(rows: MatrixRow[]): string {
  const header =
    `${"label".padEnd(18)} ${"relays".padEnd(26)} ${"only".padEnd(5)} ${"msg p50".padStart(8)} ${"msg p95".padStart(8)} ${"msg max".padStart(8)} ${"stalls".padStart(7)} ${"Mbps".padStart(8)}`;
  const lines = [header, "-".repeat(header.length)];
  for (const row of rows) {
    if (row.error) {
      lines.push(`${row.label.padEnd(18)} FAILED: ${row.error}`);
      continue;
    }
    lines.push(
      `${row.label.padEnd(18)} ${String(row.relay_urls).slice(0, 26).padEnd(26)} ${(row.relay_only ? "yes" : "no").padEnd(5)} ` +
        `${row.msg_ms!.p50.toFixed(1).padStart(8)} ${row.msg_ms!.p95.toFixed(1).padStart(8)} ${row.msg_ms!.max.toFixed(1).padStart(8)} ` +
        `${String(`${row.stalls ?? 0}/${row.n}`).padStart(7)} ` +
        `${row.blob_mbps!.toFixed(1).padStart(8)}`,
    );
  }
  return lines.join("\n");
}

/** Append rows to the JSONL history (bench-results/, gitignored). */
export function appendHistory(rows: MatrixRow[], out?: string): string {
  const resultsDir = join(repoRoot, "bench-results");
  mkdirSync(resultsDir, { recursive: true });
  const path = out ?? join(resultsDir, `relay-${new Date().toISOString().slice(0, 10)}.jsonl`);
  const stamp = new Date().toISOString();
  for (const row of rows) appendFileSync(path, JSON.stringify({ ts: stamp, ...row }) + "\n");
  return path;
}
