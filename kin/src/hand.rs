//! Multi-finger hand IK (RUST-ENGINES 4.3, K5, VIAFORM-SPEC 7.10.5): one position task per
//! fingertip with priorities (higher ones solved first, lower ones in their null space), solved in
//! actuator space so motor-per-joint fingers, linkages and tendons all stay consistent (E-13).

use serde::Serialize;

use crate::error::KinError;
use crate::ik::{IkOptions, IkProblem, IkResult, IkTask, solve};
use crate::math::{UnitQuat, Vec3, pose};
use crate::model::{Drive, FrameId, Model};

/// A fingertip target.
#[derive(Clone, Debug)]
pub struct Fingertip {
    pub frame: FrameId,
    /// Target point in the world (hand base) frame, m.
    pub point: Vec3,
    /// 1 = highest.
    pub priority: u32,
}

/// Result of [`solve_grasp`].
#[derive(Clone, Debug, Serialize)]
pub struct GraspResult {
    pub ik: IkResult,
    /// Per fingertip: within the position tolerance.
    pub reached: Vec<bool>,
    /// Per fingertip: distance left, m.
    pub distance: Vec<f64>,
    /// Per actuator: motor or tendon.
    pub drives: Vec<Drive>,
}

/// Solves a grasp: fingertips to their points (orientation free), with a light pull toward mid
/// range in the null space so unconstrained joints stay natural.
pub fn solve_grasp(model: &Model, tips: &[Fingertip], q0: Vec<f64>, posture_weight: f64, opts: &IkOptions) -> Result<GraspResult, KinError> {
    let tasks = tips.iter().map(|t| IkTask { priority: t.priority, ..IkTask::position(t.frame, pose(t.point, UnitQuat::identity())) }).collect();
    let mut problem = IkProblem::new(tasks, q0);
    problem.posture_weight = posture_weight;
    let ik = solve(model, &problem, opts)?;
    let reached = ik.pos_err.iter().map(|e| *e <= opts.tol_pos).collect();
    let distance = ik.pos_err.clone();
    Ok(GraspResult { ik, reached, distance, drives: model.actuators.iter().map(|a| a.drive).collect() })
}
