//! Geometry the assembly measures: closed triangle meshes (mm), their volume, centre and second
//! moments, their bounding boxes and the volume two of them share.
//!
//! The shared volume is measured on a grid of rays along X through the overlap of the two
//! bounding boxes: each ray crosses each closed mesh an even number of times, the crossings
//! pair into inside intervals, and the length both meshes are inside along the ray, times the
//! ray's cell, adds up to the volume. Exact along X, sampled in Y and Z at `cell` mm.

use super::math::{Iso, M3, V3, add, cross, dot, scale, sub};

/// A closed, outward-oriented triangle mesh.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Mesh {
    pub positions: Vec<V3>,
    pub triangles: Vec<[u32; 3]>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Aabb {
    pub min: V3,
    pub max: V3,
}

impl Aabb {
    pub const EMPTY: Aabb = Aabb { min: [f64::INFINITY; 3], max: [f64::NEG_INFINITY; 3] };

    pub fn grow(&mut self, p: V3) {
        for i in 0..3 {
            self.min[i] = self.min[i].min(p[i]);
            self.max[i] = self.max[i].max(p[i]);
        }
    }

    pub fn union(&self, o: &Aabb) -> Aabb {
        let mut out = *self;
        out.grow(o.min);
        out.grow(o.max);
        out
    }

    pub fn is_empty(&self) -> bool {
        (0..3).any(|i| !(self.max[i] >= self.min[i]))
    }

    /// The common box; None when they do not touch.
    pub fn intersect(&self, o: &Aabb) -> Option<Aabb> {
        let min = [0, 1, 2].map(|i| self.min[i].max(o.min[i]));
        let max = [0, 1, 2].map(|i| self.max[i].min(o.max[i]));
        (0..3).all(|i| max[i] > min[i]).then_some(Aabb { min, max })
    }

    pub fn center(&self) -> V3 {
        scale(add(self.min, self.max), 0.5)
    }

    pub fn size(&self) -> V3 {
        sub(self.max, self.min)
    }
}

impl Mesh {
    /// A box from `min` to `max`, faces outward.
    pub fn cuboid(min: V3, max: V3) -> Mesh {
        let p = |x: usize, y: usize, z: usize| [if x == 0 { min[0] } else { max[0] }, if y == 0 { min[1] } else { max[1] }, if z == 0 { min[2] } else { max[2] }];
        let positions = vec![p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0, 1, 0), p(0, 0, 1), p(1, 0, 1), p(1, 1, 1), p(0, 1, 1)];
        let triangles = vec![
            [0, 2, 1], [0, 3, 2], // bottom (-z)
            [4, 5, 6], [4, 6, 7], // top (+z)
            [0, 1, 5], [0, 5, 4], // front (-y)
            [3, 7, 6], [3, 6, 2], // back (+y)
            [0, 4, 7], [0, 7, 3], // left (-x)
            [1, 2, 6], [1, 6, 5], // right (+x)
        ];
        Mesh { positions, triangles }
    }

    /// From flat buffers (xyz per vertex, three indices per triangle), as the scene hands them.
    pub fn from_flat(positions: &[f32], indices: &[u32]) -> Mesh {
        Mesh {
            positions: positions.chunks_exact(3).map(|c| [f64::from(c[0]), f64::from(c[1]), f64::from(c[2])]).collect(),
            triangles: indices.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect(),
        }
    }

    pub fn transformed(&self, t: &Iso) -> Mesh {
        Mesh { positions: self.positions.iter().map(|p| t.apply(*p)).collect(), triangles: self.triangles.clone() }
    }

    pub fn aabb(&self) -> Aabb {
        let mut b = Aabb::EMPTY;
        for p in &self.positions {
            b.grow(*p);
        }
        b
    }

    fn tri(&self, t: &[u32; 3]) -> Option<[V3; 3]> {
        Some([*self.positions.get(t[0] as usize)?, *self.positions.get(t[1] as usize)?, *self.positions.get(t[2] as usize)?])
    }

    /// Volume (mm³), centroid and the second moment `∫ x xᵀ dV` about the world origin, by signed
    /// tetrahedra from the origin.
    pub fn moments(&self) -> Moments {
        let mut vol = 0.0;
        let mut first = [0.0; 3];
        let mut second = [[0.0; 3]; 3];
        for t in &self.triangles {
            let Some([a, b, c]) = self.tri(t) else { continue };
            let det = dot(a, cross(b, c));
            vol += det / 6.0;
            let s = add(add(a, b), c);
            first = add(first, scale(s, det / 24.0));
            // ∫ x xᵀ over the tetrahedron (0, a, b, c) = det/120 · (Σ vᵢvᵢᵀ + s sᵀ).
            for r in 0..3 {
                for k in 0..3 {
                    let diag = a[r] * a[k] + b[r] * b[k] + c[r] * c[k];
                    second[r][k] += det / 120.0 * (diag + s[r] * s[k]);
                }
            }
        }
        let centroid = if vol.abs() > 1e-12 { scale(first, 1.0 / vol) } else { [0.0; 3] };
        Moments { volume: vol, centroid, second }
    }

    /// Where the ray `{(x, y, z) : x real}` enters and leaves the mesh, sorted, as inside
    /// intervals of x.
    fn intervals(&self, tris: &[usize], y: f64, z: f64) -> Vec<(f64, f64)> {
        let mut xs: Vec<f64> = Vec::new();
        for &i in tris {
            let Some([a, b, c]) = self.tri(&self.triangles[i]) else { continue };
            // Barycentric coordinates of (y, z) in the triangle's projection on the YZ plane.
            let d = (b[1] - a[1]) * (c[2] - a[2]) - (c[1] - a[1]) * (b[2] - a[2]);
            if d.abs() < 1e-18 {
                continue;
            }
            let u = ((y - a[1]) * (c[2] - a[2]) - (c[1] - a[1]) * (z - a[2])) / d;
            let v = ((b[1] - a[1]) * (z - a[2]) - (y - a[1]) * (b[2] - a[2])) / d;
            if u < 0.0 || v < 0.0 || u + v > 1.0 {
                continue;
            }
            xs.push(a[0] + u * (b[0] - a[0]) + v * (c[0] - a[0]));
        }
        xs.sort_by(f64::total_cmp);
        xs.dedup_by(|a, b| (*a - *b).abs() < 1e-9);
        xs.chunks_exact(2).map(|p| (p[0], p[1])).collect()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Moments {
    pub volume: f64,
    pub centroid: V3,
    pub second: M3,
}

impl Moments {
    /// The inertia tensor about the centroid at `density` (mass per mm³).
    pub fn inertia_about_centroid(&self, density: f64) -> M3 {
        let c = self.centroid;
        let mut cc = self.second;
        for r in 0..3 {
            for k in 0..3 {
                cc[r][k] -= self.volume * c[r] * c[k];
            }
        }
        let tr = cc[0][0] + cc[1][1] + cc[2][2];
        let mut out = [[0.0; 3]; 3];
        for r in 0..3 {
            for k in 0..3 {
                out[r][k] = density * (if r == k { tr } else { 0.0 } - cc[r][k]);
            }
        }
        out
    }
}

/// Several closed meshes taken as one solid (their union along each ray).
pub struct Solid<'a> {
    pub meshes: Vec<(&'a Mesh, Vec<usize>)>,
}

impl<'a> Solid<'a> {
    /// The meshes, keeping only triangles that reach into `region` in Y and Z.
    pub fn within(meshes: &'a [Mesh], region: &Aabb) -> Self {
        let meshes = meshes
            .iter()
            .map(|m| {
                let tris = (0..m.triangles.len())
                    .filter(|&i| {
                        m.tri(&m.triangles[i]).is_some_and(|t| {
                            let lo = |k: usize| t.iter().map(|p| p[k]).fold(f64::INFINITY, f64::min);
                            let hi = |k: usize| t.iter().map(|p| p[k]).fold(f64::NEG_INFINITY, f64::max);
                            hi(1) >= region.min[1] && lo(1) <= region.max[1] && hi(2) >= region.min[2] && lo(2) <= region.max[2]
                        })
                    })
                    .collect();
                (m, tris)
            })
            .collect();
        Self { meshes }
    }

    fn intervals(&self, y: f64, z: f64) -> Vec<(f64, f64)> {
        let mut all: Vec<(f64, f64)> = self.meshes.iter().flat_map(|(m, t)| m.intervals(t, y, z)).collect();
        all.sort_by(|a, b| a.0.total_cmp(&b.0));
        let mut merged: Vec<(f64, f64)> = Vec::new();
        for (a, b) in all {
            match merged.last_mut() {
                Some(last) if a <= last.1 => last.1 = last.1.max(b),
                _ => merged.push((a, b)),
            }
        }
        merged
    }
}

fn overlap_len(a: &[(f64, f64)], b: &[(f64, f64)], lo: f64, hi: f64) -> f64 {
    let mut total = 0.0;
    for &(a0, a1) in a {
        for &(b0, b1) in b {
            let s = a0.max(b0).max(lo);
            let e = a1.min(b1).min(hi);
            if e > s {
                total += e - s;
            }
        }
    }
    total
}

/// The volume (mm³) two solids share inside `region`, sampled every `cell` mm in Y and Z.
pub fn shared_volume(a: &[Mesh], b: &[Mesh], region: &Aabb, cell: f64) -> f64 {
    let size = region.size();
    let ny = ((size[1] / cell).ceil() as usize).clamp(1, 512);
    let nz = ((size[2] / cell).ceil() as usize).clamp(1, 512);
    let (dy, dz) = (size[1] / ny as f64, size[2] / nz as f64);
    let sa = Solid::within(a, region);
    let sb = Solid::within(b, region);
    let mut vol = 0.0;
    for iy in 0..ny {
        // A sliver off the cell centre keeps rays off the edges of axis-aligned meshes.
        let y = region.min[1] + (iy as f64 + 0.5) * dy + dy * 1.234_567e-4;
        for iz in 0..nz {
            let z = region.min[2] + (iz as f64 + 0.5) * dz + dz * 2.345_678e-4;
            let ia = sa.intervals(y, z);
            if ia.is_empty() {
                continue;
            }
            let ib = sb.intervals(y, z);
            vol += overlap_len(&ia, &ib, region.min[0], region.max[0]) * dy * dz;
        }
    }
    vol
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_box_measures_like_a_box() {
        let m = Mesh::cuboid([0.0, 0.0, 0.0], [10.0, 20.0, 30.0]);
        let mo = m.moments();
        assert!((mo.volume - 6000.0).abs() < 1e-9, "{}", mo.volume);
        assert!((mo.centroid[1] - 10.0).abs() < 1e-9);
        let i = mo.inertia_about_centroid(1.0);
        // Ixx = V (b² + c²) / 12 with b = 20, c = 30.
        assert!((i[0][0] - 6000.0 * (400.0 + 900.0) / 12.0).abs() < 1e-6, "{i:?}");
        assert!(i[0][1].abs() < 1e-6);
    }

    #[test]
    fn two_boxes_share_their_overlap() {
        let a = vec![Mesh::cuboid([0.0; 3], [10.0; 3])];
        let b = vec![Mesh::cuboid([5.0, 5.0, 5.0], [15.0, 15.0, 15.0])];
        let region = a[0].aabb().intersect(&b[0].aabb()).unwrap();
        let v = shared_volume(&a, &b, &region, 0.5);
        assert!((v - 125.0).abs() < 1.0, "{v}");
        let c = vec![Mesh::cuboid([20.0; 3], [30.0; 3])];
        assert!(a[0].aabb().intersect(&c[0].aabb()).is_none());
    }
}
