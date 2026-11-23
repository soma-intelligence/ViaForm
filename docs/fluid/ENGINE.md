# ViaForm fluid engine

Crate `fluid/` (`viaform-fluid`). Lattice Boltzmann (LBM) flow on the same cubic voxels as the
generative engine, for drone rotor and frame aerodynamics, cooling airflow over ESCs and motors,
forced convection in enclosures, and later fluid and thermo-fluid topology optimisation on one
voxel grid. CPU, f64, rayon; the kernel is one local pass per step, so it maps to a wgpu compute
shader later. The solver runs in lattice units; `units.rs` converts to SI at the boundary.

## Method

| Piece | What it does | Code |
|---|---|---|
| Lattice | D3Q19, second-order equilibrium `w_i rho (1 + 3 c.u + 4.5 (c.u)^2 - 1.5 u^2)`, `cs^2 = 1/3` (Qian, d'Humieres and Lallemand 1992). | `lattice.rs` |
| Storage | Two buffers (pull from `f`, write `f2`, swap). Structure of arrays inside each z plane: index `((z * 19 + q) * ny + y) * nx + x`, so one z plane of all 19 directions is one contiguous slab. 2 x 152 bytes per cell (f64): 128^3 takes 640 MB. | `solver.rs` |
| Step | Fused pull-stream-collide: each fluid cell gathers `f_q(x - c_q)` from the previous post-collision state, applies the boundary rule on every link that crosses a wall or a solid, collides and writes its own 19 values. Cells are pre-classified (bulk, edge, solid) so bulk cells take a branch-free gather. | `Pass::plane` |
| Parallelism, determinism | rayon, one task per z plane (`par_chunks_mut` over the slabs). Each output value is a pure function of the previous buffer, so results are bitwise identical on any thread count (tested 1, 2, 5, 16 threads, and 1 vs all cores in the example). Forces, torques and the convergence norm are summed per plane, then over planes in z order. | `Solver::step` |
| BGK | Single relaxation time, `nu = (tau - 1/2) / 3` (Bhatnagar, Gross and Krook 1954; Qian et al. 1992). | `collide` |
| Regularized (default) | The non-equilibrium part is replaced by its projection on the second-order Hermite polynomial before relaxing, `f_i = f_eq_i + (1 - 1/tau) (w_i / (2 cs^4)) Q_i : Pi_neq` (Latt and Chopard 2006). Filters the ghost modes that make BGK blow up near `tau = 1/2`; same viscosity as BGK. With Guo forcing the first-order non-equilibrium moment `j - rho u = -F/2` is kept and relaxed as well, otherwise the projection loses `(1 - 1/(2 tau)) F / 2` of the force (found by the Poiseuille test: 12.5 % low before the fix). | `collide` |
| LES | Smagorinsky, `nu_t = (Cs dx)^2 |S|`, with `|S|` from the local non-equilibrium stress, which gives `tau = (tau0 + sqrt(tau0^2 + 18 sqrt(2) Cs^2 |Pi_neq| / rho)) / 2` per cell, no finite differences (Hou, Sterling, Chen and Doolen 1996). Off by default; the facade turns it on (Cs 0.14) when `tau < 0.55`. | `collide` |
| Body force | Guo, Zheng and Shi (2002): `u = (j + F/2) / rho`, source `(1 - 1/(2 tau)) w_i [3 (c_i - u) + 9 (c_i.u) c_i] . F`. Uniform force density (`Config.body_force`). | `collide` |
| Solid voxels | Halfway bounce-back on every link into a solid voxel (wall half a cell from the fluid cell centre), `f_i(x) = f*_opp(x)`. Second order for walls aligned with the grid, staircase for curved ones. | `Pass::pull_edge` |
| Curved walls | Linear interpolated bounce-back (Bouzidi, Firdaouss and Lallemand 2001) on links whose wall distance is known: `q < 1/2`: `f_i = 2q f*_opp(x) + (1 - 2q) f*_opp(x + c_i)`; `q >= 1/2`: `f_i = f*_opp(x) / (2q) + (2q - 1) / (2q) f*_i(x)`. The distances come from exact ray hits on the shape primitives (box, cylinder, sphere); voxel masks and densities stay halfway. Links stored sorted by `(cell, q)`, looked up only on edge cells. | `Solver::set_wall_distance`, `geometry::wall_distance` |
| Moving wall | Bounce-back with Ladd's (1994) momentum term `+ 6 w_i rho c_i . u_w`. | `Face::Wall` |
| Velocity inlet | The same moving-wall rule carrying the inlet velocity (Kruger et al. 2017, 5.3.3), uniform or parabolic (`4 s (L - s) / L^2` across each non-periodic transverse axis). The profile is evaluated where each link crosses the inlet (`x - c/2`), not at the cell centre: the difference between the two diagonal links carries the inflow's shear, and dropping it made a 1.5 % centreline overshoot develop over the first 20 cells (and 0.5 % too much cD on the cylinder). Link-wise, so it needs no face-specific Zou-He algebra and works on any face. | `Face::Velocity` |
| Pressure outlet | Anti-bounce-back at density `rho_w`, `f_i(x) = -f*_opp(x) + 2 w_i rho_w (1 + 4.5 (c_i.u)^2 - 1.5 u^2)`, `u` the cell's velocity (Kruger et al. 2017, 5.3.4). Chosen over Zou-He for the same reason as the inlet: one rule for every face and edge. | `Face::Pressure` |
| Outlet sponge | Optional density sponge in front of pressure outlets: `f += s(d) (1 - rho) f_eq(1, u)`, quadratic ramp over `cells`. Relaxes the density, not the velocity. | `Solver::set_sponge` |
| Free slip, periodic | Specular reflection (a population leaves the cell shifted by the tangential part of `c`, mirrored); periodic faces wrap. Edges and corners take the face with the highest priority: wall, inlet, outlet, slip. | `Face::Slip`, `Face::Periodic` |
| Porosity | Per-voxel partial bounce-back `n_s` in [0, 1] (Walsh, Burwinkle and Saar 2009): `f_out = (1 - n_s) f_collided + n_s f_opp(pre-collision)`. In a uniform field under a body force it is exactly a Brinkman drag `F = 2 n_s rho u` per cell and step (test `partial_bounce_back_is_a_brinkman_drag`). A topology optimisation density maps to it through `porosity_from_design(s, q) = q s / (q + 1 - s)` (`s` solid fraction), the convex interpolation of Borrvall and Petersson (2003) as used for LBM topology optimisation by Pingen, Evgrafov and Maute (2007); `s = 1` is a full solid voxel. | `Solver::set_porosity`, `porosity_from_design` |
| Forces, torques | Momentum exchange on every fluid-solid link, `F = -2 f*_opp(x) c_i` per link and step (Ladd 1994; Mei et al. 2002), plus the momentum the partial bounce-back removes on porous cells. Torque about `torque_center` with the link midpoint as lever. | `Pass::pull_edge`, `Solver::force` |
| Convergence | Relative L2 change of the velocity field between two checks, `|u - u_prev| / |u|`. | `Solver::relative_change` |
| Units | `dx`, `dt`, `rho` fix everything; `dt = Ma cs dx / U_ref` from a target Mach number (default 0.1), `tau = 3 nu dt / dx^2 + 1/2`. Conversions for velocity, viscosity, pressure, force, torque, body force, time; round trip tested. | `units.rs` |
| Temperature | Passive scalar on D3Q7 (`w0 = 1/4`, `cs^2 = 1/4`), BGK, `g_eq = w_i T (1 + 4 c_i.u)`, `kappa = (tau_g - 1/2) / 4`, advected by the flow's velocity, one-way coupled (forced convection). Fixed-temperature solids and faces by anti-bounce-back `g_i = -g*_opp + 2 w_i T_w`, adiabatic by bounce-back, outflow by zero gradient, volumetric source `+ w_i S`. Heat into the fluid counted per link. | `thermal.rs` |

## Validation

Tests: `cargo test --release -p viaform-fluid` (14 tests; 2 min 11 s on the loaded machine below, the cavity and cylinder tests take most of it). Table:
`cargo run --release -p viaform-fluid --example validate` (`quick` for a short run; `only=poiseuille,taylor,cavity,cylinder,sphere,determinism,perf`
selects sections, `cyl=20:0.05:i` and `sph=12:20` override the cylinder and sphere lists). The
full list takes hours on a loaded machine, so the numbers below come from section runs of that
example on 2026-11-22, on a machine shared with other builds (see Performance).

| Check | Reference | ViaForm | Error |
|---|---|---|---|
| Couette, H = 16, moving-wall bounce-back | linear profile | max error 3.3e-14 U | exact |
| Poiseuille (body force), BGK, tau 0.8, H = 16 / 32 / 64 | `u = g s (H - s) / (2 nu)` | L2 2.78e-3 / 6.95e-4 / 1.74e-4 | **order 2.000, 2.000** |
| same, regularized | same | L2 1.07e-3 / 2.67e-4 / 6.69e-5 | **order 2.000, 2.000** |
| Taylor-Green 2D decay, 128^2, BGK, tau 0.8 | `nu = (tau - 1/2) / 3` | nu x 0.99986 | -0.014 % |
| same, regularized, tau 0.8 | same | nu x 0.99981 | -0.019 % |
| same, regularized, tau 0.51 | same | nu x 1.00055 | +0.055 % |
| Partial bounce-back, uniform `n_s` 0.05 / 0.2 / 0.5 | `u = F / (2 n_s)`, drag = body force | same | < 1e-9 |
| Lid-driven cavity Re 100, 64^2 (23,000 steps) | Ghia et al. 1982, 15 u + 15 v centreline points | max 0.0078 U, rms 0.0038 U | **0.78 % of U** |
| same, 128^2 (42,000 steps) | same | max 0.0085 U, rms 0.0038 U | 0.85 % of U |
| Lid-driven cavity Re 400, 128^2 (92,000 steps) | same, without the misprinted point (note) | max 0.0053 U | **0.53 % of U** |
| Lid-driven cavity Re 1000, 128^2 (195,000 steps) | same | max 0.0151 U, rms 0.0079 U | 1.51 % of U |
| same, 256^2 (364,000 steps) | same | max 0.0175 U, rms 0.0076 U | 1.75 % of U |
| Schafer-Turek 2D-1 cD, D = 20 cells, peak inflow 0.1, halfway | 5.57 to 5.59 | 5.8758 | +5.1 % |
| same, interpolated bounce-back | 5.57 to 5.59 | 5.8082 | +3.9 % |
| same, interpolated, peak inflow 0.05 | 5.57 to 5.59 | 5.6578 | **+1.2 %** |
| same, cL | 0.0104 to 0.0110 | 0.0110 | in range |
| same, pressure difference front to back | 0.1172 to 0.1176 Pa | 0.1169 Pa | -0.3 % |
| same, interpolated, peak inflow 0.025 (177,500 steps) | cD 5.57 to 5.59 | **5.6234** | **+0.60 %** |
| same, cL | 0.0104 to 0.0110 | 0.0113 | +2.7 % |
| same, pressure difference | 0.1172 to 0.1176 Pa | 0.1163 Pa | -0.8 % |
| D = 10 cells, interpolated, peak inflow 0.02 (the test) | cD 5.57 to 5.59, cL 0.0104 to 0.0110, dp 0.1172 to 0.1176 | 5.7360, 0.0151, 0.1179 | +2.7 %, +37 %, +0.3 % |
| Sphere Re 20, D = 12 cells, interpolated, 12D x 8D x 8D slip box, u 0.05 (40,000 steps, residual not under 1e-6) | Schiller-Naumann cD 2.610 | 2.840 | +8.8 % |
| Conduction between plates (D3Q7) | linear | max error 4.0e-14 | exact |
| Uniform heat source between cold plates, H = 32 | parabola `S s (H - s) / (2 kappa)` | L2 1.0e-3, energy balance to 1e-6 | 0.10 % |
| Advection-diffusion of a sine wave, u 0.05 | `kappa`, phase speed `u` | kappa -0.92 %, speed +0.01 % | see Limits |
| Determinism, 48x32x32 block, LES, outlet, 300 steps | 1 thread vs 18 threads | hash 8ccfe907b6cec090 both | **bitwise equal** |

Notes.

- Poiseuille at fixed `tau` (diffusive scaling) converges at exactly second order: halfway
  bounce-back puts the wall half a cell out with a `tau`-dependent slip of order `dx^2`.
- Cavities are 2D: the x-z plane with one periodic cell in y, so the 3D code solves the 2D
  benchmark exactly. Ghia's data are themselves a 129^2 multigrid solution (about 1 % accurate
  at Re 1000), which is why refining to 256^2 does not lower the Re 1000 error further. At Re 400
  Ghia's `v = -0.23827` at `x = 0.9063` is a known misprint (its neighbours read -0.228 and
  -0.450, and every later study gives about -0.39 there); with it the max error reads 14.96 %.
- Cylinder: 2D the same way. Three effects, each measured: halfway bounce-back on a staircase
  circle (+1.2 % on cD against interpolated bounce-back at D = 20), compressibility (the peak
  inflow of 0.1 lattice, Mach 0.17, adds +2.6 % against 0.05; 0.02 against 0.05 changes cD by
  another 0.5 % at D = 10, and 0.025 against 0.05 another 0.6 % at D = 20, to +0.60 %), and the inlet shear fix in the method table (0.5 %). cL is a small
  difference of two large integrals and is noisy on coarse grids (+37 % at D = 10, in range at
  D = 20). The pressure is read in the first fluid cell in front of and behind the cylinder, half
  a cell off the surface points of the benchmark.
- Sphere: only the coarse case ran (each 3D case took 15 min on the loaded machine; the
  example also lists D = 16 at Re 20 and 100). +8.8 % is mostly set-up, not the solver: 12 cells
  per diameter, the sphere only 4 D from the inlet and 4 D from the slip sides (at Re 20 the
  viscous disturbance reaches far, and confinement raises drag by several percent), the run
  stopped at 40,000 steps before the 1e-6 residual, and Schiller-Naumann is itself a fit with
  about 5 % scatter against the measurements. A fair sphere check needs a 20 D box and D >= 24,
  which is a GPU-sized run (about 30 M cells).

## Performance

`cargo run --release -p viaform-fluid --example validate only=perf` (100 steps at 128^3 after
3 warm-up steps; MLUPS = million cell updates per second). Apple M5 Max, 18 cores, 48 GB.

**These numbers are not a clean baseline.** Every run of 2026-11-22 shared the machine with
another agent's builds and benchmarks at a load average of 60 to 120 on 18 cores, so each
thread got a fraction of a core. They are lower bounds; rerun on a quiet machine and record the
baseline here (spec section 2, performance guard).

| Case | Threads | MLUPS (wall, loaded) |
|---|---|---|
| 128^3 periodic box, regularized | 1 | 5.6 |
| same | 18 | 17.4 |
| 128^3 sphere in a wind tunnel, regularized + LES, slip sides, outlet | 1 | 2.1 |
| same | 18 | 22.9 |

CPU time (unaffected by waiting for a core, still affected by cache and bandwidth contention):
the single-thread runs did 549 M cell updates in 75.3 s of user time, **7.3 MLUPS per core**,
about 137 ns per update. Memory: 2 x 19 f64 per cell plus 4 for the macroscopic field, 336 bytes
per cell, 716 MB resident at 128^3. Expected on a quiet machine: the step is bandwidth-light
(about 340 bytes per update), so it should scale close to linearly to 18 cores; the f32 GPU
port is the route to the 1 to 5 GLUPS class.

## JSON facade

`viaform_fluid::call(op, params) -> Result<Value, EngineError>`; errors carry a stable `code`
(`unknown_op`, `bad_params`, `bad_mask`, `bad_units`, `bad_grid`, `bad_boundary`,
`bad_parameter`, `too_large`, `unstable`, `diverged`) and a `message`.

| Op | Params | Returns |
|---|---|---|
| `version` | none | engine, version, lattices |
| `presets` | none | `air` and `water`: density, kinematic viscosity, thermal diffusivity, heat capacity |
| `units` | `voxel_mm`, `inlet_velocity`, `fluid`, `mach` | `dx_m`, `dt_s`, `u_lattice`, `tau`, `nu_lattice` |
| `run` | below | below |

`run` is a wind tunnel along +x: velocity inlet on the -x face, pressure outlet on +x, the four
other faces `sides`.

| Field | Meaning | Default |
|---|---|---|
| `domain_mm` | Box `[x, y, z]`, corner at the origin | required |
| `voxel_mm` | Voxel edge | required |
| `fluid` | `"air"`, `"water"` or `{density, viscosity, thermal_diffusivity?, heat_capacity?}` (SI) | air |
| `inlet_velocity` | m/s along +x | required |
| `mach` | Lattice Mach number of the inlet velocity (sets `dt`) | 0.1 |
| `obstacles` | Shapes in mm: `{"type": "box", "min", "max"}`, `{"type": "cylinder", "center", "axis", "radius", "length"?}`, `{"type": "sphere", "center", "radius"}`; a voxel is solid when its centre is inside | none |
| `mask` | 0/1 per voxel, index `(z * ny + y) * nx + x`, or-ed with the shapes | none |
| `solid_fraction` | 0..1 per voxel (a topology optimisation density); 1 is solid, below 1 becomes partial bounce-back through `porosity_from_design` with `interpolation_q` | none, q 0.1 |
| `sides` | `"slip"`, `"wall"` or `"periodic"` | slip |
| `collision` | `"regularized"` or `"bgk"` | regularized |
| `smagorinsky` | Constant, `null` for none, or omitted for auto (0.14 when `tau < 0.55`) | auto |
| `steps`, `tolerance`, `check_every` | Step cap; stop when the relative velocity change over `check_every` steps is under `tolerance` | 20000, 1e-4, 100 |
| `ramp_steps` | Inlet ramp from rest (sin^2); an impulsive start sends pressure waves the inlet and outlet reflect for tens of thousands of steps | one flow-through |
| `sponge_cells` | Outlet density sponge length (strength 0.1) | `min(nx / 8, 24)` |
| `average_steps` | Forces averaged over this many final steps | `check_every` |
| `interpolated_walls` | Interpolated bounce-back on the shapes' exact surfaces | true |
| `torque_about_mm` | Torque reference point | solid centroid |
| `reference_length_mm` | Length for the Reynolds number | equivalent diameter of the frontal area |
| `thermal` | `{"inlet_c", "obstacle_c"}`: every obstacle held at `obstacle_c`, inflow at `inlet_c` | none |
| `field_stride` | Return velocity and pressure every `stride` voxels | none |
| `max_cells` | Guard | 20,000,000 |

Returns `grid`, `units` (`dx_m`, `dt_s`, `tau`, `u_lattice`, `smagorinsky`, `collision`),
`steps`, `converged`, `residual`, `time_s`, `reynolds`, `reference_length_mm`, `force_n`,
`drag_n` (x), `side_n` (y), `lift_n` (z), `torque_nm`, `frontal_area_mm2` (projected solid on
the y-z plane), `cd` and `cl` (on that area and `0.5 rho U^2`), `pressure_drop_pa` (mean inlet
plane minus mean outlet plane), `max_velocity_ms`, `solid_voxels`; with `thermal`, `heat_w`
(from the obstacles into the fluid), `max_fluid_c`, `outlet_mean_c`; with `field_stride`,
`fields` (`dims`, `stride`, `spacing_mm`, `velocity_ms` as `[u, v, w]` per sample and
`pressure_pa`, x fastest).

Example (from `tests/facade.rs`): a 4 mm cube held at 40 C in a 40 x 16 x 16 mm air channel at
0.5 m/s, 0.5 mm voxels, 6000 steps: cD 1.55, 0.078 W into the air, outlet mean 20.61 C (the
outlet enthalpy rise, 1.28e-4 m3/s x 1210 J/(m3 K) x 0.61 K, is 0.095 W; a Whitaker-type
correlation gives about 0.09 W).

## Limits and next steps

- Staircase walls: voxel masks and topology optimisation densities have no sub-voxel surface, so
  they use halfway bounce-back (effective shape off by up to half a voxel, drag first order in
  the voxel size). Shape primitives use interpolated bounce-back. A smoothed density could give
  link distances from its 0.5 level set (not done).
- Compressibility: LBM is weakly compressible; errors grow with the Mach number squared. On the
  Schafer-Turek cylinder a peak inflow of 0.1 (lattice) adds about +2.5 % to cD against 0.02.
  The facade's default Mach 0.1 refers to the mean inlet speed; use 0.05 where 1 % matters.
- High Reynolds numbers: the regularized operator with Smagorinsky runs down to `tau - 1/2` of
  1e-3 to 1e-2; propeller tips at full speed need more (cumulant or recursive regularized
  collision, wall models) and far finer voxels than a CPU affords.
- Rotors: no rotating geometry yet. Next: actuator disk and actuator line models (thrust and
  torque as body forces on a disk of voxels), then sliding or immersed-boundary rotors.
- Topology optimisation: the porosity field is ready; the adjoint LBM (Pingen et al. 2007,
  Krause et al. 2013) and the coupling to the generative engine's optimiser are not written.
- GPU: the pass is local and branch-light; port to a wgpu compute shader in f32 (spec E-4, E-11).
- Temperature is one-way (no buoyancy) and D3Q7 BGK has a numerical diffusivity deficit of
  `(tau_g - 1/2) u^2` (0.9 % at u = 0.05 in `advection_diffusion_of_a_wave`); keep `tau_g` well
  above 1/2 (cell Peclet number `u / kappa` under about 10).

## References

- P. L. Bhatnagar, E. P. Gross, M. Krook, A model for collision processes in gases, Phys. Rev. 94 (1954) 511-525.
- Y. H. Qian, D. d'Humieres, P. Lallemand, Lattice BGK models for Navier-Stokes equation, Europhys. Lett. 17 (1992) 479-484.
- J. Latt, B. Chopard, Lattice Boltzmann method with regularized pre-collision distribution functions, Math. Comput. Simul. 72 (2006) 165-168.
- S. Hou, J. Sterling, S. Chen, G. D. Doolen, A lattice Boltzmann subgrid model for high Reynolds number flows, Fields Inst. Commun. 6 (1996) 151-166.
- Z. Guo, C. Zheng, B. Shi, Discrete lattice effects on the forcing term in the lattice Boltzmann method, Phys. Rev. E 65 (2002) 046308.
- A. J. C. Ladd, Numerical simulations of particulate suspensions via a discretized Boltzmann equation, J. Fluid Mech. 271 (1994) 285-339.
- R. Mei, D. Yu, W. Shyy, L.-S. Luo, Force evaluation in the lattice Boltzmann method involving curved geometry, Phys. Rev. E 65 (2002) 041203.
- T. Kruger, H. Kusumaatmaja, A. Kuzmin, O. Shardt, G. Silva, E. M. Viggen, The Lattice Boltzmann Method: Principles and Practice, Springer (2017), sections 5.3 (velocity and pressure boundaries) and 8 (forcing).
- S. D. C. Walsh, H. Burwinkle, M. O. Saar, A new partial-bounceback lattice-Boltzmann method for fluid flow through heterogeneous media, Comput. Geosci. 35 (2009) 1186-1193.
- T. Borrvall, J. Petersson, Topology optimization of fluids in Stokes flow, Int. J. Numer. Meth. Fluids 41 (2003) 77-107.
- G. Pingen, A. Evgrafov, K. Maute, Topology optimization of flow domains using the lattice Boltzmann method, Struct. Multidisc. Optim. 34 (2007) 507-524.
- U. Ghia, K. N. Ghia, C. T. Shin, High-Re solutions for incompressible flow using the Navier-Stokes equations and a multigrid method, J. Comput. Phys. 48 (1982) 387-411.
- M. Schafer, S. Turek, Benchmark computations of laminar flow around a cylinder, in Flow Simulation with High-Performance Computers II, Notes Numer. Fluid Mech. 52 (1996) 547-566.
- L. Schiller, A. Naumann, Uber die grundlegenden Berechnungen bei der Schwerkraftaufbereitung, Z. Ver. Dtsch. Ing. 77 (1933) 318-320.
- M. Bouzidi, M. Firdaouss, P. Lallemand, Momentum transfer of a Boltzmann-lattice fluid with boundaries, Phys. Fluids 13 (2001) 3452-3459.
