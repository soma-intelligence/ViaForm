//! The simulation as the apps see it: everything crosses as JSON text, so this facade is the only
//! contract the Swift side (through the bridge's C ABI) depends on. A `Session` holds one flight;
//! `episode` runs a whole one off to the side (the benchmark, the self-test).

use serde::Deserialize;
use serde_json::{Value, json};

use crate::airframe::Airframe;
use crate::control::RateLoop;
use crate::flight::*;
use crate::frame::FRAME;
use crate::job::BrainSpec;
use crate::physics::QuadParams;
use crate::race::{Race, RaceState};
use crate::math::{Rng, norm, sub};
use crate::parts::{PARTS, parts_mass_kg};
use crate::realism::REALISTIC;
use crate::train::{random_disturbance, stress_bench};
use crate::weather::weathers;
use crate::world::{Course, obstacle_course, random_course};

/// Infinity (clear air, no hit yet) has no JSON form; send a large number instead.
fn finite(x: f64) -> f64 {
    if x.is_finite() { x } else { 1e9 }
}

#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MissionKind {
    #[default]
    Course,
    Hover,
    Stress,
    /// Flown by a person on the sticks, as a race through the gates to the pad.
    Manual,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct StartOptions {
    #[serde(default = "obstacle")]
    pub course: String,
    #[serde(default)]
    pub seed: f64,
    #[serde(default)]
    pub weather: usize,
    #[serde(default = "trained_name")]
    pub brain: String,
    #[serde(default)]
    pub mission: MissionKind,
    /// The realistic plant and sensors (always on for the stress test).
    #[serde(default)]
    pub realism: bool,
    /// The brain a training ended with, flown when `brain` is "custom".
    #[serde(default)]
    pub custom: Option<BrainSpec>,
    /// The text of a generated frame file (docs/generative/drone-frame.json); the nominal quad without.
    #[serde(default)]
    pub frame: Option<String>,
    /// The text of the sourced components list (docs/components/drone.json): the drone is built
    /// from it, with the frame above, and placed by `assembly` when given.
    #[serde(default)]
    pub components: Option<String>,
    #[serde(default)]
    pub assembly: Option<String>,
    #[serde(default)]
    pub pilot_mode: PilotMode,
}
fn obstacle() -> String {
    "obstacle".into()
}
fn trained_name() -> String {
    "trained".into()
}

/// The brain the options name, or the trained one they carry.
pub fn brain_of(o: &StartOptions) -> Brain {
    match (&o.custom, o.brain.as_str()) {
        (Some(c), "custom") => c.brain(),
        _ => brain_for(&o.brain),
    }
}

/// The drone the options fly: from the generated frame when given, else the nominal quad.
pub fn quad_of(o: &StartOptions) -> Result<(QuadParams, Option<Airframe>), String> {
    if let Some(c) = o.components.as_deref().filter(|c| !c.trim().is_empty()) {
        let v = crate::components::vehicle(c, o.assembly.as_deref(), o.frame.as_deref())?;
        let a = match o.frame.as_deref().filter(|t| !t.trim().is_empty()) {
            Some(t) => Some(Airframe::from_json(t)?),
            None => None,
        };
        return Ok((v.params, a));
    }
    match &o.frame {
        Some(text) if !text.trim().is_empty() => {
            let a = Airframe::from_json(text)?;
            Ok((a.params.clone(), Some(a)))
        }
        _ => Ok((quad3_default(), None)),
    }
}

/// What a generated frame file builds: `{name, frameG, armMm, massKg, inertia, thrustToWeight}`
/// or `{error}`.
pub fn airframe(text: &str) -> String {
    match Airframe::from_json(text) {
        Ok(a) => a.summary().to_string(),
        Err(e) => json!({ "error": e }).to_string(),
    }
}

/// What the sourced components build (`{massKg, inertia, thrustToWeight, sources, missing, ...}`)
/// or `{error}`. `request` is `{"components": text, "assembly": text?, "frame": text?}`.
pub fn vehicle(request: &str) -> String {
    #[derive(Deserialize)]
    struct Req {
        components: String,
        #[serde(default)]
        assembly: Option<String>,
        #[serde(default)]
        frame: Option<String>,
    }
    let r: Req = match serde_json::from_str(request) {
        Ok(r) => r,
        Err(e) => return json!({ "error": e.to_string() }).to_string(),
    };
    match crate::components::vehicle(&r.components, r.assembly.as_deref(), r.frame.as_deref()) {
        Ok(v) => v.summary.to_string(),
        Err(e) => json!({ "error": e }).to_string(),
    }
}

pub fn brain_for(name: &str) -> Brain {
    match name {
        "pid" => pid_only(crate::control::DEFAULT_GAINS),
        "tuned" => trained(false),
        "stable" => stable(RateLoop::Pid),
        "indi" => stable(RateLoop::Indi),
        _ => trained(true),
    }
}

/// The weather presets, brains, courses and missions, for the pickers.
pub fn catalog() -> String {
    json!({
        "weathers": weathers().iter().map(|w| json!({
            "name": w.name, "temperatureC": w.temperature_c, "wind": norm(w.wind.mean), "fog": finite(w.fog_visibility_m),
        })).collect::<Vec<_>>(),
        "brains": [
            { "id": "pid", "name": "Default PID" },
            { "id": "tuned", "name": "Tuned PID" },
            { "id": "trained", "name": "Tuned PID + neural residual" },
            { "id": "stable", "name": "Stabilization PID" },
            { "id": "indi", "name": "Stabilization INDI" },
        ],
        "courses": [
            { "id": "obstacle", "name": "Obstacle course" },
            { "id": "random", "name": "Random course" },
        ],
        "missions": [
            { "id": "course", "name": "Fly the course" },
            { "id": "hover", "name": "Hover" },
            { "id": "stress", "name": "Stress test" },
            { "id": "manual", "name": "Race (manual)" },
        ],
        "disturbances": ["kick", "gust", "tumble", "payload", "prop"],
        "frame": FRAME,
    })
    .to_string()
}

/// The drone's parts list (bill of materials) with the masses the simulation uses.
pub fn parts(frame_g: f64) -> String {
    json!({ "parts": PARTS, "massKg": parts_mass_kg(frame_g) }).to_string()
}

pub fn scenario_for(o: &StartOptions) -> (Scenario, Option<Course>) {
    let all = weathers();
    let w = all[o.weather.min(all.len() - 1)].clone();
    let realism = o.realism.then(|| REALISTIC.clone());
    match o.mission {
        MissionKind::Stress => (stress_bench(o.seed, w, REALISTIC.clone()), None),
        MissionKind::Hover => {
            let mut sc = Scenario::new(w, Mission::Hover { at: [0.0, 0.0, 1.6] }, 20.0, o.seed);
            sc.realism = realism;
            (sc, None)
        }
        MissionKind::Manual => {
            let course = obstacle_course();
            let mut sc = Scenario::new(w, Mission::Manual { course: course.clone() }, 120.0, o.seed);
            sc.realism = realism;
            (sc, Some(course))
        }
        MissionKind::Course => {
            let course = if o.course == "random" { random_course(&mut Rng::new(o.seed * 7919.0)) } else { obstacle_course() };
            let mut sc = Scenario::new(w, Mission::Waypoints { course: course.clone() }, 40.0, o.seed);
            sc.realism = realism;
            (sc, Some(course))
        }
    }
}

/// Runs one flight to its end and returns how it went (`EpisodeResult` as JSON).
pub fn episode(options: &str) -> String {
    let o: StartOptions = match serde_json::from_str(options) {
        Ok(o) => o,
        Err(e) => return json!({ "error": e.to_string() }).to_string(),
    };
    let quad = match quad_of(&o) {
        Ok((q, _)) => q,
        Err(e) => return json!({ "error": e }).to_string(),
    };
    let (sc, _) = scenario_for(&o);
    let mut r = serde_json::to_value(run_episode(&quad, brain_of(&o), sc)).unwrap();
    r["minClearance"] = json!(finite(r["minClearance"].as_f64().unwrap_or(f64::INFINITY)));
    r.to_string()
}

pub struct Session {
    flight: Flight,
    stress_rand: Rng,
    timed: bool,
    next_timed: f64,
    race: Option<Race>,
    airframe: Option<Airframe>,
    vehicle: Option<Value>,
    ticks: u64,
}

impl Session {
    /// Starts a flight; `world` returns what to draw that does not move.
    pub fn start(options: &str) -> Result<Session, String> {
        let o: StartOptions = serde_json::from_str(options).map_err(|e| e.to_string())?;
        let (quad, airframe) = quad_of(&o)?;
        // The sourced drone's whole summary: what flies, and what the assembly placed and the
        // frame file gave (the app's self-test checks those against the files).
        let vehicle = match o.components.as_deref().filter(|c| !c.trim().is_empty()) {
            Some(c) => Some(crate::components::vehicle(c, o.assembly.as_deref(), o.frame.as_deref())?.summary),
            None => None,
        };
        let (sc, course) = scenario_for(&o);
        let race = (o.mission == MissionKind::Manual).then(|| Race::new(course.clone().unwrap_or_else(obstacle_course)));
        let mut flight = Flight::new(&quad, brain_of(&o), sc);
        flight.pilot_mode = o.pilot_mode;
        Ok(Session { flight, stress_rand: Rng::new(o.seed * 31.0 + 7.0), timed: false, next_timed: 0.0, race, airframe, vehicle, ticks: 0 })
    }

    pub fn world(&self) -> String {
        let f = &self.flight;
        let mut v = match f.course() {
            Some(c) => json!({
                "name": c.name, "start": c.start, "waypoints": c.waypoints, "obstacles": c.obstacles,
                "hidden": c.hidden, "bounds": c.bounds, "gates": c.gates,
            }),
            None => json!({
                "name": "Open air", "start": f.s.p, "waypoints": [], "obstacles": [], "hidden": [], "gates": [],
                "bounds": { "min": [-8.0, -8.0, 0.0], "max": [8.0, 8.0, 6.0] },
            }),
        };
        v["hold"] = json!(f.hold_point());
        v["frame"] = self.frame_json();
        v["status"] = self.status();
        v["race"] = self.race_json();
        v["airframe"] = self.airframe.as_ref().map_or(Value::Null, Airframe::summary);
        v["vehicle"] = self.vehicle.clone().unwrap_or(Value::Null);
        v.to_string()
    }

    fn frame_json(&self) -> Value {
        let f = self.flight.frame();
        json!({
            "t": f.t, "p": f.p, "q": f.q, "v": f.v, "omega": f.omega, "wind": f.wind, "target": f.target,
            "rays": f.hits.iter().map(|h| json!({ "point": h.point, "hit": h.hit })).collect::<Vec<_>>(),
            "voltage": f.voltage, "soc": f.soc, "planIndex": f.plan_index,
        })
    }

    fn race_json(&self) -> Value {
        self.race.as_ref().map_or(Value::Null, |r| {
            json!({
                "state": r.state, "countdown": r.countdown.max(0.0), "next": r.next, "gates": r.gates().len(),
                "splits": r.splits, "time": r.time, "target": r.target(),
            })
        })
    }

    /// Over: the flight ended, or the race was won or lost.
    pub fn finished(&self) -> bool {
        self.flight.finished() || self.race.as_ref().is_some_and(|r| matches!(r.state, RaceState::Finished | RaceState::Crashed))
    }

    /// The sticks for a manual flight: `{"x","y","z","yaw"}` each -1..1, and optionally `"mode"`
    /// ("position" or "angle"). False when the text does not parse.
    pub fn set_pilot(&mut self, input: &str) -> bool {
        #[derive(Deserialize)]
        #[serde(default)]
        struct Sticks {
            x: f64,
            y: f64,
            z: f64,
            yaw: f64,
            mode: Option<PilotMode>,
        }
        impl Default for Sticks {
            fn default() -> Self {
                Sticks { x: 0.0, y: 0.0, z: 0.0, yaw: 0.0, mode: None }
            }
        }
        let Ok(s) = serde_json::from_str::<Sticks>(input) else { return false };
        let c = |x: f64| if x.is_finite() { x.clamp(-1.0, 1.0) } else { 0.0 };
        self.flight.pilot = PilotInput { x: c(s.x), y: c(s.y), z: c(s.z), yaw: c(s.yaw) };
        if let Some(m) = s.mode {
            self.flight.pilot_mode = m;
        }
        true
    }

    fn status(&self) -> Value {
        let f = &self.flight;
        json!({
            "finished": self.finished(), "crashed": f.s.crashed, "collided": f.collided,
            "minClearance": finite(f.min_clearance), "energyWh": f.energy_j / 3600.0,
        })
    }

    /// What the stress test's scope and arrow draw: body rates, attitude and position error,
    /// each disturbance's recovery and the last one's vector.
    fn stabilization(&self) -> Value {
        let f = &self.flight;
        let dev = f.hold_point().map_or(0.0, |h| norm(sub(f.s.p, h)));
        json!({
            "w": f.s.w, "attitudeError": f.attitude_error(), "deviation": dev,
            "attitudeRms": if f.att_err_n > 0 { (f.att_err_sq / f.att_err_n as f64).sqrt() } else { 0.0 },
            "recoveries": f.recoveries, "lastHit": f.last_hit, "timed": self.timed, "payloadKg": f.payload_kg,
        })
    }

    /// Advances by `seconds` of simulated time (2 ms physics steps) and returns the latest frame,
    /// the trail points added since the last call, the status and the stabilization readout.
    pub fn advance(&mut self, seconds: f64) -> String {
        let mut steps = (seconds / DT).round().max(1.0) as usize;
        let mut added = vec![];
        // The race's countdown: the drone waits on the start, the clock does not run.
        if let Some(r) = self.race.as_mut().filter(|r| r.state == RaceState::Countdown) {
            let wait = r.countdown.min(seconds);
            r.countdown -= wait;
            steps = ((seconds - wait) / DT).round() as usize;
            if r.countdown <= 1e-9 {
                r.countdown = 0.0;
                r.state = RaceState::Flying;
            }
        }
        for i in 0..steps {
            if self.finished() {
                break;
            }
            if self.timed && self.flight.s.t >= self.next_timed {
                let t = self.flight.s.t;
                let d = random_disturbance(&mut self.stress_rand, t);
                self.flight.disturb(&d);
                self.next_timed = t + self.stress_rand.range(1.5, 3.0);
            }
            self.flight.tick();
            self.ticks += 1;
            if let Some(r) = self.race.as_mut().filter(|_| self.ticks % 5 == 0) {
                let f = &self.flight;
                r.update(f.s.p, f.s.v, f.s.t, f.s.crashed || f.collided);
            }
            if i % 10 == 0 {
                added.push(self.flight.s.p);
            }
        }
        json!({
            "frame": self.frame_json(), "trail": added, "status": self.status(), "stabilization": self.stabilization(), "race": self.race_json(),
        })
        .to_string()
    }

    /// The stress test's keys: one disturbance of `kind` now at a random size, or "timed" to
    /// toggle random ones every 1.5 to 3 s. Returns false for an unknown kind.
    pub fn disturb(&mut self, kind: &str) -> bool {
        let t = self.flight.s.t;
        if kind == "timed" {
            self.timed = !self.timed;
            self.next_timed = t + 1.5;
            return true;
        }
        for _ in 0..40 {
            let d = random_disturbance(&mut self.stress_rand, t);
            let name = serde_json::to_value(d.kind()).ok();
            if name.as_ref().and_then(Value::as_str) == Some(kind) {
                // A payload from the keys is always picked up, never dropped.
                let d = match d {
                    Disturbance::Payload { t, kg, at } => Disturbance::Payload { t, kg: kg.abs() + 0.01, at },
                    d => d,
                };
                self.flight.disturb(&d);
                return true;
            }
        }
        false
    }

    pub fn flight(&self) -> &Flight {
        &self.flight
    }
}
