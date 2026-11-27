//! Small math vocabulary shared by the whole crate (and by `phys`): f64 nalgebra types, pose
//! helpers, the rotation error used by IK, a seeded random stream and serde helpers for the JSON
//! form of vectors and poses.

use nalgebra::{Isometry3, Matrix3, Matrix6xX, Translation3, UnitQuaternion, Vector3};
use rand_chacha::ChaCha8Rng;
use rand_chacha::rand_core::{RngCore, SeedableRng};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A 3-vector (m, or a unit axis).
pub type Vec3 = Vector3<f64>;
/// A 3x3 matrix.
pub type Mat3 = Matrix3<f64>;
/// A unit quaternion (rotation).
pub type UnitQuat = UnitQuaternion<f64>;
/// A rigid pose: rotation plus translation, `p_world = pose * p_local`.
pub type Iso3 = Isometry3<f64>;
/// A geometric Jacobian: 6 rows (linear velocity x, y, z, then angular velocity x, y, z, both in
/// the world frame, linear velocity of the frame origin) by `nv` columns.
pub type Jacobian = Matrix6xX<f64>;

/// A pose from a translation and a rotation.
pub fn pose(pos: Vec3, rot: UnitQuat) -> Iso3 {
    Isometry3::from_parts(Translation3::from(pos), rot)
}

/// A pose from URDF style `xyz` and `rpy` (fixed axes: roll about X, then pitch about Y, then yaw
/// about Z, so `R = Rz(yaw) Ry(pitch) Rx(roll)`).
pub fn pose_xyz_rpy(xyz: [f64; 3], rpy: [f64; 3]) -> Iso3 {
    pose(Vec3::from(xyz), UnitQuat::from_euler_angles(rpy[0], rpy[1], rpy[2]))
}

/// A pose from `[x, y, z, qw, qx, qy, qz]` (the quaternion is normalised).
pub fn pose_from7(p: &[f64; 7]) -> Iso3 {
    let q = nalgebra::Quaternion::new(p[3], p[4], p[5], p[6]);
    pose(Vec3::new(p[0], p[1], p[2]), UnitQuat::from_quaternion(q))
}

/// `[x, y, z, qw, qx, qy, qz]` of a pose.
pub fn pose_to7(p: &Iso3) -> [f64; 7] {
    let t = p.translation.vector;
    let q = p.rotation.quaternion();
    [t.x, t.y, t.z, q.w, q.i, q.j, q.k]
}

/// Rotation error as a rotation vector (log map of `target * current^-1`, world frame). Its norm is
/// the angle between the two orientations, in [0, pi].
pub fn rot_error(target: &UnitQuat, current: &UnitQuat) -> Vec3 {
    let d = target * current.inverse();
    // Keep the short way round (w >= 0) before taking the log.
    let q = d.quaternion();
    let (w, v) = if q.w < 0.0 { (-q.w, -q.imag()) } else { (q.w, q.imag()) };
    let s = v.norm();
    if s < 1e-12 {
        return v * 2.0;
    }
    v * (2.0 * s.atan2(w) / s)
}

/// The skew-symmetric (cross product) matrix of `v`.
pub fn skew(v: &Vec3) -> Mat3 {
    Mat3::new(0.0, -v.z, v.y, v.z, 0.0, -v.x, -v.y, v.x, 0.0)
}

/// Wraps an angle to (-pi, pi].
pub fn wrap_pi(a: f64) -> f64 {
    let mut x = (a + std::f64::consts::PI).rem_euclid(2.0 * std::f64::consts::PI) - std::f64::consts::PI;
    if x <= -std::f64::consts::PI {
        x += 2.0 * std::f64::consts::PI;
    }
    x
}

/// A seeded, portable random stream (ChaCha8). Same seed, same numbers on every platform.
#[derive(Clone, Debug)]
pub struct Rng(ChaCha8Rng);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(ChaCha8Rng::seed_from_u64(seed))
    }
    /// Uniform in [0, 1) with 53 random bits.
    pub fn uniform(&mut self) -> f64 {
        (self.0.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }
    /// Uniform in [lo, hi).
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.uniform()
    }
    /// Standard normal (Box-Muller).
    pub fn normal(&mut self) -> f64 {
        let u1 = self.uniform().max(1e-300);
        let u2 = self.uniform();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
    /// A uniformly distributed rotation (Shoemake).
    pub fn rotation(&mut self) -> UnitQuat {
        let (u1, u2, u3) = (self.uniform(), self.uniform(), self.uniform());
        let tau = 2.0 * std::f64::consts::PI;
        let (a, b) = ((1.0 - u1).sqrt(), u1.sqrt());
        let q = nalgebra::Quaternion::new(b * (tau * u3).cos(), a * (tau * u2).sin(), a * (tau * u2).cos(), b * (tau * u3).sin());
        UnitQuat::from_quaternion(q)
    }
}

/// JSON form of a pose: `{"xyz": [..], "quat_wxyz": [..]}` on output; on input either
/// `quat_wxyz` or URDF style `rpy` (radians), both optional (identity rotation).
#[derive(Serialize, Deserialize)]
struct PoseJson {
    #[serde(default)]
    xyz: [f64; 3],
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rpy: Option<[f64; 3]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    quat_wxyz: Option<[f64; 4]>,
}

impl PoseJson {
    fn to_iso(&self) -> Result<Iso3, String> {
        let rot = match (self.quat_wxyz, self.rpy) {
            (Some(q), _) => {
                let qq = nalgebra::Quaternion::new(q[0], q[1], q[2], q[3]);
                if !(qq.norm() > 1e-9) {
                    return Err("quat_wxyz has zero length".into());
                }
                UnitQuat::from_quaternion(qq)
            }
            (None, Some(r)) => UnitQuat::from_euler_angles(r[0], r[1], r[2]),
            (None, None) => UnitQuat::identity(),
        };
        if !self.xyz.iter().all(|v| v.is_finite()) {
            return Err("xyz is not finite".into());
        }
        Ok(pose(Vec3::from(self.xyz), rot))
    }
    fn from_iso(p: &Iso3) -> Self {
        let a = pose_to7(p);
        PoseJson { xyz: [a[0], a[1], a[2]], rpy: None, quat_wxyz: Some([a[3], a[4], a[5], a[6]]) }
    }
}

/// Parses a pose from JSON (see [`pose_json`] for the form).
pub fn pose_from_json(v: &serde_json::Value) -> Result<Iso3, String> {
    let p: PoseJson = serde_json::from_value(v.clone()).map_err(|e| e.to_string())?;
    p.to_iso()
}

/// A pose as JSON: `{"xyz": [x, y, z], "quat_wxyz": [w, x, y, z]}`.
pub fn pose_json(p: &Iso3) -> serde_json::Value {
    serde_json::to_value(PoseJson::from_iso(p)).unwrap_or_default()
}

/// Serde helpers (`#[serde(with = ...)]`) for nalgebra fields.
pub mod serde_iso {
    use super::*;
    pub fn serialize<S: Serializer>(p: &Iso3, s: S) -> Result<S::Ok, S::Error> {
        PoseJson::from_iso(p).serialize(s)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Iso3, D::Error> {
        PoseJson::deserialize(d)?.to_iso().map_err(serde::de::Error::custom)
    }
}

/// Serde helper: a [`Vec3`] as `[x, y, z]`.
pub mod serde_vec3 {
    use super::*;
    pub fn serialize<S: Serializer>(v: &Vec3, s: S) -> Result<S::Ok, S::Error> {
        [v.x, v.y, v.z].serialize(s)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec3, D::Error> {
        let a = <[f64; 3]>::deserialize(d)?;
        Ok(Vec3::from(a))
    }
}

/// Serde helper: a lower bound that may be minus infinity, written as `null` (or left out) then.
pub mod serde_lower {
    use super::*;
    pub fn serialize<S: Serializer>(v: &f64, s: S) -> Result<S::Ok, S::Error> {
        if v.is_finite() { s.serialize_some(v) } else { s.serialize_none() }
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
        Ok(Option::<f64>::deserialize(d)?.unwrap_or(f64::NEG_INFINITY))
    }
}

/// Serde helper: an upper bound that may be infinite, written as `null` (or left out) then.
pub mod serde_upper {
    use super::*;
    pub fn serialize<S: Serializer>(v: &f64, s: S) -> Result<S::Ok, S::Error> {
        if v.is_finite() { s.serialize_some(v) } else { s.serialize_none() }
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
        Ok(Option::<f64>::deserialize(d)?.unwrap_or(f64::INFINITY))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rot_error_is_the_angle() {
        let a = UnitQuat::from_euler_angles(0.3, -0.2, 1.1);
        let d = UnitQuat::from_scaled_axis(Vec3::new(0.1, -0.4, 0.25));
        let e = rot_error(&(d * a), &a);
        assert!((e - Vec3::new(0.1, -0.4, 0.25)).norm() < 1e-12);
        // Near pi still the short way.
        let d = UnitQuat::from_scaled_axis(Vec3::new(0.0, 0.0, 3.1));
        assert!((rot_error(&(d * a), &a).norm() - 3.1).abs() < 1e-12);
    }

    #[test]
    fn pose_json_round_trip() {
        let p = pose_xyz_rpy([0.1, 0.2, 0.3], [0.4, -0.5, 0.6]);
        let back = pose_from_json(&pose_json(&p)).unwrap();
        assert!((back.translation.vector - p.translation.vector).norm() < 1e-15);
        assert!(back.rotation.angle_to(&p.rotation) < 1e-12);
        assert!((wrap_pi(3.0 * std::f64::consts::PI) - std::f64::consts::PI).abs() < 1e-12);
    }
}
