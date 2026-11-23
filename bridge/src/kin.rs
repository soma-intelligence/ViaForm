//! C ABI for the kinematics engine (viaform-kin): one handle per model and one JSON call, plus
//! a binary entry for dragging the end effector at 60 fps (RUST-ENGINES 9.2, K4).
//!
//! JSON ops are those of `viaform_kin::Kin::call` (`model.load`, `model.info`, `fk`, `jacobian`,
//! `ik`, `ik_hand`, `path.cartesian`, `ik_drag_begin`, `ik_drag_move`, `ik_drag_end`). Replies are
//! `{"ok": result}` or `{"error": message, "code": code}`, freed with `sc_string_free`.

use std::ffi::c_char;

use serde_json::{Value, json};
use viaform_kin::Kin;
use viaform_kin::math::pose_from7;

use super::{guard, out, text};

pub struct VfKin {
    kin: Kin,
}

#[unsafe(no_mangle)]
pub extern "C" fn vf_kin_new() -> *mut VfKin {
    guard(std::ptr::null_mut(), || Box::into_raw(Box::new(VfKin { kin: Kin::new() })))
}

/// # Safety
/// `k` is null or came from `vf_kin_new`, and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_kin_free(k: *mut VfKin) {
    if !k.is_null() {
        // SAFETY: `k` came from `Box::into_raw` in `vf_kin_new`.
        drop(unsafe { Box::from_raw(k) });
    }
}

/// Runs `op` with `params` (JSON, may be null).
///
/// # Safety
/// `k` is a live handle; `op` and `params` are NUL-terminated strings (`params` may be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_kin_call(k: *mut VfKin, op: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: the caller passes a live handle.
    let Some(k) = (unsafe { k.as_mut() }) else { return out(&json!({"error": "no kinematics handle", "code": "params.invalid"})) };
    // SAFETY: NUL-terminated strings, per the contract above.
    let (op, params) = unsafe { (text(op), text(params)) };
    let reply = guard(json!({"error": "the kinematics engine stopped on this call", "code": "engine.panic"}), || {
        let Some(op) = op else { return json!({"error": "no op", "code": "params.invalid"}) };
        let p: Value = match params {
            Some(p) if !p.trim().is_empty() => match serde_json::from_str(p) {
                Ok(v) => v,
                Err(e) => return json!({"error": format!("params: {e}"), "code": "params.invalid"}),
            },
            _ => json!({}),
        };
        viaform_kin::call(&mut k.kin, op, &p)
    });
    out(&reply)
}

/// One drag move without JSON (60 fps path). `pose` is the target of the dragged frame as
/// `[x, y, z, qw, qx, qy, qz]` (m; the quaternion is normalised). Writes up to `n` joint values
/// into `q_out` and up to `n_links` link matrices into `poses_out` (16 floats each, 4x4
/// column-major, world frame). Returns 0 when the target is reached, 1 when the chain is
/// stretching toward an unreachable target (see `vf_kin_drag_error`), -1 on error (no model or
/// no drag begun with `ik_drag_begin`, or a drag of several frames, which takes the JSON op).
///
/// # Safety
/// `k` is a live handle; `pose` points to 7 doubles; `q_out` is null or has room for `n`
/// doubles; `poses_out` is null or has room for `n_links * 16` floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_kin_drag_move(k: *mut VfKin, pose: *const f64, q_out: *mut f64, n: i32, poses_out: *mut f32, n_links: i32) -> i32 {
    // SAFETY: the caller passes a live handle.
    let Some(k) = (unsafe { k.as_mut() }) else { return -1 };
    if pose.is_null() {
        return -1;
    }
    // SAFETY: `pose` points to 7 doubles.
    let p: [f64; 7] = unsafe { std::ptr::read_unaligned(pose as *const [f64; 7]) };
    guard(-1, || {
        if k.kin.drag.as_ref().is_none_or(|d| d.frames.len() != 1) || p.iter().any(|v| !v.is_finite()) {
            return -1;
        }
        if k.kin.drag_move(&[pose_from7(&p)]).is_err() {
            return -1;
        }
        let Some(d) = k.kin.drag.as_ref() else { return -1 };
        if !q_out.is_null() && n > 0 {
            let m = (n as usize).min(d.q.len());
            // SAFETY: `q_out` has room for `n` doubles.
            unsafe { std::ptr::copy_nonoverlapping(d.q.as_ptr(), q_out, m) };
        }
        if !poses_out.is_null() && n_links > 0 {
            let m = (n_links as usize).min(k.kin.drag_poses.len());
            for (i, t) in k.kin.drag_poses.iter().take(m).enumerate() {
                let h = t.to_homogeneous();
                for (c, v) in h.as_slice().iter().enumerate() {
                    // SAFETY: `poses_out` has room for `n_links * 16` floats and `i < n_links`.
                    unsafe { *poses_out.add(i * 16 + c) = *v as f32 };
                }
            }
        }
        match &d.last {
            Some(r) if r.converged => 0,
            Some(_) => 1,
            None => -1,
        }
    })
}

/// Error of the last drag move: `out[0]` position distance left (m), `out[1]` orientation error
/// (rad). Returns 0, or -1 when no move was made.
///
/// # Safety
/// `k` is a live handle; `out` has room for 2 doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_kin_drag_error(k: *const VfKin, out: *mut f64) -> i32 {
    // SAFETY: the caller passes a live handle.
    let Some(k) = (unsafe { k.as_ref() }) else { return -1 };
    let Some(r) = k.kin.drag.as_ref().and_then(|d| d.last.as_ref()) else { return -1 };
    if out.is_null() {
        return -1;
    }
    // SAFETY: `out` has room for 2 doubles.
    unsafe {
        *out = r.pos_err.iter().copied().fold(0.0, f64::max);
        *out.add(1) = r.rot_err.iter().copied().fold(0.0, f64::max);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    fn call(k: *mut VfKin, op: &str, p: &str) -> Value {
        let (op, p) = (CString::new(op).unwrap(), CString::new(p).unwrap());
        // SAFETY: live handle and NUL-terminated strings.
        let r = unsafe { vf_kin_call(k, op.as_ptr(), p.as_ptr()) };
        // SAFETY: `r` came from `out`.
        let v = serde_json::from_str(unsafe { CStr::from_ptr(r) }.to_str().unwrap()).unwrap();
        // SAFETY: returned by this library.
        unsafe { crate::sc_string_free(r) };
        v
    }

    #[test]
    fn json_and_binary_drag() {
        let k = vf_kin_new();
        assert_eq!(call(k, "fk", "{}")["code"], "model.none");
        assert_eq!(call(k, "model.load", r#"{"builtin": "so101_arm"}"#)["ok"]["nq"], 6);
        let q = "[0.2, 0.3, 0.5, 0.2, 0.6, -0.1]";
        let fk = call(k, "fk", &format!(r#"{{"q": {q}}}"#));
        let tip = &fk["ok"]["frames"]["gripper_tip"];
        assert_eq!(call(k, "ik_drag_begin", &format!(r#"{{"q": {q}}}"#))["ok"]["solver"], "analytic");
        let xyz: Vec<f64> = serde_json::from_value(tip["xyz"].clone()).unwrap();
        let wxyz: Vec<f64> = serde_json::from_value(tip["quat_wxyz"].clone()).unwrap();
        let pose = [xyz[0] + 0.005, xyz[1], xyz[2] - 0.003, wxyz[0], wxyz[1], wxyz[2], wxyz[3]];
        let mut qo = [0.0f64; 6];
        let mut poses = [0.0f32; 7 * 16];
        // SAFETY: buffers sized as passed.
        let rc = unsafe { vf_kin_drag_move(k, pose.as_ptr(), qo.as_mut_ptr(), 6, poses.as_mut_ptr(), 7) };
        assert_eq!(rc, 0);
        assert!(qo.iter().any(|v| *v != 0.0));
        assert_eq!(poses[15], 1.0);
        let mut err = [1.0f64; 2];
        // SAFETY: live handle, 2 doubles.
        assert_eq!(unsafe { vf_kin_drag_error(k, err.as_mut_ptr()) }, 0);
        assert!(err[0] < 1e-9);
        // Far away: stretching.
        let far = [1.5, 0.0, 0.2, 1.0, 0.0, 0.0, 0.0];
        assert_eq!(call(k, "ik_drag_begin", &format!(r#"{{"q": {q}, "keep_orientation": false}}"#))["ok"]["solver"], "numerical");
        // SAFETY: buffers sized as passed.
        let rc = unsafe { vf_kin_drag_move(k, far.as_ptr(), qo.as_mut_ptr(), 6, std::ptr::null_mut(), 0) };
        assert_eq!(rc, 1);
        let end = call(k, "ik_drag_end", r#"{"cancel": true}"#);
        assert_eq!(end["ok"]["q"], serde_json::from_str::<Value>(q).unwrap());
        // SAFETY: no drag any more.
        assert_eq!(unsafe { vf_kin_drag_move(k, far.as_ptr(), qo.as_mut_ptr(), 6, std::ptr::null_mut(), 0) }, -1);
        // SAFETY: from vf_kin_new.
        unsafe { vf_kin_free(k) };
    }
}
