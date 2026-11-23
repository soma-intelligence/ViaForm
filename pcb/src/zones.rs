//! Copper zone fill with clearances and thermal reliefs, through polygon booleans (i_overlay).

use crate::copper::{collect, Item, ItemRef};
use crate::geom::*;
use crate::model::*;

fn board_region(p: &Project) -> Vec<Shape> {
    let e = p.rules.edge_clearance;
    let mut cut: Vec<Shape> = ring_edges(&p.board.outline).into_iter().map(|(a, b)| vec![stadium(a, b, e)]).collect();
    for c in &p.board.cutouts {
        cut.push(vec![stadium(c.center, c.center, c.radius + e)]);
    }
    difference(&[vec![p.board.outline.clone()]], &cut)
}

fn spokes(at: Pt, reach: Nm, width: Nm) -> Vec<Shape> {
    let h = width / 2;
    vec![
        vec![vec![Pt::new(at.x - reach, at.y - h), Pt::new(at.x + reach, at.y - h), Pt::new(at.x + reach, at.y + h), Pt::new(at.x - reach, at.y + h)]],
        vec![vec![Pt::new(at.x - h, at.y - reach), Pt::new(at.x + h, at.y - reach), Pt::new(at.x + h, at.y + reach), Pt::new(at.x - h, at.y + reach)]],
    ]
}

/// Fills zone `zi` against the copper currently on the board (other zones' fills included).
pub fn fill_zone(p: &Project, zi: usize) -> Vec<Shape> {
    let z = &p.board.zones[zi];
    let items: Vec<Item> = collect(p).into_iter().filter(|it| !matches!(it.what, ItemRef::Zone(k, _) if k == zi)).collect();
    let region = intersection(&board_region(p), &[vec![z.outline.clone()]]);
    let mut obstacles: Vec<Shape> = vec![];
    let mut thermal_rings: Vec<Shape> = vec![];
    let mut thermal_spokes: Vec<Shape> = vec![];
    for it in items.iter().filter(|it| it.on(&z.layer)) {
        if it.net == Some(z.net) {
            if let ItemRef::Pad(f, k) = it.what {
                let fp = &p.board.footprints[f];
                let pad = &fp.pads[k];
                let at = fp.pad_position(pad);
                thermal_rings.push(it.prim.to_polygon(z.thermal_gap));
                let reach = pad.size.x.max(pad.size.y) / 2 + z.thermal_gap + z.spoke_width;
                thermal_spokes.extend(spokes(at, reach, z.spoke_width));
            }
            continue;
        }
        let clear = z.clearance.max(p.net_rules(it.net).0);
        obstacles.push(it.prim.to_polygon(clear));
    }
    // Holes keep their clearance on every layer, whatever their net.
    for f in &p.board.footprints {
        for pad in f.pads.iter().filter(|q| q.kind == PadKind::Npth) {
            if let Some(d) = pad.drill {
                obstacles.push(vec![stadium(f.pad_position(pad), f.pad_position(pad), d / 2 + z.clearance)]);
            }
        }
    }
    let base = difference(&region, &union_all(&obstacles));
    let solid = difference(&base, &union_all(&thermal_rings));
    let bridges = intersection(&base, &union_all(&thermal_spokes));
    let mut fill = union_all(&[solid, bridges].concat());
    // Drop slivers and islands that reach no copper of the zone's net.
    let own: Vec<&Item> = items.iter().filter(|it| it.on(&z.layer) && it.net == Some(z.net)).collect();
    let min_area = (z.min_width as f64) * (z.min_width as f64);
    fill.retain(|s| {
        if s.is_empty() || shape_area(s) < min_area {
            return false;
        }
        let prim = Prim::Poly { outer: s[0].clone(), holes: s[1..].to_vec(), r: 0 };
        own.iter().any(|it| it.prim.signed_gap(&prim) <= 0.0)
    });
    fill
}

/// Refills every zone in id order.
pub fn fill_all(p: &mut Project) {
    let mut order: Vec<usize> = (0..p.board.zones.len()).collect();
    order.sort_by_key(|i| p.board.zones[*i].id);
    for z in &mut p.board.zones {
        z.filled.clear();
    }
    for i in order {
        let f = fill_zone(p, i);
        p.board.zones[i].filled = f;
    }
}
