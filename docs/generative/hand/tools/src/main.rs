//! `viaform-hand <command>` (run from anywhere, writes docs/generative/hand):
//!
//! - `studies`: writes every structural part's study to `studies/<name>.json`.
//! - `run [--only word,word]`: runs the studies in `studies/` (the files are the source of
//!   truth) on the 3D engine, writes `parts/<name>.{stl,3mf,obj}` and `results/<name>.json`
//!   (figures) with `results/<name>.dens` (the voxel layout, one byte per voxel).
//! - `assemble`: places every generated part and every real component, writes `assembly.json`
//!   with joints, motors and the checks (motion, fist, opposition, quantities), and renders
//!   `renders/*.png`.

mod assembly;
mod common;
mod design;
mod motion;
mod render;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use viaform_generative::solid::{self, Study, export, iso};

pub fn hand_dir() -> PathBuf {
    common::out_dir("hand")
}

fn unique_studies(d: &design::Design) -> Vec<Study> {
    let mut out: Vec<Study> = Vec::new();
    for p in &d.parts {
        if !out.iter().any(|s| s.name == p.study.name) {
            out.push(p.study.clone());
        }
    }
    out
}

fn voxels(s: &Study) -> usize {
    solid::Grid::new(s.min, s.max, s.voxel).elements()
}

fn write_studies(dir: &Path) {
    let d = design::build();
    std::fs::create_dir_all(dir.join("studies")).unwrap();
    for s in unique_studies(&d) {
        std::fs::write(dir.join("studies").join(format!("{}.json", s.name)), serde_json::to_string_pretty(&s).unwrap()).unwrap();
        eprintln!("{:<22} {:>8} voxels at {:.2} mm", s.name, voxels(&s), s.voxel);
    }
}

fn run(dir: &Path, only: Option<Vec<String>>) {
    let d = design::build();
    let mut studies: Vec<Study> = unique_studies(&d)
        .into_iter()
        .map(|s| {
            let path = dir.join("studies").join(format!("{}.json", s.name));
            let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e} (run `studies` first)", path.display()));
            serde_json::from_str::<Study>(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
        })
        .filter(|s| only.as_ref().is_none_or(|w| w.iter().any(|w| s.name.contains(w.as_str()))))
        .collect();
    studies.sort_by_key(voxels);
    std::fs::create_dir_all(dir.join("parts")).unwrap();
    std::fs::create_dir_all(dir.join("results")).unwrap();
    for s in &studies {
        let t = std::time::Instant::now();
        let out = match solid::generate(s) {
            Ok(o) => o,
            Err(e) => {
                eprintln!("{}: FAILED {e}", s.name);
                continue;
            }
        };
        let c = &out.candidates[out.best];
        let stem = dir.join("parts").join(&s.name);
        std::fs::write(stem.with_extension("stl"), export::stl(&c.mesh, &s.name)).unwrap();
        std::fs::write(stem.with_extension("3mf"), export::three_mf(&c.mesh, &s.name)).unwrap();
        std::fs::write(stem.with_extension("obj"), export::obj(&c.mesh)).unwrap();
        let a = &c.analysis;
        let limit = s.max_stress.unwrap_or(s.material.allowable / s.safety_factor);
        let max_stress = a.max_stress.iter().copied().fold(0.0, f64::max);
        let max_disp = a.max_displacement.iter().copied().fold(0.0, f64::max);
        let impacts: Vec<Value> = a.impacts.iter().map(|i| json!({"case": s.cases[i.case].name, "peak_stress_mpa": i.peak_stress, "peak_displacement_mm": i.peak_displacement, "amplification": i.amplification})).collect();
        let peak_dyn = a.impacts.iter().map(|i| i.peak_stress).fold(0.0, f64::max);
        let r = json!({
            "name": s.name,
            "material": s.material.name,
            "mass_g": c.mass_g,
            "volume_fraction": c.volume_fraction,
            "feasible": c.feasible,
            "stress_limit_mpa": limit,
            "yield_mpa": s.material.allowable,
            "max_von_mises_mpa": max_stress.max(peak_dyn),
            "safety_factor": a.safety_factor,
            "max_displacement_mm": max_disp.max(a.impacts.iter().map(|i| i.peak_displacement).fold(0.0, f64::max)),
            "first_frequency_hz": a.modes.first().map(|m| m.frequency),
            "modes_hz": a.modes.iter().map(|m| m.frequency).collect::<Vec<_>>(),
            "cases": s.cases.iter().enumerate().map(|(k, cs)| json!({"name": cs.name, "max_von_mises_mpa": a.max_stress.get(k), "max_displacement_mm": a.max_displacement.get(k), "compliance_nmm": a.compliance.get(k)})).collect::<Vec<_>>(),
            "impacts": impacts,
            "iterations": c.history.len(),
            "voxels": c.grid.elements(),
            "voxel_mm": c.grid.h,
            "grid": c.grid,
            "triangles": c.mesh.indices.len() / 3,
            "closed": iso::is_closed(&c.mesh),
            "manifold": iso::is_manifold(&c.mesh),
            "mesh_volume_mm3": iso::volume(&c.mesh),
            "seconds": t.elapsed().as_secs_f64(),
            "files": {"stl": format!("parts/{}.stl", s.name), "3mf": format!("parts/{}.3mf", s.name), "obj": format!("parts/{}.obj", s.name), "study": format!("studies/{}.json", s.name), "density": format!("results/{}.dens", s.name)},
        });
        std::fs::write(dir.join("results").join(format!("{}.json", s.name)), serde_json::to_string_pretty(&r).unwrap()).unwrap();
        let bytes: Vec<u8> = c.density.iter().map(|d| (d.clamp(0.0, 1.0) * 255.0).round() as u8).collect();
        std::fs::write(dir.join("results").join(format!("{}.dens", s.name)), bytes).unwrap();
        eprintln!(
            "{:<22} {:>8.2} g  vm {:>6.1} / {:>5.1} MPa  SF {:>5.2}  u {:>6.3} mm  f1 {:>7.0} Hz  {} its  {} vox  {:.0} s{}",
            s.name,
            c.mass_g,
            max_stress.max(peak_dyn),
            limit,
            a.safety_factor,
            max_disp,
            a.modes.first().map_or(0.0, |m| m.frequency),
            c.history.len(),
            c.grid.elements(),
            t.elapsed().as_secs_f64(),
            if c.feasible { "" } else { "  NOT FEASIBLE" }
        );
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = hand_dir();
    let only = args.iter().position(|a| a == "--only").and_then(|i| args.get(i + 1)).map(|w| w.split(',').map(String::from).collect());
    match args.first().map(String::as_str) {
        Some("studies") => write_studies(&dir),
        Some("run") => run(&dir, only),
        Some("assemble") => assembly::assemble(&dir),
        _ => {
            eprintln!("usage: viaform-hand studies | run [--only word,word] | assemble");
            std::process::exit(2);
        }
    }
}
