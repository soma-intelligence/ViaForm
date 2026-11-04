// What the companion computer runs: waypoint following with obstacle avoidance from the
// time-of-flight sensors only. Readings build an occupancy map (mapping.ts); an optimistic A*
// plans to the next waypoint through it and is redone five times a second as the map grows; the
// drone flies toward a point a metre down the smoothed path, at a speed that lets it stop before
// what it has seen and within what its sensors can see.

import { add, clamp, dot, norm, scale, sub, unit, type V3 } from "./math";
import { OccupancyGrid } from "./mapping";
import type { TofHit } from "./world";

export type PlannerConfig = {
  cruise: number; // m/s
  safety: number; // m, clearance kept from obstacles (the map's inflation)
  lookahead: number; // m, carrot distance down the path
  brake: number; // m/s², for the stopping-distance speed limit
  acceptRadius: number; // m, waypoint reached
  sensorRange: number; // m, what the sensors see in this weather: beyond it, nothing is known
  latency: number; // s, from a reading to the drone braking
  floor: number; // m, lowest altitude the planner uses (except to land)
  ceiling: number; // m
};

export const DEFAULT_PLANNER: PlannerConfig = { cruise: 3.5, safety: 0.4, lookahead: 1.0, brake: 5, acceptRadius: 0.35, sensorRange: 4, latency: 0.25, floor: 0.35, ceiling: 3.4 };

export type PlanOut = {
  v: V3; // velocity command
  yaw: number; // face the way it flies so the front sensors see ahead
  target: V3;
  index: number;
  done: boolean;
  blocked: boolean;
  path: V3[];
  carrot: V3;
};

export class Planner {
  index = 0;
  yaw = 0;
  path: V3[] = [];
  map: OccupancyGrid;
  private tick = 0;
  private pathFor = -1;

  constructor(public waypoints: V3[], public cfg: PlannerConfig = { ...DEFAULT_PLANNER }, bounds?: { min: V3; max: V3 }) {
    const lo: V3 = bounds?.min ?? [-5, -10, 0], hi: V3 = bounds?.max ?? [50, 10, 6];
    this.map = new OccupancyGrid(lo, hi, 0.2, cfg.safety);
  }

  observe(from: V3, hits: TofHit[]): void {
    this.map.integrate(from, hits);
  }

  /** True when the straight segment stays out of the margin. */
  private clear(a: V3, b: V3, floor: number): boolean {
    const n = Math.ceil(norm(sub(b, a)) / (this.map.res * 0.5));
    for (let s = 0; s <= n; s++) {
      const p = add(a, scale(sub(b, a), s / Math.max(n, 1)));
      if (this.map.level(...this.map.cellOf(p), floor, this.cfg.ceiling) > 0) return false;
    }
    return true;
  }

  /** Length from p along the path (from its second point on). */
  private length(p: V3, path: V3[]): number {
    let l = norm(sub(path[1], p));
    for (let i = 1; i < path.length - 1; i++) l += norm(sub(path[i + 1], path[i]));
    return l;
  }

  /** The current path, from p, still stays out of the margin up to the waypoint. */
  private stillClear(p: V3, floor: number): boolean {
    const end = this.path.findIndex((q) => q === this.waypoints[this.index]);
    const pts = [p, ...this.path.slice(1, end < 0 ? this.path.length : end + 1)];
    for (let i = 0; i < pts.length - 1; i++) if (!this.clear(pts[i], pts[i + 1], floor)) return false;
    return true;
  }

  /** Free distance (m) from p along a unit direction before the safety margin, up to `max`. */
  private freeAlong(p: V3, dir: V3, floor: number, max: number): number {
    const step = this.map.res * 0.5;
    for (let t = step; t < max; t += step) {
      if (this.map.level(...this.map.cellOf(add(p, scale(dir, t))), floor, this.cfg.ceiling) > 0) return t;
    }
    return max;
  }

  /** Drops path cells that a straight line can skip (string pulling). */
  private smooth(path: V3[], floor: number): V3[] {
    if (path.length < 3) return path;
    const out = [path[0]];
    let i = 0;
    while (i < path.length - 1) {
      let j = path.length - 1;
      while (j > i + 1 && !this.clear(path[i], path[j], floor)) j--;
      out.push(path[j]);
      i = j;
    }
    return out;
  }

  /** `trackError`: how far (m/s) the drone has lately been from the velocity it was told to fly;
   *  wind and gusts raise it, and the planner flies slower. */
  plan(p: V3, v: V3, trackError = 0): PlanOut {
    const C = this.cfg;
    const last = this.waypoints.length - 1;
    let target = this.waypoints[this.index];
    while (this.index < last && norm(sub(target, p)) < C.acceptRadius) target = this.waypoints[++this.index];
    const done = this.index === last && norm(sub(target, p)) < C.acceptRadius;
    const result = (cmd: V3, blocked: boolean, carrot: V3): PlanOut => ({ v: cmd, yaw: this.yaw, target, index: this.index, done, blocked, path: this.path, carrot });
    if (done) return result([0, 0, 0], false, target);

    // Landing: the last waypoint is on the ground, below the planner's floor.
    const floor = Math.min(C.floor, target[2] - 0.05);
    const t = this.tick++;
    const nextBlocked = this.path.length > 1 && !this.clear(p, this.path[1], floor);
    if (this.pathFor !== this.index || t % 4 === 0 || nextBlocked) {
      const raw = this.map.plan(p, target, floor, C.ceiling);
      // The leg after this waypoint joins the path, so the carrot and the speed see the turn.
      const next = this.waypoints[this.index + 1];
      const fresh = raw ? [...this.smooth([p, ...raw.slice(1, -1), target], floor), ...(next ? [next] : [])] : [];
      // Hysteresis: two routes of nearly equal length around a new obstacle must not alternate
      // every replan (the drone would dither toward the obstacle between them). Keep the current
      // route while it is still clear and not much longer (and the waypoint is not close: there the
      // path must start from the drone so it does pass the waypoint).
      const keep = this.pathFor === this.index && norm(sub(target, p)) > 2.5 && this.path.length > 1 && fresh.length > 1 && this.stillClear(p, floor) &&
        this.length(p, this.path) < this.length(p, fresh) + 1.5;
      if (!keep) this.path = fresh;
      this.pathFor = this.index;
    }
    if (!this.path.length) {
      // No route known: hold position and turn to look around.
      this.yaw += 0.08;
      return result([0, 0, 0], true, p);
    }

    // Carrot: the point `lookahead` metres down the path from the closest point on it.
    let carrot = this.path[this.path.length - 1], best = Infinity, from = 0, at: V3 = p;
    for (let i = 0; i < this.path.length - 1; i++) {
      const a = this.path[i], ab = sub(this.path[i + 1], a), l = norm(ab);
      const u = l > 1e-9 ? clamp(dot(sub(p, a), ab) / (l * l), 0, 1) : 0;
      const q = add(a, scale(ab, u));
      const d = norm(sub(p, q));
      if (d < best) [best, from, at] = [d, i, q];
    }
    let left = C.lookahead;
    for (let i = from, a = at; i < this.path.length - 1; i++) {
      const b = this.path[i + 1], l = norm(sub(b, a));
      if (l >= left) {
        carrot = add(a, scale(unit(sub(b, a)), left));
        break;
      }
      left -= l;
      a = b;
    }
    const dir = unit(sub(carrot, p));

    // Speed: cruise, slower in rough air; slow for the goal and for turns down the path; slow
    // close to obstacles; never outrun the sensors.
    const near = this.map.nearest(p, 1.2);
    const room = (d: number) => Math.max(0, Math.sqrt(2 * C.brake * Math.max(0, d)) - C.brake * C.latency);
    // Each corner ahead caps the speed: the sharper the turn, the slower through it, and the
    // drone must be able to brake down to that speed by the time it gets there.
    const isLast = this.index === last;
    const stopAt = isLast ? target : null;
    let cap = C.cruise / (1 + 0.5 * trackError);
    let along = norm(sub(this.path[from + 1] ?? carrot, p));
    for (let i = from + 1; i < this.path.length - 1 && along < 8; i++) {
      const cos = dot(unit(sub(this.path[i], this.path[i - 1])), unit(sub(this.path[i + 1], this.path[i])));
      const corner = 0.8 + 2.7 * Math.max(0, cos) ** 2;
      cap = Math.min(cap, Math.sqrt(corner * corner + 2 * C.brake * 0.6 * along));
      along += norm(sub(this.path[i + 1], this.path[i]));
    }
    if (stopAt) cap = Math.min(cap, 0.9 * Math.sqrt(2 * C.brake * norm(sub(stopAt, p))) + 0.15);
    // Whatever the plan says, the drone must be able to stop before the obstacles it is moving
    // toward now (its momentum, not its command, carries it into a wall).
    const vNow = norm(v);
    const ahead = vNow > 0.3 ? this.freeAlong(p, scale(v, 1 / vNow), floor, 4) : 4;
    const momentum = Math.sqrt(2 * C.brake * 0.6 * ahead);
    const speed = Math.max(0.35, Math.min(cap, room(C.sensorRange - C.safety), momentum + 0.3, 0.5 + 2.2 * Math.max(0, near.d - 0.15)));
    let cmd = scale(dir, speed);
    // Inside the margin, also push straight away from the nearest obstacle: tracking error in a
    // gust must not carry it in.
    // The margin grows with the recent tracking error (gusts).
    const keepOff = C.safety + Math.min(0.3, 0.3 * trackError);
    if (near.d < keepOff) {
      const away = unit(sub(p, near.at));
      // Cancel the part of the command toward the obstacle, then push off.
      const into = Math.min(0, dot(cmd, away));
      cmd = add(cmd, scale(away, -into + Math.min(1.8, 5 * (keepOff - near.d))));
    }
    // Turn to face the way it flies (the front sensors look ahead), smoothly, and only when
    // really moving somewhere: near a waypoint the direction swings and the yaw must not chase it.
    const flat = Math.hypot(cmd[0], cmd[1]);
    if (flat > 0.8) {
      const want = Math.atan2(cmd[1], cmd[0]);
      const diff = Math.atan2(Math.sin(want - this.yaw), Math.cos(want - this.yaw));
      this.yaw += clamp(diff, -0.12, 0.12); // ≤ 2.4 rad/s at 20 Hz
    }
    return result(cmd, false, carrot);
  }
}
