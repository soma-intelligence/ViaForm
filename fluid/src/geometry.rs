//! Obstacles as primitive shapes, voxelised by cell centre (a voxel is solid when its centre is
//! inside a shape), the same rule as the generative engine's keep-in regions.

use serde::{Deserialize, Serialize};

/// A solid primitive in the domain's frame (any length unit, the same as the grid's).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Shape {
    /// Axis-aligned box.
    Box { min: [f64; 3], max: [f64; 3] },
    /// Cylinder through `center` along `axis`; `length` (total) unbounded when omitted.
    Cylinder {
        center: [f64; 3],
        axis: [f64; 3],
        radius: f64,
        #[serde(default)]
        length: Option<f64>,
    },
    /// Sphere.
    Sphere { center: [f64; 3], radius: f64 },
}

impl Shape {
    /// Whether the point is inside.
    pub fn contains(&self, p: [f64; 3]) -> bool {
        match self {
            Shape::Box { min, max } => (0..3).all(|a| p[a] >= min[a] && p[a] <= max[a]),
            Shape::Sphere { center, radius } => {
                let d = [p[0] - center[0], p[1] - center[1], p[2] - center[2]];
                d[0] * d[0] + d[1] * d[1] + d[2] * d[2] <= radius * radius
            }
            Shape::Cylinder {
                center,
                axis,
                radius,
                length,
            } => {
                let n = (axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]).sqrt();
                if n == 0.0 {
                    return false;
                }
                let a = [axis[0] / n, axis[1] / n, axis[2] / n];
                let d = [p[0] - center[0], p[1] - center[1], p[2] - center[2]];
                let along = d[0] * a[0] + d[1] * a[1] + d[2] * a[2];
                if let Some(l) = length
                    && along.abs() > 0.5 * l
                {
                    return false;
                }
                let r2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2] - along * along;
                r2 <= radius * radius
            }
        }
    }
}

fn quad_first(a: f64, b: f64, c: f64) -> Option<f64> {
    // Smallest t >= 0 with a t^2 + b t + c = 0 (entering root).
    if a.abs() < 1e-300 {
        return None;
    }
    let disc = b * b - 4.0 * a * c;
    if disc < 0.0 {
        return None;
    }
    let sq = disc.sqrt();
    let (t0, t1) = ((-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a));
    if t0 >= 0.0 {
        Some(t0)
    } else if t1 >= 0.0 {
        Some(t1)
    } else {
        None
    }
}

impl Shape {
    /// First `t >= 0` at which the ray `p + t d` meets the shape's surface (for `p` outside).
    pub fn ray_hit(&self, p: [f64; 3], d: [f64; 3]) -> Option<f64> {
        let dot = |a: [f64; 3], b: [f64; 3]| a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        match self {
            Shape::Sphere { center, radius } => {
                let w = [p[0] - center[0], p[1] - center[1], p[2] - center[2]];
                quad_first(dot(d, d), 2.0 * dot(w, d), dot(w, w) - radius * radius)
            }
            Shape::Box { min, max } => {
                let (mut t0, mut t1) = (f64::NEG_INFINITY, f64::INFINITY);
                for a in 0..3 {
                    if d[a] == 0.0 {
                        if p[a] < min[a] || p[a] > max[a] {
                            return None;
                        }
                    } else {
                        let (u, v) = ((min[a] - p[a]) / d[a], (max[a] - p[a]) / d[a]);
                        t0 = t0.max(u.min(v));
                        t1 = t1.min(u.max(v));
                    }
                }
                (t1 >= t0.max(0.0)).then_some(t0.max(0.0))
            }
            Shape::Cylinder {
                center,
                axis,
                radius,
                length,
            } => {
                let n = dot(*axis, *axis).sqrt();
                if n == 0.0 {
                    return None;
                }
                let a = [axis[0] / n, axis[1] / n, axis[2] / n];
                let w = [p[0] - center[0], p[1] - center[1], p[2] - center[2]];
                let (wa, da) = (dot(w, a), dot(d, a));
                let wp = [w[0] - wa * a[0], w[1] - wa * a[1], w[2] - wa * a[2]];
                let dp = [d[0] - da * a[0], d[1] - da * a[1], d[2] - da * a[2]];
                let half = length.map(|l| 0.5 * l);
                let mut best: Option<f64> = None;
                if let Some(t) = quad_first(
                    dot(dp, dp),
                    2.0 * dot(wp, dp),
                    dot(wp, wp) - radius * radius,
                ) && half.is_none_or(|h| (wa + t * da).abs() <= h)
                {
                    best = Some(t);
                }
                if let Some(h) = half
                    && da != 0.0
                {
                    for side in [-h, h] {
                        let t = (side - wa) / da;
                        let r = [wp[0] + t * dp[0], wp[1] + t * dp[1], wp[2] + t * dp[2]];
                        if t >= 0.0 && dot(r, r) <= radius * radius && best.is_none_or(|b| t < b) {
                            best = Some(t);
                        }
                    }
                }
                best
            }
        }
    }
}

/// Wall distance function for [`crate::Solver::set_wall_distance`] from shapes on a grid of
/// edge `h` with its corner at `origin` (the voxelisation of [`voxelize`]).
pub fn wall_distance(
    shapes: &[Shape],
    h: f64,
    origin: [f64; 3],
) -> impl Fn([f64; 3], [f64; 3]) -> Option<f64> + '_ {
    move |p, d| {
        let pp = [
            origin[0] + (p[0] + 0.5) * h,
            origin[1] + (p[1] + 0.5) * h,
            origin[2] + (p[2] + 0.5) * h,
        ];
        let dd = [d[0] * h, d[1] * h, d[2] * h];
        shapes
            .iter()
            .filter_map(|s| s.ray_hit(pp, dd))
            .filter(|t| *t <= 1.0 + 1e-9)
            .min_by(f64::total_cmp)
    }
}

/// Solid mask of `dims` cells of edge `h` whose corner sits at `origin`: cell `(i, j, k)` has
/// its centre at `origin + (i + 1/2, j + 1/2, k + 1/2) h`.
pub fn voxelize(shapes: &[Shape], dims: [usize; 3], h: f64, origin: [f64; 3]) -> Vec<bool> {
    let [nx, ny, nz] = dims;
    let mut out = vec![false; nx * ny * nz];
    for k in 0..nz {
        for j in 0..ny {
            for i in 0..nx {
                let p = [
                    origin[0] + (i as f64 + 0.5) * h,
                    origin[1] + (j as f64 + 0.5) * h,
                    origin[2] + (k as f64 + 0.5) * h,
                ];
                if shapes.iter().any(|s| s.contains(p)) {
                    out[(k * ny + j) * nx + i] = true;
                }
            }
        }
    }
    out
}
