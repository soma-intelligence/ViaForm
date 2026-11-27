//! One simulated environment: state, controls, and the time step.
//!
//! Step (semi-implicit Euler, RUST-ENGINES 6.2): rotor speeds, then the unconstrained next
//! velocity `v* = v + dt (M + dt D + dt^2 K)^-1 (tau - c(q, v) - D v - K (q - rest) - dt K v)` by
//! the ABA (damping, springs, armature and DC back-EMF implicit), then the constraint set
//! (contacts, joint limits, linkages, joint friction, servos, tendons) and, when it is not empty,
//! the convex solve on `A = M + dt D + dt^2 K` from the CRBA, then `q <- q (+) dt v`.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use viaform_kin::model::JointKind;
use viaform_kin::{Iso3, UnitQuat};

use crate::actuator::{ActuatorKind, ActuatorState, dc_step, servo_row};
use crate::aero::{Air, ground_effect, spin_up};
use crate::contact::{Collider, Contact, tangents};
use crate::dynamics::{Ws, aba, angular_jacobian_col, crba, kinematics, point_jacobian_col, rnea, velocities};
use crate::error::{PhysError, codes, params};
use crate::model::PhysModel;
use crate::power::Powertrain;
use crate::record::Recorder;
use crate::solver::{Kind, Problem, Reg, SolveStats, Solver, SolverSettings};
use crate::spatial::{V3, V6, v6};
use crate::tendon;

/// Time integration scheme.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Integrator {
    /// Semi-implicit (symplectic) Euler with the convex constraint solve. The default.
    #[default]
    SemiImplicit,
    /// Classical Runge-Kutta 4 on the smooth dynamics; constraints are ignored (validation
    /// of energy, free flight). Falls back to semi-implicit when constraints are active.
    Rk4,
}

/// World settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// Step, s (1 ms default, RUST-ENGINES 6.2).
    pub dt: f64,
    /// Gravity, m/s^2, world frame (Z up).
    pub gravity: [f64; 3],
    pub integrator: Integrator,
    pub solver: SolverSettings,
    pub air: Air,
    /// Joint limit rows are added when a joint is closer than this to a limit, rad or m.
    pub limit_margin: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { dt: 0.001, gravity: [0.0, 0.0, -9.81], integrator: Integrator::SemiImplicit, solver: SolverSettings::default(), air: Air::default(), limit_margin: 0.02 }
    }
}

/// An external wrench on a link (world frame) for a time window.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExtForce {
    pub link: usize,
    pub force: [f64; 3],
    /// World point where the force acts.
    pub point: [f64; 3],
    #[serde(default)]
    pub torque: [f64; 3],
    /// Active while `t < until` (infinite: until cleared).
    #[serde(default = "inf")]
    pub until: f64,
}

fn inf() -> f64 {
    f64::INFINITY
}

/// A contact of the last step with its force.
#[derive(Clone, Copy, Debug)]
pub struct ContactForce {
    pub contact: Contact,
    /// Force on body 2 (body 1 gets the opposite), N, world frame.
    pub force: V3,
}

/// One environment.
#[derive(Clone)]
pub struct World {
    pub model: Arc<PhysModel>,
    pub settings: Settings,
    pub q: Vec<f64>,
    pub v: Vec<f64>,
    pub t: f64,
    pub steps: u64,
    pub act: Vec<ActuatorState>,
    pub rotor_cmd: Vec<f64>,
    pub rotor_omega: Vec<f64>,
    /// Loaded pack voltage over a full pack's (caps rotor speed), from the powertrain.
    pub omega_scale: f64,
    pub ext: Vec<ExtForce>,
    pub powertrain: Option<Powertrain>,
    pub recorder: Option<Recorder>,
    pub stats: SolveStats,
    pub contacts: Vec<ContactForce>,
    pub ws: Ws,
    collider: Collider,
    solver: Solver,
    problem: Problem,
    found: Vec<Contact>,
    contact_blocks: Vec<usize>,
    tendon_blocks: Vec<(usize, usize)>,
    act_blocks: Vec<(usize, usize)>,
    buf: Buffers,
}

#[derive(Clone, Debug, Default)]
struct Buffers {
    tau: Vec<f64>,
    arm: Vec<f64>,
    qdd: Vec<f64>,
    vstar: Vec<f64>,
    vnext: Vec<f64>,
    a: Vec<f64>,
    fext: Vec<V6>,
    arms: Vec<f64>,
    cols: Vec<usize>,
    k: [Vec<f64>; 8],
}

impl World {
    pub fn new(model: Arc<PhysModel>, settings: Settings) -> Self {
        let nv = model.nv();
        let nl = model.nlinks();
        let q = model.kin.neutral();
        let na = model.actuators.len();
        let nr = model.rotors.len();
        let collider = Collider::new(&model);
        let ws = Ws::new(&model);
        let mut w = World {
            settings,
            q,
            v: vec![0.0; nv],
            t: 0.0,
            steps: 0,
            act: vec![ActuatorState::default(); na],
            rotor_cmd: vec![0.0; nr],
            rotor_omega: vec![0.0; nr],
            omega_scale: 1.0,
            ext: vec![],
            powertrain: None,
            recorder: None,
            stats: SolveStats::default(),
            contacts: vec![],
            ws,
            collider,
            solver: Solver::default(),
            problem: Problem::default(),
            found: vec![],
            contact_blocks: vec![],
            tendon_blocks: vec![],
            act_blocks: vec![],
            buf: Buffers::default(),
            model,
        };
        w.buf.tau = vec![0.0; nv];
        w.buf.arm = vec![0.0; nv];
        w.buf.qdd = vec![0.0; nv];
        w.buf.vstar = vec![0.0; nv];
        w.buf.vnext = vec![0.0; nv];
        w.buf.a = vec![0.0; nv * nv];
        w.buf.fext = vec![V6::zeros(); nl];
        w.buf.arms = vec![0.0; nv];
        for k in 0..8 {
            w.buf.k[k] = vec![0.0; nv.max(w.q.len())];
        }
        // Servos hold where they start; tendon motors start slack-free at zero excursion.
        w.hold_servos();
        kinematics(&w.model, &w.q, &mut w.ws);
        w
    }

    pub fn gravity(&self) -> V3 {
        V3::new(self.settings.gravity[0], self.settings.gravity[1], self.settings.gravity[2])
    }

    /// Servo targets set to the present positions (and backlash engaged).
    pub fn hold_servos(&mut self) {
        for a in 0..self.act.len() {
            if let (ActuatorKind::Servo(_), Some(m)) = (&self.model.actuators[a], &self.model.actuator_map[a]) {
                self.act[a].control = (self.q[m.qi] - m.offset) / m.gain;
            }
        }
    }

    /// Sets the configuration (checked) and zero velocity; servo targets follow.
    pub fn set_q(&mut self, q: &[f64]) -> Result<(), PhysError> {
        self.model.kin.check_q(q)?;
        self.q.copy_from_slice(q);
        normalize_quats(&self.model, &mut self.q);
        self.v.iter_mut().for_each(|x| *x = 0.0);
        self.hold_servos();
        kinematics(&self.model, &self.q, &mut self.ws);
        Ok(())
    }

    /// Sets the velocity.
    pub fn set_v(&mut self, v: &[f64]) -> Result<(), PhysError> {
        if v.len() != self.v.len() || v.iter().any(|x| !x.is_finite()) {
            return Err(params(format!("v needs {} finite values", self.v.len())));
        }
        self.v.copy_from_slice(v);
        Ok(())
    }

    /// Sets the control of actuator `a` (see [`ActuatorKind`] for its meaning).
    pub fn set_control(&mut self, a: usize, value: f64) {
        self.act[a].control = value;
    }

    /// Sets the pose of a free body (floating joint of link `link`), world frame.
    pub fn set_free_pose(&mut self, link: usize, pose: &Iso3) -> Result<(), PhysError> {
        let j = link.checked_sub(1).filter(|&j| j < self.model.joints.len()).ok_or_else(|| params("no such link"))?;
        let jt = &self.model.joints[j];
        if jt.kind != JointKind::Floating {
            return Err(params("the link is not a free body"));
        }
        // q is the pose relative to the joint frame (parent * origin).
        let rel = (self.ws.poses[jt.parent] * jt.origin).inverse() * pose;
        let o = jt.qo;
        self.q[o..o + 3].copy_from_slice(rel.translation.vector.as_slice());
        let r = rel.rotation.quaternion();
        self.q[o + 3..o + 7].copy_from_slice(&[r.w, r.i, r.j, r.k]);
        kinematics(&self.model, &self.q, &mut self.ws);
        Ok(())
    }

    /// World poses of all links for the present `q`.
    pub fn poses(&mut self) -> &[Iso3] {
        kinematics(&self.model, &self.q, &mut self.ws);
        &self.ws.poses
    }

    /// Link poses as `[x, y, z, qw, qx, qy, qz]` per link into `out` (7 per link); returns the
    /// number of links written.
    pub fn poses_flat(&mut self, out: &mut [f64]) -> usize {
        kinematics(&self.model, &self.q, &mut self.ws);
        let n = (out.len() / 7).min(self.ws.poses.len());
        for (i, p) in self.ws.poses.iter().take(n).enumerate() {
            out[i * 7..i * 7 + 7].copy_from_slice(&viaform_kin::math::pose_to7(p));
        }
        n
    }

    /// Total mechanical energy (kinetic plus gravity potential), J.
    pub fn energy(&mut self) -> f64 {
        kinematics(&self.model, &self.q, &mut self.ws);
        let g = self.gravity();
        crate::dynamics::kinetic_energy(&self.model, &self.v, &mut self.ws) + crate::dynamics::potential_energy(&self.model, &g, &self.ws)
    }

    /// Advances `n` steps.
    pub fn run(&mut self, n: usize) -> Result<(), PhysError> {
        for _ in 0..n {
            self.step()?;
        }
        Ok(())
    }

    /// External forces, rotor and drag forces as spatial forces per link (link coordinates);
    /// needs kinematics and velocities.
    fn body_forces(&mut self) {
        let m = &self.model;
        let ws = &self.ws;
        let fext = &mut self.buf.fext;
        fext.iter_mut().for_each(|f| *f = V6::zeros());
        let world_force = |fext: &mut Vec<V6>, link: usize, f: V3, p: V3, tq: V3| {
            let fw = v6(&(tq + p.cross(&f)), &f);
            fext[link] += ws.xw[link].force(&fw);
        };
        for e in &self.ext {
            if self.t < e.until {
                world_force(fext, e.link, V3::from(e.force), V3::from(e.point), V3::from(e.torque));
            }
        }
        let air = &self.settings.air;
        let dens = air.density / crate::aero::RHO;
        for (i, r) in m.rotors.iter().enumerate() {
            let pose = &ws.poses[r.link];
            let ge = if air.ground_effect { ground_effect(r.radius, pose.translation.vector.z + air.ground_offset) } else { 1.0 };
            let w2 = self.rotor_omega[i] * self.rotor_omega[i];
            let thrust = r.k_t * w2 * dens * ge;
            let torque = r.spin * r.k_q * w2 * dens;
            // Link-frame wrench at the link origin: thrust at the hub plus the reaction torque.
            let f = r.axis * thrust;
            let n = r.pos.cross(&f) + r.axis * torque;
            fext[r.link] += v6(&n, &f);
        }
        let wind = V3::from(air.wind);
        for d in &m.drags {
            let pose = &ws.poses[d.link];
            let rot = pose.rotation;
            // World velocity of the link origin.
            let vb = &ws.vel[d.link];
            let v_body = V3::new(vb[3], vb[4], vb[5]);
            let rel = v_body - rot.inverse() * wind;
            let f = V3::from_fn(|k, _| dens * (-d.linear[k] * rel[k] - d.quadratic[k] * rel[k] * rel[k].abs()));
            fext[d.link] += v6(&V3::zeros(), &f);
        }
    }

    /// One time step.
    pub fn step(&mut self) -> Result<(), PhysError> {
        let dt = self.settings.dt;
        if !(dt > 0.0) {
            return Err(params("dt must be positive"));
        }
        // Powertrain (voltage sag) and rotor speeds.
        if let Some(pt) = &self.powertrain {
            self.omega_scale = pt.omega_scale();
        }
        for (i, r) in self.model.rotors.iter().enumerate() {
            self.rotor_omega[i] = spin_up(r, self.rotor_omega[i], self.rotor_cmd[i], self.omega_scale, dt);
        }
        let model = self.model.clone();
        let m = &*model;
        kinematics(m, &self.q, &mut self.ws);
        velocities(m, &self.v, &mut self.ws);
        self.body_forces();
        let g = self.gravity();
        let nv = m.nv();
        // Generalised forces and implicit diagonal terms.
        for i in 0..nv {
            let j = m.dof_joint[i];
            let p = &m.params[j];
            let scalar = m.joints[j].kind.is_scalar();
            let k = if scalar { p.stiffness } else { 0.0 };
            self.buf.arm[i] = p.armature + dt * p.damping + dt * dt * k;
            let spring = if scalar { -k * (self.q[m.joints[j].qo] - p.rest) } else { 0.0 };
            self.buf.tau[i] = spring - (p.damping + dt * k) * self.v[i];
        }
        // Actuators: explicit efforts, DC back-EMF, servo rows planned below.
        let mut servo_rows = vec![];
        for a in 0..m.actuators.len() {
            let Some(map) = &m.actuator_map[a] else {
                if let ActuatorKind::TendonMotor { max_speed } = m.actuators[a] {
                    let st = &mut self.act[a];
                    let d = (st.control - st.excursion).clamp(-max_speed * dt, max_speed * dt);
                    st.excursion += d;
                    st.excursion_rate = d / dt;
                }
                continue;
            };
            let pos = (self.q[map.qi] - map.offset) / map.gain;
            let vel = self.v[map.vi] / map.gain;
            match &m.actuators[a] {
                ActuatorKind::Torque => {
                    let lim = m.kin.actuators[a].limits.effort;
                    let e = self.act[a].control.clamp(-lim, lim);
                    self.act[a].effort = e;
                    self.buf.tau[map.vi] += e / map.gain;
                }
                ActuatorKind::Dc(p) => {
                    let (e, d) = dc_step(p, &mut self.act[a], vel, dt);
                    self.buf.tau[map.vi] += e / map.gain - d / (map.gain * map.gain) * self.v[map.vi];
                    self.buf.arm[map.vi] += dt * d / (map.gain * map.gain);
                    self.act[a].effort = e - d * vel;
                }
                ActuatorKind::Servo(p) => {
                    if let Some(row) = servo_row(p, &mut self.act[a], pos, vel, dt) {
                        servo_rows.push((a, map.vi, 1.0 / map.gain, row));
                    } else {
                        self.act[a].effort = 0.0;
                    }
                }
                ActuatorKind::TendonMotor { .. } => {}
            }
        }
        // Unconstrained velocity.
        let fext = std::mem::take(&mut self.buf.fext);
        aba(m, &self.v, &self.buf.tau, Some(&fext), &self.buf.arm, &g, &mut self.ws, &mut self.buf.qdd);
        for i in 0..nv {
            self.buf.vstar[i] = self.v[i] + dt * self.buf.qdd[i];
        }
        // Constraints.
        self.build_constraints(&servo_rows);
        let constrained = !self.problem.blocks.is_empty();
        if self.settings.integrator == Integrator::Rk4 && !constrained {
            self.buf.fext = fext;
            self.rk4(dt, &g);
        } else {
            if constrained {
                crba(m, &self.buf.arm, &mut self.ws);
                for r in 0..nv {
                    for c in 0..nv {
                        self.buf.a[r * nv + c] = self.ws.h[(r, c)];
                    }
                }
                let mut vnext = std::mem::take(&mut self.buf.vnext);
                self.stats = self.solver.solve(&mut self.problem, &self.buf.a, &self.buf.vstar, &self.v, dt, &self.settings.solver, &mut vnext);
                self.buf.vnext = vnext;
            } else {
                self.buf.vnext.copy_from_slice(&self.buf.vstar);
                self.stats = SolveStats::default();
            }
            self.buf.fext = fext;
            self.post_solve(dt, &servo_rows);
            // Record before q moves (wrenches at the start-of-step state).
            if self.recorder.as_ref().is_some_and(|r| r.due(self.steps)) {
                self.record(dt, &g);
            }
            let vnext = std::mem::take(&mut self.buf.vnext);
            self.v.copy_from_slice(&vnext);
            self.buf.vnext = vnext;
            integrate_in_place(m, &mut self.q, &self.v, dt);
        }
        if let Some(pt) = &mut self.powertrain {
            pt.step(&self.model.rotors, &self.rotor_omega, dt);
        }
        self.t += dt;
        self.steps += 1;
        if self.q.iter().chain(self.v.iter()).any(|x| !x.is_finite()) {
            return Err(PhysError::new(codes::DIVERGED, format!("the state is not finite at t = {:.4} s", self.t)));
        }
        Ok(())
    }

    fn build_constraints(&mut self, servo_rows: &[(usize, usize, f64, crate::actuator::BoxRow)]) {
        let model = self.model.clone();
        let m = &*model;
        let dt = self.settings.dt;
        let cp = &m.contact;
        self.problem.clear();
        self.contact_blocks.clear();
        self.tendon_blocks.clear();
        self.act_blocks.clear();
        // Contacts.
        self.collider.detect(m, &self.ws, &mut self.found);
        for ci in 0..self.found.len() {
            let c = self.found[ci];
            let cols = &mut self.buf.cols;
            cols.clear();
            cols.extend_from_slice(&m.support[c.b1]);
            for &k in &m.support[c.b2] {
                if !cols.contains(&k) {
                    cols.push(k);
                }
            }
            cols.sort_unstable();
            let (t1, t2) = tangents(&c.n);
            let vhat = [0.0, 0.0, -c.dist / (dt + cp.dissipation)];
            let b = self.problem.push(Kind::Cone { mu: c.mu }, Reg::Compliant { k: cp.stiffness, tau_d: cp.dissipation, beta: cp.beta, sigma: cp.sigma }, &self.buf.cols, vhat);
            let ncols = self.buf.cols.len();
            for (r, dir) in [t1, t2, c.n].iter().enumerate() {
                for x in 0..ncols {
                    let k = self.buf.cols[x];
                    let jc = point_jacobian_col(&self.ws, k, &c.p);
                    let s1 = if m.support[c.b1].binary_search(&k).is_ok() { 1.0 } else { 0.0 };
                    let s2 = if m.support[c.b2].binary_search(&k).is_ok() { 1.0 } else { 0.0 };
                    self.problem.row_mut(b, r)[x] = dir.dot(&jc) * (s2 - s1);
                }
            }
            // Gliding compensation: the convex relaxation lets a sliding contact separate at
            // `mu |v_t|` (Anitescu 2006; Castro et al. 2023 section VIII). The bias takes the
            // start-of-step slip speed off the normal target so a sliding body stays on its
            // support. Sticking contacts (no slip) are unchanged.
            let mut vt = [0.0; 2];
            for (r, slot) in vt.iter_mut().enumerate() {
                let vals = self.problem.row_mut(b, r);
                *slot = (0..ncols).map(|x| vals[x] * self.v[self.buf.cols[x]]).sum();
            }
            let slip = (vt[0] * vt[0] + vt[1] * vt[1]).sqrt();
            self.problem.blocks[b].vhat[2] -= c.mu * slip;
            self.contact_blocks.push(b);
        }
        // Joint limits.
        let lim_reg = Reg::Compliant { k: cp.stiffness, tau_d: cp.dissipation, beta: cp.beta, sigma: cp.sigma };
        for (j, jt) in m.joints.iter().enumerate() {
            if !jt.kind.is_bounded() {
                continue;
            }
            let l = &m.kin.joints[j].limits;
            let (qv, vi) = (self.q[jt.qo], jt.vo);
            let reach = self.settings.limit_margin + self.v[vi].abs() * dt;
            if l.lower.is_finite() && qv - l.lower < reach {
                let b = self.problem.push(Kind::Interval { lo: 0.0, hi: f64::INFINITY }, lim_reg, &[vi], [-(qv - l.lower) / (dt + cp.dissipation), 0.0, 0.0]);
                self.problem.row_mut(b, 0)[0] = 1.0;
            }
            if l.upper.is_finite() && l.upper - qv < reach {
                let b = self.problem.push(Kind::Interval { lo: 0.0, hi: f64::INFINITY }, lim_reg, &[vi], [-(l.upper - qv) / (dt + cp.dissipation), 0.0, 0.0]);
                self.problem.row_mut(b, 0)[0] = -1.0;
            }
        }
        // Linkage equalities: near rigid (a hundredth of the SAP floor `beta`), so a loaded
        // linkage keeps its ratio; the rows are bilateral and linear, so Newton stays exact.
        let eq_reg = Reg::Compliant { k: 0.0, tau_d: cp.dissipation, beta: 0.01, sigma: cp.sigma };
        for e in &m.equalities {
            let phi = (self.q[e.qa] - e.off_a) - e.ratio * (self.q[e.qb] - e.off_b);
            let mut cols = [e.va, e.vb];
            let mut vals = [1.0, -e.ratio];
            if cols[0] > cols[1] {
                cols.swap(0, 1);
                vals.swap(0, 1);
            }
            let b = self.problem.push(Kind::Interval { lo: f64::NEG_INFINITY, hi: f64::INFINITY }, eq_reg, &cols, [-phi / (dt + cp.dissipation), 0.0, 0.0]);
            self.problem.row_mut(b, 0).copy_from_slice(&vals);
        }
        // Joint dry friction.
        for (j, jt) in m.joints.iter().enumerate() {
            let f = m.params[j].friction;
            if f > 0.0 && jt.kind.is_scalar() {
                let b = self.problem.push(Kind::Interval { lo: -f * dt, hi: f * dt }, Reg::Friction { sigma: cp.sigma }, &[jt.vo], [0.0; 3]);
                self.problem.row_mut(b, 0)[0] = 1.0;
            }
        }
        // Servos.
        for &(a, vi, scale, row) in servo_rows {
            let b = self.problem.push(Kind::Interval { lo: row.lo, hi: row.hi }, Reg::Given([row.r; 3]), &[vi], [row.vhat, 0.0, 0.0]);
            self.problem.row_mut(b, 0)[0] = scale;
            self.act_blocks.push((a, b));
        }
        // Tendons.
        for (ti, t) in m.tendons.iter().enumerate() {
            let e = tendon::geometry(m, t, &self.q, &self.ws, &mut self.buf.arms);
            let st = &self.act[t.actuator];
            let stretch = st.excursion - e - t.slack;
            let tau_d = t.damping / t.stiffness;
            let r = 1.0 / (dt * t.stiffness * (dt + tau_d));
            let vhat = st.excursion_rate + stretch / (dt + tau_d);
            self.buf.cols.clear();
            for (k, x) in self.buf.arms.iter().enumerate() {
                if *x != 0.0 {
                    self.buf.cols.push(k);
                }
            }
            let hi = if t.max_tension.is_finite() { t.max_tension * dt } else { f64::INFINITY };
            let b = self.problem.push(Kind::Interval { lo: 0.0, hi }, Reg::Given([r; 3]), &self.buf.cols, [vhat, 0.0, 0.0]);
            for x in 0..self.buf.cols.len() {
                let k = self.buf.cols[x];
                self.problem.row_mut(b, 0)[x] = self.buf.arms[k];
            }
            self.tendon_blocks.push((ti, b));
        }
    }

    /// Impulse offsets of each block.
    fn block_rows(&self) -> Vec<usize> {
        let mut out = Vec::with_capacity(self.problem.blocks.len());
        let mut r = 0;
        for b in &self.problem.blocks {
            out.push(r);
            r += b.dim;
        }
        out
    }

    fn post_solve(&mut self, dt: f64, _servo_rows: &[(usize, usize, f64, crate::actuator::BoxRow)]) {
        let rows = self.block_rows();
        let gamma = &self.solver.gamma;
        self.contacts.clear();
        for (ci, &b) in self.contact_blocks.iter().enumerate() {
            let c = self.found[ci];
            let r = rows[b];
            let (t1, t2) = tangents(&c.n);
            let f = (t1 * gamma[r] + t2 * gamma[r + 1] + c.n * gamma[r + 2]) / dt;
            self.contacts.push(ContactForce { contact: c, force: f });
        }
        for &(a, b) in &self.act_blocks {
            self.act[a].effort = gamma[rows[b]] / dt;
        }
        for &(ti, b) in &self.tendon_blocks {
            let a = self.model.tendons[ti].actuator;
            self.act[a].effort = gamma[rows[b]] / dt;
        }
    }

    /// Classical RK4 in coordinates: `qdot` from `v` (quaternion rates `1/2 q w`, floating
    /// positions `R v_lin`), quaternions renormalised at each stage and at the end.
    fn rk4(&mut self, dt: f64, g: &V3) {
        let model = self.model.clone();
        let m = &*model;
        let (nq, nv) = (m.nq(), m.nv());
        let q0 = self.q.clone();
        let v0 = self.v.clone();
        let fext = std::mem::take(&mut self.buf.fext);
        let tau = self.buf.tau.clone();
        let arm: Vec<f64> = (0..nv).map(|i| m.params[m.dof_joint[i]].armature).collect();
        let mut kq = [vec![0.0; nq], vec![0.0; nq], vec![0.0; nq], vec![0.0; nq]];
        let mut kv = [vec![0.0; nv], vec![0.0; nv], vec![0.0; nv], vec![0.0; nv]];
        let (mut qs, mut vs) = (q0.clone(), v0.clone());
        for stage in 0..4 {
            normalize_quats(m, &mut qs);
            kinematics(m, &qs, &mut self.ws);
            aba(m, &vs, &tau, Some(&fext), &arm, g, &mut self.ws, &mut kv[stage]);
            qdot(m, &qs, &vs, &mut kq[stage]);
            if stage < 3 {
                let c = if stage < 2 { 0.5 * dt } else { dt };
                for i in 0..nq {
                    qs[i] = q0[i] + c * kq[stage][i];
                }
                for i in 0..nv {
                    vs[i] = v0[i] + c * kv[stage][i];
                }
            }
        }
        for i in 0..nq {
            self.q[i] = q0[i] + dt * (kq[0][i] + 2.0 * kq[1][i] + 2.0 * kq[2][i] + kq[3][i]) / 6.0;
        }
        for i in 0..nv {
            self.v[i] = v0[i] + dt * (kv[0][i] + 2.0 * kv[1][i] + 2.0 * kv[2][i] + kv[3][i]) / 6.0;
        }
        normalize_quats(m, &mut self.q);
        self.buf.fext = fext;
    }

    /// Writes one sample of the wrench history (RNEA with the solved acceleration and the
    /// contact forces as external forces).
    fn record(&mut self, dt: f64, g: &V3) {
        let model = self.model.clone();
        let m = &*model;
        let nv = m.nv();
        let nl = m.nlinks();
        let qdd: Vec<f64> = (0..nv).map(|i| (self.buf.vnext[i] - self.v[i]) / dt).collect();
        // External forces: rotors, drag, user forces, plus contacts.
        let mut fext = self.buf.fext.clone();
        let mut contact_w = vec![(V3::zeros(), V3::zeros(), V3::zeros(), 0.0); nl];
        for cf in &self.contacts {
            let c = &cf.contact;
            for (link, f) in [(c.b2, cf.force), (c.b1, -cf.force)] {
                if link == 0 {
                    continue;
                }
                let fw = v6(&c.p.cross(&f), &f);
                fext[link] += self.ws.xw[link].force(&fw);
                let e = &mut contact_w[link];
                e.0 += f;
                e.1 += c.p.cross(&f);
                let wgt = f.norm();
                e.2 += c.p * wgt;
                e.3 += wgt;
            }
        }
        kinematics(m, &self.q, &mut self.ws);
        let mut tau = vec![0.0; nv];
        rnea(m, &self.v, &qdd, Some(&fext), g, &mut self.ws, &mut tau);
        let ws = &self.ws;
        let t = self.t;
        let Some(rec) = self.recorder.as_mut() else { return };
        rec.push_sample(m, ws, t, g, &contact_w, &self.q, &self.act);
    }
}

/// `q <- q (+) dt v` in place (kin's convention: scalar joints add, spherical and floating
/// joints compose on the right in the child frame), quaternions renormalised.
pub fn integrate_in_place(m: &PhysModel, q: &mut [f64], v: &[f64], dt: f64) {
    for jt in &m.joints {
        let (kq, kv) = (jt.qo, jt.vo);
        match jt.kind {
            JointKind::Fixed => {}
            JointKind::Spherical => {
                let r = quat(q, kq) * UnitQuat::from_scaled_axis(V3::new(v[kv], v[kv + 1], v[kv + 2]) * dt);
                put_quat(q, kq, &r);
            }
            JointKind::Floating => {
                let r0 = quat(q, kq + 3);
                let dp = r0 * (V3::new(v[kv], v[kv + 1], v[kv + 2]) * dt);
                for a in 0..3 {
                    q[kq + a] += dp[a];
                }
                let r = r0 * UnitQuat::from_scaled_axis(V3::new(v[kv + 3], v[kv + 4], v[kv + 5]) * dt);
                put_quat(q, kq + 3, &r);
            }
            _ => q[kq] += v[kv] * dt,
        }
    }
}

fn quat(q: &[f64], k: usize) -> UnitQuat {
    UnitQuat::new_normalize(nalgebra::Quaternion::new(q[k], q[k + 1], q[k + 2], q[k + 3]))
}

fn put_quat(q: &mut [f64], k: usize, r: &UnitQuat) {
    let c = r.quaternion();
    q[k] = c.w;
    q[k + 1] = c.i;
    q[k + 2] = c.j;
    q[k + 3] = c.k;
}

/// Time derivative of `q` for velocity `v` (kin's layout).
pub fn qdot(m: &PhysModel, q: &[f64], v: &[f64], out: &mut [f64]) {
    for jt in &m.joints {
        let (kq, kv) = (jt.qo, jt.vo);
        let quat_rate = |out: &mut [f64], k: usize, w: [f64; 3]| {
            let (a, b, c, d) = (q[k], q[k + 1], q[k + 2], q[k + 3]);
            // 1/2 q (x) (0, w): the angular velocity is in the child frame.
            out[k] = 0.5 * (-b * w[0] - c * w[1] - d * w[2]);
            out[k + 1] = 0.5 * (a * w[0] + c * w[2] - d * w[1]);
            out[k + 2] = 0.5 * (a * w[1] - b * w[2] + d * w[0]);
            out[k + 3] = 0.5 * (a * w[2] + b * w[1] - c * w[0]);
        };
        match jt.kind {
            JointKind::Fixed => {}
            JointKind::Spherical => quat_rate(out, kq, [v[kv], v[kv + 1], v[kv + 2]]),
            JointKind::Floating => {
                let r = quat(q, kq + 3);
                let p = r * V3::new(v[kv], v[kv + 1], v[kv + 2]);
                out[kq..kq + 3].copy_from_slice(p.as_slice());
                quat_rate(out, kq + 3, [v[kv + 3], v[kv + 4], v[kv + 5]]);
            }
            _ => out[kq] = v[kv],
        }
    }
}

/// Renormalises every quaternion in `q`.
pub fn normalize_quats(m: &PhysModel, q: &mut [f64]) {
    for jt in &m.joints {
        match jt.kind {
            JointKind::Spherical => {
                let r = quat(q, jt.qo);
                put_quat(q, jt.qo, &r);
            }
            JointKind::Floating => {
                let r = quat(q, jt.qo + 3);
                put_quat(q, jt.qo + 3, &r);
            }
            _ => {}
        }
    }
}

/// Angular Jacobian column helper re-exported for tests.
pub fn angular_col(w: &World, k: usize) -> V3 {
    angular_jacobian_col(&w.ws, k)
}
