//! Drag end effector (VIAFORM-SPEC 7.10.4, RUST-ENGINES 4.3): each pointer move solves IK warm
//! started from the last configuration with at most 10 iterations, so a drag stays at 60 fps.
//! Arms with a spherical wrist take the analytic solution nearest the current configuration
//! when the full pose is asked for; everything else (and a fallback) is numerical. When the target
//! is out of reach the chain stretches toward it and the result reports the distance left.

use serde::Serialize;

use crate::analytic::Analytic6R;
use crate::error::{KinError, codes};
use crate::ik::{AxisMask, IkOptions, IkProblem, IkResult, IkTask, Solver};
use crate::math::Iso3;
use crate::model::{FrameId, Model};

/// Drag settings.
#[derive(Clone, Debug)]
pub struct DragOptions {
    /// Keep the tool orientation (full pose task) or only follow the position.
    pub keep_orientation: bool,
    /// Joints the user froze.
    pub locked: Vec<usize>,
    /// Null-space pull toward mid range (0 = off).
    pub posture_weight: f64,
    /// Iterations per move.
    pub iters: usize,
    /// Use the analytic solver when it applies.
    pub analytic: bool,
}

impl Default for DragOptions {
    fn default() -> Self {
        DragOptions { keep_orientation: true, locked: vec![], posture_weight: 0.0, iters: 10, analytic: true }
    }
}

/// Which solver answered the last move.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SolverKind {
    Analytic,
    Numerical,
}

/// A drag in progress.
#[derive(Clone, Debug)]
pub struct Drag {
    pub frames: Vec<FrameId>,
    pub opts: DragOptions,
    /// Configuration when the drag began (Esc restores it).
    pub q_begin: Vec<f64>,
    /// Current configuration.
    pub q: Vec<f64>,
    pub last: Option<IkResult>,
    pub solver: SolverKind,
    analytic: Option<Analytic6R>,
}

impl Drag {
    /// Starts a drag of `frames` (one tool frame for an arm, several fingertips for a hand).
    pub fn begin(model: &Model, frames: Vec<FrameId>, q: Vec<f64>, opts: DragOptions) -> Result<Drag, KinError> {
        model.check_q(&q)?;
        if frames.is_empty() {
            return Err(KinError::new(codes::PARAMS, "a drag needs a frame"));
        }
        for &f in &frames {
            model.check_frame(f)?;
        }
        let analytic = (opts.analytic && frames.len() == 1 && opts.keep_orientation && opts.locked.is_empty()).then(|| Analytic6R::new(model, frames[0]).ok()).flatten();
        let solver = if analytic.is_some() { SolverKind::Analytic } else { SolverKind::Numerical };
        Ok(Drag { frames, opts, q_begin: q.clone(), q, last: None, solver, analytic })
    }

    fn tasks(&self, targets: &[Iso3]) -> Vec<IkTask> {
        self.frames.iter().zip(targets).map(|(&f, t)| IkTask { mask: if self.opts.keep_orientation { AxisMask::default() } else { AxisMask::position() }, ..IkTask::pose(f, *t) }).collect()
    }

    /// Moves the dragged frames toward `targets` (one per frame). Returns the IK result; the
    /// drag's configuration follows it even when the target is not reached.
    pub fn move_to(&mut self, model: &Model, targets: &[Iso3]) -> Result<&IkResult, KinError> {
        if targets.len() != self.frames.len() {
            return Err(KinError::new(codes::PARAMS, format!("{} targets for {} dragged frames", targets.len(), self.frames.len())));
        }
        let opts = IkOptions { max_iters: self.opts.iters, seeds: 0, ..IkOptions::default() };
        if let Some(a) = &self.analytic {
            if let Some(q) = a.solve_nearest(&targets[0], &self.q) {
                let jump = a.q_index.iter().map(|&k| (q[k] - self.q[k]).abs()).fold(0.0, f64::max);
                if jump < 0.5 {
                    self.solver = SolverKind::Analytic;
                    self.q = q.clone();
                    self.last = Some(IkResult { actuators: model.to_actuators(&q), q, converged: true, iterations: 0, restarts: 0, pos_err: vec![0.0], rot_err: vec![0.0] });
                    return Ok(self.last.as_ref().unwrap());
                }
            }
        }
        self.solver = SolverKind::Numerical;
        let mut problem = IkProblem::new(self.tasks(targets), self.q.clone());
        problem.locked = self.opts.locked.clone();
        problem.posture_weight = self.opts.posture_weight;
        let mut s = Solver::new(model, &problem, &opts)?;
        let r = s.track(&self.q, self.opts.iters, &opts);
        self.q = r.q.clone();
        self.last = Some(r);
        Ok(self.last.as_ref().unwrap())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::{Rng, pose};
    use crate::models;

    #[test]
    fn drag_follows_a_small_move_and_stretches_out_of_reach() {
        let m = models::so101_arm();
        let q0 = vec![0.2, 0.3, 0.5, 0.2, 0.6, -0.1];
        let mut d = Drag::begin(&m, vec![0], q0.clone(), DragOptions::default()).unwrap();
        assert_eq!(d.solver, SolverKind::Analytic);
        let start = m.fk_frame(&q0, 0).unwrap();
        let mut rng = Rng::new(4);
        for _ in 0..60 {
            let mut t = start;
            t.translation.vector += crate::math::Vec3::new(rng.range(-0.01, 0.01), rng.range(-0.01, 0.01), rng.range(-0.01, 0.01));
            let r = d.move_to(&m, &[t]).unwrap();
            assert!(r.converged);
        }
        // Position-only drag far away: stretched, distance reported.
        let mut d = Drag::begin(&m, vec![0], q0, DragOptions { keep_orientation: false, ..DragOptions::default() }).unwrap();
        let far = pose(crate::math::Vec3::new(0.0, 0.9, 0.2), start.rotation);
        let mut last = f64::INFINITY;
        for _ in 0..20 {
            let r = d.move_to(&m, &[far]).unwrap().clone();
            assert!(r.pos_err[0] <= last + 1e-9);
            last = r.pos_err[0];
        }
        assert!(last > 0.4 && last < 0.7, "distance left {last}");
    }
}
