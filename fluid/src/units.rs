//! Physical to lattice units.
//!
//! Three scales fix everything: the voxel edge `dx` (m), the time step `dt` (s) and the fluid
//! density `rho` (kg/m3). The solver runs with `dx = dt = 1` and a reference density of 1, so
//!
//! | Quantity | Lattice to physical |
//! |---|---|
//! | length | `* dx` |
//! | velocity | `* dx / dt` |
//! | kinematic viscosity | `* dx^2 / dt` |
//! | pressure (gauge) | `(rho_lat - 1) * cs^2 * rho * dx^2 / dt^2` |
//! | force | `* rho * dx^4 / dt^2` |
//! | torque | `* rho * dx^5 / dt^2` |
//! | body force density (N/m3) | `* rho * dx / dt^2` |
//!
//! `dt` comes from a target Mach number: the reference velocity maps to `mach * cs` in lattice
//! units (`cs = 1/sqrt(3)`), so `dt = mach * cs * dx / u_ref`. The relaxation time is then
//! `tau = 3 nu_lat + 1/2`.

use serde::{Deserialize, Serialize};

use crate::EngineError;
use crate::lattice::CS2;

/// Unit scales of one run.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Units {
    /// Voxel edge, m.
    pub dx: f64,
    /// Time step, s.
    pub dt: f64,
    /// Fluid density, kg/m3.
    pub rho: f64,
}

/// A fluid by its density and kinematic viscosity.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Fluid {
    /// kg/m3.
    pub density: f64,
    /// Kinematic viscosity, m2/s.
    pub viscosity: f64,
}

impl Fluid {
    /// Dry air at 20 C, 1 atm.
    pub const AIR: Fluid = Fluid {
        density: 1.204,
        viscosity: 1.516e-5,
    };
    /// Water at 20 C.
    pub const WATER: Fluid = Fluid {
        density: 998.2,
        viscosity: 1.004e-6,
    };

    /// `air` or `water`.
    pub fn preset(name: &str) -> Option<Fluid> {
        match name {
            "air" => Some(Self::AIR),
            "water" => Some(Self::WATER),
            _ => None,
        }
    }
}

impl Units {
    /// Scales from explicit `dx`, `dt`, `rho`.
    pub fn new(dx: f64, dt: f64, rho: f64) -> Result<Units, EngineError> {
        if !(dx > 0.0
            && dt > 0.0
            && rho > 0.0
            && dx.is_finite()
            && dt.is_finite()
            && rho.is_finite())
        {
            return Err(EngineError::new(
                "bad_units",
                "dx, dt and rho must be positive and finite",
            ));
        }
        Ok(Units { dx, dt, rho })
    }

    /// Scales so that `u_ref` (m/s) runs at `mach` lattice Mach number on voxels of `dx` m.
    pub fn from_mach(dx: f64, u_ref: f64, rho: f64, mach: f64) -> Result<Units, EngineError> {
        if !(u_ref > 0.0 && u_ref.is_finite()) {
            return Err(EngineError::new(
                "bad_units",
                "reference velocity must be positive",
            ));
        }
        if !(mach > 0.0 && mach <= 0.3) {
            return Err(EngineError::new("bad_units", "mach must be in (0, 0.3]"));
        }
        let u_lat = mach * CS2.sqrt();
        Units::new(dx, u_lat * dx / u_ref, rho)
    }

    /// m/s to lattice.
    pub fn velocity_to_lattice(&self, u: f64) -> f64 {
        u * self.dt / self.dx
    }
    /// Lattice to m/s.
    pub fn velocity_to_physical(&self, u: f64) -> f64 {
        u * self.dx / self.dt
    }
    /// m2/s to lattice.
    pub fn viscosity_to_lattice(&self, nu: f64) -> f64 {
        nu * self.dt / (self.dx * self.dx)
    }
    /// Lattice to m2/s.
    pub fn viscosity_to_physical(&self, nu: f64) -> f64 {
        nu * self.dx * self.dx / self.dt
    }
    /// BGK relaxation time for a physical kinematic viscosity.
    pub fn tau(&self, nu: f64) -> f64 {
        3.0 * self.viscosity_to_lattice(nu) + 0.5
    }
    /// Gauge pressure (Pa) from a lattice density.
    pub fn pressure_to_physical(&self, rho_lat: f64) -> f64 {
        (rho_lat - 1.0) * CS2 * self.rho * self.dx * self.dx / (self.dt * self.dt)
    }
    /// Lattice density from a gauge pressure (Pa).
    pub fn pressure_to_lattice(&self, p: f64) -> f64 {
        1.0 + p * self.dt * self.dt / (CS2 * self.rho * self.dx * self.dx)
    }
    /// Lattice force to N.
    pub fn force_to_physical(&self, f: f64) -> f64 {
        f * self.rho * self.dx.powi(4) / (self.dt * self.dt)
    }
    /// N to lattice force.
    pub fn force_to_lattice(&self, f: f64) -> f64 {
        f * self.dt * self.dt / (self.rho * self.dx.powi(4))
    }
    /// Lattice torque to N m.
    pub fn torque_to_physical(&self, t: f64) -> f64 {
        t * self.rho * self.dx.powi(5) / (self.dt * self.dt)
    }
    /// Body force density N/m3 to lattice.
    pub fn body_force_to_lattice(&self, g: f64) -> f64 {
        g * self.dt * self.dt / (self.rho * self.dx)
    }
    /// Steps to s.
    pub fn time_to_physical(&self, steps: f64) -> f64 {
        steps * self.dt
    }
}
