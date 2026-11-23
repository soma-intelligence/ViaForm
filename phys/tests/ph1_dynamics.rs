//! PH1: ABA, RNEA, CRBA, semi-implicit integration, joint limits and damping.
//! `cargo test --release -p viaform-phys --test ph1_dynamics -- --nocapture` prints the numbers.

use viaform_kin::math::{Rng, pose_xyz_rpy};
use viaform_kin::model::{Inertial, Joint, JointKind, Limits, Link};
use viaform_kin::{Model, Vec3, models};
use viaform_phys::dynamics::{Ws, aba, crba, kinematics, rnea};
use viaform_phys::world::Integrator;
use viaform_phys::{ModelBuilder, Settings, World};

fn link(name: &str, rng: &mut Rng) -> Link {
    let m = rng.range(0.2, 2.0);
    let (a, b, c) = (rng.range(0.01, 0.1), rng.range(0.01, 0.1), rng.range(0.01, 0.1));
    let i = [m * (b * b + c * c) / 12.0, m * (a * a + c * c) / 12.0, m * (a * a + b * b) / 12.0, 0.1 * m * a * b / 12.0, -0.05 * m * a * c / 12.0, 0.02 * m * b * c / 12.0];
    Link { name: name.into(), inertial: Some(Inertial { mass: m, com: Vec3::new(rng.range(-0.05, 0.05), rng.range(-0.05, 0.05), rng.range(-0.05, 0.1)), inertia: i }) }
}

/// A tree with every joint kind: a floating base, revolute and prismatic chains, a spherical
/// joint, a fixed joint, and a branch.
fn tree(seed: u64) -> Model {
    let mut rng = Rng::new(seed);
    let mut links = vec![Link { name: "world".into(), inertial: None }];
    let mut joints = vec![];
    let kinds = [
        (JointKind::Floating, 0),
        (JointKind::Revolute, 1),
        (JointKind::Prismatic, 2),
        (JointKind::Spherical, 3),
        (JointKind::Revolute, 1),
        (JointKind::Fixed, 5),
        (JointKind::Continuous, 6),
        (JointKind::Revolute, 4),
    ];
    for (i, (k, parent)) in kinds.iter().enumerate() {
        links.push(link(&format!("l{i}"), &mut rng));
        let axis = Vec3::new(rng.range(-1.0, 1.0), rng.range(-1.0, 1.0), rng.range(-1.0, 1.0)).normalize();
        joints.push(Joint {
            name: format!("j{i}"),
            kind: *k,
            parent: *parent,
            origin: pose_xyz_rpy([rng.range(-0.2, 0.2), rng.range(-0.2, 0.2), rng.range(0.0, 0.3)], [rng.range(-1.0, 1.0), rng.range(-1.0, 1.0), rng.range(-1.0, 1.0)]),
            axis,
            limits: Limits::default(),
        });
    }
    let mut m = Model { name: "tree".into(), links, joints, actuators: vec![], couplings: vec![], end_effectors: vec![] };
    m.normalize().unwrap();
    m
}

#[test]
fn aba_matches_crba_and_rnea_inverts_aba() {
    let mut worst_aba = 0.0f64;
    let mut worst_rnea = 0.0f64;
    let g = Vec3::new(0.0, 0.0, -9.81);
    for (name, kin) in [("tree", tree(3)), ("tree2", tree(11)), ("arm", models::so101_arm())] {
        let model = ModelBuilder::new(kin).build().unwrap();
        let (nv, m) = (model.nv(), &*model);
        let mut ws = Ws::new(m);
        let mut rng = Rng::new(7);
        for _ in 0..200 {
            let q = m.kin.random_q(&mut rng);
            let v: Vec<f64> = (0..nv).map(|_| rng.range(-2.0, 2.0)).collect();
            let tau: Vec<f64> = (0..nv).map(|_| rng.range(-3.0, 3.0)).collect();
            let arm: Vec<f64> = (0..nv).map(|_| rng.range(0.0, 0.01)).collect();
            kinematics(m, &q, &mut ws);
            let mut qdd = vec![0.0; nv];
            aba(m, &v, &tau, None, &arm, &g, &mut ws, &mut qdd);
            // CRBA: (M + arm) qdd = tau - c.
            let mut c = vec![0.0; nv];
            rnea(m, &v, &vec![0.0; nv], None, &g, &mut ws, &mut c);
            crba(m, &arm, &mut ws);
            let h = ws.h.clone();
            let rhs = nalgebra::DVector::from_iterator(nv, (0..nv).map(|i| tau[i] - c[i]));
            let sol = h.clone().cholesky().expect("M is SPD").solve(&rhs);
            let scale = 1.0 + qdd.iter().fold(0.0f64, |a, x| a.max(x.abs()));
            for i in 0..nv {
                worst_aba = worst_aba.max((sol[i] - qdd[i]).abs() / scale);
            }
            // RNEA(ABA(tau)) = tau (with the armature added back).
            let mut back = vec![0.0; nv];
            rnea(m, &v, &qdd, None, &g, &mut ws, &mut back);
            let ts = 1.0 + tau.iter().fold(0.0f64, |a, x| a.max(x.abs()));
            for i in 0..nv {
                worst_rnea = worst_rnea.max((back[i] + arm[i] * qdd[i] - tau[i]).abs() / ts);
            }
        }
        println!("PH1 {name}: nv {nv}");
    }
    println!("PH1 ABA vs CRBA solve, 600 random states: worst {worst_aba:.2e} (target 1e-10)");
    println!("PH1 RNEA(ABA(tau)) - tau: worst {worst_rnea:.2e} (target 1e-10)");
    assert!(worst_aba < 1e-10);
    assert!(worst_rnea < 1e-10);
}

/// A planar double pendulum: two 1 m rods of 1 kg about y, hanging from the world.
fn double_pendulum() -> Model {
    let rod = |name: &str| Link { name: name.into(), inertial: Some(Inertial { mass: 1.0, com: Vec3::new(0.0, 0.0, -0.5), inertia: [1.0 / 12.0, 1.0 / 12.0, 1e-4, 0.0, 0.0, 0.0] }) };
    let j = |name: &str, parent: usize, z: f64| Joint { name: name.into(), kind: JointKind::Continuous, parent, origin: pose_xyz_rpy([0.0, 0.0, z], [0.0; 3]), axis: Vec3::y(), limits: Limits::default() };
    let mut m = Model { name: "double pendulum".into(), links: vec![Link { name: "world".into(), inertial: None }, rod("a"), rod("b")], joints: vec![j("j1", 0, 2.0), j("j2", 1, -1.0)], actuators: vec![], couplings: vec![], end_effectors: vec![] };
    m.normalize().unwrap();
    m
}

fn energy_drift(integrator: Integrator, dt: f64, seconds: f64) -> f64 {
    let model = ModelBuilder::new(double_pendulum()).build().unwrap();
    let mut w = World::new(model, Settings { dt, integrator, ..Settings::default() });
    w.set_q(&[1.2, -0.7]).unwrap();
    let e0 = w.energy();
    // Scale: the energy above the lowest state (the potential at rest).
    let mut rest = w.clone();
    rest.set_q(&[0.0, 0.0]).unwrap();
    let scale = e0 - rest.energy();
    let n = (seconds / dt).round() as usize;
    let mut worst = 0.0f64;
    for k in 0..n {
        w.step().unwrap();
        if k % 100 == 0 || k + 1 == n {
            worst = worst.max((w.energy() - e0).abs() / scale);
        }
    }
    worst
}

#[test]
fn double_pendulum_energy() {
    let rk4 = energy_drift(Integrator::Rk4, 1e-4, 10.0);
    println!("PH1 double pendulum, 10 s, RK4 dt 1e-4: worst energy error {rk4:.2e} of the swing energy (target 1e-6)");
    let si = energy_drift(Integrator::SemiImplicit, 1e-5, 10.0);
    println!("PH1 double pendulum, 10 s, semi-implicit dt 1e-5: worst energy error {si:.2e} (bounded, O(dt))");
    let rk60 = energy_drift(Integrator::Rk4, 1e-3, 60.0);
    println!("PH1 double pendulum, 60 s, RK4 dt 1e-3: worst energy error {rk60:.2e} (6.4: drift under 1e-3)");
    let si60 = energy_drift(Integrator::SemiImplicit, 1e-3, 60.0);
    println!("PH1 double pendulum, 60 s, semi-implicit dt 1e-3: worst energy error {si60:.2e} (not symplectic in v form: chaotic swing drifts)");
    assert!(rk60 < 1e-3);
    assert!(rk4 < 1e-6);
    assert!(si < 1e-3);
}

#[test]
fn joint_limits_and_damping() {
    // Single pendulum (one rod) with a limit at 0.3 rad: released from 1.0 rad it swings down
    // and must stop at the far limit -0.3 rad without passing it by more than a few mrad.
    let mut kin = double_pendulum();
    kin.links.pop();
    kin.joints.pop();
    kin.joints[0].kind = JointKind::Revolute;
    kin.joints[0].limits = Limits { lower: -0.3, upper: 1.0, ..Limits::default() };
    kin.actuators.clear();
    kin.couplings.clear();
    kin.normalize().unwrap();
    let model = ModelBuilder::new(kin.clone()).build().unwrap();
    let mut w = World::new(model, Settings::default());
    w.set_q(&[1.0]).unwrap();
    let mut lowest = f64::INFINITY;
    for _ in 0..3000 {
        w.step().unwrap();
        lowest = lowest.min(w.q[0]);
    }
    println!("PH1 limit -0.3 rad: lowest {:.5} rad, overshoot {:.2e} rad", lowest, -0.3 - lowest);
    assert!(lowest > -0.3 - 2e-3, "{lowest}");

    // Damping: small swings decay as exp(-zeta w t). Rod about its end: I = m L^2 / 3,
    // w0^2 = m g (L/2) / I, zeta = d / (2 I w0).
    let mut kin = kin;
    kin.joints[0].limits = Limits::default();
    kin.joints[0].kind = JointKind::Continuous;
    kin.normalize().unwrap();
    let mut b = ModelBuilder::new(kin);
    b.joint_params(0).damping = 0.05;
    let model = b.build().unwrap();
    let i: f64 = 1.0 / 3.0;
    let w0 = (9.81 * 0.5 / i).sqrt();
    let zeta = 0.05 / (2.0 * i * w0);
    let mut w = World::new(model, Settings { dt: 1e-4, ..Settings::default() });
    w.set_q(&[0.01]).unwrap();
    let mut peaks = vec![];
    let mut last = (w.q[0], w.v[0]);
    for _ in 0..100000 {
        w.step().unwrap();
        if last.1 > 0.0 && w.v[0] <= 0.0 {
            peaks.push((w.t, w.q[0]));
        }
        last = (w.q[0], w.v[0]);
    }
    let (t0, a0) = peaks[0];
    let (t1, a1) = peaks[peaks.len() - 1];
    let measured = (a0 / a1).ln() / (t1 - t0);
    let expected = zeta * w0;
    println!("PH1 damping: decay rate {measured:.5} 1/s, expected {expected:.5} ({:.2} %)", 100.0 * (measured / expected - 1.0));
    assert!((measured / expected - 1.0).abs() < 0.01);
}

#[test]
fn free_body_flies_ballistic() {
    // A free tumbling box: momentum conserved, centre of mass on a parabola.
    let mut b = ModelBuilder::empty();
    let link = b.free_body("box", 2.0, Vec3::zeros(), [0.01, 0.02, 0.03, 0.0, 0.0, 0.0], pose_xyz_rpy([0.0, 0.0, 1.0], [0.0; 3]));
    let model = b.build().unwrap();
    let mut w = World::new(model, Settings { dt: 1e-3, integrator: Integrator::Rk4, ..Settings::default() });
    w.set_v(&[1.0, 0.0, 2.0, 0.3, 5.0, 0.2]).unwrap();
    let e0 = w.energy();
    for _ in 0..1000 {
        w.step().unwrap();
    }
    let p = w.poses()[link].translation.vector;
    // Body-frame initial velocity (1, 0, 2) is the world velocity at t = 0 (identity pose).
    let expected = Vec3::new(1.0, 0.0, 1.0 + 2.0 - 0.5 * 9.81);
    println!("PH1 free body after 1 s: position error {:.2e} m, energy error {:.2e}", (p - expected).norm(), (w.energy() - e0).abs() / e0);
    assert!((p - expected).norm() < 1e-6);
    assert!((w.energy() - e0).abs() / e0 < 1e-6);
}
