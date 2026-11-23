# Physics simulation for ViaForm: state of the art and build plan

Version 1.0, 2026-11-22. Status: research note, input to `docs/specs/RUST-ENGINES.md`.

Scope: the physics a hardware builder needs for drones, robot arms, robotic hands and small electronics
enclosures (fluids, heat, product thermodynamics, coupling, neural surrogates, rigid and contact dynamics,
numerics), what the field does as of late 2026, and what ViaForm should build in Rust (CPU with rayon,
GPU with wgpu/WGSL, ML with burn; no C or C++ linking, no Python in the product).

How the references were checked: every journal and conference entry below was resolved by DOI against
Crossref, by arXiv id against the arXiv API, or by the publisher or proceedings page, on 2026-11-22.
Software entries point at the project itself. Performance figures quoted from vendors are marked as such.
Numbers marked "estimate" are back-of-envelope figures computed for this note, not published results.

## Summary

Effort: S is up to 3 engineer-weeks, M is 3 to 8, L is 8 to 16, XL is more. Priority: P0 next, P1 after
P0, P2 opportunistic, P3 research only.

| Domain | Best method for ViaForm | Why | Effort | Priority |
|---|---|---|---|---|
| Heat conduction (parts, enclosures, heat sinks, PCBs) | Scalar hex8 FEM on the existing voxel grid, same geometric multigrid; convection and radiation as surface Robin terms from correlations; anisotropic voxels for PCBs; Joule heating via a second scalar solve | Reuses 80 percent of the structural code; validates against closed forms; unlocks G10 thermal topology optimisation and heat sink design | S | P0 |
| Product thermodynamics (battery, motor, ESC) | Lumped thermal networks plus equivalent circuit battery model with Bernardi heat, inside `phys::power`; SPMe as an optional higher fidelity cell model | Cheap (ODEs), validated, answers the questions builders ask (flight time, hot spots, derating); full P2D not needed | S | P0 |
| Thermo-elastic coupling | One-way: thermal strain as a load case in the existing FEM | Trivial on top of conduction, needed for motor mounts and enclosures | S | P0 |
| Rotor aerodynamics | Blade element momentum with tip loss, fed by airfoil polars and validated on the UIUC propeller database; actuator line inside the CFD later | Drone thrust and torque from geometry instead of fitted curves; actuator line is how LBM codes model rotors at affordable cost | S | P1 |
| Rigid and contact dynamics (`phys`) | Featherstone ABA plus convex compliant contact (MuJoCo style or Drake SAP primal form) solved by Newton or CG, PGS kept as fallback | Convex soft contact is the robotics standard for stable grasps at 1 kHz; it fits f64 and determinism | M to L | P1 (already planned) |
| CFD (external aero, enclosure airflow, forced and natural convection) | GPU lattice Boltzmann on wgpu: D3Q19/D3Q27, cumulant or recursive regularized collision, Smagorinsky LES, Bouzidi walls, FP32 compute with FP16 storage, in-place streaming; thermal LBM for convection | Voxel native (no meshing), local and bandwidth bound, works in f32, best speed per line of code; matches the generative grid | L | P1 |
| Fluid topology optimisation and conjugate heat transfer design | Brinkman penalization on voxels; start with Stokes/Darcy-Brinkman FEM on the multigrid, adjoint LBM later | Proven path for heat sinks and ducts; adjoint LBM memory cost is high | M then L | P2 |
| Radiation | Linearised surface radiation to ambient first; view factors by GPU ray casting for enclosures later | Small electronics lose a comparable share of heat by radiation and natural convection | S then M | P1 / P2 |
| Differentiable simulation | Hand-written discrete adjoints (as generative already does); burn autodiff only for learned parts; no general AD of the solvers | Rust has no production AD for whole solvers (std::autodiff is nightly and experimental); contact gradients are of doubtful use for RL | ongoing | P2 |
| Neural surrogates | Geometry-to-field transformer surrogates (Transolver or AB-UPT style) trained on ViaForm's own solver runs, for variant screening only, with the solver always in the loop for the final answer | Surrogates win on repeated queries in a narrow family; they lose on accuracy, generalisation and against good solvers | M | P3 |
| Numerics and GPU | Matrix-free GMG-PCG on wgpu in f32 with f64 iterative refinement on the CPU; gather, not atomics, for determinism; faer for sparse direct and coarse solves | f64 is absent on Apple GPUs; mixed precision is the textbook remedy; the CPU code already proved the scheme | M | P0 / P1 |

## 0. Starting point

What ViaForm already has (from `docs/specs/RUST-ENGINES.md` sections 0 to 2 and
`docs/generative/ENGINE.md`):

- **Structural FEM on voxels:** hex8 trilinear elements on a cubic grid, one 24x24 element matrix scaled
  per voxel, matrix-free `K u` gathered by node row (bit-reproducible), f64 CPU with rayon and NEON f32
  kernels.
- **Solver:** CG preconditioned by a geometric multigrid V-cycle (Galerkin coarse operators, Chebyshev
  smoothing, banded Cholesky on the coarsest grid), f32 V-cycle inside an f64 flexible CG, f64 fallback.
  11 iterations to 1e-8 regardless of size on uniform grids; 1M voxels at about 0.95 s per optimiser
  iteration on an M5 Max.
- **Optimisation:** SIMP, density filter, Heaviside projection, robust formulation, overhang and milling
  filters, stress p-norm and displacement adjoints, MMA.
- **Dynamics:** subspace iteration for modes with a frequency floor, Newmark average acceleration for
  impacts.
- **Drone simulation (`sim/`):** 6-DOF rigid quadcopter with first-order motor spin-up, thrust and drag
  torque from rotor speed, rotor drag and blade flapping (after Mahony, Kumar and Corke [1]),
  inflow and vortex ring state, ground effect, wind with turbulence and gusts.
- **Planned:** `phys` (Featherstone ABA, RNEA, CRBA, soft compliant contact solved by projected
  Gauss-Seidel, f64, fixed order), `gpu` (wgpu, f32), G10 thermal loads (scalar conduction FEM on the
  same grid), `learn` (burn).
- **Constraints:** f64 on CPU, f32 on GPU (E-11), MIT OR Apache-2.0 for ViaForm's own engines (E-20),
  no crate that links C or C++ (section 1), determinism per platform.

These constraints decide most verdicts below: the voxel grid and the multigrid are ViaForm's strongest
assets, Apple GPUs have no f64, and every reference code in this field that is worth copying is
written in C++, CUDA, OpenCL, JAX or Python, so ViaForm reimplements from papers and validates against
published numbers, never links.

## 1. Computational fluid dynamics

### 1.1 Leading methods

**Lattice Boltzmann (LBM).** Solves a discrete-velocity Boltzmann equation on a Cartesian lattice
(D3Q19 or D3Q27 in 3D); the weakly compressible Navier-Stokes equations emerge at low Mach number.
Each step is a local collision plus a shift of populations to neighbours, so the method is memory
bandwidth bound and maps cleanly to GPUs. The field is defined by the collision operator:

- BGK, single relaxation time [2]: simplest, unstable at low viscosity (high Reynolds number).
- MRT, multiple relaxation times [3]: relaxes moments separately, more stable, tunable bulk viscosity.
- Regularized [4]: filters non-hydrodynamic content of the non-equilibrium part before
  collision; cheap stability gain, widely used in Palabos and OpenLB.
- Cumulant [5]: relaxes statistically independent cumulants, the most robust option for under
  resolved LES at high Reynolds number, and parametrised for fourth order diffusion in later work by the
  same group.

The standard textbook is Krüger et al. [6]. Turbulence: LBM codes almost always run LES, with
the Smagorinsky eddy viscosity [7] folded into the local relaxation time (no extra cost), or
implicit LES through the cumulant operator. Walls: half-way bounce-back is first order on curved walls;
interpolated bounce-back (Bouzidi, Firdaouss and Lallemand [8]) is second order and uses the
exact wall distance per link, which a voxel solver can compute from the CAD body. At engineering Reynolds
numbers the near-wall layer cannot be resolved on a uniform lattice, so wall models are needed;
Malaspinas and Sagaut [9] reconstruct the first off-wall node from a wall function inside a
regularized scheme, which is the reference for wall-modelled LES in LBM.

Precision and memory: Lehmann et al. [10] showed that FP32 is as accurate as FP64 for LBM
in almost all cases, and that storing populations in a custom 16-bit format while computing in FP32 is
sufficient in many cases and nearly doubles throughput. The "esoteric pull" in-place streaming
[11] halves memory by storing one population set instead of two. FluidX3D
[12] combines these and reaches about 55 bytes per cell for D3Q19 with FP16 storage (project
README figures).

Thermal flows: a second distribution for temperature (double distribution, He, Chen and Doolen
[13]) or a passive scalar D3Q7 lattice gives forced and natural convection and conjugate heat
transfer with the solid treated as a zero-velocity region of different diffusivity.

Optimisation: LBM has been used for density-based fluid topology optimisation since Pingen, Evgrafov
and Maute [14]; Dugast et al. [15] extended adjoint LBM to thermal fluid flows. The
cost is the adjoint's memory: the forward history (or checkpoints) must be stored for transient runs.

**Finite volume (OpenFOAM class).** The industrial default for incompressible RANS and LES on
unstructured meshes. Pressure-velocity coupling by SIMPLE [16] for steady and PISO [17]
(or PIMPLE, their combination) for transient flows; OpenFOAM [18] is the reference open code.
Turbulence by RANS models such as k-omega SST [19]. Strengths: conservation, robust RANS for
steady drag and pressure drop, body-fitted boundary layers. Weaknesses for ViaForm: a body-fitted mesh
generator (the hardest part of any CFD product), implicit pressure solves with poorly conditioned
algebraic multigrid on unstructured meshes, and f64 expectations throughout.

**Immersed boundary and Brinkman penalization.** Keep a Cartesian grid and represent solids through
forcing terms (Peskin [20]; review by Mittal and Iaccarino [21]) or by a porous drag
term `-u / K` that becomes large inside solids (Brinkman penalization, convergence shown by Angot,
Bruneau and Fabrie [22]). Penalization on voxels is exactly what density-based fluid topology
optimisation uses (Borrvall and Petersson [23]; review by Alexandersen and Andreasen
[24]).

**High order (spectral element, discontinuous Galerkin, flux reconstruction).** Best accuracy per degree
of freedom for smooth and transitional flows; GPU codes such as NekRS [25] (spectral element,
up to 60 billion grid points on Summit) and PyFR (flux reconstruction, BSD-3-Clause). They need curved
high-order meshes and expert setup; not a fit for push-button design studies.

**Rotor and propeller modelling.**

- Momentum theory and blade element momentum (BEM): blade sections with airfoil lift and drag polars,
  inflow from momentum balance, Prandtl tip loss (textbook: Leishman [26]). Milliseconds per
  operating point; accuracy within roughly 5 to 15 percent of measured thrust and power for small
  propellers when good low Reynolds number polars are available.
- Hybrid BEM plus learned residual: NeuroBEM [27] combined BEM with a network trained on
  motion capture flight data at up to 65 km/h and halved prediction error on a racing quadrotor.
- Actuator disk and actuator line [28]: rotor forces from BEM-style sectional data are
  smeared into the flow solver as body forces on a disk or along rotating lines, so the wake is resolved
  without blade-resolved meshes. Asmuth et al. [29] coupled the actuator line to a cumulant LBM
  on a single GPU and validated it against a finite volume solver, at near real-time speed for a wind
  turbine wake.
- Blade-resolved CFD: overset grids with high-order finite differences, as in NASA's quadcopter studies
  [30], for rotor-rotor and rotor-body interaction. Hours to days per case.

**Drone aerodynamics in practice.** Flight simulators use first-order effects: thrust and torque
quadratic in rotor speed, rotor drag proportional to edgewise speed and blade flapping [1], inflow
changes, ground effect. ViaForm's `sim` already has these. What design studies add: propeller selection
from geometry (BEM), arm and body drag and download in the rotor wash (CFD with actuator disks), and
cooling airflow through the body (CFD with heat).

### 1.2 Reference codes

| Code | Method | Hardware | Licence | Note for ViaForm |
|---|---|---|---|---|
| FluidX3D [12] | LBM, D3Q19/D3Q27, SRT/TRT, FP16 storage, esoteric pull | OpenCL GPUs | Free for non-commercial use only (custom licence) | Read the papers, do not copy code |
| waLBerla [31] | LBM framework, code generation (lbmpy), multiphysics | CPU, CUDA | GPLv3 | Good design ideas (block structure, generated kernels) |
| Palabos [32] | LBM, many collision models | CPU (MPI), GPU branch | AGPLv3 | Reference for regularized collisions |
| OpenLB [33] | LBM, thermal, particles, optimisation | CPU, CUDA | GPLv2 | Reference for wall models and thermal LBM |
| XLB [34] | Differentiable LBM in JAX and Warp | GPU | Apache-2.0 | Permissive; useful to cross-check results |
| OpenFOAM [18] | FV, SIMPLE/PISO, RANS/LES | CPU | GPLv3 | Reference results, not a model for ViaForm |
| NekRS [25] | Spectral element | GPU | BSD-3-Clause | Reference DNS/LES results |

None of these can be linked (C++, CUDA, OpenCL or Python). Licences matter only for copying code: GPL
code must not be ported line by line into the MIT OR Apache-2.0 engines; methods from papers are free.

### 1.3 Accuracy, speed, GPU suitability

- LBM throughput is set by memory bandwidth. Estimate for an Apple M-series Max GPU (roughly 400 to
  550 GB/s): D3Q19 with FP32 storage and in-place streaming moves about 153 bytes per cell update, so
  about 2.5 to 3.5 billion lattice updates per second at 80 percent of peak bandwidth; FP16 storage
  roughly doubles that. A 256x128x128 domain (4.2M cells) at 3 GLUPS runs about 700 steps per second.
  These are estimates for this note, not measurements.
- LBM time step is tied to the grid (acoustic scaling), so steady problems take many steps; a steady
  drag run typically needs tens of thousands of steps. Local grid refinement is possible (block
  refinement) but adds complexity; start uniform plus sparse blocks.
- LBM is weakly compressible: the lattice Mach number must stay below about 0.1 to 0.2. Propeller tip
  speeds of small drones (tip Mach 0.3 to 0.5) cannot be resolved blade by blade cheaply, which is why
  rotors enter as actuator lines or disks.
- FV RANS gives better steady drag per CPU hour on body-fitted meshes but needs the mesh and f64
  implicit solves. On Apple GPUs (no f64) an FV solver would run its pressure solve in mixed precision
  at best.
- Brinkman penalization on voxels is first order at walls unless the penalization parameter and grid
  are refined together; it is adequate for design (topology optimisation) and for qualitative flow, and
  needs a verification pass on the final design with a sharper wall treatment.

### 1.4 Verdict for ViaForm

Build a GPU lattice Boltzmann solver (`viaform-cfd`) on wgpu, sharing the voxel geometry of the
generative grid, with:

1. D3Q19 for most runs and D3Q27 for high Reynolds LES; recursive regularized or cumulant collision (start
   with regularized plus Smagorinsky, add cumulant when the validation suite is green).
2. Esoteric pull in-place streaming, FP32 arithmetic, optional FP16 storage per Lehmann et al.
3. Bouzidi interpolated bounce-back with link distances from the CAD body; Malaspinas-Sagaut style wall
   function for Reynolds numbers above about 10^4 based on body size.
4. Inlets, outlets (non-reflecting by sponge layer), symmetry, moving walls; force by momentum exchange.
5. Actuator disk first, actuator line second, both driven by the BEM model from section 1 (shared code
   with `phys::aero`).
6. Thermal D3Q7 passive scalar with Boussinesq buoyancy for forced and natural convection and conjugate
   heat transfer.

Skip finite volume RANS and high-order methods. Keep BEM as the default rotor model for flight
simulation; CFD is for design questions (body drag, rotor-arm download, cooling airflow), not for the
flight loop.

## 2. Heat transfer

### 2.1 Leading methods

- **Conduction FEM on voxels.** The steady equation `-div(k grad T) = q` with Dirichlet, flux and Robin
  (convection `h (T - T_inf)`) conditions; hex8 scalar elements give an 8x8 element matrix, the
  multigrid and PCG carry over unchanged. Density-based thermal topology optimisation is classic
  (book by Bendsøe and Sigmund [35]).
- **Convection.** Three levels. (a) Correlations for the heat transfer coefficient: Churchill and Chu
  [36] for natural convection on vertical plates, flat plate and cylinder correlations for
  forced flow (Incropera et al. [37]). Typical values in still air are 3 to 10 W/m2K; forced
  air from a fan or propeller wash is 20 to 100 W/m2K. (b) Conjugate heat transfer: solve the flow and
  the energy equation in fluid and solid together (thermal LBM, section 1). (c) Topology optimisation
  with full natural convection: Alexandersen, Sigmund and Aage [38] optimised 3D heat
  sinks at large scale; Lazarov et al. [39] built them additively and measured them,
  confirming the predicted gains over pin-fin and lattice designs.
- **Radiation.** Surface to surface exchange by view factors (hemicube or ray casting); P1 or discrete
  ordinates for participating media (Modest [40]), which do not matter for air-filled
  electronics. For a single part to a large enclosure, the linearised coefficient `h_r = 4 eps sigma T^3`
  is about 5.5 W/m2K at 300 K for emissivity 0.9 (computed for this note), the same order as natural
  convection, so it must not be dropped.
- **Electronics cooling and PCBs.** Boards are layered: FR4 (about 0.3 W/mK) and copper (about 385 W/mK).
  The usual homogenisation is an anisotropic conductivity: in plane is the thickness-weighted mean,
  through plane the harmonic mean. Example (computed for this note): a 1.6 mm board with two full 35 um
  copper layers has about 17 W/mK in plane and 0.31 W/mK through plane. Vias are local through-plane
  conductors. Joule heating in traces and planes needs the current distribution: solve
  `div(sigma grad phi) = 0` on the copper, then `q = sigma |grad phi|^2`, the same scalar solver.
  Component packages are compact thermal networks (junction to case, junction to board) from data sheets.
- **Phase change.** The enthalpy-porosity fixed-grid method (Voller and Prakash [41]) covers
  melting of phase change materials (PCM heat buffers) and solder; niche for ViaForm's products.

### 2.2 Reference codes

OpenFOAM (chtMultiRegionFoam) for conjugate heat transfer, OpenLB and waLBerla for thermal LBM, Elmer and
MFEM [42] for FEM conduction. ViaForm does not need any of them as a dependency.

### 2.3 Accuracy, speed, GPU suitability

Steady conduction on 1M voxels is cheaper than the structural problem (one unknown per node instead of
three); with the existing multigrid expect well under a second per solve on the CPU. Correlation-based
convection is accurate to about 10 to 25 percent for simple shapes, worse in enclosures; conjugate
CFD reduces that to the CFD's own error. Thermal problems are diffusion dominated and multigrid friendly
on GPUs.

### 2.4 Verdict for ViaForm

Do G10 now: scalar hex8 conduction on the generative grid with the same multigrid, Robin convection from
correlations (selected per surface orientation and flow regime), linearised radiation, anisotropic
voxels for PCBs, a second scalar solve for Joule heating, heat sources from BOM parts. Add the thermal
compliance and maximum temperature (p-norm) objectives with adjoints, which follow the structural
pattern exactly. Conjugate heat transfer comes with the CFD crate (thermal LBM). View factors by GPU ray
casting are a later refinement for closed enclosures.

## 3. Thermodynamics of the products

### 3.1 Batteries

- **Heat generation.** Bernardi, Pawlikowski and Newman [43]: `q = I (U_ocv - V) - I T dU_ocv/dT`
  (irreversible overpotential heat plus reversible entropic heat), the formula every cell-level thermal
  model uses.
- **Equivalent circuit models (ECM).** Open-circuit voltage as a function of state of charge and
  temperature, series resistance and one or two RC pairs (Plett [44]). Lin et al. [45]
  coupled an ECM to a two-state (core and surface) thermal model for cylindrical cells and identified it
  from surface measurements, predicting core temperature. Fast, robust, needs only a pulse test to fit.
- **Physics-based models.** Doyle-Fuller-Newman pseudo-two-dimensional model (P2D/DFN) [46];
  single particle model with electrolyte (SPMe) derived asymptotically by Marquis et al. [47];
  the family is reviewed by Brosa Planella et al. [48]. PyBaMM [49] is the open
  reference implementation (BSD-3-Clause); Chen et al. [50] published a full DFN parameter set
  for the LG M50 21700 cell, the de facto test cell.
- **Thermal runaway.** Arrhenius decomposition reactions (SEI, anode, cathode, electrolyte) after
  Hatchard et al. [51]; mechanisms reviewed by Feng et al. [52]. Useful for abuse
  scenarios in battery pack design; for ViaForm, a temperature limit check is enough.

### 3.2 Motors and ESCs

Lumped parameter thermal networks are the standard for electric machines (review by Boglietti et al.
[53]): nodes for winding,
stator iron, rotor, magnets and housing, conductances from geometry, losses from copper (`I^2 R(T)`,
with copper resistance rising about 0.39 percent per kelvin), iron (Steinmetz) and friction. ESC losses are
MOSFET conduction `I^2 R_ds(on)` plus switching losses. Kirchgässner, Wallscheid and Böcker
[54] showed that a thermal network whose conductances are small neural networks
(thermal neural network) predicts motor temperatures with 64 parameters and a worst case error of 5.8 K
on a public motor dataset, a good model for learning from bench data in `learn`.

### 3.3 Thermo-elastic coupling

Thermal strain `alpha (T - T_ref)` enters the structural FEM as an initial strain load. One-way coupling
(heat first, then stress) is accurate whenever deformation does not change heat flow, which holds for
all ViaForm products. Validation by the uniform free expansion (exact) and the bimetal strip curvature of
Timoshenko [55].

### 3.4 Verdict for ViaForm

Put an ECM (OCV table, R0, two RC pairs, temperature dependence) with Bernardi heat and a two-state cell
thermal model into `phys::power`, plus lumped motor and ESC networks; parameters from Library part
records. This gives flight time, sag, cell and motor temperatures in the drone sim at negligible cost.
Offer SPMe with thermal coupling as a higher fidelity option later (P2); never P2D in the product.
Thermo-elastic coupling is a few dozen lines in `generative` once G10 exists.

## 4. Multiphysics coupling and differentiable simulation

### 4.1 Coupling

Monolithic coupling solves all fields in one nonlinear system (robust for strong coupling, hard to
build); partitioned coupling iterates between existing solvers (Keyes et al. [56]). For
partitioned two-way problems, quasi-Newton interface acceleration (IQN-ILS, Degroote, Bathe and
Vierendeels [57]) is the standard. ViaForm's couplings are almost all one-way or weak:
motor and electronics heat to conduction, conduction to thermal stress, aero loads to structure, BEM
thrust to flight dynamics, battery heat to cell temperature. Two-way coupling appears only in conjugate
heat transfer, which thermal LBM solves monolithically on the same lattice.

### 4.2 Adjoint methods

Discrete adjoints give gradients of any objective with respect to millions of design variables at the
cost of one extra linear solve (Giles and Pierce [58]); ViaForm's generative engine already
does this for compliance, stress, displacement and frequency, each checked against finite differences.
For time-dependent problems (impact, transient LBM) the adjoint runs backward in time and needs the
forward history: checkpointing trades memory for recomputation.

### 4.3 Differentiable solvers

- JAX-Fluids [59] and JAX-Fluids 2.0 [60]: fully differentiable compressible
  two-phase CFD, scaled to 512 A100 GPUs (GPLv3).
- PhiFlow [61] (MIT): differentiable PDE solvers for learning control.
- DiffTaichi [62]: differentiable programming language for physical simulation.
- Warp (NVIDIA, Apache-2.0 since 2025): kernel-level differentiable GPU programming, base of Newton
  [63].
- Brax [64], MuJoCo MJX and MuJoCo Playground [65], Genesis [66]:
  differentiable or GPU batched rigid body engines for robot learning.
- XLB [34]: differentiable LBM.
- Hybrid learning: learned interpolation inside a
  differentiable CFD solver [67] shows the best use of differentiability: train a small
  correction through a real solver.

Reviews: Newbury et al. [68]; a state-of-the-art report on differentiable physics by Shu et al.
(November 2026) [69]. Known limit: gradients through contact are stiff or discontinuous; Suh et
al. [70] showed that differentiable simulators do not reliably give better policy gradients than
zeroth order estimates when contact is involved.

### 4.4 Automatic differentiation in Rust

- `burn-autodiff`: tape-based AD over burn tensors, production ready for networks; a solver written as
  tensor operations could use it, but loses the matrix-free kernels' speed.
- `std::autodiff` (Enzyme [71] inside rustc): differentiates LLVM IR, so plain Rust loops are
  differentiable. As of the 2026 nightly documentation it is experimental, nightly only, requires LTO
  and special flags, and is being distributed through rustup [72]. Not a base for shipping
  engines yet; worth tracking.
- `diffsol` (MIT): Rust ODE and DAE solver with forward and adjoint sensitivities [73], a fit for
  battery and thermal network parameter identification.

### 4.5 Verdict for ViaForm

Keep hand-written discrete adjoints for FEM and (later) LBM; they are faster, deterministic and already
validated. Use burn autodiff for learned components (thermal neural networks, residual aero models in
the NeuroBEM style, policies). Fit battery and motor models with adjoint ODE sensitivities (own code or
`diffsol`). Do not build a differentiable contact simulator for RL; use the existing PPO plan.

## 5. Neural surrogates and AI for simulation

### 5.1 Leading methods

- **Neural operators.** Fourier neural operator (FNO) [74] and the general framework of
  Kovachki et al. [75]. FNO needs regular grids; GINO
  [76] couples a graph encoder to an FNO for 3D car geometries.
- **Transformer operators.** Transolver [77] attends over learned physical slices rather
  than points, scaling to large meshes; Transolver++ [78] reaches million-point
  geometries on one GPU; Transolver-3 [79] (2026) about doubles that capacity. Universal
  Physics Transformers [80] and AB-UPT [81] predict surface and volume fields for
  automotive meshes up to about 150 million cells from CAD alone, trainable on one GPU in under a day
  (authors' figures).
- **Graph networks.** MeshGraphNets [82] learn mesh-based dynamics by message passing; good for
  deformable and unstructured problems, but rollouts drift over long horizons.
- **Physics-informed networks (PINNs).** Raissi, Perdikaris and Karniadakis [83] fit a network
  to the PDE residual. Known failure modes: spectral bias and ill-conditioned losses for convection and
  stiff problems (Krishnapriyan et al. [84]), gradient pathologies between loss terms
  (Wang, Teng and Perdikaris [85]). Grossmann et al. [86] compared PINNs with FEM head
  to head on Poisson, Allen-Cahn and Schrödinger problems: PINNs did not beat FEM in solution time or
  accuracy, only in evaluation speed after training.
- **Diffusion surrogates.** Autoregressive conditional diffusion models give stable long rollouts and
  calibrated variability for turbulent flows (Kohl, Chen and Thuerey [87]).
- **Foundation models for PDEs.** Poseidon [88] (multiscale operator transformer pretrained on
  compressible and incompressible flows), DPOT [89] (denoising pretraining across PDE datasets).
  Aurora [90] shows what scale buys in a single domain: a 1.3 billion parameter model trained on
  over a million hours of geophysical data that beats operational forecasts at much lower cost. The
  engineering equivalents do not yet exist for 3D CAD geometry with arbitrary physics.

### 5.2 Benchmarks

PDEBench [91] (1D to 3D canonical PDEs), The Well [92] (15 TB, 16 datasets),
AirfRANS [93] (2D airfoil RANS), DrivAerNet++ [94] (8,000 car designs with
CFD), CarBench [95] (benchmarking neural surrogates on high-fidelity 3D car aerodynamics).

### 5.3 Honest assessment

McGreivy and Hakim [96] reviewed 82 papers on ML for fluid PDEs: 76 claimed to beat a
numerical method, but 79 percent of those compared against a weak baseline (not equal accuracy or
equal runtime, or not an efficient solver), and reporting biases hid negative results. Their rule:
compare at equal accuracy or equal runtime against a good solver. Combined with the PINN results above,
the picture in late 2026 is:

- Surrogates win when the same family of problems is queried many times (design space exploration,
  real-time previews, optimisation inner loops) and enough solver data exists to train them (hundreds
  to thousands of runs). AB-UPT and Transolver class models reach a few percent error on drag and
  surface pressure within the training distribution.
- They lose on out-of-distribution geometry, on guarantees (no error bound, no conservation unless
  built in), and against a good GPU solver for one-off questions.
- PINNs are not competitive as forward solvers for the problems ViaForm solves.

### 5.4 Verdict for ViaForm

P3. Once the thermal and CFD solvers produce data, train per-family geometry-to-field surrogates in burn
(a Transolver or AB-UPT style point transformer on wgpu) to rank variants and to give previews during
interactive edits. The solver always computes the numbers shown as results. Do not build PINNs. Use
small learned corrections (thermal neural networks, NeuroBEM-like rotor residuals) where bench or
flight data exists.

## 6. Rigid, articulated and contact dynamics

### 6.1 Leading methods

- **Articulated bodies.** Featherstone's articulated-body algorithm (ABA, O(n) forward dynamics),
  recursive Newton-Euler (inverse dynamics) and composite rigid body algorithm (mass matrix)
  [97]; Pinocchio [98] is the fastest open implementation (BSD-2-Clause).
- **Contact as complementarity.** Velocity-level LCP time stepping of Stewart and Trinkle [99]
  and Anitescu and Potra [100]; exact Coulomb friction, nonconvex, hard to solve robustly.
- **Convex compliant contact.** MuJoCo [101] relaxes contact into a convex optimisation with soft
  constraints (`solref`, `solimp`) and solves it with Newton, CG or PGS [102]. Drake's SAP
  [103] writes compliant contact as an unconstrained convex primal problem with proven global
  convergence and warm starts. Le Lidec et al. [104] compared contact models across simulators
  and showed that common relaxations (for example the gliding artefact of Anitescu's relaxation, or
  overly soft contact) widen the reality gap for manipulation; they published benchmarks and code.
- **Per-contact iteration.** RaiSim (Hwangbo, Lee and Hutter, 2018) solves contacts one at a time with exact friction
  cones; fast and accurate for legged robots.
- **Position based dynamics.** XPBD [105] with small substeps: robust,
  GPU-friendly, popular for cloth, cables and games; compliance is time-step independent. Accuracy for
  stiff articulated robots is lower than reduced-coordinate methods.
- **Incremental potential contact (IPC).** Li et al. [106] guarantee intersection-free, inversion
  free contact with barrier energies and continuous collision detection; affine body dynamics
  [107] makes it fast for stiff bodies; GIPC [108] gives analytic barrier Hessians and a full
  GPU implementation (3x speedup from the eigensystems alone). Robust but orders of magnitude slower than
  MuJoCo-style contact per step; best for offline validation of tight assemblies (snap fits, grippers on
  thin parts).
- **GPU batch simulation for learning.** Isaac Gym [109] and its successor Isaac Lab
  [110]; MuJoCo MJX and MuJoCo Playground [65] (sim-to-real on six platforms in
  under eight weeks); Newton [63] (NVIDIA, Google DeepMind and Disney, Linux Foundation since
  September 2025) with MuJoCo Warp as its main solver; Genesis [66]. Vendor figures claim
  hundreds of thousands of environment steps per second on one GPU; treat them as upper bounds.

### 6.2 Reference codes and licences

MuJoCo (Apache-2.0), Drake (BSD-3-Clause), Pinocchio (BSD-2-Clause), Newton and Warp (Apache-2.0),
Genesis (Apache-2.0), Brax (Apache-2.0), Isaac Lab (BSD-3-Clause, needs Isaac Sim), Rapier and parry
(Apache-2.0, Rust, maximal coordinates plus multibody joints, impulse based).

### 6.3 Verdict for ViaForm

The `phys` design in RUST-ENGINES section 6 is sound. Two changes are worth making:

1. Formulate contact as the convex soft-constraint problem (MuJoCo's formulation, or SAP's primal form)
   and solve it with a Newton or CG method on the constraint space, keeping projected Gauss-Seidel as the
   fallback and for batches. Newton converges in a few iterations on stiff grasps where PGS stalls; both
   are deterministic with fixed contact order.
2. Add the Le Lidec et al. contact benchmarks to section 6.4 so the reality gap is measured, not assumed.

Keep IPC out of the real-time engine; consider an offline IPC check for gripper and snap-fit designs
later. GPU batching (f32) only after the CPU batch is validated, as planned.

## 7. Numerics and performance

### 7.1 Methods

- **Matrix-free FEM.** Apply operators from element kernels instead of assembled matrices; sum
  factorisation for high order (Kronbichler and Kormann [111]); MFEM [42] for
  partial assembly on GPUs. On voxels with one shared element matrix, matrix-free is optimal, as
  ViaForm already shows.
- **Multigrid.** Geometric multigrid is optimal on structured grids (Trottenberg, Oosterlee and
  Schüller [112]); MG-preconditioned CG for topology optimisation [113]; giga-voxel
  topology optimisation used the same family on 8,000 CPU cores [114]. Algebraic multigrid
  (for example NVIDIA AmgX) is needed only on unstructured meshes.
- **Mixed precision.** Iterative refinement in three precisions (Carson and Higham [115]) and the
  survey of Higham and Mary [116]: factorise or precondition in low precision, compute residuals
  and update in high precision. ViaForm's f32 V-cycle inside an f64 flexible CG (Notay [117]) is an instance.
- **GPU sparse solvers.** On GPUs, multigrid smoothers must be parallel (Jacobi, Chebyshev, red-black
  Gauss-Seidel); Chebyshev is already used in ViaForm.

### 7.2 WebGPU and wgpu limits (as of wgpu 30, November 2026)

- No f64 in WGSL core. wgpu's native `SHADER_F64` works on Vulkan only, not Metal [118]; Apple
  GPUs have no f64 hardware. Therefore: f32 kernels, f64 outer iterations on the CPU or emulated
  double-single where truly needed.
- `SUBGROUP` operations: native on Vulkan, DX12 and Metal in wgpu [118]; in browsers, a WebGPU
  extension since Chrome 134 (2025). Use them for reductions (dot products in CG) with a shared-memory
  fallback.
- f32 atomics: native `SHADER_FLOAT32_ATOMIC` on Metal (Apple7+, MSL 3.0) and Vulkan with an extension
  [118]. Floating-point atomic accumulation is non-deterministic; use gather-style kernels (one
  thread per output node, fixed summation order), exactly as the CPU `K u` does, to keep E-11.
- 64-bit integer atomics (min/max) are native on Vulkan, DX12 and Metal (MSL 2.4+); useful for
  deterministic fixed-point accumulation if scatter is unavoidable.
- WebGPU default limits [119]: 256 invocations per workgroup, 16 KiB workgroup storage, 128 MiB per
  storage buffer binding, 256 MiB per buffer; native adapters allow more (request adapter limits). A 1M
  voxel structural problem (3.2M DOFs) fits within default binding sizes per vector; LBM domains above
  about 1.5M cells per buffer need the higher native limits or split buffers.
- burn and CubeCL (MIT OR Apache-2.0) compile Rust kernels to WGSL, Metal, CUDA and others; CubeCL is an
  option for writing the solver kernels once for wgpu and CUDA (Azure).

### 7.3 Rust crates

Versions and licences from crates.io on 2026-11-22 [73]:

| Crate | Version | Licence | Use in ViaForm |
|---|---|---|---|
| `wgpu` | 30.0.2 | MIT OR Apache-2.0 | GPU compute (all GPU engines) |
| `burn` | 0.22.1 | MIT OR Apache-2.0 | Networks, training, surrogates, autodiff of learned parts |
| `cubecl` | 0.11.4 | MIT OR Apache-2.0 | Optional kernel language for wgpu plus CUDA |
| `faer` | 0.24.4 | MIT | Dense and sparse direct solvers (coarse grids, battery and thermal networks, small FEM) |
| `nalgebra` | 0.35.0 | Apache-2.0 | Small dense algebra in kin, phys |
| `nalgebra-sparse` | 0.12.0 | Apache-2.0 | Sparse storage if faer is not used |
| `parry3d-f64` | 0.31.1 | Apache-2.0 | Collision geometry, distances (and wall distances for CFD voxels) |
| `rapier3d-f64` | 0.36.1 | Apache-2.0 | Reference only (ViaForm builds its own `phys`, E-2) |
| `diffsol` | 0.20.0 | MIT | ODE/DAE with sensitivities (battery, lumped thermal) |
| `rayon` | 1.12.0 | MIT OR Apache-2.0 | CPU parallelism |

All are pure Rust (wgpu's platform layers and burn's optional CUDA backend excepted, already allowed).

### 7.4 Verdict for ViaForm

Port the matrix-free hex8 apply, the Chebyshev smoother, restriction and prolongation to WGSL with a
gather formulation, keep the coarse grid on the CPU (faer Cholesky or the existing banded Cholesky), and
wrap the f32 GPU V-cycle in the existing f64 flexible CG on the CPU. The same kernels serve conduction.
This doubles as the first `viaform-gpu` consumer and de-risks the LBM crate.

## 8. Recommended build order

Each step lists its crate, its scope and its acceptance benchmarks. A step is done when every benchmark
passes in CI in release mode, with the reference value, the tolerance and the source printed by a
`validate` example, as `generative` does today.

### Step 1. Thermal conduction in `generative` (G10), effort S, P0

Scope: scalar hex8 conduction on the voxel grid, multigrid PCG, sources, Dirichlet, flux, Robin
convection, linearised radiation, anisotropic conductivity (PCB), Joule heating, adjoints for thermal
compliance and p-norm maximum temperature, thermal strain load case.

| Benchmark | Reference | Pass |
|---|---|---|
| 1D slab, fixed temperatures, uniform source | Parabolic closed form | max error under 0.1 percent at 32 cells through |
| Manufactured solution on a cube (smooth `T`) | Exact | second order convergence over three meshes |
| Pin fin, steel k = 15 W/mK, D = 5 mm, L = 50 mm, h = 25 W/m2K, convective tip | Incropera [37] closed form: q / dT = 0.01026 W/K, efficiency 0.510 (computed for this note) | within 1 percent at 10 voxels across the diameter (staircase surface corrected by area) |
| Multigrid iterations, conduction, 1M voxels, random 0/1 density | mesh independent | at most 1.5x the uniform case |
| Free bar, uniform dT | `alpha dT L` exact | 1e-8 relative |
| Bimetal strip curvature | Timoshenko [55] | within 2 percent |
| PCB anisotropy: 1.6 mm board, two full 35 um copper layers | in plane 17.1 W/mK, through 0.31 W/mK (rule of mixtures, computed) | homogenised voxel model matches resolved layers within 2 percent |
| Thermal adjoints | central finite differences | 1e-5 relative |
| G10 AC (existing) | heat sink keeps a 5 W source under the limit with less mass than a plain block | as specified |

### Step 2. Power and thermal networks in `phys::power`, effort S, P0

Scope: ECM (OCV(SOC, T), R0, two RC pairs), Bernardi heat, two-state cell thermal model, pack as cells in
series and parallel, lumped motor and ESC networks, parameter fitting from pulse tests by adjoint ODE
sensitivities.

| Benchmark | Reference | Pass |
|---|---|---|
| Bernardi heat on a constant current discharge | energy balance: integral of `I (U_ocv - V)` equals the electrical loss | 1e-6 relative |
| LG M50 1C discharge at 25 C, terminal voltage | DFN with the Chen et al. [50] parameter set, generated offline once with PyBaMM [49] and stored as CSV | ECM fitted on pulse data within 30 mV RMS; SPMe (if built) within 15 mV RMS |
| Cylindrical cell core temperature | Lin et al. [45] two-state model, same parameters | trajectories match the published model within 0.5 K |
| Motor network step response | analytic first-order solution of a two-node network | 1e-6 relative |
| Drone hover endurance | measured flight time of the reference 3-inch build (bench log) | within 10 percent |

### Step 3. GPU multigrid in `viaform-gpu`, effort M, P0/P1

Scope: WGSL kernels for hex8 apply (f32, gather), Chebyshev, restriction, prolongation, dot products with
subgroups; CPU f64 flexible CG outside.

| Benchmark | Reference | Pass |
|---|---|---|
| Cantilever 80x10x10 mm, h = 0.25 mm | Timoshenko 0.10362 mm and CPU result 0.10272 mm (ENGINE.md) | GPU equals CPU to 1e-6 relative |
| Iteration count, uniform and random SIMP fields | CPU iteration counts (11 and up to 50) | within 2 iterations |
| 1M voxel study, 100 iterations, M-series Mac | E-15 target: 2 minutes | at most 60 s |
| Determinism | two runs, same GPU | bitwise equal |

### Step 4. Rotor model in `phys::aero`, effort S, P1

Scope: BEM with Prandtl tip and root loss, low Reynolds number airfoil polars, propeller geometry from the
part record (chord and twist tables), optional learned residual.

| Benchmark | Reference | Pass |
|---|---|---|
| Static thrust and power coefficients vs RPM for three small APC propellers | UIUC propeller database (Brandt and Selig [120]) | CT and CP within 10 percent |
| CT and CP vs advance ratio J | same database | within 10 percent up to 80 percent of the windmill J |
| Parity with `sim` hover | existing parity example | trajectories within 1 mm over 10 s |

### Step 5. Contact upgrade in `phys`, effort M, P1 (inside the planned `phys` work)

| Benchmark | Reference | Pass |
|---|---|---|
| Existing section 6.4 suite | RUST-ENGINES 6.4 | as specified |
| Box on incline, Coulomb friction, mu = 0.5 at 20 and 30 degrees | stick below `atan(mu)` = 26.6 degrees, slide above with `a = g (sin - mu cos)` | stick drift under 0.1 mm over 10 s; slide acceleration within 1 percent |
| Contact model benchmarks of Le Lidec et al. [104] | published results and code | report the same metrics; no gliding on the sliding tests |
| Newton vs PGS on a 5-finger grasp | same contact problem | Newton residual 1e-8 in under 20 iterations |

### Step 6. Lattice Boltzmann CFD crate `viaform-cfd`, effort L, P1

Scope: section 1.4. Validation in increasing order of difficulty:

| Benchmark | Reference | Pass |
|---|---|---|
| Poiseuille channel, laminar | parabolic profile, analytic | L2 error under 1 percent at 16 cells across; second order with Bouzidi walls |
| 2D Taylor-Green vortex decay | analytic `exp(-2 nu k^2 t)` | decay rate within 0.5 percent |
| Lid-driven cavity Re = 100 and 1000 | Ghia, Ghia and Shin [121]: minimum centreline u = -0.21090 at y = 0.4531 (Re 100) and -0.38289 at y = 0.1719 (Re 1000) | within 1 percent at 256x256 |
| Schäfer-Turek 2D-1, Re 20, steady [122] | Cd 5.57 to 5.59, Cl 0.0104 to 0.0110, pressure difference 0.1172 to 0.1176 | inside the bands |
| Schäfer-Turek 2D-2, Re 100, periodic | Cd max 3.22 to 3.24, Cl max 0.99 to 1.01, Strouhal 0.295 to 0.305 | inside the bands |
| Schäfer-Turek 3D-1Z, Re 20 | Cd 6.05 to 6.25, Cl 0.008 to 0.010 | inside the bands |
| Sphere, Re 20 and 100 | Schiller-Naumann correlation [123]: Cd 2.61 and 1.09; Johnson and Patel [124]: steady axisymmetric wake up to Re about 210, Cd about 1.09 at Re 100 | Cd within 3 percent; axisymmetric wake at Re 100, symmetry breaking between Re 210 and 270 |
| Turbulent channel, Re_tau 180, wall-resolved LES | Moser, Kim and Mansour [125] mean velocity and Reynolds stresses | mean u+ within 3 percent; peak u_rms within 10 percent |
| Natural convection in a square cavity (thermal LBM) | de Vahl Davis [126] mean Nusselt 1.118, 2.243, 4.519, 8.800 for Ra 10^3 to 10^6 | within 1 percent up to Ra 10^5, 2 percent at 10^6 |
| Actuator disk in hover | momentum theory induced velocity `sqrt(T / (2 rho A))` | within 3 percent |
| Actuator line, isolated propeller | BEM of step 4 and UIUC data | thrust within 5 percent of BEM |
| Throughput | own estimate in 1.3 | at least 1.5 GLUPS D3Q19 FP32 on an M-series Max |
| Determinism | two runs, same GPU | bitwise equal |

### Step 7. Conjugate heat transfer and thermal design, effort M then L, P2

Scope: thermal LBM coupled to the solid conduction voxels (same lattice), forced cooling of an enclosure
with a fan or propeller wash as an actuator disk; heat sink topology optimisation first with
convection from correlations on the evolving surface (density-gradient surface term), then with a
Darcy-Brinkman flow model, then (research) adjoint LBM [15].

| Benchmark | Reference | Pass |
|---|---|---|
| Heated vertical plate in still air | Churchill and Chu [36] average Nusselt | within 10 percent |
| Cylinder in cross flow, Re 100, heated | Incropera [37] cross-flow correlation | within 10 percent |
| Natural convection heat sink | Lazarov et al. [39] measured design trends (optimised beats pin fin at equal mass) | same ranking |
| Brinkman flow past a voxelised cylinder | Schäfer-Turek 2D-1 | drag within 5 percent at the chosen penalization |

### Step 8. Surrogates in `learn`, effort M, P3

Scope: point transformer surrogate (Transolver or AB-UPT style) in burn per product family, trained on
step 1 and step 6 outputs.

| Benchmark | Reference | Pass |
|---|---|---|
| Held-out designs in family | solver results | drag or peak temperature within 5 percent on 90 percent of held-out designs |
| Equal-runtime and equal-accuracy baselines | McGreivy and Hakim [96] rules | report both; the surrogate is used only where it wins at equal accuracy |
| Out-of-distribution flag | solver on random new designs | error predictor flags at least 90 percent of designs with error above 10 percent |

### Not recommended

- A finite volume RANS solver with a mesh generator (cost of the mesher alone exceeds the LBM crate).
- PINNs as forward solvers.
- Full P2D battery models in the product.
- IPC in the real-time robot engine.
- General automatic differentiation of the solvers before `std::autodiff` is stable.

## References

Numbered in order of first citation.

1. R. Mahony, V. Kumar, P. Corke. Multirotor aerial vehicles: modeling, estimation, and control of quadrotor. IEEE Robotics and Automation Magazine 19(3) (2012) 20-32. doi:10.1109/MRA.2012.2206474
2. P. L. Bhatnagar, E. P. Gross, M. Krook. A model for collision processes in gases. I. Small amplitude processes in charged and neutral one-component systems. Physical Review 94 (1954) 511-525. doi:10.1103/PhysRev.94.511
3. D. d'Humières, I. Ginzburg, M. Krafczyk, P. Lallemand, L.-S. Luo. Multiple-relaxation-time lattice Boltzmann models in three dimensions. Philosophical Transactions of the Royal Society A 360 (2002) 437-451. doi:10.1098/rsta.2001.0955
4. J. Latt, B. Chopard. Lattice Boltzmann method with regularized pre-collision distribution functions. Mathematics and Computers in Simulation 72 (2006) 165-168. doi:10.1016/j.matcom.2006.05.017
5. M. Geier, M. Schönherr, A. Pasquali, M. Krafczyk. The cumulant lattice Boltzmann equation in three dimensions: Theory and validation. Computers and Mathematics with Applications 70 (2015) 507-547. doi:10.1016/j.camwa.2015.05.001
6. T. Krüger, H. Kusumaatmaja, A. Kuzmin, O. Shardt, G. Silva, E. M. Viggen. The Lattice Boltzmann Method: Principles and Practice. Springer, 2017. doi:10.1007/978-3-319-44649-3
7. J. Smagorinsky. General circulation experiments with the primitive equations. Monthly Weather Review 91 (1963) 99-164.
8. M. Bouzidi, M. Firdaouss, P. Lallemand. Momentum transfer of a Boltzmann-lattice fluid with boundaries. Physics of Fluids 13 (2001) 3452-3459. doi:10.1063/1.1399290
9. O. Malaspinas, P. Sagaut. Wall model for large-eddy simulation based on the lattice Boltzmann method. Journal of Computational Physics 275 (2014) 25-40. doi:10.1016/j.jcp.2014.06.020
10. M. Lehmann, M. J. Krause, G. Amati, M. Sega, J. Harting, S. Gekle. Accuracy and performance of the lattice Boltzmann method with 64-bit, 32-bit, and customized 16-bit number formats. Physical Review E 106 (2022) 015308. doi:10.1103/PhysRevE.106.015308
11. M. Lehmann. Esoteric Pull and Esoteric Push: two simple in-place streaming schemes for the lattice Boltzmann method on GPUs. Computation 10 (2022) 92. doi:10.3390/computation10060092
12. M. Lehmann. FluidX3D (software), github.com/ProjectPhysX/FluidX3D. Free for non-commercial use only.
13. X. He, S. Chen, G. D. Doolen. A novel thermal model for the lattice Boltzmann method in incompressible limit. Journal of Computational Physics 146 (1998) 282-300. doi:10.1006/jcph.1998.6057
14. G. Pingen, A. Evgrafov, K. Maute. Topology optimization of flow domains using the lattice Boltzmann method. Structural and Multidisciplinary Optimization 34 (2007) 507-524. doi:10.1007/s00158-007-0105-7
15. F. Dugast, Y. Favennec, C. Josset, Y. Fan, L. Luo. Topology optimization of thermal fluid flows with an adjoint lattice Boltzmann method. Journal of Computational Physics 365 (2018) 376-404. doi:10.1016/j.jcp.2018.03.040
16. S. V. Patankar, D. B. Spalding. A calculation procedure for heat, mass and momentum transfer in three-dimensional parabolic flows. International Journal of Heat and Mass Transfer 15 (1972) 1787-1806. doi:10.1016/0017-9310(72)90054-3
17. R. I. Issa. Solution of the implicitly discretised fluid flow equations by operator-splitting. Journal of Computational Physics 62 (1986) 40-65. doi:10.1016/0021-9991(86)90099-9
18. H. G. Weller, G. Tabor, H. Jasak, C. Fureby. A tensorial approach to computational continuum mechanics using object-oriented techniques. Computers in Physics 12 (1998) 620-631. doi:10.1063/1.168744
19. F. R. Menter. Two-equation eddy-viscosity turbulence models for engineering applications. AIAA Journal 32 (1994) 1598-1605. doi:10.2514/3.12149
20. C. S. Peskin. The immersed boundary method. Acta Numerica 11 (2002) 479-517. doi:10.1017/S0962492902000077
21. R. Mittal, G. Iaccarino. Immersed boundary methods. Annual Review of Fluid Mechanics 37 (2005) 239-261. doi:10.1146/annurev.fluid.37.061903.175743
22. P. Angot, C.-H. Bruneau, P. Fabrie. A penalization method to take into account obstacles in incompressible viscous flows. Numerische Mathematik 81 (1999) 497-520. doi:10.1007/s002110050401
23. T. Borrvall, J. Petersson. Topology optimization of fluids in Stokes flow. International Journal for Numerical Methods in Fluids 41 (2003) 77-107. doi:10.1002/fld.426
24. J. Alexandersen, C. S. Andreasen. A review of topology optimisation for fluid-based problems. Fluids 5 (2020) 29. doi:10.3390/fluids5010029
25. P. Fischer et al. NekRS, a GPU-accelerated spectral element Navier-Stokes solver. Parallel Computing 114 (2022) 102982. doi:10.1016/j.parco.2022.102982. arXiv:2104.05829
26. J. G. Leishman. Principles of Helicopter Aerodynamics, 2nd ed. Cambridge University Press, 2006.
27. L. Bauersfeld, E. Kaufmann, P. Foehn, S. Sun, D. Scaramuzza. NeuroBEM: Hybrid aerodynamic quadrotor model. Robotics: Science and Systems XVII, 2021. doi:10.15607/RSS.2021.XVII.042. arXiv:2106.08015
28. J. N. Sørensen, W. Z. Shen. Numerical modeling of wind turbine wakes. Journal of Fluids Engineering 124 (2002) 393-399. doi:10.1115/1.1471361
29. H. Asmuth, H. Olivares-Espinosa, S. Ivanell. Actuator line simulations of wind turbine wakes using the lattice Boltzmann method. Wind Energy Science 5 (2020) 623-645. doi:10.5194/wes-5-623-2020
30. P. Ventura Diaz, S. Yoon. High-fidelity computational aerodynamics of multi-rotor unmanned aerial vehicles. AIAA SciTech Forum, Kissimmee, 2018 (AIAA 2018-1266). NASA NTRS 20180001326
31. M. Bauer et al. waLBerla: A block-structured high-performance framework for multiphysics simulations. Computers and Mathematics with Applications 81 (2021) 478-501. doi:10.1016/j.camwa.2020.01.007
32. J. Latt et al. Palabos: Parallel Lattice Boltzmann Solver. Computers and Mathematics with Applications 81 (2021) 334-350. doi:10.1016/j.camwa.2020.03.022
33. M. J. Krause et al. OpenLB: Open source lattice Boltzmann code. Computers and Mathematics with Applications 81 (2021) 258-288. doi:10.1016/j.camwa.2020.04.033
34. M. Ataei, H. Salehipour. XLB: A differentiable massively parallel lattice Boltzmann library in Python. Computer Physics Communications 300 (2024) 109187. doi:10.1016/j.cpc.2024.109187. arXiv:2311.16080
35. M. P. Bendsøe, O. Sigmund. Topology Optimization: Theory, Methods, and Applications. Springer, 2003. doi:10.1007/978-3-662-05086-6
36. S. W. Churchill, H. H. S. Chu. Correlating equations for laminar and turbulent free convection from a vertical plate. International Journal of Heat and Mass Transfer 18 (1975) 1323-1329. doi:10.1016/0017-9310(75)90243-4
37. T. L. Bergman, A. S. Lavine, F. P. Incropera, D. P. DeWitt. Fundamentals of Heat and Mass Transfer, 7th ed. Wiley, 2011.
38. J. Alexandersen, O. Sigmund, N. Aage. Large scale three-dimensional topology optimisation of heat sinks cooled by natural convection. International Journal of Heat and Mass Transfer 100 (2016) 876-891. doi:10.1016/j.ijheatmasstransfer.2016.05.013
39. B. S. Lazarov, O. Sigmund, K. E. Meyer, J. Alexandersen. Experimental validation of additively manufactured optimized shapes for passive cooling. Applied Energy 226 (2018) 330-339. doi:10.1016/j.apenergy.2018.05.106
40. M. F. Modest. Radiative Heat Transfer, 3rd ed. Academic Press, 2013.
41. V. R. Voller, C. Prakash. A fixed grid numerical modelling methodology for convection-diffusion mushy region phase-change problems. International Journal of Heat and Mass Transfer 30 (1987) 1709-1719. doi:10.1016/0017-9310(87)90317-6
42. R. Anderson et al. MFEM: A modular finite element methods library. Computers and Mathematics with Applications 81 (2021) 42-74. doi:10.1016/j.camwa.2020.06.009
43. D. Bernardi, E. Pawlikowski, J. Newman. A general energy balance for battery systems. Journal of the Electrochemical Society 132 (1985) 5-12. doi:10.1149/1.2113792
44. G. L. Plett. Battery Management Systems, Volume I: Battery Modeling. Artech House, 2015.
45. X. Lin, H. E. Perez, S. Mohan, J. B. Siegel, A. G. Stefanopoulou, Y. Ding, M. P. Castanier. A lumped-parameter electro-thermal model for cylindrical batteries. Journal of Power Sources 257 (2014) 1-11. doi:10.1016/j.jpowsour.2014.01.097
46. M. Doyle, T. F. Fuller, J. Newman. Modeling of galvanostatic charge and discharge of the lithium/polymer/insertion cell. Journal of the Electrochemical Society 140 (1993) 1526-1533. doi:10.1149/1.2221597
47. S. G. Marquis, V. Sulzer, R. Timms, C. P. Please, S. J. Chapman. An asymptotic derivation of a single particle model with electrolyte. Journal of the Electrochemical Society 166 (2019) A3693-A3706. doi:10.1149/2.0341915jes
48. F. Brosa Planella et al. A continuum of physics-based lithium-ion battery models reviewed. Progress in Energy 4 (2022) 042003. doi:10.1088/2516-1083/ac7d31
49. V. Sulzer, S. G. Marquis, R. Timms, M. Robinson, S. J. Chapman. Python Battery Mathematical Modelling (PyBaMM). Journal of Open Research Software 9 (2021) 14. doi:10.5334/jors.309
50. C.-H. Chen, F. Brosa Planella, K. O'Regan, D. Gastol, W. D. Widanage, E. Kendrick. Development of experimental techniques for parameterization of multi-scale lithium-ion battery models. Journal of the Electrochemical Society 167 (2020) 080534. doi:10.1149/1945-7111/ab9050
51. T. D. Hatchard, D. D. MacNeil, A. Basu, J. R. Dahn. Thermal model of cylindrical and prismatic lithium-ion cells. Journal of the Electrochemical Society 148 (2001) A755. doi:10.1149/1.1377592
52. X. Feng, M. Ouyang, X. Liu, L. Lu, Y. Xia, X. He. Thermal runaway mechanism of lithium ion battery for electric vehicles: A review. Energy Storage Materials 10 (2018) 246-267. doi:10.1016/j.ensm.2017.05.013
53. A. Boglietti, A. Cavagnino, D. Staton, M. Shanel, M. Mueller, C. Mejuto. Evolution and modern approaches for thermal analysis of electrical machines. IEEE Transactions on Industrial Electronics 56 (2009) 871-882. doi:10.1109/TIE.2008.2011622
54. W. Kirchgässner, O. Wallscheid, J. Böcker. Thermal neural networks: Lumped-parameter thermal modeling with state-space machine learning. Engineering Applications of Artificial Intelligence 117 (2023) 105537. doi:10.1016/j.engappai.2022.105537. arXiv:2103.16323
55. S. Timoshenko. Analysis of bi-metal thermostats. Journal of the Optical Society of America 11 (1925) 233-255. doi:10.1364/JOSA.11.000233
56. D. E. Keyes et al. Multiphysics simulations: Challenges and opportunities. International Journal of High Performance Computing Applications 27 (2013) 4-83. doi:10.1177/1094342012468181
57. J. Degroote, K.-J. Bathe, J. Vierendeels. Performance of a new partitioned procedure versus a monolithic procedure in fluid-structure interaction. Computers and Structures 87 (2009) 793-801. doi:10.1016/j.compstruc.2008.11.013
58. M. B. Giles, N. A. Pierce. An introduction to the adjoint approach to design. Flow, Turbulence and Combustion 65 (2000) 393-415. doi:10.1023/A:1011430410075
59. D. A. Bezgin, A. B. Buhendwa, N. A. Adams. JAX-Fluids: A fully-differentiable high-order computational fluid dynamics solver for compressible two-phase flows. Computer Physics Communications 282 (2023) 108527. doi:10.1016/j.cpc.2022.108527
60. D. A. Bezgin, A. B. Buhendwa, N. A. Adams. JAX-Fluids 2.0: Towards HPC for differentiable CFD of compressible two-phase flows. Computer Physics Communications 308 (2025) 109433. doi:10.1016/j.cpc.2024.109433. arXiv:2402.05193
61. P. Holl, V. Koltun, N. Thuerey. Learning to control PDEs with differentiable physics. ICLR 2020. arXiv:2001.07457
62. Y. Hu, L. Anderson, T.-M. Li, Q. Sun, N. Carr, J. Ragan-Kelley, F. Durand. DiffTaichi: Differentiable programming for physical simulation. ICLR 2020. arXiv:1910.00935
63. Newton physics engine (NVIDIA, Google DeepMind, Disney Research), contributed to the Linux Foundation, announced 2025-09-29; MuJoCo Warp as its main solver. github.com/newton-physics/newton (software, Apache-2.0)
64. C. D. Freeman, E. Frey, A. Raichuk, S. Girgin, I. Mordatch, O. Bachem. Brax: A differentiable physics engine for large scale rigid body simulation. NeurIPS 2021 Datasets and Benchmarks. arXiv:2106.13281
65. K. Zakka et al. MuJoCo Playground. Robotics: Science and Systems XXI, 2025. arXiv:2502.08844
66. Genesis Authors. Genesis: A generative and universal physics engine for robotics and beyond. Software, December 2024, github.com/Genesis-Embodied-AI/Genesis (Apache-2.0; technical report pending)
67. D. Kochkov, J. A. Smith, A. Alieva, Q. Wang, M. P. Brenner, S. Hoyer. Machine learning-accelerated computational fluid dynamics. PNAS 118 (2021) e2101784118. doi:10.1073/pnas.2101784118
68. R. Newbury, J. Collins, K. He, J. Pan, I. Posner, D. Howard, A. Cosgun. A review of differentiable simulators. IEEE Access 12 (2024) 97581-97604. doi:10.1109/ACCESS.2024.3425448
69. L. Shu, Z. Huang, Y. Chen et al. Same physics, different gradients: A state-of-the-art report on differentiable physics simulation. arXiv:2611.12162, 2026 (preprint)
70. H. J. T. Suh, M. Simchowitz, K. Zhang, R. Tedrake. Do differentiable simulators give better policy gradients? ICML 2022. arXiv:2202.00817
71. W. S. Moses, V. Churavy. Instead of rewriting foreign code for machine learning, automatically synthesize fast gradients. NeurIPS 2020. arXiv:2010.01709
72. Rust project. `core::autodiff` (nightly, experimental) and rustc-dev-guide "Autodiff installation", doc.rust-lang.org/nightly/core/autodiff and rustc-dev-guide.rust-lang.org/autodiff/installation.html, read 2026-11-22
73. crates.io registry entries for wgpu, burn, cubecl, faer, nalgebra, nalgebra-sparse, parry3d-f64, rapier3d-f64, diffsol, rayon, read 2026-11-22
74. Z. Li, N. Kovachki, K. Azizzadenesheli, B. Liu, K. Bhattacharya, A. Stuart, A. Anandkumar. Fourier neural operator for parametric partial differential equations. ICLR 2021. arXiv:2010.08895
75. N. Kovachki et al. Neural operator: Learning maps between function spaces with applications to PDEs. Journal of Machine Learning Research 24(89) (2023) 1-97. arXiv:2108.08481
76. Z. Li et al. Geometry-informed neural operator for large-scale 3D PDEs. NeurIPS 2023. arXiv:2309.00583
77. H. Wu, H. Luo, H. Wang, J. Wang, M. Long. Transolver: A fast transformer solver for PDEs on general geometries. ICML 2024. arXiv:2402.02366
78. H. Luo, H. Wu, H. Zhou, L. Xing, Y. Di, J. Wang, M. Long. Transolver++: An accurate neural solver for PDEs on million-scale geometries. ICML 2025, PMLR 267. arXiv:2502.02414
79. H. Zhou, H. Wu, H. Shangguan et al. Transolver-3: Scaling up transformer solvers to industrial-scale geometries. arXiv:2602.04940, 2026 (preprint)
80. B. Alkin, A. Fürst, S. Schmid, L. Gruber, M. Holzleitner, J. Brandstetter. Universal physics transformers: A framework for efficiently scaling neural operators. NeurIPS 2024. arXiv:2402.12365
81. B. Alkin, M. Bleeker, R. Kurle, T. Kronlachner et al. AB-UPT: Scaling neural CFD surrogates for high-fidelity automotive aerodynamics simulations via anchored-branched universal physics transformers. arXiv:2502.09692 (v4, 2025; ICLR 2026)
82. T. Pfaff, M. Fortunato, A. Sanchez-Gonzalez, P. W. Battaglia. Learning mesh-based simulation with graph networks. ICLR 2021. arXiv:2010.03409
83. M. Raissi, P. Perdikaris, G. E. Karniadakis. Physics-informed neural networks: A deep learning framework for solving forward and inverse problems involving nonlinear partial differential equations. Journal of Computational Physics 378 (2019) 686-707. doi:10.1016/j.jcp.2018.10.045
84. A. S. Krishnapriyan, A. Gholami, S. Zhe, R. M. Kirby, M. W. Mahoney. Characterizing possible failure modes in physics-informed neural networks. NeurIPS 2021. arXiv:2109.01050
85. S. Wang, Y. Teng, P. Perdikaris. Understanding and mitigating gradient flow pathologies in physics-informed neural networks. SIAM Journal on Scientific Computing 43 (2021) A3055-A3081. doi:10.1137/20M1318043
86. T. G. Grossmann, U. J. Komorowska, J. Latz, C.-B. Schönlieb. Can physics-informed neural networks beat the finite element method? IMA Journal of Applied Mathematics 89 (2024) 143-174. doi:10.1093/imamat/hxae011
87. G. Kohl, L.-W. Chen, N. Thuerey. Benchmarking autoregressive conditional diffusion models for turbulent flow simulation. arXiv:2309.01745, 2023
88. M. Herde, B. Raonić, T. Rohner, R. Käppeli, R. Molinaro, E. de Bézenac, S. Mishra. Poseidon: Efficient foundation models for PDEs. NeurIPS 2024. arXiv:2405.19101
89. Z. Hao et al. DPOT: Auto-regressive denoising operator transformer for large-scale PDE pre-training. ICML 2024. arXiv:2403.03542
90. C. Bodnar et al. A foundation model for the Earth system. Nature 641 (2025) 1180-1187. doi:10.1038/s41586-025-09005-y
91. M. Takamoto et al. PDEBench: An extensive benchmark for scientific machine learning. NeurIPS 2022 Datasets and Benchmarks. arXiv:2210.07182
92. R. Ohana, M. McCabe et al. The Well: a large-scale collection of diverse physics simulations for machine learning. NeurIPS 2024 Datasets and Benchmarks. arXiv:2412.00568
93. F. Bonnet, J. A. Mazari, P. Cinnella, P. Gallinari. AirfRANS: High fidelity computational fluid dynamics dataset for approximating Reynolds-averaged Navier-Stokes solutions. NeurIPS 2022 Datasets and Benchmarks. arXiv:2212.07564
94. M. Elrefaie, F. Morar, A. Dai, F. Ahmed. DrivAerNet++: A large-scale multimodal car dataset with computational fluid dynamics simulations and deep learning benchmarks. NeurIPS 2024 Datasets and Benchmarks. arXiv:2406.09624
95. M. Elrefaie et al. CarBench: A comprehensive benchmark for neural surrogates on high-fidelity 3D car aerodynamics. arXiv:2512.07847, 2025 (preprint)
96. N. McGreivy, A. Hakim. Weak baselines and reporting biases lead to overoptimism in machine learning for fluid-related partial differential equations. Nature Machine Intelligence 6 (2024) 1256-1269. doi:10.1038/s42256-024-00897-5
97. R. Featherstone. Rigid Body Dynamics Algorithms. Springer, 2008. doi:10.1007/978-1-4899-7560-7
98. J. Carpentier et al. The Pinocchio C++ library: A fast and flexible implementation of rigid body dynamics algorithms and their analytical derivatives. IEEE/SICE SII 2019, 614-619. doi:10.1109/SII.2019.8700380
99. D. E. Stewart, J. C. Trinkle. An implicit time-stepping scheme for rigid body dynamics with inelastic collisions and Coulomb friction. International Journal for Numerical Methods in Engineering 39 (1996) 2673-2691. doi:10.1002/(SICI)1097-0207(19960815)39:15<2673::AID-NME972>3.0.CO;2-I
100. M. Anitescu, F. A. Potra. Formulating dynamic multi-rigid-body contact problems with friction as solvable linear complementarity problems. Nonlinear Dynamics 14 (1997) 231-247. doi:10.1023/A:1008292328909
101. E. Todorov, T. Erez, Y. Tassa. MuJoCo: A physics engine for model-based control. IEEE/RSJ IROS 2012, 5026-5033. doi:10.1109/IROS.2012.6386109
102. E. Todorov. Convex and analytically-invertible dynamics with contacts and constraints: Theory and implementation in MuJoCo. IEEE ICRA 2014, 6054-6061. doi:10.1109/ICRA.2014.6907751
103. A. M. Castro, F. N. Permenter, X. Han. An unconstrained convex formulation of compliant contact. IEEE Transactions on Robotics 39(2) (2023) 1301-1320. arXiv:2110.10107
104. Q. Le Lidec, W. Jallet, L. Montaut, I. Laptev, C. Schmid, J. Carpentier. Contact models in robotics: a comparative analysis. IEEE Transactions on Robotics 40 (2024) 3716-3733. doi:10.1109/TRO.2024.3434208
105. M. Macklin, M. Müller, N. Chentanez. XPBD: Position-based simulation of compliant constrained dynamics. Motion in Games 2016, 49-54. doi:10.1145/2994258.2994272
106. M. Li, Z. Ferguson, T. Schneider, T. Langlois, D. Zorin, D. Panozzo, C. Jiang, D. M. Kaufman. Incremental potential contact: Intersection- and inversion-free, large-deformation dynamics. ACM Transactions on Graphics 39(4) (2020). doi:10.1145/3386569.3392425
107. L. Lan, D. M. Kaufman, M. Li, C. Jiang, Y. Yang. Affine body dynamics: Fast, stable and intersection-free simulation of stiff materials. ACM Transactions on Graphics 41(4) (2022). doi:10.1145/3528223.3530064. arXiv:2201.10022
108. K. Huang, F. M. Chitalu, H. Lin, T. Komura. GIPC: Fast and stable Gauss-Newton optimization of IPC barrier energy. ACM Transactions on Graphics 43(2) (2024). doi:10.1145/3643028. arXiv:2308.09400
109. V. Makoviychuk et al. Isaac Gym: High performance GPU-based physics simulation for robot learning. NeurIPS 2021 Datasets and Benchmarks. arXiv:2108.10470
110. NVIDIA (M. Mittal et al.). Isaac Lab: A GPU-accelerated simulation framework for multi-modal robot learning. arXiv:2511.04831, 2025
111. M. Kronbichler, K. Kormann. A generic interface for parallel cell-based finite element operator application. Computers and Fluids 63 (2012) 135-147. doi:10.1016/j.compfluid.2012.04.012
112. U. Trottenberg, C. W. Oosterlee, A. Schüller. Multigrid. Academic Press, 2001.
113. O. Amir, N. Aage, B. S. Lazarov. On multigrid-CG for efficient topology optimization. Structural and Multidisciplinary Optimization 49 (2014) 815-829.
114. N. Aage, E. Andreassen, B. S. Lazarov, O. Sigmund. Giga-voxel computational morphogenesis for structural design. Nature 550 (2017) 84-86. doi:10.1038/nature23911
115. E. Carson, N. J. Higham. Accelerating the solution of linear systems by iterative refinement in three precisions. SIAM Journal on Scientific Computing 40 (2018) A817-A847. doi:10.1137/17M1140819
116. N. J. Higham, T. Mary. Mixed precision algorithms in numerical linear algebra. Acta Numerica 31 (2022) 347-414. doi:10.1017/S0962492922000022
117. Y. Notay. Flexible conjugate gradients. SIAM Journal on Scientific Computing 22 (2000) 1444-1460. doi:10.1137/S1064827599362314
118. wgpu-types 30.0.2 documentation, `FeaturesWGPU` (SHADER_F64, SUBGROUP, SHADER_FLOAT32_ATOMIC, SHADER_INT64_ATOMIC_MIN_MAX), docs.rs/wgpu-types, read 2026-11-22
119. W3C. WebGPU and WebGPU Shading Language (WGSL), Candidate Recommendations, w3.org/TR/webgpu and w3.org/TR/WGSL (limits section)
120. J. B. Brandt, M. S. Selig. Propeller performance data at low Reynolds numbers. 49th AIAA Aerospace Sciences Meeting, AIAA 2011-1255, 2011. Data: UIUC Propeller Database, m-selig.ae.illinois.edu/props/propDB.html
121. U. Ghia, K. N. Ghia, C. T. Shin. High-Re solutions for incompressible flow using the Navier-Stokes equations and a multigrid method. Journal of Computational Physics 48 (1982) 387-411. doi:10.1016/0021-9991(82)90058-4
122. M. Schäfer, S. Turek. Benchmark computations of laminar flow around a cylinder. In: Flow Simulation with High-Performance Computers II, Notes on Numerical Fluid Mechanics 48, Vieweg, 1996, 547-566. doi:10.1007/978-3-322-89849-4_39
123. R. Clift, J. R. Grace, M. E. Weber. Bubbles, Drops, and Particles. Academic Press, 1978 (Schiller-Naumann drag correlation, `Cd = 24/Re (1 + 0.15 Re^0.687)`).
124. T. A. Johnson, V. C. Patel. Flow past a sphere up to a Reynolds number of 300. Journal of Fluid Mechanics 378 (1999) 19-70. doi:10.1017/S0022112098003206
125. R. D. Moser, J. Kim, N. N. Mansour. Direct numerical simulation of turbulent channel flow up to Re_tau = 590. Physics of Fluids 11 (1999) 943-945. doi:10.1063/1.869966
126. G. de Vahl Davis. Natural convection of air in a square cavity: a bench mark numerical solution. International Journal for Numerical Methods in Fluids 3 (1983) 249-264. doi:10.1002/fld.1650030305
