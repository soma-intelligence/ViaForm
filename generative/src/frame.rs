//! Ground-structure frames: candidate beams between grid nodes, sized by an evolution strategy
//! and checked by a plane-frame finite-element model.
//!
//! The pipeline:
//! 1. Ground structure: a grid of nodes (at most about 15 × 15) plus a node at the centre of every
//!    support and load region, candidate beams between nodes up to 2.3 spacings apart (so
//!    diagonals and knight moves), none crossing a keep-out region, none overlapping a shorter
//!    collinear one. Mirror twins (from the spec's symmetry) share one width.
//! 2. Layout: optimality-criteria resizing for least compliance at the volume cap over the whole
//!    ground structure; members that stay thinner than half the narrowest member go.
//! 3. Sizing: a (μ/μ_w, λ) evolution strategy with a self-adapting step and per-variable scales,
//!    one width per beam group, for least mass under the stress and volume limits. A width under
//!    `min_member` removes the beam.
//! 4. Polish: fully stressed resizing and greedy pruning of members the frame does not need, then
//!    cleanup (dangling members, unused nodes).
//!
//! The finite-element model is a plane frame: three degrees of freedom per node (u, v, θ),
//! Euler-Bernoulli beams of section `width × thickness` (width in plane), rigid joints. Nodes are
//! numbered along the domain's longer side so the stiffness matrix is banded; a banded Cholesky
//! factorisation solves it and flags mechanisms.

use std::collections::HashMap;

use crate::spec::{Beam, Fix, Region, Shape, Solved, Spec};

/// Grid intervals along the domain's longer side, at most.
const MAX_INTERVALS: f64 = 14.0;
/// Candidate beams join nodes up to this many spacings apart.
const REACH: f64 = 2.3;
/// A region's centre reuses a grid node closer than this share of the spacing.
const SNAP: f64 = 0.3;
/// Pivot below this share of its original diagonal: the frame is a mechanism.
const PIVOT: f64 = 1e-11;
/// Floating-point work the evolution strategy may spend, roughly (sets the population).
const WORK_BUDGET: f64 = 4e9;

/// Sizes the ground structure's beams for least mass under the stress and volume limits.
pub fn solve(spec: &Spec, seed: u64) -> Result<Solved, String> {
    let model = Model::build(spec)?;
    let mut rng = Rng::new(seed);
    let start = model.layout();
    let (mut best, best_obj, history) = model.evolve(&start, spec.iterations, &mut rng);
    model.polish(&mut best, best_obj);
    model.cleanup(&mut best);
    model.finish(&best, history)
}

// MARK: Ground structure

struct Member {
    a: usize,
    b: usize,
    len: f64,
    c: f64,
    s: f64,
}

struct Model {
    width: f64,
    height: f64,
    t: f64,
    e: f64,
    density: f64,
    /// Stress limit, MPa (infinite when the material gives none).
    allowable: f64,
    min_w: f64,
    max_w: f64,
    vol_cap: f64,
    nodes: Vec<[f64; 2]>,
    /// Position of each node in the banded numbering.
    rank: Vec<usize>,
    fixed: Vec<[bool; 3]>,
    loaded: Vec<bool>,
    /// Per load case: nodal forces.
    cases: Vec<Vec<(usize, [f64; 2])>>,
    members: Vec<Member>,
    /// Member indices per design variable (mirror twins together).
    groups: Vec<Vec<usize>>,
    /// Half-bandwidth of the full ground structure (for the work estimate).
    band: usize,
}

impl Model {
    fn build(spec: &Spec) -> Result<Model, String> {
        let (w, h) = (spec.width, spec.height);
        if !(w > 0.0 && h > 0.0 && spec.thickness > 0.0 && spec.material.e > 0.0) {
            return Err("the frame needs a positive width, height, thickness and modulus".into());
        }
        let spacing = spec.resolution.max(w.max(h) / MAX_INTERVALS);
        let nx = ((w / spacing).round() as usize).max(1);
        let ny = ((h / spacing).round() as usize).max(1);
        let (dx, dy) = (w / nx as f64, h / ny as f64);
        let fine = dx.min(dy);
        let min_w = spec.min_member.max(1e-3 * fine);
        let max_w = (3.0 * min_w).max(0.75 * fine);
        let margin = 0.5 * min_w;
        let blocked = |p: [f64; 2]| spec.keep_out.iter().any(|r| inflated_contains(r, p, margin));

        let mut nodes = Vec::with_capacity((nx + 1) * (ny + 1));
        for j in 0..=ny {
            for i in 0..=nx {
                nodes.push([i as f64 * dx, j as f64 * dy]);
            }
        }
        let centres = spec
            .supports
            .iter()
            .map(|s| s.region.center())
            .chain(spec.cases.iter().flat_map(|c| c.loads.iter().map(|l| l.region.center())));
        for c in centres {
            let c = [c[0].clamp(0.0, w), c[1].clamp(0.0, h)];
            let mut ps = vec![c];
            if spec.symmetry.x {
                ps.push([w - c[0], c[1]]);
            }
            if spec.symmetry.y {
                for k in 0..ps.len() {
                    ps.push([ps[k][0], h - ps[k][1]]);
                }
            }
            for p in ps {
                if nearest(&nodes, p).is_none_or(|(_, d)| d > SNAP * fine) {
                    nodes.push(p);
                }
            }
        }
        nodes.retain(|&p| !blocked(p));
        if nodes.len() < 2 {
            return Err("keep-out regions leave no room for a frame".into());
        }
        let nn = nodes.len();

        // Supports: every node inside the region, else the nearest one.
        let mut fixed = vec![[false; 3]; nn];
        for s in &spec.supports {
            let held = match s.fix {
                Fix::All => [true, true, true],
                Fix::X => [true, false, false],
                Fix::Y => [false, true, false],
            };
            let inside: Vec<usize> = (0..nn).filter(|&i| s.region.contains(nodes[i])).collect();
            let inside = if inside.is_empty() { nearest(&nodes, s.region.center()).map(|(i, _)| vec![i]).unwrap_or_default() } else { inside };
            for i in inside {
                for k in 0..3 {
                    fixed[i][k] |= held[k];
                }
            }
        }
        // Loads: split evenly over the nodes inside the region, else the nearest node.
        let mut loaded = vec![false; nn];
        let mut cases = Vec::with_capacity(spec.cases.len());
        for case in &spec.cases {
            let mut forces: Vec<(usize, [f64; 2])> = Vec::new();
            for load in &case.loads {
                let inside: Vec<usize> = (0..nn).filter(|&i| load.region.contains(nodes[i])).collect();
                let inside = if inside.is_empty() { nearest(&nodes, load.region.center()).map(|(i, _)| vec![i]).unwrap_or_default() } else { inside };
                let share = 1.0 / inside.len().max(1) as f64;
                for i in inside {
                    let f = [load.force[0] * share, load.force[1] * share];
                    if f[0] != 0.0 || f[1] != 0.0 {
                        loaded[i] = true;
                    }
                    match forces.iter_mut().find(|(n, _)| *n == i) {
                        Some((_, g)) => {
                            g[0] += f[0];
                            g[1] += f[1];
                        }
                        None => forces.push((i, f)),
                    }
                }
            }
            cases.push(forces);
        }

        // Candidate beams.
        let reach = REACH * dx.max(dy) * (1.0 + 1e-9);
        let tol = 0.05 * fine;
        let mut members = Vec::new();
        for a in 0..nn {
            for b in a + 1..nn {
                let (pa, pb) = (nodes[a], nodes[b]);
                let len = (pb[0] - pa[0]).hypot(pb[1] - pa[1]);
                if len > reach || len < 1e-9 {
                    continue;
                }
                if spec.keep_out.iter().any(|r| segment_hits(r, pa, pb, margin)) {
                    continue;
                }
                if (0..nn).any(|k| k != a && k != b && passes_near(pa, pb, len, nodes[k], tol)) {
                    continue;
                }
                members.push(Member { a, b, len, c: (pb[0] - pa[0]) / len, s: (pb[1] - pa[1]) / len });
            }
        }
        if members.is_empty() {
            return Err("the ground structure has no beams: lower the resolution or shrink the keep-out regions".into());
        }

        // Banded numbering along the longer side.
        let mut order: Vec<usize> = (0..nn).collect();
        let (major, minor) = if w >= h { (0, 1) } else { (1, 0) };
        order.sort_by(|&i, &j| nodes[i][major].total_cmp(&nodes[j][major]).then(nodes[i][minor].total_cmp(&nodes[j][minor])));
        let mut rank = vec![0; nn];
        for (r, &i) in order.iter().enumerate() {
            rank[i] = r;
        }
        let band = members.iter().map(|m| 3 * rank[m.a].abs_diff(rank[m.b]) + 2).max().unwrap_or(2);

        let groups = mirror_groups(spec, &nodes, &members, 1e-3 * fine);
        let allowable = if spec.material.allowable > 0.0 { spec.material.allowable } else { f64::INFINITY };
        Ok(Model {
            width: w,
            height: h,
            t: spec.thickness,
            e: spec.material.e,
            density: spec.material.density,
            allowable,
            min_w,
            max_w,
            vol_cap: spec.volume_fraction * w * h * spec.thickness,
            nodes,
            rank,
            fixed,
            loaded,
            cases,
            members,
            groups,
            band,
        })
    }

    /// Member widths from group widths.
    fn expand(&self, gw: &[f64]) -> Vec<f64> {
        let mut w = vec![0.0; self.members.len()];
        for (g, ms) in self.groups.iter().enumerate() {
            for &m in ms {
                w[m] = gw[g];
            }
        }
        w
    }

    /// A design variable as a width: under the narrowest member it removes the beam.
    fn decode(&self, x: f64) -> f64 {
        if x >= self.min_w { x.min(self.max_w) } else { 0.0 }
    }

    /// Members present and joined to a support.
    fn grounded(&self, w: &[f64]) -> Vec<bool> {
        let nn = self.nodes.len();
        let mut parent: Vec<usize> = (0..nn).collect();
        for (k, m) in self.members.iter().enumerate() {
            if w[k] > 0.0 {
                let (ra, rb) = (find(&mut parent, m.a), find(&mut parent, m.b));
                if ra != rb {
                    parent[ra] = rb;
                }
            }
        }
        let mut held = vec![false; nn];
        for i in 0..nn {
            if self.fixed[i].iter().any(|&f| f) {
                let r = find(&mut parent, i);
                held[r] = true;
            }
        }
        self.members.iter().enumerate().map(|(k, m)| w[k] > 0.0 && held[find(&mut parent, m.a)]).collect()
    }
}

/// Unions each beam with its mirror twins; returns member indices per group, in member order.
fn mirror_groups(spec: &Spec, nodes: &[[f64; 2]], members: &[Member], tol: f64) -> Vec<Vec<usize>> {
    let nm = members.len();
    let mut parent: Vec<usize> = (0..nm).collect();
    let (w, h) = (spec.width, spec.height);
    // Each mirror: (flip x, flip y).
    let mirrors: Vec<(bool, bool)> = [(spec.symmetry.x, (true, false)), (spec.symmetry.y, (false, true))].into_iter().filter(|m| m.0).map(|m| m.1).collect();
    if !mirrors.is_empty() {
        let index: HashMap<(usize, usize), usize> = members.iter().enumerate().map(|(k, m)| ((m.a, m.b), k)).collect();
        for &(fx, fy) in &mirrors {
            let flip = |p: [f64; 2]| [if fx { w - p[0] } else { p[0] }, if fy { h - p[1] } else { p[1] }];
            let image: Vec<Option<usize>> = nodes.iter().map(|&p| nearest(nodes, flip(p)).filter(|&(_, d)| d <= tol).map(|(i, _)| i)).collect();
            for (k, m) in members.iter().enumerate() {
                if let (Some(a), Some(b)) = (image[m.a], image[m.b])
                    && let Some(&j) = index.get(&(a.min(b), a.max(b)))
                {
                    let (rk, rj) = (find(&mut parent, k), find(&mut parent, j));
                    if rk != rj {
                        parent[rk.max(rj)] = rk.min(rj);
                    }
                }
            }
        }
    }
    let mut id: Vec<Option<usize>> = vec![None; nm];
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for k in 0..nm {
        let r = find(&mut parent, k);
        let g = *id[r].get_or_insert_with(|| {
            groups.push(Vec::new());
            groups.len() - 1
        });
        groups[g].push(k);
    }
    groups
}

// MARK: Plane-frame finite elements

struct Analysis {
    /// Stable, and every load reaches a support.
    ok: bool,
    /// Loaded nodes no grounded beam reaches.
    bad: usize,
    /// Worst fibre stress per member over the cases, MPa.
    stress: Vec<f64>,
    /// Compliance sensitivity per member times its width, summed over the cases, N·mm: axial
    /// strain energy plus three times the bending energy (bending stiffness goes as width³).
    energy: Vec<f64>,
    compliance: f64,
    max_stress: f64,
    max_disp: f64,
    /// Material volume of every present beam, mm³.
    volume: f64,
}

impl Model {
    fn analyse(&self, w: &[f64]) -> Analysis {
        let nn = self.nodes.len();
        let nm = self.members.len();
        let active = self.grounded(w);
        let mut on = vec![false; nn];
        for (k, m) in self.members.iter().enumerate() {
            if active[k] {
                on[m.a] = true;
                on[m.b] = true;
            }
        }
        let bad = (0..nn).filter(|&i| self.loaded[i] && !on[i] && !self.fixed[i].iter().all(|&f| f)).count();
        let volume = self.members.iter().zip(w).map(|(m, &wk)| m.len * wk * self.t).sum();
        let mut out = Analysis { ok: false, bad, stress: vec![0.0; nm], energy: vec![0.0; nm], compliance: 0.0, max_stress: 0.0, max_disp: 0.0, volume };
        if bad > 0 || !active.iter().any(|&a| a) {
            return out;
        }

        let nd = 3 * nn;
        let band = self.members.iter().zip(&active).filter(|(_, a)| **a).map(|(m, _)| 3 * self.rank[m.a].abs_diff(self.rank[m.b]) + 2).max().unwrap_or(2);
        let dof = |node: usize, k: usize| 3 * self.rank[node] + k;
        let mut cons = vec![false; nd];
        for i in 0..nn {
            for k in 0..3 {
                cons[dof(i, k)] = self.fixed[i][k] || !on[i];
            }
        }
        let mut kb = Band::new(nd, band);
        for (k, m) in self.members.iter().enumerate() {
            if !active[k] {
                continue;
            }
            let ke = global_k(&self.local_k(m, w[k]), m.c, m.s);
            let g = [dof(m.a, 0), dof(m.a, 1), dof(m.a, 2), dof(m.b, 0), dof(m.b, 1), dof(m.b, 2)];
            for p in 0..6 {
                for q in 0..6 {
                    if g[p] >= g[q] && !cons[g[p]] && !cons[g[q]] {
                        kb.add(g[p], g[q], ke[p][q]);
                    }
                }
            }
        }
        for (i, &c) in cons.iter().enumerate() {
            if c {
                kb.add(i, i, 1.0);
            }
        }
        if !kb.factor() {
            return out;
        }

        for case in &self.cases {
            let mut f = vec![0.0; nd];
            for &(node, force) in case {
                for (k, fk) in force.iter().enumerate() {
                    let d = dof(node, k);
                    if !cons[d] {
                        f[d] += fk;
                    }
                }
            }
            let u = kb.solve(&f);
            out.compliance += f.iter().zip(&u).map(|(a, b)| a * b).sum::<f64>();
            for i in 0..nn {
                let d = dof(i, 0);
                out.max_disp = out.max_disp.max(u[d].hypot(u[d + 1]));
            }
            for (k, m) in self.members.iter().enumerate() {
                if !active[k] {
                    continue;
                }
                let de = [u[dof(m.a, 0)], u[dof(m.a, 1)], u[dof(m.a, 2)], u[dof(m.b, 0)], u[dof(m.b, 1)], u[dof(m.b, 2)]];
                let dl = to_local(&de, m.c, m.s);
                let kl = self.local_k(m, w[k]);
                let fl: Vec<f64> = kl.iter().map(|row| row.iter().zip(&dl).map(|(a, b)| a * b).sum()).collect();
                let wk = w[k];
                let sigma = fl[0].abs() / (wk * self.t) + 6.0 * fl[2].abs().max(fl[5].abs()) / (self.t * wk * wk);
                out.stress[k] = out.stress[k].max(sigma);
                let total = 0.5 * fl.iter().zip(&dl).map(|(a, b)| a * b).sum::<f64>();
                let axial = 0.5 * fl[0] * (dl[0] - dl[3]);
                out.energy[k] += axial + 3.0 * (total - axial);
            }
        }
        if !(out.compliance.is_finite() && out.max_disp.is_finite()) {
            return out;
        }
        out.max_stress = out.stress.iter().copied().fold(0.0, f64::max);
        out.ok = true;
        out
    }

    /// Local stiffness: axial, then bending in plane (w along the section's in-plane side).
    fn local_k(&self, m: &Member, w: f64) -> [[f64; 6]; 6] {
        let l = m.len;
        let a = self.e * w * self.t / l;
        let ei = self.e * self.t * w * w * w / 12.0;
        let (b12, b6, b4, b2) = (12.0 * ei / l.powi(3), 6.0 * ei / (l * l), 4.0 * ei / l, 2.0 * ei / l);
        [
            [a, 0.0, 0.0, -a, 0.0, 0.0],
            [0.0, b12, b6, 0.0, -b12, b6],
            [0.0, b6, b4, 0.0, -b6, b2],
            [-a, 0.0, 0.0, a, 0.0, 0.0],
            [0.0, -b12, -b6, 0.0, b12, -b6],
            [0.0, b6, b2, 0.0, -b6, b4],
        ]
    }

    /// Least mass, with steep penalties for stress, the volume cap and broken load paths.
    fn objective(&self, a: &Analysis) -> f64 {
        let mass = a.volume * self.density;
        let reference = self.vol_cap * self.density;
        if !a.ok {
            return mass + reference * (200.0 + 20.0 * a.bad as f64);
        }
        // Feasibility first: any overstressed or overfull design ranks behind any feasible one.
        // Every overstressed member adds its own term, so fixing one of several still pays.
        let over: f64 = a.stress.iter().map(|&s| (s / self.allowable).max(1.0).ln()).sum();
        let stress = if over > 0.0 { 1.0 + 20.0 * over.min(10.0) } else { 0.0 };
        let v = a.volume / self.vol_cap;
        let volume = if v > 1.0 { 1.0 + 20.0 * (v - 1.0) } else { 0.0 };
        mass + reference * (stress + volume)
    }

    fn score(&self, gw: &[f64]) -> (f64, Analysis) {
        let a = self.analyse(&self.expand(gw));
        (self.objective(&a), a)
    }
}

/// Element DOFs from global (u, v, θ per end) to local (axial, transverse, θ).
fn to_local(d: &[f64; 6], c: f64, s: f64) -> [f64; 6] {
    [c * d[0] + s * d[1], -s * d[0] + c * d[1], d[2], c * d[3] + s * d[4], -s * d[3] + c * d[4], d[5]]
}

/// Tᵀ k T.
fn global_k(k: &[[f64; 6]; 6], c: f64, s: f64) -> [[f64; 6]; 6] {
    let mut t = [[0.0; 6]; 6];
    for o in [0, 3] {
        t[o][o] = c;
        t[o][o + 1] = s;
        t[o + 1][o] = -s;
        t[o + 1][o + 1] = c;
        t[o + 2][o + 2] = 1.0;
    }
    let mut kt = [[0.0; 6]; 6];
    for i in 0..6 {
        for j in 0..6 {
            kt[i][j] = (0..6).map(|r| k[i][r] * t[r][j]).sum();
        }
    }
    let mut g = [[0.0; 6]; 6];
    for i in 0..6 {
        for j in 0..6 {
            g[i][j] = (0..6).map(|r| t[r][i] * kt[r][j]).sum();
        }
    }
    g
}

/// A symmetric banded matrix, lower half stored row by row, factored in place (Cholesky).
struct Band {
    n: usize,
    b: usize,
    a: Vec<f64>,
}

impl Band {
    fn new(n: usize, b: usize) -> Self {
        let b = b.min(n.saturating_sub(1));
        Self { n, b, a: vec![0.0; n * (b + 1)] }
    }

    /// Entry (i, j), j ≤ i ≤ j + b.
    fn at(&self, i: usize, j: usize) -> usize {
        i * (self.b + 1) + self.b + j - i
    }

    fn add(&mut self, i: usize, j: usize, v: f64) {
        let k = self.at(i, j);
        self.a[k] += v;
    }

    /// False for a singular or indefinite matrix (a mechanism).
    fn factor(&mut self) -> bool {
        let diag: Vec<f64> = (0..self.n).map(|i| self.a[self.at(i, i)]).collect();
        for (i, &d) in diag.iter().enumerate() {
            let j0 = i.saturating_sub(self.b);
            for j in j0..=i {
                let k0 = j0.max(j.saturating_sub(self.b));
                let (ri, rj) = (self.at(i, k0), self.at(j, k0));
                let len = j - k0;
                let mut s = self.a[self.at(i, j)];
                for k in 0..len {
                    s -= self.a[ri + k] * self.a[rj + k];
                }
                if j == i {
                    if !(s > PIVOT * d && s.is_finite()) {
                        return false;
                    }
                    let k = self.at(i, i);
                    self.a[k] = s.sqrt();
                } else {
                    let k = self.at(i, j);
                    self.a[k] = s / self.a[self.at(j, j)];
                }
            }
        }
        true
    }

    fn solve(&self, f: &[f64]) -> Vec<f64> {
        let n = self.n;
        let mut y = f.to_vec();
        for i in 0..n {
            let k0 = i.saturating_sub(self.b);
            let row = &self.a[self.at(i, k0)..self.at(i, i)];
            let s = y[i] - row.iter().zip(&y[k0..i]).map(|(l, v)| l * v).sum::<f64>();
            y[i] = s / self.a[self.at(i, i)];
        }
        for i in (0..n).rev() {
            let end = (i + self.b + 1).min(n);
            let s = y[i] - (i + 1..end).zip(&y[i + 1..end]).map(|(k, v)| self.a[self.at(k, i)] * v).sum::<f64>();
            y[i] = s / self.a[self.at(i, i)];
        }
        y
    }
}

// MARK: Optimisation

impl Model {
    /// Optimality criteria for least compliance at the volume cap over the whole ground
    /// structure, then gradual pruning: each round removes the thinnest of the members under
    /// the narrowest allowed width and lets the rest rebalance, so material gathers into a few
    /// members instead of a haze of thin ones. Returns group widths.
    fn layout(&self) -> Vec<f64> {
        let ng = self.groups.len();
        let glen: Vec<f64> = self.groups.iter().map(|ms| ms.iter().map(|&m| self.members[m].len).sum()).collect();
        let total: f64 = glen.iter().sum();
        let tiny = 0.01 * self.min_w;
        let mut gw = vec![(self.vol_cap / (self.t * total)).clamp(tiny, self.max_w); ng];
        let mut alive = vec![true; ng];
        self.criteria(&mut gw, &alive, &glen, tiny, 50);
        for _ in 0..60 {
            let mut thin: Vec<usize> = (0..ng).filter(|&g| alive[g] && gw[g] < self.min_w).collect();
            if thin.is_empty() {
                break;
            }
            thin.sort_by(|&a, &b| gw[a].total_cmp(&gw[b]).then(a.cmp(&b)));
            let live = alive.iter().filter(|&&a| a).count();
            let mut cut = (live / 5).clamp(1, thin.len());
            let before = self.score(&gw).1.compliance;
            loop {
                let mut keep = alive.clone();
                for &g in &thin[..cut] {
                    keep[g] = false;
                }
                let trial: Vec<f64> = gw.iter().zip(&keep).map(|(&w, &k)| if k { w } else { 0.0 }).collect();
                let a = self.score(&trial).1;
                if a.ok && a.compliance <= 2.0 * before {
                    alive = keep;
                    gw = trial;
                    break;
                }
                if cut == 1 {
                    // The thinnest member matters to the frame: let it grow.
                    gw[thin[0]] = self.min_w;
                    break;
                }
                cut /= 2;
            }
            self.criteria(&mut gw, &alive, &glen, tiny, 8);
        }
        let snapped: Vec<f64> = gw.iter().zip(&alive).map(|(&w, &a)| if a { w.max(self.min_w) } else { 0.0 }).collect();
        if self.score(&snapped).1.ok {
            return snapped;
        }
        vec![self.min_w; ng]
    }

    /// Optimality-criteria updates (least compliance at the volume cap) over the live groups.
    fn criteria(&self, gw: &mut [f64], alive: &[bool], glen: &[f64], lo: f64, rounds: usize) {
        let ng = gw.len();
        let step = 0.15 * self.max_w;
        for _ in 0..rounds {
            let a = self.analyse(&self.expand(gw));
            if !a.ok {
                return;
            }
            let dens: Vec<f64> = (0..ng)
                .map(|g| if alive[g] { self.groups[g].iter().map(|&m| a.energy[m]).sum::<f64>().max(0.0) / (glen[g] * gw[g] * self.t) } else { 0.0 })
                .collect();
            let update = |lam: f64| -> Vec<f64> {
                (0..ng)
                    .map(|g| if alive[g] { (gw[g] * (dens[g] / lam).sqrt()).clamp((gw[g] - step).max(lo), (gw[g] + step).min(self.max_w)) } else { 0.0 })
                    .collect()
            };
            let (mut l1, mut l2) = (1e-40_f64, dens.iter().copied().fold(0.0, f64::max) * 1e4 + 1e-30);
            for _ in 0..80 {
                let mid = (l1 * l2).sqrt();
                let vol: f64 = update(mid).iter().zip(glen).map(|(w, l)| w * l * self.t).sum();
                if vol > self.vol_cap {
                    l1 = mid;
                } else {
                    l2 = mid;
                }
            }
            gw.copy_from_slice(&update(l2));
        }
    }

    /// Worst stress over each group's members, as a share of the allowable.
    fn ratios(&self, a: &Analysis) -> Vec<f64> {
        self.groups
            .iter()
            .map(|ms| if a.ok && self.allowable.is_finite() { ms.iter().map(|&m| a.stress[m]).fold(0.0, f64::max) / self.allowable } else { 1.0 })
            .collect()
    }

    /// (μ + λ) evolution strategy over group widths, with mutative step-size self-adaptation:
    /// each child inherits its parent's step scaled by a log-normal factor. Mutations are sparse
    /// so a child stays a frame: resize a few members, remove one, add one next to the frame, or
    /// rescale every member towards its stress limit. Returns the best widths, their objective
    /// and the best objective per generation.
    fn evolve(&self, start: &[f64], generations: usize, rng: &mut Rng) -> (Vec<f64>, f64, Vec<f64>) {
        struct One {
            gw: Vec<f64>,
            obj: f64,
            sigma: f64,
            ratio: Vec<f64>,
        }
        let eval = |gw: Vec<f64>, sigma: f64| {
            let (obj, a) = self.score(&gw);
            One { ratio: self.ratios(&a), gw, obj, sigma }
        };
        let n = start.len();
        let mut pop = vec![eval(start.to_vec(), 0.3 * self.min_w)];
        let mut history = Vec::with_capacity(generations);
        if n == 0 {
            return (pop.swap_remove(0).gw, f64::INFINITY, history);
        }
        let work = (3 * self.nodes.len()) as f64 * (self.band * self.band) as f64 * 0.5 + 1.0;
        let by_budget = (WORK_BUDGET / (generations.max(1) as f64 * work)) as usize;
        let lambda = (6 + n / 40).clamp(8, 20).min(by_budget.max(4));
        let mu = (lambda / 3).max(2);
        let tau = 0.3;

        for _ in 0..generations {
            let mut children = Vec::with_capacity(lambda);
            for _ in 0..lambda {
                let p = &pop[rng.below(pop.len())];
                let sigma = (p.sigma * (tau * rng.gauss()).exp()).clamp(0.02 * self.min_w, self.max_w);
                let mut gw = p.gw.clone();
                let active: Vec<usize> = (0..n).filter(|&g| gw[g] > 0.0).collect();
                let u = rng.uniform();
                if u < 0.45 && !active.is_empty() {
                    let hot: Vec<usize> = active.iter().copied().filter(|&g| p.ratio[g] > 0.8).collect();
                    for _ in 0..1 + rng.below(3) {
                        let pool = if !hot.is_empty() && rng.uniform() < 0.5 { &hot } else { &active };
                        let g = pool[rng.below(pool.len())];
                        gw[g] = self.decode(gw[g] + sigma * rng.gauss());
                    }
                } else if u < 0.6 && !active.is_empty() {
                    gw[active[rng.below(active.len())]] = 0.0;
                } else if u < 0.8 {
                    let mut on = vec![false; self.nodes.len()];
                    for &g in &active {
                        for &m in &self.groups[g] {
                            on[self.members[m].a] = true;
                            on[self.members[m].b] = true;
                        }
                    }
                    let near: Vec<usize> = (0..n)
                        .filter(|&g| gw[g] <= 0.0 && (active.is_empty() || self.groups[g].iter().any(|&m| on[self.members[m].a] || on[self.members[m].b])))
                        .collect();
                    if !near.is_empty() {
                        gw[near[rng.below(near.len())]] = (self.min_w + sigma * rng.gauss().abs()).min(self.max_w);
                    }
                } else if self.allowable.is_finite() {
                    let power = 0.5 * rng.uniform();
                    for &g in &active {
                        gw[g] = (gw[g] * (p.ratio[g] / 0.97).max(1e-3).powf(power)).clamp(self.min_w, self.max_w);
                    }
                }
                children.push(eval(gw, sigma));
            }
            pop.extend(children);
            pop.sort_by(|a, b| a.obj.total_cmp(&b.obj));
            pop.truncate(mu);
            history.push(pop[0].obj);
        }
        let best = pop.swap_remove(0);
        (best.gw, best.obj, history)
    }

    /// Fully stressed resizing, then greedy pruning of members the frame does without, then
    /// resizing again. Only improvements are kept.
    fn polish(&self, gw: &mut [f64], mut obj: f64) -> f64 {
        obj = self.resize(gw, obj, 15);
        obj = self.tune(gw, obj, 15);
        let a = self.score(gw).1;
        if a.ok {
            let mut order: Vec<(f64, usize)> = (0..gw.len())
                .filter(|&g| gw[g] > 0.0)
                .map(|g| (self.groups[g].iter().map(|&m| a.stress[m]).fold(0.0, f64::max), g))
                .collect();
            order.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)));
            for (_, g) in order {
                let keep = gw[g];
                gw[g] = 0.0;
                let o = self.score(gw).0;
                if o < obj {
                    obj = o;
                } else {
                    gw[g] = keep;
                }
            }
        }
        obj = self.resize(gw, obj, 10);
        self.tune(gw, obj, 10)
    }

    /// Coordinate descent on the most stressed members: each round tries each of them thinner
    /// then thicker and keeps the first improvement. In a rigid frame, bending a member is made
    /// to follow eases when it gets thinner, so stress does not always call for more width.
    fn tune(&self, gw: &mut [f64], mut obj: f64, rounds: usize) -> f64 {
        for _ in 0..rounds {
            let a = self.score(gw).1;
            if !a.ok {
                break;
            }
            let ratio = self.ratios(&a);
            let mut hot: Vec<usize> = (0..gw.len()).filter(|&g| gw[g] > 0.0).collect();
            hot.sort_by(|&a, &b| ratio[b].total_cmp(&ratio[a]).then(a.cmp(&b)));
            hot.truncate(6);
            let mut improved = false;
            'search: for &g in &hot {
                for f in [0.8, 1.25] {
                    let keep = gw[g];
                    gw[g] = self.decode(keep * f).max(if f > 1.0 { self.min_w } else { 0.0 });
                    let o = self.score(gw).0;
                    if o < obj {
                        obj = o;
                        improved = true;
                        break 'search;
                    }
                    gw[g] = keep;
                }
            }
            if !improved {
                break;
            }
        }
        obj
    }

    /// Scales each group's width towards its stress limit; halves the step when it fails.
    fn resize(&self, gw: &mut [f64], mut obj: f64, rounds: usize) -> f64 {
        if !self.allowable.is_finite() {
            return obj;
        }
        let target = 0.97 * self.allowable;
        let mut power = 0.5;
        for _ in 0..rounds {
            let a = self.score(gw).1;
            if !a.ok {
                break;
            }
            let trial: Vec<f64> = gw
                .iter()
                .enumerate()
                .map(|(g, &w)| {
                    if w <= 0.0 {
                        return 0.0;
                    }
                    let s = self.groups[g].iter().map(|&m| a.stress[m]).fold(0.0, f64::max);
                    (w * (s / target).max(1e-3).powf(power)).clamp(self.min_w, self.max_w)
                })
                .collect();
            let o = self.score(&trial).0;
            if o < obj {
                obj = o;
                gw.copy_from_slice(&trial);
            } else {
                power *= 0.5;
                if power < 0.05 {
                    break;
                }
            }
        }
        obj
    }

    /// Drops groups whose every beam dangles (a free, unloaded end) or floats off the supports.
    fn cleanup(&self, gw: &mut [f64]) {
        loop {
            let w = self.expand(gw);
            let active = self.grounded(&w);
            let mut degree = vec![0usize; self.nodes.len()];
            for (k, m) in self.members.iter().enumerate() {
                if active[k] {
                    degree[m.a] += 1;
                    degree[m.b] += 1;
                }
            }
            let free_end = |i: usize| degree[i] == 1 && !self.loaded[i] && !self.fixed[i].iter().any(|&f| f);
            let useless = |k: usize| !active[k] || free_end(self.members[k].a) || free_end(self.members[k].b);
            let mut changed = false;
            for (g, ms) in self.groups.iter().enumerate() {
                if gw[g] > 0.0 && ms.iter().all(|&k| useless(k)) {
                    gw[g] = 0.0;
                    changed = true;
                }
            }
            if !changed {
                return;
            }
        }
    }

    /// The kept beams on re-indexed nodes, and their figures.
    fn finish(&self, gw: &[f64], history: Vec<f64>) -> Result<Solved, String> {
        let w = self.expand(gw);
        let active = self.grounded(&w);
        let w: Vec<f64> = w.iter().zip(&active).map(|(&wk, &a)| if a { wk } else { 0.0 }).collect();
        let a = self.analyse(&w);
        if !a.ok {
            return Err("no stable frame carries every load to a support: check the supports, loads and keep-out regions".into());
        }
        let mut index = vec![usize::MAX; self.nodes.len()];
        let mut nodes = Vec::new();
        let mut beams = Vec::new();
        let mut area = 0.0;
        for (k, m) in self.members.iter().enumerate() {
            if w[k] <= 0.0 {
                continue;
            }
            for i in [m.a, m.b] {
                if index[i] == usize::MAX {
                    index[i] = nodes.len();
                    nodes.push(self.nodes[i]);
                }
            }
            beams.push(Beam { a: index[m.a], b: index[m.b], width: w[k] });
            area += m.len * w[k];
        }
        Ok(Solved {
            shape: Shape::Frame { nodes, beams },
            compliance: a.compliance,
            max_stress: a.max_stress,
            max_displacement: a.max_disp,
            volume_fraction: area / (self.width * self.height),
            history,
        })
    }
}

// MARK: Helpers

/// splitmix64, with Box-Muller normals.
struct Rng {
    state: u64,
    spare: Option<f64>,
}

impl Rng {
    fn new(seed: u64) -> Self {
        Self { state: seed ^ 0x5DEE_CE66_D1CE_4E5B, spare: None }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform index below `n` (n > 0).
    fn below(&mut self, n: usize) -> usize {
        ((self.uniform() * n as f64) as usize).min(n - 1)
    }

    fn uniform(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn gauss(&mut self) -> f64 {
        if let Some(g) = self.spare.take() {
            return g;
        }
        let r = (-2.0 * self.uniform().max(1e-300).ln()).sqrt();
        let a = std::f64::consts::TAU * self.uniform();
        self.spare = Some(r * a.sin());
        r * a.cos()
    }
}

fn find(parent: &mut [usize], mut i: usize) -> usize {
    while parent[i] != i {
        parent[i] = parent[parent[i]];
        i = parent[i];
    }
    i
}

/// The nearest node and its distance.
fn nearest(nodes: &[[f64; 2]], p: [f64; 2]) -> Option<(usize, f64)> {
    nodes.iter().enumerate().map(|(i, q)| (i, (q[0] - p[0]).hypot(q[1] - p[1]))).min_by(|a, b| a.1.total_cmp(&b.1))
}

/// Whether `p` lies on the segment's interior, within `tol`.
fn passes_near(a: [f64; 2], b: [f64; 2], len: f64, p: [f64; 2], tol: f64) -> bool {
    let d = [(b[0] - a[0]) / len, (b[1] - a[1]) / len];
    let r = [p[0] - a[0], p[1] - a[1]];
    let along = r[0] * d[0] + r[1] * d[1];
    along > tol && along < len - tol && (r[0] * d[1] - r[1] * d[0]).abs() < tol
}

fn inflated_contains(r: &Region, p: [f64; 2], m: f64) -> bool {
    match *r {
        Region::Circle { center, radius } => (p[0] - center[0]).hypot(p[1] - center[1]) <= radius + m,
        Region::Rect { min, max } => p[0] >= min[0] - m && p[0] <= max[0] + m && p[1] >= min[1] - m && p[1] <= max[1] + m,
    }
}

/// Whether segment ab touches the region grown by `m`.
fn segment_hits(r: &Region, a: [f64; 2], b: [f64; 2], m: f64) -> bool {
    match *r {
        Region::Circle { center, radius } => segment_distance(a, b, center) <= radius + m,
        Region::Rect { min, max } => {
            // Liang-Barsky clipping against the grown box.
            let (lo, hi) = ([min[0] - m, min[1] - m], [max[0] + m, max[1] + m]);
            let (mut t0, mut t1) = (0.0_f64, 1.0_f64);
            for k in 0..2 {
                let d = b[k] - a[k];
                if d.abs() < 1e-12 {
                    if a[k] < lo[k] || a[k] > hi[k] {
                        return false;
                    }
                } else {
                    let (ta, tb) = ((lo[k] - a[k]) / d, (hi[k] - a[k]) / d);
                    t0 = t0.max(ta.min(tb));
                    t1 = t1.min(ta.max(tb));
                    if t0 > t1 {
                        return false;
                    }
                }
            }
            true
        }
    }
}

fn segment_distance(a: [f64; 2], b: [f64; 2], p: [f64; 2]) -> f64 {
    let d = [b[0] - a[0], b[1] - a[1]];
    let l2 = d[0] * d[0] + d[1] * d[1];
    let t = if l2 > 0.0 { (((p[0] - a[0]) * d[0] + (p[1] - a[1]) * d[1]) / l2).clamp(0.0, 1.0) } else { 0.0 };
    (a[0] + t * d[0] - p[0]).hypot(a[1] + t * d[1] - p[1])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Load, LoadCase, Method, Support, Symmetry};

    fn cantilever() -> Spec {
        Spec {
            method: Method::Frame,
            supports: vec![Support { region: Region::Rect { min: [0.0, 0.0], max: [1.0, 40.0] }, fix: Fix::All }],
            cases: vec![LoadCase { name: "tip".into(), loads: vec![Load { region: Region::Circle { center: [120.0, 20.0], radius: 2.0 }, force: [0.0, -500.0] }] }],
            ..Spec::default()
        }
    }

    fn frame(s: &Solved) -> (&[[f64; 2]], &[Beam]) {
        match &s.shape {
            Shape::Frame { nodes, beams } => (nodes, beams),
            _ => panic!("not a frame"),
        }
    }

    /// Every beam reaches a support node through the kept beams.
    fn connected(nodes: &[[f64; 2]], beams: &[Beam], support: &Region) -> bool {
        let mut parent: Vec<usize> = (0..nodes.len()).collect();
        for b in beams {
            let (ra, rb) = (find(&mut parent, b.a), find(&mut parent, b.b));
            parent[ra] = rb;
        }
        let roots: Vec<usize> = (0..nodes.len()).filter(|&i| support.contains(nodes[i])).map(|i| find(&mut parent, i)).collect();
        beams.iter().all(|b| roots.contains(&find(&mut parent, b.a)))
    }

    #[test]
    fn frame_cantilever_is_connected_and_within_allowable() {
        let spec = cantilever();
        let t0 = std::time::Instant::now();
        let s = solve(&spec, 1).expect("solves");
        eprintln!(
            "cantilever: {:?}, stress {:.1} MPa, disp {:.3} mm, vf {:.3}, compliance {:.1}, beams {}, history {:.2} -> {:.2}",
            t0.elapsed(),
            s.max_stress,
            s.max_displacement,
            s.volume_fraction,
            s.compliance,
            frame(&s).1.len(),
            s.history.first().copied().unwrap_or(0.0),
            s.history.last().copied().unwrap_or(0.0),
        );
        let (nodes, beams) = frame(&s);
        assert!(!beams.is_empty());
        assert!(beams.iter().all(|b| b.width >= spec.min_member && b.a < nodes.len() && b.b < nodes.len()));
        assert!(connected(nodes, beams, &spec.supports[0].region));
        assert!(nodes.iter().any(|p| (p[0] - 120.0).hypot(p[1] - 20.0) < 2.0), "the load node is in the frame");
        assert!(s.max_stress <= spec.material.allowable, "stress {}", s.max_stress);
        assert!(s.volume_fraction <= spec.volume_fraction + 1e-9);
        assert!(s.compliance > 0.0 && s.max_displacement > 0.0);
        assert_eq!(s.history.len(), spec.iterations);
        assert!(s.history.windows(2).all(|w| w[1] <= w[0]));
    }

    #[test]
    fn frame_is_deterministic() {
        let spec = cantilever();
        assert_eq!(solve(&spec, 7).unwrap(), solve(&spec, 7).unwrap());
    }

    #[test]
    fn frame_keeps_out() {
        let hole = Region::Circle { center: [60.0, 20.0], radius: 10.0 };
        let spec = Spec { keep_out: vec![hole], ..cantilever() };
        let s = solve(&spec, 3).expect("solves");
        let (nodes, beams) = frame(&s);
        assert!(s.max_stress <= spec.material.allowable, "stress {}", s.max_stress);
        let Region::Circle { center, radius } = hole else { unreachable!() };
        for b in beams {
            assert!(segment_distance(nodes[b.a], nodes[b.b], center) > radius, "beam {b:?} crosses the hole");
        }
    }

    #[test]
    fn frame_respects_symmetry() {
        let spec = Spec {
            method: Method::Frame,
            supports: vec![
                Support { region: Region::Rect { min: [0.0, 0.0], max: [2.0, 2.0] }, fix: Fix::All },
                Support { region: Region::Rect { min: [118.0, 0.0], max: [120.0, 2.0] }, fix: Fix::All },
            ],
            cases: vec![LoadCase { name: "mid".into(), loads: vec![Load { region: Region::Circle { center: [60.0, 40.0], radius: 2.0 }, force: [0.0, -800.0] }] }],
            symmetry: Symmetry { x: true, y: false },
            ..Spec::default()
        };
        let s = solve(&spec, 5).expect("solves");
        let (nodes, beams) = frame(&s);
        assert!(!beams.is_empty());
        let close = |p: [f64; 2], q: [f64; 2]| (p[0] - q[0]).hypot(p[1] - q[1]) < 1e-6;
        for b in beams {
            let (ma, mb) = ([120.0 - nodes[b.a][0], nodes[b.a][1]], [120.0 - nodes[b.b][0], nodes[b.b][1]]);
            let twin = beams.iter().find(|c| (close(nodes[c.a], ma) && close(nodes[c.b], mb)) || (close(nodes[c.a], mb) && close(nodes[c.b], ma)));
            let twin = twin.unwrap_or_else(|| panic!("beam {b:?} has no mirror twin"));
            assert!((twin.width - b.width).abs() < 1e-9);
        }
    }

    #[test]
    fn frame_refuses_an_empty_ground_structure() {
        let spec = Spec { keep_out: vec![Region::Rect { min: [-1.0, -1.0], max: [121.0, 41.0] }], ..cantilever() };
        assert!(solve(&spec, 1).is_err());
    }
}

#[cfg(test)]
mod fe {
    use super::*;
    #[test]
    fn frame_beam_matches_closed_form() {
        // One beam along x, root clamped, tip loaded.
        let spec = Spec {
            method: crate::spec::Method::Frame,
            width: 100.0,
            height: 100.0,
            resolution: 100.0,
            supports: vec![crate::spec::Support { region: Region::Rect { min: [0.0, 0.0], max: [0.0, 0.0] }, fix: Fix::All }],
            cases: vec![crate::spec::LoadCase { name: "tip".into(), loads: vec![crate::spec::Load { region: Region::Rect { min: [100.0, 0.0], max: [100.0, 0.0] }, force: [0.0, -100.0] }] }],
            ..Spec::default()
        };
        let m = Model::build(&spec).unwrap();
        let w: Vec<f64> = m.members.iter().map(|mm| if m.nodes[mm.a][1] == 0.0 && m.nodes[mm.b][1] == 0.0 { 10.0 } else { 0.0 }).collect();
        let a = m.analyse(&w);
        // σ = 6PL / (t w²) = 100 MPa, δ = PL³ / (3EI) = 0.966 mm.
        assert!(a.ok);
        assert!((a.max_stress - 100.0).abs() < 1e-6, "stress {}", a.max_stress);
        assert!((a.max_disp - 100.0 * 1e6 / (3.0 * 69_000.0 * 500.0)).abs() < 1e-9, "disp {}", a.max_disp);
    }
}
