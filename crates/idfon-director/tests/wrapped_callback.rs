//! The host callback that backs `voice_forward` (#38, FFI wiring).

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::sync::Mutex;

use idfon_director::wrapped::{CallbackWrapped, WrappedAgent};

static SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());

unsafe extern "C" fn forward(
    _ctx: *mut c_void,
    text: *const c_char,
    delegation_id: *const c_char,
    out_reply: *mut *mut c_char,
) -> i32 {
    let text = unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned();
    let id = unsafe { CStr::from_ptr(delegation_id) }
        .to_string_lossy()
        .into_owned();
    SEEN.lock().unwrap().push(format!("{text}|{id}"));
    let reply = CString::new("the agent reply").unwrap();
    unsafe { *out_reply = reply.into_raw() };
    0
}

unsafe extern "C" fn free_reply(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}

unsafe extern "C" fn forward_fails(
    _ctx: *mut c_void,
    _text: *const c_char,
    _id: *const c_char,
    _out: *mut *mut c_char,
) -> i32 {
    7
}

/// The callback receives the text and delegation id and returns its reply.
#[tokio::test]
async fn a_callback_forward_returns_the_reply() {
    let agent = unsafe { CallbackWrapped::new(std::ptr::null_mut(), forward, free_reply) };
    let reply = agent.forward("hello agent", "turn-3-abc").await.unwrap();
    assert_eq!(reply, "the agent reply");
    assert_eq!(
        SEEN.lock().unwrap().last().unwrap(),
        "hello agent|turn-3-abc"
    );
}

/// A non-zero callback return is an error the tool can report.
#[tokio::test]
async fn a_callback_failure_is_an_error() {
    let agent =
        unsafe { CallbackWrapped::new(std::ptr::null_mut(), forward_fails, free_reply) };
    let error = agent.forward("hello", "turn-1").await.unwrap_err();
    assert!(error.contains("code 7"), "{error}");
}
