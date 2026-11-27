//! Power and heat (docs/research/sota-simulation.md 3.1, 3.2, step 2): a battery equivalent
//! circuit with Bernardi heat and a two-state cell thermal model, lumped thermal networks for
//! motors and ESCs, and the drone powertrain that ties them to the rotors.
//!
//! - Cell: open-circuit voltage `U(soc)`, series resistance `R0(T)` (Arrhenius), two RC pairs
//!   (Plett 2015, vol. I ch. 2). Terminal voltage `V = U - I R0 - v1 - v2` (`I` > 0 discharging).
//!   RC voltages are updated exactly for a current held over the step.
//! - Heat (Bernardi, Pawlikowski and Newman 1985): `q = I (U - V) - I T dU/dT`, the
//!   irreversible overpotential heat plus the reversible entropic heat. `I (U - V)` is
//!   integrated exactly over the step (average RC voltages).
//! - Cell temperature: core and surface nodes (Lin et al. 2014):
//!   `Cc dTc/dt = q + (Ts - Tc) / Rc`, `Cs dTs/dt = (Tamb - Ts) / Ru - (Ts - Tc) / Rc`.
//! - Motors and ESCs: lumped networks (Boglietti et al. 2009): winding, stator, housing nodes
//!   with copper loss `I^2 R(T)` (`R` rising 0.393 % per kelvin) and iron loss `k_fe w^1.5`;
//!   ESC node with conduction `2 I^2 R_ds(on)` and switching `1/2 V I (t_r + t_f) f_sw`.
//!   Networks step exactly (eigen decomposition of the symmetric form) for losses held over the
//!   step, so the analytic solution of a constant-loss step is reproduced to rounding.

use nalgebra::{DMatrix, DVector, SymmetricEigen};
use serde::{Deserialize, Serialize};

use crate::aero::Rotor;

const T0: f64 = 273.15;

/// Equivalent circuit and thermal parameters of one cell. Defaults: a 650 mAh LiPo cell of a
/// 3-inch quad pack. The OCV curve and `r0` match `sim`'s battery (weather.rs); the RC pairs,
/// entropic coefficient and thermal values are typical LiPo figures, not a fit to this cell.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct CellParams {
    pub capacity_ah: f64,
    /// Series resistance at 25 C, ohm.
    pub r0: f64,
    /// Arrhenius activation of `r0`, `Ea / R`, K.
    pub r0_activation: f64,
    pub r1: f64,
    pub c1: f64,
    pub r2: f64,
    pub c2: f64,
    /// Entropic coefficient dU/dT, V/K.
    pub dudt: f64,
    /// Core heat capacity, J/K.
    pub c_core: f64,
    /// Surface heat capacity, J/K.
    pub c_surface: f64,
    /// Core to surface thermal resistance, K/W.
    pub r_core: f64,
    /// Surface to air thermal resistance, K/W.
    pub r_air: f64,
    /// Loaded voltage per cell at which the pack is empty, V.
    pub cutoff: f64,
}

impl Default for CellParams {
    fn default() -> Self {
        CellParams {
            capacity_ah: 0.65,
            r0: 0.012,
            r0_activation: 2500.0,
            r1: 0.004,
            c1: 2000.0,
            r2: 0.003,
            c2: 20000.0,
            dudt: -1.0e-4,
            c_core: 12.0,
            c_surface: 6.0,
            r_core: 3.0,
            r_air: 11.0,
            cutoff: 3.3,
        }
    }
}

impl CellParams {
    /// Open-circuit voltage of a LiPo cell (sim's curve: steep at both ends, flat between).
    pub fn ocv(&self, soc: f64) -> f64 {
        let s = soc.clamp(0.0, 1.0);
        3.3 + 0.9 * s - 0.35 * (-12.0 * s).exp() + 0.1 * (-8.0 * (1.0 - s)).exp()
    }

    /// Series resistance at temperature `t_c` (C).
    pub fn r0_at(&self, t_c: f64) -> f64 {
        self.r0 * (self.r0_activation * (1.0 / (t_c + T0) - 1.0 / (25.0 + T0))).exp()
    }
}

/// A pack of identical cells, `series` x `parallel`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Pack {
    pub cell: CellParams,
    pub series: f64,
    pub parallel: f64,
    /// State of charge, 0..1.
    pub soc: f64,
    /// RC pair voltages, V (per cell).
    pub v1: f64,
    pub v2: f64,
    /// Core and surface temperature, C.
    pub t_core: f64,
    pub t_surface: f64,
    pub ambient: f64,
    /// Pack current (A, discharge positive) and terminal voltage (V) of the last step.
    pub current: f64,
    pub voltage: f64,
    /// Heat totals per pack, J: irreversible `int I (U - V)`, reversible `int -I T dU/dT`.
    pub heat_irreversible: f64,
    pub heat_reversible: f64,
    /// Energy delivered at the terminals, J.
    pub energy_out: f64,
}

impl Pack {
    pub fn new(cell: CellParams, series: f64, parallel: f64, ambient_c: f64) -> Self {
        let v = series * cell.ocv(1.0);
        Pack { cell, series, parallel, soc: 1.0, v1: 0.0, v2: 0.0, t_core: ambient_c, t_surface: ambient_c, ambient: ambient_c, current: 0.0, voltage: v, heat_irreversible: 0.0, heat_reversible: 0.0, energy_out: 0.0 }
    }

    /// Full pack voltage at rest.
    pub fn full_voltage(&self) -> f64 {
        self.series * self.cell.ocv(1.0)
    }

    /// Draws `current` (A, pack) for `dt` s; returns the terminal voltage.
    pub fn step(&mut self, current: f64, dt: f64) -> f64 {
        let c = &self.cell;
        let i = current / self.parallel;
        let r0 = c.r0_at(self.t_core);
        let mut avg = 0.0;
        let mut upd = |v: &mut f64, r: f64, cap: f64| {
            let tau = r * cap;
            let vs = i * r;
            let e = (-dt / tau).exp();
            avg += vs + (*v - vs) * tau / dt * (1.0 - e);
            *v = vs + (*v - vs) * e;
        };
        upd(&mut self.v1, c.r1, c.c1);
        upd(&mut self.v2, c.r2, c.c2);
        // Bernardi heat per cell over the step.
        let q_irr = i * (i * r0 + avg) * dt;
        // (avg is the sum of the two RC voltages averaged over the step.)
        let q_rev = -i * (self.t_core + T0) * c.dudt * dt;
        let ncell = self.series * self.parallel;
        self.heat_irreversible += q_irr * ncell;
        self.heat_reversible += q_rev * ncell;
        // Two-state thermal model, implicit Euler.
        let q = (q_irr + q_rev) / dt;
        let (cc, cs, rc, ru) = (c.c_core, c.c_surface, c.r_core, c.r_air);
        let a11 = cc / dt + 1.0 / rc;
        let a12 = -1.0 / rc;
        let a22 = cs / dt + 1.0 / rc + 1.0 / ru;
        let b1 = cc / dt * self.t_core + q;
        let b2 = cs / dt * self.t_surface + self.ambient / ru;
        let det = a11 * a22 - a12 * a12;
        self.t_core = (b1 * a22 - a12 * b2) / det;
        self.t_surface = (a11 * b2 - a12 * b1) / det;
        let soc0 = self.soc;
        self.soc = (self.soc - i * dt / (3600.0 * c.capacity_ah)).max(0.0);
        let v_cell = c.ocv(self.soc) - i * r0 - self.v1 - self.v2;
        self.current = current;
        self.voltage = self.series * v_cell;
        // Terminal energy at the step's mean voltage (OCV at the mid charge, mean RC voltages),
        // so that delivered energy plus irreversible heat is the chemical energy `int I U dt`.
        let u_mid = c.ocv(0.5 * (soc0 + self.soc));
        self.energy_out += self.series * (u_mid - i * r0 - avg) * current * dt;
        self.voltage
    }

    /// Loaded voltage per cell.
    pub fn cell_voltage(&self) -> f64 {
        self.voltage / self.series
    }

    /// Empty: under the cutoff voltage or out of charge.
    pub fn empty(&self) -> bool {
        self.cell_voltage() < self.cell.cutoff || self.soc <= 0.0
    }
}

/// A lumped thermal network: node heat capacities, conductances between nodes and to the
/// ambient. Stepped exactly for losses held over the step.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ThermalNetwork {
    pub names: Vec<String>,
    /// J/K per node.
    pub capacity: Vec<f64>,
    /// `(a, b, W/K)` between nodes.
    pub links: Vec<(usize, usize, f64)>,
    /// W/K from each node to the ambient.
    pub to_ambient: Vec<f64>,
    /// Node temperatures, C.
    pub t: Vec<f64>,
    pub ambient: f64,
    #[serde(skip)]
    eig: Option<(DMatrix<f64>, DVector<f64>, DMatrix<f64>)>,
}

impl ThermalNetwork {
    pub fn new(names: &[&str], capacity: Vec<f64>, links: Vec<(usize, usize, f64)>, to_ambient: Vec<f64>, ambient: f64) -> Self {
        let n = capacity.len();
        ThermalNetwork { names: names.iter().map(|s| s.to_string()).collect(), capacity, links, to_ambient, t: vec![ambient; n], ambient, eig: None }
    }

    fn conductance(&self) -> DMatrix<f64> {
        let n = self.capacity.len();
        let mut g = DMatrix::zeros(n, n);
        for &(a, b, k) in &self.links {
            g[(a, a)] += k;
            g[(b, b)] += k;
            g[(a, b)] -= k;
            g[(b, a)] -= k;
        }
        for i in 0..n {
            g[(i, i)] += self.to_ambient[i];
        }
        g
    }

    /// Advances `dt` with node losses `p` (W).
    pub fn step(&mut self, p: &[f64], dt: f64) {
        let n = self.capacity.len();
        if self.eig.is_none() {
            // S = C^-1/2 G C^-1/2 (symmetric), eigen S = V L V^T.
            let g = self.conductance();
            let cs: Vec<f64> = self.capacity.iter().map(|c| 1.0 / c.sqrt()).collect();
            let s = DMatrix::from_fn(n, n, |i, j| g[(i, j)] * cs[i] * cs[j]);
            let e = SymmetricEigen::new(s.clone());
            self.eig = Some((s, e.eigenvalues, e.eigenvectors));
        }
        let (s, lam, vecs) = self.eig.as_ref().unwrap();
        let ch: Vec<f64> = self.capacity.iter().map(|c| c.sqrt()).collect();
        // x = C^1/2 T; dx/dt = -S x + C^-1/2 (p + g_amb T_amb).
        let b = DVector::from_fn(n, |i, _| (p[i] + self.to_ambient[i] * self.ambient) / ch[i]);
        let x = DVector::from_fn(n, |i, _| self.t[i] * ch[i]);
        let xss = s.clone().lu().solve(&b).unwrap_or_else(|| x.clone());
        let d = vecs.transpose() * (x - &xss);
        let d = DVector::from_fn(n, |i, _| d[i] * (-lam[i] * dt).exp());
        let xn = xss + vecs * d;
        for i in 0..n {
            self.t[i] = xn[i] / ch[i];
        }
    }

    /// Temperature by node name.
    pub fn temp(&self, name: &str) -> Option<f64> {
        self.names.iter().position(|n| n == name).map(|i| self.t[i])
    }
}

/// A brushless motor's electrical and thermal model. Defaults: a 1404 4600 KV class motor.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct MotorThermalParams {
    /// Phase resistance at 25 C, ohm.
    pub resistance: f64,
    /// Iron loss coefficient, W per (rad/s)^1.5.
    pub k_iron: f64,
    pub c_winding: f64,
    pub c_stator: f64,
    pub c_housing: f64,
    pub g_winding_stator: f64,
    pub g_stator_housing: f64,
    pub g_housing_air: f64,
}

impl Default for MotorThermalParams {
    fn default() -> Self {
        MotorThermalParams { resistance: 0.18, k_iron: 2.0e-6, c_winding: 1.5, c_stator: 3.0, c_housing: 4.0, g_winding_stator: 0.5, g_stator_housing: 0.3, g_housing_air: 0.15 }
    }
}

/// An ESC's losses and thermal node. Defaults: a small 4-in-1 board, one channel.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct EscParams {
    /// MOSFET on resistance, ohm.
    pub r_ds_on: f64,
    /// Rise plus fall time, s.
    pub t_switch: f64,
    /// PWM frequency, Hz.
    pub f_pwm: f64,
    pub capacity: f64,
    pub g_air: f64,
}

impl Default for EscParams {
    fn default() -> Self {
        EscParams { r_ds_on: 0.005, t_switch: 50e-9, f_pwm: 24000.0, capacity: 2.0, g_air: 0.1 }
    }
}

/// Copper resistance at temperature `t` (C) from its 25 C value.
pub fn copper(r25: f64, t: f64) -> f64 {
    r25 * (1.0 + 0.00393 * (t - 25.0))
}

/// Motor losses (W) at current `i` (A), speed `w` (rad/s), winding temperature `tw` (C).
pub fn motor_losses(p: &MotorThermalParams, i: f64, w: f64, tw: f64) -> (f64, f64) {
    (i * i * copper(p.resistance, tw), p.k_iron * w.abs().powf(1.5))
}

/// ESC losses (W) at current `i` and bus voltage `v`.
pub fn esc_losses(p: &EscParams, i: f64, v: f64) -> f64 {
    2.0 * i * i * p.r_ds_on + 0.5 * v * i.abs() * p.t_switch * p.f_pwm
}

/// The drone powertrain: pack, one motor network and one ESC node per rotor. Motor current
/// follows sim's thrust law `0.3 + (I_peak - 0.3) (T / T_max)^1.5` (weather.rs), so the
/// two simulators draw the same current for the same thrust.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Powertrain {
    pub pack: Pack,
    pub motor: MotorThermalParams,
    pub esc: EscParams,
    pub motors: Vec<ThermalNetwork>,
    pub escs: Vec<ThermalNetwork>,
    /// Thrust of one motor at full throttle on a charged pack, N.
    pub max_thrust: f64,
    /// Current of one motor at full throttle, A.
    pub peak_current: f64,
    /// Avionics draw, A.
    pub avionics: f64,
    pub time: f64,
}

impl Powertrain {
    pub fn new(pack: Pack, motor: MotorThermalParams, esc: EscParams, rotors: usize, max_thrust: f64, peak_current: f64) -> Self {
        let amb = pack.ambient;
        let net = |m: &MotorThermalParams| ThermalNetwork::new(&["winding", "stator", "housing"], vec![m.c_winding, m.c_stator, m.c_housing], vec![(0, 1, m.g_winding_stator), (1, 2, m.g_stator_housing)], vec![0.0, 0.0, m.g_housing_air], amb);
        let esc_net = |e: &EscParams| ThermalNetwork::new(&["esc"], vec![e.capacity], vec![], vec![e.g_air], amb);
        Powertrain { motors: (0..rotors).map(|_| net(&motor)).collect(), escs: (0..rotors).map(|_| esc_net(&esc)).collect(), pack, motor, esc, max_thrust, peak_current, avionics: 0.3, time: 0.0 }
    }

    /// Rotor speed cap from voltage sag: loaded pack voltage over the nominal 3.8 V per cell,
    /// at most 1 (as sim's flight.rs: `volts / 11.4` on 3S).
    pub fn omega_scale(&self) -> f64 {
        (self.pack.voltage / (3.8 * self.pack.series)).clamp(0.0, 1.0)
    }

    /// Current of one motor making thrust `t` (N).
    pub fn motor_current(&self, t: f64) -> f64 {
        0.3 + (self.peak_current - 0.3).max(0.0) * (t.max(0.0) / self.max_thrust).powf(1.5)
    }

    pub fn step(&mut self, rotors: &[Rotor], omega: &[f64], dt: f64) {
        let mut total = self.avionics;
        let mut currents = Vec::with_capacity(rotors.len());
        for (r, w) in rotors.iter().zip(omega) {
            let i = self.motor_current(r.k_t * w * w);
            currents.push(i);
            total += i;
        }
        let v = self.pack.voltage;
        for (k, (&i, w)) in currents.iter().zip(omega).enumerate() {
            let tw = self.motors[k].t[0];
            let (cu, fe) = motor_losses(&self.motor, i, *w, tw);
            self.motors[k].step(&[cu, fe, 0.0], dt);
            let pe = esc_losses(&self.esc, i, v);
            self.escs[k].step(&[pe], dt);
        }
        self.pack.step(total, dt);
        self.time += dt;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ocv_is_monotone() {
        let c = CellParams::default();
        let mut last = 0.0;
        for k in 0..=100 {
            let u = c.ocv(k as f64 / 100.0);
            assert!(u > last);
            last = u;
        }
        assert!((c.ocv(1.0) - 4.3).abs() < 0.01, "sim's curve tops out at 4.3 V");
    }
}
