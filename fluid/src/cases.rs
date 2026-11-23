//! Validation cases shared by the tests and `examples/validate.rs`, with their reference data.

use crate::geometry::Shape;
use crate::lattice::CS2;
use crate::solver::{Collision, Config, Face, Profile, Solver};

/// Ghia, Ghia and Shin (1982), Table I: u on the vertical centreline, `(y, u/U)`, for
/// Re 100, 400 and 1000 (columns), 2D square cavity, lid at y = 1 moving in +x.
pub const GHIA_U: [(f64, [f64; 3]); 17] = [
    (1.0000, [1.00000, 1.00000, 1.00000]),
    (0.9766, [0.84123, 0.75837, 0.65928]),
    (0.9688, [0.78871, 0.68439, 0.57492]),
    (0.9609, [0.73722, 0.61756, 0.51117]),
    (0.9531, [0.68717, 0.55892, 0.46604]),
    (0.8516, [0.23151, 0.29093, 0.33304]),
    (0.7344, [0.00332, 0.16256, 0.18719]),
    (0.6172, [-0.13641, 0.02135, 0.05702]),
    (0.5000, [-0.20581, -0.11477, -0.06080]),
    (0.4531, [-0.21090, -0.17119, -0.10648]),
    (0.2813, [-0.15662, -0.32726, -0.27805]),
    (0.1719, [-0.10150, -0.24299, -0.38289]),
    (0.1016, [-0.06434, -0.14612, -0.29730]),
    (0.0703, [-0.04775, -0.10338, -0.22220]),
    (0.0625, [-0.04192, -0.09266, -0.20196]),
    (0.0547, [-0.03717, -0.08186, -0.18109]),
    (0.0000, [0.00000, 0.00000, 0.00000]),
];

/// Ghia, Ghia and Shin (1982), Table II: v on the horizontal centreline, `(x, v/U)`.
pub const GHIA_V: [(f64, [f64; 3]); 17] = [
    (1.0000, [0.00000, 0.00000, 0.00000]),
    (0.9688, [-0.05906, -0.12146, -0.21388]),
    (0.9609, [-0.07391, -0.15663, -0.27669]),
    (0.9531, [-0.08864, -0.19254, -0.33714]),
    (0.9453, [-0.10313, -0.22847, -0.39188]),
    (0.9063, [-0.16914, -0.23827, -0.51550]),
    (0.8594, [-0.22445, -0.44993, -0.42665]),
    (0.8047, [-0.24533, -0.38598, -0.31966]),
    (0.5000, [0.05454, 0.05186, 0.02526]),
    (0.2344, [0.17527, 0.30174, 0.32235]),
    (0.2266, [0.17507, 0.30203, 0.33075]),
    (0.1563, [0.16077, 0.28124, 0.37095]),
    (0.0938, [0.12317, 0.22965, 0.32627]),
    (0.0781, [0.10890, 0.20920, 0.30353]),
    (0.0703, [0.10091, 0.19713, 0.29012]),
    (0.0625, [0.09233, 0.18360, 0.27485]),
    (0.0000, [0.00000, 0.00000, 0.00000]),
];

/// Result of a cavity run against Ghia et al.
#[derive(Clone, Debug)]
pub struct CavityResult {
    pub steps: u64,
    pub converged: bool,
    /// Largest |ours - Ghia| / U over the 15 interior points of both centrelines.
    pub max_error: f64,
    /// RMS of the same.
    pub rms_error: f64,
    /// Per point `(coordinate, Ghia, ours)` for u then v.
    pub u: Vec<(f64, f64, f64)>,
    pub v: Vec<(f64, f64, f64)>,
}

/// 2D lid-driven cavity at `re` (100, 400 or 1000) on `n x n` cells, in the x-z plane with one
/// periodic cell in y (so the 2D benchmark is solved exactly by the 3D code). Lid at +z moving
/// in +x at `u_lid` (lattice).
pub fn cavity(n: usize, re: f64, u_lid: f64, collision: Collision, max_steps: u64) -> CavityResult {
    let col = match re as i64 {
        100 => 0,
        400 => 1,
        1000 => 2,
        _ => panic!("Ghia data exist for Re 100, 400, 1000"),
    };
    let tau = 3.0 * u_lid * n as f64 / re + 0.5;
    let wall = Face::Wall { velocity: [0.0; 3] };
    let cfg = Config {
        dims: [n, 1, n],
        tau,
        collision,
        smagorinsky: None,
        body_force: [0.0; 3],
        faces: [
            wall,
            wall,
            Face::Periodic,
            Face::Periodic,
            wall,
            Face::Wall {
                velocity: [u_lid, 0.0, 0.0],
            },
        ],
    };
    let mut s = Solver::new(cfg).expect("cavity set-up");
    let (steps, converged) = s.run_to_steady(max_steps, 1000, 1e-7);
    let nf = n as f64;
    let mid = 0.5 * nf - 0.5;
    let (mut worst, mut sq, mut cnt) = (0.0f64, 0.0, 0.0);
    let mut u = vec![];
    let mut v = vec![];
    for &(y, r) in &GHIA_U[1..16] {
        let ours = s.sample([mid, 0.0, y * nf - 0.5])[1] / u_lid;
        let e = (ours - r[col]).abs();
        worst = worst.max(e);
        sq += e * e;
        cnt += 1.0;
        u.push((y, r[col], ours));
    }
    for &(x, r) in &GHIA_V[1..16] {
        let ours = s.sample([x * nf - 0.5, 0.0, mid])[3] / u_lid;
        let e = (ours - r[col]).abs();
        worst = worst.max(e);
        sq += e * e;
        cnt += 1.0;
        v.push((x, r[col], ours));
    }
    CavityResult {
        steps,
        converged,
        max_error: worst,
        rms_error: (sq / cnt).sqrt(),
        u,
        v,
    }
}

/// Result of the Schafer-Turek 2D-1 run.
#[derive(Clone, Debug)]
pub struct CylinderResult {
    pub steps: u64,
    pub converged: bool,
    pub cd: f64,
    pub cl: f64,
    /// Pressure difference front to back of the cylinder, Pa (benchmark units).
    pub dp: f64,
    pub cells: usize,
}

/// Schafer and Turek (1996) benchmark 2D-1: channel 2.2 x 0.41 m, cylinder D = 0.1 m centred at
/// (0.2, 0.2), parabolic inflow with mean 0.2 m/s, nu = 1e-3, Re 20. `d` cells per diameter
/// (the channel is 22 d by 4.1 d; use a multiple of 10), `u_max` the inflow peak (lattice).
/// Solved in the x-z plane with one periodic cell in y; the cylinder is voxelised by cell centre.
///
/// `interpolated` uses Bouzidi's interpolated bounce-back with the exact circle instead of
/// halfway bounce-back on the voxels.
pub fn schafer_turek_2d1(
    d: usize,
    u_max: f64,
    collision: Collision,
    interpolated: bool,
    max_steps: u64,
) -> CylinderResult {
    let df = d as f64;
    let nx = 22 * d;
    let nz = (4.1 * df).round() as usize;
    let u_mean = 2.0 / 3.0 * u_max;
    let nu = u_mean * df / 20.0;
    let tau = 3.0 * nu + 0.5;
    let wall = Face::Wall { velocity: [0.0; 3] };
    let cfg = Config {
        dims: [nx, 1, nz],
        tau,
        collision,
        smagorinsky: None,
        body_force: [0.0; 3],
        faces: [
            Face::Velocity {
                velocity: [u_max, 0.0, 0.0],
                profile: Profile::Parabolic,
            },
            Face::Pressure { density: 1.0 },
            Face::Periodic,
            Face::Periodic,
            wall,
            wall,
        ],
    };
    let mut s = Solver::new(cfg).expect("cylinder set-up");
    let (cx, cz, r) = (2.0 * df, 2.0 * df, 0.5 * df);
    for k in 0..nz {
        for i in 0..nx {
            let (x, z) = (i as f64 + 0.5 - cx, k as f64 + 0.5 - cz);
            if x * x + z * z <= r * r {
                s.set_solid(i, 0, k, true);
            }
        }
    }
    if interpolated {
        // Cell coordinates: cell i has its centre at i, so the circle's centre is at c - 1/2.
        let circle = [Shape::Cylinder {
            center: [cx - 0.5, 0.0, cz - 0.5],
            axis: [0.0, 1.0, 0.0],
            radius: r,
            length: None,
        }];
        s.set_wall_distance(|p, dir| circle[0].ray_hit(p, dir).filter(|t| *t <= 1.0));
    }
    let h = nz as f64;
    s.init(|i, _, k| {
        let (x, z) = (i as f64 + 0.5 - cx, k as f64 + 0.5 - cz);
        if x * x + z * z <= r * r {
            return (1.0, [0.0; 3]);
        }
        let sz = k as f64 + 0.5;
        (1.0, [u_max * 4.0 * sz * (h - sz) / (h * h), 0.0, 0.0])
    });
    let (steps, converged) = s.run_to_steady(max_steps, 500, 1e-7);
    // Average the force over a few steps (the momentum exchange has a small step-to-step ripple).
    let mut f = [0.0; 3];
    let avg = 100;
    for _ in 0..avg {
        s.step();
        let g = s.force();
        f[0] += g[0] / avg as f64;
        f[2] += g[2] / avg as f64;
    }
    let cd = 2.0 * f[0] / (u_mean * u_mean * df);
    let cl = 2.0 * f[2] / (u_mean * u_mean * df);
    // Pressure at (0.15, 0.2) and (0.25, 0.2), on the cylinder's surface: read in the first fluid
    // cell in front of and behind it (half a cell off), averaged over the two rows about z = 0.2.
    let (i_f, i_b, k) = ((3 * d) / 2 - 1, (5 * d) / 2, 2 * d);
    let pf = 0.5 * (s.density(i_f, 0, k - 1) + s.density(i_f, 0, k));
    let pb = 0.5 * (s.density(i_b, 0, k - 1) + s.density(i_b, 0, k));
    let scale = 0.2 / u_mean; // m/s per lattice velocity, rho = 1 kg/m3
    let dp = (pf - pb) * CS2 * scale * scale;
    CylinderResult {
        steps,
        converged,
        cd,
        cl,
        dp,
        cells: nx * nz,
    }
}

/// Schiller and Naumann (1933) drag correlation for a sphere, Re < 800.
pub fn schiller_naumann(re: f64) -> f64 {
    24.0 / re * (1.0 + 0.15 * re.powf(0.687))
}
