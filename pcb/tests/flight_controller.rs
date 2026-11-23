//! Parity checklist (RUST-ENGINES 3B.3): the drone flight controller sample rebuilt end to end.

use serde_json::{json, Value};
use viaform_pcb::{fab, kicad, Session};

fn errors(findings: &Value) -> Vec<Value> {
    findings.as_array().unwrap().iter().filter(|f| f["severity"] == "error").cloned().collect()
}

fn routed_sample() -> (Session, Value) {
    let mut s = Session::sample();
    let r = s.call("route.auto", &json!({})).unwrap();
    (s, r["result"].clone())
}

#[test]
fn sample_schematic_is_drawn_and_erc_clean() {
    let s = Session::sample();
    let i = s.inspect();
    assert_eq!(i["project"]["name"], "Flight controller");
    assert_eq!(i["project"]["components"].as_array().unwrap().len(), 12);
    assert_eq!(i["project"]["nets"].as_array().unwrap().len(), 12);
    let c = s.checks();
    assert!(errors(&c["erc"]).is_empty(), "{:#}", c["erc"]);
    // Every pin of the sample is on a net.
    assert!(c["erc"].as_array().unwrap().iter().all(|f| f["code"] != "pin_unconnected"), "{:#}", c["erc"]);
}

#[test]
fn sample_board_is_updated_and_placed() {
    let s = Session::sample();
    let b = &s.inspect()["project"]["board"];
    assert_eq!(b["width"], 50.0);
    assert_eq!(b["cutouts"].as_array().unwrap().len(), 4);
    let fps = b["footprints"].as_array().unwrap();
    assert_eq!(fps.len(), 12);
    // Every pad has its net from the schematic.
    for f in fps {
        for p in f["pads"].as_array().unwrap() {
            assert!(p["net"].is_u64(), "pad without net in {f}");
        }
    }
    // Before routing, airwires connect every net.
    assert!(s.checks()["airwires"].as_array().unwrap().len() >= 20);
}

#[test]
fn sample_autoroutes_drc_clean() {
    let (s, r) = routed_sample();
    assert_eq!(r["failed"].as_array().unwrap().len(), 0, "{r:#}");
    assert_eq!(r["routed"], r["connections"]);
    let c = s.checks();
    assert!(c["airwires"].as_array().unwrap().is_empty(), "{:#}", c["airwires"]);
    let drc = c["drc"].as_array().unwrap();
    assert!(drc.is_empty(), "DRC not clean: {drc:#?}");
}

#[test]
fn autoroute_is_deterministic() {
    let (a, ra) = routed_sample();
    let (b, rb) = routed_sample();
    assert_eq!(ra, rb);
    assert_eq!(viaform_pcb::to_vfpcb(&a.project), viaform_pcb::to_vfpcb(&b.project));
    assert_eq!(fab::gerbers(&a.project), fab::gerbers(&b.project));
}

/// A small structural Gerber reader: every command ends with `*`, extended commands are in `%`
/// pairs, the header has FS and MO, apertures are defined before use, draws and flashes have
/// coordinates, regions close, and the file ends with M02.
fn check_gerber(name: &str, g: &str) -> usize {
    let mut defined = std::collections::BTreeSet::new();
    let (mut fs, mut mo, mut in_region, mut ended, mut ops) = (false, false, false, false, 0);
    for line in g.lines() {
        assert!(!ended, "{name}: data after M02");
        assert!(line.ends_with('*') || line.ends_with("*%"), "{name}: line without *: {line}");
        if line.starts_with('%') {
            assert!(line.ends_with("*%"), "{name}: bad extended command {line}");
            let body = &line[1..line.len() - 2];
            if body.starts_with("FSLAX46Y46") {
                fs = true;
            }
            if body == "MOMM" {
                mo = true;
            }
            if let Some(rest) = body.strip_prefix("ADD") {
                let n: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
                let tpl = &rest[n.len()..];
                assert!(tpl.starts_with("C,") || tpl.starts_with("R,") || tpl.starts_with("O,"), "{name}: template {tpl}");
                defined.insert(n.parse::<u32>().unwrap());
            }
            continue;
        }
        assert!(fs && mo, "{name}: operation before FS and MO");
        match line {
            "G36*" => {
                assert!(!in_region);
                in_region = true;
            }
            "G37*" => {
                assert!(in_region);
                in_region = false;
            }
            "M02*" => ended = true,
            "G01*" | "G75*" => {}
            l if l.starts_with("G04") => {}
            l if l.starts_with('D') && !l.starts_with("D0") => {
                let n: u32 = l[1..l.len() - 1].parse().unwrap();
                assert!(defined.contains(&n), "{name}: D{n} used before definition");
                assert!(!in_region, "{name}: aperture change in region");
            }
            l => {
                assert!(l.ends_with("D01*") || l.ends_with("D02*") || l.ends_with("D03*"), "{name}: unknown {l}");
                assert!(l.contains('X') && l.contains('Y'), "{name}: no coordinates {l}");
                if l.ends_with("D03*") {
                    assert!(!in_region);
                }
                ops += 1;
            }
        }
    }
    assert!(ended && !in_region, "{name}: missing M02 or open region");
    ops
}

#[test]
fn gerbers_and_drills_are_well_formed() {
    let (s, _) = routed_sample();
    let g = fab::gerbers(&s.project);
    for want in ["F_Cu", "B_Cu", "F_Mask", "B_Mask", "Edge_Cuts", "F_Paste", "B_Paste"] {
        assert!(g.keys().any(|k| k.contains(want)), "missing {want}");
    }
    for (name, body) in &g {
        let ops = check_gerber(name, body);
        if name.contains("_Cu") || name.contains("Mask") || name.contains("Edge") {
            assert!(ops > 0, "{name} is empty");
        }
        assert!(body.contains("%TF.FileFunction,"), "{name} lacks X2 file function");
    }
    let top = g.iter().find(|(k, _)| k.contains("F_Cu")).unwrap().1;
    assert!(top.contains("%TO.N,GND*%") && top.contains("%TA.AperFunction,ComponentPad*%"));
    let d = fab::drills(&s.project);
    let pth = d.iter().find(|(k, _)| k.contains("-PTH")).unwrap().1;
    assert!(pth.starts_with("M48\n") && pth.trim_end().ends_with("M30"));
    let pads: usize = s.project.board.footprints.iter().map(|f| f.pads.len()).sum();
    let hits = pth.lines().filter(|l| l.starts_with('X')).count();
    assert_eq!(hits, pads + s.project.board.vias.len());
    assert!(pth.contains("T1C0.800"));
}

#[test]
fn kicad_export_round_trips() {
    let (s, _) = routed_sample();
    let k = kicad::export_pcb(&s.project);
    assert!(k.starts_with("(kicad_pcb\n  (version 20240108)"));
    let parsed = viaform_pcb::sexpr::parse(&k).unwrap();
    assert_eq!(parsed.children("footprint").count(), 12);
    let back = kicad::import_pcb(&k).unwrap();
    assert_eq!(back.board.footprints.len(), 12);
    assert_eq!(back.board.tracks.len(), s.project.board.tracks.len());
    assert_eq!(back.board.vias.len(), s.project.board.vias.len());
    assert_eq!(back.board.cutouts.len(), 4);
    assert_eq!(back.board.width, s.project.board.width);
    // Pad positions survive the trip (rotated J6 included).
    let pos = |p: &viaform_pcb::Project| {
        let mut v: Vec<_> = p.board.footprints.iter().flat_map(|f| f.pads.iter().map(move |q| f.pad_position(q))).collect();
        v.sort();
        v
    };
    assert_eq!(pos(&back), pos(&s.project));
    // The reimported board keeps its connectivity: no airwires, no DRC errors.
    let c = viaform_pcb::checks::checks_json(&back);
    assert!(c["airwires"].as_array().unwrap().is_empty(), "{:#}", c["airwires"]);
    assert!(errors(&c["drc"]).is_empty(), "{:#}", c["drc"]);
}

#[test]
fn bom_and_pick_and_place() {
    let s = Session::sample();
    let bom = fab::bom_csv(&s.project);
    let lines: Vec<&str> = bom.lines().collect();
    assert_eq!(lines[0], "Item,Quantity,References,Value,Footprint");
    assert!(bom.contains(",1,J1,Battery 4S,FC_2P"));
    let qty: usize = lines[1..].iter().map(|l| l.split(',').nth(1).unwrap().parse::<usize>().unwrap()).sum();
    assert_eq!(qty, 12);
    let pnp = fab::pnp_csv(&s.project);
    assert!(pnp.lines().next().unwrap().starts_with("Ref,Val,Package,PosX,PosY,Rot,Side"));
    assert!(pnp.contains("J6,Receiver,FC_2P,44,-28,90,top"), "{pnp}");
    assert_eq!(pnp.lines().count(), 13);
}

#[test]
fn save_and_open_vfpcb() {
    let (mut s, _) = routed_sample();
    let dir = std::env::temp_dir().join(format!("viaform-pcb-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("board.vfpcb");
    s.call("file.save", &json!({"path": path.to_str().unwrap()})).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("\"format\": \"viaform-pcb\"") && text.contains("\"version\": 1"));
    let mut t = Session::new();
    t.call("file.open", &json!({"path": path.to_str().unwrap()})).unwrap();
    assert_eq!(t.project, s.project);
    // A file from a newer engine is refused, not misread.
    std::fs::write(&path, text.replace("\"version\": 1", "\"version\": 99")).unwrap();
    assert!(t.call("file.open", &json!({"path": path.to_str().unwrap()})).is_err());
    let out = s.call("export.fab", &json!({"dir": dir.join("fab").to_str().unwrap()})).unwrap();
    assert!(out["result"]["files"].as_array().unwrap().len() >= 11);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn link_geometry_for_send_to_3d() {
    let (mut s, _) = routed_sample();
    let g = s.call("link.geometry", &json!({})).unwrap()["result"].clone();
    assert_eq!(g["outline"].as_array().unwrap().len(), 4);
    assert_eq!(g["thickness"], 1.6);
    let pads: usize = s.project.board.footprints.iter().map(|f| f.pads.len()).sum();
    assert_eq!(g["holes"].as_array().unwrap().len(), pads + s.project.board.vias.len() + 4);
    assert_eq!(g["bodies"].as_array().unwrap().len(), 12);
    assert!(g["copper"]["F.Cu"].as_array().unwrap().len() > pads);
    // Bodies stay on the board.
    for b in g["bodies"].as_array().unwrap() {
        assert!(b["min"]["x"].as_f64().unwrap() >= 0.0 && b["max"]["y"].as_f64().unwrap() <= 50.0, "{b}");
    }
}
