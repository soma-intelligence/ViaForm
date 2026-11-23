//! Command facade, rule checks, router features and zones.

use serde_json::{json, Value};
use viaform_pcb::Session;

fn id(v: Value) -> u64 {
    v["result"]["id"].as_u64().unwrap()
}

fn codes(findings: &Value) -> Vec<String> {
    findings.as_array().unwrap().iter().map(|f| f["code"].as_str().unwrap().to_string()).collect()
}

/// Two resistors wired R1.2 to R2.1, on the board.
fn two_resistors() -> (Session, u64, u64) {
    let mut s = Session::new();
    let a = id(s.call("component.add", &json!({"kind": "resistor", "position": {"x": 0, "y": 0}})).unwrap());
    let b = id(s.call("component.add", &json!({"kind": "resistor", "position": {"x": 20, "y": 0}})).unwrap());
    s.call("wire.connect", &json!({"from": {"component": a, "pin": "2"}, "to": {"component": b, "pin": "1"}})).unwrap();
    s.call("board.sync", &json!({})).unwrap();
    (s, a, b)
}

fn fp_of(s: &Session, component: u64) -> u64 {
    s.project.board.footprints.iter().find(|f| f.component == component).unwrap().id
}

#[test]
fn component_add_replies_with_id_and_annotates() {
    let mut s = Session::new();
    let r: Value = serde_json::from_str(&s.execute("component.add", r#"{"kind":"resistor","position":{"x":2.54,"y":0}}"#)).unwrap();
    assert!(r["ok"]["result"]["id"].is_u64(), "{r}");
    s.call("component.add", &json!({"kind": "resistor", "position": {"x": 0, "y": 0}})).unwrap();
    let refs: Vec<String> = s.project.components.iter().map(|c| c.reference.clone()).collect();
    assert_eq!(refs, ["R1", "R2"]);
    let e: Value = serde_json::from_str(&s.execute("component.add", r#"{"kind":"warp_core","position":{"x":0,"y":0}}"#)).unwrap();
    assert!(e["error"].is_string());
    let e: Value = serde_json::from_str(&s.execute("no.such.command", "{}")).unwrap();
    assert_eq!(e["code"], "unknown_command");
}

#[test]
fn wire_makes_a_net_and_board_sync_puts_it_on_pads() {
    let (s, a, _) = two_resistors();
    let i = s.inspect();
    let wires = i["project"]["wires"].as_array().unwrap();
    assert_eq!(wires.len(), 1);
    let net = wires[0]["net"].as_u64().unwrap();
    assert!(net > 0);
    let f = s.project.board.footprints.iter().find(|f| f.component == a).unwrap();
    assert_eq!(f.pads.iter().find(|p| p.number == "2").unwrap().net, Some(net));
    assert_eq!(f.pads.iter().find(|p| p.number == "1").unwrap().net, None);
    assert_eq!(s.checks()["airwires"].as_array().unwrap().len(), 1);
}

#[test]
fn undo_redo_and_atomic_errors() {
    let mut s = Session::new();
    let r0 = s.revision;
    let a = id(s.call("component.add", &json!({"kind": "led", "position": {"x": 0, "y": 0}})).unwrap());
    s.call("component.move", &json!({"id": a, "position": {"x": 5, "y": 5}})).unwrap();
    assert_eq!(s.history(), (2, 0));
    s.call("undo", &json!({})).unwrap();
    assert_eq!(s.project.component(a).unwrap().position, viaform_pcb::geom::Pt::mm(0.0, 0.0));
    s.call("redo", &json!({})).unwrap();
    assert_eq!(s.project.component(a).unwrap().position, viaform_pcb::geom::Pt::mm(5.0, 5.0));
    assert!(s.revision > r0);
    let before = s.project.clone();
    assert!(s.call("wire.connect", &json!({"from": {"component": a, "pin": "1"}, "to": {"component": a, "pin": "9"}})).is_err());
    assert_eq!(s.project, before);
    assert_eq!(s.history(), (2, 0));
    s.call("undo", &json!({})).unwrap();
    s.call("undo", &json!({})).unwrap();
    assert!(s.project.components.is_empty());
    assert!(s.call("undo", &json!({})).is_err());
    let i = s.inspect();
    assert_eq!(i["history"]["redo"], 2);
}

#[test]
fn delete_component_removes_wires_and_footprint() {
    let (mut s, a, _) = two_resistors();
    s.call("object.delete", &json!({"id": a})).unwrap();
    assert!(s.project.wires.is_empty());
    assert_eq!(s.project.board.footprints.len(), 1);
    assert!(s.call("object.delete", &json!({"id": 99999})).is_err());
}

#[test]
fn commands_listing_covers_the_swift_surface() {
    let list = viaform_pcb::commands();
    let ids: Vec<&str> = list.as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap()).collect();
    for want in [
        "component.add", "component.move", "component.rotate", "component.place_library", "component.place_custom", "footprint.move",
        "footprint.rotate", "footprint.assign", "footprint.assign_custom", "object.delete", "board.sync", "track.route", "track.add",
        "wire.connect", "net.create", "net.connect", "board.resize", "board.cutout.add", "file.open", "file.save", "file.export_kicad",
        "project.rename", "library.symbol.upsert", "library.footprint.upsert", "undo", "redo",
    ] {
        assert!(ids.contains(&want), "missing {want}");
    }
}

#[test]
fn kicad_library_parts_are_placed() {
    let dir = std::env::temp_dir().join(format!("viaform-pcb-lib-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sym = dir.join("lib.kicad_sym");
    std::fs::write(
        &sym,
        r#"(kicad_symbol_lib (version 20231120) (generator "t")
  (symbol "Q" (property "Reference" "Q" (at 0 0 0)) (property "Value" "NPN" (at 0 0 0))
    (symbol "Q_0_1" (pin input line (at -5.08 0 0) (length 2.54) (name "B") (number "1"))
      (pin passive line (at 2.54 5.08 270) (length 2.54) (name "C") (number "2"))
      (pin passive line (at 2.54 -5.08 90) (length 2.54) (name "E") (number "3")))))"#,
    )
    .unwrap();
    let modf = dir.join("TO92.kicad_mod");
    std::fs::write(
        &modf,
        r#"(footprint "TO-92" (layer "F.Cu")
  (pad "1" thru_hole rect (at 0 0) (size 1.3 1.3) (drill 0.75) (layers "*.Cu" "*.Mask"))
  (pad "2" thru_hole oval (at 1.27 -1.27) (size 1.3 1.3) (drill 0.75) (layers "*.Cu" "*.Mask"))
  (pad "3" thru_hole oval (at 2.54 0) (size 1.3 1.3) (drill 0.75) (layers "*.Cu" "*.Mask")))"#,
    )
    .unwrap();
    let mut s = Session::new();
    let q = id(s.call("component.place_library", &json!({"path": sym.to_str().unwrap(), "symbol": "Q", "position": {"x": 0, "y": 0}})).unwrap());
    s.call("footprint.assign", &json!({"id": q, "path": modf.to_str().unwrap()})).unwrap();
    s.call("board.sync", &json!({})).unwrap();
    assert_eq!(s.project.component(q).unwrap().reference, "Q1");
    assert_eq!(s.project.board.footprints[0].pads.len(), 3);
    // A footprint without the symbol's pads is refused.
    let two = dir.join("two.kicad_mod");
    std::fs::write(&two, r#"(footprint "TWO" (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu")))"#).unwrap();
    assert!(s.call("footprint.assign", &json!({"id": q, "path": two.to_str().unwrap()})).is_err());
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn erc_finds_unconnected_and_conflicting_drivers() {
    let mut s = Session::new();
    let sym = json!({"name": "BUF", "reference": "U", "pins": [
        {"number": "1", "name": "IN", "position": {"x": -5, "y": 0}, "electrical_type": "input"},
        {"number": "2", "name": "OUT", "position": {"x": 5, "y": 0}, "electrical_type": "output"},
        {"number": "3", "name": "VCC", "position": {"x": 0, "y": 5}, "electrical_type": "power_in"}]});
    s.call("library.symbol.upsert", &json!({"definition": sym})).unwrap();
    let a = id(s.call("component.place_custom", &json!({"name": "BUF", "position": {"x": 0, "y": 0}})).unwrap());
    let b = id(s.call("component.place_custom", &json!({"name": "BUF", "position": {"x": 20, "y": 0}})).unwrap());
    s.call("wire.connect", &json!({"from": {"component": a, "pin": "2"}, "to": {"component": b, "pin": "2"}})).unwrap();
    s.call("wire.connect", &json!({"from": {"component": a, "pin": "3"}, "to": {"component": b, "pin": "3"}})).unwrap();
    let erc = codes(&s.checks()["erc"]);
    assert!(erc.contains(&"driver_conflict".to_string()), "{erc:?}");
    assert!(erc.contains(&"pin_unconnected".to_string()));
    assert!(erc.contains(&"power_not_driven".to_string()));
    assert!(erc.contains(&"footprint_missing".to_string()));
    // A power symbol on the VCC net is its source; no-connect flags silence the inputs.
    let pwr = id(s.call("component.add", &json!({"kind": "power", "value": "VCC", "position": {"x": 0, "y": 10}})).unwrap());
    s.call("wire.connect", &json!({"from": {"component": pwr, "pin": "1"}, "to": {"component": a, "pin": "3"}})).unwrap();
    s.call("component.no_connect", &json!({"component": a, "pin": "1"})).unwrap();
    s.call("component.no_connect", &json!({"component": b, "pin": "1"})).unwrap();
    let erc = codes(&s.checks()["erc"]);
    assert!(!erc.contains(&"power_not_driven".to_string()) && !erc.contains(&"pin_unconnected".to_string()), "{erc:?}");
    let vcc = s.project.net_by_name("VCC").expect("power symbol names its net");
    assert!(vcc.named);
}

#[test]
fn drc_catches_each_rule() {
    let (mut s, a, b) = two_resistors();
    let (fa, fb) = (fp_of(&s, a), fp_of(&s, b));
    s.call("board.resize", &json!({"width": 40, "height": 30})).unwrap();
    s.call("footprint.move", &json!({"id": fa, "position": {"x": 10, "y": 10}})).unwrap();
    s.call("footprint.move", &json!({"id": fb, "position": {"x": 25, "y": 10}})).unwrap();
    let drc = codes(&s.checks()["drc"]);
    assert_eq!(drc, ["unrouted"]);
    let net = s.project.wires[0].net;
    // A narrow track from R1.2 (12.54, 10) to R2.1 (22.46, 10): connects, but under min width.
    let t = id(s.call("track.add", &json!({"net": net, "start": {"x": 12.54, "y": 10}, "end": {"x": 22.46, "y": 10}, "width": 0.1})).unwrap());
    let drc = codes(&s.checks()["drc"]);
    assert_eq!(drc, ["track_width"], "{drc:?}");
    s.call("object.delete", &json!({"id": t})).unwrap();
    // A track of the net through R1 pad 1 (no net) is a short; near it, a clearance error.
    s.call("track.add", &json!({"net": net, "start": {"x": 7.46, "y": 8}, "end": {"x": 7.46, "y": 12}, "width": 0.3})).unwrap();
    s.call("track.add", &json!({"net": net, "start": {"x": 8.5, "y": 6}, "end": {"x": 8.5, "y": 14}, "width": 0.3})).unwrap();
    let drc = codes(&s.checks()["drc"]);
    assert!(drc.contains(&"short".to_string()) && drc.contains(&"clearance".to_string()), "{drc:?}");
    // Edge clearance and copper outside the board.
    s.call("track.add", &json!({"net": net, "start": {"x": 39.9, "y": 5}, "end": {"x": 39.9, "y": 6}, "width": 0.3})).unwrap();
    s.call("track.add", &json!({"net": net, "start": {"x": 45, "y": 5}, "end": {"x": 46, "y": 5}, "width": 0.3})).unwrap();
    let drc = codes(&s.checks()["drc"]);
    assert!(drc.contains(&"edge_clearance".to_string()) && drc.contains(&"outside_board".to_string()), "{drc:?}");
    // Via rules: annular ring and hole to hole.
    s.call("via.add", &json!({"net": net, "at": {"x": 30, "y": 20}, "diameter": 0.4, "drill": 0.3})).unwrap();
    s.call("via.add", &json!({"net": net, "at": {"x": 30.45, "y": 20}, "diameter": 0.4, "drill": 0.3})).unwrap();
    let drc = codes(&s.checks()["drc"]);
    assert!(drc.contains(&"annular_ring".to_string()) && drc.contains(&"hole_to_hole".to_string()), "{drc:?}");
    // A cutout under a pad.
    s.call("board.cutout.add", &json!({"center": {"x": 25, "y": 10}, "radius": 1})).unwrap();
    assert!(codes(&s.checks()["drc"]).contains(&"edge_clearance".to_string()));
}

#[test]
fn net_classes_widen_clearance() {
    let (mut s, a, b) = two_resistors();
    s.call("footprint.move", &json!({"id": fp_of(&s, a), "position": {"x": 10, "y": 10}})).unwrap();
    s.call("footprint.move", &json!({"id": fp_of(&s, b), "position": {"x": 25, "y": 10}})).unwrap();
    let net = s.project.wires[0].net;
    s.call("track.add", &json!({"net": net, "start": {"x": 12.54, "y": 10}, "end": {"x": 22.46, "y": 10}})).unwrap();
    // R1 pad 1 sits 5.08 mm from pad 2: a 6 mm class clearance makes that a violation.
    s.call("netclass.set", &json!({"name": "HV", "clearance": 6, "track_width": 0.5})).unwrap();
    s.call("net.set_class", &json!({"net": net, "class": "HV"})).unwrap();
    assert!(codes(&s.checks()["drc"]).contains(&"clearance".to_string()));
}

/// A one-pad SMD part, for router scenarios.
fn smd_parts(s: &mut Session) {
    s.call("library.symbol.upsert", &json!({"definition": {"name": "TP", "reference": "TP", "pins": [{"number": "1", "name": "T", "position": {"x": 0, "y": 0}}]}})).unwrap();
    s.call("library.footprint.upsert", &json!({"definition": {"name": "TP_SMD", "pads": [{"number": "1", "pad_type": "smd", "shape": "rect", "position": {"x": 0, "y": 0}, "size": {"x": 1, "y": 1}}]}})).unwrap();
}

fn test_points(s: &mut Session, pairs: &[((f64, f64), (f64, f64))]) {
    smd_parts(s);
    let mut placed = vec![];
    for (k, (p, q)) in pairs.iter().enumerate() {
        let mut ids = vec![];
        for at in [p, q] {
            let c = id(s.call("component.place_custom", &json!({"name": "TP", "position": {"x": 0, "y": 0}})).unwrap());
            s.call("footprint.assign_custom", &json!({"id": c, "name": "TP_SMD"})).unwrap();
            ids.push((c, *at));
        }
        let net = id(s.call("net.create", &json!({"name": format!("N{k}")})).unwrap());
        s.call("net.connect", &json!({"net": net, "pins": ids.iter().map(|(c, _)| json!({"component": c, "pin": "1"})).collect::<Vec<_>>()})).unwrap();
        placed.extend(ids);
    }
    s.call("board.sync", &json!({})).unwrap();
    for (c, at) in placed {
        let f = fp_of(s, c);
        s.call("footprint.move", &json!({"id": f, "position": {"x": at.0, "y": at.1}})).unwrap();
    }
}

fn wall(s: &mut Session, x0: f64, y0: f64, x1: f64, y1: f64) {
    s.call("keepout.add", &json!({"points": [[x0, y0], [x1, y0], [x1, y1], [x0, y1]], "layers": ["F.Cu"], "vias": true})).unwrap();
}

#[test]
fn router_uses_vias_to_cross_a_wall() {
    let mut s = Session::new();
    s.call("board.resize", &json!({"width": 50, "height": 40})).unwrap();
    test_points(&mut s, &[((10.0, 20.0), (40.0, 20.0))]);
    wall(&mut s, 24.0, 0.0, 26.0, 40.0);
    let r = s.call("route.auto", &json!({})).unwrap();
    assert_eq!(r["result"]["routed"], 1, "{r}");
    assert_eq!(r["result"]["vias"], 2, "{r}");
    assert!(s.project.board.tracks.iter().any(|t| t.layer == "B.Cu"));
    let c = s.checks();
    assert!(c["drc"].as_array().unwrap().is_empty(), "{:#}", c["drc"]);
    // No track crosses the wall on the front.
    for t in s.project.board.tracks.iter().filter(|t| t.layer == "F.Cu") {
        assert!(t.start.x.max(t.end.x) < 24_000_000 || t.start.x.min(t.end.x) > 26_000_000, "{t:?}");
    }
    // Without vias, one layer cannot do it.
    s.call("route.clear", &json!({})).unwrap();
    let r = s.call("route.auto", &json!({"layers": ["F.Cu"], "vias": false})).unwrap();
    assert_eq!(r["result"]["failed"].as_array().unwrap().len(), 1);
}

#[test]
fn router_rips_up_and_retries() {
    // One layer. A wall across the board at y 20 with two one-track gaps, M (x 25) and L (x 5).
    // B's top pad sits in a fence that opens only onto M. A's top pad reaches M through a
    // one-track slit under the fence. A is shorter, goes first and takes the slit and M, which
    // leaves B nothing: B must rip A up, and A must then go round by L.
    let setup = |s: &mut Session| {
        s.call("board.resize", &json!({"width": 50, "height": 40})).unwrap();
        test_points(s, &[((20.0, 15.0), (22.0, 24.0)), ((25.0, 14.0), (25.0, 26.0))]);
        wall(s, 0.0, 19.5, 4.6, 20.5);
        wall(s, 5.4, 19.5, 24.6, 20.5);
        wall(s, 25.4, 19.5, 50.0, 20.5);
        wall(s, 23.0, 10.0, 23.5, 18.5);
        wall(s, 26.5, 10.0, 27.0, 19.5);
        wall(s, 23.0, 9.5, 27.0, 10.0);
    };
    let mut s = Session::new();
    setup(&mut s);
    let r = s.call("route.auto", &json!({"layers": ["F.Cu"], "vias": false, "ripup": false})).unwrap();
    assert_eq!(r["result"]["failed"].as_array().unwrap().len(), 1, "{r}");
    let mut s = Session::new();
    setup(&mut s);
    let r = s.call("route.auto", &json!({"layers": ["F.Cu"], "vias": false})).unwrap();
    assert_eq!(r["result"]["routed"], 2, "{r}");
    assert!(r["result"]["ripups"].as_u64().unwrap() >= 1, "{r}");
    let c = s.checks();
    assert!(c["drc"].as_array().unwrap().is_empty() && c["airwires"].as_array().unwrap().is_empty(), "{c:#}");
}

#[test]
fn track_route_walks_around() {
    let mut s = Session::new();
    s.call("board.resize", &json!({"width": 40, "height": 30})).unwrap();
    test_points(&mut s, &[((5.0, 15.0), (35.0, 15.0)), ((20.0, 10.0), (20.0, 20.0))]);
    // The second net, routed straight across, sits in the way of the first.
    let n1 = s.project.net_by_name("N1").unwrap().id;
    s.call("track.add", &json!({"net": n1, "start": {"x": 20, "y": 10}, "end": {"x": 20, "y": 20}})).unwrap();
    let f = |s: &Session, i: usize| s.project.board.footprints[i].id;
    let r = s.call("track.route", &json!({"from": {"footprint": f(&s, 0), "pad": "1"}, "to": {"footprint": f(&s, 1), "pad": "1"}, "layer": "B.Cu"}));
    assert!(r.is_err(), "SMD pads on the front cannot be joined on the back");
    let r = s.call("track.route", &json!({"from": {"footprint": f(&s, 0), "pad": "1"}, "to": {"footprint": f(&s, 1), "pad": "1"}, "width": 0.25, "layer": "F.Cu"})).unwrap();
    assert!(r["result"]["ids"].as_array().unwrap().len() >= 3, "a detour has bends: {r}");
    let c = s.checks();
    assert!(c["airwires"].as_array().unwrap().is_empty(), "{:#}", c["airwires"]);
    assert!(c["drc"].as_array().unwrap().is_empty(), "{:#}", c["drc"]);
}

#[test]
fn zones_fill_with_clearance_and_thermals() {
    let (mut s, a, b) = two_resistors();
    s.call("board.resize", &json!({"width": 40, "height": 30})).unwrap();
    s.call("footprint.move", &json!({"id": fp_of(&s, a), "position": {"x": 10, "y": 15}})).unwrap();
    s.call("footprint.move", &json!({"id": fp_of(&s, b), "position": {"x": 30, "y": 15}})).unwrap();
    let net = s.project.wires[0].net;
    let z = id(s.call("zone.add", &json!({"net": net, "layer": "F.Cu", "points": [[0, 0], [40, 0], [40, 30], [0, 30]]})).unwrap());
    let zone = s.project.board.zones.iter().find(|x| x.id == z).unwrap();
    assert!(!zone.filled.is_empty());
    // The zone joins the two pads of its net on the front: nothing left to route.
    let c = s.checks();
    assert!(c["airwires"].as_array().unwrap().is_empty(), "{:#}", c["airwires"]);
    assert!(c["drc"].as_array().unwrap().is_empty(), "{:#}", c["drc"]);
    // Area: board minus edge band minus other-net pads, so well below the full 1200 mm2.
    let area: f64 = zone.filled.iter().map(viaform_pcb::geom::shape_area).sum::<f64>() / 1e12;
    assert!(area > 1000.0 && area < 1200.0, "{area}");
    // The fill appears in the front copper Gerber as regions.
    let g = viaform_pcb::fab::gerbers(&s.project);
    assert!(g.iter().find(|(k, _)| k.contains("F_Cu")).unwrap().1.contains("G36*"));
}

#[test]
fn stateless_facade() {
    let r = viaform_pcb::call("component.add", &json!({"params": {"kind": "capacitor", "position": {"x": 1, "y": 2}}})).unwrap();
    assert!(r["reply"]["result"]["id"].is_u64());
    let again = viaform_pcb::call("component.add", &json!({"project": r["project"], "params": {"kind": "capacitor", "position": {"x": 5, "y": 2}}})).unwrap();
    assert_eq!(again["project"]["components"].as_array().unwrap().len(), 2);
}
