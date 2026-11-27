//! Errors with a stable code (RUST-ENGINES section 2).

use serde::Serialize;

/// An engine error: a stable machine `code` (never renamed once shipped) and a user-facing
/// `message`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PhysError {
    pub code: &'static str,
    pub message: String,
}

impl PhysError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        PhysError { code, message: message.into() }
    }
}

impl std::fmt::Display for PhysError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for PhysError {}

impl From<viaform_kin::KinError> for PhysError {
    fn from(e: viaform_kin::KinError) -> Self {
        PhysError { code: e.code, message: e.message }
    }
}

/// Stable error codes (kin's codes pass through unchanged).
pub mod codes {
    /// A parameter is missing or has the wrong type or value.
    pub const PARAMS: &str = "params.invalid";
    /// The op name is unknown.
    pub const UNKNOWN_OP: &str = "op.unknown";
    /// An op that needs a world ran before `world_new` or `scenario_load`.
    pub const NO_WORLD: &str = "world.none";
    /// A batch op ran before `batch_new`.
    pub const NO_BATCH: &str = "batch.none";
    /// The physical model is not valid (missing mass, bad shape, bad actuator).
    pub const MODEL_INVALID: &str = "phys.model_invalid";
    /// A name (body, joint, actuator, rotor) is unknown.
    pub const UNKNOWN_NAME: &str = "name.unknown";
    /// The state became non-finite (step too large for the model, or a bad input).
    pub const DIVERGED: &str = "phys.diverged";
    /// The assembly or scenario file does not parse or is inconsistent.
    pub const SCENARIO: &str = "scenario.invalid";
    /// No job with this id.
    pub const NO_JOB: &str = "job.none";
    /// The engine a world asks for is not built into this binary (MuJoCo without its feature).
    pub const ENGINE_UNAVAILABLE: &str = "engine.unavailable";
    /// The engine cannot run this model (the drone on MuJoCo).
    pub const ENGINE_UNSUPPORTED: &str = "engine.unsupported";
}

pub(crate) fn params(msg: impl Into<String>) -> PhysError {
    PhysError::new(codes::PARAMS, msg)
}

pub(crate) fn invalid(msg: impl Into<String>) -> PhysError {
    PhysError::new(codes::MODEL_INVALID, msg)
}
