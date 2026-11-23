//! A 3-inch quadcopter frame grown by the 3D generative engine around the parts sourced in
//! docs/components/drone.json (T-Motor F1404 4600KV, Gemfan 3016 props, SpeedyBee F405 Mini
//! stack, GNB 4S 650 mAh, Rush Tank Mini, Caddx Ant, Foxeer Lollipop, RP1 V2, XIAO ESP32S3 and
//! six Pololu VL53L1X boards), as strong as it can be for its weight.
//!
//! - Bottom plate and arms, one carbon plate (constant 4 mm section: cut from sheet, as
//!   docs/generative/drone-3in.md section 5.1 asks), 130 mm motor to motor. Least mass under
//!   the stress limit (450 MPa over 1.5 on rare events, frequent ones entered at 4/3), a 3 mm
//!   displacement limit (the post hit's peak in time included), a 350 Hz first-mode floor, and the spec's load table (section 4): punch
//!   12 N and 160 N mm per motor, corner drop 200 N, radial post hit 550 N with its bell lever,
//!   sideways post hit 130 N, belly drop at 300 g; mirrored onto all four arms. The drone is
//!   free in the air: every case is balanced by the inertia of the parts it moves, in
//!   translation and in rotation (motors on the pads, the stack on its bolts, the cage, battery
//!   and electronics on the standoffs, the plate's own mass), and held only at the hub's centre,
//!   which then takes next to nothing. The motors and props weigh on the pads in the modes. The
//!   radial hit is also integrated in time (3.33 ms pulse). Holes, cut exact: the motors' 9 x 9 M2 pattern and shaft, the 20 x 20 stack
//!   bolts (M2 x 25), four M2 x 20 standoffs; the downward ToF's window.
//! - Cage, SLS-printed in carbon-filled PA12, on the four standoffs: a closed tub (walls 1.0 mm,
//!   floor 0.5 mm on the plate, the tray as its roof) round the stack, VTX, receiver, XIAO,
//!   capacitor, XT30 and camera, 0.5 mm clear of each, cut only by the props' rounded 3 mm
//!   envelopes, the lens's view, a 3.2 mm antenna hole and a 3.0 mm lead slot; the engine grows
//!   the stiffest ribs from it to the feet. It keeps out the stack, the VTX
//!   on the stack, the camera and its view, the antenna's way out, the receiver, the XIAO, the
//!   six ToF boards and their windows, and the props' disks grown by the 3 mm clearance the spec
//!   asks; carries the battery and its strap on top; screw heads at the four feet have a
//!   counterbore and a driver's column. Cases from the spec's table: inverted 3 m drop (322.9 N
//!   on the roof at 300 g), battery thrown forward (100 N at 288 g), nose hit 310 N on the hood,
//!   side swipe 140 N on a 10 mm patch with the battery's 57.4 N, rear swipe 140 N.
//!
//! `cargo run --release --example drone` writes docs/generative/drone (parts, assembly.json)
//! and docs/generative/drone-frame.json (mass and inertia for the flight simulation).

mod common;

use common::*;
use serde_json::json;
use viaform_generative::Material;
use viaform_generative::solid::{self, Impact, Load, LoadCase, Manufacturing, Objective, Region, Study, Support};

/// Motor centre at (±ARM, ±ARM): 130 mm diagonal (the frame line FR1 asks ~130 mm).
const ARM: f64 = 45.96;
/// 4 mm carbon sheet (spec 5.1); the voxel is set so the plate is 7 voxels exactly.
const PLATE: f64 = 4.0;
/// The props' disk (76.49 mm, Gemfan 3016) and the 3.0 mm prop-to-frame clearance the spec asks
/// (section 0); the disk sweeps z PROP_DISC_Z (motor 16.6 mm on the plate, prop 5.5 mm), and its
/// clearance envelope is the disk grown by 3.0 mm all round (rounded at its rim, spec 10.11).
const PROP_DISK_R: f64 = 76.49 / 2.0;
const PROP_CLEAR: f64 = 3.0;
const PROP_DISC_Z: [f64; 2] = [PLATE + 16.6, PLATE + 16.6 + 5.5];
const PROP_Z: [f64; 2] = [PROP_DISC_Z[0] - PROP_CLEAR, PROP_DISC_Z[1] + PROP_CLEAR];
/// Maker table, F1404 KV4600 + GF3016 at 15.64 V, full throttle: 344.73 g.
const THRUST_N: f64 = 0.34473 * 9.81;
/// Shaft torque at full throttle: 274.32 W electrical at 80 % to 40053 rpm.
const REACTION_NMM: f64 = 274.32 * 0.8 / (40053.0 * std::f64::consts::TAU / 60.0) * 1000.0;
/// Spec section 4, entered values: punch (x3, at 4/3) and spin-up torque, corner drop 30 cm,
/// radial and sideways post hits at 6 m/s with the bell's 8.25 mm lever, belly drop 3 m on turf.
const PUNCH_N: f64 = 12.0;
const PUNCH_NMM: f64 = 160.0;
const CORNER_N: f64 = 200.0;
const RADIAL_N: f64 = 550.0;
const SIDE_N: f64 = 130.0;
const BELL_LEVER: f64 = 8.25;
const BELLY_G: f64 = 300.0;
/// Standoffs (SO1, M2 x 20) between the plate and the cage, 3 mm or more outside the props'
/// disks.
const STANDOFFS: [(f64, f64); 4] = [(21.0, 10.0), (21.0, -10.0), (-21.0, -10.0), (-21.0, 10.0)];
const STACK: [(f64, f64); 4] = [(10.0, 10.0), (10.0, -10.0), (-10.0, -10.0), (-10.0, 10.0)];
/// F1404 mount: 9 x 9 mm M2 (from the sim, UNCONFIRMED in drone-notes.md).
const MOTOR_SQUARE: f64 = 9.0;
/// The plate's own mass as the balance below assumes it, g (the engine weighs the real one; the
/// difference is the only load the hub's hold takes).
const PLATE_EST_G: f64 = 18.0;
/// The cage's mass as the balance assumes it, g.
const CAGE_EST_G: f64 = 15.0;
/// PA12 the cage may add to its fixed tub for ribs to the standoffs' feet, g.
const RIBS_G: f64 = 2.0;
/// Camera side screws (SCR3): the Caddx Ant's side M2 holes, taken at its body's middle, 7 mm
/// behind the lens face (hole position UNCONFIRMED in drone-notes.md).
const CAM_SCREW_X: f64 = 23.5;

fn carbon() -> Material {
    // Quasi-isotropic T700 laminate, in-plane (spec 5.1: allowable 450 MPa).
    Material { name: "Carbon fibre plate, quasi-isotropic T700".into(), e: 50_000.0, nu: 0.3, density: 1.55e-3, allowable: 450.0, color: "#2b2d30".into() }
}

fn pa12cf() -> Material {
    Material { name: "PA12 carbon filled (SLS)".into(), e: 3_800.0, nu: 0.36, density: 1.06e-3, allowable: 55.0, color: "#3a3d42".into() }
}

fn motors() -> [V3; 4] {
    [[ARM, ARM, 0.0], [ARM, -ARM, 0.0], [-ARM, -ARM, 0.0], [-ARM, ARM, 0.0]]
}

/// Props spin: front right and rear left clockwise seen from above (props-in).
const SPIN: [f64; 4] = [-1.0, 1.0, -1.0, 1.0];

fn bx(min: V3, max: V3) -> Region {
    Region::Box { min, max }
}

fn mid(b: [V3; 2]) -> V3 {
    scale(add(b[0], b[1]), 0.5)
}

/// Radius of a prop's 3 mm clearance envelope at height z (None: farther than 3 mm from the
/// disk's band, so no limit there).
fn envelope_r(z: f64) -> Option<f64> {
    let dz = (PROP_DISC_Z[0] - z).max(z - PROP_DISC_Z[1]).max(0.0);
    (dz < PROP_CLEAR).then(|| PROP_DISK_R + (PROP_CLEAR * PROP_CLEAR - dz * dz).sqrt())
}

/// The envelope round motor `m` as stacked cylinders `step` high, each as wide as the envelope
/// gets inside it, grown by `margin`: a keep-out no voxel of the frame may touch.
fn prop_envelope(m: V3, step: f64, margin: f64) -> Vec<Region> {
    let n = ((PROP_Z[1] - PROP_Z[0]) / step).ceil() as usize;
    (0..n)
        .map(|k| {
            let a = PROP_Z[0] + k as f64 * step;
            let b = (a + step).min(PROP_Z[1]);
            let widest = PROP_DISC_Z[0].max(a).min(b).max(PROP_DISC_Z[1].min(b).min(a.max(PROP_DISC_Z[0])));
            let r = envelope_r(widest).unwrap_or(PROP_DISK_R) + margin;
            let (a, b) = (if k == 0 { a - margin } else { a }, if k + 1 == n { b + margin } else { b });
            cyl([m[0], m[1], 0.0], [0.0, 0.0, 1.0], a, b, r)
        })
        .collect()
}

/// A bought part (or a share of the plate) as the balance sees it: mass g, centre, box size.
#[derive(Clone, Copy)]
struct Lump {
    m: f64,
    at: V3,
    size: V3,
}

/// Where the mass the plate carries sits, grouped by where it bears on the plate: each motor pad
/// (motor, prop, four screws), the four stack bolts (stack, VTX, receiver, capacitor, lead,
/// bolts, nuts, gummies), the four standoffs (cage, battery, camera, antennas, XIAO, ToF boards,
/// strap, standoffs, screws); and the plate's own, a hub share and an arm share per pad.
struct Masses {
    pads: [Vec<Lump>; 4],
    hub: Vec<Lump>,
    upper: Vec<Lump>,
    plate_hub: Lump,
    plate_arms: [Lump; 4],
}

impl Masses {
    fn of(list: &[Bought]) -> Self {
        let m = |r: &str| bought(list, r).mass_g;
        let l = layout();
        let lump = |m: f64, b: [V3; 2]| Lump { m, at: mid(b), size: sub(b[1], b[0]) };
        let point = |m: f64, at: V3| Lump { m, at, size: [0.0; 3] };
        let pads = motors().map(|c| {
            vec![
                lump(m("M1"), [add(c, [-8.95, -8.95, PLATE]), add(c, [8.95, 8.95, PLATE + 16.6])]),
                lump(m("P1"), [add(c, [-PROP_DISK_R, -PROP_DISK_R, PROP_DISC_Z[0]]), add(c, [PROP_DISK_R, PROP_DISK_R, PROP_DISC_Z[1]])]),
                point(4.0 * m("SCR1"), add(c, [0.0, 0.0, 1.0])),
            ]
        });
        let mut hub = vec![
            lump(m("STK1"), [l.esc[0], l.fc[1]]),
            lump(m("VTX1"), l.vtx),
            lump(m("RX1"), l.rx),
            lump(m("C1"), l.cap),
            lump(m("J1"), l.xt30),
        ];
        for (x, y) in STACK {
            hub.push(point(m("SCR2") + m("NUT1") + 2.0 * m("GUM1"), [x, y, 13.0]));
        }
        let mut upper = vec![
            lump(CAGE_EST_G, [[-37.0, -25.0, PLATE], [31.0, 25.0, 34.5]]),
            lump(m("B1"), l.battery),
            lump(m("CAM1"), l.cam),
            lump(m("MCU2"), l.xiao),
            lump(m("STR1"), l.tray),
            lump(m("ANT1"), [add(l.antenna.0, [-85.0, -1.5, -1.5]), add(l.antenna.0, [0.0, 1.5, 1.5])]),
            point(2.0 * m("SCR3"), [CAM_SCREW_X, 0.0, mid(l.cam)[2]]),
        ];
        for (_, b) in &l.tof {
            upper.push(lump(m("TOF1"), *b));
        }
        for (x, y) in STANDOFFS {
            upper.push(point(m("SO1") + 2.0 * m("SCR1"), [x, y, PLATE + 10.0]));
        }
        // The plate: 40 % in the hub, 15 % along each arm (its middle).
        let plate_hub = Lump { m: 0.4 * PLATE_EST_G, at: [0.0, 0.0, PLATE / 2.0], size: [45.0, 45.0, PLATE] };
        let plate_arms = motors().map(|c| Lump { m: 0.15 * PLATE_EST_G, at: [c[0] / 2.0, c[1] / 2.0, PLATE / 2.0], size: [0.0; 3] });
        Masses { pads, hub, upper, plate_hub, plate_arms }
    }

    fn all(&self) -> Vec<Lump> {
        let mut v: Vec<Lump> = self.pads.iter().flatten().copied().collect();
        v.extend(self.hub.iter().copied());
        v.extend(self.upper.iter().copied());
        v.push(self.plate_hub);
        v.extend(self.plate_arms);
        v
    }

    fn pad_mass(&self) -> f64 {
        self.pads[0].iter().map(|l| l.m).sum()
    }
}

/// Mass, centre and inertia tensor (g, mm, g mm^2 about the centre) of lumps.
fn rigid(lumps: &[Lump]) -> (f64, V3, [[f64; 3]; 3]) {
    let m: f64 = lumps.iter().map(|l| l.m).sum();
    let c = scale(lumps.iter().fold([0.0; 3], |a, l| add(a, scale(l.at, l.m))), 1.0 / m);
    let mut i = [[0.0; 3]; 3];
    for l in lumps {
        let d = sub(l.at, c);
        let own = own_inertia(l);
        for a in 0..3 {
            for b in 0..3 {
                i[a][b] += l.m * (if a == b { dot(d, d) } else { 0.0 } - d[a] * d[b]) + own[a][b];
            }
        }
    }
    (m, c, i)
}

fn own_inertia(l: &Lump) -> [[f64; 3]; 3] {
    let s = l.size.map(|x| x * x);
    let k = l.m / 12.0;
    [[k * (s[1] + s[2]), 0.0, 0.0], [0.0, k * (s[0] + s[2]), 0.0], [0.0, 0.0, k * (s[0] + s[1])]]
}

fn mat_vec(m: &[[f64; 3]; 3], v: V3) -> V3 {
    [0, 1, 2].map(|a| m[a][0] * v[0] + m[a][1] * v[1] + m[a][2] * v[2])
}

/// Solves a small dense system (Gaussian elimination with partial pivoting).
fn solve(mut a: Vec<Vec<f64>>, mut b: Vec<f64>) -> Vec<f64> {
    let n = b.len();
    for c in 0..n {
        let p = (c..n).max_by(|&i, &j| a[i][c].abs().total_cmp(&a[j][c].abs())).unwrap();
        a.swap(c, p);
        b.swap(c, p);
        for r in c + 1..n {
            let f = a[r][c] / a[c][c];
            for k in c..n {
                a[r][k] -= f * a[c][k];
            }
            b[r] -= f * b[c];
        }
    }
    let mut x = vec![0.0; n];
    for c in (0..n).rev() {
        x[c] = (b[c] - (c + 1..n).map(|k| a[c][k] * x[k]).sum::<f64>()) / a[c][c];
    }
    x
}

/// Forces at points `q` (least squares: the smallest that do it) whose sum is `f` and whose
/// moment about `p` is `t`.
fn spread_wrench(q: &[V3], p: V3, f: V3, t: V3) -> Vec<V3> {
    // Rows: three force sums, three moments; columns: the three components at each point.
    let n = 3 * q.len();
    let mut a = vec![vec![0.0; n]; 6];
    for (j, qj) in q.iter().enumerate() {
        let d = sub(*qj, p);
        for c in 0..3 {
            a[c][3 * j + c] = 1.0;
            let mut e = [0.0; 3];
            e[c] = 1.0;
            let m = cross(d, e);
            for r in 0..3 {
                a[3 + r][3 * j + c] = m[r];
            }
        }
    }
    let aat: Vec<Vec<f64>> = (0..6).map(|r| (0..6).map(|s| (0..n).map(|k| a[r][k] * a[s][k]).sum()).collect()).collect();
    let y = solve(aat, vec![f[0], f[1], f[2], t[0], t[1], t[2]]);
    (0..q.len()).map(|j| [0, 1, 2].map(|c| (0..6).map(|r| a[r][3 * j + c] * y[r]).sum())).collect()
}

/// The downward ToF board and its window (rear), mirrored at the front in the plate only so the
/// plate keeps both mirror planes.
const DOWN_TOF: [f64; 2] = [-37.0, -19.2];

fn plate_study(mass: &Masses) -> Study {
    let z = [0.0, 0.0, 1.0];
    // 97 voxels of 4/7 mm a side from the centre: the plate 7 voxels through, exactly 4 mm.
    let h = PLATE / 7.0;
    let half = 97.0 * h;
    let mut s = Study {
        name: "drone_bottom_plate".into(),
        min: [-half, -half, 0.0],
        max: [half, half, PLATE],
        voxel: h,
        material: carbon(),
        objective: Objective::Mass,
        volume_fraction: 0.45,
        safety_factor: 1.5,
        max_stress: Some(300.0),
        // The pad may never move more than the props' 3.0 mm clearance (spec 5.1), the 3.33 ms
        // radial post hit's peak in time included. The optimiser steers by the static one, and
        // the peak ran 1.52 times it (run of 2026-11-06): the static limit is 3.0 / 1.52.
        max_displacement: Some(1.95),
        max_impact_displacement: Some(3.0),
        min_frequency: Some(350.0),
        frequency_modes: 4,
        symmetry: [true, true, false],
        min_member: 2.5,
        manufacturing: Manufacturing::Extrusion { direction: z },
        iterations: 50,
        smoothing: 4,
        ..Study::default()
    };
    // A hole: no voxel reaches into it, and the engine cuts it exact into the surface.
    let hole = |s: &mut Study, c: V3, r: f64| s.keep_out.push(cyl(c, z, -1.0, PLATE + 1.0, r));
    // Motor pads: the F1404's 17.9 mm base, its four M2 screws (SCR1, 2.2 mm clearance) and the
    // shaft's clearance.
    let mut pads = Vec::new();
    for m in motors() {
        let pad = tube(m, z, -0.1, PLATE + 0.1, 2.6, 9.0);
        s.keep_in.push(pad);
        hole(&mut s, m, 2.6);
        for (dx, dy) in [(1.0, 1.0), (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0)] {
            hole(&mut s, add(m, [dx * MOTOR_SQUARE / 2.0, dy * MOTOR_SQUARE / 2.0, 0.0]), 1.1);
        }
        pads.push(pad);
    }
    // The stack's M2 x 25 bolts and the standoffs' M2 x 6 screws.
    let mut holes = Vec::new();
    for (x, y) in STACK.iter().chain(STANDOFFS.iter()) {
        let c = [*x, *y, 0.0];
        let r = tube(c, z, -0.1, PLATE + 0.1, 1.1, 3.5);
        s.keep_in.push(r);
        hole(&mut s, c, 1.1);
        holes.push(r);
    }
    // The downward ToF's window (and its mirror).
    for sign in [1.0, -1.0] {
        let (a, b) = (DOWN_TOF[0] * sign, DOWN_TOF[1] * sign);
        s.keep_out.push(bx([a.min(b) - 0.5, -7.0, -1.0], [a.max(b) + 0.5, 7.0, PLATE + 1.0]));
    }
    // The motors and props weigh on their pads in the modes (the 350 Hz floor is the arm with its
    // motor and prop on it, spec 4.2); the parts on the hub sit next to the hold and are left out.
    for (k, p) in pads.iter().enumerate() {
        s.point_masses.push(solid::PointMass { region: *p, mass_g: mass.pads[k].iter().map(|l| l.m).sum() });
    }
    // Held only at the hub's centre, under the stack. The drone is free: every case below is
    // balanced by the inertia of everything it moves, in translation and rotation (inertia
    // relief), so the hold takes only what the estimate of the plate's own mass leaves over.
    let hub = [0.0, 0.0, 0.0];
    s.keep_in.push(cyl(hub, z, -0.1, PLATE + 0.1, 5.0));
    s.supports.push(Support { region: cyl(hub, z, -0.1, PLATE + 0.1, 3.0), fix: [true; 3] });
    let (m_all, c, inertia) = rigid(&mass.all());
    let inv = invert3(&inertia);
    let pad_at = |k: usize| add(motors()[k], [0.0, 0.0, PLATE / 2.0]);
    let at = |r: &Region| r.center();
    // The inertial loads that balance outside loads `loads` on the free drone, added to them;
    // answers the plate's own acceleration (mm/s^2, as a body load).
    let relieve = |loads: &mut Vec<Load>| -> V3 {
        let (mut f, mut t) = ([0.0; 3], [0.0; 3]);
        for l in loads.iter() {
            match l {
                Load::Force { region, force } => {
                    f = add(f, *force);
                    t = add(t, cross(sub(at(region), c), *force));
                }
                Load::Torque { axis, moment, .. } => t = add(t, scale(unit(*axis), *moment)),
                Load::Pressure { .. } => unreachable!(),
            }
        }
        // N per g, and per g mm (angular acceleration times mm).
        let a = scale(f, 1.0 / m_all);
        let alpha = mat_vec(&inv, t);
        // Each lump pushed back by -m (a + alpha x d) (only the turning part for the plate's own,
        // whose straight part is the body load); its moment about where it bears.
        let push = |l: &Lump, straight: bool, p: V3| -> (V3, V3) {
            let lin = cross(alpha, sub(l.at, c));
            let acc = if straight { add(a, lin) } else { lin };
            let fl = scale(acc, -l.m);
            let own = mat_vec(&own_inertia(l), alpha);
            (fl, sub(cross(sub(l.at, p), fl), own))
        };
        for k in 0..4 {
            let (mut fk, mut tk) = ([0.0; 3], [0.0; 3]);
            for l in &mass.pads[k] {
                let (a1, b1) = push(l, true, pad_at(k));
                fk = add(fk, a1);
                tk = add(tk, b1);
            }
            let (a1, b1) = push(&mass.plate_arms[k], false, pad_at(k));
            fk = add(fk, a1);
            tk = add(tk, b1);
            loads.push(Load::Force { region: pads[k], force: fk });
            if norm(tk) > 1e-9 {
                loads.push(Load::Torque { region: pads[k], center: pad_at(k), axis: unit(tk), moment: norm(tk) });
            }
        }
        for (group, rs, extra) in [(&mass.hub, &holes[..4], Some(&mass.plate_hub)), (&mass.upper, &holes[4..], None)] {
            let q: Vec<V3> = rs.iter().map(at).collect();
            let p = scale(q.iter().fold([0.0; 3], |s, x| add(s, *x)), 1.0 / q.len() as f64);
            let (mut fg, mut tg) = ([0.0; 3], [0.0; 3]);
            for l in group.iter() {
                let (a1, b1) = push(l, true, p);
                fg = add(fg, a1);
                tg = add(tg, b1);
            }
            if let Some(l) = extra {
                let (a1, b1) = push(l, false, p);
                fg = add(fg, a1);
                tg = add(tg, b1);
            }
            for (r, fj) in rs.iter().zip(spread_wrench(&q, p, fg, tg)) {
                loads.push(Load::Force { region: *r, force: fj });
            }
        }
        // N/g to mm/s^2: 1e6.
        scale(a, -1e6)
    };
    let mut case = |name: &str, mut loads: Vec<Load>| {
        let acc = relieve(&mut loads);
        s.cases.push(LoadCase { name: name.into(), loads, acceleration: Some(acc), weight: 1.0 });
    };
    let mut punch = Vec::new();
    for (k, m) in motors().iter().enumerate() {
        punch.push(Load::Force { region: pads[k], force: [0.0, 0.0, PUNCH_N] });
        punch.push(Load::Torque { region: pads[k], center: add(*m, [0.0, 0.0, PLATE / 2.0]), axis: z, moment: SPIN[k] * PUNCH_NMM });
    }
    case("punch", punch);
    case("corner drop 30 cm", vec![Load::Force { region: pads[0], force: [0.0, 0.0, CORNER_N] }]);
    // A post hit at the bell, 8.25 mm over the plate's middle: the force and its lever.
    let hit = |f: V3| -> Vec<Load> {
        let m = cross([0.0, 0.0, BELL_LEVER], f);
        vec![Load::Force { region: pads[0], force: f }, Load::Torque { region: pads[0], center: pad_at(0), axis: unit(m), moment: norm(m) }]
    };
    case("radial post hit", hit(scale(unit([-ARM, -ARM, 0.0]), RADIAL_N)));
    case("sideways post hit", hit(scale(unit([-ARM, ARM, 0.0]), SIDE_N)));
    // Belly drop on turf at 300 g: the ground under the hub's bosses (the arms landing too would
    // only help), everything on the plate thrown down onto it.
    let ground = BELLY_G * 9.81e-3 * m_all;
    let bosses: Vec<Region> = holes.iter().copied().collect();
    let belly: Vec<Load> = bosses.iter().map(|r| Load::Force { region: *r, force: [0.0, 0.0, ground / bosses.len() as f64] }).collect();
    case("belly drop 300 g", belly);
    s.dynamics = solid::Dynamics { modes: 4, impacts: vec![Impact { case: 2, duration: 0.00333, window: 0.008, steps: 160, damping: 0.02 }] };
    eprintln!("drone balance: {:.1} g, centre {:?} mm, pad {:.2} g", m_all, c.map(|v| (v * 100.0).round() / 100.0), mass.pad_mass());
    s
}

fn invert3(m: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    let c = |a: usize, b: usize, cc: usize, d: usize| m[a][b] * m[cc][d] - m[a][d] * m[cc][b];
    [
        [c(1, 1, 2, 2) / det, -c(0, 1, 2, 2) / det, c(0, 1, 1, 2) / det],
        [-c(1, 0, 2, 2) / det, c(0, 0, 2, 2) / det, -c(0, 0, 1, 2) / det],
        [c(1, 0, 2, 1) / det, -c(0, 0, 2, 1) / det, c(0, 0, 1, 1) / det],
    ]
}

/// Where the bought parts sit (frame: x forward, y left, z up, plate bottom at z = 0).
struct Layout {
    esc: [V3; 2],
    fc: [V3; 2],
    vtx: [V3; 2],
    cam: [V3; 2],
    rx: [V3; 2],
    xiao: [V3; 2],
    battery: [V3; 2],
    tray: [V3; 2],
    tof: Vec<(&'static str, [V3; 2])>,
    antenna: (V3, V3),
    cap: [V3; 2],
    xt30: [V3; 2],
}

fn layout() -> Layout {
    let top = 32.5;
    Layout {
        esc: [[-17.5, -17.5, PLATE + 1.0], [17.5, 17.5, PLATE + 6.5]],
        fc: [[-16.0, -15.0, PLATE + 8.0], [16.0, 15.0, PLATE + 14.2]],
        vtx: [[-14.0, -14.0, PLATE + 15.0], [14.0, 14.0, PLATE + 18.3]],
        // Its bottom 0.8 mm over the front ToF board, its top 0.5 mm under the tray.
        cam: [[16.5, -7.0, 18.0], [30.5, 7.0, 32.0]],
        rx: [[-6.5, -5.5, 24.0], [6.5, 5.5, 27.0]],
        xiao: [[-10.5, -8.9, 28.4], [10.5, 8.9, 31.9]],
        battery: [[-27.0, -14.0, top + 2.0], [32.0, 14.0, top + 28.0]],
        tray: [[-27.0, -14.5, top], [32.0, 14.5, top + 2.0]],
        tof: vec![
            ("front", [[28.3, -8.9, PLATE + 0.5], [30.5, 8.9, PLATE + 13.2]]),
            // Its top 3.4 mm under the rear props' disks.
            ("rear", [[-40.0, -8.9, PLATE + 0.5], [-37.8, 8.9, PLATE + 13.2]]),
            // On the outside of the cage's side walls.
            ("left", [[-8.9, 20.0, PLATE + 1.0], [8.9, 22.2, PLATE + 13.7]]),
            ("right", [[-8.9, -22.2, PLATE + 1.0], [8.9, -20.0, PLATE + 13.7]]),
            // On the tray's tail behind the battery, 0.4 mm up on its screw bosses.
            ("up", [[-40.0, -6.35, 34.9], [-27.3, 6.35, 37.1]]),
            // On the plate, in the cage floor's opening, over the plate's window.
            ("down", [[DOWN_TOF[0], -6.35, PLATE], [DOWN_TOF[1], 6.35, PLATE + 2.2]]),
        ],
        antenna: ([-14.0, 0.0, 20.0], [-1.0, 0.0, 0.0]),
        // Clear of the stack's ESC board (|x|, |y| <= 17.5) by 0.5 mm.
        cap: [[-35.5, 13.8, PLATE + 1.0], [-18.0, 23.8, PLATE + 11.0]],
        xt30: [[-35.5, -23.8, PLATE + 1.0], [-18.0, -13.8, PLATE + 11.0]],
    }
}

/// The cage's inside: the bought parts it closes round, each with 0.5 mm of air (spec E1 asks
/// 1.0 from the structure; 0.5 is what fits between the props, and the boards sit on gummies).
fn cavities() -> Vec<[V3; 2]> {
    vec![
        // ESC board, the 4-in-1 down on its gummies.
        [[-18.0, -18.0, PLATE + 0.5], [18.0, 18.0, 11.0]],
        // FC board.
        [[-16.5, -15.5, 11.0], [16.5, 15.5, 18.7]],
        // VTX.
        [[-14.5, -14.5, 18.7], [14.5, 14.5, 22.8]],
        // The stack bolts' nylock nuts.
        [[-12.5, -12.5, 22.8], [12.5, 12.5, 25.7]],
        // Receiver and XIAO, up to the tray.
        [[-11.0, -9.4, 25.7], [11.0, 9.4, 32.5]],
        // Between the XIAO and the camera (walls round it alone would close a pocket of powder).
        [[11.0, -7.5, 22.8], [16.0, 7.5, 32.5]],
        // Camera bay, open in front of the lens, up to the tray.
        [[16.0, -7.5, 17.5], [30.5, 7.5, 32.5]],
        // Rear bay: capacitor (left), XT30 (right), the down ToF between them.
        [[-36.0, -24.3, PLATE + 0.5], [-17.5, 24.3, 15.5]],
    ]
}

/// Solid inside the cavities: a hood over the down ToF board, so the plate's window under it opens
/// only onto the board, never into the rear bay (1.0 mm over the board's 0.4 mm air).
fn cavity_cuts() -> Vec<[V3; 2]> {
    vec![[[DOWN_TOF[0] - 1.4, -7.75, 0.0], [DOWN_TOF[1] + 1.4, 7.75, PLATE + 3.6]]]
}

/// Walls of the cage: every voxel of `grid` outside the cavities but within `wall` of them,
/// merged into boxes (each box covers voxel centres only of the wall).
fn cage_walls(grid: &solid::Grid, wall: f64) -> Vec<Region> {
    let [nx, ny, nz] = grid.n;
    let h = grid.h;
    let within = |p: V3, bs: &[[V3; 2]]| bs.iter().any(|b| (0..3).all(|a| p[a] > b[0][a] && p[a] < b[1][a]));
    let (open, cut) = (cavities(), cavity_cuts());
    let inside = |p: V3| within(p, &open) && !within(p, &cut);
    let id = |i: usize, j: usize, k: usize| (k * ny + j) * nx + i;
    let mut cav = vec![false; nx * ny * nz];
    for k in 0..nz {
        for j in 0..ny {
            for i in 0..nx {
                cav[id(i, j, k)] = inside(grid.element_center(grid.element(i, j, k)));
            }
        }
    }
    let reach = (wall / h).ceil() as isize;
    let mut offsets = Vec::new();
    for dk in -reach..=reach {
        for dj in -reach..=reach {
            for di in -reach..=reach {
                let d = h * ((di * di + dj * dj + dk * dk) as f64).sqrt();
                if d > 0.0 && d <= wall + 1e-9 {
                    offsets.push((di, dj, dk));
                }
            }
        }
    }
    let mut shell = vec![false; nx * ny * nz];
    for k in 0..nz {
        for j in 0..ny {
            for i in 0..nx {
                if cav[id(i, j, k)] {
                    continue;
                }
                shell[id(i, j, k)] = offsets.iter().any(|&(di, dj, dk)| {
                    let (a, b, c) = (i as isize + di, j as isize + dj, k as isize + dk);
                    a >= 0 && b >= 0 && c >= 0 && (a as usize) < nx && (b as usize) < ny && (c as usize) < nz && cav[id(a as usize, b as usize, c as usize)]
                });
            }
        }
    }
    // Greedy merge: runs along x, grown along y, then along z.
    let mut used = vec![false; nx * ny * nz];
    let mut boxes = Vec::new();
    let free = |used: &Vec<bool>, i: usize, j: usize, k: usize| shell[id(i, j, k)] && !used[id(i, j, k)];
    for k in 0..nz {
        for j in 0..ny {
            for i in 0..nx {
                if !free(&used, i, j, k) {
                    continue;
                }
                let mut i1 = i;
                while i1 + 1 < nx && free(&used, i1 + 1, j, k) {
                    i1 += 1;
                }
                let mut j1 = j;
                while j1 + 1 < ny && (i..=i1).all(|a| free(&used, a, j1 + 1, k)) {
                    j1 += 1;
                }
                let mut k1 = k;
                while k1 + 1 < nz && (j..=j1).all(|b| (i..=i1).all(|a| free(&used, a, b, k1 + 1))) {
                    k1 += 1;
                }
                for c in k..=k1 {
                    for b in j..=j1 {
                        for a in i..=i1 {
                            used[id(a, b, c)] = true;
                        }
                    }
                }
                let lo = grid.element_center(grid.element(i, j, k));
                let hi = grid.element_center(grid.element(i1, j1, k1));
                boxes.push(bx(sub(lo, [0.25 * h; 3]), add(hi, [0.25 * h; 3])));
            }
        }
    }
    boxes
}

fn grow(b: [V3; 2], d: f64) -> Region {
    bx(sub(b[0], [d; 3]), add(b[1], [d; 3]))
}

fn cage_study() -> Study {
    let z = [0.0, 0.0, 1.0];
    let l = layout();
    let (x0, x1, y1, z0, z1) = (-41.0, 32.5, 25.5, PLATE, 34.5);
    let mut s = Study {
        name: "drone_cage".into(),
        min: [x0, -y1, z0],
        max: [x1, y1, z1],
        // Walls of 1.0 mm (SLS) are two voxels; the floor on the plate is one.
        voxel: 0.5,
        material: pa12cf(),
        // A closed tub round the electronics (spec T7: a 4 mm ball reaches none of them, rays
        // escape <= 6 %), its walls fixed; the engine grows the stiffest ribs from them to the
        // standoffs' feet with what mass is left.
        objective: Objective::Compliance,
        volume_fraction: 0.16,
        // Crashes and 3 m drops are rare events: 1.5 on the 55 MPa allowable (spec section 4).
        safety_factor: 1.5,
        symmetry: [false, true, false],
        min_member: 1.0,
        // SLS prints in a powder bed that holds every overhang: no overhang rule.
        manufacturing: Manufacturing::Free,
        iterations: 30,
        smoothing: 6,
        dynamics: solid::Dynamics { modes: 3, impacts: Vec::new() },
        ..Study::default()
    };
    // The bought parts inside, as in `cavities`, and the stack bolts with their nuts (the bolts
    // stop at the nuts: the roof over them stays closed).
    for b in [l.esc, l.fc, l.vtx, l.rx, l.xiao, l.cap, l.xt30, l.cam] {
        s.keep_out.push(grow(b, 0.5));
    }
    for (x, y) in STACK {
        s.keep_out.push(cyl([x, y, 0.0], z, PLATE, 25.7, 2.5));
    }
    // The camera's view, open ahead of the lens.
    s.keep_out.push(bx([l.cam[1][0], -9.0, l.cam[0][2] - 2.0], [x1 + 1.0, 9.0, l.cam[1][2]]));
    // The camera's side screws (SCR3, M2 x 3) in two pads.
    let cam_z = mid(l.cam)[2];
    for sign in [1.0, -1.0] {
        let y = sign * 8.25;
        s.keep_in.push(bx([CAM_SCREW_X - 2.0, y - 0.75, cam_z - 2.0], [CAM_SCREW_X + 2.0, y + 0.75, cam_z + 2.0]));
        s.keep_out.push(cyl([CAM_SCREW_X, 0.0, cam_z], [0.0, sign, 0.0], 6.9, 10.5, 1.1));
    }
    // The video antenna out of the VTX's wall: a 3.2 mm hole round the 3.0 mm lead (spec 4 mm
    // ball, <= 3.2 mm openings).
    s.keep_out.push(cyl(l.antenna.0, l.antenna.1, 0.0, 30.0, 1.6));
    // The XT30 lead out of the rear bay's back wall: a slot 3.0 mm wide.
    s.keep_out.push(bx([x0 - 1.0, mid(l.xt30)[1] - 1.5, 7.0], [l.xt30[0][0], mid(l.xt30)[1] + 1.5, 13.0]));
    // The ToF boards, each on a pad on the wall behind it, with its window in front.
    for (name, b) in &l.tof {
        if *name == "up" || *name == "down" {
            continue;
        }
        s.keep_out.push(grow(*b, 0.4));
        let (pad, window) = match *name {
            "front" => (bx([b[0][0] - 1.6, b[0][1], b[0][2]], [b[0][0] - 0.4, b[1][1], b[1][2]]), bx([b[1][0], b[0][1] + 3.0, b[0][2] + 2.0], [x1 + 1.0, b[1][1] - 3.0, b[1][2] - 2.0])),
            "rear" => (bx([b[1][0] + 0.4, b[0][1], b[0][2]], [b[1][0] + 1.6, b[1][1], b[1][2]]), bx([x0 - 1.0, b[0][1] + 3.0, b[0][2] + 2.0], [b[0][0], b[1][1] - 3.0, b[1][2] - 2.0])),
            "left" => (bx([b[0][0], b[0][1] - 1.6, b[0][2]], [b[1][0], b[0][1] - 0.4, b[1][2]]), bx([b[0][0] + 3.0, b[1][1], b[0][2] + 2.0], [b[1][0] - 3.0, y1 + 1.0, b[1][2] - 2.0])),
            _ => (bx([b[0][0], b[1][1] + 0.4, b[0][2]], [b[1][0], b[1][1] + 1.6, b[1][2]]), bx([b[0][0] + 3.0, -y1 - 1.0, b[0][2] + 2.0], [b[1][0] - 3.0, b[0][1], b[1][2] - 2.0])),
        };
        s.keep_in.push(pad);
        s.keep_out.push(window);
    }
    // The down ToF lies on the plate under its hood, in an opening of the floor (its window is
    // the plate's).
    let down = l.tof.iter().find(|t| t.0 == "down").unwrap().1;
    s.keep_out.push(grow(down, 0.4));
    // The props' envelopes and the motors under them.
    for m in motors() {
        s.keep_out.extend(prop_envelope(m, 0.5, 0.3));
        s.keep_out.push(cyl(m, z, 0.0, PROP_Z[0], 10.5));
    }
    // Battery tray on top with the strap's two slots: the strap (STR1, 10 x 1.5) runs down at
    // |y| 14 to 15.5, 0.5 mm clear each way. Its tail carries the up ToF behind the battery.
    let tray = bx(l.tray[0], l.tray[1]);
    s.keep_in.push(tray);
    let up = l.tof.iter().find(|t| t.0 == "up").unwrap().1;
    s.keep_in.push(bx([x0 + 0.5, up[0][1] - 0.5, l.tray[0][2]], [l.tray[0][0] + 0.5, up[1][1] + 0.5, l.tray[1][2]]));
    for sign in [1.0, -1.0] {
        s.keep_out.push(bx([-5.5, sign * 14.75 - 1.25, 29.5], [5.5, sign * 14.75 + 1.25, z1 + 1.0]));
    }
    // Standing on the standoffs' tops (M2 x 6 screws up into them).
    let mut feet = Vec::new();
    for (x, y) in STANDOFFS {
        let c = [x, y, 0.0];
        let top = PLATE + 20.0;
        let f = tube(c, z, top, top + 3.0, 1.1, 3.6);
        s.keep_in.push(f);
        s.keep_out.push(cyl(c, z, top - 0.5, top + 3.5, 1.1));
        s.keep_out.push(cyl(c, z, z0 - 1.0, top, 2.2));
        // The M2 button head (3.5 mm) on the foot, and a driver's column up through the tray.
        s.keep_out.push(cyl(c, z, top + 3.0, z1 + 1.0, 2.3));
        feet.push(f);
    }
    for f in &feet {
        s.supports.push(Support { region: *f, fix: [true; 3] });
    }
    // The closed tub: walls fixed solid.
    let grid = solid::Grid::new(s.min, s.max, s.voxel);
    let walls = cage_walls(&grid, 1.0);
    s.keep_in.extend(walls);
    // The spec's crash table (section 4) on the cage: hits on the hood and sides, the battery's
    // load through the tray.
    let pressure = |s: &mut Study, name: &str, region: Region, force: V3, extra: Vec<Load>, acc: Option<V3>| {
        let mut loads = vec![Load::Pressure { region, direction: unit(force), pressure: norm(force) / solid::loads::projected_area(&grid, &region, unit(force)) }];
        loads.extend(extra);
        s.cases.push(LoadCase { name: name.into(), loads, acceleration: acc, weight: 1.0 });
    };
    // Nose hit, 310 N on the hood: the tray's nose and the camera bay's cheeks (full mass,
    // 4 m/s, 8 mm).
    pressure(&mut s, "nose hit", bx([28.5, -y1, z0 + 4.0], [x1, y1, z1]), [-310.0, 0.0, 0.0], Vec::new(), None);
    // Side swipe, 140 N on a 10 mm patch, with the battery's 57.4 N sideways.
    let patch = bx([-5.0, 14.0, 10.0], [5.0, y1, 25.0]);
    pressure(&mut s, "side swipe", patch, [0.0, -140.0, 0.0], vec![Load::Force { region: tray, force: [0.0, -57.4, 0.0] }], Some([0.0, -718_000.0, 0.0]));
    // Rear swipe on the antenna side, 140 N on a 10 mm patch of the rear bay's back wall.
    pressure(&mut s, "rear swipe", bx([x0, -5.0, z0], [-35.5, 5.0, 16.5]), [140.0, 0.0, 0.0], Vec::new(), None);
    // Inverted 3 m drop: the ground on the battery, everything under the roof at 300 g on it.
    s.cases.push(LoadCase { name: "inverted drop 3 m".into(), loads: vec![Load::Force { region: tray, force: [0.0, 0.0, -322.9] }], acceleration: Some([0.0, 0.0, 2_943_000.0]), weight: 1.0 });
    // Front crash: the battery thrown forward on the tray (friction-limited, 100 N) at 288 g.
    s.cases.push(LoadCase { name: "battery front crash".into(), loads: vec![Load::Force { region: tray, force: [100.0, 0.0, 0.0] }], acceleration: Some([2_821_000.0, 0.0, 0.0]), weight: 1.0 });
    // The fixed walls and pads, and RIBS_G of PA12 more for the ribs to the feet.
    let fixed: std::collections::HashSet<usize> = s.keep_in.iter().flat_map(|r| grid.elements_in(r)).collect();
    let voids: std::collections::HashSet<usize> = s.keep_out.iter().flat_map(|r| grid.elements_touching(r)).collect();
    let fixed_g = fixed.difference(&voids).count() as f64 * grid.h.powi(3) * s.material.density;
    s.mass_target_g = Some(fixed_g + RIBS_G);
    eprintln!("drone cage: {} wall boxes, fixed {:.2} g, target {:.2} g", s.keep_in.len(), fixed_g, fixed_g + RIBS_G);
    s
}

fn main() {
    let dir = out_dir("drone");
    let list = components("drone");
    let masses = Masses::of(&list);
    let mut plate = plate_study(&masses);
    let mut cage = cage_study();
    // A short look (DRONE_ITERATIONS=1: the fixed walls and pads only), never the result.
    if let Some(n) = std::env::var("DRONE_ITERATIONS").ok().and_then(|v| v.parse().ok()) {
        plate.iterations = n;
        cage.iterations = n;
    }
    if std::env::args().any(|a| a == "--plan") {
        // The studies' loads and walls only, written for a look, nothing grown.
        for st in [&plate, &cage] {
            std::fs::write(std::env::temp_dir().join(format!("{}.plan.json", st.name)), serde_json::to_string_pretty(st).unwrap()).unwrap();
        }
        return;
    }
    let mut results = Vec::new();
    for s in [&plate, &cage] {
        if !wanted(&s.name) {
            continue;
        }
        let r = run_part(&dir, s);
        results.push((r, s.material.density));
    }
    if results.len() < 2 {
        return;
    }
    let (plate_r, cage_r) = (&results[0].0, &results[1].0);
    let mut structure = solid::Mesh::default();
    mesh_append(&mut structure, &plate_r.mesh);
    mesh_append(&mut structure, &cage_r.mesh);
    std::fs::write(dir.join("drone_frame.stl"), solid::export::stl(&structure, "Drone3inFrame")).unwrap();
    std::fs::write(dir.join("drone_frame.3mf"), solid::export::three_mf(&structure, "Drone3inFrame")).unwrap();

    // Every sourced part placed, rigidly held by the plate.
    let l = layout();
    let mut asm = AssemblyFile::default();
    asm.made("drone_bottom_plate", "parts/drone_bottom_plate.3mf", &Pose::ID, &plate.material.name, "CNC routed from 4 mm sheet", plate_r.mass_g, None);
    asm.made("drone_cage", "parts/drone_cage.3mf", &Pose::ID, &cage.material.name, "SLS (powder bed, no supports)", cage_r.mass_g, Some(("drone_bottom_plate", json!({"name": "drone_cage mount", "type": "rigid", "origin": [0.0, 0.0, PLATE + 20.0], "axis": [0.0, 0.0, 1.0]}))));
    let mut points: Vec<(f64, V3, String)> = Vec::new();
    let mut picture = solid::Mesh::default();
    let mut place = |asm: &mut AssemblyFile, reference: &str, name: &str, shape: &str, local: solid::Mesh, pose: Pose, role: &str| {
        let b = bought(&list, reference);
        let world = mesh_transformed(&local, &pose);
        points.push((b.mass_g, centre(&world), name.to_string()));
        mesh_append(&mut picture, &world);
        asm.bought(&dir, b, name, shape, &local, &pose, Some("drone_bottom_plate"), role);
    };
    let block = |b: [V3; 2]| (box_mesh(scale(sub(b[1], b[0]), -0.5), scale(sub(b[1], b[0]), 0.5)), Pose::trans(scale(add(b[0], b[1]), 0.5)));
    let z = [0.0, 0.0, 1.0];
    for (k, m) in motors().iter().enumerate() {
        let spin = if SPIN[k] > 0.0 { "ccw" } else { "cw" };
        place(&mut asm, "M1", &format!("Motor {} ({spin})", k + 1), "M1", cylinder_mesh([0.0; 3], [0.0, 0.0, 16.6], 8.95, 32), Pose::trans(add(*m, [0.0, 0.0, PLATE])), "motor on the arm pad, four M2 x 6 from below");
        place(&mut asm, "P1", &format!("Prop {} ({spin})", k + 1), "P1", cylinder_mesh([0.0; 3], [0.0, 0.0, 5.5], 76.49 / 2.0, 48), Pose::trans(add(*m, [0.0, 0.0, PLATE + 16.6])), "prop on the motor shaft");
        for (n, (dx, dy)) in [(1.0, 1.0), (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0)].into_iter().enumerate() {
            let at = add(*m, [dx * MOTOR_SQUARE / 2.0, dy * MOTOR_SQUARE / 2.0, -1.3]);
            let mut screw = cylinder_mesh([0.0; 3], [0.0, 0.0, 1.3], 1.75, 12);
            mesh_append(&mut screw, &cylinder_mesh([0.0, 0.0, 1.3], [0.0, 0.0, 7.3], 1.0, 12));
            place(&mut asm, "SCR1", &format!("Motor {} screw {}", k + 1, n + 1), "SCR1", screw, Pose::trans(at), "M2 x 6 motor screw");
        }
    }
    let mut stack = solid::Mesh::default();
    let (esc, fc) = (block(l.esc), block(l.fc));
    mesh_append(&mut stack, &mesh_transformed(&esc.0, &esc.1));
    mesh_append(&mut stack, &mesh_transformed(&fc.0, &fc.1));
    place(&mut asm, "STK1", "FC + ESC stack", "STK1", stack, Pose::ID, "20 x 20 stack on four M2 x 25 bolts and gummies");
    for (reference, name, b, role) in [
        ("VTX1", "Video transmitter", l.vtx, "on the stack bolts"),
        ("CAM1", "FPV camera", l.cam, "between the cage's camera pads, M2 x 3 each side"),
        ("RX1", "Receiver", l.rx, "between the stack bolts under the XIAO"),
        ("MCU2", "XIAO ESP32S3", l.xiao, "over the stack under the battery tray"),
        ("B1", "Battery 4S 650 mAh", l.battery, "on the cage tray, strapped"),
        ("C1", "Low-ESR capacitor", l.cap, "left rear bay, across the ESC battery pads"),
        ("J1", "XT30 pigtail", l.xt30, "right rear bay (lead not drawn)"),
    ] {
        let (mesh, pose) = block(b);
        place(&mut asm, reference, name, reference, mesh, pose, role);
    }
    for (side, b) in &l.tof {
        let (mesh, pose) = block(*b);
        place(&mut asm, "TOF1", &format!("ToF {side}"), &format!("TOF1_{side}"), mesh, pose, "ToF board on its cage pad, window in front");
    }
    let (a0, ad) = l.antenna;
    place(&mut asm, "ANT1", "Video antenna", "ANT1", cylinder_mesh([0.0; 3], scale(ad, 85.0), 1.5, 16), Pose::trans(a0), "MMCX on the VTX, out of the back");
    for (n, (x, y)) in STANDOFFS.iter().enumerate() {
        let c = [*x, *y, PLATE];
        place(&mut asm, "SO1", &format!("Standoff {}", n + 1), "SO1", cylinder_mesh([0.0; 3], [0.0, 0.0, 20.0], 2.0, 16), Pose::trans(c), "plate to cage");
        let mut screw = cylinder_mesh([0.0; 3], [0.0, 0.0, 1.3], 1.75, 12);
        mesh_append(&mut screw, &cylinder_mesh([0.0, 0.0, 1.3], [0.0, 0.0, 7.3], 1.0, 12));
        place(&mut asm, "SCR1", &format!("Standoff {} bottom screw", n + 1), "SCR1", screw.clone(), Pose::trans([*x, *y, -1.3]), "M2 x 6 up into the standoff");
        place(&mut asm, "SCR1", &format!("Standoff {} top screw", n + 1), "SCR1", screw, Pose { r: Pose::rot([1.0, 0.0, 0.0], std::f64::consts::PI).r, t: [*x, *y, PLATE + 24.3] }, "M2 x 6 down through the cage foot");
    }
    for (n, (x, y)) in STACK.iter().enumerate() {
        let mut bolt = cylinder_mesh([0.0; 3], [0.0, 0.0, 2.0], 1.9, 12);
        mesh_append(&mut bolt, &cylinder_mesh([0.0, 0.0, 2.0], [0.0, 0.0, 27.0], 1.0, 12));
        place(&mut asm, "SCR2", &format!("Stack bolt {}", n + 1), "SCR2", bolt, Pose::trans([*x, *y, -2.0]), "M2 x 25 through plate, ESC, FC, VTX");
        place(&mut asm, "NUT1", &format!("Stack nut {}", n + 1), "NUT1", ring_mesh(1.0, 2.0, 2.8, 6), Pose::trans([*x, *y, PLATE + 18.4]), "nylock on top of the VTX");
        place(&mut asm, "GUM1", &format!("Gummy ESC {}", n + 1), "GUM1", ring_mesh(1.0, 2.5, 1.0, 12), Pose::trans([*x, *y, PLATE]), "under the ESC");
        place(&mut asm, "GUM1", &format!("Gummy FC {}", n + 1), "GUM1", ring_mesh(1.0, 2.5, 1.5, 12), Pose::trans([*x, *y, PLATE + 6.5]), "between the ESC and the FC");
    }
    for sign in [1.0, -1.0] {
        let mut screw = cylinder_mesh([0.0; 3], [0.0, 0.0, 1.0], 1.75, 12);
        mesh_append(&mut screw, &cylinder_mesh([0.0, 0.0, 1.0], [0.0, 0.0, 4.0], 1.0, 12));
        let pose = Pose { r: Pose::rot([1.0, 0.0, 0.0], sign * std::f64::consts::FRAC_PI_2).r, t: [CAM_SCREW_X, sign * 10.0, mid(l.cam)[2]] };
        place(&mut asm, "SCR3", &format!("Camera screw {}", if sign > 0.0 { "left" } else { "right" }), "SCR3", screw, pose, "M2 x 3 through the camera pad");
    }
    let mut strap = solid::Mesh::default();
    let (bt, bb) = (l.battery[1][2], l.tray[0][2]);
    mesh_append(&mut strap, &box_mesh([-5.0, -14.75, bt], [5.0, 14.75, bt + 1.5]));
    for s in [1.0, -1.0] {
        mesh_append(&mut strap, &box_mesh([-5.0, s * 14.0 - 0.75 * (1.0 - s), bb - 2.0], [5.0, s * 14.0 + 0.75 * (1.0 + s), bt]));
    }
    place(&mut asm, "STR1", "Battery strap", "STR1", strap, Pose::ID, "through the tray's two slots");
    asm.loose(bought(&list, "FR1"), 1, "made here: drone_bottom_plate + drone_cage (this assembly's generated parts)");
    drop(place);
    std::fs::write(dir.join("drone_components.stl"), solid::export::stl(&picture, "DroneComponents")).unwrap();

    let parts: Vec<(f64, V3, V3)> = results.iter().map(|(r, d)| voxel_inertia(r, *d)).collect();
    let frame = combine(&parts);
    let mut all = parts.clone();
    all.extend(points.iter().map(|(m, p, _)| (*m, *p, [0.0; 3])));
    let up = combine(&all);
    // One parts list for the simulation's file and the assembly: the frame's mass is the two
    // grown parts' analysed solid, the all-up mass that plus every placed bought part.
    let made = plate_r.mass_g + cage_r.mass_g;
    let placed: f64 = points.iter().map(|p| p.0).sum();
    assert!((frame.0 - made).abs() < 1e-6 * made.max(1.0), "frame mass {} vs grown parts {}", frame.0, made);
    assert!((up.0 - made - placed).abs() < 1e-6 * up.0, "all-up {} vs {} + {}", up.0, made, placed);
    // g mm^2 to kg m^2: 1e-3 * 1e-6.
    let si = |i: V3| i.map(|v| v * 1e-9);
    let impact = plate_r.analysis.impacts.first();
    let doc = json!({
        "schema": "viaform.drone-frame/1",
        "units": {"mass": "g", "length": "mm", "inertia": "kg m^2, about the centre of mass, body axes x forward y left z up"},
        // The flight simulation reads `mass_g` and `inertia_kg_m2` as the frame's own, and the
        // whole drone from `all_up_mass_g` (sim/src/airframe.rs).
        "mass_g": frame.0,
        "center_of_mass_mm": frame.1,
        "inertia_kg_m2": si(frame.2),
        "all_up_mass_g": up.0,
        "all_up": {"mass_g": up.0, "center_of_mass_mm": up.1, "inertia_kg_m2": si(up.2)},
        "frame": {"mass_g": frame.0, "center_of_mass_mm": frame.1, "inertia_kg_m2": si(frame.2)},
        "arm_length_mm": (2.0f64).sqrt() * ARM,
        "wheelbase_mm": 2.0 * (2.0f64).sqrt() * ARM,
        "prop_diameter_in": 3.0,
        "battery": {"component_ref": "B1", "cells": 4, "capacity_mah": 650},
        "motor_mounts": motors().iter().zip(SPIN).enumerate().map(|(k, (p, s))| json!({"index": k, "position_mm": add(*p, [0.0, 0.0, PLATE]), "thrust_axis": z, "spin": if s > 0.0 { "ccw" } else { "cw" }, "bolt_square_mm": MOTOR_SQUARE, "thread": "M2", "component_ref": "M1", "max_thrust_n": THRUST_N, "reaction_torque_nmm": REACTION_NMM})).collect::<Vec<_>>(),
        "components": points.iter().map(|(m, p, n)| json!({"name": n, "mass_g": m, "position_mm": p})).collect::<Vec<_>>(),
        "structure": [
            {"part": plate_r.name, "material": plate.material.name, "mass_g": plate_r.mass_g, "max_stress_mpa": plate_r.max_stress, "stress_limit_mpa": plate_r.limit, "safety_factor": plate_r.safety_factor, "first_mode_hz": plate_r.first_mode_hz, "feasible": plate_r.feasible,
             "max_displacement_mm": plate_r.analysis.max_displacement, "cases": plate.cases.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
             "pole_strike_impact": impact.map(|i| json!({"pulse_s": plate.dynamics.impacts[0].duration, "peak_stress_mpa": i.peak_stress, "peak_displacement_mm": i.peak_displacement, "dynamic_amplification": i.amplification}))},
            {"part": cage_r.name, "material": cage.material.name, "mass_g": cage_r.mass_g, "max_stress_mpa": cage_r.max_stress, "stress_limit_mpa": cage_r.limit, "safety_factor": cage_r.safety_factor, "first_mode_hz": cage_r.first_mode_hz, "feasible": cage_r.feasible, "cases": cage.cases.iter().map(|c| c.name.clone()).collect::<Vec<_>>()},
        ],
        "modes_hz": plate_r.analysis.modes.iter().map(|m| m.frequency).collect::<Vec<_>>(),
        "files": {"assembly": "drone/assembly.json", "frame_stl": "drone/drone_frame.stl", "frame_3mf": "drone/drone_frame.3mf", "plate_3mf": "drone/parts/drone_bottom_plate.3mf", "cage_3mf": "drone/parts/drone_cage.3mf", "components_stl": "drone/drone_components.stl"},
    });
    std::fs::write(dir.join("..").join("drone-frame.json"), serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    asm.write(&dir, "drone", &list, json!({"base": "drone_bottom_plate", "all_up_mass_g": up.0, "frame_file": "../drone-frame.json"}));
    eprintln!("drone: frame {:.1} g, all up {:.1} g, inertia {:?} kg m2", frame.0, up.0, si(up.2));
}
