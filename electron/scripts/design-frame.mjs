// Runs the generative frame study (src/shared/sim/generative.ts) and writes the outcomes to
// src/shared/sim/frame.ts, so the app shows the design without a ten-second study at start:
//   node scripts/design-frame.mjs
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const G = require("../out/shared/sim/generative.js");

const all = G.outcomes();
const r = (x, n = 3) => Math.round(x * 10 ** n) / 10 ** n;
const slim = (d) => ({
  arm: r(d.arm, 2), thickness: d.thickness, massG: r(d.massG, 2), deflection: r(d.deflection, 4), stress: r(d.stress, 1), feasible: d.feasible,
  nodes: d.nodes.map((n) => ({ x: r(n.x), y: r(n.y), fixed: n.fixed, motor: n.motor })),
  members: d.members.map((m) => ({ a: m.a, b: m.b, w: r(m.w), cls: m.cls })),
});
for (const o of all) console.log(`safety ${o.safety}: arm ${o.design.arm.toFixed(1)} mm, ${o.design.thickness} mm plate, ${o.design.massG.toFixed(1)} g, ${o.design.deflection.toFixed(3)} mm, ${o.design.stress.toFixed(0)} MPa`);
writeFileSync(
  new URL("../src/shared/sim/frame.ts", import.meta.url),
  `// Written by scripts/design-frame.mjs: do not edit. The generative frame study's outcomes, one\n` +
    `// per safety factor; the drone uses the one at 1.5.\n\n` +
    `import type { FrameDesign, GenerationLog } from "./generative";\n\n` +
    `export const FRAME_OUTCOMES: { safety: number; design: FrameDesign; history: GenerationLog[] }[] = ${JSON.stringify(
      all.map((o) => ({ safety: o.safety, design: slim(o.design), history: o.history.map((h) => ({ generation: h.generation, bestMass: r(h.bestMass, 2), feasible: h.feasible, meanMass: r(h.meanMass, 2) })) })),
    )};\n\n` +
    `export const FRAME = FRAME_OUTCOMES.find((o) => o.safety === 1.5)!.design;\n`,
);
console.log("wrote src/shared/sim/frame.ts");
