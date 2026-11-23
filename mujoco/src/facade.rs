//! The phys JSON facade on MuJoCo (feature `mujoco`): the same ops, parameters and reply
//! shapes as `viaform_phys::Phys` (`world_new`, `scenario_load`, `world_step`, `world_state`,
//! `set_controls`, `episode_record`, `wrench_history`, `batch_new`, `batch_step`,
//! `episode_start`, `job_poll`, `job_cancel`, `model_info`), plus `mjcf_export`. The model,
//! initial state and drives come from phys's own loader (`load.rs`), so a scenario means the
//! same thing on both engines. Differences: `solver` in replies carries MuJoCo's statistics,
//! `model_info` adds `engine` and `mujoco_version`, and the drone runs on phys only.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use rayon::prelude::*;
use serde_json::{Value, json};
use viaform_phys::error::codes;
use viaform_phys::scenario::DriveTrack;
use viaform_phys::world::ExtForce;
use viaform_phys::{PhysError, WrenchHistory};

use crate::load::{self, Built};
use crate::params;
use crate::world::{MjRecorder, MjWorld};

/// A scenario on MuJoCo: the world plus phys's drive schedule.
pub struct MjScenario {
    pub world: MjWorld,
    pub id: String,
    pub drives: Vec<DriveTrack>,
    pub duration: f64,
    pub control_dt: f64,
    pub latency: f64,
    pub objects: Vec<(String, usize)>,
    pub notes: Vec<String>,
    pub randomised: Value,
    pub joints: Vec<String>,
    pending: Vec<(f64, usize, f64)>,
    next_control: f64,
}

impl MjScenario {
    /// Advances to `t_end` (or the end), sampling the drives at the control rate and applying
    /// each command `latency` later: phys's `Loaded::advance`, step for step.
    pub fn advance(&mut self, t_end: f64) -> Result<(), PhysError> {
        let t_end = t_end.min(self.duration);
        let dt = self.world.settings.dt;
        while self.world.t + 0.5 * dt < t_end {
            let t = self.world.t;
            if t + 0.5 * dt >= self.next_control {
                for d in &self.drives {
                    if let Some(&(_, v)) = d.timeline.iter().rev().find(|(t0, _)| *t0 <= t + 1e-12) {
                        self.pending.push((t + self.latency, d.actuator, v));
                    }
                }
                self.next_control += self.control_dt;
            }
            let mut k = 0;
            while k < self.pending.len() {
                if self.pending[k].0 <= t + 1e-12 {
                    let (_, a, v) = self.pending.remove(k);
                    self.world.set_control(a, v);
                } else {
                    k += 1;
                }
            }
            self.world.step()?;
        }
        Ok(())
    }
}

enum Sim {
    World(Box<MjWorld>),
    Scenario(Box<MjScenario>),
}

impl Sim {
    fn world(&self) -> &MjWorld {
        match self {
            Sim::World(w) => w,
            Sim::Scenario(s) => &s.world,
        }
    }
    fn world_mut(&mut self) -> &mut MjWorld {
        match self {
            Sim::World(w) => w,
            Sim::Scenario(s) => &mut s.world,
        }
    }
    fn advance(&mut self, steps: usize) -> Result<(), PhysError> {
        match self {
            Sim::World(w) => w.run(steps),
            Sim::Scenario(s) => {
                let t = s.world.t + steps as f64 * s.world.settings.dt;
                s.advance(t)
            }
        }
    }
}

struct JobState {
    progress: f64,
    done: bool,
    error: Option<PhysError>,
    sim: Option<Sim>,
}

struct Job {
    state: Arc<Mutex<JobState>>,
    cancel: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

/// One facade instance (one handle on the C side) running MuJoCo.
#[derive(Default)]
pub struct MjPhys {
    sim: Option<Sim>,
    batch: Vec<MjWorld>,
    jobs: BTreeMap<u64, Job>,
    next_job: u64,
}

fn world_none() -> PhysError {
    PhysError::new(codes::NO_WORLD, "no world: call world_new first (or wait for the running job)")
}

fn f64s(v: &Value, what: &str) -> Result<Vec<f64>, PhysError> {
    v.as_array().ok_or_else(|| params(format!("{what} must be an array of numbers")))?.iter().map(|x| x.as_f64().ok_or_else(|| params(format!("{what} must be an array of numbers")))).collect()
}

fn norm(v: &[f64; 3]) -> f64 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

impl MjPhys {
    pub fn new() -> Self {
        MjPhys::default()
    }

    /// Runs one op.
    pub fn call(&mut self, op: &str, p: &Value) -> Result<Value, PhysError> {
        match op {
            "world_new" | "scenario_load" => self.world_new(p),
            "world_step" => self.world_step(p),
            "world_state" => self.world_state(),
            "set_controls" => self.set_controls(p),
            "episode_record" => self.episode_record(p),
            "wrench_history" => self.wrench_history(p),
            "batch_new" => self.batch_new(p),
            "batch_step" => self.batch_step(p),
            "episode_start" => self.episode_start(p),
            "job_poll" => self.job_poll(p),
            "job_cancel" => self.job_cancel(p),
            "model_info" => self.model_info(),
            "mjcf_export" => self.mjcf_export(p),
            _ => Err(PhysError::new(codes::UNKNOWN_OP, format!("unknown op {op}"))),
        }
    }

    fn sim(&self) -> Result<&Sim, PhysError> {
        self.sim.as_ref().ok_or_else(world_none)
    }

    fn sim_mut(&mut self) -> Result<&mut Sim, PhysError> {
        self.sim.as_mut().ok_or_else(world_none)
    }

    /// The current world (for the fast C entry points).
    pub fn world_mut(&mut self) -> Option<&mut MjWorld> {
        self.sim.as_mut().map(Sim::world_mut)
    }

    /// Advances the current world (a scenario follows its drives).
    pub fn step(&mut self, steps: usize) -> Result<(), PhysError> {
        self.sim_mut()?.advance(steps)
    }

    /// Link poses `[x, y, z, qw, qx, qy, qz]` per link; `None` without a world.
    pub fn poses_flat(&mut self, out: &mut [f64]) -> Option<usize> {
        self.world_mut().map(|w| w.poses_flat(out))
    }

    /// Number of links of the current world.
    pub fn nlinks(&self) -> Option<usize> {
        self.sim.as_ref().map(|s| s.world().nlinks())
    }

    /// Number of actuators of the current world.
    pub fn nact(&self) -> Option<usize> {
        self.sim.as_ref().map(|s| s.world().control.len())
    }

    /// Sets actuator controls in actuator order (finite values only); returns how many.
    pub fn set_controls_flat(&mut self, c: &[f64]) -> Option<usize> {
        let w = self.world_mut()?;
        let k = w.control.len().min(c.len());
        for (a, v) in c.iter().take(k).enumerate() {
            if v.is_finite() {
                w.set_control(a, *v);
            }
        }
        Some(k)
    }

    fn world_new(&mut self, p: &Value) -> Result<Value, PhysError> {
        let sim = match load::build(p)? {
            Built::World(w) => Sim::World(Box::new(MjWorld::from_phys(&w)?)),
            Built::Scenario(s) => {
                let world = MjWorld::from_phys(&s.world)?;
                Sim::Scenario(Box::new(MjScenario {
                    world,
                    id: s.id.clone(),
                    drives: s.drives.clone(),
                    duration: s.duration,
                    control_dt: s.control_dt,
                    latency: s.latency,
                    objects: s.objects.clone(),
                    notes: s.notes.clone(),
                    randomised: s.randomised.clone(),
                    joints: s.joints.clone(),
                    pending: vec![],
                    next_control: 0.0,
                }))
            }
        };
        self.sim = Some(sim);
        self.batch.clear();
        self.model_info()
    }

    fn world_step(&mut self, p: &Value) -> Result<Value, PhysError> {
        let dt = self.sim()?.world().settings.dt;
        let steps = match (p.get("steps").and_then(Value::as_u64), p.get("seconds").and_then(Value::as_f64)) {
            (Some(n), _) => n as usize,
            (None, Some(s)) => (s / dt).round().max(0.0) as usize,
            _ => 1,
        };
        self.step(steps)?;
        let w = self.sim()?.world();
        Ok(json!({"t": w.t, "steps": w.steps, "solver": solver(w)}))
    }

    fn world_state(&mut self) -> Result<Value, PhysError> {
        let w = self.sim_mut()?.world_mut();
        let mut poses = vec![0.0; 7 * w.nlinks()];
        w.poses_flat(&mut poses);
        let contacts: Vec<Value> = w.contacts().iter().map(|c| json!({"bodies": [c.b1, c.b2], "point": c.p, "normal": c.n, "depth": -c.dist, "force": c.f})).collect();
        Ok(json!({"t": w.t, "q": w.q(), "v": w.v(), "poses": poses, "efforts": w.effort, "contacts": contacts, "solver": solver(w)}))
    }

    fn set_controls(&mut self, p: &Value) -> Result<Value, PhysError> {
        let w = self.sim_mut()?.world_mut();
        if let Some(c) = p.get("controls") {
            let c = f64s(c, "controls")?;
            if c.len() != w.control.len() {
                return Err(params(format!("controls: expected {} values", w.control.len())));
            }
            for (a, v) in c.iter().enumerate() {
                w.set_control(a, *v);
            }
        }
        if let Some(a) = p.get("actuator") {
            let idx = match a {
                Value::Number(n) => n.as_u64().map(|x| x as usize),
                Value::String(s) => w.model.kin.actuators.iter().position(|x| &x.name == s),
                _ => None,
            }
            .filter(|&i| i < w.control.len())
            .ok_or_else(|| PhysError::new(codes::UNKNOWN_NAME, format!("no actuator {a}")))?;
            let v = p.get("value").and_then(Value::as_f64).ok_or_else(|| params("value must be a number"))?;
            w.set_control(idx, v);
        }
        if p.get("rotors").is_some() {
            return Err(PhysError::new(codes::ENGINE_UNSUPPORTED, "rotors run on the phys engine only"));
        }
        if let Some(f) = p.get("forces") {
            w.ext = serde_json::from_value::<Vec<ExtForce>>(f.clone()).map_err(|e| params(format!("forces: {e}")))?;
        }
        Ok(json!({"t": w.t}))
    }

    fn episode_record(&mut self, p: &Value) -> Result<Value, PhysError> {
        let w = self.sim_mut()?.world_mut();
        if p.get("get").and_then(Value::as_bool).unwrap_or(false) {
            return Ok(w.recorder.as_ref().map_or(Value::Null, |r| serde_json::to_value(&r.episode).unwrap_or(Value::Null)));
        }
        let every = p.get("every").and_then(Value::as_u64).unwrap_or(1);
        let bodies: Vec<usize> = match p.get("bodies").and_then(Value::as_array) {
            Some(list) => list.iter().filter_map(|b| b.as_u64().map(|x| x as usize).or_else(|| b.as_str().and_then(|n| w.model.kin.link_index(n)))).collect(),
            None => vec![],
        };
        w.recorder = Some(MjRecorder::new(every, bodies));
        Ok(json!({"recording": true, "every": every}))
    }

    fn wrench_history(&mut self, p: &Value) -> Result<Value, PhysError> {
        let w = self.sim()?.world();
        let all: &[WrenchHistory] = w.recorder.as_ref().map_or(&[], |r| r.wrenches.as_slice());
        let body = p.get("body").and_then(Value::as_str);
        let source = p.get("source").and_then(Value::as_str);
        let pick = p.get("pick").and_then(Value::as_str).unwrap_or("envelope");
        let at_t = p.get("t").and_then(Value::as_f64);
        let mut out = vec![];
        for h in all.iter().filter(|h| body.is_none_or(|b| h.body == b) && source.is_none_or(|s| h.source == s)) {
            let picked = match pick {
                "envelope" => h.clone(),
                "peak" | "at" => {
                    let k = if pick == "peak" {
                        (0..h.t.len()).max_by(|&a, &b| norm(&h.force[a]).total_cmp(&norm(&h.force[b])))
                    } else {
                        let t = at_t.ok_or_else(|| params("pick at needs t"))?;
                        (0..h.t.len()).min_by(|&a, &b| (h.t[a] - t).abs().total_cmp(&(h.t[b] - t).abs()))
                    };
                    match k {
                        Some(k) => WrenchHistory { body: h.body.clone(), source: h.source.clone(), t: vec![h.t[k]], force: vec![h.force[k]], torque: vec![h.torque[k]], at: vec![h.at[k]], accel: vec![h.accel[k]] },
                        None => h.clone(),
                    }
                }
                other => return Err(params(format!("pick {other}: envelope, peak or at"))),
            };
            out.push(picked);
        }
        Ok(serde_json::to_value(out).unwrap_or(Value::Null))
    }

    fn batch_new(&mut self, p: &Value) -> Result<Value, PhysError> {
        let n = p.get("n").and_then(Value::as_u64).ok_or_else(|| params("n must be a positive integer"))? as usize;
        if n == 0 || n > 65536 {
            return Err(params("n must be between 1 and 65536"));
        }
        let w = self.sim()?.world();
        let mut proto = w.clone();
        proto.recorder = None;
        let (nq, na) = (w.model.nq(), w.control.len());
        self.batch = vec![proto; n];
        Ok(json!({"n": n, "nq": nq, "na": na}))
    }

    fn batch_step(&mut self, p: &Value) -> Result<Value, PhysError> {
        if self.batch.is_empty() {
            return Err(PhysError::new(codes::NO_BATCH, "no batch: call batch_new first"));
        }
        if let Some(c) = p.get("controls") {
            let c = f64s(c, "controls")?;
            let na = self.batch[0].control.len();
            if c.len() != self.batch.len() * na {
                return Err(params(format!("controls: expected {} values ({} worlds x {na} actuators)", self.batch.len() * na, self.batch.len())));
            }
            for (w, c) in self.batch.iter_mut().zip(c.chunks(na.max(1))) {
                for (a, v) in c.iter().enumerate() {
                    w.set_control(a, *v);
                }
            }
        }
        let steps = p.get("steps").and_then(Value::as_u64).unwrap_or(1) as usize;
        self.batch.par_iter_mut().with_min_len(8).map(|w| w.run(steps)).collect::<Result<Vec<_>, _>>()?;
        Ok(json!({"q": self.batch.iter().flat_map(|w| w.q()).collect::<Vec<f64>>()}))
    }

    fn episode_start(&mut self, p: &Value) -> Result<Value, PhysError> {
        let sim = self.sim.take().ok_or_else(world_none)?;
        let dt = sim.world().settings.dt;
        let seconds = match (p.get("seconds").and_then(Value::as_f64), &sim) {
            (Some(s), _) => s,
            (None, Sim::Scenario(s)) => s.duration - s.world.t,
            (None, Sim::World(_)) => 1.0,
        };
        let steps = (seconds / dt).round().max(0.0) as usize;
        let state = Arc::new(Mutex::new(JobState { progress: 0.0, done: false, error: None, sim: None }));
        let cancel = Arc::new(AtomicBool::new(false));
        let (st, cn) = (state.clone(), cancel.clone());
        let handle = std::thread::spawn(move || {
            let mut sim = sim;
            let mut done = 0;
            let mut err = None;
            while done < steps && !cn.load(Ordering::Relaxed) {
                let n = 100usize.min(steps - done);
                let r = sim.advance(n);
                done += n;
                if let Err(e) = r {
                    err = Some(e);
                    break;
                }
                if let Ok(mut g) = st.lock() {
                    g.progress = done as f64 / steps.max(1) as f64;
                }
            }
            if let Ok(mut g) = st.lock() {
                g.done = true;
                g.error = err;
                g.sim = Some(sim);
            }
        });
        let id = self.next_job;
        self.next_job += 1;
        self.jobs.insert(id, Job { state, cancel, handle: Some(handle) });
        Ok(json!({"job": id, "steps": steps}))
    }

    fn job(&self, p: &Value) -> Result<u64, PhysError> {
        let id = p.get("id").and_then(Value::as_u64).ok_or_else(|| params("id must be a job id"))?;
        if !self.jobs.contains_key(&id) {
            return Err(PhysError::new(codes::NO_JOB, format!("no job {id}")));
        }
        Ok(id)
    }

    fn job_poll(&mut self, p: &Value) -> Result<Value, PhysError> {
        let id = self.job(p)?;
        let job = self.jobs.get_mut(&id).expect("checked");
        let (progress, done) = {
            let g = job.state.lock().map_err(|_| PhysError::new(codes::NO_JOB, "job state poisoned"))?;
            (g.progress, g.done)
        };
        if !done {
            return Ok(json!({"job": id, "state": "running", "progress": progress}));
        }
        if let Some(h) = job.handle.take() {
            let _ = h.join();
        }
        let mut g = job.state.lock().map_err(|_| PhysError::new(codes::NO_JOB, "job state poisoned"))?;
        if let Some(sim) = g.sim.take() {
            self.sim = Some(sim);
        }
        let error = g.error.take();
        drop(g);
        self.jobs.remove(&id);
        let t = self.sim.as_ref().map_or(0.0, |s| s.world().t);
        match error {
            Some(e) => Ok(json!({"job": id, "state": "failed", "error": e.message, "code": e.code, "t": t})),
            None => Ok(json!({"job": id, "state": "done", "progress": 1.0, "t": t})),
        }
    }

    fn job_cancel(&mut self, p: &Value) -> Result<Value, PhysError> {
        let id = self.job(p)?;
        self.jobs[&id].cancel.store(true, Ordering::Relaxed);
        Ok(json!({"job": id, "cancelling": true}))
    }

    fn model_info(&self) -> Result<Value, PhysError> {
        let sim = self.sim()?;
        let w = sim.world();
        let m = &w.model;
        let mut notes = m.notes.clone();
        notes.extend(w.map.notes.iter().cloned());
        let mut out = json!({
            "links": m.kin.links.iter().map(|l| l.name.clone()).collect::<Vec<_>>(),
            "joints": m.kin.joints.iter().map(|j| json!({"name": j.name, "kind": j.kind, "parent": j.parent})).collect::<Vec<_>>(),
            "actuators": m.kin.actuators.iter().map(|a| a.name.clone()).collect::<Vec<_>>(),
            "mass_kg": m.mass,
            "nq": m.nq(), "nv": m.nv(), "dt": w.settings.dt, "notes": notes,
            "engine": "mujoco", "mujoco_version": crate::sim::version(),
        });
        if let Sim::Scenario(s) = sim {
            out["scenario"] = json!({"id": s.id, "duration_s": s.duration, "control_dt": s.control_dt, "latency_s": s.latency, "objects": s.objects, "randomised": s.randomised, "notes": s.notes, "assembly_joints": s.joints});
        }
        Ok(out)
    }

    /// `{path?}`: the current world's MJCF (and writes it to `path` when given).
    fn mjcf_export(&self, p: &Value) -> Result<Value, PhysError> {
        let xml = &self.sim()?.world().xml;
        crate::write_xml(p, xml)
    }
}

fn solver(w: &MjWorld) -> Value {
    json!({"engine": "mujoco", "iterations": w.sim.solver_iterations(), "constraints": w.sim.nefc()})
}

impl Drop for MjPhys {
    fn drop(&mut self) {
        for job in self.jobs.values_mut() {
            job.cancel.store(true, Ordering::Relaxed);
            if let Some(h) = job.handle.take() {
                let _ = h.join();
            }
        }
    }
}
