//! The companion computer's map: a 3D occupancy grid in log-odds, as OctoMap keeps one. Every
//! time-of-flight reading raises the odds of the cell it hit and lowers those of the cells the beam
//! crossed, so a raindrop or a snowflake (one return, then free beams through the same place) fades
//! out while a wall (returning scan after scan) stays. An optimistic A* then plans through it:
//! unknown space counts as free, known obstacles are inflated by the safety margin, and the plan
//! is redone as the map grows.
//!
//! Port of `electron/src/shared/sim/mapping.ts`. The odds are stored as `f32` like the
//! TypeScript `Float32Array` (sums are done in `f64` and rounded on store, as JavaScript does), so
//! the thresholds flip on the same reading.

use std::collections::{HashMap, HashSet};

use serde::Serialize;

use crate::math::*;
use crate::world::{Obstacle, TofHit, distance_to, js_max, js_min};

const HIT: f64 = 0.85;
const MISS: f64 = -0.3;
const MISS_OCCUPIED: f64 = -0.08;
const MIN: f64 = -2.0;
const MAX: f64 = 3.5;
const OCCUPIED: f64 = 1.2;

/// Default cell size (m) of the TypeScript constructor.
pub const DEFAULT_RES: f64 = 0.2;
/// Default inflation (m) of the TypeScript constructor.
pub const DEFAULT_INFLATE: f64 = 0.36;
/// Default expansion budget of `plan` in the TypeScript source.
pub const DEFAULT_MAX_EXPAND: usize = 60000;

/// Integer cell coordinates; may lie outside the grid (check with `inside`).
pub type Cell = [i64; 3];

/// The nearest occupied cell found by `nearest`.
#[derive(Clone, Debug, Serialize)]
pub struct Nearest {
    /// Distance (m) to the cell's surface, or infinity when none is within the radius.
    pub d: f64,
    /// The cell's centre, or the query point when none was found.
    pub at: V3,
}

#[derive(Clone, Debug)]
pub struct OccupancyGrid {
    pub min: V3,
    pub max: V3,
    pub res: f64,
    pub inflate: f64,
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub odds: Vec<f32>,
    /// Per cell: 2 within the airframe's reach of an obstacle (never entered), 1 within the safety
    /// margin (entered only at a high cost, so a drone pushed into it can always get out).
    blocked: Vec<u8>,
    /// Cells of obstacles known in advance: readings never change them.
    fixed: Vec<u8>,
    dirty: bool,
    pub occupied_count: i64,
}

impl OccupancyGrid {
    /// TypeScript defaults: `res = DEFAULT_RES`, `inflate = DEFAULT_INFLATE`.
    pub fn new(min: V3, max: V3, res: f64, inflate: f64) -> Self {
        let nx = ((max[0] - min[0]) / res).ceil() as usize;
        let ny = ((max[1] - min[1]) / res).ceil() as usize;
        let nz = ((max[2] - min[2]) / res).ceil() as usize;
        let n = nx * ny * nz;
        OccupancyGrid {
            min,
            max,
            res,
            inflate,
            nx,
            ny,
            nz,
            odds: vec![0.0; n],
            blocked: vec![0; n],
            fixed: vec![0; n],
            dirty: true,
            occupied_count: 0,
        }
    }

    /// Flat index of a cell; the cell must be inside the grid.
    pub fn index(&self, i: i64, j: i64, k: i64) -> usize {
        ((k * self.ny as i64 + j) * self.nx as i64 + i) as usize
    }
    pub fn cell_of(&self, p: V3) -> Cell {
        // `Math.floor` then a cast; a NaN coordinate becomes 0 here (JavaScript keeps NaN, which
        // `inside` then rejects).
        [
            ((p[0] - self.min[0]) / self.res).floor() as i64,
            ((p[1] - self.min[1]) / self.res).floor() as i64,
            ((p[2] - self.min[2]) / self.res).floor() as i64,
        ]
    }
    pub fn inside(&self, i: i64, j: i64, k: i64) -> bool {
        i >= 0 && j >= 0 && k >= 0 && i < self.nx as i64 && j < self.ny as i64 && k < self.nz as i64
    }
    pub fn centre(&self, i: i64, j: i64, k: i64) -> V3 {
        [
            self.min[0] + (i as f64 + 0.5) * self.res,
            self.min[1] + (j as f64 + 0.5) * self.res,
            self.min[2] + (k as f64 + 0.5) * self.res,
        ]
    }
    pub fn occupied(&self, i: i64, j: i64, k: i64) -> bool {
        self.inside(i, j, k) && self.odds[self.index(i, j, k)] as f64 > OCCUPIED
    }

    /// Integrates one scan from the sensor origin `from`.
    pub fn integrate(&mut self, from: V3, hits: &[TofHit]) {
        for h in hits {
            let end = h.d;
            // Walk the beam in half-cell steps; the ground (z < 5 cm) is not an obstacle to map. The
            // last cell and a half before a return are left alone: a zone's beam grazing a post passes
            // through the cell the post's edge is in, and must not erase it.
            let steps = ((if h.hit { end - self.res * 1.5 } else { end }) / (self.res * 0.5)).floor() as i64;
            let mut last: Option<usize> = None;
            for s in 1..steps {
                let t = s as f64 * self.res * 0.5;
                let [ci, cj, ck] = self.cell_of([from[0] + h.dir[0] * t, from[1] + h.dir[1] * t, from[2] + h.dir[2] * t]);
                if !self.inside(ci, cj, ck) {
                    break;
                }
                let id = self.index(ci, cj, ck);
                if last == Some(id) {
                    continue;
                }
                last = Some(id);
                // A known obstacle fades slowly (a wall seen for a while is not erased by one beam that
                // slips past its edge); a lone raindrop's return, never confirmed, fades fast.
                let by = if self.odds[id] as f64 > OCCUPIED { MISS_OCCUPIED } else { MISS };
                self.bump(id, by);
            }
            if h.hit && h.point[2] > 0.05 {
                let [ci, cj, ck] = self.cell_of(h.point);
                if self.inside(ci, cj, ck) {
                    let id = self.index(ci, cj, ck);
                    self.bump(id, HIT);
                }
            }
        }
    }

    /// Marks an obstacle known in advance (the course plan: gates, not what is hidden) as occupied
    /// for good.
    pub fn know(&mut self, o: &Obstacle) {
        for k in 0..self.nz as i64 {
            for j in 0..self.ny as i64 {
                for i in 0..self.nx as i64 {
                    if distance_to(o, self.centre(i, j, k)) > self.res * 0.5 {
                        continue;
                    }
                    let id = self.index(i, j, k);
                    if (self.odds[id] as f64) <= OCCUPIED {
                        self.occupied_count += 1;
                    }
                    self.odds[id] = MAX as f32;
                    self.fixed[id] = 1;
                    self.dirty = true;
                }
            }
        }
    }

    fn bump(&mut self, id: usize, by: f64) {
        if self.fixed[id] != 0 {
            return;
        }
        let before = self.odds[id] as f64 > OCCUPIED;
        // Computed in f64 and rounded to f32 on store, as a Float32Array assignment does.
        self.odds[id] = js_min(MAX, js_max(MIN, self.odds[id] as f64 + by)) as f32;
        let after = self.odds[id] as f64 > OCCUPIED;
        if before != after {
            self.dirty = true;
            self.occupied_count += if after { 1 } else { -1 };
        }
    }

    /// Occupied cell centres (for drawing).
    pub fn occupied_cells(&self) -> Vec<V3> {
        let mut out = Vec::new();
        for k in 0..self.nz as i64 {
            for j in 0..self.ny as i64 {
                for i in 0..self.nx as i64 {
                    if self.odds[self.index(i, j, k)] as f64 > OCCUPIED {
                        out.push(self.centre(i, j, k));
                    }
                }
            }
        }
        out
    }

    fn rebuild(&mut self) {
        if !self.dirty {
            return;
        }
        self.blocked.fill(0);
        let r = (self.inflate / self.res).ceil() as i64;
        let mut offsets: Vec<(i64, i64, i64, u8)> = Vec::new();
        for a in -r..=r {
            for b in -r..=r {
                for c in -r..=r {
                    let d = hypot3(a as f64, b as f64, c as f64) * self.res;
                    if d <= self.inflate + self.res * 0.5 {
                        offsets.push((a, b, c, if d <= self.res * 1.01 { 2 } else { 1 }));
                    }
                }
            }
        }
        for k in 0..self.nz as i64 {
            for j in 0..self.ny as i64 {
                for i in 0..self.nx as i64 {
                    if (self.odds[self.index(i, j, k)] as f64) <= OCCUPIED {
                        continue;
                    }
                    for &(a, b, c, level) in &offsets {
                        if !self.inside(i + a, j + b, k + c) {
                            continue;
                        }
                        let id = self.index(i + a, j + b, k + c);
                        if self.blocked[id] < level {
                            self.blocked[id] = level;
                        }
                    }
                }
            }
        }
        self.dirty = false;
    }

    /// 0 free, 1 inside the margin, 2 hard (an obstacle, or outside the allowed altitudes).
    /// Takes `&mut self` because the inflated map is rebuilt lazily here when readings changed it.
    pub fn level(&mut self, i: i64, j: i64, k: i64, floor: f64, ceiling: f64) -> u8 {
        if !self.inside(i, j, k) {
            return 2;
        }
        let z = self.min[2] + (k as f64 + 0.5) * self.res;
        if z < floor || z > ceiling {
            return 2;
        }
        self.rebuild();
        self.blocked[self.index(i, j, k)]
    }

    /// Distance (m) from p to the nearest occupied cell within `radius`, and its direction.
    pub fn nearest(&self, p: V3, radius: f64) -> Nearest {
        let c = self.cell_of(p);
        let r = (radius / self.res).ceil() as i64;
        let mut best = f64::INFINITY;
        let mut at: V3 = p;
        for a in -r..=r {
            for b in -r..=r {
                for k in -r..=r {
                    if !self.occupied(c[0] + a, c[1] + b, c[2] + k) {
                        continue;
                    }
                    let q = self.centre(c[0] + a, c[1] + b, c[2] + k);
                    let d = hypot3(q[0] - p[0], q[1] - p[1], q[2] - p[2]) - self.res * 0.5;
                    if d < best {
                        best = d;
                        at = q;
                    }
                }
            }
        }
        Nearest { d: best, at }
    }

    /// A* with the default expansion budget (`DEFAULT_MAX_EXPAND`).
    pub fn plan(&mut self, from: V3, to: V3, floor: f64, ceiling: f64) -> Option<Vec<V3>> {
        self.plan_limited(from, to, floor, ceiling, DEFAULT_MAX_EXPAND)
    }

    /// A* over the 26-connected grid from `from` to `to`, through cells that are not blocked
    /// (unknown counts as free). Returns cell centres, or `None` when no route exists within
    /// `max_expand` expansions.
    pub fn plan_limited(&mut self, from: V3, to: V3, floor: f64, ceiling: f64, max_expand: usize) -> Option<Vec<V3>> {
        let s = self.cell_of(from);
        let g = self.cell_of(to);
        let (nx, ny, nz) = (self.nx as i64, self.ny as i64, self.nz as i64);
        let clamp_cell = |c: Cell| -> Cell { [(nx - 1).min(c[0].max(0)), (ny - 1).min(c[1].max(0)), (nz - 1).min(c[2].max(0))] };
        let [si, sj, sk] = clamp_cell(s);
        let [gi, gj, gk] = clamp_cell(g);
        let start = self.index(si, sj, sk);
        let goal = self.index(gi, gj, gk);
        let mut g_score: HashMap<usize, f64> = HashMap::from([(start, 0.0)]);
        let mut came: HashMap<usize, usize> = HashMap::new();
        let h = |i: i64, j: i64, k: i64| hypot3((i - gi) as f64, (j - gj) as f64, (k - gk) as f64);
        // The same hand-written binary heap as the TypeScript source (not `BinaryHeap`), so equal
        // scores pop in the same order and the same route comes out.
        let mut heap: Vec<(f64, usize)> = vec![(h(si, sj, sk), start)];
        let push = |heap: &mut Vec<(f64, usize)>, f: f64, id: usize| {
            heap.push((f, id));
            let mut x = heap.len() - 1;
            while x > 0 {
                let u = (x - 1) >> 1;
                if heap[u].0 <= heap[x].0 {
                    break;
                }
                heap.swap(u, x);
                x = u;
            }
        };
        let pop = |heap: &mut Vec<(f64, usize)>| -> (f64, usize) {
            let top = heap[0];
            let last = heap.pop().unwrap();
            if !heap.is_empty() {
                heap[0] = last;
                let mut x = 0;
                loop {
                    let l = 2 * x + 1;
                    let r = l + 1;
                    let mut m = x;
                    if l < heap.len() && heap[l].0 < heap[m].0 {
                        m = l;
                    }
                    if r < heap.len() && heap[r].0 < heap[m].0 {
                        m = r;
                    }
                    if m == x {
                        break;
                    }
                    heap.swap(m, x);
                    x = m;
                }
            }
            top
        };
        let mut closed: HashSet<usize> = HashSet::new();
        let mut expanded = 0;
        let (nxu, nyu) = (self.nx, self.ny);
        let split = |c: usize| -> (i64, i64, i64) { ((c % nxu) as i64, ((c / nxu) % nyu) as i64, (c / (nxu * nyu)) as i64) };
        while !heap.is_empty() && expanded < max_expand {
            let (_, id) = pop(&mut heap);
            if !closed.insert(id) {
                continue;
            }
            expanded += 1;
            if id == goal {
                let mut path: Vec<V3> = Vec::new();
                let mut c = Some(id);
                while let Some(cc) = c {
                    let (i, j, k) = split(cc);
                    path.push(self.centre(i, j, k));
                    c = came.get(&cc).copied();
                }
                path.reverse();
                return Some(path);
            }
            let (i, j, k) = split(id);
            let base = g_score[&id];
            for a in -1..=1_i64 {
                for b in -1..=1_i64 {
                    for c in -1..=1_i64 {
                        if a == 0 && b == 0 && c == 0 {
                            continue;
                        }
                        let (ni, nj, nk) = (i + a, j + b, k + c);
                        if !self.inside(ni, nj, nk) {
                            continue;
                        }
                        let nid = self.index(ni, nj, nk);
                        if closed.contains(&nid) {
                            continue;
                        }
                        let lv = if nid == goal { 0 } else { self.level(ni, nj, nk, floor, ceiling) };
                        if lv == 2 && id != start {
                            continue;
                        }
                        // Climbing costs a little more; the margin costs a lot, but can be crossed to get out.
                        let step = ((a * a + b * b + c * c) as f64).sqrt() * (if lv == 1 { 8.0 } else { 1.0 }) + (if c != 0 { 0.3 } else { 0.0 });
                        let tentative = base + step;
                        if tentative < g_score.get(&nid).copied().unwrap_or(f64::INFINITY) {
                            g_score.insert(nid, tentative);
                            came.insert(nid, id);
                            push(&mut heap, tentative + h(ni, nj, nk), nid);
                        }
                    }
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wall_seen_scan_after_scan_is_occupied_a_raindrop_is_not() {
        let mut g = OccupancyGrid::new([-1.0, -1.0, 0.0], [5.0, 1.0, 3.0], 0.2, DEFAULT_INFLATE);
        let from: V3 = [0.0, 0.0, 1.0];
        let wall = TofHit { sensor: 0, dir: [1.0, 0.0, 0.0], d: 3.0, point: [3.0, 0.0, 1.0], hit: true };
        let drop = TofHit { d: 1.5, point: [1.5, 0.0, 1.0], ..wall.clone() };
        g.integrate(from, &[drop]);
        for _ in 0..4 {
            g.integrate(from, std::slice::from_ref(&wall));
        }
        let [i, j, k] = g.cell_of([3.0, 0.0, 1.0]);
        assert!(g.occupied(i, j, k));
        let [i, j, k] = g.cell_of([1.5, 0.0, 1.0]);
        assert!(!g.occupied(i, j, k));
    }

    #[test]
    fn plans_around_a_known_wall() {
        let mut g = OccupancyGrid::new([-1.0, -3.0, 0.0], [7.0, 3.0, 3.0], DEFAULT_RES, DEFAULT_INFLATE);
        g.know(&Obstacle::new_box([2.8, -3.0, 0.0], [3.2, 1.0, 3.0]));
        let path = g.plan([0.0, 0.0, 1.0], [6.0, 0.0, 1.0], 0.3, 2.8).expect("a route round the wall");
        assert!(path.iter().any(|p| p[1] > 1.0), "goes round the open side");
        let [i, j, k] = g.cell_of([3.0, -1.0, 1.0]);
        assert_eq!(g.level(i, j, k, 0.3, 2.8), 2);
        let n = g.nearest([2.0, -1.0, 1.0], 1.2);
        assert!(n.d < 1.0 && n.at[0] > 2.5);
    }
}
