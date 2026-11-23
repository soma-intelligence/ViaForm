//! Forward kinematics and geometric Jacobians (RUST-ENGINES 4.2), plus configuration-space
//! helpers (integrate, difference, random configurations).

use nalgebra::{Matrix3xX, Point3, Translation3};

use crate::error::{KinError, codes};
use crate::math::{Iso3, Jacobian, Rng, UnitQuat, Vec3, pose};
use crate::model::{FrameId, JointKind, Model};

impl Model {
    /// The motion of joint `j` for its slice of `q` (`T_joint_child`).
    pub fn joint_motion(&self, j: usize, q: &[f64]) -> Iso3 {
        let joint = &self.joints[j];
        match joint.kind {
            JointKind::Fixed => Iso3::identity(),
            JointKind::Revolute | JointKind::Continuous | JointKind::Wheel => {
                Iso3::from_parts(Translation3::identity(), UnitQuat::from_axis_angle(&nalgebra::Unit::new_unchecked(joint.axis), q[0]))
            }
            JointKind::Prismatic => Iso3::from_parts(Translation3::from(joint.axis * q[0]), UnitQuat::identity()),
            JointKind::Spherical => Iso3::from_parts(Translation3::identity(), quat_at(q, 0)),
            JointKind::Floating => pose(Vec3::new(q[0], q[1], q[2]), quat_at(q, 3)),
        }
    }

    /// Poses of every link in the world for configuration `q`.
    pub fn fk(&self, q: &[f64]) -> Result<Vec<Iso3>, KinError> {
        self.check_q(q)?;
        let mut out = Vec::with_capacity(self.links.len());
        self.fk_into(q, &mut out);
        Ok(out)
    }

    /// [`Model::fk`] into a buffer, without checking `q` (it must have length `nq`).
    pub fn fk_into(&self, q: &[f64], out: &mut Vec<Iso3>) {
        out.clear();
        out.push(Iso3::identity());
        let mut k = 0;
        for (i, joint) in self.joints.iter().enumerate() {
            let n = joint.kind.nq();
            let parent = out[joint.parent];
            let child = parent * joint.origin * self.joint_motion(i, &q[k..k + n]);
            out.push(child);
            k += n;
        }
    }

    /// Pose of tool frame `frame` given the link poses.
    pub fn frame_pose(&self, poses: &[Iso3], frame: FrameId) -> Iso3 {
        let f = &self.end_effectors[frame];
        poses[f.link] * f.offset
    }

    /// Pose of tool frame `frame` at `q`.
    pub fn fk_frame(&self, q: &[f64], frame: FrameId) -> Result<Iso3, KinError> {
        self.check_frame(frame)?;
        let poses = self.fk(q)?;
        Ok(self.frame_pose(&poses, frame))
    }

    pub(crate) fn check_frame(&self, frame: FrameId) -> Result<(), KinError> {
        if frame >= self.end_effectors.len() {
            return Err(KinError::new(codes::UNKNOWN_NAME, format!("no tool frame {frame}")));
        }
        Ok(())
    }

    /// Geometric Jacobian of tool frame `frame` at `q`: 6 x nv, rows linear velocity of the
    /// frame origin then angular velocity, both in world coordinates. Column for a revolute joint
    /// `[z x (p - o); z]`, prismatic `[z; 0]`, spherical and floating per local axis.
    pub fn jacobian(&self, q: &[f64], frame: FrameId) -> Result<Jacobian, KinError> {
        self.check_frame(frame)?;
        let poses = self.fk(q)?;
        let mut j = Jacobian::zeros(self.nv());
        let p = self.frame_pose(&poses, frame).translation.vector;
        self.jacobian_into(&poses, self.end_effectors[frame].link, &p, &mut j);
        Ok(j)
    }

    /// Jacobian of the point `p` (world) rigidly attached to `link`, given link poses, into `out`
    /// (6 x nv, zeroed first). Used by IK to avoid allocations.
    pub fn jacobian_into(&self, poses: &[Iso3], link: usize, p: &Vec3, out: &mut Jacobian) {
        out.fill(0.0);
        let mut l = link;
        let vo = if l > 0 { self.v_offsets() } else { vec![] };
        while l > 0 {
            let ji = l - 1;
            let joint = &self.joints[ji];
            let child = &poses[l];
            let o = child.translation.vector;
            let k = vo[ji];
            match joint.kind {
                JointKind::Fixed => {}
                JointKind::Revolute | JointKind::Continuous | JointKind::Wheel => {
                    let z = child.rotation * joint.axis;
                    let lin = z.cross(&(p - o));
                    out.fixed_view_mut::<3, 1>(0, k).copy_from(&lin);
                    out.fixed_view_mut::<3, 1>(3, k).copy_from(&z);
                }
                JointKind::Prismatic => {
                    let z = child.rotation * joint.axis;
                    out.fixed_view_mut::<3, 1>(0, k).copy_from(&z);
                }
                JointKind::Spherical => {
                    let r = child.rotation.to_rotation_matrix();
                    for a in 0..3 {
                        let z: Vec3 = r.matrix().column(a).into();
                        out.fixed_view_mut::<3, 1>(0, k + a).copy_from(&z.cross(&(p - o)));
                        out.fixed_view_mut::<3, 1>(3, k + a).copy_from(&z);
                    }
                }
                JointKind::Floating => {
                    let r = child.rotation.to_rotation_matrix();
                    for a in 0..3 {
                        let z: Vec3 = r.matrix().column(a).into();
                        out.fixed_view_mut::<3, 1>(0, k + a).copy_from(&z);
                        out.fixed_view_mut::<3, 1>(0, k + 3 + a).copy_from(&z.cross(&(p - o)));
                        out.fixed_view_mut::<3, 1>(3, k + 3 + a).copy_from(&z);
                    }
                }
            }
            l = joint.parent;
        }
    }

    /// Linear-velocity Jacobian (3 x nv) of the world point `p` attached to `link`.
    pub fn point_jacobian(&self, poses: &[Iso3], link: usize, p: &Vec3) -> Matrix3xX<f64> {
        let mut j = Jacobian::zeros(self.nv());
        self.jacobian_into(poses, link, p, &mut j);
        j.fixed_rows::<3>(0).into_owned()
    }

    /// `q (+) v`: moves `q` by the velocity step `v` (scalar joints add, spherical and floating
    /// joints compose on the right in their child frame). Bounded joints are not clamped.
    pub fn integrate(&self, q: &[f64], v: &[f64]) -> Vec<f64> {
        let mut out = q.to_vec();
        let (mut kq, mut kv) = (0, 0);
        for joint in &self.joints {
            match joint.kind {
                JointKind::Fixed => {}
                JointKind::Spherical => {
                    let r = quat_at(q, kq) * UnitQuat::from_scaled_axis(Vec3::new(v[kv], v[kv + 1], v[kv + 2]));
                    put_quat(&mut out, kq, &r);
                }
                JointKind::Floating => {
                    let r0 = quat_at(q, kq + 3);
                    let dp = r0 * Vec3::new(v[kv], v[kv + 1], v[kv + 2]);
                    for a in 0..3 {
                        out[kq + a] += dp[a];
                    }
                    let r = r0 * UnitQuat::from_scaled_axis(Vec3::new(v[kv + 3], v[kv + 4], v[kv + 5]));
                    put_quat(&mut out, kq + 3, &r);
                }
                _ => out[kq] += v[kv],
            }
            kq += joint.kind.nq();
            kv += joint.kind.nv();
        }
        out
    }

    /// `q1 (-) q0`: the velocity step `v` with `integrate(q0, v) == q1` (to first order for
    /// floating positions).
    pub fn difference(&self, q0: &[f64], q1: &[f64]) -> Vec<f64> {
        let mut v = vec![0.0; self.nv()];
        let (mut kq, mut kv) = (0, 0);
        for joint in &self.joints {
            match joint.kind {
                JointKind::Fixed => {}
                JointKind::Spherical => {
                    let d = (quat_at(q0, kq).inverse() * quat_at(q1, kq)).scaled_axis();
                    v[kv..kv + 3].copy_from_slice(d.as_slice());
                }
                JointKind::Floating => {
                    let r0 = quat_at(q0, kq + 3);
                    let dp = r0.inverse() * Vec3::new(q1[kq] - q0[kq], q1[kq + 1] - q0[kq + 1], q1[kq + 2] - q0[kq + 2]);
                    v[kv..kv + 3].copy_from_slice(dp.as_slice());
                    let d = (r0.inverse() * quat_at(q1, kq + 3)).scaled_axis();
                    v[kv + 3..kv + 6].copy_from_slice(d.as_slice());
                }
                _ => v[kv] = q1[kq] - q0[kq],
            }
            kq += joint.kind.nq();
            kv += joint.kind.nv();
        }
        v
    }

    /// A random configuration: bounded scalar joints uniform in their limits, unbounded ones
    /// uniform in [-pi, pi], spherical joints uniform rotations (within their angle limit),
    /// floating joints a uniform rotation at the origin. Coupled joints follow random actuator
    /// values uniform in [`Model::actuator_bounds`] (unbounded: [-pi, pi]).
    pub fn random_q(&self, rng: &mut Rng) -> Vec<f64> {
        let bounds = self.actuator_bounds();
        let a: Vec<f64> = bounds.iter().map(|&(lo, hi)| {
            let (lo, hi) = (if lo.is_finite() { lo } else { -std::f64::consts::PI }, if hi.is_finite() { hi } else { std::f64::consts::PI });
            rng.range(lo, hi)
        }).collect();
        let mut q = self.neutral();
        let mut k = 0;
        for joint in &self.joints {
            match joint.kind {
                JointKind::Spherical => {
                    let mut r = rng.rotation();
                    if joint.limits.upper.is_finite() && r.angle() > joint.limits.upper {
                        r = UnitQuat::from_scaled_axis(r.scaled_axis() * (joint.limits.upper / r.angle()) * rng.uniform());
                    }
                    put_quat(&mut q, k, &r);
                }
                JointKind::Floating => put_quat(&mut q, k + 3, &rng.rotation()),
                _ => {}
            }
            k += joint.kind.nq();
        }
        self.apply_actuators(&a, &mut q);
        q
    }

    /// World position of a point given in a link frame.
    pub fn link_point(&self, poses: &[Iso3], link: usize, p: &Vec3) -> Vec3 {
        (poses[link] * Point3::from(*p)).coords
    }
}

/// The unit quaternion stored as `[w, x, y, z]` at `q[k..k + 4]`.
pub fn quat_at(q: &[f64], k: usize) -> UnitQuat {
    UnitQuat::from_quaternion(nalgebra::Quaternion::new(q[k], q[k + 1], q[k + 2], q[k + 3]))
}

/// Writes a unit quaternion as `[w, x, y, z]` at `q[k..k + 4]`.
pub fn put_quat(q: &mut [f64], k: usize, r: &UnitQuat) {
    let c = r.quaternion();
    q[k] = c.w;
    q[k + 1] = c.i;
    q[k + 2] = c.j;
    q[k + 3] = c.k;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::{pose_xyz_rpy, rot_error};
    use crate::model::{Frame, Joint, Limits, Link};

    /// A tree with every joint kind: floating body, revolute, prismatic, spherical, fixed,
    /// continuous, and two branches.
    pub(crate) fn zoo() -> Model {
        let link = |n: &str| Link { name: n.into(), inertial: None };
        let j = |name: &str, kind: JointKind, parent: usize, xyz: [f64; 3], rpy: [f64; 3], axis: [f64; 3]| Joint { name: name.into(), kind, parent, origin: pose_xyz_rpy(xyz, rpy), axis: Vec3::from(axis), limits: Limits { lower: -2.0, upper: 2.0, ..Limits::default() } };
        let mut m = Model {
            name: "zoo".into(),
            links: ["world", "body", "a1", "a2", "a3", "a4", "b1", "b2"].iter().map(|n| link(n)).collect(),
            joints: vec![
                j("float", JointKind::Floating, 0, [0.1, 0.0, 0.5], [0.0, 0.0, 0.3], [0.0, 0.0, 1.0]),
                j("rev", JointKind::Revolute, 1, [0.05, 0.02, 0.1], [0.2, -0.1, 0.4], [0.3, 1.0, -0.2]),
                j("pri", JointKind::Prismatic, 2, [0.0, 0.1, 0.2], [0.0, 0.5, 0.0], [1.0, 0.2, 0.1]),
                j("ball", JointKind::Spherical, 3, [0.1, 0.0, 0.05], [0.3, 0.2, 0.1], [0.0, 0.0, 1.0]),
                j("fix", JointKind::Fixed, 4, [0.0, 0.03, 0.12], [0.1, 0.0, 0.0], [0.0, 0.0, 1.0]),
                j("cont", JointKind::Continuous, 1, [-0.1, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
                j("rev2", JointKind::Revolute, 6, [0.0, 0.0, -0.2], [0.0, 0.3, 0.0], [1.0, 0.0, 0.0]),
            ],
            actuators: vec![],
            couplings: vec![],
            end_effectors: vec![
                Frame { name: "tip_a".into(), link: 5, offset: pose_xyz_rpy([0.02, 0.01, 0.07], [0.1, 0.2, 0.3]) },
                Frame { name: "tip_b".into(), link: 7, offset: pose_xyz_rpy([0.0, 0.0, -0.1], [0.0; 3]) },
            ],
        };
        m.normalize().unwrap();
        m
    }

    #[test]
    fn jacobian_matches_finite_differences() {
        let m = zoo();
        let mut rng = Rng::new(7);
        let h = 1e-7;
        let mut worst: f64 = 0.0;
        for _ in 0..50 {
            let q = m.random_q(&mut rng);
            let mut q = m.integrate(&q, &(0..m.nv()).map(|_| rng.range(-0.5, 0.5)).collect::<Vec<_>>());
            q[0] = rng.range(-1.0, 1.0);
            for f in 0..m.end_effectors.len() {
                let j = m.jacobian(&q, f).unwrap();
                for k in 0..m.nv() {
                    let mut e = vec![0.0; m.nv()];
                    e[k] = h;
                    let tp = m.fk_frame(&m.integrate(&q, &e), f).unwrap();
                    e[k] = -h;
                    let tm = m.fk_frame(&m.integrate(&q, &e), f).unwrap();
                    let dp = (tp.translation.vector - tm.translation.vector) / (2.0 * h);
                    let dw = rot_error(&tp.rotation, &tm.rotation) / (2.0 * h);
                    let col = j.column(k);
                    let an = nalgebra::Vector6::new(col[0], col[1], col[2], col[3], col[4], col[5]);
                    let fd = nalgebra::Vector6::new(dp.x, dp.y, dp.z, dw.x, dw.y, dw.z);
                    let rel = (an - fd).norm() / an.norm().max(1e-3);
                    worst = worst.max(rel);
                }
            }
        }
        assert!(worst < 1e-6, "worst relative error {worst:e}");
    }

    #[test]
    fn integrate_and_difference_are_inverse() {
        let m = zoo();
        let mut rng = Rng::new(3);
        for _ in 0..20 {
            let q0 = m.random_q(&mut rng);
            let v: Vec<f64> = (0..m.nv()).map(|_| rng.range(-0.3, 0.3)).collect();
            let q1 = m.integrate(&q0, &v);
            let back = m.difference(&q0, &q1);
            for k in 0..m.nv() {
                assert!((back[k] - v[k]).abs() < 1e-12, "{k}: {} vs {}", back[k], v[k]);
            }
        }
    }

    #[test]
    fn fk_of_a_planar_arm_is_closed_form() {
        // Two revolute joints about z, links 0.3 and 0.2 along x.
        let mut m = zoo();
        m.links.truncate(3);
        m.joints = vec![
            Joint { name: "j1".into(), kind: JointKind::Revolute, parent: 0, origin: Iso3::identity(), axis: Vec3::z(), limits: Limits::default() },
            Joint { name: "j2".into(), kind: JointKind::Revolute, parent: 1, origin: pose_xyz_rpy([0.3, 0.0, 0.0], [0.0; 3]), axis: Vec3::z(), limits: Limits::default() },
        ];
        m.end_effectors = vec![Frame { name: "tip".into(), link: 2, offset: pose_xyz_rpy([0.2, 0.0, 0.0], [0.0; 3]) }];
        m.actuators.clear();
        m.couplings.clear();
        m.normalize().unwrap();
        let (a, b) = (0.4_f64, -0.9_f64);
        let p = m.fk_frame(&[a, b], 0).unwrap().translation.vector;
        let x = 0.3 * a.cos() + 0.2 * (a + b).cos();
        let y = 0.3 * a.sin() + 0.2 * (a + b).sin();
        assert!((p - Vec3::new(x, y, 0.0)).norm() < 1e-15);
    }
}
