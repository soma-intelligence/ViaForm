//! Interference between components at a pose, and the motion study: one joint swept over its
//! range, the poses and the collisions at each step.
//!
//! Broad phase: world bounding boxes of each component's meshes. Exact phase: the volume both
//! solids fill inside the common box ([`geom::shared_volume`]). Components a joint ties together
//! touch by design and are left out unless asked (`include_adjacent`).

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::geom::{self, Aabb, Mesh};
use super::kin::{Q, fk, joint_frame, leaves, poses_json};
use super::math::Iso;
use super::mass::Geometry;
use super::model::{Assembly, MotionStudy};

#[derive(Clone, Copy, Debug)]
pub struct Options {
    /// Grid step of the exact phase (mm); 0 picks one from the overlap's size.
    pub cell_mm: f64,
    pub include_adjacent: bool,
    /// Overlaps smaller than this (mm³) do not count.
    pub min_volume_mm3: f64,
}

impl Default for Options {
    fn default() -> Self {
        Self { cell_mm: 0.0, include_adjacent: false, min_volume_mm3: 1e-3 }
    }
}

impl Options {
    pub fn from_json(p: &Value) -> Self {
        let d = Self::default();
        Self {
            cell_mm: p["cell_mm"].as_f64().unwrap_or(d.cell_mm),
            include_adjacent: p["include_adjacent"].as_bool().unwrap_or(d.include_adjacent),
            min_volume_mm3: p["min_volume_mm3"].as_f64().unwrap_or(d.min_volume_mm3),
        }
    }
}

/// Every component's meshes at its home pose, computed once per study.
pub struct Shapes {
    pub home: BTreeMap<String, Vec<Mesh>>,
}

impl Shapes {
    pub fn new(asm: &Assembly, g: &Geometry) -> Self {
        Self { home: asm.components.iter().map(|c| (c.id.clone(), g.meshes_of(c))).collect() }
    }
}

fn adjacent(asm: &Assembly) -> BTreeSet<(String, String)> {
    asm.joints.iter().map(|j| pair(&j.parent, &j.child)).collect()
}

fn pair(a: &str, b: &str) -> (String, String) {
    if a <= b { (a.to_owned(), b.to_owned()) } else { (b.to_owned(), a.to_owned()) }
}

/// The colliding pairs at `poses`: `[{a, b, volume_mm3, region: {min, max}}]`.
pub fn interference_at(asm: &Assembly, shapes: &Shapes, poses: &BTreeMap<String, Iso>, opts: &Options) -> Vec<Value> {
    let skip = if opts.include_adjacent { BTreeSet::new() } else { adjacent(asm) };
    let placed: Vec<(&str, Vec<Mesh>, Aabb)> = asm
        .components
        .iter()
        .filter_map(|c| {
            let meshes: Vec<Mesh> = shapes.home.get(&c.id)?.iter().map(|m| m.transformed(&poses.get(&c.id).copied().unwrap_or_default())).collect();
            let b = meshes.iter().map(Mesh::aabb).fold(Aabb::EMPTY, |a, b| a.union(&b));
            (!meshes.is_empty() && !b.is_empty()).then_some((c.id.as_str(), meshes, b))
        })
        .collect();
    let mut hits = Vec::new();
    for i in 0..placed.len() {
        for k in i + 1..placed.len() {
            let (a, ma, ba) = &placed[i];
            let (b, mb, bb) = &placed[k];
            if skip.contains(&pair(a, b)) {
                continue;
            }
            let Some(region) = ba.intersect(bb) else { continue };
            let s = region.size();
            let cell = if opts.cell_mm > 0.0 { opts.cell_mm } else { (s[1].max(s[2]) / 48.0).max(0.05) };
            let vol = geom::shared_volume(ma, mb, &region, cell);
            if vol > opts.min_volume_mm3 {
                hits.push(json!({"a": a, "b": b, "volume_mm3": vol, "region": {"min": region.min, "max": region.max}}));
            }
        }
    }
    hits
}

/// Interference at joint values `q`.
pub fn interference(asm: &Assembly, g: &Geometry, q: &Q, opts: &Options) -> Value {
    let shapes = Shapes::new(asm, g);
    let poses = fk(asm, q);
    let hits = interference_at(asm, &shapes, &poses, opts);
    let checked = shapes.home.values().filter(|m| !m.is_empty()).count();
    json!({"pairs": hits, "clear": hits.is_empty(), "components_checked": checked})
}

/// Runs a motion study: `steps + 1` samples from `from` to `to` (the joint's range by default),
/// the other joints at `base`. Each step: the joint value, every component's pose, the end
/// effectors' positions and the colliding pairs; then the first contact of each pair.
pub fn motion_study(asm: &Assembly, g: &Geometry, study: &MotionStudy, base: &Q, opts: &Options) -> Result<Value, String> {
    let j = asm.joint(&study.joint).ok_or_else(|| format!("no joint {}", study.joint))?;
    if j.kind.dof() != 1 {
        return Err(format!("joint {} is {} and has no single value to sweep", j.id, j.kind.name()));
    }
    let (lo, hi) = j.range().unwrap_or((-180.0, 180.0));
    let from = j.clamp(study.from.unwrap_or(lo));
    let to = j.clamp(study.to.unwrap_or(hi));
    let n = study.steps.clamp(1, 2000);
    let shapes = Shapes::new(asm, g);
    let tips = leaves(asm);
    let mut steps = Vec::new();
    let mut first: BTreeMap<(String, String), Value> = BTreeMap::new();
    for i in 0..=n {
        let s = f64::from(i) / f64::from(n);
        let v = from + (to - from) * s;
        let mut q = base.clone();
        q.insert(j.id.clone(), v);
        let poses = fk(asm, &q);
        let hits = interference_at(asm, &shapes, &poses, opts);
        let t = study.duration_s.map(|d| d * s);
        for h in &hits {
            let key = pair(h["a"].as_str().unwrap_or(""), h["b"].as_str().unwrap_or(""));
            first.entry(key).or_insert_with(|| json!({"a": h["a"], "b": h["b"], "step": i, "value": v, "time_s": t, "volume_mm3": h["volume_mm3"]}));
        }
        let ends: Vec<Value> = tips.iter().map(|c| json!({"component": c, "pos_mm": poses.get(c).copied().unwrap_or_default().pos})).collect();
        let (axis_at, axis_dir) = joint_frame(&poses, j);
        steps.push(json!({
            "step": i, "value": v, "time_s": t,
            "poses": poses_json(&poses),
            "end_effectors": ends,
            "joint_frame": {"origin_mm": axis_at, "axis": axis_dir},
            "collisions": hits,
        }));
    }
    let contacts: Vec<Value> = first.into_values().collect();
    Ok(json!({
        "study": study.id, "joint": j.id, "unit": if j.kind.angular() { "deg" } else { "mm" },
        "from": from, "to": to, "steps": steps, "first_contacts": contacts.clone(), "clear": contacts.is_empty(),
    }))
}
