//! The product pipeline: what each workspace consumes and produces, and whether it is current.
//!
//! A project moves through eight stages (design, generate, assemble, electronics, simulate,
//! train, render, make). Each stage owns artifacts (the design model, the generated frame, the
//! board, a flight log, a policy...). Every build of an artifact is a [`Revision`] ("Frame v12",
//! "Board rev C") that records the revision of every input it was built from, so when an input
//! moves on, everything downstream reads as stale until it is rebuilt, with a reason ("Frame v12
//! replaced v11") and an action ("Re-run on Frame v12"). Long work (a generation, a training
//! run, a render) is a [`Job`] on the artifact it will produce, with progress, time left, pause,
//! resume and cancel.
//!
//! The pipeline also keeps what the browser shows of each stage (the [`tree`], with the eye and
//! the lock of every row), the selection and where it shows in the other stages, and the
//! [`commands`] of all eight stages with their search. The project's graph and state save as
//! `flow.json` in the `.viaform` file ([`persist`]).
//!
//! Front ends drive it with JSON commands ([`Flow::command`]) and read [`Flow::state`] back.

pub mod commands;
pub mod graph;
pub mod jobs;
pub mod persist;
pub mod revision;
pub mod tree;

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

pub use graph::{ArtifactDef, Graph, Scheme, StageDef};
pub use jobs::{Job, JobState, Poll, Worker};
pub use revision::Revision;
pub use tree::{Flags, Selection, TreeItem};

use jobs::Workers;
use tree::Trees;

/// The nine stages, in pipeline order (the default graph's).
pub const STAGES: [(&str, &str); 9] = [
    ("design", "Design"),
    ("generate", "Generate"),
    ("assemble", "Assemble"),
    ("electronics", "Electronics"),
    ("simulate", "Simulate"),
    ("train", "Train"),
    ("render", "Render"),
    ("make", "Make"),
    ("robot", "Robot"),
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

/// Seconds since the Unix epoch.
pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

#[derive(Clone, Debug, Default)]
struct Node {
    revisions: Vec<Revision>,
    /// The revision in use; 0 until first built.
    active: u64,
    error: Option<String>,
    /// A passing word about the last job ("Cancelled", "Interrupted...").
    note: Option<String>,
}

impl Node {
    fn rev(&self, n: u64) -> Option<&Revision> {
        self.revisions.iter().find(|r| r.number == n)
    }

    fn current(&self) -> Option<&Revision> {
        self.rev(self.active)
    }
}

/// How a build was reported (see `produce` in [`Flow::command`]).
#[derive(Clone, Debug, Default)]
pub struct Build {
    pub summary: Option<String>,
    pub fingerprint: Option<String>,
    /// Folds this build into the last one when it came less than this many seconds ago, was an
    /// edit too, and nothing was built from it yet: a burst of edits is one revision.
    pub amend_within: Option<f64>,
    pub data: Value,
    pub source: Option<String>,
    pub from: Option<String>,
}

impl Build {
    pub fn summary(s: &str) -> Self {
        Self { summary: Some(s.to_owned()), ..Self::default() }
    }

    fn from_json(cmd: &Value) -> Self {
        let text = |k: &str| cmd[k].as_str().map(str::to_owned);
        Self {
            summary: text("summary"),
            fingerprint: text("fingerprint"),
            amend_within: cmd["amend_within"].as_f64(),
            data: cmd.get("data").cloned().unwrap_or(Value::Null),
            source: text("source"),
            from: text("from"),
        }
    }
}

/// What a build did to the artifact's revisions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Built {
    /// A new revision.
    New(u64),
    /// Folded into the last revision.
    Amended(u64),
    /// The same content as the revision in use: nothing changed.
    Unchanged(u64),
    /// The same content as an earlier revision (an undo): that one is in use again.
    Restored(u64),
}

impl Built {
    pub fn revision(self) -> u64 {
        match self {
            Built::New(n) | Built::Amended(n) | Built::Unchanged(n) | Built::Restored(n) => n,
        }
    }

    fn word(self) -> &'static str {
        match self {
            Built::New(_) => "new",
            Built::Amended(_) => "amended",
            Built::Unchanged(_) => "unchanged",
            Built::Restored(_) => "restored",
        }
    }
}

/// The pipeline state of one project.
#[derive(Clone, Debug)]
pub struct Flow {
    graph: Graph,
    nodes: BTreeMap<String, Node>,
    jobs: Vec<Job>,
    next_job: u64,
    trees: Trees,
    workers: Workers,
}

impl Default for Flow {
    fn default() -> Self {
        Self::with_graph(Graph::drone()).expect("the drone graph is valid")
    }
}

impl Flow {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_graph(graph: Graph) -> Result<Self, String> {
        graph.validate()?;
        let nodes = graph.artifacts.iter().map(|a| (a.id.clone(), Node::default())).collect();
        Ok(Self { graph, nodes, jobs: Vec::new(), next_job: 1, trees: Trees::default(), workers: Workers::default() })
    }

    pub fn graph(&self) -> &Graph {
        &self.graph
    }

    fn def(&self, id: &str) -> Result<&ArtifactDef, String> {
        self.graph.artifact(id).ok_or_else(|| format!("unknown artifact {id}"))
    }

    fn node(&self, id: &str) -> &Node {
        static EMPTY: Node = Node { revisions: Vec::new(), active: 0, error: None, note: None };
        self.nodes.get(id).unwrap_or(&EMPTY)
    }

    fn node_mut(&mut self, id: &str) -> Result<&mut Node, String> {
        self.def(id)?;
        Ok(self.nodes.entry(id.to_owned()).or_default())
    }

    fn stage_order(&self) -> Vec<String> {
        self.graph.stages.iter().map(|s| s.id.clone()).collect()
    }

    /// The revision of `id` in use (0 when not built).
    pub fn revision(&self, id: &str) -> u64 {
        self.node(id).active
    }

    /// "Frame v12", "Board rev C".
    pub fn revision_name(&self, id: &str, n: u64) -> String {
        match self.graph.artifact(id) {
            Some(a) => a.scheme.name(&a.label, n),
            None => format!("{id} {n}"),
        }
    }

    /// "v11", "rev B": a revision named after the artifact it belongs to was already said.
    fn short_name(&self, id: &str, n: u64) -> String {
        let full = self.revision_name(id, n);
        let label = self.graph.artifact(id).map_or("", |a| a.label.as_str());
        full.strip_prefix(label).map_or(full.clone(), |s| s.trim().to_owned())
    }

    /// Whether `id` or anything upstream of it was built against an input that has moved on.
    fn stale(&self, id: &str) -> bool {
        let Some(a) = self.graph.artifact(id) else { return false };
        let Some(r) = self.node(id).current() else { return false };
        a.inputs.iter().any(|i| r.seen.get(i).copied().unwrap_or(0) != self.node(i).active || self.stale(i))
    }

    fn job_on(&self, id: &str) -> Option<&Job> {
        self.jobs.iter().find(|j| j.artifact == id)
    }

    pub fn status(&self, id: &str) -> Status {
        let n = self.node(id);
        if self.job_on(id).is_some() {
            Status::Running
        } else if n.error.is_some() {
            Status::Failed
        } else if n.active == 0 {
            Status::Empty
        } else if self.stale(id) {
            Status::Stale
        } else {
            Status::Current
        }
    }

    fn own(&self, stage: &str) -> Vec<&str> {
        self.graph.artifacts.iter().filter(|a| a.stage == stage).map(|a| a.id.as_str()).collect()
    }

    /// A stage reads as its worst artifact, except that an empty artifact does not hide a
    /// current one next to it.
    pub fn stage_status(&self, stage: &str) -> Status {
        self.own(stage).iter().map(|a| self.status(a)).filter(|s| *s != Status::Empty).max().unwrap_or(Status::Empty)
    }

    /// Everything downstream of `id`, in pipeline (build) order.
    pub fn downstream(&self, id: &str) -> Vec<String> {
        let mut found = BTreeSet::new();
        let mut todo: Vec<String> = self.graph.consumers(id).into_iter().map(str::to_owned).collect();
        while let Some(n) = todo.pop() {
            if found.insert(n.clone()) {
                todo.extend(self.graph.consumers(&n).into_iter().map(str::to_owned));
            }
        }
        self.graph.artifacts.iter().map(|a| a.id.clone()).filter(|a| found.contains(a)).collect()
    }

    /// The stale artifacts to rebuild, in order, so `id` and what feeds it are current.
    pub fn plan_update(&self, id: &str) -> Vec<String> {
        let mut need = BTreeSet::new();
        let mut todo = vec![id.to_owned()];
        while let Some(n) = todo.pop() {
            let Some(a) = self.graph.artifact(&n) else { continue };
            if matches!(self.status(&a.id), Status::Stale | Status::Failed) && need.insert(a.id.clone()) {
                todo.extend(a.inputs.iter().cloned());
            }
        }
        self.graph.artifacts.iter().map(|a| a.id.clone()).filter(|a| need.contains(a)).collect()
    }

    /// Whether an artifact built from `id` uses its revision `n`.
    fn consumed(&self, id: &str, n: u64) -> bool {
        self.graph.consumers(id).iter().any(|c| self.node(c).current().is_some_and(|r| r.seen.get(id) == Some(&n)))
    }

    /// Records that `id` was just built from the current revisions of its inputs. With a
    /// fingerprint, a build with the content of the revision in use changes nothing, and one
    /// with the content of an older revision (an undo) puts that revision back in use.
    pub fn produce(&mut self, id: &str, b: Build) -> Result<Built, String> {
        self.produce_at(id, b, now())
    }

    pub fn produce_at(&mut self, id: &str, b: Build, at: f64) -> Result<Built, String> {
        let inputs = self.def(id)?.inputs.clone();
        let seen: BTreeMap<String, u64> = inputs.iter().map(|i| (i.clone(), self.node(i).active)).collect();
        let consumed = self.node(id).active > 0 && self.consumed(id, self.node(id).active);
        self.jobs.retain(|j| j.artifact != id);
        self.workers.0.retain(|k, _| self.jobs.iter().any(|j| j.id == *k));
        let n = self.node_mut(id)?;
        n.error = None;
        n.note = None;
        if let Some(fp) = &b.fingerprint {
            if let Some(r) = n.current()
                && r.fingerprint.as_ref() == Some(fp)
                && r.seen == seen
            {
                return Ok(Built::Unchanged(r.number));
            }
            if let Some(r) = n.revisions.iter().rev().find(|r| r.fingerprint.as_ref() == Some(fp) && r.seen == seen) {
                n.active = r.number;
                return Ok(Built::Restored(r.number));
            }
        }
        let source = b.source.clone().unwrap_or_else(|| "build".into());
        if let Some(window) = b.amend_within {
            let active = n.active;
            let last = n.revisions.last().map(|r| r.number);
            if let Some(r) = n.revisions.iter_mut().find(|r| r.number == active)
                && last == Some(active)
                && r.source == source
                && at - r.at <= window
                && r.seen == seen
                && !consumed
            {
                if let Some(s) = b.summary {
                    r.summary = s;
                }
                r.fingerprint = b.fingerprint;
                if !b.data.is_null() {
                    r.data = b.data;
                }
                r.at = at;
                return Ok(Built::Amended(r.number));
            }
        }
        let number = n.revisions.last().map_or(0, |r| r.number) + 1;
        n.revisions.push(Revision {
            number,
            seen,
            summary: b.summary.unwrap_or_default(),
            source,
            from: b.from,
            fingerprint: b.fingerprint,
            data: b.data,
            at,
        });
        n.active = number;
        Ok(Built::New(number))
    }

    /// Makes a result the artifact's new revision ("Use as Frame" on a generative outcome).
    pub fn promote(&mut self, id: &str, from: &str, mut b: Build) -> Result<Built, String> {
        b.source = Some("promote".into());
        b.from = Some(from.to_owned());
        b.amend_within = None;
        if b.summary.is_none() {
            b.summary = Some(format!("From {from}"));
        }
        self.produce(id, b)
    }

    /// Puts an earlier revision of `id` back in use; what was built from the later one reads
    /// stale.
    pub fn activate(&mut self, id: &str, number: u64) -> Result<(), String> {
        let name = self.revision_name(id, number);
        let n = self.node_mut(id)?;
        if n.rev(number).is_none() {
            return Err(format!("{name} does not exist"));
        }
        n.active = number;
        n.error = None;
        Ok(())
    }

    /// Every revision of `id`, oldest first, with what uses it.
    pub fn revisions(&self, id: &str) -> Result<Value, String> {
        self.def(id)?;
        let n = self.node(id);
        let list: Vec<Value> = n
            .revisions
            .iter()
            .map(|r| {
                let used_by: Vec<&str> =
                    self.graph.consumers(id).into_iter().filter(|c| self.node(c).current().is_some_and(|cr| cr.seen.get(id) == Some(&r.number))).collect();
                json!({
                    "number": r.number,
                    "name": self.revision_name(id, r.number),
                    "summary": r.summary,
                    "source": r.source,
                    "from": r.from,
                    "at": r.at,
                    "data": r.data,
                    "active": r.number == n.active,
                    "used_by": used_by,
                    "inputs": r.seen.iter().map(|(k, v)| json!({"id": k, "name": self.revision_name(k, *v)})).collect::<Vec<_>>(),
                })
            })
            .collect();
        Ok(json!({"artifact": id, "active": n.active, "revisions": list}))
    }

    /// What changed from revision `a` to `b` of `id` (by default the one before the active
    /// revision, and the active one).
    pub fn diff(&self, id: &str, a: Option<u64>, b: Option<u64>) -> Result<Value, String> {
        self.def(id)?;
        let n = self.node(id);
        let b = b.unwrap_or(n.active);
        let a = a.unwrap_or_else(|| n.revisions.iter().map(|r| r.number).filter(|x| *x < b).max().unwrap_or(0));
        let empty = Revision::default();
        let ra = if a == 0 { &empty } else { n.rev(a).ok_or_else(|| format!("{} does not exist", self.revision_name(id, a)))? };
        let rb = n.rev(b).ok_or_else(|| format!("{} does not exist", self.revision_name(id, b)))?;
        Ok(revision::diff(|k, v| self.revision_name(k, v), id, ra, rb))
    }

    /// Why `id` reads as it does, in a line: "Frame v12 replaced v11".
    pub fn reason(&self, id: &str) -> String {
        let n = self.node(id);
        match self.status(id) {
            Status::Current => String::new(),
            Status::Empty => "Not built yet".into(),
            Status::Running => self.job_on(id).map(|j| j.caption(now())).unwrap_or_default(),
            Status::Failed => n.error.clone().unwrap_or_default(),
            Status::Stale => {
                let (Some(a), Some(r)) = (self.graph.artifact(id), n.current()) else { return String::new() };
                // The same input the action re-runs on, so "Model v3 replaced v2" never sits
                // next to "Re-run on Board rev A".
                if let Some(i) = self.changed_input(id) {
                    let seen = r.seen.get(&i).copied().unwrap_or(0);
                    let now = self.node(&i).active;
                    return if seen == 0 {
                        format!("{} is new", self.revision_name(&i, now))
                    } else {
                        format!("{} replaced {}", self.revision_name(&i, now), self.short_name(&i, seen))
                    };
                }
                // Built on current inputs that wait on something themselves: name the nearest
                // root cause only ("Model v13 replaced v12"), or the input still being built.
                if let Some(i) = a.inputs.iter().find(|i| self.status(i) == Status::Running) {
                    return format!("Waiting on {}", self.revision_name(i, self.node(i).active.max(1)));
                }
                a.inputs.iter().find(|i| self.stale(i)).map(|i| self.reason(i)).unwrap_or_default()
            }
        }
    }

    /// The input of `id` whose revision moved since `id` was built; with several, the latest in
    /// the graph (a frame or a board says more than the model behind it).
    fn changed_input(&self, id: &str) -> Option<String> {
        let a = self.graph.artifact(id)?;
        let r = self.node(id).current()?;
        let mut changed: Vec<&String> = a.inputs.iter().filter(|i| r.seen.get(*i).copied().unwrap_or(0) != self.node(i).active).collect();
        changed.sort_by_key(|i| std::cmp::Reverse(self.graph.artifacts.iter().position(|x| &x.id == *i)));
        changed.first().map(|i| (*i).clone())
    }

    /// The input change that made `id` stale, as the revision to re-run on.
    fn rerun_on(&self, id: &str) -> Option<String> {
        let a = self.graph.artifact(id)?;
        match self.changed_input(id) {
            Some(i) => Some(self.revision_name(&i, self.node(&i).active)),
            // Built on current inputs that are themselves stale: re-run on what they wait for.
            None => a.inputs.iter().find(|i| self.stale(i)).and_then(|i| self.rerun_on(i)),
        }
    }

    /// The one action a stale, failed or empty artifact offers.
    pub fn action(&self, id: &str) -> Value {
        match self.status(id) {
            Status::Stale => {
                let label = self.rerun_on(id).map_or("Update".to_owned(), |r| format!("Re-run on {r}"));
                json!({"label": label, "op": "update", "plan": self.plan_update(id)})
            }
            Status::Failed => json!({"label": "Retry", "op": "update", "plan": self.plan_update(id)}),
            Status::Empty => {
                let ready = self.graph.artifact(id).is_some_and(|a| !a.inputs.is_empty() && a.inputs.iter().all(|i| self.node(i).active > 0));
                if ready { json!({"label": "Build", "op": "build", "plan": [id]}) } else { Value::Null }
            }
            _ => Value::Null,
        }
    }

    // MARK: Jobs

    fn job_index(&self, cmd: &Value) -> Result<usize, String> {
        if let Some(j) = cmd["job"].as_u64() {
            return self.jobs.iter().position(|x| x.id == j).ok_or_else(|| format!("no job {j}"));
        }
        let id = cmd["artifact"].as_str().unwrap_or("");
        self.def(id)?;
        self.jobs.iter().position(|x| x.artifact == id).ok_or_else(|| format!("no job running on {id}"))
    }

    /// Starts work on `id`; it reads as running until the job ends. Answers the job id. A job
    /// already on the artifact is replaced.
    pub fn job_start(&mut self, id: &str, verb: &str, label: &str, at: f64) -> Result<u64, String> {
        let stage = self.def(id)?.stage.clone();
        if let Some(old) = self.job_on(id).map(|j| j.id) {
            self.workers.0.remove(&old);
        }
        self.jobs.retain(|j| j.artifact != id);
        let n = self.node_mut(id)?;
        n.error = None;
        n.note = None;
        let job = self.next_job;
        self.next_job += 1;
        self.jobs.push(Job::new(job, id, &stage, verb, label, at));
        Ok(job)
    }

    fn job_mut(&mut self, job: u64) -> Result<&mut Job, String> {
        self.jobs.iter_mut().find(|j| j.id == job).ok_or_else(|| format!("no job {job}"))
    }

    pub fn job(&self, job: u64) -> Option<&Job> {
        self.jobs.iter().find(|j| j.id == job)
    }

    pub fn job_progress(&mut self, job: u64, progress: Option<f64>, done: Option<u64>, total: Option<u64>, label: Option<&str>) -> Result<(), String> {
        let j = self.job_mut(job)?;
        if let Some(p) = progress {
            j.progress = Some(p.clamp(0.0, 1.0));
        }
        if done.is_some() {
            j.done = done;
        }
        if total.is_some() {
            j.total = total;
        }
        if let Some(l) = label {
            j.label = l.to_owned();
        }
        j.control = None;
        Ok(())
    }

    pub fn job_pause(&mut self, job: u64, at: f64) -> Result<bool, String> {
        let paused = self.job_mut(job)?.pause(at);
        if paused && let Some(w) = self.workers.0.get_mut(&job) {
            w.pause();
        }
        Ok(paused)
    }

    pub fn job_resume(&mut self, job: u64, at: f64) -> Result<bool, String> {
        let resumed = self.job_mut(job)?.resume(at);
        if resumed && let Some(w) = self.workers.0.get_mut(&job) {
            w.resume();
        }
        Ok(resumed)
    }

    /// Stops the job: the artifact keeps its last build, with a note.
    pub fn job_cancel(&mut self, job: u64) -> Result<(), String> {
        let i = self.jobs.iter().position(|j| j.id == job).ok_or_else(|| format!("no job {job}"))?;
        let j = self.jobs.remove(i);
        if let Some(mut w) = self.workers.0.remove(&job) {
            w.cancel();
        }
        if let Some(n) = self.nodes.get_mut(&j.artifact) {
            n.note = Some(format!("{} cancelled", j.label));
        }
        Ok(())
    }

    /// Ends a job: a success builds the artifact, a failure keeps the last build and says why.
    pub fn job_end(&mut self, job: u64, error: Option<&str>, b: Build) -> Result<Option<Built>, String> {
        let i = self.jobs.iter().position(|j| j.id == job).ok_or_else(|| format!("no job {job}"))?;
        let artifact = self.jobs[i].artifact.clone();
        self.jobs.remove(i);
        self.workers.0.remove(&job);
        self.finish(&artifact, error, b)
    }

    fn finish(&mut self, artifact: &str, error: Option<&str>, b: Build) -> Result<Option<Built>, String> {
        match error {
            None => self.produce(artifact, b).map(Some),
            Some(e) => {
                let n = self.node_mut(artifact)?;
                n.error = Some(e.to_owned());
                Ok(None)
            }
        }
    }

    /// Hands a job's work to a Rust worker: `tick` polls it, and pause, resume and cancel reach
    /// it.
    pub fn attach(&mut self, job: u64, worker: Box<dyn Worker>) -> Result<(), String> {
        let pausable = worker.pausable();
        self.job_mut(job)?.pausable = pausable;
        self.workers.0.insert(job, worker);
        Ok(())
    }

    /// Polls every attached worker; answers the jobs that ended.
    pub fn tick(&mut self) -> Vec<u64> {
        let ids: Vec<u64> = self.workers.0.keys().copied().collect();
        let mut ended = Vec::new();
        for id in ids {
            let Some(p) = self.workers.0.get_mut(&id).map(|w| w.poll()) else { continue };
            let _ = self.job_progress(id, p.progress, p.done, p.total, p.label.as_deref());
            if let Some(result) = p.finished {
                let _ = match result {
                    Ok(summary) => self.job_end(id, None, Build { summary, ..Build::default() }),
                    Err(e) => self.job_end(id, Some(&e), Build::default()),
                };
                ended.push(id);
            }
        }
        ended
    }

    // MARK: Tree and selection

    pub fn tree_report(&mut self, stage: &str, items: Vec<TreeItem>) -> Result<(), String> {
        self.graph.stage(stage).ok_or_else(|| format!("unknown stage {stage}"))?;
        self.trees.report(stage, items);
        Ok(())
    }

    pub fn set_flags(&mut self, id: &str, visible: Option<bool>, locked: Option<bool>) -> Flags {
        self.trees.set_flags(id, visible, locked)
    }

    /// The browser rows of `stage`: its artifacts, then what the workspace reported under
    /// them, depth first, each with its eye and lock (`shown` and `held` follow the parents).
    pub fn tree(&self, stage: &str) -> Result<Value, String> {
        self.graph.stage(stage).ok_or_else(|| format!("unknown stage {stage}"))?;
        let roots = self.own(stage);
        let items = self.trees.items.get(stage).map(Vec::as_slice).unwrap_or(&[]);
        let ids: BTreeSet<&str> = items.iter().map(|i| i.id.as_str()).chain(roots.iter().copied()).collect();
        let parent_of = |i: &TreeItem| -> String {
            i.parent
                .as_deref()
                .filter(|p| ids.contains(p) && *p != i.id)
                .or(i.artifact.as_deref().filter(|a| roots.contains(a)))
                .or(roots.first().copied())
                .unwrap_or("")
                .to_owned()
        };
        let mut children: BTreeMap<String, Vec<&TreeItem>> = BTreeMap::new();
        for i in items {
            children.entry(parent_of(i)).or_default().push(i);
        }
        let selected: BTreeSet<&str> = self.trees.selection.ids.iter().map(String::as_str).collect();
        let mut rows = Vec::new();
        let mut visited = BTreeSet::new();
        struct Walk<'a> {
            flow: &'a Flow,
            children: &'a BTreeMap<String, Vec<&'a TreeItem>>,
            selected: &'a BTreeSet<&'a str>,
            rows: &'a mut Vec<Value>,
            visited: &'a mut BTreeSet<String>,
        }
        impl Walk<'_> {
            fn under(&mut self, id: &str, depth: usize, shown: bool, held: bool) {
                let children = self.children;
                for item in children.get(id).map(Vec::as_slice).unwrap_or(&[]) {
                    if !self.visited.insert(item.id.clone()) {
                        continue;
                    }
                    let flags = self.flow.trees.flags(&item.id);
                    let (s, h) = (shown && flags.visible, held || flags.locked);
                    self.rows.push(json!({
                        "id": item.id, "name": item.name, "kind": item.kind, "detail": item.detail, "depth": depth, "parent": if id.is_empty() { Value::Null } else { Value::from(id) },
                        "children": children.get(&item.id).map_or(0, Vec::len),
                        "visible": flags.visible, "locked": flags.locked, "shown": s, "held": h,
                        "selected": self.selected.contains(item.id.as_str()), "links": item.links,
                    }));
                    self.under(&item.id, depth + 1, s, h);
                }
            }
        }
        for r in &roots {
            let flags = self.trees.flags(r);
            let a = self.graph.artifact(r).expect("own artifact");
            rows.push(json!({
                "id": r, "name": a.name, "kind": "artifact", "detail": if self.node(r).active > 0 { Some(self.revision_name(r, self.node(r).active)) } else { None },
                "depth": 0, "parent": Value::Null, "children": children.get(*r).map_or(0, Vec::len),
                "visible": flags.visible, "locked": flags.locked, "shown": flags.visible, "held": flags.locked,
                "selected": selected.contains(r), "status": self.status(r).name(), "links": [],
            }));
            Walk { flow: self, children: &children, selected: &selected, rows: &mut rows, visited: &mut visited }.under(r, 1, flags.visible, flags.locked);
        }
        // A stage with no artifact of its own in this product's graph (the hand's Generate,
        // which has no frame) still lists what its workspace reported, from the top.
        if roots.is_empty() {
            Walk { flow: self, children: &children, selected: &selected, rows: &mut rows, visited: &mut visited }.under("", 0, true, false);
        }
        Ok(json!({"stage": stage, "rows": rows}))
    }

    pub fn select(&mut self, stage: &str, ids: Vec<String>, anchor: Option<[f64; 3]>) -> Result<(), String> {
        if !stage.is_empty() {
            self.graph.stage(stage).ok_or_else(|| format!("unknown stage {stage}"))?;
        }
        self.trees.selection = Selection { stage: stage.to_owned(), ids, anchor };
        Ok(())
    }

    pub fn selection(&self) -> Value {
        self.trees.selection_json(&self.stage_order())
    }

    /// One row per artifact for PIPELINE OUTPUTS: state, reason and action.
    pub fn outputs(&self) -> Value {
        Value::Array(
            self.graph
                .artifacts
                .iter()
                .map(|a| {
                    let n = self.node(&a.id);
                    json!({
                        "id": a.id, "stage": a.stage, "name": a.name, "label": a.label,
                        "revision": n.active,
                        "revision_name": if n.active > 0 { Some(self.revision_name(&a.id, n.active)) } else { None },
                        "status": self.status(&a.id).name(),
                        "reason": self.reason(&a.id),
                        "action": self.action(&a.id),
                    })
                })
                .collect(),
        )
    }

    // MARK: State and commands

    /// The whole pipeline as the front ends draw it.
    pub fn state(&self) -> Value {
        self.state_at(now())
    }

    pub fn state_at(&self, at: f64) -> Value {
        let nodes: Vec<Value> = self
            .graph
            .artifacts
            .iter()
            .map(|a| {
                let n = self.node(&a.id);
                let built = n.current();
                json!({
                    "id": a.id,
                    "stage": a.stage,
                    "name": a.name,
                    "label": a.label,
                    "revision": n.active,
                    "revision_name": if n.active > 0 { Some(self.revision_name(&a.id, n.active)) } else { None },
                    "revisions": n.revisions.len(),
                    "status": self.status(&a.id).name(),
                    "summary": built.map_or("", |r| r.summary.as_str()),
                    "from": built.and_then(|r| r.from.clone()),
                    "data": built.map_or(Value::Null, |r| r.data.clone()),
                    "error": n.error,
                    "note": n.note,
                    "reason": self.reason(&a.id),
                    "action": self.action(&a.id),
                    "job": self.job_on(&a.id).map(|j| j.to_json(at)),
                    "consumes": a.inputs.iter().map(|i| {
                        let seen = built.and_then(|r| r.seen.get(i).copied()).unwrap_or(0);
                        let now = self.node(i).active;
                        json!({
                            "id": i, "seen": seen, "now": now, "current": n.active == 0 || seen == now,
                            "seen_name": self.revision_name(i, seen), "now_name": self.revision_name(i, now),
                        })
                    }).collect::<Vec<_>>(),
                    "feeds": self.graph.consumers(&a.id),
                })
            })
            .collect();
        let stages: Vec<Value> = self
            .graph
            .stages
            .iter()
            .map(|s| {
                let own = self.own(&s.id);
                let stale = own.iter().filter(|a| self.status(a) == Status::Stale).count();
                let worst = own.iter().copied().max_by_key(|a| self.status(a));
                json!({
                    "id": s.id, "name": s.name, "status": self.stage_status(&s.id).name(), "artifacts": own, "stale": stale,
                    "reason": worst.map(|a| self.reason(a)).unwrap_or_default(),
                    "action": worst.map_or(Value::Null, |a| self.action(a)),
                })
            })
            .collect();
        let jobs: Vec<Value> = self.jobs.iter().map(|j| j.to_json(at)).collect();
        json!({"product": self.graph.product, "stages": stages, "nodes": nodes, "jobs": jobs, "selection": self.selection()})
    }

    /// One command from a front end, `{"op": ..., ...}`. Answers `{"ok": true, ...}` or
    /// `{"error": ...}`. Ops:
    ///
    /// - builds: `produce` {artifact, summary?, fingerprint?, amend_within?, data?, source?},
    ///   `promote` {artifact, from, summary?, data?}, `activate` {artifact, revision}
    /// - reads: `revisions` {artifact}, `diff` {artifact, from?, to?}, `plan_update`,
    ///   `downstream` {artifact}, `outputs`, `tree` {stage}, `selection`, `commands` {stage?},
    ///   `search` {query, stage?, limit?}, `export`
    /// - jobs (by {job} or {artifact}): `job_start` {artifact, label?, verb?, total?,
    ///   expected?, pausable?}, `job_progress` {progress?, done?, total?, label?}, `job_pause`,
    ///   `job_resume`, `job_cancel`, `job_end` {error?, summary?, data?}
    /// - tree: `tree_report` {stage, items}, `tree_set` {id, visible?, locked?}
    /// - selection: `select` {stage, ids, anchor?}
    /// - project: `set_product` {name}, `set_graph` {graph}, `import` {doc}, `save` {path},
    ///   `open` {path}, `reset`
    ///
    /// Any command may carry `now` (seconds since the epoch) to fix the clock, for tests.
    pub fn command(&mut self, cmd: &Value) -> Value {
        if let Some(v) = self.query(cmd) {
            return v;
        }
        let at = cmd["now"].as_f64().unwrap_or_else(now);
        let id = cmd["artifact"].as_str().unwrap_or("");
        let text = |k: &str| cmd[k].as_str();
        let built = |r: Result<Built, String>| done(r.map(|b| json!({"revision": b.revision(), "result": b.word()})));
        match cmd["op"].as_str().unwrap_or("") {
            "produce" => built(self.produce_at(id, Build::from_json(cmd), at)),
            "promote" => built(self.promote(id, text("from").unwrap_or("a result"), Build::from_json(cmd))),
            "activate" => done(self.activate(id, cmd["revision"].as_u64().unwrap_or(0)).map(|_| json!({}))),
            "job_start" => {
                let verb = text("verb").unwrap_or("Working");
                let label = text("label").unwrap_or(verb);
                done(self.job_start(id, verb, label, at).and_then(|job| {
                    let j = self.job_mut(job)?;
                    j.total = cmd["total"].as_u64();
                    j.expected = cmd["expected"].as_f64();
                    j.pausable = cmd["pausable"].as_bool().unwrap_or(false);
                    Ok(json!({"job": job}))
                }))
            }
            "job_progress" | "job_pause" | "job_resume" | "job_cancel" | "job_end" => {
                let op = cmd["op"].as_str().unwrap_or("");
                let job = match self.job_index(cmd) {
                    Ok(i) => self.jobs[i].id,
                    // A job that ended or was cancelled may still report: it is let go quietly.
                    Err(_) if cmd["job"].is_u64() => return ok(json!({"ignored": true})),
                    // Ending work on an artifact that had no job is a plain build (or failure).
                    Err(_) if op == "job_end" && self.def(id).is_ok() => {
                        return done(self.finish(id, text("error"), Build::from_json(cmd)).map(|b| json!({"revision": b.map(Built::revision)})));
                    }
                    Err(e) => return json!({"error": e}),
                };
                match op {
                    "job_progress" => done(
                        self.job_progress(job, cmd["progress"].as_f64(), cmd["done"].as_u64(), cmd["total"].as_u64(), text("label")).map(|_| json!({"job": job})),
                    ),
                    "job_pause" => done(self.job_pause(job, at).map(|c| json!({"job": job, "changed": c}))),
                    "job_resume" => done(self.job_resume(job, at).map(|c| json!({"job": job, "changed": c}))),
                    "job_cancel" => done(self.job_cancel(job).map(|_| json!({"job": job}))),
                    _ => done(self.job_end(job, text("error"), Build::from_json(cmd)).map(|b| json!({"job": job, "revision": b.map(Built::revision)}))),
                }
            }
            "tree_report" => {
                let items: Result<Vec<TreeItem>, _> = serde_json::from_value(cmd["items"].clone());
                match items {
                    Ok(items) => done(self.tree_report(text("stage").unwrap_or(""), items).map(|_| json!({}))),
                    Err(e) => json!({"error": format!("items: {e}")}),
                }
            }
            "tree_set" => {
                let f = self.set_flags(text("id").unwrap_or(""), cmd["visible"].as_bool(), cmd["locked"].as_bool());
                ok(json!({"visible": f.visible, "locked": f.locked}))
            }
            "select" => {
                let ids: Vec<String> = cmd["ids"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()).unwrap_or_default();
                let anchor = cmd["anchor"].as_array().filter(|a| a.len() == 3).map(|a| [0, 1, 2].map(|k| a[k].as_f64().unwrap_or(0.0)));
                done(self.select(text("stage").unwrap_or(""), ids, anchor).map(|_| json!({"selection": self.selection()})))
            }
            "set_product" => {
                self.graph.product = text("name").unwrap_or("Untitled").to_owned();
                ok(json!({}))
            }
            "set_graph" => match text("preset")
                .map(|p| Graph::preset(p).ok_or_else(|| format!("no graph preset {p:?}")))
                .unwrap_or_else(|| serde_json::from_value::<Graph>(cmd["graph"].clone()).map_err(|e| e.to_string()))
                .map(|mut g| {
                    // A preset keeps the product's name.
                    if text("preset").is_some() {
                        g.product = self.graph.product.clone();
                    }
                    g
                })
                .and_then(|g| self.set_graph(g))
            {
                Ok(()) => ok(json!({})),
                Err(e) => json!({"error": e}),
            },
            "import" => done(persist::from_doc(&cmd["doc"]).map(|f| {
                *self = f;
                json!({})
            })),
            "save" => done(persist::write_into(std::path::Path::new(text("path").unwrap_or("")), self).map(|_| json!({}))),
            "open" => done(persist::read_from(std::path::Path::new(text("path").unwrap_or(""))).map(|f| {
                let found = f.is_some();
                *self = f.unwrap_or_default();
                json!({"found": found})
            })),
            "reset" => {
                *self = Self::new();
                ok(json!({}))
            }
            op => json!({"error": format!("unknown op {op:?}")}),
        }
    }

    /// The commands that only read (`revisions`, `diff`, `plan_update`, `downstream`,
    /// `outputs`, `tree`, `selection`, `commands`, `search`, `export`, `state`); None for any
    /// other op.
    pub fn query(&self, cmd: &Value) -> Option<Value> {
        let at = cmd["now"].as_f64().unwrap_or_else(now);
        let id = cmd["artifact"].as_str().unwrap_or("");
        let text = |k: &str| cmd[k].as_str();
        Some(match cmd["op"].as_str().unwrap_or("") {
            "revisions" => done(self.revisions(id).map(|v| json!({"list": v}))),
            "diff" => done(self.diff(id, cmd["from"].as_u64(), cmd["to"].as_u64()).map(|v| json!({"diff": v}))),
            "plan_update" => done(self.def(id).map(|_| json!({"order": self.plan_update(id)}))),
            "downstream" => done(self.def(id).map(|_| json!({"order": self.downstream(id)}))),
            "outputs" => ok(json!({"outputs": self.outputs()})),
            "tree" => done(self.tree(text("stage").unwrap_or("")).map(|t| json!({"tree": t}))),
            "selection" => ok(json!({"selection": self.selection()})),
            "commands" => ok(json!({"commands": commands::list(text("stage"))})),
            "search" => ok(json!({"results": commands::search(text("query").unwrap_or(""), text("stage"), cmd["limit"].as_u64().unwrap_or(20) as usize)})),
            "export" => ok(json!({"doc": persist::to_doc(self)})),
            "state" => ok(json!({"state": self.state_at(at)})),
            _ => return None,
        })
    }

    /// Changes the project's graph, keeping the revisions of the artifacts still in it.
    pub fn set_graph(&mut self, graph: Graph) -> Result<(), String> {
        graph.validate()?;
        let mut nodes = std::mem::take(&mut self.nodes);
        self.nodes = graph.artifacts.iter().map(|a| (a.id.clone(), nodes.remove(&a.id).unwrap_or_default())).collect();
        self.jobs.retain(|j| graph.artifact(&j.artifact).is_some());
        self.graph = graph;
        Ok(())
    }

    /// A worked example for previews and screenshots: the 3 inch racer half way through its
    /// second frame, with a study running.
    pub fn sample() -> Self {
        let mut f = Self::new();
        f.graph.product = "Racer 3in".into();
        let t = 1_780_000_000.0;
        let b = |s: &str| Build::summary(s);
        for _ in 0..12 {
            let _ = f.produce_at("design.model", b("Arms, motor pods, battery bay"), t);
        }
        for _ in 0..2 {
            let _ = f.produce_at("electronics.board", b("F4 flight controller, 4 layers"), t);
        }
        let _ = f.produce_at("electronics.board", b("36 x 36 mm, 112 nets, DRC passed"), t);
        for _ in 0..11 {
            let _ = f.produce_at("generate.frame", b("Outcome 9, 161 g"), t);
        }
        let _ = f.produce_at("assemble.assembly", b("Frame v11, Board rev C, 4 motors"), t + 60.0);
        for _ in 0..4 {
            let _ = f.produce_at("simulate.flight", b("Gate course, wind 4 m/s"), t + 120.0);
        }
        for _ in 0..5 {
            let _ = f.produce_at("train.policy", b("PID + residual, held-out cost 0.41"), t + 180.0);
        }
        let _ = f.produce_at("render.shots", b("6 shots"), t + 200.0);
        let _ = f.promote("generate.frame", "Outcome 13", Build { data: json!({"mass_g": 153}), ..b("Outcome 13, 153 g") });
        if let Ok(j) = f.job_start("generate.frame", "Generating", "Frame study, 120 outcomes", now() - 90.0) {
            let _ = f.job_progress(j, None, Some(74), Some(120), None);
        }
        f.trees.report(
            "design",
            vec![
                TreeItem { id: "body:Frame".into(), name: "Frame".into(), kind: "body".into(), links: vec!["part:Frame".into()], detail: Some("153 g".into()), ..Default::default() },
                TreeItem { id: "body:Pods".into(), name: "Motor pods".into(), kind: "body".into(), ..Default::default() },
                TreeItem { id: "sketch:1".into(), name: "Arm profile".into(), kind: "sketch".into(), ..Default::default() },
            ],
        );
        f.trees.report(
            "electronics",
            vec![
                TreeItem { id: "ref:U1".into(), name: "U1 STM32F405".into(), kind: "component".into(), links: vec!["part:FC".into()], ..Default::default() },
                TreeItem { id: "ref:J1".into(), name: "J1 battery".into(), kind: "component".into(), ..Default::default() },
            ],
        );
        f.trees.report(
            "assemble",
            vec![
                TreeItem { id: "occ:Frame".into(), name: "Frame:1".into(), kind: "occurrence".into(), links: vec!["part:Frame".into()], ..Default::default() },
                TreeItem { id: "occ:FC".into(), name: "Flight controller:1".into(), kind: "occurrence".into(), links: vec!["part:FC".into()], ..Default::default() },
            ],
        );
        f.trees.selection = Selection { stage: "design".into(), ids: vec!["body:Frame".into()], anchor: Some([0.0, 0.0, 12.0]) };
        f
    }
}

/// `{"ok": true, ...extra}`.
fn ok(extra: Value) -> Value {
    let mut o = json!({"ok": true});
    if let (Some(m), Value::Object(extra)) = (o.as_object_mut(), extra) {
        m.extend(extra);
    }
    o
}

fn done(r: Result<Value, String>) -> Value {
    r.map(ok).unwrap_or_else(|e| json!({"error": e}))
}

#[cfg(test)]
mod tests;
