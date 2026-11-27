//! The drone flight controller sample (ViaForm's own sample from `electron/src/test/drone.ts`),
//! drawn through the command facade: battery in through a 5 V regulator to the MCU and the IMU
//! (I2C), four ESC outputs, a receiver input and a status LED, placed on a 50 mm board.

use crate::engine::Session;
use crate::error::Result;
use serde_json::{json, Value};

const MCU_PINS: [&str; 10] = ["VDD", "GND", "M1", "M2", "M3", "M4", "SDA", "SCL", "RX", "LED"];
const IMU_PINS: [&str; 4] = ["VDD", "GND", "SDA", "SCL"];
const REG_PINS: [&str; 3] = ["VIN", "GND", "VOUT"];

pub const BOARD_SIZE: f64 = 50.0;
pub const HOLE_SPACING: f64 = 30.5;
pub const TRACK: f64 = 0.3;

/// A through-hole package: a symbol with pins left and right and a footprint of one or two rows
/// on a 2.54 mm pitch.
fn package(name: &str, reference: &str, value: &str, pins: &[&str], rows: usize) -> (Value, Value) {
    let n = pins.len();
    let per = if rows == 2 { n.div_ceil(2) } else { n };
    let (pitch, span) = (2.54, if rows == 2 { 7.62 } else { 0.0 });
    let place = |i: usize| {
        let right = rows == 2 && i >= per;
        let row = if right { n - 1 - i } else { i };
        (right, row as f64 * pitch - (per as f64 - 1.0) * pitch / 2.0)
    };
    let sym_pins: Vec<Value> = pins
        .iter()
        .enumerate()
        .map(|(i, pin)| {
            let (right, y) = place(i);
            json!({"number": (i + 1).to_string(), "name": pin, "position": {"x": if right { 7.62 } else { -7.62 }, "y": y},
                   "angle": if right { 180 } else { 0 }, "length": 2.54, "electrical_type": "passive"})
        })
        .collect();
    let symbol = json!({"name": name, "reference": reference, "value": value, "description": format!("{value} (ViaForm drone sample)"),
                        "footprint": name, "pins": sym_pins});
    let pads: Vec<Value> = (0..n)
        .map(|i| {
            let (right, y) = place(i);
            json!({"number": (i + 1).to_string(), "pad_type": "thru_hole", "shape": if i == 0 { "rect" } else { "circle" },
                   "position": {"x": if right { span / 2.0 } else { -span / 2.0 }, "y": y}, "rotation": 0,
                   "size": {"x": 1.6, "y": 1.6}, "drill": {"size": {"x": 0.8, "y": 0.8}}})
        })
        .collect();
    let footprint = json!({"name": name, "description": format!("{}-{n}", if rows == 2 { "DIP" } else { "SIP" }), "pads": pads});
    (symbol, footprint)
}

fn two_pin() -> Value {
    let pads: Vec<Value> = [-2.54, 2.54]
        .iter()
        .enumerate()
        .map(|(i, x)| {
            json!({"number": (i + 1).to_string(), "pad_type": "thru_hole", "shape": "circle", "position": {"x": x, "y": 0}, "rotation": 0,
                   "size": {"x": 1.6, "y": 1.6}, "drill": {"size": {"x": 0.8, "y": 0.8}}})
        })
        .collect();
    json!({"name": "FC_2P", "description": "2-pin THT, 5.08 mm", "pads": pads})
}

/// Where each part sits on the board (x right, y down, mm) and its rotation in degrees.
pub const LAYOUT: [(&str, f64, f64, f64); 12] = [
    ("U1", 25.0, 27.0, 0.0),
    ("U2", 36.0, 28.0, 0.0),
    ("U3", 13.0, 25.0, 0.0),
    ("J1", 14.0, 35.0, 0.0),
    ("J2", 19.0, 5.0, 0.0),
    ("J3", 31.0, 5.0, 0.0),
    ("J4", 19.0, 45.0, 0.0),
    ("J5", 31.0, 45.0, 0.0),
    ("J6", 44.0, 28.0, 90.0),
    ("C1", 13.0, 14.0, 0.0),
    ("R1", 25.0, 13.0, 0.0),
    ("D1", 36.0, 15.0, 0.0),
];

fn id_of(v: &Value) -> u64 {
    v["result"]["id"].as_u64().expect("created id")
}

/// Draws and places the flight controller in `s`.
pub fn build_flight_controller(s: &mut Session) -> Result<()> {
    s.call("project.rename", &json!({"name": "Flight controller"}))?;
    for (name, r, value, pins, rows) in [
        ("FC_MCU", "U", "Flight MCU", &MCU_PINS[..], 2),
        ("FC_IMU", "U", "6-axis IMU", &IMU_PINS[..], 1),
        ("FC_REG", "U", "5 V regulator", &REG_PINS[..], 1),
    ] {
        let (sym, fp) = package(name, r, value, pins, rows);
        s.call("library.symbol.upsert", &json!({"definition": sym, "notice": "Original ViaForm sample part"}))?;
        s.call("library.footprint.upsert", &json!({"definition": fp}))?;
    }
    s.call("library.footprint.upsert", &json!({"definition": two_pin()}))?;

    let mut ids: Vec<(&str, u64)> = vec![];
    for (name, r) in [("FC_MCU", "U1"), ("FC_IMU", "U2"), ("FC_REG", "U3")] {
        let id = id_of(&s.call("component.place_custom", &json!({"name": name, "position": {"x": 0, "y": 0}, "reference": r}))?);
        s.call("footprint.assign_custom", &json!({"id": id, "name": name}))?;
        ids.push((r, id));
    }
    for (kind, r, value) in [
        ("connector", "J1", "Battery 4S"),
        ("connector", "J2", "ESC 1"),
        ("connector", "J3", "ESC 2"),
        ("connector", "J4", "ESC 3"),
        ("connector", "J5", "ESC 4"),
        ("connector", "J6", "Receiver"),
        ("capacitor", "C1", "10 \u{b5}F"),
        ("resistor", "R1", "1 k\u{3a9}"),
        ("led", "D1", "Status"),
    ] {
        let id = id_of(&s.call("component.add", &json!({"kind": kind, "position": {"x": 0, "y": 0}, "reference": r, "value": value}))?);
        s.call("footprint.assign_custom", &json!({"id": id, "name": "FC_2P"}))?;
        ids.push((r, id));
    }
    for (i, (_, id)) in ids.iter().enumerate() {
        s.call("component.move", &json!({"id": id, "position": {"x": (i % 4) as f64 * 30.0, "y": (i / 4) as f64 * 30.0}}))?;
    }
    let cid = |r: &str| ids.iter().find(|x| x.0 == r).unwrap().1;
    let pin_named = |s: &Session, r: &str, name: &str| -> Value {
        let c = s.project.component(cid(r)).unwrap();
        let sym = s.project.symbol_of(c).unwrap();
        let p = sym.pins.iter().find(|p| p.name == name).unwrap();
        json!({"component": c.id, "pin": p.number})
    };
    let pin_at = |s: &Session, r: &str, i: usize| -> Value {
        let c = s.project.component(cid(r)).unwrap();
        let sym = s.project.symbol_of(c).unwrap();
        json!({"component": c.id, "pin": sym.pins[i].number})
    };
    let nets: Vec<(String, Vec<Value>)> = {
        let s = &*s;
        let mut v = vec![
            ("VBAT".to_string(), vec![pin_at(s, "J1", 0), pin_named(s, "U3", "VIN")]),
            ("5V".to_string(), vec![pin_named(s, "U3", "VOUT"), pin_named(s, "U1", "VDD"), pin_named(s, "U2", "VDD"), pin_at(s, "C1", 0)]),
        ];
        let mut gnd = vec![pin_at(s, "J1", 1), pin_named(s, "U3", "GND"), pin_named(s, "U1", "GND"), pin_named(s, "U2", "GND"), pin_at(s, "C1", 1), pin_at(s, "D1", 1)];
        for j in ["J2", "J3", "J4", "J5", "J6"] {
            gnd.push(pin_at(s, j, 1));
        }
        v.push(("GND".to_string(), gnd));
        for (i, j) in ["J2", "J3", "J4", "J5"].iter().enumerate() {
            v.push((format!("M{}", i + 1), vec![pin_named(s, "U1", &format!("M{}", i + 1)), pin_at(s, j, 0)]));
        }
        v.push(("SDA".into(), vec![pin_named(s, "U1", "SDA"), pin_named(s, "U2", "SDA")]));
        v.push(("SCL".into(), vec![pin_named(s, "U1", "SCL"), pin_named(s, "U2", "SCL")]));
        v.push(("RX".into(), vec![pin_named(s, "U1", "RX"), pin_at(s, "J6", 0)]));
        v.push(("LED".into(), vec![pin_named(s, "U1", "LED"), pin_at(s, "R1", 0)]));
        v.push(("LED_K".into(), vec![pin_at(s, "R1", 1), pin_at(s, "D1", 0)]));
        v
    };
    for (name, pins) in nets {
        let id = id_of(&s.call("net.create", &json!({"name": name}))?);
        s.call("net.connect", &json!({"net": id, "pins": pins}))?;
    }
    s.call("board.resize", &json!({"width": BOARD_SIZE, "height": BOARD_SIZE}))?;
    let m = (BOARD_SIZE - HOLE_SPACING) / 2.0;
    for (x, y) in [(m, m), (BOARD_SIZE - m, m), (m, BOARD_SIZE - m), (BOARD_SIZE - m, BOARD_SIZE - m)] {
        s.call("board.cutout.add", &json!({"center": {"x": x, "y": y}, "radius": 1.6}))?;
    }
    s.call("board.sync", &json!({}))?;
    for (r, x, y, deg) in LAYOUT {
        let c = cid(r);
        let f = s.project.board.footprints.iter().find(|f| f.component == c).unwrap().id;
        s.call("footprint.move", &json!({"id": f, "position": {"x": x, "y": y}}))?;
        if deg != 0.0 {
            s.call("footprint.rotate", &json!({"id": f, "degrees": deg}))?;
        }
    }
    Ok(())
}
