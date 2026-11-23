//! Kinematics for ViaForm (RUST-ENGINES section 4): the robot model, forward kinematics,
//! geometric Jacobians, numerical IK with limits, priorities and multi-start, an analytic fast path
//! for 6R arms with a spherical wrist, multi-finger hand IK with linkages and tendons, drag end
//! effector, and Cartesian line and arc paths with time scaling.
//!
//! SI units, Z up, poses as [`Iso3`] in f64, seeded ChaCha8 randomness, `Result` with stable error
//! codes. Front ends drive it with one JSON call: [`facade::Kin::call`]. See `kin/API.md` for the
//! model types other engines build on and `kin/README.md` for methods and validation.

pub mod analytic;
pub mod drag;
pub mod error;
pub mod facade;
pub mod fk;
pub mod hand;
pub mod ik;
pub mod math;
pub mod model;
pub mod models;
pub mod path;

pub use error::KinError;
pub use facade::Kin;
pub use math::{Iso3, Jacobian, UnitQuat, Vec3};
pub use model::*;
pub use nalgebra;

/// Runs one op on `kin` and wraps the answer as `{"ok": ...}` or `{"error", "code"}`.
pub fn call(kin: &mut Kin, op: &str, params: &serde_json::Value) -> serde_json::Value {
    facade::reply(kin.call(op, params))
}
