//! Shared pieces of the product examples: small vector maths, poses, link studies, running a
//! part and writing its files.

#![allow(dead_code)]

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use viaform_generative::Material;
use viaform_generative::solid::{self, Load, LoadCase, Manufacturing, Mesh, Objective, Region, Study, Support, export, iso};

pub type V3 = [f64; 3];

pub fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
pub fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
pub fn scale(a: V3, k: f64) -> V3 {
    [a[0] * k, a[1] * k, a[2] * k]
}
pub fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
pub fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
pub fn norm(a: V3) -> f64 {
    dot(a, a).sqrt()
}
pub fn unit(a: V3) -> V3 {
    let n = norm(a);
    if n > 0.0 { scale(a, 1.0 / n) } else { a }
}

/// A rigid placement: rotation (columns are the local axes in the parent) and translation.
#[derive(Clone, Copy, Debug)]
pub struct Pose {
    pub r: [[f64; 3]; 3],
    pub t: V3,
}

impl Pose {
    pub const ID: Pose = Pose { r: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], t: [0.0; 3] };

    pub fn from_axes(x: V3, y: V3, z: V3, t: V3) -> Pose {
        Pose { r: [[x[0], y[0], z[0]], [x[1], y[1], z[1]], [x[2], y[2], z[2]]], t }
    }
    /// Rotation by `angle` (radians) about the unit `axis` through the origin.
    pub fn rot(axis: V3, angle: f64) -> Pose {
        let [x, y, z] = unit(axis);
        let (s, c) = angle.sin_cos();
        let k = 1.0 - c;
        Pose { r: [[c + x * x * k, x * y * k - z * s, x * z * k + y * s], [y * x * k + z * s, c + y * y * k, y * z * k - x * s], [z * x * k - y * s, z * y * k + x * s, c + z * z * k]], t: [0.0; 3] }
    }
    pub fn trans(t: V3) -> Pose {
        Pose { t, ..Pose::ID }
    }
    pub fn point(&self, p: V3) -> V3 {
        add(self.vector(p), self.t)
    }
    pub fn vector(&self, v: V3) -> V3 {
        [0, 1, 2].map(|i| self.r[i][0] * v[0] + self.r[i][1] * v[1] + self.r[i][2] * v[2])
    }
    pub fn then(&self, child: &Pose) -> Pose {
        let mut r = [[0.0; 3]; 3];
        for i in 0..3 {
            for j in 0..3 {
                r[i][j] = (0..3).map(|k| self.r[i][k] * child.r[k][j]).sum();
            }
        }
        Pose { r, t: self.point(child.t) }
    }
    /// Row-major 3 x 4.
    pub fn matrix(&self) -> [f64; 12] {
        let r = &self.r;
        [r[0][0], r[0][1], r[0][2], self.t[0], r[1][0], r[1][1], r[1][2], self.t[1], r[2][0], r[2][1], r[2][2], self.t[2]]
    }
}

pub fn mesh_transformed(mesh: &Mesh, pose: &Pose) -> Mesh {
    let mut m = mesh.clone();
    for p in m.positions.chunks_mut(3) {
        let q = pose.point([p[0] as f64, p[1] as f64, p[2] as f64]);
        p.copy_from_slice(&q.map(|v| v as f32));
    }
    m
}

pub fn mesh_append(into: &mut Mesh, m: &Mesh) {
    let base = (into.positions.len() / 3) as u32;
    into.positions.extend_from_slice(&m.positions);
    into.indices.extend(m.indices.iter().map(|i| i + base));
    if m.stress.len() * 3 == m.positions.len() {
        into.stress.extend_from_slice(&m.stress);
    } else {
        into.stress.extend(std::iter::repeat_n(0.0, m.positions.len() / 3));
    }
}

/// A closed cylinder mesh from `a` to `b` (a motor body, for the assembly view).
pub fn cylinder_mesh(a: V3, b: V3, r: f64, sides: usize) -> Mesh {
    let ax = unit(sub(b, a));
    let helper = if ax[0].abs() < 0.9 { [1.0, 0.0, 0.0] } else { [0.0, 1.0, 0.0] };
    let u = unit(cross(ax, helper));
    let v = cross(ax, u);
    let mut m = Mesh::default();
    let mut push = |p: V3| {
        m.positions.extend(p.map(|x| x as f32));
        (m.positions.len() / 3 - 1) as u32
    };
    let ca = push(a);
    let cb = push(b);
    let ring: Vec<(u32, u32)> = (0..sides)
        .map(|k| {
            let t = k as f64 / sides as f64 * std::f64::consts::TAU;
            let d = add(scale(u, r * t.cos()), scale(v, r * t.sin()));
            (push(add(a, d)), push(add(b, d)))
        })
        .collect();
    for k in 0..sides {
        let (a0, b0) = ring[k];
        let (a1, b1) = ring[(k + 1) % sides];
        m.indices.extend([ca, a1, a0, cb, b0, b1, a0, a1, b1, a0, b1, b0]);
    }
    m
}

/// Which way a link's joint turns, in the link's own frame (x runs along the link).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Ax {
    Y,
    Z,
}

impl Ax {
    pub fn v(self) -> V3 {
        match self {
            Ax::Y => [0.0, 1.0, 0.0],
            Ax::Z => [0.0, 0.0, 1.0],
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Drive {
    /// Turns the link against the one before it.
    Prox,
    /// Turns the next link.
    Dist,
}

/// A geared micro motor housed in a link, along the link's x.
#[derive(Clone, Debug)]
pub struct Motor {
    pub name: String,
    pub dof: String,
    pub x0: f64,
    pub len: f64,
    pub r: f64,
    pub y: f64,
    pub z: f64,
    pub drives: Drive,
    pub mass_g: f64,
    /// Rated output at the joint (gearhead and worm), N·mm.
    pub rated_nmm: f64,
}

/// A finger-like link: a tongue on its proximal joint, a clevis (two lugs) on its distal one,
/// motors inside, a pad at the tip when it ends the chain.
#[derive(Clone, Debug)]
pub struct Link {
    pub name: String,
    pub len: f64,
    pub w: f64,
    pub h: f64,
    pub prox: Ax,
    pub dist: Option<Ax>,
    /// Half width of this link's tongue, along its proximal axis.
    pub tongue: f64,
    /// Half width of the gap between its distal lugs (the next link's tongue plus clearance).
    pub gap: f64,
    pub rb: f64,
    pub ro: f64,
    pub motors: Vec<Motor>,
    /// From the distal joint to the fingertip along x (0 for the tip link: its pad is at `len`).
    pub reach: f64,
    pub tip: bool,
    pub voxel: f64,
}

pub fn alsi10mg() -> Material {
    Material { name: "AlSi10Mg (laser powder bed)".into(), e: 70_000.0, nu: 0.33, density: 2.67e-3, allowable: 230.0, color: "#c4c8cc".into() }
}

pub fn tube(c: V3, a: V3, from: f64, to: f64, inner: f64, outer: f64) -> Region {
    Region::Tube { base: add(c, scale(a, from)), axis: a, inner, outer, length: to - from }
}

pub fn cyl(c: V3, a: V3, from: f64, to: f64, r: f64) -> Region {
    Region::Cylinder { base: add(c, scale(a, from)), axis: a, radius: r, length: to - from }
}

/// The moment of `f` at `p` about `c`, split into its share along `a` and the rest.
fn split(p: V3, f: V3, c: V3, a: V3) -> (f64, V3) {
    let m = cross(sub(p, c), f);
    let ma = dot(m, a);
    (ma, sub(m, scale(a, ma)))
}

fn torque(region: Region, center: V3, m: V3) -> Option<Load> {
    let n = norm(m);
    (n > 1e-9).then(|| Load::Torque { region, center, axis: unit(m), moment: n })
}

/// Load cases at the tip, link frame: grip, lateral and a 100 g drop.
pub fn tip_cases(grip: f64, lateral: f64) -> Vec<(String, V3)> {
    vec![("grip".into(), [0.0, 0.0, -grip]), ("lateral".into(), [0.0, lateral, 0.0])]
}

pub const DROP_G: f64 = 100.0;

impl Link {
    pub fn tip_point(&self) -> V3 {
        if self.tip { [self.len, 0.0, -0.2 * self.h] } else { [self.len + self.reach, 0.0, 0.0] }
    }

    fn rings(&self, m: &Motor) -> [Region; 2] {
        let a = [1.0, 0.0, 0.0];
        let c = [0.0, m.y, m.z];
        [tube(c, a, m.x0, m.x0 + 2.5, m.r + 0.1, m.r + 1.3), tube(c, a, m.x0 + m.len - 2.5, m.x0 + m.len, m.r + 0.1, m.r + 1.3)]
    }

    pub fn study(&self, grip: f64, lateral: f64) -> Study {
        let (w2, h2) = (self.w / 2.0, self.h / 2.0);
        let o = [0.0; 3];
        let cd = [self.len, 0.0, 0.0];
        let ap = self.prox.v();
        let span = |a: Ax| if a == Ax::Y { w2 } else { h2 };
        let xmax = if self.tip { self.len + 0.5 } else { self.len + self.ro + 0.6 };
        let mut keep_in = vec![tube(o, ap, -self.tongue, self.tongue, self.rb, self.ro)];
        let mut keep_out = vec![cyl(o, ap, -span(self.prox) - 1.0, span(self.prox) + 1.0, self.rb)];
        // Room for the previous link's lugs to turn beside the tongue.
        keep_out.push(cyl(o, ap, self.tongue + 0.4, span(self.prox) + 1.0, self.ro + 0.8));
        keep_out.push(cyl(o, ap, -span(self.prox) - 1.0, -self.tongue - 0.4, self.ro + 0.8));
        let mut lugs = Vec::new();
        if let Some(ad) = self.dist {
            let a = ad.v();
            let s = span(ad);
            lugs = vec![tube(cd, a, self.gap, s, self.rb, self.ro), tube(cd, a, -s, -self.gap, self.rb, self.ro)];
            keep_in.extend(lugs.iter().copied());
            keep_out.push(cyl(cd, a, -s - 1.0, s + 1.0, self.rb));
            // The next link's tongue and its swing.
            keep_out.push(cyl(cd, a, -self.gap, self.gap, self.ro + 0.9));
            let (lo, hi) = (cd[0] - self.ro - 0.9, xmax + 1.0);
            keep_out.push(match ad {
                Ax::Y => Region::Box { min: [lo, -self.gap, -h2 - 1.0], max: [hi, self.gap, h2 + 1.0] },
                Ax::Z => Region::Box { min: [lo, -w2 - 1.0, -self.gap], max: [hi, w2 + 1.0, self.gap] },
            });
        }
        let pad = if self.tip {
            let r = 0.42 * self.h.min(self.w);
            let p = Region::Sphere { center: [self.len - r, 0.0, -0.1 * self.h], radius: r };
            keep_in.push(p);
            Some(p)
        } else {
            None
        };
        for m in &self.motors {
            keep_in.extend(self.rings(m));
            keep_out.push(cyl([0.0, m.y, m.z], [1.0, 0.0, 0.0], m.x0, m.x0 + m.len, m.r + 0.15));
            // The worm on the shaft, out to the joint it turns.
            let (from, to) = match m.drives {
                Drive::Dist => (m.x0 + m.len, self.len - 1.0),
                Drive::Prox => (1.0, m.x0),
            };
            if to > from {
                keep_out.push(cyl([0.0, m.y, m.z], [1.0, 0.0, 0.0], from, to, 1.8));
            }
        }
        let tip = self.tip_point();
        let mut cases = Vec::new();
        for (name, f) in tip_cases(grip, lateral) {
            let mut loads = Vec::new();
            if let Some(p) = pad {
                loads.push(Load::Force { region: p, force: f });
            }
            if let Some(ad) = self.dist {
                let a = ad.v();
                for l in &lugs {
                    loads.push(Load::Force { region: *l, force: scale(f, 0.5) });
                }
                let (ma, mp) = split(tip, f, cd, a);
                for l in &lugs {
                    loads.extend(torque(*l, cd, scale(mp, 0.5)));
                }
                // The joint's own moment: through the motor that turns it when it sits here,
                // else through the wheel on these lugs.
                match self.motors.iter().find(|m| m.drives == Drive::Dist) {
                    Some(m) => {
                        for r in self.rings(m) {
                            loads.extend(torque(r, cd, scale(a, -0.5 * ma)));
                        }
                    }
                    None => {
                        for l in &lugs {
                            loads.extend(torque(*l, cd, scale(a, 0.5 * ma)));
                        }
                    }
                }
            }
            // A motor turning the proximal joint pushes on its wheel: its housing takes the
            // joint's moment back.
            if let Some(m) = self.motors.iter().find(|m| m.drives == Drive::Prox) {
                let (ma, _) = split(tip, f, o, ap);
                for r in self.rings(m) {
                    loads.extend(torque(r, o, scale(ap, -0.5 * ma)));
                }
            }
            cases.push(LoadCase { name, loads, acceleration: None, weight: 1.0 });
        }
        let acc = DROP_G * 9810.0;
        let mut drop = Vec::new();
        for m in &self.motors {
            for r in self.rings(m) {
                drop.push(Load::Force { region: r, force: [0.0, 0.0, -0.5 * m.mass_g * 1e-3 * acc / 1000.0] });
            }
        }
        cases.push(LoadCase { name: "drop 100 g".into(), loads: drop, acceleration: Some([0.0, 0.0, -acc]), weight: 0.5 });
        Study {
            name: self.name.clone(),
            min: [-self.ro - 0.6, -w2, -h2],
            max: [xmax, w2, h2],
            voxel: self.voxel,
            material: alsi10mg(),
            supports: vec![Support { region: tube(o, ap, -self.tongue, self.tongue, self.rb - 0.05, self.rb + 1.1), fix: [true; 3] }],
            cases,
            keep_in,
            keep_out,
            objective: Objective::Mass,
            volume_fraction: 0.5,
            safety_factor: 2.0,
            min_member: 1.2,
            manufacturing: Manufacturing::Additive { build: [0.0, 0.0, 1.0], overhang: 45.0 },
            iterations: 45,
            smoothing: 10,
            dynamics: solid::Dynamics { modes: 3, impacts: Vec::new() },
            ..Study::default()
        }
    }
}

/// What one part's run gave, for the summary.
#[derive(Clone, Debug)]
pub struct PartResult {
    pub name: String,
    pub mass_g: f64,
    pub max_stress: f64,
    pub limit: f64,
    pub safety_factor: f64,
    pub feasible: bool,
    pub first_mode_hz: f64,
    pub seconds: f64,
    pub voxels: usize,
    pub mesh: Mesh,
    pub grid: solid::Grid,
    pub density: Vec<f32>,
    pub analysis: solid::Analysis,
    /// Why it fails or what to check (the engine's words), and the surface's volume.
    pub issues: Vec<String>,
    pub mesh_mm3: f64,
}

/// Runs a study, writes its study JSON, STL, 3MF and OBJ into `dir`, and answers its figures.
pub fn run_part(dir: &Path, study: &Study) -> PartResult {
    std::fs::create_dir_all(dir.join("studies")).unwrap();
    std::fs::create_dir_all(dir.join("parts")).unwrap();
    std::fs::write(dir.join("studies").join(format!("{}.json", study.name)), serde_json::to_string_pretty(study).unwrap()).unwrap();
    let t = std::time::Instant::now();
    let out = solid::generate(study).unwrap_or_else(|e| panic!("{}: {e}", study.name));
    let c = &out.candidates[out.best];
    let stem = dir.join("parts").join(&study.name);
    std::fs::write(stem.with_extension("stl"), export::stl(&c.mesh, &study.name)).unwrap();
    std::fs::write(stem.with_extension("3mf"), export::three_mf(&c.mesh, &study.name)).unwrap();
    std::fs::write(stem.with_extension("obj"), export::obj(&c.mesh)).unwrap();
    let a = &c.analysis;
    let limit = study.max_stress.unwrap_or(study.material.allowable / study.safety_factor);
    let r = PartResult {
        name: study.name.clone(),
        mass_g: c.mass_g,
        max_stress: a.max_stress.iter().copied().fold(0.0, f64::max),
        limit,
        safety_factor: a.safety_factor,
        feasible: c.feasible,
        first_mode_hz: a.modes.first().map_or(0.0, |m| m.frequency),
        seconds: t.elapsed().as_secs_f64(),
        voxels: c.grid.elements(),
        mesh: c.mesh.clone(),
        grid: c.grid,
        density: c.density.clone(),
        analysis: c.analysis.clone(),
        issues: c.issues.clone(),
        mesh_mm3: c.mesh_mm3,
    };
    for w in &out.warnings {
        eprintln!("  {}: {w}", r.name);
    }
    for i in &r.issues {
        eprintln!("  {}: {i}", r.name);
    }
    eprintln!(
        "{:<22} {:>7.2} g  stress {:>6.1} / {:>5.1} MPa  SF {:>5.2}  f1 {:>7.0} Hz  closed {}  {} voxels  {:.0} s{}",
        r.name,
        r.mass_g,
        r.max_stress,
        r.limit,
        r.safety_factor,
        r.first_mode_hz,
        iso::is_closed(&c.mesh),
        r.voxels,
        r.seconds,
        if r.feasible { "" } else { "  NOT FEASIBLE" }
    );
    r
}

pub fn result_json(r: &PartResult, extra: Value) -> Value {
    let mut v = json!({
        "name": r.name,
        "mass_g": r.mass_g,
        "max_stress_mpa": r.max_stress,
        "stress_limit_mpa": r.limit,
        "safety_factor": r.safety_factor,
        "feasible": r.feasible,
        "first_mode_hz": r.first_mode_hz,
        "voxels": r.voxels,
        "seconds": r.seconds,
        "triangles": r.mesh.indices.len() / 3,
        "max_displacement_mm": r.analysis.max_displacement.iter().copied().fold(0.0, f64::max),
        "compliance_nmm": r.analysis.compliance,
        "bodies": r.analysis.bodies,
        "solid_mm3": r.analysis.solid_mm3,
        "mesh_mm3": r.mesh_mm3,
        "floating_mm3": r.analysis.floating_mm3,
        "unsupported_loads": r.analysis.unsupported,
        "issues": r.issues,
        "files": {"stl": format!("parts/{}.stl", r.name), "3mf": format!("parts/{}.3mf", r.name), "obj": format!("parts/{}.obj", r.name), "study": format!("studies/{}.json", r.name)},
    });
    if let (Some(o), Some(e)) = (v.as_object_mut(), extra.as_object()) {
        for (k, x) in e {
            o.insert(k.clone(), x.clone());
        }
    }
    v
}

/// Where the product files go: `docs/generative/<name>` at the repository root.
pub fn out_dir(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("docs").join("generative").join(name)
}

/// Only these parts (names containing one of the `--only` words), when asked.
pub fn wanted(name: &str) -> bool {
    let args: Vec<String> = std::env::args().collect();
    match args.iter().position(|a| a == "--only") {
        Some(i) => args.get(i + 1).is_none_or(|w| w.split(',').any(|w| name.contains(w))),
        None => true,
    }
}

/// A closed box mesh (a bought part's envelope, for the assembly view).
pub fn box_mesh(min: V3, max: V3) -> Mesh {
    let p = [
        [min[0], min[1], min[2]],
        [max[0], min[1], min[2]],
        [max[0], max[1], min[2]],
        [min[0], max[1], min[2]],
        [min[0], min[1], max[2]],
        [max[0], min[1], max[2]],
        [max[0], max[1], max[2]],
        [min[0], max[1], max[2]],
    ];
    let t: [[u32; 3]; 12] = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]];
    Mesh { positions: p.iter().flatten().map(|v| *v as f32).collect(), indices: t.iter().flatten().copied().collect(), stress: Vec::new() }
}

/// A tube mesh (a bearing: bore to outside diameter), closed, along z from 0 to `len`.
pub fn ring_mesh(inner: f64, outer: f64, len: f64, sides: usize) -> Mesh {
    let mut m = Mesh::default();
    let mut push = |p: V3| {
        m.positions.extend(p.map(|x| x as f32));
        (m.positions.len() / 3 - 1) as u32
    };
    let ring: Vec<[u32; 4]> = (0..sides)
        .map(|k| {
            let t = k as f64 / sides as f64 * std::f64::consts::TAU;
            let (c, s) = (t.cos(), t.sin());
            [push([inner * c, inner * s, 0.0]), push([outer * c, outer * s, 0.0]), push([inner * c, inner * s, len]), push([outer * c, outer * s, len])]
        })
        .collect();
    for k in 0..sides {
        let [i0, o0, i0t, o0t] = ring[k];
        let [i1, o1, i1t, o1t] = ring[(k + 1) % sides];
        // Outside, inside, bottom and top faces.
        m.indices.extend([o0, o1, o1t, o0, o1t, o0t, i0, i1t, i1, i0, i0t, i1t, i0, o1, o0, i0, i1, o1, i0t, o0t, o1t, i0t, o1t, i1t]);
    }
    m
}

/// One line of a component file (`docs/components/<assembly>.json`), as the assembly needs it.
#[derive(Clone, Debug)]
pub struct Bought {
    pub reference: String,
    pub qty: u64,
    pub mpn: String,
    pub manufacturer: String,
    pub category: String,
    pub description: String,
    pub dims: Vec<f64>,
    pub mass_g: f64,
}

/// Reads the component file the components agent sourced; the design never invents a part.
pub fn components(assembly: &str) -> Vec<Bought> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("docs").join("components").join(format!("{assembly}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let v: Value = serde_json::from_str(&text).unwrap();
    v["components"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| Bought {
            reference: c["ref"].as_str().unwrap_or_default().into(),
            qty: c["qty"].as_u64().unwrap_or(1),
            mpn: c["mpn"].as_str().unwrap_or_default().into(),
            manufacturer: c["manufacturer"].as_str().unwrap_or_default().into(),
            category: c["category"].as_str().unwrap_or_default().into(),
            description: c["description"].as_str().unwrap_or_default().into(),
            dims: c["dims_mm"].as_array().map(|a| a.iter().filter_map(Value::as_f64).collect()).unwrap_or_default(),
            mass_g: c["mass_g"].as_f64().unwrap_or(0.0),
        })
        .collect()
}

pub fn bought<'a>(list: &'a [Bought], reference: &str) -> &'a Bought {
    list.iter().find(|b| b.reference == reference).unwrap_or_else(|| panic!("component {reference} is not in the component file"))
}

/// The assembly file `generative::assemble` inserts (parts, poses, joints) and the bill of
/// materials reads (every instance: generated with its material and mass, or bought with its
/// `component_ref`).
#[derive(Default)]
pub struct AssemblyFile {
    pub parts: Vec<Value>,
    pub joints: Vec<Value>,
    /// Bought lines with no placed geometry (cable, wire, tendon line, loose hardware).
    pub bulk: Vec<Value>,
    written: std::collections::HashSet<String>,
    shapes: std::collections::HashMap<String, u64>,
}

impl AssemblyFile {
    /// A generated part (its 3MF is already in `parts/`).
    pub fn made(&mut self, name: &str, file: &str, pose: &Pose, material: &str, process: &str, mass_g: f64, parent: Option<(&str, Value)>) {
        self.parts.push(json!({
            "name": name, "file": file, "pose": pose.matrix(), "kind": "generative", "qty": 1,
            "material": material, "mass_g": mass_g,
            "properties": {"material": material, "process": process, "mass_g": format!("{mass_g:.2}"), "category": "made"},
        }));
        if let Some((p, j)) = parent {
            self.attach(p, name, j);
        }
    }

    /// A made part that is not grown (a turned spool): same row as a generated one.
    pub fn simple(&mut self, dir: &Path, name: &str, shape: &str, mesh: &Mesh, pose: &Pose, material: &str, process: &str, mass_g: f64, parent: &str) {
        let file = self.shape(dir, shape, mesh);
        self.parts.push(json!({
            "name": name, "file": file, "pose": pose.matrix(), "kind": "made", "qty": 1,
            "material": material, "mass_g": mass_g,
            "properties": {"material": material, "process": process, "mass_g": format!("{mass_g:.2}"), "category": "made"},
        }));
        self.rigid(parent, name, pose.t);
    }

    /// The file of a shape: one per distinct mesh, so two instances of one part number drawn
    /// differently (a servo standing and one lying down) never share a file.
    fn shape(&mut self, dir: &Path, shape: &str, mesh: &Mesh) -> String {
        let key = |m: &Mesh| m.positions.iter().fold(m.indices.len() as u64, |h, v| h.rotate_left(5) ^ u64::from(v.to_bits()));
        let k = key(mesh);
        let mut name = shape.to_string();
        let mut n = 1;
        loop {
            match self.shapes.get(&name) {
                Some(&other) if other == k => return format!("components/{name}.stl"),
                Some(_) => {
                    n += 1;
                    name = format!("{shape}_{n}");
                }
                None => break,
            }
        }
        let file = format!("components/{name}.stl");
        self.shapes.insert(name.clone(), k);
        self.written.insert(name.clone());
        std::fs::create_dir_all(dir.join("components")).unwrap();
        std::fs::write(dir.join(&file), export::stl(mesh, &name)).unwrap();
        file
    }

    /// One bought part instance, its envelope `mesh` (local frame) placed at `pose`, held
    /// rigidly by `parent`.
    pub fn bought(&mut self, dir: &Path, b: &Bought, name: &str, shape: &str, mesh: &Mesh, pose: &Pose, parent: Option<&str>, role: &str) {
        let file = self.shape(dir, shape, mesh);
        self.parts.push(json!({
            "name": name, "file": file, "pose": pose.matrix(), "kind": "component", "qty": 1,
            "component_ref": b.reference, "ref": b.reference, "position_mm": pose.t, "part_number": b.mpn, "bom_type": "purchased", "description": b.description,
            "material": Value::Null, "mass_g": b.mass_g, "role": role,
            "properties": {"mpn": b.mpn, "manufacturer": b.manufacturer, "category": b.category, "mass_g": format!("{}", b.mass_g)},
        }));
        if let Some(p) = parent {
            self.rigid(p, name, pose.t);
        }
    }

    pub fn rigid(&mut self, parent: &str, child: &str, at: V3) {
        self.joints.push(json!({"name": format!("{child} mount"), "type": "rigid", "parent": parent, "child": child, "origin": at, "axis": [0.0, 0.0, 1.0]}));
    }

    pub fn attach(&mut self, parent: &str, child: &str, joint: Value) {
        let mut j = joint;
        j["parent"] = json!(parent);
        j["child"] = json!(child);
        self.joints.push(j);
    }

    /// A bought line used without placed geometry.
    pub fn loose(&mut self, b: &Bought, qty: u64, use_: &str) {
        self.bulk.push(json!({"component_ref": b.reference, "part_number": b.mpn, "qty": qty, "mass_g_each": b.mass_g, "use": use_}));
    }

    /// Every instance counted by line, against the component file's quantities.
    pub fn write(&self, dir: &Path, assembly: &str, list: &[Bought], extra: Value) {
        let mut placed: std::collections::BTreeMap<String, u64> = Default::default();
        for p in &self.parts {
            if let Some(r) = p["component_ref"].as_str() {
                *placed.entry(r.to_string()).or_default() += 1;
            }
        }
        for b in &self.bulk {
            *placed.entry(b["component_ref"].as_str().unwrap_or_default().to_string()).or_default() += b["qty"].as_u64().unwrap_or(0);
        }
        let check: Vec<Value> = list
            .iter()
            .map(|b| {
                let n = placed.get(&b.reference).copied().unwrap_or(0);
                json!({"component_ref": b.reference, "file_qty": b.qty, "placed_or_listed": n, "matches": n == b.qty})
            })
            .collect();
        let wrong: Vec<String> = check.iter().filter(|c| c["matches"] != true).map(|c| format!("{} placed or listed {} against {}", c["component_ref"].as_str().unwrap_or_default(), c["placed_or_listed"], c["file_qty"])).collect();
        assert!(wrong.is_empty(), "{assembly}: every line of the component file must be placed or listed at its quantity: {}", wrong.join("; "));
        let made: f64 = self.parts.iter().filter(|p| p["kind"] != "component").filter_map(|p| p["mass_g"].as_f64()).sum();
        let bought: f64 = self.parts.iter().filter(|p| p["kind"] == "component").filter_map(|p| p["mass_g"].as_f64()).sum::<f64>()
            + self.bulk.iter().map(|b| b["mass_g_each"].as_f64().unwrap_or(0.0) * b["qty"].as_f64().unwrap_or(0.0)).sum::<f64>();
        let mut doc = json!({
            "schema": "viaform.assembly/1",
            "assembly": assembly,
            "component_file": format!("docs/components/{assembly}.json"),
            "units": {"length": "mm", "mass": "g", "pose": "row-major 3x4, part frame in the assembly frame"},
            "parts": self.parts,
            "joints": self.joints,
            "bulk": self.bulk,
            "quantities": check,
            "mass_g": {"made": made, "bought": bought, "total": made + bought},
        });
        if let (Some(o), Some(e)) = (doc.as_object_mut(), extra.as_object()) {
            for (k, v) in e {
                o.insert(k.clone(), v.clone());
            }
        }
        std::fs::write(dir.join("assembly.json"), serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    }
}

/// The middle of a mesh's bounds.
pub fn centre(mesh: &Mesh) -> V3 {
    let (mut lo, mut hi) = ([f64::INFINITY; 3], [f64::NEG_INFINITY; 3]);
    for p in mesh.positions.chunks(3) {
        for i in 0..3 {
            lo[i] = lo[i].min(p[i] as f64);
            hi[i] = hi[i].max(p[i] as f64);
        }
    }
    scale(add(lo, hi), 0.5)
}

/// Mass (g), centre (mm) and inertia about it (g mm^2, xx yy zz) of several bodies.
pub fn combine(items: &[(f64, V3, V3)]) -> (f64, V3, V3) {
    let m: f64 = items.iter().map(|x| x.0).sum();
    let c = scale(items.iter().fold([0.0; 3], |a, x| add(a, scale(x.1, x.0))), 1.0 / m.max(1e-12));
    let mut i = [0.0; 3];
    for (mi, ci, ii) in items {
        let d = sub(*ci, c);
        i[0] += ii[0] + mi * (d[1] * d[1] + d[2] * d[2]);
        i[1] += ii[1] + mi * (d[0] * d[0] + d[2] * d[2]);
        i[2] += ii[2] + mi * (d[0] * d[0] + d[1] * d[1]);
    }
    (m, c, i)
}

/// Mass (g), centre (mm) and inertia about the centre (g mm^2) of a part's voxel layout.
pub fn voxel_inertia(r: &PartResult, density: f64) -> (f64, V3, V3) {
    let g = r.grid;
    let cell = g.h.powi(3) * density;
    let solid: Vec<V3> = (0..g.elements()).filter(|&e| r.density[e] >= 0.5).map(|e| g.element_center(e)).collect();
    let m = cell * solid.len() as f64;
    let c = scale(solid.iter().fold([0.0; 3], |a, p| add(a, *p)), 1.0 / solid.len().max(1) as f64);
    let mut i = [0.0; 3];
    for p in &solid {
        let d = sub(*p, c);
        i[0] += cell * (d[1] * d[1] + d[2] * d[2] + g.h * g.h / 6.0);
        i[1] += cell * (d[0] * d[0] + d[2] * d[2] + g.h * g.h / 6.0);
        i[2] += cell * (d[0] * d[0] + d[1] * d[1] + g.h * g.h / 6.0);
    }
    (m, c, i)
}
