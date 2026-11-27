//! A candidate as SolidCraft commands: the same `(id, params)` pairs every front end runs.
//!
//! The plate lies in XY with the domain's corner at `spec.origin` and rises along +Z by the
//! spec's thickness. Each piece is a new body (`solid.box`, `solid.cylinder`): a density shape
//! is one box per [`geometry::rects`] rectangle; a frame is one box per beam, laid along X about
//! the world origin, turned about Z and moved to its place in one `solid.move` (a move turns
//! about the world origin first, then translates), and one cylinder per joint as wide as its
//! widest beam to round it. One `solid.combine` joins every piece into the first, which is
//! named `spec.body_name`, with `touching: one_body` so pieces meeting only along an edge or at
//! a corner stay one body. Last, `material.create` and `material.assign`.
//!
//! `material.create` refuses a built-in material's name (`` `Aluminum` is a built-in material
//! (material.list) ``) and a name the design already has (`` the design already has a material
//! `…` ``): a front end that builds a second candidate in the same design treats that refusal as
//! harmless and runs on to `material.assign`.

use serde_json::{Value, json};

use crate::geometry;
use crate::spec::{Candidate, Shape, Spec};

/// The commands that build `candidate` as one body named `spec.body_name`, with its material.
/// Empty when the candidate has no solid.
pub fn commands(spec: &Spec, candidate: &Candidate) -> Vec<(String, Value)> {
    let name = spec.body_name.as_str();
    let [ox, oy, oz] = spec.origin;
    let t = spec.thickness;
    let mut out: Vec<(String, Value)> = Vec::new();
    let mut pieces: Vec<String> = Vec::new();
    let piece = |pieces: &mut Vec<String>| {
        let n = if pieces.is_empty() { name.to_string() } else { format!("{name}_p{}", pieces.len()) };
        pieces.push(n.clone());
        n
    };
    match &candidate.shape {
        Shape::Density { .. } => {
            for r in geometry::rects(&candidate.shape) {
                let body = piece(&mut pieces);
                out.push(cmd(
                    "solid.box",
                    json!({"length": r[2] - r[0], "width": r[3] - r[1], "height": t, "corner": [ox + r[0], oy + r[1], oz], "operation": "new", "body_name": body}),
                ));
            }
        }
        Shape::Frame { nodes, beams } => {
            // The widest beam at each node.
            let mut joint = vec![0.0_f64; nodes.len()];
            for b in beams {
                let (Some(a), Some(c)) = (nodes.get(b.a), nodes.get(b.b)) else { continue };
                let (dx, dy) = (c[0] - a[0], c[1] - a[1]);
                let len = dx.hypot(dy);
                if !(len > 1e-9 && b.width > 1e-9) {
                    continue;
                }
                joint[b.a] = joint[b.a].max(b.width);
                joint[b.b] = joint[b.b].max(b.width);
                let body = piece(&mut pieces);
                out.push(cmd("solid.box", json!({"length": len, "width": b.width, "height": t, "center": [0.0, 0.0, oz + t / 2.0], "operation": "new", "body_name": body})));
                let mid = [ox + (a[0] + c[0]) / 2.0, oy + (a[1] + c[1]) / 2.0, 0.0];
                let deg = dy.atan2(dx).to_degrees();
                let mut mv = json!({"bodies": [body], "translate": mid});
                if deg.abs() > 1e-9 {
                    mv["axis"] = json!([0.0, 0.0, 1.0]);
                    mv["angle"] = json!(format!("{deg:.9} deg"));
                }
                out.push(cmd("solid.move", mv));
            }
            for (n, d) in nodes.iter().zip(&joint) {
                if *d > 0.0 {
                    let body = piece(&mut pieces);
                    out.push(cmd("solid.cylinder", json!({"diameter": d, "height": t, "base": [ox + n[0], oy + n[1], oz], "operation": "new", "body_name": body})));
                }
            }
        }
    }
    if pieces.is_empty() {
        return Vec::new();
    }
    if pieces.len() > 1 {
        out.push(cmd("solid.combine", json!({"target": pieces[0], "tools": pieces[1..], "operation": "join", "touching": "one_body"})));
    }
    let m = &spec.material;
    out.push(cmd("material.create", json!({"name": m.name, "density_g_cm3": m.density * 1000.0, "color": m.color})));
    out.push(cmd("material.assign", json!({"bodies": [name], "material": m.name})));
    out
}

fn cmd(id: &str, params: Value) -> (String, Value) {
    (id.to_string(), params)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Beam, Method};

    fn candidate(shape: Shape) -> Candidate {
        Candidate {
            id: 0,
            method: Method::Topology,
            mass_g: 0.0,
            compliance: 0.0,
            max_stress: 0.0,
            max_displacement: 0.0,
            volume_fraction: 0.0,
            feasible: true,
            history: Vec::new(),
            shape,
            outlines: Vec::new(),
        }
    }

    #[test]
    fn density_is_boxes_joined_then_material() {
        let spec = Spec { origin: [1.0, 2.0, 3.0], body_name: "Arm".into(), ..Spec::default() };
        let shape = Shape::Density { nx: 2, ny: 2, cell: 5.0, values: vec![1.0, 1.0, 1.0, 0.0] };
        let c = commands(&spec, &candidate(shape));
        let ids: Vec<&str> = c.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["solid.box", "solid.box", "solid.combine", "material.create", "material.assign"]);
        assert_eq!(c[0].1["corner"], json!([1.0, 2.0, 3.0]));
        assert_eq!(c[0].1["body_name"], "Arm");
        assert_eq!(c[2].1["tools"], json!(["Arm_p1"]));
        assert_eq!(c[3].1["density_g_cm3"], json!(2.7));
        assert!(commands(&spec, &candidate(Shape::Density { nx: 1, ny: 1, cell: 1.0, values: vec![0.0] })).is_empty());
    }

    #[test]
    fn frame_beams_turn_then_move_and_joints_round() {
        let spec = Spec::default();
        let shape = Shape::Frame { nodes: vec![[0.0, 0.0], [10.0, 10.0]], beams: vec![Beam { a: 0, b: 1, width: 2.0 }] };
        let c = commands(&spec, &candidate(shape));
        let ids: Vec<&str> = c.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["solid.box", "solid.move", "solid.cylinder", "solid.cylinder", "solid.combine", "material.create", "material.assign"]);
        assert_eq!(c[1].1["angle"], "45.000000000 deg");
        assert_eq!(c[1].1["translate"], json!([5.0, 5.0, 0.0]));
    }
}
