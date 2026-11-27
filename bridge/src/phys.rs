//! C ABI for the physics engine (viaform-phys): one handle per simulation and one JSON call,
//! plus binary entries that step and read link poses as flat arrays for the 60 fps viewport
//! (RUST-ENGINES 9.2).
//!
//! JSON ops are those of `viaform_phys::Phys::call` (`world_new`, `scenario_load`,
//! `world_step`, `world_state`, `set_controls`, `episode_record`, `wrench_history`,
//! `batch_new`, `batch_step`, `episode_start`, `job_poll`, `job_cancel`, `model_info`).
//! Replies are `{"ok": result}` or `{"error": message, "code": code}`, freed with
//! `sc_string_free`.
//!
//! Engines: `world_new` / `scenario_load` take `"engine": "phys" | "mujoco"` (top level or in
//! the scenario; default phys). The handle then routes every op and the binary entries to that
//! engine, with the same JSON shapes and the same flat poses. MuJoCo runs when the bridge is
//! built with `--features mujoco`; otherwise asking for it answers `engine.unavailable`. One
//! more op, `mjcf_export` `{path?}` (or with `builtin | model | assembly + scenario`), returns
//! the current or given model as MJCF on either engine, with or without the feature.

use std::ffi::c_char;

use serde_json::{Value, json};
use viaform_mujoco::MjPhys;
use viaform_phys::Phys;

use super::{guard, out, text};

/// Which engine the handle's current world runs on.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Engine {
    Phys,
    Mujoco,
}

pub struct VfPhys {
    phys: Phys,
    mj: MjPhys,
    engine: Engine,
}

impl VfPhys {
    fn call(&mut self, op: &str, p: &Value) -> Value {
        match op {
            "world_new" | "scenario_load" => match viaform_mujoco::load::engine_of(p) {
                "mujoco" => {
                    let r = viaform_mujoco::call(&mut self.mj, op, p);
                    if r.get("ok").is_some() {
                        self.engine = Engine::Mujoco;
                    }
                    r
                }
                _ => {
                    let r = viaform_phys::call(&mut self.phys, op, p);
                    if r.get("ok").is_some() {
                        self.engine = Engine::Phys;
                    }
                    r
                }
            },
            "mjcf_export" => match self.engine {
                Engine::Mujoco if !has_model(p) => viaform_mujoco::call(&mut self.mj, op, p),
                _ => viaform_phys::facade::reply(viaform_mujoco::mjcf_export(p, self.phys.world_mut().map(|w| &*w))),
            },
            _ => match self.engine {
                Engine::Phys => viaform_phys::call(&mut self.phys, op, p),
                Engine::Mujoco => viaform_mujoco::call(&mut self.mj, op, p),
            },
        }
    }

    /// Steps the current world: 0, -1 without a world, -2 when the step failed.
    fn step(&mut self, steps: usize) -> i32 {
        let r = match self.engine {
            Engine::Phys => self.phys.step(steps),
            Engine::Mujoco => self.mj.step(steps),
        };
        match r {
            Ok(()) => 0,
            Err(e) if e.code == "world.none" || e.code == "engine.unavailable" => -1,
            Err(_) => -2,
        }
    }

    /// Writes up to `n` link poses; `None` without a world.
    fn poses(&mut self, out: &mut [f64]) -> Option<usize> {
        match self.engine {
            Engine::Phys => self.phys.world_mut().map(|w| w.poses_flat(out)),
            Engine::Mujoco => self.mj.poses_flat(out),
        }
    }

    fn nlinks(&mut self) -> Option<usize> {
        match self.engine {
            Engine::Phys => self.phys.world_mut().map(|w| w.model.nlinks()),
            Engine::Mujoco => self.mj.nlinks(),
        }
    }

    fn set_controls(&mut self, c: &[f64]) -> Option<usize> {
        match self.engine {
            Engine::Phys => {
                let w = self.phys.world_mut()?;
                let k = w.act.len().min(c.len());
                for (a, v) in c.iter().take(k).enumerate() {
                    if v.is_finite() {
                        w.set_control(a, *v);
                    }
                }
                Some(k)
            }
            Engine::Mujoco => self.mj.set_controls_flat(c),
        }
    }

    /// Number of actuators of the current world (to size the controls slice).
    fn nact(&mut self) -> Option<usize> {
        match self.engine {
            Engine::Phys => self.phys.world_mut().map(|w| w.act.len()),
            Engine::Mujoco => self.mj.nact(),
        }
    }
}

fn has_model(p: &Value) -> bool {
    ["builtin", "model", "assembly"].iter().any(|k| p.get(*k).is_some())
}

#[unsafe(no_mangle)]
pub extern "C" fn vf_phys_new() -> *mut VfPhys {
    guard(std::ptr::null_mut(), || Box::into_raw(Box::new(VfPhys { phys: Phys::new(), mj: MjPhys::new(), engine: Engine::Phys })))
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
        h.call(op, &p)
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
        let Some(nl) = h.nlinks() else { return -1 };
        let k = nl.min(n.max(0) as usize);
        if out.is_null() || k == 0 {
            return k as i32;
        }
        let mut buf = vec![0.0; 7 * nl];
        h.poses(&mut buf);
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
    let r = guard(-2, || hh.step(steps.max(0) as usize));
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
        let Some(na) = h.nact() else { return -1 };
        let k = na.min(n.max(0) as usize);
        // SAFETY: `controls` points to `n >= k` doubles.
        let c = unsafe { std::slice::from_raw_parts(controls, k) };
        h.set_controls(c).map_or(-1, |k| k as i32)
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

    #[test]
    fn engine_selection() {
        let h = vf_phys_new();
        // MJCF export works on phys worlds, with or without MuJoCo.
        call(h, "world_new", r#"{"builtin": "so101_arm"}"#);
        let x = call(h, "mjcf_export", "{}");
        assert!(x["ok"]["xml"].as_str().unwrap().contains("<mujoco model="), "{x}");
        let r = call(h, "world_new", r#"{"builtin": "so101_arm", "engine": "mujoco"}"#);
        if cfg!(feature = "mujoco") {
            assert_eq!(r["ok"]["engine"], "mujoco", "{r}");
            let targets = [0.3, -0.2, 0.4, 0.0, 0.1, 0.0];
            // SAFETY: live handle, 6 doubles.
            assert_eq!(unsafe { vf_phys_set_controls(h, targets.as_ptr(), 6) }, 6);
            let mut poses = vec![0.0; 7 * 8];
            // SAFETY: live handle, room for 8 links.
            assert_eq!(unsafe { vf_phys_step(h, 500, poses.as_mut_ptr(), 8) }, 7);
            assert_eq!(&poses[0..7], &[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]);
            let st = call(h, "world_state", "{}");
            assert!((st["ok"]["q"][0].as_f64().unwrap() - 0.3).abs() < 0.02, "{st}");
        } else {
            assert_eq!(r["code"], "engine.unavailable", "{r}");
            // The phys world stays current.
            let st = call(h, "world_state", "{}");
            assert!(st.get("ok").is_some());
        }
        // Back to phys on the same handle.
        let r = call(h, "world_new", r#"{"builtin": "so101_arm", "engine": "phys"}"#);
        assert!(r.get("ok").is_some());
        assert!(call(h, "model_info", "{}")["ok"].get("engine").is_none());
        // SAFETY: handle from vf_phys_new, not used afterwards.
        unsafe { vf_phys_free(h) };
    }
}
