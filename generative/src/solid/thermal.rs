//! Steady heat conduction on the voxel grid, thermal topology optimisation and thermal stress.
//!
//! Model. The same cubic voxels as the elastic model, each an eight-node trilinear hexahedron
//! with one temperature per node. One 8x8 conduction matrix (for k = 1, `h ∫ ∇Nᵀ∇N`, exact with
//! 2x2x2 Gauss) serves every voxel, scaled by its conductivity. Heat leaves through:
//!
//! - fixed temperatures (a heat sink base, a cold plate): nodes in a region, eliminated;
//! - convection to an ambient temperature (Robin): `q = h (T - T_amb)` on the faces of the
//!   design box whose centres lie in a region (all six sides when none is given), with the
//!   consistent 4x4 face matrix `h a²/36 [(1 + δ)(1 + δ)]` and the load `h T_amb a²/4` per
//!   node. This convection does not follow the design: it acts on the box's faces whether a
//!   voxel there is solid or void (a cold plate or a fan duct on the base). Design-dependent
//!   convection (on the faces the layout itself exposes, as for fins, after Yoon and Kim 2005
//!   or Coffin and Maute 2016) is not built yet;
//! - heat sources, W: spread over the elements whose centre lies in the region (a motor, a
//!   regulator, a whole plate's uniform generation), an eighth of each element's share on each
//!   corner, so a uniform source is the consistent load of a constant field.
//!
//! Units follow the engine: mm, W, K (or °C, the problem is linear), conductivity W/(mm K) and
//! film coefficients W/(mm² K) inside; the study gives W/(m K) and W/(m² K), converted at the
//! boundary ([`conductivity_mm`], [`film_mm`]).
//!
//! Solver. The product `K T` is matrix-free and gathered by node row in parallel, as in
//! [`super::fem`]: no two threads write one entry and every sum runs in a fixed order, so a
//! solve gives the same bits on any number of cores. Conjugate gradients are preconditioned by
//! one geometric multigrid V-cycle: two-to-one coarsening on every axis that has two cells or
//! more, trilinear prolongation, Galerkin coarse operators (`Pᵀ A P` on 27-point stencils, the
//! fine one assembled from the elements and the convection faces), Chebyshev smoothing of degree
//! three on `D⁻¹A` up to its Gershgorin bound, and a banded Cholesky solve on the coarsest level.
//!
//! Optimisation. SIMP conductivity `k = k0 (kmin + ρ^p (1 - kmin))` (kmin 1e-3, p 3 by
//! default) on the same design chain as the elastic studies: symmetry groups, density filter,
//! Heaviside projection, keep-in and keep-out voxels and the printing and milling sweeps
//! ([`super::optimize::Model`]), with MMA. Objectives:
//!
//! - compliance: least thermal compliance `c = qᵀ(T - T_ref)` (the heat-weighted mean
//!   temperature rise times the power) for a volume fraction;
//! - mass: least volume under the temperature limit, read as a p-norm (p 16) of the nodal
//!   temperature rise, rescaled each iteration to the true peak (as the stress limit is).
//!
//! Both gradients are adjoint: `dc/dρ_e = -λ_eᵀ (dk_e K₁) T_e` with `K λ = q` (λ is the rise
//! itself when every boundary temperature is the reference one).
//!
//! Thermal stress. A temperature field loads the elastic model through the thermal strain
//! `α (T - T_0)`: element forces `E α G θ_e` ([`super::fem::thermal_coupling`]) gathered per
//! node, and the stress is `σ = E (B u - α θ m)` with `D m` on the normal components.

#![allow(clippy::needless_range_loop)] // stencil algebra reads best indexed

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use super::fem::{self, Operator, SolveStats};
use super::mma::Mma;
use super::optimize::Model;
use super::{Grid, Mesh, Region, Study, iso, loads};

/// Reduction chunk: fixed, so sums do not depend on the thread count.
const CHUNK: usize = 1 << 13;
/// The coarsest level holds at most this many nodes (banded Cholesky there).
const COARSE_NODES: usize = 1500;
/// Chebyshev degree, and the share of the spectrum it aims at (`[hi / RATIO, hi]`).
const DEGREE: usize = 3;
const RATIO: f64 = 8.0;
/// p-norm exponent of the temperature limit.
pub const TEMPERATURE_P: f64 = 16.0;
/// The optimiser aims under the temperature limit by this share.
const TEMPERATURE_MARGIN: f64 = 0.98;
/// Stiffness floor of void in the thermal stress analysis.
const EMIN: f64 = 1e-9;

/// W/(m K) to W/(mm K).
pub fn conductivity_mm(k_w_per_m_k: f64) -> f64 {
    k_w_per_m_k * 1e-3
}

/// W/(m² K) to W/(mm² K).
pub fn film_mm(h_w_per_m2_k: f64) -> f64 {
    h_w_per_m2_k * 1e-6
}

// ---------------------------------------------------------------------------------------------
// Study block

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThermalObjective {
    /// Least thermal compliance (heat-weighted mean temperature) for the volume fraction.
    #[default]
    Compliance,
    /// Least mass that keeps the maximum temperature under `max_temperature`.
    Mass,
}

/// Heat generated in a region, W.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct HeatSource {
    pub region: Region,
    pub power: f64,
}

/// Convection to an ambient temperature on the design box's faces whose centres lie in
/// `region` (every face when none).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Convection {
    #[serde(default)]
    pub region: Option<Region>,
    /// Film coefficient, W/(m² K): about 5 to 25 still air, 25 to 250 forced air.
    pub h: f64,
    /// °C; default: the study's ambient.
    #[serde(default)]
    pub ambient: Option<f64>,
}

/// A region held at a temperature, °C (a heat sink base on a cold plate).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct FixedTemperature {
    pub region: Region,
    pub temperature: f64,
}

/// The thermal side of a study ([`Study::thermal`]).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Thermal {
    pub objective: ThermalObjective,
    /// Conductivity, W/(m K); default: the material's ([`crate::Material::thermal`]).
    pub conductivity: Option<f64>,
    /// Thermal expansion, 1/K; default: the material's.
    pub expansion: Option<f64>,
    /// Ambient temperature, °C.
    pub ambient: f64,
    pub sources: Vec<HeatSource>,
    pub convection: Vec<Convection>,
    pub fixed: Vec<FixedTemperature>,
    /// Maximum temperature anywhere, °C: the mass objective's limit, a constraint on the
    /// compliance objective when set.
    pub max_temperature: Option<f64>,
    /// SIMP exponent of the conductivity.
    pub penal: f64,
    /// Void conductivity over the solid's.
    pub kmin: f64,
    /// Analyse the result's thermal stress (needs the study's supports): the temperature rise
    /// over `stress_free` loads the elastic model.
    pub stress: bool,
    /// Stress-free temperature, °C; default: the ambient.
    pub stress_free: Option<f64>,
}

impl Default for Thermal {
    fn default() -> Self {
        Self {
            objective: ThermalObjective::Compliance,
            conductivity: None,
            expansion: None,
            ambient: 25.0,
            sources: Vec::new(),
            convection: Vec::new(),
            fixed: Vec::new(),
            max_temperature: None,
            penal: 3.0,
            kmin: 1e-3,
            stress: false,
            stress_free: None,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Element

/// Standard corner `s` in lexicographic order (x fastest); the map is its own inverse.
const LEX: [usize; 8] = [0, 1, 3, 2, 4, 5, 7, 6];

/// The conduction matrix of a cube of edge `h` for k = 1, lexicographic corner order.
fn conduction_lex(h: f64) -> [[f64; 8]; 8] {
    let g = 1.0 / 3f64.sqrt();
    let w = (h / 2.0).powi(3);
    let mut k = [[0.0; 8]; 8];
    for q in 0..8 {
        let p = [0, 1, 2].map(|a| if (q >> a) & 1 == 1 { g } else { -g });
        let grad: [[f64; 3]; 8] = std::array::from_fn(|l| {
            let s = [0, 1, 2].map(|a| if (l >> a) & 1 == 1 { 1.0 } else { -1.0 });
            let f = [0, 1, 2].map(|a| 0.5 * (1.0 + s[a] * p[a]));
            [s[0] / h * f[1] * f[2], s[1] / h * f[0] * f[2], s[2] / h * f[0] * f[1]]
        });
        for i in 0..8 {
            for j in 0..8 {
                k[i][j] += w * (0..3).map(|a| grad[i][a] * grad[j][a]).sum::<f64>();
            }
        }
    }
    k
}

/// The 8x8 conduction matrix of a cube of edge `h` for k = 1, nodes in the grid's standard
/// corner order ([`Grid::element_nodes`]). Closed form: `h Σ_axes s Π m`, with the 1D stiffness
/// `s = ±1` and mass `m = 1/3` (same coordinate) or `1/6`: 1/3 on the diagonal, 0 between
/// corners on one edge, -1/12 across a face or the body. Scales with `h`.
pub fn element_conduction(h: f64) -> [[f64; 8]; 8] {
    let lex = conduction_lex(h);
    let mut k = [[0.0; 8]; 8];
    for a in 0..8 {
        for b in 0..8 {
            k[a][b] = lex[LEX[a]][LEX[b]];
        }
    }
    k
}

// ---------------------------------------------------------------------------------------------
// Operator

/// The faces normal to axis `a`: planes along `a`, cells along the other two.
fn face_dims(n: [usize; 3], a: usize) -> [usize; 3] {
    let mut d = n;
    d[a] += 1;
    d
}

fn face_index(d: [usize; 3], f: [usize; 3]) -> usize {
    f[0] + d[0] * (f[1] + d[1] * f[2])
}

fn others(a: usize) -> (usize, usize) {
    match a {
        0 => (1, 2),
        1 => (0, 2),
        _ => (0, 1),
    }
}

/// The conduction operator of one grid: fixed nodes and convection faces.
#[derive(Clone)]
pub struct Conduction {
    pub grid: Grid,
    /// Per node: temperature prescribed.
    pub fixed: Vec<bool>,
    lex: [[f64; 8]; 8],
    /// Film coefficient per face, W/(mm² K): `film[a]` holds the faces normal to axis `a`
    /// ([`face_dims`]).
    film: [Vec<f64>; 3],
    /// Per node row `(j, k)`: some convection face touches it.
    conv_row: Vec<bool>,
}

impl Conduction {
    /// `film[a]` must have one entry per face normal to axis `a` (empty: none).
    pub fn new(grid: Grid, fixed: Vec<bool>, film: [Vec<f64>; 3]) -> Self {
        let n = grid.n;
        let film: [Vec<f64>; 3] = std::array::from_fn(|a| {
            let d = face_dims(n, a);
            if film[a].len() == d[0] * d[1] * d[2] { film[a].clone() } else { vec![0.0; d[0] * d[1] * d[2]] }
        });
        let (ny, nz) = (n[1] + 1, n[2] + 1);
        let mut conv_row = vec![false; ny * nz];
        for a in 0..3 {
            let d = face_dims(n, a);
            for f2 in 0..d[2] {
                for f1 in 0..d[1] {
                    for f0 in 0..d[0] {
                        if film[a][face_index(d, [f0, f1, f2])] == 0.0 {
                            continue;
                        }
                        let f = [f0, f1, f2];
                        // The face's nodes span its cell on the two other axes.
                        let (jr, kr) = match a {
                            1 => (f[1]..=f[1], f[2]..=f[2] + 1),
                            2 => (f[1]..=f[1] + 1, f[2]..=f[2]),
                            _ => (f[1]..=f[1] + 1, f[2]..=f[2] + 1),
                        };
                        for k in kr.clone() {
                            for j in jr.clone() {
                                conv_row[j + ny * k] = true;
                            }
                        }
                    }
                }
            }
        }
        Self { grid, fixed, lex: conduction_lex(grid.h), film, conv_row }
    }

    /// Convection's part of row `p` of `K t`.
    fn convect(&self, p: [usize; 3], t: &[f64]) -> f64 {
        let n = self.grid.n;
        let w = self.grid.h * self.grid.h / 36.0;
        let mut s = 0.0;
        for a in 0..3 {
            let (b, c) = others(a);
            let d = face_dims(n, a);
            for cc in p[c].saturating_sub(1)..=p[c].min(n[c] - 1) {
                for cb in p[b].saturating_sub(1)..=p[b].min(n[b] - 1) {
                    let mut f = [0; 3];
                    f[a] = p[a];
                    f[b] = cb;
                    f[c] = cc;
                    let film = self.film[a][face_index(d, f)];
                    if film == 0.0 {
                        continue;
                    }
                    let mut acc = 0.0;
                    for dc in 0..2 {
                        for db in 0..2 {
                            let mut q = [0; 3];
                            q[a] = p[a];
                            q[b] = cb + db;
                            q[c] = cc + dc;
                            let wb = if q[b] == p[b] { 2.0 } else { 1.0 };
                            let wc = if q[c] == p[c] { 2.0 } else { 1.0 };
                            acc += wb * wc * t[self.grid.node(q[0], q[1], q[2])];
                        }
                    }
                    s += film * w * acc;
                }
            }
        }
        s
    }

    /// `out = K(kappa) t` on every row, fixed ones included (no elimination). `kappa`: per
    /// element conductivity, W/(mm K).
    pub fn apply_raw(&self, kappa: &[f64], t: &[f64], out: &mut [f64]) {
        let g = &self.grid;
        let [nx, ny, nz] = g.n;
        let (sx, sxy) = (nx + 1, (nx + 1) * (ny + 1));
        if kappa.len() != g.elements() || t.len() != g.nodes() || out.len() != g.nodes() {
            out.fill(f64::NAN);
            return;
        }
        let lex = &self.lex;
        out.par_chunks_mut(sx).enumerate().for_each(|(row, o)| {
            let (j, k) = (row % (ny + 1), row / (ny + 1));
            o.fill(0.0);
            for ez in k.saturating_sub(1)..=k.min(nz - 1) {
                for ey in j.saturating_sub(1)..=j.min(ny - 1) {
                    let q = (j - ey) + 2 * (k - ez);
                    let (r0, r1) = (&lex[2 * q], &lex[2 * q + 1]);
                    let first = nx * (ey + ny * ez);
                    let n0 = sx * ey + sxy * ez;
                    for (ei, &kap) in kappa[first..first + nx].iter().enumerate() {
                        if kap == 0.0 {
                            continue;
                        }
                        let b = n0 + ei;
                        let te = [t[b], t[b + 1], t[b + sx], t[b + sx + 1], t[b + sxy], t[b + sxy + 1], t[b + sxy + sx], t[b + sxy + sx + 1]];
                        let (mut a0, mut a1) = (0.0, 0.0);
                        for c in 0..8 {
                            a0 = r0[c].mul_add(te[c], a0);
                            a1 = r1[c].mul_add(te[c], a1);
                        }
                        o[ei] = a0.mul_add(kap, o[ei]);
                        o[ei + 1] = a1.mul_add(kap, o[ei + 1]);
                    }
                }
            }
            if self.conv_row[row] {
                for (i, v) in o.iter_mut().enumerate() {
                    *v += self.convect([i, j, k], t);
                }
            }
        });
    }

    /// `out = K t` on the free rows (zero on fixed ones); `t` must be zero on fixed nodes.
    pub fn apply_free(&self, kappa: &[f64], t: &[f64], out: &mut [f64]) {
        self.apply_raw(kappa, t, out);
        out.par_iter_mut().zip(self.fixed.par_iter()).for_each(|(o, &f)| {
            if f {
                *o = 0.0;
            }
        });
    }

    /// `out = K t` with fixed rows and columns as the identity (as [`fem::Operator::apply`]).
    pub fn apply(&self, kappa: &[f64], t: &[f64], out: &mut [f64]) {
        let clean: Vec<f64> = t.par_iter().zip(self.fixed.par_iter()).map(|(&x, &f)| if f { 0.0 } else { x }).collect();
        self.apply_free(kappa, &clean, out);
        out.par_iter_mut().zip(t.par_iter()).zip(self.fixed.par_iter()).for_each(|((o, &x), &f)| {
            if f {
                *o = x;
            }
        });
    }

    /// Per element, `a_eᵀ K₁ b_e` for k = 1 (the sensitivities' core).
    pub fn cross(&self, a: &[f64], b: &[f64], out: &mut [f64]) {
        let g = &self.grid;
        let [nx, ny, _] = g.n;
        let (sx, sxy) = (nx + 1, (nx + 1) * (ny + 1));
        let lex = &self.lex;
        out.par_chunks_mut(nx).enumerate().for_each(|(row, o)| {
            let n0 = sx * (row % ny) + sxy * (row / ny);
            for (ei, v) in o.iter_mut().enumerate() {
                let p = n0 + ei;
                let idx = [p, p + 1, p + sx, p + sx + 1, p + sxy, p + sxy + 1, p + sxy + sx, p + sxy + sx + 1];
                let mut s = 0.0;
                for i in 0..8 {
                    let mut t = 0.0;
                    for j in 0..8 {
                        t = lex[i][j].mul_add(b[idx[j]], t);
                    }
                    s = a[idx[i]].mul_add(t, s);
                }
                *v = s;
            }
        });
    }

    /// The 27-point stencil of `K(kappa)` per node (`(dx+1) + 3(dy+1) + 9(dz+1)`), fixed rows
    /// and columns zero.
    fn stencil(&self, kappa: &[f64]) -> Vec<f64> {
        let g = &self.grid;
        let n = g.n;
        let nodes = [n[0] + 1, n[1] + 1, n[2] + 1];
        let mut st = vec![0.0; 27 * g.nodes()];
        st.par_chunks_mut(27).enumerate().for_each(|(v, s)| {
            if self.fixed[v] {
                return;
            }
            let p = g.node_ijk(v);
            // Elements around the node.
            for ez in p[2].saturating_sub(1)..=p[2].min(n[2] - 1) {
                for ey in p[1].saturating_sub(1)..=p[1].min(n[1] - 1) {
                    for ex in p[0].saturating_sub(1)..=p[0].min(n[0] - 1) {
                        let kap = kappa[g.element(ex, ey, ez)];
                        let la = (p[0] - ex) + 2 * (p[1] - ey) + 4 * (p[2] - ez);
                        for lb in 0..8 {
                            let q = [ex + (lb & 1), ey + ((lb >> 1) & 1), ez + (lb >> 2)];
                            let slot = (q[0] + 1 - p[0]) + 3 * (q[1] + 1 - p[1]) + 9 * (q[2] + 1 - p[2]);
                            s[slot] += kap * self.lex[la][lb];
                        }
                    }
                }
            }
            // Convection faces.
            let w = g.h * g.h / 36.0;
            for a in 0..3 {
                let (b, c) = others(a);
                let d = face_dims(n, a);
                for cc in p[c].saturating_sub(1)..=p[c].min(n[c] - 1) {
                    for cb in p[b].saturating_sub(1)..=p[b].min(n[b] - 1) {
                        let mut f = [0; 3];
                        f[a] = p[a];
                        f[b] = cb;
                        f[c] = cc;
                        let film = self.film[a][face_index(d, f)];
                        if film == 0.0 {
                            continue;
                        }
                        for dc in 0..2 {
                            for db in 0..2 {
                                let mut q = [0; 3];
                                q[a] = p[a];
                                q[b] = cb + db;
                                q[c] = cc + dc;
                                let wb = if q[b] == p[b] { 2.0 } else { 1.0 };
                                let wc = if q[c] == p[c] { 2.0 } else { 1.0 };
                                let slot = (q[0] + 1 - p[0]) + 3 * (q[1] + 1 - p[1]) + 9 * (q[2] + 1 - p[2]);
                                s[slot] += film * w * wb * wc;
                            }
                        }
                    }
                }
            }
            for slot in 0..27 {
                let o = [slot % 3, (slot / 3) % 3, slot / 9];
                let q = [0, 1, 2].map(|a| p[a] + o[a]);
                if (0..3).any(|a| q[a] < 1 || q[a] > nodes[a]) {
                    s[slot] = 0.0;
                    continue;
                }
                if self.fixed[g.node(q[0] - 1, q[1] - 1, q[2] - 1)] {
                    s[slot] = 0.0;
                }
            }
        });
        st
    }
}

// ---------------------------------------------------------------------------------------------
// Multigrid

/// One axis of a coarsening step (or of none); an odd count leaves the last coarse cell one
/// fine cell wide, as in [`super::mg`].
#[derive(Clone, Copy, Debug)]
struct Axis {
    fine: usize,
    coarse: usize,
    halve: bool,
}

impl Axis {
    fn new(fine: usize) -> Self {
        if fine >= 2 { Self { fine, coarse: fine.div_ceil(2), halve: true } } else { Self { fine, coarse: fine, halve: false } }
    }

    /// The coarse nodes fine node `f` interpolates from, with weights.
    fn up(&self, f: usize) -> ([(usize, f64); 2], usize) {
        if !self.halve || f.is_multiple_of(2) {
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
}

struct Level {
    /// Nodes per axis.
    nodes: [usize; 3],
    /// The coarsening from the level above to this one (unused on the finest).
    axes: [Axis; 3],
    stencil: Vec<f64>,
    /// One over the diagonal; zero on dropped (fixed) nodes.
    inv: Vec<f64>,
    /// Chebyshev centre and half-width.
    theta: f64,
    delta: f64,
}

impl Level {
    fn new(nodes: [usize; 3], axes: [Axis; 3], stencil: Vec<f64>) -> Self {
        let count = nodes[0] * nodes[1] * nodes[2];
        let inv: Vec<f64> = (0..count).into_par_iter().map(|v| {
            let d = stencil[27 * v + 13];
            if d > 0.0 { 1.0 / d } else { 0.0 }
        }).collect();
        // Gershgorin bound on the top of D⁻¹A: rigorous, so the smoother never amplifies.
        let hi = (0..count)
            .into_par_iter()
            .map(|v| if inv[v] > 0.0 { inv[v] * stencil[27 * v..27 * v + 27].iter().map(|x| x.abs()).sum::<f64>() } else { 0.0 })
            .reduce(|| 0.0, f64::max)
            .max(1e-12);
        let lo = hi / RATIO;
        Self { nodes, axes, stencil, inv, theta: 0.5 * (hi + lo), delta: 0.5 * (hi - lo) }
    }

    fn count(&self) -> usize {
        self.nodes[0] * self.nodes[1] * self.nodes[2]
    }
}

/// `out = A x` for a 27-point stencil, gathered by node row.
fn stencil_apply(nodes: [usize; 3], st: &[f64], x: &[f64], out: &mut [f64]) {
    let [mx, my, mz] = nodes;
    out.par_chunks_mut(mx).enumerate().for_each(|(row, o)| {
        let (j, k) = (row % my, row / my);
        for (i, v) in o.iter_mut().enumerate() {
            let node = i + mx * row;
            let s = &st[27 * node..27 * node + 27];
            let mut acc = 0.0;
            for dz in 0..3 {
                let kk = k + dz;
                if kk < 1 || kk > mz {
                    continue;
                }
                for dy in 0..3 {
                    let jj = j + dy;
                    if jj < 1 || jj > my {
                        continue;
                    }
                    let base = mx * ((jj - 1) + my * (kk - 1));
                    for dx in 0..3 {
                        let ii = i + dx;
                        if ii < 1 || ii > mx {
                            continue;
                        }
                        acc = s[dx + 3 * dy + 9 * dz].mul_add(x[base + ii - 1], acc);
                    }
                }
            }
            *v = acc;
        }
    });
}

/// The Galerkin product `Pᵀ A P` of a level's stencil onto the next coarser grid.
fn galerkin(fine: &Level, axes: [Axis; 3]) -> Vec<f64> {
    let fnodes = fine.nodes;
    let cnodes = [axes[0].coarse + 1, axes[1].coarse + 1, axes[2].coarse + 1];
    let count = cnodes[0] * cnodes[1] * cnodes[2];
    let mut out = vec![0.0; 27 * count];
    out.par_chunks_mut(27).enumerate().for_each(|(cv, o)| {
        let ci = [cv % cnodes[0], (cv / cnodes[0]) % cnodes[1], cv / (cnodes[0] * cnodes[1])];
        let downs = [axes[0].down(ci[0]), axes[1].down(ci[1]), axes[2].down(ci[2])];
        for &(fz, wz) in &downs[2].0[..downs[2].1] {
            for &(fy, wy) in &downs[1].0[..downs[1].1] {
                for &(fx, wx) in &downs[0].0[..downs[0].1] {
                    let fi = fx + fnodes[0] * (fy + fnodes[1] * fz);
                    if fine.inv[fi] == 0.0 {
                        continue;
                    }
                    let wi = wx * wy * wz;
                    let s = &fine.stencil[27 * fi..27 * fi + 27];
                    for slot in 0..27 {
                        let a = s[slot];
                        if a == 0.0 {
                            continue;
                        }
                        let j = [fx + slot % 3, fy + (slot / 3) % 3, fz + slot / 9].map(|v| v as isize - 1);
                        let ups = [axes[0].up(j[0] as usize), axes[1].up(j[1] as usize), axes[2].up(j[2] as usize)];
                        for &(cz, vz) in &ups[2].0[..ups[2].1] {
                            for &(cy, vy) in &ups[1].0[..ups[1].1] {
                                for &(cx, vx) in &ups[0].0[..ups[0].1] {
                                    let off = [cx as isize - ci[0] as isize, cy as isize - ci[1] as isize, cz as isize - ci[2] as isize];
                                    let cs = (off[0] + 1) + 3 * (off[1] + 1) + 9 * (off[2] + 1);
                                    o[cs as usize] += wi * a * vx * vy * vz;
                                }
                            }
                        }
                    }
                }
            }
        }
    });
    out
}

/// `coarse = Pᵀ r`.
fn restrict(axes: [Axis; 3], fnodes: [usize; 3], r: &[f64], cnodes: [usize; 3], coarse: &mut [f64]) {
    coarse.par_chunks_mut(cnodes[0]).enumerate().for_each(|(row, o)| {
        let (dy, ndy) = axes[1].down(row % cnodes[1]);
        let (dz, ndz) = axes[2].down(row / cnodes[1]);
        for (ci, v) in o.iter_mut().enumerate() {
            let (dx, ndx) = axes[0].down(ci);
            let mut acc = 0.0;
            for &(fz, wz) in &dz[..ndz] {
                for &(fy, wy) in &dy[..ndy] {
                    let base = fnodes[0] * (fy + fnodes[1] * fz);
                    for &(fx, wx) in &dx[..ndx] {
                        acc += wx * wy * wz * r[base + fx];
                    }
                }
            }
            *v = acc;
        }
    });
}

/// `fine += P coarse`, except on dropped nodes (zero `inv`).
fn prolong_add(axes: [Axis; 3], cnodes: [usize; 3], coarse: &[f64], fnodes: [usize; 3], fine: &mut [f64], inv: &[f64]) {
    fine.par_chunks_mut(fnodes[0]).enumerate().for_each(|(row, o)| {
        let (uy, nuy) = axes[1].up(row % fnodes[1]);
        let (uz, nuz) = axes[2].up(row / fnodes[1]);
        for (fi, v) in o.iter_mut().enumerate() {
            if inv[fnodes[0] * row + fi] == 0.0 {
                continue;
            }
            let (ux, nux) = axes[0].up(fi);
            let mut acc = 0.0;
            for &(cz, wz) in &uz[..nuz] {
                for &(cy, wy) in &uy[..nuy] {
                    let base = cnodes[0] * (cy + cnodes[1] * cz);
                    for &(cx, wx) in &ux[..nux] {
                        acc += wx * wy * wz * coarse[base + cx];
                    }
                }
            }
            *v += acc;
        }
    });
}

/// Banded Cholesky of the coarsest stencil (nodes renumbered shortest axis first).
struct Band {
    n: usize,
    bw: usize,
    l: Vec<f64>,
    map: Vec<usize>,
}

impl Band {
    fn new(nodes: [usize; 3], st: &[f64]) -> Self {
        let mut ord = [0, 1, 2];
        ord.sort_by_key(|&a| nodes[a]);
        let m = ord.map(|a| nodes[a]);
        let n = nodes[0] * nodes[1] * nodes[2];
        let bw = (m[0] * m[1] + m[0] + 1).min(n.saturating_sub(1));
        let w = bw + 1;
        let place = |ijk: [usize; 3]| ijk[ord[0]] + m[0] * (ijk[ord[1]] + m[1] * ijk[ord[2]]);
        let mut map = vec![0; n];
        for k in 0..nodes[2] {
            for j in 0..nodes[1] {
                for i in 0..nodes[0] {
                    map[i + nodes[0] * (j + nodes[1] * k)] = place([i, j, k]);
                }
            }
        }
        let mut l = vec![0.0; n * w];
        for k in 0..nodes[2] {
            for j in 0..nodes[1] {
                for i in 0..nodes[0] {
                    let v = i + nodes[0] * (j + nodes[1] * k);
                    for slot in 0..27 {
                        let g = [i + slot % 3, j + (slot / 3) % 3, k + slot / 9];
                        if (0..3).any(|a| g[a] < 1 || g[a] > nodes[a]) {
                            continue;
                        }
                        let u = (g[0] - 1) + nodes[0] * ((g[1] - 1) + nodes[1] * (g[2] - 1));
                        let (p, q) = (map[v], map[u]);
                        if q <= p && p - q <= bw {
                            l[p * w + bw - (p - q)] = st[27 * v + slot];
                        }
                    }
                }
            }
        }
        for i in 0..n {
            let i0 = i.saturating_sub(bw);
            for j in i0..=i {
                let j0 = j.saturating_sub(bw).max(i0);
                let mut s = l[i * w + bw - (i - j)];
                for c in j0..j {
                    s -= l[i * w + bw - (i - c)] * l[j * w + bw - (j - c)];
                }
                if j < i {
                    l[i * w + bw - (i - j)] = s / l[j * w + bw];
                } else {
                    // An empty row (a fixed node) gets a unit pivot.
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
            let mut s = y[i];
            for c in i0..i {
                s -= self.l[i * w + bw - (i - c)] * y[c];
            }
            y[i] = s / self.l[i * w + bw];
        }
        for i in (0..n).rev() {
            y[i] /= self.l[i * w + bw];
            let i0 = i.saturating_sub(bw);
            let yi = y[i];
            for c in i0..i {
                y[c] -= self.l[i * w + bw - (i - c)] * yi;
            }
        }
        for (d, &p) in self.map.iter().enumerate() {
            x[d] = y[p];
        }
    }
}

fn dot(a: &[f64], b: &[f64]) -> f64 {
    a.par_chunks(CHUNK).zip(b.par_chunks(CHUNK)).map(|(a, b)| a.iter().zip(b).map(|(x, y)| x * y).sum::<f64>()).collect::<Vec<_>>().iter().sum()
}

/// The multigrid-preconditioned conjugate gradient for one conductivity field.
pub struct Multigrid<'a> {
    op: &'a Conduction,
    kappa: &'a [f64],
    levels: Vec<Level>,
    band: Band,
}

impl<'a> Multigrid<'a> {
    pub fn new(op: &'a Conduction, kappa: &'a [f64]) -> Self {
        let n = op.grid.n;
        let mut levels = vec![Level::new([n[0] + 1, n[1] + 1, n[2] + 1], [Axis::new(0); 3], op.stencil(kappa))];
        loop {
            let last = levels.last().expect("one level");
            if last.count() <= COARSE_NODES {
                break;
            }
            let axes = last.nodes.map(|m| Axis::new(m - 1));
            if axes.iter().all(|a| !a.halve) {
                break;
            }
            let st = galerkin(last, axes);
            levels.push(Level::new(axes.map(|a| a.coarse + 1), axes, st));
        }
        let last = levels.last().expect("one level");
        let band = Band::new(last.nodes, &last.stencil);
        Self { op, kappa, levels, band }
    }

    pub fn levels(&self) -> usize {
        self.levels.len()
    }

    fn smooth(&self, l: usize, b: &[f64], x: &mut [f64], zero: bool) {
        let lv = &self.levels[l];
        let n = lv.count();
        let sigma = lv.theta / lv.delta;
        let mut rho = 1.0 / sigma;
        let mut d = vec![0.0; n];
        let mut t = vec![0.0; n];
        if zero {
            x.par_iter_mut().zip(d.par_iter_mut()).zip(b.par_iter().zip(lv.inv.par_iter())).for_each(|((x, d), (&b, &i))| {
                *d = i * b / lv.theta;
                *x = *d;
            });
        } else {
            stencil_apply(lv.nodes, &lv.stencil, x, &mut t);
            x.par_iter_mut().zip(d.par_iter_mut()).zip(b.par_iter().zip(lv.inv.par_iter()).zip(t.par_iter())).for_each(|((x, d), ((&b, &i), &t))| {
                *d = i * (b - t) / lv.theta;
                *x += *d;
            });
        }
        for _ in 1..DEGREE {
            stencil_apply(lv.nodes, &lv.stencil, x, &mut t);
            let next = 1.0 / (2.0 * sigma - rho);
            let (c1, c2) = (next * rho, 2.0 * next / lv.delta);
            x.par_iter_mut().zip(d.par_iter_mut()).zip(b.par_iter().zip(lv.inv.par_iter()).zip(t.par_iter())).for_each(|((x, d), ((&b, &i), &t))| {
                *d = c1 * *d + c2 * i * (b - t);
                *x += *d;
            });
            rho = next;
        }
    }

    fn cycle(&self, l: usize, b: &[f64], x: &mut [f64]) {
        let last = self.levels.len() - 1;
        if l == last {
            self.band.solve(b, x);
            for (x, &i) in x.iter_mut().zip(&self.levels[l].inv) {
                if i == 0.0 {
                    *x = 0.0;
                }
            }
            return;
        }
        let lv = &self.levels[l];
        self.smooth(l, b, x, true);
        let mut t = vec![0.0; lv.count()];
        stencil_apply(lv.nodes, &lv.stencil, x, &mut t);
        t.par_iter_mut().zip(b.par_iter()).zip(lv.inv.par_iter()).for_each(|((t, &b), &i)| *t = if i > 0.0 { b - *t } else { 0.0 });
        let next = &self.levels[l + 1];
        let mut bc = vec![0.0; next.count()];
        restrict(next.axes, lv.nodes, &t, next.nodes, &mut bc);
        let mut xc = vec![0.0; next.count()];
        self.cycle(l + 1, &bc, &mut xc);
        prolong_add(next.axes, next.nodes, &xc, lv.nodes, x, &lv.inv);
        self.smooth(l, b, x, false);
    }

    /// One V-cycle: `z ≈ A⁻¹ r` (zero on fixed nodes).
    pub fn vcycle(&self, r: &[f64], z: &mut [f64]) {
        self.cycle(0, r, z);
    }

    /// Solves `K x = b` on the free nodes (`b` and `x` zero on fixed ones; `x` holds the start)
    /// to a relative residual `tol`.
    pub fn solve(&self, b: &[f64], x: &mut [f64], tol: f64, max_iter: usize) -> Result<SolveStats, String> {
        let n = b.len();
        let fixed = &self.op.fixed;
        if n != self.op.grid.nodes() || x.len() != n {
            return Err(format!("{} entries for {} nodes", b.len(), self.op.grid.nodes()));
        }
        x.par_iter_mut().zip(fixed.par_iter()).for_each(|(x, &f)| {
            if f {
                *x = 0.0;
            }
        });
        let bc: Vec<f64> = b.par_iter().zip(fixed.par_iter()).map(|(&b, &f)| if f { 0.0 } else { b }).collect();
        let bn = dot(&bc, &bc).sqrt();
        if !bn.is_finite() {
            return Err("heat load is not finite".into());
        }
        if bn == 0.0 {
            x.fill(0.0);
            return Ok(SolveStats { iterations: 0, residual: 0.0 });
        }
        let mut q = vec![0.0; n];
        self.op.apply_free(self.kappa, x, &mut q);
        let mut r: Vec<f64> = bc.par_iter().zip(q.par_iter()).map(|(b, q)| b - q).collect();
        let mut z = vec![0.0; n];
        self.vcycle(&r, &mut z);
        let mut p = z.clone();
        let mut rz = dot(&r, &z);
        let mut res = dot(&r, &r).sqrt() / bn;
        let mut it = 0;
        while res > tol && it < max_iter {
            self.op.apply_free(self.kappa, &p, &mut q);
            let pq = dot(&p, &q);
            if pq.is_nan() || pq <= 0.0 {
                break;
            }
            let alpha = rz / pq;
            x.par_iter_mut().zip(p.par_iter()).for_each(|(x, p)| *x += alpha * p);
            r.par_iter_mut().zip(q.par_iter()).for_each(|(r, q)| *r -= alpha * q);
            res = dot(&r, &r).sqrt() / bn;
            it += 1;
            if !res.is_finite() {
                return Err("the temperature solve diverged".into());
            }
            if res <= tol {
                break;
            }
            self.vcycle(&r, &mut z);
            let rz_new = dot(&r, &z);
            let beta = rz_new / rz;
            rz = rz_new;
            p.par_iter_mut().zip(z.par_iter()).for_each(|(p, z)| *p = z + beta * *p);
        }
        Ok(SolveStats { iterations: it, residual: res })
    }
}

// ---------------------------------------------------------------------------------------------
// The problem a study sets

/// A study's heat problem on its grid: operator, loads and boundary temperatures.
pub struct Problem {
    pub op: Conduction,
    /// Solid conductivity, W/(mm K).
    pub k0: f64,
    /// Heat sources per node, W.
    pub source: Vec<f64>,
    /// Convection's ambient load per node, W (`h T_amb a²/4` per face corner).
    pub ambient_load: Vec<f64>,
    /// Prescribed temperatures on fixed nodes (zero elsewhere), °C.
    pub prescribed: Vec<f64>,
    /// Lowest boundary temperature (ambient or fixed), °C: rises are read from it.
    pub reference: f64,
    /// Every boundary temperature is the reference: the compliance's adjoint is the rise itself.
    pub homogeneous: bool,
    pub power: f64,
}

impl Problem {
    pub fn new(study: &Study, th: &Thermal, grid: Grid) -> Result<Self, String> {
        let k_si = match th.conductivity {
            Some(k) => k,
            None => study.material.thermal().map(|p| p.conductivity).ok_or_else(|| format!("no thermal conductivity for \"{}\": give thermal.conductivity in W/(m K)", study.material.name))?,
        };
        if !(k_si.is_finite() && k_si > 0.0) {
            return Err(format!("thermal conductivity {k_si} W/(m K) must be positive"));
        }
        if !th.ambient.is_finite() {
            return Err("ambient temperature is not finite".into());
        }
        let n = grid.n;
        let mut fixed = vec![false; grid.nodes()];
        let mut prescribed = vec![0.0; grid.nodes()];
        let mut temps = Vec::new();
        for f in &th.fixed {
            if !f.temperature.is_finite() {
                return Err("a fixed temperature is not finite".into());
            }
            temps.push(f.temperature);
            for v in grid.nodes_in(&f.region) {
                fixed[v] = true;
                prescribed[v] = f.temperature;
            }
        }
        let mut film: [Vec<f64>; 3] = std::array::from_fn(|a| {
            let d = face_dims(n, a);
            vec![0.0; d[0] * d[1] * d[2]]
        });
        let mut ambient_load = vec![0.0; grid.nodes()];
        let quarter = grid.h * grid.h / 4.0;
        for c in &th.convection {
            if !(c.h.is_finite() && c.h >= 0.0) {
                return Err(format!("film coefficient {} W/(m2 K) must be zero or positive", c.h));
            }
            let amb = c.ambient.unwrap_or(th.ambient);
            if !amb.is_finite() {
                return Err("a convection ambient is not finite".into());
            }
            let hm = film_mm(c.h);
            let mut any = false;
            for a in 0..3 {
                let (b, cc) = others(a);
                let d = face_dims(n, a);
                for plane in [0, n[a]] {
                    for kc in 0..n[cc] {
                        for kb in 0..n[b] {
                            let mut f = [0; 3];
                            f[a] = plane;
                            f[b] = kb;
                            f[cc] = kc;
                            let mut centre = [0.0; 3];
                            centre[a] = grid.origin[a] + plane as f64 * grid.h;
                            centre[b] = grid.origin[b] + (kb as f64 + 0.5) * grid.h;
                            centre[cc] = grid.origin[cc] + (kc as f64 + 0.5) * grid.h;
                            if c.region.is_some_and(|r| !r.contains(centre)) {
                                continue;
                            }
                            any = true;
                            film[a][face_index(d, f)] += hm;
                            for dc in 0..2 {
                                for db in 0..2 {
                                    let mut q = f;
                                    q[b] += db;
                                    q[cc] += dc;
                                    ambient_load[grid.node(q[0], q[1], q[2])] += hm * amb * quarter;
                                }
                            }
                        }
                    }
                }
            }
            if any && c.h > 0.0 {
                temps.push(amb);
            }
        }
        if temps.is_empty() {
            return Err("the heat has no way out: add a convection (h > 0) or a fixed temperature".into());
        }
        let reference = temps.iter().copied().fold(f64::INFINITY, f64::min);
        let homogeneous = temps.iter().all(|&t| t == reference);
        let mut source = vec![0.0; grid.nodes()];
        let mut power = 0.0;
        for s in &th.sources {
            if !(s.power.is_finite() && s.power >= 0.0) {
                return Err(format!("heat source power {} W must be zero or positive", s.power));
            }
            power += s.power;
            let elems = grid.elements_in(&s.region);
            if elems.is_empty() {
                if let Some(&v) = grid.nodes_in(&s.region).first() {
                    source[v] += s.power;
                }
                continue;
            }
            let each = s.power / elems.len() as f64 / 8.0;
            for e in elems {
                for v in grid.element_nodes(e) {
                    source[v] += each;
                }
            }
        }
        Ok(Self { op: Conduction::new(grid, fixed, film), k0: conductivity_mm(k_si), source, ambient_load, prescribed, reference, homogeneous, power })
    }

    /// Conductivity per element from physical densities, and its slope.
    pub fn interpolate(&self, phys: &[f64], penal: f64, kmin: f64) -> (Vec<f64>, Vec<f64>) {
        let kmin = kmin.clamp(1e-9, 1.0);
        let kappa = phys.par_iter().map(|&r| self.k0 * (kmin + r.max(0.0).powf(penal) * (1.0 - kmin))).collect();
        let dk = phys.par_iter().map(|&r| self.k0 * penal * r.max(1e-12).powf(penal - 1.0) * (1.0 - kmin)).collect();
        (kappa, dk)
    }

    /// Solves for the nodal temperatures, °C. `t` holds the start (any values) and receives the
    /// field, prescribed nodes included.
    pub fn temperature(&self, kappa: &[f64], mg: &Multigrid, t: &mut [f64], tol: f64) -> Result<SolveStats, String> {
        let n = self.op.grid.nodes();
        let mut lift = vec![0.0; n];
        self.op.apply_raw(kappa, &self.prescribed, &mut lift);
        let rhs: Vec<f64> = (0..n)
            .into_par_iter()
            .map(|v| if self.op.fixed[v] { 0.0 } else { self.source[v] + self.ambient_load[v] - lift[v] })
            .collect();
        let mut x: Vec<f64> = (0..n).into_par_iter().map(|v| if self.op.fixed[v] { 0.0 } else { t[v] }).collect();
        let stats = mg.solve(&rhs, &mut x, tol, 1000)?;
        t.par_iter_mut().enumerate().for_each(|(v, t)| *t = if self.op.fixed[v] { self.prescribed[v] } else { x[v] });
        Ok(stats)
    }

    /// Thermal compliance `q·(T - T_ref)`, W K.
    pub fn compliance(&self, t: &[f64]) -> f64 {
        let rise: Vec<f64> = t.par_iter().map(|&x| x - self.reference).collect();
        dot(&self.source, &rise)
    }
}

/// The p-norm of the nodal temperature rise over the free nodes, `(Σ θᵖ)^(1/p)`, its gradient
/// in the temperatures and the true peak rise (all nodes).
pub fn temperature_pnorm(prob: &Problem, t: &[f64], p: f64) -> (f64, Vec<f64>, f64) {
    let theta: Vec<f64> = t.iter().map(|&x| (x - prob.reference).max(0.0)).collect();
    let peak = theta.iter().copied().fold(0.0, f64::max);
    if peak <= 0.0 {
        return (0.0, vec![0.0; t.len()], 0.0);
    }
    let sum: f64 = theta
        .par_chunks(CHUNK)
        .zip(prob.op.fixed.par_chunks(CHUNK))
        .map(|(th, fx)| th.iter().zip(fx).filter(|(_, f)| !**f).map(|(x, _)| (x / peak).powf(p)).sum::<f64>())
        .collect::<Vec<_>>()
        .iter()
        .sum();
    let j = peak * sum.powf(1.0 / p);
    let grad = theta.iter().zip(&prob.op.fixed).map(|(&x, &f)| if f { 0.0 } else { (x / j).powf(p - 1.0) }).collect();
    (j, grad, peak)
}

// ---------------------------------------------------------------------------------------------
// Optimisation

/// What one evaluation answers.
pub struct Evaluation {
    pub phys: Vec<f64>,
    pub f0: f64,
    pub df0: Vec<f64>,
    pub g: Vec<f64>,
    pub dg: Vec<Vec<f64>>,
    pub volume: f64,
    /// Thermal compliance, W K.
    pub compliance: f64,
    /// Peak temperature, °C, and the p-norm's estimate of it.
    pub max_temperature: f64,
    pub estimate: f64,
    pub iterations: usize,
}

/// The optimiser's state between evaluations.
pub struct Evaluator<'a> {
    pub m: Model,
    pub prob: Problem,
    th: &'a Thermal,
    vf: f64,
    design: Vec<bool>,
    n_design: f64,
    mass_obj: bool,
    ci_temp: Option<usize>,
    pub ncon: usize,
    t: Vec<f64>,
    c0: Option<f64>,
    scale: f64,
    /// Share of the temperature budget (limit over the reference) aimed at.
    margin: f64,
}

impl<'a> Evaluator<'a> {
    pub fn new(study: &'a Study, volume_fraction: f64) -> Result<Self, String> {
        let th = study.thermal.as_ref().ok_or("the study has no thermal block")?;
        let grid = design_grid(study)?;
        let prob = Problem::new(study, th, grid)?;
        let m = Model::for_design(study, grid, passive(study, &grid));
        let design: Vec<bool> = m.passive.iter().map(|p| p.is_none()).collect();
        let n_design = design.iter().filter(|&&d| d).count().max(1) as f64;
        let mass_obj = th.objective == ThermalObjective::Mass;
        if mass_obj && th.max_temperature.is_none() {
            return Err("the thermal mass objective needs max_temperature".into());
        }
        if let Some(tl) = th.max_temperature.filter(|&tl| tl.is_nan() || tl <= prob.reference) {
            return Err(format!("max_temperature {tl} C is not above the boundary temperature {} C", prob.reference));
        }
        let ci_temp = th.max_temperature.map(|_| 1);
        let ncon = 1 + usize::from(ci_temp.is_some());
        let t = vec![prob.reference; grid.nodes()];
        Ok(Self { m, prob, th, vf: volume_fraction.clamp(0.01, 1.0), design, n_design, mass_obj, ci_temp, ncon, t, c0: None, scale: 1.0, margin: TEMPERATURE_MARGIN })
    }

    pub fn variables(&self) -> usize {
        self.m.groups
    }

    /// Objective, limits and their gradients at `x`; `rescale` updates the p-norm's scale.
    pub fn evaluate(&mut self, x: &[f64], beta: f64, it: usize, tol: f64, rescale: bool) -> Result<Evaluation, String> {
        let m = &self.m;
        let th = self.th;
        let prob = &self.prob;
        let chain = m.forward(x, beta, 0.5);
        let phys = &chain.phys;
        let ne = m.grid.elements();
        let (kappa, dk) = prob.interpolate(phys, th.penal, th.kmin);
        let mg = Multigrid::new(&prob.op, &kappa);
        let stats = prob.temperature(&kappa, &mg, &mut self.t, tol)?;
        let t = &self.t;
        let comp = prob.compliance(t);
        let c0 = *self.c0.get_or_insert(comp.abs().max(1e-30));
        let groups = m.groups;
        let mut df0 = vec![0.0; groups];
        let mut dg = vec![vec![0.0; groups]; self.ncon];
        let mut gv = vec![0.0; self.ncon];
        let back = |dphys: &[f64], scale: f64, out: &mut Vec<f64>| {
            let d = m.backward(&chain, beta, dphys);
            out.par_iter_mut().zip(d.par_iter()).for_each(|(o, v)| *o += scale * v);
        };

        let vol: f64 = phys.iter().zip(&self.design).filter(|(_, d)| **d).map(|(r, _)| r).sum::<f64>() / self.n_design;
        let dvol: Vec<f64> = self.design.iter().map(|&d| if d { 1.0 / self.n_design } else { 0.0 }).collect();
        gv[0] = vol / self.vf - 1.0;
        back(&dvol, 1.0 / self.vf, &mut dg[0]);

        let f0 = if self.mass_obj {
            back(&dvol, 1.0, &mut df0);
            vol
        } else {
            let lam = self.adjoint(&mg, &prob.source, tol, true)?;
            let mut ce = vec![0.0; ne];
            prob.op.cross(&lam, t, &mut ce);
            let d: Vec<f64> = (0..ne).into_par_iter().map(|e| -dk[e] * ce[e]).collect();
            back(&d, 1.0 / c0, &mut df0);
            comp / c0
        };

        let (j, grad, peak) = temperature_pnorm(prob, t, TEMPERATURE_P);
        if rescale && j > 0.0 {
            let ratio = peak / j;
            self.scale = if it == 0 { ratio } else { 0.5 * self.scale + 0.5 * ratio };
        }
        if let (Some(ci), Some(tl)) = (self.ci_temp, th.max_temperature) {
            let allow = self.margin * (tl - prob.reference);
            gv[ci] = self.scale * j / allow - 1.0;
            let mu = self.adjoint(&mg, &grad, tol, false)?;
            let mut ce = vec![0.0; ne];
            prob.op.cross(&mu, t, &mut ce);
            let d: Vec<f64> = (0..ne).into_par_iter().map(|e| -dk[e] * ce[e]).collect();
            back(&d, self.scale / allow, &mut dg[ci]);
        }
        Ok(Evaluation {
            phys: chain.phys.clone(),
            f0,
            df0,
            g: gv,
            dg,
            volume: vol,
            compliance: comp,
            max_temperature: prob.reference + peak,
            estimate: prob.reference + self.scale * j,
            iterations: stats.iterations,
        })
    }

    /// Peak temperature, °C, of the layout as built: densities at 0.5 and over solid, the rest
    /// void.
    pub fn built_peak(&self, phys: &[f64]) -> Result<f64, String> {
        let prob = &self.prob;
        let built: Vec<f64> = phys.iter().map(|&r| if r >= 0.5 { 1.0 } else { 0.0 }).collect();
        let (kappa, _) = prob.interpolate(&built, self.th.penal, self.th.kmin);
        let mg = Multigrid::new(&prob.op, &kappa);
        let mut t = self.t.clone();
        prob.temperature(&kappa, &mg, &mut t, 1e-8)?;
        Ok(t.iter().copied().fold(f64::NEG_INFINITY, f64::max))
    }

    /// `K λ = rhs` on the free nodes; the rise itself for the source when the problem is
    /// homogeneous.
    fn adjoint(&self, mg: &Multigrid, rhs: &[f64], tol: f64, source: bool) -> Result<Vec<f64>, String> {
        let prob = &self.prob;
        if source && prob.homogeneous {
            return Ok(self.t.iter().map(|&x| x - prob.reference).collect());
        }
        let mut lam = vec![0.0; rhs.len()];
        mg.solve(rhs, &mut lam, tol.min(1e-6), 1000)?;
        Ok(lam)
    }
}

/// The grid of a study, checked.
fn design_grid(study: &Study) -> Result<Grid, String> {
    let span: [f64; 3] = std::array::from_fn(|a| study.max[a] - study.min[a]);
    if span.iter().any(|s| !(s.is_finite() && *s > 0.0)) {
        return Err("the design space is empty: max must exceed min on every axis".into());
    }
    if !(study.voxel.is_finite() && study.voxel > 0.0) {
        return Err(format!("voxel edge {} must be a positive length", study.voxel));
    }
    let grid = Grid::new(study.min, study.max, study.voxel);
    if grid.elements() > super::optimize::MAX_ELEMENTS {
        return Err(format!("{} voxels is over the engine's {}: use a coarser voxel", grid.elements(), super::optimize::MAX_ELEMENTS));
    }
    Ok(grid)
}

/// Keep-in (1) and keep-out (0) voxels, as the elastic model reads them.
fn passive(study: &Study, grid: &Grid) -> Vec<Option<f64>> {
    let mut passive = vec![None; grid.elements()];
    for r in &study.keep_in {
        for e in grid.elements_in(r) {
            passive[e] = Some(1.0);
        }
    }
    for r in &study.keep_out {
        for e in grid.elements_touching(r) {
            passive[e] = Some(0.0);
        }
    }
    passive
}

/// A thermal run's layout and its history.
#[derive(Clone, Debug, PartialEq)]
pub struct ThermalLayout {
    pub grid: Grid,
    pub density: Vec<f32>,
    /// Per iteration: the compliance (compliance objective) or the volume fraction (mass).
    pub history: Vec<f64>,
    /// Per iteration: the peak temperature, °C.
    pub peaks: Vec<f64>,
    /// Per iteration: PCG iterations of the temperature solve.
    pub solves: Vec<usize>,
}

/// Runs the thermal topology optimisation of `study` (its `thermal` block).
pub fn optimize(study: &Study) -> Result<ThermalLayout, String> {
    optimize_with(study, &mut |_, _| true)
}

/// [`optimize`], reporting `(iteration, objective)`; stops with `cancelled` on false.
pub fn optimize_with(study: &Study, report: &mut dyn FnMut(usize, f64) -> bool) -> Result<ThermalLayout, String> {
    let th = study.thermal.as_ref().ok_or("the study has no thermal block")?;
    let mass_obj = th.objective == ThermalObjective::Mass;
    let mut ev = Evaluator::new(study, study.volume_fraction)?;
    let nvar = ev.variables();
    let iterations = study.iterations.max(1);
    let mut x = vec![if mass_obj { ev.vf.min(0.6) } else { ev.vf }; nvar];
    let (xmin, xmax) = (vec![0.0; nvar], vec![1.0; nvar]);
    let mut mma = Mma::new(nvar, ev.ncon);
    let stage = (iterations / 5).max(1);
    let hard = ev.ci_temp.is_some();
    let mut layout = ThermalLayout { grid: ev.m.grid, density: Vec::new(), history: Vec::new(), peaks: Vec::new(), solves: Vec::new() };
    // The main run, then (temperature-limited studies) up to three short rounds at full
    // sharpness, each aiming lower by what the built part (thresholded at 0.5) reads over the
    // limit: grey voxels conduct in the run and not in the part.
    let extra = if hard { (iterations / 4).max(5) } else { 0 };
    let mut total = iterations;
    let mut round = 0;
    let mut it = 0;
    while it < total {
        let beta = if study.max_beta <= 0.0 { 0.0 } else { 2f64.powi(((it / stage) as i32).min(4)).min(study.max_beta.max(1.0)) };
        let last = it + 1 == total;
        let e = ev.evaluate(&x, beta, it, if last { 1e-8 } else { 1e-6 }, true)?;
        if std::env::var_os("VIAFORM_GEN_TRACE").is_some() {
            eprintln!("thermal it {it:3} beta {beta:4.1} vol {:.4} comp {:.5e} tmax {:.2} est {:.2} pcg {} g {:?}", e.volume, e.compliance, e.max_temperature, e.estimate, e.iterations, e.g);
        }
        layout.history.push(if mass_obj { e.volume } else { e.compliance });
        layout.peaks.push(e.max_temperature);
        layout.solves.push(e.iterations);
        if !report(it, *layout.history.last().unwrap_or(&0.0)) {
            return Err(super::CANCELLED.into());
        }
        layout.density = e.phys.iter().map(|&r| r as f32).collect();
        it += 1;
        if last {
            let tl = th.max_temperature.unwrap_or(f64::INFINITY);
            if extra > 0 && round < 3 {
                let peak = ev.built_peak(&e.phys)?;
                if peak > tl {
                    let r = ev.prob.reference;
                    ev.margin *= 0.97 * (tl - r) / (peak - r);
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
            (false, false) => 0.2,
            (false, true) => 0.1,
            (true, false) => 0.1,
            (true, true) => 0.05,
        };
        mma.try_update(&mut x, &xmin, &xmax, &e.df0, &e.g, &e.dg, move_limit)?;
    }
    Ok(layout)
}

// ---------------------------------------------------------------------------------------------
// Analysis, thermal stress and the study runner

/// What the heat analysis says about one layout.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ThermalAnalysis {
    /// Peak temperature, °C.
    pub max_temperature: f64,
    /// Heat-weighted mean temperature of the sources, °C.
    pub source_temperature: f64,
    /// Thermal compliance `q·(T - T_ref)`, W K.
    pub compliance: f64,
    /// Heat put in, W.
    pub power: f64,
    pub solid_mm3: f64,
    pub mass_g: f64,
    /// Peak von Mises of the thermal stress over solid voxels, MPa (when asked for).
    pub thermal_stress: Option<f64>,
}

/// The heat analysis of densities on the study's grid (0/1 for a built part; grey values
/// read through the SIMP interpolation). Answers the analysis and the nodal temperatures.
pub fn analyse(study: &Study, density: &[f32]) -> Result<(ThermalAnalysis, Vec<f64>), String> {
    let th = study.thermal.as_ref().ok_or("the study has no thermal block")?;
    let grid = design_grid(study)?;
    if density.len() != grid.elements() {
        return Err(format!("{} densities for {} voxels", density.len(), grid.elements()));
    }
    let prob = Problem::new(study, th, grid)?;
    let phys: Vec<f64> = density.iter().map(|&d| d as f64).collect();
    let (kappa, _) = prob.interpolate(&phys, th.penal, th.kmin);
    let mg = Multigrid::new(&prob.op, &kappa);
    let mut t = vec![prob.reference; grid.nodes()];
    prob.temperature(&kappa, &mg, &mut t, 1e-9)?;
    let comp = prob.compliance(&t);
    let peak = t.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let solid = phys.iter().filter(|&&r| r >= 0.5).count() as f64 * grid.h.powi(3);
    let mut a = ThermalAnalysis {
        max_temperature: peak,
        source_temperature: if prob.power > 0.0 { prob.reference + comp / prob.power } else { prob.reference },
        compliance: comp,
        power: prob.power,
        solid_mm3: solid,
        mass_g: solid * study.material.density,
        thermal_stress: None,
    };
    if th.stress && !study.supports.is_empty() {
        let alpha = match th.expansion {
            Some(a) => a,
            None => study.material.thermal().map(|p| p.expansion).ok_or("no thermal expansion for the material: give thermal.expansion")?,
        };
        let t0 = th.stress_free.unwrap_or(th.ambient);
        let theta: Vec<f64> = t.iter().map(|&x| x - t0).collect();
        let (_, vm) = thermal_stress(study, &grid, &phys, alpha, &theta)?;
        a.thermal_stress = Some(vm.iter().zip(&phys).filter(|(_, r)| **r >= 0.5).map(|(s, _)| *s).fold(0.0, f64::max));
    }
    Ok((a, t))
}

/// Nodal forces of the thermal strain `α θ` (θ per node, the rise over the stress-free
/// temperature) on elements of modulus `young`, gathered per node.
pub fn thermal_load(grid: &Grid, nu: f64, young: &[f64], alpha: f64, theta: &[f64]) -> Vec<f64> {
    let gm = fem::thermal_coupling(nu, grid.h);
    let n = grid.n;
    let mut f = vec![0.0; grid.dofs()];
    f.par_chunks_mut(3).enumerate().for_each(|(v, o)| {
        let p = grid.node_ijk(v);
        for ez in p[2].saturating_sub(1)..=p[2].min(n[2] - 1) {
            for ey in p[1].saturating_sub(1)..=p[1].min(n[1] - 1) {
                for ex in p[0].saturating_sub(1)..=p[0].min(n[0] - 1) {
                    let e = grid.element(ex, ey, ez);
                    let nodes = grid.element_nodes(e);
                    let a = nodes.iter().position(|&w| w == v).expect("a corner of its element");
                    let te: [f64; 8] = std::array::from_fn(|c| theta[nodes[c]]);
                    for i in 0..3 {
                        let s: f64 = (0..8).map(|c| gm[3 * a + i][c] * te[c]).sum();
                        o[i] += young[e] * alpha * s;
                    }
                }
            }
        }
    });
    f
}

/// Thermal stress: solves the elastic model (the study's supports, no other load) under the
/// thermal strain of `theta` (rise per node) on densities `phys` (SIMP modulus), and answers
/// the displacements and the von Mises stress per element at its centre, MPa (solid modulus).
pub fn thermal_stress(study: &Study, grid: &Grid, phys: &[f64], alpha: f64, theta: &[f64]) -> Result<(Vec<f64>, Vec<f64>), String> {
    let mat = &study.material;
    let fixed = loads::fixed_dofs(grid, &study.supports);
    let op = Operator::new(*grid, mat.nu, fixed);
    let young: Vec<f64> = phys.iter().map(|&r| mat.e * (EMIN + r.powi(3) * (1.0 - EMIN))).collect();
    let f = thermal_load(grid, mat.nu, &young, alpha, theta);
    let mut u = vec![0.0; grid.dofs()];
    op.solve(&young, &f, &mut u, 1e-10, 2000)?;
    let smat = fem::stress_matrix(mat.nu, grid.h);
    let dm = fem::thermal_stress_unit(mat.nu);
    let vm = (0..grid.elements())
        .into_par_iter()
        .map(|e| {
            let dofs = fem::lex_dofs(grid, e);
            let th: f64 = grid.element_nodes(e).iter().map(|&v| theta[v]).sum::<f64>() / 8.0;
            let s: [f64; 6] = std::array::from_fn(|i| {
                let elastic: f64 = (0..24).map(|j| smat[i][j] * u[dofs[j]]).sum();
                mat.e * (elastic - if i < 3 { alpha * th * dm } else { 0.0 })
            });
            fem::von_mises_grad(&s).0
        })
        .collect();
    Ok((u, vm))
}

/// A thermal study's result.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ThermalOutcome {
    pub grid: Grid,
    /// Optimised physical densities.
    pub density: Vec<f32>,
    pub history: Vec<f64>,
    /// The built part (densities at 0.5 and up solid, the rest void).
    pub analysis: ThermalAnalysis,
    /// The same box filled solid (keep-outs void), for comparison.
    pub block: ThermalAnalysis,
    /// Nodal temperatures of the built part, °C.
    pub temperature: Vec<f32>,
    /// The temperature limit held by the built part (true when none is set).
    pub feasible: bool,
    pub mesh: Mesh,
    pub seconds: f64,
}

/// Runs a thermal study: optimisation, the built part's analysis, the plain block's, and the
/// surface.
pub fn generate(study: &Study) -> Result<ThermalOutcome, String> {
    let start = std::time::Instant::now();
    let th = study.thermal.as_ref().ok_or("the study has no thermal block")?;
    let layout = optimize(study)?;
    let built: Vec<f32> = layout.density.iter().map(|&d| if d >= 0.5 { 1.0 } else { 0.0 }).collect();
    let (analysis, t) = analyse(study, &built)?;
    let grid = layout.grid;
    let block: Vec<f32> = passive(study, &grid).iter().map(|p| p.map_or(1.0, |v| v as f32)).collect();
    let (block, _) = analyse(study, &block)?;
    let feasible = th.max_temperature.is_none_or(|tl| analysis.max_temperature <= tl + 1e-9);
    let solid: Vec<bool> = built.iter().map(|&d| d >= 0.5).collect();
    let (mesh, _) = iso::surface_solid(&grid, &solid, study.smoothing);
    Ok(ThermalOutcome {
        grid,
        density: layout.density,
        history: layout.history,
        analysis,
        block,
        temperature: t.iter().map(|&x| x as f32).collect(),
        feasible,
        mesh,
        seconds: start.elapsed().as_secs_f64(),
    })
}

// ---------------------------------------------------------------------------------------------
// Benchmark studies (shared by the tests and `examples/thermal.rs`)

/// The volume-to-point problem (Bejan 1997; Gersborg-Hansen, Bendsøe and Sigmund 2006; the
/// heat example of top3d, Liu and Tovar 2014): a square plate `n` voxels a side and `nz`
/// thick, uniform heat generation (`q` W/mm³), a sink at 0 °C on the middle tenth of one edge
/// (y = 0, through the thickness), k0 = 1 W/(m K), kmin 1e-3, SIMP p = 3, plain density filter
/// of radius 1.5 voxels, no projection, volume fraction `vf`.
pub fn volume_to_point(n: usize, nz: usize, vf: f64, iterations: usize) -> Study {
    let l = n as f64;
    let w = (l / 20.0).max(0.5);
    Study {
        min: [0.0; 3],
        max: [l, l, nz as f64],
        voxel: 1.0,
        volume_fraction: vf,
        iterations,
        max_beta: 0.0,
        min_member: 2.0,
        thermal: Some(Thermal {
            conductivity: Some(1.0),
            ambient: 0.0,
            sources: vec![HeatSource { region: Region::Box { min: [-1.0; 3], max: [l + 1.0, l + 1.0, nz as f64 + 1.0] }, power: 1e-3 * l * l * nz as f64 }],
            fixed: vec![FixedTemperature { region: Region::Box { min: [l / 2.0 - w - 1e-6, -0.01, -1.0], max: [l / 2.0 + w + 1e-6, 0.01, nz as f64 + 1.0] }, temperature: 0.0 }],
            ..Thermal::default()
        }),
        ..Study::default()
    }
}

/// The G10 acceptance case: a 40 x 40 x 10 mm aluminium heat sink base, a 5 W source on a
/// 10 x 10 mm pad in the middle of the top (a 1 mm keep-in), the bottom face cooled by forced
/// air or a cold plate at `h` W/(m² K) to 25 °C, at most 60 °C anywhere; least mass.
pub fn heat_sink(voxel: f64, h: f64, iterations: usize) -> Study {
    let pad = Region::Box { min: [15.0, 15.0, 9.0], max: [25.0, 25.0, 10.0] };
    Study {
        name: "Heat sink".into(),
        min: [0.0; 3],
        max: [40.0, 40.0, 10.0],
        voxel,
        keep_in: vec![pad],
        volume_fraction: 1.0,
        iterations,
        min_member: 3.0,
        symmetry: [true, true, false],
        thermal: Some(Thermal {
            objective: ThermalObjective::Mass,
            sources: vec![HeatSource { region: pad, power: 5.0 }],
            convection: vec![Convection { region: Some(Region::Box { min: [-1.0, -1.0, -0.01], max: [41.0, 41.0, 0.01] }), h, ambient: None }],
            max_temperature: Some(60.0),
            ..Thermal::default()
        }),
        ..Study::default()
    }
}

#[cfg(test)]
mod tests;
