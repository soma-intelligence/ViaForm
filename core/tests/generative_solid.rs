//! A 3D generative study through the workspace: the outcome as JSON, then the best candidate
//! built as one closed mesh body in one undo step.

use serde_json::{Value, json};
use viaform_core::{Workspace, scene};

/// A 40 x 10 x 16 mm bracket on 1 mm voxels: held on its left face, pulled down at its right end.
fn bracket() -> Value {
    json!({
        "name": "Bracket3D",
        "min": [0.0, 0.0, 0.0],
        "max": [40.0, 10.0, 16.0],
        "voxel": 1.0,
        "iterations": 25,
        "volume_fraction": 0.3,
        "supports": [{"region": {"shape": "box", "min": [-0.1, -1.0, -1.0], "max": [0.1, 11.0, 17.0]}}],
        "cases": [{"name": "tip", "loads": [{"type": "force", "region": {"shape": "box", "min": [39.9, -1.0, 7.0], "max": [41.0, 11.0, 9.0]}, "force": [0.0, 0.0, -300.0]}]}],
        "dynamics": {"modes": 2},
    })
}

#[test]
fn a_3d_study_answers_mesh_stress_and_modes() {
    let out = viaform_core::generative::study(&bracket()).expect("study");
    let c = &out["candidates"][0];
    assert!(c["mesh"]["indices"].as_array().is_some_and(|i| i.len() > 300));
    assert_eq!(c["mesh"]["stress"].as_array().map(Vec::len).unwrap_or(0) * 3, c["mesh"]["positions"].as_array().map(Vec::len).unwrap_or(1));
    assert_eq!(c["analysis"]["modes"].as_array().map(Vec::len), Some(2));
    assert!(c["mass_g"].as_f64().is_some_and(|m| m > 0.0));
}

#[test]
fn builds_the_3d_candidate_as_one_mesh_body_in_one_undo_step() {
    let mut w = Workspace::new(false);
    let undo = w.cad.undo.len();
    let r = w.generate(&bracket(), None).expect("build");
    assert_eq!(r["body"], "Bracket3D");
    assert_eq!(w.cad.undo.len(), undo + 1);
    let bodies: Vec<String> = scene::build(&w.cad, None).meshes.into_iter().map(|m| m.body).collect();
    assert!(bodies.iter().any(|b| b.contains("Bracket3D")), "{bodies:?}");
}

/// Two generated parts, one jointed to the other: inserted, placed, grounded and jointed in one
/// undo step, and the child turns when its joint is driven.
#[test]
fn a_generated_assembly_inserts_with_working_joints() {
    use viaform_core::viaform_generative::solid::{Mesh, export};
    let cube = |x0: f32, x1: f32| {
        let p = [[x0, 0.0, 0.0], [x1, 0.0, 0.0], [x1, 4.0, 0.0], [x0, 4.0, 0.0], [x0, 0.0, 4.0], [x1, 0.0, 4.0], [x1, 4.0, 4.0], [x0, 4.0, 4.0]];
        let t: [[u32; 3]; 12] = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]];
        Mesh { positions: p.iter().flatten().copied().collect(), indices: t.iter().flatten().copied().collect(), stress: Vec::new() }
    };
    let dir = std::env::temp_dir().join(format!("viaform-assembly-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (a, b, m) = (dir.join("Base.3mf"), dir.join("Arm.3mf"), dir.join("Servo.3mf"));
    std::fs::write(&a, export::three_mf(&cube(0.0, 10.0), "Base")).unwrap();
    std::fs::write(&b, export::three_mf(&cube(0.0, 10.0), "Arm")).unwrap();
    std::fs::write(&m, export::three_mf(&cube(0.0, 2.0), "Servo")).unwrap();
    let spec = json!({
        "parts": [
            {"name": "Base", "file": a.to_string_lossy(), "pose": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]},
            {"name": "Arm", "file": b.to_string_lossy(), "pose": [1, 0, 0, 10, 0, 1, 0, 0, 0, 0, 1, 0], "properties": {"material": "AlSi10Mg", "mass_g": 1.5}},
            {"name": "Servo 1", "file": m.to_string_lossy(), "pose": [1, 0, 0, 14, 0, 1, 0, 0, 0, 0, 1, 4], "component_ref": "M1", "part_number": "XC330-T288-T", "bom_type": "purchased"},
        ],
        "joints": [
            {"name": "Elbow", "type": "revolute", "parent": "Base", "child": "Arm", "origin": [10.0, 2.0, 2.0], "axis": [0.0, 1.0, 0.0], "limits_deg": [-90.0, 90.0]},
            {"name": "Servo 1 mount", "type": "rigid", "parent": "Arm", "child": "Servo 1", "origin": [14.0, 0.0, 4.0], "axis": [0.0, 0.0, 1.0]},
        ],
    });
    let mut w = Workspace::new(false);
    let undo = w.cad.undo.len();
    let r = viaform_core::generative::assemble(&mut w.cad, &spec).expect("assemble");
    assert_eq!(r["joints"], 2);
    assert_eq!(w.cad.undo.len(), undo + 1);
    let d = w.cad.execute("joint.drive", &json!({"joint": "Elbow", "value": 45.0})).expect("drive");
    assert_eq!(d["moved"], true, "{d}");
    // The bought part carries its component file line into the bill of materials.
    let bom = w.cad.execute("assembly.bom", &json!({"levels": "flat"})).expect("bom");
    let rows = bom["rows"].as_array().unwrap();
    assert!(rows.iter().any(|r| r["properties"]["component_ref"] == "M1"), "{bom}");
    assert!(rows.iter().any(|r| r["properties"]["material"] == "AlSi10Mg"), "{bom}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A study run as a job: progress counts up, the outcome comes back, and the picked candidate
/// builds into the design as one undo step without running the study again.
#[test]
fn a_job_reports_progress_and_builds_its_outcome() {
    use viaform_core::generative::Job;
    let job = Job::start(&bracket()).expect("start");
    let mut seen = 0.0f64;
    while !job.finished() {
        let p = job.progress();
        seen = seen.max(p["fraction"].as_f64().unwrap_or(0.0));
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let done = job.progress();
    assert_eq!(done["running"], false);
    assert_eq!(done["fraction"].as_f64(), Some(1.0), "{done}");
    assert_eq!(done["iterations"].as_u64(), Some(25));
    let out = job.outcome().expect("outcome");
    assert!(out["candidates"].as_array().is_some_and(|c| !c.is_empty()));
    let mut w = Workspace::new(false);
    let undo = w.cad.undo.len();
    let t = std::time::Instant::now();
    let r = job.build(&mut w.cad, None).expect("build");
    assert_eq!(r["body"], "Bracket3D");
    assert_eq!(w.cad.undo.len(), undo + 1);
    assert!(seen >= 0.0 && t.elapsed().as_secs_f64() < 5.0);
}

/// Cancelling stops the run at its next iteration: it keeps its best design so far (flagged
/// stopped, not converged) or, with no solid formed yet, answers the `cancelled` error.
#[test]
fn a_cancelled_job_stops_early() {
    use viaform_core::generative::Job;
    let mut spec = bracket();
    spec["iterations"] = json!(400);
    spec["voxel"] = json!(0.5);
    let job = Job::start(&spec).expect("start");
    while job.progress()["iteration"].as_u64().unwrap_or(0) < 2 && !job.finished() {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    job.cancel();
    let t = std::time::Instant::now();
    match job.summary() {
        Ok(s) => assert_eq!(s["candidates"][0]["converged"], false, "{s}"),
        Err(e) => assert_eq!(e, "cancelled"),
    }
    assert!(t.elapsed().as_secs_f64() < 5.0, "stopped in {:.2} s", t.elapsed().as_secs_f64());
    assert!(job.progress()["cancelled"].as_bool().unwrap_or(false));
}

/// A live job: every iteration lands in the history with its figures, a coarse preview surface
/// follows the shape, pausing holds the run and resuming lets it finish, the ETA shows once two
/// iterations ran, and the summary (no densities) comes back small with cost and f1.
#[test]
fn a_live_job_reports_history_preview_pause_and_summary() {
    use viaform_core::generative::Job;
    let mut spec = bracket();
    spec["iterations"] = json!(12);
    let job = Job::start(&spec).expect("start");
    while job.progress()["iteration"].as_u64().unwrap_or(0) < 3 && !job.finished() {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    job.set_paused(true);
    std::thread::sleep(std::time::Duration::from_millis(400));
    let held = job.progress()["iteration"].as_u64().unwrap_or(0);
    std::thread::sleep(std::time::Duration::from_millis(400));
    let p = job.progress();
    assert_eq!(p["paused"], true);
    assert!(p["iteration"].as_u64().unwrap_or(0) <= held + 1, "paused run moved on: {p}");
    assert!(p["eta"].as_f64().is_some_and(|e| e >= 0.0), "{p}");
    let (version, _, iteration, mesh) = job.preview(0).expect("a preview");
    assert!(version >= 3 && iteration >= 1 && !mesh.indices.is_empty());
    assert!(job.preview(version).is_none() || job.progress()["preview"].as_u64().unwrap_or(0) > version);
    job.set_paused(false);
    let summary = job.summary().expect("summary");
    let h = job.history(0);
    let steps = h.as_array().expect("history");
    assert!(steps.len() >= 12, "{}", steps.len());
    for (i, s) in steps.iter().enumerate() {
        assert_eq!(s["iteration"].as_u64(), Some(i as u64 + 1));
        assert!(s["compliance"].as_f64().is_some_and(|c| c > 0.0) && s["volume"].as_f64().is_some_and(|v| v > 0.0 && v <= 1.0));
        assert!(s["max_stress"].as_f64().is_some_and(|m| m >= 0.0), "{s}");
    }
    assert_eq!(job.history(5).as_array().map(Vec::len), Some(steps.len() - 5));
    let c = &summary["candidates"][0];
    assert!(c.get("density").is_none() && c.get("mesh").is_none(), "{c}");
    assert!(c["cost"].as_f64().is_some_and(|x| x > 0.0), "{c}");
    assert!(summary.to_string().len() < 200_000);
    let tris = job.with_mesh(None, |m| m.indices.len() / 3).expect("mesh");
    assert_eq!(c["triangles"].as_u64(), Some(tris as u64));
}

/// Variants: volume fraction, material and process laid over a base study, each one candidate
/// with its first mode, and an unknown process refused.
#[test]
fn variant_studies_override_fraction_material_and_process() {
    use viaform_core::generative::variant_study;
    let base = bracket();
    let pa12 = json!({"name": "PA12", "e": 1700.0, "nu": 0.4, "density": 0.00101, "allowable": 45.0, "color": "#d8d4cc"});
    let fdm = variant_study(&base, &json!({"label": "FDM 20 %", "volume_fraction": 0.2, "process": "fdm"})).unwrap();
    assert_eq!(fdm["manufacturing"]["process"], "additive");
    assert_eq!(fdm["manufacturing"]["overhang"], 45.0);
    assert_eq!(fdm["volume_fraction"], 0.2);
    assert_eq!(fdm["variants"], 1);
    assert!(fdm["dynamics"]["modes"].as_u64().unwrap_or(0) >= 1);
    let sls = variant_study(&base, &json!({"process": "sls", "material": pa12})).unwrap();
    assert_eq!(sls["manufacturing"]["process"], "free");
    assert_eq!(sls["material"]["name"], "PA12");
    let cnc = variant_study(&base, &json!({"process": "cnc3", "build": [0.0, 0.0, -1.0]})).unwrap();
    assert_eq!(cnc["manufacturing"]["process"], "milling");
    assert_eq!(cnc["manufacturing"]["direction"], json!([0.0, 0.0, -1.0]));
    assert!(variant_study(&base, &json!({"process": "laser"})).is_err());
}
