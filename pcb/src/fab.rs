//! Fabrication outputs: Gerber RS-274X with X2 attributes (Ucamco specification), Excellon
//! drill files, bill of materials and pick and place CSV.
//!
//! Gerber and drill coordinates use the Gerber frame: x right, y up, so board y is negated.
//! Format 4.6 in millimetres, so a coordinate is the nanometre count itself.

use crate::copper::pad_prim;
use crate::geom::*;
use crate::model::*;
use crate::sexpr::n as mmstr;
use std::collections::BTreeMap;
use std::fmt::Write as _;

/// Solder mask opening around each pad.
pub const MASK_MARGIN: Nm = 50_000;

fn xy(p: Pt) -> String {
    format!("X{}Y{}", p.x, -p.y)
}

/// Splits a polygon with holes into hole-free rings that cover it (pieces may share edges),
/// by cutting through each hole with a vertical line. Gerber regions cannot hold holes.
pub fn fracture(shape: &Shape) -> Vec<Vec<Pt>> {
    if shape.is_empty() {
        return vec![];
    }
    if shape.len() == 1 {
        return vec![shape[0].clone()];
    }
    let hb = Aabb::of(&shape[1]);
    let x = (hb.min.x + hb.max.x) / 2;
    let ob = Aabb::of(&shape[0]).grow(1);
    let left = vec![vec![Pt::new(ob.min.x, ob.min.y), Pt::new(x, ob.min.y), Pt::new(x, ob.max.y), Pt::new(ob.min.x, ob.max.y)]];
    let right = vec![vec![Pt::new(x, ob.min.y), Pt::new(ob.max.x, ob.min.y), Pt::new(ob.max.x, ob.max.y), Pt::new(x, ob.max.y)]];
    let mut out = vec![];
    for half in [left, right] {
        for piece in intersection(&[shape.clone()], &[half]) {
            out.extend(fracture(&piece));
        }
    }
    out
}

struct Gerber {
    body: String,
    apertures: BTreeMap<(String, String), u32>,
    defs: String,
    current: Option<u32>,
}

impl Gerber {
    fn new() -> Self {
        Gerber { body: String::new(), apertures: BTreeMap::new(), defs: String::new(), current: None }
    }
    /// Aperture number for a template (C, R, O with mm parameters) and function attribute.
    fn aperture(&mut self, template: String, function: &str) -> u32 {
        let key = (function.to_string(), template.clone());
        if let Some(d) = self.apertures.get(&key) {
            return *d;
        }
        let d = 10 + self.apertures.len() as u32;
        self.apertures.insert(key, d);
        let _ = write!(self.defs, "%TA.AperFunction,{function}*%\n%ADD{d}{template}*%\n");
        d
    }
    fn select(&mut self, d: u32) {
        if self.current != Some(d) {
            let _ = writeln!(self.body, "D{d}*");
            self.current = Some(d);
        }
    }
    fn attr(&mut self, a: &str) {
        let _ = writeln!(self.body, "%{a}*%");
    }
    fn flash(&mut self, d: u32, at: Pt) {
        self.select(d);
        let _ = writeln!(self.body, "{}D03*", xy(at));
    }
    fn draw(&mut self, d: u32, a: Pt, b: Pt) {
        self.select(d);
        let _ = writeln!(self.body, "{}D02*", xy(a));
        let _ = writeln!(self.body, "{}D01*", xy(b));
    }
    fn region(&mut self, ring: &[Pt]) {
        if ring.len() < 3 {
            return;
        }
        let _ = writeln!(self.body, "G36*");
        let _ = writeln!(self.body, "{}D02*", xy(ring[0]));
        for p in &ring[1..] {
            let _ = writeln!(self.body, "{}D01*", xy(*p));
        }
        let _ = writeln!(self.body, "{}D01*", xy(ring[0]));
        let _ = writeln!(self.body, "G37*");
    }
    fn finish(self, project: &str, function: &str, polarity: &str) -> String {
        let mut o = String::new();
        let _ = writeln!(o, "%TF.GenerationSoftware,ViaForm,viaform-pcb,{}*%", env!("CARGO_PKG_VERSION"));
        let _ = writeln!(o, "%TF.ProjectId,{},00000000-0000-4000-8000-000000000000,1*%", sanitize(project));
        let _ = writeln!(o, "%TF.SameCoordinates,Original*%");
        let _ = writeln!(o, "%TF.FileFunction,{function}*%");
        let _ = writeln!(o, "%TF.FilePolarity,{polarity}*%");
        let _ = writeln!(o, "%FSLAX46Y46*%");
        let _ = writeln!(o, "%MOMM*%");
        let _ = writeln!(o, "G04 Made by ViaForm viaform-pcb*");
        let _ = writeln!(o, "%LPD*%");
        let _ = writeln!(o, "G01*");
        o.push_str(&self.defs);
        let _ = writeln!(o, "%TD*%");
        o.push_str(&self.body);
        let _ = writeln!(o, "M02*");
        o
    }
}

/// Gerber attribute values may not hold commas or asterisks.
fn sanitize(s: &str) -> String {
    let t: String = s.chars().map(|c| if matches!(c, ',' | '*' | '%' | '\n' | '\r') { '_' } else { c }).collect();
    if t.is_empty() { "board".into() } else { t }
}

fn pad_aperture(g: &mut Gerber, shape: PadShape, size: Pt, rot: MilliDeg, function: &str) -> Option<u32> {
    let quarter = rot % 90_000 == 0;
    let (w, h) = if (rot / 90_000) % 2 == 1 { (size.y, size.x) } else { (size.x, size.y) };
    match shape {
        PadShape::Circle => Some(g.aperture(format!("C,{}", mmstr(size.x.min(size.y))), function)),
        PadShape::Rect if quarter => Some(g.aperture(format!("R,{}X{}", mmstr(w), mmstr(h)), function)),
        PadShape::Oval if quarter => Some(g.aperture(format!("O,{}X{}", mmstr(w), mmstr(h)), function)),
        _ => None,
    }
}

fn pads_layer(p: &Project, g: &mut Gerber, layer: &str, grow: Nm, smd_only: bool) {
    for f in &p.board.footprints {
        let reference = p.component(f.component).map(|c| c.reference.clone()).unwrap_or_default();
        for pad in &f.pads {
            if pad.kind == PadKind::Npth && grow == 0 {
                continue;
            }
            if smd_only && pad.kind != PadKind::Smd {
                continue;
            }
            let on = match pad.kind {
                PadKind::Smd => f.pad_layers(pad).contains(&layer.replace("Mask", "Cu").replace("Paste", "Cu").as_str()),
                _ => true,
            };
            if !on {
                continue;
            }
            let at = f.pad_position(pad);
            let rot = f.pad_rotation(pad);
            let size = Pt::new(pad.size.x + 2 * grow, pad.size.y + 2 * grow);
            let function = match pad.kind {
                PadKind::Smd => "SMDPad,CuDef",
                PadKind::Npth => "ComponentPad",
                PadKind::Tht => "ComponentPad",
            };
            g.attr(&format!("TO.P,{},{}", sanitize(&reference), sanitize(&pad.number)));
            if let Some(net) = pad.net {
                g.attr(&format!("TO.N,{}", sanitize(&p.net_name(net))));
            }
            match pad_aperture(g, pad.shape, size, rot, function) {
                Some(d) => g.flash(d, at),
                None => {
                    for ring in pad_prim(pad.shape, at, size, rot).to_polygon(0) {
                        g.region(&ring);
                    }
                }
            }
            g.attr("TD");
        }
    }
}

/// One Gerber file per layer, keyed by file name.
pub fn gerbers(p: &Project) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let base = sanitize(&p.name).replace(' ', "_");
    for (layer, file, function) in [("F.Cu", "F_Cu", "Copper,L1,Top"), ("B.Cu", "B_Cu", "Copper,L2,Bot")] {
        let mut g = Gerber::new();
        // Zone fills first, as hole-free regions.
        for z in p.board.zones.iter().filter(|z| z.layer == layer) {
            g.attr(&format!("TO.N,{}", sanitize(&p.net_name(z.net))));
            for s in &z.filled {
                for ring in fracture(s) {
                    g.region(&ring);
                }
            }
            g.attr("TD");
        }
        pads_layer(p, &mut g, layer, 0, false);
        for t in p.board.tracks.iter().filter(|t| t.layer == layer) {
            let d = g.aperture(format!("C,{}", mmstr(t.width)), "Conductor");
            g.attr(&format!("TO.N,{}", sanitize(&p.net_name(t.net))));
            g.draw(d, t.start, t.end);
            g.attr("TD");
        }
        for v in &p.board.vias {
            let d = g.aperture(format!("C,{}", mmstr(v.diameter)), "ViaPad");
            g.attr(&format!("TO.N,{}", sanitize(&p.net_name(v.net))));
            g.flash(d, v.at);
            g.attr("TD");
        }
        out.insert(format!("{base}-{file}.gbr"), g.finish(&p.name, function, "Positive"));
    }
    for (layer, file, function) in [("F.Mask", "F_Mask", "Soldermask,Top"), ("B.Mask", "B_Mask", "Soldermask,Bot")] {
        let mut g = Gerber::new();
        pads_layer(p, &mut g, layer, MASK_MARGIN, false);
        out.insert(format!("{base}-{file}.gbr"), g.finish(&p.name, function, "Negative"));
    }
    for (layer, file, function) in [("F.Paste", "F_Paste", "Paste,Top"), ("B.Paste", "B_Paste", "Paste,Bot")] {
        let mut g = Gerber::new();
        pads_layer(p, &mut g, layer, 0, true);
        out.insert(format!("{base}-{file}.gbr"), g.finish(&p.name, function, "Positive"));
    }
    let mut g = Gerber::new();
    let d = g.aperture("C,0.05".into(), "Profile");
    for (a, b) in ring_edges(&p.board.outline) {
        g.draw(d, a, b);
    }
    for c in &p.board.cutouts {
        g.select(d);
        let start = Pt::new(c.center.x + c.radius, c.center.y);
        let _ = writeln!(g.body, "G75*");
        let _ = writeln!(g.body, "{}D02*", xy(start));
        let _ = writeln!(g.body, "G03{}I{}J0D01*", xy(start), -c.radius);
        let _ = writeln!(g.body, "G01*");
    }
    out.insert(format!("{base}-Edge_Cuts.gbr"), g.finish(&p.name, "Profile,NP", "Positive"));
    out
}

fn drill_file(holes: &[(Nm, Pt)], plated: bool) -> String {
    let mut tools: BTreeMap<Nm, Vec<Pt>> = BTreeMap::new();
    for (d, at) in holes {
        tools.entry(*d).or_default().push(*at);
    }
    let mut o = String::new();
    let _ = writeln!(o, "M48");
    let _ = writeln!(o, "; DRILL file {{ViaForm viaform-pcb {}}}", env!("CARGO_PKG_VERSION"));
    let _ = writeln!(o, "; FORMAT={{-:-/ absolute / metric / decimal}}");
    let _ = writeln!(o, "; #@! TF.FileFunction,{},1,2,{}", if plated { "Plated" } else { "NonPlated" }, if plated { "PTH" } else { "NPTH" });
    let _ = writeln!(o, "FMAT,2");
    let _ = writeln!(o, "METRIC");
    for (i, d) in tools.keys().enumerate() {
        let _ = writeln!(o, "T{}C{:.3}", i + 1, *d as f64 / 1e6);
    }
    let _ = writeln!(o, "%");
    let _ = writeln!(o, "G90");
    let _ = writeln!(o, "G05");
    for (i, (_, pts)) in tools.iter().enumerate() {
        let _ = writeln!(o, "T{}", i + 1);
        let mut pts = pts.clone();
        pts.sort();
        for at in pts {
            let _ = writeln!(o, "X{:.3}Y{:.3}", at.x as f64 / 1e6, -(at.y as f64) / 1e6);
        }
    }
    let _ = writeln!(o, "T0");
    let _ = writeln!(o, "M30");
    o
}

/// Excellon drill files: plated (pads and vias) and non plated.
pub fn drills(p: &Project) -> BTreeMap<String, String> {
    let (mut pth, mut npth) = (vec![], vec![]);
    for f in &p.board.footprints {
        for pad in &f.pads {
            if let Some(d) = pad.drill {
                let at = f.pad_position(pad);
                if pad.kind == PadKind::Npth { npth.push((d, at)) } else { pth.push((d, at)) }
            }
        }
    }
    for v in &p.board.vias {
        pth.push((v.drill, v.at));
    }
    let base = sanitize(&p.name).replace(' ', "_");
    let mut out = BTreeMap::new();
    out.insert(format!("{base}-PTH.drl"), drill_file(&pth, true));
    out.insert(format!("{base}-NPTH.drl"), drill_file(&npth, false));
    out
}

fn csv(s: &str) -> String {
    if s.contains([',', '"', '\n']) { format!("\"{}\"", s.replace('"', "\"\"")) } else { s.to_string() }
}

/// Natural order for references: R2 before R10.
pub fn ref_key(r: &str) -> (String, u64, String) {
    let pre: String = r.chars().take_while(|c| !c.is_ascii_digit()).collect();
    let rest = &r[pre.len()..];
    let num: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    (pre, num.parse().unwrap_or(0), rest[num.len()..].to_string())
}

/// Bill of materials: one line per value and footprint, references in natural order.
pub fn bom_csv(p: &Project) -> String {
    let mut groups: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
    for c in &p.components {
        if p.symbol_of(c).map(|s| s.power).unwrap_or(false) {
            continue;
        }
        groups.entry((c.value.clone(), c.footprint.clone().unwrap_or_default())).or_default().push(c.reference.clone());
    }
    let mut rows: Vec<(Vec<String>, String, String)> = groups
        .into_iter()
        .map(|((v, f), mut r)| {
            r.sort_by_key(|x| ref_key(x));
            (r, v, f)
        })
        .collect();
    rows.sort_by_key(|(r, _, _)| ref_key(&r[0]));
    let mut o = String::from("Item,Quantity,References,Value,Footprint\n");
    for (i, (r, v, f)) in rows.iter().enumerate() {
        let _ = writeln!(o, "{},{},{},{},{}", i + 1, r.len(), csv(&r.join(" ")), csv(v), csv(f));
    }
    o
}

/// Pick and place: position in millimetres in the Gerber frame (y up), rotation in degrees.
pub fn pnp_csv(p: &Project) -> String {
    let mut rows: Vec<(String, String)> = vec![];
    for f in &p.board.footprints {
        let Some(c) = p.component(f.component) else { continue };
        let line = format!(
            "{},{},{},{},{},{},{}",
            csv(&c.reference),
            csv(&c.value),
            csv(&f.name),
            mmstr(f.position.x),
            mmstr(-f.position.y),
            to_deg(f.rotation),
            if f.side == Side::Front { "top" } else { "bottom" }
        );
        rows.push((c.reference.clone(), line));
    }
    rows.sort_by_key(|(r, _)| ref_key(r));
    let mut o = String::from("Ref,Val,Package,PosX,PosY,Rot,Side\n");
    for (_, l) in rows {
        o.push_str(&l);
        o.push('\n');
    }
    o
}
