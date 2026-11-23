//! C ABI for the physics engine (viaform-phys): one handle per simulation and one JSON call,
//! plus binary entries that step and read link poses as flat arrays for the 60 fps viewport
//! (RUST-ENGINES 9.2).
//!
//! JSON ops are those of `viaform_phys::Phys::call` (`world_new`, `scenario_load`,
//! `world_step`, `world_state`, `set_controls`, `episode_record`, `wrench_history`,
//! `batch_new`, `batch_step`, `episode_start`, `job_poll`, `job_cancel`, `model_info`).
//! Replies are `{"ok": result}` or `{"error": message, "code": code}`, freed with
//! `sc_string_free`.

use std::ffi::c_char;

use serde_json::{Value, json};
use viaform_phys::Phys;

use super::{guard, out, text};

pub struct VfPhys {
    phys: Phys,
}

#[unsafe(no_mangle)]
pub extern "C" fn vf_phys_new() -> *mut VfPhys {
    guard(std::ptr::null_mut(), || Box::into_raw(Box::new(VfPhys { phys: Phys::new() })))
}

/// # Safety
/// `h` is null or came from `vf_phys_new`, and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_phys_free(h: *mut VfPhys) {
    if !h.is_null() {
        // SAFETY: `h` came from `Box::into_raw` in `vf_phys_new`.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// Runs `op` with `params` (JSON, may be null).
///
/// # Safety
/// `h` is a live handle; `op` and `params` are NUL-terminated strings (`params` may be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_phys_call(h: *mut VfPhys, op: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: the caller passes a live handle.
    let Some(h) = (unsafe { h.as_mut() }) else { return out(&json!({"error": "no physics handle", "code": "params.invalid"})) };
    // SAFETY: NUL-terminated strings, per the contract above.
    let (op, params) = unsafe { (text(op), text(params)) };
    let reply = guard(json!({"error": "the physics engine stopped on this call", "code": "engine.panic"}), || {
        let Some(op) = op else { return json!({"error": "no op", "code": "params.invalid"}) };
        let p: Value = match params {
            Some(p) if !p.trim().is_empty() => match serde_json::from_str(p) {
                Ok(v) => v,
                Err(e) => return json!({"error": format!("params: {e}"), "code": "params.invalid"}),
            },
            _ => json!({}),
        };
        viaform_phys::call(&mut h.phys, op, &p)
    });
    out(&reply)
}

/// Writes the link poses of the current world into `out` as `[x, y, z, qw, qx, qy, qz]` per
/// link (m, world frame; link 0 is the world). Returns the number of links written (at most
/// `n`), or -1 when there is no world.
///
/// # Safety
/// `h` is a live handle; `out` is null or has room for `n * 7` doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_phys_state_poses(h: *mut VfPhys, out: *mut f64, n: i32) -> i32 {
    // SAFETY: the caller passes a live handle.
    let Some(h) = (unsafe { h.as_mut() }) else { return -1 };
    guard(-1, || {
        let Some(w) = h.phys.world_mut() else { return -1 };
        let nl = w.model.nlinks();
        let k = nl.min(n.max(0) as usize);
        if out.is_null() || k == 0 {
            return k as i32;
        }
        let mut buf = vec![0.0; 7 * nl];
        w.poses_flat(&mut buf);
        // SAFETY: `out` has room for `n * 7 >= k * 7` doubles.
        unsafe { std::ptr::copy_nonoverlapping(buf.as_ptr(), out, 7 * k) };
        k as i32
    })
}

/// Advances the current world `steps` steps (a scenario follows its drives), then writes the
/// link poses as `vf_phys_state_poses` does. Returns the number of links written, -1 when there
/// is no world, -2 when the step failed (the state diverged: call `world_state` or rebuild).
///
/// # Safety
/// `h` is a live handle; `out` is null or has room for `n * 7` doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_phys_step(h: *mut VfPhys, steps: i32, out: *mut f64, n: i32) -> i32 {
    // SAFETY: the caller passes a live handle.
    let Some(hh) = (unsafe { h.as_mut() }) else { return -1 };
    let r = guard(-2, || match hh.phys.step(steps.max(0) as usize) {
        Ok(()) => 0,
        Err(e) if e.code == "world.none" => -1,
        Err(_) => -2,
    });
    if r != 0 {
        return r;
    }
    // SAFETY: same contract as this function.
    unsafe { vf_phys_state_poses(h, out, n) }
}

/// Sets `n` actuator controls (actuator order; rad, m, V or N m by actuator kind) without
/// JSON. Returns the number set, or -1 when there is no world.
///
/// # Safety
/// `h` is a live handle; `controls` points to `n` doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_phys_set_controls(h: *mut VfPhys, controls: *const f64, n: i32) -> i32 {
    // SAFETY: the caller passes a live handle.
    let Some(h) = (unsafe { h.as_mut() }) else { return -1 };
    if controls.is_null() {
        return -1;
    }
    guard(-1, || {
        let Some(w) = h.phys.world_mut() else { return -1 };
        let k = w.act.len().min(n.max(0) as usize);
        // SAFETY: `controls` points to `n >= k` doubles.
        let c = unsafe { std::slice::from_raw_parts(controls, k) };
        for (a, v) in c.iter().enumerate() {
            if v.is_finite() {
                w.set_control(a, *v);
            }
        }
        k as i32
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    fn call(h: *mut VfPhys, op: &str, p: &str) -> Value {
        let (op, p) = (CString::new(op).unwrap(), CString::new(p).unwrap());
        // SAFETY: live handle and NUL-terminated strings.
        let r = unsafe { vf_phys_call(h, op.as_ptr(), p.as_ptr()) };
        // SAFETY: `r` came from `out`.
        let v = serde_json::from_str(unsafe { CStr::from_ptr(r) }.to_str().unwrap()).unwrap();
        // SAFETY: returned by this library.
        unsafe { crate::sc_string_free(r) };
        v
    }

    #[test]
    fn json_and_binary_step() {
        let h = vf_phys_new();
        assert_eq!(call(h, "world_state", "{}")["code"], "world.none");
        let mut poses = vec![0.0; 7 * 8];
        // SAFETY: live handle, buffer of 8 links.
        assert_eq!(unsafe { vf_phys_step(h, 1, poses.as_mut_ptr(), 8) }, -1);
        let info = call(h, "world_new", r#"{"builtin": "so101_arm"}"#);
        let nl = info["ok"]["links"].as_array().unwrap().len();
        assert_eq!(nl, 7);
        let targets = [0.3, -0.2, 0.4, 0.0, 0.1, 0.0];
        // SAFETY: live handle, 6 doubles.
        assert_eq!(unsafe { vf_phys_set_controls(h, targets.as_ptr(), 6) }, 6);
        // SAFETY: live handle, room for 8 links.
        let k = unsafe { vf_phys_step(h, 500, poses.as_mut_ptr(), 8) };
        assert_eq!(k, 7);
        // Unit quaternions, world link at the origin.
        assert_eq!(&poses[0..7], &[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]);
        for l in 0..7 {
            let q = &poses[7 * l + 3..7 * l + 7];
            assert!((q.iter().map(|x| x * x).sum::<f64>() - 1.0).abs() < 1e-9);
        }
        let st = call(h, "world_state", "{}");
        assert!((st["ok"]["q"][0].as_f64().unwrap() - 0.3).abs() < 0.02);
        // SAFETY: handle from vf_phys_new, not used afterwards.
        unsafe { vf_phys_free(h) };
    }
}
