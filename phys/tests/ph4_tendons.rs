//! PH4: tendons and couplings on kin's definitions. A linkage keeps its ratio under load, a
//! fixed tendon and a routed tendon reach the statics equilibrium, the routed path length and
//! moment arms equal kin's, slack and the tension limit hold, and cables only pull.
//! `cargo test --release -p viaform-phys --test ph4_tendons -- --nocapture` prints the numbers.

use viaform_kin::math::{Rng, pose_xyz_rpy};
use viaform_kin::model::{Actuator, Coupling, CouplingKind, Drive, Inertial, Joint, JointKind, Limits, Link, TendonPoint};
use viaform_kin::{Model, Vec3};
use viaform_phys::actuator::{ActuatorKind, ServoParams};
use viaform_phys::dynamics::{Ws, kinematics};
use viaform_phys::world::ExtForce;
use viaform_phys::{ModelBuilder, Settings, World};

fn body(name: &str) -> Link {
    Link { name: name.into(), inertial: Some(Inertial { mass: 0.02, com: Vec3::new(0.0, 0.0, 0.02), inertia: [4e-6, 4e-6, 1e-6, 0.0, 0.0, 0.0] }) }
}

/// Two phalanges flexing about x, 50 mm apart, with one coupling.
fn finger(drive: Drive, kind: CouplingKind, matrix: Vec<f64>, effort: f64) -> Model {
    let j = |name: &str, parent: usize, z: f64| Joint { name: name.into(), kind: JointKind::Revolute, parent, origin: pose_xyz_rpy([0.0, 0.0, z], [0.0; 3]), axis: Vec3::x(), limits: Limits::default() };
    let mut m = Model {
        name: "finger".into(),
        links: vec![Link { name: "palm".into(), inertial: None }, body("p1"), body("p2")],
        joints: vec![j("mcp", 0, 0.0), j("pip", 1, 0.05)],
        actuators: vec![Actuator { name: "a".into(), drive, limits: Limits { effort, ..Limits::default() } }],
        couplings: vec![Coupling { name: "c".into(), kind, actuators: vec![0], joints: vec![0, 1], matrix, offset: vec![] }],
        end_effectors: vec![],
    };
    m.normalize().unwrap();
    m
}

fn routing() -> Vec<TendonPoint> {
    vec![
        TendonPoint { link: 0, pos: Vec3::new(0.0, -0.008, -0.01) },
        TendonPoint { link: 1, pos: Vec3::new(0.0, -0.008, 0.01) },
        TendonPoint { link: 1, pos: Vec3::new(0.0, -0.006, 0.04) },
        TendonPoint { link: 2, pos: Vec3::new(0.0, -0.006, 0.01) },
    ]
}

/// No gravity, a constant torque about x on the distal phalanx (it loads both joints).
fn settings() -> Settings {
    Settings { gravity: [0.0; 3], ..Settings::default() }
}

fn load(w: &mut World, torque: f64) {
    w.ext = vec![ExtForce { link: 2, force: [0.0; 3], point: [0.0; 3], torque: [torque, 0.0, 0.0], until: f64::INFINITY }];
}

#[test]
fn linkage_keeps_its_ratio_under_load() {
    // A motor drives the proximal joint; the distal one follows at 0.6 through a linkage.
    let kin = finger(Drive::Motor, CouplingKind::Linear, vec![1.0, 0.6], f64::INFINITY);
    let mut b = ModelBuilder::new(kin);
    b.actuator(0, ActuatorKind::Servo(ServoParams { backlash: 0.0, deadband: 0.0, encoder_counts: 0.0, ..ServoParams::default() }));
    let mut w = World::new(b.build().unwrap(), settings());
    let mut worst = 0.0f64;
    for (target, torque) in [(0.5, 0.0), (0.5, -0.3), (1.0, 0.4), (-0.4, -0.5)] {
        w.set_control(0, target);
        load(&mut w, torque);
        w.run(1500).unwrap();
        let ratio = w.q[1] / w.q[0];
        let err = (ratio / 0.6 - 1.0).abs();
        worst = worst.max(err);
        println!("PH4 linkage, target {target} rad, load {torque} N m on the distal link: q {:.4} {:.4}, ratio {ratio:.5} (0.6, {:.4} %)", w.q[0], w.q[1], err * 100.0);
    }
    assert!(worst < 0.01, "ratio within 1 % under load");
}

#[test]
fn fixed_tendon_statics() {
    // q = m a with m = (0.6, 0.4) / 0.52 rad/m... moment arms r = m / |m|^2 = (0.006, 0.004)
    // m after normalising a 10 mm and 6.7 mm pulley pair. Return springs k on both joints.
    let r = [0.010, 0.0067];
    let s: f64 = r.iter().map(|x| x * x).sum();
    let matrix: Vec<f64> = r.iter().map(|x| x / s).collect();
    let kin = finger(Drive::Tendon, CouplingKind::Linear, matrix.clone(), f64::INFINITY);
    let mut b = ModelBuilder::new(kin);
    let k = 0.05;
    for j in 0..2 {
        b.joint_params(j).stiffness = k;
        b.joint_params(j).damping = 0.002;
    }
    let model = b.build().unwrap();
    let kc = model.tendons[0].stiffness;
    let mut w = World::new(model, settings());
    let mut worst = 0.0f64;
    for (a, tau) in [(0.002, 0.0), (0.004, 0.0), (0.004, 0.005), (0.006, -0.004)] {
        w.set_control(0, a);
        load(&mut w, tau);
        w.run(3000).unwrap();
        // Statics: k q_j = r_j T + tau, sum r_j q_j = a - T / kc.
        let t = (a - r.iter().map(|x| x * tau / k).sum::<f64>()) / (s / k + 1.0 / kc);
        let q: Vec<f64> = r.iter().map(|x| (x * t + tau) / k).collect();
        let err = (0..2).map(|j| (w.q[j] - q[j]).abs() / q[j].abs()).fold(0.0, f64::max);
        let terr = (w.act[0].effort - t).abs() / t;
        worst = worst.max(err).max(terr);
        println!(
            "PH4 fixed tendon a {:.0} mm, load {tau} N m: q {:.5} {:.5} vs statics {:.5} {:.5}, tension {:.4} vs {t:.4} N, worst {:.4} %",
            a * 1e3,
            w.q[0],
            w.q[1],
            q[0],
            q[1],
            w.act[0].effort,
            err.max(terr) * 100.0
        );
        if tau == 0.0 {
            // Unloaded and stiff cable: the joints share the excursion on kin's matrix.
            let ratio = w.q[1] / w.q[0];
            assert!((ratio / (matrix[1] / matrix[0]) - 1.0).abs() < 0.01);
        }
    }
    assert!(worst < 0.01, "statics within 1 %");
}

#[test]
fn routed_tendon_matches_kin_and_statics() {
    let kin = finger(Drive::Tendon, CouplingKind::Tendon { routing: routing(), stiffness: 1e4, slack: 0.0 }, vec![], 20.0);
    // Path length and moment arms against kin's definitions at random configurations.
    let model = ModelBuilder::new(kin.clone()).build().unwrap();
    let mut ws = Ws::new(&model);
    let mut arms = vec![0.0; 2];
    let mut rng = Rng::new(5);
    let mut worst_l = 0.0f64;
    let mut worst_r = 0.0f64;
    let l0 = kin.tendon_length(&kin.neutral(), 0).unwrap();
    for _ in 0..50 {
        let q = vec![rng.range(-0.5, 1.5), rng.range(-0.5, 1.5)];
        kinematics(&model, &q, &mut ws);
        let e = viaform_phys::tendon::geometry(&model, &model.tendons[0], &q, &ws, &mut arms);
        worst_l = worst_l.max((e - (l0 - kin.tendon_length(&q, 0).unwrap())).abs());
        let rk = kin.tendon_moment_arms(&q, 0).unwrap();
        worst_r = worst_r.max((0..2).map(|j| (arms[j] - rk[j]).abs()).fold(0.0, f64::max));
    }
    println!("PH4 routed tendon vs kin over 50 configurations: path length {worst_l:.2e} m, moment arms {worst_r:.2e} m");
    assert!(worst_l < 1e-12 && worst_r < 1e-12);

    // Statics with return springs: k q_j = r_j(q) T at rest, T = kc (a - (L0 - L(q))).
    let k = 0.05;
    let mut b = ModelBuilder::new(kin.clone());
    for j in 0..2 {
        b.joint_params(j).stiffness = k;
        b.joint_params(j).damping = 0.002;
    }
    let mut w = World::new(b.build().unwrap(), settings());
    let mut worst = 0.0f64;
    for a in [0.002, 0.005, 0.008] {
        w.set_control(0, a);
        w.run(3000).unwrap();
        let q = w.q.clone();
        let rk = kin.tendon_moment_arms(&q, 0).unwrap();
        let t = 1e4 * (a - (l0 - kin.tendon_length(&q, 0).unwrap()));
        let res = (0..2).map(|j| (k * q[j] - rk[j] * t).abs() / (k * q[j]).abs()).fold(0.0, f64::max);
        let terr = (w.act[0].effort - t).abs() / t;
        worst = worst.max(res).max(terr);
        println!("PH4 routed tendon a {:.0} mm: q {:.4} {:.4}, tension {:.4} N, spring/tendon torque residual {:.4} %, tension error {:.4} %", a * 1e3, q[0], q[1], w.act[0].effort, res * 100.0, terr * 100.0);
    }
    assert!(worst < 0.01);
    // Kin's matrix is the small-excursion, stiff-cable limit of the same finger.
    let m = &kin.couplings[0].matrix;
    w.set_control(0, 2e-4);
    w.run(3000).unwrap();
    let ratio = w.q[1] / w.q[0];
    println!("PH4 routed tendon at 0.2 mm: q1/q0 {ratio:.4} vs kin matrix {:.4}", m[1] / m[0]);
    assert!((ratio / (m[1] / m[0]) - 1.0).abs() < 0.01);
}

#[test]
fn slack_limit_and_pull_only() {
    let kin = finger(Drive::Tendon, CouplingKind::Tendon { routing: routing(), stiffness: 1e4, slack: 0.002 }, vec![], 1.5);
    let mut b = ModelBuilder::new(kin);
    for j in 0..2 {
        b.joint_params(j).stiffness = 0.05;
        b.joint_params(j).damping = 0.002;
    }
    let mut w = World::new(b.build().unwrap(), settings());
    // Inside the slack nothing moves.
    w.set_control(0, 0.0015);
    w.run(1000).unwrap();
    println!("PH4 slack 2 mm, pull 1.5 mm: tension {:.2e} N, q {:.2e} {:.2e}", w.act[0].effort, w.q[0], w.q[1]);
    assert!(w.act[0].effort.abs() < 1e-12 && w.q[0].abs() < 1e-5);
    // Past the limit the tension saturates at 1.5 N.
    w.set_control(0, 0.03);
    w.run(2000).unwrap();
    println!("PH4 tension limit 1.5 N, pull 30 mm: tension {:.4} N", w.act[0].effort);
    assert!(w.act[0].effort <= 1.5 + 1e-9 && w.act[0].effort > 1.4);
    // Pushing does nothing: the cable goes slack.
    w.set_control(0, -0.01);
    w.run(3000).unwrap();
    println!("PH4 push -10 mm: tension {:.2e} N, q {:.2e} {:.2e}", w.act[0].effort, w.q[0], w.q[1]);
    assert!(w.act[0].effort.abs() < 1e-12);
    assert!(w.q[0].abs() < 1e-3 && w.q[1].abs() < 1e-3);
}
