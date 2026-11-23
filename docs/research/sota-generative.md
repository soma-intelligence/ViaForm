# Generative design: state of the art and ViaForm gap analysis

Date: 2026-11-22. Scope: the ViaForm generative engine (`generative/`, docs/generative/ENGINE.md) and
the work items G0 to G10 of docs/specs/RUST-ENGINES.md section 3. Products in view: 3 inch FPV drone
frames and carbon plates, desk robot arm parts, a robotic hand, electronics enclosures.

Method. Every paper cited below was checked against a registry (Crossref by DOI, arXiv abstract pages,
publisher or proceedings pages) for authors, year, venue and identifier. Items that could not be
checked were left out (for example vendor claims about Hyperganic's current product, and the exact
compliance penalties in Langelaar's overhang papers, which are not in any open abstract). Vendor
figures are marked as vendor claims. Crate licences come from crates.io on 2026-11-22.

Constraint recalled from the owner decisions: everything in Rust (rayon, wgpu/WGSL, burn), no C or C++
linking, no Python, engines MIT OR Apache-2.0 (E-1, E-3, E-4, E-20), smooth mesh output rather than
B-rep fitting (E-10).

---

## 0. Summary table

Effort is in engineer-weeks (ew) for one person who knows the code base. Priority: P1 next, P2 after,
P3 later or never.

| Capability | State of the art (2026) | ViaForm today | Gap | Effort | Priority |
|---|---|---|---|---|---|
| Large-scale solve, GPU | Matrix-free hex8 MG-PCG on GPU, mixed precision; 65.5M elements in about 2 h on one GPU [30]; fused gather-GEMM-scatter kernels 4.6 to 7.3x end to end over CPU [33]; sparse narrow-band grids past 1B voxels [29] | CPU matrix-free MG-PCG, f32 V-cycle in f64 CG, 1M voxels at 0.68 to 0.95 s per iteration on an M5 Max; cap 6M | No GPU path, no sparse grid | 6 to 8 ew | P1 (G4) |
| Overhang control | Layer-wise AM filter for any angle [69, 70]; continuous front propagation [71, 72]; build orientation co-optimised [73] | Langelaar filter, 45 degree stencil, on or off | Arbitrary angle, orientation search, overhang report on mesh | 2 to 3 ew | P1 (G2) |
| Enclosed voids (SLS, resin, FDM infill) | Cumulative-sum flood-fill filter, differentiable, controls escape channels [75]; virtual temperature method [74] | None | Full gap | 1 to 2 ew | P1 (G2) |
| Milling | Multi-axis machining filter (2.5D to 5-axis) [76]; accessibility constraint with tool shape [77]; casting parameterisation [78] | One tool direction, smooth max | Several directions, tool radius, undercut check | 2 to 3 ew | P1 (G2) |
| Plate cutting (carbon, aluminium) | Extrusion parameterisation plus solid and void length scale [79, 80] | Extrusion, one variable per line | Thickness from a list, min slot and bridge, DXF | 1 to 2 ew | P1 (G2) |
| Thermal (conduction, convection) | SIMP conduction [41]; design-dependent convection boundaries [46, 47, 48]; full natural-convection CFD topology optimisation [42, 43, 45], experimentally validated [44] | None | Full gap | 4 to 6 ew (conduction plus simplified convection) | P1 (G10) |
| Output geometry | Iso-surface plus isotropic remeshing [139] and QEM decimation [138]; SDF plus RBF smoothing with volume preservation [142]; robust mesh booleans [143, 144] | Marching tetrahedra, Taubin, exact bores, volume-matching offset | Remesh, decimate, plane snap, self-intersection test, booleans | 3 to 4 ew | P1 (G5) |
| Buckling | Linearised buckling bound formulation with aggregation [104, 105, 106] | None | Full gap | 3 to 4 ew | P2 (new G11) |
| Loads from simulation | Equivalent static loads for nonlinear and dynamic responses [108]; crash via HCA [109] | Static, modal, Newmark impact; hand-made load cases | Envelope of simulated wrenches | 2 to 3 ew | P2 (G3) |
| Lattice and multiscale | Homogenisation then de-homogenisation [83 to 88]; voxel infill [90]; graded TPMS [91, 92] | None | Full gap | 5 to 7 ew | P2 (G7) |
| Stress | p-norm with adaptive normalisation [97]; augmented Lagrangian local constraints, one adjoint [99, 100]; adaptive mesh refinement [37] | p-norm, qp relaxation, eroded design, tightening rounds | Local constraints, boundary shape polish | 2 to 3 ew | P2 (G8) |
| Multi-material and fibre | DMO [93], PolyMat [94]; fibre path optimisation for printed composites [95, 96] | None | Full gap | 3 to 5 ew | P2/P3 (G9, new G14) |
| Fatigue | Finite-life fatigue with rainflow and damage aggregation [103]; stress-based fatigue [102] | None | Full gap | 2 to 3 ew | P3 (new G15) |
| Thermo-elastic, electro-thermal | Thermal stress loads with RAMP-type penalisation [61]; electro-thermal actuators [62] | None | Full gap | 2 to 3 ew after G10 | P3 (new G16) |
| Fluid, thermo-fluid | Brinkman Stokes [49], Navier-Stokes [50], LBM [51], RANS [53, 54], two-fluid heat exchangers [56, 57], sparse narrow band [59] | None | Full gap | 10 ew or more | P3 (new G18) |
| Robust design | Eroded, nominal, dilated [10]; spatially varying errors [82] | Eroded, nominal, dilated with bound formulation | At SOTA for uniform errors | none | done |
| Eigenfrequency | Bound formulation, repeated eigenvalues [107] | Same, subspace iteration, warm starts | At SOTA | none | done |
| ML acceleration | Neural reparameterisation [114, 115, 117]; foundation model for 2D compliance [124] | None | Optional | 3 to 4 ew | P3 (new G17) |
| Generative CAD, LLM agents | CAD code from point clouds [131]; text to CAD [130]; LLM topology optimisation agents [135] | None | Optional | 2 to 3 ew for study authoring | P3 (new G19) |
| Explicit methods (level set, MMC, feature mapping) | Mature in research [13 to 23] | SIMP plus `frame3d` ground structure | Not needed for products | none | skip |
| B-rep reconstruction | Feature or primitive fitting [140, 141, 145] | Mesh body by design (E-10) | Out of scope by owner decision | none | skip |

What ViaForm already does that is at or near the research state of the art: robust three-field
projection with a bound formulation [10], MMA [12], geometric multigrid preconditioned CG after Amir
et al. [27] with a mixed-precision V-cycle, the frequency bound over the lowest modes [107], stress
p-norm with adaptive normalisation [97], as-built feasibility checks (body count, unsupported loads),
exact bores in the output, and an impact time axis. None of the commercial tools surveyed in section 7
advertises a transient impact constraint inside generative design.

---

## 1. Topology optimisation methods

### 1.1 Density methods: SIMP, filters, projection

Landmarks. Homogenisation-based topology optimisation [1]; the compact educational codes that set the
benchmarks still used today: 99 lines [2], 88 lines [3], top3d [5], and the 2020 rewrite top99neo and
top3D125 [4]. Density and sensitivity filters [7, 8], Helmholtz PDE filter [11], projection for a
minimum length scale [9], and the analysis of projection, continuation and robust formulations [10].
The comparative review of approaches remains the reference [6]. MMA [12] is the standard optimiser.

Recent. Work since 2022 is mostly on scale (section 1.4), length scale control that holds for nearly
binary designs (hyperparameter-free geometric constraints with a double PDE filter, [80]), and better
coupling to manufacturing filters (section 3).

Open codes. top3d [5], top99neo and top3D125 [4], PolyTop [38], TopOpt_in_PETSc [26], FEniTop [40],
JAX-FEM [39] (GPL-3.0).

Maturity: industrial (every commercial tool in section 7 is density based or offers it).

Verdict for ViaForm: at SOTA. The engine already reproduces the top3d cantilever to 0.04 % and runs
MMA with Heaviside continuation. Two small additions are worth having: the Zhou et al. geometric
length scale constraints [79] (with the derived hyperparameters of [80]) as an option when the robust
formulation is too expensive, and a PDE filter option [11] once the grid stops being a full box
(sparse grids, section 1.4), because a cone filter on a sparse grid is awkward.

### 1.2 Level set and phase field

Landmarks: Wang, Wang and Guo [13] and Allaire, Jouve and Toader [14] introduced level set topology
optimisation; the 2013 review classifies the variants [15]; compact velocity field level set codes
[16]; the phase field method driven by sensitivities [17].

Maturity: research and niche industrial (Ansys Mechanical exposes a level set based topology
optimisation with an AM overhang constraint, section 7).

Verdict for ViaForm: skip as a solver. The crisp boundary is the main appeal, and ViaForm already gets
a crisp boundary from projection plus its surface pipeline. A level set representation is useful as
the output stage (SDF, section 6) and for G8 shape optimisation, which moves an explicit surface.

### 1.3 Explicit and feature-mapping methods (MMC, MMV, geometry projection)

Landmarks: moving morphable components [18], moving morphable voids in 3D [19], a compact 3D MMC code
[20], geometry projection of bars [21], and the feature-mapping review [22], which shows these methods
share one structure: a geometric primitive mapped to a density field.

Maturity: research. Strong where the part should be a few bars or plates with few variables.

The generalised geometry projection [23] unifies the bar, plate and void primitives.

Verdict for ViaForm: no new solver. The idea is relevant to two products: a drone frame is a handful
of arms and plates, a robot link is a tube with bosses. ViaForm's `frame3d` ground structure already
covers the bar case. If a "few editable members" output is wanted later, geometry projection [21] on
top of the existing density pipeline is the cheapest route, since it reuses the FEM, filter and MMA
unchanged.

### 1.4 Giga-voxel, GPU and multiresolution

Landmarks. Giga-voxel structural design on a supercomputer, an aircraft wing at over 1 billion voxels
[24]; the same machinery reduced a suspension bridge girder weight by more than 28 % [25]. On a single
GPU: Wu, Dick and Westermann solved a 621 x 488 x 1000 voxel problem with a matrix-free geometric
multigrid [28]; Liu et al. passed one billion voxels on one shared-memory machine with a sparse
narrow-band grid and a mixed-precision multigrid [29]. Earlier GPU codes include [32].

Recent (2021 to 2026). Multi-GPU with aggregation AMG and mixed precision [31]. Träff et al. released
simple GPU codes and showed a 65.5 million element compliance problem solved in about 2 hours on one
GPU, against about 3 h 10 min for their reference implementation [30]. A 2026 preprint fuses gather,
element GEMM and scatter in one kernel for a matrix-free 3D SIMP and reports 4.6 to 7.3x end-to-end
speedups over CPU on 216k to 4.9M element cantilevers, 8.9 to 13.8x per matrix-vector product [33].
PeTTO recasts the optimality system as pseudo-transient PDEs and reports 40 to 50x GPU over desktop
CPU [34]. Sparse narrow-band ideas now reach thermo-fluids: a two-fluid heat exchanger at 370^3 with
5 x 10^7 design variables on one workstation [59]. Fluidic topology optimisation on sparse grids [58].

Multiresolution and adaptivity: separate analysis, density and design meshes (MTOP) [36]; adaptive mesh
refinement for stress [37]; fully parallel level set at large scale [35].

Open codes: TopOpt_in_PETSc [26], the GPU codes of [30], spgrid_topo_opt from [29].

Maturity: research codes are mature; industrial tools rarely go past tens of millions of elements.

Verdict for ViaForm: G4 is the highest-leverage speed item. ViaForm's design (matrix-free hex8, one
element matrix, geometric multigrid, f32 V-cycle) is exactly what [28, 29, 30, 33] put on GPUs, so the
port is mechanical. Plan: WGSL kernels for `K u` with the fused gather-GEMM-scatter pattern of [33],
Chebyshev smoothing, restriction and prolongation, filter and projection; f64 outer CG on CPU first
(as the spec says), full-GPU CG with periodic refinement second. A sparse or narrow-band grid [29] is
the natural follow-up for 8M voxels and up on a 48 GB Mac, since most voxels of a 30 % part are void.

---

## 2. Multiphysics topology optimisation

### 2.1 Heat conduction and heat sinks

Conduction (volume-to-point and spreaders): the SIMP formulation of conduction with a finite volume
discretisation [41]. It reuses a scalar version of the structural machinery, and is a direct fit for
ViaForm's voxel grid and multigrid.

Convection. A constant film coefficient on the design boundary gives closed internal voids and
over-predicts heat transfer, which industrial work addresses with design-dependent convection
boundaries [47]. Simplified convection models in a level set setting [46] and shape-dependent heat
transfer coefficients for natural convection [48] are the cheap middle ground. The full route solves
natural convection (Navier-Stokes plus energy) inside the optimisation [42], at large scale in 3D
[43], or through a cheaper reduced model ("poor man's" approach) [45]. Experiments: printed
optimised LED heat sinks outperform lattice geometries by more than 21 % [44]; topology optimised heat
sinks were printed and tested thermohydraulically [60].

Maturity: conduction and simplified convection are industrial (SIMULIA Tosca offers it, as described
in [47]); natural convection CFD optimisation is research, validated by experiment.

Verdict for ViaForm: G10 is P1 because electronics enclosures, motor mounts and ESC plates are thermal
parts. Build in two steps: (a) steady conduction on the existing grid with the same filter, projection
and MMA, heat sources from BOM parts, a max temperature p-norm; (b) design-dependent convection by
applying a Robin condition on the density gradient (smeared interface) after [46, 47, 48]. Full CFD
(natural convection [43]) waits for the fluid item (2.3).

### 2.2 Thermo-elastic and electro-thermal

Thermal stress loads depend on the design, which breaks SIMP's usual monotonicity; penalising the
thermal stress coefficient (RAMP-type) fixes it [61]. Electro-thermal and thermal actuators were
optimised with coupled nonlinear analysis and adjoints [62].

Verdict for ViaForm: after G10. Useful for motor mounts (thermal growth of a stator against a printed
PETG seat) and for copper or aluminium heat spreaders on PCBs. Effort is small once conduction exists.

### 2.3 Fluid and thermo-fluid

Landmarks: Stokes flow with a Brinkman penalisation [49]; steady Navier-Stokes [50]; lattice Boltzmann
based topology optimisation [51] and its adjoint for thermal flows [52]; turbulent RANS models with
exact sensitivities [53] and turbulent heat transfer [54]; the 2020 review of 186 fluid papers [55].
Heat exchangers: density based two-fluid exchangers with up to 113 % better performance at the same
pressure drop in a shell-and-tube inspired case [56]; body-fitted level set exchangers with a non-mixing
distance constraint [57]; sparse narrow-band thermo-fluid at 5 x 10^7 variables [59].

Maturity: research, with one focused commercial player (ToffeeX, section 7).

Verdict for ViaForm: P3. None of the five products needs flow design to ship. If ducted cooling for an
enclosure or a cold plate becomes a product, start with Brinkman Stokes plus convection-diffusion on the
voxel grid ([49] plus the energy equation as in [56]), on the GPU path, with the sparse narrow band of
[59] to keep it tractable.

### 2.4 Compliant mechanisms

Landmarks: compliant mechanism synthesis by topology optimisation [63]; geometric nonlinearity [8, 65];
robust interpolation for finite strain [66]; review [64].

Verdict for ViaForm: relevant to the robotic hand (flexure fingers, tendon guides). It needs a
displacement-ratio objective (already close to the displacement p-norm machinery) and, to be honest
about large rotations, geometric nonlinearity [65, 66]. P3 unless the hand moves to flexure joints.

---

## 3. Manufacturing constraints

### 3.1 Additive: overhang and self-support

Landmarks: projection-based overhang constraints [68]; Langelaar's layer-by-layer AM filter in 2D and
3D [69, 70]; continuous front propagation with a free overhang angle and near-zero adjoint cost [71];
the 2021 comparison of continuous and discrete filters, with an improved continuous version [72];
simultaneous build orientation and topology [73]; the 2018 review of topology optimisation for AM [67].

Maturity: industrial (Altair Inspire overhang control with Strict and Lenient modes, Ansys Mechanical
AM overhang constraint, Siemens lists overhang angles among its rules; section 7).

Verdict for ViaForm: G2 as specified. ViaForm has the Langelaar filter but only a 45 degree cross stencil
or a full 3 x 3. Generalise the support footprint to any angle (Langelaar's own generalisation [70]) or
adopt the front propagation filter [71, 72], which takes the angle as a parameter and suits any voxel
spacing. Add an orientation sweep (a few candidate build directions run as variants, as [73] does
inside the optimisation) since variants already run in parallel.

### 3.2 Enclosed voids

The cumulative-sum flood fill filter turns every enclosed void solid, works in 2D and 3D at low cost,
and gives direct control over the number, location and size of access channels [75]. The virtual
temperature method (voids as heat conductors, a temperature bound) is the older alternative [74].

Verdict for ViaForm: P1. SLS powder and resin get trapped, and an FDM part with a sealed void prints but
cannot be inspected. The flood fill filter [75] is cheap on a voxel grid and differentiable. Keep the
spec's user choice between "fill" and "escape hole".

### 3.3 Milling, casting, extrusion

Multi-axis machining filter for 2.5D, 3, 4 and 5-axis by listing tool directions [76]; accessibility
with a tool shape and collisions [77]; a Heaviside parameterisation along a casting direction [78].

Verdict for ViaForm: extend `Milling` to several directions with a smooth max across the per-direction
filters [76] and a tool radius through the void-side length scale; add a casting option (two-sided draw
direction, [78]) later since no current product is cast.

### 3.4 Length scale

Robust projection [10] gives both solid and void minimum sizes and is what ViaForm uses. Geometric
constraints [79] are a cheaper alternative; [80] removes their hyperparameter tuning and fixes their
interaction with PDE filters. Manufacturing tolerant design [81] and spatially varying errors [82]
extend robustness to non-uniform over or under etching.

Verdict: at SOTA for uniform errors. For carbon plates (G2), the in-plane slot and bridge minimums
come directly from the robust filter applied in 2D on the extruded variables.

### 3.5 Lattices, infill, homogenisation and de-homogenisation

Landmarks: post-treatment of homogenisation into a fine-scale design [83]; projection of
homogenisation results into high-resolution manufacturable microstructures [84]; modulated and
oriented periodic microstructures [85]; singularity-aware de-homogenisation [86]; phasor noise
de-homogenisation [87] and an 808-line code [88]; review of multi-scale structures [89]. Voxel-level
infill with local volume bounds that converges to bone-like structures [90]. Graded lattices derived
from topology optimisation gave about 40 to 50 % higher specific stiffness than strategies that ignore
the optimisation result [91]. TPMS lattices (gyroid, Schwarz) are well characterised [92].

Maturity: graded lattice workflows are industrial (nTop, Altair OptiStruct lattice optimisation,
section 7); de-homogenisation is research grade but has public codes [88].

Verdict for ViaForm: G7 at P2. For FDM and SLS robot parts and enclosures, a solid shell plus graded TPMS
infill is the visible feature buyers compare against nTop. Start with the spec's plan (homogenised
stiffness tables per cell type, density graded by a solid run), output as an implicit field. Phasor
de-homogenisation [87, 88] is the upgrade when anisotropic, stress-aligned infill is wanted.

### 3.6 Multi-material and composites

Discrete material optimisation [93] chooses between candidate materials or ply angles per element;
PolyMat gives a compact multi-material reference [94]. For printed continuous fibre, gradient-based fibre
path optimisation beats the concentric-ring layouts of commercial slicers in stiffness per fibre used
[95]; variable-stiffness laminates have been designed and manufactured end to end [96].

Verdict for ViaForm: G9 as specified (DMO-style, two then four materials). For the carbon plate
product, the relevant composite question is ply orientation of a quasi-isotropic sheet, which is fixed
by the supplier; fibre steering [95] only matters if ViaForm targets continuous-fibre printers. P3.

---

## 4. Stress, fatigue, buckling, dynamics, uncertainty

Stress. p-norm aggregation with adaptive normalisation [97] (what ViaForm does), stress-constrained
formulations with clustering [98], augmented Lagrangian handling of every local constraint with one
adjoint [99] and its compact code [100], robust stress design with eroded and dilated fields [101],
and adaptive mesh refinement to resolve stress on the final boundary [37].

Fatigue. Stress-based fatigue constraints [102]; finite-life fatigue with rainflow counting, a Sines
damage parameter and log-aggregated damage [103].

Buckling. Linearised buckling with bound formulations and aggregation [104], a 250-line code [105], and
a multilevel solve that brings the cost close to linear analyses [106]. Worked numbers from [105]: on a
480 x 240 compressed column the compliance-optimal design has a buckling load factor of about 0.75;
the buckling-constrained design reaches 8.53 with about 4 % more volume and about 30 % less stiffness.

Dynamics and crash. Eigenfrequency bounds with repeated eigenvalues [107] (in ViaForm). Equivalent
static loads for nonlinear and dynamic responses [108]; crashworthiness with hybrid cellular automata
[109].

Verdict for ViaForm. Stress is near SOTA; the augmented Lagrangian option [99, 100] is worth adding
for least-mass studies where the p-norm still leaves local peaks. Buckling is the larger gap: thin
drone arms, robot link walls and carbon plates in compression fail by buckling before yield, and the
compliance-optimal design can have a buckling factor under 1 [105]. Fatigue matters for drone arms
under motor vibration but can follow. Crash is well served by the existing Newmark impact plus G3
(loads from simulation, envelope of wrenches), which is the practical version of ESL [108].

---

## 5. Machine learning and AI in generative design

### 5.1 Neural reparameterisation

Optimising the weights of a network that outputs the density field, instead of the densities: the
Google study found the best design 50 % more often than the best baseline over 116 tasks [114];
TOuNN uses an MLP as the density field [115]; NTopo parameterises both density and displacement with
implicit networks [116]. A 2024 DTU/TUM study found the benefit is real only on harder, non-convex
problems (acoustics) with unconstrained first-order optimisation and Adam, and limited against
constrained or higher-order methods such as MMA [117].

### 5.2 Surrogates and generative models for topology optimisation

Iteration-free CNN prediction [118, 119]; conditional GANs on physical fields [120]; diffusion models
with performance guidance (TopoDiff: 8x lower physical performance error and 11x fewer infeasible
designs than a conditional GAN, on 64 x 64 2D compliance) [121]; trajectory alignment with the
optimiser [122]; resolution-free neural implicit fields (NITO) [123]; a foundation model trained on
2.2 million optimised 2D structures, under one second per design at 64 to 256 squared, up to 90 % lower
mean compliance than prior learned models, compliance and linear elasticity only [124].

### 5.3 Generative CAD and LLM-driven design

Sequence models of sketch-and-extrude CAD: DeepCAD [125], SkexGen [126], on the Fusion 360 Gallery
data [127]. Direct B-rep generation: BrepGen [128] and AutoBrep [129]. Text to parametric CAD:
Text2CAD [130]. Point cloud to executable CAD code with a small LLM, 10x lower Chamfer distance than
prior methods [131]. CAD code with self-verification and the CADPrompt benchmark [132]. LLMs in the
design and manufacturing loop [133]; an LLM proposing and refining trusses from FEM feedback [134]; a
six-agent LLM system that writes, runs and checks topology optimisation code [135].

### 5.4 Honest evidence

A DTU review argues that most learned topology optimisation papers reproduce small 2D compliance
problems, overstate what the methods can do, and are rarely compared fairly with the classical
optimiser, data generation cost included; it recommends targeting sub-problems instead [111]. The
earlier case against non-gradient methods [110] applies to most learned replacements of the optimiser.
A broad 2023 review catalogues the learned approaches [112]. The broader engineering-design review reaches similar cautions on
constraints and performance [113]. The strongest 2025 results [124] are still 2D, compliance only, and
below 256 squared, while ViaForm's studies are 3D, up to 6M voxels, with stress, frequency, impact and
manufacturing filters. Neural reparameterisation helps on some hard problems but not against MMA on
constrained ones [117].

Verdict for ViaForm: no ML in the optimisation loop for now. Two narrow uses are worth a small budget:
(a) a learned warm start or instant preview for 2D plate studies (carbon frames), where the problem
class is close to [124], judged by iterations saved, never by the final design; (b) an LLM-backed study
author that turns a prompt plus the assembly into a study JSON (regions, loads, process), validated by
the engine before running, in the spirit of [135]. Generative CAD models [125 to 131] do not fit E-10
(mesh output) and are out of scope.

---

## 6. Output and geometry

Iso-surfacing: marching cubes [136] and dual contouring with Hermite data, which keeps sharp features
[137]. Mesh quality: isotropic remeshing by split, collapse, flip and tangential relaxation [139];
quadric error decimation [138]. Post-processing of topology results: the review classifies skeleton,
surface and volume approaches [140]; level set extraction with RBFs followed by shape optimisation on
the extracted boundary [141]; a 2025 SDF plus RBF pipeline that keeps volume fraction and topology and
reports 18 % lower peak von Mises stress than conventional extraction [142]. Booleans: exact mesh
arrangements [143] and interactive robust booleans at up to 200k triangles [144]. B-rep recovery from
points by segmentation plus primitive and freeform fitting [145].

Verdict for ViaForm: G5 at P1. ViaForm's surface already keeps volume, bores and connectivity, which
many research pipelines do not. Missing: remeshing to a target edge length, decimation to a budget,
planar snapping of keep-in faces, a self-intersection check, minimum wall measurement, and robust
booleans so a candidate can be cut by a CAD solid (screw holes added after the fact). The SDF route
[142] fits ViaForm's implicit future (lattices in G7 are implicit too): keep a narrow-band signed
distance field of the result as the canonical output, mesh it on demand. B-rep fitting stays out
(E-10).

---

## 7. Commercial benchmarks

| Product | What it offers (verified from vendor docs) | The bar for ViaForm |
|---|---|---|
| Autodesk Fusion generative design | Manufacturing methods Unrestricted, Additive, 2.5-axis, 3-axis and 5-axis milling, 2-axis cutting, casting, several selectable at once; many outcomes per study; cloud solves [146] | Same process list locally (G2), many variants in parallel (G6), cost index already present |
| nTop | Implicit modelling, field-driven design, TPMS lattices, topology optimisation with multiple objectives and constraints; heat exchanger workflows with GPU CFD and conjugate heat transfer on implicit geometry [147] | Implicit output and graded lattices (G5, G7) |
| Altair Inspire and OptiStruct | Overhang shape control with Strict and Lenient methods, not combinable with lattice optimisation; automatic PolyNURBS fit of the result [148]; two-phase lattice optimisation with Euler buckling checks on struts [149]; fatigue-aware topology optimisation through SimLab and OptiStruct [149] | Overhang any angle (G2), buckling (G11), smooth editable output (G5) |
| Siemens NX, Simcenter | Topology optimisation with manufacturing rules: symmetry patterns, draw direction, cavity avoidance, overhang angles [150] | Draw direction and cavity rules (G2) |
| Ansys Discovery and Mechanical | GPU-native structural topology optimisation in Discovery, a few minutes per run per Ansys material; Mechanical offers a level set topology optimisation with an AM overhang constraint and modal coupling [151] | GPU speed (G4) |
| ToffeeX | Thermal-fluid topology optimisation including two-fluid exchangers; Ansys Discovery plug-in; vendor-reported cases (Nissan oil cooler, battery cold plate) [152] | Thermo-fluid (G18), P3 |
| LEAP 71 PicoGK | Open source voxel geometry kernel for computational engineering, Apache-2.0, C++ runtime on OpenVDB with a C# API [153] | Shows the implicit voxel route is industrially credible; not usable directly (C++) |

Where ViaForm is already ahead of the surveyed tools: local and offline, bit-reproducible results,
modal and impact constraints in the same study, exact bores and point masses from the BOM, and
as-built feasibility checks. Where it is behind: process coverage (overhang angle, multi-axis milling,
casting, trapped volumes), thermal, lattices, and output editing.

---

## 8. Rust ecosystem

Licences from crates.io (2026-11-22) [154]. "Pure Rust" means no C or C++ build step.

| Crate | Use for ViaForm | Licence | Notes |
|---|---|---|---|
| wgpu 30, naga | GPU kernels (G4), WGSL | MIT OR Apache-2.0 | Metal and Vulkan, already chosen (E-4) |
| cubecl 0.11, cubecl-wgpu | Write GPU kernels in Rust, compile to WGSL or CUDA | MIT OR Apache-2.0 | From the burn team; an option to share kernels between burn and the solver |
| burn 0.22, burn-wgpu | ML (G17) | MIT OR Apache-2.0 | Chosen (E-3) |
| rayon 1.12 | CPU parallelism | MIT OR Apache-2.0 | In use |
| pulp 0.22, wide 1.7 | Portable SIMD | MIT; Zlib OR Apache-2.0 OR MIT | Alternative to hand NEON |
| faer 0.24 | Dense and sparse Cholesky, LU, eigen | MIT | Coarse grid solve, small eigenproblems for buckling (G11) |
| nalgebra 0.35, nalgebra-sparse | Small dense algebra, CSR | Apache-2.0 | Element matrices |
| sprs 0.11 | Sparse matrices | MIT OR Apache-2.0 | |
| clarabel 0.11 | Conic interior point | Apache-2.0 | Not a replacement for MMA; useful for small QP subproblems (fibre angle, Pareto scalarisation) |
| argmin 0.11 | Optimisation framework | MIT OR Apache-2.0 | Line searches, L-BFGS for shape optimisation (G8) |
| parry3d 0.31 | BVH, distance, ray casts | Apache-2.0 | Self-intersection and min wall checks (G5); already chosen for physics |
| obvhs 0.4, bvh 0.13, kiddo 6, rstar 0.14 | Spatial indices | MIT OR Apache-2.0; MIT; MIT OR Apache-2.0; MIT OR Apache-2.0 | Ray casting for wall thickness, k-NN for RBF smoothing |
| fast-surface-nets 0.2 | Surface nets on regular grids | MIT OR Apache-2.0 | Alternative mesher for previews |
| isosurface 0.0.4 | Marching cubes, dual contouring | Apache-2.0 | Old, unmaintained; reference only |
| saft 0.34 | SDF compiler, discretiser, mesher | MIT OR Apache-2.0 | Implicit output (G5, G7) |
| fidget 0.5 | JIT implicit surfaces | MPL-2.0 | File-level copyleft; acceptable as a dependency, not for code copied into engines |
| boolmesh 0.2 | Robust mesh booleans, pure Rust | MPL-2.0 | Candidate for G5 booleans; check robustness on Thingi10K before adopting |
| csgrs 0.20 | BSP mesh CSG | MIT | Not robust on large meshes; reference only |
| manifold-rs, manifold3d | Manifold booleans | MIT OR Apache-2.0 | Wrap the C++ Manifold library: excluded by E-1 |
| meshopt 0.7; meshopt-rs 0.1 | Mesh optimisation | MIT OR Apache-2.0; MIT | meshopt links C++ (excluded); meshopt-rs is a pure Rust port (young) |
| truck-modeling 0.6, truck-stepio, ruststep | B-rep and STEP | Apache-2.0 | Only if B-rep output is reopened (E-10) |
| fj (Fornjot) 0.49 | Early B-rep kernel | 0BSD | Same |
| curvo 0.3 | NURBS | MIT | Same |
| threemf 0.8, stl_io 0.11, tobj 4 | 3MF, STL, OBJ IO | 0BSD; MIT; MIT | 3MF with materials for G9 |
| vdb-rs 0.6 | Read OpenVDB files | MIT | Interop with PicoGK and nTop style volumes |
| fenris 0.0.33 | FEM library | MIT OR Apache-2.0 | Reference for higher-order elements; not needed for voxels |
| topopt 0.1 | 99-line port | MIT | Toy, reference only |
| opencascade 0.3 | OCCT wrapper | LGPL-2.1 | C++ and LGPL: excluded |

Gaps in the ecosystem that ViaForm will have to fill itself: a robust, fast, pure Rust mesh boolean
proven on large meshes (boolmesh is the only candidate), isotropic remeshing, QEM decimation in pure
Rust with feature locks, and a GPU geometric multigrid (none exists as a crate).

---

## 9. Ranked roadmap

Each item maps to a spec work item where one fits; new ids start at G11. Acceptance benchmarks name a
reference problem with a published number. "Published" values are the paper's own; ViaForm's numbers
from docs/generative/ENGINE.md are labelled as such.

| Rank | Item | Products | Acceptance benchmark |
|---|---|---|---|
| 1 | **G2a Additive rules**: overhang at any angle (generalised AM filter [70] or front propagation [71, 72]), enclosed-void flood fill with fill or escape hole [75], build direction sweep as variants [73], overhang map on the mesh | Arm parts, hand, enclosures | top3d cantilever 60 x 20 x 4, vf 0.3, rmin 1.5 (published C = 2417.54 [5]): at 30, 45 and 60 degrees along +x and +z, zero unsupported voxels outside bores in the as-built part, zero enclosed voids, and the compliance penalty versus the free ViaForm run (ENGINE.md: 1727.8) reported. Flood-fill sensitivities pass central finite differences like every other filter |
| 2 | **G2b Subtractive and plate rules**: several milling directions with tool radius [76, 77]; carbon plate thickness from a list, min slot and min bridge from a 2D robust filter, DXF out | Carbon frames, aluminium arm links | Same cantilever with 3-axis milling from plus and minus z: every surface face reachable from a listed direction, compliance penalty reported against the published 2417.54. Drone arm plate: measured min slot and bridge at or above the asked values, closed DXF polylines |
| 3 | **G4 GPU solver** (wgpu, fused gather-GEMM-scatter `K u` [33], GPU geometric multigrid [28, 30]); then a sparse narrow-band grid [29] | All, interactive variants | 1M voxel cantilever: compliance within 1 % and volume within 0.5 % of the CPU path, at least 4x faster on an M-series GPU (spec). Comparator: Träff et al. report 65.5M elements in about 2 h on one GPU [30]; Yang et al. 4.6 to 7.3x over CPU end to end [33]. Stretch: the 65.5M-element class problem on the M5 Max in under 2 h |
| 4 | **G10 Thermal**: steady conduction on the voxel grid [41], max temperature p-norm, then design-dependent convection [46, 47, 48] | Enclosures, ESC and motor mounts | LED heat sink in passive cooling as in Lazarov et al.: optimised design beats a lattice or pin-fin reference of equal volume by at least 20 % in thermal resistance in ViaForm's own model (published: more than 21 % measured [44]). Plus the spec AC: 5 W source under the limit with less mass than a plain block |
| 5 | **G5 Output quality**: isotropic remeshing [139], QEM decimation [138], plane snapping, self-intersection and min wall checks (parry3d), robust booleans [143, 144], narrow-band SDF as canonical output [142] | All | Every example study passes the checks; a 300k-triangle candidate cut by a simple CAD solid at interactive speed (published: robust booleans at interactive rates up to 200k triangles [144]); peak von Mises of the re-voxelised smoothed part no higher than the voxel part's (published: SDF plus RBF smoothing cut peak stress 18 % [142]); enclosed volume within 1 % of the analysed volume |
| 6 | **G11 Buckling constraint**: linearised buckling with a bound formulation over the lowest load factors, aggregated [104, 105], multilevel eigen solve [106] | Drone arms, robot link walls, carbon plates | Compressed column, 480 x 240 (2D slab): compliance-only design buckling factor about 0.75, buckling-constrained design at least 8 with at most 5 % more volume (published: 0.75 to 8.53 at about +4 % volume, compliance about 1.4 c* [105]) |
| 7 | **G3 Loads from simulation**: wrench histories to load cases, envelope by k-medoids; the practical ESL route for crash [108] | Drone crash, arm stall | Spec AC: drone crash regenerated from `sim` loads lowers peak stress in a re-run crash by at least 20 % against the hand-made load set |
| 8 | **G7 Lattice infill and graded TPMS**, then phasor de-homogenisation [87, 88] | Arm parts, enclosures (SLS, FDM) | Graded lattice bracket against a uniform lattice of the same mass: specific stiffness gain of at least 40 % (published range 40 to 50 % for optimisation-derived grading [91]); stiffness within 15 % of the homogenised prediction (spec) |
| 9 | **G8 Shape optimisation and local stress**: boundary polish by adjoint on the smoothed surface [141], augmented Lagrangian local stress option [99, 100] | Hand knuckles, arm brackets | Spec AC: L-bracket peak stress cut by at least 25 % at equal mass; L-bracket as in [97, 100] with no stress above the limit at the re-entrant corner |
| 10 | **G9 Multi-material**, DMO interpolation [93, 94]; 3MF with materials | Hand (TPU pads on PETG), enclosures | Spec AC: two-material cantilever beats both single materials at equal mass; PolyMat-style three-material cantilever reproduces the published layouts qualitatively [94] |
| 11 | **G15 Fatigue**: finite-life fatigue with rainflow and damage aggregation [103] | Drone arms | Damage of a drone arm under a recorded motor vibration spectrum within 5 % of an independent rainflow plus Miner calculation; design life met at the eroded design |
| 12 | **G16 Thermo-elastic and electro-thermal coupling** [61, 62] | Motor mounts, PCB spreaders | Bimetal strip (Timoshenko closed form curvature) within 2 %; RAMP-penalised thermal stress study converges without the SIMP thermal-load artefact described in [61] |
| 13 | **G17 ML assist** (burn): neural reparameterisation as an optimiser option [114, 117]; learned warm start for 2D plate studies [124] | Carbon frames | Warm start cuts MMA iterations by at least 30 % with final compliance within 1 % of a cold start (published reference: OAT under 1 s per 2D design [124]); neural reparameterisation win rate reported on a 20-problem subset styled after the 116-task suite of [114] |
| 14 | **G18 Thermo-fluid**: Brinkman Stokes plus convection-diffusion on the GPU voxel grid [49, 56], sparse narrow band [59] | Cold plates, ducted enclosures | Two-fluid exchanger in the shell-and-tube setting of Høghøj et al.: improvement over the reference at equal pressure drop reported against the published up to 113 % [56] |
| 15 | **G19 Study authoring agent**: prompt plus assembly to study JSON, validated by the engine [135] | All | 50 written prompts over the five products: at least 90 % produce a study that validates and runs first time (method after the CADPrompt benchmark of 200 prompts [132]) |

G6 (variants and Pareto front) stays as specified; it is cheap and multiplies the value of items 1 to 4.
G0 and G1 are done per ENGINE.md (1M voxels at 0.68 s per iteration unloaded, under the 1.2 s target).

---

## References

1. M. P. Bendsøe, N. Kikuchi. Generating optimal topologies in structural design using a homogenization method. Comput. Methods Appl. Mech. Eng. 71 (1988) 197-224. doi:10.1016/0045-7825(88)90086-2
2. O. Sigmund. A 99 line topology optimization code written in Matlab. Struct. Multidisc. Optim. 21 (2001) 120-127. doi:10.1007/s001580050176
3. E. Andreassen, A. Clausen, M. Schevenels, B. S. Lazarov, O. Sigmund. Efficient topology optimization in MATLAB using 88 lines of code. Struct. Multidisc. Optim. 43 (2011) 1-16. doi:10.1007/s00158-010-0594-7
4. F. Ferrari, O. Sigmund. A new generation 99 line Matlab code for compliance topology optimization and its extension to 3D. Struct. Multidisc. Optim. 62 (2020) 2211-2228. doi:10.1007/s00158-020-02629-w
5. K. Liu, A. Tovar. An efficient 3D topology optimization code written in Matlab. Struct. Multidisc. Optim. 50 (2014) 1175-1196. doi:10.1007/s00158-014-1107-x (cantilever printout C = 2417.5352 as reported in D. Y. Gao et al., arXiv:1712.02919, cited in ENGINE.md)
6. O. Sigmund, K. Maute. Topology optimization approaches: a comparative review. Struct. Multidisc. Optim. 48 (2013) 1031-1055. doi:10.1007/s00158-013-0978-6
7. B. Bourdin. Filters in topology optimization. Int. J. Numer. Methods Eng. 50 (2001) 2143-2158. doi:10.1002/nme.116
8. T. E. Bruns, D. A. Tortorelli. Topology optimization of non-linear elastic structures and compliant mechanisms. Comput. Methods Appl. Mech. Eng. 190 (2001) 3443-3459. doi:10.1016/S0045-7825(00)00278-4
9. J. K. Guest, J. H. Prévost, T. Belytschko. Achieving minimum length scale in topology optimization using nodal design variables and projection functions. Int. J. Numer. Methods Eng. 61 (2004) 238-254. doi:10.1002/nme.1064
10. F. Wang, B. S. Lazarov, O. Sigmund. On projection methods, convergence and robust formulations in topology optimization. Struct. Multidisc. Optim. 43 (2011) 767-784. doi:10.1007/s00158-010-0602-y
11. B. S. Lazarov, O. Sigmund. Filters in topology optimization based on Helmholtz-type differential equations. Int. J. Numer. Methods Eng. 86 (2011) 765-781. doi:10.1002/nme.3072
12. K. Svanberg. The method of moving asymptotes: a new method for structural optimization. Int. J. Numer. Methods Eng. 24 (1987) 359-373. doi:10.1002/nme.1620240207
13. M. Y. Wang, X. Wang, D. Guo. A level set method for structural topology optimization. Comput. Methods Appl. Mech. Eng. 192 (2003) 227-246. doi:10.1016/S0045-7825(02)00559-5
14. G. Allaire, F. Jouve, A.-M. Toader. Structural optimization using sensitivity analysis and a level-set method. J. Comput. Phys. 194 (2004) 363-393. doi:10.1016/j.jcp.2003.09.032
15. N. P. van Dijk, K. Maute, M. Langelaar, F. van Keulen. Level-set methods for structural topology optimization: a review. Struct. Multidisc. Optim. 48 (2013) 437-472. doi:10.1007/s00158-013-0912-y
16. Y. Wang, Z. Kang. MATLAB implementations of velocity field level set method for topology optimization: an 80-line code for 2D and a 100-line code for 3D problems. Struct. Multidisc. Optim. 64 (2021) 4325-4342. doi:10.1007/s00158-021-02958-4
17. A. Takezawa, S. Nishiwaki, M. Kitamura. Shape and topology optimization based on the phase field method and sensitivity analysis. J. Comput. Phys. 229 (2010) 2697-2718. doi:10.1016/j.jcp.2009.12.017
18. X. Guo, W. Zhang, W. Zhong. Doing topology optimization explicitly and geometrically: a new moving morphable components based framework. J. Appl. Mech. 81 (2014) 081009. doi:10.1115/1.4027609
19. W. Zhang, J. Chen, X. Zhu, J. Zhou, D. Xue, X. Lei, X. Guo. Explicit three dimensional topology optimization via Moving Morphable Void (MMV) approach. Comput. Methods Appl. Mech. Eng. 322 (2017) 590-614. doi:10.1016/j.cma.2017.05.002
20. Z. Du, T. Cui, C. Liu, W. Zhang, Y. Guo, X. Guo. An efficient and easy-to-extend Matlab code of the Moving Morphable Component (MMC) method for three-dimensional topology optimization. Struct. Multidisc. Optim. 65 (2022) 158. doi:10.1007/s00158-022-03239-4
21. J. A. Norato, B. K. Bell, D. A. Tortorelli. A geometry projection method for continuum-based topology optimization with discrete elements. Comput. Methods Appl. Mech. Eng. 293 (2015) 306-327. doi:10.1016/j.cma.2015.05.005
22. F. Wein, P. D. Dunning, J. A. Norato. A review on feature-mapping methods for structural optimization. Struct. Multidisc. Optim. 62 (2020) 1597-1638. doi:10.1007/s00158-020-02649-6
23. S. Coniglio, J. Morlier, C. Gogu, R. Amargier. Generalized geometry projection: a unified approach for geometric feature based topology optimization. Arch. Comput. Methods Eng. 27 (2020) 1573-1610. doi:10.1007/s11831-019-09362-8
24. N. Aage, E. Andreassen, B. S. Lazarov, O. Sigmund. Giga-voxel computational morphogenesis for structural design. Nature 550 (2017) 84-86. doi:10.1038/nature23911
25. M. Baandrup, O. Sigmund, H. Polk, N. Aage. Closing the gap towards super-long suspension bridges using computational morphogenesis. Nat. Commun. 11 (2020) 2735. doi:10.1038/s41467-020-16599-6
26. N. Aage, E. Andreassen, B. S. Lazarov. Topology optimization using PETSc: an easy-to-use, fully parallel, open source topology optimization framework. Struct. Multidisc. Optim. 51 (2015) 565-572. doi:10.1007/s00158-014-1157-0
27. O. Amir, N. Aage, B. S. Lazarov. On multigrid-CG for efficient topology optimization. Struct. Multidisc. Optim. 49 (2014) 815-829. doi:10.1007/s00158-013-1015-5
28. J. Wu, C. Dick, R. Westermann. A system for high-resolution topology optimization. IEEE Trans. Vis. Comput. Graph. 22 (2016) 1195-1208. doi:10.1109/TVCG.2015.2502588
29. H. Liu, Y. Hu, B. Zhu, W. Matusik, E. Sifakis. Narrow-band topology optimization on a sparsely populated grid. ACM Trans. Graph. 37(6) (2018). doi:10.1145/3272127.3275012
30. E. A. Träff, A. Rydahl, S. Karlsson, O. Sigmund, N. Aage. Simple and efficient GPU accelerated topology optimisation: codes and applications. Comput. Methods Appl. Mech. Eng. 410 (2023) 116043. doi:10.1016/j.cma.2023.116043
31. D. Herrero-Pérez, P. J. Martínez Castejón. Multi-GPU acceleration of large-scale density-based topology optimization. Adv. Eng. Softw. 157-158 (2021) 103006. doi:10.1016/j.advengsoft.2021.103006
32. S. Schmidt, V. Schulz. A 2589 line topology optimization code written for the graphics card. Comput. Vis. Sci. 14 (2011) 249-256. doi:10.1007/s00791-012-0180-1
33. S. Yang, J. Wang, Y. Wang. Matrix-free 3D SIMP topology optimization with fused gather-GEMM-scatter kernels. arXiv:2604.18020 (2026)
34. M. Yang, Q. Yu, C. Yang. PeTTO: leveraging GPUs to accelerate topology optimization with the pseudo-transient methods. arXiv:2509.06971 (2025)
35. H. Liu, Y. Tian, H. Zong, Q. Ma, M. Y. Wang, L. Zhang. Fully parallel level set method for large-scale structural topology optimization. Comput. Struct. 221 (2019) 13-27. doi:10.1016/j.compstruc.2019.05.010
36. T. H. Nguyen, G. H. Paulino, J. Song, C. H. Le. A computational paradigm for multiresolution topology optimization (MTOP). Struct. Multidisc. Optim. 41 (2010) 525-539. doi:10.1007/s00158-009-0443-8
37. M. A. Salazar de Troya, D. A. Tortorelli. Adaptive mesh refinement in stress-constrained topology optimization. Struct. Multidisc. Optim. 58 (2018) 2369-2386. doi:10.1007/s00158-018-2084-2
38. C. Talischi, G. H. Paulino, A. Pereira, I. F. M. Menezes. PolyTop: a Matlab implementation of a general topology optimization framework using unstructured polygonal finite element meshes. Struct. Multidisc. Optim. 45 (2012) 329-357. doi:10.1007/s00158-011-0696-x
39. T. Xue, S. Liao, Z. Gan, C. Park, X. Xie, W. K. Liu, J. Cao. JAX-FEM: a differentiable GPU-accelerated 3D finite element solver for automatic inverse design and mechanistic data science. Comput. Phys. Commun. 291 (2023) 108802. doi:10.1016/j.cpc.2023.108802
40. Y. Jia, C. Wang, X. S. Zhang. FEniTop: a simple FEniCSx implementation for 2D and 3D topology optimization supporting parallel computing. Struct. Multidisc. Optim. 67 (2024) 140. doi:10.1007/s00158-024-03818-7
41. A. Gersborg-Hansen, M. P. Bendsøe, O. Sigmund. Topology optimization of heat conduction problems using the finite volume method. Struct. Multidisc. Optim. 31 (2006) 251-259. doi:10.1007/s00158-005-0584-3
42. J. Alexandersen, N. Aage, C. S. Andreasen, O. Sigmund. Topology optimisation for natural convection problems. Int. J. Numer. Methods Fluids 76 (2014) 699-721. doi:10.1002/fld.3954
43. J. Alexandersen, O. Sigmund, N. Aage. Large scale three-dimensional topology optimisation of heat sinks cooled by natural convection. Int. J. Heat Mass Transf. 100 (2016) 876-891. doi:10.1016/j.ijheatmasstransfer.2016.05.013
44. B. S. Lazarov, O. Sigmund, K. E. Meyer, J. Alexandersen. Experimental validation of additively manufactured optimized shapes for passive cooling. Appl. Energy 226 (2018) 330-339. doi:10.1016/j.apenergy.2018.05.106
45. N. Pollini, O. Sigmund, C. S. Andreasen, J. Alexandersen. A "poor man's" approach for high-resolution three-dimensional topology design for natural convection problems. Adv. Eng. Softw. 140 (2020) 102736. doi:10.1016/j.advengsoft.2019.102736
46. P. Coffin, K. Maute. Level set topology optimization of cooling and heating devices using a simplified convection model. Struct. Multidisc. Optim. 53 (2016) 985-1003. doi:10.1007/s00158-015-1343-8
47. M. Zhou, J. Alexandersen, O. Sigmund, C. B. W. Pedersen. Industrial application of topology optimization for combined conductive and convective heat transfer problems. Struct. Multidisc. Optim. 54 (2016) 1045-1060. doi:10.1007/s00158-016-1433-2
48. Y. Joo, I. Lee, S. J. Kim. Topology optimization of heat sinks in natural convection considering the effect of shape-dependent heat transfer coefficient. Int. J. Heat Mass Transf. 109 (2017) 123-133. doi:10.1016/j.ijheatmasstransfer.2017.01.099
49. T. Borrvall, J. Petersson. Topology optimization of fluids in Stokes flow. Int. J. Numer. Methods Fluids 41 (2003) 77-107. doi:10.1002/fld.426
50. L. H. Olesen, F. Okkels, H. Bruus. A high-level programming-language implementation of topology optimization applied to steady-state Navier-Stokes flow. Int. J. Numer. Methods Eng. 65 (2006) 975-1001. doi:10.1002/nme.1468
51. G. Pingen, A. Evgrafov, K. Maute. Topology optimization of flow domains using the lattice Boltzmann method. Struct. Multidisc. Optim. 34 (2007) 507-524. doi:10.1007/s00158-007-0105-7
52. F. Dugast, Y. Favennec, C. Josset, Y. Fan, L. Luo. Topology optimization of thermal fluid flows with an adjoint lattice Boltzmann method. J. Comput. Phys. 365 (2018) 376-404. doi:10.1016/j.jcp.2018.03.040
53. C. B. Dilgen, S. B. Dilgen, D. R. Fuhrman, O. Sigmund, B. S. Lazarov. Topology optimization of turbulent flows. Comput. Methods Appl. Mech. Eng. 331 (2018) 363-393. doi:10.1016/j.cma.2017.11.029
54. S. B. Dilgen, C. B. Dilgen, D. R. Fuhrman, O. Sigmund, B. S. Lazarov. Density based topology optimization of turbulent flow heat transfer systems. Struct. Multidisc. Optim. 57 (2018) 1905-1918. doi:10.1007/s00158-018-1967-6
55. J. Alexandersen, C. S. Andreasen. A review of topology optimisation for fluid-based problems. Fluids 5 (2020) 29. doi:10.3390/fluids5010029
56. L. C. Høghøj, D. R. Nørhave, J. Alexandersen, O. Sigmund, C. S. Andreasen. Topology optimization of two fluid heat exchangers. Int. J. Heat Mass Transf. 163 (2020) 120543. doi:10.1016/j.ijheatmasstransfer.2020.120543
57. F. Feppon, G. Allaire, C. Dapogny, P. Jolivet. Body-fitted topology optimization of 2D and 3D fluid-to-fluid heat exchangers. Comput. Methods Appl. Mech. Eng. 376 (2021) 113638. doi:10.1016/j.cma.2020.113638
58. Y. Li, T. Du, S. Grama Srinivasan, K. Wu, B. Zhu, E. Sifakis, W. Matusik. Fluidic topology optimization with an anisotropic mixture model. ACM Trans. Graph. 41(6) (2022) 239. doi:10.1145/3550454.3555429
59. V. Pimanov, A. T. R. Guibert, J.-P. Sabino, M. Stoia, H. A. Kim. Sparse narrow-band topology optimization for large-scale thermal-fluid applications. arXiv:2508.04261 (2025)
60. S. Sun, B. Rankouhi, D. J. Thoma, M. Cheadle, B. Maples, M. Anderson, G. Nellis, X. Qian. Topology optimization, additive manufacturing and thermohydraulic testing of heat sinks. Int. J. Heat Mass Transf. 224 (2024) 125281. doi:10.1016/j.ijheatmasstransfer.2024.125281
61. T. Gao, W. Zhang. Topology optimization involving thermo-elastic stress loads. Struct. Multidisc. Optim. 42 (2010) 725-738. doi:10.1007/s00158-010-0527-5
62. O. Sigmund. Design of multiphysics actuators using topology optimization, Part I: one-material structures. Comput. Methods Appl. Mech. Eng. 190 (2001) 6577-6604. doi:10.1016/S0045-7825(01)00251-1
63. O. Sigmund. On the design of compliant mechanisms using topology optimization. Mech. Struct. Mach. 25 (1997) 493-524. doi:10.1080/08905459708945415
64. B. Zhu, X. Zhang, H. Zhang, J. Liang, H. Zang, H. Li, R. Wang. Design of compliant mechanisms using continuum topology optimization: a review. Mech. Mach. Theory 143 (2020) 103622. doi:10.1016/j.mechmachtheory.2019.103622
65. T. Buhl, C. B. W. Pedersen, O. Sigmund. Stiffness design of geometrically nonlinear structures using topology optimization. Struct. Multidisc. Optim. 19 (2000) 93-104. doi:10.1007/s001580050089
66. F. Wang, B. S. Lazarov, O. Sigmund, J. S. Jensen. Interpolation scheme for fictitious domain techniques and topology optimization of finite strain elastic problems. Comput. Methods Appl. Mech. Eng. 276 (2014) 453-472. doi:10.1016/j.cma.2014.03.021
67. J. Liu, A. T. Gaynor, S. Chen, Z. Kang, K. Suresh, A. Takezawa, L. Li, J. Kato, J. Tang, C. C. L. Wang, L. Cheng, X. Liang, A. C. To. Current and future trends in topology optimization for additive manufacturing. Struct. Multidisc. Optim. 57 (2018) 2457-2483. doi:10.1007/s00158-018-1994-3
68. A. T. Gaynor, J. K. Guest. Topology optimization considering overhang constraints: eliminating sacrificial support material in additive manufacturing through design. Struct. Multidisc. Optim. 54 (2016) 1157-1172. doi:10.1007/s00158-016-1551-x
69. M. Langelaar. Topology optimization of 3D self-supporting structures for additive manufacturing. Addit. Manuf. 12 (2016) 60-70. doi:10.1016/j.addma.2016.06.010
70. M. Langelaar. An additive manufacturing filter for topology optimization of print-ready designs. Struct. Multidisc. Optim. 55 (2017) 871-883. doi:10.1007/s00158-016-1522-2
71. E. van de Ven, R. Maas, C. Ayas, M. Langelaar, F. van Keulen. Continuous front propagation-based overhang control for topology optimization with additive manufacturing. Struct. Multidisc. Optim. 57 (2018) 2075-2091. doi:10.1007/s00158-017-1880-4
72. E. van de Ven, R. Maas, C. Ayas, M. Langelaar, F. van Keulen. Overhang control in topology optimization: a comparison of continuous front propagation-based and discrete layer-by-layer overhang control. Struct. Multidisc. Optim. 64 (2021) 761-778. doi:10.1007/s00158-021-02887-2
73. C. Wang, X. Qian. Simultaneous optimization of build orientation and topology for additive manufacturing. Addit. Manuf. 34 (2020) 101246. doi:10.1016/j.addma.2020.101246
74. S. Liu, Q. Li, W. Chen, L. Tong, G. Cheng. An identification method for enclosed voids restriction in manufacturability design for additive manufacturing structures. Front. Mech. Eng. 10 (2015) 126-137. doi:10.1007/s11465-015-0340-3
75. J. van der Zwet, A. Delissen, M. Langelaar. Prevention of enclosed voids in topology optimization using a cumulative sum flood fill algorithm. Adv. Eng. Softw. 186 (2023) 103530. doi:10.1016/j.advengsoft.2023.103530
76. M. Langelaar. Topology optimization for multi-axis machining. Comput. Methods Appl. Mech. Eng. 351 (2019) 226-252. doi:10.1016/j.cma.2019.03.037
77. A. M. Mirzendehdel, M. Behandish, S. Nelaturi. Topology optimization with accessibility constraint for multi-axis machining. Comput.-Aided Des. 122 (2020) 102825. doi:10.1016/j.cad.2020.102825
78. A. R. Gersborg, C. S. Andreasen. An explicit parameterization for casting constraints in gradient driven topology optimization. Struct. Multidisc. Optim. 44 (2011) 875-881. doi:10.1007/s00158-011-0632-0
79. M. Zhou, B. S. Lazarov, F. Wang, O. Sigmund. Minimum length scale in topology optimization by geometric constraints. Comput. Methods Appl. Mech. Eng. 293 (2015) 266-282. doi:10.1016/j.cma.2015.05.003
80. R. Arrieta, G. Romano, S. G. Johnson. Hyperparameter-free minimum-lengthscale constraints for topology optimization. arXiv:2507.16108 (2025); journal reference given on arXiv: Struct. Multidisc. Optim. 69(9) (2026) 210
81. O. Sigmund. Manufacturing tolerant topology optimization. Acta Mech. Sin. 25 (2009) 227-239. doi:10.1007/s10409-009-0240-z
82. M. Schevenels, B. S. Lazarov, O. Sigmund. Robust topology optimization accounting for spatially varying manufacturing errors. Comput. Methods Appl. Mech. Eng. 200 (2011) 3613-3627. doi:10.1016/j.cma.2011.08.006
83. O. Pantz, K. Trabelsi. A post-treatment of the homogenization method for shape optimization. SIAM J. Control Optim. 47 (2008) 1380-1398. doi:10.1137/070688900
84. J. P. Groen, O. Sigmund. Homogenization-based topology optimization for high-resolution manufacturable microstructures. Int. J. Numer. Methods Eng. 113 (2018) 1148-1163. doi:10.1002/nme.5575
85. G. Allaire, P. Geoffroy-Donders, O. Pantz. Topology optimization of modulated and oriented periodic microstructures by the homogenization method. Comput. Math. Appl. 78 (2019) 2197-2229. doi:10.1016/j.camwa.2018.08.007
86. F. C. Stutz, J. P. Groen, O. Sigmund, J. A. Bærentzen. Singularity aware de-homogenization for high-resolution topology optimized structures. Struct. Multidisc. Optim. 62 (2020) 2279-2295. doi:10.1007/s00158-020-02681-6
87. R. V. Woldseth, J. A. Bærentzen, O. Sigmund. Phasor noise for dehomogenisation in 2D multiscale topology optimisation. Comput. Methods Appl. Mech. Eng. 418 (2024) 116551. doi:10.1016/j.cma.2023.116551
88. R. V. Woldseth, O. Sigmund, P. D. L. Jensen. An 808 line phasor-based dehomogenisation Matlab code for multi-scale topology optimisation. Struct. Multidisc. Optim. 67 (2024) 205. doi:10.1007/s00158-024-03880-1
89. J. Wu, O. Sigmund, J. P. Groen. Topology optimization of multi-scale structures: a review. Struct. Multidisc. Optim. 63 (2021) 1455-1480. doi:10.1007/s00158-021-02881-8
90. J. Wu, N. Aage, R. Westermann, O. Sigmund. Infill optimization for additive manufacturing: approaching bone-like porous structures. IEEE Trans. Vis. Comput. Graph. 24 (2018) 1127-1140. doi:10.1109/TVCG.2017.2655523
91. A. Panesar, M. Abdi, D. Hickman, I. Ashcroft. Strategies for functionally graded lattice structures derived using topology optimisation for additive manufacturing. Addit. Manuf. 19 (2018) 81-94. doi:10.1016/j.addma.2017.11.008
92. O. Al-Ketan, R. K. Abu Al-Rub. Multifunctional mechanical metamaterials based on triply periodic minimal surface lattices. Adv. Eng. Mater. 21 (2019) 1900524. doi:10.1002/adem.201900524
93. J. Stegmann, E. Lund. Discrete material optimization of general composite shell structures. Int. J. Numer. Methods Eng. 62 (2005) 2009-2027. doi:10.1002/nme.1259
94. E. D. Sanders, A. Pereira, M. A. Aguiló, G. H. Paulino. PolyMat: an efficient Matlab code for multi-material topology optimization. Struct. Multidisc. Optim. 58 (2018) 2727-2759. doi:10.1007/s00158-018-2094-0
95. X. Sun, G. Roeder, T. Xue, R. P. Adams, S. Rusinkiewicz. More stiffness with less fiber: end-to-end fiber path optimization for 3D-printed composites. Proc. 8th ACM Symposium on Computational Fabrication (SCF 2023). doi:10.1145/3623263.3623356 (arXiv:2205.16008)
96. N. Boddeti, Y. Tang, K. Maute, D. W. Rosen, M. L. Dunn. Optimal design and manufacture of variable stiffness laminated continuous fiber reinforced composites. Sci. Rep. 10 (2020) 16507. doi:10.1038/s41598-020-73333-4
97. C. Le, J. Norato, T. Bruns, C. Ha, D. Tortorelli. Stress-based topology optimization for continua. Struct. Multidisc. Optim. 41 (2010) 605-620. doi:10.1007/s00158-009-0440-y
98. E. Holmberg, B. Torstenfelt, A. Klarbring. Stress constrained topology optimization. Struct. Multidisc. Optim. 48 (2013) 33-47. doi:10.1007/s00158-012-0880-7
99. F. V. Senhora, O. Giraldo-Londoño, I. F. M. Menezes, G. H. Paulino. Topology optimization with local stress constraints: a stress aggregation-free approach. Struct. Multidisc. Optim. 62 (2020) 1639-1668. doi:10.1007/s00158-020-02573-9
100. O. Giraldo-Londoño, G. H. Paulino. PolyStress: a Matlab implementation for local stress-constrained topology optimization using the augmented Lagrangian method. Struct. Multidisc. Optim. 63 (2021) 2065-2097. doi:10.1007/s00158-020-02760-8
101. G. A. da Silva, A. T. Beck, O. Sigmund. Stress-constrained topology optimization considering uniform manufacturing uncertainties. Comput. Methods Appl. Mech. Eng. 344 (2019) 512-537. doi:10.1016/j.cma.2018.10.020
102. E. Holmberg, B. Torstenfelt, A. Klarbring. Fatigue constrained topology optimization. Struct. Multidisc. Optim. 50 (2014) 207-219. doi:10.1007/s00158-014-1054-6
103. J. Oest, E. Lund. Topology optimization with finite-life fatigue constraints. Struct. Multidisc. Optim. 56 (2017) 1045-1059. doi:10.1007/s00158-017-1701-9
104. F. Ferrari, O. Sigmund. Revisiting topology optimization with buckling constraints. Struct. Multidisc. Optim. 59 (2019) 1401-1415. doi:10.1007/s00158-019-02253-3
105. F. Ferrari, O. Sigmund, J. K. Guest. Topology optimization with linearized buckling criteria in 250 lines of Matlab. Struct. Multidisc. Optim. 63 (2021) 3045-3066. doi:10.1007/s00158-021-02854-x
106. F. Ferrari, O. Sigmund. Towards solving large-scale topology optimization problems with buckling constraints at the cost of linear analyses. Comput. Methods Appl. Mech. Eng. 363 (2020) 112911. doi:10.1016/j.cma.2020.112911
107. J. Du, N. Olhoff. Topological design of freely vibrating continuum structures for maximum values of simple and multiple eigenfrequencies and frequency gaps. Struct. Multidisc. Optim. 34 (2007) 91-110. doi:10.1007/s00158-007-0101-y
108. G. J. Park. Technical overview of the equivalent static loads method for non-linear static response structural optimization. Struct. Multidisc. Optim. 43 (2011) 319-337. doi:10.1007/s00158-010-0530-x
109. N. M. Patel, B.-S. Kang, J. E. Renaud, A. Tovar. Crashworthiness design using topology optimization. J. Mech. Des. 131 (2009) 061013. doi:10.1115/1.3116256
110. O. Sigmund. On the usefulness of non-gradient approaches in topology optimization. Struct. Multidisc. Optim. 43 (2011) 589-596. doi:10.1007/s00158-011-0638-7
111. R. V. Woldseth, N. Aage, J. A. Bærentzen, O. Sigmund. On the use of artificial neural networks in topology optimisation. Struct. Multidisc. Optim. 65 (2022) 294. doi:10.1007/s00158-022-03347-1
112. S. Shin, D. Shin, N. Kang. Topology optimization via machine learning and deep learning: a review. J. Comput. Des. Eng. 10 (2023) 1736-1766. doi:10.1093/jcde/qwad072
113. L. Regenwetter, A. H. Nobari, F. Ahmed. Deep generative models in engineering design: a review. J. Mech. Des. 144 (2022) 071704. doi:10.1115/1.4053859
114. S. Hoyer, J. Sohl-Dickstein, S. Greydanus. Neural reparameterization improves structural optimization. arXiv:1909.04240 (2019), NeurIPS 2019 workshop on solving inverse problems with deep networks
115. A. Chandrasekhar, K. Suresh. TOuNN: topology optimization using neural networks. Struct. Multidisc. Optim. 63 (2021) 1135-1149. doi:10.1007/s00158-020-02748-4
116. J. Zehnder, Y. Li, S. Coros, B. Thomaszewski. NTopo: mesh-free topology optimization using implicit neural representations. NeurIPS 34 (2021). arXiv:2102.10782
117. L. Herrmann, O. Sigmund, V. M. Li, C. Vogl, S. Kollmannsberger. On neural networks for generating better local optima in topology optimization. Struct. Multidisc. Optim. 67 (2024) 192. doi:10.1007/s00158-024-03908-6
118. I. Sosnovik, I. Oseledets. Neural networks for topology optimization. Russ. J. Numer. Anal. Math. Model. 34 (2019) 215-223. doi:10.1515/rnam-2019-0018
119. Y. Yu, T. Hur, J. Jung, I. G. Jang. Deep learning for determining a near-optimal topological design without any iteration. Struct. Multidisc. Optim. 59 (2019) 787-799. doi:10.1007/s00158-018-2101-5
120. Z. Nie, T. Lin, H. Jiang, L. B. Kara. TopologyGAN: topology optimization using generative adversarial networks based on physical fields over the initial domain. J. Mech. Des. 143 (2021) 031715. doi:10.1115/1.4049533
121. F. Mazé, F. Ahmed. Diffusion models beat GANs on topology optimization. Proc. AAAI Conf. Artif. Intell. 37 (2023) 9108-9116. doi:10.1609/aaai.v37i8.26093
122. G. Giannone, A. Srivastava, O. Winther, F. Ahmed. Aligning optimization trajectories with diffusion models for constrained design generation. NeurIPS 2023. arXiv:2305.18470
123. A. H. Nobari, G. Giannone, L. Regenwetter, F. Ahmed. NITO: neural implicit fields for resolution-free topology optimization. arXiv:2402.05073 (2024); journal version in Transactions on Machine Learning Research (2025)
124. A. H. Nobari, L. Regenwetter, C. Picard, L. Han, F. Ahmed. Optimize any topology: a foundation model for shape- and resolution-free structural topology optimization. NeurIPS 2025. arXiv:2510.23667
125. R. Wu, C. Xiao, C. Zheng. DeepCAD: a deep generative network for computer-aided design models. ICCV 2021, 6772-6782. arXiv:2105.09492
126. X. Xu, K. D. D. Willis, J. G. Lambourne, C.-Y. Cheng, P. K. Jayaraman, Y. Furukawa. SkexGen: autoregressive generation of CAD construction sequences with disentangled codebooks. ICML 2022, PMLR 162, 24698-24724. arXiv:2207.04632
127. K. D. D. Willis, Y. Pu, J. Luo, H. Chu, T. Du, J. G. Lambourne, A. Solar-Lezama, W. Matusik. Fusion 360 Gallery: a dataset and environment for programmatic CAD construction from human design sequences. ACM Trans. Graph. 40(4) (2021). doi:10.1145/3450626.3459818
128. X. Xu, J. G. Lambourne, P. K. Jayaraman, Z. Wang, K. D. D. Willis, Y. Furukawa. BrepGen: a B-rep generative diffusion model with structured latent geometry. ACM Trans. Graph. 43(4) (2024). doi:10.1145/3658129
129. X. Xu, P. K. Jayaraman, J. G. Lambourne, et al. AutoBrep: autoregressive B-rep generation with unified topology and geometry. SIGGRAPH Asia 2025 Conference Papers. doi:10.1145/3757377.3763814
130. M. S. Khan, S. Sinha, T. Uddin, D. Stricker, S. A. Ali, M. Z. Afzal. Text2CAD: generating sequential CAD designs from beginner-to-expert level text prompts. NeurIPS 37 (2024). arXiv:2409.17106
131. D. Rukhovich, E. Dupont, D. Mallis, K. Cherenkova, A. Kacem, D. Aouada. CAD-Recode: reverse engineering CAD code from point clouds. ICCV 2025. arXiv:2412.14042
132. K. Alrashedy et al. Generating CAD code with vision-language models for 3D designs. ICLR 2025. arXiv:2410.05340
133. L. Makatura et al. How can large language models help humans in design and manufacturing? arXiv:2307.14377 (2023)
134. Y. Jadhav, A. Barati Farimani. Large language model agent as a mechanical designer. arXiv:2404.17525 (2024)
135. H. Park, H. Chung. Self-refining topology optimization via an LLM-based multi-agent framework. arXiv:2605.23273 (2026)
136. W. E. Lorensen, H. E. Cline. Marching cubes: a high resolution 3D surface construction algorithm. ACM SIGGRAPH Comput. Graph. 21(4) (1987) 163-169. doi:10.1145/37402.37422
137. T. Ju, F. Losasso, S. Schaefer, J. Warren. Dual contouring of Hermite data. ACM Trans. Graph. 21(3) (2002) 339-346. doi:10.1145/566654.566586
138. M. Garland, P. S. Heckbert. Surface simplification using quadric error metrics. SIGGRAPH 1997, 209-216. doi:10.1145/258734.258849
139. M. Botsch, L. Kobbelt. A remeshing approach to multiresolution modeling. Eurographics Symposium on Geometry Processing 2004, 189-196. doi:10.2312/SGP/SGP04/189-196
140. S. C. Subedi, C. S. Verma, K. Suresh. A review of methods for the geometric post-processing of topology optimized models. J. Comput. Inf. Sci. Eng. 20 (2020) 060801. doi:10.1115/1.4047429
141. M. K. Swierstra, D. K. Gupta, M. Langelaar. Automated and accurate geometry extraction and shape optimization of 3D topology optimization results. arXiv:2004.05448 (2020)
142. O. Ježek, J. Kopačka, M. Isoz, D. Gabriel, P. Maršálek, M. Šotola, R. Halama. Smooth geometry extraction from SIMP topology optimization: signed distance function approach with volume preservation. arXiv:2512.06976 (2025)
143. Q. Zhou, E. Grinspun, D. Zorin, A. Jacobson. Mesh arrangements for solid geometry. ACM Trans. Graph. 35(4) (2016). doi:10.1145/2897824.2925901
144. G. Cherchi, F. Pellacini, M. Attene, M. Livesu. Interactive and robust mesh booleans. ACM Trans. Graph. 41(6) (2022). doi:10.1145/3550454.3555460
145. Y. Liu, A. Obukhov, J. D. Wegner, K. Schindler. Point2CAD: reverse engineering CAD models from 3D point clouds. CVPR 2024, 3763-3772. arXiv:2312.04962
146. Autodesk. Manufacturing methods in the Generative Design workspace (Fusion help). https://help.autodesk.com/cloudhelp/ENU/Fusion-GenerativeDesign/files/GD-MFG-METHODS.htm (accessed 2026-11-22)
147. nTop. Solutions page and webinar "End-to-end high efficiency heat exchanger design with integrated CFD" (2026). https://www.ntop.com/solutions/ ; https://www.ntop.com/resources/webinars/end-to-end-high-efficiency-heat-exchanger-design-with-integrated-cfd/ (accessed 2026-11-22)
148. Altair. Inspire help: overhang shape controls. https://help.altair.com/inspire/en_us/topics/inspire/structure/draw_overhang_c.htm ; Inspire product page (PolyNURBS fit). https://altair.com/Inspire (accessed 2026-11-22)
149. Altair. OptiStruct help: lattice structure optimization (2025). https://2025.help.altair.com/2025/hwsolvers/altair_help/topics/solvers/os/lattice_structure_optimization_intro_r.htm ; SimLab fatigue optimization. https://altair.com/resource/altair-simlab-fatigue-optimization (accessed 2026-11-22)
150. Siemens. Topology optimization (technology page). https://www.siemens.com/fi-fi/technology/topology-optimization/ (accessed 2026-11-22)
151. Ansys. Discovery capabilities, https://www.ansys.com/products/3d-design/ansys-discovery/capabilities ; Mechanical help 2024 R2, Topology Optimization, Level Set Based, https://ansyshelp.ansys.com/public/Views/Secured/corp/v242/en/mech_struct_opt/ds_topo_opt_level_set.html ; Design exploration via topology optimization (2023), https://www.ansys.com/content/dam/amp/2023/october/quick-request/design-exploration-via-topology-optimization-et.pdf (accessed 2026-11-22)
152. ToffeeX. ToffeeX Discovery plug-in, https://developer.ansys.com/app/toffeex/toffeex-discovery-plug/1-06 ; Metal AM, "ToffeeX software improves Nissan oil cooler performance", https://www.metal-am.com/toffeex-software-improves-nissan-oil-cooler-performance/ (vendor-reported figures; accessed 2026-11-22)
153. LEAP 71. PicoGK geometry kernel, Apache-2.0. https://github.com/leap71/PicoGK (accessed 2026-11-22)
154. crates.io registry entries for every crate in section 8, https://crates.io/crates/<name> (licences and versions read 2026-11-22)
