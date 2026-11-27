//! The backend without the `mujoco` feature: same API as the real facade, every call answers
//! `engine.unavailable`, except `mjcf_export`, which needs no MuJoCo library.

use serde_json::Value;
use viaform_phys::PhysError;
use viaform_phys::error::codes;

/// Stub of the MuJoCo facade.
#[derive(Default)]
pub struct MjPhys;

fn unavailable() -> PhysError {
    PhysError::new(codes::ENGINE_UNAVAILABLE, format!("MuJoCo backend not built: rebuild with --features mujoco (MuJoCo {}, see mujoco/README.md)", crate::MUJOCO_VERSION))
}

impl MjPhys {
    pub fn new() -> Self {
        MjPhys
    }

    pub fn call(&mut self, op: &str, p: &Value) -> Result<Value, PhysError> {
        match op {
            "mjcf_export" => crate::mjcf_export(p, None),
            _ => Err(unavailable()),
        }
    }

    pub fn step(&mut self, _steps: usize) -> Result<(), PhysError> {
        Err(unavailable())
    }

    pub fn poses_flat(&mut self, _out: &mut [f64]) -> Option<usize> {
        None
    }

    pub fn nlinks(&self) -> Option<usize> {
        None
    }

    pub fn nact(&self) -> Option<usize> {
        None
    }

    pub fn set_controls_flat(&mut self, _c: &[f64]) -> Option<usize> {
        None
    }
}
