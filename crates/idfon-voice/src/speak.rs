//! `speak` authorization (N9): a scoped `voice.speak` grant with rate and
//! length caps, enforced at the holder/voice component.
//!
//! The grant is issued by the **listening client** (the speaker's target); a
//! holder of other grants cannot inject speech. This module is the enforcement
//! point, provider- and transport-neutral.

use std::{
    collections::VecDeque,
    sync::Mutex,
    time::{Duration, Instant},
};

use idfon_protocol::Capability;

/// Why a `speak` request was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SpeakDenied {
    /// The caller did not present the scoped `voice.speak` grant.
    MissingGrant,
    TooLong {
        chars: usize,
        max: usize,
    },
    RateLimited {
        per_minute: u32,
    },
}

/// Caps applied to every `speak`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpeakPolicy {
    pub max_chars: usize,
    pub max_per_minute: u32,
}

impl Default for SpeakPolicy {
    fn default() -> Self {
        Self {
            // ponytail: generous defaults for a single spoken turn; tighten if
            // abuse appears.
            max_chars: 2000,
            max_per_minute: 30,
        }
    }
}

/// Stateful, per-target enforcement of [`SpeakPolicy`].
pub struct SpeakAuthorizer {
    policy: SpeakPolicy,
    recent: Mutex<VecDeque<Instant>>,
}

impl SpeakAuthorizer {
    pub fn new(policy: SpeakPolicy) -> Self {
        Self {
            policy,
            recent: Mutex::new(VecDeque::new()),
        }
    }

    pub fn policy(&self) -> SpeakPolicy {
        self.policy
    }

    pub fn authorize(&self, capabilities: &[Capability], text: &str) -> Result<(), SpeakDenied> {
        self.authorize_at(capabilities, text, Instant::now())
    }

    /// Clock-injected form for deterministic tests.
    pub fn authorize_at(
        &self,
        capabilities: &[Capability],
        text: &str,
        now: Instant,
    ) -> Result<(), SpeakDenied> {
        if !capabilities.contains(&Capability::VoiceSpeak) {
            return Err(SpeakDenied::MissingGrant);
        }
        let chars = text.chars().count();
        if chars > self.policy.max_chars {
            return Err(SpeakDenied::TooLong {
                chars,
                max: self.policy.max_chars,
            });
        }
        let mut recent = self.recent.lock().expect("speak authorizer poisoned");
        while recent
            .front()
            .is_some_and(|at| now.duration_since(*at) >= Duration::from_secs(60))
        {
            recent.pop_front();
        }
        if recent.len() as u32 >= self.policy.max_per_minute {
            return Err(SpeakDenied::RateLimited {
                per_minute: self.policy.max_per_minute,
            });
        }
        recent.push_back(now);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GRANTED: [Capability; 1] = [Capability::VoiceSpeak];

    #[test]
    fn speak_without_the_grant_is_denied() {
        let authorizer = SpeakAuthorizer::new(SpeakPolicy::default());
        assert_eq!(
            authorizer.authorize(&[], "hello"),
            Err(SpeakDenied::MissingGrant)
        );
        assert_eq!(
            authorizer.authorize(&[Capability::MessageSend], "hello"),
            Err(SpeakDenied::MissingGrant)
        );
        assert!(authorizer.authorize(&GRANTED, "hello").is_ok());
    }

    #[test]
    fn length_and_rate_caps_are_enforced() {
        let authorizer = SpeakAuthorizer::new(SpeakPolicy {
            max_chars: 5,
            max_per_minute: 2,
        });
        assert_eq!(
            authorizer.authorize(&GRANTED, "too long"),
            Err(SpeakDenied::TooLong { chars: 8, max: 5 })
        );

        let base = Instant::now();
        assert!(authorizer.authorize_at(&GRANTED, "one", base).is_ok());
        assert!(authorizer
            .authorize_at(&GRANTED, "two", base + Duration::from_secs(1))
            .is_ok());
        assert_eq!(
            authorizer.authorize_at(&GRANTED, "three", base + Duration::from_secs(2)),
            Err(SpeakDenied::RateLimited { per_minute: 2 })
        );
        // The window slides: after a minute the oldest drops out.
        assert!(authorizer
            .authorize_at(&GRANTED, "four", base + Duration::from_secs(61))
            .is_ok());
    }
}
