//! The drone simulation (viaform-sim) for the Swift app: one handle per flight and JSON text both
//! ways, the same facade (`viaform_sim::api`) every front end uses. Every string returned here is
//! freed with `sc_string_free`; a panic inside the simulation answers `{"error": ...}`.

use std::ffi::{CString, c_char};

use serde_json::json;
use viaform_sim::api::{self, Session};
use viaform_sim::job::TrainJob;

use super::{guard, out, text};

/// One flight.
pub struct VfSim {
    session: Session,
}

/// The facade already answers JSON text; hand it over as it is.
fn raw(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn panicked() -> String {
    json!({ "error": "the simulation panicked" }).to_string()
}

/// The weather presets, brains, courses, missions and disturbances, for the pickers.
#[unsafe(no_mangle)]
pub extern "C" fn vf_sim_catalog() -> *mut c_char {
    raw(guard(panicked(), api::catalog))
}

/// The drone's parts list with the masses the simulation uses, for a frame of `frame_g` grams.
#[unsafe(no_mangle)]
pub extern "C" fn vf_sim_parts(frame_g: f64) -> *mut c_char {
    raw(guard(panicked(), || api::parts(frame_g)))
}

/// Runs a whole flight off to the side and returns its result (the benchmark).
///
/// # Safety
/// `options` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_episode(options: *const c_char) -> *mut c_char {
    // SAFETY: NUL-terminated string, per the contract above.
    let o = unsafe { text(options) }.unwrap_or("{}").to_owned();
    raw(guard(panicked(), || api::episode(&o)))
}

/// Starts a flight from its options (JSON). Null when the options do not parse.
///
/// # Safety
/// `options` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_start(options: *const c_char) -> *mut VfSim {
    // SAFETY: NUL-terminated string, per the contract above.
    let o = unsafe { text(options) }.unwrap_or("{}").to_owned();
    guard(None, || Session::start(&o).ok()).map_or(std::ptr::null_mut(), |session| Box::into_raw(Box::new(VfSim { session })))
}

/// # Safety
/// `sim` is null or came from `vf_sim_start`, and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_free(sim: *mut VfSim) {
    if !sim.is_null() {
        // SAFETY: `sim` came from `Box::into_raw` in `vf_sim_start`.
        drop(unsafe { Box::from_raw(sim) });
    }
}

/// What does not move: obstacles, waypoints, gates and bounds, with the first frame and status.
///
/// # Safety
/// `sim` came from `vf_sim_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_world(sim: *const VfSim) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(sim) = (unsafe { sim.as_ref() }) else { return out(&json!({ "error": "no flight" })) };
    raw(guard(panicked(), || sim.session.world()))
}

/// Advances by `seconds` of simulated time; returns the frame, new trail points, the status and
/// the stabilization readout.
///
/// # Safety
/// `sim` came from `vf_sim_start` and is not used from another thread at the same time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_advance(sim: *mut VfSim, seconds: f64) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(sim) = (unsafe { sim.as_mut() }) else { return out(&json!({ "error": "no flight" })) };
    raw(guard(panicked(), || sim.session.advance(seconds)))
}

/// One disturbance of `kind` (kick, gust, tumble, payload, prop) now, or "timed" to toggle random
/// ones. False for an unknown kind.
///
/// # Safety
/// `sim` came from `vf_sim_start`; `kind` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_disturb(sim: *mut VfSim, kind: *const c_char) -> bool {
    // SAFETY: a live handle and a NUL-terminated string, per the contract above.
    let (Some(sim), Some(kind)) = (unsafe { sim.as_mut() }, unsafe { text(kind) }) else { return false };
    guard(false, || sim.session.disturb(kind))
}

/// The sticks for a manual flight: `{"x","y","z","yaw"}` each -1..1, optionally `"mode"`
/// ("position" or "angle"). False when the text does not parse.
///
/// # Safety
/// `sim` came from `vf_sim_start`; `sticks` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_pilot(sim: *mut VfSim, sticks: *const c_char) -> bool {
    // SAFETY: a live handle and a NUL-terminated string, per the contract above.
    let (Some(sim), Some(sticks)) = (unsafe { sim.as_mut() }, unsafe { text(sticks) }) else { return false };
    guard(false, || sim.session.set_pilot(sticks))
}

/// What a generated frame file (docs/generative/drone-frame.json) builds, or `{"error"}`.
///
/// # Safety
/// `frame` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_airframe(frame: *const c_char) -> *mut c_char {
    // SAFETY: NUL-terminated string, per the contract above.
    let f = unsafe { text(frame) }.unwrap_or("").to_owned();
    raw(guard(panicked(), || api::airframe(&f)))
}

/// A training running on its own threads.
pub struct VfTrain {
    job: TrainJob,
}

/// Starts a training (`{"target": "tracking" | "stabilize" | "policy", "rateLoop", "iterations",
/// "population", "episodes", "seed"}`). Null when the options are refused.
///
/// # Safety
/// `options` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_train_start(options: *const c_char) -> *mut VfTrain {
    // SAFETY: NUL-terminated string, per the contract above.
    let o = unsafe { text(options) }.unwrap_or("").to_owned();
    guard(None, || TrainJob::start(&o).ok()).map_or(std::ptr::null_mut(), |job| Box::into_raw(Box::new(VfTrain { job })))
}

/// `{running, stage, iteration, total, history, result?, error?}`; `result.brain` goes into the
/// flight options as `custom` with `brain: "custom"`.
///
/// # Safety
/// `job` came from `vf_train_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_train_progress(job: *const VfTrain) -> *mut c_char {
    // SAFETY: a live handle, per the contract above.
    let Some(job) = (unsafe { job.as_ref() }) else { return out(&json!({ "error": "no training" })) };
    raw(guard(panicked(), || job.job.progress()))
}

/// Stops after the current iteration; the job still reports what it has.
///
/// # Safety
/// `job` came from `vf_train_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_train_cancel(job: *const VfTrain) {
    // SAFETY: a live handle, per the contract above.
    if let Some(job) = unsafe { job.as_ref() } {
        job.job.cancel();
    }
}

/// Cancels the job if it still runs, waits for it and frees it.
///
/// # Safety
/// `job` is null or came from `vf_train_start`, and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_train_free(job: *mut VfTrain) {
    if !job.is_null() {
        // SAFETY: `job` came from `Box::into_raw` in `vf_train_start`.
        drop(unsafe { Box::from_raw(job) });
    }
}

/// What the sourced components build: `request` is `{"components": text, "assembly"?, "frame"?}`;
/// replies `{massKg, inertia, thrustToWeight, sources, missing, ...}` or `{"error"}`.
///
/// # Safety
/// `request` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_sim_vehicle(request: *const c_char) -> *mut c_char {
    // SAFETY: NUL-terminated string, per the contract above.
    let r = unsafe { text(request) }.unwrap_or("").to_owned();
    raw(guard(panicked(), || api::vehicle(&r)))
}
