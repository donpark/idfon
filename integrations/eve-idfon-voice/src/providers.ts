// TypeScript voice-provider seam.
//
// A voice agent's STT/TTS run here, in the agent's Node process — so
// open-source models that bundle (WASM/ONNX/npm: Kokoro, Whisper, Parakeet,
// …) are ordinary `import`s, with no Rust rebuild. Cloud and
// OpenAI-compatible local servers use the same seam.
//
// Config is the same shape as the Rust engine block, passed via the
// `IDFON_VOICE_ENGINE` env (JSON) or the channel's `voice` config:
//
//   { "stt": { "provider": "command", "stt_cmd": "whisper {input}" },
//     "tts": { "provider": "kokoro", "voice": "af_bella" } }
//
// A single `{ "provider": ... }` applies to both directions.

import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import { RATE, wavToPcm, wavWrap } from "./audio";
import { optionalImport } from "./optional";

const run = promisify(execFile);

export type ProviderConfig = Record<string, unknown>;

export interface VoiceProvider {
  readonly name: string;
  transcribe?(pcm: Buffer, rate: number): Promise<string>;
  synthesize?(text: string): Promise<Buffer>;
}

/** STT/TTS/wrap config from `IDFON_VOICE_ENGINE` (JSON). */
export function engineConfig(): {
  stt?: ProviderConfig;
  tts?: ProviderConfig;
  wrap?: ProviderConfig;
} {
  const raw = process.env.IDFON_VOICE_ENGINE;
  if (!raw) return {};
  let parsed: ProviderConfig;
  try {
    parsed = JSON.parse(raw) as ProviderConfig;
  } catch (error) {
    throw new Error(`IDFON_VOICE_ENGINE is not valid JSON: ${error}`);
  }
  const wrap = parsed.wrap as ProviderConfig | undefined;
  if (parsed.stt || parsed.tts) {
    return { stt: parsed.stt as ProviderConfig, tts: parsed.tts as ProviderConfig, wrap };
  }
  return { stt: parsed, tts: parsed, wrap };
}

export async function createVoiceProvider(
  config: ProviderConfig | undefined,
  kind: "stt" | "tts",
): Promise<VoiceProvider> {
  const cfg = config ?? {};
  const provider = String(cfg.provider ?? "command");
  switch (provider) {
    case "command":
    case "local":
      return commandProvider(cfg, kind);
    case "openai":
    case "openai-compatible":
      return openaiProvider(cfg, kind);
    case "kokoro":
      return kokoroProvider(cfg);
    case "module":
      return moduleProvider(cfg);
    // Open-source ASR packages expose their own JS/WASM APIs; wire them with
    // `"provider": "module", "module": "<pkg>", "factory": "<export>"`, whose
    // factory returns `{ transcribe }` (or point at a local server with
    // `openai-compatible`). Named here so the intent is discoverable.
    case "whisper":
    case "parakeet":
      if (!cfg.module) {
        throw new Error(
          `provider '${provider}' needs \`module\` (or use "command"/"openai-compatible")`,
        );
      }
      return moduleProvider(cfg);
    default:
      throw new Error(`unknown voice provider '${provider}'`);
  }
}

function apiKey(cfg: ProviderConfig, fallbackEnv = "AI_GATEWAY_API_KEY"): string {
  const name = String(cfg.api_key_env ?? fallbackEnv);
  const key = process.env[name] ?? "";
  if (!key && !cfg.allow_missing_key) {
    throw new Error(`${name} is required for the voice provider`);
  }
  return key;
}

/** `command`: shell out to a model CLI. */
async function commandProvider(cfg: ProviderConfig, kind: "stt" | "tts"): Promise<VoiceProvider> {
  const cmd = String((kind === "stt" ? cfg.stt_cmd : cfg.tts_cmd) ?? cfg.cmd ?? "");
  if (!cmd) throw new Error(`command provider needs \`${kind}_cmd\``);
  const shell = async (expanded: string): Promise<{ stdout: string }> => {
    const { stdout } = await run("/bin/sh", ["-c", expanded]);
    return { stdout };
  };

  if (kind === "stt") {
    return {
      name: "command",
      async transcribe(pcm: Buffer) {
        const dir = await mkdtemp(join(tmpdir(), "idfon-stt-"));
        const input = join(dir, "in.wav");
        const output = join(dir, "out.txt");
        try {
          await writeFile(input, wavWrap(pcm));
          const { stdout } = await shell(
            cmd.replaceAll("{input}", input).replaceAll("{output}", output),
          );
          const file = await readFile(output, "utf8").catch(() => "");
          return (file.trim() || stdout.trim());
        } finally {
          await rm(dir, { recursive: true, force: true });
        }
      },
    };
  }
  return {
    name: "command",
    async synthesize(text: string) {
      const dir = await mkdtemp(join(tmpdir(), "idfon-tts-"));
      const input = join(dir, "in.txt");
      const output = join(dir, "out.wav");
      try {
        await writeFile(input, text);
        await shell(cmd.replaceAll("{text}", input).replaceAll("{output}", output));
        return wavToPcm(await readFile(output));
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    },
  };
}

/** OpenAI audio API — cloud or an OpenAI-compatible local server (Kokoro, …). */
async function openaiProvider(cfg: ProviderConfig, kind: "stt" | "tts"): Promise<VoiceProvider> {
  const base = String(cfg.base_url ?? "https://ai-gateway.vercel.sh/v1").replace(/\/$/, "");
  const authHeaders = (): Record<string, string> => {
    const key = apiKey(cfg);
    return key ? { authorization: `Bearer ${key}` } : {};
  };

  if (kind === "stt") {
    return {
      name: "openai-compatible",
      async transcribe(pcm: Buffer) {
        const form = new FormData();
        form.append("file", new Blob([new Uint8Array(wavWrap(pcm))], { type: "audio/wav" }), "audio.wav");
        form.append("model", String(cfg.stt_model ?? "openai/whisper-1"));
        const response = await fetch(`${base}/audio/transcriptions`, {
          method: "POST",
          headers: authHeaders(),
          body: form,
        });
        if (!response.ok) throw new Error(`transcription HTTP ${response.status}: ${await response.text()}`);
        const body = (await response.json()) as { text?: string };
        return body.text ?? "";
      },
    };
  }
  return {
    name: "openai-compatible",
    async synthesize(text: string) {
      const response = await fetch(`${base}/audio/speech`, {
        method: "POST",
        headers: { "content-type": "application/json", ...authHeaders() },
        body: JSON.stringify({
          model: String(cfg.tts_model ?? "openai/tts-1"),
          input: text,
          voice: String(cfg.voice ?? "alloy"),
          response_format: String(cfg.response_format ?? "pcm"),
        }),
      });
      if (!response.ok) throw new Error(`speech HTTP ${response.status}: ${await response.text()}`);
      return Buffer.from(await response.arrayBuffer());
    },
  };
}

/** `module`: import a package that exports a provider factory. */
async function moduleProvider(cfg: ProviderConfig): Promise<VoiceProvider> {
  const name = String(cfg.module ?? "");
  if (!name) throw new Error("module provider needs `module`");
  const mod = await optionalImport(name);
  const factory = (mod[String(cfg.factory ?? "createVoiceProvider")] ?? mod.default) as
    | ((config: ProviderConfig) => Promise<VoiceProvider> | VoiceProvider)
    | undefined;
  if (typeof factory !== "function") {
    throw new Error(`module '${name}' has no factory export`);
  }
  return await factory(cfg);
}

/** Kokoro TTS via the `kokoro-js` package (bundlable ONNX). */
async function kokoroProvider(cfg: ProviderConfig): Promise<VoiceProvider> {
  const pkg = String(cfg.module ?? "kokoro-js");
  const { KokoroTTS } = (await optionalImport(pkg)) as unknown as {
    KokoroTTS: {
      from_pretrained(model: string, options?: Record<string, unknown>): Promise<{
        generate(text: string, options?: Record<string, unknown>): Promise<{ toWav(): ArrayBuffer }>;
      }>;
    };
  };
  const tts = await KokoroTTS.from_pretrained(
    String(cfg.model ?? "onnx-community/Kokoro-82M-v1.0-ONNX"),
    { dtype: String(cfg.dtype ?? "q8"), device: String(cfg.device ?? "wasm") },
  );
  const voice = String(cfg.voice ?? "af_bella");
  return {
    name: "kokoro",
    async synthesize(text: string) {
      const audio = await tts.generate(text, { voice });
      return wavToPcm(Buffer.from(audio.toWav()));
    },
  };
}

