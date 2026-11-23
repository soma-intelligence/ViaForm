//! `assembly.json` (`viaform-asm` v1): the physical model of a product. Components (design
//! bodies, bought parts from the library and the BOM, the linked PCB), the joints between them
//! with their limits and drives (a servo and its motor, or a tendon), the ground, mass
//! overrides, motion studies and the saved poses, grasps and paths.
//!
//! Units: lengths in mm in the design's world frame at the home pose (every joint value 0),
//! angles in degrees, masses in kg, torques in N·m, forces in N. Exports convert to SI.
//!
//! Joint origins and axes are given in the world frame at the home pose, the way the design
//! shows them, so a joint is placed by picking a point and a direction in the viewport. The
//! kinematic frames the exports need are derived from them.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::math::{V3, unit};

pub const FORMAT: &str = "viaform-asm";
pub const VERSION: u64 = 1;
pub const ENTRY: &str = "assembly.json";

fn format() -> String {
    FORMAT.into()
}

fn version() -> u64 {
    VERSION
}

fn one() -> u32 {
    1
}

fn is_zero(x: &f64) -> bool {
    *x == 0.0
}

fn z_axis() -> V3 {
    [0.0, 0.0, 1.0]
}

/// The whole document.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Assembly {
    #[serde(default = "format")]
    pub format: String,
    #[serde(default = "version")]
    pub version: u64,
    #[serde(default)]
    pub name: String,
    /// The component fixed to the world. Without one, the root of the tree floats (a drone, a
    /// mobile base).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ground: Option<String>,
    #[serde(default)]
    pub components: Vec<Component>,
    #[serde(default)]
    pub joints: Vec<Joint>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub mass_overrides: Vec<MassOverride>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub motion_studies: Vec<MotionStudy>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub poses: Vec<Pose>,
    /// Saved hand grasps (VIAFORM-SPEC 7.10.5), kept as written by `save_grasp`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub grasps: Vec<Value>,
    /// Saved waypoint paths (VIAFORM-SPEC 7.10.6), kept as written by `save_path`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub paths: Vec<Value>,
    /// Fields a newer ViaForm wrote: kept as they are (R-9).
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Default for Assembly {
    fn default() -> Self {
        Self {
            format: format(),
            version: VERSION,
            name: String::new(),
            ground: None,
            components: Vec::new(),
            joints: Vec::new(),
            mass_overrides: Vec::new(),
            motion_studies: Vec::new(),
            poses: Vec::new(),
            grasps: Vec::new(),
            paths: Vec::new(),
            extra: BTreeMap::new(),
        }
    }
}

/// One rigid link of the mechanism.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Component {
    pub id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
    /// Design bodies that move with this component (SolidCraft body names).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub bodies: Vec<String>,
    /// Bought parts carried by this component (a servo, a bearing, a battery).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub parts: Vec<PartRef>,
    /// The linked board, when this component carries it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pcb: Option<PcbLink>,
    /// A stand-in box for collisions and mass when no design geometry is at hand (templates,
    /// imported URDF and MJCF).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<Proxy>,
}

/// A bought part placed on a component, from the library (`lib:feetech/STS3215`) and the BOM.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PartRef {
    pub part: String,
    /// The BOM line it counts (`bom.json` line id): its `mass_g` is used when `mass_kg` is not set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bom_line: Option<String>,
    #[serde(default = "one")]
    pub qty: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mass_kg: Option<f64>,
    /// Where its centre sits at the home pose (mm, world).
    #[serde(default)]
    pub at_mm: V3,
    /// Its size, for a box inertia; a point mass without it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dims_mm: Option<V3>,
}

/// The board from the electronics, as the link places it in the design (`pcb-N`, N the PCB
/// revision the 3D board was built from).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PcbLink {
    /// The design component holding the board (`PCB Board`).
    pub component: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    /// The board's mass when the design has no bodies for it yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mass_kg: Option<f64>,
}

impl PcbLink {
    /// `pcb-12`, as the design component's revision field reads.
    pub fn tag(&self) -> Option<String> {
        self.revision.map(|r| format!("pcb-{r}"))
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Proxy {
    pub min_mm: V3,
    pub max_mm: V3,
    /// The mass the box stands for (kg); with none, it only collides.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mass_kg: Option<f64>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum JointType {
    #[default]
    Revolute,
    Prismatic,
    Fixed,
    Ball,
    /// A revolute joint without limits (a driven wheel).
    Wheel,
}

impl JointType {
    pub fn name(self) -> &'static str {
        match self {
            JointType::Revolute => "revolute",
            JointType::Prismatic => "prismatic",
            JointType::Fixed => "fixed",
            JointType::Ball => "ball",
            JointType::Wheel => "wheel",
        }
    }

    /// How many joint values it takes.
    pub fn dof(self) -> usize {
        match self {
            JointType::Fixed => 0,
            JointType::Ball => 3,
            _ => 1,
        }
    }

    pub fn angular(self) -> bool {
        !matches!(self, JointType::Prismatic)
    }
}

/// Joint limits. Angular joints use the `_deg`, `_dps` and `_nm` fields, prismatic joints the
/// `_mm`, `_mmps` and `_n` fields.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Limits {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lower_deg: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upper_deg: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lower_mm: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upper_mm: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub velocity_dps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub velocity_mmps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort_nm: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort_n: Option<f64>,
}

/// A servo driving the joint, with what the motor can do.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Motor {
    /// The library part (`lib:feetech/STS3215`).
    pub part: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bom_line: Option<String>,
    #[serde(default = "unit_ratio")]
    pub gear_ratio: f64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub backlash_deg: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bus_id: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stall_torque_nm: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub no_load_speed_dps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voltage_v: Option<f64>,
    /// Position gain of the servo loop (N·m per rad).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kp: Option<f64>,
}

fn unit_ratio() -> f64 {
    1.0
}

/// A tendon pulling the joint: the actuator's travel maps to the joint value through `ratio`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Tendon {
    /// The actuator id it shares with other joints (one tendon can drive several joints).
    pub actuator: String,
    /// Joint degrees per mm of tendon travel.
    pub ratio: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stiffness_n_per_mm: Option<f64>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub slack_mm: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Joint {
    pub id: String,
    #[serde(rename = "type", default)]
    pub kind: JointType,
    pub parent: String,
    pub child: String,
    /// The joint's point at the home pose (mm, world).
    #[serde(default)]
    pub origin: V3,
    /// Its axis at the home pose (world); the slide direction of a prismatic joint.
    #[serde(default = "z_axis")]
    pub axis: V3,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limits: Option<Limits>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motor: Option<Motor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tendon: Option<Tendon>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub damping: f64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub friction: f64,
    /// The SolidCraft joint this one mates to (its name in the design).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cad_joint: Option<String>,
}

impl Joint {
    /// The drive, as the inspector badge says it: `servo`, `tendon` or `none`.
    pub fn drive(&self) -> &'static str {
        match (&self.motor, &self.tendon) {
            (Some(_), _) => "servo",
            (None, Some(_)) => "tendon",
            _ => "none",
        }
    }

    /// The range in the joint's own unit (deg or mm); None when it is not limited.
    pub fn range(&self) -> Option<(f64, f64)> {
        let l = self.limits.as_ref()?;
        match self.kind {
            JointType::Revolute => Some((l.lower_deg?, l.upper_deg?)),
            JointType::Prismatic => Some((l.lower_mm?, l.upper_mm?)),
            _ => None,
        }
    }

    pub fn clamp(&self, v: f64) -> f64 {
        match self.range() {
            Some((lo, hi)) => v.clamp(lo, hi),
            None => v,
        }
    }

    /// Effort limit in the joint's unit (N·m or N).
    pub fn effort(&self) -> Option<f64> {
        let l = self.limits.as_ref()?;
        if self.kind.angular() { l.effort_nm } else { l.effort_n }
    }

    /// Velocity limit in the joint's unit per second (deg/s or mm/s).
    pub fn velocity(&self) -> Option<f64> {
        let l = self.limits.as_ref()?;
        if self.kind.angular() { l.velocity_dps } else { l.velocity_mmps }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MassOverride {
    pub component: String,
    pub mass_kg: f64,
    /// Keep the measured centre when not set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub center_of_mass_mm: Option<V3>,
    /// The inertia about the centre of mass (kg·mm², world axes at the home pose); the
    /// measured tensor scaled to `mass_kg` when not set. Imports from URDF and MJCF set it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inertia_kg_mm2: Option<[[f64; 3]; 3]>,
}

/// Sweep one joint over its range (or `from`..`to`) in `steps` steps, the others held at `pose`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MotionStudy {
    pub id: String,
    pub joint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<f64>,
    #[serde(default = "steps")]
    pub steps: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pose: Option<String>,
    /// How long the sweep takes (s), to give contacts a time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_s: Option<f64>,
}

fn steps() -> u32 {
    24
}

/// A named joint configuration. Values are degrees, or mm for prismatic joints; a ball joint
/// takes `<id>:x`, `<id>:y`, `<id>:z` (degrees, applied X then Y then Z).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Pose {
    pub id: String,
    #[serde(default)]
    pub q_deg: BTreeMap<String, f64>,
}

impl Assembly {
    pub fn component(&self, id: &str) -> Option<&Component> {
        self.components.iter().find(|c| c.id == id)
    }

    pub fn joint(&self, id: &str) -> Option<&Joint> {
        self.joints.iter().find(|j| j.id == id)
    }

    pub fn joint_mut(&mut self, id: &str) -> Option<&mut Joint> {
        self.joints.iter_mut().find(|j| j.id == id)
    }

    pub fn pose(&self, id: &str) -> Option<&Pose> {
        self.poses.iter().find(|p| p.id == id)
    }

    /// The joint that places `component` (it is that joint's child).
    pub fn parent_joint(&self, component: &str) -> Option<&Joint> {
        self.joints.iter().find(|j| j.child == component)
    }

    /// Movable degrees of freedom.
    pub fn dof(&self) -> usize {
        self.joints.iter().map(|j| j.kind.dof()).sum()
    }

    /// Components in tree order: each after its parent, roots first (ground first).
    pub fn tree_order(&self) -> Vec<&Component> {
        let mut out: Vec<&Component> = Vec::new();
        let mut placed = BTreeSet::new();
        let mut roots: Vec<&Component> = self.components.iter().filter(|c| self.parent_joint(&c.id).is_none()).collect();
        roots.sort_by_key(|c| Some(c.id.as_str()) != self.ground.as_deref());
        let mut stack: Vec<&Component> = roots.into_iter().rev().collect();
        while let Some(c) = stack.pop() {
            if !placed.insert(c.id.as_str()) {
                continue;
            }
            out.push(c);
            let kids: Vec<&Component> =
                self.joints.iter().filter(|j| j.parent == c.id).filter_map(|j| self.component(&j.child)).collect();
            stack.extend(kids.into_iter().rev());
        }
        out
    }

    /// Refuses a model the exports and the kinematics cannot take: duplicate ids, joints on
    /// unknown components, a component placed by two joints, loops, a zero axis, an inverted
    /// range, a grounded component with a parent joint.
    pub fn validate(&self) -> Result<(), String> {
        if self.format != FORMAT {
            return Err(format!("not an assembly ({})", self.format));
        }
        let mut ids = BTreeSet::new();
        for c in &self.components {
            if c.id.trim().is_empty() {
                return Err("a component has no id".into());
            }
            if !ids.insert(c.id.as_str()) {
                return Err(format!("component {} is listed twice", c.id));
            }
            if let Some(p) = &c.proxy
                && (0..3).any(|i| p.max_mm[i] < p.min_mm[i])
            {
                return Err(format!("{}: the proxy box is inside out", c.id));
            }
        }
        let mut jids = BTreeSet::new();
        let mut children = BTreeSet::new();
        for j in &self.joints {
            if j.id.trim().is_empty() {
                return Err("a joint has no id".into());
            }
            if !jids.insert(j.id.as_str()) {
                return Err(format!("joint {} is listed twice", j.id));
            }
            for side in [&j.parent, &j.child] {
                if !ids.contains(side.as_str()) {
                    return Err(format!("joint {} uses unknown component {side}", j.id));
                }
            }
            if j.parent == j.child {
                return Err(format!("joint {} joins {} to itself", j.id, j.child));
            }
            if !children.insert(j.child.as_str()) {
                return Err(format!("{} is placed by two joints; a closed loop is a driving joint plus a coupling", j.child));
            }
            if j.kind.dof() == 1 && unit(j.axis).is_none() {
                return Err(format!("joint {} has no axis", j.id));
            }
            if let Some((lo, hi)) = j.range()
                && !(lo <= hi)
            {
                return Err(format!("joint {}: the lower limit {lo} is above the upper {hi}", j.id));
            }
            if let Some(m) = &j.motor
                && !(m.gear_ratio > 0.0)
            {
                return Err(format!("joint {}: the gear ratio must be positive", j.id));
            }
        }
        if let Some(g) = &self.ground {
            if !ids.contains(g.as_str()) {
                return Err(format!("the ground {g} is not a component"));
            }
            if children.contains(g.as_str()) {
                return Err(format!("the ground {g} cannot be placed by a joint"));
            }
        }
        // Each component has at most one parent, so a loop is a chain that never reaches a root.
        for c in &self.components {
            let mut at = c.id.as_str();
            let mut steps = 0;
            while let Some(j) = self.parent_joint(at) {
                at = j.parent.as_str();
                steps += 1;
                if steps > self.joints.len() {
                    return Err(format!("the joints around {} form a loop", c.id));
                }
            }
        }
        for o in &self.mass_overrides {
            if !ids.contains(o.component.as_str()) {
                return Err(format!("mass override on unknown component {}", o.component));
            }
            if !(o.mass_kg >= 0.0) {
                return Err(format!("{}: mass must not be negative", o.component));
            }
        }
        for s in &self.motion_studies {
            if self.joint(&s.joint).is_none() {
                return Err(format!("motion study {} sweeps unknown joint {}", s.id, s.joint));
            }
        }
        Ok(())
    }

    /// Reads a document; a newer format is refused rather than half read.
    pub fn from_json(v: &Value) -> Result<Self, String> {
        if v.get("format").and_then(Value::as_str) != Some(FORMAT) {
            return Err("not a ViaForm assembly".into());
        }
        let version = v.get("version").and_then(Value::as_u64).unwrap_or(0);
        if version > VERSION {
            return Err(format!("this assembly was saved by a newer ViaForm (format {version}); update ViaForm to open it"));
        }
        let a: Assembly = serde_json::from_value(v.clone()).map_err(|e| format!("assembly.json: {e}"))?;
        a.validate()?;
        Ok(a)
    }

    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    /// A stable fingerprint of the content (FNV-1a over the canonical JSON), so saving the same
    /// assembly twice is one revision.
    pub fn fingerprint(&self) -> String {
        let text = serde_json::to_string(&self.to_json()).unwrap_or_default();
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in text.bytes() {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x0100_0000_01b3);
        }
        format!("{h:016x}")
    }
}
