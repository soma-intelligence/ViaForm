//! Analytic flows: Poiseuille (second-order convergence), Couette, Taylor-Green decay,
//! partial bounce-back as a Brinkman drag, units round trip, determinism.

use viaform_fluid::{Collision, Config, Face, Solver, Units, porosity_from_design};

fn channel(h: usize, tau: f64, collision: Collision) -> Config {
    // Flow along x, walls on the y faces, periodic x and z: one plane of h cells.
    Config {
        dims: [1, h, 1],
        tau,
        collision,
        smagorinsky: None,
        body_force: [0.0; 3],
        faces: [
            Face::Periodic,
            Face::Periodic,
            Face::Wall { velocity: [0.0; 3] },
            Face::Wall { velocity: [0.0; 3] },
            Face::Periodic,
            Face::Periodic,
        ],
    }
}

/// L2 relative error of the body-force Poiseuille profile at `h` cells.
fn poiseuille(h: usize, collision: Collision) -> f64 {
    let tau = 0.8;
    let nu = (tau - 0.5) / 3.0;
    let hf = h as f64;
    let umax = 0.01;
    let g = 8.0 * nu * umax / (hf * hf);
    let mut cfg = channel(h, tau, collision);
    cfg.body_force = [g, 0.0, 0.0];
    let mut s = Solver::new(cfg).unwrap();
    let (_, ok) = s.run_to_steady(2_000_000, 500, 1e-12);
    assert!(ok, "Poiseuille h={h} did not converge");
    let (mut e, mut n) = (0.0, 0.0);
    for y in 0..h {
        let sy = y as f64 + 0.5;
        let ua = g / (2.0 * nu) * sy * (hf - sy);
        let u = s.velocity(0, y, 0)[0];
        e += (u - ua) * (u - ua);
        n += ua * ua;
    }
    (e / n).sqrt()
}

#[test]
fn poiseuille_second_order() {
    for col in [Collision::Bgk, Collision::Regularized] {
        let e: Vec<f64> = [8, 16, 32].iter().map(|&h| poiseuille(h, col)).collect();
        let o1 = (e[0] / e[1]).log2();
        let o2 = (e[1] / e[2]).log2();
        println!("{col:?} Poiseuille L2 errors {e:?}, orders {o1:.3} {o2:.3}");
        assert!(e[2] < 2e-3, "error at h=32: {}", e[2]);
        assert!(o1 > 1.9 && o2 > 1.9, "orders {o1} {o2}");
    }
}

#[test]
fn couette_exact() {
    let h = 16;
    let uw = 0.05;
    let mut cfg = channel(h, 0.9, Collision::Regularized);
    cfg.faces[3] = Face::Wall {
        velocity: [uw, 0.0, 0.0],
    };
    let mut s = Solver::new(cfg).unwrap();
    let (_, ok) = s.run_to_steady(1_000_000, 500, 1e-13);
    assert!(ok);
    let mut worst: f64 = 0.0;
    for y in 0..h {
        let ua = uw * (y as f64 + 0.5) / h as f64;
        worst = worst.max((s.velocity(0, y, 0)[0] - ua).abs() / uw);
    }
    println!("Couette max error / U = {worst:e}");
    assert!(worst < 1e-10, "{worst}");
}

/// Kinetic-energy decay of the 2D Taylor-Green vortex in the x-z plane; returns the measured
/// viscosity over the BGK one, minus 1.
fn taylor_green(n: usize, tau: f64, collision: Collision) -> f64 {
    let u0 = 0.02;
    let k = 2.0 * std::f64::consts::PI / n as f64;
    let mut s = Solver::new(Config {
        collision,
        ..Config::periodic([n, 1, n], tau)
    })
    .unwrap();
    s.init(|x, _, z| {
        let (x, z) = (x as f64 * k, z as f64 * k);
        let p = u0 * u0 / 4.0 * ((2.0 * x).cos() + (2.0 * z).cos());
        (
            1.0 + 3.0 * p,
            [u0 * x.sin() * z.cos(), 0.0, -u0 * x.cos() * z.sin()],
        )
    });
    let energy = |s: &Solver| {
        s.macroscopic()
            .iter()
            .map(|m| m[1] * m[1] + m[2] * m[2] + m[3] * m[3])
            .sum::<f64>()
    };
    s.run(100);
    let e0 = energy(&s);
    let t = 600;
    s.run(t);
    let e1 = energy(&s);
    let nu = -(e1 / e0).ln() / (4.0 * k * k * t as f64);
    nu / s.viscosity() - 1.0
}

#[test]
fn taylor_green_viscosity() {
    for (tau, col) in [
        (0.8, Collision::Bgk),
        (0.8, Collision::Regularized),
        (0.56, Collision::Regularized),
    ] {
        let e = taylor_green(64, tau, col);
        println!(
            "Taylor-Green N=64 tau={tau} {col:?}: viscosity error {:.4} %",
            e * 100.0
        );
        assert!(e.abs() < 5e-3, "{e}");
    }
}

#[test]
fn partial_bounce_back_is_a_brinkman_drag() {
    // Uniform n_s in a periodic box under a body force: steady u = F / (2 n_s).
    for ns in [0.05, 0.2, 0.5] {
        let g = 1e-5;
        let mut cfg = Config::periodic([4, 4, 4], 0.7);
        cfg.body_force = [g, 0.0, 0.0];
        let mut s = Solver::new(cfg).unwrap();
        s.set_porosity(Some(vec![ns; 64])).unwrap();
        s.run(2000);
        let u = s.velocity(1, 2, 3)[0];
        let want = g / (2.0 * ns);
        assert!((u / want - 1.0).abs() < 1e-9, "ns {ns}: {u} vs {want}");
        // The drag on the porous cells balances the body force.
        let f = s.force()[0];
        assert!((f / (g * 64.0) - 1.0).abs() < 1e-9, "force {f}");
    }
    assert_eq!(porosity_from_design(0.0, 0.1), 0.0);
    assert!((porosity_from_design(1.0, 0.1) - 1.0).abs() < 1e-15);
    assert!(porosity_from_design(0.5, 0.1) < 0.5);
}

#[test]
fn units_round_trip() {
    let u = Units::from_mach(1e-3, 5.0, 1.204, 0.1).unwrap();
    let ul = u.velocity_to_lattice(5.0);
    assert!((ul - 0.1 / 3f64.sqrt()).abs() < 1e-15);
    assert!((u.velocity_to_physical(ul) - 5.0).abs() < 1e-12);
    assert!((u.viscosity_to_physical(u.viscosity_to_lattice(1.5e-5)) - 1.5e-5).abs() < 1e-20);
    assert!((u.force_to_physical(u.force_to_lattice(0.37)) - 0.37).abs() < 1e-14);
    assert!((u.pressure_to_physical(u.pressure_to_lattice(12.5)) - 12.5).abs() < 1e-9);
    assert!((u.tau(1.5e-5) - (0.5 + 3.0 * 1.5e-5 * u.dt / 1e-6)).abs() < 1e-14);
    // Dynamic pressure is consistent: 0.5 rho U^2 in lattice is 0.5 ul^2, in Pa 0.5*1.204*25.
    let q_lat = 0.5 * ul * ul;
    let q = u.pressure_to_physical(1.0 + q_lat / (1.0 / 3.0));
    assert!((q - 0.5 * 1.204 * 25.0).abs() < 1e-9);
    assert!(Units::from_mach(1e-3, 5.0, 1.2, 0.5).is_err());
}

fn det_case() -> Solver {
    let mut cfg = Config {
        dims: [24, 18, 14],
        tau: 0.52,
        collision: Collision::Regularized,
        smagorinsky: Some(0.14),
        body_force: [1e-6, 0.0, 2e-7],
        faces: [
            Face::Velocity {
                velocity: [0.05, 0.0, 0.0],
                profile: Default::default(),
            },
            Face::Pressure { density: 1.0 },
            Face::Slip,
            Face::Slip,
            Face::Periodic,
            Face::Periodic,
        ],
    };
    cfg.collision = Collision::Regularized;
    let mut s = Solver::new(cfg).unwrap();
    for z in 0..14 {
        for y in 0..18 {
            for x in 0..24 {
                let d = [(x as f64 - 8.0), (y as f64 - 9.0), (z as f64 - 7.0)];
                if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < 12.0 {
                    s.set_solid(x, y, z, true);
                }
            }
        }
    }
    let mut ns = vec![0.0; 24 * 18 * 14];
    for (i, v) in ns.iter_mut().enumerate() {
        if i % 24 == 15 {
            *v = 0.3;
        }
    }
    s.set_porosity(Some(ns)).unwrap();
    s.torque_center = [8.0, 9.0, 7.0];
    s
}

#[test]
fn bitwise_identical_on_any_thread_count() {
    let mut runs = vec![];
    for threads in [1, 2, 5, 16] {
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .unwrap();
        let r = pool.install(|| {
            let mut s = det_case();
            s.run(60);
            let pops: Vec<u64> = s.populations().iter().map(|v| v.to_bits()).collect();
            let f = s.force().map(f64::to_bits);
            let t = s.torque().map(f64::to_bits);
            let ch = s.relative_change().to_bits();
            (pops, f, t, ch)
        });
        runs.push(r);
    }
    for r in &runs[1..] {
        assert!(r.0 == runs[0].0, "populations differ");
        assert_eq!(r.1, runs[0].1);
        assert_eq!(r.2, runs[0].2);
        assert_eq!(r.3, runs[0].3);
    }
    let f = f64::from_bits(runs[0].1[0]);
    assert!(f > 0.0, "drag on the sphere should be positive, got {f}");
}
