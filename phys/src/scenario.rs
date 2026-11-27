//! Scenario loader (VIAFORM-SPEC 7.5): an `assembly.json` (`viaform-asm`, mm and degrees, world
//! frame at the home pose) plus a `viaform-scenario` file become a [`World`] with its drives,
//! objects, randomisation and wrench recording.
//!
//! Assembly to model, the same mapping as core's `asm::kin::kin_model` (phys cannot depend on
//! core): one link per component in tree order, each link frame at its parent joint's origin
//! with the world axes at the home pose. Revolute, prismatic and fixed joints keep their kind,
//! ball becomes spherical, wheel becomes continuous. The root component is fixed to the world
//! through the scenario's base pose when the assembly names a `ground`, and floats otherwise.
//! Mass per component as core's `component_inertial` without design bodies: parts (point or
//! solid box), the board mass at the proxy centre, the proxy box mass, then `mass_overrides`.
//! Proxy boxes are the collision shapes. A joint `motor` becomes an STS3215 class servo with the
//! motor's gear ratio, backlash, stall torque, no-load speed and effort limit; joints that share
//! a `tendon.actuator` become one tendon actuator (excursion in m, ratio deg/mm to rad/m).
//!
//! Scenario fields: `world` (`ground`, `table {size_m, height_m}`, `objects [{id, shape: box |
//! sphere | cylinder, size_m, mass_kg, pose, friction}]`), `base` (`{xyz, rpy_deg}`, default on
//! the table top), `gravity`, `initial {pose, q_deg}`, `drives [{joint | actuator, kind,
//! target | timeline [[t, value]]}]` (deg, mm, or mm of tendon travel), `randomise {mass_pct,
//! friction_pct, latency_ms, backlash_deg}` (numbers or `[lo, hi]` ranges, seeded by `seed`),
//! `record {bodies, every}`, `duration_s`, `rate_hz`, `control_hz`.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;
use viaform_kin::math::{Rng, pose_xyz_rpy};
use viaform_kin::model::{Actuator, Coupling, CouplingKind, Drive as KinDrive, Inertial, Joint, JointKind, Limits, Link};
use viaform_kin::{Iso3, Model as KinModel, Vec3};

use crate::actuator::{ActuatorKind, ServoParams};
use crate::error::PhysError;
use crate::model::{ModelBuilder, ShapeSpec};
use crate::record::{Recorder, WrenchHistory};
use crate::world::{Settings, World};

fn bad(msg: impl Into<String>) -> PhysError {
    PhysError::new("scenario.invalid", msg)
}

// MARK: Assembly (the fields phys reads; unknown fields are ignored)

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct Asm {
    name: String,
    ground: Option<String>,
    components: Vec<AComponent>,
    joints: Vec<AJoint>,
    mass_overrides: Vec<AOverride>,
    poses: Vec<APose>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct AComponent {
    id: String,
    parts: Vec<APart>,
    pcb: Option<APcb>,
    proxy: Option<AProxy>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct APart {
    qty: Option<u32>,
    mass_kg: Option<f64>,
    at_mm: [f64; 3],
    dims_mm: Option<[f64; 3]>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct APcb {
    mass_kg: Option<f64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct AProxy {
    min_mm: [f64; 3],
    max_mm: [f64; 3],
    mass_kg: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
struct AJoint {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    parent: String,
    child: String,
    origin: [f64; 3],
    axis: [f64; 3],
    limits: Option<ALimits>,
    motor: Option<AMotor>,
    tendon: Option<ATendon>,
    damping: f64,
    friction: f64,
}

impl Default for AJoint {
    fn default() -> Self {
        AJoint { id: String::new(), kind: "revolute".into(), parent: String::new(), child: String::new(), origin: [0.0; 3], axis: [0.0, 0.0, 1.0], limits: None, motor: None, tendon: None, damping: 0.0, friction: 0.0 }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct ALimits {
    lower_deg: Option<f64>,
    upper_deg: Option<f64>,
    lower_mm: Option<f64>,
    upper_mm: Option<f64>,
    velocity_dps: Option<f64>,
    velocity_mmps: Option<f64>,
    effort_nm: Option<f64>,
    effort_n: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
struct AMotor {
    gear_ratio: f64,
    backlash_deg: f64,
    stall_torque_nm: Option<f64>,
    no_load_speed_dps: Option<f64>,
}

impl Default for AMotor {
    fn default() -> Self {
        AMotor { gear_ratio: 1.0, backlash_deg: 0.0, stall_torque_nm: None, no_load_speed_dps: None }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct ATendon {
    actuator: String,
    ratio: f64,
    stiffness_n_per_mm: Option<f64>,
    slack_mm: f64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct AOverride {
    component: String,
    mass_kg: f64,
    center_of_mass_mm: Option<[f64; 3]>,
    inertia_kg_mm2: Option<[[f64; 3]; 3]>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct APose {
    id: String,
    q_deg: BTreeMap<String, f64>,
}

/// Mass, centre (mm) and inertia about the centre (kg mm^2), core's `Inertial`.
#[derive(Clone, Copy, Default)]
struct Mass {
    m: f64,
    c: [f64; 3],
    i: [[f64; 3]; 3],
}

fn cuboid(m: f64, c: [f64; 3], d: [f64; 3]) -> Mass {
    let k = m / 12.0;
    let mut i = [[0.0; 3]; 3];
    i[0][0] = k * (d[1] * d[1] + d[2] * d[2]);
    i[1][1] = k * (d[0] * d[0] + d[2] * d[2]);
    i[2][2] = k * (d[0] * d[0] + d[1] * d[1]);
    Mass { m, c, i }
}

fn combine(parts: &[Mass]) -> Mass {
    let m: f64 = parts.iter().map(|p| p.m).sum();
    if !(m > 0.0) {
        return Mass::default();
    }
    let mut c = [0.0; 3];
    for p in parts {
        for k in 0..3 {
            c[k] += p.c[k] * p.m / m;
        }
    }
    let mut i = [[0.0; 3]; 3];
    for p in parts {
        let d = [p.c[0] - c[0], p.c[1] - c[1], p.c[2] - c[2]];
        let dd = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
        for r in 0..3 {
            for k in 0..3 {
                i[r][k] += p.i[r][k] + p.m * (if r == k { dd } else { 0.0 } - d[r] * d[k]);
            }
        }
    }
    Mass { m, c, i }
}

fn component_mass(asm: &Asm, c: &AComponent) -> Mass {
    let mut parts = vec![];
    for p in &c.parts {
        let Some(one) = p.mass_kg else { continue };
        let m = one * f64::from(p.qty.unwrap_or(1).max(1));
        parts.push(match p.dims_mm {
            Some(d) => cuboid(m, p.at_mm, d),
            None => Mass { m, c: p.at_mm, i: [[0.0; 3]; 3] },
        });
    }
    let centre = c.proxy.as_ref().map(|p| [(p.min_mm[0] + p.max_mm[0]) / 2.0, (p.min_mm[1] + p.max_mm[1]) / 2.0, (p.min_mm[2] + p.max_mm[2]) / 2.0]);
    if let Some(m) = c.pcb.as_ref().and_then(|p| p.mass_kg) {
        parts.push(Mass { m, c: centre.unwrap_or([0.0; 3]), i: [[0.0; 3]; 3] });
    }
    if let Some(p) = &c.proxy
        && let Some(m) = p.mass_kg
    {
        let d = [p.max_mm[0] - p.min_mm[0], p.max_mm[1] - p.min_mm[1], p.max_mm[2] - p.min_mm[2]];
        parts.push(cuboid(m, centre.unwrap_or([0.0; 3]), d));
    }
    let mut total = combine(&parts);
    if let Some(o) = asm.mass_overrides.iter().find(|o| o.component == c.id) {
        let k = if total.m > 0.0 { o.mass_kg / total.m } else { 0.0 };
        total.i = total.i.map(|r| r.map(|x| x * k));
        total.m = o.mass_kg;
        if let Some(com) = o.center_of_mass_mm {
            total.c = com;
        }
        if let Some(i) = o.inertia_kg_mm2 {
            total.i = i;
        }
    }
    total
}

fn unit(v: [f64; 3]) -> Vec3 {
    let a = Vec3::from(v);
    if a.norm() > 1e-12 { a.normalize() } else { Vec3::z() }
}

/// The assembly as a phys model. Returns the builder (so a scenario can add its world) and
/// the names: links (world, then components in tree order) and assembly joint ids per kin joint.
pub struct AsmModel {
    pub builder: ModelBuilder,
    pub links: Vec<String>,
    /// Assembly joint id per kin joint (`base` for the root's joint to the world).
    pub joints: Vec<String>,
    /// Joint kind per kin joint (assembly name).
    pub kinds: Vec<String>,
    /// Home pose of each component link frame (world, SI).
    pub frames: Vec<Iso3>,
    /// Saved poses `(id, joint id -> deg or mm)`.
    pub poses: Vec<(String, BTreeMap<String, f64>)>,
    pub notes: Vec<String>,
}

/// Builds the model of an assembly with the root at `base` (world).
pub fn model_from_assembly(asm_json: &Value, base: Iso3) -> Result<AsmModel, PhysError> {
    let asm: Asm = serde_json::from_value(asm_json.clone()).map_err(|e| bad(format!("assembly: {e}")))?;
    if asm.components.is_empty() {
        return Err(bad("the assembly has no components"));
    }
    let parent_joint = |c: &str| asm.joints.iter().find(|j| j.child == c);
    // Tree order: roots first (the ground first), depth first.
    let mut roots: Vec<&AComponent> = asm.components.iter().filter(|c| parent_joint(&c.id).is_none()).collect();
    roots.sort_by_key(|c| Some(c.id.as_str()) != asm.ground.as_deref());
    if roots.len() != 1 {
        return Err(bad(format!("the assembly needs exactly one root component, it has {}", roots.len())));
    }
    let mut order: Vec<&AComponent> = vec![];
    let mut stack = vec![roots[0]];
    while let Some(c) = stack.pop() {
        if order.iter().any(|o| o.id == c.id) {
            return Err(bad(format!("component {} is reached twice (a loop)", c.id)));
        }
        order.push(c);
        let kids: Vec<&AComponent> = asm.joints.iter().filter(|j| j.parent == c.id).filter_map(|j| asm.components.iter().find(|k| k.id == j.child)).collect();
        stack.extend(kids.into_iter().rev());
    }
    if order.len() != asm.components.len() {
        return Err(bad("some components are not connected to the root"));
    }
    let mm = 1e-3;
    let frame_mm = |id: &str| parent_joint(id).map(|j| j.origin).unwrap_or([0.0; 3]);
    let mut links = vec![Link { name: "world".into(), inertial: None }];
    let mut names = vec!["world".to_string()];
    let mut joints = vec![];
    let mut joint_ids = vec![];
    let mut kinds = vec![];
    let mut notes = vec![];
    let mut frames = vec![Iso3::identity()];
    for c in &order {
        let f = frame_mm(&c.id);
        let mass = component_mass(&asm, c);
        let inertial = (mass.m > 0.0).then(|| Inertial {
            mass: mass.m,
            com: Vec3::new((mass.c[0] - f[0]) * mm, (mass.c[1] - f[1]) * mm, (mass.c[2] - f[2]) * mm),
            inertia: [mass.i[0][0] * 1e-6, mass.i[1][1] * 1e-6, mass.i[2][2] * 1e-6, mass.i[0][1] * 1e-6, mass.i[0][2] * 1e-6, mass.i[1][2] * 1e-6],
        });
        if inertial.is_none() {
            notes.push(format!("component {} has no mass (parts, proxy or override): 1 g placeholder", c.id));
        }
        links.push(Link { name: c.id.clone(), inertial });
        names.push(c.id.clone());
        frames.push(base * Iso3::translation(f[0] * mm, f[1] * mm, f[2] * mm));
    }
    // The root's joint to the world.
    let floating = asm.ground.is_none();
    joints.push(Joint { name: "base".into(), kind: if floating { JointKind::Floating } else { JointKind::Fixed }, parent: 0, origin: base, axis: Vec3::z(), limits: Limits::default() });
    joint_ids.push("base".to_string());
    kinds.push(if floating { "floating".to_string() } else { "fixed".to_string() });
    if floating {
        notes.push("the assembly names no ground: its root floats".into());
    }
    let index = |id: &str| order.iter().position(|c| c.id == id).map(|k| k + 1);
    let mut tendon_groups: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    let mut motors = vec![];
    for c in order.iter().skip(1) {
        let j = parent_joint(&c.id).expect("non-root components have a parent joint");
        let parent = index(&j.parent).ok_or_else(|| bad(format!("joint {} names unknown parent {}", j.id, j.parent)))?;
        let po = frame_mm(&j.parent);
        let kind = match j.kind.as_str() {
            "revolute" => JointKind::Revolute,
            "prismatic" => JointKind::Prismatic,
            "fixed" => JointKind::Fixed,
            "ball" => JointKind::Spherical,
            "wheel" => JointKind::Continuous,
            other => return Err(bad(format!("joint {}: unknown type {other}", j.id))),
        };
        let angular = kind != JointKind::Prismatic;
        let mut limits = Limits::default();
        if let Some(l) = &j.limits {
            let (lo, hi) = if angular { (l.lower_deg.map(f64::to_radians), l.upper_deg.map(f64::to_radians)) } else { (l.lower_mm.map(|x| x * mm), l.upper_mm.map(|x| x * mm)) };
            if kind != JointKind::Continuous {
                limits.lower = lo.unwrap_or(f64::NEG_INFINITY);
                limits.upper = hi.unwrap_or(f64::INFINITY);
            }
            if let Some(v) = if angular { l.velocity_dps.map(f64::to_radians) } else { l.velocity_mmps.map(|x| x * mm) } {
                limits.velocity = v;
            }
            if let Some(e) = if angular { l.effort_nm } else { l.effort_n } {
                limits.effort = e;
            }
        }
        let origin = Iso3::translation((j.origin[0] - po[0]) * mm, (j.origin[1] - po[1]) * mm, (j.origin[2] - po[2]) * mm);
        let ji = joints.len();
        joints.push(Joint { name: j.id.clone(), kind, parent, origin, axis: unit(j.axis), limits });
        joint_ids.push(j.id.clone());
        kinds.push(j.kind.clone());
        if let Some(t) = &j.tendon {
            tendon_groups.entry(t.actuator.clone()).or_default().push(ji);
        } else if j.motor.is_some() {
            motors.push(ji);
        }
    }
    let mut kin = KinModel { name: if asm.name.is_empty() { "assembly".into() } else { asm.name.clone() }, links, joints, actuators: vec![], couplings: vec![], end_effectors: vec![] };
    // Tendons: one actuator per shared tendon, q_j = ratio_j a (rad per m of travel).
    let mut tendon_meta = vec![];
    for (name, js) in &tendon_groups {
        let a = kin.actuators.len();
        let first = &asm.joints.iter().find(|j| j.id == kin.joints[js[0]].name).unwrap().tendon.clone().unwrap_or_default();
        let matrix: Vec<f64> = js
            .iter()
            .map(|&ji| {
                let aj = asm.joints.iter().find(|j| j.id == kin.joints[ji].name).unwrap();
                let r = aj.tendon.as_ref().map_or(0.0, |t| t.ratio);
                if kin.joints[ji].kind == JointKind::Prismatic { r } else { r.to_radians() * 1000.0 }
            })
            .collect();
        kin.actuators.push(Actuator { name: name.clone(), drive: KinDrive::Tendon, limits: Limits::default() });
        let stiffness = first.stiffness_n_per_mm.map_or(0.0, |k| k * 1000.0);
        kin.couplings.push(Coupling { name: name.clone(), kind: CouplingKind::Tendon { routing: vec![], stiffness, slack: first.slack_mm * mm }, actuators: vec![a], joints: js.clone(), matrix, offset: vec![] });
        tendon_meta.push(a);
    }
    kin.normalize()?;
    let mut builder = ModelBuilder::new(kin);
    // Joint damping and friction.
    for (ji, id) in joint_ids.iter().enumerate() {
        if let Some(j) = asm.joints.iter().find(|j| &j.id == id) {
            builder.joint_params(ji).damping = j.damping;
            builder.joint_params(ji).friction = j.friction;
        }
    }
    // Motors: servos from the motor block.
    for a in 0..builder.kin.actuators.len() {
        let name = builder.kin.actuators[a].name.clone();
        if builder.kin.actuators[a].drive == KinDrive::Tendon {
            continue;
        }
        let Some(ji) = joint_ids.iter().position(|id| *id == name) else { continue };
        let Some(m) = asm.joints.iter().find(|j| j.id == name).and_then(|j| j.motor.as_ref()) else { continue };
        if !motors.contains(&ji) {
            continue;
        }
        let mut p = ServoParams::default();
        if m.gear_ratio > 0.0 {
            p.gear_ratio = m.gear_ratio;
        }
        p.backlash = m.backlash_deg.to_radians();
        if let Some(s) = m.stall_torque_nm {
            p.stall_torque = s;
            p.max_torque = s;
        }
        if let Some(w) = m.no_load_speed_dps {
            p.no_load_speed = w.to_radians();
        }
        let effort = builder.kin.joints[ji].limits.effort;
        if effort.is_finite() {
            p.max_torque = p.max_torque.min(effort);
        }
        builder.actuator(a, ActuatorKind::Servo(p));
    }
    // Collision: the proxy boxes.
    for (k, c) in order.iter().enumerate() {
        if let Some(p) = &c.proxy {
            let f = frame_mm(&c.id);
            let size = [(p.max_mm[0] - p.min_mm[0]) * mm, (p.max_mm[1] - p.min_mm[1]) * mm, (p.max_mm[2] - p.min_mm[2]) * mm];
            if size.iter().all(|x| *x > 0.0) {
                let centre = [((p.min_mm[0] + p.max_mm[0]) / 2.0 - f[0]) * mm, ((p.min_mm[1] + p.max_mm[1]) / 2.0 - f[1]) * mm, ((p.min_mm[2] + p.max_mm[2]) / 2.0 - f[2]) * mm];
                builder.geom(k + 1, &c.id, ShapeSpec::Box { size }, pose_xyz_rpy(centre, [0.0; 3]), 0.8);
            }
        }
    }
    let poses = asm.poses.iter().map(|p| (p.id.clone(), p.q_deg.clone())).collect();
    Ok(AsmModel { builder, links: names, joints: joint_ids, kinds, frames, poses, notes })
}

// MARK: Scenario

/// A drive: actuator `actuator` follows `timeline` (time s, value SI), held between points.
#[derive(Clone, Debug)]
pub struct DriveTrack {
    pub actuator: usize,
    pub timeline: Vec<(f64, f64)>,
}

/// A loaded scenario.
pub struct Loaded {
    pub id: String,
    pub world: World,
    pub links: Vec<String>,
    pub joints: Vec<String>,
    pub actuators: Vec<String>,
    pub drives: Vec<DriveTrack>,
    pub duration: f64,
    /// Control period, s (drives are sampled at this rate).
    pub control_dt: f64,
    /// Command latency, s (sampled from the randomise block).
    pub latency: f64,
    pub objects: Vec<(String, usize)>,
    pub notes: Vec<String>,
    /// The randomised values actually used.
    pub randomised: Value,
    pending: Vec<(f64, usize, f64)>,
    next_control: f64,
}

fn num_or_range(v: Option<&Value>, rng: &mut Rng) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::Array(a) if a.len() == 2 => {
            let (lo, hi) = (a[0].as_f64()?, a[1].as_f64()?);
            Some(rng.range(lo.min(hi), lo.max(hi)))
        }
        _ => None,
    }
}

fn vec3(v: &Value) -> Option<[f64; 3]> {
    let a = v.as_array()?;
    if a.len() != 3 {
        return None;
    }
    Some([a[0].as_f64()?, a[1].as_f64()?, a[2].as_f64()?])
}

/// `random_in:[x0,x1]x[y0,y1]` (z on the surface), `{xyz, rpy_deg}` or `[x, y, z]`.
fn object_pose(v: Option<&Value>, rest_z: f64, rng: &mut Rng) -> Result<Iso3, PhysError> {
    match v {
        None => Ok(pose_xyz_rpy([0.0, 0.0, rest_z], [0.0; 3])),
        Some(Value::String(s)) => {
            let body = s.strip_prefix("random_in:").ok_or_else(|| bad(format!("object pose {s}: expected random_in:[a,b]x[c,d]")))?;
            let nums: Vec<f64> = body.split(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-' || c == 'e')).filter(|t| !t.is_empty()).map(|t| t.parse::<f64>()).collect::<Result<_, _>>().map_err(|_| bad(format!("object pose {s}: bad number")))?;
            if nums.len() != 4 {
                return Err(bad(format!("object pose {s}: expected two ranges")));
            }
            let x = rng.range(nums[0].min(nums[1]), nums[0].max(nums[1]));
            let y = rng.range(nums[2].min(nums[3]), nums[2].max(nums[3]));
            let yaw = rng.range(-std::f64::consts::PI, std::f64::consts::PI);
            Ok(pose_xyz_rpy([x, y, rest_z], [0.0, 0.0, yaw]))
        }
        Some(v @ Value::Array(_)) => Ok(pose_xyz_rpy(vec3(v).ok_or_else(|| bad("object pose: [x, y, z]"))?, [0.0; 3])),
        Some(v) => {
            let xyz = v.get("xyz").and_then(vec3).ok_or_else(|| bad("object pose: xyz"))?;
            let rpy = v.get("rpy_deg").and_then(vec3).unwrap_or([0.0; 3]);
            Ok(pose_xyz_rpy(xyz, rpy.map(f64::to_radians)))
        }
    }
}

/// Loads an assembly and a scenario into a world.
pub fn load(asm_json: &Value, sc: &Value) -> Result<Loaded, PhysError> {
    if let Some(f) = sc.get("format").and_then(Value::as_str)
        && f != "viaform-scenario"
    {
        return Err(bad(format!("format {f}: expected viaform-scenario")));
    }
    if let Some(e) = sc.get("engine").and_then(Value::as_str)
        && e != "phys"
    {
        return Err(bad(format!("engine {e}: this loader runs phys scenarios")));
    }
    let seed = sc.get("seed").and_then(Value::as_u64).unwrap_or(0);
    let mut rng = Rng::new(seed);
    let world_spec = sc.get("world").cloned().unwrap_or(Value::Null);
    let table = world_spec.get("table");
    let table_h = table.and_then(|t| t.get("height_m")).and_then(Value::as_f64).unwrap_or(0.0);
    let base = match sc.get("base") {
        Some(b) => {
            let xyz = b.get("xyz").and_then(vec3).unwrap_or([0.0, 0.0, table_h]);
            let rpy = b.get("rpy_deg").and_then(vec3).unwrap_or([0.0; 3]);
            pose_xyz_rpy(xyz, rpy.map(f64::to_radians))
        }
        None => pose_xyz_rpy([0.0, 0.0, table_h], [0.0; 3]),
    };
    let am = model_from_assembly(asm_json, base)?;
    let mut b = am.builder;
    let mut notes = am.notes;
    let rand = sc.get("randomise").cloned().unwrap_or(Value::Null);
    let mass_pct = num_or_range(rand.get("mass_pct"), &mut rng).unwrap_or(0.0);
    let friction_pct = num_or_range(rand.get("friction_pct"), &mut rng).unwrap_or(0.0);
    let latency_ms = num_or_range(rand.get("latency_ms"), &mut rng).unwrap_or(0.0);
    let backlash_deg = num_or_range(rand.get("backlash_deg"), &mut rng);
    let scale_of = |pct: f64, rng: &mut Rng| if pct > 0.0 { 1.0 + rng.range(-pct, pct) / 100.0 } else { 1.0 };
    // Masses of the assembly's links.
    for l in b.kin.links.iter_mut() {
        if let Some(i) = &mut l.inertial {
            let k = scale_of(mass_pct, &mut rng);
            i.mass *= k;
            i.inertia = i.inertia.map(|x| x * k);
        }
    }
    if let Some(bl) = backlash_deg {
        for a in b.actuators.iter_mut().flatten() {
            if let ActuatorKind::Servo(p) = a {
                p.backlash = bl.max(0.0).to_radians();
            }
        }
    }
    // The world: ground, table, objects.
    let base_friction = world_spec.get("friction").and_then(Value::as_f64).unwrap_or(0.8);
    if world_spec.get("ground").and_then(Value::as_bool).unwrap_or(true) {
        b.ground(base_friction * scale_of(friction_pct, &mut rng));
    }
    if let Some(t) = table {
        let size = t.get("size_m").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_f64).collect::<Vec<_>>()).unwrap_or_default();
        if size.len() >= 2 && table_h > 0.0 {
            let th = 0.03f64.min(table_h);
            b.geom(0, "table", ShapeSpec::Box { size: [size[0], size[1], th] }, pose_xyz_rpy([0.0, 0.0, table_h - th / 2.0], [0.0; 3]), base_friction * scale_of(friction_pct, &mut rng));
        }
    }
    let mut objects = vec![];
    for o in world_spec.get("objects").and_then(Value::as_array).cloned().unwrap_or_default() {
        let id = o.get("id").and_then(Value::as_str).unwrap_or("object").to_string();
        let shape = o.get("shape").and_then(Value::as_str).unwrap_or("box");
        let size = o.get("size_m");
        let dims = match size {
            Some(Value::Number(n)) => {
                let s = n.as_f64().unwrap_or(0.03);
                [s, s, s]
            }
            Some(v) => vec3(v).ok_or_else(|| bad(format!("object {id}: size_m is a number or [x, y, z]")))?,
            None => [0.03; 3],
        };
        let (spec, half_h) = match shape {
            "box" | "cube" => (ShapeSpec::Box { size: dims }, dims[2] / 2.0),
            "sphere" | "ball" => (ShapeSpec::Sphere { radius: dims[0] / 2.0 }, dims[0] / 2.0),
            "cylinder" => (ShapeSpec::Cylinder { length: dims[2], radius: dims[0] / 2.0 }, dims[2] / 2.0),
            other => return Err(bad(format!("object {id}: unknown shape {other}"))),
        };
        let mass = o.get("mass_kg").and_then(Value::as_f64).unwrap_or(0.02) * scale_of(mass_pct, &mut rng);
        let friction = o.get("friction").and_then(Value::as_f64).unwrap_or(base_friction) * scale_of(friction_pct, &mut rng);
        let pose = object_pose(o.get("pose"), table_h + half_h, &mut rng)?;
        let link = b.free_shape(&id, spec, mass, pose, friction)?;
        objects.push((id, link));
    }
    let model = b.build()?;
    // Settings.
    let rate = sc.get("rate_hz").and_then(Value::as_f64).unwrap_or(1000.0);
    if !(rate > 0.0) {
        return Err(bad("rate_hz must be positive"));
    }
    let mut settings = Settings { dt: 1.0 / rate, ..Settings::default() };
    if let Some(g) = sc.get("gravity").and_then(vec3) {
        settings.gravity = g;
    }
    let control_hz = sc.get("control_hz").and_then(Value::as_f64).unwrap_or(rate).clamp(1e-3, rate);
    let duration = sc.get("duration_s").and_then(Value::as_f64).unwrap_or(5.0);
    let mut world = World::new(model, settings);
    // Initial configuration: a saved pose, then q_deg on top.
    let mut q_deg: BTreeMap<String, f64> = BTreeMap::new();
    if let Some(init) = sc.get("initial") {
        if let Some(p) = init.get("pose").and_then(Value::as_str) {
            let (_, qd) = am.poses.iter().find(|(id, _)| id == p).ok_or_else(|| bad(format!("no pose {p} in the assembly")))?;
            q_deg.extend(qd.clone());
        }
        if let Some(obj) = init.get("q_deg").and_then(Value::as_object) {
            for (k, v) in obj {
                q_deg.insert(k.clone(), v.as_f64().ok_or_else(|| bad(format!("initial.q_deg.{k} must be a number")))?);
            }
        }
    }
    let mut q = world.q.clone();
    let m = world.model.clone();
    let mut balls: BTreeMap<usize, [f64; 3]> = BTreeMap::new();
    for (k, v) in &q_deg {
        let (id, comp) = match k.split_once(':') {
            Some((a, b)) => (a, Some(b)),
            None => (k.as_str(), None),
        };
        let ji = am.joints.iter().position(|j| j == id).ok_or_else(|| bad(format!("initial pose names unknown joint {id}")))?;
        let jt = &m.joints[ji];
        match (jt.kind, comp) {
            (JointKind::Spherical, Some(axis)) => {
                let e = balls.entry(ji).or_insert([0.0; 3]);
                let slot = match axis {
                    "x" => 0,
                    "y" => 1,
                    "z" => 2,
                    _ => return Err(bad(format!("{k}: ball joint components are :x, :y, :z"))),
                };
                e[slot] = v.to_radians();
            }
            (JointKind::Prismatic, None) => q[jt.qo] = v * 1e-3,
            (kind, None) if kind.is_scalar() => q[jt.qo] = v.to_radians(),
            _ => return Err(bad(format!("{k}: not a joint value this joint takes"))),
        }
    }
    for (ji, e) in balls {
        // Rz Ry Rx, as core's joint_motion.
        let r = nalgebra::UnitQuaternion::from_axis_angle(&Vec3::z_axis(), e[2]) * nalgebra::UnitQuaternion::from_axis_angle(&Vec3::y_axis(), e[1]) * nalgebra::UnitQuaternion::from_axis_angle(&Vec3::x_axis(), e[0]);
        let o = m.joints[ji].qo;
        q[o..o + 4].copy_from_slice(&[r.w, r.i, r.j, r.k]);
    }
    world.set_q(&q)?;
    // Drives.
    let actuators: Vec<String> = m.kin.actuators.iter().map(|a| a.name.clone()).collect();
    let mut drives = vec![];
    for d in sc.get("drives").and_then(Value::as_array).cloned().unwrap_or_default() {
        let name = d.get("actuator").or_else(|| d.get("joint")).and_then(Value::as_str).ok_or_else(|| bad("a drive names its actuator or joint"))?;
        let a = actuators.iter().position(|x| x == name).ok_or_else(|| bad(format!("drive: no actuator {name}")))?;
        // Units: rad for angular motors (given in deg), m for prismatic and tendons (given in mm).
        let linear = m.kin.actuators[a].drive == KinDrive::Tendon || m.actuator_map[a].as_ref().is_some_and(|map| m.joints[m.dof_joint[map.vi]].kind == JointKind::Prismatic);
        let si = |x: f64| if linear { x * 1e-3 } else { x.to_radians() };
        let mut timeline = vec![];
        if let Some(t) = d.get("target").and_then(Value::as_f64) {
            timeline.push((0.0, si(t)));
        }
        for p in d.get("timeline").and_then(Value::as_array).cloned().unwrap_or_default() {
            let pt = p.as_array().filter(|a| a.len() == 2).and_then(|a| Some((a[0].as_f64()?, a[1].as_f64()?))).ok_or_else(|| bad("timeline points are [t, value]"))?;
            timeline.push((pt.0, si(pt.1)));
        }
        timeline.sort_by(|x, y| x.0.total_cmp(&y.0));
        if let Some(kind) = d.get("kind").and_then(Value::as_str)
            && kind != "servo"
        {
            notes.push(format!("drive {name}: kind {kind} is set on the model, the drive gives its control values"));
        }
        drives.push(DriveTrack { actuator: a, timeline });
    }
    // Recording.
    let rec = sc.get("record");
    let every = rec.and_then(|r| r.get("every")).and_then(Value::as_u64).unwrap_or(1).max(1);
    let bodies: Vec<usize> = match rec.and_then(|r| r.get("bodies")).and_then(Value::as_array) {
        Some(list) => list.iter().filter_map(Value::as_str).filter_map(|n| m.kin.link_index(n)).collect(),
        None => (1..m.nlinks()).collect(),
    };
    world.recorder = Some(Recorder::new(every, bodies));
    let randomised = serde_json::json!({"seed": seed, "mass_pct": mass_pct, "friction_pct": friction_pct, "latency_ms": latency_ms, "backlash_deg": backlash_deg});
    let links = m.kin.links.iter().map(|l| l.name.clone()).collect();
    Ok(Loaded {
        id: sc.get("id").and_then(Value::as_str).unwrap_or("scenario").to_string(),
        world,
        links,
        joints: am.joints,
        actuators,
        drives,
        duration,
        control_dt: 1.0 / control_hz,
        latency: latency_ms.max(0.0) * 1e-3,
        objects,
        notes,
        randomised,
        pending: vec![],
        next_control: 0.0,
    })
}

impl Loaded {
    /// Advances to time `t_end` (or the scenario's end), sampling the drives at the control
    /// rate and applying each command `latency` later.
    pub fn advance(&mut self, t_end: f64) -> Result<(), PhysError> {
        let t_end = t_end.min(self.duration);
        let dt = self.world.settings.dt;
        while self.world.t + 0.5 * dt < t_end {
            let t = self.world.t;
            if t + 0.5 * dt >= self.next_control {
                for d in &self.drives {
                    if let Some(&(_, v)) = d.timeline.iter().rev().find(|(t0, _)| *t0 <= t + 1e-12) {
                        self.pending.push((t + self.latency, d.actuator, v));
                    }
                }
                self.next_control += self.control_dt;
            }
            let mut k = 0;
            while k < self.pending.len() {
                if self.pending[k].0 <= t + 1e-12 {
                    let (_, a, v) = self.pending.remove(k);
                    self.world.set_control(a, v);
                } else {
                    k += 1;
                }
            }
            self.world.step()?;
        }
        Ok(())
    }

    /// Runs to the end.
    pub fn run(&mut self) -> Result<(), PhysError> {
        self.advance(self.duration)
    }

    /// The recorded wrench histories (empty when nothing was recorded).
    pub fn wrench_history(&self) -> &[WrenchHistory] {
        self.world.recorder.as_ref().map_or(&[], |r| r.wrenches.as_slice())
    }
}
