//! Validation and performance table for docs/fluid/ENGINE.md.
//!
//! `cargo run --release -p viaform-fluid --example validate [quick] [nocavity]`

use std::time::Instant;

use viaform_fluid::cases::{cavity, schafer_turek_2d1, schiller_naumann};
use viaform_fluid::{Collision, Config, Face, Profile, Solver};

fn row(check: &str, reference: &str, ours: &str, error: &str) {
    println!("| {check} | {reference} | {ours} | {error} |");
}

fn poiseuille(h: usize, col: Collision) -> f64 {
    let tau = 0.8;
    let nu = (tau - 0.5) / 3.0;
    let hf = h as f64;
    let g = 8.0 * nu * 0.01 / (hf * hf);
    let wall = Face::Wall { velocity: [0.0; 3] };
    let mut s = Solver::new(Config {
        dims: [1, h, 1],
        tau,
        collision: col,
        smagorinsky: None,
        body_force: [g, 0.0, 0.0],
        faces: [
            Face::Periodic,
            Face::Periodic,
            wall,
            wall,
            Face::Periodic,
            Face::Periodic,
        ],
    })
    .unwrap();
    s.run_to_steady(5_000_000, 1000, 1e-12);
    let (mut e, mut n) = (0.0, 0.0);
    for y in 0..h {
        let sy = y as f64 + 0.5;
        let ua = g / (2.0 * nu) * sy * (hf - sy);
        e += (s.velocity(0, y, 0)[0] - ua).powi(2);
        n += ua * ua;
    }
    (e / n).sqrt()
}

fn taylor_green(n: usize, tau: f64, col: Collision) -> f64 {
    let u0 = 0.02;
    let k = 2.0 * std::f64::consts::PI / n as f64;
    let mut s = Solver::new(Config {
        collision: col,
        ..Config::periodic([n, 1, n], tau)
    })
    .unwrap();
    s.init(|x, _, z| {
        let (x, z) = (x as f64 * k, z as f64 * k);
        (
            1.0 + 0.75 * u0 * u0 * ((2.0 * x).cos() + (2.0 * z).cos()),
            [u0 * x.sin() * z.cos(), 0.0, -u0 * x.cos() * z.sin()],
        )
    });
    let e = |s: &Solver| {
        s.macroscopic()
            .iter()
            .map(|m| m[1] * m[1] + m[3] * m[3])
            .sum::<f64>()
    };
    s.run(100);
    let e0 = e(&s);
    let t = 4 * n;
    s.run(t as u64);
    let nu = -(e(&s) / e0).ln() / (4.0 * k * k * t as f64);
    nu / s.viscosity() - 1.0
}

/// Sphere of `d` cells in a box 12 d x 8 d x 8 d (centre 4 d from the inlet), slip sides.
fn sphere(d: usize, re: f64, u: f64) -> (f64, u64, bool) {
    use viaform_fluid::geometry::Shape;
    let df = d as f64;
    let dims = [12 * d, 8 * d, 8 * d];
    let nu = u * df / re;
    let mut s = Solver::new(Config {
        dims,
        tau: 3.0 * nu + 0.5,
        collision: Collision::Regularized,
        smagorinsky: None,
        body_force: [0.0; 3],
        faces: [
            Face::Velocity {
                velocity: [u, 0.0, 0.0],
                profile: Profile::Uniform,
            },
            Face::Pressure { density: 1.0 },
            Face::Slip,
            Face::Slip,
            Face::Slip,
            Face::Slip,
        ],
    })
    .unwrap();
    let c = [4.0 * df, 4.0 * df, 4.0 * df];
    let mut mask = vec![false; dims[0] * dims[1] * dims[2]];
    for z in 0..dims[2] {
        for y in 0..dims[1] {
            for x in 0..dims[0] {
                let p = [
                    x as f64 + 0.5 - c[0],
                    y as f64 + 0.5 - c[1],
                    z as f64 + 0.5 - c[2],
                ];
                if p[0] * p[0] + p[1] * p[1] + p[2] * p[2] <= 0.25 * df * df {
                    mask[(z * dims[1] + y) * dims[0] + x] = true;
                }
            }
        }
    }
    s.set_solid_mask(&mask).unwrap();
    let ball = Shape::Sphere {
        center: [c[0] - 0.5, c[1] - 0.5, c[2] - 0.5],
        radius: 0.5 * df,
    };
    s.set_wall_distance(|p, dir| ball.ray_hit(p, dir).filter(|t| *t <= 1.0));
    s.set_sponge(d, 0.1);
    s.init(|_, _, _| (1.0, [u, 0.0, 0.0]));
    let (steps, ok) = s.run_to_steady(40_000, 500, 1e-6);
    let mut f = 0.0;
    for _ in 0..200 {
        s.step();
        f += s.force()[0] / 200.0;
    }
    let cd = f / (0.5 * u * u * std::f64::consts::PI * df * df / 4.0);
    (cd, steps, ok)
}

fn mlups(n: usize, steps: u64, threads: Option<usize>, obstacle: bool) -> f64 {
    let work = || {
        let mut s = if obstacle {
            let mut s = Solver::new(Config {
                dims: [n, n, n],
                tau: 0.51,
                collision: Collision::Regularized,
                smagorinsky: Some(0.14),
                body_force: [0.0; 3],
                faces: [
                    Face::Velocity {
                        velocity: [0.05, 0.0, 0.0],
                        profile: Profile::Uniform,
                    },
                    Face::Pressure { density: 1.0 },
                    Face::Slip,
                    Face::Slip,
                    Face::Slip,
                    Face::Slip,
                ],
            })
            .unwrap();
            let c = n as f64 / 2.0;
            for z in 0..n {
                for y in 0..n {
                    for x in 0..n {
                        let p = [x as f64 - c * 0.6, y as f64 - c, z as f64 - c];
                        if p[0] * p[0] + p[1] * p[1] + p[2] * p[2] < (n as f64 / 8.0).powi(2) {
                            s.set_solid(x, y, z, true);
                        }
                    }
                }
            }
            s
        } else {
            Solver::new(Config::periodic([n, n, n], 0.6)).unwrap()
        };
        s.run(3);
        let t = Instant::now();
        s.run(steps);
        (n * n * n) as f64 * steps as f64 / t.elapsed().as_secs_f64() / 1e6
    };
    match threads {
        Some(k) => rayon::ThreadPoolBuilder::new()
            .num_threads(k)
            .build()
            .unwrap()
            .install(work),
        None => work(),
    }
}

fn main() {
    let quick = std::env::args().any(|a| a == "quick");
    // `only=poiseuille,taylor,cavity,cylinder,sphere,determinism,perf` runs those sections;
    // `cyl=20:0.05:i,40:0.05:h` replaces the cylinder list (D, peak inflow, interpolated or halfway),
    // `sph=12:20` the sphere list (D, Re).
    let only: Option<Vec<String>> = std::env::args().find_map(|a| {
        a.strip_prefix("only=")
            .map(|v| v.split(',').map(String::from).collect())
    });
    let want = |name: &str| only.as_ref().is_none_or(|o| o.iter().any(|x| x == name));
    let cyl_arg: Option<Vec<(usize, f64, bool)>> = std::env::args().find_map(|a| {
        a.strip_prefix("cyl=").map(|v| {
            v.split(',')
                .map(|e| {
                    let p: Vec<&str> = e.split(':').collect();
                    (
                        p[0].parse().unwrap(),
                        p[1].parse().unwrap(),
                        p.get(2) != Some(&"h"),
                    )
                })
                .collect()
        })
    });
    let t0 = Instant::now();
    println!("| Check | Reference | ViaForm | Error |");
    println!("|---|---|---|---|");

    for col in if want("poiseuille") {
        vec![Collision::Bgk, Collision::Regularized]
    } else {
        vec![]
    } {
        let e: Vec<f64> = [16, 32, 64].iter().map(|&h| poiseuille(h, col)).collect();
        row(
            &format!("Poiseuille (body force), {col:?}, tau 0.8, H = 16 / 32 / 64"),
            "u = g s (H - s) / (2 nu)",
            &format!("L2 {:.2e} / {:.2e} / {:.2e}", e[0], e[1], e[2]),
            &format!(
                "order {:.3}, {:.3}",
                (e[0] / e[1]).log2(),
                (e[1] / e[2]).log2()
            ),
        );
    }

    for (tau, col) in if want("taylor") {
        vec![
            (0.8, Collision::Bgk),
            (0.8, Collision::Regularized),
            (0.51, Collision::Regularized),
        ]
    } else {
        vec![]
    } {
        let e = taylor_green(128, tau, col);
        row(
            &format!("Taylor-Green 2D decay, 128^2, {col:?}, tau {tau}"),
            "nu = (tau - 1/2) / 3",
            &format!("nu x {:.5}", 1.0 + e),
            &format!("{:+.3} %", e * 100.0),
        );
    }

    // `nocavity` skips the cavity rows (several minutes each at 128^2 and 256^2).
    let nocavity = std::env::args().any(|a| a == "nocavity");
    let cav: &[(f64, usize)] = if nocavity || !want("cavity") {
        &[]
    } else if quick {
        &[(100.0, 64)]
    } else {
        &[
            (100.0, 64),
            (100.0, 128),
            (400.0, 128),
            (1000.0, 128),
            (1000.0, 256),
        ]
    };
    // Re 400: Ghia's v = -0.23827 at x = 0.9063 is a known misprint (neighbours -0.228 and -0.450);
    // the row also gives the error without that point.
    for &(re, n) in cav {
        let t = Instant::now();
        let r = cavity(n, re, 0.1, Collision::Regularized, 2_000_000);
        row(
            &format!(
                "Lid-driven cavity Re {re}, {n}^2, regularized, U 0.1 ({} steps, {:.0} s)",
                r.steps,
                t.elapsed().as_secs_f64()
            ),
            "Ghia et al. 1982, 15 + 15 centreline points",
            &format!("max {:.4}, rms {:.4}", r.max_error, r.rms_error),
            &format!("max {:.2} % of U", r.max_error * 100.0),
        );
        if re == 400.0 {
            let worst =
                r.u.iter()
                    .chain(r.v.iter().filter(|p| p.0 != 0.9063))
                    .map(|p| (p.2 - p.1).abs())
                    .fold(0.0, f64::max);
            row(
                "same, Re 400, without Ghia's x = 0.9063 v point",
                "Ghia et al. 1982, 29 points",
                &format!("max {worst:.4}"),
                &format!("max {:.2} % of U", worst * 100.0),
            );
        }
        if n >= 128 {
            let worst_u = r.u.iter().map(|p| (p.2 - p.1).abs()).fold(0.0, f64::max);
            let worst_v = r.v.iter().map(|p| (p.2 - p.1).abs()).fold(0.0, f64::max);
            eprintln!(
                "  cavity Re {re} {n}: worst u {worst_u:.4}, worst v {worst_v:.4}; u(0.5) Ghia {:.5} ours {:.5}",
                r.u[7].1, r.u[7].2
            );
        }
    }

    let cyl: &[(usize, f64, bool)] = if !want("cylinder") {
        &[]
    } else if let Some(c) = &cyl_arg {
        c
    } else if quick {
        &[(10, 0.05, true)]
    } else {
        &[
            (20, 0.1, false),
            (20, 0.1, true),
            (20, 0.05, true),
            (20, 0.025, true),
            (40, 0.05, true),
            (40, 0.025, true),
        ]
    };
    for &(d, um, interp) in cyl {
        let t = Instant::now();
        let r = schafer_turek_2d1(d, um, Collision::Regularized, interp, 3_000_000);
        let d = format!(
            "{d}, Um {um}, {}",
            if interp { "interpolated" } else { "halfway" }
        );
        let span = |v: f64, lo: f64, hi: f64| {
            if v < lo {
                (v / lo - 1.0) * 100.0
            } else if v > hi {
                (v / hi - 1.0) * 100.0
            } else {
                0.0
            }
        };
        row(
            &format!(
                "Schafer-Turek 2D-1 cD, D = {d} cells ({} cells, {} steps, {:.0} s)",
                r.cells,
                r.steps,
                t.elapsed().as_secs_f64()
            ),
            "5.57 to 5.59",
            &format!("{:.4}", r.cd),
            &format!("{:+.2} %", span(r.cd, 5.57, 5.59)),
        );
        row(
            &format!("same, cL, D = {d}"),
            "0.0104 to 0.0110",
            &format!("{:.4}", r.cl),
            &format!("{:+.1} %", span(r.cl, 0.0104, 0.0110)),
        );
        row(
            &format!("same, pressure difference, D = {d}"),
            "0.1172 to 0.1176 Pa",
            &format!("{:.4}", r.dp),
            &format!("{:+.1} %", span(r.dp, 0.1172, 0.1176)),
        );
    }

    let sph_arg: Option<Vec<(usize, f64)>> = std::env::args().find_map(|a| {
        a.strip_prefix("sph=").map(|v| {
            v.split(',')
                .map(|e| {
                    let p: Vec<&str> = e.split(':').collect();
                    (p[0].parse().unwrap(), p[1].parse().unwrap())
                })
                .collect()
        })
    });
    let sph: &[(usize, f64)] = if let Some(v) = sph_arg.as_deref().filter(|_| want("sphere")) {
        v
    } else if quick || !want("sphere") {
        &[]
    } else {
        &[(12, 20.0), (16, 20.0), (16, 100.0)]
    };
    // Slip box 8 D wide: blockage 1.2 %, which raises cD by roughly 2 to 4 % at these Re.
    for &(d, re) in sph {
        let t = Instant::now();
        let (cd, steps, ok) = sphere(d, re, 0.05);
        let r = schiller_naumann(re);
        row(
            &format!(
                "Sphere Re {re}, D = {d} cells, interpolated, 12D x 8D x 8D slip box ({steps} steps, converged {ok}, {:.0} s)",
                t.elapsed().as_secs_f64()
            ),
            &format!("Schiller-Naumann {r:.3}"),
            &format!("{cd:.3}"),
            &format!("{:+.1} %", (cd / r - 1.0) * 100.0),
        );
    }

    // Determinism: 1 thread against every core on a 3D case with a solid, LES and an outlet.
    if want("determinism") {
        let det = |k: usize| {
            rayon::ThreadPoolBuilder::new()
                .num_threads(k)
                .build()
                .unwrap()
                .install(|| {
                    let mut s = Solver::new(Config {
                        dims: [48, 32, 32],
                        tau: 0.505,
                        collision: Collision::Regularized,
                        smagorinsky: Some(0.14),
                        body_force: [0.0; 3],
                        faces: [
                            Face::Velocity {
                                velocity: [0.05, 0.0, 0.0],
                                profile: Profile::Uniform,
                            },
                            Face::Pressure { density: 1.0 },
                            Face::Slip,
                            Face::Slip,
                            Face::Wall { velocity: [0.0; 3] },
                            Face::Wall { velocity: [0.0; 3] },
                        ],
                    })
                    .unwrap();
                    for z in 10..20 {
                        for y in 10..20 {
                            for x in 12..16 {
                                s.set_solid(x, y, z, true);
                            }
                        }
                    }
                    s.run(300);
                    let mut h: u64 = 1469598103934665603;
                    for v in s.populations() {
                        h = (h ^ v.to_bits()).wrapping_mul(1099511628211);
                    }
                    (h, s.force()[0])
                })
        };
        let all = rayon::current_num_threads();
        let (a, b) = (det(1), det(all));
        row(
            &format!("Determinism, 48x32x32 block, LES, 300 steps, 1 vs {all} threads"),
            "bitwise equal",
            &format!("hash {:016x} / {:016x}", a.0, b.0),
            if a == b { "equal" } else { "DIFFERENT" },
        );
    }
    if !want("perf") {
        return;
    }
    let all = rayon::current_num_threads();
    println!();
    println!("| Case | Threads | MLUPS |");
    println!("|---|---|---|");
    let n = if quick { 64 } else { 128 };
    let steps = if quick { 20 } else { 100 };
    for (obstacle, name) in [
        (false, "periodic box, regularized"),
        (true, "sphere in a wind tunnel, regularized + LES"),
    ] {
        let m1 = mlups(n, steps / 4, Some(1), obstacle);
        let mn = mlups(n, steps, None, obstacle);
        println!("| {n}^3 {name} | 1 | {m1:.1} |");
        println!("| {n}^3 {name} | {all} | {mn:.1} |");
    }
    eprintln!("total {:.0} s", t0.elapsed().as_secs_f64());
}
