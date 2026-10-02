//! Text-layer echo suppression (P5): drop STT finals that fuzzy-match what the
//! service is currently speaking, so residual echo neither barge-ins nor
//! becomes a user turn.
//!
//! Pending-approval keywords are **exempt** (N12): the caller's real "yes" must
//! never be mistaken for echo, even if it matches spoken text.

/// Fuzzy echo check over the text currently being spoken.
#[derive(Default)]
pub struct EchoSuppressor {
    spoken: String,
    approval_keywords: Vec<String>,
    /// Minimum token-overlap ratio to call a final an echo.
    threshold: f64,
}

impl EchoSuppressor {
    pub fn new() -> Self {
        Self {
            threshold: 0.7,
            ..Self::default()
        }
    }

    /// Set the text being spoken (empty clears).
    pub fn set_spoken(&mut self, text: &str) {
        self.spoken = text.to_string();
    }

    pub fn clear_spoken(&mut self) {
        self.spoken.clear();
    }

    /// Keywords that exempt a final from suppression while an approval is
    /// pending.
    pub fn set_pending_approval_keywords(&mut self, keywords: Vec<String>) {
        self.approval_keywords = keywords;
    }

    /// True when `final_text` looks like our own speech and should be dropped.
    pub fn is_echo(&self, final_text: &str) -> bool {
        if self
            .approval_keywords
            .iter()
            .any(|keyword| contains_word(final_text, keyword))
        {
            return false;
        }
        let spoken = normalize(&self.spoken);
        let heard = normalize(final_text);
        if spoken.is_empty() || heard.is_empty() {
            return false;
        }
        if heard.len() >= 4 && (spoken.contains(&heard) || heard.contains(&spoken)) {
            return true;
        }
        overlap_ratio(&spoken, &heard) >= self.threshold
    }
}

fn normalize(text: &str) -> String {
    text.to_lowercase()
        .split(|character: char| !character.is_alphanumeric())
        .filter(|token| !token.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn contains_word(text: &str, word: &str) -> bool {
    let word = normalize(word);
    !word.is_empty() && normalize(text).split(' ').any(|token| token == word)
}

/// Fraction of the shorter text's tokens present in the longer.
fn overlap_ratio(a: &str, b: &str) -> f64 {
    let (short, long) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    let short: Vec<&str> = short.split(' ').collect();
    let long: Vec<&str> = long.split(' ').collect();
    if short.is_empty() {
        return 0.0;
    }
    let shared = short.iter().filter(|token| long.contains(token)).count();
    shared as f64 / short.len() as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spoken_text_is_suppressed_but_unrelated_speech_is_not() {
        let mut suppressor = EchoSuppressor::new();
        suppressor.set_spoken("Two plus two is four.");
        assert!(suppressor.is_echo("two plus two is four"));
        assert!(suppressor.is_echo("Two plus two is four"));
        assert!(!suppressor.is_echo("What time is it?"));
        suppressor.clear_spoken();
        assert!(!suppressor.is_echo("two plus two is four"));
    }

    #[test]
    fn pending_approval_keywords_are_exempt() {
        let mut suppressor = EchoSuppressor::new();
        suppressor.set_spoken("Please confirm you approve the transfer.");
        suppressor.set_pending_approval_keywords(vec!["approve".into()]);
        // Matches the spoken text, but the caller's real approval must survive.
        assert!(!suppressor.is_echo("I approve"));
        // Without the pending approval, the same final is suppressed as echo.
        suppressor.set_pending_approval_keywords(Vec::new());
        assert!(suppressor.is_echo("I approve the transfer"));
    }
}
