//! Voice model registry (F8): `speak(text, voice)` resolves a named voice to
//! an `(engine, model, voice-id)` plus its tier and license.
//!
//! Tiered deployment (`docs/voice-side-channel.md`, "Recommendation"):
//! a **bundled** default that works offline, and **downloadable** models
//! carrying size/hash/license metadata for a manifest fetch. Only the bundled
//! stub is actually present in P3; the downloadable rows are catalog entries.

/// Whether a model ships with the client or is fetched on demand.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelTier {
    Bundled,
    Downloadable,
}

/// One resolvable voice: a specific `(engine, model, voice-id)` with provenance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceModel {
    /// Provider id, matching [`crate::VoiceEngine::name`].
    pub engine: String,
    /// Model id within the provider.
    pub model: String,
    /// Voice id within the model.
    pub voice: String,
    pub tier: ModelTier,
    /// SPDX expression or `proprietary`.
    pub license: String,
    /// BCP-47-ish language tags the voice covers.
    pub languages: Vec<String>,
    /// Download size for a downloadable tier; zero for bundled.
    pub size_bytes: u64,
    /// Expected content hash for a downloadable model.
    pub sha256: Option<String>,
}

impl VoiceModel {
    /// Canonical `engine:model:voice` id.
    pub fn id(&self) -> String {
        format!("{}:{}:{}", self.engine, self.model, self.voice)
    }
}

/// Catalog of known voices. Immutable once built.
pub struct ModelRegistry {
    models: Vec<VoiceModel>,
}

impl ModelRegistry {
    pub fn new(models: Vec<VoiceModel>) -> Self {
        Self { models }
    }

    /// The built-in catalog: the offline stub plus representative downloadable
    /// engines from the candidate list. Licenses are recorded; re-check at
    /// adoption.
    pub fn bundled() -> Self {
        Self::new(vec![
            VoiceModel {
                engine: crate::stub::STUB.into(),
                model: "stub-silence".into(),
                voice: "default".into(),
                tier: ModelTier::Bundled,
                license: "MIT OR Apache-2.0".into(),
                languages: vec!["en".into()],
                size_bytes: 0,
                sha256: None,
            },
            VoiceModel {
                engine: "kokoro".into(),
                model: "kokoro-82m".into(),
                voice: "af_heart".into(),
                tier: ModelTier::Downloadable,
                license: "Apache-2.0".into(),
                languages: vec!["en".into(), "es".into(), "fr".into()],
                size_bytes: 326_000_000,
                sha256: None,
            },
            VoiceModel {
                engine: "kokoro".into(),
                model: "kokoro-7m-distill".into(),
                voice: "af_msa".into(),
                tier: ModelTier::Downloadable,
                license: "Apache-2.0".into(),
                languages: vec!["en".into()],
                size_bytes: 28_700_000,
                sha256: None,
            },
        ])
    }

    /// The offline default: the first bundled model. Always present.
    pub fn default_voice(&self) -> &VoiceModel {
        self.models
            .iter()
            .find(|model| model.tier == ModelTier::Bundled)
            .expect("registry must have a bundled default")
    }

    /// Resolve a request by canonical id, `model:voice`, bare voice id, or
    /// model name. Ambiguous bare ids resolve to the first catalog match.
    pub fn resolve(&self, requested: &str) -> Option<&VoiceModel> {
        let requested = requested.strip_prefix("voice:").unwrap_or(requested);
        self.models
            .iter()
            .find(|model| model.id() == requested)
            .or_else(|| {
                self.models
                    .iter()
                    .find(|model| format!("{}:{}", model.model, model.voice) == requested)
            })
            .or_else(|| self.models.iter().find(|model| model.voice == requested))
            .or_else(|| self.models.iter().find(|model| model.model == requested))
    }

    pub fn models(&self) -> &[VoiceModel] {
        &self.models
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_bundled_and_resolution_accepts_several_forms() {
        let registry = ModelRegistry::bundled();
        let default = registry.default_voice();
        assert_eq!(default.tier, ModelTier::Bundled);
        assert_eq!(default.engine, crate::stub::STUB);

        assert_eq!(registry.resolve("default").unwrap(), default);
        assert_eq!(registry.resolve(&default.id()).unwrap(), default);
        assert_eq!(
            registry
                .resolve("kokoro:kokoro-82m:af_heart")
                .unwrap()
                .engine,
            "kokoro"
        );
        assert_eq!(
            registry.resolve("af_msa").unwrap().model,
            "kokoro-7m-distill"
        );
        assert_eq!(registry.resolve("nope"), None);
    }

    #[test]
    fn downloadable_models_carry_license_and_size() {
        let registry = ModelRegistry::bundled();
        let downloadable: Vec<_> = registry
            .models()
            .iter()
            .filter(|model| model.tier == ModelTier::Downloadable)
            .collect();
        assert!(!downloadable.is_empty());
        for model in downloadable {
            assert!(!model.license.is_empty(), "{} missing license", model.id());
            assert!(model.size_bytes > 0, "{} missing size", model.id());
        }
    }
}
