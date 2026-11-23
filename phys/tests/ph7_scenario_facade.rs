//! Scenario loader and JSON facade: the sample arm assembly with a pick-style scenario, run
//! through the facade ops; the wrench history balances the arm's weight; the same seed gives
//! the same run; a job runs on a thread; a batch steps copies of the scenario world.
//! `cargo test --release -p viaform-phys --test ph7_scenario_facade -- --nocapture`

use serde_json::{Value, json};
use viaform_phys::{Phys, call};

fn assembly() -> Value {
    serde_json::from_str(include_str!("../../docs/samples/arm/assembly.json")).unwrap()
}

fn scenario(seed: u64) -> Value {
    json!({
        "format": "viaform-scenario", "version": 1, "id": "pick", "engine": "phys", "seed": seed,
        "world": {"table": {"size_m": [0.8, 0.6], "height_m": 0.05},
                  "objects": [{"id": "cube", "shape": "box", "size_m": 0.03, "mass_kg": 0.02, "pose": "random_in:[0.15,0.3]x[-0.1,0.1]"}]},
        "initial": {"pose": "home"},
        "drives": [{"joint": "shoulder_lift", "timeline": [[0.0, 0.0], [0.5, 30.0], [1.2, -20.0]]},
                   {"joint": "elbow", "target": 20.0}],
        "randomise": {"mass_pct": 10, "friction_pct": 20, "latency_ms": [5, 25], "backlash_deg": [0, 0.5]},
        "record": {"every": 10},
        "duration_s": 2.0, "rate_hz": 1000, "control_hz": 50
    })
}

fn ok(v: Value) -> Value {
    assert!(v.get("ok").is_some(), "facade error: {v}");
    v["ok"].clone()
}

#[test]
fn scenario_runs_through_the_facade() {
    let mut p = Phys::new();
    let info = ok(call(&mut p, "world_new", &json!({"assembly": assembly(), "scenario": scenario(4)})));
    println!("PH7 scenario links {} actuators {} randomised {}", info["links"], info["actuators"], info["scenario"]["randomised"]);
    assert_eq!(info["links"][1], "base");
    ok(call(&mut p, "world_step", &json!({"seconds": 0.3})));
    let st = ok(call(&mut p, "world_state", &json!({})));
    let nl = info["links"].as_array().unwrap().len();
    assert_eq!(st["poses"].as_array().unwrap().len(), 7 * nl);
    let w = ok(call(&mut p, "wrench_history", &json!({"body": "base", "source": "joint:base", "pick": "at", "t": 0.29})));
    println!("PH7 wrench history shape: body {}, source {}, t {}, force {}, at {}, accel {}", w[0]["body"], w[0]["source"], w[0]["t"], w[0]["force"], w[0]["at"], w[0]["accel"]);
    // Run the rest as a job.
    let job = ok(call(&mut p, "episode_start", &json!({})));
    let id = job["job"].as_u64().unwrap();
    let mut state = Value::Null;
    for _ in 0..2000 {
        state = ok(call(&mut p, "job_poll", &json!({"id": id})));
        if state["state"] != "running" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    assert_eq!(state["state"], "done", "{state}");
    let peak = ok(call(&mut p, "wrench_history", &json!({"body": "upper_arm", "pick": "peak"})));
    println!("PH7 job done at t {}; upper_arm peak wrenches: {}", state["t"], peak.as_array().unwrap().iter().map(|h| format!("{} {:.2} N", h["source"], (0..3).map(|k| h["force"][0][k].as_f64().unwrap().powi(2)).sum::<f64>().sqrt())).collect::<Vec<_>>().join(", "));
    let env = ok(call(&mut p, "wrench_history", &json!({"body": "upper_arm", "source": "joint:shoulder_lift"})));
    assert_eq!(env[0]["t"].as_array().unwrap().len(), env[0]["accel"].as_array().unwrap().len());
    let episode = ok(call(&mut p, "episode_record", &json!({"get": true})));
    assert!(episode["t"].as_array().unwrap().len() > 150);
    // A batch of copies.
    let b = ok(call(&mut p, "batch_new", &json!({"n": 8})));
    let q = ok(call(&mut p, "batch_step", &json!({"steps": 20})));
    assert_eq!(q["q"].as_array().unwrap().len(), 8 * b["nq"].as_u64().unwrap() as usize);
    // Errors carry codes.
    let e = call(&mut p, "nope", &json!({}));
    assert_eq!(e["code"], "op.unknown");
    let e = call(&mut Phys::new(), "world_state", &json!({}));
    assert_eq!(e["code"], "world.none");
}

#[test]
fn base_carries_the_arm_weight() {
    // No drives: the servos hold the home pose; the base joint carries every link's weight.
    let mut sc = scenario(1);
    sc["drives"] = json!([]);
    sc["randomise"] = json!({});
    let mut p = Phys::new();
    let info = ok(call(&mut p, "world_new", &json!({"assembly": assembly(), "scenario": sc})));
    let mass: f64 = info["mass_kg"].as_array().unwrap().iter().skip(1).filter_map(Value::as_f64).sum::<f64>() - info["mass_kg"][info["links"].as_array().unwrap().iter().position(|l| l == "cube").unwrap()].as_f64().unwrap();
    ok(call(&mut p, "world_step", &json!({"seconds": 1.0})));
    let w = ok(call(&mut p, "wrench_history", &json!({"body": "base", "source": "joint:base", "pick": "at", "t": 0.99})));
    let f = &w[0]["force"][0];
    let fz = f[2].as_f64().unwrap();
    let rel = (fz / (mass * 9.81) - 1.0).abs();
    println!("PH7 arm at rest 1 s: base joint force {:.4} {:.4} {fz:.4} N vs weight {:.4} N ({:.3} kg), {:.3} %", f[0].as_f64().unwrap(), f[1].as_f64().unwrap(), mass * 9.81, mass, rel * 100.0);
    assert!(rel < 0.01);
}

#[test]
fn same_seed_same_run() {
    let run = |seed: u64| {
        let mut p = Phys::new();
        ok(call(&mut p, "world_new", &json!({"assembly": assembly(), "scenario": scenario(seed)})));
        ok(call(&mut p, "world_step", &json!({"seconds": 2.0})));
        ok(call(&mut p, "world_state", &json!({})))["q"].clone()
    };
    let (a, b, c) = (run(7), run(7), run(8));
    assert_eq!(a, b);
    assert_ne!(a, c);
    println!("PH7 scenario seed 7 twice: identical q; seed 8 differs");
}

#[test]
fn drone_through_the_facade() {
    let mut p = Phys::new();
    ok(call(&mut p, "world_new", &json!({"drone": {}, "state": {"p": [0.0, 0.0, 1.0], "q": [1.0, 0.0, 0.0, 0.0], "v": [0.0, 0.0, 0.0], "w": [0.0, 0.0, 0.0], "omega": [0.0, 0.0, 0.0, 0.0]}})));
    // Hover speed: m g = 4 k_t w^2.
    let k_t = 0.18 * 9.81 / 4000.0f64.powi(2);
    let w = (0.175 * 9.81 / (4.0 * k_t)).sqrt();
    ok(call(&mut p, "set_controls", &json!({"rotors": [w, w, w, w]})));
    ok(call(&mut p, "world_step", &json!({"seconds": 0.5})));
    let st = ok(call(&mut p, "world_state", &json!({})));
    println!("PH7 drone open-loop hover 0.5 s: z {:.4} m, pack {:.2} V, winding {:.2} C", st["drone"]["p"][2].as_f64().unwrap(), st["power"]["voltage"].as_f64().unwrap(), st["power"]["motor_winding_c"][0].as_f64().unwrap());
    assert!(st["power"]["voltage"].as_f64().unwrap() > 11.0);
}
