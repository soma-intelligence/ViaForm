//! A sized frame as a solid: voxels inside any bar or joint (and the keep-in regions) on the
//! study's grid, and a surface of closed parts: a twelve-sided tube per bar, a low-poly sphere per
//! joint, and each keep-in region.

use rayon::prelude::*;

use super::beam::{V3, add, cross, dot, norm, scale, sub};
use super::{Frame, Layout};
use crate::solid::grid::unit;
use crate::solid::{Grid, Mesh, Region, Study};

/// Sides of a tube.
const SIDES: usize = 12;

pub fn layout(study: &Study, frame: &Frame) -> Result<Layout, String> {
    let grid = Grid::new(study.min, study.max, study.voxel);
    if grid.n.iter().map(|&n| n as f64).product::<f64>() > 2e8 {
        return Err("too many voxels: choose a larger voxel".into());
    }
    let density = raster(&grid, frame, &study.keep_in);
    let mut mesh = tubes(frame);
    for r in &study.keep_in {
        let (positions, indices) = solid(r, study);
        append(&mut mesh, &positions, &indices, 0.0);
    }
    Ok(Layout { grid, density, mesh: Some(mesh), history: frame.history.clone() })
}

/// A capsule (a sphere when both ends meet) and its bounds.
struct Capsule {
    a: V3,
    b: V3,
    r: f64,
    lo: V3,
    hi: V3,
}

impl Capsule {
    fn new(a: V3, b: V3, r: f64) -> Self {
        Self { a, b, r, lo: std::array::from_fn(|i| a[i].min(b[i]) - r), hi: std::array::from_fn(|i| a[i].max(b[i]) + r) }
    }

    fn holds(&self, p: V3) -> bool {
        let ab = sub(self.b, self.a);
        let ap = sub(p, self.a);
        let l2 = dot(ab, ab);
        let t = if l2 > 0.0 { (dot(ap, ab) / l2).clamp(0.0, 1.0) } else { 0.0 };
        let q = sub(ap, scale(ab, t));
        dot(q, q) < self.r * self.r
    }
}

/// 1 for every element whose centre is inside a bar, a joint or a keep-in region.
pub fn raster(grid: &Grid, frame: &Frame, keep_in: &[Region]) -> Vec<f32> {
    let mut parts: Vec<Capsule> = frame.beams.iter().map(|b| Capsule::new(frame.nodes[b.ends[0]], frame.nodes[b.ends[1]], b.diameter / 2.0)).collect();
    parts.extend(frame.nodes.iter().zip(&frame.joints).map(|(&p, &r)| Capsule::new(p, p, r)));
    let [nx, ny, _] = grid.n;
    let (h, o) = (grid.h, grid.origin);
    // Elements whose centre lies within `lo..=hi` along axis `a`.
    let span = |lo: f64, hi: f64, a: usize, n: usize| -> Option<(usize, usize)> {
        let first = ((lo - o[a]) / h - 0.5).ceil().max(0.0);
        let last = ((hi - o[a]) / h - 0.5).floor().min(n as f64 - 1.0);
        (last >= first).then_some((first as usize, last as usize))
    };
    let mut density = vec![0.0f32; grid.elements()];
    density.par_chunks_mut(nx * ny).enumerate().for_each(|(k, slice)| {
        let z = o[2] + (k as f64 + 0.5) * h;
        for c in parts.iter().filter(|c| z >= c.lo[2] && z <= c.hi[2]) {
            let (Some((i0, i1)), Some((j0, j1))) = (span(c.lo[0], c.hi[0], 0, nx), span(c.lo[1], c.hi[1], 1, ny)) else {
                continue;
            };
            for j in j0..=j1 {
                let y = o[1] + (j as f64 + 0.5) * h;
                for i in i0..=i1 {
                    let at = i + nx * j;
                    if slice[at] == 0.0 && c.holds([o[0] + (i as f64 + 0.5) * h, y, z]) {
                        slice[at] = 1.0;
                    }
                }
            }
        }
        if !keep_in.is_empty() {
            for j in 0..ny {
                for i in 0..nx {
                    let p = [o[0] + (i as f64 + 0.5) * h, o[1] + (j as f64 + 0.5) * h, z];
                    if keep_in.iter().any(|r| r.contains(p)) {
                        slice[i + nx * j] = 1.0;
                    }
                }
            }
        }
    });
    density
}

/// Two unit vectors across `n`, with `n` a right-handed frame.
fn across(n: V3) -> (V3, V3) {
    let helper = if n[0].abs() < 0.9 { [1.0, 0.0, 0.0] } else { [0.0, 1.0, 0.0] };
    let e1 = unit(cross(helper, n));
    (e1, cross(n, e1))
}

/// A closed prism of `sides` around the segment `a`-`b` (radius `r`), capped at both ends.
fn prism(a: V3, b: V3, r: f64, sides: usize) -> (Vec<V3>, Vec<[u32; 3]>) {
    let n = unit(sub(b, a));
    let (e1, e2) = across(n);
    let mut pos = Vec::with_capacity(2 * sides + 2);
    for end in [a, b] {
        for k in 0..sides {
            let t = 2.0 * std::f64::consts::PI * k as f64 / sides as f64;
            pos.push(add(end, add(scale(e1, r * t.cos()), scale(e2, r * t.sin()))));
        }
    }
    pos.push(a);
    pos.push(b);
    let s = sides as u32;
    let (ca, cb) = (2 * s, 2 * s + 1);
    let mut tri = Vec::with_capacity(4 * sides);
    for k in 0..s {
        let k1 = (k + 1) % s;
        tri.push([k, k1, s + k1]);
        tri.push([k, s + k1, s + k]);
        tri.push([cb, s + k, s + k1]);
        tri.push([ca, k1, k]);
    }
    (pos, tri)
}

/// The unit icosphere, subdivided `levels` times, outward counter-clockwise.
fn icosphere(levels: usize) -> (Vec<V3>, Vec<[u32; 3]>) {
    let t = (1.0 + 5f64.sqrt()) / 2.0;
    let mut pos: Vec<V3> = [[-1.0, t, 0.0], [1.0, t, 0.0], [-1.0, -t, 0.0], [1.0, -t, 0.0], [0.0, -1.0, t], [0.0, 1.0, t], [0.0, -1.0, -t], [0.0, 1.0, -t], [t, 0.0, -1.0], [t, 0.0, 1.0], [-t, 0.0, -1.0], [-t, 0.0, 1.0]].map(unit).to_vec();
    let mut tri: Vec<[u32; 3]> = vec![
        [0, 11, 5],
        [0, 5, 1],
        [0, 1, 7],
        [0, 7, 10],
        [0, 10, 11],
        [1, 5, 9],
        [5, 11, 4],
        [11, 10, 2],
        [10, 7, 6],
        [7, 1, 8],
        [3, 9, 4],
        [3, 4, 2],
        [3, 2, 6],
        [3, 6, 8],
        [3, 8, 9],
        [4, 9, 5],
        [2, 4, 11],
        [6, 2, 10],
        [8, 6, 7],
        [9, 8, 1],
    ];
    for _ in 0..levels {
        let mut mid = std::collections::HashMap::new();
        let mut half = |a: u32, b: u32, pos: &mut Vec<V3>| -> u32 {
            *mid.entry((a.min(b), a.max(b))).or_insert_with(|| {
                pos.push(unit(scale(add(pos[a as usize], pos[b as usize]), 0.5)));
                pos.len() as u32 - 1
            })
        };
        let mut next = Vec::with_capacity(tri.len() * 4);
        for &[a, b, c] in &tri {
            let (ab, bc, ca) = (half(a, b, &mut pos), half(b, c, &mut pos), half(c, a, &mut pos));
            next.extend([[a, ab, ca], [b, bc, ab], [c, ca, bc], [ab, bc, ca]]);
        }
        tri = next;
    }
    (pos, tri)
}

fn append(mesh: &mut Mesh, pos: &[V3], tri: &[[u32; 3]], stress: f64) {
    let base = (mesh.positions.len() / 3) as u32;
    mesh.positions.extend(pos.iter().flat_map(|p| p.map(|x| x as f32)));
    mesh.indices.extend(tri.iter().flat_map(|t| t.map(|i| i + base)));
    mesh.stress.extend(std::iter::repeat_n(stress as f32, pos.len()));
}

/// Tubes and joints, each closed, stress per vertex from its bar (a joint takes its worst bar).
pub fn tubes(frame: &Frame) -> Mesh {
    let mut mesh = Mesh::default();
    let mut worst = vec![0.0f64; frame.nodes.len()];
    for b in &frame.beams {
        let (a, c) = (frame.nodes[b.ends[0]], frame.nodes[b.ends[1]]);
        let (pos, tri) = prism(a, c, b.diameter / 2.0, SIDES);
        append(&mut mesh, &pos, &tri, b.stress);
        for &v in &b.ends {
            worst[v] = worst[v].max(b.stress);
        }
    }
    let (unit_pos, unit_tri) = icosphere(1);
    for (v, (&p, &r)) in frame.nodes.iter().zip(&frame.joints).enumerate() {
        let pos: Vec<V3> = unit_pos.iter().map(|&q| add(p, scale(q, r))).collect();
        append(&mut mesh, &pos, &unit_tri, worst[v]);
    }
    mesh
}

/// A keep-in region as a closed solid (boxes clipped to the design space, cylinders to the part
/// of their axis inside it).
fn solid(r: &Region, study: &Study) -> (Vec<V3>, Vec<[u32; 3]>) {
    match r.hull() {
        Region::Tube { .. } => unreachable!("a hull is never a tube"),
        Region::Box { min, max } => {
            let lo: V3 = std::array::from_fn(|a| min[a].max(study.min[a]));
            let hi: V3 = std::array::from_fn(|a| max[a].min(study.max[a]).max(lo[a]));
            let pos = (0..8).map(|c| std::array::from_fn(|a| if c & (1 << a) != 0 { hi[a] } else { lo[a] })).collect();
            let tri = vec![[0, 2, 3], [0, 3, 1], [4, 5, 7], [4, 7, 6], [0, 1, 5], [0, 5, 4], [2, 6, 7], [2, 7, 3], [0, 4, 6], [0, 6, 2], [1, 3, 7], [1, 7, 5]];
            (pos, tri)
        }
        Region::Sphere { center, radius } => {
            let (pos, tri) = icosphere(2);
            (pos.iter().map(|&q| add(center, scale(q, radius))).collect(), tri)
        }
        Region::Cylinder { base, axis, radius, length } => {
            let a = unit(axis);
            let (mut t0, mut t1) = (0.0, length);
            for i in 0..3 {
                if a[i].abs() > 1e-12 {
                    let (u, v) = ((study.min[i] - base[i]) / a[i], (study.max[i] - base[i]) / a[i]);
                    t0 = f64::max(t0, u.min(v));
                    t1 = f64::min(t1, u.max(v));
                }
            }
            if t1 <= t0 || norm(a) == 0.0 {
                (t0, t1) = (0.0, length.max(1e-9));
            }
            prism(add(base, scale(a, t0)), add(base, scale(a, t1)), radius, 2 * SIDES)
        }
    }
}
