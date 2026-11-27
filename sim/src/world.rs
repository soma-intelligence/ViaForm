//! The world the drone flies in: obstacles (boxes, posts, gate frames), the time-of-flight
//! sensors of the companion board as ray fans, collision tests, and the obstacle courses.
//!
//! Port of `electron/src/shared/sim/world.ts`; the same seed draws the same numbers in the same
//! order, so a seeded course or sensor read matches the TypeScript one.

use serde::Serialize;

use crate::math::*;

/// Colour of a box when the TypeScript source gives none (the renderer's default for walls).
pub const BOX_COLOR: &str = "#8b93a1";
/// Colour of a post when the TypeScript source gives none.
pub const POST_COLOR: &str = "#e8e3d6";
/// Colour of the gate frames.
pub const GATE_COLOR: &str = "#ff6a2b";

/// An obstacle: an axis-aligned box, or a vertical post (a cylinder from `z0` to `z1`).
/// Serializes as the TypeScript union does: `{"kind":"box",...}` or `{"kind":"post",...}`.
/// The colour is optional in TypeScript; here it is always present, with the defaults above.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Obstacle {
    Box { min: V3, max: V3, color: String },
    Post { c: [f64; 2], r: f64, z0: f64, z1: f64, color: String },
}

impl Obstacle {
    /// A box in the default wall colour.
    pub fn new_box(min: V3, max: V3) -> Self {
        Obstacle::Box { min, max, color: BOX_COLOR.to_string() }
    }
    /// A post in the default post colour.
    pub fn new_post(c: [f64; 2], r: f64, z0: f64, z1: f64) -> Self {
        Obstacle::Post { c, r, z0, z1, color: POST_COLOR.to_string() }
    }
}

/// A gate: a square frame standing on two legs, facing `yaw`; fly through its centre.
#[derive(Clone, Debug, Serialize)]
pub struct Gate {
    pub center: V3,
    pub yaw: f64,
    pub size: f64,
    pub bar: f64,
}

pub fn gate_obstacles(g: &Gate) -> Vec<Obstacle> {
    // The frame as four bars, axis-aligned when the gate faces x or y (the courses only use those).
    let h = g.size / 2.0;
    let b = g.bar;
    let along_x = g.yaw.cos().abs() > 0.5; // the drone flies along x, so the frame spans y
    let [cx, cy, cz] = g.center;
    let span = |u0: f64, u1: f64, z0: f64, z1: f64| -> Obstacle {
        if along_x {
            Obstacle::Box { min: [cx - b / 2.0, cy + u0, z0], max: [cx + b / 2.0, cy + u1, z1], color: GATE_COLOR.to_string() }
        } else {
            Obstacle::Box { min: [cx + u0, cy - b / 2.0, z0], max: [cx + u1, cy + b / 2.0, z1], color: GATE_COLOR.to_string() }
        }
    };
    vec![
        span(-h - b, -h, 0.0, cz + h + b), // left leg up to the top bar
        span(h, h + b, 0.0, cz + h + b),   // right leg
        span(-h, h, cz + h, cz + h + b),   // top bar
        span(-h, h, cz - h - b, cz - h),   // bottom bar
    ]
}

// MARK: Rays

/// Distance along a unit ray to the obstacle, or infinity.
pub fn ray_hit(o: &Obstacle, from: V3, dir: V3) -> f64 {
    match o {
        Obstacle::Box { min, max, .. } => {
            let (mut t0, mut t1) = (0.0_f64, f64::INFINITY);
            for i in 0..3 {
                if dir[i].abs() < 1e-12 {
                    if from[i] < min[i] || from[i] > max[i] {
                        return f64::INFINITY;
                    }
                    continue;
                }
                let mut a = (min[i] - from[i]) / dir[i];
                let mut b = (max[i] - from[i]) / dir[i];
                if a > b {
                    std::mem::swap(&mut a, &mut b);
                }
                t0 = js_max(t0, a);
                t1 = js_min(t1, b);
                if t0 > t1 {
                    return f64::INFINITY;
                }
            }
            t0
        }
        Obstacle::Post { c: pc, r, z0, z1, .. } => {
            let ox = from[0] - pc[0];
            let oy = from[1] - pc[1];
            let a = dir[0] * dir[0] + dir[1] * dir[1];
            if a < 1e-12 {
                return f64::INFINITY;
            }
            let b = 2.0 * (ox * dir[0] + oy * dir[1]);
            let c = ox * ox + oy * oy - r * r;
            let disc = b * b - 4.0 * a * c;
            if disc < 0.0 {
                return f64::INFINITY;
            }
            let t = (-b - disc.sqrt()) / (2.0 * a);
            if t < 0.0 {
                return if c < 0.0 { 0.0 } else { f64::INFINITY };
            }
            let z = from[2] + t * dir[2];
            if z >= *z0 && z <= *z1 { t } else { f64::INFINITY }
        }
    }
}

/// Ray against the obstacles and the ground plane.
pub fn raycast(obstacles: &[Obstacle], from: V3, dir: V3, max: f64) -> f64 {
    let mut best = if dir[2] < -1e-9 { -from[2] / dir[2] } else { f64::INFINITY };
    for o in obstacles {
        best = js_min(best, ray_hit(o, from, dir));
    }
    js_min(best, max)
}

/// Shortest distance from a point to the obstacle's surface (negative inside).
pub fn distance_to(o: &Obstacle, p: V3) -> f64 {
    match o {
        Obstacle::Box { min, max, .. } => {
            let d: [f64; 3] = std::array::from_fn(|i| js_max(js_max(min[i] - p[i], 0.0), p[i] - max[i]));
            let out = hypot3(d[0], d[1], d[2]);
            if out > 0.0 {
                return out;
            }
            let inner: [f64; 3] = std::array::from_fn(|i| js_min(p[i] - min[i], max[i] - p[i]));
            -js_min(js_min(inner[0], inner[1]), inner[2])
        }
        Obstacle::Post { c, r, z0, z1, .. } => {
            let radial = hypot3(p[0] - c[0], p[1] - c[1], 0.0) - r;
            let vertical = js_max(js_max(z0 - p[2], p[2] - z1), 0.0);
            if radial > 0.0 || vertical > 0.0 {
                hypot3(js_max(radial, 0.0), vertical, 0.0)
            } else {
                js_max(radial, -vertical)
            }
        }
    }
}

/// Distance from p to the nearest obstacle surface (infinity when there are none).
pub fn clearance(obstacles: &[Obstacle], p: V3) -> f64 {
    obstacles.iter().fold(f64::INFINITY, |m, o| js_min(m, distance_to(o, p)))
}

// MARK: Time-of-flight sensors

/// One VL53L1X-class sensor: a direction in body axes and a square field of view split into
/// zones (its programmable region of interest), each read as one ray. Angles in degrees.
#[derive(Clone, Debug, Serialize)]
pub struct TofSpec {
    pub name: String,
    pub yaw: f64,
    pub pitch: f64,
    pub fov: f64,
    pub zones: usize,
    pub range: f64,
    pub sigma: f64,
}

/// Default sensor range (m) of `tof_array` in the TypeScript source.
pub const DEFAULT_TOF_RANGE: f64 = 4.0;

/// The companion board: front, front-left, front-right, left, right and down. VL53L1X long mode
/// reaches about 4 m indoors and much less in sunlight; `range` is set by the scenario
/// (TypeScript default: `DEFAULT_TOF_RANGE`).
pub fn tof_array(range: f64) -> Vec<TofSpec> {
    let s = |name: &str, yaw: f64, pitch: f64| TofSpec { name: name.to_string(), yaw, pitch, fov: 27.0, zones: 4, range, sigma: 0.015 };
    vec![
        s("front", 0.0, 0.0),
        s("front-left", 35.0, 0.0),
        s("front-right", -35.0, 0.0),
        s("left", 90.0, 0.0),
        s("right", -90.0, 0.0),
        s("down", 0.0, -90.0),
    ]
}

/// One zone's reading: the sensor's index, the world direction of its ray, the distance (the
/// sensor's range when nothing is hit), the point it lands on, and whether it hit anything.
#[derive(Clone, Debug, Serialize)]
pub struct TofHit {
    pub sensor: usize,
    pub dir: V3,
    pub d: f64,
    pub point: V3,
    pub hit: bool,
}

/// Reads every zone of every sensor from the drone at p with attitude q. With `rand`, each
/// return gets range noise (two Gaussian draws per hit, in the TypeScript order).
pub fn read_tof(sensors: &[TofSpec], obstacles: &[Obstacle], p: V3, q: Q, mut rand: Option<&mut Rng>) -> Vec<TofHit> {
    let r = q_to_m3(q);
    let mut out = Vec::with_capacity(sensors.iter().map(|s| s.zones * s.zones).sum());
    for (k, s) in sensors.iter().enumerate() {
        let zones = s.zones as f64;
        for i in 0..s.zones {
            for j in 0..s.zones {
                let da = ((i as f64 + 0.5) / zones - 0.5) * s.fov;
                let de = ((j as f64 + 0.5) / zones - 0.5) * s.fov;
                let yaw = ((s.yaw + da) * PI) / 180.0;
                let pitch = ((s.pitch + de) * PI) / 180.0;
                let body: V3 = [pitch.cos() * yaw.cos(), pitch.cos() * yaw.sin(), pitch.sin()];
                let dir = mv(&r, body);
                let mut d = raycast(obstacles, p, dir, s.range);
                let hit = d < s.range;
                if hit && let Some(rand) = rand.as_deref_mut() {
                    // Left to right, as in JavaScript: the scale draw first, then the offset draw.
                    d = js_max(0.0, d * (1.0 + 0.01 * rand.gauss()) + s.sigma * rand.gauss());
                }
                out.push(TofHit { sensor: k, dir, d, point: add(p, [dir[0] * d, dir[1] * d, dir[2] * d]), hit });
            }
        }
    }
    out
}

// MARK: Courses

/// The region a course is flown in (and mapped).
#[derive(Clone, Debug, Serialize)]
pub struct Bounds {
    pub min: V3,
    pub max: V3,
}

#[derive(Clone, Debug, Serialize)]
pub struct Course {
    pub name: String,
    pub start: V3,
    /// Waypoints in order; the last one is the landing spot. Gates add their centre.
    pub waypoints: Vec<V3>,
    pub gates: Vec<Gate>,
    pub obstacles: Vec<Obstacle>,
    /// Obstacles that are not on the map the drone gets: only its sensors find them.
    pub hidden: Vec<usize>,
    pub bounds: Bounds,
}

/// The obstacle course: a slalom of posts, three gates at different heights, a wall with a window,
/// a low beam to duck under, then a landing pad. Waypoints run straight through the posts and the
/// wall, so the drone has to see and avoid them.
pub fn obstacle_course() -> Course {
    let gates = vec![
        Gate { center: [6.0, 0.0, 1.5], yaw: 0.0, size: 1.2, bar: 0.08 },
        Gate { center: [18.0, 4.0, 2.4], yaw: 0.0, size: 1.2, bar: 0.08 },
        Gate { center: [30.0, 0.0, 1.2], yaw: 0.0, size: 1.2, bar: 0.08 },
    ];
    let posts = vec![
        Obstacle::Post { c: [10.0, 1.2], r: 0.25, z0: 0.0, z1: 4.0, color: "#e8e3d6".to_string() },
        Obstacle::Post { c: [11.8, 1.8], r: 0.25, z0: 0.0, z1: 4.0, color: "#e8e3d6".to_string() },
        Obstacle::Post { c: [13.6, 2.3], r: 0.25, z0: 0.0, z1: 4.0, color: "#e8e3d6".to_string() },
    ];
    // A wall across the path with a 1.4 m window off to one side.
    let wall = vec![
        Obstacle::Box { min: [23.8, -4.0, 0.0], max: [24.2, 1.4, 4.0], color: "#8b93a1".to_string() },
        Obstacle::Box { min: [23.8, 2.8, 0.0], max: [24.2, 6.0, 4.0], color: "#8b93a1".to_string() },
        Obstacle::Box { min: [23.8, 1.4, 0.0], max: [24.2, 2.8, 1.1], color: "#8b93a1".to_string() },
        Obstacle::Box { min: [23.8, 1.4, 2.5], max: [24.2, 2.8, 4.0], color: "#8b93a1".to_string() },
    ];
    let beam = Obstacle::Box { min: [34.8, -3.0, 1.0], max: [35.2, 3.0, 1.3], color: "#ffd23f".to_string() };
    let mut obstacles: Vec<Obstacle> = gates.iter().flat_map(gate_obstacles).collect();
    obstacles.extend(posts);
    obstacles.extend(wall);
    obstacles.push(beam);
    let hidden_start = gates.len() * 4;
    // Each gate is entered and left along its normal, as racing lines do.
    let mut waypoints: Vec<V3> = vec![[0.0, 0.0, 1.5]];
    waypoints.extend(through(&gates[0]));
    waypoints.push([15.5, 2.6, 2.0]);
    waypoints.extend(through(&gates[1]));
    waypoints.push([27.0, -1.5, 1.8]);
    waypoints.extend(through(&gates[2]));
    waypoints.extend([[38.0, 0.0, 1.5], [40.0, 0.0, 0.0]]);
    let hidden = (0..obstacles.len()).filter(|&i| i >= hidden_start).collect();
    Course {
        name: "Obstacle course".to_string(),
        start: [0.0, 0.0, 0.0],
        waypoints,
        gates,
        obstacles,
        hidden,
        bounds: Bounds { min: [-3.0, -6.0, 0.0], max: [43.0, 8.0, 6.0] },
    }
}

/// Waypoints just before, at and just after a gate's centre, along its normal.
pub fn through(g: &Gate) -> [V3; 3] {
    let n: V3 = [g.yaw.cos(), g.yaw.sin(), 0.0];
    [add(g.center, [-n[0] * 1.5, -n[1] * 1.5, 0.0]), g.center, add(g.center, [n[0] * 0.8, n[1] * 0.8, 0.0])]
}

/// Random training layouts: a few posts and walls on the way between random waypoints.
pub fn random_course(rand: &mut Rng) -> Course {
    let mut waypoints: Vec<V3> = vec![[0.0, 0.0, 1.5]];
    let mut at: V3 = [0.0, 0.0, 1.5];
    for _ in 0..3 {
        // Array elements are evaluated left to right in both languages: x, then y, then z.
        at = [at[0] + rand.range(5.0, 8.0), rand.range(-2.5, 2.5), rand.range(1.0, 2.5)];
        waypoints.push(at);
    }
    let mut obstacles: Vec<Obstacle> = Vec::new();
    for i in 1..waypoints.len() {
        let (a, b) = (waypoints[i - 1], waypoints[i]);
        let u = rand.range(0.35, 0.65);
        let mid = add(a, [(b[0] - a[0]) * u, (b[1] - a[1]) * u, (b[2] - a[2]) * u]);
        if rand.next() < 0.6 {
            // `c` is drawn before `r`, as in the TypeScript object literal.
            let c = [mid[0], mid[1] + rand.range(-0.3, 0.3)];
            let r = rand.range(0.15, 0.4);
            obstacles.push(Obstacle::new_post(c, r, 0.0, 4.0));
        } else {
            let gap = rand.range(-1.5, 1.5);
            obstacles.push(Obstacle::new_box([mid[0] - 0.2, mid[1] - 4.0, 0.0], [mid[0] + 0.2, mid[1] + gap - 0.8, 4.0]));
            obstacles.push(Obstacle::new_box([mid[0] - 0.2, mid[1] + gap + 0.8, 0.0], [mid[0] + 0.2, mid[1] + 4.0, 4.0]));
        }
    }
    let last = waypoints[waypoints.len() - 1];
    let hidden = (0..obstacles.len()).collect();
    Course {
        name: "Random".to_string(),
        start: [0.0, 0.0, 0.0],
        waypoints,
        gates: vec![],
        obstacles,
        hidden,
        bounds: Bounds { min: [-3.0, -6.0, 0.0], max: [last[0] + 3.0, 6.0, 5.0] },
    }
}

pub fn segment_length(a: V3, b: V3) -> f64 {
    norm(sub(b, a))
}

/// `Math.min(a, b)`: NaN if either is NaN (Rust's `f64::min` would return the other one).
#[inline]
pub(crate) fn js_min(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() { f64::NAN } else { a.min(b) }
}
/// `Math.max(a, b)`: NaN if either is NaN.
#[inline]
pub(crate) fn js_max(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() { f64::NAN } else { a.max(b) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn obstacle_course_serializes_with_the_typescript_shapes() {
        let c = obstacle_course();
        let v = serde_json::to_value(&c).unwrap();
        let obs = v["obstacles"].as_array().unwrap();
        assert_eq!(obs.len(), 12 + 3 + 4 + 1);
        // A gate bar.
        let gate = &obs[0];
        assert_eq!(gate["kind"], "box");
        assert_eq!(gate["color"], "#ff6a2b");
        assert_eq!(gate["min"].as_array().unwrap().len(), 3);
        assert_eq!(gate["max"].as_array().unwrap().len(), 3);
        assert_eq!(gate.as_object().unwrap().len(), 4);
        // A post.
        // Serialized straight from the enum (a `Value` would sort the keys).
        assert_eq!(
            serde_json::to_string(&c.obstacles[12]).unwrap(),
            r##"{"kind":"post","c":[10.0,1.2],"r":0.25,"z0":0.0,"z1":4.0,"color":"#e8e3d6"}"##
        );
        // A wall panel.
        assert_eq!(
            serde_json::to_string(&c.obstacles[15]).unwrap(),
            r##"{"kind":"box","min":[23.8,-4.0,0.0],"max":[24.2,1.4,4.0],"color":"#8b93a1"}"##
        );
        assert_eq!(v["hidden"].as_array().unwrap().len(), 8);
        assert_eq!(v["hidden"][0], 12);
        assert_eq!(v["bounds"]["max"][0], 43.0);
        assert_eq!(v["waypoints"].as_array().unwrap().len(), 14);
        assert_eq!(v["gates"][1]["center"][1], 4.0);
    }

    #[test]
    fn random_course_gets_default_colours() {
        let mut r = Rng::new(7.0);
        let c = random_course(&mut r);
        assert_eq!(c.waypoints.len(), 4);
        assert_eq!(c.hidden.len(), c.obstacles.len());
        for o in serde_json::to_value(&c).unwrap()["obstacles"].as_array().unwrap() {
            let want = if o["kind"] == "box" { BOX_COLOR } else { POST_COLOR };
            assert_eq!(o["color"], want);
        }
    }

    #[test]
    fn rays_hit_boxes_posts_and_the_ground() {
        let b = Obstacle::new_box([2.0, -1.0, 0.0], [3.0, 1.0, 2.0]);
        assert!((ray_hit(&b, [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]) - 2.0).abs() < 1e-12);
        let p = Obstacle::new_post([5.0, 0.0], 0.5, 0.0, 2.0);
        assert!((ray_hit(&p, [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]) - 4.5).abs() < 1e-12);
        assert_eq!(ray_hit(&p, [0.0, 0.0, 3.0], [1.0, 0.0, 0.0]), f64::INFINITY);
        let down = raycast(&[], [0.0, 0.0, 1.5], [0.0, 0.0, -1.0], 4.0);
        assert!((down - 1.5).abs() < 1e-12);
        assert!((distance_to(&b, [2.5, 0.0, 1.0]) + 0.5).abs() < 1e-12);
        assert!((clearance(&[b, p], [0.0, 0.0, 1.0]) - 2.0).abs() < 1e-12);
    }

    #[test]
    fn tof_reads_the_wall_ahead_and_the_ground_below() {
        let obstacles = vec![Obstacle::new_box([3.0, -2.0, 0.0], [3.2, 2.0, 3.0])];
        let hits = read_tof(&tof_array(DEFAULT_TOF_RANGE), &obstacles, [0.0, 0.0, 1.0], [1.0, 0.0, 0.0, 0.0], None);
        assert_eq!(hits.len(), 6 * 16);
        let front: Vec<_> = hits.iter().filter(|h| h.sensor == 0).collect();
        assert!(front.iter().all(|h| h.hit && h.d > 3.0 && h.d < 3.2));
        let down: Vec<_> = hits.iter().filter(|h| h.sensor == 5).collect();
        assert!(down.iter().all(|h| h.hit && h.d > 1.0 && h.d < 1.1));
    }
}
