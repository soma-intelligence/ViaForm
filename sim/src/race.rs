//! The game's rules: the course's gates in order, each entered through its opening, then a landing
//! on the pad, against the clock. Times are flight times (simulated seconds).
//!
//! Port of `electron/src/shared/sim/race.ts`.

use serde::Serialize;

use crate::math::*;
use crate::world::{Course, Gate};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RaceState {
    Countdown,
    Flying,
    Crashed,
    Finished,
}

/// The gates in order, then the pad. Times are flight times (simulated seconds).
#[derive(Clone, Debug, Serialize)]
pub struct Race {
    pub state: RaceState,
    pub countdown: f64,
    /// Index of the next gate; equal to the number of gates once all are passed.
    pub next: usize,
    pub splits: Vec<f64>,
    pub time: f64,
    prev: Option<V3>,
    pub pad: V3,
    pub course: Course,
}

impl Race {
    pub fn new(course: Course) -> Self {
        let pad = course.waypoints[course.waypoints.len() - 1];
        Race { state: RaceState::Countdown, countdown: 3.0, next: 0, splits: Vec::new(), time: 0.0, prev: None, pad, course }
    }

    pub fn gates(&self) -> &[Gate] {
        &self.course.gates
    }

    /// The next target: a gate's centre, or the pad.
    pub fn target(&self) -> V3 {
        if self.next < self.gates().len() { self.gates()[self.next].center } else { self.pad }
    }

    pub fn update(&mut self, p: V3, v: V3, t: f64, crashed: bool) {
        if self.state != RaceState::Flying {
            return;
        }
        self.time = t;
        if crashed {
            self.state = RaceState::Crashed;
            return;
        }
        let prev = self.prev;
        self.prev = Some(p);
        let Some(prev) = prev else { return };
        if self.next < self.gates().len() {
            let g = &self.course.gates[self.next];
            let n: V3 = [g.yaw.cos(), g.yaw.sin(), 0.0];
            let side: V3 = [-n[1], n[0], 0.0];
            let d0 = dot(sub(prev, g.center), n);
            let d1 = dot(sub(p, g.center), n);
            if d0 < 0.0 && d1 >= 0.0 {
                // Where the drone crossed the gate's plane: inside the opening?
                let u = d0 / (d0 - d1);
                let at: V3 = [prev[0] + (p[0] - prev[0]) * u, prev[1] + (p[1] - prev[1]) * u, prev[2] + (p[2] - prev[2]) * u];
                let rel = sub(at, g.center);
                if dot(rel, side).abs() < g.size / 2.0 && rel[2].abs() < g.size / 2.0 {
                    self.next += 1;
                    self.splits.push(t);
                }
            }
            return;
        }
        let on_pad = hypot3(p[0] - self.pad[0], p[1] - self.pad[1], 0.0) < 0.6 && p[2] < 0.15 && norm(v) < 0.5;
        if on_pad {
            self.state = RaceState::Finished;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::obstacle_course;

    /// Flies straight lines between the points at `speed`, updating the race every `dt`, and
    /// returns the time reached.
    fn fly(race: &mut Race, route: &[V3], speed: f64, dt: f64, mut t: f64) -> f64 {
        for w in route.windows(2) {
            let (a, b) = (w[0], w[1]);
            let l = norm(sub(b, a));
            let steps = (l / (speed * dt)).ceil().max(1.0) as usize;
            let v = scale(sub(b, a), 1.0 / (steps as f64 * dt));
            for s in 1..=steps {
                t += dt;
                let p = add(a, scale(sub(b, a), s as f64 / steps as f64));
                race.update(p, v, t, false);
            }
        }
        t
    }

    #[test]
    fn passes_the_gates_in_order_and_lands_on_the_pad() {
        let mut race = Race::new(obstacle_course());
        // Updates before the start are ignored.
        race.update([6.0, 0.0, 1.5], [0.0; 3], 0.0, false);
        assert_eq!(race.state, RaceState::Countdown);
        race.state = RaceState::Flying;
        let route: Vec<V3> = vec![
            [0.0, 0.0, 1.5], [4.5, 0.0, 1.5], [6.8, 0.0, 1.5], [16.5, 4.0, 2.4], [18.8, 4.0, 2.4],
            [28.5, 0.0, 1.2], [30.8, 0.0, 1.2], [40.0, 0.0, 1.0], [40.0, 0.0, 0.1],
        ];
        let t = fly(&mut race, &route, 3.0, 0.05, 0.0);
        assert_eq!(race.splits.len(), 3);
        assert!(race.splits.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(race.target(), race.pad);
        // Settle on the pad.
        race.update([40.0, 0.0, 0.1], [0.0; 3], t + 0.05, false);
        assert_eq!(race.state, RaceState::Finished);
        assert_eq!(serde_json::to_value(race.state).unwrap(), "finished");
    }

    #[test]
    fn a_gate_passed_outside_its_opening_does_not_count() {
        let mut race = Race::new(obstacle_course());
        race.state = RaceState::Flying;
        // Past the first gate, a metre to its side.
        fly(&mut race, &[[0.0, 1.5, 1.5], [8.0, 1.5, 1.5]], 3.0, 0.05, 0.0);
        assert_eq!(race.next, 0);
        assert_eq!(race.target(), [6.0, 0.0, 1.5]);
        // Backwards through it does not count either.
        fly(&mut race, &[[8.0, 0.0, 1.5], [4.0, 0.0, 1.5]], 3.0, 0.05, 0.0);
        assert_eq!(race.next, 0);
        // Forwards through the opening does.
        fly(&mut race, &[[4.0, 0.0, 1.5], [8.0, 0.0, 1.5]], 3.0, 0.05, 0.0);
        assert_eq!(race.next, 1);
    }

    #[test]
    fn a_crash_ends_the_race() {
        let mut race = Race::new(obstacle_course());
        race.state = RaceState::Flying;
        race.update([0.0, 0.0, 1.5], [0.0; 3], 1.0, false);
        race.update([1.0, 0.0, 1.5], [0.0; 3], 1.5, true);
        assert_eq!(race.state, RaceState::Crashed);
        assert_eq!(race.time, 1.5);
        race.update([2.0, 0.0, 1.5], [0.0; 3], 2.0, false);
        assert_eq!(race.time, 1.5, "no updates once crashed");
    }
}
