//! Relay selection: parameter > configuration > default (docs/relay-config.md).
//!
//! Relay selection is never compiled into a binary. Every endpoint bind
//! resolves it at runtime, **per field**, from the highest source that sets it:
//!
//! 1. **parameter** — per-run input: `idfond --relay-…` flags, the apps'
//!    launch args (`-relayurls …`), or [`set_parameter_override`] (the FFI);
//!    `IDFON_RELAY_*` environment variables sit at the bottom of this tier
//!    (headless processes and scripts).
//! 2. **configuration** — the persisted setting: `~/.idfon/relay.conf`.
//!    The apps hold their persisted setting in their own store and pass it
//!    down as a parameter.
//! 3. **default** — the N0 public relays (the `iroh` preset).
//!
//! A relay-only peer (no IP transports) is for enterprise NAT / tests; it is
//! orthogonal to the map and merges sticky-true across sources.

use std::{path::PathBuf, sync::RwLock};

use iroh::{
    endpoint::{presets, Builder},
    Endpoint, RelayMap, RelayMode,
};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RelayConfig {
    /// Comma-separated `https://…` relay URLs. `None` when the source does
    /// not set it (an empty string also counts as unset).
    pub urls: Option<String>,
    /// Shared bearer token (`shared_token` relays only). `None` = unset.
    pub token: Option<String>,
    /// Drop IP transports: relay-only.
    pub only: bool,
}

impl RelayConfig {
    /// True when this config contributes nothing.
    pub fn is_unset(&self) -> bool {
        self.urls.is_none() && self.token.is_none() && !self.only
    }

    /// Per-field merge: `over` wins where it sets a field; `only` is sticky.
    fn merged(mut self, over: RelayConfig) -> RelayConfig {
        self.urls = over.urls.or(self.urls);
        self.token = over.token.or(self.token);
        self.only |= over.only;
        self
    }

    fn from_env() -> Option<RelayConfig> {
        let urls = non_empty(std::env::var("IDFON_RELAY_URLS").ok());
        let token = non_empty(std::env::var("IDFON_RELAY_TOKEN").ok());
        let only = env_truthy("IDFON_RELAY_ONLY");
        (urls.is_some() || token.is_some() || only).then_some(RelayConfig { urls, token, only })
    }

    fn from_file() -> Option<RelayConfig> {
        std::fs::read_to_string(config_path()).ok().and_then(|text| parse_config(&text))
    }

    /// The effective relay map: `Some(Custom)` when URLs are configured,
    /// `None` for the default N0 map. An unparseable URL list falls back to
    /// the default (the same behavior the env knob always had).
    fn relay_mode(&self) -> Option<RelayMode> {
        let urls = self.urls.as_deref()?;
        relay_mode_from(urls, self.token.as_deref())
    }
}

/// Per-run parameter override. Empty/`None` fields stay unset and are filled
/// from lower tiers; [`RelayConfig::default`] clears the override entirely.
pub fn set_parameter_override(config: RelayConfig) {
    let mut slot = PARAMETER.write().expect("relay parameter poisoned");
    *slot = (!config.is_unset()).then_some(config);
}

static PARAMETER: RwLock<Option<RelayConfig>> = RwLock::new(None);

/// The effective relay config: parameter > env > `~/.idfon/relay.conf` > default.
pub fn resolve() -> RelayConfig {
    resolve_from(
        PARAMETER.read().expect("relay parameter poisoned").clone(),
        RelayConfig::from_env(),
        RelayConfig::from_file(),
    )
}

fn resolve_from(
    parameter: Option<RelayConfig>,
    env: Option<RelayConfig>,
    file: Option<RelayConfig>,
) -> RelayConfig {
    let mut config = RelayConfig::default();
    for source in [file, env, parameter].into_iter().flatten() {
        config = config.merged(source);
    }
    config
}

/// The endpoint builder every bind site uses: N0 preset + resolved selection.
pub fn endpoint_builder() -> Builder {
    apply(Endpoint::builder(presets::N0), &resolve())
}

/// Applies a resolved config to a builder: custom relay map when URLs are
/// configured, no IP transports when relay-only.
pub fn apply(builder: Builder, config: &RelayConfig) -> Builder {
    let mut builder = match config.relay_mode() {
        Some(mode) => builder.relay_mode(mode),
        None => builder,
    };
    if config.only {
        builder = builder.clear_ip_transports();
    }
    builder
}

/// The persisted configuration file: `~/.idfon/relay.conf`.
pub fn config_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".idfon").join("relay.conf")
}

/// Parses `key=value` lines (`urls`, `token`, `only`; `#` comments). `None`
/// when the text sets nothing, so an empty file falls through to lower tiers.
fn parse_config(text: &str) -> Option<RelayConfig> {
    let mut config = RelayConfig::default();
    let mut any = false;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        match key.trim() {
            "urls" if !value.is_empty() => {
                config.urls = Some(value.to_string());
                any = true;
            }
            "token" if !value.is_empty() => {
                config.token = Some(value.to_string());
                any = true;
            }
            "only" => {
                config.only = is_truthy(value);
                any = true;
            }
            _ => {}
        }
    }
    any.then_some(config)
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.trim().is_empty())
}

fn env_truthy(name: &str) -> bool {
    is_truthy(&std::env::var(name).unwrap_or_default())
}

fn is_truthy(value: &str) -> bool {
    matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes")
}

fn relay_mode_from(urls: &str, token: Option<&str>) -> Option<RelayMode> {
    let list: Vec<&str> = urls
        .split(',')
        .map(str::trim)
        .filter(|url| !url.is_empty())
        .collect();
    if list.is_empty() {
        return None;
    }
    let map = RelayMap::try_from_iter(list).ok()?;
    let map = match token {
        Some(token) if !token.is_empty() => map.with_auth_token(token),
        _ => map,
    };
    Some(RelayMode::Custom(map))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_truthy_accepts_common_flags() {
        assert!(is_truthy("1") && is_truthy("true") && is_truthy(" YES "));
        assert!(!is_truthy("0") && !is_truthy("") && !is_truthy("no"));
    }

    #[test]
    fn relay_mode_from_parses_urls_and_token() {
        assert!(relay_mode_from("", None).is_none());
        assert!(relay_mode_from("  ,  ", None).is_none());
        let mode = relay_mode_from(
            "https://relay.example.com, https://relay2.example.com:8443",
            Some("tok"),
        )
        .expect("two relays");
        match mode {
            RelayMode::Custom(map) => assert_eq!(map.len(), 2),
            _ => panic!("expected RelayMode::Custom"),
        }
    }

    #[test]
    fn precedence_is_parameter_over_env_over_file_per_field() {
        let file = Some(RelayConfig {
            urls: Some("https://file.example".into()),
            token: Some("file-tok".into()),
            only: false,
        });
        let env = Some(RelayConfig {
            urls: None,
            token: Some("env-tok".into()),
            only: true,
        });
        let parameter = Some(RelayConfig {
            urls: Some("https://param.example".into()),
            token: None,
            only: false,
        });
        let config = resolve_from(parameter, env, file);
        assert_eq!(config.urls.as_deref(), Some("https://param.example"));
        assert_eq!(config.token.as_deref(), Some("env-tok"));
        assert!(config.only);
    }

    #[test]
    fn unset_sources_fall_through_to_the_default() {
        let config = resolve_from(None, None, None);
        assert!(config.is_unset());
        assert!(config.relay_mode().is_none());
    }

    #[test]
    fn parse_config_reads_the_three_keys() {
        let config = parse_config(
            "# comment\n\nurls=https://relay.example:8443, https://b.example\ntoken=a=b c\nonly=1\n",
        )
        .expect("configured");
        assert_eq!(config.urls.as_deref(), Some("https://relay.example:8443, https://b.example"));
        assert_eq!(config.token.as_deref(), Some("a=b c"));
        assert!(config.only);
        assert!(parse_config("# nothing\n").is_none());
    }
}
