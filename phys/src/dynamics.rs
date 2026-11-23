//! Rigid-body dynamics algorithms on the kinematic tree (Featherstone 2008): the
//! articulated-body algorithm (ABA, forward dynamics, chapter 7), the recursive Newton-Euler
//! algorithm (RNEA, inverse dynamics, chapter 5) and the composite rigid body algorithm (CRBA,
//! joint-space mass matrix, chapter 6). Multi-DOF joints (spherical, floating) use their 3 or 6
//! column motion subspace; scalar joints take a fast path.
//!
//! Base: link 0 is fixed to the world. Gravity enters as a base acceleration `-g`.
//! External forces are spatial forces per link in link coordinates (`[torque; force]` about the
//! link origin).

use nalgebra::{DMatrix, Matrix3};
use viaform_kin::Iso3;

use crate::model::PhysModel;
use crate::spatial::{M6, V3, V6, Xf, crf, crm};

/// Scratch space for the algorithms (allocated once per world).
#[derive(Clone, Debug)]
pub struct Ws {
    /// World pose of every link.
    pub poses: Vec<Iso3>,
    /// Per joint: transform from the parent link to the child link.
    pub xj: Vec<Xf>,
    /// Per link: transform from the world to the link.
    pub xw: Vec<Xf>,
    /// Per velocity index: its motion axis in world coordinates (at the world origin).
    pub sw: Vec<V6>,
    pub vel: Vec<V6>,
    pub acc: Vec<V6>,
    pub cc: Vec<V6>,
    pub ia: Vec<M6>,
    pub pa: Vec<V6>,
    pub uu: Vec<M6>,
    pub dinv: Vec<M6>,
    pub ub: Vec<V6>,
    pub f: Vec<V6>,
    pub h: DMatrix<f64>,
}

impl Ws {
    pub fn new(m: &PhysModel) -> Self {
        let nl = m.nlinks();
        let nj = m.joints.len();
        Ws {
            poses: vec![Iso3::identity(); nl],
            xj: vec![Xf::identity(); nj],
            xw: vec![Xf::identity(); nl],
            sw: vec![V6::zeros(); m.nv()],
            vel: vec![V6::zeros(); nl],
            acc: vec![V6::zeros(); nl],
            cc: vec![V6::zeros(); nl],
            ia: vec![M6::zeros(); nl],
            pa: vec![V6::zeros(); nl],
            uu: vec![M6::zeros(); nj],
            dinv: vec![M6::zeros(); nj],
            ub: vec![V6::zeros(); nj],
            f: vec![V6::zeros(); nl],
            h: DMatrix::zeros(m.nv(), m.nv()),
        }
    }
}

#[inline]
fn s_times(s: &M6, nv: usize, x: &[f64]) -> V6 {
    let mut out = V6::zeros();
    for k in 0..nv {
        out += s.column(k) * x[k];
    }
    out
}

/// Link poses, joint transforms and world motion axes for configuration `q`.
pub fn kinematics(m: &PhysModel, q: &[f64], ws: &mut Ws) {
    ws.poses[0] = Iso3::identity();
    ws.xw[0] = Xf::identity();
    for (j, jt) in m.joints.iter().enumerate() {
        let t = jt.origin * m.kin.joint_motion(j, &q[jt.qo..jt.qo + jt.nq]);
        ws.xj[j] = Xf::from_pose(&t);
        let p = ws.poses[jt.parent] * t;
        ws.poses[jt.child] = p;
        ws.xw[jt.child] = Xf::from_pose(&p);
        for k in 0..jt.nv {
            ws.sw[jt.vo + k] = ws.xw[jt.child].inv_motion(&jt.s.column(k).into_owned());
        }
    }
}

/// Body velocities (link coordinates) for `v`; needs [`kinematics`] first.
pub fn velocities(m: &PhysModel, v: &[f64], ws: &mut Ws) {
    ws.vel[0] = V6::zeros();
    for (j, jt) in m.joints.iter().enumerate() {
        let vj = s_times(&jt.s, jt.nv, &v[jt.vo..jt.vo + jt.nv]);
        ws.vel[jt.child] = ws.xj[j].motion(&ws.vel[jt.parent]) + vj;
    }
}

/// Spatial base acceleration for gravity `g`.
#[inline]
pub fn base_acc(g: &V3) -> V6 {
    V6::new(0.0, 0.0, 0.0, -g.x, -g.y, -g.z)
}

/// Articulated-body algorithm: `qdd = (M + diag(armature))^-1 (tau - c(q, v) + J^T f_ext)`.
/// `armature` is per velocity index (implicit damping and springs enter here as `dt d + dt^2 k`).
/// Needs [`kinematics`] for `q` first.
pub fn aba(m: &PhysModel, v: &[f64], tau: &[f64], fext: Option<&[V6]>, armature: &[f64], g: &V3, ws: &mut Ws, qdd: &mut [f64]) {
    let nl = m.nlinks();
    ws.vel[0] = V6::zeros();
    for (j, jt) in m.joints.iter().enumerate() {
        let c = jt.child;
        let vj = s_times(&jt.s, jt.nv, &v[jt.vo..jt.vo + jt.nv]);
        let vc = ws.xj[j].motion(&ws.vel[jt.parent]) + vj;
        ws.vel[c] = vc;
        ws.cc[c] = crm(&vc, &vj);
        let i = &m.inertia[c];
        ws.ia[c] = *i;
        ws.pa[c] = crf(&vc, &(i * vc));
        if let Some(fe) = fext {
            ws.pa[c] -= fe[c];
        }
    }
    let _ = nl;
    for j in (0..m.joints.len()).rev() {
        let jt = &m.joints[j];
        let c = jt.child;
        let (ia_c, pa_c) = (ws.ia[c], ws.pa[c]);
        let (ia_up, pa_up);
        match jt.nv {
            0 => {
                ia_up = ia_c;
                pa_up = pa_c + ia_c * ws.cc[c];
            }
            1 => {
                let u = ia_c * jt.s0;
                let d = jt.s0.dot(&u) + armature[jt.vo];
                let di = 1.0 / d;
                let ub = tau[jt.vo] - jt.s0.dot(&pa_c);
                let mut um = M6::zeros();
                um.set_column(0, &u);
                ws.uu[j] = um;
                ws.dinv[j][(0, 0)] = di;
                ws.ub[j][0] = ub;
                ia_up = ia_c - u * u.transpose() * di;
                pa_up = pa_c + ia_up * ws.cc[c] + u * (di * ub);
            }
            nv => {
                let u = ia_c * jt.s;
                let mut d = jt.s.transpose() * u;
                for k in 0..6 {
                    if k < nv {
                        d[(k, k)] += armature[jt.vo + k];
                    } else {
                        d[(k, k)] = 1.0;
                    }
                }
                let mut di = d.try_inverse().unwrap_or_else(M6::zeros);
                for r in 0..6 {
                    for k in 0..6 {
                        if r >= nv || k >= nv {
                            di[(r, k)] = 0.0;
                        }
                    }
                }
                let mut ub = V6::zeros();
                let sp = jt.s.transpose() * pa_c;
                for k in 0..nv {
                    ub[k] = tau[jt.vo + k] - sp[k];
                }
                ws.uu[j] = u;
                ws.dinv[j] = di;
                ws.ub[j] = ub;
                ia_up = ia_c - u * di * u.transpose();
                pa_up = pa_c + ia_up * ws.cc[c] + u * (di * ub);
            }
        }
        let p = jt.parent;
        if p != 0 {
            let x = &ws.xj[j];
            ws.ia[p] += x.inertia_to_parent(&ia_up);
            ws.pa[p] += x.inv_force(&pa_up);
        }
    }
    ws.acc[0] = base_acc(g);
    for (j, jt) in m.joints.iter().enumerate() {
        let c = jt.child;
        let ap = ws.xj[j].motion(&ws.acc[jt.parent]) + ws.cc[c];
        match jt.nv {
            0 => ws.acc[c] = ap,
            1 => {
                let x = ws.dinv[j][(0, 0)] * (ws.ub[j][0] - ws.uu[j].column(0).dot(&ap));
                qdd[jt.vo] = x;
                ws.acc[c] = ap + jt.s0 * x;
            }
            nv => {
                let rhs = ws.ub[j] - ws.uu[j].transpose() * ap;
                let x = ws.dinv[j] * rhs;
                qdd[jt.vo..jt.vo + nv].copy_from_slice(&x.as_slice()[..nv]);
                ws.acc[c] = ap + jt.s * x;
            }
        }
    }
}

/// Recursive Newton-Euler: `tau = M(q) qdd + c(q, v) - J^T f_ext`. Leaves in `ws.f[link]` the
/// spatial force the parent joint transmits to each link (link coordinates, about its origin)
/// and in `ws.acc` the link accelerations (gravity removed: `acc[0] = -g`).
/// Needs [`kinematics`] for `q` first.
pub fn rnea(m: &PhysModel, v: &[f64], qdd: &[f64], fext: Option<&[V6]>, g: &V3, ws: &mut Ws, tau: &mut [f64]) {
    ws.vel[0] = V6::zeros();
    ws.acc[0] = base_acc(g);
    for (j, jt) in m.joints.iter().enumerate() {
        let c = jt.child;
        let vj = s_times(&jt.s, jt.nv, &v[jt.vo..jt.vo + jt.nv]);
        let aj = s_times(&jt.s, jt.nv, &qdd[jt.vo..jt.vo + jt.nv]);
        let x = &ws.xj[j];
        let vc = x.motion(&ws.vel[jt.parent]) + vj;
        ws.vel[c] = vc;
        ws.acc[c] = x.motion(&ws.acc[jt.parent]) + aj + crm(&vc, &vj);
        let i = &m.inertia[c];
        ws.f[c] = i * ws.acc[c] + crf(&vc, &(i * vc));
        if let Some(fe) = fext {
            ws.f[c] -= fe[c];
        }
    }
    for j in (0..m.joints.len()).rev() {
        let jt = &m.joints[j];
        let c = jt.child;
        let fc = ws.f[c];
        for k in 0..jt.nv {
            tau[jt.vo + k] = jt.s.column(k).dot(&fc);
        }
        if jt.parent != 0 {
            let up = ws.xj[j].inv_force(&fc);
            ws.f[jt.parent] += up;
        }
    }
}

/// Composite rigid body algorithm: the joint-space mass matrix into `ws.h` (armature on the
/// diagonal). Needs [`kinematics`] for `q` first.
pub fn crba(m: &PhysModel, armature: &[f64], ws: &mut Ws) {
    let nv = m.nv();
    ws.h.fill(0.0);
    for l in 0..m.nlinks() {
        ws.ia[l] = m.inertia[l];
    }
    for j in (0..m.joints.len()).rev() {
        let jt = &m.joints[j];
        let c = jt.child;
        if jt.nv > 0 {
            let ic = ws.ia[c];
            let mut f = ic * jt.s;
            for a in 0..jt.nv {
                for b in 0..jt.nv {
                    ws.h[(jt.vo + a, jt.vo + b)] = jt.s.column(a).dot(&f.column(b));
                }
            }
            let mut k = j;
            while m.joints[k].parent != 0 {
                // Move f to the parent link of joint k.
                let x = &ws.xj[k];
                for col in 0..jt.nv {
                    let fc: V6 = f.column(col).into_owned();
                    f.set_column(col, &x.inv_force(&fc));
                }
                k = m.joints[k].parent - 1;
                let jk = &m.joints[k];
                for a in 0..jt.nv {
                    for b in 0..jk.nv {
                        let val = f.column(a).dot(&jk.s.column(b));
                        ws.h[(jt.vo + a, jk.vo + b)] = val;
                        ws.h[(jk.vo + b, jt.vo + a)] = val;
                    }
                }
            }
        }
        if jt.parent != 0 {
            let up = ws.xj[j].inertia_to_parent(&ws.ia[c]);
            ws.ia[jt.parent] += up;
        }
    }
    for i in 0..nv {
        ws.h[(i, i)] += armature[i];
    }
}

/// Kinetic energy `1/2 v^T M v` (needs [`kinematics`]).
pub fn kinetic_energy(m: &PhysModel, v: &[f64], ws: &mut Ws) -> f64 {
    velocities(m, v, ws);
    (1..m.nlinks()).map(|l| 0.5 * ws.vel[l].dot(&(m.inertia[l] * ws.vel[l]))).sum()
}

/// Potential energy of gravity `-sum m g . c_world` (needs [`kinematics`]).
pub fn potential_energy(m: &PhysModel, g: &V3, ws: &Ws) -> f64 {
    (1..m.nlinks()).map(|l| -m.mass[l] * g.dot(&(ws.poses[l] * nalgebra::Point3::from(m.com[l])).coords)).sum()
}

/// World linear velocity of a point `p` (world coordinates) fixed on `link`, from the world
/// motion axes (needs [`kinematics`]).
pub fn point_velocity(m: &PhysModel, ws: &Ws, link: usize, p: &V3, v: &[f64]) -> V3 {
    let mut out = V3::zeros();
    for &k in &m.support[link] {
        let s = &ws.sw[k];
        out += (V3::new(s[3], s[4], s[5]) + V3::new(s[0], s[1], s[2]).cross(p)) * v[k];
    }
    out
}

/// Column `k` of the linear point Jacobian of `p` (world) on a link that `k` moves.
#[inline]
pub fn point_jacobian_col(ws: &Ws, k: usize, p: &V3) -> V3 {
    let s = &ws.sw[k];
    V3::new(s[3], s[4], s[5]) + V3::new(s[0], s[1], s[2]).cross(p)
}

/// Column `k` of the angular Jacobian.
#[inline]
pub fn angular_jacobian_col(ws: &Ws, k: usize) -> V3 {
    let s = &ws.sw[k];
    V3::new(s[0], s[1], s[2])
}

/// Rotation part helper.
pub fn rot(p: &Iso3) -> Matrix3<f64> {
    p.rotation.to_rotation_matrix().into_inner()
}
