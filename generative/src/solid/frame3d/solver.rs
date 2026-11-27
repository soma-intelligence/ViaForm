//! Sparse Cholesky factorisation of a frame's stiffness in dense 6×6 blocks, one per node.
//!
//! Nodes are ordered by nested dissection (split the node set at the median of its longest
//! extent, the smaller side's boundary is the separator, numbered last), the elimination tree
//! gives the factor's block pattern, and the numbers are computed column by column, left-looking.
//! A frame's graph is a lattice, so the factor stays sparse: a separator of `s` nodes fills a
//! dense `6s` square, the cost of a 3D lattice of `N` nodes grows as `N²` rather than the band's
//! `N^(7/3)`. Blocks are row-major `[f64; 36]`.

use super::beam::V3;

pub type Block = [f64; 36];

/// The ordering and the factor's block pattern, fixed for one set of nodes and beams.
pub struct Symbolic {
    /// New position to node, and back.
    perm: Vec<usize>,
    iperm: Vec<usize>,
    /// Off-diagonal blocks of column `j` (new numbering) are `start[j]..start[j + 1]`, their rows
    /// in `rows`, ascending.
    start: Vec<usize>,
    rows: Vec<usize>,
    /// Blocks in row `j`, left of the diagonal: `row_start[j]..row_start[j + 1]` index
    /// `row_slot` (the block's place in storage) and `row_col` (its column).
    row_start: Vec<usize>,
    row_col: Vec<usize>,
    row_slot: Vec<usize>,
    /// Per edge: the slot of its off-diagonal block and whether that block's row is its first end.
    edge_slot: Vec<(usize, bool)>,
}

/// The numbers: `K = L Lᵀ`, diagonal blocks lower triangular.
pub struct Factor {
    diag: Vec<Block>,
    off: Vec<Block>,
}

impl Symbolic {
    /// The ordering and pattern for nodes at `pos` joined by `edges` (no repeats, no loops).
    pub fn new(pos: &[V3], edges: &[[usize; 2]]) -> Self {
        let n = pos.len();
        let mut adj = vec![Vec::new(); n];
        for &[a, b] in edges {
            adj[a].push(b);
            adj[b].push(a);
        }
        let mut set: Vec<usize> = (0..n).collect();
        let mut perm = Vec::with_capacity(n);
        let mut mark = vec![0u32; n];
        let mut stamp = 0u32;
        dissect(&mut set, pos, &adj, &mut mark, &mut stamp, &mut perm);
        let mut iperm = vec![0; n];
        for (new, &old) in perm.iter().enumerate() {
            iperm[old] = new;
        }

        // Column patterns from the elimination tree.
        let mut pattern: Vec<Vec<usize>> = Vec::with_capacity(n);
        let mut children: Vec<Vec<usize>> = vec![Vec::new(); n];
        let mut seen = vec![usize::MAX; n];
        for j in 0..n {
            let mut p = Vec::new();
            seen[j] = j;
            for &nb in &adj[perm[j]] {
                let i = iperm[nb];
                if i > j && seen[i] != j {
                    seen[i] = j;
                    p.push(i);
                }
            }
            for &c in &children[j] {
                for &i in &pattern[c] {
                    if seen[i] != j {
                        seen[i] = j;
                        p.push(i);
                    }
                }
            }
            p.sort_unstable();
            if let Some(&parent) = p.first() {
                children[parent].push(j);
            }
            pattern.push(p);
        }
        let mut start = Vec::with_capacity(n + 1);
        start.push(0);
        let mut rows = Vec::new();
        for p in &pattern {
            rows.extend_from_slice(p);
            start.push(rows.len());
        }
        drop(pattern);

        let mut count = vec![0usize; n + 1];
        for &i in &rows {
            count[i + 1] += 1;
        }
        for j in 0..n {
            count[j + 1] += count[j];
        }
        let row_start = count.clone();
        let mut row_col = vec![0; rows.len()];
        let mut row_slot = vec![0; rows.len()];
        for k in 0..n {
            for s in start[k]..start[k + 1] {
                let i = rows[s];
                row_col[count[i]] = k;
                row_slot[count[i]] = s;
                count[i] += 1;
            }
        }

        let edge_slot = edges
            .iter()
            .map(|&[a, b]| {
                let (ia, ib) = (iperm[a], iperm[b]);
                let (col, row) = (ia.min(ib), ia.max(ib));
                let at = rows[start[col]..start[col + 1]].binary_search(&row).expect("edge in its column's pattern");
                (start[col] + at, row == ia)
            })
            .collect();
        Self { perm, iperm, start, rows, row_start, row_col, row_slot, edge_slot }
    }

    pub fn nodes(&self) -> usize {
        self.perm.len()
    }

    /// Assembles and factors. `elements[e]` holds edge `e`'s blocks `[K_aa, K_ab, K_ba, K_bb]` for
    /// its ends `a`, `b`; `fixed` marks held degrees of freedom (6 per node), whose rows and
    /// columns become the identity. Fails with the first node whose pivot vanishes (a mechanism).
    pub fn factor(&self, elements: &[[Block; 4]], edges: &[[usize; 2]], fixed: &[bool]) -> Result<Factor, usize> {
        let n = self.nodes();
        let mut diag = vec![[0.0; 36]; n];
        let mut off = vec![[0.0; 36]; self.rows.len()];
        for (e, (&[a, b], k)) in edges.iter().zip(elements).enumerate() {
            add_to(&mut diag[self.iperm[a]], &k[0]);
            add_to(&mut diag[self.iperm[b]], &k[3]);
            let (slot, row_is_a) = self.edge_slot[e];
            add_to(&mut off[slot], if row_is_a { &k[1] } else { &k[2] });
        }
        for j in 0..n {
            let fj = &fixed[6 * self.perm[j]..6 * self.perm[j] + 6];
            let dj = &mut diag[j];
            for r in 0..6 {
                for c in 0..6 {
                    if fj[r] || fj[c] {
                        dj[6 * r + c] = if r == c { 1.0 } else { 0.0 };
                    }
                }
            }
            for s in self.start[j]..self.start[j + 1] {
                let i = self.perm[self.rows[s]];
                let fi = &fixed[6 * i..6 * i + 6];
                for r in 0..6 {
                    for c in 0..6 {
                        if fi[r] || fj[c] {
                            off[s][6 * r + c] = 0.0;
                        }
                    }
                }
            }
        }

        let mut slot_of = vec![0usize; n];
        for j in 0..n {
            let (s0, s1) = (self.start[j], self.start[j + 1]);
            for s in s0..s1 {
                slot_of[self.rows[s]] = s;
            }
            let mut dj = diag[j];
            let scale: [f64; 6] = std::array::from_fn(|r| dj[7 * r].abs());
            let (done, here) = off.split_at_mut(s0);
            for r in self.row_start[j]..self.row_start[j + 1] {
                let (k, sjk) = (self.row_col[r], self.row_slot[r]);
                let ljk = done[sjk];
                sub_abt(&mut dj, &ljk, &ljk);
                for (s, lik) in done.iter().enumerate().take(self.start[k + 1]).skip(sjk + 1) {
                    sub_abt(&mut here[slot_of[self.rows[s]] - s0], lik, &ljk);
                }
            }
            if !chol(&mut dj, &scale) {
                return Err(self.perm[j]);
            }
            for w in here.iter_mut().take(s1 - s0) {
                right_solve(w, &dj);
            }
            diag[j] = dj;
        }
        Ok(Factor { diag, off })
    }

    /// Solves `K x = b` in place (`b` per node, 6 each, in the caller's numbering).
    pub fn solve(&self, f: &Factor, b: &mut [f64]) {
        let n = self.nodes();
        let mut y = vec![0.0; 6 * n];
        for (j, &old) in self.perm.iter().enumerate() {
            y[6 * j..6 * j + 6].copy_from_slice(&b[6 * old..6 * old + 6]);
        }
        for j in 0..n {
            let mut yj = [0.0; 6];
            yj.copy_from_slice(&y[6 * j..6 * j + 6]);
            lower_solve(&f.diag[j], &mut yj);
            y[6 * j..6 * j + 6].copy_from_slice(&yj);
            for s in self.start[j]..self.start[j + 1] {
                let i = self.rows[s];
                let l = &f.off[s];
                for r in 0..6 {
                    let mut acc = 0.0;
                    for c in 0..6 {
                        acc += l[6 * r + c] * yj[c];
                    }
                    y[6 * i + r] -= acc;
                }
            }
        }
        for j in (0..n).rev() {
            let mut yj = [0.0; 6];
            yj.copy_from_slice(&y[6 * j..6 * j + 6]);
            for s in self.start[j]..self.start[j + 1] {
                let i = self.rows[s];
                let l = &f.off[s];
                for r in 0..6 {
                    let yi = y[6 * i + r];
                    for c in 0..6 {
                        yj[c] -= l[6 * r + c] * yi;
                    }
                }
            }
            upper_solve(&f.diag[j], &mut yj);
            y[6 * j..6 * j + 6].copy_from_slice(&yj);
        }
        for (j, &old) in self.perm.iter().enumerate() {
            b[6 * old..6 * old + 6].copy_from_slice(&y[6 * j..6 * j + 6]);
        }
    }
}

/// Nested dissection of `set` into `out`.
fn dissect(set: &mut [usize], pos: &[V3], adj: &[Vec<usize>], mark: &mut [u32], stamp: &mut u32, out: &mut Vec<usize>) {
    if set.len() <= 24 {
        out.extend_from_slice(set);
        return;
    }
    let mut lo = [f64::INFINITY; 3];
    let mut hi = [f64::NEG_INFINITY; 3];
    for &v in set.iter() {
        for a in 0..3 {
            lo[a] = lo[a].min(pos[v][a]);
            hi[a] = hi[a].max(pos[v][a]);
        }
    }
    let axis = (0..3).max_by(|&a, &b| (hi[a] - lo[a]).total_cmp(&(hi[b] - lo[b]))).unwrap_or(0);
    set.sort_by(|&a, &b| pos[a][axis].total_cmp(&pos[b][axis]).then(a.cmp(&b)));
    let mid = set.len() / 2;
    let (left, right) = set.split_at(mid);
    let boundary = |side: &[usize], other: &[usize], mark: &mut [u32], stamp: &mut u32| {
        *stamp += 1;
        for &v in other {
            mark[v] = *stamp;
        }
        let s = *stamp;
        side.iter().copied().filter(|&v| adj[v].iter().any(|&w| mark[w] == s)).collect::<Vec<_>>()
    };
    let sep_left = boundary(left, right, mark, stamp);
    let sep_right = boundary(right, left, mark, stamp);
    let (sep, cut_left) = if sep_left.len() <= sep_right.len() { (sep_left, true) } else { (sep_right, false) };
    *stamp += 1;
    let s = *stamp;
    for &v in &sep {
        mark[v] = s;
    }
    let keep = |side: &[usize], cut: bool| -> Vec<usize> { if cut { side.iter().copied().filter(|&v| mark[v] != s).collect() } else { side.to_vec() } };
    let mut a = keep(left, cut_left);
    let mut b = keep(right, !cut_left);
    dissect(&mut a, pos, adj, mark, stamp, out);
    dissect(&mut b, pos, adj, mark, stamp, out);
    out.extend_from_slice(&sep);
}

fn add_to(a: &mut Block, b: &Block) {
    for (x, y) in a.iter_mut().zip(b) {
        *x += y;
    }
}

/// `c -= a bᵀ`.
fn sub_abt(c: &mut Block, a: &Block, b: &Block) {
    for r in 0..6 {
        let ar: [f64; 6] = std::array::from_fn(|t| a[6 * r + t]);
        for col in 0..6 {
            let mut acc = 0.0;
            for t in 0..6 {
                acc += ar[t] * b[6 * col + t];
            }
            c[6 * r + col] -= acc;
        }
    }
}

/// In-place Cholesky of a 6×6 block (lower triangle kept, upper cleared); false when a pivot is
/// not positive against `scale`, the block's diagonal before elimination.
fn chol(a: &mut Block, scale: &[f64; 6]) -> bool {
    for c in 0..6 {
        let mut v = a[7 * c];
        for t in 0..c {
            v -= a[6 * c + t] * a[6 * c + t];
        }
        if !(v > 1e-12 * scale[c]) || !v.is_finite() {
            return false;
        }
        let p = v.sqrt();
        a[7 * c] = p;
        for r in c + 1..6 {
            let mut w = a[6 * r + c];
            for t in 0..c {
                w -= a[6 * r + t] * a[6 * c + t];
            }
            a[6 * r + c] = w / p;
        }
        for r in 0..c {
            a[6 * r + c] = 0.0;
        }
    }
    true
}

/// `w ← w L⁻ᵀ` for lower triangular `l`.
fn right_solve(w: &mut Block, l: &Block) {
    for r in 0..6 {
        for c in 0..6 {
            let mut v = w[6 * r + c];
            for t in 0..c {
                v -= l[6 * c + t] * w[6 * r + t];
            }
            w[6 * r + c] = v / l[7 * c];
        }
    }
}

fn lower_solve(l: &Block, y: &mut [f64; 6]) {
    for r in 0..6 {
        let mut v = y[r];
        for t in 0..r {
            v -= l[6 * r + t] * y[t];
        }
        y[r] = v / l[7 * r];
    }
}

fn upper_solve(l: &Block, y: &mut [f64; 6]) {
    for r in (0..6).rev() {
        let mut v = y[r];
        for t in r + 1..6 {
            v -= l[6 * t + r] * y[t];
        }
        y[r] = v / l[7 * r];
    }
}
