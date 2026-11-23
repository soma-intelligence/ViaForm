//! Generative design in 3D, and in time.
//!
//! A [`Study`] is a box of space in the design (world millimetres) cut into cubic voxels, each an
//! eight-node hexahedral element. Supports hold regions of it, load cases push on regions (forces,
//! torques, accelerations), keep-out regions stay empty and keep-in regions stay solid. The
//! optimiser ([`optimize`]) finds the material layout that meets the objective under the limits:
//! stiffness for a mass, or least mass for a stress, a displacement and a first natural frequency.
//! The time axis ([`dynamics`]) adds natural frequencies and modes, and impacts integrated step by
//! step, so a part is checked against how it rings and how it is hit, not only how it is pushed.
//! The result is a smooth, closed triangle mesh ([`iso`]) with the stress on every vertex,
//! written as 3MF, STL or OBJ ([`export`]) and inserted into the design as a mesh body.
//!
//! [`Method::Frame`] instead sizes a space frame of beams between lattice nodes ([`frame3d`]).
//!
//! Units: mm, N, N·mm, MPa (N/mm²), g/mm³, s. Element `e` at voxel `(i, j, k)` is
//! `i + nx * (j + ny * k)`; node `(i, j, k)` is `i + (nx + 1) * (j + (ny + 1) * k)`; degree of
//! freedom `3 * node + axis`.

use serde::{Deserialize, Serialize};

use crate::spec::Material;

pub mod dynamics;
pub mod export;
pub mod fem;
pub mod frame3d;
pub mod grid;
pub mod iso;
pub mod loads;
pub mod mg;
pub mod mma;
pub mod optimize;
pub mod sim_loads;
pub mod thermal;

pub use grid::Grid;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    /// Density-based topology optimisation (SIMP with projection) on hexahedral voxels.
    #[default]
    Topology,
    /// A space frame: candidate beams between lattice nodes, sized for least mass.
    Frame,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Objective {
    /// Stiffest layout (least weighted compliance) for the volume fraction.
    #[default]
    Compliance,
    /// Lightest layout that keeps the stress, displacement and frequency limits.
    Mass,
}

/// A region of space, world millimetres.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "shape", rename_all = "snake_case")]
pub enum Region {
    Box { min: [f64; 3], max: [f64; 3] },
    /// A solid cylinder from `base` along `axis` (any length; normalised) for `length`.
    Cylinder { base: [f64; 3], axis: [f64; 3], radius: f64, length: f64 },
    Sphere { center: [f64; 3], radius: f64 },
    /// A tube (a bore's wall): between radii `inner` and `outer` about the axis from `base`.
    Tube { base: [f64; 3], axis: [f64; 3], inner: f64, outer: f64, length: f64 },
}

/// Where the voxels' material may go, beyond keep-in and keep-out.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(tag = "process", rename_all = "snake_case")]
pub enum Manufacturing {
    #[default]
    Free,
    /// Printed along `build`: no overhang flatter than `overhang` degrees from the build plate.
    Additive { build: [f64; 3], overhang: f64 },
    /// Constant section along `direction` (extruded, laser or water-jet cut, a carbon plate).
    Extrusion { direction: [f64; 3] },
    /// Reached by a tool along `direction`: no cavity hidden from it.
    Milling { direction: [f64; 3] },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Support {
    pub region: Region,
    /// Held axes: x, y, z.
    #[serde(default = "all_axes")]
    pub fix: [bool; 3],
}

fn all_axes() -> [bool; 3] {
    [true; 3]
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Load {
    /// A force spread evenly over the nodes in the region (the nearest node if none).
    Force { region: Region, force: [f64; 3] },
    /// A moment about `axis` through `center`, N·mm, applied as tangential forces on the nodes in
    /// the region (a shaft bore driven by a motor).
    Torque { region: Region, center: [f64; 3], axis: [f64; 3], moment: f64 },
    /// A pressure on the faces of the solid inside the region, along `direction`, MPa (applied on
    /// the region's nodes as force = pressure × projected area).
    Pressure { region: Region, direction: [f64; 3], pressure: f64 },
}

/// Loads applied together.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LoadCase {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub loads: Vec<Load>,
    /// Body acceleration, mm/s² (gravity is `[0, 0, -9810]`; a 50 g crash is 490 500): the
    /// material's own weight loads the part, so it follows the layout.
    #[serde(default)]
    pub acceleration: Option<[f64; 3]>,
    /// Share of this case in the compliance objective.
    #[serde(default = "one")]
    pub weight: f64,
}

fn one() -> f64 {
    1.0
}

/// The time axis.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Dynamics {
    /// Natural frequencies (and mode shapes) to compute, lowest first.
    pub modes: usize,
    /// Impacts: a load case applied as a half-sine pulse, integrated in time.
    pub impacts: Vec<Impact>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Impact {
    /// Index into the study's load cases: its loads are the pulse's peak.
    pub case: usize,
    /// Pulse length, s.
    pub duration: f64,
    /// Time integrated after the pulse starts, s (at least the duration).
    pub window: f64,
    /// Time steps over the window.
    #[serde(default = "steps")]
    pub steps: usize,
    /// Rayleigh damping ratio at the first mode.
    #[serde(default = "damping")]
    pub damping: f64,
}

fn steps() -> usize {
    200
}

fn damping() -> f64 {
    0.02
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Study {
    pub method: Method,
    pub objective: Objective,
    /// Name of the body (and component) the result builds.
    pub name: String,
    /// The design space, world mm.
    pub min: [f64; 3],
    pub max: [f64; 3],
    /// Voxel edge, mm.
    pub voxel: f64,
    pub material: Material,
    pub supports: Vec<Support>,
    pub cases: Vec<LoadCase>,
    pub keep_out: Vec<Region>,
    pub keep_in: Vec<Region>,
    /// Share of the design space the part may fill (compliance objective), or its cap (mass).
    pub volume_fraction: f64,
    /// Stress limit, MPa; default: the material's allowable over the safety factor.
    pub max_stress: Option<f64>,
    pub safety_factor: f64,
    /// Displacement limit at any node, mm.
    pub max_displacement: Option<f64>,
    /// Displacement limit at any node at an impact's peak (`dynamics.impacts`), mm; none: the
    /// static limit. The static limit can then be a tighter stand-in the optimiser steers by.
    pub max_impact_displacement: Option<f64>,
    /// First natural frequency floor, Hz.
    pub min_frequency: Option<f64>,
    /// Mirror planes through the design space's centre, normal to x, y and z.
    pub symmetry: [bool; 3],
    /// Narrowest member, mm (sets the filter radius: at least 1.5 voxels).
    pub min_member: f64,
    pub manufacturing: Manufacturing,
    pub iterations: usize,
    pub dynamics: Dynamics,
    /// Candidates: each varies the volume fraction (topology) or the seed (frame).
    pub variants: usize,
    pub seed: u64,
    /// Taubin smoothing passes on the result's surface.
    pub smoothing: usize,
    /// Robust formulation for manufacturing tolerance: the layout is optimised over its
    /// eroded, nominal and dilated projections (Wang, Lazarov and Sigmund 2011).
    pub robust: Option<Robust>,
    /// How many of the lowest modes the frequency floor holds (bound formulation over a
    /// cluster, so two modes that swap or coincide never slip under the floor). At least 1.
    pub frequency_modes: usize,
    /// Target part mass, g (keep-in material included): sets the volume fraction in place of
    /// `volume_fraction` (variants still spread around it).
    pub mass_target_g: Option<f64>,
    /// Final sharpness of the Heaviside projection (doubled from 1 over the run, capped here).
    /// 0 turns projection off: plain SIMP with a density filter, as top3d and the PETSc code run.
    pub max_beta: f64,
    /// Stop when no design variable moved more than this in an iteration (at full sharpness);
    /// 0 runs every iteration.
    pub tolerance: f64,
    /// Exact round holes (cylinders) cut into the surface after it is built: bearing seats,
    /// pin bores and screw clearances come out at their true diameter (voxels only approach it).
    /// Keep the same cylinders (or a little larger) out of the material.
    pub bores: Vec<Region>,
    /// Cylinder keep-outs are cut exactly too (holes, seats, clearances round a turning part).
    pub exact_keep_outs: bool,
    /// Separate solid bodies the result may have (each joined to a support); more fails the
    /// study. 1: a part is one piece.
    pub max_bodies: usize,
    /// Bought parts the structure carries, as masses on its nodes: they lower the natural
    /// frequencies and load the impacts (a motor on an arm pad), but add no stiffness. Body
    /// accelerations do not load them; give their inertia as forces in the load cases.
    pub point_masses: Vec<PointMass>,
    /// Steady heat conduction on the same voxels: sources, convection, fixed temperatures and
    /// a temperature limit ([`thermal`]). Runs through [`thermal::generate`].
    pub thermal: Option<thermal::Thermal>,
}

/// A mass spread evenly over the nodes of `region` (the nearest node if none), g.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PointMass {
    pub region: Region,
    pub mass_g: f64,
}

/// Eroded / nominal / dilated thresholds `0.5 + delta`, `0.5`, `0.5 - delta`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Robust {
    #[serde(default = "robust_delta")]
    pub delta: f64,
}

fn robust_delta() -> f64 {
    0.15
}

impl Default for Robust {
    fn default() -> Self {
        Self { delta: robust_delta() }
    }
}

impl Default for Study {
    fn default() -> Self {
        Self {
            method: Method::Topology,
            objective: Objective::Compliance,
            name: "Generated".into(),
            min: [0.0; 3],
            max: [60.0, 20.0, 20.0],
            voxel: 1.0,
            material: Material::default(),
            supports: Vec::new(),
            cases: Vec::new(),
            keep_out: Vec::new(),
            keep_in: Vec::new(),
            volume_fraction: 0.2,
            max_stress: None,
            safety_factor: 1.5,
            max_displacement: None,
            max_impact_displacement: None,
            min_frequency: None,
            symmetry: [false; 3],
            min_member: 2.0,
            manufacturing: Manufacturing::Free,
            iterations: 80,
            dynamics: Dynamics::default(),
            variants: 1,
            seed: 1,
            smoothing: 12,
            robust: None,
            frequency_modes: 3,
            mass_target_g: None,
            max_beta: 16.0,
            tolerance: 0.0,
            bores: Vec::new(),
            exact_keep_outs: true,
            max_bodies: 1,
            point_masses: Vec::new(),
            thermal: None,
        }
    }
}

/// A triangle mesh, world mm, outward-facing counter-clockwise triangles.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Mesh {
    /// xyz per vertex.
    pub positions: Vec<f32>,
    pub indices: Vec<u32>,
    /// Von Mises stress per vertex (worst load case), MPa; empty when not computed.
    pub stress: Vec<f32>,
}

/// One natural mode.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Mode {
    pub frequency: f64,
    /// Effective mass share per axis.
    pub participation: [f64; 3],
}

/// One impact, integrated.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ImpactResponse {
    pub case: usize,
    /// Sampled time, s.
    pub time: Vec<f64>,
    /// Worst von Mises over the solid at each sample, MPa.
    pub stress: Vec<f64>,
    /// Largest nodal displacement at each sample, mm.
    pub displacement: Vec<f64>,
    pub peak_stress: f64,
    pub peak_displacement: f64,
    /// Peak dynamic stress over the static stress of the same case.
    pub amplification: f64,
}

/// What the analysis says about one layout, per load case and over time.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Analysis {
    /// Per case: weighted compliance, N·mm.
    pub compliance: Vec<f64>,
    /// Per case: worst von Mises over solid voxels, MPa.
    pub max_stress: Vec<f64>,
    /// Per case: largest nodal displacement, mm.
    pub max_displacement: Vec<f64>,
    /// Allowable over the worst static or dynamic stress.
    pub safety_factor: f64,
    pub modes: Vec<Mode>,
    pub impacts: Vec<ImpactResponse>,
    /// The layout as built (densities at 0.5 and up, solid; the rest void) is what is analysed.
    /// Solid bodies left once pieces no support holds are dropped.
    #[serde(default)]
    pub bodies: usize,
    /// Solid volume analysed, mm³ (the mass is this times the density).
    #[serde(default)]
    pub solid_mm3: f64,
    /// Solid no support holds (dropped: it would fall off the part), mm³.
    #[serde(default)]
    pub floating_mm3: f64,
    /// Loads with no built material under them ("case: load n"): nothing carries them to a
    /// support, so the part fails.
    #[serde(default)]
    pub unsupported: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Candidate {
    pub id: usize,
    pub method: Method,
    pub mass_g: f64,
    pub volume_fraction: f64,
    /// Every limit kept: stress (with the safety factor), displacement, frequency, impacts.
    pub feasible: bool,
    pub analysis: Analysis,
    /// Objective per iteration.
    pub history: Vec<f64>,
    /// Voxel grid and final densities (`values[e]`), for re-meshing and previews.
    pub grid: Grid,
    pub density: Vec<f32>,
    pub mesh: Mesh,
    /// Volume the surface encloses, mm³ (checked against the solid's within 5 %).
    #[serde(default)]
    pub mesh_mm3: f64,
    /// Why the candidate fails or what to check, in words (empty when it passes cleanly).
    #[serde(default)]
    pub issues: Vec<String>,
    /// False when the run was stopped before this candidate's optimisation finished: its shape
    /// is the best iterate so far, analysed and surfaced like any other, but not settled.
    #[serde(default = "yes")]
    pub converged: bool,
    /// When stopped: the iterations run before the stop (1-based count), else null.
    #[serde(default)]
    pub stopped_at: Option<usize>,
    /// When stopped: the iteration whose densities the candidate keeps (1-based), else null.
    #[serde(default)]
    pub kept_iteration: Option<usize>,
}

fn yes() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Outcome {
    pub candidates: Vec<Candidate>,
    /// The lightest feasible candidate, else the safest.
    pub best: usize,
    /// Wall time, s.
    pub seconds: f64,
    /// Things about the study itself to know (the grid not matching the asked box).
    #[serde(default)]
    pub warnings: Vec<String>,
    /// True when the run was stopped by its caller: the candidates are those finished before
    /// the stop plus, when it had run at least one iteration, the stopped one's best iterate
    /// (`converged` false). The best candidate is chosen among them as usual.
    #[serde(default)]
    pub stopped: bool,
}

/// Runs a study: one optimisation per variant, then analysis and surface per candidate.
pub fn generate(study: &Study) -> Result<Outcome, String> {
    optimize::generate(study)
}

pub use optimize::{CANCELLED, Progress, Step};

/// [`generate`], reporting progress. When `report` answers false the run stops and keeps what
/// it has (see [`Outcome::stopped`]); it fails with [`CANCELLED`] only when nothing was solved.
pub fn generate_with(study: &Study, report: &mut dyn FnMut(&Progress) -> bool) -> Result<Outcome, String> {
    optimize::generate_with(study, report)
}

/// [`generate_with`], also handing every topology iteration (figures and densities) to `observe`.
pub fn generate_observed(study: &Study, report: &mut dyn FnMut(&Progress) -> bool, observe: Option<&mut dyn FnMut(&Step)>) -> Result<Outcome, String> {
    optimize::generate_observed(study, report, observe)
}

/// What an optimiser settles on, before analysis: the densities on the grid, and the surface
/// when the method builds it itself (frames do; topology meshes the densities).
#[derive(Clone, Debug, PartialEq)]
pub struct Layout {
    pub grid: Grid,
    /// Physical (filtered, projected) density per element, 0..1.
    pub density: Vec<f32>,
    pub mesh: Option<Mesh>,
    pub history: Vec<f64>,
}
