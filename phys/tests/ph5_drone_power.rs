//! PH5: the drone in phys against `sim` (same parameters, same controller, same setpoints,
//! trajectories compared), and the power models: battery energy balance (Bernardi heat), a
//! thermal network against its analytic solution, voltage sag, flight time and temperatures.
//! `cargo test --release -p viaform-phys --test ph5_drone_power -- --nocapture` prints the numbers.

use viaform_phys::drone::{self, DroneState, QuadSpec};
use viaform_phys::power::{CellParams, Pack, ThermalNetwork};
use viaform_sim::control::{Cascade, DEFAULT_GAINS, DEFAULT_LIMITS, Estimate, Setpoint};
use viaform_sim::flight::{DT, quad3_default};
use viaform_sim::math::q_to_m3;
use viaform_sim::physics::{self, QuadParams, QuadState, SEA_LEVEL};

fn spec_of(p: &QuadParams) -> QuadSpec {
    serde_json::from_value(serde_json::to_value(p).unwrap()).unwrap()
}

/// Flies both simulators through `setpoints` (time, target) with their own copy of sim's
/// cascade controller fed by their own state. Returns the worst position and attitude gaps.
fn fly(start: [f64; 3], setpoints: &[(f64, [f64; 3])], t_end: f64) -> (f64, f64, f64) {
    let p = quad3_default();
    let spec = spec_of(&p);
    assert_eq!(spec, QuadSpec::default(), "QuadSpec defaults are sim's quad3_default");
    let q0 = [1.0, 0.0, 0.0, 0.0];
    let mut s = QuadState::new(start, q0);
    let hover = (p.mass * physics::G / (4.0 * p.k_t)).sqrt();
    s.omega = [hover; 4];
    let mut w = drone::quad_world(&spec, &DroneState { p: start, v: [0.0; 3], q: q0, w: [0.0; 3], omega: [hover; 4] }, false).unwrap();
    let (mut ca, mut cb) = (Cascade::new(p.clone(), DEFAULT_GAINS, DEFAULT_LIMITS), Cascade::new(p.clone(), DEFAULT_GAINS, DEFAULT_LIMITS));
    let n = (t_end / DT).round() as usize;
    let (mut worst_p, mut worst_att) = (0.0f64, 0.0f64);
    let mut path = 0.0;
    let mut last = start;
    let mut acc_b = [0.0, 0.0, physics::G];
    for k in 0..n {
        let t = k as f64 * DT;
        let target = setpoints.iter().rev().find(|(t0, _)| t >= *t0).map(|x| x.1).unwrap_or(start);
        let sp = Setpoint::Position { p: target, yaw: 0.0 };
        // sim
        let e = Estimate { p: s.p, v: s.v, r: q_to_m3(s.q), w: s.w, acc_body: s.acc_body };
        let acc = ca.outer(&e, &sp, DT);
        let cmd = ca.inner(&e, acc, sp.yaw(), DT, None);
        physics::step(&p, &mut s, &cmd, [0.0; 3], DT, &SEA_LEVEL, None);
        // phys
        let d = drone::state(&w);
        let e = Estimate { p: d.p, v: d.v, r: q_to_m3(d.q), w: d.w, acc_body: acc_b };
        let acc = cb.outer(&e, &sp, DT);
        let cmd = cb.inner(&e, acc, sp.yaw(), DT, None);
        drone::set_commands(&mut w, &cmd);
        w.step().unwrap();
        let d2 = drone::state(&w);
        // Specific force in body axes, as sim's acc_body.
        let r = q_to_m3(d2.q);
        let a = [(d2.v[0] - d.v[0]) / DT, (d2.v[1] - d.v[1]) / DT, (d2.v[2] - d.v[2]) / DT + physics::G];
        acc_b = [r[0] * a[0] + r[3] * a[1] + r[6] * a[2], r[1] * a[0] + r[4] * a[1] + r[7] * a[2], r[2] * a[0] + r[5] * a[1] + r[8] * a[2]];
        let gap = ((0..3).map(|i| (d2.p[i] - s.p[i]).powi(2)).sum::<f64>()).sqrt();
        worst_p = worst_p.max(gap);
        let dot: f64 = (0..4).map(|i| d2.q[i] * s.q[i]).sum::<f64>().abs().min(1.0);
        worst_att = worst_att.max(2.0 * dot.acos());
        path += ((0..3).map(|i| (s.p[i] - last[i]).powi(2)).sum::<f64>()).sqrt();
        last = s.p;
    }
    (worst_p, worst_att, path)
}

#[test]
fn drone_parity_with_sim() {
    // Hover: 10 s holding a point from a 10 cm offset start.
    let (dp, da, _) = fly([0.1, -0.1, 0.9], &[(0.0, [0.0, 0.0, 1.0])], 10.0);
    println!("PH5 parity hover 10 s: worst position gap {:.3} mm, attitude gap {:.4} deg", dp * 1e3, da.to_degrees());
    assert!(dp < 1e-3, "hover within 1 mm");
    // Course: four waypoints in 5 s.
    let course = [(0.0, [0.0, 0.0, 1.0]), (0.5, [1.5, 0.0, 1.5]), (1.8, [1.5, 1.5, 1.0]), (3.0, [0.0, 1.0, 2.0]), (4.2, [0.0, 0.0, 1.0])];
    let (dp, da, path) = fly([0.0, 0.0, 1.0], &course, 5.0);
    println!("PH5 parity course 5 s ({path:.2} m flown): worst position gap {:.2} mm, attitude gap {:.3} deg", dp * 1e3, da.to_degrees());
    assert!(dp < 0.05, "course within 5 cm");
}

#[test]
fn battery_energy_balance_bernardi() {
    // Constant 6 A from a 3S pack for 4 minutes: chemical energy int I U(soc) dt equals energy
    // out plus irreversible heat (Bernardi's I (U - V)); U integrated over the charge drawn.
    let cell = CellParams::default();
    let mut pack = Pack::new(cell.clone(), 3.0, 1.0, 25.0);
    let (i, dt, t_end) = (6.0, 0.01, 240.0);
    let n = (t_end / dt) as usize;
    let mut sag = 0.0f64;
    for _ in 0..n {
        let v = pack.step(i, dt);
        sag = sag.max(3.0 * cell.ocv(pack.soc) - v);
    }
    // Simpson over the charge drawn: E = 3 cells * Q * int U dsoc.
    let (s0, s1) = (pack.soc, 1.0);
    let m = 20000;
    let h = (s1 - s0) / m as f64;
    let mut sum = cell.ocv(s0) + cell.ocv(s1);
    for k in 1..m {
        sum += if k % 2 == 1 { 4.0 } else { 2.0 } * cell.ocv(s0 + k as f64 * h);
    }
    let chem = 3.0 * cell.capacity_ah * 3600.0 * sum * h / 3.0;
    let rel = (pack.energy_out + pack.heat_irreversible - chem).abs() / chem;
    println!(
        "PH5 battery 6 A for 240 s: soc {:.4}, energy out {:.1} J, irreversible heat {:.2} J, reversible {:.3} J, chemical {:.1} J, balance {rel:.2e} (target 1e-6); sag {:.3} V, core {:.2} C, surface {:.2} C",
        pack.soc,
        pack.energy_out,
        pack.heat_irreversible,
        pack.heat_reversible,
        chem,
        sag,
        pack.t_core,
        pack.t_surface
    );
    assert!(rel < 1e-6);
    assert!(pack.t_core > pack.t_surface && pack.t_surface > 25.0);
}

#[test]
fn thermal_network_matches_analytic() {
    // Winding and stator nodes, constant copper loss: the two-node solution in closed form.
    let (c1, c2, g12, g2a, p, amb) = (1.5, 3.0, 0.5, 0.2, 4.0, 25.0);
    let mut net = ThermalNetwork::new(&["winding", "stator"], vec![c1, c2], vec![(0, 1, g12)], vec![0.0, g2a], amb);
    // dT/dt = A T + b, A = [[-g12/c1, g12/c1], [g12/c2, -(g12+g2a)/c2]], rise x = T - Tss.
    let a = [[-g12 / c1, g12 / c1], [g12 / c2, -(g12 + g2a) / c2]];
    let tss = [amb + p / g2a + p / g12, amb + p / g2a];
    let tr = a[0][0] + a[1][1];
    let det = a[0][0] * a[1][1] - a[0][1] * a[1][0];
    let disc = (tr * tr / 4.0 - det).sqrt();
    let (l1, l2) = (tr / 2.0 + disc, tr / 2.0 - disc);
    // Eigenvectors (a01, l - a00); x0 = amb - tss = c1 u + c2 v.
    let (u, v) = ([a[0][1], l1 - a[0][0]], [a[0][1], l2 - a[0][0]]);
    let x0 = [amb - tss[0], amb - tss[1]];
    let d = u[0] * v[1] - u[1] * v[0];
    let (k1, k2) = ((x0[0] * v[1] - x0[1] * v[0]) / d, (u[0] * x0[1] - u[1] * x0[0]) / d);
    let mut worst = 0.0f64;
    let dt = 0.5;
    for step in 1..=2000 {
        net.step(&[p, 0.0], dt);
        let t = step as f64 * dt;
        for i in 0..2 {
            let exact = tss[i] + k1 * u[i] * (l1 * t).exp() + k2 * v[i] * (l2 * t).exp();
            worst = worst.max((net.t[i] - exact).abs() / (tss[i] - amb));
        }
    }
    println!("PH5 two-node motor network, 4 W for 1000 s at 0.5 s steps: worst error {worst:.2e} of the rise (target 1e-6), winding {:.3} C (steady {:.3})", net.t[0], tss[0]);
    assert!(worst < 1e-6);
}

#[test]
fn hover_flight_time_and_temperatures() {
    // Hover on the powertrain until the pack hits its cutoff; compare sim's battery model.
    let p = quad3_default();
    let spec = spec_of(&p);
    let mut w = drone::quad_world(&spec, &DroneState { p: [0.0, 0.0, 1.0], q: [1.0, 0.0, 0.0, 0.0], ..DroneState::default() }, false).unwrap();
    w.powertrain = Some(drone::powertrain(&spec, 25.0));
    let mut c = Cascade::new(p.clone(), DEFAULT_GAINS, DEFAULT_LIMITS);
    let sp = Setpoint::Position { p: [0.0, 0.0, 1.0], yaw: 0.0 };
    let mut t = 0.0;
    let mut v_start = 0.0;
    let mut lowest_z = 1.0f64;
    while t < 1200.0 {
        let d = drone::state(&w);
        let e = Estimate { p: d.p, v: d.v, r: q_to_m3(d.q), w: d.w, acc_body: [0.0, 0.0, physics::G] };
        let acc = c.outer(&e, &sp, DT);
        let cmd = c.inner(&e, acc, 0.0, DT, None);
        drone::set_commands(&mut w, &cmd);
        w.step().unwrap();
        t += DT;
        let pt = w.powertrain.as_ref().unwrap();
        if v_start == 0.0 && t > 1.0 {
            v_start = pt.pack.voltage;
        }
        if t > 5.0 {
            lowest_z = lowest_z.min(d.p[2]);
        }
        if pt.pack.empty() {
            break;
        }
    }
    let pt = w.powertrain.as_ref().unwrap();
    let wind = pt.motors[0].temp("winding").unwrap();
    let esc = pt.escs[0].temp("esc").unwrap();
    // sim's battery at the same hover current.
    let hover_t = p.mass * physics::G / 4.0;
    let i_hover = 4.0 * viaform_sim::weather::motor_current_peak(hover_t, p.max_thrust, p.peak_current) + 0.3;
    let mut b = viaform_sim::weather::Battery::new(p.battery_ah, p.battery_cells, 25.0);
    let mut ts = 0.0;
    while ts < 1200.0 && b.draw(i_hover, 0.01) / p.battery_cells > 3.3 && b.soc > 0.0 {
        ts += 0.01;
    }
    println!(
        "PH5 hover on 3S 650 mAh: flight time {:.0} s (sim's battery model at {i_hover:.2} A: {ts:.0} s), voltage {v_start:.2} V loaded at start, {:.2} V at cutoff, pack core {:.1} C, winding {wind:.1} C, ESC {esc:.1} C, lowest hover height {lowest_z:.3} m",
        t,
        pt.pack.voltage,
        pt.pack.t_core
    );
    assert!(t > 120.0 && t < 1200.0);
    assert!((t / ts - 1.0).abs() < 0.25, "flight time within 25 % of sim's simpler model");
    assert!(wind > 25.0 && esc > 25.0);
    assert!(lowest_z > 0.9, "voltage sag does not drop the hover");
}
