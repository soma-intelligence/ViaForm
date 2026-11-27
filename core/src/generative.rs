//! Generative design in the workspace: runs a study ([`viaform_generative`]) and builds a
//! candidate into the design through the same SolidCraft commands every front end runs.
//!
//! Two kinds of study share the entry points, told apart by their JSON: a 3D study
//! ([`viaform_generative::solid::Study`]: `min`, `max` and `voxel`), solved on hexahedral voxels
//! and built as one closed mesh body (`file.insert_mesh` of the candidate's 3MF), and the older
//! plate study ([`Spec`]: `width`, `height`, `thickness`), built as a sketch and an extrusion.
//!
//! The study is deterministic (same spec, same candidates), so [`build`] reruns it rather than
//! taking an outcome back from the front end.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use solidcraft_engine::{Session, Snapshot};
use viaform_generative::{Candidate, Outcome, Spec, emit, solid};

/// The engine's undo depth (`MAX_UNDO` in solidcraft-engine).
const MAX_UNDO: usize = 200;

fn spec(v: &Value) -> Result<Spec, String> {
    serde_json::from_value(v.clone()).map_err(|e| format!("spec: {e}"))
}

fn run(v: &Value) -> Result<(Spec, Outcome), String> {
    let spec = spec(v)?;
    let outcome = viaform_generative::generate(&spec)?;
    Ok((spec, outcome))
}

/// A candidate's figures without its shape (the grid or the beams), for replies.
fn figures(c: &Candidate) -> Value {
    let mut v = serde_json::to_value(c).unwrap_or(Value::Null);
    if let Some(o) = v.as_object_mut() {
        o.remove("shape");
    }
    v
}

/// Whether `spec` is a 3D study (a design space with `min`, `max` and `voxel`).
pub fn is_solid(spec: &Value) -> bool {
    spec.get("voxel").is_some() || spec.get("min").and_then(Value::as_array).is_some_and(|a| a.len() == 3)
}

fn solid_run(v: &Value) -> Result<(solid::Study, solid::Outcome), String> {
    let study: solid::Study = serde_json::from_value(v.clone()).map_err(|e| format!("study: {e}"))?;
    let outcome = solid::generate(&study)?;
    Ok((study, outcome))
}

/// A file-system-safe body name.
fn file_stem(name: &str) -> String {
    let s: String = name.chars().map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
    if s.is_empty() { "Generated".into() } else { s }
}

/// Builds a 3D candidate into `cad` as one mesh body (one command, so one undo step).
fn solid_build(cad: &mut Session, spec: &Value, candidate: Option<usize>) -> Result<Value, String> {
    let (study, outcome) = solid_run(spec)?;
    insert_candidate(cad, &study, &outcome, candidate)
}

/// Inserts candidate `candidate` (the best when `None`) of a finished 3D run into `cad` as one
/// mesh body: one command, so one undo step.
pub fn insert_candidate(cad: &mut Session, study: &solid::Study, outcome: &solid::Outcome, candidate: Option<usize>) -> Result<Value, String> {
    let pick = candidate.unwrap_or(outcome.best);
    let c = outcome.candidates.get(pick).ok_or_else(|| format!("no candidate {pick} (the study has {})", outcome.candidates.len()))?;
    if c.mesh.indices.is_empty() {
        return Err(format!("candidate {pick} has no surface: no voxel kept material"));
    }
    let name = if study.name.trim().is_empty() { "Generated".to_string() } else { study.name.clone() };
    let dir = std::env::temp_dir().join(format!("viaform-generate-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos())));
    std::fs::create_dir_all(&dir).map_err(|e| format!("temporary folder: {e}"))?;
    let path = dir.join(format!("{}.3mf", file_stem(&name)));
    std::fs::write(&path, solid::export::three_mf(&c.mesh, &name)).map_err(|e| format!("writing the mesh: {e}"))?;
    let r = cad.execute("file.insert_mesh", &json!({"path": path.to_string_lossy(), "name": name}));
    let _ = std::fs::remove_dir_all(&dir);
    let r = r.map_err(|e| format!("file.insert_mesh: {e}"))?;
    Ok(json!({"candidate": solid_figures(c), "body": name, "commands": 1, "inserted": r}))
}

/// A 3D candidate's figures without its densities and surface.
pub fn solid_figures(c: &solid::Candidate) -> Value {
    let mut v = serde_json::to_value(c).unwrap_or(Value::Null);
    if let Some(o) = v.as_object_mut() {
        o.remove("density");
        o.remove("mesh");
        o.insert("triangles".into(), json!(c.mesh.indices.len() / 3));
    }
    v
}

/// Runs the study `spec` (a 3D [`solid::Study`] or a plate [`Spec`], as JSON) and answers its
/// outcome as JSON (3D candidates carry their surface and densities).
pub fn study(spec: &Value) -> Result<Value, String> {
    if is_solid(spec) {
        let (_, outcome) = solid_run(spec)?;
        return serde_json::to_value(&outcome).map_err(|e| e.to_string());
    }
    let (_, outcome) = run(spec)?;
    serde_json::to_value(&outcome).map_err(|e| e.to_string())
}

/// Runs the study `spec`, then builds candidate `candidate` (the study's best when `None`) into
/// `cad`. The whole build is one undo step; when a command fails the design goes back to how it
/// was and the error names the command. Answers `{candidate, body, commands}`.
pub fn build(cad: &mut Session, spec: &Value, candidate: Option<usize>) -> Result<Value, String> {
    if is_solid(spec) {
        return solid_build(cad, spec, candidate);
    }
    let (spec, outcome) = run(spec)?;
    let pick = candidate.unwrap_or(outcome.best);
    let c = outcome.candidates.get(pick).ok_or_else(|| format!("no candidate {pick} (the study has {})", outcome.candidates.len()))?;
    let commands = emit::commands(&spec, c);
    if commands.is_empty() {
        return Err(format!("candidate {pick} gave no commands to build"));
    }

    let before = Snapshot {
        label: format!("Generate {}", spec.body_name),
        doc: cad.doc.clone(),
        active_sketch: cad.active_sketch,
        pending_moves: cad.pending_moves.clone(),
        visibility: cad.visibility.clone(),
    };
    let undo = cad.undo.clone();
    let checkpoint = cad.checkpoint();
    for (id, params) in &commands {
        if let Err(e) = cad.execute(id, params) {
            let restored = cad.restore_checkpoint(checkpoint).err().map(|r| format!(" (and the design could not be restored: {r})")).unwrap_or_default();
            return Err(format!("{id}: {e}{restored}"));
        }
    }
    cad.drop_checkpoint(checkpoint);
    // One undo step for the whole build, in place of one per command.
    cad.undo = undo;
    cad.undo.push(before);
    if cad.undo.len() > MAX_UNDO {
        cad.undo.remove(0);
    }
    Ok(json!({"candidate": figures(c), "body": spec.body_name, "commands": commands.len()}))
}

/// Builds a generated assembly into `cad` as one undo step: each part's mesh file inserted as
/// its own component, placed, the base grounded, and a joint between every part and its parent
/// (`joint.as_built`, so the parts stay where they were generated and turn about the joints).
///
/// `spec`: `{"parts": [{"name", "file" (a .3mf, .stl or .obj path), "pose": [12 numbers, row-major
/// 3 x 4, part frame to world]}], "joints": [{"name", "type" (revolute), "parent", "child",
/// "origin": [x, y, z], "axis": [x, y, z], "limits_deg": [min, max]}]}`. A part without a parent
/// joint is grounded. Relative `file`s are read from `base_dir` when given. Answers `{"parts", "joints", "occurrences": {name: id}}`.
pub fn assemble(cad: &mut Session, spec: &Value) -> Result<Value, String> {
    let parts = spec["parts"].as_array().ok_or("assembly: no parts")?;
    let joints = spec["joints"].as_array().cloned().unwrap_or_default();
    let before = Snapshot {
        label: "Insert generated assembly".into(),
        doc: cad.doc.clone(),
        active_sketch: cad.active_sketch,
        pending_moves: cad.pending_moves.clone(),
        visibility: cad.visibility.clone(),
    };
    let undo = cad.undo.clone();
    let checkpoint = cad.checkpoint();
    let result = (|| -> Result<Value, String> {
        let mut occ = serde_json::Map::new();
        for p in parts {
            let name = p["name"].as_str().ok_or("assembly: a part has no name")?;
            let file = p["file"].as_str().ok_or_else(|| format!("{name}: no file"))?;
            // Relative files are read from `base_dir` (the assembly file's folder).
            let file = match spec["base_dir"].as_str() {
                Some(base) if std::path::Path::new(file).is_relative() => std::path::Path::new(base).join(file).to_string_lossy().into_owned(),
                _ => file.to_string(),
            };
            let r = cad.execute("file.insert_mesh", &json!({"path": file, "name": name})).map_err(|e| format!("{name}: file.insert_mesh: {e}"))?;
            let id = r["occurrence"].as_u64().ok_or_else(|| format!("{name}: the insert gave no occurrence ({r})"))?;
            // Part properties for the bill of materials: a bought part carries `component_ref`
            // (its line in the component file), a made one its material, process and mass.
            if let Some(component) = r.get("component").filter(|c| !c.is_null()) {
                let mut props = serde_json::Map::new();
                if let Some(o) = p["properties"].as_object() {
                    for (k, v) in o {
                        let text = match v {
                            Value::String(t) => t.clone(),
                            Value::Null => continue,
                            other => other.to_string(),
                        };
                        props.insert(k.clone(), json!(text));
                    }
                }
                if let Some(c) = p["component_ref"].as_str() {
                    props.insert("component_ref".into(), json!(c));
                }
                let mut meta = json!({"component": component});
                if !props.is_empty() {
                    meta["properties"] = Value::Object(props);
                }
                for key in ["part_number", "description", "bom_type"] {
                    if let Some(v) = p[key].as_str() {
                        meta[key] = json!(v);
                    }
                }
                if meta.as_object().is_some_and(|m| m.len() > 1) {
                    cad.execute("component.metadata.set", &meta).map_err(|e| format!("{name}: component.metadata.set: {e}"))?;
                }
            }
            if let Some(m) = p.get("pose").filter(|m| m.is_array()) {
                cad.execute("occurrence.move", &json!({"occurrence": id, "matrix": m, "space": "world", "move_grounded": true})).map_err(|e| format!("{name}: occurrence.move: {e}"))?;
            }
            occ.insert(name.to_string(), json!(id));
        }
        let child_of: Vec<&str> = joints.iter().filter_map(|j| j["child"].as_str()).collect();
        for p in parts {
            let name = p["name"].as_str().unwrap_or_default();
            let jointed = joints.iter().any(|j| j["child"].as_str() == Some(name) && j["parent"].as_str().is_some_and(|q| occ.contains_key(q)));
            // The design's first part comes in grounded: only the base stays so.
            cad.execute("occurrence.ground", &json!({"occurrence": occ[name], "grounded": !jointed})).map_err(|e| format!("{name}: occurrence.ground: {e}"))?;
        }
        let _ = child_of;
        let mut made = 0;
        for j in &joints {
            let (Some(parent), Some(child)) = (j["parent"].as_str(), j["child"].as_str()) else { continue };
            let (Some(a), Some(b)) = (occ.get(parent), occ.get(child)) else { continue };
            let lim = &j["limits_deg"];
            let params = json!({
                "type": j["type"].as_str().unwrap_or("revolute"),
                "a": a, "b": b,
                "at": {"frame": {"origin": j["origin"], "z": j["axis"]}, "occurrence": b},
                "name": j["name"],
                "limits": if lim.is_array() && j["type"].as_str() != Some("rigid") { json!([lim]) } else { Value::Null },
                "quiet": true,
            });
            cad.execute("joint.as_built", &params).map_err(|e| format!("joint {}: {e}", j["name"]))?;
            made += 1;
        }
        Ok(json!({"parts": occ.len(), "joints": made, "occurrences": occ}))
    })();
    match result {
        Ok(v) => {
            cad.drop_checkpoint(checkpoint);
            cad.undo = undo;
            cad.undo.push(before);
            if cad.undo.len() > MAX_UNDO {
                cad.undo.remove(0);
            }
            Ok(v)
        }
        Err(e) => {
            let restored = cad.restore_checkpoint(checkpoint).err().map(|r| format!(" (and the design could not be restored: {r})")).unwrap_or_default();
            Err(format!("{e}{restored}"))
        }
    }
}

/// A 3D study running on its own thread: its progress can be read, the run paused, resumed or
/// cancelled while it works, its convergence and a coarse preview of the shape followed live, and
/// once it is done its candidates build into a design without running it again. Every method
/// takes `&self` and may be called from any thread.
pub struct Job {
    cancel: Arc<AtomicBool>,
    pause: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
    progress: Arc<Mutex<solid::Progress>>,
    live: Arc<Mutex<Live>>,
    started: std::time::Instant,
    state: Mutex<JobState>,
}

/// Cells a live preview keeps at most: finer runs are averaged over blocks of voxels.
const PREVIEW_CELLS: usize = 48_000;

/// One iteration's figures, as the convergence plot draws them.
#[derive(Clone, Debug, serde::Serialize)]
pub struct LiveStep {
    pub variant: usize,
    pub iteration: usize,
    pub iterations: usize,
    pub objective: f64,
    /// Weighted compliance of the nominal design, N mm.
    pub compliance: f64,
    /// Volume fraction of the design voxels.
    pub volume: f64,
    /// Peak relaxed von Mises stress, MPa.
    pub max_stress: f64,
    /// Seconds the iteration took (pauses not counted).
    pub seconds: f64,
}

/// What the solving thread leaves for live front ends.
#[derive(Default)]
struct Live {
    steps: Vec<LiveStep>,
    /// The latest densities, decimated: grid, values, variant and iteration.
    preview: Option<(solid::Grid, Vec<f32>, usize, usize)>,
    /// Counts previews, so a front end asks for a surface only when it changed.
    version: u64,
    /// Seconds spent paused.
    paused: f64,
}

/// `density` on `grid` averaged over blocks of voxels so at most [`PREVIEW_CELLS`] remain.
pub fn decimate(grid: &solid::Grid, density: &[f64]) -> (solid::Grid, Vec<f32>) {
    let ne = grid.n.iter().product::<usize>();
    let f = ((ne as f64 / PREVIEW_CELLS as f64).cbrt().ceil() as usize).max(1);
    if f == 1 {
        return (*grid, density.iter().map(|&d| d as f32).collect());
    }
    let n = grid.n.map(|c| c.div_ceil(f));
    let coarse = solid::Grid { n, h: grid.h * f as f64, origin: grid.origin };
    let mut sum = vec![0f32; n[0] * n[1] * n[2]];
    let mut count = vec![0u16; sum.len()];
    let [nx, ny, nz] = grid.n;
    for k in 0..nz {
        for j in 0..ny {
            let row = nx * (j + ny * k);
            let crow = n[0] * (j / f + n[1] * (k / f));
            for i in 0..nx {
                sum[crow + i / f] += density[row + i] as f32;
                count[crow + i / f] += 1;
            }
        }
    }
    for (s, &c) in sum.iter_mut().zip(&count) {
        *s /= c.max(1) as f32;
    }
    (coarse, sum)
}

/// A rough cost index for a candidate, in dollars: material bought plus machine time, by
/// process. Additive (FDM) and free (SLS) layouts pay for the printed volume; milling pays for
/// the stock's bounding block and the volume cut away. For ranking variants, not for quoting.
pub fn cost_index(study: &solid::Study, c: &solid::Candidate) -> f64 {
    let name = study.material.name.to_lowercase();
    // $/kg of material as bought (filament, powder, bar stock).
    let per_kg = if name.contains("pla") || name.contains("petg") {
        25.0
    } else if name.contains("pa12") || name.contains("nylon") || name.contains("pa 12") {
        80.0
    } else if name.contains("ti") && !name.contains("tin") {
        300.0
    } else if name.contains("steel") || name.contains("316") {
        6.0
    } else if name.contains("al") {
        8.0
    } else if name.contains("carbon") || name.contains("cf") {
        60.0
    } else {
        30.0
    };
    let part_cm3 = c.mass_g / (study.material.density * 1000.0).max(1e-9);
    let p = &c.mesh.positions;
    let stock_cm3 = if p.len() >= 3 {
        let mut lo = [f32::MAX; 3];
        let mut hi = [f32::MIN; 3];
        for v in p.chunks_exact(3) {
            for a in 0..3 {
                lo[a] = lo[a].min(v[a]);
                hi[a] = hi[a].max(v[a]);
            }
        }
        (0..3).map(|a| (hi[a] - lo[a]).max(0.0) as f64 + 2.0).product::<f64>() / 1000.0
    } else {
        part_cm3
    };
    let kg = |cm3: f64| cm3 * study.material.density;
    match study.manufacturing {
        // FDM: filament plus printer time (~0.15 $/cm³).
        solid::Manufacturing::Additive { .. } => per_kg * kg(part_cm3) + 0.15 * part_cm3 + 2.0,
        // SLS (no support, any shape): powder plus machine time (~0.45 $/cm³).
        solid::Manufacturing::Free => per_kg * kg(part_cm3) * 1.3 + 0.45 * part_cm3 + 8.0,
        // CNC: the stock block, cutting time on the removed volume, a setup.
        solid::Manufacturing::Milling { .. } => per_kg * kg(stock_cm3) + 0.35 * (stock_cm3 - part_cm3).max(0.0) + 25.0,
        solid::Manufacturing::Extrusion { .. } => per_kg * kg(stock_cm3) + 0.10 * (stock_cm3 - part_cm3).max(0.0) + 10.0,
    }
}

/// The study `base` (3D study JSON) with a variant's overrides laid over it. `variant`:
/// `{"label", "volume_fraction", "material": {name, e, nu, density, allowable, color},
/// "process": "fdm" | "sls" | "cnc3" | "as_is", "build": [x, y, z], ...}`; any other key is a
/// study field and replaces the base's. FDM prints along `build` (default the base's build or
/// +z) with 45° overhangs, SLS is free, CNC 3-axis mills along `build` (default +z). The variant
/// runs one candidate (`variants: 1`) and computes at least the first mode, so `f1` compares.
pub fn variant_study(base: &Value, variant: &Value) -> Result<Value, String> {
    let mut s = base.clone();
    let obj = s.as_object_mut().ok_or("the base study is not an object")?;
    let v = variant.as_object().ok_or("the variant is not an object")?;
    let base_dir = match obj.get("manufacturing") {
        Some(m) => m.get("build").or_else(|| m.get("direction")).cloned(),
        None => None,
    };
    let dir = v.get("build").cloned().or(base_dir).unwrap_or(json!([0.0, 0.0, 1.0]));
    for (k, val) in v {
        match k.as_str() {
            "label" | "process" | "build" => {}
            _ => {
                obj.insert(k.clone(), val.clone());
            }
        }
    }
    match v.get("process").and_then(Value::as_str).unwrap_or("as_is") {
        "fdm" => {
            obj.insert("manufacturing".into(), json!({"process": "additive", "build": dir, "overhang": 45.0}));
        }
        "sls" => {
            obj.insert("manufacturing".into(), json!({"process": "free"}));
        }
        "cnc3" => {
            obj.insert("manufacturing".into(), json!({"process": "milling", "direction": dir}));
        }
        "as_is" => {}
        other => return Err(format!("unknown process {other} (fdm, sls, cnc3 or as_is)")),
    }
    obj.insert("variants".into(), json!(1));
    let modes = obj.get("dynamics").and_then(|d| d.get("modes")).and_then(Value::as_u64).unwrap_or(0);
    if modes == 0 {
        let mut d = obj.get("dynamics").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
        d["modes"] = json!(1);
        if d.get("impacts").is_none() {
            d["impacts"] = json!([]);
        }
        obj.insert("dynamics".into(), d);
    }
    let _: solid::Study = serde_json::from_value(s.clone()).map_err(|e| format!("variant study: {e}"))?;
    Ok(s)
}

type JobResult = Result<(solid::Study, solid::Outcome), String>;

struct JobState {
    thread: Option<std::thread::JoinHandle<JobResult>>,
    result: Option<JobResult>,
}

impl Job {
    /// Starts the 3D study `spec` (a [`solid::Study`] as JSON). A study that does not read
    /// fails here, before any thread starts.
    pub fn start(spec: &Value) -> Result<Job, String> {
        if !is_solid(spec) {
            return Err("a job runs a 3D study (min, max and voxel); a plate study runs through `study`".into());
        }
        let study: solid::Study = serde_json::from_value(spec.clone()).map_err(|e| format!("study: {e}"))?;
        let cancel = Arc::new(AtomicBool::new(false));
        let pause = Arc::new(AtomicBool::new(false));
        let done = Arc::new(AtomicBool::new(false));
        let progress = Arc::new(Mutex::new(solid::Progress { variants: study.variants.clamp(1, 16), iterations: study.iterations.max(1), stage: "starting".into(), ..Default::default() }));
        let live = Arc::new(Mutex::new(Live::default()));
        let (c, d, p, z, l) = (cancel.clone(), done.clone(), progress.clone(), pause.clone(), live.clone());
        let l2 = live.clone();
        let thread = std::thread::Builder::new()
            .name("viaform-generate".into())
            .spawn(move || {
                let run = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let mut observe = |s: &solid::Step| {
                        let (g, values) = decimate(&s.grid, s.density);
                        if let Ok(mut lv) = l2.lock() {
                            lv.steps.push(LiveStep {
                                variant: s.variant,
                                iteration: s.iteration,
                                iterations: s.iterations,
                                objective: s.objective,
                                compliance: s.compliance,
                                volume: s.volume,
                                max_stress: s.max_stress,
                                seconds: s.seconds,
                            });
                            lv.preview = Some((g, values, s.variant, s.iteration));
                            lv.version += 1;
                        }
                    };
                    solid::generate_observed(
                        &study,
                        &mut |now| {
                            if let Ok(mut g) = p.lock() {
                                *g = now.clone();
                            }
                            // Paused: hold between iterations until resumed or cancelled.
                            if z.load(Ordering::Relaxed) {
                                let t = std::time::Instant::now();
                                while z.load(Ordering::Relaxed) && !c.load(Ordering::Relaxed) {
                                    std::thread::sleep(std::time::Duration::from_millis(20));
                                }
                                if let Ok(mut lv) = l.lock() {
                                    lv.paused += t.elapsed().as_secs_f64();
                                }
                            }
                            !c.load(Ordering::Relaxed)
                        },
                        Some(&mut observe),
                    )
                }));
                d.store(true, Ordering::Release);
                match run {
                    Ok(r) => r.map(|o| (study, o)),
                    Err(_) => Err("the engine stopped on this study".into()),
                }
            })
            .map_err(|e| format!("could not start the study: {e}"))?;
        Ok(Job { cancel, pause, done, progress, live, started: std::time::Instant::now(), state: Mutex::new(JobState { thread: Some(thread), result: None }) })
    }

    /// Asks the run to stop at its next iteration.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    /// Holds the run after its current iteration (`true`) or lets it go on (`false`).
    pub fn set_paused(&self, paused: bool) {
        self.pause.store(paused, Ordering::Relaxed);
    }

    pub fn paused(&self) -> bool {
        self.pause.load(Ordering::Relaxed)
    }

    /// Iterations from `from` on (0: all), as the convergence plot draws them:
    /// `[{variant, iteration, iterations, objective, compliance, volume, max_stress, seconds}]`.
    pub fn history(&self, from: usize) -> Value {
        let lv = self.live.lock().unwrap_or_else(|e| e.into_inner());
        serde_json::to_value(lv.steps.get(from.min(lv.steps.len())..).unwrap_or(&[])).unwrap_or(Value::Null)
    }

    /// The latest shape as a coarse surface (densities averaged to at most 48 000 cells, iso
    /// 0.5), when it is newer than `since`: `(version, variant, iteration, mesh)`. Surfacing runs
    /// on the caller's thread, not the solver's.
    pub fn preview(&self, since: u64) -> Option<(u64, usize, usize, solid::Mesh)> {
        let (version, grid, values, variant, iteration) = {
            let lv = self.live.lock().unwrap_or_else(|e| e.into_inner());
            if lv.version <= since {
                return None;
            }
            let (g, v, var, it) = lv.preview.as_ref()?;
            (lv.version, *g, v.clone(), *var, *it)
        };
        Some((version, variant, iteration, solid::iso::surface(&grid, &values, 0.5, 1)))
    }

    pub fn finished(&self) -> bool {
        self.done.load(Ordering::Acquire)
    }

    /// `{running, cancelled, paused, variant, variants, iteration, iterations, objective, stage,
    /// fraction, seconds, eta, per_iteration, preview}`; `fraction` counts iterations over every
    /// variant (0..1), `eta` is the seconds still to solve (null before two iterations; the
    /// mean of the last five iterations times those left, pauses not counted), `preview` the
    /// latest preview's version.
    pub fn progress(&self) -> Value {
        let p = self.progress.lock().map(|g| g.clone()).unwrap_or_default();
        let per = p.iterations.max(1) as f64;
        let within = match p.stage.as_str() {
            "done" => 1.0,
            "analysing" => 0.98,
            _ => (p.iteration as f64 / per).min(0.97),
        };
        let fraction = if p.stage == "done" { 1.0 } else { (p.variant as f64 + within) / p.variants.max(1) as f64 };
        let (per, version, paused_s) = {
            let lv = self.live.lock().unwrap_or_else(|e| e.into_inner());
            let tail = &lv.steps[lv.steps.len().saturating_sub(5)..];
            let per = (lv.steps.len() >= 2).then(|| tail.iter().map(|s| s.seconds).sum::<f64>() / tail.len() as f64);
            (per, lv.version, lv.paused)
        };
        let left = p.iterations.saturating_sub(p.iteration) + p.variants.saturating_sub(p.variant + 1) * p.iterations;
        let eta = match (p.stage.as_str(), per) {
            ("done", _) => Some(0.0),
            (_, Some(s)) if !self.finished() => Some(s * left as f64),
            _ => None,
        };
        json!({
            "running": !self.finished(),
            "cancelled": self.cancel.load(Ordering::Relaxed),
            "paused": self.paused(),
            "eta": eta,
            "per_iteration": per,
            "paused_seconds": paused_s,
            "preview": version,
            "variant": p.variant, "variants": p.variants,
            "iteration": p.iteration, "iterations": p.iterations,
            "objective": if p.objective.is_finite() { json!(p.objective) } else { Value::Null },
            "stage": p.stage,
            "fraction": fraction.clamp(0.0, 1.0),
            "seconds": self.started.elapsed().as_secs_f64(),
        })
    }

    /// Waits for the run, then hands its result to `f`.
    fn with_result<T>(&self, f: impl FnOnce(&JobResult) -> T) -> T {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if st.result.is_none() {
            let r = match st.thread.take() {
                Some(t) => t.join().unwrap_or_else(|_| Err("the engine stopped on this study".into())),
                None => Err("the study never started".into()),
            };
            st.result = Some(r);
        }
        f(st.result.as_ref().expect("joined"))
    }

    /// Waits for the run, then answers its outcome as JSON (candidates with their surfaces and
    /// densities), or the error (`cancelled` when it was stopped).
    pub fn outcome(&self) -> Result<Value, String> {
        self.with_result(|r| match r {
            Ok((_, o)) => serde_json::to_value(o).map_err(|e| e.to_string()),
            Err(e) => Err(e.clone()),
        })
    }

    /// Waits for the run, then answers its outcome without densities or surfaces (each candidate
    /// as [`solid_figures`], plus `cost` from [`cost_index`] and `f1`, Hz, null without modes):
    /// small, so results open at once; surfaces come one by one through [`Job::with_mesh`].
    pub fn summary(&self) -> Result<Value, String> {
        self.with_result(|r| match r {
            Ok((study, o)) => {
                let cands: Vec<Value> = o
                    .candidates
                    .iter()
                    .map(|c| {
                        let mut v = solid_figures(c);
                        v["cost"] = json!(cost_index(study, c));
                        v["f1"] = c.analysis.modes.first().map_or(Value::Null, |m| json!(m.frequency));
                        v
                    })
                    .collect();
                Ok(json!({"candidates": cands, "best": o.best, "seconds": o.seconds, "warnings": o.warnings}))
            }
            Err(e) => Err(e.clone()),
        })
    }

    /// Waits for the run, then hands candidate `candidate`'s surface (the best when `None`) to `f`.
    pub fn with_mesh<T>(&self, candidate: Option<usize>, f: impl FnOnce(&solid::Mesh) -> T) -> Result<T, String> {
        self.with_result(|r| match r {
            Ok((_, o)) => {
                let pick = candidate.unwrap_or(o.best);
                o.candidates.get(pick).map(|c| f(&c.mesh)).ok_or_else(|| format!("no candidate {pick}"))
            }
            Err(e) => Err(e.clone()),
        })
    }

    /// Waits for the run, then inserts candidate `candidate` (the best when `None`) into `cad`
    /// as one mesh body, one undo step, without running the study again.
    pub fn build(&self, cad: &mut Session, candidate: Option<usize>) -> Result<Value, String> {
        self.with_result(|r| match r {
            Ok((study, outcome)) => insert_candidate(cad, study, outcome, candidate),
            Err(e) => Err(e.clone()),
        })
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        // A dropped job stops its run; the thread ends at its next iteration on its own.
        self.cancel();
    }
}
