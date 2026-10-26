//! Voice C ABI for the native shells.
//!
//! - **Filters (all Apple platforms)**: `idfon_voice_is_cancellable` and
//!   `idfon_voice_is_echo` reuse the Rust P5 barge-in/echo rules so the shells
//!   do not reimplement them.
//! - **Apple engine bridge (iOS)**: the app registers its Swift engine with
//!   `idfon_voice_set_bindings`; `idfon_voice_apple_selftest` runs a full
//!   TTS -> PCM -> STT round trip through the Rust seam and returns the
//!   transcript (or `error:...`). Free the result with `rust_free_string`.

use std::ffi::{c_char, c_void, CStr, CString};

// ---- turn rules (idfon_voice::turns) — the voice loop's decision seam ----
//
// One conversation's rules session is an opaque handle. JSON results are freed
// with `rust_free_string`, turn audio with `idfon_voice_turn_free_audio`. `mode`
// is "listen" or "speaking" (NULL = "listen"); audio is 16 kHz mono f32.

use idfon_voice::turns::{Thresholds, TurnSession};

fn mode_str(mode: *const c_char) -> String {
    if mode.is_null() {
        return "listen".into();
    }
    unsafe { CStr::from_ptr(mode) }.to_string_lossy().into_owned()
}

/// New session; `thresholds_json` overrides EarsSession defaults (NULL/empty =
/// defaults, invalid = NULL handle). Free with `idfon_voice_turn_free`.
#[no_mangle]
pub extern "C" fn idfon_voice_turn_new(thresholds_json: *const c_char) -> *mut c_void {
    let mut th = Thresholds::default();
    if !thresholds_json.is_null() {
        let s = unsafe { CStr::from_ptr(thresholds_json) }.to_string_lossy();
        if !s.trim().is_empty() {
            match serde_json::from_str(&s) {
                Ok(t) => th = t,
                Err(_) => return std::ptr::null_mut(),
            }
        }
    }
    Box::into_raw(Box::new(TurnSession::new(th))) as *mut c_void
}

#[no_mangle]
pub extern "C" fn idfon_voice_turn_free(sess: *mut c_void) {
    if !sess.is_null() {
        drop(unsafe { Box::from_raw(sess as *mut TurnSession) });
    }
}

/// Ask for the heads' context to start over before the next hop (rules.reset).
#[no_mangle]
pub extern "C" fn idfon_voice_turn_reset(sess: *mut c_void) {
    if let Some(s) = unsafe { (sess as *mut TurnSession).as_mut() } {
        s.reset();
    }
}

/// The state the step consumes for the next frame (0=LISTEN, 1=HOLD, 2=SPEAK,
/// 3=BACKCHANNEL).
#[no_mangle]
pub extern "C" fn idfon_voice_turn_prev_state(sess: *const c_void) -> i32 {
    unsafe { (sess as *const TurnSession).as_ref() }
        .map(|s| s.prev_state)
        .unwrap_or(0)
}

/// Before a hop's frames: pending reset, window sliding, turn audio
/// (rules.begin_hop). Returns 1 when the heads' context must start over.
#[no_mangle]
pub extern "C" fn idfon_voice_turn_begin_hop(
    sess: *mut c_void,
    user: *const f32,
    agent: *const f32,
    samples: usize,
    mode: *const c_char,
) -> u8 {
    let Some(s) = (unsafe { (sess as *mut TurnSession).as_mut() }) else {
        return 0;
    };
    let user = if user.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(user, samples) }
    };
    let agent = if agent.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(agent, samples) }
    };
    u8::from(s.begin_hop(user, agent, &mode_str(mode)))
}

/// A change between listening and speaking; returns 1 when it took effect.
#[no_mangle]
pub extern "C" fn idfon_voice_turn_switch_mode(sess: *mut c_void, mode: *const c_char) -> u8 {
    let Some(s) = (unsafe { (sess as *mut TurnSession).as_mut() }) else {
        return 0;
    };
    u8::from(s.switch_mode(&mode_str(mode)))
}

/// The user's words so far, from the ASR thread (feeds PARTIAL events).
#[no_mangle]
pub extern "C" fn idfon_voice_turn_set_words(sess: *mut c_void, words: *const c_char) {
    let Some(s) = (unsafe { (sess as *mut TurnSession).as_mut() }) else {
        return;
    };
    s.words = if words.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(words) }.to_string_lossy().into_owned()
    };
}

/// The PARTIAL event when the words changed (rules.words_event); JSON, or NULL.
#[no_mangle]
pub extern "C" fn idfon_voice_turn_words_event(sess: *mut c_void, mode: *const c_char) -> *mut c_char {
    let Some(s) = (unsafe { (sess as *mut TurnSession).as_mut() }) else {
        return std::ptr::null_mut();
    };
    match s.words_event(&mode_str(mode)) {
        Some(ev) => CString::new(serde_json::to_string(&ev).unwrap_or_default())
            .unwrap_or_default()
            .into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// One frame's decision (rules.on_frame). `outputs` is the 8-vector (state
/// logits x4, hazard, yield, bc, p_end); `left` is the hop's frames after this
/// one. Returns JSON {"events":[...], "final":bool, "reset":bool} (NULL on bad
/// args); when a turn ended (`final`), its audio is handed over through
/// `out_audio`/`out_audio_len` (NULL when none — free with
/// `idfon_voice_turn_free_audio`).
#[no_mangle]
pub extern "C" fn idfon_voice_turn_on_frame(
    sess: *mut c_void,
    outputs: *const f32,
    act_db: f64,
    left: usize,
    mode: *const c_char,
    out_audio: *mut *mut f32,
    out_audio_len: *mut usize,
) -> *mut c_char {
    let Some(s) = (unsafe { (sess as *mut TurnSession).as_mut() }) else {
        return std::ptr::null_mut();
    };
    if outputs.is_null() {
        return std::ptr::null_mut();
    }
    let outs: [f32; 8] = unsafe { std::slice::from_raw_parts(outputs, 8) }
        .try_into()
        .unwrap();
    if !out_audio.is_null() {
        unsafe { *out_audio = std::ptr::null_mut() };
    }
    if !out_audio_len.is_null() {
        unsafe { *out_audio_len = 0 };
    }
    let (events, final_, reset) = s.on_frame(&mode_str(mode), outs, act_db, left);
    let mut final_flag = false;
    if let Some((_ev, audio)) = final_ {
        final_flag = true;
        if !out_audio.is_null() && !out_audio_len.is_null() {
            let mut v = audio.into_boxed_slice();
            unsafe {
                *out_audio_len = v.len();
                *out_audio = v.as_mut_ptr();
            }
            std::mem::forget(v);
        }
    }
    let body = serde_json::json!({ "events": events, "final": final_flag, "reset": reset });
    CString::new(serde_json::to_string(&body).unwrap_or_default())
        .unwrap_or_default()
        .into_raw()
}

/// Frees turn audio handed out by `idfon_voice_turn_on_frame`.
#[no_mangle]
pub extern "C" fn idfon_voice_turn_free_audio(ptr: *mut f32, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Vec::from_raw_parts(ptr, len, len) });
    }
}

/// Barge-in filter (P5): whether `text` may cancel playback. The client owns
/// the barge-in state; this reuses the Rust rule (backchannel/sub-minimum and
/// the tool-action window never cancel).
#[no_mangle]
pub extern "C" fn idfon_voice_is_cancellable(
    text: *const c_char,
    playing: u8,
    in_tool_window: u8,
) -> u8 {
    if text.is_null() {
        return 0;
    }
    let text = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    u8::from(idfon_voice::bargein::is_cancellable(
        &text,
        playing != 0,
        in_tool_window != 0,
    ))
}

/// Text-layer echo check (P5): nonzero when `heard` is our own `spoken` text.
#[no_mangle]
pub extern "C" fn idfon_voice_is_echo(spoken: *const c_char, heard: *const c_char) -> u8 {
    if spoken.is_null() || heard.is_null() {
        return 0;
    }
    let spoken = unsafe { CStr::from_ptr(spoken) }.to_string_lossy();
    let heard = unsafe { CStr::from_ptr(heard) }.to_string_lossy();
    let mut suppressor = idfon_voice::echo::EchoSuppressor::new();
    suppressor.set_spoken(&spoken);
    u8::from(suppressor.is_echo(&heard))
}

/// Text-layer echo subtraction (P5): the caller's own words — `heard` with
/// every substantial span echoing `spoken` removed — copied NUL-terminated
/// into `out`. Returns the result's full length (size-first, like
/// `idfon_client_socket_path`: a null `out` sizes the buffer). Mixed
/// transcripts keep the caller's part; pure echo yields an empty string.
#[no_mangle]
pub extern "C" fn idfon_voice_strip_echo(
    spoken: *const c_char,
    heard: *const c_char,
    out: *mut c_char,
    out_len: usize,
) -> usize {
    if spoken.is_null() || heard.is_null() {
        return 0;
    }
    let spoken = unsafe { CStr::from_ptr(spoken) }.to_string_lossy();
    let heard = unsafe { CStr::from_ptr(heard) }.to_string_lossy();
    let mut suppressor = idfon_voice::echo::EchoSuppressor::new();
    suppressor.set_spoken(&spoken);
    let stripped = suppressor.strip_echo(&heard);
    let bytes = stripped.as_bytes();
    if !out.is_null() && out_len > 0 {
        let copy = bytes.len().min(out_len - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out as *mut u8, copy);
            *out.add(copy) = 0;
        }
    }
    bytes.len()
}

#[cfg(test)]
mod turn_tests {
    use super::*;

    #[test]
    fn turn_abi_round_trip() {
        let bad = CString::new("{not json").unwrap().into_raw();
        assert!(idfon_voice_turn_new(bad).is_null());
        unsafe { drop(CString::from_raw(bad)) };

        let s = idfon_voice_turn_new(std::ptr::null());
        assert!(!s.is_null());
        assert_eq!(idfon_voice_turn_prev_state(s), 0);
        let hop = vec![0f32; idfon_voice::turns::HOP_N];
        // the first hop always starts the heads over
        assert_eq!(
            idfon_voice_turn_begin_hop(s, hop.as_ptr(), hop.as_ptr(), hop.len(), std::ptr::null()),
            1
        );
        let outs = [0f32; 8];
        let mut audio: *mut f32 = std::ptr::null_mut();
        let mut alen = 0usize;
        let evs = idfon_voice_turn_on_frame(
            s,
            outs.as_ptr(),
            -100.0,
            idfon_voice::turns::HOP_FRAMES - 1,
            b"listen\0".as_ptr() as *const c_char,
            &mut audio,
            &mut alen,
        );
        assert!(!evs.is_null());
        let text = unsafe { CStr::from_ptr(evs) }.to_str().unwrap().to_string();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert!(v["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["kind"] == "FRAME"));
        assert_eq!(v["final"], false);
        assert_eq!(v["reset"], false);
        unsafe { drop(CString::from_raw(evs)) };
        // bad args return NULL instead of crashing
        assert!(idfon_voice_turn_on_frame(
            s,
            std::ptr::null(),
            0.0,
            0,
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut()
        )
        .is_null());
        idfon_voice_turn_free(s);
        idfon_voice_turn_free(std::ptr::null_mut()); // double-free guard: NULL is a no-op
    }
}

#[cfg(target_os = "ios")]
mod engine {
    use std::ffi::{c_char, CString};

    use anyhow::{bail, Result};
    use idfon_voice::apple_ffi::{
        set_bindings, AppleVoiceBindings, AppleVoiceEngine, FreeBytesFn, FreeTextFn, SttFn, TtsFn,
    };
    use idfon_voice::{AudioFormat, VoiceEngine};

    /// Register the Swift engine's C functions. Returns 0 on success.
    #[no_mangle]
    pub extern "C" fn idfon_voice_set_bindings(
        tts: TtsFn,
        stt: SttFn,
        free_bytes: FreeBytesFn,
        free_text: FreeTextFn,
    ) -> i32 {
        set_bindings(AppleVoiceBindings {
            tts,
            stt,
            free_bytes,
            free_text,
        });
        0
    }

    /// Runs the Rust seam against the Swift Apple engine; returns a Rust-owned
    /// C string (transcript, or `error:...`). Requires the bindings to be set.
    #[no_mangle]
    pub extern "C" fn idfon_voice_apple_selftest() -> *mut c_char {
        let text = match run() {
            Ok(transcript) => transcript,
            Err(error) => format!("error:{error:#}"),
        };
        CString::new(text)
            .unwrap_or_default()
            .into_raw()
    }

    fn run() -> Result<String> {
        eprintln!("[idfon voice] seam: tts start");
        let engine = AppleVoiceEngine::new();
        let mut tts = engine.tts("default", AudioFormat::PCM_24K_MONO)?;
        let phrase = "the quick brown fox jumps over the lazy dog";
        let mut chunks = tts.push_text(phrase)?;
        chunks.extend(tts.finish()?);

        let format = chunks
            .first()
            .map(|chunk| chunk.format)
            .unwrap_or(AudioFormat::PCM_24K_MONO);
        let samples: Vec<i16> = chunks.into_iter().flat_map(|chunk| chunk.samples).collect();
        eprintln!(
            "[idfon voice] seam: tts samples={} rate={}",
            samples.len(),
            format.sample_rate
        );
        if samples.is_empty() {
            bail!("tts produced no samples");
        }

        eprintln!("[idfon voice] seam: stt start");
        let mut stt = engine.stt(format)?;
        stt.push(&samples)?;
        let transcript = stt.finish()?.unwrap_or_default();
        if transcript.trim().is_empty() {
            bail!("stt produced no transcript");
        }
        Ok(transcript)
    }
}
