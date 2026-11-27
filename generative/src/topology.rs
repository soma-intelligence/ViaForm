//! SIMP topology optimisation on a grid of bilinear plane-stress elements.
//!
//! The domain is cut into `nx` × `ny` square cells: `nx = round(width / resolution)`, the cell is
//! `width / nx` so the grid spans the width exactly, and `ny = round(height / cell)`, so it spans
//! the height to within half a cell. Densities follow the modified SIMP law
//! `E(x) = Emin + x^p (E - Emin)` with `Emin = 1e-9 E`, pass through a density filter (Andreassen
//! et al., 2011) and move by optimality criteria. Each step solves every load case with a
//! conjugate gradient preconditioned by a geometric multigrid V-cycle ([`fem`]), warm started from
//! the step before; the objective is the sum of the cases' compliances.
//!
//! Supports hold the nodes inside their region, loads spread over the nodes inside theirs (the
//! nearest node to the region's centre if none is inside). Elements whose centre lies in a
//! keep-out region stay empty, in a keep-in region solid; keep-out wins where both apply.

mod fem;

use crate::spec::{Fix, Region, Shape, Solved, Spec, Symmetry};

/// `Emin / E`.
const EMIN_RATIO: f64 = 1e-9;
/// Largest density change per step.
const MOVE: f64 = 0.2;
/// The design has settled when no density moves more than this in a step.
const CHANGE_TOL: f64 = 0.01;
/// Stress relaxation exponent: an element of density `x` carries `x^q` of the solid's stress.
const STRESS_Q: f64 = 0.5;
/// Only elements denser than this count towards the reported stress.
const STRESS_SOLID: f64 = 0.5;
/// Relative residual the displacement solve stops at.
const CG_TOL: f64 = 1e-6;
const CG_MAX: usize = 2000;
/// Smallest filter radius, in cells.
const MIN_FILTER: f64 = 1.5;

/// Optimises element densities for minimum compliance under `volume_fraction`.
pub fn solve(spec: &Spec, volume_fraction: f64) -> Result<Solved, String> {
    let grid = Grid::new(spec)?;
    let mat = &spec.material;
    if !(mat.e.is_finite() && mat.e > 0.0 && (0.0..0.5).contains(&mat.nu)) {
        return Err("material needs e > 0 and 0 ≤ nu < 0.5".into());
    }
    if !(spec.thickness.is_finite() && spec.thickness > 0.0) {
        return Err("thickness must be a positive number".into());
    }
    if !(volume_fraction.is_finite() && volume_fraction > 0.0 && volume_fraction <= 1.0) {
        return Err("volume_fraction must be between 0 and 1".into());
    }
    let penal = spec.penal;
    if !(penal.is_finite() && penal >= 1.0) {
        return Err("penal must be at least 1".into());
    }
    let ne = grid.nx * grid.ny;
    let fixed = supports(&grid, spec)?;
    let forces = loads(&grid, spec, &fixed)?;
    let passive = passive(&grid, spec);
    let radius = if spec.filter_radius.is_finite() { spec.filter_radius / grid.cell } else { 0.0 };
    let filter = Filter::new(&grid, radius.max(MIN_FILTER));
    let fea = Fea { grid: &grid, ke: fem::element_stiffness(mat.nu, spec.thickness), e: mat.e, penal, fixed: &fixed };

    // Total solid the design may hold, keep-in included.
    let target = volume_fraction * ne as f64;
    let active = passive.iter().filter(|p| p.is_none()).count();
    let solid = passive.iter().filter(|&&p| p == Some(1.0)).count() as f64;
    let start = if active > 0 { ((target - solid) / active as f64).clamp(0.0, 1.0) } else { 0.0 };
    let mut x: Vec<f64> = passive.iter().map(|p| p.unwrap_or(start)).collect();
    let mut phys = physical(&filter, &x, &passive);
    let mut us = vec![vec![0.0; 2 * grid.nodes()]; forces.len()];
    let mut history = Vec::new();

    for _ in 0..spec.iterations {
        let (obj, mut dc) = fea.analyse(&phys, &forces, &mut us)?;
        history.push(obj);
        if active == 0 {
            break;
        }
        let mut dv = vec![1.0; ne];
        for (e, p) in passive.iter().enumerate() {
            if p.is_some() {
                dc[e] = 0.0;
                dv[e] = 0.0;
            }
        }
        let mut dc = filter.back(&dc);
        let mut dv = filter.back(&dv);
        symmetrise(&mut dc, &grid, spec.symmetry);
        symmetrise(&mut dv, &grid, spec.symmetry);
        let mut next = optimality(&x, &dc, &dv, &passive, &filter, target);
        symmetrise(&mut next, &grid, spec.symmetry);
        for (v, p) in next.iter_mut().zip(&passive) {
            if let Some(p) = p {
                *v = *p;
            }
        }
        let change = x.iter().zip(&next).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        x = next;
        phys = physical(&filter, &x, &passive);
        if change < CHANGE_TOL {
            break;
        }
    }

    // The settled design, analysed once more.
    let (compliance, _) = fea.analyse(&phys, &forces, &mut us)?;
    let (max_stress, max_displacement) = fea.stress_and_displacement(&phys, &us, mat.e, mat.nu);
    let values: Vec<f64> = phys.iter().map(|v| v.clamp(0.0, 1.0)).collect();
    let volume_fraction = values.iter().sum::<f64>() / ne as f64;
    Ok(Solved {
        shape: Shape::Density { nx: grid.nx, ny: grid.ny, cell: grid.cell, values },
        compliance,
        max_stress,
        max_displacement,
        volume_fraction,
        history,
    })
}

/// The element grid.
struct Grid {
    nx: usize,
    ny: usize,
    cell: f64,
}

impl Grid {
    fn new(spec: &Spec) -> Result<Self, String> {
        let positive = [("width", spec.width), ("height", spec.height), ("resolution", spec.resolution)];
        if let Some((name, _)) = positive.iter().find(|(_, v)| !(v.is_finite() && *v > 0.0)) {
            return Err(format!("{name} must be a positive number"));
        }
        let nx = (spec.width / spec.resolution).round().max(1.0);
        let cell = spec.width / nx;
        let ny = (spec.height / cell).round().max(1.0);
        if nx * ny > 250_000.0 {
            return Err("the grid is too fine: raise the resolution (at most 250 000 elements)".into());
        }
        Ok(Self { nx: nx as usize, ny: ny as usize, cell })
    }

    fn nodes(&self) -> usize {
        (self.nx + 1) * (self.ny + 1)
    }

    fn node_position(&self, n: usize) -> [f64; 2] {
        let mx = self.nx + 1;
        [(n % mx) as f64 * self.cell, (n / mx) as f64 * self.cell]
    }

    fn element_centre(&self, e: usize) -> [f64; 2] {
        [((e % self.nx) as f64 + 0.5) * self.cell, ((e / self.nx) as f64 + 0.5) * self.cell]
    }

    /// Unknowns of element `e`, corner by corner.
    fn dofs(&self, e: usize) -> [usize; 8] {
        let (i, j, mx) = (e % self.nx, e / self.nx, self.nx + 1);
        let n = [j * mx + i, j * mx + i + 1, (j + 1) * mx + i + 1, (j + 1) * mx + i];
        [2 * n[0], 2 * n[0] + 1, 2 * n[1], 2 * n[1] + 1, 2 * n[2], 2 * n[2] + 1, 2 * n[3], 2 * n[3] + 1]
    }

    /// Nodes inside `region`, or the node nearest its centre if none is.
    fn region_nodes(&self, region: &Region) -> Vec<usize> {
        let inside: Vec<usize> = (0..self.nodes()).filter(|&n| region.contains(self.node_position(n))).collect();
        if !inside.is_empty() {
            return inside;
        }
        let c = region.center();
        let snap = |v: f64, max: usize| {
            let v = (v / self.cell).round();
            if v.is_finite() { v.clamp(0.0, max as f64) as usize } else { 0 }
        };
        vec![snap(c[1], self.ny) * (self.nx + 1) + snap(c[0], self.nx)]
    }
}

/// Held unknowns. Refuses supports that leave a rigid-body motion free.
fn supports(grid: &Grid, spec: &Spec) -> Result<Vec<bool>, String> {
    if spec.supports.is_empty() {
        return Err("at least one support is required".into());
    }
    let mut fixed = vec![false; 2 * grid.nodes()];
    for s in &spec.supports {
        for n in grid.region_nodes(&s.region) {
            match s.fix {
                Fix::All => {
                    fixed[2 * n] = true;
                    fixed[2 * n + 1] = true;
                }
                Fix::X => fixed[2 * n] = true,
                Fix::Y => fixed[2 * n + 1] = true,
            }
        }
    }
    // Each held unknown removes one combination of the rigid motions (translate X, translate Y,
    // rotate): the supports hold the part when those rows span all three.
    let (w, h) = (grid.nx as f64 * grid.cell, grid.ny as f64 * grid.cell);
    let l = w.max(h);
    let mut g = [[0.0; 3]; 3];
    for (d, _) in fixed.iter().enumerate().filter(|(_, f)| **f) {
        let p = grid.node_position(d / 2);
        let (x, y) = ((p[0] - w / 2.0) / l, (p[1] - h / 2.0) / l);
        let row = if d % 2 == 0 { [1.0, 0.0, -y] } else { [0.0, 1.0, x] };
        for r in 0..3 {
            for c in 0..3 {
                g[r][c] += row[r] * row[c];
            }
        }
    }
    let det = g[0][0] * (g[1][1] * g[2][2] - g[1][2] * g[2][1]) - g[0][1] * (g[1][0] * g[2][2] - g[1][2] * g[2][0])
        + g[0][2] * (g[1][0] * g[2][1] - g[1][1] * g[2][0]);
    let tr = (g[0][0] + g[1][1] + g[2][2]) / 3.0;
    if det.is_nan() || det <= 1e-10 * tr * tr * tr {
        return Err("the supports leave the part free to move: hold it in both directions, at two points or more".into());
    }
    Ok(fixed)
}

/// One force vector per load case that has loads; held unknowns carry none.
fn loads(grid: &Grid, spec: &Spec, fixed: &[bool]) -> Result<Vec<Vec<f64>>, String> {
    let mut forces = Vec::new();
    for case in spec.cases.iter().filter(|c| !c.loads.is_empty()) {
        let mut f = vec![0.0; 2 * grid.nodes()];
        for load in &case.loads {
            if !(load.force[0].is_finite() && load.force[1].is_finite()) {
                return Err("load forces must be finite".into());
            }
            let nodes = grid.region_nodes(&load.region);
            let share = 1.0 / nodes.len() as f64;
            for n in nodes {
                f[2 * n] += load.force[0] * share;
                f[2 * n + 1] += load.force[1] * share;
            }
        }
        for (v, &held) in f.iter_mut().zip(fixed) {
            if held {
                *v = 0.0;
            }
        }
        forces.push(f);
    }
    if forces.iter().all(|f| f.iter().all(|&v| v == 0.0)) {
        return Err("no load reaches the part: every load is zero or sits on a support".into());
    }
    Ok(forces)
}

/// Each element's fixed density, if any: 0 in keep-out regions, 1 in keep-in regions.
fn passive(grid: &Grid, spec: &Spec) -> Vec<Option<f64>> {
    (0..grid.nx * grid.ny)
        .map(|e| {
            let c = grid.element_centre(e);
            if spec.keep_out.iter().any(|r| r.contains(c)) {
                Some(0.0)
            } else if spec.keep_in.iter().any(|r| r.contains(c)) {
                Some(1.0)
            } else {
                None
            }
        })
        .collect()
}

/// Physical densities: the filtered design, passive elements at their fixed value.
fn physical(filter: &Filter, x: &[f64], passive: &[Option<f64>]) -> Vec<f64> {
    let mut phys = filter.apply(x);
    for (v, p) in phys.iter_mut().zip(passive) {
        if let Some(p) = p {
            *v = *p;
        }
    }
    phys
}

/// Averages each value with its mirror images.
fn symmetrise(v: &mut [f64], grid: &Grid, sym: Symmetry) {
    let (nx, ny) = (grid.nx, grid.ny);
    if sym.x {
        for j in 0..ny {
            for i in 0..nx / 2 {
                let (a, b) = (j * nx + i, j * nx + nx - 1 - i);
                let m = 0.5 * (v[a] + v[b]);
                v[a] = m;
                v[b] = m;
            }
        }
    }
    if sym.y {
        for j in 0..ny / 2 {
            for i in 0..nx {
                let (a, b) = (j * nx + i, (ny - 1 - j) * nx + i);
                let m = 0.5 * (v[a] + v[b]);
                v[a] = m;
                v[b] = m;
            }
        }
    }
}

/// Optimality criteria update: bisects the Lagrange multiplier until the physical densities
/// hold `target`.
fn optimality(x: &[f64], dc: &[f64], dv: &[f64], passive: &[Option<f64>], filter: &Filter, target: f64) -> Vec<f64> {
    // The update does not change when the sensitivities scale; normalising keeps the bracket valid.
    let scale = dc.iter().fold(0.0, |m: f64, v| m.max(v.abs()));
    let scale = if scale > 0.0 { scale } else { 1.0 };
    let update = |lambda: f64| -> Vec<f64> {
        x.iter()
            .zip(dc.iter().zip(dv))
            .zip(passive)
            .map(|((&x, (&dc, &dv)), p)| match p {
                Some(p) => *p,
                None => {
                    let b = (-dc / scale).max(0.0) / (dv.max(1e-30) * lambda);
                    (x * b.sqrt()).clamp(x - MOVE, x + MOVE).clamp(0.0, 1.0)
                }
            })
            .collect()
    };
    // Bisection on a log scale: the multiplier spans many decades.
    let (mut l1, mut l2): (f64, f64) = (1e-15, 1e15);
    for _ in 0..100 {
        if l2 / l1 - 1.0 < 1e-6 {
            break;
        }
        let mid = (l1 * l2).sqrt();
        let volume: f64 = physical(filter, &update(mid), passive).iter().sum();
        if volume > target {
            l1 = mid;
        } else {
            l2 = mid;
        }
    }
    update((l1 * l2).sqrt())
}

/// Density filter: weights `max(0, r - distance)` over neighbouring element centres, in cells.
struct Filter {
    start: Vec<usize>,
    idx: Vec<usize>,
    w: Vec<f64>,
    sum: Vec<f64>,
}

impl Filter {
    fn new(grid: &Grid, r: f64) -> Self {
        let (nx, ny) = (grid.nx as isize, grid.ny as isize);
        let reach = r.ceil() as isize - 1;
        let (mut start, mut idx, mut w, mut sum) = (vec![0], Vec::new(), Vec::new(), Vec::new());
        for j in 0..ny {
            for i in 0..nx {
                let mut s = 0.0;
                for jj in (j - reach).max(0)..=(j + reach).min(ny - 1) {
                    for ii in (i - reach).max(0)..=(i + reach).min(nx - 1) {
                        let weight = r - (((ii - i).pow(2) + (jj - j).pow(2)) as f64).sqrt();
                        if weight > 0.0 {
                            idx.push((jj * nx + ii) as usize);
                            w.push(weight);
                            s += weight;
                        }
                    }
                }
                start.push(idx.len());
                sum.push(s);
            }
        }
        Self { start, idx, w, sum }
    }

    /// Filtered densities: `y_e = Σ w_ek x_k / Σ w_ek`.
    fn apply(&self, x: &[f64]) -> Vec<f64> {
        (0..self.sum.len())
            .map(|e| {
                let r = self.start[e]..self.start[e + 1];
                self.idx[r.clone()].iter().zip(&self.w[r]).map(|(&k, w)| w * x[k]).sum::<f64>() / self.sum[e]
            })
            .collect()
    }

    /// Chain rule through [`Filter::apply`]: `y_e = Σ w_ek d_k / Σ_l w_kl`.
    fn back(&self, d: &[f64]) -> Vec<f64> {
        let scaled: Vec<f64> = d.iter().zip(&self.sum).map(|(d, s)| d / s).collect();
        (0..self.sum.len())
            .map(|e| {
                let r = self.start[e]..self.start[e + 1];
                self.idx[r.clone()].iter().zip(&self.w[r]).map(|(&k, w)| w * scaled[k]).sum()
            })
            .collect()
    }
}

/// The finite-element model a density field is analysed on.
struct Fea<'a> {
    grid: &'a Grid,
    /// Unit-modulus element stiffness, thickness included.
    ke: [[f64; 8]; 8],
    e: f64,
    penal: f64,
    fixed: &'a [bool],
}

impl Fea<'_> {
    /// Solves every case (warm started from `us`, which it updates) and returns the summed
    /// compliance and its derivative with respect to each physical density.
    fn analyse(&self, phys: &[f64], forces: &[Vec<f64>], us: &mut [Vec<f64>]) -> Result<(f64, Vec<f64>), String> {
        let (grid, p) = (self.grid, self.penal);
        let emin = EMIN_RATIO * self.e;
        let factors: Vec<f64> = phys.iter().map(|x| emin + x.max(0.0).powf(p) * (self.e - emin)).collect();
        let mut k = fem::Stencil::assemble(grid.nx, grid.ny, &self.ke, &factors);
        for (d, _) in self.fixed.iter().enumerate().filter(|(_, f)| **f) {
            k.pin(d);
        }
        let solver = fem::Solver::new(k)?;
        let mut total = 0.0;
        let mut dc = vec![0.0; phys.len()];
        for (f, u) in forces.iter().zip(us.iter_mut()) {
            solver.solve(f, u, CG_TOL, CG_MAX)?;
            total += f.iter().zip(u.iter()).map(|(f, u)| f * u).sum::<f64>();
            for (e, (dc, x)) in dc.iter_mut().zip(phys).enumerate() {
                let ue = self.grid.dofs(e).map(|d| u[d]);
                let ce: f64 = (0..8).map(|r| ue[r] * (0..8).map(|c| self.ke[r][c] * ue[c]).sum::<f64>()).sum();
                *dc -= p * x.max(0.0).powf(p - 1.0) * (self.e - emin) * ce;
            }
        }
        if !total.is_finite() {
            return Err("the displacement solve diverged".into());
        }
        Ok((total, dc))
    }

    /// Worst von Mises stress at element centres over the cases (solid elements only, relaxed
    /// by `x^q`), MPa, and worst nodal displacement, mm.
    fn stress_and_displacement(&self, phys: &[f64], us: &[Vec<f64>], e: f64, nu: f64) -> (f64, f64) {
        let b = fem::strain_matrix(self.grid.cell, 0.0, 0.0);
        let d = fem::elasticity(e, nu);
        let mut stress: f64 = 0.0;
        let mut disp: f64 = 0.0;
        for u in us {
            for n in u.as_chunks::<2>().0 {
                disp = disp.max(n[0].hypot(n[1]));
            }
            for (el, &x) in phys.iter().enumerate().filter(|(_, x)| **x > STRESS_SOLID) {
                let ue = self.grid.dofs(el).map(|k| u[k]);
                let eps: [f64; 3] = std::array::from_fn(|r| (0..8).map(|c| b[r][c] * ue[c]).sum());
                let s: [f64; 3] = std::array::from_fn(|r| x.powf(STRESS_Q) * (0..3).map(|c| d[r][c] * eps[c]).sum::<f64>());
                let vm = (s[0] * s[0] - s[0] * s[1] + s[1] * s[1] + 3.0 * s[2] * s[2]).max(0.0).sqrt();
                stress = stress.max(vm);
            }
        }
        (stress, disp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Load, LoadCase, Support};
    use std::time::Instant;

    fn rect(min: [f64; 2], max: [f64; 2]) -> Region {
        Region::Rect { min, max }
    }

    fn circle(center: [f64; 2], radius: f64) -> Region {
        Region::Circle { center, radius }
    }

    /// 120 × 40 mm at 2 mm, left edge clamped, 1 kN down at the right middle.
    fn cantilever() -> Spec {
        Spec {
            supports: vec![Support { region: rect([-0.1, -0.1], [0.1, 40.1]), fix: Fix::All }],
            cases: vec![LoadCase { name: "tip".into(), loads: vec![Load { region: circle([120.0, 20.0], 0.5), force: [0.0, -1000.0] }] }],
            ..Spec::default()
        }
    }

    fn values(s: &Solved) -> (usize, usize, f64, &[f64]) {
        match &s.shape {
            Shape::Density { nx, ny, cell, values } => (*nx, *ny, *cell, values),
            Shape::Frame { .. } => panic!("expected densities"),
        }
    }

    #[test]
    fn topology_cantilever_converges() {
        let spec = cantilever();
        let t = Instant::now();
        let s = solve(&spec, 0.4).unwrap();
        eprintln!(
            "cantilever 60x20: {:?}, {} iterations, compliance {:.3} N·mm, stress {:.1} MPa, displacement {:.4} mm",
            t.elapsed(),
            s.history.len(),
            s.compliance,
            s.max_stress,
            s.max_displacement
        );
        let (nx, ny, cell, v) = values(&s);
        assert_eq!((nx, ny, cell), (60, 20, 2.0));
        let (first, last) = (s.history[0], s.history[s.history.len() - 1]);
        assert!(last < 0.5 * first, "compliance {first} -> {last}");
        let n = s.history.len();
        assert!((s.history[n - 1] - s.history[n - 2]).abs() < 0.01 * last, "not settled: {:?}", &s.history[n - 5..]);
        assert!((s.volume_fraction - 0.4).abs() < 0.02 * 0.4, "volume {}", s.volume_fraction);
        assert!(v.iter().all(|x| (0.0..=1.0).contains(x)));
        assert!(s.compliance.is_finite() && s.compliance > 0.0);
        assert!(s.max_stress > 0.0 && s.max_displacement > 0.0);
        // Thresholded at one half, the solid holds about the asked share.
        let solid = v.iter().filter(|&&x| x > 0.5).count() as f64 / v.len() as f64;
        assert!((solid - 0.4).abs() < 0.06, "solid share {solid}");
    }

    #[test]
    fn topology_keep_out_stays_empty() {
        let mut spec = cantilever();
        let hole = circle([50.0, 20.0], 8.0);
        spec.keep_out = vec![hole];
        spec.keep_in = vec![rect([100.0, 14.0], [120.0, 26.0])];
        let s = solve(&spec, 0.4).unwrap();
        let (nx, _, cell, v) = values(&s);
        let mut inside = 0;
        for (e, &x) in v.iter().enumerate() {
            let c = [((e % nx) as f64 + 0.5) * cell, ((e / nx) as f64 + 0.5) * cell];
            if hole.contains(c) {
                inside += 1;
                assert_eq!(x, 0.0);
            } else if spec.keep_in[0].contains(c) {
                assert_eq!(x, 1.0);
            }
        }
        assert!(inside > 40);
        assert!((s.volume_fraction - 0.4).abs() < 0.02 * 0.4, "volume {}", s.volume_fraction);
    }

    #[test]
    fn topology_symmetric_beam_is_symmetric() {
        // MBB-style beam on the full span: pinned and rolling bottom corners, load at top centre.
        let spec = Spec {
            supports: vec![
                Support { region: circle([0.0, 0.0], 0.5), fix: Fix::All },
                Support { region: circle([120.0, 0.0], 0.5), fix: Fix::Y },
            ],
            cases: vec![LoadCase { name: "mid".into(), loads: vec![Load { region: circle([60.0, 40.0], 0.5), force: [0.0, -1000.0] }] }],
            symmetry: Symmetry { x: true, y: false },
            volume_fraction: 0.5,
            ..Spec::default()
        };
        let s = solve(&spec, 0.5).unwrap();
        let (nx, ny, _, v) = values(&s);
        for j in 0..ny {
            for i in 0..nx {
                assert!((v[j * nx + i] - v[j * nx + nx - 1 - i]).abs() < 1e-9, "({i}, {j})");
            }
        }
        assert!(s.history[s.history.len() - 1] < s.history[0]);
    }

    #[test]
    fn topology_load_cases_sum() {
        let mut spec = cantilever();
        spec.cases.push(LoadCase { name: "up".into(), loads: vec![Load { region: circle([120.0, 20.0], 0.5), force: [0.0, 1000.0] }] });
        let s = solve(&spec, 0.4).unwrap();
        assert!(s.compliance.is_finite() && s.compliance > 0.0);
        assert!((s.volume_fraction - 0.4).abs() < 0.02 * 0.4);
    }

    #[test]
    fn topology_refuses_degenerate_studies() {
        let mut spec = cantilever();
        spec.supports.clear();
        assert!(solve(&spec, 0.4).is_err());
        // One pinned point leaves rotation free.
        let mut spec = cantilever();
        spec.supports = vec![Support { region: circle([0.0, 20.0], 0.5), fix: Fix::All }];
        assert!(solve(&spec, 0.4).is_err());
        // Held along X only.
        let mut spec = cantilever();
        spec.supports[0].fix = Fix::X;
        assert!(solve(&spec, 0.4).is_err());
        // Load on the support.
        let mut spec = cantilever();
        spec.cases[0].loads[0].region = circle([0.0, 20.0], 0.5);
        assert!(solve(&spec, 0.4).is_err());
        let mut spec = cantilever();
        spec.resolution = 0.0;
        assert!(solve(&spec, 0.4).is_err());
    }

    #[test]
    fn topology_large_grid_runs() {
        // 200 × 100 elements. Wall time is printed, not asserted: shared machines make it noisy.
        let spec = Spec {
            width: 200.0,
            height: 100.0,
            resolution: 1.0,
            filter_radius: 1.5,
            supports: vec![Support { region: rect([-0.1, -0.1], [0.1, 100.1]), fix: Fix::All }],
            cases: vec![LoadCase { name: "tip".into(), loads: vec![Load { region: circle([200.0, 50.0], 0.5), force: [0.0, -1000.0] }] }],
            ..Spec::default()
        };
        let t = Instant::now();
        let s = solve(&spec, 0.4).unwrap();
        let elapsed = t.elapsed();
        eprintln!("cantilever 200x100: {elapsed:?}, {} iterations, compliance {:.3}", s.history.len(), s.compliance);
        assert!(s.history[s.history.len() - 1] < s.history[0]);
    }
}
