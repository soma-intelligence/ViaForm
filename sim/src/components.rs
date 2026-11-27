//! The drone built from its real, sourced components: docs/components/drone.json lists them
//! (ref, qty, category, mpn, mass, dimensions, key specs), and docs/generative/drone/assembly.json,
//! when it exists, places them. The motors' thrust and current, the pack and the props come from
//! the specs given; a value the file does not give comes from the built-in parts list (parts.rs)
//! and the summary says so. Nothing is made up here: a missing figure is either the catalogue's or
//! reported missing.
//!
//! All-up mass is the sum of the components (and the frame, from the frame file or the nominal
//! frame study when the list has no frame mass). Inertia is about the centre of mass: each
//! component a box of its dimensions at its place (a point when it has none), plus the frame's
//! own inertia. Without an assembly, parts sit where a 3-inch quad carries them: motors and props
//! at the arm tips, the stack in the middle, the pack on top.

use serde_json::{Map, Value, json};

use crate::airframe::{Airframe, nominal_frame_inertia};
use crate::flight::quad3;
use crate::frame::FRAME;
use crate::parts::{MOTOR_THRUST_3S_N, PARTS};
use crate::physics::{MOTOR_ANGLES, QuadParams};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Motor,
    Prop,
    Battery,
    Stack,
    Frame,
    Other,
}

fn kind_of(category: &str) -> Kind {
    let c = category.to_lowercase();
    if c.contains("motor") {
        Kind::Motor
    } else if c.contains("prop") {
        Kind::Prop
    } else if c.contains("batt") || c.contains("lipo") || c.contains("pack") {
        Kind::Battery
    } else if c.contains("esc") || c.contains("flight") || c.contains("fc") || c.contains("stack") || c.contains("controller") || c.contains("mcu") {
        Kind::Stack
    } else if c.contains("frame") {
        Kind::Frame
    } else {
        Kind::Other
    }
}

#[derive(Clone, Debug)]
pub struct Component {
    pub reference: String,
    pub qty: usize,
    pub kind: Kind,
    pub category: String,
    pub mpn: String,
    pub mass_g: Option<f64>,
    pub dims_mm: Option<[f64; 3]>,
    pub specs: Map<String, Value>,
}

fn get<'a>(o: &'a Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|k| o.get(*k)).or_else(|| {
        // Case- and separator-insensitive: "Mass_g", "massG", "mass-g".
        let norm = |s: &str| s.chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_lowercase();
        let want: Vec<String> = keys.iter().map(|k| norm(k)).collect();
        o.iter().find(|(k, _)| want.contains(&norm(k))).map(|(_, v)| v)
    })
}

/// A number, or the first number in a string ("650 mAh", "11.1V").
fn num(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => {
            let t: String = s.chars().skip_while(|c| !c.is_ascii_digit() && *c != '.').take_while(|c| c.is_ascii_digit() || *c == '.').collect();
            t.parse().ok()
        }
        Value::Object(o) => get(o, &["value", "nominal"]).and_then(num),
        _ => None,
    }
}

fn f(o: &Map<String, Value>, keys: &[&str]) -> Option<f64> {
    get(o, keys).and_then(num).filter(|x| x.is_finite())
}

fn v3(v: &Value) -> Option<[f64; 3]> {
    match v {
        Value::Array(a) if a.len() >= 2 => Some([num(&a[0])?, num(&a[1])?, a.get(2).and_then(num).unwrap_or(0.0)]),
        Value::Object(o) => {
            let x = f(o, &["x", "l", "length", "length_mm"])?;
            let y = f(o, &["y", "w", "width", "width_mm"])?;
            Some([x, y, f(o, &["z", "h", "height", "height_mm", "thickness"]).unwrap_or(0.0)])
        }
        Value::String(s) => {
            // "55x30x17" or "55 × 30 × 17 mm".
            let n: Vec<f64> = s.split(|c: char| !(c.is_ascii_digit() || c == '.')).filter_map(|t| t.parse().ok()).collect();
            (n.len() >= 2).then(|| [n[0], n[1], n.get(2).copied().unwrap_or(0.0)])
        }
        _ => None,
    }
}

/// Reads docs/components/drone.json: `{"components": [...]}` or a bare list.
pub fn parse_components(text: &str) -> Result<Vec<Component>, String> {
    let v: Value = serde_json::from_str(text).map_err(|e| format!("drone.json: {e}"))?;
    let list = match &v {
        Value::Array(a) => a,
        Value::Object(o) => get(o, &["components", "parts", "bom"]).and_then(Value::as_array).ok_or("drone.json: no components list")?,
        _ => return Err("drone.json: no components list".into()),
    };
    let mut out = vec![];
    for (i, c) in list.iter().enumerate() {
        let Some(o) = c.as_object() else { return Err(format!("drone.json: component {i} is not an object")) };
        let category = get(o, &["category", "role", "kind", "type"]).and_then(Value::as_str).unwrap_or("").to_string();
        let reference = get(o, &["ref", "id", "designator"]).and_then(Value::as_str).map_or_else(|| format!("#{i}"), str::to_string);
        let qty = f(o, &["qty", "quantity", "count"]).unwrap_or(1.0).round().max(0.0) as usize;
        let mass_g = f(o, &["mass_g", "massG", "weight_g", "mass"]).filter(|m| *m >= 0.0 && *m < 2000.0);
        let dims_mm = get(o, &["dims_mm", "dimensions_mm", "dims", "dimensions", "size_mm"]).and_then(v3);
        let specs = get(o, &["key_specs", "specs", "keySpecs"]).and_then(Value::as_object).cloned().unwrap_or_default();
        let mpn = get(o, &["mpn", "part_number", "model"]).and_then(Value::as_str).unwrap_or("").to_string();
        // A frame filed under another category ("other") still names itself, or is used as one.
        // (Its part number, not its description: a standoff's describes the frame it holds.)
        let names_frame = o.get("mpn").and_then(Value::as_str).is_some_and(|t| t.to_lowercase().contains("frame"))
            // Used by nothing but the frame and not a fastener (screws and standoffs say "frame" too).
            || (!category.to_lowercase().contains("fasten")
                && o.get("used_by").and_then(Value::as_array).is_some_and(|u| u.len() == 1 && u[0].as_str() == Some("frame")));
        let kind = match kind_of(&category) {
            Kind::Other if names_frame => Kind::Frame,
            k => k,
        };
        out.push(Component { kind, reference, qty, category, mpn, mass_g, dims_mm, specs });
    }
    if out.is_empty() {
        return Err("drone.json: the components list is empty".into());
    }
    Ok(out)
}

/// Placements from docs/generative/drone/assembly.json: ref to positions (mm, body axes).
///
/// The generated assembly (`viaform.assembly/1`) lists every part under `parts`: a real
/// component names its line with `component_ref` (and `ref`), and gives its place as
/// `position_mm` or as `pose`, a row-major 3x4 matrix whose last column is the translation.
/// Generated and made parts (no ref) are the frame, which the frame file describes; they are
/// skipped here. Older files (`placements`, `instances`, `ref` + `position`) still read.
pub fn parse_assembly(text: &str) -> Result<Vec<(String, [f64; 3])>, String> {
    let v: Value = serde_json::from_str(text).map_err(|e| format!("assembly.json: {e}"))?;
    let list = match &v {
        Value::Array(a) => a.clone(),
        Value::Object(o) => get(o, &["placements", "instances", "parts", "components", "occurrences"])
            .and_then(Value::as_array)
            .cloned()
            .ok_or("assembly.json: no placements list")?,
        _ => return Err("assembly.json: no placements list".into()),
    };
    let mut out = vec![];
    for p in &list {
        let Some(o) = p.as_object() else { continue };
        // Generated and made parts are the frame (the frame file has them).
        if o.get("kind").and_then(Value::as_str).is_some_and(|k| k == "generative" || k == "made") {
            continue;
        }
        let Some(r) = get(o, &["component_ref", "ref", "component", "id", "part"]).and_then(Value::as_str) else { continue };
        let pos = get(o, &["position_mm", "position", "translation_mm", "translation", "pos", "at", "origin_mm"])
            .and_then(v3)
            .or_else(|| get(o, &["pose"]).and_then(pose_translation))
            .or_else(|| get(o, &["transform"]).and_then(Value::as_object).and_then(|t| get(t, &["translation", "position"])).and_then(v3));
        if let Some(pos) = pos {
            out.push((r.to_string(), pos));
        }
    }
    Ok(out)
}

/// The translation of a pose: a row-major 3x4 (12 numbers) or 4x4 (16) matrix, flat or nested.
fn pose_translation(v: &Value) -> Option<[f64; 3]> {
    let flat: Vec<f64> = match v.as_array()? {
        a if a.iter().all(Value::is_array) => a.iter().flat_map(|r| r.as_array().into_iter().flatten().filter_map(Value::as_f64)).collect(),
        a => a.iter().filter_map(Value::as_f64).collect(),
    };
    (flat.len() == 12 || flat.len() == 16).then(|| [flat[3], flat[7], flat[11]])
}

/// Whether a placement's ref is the component's: the same ref, or the ref with an instance
/// suffix ("M1.2", "M1#2"), never another ref that starts the same way ("SCR1" is not "SC").
fn same_ref(placed: &str, reference: &str) -> bool {
    placed == reference || placed.strip_prefix(reference).is_some_and(|rest| rest.starts_with(|c: char| !c.is_ascii_alphanumeric()))
}

/// The catalogue entry for a kind, the fallback for a figure the file does not give.
fn catalogue_mass_g(kind: Kind) -> Option<f64> {
    let role = match kind {
        Kind::Motor => "Motors",
        Kind::Prop => "Propellers",
        Kind::Battery => "Battery",
        Kind::Stack => "Flight controller + 4-in-1 ESC",
        _ => return None,
    };
    PARTS.iter().find(|p| p.role == role).map(|p| p.mass_g)
}

/// The motor's full-throttle thrust (N) and current (A) from its thrust table, at the pack's
/// voltage: thrust and current scale as voltage squared (the catalogue figure is scaled the
/// same way from 4S to 3S).
fn motor_peak(specs: &Map<String, Value>, pack_v: Option<f64>) -> Option<(f64, Option<f64>, Option<f64>, &'static str)> {
    let table_v = f(specs, &["thrust_table_voltage_v", "table_voltage_v", "test_voltage_v", "voltage_v"]);
    let scale = |row_v: Option<f64>| match (row_v.or(table_v), pack_v) {
        (Some(t), Some(p)) if t > 0.0 => (p / t).powi(2),
        _ => 1.0,
    };
    // "thrust_table", or a table named after its test ("thrust_table_gf3016_4s").
    let table = get(specs, &["thrust_table", "thrust", "thrust_data"])
        .or_else(|| specs.iter().find(|(k, v)| k.to_lowercase().starts_with("thrust_table") && v.is_array()).map(|(_, v)| v));
    if let Some(rows) = table.and_then(Value::as_array) {
        let mut best: Option<(f64, Option<f64>, Option<f64>)> = None;
        for r in rows.iter().filter_map(Value::as_object) {
            let Some(g) = f(r, &["thrust_g", "thrust", "grams", "g"]) else { continue };
            let row_v = f(r, &["voltage_v", "voltage", "v"]);
            let k = scale(row_v);
            let a = f(r, &["current_a", "current", "amps", "a"]).map(|a| a * k);
            // Speed goes with voltage: rpm at the pack's.
            let w = f(r, &["rpm"]).map(|rpm| rpm * std::f64::consts::PI / 30.0 * k.sqrt());
            if best.is_none_or(|(b, _, _)| g * k > b) {
                best = Some((g * k, a, w));
            }
        }
        if let Some((g, a, w)) = best {
            return Some((g / 1000.0 * 9.81, a, w, "thrust table"));
        }
    }
    f(specs, &["max_thrust_g", "thrust_g", "peak_thrust_g"]).map(|g| (g * scale(None) / 1000.0 * 9.81, f(specs, &["max_current_a", "peak_current_a"]), None, "max thrust"))
}

/// Prop diameter (m) from "diameter_in", "diameter_mm" or a size such as 3016 or "3x1.6".
fn prop_radius(specs: &Map<String, Value>) -> Option<f64> {
    if let Some(mm) = f(specs, &["diameter_mm", "prop_diameter_mm"]) {
        return Some(mm / 2000.0);
    }
    if let Some(inch) = f(specs, &["diameter_in", "prop_size_in", "size_in", "diameter_inch"]) {
        return Some(inch * 0.0254 / 2.0);
    }
    let size = get(specs, &["size", "prop_size", "diameter"])?;
    let text = match size {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return None,
    };
    let digits: String = text.chars().take_while(char::is_ascii_digit).collect();
    // The four-digit code: 3016 is 3.0 in by 1.6 in pitch.
    let inch = if digits.len() == 4 && !text.contains('.') { digits[..2].parse::<f64>().ok()? / 10.0 } else { num(size)? };
    (inch > 1.0 && inch < 12.0).then_some(inch * 0.0254 / 2.0)
}

/// The drone from its components, and what each figure came from.
#[derive(Debug, Clone)]
pub struct Vehicle {
    pub params: QuadParams,
    pub summary: Value,
}

pub fn vehicle(components: &str, assembly: Option<&str>, frame: Option<&str>) -> Result<Vehicle, String> {
    let comps = parse_components(components)?;
    let placements = match assembly {
        Some(a) if !a.trim().is_empty() => parse_assembly(a)?,
        _ => vec![],
    };
    let frame = match frame {
        Some(t) if !t.trim().is_empty() => Some(Airframe::from_json(t)?),
        _ => None,
    };
    let mut sources = Map::new();
    let mut missing: Vec<String> = vec![];
    let first = |k: Kind| comps.iter().find(|c| c.kind == k);

    // The pack: voltage first, since the motors' figures depend on it.
    let (mut cells, mut capacity_ah) = (3.0, 0.65);
    match first(Kind::Battery) {
        Some(b) => {
            let s = &b.specs;
            let v = f(s, &["voltage_nominal_v", "nominal_voltage_v", "voltage_v", "voltage"]);
            match f(s, &["cells", "cell_count", "s", "series"]).or_else(|| v.map(|v| (v / 3.7).round())) {
                Some(c) if (1.0..=12.0).contains(&c) => {
                    cells = c;
                    sources.insert("cells".into(), json!(b.reference));
                }
                _ => missing.push(format!("{}: cells or voltage", b.reference)),
            }
            match f(s, &["capacity_mah", "capacity", "mah"]).map(|m| m / 1000.0).or_else(|| f(s, &["capacity_ah"])) {
                Some(c) if c > 0.0 && c < 50.0 => {
                    capacity_ah = c;
                    sources.insert("capacityAh".into(), json!(b.reference));
                }
                _ => missing.push(format!("{}: capacity", b.reference)),
            }
        }
        None => missing.push("no battery in the list".into()),
    }
    let pack_v = cells * 3.7;

    // Motors: thrust, current and speed.
    let mut max_thrust = MOTOR_THRUST_3S_N;
    let mut peak_current = 9.3;
    let mut omega_max = 4000.0;
    match first(Kind::Motor) {
        Some(m) => {
            let mut table_omega = None;
            match motor_peak(&m.specs, Some(pack_v)) {
                Some((t, a, w, how)) if t > 0.2 && t < 50.0 => {
                    table_omega = w.filter(|w| *w > 500.0 && *w < 20_000.0);
                    max_thrust = t;
                    sources.insert("maxThrust".into(), json!(format!("{} ({how})", m.reference)));
                    if let Some(a) = a.filter(|a| *a > 0.3 && *a < 200.0) {
                        peak_current = a;
                        sources.insert("peakCurrent".into(), json!(m.reference));
                    }
                }
                _ => missing.push(format!("{}: thrust table", m.reference)),
            }
            // Loaded speed: 75 % of KV times the pack voltage (the catalogue's 4600 KV on 3S
            // gives 4000 rad/s the same way).
            match f(&m.specs, &["kv", "motor_kv"]) {
                // The measured speed at full throttle, when the table has it, beats the KV estimate.
                _ if table_omega.is_some() => {
                    omega_max = table_omega.unwrap_or(omega_max);
                    sources.insert("omegaMax".into(), json!(format!("{} (thrust table rpm)", m.reference)));
                }
                Some(kv) if kv > 100.0 && kv < 100_000.0 => {
                    omega_max = 0.748 * kv * pack_v * std::f64::consts::PI / 30.0;
                    sources.insert("omegaMax".into(), json!(format!("{} (KV)", m.reference)));
                }
                _ => missing.push(format!("{}: KV", m.reference)),
            }
        }
        None => missing.push("no motor in the list".into()),
    }
    let prop_r = match first(Kind::Prop).and_then(|p| prop_radius(&p.specs).map(|r| (p, r))) {
        Some((p, r)) => {
            sources.insert("propRadius".into(), json!(p.reference));
            r
        }
        None => {
            missing.push("prop diameter".into());
            0.0381
        }
    };

    // Arm: the frame file, else the motor placements, else the nominal frame.
    let motor_ref = first(Kind::Motor).map(|m| m.reference.clone());
    let motor_places: Vec<[f64; 3]> =
        placements.iter().filter(|(r, _)| motor_ref.as_deref().is_some_and(|m| same_ref(r, m))).map(|(_, p)| *p).collect();
    let arm_mm = frame.as_ref().map(|a| a.arm_mm).unwrap_or_else(|| {
        if motor_places.is_empty() { FRAME.arm } else { motor_places.iter().map(|p| p[0].hypot(p[1])).sum::<f64>() / motor_places.len() as f64 }
    });

    // Masses at their places.
    let tip = |i: usize, z: f64| {
        let a = MOTOR_ANGLES[i % 4].to_radians();
        [arm_mm * a.cos(), arm_mm * a.sin(), z]
    };
    let standard = |k: Kind, i: usize| match k {
        Kind::Motor => tip(i, 8.0),
        Kind::Prop => tip(i, 16.0),
        Kind::Battery => [0.0, 0.0, 22.0],
        Kind::Stack => [0.0, 0.0, 6.0],
        Kind::Frame => [0.0, 0.0, 0.0],
        Kind::Other => [0.0, 0.0, 10.0],
    };
    let mut bodies: Vec<(f64, [f64; 3], Option<[f64; 3]>)> = vec![]; // g, mm, dims
    let mut frame_listed = false;
    let mut placed = 0;
    let mut placed_refs: Vec<String> = vec![];
    for c in &comps {
        let m = match c.mass_g {
            Some(m) => m,
            // A frame without a mass: the frame file's or the nominal frame study's, below.
            None if c.kind == Kind::Frame => continue,
            None => match catalogue_mass_g(c.kind) {
                Some(m) => {
                    sources.insert(format!("mass {}", c.reference), json!("catalogue"));
                    m
                }
                None => {
                    missing.push(format!("{}: mass", c.reference));
                    continue;
                }
            },
        };
        if c.kind == Kind::Frame {
            frame_listed = true;
        }
        let mine: Vec<[f64; 3]> = placements.iter().filter(|(r, _)| same_ref(r, &c.reference)).map(|(_, p)| *p).collect();
        for i in 0..c.qty {
            let at = mine.get(i).copied().unwrap_or_else(|| standard(c.kind, i));
            if i < mine.len() {
                placed += 1;
                if i == 0 {
                    placed_refs.push(c.reference.clone());
                }
            }
            // The frame's spread is its own inertia, added below; here it is the mass at its place.
            bodies.push((m, at, if c.kind == Kind::Frame { None } else { c.dims_mm }));
        }
    }
    let frame_g = if frame_listed {
        bodies.iter().zip(comps.iter().flat_map(|c| std::iter::repeat_n(c, c.qty))).filter(|(_, c)| c.kind == Kind::Frame).map(|(b, _)| b.0).sum()
    } else {
        let g = frame.as_ref().map_or(FRAME.mass_g, |a| a.frame_g);
        bodies.push((g, [0.0; 3], None));
        sources.insert("frameMass".into(), json!(if frame.is_some() { "frame file" } else { "nominal frame study" }));
        g
    };
    // The frame's own inertia: the generated frame's from its file (scaled to the listed frame
    // mass), else the nominal frame's scaled by mass and arm squared.
    let frame_i = {
        let (base, base_g, base_arm) = match &frame {
            Some(a) => (a.frame_inertia, a.frame_g, a.arm_mm),
            None => (nominal_frame_inertia(), FRAME.mass_g, FRAME.arm),
        };
        let k = frame_g / base_g * (arm_mm / base_arm).powi(2);
        base.map(|x| x * k)
    };
    let mass_g: f64 = bodies.iter().map(|b| b.0).sum();
    if mass_g <= 0.0 {
        return Err("drone.json: no component has a mass".into());
    }
    let cg: [f64; 3] = std::array::from_fn(|k| bodies.iter().map(|b| b.0 * b.1[k]).sum::<f64>() / mass_g);
    let mut inertia = frame_i;
    for (m, p, dims) in &bodies {
        let kg = m / 1000.0;
        let d: [f64; 3] = std::array::from_fn(|k| (p[k] - cg[k]) / 1000.0);
        let [l, w, h] = dims.map_or([0.0; 3], |x| x.map(|v| v / 1000.0));
        inertia[0] += kg * (d[1] * d[1] + d[2] * d[2]) + kg * (w * w + h * h) / 12.0;
        inertia[1] += kg * (d[0] * d[0] + d[2] * d[2]) + kg * (l * l + h * h) / 12.0;
        inertia[2] += kg * (d[0] * d[0] + d[1] * d[1]) + kg * (l * l + w * w) / 12.0;
    }

    let mut p = quad3(mass_g / 1000.0, inertia, arm_mm / 1000.0);
    p.omega_max = omega_max;
    p.omega_idle = 0.12 * omega_max;
    p.k_t = max_thrust / (omega_max * omega_max);
    p.k_q = p.k_t * 0.009 * (prop_r / 0.0381);
    p.max_thrust = max_thrust;
    p.peak_current = peak_current;
    p.battery_ah = capacity_ah;
    p.battery_cells = cells;
    p.prop_radius = prop_r;
    p.body_radius = arm_mm / 1000.0 + prop_r;
    let summary = json!({
        "massKg": p.mass, "inertia": p.inertia, "armMm": arm_mm, "cgMm": cg,
        "maxThrustN": max_thrust, "thrustToWeight": 4.0 * max_thrust / (p.mass * 9.81),
        "peakCurrentA": peak_current, "omegaMax": omega_max, "propRadiusM": prop_r,
        "battery": { "cells": cells, "capacityAh": capacity_ah },
        "components": comps.iter().map(|c| json!({ "ref": c.reference, "qty": c.qty, "category": c.category, "mpn": c.mpn, "massG": c.mass_g })).collect::<Vec<_>>(),
        "placed": placed, "placedRefs": placed_refs, "placements": placements.len(), "assembly": !placements.is_empty(),
        "frame": frame.as_ref().map(|a| json!({"name": a.name, "frameG": a.frame_g, "armMm": a.arm_mm})),
        "sources": sources, "missing": missing,
    });
    if 4.0 * max_thrust < 1.3 * p.mass * 9.81 {
        return Err(format!("drone.json: thrust to weight {:.2} is too low to fly", 4.0 * max_thrust / (p.mass * 9.81)));
    }
    Ok(Vehicle { params: p, summary })
}
