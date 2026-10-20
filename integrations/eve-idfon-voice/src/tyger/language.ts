// The language knob (`IDFON_VOICE_LANG`, BCP-47): one tag -> the per-half
// settings. The ASR prompt ids are the tyger bundle's processor
// `prompt_dictionary` (Nemotron streaming ASR is ~100 languages — the full map
// is in the bundle's nemotron/processor_config.json; these are the common
// ones). The reply language is guidance for the agent; TTS voice choice stays
// with the provider config.
//
// When the bundle's RNN-T ASR joins the chain, its prompt id comes from here;
// until then the tag drives the STT provider's `language` parameter.

export const ASR_PROMPT_IDS: Record<string, number> = {
  en: 0, "en-US": 0, "en-GB": 1,
  "zh-CN": 4, "zh-TW": 5,
  es: 3, "es-ES": 2, "es-US": 3,
  fr: 8, "fr-FR": 8, "fr-CA": 100,
  "de-DE": 9, de: 9,
  "ja-JP": 10, ja: 10,
  ru: 11, "ru-RU": 11,
  "pt-BR": 12, pt: 13, "pt-PT": 13,
  "ko-KR": 14, ko: 14,
  it: 15, "it-IT": 15,
  nl: 16, "nl-NL": 16,
  sv: 24, "sv-SE": 24,
};

export interface LanguagePlan {
  tag: string;
  asrPromptId: number; // the Nemotron prompt id (0 = en)
  replyLanguage: string; // guidance text for the agent's reply
}

/// Resolve `IDFON_VOICE_LANG` (or an explicit tag). Unknown tags fall back to
/// English rather than guessing.
export function resolveLanguage(tag?: string): LanguagePlan {
  const raw = (tag ?? process.env.IDFON_VOICE_LANG ?? "en").trim();
  const direct = ASR_PROMPT_IDS[raw];
  const base = ASR_PROMPT_IDS[raw.split("-")[0]];
  const asrPromptId = direct ?? base ?? 0;
  return {
    tag: raw,
    asrPromptId,
    replyLanguage: raw,
  };
}
