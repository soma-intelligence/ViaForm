//! The command facade: a session holds one project, runs JSON commands with undo and redo,
//! and serialises the project for the UI (`inspect`) and the checks (`checks`).
//!
//! Lengths cross this boundary in millimetres (f64) and are stored in nanometres. Command ids
//! follow the `pcb_*` surface ViaForm uses today, so the UI keeps working after the swap.

use crate::checks;
use crate::error::{EngineError, Result};
use crate::fab;
use crate::geom::*;
use crate::kicad;
use crate::library;
use crate::model::*;
use crate::netlist;
use crate::router;
use crate::zones;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub struct Session {
    pub project: Project,
    undo: Vec<Project>,
    redo: Vec<Project>,
    pub revision: u64,
}

impl Default for Session {
    fn default() -> Self {
        Session::new()
    }
}

// ---------- parameter helpers ----------

fn get<'a>(p: &'a Value, k: &str) -> Result<&'a Value> {
    p.get(k).ok_or_else(|| EngineError::invalid(format!("missing parameter `{k}`")))
}

fn num(p: &Value, k: &str) -> Result<f64> {
    get(p, k)?.as_f64().ok_or_else(|| EngineError::invalid(format!("`{k}` must be a number")))
}

fn opt_num(p: &Value, k: &str) -> Option<f64> {
    p.get(k).and_then(Value::as_f64)
}

fn len(p: &Value, k: &str) -> Result<Nm> {
    let v = num(p, k)?;
    if !v.is_finite() {
        return Err(EngineError::invalid(format!("`{k}` must be finite")));
    }
    Ok(mm(v))
}

fn opt_len(p: &Value, k: &str) -> Option<Nm> {
    opt_num(p, k).filter(|v| v.is_finite()).map(mm)
}

fn id(p: &Value, k: &str) -> Result<Id> {
    get(p, k)?.as_u64().ok_or_else(|| EngineError::invalid(format!("`{k}` must be an object id")))
}

fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    get(p, k)?.as_str().ok_or_else(|| EngineError::invalid(format!("`{k}` must be a string")))
}

fn opt_text<'a>(p: &'a Value, k: &str) -> Option<&'a str> {
    p.get(k).and_then(Value::as_str)
}

fn point(v: &Value) -> Result<Pt> {
    if let Some(a) = v.as_array() {
        if a.len() == 2 {
            if let (Some(x), Some(y)) = (a[0].as_f64(), a[1].as_f64()) {
                return Ok(Pt::mm(x, y));
            }
        }
    }
    match (v.get("x").and_then(Value::as_f64), v.get("y").and_then(Value::as_f64)) {
        (Some(x), Some(y)) if x.is_finite() && y.is_finite() => Ok(Pt::mm(x, y)),
        _ => Err(EngineError::invalid("a point is {\"x\": mm, \"y\": mm}")),
    }
}

fn pt(p: &Value, k: &str) -> Result<Pt> {
    point(get(p, k)?)
}

fn points(p: &Value, k: &str) -> Result<Vec<Pt>> {
    let a = get(p, k)?.as_array().ok_or_else(|| EngineError::invalid(format!("`{k}` must be a list of points")))?;
    let v: Result<Vec<Pt>> = a.iter().map(point).collect();
    let v = v?;
    if v.len() < 3 {
        return Err(EngineError::invalid(format!("`{k}` needs at least three points")));
    }
    Ok(v)
}

fn pinref(v: &Value) -> Result<PinRef> {
    let component = v.get("component").and_then(Value::as_u64).ok_or_else(|| EngineError::invalid("a pin is {\"component\": id, \"pin\": number}"))?;
    let pin = match v.get("pin") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => return Err(EngineError::invalid("a pin is {\"component\": id, \"pin\": number}")),
    };
    Ok(PinRef { component, pin })
}

fn mmv(v: Nm) -> Value {
    json!(to_mm(v))
}

fn ptv(p: Pt) -> Value {
    json!({"x": to_mm(p.x), "y": to_mm(p.y)})
}

fn created(id: Id) -> Value {
    json!({"result": {"id": id}})
}

fn done() -> Value {
    json!({"result": {}})
}

fn read(path: &str) -> Result<String> {
    std::fs::read_to_string(path).map_err(|e| EngineError::io(format!("Could not read {path}: {e}")))
}

fn write(path: &str, s: &str) -> Result<()> {
    std::fs::write(path, s).map_err(|e| EngineError::io(format!("Could not write {path}: {e}")))
}

// ---------- file format ----------

/// The native `.vfpcb` file: the project as JSON, lengths in nanometres.
pub fn to_vfpcb(p: &Project) -> String {
    let mut s = serde_json::to_string_pretty(p).expect("project serialises");
    s.push('\n');
    s
}

pub fn from_vfpcb(s: &str) -> Result<Project> {
    let v: Value = serde_json::from_str(s).map_err(|e| EngineError::new("format", format!("Not a ViaForm board file: {e}")))?;
    if v.get("format").and_then(Value::as_str) != Some(FORMAT) {
        return Err(EngineError::new("format", "Not a ViaForm board file (format is not viaform-pcb)"));
    }
    let version = v.get("version").and_then(Value::as_u64).unwrap_or(0) as u32;
    if version == 0 || version > FORMAT_VERSION {
        return Err(EngineError::new("format", format!("Board file version {version} is not supported (this engine reads up to {FORMAT_VERSION})")));
    }
    // Version migrations go here as the format grows.
    serde_json::from_value(v).map_err(|e| EngineError::new("format", format!("Damaged board file: {e}")))
}

// ---------- the session ----------

/// Commands that never change the project (no undo step, no revision).
const READ_ONLY: &[&str] = &[
    "rules.get",
    "check.erc",
    "check.drc",
    "check.all",
    "netlist.get",
    "ratsnest.get",
    "file.save",
    "file.export_kicad",
    "export.gerber",
    "export.drill",
    "export.bom",
    "export.pnp",
    "export.fab",
    "commands.list",
    "link.geometry",
];

impl Session {
    pub fn new() -> Session {
        Session { project: Project::default(), undo: vec![], redo: vec![], revision: 0 }
    }

    /// A session with the drone flight controller sample drawn and placed.
    pub fn sample() -> Session {
        let mut s = Session::new();
        crate::sample::build_flight_controller(&mut s).expect("sample builds");
        s.undo.clear();
        s.redo.clear();
        s.revision = 1;
        s
    }

    /// Runs one command. Mutating commands are atomic: on error the project is unchanged.
    pub fn call(&mut self, op: &str, params: &Value) -> Result<Value> {
        match op {
            "undo" | "edit.undo" => {
                let prev = self.undo.pop().ok_or_else(|| EngineError::new("nothing_to_undo", "Nothing to undo"))?;
                self.redo.push(std::mem::replace(&mut self.project, prev));
                self.revision += 1;
                return Ok(done());
            }
            "redo" | "edit.redo" => {
                let next = self.redo.pop().ok_or_else(|| EngineError::new("nothing_to_redo", "Nothing to redo"))?;
                self.undo.push(std::mem::replace(&mut self.project, next));
                self.revision += 1;
                return Ok(done());
            }
            _ => {}
        }
        if READ_ONLY.contains(&op) {
            return self.query(op, params);
        }
        let before = self.project.clone();
        match self.apply(op, params) {
            Ok(v) => {
                netlist::extract(&mut self.project);
                if self.project != before {
                    self.undo.push(before);
                    self.redo.clear();
                    self.revision += 1;
                }
                Ok(v)
            }
            Err(e) => {
                self.project = before;
                Err(e)
            }
        }
    }

    /// The C ABI reply shape: `{"ok": ...}` or `{"error": message, "code": code}`.
    pub fn execute(&mut self, op: &str, params_json: &str) -> String {
        let params: Value = match serde_json::from_str(if params_json.trim().is_empty() { "{}" } else { params_json }) {
            Ok(v) => v,
            Err(e) => return json!({"error": format!("Parameters are not JSON: {e}"), "code": "invalid_params"}).to_string(),
        };
        match self.call(op, &params) {
            Ok(v) => json!({"ok": v}).to_string(),
            Err(e) => json!({"error": e.message, "code": e.code}).to_string(),
        }
    }

    pub fn history(&self) -> (usize, usize) {
        (self.undo.len(), self.redo.len())
    }

    fn query(&mut self, op: &str, p: &Value) -> Result<Value> {
        let pr = &self.project;
        Ok(match op {
            "rules.get" => json!({"result": rules_json(&pr.rules)}),
            "check.erc" => json!({"result": checks::erc(pr)}),
            "check.drc" => json!({"result": checks::drc(pr)}),
            "check.all" => json!({"result": checks::checks_json(pr)}),
            "ratsnest.get" => json!({"result": checks::checks_json(pr)["airwires"].clone()}),
            "netlist.get" => {
                let mut q = pr.clone();
                let nl = netlist::extract(&mut q);
                let mut per: BTreeMap<Id, Vec<Value>> = BTreeMap::new();
                for (r, n) in &nl.pin_net {
                    let reference = pr.component(r.component).map(|c| c.reference.clone()).unwrap_or_default();
                    per.entry(*n).or_default().push(json!({"component": r.component, "reference": reference, "pin": r.pin}));
                }
                let nets: Vec<Value> = q.nets.iter().map(|n| json!({"id": n.id, "name": n.name, "pins": per.remove(&n.id).unwrap_or_default()})).collect();
                json!({"result": {"nets": nets}})
            }
            "file.save" => {
                let path = text(p, "path")?;
                write(path, &to_vfpcb(pr))?;
                json!({"result": {"path": path}})
            }
            "file.export_kicad" => {
                let path = text(p, "path")?;
                write(path, &kicad::export_pcb(pr))?;
                json!({"result": {"path": path}})
            }
            "export.gerber" | "export.drill" | "export.fab" => {
                let dir = text(p, "dir")?;
                std::fs::create_dir_all(dir).map_err(|e| EngineError::io(format!("Could not create {dir}: {e}")))?;
                let mut files = BTreeMap::new();
                if op != "export.drill" {
                    files.extend(fab::gerbers(pr));
                }
                if op != "export.gerber" {
                    files.extend(fab::drills(pr));
                }
                if op == "export.fab" {
                    let base = pr.name.replace([' ', ',', '*', '/'], "_");
                    files.insert(format!("{base}-bom.csv"), fab::bom_csv(pr));
                    files.insert(format!("{base}-pos.csv"), fab::pnp_csv(pr));
                }
                let mut written = vec![];
                for (name, body) in &files {
                    let path = std::path::Path::new(dir).join(name);
                    write(&path.to_string_lossy(), body)?;
                    written.push(name.clone());
                }
                json!({"result": {"files": written}})
            }
            "export.bom" => {
                let path = text(p, "path")?;
                write(path, &fab::bom_csv(pr))?;
                json!({"result": {"path": path}})
            }
            "export.pnp" => {
                let path = text(p, "path")?;
                write(path, &fab::pnp_csv(pr))?;
                json!({"result": {"path": path}})
            }
            "commands.list" => json!({"result": commands()}),
            "link.geometry" => json!({"result": link_geometry(pr)}),
            _ => unreachable!(),
        })
    }

    fn next_reference(&self, prefix: &str) -> String {
        let mut n = 1;
        loop {
            let r = format!("{prefix}{n}");
            if !self.project.components.iter().any(|c| c.reference == r) {
                return r;
            }
            n += 1;
        }
    }

    fn add_component(&mut self, symbol: &str, position: Pt, reference: Option<&str>, value: Option<&str>, rotation: MilliDeg) -> Result<Id> {
        let s = self.project.library.symbols.get(symbol).cloned().ok_or_else(|| EngineError::not_found(format!("No symbol named {symbol} in the library")))?;
        let reference = match reference {
            Some(r) if !r.is_empty() => r.to_string(),
            _ if s.power => format!("#PWR{:02}", self.project.components.iter().filter(|c| c.reference.starts_with("#PWR")).count() + 1),
            _ => self.next_reference(&s.reference_prefix),
        };
        let id = self.project.alloc();
        let sheet = self.project.sheets[0].id;
        self.project.components.push(Component {
            id,
            sheet,
            reference,
            value: value.map(String::from).unwrap_or(s.value.clone()),
            kind: symbol.to_string(),
            symbol: symbol.to_string(),
            footprint: s.footprint.clone().filter(|f| self.project.library.footprints.contains_key(f)),
            position,
            rotation,
            no_connect: vec![],
        });
        Ok(id)
    }

    fn check_pin(&self, r: &PinRef) -> Result<()> {
        let c = self.project.component(r.component).ok_or_else(|| EngineError::not_found(format!("No component {}", r.component)))?;
        let s = self.project.symbol_of(c).ok_or_else(|| EngineError::not_found(format!("{} has no symbol", c.reference)))?;
        if !s.pins.iter().any(|p| p.number == r.pin) {
            return Err(EngineError::not_found(format!("{} has no pin {}", c.reference, r.pin)));
        }
        Ok(())
    }

    fn net_exists(&self, net: Id) -> Result<()> {
        self.project.net(net).map(|_| ()).ok_or_else(|| EngineError::not_found(format!("No net {net}")))
    }

    fn layer(&self, p: &Value) -> Result<String> {
        let l = opt_text(p, "layer").unwrap_or(FRONT_CU);
        if !COPPER.contains(&l) {
            return Err(EngineError::invalid(format!("Layer {l} is not a copper layer (F.Cu or B.Cu)")));
        }
        Ok(l.to_string())
    }

    fn pad_ref(&self, v: &Value) -> Result<(Id, Pt, Option<Id>)> {
        let fid = v.get("footprint").and_then(Value::as_u64).ok_or_else(|| EngineError::invalid("a pad is {\"footprint\": id, \"pad\": number}"))?;
        let num = match v.get("pad") {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Number(n)) => n.to_string(),
            _ => return Err(EngineError::invalid("a pad is {\"footprint\": id, \"pad\": number}")),
        };
        let f = self.project.footprint(fid).ok_or_else(|| EngineError::not_found(format!("No footprint {fid}")))?;
        let pad = f.pads.iter().find(|p| p.number == num).ok_or_else(|| EngineError::not_found(format!("Footprint {fid} has no pad {num}")))?;
        Ok((fid, f.pad_position(pad), pad.net))
    }

    fn assign_footprint(&mut self, component: Id, name: &str) -> Result<()> {
        let fp = self.project.library.footprints.get(name).cloned().ok_or_else(|| EngineError::not_found(format!("No footprint named {name} in the library")))?;
        let c = self.project.component(component).ok_or_else(|| EngineError::not_found(format!("No component {component}")))?;
        let s = self.project.symbol_of(c).cloned().ok_or_else(|| EngineError::not_found("component has no symbol"))?;
        for pin in &s.pins {
            if !fp.pads.iter().any(|q| q.number == pin.number) {
                return Err(EngineError::new("pin_pad_mismatch", format!("Footprint {name} has no pad {} for pin {}", pin.number, pin.name)));
            }
        }
        self.project.component_mut(component).unwrap().footprint = Some(name.to_string());
        Ok(())
    }

    /// Schematic to board: footprints for new parts, new pads for changed footprints, removed
    /// parts leave the board, pad nets follow the netlist.
    pub fn sync_board(&mut self) {
        let pr = &mut self.project;
        let nl = netlist::extract(pr);
        let comps: Vec<Component> = pr.components.clone();
        pr.board.footprints.retain(|f| comps.iter().any(|c| c.id == f.component && c.footprint.is_some()));
        let mut placed = 0;
        for c in &comps {
            let Some(name) = &c.footprint else { continue };
            let Some(def) = pr.library.footprints.get(name).cloned() else { continue };
            let pads: Vec<Pad> = def
                .pads
                .iter()
                .map(|d| Pad {
                    number: d.number.clone(),
                    kind: d.kind,
                    shape: d.shape,
                    offset: d.offset,
                    size: d.size,
                    rotation: d.rotation,
                    drill: d.drill,
                    net: nl.pin_net.get(&PinRef { component: c.id, pin: d.number.clone() }).copied(),
                })
                .collect();
            match pr.board.footprints.iter_mut().find(|f| f.component == c.id) {
                Some(f) => {
                    f.name = name.clone();
                    f.pads = pads;
                }
                None => {
                    // New parts start in a row along the top of the board, 8 mm apart.
                    let w = pr.board.width.max(mm(10.0));
                    let per_row = (w / mm(8.0)).max(1);
                    let at = Pt::new(mm(4.0) + (placed % per_row) * mm(8.0), mm(4.0) + (placed / per_row) * mm(8.0));
                    placed += 1;
                    let id = pr.alloc();
                    pr.board.footprints.push(Footprint { id, component: c.id, name: name.clone(), position: at, rotation: 0, side: Side::Front, pads });
                }
            }
        }
    }

    fn apply(&mut self, op: &str, p: &Value) -> Result<Value> {
        match op {
            "file.new" => {
                self.project = Project::default();
                Ok(done())
            }
            "project.rename" => {
                self.project.name = text(p, "name")?.to_string();
                Ok(done())
            }
            "library.symbol.upsert" => {
                let d = library::symbol_from_json(get(p, "definition")?)?;
                if let Some(n) = opt_text(p, "notice") {
                    self.project.library.notices.insert(d.name.clone(), n.to_string());
                }
                let name = d.name.clone();
                self.project.library.symbols.insert(name.clone(), d);
                Ok(json!({"result": {"name": name}}))
            }
            "library.footprint.upsert" => {
                let d = library::footprint_from_json(get(p, "definition")?)?;
                let name = d.name.clone();
                self.project.library.footprints.insert(name.clone(), d);
                Ok(json!({"result": {"name": name}}))
            }
            "component.add" => {
                let kind = text(p, "kind")?;
                if !library::BUILTIN_KINDS.contains(&kind) && !self.project.library.symbols.contains_key(kind) {
                    return Err(EngineError::not_found(format!("Unknown part kind {kind}")));
                }
                let rot = opt_num(p, "rotation").map(mdeg).unwrap_or(0);
                let id = self.add_component(kind, pt(p, "position")?, opt_text(p, "reference"), opt_text(p, "value"), rot)?;
                Ok(created(id))
            }
            "component.place_custom" => {
                let name = text(p, "name")?;
                let rot = opt_num(p, "rotation").map(mdeg).unwrap_or(0);
                let id = self.add_component(name, pt(p, "position")?, opt_text(p, "reference"), opt_text(p, "value"), rot)?;
                Ok(created(id))
            }
            "component.place_library" => {
                let path = text(p, "path")?;
                let sym = kicad::import_symbol(&read(path)?, text(p, "symbol")?)?;
                let name = sym.name.clone();
                self.project.library.symbols.insert(name.clone(), sym);
                let id = self.add_component(&name, pt(p, "position")?, opt_text(p, "reference"), opt_text(p, "value"), 0)?;
                Ok(created(id))
            }
            "component.move" => {
                let at = pt(p, "position")?;
                let c = self.project.component_mut(id(p, "id")?).ok_or_else(|| EngineError::not_found("No such component"))?;
                c.position = at;
                Ok(done())
            }
            "component.rotate" => {
                let a = mdeg(num(p, "degrees")?);
                let c = self.project.component_mut(id(p, "id")?).ok_or_else(|| EngineError::not_found("No such component"))?;
                c.rotation = a;
                Ok(done())
            }
            "component.set" => {
                let cid = id(p, "id")?;
                if let Some(r) = opt_text(p, "reference") {
                    if self.project.components.iter().any(|c| c.id != cid && c.reference == r) {
                        return Err(EngineError::new("duplicate_reference", format!("Reference {r} is taken")));
                    }
                }
                let c = self.project.component_mut(cid).ok_or_else(|| EngineError::not_found("No such component"))?;
                if let Some(r) = opt_text(p, "reference") {
                    c.reference = r.into();
                }
                if let Some(v) = opt_text(p, "value") {
                    c.value = v.into();
                }
                Ok(done())
            }
            "component.no_connect" => {
                let r = pinref(p)?;
                self.check_pin(&r)?;
                let on = p.get("on").and_then(Value::as_bool).unwrap_or(true);
                let c = self.project.component_mut(r.component).unwrap();
                c.no_connect.retain(|x| x != &r.pin);
                if on {
                    c.no_connect.push(r.pin);
                    c.no_connect.sort();
                }
                Ok(done())
            }
            "footprint.assign" => {
                let def = kicad::import_footprint(&read(text(p, "path")?)?)?;
                let name = def.name.clone();
                self.project.library.footprints.insert(name.clone(), def);
                self.assign_footprint(id(p, "id")?, &name)?;
                Ok(json!({"result": {"name": name}}))
            }
            "footprint.assign_custom" => {
                self.assign_footprint(id(p, "id")?, text(p, "name")?)?;
                Ok(done())
            }
            "footprint.move" => {
                let at = pt(p, "position")?;
                let f = self.project.footprint_mut(id(p, "id")?).ok_or_else(|| EngineError::not_found("No such footprint"))?;
                f.position = at;
                Ok(done())
            }
            "footprint.rotate" => {
                let a = mdeg(num(p, "degrees")?);
                let f = self.project.footprint_mut(id(p, "id")?).ok_or_else(|| EngineError::not_found("No such footprint"))?;
                f.rotation = a;
                Ok(done())
            }
            "footprint.flip" => {
                let f = self.project.footprint_mut(id(p, "id")?).ok_or_else(|| EngineError::not_found("No such footprint"))?;
                f.side = if f.side == Side::Front { Side::Back } else { Side::Front };
                Ok(done())
            }
            "wire.connect" => {
                let (a, b) = (pinref(get(p, "from")?)?, pinref(get(p, "to")?)?);
                self.check_pin(&a)?;
                self.check_pin(&b)?;
                if a == b {
                    return Err(EngineError::invalid("A wire needs two different pins"));
                }
                let id = self.project.alloc();
                self.project.wires.push(Wire { id, from: a, to: b, net: 0 });
                Ok(created(id))
            }
            "label.add" => {
                let r = pinref(get(p, "pin")?)?;
                self.check_pin(&r)?;
                let name = text(p, "name")?.to_string();
                let id = self.project.alloc();
                self.project.labels.push(Label { id, name, pin: r });
                Ok(created(id))
            }
            "net.create" => {
                let name = text(p, "name")?.trim().to_string();
                if name.is_empty() {
                    return Err(EngineError::invalid("A net needs a name"));
                }
                if let Some(n) = self.project.net_by_name(&name) {
                    if n.named {
                        return Err(EngineError::new("duplicate_net", format!("Net {name} exists")));
                    }
                }
                let id = self.project.alloc();
                self.project.nets.push(Net { id, name, named: true, pins: vec![], class: opt_text(p, "class").map(String::from) });
                Ok(created(id))
            }
            "net.connect" => {
                let net = id(p, "net")?;
                self.net_exists(net)?;
                let pins = get(p, "pins")?.as_array().ok_or_else(|| EngineError::invalid("`pins` must be a list"))?;
                let mut refs = vec![];
                for v in pins {
                    let r = pinref(v)?;
                    self.check_pin(&r)?;
                    refs.push(r);
                }
                let n = self.project.nets.iter_mut().find(|n| n.id == net).unwrap();
                n.named = true;
                for r in refs {
                    if !n.pins.contains(&r) {
                        n.pins.push(r);
                    }
                }
                Ok(done())
            }
            "net.rename" => {
                let (net, name) = (id(p, "id")?, text(p, "name")?.to_string());
                self.net_exists(net)?;
                let n = self.project.nets.iter_mut().find(|n| n.id == net).unwrap();
                n.name = name;
                n.named = true;
                Ok(done())
            }
            "net.set_class" => {
                let net = id(p, "net")?;
                self.net_exists(net)?;
                let class = opt_text(p, "class").map(String::from);
                if let Some(c) = &class {
                    if !self.project.net_classes.iter().any(|k| &k.name == c) {
                        return Err(EngineError::not_found(format!("No net class {c}")));
                    }
                }
                self.project.nets.iter_mut().find(|n| n.id == net).unwrap().class = class;
                Ok(done())
            }
            "netclass.set" => {
                let name = text(p, "name")?.to_string();
                let k = NetClass { name: name.clone(), clearance: len(p, "clearance")?, track_width: len(p, "track_width")? };
                self.project.net_classes.retain(|c| c.name != name);
                self.project.net_classes.push(k);
                self.project.net_classes.sort_by(|a, b| a.name.cmp(&b.name));
                Ok(done())
            }
            "rules.set" => {
                let r = &mut self.project.rules;
                for (k, slot) in [
                    ("clearance", &mut r.clearance),
                    ("min_track_width", &mut r.min_track_width),
                    ("track_width", &mut r.track_width),
                    ("via_diameter", &mut r.via_diameter),
                    ("via_drill", &mut r.via_drill),
                    ("min_annular_ring", &mut r.min_annular_ring),
                    ("min_drill", &mut r.min_drill),
                    ("hole_to_hole", &mut r.hole_to_hole),
                    ("edge_clearance", &mut r.edge_clearance),
                    ("route_grid", &mut r.route_grid),
                ] {
                    if let Some(v) = opt_len(p, k) {
                        if v < 0 {
                            return Err(EngineError::invalid(format!("`{k}` must not be negative")));
                        }
                        *slot = v;
                    }
                }
                if r.route_grid < mm(0.025) {
                    return Err(EngineError::invalid("route_grid must be at least 0.025 mm"));
                }
                Ok(json!({"result": rules_json(&self.project.rules)}))
            }
            "board.resize" => {
                let (w, h) = (len(p, "width")?, len(p, "height")?);
                if w <= 0 || h <= 0 {
                    return Err(EngineError::invalid("Board size must be positive"));
                }
                let b = &mut self.project.board;
                b.width = w;
                b.height = h;
                b.outline = Board::rect_outline(w, h);
                Ok(done())
            }
            "board.outline.set" => {
                let pts = points(p, "points")?;
                let bb = Aabb::of(&pts);
                if bb.min.x < 0 || bb.min.y < 0 {
                    return Err(EngineError::invalid("The outline must stay at x, y >= 0"));
                }
                let b = &mut self.project.board;
                b.width = bb.max.x;
                b.height = bb.max.y;
                b.outline = pts;
                Ok(done())
            }
            "board.cutout.add" => {
                let (c, r) = (pt(p, "center")?, len(p, "radius")?);
                if r <= 0 {
                    return Err(EngineError::invalid("radius must be positive"));
                }
                let id = self.project.alloc();
                self.project.board.cutouts.push(Cutout { id, center: c, radius: r });
                Ok(created(id))
            }
            "board.sync" => {
                self.sync_board();
                Ok(done())
            }
            "track.add" => {
                let net = id(p, "net")?;
                self.net_exists(net)?;
                let width = opt_len(p, "width").unwrap_or(self.project.net_rules(Some(net)).1);
                if width <= 0 {
                    return Err(EngineError::invalid("width must be positive"));
                }
                let layer = self.layer(p)?;
                let (start, end) = (pt(p, "start")?, pt(p, "end")?);
                let id = self.project.alloc();
                self.project.board.tracks.push(Track { id, net, start, end, width, layer, auto: false });
                Ok(created(id))
            }
            "track.route" => {
                let (fa, a, na) = self.pad_ref(get(p, "from")?)?;
                let (fb, b, nb) = self.pad_ref(get(p, "to")?)?;
                let net = match (na, nb) {
                    (Some(x), Some(y)) if x == y => x,
                    (Some(_), Some(_)) => return Err(EngineError::new("net_mismatch", "The two pads are on different nets")),
                    _ => return Err(EngineError::new("no_net", "Both pads need a net: connect them in the schematic and update the board")),
                };
                let width = opt_len(p, "width").unwrap_or(self.project.net_rules(Some(net)).1);
                let layer = self.layer(p)?;
                let ids = router::route_one(&mut self.project, net, (fa, a), (fb, b), &layer, width)?;
                Ok(json!({"result": {"ids": ids, "id": ids.first()}}))
            }
            "via.add" => {
                let net = id(p, "net")?;
                self.net_exists(net)?;
                let d = opt_len(p, "diameter").unwrap_or(self.project.rules.via_diameter);
                let dr = opt_len(p, "drill").unwrap_or(self.project.rules.via_drill);
                if dr <= 0 || d <= dr {
                    return Err(EngineError::invalid("A via needs 0 < drill < diameter"));
                }
                let id = self.project.alloc();
                self.project.board.vias.push(Via { id, net, at: pt(p, "at")?, diameter: d, drill: dr, auto: false });
                Ok(created(id))
            }
            "zone.add" => {
                let net = id(p, "net")?;
                self.net_exists(net)?;
                let layer = self.layer(p)?;
                let r = &self.project.rules;
                let z = Zone {
                    id: 0,
                    net,
                    layer,
                    outline: points(p, "points")?,
                    clearance: opt_len(p, "clearance").unwrap_or(r.clearance),
                    thermal_gap: opt_len(p, "thermal_gap").unwrap_or(mm(0.5)),
                    spoke_width: opt_len(p, "spoke_width").unwrap_or(mm(0.5)),
                    min_width: opt_len(p, "min_width").unwrap_or(mm(0.25)),
                    filled: vec![],
                };
                let id = self.project.alloc();
                self.project.board.zones.push(Zone { id, ..z });
                zones::fill_all(&mut self.project);
                Ok(created(id))
            }
            "zone.fill" => {
                zones::fill_all(&mut self.project);
                Ok(done())
            }
            "keepout.add" => {
                let layers: Vec<String> = p.get("layers").and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                let id = self.project.alloc();
                self.project.board.keepouts.push(Keepout {
                    id,
                    outline: points(p, "points")?,
                    layers,
                    tracks: p.get("tracks").and_then(Value::as_bool).unwrap_or(true),
                    vias: p.get("vias").and_then(Value::as_bool).unwrap_or(true),
                });
                Ok(created(id))
            }
            "route.auto" => {
                let layers: Vec<String> = match p.get("layers").and_then(Value::as_array) {
                    Some(a) => a.iter().filter_map(|x| x.as_str().map(String::from)).collect(),
                    None => COPPER.iter().map(|s| s.to_string()).collect(),
                };
                for l in &layers {
                    if !COPPER.contains(&l.as_str()) {
                        return Err(EngineError::invalid(format!("Layer {l} is not a copper layer")));
                    }
                }
                let opt = router::Options {
                    layers,
                    width: opt_len(p, "width").unwrap_or(self.project.rules.track_width),
                    allow_vias: p.get("vias").and_then(Value::as_bool).unwrap_or(true),
                    ripup: p.get("ripup").and_then(Value::as_bool).unwrap_or(true),
                };
                let r = router::autoroute(&mut self.project, &opt)?;
                if !self.project.board.zones.is_empty() {
                    zones::fill_all(&mut self.project);
                }
                Ok(json!({"result": {"connections": r.connections, "routed": r.routed, "failed": r.failed, "ripups": r.ripups, "vias": r.vias}}))
            }
            "route.clear" => {
                let b = &mut self.project.board;
                b.tracks.retain(|t| !t.auto);
                b.vias.retain(|v| !v.auto);
                Ok(done())
            }
            "file.open" => {
                let path = text(p, "path")?;
                let src = read(path)?;
                self.project = if path.ends_with(".kicad_pcb") { kicad::import_pcb(&src)? } else { from_vfpcb(&src)? };
                Ok(done())
            }
            "file.import_kicad" => {
                self.project = kicad::import_pcb(&read(text(p, "path")?)?)?;
                Ok(done())
            }
            "object.delete" => {
                let oid = id(p, "id")?;
                self.delete(oid)?;
                Ok(done())
            }
            _ => Err(EngineError::new("unknown_command", format!("Unknown PCB command {op}"))),
        }
    }

    fn delete(&mut self, oid: Id) -> Result<()> {
        let pr = &mut self.project;
        if pr.components.iter().any(|c| c.id == oid) {
            pr.components.retain(|c| c.id != oid);
            pr.wires.retain(|w| w.from.component != oid && w.to.component != oid);
            pr.labels.retain(|l| l.pin.component != oid);
            for n in &mut pr.nets {
                n.pins.retain(|r| r.component != oid);
            }
            pr.board.footprints.retain(|f| f.component != oid);
            return Ok(());
        }
        let b = &mut pr.board;
        let before = (b.footprints.len(), b.tracks.len(), b.vias.len(), b.zones.len(), b.cutouts.len(), b.keepouts.len());
        b.footprints.retain(|x| x.id != oid);
        b.tracks.retain(|x| x.id != oid);
        b.vias.retain(|x| x.id != oid);
        b.zones.retain(|x| x.id != oid);
        b.cutouts.retain(|x| x.id != oid);
        b.keepouts.retain(|x| x.id != oid);
        if before != (b.footprints.len(), b.tracks.len(), b.vias.len(), b.zones.len(), b.cutouts.len(), b.keepouts.len()) {
            return Ok(());
        }
        let (w, l) = (pr.wires.len(), pr.labels.len());
        pr.wires.retain(|x| x.id != oid);
        pr.labels.retain(|x| x.id != oid);
        if (w, l) != (pr.wires.len(), pr.labels.len()) {
            return Ok(());
        }
        if pr.nets.iter().any(|n| n.id == oid) {
            pr.nets.retain(|n| n.id != oid);
            pr.board.tracks.retain(|t| t.net != oid);
            pr.board.vias.retain(|v| v.net != oid);
            pr.board.zones.retain(|z| z.net != oid);
            return Ok(());
        }
        Err(EngineError::not_found(format!("No object {oid}")))
    }

    /// The `pcb_inspect` reply, in the shape the Swift `PCBInspect` decodes (millimetres).
    pub fn inspect(&self) -> Value {
        let pr = &self.project;
        let mut q = pr.clone();
        let nl = netlist::extract(&mut q);
        let comps: Vec<Value> = pr
            .components
            .iter()
            .map(|c| {
                let pins: Vec<Value> = pr
                    .symbol_of(c)
                    .map(|s| {
                        s.pins
                            .iter()
                            .map(|pin| {
                                json!({"number": pin.number, "name": pin.name, "kind": pin.kind.name(),
                                       "net": nl.pin_net.get(&PinRef { component: c.id, pin: pin.number.clone() }),
                                       "offset": ptv(pin.position)})
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                json!({"id": c.id, "reference": c.reference, "value": c.value, "kind": c.kind, "footprint": c.footprint,
                       "position": ptv(c.position), "rotation": to_deg(c.rotation), "pins": pins})
            })
            .collect();
        let wires: Vec<Value> = pr
            .wires
            .iter()
            .map(|w| json!({"id": w.id, "net": w.net, "from": {"component": w.from.component, "pin": w.from.pin}, "to": {"component": w.to.component, "pin": w.to.pin}}))
            .collect();
        let labels: Vec<Value> = pr.labels.iter().map(|l| json!({"id": l.id, "name": l.name, "pin": {"component": l.pin.component, "pin": l.pin.pin}})).collect();
        let nets: Vec<Value> = pr.nets.iter().map(|n| json!({"id": n.id, "name": n.name, "class": n.class})).collect();
        let b = &pr.board;
        let fps: Vec<Value> = b
            .footprints
            .iter()
            .map(|f| {
                let pads: Vec<Value> = f
                    .pads
                    .iter()
                    .map(|pad| {
                        json!({"number": pad.number, "offset": ptv(pad.offset), "diameter": to_mm(pad.size.x.max(pad.size.y)), "net": pad.net,
                               "drill": pad.drill.map(to_mm), "rotation": to_deg(pad.rotation),
                               "geometry": {"shape": pad.shape.name(), "kind": match pad.kind { PadKind::Tht => "thru_hole", PadKind::Smd => "smd", PadKind::Npth => "np_thru_hole" },
                                            "size": ptv(pad.size)}})
                    })
                    .collect();
                json!({"id": f.id, "component": f.component, "name": f.name, "position": ptv(f.position), "rotation": to_deg(f.rotation),
                       "side": if f.side == Side::Front { "front" } else { "back" }, "pads": pads})
            })
            .collect();
        let tracks: Vec<Value> =
            b.tracks.iter().map(|t| json!({"id": t.id, "net": t.net, "start": ptv(t.start), "end": ptv(t.end), "width": to_mm(t.width), "layer": t.layer})).collect();
        let vias: Vec<Value> = b.vias.iter().map(|v| json!({"id": v.id, "net": v.net, "at": ptv(v.at), "diameter": to_mm(v.diameter), "drill": to_mm(v.drill)})).collect();
        let zones: Vec<Value> = b
            .zones
            .iter()
            .map(|z| {
                let fill: Vec<Vec<Vec<Value>>> = z.filled.iter().map(|s| s.iter().map(|r| r.iter().map(|p| ptv(*p)).collect()).collect()).collect();
                json!({"id": z.id, "net": z.net, "layer": z.layer, "outline": z.outline.iter().map(|p| ptv(*p)).collect::<Vec<_>>(), "filled": fill})
            })
            .collect();
        let (u, r) = self.history();
        json!({
            "revision": self.revision,
            "history": {"undo": u, "redo": r},
            "project": {
                "name": pr.name,
                "components": comps,
                "wires": wires,
                "labels": labels,
                "nets": nets,
                "board": {
                    "width": to_mm(b.width), "height": to_mm(b.height), "thickness": to_mm(b.thickness),
                    "clearance": to_mm(pr.rules.clearance),
                    "outline": b.outline.iter().map(|p| ptv(*p)).collect::<Vec<_>>(),
                    "cutouts": b.cutouts.iter().map(|c| json!({"id": c.id, "center": ptv(c.center), "radius": to_mm(c.radius)})).collect::<Vec<_>>(),
                    "footprints": fps, "tracks": tracks, "vias": vias, "zones": zones,
                    "keepouts": b.keepouts.iter().map(|k| json!({"id": k.id, "outline": k.outline.iter().map(|p| ptv(*p)).collect::<Vec<_>>(), "layers": k.layers})).collect::<Vec<_>>(),
                },
            },
        })
    }

    /// The `pcb_checks` reply.
    pub fn checks(&self) -> Value {
        checks::checks_json(&self.project)
    }
}

/// What the board to 3D link needs (VIAFORM-SPEC 7.4, `vf_link_*`): outline and thickness,
/// every hole, copper per layer as polygons, and a box per part (pad extent plus 0.5 mm, a
/// nominal 3 mm tall until parts carry 3D models). Millimetres, board frame (y down).
pub fn link_geometry(p: &Project) -> Value {
    let poly = |r: &[Pt]| r.iter().map(|q| ptv(*q)).collect::<Vec<_>>();
    let mut holes = vec![];
    for f in &p.board.footprints {
        for pad in &f.pads {
            if let Some(d) = pad.drill {
                holes.push(json!({"center": ptv(f.pad_position(pad)), "diameter": to_mm(d), "plated": pad.kind == PadKind::Tht}));
            }
        }
    }
    for v in &p.board.vias {
        holes.push(json!({"center": ptv(v.at), "diameter": to_mm(v.drill), "plated": true}));
    }
    for c in &p.board.cutouts {
        holes.push(json!({"center": ptv(c.center), "diameter": to_mm(2 * c.radius), "plated": false, "cutout": true}));
    }
    let items = crate::copper::collect(p);
    let mut copper = serde_json::Map::new();
    for layer in COPPER {
        let shapes: Vec<Value> = items
            .iter()
            .filter(|it| it.on(layer))
            .map(|it| json!({"net": it.net, "object": it.object, "rings": it.prim.to_polygon(0).iter().map(|r| poly(r)).collect::<Vec<_>>()}))
            .collect();
        copper.insert(layer.to_string(), Value::Array(shapes));
    }
    let bodies: Vec<Value> = p
        .board
        .footprints
        .iter()
        .map(|f| {
            let pts: Vec<Pt> = f.pads.iter().flat_map(|q| {
                let c = f.pad_position(q);
                let h = q.size.x.max(q.size.y) / 2;
                [Pt::new(c.x - h, c.y - h), Pt::new(c.x + h, c.y + h)]
            }).collect();
            let b = if pts.is_empty() { Aabb { min: f.position, max: f.position } } else { Aabb::of(&pts) }.grow(mm(0.5));
            let reference = p.component(f.component).map(|c| c.reference.clone()).unwrap_or_default();
            json!({"footprint": f.id, "component": f.component, "reference": reference, "side": if f.side == Side::Front { "front" } else { "back" },
                   "min": ptv(b.min), "max": ptv(b.max), "height": 3.0})
        })
        .collect();
    json!({"outline": poly(&p.board.outline), "thickness": to_mm(p.board.thickness), "holes": holes, "copper": copper, "bodies": bodies})
}

fn rules_json(r: &Rules) -> Value {
    json!({"clearance": mmv(r.clearance), "min_track_width": mmv(r.min_track_width), "track_width": mmv(r.track_width),
           "via_diameter": mmv(r.via_diameter), "via_drill": mmv(r.via_drill), "min_annular_ring": mmv(r.min_annular_ring),
           "min_drill": mmv(r.min_drill), "hole_to_hole": mmv(r.hole_to_hole), "edge_clearance": mmv(r.edge_clearance),
           "route_grid": mmv(r.route_grid)})
}

/// The `pcb_commands` listing: id, group, parameters and whether the command changes the
/// project, for the UI and for agents.
pub fn commands() -> Value {
    let c = |id: &str, group: &str, label: &str, params: Value| json!({"id": id, "group": group, "label": label, "params": params, "mutates": !READ_ONLY.contains(&id)});
    let pos = json!({"type": "point", "unit": "mm"});
    let pin = json!({"type": "pin", "shape": {"component": "id", "pin": "string"}});
    let pad = json!({"type": "pad", "shape": {"footprint": "id", "pad": "string"}});
    Value::Array(vec![
        c("file.new", "FILE", "New project", json!({})),
        c("file.open", "FILE", "Open (.vfpcb or .kicad_pcb)", json!({"path": "string"})),
        c("file.save", "FILE", "Save (.vfpcb)", json!({"path": "string"})),
        c("file.export_kicad", "FILE", "Export KiCad board", json!({"path": "string"})),
        c("file.import_kicad", "FILE", "Import KiCad board", json!({"path": "string"})),
        c("project.rename", "FILE", "Rename project", json!({"name": "string"})),
        c("undo", "EDIT", "Undo", json!({})),
        c("redo", "EDIT", "Redo", json!({})),
        c("object.delete", "EDIT", "Delete", json!({"id": "id"})),
        c("library.symbol.upsert", "LIBRARY", "Add or replace a symbol", json!({"definition": "object", "notice": "string?"})),
        c("library.footprint.upsert", "LIBRARY", "Add or replace a footprint", json!({"definition": "object"})),
        c("component.add", "SCHEMATIC", "Place a part", json!({"kind": library::BUILTIN_KINDS, "position": pos, "reference": "string?", "value": "string?", "rotation": "degrees?"})),
        c("component.place_custom", "SCHEMATIC", "Place a library symbol", json!({"name": "string", "position": pos, "reference": "string?", "value": "string?"})),
        c("component.place_library", "SCHEMATIC", "Place a KiCad symbol", json!({"path": ".kicad_sym", "symbol": "string", "position": pos})),
        c("component.move", "SCHEMATIC", "Move a part", json!({"id": "id", "position": pos})),
        c("component.rotate", "SCHEMATIC", "Rotate a part", json!({"id": "id", "degrees": "number"})),
        c("component.set", "SCHEMATIC", "Set reference or value", json!({"id": "id", "reference": "string?", "value": "string?"})),
        c("component.no_connect", "SCHEMATIC", "Mark a pin not connected", json!({"component": "id", "pin": "string", "on": "bool?"})),
        c("wire.connect", "SCHEMATIC", "Wire two pins", json!({"from": pin, "to": pin})),
        c("label.add", "SCHEMATIC", "Label a pin", json!({"name": "string", "pin": pin})),
        c("net.create", "SCHEMATIC", "Create a net", json!({"name": "string", "class": "string?"})),
        c("net.connect", "SCHEMATIC", "Put pins on a net", json!({"net": "id", "pins": [pin]})),
        c("net.rename", "SCHEMATIC", "Rename a net", json!({"id": "id", "name": "string"})),
        c("net.set_class", "RULES", "Set a net's class", json!({"net": "id", "class": "string?"})),
        c("netclass.set", "RULES", "Define a net class", json!({"name": "string", "clearance": "mm", "track_width": "mm"})),
        c("rules.get", "RULES", "Design rules", json!({})),
        c("rules.set", "RULES", "Set design rules", json!({"clearance": "mm?", "min_track_width": "mm?", "track_width": "mm?", "via_diameter": "mm?", "via_drill": "mm?", "min_annular_ring": "mm?", "min_drill": "mm?", "hole_to_hole": "mm?", "edge_clearance": "mm?", "route_grid": "mm?"})),
        c("footprint.assign", "BOARD", "Assign a KiCad footprint", json!({"id": "component id", "path": ".kicad_mod"})),
        c("footprint.assign_custom", "BOARD", "Assign a library footprint", json!({"id": "component id", "name": "string"})),
        c("board.resize", "BOARD", "Board size", json!({"width": "mm", "height": "mm"})),
        c("board.outline.set", "BOARD", "Board outline", json!({"points": [pos]})),
        c("board.cutout.add", "BOARD", "Add a round cutout", json!({"center": pos, "radius": "mm"})),
        c("board.sync", "BOARD", "Update board from schematic", json!({})),
        c("footprint.move", "BOARD", "Move a footprint", json!({"id": "id", "position": pos})),
        c("footprint.rotate", "BOARD", "Rotate a footprint", json!({"id": "id", "degrees": "number"})),
        c("footprint.flip", "BOARD", "Flip to the other side", json!({"id": "id"})),
        c("track.add", "TRACK", "Add a track segment", json!({"net": "id", "start": pos, "end": pos, "width": "mm?", "layer": "F.Cu|B.Cu"})),
        c("track.route", "TRACK", "Route track", json!({"from": pad, "to": pad, "width": "mm?", "layer": "F.Cu|B.Cu"})),
        c("via.add", "TRACK", "Add a via", json!({"net": "id", "at": pos, "diameter": "mm?", "drill": "mm?"})),
        c("zone.add", "TRACK", "Add a copper zone", json!({"net": "id", "layer": "F.Cu|B.Cu", "points": [pos], "clearance": "mm?", "thermal_gap": "mm?", "spoke_width": "mm?", "min_width": "mm?"})),
        c("zone.fill", "TRACK", "Refill zones", json!({})),
        c("keepout.add", "TRACK", "Add a keep-out", json!({"points": [pos], "layers": ["string"], "tracks": "bool?", "vias": "bool?"})),
        c("route.auto", "TRACK", "Autoroute", json!({"layers": ["F.Cu", "B.Cu"], "width": "mm?", "vias": "bool?", "ripup": "bool?"})),
        c("route.clear", "TRACK", "Remove autorouted copper", json!({})),
        c("check.erc", "CHECK", "Electrical rules", json!({})),
        c("check.drc", "CHECK", "Design rules", json!({})),
        c("check.all", "CHECK", "ERC, DRC and airwires", json!({})),
        c("netlist.get", "CHECK", "Netlist", json!({})),
        c("ratsnest.get", "CHECK", "Airwires", json!({})),
        c("export.gerber", "MAKE", "Gerber files", json!({"dir": "string"})),
        c("export.drill", "MAKE", "Drill files", json!({"dir": "string"})),
        c("export.bom", "MAKE", "Bill of materials CSV", json!({"path": "string"})),
        c("export.pnp", "MAKE", "Pick and place CSV", json!({"path": "string"})),
        c("export.fab", "MAKE", "Gerbers, drills, BOM and placement", json!({"dir": "string"})),
        c("link.geometry", "3D", "Board geometry for the 3D link", json!({})),
        c("commands.list", "HELP", "This listing", json!({})),
    ])
}
