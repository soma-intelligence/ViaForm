// The drone simulation (src/shared/sim): physics, weather, the generative frame, mapping, the
// trained controller, and flights in hard weather that must hover and finish the obstacle course.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { DT, PID_ONLY, quad3, runEpisode, TRAINED, type Scenario } from "../shared/sim/sim";
import { newState, step } from "../shared/sim/physics";
import { airDensity, Battery, Exposure, WEATHERS } from "../shared/sim/weather";
import { OccupancyGrid } from "../shared/sim/mapping";
import { obstacleCourse } from "../shared/sim/world";
import { LOADS, minimumArm } from "../shared/sim/generative";
import { FRAME, FRAME_OUTCOMES } from "../shared/sim/frame";
import { TRAINED_SCORE } from "../shared/sim/trained";
import { cost, trackingScenario } from "../shared/sim/train";
import { partsMassKg } from "../shared/sim/parts";

const P = quad3(partsMassKg(FRAME.massG), undefined, FRAME.arm / 1000);
const weather = (name: string) => WEATHERS.find((w) => w.name.startsWith(name))!;
const course = (w: string, seed: number): Scenario => ({ weather: weather(w), mission: { kind: "waypoints", course: obstacleCourse() }, duration: 90, seed });

test("physics: falls at g less the idle thrust, motors at idle", () => {
  const s = newState([0, 0, 10]);
  // 0.1 s: too slow yet for drag to matter.
  for (let i = 0; i < 50; i++) step(P, s, [0, 0, 0, 0], [0, 0, 0], DT);
  const a = 9.81 - (4 * P.kT * P.omegaIdle ** 2) / P.mass;
  assert.ok(Math.abs(s.v[2] + a * 0.1) < 0.03, `v ${s.v[2]}, expected ${-a * 0.1}`);
});

test("weather: thin hot air, rain, icing and cold batteries cost thrust and voltage", () => {
  assert.ok(airDensity(weather("Hot and high")) < 0.85 * airDensity(weather("Indoor")));
  assert.ok(airDensity(weather("Snow")) > airDensity(weather("Indoor")));
  const fog = new Exposure(weather("Freezing fog"));
  for (let i = 0; i < 60 / DT; i += 10) fog.update(DT * 10);
  assert.ok(fog.thrustFactor() < 0.95, `icing ${fog.thrustFactor()}`);
  const rain = new Exposure(weather("Rain"));
  for (let i = 0; i < 10 / DT; i += 10) rain.update(DT * 10);
  assert.ok(rain.thrustFactor() < 1 && rain.rainForce(P.propRadius) > 0);
  const warm = new Battery(0.65, 3, 25), cold = new Battery(0.65, 3, -10);
  warm.draw(20, 0.1);
  cold.draw(20, 0.1);
  assert.ok(cold.voltage < warm.voltage - 0.1, `sag ${warm.voltage} vs ${cold.voltage}`);
});

test("generative frame: clears the props, stiff and strong enough at a 1.5 safety factor", () => {
  assert.ok(FRAME.feasible);
  assert.ok(FRAME.arm >= minimumArm() - 0.01, "the props clear the frame (arm stored to 0.01 mm)");
  assert.ok(FRAME.deflection <= LOADS.maxDeflection);
  assert.ok(FRAME.stress * 1.5 <= 300 + 1e-6);
  const masses = FRAME_OUTCOMES.map((o) => o.design.massG);
  assert.deepEqual([...masses].sort((a, b) => a - b), masses, "a higher safety factor costs mass");
  assert.ok(partsMassKg(FRAME.massG) < 0.2, "under 200 g all up");
});

test("mapping: a wall seen scan after scan is occupied, a raindrop is not", () => {
  const g = new OccupancyGrid([-1, -1, 0], [5, 1, 3], 0.2);
  const from: [number, number, number] = [0, 0, 1];
  const wall = { sensor: 0, dir: [1, 0, 0] as [number, number, number], d: 3, point: [3, 0, 1] as [number, number, number], hit: true };
  const drop = { ...wall, d: 1.5, point: [1.5, 0, 1] as [number, number, number] };
  g.integrate(from, [drop]);
  for (let i = 0; i < 4; i++) g.integrate(from, [wall]);
  assert.ok(g.occupied(...g.cellOf([3, 0, 1])));
  assert.ok(!g.occupied(...g.cellOf([1.5, 0, 1])));
});

test("training: tuned gains and the neural residual each lower the tracking cost", () => {
  assert.ok(TRAINED_SCORE.tunedPid < TRAINED_SCORE.defaultPid && TRAINED_SCORE.tunedPidNn < TRAINED_SCORE.tunedPid);
  const held = [1, 2, 3, 4].map((i) => trackingScenario(77_000 + i));
  assert.ok(cost(P, TRAINED(false), held) < cost(P, PID_ONLY(), held));
});

test("hover: holds position in every weather without crashing", () => {
  for (const w of WEATHERS) {
    const r = runEpisode(P, TRAINED(), { weather: w, mission: { kind: "hover", at: [0, 0, 1.6] }, duration: 15, seed: 3 });
    assert.ok(!r.crashed, `${w.name} crashed`);
    assert.ok(r.rmsError < 1, `${w.name} rms ${r.rmsError}`);
  }
});

test("obstacle course: finished without touching anything, calm to gale", () => {
  for (const [w, seed, nn] of [["Indoor", 1, true], ["Breezy", 3, true], ["Gale", 1, false], ["Rain", 2, false], ["Snow", 3, true], ["Freezing fog", 1, false]] as const) {
    const r = runEpisode(P, TRAINED(nn), course(w, seed));
    assert.ok(r.completed && !r.collided && !r.crashed, `${w} seed ${seed}: completed ${r.completed}, collided ${r.collided}, crashed ${r.crashed}`);
  }
});
