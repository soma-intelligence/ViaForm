// The world the drone flies in: obstacles (boxes, posts, gate frames), the time-of-flight
// sensors of the companion board as ray fans, collision tests, and the obstacle courses.

import { add, mv, norm, qToM3, sub, type Q, type Rng, type V3 } from "./math";

export type Box = { kind: "box"; min: V3; max: V3; color?: string };
export type Post = { kind: "post"; c: [number, number]; r: number; z0: number; z1: number; color?: string };
export type Obstacle = Box | Post;

/** A gate: a square frame standing on two legs, facing `yaw`; fly through its centre. */
export type Gate = { center: V3; yaw: number; size: number; bar: number };

export function gateObstacles(g: Gate): Box[] {
  // The frame as four bars, axis-aligned when the gate faces x or y (the courses only use those).
  const h = g.size / 2, b = g.bar;
  const alongX = Math.abs(Math.cos(g.yaw)) > 0.5; // the drone flies along x, so the frame spans y
  const [cx, cy, cz] = g.center;
  const span = (u0: number, u1: number, z0: number, z1: number): Box =>
    alongX
      ? { kind: "box", min: [cx - b / 2, cy + u0, z0], max: [cx + b / 2, cy + u1, z1], color: "#ff6a2b" }
      : { kind: "box", min: [cx + u0, cy - b / 2, z0], max: [cx + u1, cy + b / 2, z1], color: "#ff6a2b" };
  return [
    span(-h - b, -h, 0, cz + h + b), // left leg up to the top bar
    span(h, h + b, 0, cz + h + b), // right leg
    span(-h, h, cz + h, cz + h + b), // top bar
    span(-h, h, cz - h - b, cz - h), // bottom bar
  ];
}

// MARK: Rays

/** Distance along a unit ray to the obstacle, or Infinity. */
export function rayHit(o: Obstacle, from: V3, dir: V3): number {
  if (o.kind === "box") {
    let t0 = 0, t1 = Infinity;
    for (let i = 0; i < 3; i++) {
      if (Math.abs(dir[i]) < 1e-12) {
        if (from[i] < o.min[i] || from[i] > o.max[i]) return Infinity;
        continue;
      }
      let a = (o.min[i] - from[i]) / dir[i], b = (o.max[i] - from[i]) / dir[i];
      if (a > b) [a, b] = [b, a];
      t0 = Math.max(t0, a);
      t1 = Math.min(t1, b);
      if (t0 > t1) return Infinity;
    }
    return t0;
  }
  const ox = from[0] - o.c[0], oy = from[1] - o.c[1];
  const a = dir[0] * dir[0] + dir[1] * dir[1];
  if (a < 1e-12) return Infinity;
  const b = 2 * (ox * dir[0] + oy * dir[1]), c = ox * ox + oy * oy - o.r * o.r;
  const disc = b * b - 4 * a * c;
  if (disc < 0) return Infinity;
  const t = (-b - Math.sqrt(disc)) / (2 * a);
  if (t < 0) return c < 0 ? 0 : Infinity;
  const z = from[2] + t * dir[2];
  return z >= o.z0 && z <= o.z1 ? t : Infinity;
}

/** Ray against the obstacles and the ground plane. */
export function raycast(obstacles: Obstacle[], from: V3, dir: V3, max: number): number {
  let best = dir[2] < -1e-9 ? -from[2] / dir[2] : Infinity;
  for (const o of obstacles) best = Math.min(best, rayHit(o, from, dir));
  return Math.min(best, max);
}

/** Shortest distance from a point to the obstacle's surface (negative inside). */
export function distanceTo(o: Obstacle, p: V3): number {
  if (o.kind === "box") {
    const d = [0, 1, 2].map((i) => Math.max(o.min[i] - p[i], 0, p[i] - o.max[i]));
    const out = Math.hypot(d[0], d[1], d[2]);
    if (out > 0) return out;
    return -Math.min(...[0, 1, 2].map((i) => Math.min(p[i] - o.min[i], o.max[i] - p[i])));
  }
  const radial = Math.hypot(p[0] - o.c[0], p[1] - o.c[1]) - o.r;
  const vertical = Math.max(o.z0 - p[2], p[2] - o.z1, 0);
  return radial > 0 || vertical > 0 ? Math.hypot(Math.max(radial, 0), vertical) : Math.max(radial, -vertical);
}

export const clearance = (obstacles: Obstacle[], p: V3) => obstacles.reduce((m, o) => Math.min(m, distanceTo(o, p)), Infinity);

// MARK: Time-of-flight sensors

/** One VL53L1X-class sensor: a direction in body axes and a square field of view split into
 *  zones (its programmable region of interest), each read as one ray. */
export type TofSpec = { name: string; yaw: number; pitch: number; fov: number; zones: number; range: number; sigma: number };

/** The companion board: front, front-left, front-right, left, right and down. VL53L1X long mode
 *  reaches about 4 m indoors and much less in sunlight; `range` is set by the scenario. */
export function tofArray(range = 4): TofSpec[] {
  const s = (name: string, yaw: number, pitch: number): TofSpec => ({ name, yaw, pitch, fov: 27, zones: 4, range, sigma: 0.015 });
  return [s("front", 0, 0), s("front-left", 35, 0), s("front-right", -35, 0), s("left", 90, 0), s("right", -90, 0), s("down", 0, -90)];
}

export type TofHit = { sensor: number; dir: V3; d: number; point: V3; hit: boolean };

/** Reads every zone of every sensor from the drone at p with attitude q. */
export function readTof(sensors: TofSpec[], obstacles: Obstacle[], p: V3, q: Q, rand?: Rng): TofHit[] {
  const R = qToM3(q);
  const out: TofHit[] = [];
  sensors.forEach((s, k) => {
    for (let i = 0; i < s.zones; i++) {
      for (let j = 0; j < s.zones; j++) {
        const da = ((i + 0.5) / s.zones - 0.5) * s.fov, de = ((j + 0.5) / s.zones - 0.5) * s.fov;
        const yaw = ((s.yaw + da) * Math.PI) / 180, pitch = ((s.pitch + de) * Math.PI) / 180;
        const body: V3 = [Math.cos(pitch) * Math.cos(yaw), Math.cos(pitch) * Math.sin(yaw), Math.sin(pitch)];
        const dir = mv(R, body);
        let d = raycast(obstacles, p, dir, s.range);
        const hit = d < s.range;
        if (hit && rand) d = Math.max(0, d * (1 + 0.01 * rand.gauss()) + s.sigma * rand.gauss());
        out.push({ sensor: k, dir, d, point: add(p, [dir[0] * d, dir[1] * d, dir[2] * d]), hit });
      }
    }
  });
  return out;
}

// MARK: Courses

export type Course = {
  name: string;
  start: V3;
  /** Waypoints in order; the last one is the landing spot. Gates add their centre. */
  waypoints: V3[];
  gates: Gate[];
  obstacles: Obstacle[];
  /** Obstacles that are not on the map the drone gets: only its sensors find them. */
  hidden: number[];
  bounds: { min: V3; max: V3 };
};

/** The obstacle course: a slalom of posts, three gates at different heights, a wall with a window,
 *  a low beam to duck under, then a landing pad. Waypoints run straight through the posts and the
 *  wall, so the drone has to see and avoid them. */
export function obstacleCourse(): Course {
  const gates: Gate[] = [
    { center: [6, 0, 1.5], yaw: 0, size: 1.2, bar: 0.08 },
    { center: [18, 4, 2.4], yaw: 0, size: 1.2, bar: 0.08 },
    { center: [30, 0, 1.2], yaw: 0, size: 1.2, bar: 0.08 },
  ];
  const posts: Post[] = [
    { kind: "post", c: [10, 1.2], r: 0.25, z0: 0, z1: 4, color: "#e8e3d6" },
    { kind: "post", c: [11.8, 1.8], r: 0.25, z0: 0, z1: 4, color: "#e8e3d6" },
    { kind: "post", c: [13.6, 2.3], r: 0.25, z0: 0, z1: 4, color: "#e8e3d6" },
  ];
  // A wall across the path with a 1.4 m window off to one side.
  const wall: Box[] = [
    { kind: "box", min: [23.8, -4, 0], max: [24.2, 1.4, 4], color: "#8b93a1" },
    { kind: "box", min: [23.8, 2.8, 0], max: [24.2, 6, 4], color: "#8b93a1" },
    { kind: "box", min: [23.8, 1.4, 0], max: [24.2, 2.8, 1.1], color: "#8b93a1" },
    { kind: "box", min: [23.8, 1.4, 2.5], max: [24.2, 2.8, 4], color: "#8b93a1" },
  ];
  const beam: Box = { kind: "box", min: [34.8, -3, 1.0], max: [35.2, 3, 1.3], color: "#ffd23f" };
  const obstacles: Obstacle[] = [...gates.flatMap(gateObstacles), ...posts, ...wall, beam];
  const hiddenStart = gates.length * 4;
  return {
    name: "Obstacle course",
    start: [0, 0, 0],
    // Each gate is entered and left along its normal, as racing lines do.
    waypoints: [[0, 0, 1.5], ...through(gates[0]), [15.5, 2.6, 2], ...through(gates[1]), [27, -1.5, 1.8], ...through(gates[2]), [38, 0, 1.5], [40, 0, 0]],
    gates,
    obstacles,
    hidden: obstacles.map((_, i) => i).filter((i) => i >= hiddenStart),
    bounds: { min: [-3, -6, 0], max: [43, 8, 6] },
  };
}

/** Waypoints just before, at and just after a gate's centre, along its normal. */
export function through(g: Gate): V3[] {
  const n: V3 = [Math.cos(g.yaw), Math.sin(g.yaw), 0];
  return [add(g.center, [-n[0] * 1.5, -n[1] * 1.5, 0]), g.center, add(g.center, [n[0] * 0.8, n[1] * 0.8, 0])];
}

/** Random training layouts: a few posts and walls on the way between random waypoints. */
export function randomCourse(rand: Rng): Course {
  const waypoints: V3[] = [[0, 0, 1.5]];
  let at: V3 = [0, 0, 1.5];
  for (let i = 0; i < 3; i++) {
    at = [at[0] + rand.range(5, 8), rand.range(-2.5, 2.5), rand.range(1, 2.5)];
    waypoints.push(at);
  }
  const obstacles: Obstacle[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    const a = waypoints[i - 1], b = waypoints[i];
    const u = rand.range(0.35, 0.65);
    const mid = add(a, [(b[0] - a[0]) * u, (b[1] - a[1]) * u, (b[2] - a[2]) * u]);
    if (rand.next() < 0.6) obstacles.push({ kind: "post", c: [mid[0], mid[1] + rand.range(-0.3, 0.3)], r: rand.range(0.15, 0.4), z0: 0, z1: 4 });
    else {
      const gap = rand.range(-1.5, 1.5);
      obstacles.push({ kind: "box", min: [mid[0] - 0.2, mid[1] - 4, 0], max: [mid[0] + 0.2, mid[1] + gap - 0.8, 4] });
      obstacles.push({ kind: "box", min: [mid[0] - 0.2, mid[1] + gap + 0.8, 0], max: [mid[0] + 0.2, mid[1] + 4, 4] });
    }
  }
  const last = waypoints[waypoints.length - 1];
  return {
    name: "Random", start: [0, 0, 0], waypoints, gates: [], obstacles, hidden: obstacles.map((_, i) => i),
    bounds: { min: [-3, -6, 0], max: [last[0] + 3, 6, 5] },
  };
}

export const segmentLength = (a: V3, b: V3) => norm(sub(b, a));
