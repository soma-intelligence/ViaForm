//! Cartesian moves (RUST-ENGINES 4.4, E-6): straight lines and circular arcs for the tool frame,
//! with circular blends at line corners, time scaling with a trapezoidal or jerk-limited
//! (S-curve) profile, IK at every output sample, and joint limit checks.
//!
//! Steps:
//! 1. Geometric path from the start pose: lines (SLERP for rotation), arcs through a via point,
//!    optional circular blends of `blend_radius` at line-line corners.
//! 2. IK every `step` along the path, warm-started from the previous sample; a joint jump over
//!    `max_joint_jump` (branch flip) or a failed sample rejects the path with the sample index.
//! 3. Time scaling of the path parameter: trapezoidal or double-S profile (Biagiotti and
//!    Melchiorri 2008, section 3.4, rest to rest) under the Cartesian limits; then the profile is
//!    slowed down uniformly until the joint velocity (and optional joint acceleration) limits hold
//!    (a simple, global form of TOPP-style iterative scaling). The motion stops at sharp corners
//!    (no blend): each section between stops gets its own rest-to-rest profile.
//! 4. Output at `rate_hz` (500 Hz): IK at each sample (warm-started), joint velocity and
//!    acceleration by finite differences, plus the actuator-space trajectory.

use serde::{Deserialize, Serialize};

use crate::error::{KinError, codes};
use crate::ik::{IkOptions, IkProblem, IkTask, Solver};
use crate::math::{Iso3, UnitQuat, Vec3, pose};
use crate::model::{FrameId, Model};

/// One piece of a Cartesian path, from the end of the previous one.
#[derive(Clone, Debug)]
pub enum Segment {
    /// Straight line to `to` (rotation by SLERP).
    Line { to: Iso3 },
    /// Circular arc through `via` to `to` (rotation by SLERP along the arc).
    Arc { via: Vec3, to: Iso3 },
}

/// Velocity profile of the path parameter.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Profile {
    /// Constant acceleration phases (jerk unbounded).
    Trapezoid,
    /// Jerk-limited (double S).
    SCurve,
}

/// Path settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct PathOpts {
    /// m/s.
    pub max_lin_vel: f64,
    /// m/s^2.
    pub max_lin_acc: f64,
    /// m/s^3 (S-curve only).
    pub max_lin_jerk: f64,
    /// rad/s of the tool orientation.
    pub max_ang_vel: f64,
    /// Geometric IK step for the branch and limit checks, m.
    pub step: f64,
    /// Corner blend: the blend starts this far from the corner on both lines, m (0 = none).
    pub blend_radius: f64,
    /// Output rate, Hz.
    pub rate_hz: f64,
    /// Largest joint change between geometric samples before the path is rejected, rad.
    pub max_joint_jump: f64,
    pub profile: Profile,
    /// Joint acceleration limit, rad/s^2 (infinite = not checked).
    #[serde(with = "crate::math::serde_upper")]
    pub max_joint_acc: f64,
}

impl Default for PathOpts {
    fn default() -> Self {
        PathOpts { max_lin_vel: 0.2, max_lin_acc: 1.0, max_lin_jerk: 10.0, max_ang_vel: 1.5, step: 0.002, blend_radius: 0.0, rate_hz: 500.0, max_joint_jump: 0.1, profile: Profile::SCurve, max_joint_acc: f64::INFINITY }
    }
}

/// A timed joint trajectory.
#[derive(Clone, Debug, Serialize)]
pub struct JointTrajectory {
    pub t: Vec<f64>,
    pub q: Vec<Vec<f64>>,
    pub qd: Vec<Vec<f64>>,
    pub qdd: Vec<Vec<f64>>,
    /// Actuator values per sample (`Model::to_actuators`).
    pub actuators: Vec<Vec<f64>>,
    /// Largest distance between the tool and the commanded path point over all samples, m.
    pub max_deviation: f64,
    /// Length of the geometric path (tool origin), m.
    pub length: f64,
    /// Peak velocity of the path parameter after joint limit scaling, m/s.
    pub peak_speed: f64,
}

/// A geometric piece with position and rotation as functions of `u` in [0, 1].
#[derive(Clone, Debug)]
enum Piece {
    Line { p0: Vec3, p1: Vec3, r0: UnitQuat, r1: UnitQuat },
    Arc { c: Vec3, e1: Vec3, e2: Vec3, radius: f64, angle: f64, r0: UnitQuat, r1: UnitQuat },
}

impl Piece {
    fn at(&self, u: f64) -> Iso3 {
        match self {
            Piece::Line { p0, p1, r0, r1 } => pose(p0 + (p1 - p0) * u, r0.slerp(r1, u)),
            Piece::Arc { c, e1, e2, radius, angle, r0, r1 } => {
                let a = angle * u;
                pose(c + (e1 * a.cos() + e2 * a.sin()) * *radius, r0.slerp(r1, u))
            }
        }
    }
    fn length(&self) -> f64 {
        match self {
            Piece::Line { p0, p1, .. } => (p1 - p0).norm(),
            Piece::Arc { radius, angle, .. } => radius * angle.abs(),
        }
    }
    /// Unit tangent of the position at `u` (zero for a rotation-only piece).
    fn tangent(&self, u: f64) -> Vec3 {
        match self {
            Piece::Line { p0, p1, .. } => {
                let d = p1 - p0;
                if d.norm() > 1e-12 { d.normalize() } else { Vec3::zeros() }
            }
            Piece::Arc { e1, e2, angle, .. } => {
                let a = angle * u;
                (e2 * a.cos() - e1 * a.sin()) * angle.signum()
            }
        }
    }
    fn turn(&self) -> f64 {
        match self {
            Piece::Line { r0, r1, .. } | Piece::Arc { r0, r1, .. } => r0.angle_to(r1),
        }
    }
}

/// The geometric path with a single parameter `s` (m): each piece's share is its length, or its
/// rotation angle times `max_lin_vel / max_ang_vel` when that is longer, so one velocity limit
/// on `s` honours both the linear and the angular limits.
struct Geometry {
    pieces: Vec<Piece>,
    /// Cumulative parameter at the start of each piece, plus the total at the end.
    s0: Vec<f64>,
    length: f64,
}

impl Geometry {
    fn total(&self) -> f64 {
        *self.s0.last().unwrap_or(&0.0)
    }
    /// Path parameters where the motion must stop: the ends and every corner where the tangent
    /// jumps (a sharp corner without blend, or a rotation-only piece).
    fn stops(&self) -> Vec<f64> {
        let mut out = vec![0.0];
        for i in 1..self.pieces.len() {
            let (a, b) = (self.pieces[i - 1].tangent(1.0), self.pieces[i].tangent(0.0));
            let smooth = a.norm() > 0.5 && b.norm() > 0.5 && a.dot(&b) > (1e-3f64).cos();
            if !smooth && self.s0[i] > *out.last().unwrap() {
                out.push(self.s0[i]);
            }
        }
        if self.total() > *out.last().unwrap() {
            out.push(self.total());
        }
        out
    }
    fn at(&self, s: f64) -> Iso3 {
        let s = s.clamp(0.0, self.total());
        let mut i = self.s0.partition_point(|x| *x <= s).saturating_sub(1);
        i = i.min(self.pieces.len() - 1);
        let span = self.s0[i + 1] - self.s0[i];
        let u = if span > 0.0 { (s - self.s0[i]) / span } else { 1.0 };
        self.pieces[i].at(u.clamp(0.0, 1.0))
    }
}

fn arc_piece(p0: Vec3, via: Vec3, p1: Vec3, r0: UnitQuat, r1: UnitQuat) -> Result<Piece, KinError> {
    let (a, b) = (via - p0, p1 - p0);
    let n = a.cross(&b);
    if n.norm() < 1e-9 {
        return Err(KinError::new(codes::PATH_INVALID, "arc points are collinear"));
    }
    // Circumcentre.
    let c = p0 + (b.cross(&n) * a.norm_squared() + n.cross(&a) * b.norm_squared()) / (2.0 * n.norm_squared());
    let radius = (p0 - c).norm();
    let e1 = (p0 - c) / radius;
    let nn = n.normalize();
    let e2 = nn.cross(&e1);
    let ang = |p: Vec3| {
        let d = p - c;
        let x = d.dot(&e2).atan2(d.dot(&e1));
        if x < 0.0 { x + 2.0 * std::f64::consts::PI } else { x }
    };
    let angle = ang(p1);
    debug_assert!(ang(via) < angle);
    Ok(Piece::Arc { c, e1, e2, radius, angle, r0, r1 })
}

fn build_geometry(start: &Iso3, segments: &[Segment], opts: &PathOpts) -> Result<Geometry, KinError> {
    if segments.is_empty() {
        return Err(KinError::new(codes::PATH_INVALID, "a path needs at least one waypoint"));
    }
    let mut pieces: Vec<Piece> = vec![];
    let mut cur = *start;
    for seg in segments {
        match seg {
            Segment::Line { to } => {
                pieces.push(Piece::Line { p0: cur.translation.vector, p1: to.translation.vector, r0: cur.rotation, r1: to.rotation });
                cur = *to;
            }
            Segment::Arc { via, to } => {
                pieces.push(arc_piece(cur.translation.vector, *via, to.translation.vector, cur.rotation, to.rotation)?);
                cur = *to;
            }
        }
    }
    // Corner blends between consecutive lines.
    if opts.blend_radius > 0.0 && pieces.len() > 1 {
        let mut out: Vec<Piece> = vec![];
        let mut pending = pieces[0].clone();
        for next in pieces.into_iter().skip(1) {
            match (&pending, &next) {
                (Piece::Line { p0: a0, p1: a1, r0: ar0, r1: ar1 }, Piece::Line { p0: _, p1: b1, r0: br0, r1: br1 }) => {
                    let (la, lb) = ((a1 - a0).norm(), (b1 - a1).norm());
                    let (da, db) = ((a1 - a0) / la.max(1e-300), (b1 - a1) / lb.max(1e-300));
                    let theta = da.dot(&db).clamp(-1.0, 1.0).acos();
                    let b = opts.blend_radius.min(0.5 * la).min(0.5 * lb);
                    if theta < 1e-6 || theta > std::f64::consts::PI - 1e-6 || b < 1e-9 {
                        out.push(pending);
                        pending = next;
                        continue;
                    }
                    let (ua, ub) = (1.0 - b / la, b / lb);
                    let pa = a0 + (a1 - a0) * ua;
                    let pb = a1 + (b1 - a1) * ub;
                    let ra = ar0.slerp(ar1, ua);
                    let rb = br0.slerp(br1, ub);
                    out.push(Piece::Line { p0: *a0, p1: pa, r0: *ar0, r1: ra });
                    // Circular arc tangent to both lines: centre along the bisector.
                    let radius = b / (theta / 2.0).tan();
                    let nrm = da.cross(&db).normalize();
                    let to_c = nrm.cross(&da).normalize();
                    let c = pa + to_c * radius;
                    let e1 = (pa - c) / radius;
                    let e2 = nrm.cross(&e1);
                    out.push(Piece::Arc { c, e1, e2, radius, angle: theta, r0: ra, r1: rb });
                    pending = Piece::Line { p0: pb, p1: *b1, r0: rb, r1: *br1 };
                }
                _ => {
                    out.push(pending);
                    pending = next;
                }
            }
        }
        out.push(pending);
        pieces = out;
    }
    let ratio = opts.max_lin_vel / opts.max_ang_vel;
    let mut s0 = vec![0.0];
    let mut length = 0.0;
    for p in &pieces {
        let l = p.length();
        length += l;
        s0.push(s0.last().unwrap() + l.max(p.turn() * ratio));
    }
    Ok(Geometry { pieces, s0, length })
}

/// A rest-to-rest profile of the path parameter: piecewise constant jerk (or acceleration for
/// the trapezoid).
#[derive(Clone, Debug)]
pub struct MotionProfile {
    /// (duration, jerk, acceleration set at the start of the phase, if any).
    phases: Vec<(f64, f64, Option<f64>)>,
    pub duration: f64,
    pub distance: f64,
    pub peak_velocity: f64,
}

impl MotionProfile {
    /// Trapezoidal profile over `dist` under `vmax`, `amax`.
    pub fn trapezoid(dist: f64, vmax: f64, amax: f64) -> Self {
        let mut ta = vmax / amax;
        let mut vp = vmax;
        let mut tv = dist / vmax - ta;
        if tv < 0.0 {
            vp = (dist * amax).sqrt();
            ta = vp / amax;
            tv = 0.0;
        }
        MotionProfile { phases: vec![(ta, 0.0, Some(amax)), (tv, 0.0, Some(0.0)), (ta, 0.0, Some(-amax))], duration: 2.0 * ta + tv, distance: dist, peak_velocity: vp }
    }

    /// Jerk-limited (double S) symmetric profile over `dist` under `vmax`, `amax`, `jmax`.
    pub fn s_curve(dist: f64, vmax: f64, amax: f64, jmax: f64) -> Self {
        let mut tj = (amax / jmax).min((vmax / jmax).sqrt());
        let mut ap = jmax * tj;
        let mut tc = (vmax / ap - tj).max(0.0);
        let mut vp = ap * (tj + tc);
        let mut tv = dist / vp - (2.0 * tj + tc);
        if tv < 0.0 {
            tv = 0.0;
            // No cruise: dist = ap (tj + tc)(2 tj + tc).
            tc = (-3.0 * tj + (tj * tj + 4.0 * dist / ap).sqrt()) / 2.0;
            if tc < 0.0 {
                tc = 0.0;
                tj = (dist / (2.0 * jmax)).cbrt();
                ap = jmax * tj;
            }
            vp = ap * (tj + tc);
        }
        let j = jmax * (ap / (jmax * tj)).min(1.0);
        let phases = vec![(tj, j, Some(0.0)), (tc, 0.0, None), (tj, -j, None), (tv, 0.0, Some(0.0)), (tj, -j, None), (tc, 0.0, None), (tj, j, None)];
        MotionProfile { phases, duration: 4.0 * tj + 2.0 * tc + tv, distance: dist, peak_velocity: vp }
    }

    /// `(s, sd, sdd)` at time `t` (clamped to the ends).
    pub fn eval(&self, t: f64) -> (f64, f64, f64) {
        let (mut s, mut v, mut a) = (0.0, 0.0, 0.0);
        let mut rest = t.clamp(0.0, self.duration);
        for &(d, j, aset) in &self.phases {
            if let Some(x) = aset {
                a = x;
            }
            let h = rest.min(d);
            s += v * h + a * h * h / 2.0 + j * h * h * h / 6.0;
            v += a * h + j * h * h / 2.0;
            a += j * h;
            rest -= h;
            if rest <= 0.0 {
                break;
            }
        }
        if t >= self.duration {
            return (self.distance, 0.0, 0.0);
        }
        (s.min(self.distance), v.max(0.0), a)
    }
}

/// Rest-to-rest profiles chained over the sections between stops.
struct Timing {
    /// (start time, start parameter, profile).
    sections: Vec<(f64, f64, MotionProfile)>,
    duration: f64,
    peak: f64,
}

impl Timing {
    fn new(stops: &[f64], vmax: f64, amax: f64, jmax: f64, profile: Profile) -> Timing {
        let mut sections = vec![];
        let (mut t, mut peak) = (0.0, 0.0f64);
        for w in stops.windows(2) {
            let p = match profile {
                Profile::Trapezoid => MotionProfile::trapezoid(w[1] - w[0], vmax, amax),
                Profile::SCurve => MotionProfile::s_curve(w[1] - w[0], vmax, amax, jmax),
            };
            peak = peak.max(p.peak_velocity);
            let d = p.duration;
            sections.push((t, w[0], p));
            t += d;
        }
        Timing { sections, duration: t, peak }
    }
    fn s_at(&self, t: f64) -> f64 {
        let i = self.sections.partition_point(|x| x.0 <= t).saturating_sub(1);
        match self.sections.get(i) {
            Some((t0, s0, p)) => s0 + p.eval(t - t0).0,
            None => 0.0,
        }
    }
}

/// Straight lines through `waypoints` (spec form of [`cartesian_segments`]).
pub fn cartesian_path(model: &Model, q_start: &[f64], waypoints: &[Iso3], frame: FrameId, opts: &PathOpts) -> Result<JointTrajectory, KinError> {
    let segs: Vec<Segment> = waypoints.iter().map(|w| Segment::Line { to: *w }).collect();
    cartesian_segments(model, q_start, &segs, frame, opts)
}

/// A Cartesian path of lines and arcs from the tool pose at `q_start`.
pub fn cartesian_segments(model: &Model, q_start: &[f64], segments: &[Segment], frame: FrameId, opts: &PathOpts) -> Result<JointTrajectory, KinError> {
    model.check_q(q_start)?;
    model.check_frame(frame)?;
    for (name, v) in [("max_lin_vel", opts.max_lin_vel), ("max_lin_acc", opts.max_lin_acc), ("max_lin_jerk", opts.max_lin_jerk), ("max_ang_vel", opts.max_ang_vel), ("step", opts.step), ("rate_hz", opts.rate_hz)] {
        if !(v > 0.0) || !v.is_finite() {
            return Err(KinError::new(codes::PATH_INVALID, format!("{name} must be positive")));
        }
    }
    let start = model.fk_frame(q_start, frame)?;
    let geo = build_geometry(&start, segments, opts)?;
    let total = geo.total();
    let ik = IkOptions { max_iters: 30, seeds: 0, ..IkOptions::default() };
    let mut solver = Solver::new(model, &IkProblem::new(vec![IkTask::pose(frame, start)], q_start.to_vec()), &ik)?;
    let solve_at = |solver: &mut Solver, q: &[f64], target: Iso3, idx: usize| -> Result<Vec<f64>, KinError> {
        solver.set_targets(&[target]);
        let r = solver.track(q, ik.max_iters, &ik);
        if !r.converged {
            let at_limit = model.joints.iter().zip(model.q_offsets()).any(|(j, k)| j.kind.is_bounded() && (r.q[k] <= j.limits.lower + 1e-9 || r.q[k] >= j.limits.upper - 1e-9));
            let code = if at_limit { codes::PATH_LIMIT } else { codes::PATH_UNREACHABLE };
            return Err(KinError::at(code, idx, format!("no IK solution at sample {idx} ({:.2e} m, {:.2e} rad off)", r.pos_err[0], r.rot_err[0])));
        }
        Ok(r.q)
    };
    let jump_check = |a: &[f64], b: &[f64], idx: usize| -> Result<(), KinError> {
        let d = model.difference(a, b);
        if let Some(k) = (0..d.len()).find(|&k| d[k].abs() > opts.max_joint_jump) {
            return Err(KinError::at(codes::PATH_BRANCH_FLIP, idx, format!("velocity index {k} jumps {:.3} rad at sample {idx}", d[k])));
        }
        Ok(())
    };
    // 2. Geometric samples.
    let n_geo = ((total / opts.step).ceil() as usize).max(1);
    let mut qs = vec![q_start.to_vec()];
    for i in 1..=n_geo {
        let s = total * i as f64 / n_geo as f64;
        let q = solve_at(&mut solver, qs.last().unwrap(), geo.at(s), i)?;
        jump_check(qs.last().unwrap(), &q, i)?;
        qs.push(q);
    }
    // Joint speed per unit path parameter: the global slow-down bound.
    let ds = total / n_geo as f64;
    let vo = model.v_offsets();
    let mut vlim = vec![f64::INFINITY; model.nv()];
    for (j, joint) in model.joints.iter().enumerate() {
        for k in 0..joint.kind.nv() {
            vlim[vo[j] + k] = joint.limits.velocity;
        }
    }
    let mut vmax = opts.max_lin_vel;
    let mut amax = opts.max_lin_acc;
    if total > 0.0 {
        for w in qs.windows(2) {
            let d = model.difference(&w[0], &w[1]);
            for k in 0..d.len() {
                let rate = d[k].abs() / ds;
                if rate > 0.0 && vlim[k].is_finite() {
                    vmax = vmax.min(0.98 * vlim[k] / rate);
                }
            }
        }
    }
    // 3 and 4: profile, output, check, slow down if needed.
    let dt = 1.0 / opts.rate_hz;
    for _attempt in 0..8 {
        let prof = Timing::new(&geo.stops(), vmax, amax, opts.max_lin_jerk, opts.profile);
        let n = if total > 0.0 { (prof.duration / dt).ceil() as usize } else { 0 };
        let mut t = Vec::with_capacity(n + 1);
        let mut q: Vec<Vec<f64>> = Vec::with_capacity(n + 1);
        let mut dev: f64 = 0.0;
        q.push(q_start.to_vec());
        t.push(0.0);
        for i in 1..=n {
            let ti = (i as f64 * dt).min(prof.duration);
            let s = prof.s_at(ti);
            let target = geo.at(s);
            let qi = solve_at(&mut solver, q.last().unwrap(), target, i)?;
            jump_check(q.last().unwrap(), &qi, i)?;
            let tip = model.fk_frame(&qi, frame)?;
            dev = dev.max((tip.translation.vector - target.translation.vector).norm());
            t.push(ti);
            q.push(qi);
        }
        let m = q.len();
        let nv = model.nv();
        let mut qd = vec![vec![0.0; nv]; m];
        let mut qdd = vec![vec![0.0; nv]; m];
        for i in 1..m.saturating_sub(1) {
            let (h0, h1) = (t[i] - t[i - 1], t[i + 1] - t[i]);
            let d0 = model.difference(&q[i - 1], &q[i]);
            let d1 = model.difference(&q[i], &q[i + 1]);
            for k in 0..nv {
                qd[i][k] = (d0[k] + d1[k]) / (h0 + h1);
                qdd[i][k] = 2.0 * (d1[k] / h1 - d0[k] / h0) / (h0 + h1);
            }
        }
        // Check joint velocity and acceleration limits on the samples.
        let mut ratio_v: f64 = 0.0;
        let mut ratio_a: f64 = 0.0;
        for i in 0..m {
            for k in 0..nv {
                if vlim[k].is_finite() {
                    ratio_v = ratio_v.max(qd[i][k].abs() / vlim[k]);
                }
                if opts.max_joint_acc.is_finite() {
                    ratio_a = ratio_a.max(qdd[i][k].abs() / opts.max_joint_acc);
                }
            }
        }
        if ratio_v <= 1.0 && ratio_a <= 1.0 {
            let actuators = q.iter().map(|x| model.to_actuators(x)).collect();
            // Joint limits: IK keeps bounded joints inside; check anyway.
            let qo = model.q_offsets();
            for (i, x) in q.iter().enumerate() {
                for (j, joint) in model.joints.iter().enumerate() {
                    if joint.kind.is_bounded() && (x[qo[j]] < joint.limits.lower - 1e-9 || x[qo[j]] > joint.limits.upper + 1e-9) {
                        return Err(KinError::at(codes::PATH_LIMIT, i, format!("joint {} leaves its limits", joint.name)));
                    }
                }
            }
            return Ok(JointTrajectory { t, q, qd, qdd, actuators, max_deviation: dev, length: geo.length, peak_speed: prof.peak });
        }
        if ratio_v > 1.0 {
            vmax /= ratio_v * 1.02;
        }
        if ratio_a > 1.0 {
            amax /= ratio_a * 1.02;
            vmax /= ratio_a.sqrt() * 1.01;
        }
    }
    Err(KinError::new(codes::PATH_LIMIT, "the joint speed limits could not be met"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profiles_reach_the_distance_within_limits() {
        for &d in &[0.001, 0.05, 0.3, 2.0] {
            for prof in [MotionProfile::trapezoid(d, 0.2, 1.0), MotionProfile::s_curve(d, 0.2, 1.0, 10.0)] {
                let (s, v, _) = prof.eval(prof.duration);
                assert!((s - d).abs() < 1e-12 && v == 0.0);
                let n = 2000;
                let mut last = 0.0;
                for i in 0..=n {
                    let t = prof.duration * i as f64 / n as f64;
                    let (s, v, a) = prof.eval(t);
                    assert!(s >= last - 1e-15, "monotone");
                    last = s;
                    assert!(v <= 0.2 + 1e-12 && a.abs() <= 1.0 + 1e-9, "v {v} a {a}");
                }
                let (s_end, _, _) = prof.eval(prof.duration * (1.0 - 1e-12));
                assert!((s_end - d).abs() < 1e-9, "{s_end} vs {d}");
            }
        }
    }
}
