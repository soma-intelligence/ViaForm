//! The product pipeline (`viaform_core::flow`) for the Swift app: one handle per project, JSON
//! text both ways. Every string returned here is freed with `sc_string_free`.

use std::ffi::c_char;

use serde_json::{Value, json};
use viaform_core::flow::Flow;

use super::{guard, out, text};

/// One project's pipeline.
pub struct VfFlow {
    flow: Flow,
}

#[unsafe(no_mangle)]
pub extern "C" fn vf_flow_new() -> *mut VfFlow {
    Box::into_raw(Box::new(VfFlow { flow: Flow::new() }))
}

/// # Safety
/// `flow` is null or a handle from `vf_flow_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_free(flow: *mut VfFlow) {
    if !flow.is_null() {
        // SAFETY: a handle from vf_flow_new, per the contract above.
        drop(unsafe { Box::from_raw(flow) });
    }
}

/// The stages, artifacts and running jobs: `{"stages", "nodes", "jobs"}`.
///
/// # Safety
/// `flow` is a live handle from `vf_flow_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_state(flow: *const VfFlow) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(f) = (unsafe { flow.as_ref() }) else { return out(&json!({"error": "no pipeline"})) };
    out(&guard(json!({"error": "the pipeline panicked"}), || f.flow.state()))
}

/// Runs one command (`{"op", "artifact", ...}`, see `Flow::command`) and answers its result.
///
/// # Safety
/// `flow` is a live handle from `vf_flow_new`; `command` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_command(flow: *mut VfFlow, command: *const c_char) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(f) = (unsafe { flow.as_mut() }) else { return out(&json!({"error": "no pipeline"})) };
    // SAFETY: NUL-terminated string, per the contract above.
    let cmd: Value = match unsafe { text(command) }.map(serde_json::from_str) {
        Some(Ok(v)) => v,
        _ => return out(&json!({"error": "the command is not JSON"})),
    };
    out(&guard(json!({"error": "the pipeline panicked"}), || f.flow.command(&cmd)))
}
