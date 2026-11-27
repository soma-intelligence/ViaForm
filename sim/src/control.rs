//! The flight controller: a cascade of PID loops as on Betaflight, INAV and PX4. Position gives a
//! velocity setpoint, velocity gives an acceleration (and so a thrust vector and an attitude),
//! attitude gives body rates, rates give torques, and the mixer turns thrust and torques into
//! four motor speeds. A learned residual (policy.rs) can add to the acceleration command.
//!
//! The rate loop is either a PID (as Betaflight) or INDI, incremental nonlinear dynamic inversion
//! (Smeur, Chu and de Croon 2016; Tal and Karaman 2021): it measures the angular acceleration the
//! drone has now and the torque the motors make now (from their RPM, which bidirectional DShot
//! reports), and asks only for the torque *change* that gives the wanted acceleration. Whatever
//! else pushes on the drone (a gust, a bent prop, an off-centre pack) is in the measurement, so it
//! is cancelled without the controller knowing what it is.

use serde::{Deserialize, Serialize};

use crate::math::*;
use crate::physics::{G, MOTOR_SPIN, QuadParams, motor_positions};

/// Every gain the tuner may change, in one flat record.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Gains {
    pub pos_p: f64,      // 1/s
    pub vel_p: f64,      // 1/s
    pub vel_i: f64,      // 1/s²
    pub vel_d: f64,      // dimensionless
    pub att_p: f64,      // 1/s
    pub yaw_p: f64,      // 1/s
    pub rate_p: f64,     // 1/s
    pub rate_i: f64,     // 1/s²
    pub rate_d: f64,     // dimensionless
    pub yaw_rate_p: f64, // 1/s
}

pub const DEFAULT_GAINS: Gains = Gains { pos_p: 1.2, vel_p: 2.2, vel_i: 0.6, vel_d: 0.05, att_p: 7.0, yaw_p: 3.0, rate_p: 22.0, rate_i: 30.0, rate_d: 0.02, yaw_rate_p: 10.0 };
pub const GAIN_COUNT: usize = 10;

impl Gains {
    pub fn to_array(&self) -> [f64; GAIN_COUNT] {
        [self.pos_p, self.vel_p, self.vel_i, self.vel_d, self.att_p, self.yaw_p, self.rate_p, self.rate_i, self.rate_d, self.yaw_rate_p]
    }
    pub fn from_array(a: [f64; GAIN_COUNT]) -> Self {
        Gains { pos_p: a[0], vel_p: a[1], vel_i: a[2], vel_d: a[3], att_p: a[4], yaw_p: a[5], rate_p: a[6], rate_i: a[7], rate_d: a[8], yaw_rate_p: a[9] }
    }
}

/// `rate_int_max` (rad/s²): how much the rate loop's integrator may hold. The first training ran
/// with 3; holding an off-centre pack (4 mm takes ~35 rad/s²) needs Betaflight's wider limit,
/// which the disturbance-tuned brains use (flight.rs `stable`).
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub tilt_max: f64,
    pub vel_max: f64,
    pub vel_up_max: f64,
    pub acc_max: f64,
    pub rate_max: f64,
    pub yaw_rate_max: f64,
    pub rate_int_max: f64,
}
pub const DEFAULT_LIMITS: Limits = Limits { tilt_max: 40.0 * PI / 180.0, vel_max: 5.0, vel_up_max: 2.5, acc_max: 12.0, rate_max: 8.0, yaw_rate_max: 3.0, rate_int_max: 3.0 };

/// What the controller knows about the drone: an estimate, not the true state.
#[derive(Clone, Debug)]
pub struct Estimate {
    pub p: V3,
    pub v: V3,
    pub r: M3,
    pub w: V3,
    pub acc_body: V3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum RateLoop {
    #[default]
    Pid,
    Indi,
}

#[derive(Clone, Debug)]
pub enum Setpoint {
    Position { p: V3, yaw: f64 },
    Velocity { v: V3, yaw: f64, p: Option<V3> },
}

impl Setpoint {
    pub fn yaw(&self) -> f64 {
        match self {
            Setpoint::Position { yaw, .. } | Setpoint::Velocity { yaw, .. } => *yaw,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Cascade {
    pub p: QuadParams,
    pub g: Gains,
    pub lim: Limits,
    pub vel_int: V3,
    pub rate_int: V3,
    pub last_vel_err: V3,
    pub w_filt: V3,
    pub last_w: V3,
    /// For the policy and the display: the last acceleration command and collective thrust.
    pub acc_cmd: V3,
    pub thrust_cmd: f64,
    /// Thrust axis the attitude loop asks for (world), for the attitude error metric.
    pub z_des: V3,
    pub rate_loop: RateLoop,
    /// INDI: the low-pass on the gyro and RPM (Hz), and the gain on the rate error (1/s, 0: rate_p).
    pub indi_hz: f64,
    pub indi_rate_p: f64,
    // INDI state: filtered gyro, its derivative, and the filtered motor torque.
    indi_w: V3,
    indi_last_w: V3,
    indi_alpha: V3,
    indi_tau: V3,
    mix_inv: [[f64; 4]; 4],
}

impl Cascade {
    pub fn new(p: QuadParams, g: Gains, lim: Limits) -> Self {
        let mix_inv = mixer_inverse(&p);
        Cascade {
            p, g, lim, vel_int: [0.0; 3], rate_int: [0.0; 3], last_vel_err: [0.0; 3], w_filt: [0.0; 3], last_w: [0.0; 3],
            acc_cmd: [0.0; 3], thrust_cmd: 0.0, z_des: [0.0, 0.0, 1.0], rate_loop: RateLoop::Pid, indi_hz: 50.0, indi_rate_p: 0.0,
            indi_w: [0.0; 3], indi_last_w: [0.0; 3], indi_alpha: [0.0; 3], indi_tau: [0.0; 3], mix_inv,
        }
    }

    /// The mixer follows the parameters the controller believes in.
    pub fn set_params(&mut self, p: QuadParams) {
        self.mix_inv = mixer_inverse(&p);
        self.p = p;
    }

    pub fn reset(&mut self) {
        self.vel_int = [0.0; 3];
        self.rate_int = [0.0; 3];
        self.last_vel_err = [0.0; 3];
        self.w_filt = [0.0; 3];
        self.last_w = [0.0; 3];
        self.indi_w = [0.0; 3];
        self.indi_last_w = [0.0; 3];
        self.indi_alpha = [0.0; 3];
        self.indi_tau = [0.0; 3];
    }

    /// The acceleration the outer loops ask for (before any learned residual).
    pub fn outer(&mut self, e: &Estimate, sp: &Setpoint, dt: f64) -> V3 {
        let (g, l) = (self.g, self.lim);
        let mut v_sp = match sp {
            Setpoint::Position { p, .. } => scale(sub(*p, e.p), g.pos_p),
            Setpoint::Velocity { v, p: Some(p), .. } => add(*v, scale(sub(*p, e.p), g.pos_p * 0.5)),
            Setpoint::Velocity { v, p: None, .. } => *v,
        };
        let h = clamp_len([v_sp[0], v_sp[1], 0.0], l.vel_max);
        v_sp = [h[0], h[1], clamp(v_sp[2], -l.vel_up_max, l.vel_up_max)];

        let err = sub(v_sp, e.v);
        let d_err = scale(sub(err, self.last_vel_err), 1.0 / dt);
        self.last_vel_err = err;
        let a = add(add(scale(err, g.vel_p), self.vel_int), scale(d_err, g.vel_d));
        // Anti-windup: integrate only while the command is not saturated.
        if norm(a) < l.acc_max {
            self.vel_int = clamp_len(add(self.vel_int, scale(err, g.vel_i * dt)), 6.0);
        }
        clamp_len(a, l.acc_max)
    }

    /// Motor speed commands from an acceleration command (world) and a yaw setpoint. `rpm`: the
    /// motor speeds the ESCs report (rad/s), which INDI needs.
    pub fn inner(&mut self, e: &Estimate, acc: V3, yaw_sp: f64, dt: f64, rpm: Option<&[f64; 4]>) -> [f64; 4] {
        let (g, l) = (self.g, self.lim);
        self.acc_cmd = acc;
        // Thrust vector: what must push against gravity plus the commanded acceleration, tilt limited.
        let mut f = [acc[0], acc[1], (acc[2] + G).max(0.25 * G)];
        let horiz = hypot2(f[0], f[1]);
        let max_h = f[2] * l.tilt_max.tan();
        if horiz > max_h {
            f = [f[0] * max_h / horiz, f[1] * max_h / horiz, f[2]];
        }
        let zb = unit(f);
        self.z_des = zb;
        let collective = self.p.mass * dot(f, col(&e.r, 2));
        self.thrust_cmd = collective;

        // Desired attitude from the thrust axis and the yaw setpoint.
        let xc = [yaw_sp.cos(), yaw_sp.sin(), 0.0];
        let yb = unit(cross(zb, xc));
        let xb = cross(yb, zb);
        let rd: M3 = [xb[0], yb[0], zb[0], xb[1], yb[1], zb[1], xb[2], yb[2], zb[2]];
        // Geometric attitude error eR = ½ vee(Rdᵀ R − Rᵀ Rd).
        let m = |a: &M3, b: &M3, i: usize, j: usize| a[i] * b[j] + a[3 + i] * b[3 + j] + a[6 + i] * b[6 + j];
        let er = [
            0.5 * (m(&rd, &e.r, 2, 1) - m(&e.r, &rd, 2, 1)),
            0.5 * (m(&rd, &e.r, 0, 2) - m(&e.r, &rd, 0, 2)),
            0.5 * (m(&rd, &e.r, 1, 0) - m(&e.r, &rd, 1, 0)),
        ];
        // Yaw is slow on a quad (only drag torque turns it): cap it so it never eats the motors'
        // headroom that roll and pitch need.
        let w_sp = [
            clamp(-g.att_p * er[0], -l.rate_max, l.rate_max),
            clamp(-g.att_p * er[1], -l.rate_max, l.rate_max),
            clamp(-g.yaw_p * er[2], -l.yaw_rate_max, l.yaw_rate_max),
        ];

        // Rate loop, D on the measurement through a low-pass (gyro noise).
        self.w_filt = add(scale(self.w_filt, 0.7), scale(e.w, 0.3));
        let dw = scale(sub(self.w_filt, self.last_w), 1.0 / dt);
        self.last_w = self.w_filt;
        let r_err = sub(w_sp, e.w);
        self.rate_int = clamp_len(add(self.rate_int, scale(r_err, g.rate_i * dt)), l.rate_int_max);
        let j = self.p.inertia;
        if self.rate_loop == RateLoop::Indi {
            if let Some(rpm) = rpm {
                let tau = self.indi(e.w, w_sp, rpm, dt);
                return self.mix(collective, tau);
            }
        }
        let alpha = [
            g.rate_p * r_err[0] + self.rate_int[0] - g.rate_d * dw[0] * 100.0,
            g.rate_p * r_err[1] + self.rate_int[1] - g.rate_d * dw[1] * 100.0,
            g.yaw_rate_p * r_err[2] + 0.2 * self.rate_int[2],
        ];
        let jw = [j[0] * e.w[0], j[1] * e.w[1], j[2] * e.w[2]];
        let tau = add([j[0] * alpha[0], j[1] * alpha[1], j[2] * alpha[2]], cross(e.w, jw));
        self.mix(collective, tau)
    }

    /// INDI: torque now (from RPM) plus inertia times the missing angular acceleration. The gyro
    /// and the RPM go through the same low-pass so the two stay in step.
    fn indi(&mut self, w: V3, w_sp: V3, rpm: &[f64; 4], dt: f64) -> V3 {
        let (p, g) = (&self.p, self.g);
        let j = p.inertia;
        let a = (dt * 2.0 * PI * self.indi_hz).min(1.0);
        self.indi_w = add(self.indi_w, scale(sub(w, self.indi_w), a));
        let alpha_raw = scale(sub(self.indi_w, self.indi_last_w), 1.0 / dt);
        self.indi_last_w = self.indi_w;
        self.indi_alpha = add(self.indi_alpha, scale(sub(alpha_raw, self.indi_alpha), a));
        let pos = motor_positions(p);
        let mut tau_now = [0.0; 3];
        for (i, &o) in rpm.iter().enumerate() {
            tau_now = add(tau_now, cross(pos[i], [0.0, 0.0, p.k_t * o * o]));
            tau_now[2] += MOTOR_SPIN[i] * p.k_q * o * o;
        }
        self.indi_tau = add(self.indi_tau, scale(sub(tau_now, self.indi_tau), a));
        // Wanted angular acceleration: a proportional rate loop (INDI needs no integrator).
        let kp = if self.indi_rate_p != 0.0 { self.indi_rate_p } else { g.rate_p };
        let alpha_ref = [kp * (w_sp[0] - self.indi_w[0]), kp * (w_sp[1] - self.indi_w[1]), g.yaw_rate_p * (w_sp[2] - self.indi_w[2])];
        std::array::from_fn(|i| self.indi_tau[i] + j[i] * (alpha_ref[i] - self.indi_alpha[i]))
    }

    /// Thrust per motor from collective and torques; yaw gives way first when a motor saturates.
    pub fn mix(&self, collective: f64, tau: V3) -> [f64; 4] {
        let p = &self.p;
        let t_max = p.k_t * p.omega_max * p.omega_max;
        let t_min = p.k_t * p.omega_idle * p.omega_idle;
        let solve = |u: [f64; 4]| -> [f64; 4] { std::array::from_fn(|r| (0..4).fold(0.0, |s, k| s + self.mix_inv[r][k] * u[k])) };
        let mut t = solve([collective, tau[0], tau[1], tau[2]]);
        let max = |t: &[f64; 4]| t.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let min = |t: &[f64; 4]| t.iter().cloned().fold(f64::INFINITY, f64::min);
        if max(&t) > t_max || min(&t) < t_min {
            t = solve([collective, tau[0], tau[1], tau[2] * 0.3]);
        }
        // Air mode: shift all four to keep the differential (attitude authority) inside the range.
        let (hi, lo) = (max(&t), min(&t));
        if hi - lo <= t_max - t_min {
            let shift = if hi > t_max { t_max - hi } else if lo < t_min { t_min - lo } else { 0.0 };
            t = t.map(|x| x + shift);
        }
        t.map(|x| (clamp(x, t_min, t_max) / p.k_t).sqrt())
    }
}

/// Inverse of the map from motor thrusts to [collective, roll, pitch, yaw torque].
pub fn mixer_inverse(p: &QuadParams) -> [[f64; 4]; 4] {
    let pos = motor_positions(p);
    let a = [
        [1.0, 1.0, 1.0, 1.0],
        pos.map(|r| r[1]),
        pos.map(|r| -r[0]),
        MOTOR_SPIN.map(|s| s * p.k_q / p.k_t),
    ];
    invert4(a)
}

fn invert4(a: [[f64; 4]; 4]) -> [[f64; 4]; 4] {
    let n = 4;
    let mut m: Vec<[f64; 8]> = (0..n).map(|i| std::array::from_fn(|j| if j < n { a[i][j] } else if j - n == i { 1.0 } else { 0.0 })).collect();
    for c in 0..n {
        let mut p = c;
        for r in c + 1..n {
            if m[r][c].abs() > m[p][c].abs() {
                p = r;
            }
        }
        m.swap(c, p);
        let d = m[c][c];
        for j in 0..2 * n {
            m[c][j] /= d;
        }
        for r in 0..n {
            if r == c {
                continue;
            }
            let k = m[r][c];
            for j in 0..2 * n {
                m[r][j] -= k * m[c][j];
            }
        }
    }
    std::array::from_fn(|i| std::array::from_fn(|j| m[i][n + j]))
}

/// Yaw of the body x axis (rad).
pub fn heading_of(r: &M3) -> f64 {
    r[3].atan2(r[0])
}
