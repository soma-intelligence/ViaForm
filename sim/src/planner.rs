//! What the companion computer runs: waypoint following with obstacle avoidance from the
//! time-of-flight sensors only. Readings build an occupancy map (mapping.rs); an optimistic A*
//! plans to the next waypoint through it and is redone five times a second as the map grows; the
//! drone flies toward a point a metre down the smoothed path, at a speed that lets it stop before
//! what it has seen and within what its sensors can see.
//!
//! Port of `electron/src/shared/sim/planner.ts`.

use serde::Serialize;

use crate::mapping::OccupancyGrid;
use crate::math::*;
use crate::world::{Bounds, TofHit, js_max, js_min};

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlannerConfig {
    /// m/s
    pub cruise: f64,
    /// m, clearance kept from obstacles (the map's inflation)
    pub safety: f64,
    /// m, carrot distance down the path
    pub lookahead: f64,
    /// m/s², for the stopping-distance speed limit
    pub brake: f64,
    /// m, waypoint reached
    pub accept_radius: f64,
    /// m, what the sensors see in this weather: beyond it, nothing is known
    pub sensor_range: f64,
    /// s, from a reading to the drone braking
    pub latency: f64,
    /// m, lowest altitude the planner uses (except to land)
    pub floor: f64,
    /// m
    pub ceiling: f64,
}

pub const DEFAULT_PLANNER: PlannerConfig = PlannerConfig {
    cruise: 3.5,
    safety: 0.4,
    lookahead: 1.0,
    brake: 5.0,
    accept_radius: 0.35,
    sensor_range: 4.0,
    latency: 0.25,
    floor: 0.35,
    ceiling: 3.4,
};

impl Default for PlannerConfig {
    fn default() -> Self {
        DEFAULT_PLANNER
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct PlanOut {
    /// velocity command
    pub v: V3,
    /// face the way it flies so the front sensors see ahead
    pub yaw: f64,
    pub target: V3,
    pub index: usize,
    pub done: bool,
    pub blocked: bool,
    pub path: Vec<V3>,
    pub carrot: V3,
}

#[derive(Clone, Debug)]
pub struct Planner {
    pub index: usize,
    pub yaw: f64,
    pub path: Vec<V3>,
    pub map: OccupancyGrid,
    pub waypoints: Vec<V3>,
    pub cfg: PlannerConfig,
    tick: u64,
    /// The waypoint index the current path was planned for (`-1` in TypeScript: `None`).
    path_for: Option<usize>,
    /// For each point of `path`, the index of the waypoint it is, if it is one. The TypeScript
    /// finds the current waypoint in the path by reference identity
    /// (`this.path.findIndex((q) => q === this.waypoints[this.index])`): the path holds the very
    /// waypoint arrays it was built from (the target, then the next waypoint), while the A* cells
    /// and the drone's position are fresh arrays. Value equality would be wrong (a cell centre can
    /// coincide with a waypoint), so the identity is kept here explicitly instead.
    path_ids: Vec<Option<usize>>,
}

impl Planner {
    /// TypeScript defaults: `cfg = DEFAULT_PLANNER`, bounds `[-5, -10, 0]` to `[50, 10, 6]`.
    pub fn new(waypoints: Vec<V3>, cfg: PlannerConfig, bounds: Option<&Bounds>) -> Self {
        let lo: V3 = bounds.map(|b| b.min).unwrap_or([-5.0, -10.0, 0.0]);
        let hi: V3 = bounds.map(|b| b.max).unwrap_or([50.0, 10.0, 6.0]);
        Planner {
            index: 0,
            yaw: 0.0,
            path: Vec::new(),
            map: OccupancyGrid::new(lo, hi, 0.2, cfg.safety),
            waypoints,
            cfg,
            tick: 0,
            path_for: None,
            path_ids: Vec::new(),
        }
    }

    pub fn observe(&mut self, from: V3, hits: &[TofHit]) {
        self.map.integrate(from, hits);
    }

    /// True when the straight segment stays out of the margin.
    fn clear(&mut self, a: V3, b: V3, floor: f64) -> bool {
        let n = (norm(sub(b, a)) / (self.map.res * 0.5)).ceil();
        let mut s = 0.0;
        while s <= n {
            let p = add(a, scale(sub(b, a), s / js_max(n, 1.0)));
            let [i, j, k] = self.map.cell_of(p);
            if self.map.level(i, j, k, floor, self.cfg.ceiling) > 0 {
                return false;
            }
            s += 1.0;
        }
        true
    }

    /// Length from p along the path (from its second point on).
    fn length(&self, p: V3, path: &[V3]) -> f64 {
        let mut l = norm(sub(path[1], p));
        for i in 1..path.len() - 1 {
            l += norm(sub(path[i + 1], path[i]));
        }
        l
    }

    /// The current path, from p, still stays out of the margin up to the waypoint.
    fn still_clear(&mut self, p: V3, floor: f64) -> bool {
        // The position of the current waypoint in the path, by identity (see `path_ids`).
        let end = self.path_ids.iter().position(|&w| w == Some(self.index));
        let stop = match end {
            None => self.path.len(),
            Some(e) => e + 1,
        };
        let mut pts = vec![p];
        pts.extend_from_slice(&self.path[1.min(stop)..stop]);
        for i in 0..pts.len().saturating_sub(1) {
            if !self.clear(pts[i], pts[i + 1], floor) {
                return false;
            }
        }
        true
    }

    /// Free distance (m) from p along a unit direction before the safety margin, up to `max`.
    fn free_along(&mut self, p: V3, dir: V3, floor: f64, max: f64) -> f64 {
        let step = self.map.res * 0.5;
        // Accumulated like the JavaScript loop (`t += step`), so the same samples are taken.
        let mut t = step;
        while t < max {
            let [i, j, k] = self.map.cell_of(add(p, scale(dir, t)));
            if self.map.level(i, j, k, floor, self.cfg.ceiling) > 0 {
                return t;
            }
            t += step;
        }
        max
    }

    /// Drops path cells that a straight line can skip (string pulling).
    fn smooth(&mut self, path: Vec<V3>, floor: f64) -> Vec<V3> {
        if path.len() < 3 {
            return path;
        }
        let mut out = vec![path[0]];
        let mut i = 0;
        while i < path.len() - 1 {
            let mut j = path.len() - 1;
            while j > i + 1 && !self.clear(path[i], path[j], floor) {
                j -= 1;
            }
            out.push(path[j]);
            i = j;
        }
        out
    }

    fn result(&self, cmd: V3, blocked: bool, carrot: V3, target: V3, done: bool) -> PlanOut {
        PlanOut { v: cmd, yaw: self.yaw, target, index: self.index, done, blocked, path: self.path.clone(), carrot }
    }

    /// `track_error`: how far (m/s) the drone has lately been from the velocity it was told to fly;
    /// wind and gusts raise it, and the planner flies slower. (TypeScript default: 0.)
    pub fn plan(&mut self, p: V3, v: V3, track_error: f64) -> PlanOut {
        let c = self.cfg;
        let last = self.waypoints.len() - 1;
        let mut target = self.waypoints[self.index];
        while self.index < last && norm(sub(target, p)) < c.accept_radius {
            self.index += 1;
            target = self.waypoints[self.index];
        }
        let done = self.index == last && norm(sub(target, p)) < c.accept_radius;
        if done {
            return self.result([0.0, 0.0, 0.0], false, target, target, done);
        }

        // Landing: the last waypoint is on the ground, below the planner's floor.
        let floor = js_min(c.floor, target[2] - 0.05);
        let t = self.tick;
        self.tick += 1;
        let next_blocked = self.path.len() > 1 && {
            let p1 = self.path[1];
            !self.clear(p, p1, floor)
        };
        if self.path_for != Some(self.index) || t.is_multiple_of(4) || next_blocked {
            let raw = self.map.plan(p, target, floor, c.ceiling);
            // The leg after this waypoint joins the path, so the carrot and the speed see the turn.
            let next = self.waypoints.get(self.index + 1).copied();
            let (fresh, fresh_ids) = match raw {
                Some(raw) => {
                    let mut input = vec![p];
                    // `raw.slice(1, -1)`: empty when the route is a single cell.
                    if raw.len() > 2 {
                        input.extend_from_slice(&raw[1..raw.len() - 1]);
                    }
                    input.push(target);
                    let mut fresh = self.smooth(input, floor);
                    // Smoothing always keeps the last point, the target waypoint itself; the
                    // other points are the drone's position and A* cells.
                    let mut ids = vec![None; fresh.len()];
                    *ids.last_mut().unwrap() = Some(self.index);
                    if let Some(n) = next {
                        fresh.push(n);
                        ids.push(Some(self.index + 1));
                    }
                    (fresh, ids)
                }
                None => (Vec::new(), Vec::new()),
            };
            // Hysteresis: two routes of nearly equal length around a new obstacle must not alternate
            // every replan (the drone would dither toward the obstacle between them). Keep the current
            // route while it is still clear and not much longer (and the waypoint is not close: there the
            // path must start from the drone so it does pass the waypoint).
            let keep = self.path_for == Some(self.index)
                && norm(sub(target, p)) > 2.5
                && self.path.len() > 1
                && fresh.len() > 1
                && self.still_clear(p, floor)
                && self.length(p, &self.path) < self.length(p, &fresh) + 1.5;
            if !keep {
                self.path = fresh;
                self.path_ids = fresh_ids;
            }
            self.path_for = Some(self.index);
        }
        if self.path.is_empty() {
            // No route known: hold position and turn to look around.
            self.yaw += 0.08;
            return self.result([0.0, 0.0, 0.0], true, p, target, done);
        }

        // Carrot: the point `lookahead` metres down the path from the closest point on it.
        let path = &self.path;
        let mut carrot = path[path.len() - 1];
        let mut best = f64::INFINITY;
        let mut from = 0;
        let mut at: V3 = p;
        for i in 0..path.len() - 1 {
            let a = path[i];
            let ab = sub(path[i + 1], a);
            let l = norm(ab);
            let u = if l > 1e-9 { clamp(dot(sub(p, a), ab) / (l * l), 0.0, 1.0) } else { 0.0 };
            let q = add(a, scale(ab, u));
            let d = norm(sub(p, q));
            if d < best {
                best = d;
                from = i;
                at = q;
            }
        }
        let mut left = c.lookahead;
        {
            let mut a = at;
            for i in from..path.len() - 1 {
                let b = path[i + 1];
                let l = norm(sub(b, a));
                if l >= left {
                    carrot = add(a, scale(unit(sub(b, a)), left));
                    break;
                }
                left -= l;
                a = b;
            }
        }
        let dir = unit(sub(carrot, p));

        // Speed: cruise, slower in rough air; slow for the goal and for turns down the path; slow
        // close to obstacles; never outrun the sensors.
        let near = self.map.nearest(p, 1.2);
        let room = |d: f64| js_max(0.0, (2.0 * c.brake * js_max(0.0, d)).sqrt() - c.brake * c.latency);
        // Each corner ahead caps the speed: the sharper the turn, the slower through it, and the
        // drone must be able to brake down to that speed by the time it gets there.
        let is_last = self.index == last;
        let stop_at = if is_last { Some(target) } else { None };
        let mut cap = c.cruise / (1.0 + 0.5 * track_error);
        let mut along = norm(sub(path.get(from + 1).copied().unwrap_or(carrot), p));
        let mut i = from + 1;
        while i < path.len() - 1 && along < 8.0 {
            let cos = dot(unit(sub(path[i], path[i - 1])), unit(sub(path[i + 1], path[i])));
            let corner = 0.8 + 2.7 * js_max(0.0, cos).powi(2);
            cap = js_min(cap, (corner * corner + 2.0 * c.brake * 0.6 * along).sqrt());
            along += norm(sub(path[i + 1], path[i]));
            i += 1;
        }
        if let Some(stop_at) = stop_at {
            cap = js_min(cap, 0.9 * (2.0 * c.brake * norm(sub(stop_at, p))).sqrt() + 0.15);
        }
        // Whatever the plan says, the drone must be able to stop before the obstacles it is moving
        // toward now (its momentum, not its command, carries it into a wall).
        let v_now = norm(v);
        let ahead = if v_now > 0.3 { self.free_along(p, scale(v, 1.0 / v_now), floor, 4.0) } else { 4.0 };
        let momentum = (2.0 * c.brake * 0.6 * ahead).sqrt();
        let speed = js_max(
            0.35,
            js_min(js_min(js_min(cap, room(c.sensor_range - c.safety)), momentum + 0.3), 0.5 + 2.2 * js_max(0.0, near.d - 0.15)),
        );
        let mut cmd = scale(dir, speed);
        // Inside the margin, also push straight away from the nearest obstacle: tracking error in a
        // gust must not carry it in.
        // The margin grows with the recent tracking error (gusts).
        let keep_off = c.safety + js_min(0.3, 0.3 * track_error);
        if near.d < keep_off {
            let away = unit(sub(p, near.at));
            // Cancel the part of the command toward the obstacle, then push off.
            let into = js_min(0.0, dot(cmd, away));
            cmd = add(cmd, scale(away, -into + js_min(1.8, 5.0 * (keep_off - near.d))));
        }
        // Turn to face the way it flies (the front sensors look ahead), smoothly, and only when
        // really moving somewhere: near a waypoint the direction swings and the yaw must not chase it.
        let flat = hypot3(cmd[0], cmd[1], 0.0);
        if flat > 0.8 {
            let want = cmd[1].atan2(cmd[0]);
            let diff = (want - self.yaw).sin().atan2((want - self.yaw).cos());
            self.yaw += clamp(diff, -0.12, 0.12); // at most 2.4 rad/s at 20 Hz
        }
        self.result(cmd, false, carrot, target, done)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::{clearance, obstacle_course, read_tof, tof_array};

    #[test]
    fn config_serializes_in_camel_case() {
        let s = serde_json::to_string(&DEFAULT_PLANNER).unwrap();
        assert!(s.contains("\"acceptRadius\":0.35") && s.contains("\"sensorRange\":4.0"), "{s}");
    }

    #[test]
    fn a_point_mass_slaloms_through_the_gates_and_the_window_without_touching_anything() {
        // A kinematic drone that flies the commanded velocity with a first-order lag, sensing with
        // the companion board's time-of-flight array: the planner must see the hidden posts and the
        // wall and get through the window. The TypeScript planner, driven by this same harness,
        // reaches waypoint 8 (just past the wall) after 186 steps with at least 0.47 m clearance,
        // and the two runs match to 1e-14 m over these 30 s.
        let course = obstacle_course();
        let mut planner = Planner::new(course.waypoints.clone(), DEFAULT_PLANNER, Some(&course.bounds));
        for (i, o) in course.obstacles.iter().enumerate() {
            if !course.hidden.contains(&i) {
                planner.map.know(o);
            }
        }
        let sensors = tof_array(4.0);
        let mut rand = Rng::new(5.0);
        let dt = 0.05;
        let mut p: V3 = course.waypoints[0];
        let mut v: V3 = [0.0; 3];
        let mut min_clear = f64::INFINITY;
        let mut reached_at = None;
        for k in 0..(30.0 / dt) as usize {
            let q = q_from_euler(0.0, 0.0, planner.yaw);
            let hits = read_tof(&sensors, &course.obstacles, p, q, Some(&mut rand));
            planner.observe(p, &hits);
            let out = planner.plan(p, v, 0.0);
            if planner.index >= 8 && reached_at.is_none() {
                reached_at = Some(k);
            }
            v = add(v, scale(sub(out.v, v), 0.4));
            p = add(p, scale(v, dt));
            min_clear = min_clear.min(clearance(&course.obstacles, p));
        }
        assert_eq!(reached_at, Some(186), "past the wall on the same step as TypeScript");
        assert!(min_clear > 0.4, "closest approach {min_clear}");
    }
}
