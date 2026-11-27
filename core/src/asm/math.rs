//! Small 3D math for the assembly: vectors, rotation matrices and rigid transforms, f64.
//! Lengths are whatever the caller uses (the assembly works in mm); angles are radians here.

pub type V3 = [f64; 3];
pub type M3 = [[f64; 3]; 3];

pub fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

pub fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub fn scale(a: V3, s: f64) -> V3 {
    [a[0] * s, a[1] * s, a[2] * s]
}

pub fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

pub fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

pub fn norm(a: V3) -> f64 {
    dot(a, a).sqrt()
}

/// `a` scaled to length 1; None for a zero or non-finite vector.
pub fn unit(a: V3) -> Option<V3> {
    let n = norm(a);
    (n > 1e-12 && n.is_finite()).then(|| scale(a, 1.0 / n))
}

pub const IDENTITY: M3 = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];

pub fn mat_mul(a: &M3, b: &M3) -> M3 {
    let mut out = [[0.0; 3]; 3];
    for r in 0..3 {
        for c in 0..3 {
            out[r][c] = (0..3).map(|k| a[r][k] * b[k][c]).sum();
        }
    }
    out
}

pub fn mat_vec(a: &M3, v: V3) -> V3 {
    [dot(a[0], v), dot(a[1], v), dot(a[2], v)]
}

pub fn transpose(a: &M3) -> M3 {
    let mut out = [[0.0; 3]; 3];
    for r in 0..3 {
        for c in 0..3 {
            out[r][c] = a[c][r];
        }
    }
    out
}

/// Rotation by `angle` (rad) about the unit `axis` (Rodrigues).
pub fn axis_angle(axis: V3, angle: f64) -> M3 {
    let [x, y, z] = axis;
    let (s, c) = angle.sin_cos();
    let t = 1.0 - c;
    [
        [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
        [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
        [t * x * z - s * y, t * y * z + s * x, t * z * z + c],
    ]
}

/// Unit quaternion `[w, x, y, z]` of a rotation matrix.
pub fn quat(m: &M3) -> [f64; 4] {
    let tr = m[0][0] + m[1][1] + m[2][2];
    let q = if tr > 0.0 {
        let s = (tr + 1.0).sqrt() * 2.0;
        [0.25 * s, (m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s]
    } else if m[0][0] > m[1][1] && m[0][0] > m[2][2] {
        let s = (1.0 + m[0][0] - m[1][1] - m[2][2]).sqrt() * 2.0;
        [(m[2][1] - m[1][2]) / s, 0.25 * s, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s]
    } else if m[1][1] > m[2][2] {
        let s = (1.0 + m[1][1] - m[0][0] - m[2][2]).sqrt() * 2.0;
        [(m[0][2] - m[2][0]) / s, (m[0][1] + m[1][0]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s]
    } else {
        let s = (1.0 + m[2][2] - m[0][0] - m[1][1]).sqrt() * 2.0;
        [(m[1][0] - m[0][1]) / s, (m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s]
    };
    if q[0] < 0.0 { [-q[0], -q[1], -q[2], -q[3]] } else { q }
}

/// A rigid transform: `p -> rot * p + pos`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Iso {
    pub rot: M3,
    pub pos: V3,
}

impl Default for Iso {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl Iso {
    pub const IDENTITY: Iso = Iso { rot: IDENTITY, pos: [0.0; 3] };

    pub fn translation(t: V3) -> Self {
        Iso { rot: IDENTITY, pos: t }
    }

    /// Rotation by `angle` about the line through `origin` along unit `axis`.
    pub fn about(origin: V3, axis: V3, angle: f64) -> Self {
        let rot = axis_angle(axis, angle);
        Iso { rot, pos: sub(origin, mat_vec(&rot, origin)) }
    }

    pub fn mul(&self, o: &Iso) -> Iso {
        Iso { rot: mat_mul(&self.rot, &o.rot), pos: add(mat_vec(&self.rot, o.pos), self.pos) }
    }

    pub fn apply(&self, p: V3) -> V3 {
        add(mat_vec(&self.rot, p), self.pos)
    }

    pub fn apply_dir(&self, v: V3) -> V3 {
        mat_vec(&self.rot, v)
    }

    pub fn inverse(&self) -> Iso {
        let rt = transpose(&self.rot);
        Iso { rot: rt, pos: scale(mat_vec(&rt, self.pos), -1.0) }
    }

    /// The 4x4 matrix, column-major (what Metal and the bridge's pose buffers take).
    pub fn column_major(&self) -> [f64; 16] {
        let r = &self.rot;
        let t = self.pos;
        [r[0][0], r[1][0], r[2][0], 0.0, r[0][1], r[1][1], r[2][1], 0.0, r[0][2], r[1][2], r[2][2], 0.0, t[0], t[1], t[2], 1.0]
    }
}

/// Roll, pitch, yaw (rad, fixed X then Y then Z, URDF's convention) of a rotation.
pub fn rpy(m: &M3) -> V3 {
    let pitch = (-m[2][0]).clamp(-1.0, 1.0).asin();
    if pitch.cos().abs() > 1e-9 {
        [m[2][1].atan2(m[2][2]), pitch, m[1][0].atan2(m[0][0])]
    } else {
        [0.0, pitch, (-m[0][1]).atan2(m[1][1])]
    }
}

/// The rotation of roll, pitch, yaw (rad): `Rz(yaw) * Ry(pitch) * Rx(roll)`.
pub fn from_rpy(r: V3) -> M3 {
    let rx = axis_angle([1.0, 0.0, 0.0], r[0]);
    let ry = axis_angle([0.0, 1.0, 0.0], r[1]);
    let rz = axis_angle([0.0, 0.0, 1.0], r[2]);
    mat_mul(&rz, &mat_mul(&ry, &rx))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotations_and_transforms_agree() {
        let r = axis_angle([0.0, 0.0, 1.0], std::f64::consts::FRAC_PI_2);
        let p = mat_vec(&r, [1.0, 0.0, 0.0]);
        assert!((p[1] - 1.0).abs() < 1e-12 && p[0].abs() < 1e-12);
        let t = Iso::about([1.0, 0.0, 0.0], [0.0, 0.0, 1.0], std::f64::consts::PI);
        let q = t.apply([2.0, 0.0, 0.0]);
        assert!((q[0] - 0.0).abs() < 1e-12, "{q:?}");
        let back = t.inverse().apply(q);
        assert!((back[0] - 2.0).abs() < 1e-12);
        let m = from_rpy([0.3, -0.4, 1.1]);
        let e = rpy(&m);
        assert!((e[0] - 0.3).abs() < 1e-12 && (e[1] + 0.4).abs() < 1e-12 && (e[2] - 1.1).abs() < 1e-12);
        let qn = quat(&m);
        assert!((qn.iter().map(|x| x * x).sum::<f64>() - 1.0).abs() < 1e-12);
    }
}
