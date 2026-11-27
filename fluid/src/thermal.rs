//! Passive scalar (temperature) on D3Q7, advected by the flow solver's velocity.
//!
//! `g_eq_i = w_i T (1 + c_i.u / cs^2)` with `cs^2 = 1/4` (`w0 = 1/4`), BGK relaxation, so the
//! diffusivity is `kappa = (tau_g - 1/2) / 4`. Same layout, pull scheme and determinism rule as
//! the flow ([`crate::solver`]). Fixed-temperature walls and solids use halfway anti-bounce-back
//! (`g_i = -g_opp* + 2 w_i T_w`), adiabatic ones plain bounce-back. A volumetric source adds
//! `w_i S` per step (S in temperature per step). One-way coupling: temperature does not change
//! the flow (forced convection).

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use crate::EngineError;
use crate::lattice::{C7, OPP7, Q7, W7};

/// Thermal condition on a face (order `-x, +x, -y, +y, -z, +z`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ThermalFace {
    Periodic,
    /// Zero flux.
    Adiabatic,
    /// Fixed temperature (walls, inflow).
    Fixed {
        temperature: f64,
    },
    /// Zero gradient (outflow).
    Outflow,
}

/// Thermal set-up (lattice units).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ThermalConfig {
    pub dims: [usize; 3],
    /// `kappa = (tau - 1/2) / 4`.
    pub tau: f64,
    pub faces: [ThermalFace; 6],
}

/// D3Q7 temperature field.
pub struct Thermal {
    cfg: ThermalConfig,
    nx: usize,
    ny: usize,
    nz: usize,
    g: Vec<f64>,
    g2: Vec<f64>,
    temp: Vec<f64>,
    solid: Vec<bool>,
    fixed: Vec<f64>,
    source: Option<Vec<f64>>,
    heat: Vec<[f64; 2]>,
}

impl Thermal {
    /// Uniform temperature `t0`, no solids.
    pub fn new(cfg: ThermalConfig, t0: f64) -> Result<Thermal, EngineError> {
        let [nx, ny, nz] = cfg.dims;
        if nx * ny * nz == 0 {
            return Err(EngineError::new(
                "bad_grid",
                "every dimension needs at least one cell",
            ));
        }
        if !(cfg.tau > 0.5 && cfg.tau.is_finite()) {
            return Err(EngineError::new(
                "unstable",
                "thermal tau must be above 0.5",
            ));
        }
        for a in 0..3 {
            if (cfg.faces[2 * a] == ThermalFace::Periodic)
                != (cfg.faces[2 * a + 1] == ThermalFace::Periodic)
            {
                return Err(EngineError::new(
                    "bad_boundary",
                    "periodic faces come in pairs",
                ));
            }
        }
        let n = nx * ny * nz;
        let mut g = vec![0.0; n * Q7];
        for z in 0..nz {
            for q in 0..Q7 {
                for c in 0..nx * ny {
                    g[(z * Q7 + q) * nx * ny + c] = W7[q] * t0;
                }
            }
        }
        Ok(Thermal {
            nx,
            ny,
            nz,
            g2: g.clone(),
            g,
            temp: vec![t0; n],
            solid: vec![false; n],
            fixed: vec![f64::NAN; n],
            source: None,
            heat: vec![[0.0; 2]; nz],
            cfg,
        })
    }

    /// Diffusivity, lattice units.
    pub fn diffusivity(&self) -> f64 {
        (self.cfg.tau - 0.5) * 0.25
    }

    /// Solid voxels (same mask as the flow); `fixed[i]` is a solid's temperature, NaN for adiabatic.
    pub fn set_solids(&mut self, solid: &[bool], fixed: &[f64]) -> Result<(), EngineError> {
        if solid.len() != self.solid.len() || fixed.len() != self.solid.len() {
            return Err(EngineError::new(
                "bad_mask",
                "thermal solid mask has the wrong length",
            ));
        }
        self.solid.copy_from_slice(solid);
        self.fixed.copy_from_slice(fixed);
        Ok(())
    }

    /// Volumetric source per cell (temperature per step), or none.
    pub fn set_source(&mut self, s: Option<Vec<f64>>) -> Result<(), EngineError> {
        if s.as_ref().is_some_and(|v| v.len() != self.solid.len()) {
            return Err(EngineError::new(
                "bad_mask",
                "source field has the wrong length",
            ));
        }
        self.source = s;
        Ok(())
    }

    /// Temperature per cell (cell index order).
    pub fn temperature(&self) -> &[f64] {
        &self.temp
    }

    /// Temperature at a cell.
    pub fn at(&self, x: usize, y: usize, z: usize) -> f64 {
        self.temp[(z * self.ny + y) * self.nx + x]
    }

    /// Heat given to the fluid by fixed-temperature solids in the last step (temperature times
    /// cell volume per step; times `rho c_p dx^3 / dt` for watts).
    pub fn heat_from_solids(&self) -> f64 {
        self.heat.iter().map(|h| h[0]).sum()
    }

    /// Heat entering through fixed-temperature faces in the last step (same units). On an inflow
    /// face this includes the enthalpy the inflow carries in (absolute temperature times flow).
    pub fn heat_through_faces(&self) -> f64 {
        self.heat.iter().map(|h| h[1]).sum()
    }

    /// One step with the flow's macroscopic field (`[rho, ux, uy, uz]` per cell), or at rest.
    pub fn step(&mut self, flow: Option<&[[f64; 4]]>) {
        let (nx, ny, nz) = (self.nx, self.ny, self.nz);
        let nxny = nx * ny;
        let omega = 1.0 / self.cfg.tau;
        let periodic = [
            self.cfg.faces[0] == ThermalFace::Periodic,
            self.cfg.faces[2] == ThermalFace::Periodic,
            self.cfg.faces[4] == ThermalFace::Periodic,
        ];
        let src = &self.g;
        let solid = &self.solid;
        let fixed = &self.fixed;
        let source = self.source.as_deref();
        let faces = &self.cfg.faces;
        let sidx = |q: usize, x: usize, y: usize, z: usize| ((z * Q7 + q) * ny + y) * nx + x;
        self.g2
            .par_chunks_mut(Q7 * nxny)
            .zip(self.temp.par_chunks_mut(nxny))
            .zip(self.heat.par_iter_mut())
            .enumerate()
            .for_each(|(z, ((dst, tp), heat))| {
                *heat = [0.0; 2];
                for y in 0..ny {
                    for x in 0..nx {
                        let c = y * nx + x;
                        let cell = z * nxny + c;
                        if solid[cell] {
                            tp[c] = if fixed[cell].is_nan() {
                                tp[c]
                            } else {
                                fixed[cell]
                            };
                            for q in 0..Q7 {
                                dst[q * nxny + c] = W7[q] * tp[c];
                            }
                            continue;
                        }
                        let mut g = [0.0; Q7];
                        for q in 0..Q7 {
                            let cq = C7[q];
                            let mut s = [
                                x as isize - cq[0] as isize,
                                y as isize - cq[1] as isize,
                                z as isize - cq[2] as isize,
                            ];
                            let n = [nx as isize, ny as isize, nz as isize];
                            let mut face = None;
                            for a in 0..3 {
                                if s[a] < 0 || s[a] >= n[a] {
                                    if periodic[a] {
                                        s[a] = s[a].rem_euclid(n[a]);
                                    } else {
                                        face = Some(2 * a + usize::from(s[a] >= n[a]));
                                    }
                                }
                            }
                            let back = src[sidx(OPP7[q], x, y, z)];
                            g[q] = if let Some(fi) = face {
                                match faces[fi] {
                                    ThermalFace::Adiabatic => back,
                                    ThermalFace::Fixed { temperature } => {
                                        let v = -back + 2.0 * W7[q] * temperature;
                                        heat[1] += v - back;
                                        v
                                    }
                                    ThermalFace::Outflow => src[sidx(q, x, y, z)],
                                    ThermalFace::Periodic => unreachable!(),
                                }
                            } else {
                                let (sx, sy, sz) = (s[0] as usize, s[1] as usize, s[2] as usize);
                                let si = (sz * ny + sy) * nx + sx;
                                if solid[si] {
                                    if fixed[si].is_nan() {
                                        back
                                    } else {
                                        let v = -back + 2.0 * W7[q] * fixed[si];
                                        heat[0] += v - back;
                                        v
                                    }
                                } else {
                                    src[sidx(q, sx, sy, sz)]
                                }
                            };
                        }
                        let t: f64 = g.iter().sum();
                        let u = flow.map_or([0.0; 3], |m| [m[cell][1], m[cell][2], m[cell][3]]);
                        let s = source.map_or(0.0, |v| v[cell]);
                        for q in 0..Q7 {
                            let cu = C7[q][0] as f64 * u[0]
                                + C7[q][1] as f64 * u[1]
                                + C7[q][2] as f64 * u[2];
                            let eq = W7[q] * t * (1.0 + 4.0 * cu);
                            dst[q * nxny + c] = g[q] - omega * (g[q] - eq) + W7[q] * s;
                        }
                        tp[c] = t;
                    }
                }
            });
        std::mem::swap(&mut self.g, &mut self.g2);
    }
}
