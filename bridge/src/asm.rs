//! Assemble (`viaform_core::asm`) for the Swift app: one handle per open assembly, one JSON call.
//! Ops that need geometry (mass properties, interference, motion study, exports) read it from
//! the open design when a session is passed, as does `mate_cad` (the design's joints) and `drive`
//! (moves the design's mated joints so the viewport follows). Replies are `{"ok": ...}` or
//! `{"error": message}`, freed with `sc_string_free`.

use std::ffi::c_char;

use serde_json::{Value, json};
use viaform_core::asm::{Asm, Assembly};

use super::{ScSession, guard, out, text};

pub struct VfAsm {
    asm: Asm,
}

/// A new, empty assembly.
#[unsafe(no_mangle)]
pub extern "C" fn vf_asm_new() -> *mut VfAsm {
    guard(std::ptr::null_mut(), || Box::into_raw(Box::new(VfAsm { asm: Asm::default() })))
}

/// An assembly from `assembly.json` text (`viaform-asm` v1); null when the text does not read
/// or a newer ViaForm wrote it.
///
/// # Safety
/// `json` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_asm_open(json: *const c_char) -> *mut VfAsm {
    // SAFETY: NUL-terminated string, per the contract above.
    let Some(t) = (unsafe { text(json) }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || {
        serde_json::from_str::<Value>(t)
            .ok()
            .and_then(|v| Assembly::from_json(&v).ok())
            .and_then(|doc| Asm::new(doc).ok())
            .map_or(std::ptr::null_mut(), |asm| Box::into_raw(Box::new(VfAsm { asm })))
    })
}

/// # Safety
/// `h` is null or came from `vf_asm_new` or `vf_asm_open`, and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_asm_free(h: *mut VfAsm) {
    if !h.is_null() {
        // SAFETY: `h` came from `Box::into_raw` in `vf_asm_new` or `vf_asm_open`.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// Runs `op` with `params` (a JSON object, may be null) on the assembly; `sc` is null or the
/// open design. See `viaform_asm.h` for the ops.
///
/// # Safety
/// `h` is a live handle; `sc` is null or a live session; `op` and `params` are NUL-terminated
/// strings (`params` may be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_asm_call(h: *mut VfAsm, sc: *mut ScSession, op: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: a live handle and a null or live session, per the contract above.
    let (Some(h), sc) = (unsafe { h.as_mut() }, unsafe { sc.as_mut() }) else { return out(&json!({"error": "no assembly"})) };
    // SAFETY: NUL-terminated strings, per the contract above.
    let (op, params) = unsafe { (text(op), text(params)) };
    let reply = guard(Err("the assembly stopped on this call".to_string()), || {
        let op = op.ok_or("no op")?;
        let p: Value = match params {
            Some(p) if !p.trim().is_empty() => serde_json::from_str(p).map_err(|e| format!("params: {e}"))?,
            _ => json!({}),
        };
        match sc {
            Some(sc) => h.asm.call_with_cad(op, &p, &mut sc.session),
            None => h.asm.call(op, &p),
        }
    });
    out(&match reply {
        Ok(v) => json!({"ok": v}),
        Err(e) => json!({"error": e}),
    })
}
