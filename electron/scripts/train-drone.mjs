// Trains the drone's controller in simulation and writes src/shared/sim/trained.ts:
//   node scripts/train-drone.mjs [pidIterations] [rlIterations]
// Stage 1 tunes the PID gains (cross-entropy method), stage 2 trains the neural residual
// (evolution strategies), both over randomized weather, mass and thrust.
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const S = require("../out/shared/sim/sim.js");
const T = require("../out/shared/sim/train.js");

const pidIt = Number(process.argv[2] ?? 20), rlIt = Number(process.argv[3] ?? 60);
const P = S.quad3();
const t0 = Date.now();
const log = (l) => console.log(`${l.stage} ${String(l.iteration).padStart(3)}  cost ${l.cost.toFixed(3)}${l.baseline !== undefined ? `  pid-only ${l.baseline.toFixed(3)}` : ""}  ${((Date.now() - t0) / 1000).toFixed(0)} s`);
const gains = T.tuneGains(P, { iterations: pidIt, log });
console.log("gains", gains);
const policy = T.trainPolicy(P, gains, { iterations: rlIt, log });

// Held-out check on episodes never used in training.
const test = Array.from({ length: 30 }, (_, i) => T.trackingScenario(9_000_000 + i));
const score = {
  defaultPid: T.cost(P, S.PID_ONLY(), test),
  tunedPid: T.cost(P, { gains, policy: null }, test),
  tunedPidNn: T.cost(P, { gains, policy }, test),
};
console.log("held-out cost", score);
const round = (x) => Math.round(x * 1e5) / 1e5;
writeFileSync(
  new URL("../src/shared/sim/trained.ts", import.meta.url),
  `// Written by scripts/train-drone.mjs: do not edit. Held-out tracking cost (lower is better):\n` +
    `// default PID ${score.defaultPid.toFixed(3)}, tuned PID ${score.tunedPid.toFixed(3)}, tuned PID + NN ${score.tunedPidNn.toFixed(3)}.\n\n` +
    `import type { Gains } from "./control";\n\n` +
    `export const TRAINED_GAINS: Gains = ${JSON.stringify(Object.fromEntries(Object.entries(gains).map(([k, v]) => [k, round(v)])))};\n\n` +
    `export const TRAINED_POLICY: number[] = ${JSON.stringify(Array.from(policy.theta, round))};\n\n` +
    `export const TRAINED_SCORE = ${JSON.stringify(Object.fromEntries(Object.entries(score).map(([k, v]) => [k, round(v)])))};\n`,
);
console.log("wrote src/shared/sim/trained.ts");
