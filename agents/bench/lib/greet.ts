// Greet-floor bench (docs/benchmarks.md §2): the model-free floor of a voice
// call's "time to answer" — N text round trips through a real eve-idfon holder
// with a deterministic instant-reply fixture agent. Measures exactly what the
// greeting turn pays before the model: two message transports (invite + reply),
// holder ingest, and the agent-IPC hop. The cold first exchange is its own
// sample: it races the endpoint's initial pkarr publish, the suspected source
// of intermittent multi-second (worst case ~30 s) answer tails.
//
// Emit one `voice-agent: answer` marker line per sample so the same
// report/baseline machinery (report.ts) checks it for regressions.
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import * as net from "node:net";
import { idfon, idfondBin, stats, waitReady, repoRoot } from "./idfon.ts";

const eveIdfonBin = () =>
  process.env.EVE_IDFON_BIN ?? join(repoRoot, "target/release/eve-idfon");

// ---- frame codecs ----------------------------------------------------------

/** Daemon IPC: 4-byte big-endian length-prefixed JSON (crates/idfon-client). */
class Rpc {
  private conn!: net.Socket;
  private buf = Buffer.alloc(0);
  private waiters: ((frame: unknown) => void)[] = [];
  private frames: unknown[] = [];

  static async connect(path: string): Promise<Rpc> {
    const rpc = new Rpc();
    rpc.conn = net.createConnection(path);
    await new Promise((resolve, reject) => {
      rpc.conn.once("connect", resolve);
      rpc.conn.once("error", reject);
    });
    rpc.conn.on("data", (chunk) => {
      rpc.buf = Buffer.concat([rpc.buf, chunk]);
      for (;;) {
        if (rpc.buf.length < 4) return;
        const size = rpc.buf.readUInt32BE(0);
        if (rpc.buf.length < 4 + size) return;
        const frame = JSON.parse(rpc.buf.subarray(4, 4 + size).toString("utf8"));
        rpc.buf = rpc.buf.subarray(4 + size);
        const waiter = rpc.waiters.shift();
        if (waiter) waiter(frame);
        else rpc.frames.push(frame);
      }
    });
    return rpc;
  }

  private next(): Promise<unknown> {
    const queued = this.frames.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  async call(method: string, params: Record<string, unknown>): Promise<{ ok: boolean; result: Record<string, unknown> }> {
    const id = `greet-${Math.random().toString(36).slice(2)}`;
    const body = Buffer.from(JSON.stringify({ version: 2, id, method, params }), "utf8");
    const header = Buffer.alloc(4);
    header.writeUInt32BE(body.length, 0);
    this.conn.write(Buffer.concat([header, body]));
    const response = (await this.next()) as { ok: boolean; result?: Record<string, unknown> };
    return { ok: response.ok, result: response.result ?? {} };
  }

  close(): void {
    this.conn.destroy();
  }
}

/** Holder agent IPC: 4-byte little-endian length-prefixed JSON (the fixture). */
class AgentIpc {
  private conn!: net.Socket;
  private buf = Buffer.alloc(0);
  private waiters: ((frame: Record<string, unknown>) => void)[] = [];
  private frames: Record<string, unknown>[] = [];
  readonly turns: string[] = [];

  static async connect(path: string): Promise<AgentIpc> {
    const ipc = new AgentIpc();
    ipc.conn = net.createConnection(path);
    await new Promise((resolve, reject) => {
      ipc.conn.once("connect", resolve);
      ipc.conn.once("error", reject);
    });
    ipc.conn.on("data", (chunk) => {
      ipc.buf = Buffer.concat([ipc.buf, chunk]);
      for (;;) {
        if (ipc.buf.length < 4) return;
        const size = ipc.buf.readUInt32LE(0);
        if (ipc.buf.length < 4 + size) return;
        const frame = JSON.parse(ipc.buf.subarray(4, 4 + size).toString("utf8"));
        ipc.buf = ipc.buf.subarray(4 + size);
        const waiter = ipc.waiters.shift();
        if (waiter) waiter(frame);
        else ipc.frames.push(frame);
      }
    });
    void ipc.serve();
    return ipc;
  }

  /** Instant-reply fixture agent: every turn.in gets a reply.out echo. */
  private async serve(): Promise<void> {
    try {
      for (;;) {
        const frame = await this.next();
        if (frame.type === "voice.info") continue;
        if (frame.type !== "turn.in") continue;
        this.turns.push(String(frame.text ?? ""));
        this.write({ type: "reply.out", in_reply_to: frame.message_id, text: `GREET-REPLY ${frame.text}` });
      }
    } catch (error) {
      this.error = String(error);
    }
  }

  error = "";

  private next(): Promise<Record<string, unknown>> {
    const queued = this.frames.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  private write(frame: Record<string, unknown>): void {
    const body = Buffer.from(JSON.stringify(frame), "utf8");
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length, 0);
    this.conn.write(Buffer.concat([header, body]));
  }

  close(): void {
    this.conn.destroy();
  }
}

// ---- bench -----------------------------------------------------------------

export interface GreetResult {
  coldMs: number | null;
  warmMs: number[];
  stalls: number;
  turns: number;
}

/**
 * Spawn a caller daemon + eve-idfon holder + fixture agent and time N
 * greet-style round trips (send -> reply event on the caller). The first
 * exchange is labeled `greet-floor-cold`, the rest `greet-floor`.
 */
export async function runGreet(count: number): Promise<GreetResult> {
  const work = mkdtempSync(join(tmpdir(), "idfon-greet-"));
  const children: ChildProcess[] = [];
  const socket = (name: string) => join(work, `${name}.sock`);
  let agent: AgentIpc | null = null;
  let holderStderrAll = "";
  let daemonStderrAll = "";
  try {
    // Caller daemon (short-lived, like the matrix spawns).
    const daemon = spawn(idfondBin(), ["--socket", socket("a"), "--data-dir", join(work, "a")], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    daemon.stdout?.on("data", () => {});
    daemon.stderr?.on("data", (c) => (daemonStderrAll += String(c)));
    children.push(daemon);
    await waitReady(socket("a"));
    const { stdout: statusOut } = await idfon(["status", "--json"], { socket: socket("a") });
    const status = JSON.parse(statusOut);
    const aPid = (status.result ?? status).identity.public_key;

    // Holder with a deterministic fixture agent (scripts/eve-holder-e2e.sh).
    const keyFile = join(work, "holder.key");
    writeFileSync(keyFile, "11".padStart(64, "0"));
    const { stdout: ticketOut } = await run(eveIdfonBin(), ["--key-file", keyFile, "ticket", "--subject", aPid]);
    // The ticket is a JSON object on the wire (the CLI parses --capability-ticket
    // as JSON); passing the raw string silently drops it — the holder then
    // rejects with "message.receive capability denied".
    const holderTicket = JSON.parse(ticketOut.trim()) as Record<string, unknown>;
    const holderSock = socket("holder");
    const holder = spawn(
      eveIdfonBin(),
      ["--key-file", keyFile, "serve", "--socket", holderSock, "--allow", aPid, "--blob-dir", join(work, "blobs")],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    children.push(holder);
    holder.stderr?.on("data", (c) => (holderStderrAll += String(c)));
    const holderAddr = await firstLine(holder.stdout!);
    const holderPid = JSON.parse(holderAddr).id as string;
    if (process.env.GREET_DEBUG) console.error("holder", holderPid, holderAddr.slice(0, 120));

    agent = await AgentIpc.connect(holderSock);

    // Pair the caller with the holder, exactly like the e2e.
    await idfon(["peer", "add", holderPid, "--name", "greet-holder", "--endpoint-id", holderPid, "--endpoint-addr", holderAddr], { socket: socket("a") });
    await idfon(["access", "allow", "--subject", holderPid, "--capability", "message.send"], { socket: socket("a") });
    // Settle before the first send: a send racing the holder's first pkarr
    // publish fails and DNS-negative-caches the peer's endpoints, poisoning
    // every fast retry for tens of seconds (the known first-send race — the
    // apps' first call after a daemon/holder restart pays it; see
    // docs/benchmarks.md). Without the settle every sample measures the race.
    await new Promise((r) => setTimeout(r, Number(process.env.GREET_SETTLE_MS ?? 3_000)));

    // Round trips over persistent UDS connections (no CLI spawn overhead):
    // one for sends, one for event polls. `wait` is not a blocking long poll
    // (it is `events` truncated to one), so poll `events` at 10 ms — the
    // reply-arrival quantization of every sample (~5 ms average).
    const sendRpc = await Rpc.connect(socket("a"));
    const waitRpc = await Rpc.connect(socket("a"));
    const seeded = await waitRpc.call("events", {});
    let cursor = ((seeded.result.events as unknown[] | undefined)?.at(-1) as { cursor?: string } | undefined)?.cursor;

    const warmMs: number[] = [];
    let coldMs: number | null = null;
    let stalls = 0;
    for (let i = 0; i < count; i++) {
      const tag = `GREET-BENCH ${i}`;
      const started = performance.now();
      // Bench-level send retry (fresh idempotency key) on top of the daemon's
      // default retries: a failed send's recovery time stays in the sample.
      let sent: { ok: boolean; result: Record<string, unknown> } | null = null;
      for (let attempt = 0; attempt < 3 && !sent?.ok; attempt++) {
        if (attempt > 0) await new Promise((r) => setTimeout(r, 500));
        sent = await sendRpc.call("message.send", {
          to: holderPid,
          text: tag,
          idempotency_key: `greet-bench-${i}-${attempt}`,
          capability_ticket: holderTicket,
        });
        if (process.env.GREET_DEBUG) console.error("send", i, attempt, JSON.stringify(sent));
      }
      let round: number | null = null;
      for (;;) {
        const wait = await waitRpc.call("events", cursor ? { after: cursor } : {});
        if (process.env.GREET_DEBUG) console.error("events", i, JSON.stringify(wait).slice(0, 400));
        const events = (wait.result.events as { cursor?: string; data?: unknown }[] | undefined) ?? [];
        for (const event of events) {
          cursor = event.cursor ?? cursor;
          const json = JSON.stringify(event.data ?? {});
          if (json.includes(`GREET-REPLY ${tag}`)) {
            round = performance.now() - started;
          }
        }
        if (round !== null) break;
        if (performance.now() - started > 30_000) break; // stalled round
        await new Promise((r) => setTimeout(r, 10));
      }
      if (round === null) {
        stalls += 1; // stalled round: excluded from percentiles
        continue;
      }
      if (coldMs === null) coldMs = round;
      else warmMs.push(round);
    }
    return { coldMs, warmMs, stalls, turns: agent.turns.length };
  } finally {
    if (process.env.GREET_DEBUG) {
      console.error("fixture turns=", agent?.turns.length, "fixture error=", agent?.error ?? "none");
      console.error("holder stderr:", holderStderrAll);
      console.error("daemon stderr:", daemonStderrAll.split("\n").slice(-30).join("\n"));
    }
    agent?.close();
    for (const child of children) child.kill("SIGTERM");
    if (process.env.GREET_KEEP) console.error(`greet: kept work dir ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

/** Read the first non-empty stdout line of a spawned process. */
function firstLine(stream: NodeJS.ReadableStream): Promise<string> {
  return new Promise((resolve, reject) => {
    let text = "";
    stream.on("data", (chunk) => {
      text += String(chunk);
      const line = text.split("\n").find((l) => l.trim());
      if (line) resolve(line.trim());
    });
    stream.on("error", reject);
    stream.on("end", () => reject(new Error(`holder produced no ticket line: ${text}`)));
  });
}

function run(bin: string, args: string[]): Promise<{ stdout: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (c) => (stdout += String(c)));
    child.stderr?.on("data", (c) => (stderr += String(c)));
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0 ? resolve({ stdout }) : reject(new Error(`${bin} exited ${code}: ${stderr}`)),
    );
  });
}

/** Marker lines + a summary row, in report.ts's `answer` marker shape. */
export function formatGreet(result: GreetResult): string {
  const lines: string[] = [];
  if (result.coldMs !== null) {
    lines.push(
      `idfon-auto: voice-agent: answer label=greet-floor-cold greet_ms=${Math.round(result.coldMs)} total_ms=${Math.round(result.coldMs)}`,
    );
  }
  for (const ms of result.warmMs) {
    lines.push(
      `idfon-auto: voice-agent: answer label=greet-floor greet_ms=${Math.round(ms)} total_ms=${Math.round(ms)}`,
    );
  }
  const all = [result.coldMs, ...result.warmMs].filter((v): v is number => v !== null);
  lines.push("");
  if (all.length > 0) {
    const s = stats(all);
    lines.push(
      `greet floor: n=${all.length} stalls=${result.stalls} p50=${s.p50.toFixed(1)}ms p95=${s.p95.toFixed(1)}ms max=${s.max.toFixed(1)}ms` +
        (result.coldMs !== null ? ` (cold first exchange: ${result.coldMs.toFixed(1)}ms)` : ""),
    );
  } else {
    lines.push("greet floor: all rounds stalled");
  }
  return lines.join("\n");
}

/** Append marker rows to the JSONL history (bench-results/, gitignored). */
export function appendGreetHistory(result: GreetResult, out?: string): string {
  const resultsDir = join(repoRoot, "bench-results");
  mkdirSync(resultsDir, { recursive: true });
  const path = out ?? join(resultsDir, `greet-${new Date().toISOString().slice(0, 10)}.jsonl`);
  const stamp = new Date().toISOString();
  const rows: Array<{ label: string; greet_ms: number }> = [];
  if (result.coldMs !== null) rows.push({ label: "greet-floor-cold", greet_ms: Math.round(result.coldMs) });
  for (const ms of result.warmMs) rows.push({ label: "greet-floor", greet_ms: Math.round(ms) });
  for (const row of rows) appendFileSync(path, JSON.stringify({ ts: stamp, ...row }) + "\n");
  return path;
}
