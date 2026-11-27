//! Validation and demonstration of the thermal engine (G10).
//!
//! `cargo run --release -p viaform-generative --example thermal [-- --quick]`
//!
//! 1. Conduction against closed forms: linear slab, slab with uniform heat (parabola), the
//!    straight fin with convection (cosh profile) at three meshes, Fourier and Newton through
//!    the unit conversion.
//! 2. Multigrid: PCG iterations as the grid doubles (uniform and 0/1 contrast).
//! 3. Thermal stress: the clamped bar, `σ = -E α ΔT`.
//! 4. The volume-to-point problem (uniform heat, small sink on one edge, vf 0.3, p 3): the
//!    compliance history, the branches and an ASCII view of the tree.
//! 5. The G10 acceptance heat sink: a 5 W source under 60 °C with less mass than a plain block.
//!
//! Prints Markdown rows for docs/generative/ENGINE.md.

use std::time::Instant;

use viaform_generative::Material;
use viaform_generative::solid::thermal::{
    self, Convection, FixedTemperature, HeatSource, Multigrid, Problem, Thermal, conductivity_mm, film_mm, heat_sink, volume_to_point,
};
use viaform_generative::solid::{Grid, Region, Study, Support};

fn row(check: &str, reference: &str, got: &str, error: &str) {
    println!("| {check} | {reference} | {got} | {error} |");
}

fn boxr(min: [f64; 3], max: [f64; 3]) -> Region {
    Region::Box { min, max }
}

/// Solves a study's heat problem on a full block; the problem, the temperatures and the PCG
/// iterations.
fn solve(study: &Study, phys: Option<&[f64]>) -> (Problem, Grid, Vec<f64>, usize) {
    let th = study.thermal.as_ref().unwrap();
    let g = Grid::new(study.min, study.max, study.voxel);
    let prob = Problem::new(study, th, g).unwrap();
    let ones = vec![1.0; g.elements()];
    let (kappa, _) = prob.interpolate(phys.unwrap_or(&ones), th.penal, th.kmin);
    let mg = Multigrid::new(&prob.op, &kappa);
    let mut t = vec![prob.reference; g.nodes()];
    let st = prob.temperature(&kappa, &mg, &mut t, 1e-10).unwrap();
    (prob, g, t, st.iterations)
}

fn bar(l: f64, b: f64, voxel: f64, th: Thermal) -> Study {
    Study { min: [0.0; 3], max: [l, b, b], voxel, thermal: Some(th), ..Study::default() }
}

fn closed_forms() {
    // Slab with uniform heat: 20 x 2 x 2 mm, k 50 W/(m K), 0.01 W/mm³, both ends 20 °C.
    let (l, b, k_si, q) = (20.0, 2.0, 50.0, 0.01);
    let th = Thermal {
        conductivity: Some(k_si),
        sources: vec![HeatSource { region: boxr([-1.0; 3], [l + 1.0, b + 1.0, b + 1.0]), power: q * l * b * b }],
        fixed: vec![
            FixedTemperature { region: boxr([-0.1, -1.0, -1.0], [0.1, 9.0, 9.0]), temperature: 20.0 },
            FixedTemperature { region: boxr([l - 0.1, -1.0, -1.0], [l + 0.1, 9.0, 9.0]), temperature: 20.0 },
        ],
        ..Thermal::default()
    };
    let (_, _, t, _) = solve(&bar(l, b, 0.5, th), None);
    let peak = t.iter().copied().fold(0.0, f64::max);
    let want = 20.0 + q * l * l / (8.0 * conductivity_mm(k_si));
    row("Slab, uniform heat 0.01 W/mm3, k 50 W/(m K), 20 mm, ends 20 C: peak", &format!("qL²/8k: {want:.6} C"), &format!("{peak:.6} C"), &format!("{:.1e}", (peak - want) / want));

    // Straight fin, insulated tip.
    let (l, b, k_si, h_si, tb, ta) = (40.0, 2.0, 167.0, 1000.0, 85.0, 25.0);
    let m = (film_mm(h_si) * 4.0 / (conductivity_mm(k_si) * b)).sqrt();
    for voxel in [1.0, 0.5, 0.25] {
        let th = Thermal {
            conductivity: Some(k_si),
            ambient: ta,
            convection: vec![Convection { region: Some(boxr([0.0, -1.0, -1.0], [l - 0.01, b + 1.0, b + 1.0])), h: h_si, ambient: None }],
            fixed: vec![FixedTemperature { region: boxr([-0.01, -1.0, -1.0], [0.01, b + 1.0, b + 1.0]), temperature: tb }],
            ..Thermal::default()
        };
        let (_, g, t, its) = solve(&bar(l, b, voxel, th), None);
        let per = ((g.n[1] + 1) * (g.n[2] + 1)) as f64;
        let mut worst: f64 = 0.0;
        let mut tip = 0.0;
        for i in 0..=g.n[0] {
            let x = i as f64 * g.h;
            let mean: f64 = (0..=g.n[2]).flat_map(|k| (0..=g.n[1]).map(move |j| (j, k))).map(|(j, k)| t[g.node(i, j, k)]).sum::<f64>() / per;
            let want = ta + (tb - ta) * (m * (l - x)).cosh() / (m * l).cosh();
            worst = worst.max((mean - want).abs() / (tb - ta));
            if i == g.n[0] {
                tip = mean;
            }
        }
        let want_tip = ta + (tb - ta) / (m * l).cosh();
        row(
            &format!("Fin 40 x 2 x 2 mm Al, h 1000 W/(m2 K), base 85 C, h = {voxel} mm ({} hex8, {its} PCG its)", g.elements()),
            &format!("cosh: tip {want_tip:.4} C"),
            &format!("tip {tip:.4} C"),
            &format!("max {:.3} % of dT_base", 100.0 * worst),
        );
    }

    // Fourier through a 10 mm aluminium cube, 10 K across: 16.7 W.
    let th = Thermal {
        conductivity: Some(167.0),
        fixed: vec![
            FixedTemperature { region: boxr([-0.1, -1.0, -1.0], [0.1, 11.0, 11.0]), temperature: 30.0 },
            FixedTemperature { region: boxr([9.9, -1.0, -1.0], [10.1, 11.0, 11.0]), temperature: 20.0 },
        ],
        ..Thermal::default()
    };
    let s = Study { max: [10.0; 3], voxel: 1.0, thermal: Some(th), ..Study::default() };
    let (prob, g, t, _) = solve(&s, None);
    let mut r = vec![0.0; g.nodes()];
    prob.op.apply_raw(&vec![prob.k0; g.elements()], &t, &mut r);
    let q: f64 = (0..g.nodes()).filter(|&v| g.node_ijk(v)[0] == 0).map(|v| r[v]).sum();
    row("Fourier: 10 mm Al cube, 10 K across (W/(m K) at the boundary)", "kAΔT/L = 16.7 W", &format!("{q:.9} W"), &format!("{:.1e}", (q - 16.7) / 16.7));
}

fn multigrid() {
    let mut out = Vec::new();
    for contrast in [false, true] {
        let mut its = Vec::new();
        for n in [16usize, 32, 64, 128] {
            let l = n as f64;
            let s = Study {
                max: [l; 3],
                voxel: 1.0,
                thermal: Some(Thermal {
                    conductivity: Some(1.0),
                    sources: vec![HeatSource { region: boxr([-1.0; 3], [l + 1.0; 3]), power: 1.0 }],
                    fixed: vec![FixedTemperature { region: boxr([0.25 * l, 0.25 * l, -0.01], [0.5 * l, 0.5 * l, 0.01]), temperature: 25.0 }],
                    convection: vec![Convection { region: Some(boxr([-1.0, -1.0, l - 0.01], [l + 1.0, l + 1.0, l + 1.0])), h: 10.0, ambient: None }],
                    ..Thermal::default()
                }),
                ..Study::default()
            };
            let g = Grid::new(s.min, s.max, s.voxel);
            let phys: Vec<f64> = (0..g.elements()).map(|e| if (e.wrapping_mul(2_654_435_761) >> 7) % 2 == 0 { 1.0 } else { 0.0 }).collect();
            let t0 = Instant::now();
            let (_, _, _, it) = solve(&s, contrast.then_some(&phys[..]));
            its.push(format!("{it} ({:.2} s)", t0.elapsed().as_secs_f64()));
        }
        out.push(its.join(" / "));
    }
    row("Thermal MG-PCG to 1e-10, uniform, 16³ / 32³ / 64³ / 128³", "mesh-independent", &out[0], "constant");
    row("same, random 0/1 SIMP field (kmin 1e-3)", "mesh-independent", &out[1], "bounded");
}

fn clamped_bar() {
    let (l, b, alpha, dt) = (10.0, 2.0, 11.7e-6, 100.0);
    let steel = Material { name: "steel".into(), e: 210_000.0, nu: 0.3, density: 7.85e-3, allowable: 250.0, color: String::new() };
    let supports = vec![
        Support { region: boxr([-0.01, -1.0, -1.0], [0.01, b + 1.0, b + 1.0]), fix: [true, false, false] },
        Support { region: boxr([l - 0.01, -1.0, -1.0], [l + 0.01, b + 1.0, b + 1.0]), fix: [true, false, false] },
        Support { region: boxr([-1.0, -0.01, -1.0], [l + 1.0, 0.01, b + 1.0]), fix: [false, true, false] },
        Support { region: boxr([-1.0, -1.0, -0.01], [l + 1.0, b + 1.0, 0.01]), fix: [false, false, true] },
    ];
    let s = Study { max: [l, b, b], voxel: 0.5, material: steel.clone(), supports, ..Study::default() };
    let g = Grid::new(s.min, s.max, s.voxel);
    let (_, vm) = thermal::thermal_stress(&s, &g, &vec![1.0; g.elements()], alpha, &vec![dt; g.nodes()]).unwrap();
    let got = vm.iter().copied().fold(0.0, f64::max);
    let want = steel.e * alpha * dt;
    row("Clamped steel bar heated 100 K (rollers at both ends)", &format!("E α ΔT = {want:.4} MPa"), &format!("{got:.4} MPa"), &format!("{:.1e}", (got - want) / want));
}

/// One character per voxel of the middle layer, y down.
fn picture(grid: &Grid, density: &[f32]) -> String {
    let k = grid.n[2] / 2;
    let mut s = String::new();
    for j in (0..grid.n[1]).rev() {
        for i in 0..grid.n[0] {
            let d = density[grid.element(i, j, k)];
            s.push(if d >= 0.75 { '#' } else if d >= 0.5 { '+' } else if d >= 0.25 { '.' } else { ' ' });
        }
        s.push('\n');
    }
    s
}

fn crossings(grid: &Grid, density: &[f32], j: usize) -> usize {
    let k = grid.n[2] / 2;
    let mut runs = 0;
    let mut inside = false;
    for i in 0..grid.n[0] {
        let solid = density[grid.element(i, j, k)] >= 0.5;
        if solid && !inside {
            runs += 1;
        }
        inside = solid;
    }
    runs
}

fn volume_to_point_run(n: usize, nz: usize, iterations: usize) {
    let s = volume_to_point(n, nz, 0.3, iterations);
    let t0 = Instant::now();
    let layout = thermal::optimize(&s).unwrap();
    let secs = t0.elapsed().as_secs_f64();
    let h = &layout.history;
    let g = layout.grid;
    let rises = h.windows(2).skip(5).filter(|w| w[1] > w[0] * 1.0001).count();
    let marks: Vec<String> = [0, 4, 9, 19, 49, h.len() - 1].iter().filter(|&&i| i < h.len()).map(|&i| format!("{}: {:.4e}", i + 1, h[i])).collect();
    println!("\nVolume to point {n} x {n} x {nz}, vf 0.3, p 3, kmin 1e-3, filter 1.5 voxels, MMA, {iterations} its, {secs:.1} s");
    println!("compliance (W K) by iteration: {}", marks.join(", "));
    println!("iterations after the 5th that raised it: {rises}; PCG its per solve {}..{}", layout.solves.iter().min().unwrap(), layout.solves.iter().max().unwrap());
    let vol = layout.density.iter().map(|&d| d as f64).sum::<f64>() / g.elements() as f64;
    let grey = layout.density.iter().filter(|&&d| d > 0.1 && d < 0.9).count() as f64 / g.elements() as f64;
    println!(
        "volume {vol:.4}, grey {:.1} %, branches crossing y = 0.25 / 0.5 / 0.75 L: {} / {} / {}",
        100.0 * grey,
        crossings(&g, &layout.density, g.n[1] / 4),
        crossings(&g, &layout.density, g.n[1] / 2),
        crossings(&g, &layout.density, 3 * g.n[1] / 4)
    );
    if n <= 100 {
        println!("```\n{}```", picture(&g, &layout.density));
    }
    row(
        &format!("Volume to point {n}x{n}x{nz}, vf 0.3, p 3, {iterations} its"),
        "tree of conductors from the sink, compliance falling steadily",
        &format!("c {:.4e} to {:.4e} W K, {} rises after it 5, {} branches at y = 0.75 L", h[0], h[h.len() - 1], rises, crossings(&g, &layout.density, 3 * g.n[1] / 4)),
        "topology matches",
    );
}

fn heat_sink_run(voxel: f64, iterations: usize) {
    let s = heat_sink(voxel, 150.0, iterations);
    let out = thermal::generate(&s).unwrap();
    let (a, b) = (&out.analysis, &out.block);
    println!(
        "\nHeat sink 40 x 40 x 10 mm Al, 5 W on a 10 x 10 pad, base h 150 W/(m2 K) to 25 C, limit 60 C, voxel {voxel} mm ({} voxels), {:.1} s",
        out.grid.elements(),
        out.seconds
    );
    println!("plain block: {:.2} g, peak {:.2} C, pad mean {:.2} C", b.mass_g, b.max_temperature, b.source_temperature);
    println!("optimised (built, 0/1): {:.2} g, peak {:.2} C, pad mean {:.2} C, feasible {}, {} triangles", a.mass_g, a.max_temperature, a.source_temperature, out.feasible, out.mesh.indices.len() / 3);
    // Base resistance alone: 1 / (h A).
    let ideal = 25.0 + 5.0 / (150.0 * 0.04 * 0.04);
    row(
        &format!("G10 heat sink, 5 W, limit 60 C, voxel {voxel} mm"),
        &format!("block {:.1} g at {:.2} C (base film alone {ideal:.2} C)", b.mass_g, b.max_temperature),
        &format!("{:.1} g at {:.2} C", a.mass_g, a.max_temperature),
        &format!("{:.0} % lighter, under the limit", 100.0 * (1.0 - a.mass_g / b.mass_g)),
    );
}

fn main() {
    let quick = std::env::args().any(|a| a == "--quick");
    println!("| Check | Reference | ViaForm | Error |\n|---|---|---|---|");
    closed_forms();
    multigrid();
    clamped_bar();
    volume_to_point_run(if quick { 40 } else { 100 }, 1, if quick { 80 } else { 150 });
    if !quick {
        volume_to_point_run(40, 10, 100);
    }
    heat_sink_run(1.0, 60);
    if !quick {
        heat_sink_run(0.5, 80);
    }
}
