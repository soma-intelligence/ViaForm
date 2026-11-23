//! Time per optimiser iteration at about 100k, 400k and 1M voxels on this machine.
//!
//! `cargo run --release -p viaform-generative --example bench [-- 100k 400k 1m]`
//!
//! A cantilever (clamped face, tip load), compliance under a 0.3 volume fraction, density filter
//! radius 1.5 voxels, Heaviside projection. Per size: one matrix-free product `K u`, the
//! multigrid setup, one solve from zero (uniform 0.3 SIMP field), and four optimiser iterations
//! (solve warm-started, sensitivities, filter and chain back, MMA). Each figure is the least of
//! three repetitions (a busy machine slows the small sizes most), and the machine's load average
//! is printed with them.

use std::time::Instant;

use viaform_generative::solid::fem::Operator;
use viaform_generative::solid::mg::Hierarchy;
use viaform_generative::solid::optimize::optimize_traced;
use viaform_generative::solid::{Grid, Load, LoadCase, Region, Study, Support, loads};

fn study(n: [usize; 3]) -> Study {
    let max = n.map(|v| v as f64);
    Study {
        min: [0.0; 3],
        max,
        voxel: 1.0,
        supports: vec![Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, max[1] + 1.0, max[2] + 1.0] }, fix: [true; 3] }],
        cases: vec![LoadCase {
            name: "tip".into(),
            loads: vec![Load::Force { region: Region::Box { min: [max[0] - 0.1, -1.0, 0.4 * max[2]], max: [max[0] + 0.1, max[1] + 1.0, 0.6 * max[2]] }, force: [0.0, 0.0, -1000.0] }],
            acceleration: None,
            weight: 1.0,
        }],
        volume_fraction: 0.3,
        min_member: 2.5,
        iterations: 4,
        ..Study::default()
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let all = [("100k", [80usize, 40, 32]), ("400k", [128, 64, 48]), ("1m", [160, 80, 80])];
    let pick: Vec<_> = all.iter().filter(|(k, _)| args.is_empty() || args.iter().any(|a| a.eq_ignore_ascii_case(k))).collect();
    let load = std::process::Command::new("sysctl").args(["-n", "vm.loadavg"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
    println!("threads: {}, load average {load}", rayon::current_num_threads());
    println!("| Voxels | Grid | DOFs | K u | MG setup | Solve (its) | Iteration (mean of 2-4) | First iteration | (least of 3 runs)");
    println!("|---|---|---|---|---|---|---|---|");
    for (_, n) in pick {
        let s = study(*n);
        let g = Grid::new(s.min, s.max, s.voxel);
        let op = Operator::new(g, s.material.nu, loads::fixed_dofs(&g, &s.supports));
        let f = loads::applied(&g, &s.cases[0]);
        let young: Vec<f64> = vec![s.material.e * (1e-9 + 0.3f64.powi(3)); g.elements()];
        let u = vec![1e-3; g.dofs()];
        let mut out = vec![0.0; g.dofs()];
        op.apply(&young, &u, &mut out);
        let (mut apply, mut setup, mut solve, mut mean, mut first) = (f64::INFINITY, f64::INFINITY, f64::INFINITY, f64::INFINITY, f64::INFINITY);
        let mut its = 0;
        for _ in 0..3 {
            let t = Instant::now();
            for _ in 0..10 {
                op.apply(&young, &u, &mut out);
            }
            apply = apply.min(t.elapsed().as_secs_f64() / 10.0);
            let t = Instant::now();
            let hier = Hierarchy::new(&op, &young);
            setup = setup.min(t.elapsed().as_secs_f64());
            let mut x = vec![0.0; g.dofs()];
            let t = Instant::now();
            let st = hier.solve(&f, &mut x, 1e-5, 600).unwrap();
            solve = solve.min(t.elapsed().as_secs_f64());
            its = st.iterations;
            drop(hier);
            let (_, tr) = optimize_traced(&s, s.volume_fraction, &mut |_, _| {}).unwrap();
            let rest = &tr.seconds[1..];
            mean = mean.min(rest.iter().sum::<f64>() / rest.len().max(1) as f64);
            first = first.min(tr.seconds[0]);
        }
        println!(
            "| {} | {}x{}x{} | {} | {:.1} ms | {:.2} s | {:.2} s ({}) | {:.2} s | {:.2} s |",
            g.elements(),
            n[0],
            n[1],
            n[2],
            g.dofs(),
            apply * 1e3,
            setup,
            solve,
            its,
            mean,
            first
        );
    }
}
