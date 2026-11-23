//! Geometric multigrid for the voxel stiffness: a hierarchy of grids coarsened two to one along
//! every axis, Galerkin coarse operators, Chebyshev smoothing and a direct solve on the coarsest
//! level. Used as the conjugate gradient's preconditioner (one V-cycle), after Amir, Aage and
//! Lazarov (2014) and Aage, Andreassen and Lazarov (2015).
//!
//! Coarsening: an axis of `n ≥ 2` cells halves to `⌈n / 2⌉`; when `n` is odd the last coarse cell
//! spans one fine cell, so any size coarsens without padding (an axis of one cell stays).
//! Prolongation `P` is trilinear between the coarse nodes and restriction is `Pᵀ`. The first
//! coarse operator is assembled from the fine elements (`Qᵀ Kₑ Q` per element, by its place in
//! its coarse cell), each next one from the one above (`Pᵀ A P` on stencils); both are stored as
//! 27 blocks of 3×3 per node, while the fine level stays matrix-free. Coarsening stops at the
//! first level a banded Cholesky factorises cheaply (nodes renumbered shortest axis first).
//!
//! Fixed degrees of freedom: the fine level drops them (and any free one with no material
//! around it), and the prolongation never writes into them, so every coarse operator is the
//! Galerkin product of the reduced stiffness. A coarse degree of freedom whose fine images are
//! all dropped comes out with an empty row and is dropped in turn. Vectors stay zero on dropped
//! entries at every level, so no identity rows mix with the stiffness's own scale, and the
//! hierarchy holds up under the 1e-9 contrast of a SIMP layout.
//!
//! Smoothing: Chebyshev polynomials of degree two in `D⁻¹A` before and after the coarse
//! correction, aimed at the top seven eighths of the spectrum; with the exact coarsest solve this
//! keeps the V-cycle symmetric positive definite, as the conjugate gradient needs. The top of the
//! spectrum is bounded exactly on the fine level by the element's own, and estimated on the
//! coarse ones by power iteration.
//!
//! Mixed precision: [`Hierarchy::new`] runs the V-cycle in `f32` (fine level matrix-free with a
//! four-elements-wide kernel, coarse stencils, smoothing and transfers) and the conjugate
//! gradient in `f64`, with its own exact product; the gradient takes flexible (Polak-Ribière)
//! steps, so the preconditioner's rounding costs iterations at most, never accuracy. A solve that
//! stalls in single precision finishes on an exact `f64` twin. [`Hierarchy::exact`] is `f64`
//! throughout.
//!
//! Every reduction runs in fixed chunks summed in order, so a solve gives the same bits on every
//! run and any number of cores.

#![allow(clippy::needless_range_loop)] // stencil algebra reads best indexed

use std::sync::{Mutex, OnceLock};

use rayon::prelude::*;

use super::fem::{self, Kernel, Operator, SolveStats};
use super::Grid;

/// Polynomial degree of each smoothing (before and after the coarse correction).
const DEGREE: usize = 2;
/// Chebyshev aims at `[hi / RATIO, hi]` of `D⁻¹A`'s spectrum.
const RATIO: f64 = 8.0;
/// Power iterations for a coarse level's spectrum, and the margin on the estimate.
const POWER_STEPS: usize = 10;
const MARGIN: f64 = 1.1;
/// The coarsest level: factorised once its banded Cholesky costs at most this many
/// multiply-adds and holds at most `DIRECT_DOFS` unknowns.
const DIRECT_COST: f64 = 2.5e8;
const DIRECT_DOFS: usize = 24_000;
/// Reduction chunk: fixed, so sums do not depend on the thread count.
const CHUNK: usize = 1 << 13;
/// Entries per stencil node: 27 neighbours (`(dx+1) + 3(dy+1) + 9(dz+1)`), 3×3 each, row-major.
const NODE: usize = 243;
const CENTRE: usize = 13;

/// One axis of a coarsening step (or of none).
#[derive(Clone, Copy, Debug)]
struct Axis {
    /// Cells on the finer level and on the coarser one.
    fine: usize,
    coarse: usize,
    halve: bool,
}

impl Axis {
    fn new(fine: usize) -> Self {
        if fine >= 2 { Self { fine, coarse: fine.div_ceil(2), halve: true } } else { Self::keep(fine) }
    }

    fn keep(fine: usize) -> Self {
        Self { fine, coarse: fine, halve: false }
    }

    /// The coarse nodes fine node `f` interpolates from, with weights.
    fn up(&self, f: usize) -> ([(usize, f64); 2], usize) {
        if !self.halve || f % 2 == 0 {
            ([(if self.halve { f / 2 } else { f }, 1.0), (0, 0.0)], 1)
        } else if f == self.fine {
            ([(self.coarse, 1.0), (0, 0.0)], 1)
        } else {
            ([(f / 2, 0.5), (f / 2 + 1, 0.5)], 2)
        }
    }

    /// The fine nodes coarse node `c` reaches, with weights.
    fn down(&self, c: usize) -> ([(usize, f64); 3], usize) {
        let mut out = [(0, 0.0); 3];
        if !self.halve {
            out[0] = (c, 1.0);
            return (out, 1);
        }
        if c == self.coarse && self.fine % 2 == 1 {
            out[0] = (self.fine, 1.0);
            return (out, 1);
        }
        let p = 2 * c;
        out[0] = (p, 1.0);
        let mut len = 1;
        if p >= 1 {
            out[len] = (p - 1, 0.5);
            len += 1;
        }
        if p + 1 < self.fine {
            out[len] = (p + 1, 0.5);
            len += 1;
        }
        (out, len)
    }

    /// The fine cells inside coarse cell `c`, each with its place in it: 0 the lower half, 1 the
    /// upper half, 2 the whole cell.
    fn children(&self, c: usize) -> ([(usize, usize); 2], usize) {
        if !self.halve {
            ([(c, 2), (0, 0)], 1)
        } else if 2 * c + 1 < self.fine {
            ([(2 * c, 0), (2 * c + 1, 1)], 2)
        } else {
            ([(2 * c, 2), (0, 0)], 1)
        }
    }
}

/// Chebyshev smoothing on `[lo, hi]`, as its centre and half-width.
#[derive(Clone, Copy, Debug, Default)]
struct Cheb {
    theta: f64,
    delta: f64,
}

impl Cheb {
    fn new(hi: f64) -> Self {
        let lo = hi / RATIO;
        Self { theta: 0.5 * (hi + lo), delta: 0.5 * (hi - lo) }
    }
}

/// The arithmetic a hierarchy runs its V-cycle in: `f64` (exact), or `f32` (mixed precision:
/// the cycle is only a preconditioner, so single precision costs no accuracy in the solution,
/// which the conjugate gradient keeps in `f64`, and halves the memory every pass streams).
pub(super) trait Real:
    Copy
    + Send
    + Sync
    + Default
    + PartialEq
    + PartialOrd
    + std::fmt::Debug
    + std::ops::Add<Output = Self>
    + std::ops::Sub<Output = Self>
    + std::ops::Mul<Output = Self>
    + std::ops::Div<Output = Self>
    + std::ops::AddAssign
    + 'static
{
    const ZERO: Self;
    fn of(v: f64) -> Self;
    fn f(self) -> f64;
    /// `out = K(young) x` on the fine level (zero on `mask`).
    fn apply_fine(fine: &Fine<Self>, x: &[Self], out: &mut [Self]);
    /// `out = A x` for a coarse level's stencil, in this precision's layout.
    fn apply_stencil(nodes: [usize; 3], st: &[Self], x: &[Self], out: &mut [Self]);
    /// The fine level's moduli in `f64`.
    fn young64(fine: &Fine<Self>) -> &[f64];
}

impl Real for f64 {
    const ZERO: Self = 0.0;
    #[inline(always)]
    fn of(v: f64) -> Self {
        v
    }
    #[inline(always)]
    fn f(self) -> f64 {
        self
    }
    fn apply_fine(fine: &Fine<Self>, x: &[Self], out: &mut [Self]) {
        fem::apply_kernel(&fine.grid, &fine.kern, &fine.young, x, out, &fine.mask);
    }
    fn young64(fine: &Fine<Self>) -> &[f64] {
        &fine.young
    }
    fn apply_stencil(nodes: [usize; 3], st: &[Self], x: &[Self], out: &mut [Self]) {
        stencil_apply(nodes, st, x, out);
    }
}

impl Real for f32 {
    const ZERO: Self = 0.0;
    #[inline(always)]
    fn of(v: f64) -> Self {
        v as f32
    }
    #[inline(always)]
    fn f(self) -> f64 {
        self as f64
    }
    fn apply_fine(fine: &Fine<Self>, x: &[Self], out: &mut [Self]) {
        fem::apply_kernel_f32(&fine.grid, &fine.lanes, &fine.young, x, out, &fine.mask);
    }
    fn young64(fine: &Fine<Self>) -> &[f64] {
        &fine.young_exact
    }
    fn apply_stencil(nodes: [usize; 3], st: &[Self], x: &[Self], out: &mut [Self]) {
        stencil_apply_f32(nodes, st, x, out);
    }
}

/// The finest level: the operator's grid, applied matrix-free.
pub(super) struct Fine<T> {
    grid: Grid,
    kern: Kernel,
    /// The element matrix as the single-precision kernel reads it.
    lanes: fem::KernelF32,
    young: Vec<T>,
    /// The moduli in `f64` when `young` is not (the conjugate gradient's product stays exact).
    young_exact: Vec<f64>,
    fixed: Vec<bool>,
    /// Dropped: fixed, or free without material.
    mask: Vec<bool>,
    /// Zero where dropped.
    inv_diag: Vec<T>,
    smooth: Cheb,
}

/// A coarse level.
struct Level<T> {
    nodes: [usize; 3],
    /// The coarsening from the level above.
    axes: [Axis; 3],
    stencil: Vec<T>,
    /// Zero where dropped (an empty row).
    inv_diag: Vec<T>,
    smooth: Cheb,
}

impl Level<f64> {
    fn new(axes: [Axis; 3], stencil: Vec<f64>) -> Self {
        let nodes = axes.map(|a| a.coarse + 1);
        let inv_diag = (0..stencil.len() / NODE * 3)
            .map(|d| {
                let v = stencil[NODE * (d / 3) + 9 * CENTRE + 4 * (d % 3)];
                if v > 0.0 { 1.0 / v } else { 0.0 }
            })
            .collect();
        Self { nodes, axes, stencil, inv_diag, smooth: Cheb::default() }
    }

    fn to_f32(&self) -> Level<f32> {
        Level { nodes: self.nodes, axes: self.axes, stencil: group_stencil(self.nodes, &self.stencil), inv_diag: to_f32(&self.inv_diag), smooth: self.smooth }
    }
}

impl<T> Level<T> {
    fn cells(&self) -> [usize; 3] {
        self.axes.map(|a| a.coarse)
    }
}

fn to_f32(v: &[f64]) -> Vec<f32> {
    let mut o = vec![0.0f32; v.len()];
    o.par_chunks_mut(CHUNK).zip(v.par_chunks(CHUNK)).for_each(|(o, v)| {
        for (o, &v) in o.iter_mut().zip(v) {
            *o = v as f32;
        }
    });
    o
}

/// Scratch vectors, per level: right-hand side and solution (coarse levels), Chebyshev
/// direction and operator product; and the fine level's right-hand side and
/// solution in the cycle's own precision (mixed precision only).
struct Work<T> {
    r: Vec<Vec<T>>,
    z: Vec<Vec<T>>,
    d: Vec<Vec<T>>,
    t: Vec<Vec<T>>,
    r0: Vec<T>,
    z0: Vec<T>,
}

/// One hierarchy's levels in one precision.
struct Parts<T> {
    fine: Fine<T>,
    levels: Vec<Level<T>>,
    /// Factor of the coarsest level (the fine one when the grid is that small).
    direct: Band,
    work: Mutex<Option<Work<T>>>,
}


pub struct Hierarchy {
    exact: OnceLock<Result<Parts<f64>, String>>,
    mixed: Option<Parts<f32>>,
    /// The operator, for the exact twin of a mixed hierarchy (built only when a solve in single
    /// precision stalls).
    source: Option<Operator>,
    /// Why the hierarchy could not be built.
    error: Option<String>,
}

impl Hierarchy {
    /// Builds the levels for the moduli `young` on the operator's grid, in mixed precision: the
    /// V-cycle in `f32`, the conjugate gradient in `f64` (flexible, so the rounding of the
    /// preconditioner costs nothing). A solve that stalls in single precision finishes on an
    /// exact `f64` hierarchy built then.
    ///
    /// Never fails outright: on bad input (lengths, a modulus not finite or negative, a bad
    /// voxel edge or Poisson's ratio) [`Hierarchy::solve`] returns the reason.
    pub fn new(op: &Operator, young: &[f64]) -> Self {
        let failed = |e: String| Self { exact: OnceLock::new(), mixed: None, source: None, error: Some(e) };
        let exact = match build(op, young, false) {
            Ok(h) => h,
            Err(e) => return failed(e),
        };
        // The cycle in single precision; the spectra are estimated on the levels as they run.
        let mut levels: Vec<Level<f32>> = exact.levels.iter().map(Level::to_f32).collect();
        if let Err(e) = estimate_spectra(&mut levels) {
            return failed(e);
        }
        let Parts { fine: f, direct, .. } = exact;
        let fine = Fine { grid: f.grid, kern: f.kern, lanes: f.lanes, young: to_f32(&f.young), young_exact: f.young, fixed: f.fixed, mask: f.mask, inv_diag: to_f32(&f.inv_diag), smooth: f.smooth };
        let mixed = Parts { fine, levels, direct, work: Mutex::new(None) };
        Self { exact: OnceLock::new(), mixed: Some(mixed), source: Some(op.clone()), error: None }
    }

    /// The hierarchy in `f64` throughout: a V-cycle that is symmetric to rounding, for checks
    /// and for callers that need it.
    pub fn exact(op: &Operator, young: &[f64]) -> Self {
        let exact = OnceLock::new();
        let (error, built) = match build(op, young, true) {
            Ok(h) => (None, Ok(h)),
            Err(e) => (Some(e.clone()), Err(e)),
        };
        let _ = exact.set(built);
        Self { exact, mixed: None, source: None, error }
    }

    /// The exact levels, built on first use for a mixed hierarchy.
    fn exact_parts(&self) -> Result<&Parts<f64>, String> {
        self.exact
            .get_or_init(|| match &self.source {
                Some(op) => match &self.mixed {
                    Some(m) => build(op, &m.fine.young_exact, true),
                    None => Err("multigrid hierarchy missing".into()),
                },
                None => Err(self.error.clone().unwrap_or_else(|| "multigrid hierarchy missing".into())),
            })
            .as_ref()
            .map_err(Clone::clone)
    }

    /// The fine level's grid data, whichever precision runs.
    fn mask(&self) -> Option<&[bool]> {
        if let Some(m) = &self.mixed {
            return Some(&m.fine.mask);
        }
        match self.exact.get() {
            Some(Ok(p)) => Some(&p.fine.mask),
            _ => None,
        }
    }

    fn fixed(&self) -> Option<&[bool]> {
        if let Some(m) = &self.mixed {
            return Some(&m.fine.fixed);
        }
        match self.exact.get() {
            Some(Ok(p)) => Some(&p.fine.fixed),
            _ => None,
        }
    }

    /// Per degree of freedom of the fine level: dropped (held, or free with no material around
    /// it); `None` when the build failed.
    pub fn dropped(&self) -> Option<&[bool]> {
        self.mask()
    }

    /// Levels, the fine one included (0 when the build failed).
    pub fn levels(&self) -> usize {
        if let Some(m) = &self.mixed {
            return 1 + m.levels.len();
        }
        match self.exact.get() {
            Some(Ok(p)) => 1 + p.levels.len(),
            _ => 0,
        }
    }

    /// Whether the V-cycle runs in single precision.
    pub fn mixed(&self) -> bool {
        self.mixed.is_some()
    }

    /// One V-cycle: `z ≈ K⁻¹ r`.
    ///
    /// Fixed degrees of freedom pass through (`z[d] = r[d]`, the identity rows); free ones
    /// without material get zero. A linear, symmetric positive definite map of `r` (to the
    /// rounding of `f32` when mixed). Mismatched lengths (or a failed build) give NaN.
    pub fn vcycle(&self, r: &[f64], z: &mut [f64]) {
        let (Some(mask), Some(fixed)) = (self.mask(), self.fixed()) else {
            z.fill(f64::NAN);
            return;
        };
        if r.len() != mask.len() || z.len() != r.len() {
            z.fill(f64::NAN);
            return;
        }
        match &self.mixed {
            Some(p) => p.precondition(r, z),
            None => match self.exact_parts() {
                Ok(p) => p.precondition(r, z),
                Err(_) => {
                    z.fill(f64::NAN);
                    return;
                }
            },
        }
        z.par_iter_mut().zip(r.par_iter()).zip(fixed.par_iter()).for_each(|((z, &r), &f)| {
            if f {
                *z = r;
            }
        });
    }

    /// Solves `K u = f` by conjugate gradients preconditioned with one V-cycle, from the guess in
    /// `u`, to a relative residual `tol` (see [`Operator::solve`]).
    pub fn solve(&self, f: &[f64], u: &mut [f64], tol: f64, max_iter: usize) -> Result<SolveStats, String> {
        if let Some(e) = &self.error {
            return Err(e.clone());
        }
        let Some(mask) = self.mask() else {
            return Err("multigrid hierarchy missing".into());
        };
        let n = mask.len();
        if f.len() != n || u.len() != n {
            return Err(format!("{} forces and {} displacements for {n} degrees of freedom", f.len(), u.len()));
        }
        if tol.is_nan() || tol < 0.0 {
            return Err(format!("tolerance {tol} is not a non-negative number"));
        }
        if f.par_iter().any(|x| !x.is_finite()) {
            return Err("force is not finite".into());
        }
        if u.par_iter().any(|x| !x.is_finite()) {
            return Err("starting displacement is not finite".into());
        }
        match &self.mixed {
            Some(p) => {
                let s = p.cg(f, u, tol, max_iter, true)?;
                if s.residual <= tol || s.iterations >= max_iter {
                    return Ok(s);
                }
                // Stalled in single precision (a breakdown, not the iteration cap): finish exact.
                let e = self.exact_parts()?.cg(f, u, tol, max_iter - s.iterations, false)?;
                Ok(SolveStats { iterations: s.iterations + e.iterations, residual: e.residual })
            }
            None => self.exact_parts()?.cg(f, u, tol, max_iter, false),
        }
    }
}

impl<T: Real> Parts<T> {
    /// `z = V(r)` for a clean `r` given in `f64` (dropped entries zero or not).
    fn precondition(&self, r: &[f64], z: &mut [f64]) {
        let fine = &self.fine;
        self.with_work(|w| {
            let (mut r0, mut z0) = (std::mem::take(&mut w.r0), std::mem::take(&mut w.z0));
            r0.par_chunks_mut(CHUNK).zip(r.par_chunks(CHUNK)).zip(fine.mask.par_chunks(CHUNK)).for_each(|((o, r), m)| {
                for i in 0..o.len() {
                    o[i] = if m[i] { T::ZERO } else { T::of(r[i]) };
                }
            });
            self.cycle(w, &r0, &mut z0);
            z.par_chunks_mut(CHUNK).zip(z0.par_chunks(CHUNK)).for_each(|(o, z)| {
                for i in 0..o.len() {
                    o[i] = z[i].f();
                }
            });
            w.r0 = r0;
            w.z0 = z0;
        });
    }

    /// Preconditioned conjugate gradients from `u`; `flexible` takes the Polak-Ribière step
    /// (`β = zₖ₊₁ · (rₖ₊₁ - rₖ) / zₖ · rₖ`), which stays a descent method when the preconditioner
    /// is only symmetric to its rounding. The residual is kept in `f64` and handed to the cycle
    /// in its own precision by the same pass that updates it; the cycle's answer is read in
    /// place, never copied back to `f64`.
    fn cg(&self, f: &[f64], u: &mut [f64], tol: f64, max_iter: usize, flexible: bool) -> Result<SolveStats, String> {
        let fine = &self.fine;
        let n = fine.mask.len();
        u.par_iter_mut().zip(fine.mask.par_iter()).for_each(|(x, &m)| {
            if m {
                *x = 0.0;
            }
        });
        let mut r = vec![0.0; n];
        apply_f64(fine, u, &mut r);
        self.with_work(|w| {
            let (mut r0, mut z0) = (std::mem::take(&mut w.r0), std::mem::take(&mut w.z0));
            let out = self.cg_in(w, &mut r0, &mut z0, f, u, &mut r, tol, max_iter, flexible);
            w.r0 = r0;
            w.z0 = z0;
            out
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn cg_in(&self, w: &mut Work<T>, r0: &mut [T], z: &mut [T], f: &[f64], u: &mut [f64], r: &mut [f64], tol: f64, max_iter: usize, flexible: bool) -> Result<SolveStats, String> {
        let fine = &self.fine;
        let n = r.len();
        let mut fnorm = 0.0;
        let mut rr = 0.0;
        {
            let parts: Vec<(f64, f64)> = r
                .par_chunks_mut(CHUNK)
                .zip(r0.par_chunks_mut(CHUNK))
                .zip(f.par_chunks(CHUNK))
                .zip(fine.mask.par_chunks(CHUNK))
                .map(|(((r, r0), f), m)| {
                    let (mut ff, mut s) = (0.0, 0.0);
                    for i in 0..r.len() {
                        let b = if m[i] { 0.0 } else { f[i] };
                        r[i] = b - r[i];
                        r0[i] = T::of(r[i]);
                        ff += b * b;
                        s += r[i] * r[i];
                    }
                    (ff, s)
                })
                .collect();
            for (a, b) in parts {
                fnorm += a;
                rr += b;
            }
        }
        let fnorm = fnorm.sqrt();
        if fnorm == 0.0 {
            u.fill(0.0);
            return Ok(SolveStats { iterations: 0, residual: 0.0 });
        }
        let mut stats = SolveStats { iterations: 0, residual: rr.sqrt() / fnorm };
        if !stats.residual.is_finite() {
            return Err("residual is not finite".into());
        }
        if stats.residual <= tol || max_iter == 0 {
            return Ok(stats);
        }
        let mut p = vec![0.0; n];
        let mut q = vec![0.0; n];
        self.cycle(w, r0, z);
        p.par_chunks_mut(CHUNK).zip(z.par_chunks(CHUNK)).for_each(|(p, z)| {
            for i in 0..p.len() {
                p[i] = z[i].f();
            }
        });
        let mut rz = dot2(r, r, z).0;
        if !(rz > 0.0) {
            return if rz.is_finite() { Ok(stats) } else { Err("preconditioned residual is not finite".into()) };
        }
        for it in 1..=max_iter {
            apply_f64(fine, &p, &mut q);
            let pq = dot(&p, &q);
            if !pq.is_finite() {
                return Err("search direction is not finite".into());
            }
            if pq <= 0.0 {
                break;
            }
            let alpha = rz / pq;
            let rr = step(u, r, r0, &p, &q, alpha);
            stats = SolveStats { iterations: it, residual: rr.sqrt() / fnorm };
            if !stats.residual.is_finite() {
                return Err("residual is not finite".into());
            }
            if stats.residual <= tol {
                break;
            }
            self.cycle(w, r0, z);
            let (rz_next, zq) = dot2(r, &q, z);
            // zₖ₊₁ · (rₖ₊₁ - rₖ) = -α zₖ₊₁ · q.
            let num = if flexible { -alpha * zq } else { rz_next };
            if !(rz_next > 0.0) {
                break;
            }
            let beta = (num / rz).max(0.0);
            rz = rz_next;
            p.par_chunks_mut(CHUNK).zip(z.par_chunks(CHUNK)).for_each(|(p, z)| {
                for i in 0..p.len() {
                    p[i] = beta.mul_add(p[i], z[i].f());
                }
            });
        }
        Ok(stats)
    }

    fn with_work<R>(&self, f: impl FnOnce(&mut Work<T>) -> R) -> R {
        // A second caller at the same time (or after a panic) gets its own scratch.
        match self.work.try_lock() {
            Ok(mut slot) => {
                let w = slot.get_or_insert_with(|| self.new_work());
                f(w)
            }
            Err(_) => f(&mut self.new_work()),
        }
    }

    fn new_work(&self) -> Work<T> {
        let fine = &self.fine;
        let sizes: Vec<usize> = std::iter::once(fine.mask.len()).chain(self.levels.iter().map(|l| l.inv_diag.len())).collect();
        let last = sizes.len() - 1;
        let alloc = |skip_fine: bool, skip_last: bool| -> Vec<Vec<T>> {
            sizes.iter().enumerate().map(|(l, &s)| if (skip_fine && l == 0) || (skip_last && l == last && l > 0) { Vec::new() } else { vec![T::ZERO; s] }).collect()
        };
        Work { r: alloc(true, false), z: alloc(true, false), d: alloc(false, true), t: alloc(false, true), r0: vec![T::ZERO; sizes[0]], z0: vec![T::ZERO; sizes[0]] }
    }

    fn nodes(&self, l: usize) -> [usize; 3] {
        if l == 0 { self.fine.grid.n.map(|c| c + 1) } else { self.levels[l - 1].nodes }
    }

    fn inv_diag(&self, l: usize) -> &[T] {
        if l == 0 { &self.fine.inv_diag } else { &self.levels[l - 1].inv_diag }
    }

    fn smoother(&self, l: usize) -> Cheb {
        if l == 0 { self.fine.smooth } else { self.levels[l - 1].smooth }
    }

    /// `out = A_l x` (x zero on dropped entries; out comes back zero there).
    fn apply(&self, l: usize, x: &[T], out: &mut [T]) {
        if l == 0 {
            T::apply_fine(&self.fine, x, out);
        } else {
            let lv = &self.levels[l - 1];
            T::apply_stencil(lv.nodes, &lv.stencil, x, out);
        }
    }

    /// Chebyshev smoothing of `A_l x = b` at level `l`, from zero when `zero`.
    #[allow(clippy::too_many_arguments)]
    fn smooth(&self, l: usize, b: &[T], x: &mut [T], zero: bool, d: &mut [T], t: &mut [T]) {
        let s = self.smoother(l);
        let inv = self.inv_diag(l);
        let sigma = s.theta / s.delta;
        let mut rho = 1.0 / sigma;
        let c0 = T::of(1.0 / s.theta);
        if zero {
            zip4(x, d, b, inv, |x, d, b, _, inv| {
                *d = c0 * inv * b;
                *x = *d;
            });
        } else {
            self.apply(l, x, t);
            zip5(x, d, b, t, inv, |x, d, b, t, inv| {
                *d = c0 * inv * (b - t);
                *x += *d;
            });
        }
        for _ in 1..DEGREE {
            self.apply(l, x, t);
            let next = 1.0 / (2.0 * sigma - rho);
            let (c1, c2) = (T::of(next * rho), T::of(2.0 * next / s.delta));
            zip5(x, d, b, t, inv, |x, d, b, t, inv| {
                *d = c1 * *d + c2 * inv * (b - t);
                *x += *d;
            });
            rho = next;
        }
    }

    /// The coarsest solve, in `f64`.
    fn direct(&self, b: &[T], x: &mut [T]) {
        let b64: Vec<f64> = b.iter().map(|v| v.f()).collect();
        let mut x64 = vec![0.0; x.len()];
        self.direct.solve(&b64, &mut x64);
        for (x, v) in x.iter_mut().zip(x64) {
            *x = T::of(v);
        }
    }

    /// One V-cycle on clean vectors (zero on dropped entries); `z` comes back clean.
    fn cycle(&self, w: &mut Work<T>, r0: &[T], z0: &mut [T]) {
        let nl = 1 + self.levels.len();
        if nl == 1 {
            self.direct(r0, z0);
            return;
        }
        for l in 0..nl - 1 {
            let (rlo, rhi) = w.r.split_at_mut(l + 1);
            let (rhs, z): (&[T], &mut [T]) = if l == 0 { (r0, &mut *z0) } else { (&rlo[l], &mut w.z[l]) };
            self.smooth(l, rhs, z, true, &mut w.d[l], &mut w.t[l]);
            self.apply(l, z, &mut w.t[l]);
            // The residual `rhs - A z` is restricted as it is read, never stored.
            restrict(self.levels[l].axes, self.nodes(l), rhs, &w.t[l], self.levels[l].nodes, &mut rhi[0]);
        }
        let last = nl - 1;
        {
            let (r, z) = (&w.r[last], &mut w.z[last]);
            self.direct(r, z);
        }
        for l in (0..nl - 1).rev() {
            let (zlo, zhi) = w.z.split_at_mut(l + 1);
            let (rhs, z): (&[T], &mut [T]) = if l == 0 { (r0, &mut *z0) } else { (&w.r[l], &mut zlo[l]) };
            prolong_add(self.levels[l].axes, self.levels[l].nodes, &zhi[0], self.nodes(l), z, self.inv_diag(l));
            self.smooth(l, rhs, z, false, &mut w.d[l], &mut w.t[l]);
        }
    }
}

/// `out = K x` on the fine level in `f64` (the conjugate gradient's own product, exact).
fn apply_f64<T: Real>(fine: &Fine<T>, x: &[f64], out: &mut [f64]) {
    fem::apply_kernel(&fine.grid, &fine.kern, T::young64(fine), x, out, &fine.mask);
}

/// The levels in `f64`; `spectra` estimates the coarse levels' smoothing ranges (a mixed
/// hierarchy estimates them on its `f32` levels instead).
fn build(op: &Operator, young: &[f64], spectra: bool) -> Result<Parts<f64>, String> {
    op.check(young)?;
    let grid = op.grid;
    let kern = Kernel::new(&op.ke);
    let lanes = fem::KernelF32::new(&kern);
    let n = grid.dofs();
    let mut diag = vec![0.0; n];
    fem::diagonal_kernel(&grid, &kern, young, &mut diag);
    let mask: Vec<bool> = op.fixed.par_iter().zip(diag.par_iter()).map(|(&f, &d)| f || !(d > 0.0)).collect();
    let inv_diag: Vec<f64> = diag.par_iter().zip(mask.par_iter()).map(|(&d, &m)| if m { 0.0 } else { 1.0 / d }).collect();
    let smooth = Cheb::new(kern.jacobi_bound());
    let fine = Fine { grid, kern, lanes, young: young.to_vec(), young_exact: Vec::new(), fixed: op.fixed.clone(), mask, inv_diag, smooth };

    let fine_nodes = grid.n.map(|c| c + 1);
    let mut levels = Vec::new();
    let direct = if direct_fits(fine_nodes) {
        Band::new(fine_nodes, &galerkin_elements(&fine, grid.n.map(Axis::keep)))
    } else {
        let axes = grid.n.map(Axis::new);
        let mut level = Level::new(axes, galerkin_elements(&fine, axes));
        loop {
            let cells = level.cells();
            if direct_fits(level.nodes) || cells.iter().all(|&c| c < 2) {
                let band = Band::new(level.nodes, &level.stencil);
                levels.push(level);
                break band;
            }
            let axes = cells.map(Axis::new);
            let next = Level::new(axes, galerkin_stencil(&level, axes));
            levels.push(level);
            level = next;
        }
    };
    if spectra {
        estimate_spectra(&mut levels)?;
    }
    Ok(Parts { fine, levels, direct, work: Mutex::new(None) })
}

/// Spectra of the smoothed coarse levels (all but the coarsest).
fn estimate_spectra<T: Real>(levels: &mut [Level<T>]) -> Result<(), String> {
    let smoothed = levels.len().saturating_sub(1);
    for lv in &mut levels[..smoothed] {
        let (nodes, st) = (lv.nodes, &lv.stencil);
        let hi = estimate(&|x: &[T], y: &mut [T]| T::apply_stencil(nodes, st, x, y), &lv.inv_diag);
        if !(hi.is_finite() && hi > 0.0) {
            return Err("coarse operator has no positive spectrum".into());
        }
        lv.smooth = Cheb::new(MARGIN * hi);
    }
    Ok(())
}

/// Unknowns and half-bandwidth of a level's banded factor.
fn band_shape(nodes: [usize; 3]) -> (usize, usize) {
    let mut m = nodes;
    m.sort_unstable();
    (3 * m[0] * m[1] * m[2], 3 * (m[0] * m[1] + m[0] + 1) + 2)
}

fn direct_fits(nodes: [usize; 3]) -> bool {
    let (n, bw) = band_shape(nodes);
    n <= DIRECT_DOFS && n as f64 * (bw * bw) as f64 / 2.0 <= DIRECT_COST
}

/// Interpolation from a coarse cell's corners (`[.][b]`) to a fine element's corners (`[a][.]`),
/// lexicographic, for the element's place in the cell: per axis 0 lower half, 1 upper, 2 whole.
fn interpolation(place: usize) -> [[f64; 8]; 8] {
    let p = [place % 3, (place / 3) % 3, place / 9];
    let mut w = [[0.0; 8]; 8];
    for a in 0..8 {
        for b in 0..8 {
            w[a][b] = (0..3)
                .map(|ax| {
                    let ai = ((a >> ax) & 1) as f64;
                    let t = match p[ax] {
                        0 => 0.5 * ai,
                        1 => 0.5 + 0.5 * ai,
                        _ => ai,
                    };
                    if (b >> ax) & 1 == 1 { t } else { 1.0 - t }
                })
                .product();
        }
    }
    w
}

/// `Qᵀ K Q` for the interpolation `w` (per corner, the same on every axis of displacement).
fn triple(w: &[[f64; 8]; 8], k: &[[f64; 24]; 24]) -> Box<[[f64; 24]; 24]> {
    let mut t = [[0.0; 24]; 24];
    for i in 0..24 {
        for b in 0..8 {
            for d in 0..3 {
                t[i][3 * b + d] = (0..8).map(|a| k[i][3 * a + d] * w[a][b]).sum();
            }
        }
    }
    let mut g = Box::new([[0.0; 24]; 24]);
    for b in 0..8 {
        for c in 0..3 {
            for j in 0..24 {
                g[3 * b + c][j] = (0..8).map(|a| w[a][b] * t[3 * a + c][j]).sum();
            }
        }
    }
    g
}

/// Rows `3 lc ..3 lc + 3` of `Q'ᵀ K Q'`, where `Q'` is `Q` with the dropped fine rows zeroed.
fn masked_rows(w: &[[f64; 8]; 8], k: &[[f64; 24]; 24], m: &[bool; 24], lc: usize) -> [[f64; 24]; 3] {
    let mut rows = [[0.0; 24]; 3];
    for c in 0..3 {
        let mut v = [0.0; 24];
        for a in 0..8 {
            if !m[3 * a + c] {
                v[3 * a + c] = w[a][lc];
            }
        }
        let mut t = [0.0; 24];
        for i in 0..24 {
            if !m[i] {
                t[i] = (0..24).map(|j| k[i][j] * v[j]).sum();
            }
        }
        for b in 0..8 {
            for d in 0..3 {
                rows[c][3 * b + d] = (0..8).map(|a| w[a][b] * t[3 * a + d]).sum();
            }
        }
    }
    rows
}

/// The Galerkin operator one coarsening (`axes`) below the fine grid, from its elements: node
/// by node, each coarse cell around the node adds its children's `E Qᵀ Kₑ Q` rows.
fn galerkin_elements(fine: &Fine<f64>, axes: [Axis; 3]) -> Vec<f64> {
    let grid = &fine.grid;
    let [nx, ny, _] = grid.n;
    let (sx, sxy) = (nx + 1, (nx + 1) * (ny + 1));
    let interp: Vec<[[f64; 8]; 8]> = (0..27).map(interpolation).collect();
    let local: Vec<Box<[[f64; 24]; 24]>> = interp.iter().map(|w| triple(w, &fine.kern.k)).collect();
    let cn = axes.map(|a| a.coarse + 1);
    let mut st = vec![0.0; NODE * cn[0] * cn[1] * cn[2]];
    st.par_chunks_mut(NODE * cn[0]).enumerate().for_each(|(row, o)| {
        let (cj, ck) = (row % cn[1], row / cn[1]);
        for ci in 0..cn[0] {
            let out = &mut o[NODE * ci..NODE * (ci + 1)];
            let c = [ci, cj, ck];
            for lc in 0..8 {
                let b = [lc & 1, (lc >> 1) & 1, lc >> 2];
                if (0..3).any(|a| c[a] < b[a] || c[a] - b[a] >= axes[a].coarse) {
                    continue;
                }
                let cell = [0, 1, 2].map(|a| c[a] - b[a]);
                let (chx, nchx) = axes[0].children(cell[0]);
                let (chy, nchy) = axes[1].children(cell[1]);
                let (chz, nchz) = axes[2].children(cell[2]);
                for &(fz, pz) in &chz[..nchz] {
                    for &(fy, py) in &chy[..nchy] {
                        for &(fx, px) in &chx[..nchx] {
                            let e = fine.young[grid.element(fx, fy, fz)];
                            if e == 0.0 {
                                continue;
                            }
                            let place = px + 3 * py + 9 * pz;
                            let n0 = fx + sx * fy + sxy * fz;
                            let mut m = [false; 24];
                            let mut any = false;
                            for q in 0..4 {
                                let base = 3 * (n0 + (q & 1) * sx + (q >> 1) * sxy);
                                for r in 0..6 {
                                    m[6 * q + r] = fine.mask[base + r];
                                    any |= m[6 * q + r];
                                }
                            }
                            let rows = if any {
                                masked_rows(&interp[place], &fine.kern.k, &m, lc)
                            } else {
                                let g = &local[place];
                                [g[3 * lc], g[3 * lc + 1], g[3 * lc + 2]]
                            };
                            for lb in 0..8 {
                                let off = ((lb & 1) + 1 - b[0]) + 3 * (((lb >> 1) & 1) + 1 - b[1]) + 9 * ((lb >> 2) + 1 - b[2]);
                                let blk = &mut out[9 * off..9 * off + 9];
                                for cc in 0..3 {
                                    for d in 0..3 {
                                        blk[3 * cc + d] += e * rows[cc][3 * lb + d];
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    });
    st
}

/// The Galerkin operator `Pᵀ A P` one coarsening (`axes`) below a coarse level.
fn galerkin_stencil(level: &Level<f64>, axes: [Axis; 3]) -> Vec<f64> {
    let fnodes = level.nodes;
    let cn = axes.map(|a| a.coarse + 1);
    let mut st = vec![0.0; NODE * cn[0] * cn[1] * cn[2]];
    st.par_chunks_mut(NODE * cn[0]).enumerate().for_each(|(row, o)| {
        let (cj, ck) = (row % cn[1], row / cn[1]);
        let (dy, ndy) = axes[1].down(cj);
        let (dz, ndz) = axes[2].down(ck);
        for ci in 0..cn[0] {
            let out = &mut o[NODE * ci..NODE * (ci + 1)];
            let (dx, ndx) = axes[0].down(ci);
            let c = [ci, cj, ck];
            for &(fz, wz) in &dz[..ndz] {
                for &(fy, wy) in &dy[..ndy] {
                    for &(fx, wx) in &dx[..ndx] {
                        let wf = wx * wy * wz;
                        let s = &level.stencil[NODE * (fx + fnodes[0] * (fy + fnodes[1] * fz))..][..NODE];
                        let f = [fx, fy, fz];
                        for o3 in 0..27 {
                            let blk = &s[9 * o3..9 * o3 + 9];
                            if blk.iter().all(|&v| v == 0.0) {
                                continue;
                            }
                            let off = [o3 % 3, (o3 / 3) % 3, o3 / 9];
                            if (0..3).any(|a| f[a] + off[a] < 1 || f[a] + off[a] > fnodes[a]) {
                                continue;
                            }
                            let g = [0, 1, 2].map(|a| f[a] + off[a] - 1);
                            let (ux, nux) = axes[0].up(g[0]);
                            let (uy, nuy) = axes[1].up(g[1]);
                            let (uz, nuz) = axes[2].up(g[2]);
                            for &(gz, vz) in &uz[..nuz] {
                                for &(gy, vy) in &uy[..nuy] {
                                    for &(gx, vx) in &ux[..nux] {
                                        let to = [gx, gy, gz];
                                        if (0..3).any(|a| to[a] + 1 < c[a] || to[a] > c[a] + 1) {
                                            continue;
                                        }
                                        let oi = (gx + 1 - ci) + 3 * (gy + 1 - cj) + 9 * (gz + 1 - ck);
                                        let wt = wf * vx * vy * vz;
                                        let dst = &mut out[9 * oi..9 * oi + 9];
                                        for i in 0..9 {
                                            dst[i] += wt * blk[i];
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    });
    st
}

/// `out = A x` for a stencil level.
fn stencil_apply<T: Real>(nodes: [usize; 3], st: &[T], x: &[T], out: &mut [T]) {
    let [nx, ny, nz] = nodes;
    rows(out, 3 * nx, |row, o| {
        let (j, k) = (row % ny, row / ny);
        for i in 0..nx {
            let s = &st[NODE * (row * nx + i)..][..NODE];
            let (mut a0, mut a1, mut a2) = (T::ZERO, T::ZERO, T::ZERO);
            for kk in k.saturating_sub(1)..=(k + 1).min(nz - 1) {
                for jj in j.saturating_sub(1)..=(j + 1).min(ny - 1) {
                    let base = nx * (jj + ny * kk);
                    let ob = 3 * (jj + 1 - j) + 9 * (kk + 1 - k);
                    for ii in i.saturating_sub(1)..=(i + 1).min(nx - 1) {
                        let b = &s[9 * (ii + 1 - i + ob)..][..9];
                        let v = &x[3 * (base + ii)..][..3];
                        a0 += b[0] * v[0] + b[1] * v[1] + b[2] * v[2];
                        a1 += b[3] * v[0] + b[4] * v[1] + b[5] * v[2];
                        a2 += b[6] * v[0] + b[7] * v[1] + b[8] * v[2];
                    }
                }
            }
            o[3 * i] = a0;
            o[3 * i + 1] = a1;
            o[3 * i + 2] = a2;
        }
    });
}

/// Lanes of the single-precision stencil layout: per node row, slots of four nodes, each slot
/// `[entry][lane]` (entry as in [`NODE`]), so four neighbouring nodes' entries load as one vector.
const LANES: usize = 4;
const SLOT: usize = NODE * LANES;

fn slots(nx: usize) -> usize {
    nx.div_ceil(LANES)
}

/// A stencil level's entries in the single-precision layout.
fn group_stencil(nodes: [usize; 3], st: &[f64]) -> Vec<f32> {
    let [nx, ny, nz] = nodes;
    let ns = slots(nx);
    let mut out = vec![0.0f32; ny * nz * ns * SLOT];
    out.par_chunks_mut(ns * SLOT).enumerate().for_each(|(row, o)| {
        for i in 0..nx {
            let src = &st[NODE * (row * nx + i)..][..NODE];
            let dst = &mut o[(i / LANES) * SLOT..][..SLOT];
            for e in 0..NODE {
                dst[LANES * e + i % LANES] = src[e] as f32;
            }
        }
    });
    out
}

/// `out = A x` for a stencil level in the single-precision layout: four nodes of a row at a
/// time (NEON), the row's ends one by one.
fn stencil_apply_f32(nodes: [usize; 3], st: &[f32], x: &[f32], out: &mut [f32]) {
    let [nx, ny, nz] = nodes;
    let ns = slots(nx);
    rows(out, 3 * nx, |row, o| {
        let (j, k) = (row % ny, row / ny);
        let srow = &st[row * ns * SLOT..][..ns * SLOT];
        let one = |i: usize, o: &mut [f32]| {
            let s = &srow[(i / LANES) * SLOT + i % LANES..];
            let (mut a0, mut a1, mut a2) = (0.0f32, 0.0f32, 0.0f32);
            for kk in k.saturating_sub(1)..=(k + 1).min(nz - 1) {
                for jj in j.saturating_sub(1)..=(j + 1).min(ny - 1) {
                    let base = nx * (jj + ny * kk);
                    let ob = 3 * (jj + 1 - j) + 9 * (kk + 1 - k);
                    for ii in i.saturating_sub(1)..=(i + 1).min(nx - 1) {
                        let e = 9 * (ii + 1 - i + ob);
                        let b = |m: usize| s[LANES * (e + m)];
                        let v = &x[3 * (base + ii)..][..3];
                        a0 += b(0) * v[0] + b(1) * v[1] + b(2) * v[2];
                        a1 += b(3) * v[0] + b(4) * v[1] + b(5) * v[2];
                        a2 += b(6) * v[0] + b(7) * v[1] + b(8) * v[2];
                    }
                }
            }
            o[3 * i] = a0;
            o[3 * i + 1] = a1;
            o[3 * i + 2] = a2;
        };
        // Slots whose nodes and both x neighbours lie inside the row go four wide.
        let (first, last) = (1, if nx >= 5 { (nx - 5) / LANES } else { 0 });
        let wide = first <= last && slots4(nodes, j, k, srow, x, o, first, last);
        for i in 0..nx {
            if wide && i >= LANES * first && i < LANES * (last + 1) {
                continue;
            }
            one(i, o);
        }
    });
}

/// The slots `first..=last` of one row, four nodes at a time; false when not done here.
#[cfg(target_arch = "aarch64")]
#[allow(clippy::too_many_arguments)]
fn slots4(nodes: [usize; 3], j: usize, k: usize, srow: &[f32], x: &[f32], o: &mut [f32], first: usize, last: usize) -> bool {
    use std::arch::aarch64::*;
    let [nx, ny, nz] = nodes;
    for s in first..=last {
        let i0 = LANES * s;
        let sl = &srow[s * SLOT..][..SLOT];
        // SAFETY: x reads nodes i0 - 1 ..= i0 + 4 of a row (1 <= i0, i0 + 4 <= nx - 1), the
        // slot reads its own SLOT values, the store writes nodes i0 ..= i0 + 3 of this row.
        unsafe {
            let (mut a0, mut a1, mut a2) = (vdupq_n_f32(0.0), vdupq_n_f32(0.0), vdupq_n_f32(0.0));
            for kk in k.saturating_sub(1)..=(k + 1).min(nz - 1) {
                for jj in j.saturating_sub(1)..=(j + 1).min(ny - 1) {
                    let base = nx * (jj + ny * kk);
                    let ob = 3 * (jj + 1 - j) + 9 * (kk + 1 - k);
                    for di in 0..3 {
                        let v = vld3q_f32(x.as_ptr().add(3 * (base + i0 + di - 1)));
                        let p = sl.as_ptr().add(LANES * 9 * (di + ob));
                        a0 = vfmaq_f32(a0, vld1q_f32(p), v.0);
                        a0 = vfmaq_f32(a0, vld1q_f32(p.add(4)), v.1);
                        a0 = vfmaq_f32(a0, vld1q_f32(p.add(8)), v.2);
                        a1 = vfmaq_f32(a1, vld1q_f32(p.add(12)), v.0);
                        a1 = vfmaq_f32(a1, vld1q_f32(p.add(16)), v.1);
                        a1 = vfmaq_f32(a1, vld1q_f32(p.add(20)), v.2);
                        a2 = vfmaq_f32(a2, vld1q_f32(p.add(24)), v.0);
                        a2 = vfmaq_f32(a2, vld1q_f32(p.add(28)), v.1);
                        a2 = vfmaq_f32(a2, vld1q_f32(p.add(32)), v.2);
                    }
                }
            }
            vst3q_f32(o.as_mut_ptr().add(3 * i0), float32x4x3_t(a0, a1, a2));
        }
    }
    true
}

#[cfg(not(target_arch = "aarch64"))]
#[allow(clippy::too_many_arguments)]
fn slots4(_: [usize; 3], _: usize, _: usize, _: &[f32], _: &[f32], _: &mut [f32], _: usize, _: usize) -> bool {
    false
}

/// `coarse = Pᵀ (b - t)`.
fn restrict<T: Real>(axes: [Axis; 3], fnodes: [usize; 3], b: &[T], t: &[T], cnodes: [usize; 3], coarse: &mut [T]) {
    rows(coarse, 3 * cnodes[0], |row, o| {
        let (dy, ndy) = axes[1].down(row % cnodes[1]);
        let (dz, ndz) = axes[2].down(row / cnodes[1]);
        for ci in 0..cnodes[0] {
            let (dx, ndx) = axes[0].down(ci);
            let mut acc = [T::ZERO; 3];
            for &(fz, wz) in &dz[..ndz] {
                for &(fy, wy) in &dy[..ndy] {
                    let base = fnodes[0] * (fy + fnodes[1] * fz);
                    for &(fx, wx) in &dx[..ndx] {
                        let w = T::of(wx * wy * wz);
                        let (v, u) = (&b[3 * (base + fx)..][..3], &t[3 * (base + fx)..][..3]);
                        acc[0] += w * (v[0] - u[0]);
                        acc[1] += w * (v[1] - u[1]);
                        acc[2] += w * (v[2] - u[2]);
                    }
                }
            }
            o[3 * ci..3 * ci + 3].copy_from_slice(&acc);
        }
    });
}

/// `fine += P coarse`, except on dropped entries (zero `inv_diag`).
fn prolong_add<T: Real>(axes: [Axis; 3], cnodes: [usize; 3], coarse: &[T], fnodes: [usize; 3], fine: &mut [T], inv_diag: &[T]) {
    rows(fine, 3 * fnodes[0], |row, o| {
        let (uy, nuy) = axes[1].up(row % fnodes[1]);
        let (uz, nuz) = axes[2].up(row / fnodes[1]);
        let keep = &inv_diag[3 * fnodes[0] * row..3 * fnodes[0] * (row + 1)];
        for fi in 0..fnodes[0] {
            let (ux, nux) = axes[0].up(fi);
            let mut acc = [T::ZERO; 3];
            for &(cz, wz) in &uz[..nuz] {
                for &(cy, wy) in &uy[..nuy] {
                    let base = cnodes[0] * (cy + cnodes[1] * cz);
                    for &(cx, wx) in &ux[..nux] {
                        let w = T::of(wx * wy * wz);
                        let v = &coarse[3 * (base + cx)..][..3];
                        acc[0] += w * v[0];
                        acc[1] += w * v[1];
                        acc[2] += w * v[2];
                    }
                }
            }
            for c in 0..3 {
                if keep[3 * fi + c] != T::ZERO {
                    o[3 * fi + c] += acc[c];
                }
            }
        }
    });
}

/// The top of `D⁻¹A`'s spectrum by power iteration (the `D`-weighted Rayleigh quotient, which
/// approaches it from below).
fn estimate<T: Real>(apply: &(dyn Fn(&[T], &mut [T]) + Sync), inv: &[T]) -> f64 {
    let n = inv.len();
    let mut x: Vec<T> = (0..n).map(|i| if inv[i] > T::ZERO { T::of(noise(i)) } else { T::ZERO }).collect();
    let mut y = vec![T::ZERO; n];
    let mut lam = 0.0;
    for _ in 0..POWER_STEPS {
        apply(&x, &mut y);
        let (xay, xdx) = reduce2(n, |i| (x[i].f() * y[i].f(), if inv[i] > T::ZERO { x[i].f() * x[i].f() / inv[i].f() } else { 0.0 }));
        if !(xdx > 0.0) {
            break;
        }
        lam = xay / xdx;
        let scale = T::of(1.0 / xdx.sqrt());
        x.par_iter_mut().zip(y.par_iter()).zip(inv.par_iter()).for_each(|((x, &y), &i)| *x = i * y * scale);
    }
    lam
}

/// A fixed pseudo-random value in -1..1.
fn noise(i: usize) -> f64 {
    let mut z = (i as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    z ^= z >> 29;
    z = z.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z ^= z >> 32;
    (z >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
}


/// `(Σ f(i).0, Σ f(i).1)` over `0..n`, in fixed chunks.
fn reduce2(n: usize, f: impl Fn(usize) -> (f64, f64) + Sync) -> (f64, f64) {
    let part = |c: usize| (c * CHUNK..(c * CHUNK + CHUNK).min(n)).map(&f).fold((0.0, 0.0), |(a, b), (x, y)| (a + x, b + y));
    let parts: Vec<(f64, f64)> = if n < SERIAL { (0..n.div_ceil(CHUNK)).map(part).collect() } else { (0..n.div_ceil(CHUNK)).into_par_iter().map(part).collect() };
    parts.iter().fold((0.0, 0.0), |(a, b), &(x, y)| (a + x, b + y))
}

/// `a · b`, in fixed chunks.
fn dot(a: &[f64], b: &[f64]) -> f64 {
    let parts: Vec<f64> = a.par_chunks(CHUNK).zip(b.par_chunks(CHUNK)).map(|(x, y)| dot_serial(x, y)).collect();
    parts.iter().sum()
}

/// `(a · c, b · c)` in one pass, in fixed chunks, `c` in any precision.
fn dot2<T: Real>(a: &[f64], b: &[f64], c: &[T]) -> (f64, f64) {
    let parts: Vec<(f64, f64)> = a
        .par_chunks(CHUNK)
        .zip(b.par_chunks(CHUNK))
        .zip(c.par_chunks(CHUNK))
        .map(|((a, b), c)| {
            let (mut s, mut t) = ([0.0; 4], [0.0; 4]);
            for i in 0..a.len() {
                let z = c[i].f();
                s[i & 3] = a[i].mul_add(z, s[i & 3]);
                t[i & 3] = b[i].mul_add(z, t[i & 3]);
            }
            ((s[0] + s[1]) + (s[2] + s[3]), (t[0] + t[1]) + (t[2] + t[3]))
        })
        .collect();
    parts.iter().fold((0.0, 0.0), |(x, y), &(a, b)| (x + a, y + b))
}

/// Four lanes, summed at the end.
fn dot_serial(x: &[f64], y: &[f64]) -> f64 {
    let mut s = [0.0; 4];
    let (xc, yc) = (x.chunks_exact(4), y.chunks_exact(4));
    let tail: f64 = xc.remainder().iter().zip(yc.remainder()).map(|(a, b)| a * b).sum();
    for (p, q) in xc.zip(yc) {
        for l in 0..4 {
            s[l] = p[l].mul_add(q[l], s[l]);
        }
    }
    (s[0] + s[1]) + (s[2] + s[3]) + tail
}

/// `u += α p`, `r -= α q`, `r0 = r` in the cycle's precision; returns `r · r`.
fn step<T: Real>(u: &mut [f64], r: &mut [f64], r0: &mut [T], p: &[f64], q: &[f64], alpha: f64) -> f64 {
    let parts: Vec<f64> = u
        .par_chunks_mut(CHUNK)
        .zip(r.par_chunks_mut(CHUNK))
        .zip(r0.par_chunks_mut(CHUNK))
        .zip(p.par_chunks(CHUNK))
        .zip(q.par_chunks(CHUNK))
        .map(|((((u, r), r0), p), q)| {
            let mut s = [0.0; 4];
            for i in 0..u.len() {
                u[i] = alpha.mul_add(p[i], u[i]);
                r[i] = (-alpha).mul_add(q[i], r[i]);
                r0[i] = T::of(r[i]);
                s[i & 3] = r[i].mul_add(r[i], s[i & 3]);
            }
            (s[0] + s[1]) + (s[2] + s[3])
        })
        .collect();
    parts.iter().sum()
}

/// Vectors shorter than this run on the calling thread: a parallel pass over a small coarse
/// level costs more in waking the workers than in the work.
const SERIAL: usize = 1 << 14;

/// `f(row, values)` over consecutive rows of `len` values, in parallel for long vectors.
fn rows<T: Send>(out: &mut [T], len: usize, f: impl Fn(usize, &mut [T]) + Sync + Send) {
    if out.len() < SERIAL {
        out.chunks_mut(len).enumerate().for_each(|(r, o)| f(r, o));
    } else {
        out.par_chunks_mut(len).enumerate().for_each(|(r, o)| f(r, o));
    }
}

/// Elementwise over `x, d, b, inv` (`d` may be empty).
fn zip4<T: Real>(x: &mut [T], d: &mut [T], b: &[T], inv: &[T], f: impl Fn(&mut T, &mut T, T, T, T) + Sync) {
    if x.len() < SERIAL {
        for i in 0..x.len() {
            let mut dummy = T::ZERO;
            let dd = if d.is_empty() { &mut dummy } else { &mut d[i] };
            f(&mut x[i], dd, b[i], T::ZERO, inv[i]);
        }
        return;
    }
    if d.is_empty() {
        x.par_chunks_mut(CHUNK).zip(b.par_chunks(CHUNK)).zip(inv.par_chunks(CHUNK)).for_each(|((x, b), inv)| {
            let mut dummy = T::ZERO;
            for i in 0..x.len() {
                f(&mut x[i], &mut dummy, b[i], T::ZERO, inv[i]);
            }
        });
        return;
    }
    x.par_chunks_mut(CHUNK).zip(d.par_chunks_mut(CHUNK)).zip(b.par_chunks(CHUNK)).zip(inv.par_chunks(CHUNK)).for_each(|(((x, d), b), inv)| {
        for i in 0..x.len() {
            f(&mut x[i], &mut d[i], b[i], T::ZERO, inv[i]);
        }
    });
}

/// Elementwise over `x, d, b, t, inv`.
fn zip5<T: Real>(x: &mut [T], d: &mut [T], b: &[T], t: &[T], inv: &[T], f: impl Fn(&mut T, &mut T, T, T, T) + Sync) {
    if x.len() < SERIAL {
        for i in 0..x.len() {
            f(&mut x[i], &mut d[i], b[i], t[i], inv[i]);
        }
        return;
    }
    x.par_chunks_mut(CHUNK)
        .zip(d.par_chunks_mut(CHUNK))
        .zip(b.par_chunks(CHUNK))
        .zip(t.par_chunks(CHUNK))
        .zip(inv.par_chunks(CHUNK))
        .for_each(|((((x, d), b), t), inv)| {
            for i in 0..x.len() {
                f(&mut x[i], &mut d[i], b[i], t[i], inv[i]);
            }
        });
}

/// A banded Cholesky factor of a stencil level, nodes renumbered shortest axis first.
struct Band {
    n: usize,
    bw: usize,
    /// Row `i` holds `L[i][i - bw ..= i]`.
    l: Vec<f64>,
    /// Level degree of freedom to band row.
    map: Vec<usize>,
}

impl Band {
    fn new(nodes: [usize; 3], st: &[f64]) -> Self {
        let mut ord = [0, 1, 2];
        ord.sort_by_key(|&a| nodes[a]);
        let m = ord.map(|a| nodes[a]);
        let (n, bw) = band_shape(nodes);
        let w = bw + 1;
        let node_of = |ijk: [usize; 3]| ijk[ord[0]] + m[0] * (ijk[ord[1]] + m[1] * ijk[ord[2]]);
        let mut map = vec![0; n];
        for k in 0..nodes[2] {
            for j in 0..nodes[1] {
                for i in 0..nodes[0] {
                    let v = i + nodes[0] * (j + nodes[1] * k);
                    let p = node_of([i, j, k]);
                    for c in 0..3 {
                        map[3 * v + c] = 3 * p + c;
                    }
                }
            }
        }
        let mut l = vec![0.0; n * w];
        for k in 0..nodes[2] {
            for j in 0..nodes[1] {
                for i in 0..nodes[0] {
                    let v = i + nodes[0] * (j + nodes[1] * k);
                    for o3 in 0..27 {
                        let off = [o3 % 3, (o3 / 3) % 3, o3 / 9];
                        let g = [i + off[0], j + off[1], k + off[2]];
                        if (0..3).any(|a| g[a] < 1 || g[a] > nodes[a]) {
                            continue;
                        }
                        let u = (g[0] - 1) + nodes[0] * ((g[1] - 1) + nodes[1] * (g[2] - 1));
                        for c in 0..3 {
                            for d in 0..3 {
                                let (p, q) = (map[3 * v + c], map[3 * u + d]);
                                if q <= p && p - q <= bw {
                                    l[p * w + bw - (p - q)] = st[NODE * v + 9 * o3 + 3 * c + d];
                                }
                            }
                        }
                    }
                }
            }
        }
        // Factorise; a pivot that vanishes (an empty row, or a part that floats free) is
        // replaced by the row's own diagonal, or one.
        for i in 0..n {
            let i0 = i.saturating_sub(bw);
            for j in i0..=i {
                let j0 = j.saturating_sub(bw).max(i0);
                let li = &l[i * w + bw - (i - j0)..i * w + bw - (i - j)];
                let lj = &l[j * w + bw - (j - j0)..j * w + bw];
                let s = l[i * w + bw - (i - j)] - dot_serial(li, lj);
                if j < i {
                    l[i * w + bw - (i - j)] = s / l[j * w + bw];
                } else {
                    let a = l[i * w + bw];
                    let s = if s > 1e-12 * a { s } else if a > 0.0 { a } else { 1.0 };
                    l[i * w + bw] = s.sqrt();
                }
            }
        }
        Self { n, bw, l, map }
    }

    fn solve(&self, b: &[f64], x: &mut [f64]) {
        let (n, bw, w) = (self.n, self.bw, self.bw + 1);
        let mut y = vec![0.0; n];
        for (d, &p) in self.map.iter().enumerate() {
            y[p] = b[d];
        }
        for i in 0..n {
            let i0 = i.saturating_sub(bw);
            let row = &self.l[i * w + bw - (i - i0)..i * w + bw];
            y[i] = (y[i] - dot_serial(row, &y[i0..i])) / self.l[i * w + bw];
        }
        for i in (0..n).rev() {
            y[i] /= self.l[i * w + bw];
            let i0 = i.saturating_sub(bw);
            let yi = y[i];
            let row = &self.l[i * w + bw - (i - i0)..i * w + bw];
            for (yk, &lk) in y[i0..i].iter_mut().zip(row) {
                *yk -= lk * yi;
            }
        }
        for (d, &p) in self.map.iter().enumerate() {
            x[d] = y[p];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn norm(v: &[f64]) -> f64 {
        dot(v, v).sqrt()
    }

    /// A cantilever: `n` cells of `h` mm, the x = 0 face clamped, `load` N spread over the far
    /// face with the bilinear weights (a uniform traction).
    fn cantilever(n: [usize; 3], h: f64, load: [f64; 3]) -> (Operator, Vec<f64>) {
        let g = Grid::new([0.0; 3], [n[0] as f64 * h, n[1] as f64 * h, n[2] as f64 * h], h);
        assert_eq!(g.n, n);
        let mut fixed = vec![false; g.dofs()];
        let mut f = vec![0.0; g.dofs()];
        let total = (n[1] * n[2]) as f64;
        for v in 0..g.nodes() {
            let [i, j, k] = g.node_ijk(v);
            if i == 0 {
                fixed[3 * v..3 * v + 3].fill(true);
            }
            if i == n[0] {
                let wy = if j == 0 || j == n[1] { 0.5 } else { 1.0 };
                let wz = if k == 0 || k == n[2] { 0.5 } else { 1.0 };
                for a in 0..3 {
                    f[3 * v + a] = load[a] * wy * wz / total;
                }
            }
        }
        (Operator::new(g, 0.3, fixed), f)
    }

    fn true_residual(op: &Operator, young: &[f64], f: &[f64], u: &[f64]) -> f64 {
        let mut ku = vec![0.0; u.len()];
        op.apply(young, u, &mut ku);
        let r: Vec<f64> = (0..u.len()).map(|d| if op.fixed[d] { 0.0 } else { f[d] - ku[d] }).collect();
        let fl: Vec<f64> = (0..u.len()).map(|d| if op.fixed[d] { 0.0 } else { f[d] }).collect();
        norm(&r) / norm(&fl)
    }

    #[test]
    fn transfer_and_galerkin_agree() {
        // Odd and even sizes, a few fixed and a few empty degrees of freedom: the stencil of the
        // first coarse level is Pᵀ A P, and the next level's is that again.
        let g = Grid::new([0.0; 3], [7.0, 4.0, 5.0], 1.0);
        let mut fixed = vec![false; g.dofs()];
        for v in 0..g.nodes() {
            if g.node_ijk(v)[0] == 0 {
                fixed[3 * v] = true;
                fixed[3 * v + 2] = true;
            }
        }
        let op = Operator::new(g, 0.3, fixed);
        let mut young: Vec<f64> = (0..g.elements()).map(|e| 1.0 + noise(e + 7).abs() * 100.0).collect();
        young[g.element(6, 3, 4)] = 0.0;
        let h = build(&op, &young, true).unwrap();
        let fine = &h.fine;
        let axes = g.n.map(Axis::new);
        let lv = Level::new(axes, galerkin_elements(fine, axes));
        let fnodes = g.n.map(|c| c + 1);
        let xc: Vec<f64> = (0..lv.inv_diag.len()).map(|i| if lv.inv_diag[i] > 0.0 { noise(i) } else { 0.0 }).collect();
        let mut xf = vec![0.0; g.dofs()];
        prolong_add(axes, lv.nodes, &xc, fnodes, &mut xf, &fine.inv_diag);
        let mut af = vec![0.0; g.dofs()];
        fem::apply_kernel(&g, &fine.kern, &young, &xf, &mut af, &fine.mask);
        let mut want = vec![0.0; xc.len()];
        restrict(axes, fnodes, &af, &vec![0.0; af.len()], lv.nodes, &mut want);
        let mut got = vec![0.0; xc.len()];
        stencil_apply(lv.nodes, &lv.stencil, &xc, &mut got);
        let err = want.iter().zip(&got).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        assert!(err < 1e-10 * norm(&want), "{err}");
        // Second level from the stencil.
        let axes2 = lv.cells().map(Axis::new);
        let lv2 = Level::new(axes2, galerkin_stencil(&lv, axes2));
        let x2: Vec<f64> = (0..lv2.inv_diag.len()).map(|i| noise(i + 99)).collect();
        let mut x1 = vec![0.0; xc.len()];
        prolong_add(axes2, lv2.nodes, &x2, lv.nodes, &mut x1, &lv.inv_diag);
        let mut a1 = vec![0.0; xc.len()];
        stencil_apply(lv.nodes, &lv.stencil, &x1, &mut a1);
        let mut want2 = vec![0.0; x2.len()];
        restrict(axes2, lv.nodes, &a1, &vec![0.0; a1.len()], lv2.nodes, &mut want2);
        let x2c: Vec<f64> = (0..x2.len()).map(|i| if lv2.inv_diag[i] > 0.0 { x2[i] } else { 0.0 }).collect();
        let mut got2 = vec![0.0; x2.len()];
        stencil_apply(lv2.nodes, &lv2.stencil, &x2c, &mut got2);
        let err2 = want2.iter().zip(&got2).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        assert!(err2 < 1e-10 * norm(&want2), "{err2}");
    }

    #[test]
    fn vcycle_is_symmetric_and_positive() {
        // Large enough that the fine level is not factorised directly and one coarse level is
        // smoothed too (48 x 20 x 16, then 24 x 10 x 8, then 12 x 5 x 4 solved exactly).
        let (op, _) = cantilever([48, 20, 16], 1.0, [0.0, 0.0, -1.0]);
        let young: Vec<f64> = (0..op.grid.elements()).map(|e| if noise(e) > 0.0 { 1.0 } else { 1e-9 }).collect();
        let h = Hierarchy::exact(&op, &young);
        assert!(h.levels() >= 3, "{}", h.levels());
        let n = op.grid.dofs();
        let x: Vec<f64> = (0..n).map(|i| if op.fixed[i] { 0.0 } else { noise(i + 5) }).collect();
        let y: Vec<f64> = (0..n).map(|i| if op.fixed[i] { 0.0 } else { noise(i + 77) }).collect();
        let (mut mx, mut my) = (vec![0.0; n], vec![0.0; n]);
        h.vcycle(&x, &mut mx);
        h.vcycle(&y, &mut my);
        let (a, b) = (dot(&y, &mx), dot(&x, &my));
        assert!((a - b).abs() < 1e-9 * a.abs().max(b.abs()), "{a} vs {b}");
        assert!(dot(&x, &mx) > 0.0);
    }

    #[test]
    fn direct_solve_on_a_small_grid() {
        let (op, f) = cantilever([6, 3, 3], 1.0, [0.0, 0.0, -10.0]);
        let young = vec![1000.0; op.grid.elements()];
        let h = Hierarchy::new(&op, &young);
        assert_eq!(h.levels(), 1);
        let mut u = vec![0.0; f.len()];
        let s = h.solve(&f, &mut u, 1e-12, 10).unwrap();
        assert!(s.iterations <= 2 && s.residual < 1e-12, "{s:?}");
        assert!(true_residual(&op, &young, &f, &u) < 1e-11);
    }

    #[test]
    fn uniaxial_bar_is_exact() {
        // 40 × 6 × 6 mm bar, voxel 1, steel, 1 kN along x; held on x = 0 only as far as needed
        // for a free lateral contraction.
        let (l, b, e, nu, force) = (40.0, 6.0, 200_000.0, 0.3, 1000.0);
        let g = Grid::new([0.0; 3], [l, b, b], 1.0);
        let mut fixed = vec![false; g.dofs()];
        let mut f = vec![0.0; g.dofs()];
        let n = g.n;
        for v in 0..g.nodes() {
            let [i, j, k] = g.node_ijk(v);
            if i == 0 {
                fixed[3 * v] = true;
                if j == 0 && k == 0 {
                    fixed[3 * v + 1] = true;
                    fixed[3 * v + 2] = true;
                }
                if j == n[1] && k == 0 {
                    fixed[3 * v + 2] = true;
                }
            }
            if i == n[0] {
                let wy = if j == 0 || j == n[1] { 0.5 } else { 1.0 };
                let wz = if k == 0 || k == n[2] { 0.5 } else { 1.0 };
                f[3 * v] = force * wy * wz / (n[1] * n[2]) as f64;
            }
        }
        let op = Operator::new(g, nu, fixed);
        let young = vec![e; g.elements()];
        let mut u = vec![0.0; g.dofs()];
        let s = op.solve(&young, &f, &mut u, 1e-10, 200).unwrap();
        let area = b * b;
        let tip = (0..g.nodes()).filter(|&v| g.node_ijk(v)[0] == n[0]).map(|v| u[3 * v]).fold(0.0, f64::max);
        let want = force * l / (e * area);
        let mut vm = vec![0.0; g.elements()];
        op.von_mises(e, &u, &mut vm);
        let (lo, hi) = vm.iter().fold((f64::MAX, 0.0f64), |(a, b), &s| (a.min(s), b.max(s)));
        eprintln!("bar: {} iterations, residual {:.1e}; tip {tip:.6e} mm vs FL/EA {want:.6e}; stress {lo:.6}..{hi:.6} MPa vs F/A {}", s.iterations, s.residual, force / area);
        assert!((tip - want).abs() < 1e-6 * want);
        assert!((lo - force / area).abs() < 1e-6 * force / area && (hi - force / area).abs() < 1e-6 * force / area);
    }

    /// Timoshenko: δ = PL³/3EI + PL/κGA, κ = 10(1+ν)/(12+11ν) for a rectangle.
    fn timoshenko(p: f64, l: f64, b: f64, d: f64, e: f64, nu: f64) -> f64 {
        let i = b * d.powi(3) / 12.0;
        let kappa = 10.0 * (1.0 + nu) / (12.0 + 11.0 * nu);
        p * l.powi(3) / (3.0 * e * i) + p * l / (kappa * e / (2.0 * (1.0 + nu)) * b * d)
    }

    fn tip_deflection(op: &Operator, u: &[f64]) -> f64 {
        let g = &op.grid;
        let tip: Vec<usize> = (0..g.nodes()).filter(|&v| g.node_ijk(v)[0] == g.n[0]).collect();
        tip.iter().map(|&v| u[3 * v + 2]).sum::<f64>() / tip.len() as f64
    }

    #[test]
    fn cantilever_against_beam_theory() {
        let want = timoshenko(100.0, 80.0, 10.0, 10.0, 200_000.0, 0.3);
        let mut got = Vec::new();
        for h in [1.0, 0.5] {
            let n = [(80.0 / h) as usize, (10.0 / h) as usize, (10.0 / h) as usize];
            let (op, f) = cantilever(n, h, [0.0, 0.0, -100.0]);
            let young = vec![200_000.0; op.grid.elements()];
            let mut u = vec![0.0; f.len()];
            let t = Instant::now();
            let hier = Hierarchy::new(&op, &young);
            let setup = t.elapsed().as_secs_f64();
            let s = hier.solve(&f, &mut u, 1e-10, 500).unwrap();
            let tip = -tip_deflection(&op, &u);
            eprintln!(
                "cantilever h {h}: {} levels, {} iterations, residual {:.1e} (true {:.1e}), setup {setup:.3} s, total {:.3} s; tip {tip:.5} mm vs Timoshenko {want:.5} ({:+.2} %)",
                hier.levels(),
                s.iterations,
                s.residual,
                true_residual(&op, &young, &f, &u),
                t.elapsed().as_secs_f64(),
                100.0 * (tip / want - 1.0)
            );
            got.push(tip);
        }
        // Full-integration hexahedra converge from below (O(h²)): extrapolate.
        let richardson = (4.0 * got[1] - got[0]) / 3.0;
        eprintln!("cantilever: Richardson {richardson:.5} mm ({:+.2} % vs Timoshenko)", 100.0 * (richardson / want - 1.0));
        assert!((got[0] / want - 1.0).abs() < 0.05);
        assert!((got[1] / want - 1.0).abs() < 0.03);
    }

    fn iterations_for(n: [usize; 3], contrast: bool) -> (SolveStats, f64, f64, usize) {
        let (op, f) = cantilever(n, 1.0, [0.0, 0.0, -100.0]);
        let young: Vec<f64> = if contrast {
            // Random solid and void, but the clamped and loaded faces solid so the load path
            // exists.
            (0..op.grid.elements())
                .map(|e| {
                    let i = op.grid.element_ijk(e)[0];
                    if i < 2 || i + 2 >= n[0] || noise(e + 3) > -0.2 { 200_000.0 } else { 200_000.0 * 1e-9 }
                })
                .collect()
        } else {
            vec![200_000.0; op.grid.elements()]
        };
        let mut u = vec![0.0; f.len()];
        let t = Instant::now();
        let h = Hierarchy::new(&op, &young);
        let setup = t.elapsed().as_secs_f64();
        let s = h.solve(&f, &mut u, 1e-8, 1000).unwrap();
        (s, setup, t.elapsed().as_secs_f64() - setup, h.levels())
    }

    #[test]
    fn iterations_hold_as_the_grid_doubles() {
        let mut its = Vec::new();
        // Every grid must go through the V-cycle: a grid small enough to factorise outright
        // (16 x 8 x 8 is) solves in one iteration and says nothing about the multigrid.
        for n in [[24, 12, 12], [48, 24, 24], [96, 48, 48]] {
            let (s, setup, solve, levels) = iterations_for(n, false);
            eprintln!("{n:?}: {levels} levels, {} iterations to {:.1e}, setup {setup:.3} s, solve {solve:.3} s", s.iterations, s.residual);
            assert!(levels >= 2, "{n:?} was solved directly");
            assert!(s.residual <= 1e-8);
            its.push(s.iterations);
        }
        assert!(its[2] <= 2 * its[0] + 5, "{its:?}");
    }

    #[test]
    fn simp_contrast_converges() {
        for n in [[32, 16, 16], [64, 32, 32]] {
            let (s, setup, solve, levels) = iterations_for(n, true);
            eprintln!("SIMP 0/1 (1e-9) {n:?}: {levels} levels, {} iterations to {:.1e}, setup {setup:.3} s, solve {solve:.3} s", s.iterations, s.residual);
            assert!(s.residual <= 1e-8, "{s:?}");
        }
    }

    #[test]
    fn bad_input_is_an_error() {
        let (op, f) = cantilever([4, 2, 2], 1.0, [0.0, 0.0, -1.0]);
        let young = vec![1.0; op.grid.elements()];
        let mut u = vec![0.0; f.len()];
        assert!(op.solve(&young[1..], &f, &mut u, 1e-8, 10).is_err());
        let mut bad = young.clone();
        bad[0] = f64::NAN;
        assert!(op.solve(&bad, &f, &mut u, 1e-8, 10).is_err());
        bad[0] = -1.0;
        assert!(op.solve(&bad, &f, &mut u, 1e-8, 10).is_err());
        assert!(op.solve(&young, &f[1..], &mut u, 1e-8, 10).is_err());
        let mut nf = f.clone();
        nf[5] = f64::INFINITY;
        assert!(op.solve(&young, &nf, &mut u, 1e-8, 10).is_err());
        assert!(op.solve(&young, &f, &mut u, f64::NAN, 10).is_err());
        // All void: every row is empty, the answer is zero.
        let zero = vec![0.0; op.grid.elements()];
        let s = op.solve(&zero, &f, &mut u, 1e-8, 10).unwrap();
        assert!(u.iter().all(|&x| x == 0.0), "{s:?}");
        // Nothing held: singular, but no panic and a finite answer.
        let free = Operator::new(op.grid, 0.3, vec![false; f.len()]);
        let mut u = vec![0.0; f.len()];
        let _ = free.solve(&young, &f, &mut u, 1e-8, 20);
        let mut z = vec![0.0; f.len()];
        Hierarchy::new(&op, &young[1..]).vcycle(&f, &mut z);
        assert!(z[0].is_nan());
    }

    /// Release benchmark: `cargo test --release -p viaform-generative solid::mg -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn benchmark() {
        eprintln!("threads: {}", rayon::current_num_threads());
        for n in [[64, 32, 32], [128, 64, 64]] {
            let (op, f) = cantilever(n, 1.0, [0.0, 0.0, -100.0]);
            let young = vec![200_000.0; op.grid.elements()];
            let u = vec![0.0; f.len()];
            let mut out = vec![0.0; f.len()];
            let t = Instant::now();
            for _ in 0..20 {
                op.apply(&young, &u, &mut out);
            }
            let apply = t.elapsed().as_secs_f64() / 20.0;
            for contrast in [false, true] {
                let (s, setup, solve, levels) = iterations_for(n, contrast);
                eprintln!(
                    "{n:?} {} elements {} dofs{}: apply {:.2} ms; {levels} levels, setup {setup:.3} s, {} iterations to {:.1e} in {solve:.3} s ({:.1} ms each)",
                    op.grid.elements(),
                    op.grid.dofs(),
                    if contrast { " SIMP 0/1" } else { "" },
                    apply * 1e3,
                    s.iterations,
                    s.residual,
                    solve * 1e3 / s.iterations.max(1) as f64
                );
            }
        }
    }
}
