//! Validation of the 3D engine against closed forms and published benchmarks.
//!
//! `cargo run --release -p viaform-generative --example validate [-- --quick]`
//!
//! 1. FEM: cantilever tip deflection against Timoshenko beam theory, three meshes.
//! 2. Modes: first bending frequency of a slender cantilever against Euler-Bernoulli.
//! 3. MMA: Svanberg's two-ball toy problem and his five-variable cantilever.
//! 4. Multigrid: PCG iterations as the grid doubles (uniform and SIMP 0/1 contrast).
//! 5. Topology: the top3d cantilever (Liu and Tovar 2014) by a line-for-line port of top3d's OC
//!    loop on this FEM, and by the engine (MMA) at the same volume fraction, penalty and filter;
//!    a 3D MBB half beam the same way; the PETSc TopOpt default (Aage, Andreassen and Lazarov
//!    2015) by the engine.
//!
//! Prints a Markdown table for docs/generative/ENGINE.md.

use std::time::Instant;

use viaform_generative::Material;
use viaform_generative::solid::fem::{Operator, lumped_mass};
use viaform_generative::solid::mg::Hierarchy;
use viaform_generative::solid::mma::Mma;
use viaform_generative::solid::optimize::{Trace, optimize_traced};
use viaform_generative::solid::{Grid, Load, LoadCase, Region, Study, Support, dynamics, loads};

fn rows() -> &'static std::sync::Mutex<Vec<String>> {
    static ROWS: std::sync::OnceLock<std::sync::Mutex<Vec<String>>> = std::sync::OnceLock::new();
    ROWS.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

fn row(check: &str, reference: &str, got: &str, error: &str) {
    let r = format!("| {check} | {reference} | {got} | {error} |");
    println!("{r}");
    rows().lock().unwrap().push(r);
}

fn material(e: f64, nu: f64, density: f64) -> Material {
    Material { name: "test".into(), e, nu, density, allowable: 1.0, ..Material::default() }
}

/// A prismatic cantilever along x, clamped over x = 0, `force` spread over the x = L face.
fn beam(n: [usize; 3], h: f64, force: [f64; 3]) -> (Grid, Vec<bool>, Vec<f64>) {
    let l = n[0] as f64 * h;
    let g = Grid::new([0.0; 3], [l, n[1] as f64 * h, n[2] as f64 * h], h);
    let big = 1e6;
    let fixed = loads::fixed_dofs(&g, &[Support { region: Region::Box { min: [-0.1 * h, -big, -big], max: [0.1 * h, big, big] }, fix: [true; 3] }]);
    let case = LoadCase { name: "tip".into(), loads: vec![Load::Force { region: Region::Box { min: [l - 0.1 * h, -big, -big], max: [l + 0.1 * h, big, big] }, force }], acceleration: None, weight: 1.0 };
    (g, fixed, loads::applied(&g, &case))
}

fn fem_cantilever() {
    // 80 x 10 x 10 mm steel, 100 N down at the tip. Timoshenko: PL³/3EI + PL/κGA.
    let (p, l, b, d, e, nu): (f64, f64, f64, f64, f64, f64) = (100.0, 80.0, 10.0, 10.0, 200_000.0, 0.3);
    let i = b * d.powi(3) / 12.0;
    let kappa = 10.0 * (1.0 + nu) / (12.0 + 11.0 * nu);
    let want = p * l.powi(3) / (3.0 * e * i) + p * l / (kappa * e / (2.0 * (1.0 + nu)) * b * d);
    let mut got = Vec::new();
    for h in [1.0, 0.5, 0.25] {
        let n = [(l / h) as usize, (b / h) as usize, (d / h) as usize];
        let (g, fixed, f) = beam(n, h, [0.0, 0.0, -p]);
        let op = Operator::new(g, nu, fixed);
        let young = vec![e; g.elements()];
        let mut u = vec![0.0; g.dofs()];
        let t = Instant::now();
        let s = Hierarchy::new(&op, &young).solve(&f, &mut u, 1e-10, 500).unwrap();
        let tip: Vec<usize> = (0..g.nodes()).filter(|&v| g.node_ijk(v)[0] == g.n[0]).collect();
        let w = -tip.iter().map(|&v| u[3 * v + 2]).sum::<f64>() / tip.len() as f64;
        row(
            &format!("FEM tip deflection, h = {h} mm ({} hex8, {} PCG its, {:.2} s)", g.elements(), s.iterations, t.elapsed().as_secs_f64()),
            &format!("Timoshenko {want:.5} mm"),
            &format!("{w:.5} mm"),
            &format!("{:+.2} %", 100.0 * (w / want - 1.0)),
        );
        got.push(w);
    }
    let rich = (4.0 * got[2] - got[1]) / 3.0;
    row("FEM tip deflection, Richardson h 0.5 / 0.25", &format!("Timoshenko {want:.5} mm"), &format!("{rich:.5} mm"), &format!("{:+.2} %", 100.0 * (rich / want - 1.0)));
}

fn first_frequency() {
    // 200 x 10 x 10 mm aluminium (L/d = 20, shear and rotary inertia under 0.2 %).
    let (l, b, d, e, nu, rho): (f64, f64, f64, f64, f64, f64) = (200.0, 10.0, 10.0, 69_000.0, 0.33, 2.7e-9);
    let i = b * d.powi(3) / 12.0;
    let a = b * d;
    let beta = 1.875_104_068_711_961;
    let want = beta * beta / (2.0 * std::f64::consts::PI) * (e * i / (rho * a * l.powi(4))).sqrt();
    for h in [1.0, 0.5] {
        let n = [(l / h) as usize, (b / h) as usize, (d / h) as usize];
        let (g, fixed, _) = beam(n, h, [0.0, 0.0, -1.0]);
        let op = Operator::new(g, nu, fixed);
        let young = vec![e; g.elements()];
        let hier = Hierarchy::new(&op, &young);
        let mass = lumped_mass(&g, &vec![rho; g.elements()]);
        let t = Instant::now();
        let modes = dynamics::eigen(&op, &young, &hier, &mass, 2, None, 60, 1e-8).unwrap();
        let f = modes[0].frequency();
        let f2 = modes[1].frequency();
        row(
            &format!("First bending frequency, h = {h} mm ({} hex8, lumped mass, {:.1} s)", g.elements(), t.elapsed().as_secs_f64()),
            &format!("Euler-Bernoulli {want:.2} Hz"),
            &format!("{f:.2} Hz (pair: {f2:.2} Hz)"),
            &format!("{:+.2} %", 100.0 * (f / want - 1.0)),
        );
    }
}

fn mma_checks() {
    // Svanberg's toy problem (mmasub documentation): min x1² + x2² + x3² in two balls of radius 3
    // about (5, 2, 1) and (3, 4, 3), 0 <= x <= 5, from (4, 3, 2).
    let mut x = vec![4.0, 3.0, 2.0];
    let (xmin, xmax) = (vec![0.0; 3], vec![5.0; 3]);
    let mut mma = Mma::new(3, 2);
    let c = [[5.0, 2.0, 1.0], [3.0, 4.0, 3.0]];
    let mut its = 0;
    for k in 0..200 {
        let df0: Vec<f64> = x.iter().map(|v| 2.0 * v).collect();
        let g: Vec<f64> = c.iter().map(|c| (0..3).map(|a| (x[a] - c[a]).powi(2)).sum::<f64>() - 9.0).collect();
        let dg: Vec<Vec<f64>> = c.iter().map(|c| (0..3).map(|a| 2.0 * (x[a] - c[a])).collect()).collect();
        let before = x.clone();
        mma.update(&mut x, &xmin, &xmax, &df0, &g, &dg, 0.5);
        its = k + 1;
        if x.iter().zip(&before).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max) < 1e-9 {
            break;
        }
    }
    // KKT: stationarity with the multipliers MMA reports.
    let lam = mma.multipliers().to_vec();
    let grad: Vec<f64> = (0..3).map(|a| 2.0 * x[a] + lam[0] * 2.0 * (x[a] - c[0][a]) + lam[1] * 2.0 * (x[a] - c[1][a])).collect();
    let res = grad.iter().map(|v| v * v).sum::<f64>().sqrt();
    let g: Vec<f64> = c.iter().map(|c| (0..3).map(|a| (x[a] - c[a]).powi(2)).sum::<f64>() - 9.0).collect();
    let f: f64 = x.iter().map(|v| v * v).sum();
    row(
        "MMA, Svanberg two-ball toy problem",
        "x* = (2.0175, 1.7800, 1.2375) (mmasub documentation)",
        &format!("x = ({:.4}, {:.4}, {:.4}), f = {f:.4}, {its} its", x[0], x[1], x[2]),
        &format!("KKT residual {res:.1e}, g = ({:.1e}, {:.1e})", g[0], g[1]),
    );
    // Svanberg (1987) cantilever: min 0.0624 Σ x with Σ c/x³ <= 1, 1 <= x <= 10 from 5.
    let cc = [61.0f64, 37.0, 19.0, 7.0, 1.0];
    let s: f64 = cc.iter().map(|c| c.powf(0.25)).sum();
    let want = 0.0624 * s.powf(1.0 / 3.0) * s;
    let mut x: Vec<f64> = vec![5.0; 5];
    let mut mma = Mma::new(5, 1);
    let (xmin, xmax) = (vec![1.0; 5], vec![10.0; 5]);
    let mut its = 0;
    for k in 0..300 {
        let df0 = vec![0.0624; 5];
        let g = vec![cc.iter().zip(&x).map(|(c, x)| c / x.powi(3)).sum::<f64>() - 1.0];
        let dg = vec![cc.iter().zip(&x).map(|(c, x)| -3.0 * c / x.powi(4)).collect::<Vec<_>>()];
        let before = x.clone();
        mma.update(&mut x, &xmin, &xmax, &df0, &g, &dg, 1.0);
        its = k + 1;
        if x.iter().zip(&before).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max) < 1e-6 {
            break;
        }
    }
    let f = 0.0624 * x.iter().sum::<f64>();
    row("MMA, Svanberg 1987 five-segment cantilever", &format!("f* = {want:.4} (closed form)"), &format!("f = {f:.4}, {its} its"), &format!("{:+.4} %", 100.0 * (f / want - 1.0)));
}

fn multigrid() {
    for contrast in [false, true] {
        let mut its = Vec::new();
        for n in [[32usize, 16, 16], [64, 32, 32], [128, 64, 64]] {
            let (g, fixed, f) = beam(n, 1.0, [0.0, 0.0, -100.0]);
            let op = Operator::new(g, 0.3, fixed);
            let young: Vec<f64> = (0..g.elements())
                .map(|e| {
                    if !contrast {
                        return 200_000.0;
                    }
                    let [i, j, k] = g.element_ijk(e);
                    // A fixed pseudo-random 0/1 field (SIMP 1e-9 voids), clamped and loaded ends solid.
                    let hsh = (i.wrapping_mul(73_856_093) ^ j.wrapping_mul(19_349_663) ^ k.wrapping_mul(83_492_791)) % 100;
                    if i < 2 || i + 2 >= n[0] || hsh < 60 { 200_000.0 } else { 200_000.0 * 1e-9 }
                })
                .collect();
            let mut u = vec![0.0; g.dofs()];
            let t = Instant::now();
            let s = Hierarchy::new(&op, &young).solve(&f, &mut u, 1e-8, 2000).unwrap();
            its.push(format!("{:?}: {} ({:.2} s)", n, s.iterations, t.elapsed().as_secs_f64()));
        }
        row(
            &format!("Multigrid PCG to 1e-8, {}", if contrast { "SIMP 0/1 field (60 % solid, E_min 1e-9)" } else { "uniform" }),
            "mesh-independent iteration count",
            &its.join("; "),
            "",
        );
    }
}

/// Density filter with top3d's weights `max(0, rmin - dist)`.
struct Filter {
    nbr: Vec<Vec<(usize, f64)>>,
    hs: Vec<f64>,
}

impl Filter {
    fn new(g: &Grid, rmin: f64) -> Self {
        let r = rmin.ceil() as isize - 1;
        let nbr: Vec<Vec<(usize, f64)>> = (0..g.elements())
            .map(|e| {
                let [i, j, k] = g.element_ijk(e).map(|v| v as isize);
                let mut out = Vec::new();
                for dk in -r..=r {
                    for dj in -r..=r {
                        for di in -r..=r {
                            let (a, b, c) = (i + di, j + dj, k + dk);
                            if a < 0 || b < 0 || c < 0 || a >= g.n[0] as isize || b >= g.n[1] as isize || c >= g.n[2] as isize {
                                continue;
                            }
                            let w = rmin - ((di * di + dj * dj + dk * dk) as f64).sqrt();
                            if w > 0.0 {
                                out.push((g.element(a as usize, b as usize, c as usize), w));
                            }
                        }
                    }
                }
                out
            })
            .collect();
        let hs = nbr.iter().map(|n| n.iter().map(|(_, w)| w).sum()).collect();
        Self { nbr, hs }
    }
    fn apply(&self, x: &[f64]) -> Vec<f64> {
        self.nbr.iter().zip(&self.hs).map(|(n, h)| n.iter().map(|&(m, w)| w * x[m]).sum::<f64>() / h).collect()
    }
    /// Hᵀ (d ./ Hs): the filter's chain rule (H is symmetric).
    fn back(&self, d: &[f64]) -> Vec<f64> {
        let s: Vec<f64> = d.iter().zip(&self.hs).map(|(d, h)| d / h).collect();
        self.nbr.iter().map(|n| n.iter().map(|&(m, w)| w * s[m]).sum()).collect()
    }
}

/// top3d.m's loop, line for line: SIMP, density filter, optimality criteria, stop when no
/// variable moves more than `tolx` or after `maxloop`.
fn top3d_oc(g: Grid, fixed: Vec<bool>, f: &[f64], volfrac: f64, penal: f64, rmin: f64, maxloop: usize, tolx: f64) -> (f64, usize, Vec<f64>, f64) {
    let ne = g.elements();
    let op = Operator::new(g, 0.3, fixed);
    let filter = Filter::new(&g, rmin);
    let emin = 1e-9;
    let mut x = vec![volfrac; ne];
    let mut phys = x.clone();
    let mut u = vec![0.0; g.dofs()];
    let mut c = 0.0;
    let mut its = 0;
    let t = Instant::now();
    for it in 1..=maxloop {
        its = it;
        let young: Vec<f64> = phys.iter().map(|r| emin + r.powf(penal) * (1.0 - emin)).collect();
        Hierarchy::new(&op, &young).solve(f, &mut u, 1e-8, 1000).unwrap();
        let mut ce = vec![0.0; ne];
        op.energy(&u, &mut ce);
        c = ce.iter().zip(&young).map(|(a, b)| a * b).sum();
        let dc: Vec<f64> = phys.iter().zip(&ce).map(|(r, ce)| -penal * (1.0 - emin) * r.powf(penal - 1.0) * ce).collect();
        let dc = filter.back(&dc);
        let dv = filter.back(&vec![1.0; ne]);
        let (mut l1, mut l2, mv) = (0.0, 1e9, 0.2);
        let mut xnew = x.clone();
        while (l2 - l1) / (l1 + l2) > 1e-3 {
            let lmid = 0.5 * (l2 + l1);
            for e in 0..ne {
                let b = x[e] * (-dc[e] / dv[e] / lmid).max(0.0).sqrt();
                xnew[e] = (x[e] - mv).max(0.0).max((x[e] + mv).min(1.0).min(b));
            }
            phys = filter.apply(&xnew);
            if phys.iter().sum::<f64>() > volfrac * ne as f64 {
                l1 = lmid;
            } else {
                l2 = lmid;
            }
        }
        let change = xnew.iter().zip(&x).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        x = xnew;
        if change <= tolx {
            break;
        }
    }
    (c, its, phys, t.elapsed().as_secs_f64())
}

/// The voxels at density 0.5 or more, as a z-column count per (x, y): a side view.
fn side_view(g: &Grid, phys: &[f64], step: usize) -> String {
    let mut out = String::new();
    for j in (0..g.n[1]).rev().step_by(step) {
        for i in (0..g.n[0]).step_by(step) {
            let s = (0..g.n[2]).filter(|&k| phys[g.element(i, j, k)] >= 0.5).count();
            out.push(if s == 0 { ' ' } else if 2 * s < g.n[2] { '+' } else { '#' });
        }
        out.push('\n');
    }
    out
}

fn agreement(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).filter(|(x, y)| (**x >= 0.5) == (**y >= 0.5)).count() as f64 / a.len() as f64
}

fn grey(a: &[f64]) -> f64 {
    a.iter().filter(|x| (0.1..0.9).contains(*x)).count() as f64 / a.len() as f64
}

fn engine(study: &Study) -> (Trace, Vec<f64>, f64) {
    let t = Instant::now();
    let (l, tr) = optimize_traced(study, study.volume_fraction, &mut |_, _| {}).unwrap();
    (tr, l.density.iter().map(|&d| d as f64).collect(), t.elapsed().as_secs_f64())
}

fn top3d_benchmarks(quick: bool) {
    // top3d(60, 20, 4, 0.3, 3, 1.5): clamped at x = 0, unit downward loads (-y) on the nodes of
    // the bottom edge of the free end (x = 60, y = 0, z = 0..4). E = 1, ν = 0.3.
    let (nx, ny, nz) = (60usize, 20usize, 4usize);
    let g = Grid::new([0.0; 3], [nx as f64, ny as f64, nz as f64], 1.0);
    let supports = vec![Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, ny as f64 + 1.0, nz as f64 + 1.0] }, fix: [true; 3] }];
    let load = Load::Force { region: Region::Box { min: [nx as f64 - 0.1, -0.1, -0.1], max: [nx as f64 + 0.1, 0.1, nz as f64 + 0.1] }, force: [0.0, -((nz + 1) as f64), 0.0] };
    let case = LoadCase { name: "tip".into(), loads: vec![load], acceleration: None, weight: 1.0 };
    let fixed = loads::fixed_dofs(&g, &supports);
    let f = loads::applied(&g, &case);
    let (c_oc, it_oc, phys_oc, t_oc) = top3d_oc(g, fixed, &f, 0.3, 3.0, 1.5, 200, 0.01);
    row(
        "top3d cantilever 60x20x4, vf 0.3, p 3, rmin 1.5: top3d OC loop ported (density filter)",
        "TOP3D printout (Gao et al. 2017, arXiv 1712.02919, Fig. 13): C = 2417.5352, It = 155",
        &format!("c = {c_oc:.2}, {it_oc} its, {:.1} s, grey {:.0} %", t_oc, 100.0 * grey(&phys_oc)),
        &format!("{:+.3} %", 100.0 * (c_oc / 2417.5352 - 1.0)),
    );
    let base = Study {
        min: [0.0; 3],
        max: [nx as f64, ny as f64, nz as f64],
        voxel: 1.0,
        material: material(1.0, 0.3, 1.0),
        supports: supports.clone(),
        cases: vec![case.clone()],
        volume_fraction: 0.3,
        min_member: 2.5, // filter radius max(1.5 h, 0.6 x 2.5) = 1.5
        iterations: 200,
        max_beta: 0.0,
        tolerance: 0.01,
        ..Study::default()
    };
    let (tr, phys_mma, t_mma) = engine(&base);
    row(
        "  same, engine: MMA, density filter, no projection, stop at change 0.01",
        &format!("OC port c = {c_oc:.2}, {it_oc} its"),
        &format!("c = {:.2}, {} its, {:.1} s, grey {:.0} %, layout agreement with OC {:.1} %", tr.compliances[0], tr.iterations, t_mma, 100.0 * grey(&phys_mma), 100.0 * agreement(&phys_oc, &phys_mma)),
        &format!("{:+.2} % vs OC", 100.0 * (tr.compliances[0] / c_oc - 1.0)),
    );
    let proj = Study { max_beta: 16.0, tolerance: 0.0, iterations: 100, ..base.clone() };
    let (tr, phys_p, t_p) = engine(&proj);
    row(
        "  same, engine default: MMA + Heaviside β 1 to 16, 100 its",
        &format!("OC port c = {c_oc:.2}"),
        &format!("c = {:.2}, {:.1} s, grey {:.1} %, agreement with OC {:.1} %", tr.compliances[0], t_p, 100.0 * grey(&phys_p), 100.0 * agreement(&phys_oc, &phys_p)),
        &format!("{:+.2} % vs OC (crisp 0/1)", 100.0 * (tr.compliances[0] / c_oc - 1.0)),
    );
    println!("\nOC port, side view (# = solid through most of z):\n{}", side_view(&g, &phys_oc, 1));
    println!("Engine MMA, side view:\n{}", side_view(&g, &phys_mma, 1));
    println!("Engine MMA + projection, side view:\n{}", side_view(&g, &phys_p, 1));

    // 3D MBB half beam 60 x 20 x 4: symmetry (ux = 0) on x = 0, roller (uy = 0) on the bottom
    // edge at x = 60, uz held there too; unit loads down on the top edge at x = 0.
    let mbb_sup = vec![
        Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, ny as f64 + 1.0, nz as f64 + 1.0] }, fix: [true, false, false] },
        Support { region: Region::Box { min: [nx as f64 - 0.1, -0.1, -0.1], max: [nx as f64 + 0.1, 0.1, nz as f64 + 0.1] }, fix: [false, true, true] },
    ];
    let mbb_case = LoadCase { name: "mid".into(), loads: vec![Load::Force { region: Region::Box { min: [-0.1, ny as f64 - 0.1, -0.1], max: [0.1, ny as f64 + 0.1, nz as f64 + 0.1] }, force: [0.0, -((nz + 1) as f64), 0.0] }], acceleration: None, weight: 1.0 };
    let (c_oc, it_oc, phys_oc, _) = top3d_oc(g, loads::fixed_dofs(&g, &mbb_sup), &loads::applied(&g, &mbb_case), 0.3, 3.0, 1.5, 200, 0.01);
    let mbb = Study { supports: mbb_sup, cases: vec![mbb_case], ..base.clone() };
    let (tr, phys_mma, _) = engine(&mbb);
    row(
        "3D MBB half beam 60x20x4, vf 0.3, p 3, rmin 1.5: top3d OC port vs engine MMA",
        &format!("OC port c = {c_oc:.2}, {it_oc} its"),
        &format!("MMA c = {:.2}, {} its, agreement {:.1} %", tr.compliances[0], tr.iterations, 100.0 * agreement(&phys_oc, &phys_mma)),
        &format!("{:+.2} %", 100.0 * (tr.compliances[0] / c_oc - 1.0)),
    );
    println!("\nMBB OC port, side view:\n{}", side_view(&g, &phys_oc, 1));
    println!("MBB engine MMA, side view:\n{}", side_view(&g, &phys_mma, 1));

    // PETSc TopOpt default (TopOpt.cc / LinearElasticity.cc): [0, 2] x [0, 1] x [0, 1], 64 x 32 x
    // 32 elements, vf 0.12, p 3, rmin 0.08, density filter, MMA move 0.2, 400 its, E 1, ν 0.3,
    // clamped at x = 0, line load -0.001 per node in z on the edge x = 2, z = 0 (corners half).
    for (n, its) in if quick { vec![(32usize, 120usize)] } else { vec![(32usize, 400usize), (64, 400)] } {
        let h = 1.0 / n as f64;
        let ny = n + 1;
        let load = -0.001 * (ny as f64 - 1.0); // total: interior nodes full, corners half.
        let s = Study {
            min: [0.0; 3],
            max: [2.0, 1.0, 1.0],
            voxel: h,
            material: material(1.0, 0.3, 1.0),
            supports: vec![Support { region: Region::Box { min: [-0.1 * h, -1.0, -1.0], max: [0.1 * h, 2.0, 2.0] }, fix: [true; 3] }],
            cases: vec![LoadCase { name: "edge".into(), loads: vec![Load::Force { region: Region::Box { min: [2.0 - 0.1 * h, -1.0, -0.1 * h], max: [2.1, 2.0, 0.1 * h] }, force: [0.0, 0.0, load] }], acceleration: None, weight: 1.0 }],
            volume_fraction: 0.12,
            min_member: 0.08 / 0.6,
            iterations: its,
            max_beta: 0.0,
            ..Study::default()
        };
        let (tr, phys, t) = engine(&s);
        let g = Grid::new(s.min, s.max, h);
        row(
            &format!("PETSc TopOpt default cantilever 2:1:1, {}x{}x{} ({} hex8), vf 0.12, rmin 0.08, {its} its", 2 * n, n, n, g.elements()),
            "Aage et al. 2015 topology (no compliance printed in the paper)",
            // The load is per node, so the total grows with the mesh: c / F² compares meshes.
            &format!("c = {:.4e}, c / F² = {:.1}, volume {:.4}, grey {:.0} %, {:.0} s ({:.2} s/it)", tr.compliances[0], tr.compliances[0] / (load * load), tr.volume, 100.0 * grey(&phys), t, t / tr.iterations as f64),
            "",
        );
        println!("\nPETSc default, side view at {}:\n{}", g.n[0], side_view(&g, &phys, (n / 32).max(1)));
    }
}

fn main() {
    let quick = std::env::args().any(|a| a == "--quick");
    println!("threads: {}\n", rayon::current_num_threads());
    println!("| Check | Reference | ViaForm | Error |\n|---|---|---|---|");
    fem_cantilever();
    first_frequency();
    mma_checks();
    multigrid();
    top3d_benchmarks(quick);
    println!("\nTable:\n| Check | Reference | ViaForm | Error |\n|---|---|---|---|");
    for r in rows().lock().unwrap().iter() {
        println!("{r}");
    }
}
