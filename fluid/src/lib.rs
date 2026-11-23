//! ViaForm's fluid engine: a lattice Boltzmann solver on the same cubic voxels as the generative
//! engine. D3Q19 for the flow (BGK or regularized collision, optional Smagorinsky LES, Guo body
//! force), halfway bounce-back on solid voxels and walls, velocity inlets and pressure outlets,
//! periodic and free-slip faces, a per-voxel partial bounce-back field for grey (topology
//! optimisation) densities, momentum-exchange forces and torques, and a D3Q7 passive temperature.
//!
//! Units: the solver runs in lattice units; [`units::Units`] converts. The front ends drive it
//! with one JSON call ([`call`]), like the `bom` and `library` crates. See `docs/fluid/ENGINE.md`.

// Index loops over the 19 directions and 3 axes read like the equations.
#![allow(clippy::needless_range_loop)]

pub mod cases;
pub mod facade;
pub mod geometry;
pub mod lattice;
pub mod solver;
pub mod thermal;
pub mod units;

use serde::Serialize;

pub use facade::call;
pub use solver::{Collision, Config, Face, Profile, Solver};
pub use thermal::{Thermal, ThermalConfig, ThermalFace};
pub use units::{Fluid, Units};

/// Engine error: a stable machine `code` and a user-facing `message`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EngineError {
    pub code: &'static str,
    pub message: String,
}

impl EngineError {
    pub fn new(code: &'static str, message: impl Into<String>) -> EngineError {
        EngineError {
            code,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for EngineError {}

/// Partial bounce-back fraction `n_s` for a voxel of solid fraction `s` (0 fluid, 1 solid),
/// with the convex interpolation of Borrvall and Petersson (2003) used for LBM topology
/// optimisation by Pingen, Evgrafov and Maute (2007): with the fluid density `g = 1 - s`,
/// `n_s = q (1 - g) / (q + g) = q s / (q + 1 - s)`. `q` large gives a linear map; small `q`
/// keeps grey voxels nearly fluid so the optimiser is pushed toward 0/1 (typical 0.01 to 1).
pub fn porosity_from_design(s: f64, q: f64) -> f64 {
    let s = s.clamp(0.0, 1.0);
    let q = q.max(1e-12);
    (q * s / (q + 1.0 - s)).clamp(0.0, 1.0)
}
