//! Long work tracked on the artifact it will build: a generative study, a training run, a
//! render. The registry keeps its progress, works out the time left, and carries pause, resume
//! and cancel to whoever does the work: a Rust [`Worker`] attached to the job, or the front end,
//! which reads the request back (`control`) and calls its own engine.

use std::collections::BTreeMap;

use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobState {
    Running,
    Paused,
}

/// Work in progress on an artifact.
#[derive(Clone, Debug)]
pub struct Job {
    pub id: u64,
    pub artifact: String,
    pub stage: String,
    /// What it does, as a verb ("Generating", "Training", "Rendering").
    pub verb: String,
    pub label: String,
    pub done: Option<u64>,
    pub total: Option<u64>,
    /// 0 to 1 when the work reports it; else from `done / total`, else from `expected`.
    pub progress: Option<f64>,
    /// Seconds the work is expected to take, when it cannot count its steps.
    pub expected: Option<f64>,
    pub started: f64,
    pub state: JobState,
    paused_at: Option<f64>,
    paused_for: f64,
    /// Whether pause and resume mean anything to the worker.
    pub pausable: bool,
    /// The last pause, resume or cancel asked for, until the worker reports again.
    pub control: Option<&'static str>,
}

impl Job {
    pub fn new(id: u64, artifact: &str, stage: &str, verb: &str, label: &str, now: f64) -> Self {
        Self {
            id,
            artifact: artifact.into(),
            stage: stage.into(),
            verb: verb.into(),
            label: label.into(),
            done: None,
            total: None,
            progress: None,
            expected: None,
            started: now,
            state: JobState::Running,
            paused_at: None,
            paused_for: 0.0,
            pausable: false,
            control: None,
        }
    }

    /// Seconds spent working, paused time left out.
    pub fn active(&self, now: f64) -> f64 {
        let paused_now = self.paused_at.map_or(0.0, |p| (now - p).max(0.0));
        (now - self.started - self.paused_for - paused_now).max(0.0)
    }

    /// 0 to 1, or None when nothing tells how far along it is.
    pub fn fraction(&self, now: f64) -> Option<f64> {
        if let Some(p) = self.progress {
            return Some(p.clamp(0.0, 1.0));
        }
        if let (Some(d), Some(t)) = (self.done, self.total)
            && t > 0
        {
            return Some((d as f64 / t as f64).clamp(0.0, 1.0));
        }
        self.expected.filter(|e| *e > 0.0).map(|e| (self.active(now) / e).min(0.99))
    }

    /// Seconds left, once there is enough to go on.
    pub fn eta(&self, now: f64) -> Option<f64> {
        let elapsed = self.active(now);
        if self.progress.is_none()
            && self.done.is_none()
            && let Some(e) = self.expected.filter(|e| *e > 0.0)
        {
            return Some((e - elapsed).max(1.0));
        }
        let p = self.fraction(now)?;
        if p < 0.02 || elapsed < 1.0 {
            return None;
        }
        Some(elapsed * (1.0 - p) / p)
    }

    /// "Generating 74 of 120 · 3 min left", "Training · paused".
    pub fn caption(&self, now: f64) -> String {
        let mut s = self.verb.clone();
        if let (Some(d), Some(t)) = (self.done, self.total) {
            s += &format!(" {d} of {t}");
        } else if let Some(p) = self.progress.filter(|p| *p > 0.0) {
            s += &format!(" {:.0}%", p * 100.0);
        }
        if self.state == JobState::Paused {
            s += " · paused";
        } else if let Some(e) = self.eta(now) {
            s += &format!(" · {}", left(e));
        }
        s
    }

    pub fn pause(&mut self, now: f64) -> bool {
        if self.state == JobState::Paused {
            return false;
        }
        self.state = JobState::Paused;
        self.paused_at = Some(now);
        self.control = Some("pause");
        true
    }

    pub fn resume(&mut self, now: f64) -> bool {
        let Some(p) = self.paused_at.take() else { return false };
        self.paused_for += (now - p).max(0.0);
        self.state = JobState::Running;
        self.control = Some("resume");
        true
    }

    pub fn to_json(&self, now: f64) -> Value {
        json!({
            "id": self.id,
            "artifact": self.artifact,
            "stage": self.stage,
            "verb": self.verb,
            "label": self.label,
            "progress": self.fraction(now).unwrap_or(0.0),
            "determinate": self.fraction(now).is_some(),
            "done": self.done,
            "total": self.total,
            "eta": self.eta(now).map(f64::round),
            "elapsed": self.active(now),
            "caption": self.caption(now),
            "state": match self.state { JobState::Running => "running", JobState::Paused => "paused" },
            "pausable": self.pausable,
            "control": self.control,
        })
    }
}

/// "12 s left", "3 min left", "1 h 20 min left".
pub fn left(secs: f64) -> String {
    let s = secs.round().max(1.0) as u64;
    if s < 60 {
        format!("{s} s left")
    } else if s < 3600 {
        format!("{} min left", s.div_ceil(60))
    } else {
        let m = s.div_ceil(60);
        if m.is_multiple_of(60) { format!("{} h left", m / 60) } else { format!("{} h {} min left", m / 60, m % 60) }
    }
}

/// What a worker reports when it is polled.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Poll {
    pub done: Option<u64>,
    pub total: Option<u64>,
    pub progress: Option<f64>,
    pub label: Option<String>,
    /// Set once the work is over: the built artifact's summary, or why it failed.
    pub finished: Option<Result<Option<String>, String>>,
}

/// Long work done in Rust (a training, a generative study, a render) that the pipeline drives:
/// it is polled on each tick, and pause, resume and cancel reach it from the jobs list. A crate
/// registers its work by implementing this on its own job type (or a small adapter in the
/// bridge) and attaching it with `Flow::attach`, so the pipeline never needs to know it.
pub trait Worker: Send {
    fn poll(&mut self) -> Poll;
    /// Answers whether the work could pause.
    fn pause(&mut self) -> bool {
        false
    }
    fn resume(&mut self) -> bool {
        false
    }
    fn cancel(&mut self) {}
    fn pausable(&self) -> bool {
        false
    }
}

/// The workers attached to jobs, by job id. Not saved and not cloned: a reopened project has no
/// work running.
#[derive(Default)]
pub struct Workers(pub(crate) BTreeMap<u64, Box<dyn Worker>>);

impl std::fmt::Debug for Workers {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list().entries(self.0.keys()).finish()
    }
}

impl Clone for Workers {
    fn clone(&self) -> Self {
        Self::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_left_reads_short() {
        assert_eq!(left(12.4), "12 s left");
        assert_eq!(left(150.0), "3 min left");
        assert_eq!(left(3600.0), "1 h left");
        assert_eq!(left(4800.0), "1 h 20 min left");
    }

    #[test]
    fn eta_leaves_paused_time_out() {
        let mut j = Job::new(1, "generate.frame", "generate", "Generating", "Study", 0.0);
        j.total = Some(120);
        j.done = Some(60);
        assert_eq!(j.eta(60.0), Some(60.0));
        assert_eq!(j.caption(60.0), "Generating 60 of 120 · 1 min left");
        j.pause(60.0);
        assert_eq!(j.caption(600.0), "Generating 60 of 120 · paused");
        j.resume(600.0);
        // Still 60 s of work behind it, so still a minute to go.
        assert_eq!(j.eta(600.0), Some(60.0));
    }

    #[test]
    fn an_expected_duration_gives_progress_without_steps() {
        let mut j = Job::new(1, "generate.frame", "generate", "Generating", "Study", 100.0);
        j.expected = Some(40.0);
        assert_eq!(j.fraction(110.0), Some(0.25));
        assert_eq!(j.eta(110.0), Some(30.0));
        assert_eq!(j.fraction(1000.0), Some(0.99));
    }
}
