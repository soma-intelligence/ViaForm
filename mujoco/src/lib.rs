//! MuJoCo as a second, selectable physics backend for ViaForm (google-deepmind/mujoco,
//! Apache-2.0, linked as a shared library, never vendored).
//!
//! - [`mjcf`]: phys model to MJCF (pure Rust, always built), also as a standalone `.xml` for
//!   MuJoCo's `simulate` viewer.
//! - [`load`]: `world_new` parameters to the phys world both engines start from.
//! - [`MjPhys`]: phys's JSON facade on MuJoCo, with the `mujoco` cargo feature. Without it
//!   [`MjPhys`] is a stub whose calls answer `engine.unavailable` ("MuJoCo backend not built").
//!
//! The pinned release is [`MUJOCO_VERSION`]; how to fetch and build it: `mujoco/README.md`.

pub mod load;
pub mod mjcf;

#[cfg(feature = "mujoco")]
pub mod facade;
#[cfg(feature = "mujoco")]
pub mod ffi;
#[cfg(feature = "mujoco")]
pub mod sim;
#[cfg(feature = "mujoco")]
pub mod world;

#[cfg(feature = "mujoco")]
pub use facade::MjPhys;
#[cfg(not(feature = "mujoco"))]
mod stub;
#[cfg(not(feature = "mujoco"))]
pub use stub::MjPhys;

use serde_json::{Value, json};
use viaform_phys::PhysError;
use viaform_phys::error::codes;

/// The MuJoCo release this crate is written and tested against (a GitHub release tag of
/// google-deepmind/mujoco).
pub const MUJOCO_VERSION: &str = "3.17.0";

/// Whether this build links MuJoCo (the `mujoco` feature).
pub const BUILT: bool = cfg!(feature = "mujoco");

pub(crate) fn params(msg: impl Into<String>) -> PhysError {
    PhysError::new(codes::PARAMS, msg)
}

/// Runs one op on `mj` and wraps the answer as `{"ok": ...}` or `{"error", "code"}`.
pub fn call(mj: &mut MjPhys, op: &str, p: &Value) -> Value {
    viaform_phys::facade::reply(mj.call(op, p))
}

/// `{xml, path?}` reply of `mjcf_export`; writes the file when `path` is given.
pub(crate) fn write_xml(p: &Value, xml: &str) -> Result<Value, PhysError> {
    match p.get("path").and_then(Value::as_str) {
        Some(path) => {
            std::fs::write(path, xml).map_err(|e| params(format!("path {path}: {e}")))?;
            Ok(json!({"xml": xml, "path": path}))
        }
        None => Ok(json!({"xml": xml})),
    }
}

/// `mjcf_export` without a MuJoCo world: the MJCF of `world_new` parameters (`builtin`,
/// `model`, or `assembly` + `scenario`), or of a phys world given directly.
pub fn mjcf_export(p: &Value, current: Option<&viaform_phys::World>) -> Result<Value, PhysError> {
    let has_model = ["builtin", "model", "assembly"].iter().any(|k| p.get(*k).is_some());
    let ex = match (has_model, current) {
        (true, _) => load::export(p)?,
        (false, Some(w)) => mjcf::export(&w.model, &w.settings)?,
        (false, None) => return Err(PhysError::new(codes::NO_WORLD, "mjcf_export needs a world, or builtin, model, or assembly + scenario")),
    };
    write_xml(p, &ex.xml)
}
