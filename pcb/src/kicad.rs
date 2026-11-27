//! KiCad file formats, written from the public s-expression format documentation
//! (dev-docs.kicad.org): symbol and footprint library import, board export and import.

use crate::error::{EngineError, Result};
use crate::geom::{mdeg, mm, norm_mdeg, to_deg, Nm, Pt};
use crate::model::*;
use crate::sexpr::{n, parse, q, Sx};
use std::collections::BTreeMap;
use std::fmt::Write as _;

/// Board file version written: KiCad 8 (KiCad 9 reads it).
pub const PCB_VERSION: &str = "20240108";

fn strip_lib(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

fn at_of(s: &Sx) -> (Pt, f64) {
    match s.child("at") {
        Some(a) => (Pt::mm(a.num(1).unwrap_or(0.0), a.num(2).unwrap_or(0.0)), a.num(3).unwrap_or(0.0)),
        None => (Pt::default(), 0.0),
    }
}

fn property<'a>(s: &'a Sx, key: &str) -> Option<&'a str> {
    s.children("property").find(|p| p.str_at(1) == Some(key)).and_then(|p| p.str_at(2))
}

fn collect_pins(s: &Sx, out: &mut Vec<SymbolPin>) {
    for c in s.items() {
        match c.head() {
            Some("pin") => {
                let (at, _) = at_of(c);
                let number = c.child("number").and_then(|x| x.str_at(1)).unwrap_or("").to_string();
                if out.iter().any(|p| p.number == number) {
                    continue; // the same pin drawn in another body style
                }
                out.push(SymbolPin {
                    number,
                    name: c.child("name").and_then(|x| x.str_at(1)).unwrap_or("").to_string(),
                    position: at,
                    kind: PinKind::parse(c.str_at(1).unwrap_or("passive")),
                });
            }
            Some("symbol") => collect_pins(c, out),
            _ => {}
        }
    }
}

/// Reads one symbol from a `.kicad_sym` library.
pub fn import_symbol(src: &str, name: &str) -> Result<SymbolDef> {
    let lib = parse(src)?;
    if lib.head() != Some("kicad_symbol_lib") {
        return Err(EngineError::new("format", "not a KiCad symbol library"));
    }
    let want = strip_lib(name);
    let find = |n: &str| lib.children("symbol").find(|s| s.str_at(1).map(strip_lib) == Some(n));
    let sym = find(want).ok_or_else(|| EngineError::not_found(format!("symbol {want} is not in the library")))?;
    let mut pins = vec![];
    collect_pins(sym, &mut pins);
    if let Some(base) = sym.child("extends").and_then(|e| e.str_at(1)) {
        if let Some(b) = find(strip_lib(base)) {
            collect_pins(b, &mut pins);
        }
    }
    let reference = property(sym, "Reference").unwrap_or("U");
    let fp = property(sym, "Footprint").unwrap_or("");
    let (mut bx, mut by): (Nm, Nm) = (mm(2.54), mm(2.54));
    for p in &pins {
        bx = bx.max(p.position.x.abs());
        by = by.max(p.position.y.abs());
    }
    Ok(SymbolDef {
        name: want.to_string(),
        reference_prefix: reference.trim_start_matches('#').trim_end_matches(|c: char| c.is_ascii_digit()).to_string(),
        value: property(sym, "Value").unwrap_or(want).to_string(),
        description: property(sym, "Description").or_else(|| property(sym, "ki_description")).unwrap_or("").to_string(),
        footprint: if fp.is_empty() { None } else { Some(strip_lib(fp).to_string()) },
        pins,
        body: Pt::new(bx, by),
        power: sym.child("power").is_some(),
    })
}

fn pad_from(p: &Sx) -> Option<PadDef> {
    let number = p.str_at(1)?.to_string();
    let kind = match p.str_at(2)? {
        "smd" | "connect" => PadKind::Smd,
        "np_thru_hole" => PadKind::Npth,
        _ => PadKind::Tht,
    };
    let shape = PadShape::parse(p.str_at(3).unwrap_or("circle"));
    let (offset, rot) = at_of(p);
    let size = p.child("size").map(|s| Pt::mm(s.num(1).unwrap_or(1.0), s.num(2).unwrap_or(1.0))).unwrap_or(Pt::mm(1.0, 1.0));
    let drill = p.child("drill").and_then(|d| {
        // (drill D) or (drill oval W H): the smaller size is the round hole we model.
        let vals: Vec<f64> = d.items()[1..].iter().filter_map(|x| x.text()?.parse().ok()).collect();
        vals.iter().cloned().fold(None, |a: Option<f64>, v| Some(a.map_or(v, |a| a.min(v)))).map(mm)
    });
    Some(PadDef { number, kind, shape, offset, size, rotation: mdeg(rot), drill: if kind == PadKind::Smd { None } else { drill } })
}

/// Reads a `.kicad_mod` footprint.
pub fn import_footprint(src: &str) -> Result<FootprintDef> {
    let f = parse(src)?;
    if !matches!(f.head(), Some("footprint") | Some("module")) {
        return Err(EngineError::new("format", "not a KiCad footprint"));
    }
    let name = strip_lib(f.str_at(1).unwrap_or("footprint")).to_string();
    let pads: Vec<PadDef> = f.children("pad").filter_map(pad_from).collect();
    let description = f.child("descr").and_then(|d| d.str_at(1)).unwrap_or("").to_string();
    Ok(FootprintDef { name, description, pads })
}

/// Deterministic UUID for an object: a fixed kind tag and the object id.
fn uuid(kind: u32, id: u64) -> String {
    format!("{kind:08x}-0000-4000-8000-{:012x}", id & 0xffff_ffff_ffff)
}

const LAYERS: &str = r#"  (layers
    (0 "F.Cu" signal)
    (31 "B.Cu" signal)
    (32 "B.Adhes" user "B.Adhesive")
    (33 "F.Adhes" user "F.Adhesive")
    (34 "B.Paste" user)
    (35 "F.Paste" user)
    (36 "B.SilkS" user "B.Silkscreen")
    (37 "F.SilkS" user "F.Silkscreen")
    (38 "B.Mask" user)
    (39 "F.Mask" user)
    (40 "Dwgs.User" user "User.Drawings")
    (41 "Cmts.User" user "User.Comments")
    (42 "Eco1.User" user "User.Eco1")
    (43 "Eco2.User" user "User.Eco2")
    (44 "Edge.Cuts" user)
    (45 "Margin" user)
    (46 "B.CrtYd" user "B.Courtyard")
    (47 "F.CrtYd" user "F.Courtyard")
    (48 "B.Fab" user)
    (49 "F.Fab" user)
  )
"#;

fn ang(a: i64) -> String {
    let d = to_deg(norm_mdeg(a));
    if d == d.trunc() { format!("{}", d as i64) } else { format!("{d}") }
}

/// Writes the board as a KiCad 8 `.kicad_pcb`. Net ordinals follow net ids; zones are written
/// with their outline only (KiCad refills them).
pub fn export_pcb(p: &Project) -> String {
    let mut o = String::new();
    let ordinal: BTreeMap<Id, usize> = p.nets.iter().enumerate().map(|(i, n)| (n.id, i + 1)).collect();
    let netref = |id: Option<Id>| -> String {
        match id.and_then(|i| ordinal.get(&i).map(|k| (i, *k))) {
            Some((i, k)) => format!("(net {k} {})", q(&p.net_name(i))),
            None => "(net 0 \"\")".into(),
        }
    };
    let _ = writeln!(o, "(kicad_pcb");
    let _ = writeln!(o, "  (version {PCB_VERSION})");
    let _ = writeln!(o, "  (generator \"viaform\")");
    let _ = writeln!(o, "  (generator_version \"{}\")", env!("CARGO_PKG_VERSION"));
    let _ = writeln!(o, "  (general\n    (thickness {})\n    (legacy_teardrops no)\n  )", n(p.board.thickness));
    let _ = writeln!(o, "  (paper \"A4\")");
    let _ = writeln!(o, "  (title_block\n    (title {})\n  )", q(&p.name));
    o.push_str(LAYERS);
    let _ = writeln!(o, "  (setup\n    (pad_to_mask_clearance 0)\n    (allow_soldermask_bridges_in_footprints no)\n  )");
    let _ = writeln!(o, "  (net 0 \"\")");
    for (i, net) in p.nets.iter().enumerate() {
        let _ = writeln!(o, "  (net {} {})", i + 1, q(&net.name));
    }
    for f in &p.board.footprints {
        let c = p.component(f.component);
        let (reference, value) = c.map(|c| (c.reference.clone(), c.value.clone())).unwrap_or_default();
        let back = f.side == Side::Back;
        let (cu, silk, fab) = if back { ("B.Cu", "B.SilkS", "B.Fab") } else { ("F.Cu", "F.SilkS", "F.Fab") };
        let _ = writeln!(o, "  (footprint {}", q(&format!("ViaForm:{}", f.name)));
        let _ = writeln!(o, "    (layer {})", q(cu));
        let _ = writeln!(o, "    (uuid {})", q(&uuid(1, f.id)));
        let _ = writeln!(o, "    (at {} {} {})", n(f.position.x), n(f.position.y), ang(f.rotation));
        let font = "(effects (font (size 1 1) (thickness 0.15)))";
        let _ = writeln!(o, "    (property \"Reference\" {} (at 0 -2.5 {}) (layer {}) (uuid {}) {})", q(&reference), ang(f.rotation), q(silk), q(&uuid(2, f.id)), font);
        let _ = writeln!(o, "    (property \"Value\" {} (at 0 2.5 {}) (layer {}) (uuid {}) {})", q(&value), ang(f.rotation), q(fab), q(&uuid(3, f.id)), font);
        let tht = f.pads.iter().any(|p| p.kind == PadKind::Tht);
        let _ = writeln!(o, "    (attr {})", if tht { "through_hole" } else { "smd" });
        for (k, pad) in f.pads.iter().enumerate() {
            let off = if back { Pt::new(-pad.offset.x, pad.offset.y) } else { pad.offset };
            let (kind, layers) = match pad.kind {
                PadKind::Tht => ("thru_hole", "\"*.Cu\" \"*.Mask\"".to_string()),
                PadKind::Npth => ("np_thru_hole", "\"*.Cu\" \"*.Mask\"".to_string()),
                PadKind::Smd => ("smd", if back { "\"B.Cu\" \"B.Paste\" \"B.Mask\"" } else { "\"F.Cu\" \"F.Paste\" \"F.Mask\"" }.to_string()),
            };
            let drill = pad.drill.map(|d| format!(" (drill {})", n(d))).unwrap_or_default();
            let rr = if pad.shape == PadShape::RoundRect { " (roundrect_rratio 0.25)" } else { "" };
            let net = if pad.kind == PadKind::Npth { String::new() } else { format!(" {}", netref(pad.net)) };
            let _ = writeln!(
                o,
                "    (pad {} {kind} {} (at {} {} {}) (size {} {}){drill} (layers {layers}){rr}{net} (uuid {}))",
                q(&pad.number),
                pad.shape.name(),
                n(off.x),
                n(off.y),
                ang(f.pad_rotation(pad)),
                n(pad.size.x),
                n(pad.size.y),
                q(&uuid(4, (f.id << 16) | k as u64)),
            );
        }
        let _ = writeln!(o, "  )");
    }
    let ol = &p.board.outline;
    for i in 0..ol.len() {
        let (a, b) = (ol[i], ol[(i + 1) % ol.len()]);
        let _ = writeln!(
            o,
            "  (gr_line (start {} {}) (end {} {}) (stroke (width 0.05) (type default)) (layer \"Edge.Cuts\") (uuid {}))",
            n(a.x),
            n(a.y),
            n(b.x),
            n(b.y),
            q(&uuid(5, i as u64))
        );
    }
    for c in &p.board.cutouts {
        let _ = writeln!(
            o,
            "  (gr_circle (center {} {}) (end {} {}) (stroke (width 0.05) (type default)) (fill none) (layer \"Edge.Cuts\") (uuid {}))",
            n(c.center.x),
            n(c.center.y),
            n(c.center.x + c.radius),
            n(c.center.y),
            q(&uuid(6, c.id))
        );
    }
    for t in &p.board.tracks {
        let _ = writeln!(
            o,
            "  (segment (start {} {}) (end {} {}) (width {}) (layer {}) (net {}) (uuid {}))",
            n(t.start.x),
            n(t.start.y),
            n(t.end.x),
            n(t.end.y),
            n(t.width),
            q(&t.layer),
            ordinal.get(&t.net).copied().unwrap_or(0),
            q(&uuid(7, t.id))
        );
    }
    for v in &p.board.vias {
        let _ = writeln!(
            o,
            "  (via (at {} {}) (size {}) (drill {}) (layers \"F.Cu\" \"B.Cu\") (net {}) (uuid {}))",
            n(v.at.x),
            n(v.at.y),
            n(v.diameter),
            n(v.drill),
            ordinal.get(&v.net).copied().unwrap_or(0),
            q(&uuid(8, v.id))
        );
    }
    for z in &p.board.zones {
        let pts: Vec<String> = z.outline.iter().map(|p| format!("(xy {} {})", n(p.x), n(p.y))).collect();
        let _ = writeln!(
            o,
            "  (zone (net {}) (net_name {}) (layer {}) (uuid {}) (hatch edge 0.5) (connect_pads (clearance {})) (min_thickness {}) (fill (thermal_gap {}) (thermal_bridge_width {})) (polygon (pts {})))",
            ordinal.get(&z.net).copied().unwrap_or(0),
            q(&p.net_name(z.net)),
            q(&z.layer),
            q(&uuid(9, z.id)),
            n(z.clearance),
            n(z.min_width),
            n(z.thermal_gap),
            n(z.spoke_width),
            pts.join(" ")
        );
    }
    o.push_str(")\n");
    o
}

/// Reads a `.kicad_pcb` into a new project: nets, footprints (each becomes a component),
/// tracks, vias, zone outlines, the Edge.Cuts outline box and circular cutouts.
pub fn import_pcb(src: &str) -> Result<Project> {
    let s = parse(src)?;
    if s.head() != Some("kicad_pcb") {
        return Err(EngineError::new("format", "not a KiCad board"));
    }
    let mut p = Project::default();
    if let Some(t) = s.child("title_block").and_then(|t| t.child("title")).and_then(|t| t.str_at(1)) {
        p.name = t.to_string();
    }
    let mut net_of: BTreeMap<i64, Id> = BTreeMap::new();
    for nt in s.children("net") {
        let (Some(k), Some(name)) = (nt.num(1), nt.str_at(2)) else { continue };
        if k as i64 == 0 || name.is_empty() {
            continue;
        }
        let id = p.alloc();
        p.nets.push(Net { id, name: name.to_string(), named: true, pins: vec![], class: None });
        net_of.insert(k as i64, id);
    }
    let net_in = |x: &Sx| x.child("net").and_then(|nn| nn.num(1)).and_then(|k| net_of.get(&(k as i64)).copied());
    let sheet = p.sheets[0].id;
    for f in s.children("footprint").chain(s.children("module")) {
        let def_name = strip_lib(f.str_at(1).unwrap_or("fp")).to_string();
        let (at, rot) = at_of(f);
        let back = f.child("layer").and_then(|l| l.str_at(1)) == Some("B.Cu");
        let reference = property(f, "Reference").unwrap_or("U?").to_string();
        let value = property(f, "Value").unwrap_or("").to_string();
        let mut pads = vec![];
        let mut def_pads = vec![];
        for padsx in f.children("pad") {
            if let Some(mut d) = pad_from(padsx) {
                // Pad angles in board files are absolute; make them relative to the footprint.
                d.rotation = norm_mdeg(d.rotation - mdeg(rot));
                if back {
                    d.offset.x = -d.offset.x;
                }
                pads.push(Pad { number: d.number.clone(), kind: d.kind, shape: d.shape, offset: d.offset, size: d.size, rotation: d.rotation, drill: d.drill, net: net_in(padsx) });
                def_pads.push(d);
            }
        }
        p.library.footprints.entry(def_name.clone()).or_insert(FootprintDef { name: def_name.clone(), description: String::new(), pads: def_pads.clone() });
        let sym_name = format!("{def_name}__pins");
        p.library.symbols.entry(sym_name.clone()).or_insert_with(|| SymbolDef {
            name: sym_name.clone(),
            reference_prefix: reference.trim_end_matches(|c: char| c.is_ascii_digit()).to_string(),
            value: value.clone(),
            description: "Made from a KiCad board footprint".into(),
            footprint: Some(def_name.clone()),
            pins: def_pads.iter().enumerate().map(|(i, d)| SymbolPin { number: d.number.clone(), name: d.number.clone(), position: Pt::mm(-7.62, i as f64 * 2.54), kind: PinKind::Passive }).collect(),
            body: Pt::mm(5.08, 2.54 * def_pads.len().max(1) as f64 / 2.0),
            power: false,
        });
        let cid = p.alloc();
        p.components.push(Component {
            id: cid,
            sheet,
            reference,
            value,
            kind: sym_name.clone(),
            symbol: sym_name,
            footprint: Some(def_name.clone()),
            position: at,
            rotation: 0,
            no_connect: vec![],
        });
        // The netlist comes from the pads: attach each pad's pin to its net.
        for pad in &pads {
            if let Some(nid) = pad.net {
                let pr = PinRef { component: cid, pin: pad.number.clone() };
                if let Some(nn) = p.nets.iter_mut().find(|x| x.id == nid) {
                    if !nn.pins.contains(&pr) {
                        nn.pins.push(pr);
                    }
                }
            }
        }
        let fid = p.alloc();
        p.board.footprints.push(Footprint { id: fid, component: cid, name: def_name, position: at, rotation: mdeg(rot), side: if back { Side::Back } else { Side::Front }, pads });
    }
    let mut edge_pts: Vec<Pt> = vec![];
    for g in s.items() {
        let layer = g.child("layer").and_then(|l| l.str_at(1));
        let xy = |h: &str| g.child(h).map(|a| Pt::mm(a.num(1).unwrap_or(0.0), a.num(2).unwrap_or(0.0)));
        match (g.head(), layer) {
            (Some("gr_line") | Some("gr_rect"), Some("Edge.Cuts")) => {
                edge_pts.extend(xy("start"));
                edge_pts.extend(xy("end"));
            }
            (Some("gr_circle"), Some("Edge.Cuts")) => {
                if let (Some(c), Some(e)) = (xy("center"), xy("end")) {
                    let id = p.alloc();
                    p.board.cutouts.push(Cutout { id, center: c, radius: c.dist(e).round() as Nm });
                }
            }
            (Some("segment"), _) => {
                if let (Some(a), Some(b), Some(net)) = (xy("start"), xy("end"), net_in(g)) {
                    let id = p.alloc();
                    let width = g.child("width").and_then(|w| w.num(1)).map(mm).unwrap_or(p.rules.track_width);
                    p.board.tracks.push(Track { id, net, start: a, end: b, width, layer: layer.unwrap_or("F.Cu").to_string(), auto: false });
                }
            }
            (Some("via"), _) => {
                if let (Some(a), Some(net)) = (xy("at"), net_in(g)) {
                    let id = p.alloc();
                    let d = g.child("size").and_then(|w| w.num(1)).map(mm).unwrap_or(p.rules.via_diameter);
                    let dr = g.child("drill").and_then(|w| w.num(1)).map(mm).unwrap_or(p.rules.via_drill);
                    p.board.vias.push(Via { id, net, at: a, diameter: d, drill: dr, auto: false });
                }
            }
            (Some("zone"), _) => {
                let pts: Vec<Pt> = g
                    .child("polygon")
                    .and_then(|pl| pl.child("pts"))
                    .map(|pts| pts.children("xy").map(|x| Pt::mm(x.num(1).unwrap_or(0.0), x.num(2).unwrap_or(0.0))).collect())
                    .unwrap_or_default();
                if let (Some(net), true) = (net_in(g), pts.len() >= 3) {
                    let id = p.alloc();
                    let cl = g.child("connect_pads").and_then(|c| c.child("clearance")).and_then(|c| c.num(1)).map(mm).unwrap_or(p.rules.clearance);
                    p.board.zones.push(Zone { id, net, layer: layer.unwrap_or("F.Cu").into(), outline: pts, clearance: cl, thermal_gap: mm(0.5), spoke_width: mm(0.5), min_width: mm(0.25), filled: vec![] });
                }
            }
            _ => {}
        }
    }
    if !edge_pts.is_empty() {
        let b = crate::geom::Aabb::of(&edge_pts);
        // Our boards keep the origin at the top left corner of the outline box.
        let shift = b.min;
        p.board.width = b.max.x - b.min.x;
        p.board.height = b.max.y - b.min.y;
        p.board.outline = Board::rect_outline(p.board.width, p.board.height);
        if shift != Pt::default() {
            let mv = |q: &mut Pt| *q = q.sub(shift);
            for f in &mut p.board.footprints {
                mv(&mut f.position);
            }
            for t in &mut p.board.tracks {
                mv(&mut t.start);
                mv(&mut t.end);
            }
            for v in &mut p.board.vias {
                mv(&mut v.at);
            }
            for c in &mut p.board.cutouts {
                mv(&mut c.center);
            }
            for z in &mut p.board.zones {
                z.outline.iter_mut().for_each(mv);
            }
        }
    }
    crate::netlist::extract(&mut p);
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SYM: &str = r#"(kicad_symbol_lib (version 20231120) (generator "test")
      (symbol "Device:R" (property "Reference" "R" (at 0 0 0)) (property "Value" "R" (at 0 0 0))
        (property "Footprint" "Resistor_THT:R_Axial" (at 0 0 0))
        (symbol "R_1_1"
          (pin passive line (at 0 3.81 270) (length 1.27) (name "~" (effects (font (size 1.27 1.27)))) (number "1" (effects (font (size 1.27 1.27)))))
          (pin passive line (at 0 -3.81 90) (length 1.27) (name "~") (number "2")))))"#;

    const MODULE: &str = r#"(footprint "R_Axial" (layer "F.Cu") (descr "axial")
      (pad "1" thru_hole rect (at 0 0) (size 1.6 1.6) (drill 0.8) (layers "*.Cu" "*.Mask"))
      (pad "2" thru_hole oval (at 7.62 0) (size 1.6 1.6) (drill 0.8) (layers "*.Cu" "*.Mask")))"#;

    #[test]
    fn imports_symbol_and_footprint() {
        let s = import_symbol(SYM, "R").unwrap();
        assert_eq!(s.pins.len(), 2);
        assert_eq!(s.reference_prefix, "R");
        assert_eq!(s.footprint.as_deref(), Some("R_Axial"));
        assert_eq!(s.pins[0].position, Pt::mm(0.0, 3.81));
        let f = import_footprint(MODULE).unwrap();
        assert_eq!(f.pads.len(), 2);
        assert_eq!(f.pads[1].offset, Pt::mm(7.62, 0.0));
        assert_eq!(f.pads[0].drill, Some(mm(0.8)));
    }
}
