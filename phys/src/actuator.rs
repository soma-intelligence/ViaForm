//! Actuators (RUST-ENGINES 6.2, E-17): ideal effort sources, position servos of the Feetech
//! STS3215 class (PD loop with torque and speed limits, gear ratio, efficiency, backlash,
//! deadband, encoder quantisation) and DC motors with a gearbox (back-EMF, armature resistance,
//! optional inductance, current limit), plus the tendon motor (position-controlled excursion).
//!
//! The servo's PD law is treated implicitly inside the contact solver: its torque
//! `tau = kp (e - dt adot') - kd adot'` (`adot'` the next velocity) is the impulse
//! `gamma = -(adot' - vhat) / R` with `R = 1 / (dt (kd + dt kp))`, `vhat = kp e / (kd + dt kp)`,
//! clipped to the torque-speed box. Stiff gains on light links stay stable at any step.

use serde::{Deserialize, Serialize};

/// How an actuator is driven. The control value's meaning depends on the kind.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ActuatorKind {
    /// Ideal effort source: control = torque (N m) or force (N) on the actuator, clipped to the
    /// actuator's effort limit.
    Torque,
    /// Position servo: control = target position (rad, or m for a linear joint).
    Servo(ServoParams),
    /// DC motor with a gearbox: control = voltage (V).
    Dc(DcParams),
    /// Tendon motor: control = target excursion (m, pull positive), reached at `max_speed`.
    TendonMotor {
        #[serde(default = "inf")]
        max_speed: f64,
    },
}

fn inf() -> f64 {
    f64::INFINITY
}

/// A serial bus position servo. Defaults are Feetech STS3215 class values (12 V version):
/// 2.94 N m stall (30 kg cm), 0.222 s per 60 degrees no load (4.7 rad/s), 1:345 gearbox,
/// 4096 count magnetic encoder on the output. Gains, rotor inertia, backlash and deadband are
/// typical values, not measured ones: replace them from bench data (phase 7 HIL).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct ServoParams {
    /// Position gain at the output, N m/rad.
    pub kp: f64,
    /// Velocity gain at the output, N m s/rad.
    pub kd: f64,
    /// Stall torque at the output, N m.
    pub stall_torque: f64,
    /// No-load speed at the output, rad/s.
    pub no_load_speed: f64,
    /// Current limit expressed as the largest output torque, N m.
    pub max_torque: f64,
    /// Gear ratio (motor turns per output turn).
    pub gear_ratio: f64,
    /// Gearbox efficiency (0, 1].
    pub efficiency: f64,
    /// Motor rotor inertia, kg m^2 (reflected: times gear_ratio^2).
    pub rotor_inertia: f64,
    /// Total backlash at the output, rad.
    pub backlash: f64,
    /// Position errors smaller than this give no torque, rad.
    pub deadband: f64,
    /// Encoder counts per output turn (0: no quantisation).
    pub encoder_counts: f64,
    /// Stall current, A (reported motor current is torque / stall_torque x this).
    pub stall_current: f64,
}

impl Default for ServoParams {
    fn default() -> Self {
        ServoParams {
            kp: 20.0,
            kd: 0.3,
            stall_torque: 2.94,
            no_load_speed: 4.72,
            max_torque: 2.94,
            gear_ratio: 345.0,
            efficiency: 0.9,
            rotor_inertia: 1.0e-8,
            backlash: 0.2f64.to_radians(),
            deadband: 2.0 * std::f64::consts::TAU / 4096.0,
            encoder_counts: 4096.0,
            stall_current: 2.7,
        }
    }
}

impl ServoParams {
    pub fn check(&self) -> Result<(), String> {
        let ok = |x: f64| x.is_finite() && x >= 0.0;
        if !(ok(self.kp) && ok(self.kd) && self.kp + self.kd > 0.0) {
            return Err("kp and kd must be zero or more, not both zero".into());
        }
        if !(self.stall_torque > 0.0 && self.no_load_speed > 0.0 && self.max_torque > 0.0) {
            return Err("stall torque, no-load speed and max torque must be positive".into());
        }
        if !(self.efficiency > 0.0 && self.efficiency <= 1.0 && self.gear_ratio > 0.0) {
            return Err("efficiency must be in (0, 1] and the gear ratio positive".into());
        }
        if !(ok(self.backlash) && ok(self.deadband) && ok(self.encoder_counts) && ok(self.rotor_inertia)) {
            return Err("backlash, deadband, encoder counts and rotor inertia must be zero or more".into());
        }
        Ok(())
    }

    /// Torque box at output speed `w`: the torque-speed line of the motor at full voltage, the
    /// current limit, and the gearbox efficiency.
    pub fn torque_box(&self, w: f64) -> (f64, f64) {
        let hi = (self.stall_torque * (1.0 - w / self.no_load_speed)).min(self.max_torque) * self.efficiency;
        let lo = (-self.stall_torque * (1.0 + w / self.no_load_speed)).max(-self.max_torque) * self.efficiency;
        (lo.min(hi), hi.max(lo))
    }

    /// The position the encoder reports.
    pub fn measure(&self, a: f64) -> f64 {
        if self.encoder_counts > 0.0 {
            let res = std::f64::consts::TAU / self.encoder_counts;
            (a / res).round() * res
        } else {
            a
        }
    }

    /// Position error after the deadband.
    pub fn error(&self, target: f64, measured: f64) -> f64 {
        let e = target - measured;
        if e.abs() <= self.deadband { 0.0 } else { e }
    }
}

/// A brushed DC motor with a gearbox. Defaults: a small 12 V gearmotor.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct DcParams {
    /// Torque constant, N m/A.
    pub kt: f64,
    /// Back-EMF constant, V s/rad (equals kt in SI for an ideal motor).
    pub ke: f64,
    /// Armature resistance, ohm.
    pub resistance: f64,
    /// Armature inductance, H (0: current follows the voltage at once).
    pub inductance: f64,
    pub gear_ratio: f64,
    pub efficiency: f64,
    /// Rotor inertia, kg m^2 (reflected: times gear_ratio^2).
    pub rotor_inertia: f64,
    /// Current limit, A.
    pub max_current: f64,
    /// Supply voltage limit, V.
    pub max_voltage: f64,
}

impl Default for DcParams {
    fn default() -> Self {
        DcParams { kt: 0.01, ke: 0.01, resistance: 2.0, inductance: 0.0, gear_ratio: 50.0, efficiency: 0.8, rotor_inertia: 2e-7, max_current: 3.0, max_voltage: 12.0 }
    }
}

impl DcParams {
    pub fn check(&self) -> Result<(), String> {
        if !(self.kt > 0.0 && self.ke >= 0.0 && self.resistance > 0.0 && self.inductance >= 0.0 && self.gear_ratio > 0.0) {
            return Err("kt, resistance and gear ratio must be positive, ke and inductance zero or more".into());
        }
        if !(self.efficiency > 0.0 && self.efficiency <= 1.0 && self.max_current > 0.0 && self.max_voltage > 0.0 && self.rotor_inertia >= 0.0) {
            return Err("efficiency in (0, 1], positive current and voltage limits".into());
        }
        Ok(())
    }

    /// Output-side back-EMF damping `eta N^2 kt ke / R`, N m s/rad.
    pub fn emf_damping(&self) -> f64 {
        self.efficiency * self.gear_ratio * self.gear_ratio * self.kt * self.ke / self.resistance
    }
}

/// Internal state of one actuator.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct ActuatorState {
    /// The control value (see [`ActuatorKind`]).
    pub control: f64,
    /// Servo: backlash gap position (motor side minus output, rad), in `[-b/2, b/2]`.
    pub gap: f64,
    /// Servo: gap rate, rad/s.
    pub gap_rate: f64,
    /// DC: armature current, A.
    pub current: f64,
    /// Tendon motor: excursion, m.
    pub excursion: f64,
    /// Tendon motor: excursion rate this step, m/s.
    pub excursion_rate: f64,
    /// Output effort of the last step (N m, N, or tendon tension N).
    pub effort: f64,
}

/// A one-row implicit constraint `gamma = clamp(-(J v - vhat) / r, lo, hi)` in impulse units.
#[derive(Clone, Copy, Debug)]
pub struct BoxRow {
    pub r: f64,
    pub vhat: f64,
    pub lo: f64,
    pub hi: f64,
}

/// Plans the servo's row for this step and advances its backlash state. `a` and `adot` are
/// the output position and speed, `dt` the step. Returns `None` while the motor crosses the
/// backlash gap (no torque reaches the joint).
pub fn servo_row(p: &ServoParams, st: &mut ActuatorState, a: f64, adot: f64, dt: f64) -> Option<BoxRow> {
    let meas = p.measure(a);
    let e = p.error(st.control, meas);
    let c = p.kd + dt * p.kp;
    let (lo, hi) = p.torque_box(adot);
    // Explicit estimate of the torque, to know which side of the gap the motor pushes.
    let tau_est = (p.kp * e - p.kd * adot).clamp(lo, hi);
    let half = 0.5 * p.backlash;
    let (mut lo, mut hi) = (lo, hi);
    if half > 0.0 {
        let want = if tau_est > 0.0 { half } else if tau_est < 0.0 { -half } else { st.gap.clamp(-half, half) };
        if (st.gap - want).abs() > 1e-12 {
            // The motor crosses the gap: driven by its torque against its own inertia, at no
            // more than its no-load speed.
            let inertia = (p.rotor_inertia * p.gear_ratio * p.gear_ratio).max(1e-9);
            st.gap_rate = (st.gap_rate + tau_est / inertia * dt).clamp(-p.no_load_speed, p.no_load_speed);
            let next = st.gap + (st.gap_rate - adot) * dt;
            if (want > st.gap && next >= want) || (want < st.gap && next <= want) {
                st.gap = want;
            } else {
                st.gap = next.clamp(-half, half);
                return None;
            }
        }
        // Engaged on one side: the motor moves with the output, only that sign of torque passes.
        st.gap_rate = adot;
        if st.gap >= half {
            lo = lo.max(0.0);
        } else {
            hi = hi.min(0.0);
        }
        if lo > hi {
            return None;
        }
    }
    if c <= 0.0 {
        return None;
    }
    Some(BoxRow { r: 1.0 / (dt * c), vhat: p.kp * e / c, lo: lo * dt, hi: hi * dt })
}

/// DC motor for one step at output speed `w`: returns `(explicit torque, implicit damping)` at
/// the output, and updates the armature current.
pub fn dc_step(p: &DcParams, st: &mut ActuatorState, w: f64, dt: f64) -> (f64, f64) {
    let u = st.control.clamp(-p.max_voltage, p.max_voltage);
    let wm = w * p.gear_ratio;
    let gain = p.efficiency * p.gear_ratio * p.kt;
    if p.inductance > 0.0 {
        // Exact first-order current update at the present speed.
        let iss = (u - p.ke * wm) / p.resistance;
        let k = (-p.resistance * dt / p.inductance).exp();
        st.current = (iss + (st.current - iss) * k).clamp(-p.max_current, p.max_current);
        return (gain * st.current, 0.0);
    }
    let i = (u - p.ke * wm) / p.resistance;
    if i.abs() <= p.max_current {
        // Back-EMF as implicit damping; the voltage term explicit.
        st.current = i;
        (gain * u / p.resistance, p.emf_damping())
    } else {
        st.current = i.clamp(-p.max_current, p.max_current);
        (gain * st.current, 0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn torque_box_follows_the_line() {
        let p = ServoParams { efficiency: 1.0, ..ServoParams::default() };
        let (lo, hi) = p.torque_box(0.0);
        assert!((hi - 2.94).abs() < 1e-12 && (lo + 2.94).abs() < 1e-12);
        let (_, hi) = p.torque_box(p.no_load_speed);
        assert!(hi.abs() < 1e-12);
        let (lo, hi) = p.torque_box(p.no_load_speed * 0.5);
        assert!((hi - 1.47).abs() < 1e-12 && (lo + 2.94).abs() < 1e-12, "{lo} {hi}");
    }

    #[test]
    fn quantisation_and_deadband() {
        let p = ServoParams::default();
        let res = std::f64::consts::TAU / 4096.0;
        assert!((p.measure(0.4 * res)).abs() < 1e-15);
        assert!((p.measure(0.6 * res) - res).abs() < 1e-15);
        assert_eq!(p.error(1.0 * res, 0.0), 0.0);
        assert!(p.error(3.0 * res, 0.0) > 0.0);
    }
}
