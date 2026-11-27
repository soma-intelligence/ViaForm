//! Errors with a stable code (RUST-ENGINES section 2).

use serde::Serialize;

/// An engine error: a stable machine `code` (never renamed once shipped), a user-facing
/// `message`, and for path errors the sample `index` where it happened.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct KinError {
    pub code: &'static str,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
}

impl KinError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        KinError { code, message: message.into(), index: None }
    }
    pub fn at(code: &'static str, index: usize, message: impl Into<String>) -> Self {
        KinError { code, message: message.into(), index: Some(index) }
    }
}

impl std::fmt::Display for KinError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for KinError {}

/// Stable error codes.
pub mod codes {
    /// The model JSON does not parse.
    pub const MODEL_PARSE: &str = "model.parse";
    /// The model is inconsistent (indices, axes, limits, couplings).
    pub const MODEL_INVALID: &str = "model.invalid";
    /// No model is loaded (facade).
    pub const MODEL_NONE: &str = "model.none";
    /// A frame, link, joint or actuator name or index does not exist.
    pub const UNKNOWN_NAME: &str = "name.unknown";
    /// A configuration or vector has the wrong length or is not finite.
    pub const BAD_VECTOR: &str = "vector.invalid";
    /// The facade got parameters it cannot read.
    pub const PARAMS: &str = "params.invalid";
    /// The facade does not know the op.
    pub const UNKNOWN_OP: &str = "op.unknown";
    /// The analytic solver does not apply to this model and frame.
    pub const ANALYTIC_UNSUPPORTED: &str = "ik.analytic_unsupported";
    /// A Cartesian path sample has no IK solution (index = sample).
    pub const PATH_UNREACHABLE: &str = "path.unreachable";
    /// A joint jumps more than the allowed step between samples (index = sample).
    pub const PATH_BRANCH_FLIP: &str = "path.branch_flip";
    /// A joint crosses a limit on the path (index = sample).
    pub const PATH_LIMIT: &str = "path.joint_limit";
    /// The path request itself is invalid (no waypoints, bad limits).
    pub const PATH_INVALID: &str = "path.invalid";
}
