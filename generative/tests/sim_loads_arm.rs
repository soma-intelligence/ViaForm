//! Loads from simulation, end to end: the sample arm scenario runs in phys, its upper arm's
//! wrench history at the elbow becomes a few load cases (`loads_from_record`, the bridge's JSON
//! op), and a coarse topology study of the upper arm held at the shoulder converges under them.
//! `cargo test --release -p viaform-generative --test sim_loads_arm -- --nocapture`

use serde_json::{Value, json};
use viaform_generative::solid::{self, Region, Study, Support, sim_loads};
use viaform_phys::{Phys, call};

fn ok(v: Value) -> Value {
    assert!(v.get("ok").is_some(), "facade error: {v}");
    v["ok"].clone()
}

#[test]
fn arm_scenario_loads_drive_a_converging_study() {
    let assembly: Value = serde_json::from_str(include_str!("../../docs/samples/arm/assembly.json")).unwrap();
    let scenario = json!({
        "format": "viaform-scenario", "version": 1, "id": "swing", "engine": "phys", "seed": 3,
        "initial": {"pose": "home"},
        "drives": [{"joint": "shoulder_lift", "timeline": [[0.0, 0.0], [0.4, 40.0], [0.9, -30.0]]},
                   {"joint": "elbow", "timeline": [[0.0, 0.0], [0.6, 45.0], [1.0, 0.0]]}],
        "record": {"every": 5},
        "duration_s": 1.2, "rate_hz": 1000, "control_hz": 50
    });
    let mut p = Phys::new();
    ok(call(&mut p, "world_new", &json!({"assembly": assembly, "scenario": scenario})));
    ok(call(&mut p, "world_step", &json!({"seconds": 1.2})));
    let record = call(&mut p, "wrench_history", &json!({"body": "upper_arm"}));
    let hist = ok(record.clone());
    let sources: Vec<&str> = hist.as_array().unwrap().iter().map(|h| h["source"].as_str().unwrap()).collect();
    println!("G3 arm: upper_arm histories {sources:?}");

    // The elbow sits at `at` in the upper arm's frame (m); the study is the link frame in mm,
    // a box from the shoulder (link origin) to the elbow.
    let elbow = sim_loads::from_record(&record, "upper_arm", "joint:elbow").unwrap();
    let e = elbow.at[0].map(|x| x * 1000.0);
    println!("G3 arm: {} samples, elbow at {e:?} mm", elbow.t.len());
    let axis = (0..3).max_by(|&a, &b| e[a].abs().total_cmp(&e[b].abs())).unwrap();
    assert!(e[axis].abs() > 20.0, "elbow too close to the shoulder: {e:?}");
    let (lo, hi) = (e[axis].min(0.0), e[axis].max(0.0));
    let half = 16.0;
    let mut min = [-half; 3];
    let mut max = [half; 3];
    min[axis] = lo;
    max[axis] = hi;
    for a in (0..3).filter(|&a| a != axis) {
        min[a] += e[a].min(0.0);
        max[a] += e[a].max(0.0);
    }
    let slab = |at: f64| {
        let (mut a, mut b) = (min, max);
        a[axis] = at - 4.1;
        b[axis] = at + 4.1;
        a.iter_mut().zip(b.iter_mut()).enumerate().filter(|(k, _)| *k != axis).for_each(|(_, (x, y))| {
            *x -= 1.0;
            *y += 1.0;
        });
        Region::Box { min: a, max: b }
    };
    let shoulder_face = slab(0.0);
    let elbow_end = slab(e[axis]);

    let req = json!({
        "record": record, "body": "upper_arm",
        "interfaces": [{"source": "joint:elbow", "region": elbow_end, "center": e}],
        "max_cases": 4, "dynamic_factor": 1.2, "safety_factor": 1.5
    });
    let out = sim_loads::loads_from_record(&req).unwrap();
    let loads: sim_loads::SimLoads = serde_json::from_value(out).unwrap();
    for c in &loads.cases {
        println!("G3 arm case: t {:.3} s, |F| {:.3} N, |M| {:.1} N mm, scale {:.3}, governs {:?}", c.t, c.force[0], c.moment[0], c.scale, c.governs);
    }
    println!("G3 arm: peak |F| {:.3} N, peak |M| {:.1} N mm, {} cases, {} dropped", loads.peak_force[0], loads.peak_moment[0], loads.cases.len(), loads.dropped);
    assert!(!loads.cases.is_empty() && loads.cases.len() <= 4);
    assert!(loads.peak_force[0] > 0.1, "the elbow carries the forearm's weight");
    // Factors applied, and the max-force case is at least the peak.
    let fmax = loads.cases.iter().map(|c| c.force[0]).fold(0.0, f64::max);
    assert!(fmax >= 1.8 * loads.peak_force[0] - 1e-9, "{fmax} vs {}", loads.peak_force[0]);

    let study = Study {
        min,
        max,
        voxel: 4.0,
        supports: vec![Support { region: shoulder_face, fix: [true; 3] }],
        cases: loads.load_cases(),
        volume_fraction: 0.3,
        iterations: 30,
        min_member: 8.0,
        smoothing: 2,
        ..Study::default()
    };
    let started = std::time::Instant::now();
    let outcome = solid::generate(&study).unwrap();
    let cand = &outcome.candidates[outcome.best];
    let h = &cand.history;
    println!(
        "G3 arm study: {} cases, {} elements, objective {:.4} -> {:.4} over {} iterations, max stress {:?} MPa, {:.2} s",
        study.cases.len(),
        cand.grid.elements(),
        h[0],
        h[h.len() - 1],
        h.len(),
        cand.analysis.max_stress,
        started.elapsed().as_secs_f64()
    );
    assert!(h.iter().all(|x| x.is_finite()));
    assert!(h[h.len() - 1] < 0.7 * h[0], "objective {} -> {}", h[0], h[h.len() - 1]);
    // The tail has settled: the last iterations move the objective little.
    let tail = &h[h.len() - 5..];
    let spread = tail.iter().cloned().fold(f64::MIN, f64::max) - tail.iter().cloned().fold(f64::MAX, f64::min);
    assert!(spread < 0.1 * h[h.len() - 1], "still moving: {tail:?}");
    assert!(cand.analysis.unsupported.is_empty(), "{:?}", cand.analysis.unsupported);
    assert!(cand.analysis.max_stress.iter().all(|s| s.is_finite() && *s > 0.0));
}
