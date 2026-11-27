//! Space frames: a ground structure of candidate beams between lattice nodes in the design space,
//! twelve-degree-of-freedom beam elements (axial, two bending planes, torsion), sized for least
//! mass under the stress and displacement limits; the result as tubes joined at spheres.
//!
//! - `ground`: lattice nodes about `max(4 voxels, longest side / 9)` apart (at most ten a side),
//!   a node at the centre of every support and load region, beams to every node within 1.8
//!   spacings (cube edges, face and body diagonals) that neither runs through a third node nor
//!   comes within half the narrowest member of a keep-out region; mirrored beams share one
//!   diameter.
//! - `beam`: solid round bars, `K = d² Ka + d⁴ Kb`, von Mises at both ends.
//! - `solver`: the stiffness in 6×6 node blocks, nested-dissection ordered, sparse Cholesky.
//! - `model`: supports (all three axes held also holds the rotations), forces and pressures
//!   spread over the region's nodes, torques as nodal moments, accelerations as each bar's own
//!   weight; the aggregated limit and its adjoint gradient.
//! - `sizing`: fully stressed design over the ground structure, thinned to a truss by reweighted
//!   steps that gather each load onto one path (analysed pin-jointed), the truss's thin bars
//!   widened to the narrowest member or cut, a last fully stressed pass that grows until the
//!   limits hold and then tightens, MMA over the best frame kept when lighter, and the whole
//!   ground structure as the last resort when nothing else holds.
//! - `geometry`: the voxel densities and the closed tubes and spheres.

mod beam;
mod geometry;
mod ground;
mod model;
mod sizing;
mod solver;
#[cfg(test)]
mod tests;

use super::{Layout, Study};

/// One sized bar.
#[derive(Clone, Debug, PartialEq)]
pub struct Beam {
    /// Indices into [`Frame::nodes`].
    pub ends: [usize; 2],
    /// Diameter of the solid round bar, mm.
    pub diameter: f64,
    /// Worst von Mises over its ends and the load cases, MPa.
    pub stress: f64,
}

/// A sized space frame and what its beam model says of it.
#[derive(Clone, Debug, PartialEq)]
pub struct Frame {
    /// Joint centres, world mm.
    pub nodes: Vec<[f64; 3]>,
    pub beams: Vec<Beam>,
    /// Joint sphere radius per node, mm.
    pub joints: Vec<f64>,
    /// Per case: compliance times the case's weight, N·mm.
    pub compliance: Vec<f64>,
    /// Per case: worst von Mises over the bars, MPa.
    pub max_stress: Vec<f64>,
    /// Per case: largest nodal displacement, mm.
    pub max_displacement: Vec<f64>,
    /// The bars' mass (joints not counted), g.
    pub mass_g: f64,
    /// The stress and displacement limits kept.
    pub feasible: bool,
    /// Mass per iteration, g.
    pub history: Vec<f64>,
}

/// Sizes a frame for the study (`seed` varies the start) and lays it out on the study's grid.
pub fn optimize(study: &Study, seed: u64) -> Result<Layout, String> {
    let frame = design(study, seed)?;
    layout(study, &frame)
}

/// Sizes a frame for the study: the beam model's own figures, before any voxels.
pub fn design(study: &Study, seed: u64) -> Result<Frame, String> {
    sizing::run(study, seed)
}

/// The frame on the study's grid: densities (1 inside a bar, a joint or a keep-in region) and its
/// surface (closed tubes, spheres and keep-in solids, stress per vertex).
pub fn layout(study: &Study, frame: &Frame) -> Result<Layout, String> {
    geometry::layout(study, frame)
}
