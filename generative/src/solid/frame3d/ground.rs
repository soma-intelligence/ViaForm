//! The ground structure: lattice nodes through the design space, a node at the centre of every
//! support and load region, and candidate beams between near nodes, clear of the keep-out regions,
//! tied into groups by the study's mirror planes.

use std::collections::HashMap;

use super::beam::{V3, dist, dot, norm, scale, sub};
use crate::solid::grid::unit;
use crate::solid::{Region, Study};

/// Candidate beams join nodes closer than this many spacings: cube edges, face and body diagonals.
const REACH: f64 = 1.8;

pub struct Ground {
    pub nodes: Vec<V3>,
    pub beams: Vec<[usize; 2]>,
    /// Per beam: distance to the nearest keep-out region over its mirror images, mm.
    pub clearance: Vec<f64>,
    /// Per node: likewise.
    pub node_clearance: Vec<f64>,
    /// Per beam: its symmetry group, `0..groups`.
    pub group: Vec<usize>,
    pub groups: usize,
    /// Lattice spacing, mm.
    pub spacing: f64,
}

/// Mirror images of a point across the study's symmetry planes, identity first.
pub struct Mirrors {
    masks: Vec<u8>,
    min: V3,
    max: V3,
}

impl Mirrors {
    pub fn new(study: &Study) -> Self {
        let masks = (0..8u8).filter(|m| (0..3).all(|a| m & (1 << a) == 0 || study.symmetry[a])).collect();
        Self { masks, min: study.min, max: study.max }
    }

    pub fn images(&self, p: V3) -> impl Iterator<Item = V3> + '_ {
        self.masks.iter().map(move |&m| std::array::from_fn(|a| if m & (1 << a) != 0 { self.min[a] + self.max[a] - p[a] } else { p[a] }))
    }
}

/// Distance from `p` to a region, zero inside.
pub fn point_distance(r: &Region, p: V3) -> f64 {
    match r.hull() {
        Region::Tube { .. } => unreachable!("a hull is never a tube"),
        Region::Box { min, max } => norm(std::array::from_fn(|a| (min[a] - p[a]).max(p[a] - max[a]).max(0.0))),
        Region::Sphere { center, radius } => (dist(p, center) - radius).max(0.0),
        Region::Cylinder { base, axis, radius, length } => {
            let a = unit(axis);
            let d = sub(p, base);
            let t = dot(d, a);
            let radial = norm(sub(d, scale(a, t)));
            let dt = (-t).max(t - length).max(0.0);
            let dr = (radial - radius).max(0.0);
            (dt * dt + dr * dr).sqrt()
        }
    }
}

/// Distance from the segment `a`-`b` to a region: the region is convex, so the distance along the
/// segment is too, and a golden-section search finds its least.
pub fn segment_distance(r: &Region, a: V3, b: V3) -> f64 {
    let at = |t: f64| point_distance(r, std::array::from_fn(|i| a[i] + t * (b[i] - a[i])));
    let g = (5f64.sqrt() - 1.0) / 2.0;
    let (mut lo, mut hi) = (0.0, 1.0);
    let mut c = hi - g * (hi - lo);
    let mut d = lo + g * (hi - lo);
    let (mut fc, mut fd) = (at(c), at(d));
    let mut best = at(0.0).min(at(1.0)).min(fc).min(fd);
    for _ in 0..60 {
        if best == 0.0 {
            break;
        }
        if fc <= fd {
            hi = d;
            d = c;
            fd = fc;
            c = hi - g * (hi - lo);
            fc = at(c);
            best = best.min(fc);
        } else {
            lo = c;
            c = d;
            fc = fd;
            d = lo + g * (hi - lo);
            fd = at(d);
            best = best.min(fd);
        }
    }
    best
}

/// Least distance from `p` to the keep-out regions (infinite when there are none).
fn point_clearance(keep_out: &[Region], p: V3) -> f64 {
    keep_out.iter().map(|r| point_distance(r, p)).fold(f64::INFINITY, f64::min)
}

/// Builds the ground structure; `anchors` are the centres of the support and load regions.
pub fn build(study: &Study, anchors: &[V3]) -> Result<Ground, String> {
    let size: V3 = std::array::from_fn(|a| study.max[a] - study.min[a]);
    let longest = size.iter().copied().fold(0.0, f64::max);
    let s = (study.voxel * 4.0).max(longest / 9.0);
    let cells = size.map(|l| ((l / s - 1e-9).ceil() as usize).max(1));
    let mirrors = Mirrors::new(study);

    let mut nodes = Vec::with_capacity((cells[0] + 1) * (cells[1] + 1) * (cells[2] + 1) + anchors.len() * 8);
    for k in 0..=cells[2] {
        for j in 0..=cells[1] {
            for i in 0..=cells[0] {
                let ijk = [i, j, k];
                nodes.push(std::array::from_fn(|a| study.min[a] + size[a] * ijk[a] as f64 / cells[a] as f64));
            }
        }
    }
    for &c in anchors {
        let c: V3 = std::array::from_fn(|a| c[a].clamp(study.min[a], study.max[a]));
        for p in mirrors.images(c) {
            if nodes.iter().all(|&q| dist(q, p) >= 0.5 * s) {
                nodes.push(p);
            }
        }
    }

    // Keep-out: a node or beam whose mirror images all keep half the narrowest member away.
    let margin = 0.5 * study.min_member;
    let keep_out = &study.keep_out;
    let node_clear: Vec<f64> = nodes
        .iter()
        .map(|&p| mirrors.images(p).map(|q| point_clearance(keep_out, q)).fold(f64::INFINITY, f64::min))
        .collect();
    let alive: Vec<usize> = (0..nodes.len()).filter(|&v| node_clear[v] >= margin).collect();

    // Candidate beams: near pairs, skipping any that runs through a third node.
    let reach = REACH * s;
    let mut near: Vec<Vec<(usize, f64)>> = vec![Vec::new(); nodes.len()];
    for (x, &a) in alive.iter().enumerate() {
        for &b in &alive[x + 1..] {
            let l = dist(nodes[a], nodes[b]);
            if l <= reach {
                near[a].push((b, l));
                near[b].push((a, l));
            }
        }
    }
    let mut beams = Vec::new();
    let mut clearance = Vec::new();
    for &a in &alive {
        for &(b, l) in &near[a] {
            if b < a {
                continue;
            }
            let ab = sub(nodes[b], nodes[a]);
            let through = near[a].iter().any(|&(c, lc)| {
                if c == b || lc >= l {
                    return false;
                }
                let ac = sub(nodes[c], nodes[a]);
                let t = dot(ac, ab) / (l * l);
                t > 1e-6 && t < 1.0 - 1e-6 && norm(sub(ac, scale(ab, t))) < 0.1 * s
            });
            if through {
                continue;
            }
            let (pa, pb) = (nodes[a], nodes[b]);
            let clear = mirrors
                .images(pa)
                .zip(mirrors.images(pb))
                .map(|(qa, qb)| keep_out.iter().map(|r| segment_distance(r, qa, qb)).fold(f64::INFINITY, f64::min))
                .fold(f64::INFINITY, f64::min);
            if clear < margin {
                continue;
            }
            beams.push([a, b]);
            clearance.push(clear);
        }
    }
    if beams.is_empty() {
        return Err("no candidate beam fits the design space outside the keep-out regions".into());
    }

    // Drop nodes no beam reaches.
    let mut index = vec![usize::MAX; nodes.len()];
    let mut kept_nodes = Vec::new();
    let mut kept_clear = Vec::new();
    for b in &mut beams {
        for v in b.iter_mut() {
            if index[*v] == usize::MAX {
                index[*v] = kept_nodes.len();
                kept_nodes.push(nodes[*v]);
                kept_clear.push(node_clear[*v]);
            }
            *v = index[*v];
        }
    }
    let nodes = kept_nodes;

    // Symmetry groups: a beam and its mirror images share one diameter.
    let lookup = Lookup::new(&nodes, 1e-6 * s);
    let at: HashMap<[usize; 2], usize> = beams.iter().enumerate().map(|(e, &[a, b])| ([a.min(b), a.max(b)], e)).collect();
    let mut uf: Vec<usize> = (0..beams.len()).collect();
    fn root(uf: &mut [usize], mut x: usize) -> usize {
        while uf[x] != x {
            uf[x] = uf[uf[x]];
            x = uf[x];
        }
        x
    }
    for (e, &[a, b]) in beams.iter().enumerate() {
        for (qa, qb) in mirrors.images(nodes[a]).zip(mirrors.images(nodes[b])).skip(1) {
            if let (Some(ma), Some(mb)) = (lookup.find(qa), lookup.find(qb)) {
                if let Some(&img) = at.get(&[ma.min(mb), ma.max(mb)]) {
                    let (ra, rb) = (root(&mut uf, e), root(&mut uf, img));
                    if ra != rb {
                        uf[ra.max(rb)] = ra.min(rb);
                    }
                }
            }
        }
    }
    let mut id = vec![usize::MAX; beams.len()];
    let mut groups = 0;
    let mut group = Vec::with_capacity(beams.len());
    for e in 0..beams.len() {
        let r = root(&mut uf, e);
        if id[r] == usize::MAX {
            id[r] = groups;
            groups += 1;
        }
        group.push(id[r]);
    }
    Ok(Ground { nodes, beams, clearance, node_clearance: kept_clear, group, groups, spacing: s })
}

/// Finds a node at a position, within a tolerance (nodes sorted along x).
struct Lookup {
    order: Vec<(f64, usize)>,
    pos: Vec<V3>,
    tol: f64,
}

impl Lookup {
    fn new(nodes: &[V3], tol: f64) -> Self {
        let mut order: Vec<(f64, usize)> = nodes.iter().enumerate().map(|(v, p)| (p[0], v)).collect();
        order.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)));
        Self { order, pos: nodes.to_vec(), tol }
    }

    fn find(&self, p: V3) -> Option<usize> {
        let from = self.order.partition_point(|&(x, _)| x < p[0] - self.tol);
        self.order[from..].iter().take_while(|&&(x, _)| x <= p[0] + self.tol).map(|&(_, v)| v).find(|&v| dist(self.pos[v], p) <= self.tol)
    }
}
