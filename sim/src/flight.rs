//! One flight: the drone, the weather, the course, the sensors, the companion computer's planner
//! and the flight controller, stepped together at the rates the real hardware runs at:
//! physics and the rate loop at 500 Hz, position and velocity at 100 Hz, the distance sensors at
//! 30 Hz and the planner at 20 Hz. The app draws a Flight frame by frame; tests and training run
//! whole episodes with `run_episode`.

use serde::{Deserialize, Serialize};

use crate::control::*;
use crate::math::*;
use crate::parts::MOTOR_THRUST_3S_N;
use crate::physics::*;
use crate::planner::{PlanOut, Planner, PlannerConfig};
use crate::policy::{Policy, PolicyIn, policy_input};
use crate::realism::{Aero, Imu, Mahony, REALISTIC, Realism, kick, make_build};
use crate::stable::{STABLE_INDI, STABLE_PID};
use crate::trained::{TRAINED_GAINS, TRAINED_POLICY};
use crate::weather::*;
use crate::world::{Course, TofHit, TofSpec, clearance, read_tof, tof_array};

pub const DT: f64 = 0.002;

/// The 3-inch quad from its parts: mass, inertia and arm from the CAD when given.
pub fn quad3(mass: f64, inertia: V3, arm: f64) -> QuadParams {
    let omega_max = 4000.0; // rad/s: 4600 KV on a loaded 3S pack, ~38 000 rpm
    let k_t = MOTOR_THRUST_3S_N / (omega_max * omega_max);
    QuadParams {
        mass, inertia, arm, k_t, k_q: k_t * 0.009, omega_max, omega_idle: 0.12 * omega_max, motor_tau: 0.025,
        drag_linear: [0.045, 0.045, 0.06], drag_quad: [0.006, 0.006, 0.012], prop_radius: 0.0381, body_radius: 0.1,
        battery_ah: 0.65, battery_cells: 3.0, max_thrust: MOTOR_THRUST_3S_N, peak_current: 9.3,
    }
}
/// The nominal quad (the TypeScript `quad3()` defaults).
pub fn quad3_default() -> QuadParams {
    quad3(0.175, [1.9e-4, 2.1e-4, 3.5e-4], 0.0602)
}

#[derive(Clone, Debug)]
pub struct Brain {
    pub gains: Gains,
    pub policy: Option<Policy>,
    pub rate_loop: RateLoop,
    pub rate_int_max: Option<f64>,
}

pub fn pid_only(gains: Gains) -> Brain {
    Brain { gains, policy: None, rate_loop: RateLoop::Pid, rate_int_max: None }
}
/// What the first training learned: tuned gains, and with `nn` the neural residual on top.
pub fn trained(nn: bool) -> Brain {
    Brain { gains: TRAINED_GAINS, policy: nn.then(|| Policy::new(TRAINED_POLICY.to_vec())), rate_loop: RateLoop::Pid, rate_int_max: None }
}
/// What the stabilization training tuned on the realistic plant, with either rate loop.
pub fn stable(rate_loop: RateLoop) -> Brain {
    let gains = if rate_loop == RateLoop::Indi { STABLE_INDI } else { STABLE_PID };
    Brain { gains, policy: None, rate_loop, rate_int_max: Some(50.0) }
}

/// Something done to the drone at time t.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Disturbance {
    /// A blow: impulse (N·s, world) at a point (m from the centre of mass, body axes).
    Kick { t: f64, impulse: V3, at: V3 },
    /// A sharp-edged gust on top of the weather, for `length` seconds.
    Gust { t: f64, wind: V3, length: f64 },
    /// A damaged prop: that motor makes `health` of its thrust from now on.
    Prop { t: f64, motor: usize, health: f64 },
    /// A payload picked up (kg > 0) or dropped (kg < 0), off-centre by `at` (m, body).
    Payload { t: f64, kg: f64, at: V3 },
    /// Thrown or knocked into a tumble: body rates (rad/s) all at once.
    Tumble { t: f64, rates: V3 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DisturbanceKind {
    Kick,
    Gust,
    Prop,
    Payload,
    Tumble,
}

impl Disturbance {
    pub fn t(&self) -> f64 {
        match self {
            Disturbance::Kick { t, .. } | Disturbance::Gust { t, .. } | Disturbance::Prop { t, .. } | Disturbance::Payload { t, .. } | Disturbance::Tumble { t, .. } => *t,
        }
    }
    pub fn kind(&self) -> DisturbanceKind {
        match self {
            Disturbance::Kick { .. } => DisturbanceKind::Kick,
            Disturbance::Gust { .. } => DisturbanceKind::Gust,
            Disturbance::Prop { .. } => DisturbanceKind::Prop,
            Disturbance::Payload { .. } => DisturbanceKind::Payload,
            Disturbance::Tumble { .. } => DisturbanceKind::Tumble,
        }
    }
}

/// How the drone came back from one disturbance.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recovery {
    pub kind: DisturbanceKind,
    pub t: f64,
    pub max_deviation: f64,
    pub max_tilt: f64,
    pub recovered_after: Option<f64>,
}

#[derive(Clone, Debug)]
pub enum Mission {
    Hover { at: V3 },
    Waypoints { course: Course },
    /// Flown by a person (the game): `Flight::pilot` holds the sticks; the course is for collisions.
    Manual { course: Course },
    /// Velocity steps (training): each entry holds from its time until the next.
    Track { at: V3, steps: Vec<(f64, V3)> },
    /// Hold a point while things are done to the drone (the stabilization bench).
    Stabilize { at: V3, events: Vec<Disturbance> },
}

#[derive(Clone, Debug)]
pub struct Scenario {
    pub weather: Weather,
    pub mission: Mission,
    pub duration: f64,
    pub seed: f64,
    pub tof_range: Option<f64>,
    pub mass_scale: Option<f64>,
    pub thrust_scale: Option<f64>,
    /// The plant and sensor effects of realism.rs; without it, the rigid body and simple noise.
    pub realism: Option<Realism>,
}

impl Scenario {
    pub fn new(weather: Weather, mission: Mission, duration: f64, seed: f64) -> Self {
        Scenario { weather, mission, duration, seed, tof_range: None, mass_scale: None, thrust_scale: None, realism: None }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    pub t: f64,
    pub p: V3,
    pub q: Q,
    pub v: V3,
    pub omega: [f64; 4],
    pub wind: V3,
    pub target: V3,
    pub hits: Vec<TofHit>,
    pub voltage: f64,
    pub soc: f64,
    pub residual: V3,
    pub plan_index: usize,
}

/// Sticks, each -1..1: forward, left, up, and yaw rate to the left.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
pub struct PilotInput {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub yaw: f64,
}
/// Position: the drone holds its place when the sticks are centred and flies the velocity the
/// sticks ask for. Angle: the sticks tilt it (up to 35°) and it keeps going, as a racing quad in
/// angle mode; only height is held.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PilotMode {
    #[default]
    Position,
    Angle,
}
const PILOT_SPEED: f64 = 5.0;
const PILOT_CLIMB: f64 = 2.5;
const PILOT_YAW: f64 = 2.4;
const PILOT_TILT: f64 = 35.0 * PI / 180.0;

/// The last disturbance, for the app to draw (time, kind and world impulse, wind or rates).
#[derive(Clone, Debug, Serialize)]
pub struct LastHit {
    pub t: f64,
    pub kind: DisturbanceKind,
    pub vec: V3,
}

pub struct Flight {
    pub s: QuadState,
    pub ctl: Cascade,
    pub wind: Wind,
    pub battery: Battery,
    pub exposure: Exposure,
    pub planner: Option<Planner>,
    pub plan: Option<PlanOut>,
    pub hits: Vec<TofHit>,
    pub rand: Rng,
    pub rho: f64,
    pub tof_range: f64,
    pub tof_false_rate: f64,
    pub sensors: Vec<TofSpec>,
    pub sp: Setpoint,
    pub acc: V3,
    pub residual: V3,
    pub wind_now: V3,
    pub gyro_bias: V3,
    pub collided: bool,
    pub min_clearance: f64,
    pub energy_j: f64,
    pub track_error: f64,
    pub err_sq: f64,
    pub err_max: f64,
    pub err_n: usize,
    k: u64,
    pub p: QuadParams,
    pub brain: Brain,
    pub sc: Scenario,
    /// The sticks, for a manual mission.
    pub pilot: PilotInput,
    pub pilot_mode: PilotMode,
    pilot_yaw: f64,
    hold: Option<V3>,
    /// realism.rs state, when the scenario asks for it, and its own random stream.
    pub realism: Option<Realism>,
    pub aero: Option<Aero>,
    pub imu: Option<Imu>,
    pub ahrs: Option<Mahony>,
    rand2: Rng,
    w_lp: V3,
    p_err: V3,
    p_drift: V3,
    v_drift: V3,
    v_err: V3,
    esc_queue: std::collections::VecDeque<[f64; 4]>,
    /// Disturbances still to come, and gusts and payload now in effect.
    pending: std::collections::VecDeque<Disturbance>,
    gusts: Vec<(f64, V3)>,
    pub payload_kg: f64,
    pub recoveries: Vec<Recovery>,
    calm_since: f64,
    z_des_lp: V3,
    pub att_err_sq: f64,
    pub att_err_n: usize,
    pub last_hit: Option<LastHit>,
}

impl Flight {
    pub fn new(base: &QuadParams, brain: Brain, sc: Scenario) -> Self {
        let mut rand = Rng::new(sc.seed);
        // Each flight's drone differs a little from the nominal one, as real builds do.
        let mut p = base.clone();
        p.mass = base.mass * sc.mass_scale.unwrap_or(1.0);
        p.k_t = base.k_t * sc.thrust_scale.unwrap_or(1.0);
        let start = match &sc.mission {
            Mission::Waypoints { course } | Mission::Manual { course } => course.start,
            Mission::Hover { at } | Mission::Track { at, .. } | Mission::Stabilize { at, .. } => *at,
        };
        let mut s = QuadState::new(start, q_from_euler(0.0, 0.0, 0.0));
        if !matches!(sc.mission, Mission::Waypoints { .. } | Mission::Manual { .. }) {
            // Start hovering: motors at hover speed, so the test measures holding, not taking off.
            let hover = (p.mass * 9.81 / 4.0 / p.k_t).sqrt();
            s.omega = [hover; 4];
        }
        // The controller knows the nominal parameters only.
        let mut nominal = p.clone();
        nominal.mass = base.mass;
        nominal.k_t = base.k_t;
        let mut ctl = Cascade::new(nominal, brain.gains, DEFAULT_LIMITS);
        ctl.rate_loop = brain.rate_loop;
        if let Some(m) = brain.rate_int_max {
            ctl.lim.rate_int_max = m;
        }
        let wind = Wind::new(sc.weather.wind.clone(), &mut rand);
        let battery = Battery::new(p.battery_ah, p.battery_cells, sc.weather.temperature_c);
        let exposure = Exposure::new(sc.weather.clone());
        let rho = air_density(&sc.weather);
        let (tof_range, tof_false_rate) = tof_conditions(&sc.weather, sc.tof_range.unwrap_or(4.0));
        let sensors = tof_array(tof_range);
        let tk = 1.0 + (sc.weather.temperature_c - 25.0).abs() / 20.0;
        let gyro_bias = std::array::from_fn(|_| rand.gauss() * 0.01 * tk);
        let planner = if let Mission::Waypoints { course } = &sc.mission {
            let mut pl = Planner::new(course.waypoints.clone(), PlannerConfig { sensor_range: tof_range, ..Default::default() }, Some(&course.bounds));
            // The drone gets the course plan (the gates); the rest only its sensors find.
            for (i, o) in course.obstacles.iter().enumerate() {
                if !course.hidden.contains(&i) {
                    pl.map.know(o);
                }
            }
            Some(pl)
        } else {
            None
        };
        let realism = sc.realism.clone().or_else(|| matches!(sc.mission, Mission::Stabilize { .. }).then(|| REALISTIC.clone()));
        // Its own random stream, so the rest of the flight draws the same numbers as without.
        let mut rand2 = Rng::new(sc.seed * 7919.0 + 13.0);
        let (mut aero, mut imu, mut ahrs) = (None, None, None);
        if let Some(r) = &realism {
            let build = make_build(r, &mut rand2);
            aero = Some(Aero::new(r.clone(), build));
            imu = Some(Imu::new(r.clone(), &mut rand2, sc.weather.temperature_c));
            ahrs = Some(Mahony::new(s.q));
        }
        let mut pending: Vec<Disturbance> = if let Mission::Stabilize { events, .. } = &sc.mission { events.clone() } else { vec![] };
        pending.sort_by(|a, b| a.t().total_cmp(&b.t()));
        Flight {
            s, ctl, wind, battery, exposure, planner, plan: None, hits: vec![], rand, rho, tof_range, tof_false_rate, sensors,
            sp: Setpoint::Position { p: start, yaw: 0.0 }, acc: [0.0; 3], residual: [0.0; 3], wind_now: [0.0; 3], gyro_bias,
            collided: false, min_clearance: f64::INFINITY, energy_j: 0.0, track_error: 0.0, err_sq: 0.0, err_max: 0.0, err_n: 0, k: 0,
            p, brain, sc, pilot: PilotInput::default(), pilot_mode: PilotMode::Position, pilot_yaw: 0.0, hold: None,
            realism, aero, imu, ahrs, rand2, w_lp: [0.0; 3], p_err: [0.0; 3], p_drift: [0.0; 3], v_drift: [0.0; 3], v_err: [0.0; 3],
            esc_queue: Default::default(), pending: pending.into(), gusts: vec![], payload_kg: 0.0, recoveries: vec![], calm_since: -1.0,
            z_des_lp: [0.0, 0.0, 1.0], att_err_sq: 0.0, att_err_n: 0, last_hit: None,
        }
    }

    pub fn course(&self) -> Option<&Course> {
        match &self.sc.mission {
            Mission::Waypoints { course } | Mission::Manual { course } => Some(course),
            _ => None,
        }
    }

    /// The point a hover or stabilize mission holds.
    pub fn hold_point(&self) -> Option<V3> {
        match &self.sc.mission {
            Mission::Hover { at } | Mission::Stabilize { at, .. } => Some(*at),
            _ => None,
        }
    }

    /// Does `d` to the drone now (the app's kick button; scheduled ones come through tick).
    pub fn disturb(&mut self, d: &Disturbance) {
        let r = q_to_m3(self.s.q);
        let mut vec = [0.0; 3];
        match d {
            Disturbance::Kick { impulse, at, .. } => {
                kick(&mut self.s, &self.p, &r, *impulse, *at);
                vec = *impulse;
            }
            Disturbance::Gust { wind, length, .. } => {
                self.gusts.push((self.s.t + length, *wind));
                vec = *wind;
            }
            Disturbance::Prop { motor, health, .. } => {
                if let Some(a) = &mut self.aero {
                    a.build.k_t[*motor] *= health;
                }
            }
            Disturbance::Payload { kg, at, .. } => {
                let before = self.payload_kg;
                self.payload_kg = (before + kg).max(0.0);
                // The centre of mass moves toward the payload; the aero model keeps the offset.
                if let Some(a) = &mut self.aero {
                    let m = self.p.mass + self.payload_kg;
                    let dm = self.payload_kg - before;
                    a.build.cg = add(a.build.cg, scale(*at, dm / m));
                }
                vec = [0.0, 0.0, -kg * G];
            }
            Disturbance::Tumble { rates, .. } => {
                self.s.w = add(self.s.w, *rates);
                vec = *rates;
            }
        }
        self.last_hit = Some(LastHit { t: self.s.t, kind: d.kind(), vec });
        self.recoveries.push(Recovery { kind: d.kind(), t: self.s.t, max_deviation: 0.0, max_tilt: 0.0, recovered_after: None });
        self.calm_since = -1.0;
    }

    pub fn estimate(&mut self) -> Estimate {
        let s = &self.s;
        let r = &mut self.rand;
        if let (Some(imu), Some(ahrs)) = (&mut self.imu, &mut self.ahrs) {
            // The flight controller's view: its IMU, its attitude filter, the companion's position.
            let (w, acc) = imu.read(s, self.aero.as_ref(), self.p.mass + self.payload_kg, self.p.inertia, DT, &mut self.rand2);
            let heading = heading_of(&q_to_m3(s.q)) + 0.02 * r.gauss();
            ahrs.update(w, acc, Some(heading), DT);
            // Gyro low-pass (PT1 at ~80 Hz), as every flight controller runs before its loops.
            self.w_lp = add(self.w_lp, scale(sub(w, self.w_lp), 0.5));
            // The companion's position and velocity come out of a filter (visual-inertial odometry,
            // integrating the IMU between camera frames): their errors wander slowly and smoothly
            // rather than jump every sample. A random walk pulled back (0.3 s), then smoothed (0.08 s).
            let a = DT / 0.3;
            let k = (2.0 * a).sqrt();
            let b = DT / 0.08;
            for i in 0..3 {
                self.p_drift[i] = self.p_drift[i] - a * self.p_drift[i] + k * if i == 2 { 0.015 } else { 0.02 } * r.gauss();
            }
            for i in 0..3 {
                self.v_drift[i] = self.v_drift[i] - a * self.v_drift[i] + k * if i == 2 { 0.03 } else { 0.04 } * r.gauss();
            }
            self.p_err = add(self.p_err, scale(sub(self.p_drift, self.p_err), b));
            self.v_err = add(self.v_err, scale(sub(self.v_drift, self.v_err), b));
            let pn = [0.001 * r.gauss(), 0.001 * r.gauss(), 0.001 * r.gauss()];
            let vn = [0.002 * r.gauss(), 0.002 * r.gauss(), 0.002 * r.gauss()];
            return Estimate {
                p: add(add(s.p, self.p_err), pn),
                v: add(add(s.v, self.v_err), vn),
                r: q_to_m3(ahrs.q),
                w: self.w_lp,
                acc_body: acc,
            };
        }
        let pn = [0.02 * r.gauss(), 0.02 * r.gauss(), 0.015 * r.gauss()];
        let vn = [0.04 * r.gauss(), 0.04 * r.gauss(), 0.03 * r.gauss()];
        let wn = [0.03 * r.gauss(), 0.03 * r.gauss(), 0.03 * r.gauss()];
        let an = [0.3 * r.gauss(), 0.3 * r.gauss(), 0.3 * r.gauss()];
        Estimate { p: add(s.p, pn), v: add(s.v, vn), r: q_to_m3(s.q), w: add(add(s.w, self.gyro_bias), wn), acc_body: add(s.acc_body, an) }
    }

    /// Advances one physics step (2 ms).
    pub fn tick(&mut self) {
        if self.s.crashed || self.collided {
            return;
        }
        let k = self.k;
        self.k += 1;
        while self.pending.front().is_some_and(|d| d.t() <= self.s.t) {
            let d = self.pending.pop_front().unwrap();
            self.disturb(&d);
        }
        let e = self.estimate();

        // 30 Hz ranging, 20 Hz planning.
        if self.planner.is_some() && k % 17 == 0 {
            let (p, q) = (self.s.p, self.s.q);
            let Mission::Waypoints { course } = &self.sc.mission else { unreachable!() };
            let obstacles = &course.obstacles;
            let raw = read_tof(&self.sensors, obstacles, p, q, Some(&mut self.rand));
            let (range, false_rate) = (self.tof_range, self.tof_false_rate);
            self.hits = raw
                .into_iter()
                .map(|h| {
                    let d = precipitation_return(h.d, range, false_rate, &mut self.rand);
                    if d == h.d { h } else { TofHit { d, hit: true, point: add(p, scale(h.dir, d)), ..h } }
                })
                .collect();
            self.planner.as_mut().unwrap().observe(p, &self.hits);
        }
        if self.planner.is_some() && k % 25 == 0 {
            let pl = self.planner.as_mut().unwrap();
            // Take off first, then follow the plan.
            if self.s.t < 1.2 {
                self.sp = Setpoint::Position { p: pl.waypoints[0], yaw: 0.0 };
            } else {
                let plan = pl.plan(e.p, e.v, self.track_error);
                let landing = plan.done || (plan.index == pl.waypoints.len() - 1 && plan.target[2] < 0.05);
                self.sp = if landing { Setpoint::Position { p: plan.target, yaw: plan.yaw } } else { Setpoint::Velocity { v: plan.v, yaw: plan.yaw, p: None } };
                self.plan = Some(plan);
            }
        }

        if let Mission::Track { steps, .. } = &self.sc.mission {
            if k % 5 == 0 {
                let mut cur = steps[0].1;
                for st in steps {
                    if st.0 <= self.s.t {
                        cur = st.1;
                    }
                }
                self.sp = Setpoint::Velocity { v: cur, yaw: 0.0, p: None };
            }
        }

        let mut angle_acc: Option<V3> = None;
        if matches!(self.sc.mission, Mission::Manual { .. }) && k % 5 == 0 {
            let u = self.pilot;
            let (c, sn) = (self.pilot_yaw.cos(), self.pilot_yaw.sin());
            let dz = |x: f64| if x.abs() < 0.06 { 0.0 } else { x };
            self.pilot_yaw += dz(u.yaw) * PILOT_YAW * DT * 5.0;
            let vz = dz(u.z) * PILOT_CLIMB;
            if self.pilot_mode == PilotMode::Angle {
                // Height held by the velocity loop; the tilt straight from the sticks.
                self.sp = Setpoint::Velocity { v: [e.v[0], e.v[1], vz], yaw: self.pilot_yaw, p: None };
                let (ax, ay) = (PILOT_TILT.tan() * G * dz(u.x), PILOT_TILT.tan() * G * dz(u.y));
                angle_acc = Some([c * ax - sn * ay, sn * ax + c * ay, 0.0]);
            } else {
                let (fwd, left) = (dz(u.x) * PILOT_SPEED, dz(u.y) * PILOT_SPEED);
                // Sticks centred: hold the spot where the drone came to rest.
                let still = fwd == 0.0 && left == 0.0;
                if !still {
                    self.hold = None;
                } else if self.hold.is_none() && hypot2(e.v[0], e.v[1]) < 0.4 {
                    self.hold = Some(e.p);
                }
                let v = [c * fwd - sn * left, sn * fwd + c * left, vz];
                self.sp = match self.hold {
                    Some(h) if vz == 0.0 => Setpoint::Position { p: h, yaw: self.pilot_yaw },
                    _ => Setpoint::Velocity { v, yaw: self.pilot_yaw, p: None },
                };
                if self.hold.is_some() && vz != 0.0 {
                    self.hold = None;
                }
            }
        }

        // 100 Hz outer loop, with the learned correction.
        if k % 5 == 0 {
            if let Setpoint::Velocity { v, .. } = &self.sp {
                self.track_error += (norm(sub(*v, e.v)) - self.track_error) * 0.01;
            }
            self.acc = self.ctl.outer(&e, &self.sp, DT * 5.0);
            if let Some(policy) = &self.brain.policy {
                let zb = col(&e.r, 2);
                let thrust_acc = scale(zb, self.ctl.thrust_cmd / self.ctl.p.mass);
                let measured = mv(&e.r, e.acc_body);
                let force = sub(measured, thrust_acc);
                let v_sp = match &self.sp {
                    Setpoint::Velocity { v, .. } => *v,
                    Setpoint::Position { p, .. } => scale(sub(*p, e.p), self.ctl.g.pos_p),
                };
                let heading = heading_of(&e.r);
                let (c, sn) = (heading.cos(), heading.sin());
                self.residual = policy.act(&policy_input(&PolicyIn {
                    vel_err: sub(v_sp, e.v), v: e.v, force, tilt: [c * zb[0] + sn * zb[1], -sn * zb[0] + c * zb[1]], w: e.w, vel_int: self.ctl.vel_int, heading,
                }));
                // Back from the heading frame to the world.
                let r = self.residual;
                self.acc = add(self.acc, [c * r[0] - sn * r[1], sn * r[0] + c * r[1], r[2]]);
            }
            if let Some(a) = angle_acc {
                self.acc = [a[0], a[1], self.acc[2]];
            }
        }
        // The ESCs report each motor's speed (bidirectional DShot), with a little noise.
        let rpm: [f64; 4] = std::array::from_fn(|i| self.s.omega[i] * (1.0 + 0.004 * self.rand.gauss()));
        let mut cmd = self.ctl.inner(&e, self.acc, self.sp.yaw(), DT, Some(&rpm));
        if let Some(delay) = self.realism.as_ref().map(|r| r.esc_delay).filter(|&d| d > 0) {
            // DShot frame and the ESC's own loop: the motors act on a command a step or two old.
            self.esc_queue.push_back(cmd);
            cmd = if self.esc_queue.len() > delay { self.esc_queue.pop_front().unwrap() } else { self.esc_queue[0] };
        }

        // Weather, battery and the step itself.
        self.exposure.update(DT);
        self.wind_now = self.wind.at(self.s.t, DT, norm(self.s.v), &mut self.rand);
        let t_now = self.s.t;
        self.gusts.retain(|g| g.0 > t_now);
        for g in &self.gusts {
            self.wind_now = add(self.wind_now, g.1);
        }
        let amps = thrusts(&self.p, &self.s).iter().fold(0.0, |a, &t| a + motor_current_peak(t, self.p.max_thrust, self.p.peak_current)) + 0.6; // + FC, VTX-free stack, ESP32, sensors
        let volts = self.battery.draw(amps, DT);
        self.energy_j += volts * amps * DT;
        let env = Env {
            rho: self.rho,
            thrust_factor: self.exposure.thrust_factor(),
            extra_mass: self.exposure.snow_kg + self.payload_kg,
            down_force: self.exposure.rain_force(self.p.prop_radius),
            omega_scale: (volts / 11.4).min(1.0),
            turbulence: self.sc.weather.wind.turbulence,
        };
        let aero = self.aero.as_mut().map(|a| (a, &mut self.rand2));
        step(&self.p, &mut self.s, &cmd, self.wind_now, DT, &env, aero);

        if k % 5 == 0 {
            if let Some(course) = self.course() {
                let c = clearance(&course.obstacles, self.s.p);
                self.min_clearance = self.min_clearance.min(c);
                if c < self.p.body_radius {
                    self.collided = true;
                }
            }
        }
        let target = self.hold_point();
        if k % 5 == 0 {
            self.measure_attitude(target);
        }
        if let (Mission::Track { .. }, true, Setpoint::Velocity { v, .. }) = (&self.sc.mission, k % 5 == 0, &self.sp) {
            let s = &self.s;
            let err = norm(sub(s.v, *v));
            self.err_sq += err * err + 0.01 * (s.w[0].powi(2) + s.w[1].powi(2) + s.w[2].powi(2));
            self.err_n += 1;
            self.err_max = self.err_max.max(err);
        }
        if let Some(target) = target {
            if self.s.t > 1.0 {
                let err = norm(sub(self.s.p, target));
                self.err_sq += err * err;
                self.err_n += 1;
                self.err_max = self.err_max.max(err);
            }
        }
    }

    /// Attitude error against what the controller asked for, and each disturbance's recovery:
    /// back within 0.25 m of the point, below 1.5 rad/s and 10° of tilt error, for 0.5 s.
    fn measure_attitude(&mut self, target: Option<V3>) {
        let s = &self.s;
        let r = q_to_m3(s.q);
        // Against the command smoothed to what a drone can follow (~6 Hz): the raw one carries the
        // position estimate's noise at 100 Hz.
        self.z_des_lp = add(self.z_des_lp, scale(sub(self.ctl.z_des, self.z_des_lp), 0.25));
        let err = clamp(dot(col(&r, 2), self.z_des_lp) / norm(self.z_des_lp), -1.0, 1.0).acos();
        if s.t > 0.5 {
            self.att_err_sq += err * err;
            self.att_err_n += 1;
        }
        let Some(rec) = self.recoveries.last_mut() else { return };
        if rec.recovered_after.is_some() {
            return;
        }
        let dev = target.map_or(0.0, |t| norm(sub(s.p, t)));
        let tilt = clamp(r[8], -1.0, 1.0).acos();
        rec.max_deviation = rec.max_deviation.max(dev);
        rec.max_tilt = rec.max_tilt.max(tilt);
        let calm = dev < 0.25 && norm(s.w) < 1.5 && err < 0.17;
        if !calm {
            self.calm_since = -1.0;
        } else if self.calm_since < 0.0 {
            self.calm_since = s.t;
        } else if s.t - self.calm_since >= 0.5 {
            rec.recovered_after = Some(self.calm_since - rec.t);
        }
    }

    /// Angle (rad) between the thrust axis now and the one the controller asks for.
    pub fn attitude_error(&self) -> f64 {
        let r = q_to_m3(self.s.q);
        clamp(dot(col(&r, 2), self.ctl.z_des), -1.0, 1.0).acos()
    }

    pub fn frame(&self) -> Frame {
        let s = &self.s;
        let target = self.plan.as_ref().map(|p| p.target).unwrap_or(match &self.sp {
            Setpoint::Position { p, .. } => *p,
            _ => s.p,
        });
        Frame {
            t: s.t, p: s.p, q: s.q, v: s.v, omega: s.omega, wind: self.wind_now, target, hits: self.hits.clone(),
            voltage: self.battery.voltage, soc: self.battery.soc, residual: self.residual, plan_index: self.plan.as_ref().map_or(0, |p| p.index),
        }
    }

    pub fn finished(&self) -> bool {
        self.s.crashed || self.collided || self.s.t >= self.sc.duration || (self.plan.as_ref().is_some_and(|p| p.done) && norm(self.s.v) < 0.2 && self.s.p[2] < 0.1)
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EpisodeResult {
    pub crashed: bool,
    pub collided: bool,
    pub completed: bool,
    pub time: f64,
    pub rms_error: f64,
    pub max_error: f64,
    pub min_clearance: f64,
    pub energy_wh: f64,
    pub waypoints_reached: usize,
    /// RMS angle (rad) between the thrust axis and the one the controller asked for.
    pub attitude_rms: f64,
    pub recoveries: Vec<Recovery>,
}

pub fn run_episode(p: &QuadParams, brain: Brain, sc: Scenario) -> EpisodeResult {
    let mut f = Flight::new(p, brain, sc);
    while !f.finished() {
        f.tick();
    }
    EpisodeResult {
        crashed: f.s.crashed,
        collided: f.collided,
        completed: f.plan.as_ref().is_some_and(|p| p.done),
        time: f.s.t,
        rms_error: if f.err_n > 0 { (f.err_sq / f.err_n as f64).sqrt() } else { 0.0 },
        max_error: f.err_max,
        min_clearance: f.min_clearance,
        energy_wh: f.energy_j / 3600.0,
        waypoints_reached: f.plan.as_ref().map_or(0, |p| p.index),
        attitude_rms: if f.att_err_n > 0 { (f.att_err_sq / f.att_err_n as f64).sqrt() } else { 0.0 },
        recoveries: f.recoveries,
    }
}
