//! Retunes the stabilization gains on the realistic plant (the port of
//! electron/scripts/train-stabilize.mjs) and prints the constants for sim/src/stable.rs:
//! `cargo run --release -p viaform-sim --example train_stable -- [iterations]`.

use viaform_sim::control::{DEFAULT_GAINS, Gains, RateLoop};
use viaform_sim::flight::{Brain, pid_only, quad3_default, stable, trained};
use viaform_sim::flight::run_episode;
use viaform_sim::realism::REALISTIC;
use viaform_sim::train::{TuneOptions, cost, realistic_scenario, stress_bench, tune_gains};
use viaform_sim::weather::weathers;

/// The stress bench as the tests run it: attitude RMS (rad) and recoveries, per brain and weather.
fn bench(p: &viaform_sim::physics::QuadParams, label: &str, brains: [(&str, Brain); 2]) {
    for (name, b) in brains {
        for w in weathers().into_iter().take(3) {
            let r = run_episode(p, b.clone(), stress_bench(3.0, w.clone(), REALISTIC.clone()));
            let back = r.recoveries.iter().filter(|x| x.recovered_after.is_some()).count();
            let dev = r.recoveries.iter().map(|x| x.max_deviation).fold(0.0, f64::max);
            println!("{label} bench {name} {}: attitude rms {:.4}, {back}/{} recovered, max deviation {dev:.2} m, crashed {}", w.name, r.attitude_rms, r.recoveries.len(), r.crashed);
        }
    }
}

fn main() {
    let iterations: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(16);
    let p = quad3_default();
    let start = trained(false).gains;
    let test: Vec<_> = (0..40).map(|i| realistic_scenario(7_000_000.0 + i as f64)).collect();
    let score = |b: &Brain| cost(&p, b, &test);
    println!(
        "before: default {:.5} first training {:.5} stable PID {:.5} stable INDI {:.5}",
        score(&pid_only(DEFAULT_GAINS)), score(&trained(false)), score(&stable(RateLoop::Pid)), score(&stable(RateLoop::Indi))
    );
    bench(&p, "before", [("PID", stable(RateLoop::Pid)), ("INDI", stable(RateLoop::Indi))]);
    let t0 = std::time::Instant::now();
    let tune = |rl: RateLoop, seed: f64| {
        tune_gains(&p, TuneOptions {
            iterations, population: 20, episodes: 12, seed, init: start, rate_loop: rl, rate_int_max: Some(50.0),
            scenario: Box::new(realistic_scenario),
            log: Box::new(move |l| println!("{rl:?} {:3} cost {:.3} mean {:.3} {:.0} s", l.iteration, l.cost, l.baseline, t0.elapsed().as_secs_f64())),
            ..Default::default()
        })
    };
    let pid = tune(RateLoop::Pid, 31.0);
    let indi = tune(RateLoop::Indi, 37.0);
    let brain = |g: Gains, rl| Brain { gains: g, policy: None, rate_loop: rl, rate_int_max: Some(50.0) };
    let s = [score(&pid_only(DEFAULT_GAINS)), score(&trained(false)), score(&brain(pid, RateLoop::Pid)), score(&brain(indi, RateLoop::Indi))];
    bench(&p, "after", [("PID", brain(pid, RateLoop::Pid)), ("INDI", brain(indi, RateLoop::Indi))]);
    println!("after: default {:.5} first training {:.5} stable PID {:.5} stable INDI {:.5}", s[0], s[1], s[2], s[3]);
    let r = |x: f64| (x * 1e5).round() / 1e5;
    let g = |g: Gains| {
        let a = g.to_array().map(r);
        format!(
            "Gains {{ pos_p: {}, vel_p: {}, vel_i: {}, vel_d: {}, att_p: {}, yaw_p: {}, rate_p: {}, rate_i: {}, rate_d: {}, yaw_rate_p: {} }}",
            a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]
        )
    };
    println!("pub const STABLE_PID: Gains = {};", g(pid));
    println!("pub const STABLE_INDI: Gains = {};", g(indi));
    println!("pub const STABLE_SCORE: [f64; 4] = [{}, {}, {}, {}];", r(s[0]), r(s[1]), r(s[2]), r(s[3]));
}
