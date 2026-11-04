// The simulation as the Apple apps see it. The flight model lives in electron/src/shared/sim, in
// TypeScript, and both front ends run that same code: Electron directly, the Swift apps through
// JavaScriptCore, from the bundle scripts/build-sim.sh makes of this file. Everything crosses as
// JSON text, so this facade is the only contract the Swift side depends on: when the sim's API
// changes, this file is the one place to follow it, and the bundle fails to build until it does.

import { Flight, quad3, PID_ONLY, TRAINED, type Brain, type Frame } from "../../electron/src/shared/sim/sim";
import { obstacleCourse, randomCourse, type Course, type Obstacle } from "../../electron/src/shared/sim/world";
import { WEATHERS } from "../../electron/src/shared/sim/weather";
import { PARTS, partsMassKg } from "../../electron/src/shared/sim/parts";
import { rng } from "../../electron/src/shared/sim/math";

type StartOptions = { course: "obstacle" | "random"; seed: number; weather: number; brain: "pid" | "tuned" | "trained" };

let flight: Flight | null = null;
let trail: number[][] = [];

/** Infinity (clear air, no hit yet) has no JSON form; send a large number instead. */
const finite = (x: number) => (Number.isFinite(x) ? x : 1e9);

function obstacleJSON(o: Obstacle) {
  return o.kind === "box"
    ? { kind: "box", min: o.min, max: o.max, color: o.color ?? "#8b93a1" }
    : { kind: "post", c: o.c, r: o.r, z0: o.z0, z1: o.z1, color: o.color ?? "#e8e3d6" };
}

function brainFor(name: StartOptions["brain"]): Brain {
  if (name === "pid") return PID_ONLY();
  return TRAINED(name === "trained");
}

function frameJSON(f: Frame) {
  return {
    t: f.t, p: f.p, q: f.q, v: f.v, omega: f.omega, wind: f.wind, target: f.target,
    rays: f.hits.map((h) => ({ point: h.point, hit: h.hit })),
    voltage: f.voltage, soc: f.soc, planIndex: f.planIndex,
  };
}

function status() {
  const fl = flight!;
  return {
    finished: fl.finished,
    crashed: fl.s.crashed,
    collided: fl.collided,
    minClearance: finite(fl.minClearance),
    energyWh: fl.energyJ / 3600,
  };
}

const api = {
  /** The weather presets and the brains, for the pickers. */
  catalog(): string {
    return JSON.stringify({
      weathers: WEATHERS.map((w) => ({ name: w.name, temperatureC: w.temperatureC, wind: Math.hypot(...w.wind.mean), fog: finite(w.fogVisibilityM) })),
      brains: [
        { id: "pid", name: "Default PID" },
        { id: "tuned", name: "Tuned PID" },
        { id: "trained", name: "Tuned PID + neural residual" },
      ],
      courses: [
        { id: "obstacle", name: "Obstacle course" },
        { id: "random", name: "Random course" },
      ],
    });
  },

  /** The drone's parts list (bill of materials) with the masses the simulation uses. */
  parts(frameG: number): string {
    return JSON.stringify({ parts: PARTS, massKg: partsMassKg(frameG) });
  },

  /** Starts a flight and returns its world: obstacles, waypoints, gates and bounds. */
  start(json: string): string {
    const o = JSON.parse(json) as StartOptions;
    const course: Course = o.course === "random" ? randomCourse(rng(o.seed)) : obstacleCourse();
    const weather = WEATHERS[Math.max(0, Math.min(WEATHERS.length - 1, o.weather))];
    flight = new Flight(quad3(), brainFor(o.brain), {
      weather, mission: { kind: "waypoints", course }, duration: 40, seed: o.seed,
    });
    trail = [];
    return JSON.stringify({
      name: course.name, start: course.start, waypoints: course.waypoints,
      obstacles: course.obstacles.map(obstacleJSON), hidden: course.hidden, bounds: course.bounds,
      frame: frameJSON(flight.frame()), status: status(),
    });
  },

  /** Advances the flight by `seconds` of simulated time (2 ms physics steps) and returns the
   *  latest frame, the trail points added since the last call and the run's status. */
  advance(seconds: number): string {
    if (!flight) return JSON.stringify({ error: "no flight" });
    const steps = Math.max(1, Math.round(seconds / 0.002));
    const added: number[][] = [];
    for (let i = 0; i < steps && !flight.finished; i++) {
      flight.tick();
      if (i % 10 === 0) added.push([...flight.s.p]);
    }
    trail.push(...added);
    return JSON.stringify({ frame: frameJSON(flight.frame()), trail: added, status: status() });
  },
};

(globalThis as unknown as { ViaSim: typeof api }).ViaSim = api;
