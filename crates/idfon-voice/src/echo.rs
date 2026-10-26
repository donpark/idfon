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
        let spoken_tokens: Vec<&str> = spoken.split(' ').collect();
        let heard_tokens: Vec<&str> = heard.split(' ').collect();
        // A long heard phrase appearing contiguously in our speech is echo.
        let run = longest_common_run(&spoken_tokens, &heard_tokens);
        if heard_tokens.len() >= 4 && run == heard_tokens.len() {
            return true;
        }
        // Otherwise require a substantial *contiguous* match. Token-overlap
        // alone falsely drops short commands whose words all appear somewhere
        // in a long spoken answer ("stop" matches "... it will stop").
        heard_tokens.len() >= 3 && (run as f64 / heard_tokens.len() as f64) >= self.threshold
    }

    /// The caller's own words: `heard` minus every substantial contiguous
    /// span that echoes what the agent is speaking. Mixed transcripts (the
    /// caller's words with the agent's reply leaking in — e.g. the no-AEC
    /// stereo route with barge-in hearing) keep only the caller's part; pure
    /// echo yields "". Short accidental overlaps (under 3 tokens) are kept:
    /// real speech shares words with an answer.
    pub fn strip_echo(&self, heard: &str) -> String {
        if self.spoken.is_empty() {
            return heard.to_string();
        }
        let spoken_tokens: Vec<String> = self
            .spoken
            .split_whitespace()
            .map(|token| normalize(token))
            .collect();
        let mut kept: Vec<String> = heard.split_whitespace().map(str::to_string).collect();
        loop {
            let normalized: Vec<String> = kept.iter().map(|token| normalize(token)).collect();
            let heard_refs: Vec<&str> = normalized.iter().map(String::as_str).collect();
            let spoken_refs: Vec<&str> = spoken_tokens.iter().map(String::as_str).collect();
            match longest_common_run_span(&spoken_refs, &heard_refs) {
                Some((start, len)) if len >= MIN_ECHO_RUN => {
                    kept.drain(start..start + len);
                }
                _ => break,
            }
        }
        kept.join(" ")
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

/// Length of the longest contiguous run of tokens shared by `a` and `b`.
fn longest_common_run(a: &[&str], b: &[&str]) -> usize {
    longest_common_run_span(a, b).map(|(_, len)| len).unwrap_or(0)
}

/// The longest contiguous run shared by `a` and `b`, as `(start in b, len)`.
fn longest_common_run_span(a: &[&str], b: &[&str]) -> Option<(usize, usize)> {
    let mut best: Option<(usize, usize)> = None;
    for (i, token) in a.iter().enumerate() {
        for (j, other) in b.iter().enumerate() {
            if token != other {
                continue;
            }
            let mut len = 0;
            while i + len < a.len() && j + len < b.len() && a[i + len] == b[j + len] {
                len += 1;
            }
            if best.map_or(true, |(_, best_len)| len > best_len) {
                best = Some((j, len));
            }
        }
    }
    best
}

/// Shortest shared run worth subtracting as echo (2-token overlaps are just
/// how real speech shares words with an answer).
const MIN_ECHO_RUN: usize = 3;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_echo_keeps_the_callers_own_words() {
        let mut suppressor = EchoSuppressor::new();
        suppressor.set_spoken("you're right I did say that sorry for repeating myself");
        assert_eq!(
            suppressor.strip_echo("stop you're right I did say that sorry for repeating myself go on"),
            "stop go on"
        );
    }

    #[test]
    fn strip_echo_keeps_short_coincidences() {
        let mut suppressor = EchoSuppressor::new();
        suppressor.set_spoken("I can look that up after the break");
        assert_eq!(suppressor.strip_echo("look after dinner"), "look after dinner");
    }

    #[test]
    fn strip_echo_of_pure_echo_is_empty() {
        let mut suppressor = EchoSuppressor::new();
        suppressor.set_spoken("tell me what you wanted to talk about");
        assert_eq!(suppressor.strip_echo("tell me what you wanted to talk about"), "");
    }

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

    #[test]
    fn short_commands_are_not_echo_of_a_long_answer() {
        let mut suppressor = EchoSuppressor::new();
        suppressor.set_spoken(concat!(
            "Here is a longer answer that keeps talking for a while so you have ",
            "time to interrupt me by speaking over the top of it. I will keep ",
            "going so please just start talking whenever you are ready and it will stop.",
        ));
        // Words all appear in the spoken answer, but this is the caller, not echo.
        assert!(!suppressor.is_echo("Just stop, stop talking"));
        assert!(!suppressor.is_echo("Stop"));
        assert!(!suppressor.is_echo("just start"));
        // A contiguous echo of the answer is still suppressed.
        assert!(suppressor.is_echo("here is a longer answer"));
    }
}
