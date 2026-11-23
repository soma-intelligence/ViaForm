//! MJCF (MuJoCo) and URDF (ROS) for interchange: generators, schema-level checks and imports
//! back into an assembly.
//!
//! Frames: each component's frame sits at the origin of the joint that places it (a root's at
//! the world origin), with the world's axes at the home pose. So every exported body or link
//! origin is a pure offset (no rotation), joint axes read as they do in the design, and the
//! import recovers the home-pose origins exactly. Units convert to SI on the way out (m, rad,
//! kg·m²) and back on the way in.
//!
//! What only ViaForm knows travels in the format's own extension points: MJCF `<custom><text>`
//! for motors (part, gear ratio, bus id, backlash), tendons and fixed joint names; URDF
//! `<transmission>` for motors (part and reduction). URDF has no ball joint: one exports as
//! fixed, with a warning.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::geom::{Aabb, Mesh};
use super::mass::{Geometry, component_inertial};
use super::math::{V3, scale, sub};
use super::model::{Assembly, Component, Joint, JointType, Limits, MassOverride, Motor, Proxy, Tendon};
use super::xml::{Element, floats, num, nums, parse};

const MM: f64 = 1e-3;

fn frame(asm: &Assembly, c: &str) -> V3 {
    asm.parent_joint(c).map_or([0.0; 3], |j| j.origin)
}

fn si(v: V3) -> String {
    nums(&scale(v, MM))
}

fn bbox(c: &Component, g: &Geometry) -> Option<Aabb> {
    let b = g.meshes_of(c).iter().map(Mesh::aabb).fold(Aabb::EMPTY, |a, b| a.union(&b));
    (!b.is_empty()).then_some(b)
}

fn single_root(asm: &Assembly) -> Result<String, String> {
    asm.validate()?;
    let roots: Vec<&Component> = asm.components.iter().filter(|c| asm.parent_joint(&c.id).is_none()).collect();
    match roots.as_slice() {
        [r] => Ok(r.id.clone()),
        [] => Err("the assembly has no components".into()),
        _ => Err(format!("the assembly has {} separate trees; join them to one root first", roots.len())),
    }
}

fn kv(pairs: &[(&str, Option<String>)]) -> String {
    pairs.iter().filter_map(|(k, v)| v.as_ref().map(|v| format!("{k}={v}"))).collect::<Vec<_>>().join(";")
}

fn parse_kv(s: &str) -> BTreeMap<String, String> {
    s.split(';').filter_map(|p| p.split_once('=')).map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned())).collect()
}

fn rad(deg: f64) -> f64 {
    deg.to_radians()
}

/// Limits in SI for the joint: (lower, upper) in rad or m.
fn si_range(j: &Joint) -> Option<(f64, f64)> {
    let (lo, hi) = j.range()?;
    Some(if j.kind.angular() { (rad(lo), rad(hi)) } else { (lo * MM, hi * MM) })
}

fn si_velocity(j: &Joint) -> Option<f64> {
    j.velocity().map(|v| if j.kind.angular() { rad(v) } else { v * MM })
}

fn limits_from_si(kind: JointType, lo: Option<f64>, hi: Option<f64>, effort: Option<f64>, velocity: Option<f64>) -> Option<Limits> {
    if lo.is_none() && hi.is_none() && effort.is_none() && velocity.is_none() {
        return None;
    }
    let mut l = Limits::default();
    if kind.angular() {
        l.lower_deg = lo.map(f64::to_degrees);
        l.upper_deg = hi.map(f64::to_degrees);
        l.velocity_dps = velocity.map(f64::to_degrees);
        l.effort_nm = effort;
    } else {
        l.lower_mm = lo.map(|x| x / MM);
        l.upper_mm = hi.map(|x| x / MM);
        l.velocity_mmps = velocity.map(|x| x / MM);
        l.effort_n = effort;
    }
    Some(l)
}

fn inertia_si(i: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    i.map(|r| r.map(|x| x * 1e-6))
}

// MARK: URDF

/// The assembly as URDF. Answers the text and any warnings.
pub fn to_urdf(asm: &Assembly, g: &Geometry) -> Result<(String, Vec<String>), String> {
    let root = single_root(asm)?;
    let mut warnings = Vec::new();
    let name = if asm.name.is_empty() { "viaform" } else { asm.name.as_str() };
    let mut robot = Element::new("robot").attr("name", name);
    for c in asm.tree_order() {
        let f = frame(asm, &c.id);
        let mut link = Element::new("link").attr("name", &c.id);
        let (m, _, w) = component_inertial(asm, c, g);
        warnings.extend(w);
        let i = inertia_si(&m.inertia);
        link.push(
            Element::new("inertial")
                .child(Element::new("origin").attr("xyz", si(sub(m.com, f))).attr("rpy", "0 0 0"))
                .child(Element::new("mass").attr("value", num(m.mass)))
                .child(
                    Element::new("inertia")
                        .attr("ixx", num(i[0][0]))
                        .attr("ixy", num(i[0][1]))
                        .attr("ixz", num(i[0][2]))
                        .attr("iyy", num(i[1][1]))
                        .attr("iyz", num(i[1][2]))
                        .attr("izz", num(i[2][2])),
                ),
        );
        if let Some(b) = bbox(c, g) {
            for tag in ["visual", "collision"] {
                link.push(
                    Element::new(tag)
                        .child(Element::new("origin").attr("xyz", si(sub(b.center(), f))).attr("rpy", "0 0 0"))
                        .child(Element::new("geometry").child(Element::new("box").attr("size", si(b.size())))),
                );
            }
        }
        robot.push(link);
    }
    for c in asm.tree_order() {
        let Some(j) = asm.parent_joint(&c.id) else { continue };
        let kind = match j.kind {
            JointType::Revolute => "revolute",
            JointType::Prismatic => "prismatic",
            JointType::Wheel => "continuous",
            JointType::Fixed => "fixed",
            JointType::Ball => {
                warnings.push(format!("{}: URDF has no ball joint; exported as fixed", j.id));
                "fixed"
            }
        };
        let mut e = Element::new("joint")
            .attr("name", &j.id)
            .attr("type", kind)
            .child(Element::new("parent").attr("link", &j.parent))
            .child(Element::new("child").attr("link", &j.child))
            .child(Element::new("origin").attr("xyz", si(sub(j.origin, frame(asm, &j.parent)))).attr("rpy", "0 0 0"));
        if kind != "fixed" {
            e.push(Element::new("axis").attr("xyz", nums(&super::math::unit(j.axis).unwrap_or([0.0, 0.0, 1.0]))));
        }
        if matches!(j.kind, JointType::Revolute | JointType::Prismatic | JointType::Wheel) {
            let mut l = Element::new("limit");
            if let Some((lo, hi)) = si_range(j) {
                l = l.attr("lower", num(lo)).attr("upper", num(hi));
            } else if j.kind != JointType::Wheel {
                warnings.push(format!("{}: no range; URDF reads it as 0 to 0", j.id));
            }
            l = l.attr("effort", num(j.effort().unwrap_or(0.0))).attr("velocity", num(si_velocity(j).unwrap_or(0.0)));
            e.push(l);
        }
        if j.damping != 0.0 || j.friction != 0.0 {
            e.push(Element::new("dynamics").attr("damping", num(j.damping)).attr("friction", num(j.friction)));
        }
        if j.tendon.is_some() {
            warnings.push(format!("{}: URDF has no tendons; the tendon is left out", j.id));
        }
        robot.push(e);
    }
    for j in &asm.joints {
        let Some(m) = &j.motor else { continue };
        robot.push(
            Element::new("transmission")
                .attr("name", format!("{}_transmission", j.id))
                .child(Element::new("type").text("transmission_interface/SimpleTransmission"))
                .child(Element::new("joint").attr("name", &j.id).child(Element::new("hardwareInterface").text("hardware_interface/PositionJointInterface")))
                .child(
                    Element::new("actuator")
                        .attr("name", format!("{}/{}", j.id, m.part))
                        .child(Element::new("mechanicalReduction").text(num(m.gear_ratio))),
                ),
        );
    }
    if root != asm.ground.clone().unwrap_or_else(|| root.clone()) {
        warnings.push("the ground is not the tree's root".into());
    }
    let text = robot.to_string_pretty();
    validate_urdf(&text)?;
    Ok((text, warnings))
}

fn v3_attr(e: Option<&Element>, k: &str, default: V3) -> Result<V3, String> {
    match e.and_then(|e| e.get(k)) {
        None => Ok(default),
        Some(s) => {
            let f = floats(s)?;
            if f.len() != 3 {
                return Err(format!("{k}=\"{s}\" needs three numbers"));
            }
            Ok([f[0], f[1], f[2]])
        }
    }
}

fn f_attr(e: &Element, k: &str) -> Result<Option<f64>, String> {
    e.get(k).map(|s| s.trim().parse::<f64>().map_err(|_| format!("{k}=\"{s}\" is not a number"))).transpose()
}

/// Checks a URDF at the schema level: well-formed, a `robot` with a name, named and unique
/// links and joints, known joint types, parent and child links that exist, limits where the
/// type needs them, three-number vectors, one root and a tree.
pub fn validate_urdf(text: &str) -> Result<Value, String> {
    let robot = parse(text)?;
    if robot.name != "robot" {
        return Err(format!("the root element is <{}>, not <robot>", robot.name));
    }
    robot.get("name").filter(|n| !n.is_empty()).ok_or("<robot> needs a name")?;
    let mut links = BTreeSet::new();
    for l in robot.all("link") {
        let n = l.get("name").filter(|n| !n.is_empty()).ok_or("a <link> has no name")?;
        if !links.insert(n) {
            return Err(format!("link {n} is defined twice"));
        }
        if let Some(i) = l.first("inertial") {
            let m = i.first("mass").ok_or(format!("{n}: <inertial> needs <mass>"))?;
            let mv = f_attr(m, "value")?.ok_or(format!("{n}: <mass> needs a value"))?;
            if mv < 0.0 {
                return Err(format!("{n}: negative mass"));
            }
            let t = i.first("inertia").ok_or(format!("{n}: <inertial> needs <inertia>"))?;
            for k in ["ixx", "ixy", "ixz", "iyy", "iyz", "izz"] {
                f_attr(t, k)?.ok_or(format!("{n}: <inertia> needs {k}"))?;
            }
            v3_attr(i.first("origin"), "xyz", [0.0; 3])?;
        }
        for v in l.all("visual").chain(l.all("collision")) {
            let geo = v.first("geometry").ok_or(format!("{n}: <{}> needs <geometry>", v.name))?;
            if geo.children.len() != 1 {
                return Err(format!("{n}: <geometry> takes exactly one shape"));
            }
        }
    }
    let mut names = BTreeSet::new();
    let mut child_of = BTreeMap::new();
    let mut edges = Vec::new();
    for j in robot.all("joint") {
        let n = j.get("name").filter(|n| !n.is_empty()).ok_or("a <joint> has no name")?;
        if !names.insert(n) {
            return Err(format!("joint {n} is defined twice"));
        }
        let t = j.get("type").ok_or(format!("joint {n} has no type"))?;
        if !["revolute", "continuous", "prismatic", "fixed", "floating", "planar"].contains(&t) {
            return Err(format!("joint {n}: unknown type {t}"));
        }
        let p = j.first("parent").and_then(|e| e.get("link")).ok_or(format!("joint {n} needs <parent link>"))?;
        let c = j.first("child").and_then(|e| e.get("link")).ok_or(format!("joint {n} needs <child link>"))?;
        for l in [p, c] {
            if !links.contains(l) {
                return Err(format!("joint {n} uses unknown link {l}"));
            }
        }
        if child_of.insert(c, n).is_some() {
            return Err(format!("link {c} has two parent joints"));
        }
        edges.push((p, c));
        v3_attr(j.first("origin"), "xyz", [0.0; 3])?;
        v3_attr(j.first("origin"), "rpy", [0.0; 3])?;
        let axis = v3_attr(j.first("axis"), "xyz", [1.0, 0.0, 0.0])?;
        if super::math::unit(axis).is_none() {
            return Err(format!("joint {n} has a zero axis"));
        }
        if matches!(t, "revolute" | "prismatic") {
            let l = j.first("limit").ok_or(format!("joint {n} ({t}) needs <limit>"))?;
            let effort = f_attr(l, "effort")?.ok_or(format!("joint {n}: <limit> needs effort"))?;
            let vel = f_attr(l, "velocity")?.ok_or(format!("joint {n}: <limit> needs velocity"))?;
            let lo = f_attr(l, "lower")?.unwrap_or(0.0);
            let hi = f_attr(l, "upper")?.unwrap_or(0.0);
            if lo > hi || effort < 0.0 || vel < 0.0 {
                return Err(format!("joint {n}: inconsistent <limit>"));
            }
        }
    }
    let roots: Vec<&&str> = links.iter().filter(|l| !child_of.contains_key(*l)).collect();
    if roots.len() != 1 {
        return Err(format!("a URDF has one root link; this one has {}", roots.len()));
    }
    // One parent each and one root: every link must hang from the root, or there is a loop.
    let mut reached: BTreeSet<&str> = BTreeSet::from([*roots[0]]);
    let mut grew = true;
    while grew {
        grew = false;
        for (p, c) in &edges {
            if reached.contains(p) && reached.insert(*c) {
                grew = true;
            }
        }
    }
    if reached.len() != links.len() {
        return Err("the joints form a loop or leave links hanging".into());
    }
    for t in robot.all("transmission") {
        for j in t.all("joint") {
            let n = j.get("name").unwrap_or("");
            if !names.contains(n) {
                return Err(format!("transmission drives unknown joint {n}"));
            }
        }
    }
    Ok(json!({"valid": true, "links": links.len(), "joints": names.len(), "root": roots[0]}))
}

/// An assembly from URDF. Links become components (their box geometry a proxy, their inertial a
/// mass override); joints come back at their home-pose origins in mm and degrees.
pub fn from_urdf(text: &str) -> Result<Assembly, String> {
    validate_urdf(text)?;
    let robot = parse(text)?;
    let mut asm = Assembly { name: robot.get("name").unwrap_or("").to_owned(), ..Assembly::default() };
    // World offsets of each link's frame, from the root down.
    let joints: Vec<&Element> = robot.all("joint").collect();
    let mut frame_of: BTreeMap<String, V3> = BTreeMap::new();
    let child_links: BTreeSet<&str> = joints.iter().filter_map(|j| j.first("child")?.get("link")).collect();
    for l in robot.all("link") {
        if let Some(n) = l.get("name")
            && !child_links.contains(n)
        {
            frame_of.insert(n.to_owned(), [0.0; 3]);
            asm.ground = Some(n.to_owned());
        }
    }
    let mut pending = joints.clone();
    let mut ordered = Vec::new();
    while !pending.is_empty() {
        let before = pending.len();
        pending.retain(|j| {
            let p = j.first("parent").and_then(|e| e.get("link")).unwrap_or("");
            let c = j.first("child").and_then(|e| e.get("link")).unwrap_or("");
            match frame_of.get(p).copied() {
                Some(fp) => {
                    let off = v3_attr(j.first("origin"), "xyz", [0.0; 3]).unwrap_or([0.0; 3]);
                    frame_of.insert(c.to_owned(), [fp[0] + off[0] / MM, fp[1] + off[1] / MM, fp[2] + off[2] / MM]);
                    ordered.push(*j);
                    false
                }
                None => true,
            }
        });
        if pending.len() == before {
            return Err("the joints do not form a tree".into());
        }
    }
    for l in robot.all("link") {
        let n = l.get("name").unwrap_or("").to_owned();
        let f = frame_of.get(&n).copied().unwrap_or([0.0; 3]);
        let mut c = Component { id: n.clone(), ..Component::default() };
        if let Some(v) = l.first("collision").or_else(|| l.first("visual"))
            && let Some(b) = v.first("geometry").and_then(|g| g.first("box"))
        {
            let size = v3_attr(Some(b), "size", [0.0; 3])?;
            let at = v3_attr(v.first("origin"), "xyz", [0.0; 3])?;
            let centre = [f[0] + at[0] / MM, f[1] + at[1] / MM, f[2] + at[2] / MM];
            let half = scale(size, 0.5 / MM);
            c.proxy = Some(Proxy { min_mm: sub(centre, half), max_mm: [centre[0] + half[0], centre[1] + half[1], centre[2] + half[2]], mass_kg: None });
        }
        if let Some(i) = l.first("inertial") {
            let mass = i.first("mass").and_then(|m| f_attr(m, "value").ok().flatten()).unwrap_or(0.0);
            let at = v3_attr(i.first("origin"), "xyz", [0.0; 3])?;
            let t = i.first("inertia").ok_or("inertia")?;
            let g = |k: &str| f_attr(t, k).ok().flatten().unwrap_or(0.0) * 1e6;
            let inertia = [[g("ixx"), g("ixy"), g("ixz")], [g("ixy"), g("iyy"), g("iyz")], [g("ixz"), g("iyz"), g("izz")]];
            asm.mass_overrides.push(MassOverride {
                component: n.clone(),
                mass_kg: mass,
                center_of_mass_mm: Some([f[0] + at[0] / MM, f[1] + at[1] / MM, f[2] + at[2] / MM]),
                inertia_kg_mm2: Some(inertia),
            });
        }
        asm.components.push(c);
    }
    let mut motors: BTreeMap<String, Motor> = BTreeMap::new();
    for t in robot.all("transmission") {
        let (Some(j), Some(a)) = (t.first("joint").and_then(|j| j.get("name")), t.first("actuator")) else { continue };
        let part = a.get("name").and_then(|n| n.split_once('/')).map_or_else(|| a.get("name").unwrap_or("").to_owned(), |(_, p)| p.to_owned());
        let ratio = a.first("mechanicalReduction").and_then(|r| r.text.trim().parse().ok()).unwrap_or(1.0);
        motors.insert(j.to_owned(), Motor { part, gear_ratio: ratio, ..Motor::default() });
    }
    for j in ordered {
        let id = j.get("name").unwrap_or("").to_owned();
        let kind = match j.get("type").unwrap_or("") {
            "revolute" => JointType::Revolute,
            "continuous" => JointType::Wheel,
            "prismatic" => JointType::Prismatic,
            "fixed" => JointType::Fixed,
            t => return Err(format!("joint {id}: {t} joints do not import yet")),
        };
        let parent = j.first("parent").and_then(|e| e.get("link")).unwrap_or("").to_owned();
        let child = j.first("child").and_then(|e| e.get("link")).unwrap_or("").to_owned();
        let rpy = v3_attr(j.first("origin"), "rpy", [0.0; 3])?;
        if rpy.iter().any(|x| x.abs() > 1e-12) {
            return Err(format!("joint {id}: rotated joint frames do not import yet"));
        }
        let limits = match j.first("limit") {
            Some(l) => limits_from_si(kind, f_attr(l, "lower")?, f_attr(l, "upper")?, f_attr(l, "effort")?, f_attr(l, "velocity")?),
            None => None,
        };
        let dynamics = j.first("dynamics");
        asm.joints.push(Joint {
            id: id.clone(),
            kind,
            origin: frame_of.get(&child).copied().unwrap_or([0.0; 3]),
            axis: if kind == JointType::Fixed { [0.0, 0.0, 1.0] } else { v3_attr(j.first("axis"), "xyz", [1.0, 0.0, 0.0])? },
            limits,
            motor: motors.remove(&id),
            damping: dynamics.and_then(|d| f_attr(d, "damping").ok().flatten()).unwrap_or(0.0),
            friction: dynamics.and_then(|d| f_attr(d, "friction").ok().flatten()).unwrap_or(0.0),
            parent,
            child,
            ..Joint::default()
        });
    }
    asm.validate()?;
    Ok(asm)
}

// MARK: MJCF

/// The assembly as MJCF. Answers the text and any warnings.
pub fn to_mjcf(asm: &Assembly, g: &Geometry) -> Result<(String, Vec<String>), String> {
    let root = single_root(asm)?;
    let mut warnings = Vec::new();
    let name = if asm.name.is_empty() { "viaform" } else { asm.name.as_str() };
    let mut doc = Element::new("mujoco")
        .attr("model", name)
        .child(Element::new("compiler").attr("angle", "radian").attr("autolimits", "true"))
        .child(Element::new("option").attr("gravity", "0 0 -9.81"));

    fn body(asm: &Assembly, g: &Geometry, c: &Component, warnings: &mut Vec<String>) -> Element {
        let f = frame(asm, &c.id);
        let parent_frame = asm.parent_joint(&c.id).map_or([0.0; 3], |j| frame(asm, &j.parent));
        let mut b = Element::new("body").attr("name", &c.id).attr("pos", si(sub(f, parent_frame)));
        match asm.parent_joint(&c.id) {
            None if asm.ground.as_deref() != Some(c.id.as_str()) => b.push(Element::new("freejoint").attr("name", format!("{}_free", c.id))),
            None => {}
            Some(j) => {
                let t = match j.kind {
                    JointType::Revolute | JointType::Wheel => Some("hinge"),
                    JointType::Prismatic => Some("slide"),
                    JointType::Ball => Some("ball"),
                    JointType::Fixed => None,
                };
                match t {
                    Some(t) => {
                        let mut e = Element::new("joint").attr("name", &j.id).attr("type", t);
                        if t != "ball" {
                            e = e.attr("axis", nums(&super::math::unit(j.axis).unwrap_or([0.0, 0.0, 1.0])));
                        }
                        match si_range(j) {
                            Some((lo, hi)) => e = e.attr("range", nums(&[lo, hi])),
                            None if t != "ball" => e = e.attr("limited", "false"),
                            None => {}
                        }
                        if let Some(eff) = j.effort() {
                            e = e.attr("actuatorfrcrange", nums(&[-eff, eff]));
                        }
                        if j.damping != 0.0 {
                            e = e.attr("damping", num(j.damping));
                        }
                        if j.friction != 0.0 {
                            e = e.attr("frictionloss", num(j.friction));
                        }
                        b.push(e);
                    }
                    None => b.push(Element::new("site").attr("name", format!("vf_fixed:{}", j.id)).attr("size", "0.001")),
                }
            }
        }
        let (m, _, w) = component_inertial(asm, c, g);
        warnings.extend(w);
        if m.mass > 0.0 {
            let i = inertia_si(&m.inertia);
            b.push(
                Element::new("inertial")
                    .attr("pos", si(sub(m.com, f)))
                    .attr("mass", num(m.mass))
                    .attr("fullinertia", nums(&[i[0][0], i[1][1], i[2][2], i[0][1], i[0][2], i[1][2]])),
            );
        } else if asm.parent_joint(&c.id).is_some() {
            warnings.push(format!("{}: no mass; MuJoCo needs one on a moving body", c.id));
        }
        if let Some(bx) = bbox(c, g) {
            b.push(Element::new("geom").attr("name", format!("{}_box", c.id)).attr("type", "box").attr("size", si(scale(bx.size(), 0.5))).attr("pos", si(sub(bx.center(), f))).attr("mass", "0"));
        }
        for j in asm.joints.iter().filter(|j| j.parent == c.id) {
            if let Some(k) = asm.component(&j.child) {
                b.push(body(asm, g, k, warnings));
            }
        }
        b
    }

    let mut world = Element::new("worldbody");
    if let Some(r) = asm.component(&root) {
        world.push(body(asm, g, r, &mut warnings));
    }
    doc.push(world);

    let mut actuators = Element::new("actuator");
    let mut custom = Element::new("custom");
    for j in &asm.joints {
        if let Some(m) = &j.motor {
            let mut a = Element::new("position").attr("name", format!("{}_servo", j.id)).attr("joint", &j.id).attr("kp", num(m.kp.unwrap_or(10.0)));
            if let Some((lo, hi)) = si_range(j) {
                a = a.attr("ctrlrange", nums(&[lo, hi]));
            }
            if let Some(eff) = j.effort().or(m.stall_torque_nm) {
                a = a.attr("forcerange", nums(&[-eff, eff]));
            }
            actuators.push(a);
            let data = kv(&[
                ("part", Some(m.part.clone())),
                ("bom_line", m.bom_line.clone()),
                ("gear_ratio", Some(num(m.gear_ratio))),
                ("backlash_deg", (m.backlash_deg != 0.0).then(|| num(m.backlash_deg))),
                ("bus_id", m.bus_id.map(|b| b.to_string())),
                ("stall_torque_nm", m.stall_torque_nm.map(num)),
                ("no_load_speed_dps", m.no_load_speed_dps.map(num)),
                ("voltage_v", m.voltage_v.map(num)),
                ("kp", m.kp.map(num)),
            ]);
            custom.push(Element::new("text").attr("name", format!("vf_motor:{}", j.id)).attr("data", data));
        }
        if let Some(v) = si_velocity(j) {
            custom.push(Element::new("text").attr("name", format!("vf_velocity:{}", j.id)).attr("data", format!("v={}", num(v))));
        }
        if let Some(t) = &j.tendon {
            let data = kv(&[
                ("actuator", Some(t.actuator.clone())),
                ("ratio", Some(num(t.ratio))),
                ("stiffness_n_per_mm", t.stiffness_n_per_mm.map(num)),
                ("slack_mm", (t.slack_mm != 0.0).then(|| num(t.slack_mm))),
            ]);
            custom.push(Element::new("text").attr("name", format!("vf_tendon:{}", j.id)).attr("data", data));
        }
    }
    if !actuators.children.is_empty() {
        doc.push(actuators);
    }
    if !custom.children.is_empty() {
        doc.push(custom);
    }
    let text = doc.to_string_pretty();
    validate_mjcf(&text)?;
    Ok((text, warnings))
}

/// Checks an MJCF at the schema level: well-formed, a `mujoco` root with one `worldbody`,
/// unique body and joint names, known joint and geom types, axes and ranges that read,
/// inertials with a mass and an inertia, actuators on joints that exist, at most one free
/// joint and only on a top-level body.
pub fn validate_mjcf(text: &str) -> Result<Value, String> {
    let doc = parse(text)?;
    if doc.name != "mujoco" {
        return Err(format!("the root element is <{}>, not <mujoco>", doc.name));
    }
    let worlds: Vec<&Element> = doc.all("worldbody").collect();
    if worlds.len() != 1 {
        return Err("an MJCF needs exactly one <worldbody>".into());
    }
    let mut bodies = BTreeSet::new();
    let mut joints = BTreeSet::new();
    fn walk<'a>(b: &'a Element, top: bool, bodies: &mut BTreeSet<&'a str>, joints: &mut BTreeSet<&'a str>) -> Result<(), String> {
        for e in &b.children {
            match e.name.as_str() {
                "body" => {
                    let n = e.get("name").filter(|n| !n.is_empty()).ok_or("a <body> has no name")?;
                    if !bodies.insert(n) {
                        return Err(format!("body {n} is defined twice"));
                    }
                    if let Some(p) = e.get("pos")
                        && floats(p)?.len() != 3
                    {
                        return Err(format!("body {n}: pos needs three numbers"));
                    }
                    walk(e, false, bodies, joints)?;
                }
                "joint" | "freejoint" => {
                    let t = if e.name == "freejoint" { "free" } else { e.get("type").unwrap_or("hinge") };
                    if !["hinge", "slide", "ball", "free"].contains(&t) {
                        return Err(format!("unknown joint type {t}"));
                    }
                    if t == "free" && !top {
                        return Err("a free joint belongs on a top-level body".into());
                    }
                    if let Some(n) = e.get("name")
                        && !joints.insert(n)
                    {
                        return Err(format!("joint {n} is defined twice"));
                    }
                    if let Some(a) = e.get("axis") {
                        let a = floats(a)?;
                        if a.len() != 3 || a.iter().all(|x| *x == 0.0) {
                            return Err("a joint axis needs three numbers, not all zero".into());
                        }
                    }
                    if let Some(r) = e.get("range") {
                        let r = floats(r)?;
                        if r.len() != 2 || r[0] > r[1] {
                            return Err("a joint range needs two numbers, lower first".into());
                        }
                    }
                }
                "inertial" => {
                    let m = f_attr(e, "mass")?.ok_or("<inertial> needs a mass")?;
                    if !(m > 0.0) {
                        return Err("<inertial> mass must be positive".into());
                    }
                    let full = e.get("fullinertia").map(floats).transpose()?;
                    let diag = e.get("diaginertia").map(floats).transpose()?;
                    match (full, diag) {
                        (Some(f), None) if f.len() == 6 => {}
                        (None, Some(d)) if d.len() == 3 => {}
                        _ => return Err("<inertial> needs fullinertia (6) or diaginertia (3)".into()),
                    }
                }
                "geom" => {
                    let t = e.get("type").unwrap_or("sphere");
                    if !["plane", "hfield", "sphere", "capsule", "ellipsoid", "cylinder", "box", "mesh", "sdf"].contains(&t) {
                        return Err(format!("unknown geom type {t}"));
                    }
                    if let Some(s) = e.get("size") {
                        floats(s)?;
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }
    walk(worlds[0], true, &mut bodies, &mut joints)?;
    for a in doc.all("actuator") {
        for e in &a.children {
            let j = e.get("joint").ok_or(format!("actuator <{}> names no joint", e.name))?;
            if !joints.contains(j) {
                return Err(format!("actuator drives unknown joint {j}"));
            }
        }
    }
    Ok(json!({"valid": true, "bodies": bodies.len(), "joints": joints.len()}))
}

/// An assembly from MJCF (bodies without rotations, as ViaForm writes them). Bodies become
/// components (a box geom a proxy, the inertial a mass override).
pub fn from_mjcf(text: &str) -> Result<Assembly, String> {
    validate_mjcf(text)?;
    let doc = parse(text)?;
    let mut asm = Assembly { name: doc.get("model").unwrap_or("").to_owned(), ..Assembly::default() };
    let mut extras: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for c in doc.all("custom") {
        for t in c.all("text") {
            if let (Some(n), Some(d)) = (t.get("name"), t.get("data")) {
                extras.insert(n.to_owned(), parse_kv(d));
            }
        }
    }
    fn walk(e: &Element, parent: Option<(&str, V3)>, asm: &mut Assembly, extras: &BTreeMap<String, BTreeMap<String, String>>) -> Result<(), String> {
        for b in e.all("body") {
            let n = b.get("name").unwrap_or("").to_owned();
            if b.get("quat").is_some() || b.get("euler").is_some() || b.get("axisangle").is_some() {
                return Err(format!("body {n}: rotated bodies do not import yet"));
            }
            let pos = v3_attr(Some(b), "pos", [0.0; 3])?;
            let base = parent.map_or([0.0; 3], |(_, f)| f);
            let f = [base[0] + pos[0] / MM, base[1] + pos[1] / MM, base[2] + pos[2] / MM];
            let mut c = Component { id: n.clone(), ..Component::default() };
            if let Some(g) = b.all("geom").find(|g| g.get("type") == Some("box")) {
                let half = v3_attr(Some(g), "size", [0.0; 3])?;
                let at = v3_attr(Some(g), "pos", [0.0; 3])?;
                let centre = [f[0] + at[0] / MM, f[1] + at[1] / MM, f[2] + at[2] / MM];
                let h = scale(half, 1.0 / MM);
                c.proxy = Some(Proxy { min_mm: sub(centre, h), max_mm: [centre[0] + h[0], centre[1] + h[1], centre[2] + h[2]], mass_kg: None });
            }
            if let Some(i) = b.first("inertial") {
                let mass = f_attr(i, "mass")?.unwrap_or(0.0);
                let at = v3_attr(Some(i), "pos", [0.0; 3])?;
                let inertia = if let Some(fi) = i.get("fullinertia") {
                    let v = floats(fi)?;
                    [[v[0], v[3], v[4]], [v[3], v[1], v[5]], [v[4], v[5], v[2]]]
                } else {
                    let v = floats(i.get("diaginertia").unwrap_or("0 0 0"))?;
                    [[v[0], 0.0, 0.0], [0.0, v[1], 0.0], [0.0, 0.0, v[2]]]
                };
                asm.mass_overrides.push(MassOverride {
                    component: n.clone(),
                    mass_kg: mass,
                    center_of_mass_mm: Some([f[0] + at[0] / MM, f[1] + at[1] / MM, f[2] + at[2] / MM]),
                    inertia_kg_mm2: Some(inertia.map(|r| r.map(|x| x * 1e6))),
                });
            }
            asm.components.push(c);
            let joints: Vec<&Element> = b.all("joint").collect();
            if joints.len() > 1 {
                return Err(format!("body {n}: more than one joint does not import yet"));
            }
            match (parent, joints.first()) {
                (None, _) if b.first("freejoint").is_some() => {}
                (None, None) => {
                    if asm.ground.is_none() {
                        asm.ground = Some(n.clone());
                    }
                }
                (None, Some(_)) => return Err(format!("body {n}: a joint to the world does not import yet")),
                (Some((p, _)), j) => {
                    let (id, kind, axis, limits, damping, friction) = match j {
                        None => {
                            let id = b
                                .all("site")
                                .find_map(|s| s.get("name").and_then(|x| x.strip_prefix("vf_fixed:")))
                                .map_or_else(|| format!("{n}_fixed"), str::to_owned);
                            (id, JointType::Fixed, [0.0, 0.0, 1.0], None, 0.0, 0.0)
                        }
                        Some(j) => {
                            let id = j.get("name").map_or_else(|| format!("{n}_joint"), str::to_owned);
                            let limited = j.get("limited") != Some("false");
                            let range = j.get("range").map(floats).transpose()?;
                            let kind = match j.get("type").unwrap_or("hinge") {
                                "hinge" if range.is_none() && !limited => JointType::Wheel,
                                "hinge" => JointType::Revolute,
                                "slide" => JointType::Prismatic,
                                _ => JointType::Ball,
                            };
                            let eff = j.get("actuatorfrcrange").map(floats).transpose()?.and_then(|r| r.get(1).copied());
                            let (lo, hi) = range.map_or((None, None), |r| (Some(r[0]), Some(r[1])));
                            let axis = if kind == JointType::Ball { [0.0, 0.0, 1.0] } else { v3_attr(Some(j), "axis", [0.0, 0.0, 1.0])? };
                            (id, kind, axis, limits_from_si(kind, lo, hi, eff, None), f_attr(j, "damping")?.unwrap_or(0.0), f_attr(j, "frictionloss")?.unwrap_or(0.0))
                        }
                    };
                    let motor = extras.get(&format!("vf_motor:{id}")).map(|m| Motor {
                        part: m.get("part").cloned().unwrap_or_default(),
                        bom_line: m.get("bom_line").cloned(),
                        gear_ratio: m.get("gear_ratio").and_then(|x| x.parse().ok()).unwrap_or(1.0),
                        backlash_deg: m.get("backlash_deg").and_then(|x| x.parse().ok()).unwrap_or(0.0),
                        bus_id: m.get("bus_id").and_then(|x| x.parse().ok()),
                        stall_torque_nm: m.get("stall_torque_nm").and_then(|x| x.parse().ok()),
                        no_load_speed_dps: m.get("no_load_speed_dps").and_then(|x| x.parse().ok()),
                        voltage_v: m.get("voltage_v").and_then(|x| x.parse().ok()),
                        kp: m.get("kp").and_then(|x| x.parse().ok()),
                    });
                    let tendon = extras.get(&format!("vf_tendon:{id}")).map(|t| Tendon {
                        actuator: t.get("actuator").cloned().unwrap_or_default(),
                        ratio: t.get("ratio").and_then(|x| x.parse().ok()).unwrap_or(1.0),
                        stiffness_n_per_mm: t.get("stiffness_n_per_mm").and_then(|x| x.parse().ok()),
                        slack_mm: t.get("slack_mm").and_then(|x| x.parse().ok()).unwrap_or(0.0),
                    });
                    asm.joints.push(Joint {
                        id,
                        kind,
                        parent: p.to_owned(),
                        child: n.clone(),
                        origin: f,
                        axis,
                        limits,
                        motor,
                        tendon,
                        damping,
                        friction,
                        cad_joint: None,
                    });
                }
            }
            walk(b, Some((&n, f)), asm, extras)?;
        }
        Ok(())
    }
    if let Some(w) = doc.first("worldbody") {
        walk(w, None, &mut asm, &extras)?;
    }
    for j in &mut asm.joints {
        if let Some(v) = extras.get(&format!("vf_velocity:{}", j.id)).and_then(|m| m.get("v")).and_then(|x| x.parse::<f64>().ok()) {
            let l = j.limits.get_or_insert_with(Limits::default);
            if j.kind.angular() {
                l.velocity_dps = Some(v.to_degrees());
            } else {
                l.velocity_mmps = Some(v / MM);
            }
        }
    }
    asm.validate()?;
    Ok(asm)
}
