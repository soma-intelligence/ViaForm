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

/// The assembly as a `viaform-kin` model (`kin/API.md`, SI units), so the IK drag and the grasp
/// solver work on the same chain the Assemble canvas draws. One link per component in tree
/// order; each link's frame sits at its parent joint's origin with the world axes at the home
/// pose, so a link pose from kin times `translation(-origin)` places the component's home
/// geometry. Ball joints become spherical joints, fixed ones fixed. The tool frame `tool` sits
/// on component `tool` at `tip_mm` (world, home pose); by default on the component that carries
/// the gripper joint (or the last leaf), at the top centre of it and its children's proxy boxes.
/// Reply: `{model, links: [component ids], joints: [joint ids in q order], tool: {component,
/// tip_mm}}`.
pub fn kin_model(asm: &Assembly, tool: Option<&str>, tip_mm: Option<V3>) -> Result<Value, String> {
    let order: Vec<&str> = asm.tree_order().iter().map(|c| c.id.as_str()).collect();
    if order.is_empty() {
        return Err("the assembly has no components".into());
    }
    let index = |id: &str| order.iter().position(|c| *c == id);
    let frame_origin = |id: &str| asm.parent_joint(id).map(|j| j.origin).unwrap_or([0.0; 3]);
    let m = |v: f64| v / 1000.0;
    let links: Vec<Value> = order.iter().map(|c| json!({"name": c})).collect();
    let mut joints = Vec::new();
    let mut joint_ids = Vec::new();
    for c in order.iter().skip(1) {
        let j = asm.parent_joint(c).ok_or_else(|| format!("component {c} has no parent joint"))?;
        let parent = index(&j.parent).ok_or_else(|| format!("joint {} names unknown parent {}", j.id, j.parent))?;
        let po = frame_origin(&j.parent);
        let kind = match j.kind {
            JointType::Revolute => "revolute",
            JointType::Prismatic => "prismatic",
            JointType::Fixed => "fixed",
            JointType::Ball => "spherical",
            JointType::Wheel => "continuous",
        };
        let mut limits = json!({});
        if let Some((lo, hi)) = j.range() {
            let k = if j.kind.angular() { std::f64::consts::PI / 180.0 } else { 0.001 };
            limits["lower"] = json!(lo * k);
            limits["upper"] = json!(hi * k);
        }
        if let Some(v) = j.velocity() {
            limits["velocity"] = json!(if j.kind.angular() { v.to_radians() } else { v / 1000.0 });
        }
        if let Some(e) = j.effort() {
            limits["effort"] = json!(e);
        }
        joints.push(json!({
            "name": j.id, "kind": kind, "parent": parent,
            "origin": {"xyz": [m(j.origin[0] - po[0]), m(j.origin[1] - po[1]), m(j.origin[2] - po[2])], "quat_wxyz": [1.0, 0.0, 0.0, 0.0]},
            "axis": unit(j.axis).unwrap_or([0.0, 0.0, 1.0]), "limits": limits,
        }));
        joint_ids.push(j.id.clone());
    }
    let tool_id = match tool {
        Some(t) => t.to_owned(),
        None => asm
            .joints
            .iter()
            .find(|j| j.id.contains("gripper") || j.id.contains("jaw"))
            .map(|j| j.parent.clone())
            .or_else(|| leaves(asm).last().cloned())
            .unwrap_or_else(|| order[order.len() - 1].to_owned()),
    };
    let tool_link = index(&tool_id).ok_or_else(|| format!("no component {tool_id}"))?;
    let tip = match tip_mm {
        Some(t) => t,
        None => {
            // The tool and everything under it, home pose: top centre of their proxy boxes.
            let mut ids = vec![tool_id.clone()];
            let mut i = 0;
            while i < ids.len() {
                let kids: Vec<String> = asm.joints.iter().filter(|j| j.parent == ids[i]).map(|j| j.child.clone()).collect();
                ids.extend(kids);
                i += 1;
            }
            let (mut lo, mut hi) = ([f64::INFINITY; 3], [f64::NEG_INFINITY; 3]);
            for c in ids.iter().filter_map(|id| asm.component(id)).filter_map(|c| c.proxy.as_ref()) {
                for k in 0..3 {
                    lo[k] = lo[k].min(c.min_mm[k]);
                    hi[k] = hi[k].max(c.max_mm[k]);
                }
            }
            if lo[0].is_finite() { [(lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0, hi[2]] } else { frame_origin(&tool_id) }
        }
    };
    let to = frame_origin(&tool_id);
    let model = json!({
        "name": if asm.name.is_empty() { "assembly" } else { asm.name.as_str() },
        "links": links, "joints": joints,
        "end_effectors": [{"name": "tool", "link": tool_link, "offset": {"xyz": [m(tip[0] - to[0]), m(tip[1] - to[1]), m(tip[2] - to[2])], "quat_wxyz": [1.0, 0.0, 0.0, 0.0]}}],
    });
    Ok(json!({"model": model, "links": order, "joints": joint_ids, "tool": {"component": tool_id, "tip_mm": tip}}))
}

#[cfg(test)]
mod kin_model_tests {
    use super::*;

    #[test]
    fn arm_as_kin_model() {
        let asm = super::super::template::arm();
        let r = kin_model(&asm, None, None).unwrap();
        assert_eq!(r["links"].as_array().unwrap().len(), 7);
        assert_eq!(r["joints"].as_array().unwrap().len(), 6);
        assert_eq!(r["tool"]["component"], "gripper");
        assert_eq!(r["model"]["end_effectors"][0]["link"], 5);
        // Elbow sits 98 mm above the shoulder lift, in the upper arm's frame.
        let elbow = &r["model"]["joints"][2];
        assert_eq!(elbow["name"], "elbow");
        assert!((elbow["origin"]["xyz"][2].as_f64().unwrap() - 0.098).abs() < 1e-9);
        assert!((elbow["limits"]["upper"].as_f64().unwrap() - 135f64.to_radians()).abs() < 1e-9);
    }
}
