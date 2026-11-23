//! The D3Q19 lattice Boltzmann solver.
//!
//! Layout: populations are stored structure-of-arrays inside each z plane, index
//! `((z * 19 + q) * ny + y) * nx + x`, so one z plane of all 19 directions is one contiguous
//! slab. A step is one fused pull-stream-collide pass from buffer `f` into buffer `f2`
//! (two buffers, swapped after the pass): each cell gathers `f_q(x - c_q)` from the previous
//! post-collision state, applies the boundary rule on every link that crosses a wall, collides,
//! and writes its own 19 values. rayon runs one task per z plane (`par_chunks_mut` over the
//! slabs); every output value is a pure function of the previous buffer, so the result is
//! bitwise identical on any thread count. Reductions (forces, convergence) are summed per plane
//! and then over planes in z order.

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use crate::EngineError;
use crate::lattice::{C, CF, CS2, OPP, Q, W, equilibrium};

/// Cell kind: fluid whose 18 neighbours are all fluid inside the domain (or across a periodic
/// face), so the fast pull applies.
pub const BULK: u8 = 0;
/// Fluid next to a solid voxel or a non-periodic domain face.
pub const EDGE: u8 = 1;
/// Solid voxel (no-slip, halfway bounce-back on every link into it).
pub const SOLID: u8 = 2;

/// Boundary condition on one face of the box. Faces are ordered `-x, +x, -y, +y, -z, +z`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Face {
    /// Wraps to the opposite face (both faces of the axis must be periodic).
    Periodic,
    /// Halfway bounce-back wall, optionally moving tangentially (Ladd 1994).
    Wall {
        #[serde(default)]
        velocity: [f64; 3],
    },
    /// Free slip (specular reflection).
    Slip,
    /// Velocity inlet: moving-wall bounce-back carrying `velocity` (lattice units).
    Velocity {
        velocity: [f64; 3],
        #[serde(default)]
        profile: Profile,
    },
    /// Pressure outlet: anti-bounce-back at lattice density `density`.
    Pressure {
        #[serde(default = "one")]
        density: f64,
    },
}

fn one() -> f64 {
    1.0
}

/// Inlet profile.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Profile {
    /// Same velocity on the whole face.
    #[default]
    Uniform,
    /// `velocity` is the peak; times `4 s (L - s) / L^2` across every transverse axis that is
    /// not periodic (plane Poiseuille in 2D, product profile in a duct).
    Parabolic,
}

/// Collision operator.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Collision {
    /// Single relaxation time (Bhatnagar, Gross and Krook 1954; Qian et al. 1992).
    Bgk,
    /// Regularized (Latt and Chopard 2006): the non-equilibrium part is projected on its
    /// second-order Hermite moment before relaxing.
    #[default]
    Regularized,
}

/// Solver set-up, all in lattice units.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Config {
    /// Cells along x, y, z.
    pub dims: [usize; 3],
    /// Relaxation time of the molecular viscosity (`nu = (tau - 1/2) / 3`).
    pub tau: f64,
    #[serde(default)]
    pub collision: Collision,
    /// Smagorinsky constant (typically 0.1 to 0.17); `None` for no LES.
    #[serde(default)]
    pub smagorinsky: Option<f64>,
    /// Uniform body force density (Guo forcing).
    #[serde(default)]
    pub body_force: [f64; 3],
    /// Faces `-x, +x, -y, +y, -z, +z`.
    pub faces: [Face; 6],
}

impl Config {
    /// A box periodic on every face.
    pub fn periodic(dims: [usize; 3], tau: f64) -> Config {
        Config {
            dims,
            tau,
            collision: Collision::Regularized,
            smagorinsky: None,
            body_force: [0.0; 3],
            faces: [Face::Periodic; 6],
        }
    }
}

#[derive(Clone, Copy, Default)]
struct PlaneStat {
    force: [f64; 3],
    torque: [f64; 3],
}

/// Lattice Boltzmann state and parameters.
pub struct Solver {
    cfg: Config,
    nx: usize,
    ny: usize,
    nz: usize,
    f: Vec<f64>,
    f2: Vec<f64>,
    /// Per cell `[rho, ux, uy, uz]` of the last step (velocity includes half the body force).
    mac: Vec<[f64; 4]>,
    kind: Vec<u8>,
    solid: Vec<bool>,
    porosity: Option<Vec<f64>>,
    dirty: bool,
    stats: Vec<PlaneStat>,
    prev_u: Vec<[f64; 3]>,
    /// Torque reference point, lattice coordinates (cell centres are integer coordinates).
    pub torque_center: [f64; 3],
    steps: u64,
    reflect: [[usize; Q]; 8],
    sponge: Option<(usize, f64)>,
    links: Vec<(u64, f64)>,
}

/// Read-only view used by the parallel pass.
struct Pass<'a> {
    nx: usize,
    ny: usize,
    nz: usize,
    src: &'a [f64],
    kind: &'a [u8],
    porosity: Option<&'a [f64]>,
    faces: &'a [Face; 6],
    periodic: [bool; 3],
    parabolic: [[bool; 3]; 6],
    xm: &'a [usize],
    xp: &'a [usize],
    ym: &'a [usize],
    yp: &'a [usize],
    zm: &'a [usize],
    zp: &'a [usize],
    reflect: &'a [[usize; Q]; 8],
    center: [f64; 3],
    col: Col,
    sponge: Option<(usize, f64)>,
    links: &'a [(u64, f64)],
}

#[derive(Clone, Copy)]
struct Col {
    tau: f64,
    regularized: bool,
    smag: Option<f64>,
    force: [f64; 3],
    has_force: bool,
}

fn priority(f: &Face) -> u8 {
    match f {
        Face::Wall { .. } => 0,
        Face::Velocity { .. } => 1,
        Face::Pressure { .. } => 2,
        Face::Slip => 3,
        Face::Periodic => 4,
    }
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

impl<'a> Pass<'a> {
    #[inline(always)]
    fn sidx(&self, q: usize, x: usize, y: usize, z: usize) -> usize {
        ((z * Q + q) * self.ny + y) * self.nx + x
    }

    #[inline(always)]
    fn cell(&self, x: usize, y: usize, z: usize) -> usize {
        (z * self.ny + y) * self.nx + x
    }

    /// Population `q` arriving at a fluid cell next to a wall or a solid.
    fn pull_edge(
        &self,
        q: usize,
        x: usize,
        y: usize,
        z: usize,
        old: [f64; 4],
        stat: &mut PlaneStat,
    ) -> f64 {
        let c = C[q];
        let n = [self.nx as isize, self.ny as isize, self.nz as isize];
        let mut s = [
            x as isize - c[0] as isize,
            y as isize - c[1] as isize,
            z as isize - c[2] as isize,
        ];
        let mut face: Option<usize> = None;
        let mut crossed = 0usize;
        for a in 0..3 {
            if s[a] < 0 || s[a] >= n[a] {
                if self.periodic[a] {
                    s[a] = s[a].rem_euclid(n[a]);
                } else {
                    let fi = 2 * a + usize::from(s[a] >= n[a]);
                    crossed |= 1 << a;
                    if face.is_none_or(|g| priority(&self.faces[fi]) < priority(&self.faces[g])) {
                        face = Some(fi);
                    }
                }
            }
        }
        let back = self.src[self.sidx(OPP[q], x, y, z)];
        if let Some(fi) = face {
            let rho = old[0];
            return match self.faces[fi] {
                Face::Wall { velocity } => back + 6.0 * W[q] * rho * dot(CF[q], velocity),
                Face::Velocity { velocity, profile } => {
                    let mut v = velocity;
                    if profile == Profile::Parabolic {
                        let p = [x, y, z];
                        let dims = [self.nx, self.ny, self.nz];
                        let mut k = 1.0;
                        for b in 0..3 {
                            if self.parabolic[fi][b] {
                                let l = dims[b] as f64;
                                // At the link's wall crossing (x - c/2), not the cell centre: the
                                // difference between diagonal links carries the inlet shear.
                                let sb = p[b] as f64 + 0.5 - 0.5 * c[b] as f64;
                                k *= 4.0 * sb * (l - sb) / (l * l);
                            }
                        }
                        v = [v[0] * k, v[1] * k, v[2] * k];
                    }
                    back + 6.0 * W[q] * rho * dot(CF[q], v)
                }
                Face::Pressure { density } => {
                    let u = [old[1], old[2], old[3]];
                    let cu = dot(CF[q], u);
                    -back + 2.0 * W[q] * density * (1.0 + 4.5 * cu * cu - 1.5 * dot(u, u))
                }
                Face::Slip => {
                    // Specular reflection: the population left the cell shifted by the
                    // tangential part of c, moving toward the wall in the mirrored direction.
                    let mut t = [x as isize, y as isize, z as isize];
                    for a in 0..3 {
                        if crossed & (1 << a) == 0 {
                            t[a] -= c[a] as isize;
                            if t[a] < 0 || t[a] >= n[a] {
                                if self.periodic[a] {
                                    t[a] = t[a].rem_euclid(n[a]);
                                } else {
                                    return back;
                                }
                            }
                        }
                    }
                    let (tx, ty, tz) = (t[0] as usize, t[1] as usize, t[2] as usize);
                    if self.kind[self.cell(tx, ty, tz)] == SOLID {
                        return back;
                    }
                    self.src[self.sidx(self.reflect[crossed][q], tx, ty, tz)]
                }
                Face::Periodic => unreachable!(),
            };
        }
        let (sx, sy, sz) = (s[0] as usize, s[1] as usize, s[2] as usize);
        if self.kind[self.cell(sx, sy, sz)] == SOLID {
            // Halfway bounce-back on a resting solid, or Bouzidi's linear interpolated
            // bounce-back when the wall distance of this link is known; momentum exchange
            // (Ladd 1994, Mei et al. 2002).
            let mut out = back;
            let mut qw = 0.5;
            if !self.links.is_empty()
                && let Ok(k) = self
                    .links
                    .binary_search_by_key(&((self.cell(x, y, z) * Q + q) as u64), |e| e.0)
            {
                qw = self.links[k].1;
                if qw < 0.5 {
                    if let Some((ax, ay, az)) = self.fluid_neighbour(x, y, z, c) {
                        out = 2.0 * qw * back
                            + (1.0 - 2.0 * qw) * self.src[self.sidx(OPP[q], ax, ay, az)];
                    } else {
                        qw = 0.5;
                    }
                } else {
                    out = back / (2.0 * qw)
                        + (2.0 * qw - 1.0) / (2.0 * qw) * self.src[self.sidx(q, x, y, z)];
                }
            }
            let sum = back + out;
            let fl = [-sum * CF[q][0], -sum * CF[q][1], -sum * CF[q][2]];
            let r = [
                x as f64 - qw * CF[q][0] - self.center[0],
                y as f64 - qw * CF[q][1] - self.center[1],
                z as f64 - qw * CF[q][2] - self.center[2],
            ];
            let t = cross(r, fl);
            for a in 0..3 {
                stat.force[a] += fl[a];
                stat.torque[a] += t[a];
            }
            return out;
        }
        self.src[self.sidx(q, sx, sy, sz)]
    }

    /// The fluid cell at `x + c` (periodic wrap), if any.
    fn fluid_neighbour(
        &self,
        x: usize,
        y: usize,
        z: usize,
        c: [i32; 3],
    ) -> Option<(usize, usize, usize)> {
        let n = [self.nx as isize, self.ny as isize, self.nz as isize];
        let mut p = [
            x as isize + c[0] as isize,
            y as isize + c[1] as isize,
            z as isize + c[2] as isize,
        ];
        for a in 0..3 {
            if p[a] < 0 || p[a] >= n[a] {
                if !self.periodic[a] {
                    return None;
                }
                p[a] = p[a].rem_euclid(n[a]);
            }
        }
        let (a, b, d) = (p[0] as usize, p[1] as usize, p[2] as usize);
        (self.kind[self.cell(a, b, d)] != SOLID).then_some((a, b, d))
    }

    fn outlet_distance(&self, x: usize, y: usize, z: usize) -> usize {
        let p = [x, y, z];
        let n = [self.nx, self.ny, self.nz];
        let mut d = usize::MAX;
        for fi in 0..6 {
            if let Face::Pressure { .. } = self.faces[fi] {
                let a = fi / 2;
                d = d.min(if fi % 2 == 0 { p[a] } else { n[a] - 1 - p[a] });
            }
        }
        d
    }

    fn plane(&self, z: usize, dst: &mut [f64], mac: &mut [[f64; 4]], stat: &mut PlaneStat) {
        *stat = PlaneStat::default();
        let (nx, ny) = (self.nx, self.ny);
        let nxny = nx * ny;
        let zs = [z, self.zm[z], self.zp[z]];
        let sel = |v: i32| match v {
            0 => 0usize,
            1 => 1,
            _ => 2,
        };
        for y in 0..ny {
            let ys = [y, self.ym[y], self.yp[y]];
            // Start of the source row of each direction (only valid for bulk cells).
            let mut row = [0usize; Q];
            for q in 0..Q {
                let cq = C[q];
                row[q] = ((zs[sel(cq[2])] * Q + q) * ny + ys[sel(cq[1])]) * nx;
            }
            for x in 0..nx {
                let c = y * nx + x;
                let cell = z * nxny + c;
                let k = self.kind[cell];
                if k == SOLID {
                    mac[c] = [1.0, 0.0, 0.0, 0.0];
                    for q in 0..Q {
                        dst[q * nxny + c] = W[q];
                    }
                    continue;
                }
                let mut f = [0.0; Q];
                if k == BULK {
                    if x > 0 && x + 1 < nx {
                        for q in 0..Q {
                            f[q] = self.src[row[q] + (x as isize - C[q][0] as isize) as usize];
                        }
                    } else {
                        let xs = [x, self.xm[x], self.xp[x]];
                        for q in 0..Q {
                            f[q] = self.src[row[q] + xs[sel(C[q][0])]];
                        }
                    }
                } else {
                    let old = mac[c];
                    for q in 0..Q {
                        f[q] = self.pull_edge(q, x, y, z, old, stat);
                    }
                }
                let pre = f;
                let (rho, u) = collide(&mut f, &self.col);
                if let Some((cells, strength)) = self.sponge {
                    // Density sponge in front of pressure outlets: relaxes rho toward 1 at
                    // fixed velocity, which absorbs the acoustic waves an outlet reflects.
                    let d = self.outlet_distance(x, y, z);
                    if d < cells {
                        let xi = 1.0 - d as f64 / cells as f64;
                        let k = strength * xi * xi * (1.0 - rho);
                        let mut e = [0.0; Q];
                        equilibrium(1.0, u, &mut e);
                        for q in 0..Q {
                            f[q] += k * e[q];
                        }
                    }
                }
                if let Some(por) = self.porosity {
                    let ns = por[cell];
                    if ns > 0.0 {
                        // Partial bounce-back (Walsh, Burwinkle and Saar 2009).
                        let mut dm = [0.0; 3];
                        for q in 0..Q {
                            let out = (1.0 - ns) * f[q] + ns * pre[OPP[q]];
                            let d = out - f[q];
                            for a in 0..3 {
                                dm[a] += d * CF[q][a];
                            }
                            f[q] = out;
                        }
                        let fl = [-dm[0], -dm[1], -dm[2]];
                        let r = [
                            x as f64 - self.center[0],
                            y as f64 - self.center[1],
                            z as f64 - self.center[2],
                        ];
                        let t = cross(r, fl);
                        for a in 0..3 {
                            stat.force[a] += fl[a];
                            stat.torque[a] += t[a];
                        }
                    }
                }
                for q in 0..Q {
                    dst[q * nxny + c] = f[q];
                }
                mac[c] = [rho, u[0], u[1], u[2]];
            }
        }
    }
}

#[inline(always)]
fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// Collides one cell in place; returns density and velocity (with half the force).
#[inline(always)]
fn collide(f: &mut [f64; Q], p: &Col) -> (f64, [f64; 3]) {
    let mut rho = 0.0;
    let mut j = [0.0; 3];
    for q in 0..Q {
        rho += f[q];
        j[0] += f[q] * CF[q][0];
        j[1] += f[q] * CF[q][1];
        j[2] += f[q] * CF[q][2];
    }
    let inv = 1.0 / rho;
    let fo = p.force;
    let u = [
        (j[0] + 0.5 * fo[0]) * inv,
        (j[1] + 0.5 * fo[1]) * inv,
        (j[2] + 0.5 * fo[2]) * inv,
    ];
    let mut feq = [0.0; Q];
    equilibrium(rho, u, &mut feq);
    let need_pi = p.regularized || p.smag.is_some();
    let mut pi = [0.0; 6]; // xx yy zz xy xz yz
    if need_pi {
        for q in 0..Q {
            let d = f[q] - feq[q];
            let c = CF[q];
            pi[0] += d * c[0] * c[0];
            pi[1] += d * c[1] * c[1];
            pi[2] += d * c[2] * c[2];
            pi[3] += d * c[0] * c[1];
            pi[4] += d * c[0] * c[2];
            pi[5] += d * c[1] * c[2];
        }
    }
    let mut tau = p.tau;
    if let Some(cs) = p.smag {
        // Smagorinsky through the local non-equilibrium stress (Hou et al. 1996): with
        // nu_t = (Cs dx)^2 |S| and |S| from Pi_neq, tau solves a quadratic.
        let mut s = pi;
        if p.has_force {
            // Chapman-Enskog estimate of Pi^(1) with Guo forcing adds (F u + u F) / 2.
            s[0] += fo[0] * u[0];
            s[1] += fo[1] * u[1];
            s[2] += fo[2] * u[2];
            s[3] += 0.5 * (fo[0] * u[1] + fo[1] * u[0]);
            s[4] += 0.5 * (fo[0] * u[2] + fo[2] * u[0]);
            s[5] += 0.5 * (fo[1] * u[2] + fo[2] * u[1]);
        }
        let qn = (s[0] * s[0]
            + s[1] * s[1]
            + s[2] * s[2]
            + 2.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]))
            .sqrt();
        tau = 0.5
            * (p.tau
                + (p.tau * p.tau + 18.0 * std::f64::consts::SQRT_2 * cs * cs * qn * inv).sqrt());
    }
    let omega = 1.0 / tau;
    let mut src = [0.0; Q];
    if p.has_force {
        let k = 1.0 - 0.5 * omega;
        for q in 0..Q {
            let c = CF[q];
            let cu = dot(c, u);
            let a = [
                3.0 * (c[0] - u[0]) + 9.0 * cu * c[0],
                3.0 * (c[1] - u[1]) + 9.0 * cu * c[1],
                3.0 * (c[2] - u[2]) + 9.0 * cu * c[2],
            ];
            src[q] = k * W[q] * dot(a, fo);
        }
    }
    if p.regularized {
        let tr = (pi[0] + pi[1] + pi[2]) * CS2;
        let keep = 1.0 - omega;
        // With Guo forcing u carries half the force, so the pre-collision state has a first-order
        // non-equilibrium moment j - rho u = -F/2; it is kept and relaxed like in BGK, otherwise
        // the projection drops part of the force (12.5 % at tau = 0.8).
        let m1 = [-0.5 * fo[0], -0.5 * fo[1], -0.5 * fo[2]];
        for q in 0..Q {
            let c = CF[q];
            let qp = c[0] * c[0] * pi[0]
                + c[1] * c[1] * pi[1]
                + c[2] * c[2] * pi[2]
                + 2.0 * (c[0] * c[1] * pi[3] + c[0] * c[2] * pi[4] + c[1] * c[2] * pi[5])
                - tr;
            f[q] = feq[q] + keep * W[q] * (4.5 * qp + 3.0 * dot(c, m1)) + src[q];
        }
    } else {
        for q in 0..Q {
            f[q] += -omega * (f[q] - feq[q]) + src[q];
        }
    }
    (rho, u)
}

fn wrap_tables(n: usize) -> (Vec<usize>, Vec<usize>) {
    let m = (0..n).map(|i| if i == 0 { n - 1 } else { i - 1 }).collect();
    let p = (0..n).map(|i| if i + 1 == n { 0 } else { i + 1 }).collect();
    (m, p)
}

impl Solver {
    /// A solver at rest (density 1, velocity 0), every cell fluid.
    pub fn new(cfg: Config) -> Result<Solver, EngineError> {
        let [nx, ny, nz] = cfg.dims;
        if nx == 0 || ny == 0 || nz == 0 {
            return Err(EngineError::new(
                "bad_grid",
                "every dimension needs at least one cell",
            ));
        }
        let n = nx
            .checked_mul(ny)
            .and_then(|v| v.checked_mul(nz))
            .ok_or_else(|| EngineError::new("too_large", "grid too large"))?;
        if n > 200_000_000 {
            return Err(EngineError::new(
                "too_large",
                format!("{n} cells is more than the 200M limit"),
            ));
        }
        if !(cfg.tau > 0.5 && cfg.tau.is_finite()) {
            return Err(EngineError::new(
                "unstable",
                format!("tau {} must be above 0.5", cfg.tau),
            ));
        }
        for a in 0..3 {
            let (lo, hi) = (cfg.faces[2 * a], cfg.faces[2 * a + 1]);
            if (lo == Face::Periodic) != (hi == Face::Periodic) {
                return Err(EngineError::new(
                    "bad_boundary",
                    format!("axis {a}: periodic faces come in pairs"),
                ));
            }
        }
        if let Some(c) = cfg.smagorinsky
            && !(0.0..=0.5).contains(&c)
        {
            return Err(EngineError::new(
                "bad_parameter",
                "smagorinsky constant must be in [0, 0.5]",
            ));
        }
        let mut reflect = [[0usize; Q]; 8];
        for (mask, row) in reflect.iter_mut().enumerate() {
            for q in 0..Q {
                let mut c = C[q];
                for (a, ca) in c.iter_mut().enumerate() {
                    if mask & (1 << a) != 0 {
                        *ca = -*ca;
                    }
                }
                row[q] = (0..Q).find(|&r| C[r] == c).unwrap_or(q);
            }
        }
        let mut s = Solver {
            nx,
            ny,
            nz,
            f: vec![0.0; n * Q],
            f2: vec![0.0; n * Q],
            mac: vec![[1.0, 0.0, 0.0, 0.0]; n],
            kind: vec![BULK; n],
            solid: vec![false; n],
            porosity: None,
            dirty: true,
            stats: vec![PlaneStat::default(); nz],
            prev_u: Vec::new(),
            torque_center: [0.0; 3],
            steps: 0,
            reflect,
            sponge: None,
            links: Vec::new(),
            cfg,
        };
        s.init(|_, _, _| (1.0, [0.0; 3]));
        Ok(s)
    }

    /// The set-up.
    pub fn config(&self) -> &Config {
        &self.cfg
    }
    /// Cells along x, y, z.
    pub fn dims(&self) -> [usize; 3] {
        [self.nx, self.ny, self.nz]
    }
    /// Steps run so far.
    pub fn steps(&self) -> u64 {
        self.steps
    }
    /// Kinematic viscosity of the molecular part, lattice units.
    pub fn viscosity(&self) -> f64 {
        (self.cfg.tau - 0.5) * CS2
    }

    /// Linear cell index `(z * ny + y) * nx + x`.
    pub fn index(&self, x: usize, y: usize, z: usize) -> usize {
        (z * self.ny + y) * self.nx + x
    }

    /// Changes the uniform body force (lattice units).
    pub fn set_body_force(&mut self, g: [f64; 3]) {
        self.cfg.body_force = g;
    }

    /// Changes a face condition (the periodic pairing must stay as built).
    pub fn set_face(&mut self, i: usize, face: Face) -> Result<(), EngineError> {
        if (face == Face::Periodic) != (self.cfg.faces[i] == Face::Periodic) {
            return Err(EngineError::new(
                "bad_boundary",
                "a face cannot switch to or from periodic",
            ));
        }
        self.cfg.faces[i] = face;
        Ok(())
    }

    /// Density sponge of `cells` cells in front of every pressure outlet, relaxation rate up to
    /// `strength` per step (quadratic ramp, 0.02 to 0.1 typical). It damps the acoustic waves that
    /// a velocity inlet and a pressure outlet otherwise reflect back and forth for thousands of
    /// steps at low viscosity; `cells = 0` turns it off.
    pub fn set_sponge(&mut self, cells: usize, strength: f64) {
        self.sponge = (cells > 0 && strength > 0.0).then_some((cells, strength.min(1.0)));
    }

    /// Wall distances for interpolated bounce-back (Bouzidi, Firdaouss and Lallemand 2001).
    /// For every link from a fluid cell centre `p` (cell coordinates) toward a solid voxel along
    /// `d = -c_q`, `dist(p, d)` returns the fraction `t` in (0, 1] at which the wall is crossed
    /// (`p + t d`), or `None` to keep halfway bounce-back (`t = 1/2`). Call after the solid mask
    /// is final; changing the mask clears the distances.
    pub fn set_wall_distance(&mut self, dist: impl Fn([f64; 3], [f64; 3]) -> Option<f64>) {
        if self.dirty {
            self.classify();
        }
        let (nx, ny, nz) = (self.nx, self.ny, self.nz);
        let periodic = [
            self.cfg.faces[0] == Face::Periodic,
            self.cfg.faces[2] == Face::Periodic,
            self.cfg.faces[4] == Face::Periodic,
        ];
        let mut links = Vec::new();
        for z in 0..nz {
            for y in 0..ny {
                for x in 0..nx {
                    let i = self.index(x, y, z);
                    if self.kind[i] != EDGE {
                        continue;
                    }
                    'q: for q in 1..Q {
                        let c = C[q];
                        let n = [nx as isize, ny as isize, nz as isize];
                        let mut p = [
                            x as isize - c[0] as isize,
                            y as isize - c[1] as isize,
                            z as isize - c[2] as isize,
                        ];
                        for a in 0..3 {
                            if p[a] < 0 || p[a] >= n[a] {
                                if !periodic[a] {
                                    continue 'q;
                                }
                                p[a] = p[a].rem_euclid(n[a]);
                            }
                        }
                        if !self.solid[self.index(p[0] as usize, p[1] as usize, p[2] as usize)] {
                            continue;
                        }
                        let d = [-CF[q][0], -CF[q][1], -CF[q][2]];
                        if let Some(t) = dist([x as f64, y as f64, z as f64], d)
                            && t.is_finite()
                        {
                            links.push(((i * Q + q) as u64, t.clamp(1e-3, 1.0)));
                        }
                    }
                }
            }
        }
        self.links = links;
    }

    /// Marks one voxel solid or fluid.
    pub fn set_solid(&mut self, x: usize, y: usize, z: usize, solid: bool) {
        let i = self.index(x, y, z);
        self.solid[i] = solid;
        self.dirty = true;
        self.links.clear();
    }

    /// Replaces the solid mask (length `nx * ny * nz`, cell index order).
    pub fn set_solid_mask(&mut self, mask: &[bool]) -> Result<(), EngineError> {
        if mask.len() != self.solid.len() {
            return Err(EngineError::new(
                "bad_mask",
                format!(
                    "mask has {} cells, grid has {}",
                    mask.len(),
                    self.solid.len()
                ),
            ));
        }
        self.solid.copy_from_slice(mask);
        self.dirty = true;
        self.links.clear();
        Ok(())
    }

    /// Solid mask.
    pub fn solid_mask(&self) -> &[bool] {
        &self.solid
    }

    /// Partial bounce-back fraction `n_s` per cell in [0, 1] (0 fluid, 1 fully reflecting),
    /// applied on fluid cells. See [`crate::porosity_from_design`] for the mapping from a
    /// topology optimisation density.
    pub fn set_porosity(&mut self, ns: Option<Vec<f64>>) -> Result<(), EngineError> {
        if let Some(v) = &ns {
            if v.len() != self.solid.len() {
                return Err(EngineError::new(
                    "bad_mask",
                    "porosity field has the wrong length",
                ));
            }
            if v.iter().any(|x| !(0.0..=1.0).contains(x)) {
                return Err(EngineError::new(
                    "bad_mask",
                    "porosity values must be in [0, 1]",
                ));
            }
        }
        self.porosity = ns;
        Ok(())
    }

    /// Sets every fluid cell to the equilibrium of `init(x, y, z) -> (rho, u)`.
    pub fn init(&mut self, init: impl Fn(usize, usize, usize) -> (f64, [f64; 3]) + Sync) {
        let (nx, ny) = (self.nx, self.ny);
        let nxny = nx * ny;
        self.f
            .par_chunks_mut(Q * nxny)
            .zip(self.mac.par_chunks_mut(nxny))
            .enumerate()
            .for_each(|(z, (fp, mp))| {
                let mut feq = [0.0; Q];
                for y in 0..ny {
                    for x in 0..nx {
                        let c = y * nx + x;
                        let (rho, u) = init(x, y, z);
                        equilibrium(rho, u, &mut feq);
                        for q in 0..Q {
                            fp[q * nxny + c] = feq[q];
                        }
                        mp[c] = [rho, u[0], u[1], u[2]];
                    }
                }
            });
    }

    fn classify(&mut self) {
        let (nx, ny, nz) = (self.nx, self.ny, self.nz);
        let periodic = [
            self.cfg.faces[0] == Face::Periodic,
            self.cfg.faces[2] == Face::Periodic,
            self.cfg.faces[4] == Face::Periodic,
        ];
        let solid = &self.solid;
        self.kind
            .par_chunks_mut(nx * ny)
            .enumerate()
            .for_each(|(z, kp)| {
                for y in 0..ny {
                    for x in 0..nx {
                        let i = (z * ny + y) * nx + x;
                        if solid[i] {
                            kp[y * nx + x] = SOLID;
                            continue;
                        }
                        let mut k = BULK;
                        'dirs: for c in C.iter().skip(1) {
                            let p = [
                                x as isize + c[0] as isize,
                                y as isize + c[1] as isize,
                                z as isize + c[2] as isize,
                            ];
                            let n = [nx as isize, ny as isize, nz as isize];
                            let mut s = [0usize; 3];
                            for a in 0..3 {
                                let mut v = p[a];
                                if v < 0 || v >= n[a] {
                                    if !periodic[a] {
                                        k = EDGE;
                                        break 'dirs;
                                    }
                                    v = v.rem_euclid(n[a]);
                                }
                                s[a] = v as usize;
                            }
                            if solid[(s[2] * ny + s[1]) * nx + s[0]] {
                                k = EDGE;
                                break;
                            }
                        }
                        kp[y * nx + x] = k;
                    }
                }
            });
        self.dirty = false;
    }

    /// One time step.
    pub fn step(&mut self) {
        if self.dirty {
            self.classify();
        }
        let (nx, ny, nz) = (self.nx, self.ny, self.nz);
        let (xm, xp) = wrap_tables(nx);
        let (ym, yp) = wrap_tables(ny);
        let (zm, zp) = wrap_tables(nz);
        let faces = self.cfg.faces;
        let periodic = [
            faces[0] == Face::Periodic,
            faces[2] == Face::Periodic,
            faces[4] == Face::Periodic,
        ];
        let mut parabolic = [[false; 3]; 6];
        for (fi, row) in parabolic.iter_mut().enumerate() {
            for (b, v) in row.iter_mut().enumerate() {
                *v = b != fi / 2 && !periodic[b];
            }
        }
        let g = self.cfg.body_force;
        let pass = Pass {
            nx,
            ny,
            nz,
            src: &self.f,
            kind: &self.kind,
            porosity: self.porosity.as_deref(),
            faces: &faces,
            periodic,
            parabolic,
            xm: &xm,
            xp: &xp,
            ym: &ym,
            yp: &yp,
            zm: &zm,
            zp: &zp,
            reflect: &self.reflect,
            center: self.torque_center,
            col: Col {
                tau: self.cfg.tau,
                regularized: self.cfg.collision == Collision::Regularized,
                smag: self.cfg.smagorinsky.filter(|c| *c > 0.0),
                force: g,
                has_force: g != [0.0; 3],
            },
            sponge: self.sponge,
            links: &self.links,
        };
        let nxny = nx * ny;
        self.f2
            .par_chunks_mut(Q * nxny)
            .zip(self.mac.par_chunks_mut(nxny))
            .zip(self.stats.par_iter_mut())
            .enumerate()
            .for_each(|(z, ((dst, mac), stat))| {
                pass.plane(z, dst, mac, stat);
            });
        std::mem::swap(&mut self.f, &mut self.f2);
        self.steps += 1;
    }

    /// Runs `n` steps.
    pub fn run(&mut self, n: u64) {
        for _ in 0..n {
            self.step();
        }
    }

    /// Runs until [`Solver::relative_change`] measured every `every` steps falls under `tol`,
    /// or `max` steps. Returns `(steps run, converged)`.
    pub fn run_to_steady(&mut self, max: u64, every: u64, tol: f64) -> (u64, bool) {
        let every = every.max(1);
        self.relative_change();
        let mut done = 0;
        while done < max {
            let k = every.min(max - done);
            self.run(k);
            done += k;
            let r = self.relative_change();
            if !r.is_finite() {
                return (done, false);
            }
            if r < tol {
                return (done, true);
            }
        }
        (done, false)
    }

    /// Relative L2 change of the velocity field since the previous call
    /// (`|u - u_prev| / |u|`, fluid cells); 1 on the first call.
    pub fn relative_change(&mut self) -> f64 {
        let first = self.prev_u.len() != self.mac.len();
        if first {
            self.prev_u = vec![[0.0; 3]; self.mac.len()];
        }
        let nxny = self.nx * self.ny;
        let sums: Vec<(f64, f64)> = self
            .mac
            .par_chunks(nxny)
            .zip(self.prev_u.par_chunks_mut(nxny))
            .map(|(m, p)| {
                let (mut d, mut s) = (0.0, 0.0);
                for (mi, pi) in m.iter().zip(p.iter_mut()) {
                    let u = [mi[1], mi[2], mi[3]];
                    for a in 0..3 {
                        d += (u[a] - pi[a]) * (u[a] - pi[a]);
                        s += u[a] * u[a];
                    }
                    *pi = u;
                }
                (d, s)
            })
            .collect();
        let (d, s) = sums.iter().fold((0.0, 0.0), |a, b| (a.0 + b.0, a.1 + b.1));
        if first {
            return 1.0;
        }
        if s == 0.0 {
            return if d == 0.0 { 0.0 } else { f64::INFINITY };
        }
        (d / s).sqrt()
    }

    /// Density at a cell (last step).
    pub fn density(&self, x: usize, y: usize, z: usize) -> f64 {
        self.mac[self.index(x, y, z)][0]
    }
    /// Velocity at a cell (last step).
    pub fn velocity(&self, x: usize, y: usize, z: usize) -> [f64; 3] {
        let m = self.mac[self.index(x, y, z)];
        [m[1], m[2], m[3]]
    }
    /// Per cell `[rho, ux, uy, uz]`, cell index order.
    pub fn macroscopic(&self) -> &[[f64; 4]] {
        &self.mac
    }
    /// Raw populations (layout in the module doc), for determinism checks.
    pub fn populations(&self) -> &[f64] {
        &self.f
    }

    /// Force of the fluid on the solid voxels and porous cells in the last step (lattice units).
    pub fn force(&self) -> [f64; 3] {
        self.stats.iter().fold([0.0; 3], |a, s| {
            [a[0] + s.force[0], a[1] + s.force[1], a[2] + s.force[2]]
        })
    }
    /// Torque about `torque_center` of the same force (lattice units).
    pub fn torque(&self) -> [f64; 3] {
        self.stats.iter().fold([0.0; 3], |a, s| {
            [a[0] + s.torque[0], a[1] + s.torque[1], a[2] + s.torque[2]]
        })
    }

    /// Largest velocity magnitude over fluid cells (lattice units).
    pub fn max_velocity(&self) -> f64 {
        let nxny = self.nx * self.ny;
        let per: Vec<f64> = self
            .mac
            .par_chunks(nxny)
            .zip(self.kind.par_chunks(nxny))
            .map(|(m, k)| {
                m.iter()
                    .zip(k)
                    .filter(|(_, k)| **k != SOLID)
                    .map(|(m, _)| (m[1] * m[1] + m[2] * m[2] + m[3] * m[3]).sqrt())
                    .fold(0.0, f64::max)
            })
            .collect();
        per.into_iter().fold(0.0, f64::max)
    }

    /// Mean density over the fluid cells of the plane `index` normal to `axis`.
    pub fn plane_mean_density(&self, axis: usize, index: usize) -> f64 {
        let (mut s, mut n) = (0.0, 0usize);
        let d = self.dims();
        for z in 0..d[2] {
            for y in 0..d[1] {
                for x in 0..d[0] {
                    if [x, y, z][axis] != index {
                        continue;
                    }
                    let i = self.index(x, y, z);
                    if !self.solid[i] {
                        s += self.mac[i][0];
                        n += 1;
                    }
                }
            }
        }
        if n == 0 { 1.0 } else { s / n as f64 }
    }

    /// Velocity interpolated trilinearly at a point in cell coordinates (clamped to the grid).
    pub fn sample(&self, p: [f64; 3]) -> [f64; 4] {
        let d = self.dims();
        let mut i0 = [0usize; 3];
        let mut t = [0.0; 3];
        for a in 0..3 {
            let v = p[a].clamp(0.0, (d[a] - 1) as f64);
            let fl = v.floor().min((d[a].max(2) - 2) as f64).max(0.0);
            i0[a] = fl as usize;
            t[a] = if d[a] == 1 { 0.0 } else { v - fl };
        }
        let mut out = [0.0; 4];
        for corner in 0..8 {
            let mut w = 1.0;
            let mut c = [0usize; 3];
            for a in 0..3 {
                let hi = corner >> a & 1 == 1;
                c[a] = if hi { (i0[a] + 1).min(d[a] - 1) } else { i0[a] };
                w *= if hi { t[a] } else { 1.0 - t[a] };
            }
            if w == 0.0 {
                continue;
            }
            let m = self.mac[self.index(c[0], c[1], c[2])];
            for k in 0..4 {
                out[k] += w * m[k];
            }
        }
        out
    }
}
