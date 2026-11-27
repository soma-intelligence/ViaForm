//! Numerical inverse kinematics for every model (RUST-ENGINES 4.3, E-7): damped least squares
//! with adaptive damping, joint limits as an active set, task priorities (multi-finger hands),
//! a null-space posture term, a line search and seeded multi-start.
//!
//! The solver works in drive space ([`crate::model::DriveMap`]): actuator values plus the DOF of
//! passive ball and floating joints. For a motor-per-joint arm that is joint space; for coupled or
//! tendon-driven fingers it is actuator space (`J_a = J_q C`), so coupled joints always stay
//! consistent.

use nalgebra::{DMatrix, DVector};
use serde::{Deserialize, Serialize};

use crate::error::{KinError, codes};
use crate::fk::{put_quat, quat_at};
use crate::math::{Iso3, Jacobian, Rng, UnitQuat, rot_error};
use crate::model::{DriveMap, FrameId, JointKind, Model};

/// Which error components a task constrains, in the target frame (`true` = constrained).
/// Example: free rotation about the tool axis is `rot: [true, true, false]`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct AxisMask {
    pub pos: [bool; 3],
    pub rot: [bool; 3],
}

impl Default for AxisMask {
    fn default() -> Self {
        AxisMask { pos: [true; 3], rot: [true; 3] }
    }
}

impl AxisMask {
    /// Position only (any orientation).
    pub fn position() -> Self {
        AxisMask { pos: [true; 3], rot: [false; 3] }
    }
    fn rows(&self) -> usize {
        self.pos.iter().chain(&self.rot).filter(|b| **b).count()
    }
}

/// One IK task: bring tool frame `frame` to `target`.
#[derive(Clone, Debug)]
pub struct IkTask {
    pub frame: FrameId,
    pub target: Iso3,
    pub weight_pos: f64,
    pub weight_rot: f64,
    pub mask: AxisMask,
    /// 1 is the highest priority; lower priority tasks act in the null space of higher ones.
    pub priority: u32,
}

impl IkTask {
    /// A full pose task, priority 1, unit weights.
    pub fn pose(frame: FrameId, target: Iso3) -> Self {
        IkTask { frame, target, weight_pos: 1.0, weight_rot: 1.0, mask: AxisMask::default(), priority: 1 }
    }
    /// A position-only task, priority 1.
    pub fn position(frame: FrameId, target: Iso3) -> Self {
        IkTask { mask: AxisMask::position(), ..IkTask::pose(frame, target) }
    }
}

/// An IK problem.
#[derive(Clone, Debug)]
pub struct IkProblem {
    pub tasks: Vec<IkTask>,
    /// Start configuration (length `nq`).
    pub q0: Vec<f64>,
    /// Null-space target; `None` drifts toward mid-range of the actuator bounds.
    pub posture: Option<Vec<f64>>,
    /// Gain of the null-space posture term per iteration (0 = off).
    pub posture_weight: f64,
    /// Joints that must not move (every drive variable that moves one of them is frozen).
    pub locked: Vec<usize>,
}

impl IkProblem {
    pub fn new(tasks: Vec<IkTask>, q0: Vec<f64>) -> Self {
        IkProblem { tasks, q0, posture: None, posture_weight: 0.0, locked: vec![] }
    }
}

/// Solver settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct IkOptions {
    /// Iterations per start.
    pub max_iters: usize,
    /// Position tolerance, m.
    pub tol_pos: f64,
    /// Orientation tolerance, rad.
    pub tol_rot: f64,
    /// Extra random starts when the first one does not converge.
    pub seeds: usize,
    /// Seed of the random starts.
    pub seed: u64,
    /// Smallest singular value below which damping starts (Nakamura and Hanafusa 1986,
    /// Chiaverini 1997).
    pub sigma_eps: f64,
    /// Damping at a singular configuration.
    pub lambda_max: f64,
    /// Largest change of a drive variable per iteration (rad or m).
    pub max_step: f64,
}

impl Default for IkOptions {
    fn default() -> Self {
        IkOptions { max_iters: 100, tol_pos: 1e-5, tol_rot: 1e-4, seeds: 32, seed: 0, sigma_eps: 0.04, lambda_max: 0.04, max_step: 0.5 }
    }
}

/// Result of [`solve`].
#[derive(Clone, Debug, Serialize)]
pub struct IkResult {
    pub q: Vec<f64>,
    /// Actuator values for `q` (`Model::to_actuators`).
    pub actuators: Vec<f64>,
    /// Every task within tolerance.
    pub converged: bool,
    /// Iterations over all starts.
    pub iterations: usize,
    /// Random restarts used.
    pub restarts: usize,
    /// Per task, norm of the constrained position error, m.
    pub pos_err: Vec<f64>,
    /// Per task, norm of the constrained orientation error, rad.
    pub rot_err: Vec<f64>,
}

/// Solves `problem` (see the module docs).
pub fn solve(model: &Model, problem: &IkProblem, opts: &IkOptions) -> Result<IkResult, KinError> {
    let mut s = Solver::new(model, problem, opts)?;
    Ok(s.run(problem, opts))
}

/// A reusable solver for one model and task layout (used by drag, paths and the facade).
pub struct Solver<'a> {
    model: &'a Model,
    dm: DriveMap,
    bounds: Vec<(f64, f64)>,
    /// Tasks grouped by priority, highest first.
    levels: Vec<Vec<usize>>,
    tasks: Vec<IkTask>,
    frozen: Vec<bool>,
    posture: Vec<Option<f64>>,
    posture_weight: f64,
    poses: Vec<Iso3>,
    jac: Jacobian,
}

struct Eval {
    /// Per level: stacked error and Jacobian (drive space).
    e: Vec<DVector<f64>>,
    j: Vec<DMatrix<f64>>,
    merit: Vec<f64>,
    pos_err: Vec<f64>,
    rot_err: Vec<f64>,
    done: bool,
}

impl<'a> Solver<'a> {
    pub fn new(model: &'a Model, problem: &IkProblem, opts: &IkOptions) -> Result<Self, KinError> {
        model.check_q(&problem.q0)?;
        for t in &problem.tasks {
            model.check_frame(t.frame)?;
        }
        if problem.tasks.is_empty() {
            return Err(KinError::new(codes::PARAMS, "IK needs at least one task"));
        }
        for &j in &problem.locked {
            if j >= model.joints.len() {
                return Err(KinError::new(codes::UNKNOWN_NAME, format!("no joint {j} to lock")));
            }
        }
        let dm = model.drive_map();
        let bounds = model.actuator_bounds();
        let mut prios: Vec<u32> = problem.tasks.iter().map(|t| t.priority).collect();
        prios.sort_unstable();
        prios.dedup();
        let levels = prios.iter().map(|p| (0..problem.tasks.len()).filter(|&i| problem.tasks[i].priority == *p).collect()).collect();
        let frozen = (0..dm.nz).map(|z| dm.drives_joints[z].iter().any(|j| problem.locked.contains(j))).collect();
        let posture = match &problem.posture {
            Some(p) => {
                model.check_q(p)?;
                model.to_actuators(p).into_iter().map(Some).collect()
            }
            None => bounds.iter().map(|&(lo, hi)| (lo.is_finite() && hi.is_finite()).then_some(0.5 * (lo + hi))).collect(),
        };
        let _ = opts;
        Ok(Solver { model, jac: Jacobian::zeros(model.nv()), dm, bounds, levels, tasks: problem.tasks.clone(), frozen, posture, posture_weight: problem.posture_weight, poses: vec![] })
    }

    /// Replaces the task targets (same layout), for drag and paths.
    pub fn set_targets(&mut self, targets: &[Iso3]) {
        for (t, p) in self.tasks.iter_mut().zip(targets) {
            t.target = *p;
        }
    }

    fn eval(&mut self, q: &[f64], opts: &IkOptions) -> Eval {
        self.model.fk_into(q, &mut self.poses);
        let n = self.tasks.len();
        let mut pos_err = vec![0.0; n];
        let mut rot_err = vec![0.0; n];
        let mut rows: Vec<(Vec<f64>, DMatrix<f64>)> = Vec::with_capacity(n);
        let mut done = true;
        for (ti, t) in self.tasks.iter().enumerate() {
            let cur = self.model.frame_pose(&self.poses, t.frame);
            let rt = t.target.rotation.inverse();
            let dp = rt * (t.target.translation.vector - cur.translation.vector);
            let dr = rt * rot_error(&t.target.rotation, &cur.rotation);
            let p = cur.translation.vector;
            self.model.jacobian_into(&self.poses, self.model.end_effectors[t.frame].link, &p, &mut self.jac);
            let nv = self.model.nv();
            // Jacobian rows in the target frame.
            let mut jt = Jacobian::zeros(nv);
            for c in 0..nv {
                let lin = rt * nalgebra::Vector3::new(self.jac[(0, c)], self.jac[(1, c)], self.jac[(2, c)]);
                let ang = rt * nalgebra::Vector3::new(self.jac[(3, c)], self.jac[(4, c)], self.jac[(5, c)]);
                jt.fixed_view_mut::<3, 1>(0, c).copy_from(&lin);
                jt.fixed_view_mut::<3, 1>(3, c).copy_from(&ang);
            }
            let m = t.mask.rows();
            let mut e = Vec::with_capacity(m);
            let mut jr = DMatrix::zeros(m, nv);
            let mut r = 0;
            let (mut pe, mut re) = (0.0, 0.0);
            for k in 0..6 {
                let (on, w, err) = if k < 3 { (t.mask.pos[k], t.weight_pos, dp[k]) } else { (t.mask.rot[k - 3], t.weight_rot, dr[k - 3]) };
                if !on {
                    continue;
                }
                if k < 3 { pe += err * err } else { re += err * err }
                e.push(w * err);
                for c in 0..nv {
                    jr[(r, c)] = w * jt[(k, c)];
                }
                r += 1;
            }
            pos_err[ti] = pe.sqrt();
            rot_err[ti] = re.sqrt();
            if pos_err[ti] > opts.tol_pos || rot_err[ti] > opts.tol_rot {
                done = false;
            }
            rows.push((e, jr * &self.dm.c));
        }
        let mut es = vec![];
        let mut js = vec![];
        let mut merit = vec![];
        for lvl in &self.levels {
            let m: usize = lvl.iter().map(|&i| rows[i].0.len()).sum();
            let mut e = DVector::zeros(m);
            let mut j = DMatrix::zeros(m, self.dm.nz);
            let mut r = 0;
            for &i in lvl {
                let (ee, jj) = &rows[i];
                for k in 0..ee.len() {
                    e[r + k] = ee[k];
                    j.row_mut(r + k).copy_from(&jj.row(k));
                }
                r += ee.len();
            }
            merit.push(e.norm_squared());
            es.push(e);
            js.push(j);
        }
        Eval { e: es, j: js, merit, pos_err, rot_err, done }
    }

    /// Task-priority damped least squares step with `fixed` drive variables moved by `forced`.
    /// Returns the step and the final null-space projector. The first level owns the active set
    /// (the caller freezes variables its step would push out of bounds); each lower level's
    /// contribution is scaled down so it never pushes a variable out of bounds (task scaling, after
    /// the saturation in the null space idea of Flacco, De Luca and Khatib 2012), so a lower
    /// priority task cannot steal a joint the higher ones need.
    fn step(&self, ev: &Eval, fixed: &[bool], forced: &DVector<f64>, opts: &IkOptions, boost: f64, a: &[f64]) -> (DVector<f64>, DMatrix<f64>) {
        let nz = self.dm.nz;
        let mut dz = forced.clone();
        let mut p = DMatrix::zeros(nz, nz);
        let mut nfree = 0;
        for i in 0..nz {
            if !fixed[i] {
                p[(i, i)] = 1.0;
                nfree += 1;
            }
        }
        for (level, (e, j)) in ev.e.iter().zip(&ev.j).enumerate() {
            if nfree == 0 || e.is_empty() {
                break;
            }
            let before = dz.clone();
            let res = e - j * &dz;
            let jt = j * &p;
            let svd = jt.svd(true, true);
            let (Some(u), Some(vt)) = (svd.u.as_ref(), svd.v_t.as_ref()) else { continue };
            let sv = &svd.singular_values;
            let mut sorted: Vec<f64> = sv.iter().copied().collect();
            sorted.sort_by(|a, b| b.total_cmp(a));
            let r = sorted.len().min(nfree).min(e.len());
            let smin = if r > 0 { sorted[r - 1] } else { 0.0 };
            let smax = sorted.first().copied().unwrap_or(0.0);
            // Damping grows as the smallest singular value falls below sigma_eps, and fades as
            // the residual vanishes (within `fade` of the target the step is Gauss-Newton), so
            // the last iterations converge quadratically even near a singularity.
            let fade = (res.norm() / 0.01).min(1.0).powi(2);
            let mut lam2 = if smin >= opts.sigma_eps { 0.0 } else { (1.0 - (smin / opts.sigma_eps).powi(2)) * opts.lambda_max * opts.lambda_max * fade };
            lam2 += boost * boost;
            let tol = 1e-10 * smax.max(1e-300) + 1e-14;
            for i in 0..sv.len() {
                let s = sv[i];
                if s <= tol {
                    continue;
                }
                let ui = u.column(i);
                let vi = vt.row(i).transpose();
                let coef = s / (s * s + lam2) * ui.dot(&res);
                dz.axpy(coef, &vi, 1.0);
                p -= &vi * vi.transpose();
            }
            if level > 0 {
                self.scale_into_bounds(&before, &mut dz, a);
            }
        }
        for i in 0..nz {
            if fixed[i] {
                dz[i] = forced[i];
            }
        }
        (dz, p)
    }

    /// Scales `dz - before` so that `a + dz` stays within the actuator bounds wherever
    /// `a + before` was.
    fn scale_into_bounds(&self, before: &DVector<f64>, dz: &mut DVector<f64>, a: &[f64]) {
        let mut scale: f64 = 1.0;
        for i in 0..self.dm.na {
            let c = dz[i] - before[i];
            let x0 = a[i] + before[i];
            let (lo, hi) = self.bounds[i];
            if c > 0.0 && x0 + c > hi && x0 <= hi {
                scale = scale.min((hi - x0) / c);
            } else if c < 0.0 && x0 + c < lo && x0 >= lo {
                scale = scale.min((lo - x0) / c);
            }
        }
        if scale < 1.0 {
            let s = scale.max(0.0);
            *dz = before + (&*dz - before) * s;
        }
    }

    fn drive_values(&self, q: &[f64]) -> Vec<f64> {
        self.model.to_actuators(q)
    }

    /// `q` moved by drive step `dz` (actuators clamped to their bounds, ball angles to their
    /// limit).
    fn apply(&self, q: &[f64], a: &[f64], dz: &DVector<f64>) -> (Vec<f64>, Vec<f64>) {
        let na = self.dm.na;
        let a2: Vec<f64> = (0..na).map(|i| (a[i] + dz[i]).max(self.bounds[i].0).min(self.bounds[i].1)).collect();
        let mut q2 = if self.dm.passive.is_empty() {
            q.to_vec()
        } else {
            let mut v = vec![0.0; self.model.nv()];
            for &(_, v0, z0, d) in &self.dm.passive {
                for k in 0..d {
                    v[v0 + k] = dz[z0 + k];
                }
            }
            let mut q2 = self.model.integrate(q, &v);
            let qo = self.model.q_offsets();
            for &(j, ..) in &self.dm.passive {
                let joint = &self.model.joints[j];
                if joint.kind == JointKind::Spherical && joint.limits.upper.is_finite() {
                    let r = quat_at(&q2, qo[j]);
                    if r.angle() > joint.limits.upper {
                        put_quat(&mut q2, qo[j], &UnitQuat::from_scaled_axis(r.scaled_axis() * (joint.limits.upper / r.angle())));
                    }
                }
            }
            q2
        };
        self.model.apply_actuators(&a2, &mut q2);
        (q2, a2)
    }

    /// One start from `q`: returns the final configuration, its evaluation and the iterations.
    fn descend(&mut self, q: &[f64], max_iters: usize, opts: &IkOptions) -> (Vec<f64>, Eval, usize) {
        let mut a = self.drive_values(q);
        let mut q = q.to_vec();
        self.model.apply_actuators(&a, &mut q);
        // Start inside the bounds.
        for i in 0..self.dm.na {
            a[i] = a[i].max(self.bounds[i].0).min(self.bounds[i].1);
        }
        self.model.apply_actuators(&a, &mut q);
        let nz = self.dm.nz;
        let mut ev = self.eval(&q, opts);
        let mut boost = 0.0;
        let mut it = 0;
        let mut history: Vec<f64> = Vec::with_capacity(max_iters);
        while it < max_iters && !ev.done {
            it += 1;
            // Stall: a local minimum (typically against a joint limit) far from the target. Give
            // the remaining budget to another start.
            history.push(ev.merit[0]);
            if self.levels.len() == 1 && it > 15 {
                let old = history[it - 11];
                if ev.merit[0] > 0.98 * old {
                    break;
                }
            }
            // Active set: freeze variables that would leave their bounds, at the bound.
            let mut fixed = self.frozen.clone();
            let mut forced = DVector::zeros(nz);
            let mut dz;
            let mut proj;
            let mut round = 0;
            loop {
                (dz, proj) = self.step(&ev, &fixed, &forced, opts, boost, &a);
                let mut changed = false;
                for i in 0..self.dm.na {
                    if fixed[i] {
                        continue;
                    }
                    let (lo, hi) = self.bounds[i];
                    let x = a[i] + dz[i];
                    if x > hi + 1e-12 || x < lo - 1e-12 {
                        fixed[i] = true;
                        forced[i] = x.max(lo).min(hi) - a[i];
                        changed = true;
                    }
                }
                round += 1;
                if !changed || round > 6 {
                    break;
                }
            }
            // Null-space posture.
            if self.posture_weight > 0.0 {
                let mut g = DVector::zeros(nz);
                for i in 0..self.dm.na {
                    if let Some(t) = self.posture[i] {
                        if !fixed[i] {
                            g[i] = self.posture_weight * (t - a[i]);
                        }
                    }
                }
                let before = dz.clone();
                dz += &proj * g;
                self.scale_into_bounds(&before, &mut dz, &a);
            }
            let big = dz.amax();
            if big > opts.max_step {
                dz *= opts.max_step / big;
            }
            // Line search on the (lexicographic) error.
            let mut accepted = false;
            let mut alpha = 1.0;
            for _ in 0..5 {
                let (q2, a2) = self.apply(&q, &a, &(&dz * alpha));
                let ev2 = self.eval(&q2, opts);
                if better(&ev2.merit, &ev.merit) || ev2.done {
                    q = q2;
                    a = a2;
                    ev = ev2;
                    accepted = true;
                    break;
                }
                alpha *= 0.5;
            }
            if accepted {
                boost *= 0.3;
                if boost < 1e-6 {
                    boost = 0.0;
                }
            } else {
                boost = if boost == 0.0 { 1e-3 } else { boost * 10.0 };
                if boost > 10.0 {
                    break;
                }
            }
        }
        (q, ev, it)
    }

    /// Runs the solver from `problem.q0`, then from random starts while it has not converged.
    pub fn run(&mut self, problem: &IkProblem, opts: &IkOptions) -> IkResult {
        let (mut best_q, mut best, mut iters) = self.descend(&problem.q0, opts.max_iters, opts);
        let mut restarts = 0;
        if !best.done && opts.seeds > 0 {
            let mut rng = Rng::new(opts.seed);
            let a0 = self.model.to_actuators(&problem.q0);
            while restarts < opts.seeds && !best.done {
                restarts += 1;
                let mut q = self.model.random_q(&mut rng);
                // Keep locked joints where they were.
                let mut a = self.model.to_actuators(&q);
                for i in 0..self.dm.na {
                    if self.frozen[i] {
                        a[i] = a0[i];
                    }
                }
                self.model.apply_actuators(&a, &mut q);
                let (q2, ev, it) = self.descend(&q, opts.max_iters, opts);
                iters += it;
                if ev.done || better(&ev.merit, &best.merit) {
                    best_q = q2;
                    best = ev;
                }
            }
        }
        IkResult { actuators: self.model.to_actuators(&best_q), q: best_q, converged: best.done, iterations: iters, restarts, pos_err: best.pos_err, rot_err: best.rot_err }
    }

    /// A short warm-started solve (drag): at most `iters` iterations, no restarts.
    pub fn track(&mut self, q: &[f64], iters: usize, opts: &IkOptions) -> IkResult {
        let (q, ev, it) = self.descend(q, iters, opts);
        IkResult { actuators: self.model.to_actuators(&q), q, converged: ev.done, iterations: it, restarts: 0, pos_err: ev.pos_err, rot_err: ev.rot_err }
    }
}

/// Lexicographic comparison of per-level squared errors: `new` is better when the first level
/// that differs (beyond round-off) is lower.
fn better(new: &[f64], old: &[f64]) -> bool {
    for (n, o) in new.iter().zip(old) {
        let tol = 1e-12 * o.abs() + 1e-30;
        if *n < o - tol {
            return true;
        }
        if *n > o + tol {
            return false;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models;

    #[test]
    fn arm_reaches_a_reachable_pose() {
        let m = models::so101_arm();
        let mut rng = Rng::new(11);
        let mut ok = 0;
        for _ in 0..50 {
            let qt = m.random_q(&mut rng);
            let target = m.fk_frame(&qt, 0).unwrap();
            let r = solve(&m, &IkProblem::new(vec![IkTask::pose(0, target)], m.neutral()), &IkOptions::default()).unwrap();
            for (j, joint) in m.joints.iter().enumerate() {
                assert!(r.q[j] >= joint.limits.lower - 1e-12 && r.q[j] <= joint.limits.upper + 1e-12);
            }
            if r.converged {
                ok += 1;
                let p = m.fk_frame(&r.q, 0).unwrap();
                assert!((p.translation.vector - target.translation.vector).norm() < 1e-5);
                assert!(rot_error(&target.rotation, &p.rotation).norm() < 1e-4);
            }
        }
        // The 10k target rate is in tests/acceptance.rs; here a short smoke check.
        assert!(ok >= 48, "{ok} of 50");
    }

    #[test]
    fn locked_joints_do_not_move_and_unreachable_stretches() {
        let m = models::so101_arm();
        let q0 = vec![0.3, 0.2, 0.4, 0.1, 0.5, -0.2];
        let target = crate::math::pose(crate::math::Vec3::new(0.15, 0.1, 0.12), UnitQuat::identity());
        let mut p = IkProblem::new(vec![IkTask::position(0, target)], q0.clone());
        p.locked = vec![0];
        let r = solve(&m, &p, &IkOptions::default()).unwrap();
        assert_eq!(r.q[0], 0.3);
        // Far away: no convergence, but the tip gets as close as it can (arm stretched).
        let far = crate::math::pose(crate::math::Vec3::new(2.0, 0.0, 0.3), UnitQuat::identity());
        let r = solve(&m, &IkProblem::new(vec![IkTask::position(0, far)], q0), &IkOptions { seeds: 2, ..IkOptions::default() }).unwrap();
        assert!(!r.converged);
        let reach = m.fk_frame(&r.q, 0).unwrap().translation.vector;
        assert!(reach.x > 0.3, "stretched toward the target: {reach}");
        assert!((r.pos_err[0] - (far.translation.vector - reach).norm()).abs() < 1e-12);
    }

    #[test]
    fn same_seed_same_result() {
        let m = models::so101_arm();
        let target = crate::math::pose(crate::math::Vec3::new(0.18, -0.08, 0.15), UnitQuat::from_euler_angles(3.0, 0.2, -0.5));
        let p = IkProblem::new(vec![IkTask::pose(0, target)], m.neutral());
        let a = solve(&m, &p, &IkOptions::default()).unwrap();
        let b = solve(&m, &p, &IkOptions::default()).unwrap();
        assert_eq!(a.q, b.q);
    }
}
