// A 5-inch quadcopter built end to end through the addon: frame, motors, propellers and battery in
// the design, a flight controller in the electronics, the board mounted on the frame, then the
// checks a drone needs before it flies (mass, balance, thrust to weight, clearances, spinning
// propellers). drone.test.ts runs it; `npm run sample:drone` saves it as samples/drone.viaform.

/* eslint-disable @typescript-eslint/no-explicit-any */
export type Workspace = any;

// Layout, in mm: an X frame, motors on a 225 mm diagonal (a common 5-inch size).
export const MOTOR_SPAN = 225;
export const PROP_DIAMETER = 127;
export const ARM_ANGLES = [45, 135, 225, 315];
const R = MOTOR_SPAN / 2;
const PLATE = { size: 80, thickness: 3 };
const ARM = { length: R + 14, width: 14, thickness: 5 };
const MOTOR = { diameter: 28, height: 18 };
const PROP_Z = PLATE.thickness + MOTOR.height + 2;

// Thrust of one 2306 motor on a 5-inch prop at full throttle, from typical maker test data. The
// engine has no aerodynamics; this figure is the input of the thrust to weight check.
export const THRUST_PER_MOTOR_G = 1100;

/** Where motor `i` sits, in world mm. */
export function motorAt(i: number): [number, number] {
  const a = (ARM_ANGLES[i] * Math.PI) / 180;
  return [R * Math.cos(a), R * Math.sin(a)];
}

/** Builds the frame, motors, propellers and battery, each with its material. */
export function buildAirframe(w: Workspace): void {
  w.cad("material.create", { name: "Carbon Fiber", density_g_cm3: 1.6, color: "#2b2d31" });
  // Averages over the real parts' volume here: a 2306 motor is about 32 g, a 4S 1500 mAh pack about 185 g.
  w.cad("material.create", { name: "Motor Average", density_g_cm3: 2.9, color: "#9aa3ad" });
  w.cad("material.create", { name: "LiPo Pack", density_g_cm3: 2.35, color: "#c43c3c" });

  w.cad("solid.box", { length: PLATE.size, width: PLATE.size, height: PLATE.thickness, center: [0, 0, PLATE.thickness / 2], body_name: "Frame" });
  ARM_ANGLES.forEach((deg, i) => {
    const arm = `Arm${i + 1}`;
    w.cad("solid.box", { length: ARM.length, width: ARM.width, height: ARM.thickness, corner: [0, -ARM.width / 2, 0], body_name: arm });
    w.cad("solid.cylinder", { diameter: ARM.width * 2, height: ARM.thickness, base: [R, 0, 0], body_name: `${arm}Pad` });
    w.cad("solid.combine", { target: arm, tools: [`${arm}Pad`], operation: "join" });
    w.cad("solid.move", { bodies: [arm], axis: [0, 0, 1], angle: `${deg} deg` });
    w.cad("solid.combine", { target: "Frame", tools: [arm], operation: "join" });
  });
  w.cad("material.assign", { bodies: ["Frame"], material: "Carbon Fiber" });

  for (let i = 0; i < 4; i++) {
    const [x, y] = motorAt(i);
    w.cad("solid.cylinder", { diameter: MOTOR.diameter, height: MOTOR.height, base: [x, y, ARM.thickness], body_name: `Motor${i + 1}` });
    // Two blades and a hub; alternate props turn the other way, so they cross the arm the other way.
    const blade = `Prop${i + 1}`;
    w.cad("solid.box", { length: PROP_DIAMETER, width: 11, height: 2, center: [x, y, PROP_Z + 1], body_name: blade });
    w.cad("solid.cylinder", { diameter: 14, height: 6, base: [x, y, PROP_Z - 1], body_name: `${blade}Hub` });
    w.cad("solid.combine", { target: blade, tools: [`${blade}Hub`], operation: "join" });
  }
  w.cad("material.assign", { bodies: [1, 2, 3, 4].map((i) => `Motor${i}`), material: "Motor Average" });
  w.cad("material.assign", { bodies: [1, 2, 3, 4].map((i) => `Prop${i}`), material: "Polycarbonate" });

  // The pack hangs under the plate, strapped on its centre line.
  w.cad("solid.box", { length: 75, width: 35, height: 30, center: [0, 0, -15], body_name: "Battery" });
  w.cad("material.assign", { bodies: ["Battery"], material: "LiPo Pack" });
}

/** Makes each part a component and joins them: rigid airframe, a revolute joint per propeller. */
export function assemble(w: Workspace): string[] {
  const parts = ["Frame", "Battery", ...[1, 2, 3, 4].flatMap((i) => [`Motor${i}`, `Prop${i}`])];
  w.cad("component.from_bodies", { bodies: parts });
  const joints: string[] = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = motorAt(i);
    w.cad("joint.rigid_group", { occurrences: ["Frame:1", "Battery:1", `Motor${i + 1}:1`] });
    const j = w.cad("joint.create", {
      type: "revolute",
      name: `Prop${i + 1} spin`,
      a: { occurrence: `Motor${i + 1}:1`, point: [x, y, ARM.thickness + MOTOR.height], x: [1, 0, 0] },
      b: { occurrence: `Prop${i + 1}:1`, point: [x, y, PROP_Z - 1], x: [1, 0, 0] },
      flip: true,
    });
    joints.push(j.name ?? `Prop${i + 1} spin`);
  }
  return joints;
}

// MARK: Flight controller

/** A through-hole package in the project library: a symbol with pins left and right, and a
 *  matching footprint of two rows (or one when `rows` is 1) on a 2.54 mm pitch. */
function packageDef(name: string, reference: string, value: string, pins: string[], rows: 1 | 2) {
  const per = rows === 2 ? Math.ceil(pins.length / 2) : pins.length;
  const pitch = 2.54, span = rows === 2 ? 7.62 : 0;
  const symbolPins = pins.map((pin, i) => {
    const right = rows === 2 && i >= per;
    const row = right ? pins.length - 1 - i : i;
    return {
      number: String(i + 1), name: pin, position: { x: right ? 7.62 : -7.62, y: row * pitch - ((per - 1) * pitch) / 2 },
      angle: right ? 180 : 0, length: 2.54, electrical_type: "passive", unit: 1, body_style: 1,
    };
  });
  const h = (per * pitch) / 2;
  const symbol = {
    name, reference, value, description: `${value} (ViaForm drone sample)`, keywords: "drone flight controller", footprint: name,
    pins: symbolPins,
    graphics: [{ unit: 1, body_style: 1, primitive: { Rectangle: { start: { x: -5.08, y: -h }, end: { x: 5.08, y: h }, width: 0.254, fill: "background", layer: "" } } }],
    extends: null, raw_source: "", unsupported: [],
  };
  const pads = pins.map((_, i) => {
    const right = rows === 2 && i >= per;
    const row = right ? pins.length - 1 - i : i;
    return {
      number: String(i + 1), pad_type: "thru_hole", shape: i === 0 ? "rect" : "circle",
      position: { x: right ? span / 2 : -span / 2, y: row * pitch - ((per - 1) * pitch) / 2 }, rotation: 0,
      size: { x: 1.6, y: 1.6 }, layers: ["*.Cu", "*.Mask"], drill: { size: { x: 0.8, y: 0.8 }, offset: { x: 0, y: 0 } },
      roundrect_ratio: null, raw_source: "",
    };
  });
  const footprint = { name, description: `${rows === 2 ? "DIP" : "SIP"}-${pins.length}`, keywords: "", pads, graphics: [], raw_source: "", unsupported: [] };
  return { symbol, footprint };
}

const MCU_PINS = ["VDD", "GND", "M1", "M2", "M3", "M4", "SDA", "SCL", "RX", "LED"];
const IMU_PINS = ["VDD", "GND", "SDA", "SCL"];
const REG_PINS = ["VIN", "GND", "VOUT"];

/** A two-pin through-hole footprint on a 5.08 mm pitch, used for the connectors and passives so
 *  every pad reaches both copper layers. */
const TWO_PIN = {
  name: "FC_2P", description: "2-pin THT, 5.08 mm", keywords: "", graphics: [], raw_source: "", unsupported: [],
  pads: [-2.54, 2.54].map((x, i) => ({
    number: String(i + 1), pad_type: "thru_hole", shape: "circle", position: { x, y: 0 }, rotation: 0,
    size: { x: 1.6, y: 1.6 }, layers: ["*.Cu", "*.Mask"], drill: { size: { x: 0.8, y: 0.8 }, offset: { x: 0, y: 0 } },
    roundrect_ratio: null, raw_source: "",
  })),
};

/** The board: 50 × 50 mm around the usual 30.5 mm mounting pattern, so the part stand-ins that
 *  `linkPush` builds in 3D have room and do not touch. */
export const BOARD = { size: 50, holes: 30.5, track: 0.3 };

/** Where each part sits on the board (x right, y down, mm) and its rotation in degrees. */
const LAYOUT: Record<string, [number, number, number]> = {
  U1: [25, 27, 0], U2: [36, 28, 0], U3: [13, 25, 0],
  J1: [14, 35, 0], J2: [19, 5, 0], J3: [31, 5, 0], J4: [19, 45, 0], J5: [31, 45, 0], J6: [44, 28, 90],
  C1: [13, 14, 0], R1: [25, 13, 0], D1: [36, 15, 0],
};

/**
 * Draws the flight controller: battery in through a 5 V regulator to the MCU and the IMU (I2C),
 * four ESC outputs, a receiver input and a status LED; then places the parts on the board.
 */
export function buildFlightController(w: Workspace): void {
  w.pcb("project.rename", { name: "Flight controller" });
  for (const [name, ref, value, pins, rows] of [
    ["FC_MCU", "U", "Flight MCU", MCU_PINS, 2],
    ["FC_IMU", "U", "6-axis IMU", IMU_PINS, 1],
    ["FC_REG", "U", "5 V regulator", REG_PINS, 1],
  ] as const) {
    const { symbol, footprint } = packageDef(name, ref, value, [...pins], rows);
    w.pcb("library.symbol.upsert", { definition: symbol, notice: "Original ViaForm sample part" });
    w.pcb("library.footprint.upsert", { definition: footprint });
  }
  w.pcb("library.footprint.upsert", { definition: TWO_PIN });

  const place = (name: string, reference: string) => {
    const id = w.pcb("component.place_custom", { name, position: { x: 0, y: 0 }, reference }).result.id as number;
    w.pcb("footprint.assign_custom", { id, name });
    return id;
  };
  const add = (kind: string, reference: string, value: string) => {
    const id = w.pcb("component.add", { kind, position: { x: 0, y: 0 }, reference, value }).result.id as number;
    w.pcb("footprint.assign_custom", { id, name: TWO_PIN.name });
    return id;
  };
  const ids: Record<string, number> = {
    U1: place("FC_MCU", "U1"), U2: place("FC_IMU", "U2"), U3: place("FC_REG", "U3"),
    J1: add("connector", "J1", "Battery 4S"),
    J2: add("connector", "J2", "ESC 1"), J3: add("connector", "J3", "ESC 2"),
    J4: add("connector", "J4", "ESC 3"), J5: add("connector", "J5", "ESC 4"),
    J6: add("connector", "J6", "Receiver"),
    C1: add("capacitor", "C1", "10 µF"), R1: add("resistor", "R1", "1 kΩ"), D1: add("led", "D1", "Status"),
  };
  // Spread the schematic symbols on a grid so the sheet reads cleanly.
  Object.values(ids).forEach((id, i) => w.pcb("component.move", { id, position: { x: (i % 4) * 30, y: Math.floor(i / 4) * 30 } }));

  const parts = w.pcbInspect().project.components as { id: number; pins: { number: string; name: string }[] }[];
  const pin = (ref: string, which: number | string) => {
    const c = parts.find((p) => p.id === ids[ref])!;
    const p = typeof which === "number" ? c.pins[which] : c.pins.find((x) => x.name === which)!;
    return { component: c.id, pin: p.number };
  };
  const net = (name: string, pins: { component: number; pin: string }[]) => {
    const id = w.pcb("net.create", { name }).result.id;
    w.pcb("net.connect", { net: id, pins });
  };
  net("VBAT", [pin("J1", 0), pin("U3", "VIN")]);
  net("5V", [pin("U3", "VOUT"), pin("U1", "VDD"), pin("U2", "VDD"), pin("C1", 0)]);
  net("GND", [pin("J1", 1), pin("U3", "GND"), pin("U1", "GND"), pin("U2", "GND"), pin("C1", 1), pin("D1", 1),
    ...["J2", "J3", "J4", "J5", "J6"].map((j) => pin(j, 1))]);
  ["J2", "J3", "J4", "J5"].forEach((j, i) => net(`M${i + 1}`, [pin("U1", `M${i + 1}`), pin(j, 0)]));
  net("SDA", [pin("U1", "SDA"), pin("U2", "SDA")]);
  net("SCL", [pin("U1", "SCL"), pin("U2", "SCL")]);
  net("RX", [pin("U1", "RX"), pin("J6", 0)]);
  net("LED", [pin("U1", "LED"), pin("R1", 0)]);
  net("LED_K", [pin("R1", 1), pin("D1", 0)]);

  w.pcb("board.resize", { width: BOARD.size, height: BOARD.size });
  const m = (BOARD.size - BOARD.holes) / 2;
  for (const [x, y] of [[m, m], [BOARD.size - m, m], [m, BOARD.size - m], [BOARD.size - m, BOARD.size - m]]) {
    w.pcb("board.cutout.add", { center: { x, y }, radius: 1.6 });
  }
  w.pcb("board.sync");
  const footprints = w.pcbInspect().project.board.footprints as { id: number; component: number }[];
  for (const [ref, [x, y, degrees]] of Object.entries(LAYOUT)) {
    const id = footprints.find((f) => f.component === ids[ref])!.id;
    w.pcb("footprint.move", { id, position: { x, y } });
    if (degrees) w.pcb("footprint.rotate", { id, degrees });
  }
}

// MARK: Router

type P = { x: number; y: number };
type Copper = { net: number; a: P; b: P; r: number; layer: "F.Cu" | "B.Cu" };

function segDist(p: P, a: P, b: P): number {
  const dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy;
  const t = l ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l)) : 0;
  return Math.hypot(p.x - a.x - t * dx, p.y - a.y - t * dy);
}

/**
 * Routes every net pad to pad on a 0.2 mm grid, front layer first and back layer when the front
 * is blocked (every pad is plated, so a net may change layer at a pad). The engine's own
 * `track.route` draws a plain L and leaves clearance to the checks; this keeps the board clean.
 */
export function routeBoard(w: Workspace): { routed: number; failed: string[] } {
  const p = w.pcbInspect().project;
  const { width: W, height: H, clearance } = p.board;
  const half = BOARD.track / 2, step = 0.2, margin = step * 0.75;
  const nx = Math.round(W / step) + 1, ny = Math.round(H / step) + 1;
  const names = new Map<number, string>(p.nets.map((n: any) => [n.id, n.name]));
  const pads: { net: number; at: P; r: number }[] = [];
  for (const f of p.board.footprints) {
    for (const pad of f.pads) {
      const r = pad.geometry?.shape === "rect" ? Math.hypot(pad.geometry.size.x, pad.geometry.size.y) / 2 : pad.diameter / 2;
      // As the engine places pads: the offset turned by minus the footprint rotation.
      const t = (-f.rotation * Math.PI) / 180, c = Math.cos(t), s = Math.sin(t);
      const at = { x: f.position.x + pad.offset.x * c - pad.offset.y * s, y: f.position.y + pad.offset.x * s + pad.offset.y * c };
      pads.push({ net: pad.net ?? 0, at, r });
    }
  }
  const copper: Copper[] = pads.flatMap((q) => (["F.Cu", "B.Cu"] as const).map((layer) => ({ net: q.net, a: q.at, b: q.at, r: q.r, layer })));

  const free = (c: P, net: number, layer: string) => {
    const edge = half + clearance + margin;
    if (c.x < edge || c.y < edge || c.x > W - edge || c.y > H - edge) return false;
    for (const cut of p.board.cutouts) if (Math.hypot(c.x - cut.center.x, c.y - cut.center.y) < cut.radius + edge) return false;
    for (const k of copper) {
      if (k.layer !== layer || (k.net === net && net !== 0)) continue;
      if (segDist(c, k.a, k.b) < k.r + half + clearance + margin) return false;
    }
    return true;
  };

  const DIRS = [[1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]];
  const search = (from: P, to: P, net: number, layer: "F.Cu" | "B.Cu"): P[] | null => {
    const ok = new Uint8Array(nx * ny); // 0 unknown, 1 free, 2 blocked
    const isFree = (i: number, j: number) => {
      const k = j * nx + i;
      if (!ok[k]) ok[k] = free({ x: i * step, y: j * step }, net, layer) ? 1 : 2;
      return ok[k] === 1;
    };
    const cell = (q: P) => [Math.round(q.x / step), Math.round(q.y / step)];
    const [si, sj] = cell(from), [ti, tj] = cell(to);
    const cost = new Float64Array(nx * ny * 8).fill(Infinity);
    const prev = new Int32Array(nx * ny * 8).fill(-1);
    const heap: [number, number][] = [];
    const push = (c: number, s: number) => {
      heap.push([c, s]);
      for (let i = heap.length - 1; i > 0;) { const u = (i - 1) >> 1; if (heap[u][0] <= heap[i][0]) break; [heap[u], heap[i]] = [heap[i], heap[u]]; i = u; }
    };
    const pop = () => {
      const top = heap[0], last = heap.pop()!;
      if (heap.length) {
        heap[0] = last;
        for (let i = 0; ;) {
          const l = 2 * i + 1, r = l + 1; let m = i;
          if (l < heap.length && heap[l][0] < heap[m][0]) m = l;
          if (r < heap.length && heap[r][0] < heap[m][0]) m = r;
          if (m === i) break; [heap[m], heap[i]] = [heap[i], heap[m]]; i = m;
        }
      }
      return top;
    };
    // Cells inside the start pad are free for this net by construction.
    for (let d = 0; d < 8; d++) { cost[(sj * nx + si) * 8 + d] = 0; push(0, (sj * nx + si) * 8 + d); }
    while (heap.length) {
      const [c, s] = pop();
      if (c > cost[s]) continue;
      const k = s >> 3, d = s & 7, i = k % nx, j = (k / nx) | 0;
      if (i === ti && j === tj) {
        const path: P[] = [];
        for (let t = s; t >= 0; t = prev[t]) path.push({ x: ((t >> 3) % nx) * step, y: (((t >> 3) / nx) | 0) * step });
        return path.reverse();
      }
      for (let e = 0; e < 8; e++) {
        const a = i + DIRS[e][0], b = j + DIRS[e][1];
        if (a < 0 || b < 0 || a >= nx || b >= ny) continue;
        if (!(a === ti && b === tj) && !isFree(a, b)) continue;
        const turn = e === d ? 0 : Math.min((e - d + 8) % 8, (d - e + 8) % 8);
        if (turn > 2) continue;
        const n = c + (e % 2 ? Math.SQRT2 : 1) + turn * 3;
        const t = (b * nx + a) * 8 + e;
        if (n < cost[t]) { cost[t] = n; prev[t] = s; push(n, t); }
      }
    }
    return null;
  };

  // Pads per net, joined nearest first (Prim), shortest nets first, ground last.
  const byNet = new Map<number, P[]>();
  for (const q of pads) if (q.net) byNet.set(q.net, [...(byNet.get(q.net) ?? []), q.at]);
  const edges: { net: number; a: P; b: P }[] = [];
  for (const [net, pts] of byNet) {
    const done = [pts[0]], left = pts.slice(1);
    while (left.length) {
      let best = { d: Infinity, i: 0, from: pts[0] };
      for (const a of done) left.forEach((b, i) => { const d = Math.hypot(a.x - b.x, a.y - b.y); if (d < best.d) best = { d, i, from: a }; });
      const [b] = left.splice(best.i, 1);
      edges.push({ net, a: best.from, b });
      done.push(b);
    }
  }
  const len = (e: { a: P; b: P }) => Math.hypot(e.a.x - e.b.x, e.a.y - e.b.y);
  edges.sort((e, f) => Number(names.get(e.net) === "GND") - Number(names.get(f.net) === "GND") || len(e) - len(f));

  let routed = 0;
  const failed: string[] = [];
  for (const e of edges) {
    const layers = names.get(e.net) === "GND" ? (["B.Cu", "F.Cu"] as const) : (["F.Cu", "B.Cu"] as const);
    let done = false;
    for (const layer of layers) {
      const path = search(e.a, e.b, e.net, layer);
      if (!path) continue;
      // Pad centre, grid path with collinear points merged, pad centre.
      const pts = [e.a, ...path, e.b].filter((q, i, all) => {
        if (i === 0 || i === all.length - 1) return true;
        const a = all[i - 1], b = all[i + 1];
        return Math.abs((q.x - a.x) * (b.y - q.y) - (q.y - a.y) * (b.x - q.x)) > 1e-9;
      });
      for (let i = 1; i < pts.length; i++) {
        if (Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) < 1e-6) continue;
        w.pcb("track.add", { net: e.net, start: pts[i - 1], end: pts[i], width: BOARD.track, layer });
        copper.push({ net: e.net, a: pts[i - 1], b: pts[i], r: half, layer });
      }
      routed++;
      done = true;
      break;
    }
    if (!done) failed.push(`${names.get(e.net)} (${e.a.x},${e.a.y})-(${e.b.x},${e.b.y})`);
  }
  return { routed, failed };
}

// MARK: Board in 3D and the checks

/** Height of the nylon standoffs between the frame and the board. */
export const STANDOFF = 5;

/** Sends the routed board to the design and seats it on standoffs over the centre of the frame
 *  (the arms meet there, so the top of the stack is the arm thickness). */
export function mountBoard(w: Workspace): { board: string; host: string } {
  w.linkPush();
  return w.linkMount("Frame", [0, 0, Math.max(PLATE.thickness, ARM.thickness) + STANDOFF], [0, 0, 1]);
}

export type FlightReport = {
  massG: number;
  centreOfMass: [number, number, number];
  thrustToWeight: number;
  interferences: number;
  spin: { clear: boolean; collisions: number; truncated: boolean; samples: number };
};

/**
 * What the engine can say about the drone before it flies: mass and balance from the materials,
 * thrust to weight from the motor figure above, static clearances, then the four propellers spun
 * through a full turn against the airframe.
 */
export function flightChecks(w: Workspace): FlightReport {
  const mp = w.cad("assembly.mass_properties", {});
  const occ = (mp.occurrences as any[]).filter((o) => o.mass?.mass_kg);
  const kg = occ.reduce((s, o) => s + o.mass.mass_kg, 0);
  const com = [0, 1, 2].map((k) => occ.reduce((s, o) => s + o.mass.mass_kg * o.mass.center_of_mass_mm[k], 0) / kg) as [number, number, number];
  const interferences = w.cad("inspect.interference", {}).count as number;

  w.cad("motion.study", {
    name: "Props spin",
    steps: 36,
    keys: [1, 2, 3, 4].map((i) => ({ joint: `Prop${i} spin`, points: [[0, 0], [36, i % 2 ? 360 : -360]] })),
  });
  const airframe = (mp.occurrences as any[]).map((o) => o.name as string).filter((n) => n && !/^Prop\d:/.test(n) && n !== "Untitled");
  const run = w.cad("motion.interference", {
    study: "Props spin",
    occurrences: [1, 2, 3, 4].map((i) => `Prop${i}:1`),
    against: airframe,
    samples: 13,
    budget_s: 60,
  });
  return {
    massG: kg * 1000,
    centreOfMass: com,
    thrustToWeight: (4 * THRUST_PER_MOTOR_G) / (kg * 1000),
    interferences,
    spin: { clear: !!run.clear, collisions: (run.collisions ?? []).length, truncated: !!run.truncated, samples: run.samples ?? 13 },
  };
}
