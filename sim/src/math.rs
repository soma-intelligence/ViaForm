//! Small vector, matrix and quaternion helpers for the flight simulation. Plain arrays keep the
//! inner loop allocation-free, so training can run thousands of episodes.

pub type V3 = [f64; 3];
/// Row-major 3 × 3 matrix.
pub type M3 = [f64; 9];
/// Unit quaternion [w, x, y, z]; rotates body vectors into the world frame.
pub type Q = [f64; 4];

pub const PI: f64 = std::f64::consts::PI;

#[inline]
pub fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
#[inline]
pub fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
#[inline]
pub fn scale(a: V3, s: f64) -> V3 {
    [a[0] * s, a[1] * s, a[2] * s]
}
#[inline]
pub fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
#[inline]
pub fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
/// Euclidean length (`Math.hypot` in the TypeScript reference).
#[inline]
pub fn norm(a: V3) -> f64 {
    hypot3(a[0], a[1], a[2])
}
#[inline]
pub fn hypot3(x: f64, y: f64, z: f64) -> f64 {
    js_hypot(&[x, y, z])
}
#[inline]
pub fn hypot2(x: f64, y: f64) -> f64 {
    js_hypot(&[x, y])
}
/// `Math.hypot` as V8 computes it (scaled by the largest value, compensated sum), so seeded runs
/// stay bit-identical with the TypeScript reference over long flights.
pub fn js_hypot(xs: &[f64]) -> f64 {
    let mut max = 0.0f64;
    for &x in xs {
        let a = x.abs();
        if a.is_nan() {
            return f64::NAN;
        }
        if a == f64::INFINITY {
            return f64::INFINITY;
        }
        max = max.max(a);
    }
    if max == 0.0 {
        return 0.0;
    }
    let (mut sum, mut compensation) = (0.0f64, 0.0f64);
    for &x in xs {
        let n = x.abs() / max;
        let summand = n * n - compensation;
        let preliminary = sum + summand;
        compensation = (preliminary - sum) - summand;
        sum = preliminary;
    }
    sum.sqrt() * max
}
pub fn unit(a: V3) -> V3 {
    let n = norm(a);
    if n > 1e-12 { scale(a, 1.0 / n) } else { [0.0; 3] }
}
pub fn clamp_len(a: V3, max: f64) -> V3 {
    let n = norm(a);
    if n > max { scale(a, max / n) } else { a }
}
#[inline]
pub fn clamp(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo { lo } else if x > hi { hi } else { x }
}

pub fn q_mul(a: Q, b: Q) -> Q {
    [
        a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
        a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
        a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
        a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
    ]
}
pub fn q_normalize(q: Q) -> Q {
    let n = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).sqrt();
    [q[0] / n, q[1] / n, q[2] / n, q[3] / n]
}
/// Quaternion from roll, pitch, yaw (rad), ZYX order.
pub fn q_from_euler(roll: f64, pitch: f64, yaw: f64) -> Q {
    let (cr, sr) = ((roll / 2.0).cos(), (roll / 2.0).sin());
    let (cp, sp) = ((pitch / 2.0).cos(), (pitch / 2.0).sin());
    let (cy, sy) = ((yaw / 2.0).cos(), (yaw / 2.0).sin());
    [cr * cp * cy + sr * sp * sy, sr * cp * cy - cr * sp * sy, cr * sp * cy + sr * cp * sy, cr * cp * sy - sr * sp * cy]
}
pub fn q_to_euler(q: Q) -> V3 {
    let [w, x, y, z] = q;
    [
        (2.0 * (w * x + y * z)).atan2(1.0 - 2.0 * (x * x + y * y)),
        clamp(2.0 * (w * y - z * x), -1.0, 1.0).asin(),
        (2.0 * (w * z + x * y)).atan2(1.0 - 2.0 * (y * y + z * z)),
    ]
}
pub fn q_to_m3(q: Q) -> M3 {
    let [w, x, y, z] = q;
    [
        1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z), 2.0 * (x * z + w * y),
        2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x),
        2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y),
    ]
}
/// R · v
pub fn mv(m: &M3, v: V3) -> V3 {
    [m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2], m[6] * v[0] + m[7] * v[1] + m[8] * v[2]]
}
/// Rᵀ · v
pub fn mtv(m: &M3, v: V3) -> V3 {
    [m[0] * v[0] + m[3] * v[1] + m[6] * v[2], m[1] * v[0] + m[4] * v[1] + m[7] * v[2], m[2] * v[0] + m[5] * v[1] + m[8] * v[2]]
}
/// Column `i`: for a rotation, body axis `i` in world coordinates.
pub fn col(m: &M3, i: usize) -> V3 {
    [m[i], m[3 + i], m[6 + i]]
}

/// Deterministic PRNG (mulberry32, as the TypeScript reference) so training and tests replay
/// exactly, and the same seed draws the same numbers in both.
#[derive(Clone, Debug)]
pub struct Rng {
    s: u32,
    spare: Option<f64>,
}

impl Rng {
    pub fn new(seed: f64) -> Self {
        // `seed >>> 0` in JavaScript: ToUint32 of the number.
        let s = if seed.is_finite() { (seed.trunc().rem_euclid(4294967296.0)) as u32 } else { 0 };
        Rng { s, spare: None }
    }
    pub fn next(&mut self) -> f64 {
        self.s = self.s.wrapping_add(0x6d2b79f5);
        let mut t = self.s;
        t = (t ^ (t >> 15)).wrapping_mul(t | 1);
        t ^= t.wrapping_add((t ^ (t >> 7)).wrapping_mul(t | 61));
        ((t ^ (t >> 14)) as f64) / 4294967296.0
    }
    pub fn gauss(&mut self) -> f64 {
        if let Some(v) = self.spare.take() {
            return v;
        }
        let u = self.next().max(1e-12);
        let v = self.next();
        let r = (-2.0 * u.ln()).sqrt();
        self.spare = Some(r * (2.0 * PI * v).sin());
        r * (2.0 * PI * v).cos()
    }
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mulberry32_matches_javascript() {
        // rng(1).next() three times, from node.
        let mut r = Rng::new(1.0);
        let got: Vec<f64> = (0..3).map(|_| r.next()).collect();
        let want = [0.6270739405881613, 0.002735721180215478, 0.5274470399599522];
        for (g, w) in got.iter().zip(want) {
            assert!((g - w).abs() < 1e-15, "{got:?}");
        }
    }
}
