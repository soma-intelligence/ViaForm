//! PH2: contacts (RUST-ENGINES 6.4): box resting, stack of 5, incline against Coulomb friction,
//! two-finger grasp under shake, determinism, PGS fallback.
//! `cargo test --release -p viaform-phys --test ph2_contacts -- --nocapture` prints the numbers.

use std::time::Instant;

use viaform_kin::math::{pose_xyz_rpy, pose_from7};
use viaform_kin::model::{Inertial, Joint, JointKind, Limits, Link};
use viaform_kin::{Iso3, Model, Vec3};
use viaform_phys::actuator::{ActuatorKind, ServoParams};
use viaform_phys::solver::SolverKind;
use viaform_phys::{ModelBuilder, Settings, ShapeSpec, World};

fn pos(w: &mut World, link: usize) -> Vec3 {
    w.poses()[link].translation.vector
}

fn box_on_plane(solver: SolverKind) -> (f64, f64, f64) {
    let mut b = ModelBuilder::empty();
    b.ground(0.8);
    let link = b.free_shape("box", ShapeSpec::Box { size: [0.1, 0.1, 0.1] }, 1.0, pose_xyz_rpy([0.0, 0.0, 0.05], [0.0; 3]), 0.8).unwrap();
    let model = b.build().unwrap();
    let mut s = Settings::default();
    s.solver.kind = solver;
    let mut w = World::new(model, s);
    w.run(1000).unwrap();
    let p1 = pos(&mut w, link);
    let mut iters = 0;
    for _ in 0..9000 {
        w.step().unwrap();
        iters += w.stats.iterations;
    }
    let p2 = pos(&mut w, link);
    ((p2 - p1).norm(), 0.05 - p2.z, iters as f64 / 9000.0)
}

#[test]
fn box_rests_without_drift() {
    for kind in [SolverKind::Newton, SolverKind::Pgs] {
        let (drift, pen, it) = box_on_plane(kind);
        println!("PH2 box on plane ({kind:?}): drift 1 s to 10 s {:.3e} m, penetration {:.2e} m, {it:.1} iterations per step", drift, pen);
        assert!(drift < 1e-4, "{drift}");
        assert!(pen.abs() < 1e-4);
    }
}

#[test]
fn stack_of_five_boxes() {
    let mut b = ModelBuilder::empty();
    b.ground(0.8);
    let h = 0.1;
    let mut links = vec![];
    for k in 0..5 {
        // Slight offsets so the stack is not perfectly symmetric.
        let dx = if k % 2 == 0 { 0.003 } else { -0.002 };
        links.push(b.free_shape(&format!("box{k}"), ShapeSpec::Box { size: [h, h, h] }, 0.5, pose_xyz_rpy([dx, 0.0, h * (k as f64 + 0.5)], [0.0; 3]), 0.8).unwrap());
    }
    let model = b.build().unwrap();
    let mut w = World::new(model, Settings::default());
    let t0 = Instant::now();
    w.run(1000).unwrap();
    let p1: Vec<Vec3> = links.iter().map(|&l| pos(&mut w, l)).collect();
    let mut vmax = 0.0f64;
    for k in 0..9000 {
        w.step().unwrap();
        if k > 8000 {
            vmax = vmax.max(w.v.iter().fold(0.0f64, |a, x| a.max(x.abs())));
        }
    }
    let el = t0.elapsed().as_secs_f64();
    let p2: Vec<Vec3> = links.iter().map(|&l| pos(&mut w, l)).collect();
    let drift = p1.iter().zip(&p2).map(|(a, b)| (a - b).norm()).fold(0.0f64, f64::max);
    println!("PH2 stack of 5: worst box drift 1 s to 10 s {drift:.3e} m, top box z {:.5} m, last second max |v| {vmax:.2e}, {:.1} us per step ({} contacts)", p2[4].z, el * 1e6 / 10000.0, w.contacts.len());
    assert!(drift < 1e-4, "{drift}");
    assert!((p2[4].z - 0.45).abs() < 1e-3);
}

fn incline(deg: f64, mu: f64) -> (f64, f64, f64) {
    let th = deg.to_radians();
    let mut b = ModelBuilder::empty();
    // Plane through the origin tilted about y: normal (sin th, 0, cos th)... the box slides
    // toward -x' (down the slope).
    b.geom(0, "slope", ShapeSpec::Plane { normal: [-th.sin(), 0.0, th.cos()] }, Iso3::identity(), mu);
    let n = Vec3::new(-th.sin(), 0.0, th.cos());
    let start = n * 0.05;
    let rot = pose_xyz_rpy([0.0; 3], [0.0, -th, 0.0]).rotation;
    let link = b.free_shape("box", ShapeSpec::Box { size: [0.1, 0.1, 0.1] }, 1.0, Iso3::from_parts(start.into(), rot), mu).unwrap();
    let model = b.build().unwrap();
    let mut w = World::new(model, Settings::default());
    // Downhill direction.
    let down = Vec3::new(-th.cos(), 0.0, -th.sin());
    w.run(500).unwrap();
    let (p1, t1) = (pos(&mut w, link), w.t);
    let v1 = {
        let p = w.poses()[link];
        let r = p.rotation;
        (r * Vec3::new(w.v[0], w.v[1], w.v[2])).dot(&down)
    };
    w.run(9500).unwrap();
    let (p2, t2) = (pos(&mut w, link), w.t);
    let v2 = {
        let p = w.poses()[link];
        (p.rotation * Vec3::new(w.v[0], w.v[1], w.v[2])).dot(&down)
    };
    let disp = (p2 - p1).dot(&down);
    let acc = (v2 - v1) / (t2 - t1);
    (disp, acc, (p2 - p1).norm())
}

#[test]
fn incline_matches_coulomb() {
    let mu = 0.5;
    let (disp, _, drift) = incline(20.0, mu);
    println!("PH2 incline 20 deg, mu 0.5 (stick, atan(mu) = 26.6 deg): drift over 9.5 s {drift:.3e} m (target under 1e-4)");
    assert!(drift < 1e-4, "{disp}");
    let (_, acc, _) = incline(30.0, mu);
    let th = 30f64.to_radians();
    let expected = 9.81 * (th.sin() - mu * th.cos());
    println!("PH2 incline 30 deg, mu 0.5 (slide): acceleration {acc:.5} m/s^2, Coulomb {expected:.5} ({:+.3} %, target 1 %)", 100.0 * (acc / expected - 1.0));
    assert!((acc / expected - 1.0).abs() < 0.01);
}

/// Gripper: a palm on a vertical prismatic "lift" joint (servo, shaken), two fingers on
/// prismatic joints squeezing with a constant force, a 30 g cube between them.
fn gripper(squeeze: f64) -> (Model, usize, usize) {
    let body = |name: &str, m: f64, s: [f64; 3]| Link { name: name.into(), inertial: Some(Inertial { mass: m, com: Vec3::zeros(), inertia: [m * (s[1] * s[1] + s[2] * s[2]) / 12.0, m * (s[0] * s[0] + s[2] * s[2]) / 12.0, m * (s[0] * s[0] + s[1] * s[1]) / 12.0, 0.0, 0.0, 0.0] }) };
    let lim = |lo: f64, hi: f64, e: f64| Limits { lower: lo, upper: hi, velocity: f64::INFINITY, effort: e };
    let mut m = Model {
        name: "gripper".into(),
        links: vec![Link { name: "world".into(), inertial: None }, body("palm", 0.3, [0.1, 0.04, 0.02]), body("left", 0.02, [0.01, 0.03, 0.06]), body("right", 0.02, [0.01, 0.03, 0.06])],
        joints: vec![
            Joint { name: "lift".into(), kind: JointKind::Prismatic, parent: 0, origin: pose_xyz_rpy([0.0, 0.0, 0.3], [0.0; 3]), axis: Vec3::z(), limits: lim(-0.2, 0.2, 50.0) },
            Joint { name: "left".into(), kind: JointKind::Prismatic, parent: 1, origin: pose_xyz_rpy([-0.02, 0.0, -0.04], [0.0; 3]), axis: Vec3::x(), limits: lim(-0.03, 0.02, squeeze) },
            Joint { name: "right".into(), kind: JointKind::Prismatic, parent: 1, origin: pose_xyz_rpy([0.02, 0.0, -0.04], [0.0; 3]), axis: -Vec3::x(), limits: lim(-0.03, 0.02, squeeze) },
        ],
        actuators: vec![],
        couplings: vec![],
        end_effectors: vec![],
    };
    m.normalize().unwrap();
    (m, 2, 3)
}

fn grasp_run(shake: bool) -> (f64, f64) {
    let squeeze = 5.0;
    let (kin, l, r) = gripper(squeeze);
    let mut b = ModelBuilder::new(kin);
    b.geom(l, "left_pad", ShapeSpec::Box { size: [0.01, 0.03, 0.06] }, Iso3::identity(), 1.0);
    b.geom(r, "right_pad", ShapeSpec::Box { size: [0.01, 0.03, 0.06] }, Iso3::identity(), 1.0);
    // Cube 3 cm, 30 g, between the pads (pad inner faces at x = -0.015 and 0.015).
    let cube = b.free_shape("cube", ShapeSpec::Box { size: [0.03, 0.03, 0.03] }, 0.03, pose_xyz_rpy([0.0, 0.0, 0.26], [0.0; 3]), 1.0).unwrap();
    b.actuator(0, ActuatorKind::Servo(ServoParams { kp: 4000.0, kd: 80.0, stall_torque: 50.0, max_torque: 50.0, no_load_speed: 1.0, backlash: 0.0, deadband: 0.0, encoder_counts: 0.0, rotor_inertia: 0.0, ..ServoParams::default() }));
    let model = b.build().unwrap();
    let mut w = World::new(model, Settings::default());
    // Fingers start touching the cube: left pad centre at x = -0.02, so q = 0.0; same right.
    w.set_control(1, squeeze);
    w.set_control(2, squeeze);
    w.run(500).unwrap();
    let rel = |w: &mut World| {
        let p = w.poses();
        p[1].inverse() * p[cube]
    };
    let r0 = rel(&mut w);
    let mut worst = 0.0f64;
    for k in 0..5000 {
        if shake {
            // 2 Hz, 1 cm amplitude vertical shake (1.6 m/s^2 peak).
            let t = w.t;
            w.set_control(0, 0.01 * (2.0 * std::f64::consts::PI * 2.0 * t).sin());
        }
        w.step().unwrap();
        if k % 10 == 0 {
            let r1 = rel(&mut w);
            worst = worst.max((r1.translation.vector - r0.translation.vector).norm());
        }
    }
    let z = w.poses()[cube].translation.vector.z;
    (worst, z)
}

#[test]
fn two_finger_grasp_holds_a_cube() {
    let (slip, z) = grasp_run(false);
    println!("PH2 grasp 30 g cube, 5 N squeeze, mu 1, held 5 s: slip {slip:.3e} m (cube z {z:.4})");
    assert!(slip < 1e-4);
    let (slip, _) = grasp_run(true);
    println!("PH2 grasp under a 2 Hz 1 cm shake, 5 s: slip {slip:.3e} m (target under 1e-4)");
    assert!(slip < 1e-4);
}

#[test]
fn deterministic_and_drops_settle() {
    // Boxes dropped in a heap: two runs are bitwise equal.
    let build = || {
        let mut b = ModelBuilder::empty();
        b.ground(0.6);
        for k in 0..6 {
            let x = 0.03 * (k as f64 - 2.5);
            b.free_shape(&format!("b{k}"), ShapeSpec::Box { size: [0.06, 0.05, 0.04] }, 0.2, pose_from7(&[x, 0.01 * k as f64, 0.1 + 0.06 * k as f64, 0.9, 0.1 * k as f64, 0.2, 0.1]), 0.6).unwrap();
        }
        b.free_shape("puck", ShapeSpec::Cylinder { length: 0.02, radius: 0.03 }, 0.1, pose_xyz_rpy([0.0, 0.0, 0.6], [0.0; 3]), 0.6).unwrap();
        // A 12-sided prism: a plane meets it vertex by vertex (parry's polygon features stop at four).
        let prism: Vec<[f64; 3]> = (0..24).map(|i| {
            let a = (i / 2) as f64 * std::f64::consts::TAU / 12.0;
            [0.03 * a.cos(), 0.03 * a.sin(), if i % 2 == 0 { -0.01 } else { 0.01 }]
        }).collect();
        b.free_shape("prism", ShapeSpec::ConvexHull { points: prism }, 0.1, pose_xyz_rpy([-0.1, 0.05, 0.3], [0.2, 0.0, 0.0]), 0.6).unwrap();
        b.free_shape("hull", ShapeSpec::ConvexHull { points: vec![[0.0, 0.0, 0.0], [0.05, 0.0, 0.0], [0.0, 0.05, 0.0], [0.0, 0.0, 0.05], [0.04, 0.04, 0.03]] }, 0.1, pose_xyz_rpy([0.05, 0.0, 0.7], [0.3, 0.2, 0.1]), 0.6).unwrap();
        World::new(b.build().unwrap(), Settings::default())
    };
    let (mut a, mut b) = (build(), build());
    a.run(3000).unwrap();
    b.run(3000).unwrap();
    assert!(a.q.iter().zip(&b.q).all(|(x, y)| x.to_bits() == y.to_bits()));
    let vmax = a.v.iter().fold(0.0f64, |m, x| m.max(x.abs()));
    println!("PH2 heap of 9 bodies after 3 s: bitwise equal runs, max |v| {vmax:.2e}, {} contacts", a.contacts.len());
    assert!(vmax < 0.05);
    // Nothing fell through the ground (the hull's frame sits on a vertex, so allow the
    // contact penetration).
    let poses = a.poses().to_vec();
    let low = poses.iter().skip(1).map(|p| p.translation.vector.z).fold(f64::INFINITY, f64::min);
    println!("PH2 heap: lowest body frame z {low:.3e} m");
    assert!(low > -1e-4);
}
