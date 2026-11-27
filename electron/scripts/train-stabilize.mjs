// Tunes the controller for disturbance rejection on the realistic plant (realism.ts) and writes
// src/shared/sim/stable.ts:
//   node scripts/train-stabilize.mjs [iterations]
// Starts from the gains train-drone.mjs found and tunes them twice, once with the PID rate loop
// and once with INDI, over episodes that are half velocity tracking and half holding a point
// while the drone is kicked, flipped, hit by gusts, loaded and has a prop damaged.
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const S = require("../out/shared/sim/sim.js");
const T = require("../out/shared/sim/train.js");

const iterations = Number(process.argv[2] ?? 16);
const P = S.quad3();
const start = S.TRAINED(false).gains;
const t0 = Date.now();
const log = (name) => (l) => console.log(`${name} ${String(l.iteration).padStart(3)}  cost ${l.cost.toFixed(3)}  mean ${l.baseline.toFixed(3)}  ${((Date.now() - t0) / 1000).toFixed(0)} s`);
const opts = { iterations, population: 20, episodes: 12, init: start, scenario: T.realisticScenario, limits: { rateIntMax: 50 } };
const pid = T.tuneGains(P, { ...opts, rateLoop: "pid", seed: 31, log: log("pid ") });
console.log("pid", pid);
const indi = T.tuneGains(P, { ...opts, rateLoop: "indi", seed: 37, log: log("indi") });
console.log("indi", indi);

// Held-out: episodes never used in tuning.
const test = Array.from({ length: 40 }, (_, i) => T.realisticScenario(7_000_000 + i));
const score = {
  defaultPid: T.cost(P, S.PID_ONLY(), test),
  trainedPid: T.cost(P, S.TRAINED(false), test),
  stablePid: T.cost(P, { gains: pid, policy: null, rateLoop: "pid", limits: opts.limits }, test),
  stableIndi: T.cost(P, { gains: indi, policy: null, rateLoop: "indi", limits: opts.limits }, test),
};
console.log("held-out cost", score);
const round = (x) => Math.round(x * 1e5) / 1e5;
const rec = (g) => JSON.stringify(Object.fromEntries(Object.entries(g).map(([k, v]) => [k, round(v)])));
writeFileSync(
  new URL("../src/shared/sim/stable.ts", import.meta.url),
  `// Written by scripts/train-stabilize.mjs: do not edit. Held-out cost on the realistic plant, half\n` +
    `// tracking and half disturbance rejection (lower is better): default PID ${score.defaultPid.toFixed(3)},\n` +
    `// first training ${score.trainedPid.toFixed(3)}, retuned PID ${score.stablePid.toFixed(3)}, retuned INDI ${score.stableIndi.toFixed(3)}.\n\n` +
    `import type { Gains } from "./control";\n\n` +
    `export const STABLE_PID: Gains = ${rec(pid)};\n\n` +
    `export const STABLE_INDI: Gains = ${rec(indi)};\n\n` +
    `export const STABLE_SCORE = ${rec(score)};\n`,
);
console.log("wrote src/shared/sim/stable.ts");
