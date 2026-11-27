// The companion computer's map: a 3D occupancy grid in log-odds, as OctoMap keeps one. Every
// time-of-flight reading raises the odds of the cell it hit and lowers those of the cells the beam
// crossed, so a raindrop or a snowflake (one return, then free beams through the same place) fades
// out while a wall (returning scan after scan) stays. An optimistic A* then plans through it:
// unknown space counts as free, known obstacles are inflated by the safety margin, and the plan
// is redone as the map grows.

import type { V3 } from "./math";
import { distanceTo, type Obstacle, type TofHit } from "./world";

const HIT = 0.85, MISS = -0.3, MISS_OCCUPIED = -0.08, MIN = -2, MAX = 3.5, OCCUPIED = 1.2;

export class OccupancyGrid {
  readonly nx: number;
  readonly ny: number;
  readonly nz: number;
  readonly odds: Float32Array;
  /** Per cell: 2 within the airframe's reach of an obstacle (never entered), 1 within the safety
   *  margin (entered only at a high cost, so a drone pushed into it can always get out). */
  private blocked: Uint8Array;
  /** Cells of obstacles known in advance: readings never change them. */
  private fixed: Uint8Array;
  private dirty = true;
  occupiedCount = 0;

  constructor(public min: V3, public max: V3, public res = 0.2, public inflate = 0.36) {
    this.nx = Math.ceil((max[0] - min[0]) / res);
    this.ny = Math.ceil((max[1] - min[1]) / res);
    this.nz = Math.ceil((max[2] - min[2]) / res);
    this.odds = new Float32Array(this.nx * this.ny * this.nz);
    this.blocked = new Uint8Array(this.odds.length);
    this.fixed = new Uint8Array(this.odds.length);
  }

  index(i: number, j: number, k: number): number {
    return (k * this.ny + j) * this.nx + i;
  }
  cellOf(p: V3): [number, number, number] {
    return [Math.floor((p[0] - this.min[0]) / this.res), Math.floor((p[1] - this.min[1]) / this.res), Math.floor((p[2] - this.min[2]) / this.res)];
  }
  inside(i: number, j: number, k: number): boolean {
    return i >= 0 && j >= 0 && k >= 0 && i < this.nx && j < this.ny && k < this.nz;
  }
  centre(i: number, j: number, k: number): V3 {
    return [this.min[0] + (i + 0.5) * this.res, this.min[1] + (j + 0.5) * this.res, this.min[2] + (k + 0.5) * this.res];
  }
  occupied(i: number, j: number, k: number): boolean {
    return this.inside(i, j, k) && this.odds[this.index(i, j, k)] > OCCUPIED;
  }

  /** Integrates one scan from the sensor origin `from`. */
  integrate(from: V3, hits: TofHit[]): void {
    for (const h of hits) {
      const end = h.d;
      // Walk the beam in half-cell steps; the ground (z < 5 cm) is not an obstacle to map. The
      // last cell and a half before a return are left alone: a zone's beam grazing a post passes
      // through the cell the post's edge is in, and must not erase it.
      const steps = Math.floor((h.hit ? end - this.res * 1.5 : end) / (this.res * 0.5));
      let last = -1;
      for (let s = 1; s < steps; s++) {
        const t = s * this.res * 0.5;
        const c = this.cellOf([from[0] + h.dir[0] * t, from[1] + h.dir[1] * t, from[2] + h.dir[2] * t]);
        if (!this.inside(...c)) break;
        const id = this.index(...c);
        if (id === last) continue;
        last = id;
        // A known obstacle fades slowly (a wall seen for a while is not erased by one beam that
        // slips past its edge); a lone raindrop's return, never confirmed, fades fast.
        this.bump(id, this.odds[id] > OCCUPIED ? MISS_OCCUPIED : MISS);
      }
      if (h.hit && h.point[2] > 0.05) {
        const c = this.cellOf(h.point);
        if (this.inside(...c)) this.bump(this.index(...c), HIT);
      }
    }
  }

  /** Marks an obstacle known in advance (the course plan: gates, not what is hidden) as occupied
   *  for good. */
  know(o: Obstacle): void {
    for (let k = 0; k < this.nz; k++) for (let j = 0; j < this.ny; j++) for (let i = 0; i < this.nx; i++) {
      if (distanceTo(o, this.centre(i, j, k)) > this.res * 0.5) continue;
      const id = this.index(i, j, k);
      if (this.odds[id] <= OCCUPIED) this.occupiedCount++;
      this.odds[id] = MAX;
      this.fixed[id] = 1;
      this.dirty = true;
    }
  }

  private bump(id: number, by: number) {
    if (this.fixed[id]) return;
    const before = this.odds[id] > OCCUPIED;
    this.odds[id] = Math.min(MAX, Math.max(MIN, this.odds[id] + by));
    const after = this.odds[id] > OCCUPIED;
    if (before !== after) {
      this.dirty = true;
      this.occupiedCount += after ? 1 : -1;
    }
  }

  /** Occupied cell centres (for drawing). */
  occupiedCells(): V3[] {
    const out: V3[] = [];
    for (let k = 0; k < this.nz; k++) for (let j = 0; j < this.ny; j++) for (let i = 0; i < this.nx; i++) {
      if (this.odds[this.index(i, j, k)] > OCCUPIED) out.push(this.centre(i, j, k));
    }
    return out;
  }

  private rebuild(): void {
    if (!this.dirty) return;
    this.blocked.fill(0);
    const r = Math.ceil(this.inflate / this.res);
    const offsets: [number, number, number, number][] = [];
    for (let a = -r; a <= r; a++) for (let b = -r; b <= r; b++) for (let c = -r; c <= r; c++) {
      const d = Math.hypot(a, b, c) * this.res;
      if (d <= this.inflate + this.res * 0.5) offsets.push([a, b, c, d <= this.res * 1.01 ? 2 : 1]);
    }
    for (let k = 0; k < this.nz; k++) for (let j = 0; j < this.ny; j++) for (let i = 0; i < this.nx; i++) {
      if (this.odds[this.index(i, j, k)] <= OCCUPIED) continue;
      for (const [a, b, c, level] of offsets) {
        if (!this.inside(i + a, j + b, k + c)) continue;
        const id = this.index(i + a, j + b, k + c);
        if (this.blocked[id] < level) this.blocked[id] = level;
      }
    }
    this.dirty = false;
  }

  /** 0 free, 1 inside the margin, 2 hard (an obstacle, or outside the allowed altitudes). */
  level(i: number, j: number, k: number, floor: number, ceiling: number): number {
    if (!this.inside(i, j, k)) return 2;
    const z = this.min[2] + (k + 0.5) * this.res;
    if (z < floor || z > ceiling) return 2;
    this.rebuild();
    return this.blocked[this.index(i, j, k)];
  }

  /** Distance (m) from p to the nearest occupied cell within `radius`, and its direction. */
  nearest(p: V3, radius: number): { d: number; at: V3 } {
    const c = this.cellOf(p), r = Math.ceil(radius / this.res);
    let best = Infinity, at: V3 = p;
    for (let a = -r; a <= r; a++) for (let b = -r; b <= r; b++) for (let k = -r; k <= r; k++) {
      if (!this.occupied(c[0] + a, c[1] + b, c[2] + k)) continue;
      const q = this.centre(c[0] + a, c[1] + b, c[2] + k);
      const d = Math.hypot(q[0] - p[0], q[1] - p[1], q[2] - p[2]) - this.res * 0.5;
      if (d < best) [best, at] = [d, q];
    }
    return { d: best, at };
  }

  /**
   * A* over the 26-connected grid from `from` to `to`, through cells that are not blocked
   * (unknown counts as free). Returns cell centres, or null when no route exists within
   * `maxExpand` expansions.
   */
  plan(from: V3, to: V3, floor: number, ceiling: number, maxExpand = 60000): V3[] | null {
    const s = this.cellOf(from), g = this.cellOf(to);
    const clampCell = (c: [number, number, number]): [number, number, number] => [
      Math.min(this.nx - 1, Math.max(0, c[0])), Math.min(this.ny - 1, Math.max(0, c[1])), Math.min(this.nz - 1, Math.max(0, c[2])),
    ];
    const [si, sj, sk] = clampCell(s), [gi, gj, gk] = clampCell(g);
    const start = this.index(si, sj, sk), goal = this.index(gi, gj, gk);
    const gScore = new Map<number, number>([[start, 0]]);
    const came = new Map<number, number>();
    const h = (i: number, j: number, k: number) => Math.hypot(i - gi, j - gj, k - gk);
    const heap: [number, number][] = [[h(si, sj, sk), start]];
    const push = (f: number, id: number) => {
      heap.push([f, id]);
      for (let x = heap.length - 1; x > 0;) { const u = (x - 1) >> 1; if (heap[u][0] <= heap[x][0]) break; [heap[u], heap[x]] = [heap[x], heap[u]]; x = u; }
    };
    const pop = () => {
      const top = heap[0], last = heap.pop()!;
      if (heap.length) {
        heap[0] = last;
        for (let x = 0; ;) {
          const l = 2 * x + 1, r = l + 1; let m = x;
          if (l < heap.length && heap[l][0] < heap[m][0]) m = l;
          if (r < heap.length && heap[r][0] < heap[m][0]) m = r;
          if (m === x) break; [heap[m], heap[x]] = [heap[x], heap[m]]; x = m;
        }
      }
      return top;
    };
    const closed = new Set<number>();
    let expanded = 0;
    while (heap.length && expanded < maxExpand) {
      const [, id] = pop();
      if (closed.has(id)) continue;
      closed.add(id);
      expanded++;
      if (id === goal) {
        const path: V3[] = [];
        for (let c: number | undefined = id; c !== undefined; c = came.get(c)) {
          const i = c % this.nx, j = Math.floor(c / this.nx) % this.ny, k = Math.floor(c / (this.nx * this.ny));
          path.push(this.centre(i, j, k));
        }
        return path.reverse();
      }
      const i = id % this.nx, j = Math.floor(id / this.nx) % this.ny, k = Math.floor(id / (this.nx * this.ny));
      const base = gScore.get(id)!;
      for (let a = -1; a <= 1; a++) for (let b = -1; b <= 1; b++) for (let c = -1; c <= 1; c++) {
        if (!a && !b && !c) continue;
        const ni = i + a, nj = j + b, nk = k + c;
        const nid = this.inside(ni, nj, nk) ? this.index(ni, nj, nk) : -1;
        if (nid < 0 || closed.has(nid)) continue;
        const lv = nid === goal ? 0 : this.level(ni, nj, nk, floor, ceiling);
        if (lv === 2 && id !== start) continue;
        // Climbing costs a little more; the margin costs a lot, but can be crossed to get out.
        const step = Math.sqrt(a * a + b * b + c * c) * (lv === 1 ? 8 : 1) + (c ? 0.3 : 0);
        const tentative = base + step;
        if (tentative < (gScore.get(nid) ?? Infinity)) {
          gScore.set(nid, tentative);
          came.set(nid, id);
          push(tentative + h(ni, nj, nk), nid);
        }
      }
    }
    return null;
  }
}
