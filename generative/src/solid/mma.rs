//! The method of moving asymptotes (Svanberg 1987, with the 2002 globally convergent
//! subproblem form solved by a primal-dual interior point method): the optimiser for studies
//! with several constraints (volume, stress, displacement, frequency).
//!
//! Each outer iteration replaces the objective and the constraints by convex separable
//! approximations about the current point, `p/(U - x) + q/(x - L)`, whose asymptotes `L` and `U`
//! open up while a variable keeps moving one way and close in when it oscillates (`asyinit` 0.5,
//! `asyincr` 1.2, `asydecr` 0.7, `raa0` 1e-5, `albefa` 0.1). The subproblem is Svanberg's
//! `mmasub` form with artificial variables (`a0` = 1, `a` = 0, `c` = 1000, `d` = 1 per
//! constraint), solved as his `subsolv` does: Newton steps on the perturbed KKT conditions with a
//! residual-halving line search, the perturbation cut tenfold per round down to 1e-7.
//!
//! Work per variable runs in parallel in fixed chunks above a few thousand variables, and the
//! chunks' sums are added in order, so a run gives the same bits on any number of cores. The
//! gradients are read in place, never copied: memory beyond the caller's is about 13 numbers per
//! variable. Scale the objective to order one (its multiplier is capped near `c`).

use std::ops::Range;

use rayon::prelude::*;

const ASYINIT: f64 = 0.5;
const ASYINCR: f64 = 1.2;
const ASYDECR: f64 = 0.7;
const RAA0: f64 = 1e-5;
const ALBEFA: f64 = 0.1;
/// Floor on `xmax - xmin` in the regularisation term.
const XMAMI_MIN: f64 = 1e-5;
/// The interior point method's last perturbation.
const EPSIMIN: f64 = 1e-7;
/// Artificial variables: `min f0 + a0 z + Σ (c yᵢ + d yᵢ²/2)` with `gᵢ - aᵢ z - yᵢ ≤ 0`.
const A0: f64 = 1.0;
const A: f64 = 0.0;
const C: f64 = 1000.0;
const D: f64 = 1.0;
/// Variables per parallel chunk, and the count below which everything runs on one thread.
const CHUNK: usize = 4096;
const PAR_MIN: usize = 4 * CHUNK;

/// One MMA run over `n` variables bounded by `[xmin, xmax]` with `m` constraints `g_i(x) ≤ 0`.
pub struct Mma {
    pub n: usize,
    pub m: usize,
    /// Outer iterations done.
    iter: usize,
    /// Per variable: x(k-1), x(k-2) and the asymptotes.
    track: Vec<Track>,
    /// The last subproblem's constraint multipliers.
    lam: Vec<f64>,
}

#[derive(Clone, Copy, Default)]
struct Track {
    old1: f64,
    old2: f64,
    low: f64,
    upp: f64,
}

/// The subproblem's per-variable unknowns: the point, the multipliers of its bounds
/// (`alfa ≤ x ≤ beta`) and the Newton step.
#[derive(Clone, Copy, Default)]
struct Var {
    x: f64,
    xsi: f64,
    eta: f64,
    dx: f64,
}

impl Mma {
    pub fn new(n: usize, m: usize) -> Self {
        Self { n, m, iter: 0, track: Vec::new(), lam: vec![0.0; m] }
    }

    /// Outer iterations done.
    pub fn iterations(&self) -> usize {
        self.iter
    }

    /// The last subproblem's constraint multipliers: at convergence, the KKT multipliers of the
    /// constraints (`∇f0 + Σ λᵢ ∇gᵢ = 0` on the free variables).
    pub fn multipliers(&self) -> &[f64] {
        &self.lam
    }

    /// One outer iteration: moves `x` given the objective `f0`, its gradient, the constraint
    /// values `g` and their gradients `dg[i]`. `move_limit` bounds the step per variable.
    ///
    /// `move_limit` is a share of each variable's range `xmax - xmin`. Unusable input (lengths,
    /// bounds, numbers that are not finite) leaves `x` as it was: [`Mma::try_update`] says why.
    pub fn update(&mut self, x: &mut [f64], xmin: &[f64], xmax: &[f64], df0: &[f64], g: &[f64], dg: &[Vec<f64>], move_limit: f64) {
        let _ = self.try_update(x, xmin, xmax, df0, g, dg, move_limit);
    }

    /// As [`Mma::update`], with the reason when nothing moved: input of the wrong length, bounds
    /// crossed, numbers that are not finite, or a subproblem that broke down.
    #[allow(clippy::too_many_arguments)]
    pub fn try_update(&mut self, x: &mut [f64], xmin: &[f64], xmax: &[f64], df0: &[f64], g: &[f64], dg: &[Vec<f64>], move_limit: f64) -> Result<(), String> {
        let (n, m) = (self.n, self.m);
        if x.len() != n || xmin.len() != n || xmax.len() != n || df0.len() != n {
            return Err(format!("MMA over {n} variables was given vectors of {}, {}, {} and {}", x.len(), xmin.len(), xmax.len(), df0.len()));
        }
        if g.len() != m || dg.len() != m || dg.iter().any(|d| d.len() != n) {
            return Err(format!("MMA with {m} constraints was given {} values and {} gradients (of {n} each)", g.len(), dg.len()));
        }
        if !(move_limit.is_finite() && move_limit >= 0.0) {
            return Err(format!("MMA's move limit must be finite and not negative, not {move_limit}"));
        }
        if !g.iter().all(|v| v.is_finite()) {
            return Err("a constraint value is not finite".into());
        }
        let bad = fold(n, |mut r| {
            r.find(|&j| {
                !(xmin[j].is_finite() && xmax[j].is_finite() && xmin[j] <= xmax[j] && x[j].is_finite() && df0[j].is_finite() && dg.iter().all(|d| d[j].is_finite()))
            })
        });
        if let Some(j) = bad.into_iter().flatten().next() {
            return Err(format!("variable {j}: its bounds are crossed or a value or gradient is not finite"));
        }
        if self.lam.len() != m {
            self.lam = vec![0.0; m];
        }
        if n == 0 {
            self.iter += 1;
            return Ok(());
        }

        // The outer point, inside its bounds.
        let xk: Vec<f64> = par_map(n, |j| x[j].max(xmin[j]).min(xmax[j]));
        if self.track.len() != n {
            self.track = xk.iter().map(|&v| Track { old1: v, old2: v, low: v, upp: v }).collect();
            self.iter = 0;
        }
        self.iter += 1;
        let early = self.iter <= 2;

        // Asymptotes, then the subproblem's bounds alfa ≤ x ≤ beta (equal when a variable cannot
        // move: no range or no move limit).
        let mut bounds = vec![[0.0; 2]; n];
        let each = |off: usize, track: &mut [Track], bounds: &mut [[f64; 2]]| {
            for (k, (t, b)) in track.iter_mut().zip(bounds.iter_mut()).enumerate() {
                let j = off + k;
                let (x, range) = (xk[j], xmax[j] - xmin[j]);
                if early {
                    t.low = x - ASYINIT * range;
                    t.upp = x + ASYINIT * range;
                } else {
                    let trend = (x - t.old1) * (t.old1 - t.old2);
                    let factor = if trend > 0.0 {
                        ASYINCR
                    } else if trend < 0.0 {
                        ASYDECR
                    } else {
                        1.0
                    };
                    t.low = (x - factor * (t.old1 - t.low)).max(x - 10.0 * range).min(x - 0.01 * range);
                    t.upp = (x + factor * (t.upp - t.old1)).min(x + 10.0 * range).max(x + 0.01 * range);
                }
                let alfa = (t.low + ALBEFA * (x - t.low)).max(x - move_limit * range).max(xmin[j]);
                let beta = (t.upp - ALBEFA * (t.upp - x)).min(x + move_limit * range).min(xmax[j]);
                *b = if beta - alfa > 1e-12 * (1.0 + alfa.abs() + beta.abs()) { [alfa, beta] } else { [x, x] };
            }
        };
        if n < PAR_MIN {
            each(0, &mut self.track, &mut bounds);
        } else {
            self.track.par_chunks_mut(CHUNK).zip(bounds.par_chunks_mut(CHUNK)).enumerate().for_each(|(c, (t, b))| each(c * CHUNK, t, b));
        }

        // Every term's p and q, once per outer iteration: the subproblem's passes read them.
        let w = 2 * (m + 1);
        let mut pq = vec![0.0; n * w];
        {
            let track = &self.track;
            let each = |off: usize, out: &mut [f64]| {
                for (k, c) in out.chunks_exact_mut(w).enumerate() {
                    let j = off + k;
                    let t = &track[j];
                    let (uk, lk) = (t.upp - xk[j], xk[j] - t.low);
                    let sc = (uk * uk, lk * lk, RAA0 / (xmax[j] - xmin[j]).max(XMAMI_MIN));
                    (c[0], c[1]) = coef(df0[j], sc);
                    for (i, g) in dg.iter().enumerate() {
                        (c[2 + 2 * i], c[3 + 2 * i]) = coef(g[j], sc);
                    }
                }
            };
            if n < PAR_MIN {
                each(0, &mut pq);
            } else {
                pq.par_chunks_mut(w * CHUNK).enumerate().for_each(|(c, out)| each(c * CHUNK, out));
            }
        }
        let mut sub = Sub { m, xk: &xk, track: &self.track, bounds: &bounds, pq, w, b: Vec::new() };
        sub.b = sub.rhs(g);
        let (xnew, lam) = sub.solve()?;

        self.lam = lam;
        let finish = |off: usize, track: &mut [Track], x: &mut [f64]| {
            for (k, (t, x)) in track.iter_mut().zip(x.iter_mut()).enumerate() {
                let j = off + k;
                t.old2 = t.old1;
                t.old1 = xk[j];
                *x = xnew[j];
            }
        };
        if n < PAR_MIN {
            finish(0, &mut self.track, x);
        } else {
            self.track.par_chunks_mut(CHUNK).zip(x.par_chunks_mut(CHUNK)).enumerate().for_each(|(c, (t, x))| finish(c * CHUNK, t, x));
        }
        Ok(())
    }
}

/// One MMA subproblem: the approximations about the outer point `xk` and the bounds.
struct Sub<'a> {
    m: usize,
    xk: &'a [f64],
    track: &'a [Track],
    bounds: &'a [[f64; 2]],
    /// Per variable, `w = 2 (m + 1)` numbers: the objective's `p` and `q`, then each
    /// constraint's.
    pq: Vec<f64>,
    w: usize,
    /// The constraints' constant terms.
    b: Vec<f64>,
}

/// The subproblem's per-constraint unknowns and the artificial `z` with its multiplier.
#[derive(Clone)]
struct Dual {
    y: Vec<f64>,
    z: f64,
    lam: Vec<f64>,
    mu: Vec<f64>,
    zet: f64,
    s: Vec<f64>,
}

impl Dual {
    fn step(&self, d: &Dual, t: f64) -> Dual {
        let add = |a: &[f64], b: &[f64]| -> Vec<f64> { a.iter().zip(b).map(|(a, b)| a + t * b).collect() };
        Dual { y: add(&self.y, &d.y), z: self.z + t * d.z, lam: add(&self.lam, &d.lam), mu: add(&self.mu, &d.mu), zet: self.zet + t * d.zet, s: add(&self.s, &d.s) }
    }
}

/// `p` and `q` of one term from its gradient `grad`, given `(uk², lk², raa0 / range)`.
#[inline]
fn coef(grad: f64, (uk2, lk2, r): (f64, f64, f64)) -> (f64, f64) {
    let pq = 0.001 * grad.abs() + r;
    ((grad.max(0.0) + pq) * uk2, ((-grad).max(0.0) + pq) * lk2)
}

impl Sub<'_> {
    #[inline]
    fn active(&self, j: usize) -> bool {
        let [a, b] = self.bounds[j];
        b > a
    }

    /// The Lagrangian's `p` and `q` at multipliers `lam` for variable `j`, calling `each(i, pᵢ, qᵢ)`
    /// with every constraint's terms on the way.
    #[inline]
    fn local(&self, j: usize, lam: &[f64], mut each: impl FnMut(usize, f64, f64)) -> (f64, f64) {
        let c = &self.pq[self.w * j..self.w * (j + 1)];
        let (mut plam, mut qlam) = (c[0], c[1]);
        for (i, l) in lam.iter().enumerate() {
            let (p, q) = (c[2 + 2 * i], c[3 + 2 * i]);
            plam += p * l;
            qlam += q * l;
            each(i, p, q);
        }
        (plam, qlam)
    }

    /// `bᵢ`: the approximations at the outer point equal the constraint values there.
    fn rhs(&self, g: &[f64]) -> Vec<f64> {
        let m = self.m;
        let ones = vec![0.0; m];
        let parts = fold(self.xk.len(), |r| {
            let mut b = vec![0.0; m];
            for j in r.filter(|&j| self.active(j)) {
                let t = &self.track[j];
                let (ui, li) = (1.0 / (t.upp - self.xk[j]), 1.0 / (self.xk[j] - t.low));
                self.local(j, &ones, |i, p, q| b[i] += p * ui + q * li);
            }
            b
        });
        let mut b = sum(parts, m);
        for (b, g) in b.iter_mut().zip(g) {
            *b -= g;
        }
        b
    }

    /// Svanberg's `subsolv`: the subproblem's primal-dual interior point solution. Returns the
    /// new point and the constraint multipliers.
    fn solve(&self) -> Result<(Vec<f64>, Vec<f64>), String> {
        let (n, m) = (self.xk.len(), self.m);
        let mut vars: Vec<Var> = par_map(n, |j| {
            let [alfa, beta] = self.bounds[j];
            let x = 0.5 * (alfa + beta);
            if self.active(j) { Var { x, xsi: (1.0 / (x - alfa)).max(1.0), eta: (1.0 / (beta - x)).max(1.0), dx: 0.0 } } else { Var { x, ..Var::default() } }
        });
        let mut dual = Dual { y: vec![1.0; m], z: 1.0, lam: vec![1.0; m], mu: vec![(0.5 * C).max(1.0); m], zet: 1.0, s: vec![1.0; m] };
        let active = fold(n, |r| r.filter(|&j| self.active(j)).count()).into_iter().sum::<usize>();

        let mut epsi = 1.0;
        // A step taken but not yet applied to the per-variable unknowns (step, perturbation):
        // the next pass over them applies it, so a Newton step reads them once less.
        let mut pending: Option<(f64, f64)> = None;
        while epsi > EPSIMIN {
            if let Some((t, e)) = pending.take() {
                self.advance(&mut vars, t, e);
            }
            let (gvec, local) = self.residual(&vars, 0.0, &dual.lam, epsi);
            let (mut norm2, mut worst) = self.residual_m(&gvec, &dual, epsi, local);
            let mut newton = 0;
            while worst > 0.9 * epsi && newton < 200 {
                newton += 1;
                let (dlam, dz, vreach) = if m < active {
                    self.direction_dual(&mut vars, &dual, epsi, pending.take())?
                } else {
                    if let Some((t, e)) = pending.take() {
                        self.advance(&mut vars, t, e);
                    }
                    self.direction_primal(&mut vars, &dual, epsi)?
                };
                // The rest of the step from dλ and dz, and how far it may go inside the bounds.
                let diagy: Vec<f64> = (0..m).map(|i| D + dual.mu[i] / dual.y[i]).collect();
                let dy: Vec<f64> = (0..m).map(|i| (-(C + D * dual.y[i] - dual.lam[i] - epsi / dual.y[i]) + dlam[i]) / diagy[i]).collect();
                let d = Dual {
                    mu: (0..m).map(|i| -dual.mu[i] + epsi / dual.y[i] - dual.mu[i] * dy[i] / dual.y[i]).collect(),
                    zet: -dual.zet + epsi / dual.z - dual.zet * dz / dual.z,
                    s: (0..m).map(|i| -dual.s[i] + epsi / dual.lam[i] - dual.s[i] * dlam[i] / dual.lam[i]).collect(),
                    y: dy,
                    z: dz,
                    lam: dlam,
                };
                let mut reach = vreach;
                let pairs = [(&d.y, &dual.y), (&d.lam, &dual.lam), (&d.mu, &dual.mu), (&d.s, &dual.s)];
                for (dv, v) in pairs {
                    for (dv, v) in dv.iter().zip(v.iter()) {
                        reach = reach.max(-1.01 * dv / v);
                    }
                }
                reach = reach.max(-1.01 * d.z / dual.z).max(-1.01 * d.zet / dual.zet).max(1.0);
                let mut steg = 1.0 / reach;

                // Halve the step until the residual drops (at most 50 times).
                let mut tries = 0;
                let (trial, new_norm2, new_worst) = loop {
                    tries += 1;
                    let trial = dual.step(&d, steg);
                    let (gvec, local) = self.residual(&vars, steg, &trial.lam, epsi);
                    let (r2, rmax) = self.residual_m(&gvec, &trial, epsi, local);
                    if r2.is_nan() {
                        return Err("the MMA subproblem broke down (numbers that are not finite)".into());
                    }
                    if r2 <= norm2 || tries >= 50 {
                        break (trial, r2, rmax);
                    }
                    steg *= 0.5;
                };
                pending = Some((steg, epsi));
                dual = trial;
                norm2 = new_norm2;
                worst = new_worst;
            }
            epsi *= 0.1;
        }
        if let Some((t, e)) = pending.take() {
            self.advance(&mut vars, t, e);
        }
        let x: Vec<f64> = par_map(n, |j| if self.active(j) { vars[j].x } else { self.xk[j] });
        let finite = fold(n, |mut r| r.all(|j| x[j].is_finite())).into_iter().all(|f| f);
        if !finite || !dual.lam.iter().all(|l| l.is_finite()) {
            return Err("the MMA subproblem broke down (numbers that are not finite)".into());
        }
        Ok((x, dual.lam))
    }

    /// The per-variable residuals at the trial point `x + t dx` (with the bound multipliers
    /// moved to match) and multipliers `lam`: the constraint sums `Σ p/(U-x) + q/(x-L)`, and the
    /// residuals' sum of squares and largest magnitude.
    fn residual(&self, vars: &[Var], t: f64, lam: &[f64], epsi: f64) -> (Vec<f64>, (f64, f64)) {
        let m = self.m;
        let parts = fold(vars.len(), |r| {
            let mut acc = vec![0.0; m + 2];
            let (gvec, tail) = acc.split_at_mut(m);
            let (mut sq, mut worst) = (0.0f64, 0.0f64);
            for j in r.filter(|&j| self.active(j)) {
                let [alfa, beta] = self.bounds[j];
                let (x, xsi, eta) = moved(vars[j], alfa, beta, t, epsi);
                let tr = &self.track[j];
                let (ui, li) = (1.0 / (tr.upp - x), 1.0 / (x - tr.low));
                let (plam, qlam) = self.local(j, lam, |i, p, q| gvec[i] += p * ui + q * li);
                let rex = plam * ui * ui - qlam * li * li - xsi + eta;
                let rexsi = xsi * (x - alfa) - epsi;
                let reeta = eta * (beta - x) - epsi;
                sq += rex * rex + rexsi * rexsi + reeta * reeta;
                worst = worst.max(rex.abs()).max(rexsi.abs()).max(reeta.abs());
            }
            tail[0] = sq;
            tail[1] = worst;
            acc
        });
        let mut gvec = vec![0.0; m];
        let (mut sq, mut worst) = (0.0f64, 0.0f64);
        for p in parts {
            for i in 0..m {
                gvec[i] += p[i];
            }
            sq += p[m];
            worst = worst.max(p[m + 1]);
        }
        (gvec, (sq, worst))
    }

    /// Adds the per-constraint residuals to the per-variable ones `(sum of squares, largest)`.
    fn residual_m(&self, gvec: &[f64], d: &Dual, epsi: f64, (mut sq, mut worst): (f64, f64)) -> (f64, f64) {
        let mut add = |r: f64| {
            sq += r * r;
            worst = worst.max(r.abs());
        };
        let alam: f64 = d.lam.iter().map(|l| A * l).sum();
        add(A0 - d.zet - alam);
        add(d.zet * d.z - epsi);
        for i in 0..self.m {
            add(C + D * d.y[i] - d.mu[i] - d.lam[i]);
            add(gvec[i] - A * d.z - d.y[i] + d.s[i] - self.b[i]);
            add(d.mu[i] * d.y[i] - epsi);
            add(d.lam[i] * d.s[i] - epsi);
        }
        (sq, worst)
    }

    /// The per-constraint parts of the Newton system: `dely`, `delz`, `dellam` (with the
    /// constraint sums `gvec`), `diagy` and `diaglamyi`.
    fn deltas(&self, gvec: &[f64], d: &Dual, epsi: f64) -> (Vec<f64>, f64, Vec<f64>, Vec<f64>, Vec<f64>) {
        let m = self.m;
        let dely: Vec<f64> = (0..m).map(|i| C + D * d.y[i] - d.lam[i] - epsi / d.y[i]).collect();
        let delz = A0 - d.lam.iter().map(|l| A * l).sum::<f64>() - epsi / d.z;
        let dellam: Vec<f64> = (0..m).map(|i| gvec[i] - A * d.z - d.y[i] - self.b[i] + epsi / d.lam[i]).collect();
        let diagy: Vec<f64> = (0..m).map(|i| D + d.mu[i] / d.y[i]).collect();
        let diaglamyi: Vec<f64> = (0..m).map(|i| d.s[i] / d.lam[i] + 1.0 / diagy[i]).collect();
        (dely, delz, dellam, diagy, diaglamyi)
    }

    /// Per variable at the current point: `delx` and `diagx` of the Newton system, with each
    /// constraint's `GG` entry (`p/(U-x)² - q/(x-L)²`) and term of `gvec` passed to `each`.
    #[inline]
    fn newton_local(&self, j: usize, v: Var, lam: &[f64], epsi: f64, mut each: impl FnMut(usize, f64, f64)) -> (f64, f64) {
        let [alfa, beta] = self.bounds[j];
        let tr = &self.track[j];
        let (ui, li) = (1.0 / (tr.upp - v.x), 1.0 / (v.x - tr.low));
        let (ui2, li2) = (ui * ui, li * li);
        let (plam, qlam) = self.local(j, lam, |i, p, q| each(i, p * ui2 - q * li2, p * ui + q * li));
        let (xa, bx) = (v.x - alfa, beta - v.x);
        let delx = plam * ui2 - qlam * li2 - epsi / xa + epsi / bx;
        let diagx = 2.0 * (plam * ui2 * ui + qlam * li2 * li) + v.xsi / xa + v.eta / bx;
        (delx, diagx)
    }

    /// The Newton step when there are fewer constraints than free variables: an (m+1)-square
    /// system in dλ and dz, then dx per variable. Returns (dλ, dz, the variables' reach: see
    /// [`Sub::reach`]) and leaves dx in `vars`.
    /// `pending` is a step to apply to `vars` first (see [`Sub::solve`]).
    fn direction_dual(&self, vars: &mut [Var], dual: &Dual, epsi: f64, pending: Option<(f64, f64)>) -> Result<(Vec<f64>, f64, f64), String> {
        let m = self.m;
        // Per chunk: gvec (m), GG (delx/diagx) (m), GG diag(1/diagx) GGᵀ (lower triangle, m²).
        let parts = fold_mut_map(vars, |off, chunk| {
            let mut acc = vec![0.0; 2 * m + m * m];
            let mut gg = vec![0.0; m];
            for (k, v) in chunk.iter_mut().enumerate() {
                let j = off + k;
                if !self.active(j) {
                    continue;
                }
                if let Some((t, e)) = pending {
                    let [alfa, beta] = self.bounds[j];
                    (v.x, v.xsi, v.eta) = moved(*v, alfa, beta, t, e);
                }
                let (gvec, rest) = acc.split_at_mut(m);
                let (delx, diagx) = self.newton_local(j, *v, &dual.lam, epsi, |i, g, s| {
                    gg[i] = g;
                    gvec[i] += s;
                });
                let (w, rhs) = (1.0 / diagx, delx / diagx);
                let (gx, alam) = rest.split_at_mut(m);
                for i in 0..m {
                    gx[i] += gg[i] * rhs;
                    let gw = gg[i] * w;
                    for k in 0..=i {
                        alam[i * m + k] += gw * gg[k];
                    }
                }
            }
            acc
        });
        let acc = sum(parts, 2 * m + m * m);
        let (gvec, rest) = acc.split_at(m);
        let (gx, alam) = rest.split_at(m);
        let (dely, delz, dellam, diagy, diaglamyi) = self.deltas(gvec, dual, epsi);

        let k = m + 1;
        let mut aa = vec![0.0; k * k];
        let mut bb = vec![0.0; k];
        for i in 0..m {
            for c in 0..=i {
                aa[i * k + c] = alam[i * m + c];
                aa[c * k + i] = alam[i * m + c];
            }
            aa[i * k + i] += diaglamyi[i];
            aa[i * k + m] = A;
            aa[m * k + i] = A;
            bb[i] = dellam[i] + dely[i] / diagy[i] - gx[i];
        }
        aa[m * k + m] = -dual.zet / dual.z;
        bb[m] = delz;
        solve_dense(&mut aa, &mut bb, k).ok_or("the MMA subproblem's Newton system is singular")?;
        let dlam = bb[..m].to_vec();
        let dz = bb[m];

        // dx = -(delx + GGᵀ dλ) / diagx, and how far the step may go, in the same pass.
        let reach = fold_mut_map(vars, |off, chunk| {
            let mut most = 0.0f64;
            for (q, v) in chunk.iter_mut().enumerate() {
                let j = off + q;
                if !self.active(j) {
                    continue;
                }
                let mut gl = 0.0;
                let (delx, diagx) = self.newton_local(j, *v, &dual.lam, epsi, |i, g, _| gl += g * dlam[i]);
                v.dx = -(delx + gl) / diagx;
                most = most.max(var_reach(*v, self.bounds[j], epsi));
            }
            most
        });
        Ok((dlam, dz, reach.into_iter().fold(0.0, f64::max)))
    }

    /// The Newton step when there are at least as many constraints as free variables: an
    /// (n+1)-square system in dx and dz over the free variables. Returns (dλ, dz) and leaves dx
    /// in `vars`.
    fn direction_primal(&self, vars: &mut [Var], dual: &Dual, epsi: f64) -> Result<(Vec<f64>, f64, f64), String> {
        let m = self.m;
        let free: Vec<usize> = (0..vars.len()).filter(|&j| self.active(j)).collect();
        let nf = free.len();
        let mut gg = vec![0.0; m * nf];
        let mut gvec = vec![0.0; m];
        let mut delx = vec![0.0; nf];
        let mut diagx = vec![0.0; nf];
        for (f, &j) in free.iter().enumerate() {
            (delx[f], diagx[f]) = self.newton_local(j, vars[j], &dual.lam, epsi, |i, g, s| {
                gg[i * nf + f] = g;
                gvec[i] += s;
            });
        }
        let (dely, delz, dellam, diagy, diaglamyi) = self.deltas(&gvec, dual, epsi);
        let dellamyi: Vec<f64> = (0..m).map(|i| dellam[i] + dely[i] / diagy[i]).collect();

        let k = nf + 1;
        let mut aa = vec![0.0; k * k];
        let mut bb = vec![0.0; k];
        for f in 0..nf {
            aa[f * k + f] = diagx[f];
            let mut bx = delx[f];
            let mut axz = 0.0;
            for i in 0..m {
                let gi = gg[i * nf + f];
                bx += gi * dellamyi[i] / diaglamyi[i];
                axz -= gi * A / diaglamyi[i];
                for c in 0..nf {
                    aa[f * k + c] += gi * gg[i * nf + c] / diaglamyi[i];
                }
            }
            aa[f * k + nf] = axz;
            aa[nf * k + f] = axz;
            bb[f] = -bx;
        }
        aa[nf * k + nf] = dual.zet / dual.z + (0..m).map(|i| A * A / diaglamyi[i]).sum::<f64>();
        bb[nf] = -(delz - (0..m).map(|i| A * dellamyi[i] / diaglamyi[i]).sum::<f64>());
        solve_dense(&mut aa, &mut bb, k).ok_or("the MMA subproblem's Newton system is singular")?;
        let dz = bb[nf];
        for (f, &j) in free.iter().enumerate() {
            vars[j].dx = bb[f];
        }
        let dlam = (0..m)
            .map(|i| {
                let gdx: f64 = (0..nf).map(|f| gg[i * nf + f] * bb[f]).sum();
                (gdx - dz * A + dellamyi[i]) / diaglamyi[i]
            })
            .collect();
        Ok((dlam, dz, self.reach(vars, epsi)))
    }

    /// How far the step may go, as the largest `-1.01 dv/v` over the per-variable unknowns and
    /// their distances to the bounds (the step is `1 / max(this, 1)`).
    fn reach(&self, vars: &[Var], epsi: f64) -> f64 {
        let parts = fold(vars.len(), |r| {
            let mut most = 0.0f64;
            for j in r.filter(|&j| self.active(j)) {
                most = most.max(var_reach(vars[j], self.bounds[j], epsi));
            }
            most
        });
        parts.into_iter().fold(0.0, f64::max)
    }

    /// Moves the per-variable unknowns by the step `t`.
    fn advance(&self, vars: &mut [Var], t: f64, epsi: f64) {
        fold_mut(vars, |off, chunk| {
            for (q, v) in chunk.iter_mut().enumerate() {
                let j = off + q;
                if self.active(j) {
                    let [alfa, beta] = self.bounds[j];
                    (v.x, v.xsi, v.eta) = moved(*v, alfa, beta, t, epsi);
                }
            }
        });
    }
}

/// One variable's share of [`Sub::reach`].
#[inline]
fn var_reach(v: Var, [alfa, beta]: [f64; 2], epsi: f64) -> f64 {
    let (xa, bx) = (v.x - alfa, beta - v.x);
    let dxsi = -v.xsi + epsi / xa - v.xsi * v.dx / xa;
    let deta = -v.eta + epsi / bx + v.eta * v.dx / bx;
    (-1.01 * v.dx / xa).max(1.01 * v.dx / bx).max(-1.01 * dxsi / v.xsi).max(-1.01 * deta / v.eta)
}

/// The point and bound multipliers of `v` moved by the step `t` along its Newton direction.
#[inline]
fn moved(v: Var, alfa: f64, beta: f64, t: f64, epsi: f64) -> (f64, f64, f64) {
    if t == 0.0 {
        return (v.x, v.xsi, v.eta);
    }
    let (xa, bx) = (v.x - alfa, beta - v.x);
    let dxsi = -v.xsi + epsi / xa - v.xsi * v.dx / xa;
    let deta = -v.eta + epsi / bx + v.eta * v.dx / bx;
    (v.x + t * v.dx, v.xsi + t * dxsi, v.eta + t * deta)
}

/// Runs `f` over `0..n` in chunks (in parallel for large `n`), returning each chunk's result in
/// order.
fn fold<T: Send>(n: usize, f: impl Fn(Range<usize>) -> T + Sync + Send) -> Vec<T> {
    let chunks = n.div_ceil(CHUNK);
    let run = |c: usize| f(c * CHUNK..((c + 1) * CHUNK).min(n));
    if n < PAR_MIN { (0..chunks).map(run).collect() } else { (0..chunks).into_par_iter().map(run).collect() }
}

/// Runs `f(offset, chunk)` over `v` in chunks, in parallel for long slices.
fn fold_mut<T: Send>(v: &mut [T], f: impl Fn(usize, &mut [T]) + Sync + Send) {
    if v.len() < PAR_MIN {
        v.chunks_mut(CHUNK).enumerate().for_each(|(c, s)| f(c * CHUNK, s));
    } else {
        v.par_chunks_mut(CHUNK).enumerate().for_each(|(c, s)| f(c * CHUNK, s));
    }
}

/// [`fold_mut`], each chunk answering a value (in order).
fn fold_mut_map<T: Send, R: Send>(v: &mut [T], f: impl Fn(usize, &mut [T]) -> R + Sync + Send) -> Vec<R> {
    if v.len() < PAR_MIN {
        v.chunks_mut(CHUNK).enumerate().map(|(c, s)| f(c * CHUNK, s)).collect()
    } else {
        v.par_chunks_mut(CHUNK).enumerate().map(|(c, s)| f(c * CHUNK, s)).collect()
    }
}

/// `f(j)` for `j` in `0..n`, in parallel for large `n`.
fn par_map<T: Send>(n: usize, f: impl Fn(usize) -> T + Sync + Send) -> Vec<T> {
    if n < PAR_MIN { (0..n).map(f).collect() } else { (0..n).into_par_iter().with_min_len(CHUNK).map(f).collect() }
}

/// The element-wise sum of the chunks' vectors, in order.
fn sum(parts: Vec<Vec<f64>>, len: usize) -> Vec<f64> {
    let mut total = vec![0.0; len];
    for p in parts {
        for (t, v) in total.iter_mut().zip(p) {
            *t += v;
        }
    }
    total
}

/// Solves the dense `k × k` system `a x = b` (row-major) by Gaussian elimination with partial
/// pivoting, leaving `x` in `b`; `None` when it is singular.
fn solve_dense(a: &mut [f64], b: &mut [f64], k: usize) -> Option<()> {
    for col in 0..k {
        let pivot = (col..k).max_by(|&r, &s| a[r * k + col].abs().total_cmp(&a[s * k + col].abs()))?;
        let p = a[pivot * k + col];
        if !(p.abs() > 0.0) || !p.is_finite() {
            return None;
        }
        if pivot != col {
            for c in 0..k {
                a.swap(pivot * k + c, col * k + c);
            }
            b.swap(pivot, col);
        }
        for r in col + 1..k {
            let f = a[r * k + col] / p;
            if f != 0.0 {
                for c in col..k {
                    a[r * k + c] -= f * a[col * k + c];
                }
                b[r] -= f * b[col];
            }
        }
    }
    for row in (0..k).rev() {
        let mut s = b[row];
        for c in row + 1..k {
            s -= a[row * k + c] * b[c];
        }
        b[row] = s / a[row * k + row];
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Svanberg's toy problem (the `mmasub` documentation): the smallest |x|² in two balls of
    /// radius 3, from (4, 3, 2) in 0 ≤ x ≤ 5.
    #[test]
    fn svanberg_toy() {
        let centres = [[5.0, 2.0, 1.0], [3.0, 4.0, 3.0]];
        let mut x = vec![4.0, 3.0, 2.0];
        let (xmin, xmax) = (vec![0.0; 3], vec![5.0; 3]);
        let mut mma = Mma::new(3, 2);
        let eval = |x: &[f64]| {
            let df0: Vec<f64> = x.iter().map(|v| 2.0 * v).collect();
            let g: Vec<f64> = centres.iter().map(|c| (0..3).map(|a| (x[a] - c[a]).powi(2)).sum::<f64>() - 9.0).collect();
            let dg: Vec<Vec<f64>> = centres.iter().map(|c| (0..3).map(|a| 2.0 * (x[a] - c[a])).collect()).collect();
            (df0, g, dg)
        };
        let mut steps = 0;
        for k in 0..100 {
            let (df0, g, dg) = eval(&x);
            let before = x.clone();
            mma.try_update(&mut x, &xmin, &xmax, &df0, &g, &dg, 0.5).unwrap();
            steps = k + 1;
            if (0..3).map(|a| (x[a] - before[a]).abs()).fold(0.0, f64::max) < 1e-9 {
                break;
            }
        }
        let expect = [2.0175, 1.7800, 1.2375];
        assert!((0..3).all(|a| (x[a] - expect[a]).abs() < 1e-4), "{x:?} after {steps} iterations");
        // KKT: both balls active, ∇f0 + Σ λ ∇g = 0 with λ ≥ 0.
        let (df0, g, dg) = eval(&x);
        assert!(g.iter().all(|g| g.abs() < 1e-6), "{g:?}");
        let lam = mma.multipliers();
        assert!(lam.iter().all(|&l| l > 0.0));
        for a in 0..3 {
            assert!((df0[a] + lam[0] * dg[0][a] + lam[1] * dg[1][a]).abs() < 1e-5, "{lam:?}");
        }
        eprintln!("toy: {x:?} in {steps} iterations, multipliers {lam:?}");
    }

    /// A tiny deterministic generator for test data.
    fn noise(seed: &mut u64) -> f64 {
        *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (*seed >> 11) as f64 / (1u64 << 53) as f64
    }

    /// The MMA point, the KKT point, their objectives and the iterations taken.
    struct Separable {
        x: Vec<f64>,
        exact: Vec<f64>,
        f: f64,
        f_exact: f64,
        steps: usize,
    }

    /// Minimise `Σ cⱼ/xⱼ` (a compliance-like objective) with `Σ vⱼ xⱼ ≤ V` over `xmin ≤ x ≤ 1`:
    /// the KKT point is `xⱼ = clamp(√(cⱼ / (λ vⱼ)))` with λ found by bisection.
    fn separable(n: usize, iterations: usize) -> Separable {
        let mut seed = 7;
        let c: Vec<f64> = (0..n).map(|_| (0.2 + 2.0 * noise(&mut seed)) / n as f64).collect();
        let v: Vec<f64> = (0..n).map(|_| (0.5 + noise(&mut seed)) / n as f64).collect();
        let (lo, hi) = (0.01, 1.0);
        let cap = 0.4 * v.iter().sum::<f64>();
        let at = |lam: f64| -> Vec<f64> { (0..n).map(|j| (c[j] / (lam * v[j])).sqrt().clamp(lo, hi)).collect() };
        let used = |x: &[f64]| -> f64 { x.iter().zip(&v).map(|(x, v)| x * v).sum() };
        let objective = |x: &[f64]| -> f64 { x.iter().zip(&c).map(|(x, c)| c / x).sum() };
        let (mut a, mut b) = (1e-12f64, 1e12f64);
        for _ in 0..400 {
            let mid = (a * b).sqrt();
            if used(&at(mid)) > cap { a = mid } else { b = mid }
        }
        let exact = at(b);

        let mut x = vec![0.4; n];
        let (xmin, xmax) = (vec![lo; n], vec![hi; n]);
        let dg = vec![v.iter().map(|v| v / cap).collect::<Vec<f64>>()];
        let mut mma = Mma::new(n, 1);
        let mut steps = iterations;
        for k in 0..iterations {
            let df0: Vec<f64> = x.iter().zip(&c).map(|(x, c)| -c / (x * x)).collect();
            let g = [used(&x) / cap - 1.0];
            let before = x.clone();
            mma.try_update(&mut x, &xmin, &xmax, &df0, &g, &dg, 0.2).unwrap();
            if x.iter().zip(&before).all(|(a, b)| (a - b).abs() < 1e-10) {
                steps = k + 1;
                break;
            }
        }
        Separable { f: objective(&x), f_exact: objective(&exact), x, exact, steps }
    }

    #[test]
    fn separable_against_kkt() {
        let Separable { x, exact, f, f_exact, steps } = separable(1000, 200);
        let worst = x.iter().zip(&exact).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        let rel = (f - f_exact) / f_exact;
        eprintln!("separable n = 1000: {steps} iterations, objective off by {rel:.2e}, worst variable off by {worst:.2e}");
        // The subproblem's interior point stops at epsi = EPSIMIN = 1e-7, which leaves the active
        // constraint a slack of about EPSIMIN / λ, so the objective sits about EPSIMIN / f above
        // the KKT value (f is about 3 here): 1e-7 is as close as the method gets, not 1e-8.
        assert!(worst < 1e-5 && rel.abs() < 1e-7, "{worst} {rel}");
    }

    /// Svanberg's (1987) cantilever: minimise `C₁ Σ xⱼ` with `Σ cⱼ / xⱼ³ ≤ 1`, c = 61, 37, 19, 7,
    /// 1, in 1 ≤ x ≤ 10 from x = 5. KKT: `xⱼ = S^(1/3) cⱼ^(1/4)` with `S = Σ cⱼ^(1/4)`, f = 1.3400.
    ///
    /// (Not Rosenbrock's valley: plain MMA, without GCMMA's growing curvature, cannot settle on an
    /// interior optimum. A variable whose Lagrangian gradient keeps one sign gets an approximation
    /// that falls all the way to its far asymptote, so it steps to alfa or beta every time, and
    /// the asymptotes cannot close in below 0.01 of the range: it cycles there, as Svanberg says.)
    #[test]
    fn svanberg_cantilever() {
        let c = [61.0f64, 37.0, 19.0, 7.0, 1.0];
        let c1 = 0.0624;
        let s: f64 = c.iter().map(|c| c.powf(0.25)).sum();
        let exact: Vec<f64> = c.iter().map(|c| s.cbrt() * c.powf(0.25)).collect();
        let f_exact = c1 * exact.iter().sum::<f64>();
        assert!((f_exact - 1.3400).abs() < 1e-4);
        let mut x = vec![5.0f64; 5];
        let (xmin, xmax) = (vec![1.0; 5], vec![10.0; 5]);
        let mut mma = Mma::new(5, 1);
        let mut steps = 0;
        for k in 0..200 {
            let df0 = vec![c1; 5];
            let g = [(0..5).map(|j| c[j] / x[j].powi(3)).sum::<f64>() - 1.0];
            let dg = vec![(0..5).map(|j| -3.0 * c[j] / x[j].powi(4)).collect::<Vec<f64>>()];
            let before = x.clone();
            mma.try_update(&mut x, &xmin, &xmax, &df0, &g, &dg, 0.5).unwrap();
            steps = k + 1;
            // Moves settle near 1e-8, the subproblem's own accuracy (EPSIMIN), not to zero.
            if x.iter().zip(&before).all(|(a, b)| (a - b).abs() < 1e-8) {
                break;
            }
        }
        let f = c1 * x.iter().sum::<f64>();
        eprintln!("cantilever: {x:?}, f = {f} ({:+.1e}), {steps} iterations", f / f_exact - 1.0);
        assert!(x.iter().zip(&exact).all(|(a, b)| (a / b - 1.0).abs() < 1e-5), "{x:?} vs {exact:?}");
        assert!((f / f_exact - 1.0).abs() < 1e-6, "{f} vs {f_exact}");
        // The multiplier: ∂f/∂xⱼ = λ 3 cⱼ / xⱼ⁴, so λ = C₁ S^(4/3) / 3.
        let lam = c1 * s.powf(4.0 / 3.0) / 3.0;
        assert!((mma.multipliers()[0] / lam - 1.0).abs() < 1e-4, "{:?} vs {lam}", mma.multipliers());
    }

    /// A Rosenbrock-like valley cut by the unit disc: minimise `(1 - x)² + b (y - x²)²` with
    /// `x² + y² ≤ 1` in `[0, 1.5]²` from (0.1, 0.1), for valley walls `b` of 1, 2 and 5. The
    /// unconstrained minimum (1, 1) lies outside, so the optimum is on the circle, found here by a
    /// golden-section search over its angle.
    ///
    /// Steeper walls (`b` = 10 and above, Rosenbrock's own 100) stall in the valley before the
    /// circle: on the floor each variable's gradient keeps one sign, so plain MMA steps a fixed
    /// share of its asymptotes' (floored) spread and zigzags across the valley instead of along it.
    /// Svanberg's GCMMA fixes this with a conservative inner loop that needs objective values,
    /// which this interface does not take; topology studies, where a volume or stress multiplier
    /// mixes the signs, do not need it.
    #[test]
    fn constrained_rosenbrock() {
        for b in [1.0, 2.0, 5.0] {
            let f = |x: &[f64]| (1.0 - x[0]).powi(2) + b * (x[1] - x[0] * x[0]).powi(2);
            let on = |t: f64| f(&[t.cos(), t.sin()]);
            let (mut lo, mut hi) = (0.2f64, 1.2f64);
            let phi = 0.5 * (5f64.sqrt() - 1.0);
            for _ in 0..200 {
                let (c, d) = (hi - phi * (hi - lo), lo + phi * (hi - lo));
                if on(c) < on(d) { hi = d } else { lo = c }
            }
            let t = 0.5 * (lo + hi);
            let exact = [t.cos(), t.sin()];

            let mut x = vec![0.1, 0.1];
            let mut mma = Mma::new(2, 1);
            let mut steps = 0;
            for k in 0..300 {
                let r = x[1] - x[0] * x[0];
                let df0 = vec![-2.0 * (1.0 - x[0]) - 4.0 * b * x[0] * r, 2.0 * b * r];
                let g = [x[0] * x[0] + x[1] * x[1] - 1.0];
                let dg = vec![vec![2.0 * x[0], 2.0 * x[1]]];
                let before = x.clone();
                mma.try_update(&mut x, &[0.0; 2], &[1.5; 2], &df0, &g, &dg, 0.2).unwrap();
                steps = k + 1;
                if x.iter().zip(&before).all(|(a, b)| (a - b).abs() < 1e-10) {
                    break;
                }
            }
            let lam = mma.multipliers()[0];
            eprintln!("Rosenbrock-like, b = {b}: {x:?} against {exact:?}, f = {:.8}, {steps} iterations, multiplier {lam:.6}", f(&x));
            assert!((x[0] - exact[0]).abs() < 1e-5 && (x[1] - exact[1]).abs() < 1e-5, "b = {b}: {x:?} against {exact:?} after {steps} iterations");
            // The interior point's last perturbation (EPSIMIN) leaves the circle a slack of about
            // EPSIMIN / λ, so f sits that times λ (about 1e-7) above the optimum.
            assert!((f(&x) - on(t)).abs() < 1e-6 && (x[0] * x[0] + x[1] * x[1] - 1.0).abs() < 1e-5);
            // KKT: ∇f + λ ∇g = 0 with λ > 0.
            let r = x[1] - x[0] * x[0];
            let df = [-2.0 * (1.0 - x[0]) - 4.0 * b * x[0] * r, 2.0 * b * r];
            assert!(lam > 0.0 && (0..2).all(|a| (df[a] + lam * 2.0 * x[a]).abs() < 1e-5), "{lam} {df:?}");
        }
    }

    #[test]
    fn fixed_variables_and_bad_input() {
        // xmin = xmax holds a variable; the others still move.
        let mut x = vec![0.5, 0.7, 0.2];
        let (xmin, xmax) = (vec![0.0, 0.7, 0.0], vec![1.0, 0.7, 1.0]);
        let mut mma = Mma::new(3, 1);
        for _ in 0..60 {
            let df0 = vec![2.0 * (x[0] - 0.9), 2.0 * (x[1] - 0.1), 2.0 * (x[2] - 0.8)];
            let g = [x[0] + x[2] - 1.0];
            let dg = vec![vec![1.0, 0.0, 1.0]];
            mma.try_update(&mut x, &xmin, &xmax, &df0, &g, &dg, 0.3).unwrap();
        }
        assert_eq!(x[1], 0.7);
        assert!((x[0] - 0.55).abs() < 1e-5 && (x[2] - 0.45).abs() < 1e-5, "{x:?}");
        // No constraints at all. An optimum on a bound is reached exactly; an interior one only to
        // within the asymptotes' floor (0.01 of the range, here 0.1): plain MMA steps to alfa or
        // beta there and cycles (see `svanberg_cantilever`).
        for (target, tol) in [(-7.0f64, 1e-6), (-1.0, 0.1)] {
            let mut y = vec![3.0];
            let mut free = Mma::new(1, 0);
            for _ in 0..60 {
                let df0 = [2.0 * (y[0] - target)];
                free.try_update(&mut y, &[-5.0], &[5.0], &df0, &[], &[], 0.5).unwrap();
            }
            assert!((y[0] - target.max(-5.0)).abs() <= tol, "{y:?} for {target}");
        }
        // Bad input is refused and leaves x alone, without panicking.
        let mut z = vec![0.5, 0.5];
        let mut mma = Mma::new(2, 1);
        let ok = (vec![0.0; 2], vec![1.0; 2], vec![1.0; 2], vec![0.0], vec![vec![1.0; 2]]);
        assert!(mma.try_update(&mut z, &ok.0, &ok.1, &ok.2, &ok.3, &ok.4, 0.2).is_ok());
        let before = z.clone();
        assert!(mma.try_update(&mut z, &ok.0, &ok.1, &[1.0], &ok.3, &ok.4, 0.2).is_err());
        assert!(mma.try_update(&mut z, &ok.0, &ok.1, &ok.2, &ok.3, &[vec![1.0]], 0.2).is_err());
        assert!(mma.try_update(&mut z, &ok.0, &ok.1, &[f64::NAN, 1.0], &ok.3, &ok.4, 0.2).is_err());
        assert!(mma.try_update(&mut z, &[2.0, 0.0], &ok.1, &ok.2, &ok.3, &ok.4, 0.2).is_err());
        assert!(mma.try_update(&mut z, &ok.0, &ok.1, &ok.2, &[f64::INFINITY], &ok.4, 0.2).is_err());
        assert!(mma.try_update(&mut z, &ok.0, &ok.1, &ok.2, &ok.3, &ok.4, -1.0).is_err());
        mma.update(&mut z, &ok.0, &ok.1, &[1.0], &ok.3, &ok.4, 0.2);
        assert_eq!(z, before);
        // A zero move limit holds everything.
        mma.try_update(&mut z, &ok.0, &ok.1, &ok.2, &ok.3, &ok.4, 0.0).unwrap();
        assert_eq!(z, before);
    }

    /// More constraints than variables: the primal form of the Newton system.
    #[test]
    fn many_constraints() {
        // Minimise -(x0 + x1) under four half-planes; the optimum is the vertex (0.6, 0.8)...
        // of x0 + 2 x1 ≤ 2.2 and 2 x0 + x1 ≤ 2.0, with two looser ones.
        let rows = [[1.0, 2.0, 2.2], [2.0, 1.0, 2.0], [1.0, 1.0, 1.9], [1.0, 0.0, 0.95]];
        let mut x = vec![0.1, 0.1];
        let mut mma = Mma::new(2, 4);
        for _ in 0..200 {
            let g: Vec<f64> = rows.iter().map(|r| r[0] * x[0] + r[1] * x[1] - r[2]).collect();
            let dg: Vec<Vec<f64>> = rows.iter().map(|r| vec![r[0], r[1]]).collect();
            mma.try_update(&mut x, &[0.0; 2], &[1.0; 2], &[-1.0, -1.0], &g, &dg, 0.2).unwrap();
        }
        assert!((x[0] - 0.6).abs() < 1e-5 && (x[1] - 0.8).abs() < 1e-5, "{x:?}");
        let lam = mma.multipliers();
        assert!((lam[0] - 1.0 / 3.0).abs() < 1e-4 && (lam[1] - 1.0 / 3.0).abs() < 1e-4 && lam[2] < 1e-4 && lam[3] < 1e-4, "{lam:?}");
    }

    /// Large: the separable problem over many variables, timed, and the same bits twice.
    #[test]
    fn large_is_parallel_and_deterministic() {
        let n = 200_000;
        let run = || {
            let t = std::time::Instant::now();
            let r = separable(n, 30);
            (r, t.elapsed().as_secs_f64())
        };
        let (first, secs) = run();
        let (second, _) = run();
        assert!(first.x == second.x, "parallel sums must not depend on scheduling");
        let Separable { x: x1, exact, f, f_exact, steps } = first;
        let rel = (f - f_exact) / f_exact;
        eprintln!("separable n = {n}: {steps} iterations in {secs:.2} s ({:.1} ms each), objective off by {rel:.2e}", 1e3 * secs / steps as f64);
        assert!(rel.abs() < 1e-6);
        let worst = x1.iter().zip(&exact).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        assert!(worst < 1e-3, "{worst}");
    }

    /// Two million variables and three constraints, one outer iteration timed (run with
    /// `--ignored`).
    #[test]
    #[ignore]
    fn two_million() {
        let n = 2_000_000;
        let mut seed = 3;
        let c: Vec<f64> = (0..n).map(|_| (0.2 + noise(&mut seed)) / n as f64).collect();
        let mut x = vec![0.3; n];
        let (xmin, xmax) = (vec![1e-3; n], vec![1.0; n]);
        let mut mma = Mma::new(n, 3);
        for k in 0..3 {
            let df0: Vec<f64> = x.iter().zip(&c).map(|(x, c)| -c / (x * x)).collect();
            let g = vec![x.iter().sum::<f64>() / (0.3 * n as f64) - 1.0, x[..n / 2].iter().sum::<f64>() / (0.2 * n as f64) - 1.0, -1.0];
            let dg = vec![vec![1.0 / (0.3 * n as f64); n], (0..n).map(|j| if j < n / 2 { 1.0 / (0.2 * n as f64) } else { 0.0 }).collect(), vec![0.0; n]];
            let t = std::time::Instant::now();
            mma.try_update(&mut x, &xmin, &xmax, &df0, &g, &dg, 0.2).unwrap();
            eprintln!("n = {n}, m = 3: iteration {} in {:.3} s", k + 1, t.elapsed().as_secs_f64());
        }
    }
}
