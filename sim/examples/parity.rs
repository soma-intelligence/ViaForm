//! Prints the same digest of a few seeded flights as the TypeScript reference did, so the port
//! can be diffed run against run: `cargo run --release -p viaform-sim --example parity`.

use viaform_sim::control::RateLoop;
use viaform_sim::flight::*;
use viaform_sim::realism::REALISTIC;
use viaform_sim::train::*;
use viaform_sim::weather::weathers;
use viaform_sim::world::obstacle_course;

fn main() {
    let w = weathers();
    let p = quad3_default();
    let mut hover_real = Scenario::new(w[2].clone(), Mission::Hover { at: [0.0, 0.0, 1.6] }, 5.0, 4.0);
    hover_real.realism = Some(REALISTIC.clone());
    let cases: Vec<(&str, Brain, Scenario)> = vec![
        ("hover-pid", pid_only(viaform_sim::control::DEFAULT_GAINS), Scenario::new(w[0].clone(), Mission::Hover { at: [0.0, 0.0, 1.6] }, 5.0, 3.0)),
        ("hover-real", pid_only(viaform_sim::control::DEFAULT_GAINS), hover_real),
        ("track-nn", trained(true), tracking_scenario(5.0, 7.0)),
        ("stress-pid", stable(RateLoop::Pid), stress_bench(1.0, w[3].clone(), REALISTIC.clone())),
        ("stress-indi", stable(RateLoop::Indi), stress_bench(2.0, w[5].clone(), REALISTIC.clone())),
        ("real-2", stable(RateLoop::Pid), realistic_scenario(2.0)),
        ("real-3", stable(RateLoop::Indi), realistic_scenario(3.0)),
        ("course", trained(true), Scenario::new(w[1].clone(), Mission::Waypoints { course: obstacle_course() }, 40.0, 1.0)),
    ];
    let only = std::env::args().nth(1);
    for (name, brain, sc) in cases {
        if only.as_deref().is_some_and(|o| o != name) {
            continue;
        }
        let mut f = Flight::new(&p, brain.clone(), sc.clone());
        while !f.finished() {
            f.tick();
        }
        let r = run_episode(&p, brain, sc);
        let back = r.recoveries.iter().filter(|x| x.recovered_after.is_some()).count();
        println!(
            "{name} {:.3} {} {} {} {} {} {} {back}/{}",
            f.s.t,
            f.s.p.iter().map(|x| js17(*x)).collect::<Vec<_>>().join(","),
            js17(r.rms_error),
            js17(r.attitude_rms),
            r.crashed,
            r.collided,
            r.completed,
            r.recoveries.len()
        );
    }
}

/// `toPrecision(17)` as JavaScript prints it.
fn js17(x: f64) -> String {
    if x == 0.0 {
        return "0.0000000000000000".into();
    }
    let e = x.abs().log10().floor() as i32;
    if !(-7..21).contains(&e) {
        let s = format!("{:.16e}", x);
        let (m, ex) = s.split_once('e').unwrap();
        let ex: i32 = ex.parse().unwrap();
        return format!("{m}e{}{}", if ex >= 0 { "+" } else { "-" }, ex.abs());
    }
    format!("{:.*}", (16 - e).max(0) as usize, x)
}
