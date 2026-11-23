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

/// Asks the study to stop at its next iteration.
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

/// Waits for the study, then answers `{"ok": outcome}` or `{"error": message}` (`cancelled`
/// when it was stopped). Can be asked again.
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
/// once), or `{"error"}`.
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
