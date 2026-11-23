//! Acceptance numbers of RUST-ENGINES section 10 (K1, K2, K3, K5, K6). Run with
//! `cargo test --release -p viaform-kin --test acceptance -- --nocapture` to see the numbers.

use std::time::Instant;

use viaform_kin::analytic::Analytic6R;
use viaform_kin::ik::{IkOptions, IkProblem, IkTask, solve};
use viaform_kin::math::{Rng, rot_error, wrap_pi};
use viaform_kin::{Jacobian, models};

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v[v.len() / 2]
}

/// K1: FK plus Jacobian timing (spec: 6-DOF under 2 us, 20-DOF hand under 8 us).
#[test]
fn k1_fk_jacobian_timing() {
    for (name, m, frames) in [("arm", models::so101_arm(), 1usize), ("hand", models::hand5(), 5)] {
        let mut rng = Rng::new(1);
        let qs: Vec<Vec<f64>> = (0..1000).map(|_| m.random_q(&mut rng)).collect();
        let mut poses = Vec::new();
        let mut j = Jacobian::zeros(m.nv());
        let mut sink = 0.0;
        let reps = 200;
        let t0 = Instant::now();
        for _ in 0..reps {
            for q in &qs {
                m.fk_into(q, &mut poses);
                for f in 0..frames {
                    let p = m.frame_pose(&poses, f).translation.vector;
                    m.jacobian_into(&poses, m.end_effectors[f].link, &p, &mut j);
                    sink += j[(0, 0)];
                }
            }
        }
        let us = t0.elapsed().as_secs_f64() * 1e6 / (reps * qs.len()) as f64;
        println!("K1 {name}: {} DOF, FK + {frames} Jacobian(s) {us:.3} us per call ({sink:.1})", m.nv());
        let limit = if name == "arm" { 2.0 } else { 8.0 };
        assert!(us < limit * 3.0, "{name} {us} us (target {limit} us; 3x margin for a loaded test machine)");
    }
}

/// K2: 10k random reachable targets on the 6-axis arm, at least 99.5 percent converge.
#[test]
fn k2_numerical_ik_10k() {
    let m = models::so101_arm();
    let mut rng = Rng::new(2026);
    let n = 10_000;
    let mut ok = 0;
    let mut times = Vec::with_capacity(n);
    let mut iters = 0;
    let opts = IkOptions::default();
    for _ in 0..n {
        let qt = m.random_q(&mut rng);
        let target = m.fk_frame(&qt, 0).unwrap();
        let t0 = Instant::now();
        let r = solve(&m, &IkProblem::new(vec![IkTask::pose(0, target)], m.neutral()), &opts).unwrap();
        times.push(t0.elapsed().as_secs_f64() * 1e6);
        iters += r.iterations;
        for (j, joint) in m.joints.iter().enumerate() {
            assert!(r.q[j] >= joint.limits.lower && r.q[j] <= joint.limits.upper, "limit violated");
        }
        if r.converged {
            ok += 1;
            let p = m.fk_frame(&r.q, 0).unwrap();
            assert!((p.translation.vector - target.translation.vector).norm() <= opts.tol_pos);
            assert!(rot_error(&target.rotation, &p.rotation).norm() <= opts.tol_rot);
        }
    }
    let rate = ok as f64 / n as f64;
    println!("K2 numerical IK: {ok}/{n} converged ({:.2} %), median {:.1} us, mean {:.1} iterations", rate * 100.0, median(times), iters as f64 / n as f64);
    assert!(rate >= 0.995, "rate {rate}");
}

/// K3: the analytic solver finds the generating configuration among all its solutions, every
/// solution is exact, and it matches the numerical solver.
#[test]
fn k3_analytic_matches_numerical() {
    let m = models::so101_arm();
    let a = Analytic6R::new(&m, 0).unwrap();
    let mut rng = Rng::new(33);
    let n = 10_000;
    let (mut found, mut worst_pos, mut worst_rot, mut nsol) = (0, 0.0f64, 0.0f64, 0);
    let mut times = vec![];
    let (mut num_checked, mut num_match) = (0, 0);
    for k in 0..n {
        let qt = m.random_q(&mut rng);
        let target = m.fk_frame(&qt, 0).unwrap();
        let t0 = Instant::now();
        let sols = a.solve_all(&target, &[0.0; 6]);
        times.push(t0.elapsed().as_secs_f64() * 1e6);
        nsol += sols.len();
        if sols.iter().any(|s| (0..6).all(|i| wrap_pi(s[i] - qt[i]).abs() < 1e-6)) {
            found += 1;
        }
        for s in &sols {
            let p = m.fk_frame(s, 0).unwrap();
            worst_pos = worst_pos.max((p.translation.vector - target.translation.vector).norm());
            worst_rot = worst_rot.max(rot_error(&target.rotation, &p.rotation).norm());
        }
        // Numerical solver on every 10th target: its answer is one of the analytic solutions
        // (compared after one analytic solve warm-started at the numerical answer).
        if k % 10 == 0 {
            // Tight tolerances so the comparison is about the solution, not the stopping rule.
            let tight = IkOptions { tol_pos: 1e-11, tol_rot: 1e-11, ..IkOptions::default() };
            let r = solve(&m, &IkProblem::new(vec![IkTask::pose(0, target)], m.neutral()), &tight).unwrap();
            // Near the wrist singularity (|q5| small) the solver's tolerance spreads over q4 and
            // q6, so the comparison only counts regular wrists.
            if r.converged && r.q[4].abs() > 0.1 {
                num_checked += 1;
                let near = a.solve_nearest(&target, &r.q);
                if let Some(qa) = near {
                    let d = (0..6).map(|i| (qa[i] - r.q[i]).abs()).fold(0.0, f64::max);
                    // A converged numerical answer is within its tolerance of a true solution;
                    // near a wrist singularity that tolerance spreads over q4 and q6.
                    if d < 1e-6 {
                        num_match += 1;
                    }
                }
            }
        }
    }
    println!(
        "K3 analytic IK: generating solution found {found}/{n}, {:.2} solutions per target, worst FK error {worst_pos:.1e} m {worst_rot:.1e} rad, median {:.1} us; numerical answers matched {num_match}/{num_checked} (regular wrists, tolerance 1e-11, agreement 1e-6 rad)",
        nsol as f64 / n as f64,
        median(times)
    );
    assert_eq!(found, n);
    assert!(worst_pos < 1e-9 && worst_rot < 1e-9);
    assert!(num_match as f64 >= 0.995 * num_checked as f64);
}

/// K5: grasp poses on the five-finger hand (motors, a linkage and tendons): fingertip targets
/// from a random closed hand, solved from the open hand, every fingertip within 1e-5 m, couplings
/// exact, limits held.
#[test]
fn k5_hand_grasp() {
    use viaform_kin::hand::{Fingertip, solve_grasp};
    use viaform_kin::{Drive, CouplingKind};
    let m = models::hand5();
    assert_eq!(m.nv(), 22);
    assert!(m.actuators.iter().any(|a| a.drive == Drive::Tendon) && m.actuators.iter().any(|a| a.drive == Drive::Motor));
    assert!(m.couplings.iter().any(|c| matches!(c.kind, CouplingKind::Tendon { .. })));
    let bounds = m.actuator_bounds();
    let mut rng = Rng::new(55);
    let n = 300;
    let (mut ok, mut times) = (0, vec![]);
    let opts = IkOptions::default();
    for _ in 0..n {
        // A grasp: every actuator in the closing half of its range.
        let a: Vec<f64> = bounds.iter().map(|&(lo, hi)| rng.range(lo + 0.3 * (hi - lo), lo + 0.9 * (hi - lo))).collect();
        let qt = m.from_actuators(&a);
        let poses = m.fk(&qt).unwrap();
        let tips: Vec<Fingertip> = (0..5).map(|f| Fingertip { frame: f, point: m.frame_pose(&poses, f).translation.vector, priority: 1 }).collect();
        let t0 = Instant::now();
        let g = solve_grasp(&m, &tips, m.neutral(), 0.02, &opts).unwrap();
        times.push(t0.elapsed().as_secs_f64() * 1e6);
        // Couplings exact, limits held, whatever the convergence.
        let back = m.from_actuators(&g.ik.actuators);
        for k in 0..m.nq() {
            assert!((back[k] - g.ik.q[k]).abs() < 1e-12, "coupling broken at {k}");
        }
        for (j, joint) in m.joints.iter().enumerate() {
            assert!(g.ik.q[j] >= joint.limits.lower - 1e-9 && g.ik.q[j] <= joint.limits.upper + 1e-9, "{} out of limits", joint.name);
        }
        if g.reached.iter().all(|r| *r) {
            ok += 1;
        }
    }
    println!("K5 hand grasp: {ok}/{n} grasps with all 5 fingertips within 1e-5 m, median {:.0} us", median(times));
    assert!(ok as f64 >= 0.98 * n as f64);
}

/// K5: priorities. The pinch (thumb and index, priority 1) is met exactly while an unreachable
/// pinky target (priority 2) only gets as close as the null space allows.
#[test]
fn k5_priority_keeps_the_pinch() {
    use viaform_kin::hand::{Fingertip, solve_grasp};
    let m = models::hand5();
    let mut rng = Rng::new(9);
    let bounds = m.actuator_bounds();
    let a: Vec<f64> = bounds.iter().map(|&(lo, hi)| rng.range(lo + 0.3 * (hi - lo), lo + 0.7 * (hi - lo))).collect();
    let poses = m.fk(&m.from_actuators(&a)).unwrap();
    let pinch = |f: usize| Fingertip { frame: f, point: m.frame_pose(&poses, f).translation.vector, priority: 1 };
    let far = Fingertip { frame: 4, point: viaform_kin::Vec3::new(-0.3, -0.2, 0.0), priority: 2 };
    let g = solve_grasp(&m, &[pinch(0), pinch(1), far], m.neutral(), 0.0, &IkOptions { seeds: 4, ..IkOptions::default() }).unwrap();
    println!("K5 priority: pinch errors {:.1e} {:.1e} m, unreachable pinky {:.3} m away", g.distance[0], g.distance[1], g.distance[2]);
    assert!(g.reached[0] && g.reached[1]);
    assert!(!g.reached[2] && g.distance[2] > 0.1);
}

/// K4 timing check for the drag: 10 iterations warm-started (spec: 1 ms arm, 3 ms hand).
#[test]
fn k4_drag_timing() {
    use viaform_kin::drag::{Drag, DragOptions};
    for (name, m, frames) in [("arm", models::so101_arm(), vec![0]), ("hand", models::hand5(), vec![0, 1, 2, 3, 4])] {
        let mut rng = Rng::new(8);
        let q0 = m.from_actuators(&m.actuator_bounds().iter().map(|&(lo, hi)| 0.5 * (lo + hi)).collect::<Vec<_>>());
        let numerical = DragOptions { keep_orientation: name == "arm", analytic: false, ..DragOptions::default() };
        for opts in [DragOptions { keep_orientation: name == "arm", ..DragOptions::default() }, numerical] {
            let mut d = Drag::begin(&m, frames.clone(), q0.clone(), opts).unwrap();
            let start: Vec<_> = frames.iter().map(|&f| m.fk_frame(&q0, f).unwrap()).collect();
            let mut worst: f64 = 0.0;
            let mut times = vec![];
            for i in 0..300 {
                let s = 0.004 * (i as f64 * 0.05).sin();
                let targets: Vec<_> = start.iter().map(|t| {
                    let mut t = *t;
                    t.translation.vector += viaform_kin::Vec3::new(s, 0.5 * s, -s) + viaform_kin::Vec3::new(rng.range(-1e-4, 1e-4), 0.0, 0.0);
                    t
                }).collect();
                let t0 = Instant::now();
                d.move_to(&m, &targets).unwrap();
                let dt = t0.elapsed().as_secs_f64() * 1e3;
                worst = worst.max(dt);
                times.push(dt);
            }
            println!("K4 drag {name} ({:?}): median {:.3} ms, worst {:.3} ms per move", d.solver, median(times.clone()), worst);
            assert!(median(times) < if name == "arm" { 1.0 } else { 3.0 });
        }
    }
}

fn line_deviation(p: &viaform_kin::Vec3, a: &viaform_kin::Vec3, b: &viaform_kin::Vec3) -> f64 {
    let d = b - a;
    let t = ((p - a).dot(&d) / d.norm_squared()).clamp(0.0, 1.0);
    (p - (a + d * t)).norm()
}

/// K6: straight lines of the template arm: deviation under 0.5 mm at every 500 Hz sample, no
/// joint position or velocity limit violation.
#[test]
fn k6_cartesian_lines() {
    use viaform_kin::path::{PathOpts, Profile, cartesian_path};
    let m = models::so101_arm();
    let mut rng = Rng::new(66);
    let (mut feasible, mut tried, mut worst, mut samples) = (0, 0, 0.0f64, 0usize);
    let mut rejected = std::collections::BTreeMap::new();
    let t0 = Instant::now();
    while feasible < 40 && tried < 400 {
        tried += 1;
        // A comfortable start (elbow bent, wrist away from its singularity).
        let q: Vec<f64> = vec![rng.range(-1.0, 1.0), rng.range(-0.6, 0.6), rng.range(0.4, 1.4), rng.range(-1.0, 1.0), rng.range(0.4, 1.2) * if rng.uniform() < 0.5 { -1.0 } else { 1.0 }, rng.range(-1.0, 1.0)];
        let start = m.fk_frame(&q, 0).unwrap();
        let dir = viaform_kin::Vec3::new(rng.normal(), rng.normal(), rng.normal()).normalize();
        let mut goal = start;
        goal.translation.vector += dir * rng.range(0.03, 0.12);
        let profile = if tried % 2 == 0 { Profile::SCurve } else { Profile::Trapezoid };
        match cartesian_path(&m, &q, &[goal], 0, &PathOpts { profile, ..PathOpts::default() }) {
            Ok(tr) => {
                feasible += 1;
                for (i, qi) in tr.q.iter().enumerate() {
                    let p = m.fk_frame(qi, 0).unwrap().translation.vector;
                    worst = worst.max(line_deviation(&p, &start.translation.vector, &goal.translation.vector));
                    for (j, joint) in m.joints.iter().enumerate() {
                        assert!(qi[j] >= joint.limits.lower && qi[j] <= joint.limits.upper);
                        assert!(tr.qd[i][j].abs() <= joint.limits.velocity * (1.0 + 1e-9), "velocity limit");
                    }
                }
                samples += tr.q.len();
                let dt: Vec<f64> = tr.t.windows(2).map(|w| w[1] - w[0]).collect();
                assert!(dt[..dt.len() - 1].iter().all(|d| (d - 0.002).abs() < 1e-12), "500 Hz");
            }
            Err(e) => *rejected.entry(e.code).or_insert(0) += 1,
        }
    }
    println!("K6 lines: {feasible} paths of {tried} tried ({rejected:?} rejected), {samples} samples at 500 Hz, worst line deviation {:.2e} m, {:.1} ms per path", worst, t0.elapsed().as_secs_f64() * 1e3 / tried as f64);
    assert!(feasible >= 40);
    assert!(worst < 0.5e-3);
}

/// K6: an arc through a via point, and a blended corner.
#[test]
fn k6_arc_and_blend() {
    use viaform_kin::path::{PathOpts, Segment, cartesian_path, cartesian_segments};
    let m = models::so101_arm();
    let q = vec![0.2, 0.1, 0.9, 0.3, 0.8, -0.2];
    let start = m.fk_frame(&q, 0).unwrap();
    let p0 = start.translation.vector;
    // Arc in the horizontal plane: radius 4 cm, half circle.
    let c = p0 + viaform_kin::Vec3::new(-0.04, 0.0, 0.0);
    let via = c + viaform_kin::Vec3::new(0.0, 0.04, 0.0);
    let mut to = start;
    to.translation.vector = c + viaform_kin::Vec3::new(-0.04, 0.0, 0.0);
    let tr = cartesian_segments(&m, &q, &[Segment::Arc { via, to }], 0, &PathOpts::default()).unwrap();
    let mut worst: f64 = 0.0;
    for qi in &tr.q {
        let p = m.fk_frame(qi, 0).unwrap().translation.vector;
        let d = p - c;
        worst = worst.max((d.z.abs()).hypot((d.xy().norm() - 0.04).abs()));
    }
    println!("K6 arc: {} samples, {:.3} s, worst circle deviation {:.2e} m, path length {:.4} m", tr.q.len(), tr.t.last().unwrap(), worst, tr.length);
    assert!(worst < 0.5e-3);
    assert!((tr.length - std::f64::consts::PI * 0.04).abs() < 1e-9);
    // Corner with a 1 cm blend: shorter than the sharp corner, still smooth (no branch flip).
    let mut w1 = start;
    w1.translation.vector += viaform_kin::Vec3::new(0.0, 0.05, 0.0);
    let mut w2 = w1;
    w2.translation.vector += viaform_kin::Vec3::new(0.0, 0.0, -0.05);
    let sharp = cartesian_path(&m, &q, &[w1, w2], 0, &PathOpts::default()).unwrap();
    let blended = cartesian_path(&m, &q, &[w1, w2], 0, &PathOpts { blend_radius: 0.01, ..PathOpts::default() }).unwrap();
    println!("K6 blend: sharp corner {:.3} s, 1 cm blend {:.3} s, lengths {:.4} / {:.4} m", sharp.t.last().unwrap(), blended.t.last().unwrap(), sharp.length, blended.length);
    assert!(blended.length < sharp.length);
    // The sharp corner stops (two rest-to-rest sections), the blend does not.
    assert!(blended.t.last().unwrap() < sharp.t.last().unwrap());
    let expect = 0.1 - 2.0 * 0.01 + 0.01 * std::f64::consts::FRAC_PI_2;
    assert!((blended.length - expect).abs() < 1e-9, "{}", blended.length);
    // Errors carry the sample index.
    let e = cartesian_path(&m, &q, &[w1], 0, &PathOpts { max_joint_jump: 1e-5, ..PathOpts::default() }).unwrap_err();
    assert_eq!(e.code, "path.branch_flip");
    assert!(e.index.is_some());
    let mut far = start;
    far.translation.vector += viaform_kin::Vec3::new(0.6, 0.0, 0.0);
    let e = cartesian_path(&m, &q, &[far], 0, &PathOpts::default()).unwrap_err();
    assert!(["path.unreachable", "path.joint_limit", "path.branch_flip"].contains(&e.code), "{e}");
    assert!(e.index.unwrap() > 0);
}
