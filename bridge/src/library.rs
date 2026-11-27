//! The side libraries (viaform-library) for the Swift app: one handle on the user's library folder
//! and one JSON call. API keys come with each search from the macOS Keychain; nothing here stores them.

use std::ffi::c_char;

use serde_json::{Value, json};
use viaform_library::Library;

use super::{guard, out, text};

/// The user's library: saved parts, attached CAD files, settings of the sources.
pub struct VfLibrary {
    library: Library,
}

/// Opens (or creates) the library kept in `dir`. Null when the folder cannot be created.
///
/// # Safety
/// `dir` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_library_open(dir: *const c_char) -> *mut VfLibrary {
    // SAFETY: NUL-terminated string, per the contract above.
    let Some(dir) = (unsafe { text(dir) }) else { return std::ptr::null_mut() };
    guard(None, || Library::open(dir).ok()).map_or(std::ptr::null_mut(), |library| Box::into_raw(Box::new(VfLibrary { library })))
}

/// # Safety
/// `lib` is null or came from `vf_library_open`, and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_library_free(lib: *mut VfLibrary) {
    if !lib.is_null() {
        // SAFETY: `lib` came from `Box::into_raw` in `vf_library_open`.
        drop(unsafe { Box::from_raw(lib) });
    }
}

/// Runs `method` with `params` (JSON). Answers `{"ok": value}` or `{"error": message}`. Searches
/// reach the shops' APIs and may take seconds: call it off the main thread, one call at a time.
///
/// # Safety
/// `lib` is a live library; `method` and `params` are NUL-terminated strings (`params` may be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_library_call(lib: *mut VfLibrary, method: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: the caller passes a live library.
    let Some(lib) = (unsafe { lib.as_mut() }) else { return out(&json!({"error": "no library"})) };
    // SAFETY: NUL-terminated strings, per the contract above.
    let (method, params) = unsafe { (text(method), text(params)) };
    let reply = guard(Err("the library stopped on this call".to_string()), || {
        let params: Value = match params {
            Some(p) if !p.trim().is_empty() => serde_json::from_str(p).map_err(|e| format!("params: {e}"))?,
            _ => json!({}),
        };
        lib.library.call(method.ok_or("no method")?, &params)
    });
    out(&match reply {
        Ok(v) => json!({ "ok": v }),
        Err(e) => json!({ "error": e }),
    })
}
