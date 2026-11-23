//! JSON facade: `call(op, params)`, shared by the bridge, the node addon, the agent and the CLI.
//!
//! Ops: `version`, `presets`, `units`, `run`. Fields are documented in `docs/fluid/ENGINE.md`.

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::geometry::{Shape, voxelize};
use crate::solver::{Collision, Config, Face, Solver};
use crate::thermal::{Thermal, ThermalConfig, ThermalFace};
use crate::units::{Fluid, Units};
use crate::{EngineError, porosity_from_design};

fn arg<T: DeserializeOwned>(p: &Value, name: &str) -> Result<T, EngineError> {
    serde_json::from_value(p.get(name).cloned().unwrap_or(Value::Null))
        .map_err(|e| EngineError::new("bad_params", format!("{name}: {e}")))
}

/// Runs one op.
pub fn call(op: &str, params: &Value) -> Result<Value, EngineError> {
    match op {
        "version" => Ok(
            json!({"engine": "viaform-fluid", "version": env!("CARGO_PKG_VERSION"), "lattice": "D3Q19", "scalar": "D3Q7"}),
        ),
        "presets" => Ok(json!({
            "air": {"density": Fluid::AIR.density, "viscosity": Fluid::AIR.viscosity, "thermal_diffusivity": 2.15e-5, "heat_capacity": 1005.0},
            "water": {"density": Fluid::WATER.density, "viscosity": Fluid::WATER.viscosity, "thermal_diffusivity": 1.43e-7, "heat_capacity": 4182.0}
        })),
        "units" => {
            let fluid = fluid(params)?;
            let h = arg::<f64>(params, "voxel_mm")? * 1e-3;
            let u = arg::<f64>(params, "inlet_velocity")?;
            let mach = arg::<Option<f64>>(params, "mach")?.unwrap_or(0.1);
            let un = Units::from_mach(h, u, fluid.0.density, mach)?;
            Ok(
                json!({"dx_m": un.dx, "dt_s": un.dt, "u_lattice": un.velocity_to_lattice(u), "tau": un.tau(fluid.0.viscosity), "nu_lattice": un.viscosity_to_lattice(fluid.0.viscosity)}),
            )
        }
        "run" => run(params),
        other => Err(EngineError::new(
            "unknown_op",
            format!("unknown op {other}"),
        )),
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum FluidArg {
    Name(String),
    Props {
        density: f64,
        viscosity: f64,
        #[serde(default)]
        thermal_diffusivity: Option<f64>,
        #[serde(default)]
        heat_capacity: Option<f64>,
    },
}

/// (fluid, thermal diffusivity m2/s, heat capacity J/(kg K)).
fn fluid(p: &Value) -> Result<(Fluid, f64, f64), EngineError> {
    match arg::<Option<FluidArg>>(p, "fluid")? {
        None => Ok((Fluid::AIR, 2.15e-5, 1005.0)),
        Some(FluidArg::Name(n)) => match n.as_str() {
            "air" => Ok((Fluid::AIR, 2.15e-5, 1005.0)),
            "water" => Ok((Fluid::WATER, 1.43e-7, 4182.0)),
            _ => Err(EngineError::new(
                "bad_params",
                format!("unknown fluid {n} (air, water or {{density, viscosity}})"),
            )),
        },
        Some(FluidArg::Props {
            density,
            viscosity,
            thermal_diffusivity,
            heat_capacity,
        }) => {
            if !(density > 0.0 && viscosity > 0.0) {
                return Err(EngineError::new(
                    "bad_params",
                    "fluid density and viscosity must be positive",
                ));
            }
            Ok((
                Fluid { density, viscosity },
                thermal_diffusivity.unwrap_or(viscosity / 0.71),
                heat_capacity.unwrap_or(1005.0),
            ))
        }
    }
}

#[derive(Deserialize)]
struct ThermalArg {
    /// Inlet (and initial) temperature, C.
    #[serde(default)]
    inlet_c: f64,
    /// Temperature of every obstacle, C (a heated part).
    obstacle_c: f64,
}

fn run(p: &Value) -> Result<Value, EngineError> {
    let domain: [f64; 3] = arg(p, "domain_mm")?;
    let h_mm: f64 = arg(p, "voxel_mm")?;
    if h_mm.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater)
        || domain
            .iter()
            .any(|d| d.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater))
    {
        return Err(EngineError::new(
            "bad_params",
            "domain_mm and voxel_mm must be positive",
        ));
    }
    let dims = [0, 1, 2].map(|a| ((domain[a] / h_mm).round() as usize).max(1));
    let n = dims[0] * dims[1] * dims[2];
    let max_cells = arg::<Option<usize>>(p, "max_cells")?.unwrap_or(20_000_000);
    if n > max_cells {
        return Err(EngineError::new(
            "too_large",
            format!("{n} voxels is more than max_cells {max_cells}"),
        ));
    }
    let (fl, alpha, cp) = fluid(p)?;
    let u_in: f64 = arg(p, "inlet_velocity")?;
    let mach = arg::<Option<f64>>(p, "mach")?.unwrap_or(0.1);
    let units = Units::from_mach(h_mm * 1e-3, u_in, fl.density, mach)?;
    let tau = units.tau(fl.viscosity);
    let collision = arg::<Option<Collision>>(p, "collision")?.unwrap_or_default();
    let smag = match p.get("smagorinsky") {
        None | Some(Value::String(_)) => (tau < 0.55).then_some(0.14),
        Some(Value::Null) => None,
        Some(v) => Some(v.as_f64().ok_or_else(|| {
            EngineError::new("bad_params", "smagorinsky: a number, null, or \"auto\"")
        })?),
    };
    let sides = match arg::<Option<String>>(p, "sides")?
        .as_deref()
        .unwrap_or("slip")
    {
        "slip" => Face::Slip,
        "wall" => Face::Wall { velocity: [0.0; 3] },
        "periodic" => Face::Periodic,
        s => {
            return Err(EngineError::new(
                "bad_params",
                format!("sides: slip, wall or periodic, not {s}"),
            ));
        }
    };
    let ul = units.velocity_to_lattice(u_in);
    let cfg = Config {
        dims,
        tau,
        collision,
        smagorinsky: smag,
        body_force: [0.0; 3],
        faces: [
            Face::Velocity {
                velocity: [ul, 0.0, 0.0],
                profile: Default::default(),
            },
            Face::Pressure { density: 1.0 },
            sides,
            sides,
            sides,
            sides,
        ],
    };
    let mut s = Solver::new(cfg)?;
    // Start at rest and ramp the inlet (sin^2 over `ramp_steps`, default one flow-through time):
    // an impulsive start launches pressure waves that the inlet and outlet reflect for a long time.
    let ramp = arg::<Option<u64>>(p, "ramp_steps")?.unwrap_or((dims[0] as f64 / ul).ceil() as u64);
    let sponge = arg::<Option<usize>>(p, "sponge_cells")?.unwrap_or((dims[0] / 8).min(24));
    s.set_sponge(sponge, 0.1);

    // Geometry: shapes in mm, an optional boolean mask and an optional solid-fraction field.
    let shapes = arg::<Option<Vec<Shape>>>(p, "obstacles")?.unwrap_or_default();
    let mut solid = voxelize(&shapes, dims, h_mm, [0.0; 3]);
    if let Some(mask) = arg::<Option<Vec<u8>>>(p, "mask")? {
        if mask.len() != n {
            return Err(EngineError::new(
                "bad_mask",
                format!("mask has {} values, grid has {n}", mask.len()),
            ));
        }
        for (s, m) in solid.iter_mut().zip(mask) {
            *s |= m != 0;
        }
    }
    if let Some(frac) = arg::<Option<Vec<f64>>>(p, "solid_fraction")? {
        if frac.len() != n {
            return Err(EngineError::new(
                "bad_mask",
                format!("solid_fraction has {} values, grid has {n}", frac.len()),
            ));
        }
        let q = arg::<Option<f64>>(p, "interpolation_q")?.unwrap_or(0.1);
        let mut ns = vec![0.0; n];
        for i in 0..n {
            if frac[i] >= 1.0 {
                solid[i] = true;
            } else {
                ns[i] = porosity_from_design(frac[i], q);
            }
        }
        s.set_porosity(Some(ns))?;
    }
    // Keep the inlet and outlet planes fluid so the boundary conditions see the fluid.
    for z in 0..dims[2] {
        for y in 0..dims[1] {
            solid[(z * dims[1] + y) * dims[0]] = false;
            solid[(z * dims[1] + y) * dims[0] + dims[0] - 1] = false;
        }
    }
    s.set_solid_mask(&solid)?;
    // Shapes have exact surfaces: interpolated bounce-back on their links (masks and densities
    // stay halfway). A link into a mask voxel no shape covers finds no hit and stays halfway.
    if arg::<Option<bool>>(p, "interpolated_walls")?.unwrap_or(true) && !shapes.is_empty() {
        s.set_wall_distance(crate::geometry::wall_distance(&shapes, h_mm, [0.0; 3]));
    }

    // Frontal area, centroid and torque centre.
    let mut cols = vec![false; dims[1] * dims[2]];
    let mut cen = [0.0; 3];
    let mut count = 0usize;
    for z in 0..dims[2] {
        for y in 0..dims[1] {
            for x in 0..dims[0] {
                if solid[(z * dims[1] + y) * dims[0] + x] {
                    cols[z * dims[1] + y] = true;
                    cen[0] += x as f64;
                    cen[1] += y as f64;
                    cen[2] += z as f64;
                    count += 1;
                }
            }
        }
    }
    let area_cells = cols.iter().filter(|c| **c).count() as f64;
    if count > 0 {
        cen = cen.map(|c| c / count as f64);
    }
    if let Some(t) = arg::<Option<[f64; 3]>>(p, "torque_about_mm")? {
        cen = t.map(|v| v / h_mm - 0.5);
    }
    s.torque_center = cen;

    let mut thermal = match arg::<Option<ThermalArg>>(p, "thermal")? {
        None => None,
        Some(t) => {
            let tau_g = 4.0 * units.viscosity_to_lattice(alpha) + 0.5;
            let tf = ThermalFace::Fixed {
                temperature: t.inlet_c,
            };
            let side = if sides == Face::Periodic {
                ThermalFace::Periodic
            } else {
                ThermalFace::Adiabatic
            };
            let mut th = Thermal::new(
                ThermalConfig {
                    dims,
                    tau: tau_g,
                    faces: [tf, ThermalFace::Outflow, side, side, side, side],
                },
                t.inlet_c,
            )?;
            let fixed: Vec<f64> = solid
                .iter()
                .map(|s| if *s { t.obstacle_c } else { f64::NAN })
                .collect();
            th.set_solids(&solid, &fixed)?;
            Some((th, t))
        }
    };

    let max_steps = arg::<Option<u64>>(p, "steps")?.unwrap_or(20_000);
    let tol = arg::<Option<f64>>(p, "tolerance")?.unwrap_or(1e-4);
    let every = arg::<Option<u64>>(p, "check_every")?.unwrap_or(100).max(1);
    let average = arg::<Option<u64>>(p, "average_steps")?.unwrap_or(every);
    let mut done = 0;
    let mut converged = false;
    let mut residual = f64::NAN;
    s.relative_change();
    while done < max_steps {
        let k = every.min(max_steps - done);
        for i in 0..k {
            let t = done + i;
            if t <= ramp {
                let a = if ramp == 0 {
                    1.0
                } else {
                    (0.5 * std::f64::consts::PI * t as f64 / ramp as f64)
                        .sin()
                        .powi(2)
                };
                s.set_face(
                    0,
                    Face::Velocity {
                        velocity: [ul * a, 0.0, 0.0],
                        profile: Default::default(),
                    },
                )?;
            }
            s.step();
            if let Some((th, _)) = thermal.as_mut() {
                th.step(Some(s.macroscopic()));
            }
        }
        done += k;
        residual = s.relative_change();
        if done <= ramp {
            continue;
        }
        if !residual.is_finite() || s.max_velocity() > 0.5 {
            return Err(EngineError::new(
                "diverged",
                format!("the run diverged after {done} steps (try a finer voxel or a lower mach)"),
            ));
        }
        if residual < tol {
            converged = true;
            break;
        }
    }
    // Forces averaged over the last `average` steps (unsteady wakes shed).
    let (mut fsum, mut tsum, mut heat) = ([0.0; 3], [0.0; 3], 0.0);
    for _ in 0..average.max(1) {
        s.step();
        if let Some((th, _)) = thermal.as_mut() {
            th.step(Some(s.macroscopic()));
            heat += th.heat_from_solids();
        }
        let (f, t) = (s.force(), s.torque());
        for a in 0..3 {
            fsum[a] += f[a];
            tsum[a] += t[a];
        }
    }
    let navg = average.max(1) as f64;
    let force = fsum.map(|v| units.force_to_physical(v / navg));
    let torque = tsum.map(|v| units.torque_to_physical(v / navg));
    let h = h_mm * 1e-3;
    let area = area_cells * h * h;
    let q_dyn = 0.5 * fl.density * u_in * u_in;
    let ref_len = arg::<Option<f64>>(p, "reference_length_mm")?
        .map(|v| v * 1e-3)
        .unwrap_or(if area > 0.0 {
            2.0 * (area / std::f64::consts::PI).sqrt()
        } else {
            domain[1] * 1e-3
        });
    let dp = units.pressure_to_physical(s.plane_mean_density(0, 0))
        - units.pressure_to_physical(s.plane_mean_density(0, dims[0] - 1));
    let mut out = json!({
        "grid": dims,
        "units": {"dx_m": units.dx, "dt_s": units.dt, "tau": tau, "u_lattice": ul, "smagorinsky": smag, "collision": collision},
        "steps": s.steps(),
        "converged": converged,
        "residual": residual,
        "time_s": units.time_to_physical(s.steps() as f64),
        "reynolds": u_in * ref_len / fl.viscosity,
        "reference_length_mm": ref_len * 1e3,
        "force_n": force,
        "drag_n": force[0],
        "side_n": force[1],
        "lift_n": force[2],
        "torque_nm": torque,
        "frontal_area_mm2": area * 1e6,
        "cd": if area > 0.0 { force[0] / (q_dyn * area) } else { 0.0 },
        "cl": if area > 0.0 { force[2] / (q_dyn * area) } else { 0.0 },
        "pressure_drop_pa": dp,
        "max_velocity_ms": units.velocity_to_physical(s.max_velocity()),
        "solid_voxels": count,
    });
    if let Some((th, t)) = &thermal {
        let w = heat / navg * fl.density * cp * h.powi(3) / units.dt;
        let temps = th.temperature();
        let tmax = temps
            .iter()
            .zip(&solid)
            .filter(|(_, s)| !**s)
            .map(|(t, _)| *t)
            .fold(f64::MIN, f64::max);
        let mut outlet = 0.0;
        let mut no = 0;
        for z in 0..dims[2] {
            for y in 0..dims[1] {
                outlet += th.at(dims[0] - 1, y, z);
                no += 1;
            }
        }
        out["thermal"] = json!({"heat_w": w, "max_fluid_c": tmax, "outlet_mean_c": outlet / no as f64, "inlet_c": t.inlet_c, "obstacle_c": t.obstacle_c});
    }
    if let Some(stride) = arg::<Option<usize>>(p, "field_stride")? {
        let st = stride.max(1);
        let mut vel = vec![];
        let mut pre = vec![];
        let sd = dims.map(|d| d.div_ceil(st));
        for z in (0..dims[2]).step_by(st) {
            for y in (0..dims[1]).step_by(st) {
                for x in (0..dims[0]).step_by(st) {
                    let m = s.macroscopic()[s.index(x, y, z)];
                    vel.push([m[1], m[2], m[3]].map(|v| units.velocity_to_physical(v)));
                    pre.push(units.pressure_to_physical(m[0]));
                }
            }
        }
        out["fields"] = json!({"dims": sd, "stride": st, "spacing_mm": h_mm * st as f64, "velocity_ms": vel, "pressure_pa": pre});
    }
    Ok(out)
}
