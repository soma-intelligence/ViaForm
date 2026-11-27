//! Linear elasticity on the voxel grid: eight-node hexahedra (trilinear, 2×2×2 Gauss), applied
//! matrix-free in parallel and solved by conjugate gradients preconditioned with geometric
//! multigrid ([`super::mg`]).
//!
//! Every voxel is the same cube, so one element matrix (for E = 1) serves all of them, scaled by
//! each element's modulus. Fixed degrees of freedom are eliminated: their rows and columns act as
//! the identity, and the solver keeps them at zero.
//! Mass is in tonnes (t = N·s²/mm), so that N, mm and s agree: g/mm³ × 1e-6.
//!
//! The products gather by node row (the nodes on one line along x): a row pulls from the four
//! rows of elements around it and writes only its own entries, so no two threads share an output
//! and every sum runs in the same order on any number of cores (the results are reproducible to
//! the bit). Elements of modulus zero cost nothing. A free degree of freedom with no material
//! around its node has an empty row: the solver holds it at zero and drops any force on it.

#![allow(clippy::needless_range_loop)] // dense 24×24 algebra reads best indexed

use rayon::prelude::*;

use super::Grid;
use super::mg::Hierarchy;

/// Standard corner `s` (bottom face counter-clockwise, then the top) in lexicographic order (x
/// fastest, then y, then z), the order the kernels use; the map is its own inverse.
const LEX: [usize; 8] = [0, 1, 3, 2, 4, 5, 7, 6];

/// Poisson's ratio as the formulas take it: finite and inside (-1, 0.5).
fn poisson(nu: f64) -> f64 {
    if nu.is_finite() { nu.clamp(-0.99, 0.499) } else { 0.0 }
}

/// Isotropic elasticity for E = 1, Voigt order xx yy zz xy yz zx (engineering shears).
fn elasticity(nu: f64) -> [[f64; 6]; 6] {
    let lambda = nu / ((1.0 + nu) * (1.0 - 2.0 * nu));
    let mu = 0.5 / (1.0 + nu);
    let mut d = [[0.0; 6]; 6];
    for i in 0..3 {
        for j in 0..3 {
            d[i][j] = lambda;
        }
        d[i][i] = lambda + 2.0 * mu;
        d[i + 3][i + 3] = mu;
    }
    d
}

/// Strain-displacement matrix of a cube of edge `h` at natural point `p` (each in -1..1),
/// columns in lexicographic corner order.
fn strain_matrix(p: [f64; 3], h: f64) -> [[f64; 24]; 6] {
    let mut b = [[0.0; 24]; 6];
    for l in 0..8 {
        let s = [0, 1, 2].map(|a| if (l >> a) & 1 == 1 { 1.0 } else { -1.0 });
        let f = [0, 1, 2].map(|a| 1.0 + s[a] * p[a]);
        // dN/dx = dN/dξ · 2/h, dN/dξ = s f_η f_ζ / 8.
        let g = 2.0 / (8.0 * h);
        let d = [s[0] * f[1] * f[2] * g, f[0] * s[1] * f[2] * g, f[0] * f[1] * s[2] * g];
        let c = 3 * l;
        b[0][c] = d[0];
        b[1][c + 1] = d[1];
        b[2][c + 2] = d[2];
        b[3][c] = d[1];
        b[3][c + 1] = d[0];
        b[4][c + 1] = d[2];
        b[4][c + 2] = d[1];
        b[5][c] = d[2];
        b[5][c + 2] = d[0];
    }
    b
}

/// The element stiffness in lexicographic corner order.
fn stiffness_lex(nu: f64, h: f64) -> [[f64; 24]; 24] {
    let d = elasticity(poisson(nu));
    let g = 1.0 / 3f64.sqrt();
    let w = (h / 2.0).powi(3);
    let mut k = [[0.0; 24]; 24];
    for q in 0..8 {
        let p = [0, 1, 2].map(|a| if (q >> a) & 1 == 1 { g } else { -g });
        let b = strain_matrix(p, h);
        let mut db = [[0.0; 24]; 6];
        for i in 0..6 {
            for j in 0..24 {
                db[i][j] = (0..6).map(|m| d[i][m] * b[m][j]).sum();
            }
        }
        for i in 0..24 {
            for j in 0..24 {
                k[i][j] += w * (0..6).map(|m| b[m][i] * db[m][j]).sum::<f64>();
            }
        }
    }
    for i in 0..24 {
        for j in 0..i {
            let s = 0.5 * (k[i][j] + k[j][i]);
            k[i][j] = s;
            k[j][i] = s;
        }
    }
    k
}

/// The 24×24 stiffness of a cube of edge `h` for E = 1 and Poisson's ratio `nu`.
///
/// Degrees of freedom node by node in the grid's standard corner order ([`Grid::element_nodes`]),
/// x y z. Exact for the trilinear field (2×2×2 Gauss); scales with `h`. `nu` is clamped to
/// -0.99..0.499 (and taken as 0 when not finite).
pub fn element_stiffness(nu: f64, h: f64) -> Box<[[f64; 24]; 24]> {
    let lex = stiffness_lex(nu, h);
    let mut k = Box::new([[0.0; 24]; 24]);
    for a in 0..8 {
        for b in 0..8 {
            for i in 0..3 {
                for j in 0..3 {
                    k[3 * a + i][3 * b + j] = lex[3 * LEX[a] + i][3 * LEX[b] + j];
                }
            }
        }
    }
    k
}

/// The element matrix as the kernels read it.
#[derive(Clone)]
pub struct Kernel {
    /// Lexicographic corner order.
    pub k: [[f64; 24]; 24],
    /// For a node row through local `(dy, dz)` (index `dy + 2 dz`): the six rows of the element's
    /// two corners on that line, transposed (`[column][row]`), for six-wide multiply-adds.
    pub rows: [[[f64; 6]; 24]; 4],
}

impl Kernel {
    /// From a matrix in the standard corner order.
    pub fn new(ke: &[[f64; 24]; 24]) -> Self {
        let mut k = [[0.0; 24]; 24];
        for a in 0..8 {
            for b in 0..8 {
                for i in 0..3 {
                    for j in 0..3 {
                        k[3 * LEX[a] + i][3 * LEX[b] + j] = ke[3 * a + i][3 * b + j];
                    }
                }
            }
        }
        let mut rows = [[[0.0; 6]; 24]; 4];
        for q in 0..4 {
            for c in 0..24 {
                for r in 0..6 {
                    rows[q][c][r] = k[6 * q + r][c];
                }
            }
        }
        Self { k, rows }
    }

    /// The largest eigenvalue of `diag(K)⁻¹ K`: on any grid of these elements (any moduli, any
    /// degrees of freedom removed) it bounds the top of `D⁻¹ A`.
    pub fn jacobi_bound(&self) -> f64 {
        let mut s = [[0.0; 24]; 24];
        for i in 0..24 {
            for j in 0..24 {
                s[i][j] = self.k[i][j] / (self.k[i][i] * self.k[j][j]).sqrt();
            }
        }
        eigenvalues(s).into_iter().fold(0.0, f64::max)
    }
}

/// An element's 24 values in lexicographic corner order, from its lowest node `n0`: four runs of
/// six (the two corners on each x line).
#[inline(always)]
fn gather(u: &[f64], n0: usize, sx: usize, sxy: usize) -> [f64; 24] {
    let mut ue = [0.0; 24];
    for q in 0..4 {
        let b = 3 * (n0 + (q & 1) * sx + (q >> 1) * sxy);
        ue[6 * q..6 * q + 6].copy_from_slice(&u[b..b + 6]);
    }
    ue
}

/// `out = K(young) u` on the free rows, zero on the rows in `mask`. `u` must be zero wherever
/// `mask` is set; every length must match the grid.
pub fn apply_kernel(grid: &Grid, kern: &Kernel, young: &[f64], u: &[f64], out: &mut [f64], mask: &[bool]) {
    let [nx, ny, nz] = grid.n;
    let (sx, sxy) = (nx + 1, (nx + 1) * (ny + 1));
    out.par_chunks_mut(3 * sx).enumerate().for_each(|(row, o)| {
        let (j, k) = (row % (ny + 1), row / (ny + 1));
        o.fill(0.0);
        for ez in k.saturating_sub(1)..=k.min(nz - 1) {
            for ey in j.saturating_sub(1)..=j.min(ny - 1) {
                let q = (j - ey) + 2 * (k - ez);
                let kt = &kern.rows[q];
                let first = nx * (ey + ny * ez);
                let n0 = sx * ey + sxy * ez;
                for (ei, &e) in young[first..first + nx].iter().enumerate() {
                    if e == 0.0 {
                        continue;
                    }
                    let ue = gather(u, n0 + ei, sx, sxy);
                    // Two half sums keep two chains of multiply-adds in flight.
                    let mut a = [0.0; 6];
                    let mut b = [0.0; 6];
                    for c in (0..24).step_by(2) {
                        let (x, y) = (ue[c], ue[c + 1]);
                        for r in 0..6 {
                            a[r] = kt[c][r].mul_add(x, a[r]);
                            b[r] = kt[c + 1][r].mul_add(y, b[r]);
                        }
                    }
                    let oo = &mut o[3 * ei..3 * ei + 6];
                    for r in 0..6 {
                        oo[r] = (a[r] + b[r]).mul_add(e, oo[r]);
                    }
                }
            }
        }
        for (v, &m) in o.iter_mut().zip(&mask[3 * sx * row..3 * sx * (row + 1)]) {
            if m {
                *v = 0.0;
            }
        }
    });
}

/// The element matrix for the single-precision kernel: `k[q][r][c]` is row `6 q + r` (the two
/// corners on node line `q`), column `c`, lexicographic corner order.
#[derive(Clone)]
pub(super) struct KernelF32 {
    pub k: [[[f32; 24]; 6]; 4],
}

impl KernelF32 {
    pub fn new(kern: &Kernel) -> Self {
        let mut k = [[[0.0f32; 24]; 6]; 4];
        for q in 0..4 {
            for r in 0..6 {
                for c in 0..24 {
                    k[q][r][c] = kern.k[6 * q + r][c] as f32;
                }
            }
        }
        Self { k }
    }
}

/// [`apply_kernel`] in single precision, four elements of a row at a time: lane `l` carries
/// element `i0 + l`, its corner values deinterleaved straight from the node row (`ld3`), so every
/// multiply-add works on four elements and the element matrix is read once per four.
pub(super) fn apply_kernel_f32(grid: &Grid, kern: &KernelF32, young: &[f32], u: &[f32], out: &mut [f32], mask: &[bool]) {
    let [nx, ny, nz] = grid.n;
    let (sx, sxy) = (nx + 1, (nx + 1) * (ny + 1));
    let fits = u.len() == 3 * grid.nodes() && out.len() == u.len() && young.len() == grid.elements() && mask.len() == u.len();
    if !fits {
        out.fill(f32::NAN);
        return;
    }
    out.par_chunks_mut(3 * sx).enumerate().for_each(|(row, o)| {
        let (j, k) = (row % (ny + 1), row / (ny + 1));
        o.fill(0.0);
        for ez in k.saturating_sub(1)..=k.min(nz - 1) {
            for ey in j.saturating_sub(1)..=j.min(ny - 1) {
                let q = (j - ey) + 2 * (k - ez);
                let kq = &kern.k[q];
                let first = nx * (ey + ny * ez);
                let n0 = sx * ey + sxy * ez;
                let ys = &young[first..first + nx];
                let done = lanes4(kq, ys, u, o, n0, sx, sxy);
                for ei in done..nx {
                    let e = ys[ei];
                    if e == 0.0 {
                        continue;
                    }
                    let mut ue = [0.0f32; 24];
                    for ql in 0..4 {
                        let b = 3 * (n0 + ei + (ql & 1) * sx + (ql >> 1) * sxy);
                        ue[6 * ql..6 * ql + 6].copy_from_slice(&u[b..b + 6]);
                    }
                    for r in 0..6 {
                        let mut s = 0.0f32;
                        for c in 0..24 {
                            s = kq[r][c].mul_add(ue[c], s);
                        }
                        o[3 * ei + r] = s.mul_add(e, o[3 * ei + r]);
                    }
                }
            }
        }
        for (v, &m) in o.iter_mut().zip(&mask[3 * sx * row..3 * sx * (row + 1)]) {
            if m {
                *v = 0.0;
            }
        }
    });
}

/// The elements of one row in groups of four (NEON); answers how many it did.
#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn lanes4(kq: &[[f32; 24]; 6], ys: &[f32], u: &[f32], o: &mut [f32], n0: usize, sx: usize, sxy: usize) -> usize {
    use std::arch::aarch64::*;
    let nx = ys.len();
    let groups = nx / 4;
    for gi in 0..groups {
        let i0 = 4 * gi;
        // SAFETY: each load reads nodes n0 + i0 + line offset ..= + 4 of one node row (twelve
        // values from node i0 and from i0 + 1, i0 + 4 <= nx), inside `u`; the stores write nodes
        // i0 ..= i0 + 4 of this row's output (3 (nx + 1) values long).
        unsafe {
            let yv = vld1q_f32(ys.as_ptr().add(i0));
            if vmaxvq_f32(vabsq_f32(yv)) == 0.0 {
                continue;
            }
            let mut acc = [vdupq_n_f32(0.0); 6];
            for ql in 0..4 {
                let p = u.as_ptr().add(3 * (n0 + i0 + (ql & 1) * sx + (ql >> 1) * sxy));
                let a = vld3q_f32(p);
                let b = vld3q_f32(p.add(3));
                let uv = [a.0, a.1, a.2, b.0, b.1, b.2];
                for r in 0..6 {
                    let kr = &kq[r][6 * ql..6 * ql + 6];
                    let mut s = acc[r];
                    for c in 0..6 {
                        s = vfmaq_n_f32(s, uv[c], kr[c]);
                    }
                    acc[r] = s;
                }
            }
            let po = o.as_mut_ptr().add(3 * i0);
            let mut lo = vld3q_f32(po);
            lo.0 = vfmaq_f32(lo.0, acc[0], yv);
            lo.1 = vfmaq_f32(lo.1, acc[1], yv);
            lo.2 = vfmaq_f32(lo.2, acc[2], yv);
            vst3q_f32(po, lo);
            let po = po.add(3);
            let mut hi = vld3q_f32(po);
            hi.0 = vfmaq_f32(hi.0, acc[3], yv);
            hi.1 = vfmaq_f32(hi.1, acc[4], yv);
            hi.2 = vfmaq_f32(hi.2, acc[5], yv);
            vst3q_f32(po, hi);
        }
    }
    4 * groups
}

/// Elsewhere every element goes through the scalar loop.
#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
fn lanes4(_: &[[f32; 24]; 6], _: &[f32], _: &[f32], _: &mut [f32], _: usize, _: usize, _: usize) -> usize {
    0
}

/// The diagonal of `K(young)` (fixed degrees of freedom not singled out).
pub(super) fn diagonal_kernel(grid: &Grid, kern: &Kernel, young: &[f64], out: &mut [f64]) {
    let [nx, ny, nz] = grid.n;
    let sx = nx + 1;
    out.par_chunks_mut(3 * sx).enumerate().for_each(|(row, o)| {
        let (j, k) = (row % (ny + 1), row / (ny + 1));
        o.fill(0.0);
        for ez in k.saturating_sub(1)..=k.min(nz - 1) {
            for ey in j.saturating_sub(1)..=j.min(ny - 1) {
                let q = (j - ey) + 2 * (k - ez);
                let first = nx * (ey + ny * ez);
                for (ei, &e) in young[first..first + nx].iter().enumerate() {
                    for r in 0..6 {
                        o[3 * ei + r] += e * kern.k[6 * q + r][6 * q + r];
                    }
                }
            }
        }
    });
}

/// The stiffness operator of one grid.
#[derive(Clone)]
pub struct Operator {
    pub grid: Grid,
    pub nu: f64,
    /// Per degree of freedom: held by a support.
    pub fixed: Vec<bool>,
    pub ke: Box<[[f64; 24]; 24]>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SolveStats {
    pub iterations: usize,
    /// Relative residual reached.
    pub residual: f64,
}

impl Operator {
    pub fn new(grid: Grid, nu: f64, fixed: Vec<bool>) -> Self {
        let ke = element_stiffness(nu, grid.h);
        Self { grid, nu, fixed, ke }
    }

    /// Why the operator cannot be used with `young`, if it cannot.
    pub(super) fn check(&self, young: &[f64]) -> Result<(), String> {
        let g = &self.grid;
        if g.n.contains(&0) {
            return Err(format!("empty grid {:?}", g.n));
        }
        if !(g.h.is_finite() && g.h > 0.0) {
            return Err(format!("voxel edge {} is not a positive length", g.h));
        }
        if !(self.nu.is_finite() && self.nu > -1.0 && self.nu < 0.5) {
            return Err(format!("Poisson's ratio {} is outside -1..0.5", self.nu));
        }
        if self.fixed.len() != g.dofs() {
            return Err(format!("{} fixed flags for {} degrees of freedom", self.fixed.len(), g.dofs()));
        }
        if young.len() != g.elements() {
            return Err(format!("{} moduli for {} elements", young.len(), g.elements()));
        }
        if self.ke.iter().flatten().any(|v| !v.is_finite()) {
            return Err("element stiffness is not finite".into());
        }
        if let Some(e) = young.iter().position(|y| !(y.is_finite() && *y >= 0.0)) {
            return Err(format!("modulus {} of element {e} is not a finite non-negative value", young[e]));
        }
        Ok(())
    }

    /// Whether the slices fit the grid (the products fill their output with NaN when not).
    fn fits(&self, young: Option<&[f64]>, u: &[f64]) -> bool {
        let g = &self.grid;
        !g.n.contains(&0) && u.len() == g.dofs() && self.fixed.len() == g.dofs() && young.is_none_or(|y| y.len() == g.elements())
    }

    /// `out = K(young) u`, `young` per element (MPa).
    ///
    /// Fixed rows and columns are the identity: `out[d] = u[d]` on a fixed `d`, and fixed entries
    /// of `u` add nothing to the free rows. Mismatched lengths give NaN throughout.
    pub fn apply(&self, young: &[f64], u: &[f64], out: &mut [f64]) {
        if !self.fits(Some(young), u) || out.len() != u.len() {
            out.fill(f64::NAN);
            return;
        }
        let kern = Kernel::new(&self.ke);
        let dirty = self.fixed.par_iter().zip(u.par_iter()).any(|(&f, &x)| f && x != 0.0);
        let clean: Vec<f64>;
        let src = if dirty {
            clean = u.par_iter().zip(self.fixed.par_iter()).map(|(&x, &f)| if f { 0.0 } else { x }).collect();
            &clean[..]
        } else {
            u
        };
        apply_kernel(&self.grid, &kern, young, src, out, &self.fixed);
        out.par_iter_mut().zip(u.par_iter()).zip(self.fixed.par_iter()).for_each(|((o, &x), &f)| {
            if f {
                *o = x;
            }
        });
    }

    /// The diagonal of `K(young)`: one on fixed degrees of freedom, zero on free ones without
    /// material around them.
    pub fn diagonal(&self, young: &[f64], out: &mut [f64]) {
        if !self.fits(Some(young), out) {
            out.fill(f64::NAN);
            return;
        }
        diagonal_kernel(&self.grid, &Kernel::new(&self.ke), young, out);
        out.par_iter_mut().zip(self.fixed.par_iter()).for_each(|(o, &f)| {
            if f {
                *o = 1.0;
            }
        });
    }

    /// Per element, `u_eᵀ K_e u_e` for E = 1 (the compliance sensitivity's core).
    pub fn energy(&self, u: &[f64], out: &mut [f64]) {
        let g = self.grid;
        if !self.fits(None, u) || out.len() != g.elements() {
            out.fill(f64::NAN);
            return;
        }
        let k = Kernel::new(&self.ke).k;
        let [nx, ny, _] = g.n;
        let (sx, sxy) = (nx + 1, (nx + 1) * (ny + 1));
        out.par_chunks_mut(nx).enumerate().for_each(|(row, o)| {
            let n0 = sx * (row % ny) + sxy * (row / ny);
            for (ei, v) in o.iter_mut().enumerate() {
                let ue = gather(u, n0 + ei, sx, sxy);
                let mut s = 0.0;
                for i in 0..24 {
                    let mut t = 0.0;
                    for j in 0..24 {
                        t = k[i][j].mul_add(ue[j], t);
                    }
                    s = ue[i].mul_add(t, s);
                }
                *v = s;
            }
        });
    }

    /// Per element, von Mises stress at the centre for a solid modulus `young` (MPa).
    pub fn von_mises(&self, young: f64, u: &[f64], out: &mut [f64]) {
        let g = self.grid;
        if !self.fits(None, u) || out.len() != g.elements() {
            out.fill(f64::NAN);
            return;
        }
        let d = elasticity(poisson(self.nu));
        let b = strain_matrix([0.0; 3], g.h);
        let mut db = [[0.0; 24]; 6];
        for i in 0..6 {
            for j in 0..24 {
                db[i][j] = young * (0..6).map(|m| d[i][m] * b[m][j]).sum::<f64>();
            }
        }
        let [nx, ny, _] = g.n;
        let (sx, sxy) = (nx + 1, (nx + 1) * (ny + 1));
        out.par_chunks_mut(nx).enumerate().for_each(|(row, o)| {
            let n0 = sx * (row % ny) + sxy * (row / ny);
            for (ei, v) in o.iter_mut().enumerate() {
                let ue = gather(u, n0 + ei, sx, sxy);
                let s: [f64; 6] = std::array::from_fn(|i| (0..24).map(|j| db[i][j] * ue[j]).sum());
                let normal = (s[0] - s[1]).powi(2) + (s[1] - s[2]).powi(2) + (s[2] - s[0]).powi(2);
                *v = (0.5 * normal + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5])).sqrt();
            }
        });
    }

    /// Solves `K(young) u = f` (u holds the starting guess and receives the answer).
    ///
    /// Conjugate gradients preconditioned by one multigrid V-cycle ([`Hierarchy`]), to a relative
    /// residual `‖f - K u‖ / ‖f‖ ≤ tol` over the free degrees of freedom; fixed ones come back
    /// zero. `Err` on bad input or a residual that is not finite; otherwise `Ok`, with the residual
    /// reached when `max_iter` ran out or the iteration broke down. To solve several right-hand
    /// sides with the same moduli, build the [`Hierarchy`] once and call [`Hierarchy::solve`].
    pub fn solve(&self, young: &[f64], f: &[f64], u: &mut [f64], tol: f64, max_iter: usize) -> Result<SolveStats, String> {
        Hierarchy::new(self, young).solve(f, u, tol, max_iter)
    }
}

/// Lumped mass per degree of freedom, tonnes, from each element's mass density (t/mm³).
pub fn lumped_mass(grid: &Grid, rho: &[f64]) -> Vec<f64> {
    let mut m = vec![0.0; grid.dofs()];
    let share = grid.h.powi(3) / 8.0;
    for (e, &r) in rho.iter().enumerate().take(grid.elements()) {
        for d in grid.element_dofs(e) {
            m[d] += r * share;
        }
    }
    m
}

/// Adds the study's point masses (g) to a lumped mass vector (tonnes per degree of freedom),
/// each spread evenly over its region's nodes that carry material (`m` already holds the
/// structure's own mass): a node of the region that only void touches (in a bore cut through
/// it) has no stiffness, and a mass there would ring on its own.
pub fn add_point_masses(grid: &Grid, masses: &[super::PointMass], m: &mut [f64]) {
    for pm in masses {
        let all = grid.nodes_in(&pm.region);
        let most = all.iter().map(|&v| m[3 * v]).fold(0.0, f64::max);
        let held: Vec<usize> = all.iter().copied().filter(|&v| m[3 * v] >= 0.01 * most).collect();
        let nodes = if most > 0.0 { held } else { all };
        if nodes.is_empty() {
            continue;
        }
        let each = pm.mass_g * 1e-6 / nodes.len() as f64;
        for v in nodes {
            for a in 0..3 {
                m[3 * v + a] += each;
            }
        }
    }
}

/// Eigenvalues of a symmetric matrix (cyclic Jacobi), unordered.
pub(super) fn eigenvalues<const N: usize>(mut a: [[f64; N]; N]) -> [f64; N] {
    for _ in 0..100 {
        let off: f64 = (0..N).flat_map(|i| (0..N).filter(move |&j| j != i).map(move |j| (i, j))).map(|(i, j)| a[i][j] * a[i][j]).sum();
        let scale: f64 = (0..N).map(|i| a[i][i] * a[i][i]).sum();
        if off <= 1e-30 * scale.max(f64::MIN_POSITIVE) {
            break;
        }
        for p in 0..N {
            for q in p + 1..N {
                if a[p][q] == 0.0 {
                    continue;
                }
                let theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
                let t = theta.signum() / (theta.abs() + (theta * theta + 1.0).sqrt());
                let t = if theta == 0.0 { 1.0 } else { t };
                let c = 1.0 / (t * t + 1.0).sqrt();
                let s = t * c;
                for k in 0..N {
                    let (akp, akq) = (a[k][p], a[k][q]);
                    a[k][p] = c * akp - s * akq;
                    a[k][q] = s * akp + c * akq;
                }
                for k in 0..N {
                    let (apk, aqk) = (a[p][k], a[q][k]);
                    a[p][k] = c * apk - s * aqk;
                    a[q][k] = s * apk + c * aqk;
                }
            }
        }
    }
    std::array::from_fn(|i| a[i][i])
}

/// The stress at an element's centre per unit modulus, `σ = S u_e`, rows in Voigt order (xx yy
/// zz xy yz zx), columns in lexicographic corner order (see [`lex_dofs`]).
pub(super) fn stress_matrix(nu: f64, h: f64) -> [[f64; 24]; 6] {
    let d = elasticity(poisson(nu));
    let b = strain_matrix([0.0; 3], h);
    let mut s = [[0.0; 24]; 6];
    for i in 0..6 {
        for j in 0..24 {
            s[i][j] = (0..6).map(|m| d[i][m] * b[m][j]).sum::<f64>();
        }
    }
    s
}

/// The thermal expansion coupling of a cube of edge `h` for E = 1 and α = 1: `G = ∫ Bᵀ D m Nᵀ
/// dV` (m = [1 1 1 0 0 0]), so the nodal forces of an element heated by `θ` (its eight corner
/// temperature rises) are `E α G θ`. Rows: the 24 degrees of freedom node by node, columns the
/// eight corners, both in the grid's standard corner order ([`Grid::element_nodes`]). 2×2×2
/// Gauss, exact for the trilinear fields.
pub fn thermal_coupling(nu: f64, h: f64) -> [[f64; 8]; 24] {
    let d = elasticity(poisson(nu));
    let dm: [f64; 6] = std::array::from_fn(|i| d[i][0] + d[i][1] + d[i][2]);
    let g = 1.0 / 3f64.sqrt();
    let w = (h / 2.0).powi(3);
    let mut lex = [[0.0; 8]; 24];
    for q in 0..8 {
        let p = [0, 1, 2].map(|a| if (q >> a) & 1 == 1 { g } else { -g });
        let b = strain_matrix(p, h);
        let n: [f64; 8] = std::array::from_fn(|l| (0..3).map(|a| 0.5 * (1.0 + if (l >> a) & 1 == 1 { p[a] } else { -p[a] })).product());
        for i in 0..24 {
            let bt: f64 = (0..6).map(|m| b[m][i] * dm[m]).sum();
            for c in 0..8 {
                lex[i][c] += w * bt * n[c];
            }
        }
    }
    let mut out = [[0.0; 8]; 24];
    for a in 0..8 {
        for c in 0..8 {
            for i in 0..3 {
                out[3 * a + i][c] = lex[3 * LEX[a] + i][LEX[c]];
            }
        }
    }
    out
}

/// `D m` for E = 1: the stress of a unit free thermal strain held fully, `1 / (1 - 2ν)` on the
/// three normal components.
pub fn thermal_stress_unit(nu: f64) -> f64 {
    1.0 / (1.0 - 2.0 * poisson(nu))
}

/// The 24 degrees of freedom of element `e` in lexicographic corner order (x fastest), the order
/// of [`stress_matrix`]'s columns.
pub(super) fn lex_dofs(grid: &Grid, e: usize) -> [usize; 24] {
    let [i, j, k] = grid.element_ijk(e);
    std::array::from_fn(|d| {
        let c = d / 3;
        3 * grid.node(i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1)) + d % 3
    })
}

/// Von Mises of a Voigt stress, and its gradient with respect to the six components.
pub(super) fn von_mises_grad(s: &[f64; 6]) -> (f64, [f64; 6]) {
    let normal = (s[0] - s[1]).powi(2) + (s[1] - s[2]).powi(2) + (s[2] - s[0]).powi(2);
    let vm = (0.5 * normal + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5])).sqrt();
    if vm <= 0.0 {
        return (0.0, [0.0; 6]);
    }
    let g = [
        (2.0 * s[0] - s[1] - s[2]) / (2.0 * vm),
        (2.0 * s[1] - s[0] - s[2]) / (2.0 * vm),
        (2.0 * s[2] - s[0] - s[1]) / (2.0 * vm),
        3.0 * s[3] / vm,
        3.0 * s[4] / vm,
        3.0 * s[5] / vm,
    ];
    (vm, g)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn point_masses_skip_nodes_only_void_touches() {
        // Three voxels in a row, the last void: the mass goes on the eight nodes the solid two
        // leave out of the far face only, never on the four the void alone holds.
        let g = Grid::new([0.0; 3], [3.0, 1.0, 1.0], 1.0);
        let rho = [1.0, 1.0, 0.0];
        let mut m = lumped_mass(&g, &rho);
        let before = m.clone();
        let region = crate::solid::Region::Box { min: [-0.1; 3], max: [3.1, 1.1, 1.1] };
        add_point_masses(&g, &[crate::solid::PointMass { region, mass_g: 12.0 }], &mut m);
        let added: Vec<f64> = (0..g.nodes()).map(|v| m[3 * v] - before[3 * v]).collect();
        let far = (0..g.nodes()).filter(|&v| g.node_ijk(v)[0] == 3);
        for v in far {
            assert_eq!(added[v], 0.0);
        }
        let total: f64 = added.iter().sum();
        assert!((total - 12e-6).abs() < 1e-15, "{total}");
    }

    fn noise(i: usize) -> f64 {
        let mut z = (i as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        z ^= z >> 29;
        z = z.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z ^= z >> 32;
        (z >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
    }

    /// The global matrix of a small grid, assembled densely from the standard element matrix.
    fn dense(op: &Operator, young: &[f64]) -> Vec<Vec<f64>> {
        let n = op.grid.dofs();
        let mut k = vec![vec![0.0; n]; n];
        for e in 0..op.grid.elements() {
            let dofs = op.grid.element_dofs(e);
            for a in 0..24 {
                for b in 0..24 {
                    k[dofs[a]][dofs[b]] += young[e] * op.ke[a][b];
                }
            }
        }
        for d in 0..n {
            if op.fixed[d] {
                for x in 0..n {
                    k[d][x] = 0.0;
                    k[x][d] = 0.0;
                }
                k[d][d] = 1.0;
            }
        }
        k
    }

    #[test]
    fn element_matrix() {
        let k = element_stiffness(0.3, 1.0);
        // Exact: on a unit cube ∫(∂N/∂x)² dV = 1/9 for every corner, so
        // k₀₀ = (λ + 2μ + 2μ) / 9 = (2 - 3ν) / 9 / ((1 + ν)(1 - 2ν)). (top3d prints twice this:
        // its matrix carries a factor of 2 that its own scaling absorbs.)
        let k00 = (2.0 - 0.9) / 9.0 / (1.3 * 0.4);
        assert!((k[0][0] - k00).abs() < 1e-12, "{} vs {k00}", k[0][0]);
        let mut s = [[0.0; 24]; 24];
        for i in 0..24 {
            for j in 0..24 {
                assert!((k[i][j] - k[j][i]).abs() < 1e-14);
                assert!((k[i][i] - k00).abs() < 1e-12, "all diagonal entries agree");
                s[i][j] = k[i][j];
            }
        }
        let mut ev = eigenvalues(s);
        ev.sort_by(f64::total_cmp);
        let top = ev[23];
        assert!(ev[..6].iter().all(|v| v.abs() < 1e-12 * top), "six rigid-body modes: {ev:?}");
        assert!(ev[6] > 1e-3 * top, "no other zero mode: {ev:?}");
        // Scales with h.
        let k2 = element_stiffness(0.3, 2.5);
        assert!((k2[5][17] - 2.5 * k[5][17]).abs() < 1e-12);
        // Rigid motions in the standard order.
        let g = Grid::new([0.0; 3], [1.0; 3], 1.0);
        let pos: Vec<[f64; 3]> = g.element_nodes(0).iter().map(|&v| g.node_position(v)).collect();
        let modes: [fn([f64; 3]) -> [f64; 3]; 6] = [
            |_| [1.0, 0.0, 0.0],
            |_| [0.0, 1.0, 0.0],
            |_| [0.0, 0.0, 1.0],
            |p| [-p[1], p[0], 0.0],
            |p| [0.0, -p[2], p[1]],
            |p| [p[2], 0.0, -p[0]],
        ];
        for m in modes {
            let u: Vec<f64> = pos.iter().flat_map(|&p| m(p)).collect();
            for row in k.iter() {
                assert!(row.iter().zip(&u).map(|(a, b)| a * b).sum::<f64>().abs() < 1e-12);
            }
        }
    }

    #[test]
    fn products_match_a_dense_assembly() {
        let g = Grid::new([0.0; 3], [3.0, 2.0, 2.0], 1.0);
        let n = g.dofs();
        let fixed: Vec<bool> = (0..n).map(|d| noise(d + 1000) > 0.6).collect();
        let op = Operator::new(g, 0.3, fixed);
        let mut young: Vec<f64> = (0..g.elements()).map(|e| 1.0 + 1000.0 * noise(e).abs()).collect();
        young[4] = 0.0;
        let u: Vec<f64> = (0..n).map(noise).collect();
        let k = dense(&op, &young);
        let mut out = vec![0.0; n];
        op.apply(&young, &u, &mut out);
        for d in 0..n {
            let want: f64 = (0..n).map(|x| k[d][x] * u[x]).sum();
            assert!((out[d] - want).abs() < 1e-9 * (1.0 + want.abs()), "dof {d}: {} vs {want}", out[d]);
        }
        op.diagonal(&young, &mut out);
        for d in 0..n {
            assert!((out[d] - k[d][d]).abs() < 1e-9 * k[d][d]);
        }
        // Energy: Σ E uᵀKu over elements is the quadratic form (fixed entries zeroed).
        let uc: Vec<f64> = u.iter().zip(&op.fixed).map(|(&x, &f)| if f { 0.0 } else { x }).collect();
        let mut en = vec![0.0; g.elements()];
        op.energy(&uc, &mut en);
        let total: f64 = en.iter().zip(&young).map(|(a, b)| a * b).sum();
        let mut ku = vec![0.0; n];
        op.apply(&young, &uc, &mut ku);
        let quad: f64 = uc.iter().zip(&ku).map(|(a, b)| a * b).sum();
        assert!((total - quad).abs() < 1e-9 * quad.abs());
        // Bad lengths do not panic.
        op.apply(&young[1..], &u, &mut out);
        assert!(out[0].is_nan());
    }

    #[test]
    fn stress_of_a_uniform_strain() {
        // u = ε x along x, -ν ε y and -ν ε z: uniaxial stress E ε, von Mises E ε.
        let g = Grid::new([0.0; 3], [4.0, 3.0, 2.0], 0.5);
        let (nu, e, eps) = (0.3, 200_000.0, 1e-3);
        let op = Operator::new(g, nu, vec![false; g.dofs()]);
        let u: Vec<f64> = (0..g.nodes()).flat_map(|v| {
            let p = g.node_position(v);
            [eps * p[0], -nu * eps * p[1], -nu * eps * p[2]]
        }).collect();
        let mut vm = vec![0.0; g.elements()];
        op.von_mises(e, &u, &mut vm);
        assert!(vm.iter().all(|s| (s - e * eps).abs() < 1e-9 * e * eps), "{}", vm[0]);
        // A uniform strain is in equilibrium: no force inside.
        let young = vec![e; g.elements()];
        let mut f = vec![0.0; g.dofs()];
        op.apply(&young, &u, &mut f);
        for v in 0..g.nodes() {
            let [i, j, k] = g.node_ijk(v);
            if (1..g.n[0]).contains(&i) && (1..g.n[1]).contains(&j) && (1..g.n[2]).contains(&k) {
                assert!(f[3 * v].abs() < 1e-8 && f[3 * v + 1].abs() < 1e-8 && f[3 * v + 2].abs() < 1e-8);
            }
        }
    }

    #[test]
    fn jacobi_bound() {
        let b = Kernel::new(&element_stiffness(0.3, 1.0)).jacobi_bound();
        assert!(b > 1.0 && b < 8.0, "{b}");
    }
}
