//! The assembly against the open SolidCraft design: body geometry and measured masses for mass
//! properties and interference, joints read from the design's own joints (`joint.inspect`), and
//! joint values pushed back to them (`joint.drive`), so the viewport moves with the assembly.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};
use solidcraft_engine::Session;

use super::geom::Mesh;
use super::kin::Q;
use super::mass::{BodyGeom, Geometry, v3};
use super::model::{Assembly, Component, Joint, JointType, Limits};

fn exec(cad: &mut Session, id: &str, p: &Value) -> Result<Value, String> {
    cad.execute(id, p).map_err(|e| e.to_string())
}

/// The geometry of every body the assembly names (its own and its linked boards'), with
/// SolidCraft's measured mass and centre, and the BOM's line masses when `bom` is given.
pub fn geometry(cad: &mut Session, asm: &Assembly, bom: Option<&Value>) -> Result<Geometry, String> {
    let mut g = Geometry::default();
    let boards: BTreeSet<&str> = asm.components.iter().filter_map(|c| c.pcb.as_ref()).map(|p| p.component.as_str()).collect();
    if !boards.is_empty() {
        let list = exec(cad, "component.list", &json!({}))?;
        for c in list["components"].as_array().into_iter().flatten() {
            if let Some(n) = c["name"].as_str().filter(|n| boards.contains(n)) {
                let bodies = c["bodies"].as_array().into_iter().flatten().filter_map(|b| b.as_str().map(str::to_owned)).collect();
                g.component_bodies.insert(n.to_owned(), bodies);
            }
        }
    }
    let mut wanted: BTreeSet<String> = BTreeSet::new();
    for c in &asm.components {
        wanted.extend(g.body_names(c));
    }
    if !wanted.is_empty() {
        let scene = crate::scene::build(cad, None);
        let mut meshes: BTreeMap<String, Mesh> = BTreeMap::new();
        for m in &scene.meshes {
            if wanted.contains(&m.body) {
                let piece = Mesh::from_flat(&m.positions, &m.indices);
                let slot = meshes.entry(m.body.clone()).or_default();
                let base = slot.positions.len() as u32;
                slot.positions.extend(piece.positions);
                slot.triangles.extend(piece.triangles.iter().map(|t| t.map(|i| i + base)));
            }
        }
        let present: Vec<String> = wanted.iter().filter(|b| meshes.contains_key(*b)).cloned().collect();
        let measured = if present.is_empty() { json!({}) } else { exec(cad, "inspect.measure", &json!({"bodies": present}))? };
        let mut by_name: BTreeMap<&str, &Value> = BTreeMap::new();
        for b in measured["bodies"].as_array().into_iter().flatten() {
            if let Some(n) = b["name"].as_str() {
                by_name.insert(n, b);
            }
        }
        for (name, mesh) in meshes {
            let m = by_name.get(name.as_str());
            g.bodies.insert(
                name.clone(),
                BodyGeom {
                    mesh,
                    density_g_cm3: m.and_then(|m| m["density_g_cm3"].as_f64()),
                    measured_mass_kg: m.and_then(|m| m["mass_g"].as_f64()).map(|x| x / 1000.0),
                    measured_center_mm: m.and_then(|m| v3(&m["center_of_mass"])),
                },
            );
        }
    }
    if let Some(b) = bom {
        g.add_bom(b);
    }
    Ok(g)
}

fn range_of(values: &Value) -> Option<(f64, f64)> {
    let v = values.as_array()?.first()?;
    let l = &v["limits"];
    match l {
        Value::Array(a) if a.len() == 2 => Some((a[0].as_f64()?, a[1].as_f64()?)),
        Value::Object(_) => Some((l["min"].as_f64()?, l["max"].as_f64()?)),
        _ => None,
    }
}

fn find_component<'a>(asm: &'a Assembly, side: &Value) -> Option<&'a Component> {
    let names = [side["occurrence_name"].as_str(), side["component_name"].as_str()];
    asm.components.iter().find(|c| names.iter().flatten().any(|n| *n == c.id || *n == c.name))
}

/// Mates the assembly to the design's joints, from a `joint.inspect` reply: a joint whose
/// `cad_joint` names a design joint is updated (type, origin, axis, range), keeping its drive;
/// a design joint the assembly does not have yet is added, with components for its two sides
/// when they are missing. Answers the warnings (types the assembly has no match for).
pub fn mate(asm: &mut Assembly, inspect: &Value) -> Result<Vec<String>, String> {
    let mut warnings = Vec::new();
    for dj in inspect["joints"].as_array().into_iter().flatten() {
        let name = dj["name"].as_str().unwrap_or("").to_owned();
        if dj["suppressed"].as_bool() == Some(true) {
            continue;
        }
        let kind = match dj["type"].as_str().unwrap_or("") {
            "revolute" => JointType::Revolute,
            "slider" => JointType::Prismatic,
            "rigid" => JointType::Fixed,
            "ball" => JointType::Ball,
            "cylindrical" => {
                warnings.push(format!("{name}: cylindrical taken as revolute (its slide is left out)"));
                JointType::Revolute
            }
            t => {
                warnings.push(format!("{name}: {t} joints have no assembly match; left out"));
                continue;
            }
        };
        let mut side = |key: &str| -> String {
            let s = &dj[key];
            if let Some(c) = find_component(asm, s) {
                return c.id.clone();
            }
            let id = s["occurrence_name"].as_str().or(s["component_name"].as_str()).unwrap_or(key).to_owned();
            asm.components.push(Component { id: id.clone(), name: s["component_name"].as_str().unwrap_or("").to_owned(), ..Component::default() });
            id
        };
        let parent = side("a");
        let child = side("b");
        let frame = dj["b"]["frame"].as_object().map(|_| &dj["b"]["frame"]).unwrap_or(&dj["a"]["frame"]);
        let origin = v3(&frame["origin"]).unwrap_or([0.0; 3]);
        let axis = v3(&frame["z"]).unwrap_or([0.0, 0.0, 1.0]);
        let limits = range_of(&dj["values"]).map(|(lo, hi)| {
            if kind.angular() {
                Limits { lower_deg: Some(lo), upper_deg: Some(hi), ..Limits::default() }
            } else {
                Limits { lower_mm: Some(lo), upper_mm: Some(hi), ..Limits::default() }
            }
        });
        let existing = asm.joints.iter().position(|j| j.cad_joint.as_deref() == Some(name.as_str()) || (j.parent == parent && j.child == child));
        match existing {
            Some(i) => {
                let j = &mut asm.joints[i];
                j.kind = kind;
                j.origin = origin;
                j.axis = axis;
                j.cad_joint = Some(name);
                if let Some(l) = limits {
                    let keep = j.limits.take().unwrap_or_default();
                    j.limits = Some(Limits { velocity_dps: keep.velocity_dps, velocity_mmps: keep.velocity_mmps, effort_nm: keep.effort_nm, effort_n: keep.effort_n, ..l });
                }
            }
            None => {
                let mut id: String = name.chars().map(|c| if c.is_alphanumeric() { c.to_ascii_lowercase() } else { '_' }).collect();
                if id.is_empty() || asm.joint(&id).is_some() {
                    id = format!("joint_{}", asm.joints.len() + 1);
                }
                asm.joints.push(Joint { id, kind, parent, child, origin, axis, limits, cad_joint: Some(name), ..Joint::default() });
            }
        }
    }
    asm.validate()?;
    Ok(warnings)
}

/// Drives the design's joints to `q` (the joints mated to one), so the viewport follows.
pub fn drive(cad: &mut Session, asm: &Assembly, q: &Q) -> Result<Vec<Value>, String> {
    let mut out = Vec::new();
    for j in &asm.joints {
        let (Some(name), Some(v)) = (&j.cad_joint, q.get(&j.id)) else { continue };
        out.push(exec(cad, "joint.drive", &json!({"joint": name, "value": v, "quiet": true}))?);
    }
    Ok(out)
}
