//! Mass properties: per component and for the whole assembly, mass, centre of mass and the
//! inertia tensor about it.
//!
//! A component's mass adds up from its design bodies (SolidCraft's measured mass and centre
//! when the design is open, the inertia from the body's mesh scaled to that mass, as SolidCraft
//! measures it; else the mesh at the body's density), its bought parts (the BOM line's mass,
//! a box inertia when the part has a size), the linked board, and its proxy box when no body
//! geometry is at hand. A mass override replaces the total last.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::geom::{Aabb, Mesh};
use super::kin::{Q, fk};
use super::math::{Iso, M3, V3, add, mat_mul, scale, sub, transpose};
use super::model::{Assembly, Component};

/// Density used for a body nothing else gives one to (PLA, the printed default), g/cm³.
pub const DEFAULT_DENSITY_G_CM3: f64 = 1.24;

/// One design body as the assembly sees it.
#[derive(Clone, Debug, Default)]
pub struct BodyGeom {
    /// Closed mesh at the home pose (mm, world).
    pub mesh: Mesh,
    pub density_g_cm3: Option<f64>,
    /// SolidCraft's own measure (kernel volume times material density), when the design is open.
    pub measured_mass_kg: Option<f64>,
    pub measured_center_mm: Option<V3>,
}

/// The geometry at hand: design bodies by name, the bodies of each linked board component, and
/// the BOM's per-line masses.
#[derive(Clone, Debug, Default)]
pub struct Geometry {
    pub bodies: BTreeMap<String, BodyGeom>,
    /// Bodies of a design component (`PCB Board` -> its bodies), for linked boards.
    pub component_bodies: BTreeMap<String, Vec<String>>,
    /// BOM line id -> mass of one (g).
    pub bom_mass_g: BTreeMap<String, f64>,
}

impl Geometry {
    /// Geometry from JSON: `{bodies: {name: {box: {min, max}} | {mesh: {positions, indices}},
    /// density_g_cm3?, mass_kg?, center_mm?}, component_bodies?: {name: [bodies]}, bom?: bom.json}`.
    pub fn from_json(v: &Value) -> Result<Self, String> {
        let mut g = Geometry::default();
        if let Some(bodies) = v.get("bodies").and_then(Value::as_object) {
            for (name, b) in bodies {
                let mesh = if let Some(bx) = b.get("box") {
                    Mesh::cuboid(v3(&bx["min"]).ok_or(format!("{name}: box.min"))?, v3(&bx["max"]).ok_or(format!("{name}: box.max"))?)
                } else if let Some(m) = b.get("mesh") {
                    let pos: Vec<f32> = m["positions"].as_array().into_iter().flatten().filter_map(Value::as_f64).map(|x| x as f32).collect();
                    let idx: Vec<u32> = m["indices"].as_array().into_iter().flatten().filter_map(Value::as_u64).map(|x| x as u32).collect();
                    Mesh::from_flat(&pos, &idx)
                } else {
                    return Err(format!("{name}: a body needs a box or a mesh"));
                };
                g.bodies.insert(
                    name.clone(),
                    BodyGeom {
                        mesh,
                        density_g_cm3: b["density_g_cm3"].as_f64(),
                        measured_mass_kg: b["mass_kg"].as_f64(),
                        measured_center_mm: v3(&b["center_mm"]),
                    },
                );
            }
        }
        if let Some(cb) = v.get("component_bodies").and_then(Value::as_object) {
            for (k, list) in cb {
                g.component_bodies.insert(k.clone(), list.as_array().into_iter().flatten().filter_map(|x| x.as_str().map(str::to_owned)).collect());
            }
        }
        if let Some(bom) = v.get("bom") {
            g.add_bom(bom);
        }
        Ok(g)
    }

    /// Reads each line's `id` and `mass_g` from a `bom.json` document.
    pub fn add_bom(&mut self, bom: &Value) {
        for l in bom["lines"].as_array().into_iter().flatten() {
            if let (Some(id), Some(m)) = (l["id"].as_str(), l["mass_g"].as_f64()) {
                self.bom_mass_g.insert(id.to_owned(), m);
            }
        }
    }

    /// The closed meshes a component collides with, at the home pose: its bodies and its board,
    /// else its proxy box.
    pub fn meshes_of(&self, c: &Component) -> Vec<Mesh> {
        let mut out: Vec<Mesh> = self.body_names(c).iter().filter_map(|b| self.bodies.get(b)).map(|b| b.mesh.clone()).collect();
        if out.is_empty()
            && let Some(p) = &c.proxy
        {
            out.push(Mesh::cuboid(p.min_mm, p.max_mm));
        }
        out
    }

    /// The design bodies of a component: its own and its board's.
    pub fn body_names(&self, c: &Component) -> Vec<String> {
        let mut names = c.bodies.clone();
        if let Some(p) = &c.pcb {
            names.extend(self.component_bodies.get(&p.component).cloned().unwrap_or_default());
        }
        names
    }
}

pub fn v3(v: &Value) -> Option<V3> {
    let a = v.as_array()?;
    (a.len() == 3).then(|| [a[0].as_f64(), a[1].as_f64(), a[2].as_f64()]).and_then(|[x, y, z]| Some([x?, y?, z?]))
}

/// Mass, centre (mm) and inertia about the centre (kg·mm², world axes).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Inertial {
    pub mass: f64,
    pub com: V3,
    pub inertia: M3,
}

impl Inertial {
    pub fn point(mass: f64, at: V3) -> Self {
        Self { mass, com: at, inertia: [[0.0; 3]; 3] }
    }

    /// A solid box of `mass` centred at `c` with sides `d`.
    pub fn cuboid(mass: f64, c: V3, d: V3) -> Self {
        let k = mass / 12.0;
        let mut i = [[0.0; 3]; 3];
        i[0][0] = k * (d[1] * d[1] + d[2] * d[2]);
        i[1][1] = k * (d[0] * d[0] + d[2] * d[2]);
        i[2][2] = k * (d[0] * d[0] + d[1] * d[1]);
        Self { mass, com: c, inertia: i }
    }

    /// The masses add, the centre is mass-weighted, tensors move to it (parallel axis).
    pub fn combine(parts: &[Inertial]) -> Inertial {
        let mass: f64 = parts.iter().map(|p| p.mass).sum();
        if !(mass > 0.0) {
            return Inertial::default();
        }
        let com = scale(parts.iter().fold([0.0; 3], |acc, p| add(acc, scale(p.com, p.mass))), 1.0 / mass);
        let mut inertia = [[0.0; 3]; 3];
        for p in parts {
            let d = sub(p.com, com);
            let dd = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
            for r in 0..3 {
                for k in 0..3 {
                    inertia[r][k] += p.inertia[r][k] + p.mass * (if r == k { dd } else { 0.0 } - d[r] * d[k]);
                }
            }
        }
        Inertial { mass, com, inertia }
    }

    pub fn moved(&self, t: &Iso) -> Inertial {
        Inertial { mass: self.mass, com: t.apply(self.com), inertia: mat_mul(&mat_mul(&t.rot, &self.inertia), &transpose(&t.rot)) }
    }

    pub fn to_json(&self) -> Value {
        json!({"mass_kg": self.mass, "center_of_mass_mm": self.com, "inertia_kg_mm2": self.inertia})
    }
}

/// One component's mass at the home pose, with where each share came from and what is missing.
pub fn component_inertial(asm: &Assembly, c: &Component, g: &Geometry) -> (Inertial, Vec<Value>, Vec<String>) {
    let mut parts = Vec::new();
    let mut sources = Vec::new();
    let mut warnings = Vec::new();
    let mut body_found = false;
    for name in g.body_names(c) {
        let Some(b) = g.bodies.get(&name) else {
            warnings.push(format!("{}: body {name} is not in the design", c.id));
            continue;
        };
        body_found = true;
        let mo = b.mesh.moments();
        let density = b.density_g_cm3.unwrap_or(DEFAULT_DENSITY_G_CM3) * 1e-6; // kg per mm³
        let mesh_mass = mo.volume * density;
        let mass = b.measured_mass_kg.unwrap_or(mesh_mass);
        let com = b.measured_center_mm.unwrap_or(mo.centroid);
        let mut inertia = mo.inertia_about_centroid(density);
        if mesh_mass > 0.0 {
            let k = mass / mesh_mass;
            inertia = inertia.map(|r| r.map(|x| x * k));
        } else {
            warnings.push(format!("{}: body {name} is not a closed solid", c.id));
        }
        parts.push(Inertial { mass, com, inertia });
        sources.push(json!({"kind": "body", "name": name, "mass_kg": mass}));
    }
    for p in &c.parts {
        let one = p.mass_kg.or_else(|| p.bom_line.as_ref().and_then(|l| g.bom_mass_g.get(l)).map(|g| g / 1000.0));
        let Some(one) = one else {
            warnings.push(format!("{}: {} has no mass (set mass_kg or the BOM line's mass)", c.id, p.part));
            continue;
        };
        let mass = one * f64::from(p.qty.max(1));
        parts.push(match p.dims_mm {
            Some(d) => Inertial::cuboid(mass, p.at_mm, d),
            None => Inertial::point(mass, p.at_mm),
        });
        sources.push(json!({"kind": "part", "name": p.part, "bom_line": p.bom_line, "mass_kg": mass}));
    }
    if let Some(pcb) = &c.pcb
        && !g.component_bodies.contains_key(&pcb.component)
    {
        match pcb.mass_kg {
            Some(m) => {
                let at = c.proxy.as_ref().map_or([0.0; 3], |p| Aabb { min: p.min_mm, max: p.max_mm }.center());
                parts.push(Inertial::point(m, at));
                sources.push(json!({"kind": "pcb", "name": pcb.component, "revision": pcb.tag(), "mass_kg": m}));
            }
            None => warnings.push(format!("{}: the board {} is not in the design yet", c.id, pcb.component)),
        }
    }
    if !body_found
        && let Some(p) = &c.proxy
        && let Some(m) = p.mass_kg
    {
        let b = Aabb { min: p.min_mm, max: p.max_mm };
        parts.push(Inertial::cuboid(m, b.center(), b.size()));
        sources.push(json!({"kind": "proxy", "name": c.id, "mass_kg": m}));
    }
    let mut total = Inertial::combine(&parts);
    if let Some(o) = asm.mass_overrides.iter().find(|o| o.component == c.id) {
        let k = if total.mass > 0.0 { o.mass_kg / total.mass } else { 0.0 };
        total.inertia = total.inertia.map(|r| r.map(|x| x * k));
        total.mass = o.mass_kg;
        if let Some(com) = o.center_of_mass_mm {
            total.com = com;
        }
        if let Some(i) = o.inertia_kg_mm2 {
            total.inertia = i;
        }
        sources.push(json!({"kind": "override", "name": c.id, "mass_kg": o.mass_kg}));
    }
    (total, sources, warnings)
}

/// Mass properties of every component and of the whole, at joint values `q`.
pub fn mass_props(asm: &Assembly, g: &Geometry, q: &Q) -> Value {
    let poses = fk(asm, q);
    let mut all = Vec::new();
    let mut rows = Vec::new();
    let mut warnings = Vec::new();
    let mut bought = 0.0;
    for c in &asm.components {
        let (home, sources, w) = component_inertial(asm, c, g);
        let now = home.moved(&poses.get(&c.id).copied().unwrap_or_default());
        bought += sources.iter().filter(|s| s["kind"] == "part").filter_map(|s| s["mass_kg"].as_f64()).sum::<f64>();
        let mut row = now.to_json();
        row["component"] = json!(c.id);
        row["sources"] = json!(sources);
        rows.push(row);
        warnings.extend(w);
        all.push(now);
    }
    let total = Inertial::combine(&all);
    json!({"components": rows, "total": total.to_json(), "bought_mass_kg": bought, "warnings": warnings})
}
