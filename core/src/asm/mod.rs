//! Assemble: the physical model of the product (`assembly.json`, `viaform-asm` v1) and what the
//! Assemble workspace does with it: components and joints, drives, mass properties, interference,
//! motion studies, MJCF and URDF interchange, saved poses, grasps and paths.
//!
//! Front ends drive it through one JSON facade, [`Asm::call`] (`vf_asm_call` in the bridge):
//! each op takes a JSON object and answers one. Ops that change the document are one undo step
//! each. Ops that need geometry take it from the open design ([`Asm::call_with_cad`]) or from a
//! `geometry` parameter ([`mass::Geometry::from_json`]); without either, components fall back to
//! their proxy boxes.
//!
//! Ops:
//! - `get` -> `{assembly}`, `set {assembly}`, `validate`, `template {name: "arm"}` (with `bom`)
//! - `add_component {component}`, `edit_component {id, ...fields}`, `remove_component {id}`
//!   (its joints go with it), `set_ground {component | null}`
//! - `joints`, `add_joint {joint}`, `set_joint {id, ...fields}`, `remove_joint {id}`
//! - `drive {joint, value}` or `drive {q}` -> current values and component poses; `fk {q?, pose?}`
//! - `kin_model {tool?, tip_mm?}` -> the assembly as a `viaform-kin` model for IK and grasps
//! - `mass_props {q?, pose?, geometry?, bom?}`, `interference {q?, pose?, cell_mm?, include_adjacent?}`
//! - `motion_study {study} | {joint, from?, to?, steps?, pose?, duration_s?}`, `add_study {study}`
//! - `export_mjcf`, `export_urdf` -> `{text, warnings, check}`; `import_mjcf {text}`,
//!   `import_urdf {text}` (replace the document); `validate_mjcf {text}`, `validate_urdf {text}`
//! - `save_pose {id, q_deg?}` (the current values when no q is given), `save_grasp {grasp}`,
//!   `save_path {path}` (spec command ids `asm.save_pose`, `asm.save_grasp`, `asm.save_path`)
//! - `mate_cad {inspect}` (a `joint.inspect` reply; read from the design by `call_with_cad`)
//! - `save {path}` writes `assembly.json` into the `.viaform`, `open {path}` reads it;
//!   `commit` -> `{produce}`, the `vf_flow_command` that records the revision
//! - `undo`, `redo`

pub mod cad;
pub mod collide;
pub mod export;
pub mod geom;
pub mod kin;
pub mod mass;
pub mod math;
pub mod model;
pub mod store;
pub mod template;
pub mod xml;

use std::path::Path;

use serde_json::{Map, Value, json};

pub use model::{Assembly, Component, Joint, JointType, Limits, MassOverride, MotionStudy, Motor, PartRef, PcbLink, Pose, Proxy, Tendon};

use mass::Geometry;

/// An open assembly with its undo history and the current joint values.
#[derive(Clone, Debug, Default)]
pub struct Asm {
    pub doc: Assembly,
    /// The current joint values (deg or mm), what `drive` moves and `save_pose` saves.
    pub q: kin::Q,
    /// The BOM the masses of bought parts come from (`bom.json`).
    pub bom: Option<Value>,
    undo: Vec<Assembly>,
    redo: Vec<Assembly>,
}

fn merge(target: &mut Value, patch: &Map<String, Value>) {
    if let Value::Object(t) = target {
        for (k, v) in patch {
            if k != "id" {
                t.insert(k.clone(), v.clone());
            }
        }
    }
}

fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str, String> {
    p.get(k).and_then(Value::as_str).ok_or_else(|| format!("{k} is required"))
}

impl Asm {
    pub fn new(doc: Assembly) -> Result<Self, String> {
        doc.validate()?;
        Ok(Self { doc, ..Self::default() })
    }

    /// Applies a change as one undo step; the document is left as it was when the result does
    /// not validate.
    fn edit(&mut self, f: impl FnOnce(&mut Assembly) -> Result<(), String>) -> Result<(), String> {
        let mut next = self.doc.clone();
        f(&mut next)?;
        next.validate()?;
        if next != self.doc {
            self.undo.push(std::mem::replace(&mut self.doc, next));
            self.redo.clear();
            self.q.retain(|k, _| self.doc.joint(k.split(':').next().unwrap_or(k)).is_some());
        }
        Ok(())
    }

    fn geometry(&self, p: &Value) -> Result<Geometry, String> {
        let mut g = match p.get("geometry") {
            Some(v) if !v.is_null() => Geometry::from_json(v)?,
            _ => Geometry::default(),
        };
        if let Some(b) = p.get("bom").filter(|b| !b.is_null()).or(self.bom.as_ref()) {
            g.add_bom(b);
        }
        Ok(g)
    }

    /// Joint values for an op: the current values, a saved pose on top (`pose`), then `q`.
    fn q_for(&self, p: &Value) -> Result<kin::Q, String> {
        let over = kin::resolve(&self.doc, p.get("pose").and_then(Value::as_str), p.get("q"))?;
        let mut q = if p.get("pose").is_some() { kin::Q::new() } else { self.q.clone() };
        q.extend(over);
        Ok(q)
    }

    fn state(&self) -> Value {
        let poses = kin::fk(&self.doc, &self.q);
        json!({"q": self.q, "poses": kin::poses_json(&poses), "dof": self.doc.dof(), "can_undo": !self.undo.is_empty(), "can_redo": !self.redo.is_empty()})
    }

    /// Runs one op without the design (geometry from `params.geometry` or proxies).
    pub fn call(&mut self, op: &str, p: &Value) -> Result<Value, String> {
        let g = self.geometry(p)?;
        self.call_geom(op, p, &g)
    }

    /// Runs one op against the open design: geometry and measured masses come from it, `drive`
    /// moves the design's mated joints, and `mate_cad` reads its joints.
    pub fn call_with_cad(&mut self, op: &str, p: &Value, cad: &mut solidcraft_engine::Session) -> Result<Value, String> {
        match op {
            "mate_cad" => {
                let inspect = cad.execute("joint.inspect", &json!({})).map_err(|e| e.to_string())?;
                self.call_geom(op, &json!({"inspect": inspect}), &Geometry::default())
            }
            "mass_props" | "interference" | "motion_study" | "export_mjcf" | "export_urdf" if p.get("geometry").is_none() => {
                let bom = p.get("bom").filter(|b| !b.is_null()).or(self.bom.as_ref()).cloned();
                let g = cad::geometry(cad, &self.doc, bom.as_ref())?;
                self.call_geom(op, p, &g)
            }
            "drive" => {
                let out = self.call(op, p)?;
                let moved = cad::drive(cad, &self.doc, &self.q)?;
                Ok(json!({"state": out["state"], "design": moved}))
            }
            _ => self.call(op, p),
        }
    }

    fn call_geom(&mut self, op: &str, p: &Value, g: &Geometry) -> Result<Value, String> {
        let ok = |v: Value| Ok(v);
        match op {
            "get" => ok(json!({"assembly": self.doc.to_json(), "state": self.state()})),
            "validate" => ok(json!({"valid": self.doc.validate().is_ok(), "error": self.doc.validate().err()})),
            "set" => {
                let a = Assembly::from_json(p.get("assembly").ok_or("assembly is required")?)?;
                self.edit(|d| {
                    *d = a;
                    Ok(())
                })?;
                ok(json!({"state": self.state()}))
            }
            "template" => {
                let name = p.get("name").and_then(Value::as_str).unwrap_or("arm");
                if name != "arm" {
                    return Err(format!("no template {name}"));
                }
                self.edit(|d| {
                    *d = template::arm();
                    Ok(())
                })?;
                self.bom = Some(template::arm_bom());
                self.q.clear();
                ok(json!({"assembly": self.doc.to_json(), "bom": self.bom}))
            }
            "add_component" => {
                let c: Component = serde_json::from_value(p.get("component").cloned().ok_or("component is required")?).map_err(|e| format!("component: {e}"))?;
                let id = c.id.clone();
                self.edit(|d| {
                    if d.component(&c.id).is_some() {
                        return Err(format!("component {} already exists", c.id));
                    }
                    d.components.push(c);
                    Ok(())
                })?;
                ok(json!({"component": id}))
            }
            "edit_component" => {
                let id = text(p, "id")?.to_owned();
                let patch = p.as_object().cloned().unwrap_or_default();
                self.edit(|d| {
                    let i = d.components.iter().position(|c| c.id == id).ok_or(format!("no component {id}"))?;
                    let mut v = serde_json::to_value(&d.components[i]).map_err(|e| e.to_string())?;
                    merge(&mut v, &patch);
                    d.components[i] = serde_json::from_value(v).map_err(|e| format!("component: {e}"))?;
                    Ok(())
                })?;
                ok(json!({"component": id}))
            }
            "remove_component" => {
                let id = text(p, "id")?.to_owned();
                let mut gone = Vec::new();
                self.edit(|d| {
                    let before = d.components.len();
                    d.components.retain(|c| c.id != id);
                    if d.components.len() == before {
                        return Err(format!("no component {id}"));
                    }
                    gone = d.joints.iter().filter(|j| j.parent == id || j.child == id).map(|j| j.id.clone()).collect();
                    d.joints.retain(|j| j.parent != id && j.child != id);
                    d.mass_overrides.retain(|o| o.component != id);
                    d.motion_studies.retain(|s| d.joints.iter().any(|j| j.id == s.joint));
                    if d.ground.as_deref() == Some(id.as_str()) {
                        d.ground = None;
                    }
                    Ok(())
                })?;
                ok(json!({"removed": id, "joints_removed": gone}))
            }
            "set_ground" => {
                let g = p.get("component").and_then(Value::as_str).map(str::to_owned);
                self.edit(|d| {
                    d.ground = g;
                    Ok(())
                })?;
                ok(json!({"ground": self.doc.ground}))
            }
            "joints" => {
                let rows: Vec<Value> = self
                    .doc
                    .joints
                    .iter()
                    .map(|j| {
                        let mut v = serde_json::to_value(j).unwrap_or(Value::Null);
                        v["drive"] = json!(j.drive());
                        v["value"] = json!(self.q.get(&j.id).copied().unwrap_or(0.0));
                        v["unit"] = json!(if j.kind.angular() { "deg" } else { "mm" });
                        v
                    })
                    .collect();
                ok(json!({"joints": rows, "dof": self.doc.dof()}))
            }
            "add_joint" => {
                let j: Joint = serde_json::from_value(p.get("joint").cloned().ok_or("joint is required")?).map_err(|e| format!("joint: {e}"))?;
                let id = j.id.clone();
                self.edit(|d| {
                    if d.joint(&j.id).is_some() {
                        return Err(format!("joint {} already exists", j.id));
                    }
                    d.joints.push(j);
                    Ok(())
                })?;
                ok(json!({"joint": id}))
            }
            "set_joint" | "edit_joint" => {
                let id = text(p, "id")?.to_owned();
                let patch = p.as_object().cloned().unwrap_or_default();
                self.edit(|d| {
                    let i = d.joints.iter().position(|j| j.id == id).ok_or(format!("no joint {id}"))?;
                    let mut v = serde_json::to_value(&d.joints[i]).map_err(|e| e.to_string())?;
                    merge(&mut v, &patch);
                    d.joints[i] = serde_json::from_value(v).map_err(|e| format!("joint: {e}"))?;
                    Ok(())
                })?;
                if let Some(j) = self.doc.joint(&id)
                    && let Some(v) = self.q.get_mut(&id)
                {
                    *v = j.clamp(*v);
                }
                ok(json!({"joint": self.doc.joint(&id)}))
            }
            "remove_joint" => {
                let id = text(p, "id")?.to_owned();
                self.edit(|d| {
                    let before = d.joints.len();
                    d.joints.retain(|j| j.id != id);
                    if d.joints.len() == before {
                        return Err(format!("no joint {id}"));
                    }
                    d.motion_studies.retain(|s| s.joint != id);
                    Ok(())
                })?;
                ok(json!({"removed": id}))
            }
            "drive" => {
                let mut asked = kin::Q::new();
                if let Some(j) = p.get("joint").and_then(Value::as_str) {
                    asked.insert(j.to_owned(), p.get("value").and_then(Value::as_f64).ok_or("value is required")?);
                }
                let q = kin::resolve(&self.doc, None, p.get("q").or(Some(&json!(asked))))?;
                let mut held = Vec::new();
                for (k, v) in &asked {
                    if (q.get(k).copied().unwrap_or(*v) - v).abs() > 1e-12 {
                        held.push(json!({"joint": k, "requested": v, "value": q[k], "why": "limit"}));
                    }
                }
                self.q.extend(q);
                ok(json!({"state": self.state(), "held": held}))
            }
            "kin_model" => {
                let tip = match p.get("tip_mm") {
                    Some(v) if !v.is_null() => Some(serde_json::from_value::<[f64; 3]>(v.clone()).map_err(|e| format!("tip_mm: {e}"))?),
                    _ => None,
                };
                kin::kin_model(&self.doc, p.get("tool").and_then(Value::as_str), tip)
            }
            "fk" => {
                let q = self.q_for(p)?;
                let poses = kin::fk(&self.doc, &q);
                ok(json!({"q": q, "poses": kin::poses_json(&poses)}))
            }
            "mass_props" => {
                let q = self.q_for(p)?;
                ok(mass::mass_props(&self.doc, g, &q))
            }
            "interference" => {
                let q = self.q_for(p)?;
                ok(collide::interference(&self.doc, g, &q, &collide::Options::from_json(p)))
            }
            "add_study" => {
                let s: MotionStudy = serde_json::from_value(p.get("study").cloned().ok_or("study is required")?).map_err(|e| format!("study: {e}"))?;
                self.edit(|d| {
                    d.motion_studies.retain(|x| x.id != s.id);
                    d.motion_studies.push(s);
                    Ok(())
                })?;
                ok(json!({"studies": self.doc.motion_studies.len()}))
            }
            "motion_study" => {
                let study = match p.get("study") {
                    Some(Value::String(id)) => self.doc.motion_studies.iter().find(|s| &s.id == id).cloned().ok_or(format!("no motion study {id}"))?,
                    Some(v @ Value::Object(_)) => serde_json::from_value(v.clone()).map_err(|e| format!("study: {e}"))?,
                    _ => {
                        let mut v = p.clone();
                        if v.get("id").is_none() {
                            v["id"] = json!("sweep");
                        }
                        serde_json::from_value(v).map_err(|e| format!("study: {e}"))?
                    }
                };
                let base = match &study.pose {
                    Some(pose) => kin::resolve(&self.doc, Some(pose), None)?,
                    None => self.q.clone(),
                };
                collide::motion_study(&self.doc, g, &study, &base, &collide::Options::from_json(p))
            }
            "export_mjcf" | "export_urdf" => {
                let (text, warnings) = if op == "export_mjcf" { export::to_mjcf(&self.doc, g)? } else { export::to_urdf(&self.doc, g)? };
                let check = if op == "export_mjcf" { export::validate_mjcf(&text)? } else { export::validate_urdf(&text)? };
                let ext = if op == "export_mjcf" { "xml" } else { "urdf" };
                let stem = if self.doc.name.is_empty() { "assembly" } else { self.doc.name.as_str() };
                if let Some(path) = p.get("path").and_then(Value::as_str) {
                    std::fs::write(path, &text).map_err(|e| format!("{path}: {e}"))?;
                }
                ok(json!({"text": text, "filename": format!("{stem}.{ext}"), "warnings": warnings, "check": check}))
            }
            "validate_mjcf" => export::validate_mjcf(text(p, "text")?),
            "validate_urdf" => export::validate_urdf(text(p, "text")?),
            "import_mjcf" | "import_urdf" => {
                let t = text(p, "text")?;
                let a = if op == "import_mjcf" { export::from_mjcf(t)? } else { export::from_urdf(t)? };
                self.edit(|d| {
                    *d = a;
                    Ok(())
                })?;
                self.q.clear();
                ok(json!({"assembly": self.doc.to_json()}))
            }
            "save_pose" => {
                let id = text(p, "id")?.to_owned();
                let q: std::collections::BTreeMap<String, f64> = match p.get("q_deg") {
                    Some(v) => kin::resolve(&self.doc, None, Some(v))?,
                    None => self.q.clone(),
                };
                self.edit(|d| {
                    d.poses.retain(|x| x.id != id);
                    d.poses.push(Pose { id: id.clone(), q_deg: q });
                    Ok(())
                })?;
                ok(json!({"pose": self.doc.pose(&id)}))
            }
            "save_grasp" | "save_path" => {
                let key = if op == "save_grasp" { "grasp" } else { "path" };
                let item = p.get(key).cloned().ok_or(format!("{key} is required"))?;
                let id = item.get("id").and_then(Value::as_str).ok_or(format!("{key}.id is required"))?.to_owned();
                self.edit(|d| {
                    let list = if key == "grasp" { &mut d.grasps } else { &mut d.paths };
                    list.retain(|x| x.get("id").and_then(Value::as_str) != Some(id.as_str()));
                    list.push(item);
                    Ok(())
                })?;
                ok(json!({"saved": id}))
            }
            "mate_cad" => {
                let inspect = p.get("inspect").ok_or("inspect is required (a joint.inspect reply)")?.clone();
                let mut warnings = Vec::new();
                self.edit(|d| {
                    warnings = cad::mate(d, &inspect)?;
                    Ok(())
                })?;
                ok(json!({"joints": self.doc.joints.len(), "warnings": warnings}))
            }
            "save" => {
                let path = text(p, "path")?;
                store::write_into(Path::new(path), &self.doc)?;
                ok(json!({"saved": path, "produce": store::produce_command(&self.doc)}))
            }
            "open" => {
                let path = text(p, "path")?;
                let found = store::read_from(Path::new(path))?;
                let was = found.is_some();
                if let Some(a) = found {
                    self.doc = a;
                    self.undo.clear();
                    self.redo.clear();
                    self.q.clear();
                }
                ok(json!({"found": was}))
            }
            "commit" => ok(json!({"produce": store::produce_command(&self.doc)})),
            "undo" => {
                let prev = self.undo.pop().ok_or("nothing to undo")?;
                self.redo.push(std::mem::replace(&mut self.doc, prev));
                ok(json!({"state": self.state()}))
            }
            "redo" => {
                let next = self.redo.pop().ok_or("nothing to redo")?;
                self.undo.push(std::mem::replace(&mut self.doc, next));
                ok(json!({"state": self.state()}))
            }
            _ => Err(format!("unknown assembly op {op}")),
        }
    }
}

/// One-shot facade: runs `op` on `asm` and wraps the answer as `{"ok": ...}` or `{"error": ...}`.
pub fn call(asm: &mut Asm, op: &str, params: &Value) -> Value {
    match asm.call(op, params) {
        Ok(v) => json!({"ok": v}),
        Err(e) => json!({"error": e}),
    }
}
