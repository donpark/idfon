// Voice-turn stage report (docs/benchmarks.md): turns `idfon-auto` marker logs
// into per-stage latency tables. TS port of the original python parser; one
// implementation, used by the bench agent tool and `scripts/voice-latency-report.sh`.
//
// Reads two marker kinds VoiceAgentSession writes (iOS + mac apps):
//   idfon-auto: voice-agent: turn=3 asr_gap_ms=1240 listen_ms=2100 reply_ms=870
//               speak_ms=2600 total_ms=6810
//   idfon-auto: voice-agent: answer label=call peers_ms=12 rotate_ms=40
//               asr_ms=310 director_ms=0 greet_ms=1900 total_ms=2400
//
//   turn metrics
//   asr_gap_ms  turn detection: recognizer's last update -> commit (the
//               VoicePromptSegmenter silence gap; ~1200-1500 on the fallback
//               path, ~0 when the recognizer commits a final)
//   listen_ms   listening window for the caller's utterance
//   reply_ms    send -> agent reply arrival (network + agent turn)
//   speak_ms    TTS + playback (includes speak()'s ~800 ms post-roll hold)
//   total_ms    whole turn
//
//   answer metrics (one marker per answered call; keys present only when the
//   stage ran — 0 is a measurement, absence is "not applicable")
//   peers_ms    contact resolution (daemon peers RPC)
//   rotate_ms   session-rotate message send
//   asr_ms      recognizer start (model load / first-use compile)
//   tts_ms      reply-voice load (iOS only)
//   sleep_ms    fixed hydration settle (iOS only)
//   director_ms on-device AFM director load + warm (proxy calls)
//   greet_ms    the greeting turn round trip (network + agent turn) — the
//               floor of "time to answer"
//   total_ms    ringback start -> answered cue
//
// Older logs without `turn=` markers still get their `listen_ms=` values.
// `bench.ts report --baseline/--write-baseline` compares runs against a stored
// baseline for regression checking.

export const METRICS = ["asr_gap_ms", "listen_ms", "reply_ms", "speak_ms", "total_ms"] as const;
export type Metric = (typeof METRICS)[number];

export interface TurnRow {
  turn: number;
  [metric: string]: number;
}

export interface AnswerRow {
  label: string;
  metrics: Record<string, number>;
}

export interface Report {
  turns: TurnRow[];
  legacyListenMs: number[];
  answers: AnswerRow[];
}

export function parse(logText: string): Report {
  const turnRe = /idfon-auto: voice-agent: turn=(\d+)\s+(.*)/;
  const answerRe = /idfon-auto: voice-agent: answer\s+(.*)/;
  const kvRe = /(\w+)=(\d+)/g;
  const listenRe = /idfon-auto: voice-agent: asr \S+ listen_ms=(\d+)/;
  const turns: TurnRow[] = [];
  const legacyListenMs: number[] = [];
  const answers: AnswerRow[] = [];
  for (const line of logText.split("\n")) {
    const turn = turnRe.exec(line);
    if (turn) {
      const row: TurnRow = { turn: Number(turn[1]) };
      for (const [, key, value] of turn[2].matchAll(kvRe)) row[key] = Number(value);
      turns.push(row);
      continue;
    }
    const answer = answerRe.exec(line);
    if (answer) {
      const metrics: Record<string, number> = {};
      for (const [, key, value] of answer[1].matchAll(kvRe)) metrics[key] = Number(value);
      const label = answer[1].match(/label=(\S+)/)?.[1] ?? "answer";
      answers.push({ label, metrics });
      continue;
    }
    const listen = listenRe.exec(line);
    if (listen) legacyListenMs.push(Number(listen[1]));
  }
  return { turns, legacyListenMs, answers };
}

function pct(values: number[], q: number): number {
  const ordered = [...values].sort((a, b) => a - b);
  return ordered[Math.round(q * (ordered.length - 1))] ?? 0;
}

function statsRow(values: number[]): string {
  return `${String(pct(values, 0.5)).padStart(8)} ${String(pct(values, 0.95)).padStart(8)} ${String(Math.max(...values)).padStart(8)}`;
}

/** Human table + per-metric p50/p95/max, like the original script. */
export function format(report: Report): string {
  const { turns, legacyListenMs, answers } = report;
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
      lines.push(`${c.padEnd(12)} ${statsRow(values)}`);
    }
  }
  if (answers.length > 0) {
    if (lines.length > 0) lines.push("");
    const cols: string[] = [];
    for (const row of answers) {
      for (const key of Object.keys(row.metrics)) if (!cols.includes(key)) cols.push(key);
    }
    lines.push("label".padEnd(16) + cols.map((c) => c.padStart(11)).join("  "));
    for (const row of answers) {
      lines.push(
        row.label.padEnd(16) + cols.map((c) => String(row.metrics[c] ?? "-").padStart(11)).join("  "),
      );
    }
    lines.push("");
    lines.push(`${"metric".padEnd(12)} ${"p50".padStart(8)} ${"p95".padStart(8)} ${"max".padStart(8)}  (n=${answers.length})`);
    for (const c of cols) {
      const values = answers.filter((row) => c in row.metrics).map((row) => row.metrics[c]);
      lines.push(`${c.padEnd(12)} ${statsRow(values)}`);
    }
  }
  if (lines.length > 0) return lines.join("\n");
  if (legacyListenMs.length > 0) {
    lines.push(`listen_ms only (log predates turn= markers): n=${legacyListenMs.length}`);
    lines.push(`${"metric".padEnd(12)} ${"p50".padStart(8)} ${"p95".padStart(8)} ${"max".padStart(8)}`);
    lines.push(`${"listen_ms".padEnd(12)} ${statsRow(legacyListenMs)}`);
    return lines.join("\n");
  }
  return "no voice-agent turn markers found";
}

// MARK: baseline (regression check)

export interface Stat {
  p50: number;
  p95: number;
  max: number;
  n: number;
}

export interface Baseline {
  generated: string;
  turns: Record<string, Stat>;
  answers: Record<string, Record<string, Stat>>;
}

function statOf(values: number[]): Stat {
  return { p50: pct(values, 0.5), p95: pct(values, 0.95), max: Math.max(...values), n: values.length };
}

export function toBaseline(report: Report): Baseline {
  const turns: Record<string, Stat> = {};
  for (const metric of METRICS) {
    const values = report.turns.filter((row) => metric in row).map((row) => row[metric]);
    if (values.length > 0) turns[metric] = statOf(values);
  }
  const samples: Record<string, Record<string, number[]>> = {};
  for (const row of report.answers) {
    const byLabel = (samples[row.label] ??= {});
    for (const [key, value] of Object.entries(row.metrics)) (byLabel[key] ??= []).push(value);
  }
  const answers: Record<string, Record<string, Stat>> = {};
  for (const [label, byMetric] of Object.entries(samples)) {
    answers[label] = Object.fromEntries(
      Object.entries(byMetric).map(([key, values]) => [key, statOf(values)]),
    );
  }
  return { generated: new Date().toISOString(), turns, answers };
}

/** p95 comparison: current vs baseline per shared metric. */
export function checkBaseline(
  baseline: Baseline,
  report: Report,
  tolerance: number,
): { lines: string[]; regressions: string[] } {
  const current = toBaseline(report);
  const lines: string[] = [];
  const regressions: string[] = [];
  const compare = (scope: string, base: Record<string, Stat>, cur: Record<string, Stat>) => {
    for (const [metric, stat] of Object.entries(base)) {
      const now = cur[metric];
      if (!now) {
        lines.push(`MISSING  ${scope}${metric} (in baseline p95=${stat.p95}, not measured now)`);
        continue;
      }
      const budget = stat.p95 * (1 + tolerance);
      const ok = now.p95 <= budget;
      lines.push(
        `${ok ? "ok      " : "REGRESSED"} ${scope}${metric} p95 ${stat.p95} -> ${now.p95} (budget ${budget.toFixed(0)})`,
      );
      if (!ok) regressions.push(`${scope}${metric}`);
    }
  };
  compare("", baseline.turns, current.turns);
  for (const [label, base] of Object.entries(baseline.answers)) {
    compare(`${label}.`, base, current.answers[label] ?? {});
  }
  return { lines, regressions };
}

/** Fixture check (parity with the original script's --self-test). */
export function selfTest(): void {
  const fixture = [
    "idfon-auto: voice-agent: turn=1 asr_gap_ms=1300 listen_ms=2100 reply_ms=900 speak_ms=2500 total_ms=6800",
    "noise line that must be ignored",
    "idfon-auto: voice-agent: turn=2 asr_gap_ms=0 listen_ms=1800 reply_ms=700 speak_ms=2600 total_ms=5200",
    "idfon-auto: voice-agent: turn=3 asr_gap_ms=1250 listen_ms=1950 reply_ms=800 speak_ms=2400 total_ms=6400",
    "idfon-auto: voice-agent: answer label=call peers_ms=12 rotate_ms=40 asr_ms=310 greet_ms=1900 total_ms=2400",
    "idfon-auto: voice-agent: answer label=call peers_ms=20 rotate_ms=45 asr_ms=280 greet_ms=2100 total_ms=2600",
  ].join("\n");
  const report = parse(fixture);
  const out = format(report);
  for (const needle of ["asr_gap_ms", "1300", "p50", "p95", "greet_ms", "1900", "label"]) {
    if (!out.includes(needle)) throw new Error(`missing ${needle} in report:\n${out}`);
  }
  // p50 of reply_ms over [900, 700, 800] is 800; max total_ms is 6800.
  if (!out.includes(" 800") || !out.includes(" 6800")) throw new Error(`unexpected percentiles:\n${out}`);
  // Answer parsing: two rows, label carried, greet_ms merged across labels.
  if (report.answers.length !== 2) throw new Error(`expected 2 answer rows, got ${report.answers.length}`);
  if (report.answers[0].label !== "call" || report.answers[0].metrics.greet_ms !== 1900) {
    throw new Error(`answer row parsed wrong: ${JSON.stringify(report.answers[0])}`);
  }
  // Baseline round trip: same log passes at tolerance 0, one doubled greet p95
  // must trip the regression check.
  const base = toBaseline(parse(fixture));
  const clean = checkBaseline(base, parse(fixture), 0);
  if (clean.regressions.length > 0) throw new Error(`clean run flagged: ${clean.lines.join("\n")}`);
  const worse = checkBaseline(base, parse(fixture.replace("greet_ms=2100", "greet_ms=4200")), 0.2);
  if (!worse.regressions.includes("call.greet_ms")) {
    throw new Error(`regression not flagged: ${worse.lines.join("\n")}`);
  }
}
