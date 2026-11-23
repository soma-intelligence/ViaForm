//! What makes a small quad hard to hold still, beyond the rigid body in physics.rs. Each effect is
//! a first-order model of a known phenomenon, sized for a 3-inch quad:
//!   - Rotor drag and blade flapping: a rotor moving edgewise through the air makes a drag force
//!     in the disc plane, proportional to its speed (Mahony, Kumar and Corke 2012). The rotors sit
//!     above the centre of mass, so the force also pitches the drone back from the wind.
//!   - Inflow: climbing through its own wake costs a rotor thrust, translational lift gives some
//!     back in forward flight, and a fast vertical descent into the wake (vortex ring state) loses
//!     thrust and makes it fluctuate rotor by rotor.
//!   - Wind shear across the rotors: turbulence is not uniform over 12 cm. Each rotor sees its own
//!     vertical gust, and the difference between them rolls and pitches the drone.
//!   - The build: no two motors or props are alike (thrust, drag, spin-up), the centre of mass is
//!     not at the centre of the motors, and props are out of balance, which shakes the frame at
//!     the rotation frequency.
//!   - The sensors: gyro and accelerometer noise and bias, bias drifting, motor vibration on both
//!     (sampled at 8 kHz and averaged down to the loop rate, as a real flight controller's gyro
//!     filter does), and the ESC's command latency.
//! Kicks (a hit, a branch, a hand) are applied from outside with `kick`.

use serde::{Deserialize, Serialize};

use crate::math::*;
use crate::physics::{MOTOR_ANGLES, QuadParams, QuadState};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Realism {
    pub rotor_drag: f64,    // N per (m/s) per (rad/s) of rotor speed, in the disc plane
    pub rotor_height: f64,  // m, rotor plane above the centre of mass
    pub inflow: bool,       // climb loss, translational lift, vortex ring state
    pub shear: f64,         // 0..1, share of the turbulence that differs from rotor to rotor
    pub motor_spread: f64,  // relative standard deviation of kT, kQ and spin-up between motors
    pub cg_offset: f64,     // m, standard deviation of the centre of mass from the centre of the motors
    pub imbalance: f64,     // N at full speed, prop and bell imbalance per motor
    pub gyro_noise: f64,    // rad/s per sample at the loop rate
    pub gyro_bias_walk: f64, // rad/s per √s
    pub acc_noise: f64,     // m/s² per sample
    pub esc_delay: usize,   // loop steps between a command and the ESC acting on it
}

/// All effects at the size measured on 3-inch builds.
pub const REALISTIC: Realism = Realism {
    rotor_drag: 5.8e-6, rotor_height: 0.012, inflow: true, shear: 0.6, motor_spread: 0.04, cg_offset: 0.004, imbalance: 0.05,
    gyro_noise: 0.02, gyro_bias_walk: 0.002, acc_noise: 0.25, esc_delay: 1,
};
/// None of them: the rigid body alone (what the first training ran on).
pub const IDEAL: Realism = Realism {
    rotor_drag: 0.0, rotor_height: 0.0, inflow: false, shear: 0.0, motor_spread: 0.0, cg_offset: 0.0, imbalance: 0.0,
    gyro_noise: 0.03, gyro_bias_walk: 0.0, acc_noise: 0.3, esc_delay: 0,
};

/// One drone as built: its motors and its balance.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Build {
    pub k_t: [f64; 4], // scale per motor
    pub k_q: [f64; 4],
    pub tau: [f64; 4],
    pub cg: V3, // m, body axes
    pub phase: [f64; 4], // rad, imbalance phase per motor
}

pub fn make_build(r: &Realism, rand: &mut Rng) -> Build {
    let spread = |rand: &mut Rng| -> [f64; 4] { std::array::from_fn(|_| 1.0 + r.motor_spread * rand.gauss().clamp(-2.5, 2.5)) };
    let k_t = spread(rand);
    let k_q = spread(rand);
    let tau = spread(rand);
    let cg = [r.cg_offset * rand.gauss(), r.cg_offset * rand.gauss(), 0.0];
    let phase = std::array::from_fn(|_| rand.range(0.0, 2.0 * PI));
    Build { k_t, k_q, tau, cg, phase }
}

/// Hover induced velocity (m/s) of one rotor making thrust T: momentum theory.
pub fn induced_velocity(t: f64, rho: f64, radius: f64) -> f64 {
    (t.max(1e-4) / (2.0 * rho * PI * radius * radius)).sqrt()
}

/// Thrust factor of one rotor from its inflow: `vz` is the air coming up through the disc in body
/// z (positive in a descent), `vh` the edgewise airspeed, `vi` the hover induced velocity. Climb
/// (vz < 0) costs thrust, edgewise flow adds some (translational lift), and a descent between
/// about 0.4 and 1.6 vi with little edgewise flow is the vortex ring state: thrust falls by up to
/// 30 % and flutters (the caller adds the flutter). Returns (factor, vrs).
pub fn inflow_factor(vz: f64, vh: f64, vi: f64) -> (f64, f64) {
    // Descending into the wake helps only a little before the ring forms.
    let climb = (vz / (2.0 * vi)).min(0.1).max(-0.4);
    let etl = 0.12 * (vh / (1.5 * vi)).powi(2).min(1.0);
    let d = vz / vi;
    // VRS: a bump around 1 vi of descent, washed out by edgewise flow.
    let vrs = (1.0 - ((d - 1.0) / 0.6).powi(2)).max(0.0) * (1.0 - vh / vi).max(0.0);
    ((1.0 + climb) * (1.0 + etl) * (1.0 - 0.3 * vrs), vrs)
}

pub struct AeroOut {
    pub t: [f64; 4],
    pub force: V3,
    pub torque: V3,
}

/// The extra forces and torques (body axes) of the effects above, for one physics step.
#[derive(Clone, Debug)]
pub struct Aero {
    pub r: Realism,
    pub build: Build,
    /// Vertical gust at each rotor relative to the mean turbulence (m/s), an OU process.
    pub shear_w: [f64; 4],
    pub flutter: [f64; 4],
    pub vrs: f64,
    pub phase: [f64; 4],
    /// Last imbalance force (body), for the accelerometer.
    pub shake: V3,
}

impl Aero {
    pub fn new(r: Realism, build: Build) -> Self {
        let phase = build.phase;
        Aero { r, build, shear_w: [0.0; 4], flutter: [0.0; 4], vrs: 0.0, phase, shake: [0.0; 3] }
    }

    /// Thrust per rotor after the build's spread, inflow, shear and flutter, plus the in-plane
    /// forces of rotor drag and imbalance and their torques about the centre of mass (body axes).
    /// `t` is each rotor's nominal thrust, `rel` the body-axes velocity of the drone through the
    /// air, `turbulence` the turbulence intensity (m/s). The caller applies the thrusts at the
    /// motor positions; `torque` adds what the centre-of-mass offset and the in-plane forces make.
    /// `rand` is the realism stream the IMU also draws from.
    #[allow(clippy::too_many_arguments)]
    pub fn forces(&mut self, p: &QuadParams, s: &QuadState, t: [f64; 4], rel: V3, rho: f64, turbulence: f64, dt: f64, rand: &mut Rng) -> AeroOut {
        let r = self.r.clone();
        let b = &self.build;
        let mut out: [f64; 4] = std::array::from_fn(|i| t[i] * b.k_t[i]);
        let (mut force, mut torque) = ([0.0; 3], [0.0; 3]);
        let cg = b.cg;
        let pos: [V3; 4] = MOTOR_ANGLES.map(|a| [p.arm * (a * PI / 180.0).cos() - cg[0], p.arm * (a * PI / 180.0).sin() - cg[1], r.rotor_height - cg[2]]);
        // Shear: each rotor's own vertical gust, decorrelating over a few arm lengths of travel.
        if r.shear > 0.0 && turbulence > 0.0 {
            let airspeed = norm(rel).max(2.0);
            let a = (airspeed * dt / (p.arm * 4.0)).min(1.0);
            let sd = r.shear * turbulence * 0.5;
            for i in 0..4 {
                self.shear_w[i] += -a * self.shear_w[i] + (2.0 * a).sqrt() * sd * rand.gauss();
            }
        } else {
            self.shear_w = [0.0; 4];
        }
        self.vrs = 0.0;
        self.shake = [0.0; 3];
        let af = (dt / 0.05).min(1.0);
        for i in 0..4 {
            let ri = pos[i];
            // Air at the rotor: the drone's motion, its rotation (w × r), and its own gust.
            let local = add(sub(rel, [0.0, 0.0, self.shear_w[i]]), cross(s.w, ri));
            let vh = hypot2(local[0], local[1]);
            if r.inflow {
                let vi = induced_velocity(out[i], rho, p.prop_radius);
                let (factor, vrs) = inflow_factor(-local[2], vh, vi);
                self.vrs = self.vrs.max(vrs);
                // Flutter in the vortex ring: a random thrust change of ~15 %, rotor by rotor, at ~20 Hz.
                self.flutter[i] += -af * self.flutter[i] + (2.0 * af).sqrt() * 0.15 * vrs * rand.gauss();
                out[i] *= (factor + self.flutter[i]).max(0.3);
            } else if r.shear > 0.0 {
                // Without the inflow model the gust still changes the blades' angle of attack.
                out[i] *= 1.0 - self.shear_w[i] * 0.08;
            }
            // Rotor drag (H-force): against the edgewise flow, proportional to rotor speed.
            let h = [-r.rotor_drag * s.omega[i] * local[0], -r.rotor_drag * s.omega[i] * local[1], 0.0];
            // Imbalance: a force turning with the rotor in the disc plane, growing with speed squared.
            self.phase[i] += s.omega[i] * dt;
            let u = s.omega[i] / p.omega_max;
            let f = r.imbalance * u * u;
            let shake = [f * self.phase[i].cos(), f * self.phase[i].sin(), 0.0];
            self.shake = add(self.shake, shake);
            let in_plane = add(h, shake);
            force = add(force, in_plane);
            torque = add(torque, cross(ri, in_plane));
        }
        // The thrusts act at the motors, but about a centre of mass that is not at their centre.
        torque = add(torque, cross([-cg[0], -cg[1], 0.0], [0.0, 0.0, out[0] + out[1] + out[2] + out[3]]));
        AeroOut { t: out, force, torque }
    }
}

/// The IMU as the flight controller reads it: rates and specific force with noise, bias and the
/// vibration averaged over the loop step (an 8 kHz gyro decimated by its low-pass).
#[derive(Clone, Debug)]
pub struct Imu {
    pub r: Realism,
    pub gyro_bias: V3,
}

impl Imu {
    pub fn new(r: Realism, rand: &mut Rng, temperature_c: f64) -> Self {
        let k = 1.0 + (temperature_c - 25.0).abs() / 20.0; // MEMS bias grows away from calibration
        // What is left after the gyro calibration at arming: a fraction of the raw bias.
        let gyro_bias = std::array::from_fn(|_| rand.gauss() * 0.003 * k);
        Imu { r, gyro_bias }
    }
    /// Returns (gyro, accelerometer).
    pub fn read(&mut self, s: &QuadState, aero: Option<&Aero>, mass: f64, inertia: V3, dt: f64, rand: &mut Rng) -> (V3, V3) {
        let r = &self.r;
        let walk = r.gyro_bias_walk * dt.sqrt();
        for i in 0..3 {
            self.gyro_bias[i] += walk * rand.gauss();
        }
        // Vibration: the shake force accelerates the frame and rocks it about the centre of mass.
        let (mut acc_vib, mut w_vib) = ([0.0; 3], [0.0; 3]);
        if let Some(aero) = aero.filter(|_| r.imbalance > 0.0) {
            // Averaging a sinusoid at the rotor frequency over one step attenuates it by sinc(ω dt / 2).
            let mean_omega = s.omega.iter().sum::<f64>() / 4.0;
            let x = mean_omega * dt / 2.0;
            let att = (x.sin() / x.max(1e-6)).abs();
            acc_vib = scale(aero.shake, att * 6.0 / mass); // the stack's soft mount still passes some
            w_vib = scale([aero.shake[1], -aero.shake[0], 0.0], att * r.rotor_height * 40.0 / inertia[0].max(1e-6) * dt);
        }
        let (gn, an) = (r.gyro_noise, r.acc_noise);
        let gw = [gn * rand.gauss(), gn * rand.gauss(), gn * rand.gauss()];
        let aw = [an * rand.gauss(), an * rand.gauss(), an * rand.gauss()];
        (add(add(add(s.w, self.gyro_bias), w_vib), gw), add(add(s.acc_body, acc_vib), aw))
    }
}

/// Mahony's complementary filter: integrates the gyro, pulls toward the accelerometer's gravity
/// and estimates the gyro bias. Yaw has no magnetometer here; the companion's visual odometry
/// gives a heading at a low gain.
#[derive(Clone, Debug)]
pub struct Mahony {
    pub q: Q,
    pub bias: V3,
    pub kp: f64,
    pub ki: f64,
}

impl Mahony {
    pub fn new(q: Q) -> Self {
        Mahony { q, bias: [0.0; 3], kp: 1.2, ki: 0.08 }
    }
    pub fn update(&mut self, w: V3, acc: V3, heading_ref: Option<f64>, dt: f64) {
        let [q0, q1, q2, q3] = self.q;
        // Gravity direction the estimate expects in body axes (third row of R).
        let v = [2.0 * (q1 * q3 - q0 * q2), 2.0 * (q0 * q1 + q2 * q3), q0 * q0 - q1 * q1 - q2 * q2 + q3 * q3];
        let an = norm(acc);
        let mut e = [0.0; 3];
        // Trust the accelerometer only near 1 g (a hard manoeuvre is not gravity).
        if an > 6.0 && an < 14.0 {
            e = cross(scale(acc, 1.0 / an), v);
        }
        if let Some(h) = heading_ref {
            let yaw = (2.0 * (q0 * q3 + q1 * q2)).atan2(1.0 - 2.0 * (q2 * q2 + q3 * q3));
            let d = (h - yaw).sin().atan2((h - yaw).cos());
            e = add(e, scale(v, d * 0.5)); // about the world vertical, seen in body axes
        }
        self.bias = sub(self.bias, scale(e, self.ki * dt));
        let c = add(sub(w, self.bias), scale(e, self.kp));
        let dq = [
            -q1 * c[0] - q2 * c[1] - q3 * c[2],
            q0 * c[0] + q2 * c[2] - q3 * c[1],
            q0 * c[1] - q1 * c[2] + q3 * c[0],
            q0 * c[2] + q1 * c[1] - q2 * c[0],
        ];
        let q: Q = std::array::from_fn(|i| self.q[i] + 0.5 * dq[i] * dt);
        self.q = q_normalize(q);
    }
}

/// A blow from outside: `impulse` (N·s, world) at `at` (m from the centre of mass, body axes).
pub fn kick(s: &mut QuadState, p: &QuadParams, r: &M3, impulse: V3, at: V3) {
    s.v = add(s.v, scale(impulse, 1.0 / p.mass));
    let l = cross(at, mtv(r, impulse));
    s.w = [s.w[0] + l[0] / p.inertia[0], s.w[1] + l[1] / p.inertia[1], s.w[2] + l[2] / p.inertia[2]];
}
