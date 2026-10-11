//! C ABI for the Apple apps. The apps prewarm at call setup and push turns.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};

use crate::Director;

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', " ")).unwrap().into_raw()
}

/// Copy a NUL-terminated C string. Null becomes the empty string.
unsafe fn read_cstr(value: *const c_char) -> String {
    if value.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(value) }
            .to_string_lossy()
            .into_owned()
    }
}

/// The FFI config for an on-device director. Only the fields the app can set
/// are here; the rest use the defaults.
#[cfg(feature = "afm")]
#[derive(Default, serde::Deserialize)]
struct DirectorConfig {
    /// Tool names the capability grant permits. Absent = no grant installed.
    #[serde(default)]
    grant: Option<Vec<String>>,
    /// The session's tool-call budget.
    #[serde(default)]
    budget: Option<u32>,
    #[serde(default)]
    trace: Option<crate::trace::TraceInfo>,
    #[serde(default)]
    redaction: Option<crate::trace::Redaction>,
}

#[cfg(feature = "afm")]
fn options_from_json(config_json: *const c_char) -> Result<crate::DirectorOptions, String> {
    let raw = unsafe { read_cstr(config_json) };
    let config: DirectorConfig = if raw.trim().is_empty() {
        DirectorConfig::default()
    } else {
        serde_json::from_str(&raw).map_err(|error| error.to_string())?
    };
    let mut options = crate::DirectorOptions::default();
    if let Some(grant) = config.grant {
        let mut authority = crate::authority::Authority::grant(grant);
        if let Some(budget) = config.budget {
            authority = authority.with_budget(budget);
        }
        options.authority = Some(authority);
    }
    if let Some(trace) = config.trace {
        options.trace = trace;
    }
    if let Some(redaction) = config.redaction {
        options.redaction = redaction;
    }
    Ok(options)
}

/// Create a director. The scaffold uses the mock provider; #34 swaps in AFM.
///
/// # Safety
/// `instructions` must be a valid NUL-terminated C string or null.
#[no_mangle]
pub unsafe extern "C" fn idfon_director_new(instructions: *const c_char) -> *mut c_void {
    let text = unsafe { read_cstr(instructions) };
    let director = crate::mock_director(&text);
    Box::into_raw(Box::new(director)).cast()
}

/// Create an on-device director on Apple Foundation Models. Returns null when
/// AFM is unavailable (below the OS floor, or Apple Intelligence off), so the
/// caller can fall back to the remote tier.
///
/// # Safety
/// `instructions` must be a valid NUL-terminated C string or null.
#[cfg(feature = "afm")]
#[no_mangle]
pub unsafe extern "C" fn idfon_director_new_afm(instructions: *const c_char) -> *mut c_void {
    let text = unsafe { read_cstr(instructions) };
    match crate::Director::afm(&text) {
        Ok(director) => Box::into_raw(Box::new(director)).cast(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Create an on-device director on Apple Foundation Models with a JSON config
/// (capability grant, budget, trace metadata, redaction). Returns null when AFM
/// is unavailable or the config is invalid, so the caller can fall back.
///
/// The config object is
/// `{ "grant"?: [string], "budget"?: number, "trace"?: object, "redaction"?: object }`.
/// An absent `grant` installs no authority (all tools allowed); an empty array
/// denies every tool.
///
/// # Safety
/// Both pointers must be valid NUL-terminated C strings or null.
#[cfg(feature = "afm")]
#[no_mangle]
pub unsafe extern "C" fn idfon_director_new_afm_config(
    instructions: *const c_char,
    config_json: *const c_char,
) -> *mut c_void {
    let text = unsafe { read_cstr(instructions) };
    let options = match options_from_json(config_json) {
        Ok(options) => options,
        Err(_) => return std::ptr::null_mut(),
    };
    match crate::Director::afm_with_options(&text, options) {
        Ok(director) => Box::into_raw(Box::new(director)).cast(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Prewarm the model (no-op in the scaffold).
///
/// # Safety
/// `ptr` must come from `idfon_director_new`.
#[no_mangle]
pub unsafe extern "C" fn idfon_director_prewarm(ptr: *mut c_void) -> i32 {
    if ptr.is_null() {
        return -1;
    }
    let director = unsafe { &*(ptr as *const Director) };
    director.prewarm();
    0
}

/// Run one turn. Returns a JSON `TurnResult` the caller frees with
/// `idfon_director_free_string`. Returns null on error.
///
/// # Safety
/// `ptr` must come from `idfon_director_new`; `text` must be a valid
/// NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn idfon_director_turn(ptr: *mut c_void, text: *const c_char) -> *mut c_char {
    if ptr.is_null() || text.is_null() {
        return std::ptr::null_mut();
    }
    let director = unsafe { &mut *(ptr as *mut Director) };
    let prompt = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    let result = director.turn(&prompt);
    match serde_json::to_string(&result) {
        Ok(json) => to_c(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Run one turn from a JSON `TurnInput` (text, references, attachments) and
/// return the JSON `TurnResult` (envelopes + full trace record). Returns null
/// on a bad input.
///
/// # Safety
/// `ptr` must come from `idfon_director_new*`; `input_json` must be a valid
/// NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn idfon_director_turn_input(
    ptr: *mut c_void,
    input_json: *const c_char,
) -> *mut c_char {
    if ptr.is_null() || input_json.is_null() {
        return std::ptr::null_mut();
    }
    let input: crate::turn_input::TurnInput =
        match serde_json::from_str(&unsafe { read_cstr(input_json) }) {
            Ok(input) => input,
            Err(_) => return std::ptr::null_mut(),
        };
    let director = unsafe { &mut *(ptr as *mut Director) };
    let result = director.turn_input(&input);
    match serde_json::to_string(&result) {
        Ok(json) => to_c(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Free a director.
///
/// # Safety
/// `ptr` must come from `idfon_director_new` and not be used again.
#[no_mangle]
pub unsafe extern "C" fn idfon_director_free(ptr: *mut c_void) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(ptr as *mut Director) });
    }
}

/// Free a string from `idfon_director_turn`.
///
/// # Safety
/// `s` must come from `idfon_director_turn` and not be used again.
#[no_mangle]
pub unsafe extern "C" fn idfon_director_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
