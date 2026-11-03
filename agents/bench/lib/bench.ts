// CLI entry for the bench vertical (pure TS — runs on Node 24+ with type
// stripping, no build step). Wrappers: scripts/relay-bench.sh,
// scripts/voice-latency-report.sh. The same lib modules power the bench
// Eve agent's tools (agents/bench/agent/tools/).
//
//   node agents/bench/lib/bench.ts matrix [--quick] [--count N] [--blob-bytes N]
//                                      [--relay URL] [--out FILE]
//   node agents/bench/lib/bench.ts rtt --to PEER [--socket S] [--count N]
//   node agents/bench/lib/bench.ts greet [--count N] [--out FILE]
//   node agents/bench/lib/bench.ts report [--self-test] [--baseline FILE]
//           [--write-baseline FILE] [--tolerance 0.25] [LOG...]
//       (LOG... omitted or `-` reads stdin)
import { readFileSync, writeFileSync } from "node:fs";
import { appendHistory, formatMatrix, runMatrix, runRtt } from "./matrix.ts";
import { appendGreetHistory, formatGreet, runGreet } from "./greet.ts";
import { checkBaseline, format, parse, selfTest, toBaseline, type Baseline } from "./report.ts";

function argValue(args: string[], flag: string): string | undefined {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
}

/** Positional args = everything that is not a flag or a flag's value. */
function positionals(args: string[], valueFlags: string[]): string[] {
  return args.filter((a, i) => !a.startsWith("--") && !valueFlags.includes(args[i - 1] ?? ""));
}

async function main(): Promise<void> {
  const [command = "matrix", ...args] = process.argv.slice(2);
  switch (command) {
    case "matrix": {
      const quick = args.includes("--quick");
      const rows = await runMatrix({
        relayUrl: argValue(args, "--relay"),
        count: Number(argValue(args, "--count") ?? (quick ? 3 : 10)),
        blobBytes: Number(argValue(args, "--blob-bytes") ?? (quick ? 256 * 1024 : 1024 * 1024)),
      });
      console.log(formatMatrix(rows));
      const path = appendHistory(rows, argValue(args, "--out"));
      console.log(`\nresults appended to ${path}`);
      break;
    }
    case "rtt": {
      const peer = argValue(args, "--to");
      if (!peer) throw new Error("rtt needs --to PEER");
      const rows = await runRtt({
        socket: argValue(args, "--socket"),
        peer,
        count: Number(argValue(args, "--count") ?? 10),
      });
      console.log(formatMatrix(rows));
      break;
    }
    case "greet": {
      const result = await runGreet(Number(argValue(args, "--count") ?? 10));
      console.log(formatGreet(result));
      const path = appendGreetHistory(result, argValue(args, "--out"));
      console.log(`\nresults appended to ${path}`);
      break;
    }
    case "report": {
      if (args.includes("--self-test")) {
        selfTest();
        console.log("PASS: voice-latency-report self-test");
        break;
      }
      const files = positionals(args, ["--baseline", "--write-baseline", "--tolerance"]).filter((a) => a !== "-");
      const text = files.length > 0
        ? files.map((file) => readFileSync(file, "utf8")).join("\n")
        : readFileSync(0, "utf8");
      const output = format(parse(text));
      console.log(output);
      if (output.startsWith("no voice-agent turn markers")) process.exit(1);
      const baselinePath = argValue(args, "--baseline");
      const writePath = argValue(args, "--write-baseline");
      const tolerance = Number(argValue(args, "--tolerance") ?? 0.25);
      if (writePath) {
        writeFileSync(writePath, JSON.stringify(toBaseline(parse(text)), null, 2) + "\n");
        console.log(`\nbaseline written to ${writePath}`);
      }
      if (baselinePath) {
        const baseline = JSON.parse(readFileSync(baselinePath, "utf8")) as Baseline;
        const { lines, regressions } = checkBaseline(baseline, parse(text), tolerance);
        console.log(`\nbaseline check vs ${baselinePath} (tolerance ${(tolerance * 100).toFixed(0)}% on p95):`);
        console.log(lines.join("\n"));
        if (regressions.length > 0) {
          console.error(`REGRESSED: ${regressions.join(", ")}`);
          process.exit(1);
        }
      }
      break;
    }
    default:
      throw new Error(`unknown subcommand: ${command}`);
  }
}

main().catch((error) => {
  console.error(`bench: ${error instanceof Error ? error.message : error}`);
  process.exit(2);
});
