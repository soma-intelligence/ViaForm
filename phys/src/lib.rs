//! Articulated-body physics for ViaForm (RUST-ENGINES section 6): Featherstone dynamics (ABA,
//! RNEA, CRBA) on viaform-kin's model, convex compliant contact with friction (parry3d-f64 for
//! the geometry, Newton on the SAP / MuJoCo primal problem, projected Gauss-Seidel fallback),
//! servo and DC motor actuators, tendons, rotors and drag (the drone port), battery and motor
//! thermal models, deterministic batch stepping, the scenario loader and the wrench history
//! for loads from simulation.
//!
//! SI units, Z up, f64, `Result` with stable error codes. Front ends drive it with one JSON
//! call: [`facade::Phys::call`]. Methods and validation: `phys/README.md`.

pub mod actuator;
pub mod aero;
pub mod batch;
pub mod contact;
pub mod drone;
pub mod dynamics;
pub mod error;
pub mod facade;
pub mod model;
pub mod power;
pub mod record;
pub mod scenario;
pub mod solver;
pub mod spatial;
pub mod tendon;
pub mod world;

pub use error::PhysError;
pub use facade::Phys;
pub use model::{ModelBuilder, PhysModel, ShapeSpec};
pub use record::{Acc6, WrenchHistory};
pub use world::{Settings, World};

/// Runs one op on `phys` and wraps the answer as `{"ok": ...}` or `{"error", "code"}`.
pub fn call(phys: &mut Phys, op: &str, params: &serde_json::Value) -> serde_json::Value {
    facade::reply(phys.call(op, params))
}
