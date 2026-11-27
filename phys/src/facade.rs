//! The JSON facade (RUST-ENGINES 9.1): one call `(op, params) -> reply` for the Swift and
//! Electron front ends through the C ABI (`bridge/src/phys.rs`). Replies are
//! `{"ok": ...}` or `{"error", "code"}` with the codes of [`crate::error`].
//!
//! Ops:
//! - `world_new` `{builtin | model | drone | assembly + scenario, settings, actuator, ground,
//!   engine}` (`engine` "phys", the default, or "mujoco", which the C bridge routes to
//!   viaform-mujoco):
//!   the current world. `builtin` is `so101_arm` or `hand5`; `model` a kin model; `actuator`
//!   the kind for every motor (default an STS3215 class servo); `drone` a sim `QuadParams`
//!   (plus `state`, `power`); `assembly` + `scenario` load a scenario (alias `scenario_load`).
//! - `world_step` `{steps | seconds}`: advances (a scenario follows its drives).
//! - `world_state`: time, q, v, link poses `[x, y, z, qw, qx, qy, qz]`, efforts, contacts,
//!   solver stats, drone state and powertrain when present.
//! - `set_controls` `{controls: [..]}` (actuator order), `{actuator: name | index, value}`,
//!   `{rotors: [rad/s x 4]}`, `{forces: [{link, force, point, torque, until}]}`.
//! - `episode_record` `{every, bodies}` starts recording; `{get: true}` returns the episode.
//! - `wrench_history` `{body, source, pick: envelope | peak | at, t}`: the G3 histories.
//! - `batch_new` `{n}` copies the current world; `batch_step` `{steps, controls}` steps all and
//!   returns `q` (row-major `n x nq`).
//! - `episode_start` `{seconds}` runs the current world on a thread; `job_poll` `{id}`,
//!   `job_cancel` `{id}`; the world comes back when the job ends.
//! - `model_info`: links, joints, actuators, sizes.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use crate::actuator::{ActuatorKind, ServoParams};
use crate::batch::Batch;
use crate::drone::{self, DroneState, QuadSpec};
use crate::error::{PhysError, params};
use crate::model::ModelBuilder;
use crate::record::{Recorder, WrenchHistory};
use crate::scenario::{self, Loaded};
use crate::world::{ExtForce, Settings, World};

/// The current simulation: a bare world, or a scenario (a world with drives).
enum Sim {
    World(Box<World>),
    Scenario(Box<Loaded>),
}

impl Sim {
    fn world(&self) -> &World {
        match self {
            Sim::World(w) => w,
            Sim::Scenario(s) => &s.world,
        }
    }
    fn world_mut(&mut self) -> &mut World {
        match self {
            Sim::World(w) => w,
            Sim::Scenario(s) => &mut s.world,
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

/// One facade instance (one handle on the C side).
#[derive(Default)]
pub struct Phys {
    sim: Option<Sim>,
    drone: bool,
    batch: Option<Batch>,
    jobs: BTreeMap<u64, Job>,
    next_job: u64,
}

fn world_none() -> PhysError {
    PhysError::new("world.none", "no world: call world_new first (or wait for the running job)")
}

fn f64s(v: &Value, what: &str) -> Result<Vec<f64>, PhysError> {
    v.as_array().ok_or_else(|| params(format!("{what} must be an array of numbers")))?.iter().map(|x| x.as_f64().ok_or_else(|| params(format!("{what} must be an array of numbers")))).collect()
}

impl Phys {
    pub fn new() -> Self {
        Phys::default()
    }

    /// Runs one op.
    pub fn call(&mut self, op: &str, p: &Value) -> Result<Value, PhysError> {
        match op {
            "world_new" => self.world_new(p),
            "scenario_load" => self.world_new(p),
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
            _ => Err(PhysError::new("op.unknown", format!("unknown op {op}"))),
        }
    }

    fn sim(&self) -> Result<&Sim, PhysError> {
        self.sim.as_ref().ok_or_else(world_none)
    }

    fn sim_mut(&mut self) -> Result<&mut Sim, PhysError> {
        self.sim.as_mut().ok_or_else(world_none)
    }

    /// The current world (for the fast C entry points).
    pub fn world_mut(&mut self) -> Option<&mut World> {
        self.sim.as_mut().map(Sim::world_mut)
    }

    /// Advances the current world (a scenario follows its drives).
    pub fn step(&mut self, steps: usize) -> Result<(), PhysError> {
        match self.sim_mut()? {
            Sim::World(w) => w.run(steps),
            Sim::Scenario(s) => {
                let t = s.world.t + steps as f64 * s.world.settings.dt;
                s.advance(t)
            }
        }
    }

    fn world_new(&mut self, p: &Value) -> Result<Value, PhysError> {
        // `engine`: "phys" (default) or "mujoco"; MuJoCo runs in viaform-mujoco, which the C
        // bridge selects before this facade sees the call.
        let engine = p.get("engine").and_then(Value::as_str).or_else(|| p.get("scenario").and_then(|s| s.get("engine")).and_then(Value::as_str)).unwrap_or("phys");
        match engine {
            "phys" => {}
            "mujoco" => return Err(PhysError::new(crate::error::codes::ENGINE_UNAVAILABLE, "engine mujoco runs through viaform-mujoco (the bridge selects it); this facade is phys")),
            other => return Err(params(format!("engine {other}: phys or mujoco"))),
        }
        let settings: Settings = match p.get("settings") {
            Some(s) => serde_json::from_value(s.clone()).map_err(|e| params(format!("settings: {e}")))?,
            None => Settings::default(),
        };
        self.drone = false;
        let sim = if let (Some(a), Some(s)) = (p.get("assembly"), p.get("scenario")) {
            Sim::Scenario(Box::new(scenario::load(a, s)?))
        } else if let Some(d) = p.get("drone") {
            let spec: QuadSpec = serde_json::from_value(d.clone()).map_err(|e| params(format!("drone: {e}")))?;
            let state: DroneState = match p.get("state") {
                Some(s) => serde_json::from_value(s.clone()).map_err(|e| params(format!("state: {e}")))?,
                None => DroneState { p: [0.0, 0.0, 1.0], q: [1.0, 0.0, 0.0, 0.0], ..DroneState::default() },
            };
            let ground = p.get("ground").and_then(Value::as_bool).unwrap_or(true);
            let mut w = World::new(drone::quad_model(&spec, ground)?, Settings { dt: drone_dt(p), ..settings });
            drone::set_state(&mut w, &state)?;
            if p.get("power").and_then(Value::as_bool).unwrap_or(true) {
                w.powertrain = Some(drone::powertrain(&spec, p.get("ambient_c").and_then(Value::as_f64).unwrap_or(25.0)));
            }
            self.drone = true;
            Sim::World(Box::new(w))
        } else {
            let kin = if let Some(name) = p.get("builtin").and_then(Value::as_str) {
                viaform_kin::models::builtin(name).ok_or_else(|| PhysError::new("name.unknown", format!("no built-in model {name}")))?
            } else if let Some(m) = p.get("model") {
                let mut m: viaform_kin::Model = serde_json::from_value(m.clone()).map_err(|e| params(format!("model: {e}")))?;
                m.normalize()?;
                m
            } else {
                return Err(params("world_new needs builtin, model, drone, or assembly + scenario"));
            };
            let kind: Option<ActuatorKind> = match p.get("actuator") {
                Some(a) => Some(serde_json::from_value(a.clone()).map_err(|e| params(format!("actuator: {e}")))?),
                None => None,
            };
            let mut b = ModelBuilder::new(kin);
            for a in 0..b.kin.actuators.len() {
                if b.kin.actuators[a].drive == viaform_kin::model::Drive::Motor {
                    b.actuator(a, kind.clone().unwrap_or(ActuatorKind::Servo(ServoParams::default())));
                }
            }
            if p.get("ground").and_then(Value::as_bool).unwrap_or(false) {
                b.ground(0.8);
            }
            Sim::World(Box::new(World::new(b.build()?, settings)))
        };
        self.sim = Some(sim);
        self.batch = None;
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
        Ok(json!({"t": w.t, "steps": w.steps, "solver": w.stats}))
    }

    fn world_state(&mut self) -> Result<Value, PhysError> {
        let drone_world = self.drone;
        let w = self.sim_mut()?.world_mut();
        let mut poses = vec![0.0; 7 * w.model.nlinks()];
        w.poses_flat(&mut poses);
        let efforts: Vec<f64> = w.act.iter().map(|a| a.effort).collect();
        let contacts: Vec<Value> = w.contacts.iter().map(|c| json!({"bodies": [c.contact.b1, c.contact.b2], "point": c.contact.p.as_slice(), "normal": c.contact.n.as_slice(), "depth": -c.contact.dist, "force": c.force.as_slice()})).collect();
        let mut out = json!({"t": w.t, "q": w.q, "v": w.v, "poses": poses, "efforts": efforts, "contacts": contacts, "solver": w.stats});
        if drone_world {
            out["drone"] = serde_json::to_value(drone::state(w)).unwrap_or(Value::Null);
        }
        if let Some(pt) = &w.powertrain {
            out["power"] = json!({
                "voltage": pt.pack.voltage, "current": pt.pack.current, "soc": pt.pack.soc,
                "cell_core_c": pt.pack.t_core, "cell_surface_c": pt.pack.t_surface,
                "heat_irreversible_j": pt.pack.heat_irreversible, "heat_reversible_j": pt.pack.heat_reversible,
                "motor_winding_c": pt.motors.iter().map(|m| m.t[0]).collect::<Vec<_>>(),
                "esc_c": pt.escs.iter().map(|e| e.t[0]).collect::<Vec<_>>(),
                "empty": pt.pack.empty(),
            });
        }
        Ok(out)
    }

    fn set_controls(&mut self, p: &Value) -> Result<Value, PhysError> {
        let w = self.sim_mut()?.world_mut();
        if let Some(c) = p.get("controls") {
            let c = f64s(c, "controls")?;
            if c.len() != w.act.len() {
                return Err(params(format!("controls: expected {} values", w.act.len())));
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
            .filter(|&i| i < w.act.len())
            .ok_or_else(|| PhysError::new("name.unknown", format!("no actuator {a}")))?;
            let v = p.get("value").and_then(Value::as_f64).ok_or_else(|| params("value must be a number"))?;
            w.set_control(idx, v);
        }
        if let Some(r) = p.get("rotors") {
            let r = f64s(r, "rotors")?;
            drone::set_commands(w, &r);
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
        w.recorder = Some(Recorder::new(every, bodies));
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
        let mut batch = Batch::from_world(w, n);
        for b in &mut batch.worlds {
            b.recorder = None;
        }
        let (nq, na) = (w.q.len(), w.act.len());
        self.batch = Some(batch);
        Ok(json!({"n": n, "nq": nq, "na": na}))
    }

    fn batch_step(&mut self, p: &Value) -> Result<Value, PhysError> {
        let batch = self.batch.as_mut().ok_or_else(|| PhysError::new("batch.none", "no batch: call batch_new first"))?;
        if let Some(c) = p.get("controls") {
            batch.set_controls(&f64s(c, "controls")?)?;
        }
        let steps = p.get("steps").and_then(Value::as_u64).unwrap_or(1) as usize;
        batch.step(steps)?;
        Ok(json!({"q": batch.q_flat()}))
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
            let chunk = 100usize;
            let mut done = 0;
            let mut err = None;
            while done < steps && !cn.load(Ordering::Relaxed) {
                let n = chunk.min(steps - done);
                let r = match &mut sim {
                    Sim::World(w) => w.run(n),
                    Sim::Scenario(s) => {
                        let t = s.world.t + n as f64 * s.world.settings.dt;
                        s.advance(t)
                    }
                };
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

    fn job(&mut self, p: &Value) -> Result<u64, PhysError> {
        let id = p.get("id").and_then(Value::as_u64).ok_or_else(|| params("id must be a job id"))?;
        if !self.jobs.contains_key(&id) {
            return Err(PhysError::new("job.none", format!("no job {id}")));
        }
        Ok(id)
    }

    fn job_poll(&mut self, p: &Value) -> Result<Value, PhysError> {
        let id = self.job(p)?;
        let job = self.jobs.get_mut(&id).expect("checked");
        let (progress, done) = {
            let g = job.state.lock().map_err(|_| PhysError::new("job.none", "job state poisoned"))?;
            (g.progress, g.done)
        };
        if !done {
            return Ok(json!({"job": id, "state": "running", "progress": progress}));
        }
        if let Some(h) = job.handle.take() {
            let _ = h.join();
        }
        let mut g = job.state.lock().map_err(|_| PhysError::new("job.none", "job state poisoned"))?;
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
        let mut out = json!({
            "links": m.kin.links.iter().map(|l| l.name.clone()).collect::<Vec<_>>(),
            "joints": m.kin.joints.iter().map(|j| json!({"name": j.name, "kind": j.kind, "parent": j.parent})).collect::<Vec<_>>(),
            "actuators": m.kin.actuators.iter().map(|a| a.name.clone()).collect::<Vec<_>>(),
            "mass_kg": m.mass,
            "nq": w.q.len(), "nv": w.v.len(), "dt": w.settings.dt, "notes": m.notes,
        });
        if let Sim::Scenario(s) = sim {
            out["scenario"] = json!({"id": s.id, "duration_s": s.duration, "control_dt": s.control_dt, "latency_s": s.latency, "objects": s.objects, "randomised": s.randomised, "notes": s.notes, "assembly_joints": s.joints});
        }
        Ok(out)
    }
}

impl Drop for Phys {
    fn drop(&mut self) {
        for job in self.jobs.values_mut() {
            job.cancel.store(true, Ordering::Relaxed);
            if let Some(h) = job.handle.take() {
                let _ = h.join();
            }
        }
    }
}

fn drone_dt(p: &Value) -> f64 {
    p.get("settings").and_then(|s| s.get("dt")).and_then(Value::as_f64).unwrap_or(0.002)
}

fn norm(v: &[f64; 3]) -> f64 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

/// Wraps an op result as `{"ok": ...}` or `{"error", "code"}`.
pub fn reply(r: Result<Value, PhysError>) -> Value {
    match r {
        Ok(v) => json!({"ok": v}),
        Err(e) => json!({"error": e.message, "code": e.code}),
    }
}
