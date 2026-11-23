//! Convex compliant constraint solver (Todorov 2014 MuJoCo formulation; Castro, Permenter and
//! Han 2023 "SAP" primal form), solved by Newton with a backtracking line search, with
//! projected Gauss-Seidel on the dual as the fallback.
//!
//! The next velocity minimises
//! `l(v) = 1/2 |v - v*|_A^2 + sum_i l_i(J_i v)`, where `A = M + dt D + dt^2 K` (mass matrix with
//! implicit damping, springs and armature), `v*` the unconstrained next velocity, and each
//! constraint block `i` has velocity `y_i = J_i v`, regularisation `R_i` (diagonal) and bias
//! `vhat_i`. With `u = -R^-1 (J_i v - vhat_i)` the impulse is the projection
//! `gamma_i = P_F(u)` under the `R` norm onto its set `F` (a Coulomb cone `|g_t| <= mu g_n` for
//! contacts, an interval for joint limits, equalities, joint friction, servos and tendons), and
//! `l_i = 1/2 |gamma_i|_R^2` extended linearly outside an interval. `l` is convex and
//! continuously differentiable: `grad l = A (v - v*) - J^T gamma`, with the generalised Hessian
//! `A + J^T G J`, `G = R^-1/2 dP R^-1/2` (`dP` the Jacobian of the projection, symmetric). Every
//! block is visited in the order it was built, so results are bitwise reproducible.

/// A block's admissible impulse set.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    /// Three rows `[t1, t2, n]`: the Coulomb cone with coefficient `mu`.
    Cone { mu: f64 },
    /// One row, impulse in `[lo, hi]` (unilateral: `lo = 0`; bilateral: infinite bounds).
    Interval { lo: f64, hi: f64 },
}

/// How a block's regularisation is set.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Reg {
    /// Given `R` per row.
    Given([f64; 3]),
    /// Compliant contact (SAP): normal `max(1 / (dt k (dt + tau_d)), beta^2 w / (4 pi^2))`,
    /// tangential `sigma w` (`w` the block's Delassus diagonal estimate).
    Compliant { k: f64, tau_d: f64, beta: f64, sigma: f64 },
    /// Regularised friction: `sigma w`.
    Friction { sigma: f64 },
}

/// One constraint block.
#[derive(Clone, Copy, Debug)]
pub struct Block {
    pub kind: Kind,
    pub reg: Reg,
    pub dim: usize,
    /// Offset of its columns in `Problem::cols` and of its values in `Problem::vals`.
    pub c0: usize,
    pub nc: usize,
    pub v0: usize,
    pub vhat: [f64; 3],
    /// Filled in by the solver: `R` per row and the Delassus estimate.
    pub r: [f64; 3],
    pub w: f64,
}

/// The constraint set of one step: sparse Jacobian rows (only the columns of the bodies the
/// block touches).
#[derive(Clone, Debug, Default)]
pub struct Problem {
    pub blocks: Vec<Block>,
    pub cols: Vec<usize>,
    pub vals: Vec<f64>,
}

impl Problem {
    pub fn clear(&mut self) {
        self.blocks.clear();
        self.cols.clear();
        self.vals.clear();
    }

    /// Starts a block over the given columns; returns its index. Fill its rows with
    /// [`Problem::row_mut`].
    pub fn push(&mut self, kind: Kind, reg: Reg, cols: &[usize], vhat: [f64; 3]) -> usize {
        let dim = match kind {
            Kind::Cone { .. } => 3,
            Kind::Interval { .. } => 1,
        };
        let b = Block { kind, reg, dim, c0: self.cols.len(), nc: cols.len(), v0: self.vals.len(), vhat, r: [0.0; 3], w: 0.0 };
        self.cols.extend_from_slice(cols);
        self.vals.resize(self.vals.len() + dim * cols.len(), 0.0);
        self.blocks.push(b);
        self.blocks.len() - 1
    }

    /// Row `r` of block `b` (values aligned with the block's columns).
    pub fn row_mut(&mut self, b: usize, r: usize) -> &mut [f64] {
        let bl = &self.blocks[b];
        let s = bl.v0 + r * bl.nc;
        &mut self.vals[s..s + bl.nc]
    }

    pub fn rows(&self) -> usize {
        self.blocks.iter().map(|b| b.dim).sum()
    }
}

/// Which solver ran.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SolverKind {
    #[default]
    Newton,
    Pgs,
}

/// Solver settings.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct SolverSettings {
    pub kind: SolverKind,
    /// Relative tolerance on the scaled gradient.
    pub tol: f64,
    pub max_newton: usize,
    pub max_pgs: usize,
}

impl Default for SolverSettings {
    fn default() -> Self {
        SolverSettings { kind: SolverKind::Newton, tol: 1e-10, max_newton: 60, max_pgs: 300 }
    }
}

/// Outcome of one solve.
#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub struct SolveStats {
    pub used: SolverKind,
    pub iterations: usize,
    pub converged: bool,
    pub fallback: bool,
}

/// Scratch buffers.
#[derive(Clone, Debug, Default)]
pub struct Solver {
    l: Vec<f64>,
    h: Vec<f64>,
    grad: Vec<f64>,
    dv: Vec<f64>,
    v: Vec<f64>,
    vt: Vec<f64>,
    tmp: Vec<f64>,
    tmp2: Vec<f64>,
    /// Impulse per row (block order).
    pub gamma: Vec<f64>,
    gtrial: Vec<f64>,
    g: Vec<[f64; 9]>,
    y: Vec<f64>,
    wmat: Vec<f64>,
    diag: Vec<f64>,
    d2: Vec<f64>,
}

/// In-place Cholesky `A = L L^T` of a row-major `n x n` matrix (lower triangle written).
pub fn cholesky(a: &mut [f64], n: usize) -> bool {
    for j in 0..n {
        let mut d = a[j * n + j];
        for k in 0..j {
            d -= a[j * n + k] * a[j * n + k];
        }
        if !(d > 0.0) || !d.is_finite() {
            return false;
        }
        let d = d.sqrt();
        a[j * n + j] = d;
        for i in j + 1..n {
            let mut s = a[i * n + j];
            for k in 0..j {
                s -= a[i * n + k] * a[j * n + k];
            }
            a[i * n + j] = s / d;
        }
    }
    true
}

/// Solves `L y = b` in place.
pub fn forward(l: &[f64], n: usize, b: &mut [f64]) {
    for i in 0..n {
        let mut s = b[i];
        for k in 0..i {
            s -= l[i * n + k] * b[k];
        }
        b[i] = s / l[i * n + i];
    }
}

/// Solves `L L^T x = b` in place.
pub fn chol_solve(l: &[f64], n: usize, b: &mut [f64]) {
    forward(l, n, b);
    for i in (0..n).rev() {
        let mut s = b[i];
        for k in i + 1..n {
            s -= l[k * n + i] * b[k];
        }
        b[i] = s / l[i * n + i];
    }
}

/// Projection of `u` (impulse units) onto the cone `|t| <= mu n` in the norm `R`, and the
/// generalised Hessian block `G` (row-major 3x3) and cost `1/2 |gamma|_R^2`.
fn project_cone(u: [f64; 3], r: [f64; 3], mu: f64, gamma: &mut [f64], g: &mut [f64; 9]) -> f64 {
    let (st, sn) = (r[0].sqrt(), r[2].sqrt());
    // Scaled coordinates z = R^1/2 u; cone slope mu~ = mu sqrt(Rt / Rn).
    let (z1, z2, zn) = (st * u[0], st * u[1], sn * u[2]);
    let mt = mu * st / sn;
    let zr = (z1 * z1 + z2 * z2).sqrt();
    *g = [0.0; 9];
    if zr <= mt * zn {
        // Stick: inside the cone.
        gamma[0] = u[0];
        gamma[1] = u[1];
        gamma[2] = u[2];
        g[0] = 1.0 / r[0];
        g[4] = 1.0 / r[1];
        g[8] = 1.0 / r[2];
        return 0.5 * (z1 * z1 + z2 * z2 + zn * zn);
    }
    if mt * zr <= -zn || zr == 0.0 && zn <= 0.0 {
        // Separation: the polar cone.
        gamma[0] = 0.0;
        gamma[1] = 0.0;
        gamma[2] = 0.0;
        return 0.0;
    }
    // Slide: project onto the cone surface.
    let k = 1.0 / (1.0 + mt * mt);
    let pn = (zn + mt * zr) * k;
    let (t1, t2) = (z1 / zr, z2 / zr);
    let (p1, p2) = (mt * pn * t1, mt * pn * t2);
    gamma[0] = p1 / st;
    gamma[1] = p2 / st;
    gamma[2] = pn / sn;
    // dP in z coordinates (order t1, t2, n).
    let a = mt * pn / zr;
    let dp = [
        mt * mt * k * t1 * t1 + a * (1.0 - t1 * t1),
        mt * mt * k * t1 * t2 - a * t1 * t2,
        mt * k * t1,
        mt * mt * k * t2 * t1 - a * t2 * t1,
        mt * mt * k * t2 * t2 + a * (1.0 - t2 * t2),
        mt * k * t2,
        mt * k * t1,
        mt * k * t2,
        k,
    ];
    let s = [st, st, sn];
    for i in 0..3 {
        for j in 0..3 {
            g[i * 3 + j] = dp[i * 3 + j] / (s[i] * s[j]);
        }
    }
    0.5 * (p1 * p1 + p2 * p2 + pn * pn)
}

/// Interval projection, `G` and the (Huber-like) cost.
fn project_interval(u: f64, r: f64, lo: f64, hi: f64) -> (f64, f64, f64) {
    if u > hi {
        (hi, 0.0, 0.5 * r * hi * hi + r * hi * (u - hi))
    } else if u < lo {
        (lo, 0.0, 0.5 * r * lo * lo + r * lo * (u - lo))
    } else {
        (u, 1.0 / r, 0.5 * r * u * u)
    }
}

impl Solver {
    fn ensure(&mut self, nv: usize, rows: usize, nb: usize) {
        self.l.resize(nv * nv, 0.0);
        self.h.resize(nv * nv, 0.0);
        for b in [&mut self.d2, &mut self.grad, &mut self.dv, &mut self.v, &mut self.vt, &mut self.tmp, &mut self.tmp2] {
            b.resize(nv, 0.0);
        }
        self.gamma.resize(rows, 0.0);
        self.gtrial.resize(rows, 0.0);
        self.g.resize(nb, [0.0; 9]);
    }

    /// Solves for the next velocity. `a` is `A` (row-major, `nv x nv`), `vstar` the
    /// unconstrained velocity, `vwarm` a warm start (the present velocity). Writes the
    /// velocity into `v_out` and the impulses into `self.gamma`.
    pub fn solve(&mut self, p: &mut Problem, a: &[f64], vstar: &[f64], vwarm: &[f64], dt: f64, s: &SolverSettings, v_out: &mut [f64]) -> SolveStats {
        let nv = vstar.len();
        let rows = p.rows();
        self.ensure(nv, rows, p.blocks.len());
        // Factor A and set the regularisation from the Delassus diagonal estimate.
        self.l.copy_from_slice(a);
        if !cholesky(&mut self.l, nv) {
            v_out.copy_from_slice(vstar);
            return SolveStats { used: s.kind, iterations: 0, converged: false, fallback: false };
        }
        for bi in 0..p.blocks.len() {
            let b = p.blocks[bi];
            let mut w = 0.0;
            for r in 0..b.dim {
                self.tmp.iter_mut().for_each(|x| *x = 0.0);
                for c in 0..b.nc {
                    self.tmp[p.cols[b.c0 + c]] += p.vals[b.v0 + r * b.nc + c];
                }
                forward(&self.l, nv, &mut self.tmp);
                w += self.tmp.iter().map(|x| x * x).sum::<f64>();
            }
            w /= b.dim as f64;
            let w = w.max(1e-300);
            let rr = match b.reg {
                Reg::Given(r) => r,
                Reg::Compliant { k, tau_d, beta, sigma } => {
                    let soft = if k > 0.0 { 1.0 / (dt * k * (dt + tau_d)) } else { 0.0 };
                    let rn = soft.max(beta * beta * w / (4.0 * std::f64::consts::PI * std::f64::consts::PI));
                    match b.kind {
                        Kind::Cone { .. } => [sigma * w, sigma * w, rn],
                        Kind::Interval { .. } => [rn, rn, rn],
                    }
                }
                Reg::Friction { sigma } => [sigma * w; 3],
            };
            p.blocks[bi].r = rr;
            p.blocks[bi].w = w;
        }
        let mut stats = match s.kind {
            SolverKind::Newton => self.newton(p, a, vstar, vwarm, s, v_out),
            SolverKind::Pgs => self.pgs(p, vstar, s, v_out),
        };
        if s.kind == SolverKind::Newton && !stats.converged {
            // Keep Newton's answer if it lowered the cost well; otherwise run PGS.
            let ok = v_out.iter().all(|x| x.is_finite());
            if !ok {
                stats = self.pgs(p, vstar, s, v_out);
                stats.fallback = true;
            }
        }
        stats
    }

    /// Velocities of the blocks, impulses, Hessian blocks and the constraint cost at `v`.
    fn eval(&mut self, p: &Problem, v: &[f64], trial: bool) -> f64 {
        let mut cost = 0.0;
        let mut row = 0;
        for (bi, b) in p.blocks.iter().enumerate() {
            let mut u = [0.0; 3];
            for r in 0..b.dim {
                let mut y = 0.0;
                let vals = &p.vals[b.v0 + r * b.nc..b.v0 + (r + 1) * b.nc];
                for (c, val) in vals.iter().enumerate() {
                    y += val * v[p.cols[b.c0 + c]];
                }
                u[r] = -(y - b.vhat[r]) / b.r[r];
            }
            let gam = if trial { &mut self.gtrial } else { &mut self.gamma };
            match b.kind {
                Kind::Cone { mu } => {
                    let mut g = [0.0; 9];
                    cost += project_cone(u, b.r, mu, &mut gam[row..row + 3], &mut g);
                    if !trial {
                        self.g[bi] = g;
                    }
                }
                Kind::Interval { lo, hi } => {
                    let (x, g, c) = project_interval(u[0], b.r[0], lo, hi);
                    gam[row] = x;
                    cost += c;
                    if !trial {
                        self.g[bi][0] = g;
                    }
                }
            }
            row += b.dim;
        }
        cost
    }

    fn quad(a: &[f64], d: &[f64], tmp: &mut [f64]) -> f64 {
        let n = d.len();
        let mut s = 0.0;
        for i in 0..n {
            let mut x = 0.0;
            for k in 0..n {
                x += a[i * n + k] * d[k];
            }
            tmp[i] = x;
            s += x * d[i];
        }
        0.5 * s
    }

    fn jt_gamma(p: &Problem, gamma: &[f64], out: &mut [f64]) {
        out.iter_mut().for_each(|x| *x = 0.0);
        let mut row = 0;
        for b in &p.blocks {
            for r in 0..b.dim {
                let gr = gamma[row + r];
                if gr == 0.0 {
                    continue;
                }
                for c in 0..b.nc {
                    out[p.cols[b.c0 + c]] += p.vals[b.v0 + r * b.nc + c] * gr;
                }
            }
            row += b.dim;
        }
    }

    fn newton(&mut self, p: &Problem, a: &[f64], vstar: &[f64], vwarm: &[f64], s: &SolverSettings, v_out: &mut [f64]) -> SolveStats {
        let nv = vstar.len();
        // Start from the better of v* and the warm start.
        let total = |me: &mut Solver, v: &[f64]| -> f64 {
            for i in 0..nv {
                me.d2[i] = v[i] - vstar[i];
            }
            let q = Solver::quad(a, &me.d2, &mut me.tmp);
            q + me.eval(p, v, true)
        };
        let c_star = total(self, vstar);
        let c_warm = total(self, vwarm);
        self.v.copy_from_slice(if c_warm < c_star { vwarm } else { vstar });
        let mut it = 0;
        let mut converged = false;
        self.diag.resize(nv, 0.0);
        for i in 0..nv {
            self.diag[i] = 1.0 / a[i * nv + i].sqrt();
        }
        loop {
            // Gradient at v.
            for i in 0..nv {
                self.dv[i] = self.v[i] - vstar[i];
            }
            let cq = Solver::quad(a, &self.dv, &mut self.tmp);
            let v = std::mem::take(&mut self.v);
            let cost = cq + self.eval(p, &v, false);
            self.v = v;
            Solver::jt_gamma(p, &self.gamma, &mut self.tmp2);
            let (mut gn, mut an, mut jn) = (0.0f64, 0.0f64, 0.0f64);
            for i in 0..nv {
                self.grad[i] = self.tmp[i] - self.tmp2[i];
                gn = gn.max((self.grad[i] * self.diag[i]).abs());
                an = an.max((self.tmp[i] * self.diag[i]).abs());
                jn = jn.max((self.tmp2[i] * self.diag[i]).abs());
            }
            if gn <= 1e-14 + s.tol * an.max(jn) {
                converged = true;
                break;
            }
            if it >= s.max_newton {
                break;
            }
            it += 1;
            // Hessian A + J^T G J.
            self.h.copy_from_slice(a);
            for (bi, b) in p.blocks.iter().enumerate() {
                let g = &self.g[bi];
                let nc = b.nc;
                let cols = &p.cols[b.c0..b.c0 + nc];
                let vals = &p.vals[b.v0..b.v0 + b.dim * nc];
                if b.dim == 1 {
                    let g0 = g[0];
                    if g0 == 0.0 {
                        continue;
                    }
                    for x in 0..nc {
                        let jx = vals[x] * g0;
                        for y in 0..nc {
                            self.h[cols[x] * nv + cols[y]] += jx * vals[y];
                        }
                    }
                } else {
                    if g.iter().all(|x| *x == 0.0) {
                        continue;
                    }
                    // GJ (3 x nc), then J^T (GJ).
                    for x in 0..nc {
                        let j0 = [vals[x], vals[nc + x], vals[2 * nc + x]];
                        let gj = [
                            g[0] * j0[0] + g[1] * j0[1] + g[2] * j0[2],
                            g[3] * j0[0] + g[4] * j0[1] + g[5] * j0[2],
                            g[6] * j0[0] + g[7] * j0[1] + g[8] * j0[2],
                        ];
                        for y in 0..nc {
                            self.h[cols[y] * nv + cols[x]] += vals[y] * gj[0] + vals[nc + y] * gj[1] + vals[2 * nc + y] * gj[2];
                        }
                    }
                }
            }
            if !cholesky(&mut self.h, nv) {
                break;
            }
            for i in 0..nv {
                self.dv[i] = -self.grad[i];
            }
            chol_solve(&self.h, nv, &mut self.dv);
            let slope: f64 = (0..nv).map(|i| self.grad[i] * self.dv[i]).sum();
            if !(slope < 0.0) {
                converged = true;
                break;
            }
            // Backtracking (Armijo) line search.
            let mut alpha = 1.0;
            let mut accepted = false;
            for _ in 0..40 {
                for i in 0..nv {
                    self.vt[i] = self.v[i] + alpha * self.dv[i];
                }
                let vt = std::mem::take(&mut self.vt);
                let ct = total(self, &vt);
                self.vt = vt;
                if ct <= cost + 1e-4 * alpha * slope {
                    accepted = true;
                    break;
                }
                alpha *= 0.5;
            }
            if !accepted {
                // No decrease left at machine precision: v is the minimiser.
                converged = true;
                break;
            }
            std::mem::swap(&mut self.v, &mut self.vt);
        }
        v_out.copy_from_slice(&self.v);
        // Impulses at the final v.
        let v = std::mem::take(&mut self.v);
        self.eval(p, &v, false);
        self.v = v;
        SolveStats { used: SolverKind::Newton, iterations: it, converged, fallback: false }
    }

    /// Projected Gauss-Seidel on the dual `min 1/2 g^T (W + R) g + g^T (J v* - vhat)`, blocks in
    /// order, cone blocks projected in the diagonal metric of `W_ii + R_i`.
    fn pgs(&mut self, p: &Problem, vstar: &[f64], s: &SolverSettings, v_out: &mut [f64]) -> SolveStats {
        let nv = vstar.len();
        let rows = p.rows();
        // Y = A^-1 J^T (nv x rows, column per row), W = J Y.
        self.y.resize(nv * rows, 0.0);
        self.wmat.resize(rows * rows, 0.0);
        let mut row = 0;
        let mut row_of = Vec::with_capacity(rows);
        for (bi, b) in p.blocks.iter().enumerate() {
            for r in 0..b.dim {
                row_of.push((bi, r));
                let mut col = vec![0.0; nv];
                for c in 0..b.nc {
                    col[p.cols[b.c0 + c]] += p.vals[b.v0 + r * b.nc + c];
                }
                chol_solve(&self.l, nv, &mut col);
                self.y[row * nv..(row + 1) * nv].copy_from_slice(&col);
                row += 1;
            }
        }
        let jrow = |k: usize, x: &[f64]| -> f64 {
            let (bi, r) = row_of[k];
            let b = &p.blocks[bi];
            (0..b.nc).map(|c| p.vals[b.v0 + r * b.nc + c] * x[p.cols[b.c0 + c]]).sum()
        };
        for i in 0..rows {
            for k in 0..rows {
                self.wmat[i * rows + k] = jrow(i, &self.y[k * nv..(k + 1) * nv]);
            }
        }
        let bias: Vec<f64> = (0..rows).map(|k| {
            let (bi, r) = row_of[k];
            jrow(k, vstar) - p.blocks[bi].vhat[r]
        }).collect();
        let gam = &mut self.gamma;
        gam.iter_mut().for_each(|x| *x = 0.0);
        let mut it = 0;
        let mut converged = false;
        while it < s.max_pgs {
            it += 1;
            let mut change = 0.0f64;
            let mut scale = 1e-300f64;
            let mut row = 0;
            for b in &p.blocks {
                let d = b.dim;
                let mut grad = [0.0; 3];
                let mut m = [0.0; 3];
                for r in 0..d {
                    let i = row + r;
                    let mut x = bias[i] + b.r[r] * gam[i];
                    for k in 0..rows {
                        x += self.wmat[i * rows + k] * gam[k];
                    }
                    grad[r] = x;
                    m[r] = self.wmat[i * rows + i] + b.r[r];
                }
                let old = [gam[row], if d == 3 { gam[row + 1] } else { 0.0 }, if d == 3 { gam[row + 2] } else { 0.0 }];
                match b.kind {
                    Kind::Interval { lo, hi } => {
                        gam[row] = (old[0] - grad[0] / m[0]).clamp(lo, hi);
                    }
                    Kind::Cone { mu } => {
                        let u = [old[0] - grad[0] / m[0], old[1] - grad[1] / m[1], old[2] - grad[2] / m[2]];
                        let mut g = [0.0; 9];
                        project_cone(u, m, mu, &mut gam[row..row + 3], &mut g);
                    }
                }
                for r in 0..d {
                    change = change.max((gam[row + r] - old[r]).abs());
                    scale = scale.max(gam[row + r].abs());
                }
                row += d;
            }
            if change <= 1e-12 * scale {
                converged = true;
                break;
            }
        }
        for i in 0..nv {
            let mut x = vstar[i];
            for k in 0..rows {
                x += self.y[k * nv + i] * gam[k];
            }
            v_out[i] = x;
        }
        SolveStats { used: SolverKind::Pgs, iterations: it, converged, fallback: false }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cone_projection_is_a_projection() {
        // Inside, outside, and polar points; G symmetric; gamma in the cone.
        let r = [1e-3, 1e-3, 0.5];
        for u in [[0.1, 0.0, 1.0], [5.0, 1.0, 1.0], [1.0, -2.0, -3.0], [-0.3, 0.2, 0.05]] {
            let mut g = [0.0; 9];
            let mut gam = [0.0; 3];
            project_cone(u, r, 0.5, &mut gam, &mut g);
            assert!((gam[0] * gam[0] + gam[1] * gam[1]).sqrt() <= 0.5 * gam[2] + 1e-12, "{gam:?}");
            for i in 0..3 {
                for j in 0..3 {
                    assert!((g[i * 3 + j] - g[j * 3 + i]).abs() < 1e-9 * (1.0 + g[i * 3 + j].abs()));
                }
            }
            // G = d gamma / d u * R^-1: check by differences.
            for k in 0..3 {
                let mut up = u;
                up[k] += 1e-7;
                let mut gp = [0.0; 3];
                let mut gg = [0.0; 9];
                project_cone(up, r, 0.5, &mut gp, &mut gg);
                for i in 0..3 {
                    let fd = (gp[i] - gam[i]) / 1e-7;
                    let an = g[i * 3 + k] * r[k];
                    assert!((fd - an).abs() < 1e-4 * (1.0 + an.abs()), "u {u:?} d{i}/d{k}: {fd} vs {an}");
                }
            }
        }
    }

    #[test]
    fn cholesky_solves() {
        let a = [4.0, 1.0, 0.5, 1.0, 3.0, 0.2, 0.5, 0.2, 2.0];
        let mut l = a;
        assert!(cholesky(&mut l, 3));
        let mut b = [1.0, 2.0, 3.0];
        chol_solve(&l, 3, &mut b);
        for i in 0..3 {
            let s: f64 = (0..3).map(|k| a[i * 3 + k] * b[k]).sum();
            assert!((s - [1.0, 2.0, 3.0][i]).abs() < 1e-12);
        }
    }
}
