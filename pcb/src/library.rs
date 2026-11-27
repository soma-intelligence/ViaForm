//! Parts library: the built-in kinds and the project library entries (symbols and footprints).
//!
//! Built-in parts are original ViaForm drawings: two-pin passives, an LED, a diode, a two-pin
//! header and power symbols. Project parts come from `library.*.upsert` definitions (JSON) or
//! from KiCad library files (`crate::kicad`).

use crate::error::{EngineError, Result};
use crate::geom::{mdeg, mm, Nm, Pt};
use crate::model::*;
use serde_json::Value;

pub const BUILTIN_KINDS: [&str; 7] = ["resistor", "capacitor", "inductor", "led", "diode", "connector", "power"];

fn pin(number: &str, name: &str, x: f64, kind: PinKind) -> SymbolPin {
    SymbolPin { number: number.into(), name: name.into(), position: Pt::mm(x, 0.0), kind }
}

fn two_pad(name: &str, pitch: f64, first_square: bool) -> FootprintDef {
    let h = pitch / 2.0;
    FootprintDef {
        name: name.into(),
        description: format!("2-pin through hole, {pitch} mm pitch"),
        pads: [-h, h]
            .iter()
            .enumerate()
            .map(|(i, x)| PadDef {
                number: (i + 1).to_string(),
                kind: PadKind::Tht,
                shape: if i == 0 && first_square { PadShape::Rect } else { PadShape::Circle },
                offset: Pt::mm(*x, 0.0),
                size: Pt::mm(1.6, 1.6),
                rotation: 0,
                drill: Some(mm(0.8)),
            })
            .collect(),
    }
}

fn two_pin_symbol(name: &str, prefix: &str, value: &str, pins: [(&str, &str); 2], fp: &str) -> SymbolDef {
    SymbolDef {
        name: name.into(),
        reference_prefix: prefix.into(),
        value: value.into(),
        description: format!("Built-in {name}"),
        footprint: Some(fp.into()),
        pins: vec![pin(pins[0].0, pins[0].1, -5.08, PinKind::Passive), pin(pins[1].0, pins[1].1, 5.08, PinKind::Passive)],
        body: Pt::mm(2.54, 1.27),
        power: false,
    }
}

pub fn builtin_library() -> Library {
    let mut lib = Library::default();
    for fp in [two_pad("VF_2P_THT_P5.08", 5.08, false), two_pad("VF_LED_THT_P2.54", 2.54, true), two_pad("VF_HDR_1x02_P2.54", 2.54, true)] {
        lib.footprints.insert(fp.name.clone(), fp);
    }
    let syms = [
        two_pin_symbol("resistor", "R", "10k", [("1", "~"), ("2", "~")], "VF_2P_THT_P5.08"),
        two_pin_symbol("capacitor", "C", "100n", [("1", "~"), ("2", "~")], "VF_2P_THT_P5.08"),
        two_pin_symbol("inductor", "L", "10u", [("1", "~"), ("2", "~")], "VF_2P_THT_P5.08"),
        two_pin_symbol("led", "D", "LED", [("1", "K"), ("2", "A")], "VF_LED_THT_P2.54"),
        two_pin_symbol("diode", "D", "1N4148", [("1", "K"), ("2", "A")], "VF_2P_THT_P5.08"),
        two_pin_symbol("connector", "J", "Conn_01x02", [("1", "Pin_1"), ("2", "Pin_2")], "VF_HDR_1x02_P2.54"),
        SymbolDef {
            name: "power".into(),
            reference_prefix: "#PWR".into(),
            value: "GND".into(),
            description: "Power symbol: its value names the net".into(),
            footprint: None,
            pins: vec![SymbolPin { number: "1".into(), name: "~".into(), position: Pt::new(0, 0), kind: PinKind::PowerIn }],
            body: Pt::mm(1.27, 1.27),
            power: true,
        },
    ];
    for s in syms {
        lib.symbols.insert(s.name.clone(), s);
    }
    lib
}

fn f(v: &Value, k: &str) -> Option<f64> {
    v.get(k).and_then(Value::as_f64)
}

fn xy(v: Option<&Value>) -> Option<Pt> {
    let v = v?;
    Some(Pt::mm(f(v, "x")?, f(v, "y")?))
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}

/// A symbol definition in the JSON shape the UI and the samples send to `library.symbol.upsert`.
/// Pin positions are the pin's outer end, as in KiCad libraries; y is up.
pub fn symbol_from_json(d: &Value) -> Result<SymbolDef> {
    let name = s(d, "name");
    if name.is_empty() {
        return Err(EngineError::invalid("symbol definition needs a name"));
    }
    let mut pins = vec![];
    for p in d.get("pins").and_then(Value::as_array).into_iter().flatten() {
        let number = p.get("number").map(|n| n.as_str().map(String::from).unwrap_or_else(|| n.to_string())).unwrap_or_default();
        if number.is_empty() {
            return Err(EngineError::invalid(format!("pin without a number in symbol {name}")));
        }
        pins.push(SymbolPin {
            number,
            name: s(p, "name").to_string(),
            position: xy(p.get("position")).unwrap_or_default(),
            kind: PinKind::parse(s(p, "electrical_type")),
        });
    }
    let (mut bx, mut by): (Nm, Nm) = (mm(2.54), mm(2.54));
    for p in &pins {
        bx = bx.max(p.position.x.abs());
        by = by.max(p.position.y.abs());
    }
    let fp = s(d, "footprint");
    Ok(SymbolDef {
        name: name.into(),
        reference_prefix: match s(d, "reference") {
            "" => "U".into(),
            r => r.trim_end_matches(|c: char| c.is_ascii_digit()).to_string(),
        },
        value: match s(d, "value") {
            "" => name.into(),
            v => v.into(),
        },
        description: s(d, "description").into(),
        footprint: if fp.is_empty() { None } else { Some(fp.rsplit(':').next().unwrap_or(fp).to_string()) },
        pins,
        body: Pt::new(bx, by),
        power: d.get("power").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// A footprint definition in the JSON shape of `library.footprint.upsert`.
pub fn footprint_from_json(d: &Value) -> Result<FootprintDef> {
    let name = s(d, "name");
    if name.is_empty() {
        return Err(EngineError::invalid("footprint definition needs a name"));
    }
    let mut pads = vec![];
    for p in d.get("pads").and_then(Value::as_array).into_iter().flatten() {
        let kind = match s(p, "pad_type") {
            "smd" => PadKind::Smd,
            "np_thru_hole" => PadKind::Npth,
            _ => PadKind::Tht,
        };
        let size = xy(p.get("size")).unwrap_or(Pt::mm(1.6, 1.6));
        let drill = p
            .get("drill")
            .and_then(|dr| dr.get("size").and_then(|sz| f(sz, "x")).or_else(|| dr.as_f64()))
            .map(mm)
            .filter(|_| kind != PadKind::Smd);
        if kind != PadKind::Smd && drill.is_none() {
            return Err(EngineError::invalid(format!("through hole pad without a drill in footprint {name}")));
        }
        pads.push(PadDef {
            number: s(p, "number").into(),
            kind,
            shape: PadShape::parse(s(p, "shape")),
            offset: xy(p.get("position")).unwrap_or_default(),
            size,
            rotation: mdeg(f(p, "rotation").unwrap_or(0.0)),
            drill,
        });
    }
    Ok(FootprintDef { name: name.into(), description: s(d, "description").into(), pads })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtins_have_footprints() {
        let l = builtin_library();
        for k in BUILTIN_KINDS {
            let s = &l.symbols[k];
            if let Some(fp) = &s.footprint {
                let f = &l.footprints[fp];
                for p in &s.pins {
                    assert!(f.pads.iter().any(|q| q.number == p.number), "{k} pin {}", p.number);
                }
            }
        }
    }

    #[test]
    fn json_definitions_parse() {
        let d = serde_json::json!({"name": "X", "reference": "U", "pins": [{"number": "1", "name": "VDD", "position": {"x": -7.62, "y": 0}, "electrical_type": "power_in"}]});
        let s = symbol_from_json(&d).unwrap();
        assert_eq!(s.pins[0].kind, PinKind::PowerIn);
        assert_eq!(s.pins[0].position, Pt::mm(-7.62, 0.0));
        let f = serde_json::json!({"name": "F", "pads": [{"number": "1", "pad_type": "thru_hole", "shape": "rect", "position": {"x": 1, "y": 2}, "size": {"x": 1.6, "y": 1.6}, "drill": {"size": {"x": 0.8, "y": 0.8}}}]});
        let f = footprint_from_json(&f).unwrap();
        assert_eq!(f.pads[0].drill, Some(mm(0.8)));
        assert_eq!(f.pads[0].shape, PadShape::Rect);
    }
}
