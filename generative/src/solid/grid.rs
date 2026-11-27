//! The voxel grid and how regions land on it.

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use super::Region;

/// A box of `n[0] × n[1] × n[2]` cubic voxels of edge `h`, corner at `origin`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Grid {
    pub n: [usize; 3],
    pub h: f64,
    pub origin: [f64; 3],
}

impl Grid {
    /// The grid covering `min..max` with voxels of edge about `voxel` (rounded so they fit).
    pub fn new(min: [f64; 3], max: [f64; 3], voxel: f64) -> Self {
        let size = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
        let n = size.map(|s| ((s / voxel).round() as usize).max(1));
        // One edge for all voxels. A thin side (a plate, a few voxels through) decides, so the
        // part is exactly as thick as asked (a 3 mm sheet stays 3 mm); otherwise the longest
        // side does and the others round to it.
        let thin = (0..3).filter(|&a| n[a] <= 8).min_by_key(|&a| n[a]);
        let h = match thin {
            Some(a) => size[a] / n[a] as f64,
            None => (0..3).map(|a| size[a] / n[a] as f64).fold(0.0, f64::max),
        };
        let n = size.map(|s| ((s / h).round() as usize).max(1));
        Self { n, h, origin: min }
    }

    /// Largest gap between the grid's extent and the box it was asked for, as a share of that
    /// side.
    pub fn extent_error(&self, min: [f64; 3], max: [f64; 3]) -> f64 {
        (0..3).map(|a| ((self.n[a] as f64 * self.h) - (max[a] - min[a])).abs() / (max[a] - min[a]).abs().max(1e-12)).fold(0.0, f64::max)
    }

    pub fn elements(&self) -> usize {
        self.n[0] * self.n[1] * self.n[2]
    }

    pub fn nodes(&self) -> usize {
        (self.n[0] + 1) * (self.n[1] + 1) * (self.n[2] + 1)
    }

    pub fn dofs(&self) -> usize {
        3 * self.nodes()
    }

    pub fn element(&self, i: usize, j: usize, k: usize) -> usize {
        i + self.n[0] * (j + self.n[1] * k)
    }

    pub fn node(&self, i: usize, j: usize, k: usize) -> usize {
        i + (self.n[0] + 1) * (j + (self.n[1] + 1) * k)
    }

    pub fn element_ijk(&self, e: usize) -> [usize; 3] {
        [e % self.n[0], (e / self.n[0]) % self.n[1], e / (self.n[0] * self.n[1])]
    }

    pub fn node_ijk(&self, v: usize) -> [usize; 3] {
        let (nx, ny) = (self.n[0] + 1, self.n[1] + 1);
        [v % nx, (v / nx) % ny, v / (nx * ny)]
    }

    pub fn node_position(&self, v: usize) -> [f64; 3] {
        let ijk = self.node_ijk(v);
        [0, 1, 2].map(|a| self.origin[a] + ijk[a] as f64 * self.h)
    }

    pub fn element_center(&self, e: usize) -> [f64; 3] {
        let ijk = self.element_ijk(e);
        [0, 1, 2].map(|a| self.origin[a] + (ijk[a] as f64 + 0.5) * self.h)
    }

    /// The eight nodes of element `e`, in the hexahedron's standard order: the bottom face
    /// (z low) counter-clockwise from the corner, then the top face.
    pub fn element_nodes(&self, e: usize) -> [usize; 8] {
        let [i, j, k] = self.element_ijk(e);
        [
            self.node(i, j, k),
            self.node(i + 1, j, k),
            self.node(i + 1, j + 1, k),
            self.node(i, j + 1, k),
            self.node(i, j, k + 1),
            self.node(i + 1, j, k + 1),
            self.node(i + 1, j + 1, k + 1),
            self.node(i, j + 1, k + 1),
        ]
    }

    /// The 24 degrees of freedom of element `e`, node by node, x y z.
    pub fn element_dofs(&self, e: usize) -> [usize; 24] {
        let nodes = self.element_nodes(e);
        std::array::from_fn(|d| 3 * nodes[d / 3] + d % 3)
    }

    /// Nodes inside `region`; the nearest node when none is.
    pub fn nodes_in(&self, region: &Region) -> Vec<usize> {
        let inside: Vec<usize> = (0..self.nodes()).filter(|&v| region.contains(self.node_position(v))).collect();
        if !inside.is_empty() {
            return inside;
        }
        let c = region.center();
        let nearest = (0..self.nodes()).min_by(|&a, &b| dist2(self.node_position(a), c).total_cmp(&dist2(self.node_position(b), c)));
        nearest.into_iter().collect()
    }

    /// Elements any of whose corners (pulled 2 % toward the centre, so a voxel that only touches
    /// the region's face is spared) or whose centre is inside `region`: a keep-out so voxelised
    /// leaves no solid inside it.
    pub fn elements_touching(&self, region: &Region) -> Vec<usize> {
        (0..self.elements())
            .into_par_iter()
            .filter(|&e| {
                let c = self.element_center(e);
                region.contains(c)
                    || self.element_nodes(e).iter().any(|&v| {
                        let p = self.node_position(v);
                        region.contains([0, 1, 2].map(|a| 0.98 * p[a] + 0.02 * c[a]))
                    })
            })
            .collect()
    }

    /// Elements whose centre is inside `region`.
    pub fn elements_in(&self, region: &Region) -> Vec<usize> {
        (0..self.elements()).filter(|&e| region.contains(self.element_center(e))).collect()
    }

    /// The element mirrored across the planes in `symmetry` (through the grid's centre).
    pub fn mirror(&self, e: usize, symmetry: [bool; 3]) -> usize {
        let ijk = self.element_ijk(e);
        let m = [0, 1, 2].map(|a| if symmetry[a] { self.n[a] - 1 - ijk[a] } else { ijk[a] });
        self.element(m[0], m[1], m[2])
    }
}

fn dist2(a: [f64; 3], b: [f64; 3]) -> f64 {
    (0..3).map(|i| (a[i] - b[i]).powi(2)).sum()
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// `v` scaled to unit length (`v` itself when zero).
pub fn unit(v: [f64; 3]) -> [f64; 3] {
    let l = dot(v, v).sqrt();
    if l > 0.0 { v.map(|x| x / l) } else { v }
}

impl Region {
    /// The region with a tube read as the solid cylinder around it (for code that measures or
    /// draws regions rather than testing points).
    pub fn hull(&self) -> Region {
        match *self {
            Region::Tube { base, axis, outer, length, .. } => Region::Cylinder { base, axis, radius: outer, length },
            r => r,
        }
    }

    pub fn contains(&self, p: [f64; 3]) -> bool {
        const EPS: f64 = 1e-9;
        match *self {
            Region::Box { min, max } => (0..3).all(|a| p[a] >= min[a] - EPS && p[a] <= max[a] + EPS),
            Region::Sphere { center, radius } => dist2(p, center) <= (radius + EPS).powi(2),
            Region::Cylinder { base, axis, radius, length } => {
                let a = unit(axis);
                let d = sub(p, base);
                let t = dot(d, a);
                if t < -EPS || t > length + EPS {
                    return false;
                }
                dot(d, d) - t * t <= (radius + EPS).powi(2)
            }
            Region::Tube { base, axis, inner, outer, length } => {
                let a = unit(axis);
                let d = sub(p, base);
                let t = dot(d, a);
                if t < -EPS || t > length + EPS {
                    return false;
                }
                let r2 = dot(d, d) - t * t;
                r2 <= (outer + EPS).powi(2) && r2 >= (inner - EPS).max(0.0).powi(2)
            }
        }
    }

    pub fn center(&self) -> [f64; 3] {
        match *self {
            Region::Box { min, max } => [0, 1, 2].map(|a| (min[a] + max[a]) / 2.0),
            Region::Sphere { center, .. } => center,
            Region::Cylinder { base, axis, length, .. } | Region::Tube { base, axis, length, .. } => {
                let a = unit(axis);
                [0, 1, 2].map(|i| base[i] + a[i] * length / 2.0)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indices_round_trip() {
        let g = Grid::new([0.0; 3], [6.0, 4.0, 2.0], 1.0);
        assert_eq!(g.n, [6, 4, 2]);
        for e in 0..g.elements() {
            let [i, j, k] = g.element_ijk(e);
            assert_eq!(g.element(i, j, k), e);
        }
        for v in 0..g.nodes() {
            let [i, j, k] = g.node_ijk(v);
            assert_eq!(g.node(i, j, k), v);
        }
        assert_eq!(g.element_nodes(0), [0, 1, 8, 7, 35, 36, 43, 42]);
    }

    #[test]
    fn regions() {
        let c = Region::Cylinder { base: [0.0; 3], axis: [0.0, 0.0, 2.0], radius: 1.0, length: 3.0 };
        assert!(c.contains([0.5, 0.5, 1.0]));
        assert!(!c.contains([0.0, 0.0, 3.5]));
        assert!(!c.contains([1.0, 1.0, 1.0]));
        assert_eq!(c.center(), [0.0, 0.0, 1.5]);
        let g = Grid::new([0.0; 3], [4.0; 3], 1.0);
        assert_eq!(g.mirror(g.element(0, 1, 2), [true, false, true]), g.element(3, 1, 1));
    }
}
