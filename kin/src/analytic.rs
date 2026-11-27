//! Analytic IK fast path for 6R arms with a spherical wrist (RUST-ENGINES 4.3, E-7).
//!
//! Method (Pieper 1968 decomposition, written with product-of-exponentials subproblems after
//! Paden 1985 and Murray, Li and Sastry 1994):
//! 1. Product of exponentials at `q = 0`: `T(q) = e^[xi1 q1] ... e^[xi6 q6] M`, with world axes
//!    `w_i` and points `p_i` read from the model.
//! 2. The wrist centre `c` (common point of axes 4, 5, 6) only moves with joints 1 to 3:
//!    `e1 e2 e3 c = T_target M^-1 c`.
//! 3. Rotating about axis 1 keeps the height along `w1` and the distance to axis 1. Both are
//!    linear in `(cos q2, sin q2)` with coefficients linear in `(cos q3, sin q3)`. Eliminating
//!    `q2` leaves a trigonometric polynomial of degree 4 in `q3`, solved as a polynomial in
//!    `tan(q3 / 2)` through companion matrix eigenvalues and polished by Newton steps. When axes
//!    1 and 2 intersect, or are parallel, one equation loses `q2` and `q3` comes from a first
//!    order equation instead. Up to 4 arm solutions; `q1` from subproblem 1.
//! 4. The wrist: `R4 R5 R6 = (R1 R2 R3)^T R_target R_M^T`; subproblem 2 on `w6` gives two
//!    `(q4, q5)` pairs, subproblem 1 gives `q6`. Up to 8 solutions in all.
//!
//! Every candidate is checked by forward kinematics; solutions outside the joint limits are kept
//! by [`Analytic6R::solve_all`] and filtered by [`Analytic6R::solve_nearest`].

use nalgebra::{DMatrix, Rotation3, Unit};

use crate::error::{KinError, codes};
use crate::math::{Iso3, Vec3, rot_error, wrap_pi};
use crate::model::{FrameId, JointKind, Model};

/// A prepared analytic solver for one tool frame.
#[derive(Clone, Debug)]
pub struct Analytic6R {
    pub frame: FrameId,
    /// The six joints of the chain, base first.
    pub joints: [usize; 6],
    /// Their indices in `q`.
    pub q_index: [usize; 6],
    w: [Vec3; 6],
    p: [Vec3; 6],
    m: Iso3,
    centre: Vec3,
    o1: Vec3,
    o2: Vec3,
    case: Case,
    limits: [(f64, f64); 6],
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Case {
    General,
    /// Axes 1 and 2 intersect: the distance equation does not depend on q2.
    Intersecting,
    /// Axes 1 and 2 are parallel: the height equation does not depend on q2.
    Parallel,
}

fn sp1(w: &Vec3, p: &Vec3, q: &Vec3) -> Option<f64> {
    let pp = p - w * w.dot(p);
    let qq = q - w * w.dot(q);
    if pp.norm() < 1e-12 || qq.norm() < 1e-12 {
        return None;
    }
    Some(w.dot(&pp.cross(&qq)).atan2(pp.dot(&qq)))
}

fn rot(w: &Vec3, a: f64) -> Rotation3<f64> {
    Rotation3::from_axis_angle(&Unit::new_unchecked(*w), a)
}

/// Roots of `alpha + beta cos t + gamma sin t = 0`.
fn trig1_roots(alpha: f64, beta: f64, gamma: f64) -> Vec<f64> {
    let r = beta.hypot(gamma);
    if r < 1e-14 {
        return vec![];
    }
    let c = -alpha / r;
    if c.abs() > 1.0 + 1e-9 {
        return vec![];
    }
    let phi = gamma.atan2(beta);
    let d = c.clamp(-1.0, 1.0).acos();
    if d < 1e-9 { vec![phi] } else { vec![phi + d, phi - d] }
}

/// Real roots of the polynomial with coefficients `c` (constant first).
fn poly_roots(c: &[f64]) -> Vec<f64> {
    let scale = c.iter().fold(0.0f64, |m, v| m.max(v.abs()));
    if scale == 0.0 {
        return vec![];
    }
    let mut deg = c.len() - 1;
    while deg > 0 && c[deg].abs() <= 1e-13 * scale {
        deg -= 1;
    }
    if deg == 0 {
        return vec![];
    }
    let lead = c[deg];
    let mut comp = DMatrix::zeros(deg, deg);
    for i in 1..deg {
        comp[(i, i - 1)] = 1.0;
    }
    for i in 0..deg {
        comp[(i, deg - 1)] = -c[i] / lead;
    }
    comp.complex_eigenvalues().iter().filter(|z| z.im.abs() <= 1e-5 * (1.0 + z.re.abs())).map(|z| z.re).collect()
}

impl Analytic6R {
    /// Prepares the solver, or explains why the frame's chain does not qualify: it needs exactly
    /// six revolute (or continuous) joints from the base, any number of fixed ones, and the last
    /// three axes meeting in one point (1e-6 m).
    pub fn new(model: &Model, frame: FrameId) -> Result<Self, KinError> {
        model.check_frame(frame)?;
        let unsupported = |m: String| KinError::new(codes::ANALYTIC_UNSUPPORTED, m);
        let mut chain = vec![];
        let mut l = model.end_effectors[frame].link;
        while l > 0 {
            let j = l - 1;
            match model.joints[j].kind {
                JointKind::Fixed => {}
                JointKind::Revolute | JointKind::Continuous => chain.push(j),
                k => return Err(unsupported(format!("joint {} is {k:?}", model.joints[j].name))),
            }
            l = model.joints[j].parent;
        }
        chain.reverse();
        if chain.len() != 6 {
            return Err(unsupported(format!("the chain has {} moving joints, not 6", chain.len())));
        }
        // Coupled joints would break the per-joint solution.
        for cp in &model.couplings {
            if cp.joints.len() > 1 && cp.joints.iter().any(|j| chain.contains(j)) {
                return Err(unsupported("a joint of the chain is coupled to another".into()));
            }
        }
        let qo = model.q_offsets();
        let mut q = model.neutral();
        for &j in &chain {
            q[qo[j]] = 0.0;
        }
        let poses = model.fk(&q)?;
        let mut w = [Vec3::zeros(); 6];
        let mut p = [Vec3::zeros(); 6];
        for (i, &j) in chain.iter().enumerate() {
            let jf = poses[model.joints[j].parent] * model.joints[j].origin;
            w[i] = (jf.rotation * model.joints[j].axis).normalize();
            p[i] = jf.translation.vector;
        }
        let m = model.frame_pose(&poses, frame);
        // Wrist centre: least-squares point of lines 4, 5, 6.
        let mut a = nalgebra::Matrix3::zeros();
        let mut b = Vec3::zeros();
        for i in 3..6 {
            let proj = nalgebra::Matrix3::identity() - w[i] * w[i].transpose();
            a += proj;
            b += proj * p[i];
        }
        let centre = a.try_inverse().ok_or_else(|| unsupported("the wrist axes are parallel".into()))? * b;
        for i in 3..6 {
            let d = (centre - p[i]) - w[i] * w[i].dot(&(centre - p[i]));
            if d.norm() > 1e-6 {
                return Err(unsupported(format!("the last three axes do not meet (off by {:.2e} m)", d.norm())));
            }
        }
        if w[3].cross(&w[4]).norm() < 1e-6 || w[4].cross(&w[5]).norm() < 1e-6 {
            return Err(unsupported("neighbouring wrist axes are parallel".into()));
        }
        // Common normal of axes 1 and 2.
        let n = w[0].cross(&w[1]);
        let (o1, o2, case) = if n.norm() < 1e-9 {
            let o2 = p[1];
            let o1 = p[0] + w[0] * w[0].dot(&(o2 - p[0]));
            (o1, o2, Case::Parallel)
        } else {
            let d = p[1] - p[0];
            let c = w[0].dot(&w[1]);
            let den = 1.0 - c * c;
            let t1 = (w[0].dot(&d) - c * w[1].dot(&d)) / den;
            let t2 = (c * w[0].dot(&d) - w[1].dot(&d)) / den;
            let o1 = p[0] + w[0] * t1;
            let o2 = p[1] + w[1] * t2;
            let case = if (o2 - o1).norm() < 1e-9 { Case::Intersecting } else { Case::General };
            (o1, o2, case)
        };
        let limits = std::array::from_fn(|i| {
            let l = &model.joints[chain[i]].limits;
            (l.lower, l.upper)
        });
        Ok(Analytic6R { frame, joints: std::array::from_fn(|i| chain[i]), q_index: std::array::from_fn(|i| qo[chain[i]]), w, p, m, centre, o1, o2, case, limits })
    }

    /// Whether the model's frame qualifies for the analytic solver.
    pub fn applies(model: &Model, frame: FrameId) -> bool {
        Analytic6R::new(model, frame).is_ok()
    }

    /// Tool pose for the six chain angles (other joints at their neutral values).
    pub fn fk(&self, th: &[f64; 6]) -> Iso3 {
        let mut t = Iso3::identity();
        for i in 0..6 {
            let r = rot(&self.w[i], th[i]);
            let tr = self.p[i] - r * self.p[i];
            t *= Iso3::from_parts(nalgebra::Translation3::from(tr), nalgebra::UnitQuaternion::from_rotation_matrix(&r));
        }
        t * self.m
    }

    /// Coefficients `(a1, b1, d1, a2, b2, d2)` of the height and distance equations
    /// `a cos q2 + b sin q2 = d` for a given `q3`.
    fn coeffs(&self, t3: f64, pw: &Vec3) -> [f64; 6] {
        let (w1, w2) = (&self.w[0], &self.w[1]);
        let y = rot(&self.w[2], t3) * (self.centre - self.p[2]) + self.p[2];
        let u = y - self.o2;
        let delta = self.o2 - self.o1;
        let wu = w2.dot(&u);
        let w2xu = w2.cross(&u);
        let h = w1.dot(&(pw - self.o1));
        let c12 = w1.dot(w2);
        let a1 = w1.dot(&u) - c12 * wu;
        let b1 = w1.dot(&w2xu);
        let d1 = h - w1.dot(&delta) - c12 * wu;
        let dw = delta.dot(w2);
        let a2 = 2.0 * (delta.dot(&u) - dw * wu);
        let b2 = 2.0 * delta.dot(&w2xu);
        let d2 = (pw - self.o1).norm_squared() - u.norm_squared() - delta.norm_squared() - 2.0 * dw * wu;
        [a1, b1, d1, a2, b2, d2]
    }

    fn g(&self, t3: f64, pw: &Vec3) -> f64 {
        let [a1, b1, d1, a2, b2, d2] = self.coeffs(t3, pw);
        let x = d1 * b2 - d2 * b1;
        let y = a1 * d2 - a2 * d1;
        let det = a1 * b2 - a2 * b1;
        x * x + y * y - det * det
    }

    /// Candidate `q3` values for the wrist centre `pw`.
    fn q3_roots(&self, pw: &Vec3) -> Vec<f64> {
        use std::f64::consts::{FRAC_PI_2, PI};
        match self.case {
            Case::Intersecting | Case::Parallel => {
                // The q2-free equation: d2 (intersecting) or d1 (parallel), first order in q3.
                let f = |t: f64| {
                    let c = self.coeffs(t, pw);
                    if self.case == Case::Intersecting { c[5] } else { c[2] }
                };
                let (f0, f90, f180) = (f(0.0), f(FRAC_PI_2), f(PI));
                let alpha = 0.5 * (f0 + f180);
                trig1_roots(alpha, f0 - alpha, f90 - alpha)
            }
            Case::General => {
                // Fourier coefficients of g (degree 4) from 9 samples.
                let n = 9;
                let samples: Vec<f64> = (0..n).map(|k| self.g(2.0 * PI * k as f64 / n as f64, pw)).collect();
                let mut a = [0.0; 5];
                let mut b = [0.0; 5];
                for k in 0..5 {
                    for (i, s) in samples.iter().enumerate() {
                        let t = 2.0 * PI * (k * i) as f64 / n as f64;
                        a[k] += s * t.cos();
                        b[k] += s * t.sin();
                    }
                    let f = if k == 0 { 1.0 / n as f64 } else { 2.0 / n as f64 };
                    a[k] *= f;
                    b[k] *= f;
                }
                // g (1 + t^2)^4 as a polynomial in t = tan(q3 / 2):
                // cos k q (1+t^2)^k = Re (1 + i t)^(2k), sin k q (1+t^2)^k = Im (1 + i t)^(2k).
                let mut poly = [0.0; 9];
                for k in 0..5 {
                    // (1 + i t)^(2k) as complex coefficients.
                    let mut re = vec![1.0];
                    let mut im = vec![0.0];
                    for _ in 0..2 * k {
                        let mut nre = vec![0.0; re.len() + 1];
                        let mut nim = vec![0.0; im.len() + 1];
                        for j in 0..re.len() {
                            nre[j] += re[j];
                            nim[j] += im[j];
                            // times i t: (re + i im) i = -im + i re
                            nre[j + 1] -= im[j];
                            nim[j + 1] += re[j];
                        }
                        re = nre;
                        im = nim;
                    }
                    // times (1 + t^2)^(4 - k)
                    let mut s = vec![1.0];
                    for _ in 0..(4 - k) {
                        let mut ns = vec![0.0; s.len() + 2];
                        for j in 0..s.len() {
                            ns[j] += s[j];
                            ns[j + 2] += s[j];
                        }
                        s = ns;
                    }
                    for (i, rv) in re.iter().enumerate() {
                        for (j, sv) in s.iter().enumerate() {
                            poly[i + j] += a[k] * rv * sv + b[k] * im[i] * sv;
                        }
                    }
                }
                let mut roots: Vec<f64> = poly_roots(&poly).into_iter().map(|t| 2.0 * t.atan()).collect();
                // t = infinity (q3 = pi) is not a polynomial root when the degree drops.
                let gscale = a.iter().chain(&b).fold(0.0f64, |m, v| m.max(v.abs())).max(1e-300);
                if self.g(PI, pw).abs() < 1e-9 * gscale {
                    roots.push(PI);
                }
                // Newton polish on g (Fourier form, exact derivative).
                for r in roots.iter_mut() {
                    for _ in 0..8 {
                        let (mut gv, mut dg) = (a[0], 0.0);
                        for k in 1..5 {
                            let kf = k as f64;
                            gv += a[k] * (kf * *r).cos() + b[k] * (kf * *r).sin();
                            dg += kf * (-a[k] * (kf * *r).sin() + b[k] * (kf * *r).cos());
                        }
                        if dg.abs() < 1e-300 {
                            break;
                        }
                        let step = gv / dg;
                        if !step.is_finite() || step.abs() > 0.1 {
                            break;
                        }
                        *r -= step;
                        if step.abs() < 1e-15 {
                            break;
                        }
                    }
                }
                roots
            }
        }
    }

    /// Every solution for `target` (angles in (-pi, pi], joint limits ignored), each checked by
    /// forward kinematics to 1e-8 m and 1e-8 rad. `hint` gives the angles to use where the
    /// solution is not unique (shoulder or wrist singularity).
    pub fn solve_all(&self, target: &Iso3, hint: &[f64; 6]) -> Vec<[f64; 6]> {
        let pw = (target * self.m.inverse() * nalgebra::Point3::from(self.centre)).coords;
        let mut out: Vec<[f64; 6]> = vec![];
        let mut t3s = self.q3_roots(&pw);
        t3s.iter_mut().for_each(|t| *t = wrap_pi(*t));
        t3s.sort_by(|a, b| a.total_cmp(b));
        t3s.dedup_by(|a, b| (*a - *b).abs() < 1e-9);
        for t3 in t3s {
            let [a1, b1, d1, a2, b2, d2] = self.coeffs(t3, &pw);
            let det = a1 * b2 - a2 * b1;
            let scale = (a1.abs() + b1.abs()) * (a2.abs() + b2.abs());
            let t2s: Vec<f64> = if det.abs() > 1e-10 * scale.max(1e-300) && self.case == Case::General {
                vec![((a1 * d2 - a2 * d1) / det).atan2((d1 * b2 - d2 * b1) / det)]
            } else if a1.abs() + b1.abs() > a2.abs() + b2.abs() {
                trig1_roots(-d1, a1, b1)
            } else {
                trig1_roots(-d2, a2, b2)
            };
            for t2 in t2s {
                let y = rot(&self.w[2], t3) * (self.centre - self.p[2]) + self.p[2];
                let x = rot(&self.w[1], t2) * (y - self.p[1]) + self.p[1];
                let t1 = sp1(&self.w[0], &(x - self.o1), &(pw - self.o1)).unwrap_or(hint[0]);
                let r123 = rot(&self.w[0], t1) * rot(&self.w[1], t2) * rot(&self.w[2], t3);
                let rg = r123.inverse() * target.rotation.to_rotation_matrix() * self.m.rotation.to_rotation_matrix().inverse();
                for (t4, t5) in self.wrist_pairs(&rg, hint[3]) {
                    let r6 = rot(&self.w[4], t5).inverse() * rot(&self.w[3], t4).inverse() * rg;
                    let u = self.w[5].cross(&if self.w[5].x.abs() < 0.9 { Vec3::x() } else { Vec3::y() }).normalize();
                    let t6 = sp1(&self.w[5], &u, &(r6 * u)).unwrap_or(hint[5]);
                    let th = [t1, t2, t3, t4, t5, t6].map(wrap_pi);
                    let f = self.fk(&th);
                    let pe = (f.translation.vector - target.translation.vector).norm();
                    let re = rot_error(&target.rotation, &f.rotation).norm();
                    if pe < 1e-8 && re < 1e-8 && !out.iter().any(|o| (0..6).all(|i| wrap_pi(o[i] - th[i]).abs() < 1e-9)) {
                        out.push(th);
                    }
                }
            }
        }
        out
    }

    /// `(q4, q5)` with `R4 R5 w6 = rg w6` (subproblem 2); at the wrist singularity `q4 = hint4`.
    fn wrist_pairs(&self, rg: &Rotation3<f64>, hint4: f64) -> Vec<(f64, f64)> {
        let (w4, w5, p) = (self.w[3], self.w[4], self.w[5]);
        let q = rg * p;
        let c = w4.dot(&w5);
        let den = c * c - 1.0;
        let alpha = (c * w5.dot(&p) - w4.dot(&q)) / den;
        let beta = (c * w4.dot(&q) - w5.dot(&p)) / den;
        let n = w4.cross(&w5);
        let g2 = (p.norm_squared() - alpha * alpha - beta * beta - 2.0 * alpha * beta * c) / n.norm_squared();
        let gs: Vec<f64> = if g2 > 1e-14 { vec![g2.sqrt(), -g2.sqrt()] } else { vec![0.0] };
        let mut out = vec![];
        for g in gs {
            let z = w4 * alpha + w5 * beta + n * g;
            let t5 = sp1(&w5, &p, &z);
            let t4 = sp1(&w4, &z, &q);
            match (t4, t5) {
                (Some(t4), Some(t5)) => out.push((t4, t5)),
                _ => {
                    // z on axis 4: wrist singular, q4 free.
                    let t4 = hint4;
                    let qq = rot(&w4, t4).inverse() * q;
                    out.push((t4, sp1(&w5, &p, &qq).unwrap_or(0.0)));
                }
            }
        }
        out
    }

    /// The solution nearest to `q0` (Euclidean in the six angles) inside the joint limits,
    /// trying `+-2 pi` variants of each angle; written into a copy of `q0`. `None` when no
    /// solution is inside the limits.
    pub fn solve_nearest(&self, target: &Iso3, q0: &[f64]) -> Option<Vec<f64>> {
        let hint: [f64; 6] = std::array::from_fn(|i| q0[self.q_index[i]]);
        let tau = 2.0 * std::f64::consts::PI;
        let mut best: Option<(f64, [f64; 6])> = None;
        for s in self.solve_all(target, &hint) {
            let mut th = [0.0; 6];
            let mut ok = true;
            for i in 0..6 {
                let (lo, hi) = self.limits[i];
                let mut cand: Option<f64> = None;
                for k in -2..=2 {
                    let v = s[i] + tau * k as f64;
                    if v >= lo - 1e-12 && v <= hi + 1e-12 && cand.is_none_or(|c| (v - hint[i]).abs() < (c - hint[i]).abs()) {
                        cand = Some(v.max(lo).min(hi));
                    }
                }
                match cand {
                    Some(v) => th[i] = v,
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if ok {
                let d: f64 = (0..6).map(|i| (th[i] - hint[i]).powi(2)).sum();
                if best.is_none_or(|(bd, _)| d < bd) {
                    best = Some((d, th));
                }
            }
        }
        best.map(|(_, th)| {
            let mut q = q0.to_vec();
            for i in 0..6 {
                q[self.q_index[i]] = th[i];
            }
            q
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::{Rng, pose_xyz_rpy};
    use crate::models;

    fn check_model(m: &Model, n: usize, seed: u64) {
        let a = Analytic6R::new(m, 0).unwrap();
        let mut rng = Rng::new(seed);
        for _ in 0..n {
            let qt = m.random_q(&mut rng);
            let target = m.fk_frame(&qt, 0).unwrap();
            let sols = a.solve_all(&target, &[0.0; 6]);
            assert!(!sols.is_empty());
            let found = sols.iter().any(|s| (0..6).all(|i| wrap_pi(s[i] - qt[a.q_index[i]]).abs() < 1e-6));
            assert!(found, "true solution missing: {qt:?} {sols:?}");
        }
    }

    #[test]
    fn reference_arm_all_solutions() {
        let m = models::so101_arm();
        assert!(Analytic6R::applies(&m, 0));
        check_model(&m, 500, 5);
    }

    #[test]
    fn intersecting_and_parallel_shoulders() {
        // Intersecting axes 1 and 2 (no shoulder offset).
        let mut m = models::so101_arm();
        m.joints[1].origin = pose_xyz_rpy([0.0, 0.0, 0.0326], [0.0; 3]);
        let a = Analytic6R::new(&m, 0).unwrap();
        assert_eq!(a.case, Case::Intersecting);
        check_model(&m, 300, 6);
        // Parallel axes 1 and 2 (a SCARA-like first pair), tilted base.
        let mut m = models::so101_arm();
        m.joints[1].axis = Vec3::z();
        m.joints[0].origin = pose_xyz_rpy([0.0, 0.0, 0.06], [0.2, 0.0, 0.0]);
        let a = Analytic6R::new(&m, 0).unwrap();
        assert_eq!(a.case, Case::Parallel);
        check_model(&m, 300, 7);
    }

    #[test]
    fn non_spherical_wrist_is_refused() {
        let mut m = models::so101_arm();
        m.joints[4].origin = pose_xyz_rpy([0.0, 0.0, 0.01], [0.0; 3]);
        assert_eq!(Analytic6R::new(&m, 0).unwrap_err().code, codes::ANALYTIC_UNSUPPORTED);
        assert!(!Analytic6R::applies(&models::hand5(), 0));
    }
}
