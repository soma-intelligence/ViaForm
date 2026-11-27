//! The generative frame study outcome the drone flies with (safety factor 1.5), from the frame
//! design in generative/. Only the figures the simulation and the renderer need.

/// The generatively designed frame.
#[derive(Clone, Copy, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameDesign {
    pub arm: f64,        // mm, centre to motor axis
    pub thickness: f64,  // mm, carbon plate
    pub mass_g: f64,
    pub deflection: f64, // mm at full thrust
    pub stress: f64,     // MPa
}

pub const FRAME: FrameDesign = FrameDesign { arm: 60.19, thickness: 3.0, mass_g: 11.03, deflection: 0.079, stress: 199.7 };
