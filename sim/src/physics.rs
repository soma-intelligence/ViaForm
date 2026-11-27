//! Rigid-body flight model of an X quadcopter: four motors with first-order spin-up, thrust and
//! drag torque from the propeller speed, body and rotor drag against the air (not the ground),
//! gravity, ground contact, and a wind field with a mean, turbulence and gusts. World frame is
//! x east, y north, z up; body frame is x forward, y left, z up. SI units throughout.

use serde::{Deserialize, Serialize};

use crate::math::*;
use crate::realism::Aero;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuadParams {
    pub mass: f64,      // kg, all-up
    pub inertia: V3,    // kg·m², principal, body axes
    pub arm: f64,       // m, centre to motor axis
    pub k_t: f64,       // N per (rad/s)², thrust = kT ω²
    pub k_q: f64,       // N·m per (rad/s)², drag torque = kQ ω²
    pub omega_max: f64, // rad/s at full throttle on a charged pack
    pub omega_idle: f64, // rad/s, motors never stop in the air (air mode)
    pub motor_tau: f64, // s, first-order spin-up time constant
    pub drag_linear: V3, // N per m/s in body axes (rotor induced drag dominates horizontally)
    pub drag_quad: V3,  // N per (m/s)² in body axes (frame and pack)
    pub prop_radius: f64, // m, for collision and drawing
    pub body_radius: f64, // m, collision sphere of the airframe with propellers
    /// The pack: capacity (Ah) and cells in series.
    #[serde(default = "default_battery_ah")]
    pub battery_ah: f64,
    #[serde(default = "default_battery_cells")]
    pub battery_cells: f64,
    /// One motor at full throttle: thrust (N) and current (A) on the pack.
    #[serde(default = "default_max_thrust")]
    pub max_thrust: f64,
    #[serde(default = "default_peak_current")]
    pub peak_current: f64,
}

fn default_battery_ah() -> f64 {
    0.65
}
fn default_battery_cells() -> f64 {
    3.0
}
fn default_max_thrust() -> f64 {
    crate::parts::MOTOR_THRUST_3S_N
}
/// The current model's full-throttle draw (weather.rs `motor_current`): 0.3 A idle plus 9 A.
fn default_peak_current() -> f64 {
    9.3
}

/// Motor i at body angle MOTOR_ANGLES[i] (deg from forward, counter-clockwise), spin sign
/// MOTOR_SPIN[i] (+1: reaction torque along +z). Front right, front left, back left, back right.
pub const MOTOR_ANGLES: [f64; 4] = [-45.0, 45.0, 135.0, -135.0];
pub const MOTOR_SPIN: [f64; 4] = [1.0, -1.0, 1.0, -1.0];

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuadState {
    pub p: V3,
    pub v: V3,
    pub q: Q,
    pub w: V3, // body rates
    pub omega: [f64; 4],
    pub t: f64,
    pub crashed: bool,
    /// Last specific force in body axes (what an accelerometer measures).
    pub acc_body: V3,
}

impl QuadState {
    pub fn new(p: V3, q: Q) -> Self {
        QuadState { p, v: [0.0; 3], q, w: [0.0; 3], omega: [0.0; 4], t: 0.0, crashed: false, acc_body: [0.0, 0.0, 9.81] }
    }
}

pub const G: f64 = 9.81;
pub const RHO: f64 = 1.225;

/// Thrust of each motor in N at its current speed.
pub fn thrusts(p: &QuadParams, s: &QuadState) -> [f64; 4] {
    s.omega.map(|o| p.k_t * o * o)
}

pub fn motor_positions(p: &QuadParams) -> [V3; 4] {
    MOTOR_ANGLES.map(|a| [p.arm * (a * PI / 180.0).cos(), p.arm * (a * PI / 180.0).sin(), 0.0])
}

// MARK: Wind

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindSpec {
    pub mean: V3,         // m/s
    pub turbulence: f64,  // m/s, standard deviation per axis
    pub length_scale: f64, // m, size of the eddies (sets the turbulence bandwidth with airspeed)
    pub gust_every: f64,  // s, mean time between gusts (0: none)
    pub gust_peak: f64,   // m/s
}
pub const CALM: WindSpec = WindSpec { mean: [0.0; 3], turbulence: 0.0, length_scale: 10.0, gust_every: 0.0, gust_peak: 0.0 };

#[derive(Clone, Debug)]
pub struct Gust {
    pub start: f64,
    pub length: f64,
    pub dir: V3,
    pub peak: f64,
}

/// Mean plus Dryden-like turbulence (a first-order filtered noise per axis whose bandwidth grows
/// with airspeed) plus discrete 1 − cos gusts from random directions.
#[derive(Clone, Debug)]
pub struct Wind {
    pub spec: WindSpec,
    pub turb: V3,
    pub gust: Option<Gust>,
    pub next_gust: f64,
}

impl Wind {
    pub fn new(spec: WindSpec, rand: &mut Rng) -> Self {
        let next_gust = if spec.gust_every != 0.0 { rand.range(0.3, 1.7) * spec.gust_every } else { f64::INFINITY };
        Wind { spec, turb: [0.0; 3], gust: None, next_gust }
    }
    pub fn at(&mut self, t: f64, dt: f64, airspeed: f64, rand: &mut Rng) -> V3 {
        let s = &self.spec;
        if s.turbulence > 0.0 {
            let a = airspeed.max(2.0) * dt / s.length_scale; // inverse correlation time × dt
            let k = (2.0 * a).sqrt() * s.turbulence;
            for i in 0..3 {
                self.turb[i] += -a * self.turb[i] + k * rand.gauss() * if i == 2 { 0.5 } else { 1.0 };
            }
        }
        if self.gust.is_none() && t >= self.next_gust {
            let yaw = rand.range(0.0, 2.0 * PI);
            let length = rand.range(0.6, 2.0);
            let dz = rand.range(-0.2, 0.2);
            let peak = rand.range(0.5, 1.0) * s.gust_peak;
            self.gust = Some(Gust { start: t, length, dir: [yaw.cos(), yaw.sin(), dz], peak });
        }
        let mut g = [0.0; 3];
        if let Some(gust) = &self.gust {
            let u = (t - gust.start) / gust.length;
            if u >= 1.0 {
                self.gust = None;
                self.next_gust = t + rand.range(0.3, 1.7) * self.spec.gust_every;
            } else {
                g = scale(gust.dir, gust.peak * (1.0 - (2.0 * PI * u).cos()) / 2.0);
            }
        }
        add(add(self.spec.mean, self.turb), g)
    }
}

// MARK: Step

/// The air and the airframe's condition for one step (weather.rs fills it).
#[derive(Clone, Debug)]
pub struct Env {
    pub rho: f64,           // kg/m³
    pub thrust_factor: f64, // water and ice on the blades
    pub extra_mass: f64,    // kg, snow load and payload
    pub down_force: f64,    // N, rain on the rotor discs
    pub omega_scale: f64,   // loaded pack voltage over a full pack's
    pub turbulence: f64,    // m/s, for the shear across the rotors (realism.rs)
}
pub const SEA_LEVEL: Env = Env { rho: RHO, thrust_factor: 1.0, extra_mass: 0.0, down_force: 0.0, omega_scale: 1.0, turbulence: 0.0 };

/// Ground effect (Cheeseman and Bennett): thrust gain of a rotor at height z over the ground.
pub fn ground_effect(prop_radius: f64, z: f64) -> f64 {
    1.0 / (1.0 - (prop_radius / (4.0 * z.max(1e-3))).powi(2).min(0.5))
}

/// Advances the state by dt toward the commanded motor speeds (rad/s), in the given wind.
/// Semi-implicit Euler: fine at the 1 to 2 ms steps the controller runs at.
/// `aero`: the realistic plant (realism.rs) with the random stream it draws from.
pub fn step(p: &QuadParams, s: &mut QuadState, cmd: &[f64; 4], wind: V3, dt: f64, env: &Env, mut aero: Option<(&mut Aero, &mut Rng)>) {
    if s.crashed {
        return;
    }
    for i in 0..4 {
        let target = cmd[i].max(p.omega_idle).min(p.omega_max * env.omega_scale);
        let tau = p.motor_tau * aero.as_ref().map_or(1.0, |a| a.0.build.tau[i]);
        s.omega[i] += (target - s.omega[i]) * (dt / tau).min(1.0);
    }
    let r = q_to_m3(s.q);
    let air = env.rho / RHO;
    let ge = ground_effect(p.prop_radius, s.p[2] + 0.02);
    let mut t = thrusts(p, s).map(|x| x * air * env.thrust_factor * ge);
    let pos = motor_positions(p);
    let mass = p.mass + env.extra_mass;

    // Forces in body axes: thrust along z, drag against the relative air.
    let rel = mtv(&r, sub(s.v, wind));
    let (mut extra_f, mut extra_tau) = ([0.0; 3], [0.0; 3]);
    if let Some((a, rand)) = aero.as_mut() {
        let out = a.forces(p, s, t, rel, env.rho, env.turbulence, dt, rand);
        (t, extra_f, extra_tau) = (out.t, out.force, out.torque);
    }
    let thrust = t[0] + t[1] + t[2] + t[3];
    // drag_linear is mostly the rotors' edgewise drag; with realism.rs that is modelled per rotor.
    let rotor_drag = aero.as_ref().is_some_and(|a| a.0.r.rotor_drag > 0.0);
    let lin = |i: usize| if rotor_drag && i < 2 { 0.0 } else { p.drag_linear[i] };
    let drag: V3 = std::array::from_fn(|i| air * (-lin(i) * rel[i] - p.drag_quad[i] * rel[i] * rel[i].abs()));
    let f_body = [drag[0] + extra_f[0], drag[1] + extra_f[1], thrust + drag[2] + extra_f[2] - env.down_force * r[8]];
    s.acc_body = scale(f_body, 1.0 / mass);

    // Torques: differential thrust, propeller drag reaction, gyroscopic coupling.
    let mut tau = extra_tau;
    for i in 0..4 {
        tau = add(tau, cross(pos[i], [0.0, 0.0, t[i]]));
        let kq = aero.as_ref().map_or(1.0, |a| a.0.build.k_q[i]);
        tau[2] += MOTOR_SPIN[i] * p.k_q * kq * air * s.omega[i] * s.omega[i];
    }
    let j = p.inertia;
    let jw = [j[0] * s.w[0], j[1] * s.w[1], j[2] * s.w[2]];
    let wdot = sub(tau, cross(s.w, jw));
    s.w = [s.w[0] + (wdot[0] / j[0]) * dt, s.w[1] + (wdot[1] / j[1]) * dt, s.w[2] + (wdot[2] / j[2]) * dt];

    let a = add(scale(mv(&r, f_body), 1.0 / mass), [0.0, 0.0, -G]);
    s.v = add(s.v, scale(a, dt));
    s.p = add(s.p, scale(s.v, dt));

    let [wx, wy, wz] = s.w;
    let dq = q_mul(s.q, [0.0, wx, wy, wz]);
    s.q = q_normalize(std::array::from_fn(|i| s.q[i] + 0.5 * dq[i] * dt));

    // Ground: a soft landing stops on it, a hard or tilted one is a crash.
    if s.p[2] < 0.0 {
        let tilted = r[8] < 0.7;
        if s.v[2] < -3.0 || tilted || hypot2(s.v[0], s.v[1]) > 3.0 {
            s.crashed = true;
        }
        s.p[2] = 0.0;
        s.v = [0.0, 0.0, s.v[2].max(0.0)];
        s.w = [0.0; 3];
    }
    s.t += dt;
}
