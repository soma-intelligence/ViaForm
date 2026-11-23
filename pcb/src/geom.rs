//! 2D geometry on integer nanometre coordinates.
//!
//! Every stored coordinate is an `i64` count of nanometres. Floating point appears only inside
//! distance computations (IEEE f64, no fused operations), whose results are compared against
//! integer rules, so the same input always gives the same answer.

use i_overlay::core::fill_rule::FillRule;
use i_overlay::core::overlay_rule::OverlayRule;
use i_overlay::core::single::SingleIntOverlay;
use i_overlay::i_float::int::point::IntPoint;
use serde::{Deserialize, Serialize};

/// A length in nanometres.
pub type Nm = i64;

pub const NM_PER_MM: i64 = 1_000_000;

/// Millimetres (as the UI speaks) to nanometres, rounded to the nearest nanometre.
pub fn mm(v: f64) -> Nm {
    (v * NM_PER_MM as f64).round() as Nm
}

/// Nanometres to millimetres.
pub fn to_mm(v: Nm) -> f64 {
    v as f64 / NM_PER_MM as f64
}

/// Angles are stored in millidegrees, normalised to `0..360_000`.
pub type MilliDeg = i64;

pub fn mdeg(deg: f64) -> MilliDeg {
    norm_mdeg((deg * 1000.0).round() as i64)
}

pub fn norm_mdeg(a: i64) -> MilliDeg {
    a.rem_euclid(360_000)
}

pub fn to_deg(a: MilliDeg) -> f64 {
    a as f64 / 1000.0
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Hash, Debug, Default, PartialOrd, Ord)]
pub struct Pt {
    pub x: Nm,
    pub y: Nm,
}

impl Pt {
    pub const fn new(x: Nm, y: Nm) -> Self {
        Pt { x, y }
    }
    pub fn mm(x: f64, y: f64) -> Self {
        Pt { x: mm(x), y: mm(y) }
    }
    pub fn add(self, o: Pt) -> Pt {
        Pt::new(self.x + o.x, self.y + o.y)
    }
    pub fn sub(self, o: Pt) -> Pt {
        Pt::new(self.x - o.x, self.y - o.y)
    }
    pub fn dist(self, o: Pt) -> f64 {
        let dx = (self.x - o.x) as f64;
        let dy = (self.y - o.y) as f64;
        (dx * dx + dy * dy).sqrt()
    }
    /// Rotation on the board, whose y axis points down: a positive angle turns counterclockwise
    /// on screen (the KiCad convention), so the formula is the math rotation by minus the angle.
    pub fn rotate_board(self, a: MilliDeg) -> Pt {
        rotate(self, norm_mdeg(-a))
    }
    /// Plain math rotation (counterclockwise with y up), used on the schematic sheet.
    pub fn rotate_math(self, a: MilliDeg) -> Pt {
        rotate(self, a)
    }
}

/// Exact for multiples of 90 degrees, rounded to the nanometre otherwise.
fn rotate(p: Pt, a: MilliDeg) -> Pt {
    match norm_mdeg(a) {
        0 => p,
        90_000 => Pt::new(-p.y, p.x),
        180_000 => Pt::new(-p.x, -p.y),
        270_000 => Pt::new(p.y, -p.x),
        a => {
            let t = (a as f64 / 1000.0).to_radians();
            let (s, c) = t.sin_cos();
            let x = p.x as f64 * c - p.y as f64 * s;
            let y = p.x as f64 * s + p.y as f64 * c;
            Pt::new(x.round() as Nm, y.round() as Nm)
        }
    }
}

/// Axis-aligned box.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Aabb {
    pub min: Pt,
    pub max: Pt,
}

impl Aabb {
    pub fn of(points: &[Pt]) -> Aabb {
        let mut b = Aabb { min: Pt::new(i64::MAX, i64::MAX), max: Pt::new(i64::MIN, i64::MIN) };
        for p in points {
            b.min.x = b.min.x.min(p.x);
            b.min.y = b.min.y.min(p.y);
            b.max.x = b.max.x.max(p.x);
            b.max.y = b.max.y.max(p.y);
        }
        b
    }
    pub fn grow(self, d: Nm) -> Aabb {
        Aabb { min: Pt::new(self.min.x - d, self.min.y - d), max: Pt::new(self.max.x + d, self.max.y + d) }
    }
}

fn seg_point_dist(p: Pt, a: Pt, b: Pt) -> f64 {
    let (px, py) = (p.x as f64, p.y as f64);
    let (ax, ay) = (a.x as f64, a.y as f64);
    let (dx, dy) = ((b.x - a.x) as f64, (b.y - a.y) as f64);
    let l = dx * dx + dy * dy;
    let t = if l > 0.0 { (((px - ax) * dx + (py - ay) * dy) / l).clamp(0.0, 1.0) } else { 0.0 };
    let (qx, qy) = (ax + t * dx, ay + t * dy);
    ((px - qx) * (px - qx) + (py - qy) * (py - qy)).sqrt()
}

fn orient(a: Pt, b: Pt, c: Pt) -> i128 {
    let v = (b.x - a.x) as i128 * (c.y - a.y) as i128 - (b.y - a.y) as i128 * (c.x - a.x) as i128;
    v.signum()
}

fn on_seg(a: Pt, b: Pt, p: Pt) -> bool {
    p.x >= a.x.min(b.x) && p.x <= a.x.max(b.x) && p.y >= a.y.min(b.y) && p.y <= a.y.max(b.y)
}

/// Exact integer segment intersection test (touching counts).
pub fn segs_intersect(a: Pt, b: Pt, c: Pt, d: Pt) -> bool {
    let (o1, o2, o3, o4) = (orient(a, b, c), orient(a, b, d), orient(c, d, a), orient(c, d, b));
    if o1 != o2 && o3 != o4 {
        return true;
    }
    (o1 == 0 && on_seg(a, b, c)) || (o2 == 0 && on_seg(a, b, d)) || (o3 == 0 && on_seg(c, d, a)) || (o4 == 0 && on_seg(c, d, b))
}

pub fn seg_seg_dist(a: Pt, b: Pt, c: Pt, d: Pt) -> f64 {
    if segs_intersect(a, b, c, d) {
        return 0.0;
    }
    seg_point_dist(a, c, d).min(seg_point_dist(b, c, d)).min(seg_point_dist(c, a, b)).min(seg_point_dist(d, a, b))
}

/// Even-odd point in polygon (boundary counts as inside).
pub fn point_in_ring(p: Pt, ring: &[Pt]) -> bool {
    let n = ring.len();
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        let (a, b) = (ring[i], ring[j]);
        if orient(a, b, p) == 0 && on_seg(a, b, p) {
            return true;
        }
        if (a.y > p.y) != (b.y > p.y) {
            // x of the edge at p.y, compared exactly with i128 cross multiplication.
            let lhs = (p.x - a.x) as i128 * (b.y - a.y) as i128;
            let rhs = (b.x - a.x) as i128 * (p.y - a.y) as i128;
            let left = if b.y > a.y { lhs < rhs } else { lhs > rhs };
            if left {
                inside = !inside;
            }
        }
        j = i;
    }
    inside
}

/// A copper or edge primitive: a point, a segment or a polygon with holes, swept by a radius.
/// Pads, tracks, vias, zone fills and holes all reduce to this.
#[derive(Clone, Debug, PartialEq)]
pub enum Prim {
    /// A circle (point swept by `r`) or a capsule (segment swept by `r`).
    Seg { a: Pt, b: Pt, r: Nm },
    /// A polygon (outer ring, optional holes), swept by `r` (0 for sharp corners).
    Poly { outer: Vec<Pt>, holes: Vec<Vec<Pt>>, r: Nm },
}

impl Prim {
    pub fn circle(c: Pt, r: Nm) -> Prim {
        Prim::Seg { a: c, b: c, r }
    }
    pub fn aabb(&self) -> Aabb {
        match self {
            Prim::Seg { a, b, r } => Aabb::of(&[*a, *b]).grow(*r),
            Prim::Poly { outer, r, .. } => Aabb::of(outer).grow(*r),
        }
    }
    fn radius(&self) -> Nm {
        match self {
            Prim::Seg { r, .. } | Prim::Poly { r, .. } => *r,
        }
    }
    fn edges(&self) -> Vec<(Pt, Pt)> {
        match self {
            Prim::Seg { a, b, .. } => vec![(*a, *b)],
            Prim::Poly { outer, holes, .. } => {
                let mut e = ring_edges(outer);
                for h in holes {
                    e.extend(ring_edges(h));
                }
                e
            }
        }
    }
    fn contains_core(&self, p: Pt) -> bool {
        match self {
            Prim::Seg { .. } => false,
            Prim::Poly { outer, holes, .. } => point_in_ring(p, outer) && !holes.iter().any(|h| point_in_ring(p, h) && !on_ring(p, h)),
        }
    }
    fn a_point(&self) -> Pt {
        match self {
            Prim::Seg { a, .. } => *a,
            Prim::Poly { outer, .. } => outer[0],
        }
    }
    /// Distance between the two swept cores, before radii.
    fn core_dist(&self, o: &Prim) -> f64 {
        if self.contains_core(o.a_point()) || o.contains_core(self.a_point()) {
            return 0.0;
        }
        let (ea, eb) = (self.edges(), o.edges());
        let mut best = f64::INFINITY;
        for (a, b) in &ea {
            for (c, d) in &eb {
                let v = seg_seg_dist(*a, *b, *c, *d);
                if v < best {
                    best = v;
                    if best == 0.0 {
                        return 0.0;
                    }
                }
            }
        }
        best
    }
    /// Edge to edge gap between two primitives in nanometres; 0 when they touch or overlap.
    pub fn gap(&self, o: &Prim) -> f64 {
        (self.core_dist(o) - self.radius() as f64 - o.radius() as f64).max(0.0)
    }
    /// Signed version: negative when they overlap by more than touching.
    pub fn signed_gap(&self, o: &Prim) -> f64 {
        self.core_dist(o) - self.radius() as f64 - o.radius() as f64
    }
    /// Polygon approximation (outer ring plus holes), used for zone clearances and Gerber regions.
    pub fn to_polygon(&self, grow: Nm) -> Vec<Vec<Pt>> {
        match self {
            Prim::Seg { a, b, r } => vec![stadium(*a, *b, r + grow)],
            Prim::Poly { outer, holes, r } => {
                let rr = r + grow;
                if rr <= 0 {
                    let mut v = vec![outer.clone()];
                    v.extend(holes.iter().cloned());
                    return v;
                }
                // Minkowski sum of the ring with a disc: union of the ring and every edge stadium.
                let mut shapes: Vec<Vec<Vec<Pt>>> = vec![vec![outer.clone()]];
                for (p, q) in ring_edges(outer) {
                    shapes.push(vec![stadium(p, q, rr)]);
                }
                let u = union_all(&shapes);
                u.into_iter().next().unwrap_or_default()
            }
        }
    }
}

fn on_ring(p: Pt, ring: &[Pt]) -> bool {
    ring_edges(ring).iter().any(|(a, b)| orient(*a, *b, p) == 0 && on_seg(*a, *b, p))
}

pub fn ring_edges(r: &[Pt]) -> Vec<(Pt, Pt)> {
    let n = r.len();
    (0..n).map(|i| (r[i], r[(i + 1) % n])).collect()
}

/// Segments per full circle when arcs become polygons. Chord error at r = 1 mm is about 5 um.
pub const ARC_SEGMENTS: usize = 32;

/// Closed outline of a segment swept by a disc of radius `r` (a circle when a == b),
/// counterclockwise in math orientation, circumscribing the true shape.
pub fn stadium(a: Pt, b: Pt, r: Nm) -> Vec<Pt> {
    // Circumscribed: every edge stays at or outside the true radius, so clearances computed
    // from these polygons are never smaller than the rule (one extra nanometre for rounding).
    let rf = r as f64 / (std::f64::consts::PI / ARC_SEGMENTS as f64).cos() + 1.0;
    if a == b {
        return (0..ARC_SEGMENTS)
            .map(|i| {
                let t = (i as f64) * std::f64::consts::TAU / ARC_SEGMENTS as f64;
                Pt::new(a.x + (rf * t.cos()).round() as Nm, a.y + (rf * t.sin()).round() as Nm)
            })
            .collect();
    }
    let base = ((b.y - a.y) as f64).atan2((b.x - a.x) as f64);
    let half = ARC_SEGMENTS / 2;
    let mut out = Vec::with_capacity(ARC_SEGMENTS + 2);
    // Cap around b from -90 to +90 degrees relative to the direction, then around a.
    for (c, off) in [(b, -std::f64::consts::FRAC_PI_2), (a, std::f64::consts::FRAC_PI_2)] {
        for i in 0..=half {
            let t = base + off + (i as f64) * std::f64::consts::PI / half as f64;
            out.push(Pt::new(c.x + (rf * t.cos()).round() as Nm, c.y + (rf * t.sin()).round() as Nm));
        }
    }
    out
}

/// A rectangle of size (w, h) centred on `c`, turned by `rot` (board convention).
pub fn rect_ring(c: Pt, w: Nm, h: Nm, rot: MilliDeg) -> Vec<Pt> {
    let (hw, hh) = (w / 2, h / 2);
    [Pt::new(-hw, -hh), Pt::new(hw, -hh), Pt::new(hw, hh), Pt::new(-hw, hh)]
        .iter()
        .map(|p| c.add(p.rotate_board(rot)))
        .collect()
}

pub type Shape = Vec<Vec<Pt>>;

fn to_int(shape: &[Vec<Pt>]) -> Vec<Vec<IntPoint<i64>>> {
    shape.iter().map(|r| r.iter().map(|p| IntPoint::new(p.x, p.y)).collect()).collect()
}

fn from_int(shapes: Vec<Vec<Vec<IntPoint<i64>>>>) -> Vec<Shape> {
    shapes.into_iter().map(|s| s.into_iter().map(|r| r.into_iter().map(|p| Pt::new(p.x, p.y)).collect()).collect()).collect()
}

fn flatten(shapes: &[Shape]) -> Vec<Vec<IntPoint<i64>>> {
    shapes.iter().flat_map(|s| to_int(s)).collect()
}

/// Union of shapes (non-zero fill), through i_overlay's integer engine.
pub fn union_all(shapes: &[Shape]) -> Vec<Shape> {
    if shapes.is_empty() {
        return vec![];
    }
    let subj = flatten(shapes);
    let empty: Vec<Vec<IntPoint<i64>>> = vec![];
    from_int(subj.overlay(&empty, OverlayRule::Subject, FillRule::NonZero))
}

/// `a` minus `b`.
pub fn difference(a: &[Shape], b: &[Shape]) -> Vec<Shape> {
    let (sa, sb) = (flatten(a), flatten(b));
    from_int(sa.overlay(&sb, OverlayRule::Difference, FillRule::NonZero))
}

/// `a` intersected with `b`.
pub fn intersection(a: &[Shape], b: &[Shape]) -> Vec<Shape> {
    let (sa, sb) = (flatten(a), flatten(b));
    from_int(sa.overlay(&sb, OverlayRule::Intersect, FillRule::NonZero))
}

/// Area of a ring (signed, math orientation), in square nanometres as f64.
pub fn ring_area(r: &[Pt]) -> f64 {
    let mut s: i128 = 0;
    for (a, b) in ring_edges(r) {
        s += a.x as i128 * b.y as i128 - b.x as i128 * a.y as i128;
    }
    s as f64 / 2.0
}

pub fn shape_area(s: &Shape) -> f64 {
    let mut a = 0.0;
    for (i, r) in s.iter().enumerate() {
        if i == 0 { a += ring_area(r).abs() } else { a -= ring_area(r).abs() }
    }
    a
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mm_round_trip() {
        assert_eq!(mm(2.54), 2_540_000);
        assert_eq!(to_mm(mm(30.5)), 30.5);
        assert_eq!(mdeg(-90.0), 270_000);
    }

    #[test]
    fn board_rotation_turns_counterclockwise_on_screen() {
        // y down: +x turned by +90 degrees goes up the screen, to -y.
        let p = Pt::new(1000, 0).rotate_board(90_000);
        assert_eq!(p, Pt::new(0, -1000));
        assert_eq!(Pt::new(1000, 0).rotate_math(90_000), Pt::new(0, 1000));
    }

    #[test]
    fn gaps() {
        let a = Prim::circle(Pt::mm(0.0, 0.0), mm(0.5));
        let b = Prim::Seg { a: Pt::mm(2.0, -5.0), b: Pt::mm(2.0, 5.0), r: mm(0.25) };
        assert!((a.gap(&b) - mm(1.25) as f64).abs() < 1.0);
        let sq = Prim::Poly { outer: rect_ring(Pt::mm(0.0, 0.0), mm(4.0), mm(4.0), 0), holes: vec![], r: 0 };
        assert_eq!(sq.gap(&a), 0.0);
        let far = Prim::circle(Pt::mm(5.0, 0.0), mm(1.0));
        assert!((sq.gap(&far) - mm(2.0) as f64).abs() < 1.0);
    }

    #[test]
    fn booleans() {
        let a: Shape = vec![rect_ring(Pt::mm(0.0, 0.0), mm(10.0), mm(10.0), 0)];
        let b: Shape = vec![rect_ring(Pt::mm(5.0, 0.0), mm(10.0), mm(10.0), 0)];
        let u = union_all(&[a.clone(), b.clone()]);
        assert_eq!(u.len(), 1);
        assert!((shape_area(&u[0]) - 150e12).abs() < 1e6);
        let d = difference(&[a.clone()], &[b.clone()]);
        assert!((shape_area(&d[0]) - 50e12).abs() < 1e6);
        let i = intersection(&[a], &[b]);
        assert!((shape_area(&i[0]) - 50e12).abs() < 1e6);
    }
}
