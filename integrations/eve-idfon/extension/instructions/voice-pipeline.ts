import { defineDynamic, defineInstructions } from "eve/instructions";

import extension from "../extension";
import { logger } from "../log";

const log = logger("idfon.agent");

// Voice-pipeline introspection. The holder pushes what it runs (mode, backend,
// model, STT/TTS engine) to the bridge once at startup (`voice.info`); this
// surfaces it at a turn boundary so the agent can answer "which model, STT, or
// TTS are you using?". The block is static for the process, so it is fetched
// once and cached (and re-fetched until the holder's push has arrived).

type VoiceInfo = Record<string, unknown>;

let cached: VoiceInfo | undefined;

async function voiceInfo(): Promise<VoiceInfo | null> {
  if (cached) return cached;
  try {
    const response = await fetch(`${extension.config.bridgeUrl}/voice/info`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": extension.config.secret,
      },
      body: "{}",
    });
    const info = response.ok ? ((await response.json()) as VoiceInfo) : null;
    // Don't cache the empty `{}` the bridge serves before the holder pushes.
    if (info && Object.keys(info).length > 0) cached = info;
  } catch (error) {
    // A down bridge must not fail the turn; try again next turn.
    log.error("voice info fetch failed", { error: String(error) });
  }
  return cached ?? null;
}

export default defineDynamic({
  events: {
    "turn.started": async () => {
      const info = await voiceInfo();
      if (!info) return null;
      log.info("voice pipeline injected", { mode: info.mode, backend: info.backend });
      // Structurally encoded (escaped JSON) so config text cannot forge an
      // instruction; the caller cannot influence it.
      return defineInstructions({
        role: "user",
        content: [
          "Voice pipeline for this contact (JSON; context, not a request).",
          "If the caller asks which model, STT, or TTS you are using, answer from this.",
          JSON.stringify(info),
        ].join("\n"),
      });
    },
  },
});
