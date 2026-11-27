//! Copper items as geometric primitives, and an R-tree over them (`rstar`).

use crate::geom::{rect_ring, Aabb, MilliDeg, Nm, Prim, Pt};
use crate::model::*;
use rstar::primitives::{GeomWithData, Rectangle};
use rstar::{RTree, AABB};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum ItemRef {
    /// Footprint index, pad index.
    Pad(usize, usize),
    Track(usize),
    Via(usize),
    /// Zone index, filled shape index.
    Zone(usize, usize),
}

#[derive(Clone, Debug)]
pub struct Item {
    pub what: ItemRef,
    /// Object id the UI knows (footprint, track, via, zone).
    pub object: Id,
    pub net: Option<Id>,
    pub layers: Vec<String>,
    pub prim: Prim,
}

impl Item {
    pub fn on(&self, layer: &str) -> bool {
        self.layers.iter().any(|l| l == layer)
    }
    pub fn shares_layer(&self, o: &Item) -> bool {
        self.layers.iter().any(|l| o.on(l))
    }
}

/// Primitive of a pad shape at `at`, turned by `rot` (board convention).
pub fn pad_prim(shape: PadShape, at: Pt, size: Pt, rot: MilliDeg) -> Prim {
    let (w, h) = (size.x, size.y);
    match shape {
        PadShape::Circle => Prim::circle(at, w.min(h) / 2),
        PadShape::Rect => Prim::Poly { outer: rect_ring(at, w, h, rot), holes: vec![], r: 0 },
        PadShape::Oval => {
            if w == h {
                return Prim::circle(at, w / 2);
            }
            let half = (w.max(h) - w.min(h)) / 2;
            let axis = if w > h { Pt::new(half, 0) } else { Pt::new(0, half) };
            let d = axis.rotate_board(rot);
            Prim::Seg { a: at.sub(d), b: at.add(d), r: w.min(h) / 2 }
        }
        PadShape::RoundRect => {
            let r = w.min(h) / 4;
            Prim::Poly { outer: rect_ring(at, w - 2 * r, h - 2 * r, rot), holes: vec![], r }
        }
    }
}

/// All copper on the board, in a fixed order: pads, tracks, vias, zone fills.
pub fn collect(p: &Project) -> Vec<Item> {
    let b = &p.board;
    let mut v = vec![];
    for (fi, f) in b.footprints.iter().enumerate() {
        for (pi, pad) in f.pads.iter().enumerate() {
            let layers: Vec<String> = f.pad_layers(pad).iter().map(|s| s.to_string()).collect();
            if layers.is_empty() {
                continue;
            }
            v.push(Item {
                what: ItemRef::Pad(fi, pi),
                object: f.id,
                net: pad.net,
                layers,
                prim: pad_prim(pad.shape, f.pad_position(pad), pad.size, f.pad_rotation(pad)),
            });
        }
    }
    for (i, t) in b.tracks.iter().enumerate() {
        v.push(Item { what: ItemRef::Track(i), object: t.id, net: Some(t.net), layers: vec![t.layer.clone()], prim: Prim::Seg { a: t.start, b: t.end, r: t.width / 2 } });
    }
    for (i, via) in b.vias.iter().enumerate() {
        v.push(Item {
            what: ItemRef::Via(i),
            object: via.id,
            net: Some(via.net),
            layers: COPPER.iter().map(|s| s.to_string()).collect(),
            prim: Prim::circle(via.at, via.diameter / 2),
        });
    }
    for (i, z) in b.zones.iter().enumerate() {
        for (k, s) in z.filled.iter().enumerate() {
            if s.is_empty() {
                continue;
            }
            v.push(Item {
                what: ItemRef::Zone(i, k),
                object: z.id,
                net: Some(z.net),
                layers: vec![z.layer.clone()],
                prim: Prim::Poly { outer: s[0].clone(), holes: s[1..].to_vec(), r: 0 },
            });
        }
    }
    v
}

pub type Entry = GeomWithData<Rectangle<[i64; 2]>, usize>;

/// R-tree of item boxes; queries return indices sorted ascending, so results never depend on
/// the tree's internal order.
pub struct Index {
    tree: RTree<Entry>,
}

impl Index {
    pub fn new(boxes: impl IntoIterator<Item = Aabb>) -> Index {
        let entries: Vec<Entry> =
            boxes.into_iter().enumerate().map(|(i, b)| GeomWithData::new(Rectangle::from_corners([b.min.x, b.min.y], [b.max.x, b.max.y]), i)).collect();
        Index { tree: RTree::bulk_load(entries) }
    }
    pub fn of_items(items: &[Item]) -> Index {
        Index::new(items.iter().map(|i| i.prim.aabb()))
    }
    pub fn query(&self, b: Aabb) -> Vec<usize> {
        let env = AABB::from_corners([b.min.x, b.min.y], [b.max.x, b.max.y]);
        let mut v: Vec<usize> = self.tree.locate_in_envelope_intersecting(env).map(|e| e.data).collect();
        v.sort_unstable();
        v
    }
}

/// Pairs of items whose boxes, grown by `d`, overlap (i < j).
pub fn near_pairs(items: &[Item], d: Nm) -> Vec<(usize, usize)> {
    let idx = Index::of_items(items);
    let mut out = vec![];
    for (i, it) in items.iter().enumerate() {
        for j in idx.query(it.prim.aabb().grow(d)) {
            if j > i {
                out.push((i, j));
            }
        }
    }
    out
}
