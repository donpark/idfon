//! Native English G2P front end (P6): turn written numbers into spoken words
//! before TTS.
//!
//! Kokoro's reference front end is Python `KPipeline` + `num2words` (LGPL);
//! the design calls for a **native G2P port** so the bundled default voice has
//! no LGPL dependency (`docs/voice-side-channel.md`, "Recommendation", P6).
//! This is the deterministic number-normalization slice: cardinals and
//! decimals, no ML, no network. Other languages still need `espeak-ng` and are
//! out of scope here.

/// Normalize a written English string for speech: numeric tokens become words.
pub fn normalize_for_speech(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < chars.len() {
        let character = chars[index];
        let at_word_start = index == 0 || !chars[index - 1].is_alphanumeric();
        let signed = character == '-'
            && at_word_start
            && chars
                .get(index + 1)
                .is_some_and(|next| next.is_ascii_digit());
        if character.is_ascii_digit() || signed {
            let mut token = String::new();
            if signed {
                token.push('-');
                index += 1;
            } else {
                token.push(character);
                index += 1;
            }
            while index < chars.len() && chars[index].is_ascii_digit() {
                token.push(chars[index]);
                index += 1;
            }
            // A decimal point only belongs to the number when a digit follows;
            // otherwise it is sentence punctuation.
            if index + 1 < chars.len() && chars[index] == '.' && chars[index + 1].is_ascii_digit() {
                token.push('.');
                index += 1;
                while index < chars.len() && chars[index].is_ascii_digit() {
                    token.push(chars[index]);
                    index += 1;
                }
            }
            match number_token_to_words(&token) {
                Some(words) => out.push_str(&words),
                None => out.push_str(&token),
            }
        } else {
            out.push(character);
            index += 1;
        }
    }
    out
}

/// Convert a numeric token (`-12`, `42`, `3.14`) to spoken words.
pub fn number_token_to_words(token: &str) -> Option<String> {
    let (negative, rest) = match token.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, token),
    };
    let (integer, fraction) = match rest.split_once('.') {
        Some((integer, fraction)) => (integer, Some(fraction)),
        None => (rest, None),
    };
    if integer.is_empty() || !integer.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let mut words = cardinal_to_words(integer)?;
    if negative {
        words = format!("minus {words}");
    }
    if let Some(fraction) = fraction {
        let digits: Vec<String> = fraction
            .chars()
            .filter_map(digit_word)
            .map(str::to_string)
            .collect();
        if digits.is_empty() {
            return None;
        }
        words = format!("{words} point {}", digits.join(" "));
    }
    Some(words)
}

fn digit_word(digit: char) -> Option<&'static str> {
    Some(match digit {
        '0' => "zero",
        '1' => "one",
        '2' => "two",
        '3' => "three",
        '4' => "four",
        '5' => "five",
        '6' => "six",
        '7' => "seven",
        '8' => "eight",
        '9' => "nine",
        _ => return None,
    })
}

const ONES: &[&str] = &[
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen",
];
const TENS: &[&str] = &[
    "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
];
const SCALES: &[(u64, &str)] = &[
    (1_000_000_000_000, "trillion"),
    (1_000_000_000, "billion"),
    (1_000_000, "million"),
    (1_000, "thousand"),
];

fn cardinal_to_words(digits: &str) -> Option<String> {
    let value: u64 = digits.parse().ok()?;
    Some(cardinal(value))
}

fn cardinal(value: u64) -> String {
    if value < 20 {
        return ONES[value as usize].to_string();
    }
    if value < 100 {
        let tens = TENS[(value / 10) as usize];
        return match value % 10 {
            0 => tens.to_string(),
            ones => format!("{tens}-{}", ONES[ones as usize]),
        };
    }
    if value < 1_000 {
        let hundreds = format!("{} hundred", ONES[(value / 100) as usize]);
        return match value % 100 {
            0 => hundreds,
            rest => format!("{hundreds} {}", cardinal(rest)),
        };
    }
    for (scale, name) in SCALES {
        if value >= *scale {
            let head = format!("{} {}", cardinal(value / scale), name);
            return match value % scale {
                0 => head,
                rest => format!("{head} {}", cardinal(rest)),
            };
        }
    }
    value.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cardinals_and_decimals_are_spoken() {
        assert_eq!(number_token_to_words("0").as_deref(), Some("zero"));
        assert_eq!(number_token_to_words("13").as_deref(), Some("thirteen"));
        assert_eq!(number_token_to_words("42").as_deref(), Some("forty-two"));
        assert_eq!(number_token_to_words("100").as_deref(), Some("one hundred"));
        assert_eq!(
            number_token_to_words("1234").as_deref(),
            Some("one thousand two hundred thirty-four")
        );
        assert_eq!(
            number_token_to_words("3.14").as_deref(),
            Some("three point one four")
        );
        assert_eq!(number_token_to_words("-7").as_deref(), Some("minus seven"));
        assert_eq!(number_token_to_words("abc"), None);
    }

    #[test]
    fn numbers_embedded_in_text_are_normalized() {
        assert_eq!(
            normalize_for_speech("Two plus 2 is 4."),
            "Two plus two is four."
        );
        assert_eq!(
            normalize_for_speech("Order 12, ship 3.5 kg."),
            "Order twelve, ship three point five kg."
        );
        // A hyphen inside a word is not a negative sign.
        assert_eq!(normalize_for_speech("state-of-the-art"), "state-of-the-art");
    }
}
