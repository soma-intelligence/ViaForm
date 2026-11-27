//! Training the controller in simulation, in two stages, over randomized weather and drones
//! (domain randomization, so what it learns holds on the real one):
//!   1. The PID gains, by the cross-entropy method: sample gain sets around a mean, keep the best
//!      sixth, move the mean and shrink the spread.
//!   2. The neural residual (policy.rs), by evolution strategies (Salimans et al. 2017): perturb
//!      the weights in mirrored pairs, score both, step along the rank-weighted perturbations with
//!      Adam. Reinforcement learning without gradients through the simulator.
//! The score of a candidate is the cost of flying the same randomized episodes (common random
//! numbers). For stabilization the episodes run on the realistic plant and sensors of realism.rs,
//! and half of them hold a point while the drone is kicked, flipped, hit by gusts, loaded and has
//! a prop damaged. Candidates are scored on every core at once; the result does not depend on it.

use crate::control::{DEFAULT_GAINS, GAIN_COUNT, Gains, RateLoop};
use crate::flight::{Brain, Disturbance, Mission, Scenario, run_episode};
use crate::math::*;
use crate::physics::{QuadParams, WindSpec};
use crate::policy::{POLICY_SIZE, Policy};
use crate::realism::{REALISTIC, Realism};
use crate::weather::Weather;

/// A random hard day: anything from calm to a gale, −10 °C to 38 °C, rain or snow, up to 2.5 km.
pub fn random_weather(r: &mut Rng) -> Weather {
    let speed = r.range(0.0, 9.0);
    let dir = r.range(0.0, 2.0 * PI);
    let cold = r.next() < 0.3;
    let mean = [speed * dir.cos(), speed * dir.sin(), r.range(-0.5, 0.5)];
    let turbulence = r.range(0.0, 2.0);
    let length_scale = r.range(6.0, 20.0);
    let gust_every = if r.next() < 0.7 { r.range(1.5, 6.0) } else { 0.0 };
    let gust_peak = r.range(1.0, 7.0);
    let wind = WindSpec { mean, turbulence, length_scale, gust_every, gust_peak };
    let temperature_c = if cold { r.range(-10.0, 3.0) } else { r.range(5.0, 38.0) };
    let altitude_m = r.range(0.0, 2500.0);
    let humidity = r.range(0.2, 1.0);
    let rain_mm_h = if !cold && r.next() < 0.3 { r.range(1.0, 30.0) } else { 0.0 };
    let snow_mm_h = if cold && r.next() < 0.5 { r.range(0.5, 4.0) } else { 0.0 };
    let fog_visibility_m = if r.next() < 0.2 { r.range(30.0, 500.0) } else { f64::INFINITY };
    let sun = r.range(0.0, 1.0);
    Weather { name: "random".into(), temperature_c, altitude_m, humidity, rain_mm_h, snow_mm_h, fog_visibility_m, sun, wind }
}

/// Velocity steps in random directions, the inputs a planner gives.
pub fn tracking_scenario(seed: f64, duration: f64) -> Scenario {
    let mut r = Rng::new(seed);
    let mut steps = vec![(0.0, [0.0; 3])];
    let mut t = 1.0;
    while t < duration {
        let sp = r.range(0.0, 4.5);
        let yaw = r.range(0.0, 2.0 * PI);
        steps.push((t, [sp * yaw.cos(), sp * yaw.sin(), r.range(-1.2, 1.2)]));
        t += r.range(0.8, 1.8);
    }
    let weather = random_weather(&mut r);
    let mut sc = Scenario::new(weather, Mission::Track { at: [0.0, 0.0, 6.0], steps }, duration, seed);
    sc.mass_scale = Some(r.range(0.9, 1.15));
    sc.thrust_scale = Some(r.range(0.9, 1.08));
    sc
}

/// A random disturbance of each kind, at a random size.
pub fn random_disturbance(r: &mut Rng, t: f64) -> Disturbance {
    let dir = |r: &mut Rng| -> V3 {
        let a = r.range(0.0, 2.0 * PI);
        let z = r.range(-0.5, 0.5);
        let h = (1.0 - z * z).sqrt();
        [a.cos() * h, a.sin() * h, z]
    };
    let pick = r.next();
    if pick < 0.3 {
        let d = dir(r);
        let j = r.range(0.01, 0.07);
        let at = [r.range(-0.06, 0.06), r.range(-0.06, 0.06), r.range(-0.02, 0.03)];
        return Disturbance::Kick { t, impulse: scale(d, j), at };
    }
    if pick < 0.55 {
        let d = dir(r);
        let s = r.range(2.0, 8.0);
        return Disturbance::Gust { t, wind: [d[0] * s, d[1] * s, d[2] * s * 0.4], length: r.range(0.3, 2.0) };
    }
    if pick < 0.75 {
        return Disturbance::Tumble { t, rates: [r.range(-14.0, 14.0), r.range(-14.0, 14.0), r.range(-4.0, 4.0)] };
    }
    if pick < 0.9 {
        let kg = r.range(-0.01, 0.04);
        return Disturbance::Payload { t, kg, at: [r.range(-0.03, 0.03), r.range(-0.03, 0.03), 0.0] };
    }
    let motor = r.range(0.0, 4.0).floor() as usize;
    Disturbance::Prop { t, motor, health: r.range(0.75, 0.95) }
}

/// Holding a point in random weather while random things happen to the drone, every 1.5 to 3 s.
pub fn stabilize_scenario(seed: f64, duration: f64, realism: Realism) -> Scenario {
    let mut r = Rng::new(seed);
    let mut events = vec![];
    let mut t = r.range(1.0, 2.0);
    while t < duration - 1.0 {
        events.push(random_disturbance(&mut r, t));
        t += r.range(1.5, 3.0);
    }
    let weather = random_weather(&mut r);
    let mut sc = Scenario::new(weather, Mission::Stabilize { at: [0.0, 0.0, 6.0], events }, duration, seed);
    sc.realism = Some(realism);
    sc.mass_scale = Some(r.range(0.9, 1.15));
    sc.thrust_scale = Some(r.range(0.9, 1.08));
    sc
}

/// The fixed stress test (the app's benchmark and the tests): every kind of disturbance, 3 s apart.
pub fn stress_bench(seed: f64, weather: Weather, realism: Realism) -> Scenario {
    let events = vec![
        Disturbance::Kick { t: 2.0, impulse: [0.05, 0.0, 0.0], at: [0.0, 0.04, 0.02] },
        Disturbance::Gust { t: 5.0, wind: [0.0, 6.0, 0.0], length: 1.2 },
        Disturbance::Tumble { t: 8.0, rates: [12.0, -5.0, 2.0] },
        Disturbance::Payload { t: 11.0, kg: 0.03, at: [0.03, 0.01, 0.0] },
        Disturbance::Prop { t: 14.0, motor: 1, health: 0.8 },
        Disturbance::Kick { t: 17.0, impulse: [0.0, 0.0, -0.06], at: [0.05, 0.0, 0.0] },
    ];
    let mut sc = Scenario::new(weather, Mission::Stabilize { at: [0.0, 0.0, 2.5], events }, 20.0, seed);
    sc.realism = Some(realism);
    sc
}

/// Half tracking, half disturbance rejection, all on the realistic plant.
pub fn realistic_scenario(seed: f64) -> Scenario {
    if seed as i64 % 2 != 0 {
        let mut sc = tracking_scenario(seed, 7.0);
        sc.realism = Some(REALISTIC.clone());
        sc
    } else {
        stabilize_scenario(seed, 9.0, REALISTIC.clone())
    }
}

/// Runs `f` over `items` on every core, keeping the order.
fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let n = std::thread::available_parallelism().map_or(1, |n| n.get()).min(items.len().max(1));
    let chunk = items.len().div_ceil(n).max(1);
    std::thread::scope(|s| {
        let handles: Vec<_> = items.chunks(chunk).map(|c| s.spawn(|| c.iter().map(&f).collect::<Vec<_>>())).collect();
        handles.into_iter().flat_map(|h| h.join().unwrap()).collect()
    })
}

pub fn cost(p: &QuadParams, brain: &Brain, scenarios: &[Scenario]) -> f64 {
    let total: f64 = scenarios
        .iter()
        .map(|sc| {
            let r = run_episode(p, brain.clone(), sc.clone());
            // Holding a point: position error, and the attitude error (rad) weighs as much as 0.5 m.
            let err = if matches!(sc.mission, Mission::Stabilize { .. }) { r.rms_error.powi(2) + 4.0 * r.attitude_rms.powi(2) } else { r.rms_error.powi(2) };
            err + if r.crashed { 50.0 } else { 0.0 }
        })
        .sum();
    total / scenarios.len() as f64
}

#[derive(Clone, Copy, Debug)]
pub enum Stage {
    Pid,
    Rl,
}

#[derive(Clone, Copy, Debug)]
pub struct TrainLog {
    pub stage: Stage,
    pub iteration: usize,
    pub cost: f64,
    pub baseline: f64,
}

pub struct TuneOptions<'a> {
    pub iterations: usize,
    pub population: usize,
    pub episodes: usize,
    pub seed: f64,
    pub init: Gains,
    pub rate_loop: RateLoop,
    pub rate_int_max: Option<f64>,
    pub scenario: Box<dyn Fn(f64) -> Scenario + Sync + 'a>,
    pub log: Box<dyn FnMut(TrainLog) + 'a>,
    /// Checked before each iteration: true ends the training with what it has so far.
    pub stop: Box<dyn Fn() -> bool + 'a>,
}

impl Default for TuneOptions<'_> {
    fn default() -> Self {
        TuneOptions {
            iterations: 20, population: 24, episodes: 6, seed: 11.0, init: DEFAULT_GAINS, rate_loop: RateLoop::Pid, rate_int_max: None,
            scenario: Box::new(|seed| tracking_scenario(seed, 7.0)), log: Box::new(|_| {}), stop: Box::new(|| false),
        }
    }
}

pub fn tune_gains(p: &QuadParams, mut o: TuneOptions) -> Gains {
    let mut r = Rng::new(o.seed);
    let n = o.population;
    let elite = 2usize.max((n as f64 / 6.0).round() as usize);
    let mut mean: [f64; GAIN_COUNT] = o.init.to_array().map(f64::ln);
    let mut sd = [0.35; GAIN_COUNT];
    let to_gains = |x: &[f64; GAIN_COUNT]| Gains::from_array(x.map(f64::exp));
    for it in 0..o.iterations {
        if (o.stop)() {
            break;
        }
        let scs: Vec<Scenario> = (0..o.episodes).map(|i| (o.scenario)((1000 * it + i + 1) as f64)).collect();
        let xs: Vec<[f64; GAIN_COUNT]> =
            (0..n).map(|i| if i == 0 { mean } else { std::array::from_fn(|j| mean[j] + sd[j] * r.gauss()) }).collect();
        let costs = par_map(&xs, |x| {
            let brain = Brain { gains: to_gains(x), policy: None, rate_loop: o.rate_loop, rate_int_max: o.rate_int_max };
            cost(p, &brain, &scs)
        });
        let current = costs[0];
        let mut order: Vec<usize> = (0..n).collect();
        order.sort_by(|&a, &b| costs[a].total_cmp(&costs[b]));
        let top = &order[..elite];
        mean = std::array::from_fn(|j| top.iter().map(|&i| xs[i][j]).sum::<f64>() / elite as f64);
        sd = std::array::from_fn(|j| (top.iter().map(|&i| (xs[i][j] - mean[j]).powi(2)).sum::<f64>() / elite as f64).sqrt().max(0.03));
        (o.log)(TrainLog { stage: Stage::Pid, iteration: it, cost: costs[order[0]], baseline: current });
    }
    to_gains(&mean)
}

pub struct PolicyOptions<'a> {
    pub iterations: usize,
    pub pairs: usize,
    pub episodes: usize,
    pub sigma: f64,
    pub lr: f64,
    pub seed: f64,
    pub init: Option<Policy>,
    pub log: Box<dyn FnMut(TrainLog) + 'a>,
    /// Checked before each iteration: true ends the training with what it has so far.
    pub stop: Box<dyn Fn() -> bool + 'a>,
}

impl Default for PolicyOptions<'_> {
    fn default() -> Self {
        PolicyOptions { iterations: 60, pairs: 16, episodes: 4, sigma: 0.04, lr: 0.02, seed: 23.0, init: None, log: Box::new(|_| {}), stop: Box::new(|| false) }
    }
}

pub fn train_policy(p: &QuadParams, gains: Gains, mut o: PolicyOptions) -> Policy {
    let mut r = Rng::new(o.seed);
    let mut theta: Vec<f64> = match &o.init {
        Some(pol) => pol.theta.clone(),
        None => (0..POLICY_SIZE).map(|_| r.gauss() * 0.05).collect(),
    };
    let mut m = vec![0.0; POLICY_SIZE];
    let mut v = vec![0.0; POLICY_SIZE];
    let brain = |th: &[f64]| Brain { gains, policy: Some(Policy::new(th.to_vec())), rate_loop: RateLoop::Pid, rate_int_max: None };
    for it in 0..o.iterations {
        if (o.stop)() {
            break;
        }
        let scs: Vec<Scenario> = (0..o.episodes).map(|i| tracking_scenario((500_000 + 1000 * it + i) as f64, 7.0)).collect();
        let eps: Vec<Vec<f64>> = (0..o.pairs).map(|_| (0..POLICY_SIZE).map(|_| r.gauss()).collect()).collect();
        let cands: Vec<Vec<f64>> = eps
            .iter()
            .flat_map(|e| [1.0, -1.0].map(|sign| theta.iter().zip(e).map(|(x, ei)| x + sign * o.sigma * ei).collect::<Vec<_>>()))
            .collect();
        let scores = par_map(&cands, |th| cost(p, &brain(th), &scs));
        // Centered ranks: robust to the occasional crash episode dominating the cost.
        let mut order: Vec<usize> = (0..scores.len()).collect();
        order.sort_by(|&a, &b| scores[a].total_cmp(&scores[b]));
        let mut rank = vec![0.0; scores.len()];
        for (j, &i) in order.iter().enumerate() {
            rank[i] = 0.5 - j as f64 / (scores.len() - 1) as f64;
        }
        let mut g = vec![0.0; POLICY_SIZE];
        for (k, e) in eps.iter().enumerate() {
            let w = rank[2 * k] - rank[2 * k + 1];
            for i in 0..POLICY_SIZE {
                g[i] += w * e[i] / (o.pairs as f64 * o.sigma);
            }
        }
        // Adam step (ascending the rank score), with a little weight decay.
        for i in 0..POLICY_SIZE {
            let gi = g[i] - 0.005 * theta[i];
            m[i] = 0.9 * m[i] + 0.1 * gi;
            v[i] = 0.999 * v[i] + 0.001 * gi * gi;
            let mh = m[i] / (1.0 - 0.9f64.powi(it as i32 + 1));
            let vh = v[i] / (1.0 - 0.999f64.powi(it as i32 + 1));
            theta[i] += o.lr * mh / (vh.sqrt() + 1e-8);
        }
        let now = cost(p, &brain(&theta), &scs);
        let base = cost(p, &Brain { gains, policy: None, rate_loop: RateLoop::Pid, rate_int_max: None }, &scs);
        (o.log)(TrainLog { stage: Stage::Rl, iteration: it, cost: now, baseline: base });
    }
    Policy::new(theta)
}
