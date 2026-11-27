//! From densities to a surface: node densities averaged from the elements, marching tetrahedra
//! at the threshold (each voxel cut into the six tetrahedra of its main diagonal, the same way in
//! every voxel, so neighbours agree on every shared face), capped on the design space's walls so
//! the surface closes there, vertices welded by grid edge, islands removed, Taubin smoothing (no
//! shrink) with wall vertices kept on their walls, stress carried to the vertices.
//!
//! Marching tetrahedra on a conforming split is watertight and manifold by construction (the
//! surface is the level set of a piecewise linear field), which marching cubes is not without
//! careful ambiguity resolution. The caps are the limit of a layer of zeros padded on at no
//! distance: the part ends on the wall rather than half a voxel beyond it.

use std::sync::OnceLock;

use rayon::prelude::*;

use super::{Grid, Mesh};

/// Taubin's shrink and inflate factors.
const LAMBDA: f64 = 0.5;
const MU: f64 = -0.53;
/// Shells with fewer triangles than this share of the largest shell's are islands.
const ISLAND: f64 = 0.01;
/// Crossings stay this share of an edge away from its ends, so no two vertices meet even when a
/// node sits exactly on the level (binary fields put many there).
const T_MIN: f64 = 0.01;
/// Mask bit of a node's own vertex (a cap corner on a wall); bits 0..7 are its edges.
const NODE_BIT: u32 = 7;
/// Offset of corner `c` of a voxel (bit 0 x, bit 1 y, bit 2 z); also an edge's direction.
const CORNER: [[usize; 3]; 8] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]];

/// What [`surface_report`] did besides the mesh.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Surfacing {
    /// Closed shells kept (a part with a cavity has two).
    pub shells: usize,
    /// Shells dropped as islands (under 1 % of the largest's triangles), and their triangles.
    pub islands: usize,
    pub island_triangles: usize,
}

/// The closed surface of `density ≥ level`.
pub fn surface(grid: &Grid, density: &[f32], level: f32, smoothing: usize) -> Mesh {
    surface_report(grid, density, level, smoothing).0
}

/// [`surface`], and what it removed. A grid that doesn't match the densities, or a level that
/// isn't a number, gives an empty mesh.
pub fn surface_report(grid: &Grid, density: &[f32], level: f32, smoothing: usize) -> (Mesh, Surfacing) {
    let Some(d) = Dims::new(grid, density.len()) else { return Default::default() };
    if !level.is_finite() {
        return Default::default();
    }
    let values = node_values(&d, density);
    let inside: Vec<bool> = values.par_iter().map(|&v| v >= level).collect();
    let masks = masks(&d, &inside);
    let Some(base) = bases(&d, &masks) else { return Default::default() };
    let (mut pos, mut lock) = vertices(&d, &values, level, &masks);
    let mut tris = cell_triangles(&d, &inside, &masks, &base);
    tris.extend(caps(&d, &inside, &masks, &base));
    let report = remove_islands(&mut pos, &mut lock, &mut tris);
    smooth(&mut pos, &lock, &tris, smoothing);
    let mesh = Mesh {
        positions: pos.iter().flat_map(|p| p.map(|x| x as f32)).collect(),
        indices: tris.into_iter().flatten().collect(),
        stress: Vec::new(),
    };
    (mesh, report)
}

/// How far smoothing may move a vertex of a built surface, in voxel edges: inward (it would
/// thin a one-voxel member) and in all.
const BUILT_INWARD: f64 = 0.25;
const BUILT_OUTWARD: f64 = 0.25;
const BUILT_MOVE: f64 = 0.5;
const BUILT_OFFSET: f64 = 0.3;

/// The surface of the solid voxels (`solid[e]`), as built and as analysed: the mean-density
/// surface at 0.5, except that a voxel the mean would thin away (a strut or a wall's edge one
/// voxel across) keeps every corner inside, so thin members keep their section and face-joined
/// bridges stay joined (the plain mean drops one-voxel struts and cuts thin bridges). Smoothing
/// rounds the voxel steps but moves no vertex more than a quarter voxel along its normal or half
/// a voxel in all, so the volume stays the voxels'.
pub fn surface_solid(grid: &Grid, solid: &[bool], smoothing: usize) -> (Mesh, Surfacing) {
    let Some(d) = Dims::new(grid, solid.len()) else { return Default::default() };
    let density: Vec<f32> = solid.iter().map(|&s| if s { 1.0 } else { 0.0 }).collect();
    let mut values = node_values(&d, &density);
    // A solid voxel whose corners average under the level would thin away or vanish (a strut or
    // a wall's edge one voxel across): its corners are raised to the level so it stays. Thick
    // material is left on the plain mean, which cuts convex edges and fills concave ones evenly.
    let [nx, ny, _] = d.n;
    let corners = |e: usize| {
        let (i, j, k) = (e % nx, (e / nx) % ny, e / (nx * ny));
        CORNER.map(|o| d.node([i + o[0], j + o[1], k + o[2]]))
    };
    let thin: Vec<usize> = (0..solid.len())
        .into_par_iter()
        .filter(|&e| solid[e] && corners(e).iter().map(|&v| values[v]).sum::<f32>() < 4.0)
        .collect();
    for e in thin {
        for v in corners(e) {
            values[v] = values[v].max(0.5);
        }
    }
    let level = 0.5f32;
    let inside: Vec<bool> = values.par_iter().map(|&v| v >= level).collect();
    let masks = masks(&d, &inside);
    let Some(base) = bases(&d, &masks) else { return Default::default() };
    let (mut pos, mut lock) = vertices(&d, &values, level, &masks);
    let mut tris = cell_triangles(&d, &inside, &masks, &base);
    tris.extend(caps(&d, &inside, &masks, &base));
    let report = remove_islands(&mut pos, &mut lock, &mut tris);
    let start = pos.clone();
    smooth(&mut pos, &lock, &tris, smoothing);
    let normals = vertex_normals(&start, &tris);
    let (inward, outward, most) = (BUILT_INWARD * d.h, BUILT_OUTWARD * d.h, BUILT_MOVE * d.h);
    pos.par_iter_mut().zip(start.par_iter()).zip(normals.par_iter()).for_each(|((p, s), n)| {
        let mut m = [p[0] - s[0], p[1] - s[1], p[2] - s[2]];
        let dn = dot(m, *n);
        if dn < -inward {
            for a in 0..3 {
                m[a] += n[a] * (-inward - dn);
            }
        } else if dn > outward {
            for a in 0..3 {
                m[a] -= n[a] * (dn - outward);
            }
        }
        let len = dot(m, m).sqrt();
        if len > most {
            for a in 0..3 {
                m[a] *= most / len;
            }
        }
        *p = [s[0] + m[0], s[1] + m[1], s[2] + m[2]];
    });
    // The level cuts convex edges and fills concave ones, which leaves the shell a few percent off
    // the voxels on thin parts: one even offset along the normals (at most BUILT_OFFSET voxel)
    // puts the enclosed volume back on the solid's.
    let target = solid.iter().filter(|&&s| s).count() as f64 * d.h.powi(3);
    let (v, a) = volume_area(&pos, &tris);
    if a > 0.0 {
        let off = ((target - v) / a).clamp(-BUILT_OFFSET * d.h, BUILT_OFFSET * d.h);
        let normals = vertex_normals(&pos, &tris);
        pos.par_iter_mut().zip(normals.par_iter()).for_each(|(p, n)| {
            for k in 0..3 {
                p[k] += n[k] * off;
            }
        });
    }
    let mesh = Mesh {
        positions: pos.iter().flat_map(|p| p.map(|x| x as f32)).collect(),
        indices: tris.into_iter().flatten().collect(),
        stress: Vec::new(),
    };
    (mesh, report)
}

/// Enclosed volume and area of a closed triangle set.
fn volume_area(pos: &[[f64; 3]], tris: &[[u32; 3]]) -> (f64, f64) {
    tris.par_iter()
        .map(|t| {
            let (a, b, c) = (pos[t[0] as usize], pos[t[1] as usize], pos[t[2] as usize]);
            let f = cross([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [c[0] - a[0], c[1] - a[1], c[2] - a[2]]);
            (dot(a, cross(b, c)) / 6.0, dot(f, f).sqrt() / 2.0)
        })
        .reduce(|| (0.0, 0.0), |x, y| (x.0 + y.0, x.1 + y.1))
}

/// Area-weighted unit normals per vertex.
fn vertex_normals(pos: &[[f64; 3]], tris: &[[u32; 3]]) -> Vec<[f64; 3]> {
    let mut n = vec![[0.0; 3]; pos.len()];
    for t in tris {
        let (a, b, c) = (pos[t[0] as usize], pos[t[1] as usize], pos[t[2] as usize]);
        let f = cross([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [c[0] - a[0], c[1] - a[1], c[2] - a[2]]);
        for &v in t {
            for k in 0..3 {
                n[v as usize][k] += f[k];
            }
        }
    }
    for v in &mut n {
        let l = dot(*v, *v).sqrt();
        if l > 0.0 {
            *v = v.map(|x| x / l);
        }
    }
    n
}

/// Cuts exact round holes into a surface: every vertex within `reach` of one of the `holes`'
/// walls (cylinders, inside or out, along its length) that faces the hole (its normal points to
/// the axis) goes to its radius along the radius, so a bore voxels can only approximate comes
/// out at its true diameter. A thin wall's outer face, or a face across the hole's end, is left
/// where it is. Returns which vertices moved. Other regions are ignored.
pub fn cut_holes(mesh: &mut Mesh, holes: &[super::Region], reach: f64) -> Vec<bool> {
    let pos: Vec<[f64; 3]> = mesh.positions.chunks(3).map(|p| [p[0] as f64, p[1] as f64, p[2] as f64]).collect();
    let tris: Vec<[u32; 3]> = mesh.indices.chunks(3).map(|t| [t[0], t[1], t[2]]).collect();
    let normals = vertex_normals(&pos, &tris);
    let mut moved = vec![false; pos.len()];
    for r in holes {
        let super::Region::Cylinder { base, axis, radius, length } = *r else { continue };
        let l = dot(axis, axis).sqrt();
        if !(l > 0.0 && radius > 0.0) {
            continue;
        }
        let a = axis.map(|x| x / l);
        mesh.positions.par_chunks_mut(3).zip(normals.par_iter()).zip(moved.par_iter_mut()).for_each(|((p, n), m)| {
            let q = [p[0] as f64 - base[0], p[1] as f64 - base[1], p[2] as f64 - base[2]];
            let t = dot(q, a);
            if t < -1e-6 || t > length + 1e-6 {
                return;
            }
            let rad = [q[0] - t * a[0], q[1] - t * a[1], q[2] - t * a[2]];
            let d = dot(rad, rad).sqrt();
            if d < 1e-9 || (d - radius).abs() >= reach {
                return;
            }
            // A vertex with a normal must face the axis; one with none (no triangles) is taken.
            if dot(*n, *n) > 0.0 && dot(*n, rad) / d > -0.3 {
                return;
            }
            *m = true;
            for k in 0..3 {
                p[k] = (base[k] + t * a[k] + rad[k] * radius / d) as f32;
            }
        });
    }
    moved
}

/// Moves every vertex not `fixed` by one even offset along its normal (at most `most`) so the
/// closed mesh encloses `target`: the cut holes stay exact and the rest takes up the difference.
pub fn match_volume(mesh: &mut Mesh, target: f64, fixed: &[bool], most: f64) {
    let mut pos: Vec<[f64; 3]> = mesh.positions.chunks(3).map(|p| [p[0] as f64, p[1] as f64, p[2] as f64]).collect();
    let tris: Vec<[u32; 3]> = mesh.indices.chunks(3).map(|t| [t[0], t[1], t[2]]).collect();
    let normals = vertex_normals(&pos, &tris);
    // Volume changes by the free area times the offset; two passes absorb the curvature term.
    for _ in 0..2 {
        let (v, _) = volume_area(&pos, &tris);
        let free: f64 = tris
            .iter()
            .map(|t| {
                let (a, b, c) = (pos[t[0] as usize], pos[t[1] as usize], pos[t[2] as usize]);
                let f = cross([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [c[0] - a[0], c[1] - a[1], c[2] - a[2]]);
                let share = t.iter().filter(|&&i| !fixed.get(i as usize).copied().unwrap_or(false)).count() as f64 / 3.0;
                dot(f, f).sqrt() / 2.0 * share
            })
            .sum();
        if free <= 0.0 {
            return;
        }
        let off = ((target - v) / free).clamp(-most, most);
        if off.abs() < 1e-9 {
            break;
        }
        for (i, p) in pos.iter_mut().enumerate() {
            if !fixed.get(i).copied().unwrap_or(false) {
                for k in 0..3 {
                    p[k] += normals[i][k] * off;
                }
            }
        }
    }
    mesh.positions = pos.iter().flat_map(|p| p.map(|x| x as f32)).collect();
}

/// Closed shells of a mesh that enclose material (positive volume): bodies, not cavities.
pub fn bodies(mesh: &Mesh) -> usize {
    let nv = mesh.positions.len() / 3;
    if nv == 0 || mesh.indices.is_empty() {
        return 0;
    }
    let mut parent: Vec<u32> = (0..nv as u32).collect();
    fn find(parent: &mut [u32], mut x: u32) -> u32 {
        while parent[x as usize] != x {
            let up = parent[parent[x as usize] as usize];
            parent[x as usize] = up;
            x = up;
        }
        x
    }
    for t in mesh.indices.chunks(3) {
        let r0 = find(&mut parent, t[0]);
        for &b in &t[1..] {
            let rb = find(&mut parent, b);
            if rb != r0 {
                parent[rb.max(r0) as usize] = rb.min(r0);
            }
        }
    }
    let mut vol: std::collections::HashMap<u32, f64> = Default::default();
    let p = &mesh.positions;
    let at = |i: u32| [p[3 * i as usize] as f64, p[3 * i as usize + 1] as f64, p[3 * i as usize + 2] as f64];
    let c = at(mesh.indices[0]);
    for t in mesh.indices.chunks(3) {
        let r = find(&mut parent, t[0]);
        let (a, b, d) = (at(t[0]), at(t[1]), at(t[2]));
        let rel = |x: [f64; 3]| [x[0] - c[0], x[1] - c[1], x[2] - c[2]];
        *vol.entry(r).or_default() += dot(rel(a), cross(rel(b), rel(d))) / 6.0;
    }
    vol.values().filter(|&&v| v > 0.0).count()
}

/// Fills `mesh.stress` from per-element stress: each vertex takes the mean over the elements
/// around its nearest grid node that carry stress (voids, at zero, don't dilute it). Stress that
/// doesn't match the grid leaves it empty.
pub fn carry_stress(grid: &Grid, mesh: &mut Mesh, stress: &[f64]) {
    mesh.stress.clear();
    let Some(d) = Dims::new(grid, stress.len()) else { return };
    let positions = &mesh.positions;
    let out: Vec<f32> = positions
        .par_chunks_exact(3)
        .map(|p| {
            let ijk: [usize; 3] = std::array::from_fn(|a| {
                let x = ((p[a] as f64 - d.origin[a]) / d.h).round();
                if x.is_finite() { x.clamp(0.0, d.n[a] as f64) as usize } else { 0 }
            });
            // The elements around the node; failing those (a vertex half way to a void node),
            // the ring of elements around it.
            let mean = |ring: usize| {
                let (mut sum, mut count) = (0.0, 0usize);
                let near = |a: usize| ijk[a].saturating_sub(ring)..=(ijk[a] + ring - 1).min(d.n[a] - 1);
                for k in near(2) {
                    for j in near(1) {
                        for i in near(0) {
                            let s = stress[i + d.n[0] * (j + d.n[1] * k)];
                            if s.is_finite() && s > 0.0 {
                                sum += s;
                                count += 1;
                            }
                        }
                    }
                }
                (count > 0).then(|| (sum / count as f64) as f32)
            };
            mean(1).or_else(|| mean(2)).unwrap_or(0.0)
        })
        .collect();
    mesh.stress = out;
}

/// Enclosed volume, mm³ (divergence theorem). Triangles naming missing vertices are skipped.
pub fn volume(mesh: &Mesh) -> f64 {
    let p = &mesh.positions;
    let nv = p.len() / 3;
    if nv == 0 {
        return 0.0;
    }
    // About the bounding box's centre, so far-off parts lose no precision.
    let mut lo = [f64::INFINITY; 3];
    let mut hi = [f64::NEG_INFINITY; 3];
    for v in p.as_chunks::<3>().0 {
        for a in 0..3 {
            lo[a] = lo[a].min(v[a] as f64);
            hi[a] = hi[a].max(v[a] as f64);
        }
    }
    let r: [f64; 3] = std::array::from_fn(|a| if lo[a].is_finite() && hi[a].is_finite() { (lo[a] + hi[a]) / 2.0 } else { 0.0 });
    let at = |i: u32| -> Option<[f64; 3]> {
        let i = i as usize;
        (i < nv).then(|| [p[3 * i] as f64 - r[0], p[3 * i + 1] as f64 - r[1], p[3 * i + 2] as f64 - r[2]])
    };
    // Fixed chunks summed in order: the same mesh gives the same bits on any machine.
    let parts: Vec<f64> = mesh
        .indices
        .par_chunks(3 * 4096)
        .map(|c| {
            c.as_chunks::<3>().0.iter()
                .filter_map(|t| {
                    let (a, b, c) = (at(t[0])?, at(t[1])?, at(t[2])?);
                    Some(dot(a, cross(b, c)))
                })
                .sum::<f64>()
        })
        .collect();
    parts.iter().sum::<f64>() / 6.0
}

/// Every edge shared by exactly two triangles, in opposite directions.
pub fn is_closed(mesh: &Mesh) -> bool {
    let Some(mut half) = half_edges(mesh) else { return false };
    half.par_sort_unstable();
    if half.windows(2).any(|w| w[0] == w[1]) {
        return false;
    }
    half.par_iter().all(|&e| half.binary_search(&e.rotate_right(32)).is_ok())
}

/// Closed, and around every vertex its triangles form a single fan (no two sheets touch at a
/// point).
pub fn is_manifold(mesh: &Mesh) -> bool {
    if !is_closed(mesh) {
        return false;
    }
    let nv = mesh.positions.len() / 3;
    // Per vertex, its link: the edge opposite it in each of its triangles, as a map from start
    // to end. A single cycle through all of them is a single fan.
    let mut offset = vec![0usize; nv + 1];
    for &v in &mesh.indices {
        offset[v as usize + 1] += 1;
    }
    for v in 0..nv {
        offset[v + 1] += offset[v];
    }
    let mut fill = offset.clone();
    let mut link = vec![(0u32, 0u32); mesh.indices.len()];
    for t in mesh.indices.as_chunks::<3>().0 {
        for r in 0..3 {
            let (a, b, c) = (t[r], t[(r + 1) % 3], t[(r + 2) % 3]);
            link[fill[a as usize]] = (b, c);
            fill[a as usize] += 1;
        }
    }
    (0..nv).into_par_iter().all(|v| {
        let mut l = link[offset[v]..offset[v + 1]].to_vec();
        if l.is_empty() {
            return true;
        }
        l.sort_unstable();
        let next = |x: u32| l.binary_search_by_key(&x, |e| e.0).ok().map(|i| l[i].1);
        let start = l[0].0;
        let mut at = start;
        for step in 1..=l.len() {
            match next(at) {
                Some(n) if n == start => return step == l.len(),
                Some(n) => at = n,
                None => return false,
            }
        }
        false
    })
}

/// Directed edges `a << 32 | b` of every triangle; `None` when a triangle names a missing or
/// repeated vertex, or there are none.
fn half_edges(mesh: &Mesh) -> Option<Vec<u64>> {
    let nv = (mesh.positions.len() / 3) as u64;
    if mesh.indices.is_empty() || !mesh.indices.len().is_multiple_of(3) {
        return None;
    }
    let ok = mesh.indices.par_chunks_exact(3).all(|t| t.iter().all(|&i| u64::from(i) < nv) && t[0] != t[1] && t[1] != t[2] && t[2] != t[0]);
    if !ok {
        return None;
    }
    Some(
        mesh.indices
            .par_chunks_exact(3)
            .flat_map_iter(|t| {
                let [a, b, c] = [t[0], t[1], t[2]].map(u64::from);
                [(a << 32) | b, (b << 32) | c, (c << 32) | a]
            })
            .collect(),
    )
}

/// The grid's sizes, checked: nodes per axis, layer strides.
struct Dims {
    n: [usize; 3],
    /// Nodes per axis.
    m: [usize; 3],
    /// Nodes per z layer.
    layer: usize,
    nodes: usize,
    origin: [f64; 3],
    h: f64,
}

impl Dims {
    fn new(grid: &Grid, values: usize) -> Option<Self> {
        let n = grid.n;
        if n.contains(&0) || !(grid.h.is_finite() && grid.h > 0.0) || grid.origin.iter().any(|x| !x.is_finite()) {
            return None;
        }
        let elements = n[0].checked_mul(n[1])?.checked_mul(n[2])?;
        let m = [n[0].checked_add(1)?, n[1].checked_add(1)?, n[2].checked_add(1)?];
        let layer = m[0].checked_mul(m[1])?;
        let nodes = layer.checked_mul(m[2])?;
        // Node indices and vertex numbers are u32.
        if elements != values || nodes > u32::MAX as usize {
            return None;
        }
        Some(Self { n, m, layer, nodes, origin: grid.origin, h: grid.h })
    }

    fn ijk(&self, v: usize) -> [usize; 3] {
        [v % self.m[0], (v / self.m[0]) % self.m[1], v / self.layer]
    }

    fn node(&self, ijk: [usize; 3]) -> usize {
        ijk[0] + self.m[0] * ijk[1] + self.layer * ijk[2]
    }

    /// Index step to the node at offset `o`.
    fn step(&self, o: [usize; 3]) -> usize {
        o[0] + self.m[0] * o[1] + self.layer * o[2]
    }
}

/// The elements touching node coordinate `i` along an axis of `n` elements.
fn span(i: usize, n: usize) -> std::ops::RangeInclusive<usize> {
    i.saturating_sub(1)..=i.min(n - 1)
}

/// Per node, the mean density of the (up to eight) elements around it; a value that isn't a
/// number counts as void.
fn node_values(d: &Dims, density: &[f32]) -> Vec<f32> {
    let mut out = vec![0.0f32; d.nodes];
    out.par_chunks_mut(d.layer).enumerate().for_each(|(k, layer)| {
        for j in 0..d.m[1] {
            for i in 0..d.m[0] {
                let (mut sum, mut count) = (0.0f32, 0u32);
                for kk in span(k, d.n[2]) {
                    for jj in span(j, d.n[1]) {
                        for ii in span(i, d.n[0]) {
                            let v = density[ii + d.n[0] * (jj + d.n[1] * kk)];
                            sum += if v.is_finite() { v } else { 0.0 };
                            count += 1;
                        }
                    }
                }
                layer[i + d.m[0] * j] = sum / count as f32;
            }
        }
    });
    out
}

/// Per node: bit `dir - 1` when its edge towards `CORNER[dir]` crosses the level, and
/// [`NODE_BIT`] when it is inside on a wall (a cap corner).
fn masks(d: &Dims, inside: &[bool]) -> Vec<u8> {
    let mut out = vec![0u8; d.nodes];
    out.par_chunks_mut(d.layer).enumerate().for_each(|(k, layer)| {
        for j in 0..d.m[1] {
            for i in 0..d.m[0] {
                let v = d.node([i, j, k]);
                let a = inside[v];
                let mut mask = 0u8;
                for (dir, o) in CORNER.iter().enumerate().skip(1) {
                    if i + o[0] < d.m[0] && j + o[1] < d.m[1] && k + o[2] < d.m[2] && inside[v + d.step(*o)] != a {
                        mask |= 1 << (dir - 1);
                    }
                }
                let wall = i == 0 || j == 0 || k == 0 || i == d.n[0] || j == d.n[1] || k == d.n[2];
                if a && wall {
                    mask |= 1 << NODE_BIT;
                }
                layer[i + d.m[0] * j] = mask;
            }
        }
    });
    out
}

/// Per node, the number of its first vertex (vertices are numbered node by node, then by mask
/// bit); `None` past u32.
fn bases(d: &Dims, masks: &[u8]) -> Option<Vec<u32>> {
    let counts: Vec<u64> = masks.par_chunks(d.layer).map(|l| l.iter().map(|m| u64::from(m.count_ones())).sum()).collect();
    let mut starts = Vec::with_capacity(counts.len());
    let mut total = 0u64;
    for c in counts {
        starts.push(total);
        total += c;
    }
    if total > u64::from(u32::MAX) {
        return None;
    }
    let mut base = vec![0u32; d.nodes];
    base.par_chunks_mut(d.layer).zip(masks.par_chunks(d.layer)).zip(starts.par_iter()).for_each(|((b, m), &s)| {
        let mut at = s as u32;
        for (b, m) in b.iter_mut().zip(m) {
            *b = at;
            at += m.count_ones();
        }
    });
    Some(base)
}

/// Vertex number of `node`'s edge or own vertex `bit`.
fn vid(base: &[u32], masks: &[u8], node: usize, bit: u32) -> u32 {
    base[node] + (u32::from(masks[node]) & ((1 << bit) - 1)).count_ones()
}

/// Every vertex, in number order: position, and per axis whether it sits on a wall across it.
fn vertices(d: &Dims, values: &[f32], level: f32, masks: &[u8]) -> (Vec<[f64; 3]>, Vec<u8>) {
    let level = f64::from(level);
    let layers: Vec<(Vec<[f64; 3]>, Vec<u8>)> = masks
        .par_chunks(d.layer)
        .enumerate()
        .map(|(k, layer)| {
            let mut pos = Vec::new();
            let mut lock = Vec::new();
            for (at, &mask) in layer.iter().enumerate() {
                if mask == 0 {
                    continue;
                }
                let v = k * d.layer + at;
                let ijk = d.ijk(v);
                for bit in 0..8u32 {
                    if mask & (1 << bit) == 0 {
                        continue;
                    }
                    let (o, t) = if bit == NODE_BIT {
                        ([0; 3], 0.0)
                    } else {
                        let o = CORNER[bit as usize + 1];
                        let (a, b) = (f64::from(values[v]), f64::from(values[v + d.step(o)]));
                        (o, ((level - a) / (b - a)).clamp(T_MIN, 1.0 - T_MIN))
                    };
                    pos.push(std::array::from_fn(|a| d.origin[a] + d.h * (ijk[a] as f64 + t * o[a] as f64)));
                    let mut l = 0u8;
                    for a in 0..3 {
                        if o[a] == 0 && (ijk[a] == 0 || ijk[a] == d.n[a]) {
                            l |= 1 << a;
                        }
                    }
                    lock.push(l);
                }
            }
            (pos, lock)
        })
        .collect();
    let total = layers.iter().map(|l| l.0.len()).sum();
    let mut pos = Vec::with_capacity(total);
    let mut lock = Vec::with_capacity(total);
    for (p, l) in layers {
        pos.extend(p);
        lock.extend(l);
    }
    (pos, lock)
}

/// A triangle of a voxel case: per corner, the voxel corner its edge starts at and the edge's
/// mask bit.
type CaseTriangle = [(u8, u8); 3];

/// For each of the 256 inside patterns of a voxel's corners, its triangles: marching tetrahedra
/// on the six tetrahedra around the diagonal from corner 0 to corner 7, outward-facing.
fn cube_table() -> &'static [Vec<CaseTriangle>] {
    static TABLE: OnceLock<Vec<Vec<CaseTriangle>>> = OnceLock::new();
    TABLE.get_or_init(|| (0..=255u8).map(cube_case).collect())
}

/// The six tetrahedra: each a monotone path from corner 0 to corner 7 (one per axis order), so
/// every edge runs from a corner to one with more bits set, and each face of the voxel is cut
/// along the diagonal from its lowest corner.
fn tetrahedra() -> [[u8; 4]; 6] {
    [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]].map(|[p, q, _]| [0, 1 << p, (1 << p) | (1 << q), 7])
}

/// Sign of the volume of tetrahedron `t` as ordered.
fn orientation(t: [u8; 4]) -> i32 {
    let c = t.map(|c| CORNER[c as usize].map(|x| x as i32));
    let e = |i: usize| [c[i][0] - c[0][0], c[i][1] - c[0][1], c[i][2] - c[0][2]];
    let (a, b, d) = (e(1), e(2), e(3));
    let det = a[0] * (b[1] * d[2] - b[2] * d[1]) - a[1] * (b[0] * d[2] - b[2] * d[0]) + a[2] * (b[0] * d[1] - b[1] * d[0]);
    det.signum()
}

/// Sign of a permutation of 0..4.
fn parity(p: [usize; 4]) -> i32 {
    let mut inversions = 0usize;
    for i in 0..4 {
        for j in i + 1..4 {
            if p[i] > p[j] {
                inversions += 1;
            }
        }
    }
    if inversions.is_multiple_of(2) { 1 } else { -1 }
}

/// The edge between corners `a` and `b`: its lower corner and mask bit.
fn edge(a: u8, b: u8) -> (u8, u8) {
    (a & b, (a ^ b) - 1)
}

fn cube_case(cfg: u8) -> Vec<CaseTriangle> {
    let mut out = Vec::new();
    for t in tetrahedra() {
        let s = orientation(t);
        let ins = t.map(|c| cfg >> c & 1 == 1);
        let (inn, out_): (Vec<usize>, Vec<usize>) = (0..4).partition(|&i| ins[i]);
        match (inn.as_slice(), out_.as_slice()) {
            // One corner apart from the other three: one triangle around it. With (a, b, c, d)
            // positive, (ab, ac, ad) faces away from a.
            ([a], [b, c, d]) | ([b, c, d], [a]) => {
                let alone_inside = inn.len() == 1;
                let (a, b, mut c, mut d) = (*a, *b, *c, *d);
                let sign = s * parity([a, b, c, d]);
                if (sign < 0) == alone_inside {
                    std::mem::swap(&mut c, &mut d);
                }
                let [a, b, c, d] = [a, b, c, d].map(|i| t[i]);
                out.push([edge(a, b), edge(a, c), edge(a, d)]);
            }
            // Two and two: a quad between the pairs. With (a, b, c, d) positive and a, b inside,
            // (ac, ad, bd, bc) faces towards c and d.
            ([a, b], [c, d]) => {
                let (a, b, mut c, mut d) = (*a, *b, *c, *d);
                if s * parity([a, b, c, d]) < 0 {
                    std::mem::swap(&mut c, &mut d);
                }
                let [a, b, c, d] = [a, b, c, d].map(|i| t[i]);
                out.push([edge(a, c), edge(a, d), edge(b, d)]);
                out.push([edge(a, c), edge(b, d), edge(b, c)]);
            }
            _ => {}
        }
    }
    out
}

/// The surface inside the box, voxel layer by voxel layer.
fn cell_triangles(d: &Dims, inside: &[bool], masks: &[u8], base: &[u32]) -> Vec<[u32; 3]> {
    let table = cube_table();
    let off = CORNER.map(|o| d.step(o));
    let layers: Vec<Vec<[u32; 3]>> = (0..d.n[2])
        .into_par_iter()
        .map(|k| {
            let mut out = Vec::new();
            for j in 0..d.n[1] {
                for i in 0..d.n[0] {
                    let v0 = d.node([i, j, k]);
                    let mut cfg = 0u8;
                    for (c, &o) in off.iter().enumerate() {
                        if inside[v0 + o] {
                            cfg |= 1 << c;
                        }
                    }
                    if cfg == 0 || cfg == 255 {
                        continue;
                    }
                    for tri in &table[cfg as usize] {
                        out.push(tri.map(|(c, bit)| vid(base, masks, v0 + off[c as usize], u32::from(bit))));
                    }
                }
            }
            out
        })
        .collect();
    layers.concat()
}

/// The caps: on each of the six walls, the part of each wall triangle (the walls are cut like
/// the voxels' faces) that is inside, facing out of the box.
fn caps(d: &Dims, inside: &[bool], masks: &[u8], base: &[u32]) -> Vec<[u32; 3]> {
    let walls: Vec<Vec<[u32; 3]>> = (0..6)
        .into_par_iter()
        .map(|w| {
            let (a, high) = (w / 2, w % 2 == 1);
            let (u, v) = ((a + 1) % 3, (a + 2) % 3);
            let mut out = Vec::new();
            for iv in 0..d.n[v] {
                for iu in 0..d.n[u] {
                    let at = |du: usize, dv: usize| {
                        let mut p = [0; 3];
                        p[a] = if high { d.n[a] } else { 0 };
                        p[u] = iu + du;
                        p[v] = iv + dv;
                        p
                    };
                    // Counter-clockwise about +a; turned over on the low wall.
                    for mut tri in [[at(0, 0), at(1, 0), at(1, 1)], [at(0, 0), at(1, 1), at(0, 1)]] {
                        if !high {
                            tri.swap(1, 2);
                        }
                        clip(d, inside, masks, base, tri, &mut out);
                    }
                }
            }
            out
        })
        .collect();
    walls.concat()
}

/// The inside part of wall triangle `tri` (node coordinates), fanned into triangles.
fn clip(d: &Dims, inside: &[bool], masks: &[u8], base: &[u32], tri: [[usize; 3]; 3], out: &mut Vec<[u32; 3]>) {
    let node = tri.map(|p| d.node(p));
    let ins = node.map(|v| inside[v]);
    if !ins.contains(&true) {
        return;
    }
    let mut poly = [0u32; 4];
    let mut len = 0;
    for r in 0..3 {
        let s = (r + 1) % 3;
        if ins[r] {
            poly[len] = vid(base, masks, node[r], NODE_BIT);
            len += 1;
        }
        if ins[r] != ins[s] {
            let (p, q) = (tri[r], tri[s]);
            let lower = [0, 1, 2].map(|x| p[x].min(q[x]));
            let dir: usize = (0..3).map(|x| p[x].abs_diff(q[x]) << x).sum();
            poly[len] = vid(base, masks, d.node(lower), dir as u32 - 1);
            len += 1;
        }
    }
    for k in 1..len.saturating_sub(1) {
        out.push([poly[0], poly[k], poly[k + 1]]);
    }
}

/// Drops shells under [`ISLAND`] of the largest one's triangles, and the vertices they leave.
fn remove_islands(pos: &mut Vec<[f64; 3]>, lock: &mut Vec<u8>, tris: &mut Vec<[u32; 3]>) -> Surfacing {
    if tris.is_empty() {
        return Surfacing::default();
    }
    let mut parent: Vec<u32> = (0..pos.len() as u32).collect();
    fn find(parent: &mut [u32], mut x: u32) -> u32 {
        while parent[x as usize] != x {
            let up = parent[parent[x as usize] as usize];
            parent[x as usize] = up;
            x = up;
        }
        x
    }
    for t in tris.iter() {
        let r0 = find(&mut parent, t[0]);
        for &b in &t[1..] {
            let rb = find(&mut parent, b);
            if rb != r0 {
                let (lo, hi) = (r0.min(rb), r0.max(rb));
                parent[hi as usize] = lo;
            }
        }
    }
    for v in 0..parent.len() as u32 {
        let r = find(&mut parent, v);
        parent[v as usize] = r;
    }
    let mut size = vec![0usize; pos.len()];
    for t in tris.iter() {
        size[parent[t[0] as usize] as usize] += 1;
    }
    let largest = size.iter().copied().max().unwrap_or(0);
    let shells = size.iter().filter(|&&s| s > 0).count();
    let island = |s: usize| (s as f64) < ISLAND * largest as f64;
    let islands = size.iter().filter(|&&s| s > 0 && island(s)).count();
    if islands == 0 {
        return Surfacing { shells, islands: 0, island_triangles: 0 };
    }
    let before = tris.len();
    tris.retain(|t| !island(size[parent[t[0] as usize] as usize]));
    let mut used = vec![false; pos.len()];
    for t in tris.iter() {
        for &v in t {
            used[v as usize] = true;
        }
    }
    let mut remap = vec![u32::MAX; pos.len()];
    let mut next = 0u32;
    for (v, &u) in used.iter().enumerate() {
        if u {
            remap[v] = next;
            pos[next as usize] = pos[v];
            lock[next as usize] = lock[v];
            next += 1;
        }
    }
    pos.truncate(next as usize);
    lock.truncate(next as usize);
    tris.par_iter_mut().for_each(|t| *t = t.map(|v| remap[v as usize]));
    Surfacing { shells: shells - islands, islands, island_triangles: before - tris.len() }
}

/// `passes` Taubin passes (a λ step then a μ step, uniform weights); a vertex on a wall keeps
/// that coordinate.
fn smooth(pos: &mut Vec<[f64; 3]>, lock: &[u8], tris: &[[u32; 3]], passes: usize) {
    if passes == 0 || tris.is_empty() {
        return;
    }
    // Neighbours from each triangle's directed edges: on a closed manifold every neighbour of a
    // vertex follows it in exactly one of its triangles.
    let nv = pos.len();
    let mut offset = vec![0u32; nv + 1];
    for t in tris {
        for &v in t {
            offset[v as usize + 1] += 1;
        }
    }
    for v in 0..nv {
        offset[v + 1] += offset[v];
    }
    let mut fill: Vec<u32> = offset[..nv].to_vec();
    let mut next = vec![0u32; offset[nv] as usize];
    for t in tris {
        for r in 0..3 {
            let a = t[r] as usize;
            next[fill[a] as usize] = t[(r + 1) % 3];
            fill[a] += 1;
        }
    }
    let mut out = pos.clone();
    for _ in 0..passes {
        for factor in [LAMBDA, MU] {
            out.par_iter_mut().enumerate().for_each(|(v, o)| {
                let ring = &next[offset[v] as usize..offset[v + 1] as usize];
                let p = pos[v];
                if ring.is_empty() {
                    *o = p;
                    return;
                }
                let mut sum = [0.0; 3];
                for &w in ring {
                    let q = pos[w as usize];
                    for a in 0..3 {
                        sum[a] += q[a];
                    }
                }
                let inv = 1.0 / ring.len() as f64;
                *o = std::array::from_fn(|a| if lock[v] & (1 << a) != 0 { p[a] } else { p[a] + factor * (sum[a] * inv - p[a]) });
            });
            std::mem::swap(pos, &mut out);
        }
    }
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

#[cfg(test)]
mod tests {
    use std::f64::consts::PI;
    use std::time::Instant;

    use super::*;

    /// Per element, the share of the voxel inside `f(p) ≤ 0`, sampled 4 × 4 × 4.
    fn field(grid: &Grid, f: impl Fn([f64; 3]) -> f64 + Sync) -> Vec<f32> {
        (0..grid.elements())
            .into_par_iter()
            .map(|e| {
                let [i, j, k] = grid.element_ijk(e);
                let mut hits = 0;
                for s in 0..64 {
                    let o = [s % 4, (s / 4) % 4, s / 16];
                    let p = [0, 1, 2].map(|a| grid.origin[a] + grid.h * ([i, j, k][a] as f64 + (o[a] as f64 + 0.5) / 4.0));
                    if f(p) <= 0.0 {
                        hits += 1;
                    }
                }
                hits as f32 / 64.0
            })
            .collect()
    }

    fn sphere(c: [f64; 3], r: f64) -> impl Fn([f64; 3]) -> f64 + Sync {
        move |p| ((p[0] - c[0]).powi(2) + (p[1] - c[1]).powi(2) + (p[2] - c[2]).powi(2)).sqrt() - r
    }

    fn area(m: &Mesh) -> f64 {
        m.indices
            .as_chunks::<3>().0.iter()
            .map(|t| {
                let p = |i: u32| [0, 1, 2].map(|a| m.positions[3 * i as usize + a] as f64);
                let (a, b, c) = (p(t[0]), p(t[1]), p(t[2]));
                let n = cross([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [c[0] - a[0], c[1] - a[1], c[2] - a[2]]);
                dot(n, n).sqrt() / 2.0
            })
            .sum()
    }

    fn euler(m: &Mesh) -> i64 {
        let mut edges: Vec<(u32, u32)> = m.indices.as_chunks::<3>().0.iter().flat_map(|t| [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])]).map(|(a, b)| (a.min(b), a.max(b))).collect();
        edges.sort_unstable();
        edges.dedup();
        (m.positions.len() / 3) as i64 - edges.len() as i64 + (m.indices.len() / 3) as i64
    }

    fn bounds(m: &Mesh) -> ([f32; 3], [f32; 3]) {
        let mut lo = [f32::INFINITY; 3];
        let mut hi = [f32::NEG_INFINITY; 3];
        for p in m.positions.as_chunks::<3>().0 {
            for a in 0..3 {
                lo[a] = lo[a].min(p[a]);
                hi[a] = hi[a].max(p[a]);
            }
        }
        (lo, hi)
    }

    #[test]
    fn table_is_complete_and_consistent() {
        // Every tetrahedron of the split is positive or negative, never flat, and they fill the
        // voxel: their volumes (1/6 each) add to one.
        let t = tetrahedra();
        assert!(t.iter().all(|&t| orientation(t) != 0));
        let table = cube_table();
        assert!(table[0].is_empty() && table[255].is_empty());
        // A pattern and its complement have the same triangles, turned over.
        for cfg in 1..255usize {
            let a = &table[cfg];
            let b = &table[255 - cfg];
            assert_eq!(a.len(), b.len(), "case {cfg}");
            assert!(!a.is_empty(), "case {cfg}");
        }
    }

    #[test]
    fn sphere_is_closed_manifold_and_measures_right() {
        let r = 10.0;
        let grid = Grid::new([-13.0; 3], [13.0; 3], 1.0);
        let density = field(&grid, sphere([0.0; 3], r));
        let exact_v = 4.0 / 3.0 * PI * r.powi(3);
        let exact_a = 4.0 * PI * r * r;
        let raw = surface(&grid, &density, 0.5, 0);
        assert!(is_closed(&raw) && is_manifold(&raw));
        assert_eq!(euler(&raw), 2);
        let m = surface(&grid, &density, 0.5, 12);
        assert!(is_closed(&m) && is_manifold(&m));
        assert_eq!(euler(&m), 2);
        let (v0, v) = (volume(&raw), volume(&m));
        let a = area(&m);
        eprintln!(
            "sphere r {r}: {} vertices {} triangles, volume raw {v0:.1} smoothed {v:.1} exact {exact_v:.1} ({:+.2} %), area {a:.1} exact {exact_a:.1} ({:+.2} %)",
            m.positions.len() / 3,
            m.indices.len() / 3,
            100.0 * (v / exact_v - 1.0),
            100.0 * (a / exact_a - 1.0)
        );
        assert!((v / exact_v - 1.0).abs() < 0.03, "volume {v} vs {exact_v}");
        assert!((v0 / exact_v - 1.0).abs() < 0.03, "raw volume {v0} vs {exact_v}");
        assert!((a / exact_a - 1.0).abs() < 0.05, "area {a} vs {exact_a}");
        // Every vertex near the sphere.
        for p in m.positions.as_chunks::<3>().0 {
            let d = (p[0] as f64).hypot(p[1] as f64).hypot(p[2] as f64);
            assert!((d - r).abs() < 0.5, "vertex at radius {d}");
        }
    }

    #[test]
    fn binary_sphere_closes_too() {
        // Centres in or out: node values land exactly on the level all over the surface.
        let grid = Grid::new([-12.0; 3], [12.0; 3], 1.0);
        let density: Vec<f32> = (0..grid.elements())
            .map(|e| {
                let c = grid.element_center(e);
                if (c[0] * c[0] + c[1] * c[1] + c[2] * c[2]).sqrt() <= 10.0 { 1.0 } else { 0.0 }
            })
            .collect();
        let exact = 4.0 / 3.0 * PI * 1000.0;
        for passes in [0, 12] {
            let m = surface(&grid, &density, 0.5, passes);
            assert!(is_closed(&m) && is_manifold(&m), "{passes} passes");
            assert_eq!(euler(&m), 2);
            let v = volume(&m);
            assert!((v / exact - 1.0).abs() < 0.05, "{passes} passes: volume {v} vs {exact}");
        }
    }

    #[test]
    fn torus_has_genus_one() {
        let (big, small) = (12.0, 4.0);
        let grid = Grid::new([-18.0, -18.0, -6.0], [18.0, 18.0, 6.0], 0.75);
        let density = field(&grid, move |p| ((p[0].hypot(p[1]) - big).hypot(p[2])) - small);
        let m = surface(&grid, &density, 0.5, 12);
        assert!(is_closed(&m) && is_manifold(&m));
        assert_eq!(euler(&m), 0);
        let exact = 2.0 * PI * PI * big * small * small;
        let v = volume(&m);
        assert!((v / exact - 1.0).abs() < 0.03, "torus volume {v} vs {exact}");
    }

    #[test]
    fn solid_touching_the_walls_is_capped_on_them() {
        // Everything solid: the surface is the box itself, and smoothing keeps it so.
        let grid = Grid::new([1.0, 2.0, 3.0], [9.0, 8.0, 7.0], 1.0);
        let full = vec![1.0f32; grid.elements()];
        let m = surface(&grid, &full, 0.5, 12);
        assert!(is_closed(&m) && is_manifold(&m));
        assert!((volume(&m) - 8.0 * 6.0 * 4.0).abs() < 1e-3, "{}", volume(&m));
        assert_eq!(bounds(&m), ([1.0, 2.0, 3.0], [9.0, 8.0, 7.0]));
        // A cylinder through the box, cut by both end walls, and a ball half out of a wall.
        let grid = Grid::new([0.0; 3], [30.0, 20.0, 20.0], 1.0);
        let density = field(&grid, |p: [f64; 3]| {
            let rod = (p[1] - 10.0).hypot(p[2] - 10.0) - 4.0;
            let ball = ((p[0] - 15.0).hypot(p[1] - 10.0).hypot(p[2])) - 6.0;
            rod.min(ball)
        });
        let raw = surface(&grid, &density, 0.5, 0);
        let m = surface(&grid, &density, 0.5, 12);
        for m in [&raw, &m] {
            assert!(is_closed(m) && is_manifold(m));
            assert_eq!(euler(m), 2);
            let (lo, hi) = bounds(m);
            assert!(lo.iter().all(|&x| x >= 0.0) && hi[0] <= 30.0 && hi[1] <= 20.0 && hi[2] <= 20.0, "{lo:?} {hi:?}");
            assert_eq!((lo[0], hi[0], lo[2]), (0.0, 30.0, 0.0));
        }
        // The rod's end caps are flat discs on the walls: area about pi 4^2 each.
        let on_wall = |m: &Mesh, x: f32| {
            m.indices.as_chunks::<3>().0.iter().filter(|t| t.iter().all(|&v| m.positions[3 * v as usize] == x)).count()
        };
        assert!(on_wall(&m, 0.0) > 0 && on_wall(&m, 30.0) > 0);
        // Apart: the rod's axis is 10 mm above the wall, the ball's radius 6 mm.
        let exact = PI * 16.0 * 30.0 + 2.0 / 3.0 * PI * 216.0;
        let v = volume(&m);
        assert!((v / exact - 1.0).abs() < 0.03, "{v} vs {exact}");
    }

    #[test]
    fn islands_are_dropped_and_counted() {
        let grid = Grid::new([0.0; 3], [40.0, 30.0, 30.0], 1.0);
        // The smallest speck that survives the 0.5 level (2 × 2 × 2 voxels) surfaces as 144
        // triangles, 1.3 % of a 10 mm ball's: the ball is 13 mm (about 19 000 triangles), so
        // the speck sits clearly under the 1 % line.
        let mut density = field(&grid, sphere([15.0, 15.0, 15.0], 13.0));
        // A 2 × 2 × 2 speck far from it.
        for (i, j, k) in [(34, 4, 4), (35, 4, 4), (34, 5, 4), (35, 5, 4), (34, 4, 5), (35, 4, 5), (34, 5, 5), (35, 5, 5)] {
            density[grid.element(i, j, k)] = 1.0;
        }
        let (m, report) = surface_report(&grid, &density, 0.5, 4);
        assert_eq!((report.shells, report.islands), (1, 1), "{report:?}");
        assert!(report.island_triangles > 0);
        assert!(is_closed(&m) && is_manifold(&m));
        let (_, hi) = bounds(&m);
        assert!(hi[0] < 30.0, "{hi:?}");
        // A hollow ball keeps both shells: the cavity is no island.
        let hollow = field(&grid, |p| {
            let d = sphere([15.0, 15.0, 15.0], 10.0)(p);
            d.max(-(d + 4.0))
        });
        let (m, report) = surface_report(&grid, &hollow, 0.5, 4);
        assert_eq!((report.shells, report.islands), (2, 0), "{report:?}");
        assert_eq!(euler(&m), 4);
        let exact = 4.0 / 3.0 * PI * (1000.0 - 216.0);
        assert!((volume(&m) / exact - 1.0).abs() < 0.04, "{}", volume(&m));
    }

    #[test]
    fn noise_stays_closed_and_manifold() {
        // Every ambiguous pattern there is: random densities, and random solids and voids.
        let grid = Grid::new([0.0; 3], [23.0, 19.0, 17.0], 1.0);
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut random = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed >> 40) as f32 / (1u64 << 24) as f32
        };
        let smooth_noise: Vec<f32> = (0..grid.elements()).map(|_| random()).collect();
        let binary: Vec<f32> = (0..grid.elements()).map(|_| if random() < 0.45 { 1.0 } else { 0.0 }).collect();
        for (density, level) in [(&smooth_noise, 0.5), (&smooth_noise, 0.3), (&binary, 0.5), (&binary, 0.25), (&binary, 0.75)] {
            for passes in [0, 3] {
                let (m, report) = surface_report(&grid, density, level, passes);
                assert!(!m.indices.is_empty(), "level {level}");
                assert!(is_closed(&m) && is_manifold(&m), "level {level}, {passes} passes, {report:?}");
                assert!(volume(&m) > 0.0);
                // Every vertex used.
                let mut used = vec![false; m.positions.len() / 3];
                m.indices.iter().for_each(|&v| used[v as usize] = true);
                assert!(used.iter().all(|&u| u));
            }
        }
    }

    #[test]
    fn stress_follows_the_elements() {
        let grid = Grid::new([0.0; 3], [20.0, 10.0, 10.0], 1.0);
        let density = field(&grid, |p: [f64; 3]| (p[1] - 5.0).abs().max((p[2] - 5.0).abs()) - 3.0);
        let mut m = surface(&grid, &density, 0.5, 4);
        // Stress rising along x where there is material, none in the voids.
        let stress: Vec<f64> = (0..grid.elements()).map(|e| if density[e] > 0.0 { grid.element_center(e)[0] } else { 0.0 }).collect();
        carry_stress(&grid, &mut m, &stress);
        assert_eq!(m.stress.len(), m.positions.len() / 3);
        for (p, &s) in m.positions.as_chunks::<3>().0.iter().zip(&m.stress) {
            assert!((s - p[0]).abs() < 1.6, "stress {s} at x {}", p[0]);
        }
        carry_stress(&grid, &mut m, &stress[1..]);
        assert!(m.stress.is_empty());
    }

    #[test]
    fn bad_input_gives_an_empty_mesh() {
        let grid = Grid::new([0.0; 3], [4.0; 3], 1.0);
        let d = vec![1.0f32; grid.elements()];
        assert!(surface(&grid, &d[1..], 0.5, 2).indices.is_empty());
        assert!(surface(&grid, &d, f32::NAN, 2).indices.is_empty());
        assert!(surface(&Grid { h: 0.0, ..grid }, &d, 0.5, 2).indices.is_empty());
        assert!(surface(&Grid { n: [0, 4, 4], ..grid }, &[], 0.5, 2).indices.is_empty());
        assert!(surface(&Grid { n: [usize::MAX, 2, 2], ..grid }, &d, 0.5, 2).indices.is_empty());
        let nan = vec![f32::NAN; grid.elements()];
        assert!(surface(&grid, &nan, 0.5, 2).indices.is_empty());
        assert!(surface(&grid, &vec![0.0; grid.elements()], 0.5, 2).indices.is_empty());
        assert!(!is_closed(&Mesh::default()));
        assert!(!is_closed(&Mesh { positions: vec![0.0; 9], indices: vec![0, 1, 7], stress: vec![] }));
        assert_eq!(volume(&Mesh { positions: vec![0.0; 9], indices: vec![0, 1, 7], stress: vec![] }), 0.0);
    }

    #[test]
    fn large_field_is_fast() {
        // 128 × 64 × 64 voxels of a perforated beam: meshed and smoothed 12 times.
        let grid = Grid::new([0.0; 3], [128.0, 64.0, 64.0], 1.0);
        let density: Vec<f32> = (0..grid.elements())
            .into_par_iter()
            .map(|e| {
                let p = grid.element_center(e);
                let g = (p[0] * 0.21).sin() * (p[1] * 0.23).cos() + (p[1] * 0.21).sin() * (p[2] * 0.23).cos() + (p[2] * 0.21).sin() * (p[0] * 0.23).cos();
                (0.5 + 0.8 * g).clamp(0.0, 1.0) as f32
            })
            .collect();
        let t = Instant::now();
        let (m, report) = surface_report(&grid, &density, 0.5, 12);
        let s = t.elapsed().as_secs_f64();
        eprintln!("128x64x64 gyroid-like: {} vertices, {} triangles, {report:?}, {s:.3} s", m.positions.len() / 3, m.indices.len() / 3);
        assert!(is_closed(&m));
        if !cfg!(debug_assertions) {
            assert!(s < 2.0, "{s} s");
        }
    }
}
