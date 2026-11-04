//! The product pipeline: what each workspace consumes and produces, and whether it is current.
//!
//! A project moves through eight stages (design, generate, assemble, electronics, simulate,
//! train, render, make). Each stage owns artifacts (the design model, the generated frame, the
//! board, a flight log, a policy...). An artifact records the revision of every input it was
//! built from, so when an input moves on, everything downstream reads as stale until it is
//! rebuilt. Long work (a generation, a training run, a render) is tracked on the artifact it
//! will produce, so the pipeline shows it running, then current or failed.
//!
//! The graph is the drone product's chain; it is fixed data, the front ends only report what
//! they built and read the status back as JSON.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

/// The eight stages, in pipeline order.
pub const STAGES: [(&str, &str); 8] = [
    ("design", "Design"),
    ("generate", "Generate"),
    ("assemble", "Assemble"),
    ("electronics", "Electronics"),
    ("simulate", "Simulate"),
    ("train", "Train"),
    ("render", "Render"),
    ("make", "Make"),
];

/// The artifacts: id, stage, name, and the artifacts each is built from.
const ARTIFACTS: [(&str, &str, &str, &[&str]); 8] = [
    ("design.model", "design", "Design model", &[]),
    ("generate.frame", "generate", "Generated frame", &["design.model"]),
    ("electronics.board", "electronics", "Flight controller board", &[]),
    ("assemble.assembly", "assemble", "Assembly", &["design.model", "generate.frame", "electronics.board"]),
    ("simulate.flight", "simulate", "Flight log", &["assemble.assembly"]),
    ("train.policy", "train", "Flight policy", &["simulate.flight"]),
    ("render.shots", "render", "Renders", &["assemble.assembly"]),
    ("make.bundle", "make", "Manufacturing bundle", &["generate.frame", "electronics.board", "assemble.assembly", "train.policy"]),
];

/// How current an artifact or a stage is. Ordered from best to worst, so a stage reads as its
/// worst artifact.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    Current,
    Empty,
    Stale,
    Running,
    Failed,
}

impl Status {
    pub fn name(self) -> &'static str {
        match self {
            Status::Current => "current",
            Status::Empty => "empty",
            Status::Stale => "stale",
            Status::Running => "running",
            Status::Failed => "failed",
        }
    }
}

/// Work in progress on an artifact.
#[derive(Clone, Debug)]
struct Job {
    label: String,
    progress: f64,
}

#[derive(Clone, Debug, Default)]
struct Node {
    /// 0 until first built.
    revision: u64,
    /// The revision of each input when this was built.
    seen: BTreeMap<&'static str, u64>,
    summary: String,
    job: Option<Job>,
    error: Option<String>,
}

/// The pipeline state of one project.
#[derive(Clone, Debug)]
pub struct Flow {
    nodes: BTreeMap<&'static str, Node>,
}

impl Default for Flow {
    fn default() -> Self {
        Self { nodes: ARTIFACTS.iter().map(|a| (a.0, Node::default())).collect() }
    }
}

fn artifact(id: &str) -> Option<&'static (&'static str, &'static str, &'static str, &'static [&'static str])> {
    ARTIFACTS.iter().find(|a| a.0 == id)
}

impl Flow {
    pub fn new() -> Self {
        Self::default()
    }

    fn node(&self, id: &str) -> &Node {
        &self.nodes[id]
    }

    /// Whether `id` or anything upstream of it was built against an input that has moved on.
    fn stale(&self, id: &str) -> bool {
        let (_, _, _, inputs) = artifact(id).expect("known artifact");
        let n = self.node(id);
        if n.revision == 0 {
            return false;
        }
        inputs.iter().any(|i| n.seen.get(i).copied().unwrap_or(0) != self.node(i).revision || self.stale(i))
    }

    pub fn status(&self, id: &str) -> Status {
        let n = self.node(id);
        if n.job.is_some() {
            Status::Running
        } else if n.error.is_some() {
            Status::Failed
        } else if n.revision == 0 {
            Status::Empty
        } else if self.stale(id) {
            Status::Stale
        } else {
            Status::Current
        }
    }

    /// A stage reads as its worst artifact, except that an empty artifact does not hide a
    /// current one next to it.
    pub fn stage_status(&self, stage: &str) -> Status {
        let all: Vec<Status> = ARTIFACTS.iter().filter(|a| a.1 == stage).map(|a| self.status(a.0)).collect();
        let built: Vec<Status> = all.iter().copied().filter(|s| *s != Status::Empty).collect();
        built.iter().copied().max().unwrap_or(Status::Empty)
    }

    /// The artifacts built from `id`, directly.
    fn consumers(id: &str) -> Vec<&'static str> {
        ARTIFACTS.iter().filter(|a| a.3.contains(&id)).map(|a| a.0).collect()
    }

    /// Everything downstream of `id`, in pipeline (build) order.
    pub fn downstream(&self, id: &str) -> Vec<&'static str> {
        let mut found = BTreeSet::new();
        let mut todo = Self::consumers(id);
        while let Some(n) = todo.pop() {
            if found.insert(n) {
                todo.extend(Self::consumers(n));
            }
        }
        ARTIFACTS.iter().map(|a| a.0).filter(|a| found.contains(a)).collect()
    }

    /// The stale artifacts to rebuild, in order, so `id` and what feeds it are current.
    pub fn plan_update(&self, id: &str) -> Vec<&'static str> {
        let mut need = BTreeSet::new();
        let mut todo = vec![id];
        while let Some(n) = todo.pop() {
            let Some(a) = artifact(n) else { continue };
            if matches!(self.status(a.0), Status::Stale | Status::Failed) && need.insert(a.0) {
                todo.extend(a.3.iter().copied());
            }
        }
        ARTIFACTS.iter().map(|a| a.0).filter(|a| need.contains(a)).collect()
    }

    /// Records that `id` was just built from the current revisions of its inputs.
    pub fn produce(&mut self, id: &str, summary: Option<&str>) -> Result<u64, String> {
        let (key, _, _, inputs) = artifact(id).ok_or_else(|| format!("unknown artifact {id}"))?;
        let seen = inputs.iter().map(|i| (*i, self.node(i).revision)).collect();
        let n = self.nodes.get_mut(key).expect("known artifact");
        n.revision += 1;
        n.seen = seen;
        n.job = None;
        n.error = None;
        if let Some(s) = summary {
            n.summary = s.to_owned();
        }
        Ok(n.revision)
    }

    fn node_mut(&mut self, id: &str) -> Result<&mut Node, String> {
        let key = artifact(id).ok_or_else(|| format!("unknown artifact {id}"))?.0;
        Ok(self.nodes.get_mut(key).expect("known artifact"))
    }

    pub fn job_start(&mut self, id: &str, label: &str) -> Result<(), String> {
        let n = self.node_mut(id)?;
        n.job = Some(Job { label: label.to_owned(), progress: 0.0 });
        n.error = None;
        Ok(())
    }

    pub fn job_progress(&mut self, id: &str, progress: f64) -> Result<(), String> {
        let n = self.node_mut(id)?;
        let job = n.job.as_mut().ok_or_else(|| format!("no job running on {id}"))?;
        job.progress = progress.clamp(0.0, 1.0);
        Ok(())
    }

    /// Ends the job on `id`: a success builds the artifact, a failure keeps the last build.
    pub fn job_end(&mut self, id: &str, error: Option<&str>, summary: Option<&str>) -> Result<(), String> {
        match error {
            None => self.produce(id, summary).map(|_| ()),
            Some(e) => {
                let n = self.node_mut(id)?;
                n.job = None;
                n.error = Some(e.to_owned());
                Ok(())
            }
        }
    }

    /// The whole pipeline as the front ends draw it.
    pub fn state(&self) -> Value {
        let nodes: Vec<Value> = ARTIFACTS
            .iter()
            .map(|(id, stage, name, inputs)| {
                let n = self.node(id);
                json!({
                    "id": id,
                    "stage": stage,
                    "name": name,
                    "revision": n.revision,
                    "status": self.status(id).name(),
                    "summary": n.summary,
                    "error": n.error,
                    "job": n.job.as_ref().map(|j| json!({"label": j.label, "progress": j.progress})),
                    "consumes": inputs.iter().map(|i| {
                        let seen = n.seen.get(i).copied().unwrap_or(0);
                        let now = self.node(i).revision;
                        json!({"id": i, "seen": seen, "now": now, "current": n.revision == 0 || seen == now})
                    }).collect::<Vec<_>>(),
                    "feeds": Self::consumers(id),
                })
            })
            .collect();
        let stages: Vec<Value> = STAGES
            .iter()
            .map(|(id, name)| {
                let own: Vec<&str> = ARTIFACTS.iter().filter(|a| a.1 == *id).map(|a| a.0).collect();
                let stale = own.iter().filter(|a| self.status(a) == Status::Stale).count();
                json!({"id": id, "name": name, "status": self.stage_status(id).name(), "artifacts": own, "stale": stale})
            })
            .collect();
        let jobs: Vec<Value> = ARTIFACTS
            .iter()
            .filter_map(|a| self.node(a.0).job.as_ref().map(|j| json!({"artifact": a.0, "stage": a.1, "label": j.label, "progress": j.progress})))
            .collect();
        json!({"stages": stages, "nodes": nodes, "jobs": jobs})
    }

    /// One command from a front end: `{"op": "produce" | "job_start" | "job_progress" | "job_end"
    /// | "plan_update" | "downstream" | "reset", "artifact": ..., ...}`. Answers `{"ok": true,
    /// ...}` or `{"error": ...}`.
    pub fn command(&mut self, cmd: &Value) -> Value {
        let id = cmd["artifact"].as_str().unwrap_or("");
        let text = |k: &str| cmd[k].as_str();
        let done = |r: Result<Value, String>| r.unwrap_or_else(|e| json!({"error": e}));
        match cmd["op"].as_str().unwrap_or("") {
            "produce" => done(self.produce(id, text("summary")).map(|rev| json!({"ok": true, "revision": rev}))),
            "job_start" => done(self.job_start(id, text("label").unwrap_or("Working")).map(|_| json!({"ok": true}))),
            "job_progress" => done(self.job_progress(id, cmd["progress"].as_f64().unwrap_or(0.0)).map(|_| json!({"ok": true}))),
            "job_end" => done(self.job_end(id, text("error"), text("summary")).map(|_| json!({"ok": true}))),
            "plan_update" if artifact(id).is_some() => json!({"ok": true, "order": self.plan_update(id)}),
            "downstream" if artifact(id).is_some() => json!({"ok": true, "order": self.downstream(id)}),
            "reset" => {
                *self = Self::new();
                json!({"ok": true})
            }
            "plan_update" | "downstream" => json!({"error": format!("unknown artifact {id}")}),
            op => json!({"error": format!("unknown op {op:?}")}),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_all(f: &mut Flow) {
        for a in ARTIFACTS {
            f.produce(a.0, None).unwrap();
        }
    }

    #[test]
    fn a_new_project_is_empty() {
        let f = Flow::new();
        assert!(STAGES.iter().all(|s| f.stage_status(s.0) == Status::Empty));
    }

    #[test]
    fn building_in_order_leaves_everything_current() {
        let mut f = Flow::new();
        build_all(&mut f);
        assert!(ARTIFACTS.iter().all(|a| f.status(a.0) == Status::Current));
    }

    #[test]
    fn a_new_frame_stales_everything_built_from_it() {
        let mut f = Flow::new();
        build_all(&mut f);
        f.produce("generate.frame", Some("outcome #13")).unwrap();
        for id in ["assemble.assembly", "simulate.flight", "train.policy", "render.shots", "make.bundle"] {
            assert_eq!(f.status(id), Status::Stale, "{id}");
        }
        for id in ["design.model", "generate.frame", "electronics.board"] {
            assert_eq!(f.status(id), Status::Current, "{id}");
        }
        assert_eq!(f.downstream("generate.frame"), ["assemble.assembly", "simulate.flight", "train.policy", "render.shots", "make.bundle"]);
    }

    #[test]
    fn staleness_carries_through_an_unrebuilt_middle() {
        let mut f = Flow::new();
        build_all(&mut f);
        f.produce("electronics.board", None).unwrap();
        // The assembly is stale; the flight was built from the assembly's current revision but
        // still reads stale because what feeds it is.
        assert_eq!(f.status("simulate.flight"), Status::Stale);
        f.produce("assemble.assembly", None).unwrap();
        assert_eq!(f.status("assemble.assembly"), Status::Current);
        assert_eq!(f.status("simulate.flight"), Status::Stale);
    }

    #[test]
    fn plan_update_lists_stale_upstream_in_build_order() {
        let mut f = Flow::new();
        build_all(&mut f);
        f.produce("design.model", None).unwrap();
        assert_eq!(f.plan_update("train.policy"), ["generate.frame", "assemble.assembly", "simulate.flight", "train.policy"]);
        assert!(f.plan_update("electronics.board").is_empty());
    }

    #[test]
    fn jobs_run_then_build_or_fail() {
        let mut f = Flow::new();
        f.job_start("train.policy", "PPO, 16 envs").unwrap();
        f.job_progress("train.policy", 0.4).unwrap();
        assert_eq!(f.status("train.policy"), Status::Running);
        assert_eq!(f.state()["jobs"][0]["progress"], 0.4);
        f.job_end("train.policy", Some("diverged"), None).unwrap();
        assert_eq!(f.status("train.policy"), Status::Failed);
        assert_eq!(f.stage_status("train"), Status::Failed);
        f.job_start("train.policy", "retry").unwrap();
        f.job_end("train.policy", None, Some("policy v2")).unwrap();
        assert_eq!(f.status("train.policy"), Status::Current);
        assert_eq!(f.state()["nodes"][5]["summary"], "policy v2");
    }

    #[test]
    fn commands_answer_json() {
        let mut f = Flow::new();
        assert_eq!(f.command(&json!({"op": "produce", "artifact": "design.model"}))["revision"], 1);
        assert!(f.command(&json!({"op": "produce", "artifact": "nope"}))["error"].is_string());
        assert!(f.command(&json!({"op": "job_progress", "artifact": "design.model", "progress": 0.5}))["error"].is_string());
        assert!(f.command(&json!({"op": "fly"}))["error"].is_string());
        let s = f.state();
        assert_eq!(s["stages"].as_array().unwrap().len(), 8);
        assert_eq!(s["stages"][0]["status"], "current");
    }
}
