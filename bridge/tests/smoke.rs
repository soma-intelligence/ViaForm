//! Smoke tests for the C ABI: every handle the Swift apps open (`sc_*`, `pcb_*`, `vf_*`) is made
//! and freed through the same functions, a cheap call answers JSON where one exists, and the free
//! functions take null. Catches a missing symbol, a panic that crosses the boundary or a crash on
//! free, on every platform CI runs.
//!
//! The root functions are reached by their Rust paths. The ones in the bridge's private modules
//! (`vf_bom_*`, `vf_flow_*`, ...) are declared below by their C names, as the header does, and
//! resolve against the same library.

use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr::null_mut;

use serde_json::Value;
use viaform_ffi::{
    pcb_checks, pcb_commands, pcb_execute, pcb_inspect, pcb_session_free, pcb_session_new, sc_commands, sc_execute, sc_home_camera,
    sc_scene_build, sc_scene_free, sc_scene_mesh_count, sc_session_free, sc_session_new, sc_string_free,
};

unsafe extern "C" {
    fn vf_bom_new() -> *mut c_void;
    fn vf_bom_free(b: *mut c_void);
    fn vf_bom_call(b: *mut c_void, sc: *mut c_void, pcb: *mut c_void, method: *const c_char, params: *const c_char) -> *mut c_char;

    fn vf_flow_new() -> *mut c_void;
    fn vf_flow_new_sample() -> *mut c_void;
    fn vf_flow_free(flow: *mut c_void);
    fn vf_flow_state(flow: *const c_void) -> *mut c_char;
    fn vf_flow_commands() -> *mut c_char;

    fn vf_library_open(dir: *const c_char) -> *mut c_void;
    fn vf_library_free(lib: *mut c_void);
    fn vf_library_call(lib: *mut c_void, method: *const c_char, params: *const c_char) -> *mut c_char;

    fn vf_sim_catalog() -> *mut c_char;
    fn vf_sim_start(options: *const c_char) -> *mut c_void;
    fn vf_sim_world(sim: *const c_void) -> *mut c_char;
    fn vf_sim_free(sim: *mut c_void);

    fn vf_train_start(options: *const c_char) -> *mut c_void;
    fn vf_train_progress(job: *const c_void) -> *mut c_char;
    fn vf_train_cancel(job: *const c_void);
    fn vf_train_free(job: *mut c_void);

    fn vf_generate_start(spec: *const c_char, error: *mut *mut c_char) -> *mut c_void;
    fn vf_generate_progress(job: *const c_void) -> *mut c_char;
    fn vf_generate_cancel(job: *const c_void);
    fn vf_generate_free(job: *mut c_void);
    fn vf_generate_mesh_free(mesh: *mut c_void);
    fn vf_generate_mesh_maps(
        positions: *const f32,
        vertex_count: u64,
        indices: *const u32,
        index_count: u64,
        request: *const c_char,
        overhang_out: *mut f32,
        wall_out: *mut f32,
        access_out: *mut f32,
    ) -> *mut c_char;
}

fn c(s: &str) -> CString {
    CString::new(s).expect("no NUL in test strings")
}

/// Reads and frees a string the bridge returned, as the Swift side does.
fn take(p: *mut c_char) -> Value {
    assert!(!p.is_null(), "the bridge answered null");
    // SAFETY: a NUL-terminated string from the bridge, freed once below.
    let text = unsafe { CStr::from_ptr(p) }.to_str().expect("UTF-8").to_owned();
    // SAFETY: from the bridge, not used after.
    unsafe { sc_string_free(p) };
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("not JSON ({e}): {text}"))
}

fn is_error(v: &Value) -> bool {
    v.get("error").is_some()
}

#[test]
fn design_session_new_execute_scene_free() {
    let s = sc_session_new();
    assert!(!s.is_null());
    // SAFETY: a live session and NUL-terminated strings; every handle is freed once.
    unsafe {
        let reply = take(sc_execute(s, c("no.such.command").as_ptr(), null_mut()));
        assert!(is_error(&reply), "{reply}");
        // An empty design may have no home camera: null is a valid answer, a crash is not.
        let _ = take(sc_home_camera(s));
        let scene = sc_scene_build(s, null_mut());
        if !scene.is_null() {
            let _ = sc_scene_mesh_count(scene);
            sc_scene_free(scene);
        }
        sc_session_free(s);
        sc_session_free(null_mut());
        sc_scene_free(null_mut());
    }
    assert!(take(sc_commands()).is_array());
}

#[test]
fn pcb_session_new_free_empty_and_sample() {
    for sample in [false, true] {
        let s = pcb_session_new(sample);
        assert!(!s.is_null());
        // SAFETY: a live session, freed once.
        unsafe {
            assert!(!take(pcb_inspect(s)).is_null());
            assert!(!take(pcb_checks(s)).is_null());
            let reply = take(pcb_execute(s, c("no.such.command").as_ptr(), null_mut()));
            assert!(is_error(&reply), "{reply}");
            pcb_session_free(s);
        }
    }
    // SAFETY: null is allowed.
    unsafe { pcb_session_free(null_mut()) };
    assert!(take(pcb_commands()).is_array());
}

#[test]
fn bom_new_call_free() {
    // SAFETY: handles from the bridge, freed once; null sessions are allowed by vf_bom_call.
    unsafe {
        let b = vf_bom_new();
        assert!(!b.is_null());
        let reply = take(vf_bom_call(b, null_mut(), null_mut(), c("state").as_ptr(), null_mut()));
        assert!(reply.get("ok").is_some() || is_error(&reply), "{reply}");
        vf_bom_free(b);
        vf_bom_free(null_mut());
    }
}

#[test]
fn flow_new_state_free() {
    // SAFETY: handles from the bridge, freed once.
    unsafe {
        for flow in [vf_flow_new(), vf_flow_new_sample()] {
            assert!(!flow.is_null());
            assert!(take(vf_flow_state(flow)).is_object());
            vf_flow_free(flow);
        }
        vf_flow_free(null_mut());
        assert!(take(vf_flow_commands()).is_array());
    }
}

#[test]
fn library_open_call_free() {
    let dir = std::env::temp_dir().join(format!("viaform-ffi-smoke-{}", std::process::id()));
    let path = c(dir.to_str().expect("UTF-8 temp dir"));
    // SAFETY: handles from the bridge, freed once.
    unsafe {
        let lib = vf_library_open(path.as_ptr());
        assert!(!lib.is_null(), "library did not open in {}", dir.display());
        let reply = take(vf_library_call(lib, c("no_such_method").as_ptr(), null_mut()));
        assert!(is_error(&reply), "{reply}");
        vf_library_free(lib);
        vf_library_free(null_mut());
        assert!(vf_library_open(null_mut()).is_null());
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn sim_start_world_free() {
    // SAFETY: handles from the bridge, freed once.
    unsafe {
        assert!(take(vf_sim_catalog()).is_object());
        let sim = vf_sim_start(c("{}").as_ptr());
        assert!(!sim.is_null(), "default flight refused");
        assert!(take(vf_sim_world(sim)).is_object());
        vf_sim_free(sim);
        vf_sim_free(null_mut());
    }
}

#[test]
fn train_start_cancel_free() {
    // SAFETY: handles from the bridge, freed once.
    unsafe {
        assert!(vf_train_start(c(r#"{"iterations": 0}"#).as_ptr()).is_null(), "bad options accepted");
        let job = vf_train_start(c(r#"{"iterations": 1, "population": 2, "episodes": 1}"#).as_ptr());
        assert!(!job.is_null(), "small training refused");
        assert!(take(vf_train_progress(job)).is_object());
        vf_train_cancel(job);
        vf_train_free(job);
        vf_train_free(null_mut());
    }
}

#[test]
fn generate_start_cancel_free() {
    let spec = r#"{
        "name": "Smoke", "min": [0, 0, 0], "max": [8, 4, 4], "voxel": 1.0, "iterations": 2,
        "volume_fraction": 0.5,
        "supports": [{"region": {"shape": "box", "min": [-0.1, -1, -1], "max": [0.1, 5, 5]}}],
        "cases": [{"name": "tip", "loads": [{"type": "force", "region": {"shape": "box", "min": [7.9, -1, 1], "max": [9, 5, 3]}, "force": [0, 0, -10]}]}]
    }"#;
    // SAFETY: handles from the bridge, freed once; `error` points to writable storage.
    unsafe {
        let mut error: *mut c_char = null_mut();
        assert!(vf_generate_start(c("not json").as_ptr(), &mut error).is_null());
        assert!(is_error(&take(error)));

        let mut error: *mut c_char = null_mut();
        let job = vf_generate_start(c(spec).as_ptr(), &mut error);
        if job.is_null() {
            panic!("study refused: {}", take(error));
        }
        assert!(take(vf_generate_progress(job)).is_object());
        vf_generate_cancel(job);
        vf_generate_free(job);
        vf_generate_free(null_mut());
        vf_generate_mesh_free(null_mut());
    }
}

/// The mesh maps call resolves by its C name, takes an empty surface and null outputs, and
/// answers JSON.
#[test]
fn generate_mesh_maps_takes_empty_input() {
    // SAFETY: null arrays with zero counts, null request, null outputs: all allowed.
    let v = take(unsafe { vf_generate_mesh_maps(std::ptr::null(), 0, std::ptr::null(), 0, std::ptr::null(), null_mut(), null_mut(), null_mut()) });
    assert_eq!(v["ok"]["vertices"], 0, "{v}");
    // A triangle with all three maps asked for.
    let p = [0.0f32, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0];
    let i = [0u32, 1, 2];
    let (mut a, mut b, mut cc) = ([0.0f32; 3], [0.0f32; 3], [0.0f32; 3]);
    let req = c(r#"{"process": "fdm"}"#);
    // SAFETY: three vertices and three floats in each output.
    let v = take(unsafe { vf_generate_mesh_maps(p.as_ptr(), 3, i.as_ptr(), 3, req.as_ptr(), a.as_mut_ptr(), b.as_mut_ptr(), cc.as_mut_ptr()) });
    assert_eq!(v["ok"]["triangles"], 1, "{v}");
    assert!(cc.iter().all(|x| x.is_nan()), "no tool map for printing");
}
