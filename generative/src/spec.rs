//! What a generative study asks for, and what it answers. Both cross the front ends as JSON.
//!
//! The design space is a plate in the XY plane: `width` along X, `height` along Y, `thickness`
//! along Z, its corner at `origin`. Supports hold it, loads push it (in plane), keep-out regions
//! stay empty and keep-in regions stay solid. Units: mm, N, MPa (N/mm²), g.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    /// Density-based topology optimisation (SIMP) on a grid of plane-stress elements.
    #[default]
    Topology,
    /// A ground structure of candidate beams; an evolution strategy sizes each one (zero removes it).
    Frame,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Fix {
    /// Both in-plane directions held.
    #[default]
    All,
    X,
    Y,
}

/// A circle or an axis-aligned rectangle, in domain coordinates (mm from the domain's corner).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "shape", rename_all = "snake_case")]
pub enum Region {
    Circle { center: [f64; 2], radius: f64 },
    Rect { min: [f64; 2], max: [f64; 2] },
}

impl Region {
    pub fn contains(&self, p: [f64; 2]) -> bool {
        match *self {
            Region::Circle { center, radius } => (p[0] - center[0]).hypot(p[1] - center[1]) <= radius,
            Region::Rect { min, max } => p[0] >= min[0] && p[0] <= max[0] && p[1] >= min[1] && p[1] <= max[1],
        }
    }

    pub fn center(&self) -> [f64; 2] {
        match *self {
            Region::Circle { center, .. } => center,
            Region::Rect { min, max } => [(min[0] + max[0]) / 2.0, (min[1] + max[1]) / 2.0],
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Support {
    pub region: Region,
    #[serde(default)]
    pub fix: Fix,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Load {
    /// The force spreads evenly over the nodes inside this region (the nearest node if none).
    pub region: Region,
    /// In-plane force, N.
    pub force: [f64; 2],
}

/// Loads applied together. A study optimises for the sum of the cases' compliances and checks
/// stress and displacement in each.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LoadCase {
    #[serde(default)]
    pub name: String,
    pub loads: Vec<Load>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Material {
    pub name: String,
    /// Young's modulus, MPa.
    pub e: f64,
    pub nu: f64,
    /// g/mm³.
    pub density: f64,
    /// Allowable stress, MPa.
    pub allowable: f64,
    /// Hex colour for the SolidCraft material.
    #[serde(default = "default_color")]
    pub color: String,
}

fn default_color() -> String {
    "#8a9099".into()
}

impl Default for Material {
    /// 6061-T6 aluminium.
    fn default() -> Self {
        Self { name: "Aluminum 6061".into(), e: 69_000.0, nu: 0.33, density: 2.7e-3, allowable: 180.0, color: "#b9c0c8".into() }
    }
}

/// Thermal properties of a material, SI as datasheets give them.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ThermalProperties {
    /// Thermal conductivity, W/(m K).
    pub conductivity: f64,
    /// Linear thermal expansion, 1/K.
    pub expansion: f64,
    /// Specific heat, J/(kg K).
    pub specific_heat: f64,
}

/// The thermal table of the engine's materials, looked up by name ([`Material::thermal`]): a
/// material matches the first row one of whose keys its lower-case name contains. Room
/// temperature values. Sources:
/// - aluminium 6061-T6: 167 W/(m K), 23.6e-6/K, 896 J/(kg K) (ASM Handbook vol. 2; MatWeb
///   "Aluminum 6061-T6");
/// - AlSi10Mg, laser powder bed, as built: 130 W/(m K) (EOS datasheet gives about 110 to 150
///   by direction and heat treatment), 21e-6/K, 900 J/(kg K);
/// - copper C11000: 390 W/(m K), 17.0e-6/K, 385 J/(kg K) (CDA data, MatWeb);
/// - carbon steel (AISI 1020, the generic "steel"): 51.9 rounded to 50 W/(m K), 11.7e-6/K,
///   486 J/(kg K) (MatWeb "AISI 1020");
/// - titanium Ti6Al4V: 6.7 W/(m K), 8.6e-6/K, 526 J/(kg K) (ASM Aerospace Specification Metals);
/// - PA12 (SLS): 0.25 W/(m K), 100e-6/K, 1200 J/(kg K) (bulk nylon 12, MatWeb typical; a
///   sintered part runs lower, about 0.15);
/// - PETG: 0.20 W/(m K), 68e-6/K, 1170 J/(kg K) (Eastman Eastar 6763 and filament datasheets);
/// - PLA: 0.13 W/(m K), 68e-6/K, 1800 J/(kg K) (NatureWorks Ingeo, Farah et al., Adv. Drug
///   Deliv. Rev. 107 (2016));
/// - carbon fibre composite (quasi-isotropic T700/epoxy laminate): 4.0 W/(m K) and 2e-6/K in
///   plane, 1000 J/(kg K). Note: in plane only; through the thickness the conductivity is about
///   0.6 W/(m K) and the expansion about 50e-6/K, and the voxel model is isotropic, so a carbon
///   part's heat flow across its plies is overestimated.
pub const THERMAL_TABLE: &[(&[&str], ThermalProperties)] = &[
    (&["alsi10mg"], ThermalProperties { conductivity: 130.0, expansion: 21.0e-6, specific_heat: 900.0 }),
    (&["pa12", "nylon", "pa 12"], ThermalProperties { conductivity: 0.25, expansion: 100.0e-6, specific_heat: 1200.0 }),
    (&["carbon"], ThermalProperties { conductivity: 4.0, expansion: 2.0e-6, specific_heat: 1000.0 }),
    (&["petg"], ThermalProperties { conductivity: 0.20, expansion: 68.0e-6, specific_heat: 1170.0 }),
    (&["pla"], ThermalProperties { conductivity: 0.13, expansion: 68.0e-6, specific_heat: 1800.0 }),
    (&["ti6al4v", "titan", "ti-6al-4v"], ThermalProperties { conductivity: 6.7, expansion: 8.6e-6, specific_heat: 526.0 }),
    (&["copper"], ThermalProperties { conductivity: 390.0, expansion: 17.0e-6, specific_heat: 385.0 }),
    (&["steel"], ThermalProperties { conductivity: 50.0, expansion: 11.7e-6, specific_heat: 486.0 }),
    (&["alumin", "6061"], ThermalProperties { conductivity: 167.0, expansion: 23.6e-6, specific_heat: 896.0 }),
];

impl Material {
    /// The material's thermal properties from [`THERMAL_TABLE`] by its name; `None` when no
    /// row matches (a thermal study then needs its conductivity given).
    pub fn thermal(&self) -> Option<ThermalProperties> {
        let name = self.name.to_lowercase();
        THERMAL_TABLE.iter().find(|(keys, _)| keys.iter().any(|k| name.contains(k))).map(|(_, p)| *p)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Symmetry {
    /// Mirror about the vertical line through the domain's centre.
    #[serde(default)]
    pub x: bool,
    /// Mirror about the horizontal line through the domain's centre.
    #[serde(default)]
    pub y: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Spec {
    pub method: Method,
    pub width: f64,
    pub height: f64,
    pub thickness: f64,
    /// Where the domain's corner sits in the design, mm.
    pub origin: [f64; 3],
    /// Element size (topology) or ground-structure node spacing (frame), mm.
    pub resolution: f64,
    pub supports: Vec<Support>,
    pub cases: Vec<LoadCase>,
    pub keep_out: Vec<Region>,
    pub keep_in: Vec<Region>,
    pub material: Material,
    /// Share of the domain's area the result may fill (topology), or the volume cap (frame).
    pub volume_fraction: f64,
    pub iterations: usize,
    /// SIMP penalty.
    pub penal: f64,
    /// Density filter radius, mm (topology).
    pub filter_radius: f64,
    /// Narrowest member the result may have, mm.
    pub min_member: f64,
    pub symmetry: Symmetry,
    /// Candidates to generate: each varies the volume fraction (topology) or the seed (frame).
    pub variants: usize,
    pub seed: u64,
    /// Name of the body the result builds.
    pub body_name: String,
}

impl Default for Spec {
    fn default() -> Self {
        Self {
            method: Method::Topology,
            width: 120.0,
            height: 40.0,
            thickness: 6.0,
            origin: [0.0; 3],
            resolution: 2.0,
            supports: Vec::new(),
            cases: Vec::new(),
            keep_out: Vec::new(),
            keep_in: Vec::new(),
            material: Material::default(),
            volume_fraction: 0.4,
            iterations: 60,
            penal: 3.0,
            filter_radius: 3.0,
            min_member: 3.0,
            symmetry: Symmetry::default(),
            variants: 1,
            seed: 1,
            body_name: "Generated".into(),
        }
    }
}

impl Spec {
    /// Refuses a study the solvers cannot run.
    pub fn validate(&self) -> Result<(), String> {
        let positive = [("width", self.width), ("height", self.height), ("thickness", self.thickness), ("resolution", self.resolution)];
        if let Some((name, _)) = positive.iter().find(|(_, v)| !(v.is_finite() && *v > 0.0)) {
            return Err(format!("{name} must be a positive number"));
        }
        if self.width / self.resolution * (self.height / self.resolution) > 250_000.0 {
            return Err("the grid is too fine: raise the resolution (at most 250 000 elements)".into());
        }
        if self.supports.is_empty() {
            return Err("at least one support is required".into());
        }
        if self.cases.iter().all(|c| c.loads.is_empty()) {
            return Err("at least one load is required".into());
        }
        if !(0.02..=0.95).contains(&self.volume_fraction) {
            return Err("volume_fraction must be between 0.02 and 0.95".into());
        }
        if !(self.material.e > 0.0 && (0.0..0.5).contains(&self.material.nu) && self.material.density > 0.0) {
            return Err("material needs e > 0, 0 ≤ nu < 0.5 and density > 0".into());
        }
        if self.variants == 0 || self.variants > 16 {
            return Err("variants must be between 1 and 16".into());
        }
        Ok(())
    }
}

/// The shape a candidate settled on.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Shape {
    /// Element densities, row-major from the domain's corner: `values[j * nx + i]` is the
    /// element whose corner is `(i * cell, j * cell)`.
    Density { nx: usize, ny: usize, cell: f64, values: Vec<f64> },
    /// Beams between nodes; `width` is in plane, the depth is the spec's thickness.
    Frame { nodes: Vec<[f64; 2]>, beams: Vec<Beam> },
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Beam {
    pub a: usize,
    pub b: usize,
    pub width: f64,
}

/// What a solver reports about one candidate, before geometry.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Solved {
    pub shape: Shape,
    /// Sum over load cases, N·mm.
    pub compliance: f64,
    /// Worst von Mises (topology) or fibre (frame) stress over the cases, MPa.
    pub max_stress: f64,
    /// Worst nodal displacement over the cases, mm.
    pub max_displacement: f64,
    /// Filled share of the domain.
    pub volume_fraction: f64,
    /// Objective per iteration (generation, for frames).
    pub history: Vec<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Candidate {
    pub id: usize,
    pub method: Method,
    pub mass_g: f64,
    pub compliance: f64,
    pub max_stress: f64,
    pub max_displacement: f64,
    pub volume_fraction: f64,
    /// Stress under the material's allowable.
    pub feasible: bool,
    pub history: Vec<f64>,
    pub shape: Shape,
    /// Closed outlines of the solid, domain coordinates (for previews).
    pub outlines: Vec<Vec<[f64; 2]>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Outcome {
    pub candidates: Vec<Candidate>,
    /// The lightest feasible candidate, else the least stressed.
    pub best: usize,
}
