// The game's rules: the course's gates in order, each entered through its opening, then a landing
// on the pad, against the clock. Times are flight times (simulated seconds).

import type { V3 } from "./math";
import type { Course, Gate } from "./world";

export type RaceState = "countdown" | "flying" | "crashed" | "finished";

/** The gates in order, then the pad. Times are flight times (simulated seconds). */
export class Race {
  state: RaceState = "countdown";
  countdown = 3;
  next = 0;
  splits: number[] = [];
  time = 0;
  private prev: V3 | null = null;
  readonly pad: V3;

  constructor(public course: Course) {
    this.pad = course.waypoints[course.waypoints.length - 1];
  }

  get gates(): Gate[] {
    return this.course.gates;
  }

  /** The next target: a gate's centre, or the pad. */
  get target(): V3 {
    return this.next < this.gates.length ? this.gates[this.next].center : this.pad;
  }

  update(p: V3, v: V3, t: number, crashed: boolean): void {
    if (this.state !== "flying") return;
    this.time = t;
    if (crashed) {
      this.state = "crashed";
      return;
    }
    const prev = this.prev;
    this.prev = [...p] as V3;
    if (!prev) return;
    if (this.next < this.gates.length) {
      const g = this.gates[this.next];
      const n: V3 = [Math.cos(g.yaw), Math.sin(g.yaw), 0], side: V3 = [-n[1], n[0], 0];
      const d0 = dot3(sub3(prev, g.center), n), d1 = dot3(sub3(p, g.center), n);
      if (d0 < 0 && d1 >= 0) {
        // Where the drone crossed the gate's plane: inside the opening?
        const u = d0 / (d0 - d1);
        const at: V3 = [prev[0] + (p[0] - prev[0]) * u, prev[1] + (p[1] - prev[1]) * u, prev[2] + (p[2] - prev[2]) * u];
        const rel = sub3(at, g.center);
        if (Math.abs(dot3(rel, side)) < g.size / 2 && Math.abs(rel[2]) < g.size / 2) {
          this.next++;
          this.splits.push(t);
        }
      }
      return;
    }
    const onPad = Math.hypot(p[0] - this.pad[0], p[1] - this.pad[1]) < 0.6 && p[2] < 0.15 && Math.hypot(...v) < 0.5;
    if (onPad) this.state = "finished";
  }
}

const sub3 = (a: V3, b: V3): V3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const dot3 = (a: V3, b: V3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
