//! Safe owner of one MuJoCo model and its data (feature `mujoco`). Each [`Sim`] owns its own
//! copy of the model, so per-step edits (servo force ranges) never leak between batch envs.

use std::ffi::{CStr, CString, c_char, c_int};

use crate::ffi::*;

/// MuJoCo's version string at run time (the linked library).
pub fn version() -> String {
    // SAFETY: MuJoCo returns a static NUL-terminated string.
    unsafe { CStr::from_ptr(vfmj_version()) }.to_string_lossy().into_owned()
}

/// Sizes of a model.
#[derive(Clone, Copy, Debug, Default)]
pub struct Sizes {
    pub nq: usize,
    pub nv: usize,
    pub nu: usize,
    pub nbody: usize,
    pub njnt: usize,
    pub ngeom: usize,
    pub ntendon: usize,
    pub nout: usize,
}

/// One MuJoCo model plus data.
pub struct Sim {
    m: *mut mjModel,
    d: *mut mjData,
    pub n: Sizes,
}

// SAFETY: a Sim owns its model and data exclusively; MuJoCo keeps no thread-local state for
// them, so moving the pair to another thread is sound.
unsafe impl Send for Sim {}

impl Drop for Sim {
    fn drop(&mut self) {
        // SAFETY: both pointers came from MuJoCo and are owned by this Sim.
        unsafe {
            vfmj_delete_data(self.d);
            vfmj_delete_model(self.m);
        }
    }
}

impl Clone for Sim {
    fn clone(&self) -> Self {
        // SAFETY: valid model and data; MuJoCo allocates the copies.
        unsafe {
            let m = vfmj_copy_model(self.m);
            let d = vfmj_copy_data(m, self.d);
            assert!(!m.is_null() && !d.is_null(), "MuJoCo could not copy the model");
            Sim { m, d, n: self.n }
        }
    }
}

macro_rules! slice {
    ($name:ident, $mut_name:ident, $f:ident, $len:expr) => {
        pub fn $name(&self) -> &[f64] {
            let n = $len(self);
            // SAFETY: MuJoCo allocates this array with that length for the life of the data.
            unsafe { std::slice::from_raw_parts($f(self.d), n) }
        }
        pub fn $mut_name(&mut self) -> &mut [f64] {
            let n = $len(self);
            // SAFETY: as above, and `&mut self` makes the borrow exclusive.
            unsafe { std::slice::from_raw_parts_mut($f(self.d), n) }
        }
    };
}

impl Sim {
    /// Compiles an MJCF string.
    pub fn from_xml(xml: &str) -> Result<Sim, String> {
        let c = CString::new(xml).map_err(|_| "the MJCF has a NUL byte".to_string())?;
        let mut err = vec![0 as c_char; 1024];
        // SAFETY: NUL-terminated input, error buffer of the size given.
        let m = unsafe { vfmj_load_xml(c.as_ptr(), err.as_mut_ptr(), err.len() as c_int) };
        if m.is_null() {
            // SAFETY: MuJoCo writes a NUL-terminated message into the buffer.
            let msg = unsafe { CStr::from_ptr(err.as_ptr()) }.to_string_lossy().into_owned();
            return Err(if msg.is_empty() { "MuJoCo could not compile the model".into() } else { msg });
        }
        // SAFETY: valid model.
        let d = unsafe { vfmj_make_data(m) };
        if d.is_null() {
            // SAFETY: owned model.
            unsafe { vfmj_delete_model(m) };
            return Err("MuJoCo could not allocate the data".into());
        }
        let mut s = [0i64; 8];
        // SAFETY: valid model, 8 slots.
        unsafe { vfmj_sizes(m, s.as_mut_ptr()) };
        let n = Sizes { nq: s[0] as usize, nv: s[1] as usize, nu: s[2] as usize, nbody: s[3] as usize, njnt: s[4] as usize, ngeom: s[5] as usize, ntendon: s[6] as usize, nout: s[7] as usize };
        Ok(Sim { m, d, n })
    }

    /// Id of a named object (kind 0 body, 1 joint, 2 actuator, 3 geom, 4 tendon), -1 if none.
    pub fn id(&self, kind: i32, name: &str) -> i32 {
        let Ok(c) = CString::new(name) else { return -1 };
        // SAFETY: valid model and NUL-terminated name.
        unsafe { vfmj_id(self.m, kind, c.as_ptr()) }
    }

    pub fn jnt_qposadr(&self, j: i32) -> usize {
        // SAFETY: valid model; callers pass ids from `id`.
        unsafe { vfmj_jnt_qposadr(self.m, j) as usize }
    }
    pub fn jnt_dofadr(&self, j: i32) -> usize {
        // SAFETY: as above.
        unsafe { vfmj_jnt_dofadr(self.m, j) as usize }
    }
    pub fn body_rootid(&self, b: usize) -> usize {
        // SAFETY: as above.
        unsafe { vfmj_body_rootid(self.m, b as c_int) as usize }
    }
    pub fn timestep(&self) -> f64 {
        // SAFETY: valid model.
        unsafe { vfmj_timestep(self.m) }
    }
    /// Actuator force ranges `[lo, hi]` per actuator (writable between steps).
    pub fn forcerange_mut(&mut self) -> &mut [f64] {
        // SAFETY: nu x 2 array owned by this Sim's model copy.
        unsafe { std::slice::from_raw_parts_mut(vfmj_actuator_forcerange(self.m), 2 * self.n.nu) }
    }

    pub fn time(&self) -> f64 {
        // SAFETY: valid data.
        unsafe { vfmj_time(self.d) }
    }
    pub fn set_time(&mut self, t: f64) {
        // SAFETY: valid data.
        unsafe { vfmj_set_time(self.d, t) }
    }

    slice!(qpos, qpos_mut, vfmj_qpos, |s: &Sim| s.n.nq);
    slice!(qvel, qvel_mut, vfmj_qvel, |s: &Sim| s.n.nv);
    slice!(qacc, qacc_mut, vfmj_qacc, |s: &Sim| s.n.nv);
    slice!(ctrl, ctrl_mut, vfmj_ctrl, |s: &Sim| s.n.nu);
    slice!(act_force, act_force_mut, vfmj_act_force, |s: &Sim| s.n.nout);
    slice!(act_length, act_length_mut, vfmj_act_length, |s: &Sim| s.n.nout);
    slice!(act_velocity, act_velocity_mut, vfmj_act_velocity, |s: &Sim| s.n.nout);
    slice!(xpos, xpos_mut, vfmj_xpos, |s: &Sim| 3 * s.n.nbody);
    slice!(xquat, xquat_mut, vfmj_xquat, |s: &Sim| 4 * s.n.nbody);
    slice!(xmat, xmat_mut, vfmj_xmat, |s: &Sim| 9 * s.n.nbody);
    slice!(xipos, xipos_mut, vfmj_xipos, |s: &Sim| 3 * s.n.nbody);
    slice!(cvel, cvel_mut, vfmj_cvel, |s: &Sim| 6 * s.n.nbody);
    slice!(cacc, cacc_mut, vfmj_cacc, |s: &Sim| 6 * s.n.nbody);
    slice!(cfrc_int, cfrc_int_mut, vfmj_cfrc_int, |s: &Sim| 6 * s.n.nbody);
    slice!(subtree_com, subtree_com_mut, vfmj_subtree_com, |s: &Sim| 3 * s.n.nbody);
    slice!(xfrc_applied, xfrc_applied_mut, vfmj_xfrc_applied, |s: &Sim| 6 * s.n.nbody);

    pub fn step(&mut self) {
        // SAFETY: valid model and data.
        unsafe { vfmj_step(self.m, self.d) }
    }
    pub fn forward(&mut self) {
        // SAFETY: valid model and data.
        unsafe { vfmj_forward(self.m, self.d) }
    }
    /// Body poses (and com positions) for the present qpos.
    pub fn kinematics(&mut self) {
        // SAFETY: valid model and data.
        unsafe { vfmj_kinematics(self.m, self.d) }
    }
    /// Body accelerations and interaction forces (`cacc`, `cfrc_int`) for the last forward pass.
    pub fn rne_post(&mut self) {
        // SAFETY: valid model and data.
        unsafe { vfmj_rne_post(self.m, self.d) }
    }
    pub fn solver_iterations(&self) -> i32 {
        // SAFETY: valid data.
        unsafe { vfmj_niter(self.d) }
    }
    pub fn nefc(&self) -> i32 {
        // SAFETY: valid data.
        unsafe { vfmj_nefc(self.d) }
    }
    /// Count of MuJoCo's bad-number warnings (qpos, qvel, qacc): the state diverged.
    pub fn bad_state(&self) -> i32 {
        // SAFETY: valid data.
        unsafe { vfmj_bad_state(self.d) }
    }

    /// Active contacts: `(body1, body2, dist, point, normal, force on body 2)`, world frame.
    pub fn contacts(&self) -> Vec<(usize, usize, f64, [f64; 3], [f64; 3], [f64; 3])> {
        // SAFETY: valid data.
        let n = unsafe { vfmj_ncon(self.d) };
        let mut out = Vec::with_capacity(n.max(0) as usize);
        for i in 0..n {
            let mut v = [0.0; 10];
            let mut b = [0 as c_int; 2];
            // SAFETY: i < ncon, buffers of the sizes the shim writes.
            if unsafe { vfmj_contact(self.m, self.d, i, v.as_mut_ptr(), b.as_mut_ptr()) } == 1 {
                out.push((b[0] as usize, b[1] as usize, v[0], [v[1], v[2], v[3]], [v[4], v[5], v[6]], [v[7], v[8], v[9]]));
            }
        }
        out
    }
}
