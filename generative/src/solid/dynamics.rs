//! The time axis: natural frequencies and modes, and impacts integrated in time.
//!
//! - Modes: `K φ = λ M φ` with the lumped mass, by subspace iteration (Bathe): each round solves
//!   `K Y = M X` for a block of vectors with the multigrid-preconditioned conjugate gradient, then
//!   a Rayleigh-Ritz step on the block. The block is wider than the modes asked for, so the
//!   highest wanted one converges too; a warm start (the last round's vectors) makes the
//!   frequency constraint of the optimiser cheap.
//! - Impacts: Newmark's average acceleration method (unconditionally stable) under Rayleigh
//!   damping set to the asked ratio at the first mode. Each step solves `K_eff Δ = r` with
//!   `K_eff = s K + D` (`D` diagonal, from the mass): the conjugate gradient runs on `K_eff`,
//!   preconditioned by the stiffness's own V-cycle scaled by `1/s`, which bounds `K_eff`'s
//!   condition by `K`'s.
//!
//! Units: mass in tonnes, so `λ = ω²` is in (rad/s)².

use rayon::prelude::*;

use super::fem::Operator;
use super::mg::Hierarchy;
use super::{Impact, ImpactResponse, Mode};

const CHUNK: usize = 8192;

fn dot(a: &[f64], b: &[f64]) -> f64 {
    a.par_chunks(CHUNK).zip(b.par_chunks(CHUNK)).map(|(a, b)| a.iter().zip(b).map(|(x, y)| x * y).sum::<f64>()).collect::<Vec<_>>().iter().sum()
}

fn axpy(y: &mut [f64], a: f64, x: &[f64]) {
    y.par_iter_mut().zip(x.par_iter()).for_each(|(y, x)| *y += a * x);
}

/// One natural mode as the optimiser and the analysis use it.
#[derive(Clone, Debug)]
pub struct Eigen {
    /// `ω²`, (rad/s)².
    pub lambda: f64,
    /// Shape, mass-normalised (`φᵀ M φ = 1`).
    pub shape: Vec<f64>,
}

impl Eigen {
    pub fn frequency(&self) -> f64 {
        self.lambda.max(0.0).sqrt() / (2.0 * std::f64::consts::PI)
    }
}

/// Eigen-decomposition of a small symmetric matrix by cyclic Jacobi: values and vectors
/// (columns), sorted by value.
fn jacobi(mut a: Vec<Vec<f64>>) -> (Vec<f64>, Vec<Vec<f64>>) {
    let n = a.len();
    let mut v = vec![vec![0.0; n]; n];
    for (i, row) in v.iter_mut().enumerate() {
        row[i] = 1.0;
    }
    for _ in 0..100 {
        let off: f64 = (0..n).flat_map(|i| (0..n).filter(move |&j| j != i).map(move |j| (i, j))).map(|(i, j)| a[i][j] * a[i][j]).sum();
        let diag: f64 = (0..n).map(|i| a[i][i] * a[i][i]).sum();
        if off <= 1e-30 * diag.max(1e-300) {
            break;
        }
        for p in 0..n {
            for q in p + 1..n {
                if a[p][q].abs() < 1e-300 {
                    continue;
                }
                let theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
                let t = theta.signum() / (theta.abs() + (theta * theta + 1.0).sqrt());
                let t = if theta == 0.0 { 1.0 } else { t };
                let c = 1.0 / (t * t + 1.0).sqrt();
                let s = t * c;
                for k in 0..n {
                    let (akp, akq) = (a[k][p], a[k][q]);
                    a[k][p] = c * akp - s * akq;
                    a[k][q] = s * akp + c * akq;
                }
                for k in 0..n {
                    let (apk, aqk) = (a[p][k], a[q][k]);
                    a[p][k] = c * apk - s * aqk;
                    a[q][k] = s * apk + c * aqk;
                }
                for row in v.iter_mut() {
                    let (vp, vq) = (row[p], row[q]);
                    row[p] = c * vp - s * vq;
                    row[q] = s * vp + c * vq;
                }
            }
        }
    }
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by(|&i, &j| a[i][i].total_cmp(&a[j][j]));
    let values = order.iter().map(|&i| a[i][i]).collect();
    let vectors = order.iter().map(|&i| (0..n).map(|k| v[k][i]).collect()).collect();
    (values, vectors)
}

/// Cholesky `M = L Lᵀ` of a small symmetric positive definite matrix; `None` when it is not.
fn cholesky(m: &[Vec<f64>]) -> Option<Vec<Vec<f64>>> {
    let n = m.len();
    let mut l = vec![vec![0.0; n]; n];
    for i in 0..n {
        for j in 0..=i {
            let s: f64 = m[i][j] - (0..j).map(|k| l[i][k] * l[j][k]).sum::<f64>();
            if i == j {
                if !(s > 0.0) {
                    return None;
                }
                l[i][i] = s.sqrt();
            } else {
                l[i][j] = s / l[j][j];
            }
        }
    }
    Some(l)
}

/// The lowest `count` modes of `K(young) φ = λ M φ` (`mass` lumped per degree of freedom,
/// tonnes), using `hier` (built for `young`) for the solves. `start` warm-starts the block.
/// Rigid or unconnected parts (no support reaches them) show as `λ` near zero.
pub fn eigen(op: &Operator, young: &[f64], hier: &Hierarchy, mass: &[f64], count: usize, start: Option<&[Eigen]>, max_rounds: usize, tol: f64) -> Result<Vec<Eigen>, String> {
    let n = op.grid.dofs();
    if mass.len() != n {
        return Err(format!("{} masses for {n} degrees of freedom", mass.len()));
    }
    if count == 0 {
        return Ok(Vec::new());
    }
    let dropped = hier.dropped().ok_or("the multigrid hierarchy failed to build")?.to_vec();
    let free: Vec<bool> = (0..n).map(|d| !dropped[d] && mass[d] > 0.0).collect();
    if !free.iter().any(|&f| f) {
        return Err("nothing to vibrate: no free degree of freedom carries mass".into());
    }
    let q = (2 * count).min(count + 8).max(count + 2);
    // Starting block: the warm start, then smooth deterministic fields (each axis, then products of
    // coordinates), which excite the low modes.
    let mut x: Vec<Vec<f64>> = Vec::with_capacity(q);
    if let Some(s) = start {
        for e in s.iter().take(q) {
            if e.shape.len() == n {
                x.push(e.shape.clone());
            }
        }
    }
    let g = op.grid;
    let size = [0, 1, 2].map(|a| g.n[a] as f64 * g.h);
    let mut seed = 0usize;
    while x.len() < q {
        let s = seed;
        seed += 1;
        let axis = s % 3;
        let harmonic = 1 + s / 3;
        let v: Vec<f64> = (0..n)
            .into_par_iter()
            .map(|d| {
                if !free[d] {
                    return 0.0;
                }
                let p = g.node_position(d / 3);
                let t = [0, 1, 2].map(|a| (p[a] - g.origin[a]) / size[a].max(1e-12));
                let w = (harmonic as f64 * std::f64::consts::FRAC_PI_2 * t[(axis + 1) % 3]).sin()
                    * (1.0 + 0.3 * (std::f64::consts::PI * (harmonic as f64) * t[(axis + 2) % 3]).cos())
                    + 0.1 * ((d * 2654435761) % 1000) as f64 / 1000.0;
                if d % 3 == axis { w } else { 0.2 * w }
            })
            .collect();
        x.push(v);
    }
    let mut lambdas = vec![f64::INFINITY; q];
    let mut kx = vec![0.0; n];
    for round in 0..max_rounds.max(1) {
        // Y = K⁻¹ M X.
        let y: Vec<Vec<f64>> = x
            .iter()
            .map(|xi| {
                let f: Vec<f64> = xi.par_iter().zip(mass.par_iter()).zip(free.par_iter()).map(|((x, m), &fr)| if fr { x * m } else { 0.0 }).collect();
                let mut u = vec![0.0; n];
                hier.solve(&f, &mut u, 1e-7, 400).map(|_| u)
            })
            .collect::<Result<_, _>>()?;
        // Rayleigh-Ritz on the block.
        let mut kr = vec![vec![0.0; q]; q];
        let mut mr = vec![vec![0.0; q]; q];
        let ky: Vec<Vec<f64>> = y
            .iter()
            .map(|yi| {
                op.apply(young, yi, &mut kx);
                kx.par_iter().zip(free.par_iter()).map(|(k, &f)| if f { *k } else { 0.0 }).collect()
            })
            .collect();
        let my: Vec<Vec<f64>> = y.iter().map(|yi| yi.par_iter().zip(mass.par_iter()).zip(free.par_iter()).map(|((y, m), &f)| if f { y * m } else { 0.0 }).collect()).collect();
        for i in 0..q {
            for j in i..q {
                kr[i][j] = dot(&y[i], &ky[j]);
                kr[j][i] = kr[i][j];
                mr[i][j] = dot(&y[i], &my[j]);
                mr[j][i] = mr[i][j];
            }
        }
        // Generalised q × q problem through Mr = L Lᵀ: A = L⁻¹ Kr L⁻ᵀ.
        let l = cholesky(&mr).ok_or("the mode block lost rank (the part may be unconnected)")?;
        let solve_l = |b: &[f64]| {
            let mut z = vec![0.0; q];
            for i in 0..q {
                z[i] = (b[i] - (0..i).map(|k| l[i][k] * z[k]).sum::<f64>()) / l[i][i];
            }
            z
        };
        let solve_lt = |b: &[f64]| {
            let mut z = vec![0.0; q];
            for i in (0..q).rev() {
                z[i] = (b[i] - (i + 1..q).map(|k| l[k][i] * z[k]).sum::<f64>()) / l[i][i];
            }
            z
        };
        let mut a = vec![vec![0.0; q]; q];
        let linv_k: Vec<Vec<f64>> = (0..q).map(|j| solve_l(&(0..q).map(|i| kr[i][j]).collect::<Vec<_>>())).collect(); // columns of L⁻¹ Kr
        for i in 0..q {
            let row: Vec<f64> = (0..q).map(|j| linv_k[j][i]).collect(); // row i of L⁻¹ Kr
            let z = solve_l(&row); // (L⁻¹ (L⁻¹ Kr)ᵀ) = L⁻¹ Kr L⁻ᵀ, symmetric
            for j in 0..q {
                a[j][i] = z[j];
            }
        }
        for i in 0..q {
            for j in i + 1..q {
                let m = 0.5 * (a[i][j] + a[j][i]);
                a[i][j] = m;
                a[j][i] = m;
            }
        }
        let (values, vectors) = jacobi(a);
        let coeffs: Vec<Vec<f64>> = vectors.iter().map(|v| solve_lt(v)).collect();
        x = coeffs
            .iter()
            .map(|c| {
                let mut v = vec![0.0; n];
                for (k, yk) in y.iter().enumerate() {
                    if c[k] != 0.0 {
                        axpy(&mut v, c[k], yk);
                    }
                }
                v
            })
            .collect();
        let change = (0..count).map(|i| ((values[i] - lambdas[i]) / values[i].abs().max(1e-30)).abs()).fold(0.0, f64::max);
        lambdas = values;
        if round > 0 && change < tol {
            break;
        }
    }
    Ok((0..count)
        .map(|i| {
            let mut shape = std::mem::take(&mut x[i]);
            let mm: f64 = shape.par_iter().zip(mass.par_iter()).zip(free.par_iter()).map(|((s, m), &f)| if f { s * s * m } else { 0.0 }).sum();
            let k = if mm > 0.0 { 1.0 / mm.sqrt() } else { 1.0 };
            shape.par_iter_mut().for_each(|s| *s *= k);
            Eigen { lambda: lambdas[i], shape }
        })
        .collect())
}

/// Frequencies and effective mass shares of computed modes.
pub fn describe(op: &Operator, mass: &[f64], modes: &[Eigen], dropped: &[bool]) -> Vec<Mode> {
    let n = op.grid.dofs();
    let total: [f64; 3] = [0, 1, 2].map(|a| (0..n / 3).map(|v| if dropped[3 * v + a] { 0.0 } else { mass[3 * v + a] }).sum::<f64>());
    modes
        .iter()
        .map(|m| {
            let participation = [0, 1, 2].map(|a| {
                let gamma: f64 = (0..n / 3).map(|v| if dropped[3 * v + a] { 0.0 } else { m.shape[3 * v + a] * mass[3 * v + a] }).sum();
                if total[a] > 0.0 { gamma * gamma / total[a] } else { 0.0 }
            });
            Mode { frequency: m.frequency(), participation }
        })
        .collect()
}

/// Solves `(s K + diag(d)) x = b` on the free degrees of freedom (`dropped` kept zero).
fn solve_shifted(op: &Operator, young: &[f64], hier: &Hierarchy, s: f64, d: &[f64], dropped: &[bool], b: &[f64], x: &mut [f64], tol: f64, max_iter: usize) -> Result<usize, String> {
    let n = b.len();
    let apply = |v: &[f64], out: &mut [f64]| {
        op.apply(young, v, out);
        out.par_iter_mut().enumerate().for_each(|(i, o)| *o = if dropped[i] { 0.0 } else { s * *o + d[i] * v[i] });
    };
    let precond = |r: &[f64], z: &mut [f64]| {
        hier.vcycle(r, z);
        z.par_iter_mut().enumerate().for_each(|(i, z)| *z = if dropped[i] { 0.0 } else { *z / s });
    };
    let bn: f64 = dot(b, b).sqrt();
    if bn == 0.0 {
        x.fill(0.0);
        return Ok(0);
    }
    let mut r = vec![0.0; n];
    apply(x, &mut r);
    r.par_iter_mut().zip(b.par_iter()).enumerate().for_each(|(i, (r, b))| *r = if dropped[i] { 0.0 } else { b - *r });
    let mut z = vec![0.0; n];
    precond(&r, &mut z);
    let mut p = z.clone();
    let mut rz = dot(&r, &z);
    let mut q = vec![0.0; n];
    for it in 0..max_iter {
        if dot(&r, &r).sqrt() <= tol * bn {
            return Ok(it);
        }
        apply(&p, &mut q);
        let pq = dot(&p, &q);
        if !(pq > 0.0) {
            return if pq.is_finite() { Ok(it) } else { Err("impact step diverged".into()) };
        }
        let alpha = rz / pq;
        axpy(x, alpha, &p);
        axpy(&mut r, -alpha, &q);
        precond(&r, &mut z);
        let rz1 = dot(&r, &z);
        let beta = rz1 / rz;
        rz = rz1;
        p.par_iter_mut().zip(z.par_iter()).for_each(|(p, z)| *p = z + beta * *p);
    }
    Ok(max_iter)
}

/// Integrates a half-sine pulse of peak `peak` (nodal forces, N) in time, from rest.
/// `stress_of(u)` gives the worst von Mises over the solid for a displacement field;
/// `static_stress` is the same loads' static answer, for the amplification.
#[allow(clippy::too_many_arguments)]
pub fn impact(op: &Operator, young: &[f64], hier: &Hierarchy, mass: &[f64], peak: &[f64], impact: &Impact, first_frequency: f64, static_stress: f64, stress_of: &dyn Fn(&[f64]) -> f64) -> Result<ImpactResponse, String> {
    let n = op.grid.dofs();
    if peak.len() != n || mass.len() != n {
        return Err("impact: vectors do not match the grid".into());
    }
    if !(impact.duration > 0.0 && impact.duration.is_finite()) {
        return Err(format!("impact pulse length {} s must be positive", impact.duration));
    }
    let window = impact.window.max(impact.duration);
    let steps = impact.steps.clamp(4, 20_000);
    let dt = window / steps as f64;
    let dropped = hier.dropped().ok_or("the multigrid hierarchy failed to build")?.to_vec();
    let w1 = (2.0 * std::f64::consts::PI * first_frequency).max(1e-6);
    let zeta = impact.damping.clamp(0.0, 1.0);
    let (alpha, beta) = (zeta * w1, zeta / w1);
    let (a0, a1) = (4.0 / (dt * dt), 2.0 / dt);
    let s = 1.0 + a1 * beta;
    let dshift: Vec<f64> = mass.par_iter().map(|m| (a0 + a1 * alpha) * m).collect();
    let mut u = vec![0.0; n];
    let mut v = vec![0.0; n];
    let mut a = vec![0.0; n];
    let mut kv = vec![0.0; n];
    let (mut time, mut stress, mut displacement) = (vec![0.0], vec![0.0], vec![0.0]);
    let mut un = vec![0.0; n];
    for step in 1..=steps {
        let t = step as f64 * dt;
        let amp = if t <= impact.duration { (std::f64::consts::PI * t / impact.duration).sin() } else { 0.0 };
        // r = f + M (a0 u + (4/dt) v + a) + C (a1 u + v), C = α M + β K.
        let w: Vec<f64> = u.par_iter().zip(v.par_iter()).map(|(u, v)| a1 * u + v).collect();
        op.apply(young, &w, &mut kv);
        let r: Vec<f64> = (0..n)
            .into_par_iter()
            .map(|i| {
                if dropped[i] {
                    return 0.0;
                }
                amp * peak[i] + mass[i] * (a0 * u[i] + 4.0 / dt * v[i] + a[i]) + alpha * mass[i] * w[i] + beta * kv[i]
            })
            .collect();
        un.copy_from_slice(&u);
        solve_shifted(op, young, hier, s, &dshift, &dropped, &r, &mut un, 1e-6, 500)?;
        let an: Vec<f64> = (0..n).into_par_iter().map(|i| if dropped[i] { 0.0 } else { a0 * (un[i] - u[i]) - 4.0 / dt * v[i] - a[i] }).collect();
        v.par_iter_mut().zip(a.par_iter()).zip(an.par_iter()).for_each(|((v, a), an)| *v += 0.5 * dt * (a + an));
        a = an;
        std::mem::swap(&mut u, &mut un);
        time.push(t);
        stress.push(stress_of(&u));
        displacement.push(u.par_chunks(3).map(|p| (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt()).reduce(|| 0.0, f64::max));
    }
    let peak_stress = stress.iter().copied().fold(0.0, f64::max);
    let peak_displacement = displacement.iter().copied().fold(0.0, f64::max);
    Ok(ImpactResponse {
        case: impact.case,
        time,
        stress,
        displacement,
        peak_stress,
        peak_displacement,
        amplification: if static_stress > 0.0 { peak_stress / static_stress } else { 0.0 },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::solid::{Grid, Region, Support, loads};

    /// A steel cantilever 40 × 4 × 4 mm: the first bending frequency near Euler-Bernoulli's.
    #[test]
    fn cantilever_first_mode_matches_beam_theory() {
        let grid = Grid::new([0.0; 3], [40.0, 4.0, 4.0], 1.0);
        let sup = [Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 5.0, 5.0] }, fix: [true; 3] }];
        let op = Operator::new(grid, 0.3, loads::fixed_dofs(&grid, &sup));
        let e = 200_000.0;
        let young = vec![e; grid.elements()];
        let rho = 7.85e-9; // t/mm³
        let mass = crate::solid::fem::lumped_mass(&grid, &vec![rho; grid.elements()]);
        let hier = Hierarchy::new(&op, &young);
        let modes = eigen(&op, &young, &hier, &mass, 2, None, 30, 1e-6).unwrap();
        // f1 = (1.875²/2π) sqrt(E I / (ρ A L⁴)).
        let (b, l) = (4.0f64, 40.0f64);
        let i = b.powi(4) / 12.0;
        let a = b * b;
        let f1 = 1.875f64.powi(2) / (2.0 * std::f64::consts::PI) * (e * i / (rho * a * l.powi(4))).sqrt();
        let got = modes[0].frequency();
        assert!((got / f1 - 1.0).abs() < 0.12, "first mode {got:.0} Hz, beam theory {f1:.0} Hz");
        // Square section: the first two modes are the two bending planes.
        assert!((modes[1].frequency() / got - 1.0).abs() < 0.05);
    }

    /// A short pulse on the cantilever's tip: the response peaks, and rings down after.
    #[test]
    fn impact_rings_and_amplifies() {
        let grid = Grid::new([0.0; 3], [20.0, 4.0, 4.0], 1.0);
        let sup = [Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 5.0, 5.0] }, fix: [true; 3] }];
        let op = Operator::new(grid, 0.3, loads::fixed_dofs(&grid, &sup));
        let young = vec![200_000.0; grid.elements()];
        let mass = crate::solid::fem::lumped_mass(&grid, &vec![7.85e-9; grid.elements()]);
        let hier = Hierarchy::new(&op, &young);
        let modes = eigen(&op, &young, &hier, &mass, 1, None, 30, 1e-6).unwrap();
        let f1 = modes[0].frequency();
        let mut peak = vec![0.0; grid.dofs()];
        for v in grid.nodes_in(&Region::Box { min: [19.9, -1.0, -1.0], max: [21.0, 5.0, 5.0] }) {
            peak[3 * v + 2] = -10.0;
        }
        let mut stat = vec![0.0; grid.dofs()];
        hier.solve(&peak, &mut stat, 1e-9, 500).unwrap();
        let static_disp = stat.chunks(3).map(|p| (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt()).fold(0.0, f64::max);
        // A pulse about half the first period: the classic dynamic load factor near 1.5 to 1.8.
        let imp = Impact { case: 0, duration: 0.5 / f1, window: 4.0 / f1, steps: 200, damping: 0.02 };
        let disp_of = |u: &[f64]| u.chunks(3).map(|p| (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt()).fold(0.0, f64::max);
        let r = impact(&op, &young, &hier, &mass, &peak, &imp, f1, static_disp, &disp_of).unwrap();
        let daf = r.peak_displacement / static_disp;
        assert!(daf > 1.2 && daf < 2.0, "dynamic load factor {daf:.2}");
    }
}
