//! Spatial vector algebra (Featherstone 2008, chapter 2) on nalgebra 6-vectors.
//!
//! Convention: a spatial vector is `[angular; linear]`. Motion vectors are `[w; v]`, force
//! vectors are `[n; f]`. A Plucker transform [`Xf`] from frame A to frame B is stored as the
//! rotation `e` (B coordinates of A axes, `E = R^T` for a pose `R` of B in A) and the position `r`
//! of B's origin in A coordinates.

use nalgebra::{Matrix3, Matrix6, Vector3, Vector6};
use viaform_kin::Iso3;

pub type V3 = Vector3<f64>;
pub type M3 = Matrix3<f64>;
pub type V6 = Vector6<f64>;
pub type M6 = Matrix6<f64>;

#[inline]
pub fn ang(m: &V6) -> V3 {
    V3::new(m[0], m[1], m[2])
}

#[inline]
pub fn lin(m: &V6) -> V3 {
    V3::new(m[3], m[4], m[5])
}

#[inline]
pub fn v6(a: &V3, l: &V3) -> V6 {
    V6::new(a.x, a.y, a.z, l.x, l.y, l.z)
}

#[inline]
pub fn skew(v: &V3) -> M3 {
    M3::new(0.0, -v.z, v.y, v.z, 0.0, -v.x, -v.y, v.x, 0.0)
}

/// Motion cross product `v x m`.
#[inline]
pub fn crm(v: &V6, m: &V6) -> V6 {
    let (w, vl) = (ang(v), lin(v));
    let (mw, mv) = (ang(m), lin(m));
    v6(&w.cross(&mw), &(w.cross(&mv) + vl.cross(&mw)))
}

/// Force cross product `v x* f`.
#[inline]
pub fn crf(v: &V6, f: &V6) -> V6 {
    let (w, vl) = (ang(v), lin(v));
    let (n, fl) = (ang(f), lin(f));
    v6(&(w.cross(&n) + vl.cross(&fl)), &w.cross(&fl))
}

/// A Plucker transform from frame A to frame B.
#[derive(Clone, Copy, Debug)]
pub struct Xf {
    /// Rotation taking A coordinates to B coordinates.
    pub e: M3,
    /// Origin of B in A coordinates.
    pub r: V3,
}

impl Default for Xf {
    fn default() -> Self {
        Xf::identity()
    }
}

impl Xf {
    pub fn identity() -> Self {
        Xf { e: M3::identity(), r: V3::zeros() }
    }

    /// The transform from A to B where `pose` is B's pose in A (`p_A = pose * p_B`).
    pub fn from_pose(pose: &Iso3) -> Self {
        Xf { e: pose.rotation.to_rotation_matrix().into_inner().transpose(), r: pose.translation.vector }
    }

    /// Motion vector from A to B coordinates.
    #[inline]
    pub fn motion(&self, m: &V6) -> V6 {
        let w = ang(m);
        v6(&(self.e * w), &(self.e * (lin(m) - self.r.cross(&w))))
    }

    /// Force vector from A to B coordinates.
    #[inline]
    pub fn force(&self, f: &V6) -> V6 {
        let fl = lin(f);
        v6(&(self.e * (ang(f) - self.r.cross(&fl))), &(self.e * fl))
    }

    /// Motion vector from B back to A coordinates (inverse transform).
    #[inline]
    pub fn inv_motion(&self, m: &V6) -> V6 {
        let w = self.e.transpose() * ang(m);
        v6(&w, &(self.e.transpose() * lin(m) + self.r.cross(&w)))
    }

    /// Force vector from B back to A coordinates (`X^T f`).
    #[inline]
    pub fn inv_force(&self, f: &V6) -> V6 {
        let fl = self.e.transpose() * lin(f);
        v6(&(self.e.transpose() * ang(f) + self.r.cross(&fl)), &fl)
    }

    /// `self * other`: first `other` (A to B), then `self` (B to C).
    pub fn compose(&self, other: &Xf) -> Xf {
        Xf { e: self.e * other.e, r: other.r + other.e.transpose() * self.r }
    }

    /// The 6x6 motion transform matrix.
    pub fn matrix(&self) -> M6 {
        let mut m = M6::zeros();
        let erx = -self.e * skew(&self.r);
        m.fixed_view_mut::<3, 3>(0, 0).copy_from(&self.e);
        m.fixed_view_mut::<3, 3>(3, 3).copy_from(&self.e);
        m.fixed_view_mut::<3, 3>(3, 0).copy_from(&erx);
        m
    }

    /// An inertia in B coordinates moved to A coordinates: `X^T I X`.
    pub fn inertia_to_parent(&self, i: &M6) -> M6 {
        let x = self.matrix();
        x.transpose() * i * x
    }
}

/// Spatial inertia at a body's origin from its mass, centre of mass and inertia about the
/// centre of mass (body axes): `[[Ic + m c^x c^xT, m c^x], [m c^xT, m 1]]`.
pub fn rigid_inertia(mass: f64, com: &V3, ic: &M3) -> M6 {
    let cx = skew(com);
    let mut i = M6::zeros();
    i.fixed_view_mut::<3, 3>(0, 0).copy_from(&(ic + mass * cx * cx.transpose()));
    i.fixed_view_mut::<3, 3>(0, 3).copy_from(&(mass * cx));
    i.fixed_view_mut::<3, 3>(3, 0).copy_from(&(mass * cx.transpose()));
    i.fixed_view_mut::<3, 3>(3, 3).copy_from(&(M3::identity() * mass));
    i
}

/// Inertia tensor from kin's `[ixx, iyy, izz, ixy, ixz, iyz]`.
pub fn inertia_matrix(i: &[f64; 6]) -> M3 {
    M3::new(i[0], i[3], i[4], i[3], i[1], i[5], i[4], i[5], i[2])
}

#[cfg(test)]
mod tests {
    use super::*;
    use viaform_kin::math::pose_xyz_rpy;

    #[test]
    fn transforms_are_consistent() {
        let a = pose_xyz_rpy([0.1, -0.2, 0.3], [0.3, -0.5, 1.1]);
        let b = pose_xyz_rpy([-0.4, 0.05, 0.2], [-0.7, 0.2, 0.4]);
        let (xa, xb) = (Xf::from_pose(&a), Xf::from_pose(&b));
        let m = V6::new(0.1, 0.2, -0.3, 0.5, -0.1, 0.7);
        let f = V6::new(-0.4, 0.3, 0.2, 1.0, -2.0, 0.5);
        // Matrix form matches.
        assert!((xa.matrix() * m - xa.motion(&m)).norm() < 1e-14);
        // Power is invariant.
        assert!((xa.motion(&m).dot(&xa.force(&f)) - m.dot(&f)).abs() < 1e-13);
        // Inverse.
        assert!((xa.inv_motion(&xa.motion(&m)) - m).norm() < 1e-14);
        assert!((xa.inv_force(&xa.force(&f)) - f).norm() < 1e-14);
        // Composition equals the composed pose.
        let xc = xb.compose(&xa);
        let xd = Xf::from_pose(&(a * b));
        assert!((xc.motion(&m) - xd.motion(&m)).norm() < 1e-13);
        // Point velocity: a body pose (R, p), body twist [w; v] at the body origin.
        let w = V3::new(0.3, -0.2, 0.5);
        let v = V3::new(1.0, 0.0, -0.4);
        let world = xa.inv_motion(&v6(&w, &v));
        let p = a.translation.vector;
        let r = a.rotation.to_rotation_matrix();
        let v_origin_body = lin(&world) + ang(&world).cross(&p);
        assert!((v_origin_body - r * v).norm() < 1e-14);
    }
}
