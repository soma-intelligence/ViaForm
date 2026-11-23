//! Cross-validation of phys against MuJoCo on one model: the double pendulum swinging free,
//! the sample arm holding its pose (the base joint carries the arm's weight), a box on a 30 deg
//! incline (Coulomb sliding) and at 20 deg (sticking), the sample arm pick scenario
//! (trajectories, servo torques, base wrench), and the throughput of both engines.
//! `cargo test --release -p viaform-mujoco --features mujoco --test cross -- --nocapture --test-threads 1`

#![cfg(feature = "mujoco")]

use std::time::Instant;

use serde_json::{Value, json};
use viaform_kin::math::pose_xyz_rpy;
use viaform_kin::model::{Inertial, Joint, JointKind, Limits, Link};
use viaform_kin::{Iso3, Model, Vec3};
use viaform_mujoco::MjPhys;
use viaform_mujoco::world::MjWorld;
use viaform_phys::world::Integrator;
use viaform_phys::{ModelBuilder, Phys, Settings, ShapeSpec, World};

fn assembly() -> Value {
    serde_json::from_str(include_str!("../../docs/samples/arm/assembly.json")).unwrap()
}

fn ok(v: Value) -> Value {
    assert!(v.get("ok").is_some(), "facade error: {v}");
    v["ok"].clone()
}

// MARK: Double pendulum

fn pendulum() -> Model {
    let rod = |m: f64, l: f64| Inertial { mass: m, com: Vec3::new(0.0, 0.0, -l / 2.0), inertia: [m * l * l / 12.0, m * l * l / 12.0, 1e-5, 0.0, 0.0, 0.0] };
    let mut kin = Model {
        name: "double_pendulum".into(),
        links: vec![Link { name: "world".into(), inertial: None }, Link { name: "upper".into(), inertial: Some(rod(1.0, 0.5)) }, Link { name: "lower".into(), inertial: Some(rod(0.7, 0.4)) }],
        joints: vec![
            Joint { name: "j1".into(), kind: JointKind::Revolute, parent: 0, origin: pose_xyz_rpy([0.0, 0.0, 2.0], [0.0; 3]), axis: Vec3::y(), limits: Limits::default() },
            Joint { name: "j2".into(), kind: JointKind::Revolute, parent: 1, origin: pose_xyz_rpy([0.0, 0.0, -0.5], [0.0; 3]), axis: Vec3::y(), limits: Limits::default() },
        ],
        actuators: vec![],
        couplings: vec![],
        end_effectors: vec![],
    };
    kin.normalize().unwrap();
    kin
}

/// Max joint angle gap over `seconds` of free swing from (1.2, -0.6) rad.
fn pendulum_gap(integrator: Integrator, dt: f64, seconds: f64) -> (f64, f64, f64) {
    let s = Settings { dt, integrator, ..Settings::default() };
    let mut w = World::new(ModelBuilder::new(pendulum()).build().unwrap(), s);
    w.set_q(&[1.2, -0.6]).unwrap();
    let mut mj = MjWorld::from_phys(&w).unwrap();
    let steps = (seconds / dt).round() as usize;
    let (mut gap, mut e0, mut e1) = (0.0f64, 0.0, 0.0);
    for k in 0..steps {
        w.step().unwrap();
        mj.step().unwrap();
        let q = mj.q();
        gap = gap.max((w.q[0] - q[0]).abs()).max((w.q[1] - q[1]).abs());
        if k == 0 {
            e0 = w.energy();
        }
        e1 = w.energy();
    }
    (gap, e0, e1)
}

#[test]
fn double_pendulum_free_swing() {
    let (g_rk4, ..) = pendulum_gap(Integrator::Rk4, 1e-4, 2.0);
    let (g_si, ..) = pendulum_gap(Integrator::SemiImplicit, 1e-3, 2.0);
    println!("X1 double pendulum 2 s from (1.2, -0.6) rad: RK4 dt 1e-4 max angle gap phys vs MuJoCo {g_rk4:.3e} rad; default (phys semi-implicit, MuJoCo implicitfast) dt 1e-3 {g_si:.3e} rad");
    assert!(g_rk4 < 1e-6, "{g_rk4}");
    assert!(g_si < 0.05, "{g_si}");
}

// MARK: Arm under gravity

fn scenario(drives: Value, randomise: Value, every: u64) -> Value {
    json!({
        "format": "viaform-scenario", "version": 1, "id": "pick", "seed": 4,
        "world": {"table": {"size_m": [0.8, 0.6], "height_m": 0.05},
                  "objects": [{"id": "cube", "shape": "box", "size_m": 0.03, "mass_kg": 0.02, "pose": "random_in:[0.15,0.3]x[-0.1,0.1]"}]},
        "initial": {"pose": "home"},
        "drives": drives,
        "randomise": randomise,
        "record": {"every": every},
        "duration_s": 2.0, "rate_hz": 1000, "control_hz": 50
    })
}

fn pick_drives() -> Value {
    json!([{"joint": "shoulder_lift", "timeline": [[0.0, 0.0], [0.5, 30.0], [1.2, -20.0]]}, {"joint": "elbow", "target": 20.0}])
}

fn both(sc: &Value) -> (Phys, MjPhys, Value) {
    let p = json!({"assembly": assembly(), "scenario": sc});
    let mut ph = Phys::new();
    let info = ok(viaform_phys::call(&mut ph, "world_new", &p));
    let mut mj = MjPhys::new();
    let mut pm = p.clone();
    pm["engine"] = json!("mujoco");
    let info_mj = ok(viaform_mujoco::call(&mut mj, "world_new", &pm));
    assert_eq!(info["links"], info_mj["links"]);
    (ph, mj, info)
}

#[test]
fn arm_holds_its_pose_under_gravity() {
    let (mut ph, mut mj, info) = both(&scenario(json!([]), json!({}), 1));
    let links = info["links"].as_array().unwrap();
    let cube = links.iter().position(|l| l == "cube").unwrap();
    let mass: f64 = info["mass_kg"].as_array().unwrap().iter().skip(1).filter_map(Value::as_f64).sum::<f64>() - info["mass_kg"][cube].as_f64().unwrap();
    let weight = mass * 9.81;
    let mut fz = [0.0; 2];
    let mut ty = [0.0; 2];
    let mut eff = [vec![], vec![]];
    // phys
    ok(viaform_phys::call(&mut ph, "world_step", &json!({"seconds": 1.0})));
    let w = ok(viaform_phys::call(&mut ph, "wrench_history", &json!({"body": "upper_arm", "source": "joint:shoulder_lift", "pick": "at", "t": 0.99})));
    ty[0] = w[0]["torque"][0][1].as_f64().unwrap();
    let w = ok(viaform_phys::call(&mut ph, "wrench_history", &json!({"body": "base", "source": "joint:base", "pick": "at", "t": 0.99})));
    fz[0] = w[0]["force"][0][2].as_f64().unwrap();
    eff[0] = ok(viaform_phys::call(&mut ph, "world_state", &json!({})))["efforts"].as_array().unwrap().iter().map(|x| x.as_f64().unwrap()).collect();
    // MuJoCo
    ok(viaform_mujoco::call(&mut mj, "world_step", &json!({"seconds": 1.0})));
    let w = ok(viaform_mujoco::call(&mut mj, "wrench_history", &json!({"body": "upper_arm", "source": "joint:shoulder_lift", "pick": "at", "t": 0.99})));
    ty[1] = w[0]["torque"][0][1].as_f64().unwrap();
    let w = ok(viaform_mujoco::call(&mut mj, "wrench_history", &json!({"body": "base", "source": "joint:base", "pick": "at", "t": 0.99})));
    fz[1] = w[0]["force"][0][2].as_f64().unwrap();
    eff[1] = ok(viaform_mujoco::call(&mut mj, "world_state", &json!({})))["efforts"].as_array().unwrap().iter().map(|x| x.as_f64().unwrap()).collect();
    let rel = |x: f64| (x / weight - 1.0).abs() * 100.0;
    println!("X2 arm at rest 1 s: base joint force z phys {:.4} N ({:.3} %), MuJoCo {:.4} N ({:.3} %), weight {weight:.4} N", fz[0], rel(fz[0]), fz[1], rel(fz[1]));
    println!("X2 shoulder_lift joint torque y phys {:.5} N m, MuJoCo {:.5} N m; servo efforts phys {:?} MuJoCo {:?}", ty[0], ty[1], eff[0].iter().map(|x| format!("{x:.4}")).collect::<Vec<_>>(), eff[1].iter().map(|x| format!("{x:.4}")).collect::<Vec<_>>());
    assert!(rel(fz[1]) < 1.0);
    assert!((fz[0] - fz[1]).abs() / weight < 0.01);
}

// MARK: Incline

/// Box on a plane tilted `deg`, per engine: acceleration down the slope from 0.5 s to 2 s and
/// from 0.5 s to 10 s (phys's PH2 window), and the slip from 0.5 s to 10 s.
fn incline(deg: f64, mu: f64) -> [(f64, f64, f64); 2] {
    let th = deg.to_radians();
    let mut b = ModelBuilder::empty();
    b.geom(0, "slope", ShapeSpec::Plane { normal: [-th.sin(), 0.0, th.cos()] }, Iso3::identity(), mu);
    let n = Vec3::new(-th.sin(), 0.0, th.cos());
    let rot = pose_xyz_rpy([0.0; 3], [0.0, -th, 0.0]).rotation;
    let link = b.free_shape("box", ShapeSpec::Box { size: [0.1, 0.1, 0.1] }, 1.0, Iso3::from_parts((n * 0.05).into(), rot), mu).unwrap();
    let mut w = World::new(b.build().unwrap(), Settings::default());
    let mut mj = MjWorld::from_phys(&w).unwrap();
    let down = Vec3::new(-th.cos(), 0.0, -th.sin());
    let measure = |pose: Iso3, v: &[f64]| (pose.translation.vector, (pose.rotation * Vec3::new(v[0], v[1], v[2])).dot(&down));
    let mut out = [(0.0, 0.0, 0.0); 2];
    // phys
    w.run(500).unwrap();
    let (p1, v1) = measure(w.poses()[link], &w.v);
    w.run(1500).unwrap();
    let (_, vm) = measure(w.poses()[link], &w.v);
    w.run(8000).unwrap();
    let (p2, v2) = measure(w.poses()[link], &w.v);
    out[0] = ((vm - v1) / 1.5, (v2 - v1) / 9.5, (p2 - p1).norm());
    // MuJoCo
    let pose = |mj: &mut MjWorld| {
        let mut buf = vec![0.0; 14];
        mj.poses_flat(&mut buf);
        viaform_kin::math::pose_from7(&buf[7..14].try_into().unwrap())
    };
    mj.run(500).unwrap();
    let (p1, v1) = measure(pose(&mut mj), &mj.v());
    mj.run(1500).unwrap();
    let (_, vm) = measure(pose(&mut mj), &mj.v());
    mj.run(8000).unwrap();
    let (p2, v2) = measure(pose(&mut mj), &mj.v());
    out[1] = ((vm - v1) / 1.5, (v2 - v1) / 9.5, (p2 - p1).norm());
    out
}

#[test]
fn box_on_an_incline() {
    let mu = 0.5;
    let th = 30f64.to_radians();
    let coulomb = 9.81 * (th.sin() - mu * th.cos());
    let [ph, mj] = incline(30.0, mu);
    let pct = |a: f64| (a / coulomb - 1.0) * 100.0;
    println!("X3 incline 30 deg mu 0.5, Coulomb {coulomb:.5} m/s^2: 0.5 to 2 s phys {:.5} ({:+.2} %), MuJoCo {:.5} ({:+.2} %); 0.5 to 10 s phys {:.5} ({:+.2} %), MuJoCo {:.5} ({:+.2} %)", ph.0, pct(ph.0), mj.0, pct(mj.0), ph.1, pct(ph.1), mj.1, pct(mj.1));
    let [ph20, mj20] = incline(20.0, mu);
    println!("X3 incline 20 deg mu 0.5 (sticks): slip over 9.5 s phys {:.3e} m, MuJoCo {:.3e} m", ph20.2, mj20.2);
    assert!(pct(ph.1).abs() < 1.0);
    assert!(pct(mj.0).abs() < 15.0, "{}", mj.0);
    assert!(mj20.2 < 0.02, "{}", mj20.2);
}

// MARK: Sample arm scenario

#[test]
fn sample_arm_scenario_trajectories() {
    let (mut ph, mut mj, info) = both(&scenario(pick_drives(), json!({}), 10));
    let joints: Vec<String> = info["actuators"].as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect();
    let na = joints.len();
    let (mut gap, mut sq, mut n) = (vec![0.0f64; na], vec![0.0f64; na], 0usize);
    let (mut egap, mut epeak) = (vec![0.0f64; na], vec![0.0f64; na]);
    for _ in 0..200 {
        let a = ok(viaform_phys::call(&mut ph, "world_step", &json!({"steps": 10})));
        ok(viaform_mujoco::call(&mut mj, "world_step", &json!({"steps": 10})));
        let (sp, sm) = (ok(viaform_phys::call(&mut ph, "world_state", &json!({}))), ok(viaform_mujoco::call(&mut mj, "world_state", &json!({}))));
        for j in 0..na {
            let d = sp["q"][j].as_f64().unwrap() - sm["q"][j].as_f64().unwrap();
            gap[j] = gap[j].max(d.abs());
            sq[j] += d * d;
            let (ep, em) = (sp["efforts"][j].as_f64().unwrap(), sm["efforts"][j].as_f64().unwrap());
            egap[j] = egap[j].max((ep - em).abs());
            epeak[j] = epeak[j].max(ep.abs());
        }
        n += 1;
        let _ = a;
    }
    for j in 0..na {
        println!("X4 sample arm pick 2 s, {}: max q gap {:.4} deg, RMS {:.4} deg; max servo torque gap {:.4} N m (phys peak {:.4} N m)", joints[j], gap[j].to_degrees(), (sq[j] / n as f64).sqrt().to_degrees(), egap[j], epeak[j]);
    }
    // Base wrench (G3 input) over the run.
    let src = json!({"body": "base", "source": "joint:base"});
    let (hp, hm) = (ok(viaform_phys::call(&mut ph, "wrench_history", &src)), ok(viaform_mujoco::call(&mut mj, "wrench_history", &src)));
    let (tp, tm) = (hp[0]["t"].as_array().unwrap().len(), hm[0]["t"].as_array().unwrap().len());
    let k = tp.min(tm);
    // The first sample differs by design: phys's servos first cross their 0.3 deg backlash
    // (no torque for a few steps), MuJoCo has no backlash. Gaps are given with and without it.
    let (mut fg, mut tg, mut fpk, mut tpk) = ([0.0f64; 2], [0.0f64; 2], 0.0f64, 0.0f64);
    for i in 0..k {
        for c in 0..3 {
            let df = (hp[0]["force"][i][c].as_f64().unwrap() - hm[0]["force"][i][c].as_f64().unwrap()).abs();
            let dt = (hp[0]["torque"][i][c].as_f64().unwrap() - hm[0]["torque"][i][c].as_f64().unwrap()).abs();
            fg[0] = fg[0].max(df);
            tg[0] = tg[0].max(dt);
            if i > 0 {
                fg[1] = fg[1].max(df);
                tg[1] = tg[1].max(dt);
            }
            fpk = fpk.max(hp[0]["force"][i][c].as_f64().unwrap().abs());
            tpk = tpk.max(hp[0]["torque"][i][c].as_f64().unwrap().abs());
        }
    }
    println!("X4 base joint wrench history ({k} samples each, every 10 ms): max force gap {:.4} N, {:.4} N after the first sample (phys peak {fpk:.4} N); max torque gap {:.4} N m, {:.4} N m after the first sample (phys peak {tpk:.4} N m)", fg[0], fg[1], tg[0], tg[1]);
    // G3: the loads module reads the MuJoCo record unchanged.
    assert!(viaform_generative_free_check(&hm));
    let g3 = viaform_generative::solid::sim_loads::from_record(&hm, "base", "joint:base").expect("sim_loads reads the MuJoCo record");
    assert_eq!(g3.t.len(), tm);
    assert_eq!(tp, tm);
    assert!(gap.iter().all(|g| g.to_degrees() < 3.0), "{gap:?}");
}

/// The MuJoCo answer parses as phys's `WrenchHistory` (the shape G3's `sim_loads` reads).
fn viaform_generative_free_check(v: &Value) -> bool {
    serde_json::from_value::<Vec<viaform_phys::WrenchHistory>>(v.clone()).is_ok_and(|h| !h.is_empty() && h[0].t.len() == h[0].accel.len())
}

// MARK: Throughput

#[test]
fn throughput_sample_arm() {
    let sc = scenario(pick_drives(), json!({}), 1_000_000);
    let (mut ph, mut mj, _) = both(&sc);
    let steps = 2000;
    let t0 = Instant::now();
    ok(viaform_phys::call(&mut ph, "world_step", &json!({"steps": steps})));
    let r_ph = steps as f64 / t0.elapsed().as_secs_f64();
    let t0 = Instant::now();
    ok(viaform_mujoco::call(&mut mj, "world_step", &json!({"steps": steps})));
    let r_mj = steps as f64 / t0.elapsed().as_secs_f64();
    println!("X5 sample arm pick scenario (6 servos, table, cube, 26 pairs), one world, one thread: phys {:.0} steps/s, MuJoCo {:.0} steps/s", r_ph, r_mj);
    // Batch of 64 on rayon.
    ok(viaform_phys::call(&mut ph, "batch_new", &json!({"n": 64})));
    ok(viaform_mujoco::call(&mut mj, "batch_new", &json!({"n": 64})));
    let t0 = Instant::now();
    ok(viaform_phys::call(&mut ph, "batch_step", &json!({"steps": 500})));
    let b_ph = 64.0 * 500.0 / t0.elapsed().as_secs_f64();
    let t0 = Instant::now();
    ok(viaform_mujoco::call(&mut mj, "batch_step", &json!({"steps": 500})));
    let b_mj = 64.0 * 500.0 / t0.elapsed().as_secs_f64();
    println!("X5 batch of 64 sample arms on rayon: phys {:.0} env steps/s, MuJoCo {:.0} env steps/s", b_ph, b_mj);
}

#[test]
fn exported_sample_scene_compiles() {
    let xml = include_str!("../../docs/samples/arm/arm-scene.mjcf.xml");
    let mut s = viaform_mujoco::sim::Sim::from_xml(xml).expect("the sample scene compiles in MuJoCo");
    for _ in 0..100 {
        s.step();
    }
    println!("X6 docs/samples/arm/arm-scene.mjcf.xml compiles in MuJoCo {}: nq {}, nu {}, nbody {}", viaform_mujoco::sim::version(), s.n.nq, s.n.nu, s.n.nbody);
}
