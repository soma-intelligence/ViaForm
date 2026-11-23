//! Tendons (E-13, RUST-ENGINES 6.2): a cable from a tendon motor routed through via points on
//! links (or a fixed tendon given by its moment arms). Path length `L(q)` is the sum of the
//! straight runs; the moment arms are `r = -dL/dq`. With excursion `a` (pull positive) the cable
//! stretch is `s = a - (L0 - L(q)) - slack`, and the tension
//! `T = k max(0, s) + c ds/dt` (cables only pull), clipped to the tension limit, acts on the
//! joints as `tau = r T`. The cable is one row of the contact solver (unilateral, compliant,
//! implicit), so stiff cables on light fingers stay stable.

use viaform_kin::{Iso3, Vec3};

use crate::dynamics::{Ws, point_jacobian_col};
use crate::model::{PhysModel, TendonModel};

/// Path length through the via points at the link poses.
pub fn path_length(routing: &[(usize, Vec3)], poses: &[Iso3]) -> f64 {
    let pts: Vec<Vec3> = routing.iter().map(|(l, p)| (poses[*l] * nalgebra::Point3::from(*p)).coords).collect();
    pts.windows(2).map(|w| (w[1] - w[0]).norm()).sum()
}

/// Current path shortening `e(q) = L0 - L(q)` (m) and moment arms `r` per velocity index into
/// `arms` (cleared first; zero where the tendon does not act). Needs `kinematics`.
pub fn geometry(m: &PhysModel, t: &TendonModel, q: &[f64], ws: &Ws, arms: &mut [f64]) -> f64 {
    arms.iter_mut().for_each(|x| *x = 0.0);
    if t.routing.len() < 2 {
        let mut e = 0.0;
        for &(vi, r) in &t.arms {
            arms[vi] += r;
            // Fixed tendon: shortening = sum r_j q_j (scalar joints share q and v indices
            // offsets through the joint table).
            let j = m.dof_joint[vi];
            e += r * q[m.joints[j].qo];
        }
        return e;
    }
    let pts: Vec<Vec3> = t.routing.iter().map(|(l, p)| (ws.poses[*l] * nalgebra::Point3::from(*p)).coords).collect();
    let mut len = 0.0;
    for k in 0..pts.len() - 1 {
        let d = pts[k + 1] - pts[k];
        let n = d.norm();
        len += n;
        if n < 1e-12 {
            continue;
        }
        let u = d / n;
        let (la, lb) = (t.routing[k].0, t.routing[k + 1].0);
        // dL/dv = u . (J_b - J_a); r = -dL/dv.
        for &c in &m.support[lb] {
            arms[c] -= u.dot(&point_jacobian_col(ws, c, &pts[k + 1]));
        }
        for &c in &m.support[la] {
            arms[c] += u.dot(&point_jacobian_col(ws, c, &pts[k]));
        }
    }
    t.length0 - len
}
