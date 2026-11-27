//! Rotor and air drag force elements (the drone models of `sim`, RUST-ENGINES 6.2 "Drone").
//!
//! A rotor makes thrust `k_t w^2` along its axis and a reaction torque `spin k_q w^2` about it;
//! its speed follows the command with a first-order lag (`sim::physics`). Thrust grows near the
//! ground by the Cheeseman and Bennett (1955) factor `1 / (1 - (R / 4z)^2)`. Body drag is linear
//! plus quadratic in body axes against the air (the wind subtracted), scaled by the air density.

use serde::{Deserialize, Serialize};
use viaform_kin::Vec3;

/// Sea-level air density, kg/m^3.
pub const RHO: f64 = 1.225;

/// A rotor on a link.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Rotor {
    pub name: String,
    pub link: usize,
    /// Rotor hub in the link frame, m.
    #[serde(with = "viaform_kin::math::serde_vec3")]
    pub pos: Vec3,
    /// Unit thrust direction in the link frame.
    #[serde(with = "viaform_kin::math::serde_vec3")]
    pub axis: Vec3,
    /// +1: the reaction torque is along +axis.
    pub spin: f64,
    /// Thrust coefficient, N/(rad/s)^2.
    pub k_t: f64,
    /// Torque coefficient, N m/(rad/s)^2.
    pub k_q: f64,
    /// Full-throttle speed on a charged pack, rad/s.
    pub omega_max: f64,
    /// Idle speed (air mode), rad/s.
    pub omega_idle: f64,
    /// Spin-up time constant, s.
    pub tau: f64,
    /// Propeller radius, m (ground effect).
    pub radius: f64,
}

/// Linear plus quadratic drag in body axes, applied at the link origin.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BodyDrag {
    pub link: usize,
    /// N per m/s, body axes.
    pub linear: [f64; 3],
    /// N per (m/s)^2, body axes.
    pub quadratic: [f64; 3],
}

/// The air around the world.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Air {
    /// Air density, kg/m^3.
    pub density: f64,
    /// Uniform wind, m/s, world frame.
    pub wind: [f64; 3],
    /// Ground effect on rotors (the ground plane z = 0).
    pub ground_effect: bool,
    /// Height offset added to the body origin for the ground effect (sim uses 0.02 m: the
    /// rotor discs sit above the body origin).
    pub ground_offset: f64,
}

impl Default for Air {
    fn default() -> Self {
        Air { density: RHO, wind: [0.0; 3], ground_effect: true, ground_offset: 0.02 }
    }
}

/// Cheeseman and Bennett ground effect: thrust gain of a rotor of radius `r` at height `z`.
pub fn ground_effect(r: f64, z: f64) -> f64 {
    1.0 / (1.0 - (r / (4.0 * z.max(1e-3))).powi(2).min(0.5))
}

/// Advances a rotor speed toward its command (clamped to idle and full speed scaled by
/// `omega_scale`, the loaded pack voltage over a full pack's).
pub fn spin_up(r: &Rotor, omega: f64, cmd: f64, omega_scale: f64, dt: f64) -> f64 {
    let target = cmd.max(r.omega_idle).min(r.omega_max * omega_scale);
    omega + (target - omega) * (dt / r.tau).min(1.0)
}

/// The rotors of a sim-style X quad: front right, front left, back left, back right at
/// -45, 45, 135, -135 degrees, spins +1, -1, +1, -1 (sim::physics MOTOR_ANGLES and MOTOR_SPIN).
pub fn quad_x_rotors(link: usize, arm: f64, k_t: f64, k_q: f64, omega_max: f64, omega_idle: f64, tau: f64, radius: f64) -> Vec<Rotor> {
    let angles = [-45.0f64, 45.0, 135.0, -135.0];
    let spins = [1.0, -1.0, 1.0, -1.0];
    (0..4)
        .map(|i| {
            let a = angles[i].to_radians();
            Rotor { name: format!("m{}", i + 1), link, pos: Vec3::new(arm * a.cos(), arm * a.sin(), 0.0), axis: Vec3::z(), spin: spins[i], k_t, k_q, omega_max, omega_idle, tau, radius }
        })
        .collect()
}
