//! PH3: actuators. A position servo of the STS3215 class against a synthetic reference (the
//! continuous servo model integrated finely), its torque and speed limits, backlash, deadband
//! and encoder quantisation, and a DC gearmotor against its analytic first-order response.
//! `cargo test --release -p viaform-phys --test ph3_actuators -- --nocapture` prints the numbers.

use viaform_kin::math::pose_xyz_rpy;
use viaform_kin::model::{Actuator, Coupling, CouplingKind, Drive, Inertial, Joint, JointKind, Limits, Link};
use viaform_kin::{Model, Vec3};
use viaform_phys::actuator::{ActuatorKind, DcParams, ServoParams};
use viaform_phys::{ModelBuilder, Settings, World};

/// One revolute joint about `axis` carrying a body of inertia `j` about that axis, with its
/// centre of mass `arm` metres out along x (for gravity loads).
fn one_joint(j: f64, mass: f64, arm: f64, axis: Vec3) -> Model {
    let inertial = Inertial { mass, com: Vec3::new(arm, 0.0, 0.0), inertia: [j, j, j, 0.0, 0.0, 0.0] };
    let mut m = Model {
        name: "one".into(),
        links: vec![Link { name: "world".into(), inertial: None }, Link { name: "load".into(), inertial: Some(inertial) }],
        joints: vec![Joint { name: "j".into(), kind: JointKind::Revolute, parent: 0, origin: pose_xyz_rpy([0.0; 3], [0.0; 3]), axis, limits: Limits::default() }],
        actuators: vec![Actuator { name: "m".into(), drive: Drive::Motor, limits: Limits::default() }],
        couplings: vec![Coupling { name: "c".into(), kind: CouplingKind::Linear, actuators: vec![0], joints: vec![0], matrix: vec![1.0], offset: vec![] }],
        end_effectors: vec![],
    };
    m.normalize().unwrap();
    m
}

fn world(kin: Model, kind: ActuatorKind, dt: f64) -> World {
    let mut b = ModelBuilder::new(kin);
    b.actuator(0, kind);
    World::new(b.build().unwrap(), Settings { dt, ..Settings::default() })
}

/// The ideal servo (no quantisation, deadband or backlash): `J theta'' = clamp(kp e - kd w,
/// box(w))`, RK4 at 1 us. This is the synthetic reference trace.
fn reference(p: &ServoParams, j_total: f64, target: f64, t_end: f64, every: f64) -> Vec<f64> {
    let f = |th: f64, w: f64| {
        let (lo, hi) = p.torque_box(w);
        ((p.kp * (target - th) - p.kd * w).clamp(lo, hi)) / j_total
    };
    let h = 1e-6;
    let (mut th, mut w) = (0.0f64, 0.0f64);
    let n = (t_end / h).round() as usize;
    let stride = (every / h).round() as usize;
    let mut out = vec![0.0];
    for k in 1..=n {
        let (k1t, k1w) = (w, f(th, w));
        let (k2t, k2w) = (w + 0.5 * h * k1w, f(th + 0.5 * h * k1t, w + 0.5 * h * k1w));
        let (k3t, k3w) = (w + 0.5 * h * k2w, f(th + 0.5 * h * k2t, w + 0.5 * h * k2w));
        let (k4t, k4w) = (w + h * k3w, f(th + h * k3t, w + h * k3w));
        th += h / 6.0 * (k1t + 2.0 * k2t + 2.0 * k3t + k4t);
        w += h / 6.0 * (k1w + 2.0 * k2w + 2.0 * k3w + k4w);
        if k % stride == 0 {
            out.push(th);
        }
    }
    out
}

/// 10 % to 90 % rise time of a trace sampled every `dt`, interpolated.
fn rise_time(trace: &[f64], step: f64, dt: f64) -> f64 {
    let cross = |level: f64| {
        let k = trace.iter().position(|&x| x >= level * step).unwrap();
        let (a, b) = (trace[k - 1], trace[k]);
        (k as f64 - 1.0 + (level * step - a) / (b - a)) * dt
    };
    cross(0.9) - cross(0.1)
}

fn ideal_servo() -> ServoParams {
    ServoParams { backlash: 0.0, deadband: 0.0, encoder_counts: 0.0, ..ServoParams::default() }
}

#[test]
fn servo_step_matches_reference() {
    let j_load = 1e-3;
    let p = ideal_servo();
    let j_total = j_load + p.rotor_inertia * p.gear_ratio * p.gear_ratio;
    let dt = 1e-3;
    for step in [0.1, 1.0] {
        let mut w = world(one_joint(j_load, 0.1, 0.0, Vec3::z()), ActuatorKind::Servo(p.clone()), dt);
        w.set_control(0, step);
        let mut trace = vec![w.q[0]];
        let mut peak_speed = 0.0f64;
        for _ in 0..1000 {
            w.step().unwrap();
            trace.push(w.q[0]);
            peak_speed = peak_speed.max(w.v[0]);
        }
        let reference = reference(&p, j_total, step, 1.0, dt);
        let (ours, theirs) = (rise_time(&trace, step, dt), rise_time(&reference, step, dt));
        let worst = trace.iter().zip(&reference).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        let over = |t: &[f64]| (t.iter().cloned().fold(f64::MIN, f64::max) / step - 1.0) * 100.0;
        println!(
            "PH3 servo step {step} rad, J {j_total:.2e} kg m^2, dt 1 ms: rise {:.2} ms vs reference {:.2} ms ({:+.2} %), overshoot {:.2} % vs {:.2} %, worst |error| {worst:.2e} rad, peak speed {peak_speed:.3} rad/s (no load {:.3})",
            ours * 1e3,
            theirs * 1e3,
            (ours / theirs - 1.0) * 100.0,
            over(&trace),
            over(&reference),
            p.no_load_speed
        );
        assert!((ours / theirs - 1.0).abs() < 0.10, "rise time within 10 %");
        assert!((trace[1000] - step).abs() < 1e-3);
        assert!(peak_speed <= p.no_load_speed * 1.001);
    }
}

#[test]
fn servo_torque_limit_and_stiffness() {
    // A 0.5 kg mass 0.2 m out on a horizontal axis: 0.98 N m, held with error tau / kp.
    let p = ideal_servo();
    let g = 9.81;
    let mut w = world(one_joint(1e-4, 0.5, 0.2, Vec3::y()), ActuatorKind::Servo(p.clone()), 1e-3);
    w.run(3000).unwrap();
    let load = 0.5 * g * 0.2;
    // Gravity about +y pulls the +x arm down: positive rotation about y.
    let err = w.q[0];
    println!("PH3 servo holding {load:.3} N m: sag {err:.5} rad, tau / kp = {:.5} rad, effort {:.4} N m", load / p.kp, w.act[0].effort);
    assert!((err - load / p.kp).abs() < 0.02 * load / p.kp);
    // 2 kg at 0.2 m: 3.92 N m, over the 2.65 N m the gearbox passes: the arm falls.
    let mut w = world(one_joint(1e-4, 2.0, 0.2, Vec3::y()), ActuatorKind::Servo(p.clone()), 1e-3);
    w.run(500).unwrap();
    println!("PH3 servo against 3.92 N m (limit {:.3} N m): angle after 0.5 s {:.3} rad, effort {:.4} N m", p.max_torque * p.efficiency, w.q[0], w.act[0].effort);
    assert!(w.q[0] > 0.3);
    assert!(w.act[0].effort.abs() <= p.max_torque * p.efficiency + 1e-9);
}

#[test]
fn servo_backlash_deadband_quantisation() {
    let dt = 1e-3;
    let reversal = |backlash: f64| {
        let p = ServoParams { backlash, deadband: 0.0, encoder_counts: 0.0, ..ServoParams::default() };
        let mut w = world(one_joint(1e-3, 0.1, 0.0, Vec3::z()), ActuatorKind::Servo(p), dt);
        w.set_control(0, 0.2);
        w.run(1000).unwrap();
        w.set_control(0, -0.2);
        let start = w.q[0];
        let mut k = 0;
        while w.q[0] > start - 0.04 {
            w.step().unwrap();
            k += 1;
        }
        (k as f64 * dt, start)
    };
    let b = 2.0f64.to_radians();
    let (t0, _) = reversal(0.0);
    let (t1, held) = reversal(b);
    println!("PH3 backlash {:.1} deg: reversal reaches 10 % {:.1} ms later than without ({:.1} vs {:.1} ms), held {held:.5} rad before", b.to_degrees(), (t1 - t0) * 1e3, t1 * 1e3, t0 * 1e3);
    assert!(t1 - t0 > 2e-3 && t1 - t0 < 40e-3);
    // A frictionless load can rest anywhere inside the gap.
    assert!((held - 0.2).abs() < 0.5 * b);

    // Deadband: a step under it does not move the output; a larger one settles within it.
    let p = ServoParams::default();
    let count = std::f64::consts::TAU / p.encoder_counts;
    let mut w = world(one_joint(1e-3, 0.1, 0.0, Vec3::z()), ActuatorKind::Servo(p.clone()), dt);
    w.set_control(0, 1.5 * count);
    w.run(500).unwrap();
    let small = w.q[0];
    w.set_control(0, 0.1);
    w.run(1000).unwrap();
    let err = (w.q[0] - 0.1).abs();
    println!("PH3 deadband {:.1} counts: a 1.5 count step moves {:.2e} rad; a 0.1 rad step settles {:.2e} rad off (bound {:.2e})", p.deadband / count, small, err, p.deadband + 0.5 * count);
    assert!(small.abs() < 1e-9);
    assert!(err <= p.deadband + 0.5 * count + 1e-9);
    // The encoder reports whole counts.
    let m = p.measure(w.q[0]);
    assert!(((m / count) - (m / count).round()).abs() < 1e-9);
}

#[test]
fn dc_motor_first_order() {
    // Below the current limit the DC gearmotor on an inertia is first order:
    // w(t) = V / (N ke) (1 - exp(-t / tau)), tau = J_total / (eta N^2 kt ke / R).
    let p = DcParams::default();
    let j_load = 1e-3;
    let j_total = j_load + p.rotor_inertia * p.gear_ratio * p.gear_ratio;
    let volts = 4.0;
    let w_ss = volts / (p.gear_ratio * p.ke);
    let tau = j_total / p.emf_damping();
    for dt in [1e-3, 1e-4] {
        let mut w = world(one_joint(j_load, 0.1, 0.0, Vec3::z()), ActuatorKind::Dc(p.clone()), dt);
        w.set_control(0, volts);
        let n = (0.1 / dt).round() as usize;
        let mut worst = 0.0f64;
        for k in 1..=n {
            w.step().unwrap();
            let t = k as f64 * dt;
            let exact = w_ss * (1.0 - (-t / tau).exp());
            worst = worst.max((w.v[0] - exact).abs() / w_ss);
        }
        println!("PH3 DC motor {volts} V, tau {:.2} ms, dt {dt:.0e} s: worst speed error {:.3} % of {w_ss:.2} rad/s, current {:.3} A", tau * 1e3, worst * 100.0, w.act[0].current);
        if dt < 5e-4 {
            assert!(worst < 0.01);
        }
    }
    // At 12 V the stall current (6 A) is over the 3 A limit: the start is current limited.
    let mut w = world(one_joint(j_load, 0.1, 0.0, Vec3::z()), ActuatorKind::Dc(p.clone()), 1e-4);
    w.set_control(0, 12.0);
    w.step().unwrap();
    let accel = w.v[0] / 1e-4;
    let expect = p.efficiency * p.gear_ratio * p.kt * p.max_current / j_total;
    println!("PH3 DC motor 12 V start: current {:.3} A, acceleration {accel:.2} vs {expect:.2} rad/s^2", w.act[0].current);
    assert!((w.act[0].current - p.max_current).abs() < 1e-12);
    assert!((accel / expect - 1.0).abs() < 1e-9);
}
