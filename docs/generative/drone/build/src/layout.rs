//! Where every bought part sits, and the numbers the studies are built on.
//!
//! Assembly frame (as docs/generative/drone-3in.md section 1): origin on the motors' centroid,
//! z = 0 under the bottom plate, +x forward (camera), +y left, +z up. mm.

use std::f64::consts::{FRAC_1_SQRT_2, PI};

use serde_json::Value;
use viaform_generative::solid::Mesh;

use crate::geom::*;

/// Motor axes at (±C, ±C): 150 mm motor to motor (the spec's 140 mm does not hold the 35 mm
/// ESC, the XIAO and six ToF boards inside the 3 mm prop envelope; see README).
pub const C: f64 = 53.033;
pub const DIAGONAL: f64 = 150.0;
pub const PLATE: f64 = 4.0;
pub const FLOOR_TOP: f64 = 5.2;
/// Top of the tub's walls; the roof sits 0.4 mm higher on the standoffs (foam tape between).
pub const RIM: f64 = 31.6;
pub const ROOF0: f64 = 32.0;
pub const ROOF1: f64 = 33.2;
/// Stack centre x (a multiple of the tub's 0.6 mm voxel so walls land on voxel faces).
pub const S: f64 = -10.2;
/// Motor: F1404 dims 17.9 x 17.9 x 16.6 (shaft included); bell top where the prop hub sits.
pub const MOTOR_R: f64 = 17.9 / 2.0;
pub const MOTOR_H: f64 = 16.6;
pub const PROP_HUB_H: f64 = 5.5;
pub const BELL_H: f64 = MOTOR_H - PROP_HUB_H;
pub const PROP_R: f64 = 76.49 / 2.0;
/// Prop swept band (world z) and the 3 mm envelope the tub keeps out of.
pub const PROP_Z: [f64; 2] = [PLATE + BELL_H, PLATE + MOTOR_H];
pub const PROP_CLEAR: f64 = 3.0;
/// 9 x 9 mm M2 motor pattern (per the sim; UNCONFIRMED in drone.json).
pub const MOTOR_SQUARE: f64 = 9.0;
pub const STACK_HOLES: [[f64; 2]; 4] = [[S + 10.0, 10.0], [S + 10.0, -10.0], [S - 10.0, -10.0], [S - 10.0, 10.0]];
pub const STANDOFFS: [[f64; 2]; 4] = [[5.4, 23.1], [5.4, -23.1], [-18.5, -23.1], [-18.5, 23.1]];
pub const STANDOFF_R: f64 = 2.5;
/// Camera: lens front centre, tilt 25 deg nose up.
pub const CAM_TILT_DEG: f64 = 25.0;
pub const LENS: V3 = [23.0, 0.0, 25.0];
/// Stack-up in z.
pub const ESC_Z: [f64; 2] = [5.7, 11.2];
pub const FC_Z: [f64; 2] = [12.2, 20.0];
pub const VTX_Z: [f64; 2] = [20.8, 24.1];
pub const NUT_Z: [f64; 2] = [24.1, 26.9];
pub const XIAO_Z: [f64; 2] = [27.5, 31.0];
/// Antenna stalk (MMCX on the VTX's rear edge) and the twin roof hole for the RX antenna.
pub const ANTENNA_XY: [f64; 2] = [-23.4, 9.6];
/// Battery: rear end no further back than this (clear of the antenna and the up ToF's view);
/// the build slides it forward to balance.
pub const BATTERY_X_MIN: f64 = -20.9;
pub const BATTERY_WINDOW: f64 = 10.0;
/// Strap slots in the roof (x range) and the slot band in y.
pub const STRAP_X: [f64; 2] = [10.0, 20.0];
pub const STRAP_Y: [f64; 2] = [21.0, 22.8];

pub fn cam_axes() -> (V3, V3) {
    let t = CAM_TILT_DEG.to_radians();
    ([t.cos(), 0.0, t.sin()], [-t.sin(), 0.0, t.cos()])
}

/// Point on the camera: `p` along the lens axis from the lens front, `q` along camera up.
pub fn cam_point(p: f64, q: f64) -> V3 {
    let (a, u) = cam_axes();
    add(LENS, add(scale(a, p), scale(u, q)))
}

/// Side screw axis point (body middle, 8 mm behind the lens front).
pub fn pivot() -> V3 {
    cam_point(-8.0, 0.0)
}

/// Motor centres: M1 rear right, M2 front right, M3 rear left, M4 front left (Betaflight).
pub fn motors() -> [V3; 4] {
    [[-C, -C, 0.0], [C, -C, 0.0], [-C, C, 0.0], [C, C, 0.0]]
}
/// Spin seen from above, props in: M1 CW, M2 CCW, M3 CCW, M4 CW (+1 = CCW).
pub const SPIN: [f64; 4] = [-1.0, 1.0, 1.0, -1.0];

/// What a placed body is, for the checks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Structure,
    Electronics,
    Camera,
    Tof,
    Motor,
    Prop,
    Battery,
    Hardware,
    Antenna,
    Connector,
}

#[derive(Clone, Debug)]
pub struct Body {
    pub id: String,
    pub name: String,
    pub cref: Option<String>,
    /// Mesh in the part's own frame; `tf` places it.
    pub local: Mesh,
    pub tf: Tf,
    pub mass_g: f64,
    pub class: Class,
    pub parent: String,
    pub role: String,
    /// Mesh file stem (shared by identical instances).
    pub shape: String,
}

impl Body {
    pub fn world(&self) -> Mesh {
        transformed(&self.local, &self.tf)
    }
}

/// One line of docs/components/drone.json.
#[derive(Clone, Debug)]
pub struct Line {
    pub reference: String,
    pub qty: u64,
    pub mpn: String,
    pub manufacturer: String,
    pub category: String,
    pub description: String,
    pub dims: Vec<f64>,
    pub mass_g: f64,
}

pub fn read_components(path: &std::path::Path) -> Vec<Line> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let v: Value = serde_json::from_str(&text).unwrap();
    v["components"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| Line {
            reference: c["ref"].as_str().unwrap_or_default().into(),
            qty: c["qty"].as_u64().unwrap_or(1),
            mpn: c["mpn"].as_str().unwrap_or_default().into(),
            manufacturer: c["manufacturer"].as_str().unwrap_or_default().into(),
            category: c["category"].as_str().unwrap_or_default().into(),
            description: c["description"].as_str().unwrap_or_default().into(),
            dims: c["dims_mm"].as_array().map(|a| a.iter().filter_map(Value::as_f64).collect()).unwrap_or_default(),
            mass_g: c["mass_g"].as_f64().unwrap_or(0.0),
        })
        .collect()
}

pub fn line<'a>(list: &'a [Line], r: &str) -> &'a Line {
    list.iter().find(|l| l.reference == r).unwrap_or_else(|| panic!("{r} is not in docs/components/drone.json"))
}

/// A ToF board (Pololu 3415, 12.7 x 17.8 x 2.2): local z along the sensing direction, local y
/// along `long` (the 17.8 side), centred at `c`.
fn tof_tf(c: V3, normal: V3, long: V3) -> Tf {
    let z = unit(normal);
    let y = unit(long);
    Tf::axes(cross(y, z), y, z, c)
}

pub struct Tof {
    pub side: &'static str,
    pub tf: Tf,
    /// Window centre in the wall in front of the chip, and the wall's outward normal.
    pub window: V3,
}

pub fn tofs() -> Vec<Tof> {
    vec![
        Tof { side: "front", tf: tof_tf([24.6, 0.0, 12.05], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]), window: [27.0, 0.0, 12.05] },
        Tof { side: "rear", tf: tof_tf([-41.6, 0.0, 16.6], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]), window: [-43.8, 0.0, 16.6] },
        Tof { side: "left", tf: tof_tf([S, 17.6, 18.55], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]), window: [S, 19.8, 18.55] },
        Tof { side: "right", tf: tof_tf([S, -17.6, 18.55], [0.0, -1.0, 0.0], [1.0, 0.0, 0.0]), window: [S, -19.8, 18.55] },
        Tof { side: "up", tf: tof_tf([-33.8, 0.0, 30.5], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]), window: [-33.8, 0.0, 32.6] },
        Tof { side: "down", tf: tof_tf([15.25, 0.0, 6.8], [0.0, 0.0, -1.0], [0.0, 1.0, 0.0]), window: [15.25, 0.0, 2.6] },
    ]
}

/// Prop mesh: hub and three blades (flat, 12 deg pitch), local z up from the hub's base.
pub fn prop_mesh(spin: f64) -> Mesh {
    let mut m = cyl_mesh([0.0; 3], [0.0, 0.0, PROP_HUB_H], 3.5, 24);
    for k in 0..3 {
        let t = k as f64 * 2.0 * PI / 3.0;
        let along = [t.cos(), t.sin(), 0.0];
        let pitch = 12f64.to_radians() * spin;
        let chord = Tf::rot(along, pitch, [0.0; 3]).vector([-t.sin(), t.cos(), 0.0]);
        let c = add(scale(along, (3.0 + PROP_R) / 2.0), [0.0, 0.0, PROP_HUB_H / 2.0]);
        append(&mut m, &obox_mesh(c, along, chord, [(PROP_R - 3.0) / 2.0, 4.0, 0.6]));
    }
    m
}

pub fn motor_mesh() -> Mesh {
    let mut m = cyl_mesh([0.0; 3], [0.0, 0.0, BELL_H], MOTOR_R, 40);
    append(&mut m, &cyl_mesh([0.0, 0.0, BELL_H - 0.01], [0.0, 0.0, MOTOR_H], 0.75, 12));
    m
}

/// Button head M2 screw: head (Ø3.5 x 1.0) from z -1 to 0, shank Ø2 from 0 to `len`.
pub fn button_screw(len: f64) -> Mesh {
    let mut m = cyl_mesh([0.0, 0.0, -1.0], [0.0; 3], 1.75, 16);
    append(&mut m, &cyl_mesh([0.0, 0.0, -0.01], [0.0, 0.0, len], 1.0, 12));
    m
}

/// Every bought part, placed. `battery_x` is the pack's rear end.
pub fn components(list: &[Line], battery_x: f64) -> Vec<Body> {
    let mut out = Vec::new();
    let mut put = |id: String, name: String, r: &str, local: Mesh, tf: Tf, class: Class, parent: &str, role: &str, shape: &str| {
        let l = line(list, r);
        out.push(Body { id, name, cref: Some(r.into()), local, tf, mass_g: l.mass_g, class, parent: parent.into(), role: role.into(), shape: shape.into() });
    };
    let z = [0.0, 0.0, 1.0];
    for (k, m) in motors().iter().enumerate() {
        let n = k + 1;
        let spin = if SPIN[k] > 0.0 { "CCW" } else { "CW" };
        let motor = format!("motor_{n}");
        put(motor.clone(), format!("Motor M{n} ({spin})"), "M1", motor_mesh(), Tf::trans([m[0], m[1], PLATE]), Class::Motor, "bottom_plate", "on the arm pad, four M2 x 6 from below", "M1_F1404");
        put(format!("prop_{n}"), format!("Prop {n} ({spin})"), "P1", prop_mesh(SPIN[k]), Tf::trans([m[0], m[1], PROP_Z[0]]), Class::Prop, &motor, "on the motor's T-mount", if SPIN[k] > 0.0 { "P1_GF3016_ccw" } else { "P1_GF3016_cw" });
        for (j, (dx, dy)) in [(1.0, 1.0), (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0)].into_iter().enumerate() {
            let at = [m[0] + dx * MOTOR_SQUARE / 2.0, m[1] + dy * MOTOR_SQUARE / 2.0, 0.0];
            put(format!("motor_{n}_screw_{}", j + 1), format!("M{n} screw {}", j + 1), "SCR1", button_screw(6.0), Tf::trans(at), Class::Hardware, "bottom_plate", "M2 x 6 up through the pad into the motor (2 mm thread)", "SCR1_M2x6");
        }
    }
    // Stack: ESC (35 x 35 x 5.5) and FC (32 x 30 x 7.8) on the 20 x 20 bolts.
    let mut stack = box_mesh([S - 17.5, -17.5, ESC_Z[0]], [S + 17.5, 17.5, ESC_Z[1]]);
    append(&mut stack, &box_mesh([S - 16.0, -15.0, FC_Z[0]], [S + 16.0, 15.0, FC_Z[1]]));
    put("stack".into(), "FC + ESC stack (F405 Mini + BLS 35A)".into(), "STK1", stack, Tf::ID, Class::Electronics, "bottom_plate", "20 x 20 on four M2 x 25 bolts, grommets", "STK1_stack");
    put("vtx".into(), "Video transmitter".into(), "VTX1", box_mesh([S - 14.0, -14.0, VTX_Z[0]], [S + 14.0, 14.0, VTX_Z[1]]), Tf::ID, Class::Electronics, "bottom_plate", "top of the stack, nylock nuts", "VTX1_tank_mini");
    put("xiao".into(), "XIAO ESP32S3 companion".into(), "MCU2", box_mesh([S - 10.5, -8.9, XIAO_Z[0]], [S + 10.5, 8.9, XIAO_Z[1]]), Tf::ID, Class::Electronics, "top_plate", "foam-taped under the roof (1.0 mm tape)", "MCU2_xiao");
    put("receiver".into(), "ELRS receiver".into(), "RX1", box_mesh([-39.9, -5.5, 24.2], [-26.9, 5.5, 27.2]), Tf::ID, Class::Electronics, "electronics_tub", "on the capacitor top, 1.0 mm tape; T antenna out of the right roof hole", "RX1_rp1");
    put("capacitor".into(), "Low-ESR capacitor 470 uF 35 V".into(), "C1", cyl_mesh([-34.7, 0.0, ESC_Z[0]], [-34.7, 0.0, ESC_Z[0] + 17.5], 5.0, 24), Tf::ID, Class::Electronics, "electronics_tub", "upright in the rear bay, on the ESC battery pads", "C1_cap");
    let (a, u) = cam_axes();
    let mut cam = box_mesh([-16.0, -7.0, -7.0], [-4.0, 7.0, 7.0]);
    append(&mut cam, &cyl_mesh([-4.01, 0.0, 0.0], [0.0, 0.0, 0.0], 4.0, 24));
    put("camera".into(), "FPV camera".into(), "CAM1", cam, Tf::axes(a, [0.0, 1.0, 0.0], u, LENS), Class::Camera, "electronics_tub", "between the tub's pivot bosses, 25 deg up", "CAM1_caddx_ant");
    for t in tofs() {
        put(format!("tof_{}", t.side), format!("ToF {}", t.side), "TOF1", box_mesh([-6.35, -8.9, -1.1], [6.35, 8.9, 1.1]), t.tf, Class::Tof, if t.side == "up" { "top_plate" } else { "electronics_tub" }, "behind its window", "TOF1_vl53l1x");
    }
    // Lollipop: stalk up from the VTX's MMCX through the roof, head 22 mm on top (85 mm in all).
    let base = [ANTENNA_XY[0], ANTENNA_XY[1], VTX_Z[1]];
    let mut ant = cyl_mesh([0.0; 3], [0.0, 0.0, 63.0], 1.5, 16);
    append(&mut ant, &cyl_mesh([0.0, 0.0, 62.99], [0.0, 0.0, 85.0], 11.0, 32));
    put("vtx_antenna".into(), "Video antenna".into(), "ANT1", ant, Tf::trans(base), Class::Antenna, "vtx", "MMCX on the VTX, up through the roof", "ANT1_lollipop");
    put("xt30".into(), "XT30 pigtail".into(), "J1", box_mesh([-61.0, -5.1, 4.5], [-45.0, 5.1, 9.7]), Tf::ID, Class::Connector, "bottom_plate", "out of the rear slot; lead not drawn", "J1_xt30");
    put("battery".into(), "Battery 4S 650 mAh".into(), "B1", box_mesh([battery_x, -14.0, ROOF1], [battery_x + 59.0, 14.0, ROOF1 + 26.0]), Tf::ID, Class::Battery, "top_plate", "on the roof, strapped", "B1_gnb_650");
    // Strap: over the pack, down to the slots, under the roof strip, up round the roof's edge.
    let mut strap = box_mesh([STRAP_X[0], -14.0, ROOF1 + 26.0], [STRAP_X[1], 14.0, ROOF1 + 27.5]);
    for s in [1.0, -1.0] {
        let top = [0.0, s * 14.75, ROOF1 + 26.0];
        let bot = [0.0, s * 21.9, ROOF1];
        let mid = scale(add(top, bot), 0.5);
        let d = sub(top, bot);
        let along = unit(d);
        append(&mut strap, &obox_mesh([15.0, mid[1], mid[2]], [1.0, 0.0, 0.0], along, [5.0, norm(d) / 2.0, 0.75]));
        let (y0, y1) = if s > 0.0 { (21.0, 27.6) } else { (-27.6, -21.0) };
        append(&mut strap, &box_mesh([STRAP_X[0], y0, 30.6], [STRAP_X[1], y1, ROOF0 - 0.05]));
        let (e0, e1) = if s > 0.0 { (27.1, 28.6) } else { (-28.6, -27.1) };
        append(&mut strap, &box_mesh([STRAP_X[0], e0, 30.6], [STRAP_X[1], e1, ROOF1 + 1.0]));
    }
    put("strap".into(), "Battery strap".into(), "STR1", strap, Tf::ID, Class::Hardware, "top_plate", "through the roof slots, round the roof's edges", "STR1_strap");
    for (k, h) in STACK_HOLES.iter().enumerate() {
        let n = k + 1;
        let mut bolt = cyl_mesh([0.0; 3], [0.0, 0.0, 2.0], 1.9, 16);
        append(&mut bolt, &cyl_mesh([0.0, 0.0, 1.99], [0.0, 0.0, 27.0], 1.0, 12));
        put(format!("stack_bolt_{n}"), format!("Stack bolt {n}"), "SCR2", bolt, Tf::trans([h[0], h[1], 0.0]), Class::Hardware, "bottom_plate", "M2 x 25 socket head, head in a 2 mm counterbore under the plate", "SCR2_M2x25");
        put(format!("stack_nut_{n}"), format!("Stack nut {n}"), "NUT1", ring_mesh([0.0; 3], [0.0, 0.0, 2.8], 1.0, 2.0, 6), Tf::trans([h[0], h[1], NUT_Z[0]]), Class::Hardware, "bottom_plate", "nylock on the VTX", "NUT1_M2");
        put(format!("grommet_esc_{n}"), format!("ESC grommet {n}"), "GUM1", ring_mesh([0.0; 3], [0.0, 0.0, 6.0], 1.0, 2.5, 16), Tf::trans([h[0], h[1], FLOOR_TOP]), Class::Hardware, "bottom_plate", "soft mount under the ESC (through its hole)", "GUM1_soft");
        put(format!("grommet_fc_{n}"), format!("FC grommet {n}"), "GUM1", ring_mesh([0.0; 3], [0.0, 0.0, 6.0], 1.0, 2.5, 16), Tf::trans([h[0], h[1], ESC_Z[1]]), Class::Hardware, "bottom_plate", "soft mount between ESC and FC (through the FC's hole)", "GUM1_soft");
    }
    for (k, s) in STANDOFFS.iter().enumerate() {
        let n = k + 1;
        put(format!("standoff_{n}_screw_bottom"), format!("Standoff {n} bottom screw"), "SCR1", button_screw(6.0), Tf::trans([s[0], s[1], 0.0]), Class::Hardware, "bottom_plate", "M2 x 6 up into the standoff", "SCR1_M2x6");
        put(format!("standoff_{n}_screw_top"), format!("Standoff {n} top screw"), "SCR1", button_screw(6.0), Tf::rot([1.0, 0.0, 0.0], PI, [s[0], s[1], ROOF1]), Class::Hardware, "top_plate", "M2 x 6 down through the roof into the standoff", "SCR1_M2x6");
    }
    let p = pivot();
    for (s, side) in [(1.0, "left"), (-1.0, "right")] {
        // Head in the boss's counterbore (bottom face at |y| 8.8), shank 3 mm into the camera.
        let tf = Tf::axes([1.0, 0.0, 0.0], [0.0, 0.0, s], [0.0, -s, 0.0], [p[0], s * 8.8, p[2]]);
        let _ = FRAC_1_SQRT_2;
        put(format!("camera_screw_{side}"), format!("Camera screw {side}"), "SCR3", button_screw(3.0), tf, Class::Hardware, "electronics_tub", "M2 x 3 through the pivot boss into the camera's side", "SCR3_M2x3");
    }
    let _ = z;
    out
}
