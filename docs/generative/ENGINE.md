# ViaForm 3D generative engine

Crate `generative/` (`viaform-generative`), module `solid`. Density-based topology optimisation on
cubic voxels, with a modal and impact time axis, a smooth closed surface out, and a space-frame
alternative (`frame3d`). Units: mm, N, MPa, g/mm³, s.

## Method

| Piece | What it does | Code |
|---|---|---|
| Grid | Box of cubic voxels, each an 8-node trilinear hexahedron (hex8, 2x2x2 Gauss). One 24x24 element matrix serves every voxel, scaled by its modulus. | `solid/grid.rs`, `solid/fem.rs` |
| FEM | Matrix-free `K u`, gathered by node row in parallel (rayon): no two threads write one entry, sums in a fixed order, so results are bit-reproducible on any core count. Fixed DOFs eliminated. | `solid/fem.rs` |
| Solver | Conjugate gradients preconditioned by one geometric multigrid V-cycle (two-to-one coarsening, Galerkin coarse operators, degree-2 Chebyshev smoothing, banded Cholesky on the coarsest grid; after Amir, Aage and Lazarov 2014). | `solid/mg.rs` |
| Interpolation | SIMP `E = E0 (1e-9 + ρ³ (1 - 1e-9))`; mass `ρ`, with Olhoff and Du's `ρ⁶` tail under 0.1 so voids do not ring as local modes. | `solid/optimize.rs` |
| Filter | Linear cone density filter (Bourdin 2001, Bruns and Tortorelli 2001), radius `max(1.5 h, 0.6 min_member)`: the minimum member size. | `Filter` |
| Projection | Smoothed Heaviside about η (Wang, Lazarov and Sigmund 2011), β doubled from 1 up to `max_beta` (16); `max_beta = 0` is plain SIMP (top3d, PETSc TopOpt). | `heaviside` |
| Robust | Eroded / nominal / dilated projections (η = 0.5 ± δ). Compliance: bound formulation, `min z` s.t. `c_k / c0 ≤ z` for the three. Stress and displacement read the eroded design; volume, frequency and the built part are the nominal one. | `Study.robust` |
| Manufacturing | Additive: Langelaar's (2016, 2017) layer-by-layer smooth-max overhang filter along the build direction (45° cross stencil, full 3x3 for flatter limits). Milling: smooth-max along the tool. Extrusion: one variable per line. | `sweep_forward`, `groups` |
| Symmetry | One design variable per orbit of the mirror planes (exact, not penalised). | `groups` |
| Passive regions | `keep_out` (holes, screw clearances, bearing bores) fixed at 0 on every voxel that reaches into it (a corner inside, not only the centre: no material is left inside a bought part's room), `keep_in` (bosses, bearing seat walls as `Tube` at the real bore and OD) fixed at 1, on top of the projection and the sweep. Loads only go to nodes that touch possible material, and a load whose region holds keep-in nodes goes on those only (a load on design voxels beside a pad pushes them through void stiffness: the palm read 12 700 times its stress limit before this). Material keep-outs cut off from every support turns void, keep-in scraps included. | `Model::new`, `Grid::elements_touching` |
| Loads | Several load cases, each with forces, torques (pure couples about an axis: motor stall torques on a bore), pressures and body accelerations (gravity, crash `g`, follows the layout's own mass). | `solid/loads.rs` |
| Stress | p-norm (p = 8) of the relaxed stress `ρ^0.5 σ_vm` (qp-type relaxation against singular optima, Bruggi 2008, Le et al. 2010), rescaled each iteration to the true peak (Le et al.'s adaptive normalisation), aimed at 85 % of the limit, then up to three short rounds that tighten the aim by what the full analysis finds (and by 20 % when the built part no longer reaches a load, which reads as no stress at all). Adjoint per case. Clamped-edge voxels are left out (singular on a voxel grid). | `Evaluator::evaluate` |
| Displacement | p-norm of nodal displacement magnitudes, adjoint. | same |
| Frequency | Subspace iteration (Bathe) with MG-PCG solves and warm starts. Floor as a bound formulation: each of the lowest `frequency_modes` (default 3) has its own constraint `λ_j ≥ λ_min`, so a repeated pair or crossing modes stay above the floor. | `solid/dynamics.rs` |
| Mass target | `mass_target_g` sets the volume fraction from the density, keep-in solid counted. Objective `mass` is least mass under stress, displacement and frequency limits. | `fraction_for_mass` |
| Optimiser | MMA (Svanberg 1987, 2002 subproblem form, primal-dual interior point), parallel per variable in fixed chunks. | `solid/mma.rs` |
| Impact | Newmark average acceleration, Rayleigh damping at the first mode, MG-preconditioned effective stiffness. | `solid/dynamics.rs` |
| As built | A candidate is what gets made: voxels at density 0.5 and up are solid, the rest void; solid bodies (face-joined) no support holds are dropped (`floating_mm3`), and so are held scraps under 1 % of the largest held body (a sliver of seat wall a keep-out cut off, as the surface drops islands under 1 %); each load goes on the built material in its region, and a load with none there is listed in `unsupported` (nothing carries it: the study fails). The static, modal and impact analysis, the mass and the inertia are all of this solid; more than `max_bodies` (1) bodies fails too. The reasons are written in `Candidate.issues`. | `as_built`, `analyse_full`, `feasible` |
| Surface | The surface of the built voxels: the mean-density level at 0.5, except that a voxel the mean would thin away keeps every corner inside (so a one-voxel strut keeps its section and a face-joined bridge stays joined). Taubin smoothing moves no vertex more than 0.25 voxel along its normal or 0.5 in all, then one even offset along the normals (at most 0.3 voxel) puts the enclosed volume back on the voxels' (test `the_surface_keeps_the_solid_volume`: 2.6 % off before the offset). Then exact round holes: every vertex within 1.5 voxels of a cylinder keep-out's wall (and of `bores`) whose normal faces the axis goes to its radius, so bearing seats, pin bores and screw clearances come out at their true diameter (a thin wall's outer face stays put). The rest of the surface then takes one more even offset (at most 0.3 voxel) so the part encloses the analysed volume: index_knuckle 1139.0 mm3 meshed for 1138.7 analysed, seat 8.000 mm, pin bores 3.000 mm. Checked: the surface's bodies against the solid's, and its volume against the solid's within 5 % (`mesh_mm3`). Per-vertex stress; 3MF, STL, OBJ. | `iso::surface_solid`, `iso::cut_holes`, `solid/export.rs` |
| Grid | One cubic edge; a side 8 voxels or fewer through (a plate) sets it, so a 3 or 4 mm sheet keeps its exact thickness; otherwise the longest side does. A grid more than 1 % off the asked box is a warning in `Outcome.warnings`. | `Grid::new` |

Every sensitivity (compliance, robust bounds, stress, displacement, through filter, projection
and the printing and milling sweeps) is checked against central finite differences in the tests.

## Validation

Run `cargo run --release -p viaform-generative --example validate` (about 6 min on the machine
below). Numbers from that run, 2026-11-05.

| Check | Reference | ViaForm | Error |
|---|---|---|---|
| Cantilever tip deflection, 80x10x10 mm steel, 100 N, h = 1 mm (8,000 hex8) | Timoshenko 0.10362 mm | 0.10208 mm | -1.49 % |
| same, h = 0.5 mm (64,000 hex8) | Timoshenko 0.10362 mm | 0.10259 mm | -1.00 % |
| same, h = 0.25 mm (512,000 hex8, 14 PCG its, 0.3 s) | Timoshenko 0.10362 mm | 0.10272 mm | **-0.87 %** |
| First bending frequency, 200x10x10 mm aluminium, h = 1 mm | Euler-Bernoulli 204.16 Hz | 204.99 Hz (twin mode 204.99 Hz) | +0.41 % |
| same, h = 0.5 mm (160,000 hex8) | Euler-Bernoulli 204.16 Hz | 204.49 Hz | **+0.16 %** |
| MMA, Svanberg two-ball problem (mmasub documentation) | x* = (2.0175, 1.7800, 1.2375) | same to 4 digits, 12 its | KKT residual 2.7e-8 |
| MMA, Svanberg 1987 five-segment cantilever | f* = 1.3400 (closed form) | 1.3400, 11 its | 0.0000 % |
| Multigrid PCG to 1e-8, uniform, 8k / 66k / 524k elements | mesh-independent | 11 / 11 / 11 its | constant |
| Multigrid PCG to 1e-8, random 0/1 SIMP field (E_min 1e-9) | mesh-independent | 39 / 36 / 50 its | bounded |
| top3d cantilever 60x20x4, vf 0.3, p 3, rmin 1.5, reference optimality criteria optimiser written from the papers (Bendsoe and Sigmund 2003; Liu and Tovar 2014) on this FEM | TOP3D printout C = 2417.5352, 155 its (Gao et al. 2017, Fig. 13) | 2416.80 (198 its) | **-0.03 %** |
| same, engine MMA, density filter, no projection | reference OC 2416.80 | 2368.90, layout 95.9 % voxel agreement | -1.98 % |
| same, engine default (MMA + Heaviside, β to 16, 100 its) | reference OC 2416.80 (37 % grey) | 1727.78, 0.9 % grey | -28.5 % (crisp 0/1 design; Gao et al.'s crisp CDT design: 1877.09) |
| 3D MBB half beam 60x20x4, vf 0.3, p 3, rmin 1.5 | reference OC 2406.60 | engine MMA 2422.10, 96.4 % agreement | +0.64 % |
| PETSc TopOpt default (Aage et al. 2015): 2:1:1, vf 0.12, p 3, rmin 0.08, density filter, MMA, 400 its, 64x32x32 | topology of the paper | c/F² = 613.4, 17 % grey, 98 s | topology matches |
| same, 128x64x64 (524,288 hex8) | same | c/F² = 995.7, 186 s (0.46 s/it) | see note |

Notes.

- The FEM error at the finest mesh is under 1 %; the remaining -0.8 % (Richardson extrapolation
  gives -0.82 %) is the 3D clamp: beam theory lets the root section warp, the clamped face does
  not.
- The reference OC optimiser (written from the method's description, not from top3d's code) reproduces the published compliance to 0.03 %. It runs to the 200-iteration
  cap where top3d stopped at 155 on its 0.01 change criterion (top3d solves directly, the port
  iteratively to 1e-8, so the last design changes are not identical); the compliance matches.
- Projection lowers the compliance by 28 % because a crisp design no longer pays the SIMP
  penalty on grey voxels. Same volume, same filter, the structure is the same truss family
  (91.8 % voxel agreement).
- PETSc TopOpt loads every node of the edge with -0.001, so the total force grows with the mesh:
  c/F² compares meshes. A line load on the edge of a 3D solid has a logarithmic displacement
  singularity, so compliance is not mesh-converged for this benchmark (it rises with refinement
  in any code); the topology (two flanges joined by the inclined web, side views in the
  validate output) is the same at both meshes and as in Aage et al. Their paper prints no
  compliance value, so no number is compared.

Unit tests (`cargo test --release -p viaform-generative`, 111 library tests pass, 12 of them
thermal, see [Thermal](#thermal-g10)) cover, besides the
above: the element matrix against its closed form, products against a dense assembly, the
uniaxial bar exactly, adjoint gradients against finite differences (free, printing, milling;
robust bounds and the eroded stress), the robust ordering `c_eroded > c_nominal > c_dilated`
at the nominal volume, a square column's repeated bending pair held over a frequency floor
(both members, pair kept within 2 %), the mass target, mirror symmetry exact to 1e-6, a bearing
seat (bore void, seat wall solid) under a radial load case and a 350 N·mm stall-torque case,
the printed part with under 2 % unsupported voxels, the mass objective under its stress limit,
the impact integration, the closed manifold surface and the 3MF/STL/OBJ writers.

## Performance

`cargo run --release -p viaform-generative --example bench`. Each figure is now the least of three
repetitions and the run prints the machine's load average: a rerun at load 22 on 18 threads read
0.26 s per iteration at 100k (small grids suffer most from contention). Apple M5 Max, 18 cores, 48 GB,
rayon on all cores. Cantilever, compliance at vf 0.3, filter 1.5 voxels, projection on. One
optimiser iteration = projection chain, MG setup, warm-started MG-PCG solve, sensitivities,
filter back, MMA step.

| Voxels | Grid | DOFs | `K u` | MG setup | Cold solve to 1e-5 | **Time per iteration** |
|---|---|---|---|---|---|---|
| 102,400 | 80x40x32 | 328,779 | 1.2 ms | 0.02 s | 0.05 s (8 its) | **0.14 s** |
| 393,216 | 128x64x48 | 1,232,595 | 2.4 ms | 0.05 s | 0.13 s (8 its) | **0.28 s** |
| 1,024,000 | 160x80x80 | 3,168,963 | 5.6 ms | 0.09 s | 0.25 s (8 its) | **0.68 s** |

### Mixed precision (2026-11-06)

The multigrid preconditioner now runs in `f32` while the outer CG keeps `f64` (solution,
residual, search direction, dot products). Because the f32 V-cycle is not exactly the inverse
of a fixed symmetric operator, CG uses the flexible Polak-Ribière beta (`β = max(0, -α (q·z) /
(r·z)_old)`). If the mixed solve has not reached the tolerance when it stops, the solve finishes
in full `f64` (built lazily from the same densities), so the answer's accuracy does not depend
on single precision. Other changes:

- Fine-level `K u` in `f32` with a NEON kernel: 4 elements per lane group, `vld3q` deinterleave, 6 accumulators (`fem::apply_kernel_f32`).
- Coarse Galerkin stencils regrouped 4 nodes per slot, applied with NEON `f32` (`stencil_apply_f32`).
- The residual is fused into restriction, and passes run serially below 16k entries (rayon's sync cost dominated on coarse levels).
- Power iteration: 10 steps instead of 15, one fused reduction per step.
- MMA: `p`/`q` coefficients precomputed once per update, the step-length search fused into the dual direction pass, and the pending step applied inside the next pass. Results are bit-identical to the previous MMA, tested for m = 1, 2, 4.

Bench before and after on the same machine, binaries run alternately, load average about 50 on
18 threads (another fix round was building). Least of 3 runs, mean of iterations 2-4, two
alternations each:

| Voxels | Before: iteration | After: iteration | Before: solve | After: solve | Speedup |
|---|---|---|---|---|---|
| 102,400 | 0.51 / 0.50 s | 0.40 / 0.40 s | 0.17 s | 0.14 s | 1.26x |
| 393,216 | 0.75 / 0.75 s | 0.61 / 0.59 s | 0.31 s | 0.26 s | 1.25x |
| 1,024,000 | 1.29 / 1.25 s | **0.95 / 0.95 s** | 0.59 s | 0.41 s | **1.34x** |

On one thread (`RAYON_NUM_THREADS=1`, 100k cantilever, 12 iterations), where load does not
distort the ratio: 1.284 s to 0.717 s per iteration (**1.79x**). The compliance agreed to 3e-8
relative (76.51332738 vs 76.51332494). The validate run after the change matches every table
value above to the printed digits, except the OC reference, which moved from 2416.61 to 2416.77 (since rewritten from the papers: 2416.80)
(+0.007 %; it uses the engine solver to 1e-8). Under load, the multi-threaded gain is held back
by per-pass synchronisation. The 2x target at 1M is reached on one thread but not yet on 18
loaded threads. Next steps: fuse the Chebyshev passes, store the coarse stencil as a symmetric
half, warm-start the power iteration from the previous hierarchy, and Metal.

Work grows linearly with the voxel count (multigrid keeps the iteration count flat), so a
100-iteration study at 1M voxels takes about 70 s. Robust studies cost three solves per
iteration, stress and displacement limits one adjoint solve per case each, a frequency floor
a few subspace rounds (warm-started). The largest grid accepted is 6M voxels.

## Study fields added in this round

| Field | Default | Meaning |
|---|---|---|
| `robust` | none | `{ "delta": 0.15 }`: eroded/nominal/dilated thresholds 0.5 ± delta |
| `frequency_modes` | 3 | lowest modes held over `min_frequency` |
| `mass_target_g` | none | part mass target, g, in place of `volume_fraction` |
| `max_beta` | 16 | final projection sharpness; 0 = no projection |
| `tolerance` | 0 | stop when no variable moves more (compliance studies) |
| `bores` | none | extra exact round holes (cylinders) cut into the surface |
| `exact_keep_outs` | true | cylinder keep-outs are cut exactly into the surface too |
| `max_bodies` | 1 | separate solid bodies allowed before the candidate fails |
| `point_masses` | none | `[{ "region": ..., "mass_g": 11.3 }]`: bought parts' mass on the region's nodes that carry material, in the modes, the frequency floor and the impacts (no stiffness, no body load). Test `a_tip_mass_lowers_the_first_mode` matches the Rayleigh tip-mass cantilever within 3 %; `point_masses_skip_nodes_only_void_touches` keeps it off nodes in a bore |
| `max_impact_displacement` | `max_displacement` | limit on an impact's peak displacement, mm, so the static limit can be a tighter stand-in the optimiser steers by |

## Running from the app

`solid::generate_with(study, report)` runs a study like `generate` and calls `report` with a
`Progress` (variant of variants, iteration of iterations, objective, stage) after every
iteration; answering false stops the run at once with the error `cancelled`. The iteration count
can grow while a stress-limited run adds its short rounds at full sharpness.

`viaform_core::generative::Job` runs a study on its own thread for the front ends: `progress()`
(with a `fraction` over every variant), `cancel()`, `outcome()` and `build(cad, candidate)`,
which inserts the candidate the run already made as one mesh body in one undo step, without
running the study again. The C ABI is `vf_generate_*` in `bridge/include/viaform_generate.h`.

### Live progress

`solid::generate_observed(study, report, Some(observe))` also hands every topology iteration to
`observe` as a `Step`: variant, iteration of iterations, objective, the nominal design's
weighted `compliance` (N mm), `volume` (fraction of the design voxels), `max_stress` (peak
relaxed von Mises `√ρ σ_vm` on the elements at density 0.5 and over, MPa; one extra stress
pass per iteration, only when observed), `change`, `seconds`, the grid and the physical
densities (borrowed). `generate_with` is `generate_observed` with no observer and costs
nothing more.

`Job` keeps, for live front ends:

- `history(from)`: every `LiveStep` from `from` on (`{variant, iteration, iterations,
  objective, compliance, volume, max_stress, seconds}`), for the convergence plot.
- `preview(since)`: the latest densities averaged over blocks of voxels down to at most
  48,000 cells (`decimate`, one pass on the solving thread), surfaced (iso 0.5, one smoothing
  pass) on the caller's thread when newer than `since`; `(version, variant, iteration, mesh)`.
- `set_paused(bool)`: the run holds after its current iteration until resumed or cancelled.
- `progress()` adds `paused`, `eta` (mean seconds of the last five iterations times the
  iterations left over every variant, pauses excluded; null before two iterations),
  `per_iteration`, `paused_seconds` and `preview` (the latest preview version).
- `summary()`: the outcome without densities or surfaces (each candidate's figures, its
  `triangles`, `cost` and `f1`), and `with_mesh(candidate, f)` for one surface. The app opens
  results through these (flat arrays across the C ABI, no JSON for meshes): the selftest
  times the opening at under 1 s.

C ABI (`bridge/include/viaform_generate.h`): `vf_generate_pause`, `vf_generate_history`,
`vf_generate_preview` / `vf_generate_mesh` (a `VfGenMesh` of flat arrays, freed with
`vf_generate_mesh_free`), `vf_generate_summary`, `vf_generate_variant`. The app polls progress
and history every 0.25 s and fetches a preview off the main actor whenever its version moved,
one at a time.

### Variants

`viaform_core::generative::variant_study(base, variant)` lays a variant over a study JSON
(`vf_generate_variant` in the C ABI); each variant then runs as its own `Job`, all at once
(they share rayon's pool). Variant keys, besides any study field:

| Key | Meaning |
|---|---|
| `label` | A name for the comparison; not sent to the engine. |
| `volume_fraction`, `material` | Study fields, replaced. |
| `process` | `fdm`: `additive` along `build` with 45° overhangs; `sls`: `free`; `cnc3`: `milling` along `build`; `as_is` (default): unchanged. |
| `build` | Build or tool direction, default the base study's, else +z. |

A variant runs one candidate (`variants: 1`) and at least one mode (`dynamics.modes >= 1`) so
`f1` compares. `cost_index(study, candidate)` is a rough dollar index for ranking, not a quote:
material bought ($/kg by name: PLA/PETG 25, PA12 80, Ti 300, steel 6, aluminium 8, carbon 60,
else 30) plus machine time: FDM 0.15 $/cm³ printed + 2, SLS 1.3 x powder + 0.45 $/cm³ + 8, CNC
the stock block (surface bounds + 2 mm) + 0.35 $/cm³ removed + 25, extrusion 0.10 $/cm³
removed + 10. The app's Variants pane crosses volume fractions, materials and routes, compares
mass, safety factor, max displacement, f1 and cost, and pushes the picked one to the results,
from where Build inserts it into the design.

The Mac app opens a project with `--sample hand` or `--sample drone` (docs/generative/<name>:
its studies and its assembly.json). Launch flags for scripted runs and screenshots:
`--generate`, `--generate-study=<name>`, `--generate-run`, `--generate-insert` (build the best
candidate once the run ends), `--generate-assembly` (insert assembly.json), `--generate-fist`,
`--generate-pane=project|study|regions|results|variants`, `--generate-display=setup|result|assembly`,
`--generate-explore` (run the default variants at once, then push the lightest feasible to the
results).

## Thermal (G10)

Module `solid/thermal.rs` (tests in `solid/thermal/tests.rs`), example
`cargo run --release -p viaform-generative --example thermal [-- --quick]`. Steady heat
conduction on the same voxels as the elastic model, thermal topology optimisation on the same
design chain, and thermal stress into the elastic solve. A study carries it as `thermal` and runs
it with `solid::thermal::generate` (not yet through `solid::generate` and the candidate
pipeline). Units inside: mm, W, K (temperatures in °C, the problem is linear), conductivity
W/(mm K), film coefficient W/(mm² K); the study gives W/(m K) and W/(m² K), converted at the
boundary (`conductivity_mm`, `film_mm`, tested against Fourier and Newton below).

### Method

| Piece | What it does | Code |
|---|---|---|
| Element | Hex8, one temperature per node; one 8x8 conduction matrix for k = 1 (2x2x2 Gauss, closed form `h Σ s Π m`: 1/3 on the diagonal, 0 along an edge, -1/12 across a face or the body) scaled by each voxel's conductivity. | `element_conduction` |
| Product | Matrix-free `K T`, gathered by node row in parallel (rayon), fixed summation order: bit-reproducible on any core count. Convection faces gathered per node in the same pass. | `Conduction::apply_raw` |
| Fixed temperatures | Nodes in a region held at a temperature (a cold plate, a sink base): lifted out, the solver works on the free nodes. | `FixedTemperature`, `Problem::temperature` |
| Convection | Robin `q = h (T - T_amb)` on the design box's faces whose centres lie in a region (all faces when none): consistent face matrix `h a²/36 (1+δ)(1+δ)`, load `h T_amb a²/4` per corner. Design independent (a cold plate or a ducted base); design-dependent convection on the layout's own surface (fins) is not built. | `Convection`, `Problem::new` |
| Sources | Power (W) spread over the elements whose centre lies in the region, an eighth of each share per corner (consistent load of a uniform source). | `HeatSource` |
| Solver | PCG with one geometric multigrid V-cycle: two-to-one coarsening on every axis of two cells or more, trilinear prolongation, Galerkin coarse operators `Pᵀ A P` on 27-point stencils (the finest one assembled from elements and faces, fixed rows and columns zero), Chebyshev smoothing of degree 3 on `D⁻¹A` up to its Gershgorin bound (rigorous, so the V-cycle stays SPD), banded Cholesky once the level holds 1,500 nodes or fewer. f64 throughout. | `Multigrid` |
| Interpolation | SIMP conductivity `k = k0 (kmin + ρ^p (1 - kmin))`, kmin 1e-3, p 3 (as top3d's heat example). | `Problem::interpolate` |
| Design chain | The elastic studies' own: symmetry groups, density filter, Heaviside projection (β doubled to `max_beta`), keep-in and keep-out, printing and milling sweeps, MMA. | `Model::for_design` |
| Compliance objective | Least `c = qᵀ(T - T_ref)` (heat-weighted mean temperature rise times power) for the volume fraction. Adjoint `dc/dρ_e = -λ_eᵀ dk_e K₁ T_e`, `K λ = q`; λ is the rise itself when every boundary temperature is the reference one (no extra solve). | `Evaluator::evaluate` |
| Temperature limit | p-norm (p 16) of the nodal rise over the free nodes, rescaled every iteration to the true peak, aimed at 98 % of the budget; adjoint solve. After the run, the part as built (densities at 0.5 and over solid) is analysed; while it reads over the limit, up to three short rounds at full sharpness aim lower by the overshoot (grey voxels conduct in the run, not in the part). | same, `optimize_with` |
| Mass objective | Least volume under the temperature limit. | `ThermalObjective::Mass` |
| Thermal stress | Element forces `E α G θ_e`, `G = ∫ Bᵀ D m Nᵀ dV` (`fem::thermal_coupling`), gathered per node, solved by the elastic MG-PCG with the study's supports; stress `σ = E (B u - α θ D m)`. `thermal.stress` reports the built part's peak von Mises. | `thermal_load`, `thermal_stress` |
| Materials | Conductivity, expansion and specific heat per material name (`Material::thermal`, `THERMAL_TABLE` in `spec.rs`, sources cited there): aluminium 6061 167 W/(m K), AlSi10Mg 130, copper 390, steel 50, Ti6Al4V 6.7, PA12 0.25, PETG 0.20, PLA 0.13, carbon fibre composite 4.0 in plane (through the thickness about 0.6; the voxel model is isotropic). A study can override conductivity and expansion. | `spec.rs` |

### Validation

Numbers from the example run of 2026-11-22 (Apple M5 Max, other builds running).

| Check | Reference | ViaForm | Error |
|---|---|---|---|
| Element matrix, h = 1, 0.37, 2.5 | closed form `h Σ s Π m` | every entry | under 1e-14 |
| Slab 10 mm between 100 C and 20 C | linear | every node | under 1e-8 C |
| Slab, uniform heat 0.01 W/mm3, k 50 W/(m K), 20 mm, ends 20 C: peak | qL²/8k + 20 = 30.000000 C | 30.000000 C | -5.4e-14 |
| Fin 40 x 2 x 2 mm Al, h 1000 W/(m2 K), base 85 C, insulated tip, h = 1 mm | cosh profile (tip 26.5067 C) | tip 26.5069 C | max 0.097 % of ΔT_base |
| same, h = 0.5 mm | same | tip 26.5109 C | max 0.061 % |
| same, h = 0.25 mm (10,240 hex8) | same | tip 26.5123 C | **max 0.031 %** |
| Fourier: 10 mm Al cube, 10 K across, k given in W/(m K) | kAΔT/L = 16.7 W | 16.700000000 W | 3.7e-14 |
| Newton: 1 W into a near-isothermal cube, 100 mm² base at 100 W/(m² K) | ΔT = P/(hA) = 100 K | 100.000 K | under 1e-3 K |
| Thermal MG-PCG to 1e-10, uniform, 16³ / 32³ / 64³ / 128³ | mesh-independent | 6 / 6 / 6 / 6 its (0.95 s at 2.1M voxels) | constant |
| same, random 0/1 field (kmin 1e-3) | mesh-independent | 41 / 97 / 26 / 12 its | bounded |
| Clamped steel bar heated 100 K | σ = -E α ΔT = -245.7 MPa | von Mises 245.7000 MPa, σxx -245.7 | 1.3e-14 |
| Free expansion, rollers on three planes | u = α ΔT x, σ = 0 | every node, stress under 1e-6 MPa | under 1e-9 mm |
| Adjoint gradients: compliance and temperature p-norm, β 2, keep-in, mirror, with and without a hotter ambient | central differences | 4 variables x 2 functions x 2 cases | under 1e-5 of the largest |
| Volume to point 100x100x1, vf 0.3, p 3, kmin 1e-3, filter 1.5 voxels, MMA, 150 its | tree of conductors from the sink (Gersborg-Hansen et al. 2006; the top3d heat example) | c 3.26e6 to 2.01e5 W K, no rise after iteration 5, 4 branches cross y = 0.75 L | topology matches |
| same, 3D plate 40x40x10, 100 its | same family | c 8.17e5 to 5.63e4 W K, no rise after iteration 5 | topology matches |
| **G10 heat sink**: 40x40x10 mm Al, 5 W on a 10x10 mm pad, base h 150 W/(m² K) to 25 C, limit 60 C, voxel 1 mm | plain block 43.2 g, 47.15 C (base film alone 45.83 C) | **5.5 g, 54.10 C** (as built) | 87 % lighter, under the limit |
| same, voxel 0.5 mm (128,000 voxels, 90 s) | plain block 43.2 g, 47.14 C | **3.4 g, 57.94 C** | 92 % lighter, under the limit |

Notes.

- The fin error is measured on the cross-section mean against one-dimensional fin theory; it
  falls with the mesh (0.097, 0.061, 0.031 %). The tip moves slightly away from the 1D value as
  the mesh refines because the 3D section is not isothermal (Biot number 0.006): the 1D theory,
  not the FEM, sets that floor.
- The random 0/1 field sits near the percolation threshold (solid clusters joined only through
  kmin), the hardest case for any multigrid; the count does not grow with the grid.
- No published compliance number with exact settings was found for the volume-to-point
  problem: the top3d paper (Liu and Tovar 2014) and Gersborg-Hansen, Bendsøe and Sigmund (2006)
  show the layouts, not the values we could reproduce. The check is the topology (a tree of
  conductors branching from the sink, side views in the example's ASCII output) and a steadily
  falling compliance.
- The heat sink's convection is design independent (the base face cools whatever lies on it),
  so the optimiser grows a thin base plate fed by a pillar under the pad. Fins that shed heat
  from their own sides need design-dependent convection, which is the next step.

### Study fields

`Study.thermal` (default none), a `Thermal`:

| Field | Default | Meaning |
|---|---|---|
| `objective` | `compliance` | `compliance` (least heat-weighted mean temperature for `volume_fraction`) or `mass` (least volume under `max_temperature`) |
| `conductivity` | the material's | W/(m K) |
| `expansion` | the material's | 1/K, for the thermal stress |
| `ambient` | 25 | °C |
| `sources` | none | `[{ "region": ..., "power": 5.0 }]`, W |
| `convection` | none | `[{ "region": ..., "h": 150, "ambient": 25 }]`: film W/(m² K) on the box faces whose centres lie in the region (all when no region); ambient defaults to the study's |
| `fixed` | none | `[{ "region": ..., "temperature": 25 }]`, °C |
| `max_temperature` | none | °C anywhere: the mass objective's limit, a constraint on the compliance objective |
| `penal` | 3 | SIMP exponent of the conductivity |
| `kmin` | 1e-3 | void conductivity over the solid's |
| `stress` | false | analyse the built part's thermal stress (needs `supports`) |
| `stress_free` | `ambient` | stress-free temperature, °C |

The other study fields (`min`, `max`, `voxel`, `material`, `keep_in`, `keep_out`, `symmetry`,
`min_member`, `manufacturing`, `max_beta`, `iterations`, `volume_fraction`, `smoothing`) mean
what they mean for the elastic studies. The result is a `ThermalOutcome`: densities, history,
the built part's `ThermalAnalysis` (peak and source temperatures, compliance, power, mass,
thermal stress) and the plain block's, nodal temperatures, feasibility and the surface mesh.

Left: design-dependent convection (fins), running thermal studies through `solid::generate`
and the app's candidate pipeline, a combined thermo-mechanical objective (weighted compliance
sum) and thermal stress inside the optimisation (the coupling is analysis only today), mixed
precision in the thermal V-cycle.

## References

- K. Liu, A. Tovar, An efficient 3D topology optimization code written in Matlab, Struct.
  Multidisc. Optim. 50 (2014) 1175-1196 (top3d).
- N. Aage, E. Andreassen, B. S. Lazarov, Topology optimization using PETSc: an easy-to-use,
  fully parallel, open source topology optimization framework, Struct. Multidisc. Optim. 51
  (2015) 565-572; defaults from github.com/topopt/TopOpt_in_PETSc (TopOpt.cc, LinearElasticity.cc).
- D. Y. Gao et al., On topology optimization and canonical duality method, arXiv 1712.02919
  (2017): TOP3D printout for the 60x20x4 cantilever (Fig. 13).
- K. Svanberg, The method of moving asymptotes, IJNME 24 (1987) 359-373; MMA and GCMMA notes
  (2007) for the subproblem and the toy problem.
- F. Wang, B. S. Lazarov, O. Sigmund, On projection methods, convergence and robust
  formulations in topology optimization, Struct. Multidisc. Optim. 43 (2011) 767-784.
- M. Langelaar, An additive manufacturing filter for topology optimization of print-ready
  designs, Struct. Multidisc. Optim. 55 (2017) 871-883; 3D version, Addit. Manuf. 12 (2016).
- C. Le, J. Norato, T. Bruns, C. Ha, D. Tortorelli, Stress-based topology optimization for
  continua, Struct. Multidisc. Optim. 41 (2010) 605-620.
- M. Bruggi, On an alternative approach to stress constraints relaxation in topology
  optimization, Struct. Multidisc. Optim. 36 (2008) 125-141.
- N. Olhoff, J. Du, Topological design of continuum structures subjected to forced vibration
  and eigenfrequency problems, Struct. Multidisc. Optim. 34 (2007) 91-110 (bound formulation,
  repeated eigenvalues, ρ⁶ mass tail).
- K. J. Bathe, Finite Element Procedures (subspace iteration, Newmark).
- A. Gersborg-Hansen, M. P. Bendsøe, O. Sigmund, Topology optimization of heat conduction
  problems using the finite volume method, Struct. Multidisc. Optim. 31 (2006) 251-259.
- A. Bejan, Constructal-theory network of conducting paths for cooling a heat generating
  volume, Int. J. Heat Mass Transfer 40 (1997) 799-816.
- O. Amir, N. Aage, B. S. Lazarov, On multigrid-CG for efficient topology optimization, Struct.
  Multidisc. Optim. 49 (2014) 815-829.
