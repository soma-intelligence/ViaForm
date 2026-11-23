//! Electrical rule check (schematic), design rule check (board), connectivity and ratsnest.

use crate::copper::{collect, near_pairs, Item, ItemRef};
use crate::geom::{ring_edges, to_mm, Nm, Prim, Pt};
use crate::model::*;
use crate::netlist;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Finding {
    pub code: String,
    pub message: String,
    pub severity: String,
    pub objects: Vec<Id>,
}

fn finding(code: &str, severity: &str, message: String, objects: Vec<Id>) -> Finding {
    Finding { code: code.into(), message, severity: severity.into(), objects }
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Airwire {
    pub from: Pt,
    pub to: Pt,
    pub net: Id,
    pub from_object: Id,
    pub to_object: Id,
}

fn pin_label(p: &Project, r: &PinRef) -> String {
    let c = p.component(r.component).map(|c| c.reference.as_str()).unwrap_or("?");
    format!("{c} pin {}", r.pin)
}

/// ERC: unconnected pins, conflicting drivers, power pins without a source, merged nets,
/// duplicate references, parts without a footprint.
pub fn erc(p: &Project) -> Vec<Finding> {
    let mut q = p.clone();
    let nl = netlist::extract(&mut q);
    let mut out = vec![];
    let pins = netlist::all_pins(p);
    let mut per_net: BTreeMap<Id, Vec<(PinRef, PinKind, bool)>> = BTreeMap::new();
    for (r, kind) in &pins {
        let power_symbol = p.component(r.component).and_then(|c| p.symbol_of(c)).map(|s| s.power).unwrap_or(false);
        if let Some(n) = nl.pin_net.get(r) {
            per_net.entry(*n).or_default().push((r.clone(), *kind, power_symbol));
        }
    }
    for (r, kind) in &pins {
        let c = p.component(r.component).unwrap();
        if *kind == PinKind::NoConnect || c.no_connect.contains(&r.pin) {
            continue;
        }
        if p.symbol_of(c).map(|s| s.power).unwrap_or(false) {
            continue;
        }
        let alone = match nl.pin_net.get(r) {
            None => true,
            Some(n) => per_net.get(n).map(|v| v.len() < 2).unwrap_or(true),
        };
        if alone {
            out.push(finding("pin_unconnected", "warning", format!("{} is not connected", pin_label(p, r)), vec![r.component]));
        }
    }
    for (net, members) in &per_net {
        let drivers: Vec<&(PinRef, PinKind, bool)> = members.iter().filter(|(_, k, _)| matches!(k, PinKind::Output | PinKind::PowerOut)).collect();
        if drivers.len() > 1 {
            out.push(finding(
                "driver_conflict",
                "error",
                format!("Net {} has {} outputs driving it: {}", p.net_name(*net), drivers.len(), drivers.iter().map(|d| pin_label(p, &d.0)).collect::<Vec<_>>().join(", ")),
                drivers.iter().map(|d| d.0.component).collect(),
            ));
        }
        let needs_power = members.iter().any(|(_, k, ps)| *k == PinKind::PowerIn && !ps);
        let has_source = members.iter().any(|(_, k, ps)| *k == PinKind::PowerOut || *ps);
        if needs_power && !has_source {
            out.push(finding(
                "power_not_driven",
                "warning",
                format!("Power pins on net {} have no source", p.net_name(*net)),
                members.iter().filter(|m| m.1 == PinKind::PowerIn).map(|m| m.0.component).collect(),
            ));
        }
    }
    for (kept, others) in &nl.merged {
        out.push(finding(
            "nets_merged",
            "warning",
            format!("Nets {} and {} are connected", p.net_name(*kept), others.iter().map(|o| p.net_name(*o)).collect::<Vec<_>>().join(", ")),
            vec![],
        ));
    }
    let mut refs: BTreeMap<&str, Vec<Id>> = BTreeMap::new();
    for c in &p.components {
        if !p.symbol_of(c).map(|s| s.power).unwrap_or(false) {
            refs.entry(c.reference.as_str()).or_default().push(c.id);
        }
    }
    for (r, ids) in refs {
        if ids.len() > 1 {
            out.push(finding("duplicate_reference", "error", format!("Reference {r} is used {} times", ids.len()), ids));
        }
    }
    for c in &p.components {
        let power = p.symbol_of(c).map(|s| s.power).unwrap_or(false);
        if !power && c.footprint.is_none() {
            out.push(finding("footprint_missing", "warning", format!("{} has no footprint", c.reference), vec![c.id]));
        }
    }
    out
}

fn touching(a: &Item, b: &Item) -> bool {
    a.shares_layer(b) && a.prim.signed_gap(&b.prim) <= 0.0
}

/// Copper islands per net: for each net, groups of item indices that touch.
pub fn islands(items: &[Item]) -> BTreeMap<Id, Vec<Vec<usize>>> {
    let mut parent: Vec<usize> = (0..items.len()).collect();
    fn find(p: &mut [usize], x: usize) -> usize {
        let mut r = x;
        while p[r] != r {
            r = p[r];
        }
        p[x] = r;
        r
    }
    for (i, j) in near_pairs(items, 0) {
        let (a, b) = (&items[i], &items[j]);
        if a.net.is_some() && a.net == b.net && touching(a, b) {
            let (ri, rj) = (find(&mut parent, i), find(&mut parent, j));
            if ri != rj {
                let (lo, hi) = if ri < rj { (ri, rj) } else { (rj, ri) };
                parent[hi] = lo;
            }
        }
    }
    let mut groups: BTreeMap<(Id, usize), Vec<usize>> = BTreeMap::new();
    for (i, it) in items.iter().enumerate() {
        if let Some(n) = it.net {
            let r = find(&mut parent, i);
            groups.entry((n, r)).or_default().push(i);
        }
    }
    let mut out: BTreeMap<Id, Vec<Vec<usize>>> = BTreeMap::new();
    for ((n, _), g) in groups {
        out.entry(n).or_default().push(g);
    }
    out
}

fn pad_at(p: &Project, it: &Item) -> Option<Pt> {
    match it.what {
        ItemRef::Pad(f, k) => {
            let fp = &p.board.footprints[f];
            Some(fp.pad_position(&fp.pads[k]))
        }
        _ => None,
    }
}

/// Airwires: per net, the shortest links joining its copper islands that hold pads (Prim's
/// algorithm over islands, pad to pad distances).
pub fn ratsnest_with(p: &Project, items: &[Item]) -> Vec<Airwire> {
    let mut out = vec![];
    for (net, groups) in islands(items) {
        let pads: Vec<Vec<(Pt, Id)>> = groups
            .iter()
            .map(|g| g.iter().filter_map(|i| pad_at(p, &items[*i]).map(|at| (at, items[*i].object))).collect::<Vec<_>>())
            .filter(|v: &Vec<(Pt, Id)>| !v.is_empty())
            .collect();
        if pads.len() < 2 {
            continue;
        }
        let mut joined = vec![false; pads.len()];
        joined[0] = true;
        for _ in 1..pads.len() {
            let mut best: Option<(f64, usize, (Pt, Id), (Pt, Id))> = None;
            for (gi, g) in pads.iter().enumerate().filter(|(i, _)| joined[*i]) {
                let _ = gi;
                for (hi, h) in pads.iter().enumerate().filter(|(i, _)| !joined[*i]) {
                    for a in g {
                        for b in h {
                            let d = a.0.dist(b.0);
                            if best.as_ref().map(|x| d < x.0).unwrap_or(true) {
                                best = Some((d, hi, *a, *b));
                            }
                        }
                    }
                }
            }
            let (_, hi, a, b) = best.unwrap();
            joined[hi] = true;
            out.push(Airwire { from: a.0, to: b.0, net, from_object: a.1, to_object: b.1 });
        }
    }
    out
}

pub fn ratsnest(p: &Project) -> Vec<Airwire> {
    ratsnest_with(p, &collect(p))
}

fn hole_of(p: &Project, it_what: ItemRef) -> Option<(Pt, Nm, Id)> {
    match it_what {
        ItemRef::Pad(f, k) => {
            let fp = &p.board.footprints[f];
            let pad = &fp.pads[k];
            pad.drill.map(|d| (fp.pad_position(pad), d, fp.id))
        }
        ItemRef::Via(i) => {
            let v = &p.board.vias[i];
            Some((v.at, v.drill, v.id))
        }
        _ => None,
    }
}

fn mmf(v: f64) -> String {
    format!("{:.3} mm", v / 1e6)
}

/// DRC: clearance and shorts, track width, annular ring, drill size, hole to hole, board edge,
/// unrouted nets, footprints missing from the board.
pub fn drc(p: &Project) -> Vec<Finding> {
    let items = collect(p);
    let r = &p.rules;
    let mut out = vec![];
    let max_clear = p.net_classes.iter().map(|c| c.clearance).max().unwrap_or(0).max(r.clearance);

    for (i, j) in near_pairs(&items, max_clear) {
        let (a, b) = (&items[i], &items[j]);
        if !a.shares_layer(b) || (a.net.is_some() && a.net == b.net) {
            continue;
        }
        // Two pads of one footprint with no nets are the footprint's own business.
        if let (ItemRef::Pad(fa, _), ItemRef::Pad(fb, _)) = (a.what, b.what) {
            if fa == fb && a.net.is_none() && b.net.is_none() {
                continue;
            }
        }
        let need = p.net_rules(a.net).0.max(p.net_rules(b.net).0);
        let g = a.prim.signed_gap(&b.prim);
        if g <= 0.0 {
            out.push(finding(
                "short",
                "error",
                format!("Short between {} and {}", p.net_name(a.net.unwrap_or(0)), p.net_name(b.net.unwrap_or(0))),
                vec![a.object, b.object],
            ));
        } else if g < need as f64 {
            out.push(finding("clearance", "error", format!("Clearance {} is under {}", mmf(g), mmf(need as f64)), vec![a.object, b.object]));
        }
    }

    for t in &p.board.tracks {
        if t.width < r.min_track_width {
            out.push(finding("track_width", "error", format!("Track width {} is under {}", mmf(t.width as f64), mmf(r.min_track_width as f64)), vec![t.id]));
        }
    }
    for f in &p.board.footprints {
        for pad in &f.pads {
            if let (Some(d), PadKind::Tht) = (pad.drill, pad.kind) {
                let ring = (pad.size.x.min(pad.size.y) - d) / 2;
                if ring < r.min_annular_ring {
                    out.push(finding("annular_ring", "error", format!("Pad {} annular ring {} is under {}", pad.number, mmf(ring as f64), mmf(r.min_annular_ring as f64)), vec![f.id]));
                }
            }
            if let Some(d) = pad.drill {
                if d < r.min_drill {
                    out.push(finding("drill_size", "error", format!("Pad {} drill {} is under {}", pad.number, mmf(d as f64), mmf(r.min_drill as f64)), vec![f.id]));
                }
            }
        }
    }
    for v in &p.board.vias {
        let ring = (v.diameter - v.drill) / 2;
        if ring < r.min_annular_ring {
            out.push(finding("annular_ring", "error", format!("Via annular ring {} is under {}", mmf(ring as f64), mmf(r.min_annular_ring as f64)), vec![v.id]));
        }
        if v.drill < r.min_drill {
            out.push(finding("drill_size", "error", format!("Via drill {} is under {}", mmf(v.drill as f64), mmf(r.min_drill as f64)), vec![v.id]));
        }
    }

    // Holes: every drilled pad and via, including those of one footprint.
    let mut holes: Vec<(Pt, Nm, Id)> = vec![];
    for (fi, f) in p.board.footprints.iter().enumerate() {
        for k in 0..f.pads.len() {
            if let Some(h) = hole_of(p, ItemRef::Pad(fi, k)) {
                holes.push(h);
            }
        }
    }
    for i in 0..p.board.vias.len() {
        holes.push(hole_of(p, ItemRef::Via(i)).unwrap());
    }
    let hidx = crate::copper::Index::new(holes.iter().map(|(c, d, _)| Prim::circle(*c, d / 2).aabb()));
    for (i, (c, d, id)) in holes.iter().enumerate() {
        for j in hidx.query(Prim::circle(*c, d / 2).aabb().grow(r.hole_to_hole)) {
            if j <= i {
                continue;
            }
            let (c2, d2, id2) = holes[j];
            let g = c.dist(c2) - (*d as f64 + d2 as f64) / 2.0;
            if g < r.hole_to_hole as f64 {
                out.push(finding("hole_to_hole", "error", format!("Holes {} apart, under {}", mmf(g.max(0.0)), mmf(r.hole_to_hole as f64)), vec![*id, id2]));
            }
        }
    }

    // Board edge: outline edges and cutouts.
    let mut edges: Vec<Prim> = ring_edges(&p.board.outline).into_iter().map(|(a, b)| Prim::Seg { a, b, r: 0 }).collect();
    let cut_rings: Vec<Prim> = p.board.cutouts.iter().map(|c| Prim::Poly { outer: crate::geom::stadium(c.center, c.center, c.radius), holes: vec![], r: 0 }).collect();
    for c in &p.board.cutouts {
        edges.push(Prim::Seg { a: c.center, b: c.center, r: c.radius });
    }
    let eidx = crate::copper::Index::new(edges.iter().map(|e| e.aabb()));
    for it in &items {
        let inside = match &it.prim {
            Prim::Seg { a, .. } => crate::geom::point_in_ring(*a, &p.board.outline),
            Prim::Poly { outer, .. } => crate::geom::point_in_ring(outer[0], &p.board.outline),
        };
        let in_cut = cut_rings.iter().any(|c| c.signed_gap(&it.prim) < 0.0 && matches!(c, Prim::Poly { .. }));
        if !inside {
            out.push(finding("outside_board", "error", "Copper outside the board outline".into(), vec![it.object]));
            continue;
        }
        let mut worst = f64::INFINITY;
        for k in eidx.query(it.prim.aabb().grow(r.edge_clearance)) {
            // A cutout circle counts by its rim: use the gap to the disc.
            worst = worst.min(edges[k].signed_gap(&it.prim));
        }
        if in_cut || worst < r.edge_clearance as f64 {
            out.push(finding("edge_clearance", "error", format!("Copper {} from the board edge, under {}", mmf(worst.max(0.0)), mmf(r.edge_clearance as f64)), vec![it.object]));
        }
    }

    // Unrouted.
    let air = ratsnest_with(p, &items);
    let mut per: BTreeMap<Id, (usize, BTreeSet<Id>)> = BTreeMap::new();
    for a in &air {
        let e = per.entry(a.net).or_default();
        e.0 += 1;
        e.1.insert(a.from_object);
        e.1.insert(a.to_object);
    }
    for (net, (n, objs)) in per {
        out.push(finding(
            "unrouted",
            "warning",
            format!("Net {} has {n} unrouted connection{}", p.net_name(net), if n == 1 { "" } else { "s" }),
            objs.into_iter().collect(),
        ));
    }
    for c in &p.components {
        if c.footprint.is_some() && !p.board.footprints.iter().any(|f| f.component == c.id) {
            out.push(finding("footprint_not_on_board", "warning", format!("{} is not on the board: update the board", c.reference), vec![c.id]));
        }
    }
    out
}

/// The `pcb_checks` reply: ERC, DRC and airwires, lengths in millimetres.
pub fn checks_json(p: &Project) -> Value {
    let air: Vec<Value> = ratsnest(p)
        .iter()
        .map(|a| {
            json!({"from": {"x": to_mm(a.from.x), "y": to_mm(a.from.y)}, "to": {"x": to_mm(a.to.x), "y": to_mm(a.to.y)},
                   "net": a.net, "from_object": a.from_object, "to_object": a.to_object})
        })
        .collect();
    json!({"erc": erc(p), "drc": drc(p), "airwires": air})
}
