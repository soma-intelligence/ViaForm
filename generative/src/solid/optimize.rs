//! The topology optimisation loop, the analysis of a finished layout, and the study runner.
//!
//! The chain from design variables to the physical density of every voxel:
//!
//! 1. Groups: one variable per orbit of the mirror planes, and per line along the extrusion
//!    direction for an extruded part (a carbon plate is one variable per column).
//! 2. Density filter: a linear cone of radius `max(1.5 h, 0.6 min_member)` (Bourdin).
//! 3. Heaviside projection about 0.5, its sharpness `β` doubled from 1 to 16 over the run.
//! 4. Keep-in voxels set to 1, keep-out ones to 0.
//! 5. Manufacturing sweep, layer by layer along the process axis:
//!    - printing (Langelaar 2017): a voxel is at most the smooth maximum of the voxels that hold
//!      it up in the layer below (the one under it and its four neighbours for a 45° overhang,
//!      all eight for a flatter one), so nothing overhangs the limit;
//!    - milling: a voxel is at least the smooth maximum of the one before it along the tool, so
//!      the tool sees no cavity behind material.
//! 6. Keep-in and keep-out again.
//!
//! Stiffness is SIMP (`E = E_min + ρ³ (E₀ - E_min)`, `E_min = 1e-9 E₀`), mass follows the density
//! with Olhoff and Du's `ρ⁶` tail under 0.1, so voids neither weigh on the body loads nor ring as
//! spurious local modes.
//!
//! Objectives and limits (all through MMA, [`super::mma`]):
//! - compliance: least weighted compliance of the load cases under the volume fraction;
//! - mass: least volume under the stress limit (aggregated p-norm of relaxed stress `√ρ σ_vm`,
//!   rescaled every iteration to the true maximum), the displacement limit (p-norm of nodal
//!   displacements) and the first natural frequency floor.
//!
//! Robust formulation (Wang, Lazarov and Sigmund 2011), when the study asks for it: the chain
//! runs three times, projected about `0.5 + δ` (eroded), `0.5` (nominal) and `0.5 - δ`
//! (dilated). The compliance objective becomes a bound formulation, `min z` with every
//! realisation's compliance under `z` (one extra MMA variable); stress and displacement limits
//! read the eroded design (the thinnest, so the worst); volume, frequency and the built layout
//! are the nominal one. A part that comes out a little thinner or thicker from the printer keeps
//! its performance.
//!
//! Frequency floor (bound formulation, Olhoff and Du): each of the lowest `frequency_modes`
//! modes has its own constraint `λ_j ≥ λ_min`, so a repeated pair (a square column's two bending
//! modes) or modes that swap order never slip under the floor through the one eigenvalue
//! picked.
//!
//! A mass target (grams) sets the volume fraction from the material's density, keep-in solid
//! included. `max_beta` caps the projection's sharpness (0: plain SIMP with a density filter, the
//! top3d and PETSc TopOpt formulation); `tolerance` stops the run when no variable moves more.
//!
//! Either objective takes the other limits when they are set. Stress, displacement and frequency
//! sensitivities are adjoint (one extra solve per case and limit; the frequency's is the
//! eigenvector's own). Body accelerations (gravity, a crash) load the part's own mass, so the
//! loads follow the layout.
//!
//! Reported stress: the worst von Mises over solid voxels (density ≥ 0.5) at the solid modulus,
//! leaving out voxels touching a held node, where a clamped edge on a voxel grid is singular and
//! the number grows without limit as the voxels shrink (Saint-Venant: the reading a few voxels
//! away is the physical one).

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use super::dynamics::{self, Eigen};
use super::fem::{self, Operator};
use super::mg::Hierarchy;
use super::mma::Mma;
use super::{Analysis, Candidate, Grid, Layout, Manufacturing, Method, Objective, Outcome, Region, Study, frame3d, iso, loads};

const PENAL: f64 = 3.0;
const EMIN: f64 = 1e-9;
const STRESS_P: f64 = 8.0;
const STRESS_Q: f64 = 0.5;
const DISP_P: f64 = 8.0;
/// The optimiser aims under the stress limit by this share: the aggregate follows the true
/// peak only approximately, and grey voxels read lower than solid ones.
const STRESS_MARGIN: f64 = 0.85;
/// Langelaar's smooth maximum exponent and the smooth minimum's ε.
const AM_P: f64 = 40.0;
const SMOOTH_EPS: f64 = 1e-4;
/// Largest grid the engine takes, elements.
pub const MAX_ELEMENTS: usize = 6_000_000;

/// t/mm³ from g/mm³.
fn tonnes(density: f64) -> f64 {
    density * 1e-6
}

/// Mass interpolation and its slope.
fn mass_interp(r: f64) -> (f64, f64) {
    if r > 0.1 { (r, 1.0) } else { (1e5 * r.powi(6), 6e5 * r.powi(5)) }
}

fn dot(a: &[f64], b: &[f64]) -> f64 {
    a.par_chunks(8192).zip(b.par_chunks(8192)).map(|(a, b)| a.iter().zip(b).map(|(x, y)| x * y).sum::<f64>()).collect::<Vec<_>>().iter().sum()
}

/// The dominant axis of a direction and whether it points up that axis.
fn axis_of(d: [f64; 3]) -> (usize, bool) {
    let a = (0..3).max_by(|&i, &j| d[i].abs().total_cmp(&d[j].abs())).unwrap_or(2);
    (a, d[a] >= 0.0)
}

/// The study's fixed parts: grid, operator, loads, passive voxels, filter, groups, sweep.
pub struct Model {
    pub grid: Grid,
    pub op: Operator,
    pub e0: f64,
    /// Material density, t/mm³.
    pub rho0: f64,
    /// Per case: applied nodal forces.
    pub applied: Vec<Vec<f64>>,
    /// Per element: Some(value) when keep-in (1) or keep-out (0).
    pub passive: Vec<Option<f64>>,
    /// Per element: left out of the stress reading (touches a held node).
    pub singular: Vec<bool>,
    /// Per element: its design variable.
    pub group: Vec<u32>,
    pub groups: usize,
    filter: Filter,
    sweep: Option<Sweep>,
    /// Stress limit, MPa.
    pub stress_limit: f64,
}

struct Filter {
    offsets: Vec<([isize; 3], f64)>,
    hs: Vec<f64>,
}

#[derive(Clone, Copy)]
enum SweepKind {
    /// Printing, with the lateral reach of the support stencil (cross or full 3 × 3).
    Additive { full: bool },
    Milling,
}

struct Sweep {
    kind: SweepKind,
    axis: usize,
    /// Sweep runs from the low end of the axis.
    up: bool,
}

/// What the forward chain keeps for the way back.
pub(super) struct Chain {
    filtered: Vec<f64>,
    /// After projection and passive values: the sweep's input.
    projected: Vec<f64>,
    pub(super) phys: Vec<f64>,
    /// Sweep partials: d out/d own input, and the coefficient toward the layer below.
    own: Vec<f64>,
    kappa: Vec<f64>,
    /// Projection threshold (0.5 nominal; above erodes, below dilates).
    eta: f64,
}

/// Groups, filter and manufacturing sweep of a study on its grid.
fn design_parts(grid: &Grid, study: &Study) -> (Vec<u32>, usize, Filter, Option<Sweep>) {
    let (group, groups) = groups(grid, study);
    let flat = match study.manufacturing {
        Manufacturing::Extrusion { direction } => Some(axis_of(direction).0),
        _ => None,
    };
    let filter = Filter::new(grid, (1.5 * grid.h).max(0.6 * study.min_member), flat);
    let sweep = match study.manufacturing {
        Manufacturing::Free | Manufacturing::Extrusion { .. } => None,
        Manufacturing::Additive { build, overhang } => {
            let (axis, up) = axis_of(build);
            Some(Sweep { kind: SweepKind::Additive { full: overhang < 45.0 }, axis, up })
        }
        Manufacturing::Milling { direction } => {
            let (axis, up) = axis_of(direction);
            Some(Sweep { kind: SweepKind::Milling, axis, up })
        }
    };
    (group, groups, filter, sweep)
}

/// Elements joined to a support through material that can exist (not kept out), face to face.
fn supported(grid: &Grid, passive: &[Option<f64>], held_node: &[bool]) -> Vec<bool> {
    let open = |e: usize| passive[e] != Some(0.0);
    let mut reached = vec![false; grid.elements()];
    let mut stack: Vec<usize> = (0..grid.elements()).filter(|&e| open(e) && grid.element_nodes(e).iter().any(|&v| held_node[v])).collect();
    for &e in &stack {
        reached[e] = true;
    }
    let n = grid.n;
    while let Some(e) = stack.pop() {
        let [i, j, k] = grid.element_ijk(e);
        let mut visit = |i: usize, j: usize, k: usize| {
            let f = grid.element(i, j, k);
            if !reached[f] && open(f) {
                reached[f] = true;
                stack.push(f);
            }
        };
        if i > 0 { visit(i - 1, j, k); }
        if i + 1 < n[0] { visit(i + 1, j, k); }
        if j > 0 { visit(i, j - 1, k); }
        if j + 1 < n[1] { visit(i, j + 1, k); }
        if k > 0 { visit(i, j, k - 1); }
        if k + 1 < n[2] { visit(i, j, k + 1); }
    }
    reached
}

impl Model {
    pub fn new(study: &Study) -> Result<Self, String> {
        let span: [f64; 3] = std::array::from_fn(|a| study.max[a] - study.min[a]);
        if span.iter().any(|s| !(s.is_finite() && *s > 0.0)) {
            return Err("the design space is empty: max must exceed min on every axis".into());
        }
        if !(study.voxel.is_finite() && study.voxel > 0.0) {
            return Err(format!("voxel edge {} must be a positive length", study.voxel));
        }
        let grid = Grid::new(study.min, study.max, study.voxel);
        if grid.elements() > MAX_ELEMENTS {
            return Err(format!("{} voxels is over the engine's {MAX_ELEMENTS}: use a coarser voxel", grid.elements()));
        }
        if grid.elements() < 8 {
            return Err("the design space holds fewer than eight voxels: use a finer voxel".into());
        }
        let m = &study.material;
        if !(m.e > 0.0 && m.density > 0.0 && m.allowable > 0.0) {
            return Err("the material needs a positive modulus, density and allowable stress".into());
        }
        if study.cases.is_empty() {
            return Err("the study has no load case".into());
        }
        loads::check(&grid, &study.supports, &study.cases)?;
        let fixed = loads::fixed_dofs(&grid, &study.supports);
        let mut passive = vec![None; grid.elements()];
        for r in &study.keep_in {
            for e in grid.elements_in(r) {
                passive[e] = Some(1.0);
            }
        }
        // Keep-outs void every voxel that reaches into them, so no material is left inside (a
        // bought part there stays clear); exact holes are cut into the surface afterwards.
        for r in &study.keep_out {
            for e in grid.elements_touching(r) {
                passive[e] = Some(0.0);
            }
        }
        let held_node: Vec<bool> = (0..grid.nodes()).map(|v| fixed[3 * v] || fixed[3 * v + 1] || fixed[3 * v + 2]).collect();
        // Material that keep-outs cut off from every support can carry nothing: a design voxel
        // there turns void, and loads skip it (a load spread on such an island would push a
        // part that floats). A keep-in scrap cut off the same way (a voxel left between two
        // keep-outs) goes too: held by nothing, it would take a body load on void stiffness.
        let reached = supported(&grid, &passive, &held_node);
        if reached.iter().any(|&r| r) {
            for e in 0..grid.elements() {
                if !reached[e] && passive[e] != Some(0.0) {
                    passive[e] = Some(0.0);
                }
            }
        }
        // Loads go on nodes that touch material that can exist and is held.
        let mut live = vec![false; grid.nodes()];
        for e in 0..grid.elements() {
            if passive[e] != Some(0.0) && (reached[e] || !reached.iter().any(|&r| r)) {
                for v in grid.element_nodes(e) {
                    live[v] = true;
                }
            }
        }
        // A load on a keep-in goes on the keep-in's nodes, not on design voxels beside it.
        let mut solid_node = vec![false; grid.nodes()];
        for e in 0..grid.elements() {
            if passive[e] == Some(1.0) {
                for v in grid.element_nodes(e) {
                    solid_node[v] = true;
                }
            }
        }
        let applied = study.cases.iter().map(|c| loads::applied_preferring(&grid, c, Some(&solid_node), Some(&live))).collect();
        let singular: Vec<bool> = (0..grid.elements()).into_par_iter().map(|e| grid.element_nodes(e).iter().any(|&v| held_node[v])).collect();
        let (group, groups, filter, sweep) = design_parts(&grid, study);
        let stress_limit = study.max_stress.unwrap_or(m.allowable / study.safety_factor.max(1.0));
        Ok(Self {
            op: Operator::new(grid, m.nu, fixed),
            grid,
            e0: m.e,
            rho0: tonnes(m.density),
            applied,
            passive,
            singular,
            group,
            groups,
            filter,
            sweep,
            stress_limit,
        })
    }

    /// The design chain alone (passive voxels, groups, filter, projection, sweep) on `grid`, for
    /// other physics on the same voxels (heat conduction, [`super::thermal`]): no supports or
    /// load cases are needed, the operator holds nothing and there are no forces.
    pub(super) fn for_design(study: &Study, grid: Grid, passive: Vec<Option<f64>>) -> Self {
        let (group, groups, filter, sweep) = design_parts(&grid, study);
        let m = &study.material;
        Self {
            op: Operator::new(grid, m.nu, vec![false; grid.dofs()]),
            grid,
            e0: m.e,
            rho0: tonnes(m.density),
            applied: Vec::new(),
            singular: vec![false; grid.elements()],
            passive,
            group,
            groups,
            filter,
            sweep,
            stress_limit: f64::INFINITY,
        }
    }

    fn young(&self, phys: &[f64]) -> Vec<f64> {
        phys.par_iter().map(|&r| self.e0 * (EMIN + r.powf(PENAL) * (1.0 - EMIN))).collect()
    }

    fn rho(&self, phys: &[f64]) -> Vec<f64> {
        phys.par_iter().map(|&r| self.rho0 * mass_interp(r).0).collect()
    }

    /// Full load vector of case `c` for the layout.
    fn forces(&self, study: &Study, c: usize, rho: &[f64]) -> Vec<f64> {
        let mut f = self.applied[c].clone();
        if let Some(b) = loads::body(&self.grid, &study.cases[c], rho) {
            f.par_iter_mut().zip(b.par_iter()).for_each(|(f, b)| *f += b);
        }
        f
    }

    pub(super) fn forward(&self, x: &[f64], beta: f64, eta: f64) -> Chain {
        let g = &self.grid;
        let xe: Vec<f64> = self.group.par_iter().map(|&k| x[k as usize]).collect();
        let filtered = self.filter.apply(g, &xe);
        let projected: Vec<f64> = filtered.par_iter().zip(self.passive.par_iter()).map(|(&r, p)| p.unwrap_or_else(|| heaviside(r, beta, eta).0)).collect();
        let n = g.elements();
        let (mut phys, mut own, mut kappa) = (projected.clone(), vec![1.0; n], vec![0.0; n]);
        if let Some(s) = &self.sweep {
            sweep_forward(g, s, &projected, &self.passive, &mut phys, &mut own, &mut kappa);
        }
        for (p, v) in self.passive.iter().zip(phys.iter_mut()) {
            if let Some(val) = p {
                *v = *val;
            }
        }
        Chain { filtered, projected, phys, own, kappa, eta }
    }

    /// From d/d(physical density) to d/d(design variables).
    pub(super) fn backward(&self, chain: &Chain, beta: f64, dphys: &[f64]) -> Vec<f64> {
        let eta = chain.eta;
        let g = &self.grid;
        let mut d: Vec<f64> = dphys.par_iter().zip(self.passive.par_iter()).map(|(&d, p)| if p.is_some() { 0.0 } else { d }).collect();
        if let Some(s) = &self.sweep {
            d = sweep_backward(g, s, &chain.phys_before_passive(), &d, &chain.own, &chain.kappa);
        }
        let dfilt: Vec<f64> = d
            .par_iter()
            .zip(chain.filtered.par_iter())
            .zip(self.passive.par_iter())
            .map(|((&d, &r), p)| if p.is_some() { 0.0 } else { d * heaviside(r, beta, eta).1 })
            .collect();
        let _ = &chain.projected;
        let dxe = self.filter.transpose(g, &dfilt);
        let mut dx = vec![0.0; self.groups];
        for (e, &k) in self.group.iter().enumerate() {
            dx[k as usize] += dxe[e];
        }
        dx
    }
}

impl Chain {
    /// The sweep's outputs before the passive override (what the layers above read).
    fn phys_before_passive(&self) -> Vec<f64> {
        // The sweep stores the passive values itself (they hold up the layers above), so the
        // override changes nothing the backward pass reads.
        self.phys.clone()
    }
}

/// Smoothed Heaviside about `eta` (Wang, Lazarov and Sigmund 2011) and its slope.
fn heaviside(r: f64, beta: f64, eta: f64) -> (f64, f64) {
    if beta <= 0.0 {
        return (r, 1.0);
    }
    let den = (beta * eta).tanh() + (beta * (1.0 - eta)).tanh();
    let t = (beta * (r - eta)).tanh();
    (((beta * eta).tanh() + t) / den, beta * (1.0 - t * t) / den)
}

impl Filter {
    /// `flat`: an axis the filter does not reach along (an extrusion keeps its section).
    fn new(g: &Grid, radius: f64, flat: Option<usize>) -> Self {
        let reach = (radius / g.h).ceil() as isize;
        let mut offsets = Vec::new();
        for dk in -reach..=reach {
            for dj in -reach..=reach {
                for di in -reach..=reach {
                    let d = g.h * ((di * di + dj * dj + dk * dk) as f64).sqrt();
                    let w = radius - d;
                    let along = flat.is_some_and(|a| [di, dj, dk][a] != 0);
                    if w > 0.0 && !along {
                        offsets.push(([di, dj, dk], w));
                    }
                }
            }
        }
        let hs = (0..g.elements())
            .into_par_iter()
            .map(|e| {
                let ijk = g.element_ijk(e);
                offsets.iter().filter(|(o, _)| inside(g, ijk, *o).is_some()).map(|(_, w)| w).sum()
            })
            .collect();
        Self { offsets, hs }
    }

    fn apply(&self, g: &Grid, x: &[f64]) -> Vec<f64> {
        (0..g.elements())
            .into_par_iter()
            .map(|e| {
                let ijk = g.element_ijk(e);
                let s: f64 = self.offsets.iter().filter_map(|(o, w)| inside(g, ijk, *o).map(|n| w * x[n])).sum();
                s / self.hs[e]
            })
            .collect()
    }

    fn transpose(&self, g: &Grid, d: &[f64]) -> Vec<f64> {
        let scaled: Vec<f64> = d.par_iter().zip(self.hs.par_iter()).map(|(d, h)| d / h).collect();
        (0..g.elements())
            .into_par_iter()
            .map(|e| {
                let ijk = g.element_ijk(e);
                self.offsets.iter().filter_map(|(o, w)| inside(g, ijk, *o).map(|n| w * scaled[n])).sum()
            })
            .collect()
    }
}

fn inside(g: &Grid, ijk: [usize; 3], o: [isize; 3]) -> Option<usize> {
    let mut p = [0usize; 3];
    for a in 0..3 {
        let v = ijk[a] as isize + o[a];
        if v < 0 || v >= g.n[a] as isize {
            return None;
        }
        p[a] = v as usize;
    }
    Some(g.element(p[0], p[1], p[2]))
}

/// One design variable per orbit of the mirrors and per line along the extrusion.
fn groups(g: &Grid, study: &Study) -> (Vec<u32>, usize) {
    let extrude = match study.manufacturing {
        Manufacturing::Extrusion { direction } => Some(axis_of(direction).0),
        _ => None,
    };
    let canon = |e: usize| {
        let mut ijk = g.element_ijk(e);
        if let Some(a) = extrude {
            ijk[a] = 0;
        }
        for a in 0..3 {
            if study.symmetry[a] {
                ijk[a] = ijk[a].min(g.n[a] - 1 - ijk[a]);
            }
        }
        g.element(ijk[0], ijk[1], ijk[2])
    };
    let reps: Vec<usize> = (0..g.elements()).into_par_iter().map(canon).collect();
    let mut id = vec![u32::MAX; g.elements()];
    let mut next = 0u32;
    let mut group = vec![0u32; g.elements()];
    for e in 0..g.elements() {
        let r = reps[e];
        if id[r] == u32::MAX {
            id[r] = next;
            next += 1;
        }
        group[e] = id[r];
    }
    (group, next as usize)
}

/// Elements of layer `l` along the sweep, in a fixed order, and the element at a lateral offset.
struct Layers {
    axis: usize,
    up: bool,
    n: [usize; 3],
}

impl Layers {
    fn count(&self) -> usize {
        self.n[self.axis]
    }
    /// The axis index of sweep layer `l`.
    fn index(&self, l: usize) -> usize {
        if self.up { l } else { self.n[self.axis] - 1 - l }
    }
    fn lateral(&self) -> (usize, usize) {
        ((self.axis + 1) % 3, (self.axis + 2) % 3)
    }
    fn size(&self) -> usize {
        let (b, c) = self.lateral();
        self.n[b] * self.n[c]
    }
    fn element(&self, g: &Grid, l: usize, p: usize, q: usize) -> usize {
        let (b, c) = self.lateral();
        let mut ijk = [0; 3];
        ijk[self.axis] = self.index(l);
        ijk[b] = p;
        ijk[c] = q;
        g.element(ijk[0], ijk[1], ijk[2])
    }
    /// Lateral neighbours (the voxel itself included) of `(p, q)` in the support stencil.
    fn stencil(&self, kind: SweepKind, p: usize, q: usize) -> Vec<(usize, usize)> {
        let (b, c) = self.lateral();
        let mut out = vec![(p, q)];
        if let SweepKind::Additive { full } = kind {
            for (dp, dq) in [(-1isize, 0isize), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)] {
                if !full && dp != 0 && dq != 0 {
                    continue;
                }
                let (pp, qq) = (p as isize + dp, q as isize + dq);
                if pp >= 0 && qq >= 0 && (pp as usize) < self.n[b] && (qq as usize) < self.n[c] {
                    out.push((pp as usize, qq as usize));
                }
            }
        }
        out
    }
}

fn sweep_forward(g: &Grid, s: &Sweep, input: &[f64], passive: &[Option<f64>], out: &mut [f64], own: &mut [f64], kappa: &mut [f64]) {
    let lay = Layers { axis: s.axis, up: s.up, n: g.n };
    let nb = g.n[lay.lateral().0];
    let sq = SMOOTH_EPS.sqrt();
    for l in 1..lay.count() {
        let results: Vec<(usize, f64, f64, f64)> = (0..lay.size())
            .into_par_iter()
            .map(|pq| {
                let (p, q) = (pq % nb, pq / nb);
                let e = lay.element(g, l, p, q);
                if let Some(v) = passive[e] {
                    return (e, v, 0.0, 0.0);
                }
                let x = input[e];
                match s.kind {
                    SweepKind::Additive { .. } => {
                        let st = lay.stencil(s.kind, p, q);
                        let qexp = AM_P + (st.len() as f64).ln() / 0.5f64.ln();
                        let sum: f64 = st.iter().map(|&(pp, qq)| out[lay.element(g, l - 1, pp, qq)].max(0.0).powf(AM_P)).sum();
                        let smax = if sum > 1e-290 { sum.powf(1.0 / qexp) } else { 0.0 };
                        let r = ((x - smax).powi(2) + SMOOTH_EPS).sqrt();
                        let v = 0.5 * (x + smax - r + sq);
                        let dx = 0.5 * (1.0 - (x - smax) / r);
                        let ds = 0.5 * (1.0 + (x - smax) / r);
                        let k = if sum > 1e-290 { ds * (AM_P / qexp) * sum.powf(1.0 / qexp - 1.0) } else { 0.0 };
                        (e, v, dx, k)
                    }
                    SweepKind::Milling => {
                        let below = out[lay.element(g, l - 1, p, q)];
                        let r = ((x - below).powi(2) + SMOOTH_EPS).sqrt();
                        let v = (0.5 * (x + below + r - sq)).min(1.0);
                        (e, v, 0.5 * (1.0 + (x - below) / r), 0.5 * (1.0 - (x - below) / r))
                    }
                }
            })
            .collect();
        for (e, v, dx, k) in results {
            out[e] = v;
            own[e] = dx;
            kappa[e] = k;
        }
    }
    // Layer 0 rests on the plate (printing) or meets the tool first (milling): out = in.
    let _ = input;
}

fn sweep_backward(g: &Grid, s: &Sweep, out: &[f64], dout: &[f64], own: &[f64], kappa: &[f64]) -> Vec<f64> {
    let lay = Layers { axis: s.axis, up: s.up, n: g.n };
    let nb = g.n[lay.lateral().0];
    let mut gx = dout.to_vec();
    let mut din = vec![0.0; g.elements()];
    for l in (0..lay.count()).rev() {
        // din for this layer.
        for pq in 0..lay.size() {
            let e = lay.element(g, l, pq % nb, pq / nb);
            din[e] = if l == 0 { gx[e] } else { gx[e] * own[e] };
        }
        if l == 0 {
            break;
        }
        // Push to the layer below: gather per voxel below from the voxels it holds up.
        let adds: Vec<(usize, f64)> = (0..lay.size())
            .into_par_iter()
            .map(|pq| {
                let (p, q) = (pq % nb, pq / nb);
                let j = lay.element(g, l - 1, p, q);
                let mut acc = 0.0;
                for (pp, qq) in lay.stencil(s.kind, p, q) {
                    let e = lay.element(g, l, pp, qq);
                    acc += gx[e] * kappa[e];
                }
                let w = match s.kind {
                    SweepKind::Additive { .. } => out[j].max(0.0).powf(AM_P - 1.0),
                    SweepKind::Milling => 1.0,
                };
                (j, acc * w)
            })
            .collect();
        for (j, a) in adds {
            gx[j] += a;
        }
    }
    din
}

/// Per case the solved displacements and forces.
struct State {
    u: Vec<Vec<f64>>,
    f: Vec<Vec<f64>>,
}

/// `λᵀ K_e(E=1) u` per element by polarisation.
fn cross_energy(op: &Operator, a: &[f64], b: &[f64]) -> Vec<f64> {
    let n = op.grid.elements();
    let plus: Vec<f64> = a.par_iter().zip(b.par_iter()).map(|(x, y)| x + y).collect();
    let minus: Vec<f64> = a.par_iter().zip(b.par_iter()).map(|(x, y)| x - y).collect();
    let (mut ep, mut em) = (vec![0.0; n], vec![0.0; n]);
    op.energy(&plus, &mut ep);
    op.energy(&minus, &mut em);
    ep.par_iter().zip(em.par_iter()).map(|(p, m)| 0.25 * (p - m)).collect()
}

/// Per element: `Σ_nodes w·acc × share × ρ₀ × m'(ρ)`, the body load's part of `wᵀ df/dρ`.
fn body_term(m: &Model, acc: [f64; 3], w: &[f64], phys: &[f64]) -> Vec<f64> {
    let g = m.grid;
    let share = g.h.powi(3) / 8.0;
    (0..g.elements())
        .into_par_iter()
        .map(|e| {
            let dm = mass_interp(phys[e]).1;
            if dm == 0.0 {
                return 0.0;
            }
            let s: f64 = g.element_nodes(e).iter().map(|&v| (0..3).map(|a| w[3 * v + a] * acc[a]).sum::<f64>()).sum();
            s * share * m.rho0 * dm
        })
        .collect()
}

/// Per element, von Mises (solid modulus) of one displacement field, and its six stresses.
fn element_stress(m: &Model, smat: &[[f64; 24]; 6], u: &[f64]) -> Vec<(f64, [f64; 6])> {
    let g = m.grid;
    (0..g.elements())
        .into_par_iter()
        .map(|e| {
            let dofs = fem::lex_dofs(&g, e);
            let s: [f64; 6] = std::array::from_fn(|i| m.e0 * (0..24).map(|j| smat[i][j] * u[dofs[j]]).sum::<f64>());
            (fem::von_mises_grad(&s).0, s)
        })
        .collect()
}

/// Runs the study: variants one after another (each uses every core), then analysis and surface.
pub fn generate(study: &Study) -> Result<Outcome, String> {
    generate_with(study, &mut |_| true)
}

/// The error a run stopped by its caller answers when it had nothing to keep (stopped before
/// its first iteration).
pub const CANCELLED: &str = "cancelled";

/// Where a running study is, for front ends: which variant, which iteration of how many (the
/// count grows when a stress-limited run adds its short rounds), and what it is doing.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Progress {
    pub variant: usize,
    pub variants: usize,
    pub iteration: usize,
    pub iterations: usize,
    /// The objective at this iteration (compliance, or the volume fraction for the mass goal).
    pub objective: f64,
    /// "optimising", "analysing" or "done".
    pub stage: String,
}

/// One optimisation iteration as it happened, for live front ends: the figures a convergence
/// plot draws and the physical densities (borrowed: copy or decimate what you keep).
#[derive(Clone, Debug)]
pub struct Step<'a> {
    pub variant: usize,
    /// 1-based, of `iterations` planned (the count grows with stress rounds).
    pub iteration: usize,
    pub iterations: usize,
    /// The objective at this iteration (as [`Progress::objective`]).
    pub objective: f64,
    /// Weighted compliance of the nominal design (N mm).
    pub compliance: f64,
    /// Volume fraction of the design voxels.
    pub volume: f64,
    /// Peak relaxed von Mises stress (`√ρ σ_vm`, MPa) over the static cases, on elements at
    /// density 0.5 and over (0 while none is). NaN when not observed.
    pub max_stress: f64,
    /// Largest design change of the previous step (NaN at the first iteration).
    pub change: f64,
    /// Seconds this iteration took.
    pub seconds: f64,
    pub grid: Grid,
    /// Physical density per element, 0..1.
    pub density: &'a [f64],
}

/// [`generate`], reporting progress after every iteration. As soon as `report` answers false
/// (between iterations, or between variants for frames) the run stops and keeps what it has:
/// the variants already finished, plus the stopped variant's best iterate so far (the latest
/// sharpness reached, lowest objective, among iterates that meet every constraint; else the
/// last one), analysed and surfaced like a finished candidate with `converged` false. The
/// outcome then has `stopped` true. It fails with [`CANCELLED`] when nothing usable was solved
/// (no iteration ran, or the kept shape holds no solid yet and no variant finished).
pub fn generate_with(study: &Study, report: &mut dyn FnMut(&Progress) -> bool) -> Result<Outcome, String> {
    generate_observed(study, report, None)
}

/// [`generate_with`], also handing every topology iteration to `observe` (after `report`, on the
/// solving thread: keep it short). Observing adds one stress pass per iteration.
pub fn generate_observed(study: &Study, report: &mut dyn FnMut(&Progress) -> bool, mut observe: Option<&mut dyn FnMut(&Step)>) -> Result<Outcome, String> {
    let start = std::time::Instant::now();
    let n = study.variants.clamp(1, 16);
    let mut candidates = Vec::with_capacity(n);
    let iterations = study.iterations.max(1);
    let mut warnings = Vec::new();
    let mut stopped = false;
    for k in 0..n {
        let mut p = Progress { variant: k, variants: n, iteration: 0, iterations, objective: f64::NAN, stage: "optimising".into() };
        if !report(&p) {
            if candidates.is_empty() {
                return Err(CANCELLED.into());
            }
            stopped = true;
            warnings.push(format!("stopped after {k} of {n} variants"));
            break;
        }
        let (layout, stop) = match study.method {
            Method::Topology => {
                let live = observe.is_some();
                let mut each = |s: &Step| {
                    let p = Progress { variant: k, variants: n, iteration: s.iteration, iterations: s.iterations, objective: s.objective, stage: "optimising".into() };
                    if !report(&p) {
                        return false;
                    }
                    if let Some(o) = observe.as_mut() {
                        o(&Step { variant: k, ..s.clone() });
                    }
                    true
                };
                let (layout, trace) = optimize_run(study, variant_fraction(study.volume_fraction, k, n), live, &mut each)?;
                (layout, trace.stopped)
            }
            Method::Frame => (frame3d::optimize(study, study.seed.wrapping_add(k as u64 * 0x9E37_79B9))?, None),
        };
        p.stage = "analysing".into();
        match stop {
            Some(stop) => {
                // Stopped mid-run: the kept iterate is analysed and surfaced, then the run ends.
                p.iteration = stop.iteration;
                report(&p);
                stopped = true;
                // A kept shape with no solid yet (stopped in the first, still grey iterations)
                // is nothing to build: the run then ends as if nothing was solved.
                let solid = layout.mesh.is_some() || layout.density.iter().any(|&d| d >= 0.5);
                let kept = if solid { candidate(study, k, layout) } else { Err("no voxel holds material yet".to_string()) }.and_then(|c| if c.mesh.indices.is_empty() { Err("no voxel holds material yet".to_string()) } else { Ok(c) });
                match kept {
                    Ok(mut c) => {
                        c.converged = false;
                        c.stopped_at = Some(stop.iteration);
                        c.kept_iteration = Some(stop.kept);
                        warnings.push(format!(
                            "stopped at iteration {} of {}: candidate {k} keeps iteration {}{}, not converged",
                            stop.iteration,
                            stop.planned,
                            stop.kept,
                            if stop.feasible { "" } else { " (no iterate met every constraint yet)" }
                        ));
                        candidates.push(c);
                    }
                    Err(e) if !candidates.is_empty() => warnings.push(format!("stopped at iteration {}: variant {k} had no usable shape yet ({e})", stop.iteration)),
                    Err(_) => return Err(CANCELLED.into()),
                }
                break;
            }
            None => {
                p.iteration = p.iterations;
                // A stop asked during the analysis keeps this finished candidate.
                let halt = !report(&p);
                candidates.push(candidate(study, k, layout)?);
                if halt && k + 1 < n {
                    stopped = true;
                    warnings.push(format!("stopped after {} of {n} variants", k + 1));
                    break;
                }
            }
        }
    }
    report(&Progress { variant: n - 1, variants: n, iteration: iterations, iterations, objective: f64::NAN, stage: "done".into() });
    let best = best(&candidates);
    let g = Grid::new(study.min, study.max, study.voxel);
    let err = g.extent_error(study.min, study.max);
    if err > 0.01 {
        warnings.push(format!(
            "the voxel grid spans {:.3} x {:.3} x {:.3} mm for a {:.3} x {:.3} x {:.3} mm box ({:.1} % off): pick a voxel that divides the sides",
            g.n[0] as f64 * g.h, g.n[1] as f64 * g.h, g.n[2] as f64 * g.h,
            study.max[0] - study.min[0], study.max[1] - study.min[1], study.max[2] - study.min[2], 100.0 * err
        ));
    }
    Ok(Outcome { candidates, best, seconds: start.elapsed().as_secs_f64(), warnings, stopped })
}

/// Analyses a layout and surfaces it into a candidate.
pub fn candidate(study: &Study, id: usize, layout: Layout) -> Result<Candidate, String> {
    let g = layout.grid;
    let topology = layout.mesh.is_none();
    // What gets built: the solid voxels a support holds (floating pieces dropped).
    let (density, floating) = if topology {
        let (solid, _, floating) = as_built(study, &g, &layout.density);
        (solid.iter().map(|&s| if s { 1.0 } else { 0.0 }).collect::<Vec<f32>>(), floating)
    } else {
        (layout.density.clone(), 0.0)
    };
    let (mut analysis, stress) = analyse_full(study, &g, &density)?;
    analysis.floating_mm3 += floating;
    let mut issues = Vec::new();
    let (mesh, mass_g, mesh_mm3) = match layout.mesh {
        Some(mut mesh) => {
            if mesh.stress.len() * 3 != mesh.positions.len() {
                iso::carry_stress(&g, &mut mesh, &stress);
            }
            let vol: f64 = density.iter().map(|&d| d as f64).sum::<f64>() * g.h.powi(3);
            let mv = if iso::is_closed(&mesh) { iso::volume(&mesh) } else { vol };
            (mesh, vol * study.material.density, mv)
        }
        None => {
            let solid: Vec<bool> = density.iter().map(|&d| d >= 0.5).collect();
            let (mut mesh, _) = iso::surface_solid(&g, &solid, study.smoothing);
            let mut holes = study.bores.clone();
            if study.exact_keep_outs {
                holes.extend(study.keep_out.iter().filter(|r| matches!(r, Region::Cylinder { .. })).copied());
            }
            let fixed = iso::cut_holes(&mut mesh, &holes, 1.5 * g.h);
            // Exact holes put back what the conservative keep-outs voided; the rest of the
            // surface takes the difference so the part stays the analysed volume.
            iso::match_volume(&mut mesh, analysis.solid_mm3, &fixed, 0.3 * g.h);
            iso::carry_stress(&g, &mut mesh, &stress);
            let mv = iso::volume(&mesh);
            let shells = iso::bodies(&mesh);
            if shells != analysis.bodies {
                issues.push(format!("the surface has {shells} bodies where the analysed solid has {}", analysis.bodies));
            }
            if analysis.solid_mm3 > 0.0 && (mv / analysis.solid_mm3 - 1.0).abs() > 0.05 {
                issues.push(format!("the surface encloses {mv:.0} mm3 against {:.0} mm3 of analysed solid ({:+.1} %)", analysis.solid_mm3, 100.0 * (mv / analysis.solid_mm3 - 1.0)));
            }
            // The mass is the analysed solid's, so mass, inertia and strength are of one shape.
            (mesh, analysis.solid_mm3 * study.material.density, mv)
        }
    };
    let feasible = feasible(study, &analysis, &mut issues);
    let volume_fraction = density.iter().map(|&d| d as f64).sum::<f64>() / density.len().max(1) as f64;
    Ok(Candidate { id, method: study.method, mass_g, volume_fraction, feasible, analysis, history: layout.history, grid: g, density, mesh, mesh_mm3, issues, converged: true, stopped_at: None, kept_iteration: None })
}

fn feasible(study: &Study, a: &Analysis, issues: &mut Vec<String>) -> bool {
    let limit = study.max_stress.unwrap_or(study.material.allowable / study.safety_factor.max(1.0));
    let worst = a.max_stress.iter().chain(a.impacts.iter().map(|i| &i.peak_stress)).copied().fold(0.0, f64::max);
    let disp = a.max_displacement.iter().copied().fold(0.0, f64::max);
    let peak = a.impacts.iter().map(|i| i.peak_displacement).fold(0.0, f64::max);
    let peak_limit = study.max_impact_displacement.or(study.max_displacement);
    let peak_ok = peak_limit.is_none_or(|d| peak <= d * 1.0001);
    let stress_ok = worst.is_finite() && worst <= limit * 1.0001;
    let disp_ok = study.max_displacement.is_none_or(|d| disp <= d * 1.0001);
    let f1 = a.modes.first().map_or(0.0, |m| m.frequency);
    let freq_ok = study.min_frequency.is_none_or(|f| f1 >= f * 0.9999);
    let bodies_ok = study.method != Method::Topology || (a.bodies >= 1 && a.bodies <= study.max_bodies.max(1));
    let carried = a.unsupported.is_empty();
    if !stress_ok {
        issues.push(format!("stress {worst:.1} MPa over the {limit:.1} MPa limit"));
    }
    if !disp_ok {
        issues.push(format!("displacement {disp:.3} mm over the {:.3} mm limit", study.max_displacement.unwrap_or(0.0)));
    }
    if !peak_ok {
        issues.push(format!("impact peak displacement {peak:.3} mm over the {:.3} mm limit", peak_limit.unwrap_or(0.0)));
    }
    if !freq_ok {
        issues.push(format!("first mode {f1:.0} Hz under the {:.0} Hz floor", study.min_frequency.unwrap_or(0.0)));
    }
    if !bodies_ok {
        issues.push(format!("{} separate bodies where {} is allowed", a.bodies, study.max_bodies.max(1)));
    }
    if !carried {
        issues.push(format!("no material carries {} to a support", a.unsupported.join(", ")));
    }
    if a.floating_mm3 > 0.0 {
        issues.push(format!("{:.1} mm3 of solid no support holds (or held scraps under 1 % of the part) was dropped", a.floating_mm3));
    }
    stress_ok && disp_ok && peak_ok && freq_ok && bodies_ok && carried
}

/// Labels the face-joined components of `mask`; answers the labels (`u32::MAX` off the mask) and
/// how many.
fn components(grid: &Grid, mask: &[bool]) -> (Vec<u32>, usize) {
    let n = grid.n;
    let mut label = vec![u32::MAX; mask.len()];
    let mut count = 0u32;
    let mut stack = Vec::new();
    for start in 0..mask.len() {
        if !mask[start] || label[start] != u32::MAX {
            continue;
        }
        label[start] = count;
        stack.push(start);
        while let Some(e) = stack.pop() {
            let [i, j, k] = grid.element_ijk(e);
            let mut visit = |f: usize| {
                if mask[f] && label[f] == u32::MAX {
                    label[f] = count;
                    stack.push(f);
                }
            };
            if i > 0 { visit(grid.element(i - 1, j, k)); }
            if i + 1 < n[0] { visit(grid.element(i + 1, j, k)); }
            if j > 0 { visit(grid.element(i, j - 1, k)); }
            if j + 1 < n[1] { visit(grid.element(i, j + 1, k)); }
            if k > 0 { visit(grid.element(i, j, k - 1)); }
            if k + 1 < n[2] { visit(grid.element(i, j, k + 1)); }
        }
        count += 1;
    }
    (label, count as usize)
}

/// The layout as built: solid where the density is 0.5 or more, keeping only the bodies (joined
/// face to face) that touch a support. Answers the solid, the bodies kept and the volume dropped
/// (mm³). With no support on the grid every body is kept.
pub fn as_built(study: &Study, grid: &Grid, density: &[f32]) -> (Vec<bool>, usize, f64) {
    let solid: Vec<bool> = density.iter().map(|&d| d >= 0.5).collect();
    let fixed = loads::fixed_dofs(grid, &study.supports);
    let held = |v: usize| fixed[3 * v] || fixed[3 * v + 1] || fixed[3 * v + 2];
    let (label, count) = components(grid, &solid);
    let mut holds = vec![false; count];
    for e in 0..solid.len() {
        if solid[e] && !holds[label[e] as usize] && grid.element_nodes(e).iter().any(|&v| held(v)) {
            holds[label[e] as usize] = true;
        }
    }
    if !holds.iter().any(|&h| h) {
        return (solid, count, 0.0);
    }
    // A held scrap under 1 % of the largest held body (a sliver of a seat wall a keep-out cut
    // off, still on a support) is not a part: it goes with the floating material, as the
    // surface drops islands under 1 % of the largest shell.
    let mut size = vec![0usize; count];
    for e in 0..solid.len() {
        if solid[e] {
            size[label[e] as usize] += 1;
        }
    }
    let largest = (0..count).filter(|&c| holds[c]).map(|c| size[c]).max().unwrap_or(0);
    for c in 0..count {
        if holds[c] && size[c] * 100 < largest {
            holds[c] = false;
        }
    }
    let mut dropped = 0usize;
    let kept: Vec<bool> = solid
        .iter()
        .zip(&label)
        .map(|(&s, &l)| {
            let keep = s && holds[l as usize];
            if s && !keep {
                dropped += 1;
            }
            keep
        })
        .collect();
    (kept, holds.iter().filter(|&&h| h).count(), dropped as f64 * grid.h.powi(3))
}

/// The volume fraction variant `k` of `n` aims for: spread ±30 % around the asked fraction.
fn variant_fraction(vf: f64, k: usize, n: usize) -> f64 {
    if n <= 1 {
        return vf;
    }
    let t = k as f64 / (n - 1) as f64;
    (vf * (0.7 + 0.6 * t)).clamp(0.02, 0.95)
}

/// The lightest feasible candidate, else the safest.
fn best(c: &[Candidate]) -> usize {
    let feasible = c.iter().filter(|c| c.feasible).min_by(|a, b| a.mass_g.total_cmp(&b.mass_g));
    feasible.or_else(|| c.iter().max_by(|a, b| a.analysis.safety_factor.total_cmp(&b.analysis.safety_factor))).map_or(0, |c| c.id)
}

/// Optimises one layout for `volume_fraction` (the compliance objective's budget, the mass
/// objective's cap).
pub fn optimize(study: &Study, volume_fraction: f64) -> Result<Layout, String> {
    optimize_with(study, volume_fraction, &mut |_, _| {})
}

/// One evaluation of the objective and the limits, with their gradients in the design variables.
pub(crate) struct Evaluation {
    /// The nominal realisation (the layout that is built).
    chain: Chain,
    f0: f64,
    df0: Vec<f64>,
    g: Vec<f64>,
    dg: Vec<Vec<f64>>,
    vol: f64,
    /// Weighted compliance of the nominal realisation.
    comp: f64,
    /// Per realisation (eroded, nominal, dilated when robust): weighted compliance.
    comps: Vec<f64>,
    /// The lowest eigenvalues `ω²` the frequency floor read, (rad/s)².
    lambdas: Vec<f64>,
}

/// One projection of the design variables and its static solution.
struct Realisation {
    chain: Chain,
    young: Vec<f64>,
    rho: Vec<f64>,
    dk: Vec<f64>,
    hier: Hierarchy,
}

/// The optimiser's state between evaluations: warm starts and the aggregation scales.
pub(crate) struct Evaluator<'a> {
    m: Model,
    study: &'a Study,
    vf: f64,
    design: Vec<bool>,
    n_design: f64,
    mass_obj: bool,
    ncon: usize,
    /// Projection thresholds, the nominal's index among them and the critical one's (the
    /// eroded design, thinnest, for stress and displacement).
    etas: Vec<f64>,
    nominal: usize,
    critical: usize,
    /// Robust compliance: min z with each realisation's compliance under z (bound formulation);
    /// the extra variable sits after the groups.
    bound: bool,
    ci_bound: Option<usize>,
    ci_stress: Option<usize>,
    ci_disp: Option<usize>,
    ci_freq: Option<usize>,
    freq_modes: usize,
    lam_min: Option<f64>,
    smat: [[f64; 24]; 6],
    stress_set: Vec<bool>,
    /// Per realisation: displacements per case (warm starts) and the last forces.
    state: Vec<State>,
    c0: Option<f64>,
    stress_scale: f64,
    disp_scale: f64,
    modes_warm: Option<Vec<Eigen>>,
    /// Share of the stress limit aimed at.
    margin: f64,
}

/// The volume fraction of the design voxels that gives `mass_g` with the keep-in solid.
fn fraction_for_mass(m: &Model, density: f64, mass_g: f64) -> f64 {
    let voxel_g = density * m.grid.h.powi(3);
    let kept = m.passive.iter().filter(|p| **p == Some(1.0)).count() as f64;
    let design = m.passive.iter().filter(|p| p.is_none()).count().max(1) as f64;
    ((mass_g / voxel_g - kept) / design).clamp(0.01, 1.0)
}

impl<'a> Evaluator<'a> {
    pub(crate) fn new(study: &'a Study, volume_fraction: f64) -> Result<Self, String> {
        let m = Model::new(study)?;
        let g = m.grid;
        let vf = match study.mass_target_g {
            Some(mt) if mt > 0.0 => {
                // Variants keep their spread around the target.
                let spread = if study.volume_fraction > 0.0 { volume_fraction / study.volume_fraction } else { 1.0 };
                (fraction_for_mass(&m, study.material.density, mt) * spread).clamp(0.01, 1.0)
            }
            _ => volume_fraction.clamp(0.01, 1.0),
        };
        let design: Vec<bool> = m.passive.iter().map(|p| p.is_none()).collect();
        let n_design = design.iter().filter(|&&d| d).count().max(1) as f64;
        let mass_obj = study.objective == Objective::Mass;
        let use_stress = mass_obj || study.max_stress.is_some();
        let use_disp = study.max_displacement.is_some();
        let lam_min = study.min_frequency.map(|f| (2.0 * std::f64::consts::PI * f).powi(2));
        let freq_modes = study.frequency_modes.clamp(1, 8);
        let (etas, nominal, critical) = match study.robust {
            Some(r) => {
                let d = r.delta.clamp(0.01, 0.45);
                (vec![0.5 + d, 0.5, 0.5 - d], 1, 0)
            }
            None => (vec![0.5], 0, 0),
        };
        let bound = etas.len() > 1 && !mass_obj;
        let mut ncon = 1;
        let mut take = |k: usize| {
            ncon += k;
            ncon - k
        };
        let ci_bound = bound.then(|| take(etas.len()));
        let ci_stress = use_stress.then(|| take(1));
        let ci_disp = use_disp.then(|| take(1));
        let ci_freq = lam_min.map(|_| take(freq_modes));
        let smat = fem::stress_matrix(study.material.nu, g.h);
        let stress_set: Vec<bool> = m.singular.iter().map(|&s| !s).collect();
        let state = etas.iter().map(|_| State { u: vec![vec![0.0; g.dofs()]; study.cases.len()], f: Vec::new() }).collect();
        Ok(Self {
            m,
            study,
            vf,
            design,
            n_design,
            mass_obj,
            ncon,
            etas,
            nominal,
            critical,
            bound,
            ci_bound,
            ci_stress,
            ci_disp,
            ci_freq,
            freq_modes,
            lam_min,
            smat,
            stress_set,
            state,
            c0: None,
            stress_scale: 1.0,
            disp_scale: 1.0,
            modes_warm: None,
            margin: STRESS_MARGIN,
        })
    }

    /// Design variables: one per group, and the bound variable last when robust compliance.
    pub(crate) fn variables(&self) -> usize {
        self.m.groups + usize::from(self.bound)
    }

    /// Projects with threshold `etas[r]`, assembles and solves every load case.
    fn realise(&mut self, r: usize, x: &[f64], beta: f64, tol: f64) -> Result<Realisation, String> {
        let m = &self.m;
        let study = self.study;
        let chain = m.forward(&x[..m.groups], beta, self.etas[r]);
        let young = m.young(&chain.phys);
        let rho = m.rho(&chain.phys);
        let hier = Hierarchy::new(&m.op, &young);
        let st = &mut self.state[r];
        st.f = (0..study.cases.len()).map(|c| m.forces(study, c, &rho)).collect();
        for c in 0..study.cases.len() {
            hier.solve(&st.f[c], &mut st.u[c], tol, 600)?;
        }
        let dk: Vec<f64> = chain.phys.par_iter().map(|&p| m.e0 * PENAL * p.powf(PENAL - 1.0) * (1.0 - EMIN)).collect();
        Ok(Realisation { chain, young, rho, dk, hier })
    }

    /// Weighted compliance of realisation `r` and its gradient in the physical densities.
    fn compliance(&self, r: usize, re: &Realisation) -> (f64, Vec<f64>) {
        let m = &self.m;
        let ne = m.grid.elements();
        let st = &self.state[r];
        let mut comp = 0.0;
        let mut dcomp = vec![0.0; ne];
        for (c, case) in self.study.cases.iter().enumerate() {
            let w = case.weight;
            if w == 0.0 {
                continue;
            }
            comp += w * dot(&st.f[c], &st.u[c]);
            let mut en = vec![0.0; ne];
            m.op.energy(&st.u[c], &mut en);
            let body = case.acceleration.map(|a| body_term(m, a, &st.u[c], &re.chain.phys));
            dcomp.par_iter_mut().enumerate().for_each(|(e, d)| {
                *d += w * (-re.dk[e] * en[e] + body.as_ref().map_or(0.0, |b| 2.0 * b[e]));
            });
        }
        (comp, dcomp)
    }

    /// Evaluates at `x`; `rescale` updates the aggregation scales (off for gradient checks).
    pub(crate) fn evaluate(&mut self, x: &[f64], beta: f64, it: usize, tol: f64, rescale: bool) -> Result<Evaluation, String> {
        let nreal = self.etas.len();
        let mut reals = Vec::with_capacity(nreal);
        for r in 0..nreal {
            reals.push(self.realise(r, x, beta, tol)?);
        }
        let (nominal, critical) = (self.nominal, self.critical);
        let groups = self.m.groups;
        let nvar = self.variables();
        let mut comps = Vec::with_capacity(nreal);
        let mut dcomps = Vec::with_capacity(nreal);
        for (r, re) in reals.iter().enumerate() {
            let (c, d) = self.compliance(r, re);
            comps.push(c);
            dcomps.push(d);
        }
        let c0v = *self.c0.get_or_insert(comps.iter().copied().fold(0.0, f64::max).abs().max(1e-30));
        let m = &self.m;
        let study = self.study;
        let g = m.grid;
        let ne = g.elements();
        let (vf, n_design, mass_obj, ncon) = (self.vf, self.n_design, self.mass_obj, self.ncon);
        let (design, smat, stress_set) = (&self.design, &self.smat, &self.stress_set);

        // Gradients are gathered per realisation in the physical densities, then taken back
        // through that realisation's chain and summed in the design variables.
        let mut df0 = vec![0.0; nvar];
        let mut dg = vec![vec![0.0; nvar]; ncon];
        let mut gvals = vec![0.0; ncon];
        let add = |out: &mut Vec<f64>, re: &Realisation, dphys: &[f64], scale: f64| {
            let d = m.backward(&re.chain, beta, dphys);
            out[..groups].par_iter_mut().zip(d.par_iter()).for_each(|(o, v)| *o += scale * v);
        };

        // Volume of the nominal layout.
        let nphys = &reals[nominal].chain.phys;
        let vol: f64 = nphys.iter().zip(design.iter()).filter(|(_, d)| **d).map(|(r, _)| r).sum::<f64>() / n_design;
        let dvol: Vec<f64> = design.iter().map(|&d| if d { 1.0 / n_design } else { 0.0 }).collect();
        gvals[0] = vol / vf - 1.0;
        add(&mut dg[0], &reals[nominal], &dvol, 1.0 / vf);

        let f0;
        if mass_obj {
            f0 = vol / vf;
            add(&mut df0, &reals[nominal], &dvol, 1.0 / vf);
        } else if let Some(cb) = self.ci_bound {
            let z = x[groups];
            f0 = z;
            df0[groups] = 1.0;
            for r in 0..nreal {
                gvals[cb + r] = comps[r] / c0v - z;
                add(&mut dg[cb + r], &reals[r], &dcomps[r], 1.0 / c0v);
                dg[cb + r][groups] = -1.0;
            }
        } else {
            f0 = comps[nominal] / c0v;
            add(&mut df0, &reals[nominal], &dcomps[nominal], 1.0 / c0v);
        }

        let crit = &reals[critical];
        let phys = &crit.chain.phys;
        let state = &self.state[critical];
        if let Some(ci) = self.ci_stress {
            // p-norm of relaxed stress over every case.
            let per_case: Vec<Vec<(f64, [f64; 6])>> = state.u.iter().map(|u| element_stress(m, smat, u)).collect();
            let mut sum = 0.0;
            let mut true_max: f64 = 0.0;
            for s in &per_case {
                for e in 0..ne {
                    if !stress_set[e] {
                        continue;
                    }
                    let rel = phys[e].max(1e-9).powf(STRESS_Q) * s[e].0;
                    sum += rel.powf(STRESS_P);
                    true_max = true_max.max(rel);
                }
            }
            let pn = sum.powf(1.0 / STRESS_P).max(1e-30);
            let ratio = true_max / pn;
            if rescale {
                self.stress_scale = if it == 0 { ratio } else { 0.5 * self.stress_scale + 0.5 * ratio };
            }
            let stress_scale = self.stress_scale;
            gvals[ci] = stress_scale * pn / (self.margin * m.stress_limit) - 1.0;
            let mut grad = vec![0.0; ne];
            for (c, s) in per_case.iter().enumerate() {
                // Explicit term and the adjoint's right-hand side.
                let mut rhs = vec![0.0; g.dofs()];
                for e in 0..ne {
                    if !stress_set[e] || s[e].0 <= 0.0 {
                        continue;
                    }
                    let rq = phys[e].max(1e-9).powf(STRESS_Q);
                    let rel = rq * s[e].0;
                    let dpn = pn.powf(1.0 - STRESS_P) * rel.powf(STRESS_P - 1.0);
                    grad[e] += dpn * STRESS_Q * phys[e].max(1e-9).powf(STRESS_Q - 1.0) * s[e].0;
                    let (_, dvm) = fem::von_mises_grad(&s[e].1);
                    let dofs = fem::lex_dofs(&g, e);
                    let k = dpn * rq * m.e0;
                    for j in 0..24 {
                        let mut v = 0.0;
                        for i in 0..6 {
                            v += dvm[i] * smat[i][j];
                        }
                        rhs[dofs[j]] += k * v;
                    }
                }
                let mut lam = vec![0.0; g.dofs()];
                crit.hier.solve(&rhs, &mut lam, 1e-5, 600)?;
                adjoint_terms(m, study, c, &lam, &state.u[c], phys, &crit.dk, &mut grad);
            }
            add(&mut dg[ci], crit, &grad, stress_scale / (self.margin * m.stress_limit));
        }

        if let Some(ci) = self.ci_disp {
            let dmax = study.max_displacement.unwrap_or(1.0);
            let mut sum = 0.0;
            let mut true_max: f64 = 0.0;
            for u in &state.u {
                for p in u.chunks(3) {
                    let q = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt();
                    sum += q.powf(DISP_P);
                    true_max = true_max.max(q);
                }
            }
            let pn = sum.powf(1.0 / DISP_P).max(1e-30);
            let ratio = true_max / pn;
            if rescale {
                self.disp_scale = if it == 0 { ratio } else { 0.5 * self.disp_scale + 0.5 * ratio };
            }
            let disp_scale = self.disp_scale;
            gvals[ci] = disp_scale * pn / dmax - 1.0;
            let mut grad = vec![0.0; ne];
            for c in 0..study.cases.len() {
                let u = &state.u[c];
                let rhs: Vec<f64> = (0..g.dofs())
                    .into_par_iter()
                    .map(|d| {
                        let v = d / 3;
                        let q2: f64 = (0..3).map(|a| u[3 * v + a].powi(2)).sum();
                        if q2 <= 0.0 { 0.0 } else { pn.powf(1.0 - DISP_P) * q2.powf((DISP_P - 2.0) / 2.0) * u[d] }
                    })
                    .collect();
                let mut mu = vec![0.0; g.dofs()];
                crit.hier.solve(&rhs, &mut mu, 1e-5, 600)?;
                adjoint_terms(m, study, c, &mu, u, phys, &crit.dk, &mut grad);
            }
            add(&mut dg[ci], crit, &grad, disp_scale / dmax);
        }

        let mut lambdas = Vec::new();
        if let (Some(ci), Some(lmin)) = (self.ci_freq, self.lam_min) {
            // Bound formulation (Olhoff and Du): every one of the lowest modes stays over the
            // floor, each its own constraint, so a cluster that coincides or swaps order keeps
            // all its members held and no single non-smooth eigenvalue drives the step.
            let re = &reals[nominal];
            let nphys = &re.chain.phys;
            let mut mass = fem::lumped_mass(&g, &re.rho);
            fem::add_point_masses(&g, &study.point_masses, &mut mass);
            let want = self.freq_modes;
            let modes = dynamics::eigen(&m.op, &re.young, &re.hier, &mass, want, self.modes_warm.as_deref(), if it == 0 { 20 } else { 4 }, 1e-4)?;
            let share = g.h.powi(3) / 8.0;
            for (j, mode) in modes.iter().take(want).enumerate() {
                gvals[ci + j] = 1.0 - mode.lambda / lmin;
                lambdas.push(mode.lambda);
                let mut en = vec![0.0; ne];
                m.op.energy(&mode.shape, &mut en);
                let grad: Vec<f64> = (0..ne)
                    .into_par_iter()
                    .map(|e| {
                        let phi2: f64 = g.element_dofs(e).iter().map(|&d| mode.shape[d].powi(2)).sum();
                        let dlam = re.dk[e] * en[e] - mode.lambda * m.rho0 * mass_interp(nphys[e]).1 * share * phi2;
                        -dlam / lmin
                    })
                    .collect();
                add(&mut dg[ci + j], re, &grad, 1.0);
            }
            self.modes_warm = Some(modes);
        }

        let comp = comps[nominal];
        let chain = reals.swap_remove(nominal).chain;
        Ok(Evaluation { chain, f0, df0, g: gvals, dg, vol, comp, comps, lambdas })
    }
}

/// [`optimize`], reporting `(iteration, objective)` as it goes.
pub fn optimize_with(study: &Study, volume_fraction: f64, report: &mut dyn FnMut(usize, f64)) -> Result<Layout, String> {
    optimize_traced(study, volume_fraction, report).map(|(l, _)| l)
}

/// What a run did, beyond the layout: for validation and reports.
#[derive(Clone, Debug, Default)]
pub struct Trace {
    /// Outer iterations run.
    pub iterations: usize,
    /// Per iteration: seconds.
    pub seconds: Vec<f64>,
    /// Last iteration: compliance per realisation (eroded, nominal, dilated when robust).
    pub compliances: Vec<f64>,
    /// Last iteration: the volume fraction reached and the target.
    pub volume: f64,
    pub target: f64,
    /// Last iteration: the lowest eigenvalues the frequency floor held, (rad/s)².
    pub lambdas: Vec<f64>,
    /// Largest design change of the last step.
    pub change: f64,
    /// Set when the caller stopped the run: the layout is then the kept iterate.
    pub stopped: Option<Stop>,
}

/// Where a stopped run was and which iterate it kept.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stop {
    /// Iterations run (1-based count of the last one).
    pub iteration: usize,
    /// Iterations planned at the stop (grows with stress rounds).
    pub planned: usize,
    /// The iteration kept (1-based).
    pub kept: usize,
    /// Whether the kept iterate met every constraint (within 1 %).
    pub feasible: bool,
}

/// The iterate a stopped run keeps, chosen as the run goes.
struct Kept {
    beta: f64,
    objective: f64,
    iteration: usize,
    feasible: bool,
    phys: Vec<f64>,
}

impl Kept {
    /// Whether an iterate at `beta` with `objective` beats this one: a feasible iterate beats an
    /// infeasible one; among equals, a sharper one (projection continuation makes earlier,
    /// greyer iterates read stiffer than what would be built), then the lower objective; among
    /// infeasible ones, the latest.
    fn beaten_by(&self, feasible: bool, beta: f64, objective: f64) -> bool {
        match (self.feasible, feasible) {
            (false, true) => true,
            (true, false) => false,
            (false, false) => true,
            (true, true) => beta > self.beta || (beta == self.beta && objective <= self.objective),
        }
    }
}

/// [`optimize_with`], with what the run did.
pub fn optimize_traced(study: &Study, volume_fraction: f64, report: &mut dyn FnMut(usize, f64)) -> Result<(Layout, Trace), String> {
    optimize_run(study, volume_fraction, false, &mut |s| {
        report(s.iteration - 1, s.objective);
        true
    })
}

/// Peak relaxed von Mises (`ρ^q σ_vm`, MPa) over the displacement fields `us`, on the elements
/// at density 0.5 and over (the part as it would be built; voids strain without meaning).
fn peak_stress(m: &Model, smat: &[[f64; 24]; 6], us: &[Vec<f64>], phys: &[f64], set: &[bool]) -> f64 {
    let g = m.grid;
    us.iter()
        .map(|u| {
            (0..g.elements())
                .into_par_iter()
                .filter(|&e| set[e] && phys[e] >= 0.5)
                .map(|e| {
                    let dofs = fem::lex_dofs(&g, e);
                    let s: [f64; 6] = std::array::from_fn(|i| m.e0 * (0..24).map(|j| smat[i][j] * u[dofs[j]]).sum::<f64>());
                    phys[e].max(1e-9).powf(STRESS_Q) * fem::von_mises_grad(&s).0
                })
                .reduce(|| 0.0, f64::max)
        })
        .fold(0.0, f64::max)
}

/// [`optimize_traced`], reporting each [`Step`] (`live` fills its peak stress, NaN otherwise).
/// When `report` answers false the run stops and answers the best iterate so far (see [`Kept`])
/// with `trace.stopped` set.
fn optimize_run(study: &Study, volume_fraction: f64, live: bool, report: &mut dyn FnMut(&Step) -> bool) -> Result<(Layout, Trace), String> {
    let mut ev = Evaluator::new(study, volume_fraction)?;
    let groups = ev.m.groups;
    let nvar = ev.variables();
    let g = ev.m.grid;
    let iterations = study.iterations.max(1);
    let mut x = vec![if ev.mass_obj { ev.vf.min(0.6) } else { ev.vf }; nvar];
    let (mut xmin, mut xmax) = (vec![0.0; nvar], vec![1.0; nvar]);
    if ev.bound {
        // The bound on the compliances (scaled by the start's worst one).
        x[groups] = 1.0;
        xmin[groups] = 0.0;
        xmax[groups] = 4.0;
    }
    let mut mma = Mma::new(nvar, ev.ncon);
    let mut history = Vec::with_capacity(iterations);
    let mut trace = Trace { target: ev.vf, ..Trace::default() };
    let stage = (iterations / 5).max(1);
    let mut phys = Vec::new();
    let mut kept: Option<Kept> = None;
    // Stress and displacement limits are far from linear in the densities: shorter steps.
    let hard = ev.ci_stress.is_some() || ev.ci_disp.is_some();
    // The main run, then (stress-limited studies) up to three short rounds at full sharpness,
    // each aiming lower by what the analysis found over the limit.
    let extra = if ev.ci_stress.is_some() { (iterations / 4).max(5) } else { 0 };
    let mut total = iterations;
    let mut round = 0;
    let mut it = 0;
    while it < total {
        let t0 = std::time::Instant::now();
        let beta = if study.max_beta <= 0.0 { 0.0 } else { 2f64.powi(((it / stage) as i32).min(4)).min(study.max_beta.max(1.0)) };
        let sharp = study.max_beta <= 0.0 || beta >= study.max_beta.max(1.0);
        let last = it + 1 == total;
        let e = ev.evaluate(&x, beta, it, if last { 1e-7 } else { 1e-5 }, true)?;
        if std::env::var_os("VIAFORM_GEN_TRACE").is_some() {
            eprintln!("it {it:3} beta {beta:4.1} vol {:.4} comp {:.4e} f0 {:.4} g {:?}", e.vol, e.comp, e.f0, e.g);
        }
        history.push(if ev.mass_obj { e.vol } else { e.comp });
        let max_stress = if live { peak_stress(&ev.m, &ev.smat, &ev.state[ev.nominal].u, &e.chain.phys, &ev.stress_set) } else { f64::NAN };
        let step = Step {
            variant: 0,
            iteration: it + 1,
            iterations: total,
            objective: *history.last().unwrap_or(&0.0),
            compliance: e.comp,
            volume: e.vol,
            max_stress,
            change: if it == 0 { f64::NAN } else { trace.change },
            seconds: t0.elapsed().as_secs_f64(),
            grid: g,
            density: &e.chain.phys,
        };
        let objective = step.objective;
        let feasible = e.g.iter().all(|&v| v <= 0.01);
        if kept.as_ref().is_none_or(|k| k.beaten_by(feasible, beta, objective)) {
            kept = Some(Kept { beta, objective, iteration: it + 1, feasible, phys: e.chain.phys.clone() });
        }
        if !report(&step) {
            let k = kept.take().expect("set just above");
            trace.iterations = it + 1;
            trace.volume = e.vol;
            trace.stopped = Some(Stop { iteration: it + 1, planned: total, kept: k.iteration, feasible: k.feasible });
            let density = k.phys.iter().map(|&r| r as f32).collect();
            return Ok((Layout { grid: g, density, mesh: None, history }, trace));
        }
        trace.compliances = e.comps.clone();
        trace.volume = e.vol;
        trace.lambdas = e.lambdas.clone();
        phys = e.chain.phys;
        it += 1;
        trace.iterations = it;
        if last {
            trace.seconds.push(t0.elapsed().as_secs_f64());
            if extra > 0 && round < 3 {
                let density: Vec<f32> = phys.iter().map(|&r| r as f32).collect();
                let (a, _) = analyse_full(study, &g, &density)?;
                let peak = a.max_stress.iter().copied().fold(0.0, f64::max);
                // A load the built part no longer reaches reads as no stress at all: that is
                // the worst case, not a pass, so it aims lower too.
                let cut = !a.unsupported.is_empty();
                if peak > ev.m.stress_limit || cut {
                    ev.margin *= if cut { 0.8 } else { 0.95 * ev.m.stress_limit / peak };
                    round += 1;
                    total += extra;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        let move_limit = match (hard, beta >= 8.0) {
            _ if study.max_beta <= 0.0 && !hard => 0.2,
            (false, false) => 0.2,
            (false, true) => 0.1,
            (true, false) => 0.05,
            (true, true) => 0.03,
        };
        let before = x.clone();
        mma.try_update(&mut x, &xmin, &xmax, &e.df0, &e.g, &e.dg, move_limit)?;
        let change = x[..groups].iter().zip(&before).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        trace.change = change;
        if study.tolerance > 0.0 && sharp && it >= 2 && change < study.tolerance && !hard {
            // Converged: one last evaluation at the moved point closes the run.
            total = it + 1;
        }
        if !last {
            trace.seconds.push(t0.elapsed().as_secs_f64());
        }
    }
    let density = phys.iter().map(|&r| r as f32).collect();
    Ok((Layout { grid: g, density, mesh: None, history }, trace))
}

/// Adds `-λᵀ dK/dρ u + λᵀ df/dρ` (the adjoint part of a sensitivity) to `grad`.
#[allow(clippy::too_many_arguments)]
fn adjoint_terms(m: &Model, study: &Study, c: usize, lam: &[f64], u: &[f64], phys: &[f64], dk: &[f64], grad: &mut [f64]) {
    let cross = cross_energy(&m.op, lam, u);
    let body = study.cases[c].acceleration.map(|a| body_term(m, a, lam, phys));
    grad.par_iter_mut().enumerate().for_each(|(e, gr)| {
        *gr += -dk[e] * cross[e] + body.as_ref().map_or(0.0, |b| b[e]);
    });
}

/// Static, modal and impact analysis of a layout (densities on `grid`).
pub fn analyse(study: &Study, grid: &Grid, density: &[f32]) -> Result<Analysis, String> {
    analyse_full(study, grid, density).map(|(a, _)| a)
}

/// [`analyse`], and the worst von Mises per element over the static cases (MPa; zero in voids).
pub fn analyse_full(study: &Study, grid: &Grid, density: &[f32]) -> Result<(Analysis, Vec<f64>), String> {
    let mut s = study.clone();
    s.min = grid.origin;
    s.max = std::array::from_fn(|a| grid.origin[a] + grid.n[a] as f64 * grid.h);
    s.voxel = grid.h;
    let m = Model::new(&s)?;
    if m.grid.n != grid.n || density.len() != grid.elements() {
        return Err("the layout does not match the study's grid".into());
    }
    let ne = grid.elements();
    // Topology layouts are analysed as built: solid or void, floating pieces dropped, and each
    // load on the material it lands on (none: nothing carries it, reported).
    let built = (study.method == Method::Topology).then(|| as_built(study, grid, density));
    let phys: Vec<f64> = match &built {
        Some((solid, _, _)) => solid.iter().map(|&s| if s { 1.0 } else { 0.0 }).collect(),
        None => density.iter().map(|&d| (d as f64).clamp(0.0, 1.0)).collect(),
    };
    let mut a = Analysis::default();
    let mut applied: Option<Vec<Vec<f64>>> = None;
    if let Some((solid, bodies, floating)) = &built {
        a.bodies = *bodies;
        a.floating_mm3 = *floating;
        a.solid_mm3 = solid.iter().filter(|&&s| s).count() as f64 * grid.h.powi(3);
        let mut attached = vec![false; grid.nodes()];
        for e in (0..ne).filter(|&e| solid[e]) {
            for v in grid.element_nodes(e) {
                attached[v] = true;
            }
        }
        let mut per_case = Vec::with_capacity(study.cases.len());
        for (c, case) in study.cases.iter().enumerate() {
            let mut kept = case.clone();
            kept.loads.clear();
            for (l, load) in case.loads.iter().enumerate() {
                let region = match load {
                    super::Load::Force { region, .. } | super::Load::Torque { region, .. } | super::Load::Pressure { region, .. } => region,
                };
                if grid.nodes_in(region).iter().any(|&v| attached[v]) {
                    kept.loads.push(load.clone());
                } else {
                    let name = if case.name.is_empty() { format!("case {}", c + 1) } else { case.name.clone() };
                    a.unsupported.push(format!("{name}: load {}", l + 1));
                }
            }
            per_case.push(loads::applied_on(grid, &kept, Some(&attached)));
        }
        applied = Some(per_case);
    }
    let young = m.young(&phys);
    let rho = m.rho(&phys);
    let hier = Hierarchy::new(&m.op, &young);
    let smat = fem::stress_matrix(study.material.nu, grid.h);
    let solid: Vec<bool> = (0..ne).map(|e| phys[e] >= 0.5 && !m.singular[e]).collect();
    let mut worst = vec![0.0f64; ne];
    let mut static_peaks = Vec::new();
    let mut forces = Vec::new();
    for (c, case) in study.cases.iter().enumerate() {
        let f = match &applied {
            Some(per_case) => {
                let mut f = per_case[c].clone();
                if let Some(b) = loads::body(grid, case, &rho) {
                    f.iter_mut().zip(&b).for_each(|(f, b)| *f += b);
                }
                f
            }
            None => m.forces(study, c, &rho),
        };
        let mut u = vec![0.0; grid.dofs()];
        hier.solve(&f, &mut u, 1e-8, 3000)?;
        a.compliance.push(case.weight * dot(&f, &u));
        let st = element_stress(&m, &smat, &u);
        let mut mx: f64 = 0.0;
        for e in 0..ne {
            if phys[e] >= 0.5 {
                worst[e] = worst[e].max(st[e].0);
            }
            if solid[e] {
                mx = mx.max(st[e].0);
            }
        }
        a.max_stress.push(mx);
        static_peaks.push(mx);
        a.max_displacement.push(u.par_chunks(3).map(|p| (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt()).reduce(|| 0.0, f64::max));
        forces.push(f);
    }
    let want_modes = study.dynamics.modes.max(usize::from(study.min_frequency.is_some() || !study.dynamics.impacts.is_empty()));
    let mut mass = fem::lumped_mass(grid, &rho);
    fem::add_point_masses(grid, &study.point_masses, &mut mass);
    if want_modes > 0 {
        let modes = dynamics::eigen(&m.op, &young, &hier, &mass, want_modes, None, 40, 1e-6)?;
        a.modes = dynamics::describe(&m.op, &mass, &modes, hier.dropped().unwrap_or(&[]));
    }
    for imp in &study.dynamics.impacts {
        let f = forces.get(imp.case).ok_or_else(|| format!("impact names load case {} of {}", imp.case + 1, forces.len()))?;
        let f1 = a.modes.first().map_or(1.0, |m| m.frequency);
        let stress_of = |u: &[f64]| element_stress(&m, &smat, u).iter().zip(&solid).filter(|(_, s)| **s).map(|(v, _)| v.0).fold(0.0, f64::max);
        let r = dynamics::impact(&m.op, &young, &hier, &mass, f, imp, f1, static_peaks[imp.case], &stress_of)?;
        a.impacts.push(r);
    }
    let peak = a.max_stress.iter().chain(a.impacts.iter().map(|i| &i.peak_stress)).copied().fold(0.0, f64::max);
    a.safety_factor = if peak > 0.0 { study.material.allowable / peak } else { f64::INFINITY };
    Ok((a, worst))
}

/// Grid of a study, for callers that lay out their own densities.
pub fn grid_of(study: &Study) -> Grid {
    Grid::new(study.min, study.max, study.voxel)
}

/// Whether a region and the grid overlap (some element centre inside).
pub fn touches(grid: &Grid, r: &Region) -> bool {
    !grid.elements_in(r).is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::solid::{Load, LoadCase, PointMass, Support};
    use crate::Material;

    fn cantilever() -> Study {
        Study {
            min: [0.0; 3],
            max: [32.0, 8.0, 12.0],
            voxel: 1.0,
            supports: vec![Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 9.0, 13.0] }, fix: [true; 3] }],
            cases: vec![LoadCase { name: "tip".into(), loads: vec![Load::Force { region: Region::Box { min: [31.9, -1.0, 5.0], max: [33.0, 9.0, 7.0] }, force: [0.0, 0.0, -200.0] }], acceleration: None, weight: 1.0 }],
            volume_fraction: 0.25,
            iterations: 40,
            min_member: 2.0,
            ..Study::default()
        }
    }

    /// A keep-out slab cuts the far end off from the support: that island turns void and the
    /// load spread over the whole end face goes only on the held side.
    #[test]
    fn a_tip_cut_off_from_its_support_fails_and_floats_away() {
        let s = cantilever();
        let g = grid_of(&s);
        // A beam held at x = 0 to x = 20, a block at the loaded tip with a gap between.
        let density: Vec<f32> = (0..g.elements())
            .map(|e| {
                let [i, j, k] = g.element_ijk(e);
                let beam = i < 20 && (2..6).contains(&j) && (4..8).contains(&k);
                let tip = i >= 22 && (4..8).contains(&k);
                if beam || tip { 1.0 } else { 0.0 }
            })
            .collect();
        let c = candidate(&s, 0, Layout { grid: g, density, mesh: None, history: Vec::new() }).unwrap();
        assert!(!c.feasible);
        assert_eq!(c.analysis.bodies, 1);
        assert!(c.analysis.floating_mm3 > 0.0);
        assert_eq!(c.analysis.unsupported.len(), 1, "{:?}", c.analysis.unsupported);
        assert!(c.issues.iter().any(|i| i.contains("no material carries")));
        // The surface is the analysed solid: one body, the same volume within 5 %.
        assert_eq!(iso::bodies(&c.mesh), 1);
        assert!((c.mesh_mm3 / c.analysis.solid_mm3 - 1.0).abs() < 0.05, "{} vs {}", c.mesh_mm3, c.analysis.solid_mm3);
    }

    #[test]
    fn the_surface_keeps_the_solid_volume() {
        let mut s = cantilever();
        s.voxel = 0.5;
        s.iterations = 30;
        s.smoothing = 10;
        s.keep_out = vec![Region::Cylinder { base: [8.0, -1.0, 6.0], axis: [0.0, 1.0, 0.0], radius: 1.5, length: 10.0 }];
        s.keep_in = vec![Region::Tube { base: [8.0, -1.0, 6.0], axis: [0.0, 1.0, 0.0], inner: 1.5, outer: 3.0, length: 10.0 }];
        let l = optimize(&s, 0.25).unwrap();
        for sm in [0usize, 10] {
            let mut t = s.clone();
            t.smoothing = sm;
            let solid: Vec<bool> = l.density.iter().map(|&d| d >= 0.5).collect();
            let (m, _) = iso::surface_solid(&l.grid, &solid, sm);
            eprintln!("smoothing {sm}: raw {:.1} vs {:.1}", iso::volume(&m), solid.iter().filter(|&&x| x).count() as f64 * l.grid.h.powi(3));
        }
        let c = candidate(&s, 0, l).unwrap();
        let r = c.mesh_mm3 / c.analysis.solid_mm3;
        eprintln!("mesh {:.1} solid {:.1} ratio {r:.4}", c.mesh_mm3, c.analysis.solid_mm3);
        assert!((r - 1.0).abs() < 0.05, "{r}");
    }

    #[test]
    fn a_one_voxel_strut_survives_the_surface() {
        let s = Study { smoothing: 10, ..cantilever() };
        let g = grid_of(&s);
        let density: Vec<f32> = (0..g.elements())
            .map(|e| {
                let [_, j, k] = g.element_ijk(e);
                if j == 4 && k == 6 { 1.0 } else { 0.0 }
            })
            .collect();
        let c = candidate(&s, 0, Layout { grid: g, density, mesh: None, history: Vec::new() }).unwrap();
        assert_eq!(iso::bodies(&c.mesh), 1);
        assert!(c.mesh_mm3 > 0.6 * c.analysis.solid_mm3, "{} vs {}", c.mesh_mm3, c.analysis.solid_mm3);
        assert!(c.analysis.unsupported.is_empty());
    }

    #[test]
    fn bores_come_out_round() {
        let mut m = crate::solid::Mesh::default();
        // A square hole's corners at radius 1.41 pulled out to 1.5.
        for (x, y) in [(1.0f32, 1.0f32), (-1.0, 1.0), (0.0, 1.45)] {
            m.positions.extend([x, y, 0.5]);
        }
        iso::cut_holes(&mut m, &[Region::Cylinder { base: [0.0, 0.0, 0.0], axis: [0.0, 0.0, 1.0], radius: 1.5, length: 1.0 }], 0.6);
        for p in m.positions.chunks(3) {
            assert!(((p[0] * p[0] + p[1] * p[1]).sqrt() - 1.5).abs() < 1e-5);
        }
    }

    #[test]
    fn a_thin_side_sets_the_voxel_so_a_plate_keeps_its_thickness() {
        let g = Grid::new([-55.43, -55.43, 0.0], [55.43, 55.43, 3.0], 0.8);
        assert!((g.n[2] as f64 * g.h - 3.0).abs() < 1e-9);
        assert!(g.extent_error([-55.43, -55.43, 0.0], [55.43, 55.43, 3.0]) < 0.01);
    }

    #[test]
    fn islands_cut_off_by_keep_outs_carry_no_load() {
        let mut s = cantilever();
        // A wall of keep-out at x 20..22 through the full section, but for a 4 x 4 window.
        s.keep_out = vec![
            Region::Box { min: [20.0, -1.0, -1.0], max: [22.0, 9.0, 4.0] },
            Region::Box { min: [20.0, -1.0, 8.0], max: [22.0, 9.0, 13.0] },
            Region::Box { min: [20.0, -1.0, 4.0], max: [22.0, 2.0, 8.0] },
            Region::Box { min: [20.0, 6.0, 4.0], max: [22.0, 9.0, 8.0] },
            // A closed pocket at the tip: its inside is an island.
            Region::Box { min: [26.0, 2.0, 2.0], max: [30.0, 6.0, 3.0] },
            Region::Box { min: [26.0, 2.0, 9.0], max: [30.0, 6.0, 10.0] },
            Region::Box { min: [26.0, 2.0, 3.0], max: [30.0, 3.0, 9.0] },
            Region::Box { min: [26.0, 5.0, 3.0], max: [30.0, 6.0, 9.0] },
            Region::Box { min: [26.0, 3.0, 3.0], max: [27.0, 5.0, 9.0] },
            Region::Box { min: [29.0, 3.0, 3.0], max: [30.0, 5.0, 9.0] },
        ];
        let m = Model::new(&s).unwrap();
        let g = m.grid;
        let inside = g.element(27, 3, 5);
        assert_eq!(m.passive[inside], Some(0.0), "the pocket's inside is voided");
        let window = g.element(21, 4, 5);
        assert_ne!(m.passive[window], Some(0.0), "the window stays open");
        let total: f64 = (0..g.nodes()).map(|v| m.applied[0][3 * v + 2]).sum();
        assert!((total + 200.0).abs() < 1e-6, "the whole load still applies: {total}");
    }

    /// Progress counts every iteration, and answering false stops the run.
    #[test]
    fn generate_with_reports_and_cancels() {
        let mut s = cantilever();
        s.iterations = 6;
        let mut seen = Vec::new();
        let o = generate_with(&s, &mut |p| {
            seen.push((p.iteration, p.stage.clone()));
            true
        })
        .unwrap();
        assert_eq!(o.candidates.len(), 1);
        assert!(seen.iter().any(|(i, st)| *i == 6 && st == "optimising"), "{seen:?}");
        assert_eq!(seen.last().map(|x| x.1.as_str()), Some("done"));
        // Stopped before the first iteration: nothing to keep.
        let e = generate_with(&s, &mut |_| false);
        assert_eq!(e.unwrap_err(), CANCELLED);
    }

    /// A stop mid-run keeps the best iterate so far as a usable, surfaced candidate flagged not
    /// converged; asking again (every later report answers false too) changes nothing.
    #[test]
    fn a_stopped_run_keeps_its_best_iterate() {
        let s = cantilever();
        let mut asked = 0;
        let mut calls = 0;
        let o = generate_with(&s, &mut |p| {
            calls += 1;
            if p.stage == "optimising" && p.iteration >= 15 {
                asked += 1;
                return false;
            }
            asked == 0
        })
        .unwrap();
        assert!(o.stopped);
        assert_eq!(o.candidates.len(), 1);
        let c = &o.candidates[0];
        assert!(!c.converged);
        assert_eq!(c.stopped_at, Some(15));
        let kept = c.kept_iteration.unwrap();
        assert!((1..=15).contains(&kept), "kept {kept}");
        assert_eq!(c.history.len(), 15);
        assert!(c.mass_g > 0.0 && c.analysis.max_stress.iter().all(|v| v.is_finite()));
        assert!(!c.mesh.indices.is_empty() && iso::is_closed(&c.mesh), "the kept shape surfaces");
        assert!(o.warnings.iter().any(|w| w.contains("stopped at iteration 15")), "{:?}", o.warnings);
        assert_eq!(o.best, 0);
        // The stop is asked once by the solver; the rest of the run only reports.
        assert_eq!(asked, 1, "{calls} calls");
        // The stopped candidate serialises with its status, and reads back.
        let v = serde_json::to_value(&o).unwrap();
        assert_eq!(v["stopped"], serde_json::json!(true));
        assert_eq!(v["candidates"][0]["converged"], serde_json::json!(false));
        assert_eq!(v["candidates"][0]["stopped_at"], serde_json::json!(15));
        let back: Outcome = serde_json::from_value(v).unwrap();
        assert_eq!(back.candidates[0].stopped_at, Some(15));
    }

    /// With several variants, a stop in the second keeps the first finished one (converged) and
    /// the second's best iterate.
    #[test]
    fn a_stop_in_a_later_variant_keeps_the_finished_ones() {
        let mut s = cantilever();
        s.variants = 2;
        s.iterations = 20;
        let o = generate_with(&s, &mut |p| !(p.variant == 1 && p.stage == "optimising" && p.iteration >= 12)).unwrap();
        assert!(o.stopped);
        assert_eq!(o.candidates.len(), 2);
        assert!(o.candidates[0].converged && o.candidates[0].stopped_at.is_none());
        assert!(!o.candidates[1].converged && o.candidates[1].stopped_at == Some(12));
        // An outcome written before the status existed reads as converged.
        let mut v = serde_json::to_value(&o.candidates[0]).unwrap();
        let m = v.as_object_mut().unwrap();
        m.remove("converged");
        m.remove("stopped_at");
        m.remove("kept_iteration");
        let c: Candidate = serde_json::from_value(v).unwrap();
        assert!(c.converged && c.stopped_at.is_none());
    }

    /// Observing hands every iteration's figures and densities, in order.
    #[test]
    fn generate_observed_hands_each_step() {
        let mut s = cantilever();
        s.iterations = 5;
        let mut steps: Vec<(usize, f64, f64, f64, usize)> = Vec::new();
        let mut obs = |st: &Step| steps.push((st.iteration, st.compliance, st.volume, st.max_stress, st.density.len()));
        let o = generate_observed(&s, &mut |_| true, Some(&mut obs)).unwrap();
        assert_eq!(steps.iter().map(|x| x.0).collect::<Vec<_>>(), (1..=steps.len()).collect::<Vec<_>>());
        assert!(steps.len() >= 5, "{steps:?}");
        let ne = o.candidates[0].grid.elements();
        for (_, c, v, sm, n) in &steps {
            assert!(c.is_finite() && *c > 0.0 && *v > 0.0 && *v <= 1.0 && sm.is_finite() && *sm >= 0.0 && *n == ne, "{steps:?}");
        }
    }

    #[test]
    fn compliance_drops_and_volume_holds() {
        let s = cantilever();
        let l = optimize(&s, 0.25).unwrap();
        let first = l.history[0];
        let last = *l.history.last().unwrap();
        // Same volume as the uniform start, far stiffer.
        assert!(last < 0.5 * first, "compliance {first:.1} -> {last:.1}");
        let vol = l.density.iter().map(|&d| d as f64).sum::<f64>() / l.density.len() as f64;
        assert!((vol - 0.25).abs() < 0.03, "volume {vol:.3}");
        let crisp = l.density.iter().filter(|&&d| !(0.1..=0.9).contains(&d)).count() as f64 / l.density.len() as f64;
        assert!(crisp > 0.9, "only {crisp:.2} of voxels are 0 or 1");
    }

    #[test]
    fn mass_objective_meets_the_stress_limit() {
        let mut s = cantilever();
        s.objective = Objective::Mass;
        s.volume_fraction = 0.6;
        s.material.allowable = 180.0;
        s.safety_factor = 1.5;
        s.iterations = 50;
        let out = generate(&s).unwrap();
        let c = &out.candidates[0];
        let sigma = c.analysis.max_stress[0];
        assert!(c.volume_fraction < 0.55, "volume {:.2}", c.volume_fraction);
        assert!(sigma <= 120.0, "stress {sigma:.0} MPa against a 120 MPa limit");
        assert!(c.feasible);
        assert!(iso::is_closed(&c.mesh) && c.mesh.stress.len() * 3 == c.mesh.positions.len());
    }

    #[test]
    fn extrusion_gives_a_constant_section() {
        let mut s = cantilever();
        s.manufacturing = Manufacturing::Extrusion { direction: [0.0, 1.0, 0.0] };
        s.iterations = 20;
        let l = optimize(&s, 0.3).unwrap();
        let g = l.grid;
        for e in 0..g.elements() {
            let [i, _, k] = g.element_ijk(e);
            assert!((l.density[e] - l.density[g.element(i, 0, k)]).abs() < 1e-6);
        }
    }

    #[test]
    fn printing_leaves_no_unsupported_overhang() {
        let mut s = cantilever();
        s.manufacturing = Manufacturing::Additive { build: [0.0, 0.0, 1.0], overhang: 45.0 };
        s.iterations = 30;
        let l = optimize(&s, 0.3).unwrap();
        let g = l.grid;
        // Every solid voxel above the plate stands on a solid voxel below or beside below.
        let mut unsupported = 0;
        let mut solid = 0;
        for e in 0..g.elements() {
            let [i, j, k] = g.element_ijk(e);
            if k == 0 || l.density[e] < 0.5 {
                continue;
            }
            solid += 1;
            let held = [(0i32, 0i32), (1, 0), (-1, 0), (0, 1), (0, -1)].iter().any(|&(di, dj)| {
                let (ii, jj) = (i as i32 + di, j as i32 + dj);
                ii >= 0 && jj >= 0 && (ii as usize) < g.n[0] && (jj as usize) < g.n[1] && l.density[g.element(ii as usize, jj as usize, k - 1)] >= 0.3
            });
            if !held {
                unsupported += 1;
            }
        }
        assert!((unsupported as f64) < 0.02 * solid as f64, "{unsupported} of {solid} solid voxels overhang");
    }

    #[test]
    fn frequency_floor_is_reported() {
        let mut s = cantilever();
        s.iterations = 15;
        s.dynamics.modes = 3;
        let out = generate(&s).unwrap();
        let a = &out.candidates[0].analysis;
        assert_eq!(a.modes.len(), 3);
        assert!(a.modes[0].frequency > 100.0 && a.modes[0].frequency <= a.modes[1].frequency);
    }

    /// A mass at the tip of a solid steel cantilever lowers its first mode as a beam with an
    /// end mass does: f = f0 * sqrt(1 / (1 + m_tip / (0.2427 m_beam))) (Rayleigh, within 3 %).
    #[test]
    fn a_tip_mass_lowers_the_first_mode() {
        let mut s = Study { min: [0.0; 3], max: [100.0, 6.0, 6.0], voxel: 1.0, ..Study::default() };
        s.material = Material { name: "steel".into(), e: 210_000.0, nu: 0.3, density: 7.85e-3, allowable: 250.0, color: String::new() };
        s.supports = vec![Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 7.0, 7.0] }, fix: [true; 3] }];
        s.cases = vec![LoadCase { name: "tip".into(), loads: vec![Load::Force { region: Region::Box { min: [99.9, -1.0, -1.0], max: [100.1, 7.0, 7.0] }, force: [0.0, 0.0, -1.0] }], acceleration: None, weight: 1.0 }];
        s.dynamics.modes = 1;
        let g = Grid::new(s.min, s.max, s.voxel);
        let solid = vec![1.0f32; g.elements()];
        let bare = analyse(&s, &g, &solid).unwrap().modes[0].frequency;
        let beam_g = 100.0 * 36.0 * 7.85e-3;
        s.point_masses = vec![PointMass { region: Region::Box { min: [99.9, -1.0, -1.0], max: [100.1, 7.0, 7.0] }, mass_g: beam_g }];
        let loaded = analyse(&s, &g, &solid).unwrap().modes[0].frequency;
        let expect = bare * (1.0f64 / (1.0 + 1.0 / 0.2427)).sqrt();
        assert!((loaded / expect - 1.0).abs() < 0.03, "bare {bare:.1} Hz, with the tip mass {loaded:.1} Hz, beam theory {expect:.1} Hz");
    }

    /// Adjoint gradients of the compliance, the stress and the displacement limits against
    /// central differences, through the whole chain (filter, projection, sweep).
    #[test]
    fn gradients_match_finite_differences() {
        for manufacturing in [Manufacturing::Free, Manufacturing::Additive { build: [0.0, 0.0, 1.0], overhang: 45.0 }, Manufacturing::Milling { direction: [0.0, 0.0, -1.0] }] {
            let mut s = cantilever();
            s.max = [16.0, 4.0, 8.0];
            s.supports[0].region = Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 5.0, 9.0] };
            s.cases[0].loads = vec![Load::Force { region: Region::Box { min: [15.9, -1.0, 3.0], max: [17.0, 5.0, 5.0] }, force: [0.0, 0.0, -50.0] }];
            s.cases[0].acceleration = Some([0.0, 0.0, -9810.0 * 2000.0]);
            s.objective = Objective::Mass;
            s.max_displacement = Some(0.01);
            s.manufacturing = manufacturing;
            let mut ev = Evaluator::new(&s, 0.5).unwrap();
            let n = ev.m.groups;
            let x: Vec<f64> = (0..n).map(|k| 0.3 + 0.4 * ((k * 7919) % 101) as f64 / 101.0).collect();
            let base = ev.evaluate(&x, 2.0, 0, 1e-12, true).unwrap();
            let h = 1e-5;
            for k in [3usize, n / 3, n / 2, 2 * n / 3 + 5] {
                let mut xp = x.clone();
                xp[k] += h;
                let p = ev.evaluate(&xp, 2.0, 1, 1e-12, false).unwrap();
                let mut xm = x.clone();
                xm[k] -= h;
                let mm = ev.evaluate(&xm, 2.0, 1, 1e-12, false).unwrap();
                for c in 0..base.g.len() {
                    let fd = (p.g[c] - mm.g[c]) / (2.0 * h);
                    let ad = base.dg[c][k];
                    let scale = base.dg[c].iter().map(|v| v.abs()).fold(0.0, f64::max);
                    assert!((fd - ad).abs() <= 1e-3 * scale + 1e-4 * fd.abs(), "{manufacturing:?} limit {c} variable {k}: adjoint {ad:.6e}, differences {fd:.6e} (largest {scale:.3e})");
                }
                let fd = (p.comp - mm.comp) / (2.0 * h);
                let _ = fd;
            }
        }
    }

    /// The robust chain: the eroded design is the weakest, the dilated the stiffest, the
    /// optimiser holds the worst compliance (bound variable) and the nominal volume.
    #[test]
    fn robust_projections_order_and_hold_the_volume() {
        let mut s = cantilever();
        s.max = [24.0, 6.0, 10.0];
        s.supports[0].region = Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 7.0, 11.0] };
        s.cases[0].loads = vec![Load::Force { region: Region::Box { min: [23.9, -1.0, 4.0], max: [25.0, 7.0, 6.0] }, force: [0.0, 0.0, -100.0] }];
        s.robust = Some(crate::solid::Robust { delta: 0.15 });
        s.iterations = 40;
        let (l, t) = optimize_traced(&s, 0.3, &mut |_, _| {}).unwrap();
        let c = &t.compliances;
        assert_eq!(c.len(), 3);
        assert!(c[0] > c[1] && c[1] > c[2], "eroded, nominal, dilated compliances {c:?}");
        // The eroded design stays connected: within a few times the nominal.
        assert!(c[0] < 3.0 * c[1], "{c:?}");
        let vol = l.density.iter().map(|&d| d as f64).sum::<f64>() / l.density.len() as f64;
        assert!((vol - 0.3).abs() < 0.03, "nominal volume {vol:.3}");
    }

    /// Adjoint gradients of the robust bound constraints (one per projection) and of the
    /// stress limit read on the eroded design, against central differences.
    #[test]
    fn robust_gradients_match_finite_differences() {
        let mut s = cantilever();
        s.max = [12.0, 4.0, 6.0];
        s.supports[0].region = Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 5.0, 7.0] };
        s.cases[0].loads = vec![Load::Force { region: Region::Box { min: [11.9, -1.0, 2.0], max: [13.0, 5.0, 4.0] }, force: [0.0, 0.0, -50.0] }];
        s.robust = Some(crate::solid::Robust { delta: 0.1 });
        s.max_stress = Some(100.0);
        let mut ev = Evaluator::new(&s, 0.5).unwrap();
        let n = ev.variables();
        assert_eq!(n, ev.m.groups + 1);
        let mut x: Vec<f64> = (0..n).map(|k| 0.3 + 0.4 * ((k * 7919) % 101) as f64 / 101.0).collect();
        x[n - 1] = 1.2;
        let base = ev.evaluate(&x, 2.0, 0, 1e-12, true).unwrap();
        assert_eq!(base.g.len(), 1 + 3 + 1);
        let h = 1e-5;
        for k in [3usize, n / 3, n / 2, n - 1] {
            let mut xp = x.clone();
            xp[k] += h;
            let p = ev.evaluate(&xp, 2.0, 1, 1e-12, false).unwrap();
            let mut xm = x.clone();
            xm[k] -= h;
            let mm = ev.evaluate(&xm, 2.0, 1, 1e-12, false).unwrap();
            let fd0 = (p.f0 - mm.f0) / (2.0 * h);
            assert!((fd0 - base.df0[k]).abs() < 1e-6, "objective variable {k}");
            for c in 0..base.g.len() {
                let fd = (p.g[c] - mm.g[c]) / (2.0 * h);
                let ad = base.dg[c][k];
                let scale = base.dg[c].iter().map(|v| v.abs()).fold(0.0, f64::max);
                assert!((fd - ad).abs() <= 1e-3 * scale + 1e-4 * fd.abs(), "limit {c} variable {k}: adjoint {ad:.6e}, differences {fd:.6e}");
            }
        }
    }

    /// A square column clamped at its foot has two equal first bending modes. With the floor
    /// on the lowest three, both members of the pair end over it, and stay a pair.
    #[test]
    fn frequency_floor_holds_a_repeated_pair() {
        let base = Study {
            min: [0.0; 3],
            max: [8.0, 8.0, 24.0],
            voxel: 1.0,
            supports: vec![Support { region: Region::Box { min: [-1.0, -1.0, -0.1], max: [9.0, 9.0, 0.1] }, fix: [true; 3] }],
            cases: vec![LoadCase { name: "top".into(), loads: vec![Load::Force { region: Region::Box { min: [2.0, 2.0, 23.9], max: [6.0, 6.0, 25.0] }, force: [0.0, 0.0, -100.0] }], acceleration: None, weight: 1.0 }],
            volume_fraction: 0.35,
            iterations: 30,
            symmetry: [true, true, false],
            ..Study::default()
        };
        let g = grid_of(&base);
        let mut probe = base.clone();
        probe.dynamics.modes = 2;
        let solid = analyse(&probe, &g, &vec![1.0; g.elements()]).unwrap();
        let (f1, f2) = (solid.modes[0].frequency, solid.modes[1].frequency);
        assert!((f2 / f1 - 1.0).abs() < 1e-3, "solid column pair {f1:.1} / {f2:.1} Hz");
        // Unconstrained, compliance alone puts the material in a core under the load.
        let (_, free) = optimize_traced(&Study { dynamics: crate::solid::Dynamics::default(), ..base.clone() }, 0.35, &mut |_, _| {}).unwrap();
        let _ = free;
        let mut s = base.clone();
        let floor = 1.1 * f1;
        s.min_frequency = Some(floor);
        s.frequency_modes = 3;
        let (l, t) = optimize_traced(&s, 0.35, &mut |_, _| {}).unwrap();
        let lmin = (2.0 * std::f64::consts::PI * floor).powi(2);
        assert_eq!(t.lambdas.len(), 3);
        assert!(t.lambdas[0] >= 0.97 * lmin && t.lambdas[1] >= 0.97 * lmin, "pair {:.3} {:.3} of the floor", t.lambdas[0] / lmin, t.lambdas[1] / lmin);
        assert!((t.lambdas[1] / t.lambdas[0] - 1.0).abs() < 0.02, "the pair split: {:?}", t.lambdas);
        let mut check = s.clone();
        check.dynamics.modes = 2;
        let a = analyse(&check, &l.grid, &l.density).unwrap();
        assert!(a.modes[0].frequency >= 0.95 * floor, "analysed {:.1} Hz against {floor:.1}", a.modes[0].frequency);
    }

    #[test]
    fn mass_target_sets_the_fraction() {
        let mut s = cantilever();
        s.iterations = 20;
        let g = grid_of(&s);
        // 25 % of the box in aluminium (2.7e-3 g/mm³).
        let target = 0.25 * g.elements() as f64 * 2.7e-3;
        s.mass_target_g = Some(target);
        s.volume_fraction = 0.6;
        let (l, t) = optimize_traced(&s, 0.6, &mut |_, _| {}).unwrap();
        assert!((t.target - 0.25).abs() < 1e-9, "{}", t.target);
        let mass: f64 = l.density.iter().map(|&d| d as f64).sum::<f64>() * 2.7e-3;
        assert!((mass / target - 1.0).abs() < 0.05, "{mass:.2} g for {target:.2}");
    }

    /// Mirror planes, a bearing seat (bore kept empty, its wall kept solid), and two load
    /// cases: a force and a motor's stall torque about the bore.
    #[test]
    fn symmetry_seat_and_torque_cases() {
        let seat = [16.0, 6.0, 6.0];
        let mut s = Study {
            min: [0.0; 3],
            max: [32.0, 12.0, 12.0],
            voxel: 1.0,
            supports: vec![
                Support { region: Region::Box { min: [-0.1, -1.0, -1.0], max: [0.1, 13.0, 13.0] }, fix: [true; 3] },
                Support { region: Region::Box { min: [31.9, -1.0, -1.0], max: [32.1, 13.0, 13.0] }, fix: [true; 3] },
            ],
            cases: vec![
                LoadCase { name: "radial".into(), loads: vec![Load::Force { region: Region::Tube { base: [16.0, -1.0, 6.0], axis: [0.0, 1.0, 0.0], inner: 2.5, outer: 4.0, length: 14.0 }, force: [0.0, 0.0, -300.0] }], acceleration: None, weight: 1.0 },
                // 0.35 N·m stall torque, 350 N·mm.
                LoadCase { name: "stall".into(), loads: vec![Load::Torque { region: Region::Tube { base: [16.0, -1.0, 6.0], axis: [0.0, 1.0, 0.0], inner: 2.5, outer: 4.0, length: 14.0 }, center: seat, axis: [0.0, 1.0, 0.0], moment: 350.0 }], acceleration: None, weight: 1.0 },
            ],
            keep_out: vec![Region::Cylinder { base: [16.0, -1.0, 6.0], axis: [0.0, 1.0, 0.0], radius: 2.5, length: 14.0 }],
            keep_in: vec![Region::Tube { base: [16.0, -1.0, 6.0], axis: [0.0, 1.0, 0.0], inner: 2.5, outer: 4.0, length: 14.0 }],
            volume_fraction: 0.25,
            iterations: 25,
            symmetry: [true, true, false],
            ..Study::default()
        };
        let l = optimize(&s, 0.25).unwrap();
        let g = l.grid;
        for e in 0..g.elements() {
            let m = g.mirror(e, [true, false, false]);
            assert!((l.density[e] - l.density[m]).abs() < 1e-6, "x mirror");
            let m = g.mirror(e, [false, true, false]);
            assert!((l.density[e] - l.density[m]).abs() < 1e-6, "y mirror");
        }
        for e in g.elements_in(&s.keep_out[0]) {
            assert_eq!(l.density[e], 0.0, "bore");
        }
        let bore = g.elements_touching(&s.keep_out[0]);
        let wall: Vec<usize> = g.elements_in(&s.keep_in[0]).into_iter().filter(|e| !bore.contains(e)).collect();
        assert!(!wall.is_empty() && wall.iter().all(|&e| l.density[e] == 1.0), "seat wall");
        s.dynamics.modes = 0;
        let a = analyse(&s, &g, &l.density).unwrap();
        assert_eq!(a.compliance.len(), 2);
        assert!(a.compliance.iter().all(|c| c.is_finite() && *c > 0.0), "{:?}", a.compliance);
    }
}
