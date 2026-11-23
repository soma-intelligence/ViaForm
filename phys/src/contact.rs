//! Collision detection with parry3d-f64 (E-2: collision geometry only): candidate pairs from a
//! fixed filter, a bounding-box test each step, then parry's contact manifolds (polygon
//! clipping for boxes and convex hulls; a plane against a polyhedron takes every vertex within
//! the margin, so a box gets its four corners and a 12-sided prism its twelve). Pairs are
//! visited in a fixed order (geometry index pairs, ascending) and points in parry's order, so
//! the contact list is deterministic (E-11).

use parry3d_f64::query::{ContactManifold, DefaultQueryDispatcher, PersistentQueryDispatcher};
use parry3d_f64::bounding_volume::BoundingVolume;
use viaform_kin::Iso3;

use crate::dynamics::Ws;
use crate::model::PhysModel;
use crate::spatial::V3;

/// One contact point.
#[derive(Clone, Copy, Debug)]
pub struct Contact {
    pub g1: usize,
    pub g2: usize,
    pub b1: usize,
    pub b2: usize,
    /// World contact point (midway between the two surfaces).
    pub p: V3,
    /// World unit normal from shape 1 to shape 2.
    pub n: V3,
    /// Signed distance (negative: penetration), m.
    pub dist: f64,
    /// Combined friction coefficient.
    pub mu: f64,
}

/// Candidate pairs and per-pair manifold caches.
pub struct Collider {
    pub pairs: Vec<(usize, usize)>,
    manifolds: Vec<Vec<ContactManifold<(), ()>>>,
    aabbs: Vec<parry3d_f64::bounding_volume::Aabb>,
    poses: Vec<Iso3>,
}

impl Clone for Collider {
    fn clone(&self) -> Self {
        Collider { pairs: self.pairs.clone(), manifolds: vec![vec![]; self.pairs.len()], aabbs: self.aabbs.clone(), poses: self.poses.clone() }
    }
}

impl Collider {
    /// The pairs that may ever touch: different links, not both fixed to the world, not a
    /// parent and its child, and within one articulation only when self collision is on.
    pub fn new(m: &PhysModel) -> Self {
        let fixed = |l: usize| m.support[l].is_empty();
        let root = |l: usize| if l == 0 { usize::MAX } else { m.joints[l - 1].root };
        let mut pairs = vec![];
        for i in 0..m.geoms.len() {
            for j in i + 1..m.geoms.len() {
                let (a, b) = (m.geoms[i].link, m.geoms[j].link);
                if a == b || (fixed(a) && fixed(b)) {
                    continue;
                }
                // A real joint between them (a free body's floating joint to the world is not one).
                let joined = |child: usize, parent: usize| child > 0 && m.joints[child - 1].parent == parent && m.joints[child - 1].kind != viaform_kin::model::JointKind::Floating;
                let adjacent = joined(b, a) || joined(a, b);
                if adjacent {
                    continue;
                }
                if !fixed(a) && !fixed(b) && root(a) == root(b) && !m.self_collision {
                    continue;
                }
                pairs.push((i, j));
            }
        }
        let n = pairs.len();
        Collider { pairs, manifolds: vec![vec![]; n], aabbs: vec![], poses: vec![] }
    }

    /// All contact points at the link poses in `ws`, into `out` (cleared first).
    pub fn detect(&mut self, m: &PhysModel, ws: &Ws, out: &mut Vec<Contact>) {
        out.clear();
        if self.pairs.is_empty() {
            return;
        }
        let margin = m.contact.margin;
        self.poses.clear();
        self.aabbs.clear();
        for g in &m.geoms {
            let p = ws.poses[g.link] * g.shape_pose;
            self.aabbs.push(g.shape.compute_aabb(&p).loosened(margin));
            self.poses.push(p);
        }
        let dispatcher = DefaultQueryDispatcher;
        for (k, &(i, j)) in self.pairs.iter().enumerate() {
            if !intersects(&self.aabbs[i], &self.aabbs[j]) {
                self.manifolds[k].clear();
                continue;
            }
            let (gi, gj) = (&m.geoms[i], &m.geoms[j]);
            let (p1, p2) = (self.poses[i], self.poses[j]);
            let mu = (gi.friction * gj.friction).sqrt();
            // A plane against a polyhedron: every vertex within the margin is a point.
            let plane = |g: &crate::model::Geom| match g.spec {
                crate::model::ShapeSpec::Plane { normal } => Some(V3::new(normal[0], normal[1], normal[2]).normalize()),
                _ => None,
            };
            let vertex_case = match (plane(gi), plane(gj)) {
                (Some(n), None) if !gj.vertices.is_empty() => Some((n, p1, j, 1.0)),
                (None, Some(n)) if !gi.vertices.is_empty() => Some((n, p2, i, -1.0)),
                _ => None,
            };
            if let Some((n_local, plane_pose, other, sign)) = vertex_case {
                self.manifolds[k].clear();
                let n = plane_pose.rotation * n_local;
                let o = plane_pose.translation.vector;
                let link_pose = ws.poses[m.geoms[other].link];
                for v in &m.geoms[other].vertices {
                    let w = link_pose.rotation * v + link_pose.translation.vector;
                    let d = n.dot(&(w - o));
                    if d <= margin {
                        out.push(Contact { g1: i, g2: j, b1: gi.link, b2: gj.link, p: w - 0.5 * d * n, n: sign * n, dist: d, mu });
                    }
                }
                continue;
            }
            let pos12 = p1.inv_mul(&p2);
            let mut ws_none = None;
            let manifolds = &mut self.manifolds[k];
            if dispatcher.contact_manifolds(&pos12, gi.shape.as_ref(), gj.shape.as_ref(), margin, manifolds, &mut ws_none).is_err() {
                continue;
            }
            for mf in manifolds.iter() {
                let (sp1, sp2) = (mf.subshape_pos1.map(|s| p1 * s).unwrap_or(p1), mf.subshape_pos2.map(|s| p2 * s).unwrap_or(p2));
                let n = sp1.rotation * mf.local_n1;
                let nn = n.norm();
                if !(nn > 1e-12) {
                    continue;
                }
                let n = n / nn;
                for c in &mf.points {
                    if c.dist > margin {
                        continue;
                    }
                    let a = (sp1 * c.local_p1).coords;
                    let b = (sp2 * c.local_p2).coords;
                    out.push(Contact { g1: i, g2: j, b1: gi.link, b2: gj.link, p: 0.5 * (a + b), n, dist: c.dist, mu });
                }
            }
        }
    }
}

fn intersects(a: &parry3d_f64::bounding_volume::Aabb, b: &parry3d_f64::bounding_volume::Aabb) -> bool {
    (0..3).all(|k| a.mins[k] <= b.maxs[k] && b.mins[k] <= a.maxs[k])
}

/// A deterministic tangent basis for a unit normal.
pub fn tangents(n: &V3) -> (V3, V3) {
    let a = if n.x.abs() < 0.57 { V3::x() } else if n.y.abs() < 0.57 { V3::y() } else { V3::z() };
    let t1 = (a - n * n.dot(&a)).normalize();
    let t2 = n.cross(&t1);
    (t1, t2)
}
