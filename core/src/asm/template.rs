//! The arm template: a six-joint desktop arm on Feetech STS3215 bus servos (the SO-100 class of
//! arm), standing straight up at the home pose. Each link carries a printed-part proxy box and
//! the servo housed in it, whose mass comes from the BOM line `arm:M1`.

use serde_json::{Value, json};

use super::model::{Assembly, Component, Joint, JointType, Limits, MotionStudy, Motor, PartRef, Pose, Proxy};

pub const SERVO: &str = "lib:feetech/STS3215";
pub const SERVO_LINE: &str = "arm:M1";
/// STS3215 (12 V, 1:345): 30 kg·cm stall, 0.222 s per 60 degrees, 55 g, 45.2 x 24.7 x 35 mm.
pub const SERVO_STALL_NM: f64 = 2.94;
pub const SERVO_SPEED_DPS: f64 = 270.0;
pub const SERVO_MASS_G: f64 = 55.0;
pub const SERVO_DIMS_MM: [f64; 3] = [45.2, 24.7, 35.0];

fn link(id: &str, name: &str, min: [f64; 3], max: [f64; 3], mass: f64, servo_at: Option<[f64; 3]>) -> Component {
    Component {
        id: id.into(),
        name: name.into(),
        bodies: Vec::new(),
        parts: servo_at
            .map(|at| PartRef { part: SERVO.into(), bom_line: Some(SERVO_LINE.into()), qty: 1, mass_kg: None, at_mm: at, dims_mm: Some(SERVO_DIMS_MM) })
            .into_iter()
            .collect(),
        pcb: None,
        proxy: Some(Proxy { min_mm: min, max_mm: max, mass_kg: Some(mass) }),
    }
}

fn joint(id: &str, parent: &str, child: &str, origin: [f64; 3], axis: [f64; 3], lo: f64, hi: f64, bus: u32) -> Joint {
    Joint {
        id: id.into(),
        kind: JointType::Revolute,
        parent: parent.into(),
        child: child.into(),
        origin,
        axis,
        limits: Some(Limits { lower_deg: Some(lo), upper_deg: Some(hi), velocity_dps: Some(SERVO_SPEED_DPS), effort_nm: Some(SERVO_STALL_NM), ..Limits::default() }),
        motor: Some(Motor {
            part: SERVO.into(),
            bom_line: Some(SERVO_LINE.into()),
            gear_ratio: 345.0,
            backlash_deg: 0.3,
            bus_id: Some(bus),
            stall_torque_nm: Some(SERVO_STALL_NM),
            no_load_speed_dps: Some(SERVO_SPEED_DPS),
            voltage_v: Some(12.0),
            kp: Some(20.0),
        }),
        tendon: None,
        damping: 0.02,
        friction: 0.05,
        cad_joint: None,
    }
}

/// The template arm: base, shoulder, upper arm, forearm, wrist, gripper and jaw, joined by
/// shoulder pan, shoulder lift, elbow, wrist pitch, wrist roll and gripper.
pub fn arm() -> Assembly {
    let y = [0.0, 1.0, 0.0];
    let z = [0.0, 0.0, 1.0];
    Assembly {
        name: "arm".into(),
        ground: Some("base".into()),
        components: vec![
            link("base", "Base", [-50.0, -50.0, 0.0], [50.0, 50.0, 40.0], 0.25, Some([0.0, 0.0, 20.0])),
            link("shoulder", "Shoulder", [-25.0, -25.0, 40.0], [25.0, 25.0, 90.0], 0.06, Some([0.0, 0.0, 70.0])),
            link("upper_arm", "Upper arm", [-15.0, -20.0, 90.0], [15.0, 20.0, 188.0], 0.05, Some([0.0, 0.0, 165.0])),
            link("forearm", "Forearm", [-15.0, -15.0, 188.0], [15.0, 15.0, 288.0], 0.04, Some([0.0, 0.0, 265.0])),
            link("wrist", "Wrist", [-12.0, -15.0, 288.0], [12.0, 15.0, 328.0], 0.03, Some([0.0, 0.0, 308.0])),
            link("gripper", "Gripper", [-20.0, -15.0, 328.0], [20.0, 15.0, 378.0], 0.035, Some([0.0, 0.0, 350.0])),
            link("jaw", "Moving jaw", [5.0, -10.0, 378.0], [20.0, 10.0, 420.0], 0.012, None),
        ],
        joints: vec![
            joint("shoulder_pan", "base", "shoulder", [0.0, 0.0, 40.0], z, -110.0, 110.0, 1),
            joint("shoulder_lift", "shoulder", "upper_arm", [0.0, 0.0, 90.0], y, -100.0, 100.0, 2),
            joint("elbow", "upper_arm", "forearm", [0.0, 0.0, 188.0], y, -10.0, 135.0, 3),
            joint("wrist_pitch", "forearm", "wrist", [0.0, 0.0, 288.0], y, -100.0, 100.0, 4),
            joint("wrist_roll", "wrist", "gripper", [0.0, 0.0, 328.0], z, -160.0, 160.0, 5),
            joint("gripper", "gripper", "jaw", [12.0, 0.0, 378.0], y, -10.0, 100.0, 6),
        ],
        motion_studies: vec![MotionStudy { id: "elbow_sweep".into(), joint: "elbow".into(), from: None, to: None, steps: 24, pose: Some("home".into()), duration_s: Some(2.0) }],
        poses: vec![
            Pose { id: "home".into(), q_deg: Default::default() },
            Pose {
                id: "ready".into(),
                q_deg: [("shoulder_pan", 0.0), ("shoulder_lift", -30.0), ("elbow", 90.0), ("wrist_pitch", -60.0), ("wrist_roll", 0.0), ("gripper", 0.0)]
                    .into_iter()
                    .map(|(k, v)| (k.to_owned(), v))
                    .collect(),
            },
        ],
        ..Assembly::default()
    }
}

/// The arm's bill of materials (`bom.json`, viaform-bom v1): six STS3215 servos, the bus servo
/// adapter, the 12 V supply, servo cables and screws. Printed parts come from the design.
pub fn arm_bom() -> Value {
    let line = |id: &str, reference: &str, qty: u32, category: &str, mpn: &str, maker: &str, desc: &str, mass_g: f64, extra: Value| {
        let mut l = json!({
            "id": id, "origin": "arm", "reference": reference, "qty": qty, "category": category,
            "mpn": mpn, "manufacturer": maker, "description": desc, "mass_g": mass_g, "subassembly": "Arm",
        });
        if let Value::Object(m) = extra {
            for (k, v) in m {
                l[k] = v;
            }
        }
        l
    };
    json!({
        "format": "viaform-bom", "version": 1, "name": "Arm", "builds": 1, "currency": "USD",
        "lines": [
            line(SERVO_LINE, "M1", 6, "Servo", "STS3215", "Feetech", "Serial bus servo, 12 V, 1:345, magnetic encoder 4096 steps", SERVO_MASS_G,
                json!({"dims_mm": SERVO_DIMS_MM, "key_specs": {"stall_torque_kgcm": 30, "voltage_v": 12, "gear_ratio": "1:345", "speed_s_per_60deg": 0.222, "bus": "TTL half duplex, 1 Mbps"}})),
            line("arm:U1", "U1", 1, "Controller", "FE-URT-1", "Feetech", "USB to serial bus servo adapter", 8.0, json!({})),
            line("arm:PS1", "PS1", 1, "Power", "12V5A", "Generic", "12 V 5 A power supply, 5.5 x 2.1 mm barrel", 250.0, json!({})),
            line("arm:W1", "W1", 6, "Cable", "STS-3P-150", "Feetech", "3-pin servo bus cable, 150 mm", 3.0, json!({})),
            line("arm:H1", "H1", 48, "Hardware", "M2x6-ST", "Generic", "M2 x 6 self-tapping screw (servo horns and covers)", 0.25, json!({})),
            line("arm:H2", "H2", 4, "Hardware", "M3x12-ISO4762", "Generic", "M3 x 12 socket head screw (base to table clamp)", 1.1, json!({})),
        ],
    })
}
