//! Bilinear plane-stress elements on a structured grid, and the linear solver: a conjugate
//! gradient preconditioned by a geometric multigrid V-cycle (Galerkin coarse operators, symmetric
//! block Gauss-Seidel smoothing, a dense Cholesky factor on the coarsest grid).
//!
//! Nodes are numbered row by row, `n = j * mx + i`, two unknowns each (`2n` along X, `2n + 1`
//! along Y). An element's corners run `(i, j)`, `(i + 1, j)`, `(i + 1, j + 1)`, `(i, j + 1)`.

/// Natural coordinates of the element corners.
const XI: [f64; 4] = [-1.0, 1.0, 1.0, -1.0];
const ETA: [f64; 4] = [-1.0, -1.0, 1.0, 1.0];

/// Smoothing sweeps before and after each coarse correction.
const SWEEPS: usize = 1;
/// The coarsest grid, in nodes, solved directly.
const COARSEST: usize = 200;

/// Strain-displacement matrix of a square element of side `h` at natural point `(xi, eta)`.
pub fn strain_matrix(h: f64, xi: f64, eta: f64) -> [[f64; 8]; 3] {
    let mut b = [[0.0; 8]; 3];
    for a in 0..4 {
        let dx = XI[a] * (1.0 + eta * ETA[a]) / (2.0 * h);
        let dy = ETA[a] * (1.0 + xi * XI[a]) / (2.0 * h);
        b[0][2 * a] = dx;
        b[1][2 * a + 1] = dy;
        b[2][2 * a] = dy;
        b[2][2 * a + 1] = dx;
    }
    b
}

/// Plane-stress constitutive matrix for modulus `e`.
pub fn elasticity(e: f64, nu: f64) -> [[f64; 3]; 3] {
    let k = e / (1.0 - nu * nu);
    [[k, k * nu, 0.0], [k * nu, k, 0.0], [0.0, 0.0, k * (1.0 - nu) / 2.0]]
}

/// Stiffness of a square element with unit modulus and thickness `t`. It does not depend on the
/// side length. 2×2 Gauss points integrate the bilinear element exactly.
pub fn element_stiffness(nu: f64, t: f64) -> [[f64; 8]; 8] {
    let d = elasticity(1.0, nu);
    let g = 1.0 / 3f64.sqrt();
    let mut k = [[0.0; 8]; 8];
    for (xi, eta) in [(-g, -g), (g, -g), (g, g), (-g, g)] {
        let b = strain_matrix(1.0, xi, eta);
        let mut db = [[0.0; 8]; 3];
        for (r, row) in db.iter_mut().enumerate() {
            for (c, v) in row.iter_mut().enumerate() {
                *v = (0..3).map(|s| d[r][s] * b[s][c]).sum();
            }
        }
        // Unit side: the Jacobian determinant is 1/4.
        for (r, row) in k.iter_mut().enumerate() {
            for (c, v) in row.iter_mut().enumerate() {
                *v += 0.25 * t * (0..3).map(|s| b[s][r] * db[s][c]).sum::<f64>();
            }
        }
    }
    k
}

/// A symmetric operator on a grid of `mx` × `my` nodes, two unknowns each, stored as the 2×2
/// blocks that couple every node to its 3×3 neighbourhood. Block `k = (dj + 1) * 3 + (di + 1)`
/// couples node `(i, j)` to `(i + di, j + dj)`; its entry `(r, c)` sits at `k * 4 + r * 2 + c`.
#[derive(Clone)]
pub struct Stencil {
    pub mx: usize,
    pub my: usize,
    pub a: Vec<[f64; 36]>,
}

impl Stencil {
    fn zeros(mx: usize, my: usize) -> Self {
        Self { mx, my, a: vec![[0.0; 36]; mx * my] }
    }

    /// Assembles `nx` × `ny` elements, element `j * nx + i` scaled by `factors[j * nx + i]`.
    pub fn assemble(nx: usize, ny: usize, ke: &[[f64; 8]; 8], factors: &[f64]) -> Self {
        let mx = nx + 1;
        let mut s = Self::zeros(nx + 1, ny + 1);
        for j in 0..ny {
            for i in 0..nx {
                let f = factors[j * nx + i];
                let corners = [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)];
                for (p, &(pi, pj)) in corners.iter().enumerate() {
                    let blocks = &mut s.a[pj * mx + pi];
                    for (q, &(qi, qj)) in corners.iter().enumerate() {
                        let k = (qj + 1 - pj) * 3 + (qi + 1 - pi);
                        for r in 0..2 {
                            for c in 0..2 {
                                blocks[k * 4 + r * 2 + c] += f * ke[2 * p + r][2 * q + c];
                            }
                        }
                    }
                }
            }
        }
        s
    }

    /// The node `(i, j)` offset by block `k`, if it lies on the grid.
    #[inline]
    fn neighbour(&self, i: usize, j: usize, k: usize) -> Option<usize> {
        let (ii, jj) = ((i + k % 3).checked_sub(1)?, (j + k / 3).checked_sub(1)?);
        (ii < self.mx && jj < self.my).then_some(jj * self.mx + ii)
    }

    /// Pins unknown `d` to zero: its row and column vanish and its diagonal becomes one.
    pub fn pin(&mut self, d: usize) {
        let (n, c) = (d / 2, d % 2);
        let (i, j) = (n % self.mx, n / self.mx);
        for k in 0..9 {
            let Some(m) = self.neighbour(i, j, k) else { continue };
            self.a[n][k * 4 + c * 2] = 0.0;
            self.a[n][k * 4 + c * 2 + 1] = 0.0;
            let back = 8 - k;
            self.a[m][back * 4 + c] = 0.0;
            self.a[m][back * 4 + 2 + c] = 0.0;
        }
        self.a[n][4 * 4 + c * 2 + c] = 1.0;
    }

    /// Row `n` = `(i, j)` times `x`, skipping the diagonal block when `skip_centre`.
    #[inline]
    fn row(&self, n: usize, i: usize, j: usize, x: &[f64], skip_centre: bool) -> (f64, f64) {
        let b = &self.a[n];
        let (mut y0, mut y1) = (0.0, 0.0);
        if i > 0 && j > 0 && i + 1 < self.mx && j + 1 < self.my {
            // Interior: every neighbour exists, three contiguous nodes per grid row.
            for dj in 0..3 {
                let m0 = n + dj * self.mx - self.mx - 1;
                let xs = &x[2 * m0..2 * m0 + 6];
                let bs = &b[dj * 12..dj * 12 + 12];
                for di in 0..3 {
                    let (x0, x1) = (xs[2 * di], xs[2 * di + 1]);
                    y0 += bs[4 * di] * x0 + bs[4 * di + 1] * x1;
                    y1 += bs[4 * di + 2] * x0 + bs[4 * di + 3] * x1;
                }
            }
            if skip_centre {
                let (x0, x1) = (x[2 * n], x[2 * n + 1]);
                y0 -= b[16] * x0 + b[17] * x1;
                y1 -= b[18] * x0 + b[19] * x1;
            }
            return (y0, y1);
        }
        for k in 0..9 {
            if skip_centre && k == 4 {
                continue;
            }
            let Some(m) = self.neighbour(i, j, k) else { continue };
            let (x0, x1) = (x[2 * m], x[2 * m + 1]);
            y0 += b[k * 4] * x0 + b[k * 4 + 1] * x1;
            y1 += b[k * 4 + 2] * x0 + b[k * 4 + 3] * x1;
        }
        (y0, y1)
    }

    /// `y = A x`.
    pub fn apply(&self, x: &[f64], y: &mut [f64]) {
        for j in 0..self.my {
            for i in 0..self.mx {
                let n = j * self.mx + i;
                let (y0, y1) = self.row(n, i, j, x, false);
                y[2 * n] = y0;
                y[2 * n + 1] = y1;
            }
        }
    }

    /// One block Gauss-Seidel sweep, forward or backward through the nodes.
    fn smooth(&self, dinv: &[[f64; 4]], x: &mut [f64], b: &[f64], forward: bool) {
        let total = self.mx * self.my;
        for t in 0..total {
            let n = if forward { t } else { total - 1 - t };
            let (s0, s1) = self.row(n, n % self.mx, n / self.mx, x, true);
            let (r0, r1) = (b[2 * n] - s0, b[2 * n + 1] - s1);
            let d = dinv[n];
            x[2 * n] = d[0] * r0 + d[1] * r1;
            x[2 * n + 1] = d[2] * r0 + d[3] * r1;
        }
    }

    /// Inverses of the diagonal blocks.
    fn diagonal_inverses(&self) -> Result<Vec<[f64; 4]>, String> {
        self.a
            .iter()
            .map(|b| {
                let (a, bb, c, d) = (b[16], b[17], b[18], b[19]);
                let det = a * d - bb * c;
                if !(det.is_finite() && det > 0.0 && a > 0.0) {
                    return Err("the stiffness matrix is singular".to_string());
                }
                Ok([d / det, -bb / det, -c / det, a / det])
            })
            .collect()
    }
}

/// The coarse nodes (at most two) a fine node interpolates from, and their weights.
#[derive(Clone, Copy)]
struct Parents {
    idx: [usize; 2],
    w: [f64; 2],
    len: usize,
}

/// Along one direction of `n` elements: the coarse element count (`ceil(n / 2)`) and each fine
/// node's parents. Coarse node `I` sits on fine node `min(2I, n)`.
fn parents(n: usize) -> (usize, Vec<Parents>) {
    let m = n.div_ceil(2);
    let list = (0..=n)
        .map(|i| {
            if i % 2 == 0 {
                Parents { idx: [i / 2, 0], w: [1.0, 0.0], len: 1 }
            } else if i == n {
                Parents { idx: [m, 0], w: [1.0, 0.0], len: 1 }
            } else {
                Parents { idx: [i / 2, i / 2 + 1], w: [0.5, 0.5], len: 2 }
            }
        })
        .collect();
    (m, list)
}

/// Galerkin coarse operator `Pᵀ A P` for bilinear interpolation `P`. It keeps the 3×3 stencil.
fn coarsen(fine: &Stencil, px: &[Parents], py: &[Parents], cmx: usize, cmy: usize) -> Stencil {
    let mut c = Stencil::zeros(cmx, cmy);
    for j in 0..fine.my {
        for i in 0..fine.mx {
            let n = j * fine.mx + i;
            let (pi, pj) = (px[i], py[j]);
            for a in 0..pi.len {
                for b in 0..pj.len {
                    let (ci, cj, w1) = (pi.idx[a], pj.idx[b], pi.w[a] * pj.w[b]);
                    let nc = cj * cmx + ci;
                    for k in 0..9 {
                        let Some(m) = fine.neighbour(i, j, k) else { continue };
                        let blk = &fine.a[n][k * 4..k * 4 + 4];
                        let (qi, qj) = (px[m % fine.mx], py[m / fine.mx]);
                        for a2 in 0..qi.len {
                            for b2 in 0..qj.len {
                                let (ki, kj, w2) = (qi.idx[a2], qj.idx[b2], qi.w[a2] * qj.w[b2]);
                                let (Some(di), Some(dj)) = ((ki + 1).checked_sub(ci), (kj + 1).checked_sub(cj)) else { continue };
                                if di > 2 || dj > 2 {
                                    continue;
                                }
                                let kc = dj * 3 + di;
                                let w = w1 * w2;
                                let dst = &mut c.a[nc][kc * 4..kc * 4 + 4];
                                for q in 0..4 {
                                    dst[q] += w * blk[q];
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    c
}

struct Level {
    s: Stencil,
    dinv: Vec<[f64; 4]>,
    /// Interpolation from the next coarser level; empty on the coarsest.
    px: Vec<Parents>,
    py: Vec<Parents>,
    cmx: usize,
}

/// A factored stiffness matrix ready to solve.
pub struct Solver {
    levels: Vec<Level>,
    /// Dense lower Cholesky factor of the coarsest level, `nc` × `nc`.
    chol: Vec<f64>,
    nc: usize,
}

impl Solver {
    /// Builds the multigrid hierarchy for `fine` (already pinned).
    pub fn new(fine: Stencil) -> Result<Self, String> {
        let mut levels = Vec::new();
        let mut s = fine;
        loop {
            let dinv = s.diagonal_inverses()?;
            let (cx, px) = parents(s.mx - 1);
            let (cy, py) = parents(s.my - 1);
            let nodes = s.mx * s.my;
            if nodes <= COARSEST || (cx + 1) * (cy + 1) == nodes {
                levels.push(Level { s, dinv, px: Vec::new(), py: Vec::new(), cmx: 0 });
                break;
            }
            let c = coarsen(&s, &px, &py, cx + 1, cy + 1);
            levels.push(Level { s, dinv, px, py, cmx: cx + 1 });
            s = c;
        }
        let last = &levels[levels.len() - 1].s;
        let nc = 2 * last.mx * last.my;
        let mut m = vec![0.0; nc * nc];
        for j in 0..last.my {
            for i in 0..last.mx {
                let n = j * last.mx + i;
                for k in 0..9 {
                    let Some(o) = last.neighbour(i, j, k) else { continue };
                    for r in 0..2 {
                        for c in 0..2 {
                            m[(2 * n + r) * nc + 2 * o + c] = last.a[n][k * 4 + r * 2 + c];
                        }
                    }
                }
            }
        }
        cholesky(&mut m, nc)?;
        Ok(Self { levels, chol: m, nc })
    }

    fn vcycle(&self, l: usize, b: &[f64], x: &mut [f64]) {
        x.fill(0.0);
        if l + 1 == self.levels.len() {
            x.copy_from_slice(b);
            cholesky_solve(&self.chol, self.nc, x);
            return;
        }
        let lev = &self.levels[l];
        let s = &lev.s;
        for _ in 0..SWEEPS {
            s.smooth(&lev.dinv, x, b, true);
        }
        let mut r = vec![0.0; b.len()];
        s.apply(x, &mut r);
        for (r, b) in r.iter_mut().zip(b) {
            *r = b - *r;
        }
        let coarse = &self.levels[l + 1].s;
        let mut rc = vec![0.0; 2 * coarse.mx * coarse.my];
        for j in 0..s.my {
            for i in 0..s.mx {
                let n = j * s.mx + i;
                let (pi, pj) = (lev.px[i], lev.py[j]);
                for a in 0..pi.len {
                    for bb in 0..pj.len {
                        let nc = pj.idx[bb] * lev.cmx + pi.idx[a];
                        let w = pi.w[a] * pj.w[bb];
                        rc[2 * nc] += w * r[2 * n];
                        rc[2 * nc + 1] += w * r[2 * n + 1];
                    }
                }
            }
        }
        let mut ec = vec![0.0; rc.len()];
        self.vcycle(l + 1, &rc, &mut ec);
        for j in 0..s.my {
            for i in 0..s.mx {
                let n = j * s.mx + i;
                let (pi, pj) = (lev.px[i], lev.py[j]);
                for a in 0..pi.len {
                    for bb in 0..pj.len {
                        let nc = pj.idx[bb] * lev.cmx + pi.idx[a];
                        let w = pi.w[a] * pj.w[bb];
                        x[2 * n] += w * ec[2 * nc];
                        x[2 * n + 1] += w * ec[2 * nc + 1];
                    }
                }
            }
        }
        for _ in 0..SWEEPS {
            s.smooth(&lev.dinv, x, b, false);
        }
    }

    /// Solves `A x = b` to a relative residual of `tol`, starting from `x`. Returns the iterations.
    pub fn solve(&self, b: &[f64], x: &mut [f64], tol: f64, max_iter: usize) -> Result<usize, String> {
        let a = &self.levels[0].s;
        let nb = dot(b, b).sqrt();
        if nb == 0.0 {
            x.fill(0.0);
            return Ok(0);
        }
        let mut r = vec![0.0; b.len()];
        a.apply(x, &mut r);
        for (r, b) in r.iter_mut().zip(b) {
            *r = b - *r;
        }
        if dot(&r, &r).sqrt() <= tol * nb {
            return Ok(0);
        }
        let mut z = vec![0.0; b.len()];
        self.vcycle(0, &r, &mut z);
        let mut p = z.clone();
        let mut q = vec![0.0; b.len()];
        let mut rz = dot(&r, &z);
        for it in 1..=max_iter {
            a.apply(&p, &mut q);
            let pq = dot(&p, &q);
            if !(pq.is_finite() && pq > 0.0) {
                return Err("the stiffness matrix is singular".into());
            }
            let alpha = rz / pq;
            for ((x, r), (p, q)) in x.iter_mut().zip(r.iter_mut()).zip(p.iter().zip(&q)) {
                *x += alpha * p;
                *r -= alpha * q;
            }
            let nr = dot(&r, &r).sqrt();
            if !nr.is_finite() {
                return Err("the displacement solve diverged".into());
            }
            if nr <= tol * nb {
                return Ok(it);
            }
            self.vcycle(0, &r, &mut z);
            let rz_new = dot(&r, &z);
            let beta = rz_new / rz;
            rz = rz_new;
            for (p, z) in p.iter_mut().zip(&z) {
                *p = z + beta * *p;
            }
        }
        Ok(max_iter)
    }
}

fn dot(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(a, b)| a * b).sum()
}

/// In-place dense Cholesky: the lower triangle of `m` (row-major, `n` × `n`) becomes `L`.
fn cholesky(m: &mut [f64], n: usize) -> Result<(), String> {
    for j in 0..n {
        let s = m[j * n + j] - (0..j).map(|k| m[j * n + k] * m[j * n + k]).sum::<f64>();
        if !(s.is_finite() && s > 0.0) {
            return Err("the stiffness matrix is singular".into());
        }
        let d = s.sqrt();
        m[j * n + j] = d;
        for i in j + 1..n {
            let s = m[i * n + j] - (0..j).map(|k| m[i * n + k] * m[j * n + k]).sum::<f64>();
            m[i * n + j] = s / d;
        }
    }
    Ok(())
}

/// Solves `L Lᵀ x = b` in place.
fn cholesky_solve(l: &[f64], n: usize, x: &mut [f64]) {
    for i in 0..n {
        let s = x[i] - (0..i).map(|k| l[i * n + k] * x[k]).sum::<f64>();
        x[i] = s / l[i * n + i];
    }
    for i in (0..n).rev() {
        let s = x[i] - (i + 1..n).map(|k| l[k * n + i] * x[k]).sum::<f64>();
        x[i] = s / l[i * n + i];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topology_element_stiffness_is_symmetric_and_rigid_free() {
        let k = element_stiffness(0.3, 1.0);
        let expected = (0.5 - 0.3 / 6.0) / (1.0 - 0.09);
        assert!((k[0][0] - expected).abs() < 1e-12);
        for (r, row) in k.iter().enumerate() {
            for (c, v) in row.iter().enumerate() {
                assert!((v - k[c][r]).abs() < 1e-12);
            }
            let tx: f64 = (0..4).map(|a| row[2 * a]).sum();
            let ty: f64 = (0..4).map(|a| row[2 * a + 1]).sum();
            assert!(tx.abs() < 1e-12 && ty.abs() < 1e-12);
        }
    }

    #[test]
    fn topology_multigrid_matches_direct() {
        let (nx, ny) = (37, 23);
        let ke = element_stiffness(0.3, 2.0);
        let factors: Vec<f64> = (0..nx * ny).map(|e| if e % 7 == 0 { 1e-3 } else { 1.0 }).collect();
        let mut s = Stencil::assemble(nx, ny, &ke, &factors);
        for j in 0..=ny {
            s.pin(2 * j * (nx + 1));
            s.pin(2 * j * (nx + 1) + 1);
        }
        let n = 2 * (nx + 1) * (ny + 1);
        let mut b = vec![0.0; n];
        b[2 * (nx + 1) * (ny / 2 + 1) - 1] = -1.0;
        let solver = Solver::new(s.clone()).unwrap();
        assert!(solver.levels.len() > 1);
        let mut x = vec![0.0; n];
        let its = solver.solve(&b, &mut x, 1e-10, 500).unwrap();
        assert!(its < 100, "{its} iterations");
        let mut ax = vec![0.0; n];
        s.apply(&x, &mut ax);
        let err: f64 = ax.iter().zip(&b).map(|(a, b)| (a - b).powi(2)).sum::<f64>().sqrt();
        assert!(err < 1e-9);
    }
}
