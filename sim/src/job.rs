//! Training as a background job for the apps: start it, poll its progress, cancel it. The job runs
//! train.rs on its own thread (which itself scores candidates on every core) and ends with a brain
//! the app can fly (`StartOptions::custom`) and its held-out cost against the brain it started from.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::control::{Gains, RateLoop};
use crate::flight::{Brain, quad3_default, trained};
use crate::physics::QuadParams;
use crate::policy::Policy;
use crate::train::{PolicyOptions, TuneOptions, cost, realistic_scenario, tracking_scenario, train_policy, tune_gains};

/// What to train.
#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Default, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    /// The PID gains for tracking velocity steps (the first training).
    #[default]
    Tracking,
    /// The gains on the realistic plant, half tracking and half disturbance rejection.
    Stabilize,
    /// The neural residual on top of the trained gains.
    Policy,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct TrainOptions {
    pub target: Target,
    pub rate_loop: RateLoop,
    pub iterations: usize,
    pub population: usize,
    pub episodes: usize,
    pub seed: f64,
}

impl Default for TrainOptions {
    fn default() -> Self {
        TrainOptions { target: Target::Tracking, rate_loop: RateLoop::Pid, iterations: 12, population: 16, episodes: 6, seed: 11.0 }
    }
}

/// A brain as JSON: gains, an optional policy, the rate loop and its integrator limit.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct BrainSpec {
    pub gains: Gains,
    #[serde(default)]
    pub policy: Option<Vec<f64>>,
    #[serde(default)]
    pub rate_loop: RateLoop,
    #[serde(default)]
    pub rate_int_max: Option<f64>,
}

impl BrainSpec {
    pub fn brain(&self) -> Brain {
        Brain { gains: self.gains, policy: self.policy.clone().map(Policy::new), rate_loop: self.rate_loop, rate_int_max: self.rate_int_max }
    }
    fn of(b: &Brain) -> Self {
        BrainSpec { gains: b.gains, policy: b.policy.as_ref().map(|p| p.theta.clone()), rate_loop: b.rate_loop, rate_int_max: b.rate_int_max }
    }
}

#[derive(Serialize, Clone, Copy)]
struct Point {
    iteration: usize,
    cost: f64,
    baseline: f64,
}

#[derive(Default)]
struct Progress {
    stage: &'static str,
    history: Vec<Point>,
    result: Option<Value>,
    error: Option<String>,
}

pub struct TrainJob {
    stop: Arc<AtomicBool>,
    progress: Arc<Mutex<Progress>>,
    total: usize,
    handle: Option<JoinHandle<()>>,
}

impl TrainJob {
    pub fn start(options: &str) -> Result<TrainJob, String> {
        let o: TrainOptions = if options.trim().is_empty() { TrainOptions::default() } else { serde_json::from_str(options).map_err(|e| e.to_string())? };
        if o.iterations == 0 || o.population < 2 || o.episodes == 0 || o.iterations > 500 || o.population > 256 || o.episodes > 64 {
            return Err("iterations 1..500, population 2..256, episodes 1..64".into());
        }
        let stop = Arc::new(AtomicBool::new(false));
        let progress = Arc::new(Mutex::new(Progress { stage: "starting", ..Default::default() }));
        let (s, pr) = (stop.clone(), progress.clone());
        let total = o.iterations;
        let handle = std::thread::Builder::new()
            .name("viaform-train".into())
            .spawn(move || {
                let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&quad3_default(), &o, &s, &pr)));
                let mut g = pr.lock().unwrap_or_else(|e| e.into_inner());
                match out {
                    Ok(v) => g.result = Some(v),
                    Err(_) => g.error = Some("the training panicked".into()),
                }
                g.stage = if s.load(Ordering::Relaxed) { "cancelled" } else { "done" };
            })
            .map_err(|e| e.to_string())?;
        Ok(TrainJob { stop, progress, total, handle: Some(handle) })
    }

    /// Asks the job to stop after the iteration it is in; it still reports what it has.
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }

    pub fn running(&self) -> bool {
        self.handle.as_ref().is_some_and(|h| !h.is_finished())
    }

    /// `{running, stage, iteration, total, history: [{iteration, cost, baseline}], result?, error?}`.
    pub fn progress(&self) -> String {
        let g = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        json!({
            "running": self.running(), "stage": g.stage, "iteration": g.history.len(), "total": self.total,
            "history": g.history, "result": g.result, "error": g.error,
        })
        .to_string()
    }

    /// Waits for the job to end (the tests).
    pub fn join(&mut self) {
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for TrainJob {
    fn drop(&mut self) {
        self.cancel();
        self.join();
    }
}

fn run(p: &QuadParams, o: &TrainOptions, stop: &Arc<AtomicBool>, pr: &Arc<Mutex<Progress>>) -> Value {
    let log = |stage: &'static str| {
        let pr = pr.clone();
        Box::new(move |l: crate::train::TrainLog| {
            let mut g = pr.lock().unwrap_or_else(|e| e.into_inner());
            g.stage = stage;
            g.history.push(Point { iteration: l.iteration, cost: l.cost, baseline: l.baseline });
        })
    };
    let halt = || {
        let s = stop.clone();
        Box::new(move || s.load(Ordering::Relaxed))
    };
    let realistic = o.target == Target::Stabilize;
    // Held-out episodes, never trained on: the score shown at the end.
    let held: Vec<_> = (0..8).map(|i| if realistic { realistic_scenario(7_000_000.0 + i as f64) } else { tracking_scenario(77_000.0 + i as f64, 7.0) }).collect();
    let start = trained(false);
    let (from, brain) = match o.target {
        Target::Policy => {
            pr.lock().unwrap_or_else(|e| e.into_inner()).stage = "policy";
            let pol = train_policy(p, start.gains, PolicyOptions {
                iterations: o.iterations, pairs: (o.population / 2).max(1), episodes: o.episodes, seed: o.seed,
                log: log("policy"), stop: halt(), ..Default::default()
            });
            (start.clone(), Brain { policy: Some(pol), ..start })
        }
        Target::Tracking | Target::Stabilize => {
            pr.lock().unwrap_or_else(|e| e.into_inner()).stage = "gains";
            let rate_int_max = realistic.then_some(50.0);
            let from = Brain { rate_loop: o.rate_loop, rate_int_max, ..start.clone() };
            let gains = tune_gains(p, TuneOptions {
                iterations: o.iterations, population: o.population, episodes: o.episodes, seed: o.seed, init: start.gains,
                rate_loop: o.rate_loop, rate_int_max,
                scenario: if realistic { Box::new(realistic_scenario) } else { Box::new(|s| tracking_scenario(s, 7.0)) },
                log: log("gains"), stop: halt(),
            });
            (from.clone(), Brain { gains, ..from })
        }
    };
    pr.lock().unwrap_or_else(|e| e.into_inner()).stage = "scoring";
    let before = cost(p, &from, &held);
    let after = cost(p, &brain, &held);
    json!({ "brain": BrainSpec::of(&brain), "heldOut": { "before": before, "after": after } })
}
