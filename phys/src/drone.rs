//! The drone in phys (RUST-ENGINES 6.2 "Drone"): the airframe is a free body, the four rotors
//! and the body drag are force elements, and the powertrain (battery, motors, ESCs) caps the
//! rotor speed by the loaded pack voltage. The parameters are `sim`'s `QuadParams` (same JSON
//! field names), so a quad tuned in the Flight screen flies the same here; `tests/ph5_drone.rs`
//! holds the two simulators to the same trajectories.
//!
//! Conventions match `sim::physics`: world x east, y north, z up; body x forward, y left, z up;
//! motors front right, front left, back left, back right at -45, 45, 135, -135 degrees, spins
//! +1, -1, +1, -1. The airframe link's origin is its centre of mass.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use viaform_kin::math::pose_xyz_rpy;
use viaform_kin::{Iso3, Vec3};

use crate::aero::{BodyDrag, quad_x_rotors};
use crate::error::PhysError;
use crate::model::{ModelBuilder, PhysModel, ShapeSpec};
use crate::power::{CellParams, EscParams, MotorThermalParams, Pack, Powertrain};
use crate::world::{Settings, World};

/// Quad parameters (sim's `QuadParams`, camelCase JSON). Defaults: sim's 3-inch quad
/// (`flight::quad3_default`).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct QuadSpec {
    pub mass: f64,
    pub inertia: [f64; 3],
    pub arm: f64,
    pub k_t: f64,
    pub k_q: f64,
    pub omega_max: f64,
    pub omega_idle: f64,
    pub motor_tau: f64,
    pub drag_linear: [f64; 3],
    pub drag_quad: [f64; 3],
    pub prop_radius: f64,
    pub body_radius: f64,
    pub battery_ah: f64,
    pub battery_cells: f64,
    pub max_thrust: f64,
    pub peak_current: f64,
}

impl Default for QuadSpec {
    fn default() -> Self {
        let omega_max = 4000.0;
        let max_thrust = 0.18 * 9.81;
        let k_t = max_thrust / (omega_max * omega_max);
        QuadSpec {
            mass: 0.175,
            inertia: [1.9e-4, 2.1e-4, 3.5e-4],
            arm: 0.0602,
            k_t,
            k_q: 0.009 * k_t,
            omega_max,
            omega_idle: 0.12 * omega_max,
            motor_tau: 0.025,
            drag_linear: [0.045, 0.045, 0.06],
            drag_quad: [0.006, 0.006, 0.012],
            prop_radius: 0.0381,
            body_radius: 0.1,
            battery_ah: 0.65,
            battery_cells: 3.0,
            max_thrust,
            peak_current: 9.3,
        }
    }
}

/// The drone's state in sim's terms.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct DroneState {
    /// Position, m (world).
    pub p: [f64; 3],
    /// Velocity, m/s (world).
    pub v: [f64; 3],
    /// Attitude quaternion `[w, x, y, z]`, body to world.
    pub q: [f64; 4],
    /// Body rates, rad/s.
    pub w: [f64; 3],
    /// Rotor speeds, rad/s.
    pub omega: [f64; 4],
}

/// The quad's model: a free body named `airframe` (link 1) with its rotors and drag. With
/// `ground`, a ground plane and a flat box for the airframe's collision (the arms' span by
/// 30 mm), so it can sit on the ground and land.
pub fn quad_model(spec: &QuadSpec, ground: bool) -> Result<Arc<PhysModel>, PhysError> {
    if !(spec.mass > 0.0 && spec.inertia.iter().all(|x| *x > 0.0) && spec.arm > 0.0 && spec.k_t > 0.0 && spec.motor_tau > 0.0) {
        return Err(crate::error::invalid("quad: mass, inertia, arm, k_t and motor_tau must be positive"));
    }
    let mut b = ModelBuilder::empty();
    let i = spec.inertia;
    let link = b.free_body("airframe", spec.mass, Vec3::zeros(), [i[0], i[1], i[2], 0.0, 0.0, 0.0], Iso3::identity());
    b.rotors = quad_x_rotors(link, spec.arm, spec.k_t, spec.k_q, spec.omega_max, spec.omega_idle, spec.motor_tau, spec.prop_radius);
    b.drags = vec![BodyDrag { link, linear: spec.drag_linear, quadratic: spec.drag_quad }];
    if ground {
        b.ground(0.8);
        let span = 2.0 * spec.arm * std::f64::consts::FRAC_1_SQRT_2 + 0.06;
        b.geom(link, "airframe", ShapeSpec::Box { size: [span, span, 0.03] }, pose_xyz_rpy([0.0; 3], [0.0; 3]), 0.8);
    }
    b.build()
}

/// The quad's powertrain: a LiPo pack of `battery_cells` in series at `ambient_c`, default
/// motor and ESC thermal parameters, sim's current law.
pub fn powertrain(spec: &QuadSpec, ambient_c: f64) -> Powertrain {
    let cell = CellParams { capacity_ah: spec.battery_ah, ..CellParams::default() };
    let pack = Pack::new(cell, spec.battery_cells, 1.0, ambient_c);
    Powertrain::new(pack, MotorThermalParams::default(), EscParams::default(), 4, spec.max_thrust, spec.peak_current)
}

/// A world with the quad at `state` (sim's step: 2 ms, gravity 9.81, sea-level air, ground
/// effect on).
pub fn quad_world(spec: &QuadSpec, state: &DroneState, ground: bool) -> Result<World, PhysError> {
    let mut w = World::new(quad_model(spec, ground)?, Settings { dt: 0.002, ..Settings::default() });
    set_state(&mut w, state)?;
    Ok(w)
}

/// Writes a [`DroneState`] into the world (airframe = link 1).
pub fn set_state(w: &mut World, s: &DroneState) -> Result<(), PhysError> {
    let n = (s.q.iter().map(|x| x * x).sum::<f64>()).sqrt();
    if !(n > 1e-9) {
        return Err(crate::error::params("drone state: zero quaternion"));
    }
    let q = [s.q[0] / n, s.q[1] / n, s.q[2] / n, s.q[3] / n];
    w.q[0..3].copy_from_slice(&s.p);
    w.q[3..7].copy_from_slice(&q);
    let rot = quat(&q);
    let vb = rot.inverse() * Vec3::from(s.v);
    w.v[0..3].copy_from_slice(vb.as_slice());
    w.v[3..6].copy_from_slice(&s.w);
    for k in 0..w.rotor_omega.len().min(4) {
        w.rotor_omega[k] = s.omega[k];
    }
    let _ = w.poses();
    Ok(())
}

/// Reads the airframe's state.
pub fn state(w: &World) -> DroneState {
    let q = [w.q[3], w.q[4], w.q[5], w.q[6]];
    let rot = quat(&q);
    let v = rot * Vec3::new(w.v[0], w.v[1], w.v[2]);
    let mut omega = [0.0; 4];
    for k in 0..w.rotor_omega.len().min(4) {
        omega[k] = w.rotor_omega[k];
    }
    DroneState { p: [w.q[0], w.q[1], w.q[2]], v: [v.x, v.y, v.z], q, w: [w.v[3], w.v[4], w.v[5]], omega }
}

fn quat(q: &[f64; 4]) -> nalgebra::UnitQuaternion<f64> {
    nalgebra::UnitQuaternion::from_quaternion(nalgebra::Quaternion::new(q[0], q[1], q[2], q[3]))
}

/// Motor speed commands, rad/s.
pub fn set_commands(w: &mut World, cmd: &[f64]) {
    for (k, c) in cmd.iter().enumerate().take(w.rotor_cmd.len()) {
        w.rotor_cmd[k] = *c;
    }
}
