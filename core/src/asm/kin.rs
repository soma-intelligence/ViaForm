//! Forward kinematics of the assembly tree: where each component is for given joint values.
//!
//! TODO(viaform-kin): once `kin/API.md` lands, build `viaform_kin::Model` from the assembly
//! (`model_from_assembly`) and take FK from it, so Assemble, IK drag and the simulator share one
//! model. This module stays the reference the kin port is tested against.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::math::{Iso, V3, axis_angle, mat_mul, quat, scale, unit};
use super::model::{Assembly, Joint, JointType};

/// Joint values by joint id: degrees, or mm for prismatic joints; ball joints by `<id>:x|y|z`.
pub type Q = BTreeMap<String, f64>;

/// The values to pose the assembly at: the saved pose `pose` (if any), then `q` on top, each
/// clamped to its joint's limits.
pub fn resolve(asm: &Assembly, pose: Option<&str>, q: Option<&Value>) -> Result<Q, String> {
    let mut out = Q::new();
    if let Some(p) = pose {
        let p = asm.pose(p).ok_or_else(|| format!("no pose {p}"))?;
        out.extend(p.q_deg.iter().map(|(k, v)| (k.clone(), *v)));
    }
    if let Some(obj) = q.and_then(Value::as_object) {
        for (k, v) in obj {
            let v = v.as_f64().ok_or_else(|| format!("q.{k} must be a number"))?;
            out.insert(k.clone(), v);
        }
    }
    for (k, v) in out.iter_mut() {
        let id = k.split(':').next().unwrap_or(k);
        let j = asm.joint(id).ok_or_else(|| format!("q names unknown joint {id}"))?;
        *v = j.clamp(*v);
    }
    Ok(out)
}

/// The motion a joint at value `q` gives its child, in the world frame at the home pose.
pub fn joint_motion(j: &Joint, q: &Q) -> Iso {
    let axis = unit(j.axis).unwrap_or([0.0, 0.0, 1.0]);
    let v = |k: &str| q.get(k).copied().unwrap_or(0.0);
    match j.kind {
        JointType::Fixed => Iso::IDENTITY,
        JointType::Revolute | JointType::Wheel => Iso::about(j.origin, axis, v(&j.id).to_radians()),
        JointType::Prismatic => Iso::translation(scale(axis, v(&j.id))),
        JointType::Ball => {
            let rx = axis_angle([1.0, 0.0, 0.0], v(&format!("{}:x", j.id)).to_radians());
            let ry = axis_angle([0.0, 1.0, 0.0], v(&format!("{}:y", j.id)).to_radians());
            let rz = axis_angle([0.0, 0.0, 1.0], v(&format!("{}:z", j.id)).to_radians());
            let rot = mat_mul(&rz, &mat_mul(&ry, &rx));
            let o = j.origin;
            let r = super::math::mat_vec(&rot, o);
            Iso { rot, pos: [o[0] - r[0], o[1] - r[1], o[2] - r[2]] }
        }
    }
}

/// Each component's motion from its home placement (world), by component id. Roots stay home.
pub fn fk(asm: &Assembly, q: &Q) -> BTreeMap<String, Iso> {
    let mut out: BTreeMap<String, Iso> = BTreeMap::new();
    for c in asm.tree_order() {
        let t = match asm.parent_joint(&c.id) {
            Some(j) => out.get(&j.parent).copied().unwrap_or_default().mul(&joint_motion(j, q)),
            None => Iso::IDENTITY,
        };
        out.insert(c.id.clone(), t);
    }
    out
}

/// Where a joint's origin and axis are now (world).
pub fn joint_frame(poses: &BTreeMap<String, Iso>, j: &Joint) -> (V3, V3) {
    let t = poses.get(&j.parent).copied().unwrap_or_default();
    (t.apply(j.origin), t.apply_dir(unit(j.axis).unwrap_or([0.0, 0.0, 1.0])))
}

/// The components at the leaves of the tree (end effectors).
pub fn leaves(asm: &Assembly) -> Vec<String> {
    asm.components.iter().filter(|c| !asm.joints.iter().any(|j| j.parent == c.id)).map(|c| c.id.clone()).collect()
}

/// The poses as JSON: per component the column-major 4x4 matrix, position (mm) and quaternion.
pub fn poses_json(poses: &BTreeMap<String, Iso>) -> Value {
    Value::Array(
        poses
            .iter()
            .map(|(id, t)| json!({"component": id, "pos_mm": t.pos, "quat": quat(&t.rot), "matrix": t.column_major().to_vec()}))
            .collect(),
    )
}
