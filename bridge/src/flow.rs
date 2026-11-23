//! The product pipeline (`viaform_core::flow`) for the Swift app: one handle per project, JSON
//! text both ways. Every string returned here is freed with `sc_string_free`.
//!
//! This is the project layer the interface plan calls `vf_project_*`: stages and outputs come
//! from `vf_flow_state`, revisions, the tree, the selection, the command catalog and its search
//! from `vf_flow_query`, and every change (builds, promotions, jobs, eyes and locks, selection,
//! saving `flow.json` into the `.viaform` file) from `vf_flow_command`.

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

/// The worked example (the 3 inch racer half way through a new frame) for previews and
/// screenshots.
#[unsafe(no_mangle)]
pub extern "C" fn vf_flow_new_sample() -> *mut VfFlow {
    Box::into_raw(Box::new(VfFlow { flow: guard(Flow::new(), Flow::sample) }))
}

/// # Safety
/// `flow` is null or a handle from `vf_flow_new*`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_free(flow: *mut VfFlow) {
    if !flow.is_null() {
        // SAFETY: a handle from vf_flow_new, per the contract above.
        drop(unsafe { Box::from_raw(flow) });
    }
}

/// The product, stages, artifacts, running jobs and selection.
///
/// # Safety
/// `flow` is a live handle from `vf_flow_new*`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_state(flow: *const VfFlow) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(f) = (unsafe { flow.as_ref() }) else { return out(&json!({"error": "no pipeline"})) };
    out(&guard(json!({"error": "the pipeline panicked"}), || f.flow.state()))
}

/// # Safety
/// `command` is null or a NUL-terminated string.
unsafe fn parse(command: *const c_char) -> Result<Value, *mut c_char> {
    // SAFETY: NUL-terminated string, per the caller's contract.
    match unsafe { text(command) }.map(serde_json::from_str::<Value>) {
        Some(Ok(v)) => Ok(v),
        _ => Err(out(&json!({"error": "the command is not JSON"}))),
    }
}

/// Runs one command (`{"op", ...}`, see `Flow::command`) and answers its result.
///
/// # Safety
/// `flow` is a live handle from `vf_flow_new*`; `command` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_command(flow: *mut VfFlow, command: *const c_char) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(f) = (unsafe { flow.as_mut() }) else { return out(&json!({"error": "no pipeline"})) };
    // SAFETY: per the contract above.
    let cmd = match unsafe { parse(command) } {
        Ok(v) => v,
        Err(e) => return e,
    };
    out(&guard(json!({"error": "the pipeline panicked"}), || f.flow.command(&cmd)))
}

/// Answers a command that only reads (`revisions`, `diff`, `tree`, `selection`, `outputs`,
/// `commands`, `search`, `plan_update`, `downstream`, `export`, `state`).
///
/// # Safety
/// `flow` is a live handle from `vf_flow_new*`; `query` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_query(flow: *const VfFlow, query: *const c_char) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(f) = (unsafe { flow.as_ref() }) else { return out(&json!({"error": "no pipeline"})) };
    // SAFETY: per the contract above.
    let q = match unsafe { parse(query) } {
        Ok(v) => v,
        Err(e) => return e,
    };
    out(&guard(json!({"error": "the pipeline panicked"}), || {
        f.flow.query(&q).unwrap_or_else(|| json!({"error": format!("{} changes the pipeline; send it with vf_flow_command", q["op"])}))
    }))
}

/// Polls the Rust workers attached to jobs; answers `{"ended": [job ids]}`.
///
/// # Safety
/// `flow` is a live handle from `vf_flow_new*`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_flow_tick(flow: *mut VfFlow) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(f) = (unsafe { flow.as_mut() }) else { return out(&json!({"error": "no pipeline"})) };
    out(&guard(json!({"error": "the pipeline panicked"}), || json!({"ended": f.flow.tick()})))
}

/// Every command of the eight stages (`[{id, label, stage, group, icon, key?, source,
/// detail}]`), without a project.
#[unsafe(no_mangle)]
pub extern "C" fn vf_flow_commands() -> *mut c_char {
    out(&guard(json!([]), || viaform_core::flow::commands::list(None)))
}
