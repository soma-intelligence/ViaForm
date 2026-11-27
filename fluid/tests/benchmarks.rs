//! Published benchmarks: lid-driven cavity (Ghia et al. 1982) and the Schafer-Turek 2D-1
//! cylinder. Coarse grids here to keep the suite short; `examples/validate.rs` runs finer ones.

use viaform_fluid::Collision;
use viaform_fluid::cases::{cavity, schafer_turek_2d1};

#[test]
fn lid_driven_cavity_re100_matches_ghia() {
    let r = cavity(64, 100.0, 0.1, Collision::Regularized, 200_000);
    println!(
        "cavity Re 100, 64^2: {} steps, converged {}, max err {:.4}, rms {:.4}",
        r.steps, r.converged, r.max_error, r.rms_error
    );
    assert!(r.converged);
    assert!(r.max_error < 0.02, "{}", r.max_error);
}

#[test]
fn cylinder_schafer_turek_2d1() {
    // D = 10 cells, interpolated bounce-back, low Mach (peak inflow 0.02): the compressibility
    // error is about +2.5 % on cD at a peak of 0.1, see docs/fluid/ENGINE.md.
    let r = schafer_turek_2d1(10, 0.02, Collision::Regularized, true, 400_000);
    println!(
        "Schafer-Turek 2D-1, D = 10, interpolated: {} steps, converged {}, cD {:.4}, cL {:.4}, dp {:.4}",
        r.steps, r.converged, r.cd, r.cl, r.dp
    );
    assert!(r.converged);
    // Reference cD 5.57 to 5.59, cL 0.0104 to 0.0110, dp 0.1172 to 0.1176.
    assert!((r.cd / 5.58 - 1.0).abs() < 0.04, "cD {}", r.cd);
    assert!(r.cl > 0.005 && r.cl < 0.02, "cL {}", r.cl);
    assert!((r.dp / 0.1174 - 1.0).abs() < 0.03, "dp {}", r.dp);
}
