// Generative design of the frame: a carbon plate cut as a network of beams. A ground structure
// of candidate members links the stack mount to the four motor pads; an evolution strategy picks
// the arm length, the plate thickness and each member's width (zero removes it), and a beam
// finite-element model checks every candidate against the loads a 3-inch quad sees:
//   - full thrust with a 3× punch factor, out of the plate (bending and torsion: a grillage),
//   - a crash into a post at a motor, in the plate (radial and sideways: a plane frame),
//   - motor deflection at full thrust, which the attitude loop feels as flex.
// Geometry rules: 3-inch props clear each other and the 27 mm stack, members are at least 3 mm.
// Units: mm, N, MPa (N/mm²), g.

import { rng, type Rng } from "./math";

export const CARBON = { E: 50_000, G: 19_000, density: 1.6e-3 /* g/mm³ */, allowable: 300 };
export const PROP_DIAMETER = 76.2;
export const STACK = { board: 27, holes: 20 };
export const MOTOR_PAD = 8; // radius, mm (9×9 M2 pattern)
// Crash loads: a 175 g quad at 5 m/s stopped over about 1 cm of prop and bell (≈ 220 N peak),
// shared by the bell and the arm; half of it reaches the arm straight in, a third from the side.
// Deflection: arm flex under full thrust moves the motor; 0.12 mm keeps the first bending mode
// well above the 200–300 Hz of prop wash.
export const LOADS = { thrustN: 0.18 * 9.81, punch: 3, crashRadialN: 110, crashSideN: 70, maxDeflection: 0.12 };

export type Node2 = { x: number; y: number; fixed: boolean; motor: boolean };
export type Member = { a: number; b: number; w: number; cls: number };
export type FrameDesign = {
  arm: number; // centre to motor axis, mm
  thickness: number;
  nodes: Node2[];
  members: Member[]; // members with w > 0 only
  massG: number;
  deflection: number; // mm, motor under full thrust (no punch factor)
  stress: number; // MPa, worst case over the load cases
  feasible: boolean;
};

// MARK: Ground structure

/** Member classes of one arm, mirrored about the arm axis and repeated on all four arms. Each
 *  entry: two node names and whether it has a mirror twin. */
const CLASSES: [string, string][] = [
  ["hub", "m1"], // arm root on the diagonal
  ["m1", "m2"],
  ["m2", "motor"],
  ["axis", "s1"], // side rail from the plate edge
  ["s1", "motor"],
  ["s1", "m1"], // bracing
  ["s1", "m2"],
  ["axis", "m1"],
  ["s1", "s1n"], // ring between neighbouring arms
  ["hub", "s1"],
];
export const CLASS_COUNT = CLASSES.length;

/** Builds the full ground structure for an arm length; widths per class. */
export function groundStructure(arm: number, widths: number[]): { nodes: Node2[]; members: Member[] } {
  const nodes: Node2[] = [];
  const index = new Map<string, number>();
  const at = (key: string, x: number, y: number, fixed = false, motor = false) => {
    const k = `${x.toFixed(4)},${y.toFixed(4)}`;
    if (!index.has(k)) {
      index.set(k, nodes.length);
      nodes.push({ x, y, fixed, motor });
    }
    void key;
    return index.get(k)!;
  };
  const polar = (r: number, deg: number) => [r * Math.cos((deg * Math.PI) / 180), r * Math.sin((deg * Math.PI) / 180)] as const;
  const hubR = (STACK.board / 2) * Math.SQRT2 * 0.92; // plate corner at the diagonal
  const members: Member[] = [];
  for (let q = 0; q < 4; q++) {
    const base = 45 + 90 * q;
    for (const side of [1, -1]) {
      const named: Record<string, number> = {
        hub: at("hub", ...polar(hubR, base), true),
        axis: at("axis", ...polar(STACK.board / 2, base + side * 45), true),
        m1: at("m1", ...polar(arm * 0.45, base)),
        m2: at("m2", ...polar(arm * 0.72, base)),
        motor: at("motor", ...polar(arm, base), false, true),
        s1: at("s1", ...polar(arm * 0.6, base + side * 16)),
        s1n: at("s1n", ...polar(arm * 0.6, base + side * (90 - 16))),
      };
      CLASSES.forEach(([a, b], cls) => {
        if (widths[cls] <= 0) return;
        const ia = named[a], ib = named[b];
        if (!members.some((m) => (m.a === ia && m.b === ib) || (m.a === ib && m.b === ia))) members.push({ a: ia, b: ib, w: widths[cls], cls });
      });
    }
  }
  return { nodes, members };
}

// MARK: Beam finite elements

function solve(K: Float64Array, f: Float64Array, n: number): Float64Array | null {
  // Gaussian elimination with partial pivoting on a dense symmetric system.
  const A = K.slice(), b = f.slice();
  for (let c = 0; c < n; c++) {
    let p = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(A[r * n + c]) > Math.abs(A[p * n + c])) p = r;
    if (Math.abs(A[p * n + c]) < 1e-9) return null;
    if (p !== c) {
      for (let j = 0; j < n; j++) [A[c * n + j], A[p * n + j]] = [A[p * n + j], A[c * n + j]];
      [b[c], b[p]] = [b[p], b[c]];
    }
    for (let r = c + 1; r < n; r++) {
      const k = A[r * n + c] / A[c * n + c];
      if (!k) continue;
      for (let j = c; j < n; j++) A[r * n + j] -= k * A[c * n + j];
      b[r] -= k * b[c];
    }
  }
  const x = new Float64Array(n);
  for (let r = n - 1; r >= 0; r--) {
    let s = b[r];
    for (let j = r + 1; j < n; j++) s -= A[r * n + j] * x[j];
    x[r] = s / A[r * n + r];
  }
  return x;
}

type Analysis = { disp: Float64Array; stress: number } | null;

/** Out of plane: node DOFs [w, ∂w/∂x, ∂w/∂y]; bending along the member, torsion across it. */
function grillage(nodes: Node2[], members: Member[], t: number, loads: Map<number, number>): Analysis {
  const n = nodes.length * 3;
  const K = new Float64Array(n * n), f = new Float64Array(n);
  const local: { T: number[][]; k: number[][]; m: Member; l: number; c: number; s: number }[] = [];
  for (const m of members) {
    const A = nodes[m.a], B = nodes[m.b];
    const l = Math.hypot(B.x - A.x, B.y - A.y), c = (B.x - A.x) / l, s = (B.y - A.y) / l;
    const EI = (CARBON.E * m.w * t ** 3) / 12;
    const GJ = CARBON.G * (m.w * t ** 3 / 3) * (1 - (0.63 * t) / Math.max(m.w, t));
    // Local DOFs: w1, slope1 (along), twist1 (across slope), w2, slope2, twist2.
    const b = EI / l ** 3, g = GJ / l;
    const k = [
      [12 * b, 6 * l * b, 0, -12 * b, 6 * l * b, 0],
      [6 * l * b, 4 * l * l * b, 0, -6 * l * b, 2 * l * l * b, 0],
      [0, 0, g, 0, 0, -g],
      [-12 * b, -6 * l * b, 0, 12 * b, -6 * l * b, 0],
      [6 * l * b, 2 * l * l * b, 0, -6 * l * b, 4 * l * l * b, 0],
      [0, 0, -g, 0, 0, g],
    ];
    // local = T · global, with global node DOFs [w, gx, gy].
    const T = Array.from({ length: 6 }, () => new Array(6).fill(0));
    for (const o of [0, 3]) {
      T[o][o] = 1;
      T[o + 1][o + 1] = c; T[o + 1][o + 2] = s;
      T[o + 2][o + 1] = -s; T[o + 2][o + 2] = c;
    }
    local.push({ T, k, m, l, c, s });
    assemble(K, n, T, k, [m.a * 3, m.a * 3 + 1, m.a * 3 + 2, m.b * 3, m.b * 3 + 1, m.b * 3 + 2]);
  }
  for (const [node, fz] of loads) f[node * 3] += fz;
  const disp = constrainAndSolve(K, f, n, nodes, 3);
  if (!disp) return null;
  let stress = 0;
  for (const e of local) {
    const ids = [e.m.a * 3, e.m.a * 3 + 1, e.m.a * 3 + 2, e.m.b * 3, e.m.b * 3 + 1, e.m.b * 3 + 2];
    const d = ids.map((i) => disp[i]);
    const dl = e.T.map((row) => row.reduce((s2, v, j) => s2 + v * d[j], 0));
    const fl = e.k.map((row) => row.reduce((s2, v, j) => s2 + v * dl[j], 0));
    const I = (e.m.w * t ** 3) / 12;
    const M = Math.max(Math.abs(fl[1]), Math.abs(fl[4]));
    const sigma = (M * t) / 2 / I;
    const Tq = Math.abs(fl[2]);
    const tau = Tq / ((e.m.w * t * t) / 3);
    stress = Math.max(stress, Math.sqrt(sigma * sigma + 3 * tau * tau));
  }
  return { disp, stress };
}

/** In plane: node DOFs [u, v, θz]; axial and in-plane bending. */
function planeFrame(nodes: Node2[], members: Member[], t: number, loads: Map<number, [number, number]>): Analysis {
  const n = nodes.length * 3;
  const K = new Float64Array(n * n), f = new Float64Array(n);
  const local: { T: number[][]; k: number[][]; m: Member }[] = [];
  for (const m of members) {
    const A = nodes[m.a], B = nodes[m.b];
    const l = Math.hypot(B.x - A.x, B.y - A.y), c = (B.x - A.x) / l, s = (B.y - A.y) / l;
    const EA = CARBON.E * m.w * t, EI = (CARBON.E * t * m.w ** 3) / 12;
    const a = EA / l, b = EI / l ** 3;
    const k = [
      [a, 0, 0, -a, 0, 0],
      [0, 12 * b, 6 * l * b, 0, -12 * b, 6 * l * b],
      [0, 6 * l * b, 4 * l * l * b, 0, -6 * l * b, 2 * l * l * b],
      [-a, 0, 0, a, 0, 0],
      [0, -12 * b, -6 * l * b, 0, 12 * b, -6 * l * b],
      [0, 6 * l * b, 2 * l * l * b, 0, -6 * l * b, 4 * l * l * b],
    ];
    const T = Array.from({ length: 6 }, () => new Array(6).fill(0));
    for (const o of [0, 3]) {
      T[o][o] = c; T[o][o + 1] = s;
      T[o + 1][o] = -s; T[o + 1][o + 1] = c;
      T[o + 2][o + 2] = 1;
    }
    local.push({ T, k, m });
    assemble(K, n, T, k, [m.a * 3, m.a * 3 + 1, m.a * 3 + 2, m.b * 3, m.b * 3 + 1, m.b * 3 + 2]);
  }
  for (const [node, [fx, fy]] of loads) {
    f[node * 3] += fx;
    f[node * 3 + 1] += fy;
  }
  const disp = constrainAndSolve(K, f, n, nodes, 3);
  if (!disp) return null;
  let stress = 0;
  for (const e of local) {
    const ids = [e.m.a * 3, e.m.a * 3 + 1, e.m.a * 3 + 2, e.m.b * 3, e.m.b * 3 + 1, e.m.b * 3 + 2];
    const d = ids.map((i) => disp[i]);
    const dl = e.T.map((row) => row.reduce((s2, v, j) => s2 + v * d[j], 0));
    const fl = e.k.map((row) => row.reduce((s2, v, j) => s2 + v * dl[j], 0));
    const N = Math.abs(fl[0]), M = Math.max(Math.abs(fl[2]), Math.abs(fl[5]));
    const I = (t * e.m.w ** 3) / 12;
    stress = Math.max(stress, N / (e.m.w * t) + (M * e.m.w) / 2 / I);
  }
  return { disp, stress };
}

function assemble(K: Float64Array, n: number, T: number[][], k: number[][], ids: number[]) {
  // K += Tᵀ k T on the element's DOFs.
  const kT = k.map((row) => T[0].map((_, j) => row.reduce((s, v, r) => s + v * T[r][j], 0)));
  for (let i = 0; i < 6; i++) for (let j = 0; j < 6; j++) {
    let s = 0;
    for (let r = 0; r < 6; r++) s += T[r][i] * kT[r][j];
    K[ids[i] * n + ids[j]] += s;
  }
}

function constrainAndSolve(K: Float64Array, f: Float64Array, n: number, nodes: Node2[], dof: number): Float64Array | null {
  // The stack plate is stiff and carries the mass: clamp its nodes (inertia relief at the hub).
  const free = [] as number[];
  nodes.forEach((nd, i) => { if (!nd.fixed) for (let d = 0; d < dof; d++) free.push(i * dof + d); });
  // Nodes no member reaches have no stiffness: drop their DOFs (their load, if any, fails below).
  const used = free.filter((i) => K[i * n + i] > 0);
  if (used.length !== free.length && free.some((i) => f[i] !== 0 && K[i * n + i] === 0)) return null;
  const m = used.length;
  const Kr = new Float64Array(m * m), fr = new Float64Array(m);
  used.forEach((gi, a) => {
    fr[a] = f[gi];
    used.forEach((gj, b) => (Kr[a * m + b] = K[gi * n + gj]));
  });
  const x = solve(Kr, fr, m);
  if (!x) return null;
  const out = new Float64Array(n);
  used.forEach((gi, a) => (out[gi] = x[a]));
  return out;
}

// MARK: Evaluation

export function evaluate(arm: number, thickness: number, rawWidths: number[], safety = 1): FrameDesign {
  const widths = rawWidths.map((w) => (w < 2.5 ? 0 : Math.min(Math.max(w, 3), 12)));
  const { nodes, members } = groundStructure(arm, widths);
  const motors = nodes.map((nd, i) => (nd.motor ? i : -1)).filter((i) => i >= 0);
  let mass = STACK.board * STACK.board * thickness * CARBON.density; // centre plate
  mass += motors.length * Math.PI * MOTOR_PAD ** 2 * thickness * CARBON.density;
  for (const m of members) {
    const A = nodes[m.a], B = nodes[m.b];
    mass += Math.hypot(B.x - A.x, B.y - A.y) * m.w * thickness * CARBON.density;
  }
  const fail = (): FrameDesign => ({ arm, thickness, nodes, members, massG: mass, deflection: Infinity, stress: Infinity, feasible: false });
  if (!members.length) return fail();

  const thrust = new Map(motors.map((i) => [i, LOADS.thrustN] as [number, number]));
  const flex = grillage(nodes, members, thickness, thrust);
  if (!flex) return fail();
  const deflection = Math.max(...motors.map((i) => Math.abs(flex.disp[i * 3])));
  const punchStress = flex.stress * LOADS.punch;

  // Crash on the first motor: straight in, then from the side.
  const m0 = motors[0], nd = nodes[m0], r = Math.hypot(nd.x, nd.y);
  const radial = planeFrame(nodes, members, thickness, new Map([[m0, [(-nd.x / r) * LOADS.crashRadialN, (-nd.y / r) * LOADS.crashRadialN]]]));
  const side = planeFrame(nodes, members, thickness, new Map([[m0, [(-nd.y / r) * LOADS.crashSideN, (nd.x / r) * LOADS.crashSideN]]]));
  if (!radial || !side) return fail();
  const stress = Math.max(punchStress, radial.stress, side.stress);
  const geometric = arm * Math.SQRT2 >= PROP_DIAMETER + 4 && Math.SQRT2 * (arm / Math.SQRT2 - STACK.board / 2) >= PROP_DIAMETER / 2 + 3;
  return {
    arm, thickness, nodes, members, massG: mass, deflection, stress,
    feasible: geometric && deflection <= LOADS.maxDeflection && stress * safety <= CARBON.allowable,
  };
}

/** Smallest arm that clears the props from each other and from the stack. */
export function minimumArm(): number {
  return Math.max((PROP_DIAMETER + 4) / Math.SQRT2, (PROP_DIAMETER / 2 + 3) / Math.SQRT2 * Math.SQRT2 + (STACK.board / 2) * Math.SQRT2);
}

export type GenerationLog = { generation: number; bestMass: number; feasible: boolean; meanMass: number };

/**
 * Cross-entropy evolution strategy over [arm, widths...] for each plate thickness. The score is
 * the mass plus steep penalties for flex, stress and geometry; the best feasible design wins.
 */
export function optimise(opts: { seed?: number; generations?: number; population?: number; safety?: number } = {}): { best: FrameDesign; history: GenerationLog[] } {
  const safety = opts.safety ?? 1;
  const rand: Rng = rng(opts.seed ?? 7);
  const G = opts.generations ?? 70, N = opts.population ?? 60, elite = Math.round(N / 6);
  const armMin = minimumArm(), armMax = armMin + 12;
  const score = (d: FrameDesign) =>
    d.massG +
    (Number.isFinite(d.deflection) ? 200 * Math.max(0, d.deflection / LOADS.maxDeflection - 1) + 200 * Math.max(0, (d.stress * safety) / CARBON.allowable - 1) : 1e4);
  let best: FrameDesign | null = null;
  const history: GenerationLog[] = [];
  for (const t of [2, 2.5, 3, 4]) {
    const dim = 1 + CLASS_COUNT;
    let mean = [armMin + 2, ...new Array(CLASS_COUNT).fill(6)];
    let sd = [4, ...new Array(CLASS_COUNT).fill(4)];
    for (let g = 0; g < G; g++) {
      const pop = Array.from({ length: N }, () => {
        const x = mean.map((m, i) => m + sd[i] * rand.gauss());
        x[0] = Math.min(Math.max(x[0], armMin), armMax);
        const d = evaluate(x[0], t, x.slice(1), safety);
        return { x, d, s: score(d) };
      }).sort((a, b) => a.s - b.s);
      const top = pop.slice(0, elite);
      mean = mean.map((_, i) => top.reduce((s, p) => s + p.x[i], 0) / elite);
      sd = sd.map((_, i) => Math.max(Math.sqrt(top.reduce((s, p) => s + (p.x[i] - mean[i]) ** 2, 0) / elite), i === 0 ? 0.2 : 0.3));
      const lead = pop[0].d;
      if (lead.feasible && (!best || lead.massG < best.massG)) best = lead;
      history.push({ generation: history.length, bestMass: best?.massG ?? lead.massG, feasible: !!best, meanMass: pop.reduce((s, p) => s + p.d.massG, 0) / N });
      void dim;
    }
  }
  if (!best) throw new Error("no feasible frame found");
  return { best, history };
}

export type Outcome = { safety: number; design: FrameDesign; history: GenerationLog[] };

/** Like a generative study: one outcome per crash safety factor, lightest first. The drone uses
 *  `chooseOutcome`: the lightest one that survives the crash loads with a factor of 1.5. */
export function outcomes(seed = 7): Outcome[] {
  return [1, 1.5, 2].map((safety) => {
    const r = optimise({ seed, safety });
    return { safety, design: r.best, history: r.history };
  });
}
export const chooseOutcome = (all: Outcome[]) => all.find((o) => o.safety === 1.5) ?? all[0];
