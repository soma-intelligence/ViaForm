//! D3Q7 passive temperature: conduction, heat source, advection-diffusion.

use viaform_fluid::{Thermal, ThermalConfig, ThermalFace};

fn plates(h: usize, tau: f64, t0: f64, t1: f64) -> Thermal {
    Thermal::new(
        ThermalConfig {
            dims: [1, 1, h],
            tau,
            faces: [
                ThermalFace::Periodic,
                ThermalFace::Periodic,
                ThermalFace::Periodic,
                ThermalFace::Periodic,
                ThermalFace::Fixed { temperature: t0 },
                ThermalFace::Fixed { temperature: t1 },
            ],
        },
        0.0,
    )
    .unwrap()
}

#[test]
fn conduction_between_plates_is_linear() {
    let h = 20;
    let mut th = plates(h, 0.9, 0.0, 1.0);
    for _ in 0..40_000 {
        th.step(None);
    }
    let worst = (0..h)
        .map(|z| (th.at(0, 0, z) - (z as f64 + 0.5) / h as f64).abs())
        .fold(0.0, f64::max);
    println!("conduction max error {worst:e}");
    assert!(worst < 1e-10, "{worst}");
    // Fourier: flux kappa dT/dz in through the hot plate, out through the cold one.
    let flux = th.heat_through_faces();
    assert!(flux.abs() < 1e-10, "net heat at steady state {flux}");
}

#[test]
fn uniform_source_gives_a_parabola() {
    let h = 32;
    let tau = 0.8;
    let mut th = plates(h, tau, 0.0, 0.0);
    let s = 1e-5;
    th.set_source(Some(vec![s; h])).unwrap();
    for _ in 0..100_000 {
        th.step(None);
    }
    let kappa = th.diffusivity();
    let hf = h as f64;
    let (mut e, mut n) = (0.0, 0.0);
    for z in 0..h {
        let sz = z as f64 + 0.5;
        let ta = s / (2.0 * kappa) * sz * (hf - sz);
        e += (th.at(0, 0, z) - ta).powi(2);
        n += ta * ta;
    }
    let rel = (e / n).sqrt();
    println!("heat source L2 error {rel:e}");
    assert!(rel < 2e-3, "{rel}");
    // Energy balance: what the source puts in leaves through the walls.
    let out = -th.heat_through_faces();
    assert!((out / (s * hf) - 1.0).abs() < 1e-6, "{out}");
}

#[test]
fn advection_diffusion_of_a_wave() {
    let n = 64;
    let tau = 0.7;
    let u = 0.05;
    let mut th = Thermal::new(
        ThermalConfig {
            dims: [n, 1, 1],
            tau,
            faces: [ThermalFace::Periodic; 6],
        },
        0.0,
    )
    .unwrap();
    let k = 2.0 * std::f64::consts::PI / n as f64;
    // Initial wave through the source-free equilibrium: run from a sine set by one source pulse.
    let src: Vec<f64> = (0..n).map(|x| (k * x as f64).sin()).collect();
    th.set_source(Some(src)).unwrap();
    let flow = vec![[1.0, u, 0.0, 0.0]; n];
    th.step(Some(&flow));
    th.set_source(None).unwrap();
    let amp_phase = |th: &Thermal| {
        let (mut a, mut b) = (0.0, 0.0);
        for x in 0..n {
            a += th.at(x, 0, 0) * (k * x as f64).sin();
            b += th.at(x, 0, 0) * (k * x as f64).cos();
        }
        ((a * a + b * b).sqrt(), b.atan2(a))
    };
    for _ in 0..50 {
        th.step(Some(&flow));
    }
    let (a0, p0) = amp_phase(&th);
    let t = 400;
    for _ in 0..t {
        th.step(Some(&flow));
    }
    let (a1, p1) = amp_phase(&th);
    let kappa = -(a1 / a0).ln() / (k * k * t as f64);
    let mut dp = p0 - p1;
    while dp < 0.0 {
        dp += 2.0 * std::f64::consts::PI;
    }
    let speed = dp / (k * t as f64);
    println!(
        "advection-diffusion: kappa {kappa:.6} vs {:.6}, speed {speed:.6} vs {u}",
        th.diffusivity()
    );
    assert!((kappa / th.diffusivity() - 1.0).abs() < 0.01);
    assert!((speed / u - 1.0).abs() < 0.005);
}
