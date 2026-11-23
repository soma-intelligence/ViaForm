//! Generative studies as jobs for the Swift app: start a 3D study on its own thread, poll its
//! progress, cancel it, take its outcome, and build a candidate into a design without running
//! the study again (`viaform_core::generative::Job`). Every string returned here is freed with
//! `sc_string_free`; a panic inside the engine answers `{"error": ...}`.

use std::ffi::c_char;

use serde_json::{Value, json};
use viaform_core::generative::Job;

use super::{ScSession, guard, link_reply, out, text};

/// One running (or finished) study.
pub struct VfGenJob {
    job: Job,
}

/// Starts the 3D study `spec` (JSON). Null when it does not read; `error` (when not null) then
/// receives the reason, freed with `sc_string_free`.
///
/// # Safety
/// `spec` is a NUL-terminated string; `error` is null or points to writable storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_start(spec: *const c_char, error: *mut *mut c_char) -> *mut VfGenJob {
    // SAFETY: NUL-terminated string, per the contract above.
    let spec = unsafe { text(spec) };
    let r = guard(Err("the engine stopped on this study".to_string()), || {
        let v: Value = serde_json::from_str(spec.ok_or("no spec")?).map_err(|e| format!("spec: {e}"))?;
        Job::start(&v)
    });
    match r {
        Ok(job) => Box::into_raw(Box::new(VfGenJob { job })),
        Err(e) => {
            if !error.is_null() {
                // SAFETY: the caller passes writable storage or null.
                unsafe { *error = out(&json!({"error": e})) };
            }
            std::ptr::null_mut()
        }
    }
}

/// `{running, cancelled, paused, variant, variants, iteration, iterations, objective, stage,
/// fraction, seconds, eta, per_iteration, paused_seconds, preview}` (see the header).
///
/// # Safety
/// `job` is a live job.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_progress(job: *const VfGenJob) -> *mut c_char {
    // SAFETY: the caller passes a live job.
    let Some(j) = (unsafe { job.as_ref() }) else { return out(&json!({"error": "no job"})) };
    out(&guard(json!({"error": "progress"}), || j.job.progress()))
}

/// Asks the study to stop at its next iteration. The run then keeps its best design so far
/// (see `vf_generate_summary`). Safe to call again, before or after the run ends.
///
/// # Safety
/// `job` is a live job.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_cancel(job: *const VfGenJob) {
    // SAFETY: the caller passes a live job.
    if let Some(j) = unsafe { job.as_ref() } {
        j.job.cancel();
    }
}

/// Waits for the study, then answers `{"ok": outcome}` or `{"error": message}`. A stopped run
/// answers its outcome with `stopped` true (the candidates finished before the stop plus the
/// stopped one's best iterate, `converged` false); `cancelled` only when it was stopped before
/// any usable shape. Can be asked again.
///
/// # Safety
/// `job` is a live job (any thread).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_outcome(job: *const VfGenJob) -> *mut c_char {
    // SAFETY: the caller passes a live job.
    let Some(j) = (unsafe { job.as_ref() }) else { return out(&json!({"error": "no job"})) };
    link_reply(guard(Err("the engine stopped on this study".into()), || j.job.outcome()))
}

/// Builds candidate `candidate` (-1: the best) of the finished study into the design `s` as one
/// mesh body in one undo step. Answers `{"ok": {candidate, body, commands}}` or `{"error"}`.
///
/// # Safety
/// `s` is a live session and `job` a live job.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_build(s: *mut ScSession, job: *const VfGenJob, candidate: i64) -> *mut c_char {
    // SAFETY: the caller passes a live session and job.
    let (Some(s), Some(j)) = (unsafe { s.as_mut() }, unsafe { job.as_ref() }) else { return out(&json!({"error": "no session or job"})) };
    link_reply(guard(Err("the engine stopped while building the candidate".into()), || j.job.build(&mut s.session, usize::try_from(candidate).ok())))
}

/// Holds the study after its current iteration (`paused` true) or lets it go on (false).
///
/// # Safety
/// `job` is a live job.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_pause(job: *const VfGenJob, paused: bool) {
    // SAFETY: the caller passes a live job.
    if let Some(j) = unsafe { job.as_ref() } {
        j.job.set_paused(paused);
    }
}

/// The iterations from `from` on (0: all), as a JSON array of `{variant, iteration,
/// iterations, objective, compliance, volume, max_stress, seconds}`. Never waits.
///
/// # Safety
/// `job` is a live job.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_history(job: *const VfGenJob, from: u64) -> *mut c_char {
    // SAFETY: the caller passes a live job.
    let Some(j) = (unsafe { job.as_ref() }) else { return out(&json!({"error": "no job"})) };
    out(&guard(json!([]), || j.job.history(from as usize)))
}

/// Waits for the study, then answers `{"ok": {candidates, best, seconds, warnings}}` with each
/// candidate's figures, `cost` and `f1` but no densities or surface (small: results open at
/// once), or `{"error"}`. Each candidate carries `converged` (false for a stopped run's kept
/// iterate), `stopped_at` (iterations run at the stop, else null) and `kept_iteration`; a
/// stopped run adds a warning that starts with "stopped at iteration".
///
/// # Safety
/// `job` is a live job (any thread).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_summary(job: *const VfGenJob) -> *mut c_char {
    // SAFETY: the caller passes a live job.
    let Some(j) = (unsafe { job.as_ref() }) else { return out(&json!({"error": "no job"})) };
    link_reply(guard(Err("the engine stopped on this study".into()), || j.job.summary()))
}

/// A triangle mesh handed over as flat arrays (world mm): `vertex_count` xyz triples,
/// `index_count` indices (three per triangle), `stress` one value per vertex (MPa) or null.
/// `variant` and `iteration` say which run state a live preview shows; `version` orders
/// previews. Freed with `vf_generate_mesh_free`.
#[repr(C)]
pub struct VfGenMesh {
    pub positions: *const f32,
    pub vertex_count: u64,
    pub indices: *const u32,
    pub index_count: u64,
    pub stress: *const f32,
    pub version: u64,
    pub variant: u64,
    pub iteration: u64,
}

/// The arrays a [`VfGenMesh`] points into (the head first, so the two share an address).
#[repr(C)]
struct MeshBox {
    head: VfGenMesh,
    _mesh: viaform_core::viaform_generative::solid::Mesh,
}

fn mesh_out(mesh: viaform_core::viaform_generative::solid::Mesh, version: u64, variant: usize, iteration: usize) -> *mut VfGenMesh {
    let stress = if mesh.stress.len() * 3 == mesh.positions.len() && !mesh.stress.is_empty() { mesh.stress.as_ptr() } else { std::ptr::null() };
    let head = VfGenMesh {
        positions: mesh.positions.as_ptr(),
        vertex_count: (mesh.positions.len() / 3) as u64,
        indices: mesh.indices.as_ptr(),
        index_count: mesh.indices.len() as u64,
        stress,
        version,
        variant: variant as u64,
        iteration: iteration as u64,
    };
    let b = Box::new(MeshBox { head, _mesh: mesh });
    let raw = Box::into_raw(b);
    // SAFETY: `raw` is a live box; its `head` field is handed out and turned back in `vf_generate_mesh_free`.
    unsafe { std::ptr::addr_of_mut!((*raw).head) }
}

/// The latest live preview of the running study (a coarse iso surface of its densities) when
/// newer than `since` (a previous `version`; 0 the first time), else null. Surfacing runs on the
/// calling thread: call it off the main thread. Never waits for the run.
///
/// # Safety
/// `job` is a live job.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_preview(job: *const VfGenJob, since: u64) -> *mut VfGenMesh {
    // SAFETY: the caller passes a live job.
    let Some(j) = (unsafe { job.as_ref() }) else { return std::ptr::null_mut() };
    match guard(None, || j.job.preview(since)) {
        Some((version, variant, iteration, mesh)) => mesh_out(mesh, version, variant, iteration),
        None => std::ptr::null_mut(),
    }
}

/// Waits for the study, then hands candidate `candidate`'s surface (-1: the best); null when
/// the run failed or there is no such candidate.
///
/// # Safety
/// `job` is a live job (any thread).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_mesh(job: *const VfGenJob, candidate: i64) -> *mut VfGenMesh {
    // SAFETY: the caller passes a live job.
    let Some(j) = (unsafe { job.as_ref() }) else { return std::ptr::null_mut() };
    match guard(Err(String::new()), || j.job.with_mesh(usize::try_from(candidate).ok(), Clone::clone)) {
        Ok(mesh) => mesh_out(mesh, 0, 0, 0),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Frees a mesh from `vf_generate_preview` or `vf_generate_mesh`.
///
/// # Safety
/// `mesh` is null or from those calls, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_mesh_free(mesh: *mut VfGenMesh) {
    if !mesh.is_null() {
        // SAFETY: `head` is the first field of a `MeshBox` from `mesh_out`; with `repr(C)` on
        // MeshBox its address is the box's.
        drop(unsafe { Box::from_raw(mesh.cast::<MeshBox>()) });
    }
}

/// The study `base` (3D study JSON) with a variant laid over it (`{"label", "volume_fraction",
/// "material", "process": "fdm" | "sls" | "cnc3" | "as_is", "build", ...}`): answers
/// `{"ok": study}` or `{"error"}`. Each variant then runs as its own job, in parallel.
///
/// # Safety
/// Both are NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_variant(base: *const c_char, variant: *const c_char) -> *mut c_char {
    // SAFETY: NUL-terminated strings, per the contract above.
    let (base, variant) = unsafe { (text(base), text(variant)) };
    link_reply(guard(Err("the engine stopped on this variant".into()), || {
        let b: Value = serde_json::from_str(base.ok_or("no base study")?).map_err(|e| format!("base study: {e}"))?;
        let v: Value = serde_json::from_str(variant.ok_or("no variant")?).map_err(|e| format!("variant: {e}"))?;
        viaform_core::generative::variant_study(&b, &v)
    }))
}

/// Loads from simulation (RUST-ENGINES G3), the JSON op `loads_from_record`: a phys wrench
/// record (`wrench_history`'s answer, bare or as `{"ok": [...]}`, or a recorder) reduced to a
/// few governing load cases. `request` is `{record, body, interfaces: [{source, region, center?}],
/// placement?: {origin, rotation}, max_cases?, similarity?, min_share?, dynamic_factor?,
/// safety_factor?, gravity?, at?, name?}`; answers `{"ok": {cases, samples, peak_force,
/// peak_moment, dropped}}` or `{"error"}` (`viaform_generative::solid::sim_loads`).
///
/// # Safety
/// `request` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_loads_from_record(request: *const c_char) -> *mut c_char {
    // SAFETY: NUL-terminated string, per the contract above.
    let request = unsafe { text(request) };
    link_reply(guard(Err("the engine stopped reading the record".into()), || {
        let v: Value = serde_json::from_str(request.ok_or("no request")?).map_err(|e| format!("request: {e}"))?;
        viaform_core::viaform_generative::solid::sim_loads::loads_from_record(&v)
    }))
}

/// Frees the job; a study still running is cancelled and ends on its own.
///
/// # Safety
/// `job` is a live job or null, not used after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_generate_free(job: *mut VfGenJob) {
    if !job.is_null() {
        // SAFETY: from `vf_generate_start`, freed once.
        drop(unsafe { Box::from_raw(job) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    /// A 40 x 10 x 16 mm bracket on 1 mm voxels, held on its left face, pulled down at its right
    /// end, with far more iterations than a test waits for.
    const BRACKET: &str = r#"{
        "name": "Bracket3D", "min": [0, 0, 0], "max": [40, 10, 16], "voxel": 1.0,
        "iterations": 400, "volume_fraction": 0.3,
        "supports": [{"region": {"shape": "box", "min": [-0.1, -1, -1], "max": [0.1, 11, 17]}}],
        "cases": [{"name": "tip", "loads": [{"type": "force", "region": {"shape": "box", "min": [39.9, -1, 7], "max": [41, 11, 9]}, "force": [0, 0, -300]}]}]
    }"#;

    fn reply(r: *mut c_char) -> Value {
        // SAFETY: `r` came from `out`.
        let v = serde_json::from_str(unsafe { CStr::from_ptr(r) }.to_str().unwrap()).unwrap();
        // SAFETY: returned by this library.
        unsafe { crate::sc_string_free(r) };
        v
    }

    fn start() -> *mut VfGenJob {
        let spec = CString::new(BRACKET).unwrap();
        // SAFETY: NUL-terminated spec; no error slot.
        let job = unsafe { vf_generate_start(spec.as_ptr(), std::ptr::null_mut()) };
        assert!(!job.is_null());
        job
    }

    /// Waits until the run reaches iteration `n`.
    fn reach(job: *mut VfGenJob, n: u64) {
        let t = std::time::Instant::now();
        loop {
            // SAFETY: live job.
            let p = reply(unsafe { vf_generate_progress(job) });
            if p["iteration"].as_u64().unwrap_or(0) >= n || !p["running"].as_bool().unwrap_or(false) {
                break;
            }
            assert!(t.elapsed().as_secs() < 120, "never reached iteration {n}: {p}");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    /// Stopping mid-run keeps the best design so far: the summary flags it stopped and not
    /// converged with its iteration, the surface comes out, and asking again (cancel, outcome,
    /// summary) after the stop changes nothing.
    #[test]
    fn a_stopped_job_keeps_its_best_design() {
        let job = start();
        reach(job, 20);
        // SAFETY: live job, for every call below.
        unsafe {
            vf_generate_cancel(job);
            vf_generate_cancel(job);
        }
        let s = reply(unsafe { vf_generate_summary(job) });
        let ok = &s["ok"];
        assert!(ok.is_object(), "{s}");
        assert_eq!(ok["candidates"].as_array().map(Vec::len), Some(1), "{s}");
        let c = &ok["candidates"][0];
        assert_eq!(c["converged"], false);
        let at = c["stopped_at"].as_u64().expect("stopped_at");
        assert!(at >= 20 && at < 400, "{c}");
        assert!(c["kept_iteration"].as_u64().is_some_and(|k| k >= 1 && k <= at));
        assert!(c["mass_g"].as_f64().is_some_and(|m| m > 0.0) && c["triangles"].as_u64().is_some_and(|t| t > 0));
        assert!(ok["warnings"].as_array().unwrap().iter().any(|w| w.as_str().is_some_and(|w| w.starts_with("stopped at iteration"))), "{s}");
        let p = reply(unsafe { vf_generate_progress(job) });
        assert_eq!(p["running"], false);
        assert_eq!(p["cancelled"], true);
        // The surface of the kept candidate, best and by index.
        for pick in [-1, 0] {
            let m = unsafe { vf_generate_mesh(job, pick) };
            assert!(!m.is_null());
            // SAFETY: a live mesh from this library.
            let head = unsafe { &*m };
            assert!(head.vertex_count > 0 && head.index_count > 0 && head.index_count % 3 == 0);
            unsafe { vf_generate_mesh_free(m) };
        }
        // Repeated asks after the stop are safe and answer the same.
        unsafe { vf_generate_cancel(job) };
        let again = reply(unsafe { vf_generate_summary(job) });
        assert_eq!(again["ok"]["candidates"][0]["stopped_at"], c["stopped_at"]);
        let full = reply(unsafe { vf_generate_outcome(job) });
        assert_eq!(full["ok"]["stopped"], true);
        unsafe { vf_generate_free(job) };
    }

    /// A stop before any solid formed has nothing to keep: `cancelled`, and no surface.
    #[test]
    fn a_job_stopped_at_once_answers_cancelled() {
        let job = start();
        // SAFETY: live job, for every call below.
        unsafe {
            vf_generate_cancel(job);
            vf_generate_cancel(job);
        }
        let o = reply(unsafe { vf_generate_outcome(job) });
        assert_eq!(o["error"], "cancelled", "{o}");
        assert!(unsafe { vf_generate_mesh(job, -1) }.is_null());
        unsafe {
            vf_generate_cancel(job);
            vf_generate_free(job);
        }
    }
}
