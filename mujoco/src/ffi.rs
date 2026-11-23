//! Hand-written bindings: the MuJoCo entry points viaform-mujoco uses go through the C shim in
//! `csrc/shim.c` (compiled against the pinned release's `mujoco.h`), so no struct layout of
//! `mjModel` or `mjData` is mirrored in Rust. Raw pointers; the safe wrapper is [`crate::sim`].

#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_int, c_longlong};

/// Opaque `mjModel`.
#[repr(C)]
pub struct mjModel {
    _p: [u8; 0],
}

/// Opaque `mjData`.
#[repr(C)]
pub struct mjData {
    _p: [u8; 0],
}

unsafe extern "C" {
    pub fn vfmj_load_xml(xml: *const c_char, err: *mut c_char, err_sz: c_int) -> *mut mjModel;
    pub fn vfmj_version() -> *const c_char;
    pub fn vfmj_copy_model(m: *const mjModel) -> *mut mjModel;
    pub fn vfmj_delete_model(m: *mut mjModel);
    pub fn vfmj_make_data(m: *const mjModel) -> *mut mjData;
    pub fn vfmj_copy_data(m: *const mjModel, d: *const mjData) -> *mut mjData;
    pub fn vfmj_delete_data(d: *mut mjData);

    pub fn vfmj_step(m: *const mjModel, d: *mut mjData);
    pub fn vfmj_forward(m: *const mjModel, d: *mut mjData);
    pub fn vfmj_kinematics(m: *const mjModel, d: *mut mjData);
    pub fn vfmj_rne_post(m: *const mjModel, d: *mut mjData);

    pub fn vfmj_sizes(m: *const mjModel, out: *mut c_longlong);
    pub fn vfmj_id(m: *const mjModel, kind: c_int, name: *const c_char) -> c_int;
    pub fn vfmj_jnt_qposadr(m: *const mjModel, j: c_int) -> c_int;
    pub fn vfmj_jnt_dofadr(m: *const mjModel, j: c_int) -> c_int;
    pub fn vfmj_geom_body(m: *const mjModel, g: c_int) -> c_int;
    pub fn vfmj_body_rootid(m: *const mjModel, b: c_int) -> c_int;
    pub fn vfmj_timestep(m: *const mjModel) -> f64;
    pub fn vfmj_actuator_forcerange(m: *mut mjModel) -> *mut f64;

    pub fn vfmj_time(d: *const mjData) -> f64;
    pub fn vfmj_set_time(d: *mut mjData, t: f64);
    pub fn vfmj_qpos(d: *mut mjData) -> *mut f64;
    pub fn vfmj_qvel(d: *mut mjData) -> *mut f64;
    pub fn vfmj_qacc(d: *mut mjData) -> *mut f64;
    pub fn vfmj_ctrl(d: *mut mjData) -> *mut f64;
    pub fn vfmj_act_force(d: *mut mjData) -> *mut f64;
    pub fn vfmj_act_length(d: *mut mjData) -> *mut f64;
    pub fn vfmj_act_velocity(d: *mut mjData) -> *mut f64;
    pub fn vfmj_xpos(d: *mut mjData) -> *mut f64;
    pub fn vfmj_xquat(d: *mut mjData) -> *mut f64;
    pub fn vfmj_xmat(d: *mut mjData) -> *mut f64;
    pub fn vfmj_xipos(d: *mut mjData) -> *mut f64;
    pub fn vfmj_cvel(d: *mut mjData) -> *mut f64;
    pub fn vfmj_cacc(d: *mut mjData) -> *mut f64;
    pub fn vfmj_cfrc_int(d: *mut mjData) -> *mut f64;
    pub fn vfmj_subtree_com(d: *mut mjData) -> *mut f64;
    pub fn vfmj_xfrc_applied(d: *mut mjData) -> *mut f64;
    pub fn vfmj_niter(d: *const mjData) -> c_int;
    pub fn vfmj_nefc(d: *const mjData) -> c_int;
    pub fn vfmj_bad_state(d: *const mjData) -> c_int;
    pub fn vfmj_ncon(d: *const mjData) -> c_int;
    pub fn vfmj_contact(m: *const mjModel, d: *const mjData, i: c_int, out: *mut f64, bodies: *mut c_int) -> c_int;
}
