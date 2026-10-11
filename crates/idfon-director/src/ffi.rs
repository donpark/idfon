//! C ABI for the Apple apps. The apps prewarm at call setup and push turns.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};

use crate::Director;

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', " ")).unwrap().into_raw()
}

/// Create a director. The scaffold uses the mock provider; #34 swaps in AFM.
///
/// # Safety
/// `instructions` must be a valid NUL-terminated C string or null.
#[no_mangle]
pub unsafe extern "C" fn idfon_director_new(instructions: *const c_char) -> *mut c_void {
    let text = if instructions.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(instructions) }
            .to_string_lossy()
            .into_owned()
    };
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
    let text = if instructions.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(instructions) }
            .to_string_lossy()
            .into_owned()
    };
    match crate::Director::afm(&text) {
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
    let prompt = unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned();
    let result = director.turn(&prompt);
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
