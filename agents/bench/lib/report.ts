// Voice-turn stage report (docs/benchmarks.md): turns `idfon-auto` marker logs
// into per-stage latency tables. TS port of the original python parser; one
// implementation, used by the bench agent tool and `scripts/voice-latency-report.sh`.
//
// Reads the per-turn marker VoiceAgentSession writes (iOS + mac apps):
//   idfon-auto: voice-agent: turn=3 asr_gap_ms=1240 listen_ms=2100 reply_ms=870
//               speak_ms=2600 total_ms=6810
//
//   asr_gap_ms  turn detection: recognizer's last update -> commit (the
//               VoicePromptSegmenter silence gap; ~1200-1500 on the fallback
//               path, ~0 when the recognizer commits a final)
//   listen_ms   listening window for the caller's utterance
//   reply_ms    send -> agent reply arrival (network + agent turn)
//   speak_ms    TTS + playback (includes speak()'s ~800 ms post-roll hold)
//   total_ms    whole turn
//
// Older logs without `turn=` markers still get their `listen_ms=` values.

export const METRICS = ["asr_gap_ms", "listen_ms", "reply_ms", "speak_ms", "total_ms"] as const;
export type Metric = (typeof METRICS)[number];

export interface TurnRow {
  turn: number;
  [metric: string]: number;
}

export interface Report {
  turns: TurnRow[];
  legacyListenMs: number[];
}

export function parse(logText: string): Report {
  const turnRe = /idfon-auto: voice-agent: turn=(\d+)\s+(.*)/g;
  const kvRe = /(\w+)=(\d+)/g;
  const listenRe = /idfon-auto: voice-agent: asr \S+ listen_ms=(\d+)/g;
  const turns: TurnRow[] = [];
  const legacyListenMs: number[] = [];
  for (const line of logText.split("\n")) {
    const turn = turnRe.exec(line);
    turnRe.lastIndex = 0;
    if (turn) {
      const row: TurnRow = { turn: Number(turn[1]) };
      for (const [, key, value] of turn[2].matchAll(kvRe)) row[key] = Number(value);
      turns.push(row);
      continue;
    }
    const listen = listenRe.exec(line);
    listenRe.lastIndex = 0;
    if (listen) legacyListenMs.push(Number(listen[1]));
  }
  return { turns, legacyListenMs };
}

function pct(values: number[], q: number): number {
  const ordered = [...values].sort((a, b) => a - b);
  return ordered[Math.round(q * (ordered.length - 1))] ?? 0;
}

/** Human table + per-metric p50/p95/max, like the original script. */
export function format(report: Report): string {
  const { turns, legacyListenMs } = report;
  const lines: string[] = [];
  if (turns.length > 0) {
    const cols = METRICS.filter((m) => turns.some((row) => m in row));
    lines.push("turn  " + cols.map((c) => c.padStart(10)).join("  "));
    for (const row of turns) {
      lines.push(
        String(row.turn).padEnd(5) + " " +
          cols.map((c) => String(row[c] ?? "-").padStart(10)).join("  "),
      );
    }
    lines.push("");
    lines.push(`${"metric".padEnd(12)} ${"p50".padStart(8)} ${"p95".padStart(8)} ${"max".padStart(8)}  (n=${turns.length})`);
    for (const c of cols) {
      const values = turns.filter((row) => c in row).map((row) => row[c]);
      lines.push(
        `${c.padEnd(12)} ${String(pct(values, 0.5)).padStart(8)} ${String(pct(values, 0.95)).padStart(8)} ${String(Math.max(...values)).padStart(8)}`,
      );
    }
  } else if (legacyListenMs.length > 0) {
    lines.push(`listen_ms only (log predates turn= markers): n=${legacyListenMs.length}`);
    lines.push(`${"metric".padEnd(12)} ${"p50".padStart(8)} ${"p95".padStart(8)} ${"max".padStart(8)}`);
    lines.push(
      `${"listen_ms".padEnd(12)} ${String(pct(legacyListenMs, 0.5)).padStart(8)} ${String(pct(legacyListenMs, 0.95)).padStart(8)} ${String(Math.max(...legacyListenMs)).padStart(8)}`,
    );
  } else {
    return "no voice-agent turn markers found";
  }
  return lines.join("\n");
}

/** Fixture check (parity with the original script's --self-test). */
export function selfTest(): void {
  const fixture = [
    "idfon-auto: voice-agent: turn=1 asr_gap_ms=1300 listen_ms=2100 reply_ms=900 speak_ms=2500 total_ms=6800",
    "noise line that must be ignored",
    "idfon-auto: voice-agent: turn=2 asr_gap_ms=0 listen_ms=1800 reply_ms=700 speak_ms=2600 total_ms=5200",
    "idfon-auto: voice-agent: turn=3 asr_gap_ms=1250 listen_ms=1950 reply_ms=800 speak_ms=2400 total_ms=6400",
  ].join("\n");
  const out = format(parse(fixture));
  for (const needle of ["asr_gap_ms", "1300", "p50", "p95"]) {
    if (!out.includes(needle)) throw new Error(`missing ${needle} in report:\n${out}`);
  }
  // p50 of reply_ms over [900, 700, 800] is 800; max total_ms is 6800.
  if (!out.includes(" 800") || !out.includes(" 6800")) throw new Error(`unexpected percentiles:\n${out}`);
}
