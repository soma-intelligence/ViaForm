//! A drone built from a generated frame: the file the generative design writes
//! (docs/generative/drone-frame.json) gives the frame's mass, inertia, arm length and motor mounts;
//! the rest of the drone is the parts list (parts.rs). Without the file the nominal quad flies.
//!
//! The all-up inertia is the nominal quad's with the nominal frame taken out (its inertia is
//! computed from the frame study's geometry below) and the motors and props moved out to the new
//! arm (point masses on an X); the generated frame's own inertia from the file goes in instead.
//! Without inertia in the file, the nominal frame's is scaled by mass and arm squared.

use serde::Deserialize;
use serde_json::{Value, json};

use crate::flight::quad3;
use crate::parts::{PARTS, parts_mass_kg};
use crate::physics::QuadParams;

pub const NOMINAL_INERTIA: [f64; 3] = [1.9e-4, 2.1e-4, 3.5e-4];
pub const NOMINAL_ARM: f64 = 0.0602;

/// The nominal frame's inertia (kg·m², about its centre), from the frame study's geometry
/// (generative.ts at safety factor 1.5): a 27 mm square centre plate, four 8 mm motor pads and per
/// arm three members along the diagonal, all 3 mm carbon at 1.6 g/cm³. The parts add up to its
/// 11.03 g; the result is scaled to `FRAME.mass_g` exactly.
pub fn nominal_frame_inertia() -> [f64; 3] {
    const T: f64 = 3.0; // mm
    const RHO: f64 = 1.6e-3; // g/mm³
    // Diagonal stations (mm along x = y) and widths of the three member classes.
    const MEMBERS: [(f64, f64, f64); 3] = [(12.42, 19.153, 5.733), (19.153, 30.645, 4.817), (30.645, 42.562, 3.462)];
    let (plate, pad_r) = (27.0, 8.0);
    let mut m_total = 0.0;
    let mut i = [0.0f64; 3]; // g·mm²
    let mp = plate * plate * T * RHO;
    m_total += mp;
    i[0] += mp * plate * plate / 12.0;
    i[1] += mp * plate * plate / 12.0;
    i[2] += mp * plate * plate / 6.0;
    let pad = 42.562f64;
    for (sx, sy) in [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] {
        let m = std::f64::consts::PI * pad_r * pad_r * T * RHO;
        m_total += m;
        i[0] += m * (pad_r * pad_r / 4.0 + pad * pad);
        i[1] += m * (pad_r * pad_r / 4.0 + pad * pad);
        i[2] += m * (pad_r * pad_r / 2.0 + 2.0 * pad * pad);
        for (a, b, w) in MEMBERS {
            let len = (b - a) * std::f64::consts::SQRT_2;
            let m = len * w * T * RHO;
            m_total += m;
            let (p, q) = ([a * sx, a * sy], [b * sx, b * sy]);
            // A thin rod from p to q: integral of x² (and y²) along it.
            let sq = |u: f64, v: f64| m * (u * u + u * v + v * v) / 3.0;
            let (ix, iy) = (sq(p[1], q[1]), sq(p[0], q[0]));
            i[0] += ix;
            i[1] += iy;
            i[2] += ix + iy;
        }
    }
    let scale = crate::frame::FRAME.mass_g / m_total * 1e-9; // g·mm² to kg·m²
    i.map(|x| x * scale)
}

#[derive(Deserialize, Debug, Clone)]
pub struct FrameFile {
    #[serde(alias = "massG", alias = "frame_mass_g")]
    pub mass_g: f64,
    #[serde(default, alias = "inertiaKgM2", alias = "inertia")]
    pub inertia_kg_m2: Option<[f64; 3]>,
    #[serde(default, alias = "armLengthMm", alias = "arm_mm", alias = "armMm")]
    pub arm_length_mm: Option<f64>,
    /// The whole drone's mass when the file knows it better than the parts list.
    #[serde(default, alias = "allUpMassG")]
    pub all_up_mass_g: Option<f64>,
    /// Motor mount centres (mm, frame axes): `[[x, y, z], ...]` or `[{"x":..,"y":..}, ...]`.
    #[serde(default, alias = "motorMounts")]
    pub motor_mounts: Option<Value>,
    #[serde(default)]
    pub name: Option<String>,
}

/// The mean distance of the motor mounts from the centre (mm), when there are any.
fn mount_radius(v: &Value) -> Option<f64> {
    let pts: Vec<(f64, f64)> = v
        .as_array()?
        .iter()
        .filter_map(|m| match m {
            Value::Array(a) if a.len() >= 2 => Some((a[0].as_f64()?, a[1].as_f64()?)),
            Value::Object(o) => {
                let o = o.get("position").or(o.get("center")).and_then(Value::as_object).unwrap_or(o);
                Some((o.get("x")?.as_f64()?, o.get("y")?.as_f64()?))
            }
            _ => None,
        })
        .collect();
    (!pts.is_empty()).then(|| pts.iter().map(|(x, y)| x.hypot(*y)).sum::<f64>() / pts.len() as f64)
}

/// The drone as the simulation flies it, and what it was built from.
#[derive(Debug, Clone)]
pub struct Airframe {
    pub params: QuadParams,
    pub frame_g: f64,
    pub arm_mm: f64,
    pub name: String,
    /// The frame's own inertia (kg·m², about its centre): the file's, or the estimate.
    pub frame_inertia: [f64; 3],
}

impl Airframe {
    pub fn from_json(text: &str) -> Result<Airframe, String> {
        let f: FrameFile = serde_json::from_str(text).map_err(|e| format!("drone-frame.json: {e}"))?;
        let arm_mm = f.arm_length_mm.or_else(|| f.motor_mounts.as_ref().and_then(mount_radius)).ok_or("drone-frame.json: no arm_length_mm and no motor_mounts")?;
        let ok = |x: f64, lo: f64, hi: f64| x.is_finite() && x > lo && x < hi;
        if !ok(f.mass_g, 0.0, 500.0) {
            return Err(format!("drone-frame.json: frame mass {} g is out of range", f.mass_g));
        }
        if !ok(arm_mm, 20.0, 250.0) {
            return Err(format!("drone-frame.json: arm {arm_mm} mm is out of range"));
        }
        let mass = match f.all_up_mass_g {
            Some(g) if ok(g, f.mass_g, 2000.0) => g / 1000.0,
            Some(g) => return Err(format!("drone-frame.json: all-up mass {g} g is out of range")),
            None => parts_mass_kg(f.mass_g),
        };
        let nominal_frame = nominal_frame_inertia();
        let frame_i = match f.inertia_kg_m2 {
            Some(i) if i.iter().all(|x| x.is_finite() && *x >= 0.0 && *x <= 0.05) => i,
            Some(_) => return Err("drone-frame.json: inertia out of range".into()),
            // Not in the file: the nominal frame's, scaled by mass and by arm squared.
            None => {
                let k = f.mass_g / crate::frame::FRAME.mass_g * (arm_mm / crate::frame::FRAME.arm).powi(2);
                nominal_frame.map(|x| x * k)
            }
        };
        let motor_kg: f64 = PARTS.iter().filter(|p| p.role == "Motors" || p.role == "Propellers").map(|p| p.qty as f64 * p.mass_g).sum::<f64>() / 1000.0;
        let arm = arm_mm / 1000.0;
        // Four point masses on an X: half the polar moment about each horizontal axis.
        let motors = |a: f64| [0.5 * motor_kg * a * a, 0.5 * motor_kg * a * a, motor_kg * a * a];
        let (m0, m1) = (motors(NOMINAL_ARM), motors(arm));
        // The nominal quad less its motors and frame (battery, stack and the rest), then the new ones.
        let inertia = std::array::from_fn(|i| (NOMINAL_INERTIA[i] - m0[i] - nominal_frame[i]).max(0.0) + m1[i] + frame_i[i]);
        Ok(Airframe { params: quad3(mass, inertia, arm), frame_g: f.mass_g, arm_mm, frame_inertia: frame_i, name: f.name.unwrap_or_else(|| "Generated frame".into()) })
    }

    pub fn summary(&self) -> Value {
        json!({
            "name": self.name, "frameG": self.frame_g, "armMm": self.arm_mm, "massKg": self.params.mass,
            "inertia": self.params.inertia, "thrustToWeight": 4.0 * crate::parts::MOTOR_THRUST_3S_N / (self.params.mass * 9.81),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_nominal_frame_is_a_small_part_of_the_nominal_inertia() {
        let f = nominal_frame_inertia();
        assert!(f.iter().zip(NOMINAL_INERTIA).all(|(a, b)| *a > 0.0 && *a < 0.4 * b), "{f:?}");
        assert!((f[2] - f[0] - f[1]).abs() < 0.05 * f[2], "thin plate: Iz = Ix + Iy, {f:?}");
    }

    #[test]
    fn the_nominal_frame_from_the_file_gives_the_nominal_inertia_back() {
        let i = nominal_frame_inertia();
        let text = format!(
            r#"{{"mass_g":{},"arm_length_mm":60.2,"inertia_kg_m2":[{},{},{}],"all_up_mass_g":175}}"#,
            crate::frame::FRAME.mass_g, i[0], i[1], i[2]
        );
        let a = Airframe::from_json(&text).unwrap();
        for k in 0..3 {
            assert!((a.params.inertia[k] - NOMINAL_INERTIA[k]).abs() < 1e-9, "{:?}", a.params.inertia);
        }
    }
}
