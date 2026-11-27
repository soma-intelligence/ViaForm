// Training the controller in simulation, in two stages, over randomized weather and drones
// (domain randomization, so what it learns holds on the real one):
//   1. The PID gains, by the cross-entropy method: sample gain sets around a mean, keep the best
//      sixth, move the mean and shrink the spread.
//   2. The neural residual (policy.ts), by evolution strategies (Salimans et al. 2017): perturb
//      the weights in mirrored pairs, score both, step along the rank-weighted perturbations with
//      Adam. Reinforcement learning without gradients through the simulator.
// The score of a candidate is the cost of flying velocity steps in the same randomized episodes
// (common random numbers): squared velocity error, a little for body rates, a lot for a crash.
// For stabilization (scripts/train-stabilize.mjs) the episodes run on the realistic plant and
// sensors of realism.ts, and half of them hold a point while the drone is kicked, flipped, hit by
// gusts, loaded and has a prop damaged.

import { rng, type Rng, type V3 } from "./math";
import { DEFAULT_GAINS, GAIN_KEYS, type Gains } from "./control";
import { Policy, POLICY_SIZE } from "./policy";
import { runEpisode, type Brain, type Disturbance, type Scenario } from "./sim";
import type { Limits, RateLoop } from "./control";
import { REALISTIC, type Realism } from "./realism";
import type { QuadParams, WindSpec } from "./physics";
import type { Weather } from "./weather";

/** A random hard day: anything from calm to a gale, −10 °C to 38 °C, rain or snow, up to 2.5 km. */
export function randomWeather(r: Rng): Weather {
  const speed = r.range(0, 9), dir = r.range(0, 2 * Math.PI);
  const cold = r.next() < 0.3;
  const wind: WindSpec = {
    mean: [speed * Math.cos(dir), speed * Math.sin(dir), r.range(-0.5, 0.5)] as V3,
    turbulence: r.range(0, 2), lengthScale: r.range(6, 20), gustEvery: r.next() < 0.7 ? r.range(1.5, 6) : 0, gustPeak: r.range(1, 7),
  };
  return {
    name: "random", temperatureC: cold ? r.range(-10, 3) : r.range(5, 38), altitudeM: r.range(0, 2500), humidity: r.range(0.2, 1),
    rainMmH: !cold && r.next() < 0.3 ? r.range(1, 30) : 0, snowMmH: cold && r.next() < 0.5 ? r.range(0.5, 4) : 0,
    fogVisibilityM: r.next() < 0.2 ? r.range(30, 500) : Infinity, sun: r.range(0, 1), wind,
  };
}

/** Velocity steps in random directions, the inputs a planner gives. */
export function trackingScenario(seed: number, duration = 7): Scenario {
  const r = rng(seed);
  const steps: { t: number; v: V3 }[] = [{ t: 0, v: [0, 0, 0] }];
  for (let t = 1; t < duration; t += r.range(0.8, 1.8)) {
    const sp = r.range(0, 4.5), yaw = r.range(0, 2 * Math.PI);
    steps.push({ t, v: [sp * Math.cos(yaw), sp * Math.sin(yaw), r.range(-1.2, 1.2)] });
  }
  return {
    weather: randomWeather(r), mission: { kind: "track", at: [0, 0, 6], steps }, duration, seed,
    massScale: r.range(0.9, 1.15), thrustScale: r.range(0.9, 1.08),
  };
}

/** A random disturbance of each kind, at a random size. */
export function randomDisturbance(r: Rng, t: number): Disturbance {
  const dir = (): V3 => {
    const a = r.range(0, 2 * Math.PI), z = r.range(-0.5, 0.5);
    return [Math.cos(a) * Math.sqrt(1 - z * z), Math.sin(a) * Math.sqrt(1 - z * z), z];
  };
  const pick = r.next();
  if (pick < 0.3) {
    const d = dir(), j = r.range(0.01, 0.07);
    return { t, kind: "kick", impulse: [d[0] * j, d[1] * j, d[2] * j], at: [r.range(-0.06, 0.06), r.range(-0.06, 0.06), r.range(-0.02, 0.03)] };
  }
  if (pick < 0.55) {
    const d = dir(), s = r.range(2, 8);
    return { t, kind: "gust", wind: [d[0] * s, d[1] * s, d[2] * s * 0.4], length: r.range(0.3, 2) };
  }
  if (pick < 0.75) return { t, kind: "tumble", rates: [r.range(-14, 14), r.range(-14, 14), r.range(-4, 4)] };
  if (pick < 0.9) return { t, kind: "payload", kg: r.range(-0.01, 0.04), at: [r.range(-0.03, 0.03), r.range(-0.03, 0.03), 0] };
  return { t, kind: "prop", motor: Math.floor(r.range(0, 4)), health: r.range(0.75, 0.95) };
}

/** Holding a point in random weather while random things happen to the drone, every 1.5 to 3 s. */
export function stabilizeScenario(seed: number, duration = 9, realism: Realism = REALISTIC): Scenario {
  const r = rng(seed);
  const events: Disturbance[] = [];
  for (let t = r.range(1, 2); t < duration - 1; t += r.range(1.5, 3)) events.push(randomDisturbance(r, t));
  return {
    weather: randomWeather(r), mission: { kind: "stabilize", at: [0, 0, 6], events }, duration, seed, realism,
    massScale: r.range(0.9, 1.15), thrustScale: r.range(0.9, 1.08),
  };
}

/** The fixed stress test (the app's benchmark and the tests): every kind of disturbance, 3 s apart. */
export function stressBench(seed: number, weather: Weather, realism: Realism = REALISTIC): Scenario {
  const events: Disturbance[] = [
    { t: 2, kind: "kick", impulse: [0.05, 0, 0], at: [0, 0.04, 0.02] },
    { t: 5, kind: "gust", wind: [0, 6, 0], length: 1.2 },
    { t: 8, kind: "tumble", rates: [12, -5, 2] },
    { t: 11, kind: "payload", kg: 0.03, at: [0.03, 0.01, 0] },
    { t: 14, kind: "prop", motor: 1, health: 0.8 },
    { t: 17, kind: "kick", impulse: [0, 0, -0.06], at: [0.05, 0, 0] },
  ];
  return { weather, mission: { kind: "stabilize", at: [0, 0, 2.5], events }, duration: 20, seed, realism };
}

/** Half tracking, half disturbance rejection, all on the realistic plant. */
export const realisticScenario = (seed: number): Scenario =>
  seed % 2 ? { ...trackingScenario(seed), realism: REALISTIC } : stabilizeScenario(seed);

export function cost(P: QuadParams, brain: Brain, scenarios: Scenario[]): number {
  let total = 0;
  for (const sc of scenarios) {
    const r = runEpisode(P, brain, sc);
    // Holding a point: position error, and the attitude error (rad) weighs as much as 0.5 m.
    const err = sc.mission.kind === "stabilize" ? r.rmsError ** 2 + 4 * r.attitudeRms ** 2 : r.rmsError ** 2;
    total += err + (r.crashed ? 50 : 0);
  }
  return total / scenarios.length;
}

export type TrainLog = { stage: "pid" | "rl"; iteration: number; cost: number; baseline?: number };

export function tuneGains(P: QuadParams, opts: {
  iterations?: number; population?: number; episodes?: number; seed?: number; log?: (l: TrainLog) => void;
  /** Where to start (default gains), which rate loop, and which episodes (velocity steps). */
  init?: Gains; rateLoop?: RateLoop; limits?: Partial<Limits>; scenario?: (seed: number) => Scenario;
} = {}): Gains {
  const r = rng(opts.seed ?? 11);
  const N = opts.population ?? 24, elite = Math.max(2, Math.round(N / 6));
  const make = opts.scenario ?? ((seed: number) => trackingScenario(seed));
  const init = opts.init ?? DEFAULT_GAINS;
  let mean = GAIN_KEYS.map((k) => Math.log(init[k]));
  let sd = GAIN_KEYS.map(() => 0.35);
  const toGains = (x: number[]) => Object.fromEntries(GAIN_KEYS.map((k, i) => [k, Math.exp(x[i])])) as Gains;
  for (let it = 0; it < (opts.iterations ?? 20); it++) {
    const scs = Array.from({ length: opts.episodes ?? 6 }, (_, i) => make(1000 * it + i + 1));
    const pop = Array.from({ length: N }, (_, i) => (i === 0 ? mean : mean.map((m, j) => m + sd[j] * r.gauss())))
      .map((x) => ({ x, c: cost(P, { gains: toGains(x), policy: null, rateLoop: opts.rateLoop, limits: opts.limits }, scs) }))
      .sort((a, b) => a.c - b.c);
    const current = pop.find((p) => p.x === mean)!.c;
    const top = pop.slice(0, elite);
    mean = mean.map((_, j) => top.reduce((s, p) => s + p.x[j], 0) / elite);
    sd = sd.map((_, j) => Math.max(0.03, Math.sqrt(top.reduce((s, p) => s + (p.x[j] - mean[j]) ** 2, 0) / elite)));
    opts.log?.({ stage: "pid", iteration: it, cost: pop[0].c, baseline: current });
  }
  return toGains(mean);
}

export function trainPolicy(P: QuadParams, gains: Gains, opts: { iterations?: number; pairs?: number; episodes?: number; sigma?: number; lr?: number; seed?: number; init?: Policy; log?: (l: TrainLog) => void } = {}): Policy {
  const r = rng(opts.seed ?? 23);
  const theta = Float64Array.from(opts.init?.theta ?? new Float64Array(POLICY_SIZE).map(() => r.gauss() * 0.05));
  const m = new Float64Array(POLICY_SIZE), v = new Float64Array(POLICY_SIZE);
  const sigma = opts.sigma ?? 0.04, lr = opts.lr ?? 0.02, pairs = opts.pairs ?? 16;
  for (let it = 0; it < (opts.iterations ?? 60); it++) {
    const scs = Array.from({ length: opts.episodes ?? 4 }, (_, i) => trackingScenario(500_000 + 1000 * it + i));
    const eps: Float64Array[] = [];
    const scores: number[] = [];
    for (let k = 0; k < pairs; k++) {
      const e = new Float64Array(POLICY_SIZE).map(() => r.gauss());
      eps.push(e);
      for (const sign of [1, -1]) {
        const th = theta.map((x, i) => x + sign * sigma * e[i]);
        scores.push(cost(P, { gains, policy: new Policy(th) }, scs));
      }
    }
    // Centered ranks: robust to the occasional crash episode dominating the cost.
    const order = scores.map((s, i) => [s, i] as const).sort((a, b) => a[0] - b[0]);
    const rank = new Array(scores.length);
    order.forEach(([, i], j) => (rank[i] = 0.5 - j / (scores.length - 1)));
    const g = new Float64Array(POLICY_SIZE);
    for (let k = 0; k < pairs; k++) {
      const w = rank[2 * k] - rank[2 * k + 1];
      for (let i = 0; i < POLICY_SIZE; i++) g[i] += (w * eps[k][i]) / (pairs * sigma);
    }
    // Adam step (ascending the rank score), with a little weight decay.
    for (let i = 0; i < POLICY_SIZE; i++) {
      const gi = g[i] - 0.005 * theta[i];
      m[i] = 0.9 * m[i] + 0.1 * gi;
      v[i] = 0.999 * v[i] + 0.001 * gi * gi;
      const mh = m[i] / (1 - 0.9 ** (it + 1)), vh = v[i] / (1 - 0.999 ** (it + 1));
      theta[i] += (lr * mh) / (Math.sqrt(vh) + 1e-8);
    }
    const now = cost(P, { gains, policy: new Policy(theta) }, scs);
    const base = cost(P, { gains, policy: null }, scs);
    opts.log?.({ stage: "rl", iteration: it, cost: now, baseline: base });
  }
  return new Policy(theta);
}
