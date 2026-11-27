//! The frame's finite-element model: supports and loads on the ground structure's nodes, the
//! assembled stiffness factored once per design, static responses per load case, and the
//! aggregated stress (and displacement) limit with its adjoint sensitivity to every diameter.

use rayon::prelude::*;

use super::beam::{self, Elastic, Line, V3, norm, scale};
use super::solver::{Block, Factor, Symbolic};

/// The ground structure with its supports and loads, in its own numbering; every model is a
/// subset of its beams.
pub struct Setup {
    pub nodes: Vec<V3>,
    pub beams: Vec<[usize; 2]>,
    pub group: Vec<usize>,
    pub groups: usize,
    /// Per group: the largest diameter allowed (keep-out clearance and the bound), mm.
    pub cap: Vec<f64>,
    /// Per node: the largest joint radius its keep-out clearance allows, mm.
    pub joint_cap: Vec<f64>,
    /// Per degree of freedom (6 per node): held.
    pub fixed: Vec<bool>,
    /// Per case: applied nodal forces and moments (6 per node), N and N·mm.
    pub loads: Vec<Vec<f64>>,
    /// Per case: body acceleration, mm/s².
    pub accel: Vec<Option<V3>>,
    pub weight: Vec<f64>,
}

impl Setup {
    pub fn loaded(&self, v: usize) -> bool {
        self.loads.iter().any(|l| l[6 * v..6 * v + 6].iter().any(|&x| x != 0.0))
    }

    pub fn supported(&self, v: usize) -> bool {
        self.fixed[6 * v..6 * v + 6].iter().any(|&f| f)
    }
}

/// A connected, supported subset of the setup's beams, ready to analyse.
pub struct Model {
    pub nodes: Vec<V3>,
    /// Per node: its index in the setup.
    pub origin: Vec<usize>,
    /// Per beam: its index in the setup.
    pub beams: Vec<usize>,
    pub ends: Vec<[usize; 2]>,
    pub lines: Vec<Line>,
    pub group: Vec<usize>,
    pub fixed: Vec<bool>,
    pub loads: Vec<Vec<f64>>,
    pub accel: Vec<Option<V3>>,
    pub weight: Vec<f64>,
    pub el: Elastic,
    /// Mass density, t/mm³.
    pub rho: f64,
    sym: Symbolic,
}

/// What one design does under every case.
pub struct Response {
    /// Per case: nodal displacements and rotations, 6 per node.
    pub u: Vec<Vec<f64>>,
    /// Per case, per beam: von Mises at both ends, MPa.
    pub stress: Vec<Vec<[f64; 2]>>,
    /// Per case: work of the loads, `fᵀu`, N·mm.
    pub compliance: Vec<f64>,
}

impl Response {
    /// Per case: the largest nodal displacement, mm.
    pub fn displacement(&self) -> Vec<f64> {
        self.u.iter().map(|u| u.chunks(6).map(|c| norm([c[0], c[1], c[2]])).fold(0.0, f64::max)).collect()
    }

    /// Per beam: the worst stress over its ends and the cases.
    pub fn beam_stress(&self) -> Vec<f64> {
        let beams = self.stress.first().map_or(0, Vec::len);
        (0..beams).map(|e| self.stress.iter().map(|c| c[e][0].max(c[e][1])).fold(0.0, f64::max)).collect()
    }
}

/// The limits the aggregate holds, and how it relaxes the stress of vanishing beams.
pub struct Limits {
    pub stress: f64,
    pub displacement: Option<f64>,
    /// Exponent of the p-norm.
    pub p: f64,
    /// A beam's stress counts nothing at `d_lo` and fully from `d_cut` up (smoothstep between),
    /// so a beam on its way out does not hold the rest up.
    pub d_lo: f64,
    pub d_cut: f64,
}

impl Limits {
    fn relax(&self, d: f64) -> (f64, f64) {
        let w = self.d_cut - self.d_lo;
        let t = ((d - self.d_lo) / w).clamp(0.0, 1.0);
        (t * t * (3.0 - 2.0 * t), if t > 0.0 && t < 1.0 { 6.0 * t * (1.0 - t) / w } else { 0.0 })
    }
}

/// The p-norm of every relaxed stress ratio (and displacement ratio), its true maximum and its
/// gradient per beam.
pub struct Aggregate {
    pub value: f64,
    pub max: f64,
    pub grad: Vec<f64>,
}

impl Model {
    /// The model of the setup's beams marked in `keep`: nodes they reach, components holding no
    /// applied load dropped. Fails when a load cannot reach a support.
    pub fn new(setup: &Setup, keep: &[bool], el: Elastic, rho: f64) -> Result<Self, String> {
        let n = setup.nodes.len();
        let mut adj: Vec<Vec<usize>> = vec![Vec::new(); n];
        for (e, &[a, b]) in setup.beams.iter().enumerate() {
            if keep[e] {
                adj[a].push(b);
                adj[b].push(a);
            }
        }
        let mut comp = vec![usize::MAX; n];
        let mut useful = Vec::new();
        let mut support = Vec::new();
        for s in 0..n {
            if comp[s] != usize::MAX || adj[s].is_empty() {
                continue;
            }
            let c = useful.len();
            comp[s] = c;
            let mut stack = vec![s];
            let (mut loaded, mut supported) = (false, false);
            while let Some(v) = stack.pop() {
                loaded |= setup.loaded(v);
                supported |= setup.supported(v);
                for &w in &adj[v] {
                    if comp[w] == usize::MAX {
                        comp[w] = c;
                        stack.push(w);
                    }
                }
            }
            if loaded && !supported {
                let p = setup.nodes[s];
                return Err(format!("a load near ({:.1}, {:.1}, {:.1}) mm reaches no support through the design space", p[0], p[1], p[2]));
            }
            useful.push(loaded && supported);
            support.push(supported);
        }
        // A mirror image of a loaded component stays too (its beams share diameters), when held.
        let mut shared = vec![false; setup.groups];
        for (e, &[a, _]) in setup.beams.iter().enumerate() {
            if keep[e] && useful[comp[a]] {
                shared[setup.group[e]] = true;
            }
        }
        for (e, &[a, _]) in setup.beams.iter().enumerate() {
            if keep[e] && shared[setup.group[e]] && support[comp[a]] {
                useful[comp[a]] = true;
            }
        }
        let mut index = vec![usize::MAX; n];
        let mut origin = Vec::new();
        let (mut beams, mut ends, mut lines, mut group) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for (e, &[a, b]) in setup.beams.iter().enumerate() {
            if !keep[e] || !useful[comp[a]] {
                continue;
            }
            for v in [a, b] {
                if index[v] == usize::MAX {
                    index[v] = origin.len();
                    origin.push(v);
                }
            }
            beams.push(e);
            ends.push([index[a], index[b]]);
            lines.push(Line::new(setup.nodes[a], setup.nodes[b]));
            group.push(setup.group[e]);
        }
        if beams.is_empty() {
            return Err("no beam carries a load to a support".into());
        }
        let nodes: Vec<V3> = origin.iter().map(|&v| setup.nodes[v]).collect();
        let pick = |src: &[f64]| -> Vec<f64> { origin.iter().flat_map(|&v| src[6 * v..6 * v + 6].iter().copied()).collect() };
        let fixed: Vec<bool> = origin.iter().flat_map(|&v| setup.fixed[6 * v..6 * v + 6].iter().copied()).collect();
        let mut loads: Vec<Vec<f64>> = setup.loads.iter().map(|l| pick(l)).collect();
        for l in &mut loads {
            for (x, &f) in l.iter_mut().zip(&fixed) {
                if f {
                    *x = 0.0;
                }
            }
        }
        let sym = Symbolic::new(&nodes, &ends);
        Ok(Self { nodes, origin, beams, ends, lines, group, fixed, loads, accel: setup.accel.clone(), weight: setup.weight.clone(), el, rho, sym })
    }

    pub fn dofs(&self) -> usize {
        6 * self.nodes.len()
    }

    /// Beam `e`'s twelve end values out of a global vector.
    pub fn gather(&self, e: usize, u: &[f64]) -> [f64; 12] {
        let [a, b] = self.ends[e];
        std::array::from_fn(|i| if i < 6 { u[6 * a + i] } else { u[6 * b + i - 6] })
    }

    fn scatter(&self, e: usize, v: &[f64; 12], out: &mut [f64]) {
        let [a, b] = self.ends[e];
        for i in 0..6 {
            out[6 * a + i] += v[i];
            out[6 * b + i] += v[6 + i];
        }
    }

    /// Equivalent end loads of the beam's own weight under the case's acceleration.
    fn weight_load(&self, case: usize, e: usize, d: f64) -> Option<[f64; 12]> {
        self.accel[case].map(|a| beam::line_load(&self.lines[e], scale(a, self.rho * beam::area(d))))
    }

    /// End actions of beam `e` (forces the nodes put on it): `K u - q`.
    pub fn end_actions(&self, case: usize, e: usize, d: f64, u: &[f64]) -> [f64; 12] {
        let mut f = beam::actions(&self.lines[e], &self.el, d, &self.gather(e, u));
        if let Some(q) = self.weight_load(case, e, d) {
            for (x, y) in f.iter_mut().zip(q) {
                *x -= y;
            }
        }
        f
    }

    fn load_vector(&self, case: usize, d: &[f64]) -> Vec<f64> {
        let mut f = self.loads[case].clone();
        if self.accel[case].is_some() {
            for e in 0..self.ends.len() {
                if let Some(q) = self.weight_load(case, e, d[e]) {
                    self.scatter(e, &q, &mut f);
                }
            }
            for (x, &h) in f.iter_mut().zip(&self.fixed) {
                if h {
                    *x = 0.0;
                }
            }
        }
        f
    }

    /// Factors the stiffness for diameters `d` (per beam) and solves every case.
    pub fn analyse(&self, d: &[f64]) -> Result<(Response, Factor), String> {
        let blocks: Vec<[Block; 4]> = (0..self.ends.len())
            .into_par_iter()
            .map(|e| {
                let k = beam::stiffness(&self.lines[e], &self.el, d[e]);
                let block = |r0: usize, c0: usize| -> Block { std::array::from_fn(|i| k[r0 + i / 6][c0 + i % 6]) };
                [block(0, 0), block(0, 6), block(6, 0), block(6, 6)]
            })
            .collect();
        let factor = self.sym.factor(&blocks, &self.ends, &self.fixed).map_err(|v| {
            let p = self.nodes[v];
            format!("the frame is free to move near ({:.1}, {:.1}, {:.1}) mm: the supports do not hold it (fix all three axes of a support, or add supports)", p[0], p[1], p[2])
        })?;
        let solved: Vec<(Vec<f64>, f64)> = (0..self.loads.len())
            .into_par_iter()
            .map(|c| {
                let f = self.load_vector(c, d);
                let mut u = f.clone();
                self.sym.solve(&factor, &mut u);
                let work = dot_all(&f, &u);
                (u, work)
            })
            .collect();
        let (u, compliance): (Vec<Vec<f64>>, Vec<f64>) = solved.into_iter().unzip();
        let stress = u
            .iter()
            .enumerate()
            .map(|(c, uc)| {
                (0..self.ends.len())
                    .into_par_iter()
                    .map(|e| {
                        let f = self.end_actions(c, e, d[e], uc);
                        let n = self.lines[e].n;
                        let at = |i: usize| beam::von_mises(n, d[e], [f[6 * i], f[6 * i + 1], f[6 * i + 2]], [f[6 * i + 3], f[6 * i + 4], f[6 * i + 5]]);
                        [at(0), at(1)]
                    })
                    .collect()
            })
            .collect();
        Ok((Response { u, stress, compliance }, factor))
    }

    /// The aggregate of the relaxed stress ratios (both ends of every beam, every case) and the
    /// displacement ratios, and its gradient per beam by the adjoint method.
    pub fn aggregate(&self, d: &[f64], resp: &Response, factor: &Factor, lim: &Limits) -> Aggregate {
        let eps = 1e-6 * lim.stress;
        let beams = self.ends.len();
        struct End {
            r: [f64; 2],
            /// ∂r/∂(end actions) per end.
            da: [[f64; 12]; 2],
            /// ∂r/∂d, end actions held.
            dd: [f64; 2],
        }
        let ends: Vec<Vec<End>> = resp
            .u
            .iter()
            .enumerate()
            .map(|(c, uc)| {
                (0..beams)
                    .into_par_iter()
                    .map(|e| {
                        let f = self.end_actions(c, e, d[e], uc);
                        let n = self.lines[e].n;
                        let (phi, dphi) = lim.relax(d[e]);
                        let mut out = End { r: [0.0; 2], da: [[0.0; 12]; 2], dd: [0.0; 2] };
                        for i in 0..2 {
                            let s = beam::end_stress(n, d[e], [f[6 * i], f[6 * i + 1], f[6 * i + 2]], [f[6 * i + 3], f[6 * i + 4], f[6 * i + 5]], eps);
                            out.r[i] = phi * s.s / lim.stress;
                            for a in 0..3 {
                                out.da[i][6 * i + a] = phi * s.df[a] / lim.stress;
                                out.da[i][6 * i + 3 + a] = phi * s.dm[a] / lim.stress;
                            }
                            out.dd[i] = (dphi * s.s + phi * s.dd) / lim.stress;
                        }
                        out
                    })
                    .collect()
            })
            .collect();
        let disp: Vec<Vec<f64>> = match lim.displacement {
            Some(limit) => resp.u.iter().map(|u| u.chunks(6).map(|c| (c[0] * c[0] + c[1] * c[1] + c[2] * c[2] + (1e-9 * limit).powi(2)).sqrt() / limit).collect()).collect(),
            None => Vec::new(),
        };

        let max = ends.iter().flatten().flat_map(|x| x.r).chain(disp.iter().flatten().copied()).fold(0.0, f64::max);
        if max <= 0.0 {
            return Aggregate { value: 0.0, max: 0.0, grad: vec![0.0; beams] };
        }
        let sum: f64 = ends.iter().flatten().flat_map(|x| x.r).chain(disp.iter().flatten().copied()).map(|r| (r / max).powf(lim.p)).sum();
        let value = max * sum.powf(1.0 / lim.p);
        let weight = |r: f64| (r / value).powf(lim.p - 1.0);

        let per_case: Vec<Vec<f64>> = (0..resp.u.len())
            .into_par_iter()
            .map(|c| {
                let uc = &resp.u[c];
                let gf: Vec<[f64; 12]> = ends[c].iter().map(|x| std::array::from_fn(|i| weight(x.r[0]) * x.da[0][i] + weight(x.r[1]) * x.da[1][i])).collect();
                let mut rhs = vec![0.0; self.dofs()];
                for (e, g) in gf.iter().enumerate() {
                    let kg = beam::actions(&self.lines[e], &self.el, d[e], g);
                    self.scatter(e, &kg, &mut rhs);
                }
                if let Some(limit) = lim.displacement {
                    for (v, &w) in disp[c].iter().enumerate() {
                        let k = weight(w) / (w * limit * limit);
                        for a in 0..3 {
                            rhs[6 * v + a] += k * uc[6 * v + a];
                        }
                    }
                }
                for (x, &h) in rhs.iter_mut().zip(&self.fixed) {
                    if h {
                        *x = 0.0;
                    }
                }
                let mut lambda = rhs;
                self.sym.solve(factor, &mut lambda);
                (0..beams)
                    .map(|e| {
                        let x = &ends[c][e];
                        let mut rate = beam::actions_rate(&self.lines[e], &self.el, d[e], &self.gather(e, uc));
                        if let Some(q) = self.weight_load(c, e, d[e]) {
                            for (r, qi) in rate.iter_mut().zip(q) {
                                *r -= 2.0 * qi / d[e];
                            }
                        }
                        let l = self.gather(e, &lambda);
                        let adj: f64 = (0..12).map(|i| (gf[e][i] - l[i]) * rate[i]).sum();
                        weight(x.r[0]) * x.dd[0] + weight(x.r[1]) * x.dd[1] + adj
                    })
                    .collect()
            })
            .collect();
        let mut grad = vec![0.0; beams];
        for g in &per_case {
            for (x, y) in grad.iter_mut().zip(g) {
                *x += y;
            }
        }
        Aggregate { value, max, grad }
    }
}

fn dot_all(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}
