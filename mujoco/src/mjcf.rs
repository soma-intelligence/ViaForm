//! Model export: a phys model (an `assembly.json` plus scenario, a built-in, or any
//! [`PhysModel`]) as MJCF, MuJoCo's XML model format. Pure Rust: it needs no MuJoCo library,
//! so the exporter builds and is tested with the `mujoco` feature off.
//!
//! Mapping (phys to MJCF):
//! - One `<body>` per link, nested along the kin tree; the body frame is the link frame (pos and
//!   quat are the parent joint's origin). Link 0 is `<worldbody>`.
//! - Joints: revolute, continuous and wheel to `hinge`, prismatic to `slide`, spherical to
//!   `ball`, floating to `freejoint` (phys hangs free bodies from the world only), fixed to no
//!   joint (a welded body). Limits to `range`, damping, dry friction to `frictionloss`,
//!   armature (including the reflected rotor inertia phys adds), spring to `stiffness` and
//!   `springref`.
//! - Inertia: `<inertial>` with the link's mass, centre and full inertia about the centre
//!   (`inertiafromgeom="false"`, so geoms add none).
//! - Geoms: box, sphere, capsule and cylinder (all along z, as phys), convex hulls as mesh
//!   assets (MuJoCo collides with the hull of the vertices), planes on the world.
//! - Contacts: phys's fixed pair filter (different links, not both fixed, not parent and child,
//!   one articulation only with self collision) as explicit `<pair>` elements with the geometric
//!   mean friction phys uses; every geom has `contype = conaffinity = 0`, so MuJoCo makes no
//!   other pairs. Elliptic cone, condim 3. Limits and equalities get `solref` with a time
//!   constant of two steps (MuJoCo's stiffest stable setting), contacts MuJoCo's default
//!   0.02 s (stiffer contacts make sliding bodies hop), all critically damped.
//! - Actuators: a servo is a `general` actuator with gain `kp`, affine bias `-kp a - kd adot`
//!   (implicit in `implicitfast`), force range at stall times efficiency; a DC motor is a
//!   `general` actuator on voltage with gain `eta N kt / R`, back-EMF damping
//!   `eta N^2 kt ke / R` and the current limit as force range; an effort source is a `motor`.
//!   Actuator gear is `1 / gain` of phys's actuator map (`a = (q - offset) / gain`).
//! - Tendons: fixed tendons as `<fixed>` with phys's moment arms, routed ones as `<spatial>`
//!   through sites at the via points; the tendon motor is a `general` actuator whose force is
//!   the cable tension `k (a - e - slack) - c de/dt`, one-sided (cables only pull).
//! - Linkages (equality rows in phys) as `<equality><joint polycoef>`.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use viaform_kin::Iso3;
use viaform_kin::model::{JointKind, Limits};
use viaform_phys::actuator::ActuatorKind;
use viaform_phys::model::PhysModel;
use viaform_phys::world::{Integrator, Settings};
use viaform_phys::{PhysError, ShapeSpec};

/// Contact `solref` time constant, s (MuJoCo's default; never below two steps).
pub const CONTACT_TIMECONST: f64 = 0.02;

/// What an actuator becomes in MuJoCo, and what the runtime needs to drive it like phys.
#[derive(Clone, Debug, PartialEq)]
pub enum ActOut {
    /// Effort source: MuJoCo ctrl is the effort.
    Torque,
    /// Position servo (ctrl is set every step from the target, see the session).
    Servo,
    /// DC motor: ctrl is the voltage.
    Dc,
    /// Tendon motor: ctrl is the excursion (plus the cable damping term); `routed` tendons
    /// report the tension with the opposite sign of MuJoCo's actuator force.
    Tendon { routed: bool, stiffness: f64, damping: f64 },
}

/// Names that tie phys indices to MuJoCo objects.
#[derive(Clone, Debug, Default)]
pub struct MjcfMap {
    /// Body name per phys link (`world` for link 0).
    pub bodies: Vec<String>,
    /// MJCF joint name per phys joint (`None` for a fixed joint).
    pub joints: Vec<Option<String>>,
    /// Actuator name and kind per phys actuator.
    pub actuators: Vec<(String, ActOut)>,
    /// Notes about what MJCF cannot express exactly.
    pub notes: Vec<String>,
}

/// An exported model.
#[derive(Clone, Debug)]
pub struct Mjcf {
    pub xml: String,
    pub map: MjcfMap,
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

/// Shortest round-trip formatting (MJCF parses doubles).
fn f(x: f64) -> String {
    if x == 0.0 { "0".into() } else { format!("{x}") }
}

fn v3(v: &[f64]) -> String {
    format!("{} {} {}", f(v[0]), f(v[1]), f(v[2]))
}

fn pose_attrs(p: &Iso3) -> String {
    let t = p.translation.vector;
    let q = p.rotation.quaternion();
    let mut s = String::new();
    if t.norm() > 0.0 {
        let _ = write!(s, " pos=\"{}\"", v3(t.as_slice()));
    }
    if (q.w - 1.0).abs() > 1e-15 || q.i != 0.0 || q.j != 0.0 || q.k != 0.0 {
        let _ = write!(s, " quat=\"{} {} {} {}\"", f(q.w), f(q.i), f(q.j), f(q.k));
    }
    s
}

/// Unique names within one MJCF namespace.
#[derive(Default)]
struct Names(BTreeMap<String, usize>);

impl Names {
    fn take(&mut self, want: &str) -> String {
        let base = if want.is_empty() { "unnamed".to_string() } else { want.to_string() };
        let n = self.0.entry(base.clone()).or_insert(0);
        *n += 1;
        if *n == 1 { base } else { format!("{base}_{n}") }
    }
}

fn limit_range(l: &Limits) -> Option<(f64, f64)> {
    if !l.lower.is_finite() && !l.upper.is_finite() {
        return None;
    }
    let lo = if l.lower.is_finite() { l.lower } else { -1e6 };
    let hi = if l.upper.is_finite() { l.upper } else { 1e6 };
    Some((lo, hi))
}

/// The contact pairs phys may ever collide (its `Collider::new` filter), as geom index pairs.
pub fn contact_pairs(m: &PhysModel) -> Vec<(usize, usize)> {
    let fixed = |l: usize| m.support[l].is_empty();
    let root = |l: usize| if l == 0 { usize::MAX } else { m.joints[l - 1].root };
    let joined = |child: usize, parent: usize| child > 0 && m.joints[child - 1].parent == parent && m.joints[child - 1].kind != JointKind::Floating;
    let mut pairs = vec![];
    for i in 0..m.geoms.len() {
        for j in i + 1..m.geoms.len() {
            let (a, b) = (m.geoms[i].link, m.geoms[j].link);
            if a == b || (fixed(a) && fixed(b)) || joined(b, a) || joined(a, b) {
                continue;
            }
            if !fixed(a) && !fixed(b) && root(a) == root(b) && !m.self_collision {
                continue;
            }
            pairs.push((i, j));
        }
    }
    pairs
}

/// Exports `m` with the world settings `s` (time step, gravity, integrator) as MJCF.
pub fn export(m: &PhysModel, s: &Settings) -> Result<Mjcf, PhysError> {
    let mut map = MjcfMap::default();
    let nl = m.nlinks();
    let dt = s.dt;
    // Limits and equalities: two steps, the stiffest time constant MuJoCo resolves stably.
    let tc = 2.0 * dt;
    // Contacts: MuJoCo's default 0.02 s. Stiffer contacts make sliding bodies hop (the convex
    // model's lift-off, which phys corrects and MuJoCo does not), see mujoco/README.md.
    let ctc = CONTACT_TIMECONST.max(tc);
    let mut body_names = Names::default();
    body_names.take("world");
    map.bodies.push("world".into());
    for l in 1..nl {
        map.bodies.push(body_names.take(&m.kin.links[l].name));
    }
    let mut joint_names = Names::default();
    for (j, jt) in m.joints.iter().enumerate() {
        if jt.kind == JointKind::Floating && jt.parent != 0 {
            return Err(PhysError::new("engine.unsupported", format!("joint {}: MuJoCo free joints hang from the world", m.kin.joints[j].name)));
        }
        map.joints.push((jt.kind != JointKind::Fixed).then(|| joint_names.take(&m.kin.joints[j].name)));
    }
    // Geom names, meshes and sites.
    let mut geom_names = Names::default();
    let gnames: Vec<String> = m.geoms.iter().map(|g| geom_names.take(&g.name)).collect();
    let mut assets = String::new();
    let mut body_geoms: Vec<String> = vec![String::new(); nl];
    for (gi, g) in m.geoms.iter().enumerate() {
        let name = esc(&gnames[gi]);
        let pose = pose_attrs(&g.pose);
        let fr = f(g.friction);
        let line = match &g.spec {
            ShapeSpec::Box { size } => format!("<geom name=\"{name}\" type=\"box\" size=\"{}\"{pose} friction=\"{fr} 0.005 0.0001\"/>", v3(&[size[0] / 2.0, size[1] / 2.0, size[2] / 2.0])),
            ShapeSpec::Sphere { radius } => format!("<geom name=\"{name}\" type=\"sphere\" size=\"{}\"{pose} friction=\"{fr} 0.005 0.0001\"/>", f(*radius)),
            ShapeSpec::Capsule { length, radius } => format!("<geom name=\"{name}\" type=\"capsule\" size=\"{} {}\"{pose} friction=\"{fr} 0.005 0.0001\"/>", f(*radius), f(length / 2.0)),
            ShapeSpec::Cylinder { length, radius } => format!("<geom name=\"{name}\" type=\"cylinder\" size=\"{} {}\"{pose} friction=\"{fr} 0.005 0.0001\"/>", f(*radius), f(length / 2.0)),
            ShapeSpec::ConvexHull { points } => {
                let mesh = format!("{}_hull", gnames[gi]);
                let verts: Vec<String> = points.iter().map(|p| v3(p)).collect();
                let _ = writeln!(assets, "    <mesh name=\"{}\" vertex=\"{}\"/>", esc(&mesh), verts.join(" "));
                format!("<geom name=\"{name}\" type=\"mesh\" mesh=\"{}\"{pose} friction=\"{fr} 0.005 0.0001\"/>", esc(&mesh))
            }
            ShapeSpec::Plane { normal } => {
                let n = viaform_kin::Vec3::new(normal[0], normal[1], normal[2]).normalize();
                let r = nalgebra::UnitQuaternion::rotation_between(&viaform_kin::Vec3::z(), &n).unwrap_or_else(|| nalgebra::UnitQuaternion::from_axis_angle(&viaform_kin::Vec3::x_axis(), std::f64::consts::PI));
                let p = g.pose * Iso3::from_parts(nalgebra::Translation3::identity(), r);
                format!("<geom name=\"{name}\" type=\"plane\" size=\"0 0 1\"{} friction=\"{fr} 0.005 0.0001\"/>", pose_attrs(&p))
            }
        };
        body_geoms[g.link].push_str(&line);
        body_geoms[g.link].push('\n');
    }
    // Tendon sites (routed tendons).
    let mut site_lines: Vec<String> = vec![String::new(); nl];
    let mut tendon_xml = String::new();
    let mut tendon_names = Names::default();
    let mut tnames = vec![];
    for (ti, t) in m.tendons.iter().enumerate() {
        let tname = tendon_names.take(&t.name);
        if t.routing.len() >= 2 {
            let mut sites = vec![];
            for (k, (link, p)) in t.routing.iter().enumerate() {
                let sname = format!("tendon{ti}_via{k}");
                let _ = writeln!(site_lines[*link], "<site name=\"{sname}\" pos=\"{}\" size=\"0.002\"/>", v3(p.as_slice()));
                sites.push(sname);
            }
            let _ = writeln!(tendon_xml, "    <spatial name=\"{}\" width=\"0.001\">", esc(&tname));
            for sname in sites {
                let _ = writeln!(tendon_xml, "      <site site=\"{sname}\"/>");
            }
            tendon_xml.push_str("    </spatial>\n");
        } else {
            let _ = writeln!(tendon_xml, "    <fixed name=\"{}\">", esc(&tname));
            for &(vi, r) in &t.arms {
                let j = m.dof_joint[vi];
                let jn = map.joints[j].clone().ok_or_else(|| PhysError::new("engine.unsupported", format!("tendon {}: fixed joint in its path", t.name)))?;
                let _ = writeln!(tendon_xml, "      <joint joint=\"{}\" coef=\"{}\"/>", esc(&jn), f(r));
            }
            tendon_xml.push_str("    </fixed>\n");
        }
        tnames.push(tname);
    }
    // Bodies, depth first.
    let mut children: Vec<Vec<usize>> = vec![vec![]; nl];
    for (j, jt) in m.joints.iter().enumerate() {
        children[jt.parent].push(j);
    }
    let mut world = String::new();
    world.push_str(&indent(&body_geoms[0], 4));
    world.push_str(&indent(&site_lines[0], 4));
    for &j in &children[0] {
        write_body(m, j, &children, &map, &body_geoms, &site_lines, 4, &mut world);
    }
    // Pairs.
    let mut contact = String::new();
    for (i, j) in contact_pairs(m) {
        let mu = (m.geoms[i].friction * m.geoms[j].friction).sqrt();
        let _ = writeln!(contact, "    <pair geom1=\"{}\" geom2=\"{}\" condim=\"3\" friction=\"{} {} 0.005 0.0001 0.0001\" solref=\"{} 1\"/>", esc(&gnames[i]), esc(&gnames[j]), f(mu), f(mu), f(ctc));
    }
    // Equalities.
    let mut equality = String::new();
    for e in &m.equalities {
        let (ja, jb) = (m.dof_joint[e.va], m.dof_joint[e.vb]);
        let (Some(na), Some(nb)) = (&map.joints[ja], &map.joints[jb]) else { continue };
        let _ = writeln!(equality, "    <joint joint1=\"{}\" joint2=\"{}\" polycoef=\"{} {} 0 0 0\"/>", esc(na), esc(nb), f(e.off_a - e.ratio * e.off_b), f(e.ratio));
    }
    // Actuators.
    let mut act_xml = String::new();
    let mut act_names = Names::default();
    for (a, kind) in m.actuators.iter().enumerate() {
        let name = act_names.take(&m.kin.actuators[a].name);
        let en = esc(&name);
        if let Some(ti) = m.tendons.iter().position(|t| t.actuator == a) {
            let t = &m.tendons[ti];
            let routed = t.routing.len() >= 2;
            let max = if t.max_tension.is_finite() { t.max_tension } else { 1e9 };
            let (k, c) = (t.stiffness, t.damping);
            if routed {
                let _ = writeln!(act_xml, "    <general name=\"{en}\" tendon=\"{}\" gainprm=\"{}\" biastype=\"affine\" biasprm=\"{} {} {}\" forcelimited=\"true\" forcerange=\"{} 0\"/>", esc(&tnames[ti]), f(-k), f(k * (t.length0 + t.slack)), f(-k), f(-c), f(-max));
            } else {
                let _ = writeln!(act_xml, "    <general name=\"{en}\" tendon=\"{}\" gainprm=\"{}\" biastype=\"affine\" biasprm=\"{} {} {}\" forcelimited=\"true\" forcerange=\"0 {}\"/>", esc(&tnames[ti]), f(k), f(-k * t.slack), f(-k), f(-c), f(max));
            }
            if !matches!(kind, ActuatorKind::TendonMotor { .. }) {
                return Err(PhysError::new("engine.unsupported", format!("actuator {name}: tendons take a tendon motor")));
            }
            map.actuators.push((name, ActOut::Tendon { routed, stiffness: k, damping: c }));
            continue;
        }
        let Some(am) = &m.actuator_map[a] else {
            return Err(PhysError::new("engine.unsupported", format!("actuator {name} drives no joint")));
        };
        let j = m.dof_joint[am.vi];
        let jn = esc(map.joints[j].as_ref().ok_or_else(|| PhysError::new("engine.unsupported", format!("actuator {name} drives a fixed joint")))?);
        let gear = f(1.0 / am.gain);
        let out = match kind {
            ActuatorKind::Torque => {
                let lim = m.kin.actuators[a].limits.effort;
                let range = if lim.is_finite() { format!(" ctrllimited=\"true\" ctrlrange=\"{} {}\"", f(-lim), f(lim)) } else { String::new() };
                let _ = writeln!(act_xml, "    <motor name=\"{en}\" joint=\"{jn}\" gear=\"{gear}\"{range}/>");
                ActOut::Torque
            }
            ActuatorKind::Servo(p) => {
                let (lo, hi) = p.torque_box(0.0);
                let _ = writeln!(act_xml, "    <general name=\"{en}\" joint=\"{jn}\" gear=\"{gear}\" gainprm=\"{}\" biastype=\"affine\" biasprm=\"{} {} {}\" forcelimited=\"true\" forcerange=\"{} {}\"/>", f(p.kp), f(p.kp * am.offset / am.gain), f(-p.kp), f(-p.kd), f(lo), f(hi));
                if p.backlash > 0.0 {
                    map.notes.push(format!("servo {name}: backlash {:.3} deg is not modelled in MuJoCo", p.backlash.to_degrees()));
                }
                ActOut::Servo
            }
            ActuatorKind::Dc(p) => {
                let g = p.efficiency * p.gear_ratio * p.kt;
                let _ = writeln!(act_xml, "    <general name=\"{en}\" joint=\"{jn}\" gear=\"{gear}\" gainprm=\"{}\" biastype=\"affine\" biasprm=\"0 0 {}\" ctrllimited=\"true\" ctrlrange=\"{} {}\" forcelimited=\"true\" forcerange=\"{} {}\"/>", f(g / p.resistance), f(-p.emf_damping()), f(-p.max_voltage), f(p.max_voltage), f(-g * p.max_current), f(g * p.max_current));
                if p.inductance > 0.0 {
                    map.notes.push(format!("DC motor {name}: armature inductance is not modelled in MuJoCo (current follows the voltage at once)"));
                }
                ActOut::Dc
            }
            ActuatorKind::TendonMotor { .. } => return Err(PhysError::new("engine.unsupported", format!("actuator {name}: a tendon motor without a tendon"))),
        };
        map.actuators.push((name, out));
    }
    if !m.rotors.is_empty() || !m.drags.is_empty() {
        return Err(PhysError::new("engine.unsupported", "rotors and aerodynamic drag (the drone) run on phys only"));
    }
    let integrator = match s.integrator {
        Integrator::Rk4 => "RK4",
        Integrator::SemiImplicit => "implicitfast",
    };
    let mut x = String::new();
    let _ = writeln!(x, "<!-- Exported by viaform-mujoco from a viaform-phys model. SI units, Z up. -->");
    let _ = writeln!(x, "<mujoco model=\"{}\">", esc(&m.kin.name));
    let _ = writeln!(x, "  <compiler angle=\"radian\" inertiafromgeom=\"false\" boundmass=\"1e-6\" boundinertia=\"1e-12\" balanceinertia=\"true\"/>");
    let _ = writeln!(x, "  <option timestep=\"{}\" gravity=\"{}\" integrator=\"{integrator}\" cone=\"elliptic\"/>", f(dt), v3(&s.gravity));
    let _ = writeln!(x, "  <default>\n    <joint solreflimit=\"{} 1\"/>\n    <geom contype=\"0\" conaffinity=\"0\" condim=\"3\" solref=\"{} 1\" rgba=\"0.7 0.72 0.75 1\"/>\n    <equality solref=\"{} 1\"/>\n  </default>", f(tc), f(ctc), f(tc));
    if !assets.is_empty() {
        let _ = writeln!(x, "  <asset>\n{assets}  </asset>");
    }
    let _ = writeln!(x, "  <worldbody>\n    <light pos=\"0 0 3\" dir=\"0 0 -1\" directional=\"true\"/>\n{world}  </worldbody>");
    for (tag, body) in [("contact", &contact), ("tendon", &tendon_xml), ("equality", &equality), ("actuator", &act_xml)] {
        if !body.is_empty() {
            let _ = writeln!(x, "  <{tag}>\n{body}  </{tag}>");
        }
    }
    x.push_str("</mujoco>\n");
    Ok(Mjcf { xml: x, map })
}

fn indent(s: &str, n: usize) -> String {
    let pad = " ".repeat(n);
    s.lines().map(|l| format!("{pad}{l}\n")).collect()
}

#[allow(clippy::too_many_arguments)]
fn write_body(m: &PhysModel, j: usize, children: &[Vec<usize>], map: &MjcfMap, geoms: &[String], sites: &[String], depth: usize, out: &mut String) {
    let jt = &m.joints[j];
    let kj = &m.kin.joints[j];
    let link = jt.child;
    let pad = " ".repeat(depth);
    let _ = writeln!(out, "{pad}<body name=\"{}\"{}>", esc(&map.bodies[link]), pose_attrs(&jt.origin));
    let inner = " ".repeat(depth + 2);
    // Inertial.
    let (mass, com, inertia) = match &m.kin.links[link].inertial {
        Some(i) => (i.mass, i.com, i.inertia),
        None => (1e-3, viaform_kin::Vec3::zeros(), [1e-9, 1e-9, 1e-9, 0.0, 0.0, 0.0]),
    };
    let _ = writeln!(out, "{inner}<inertial pos=\"{}\" mass=\"{}\" fullinertia=\"{} {} {} {} {} {}\"/>", v3(com.as_slice()), f(mass), f(inertia[0]), f(inertia[1]), f(inertia[2]), f(inertia[3]), f(inertia[4]), f(inertia[5]));
    // Joint.
    if let Some(name) = &map.joints[j] {
        let p = &m.params[j];
        let name = esc(name);
        match jt.kind {
            JointKind::Floating => {
                let _ = writeln!(out, "{inner}<freejoint name=\"{name}\"/>");
            }
            kind => {
                let ty = match kind {
                    JointKind::Prismatic => "slide",
                    JointKind::Spherical => "ball",
                    _ => "hinge",
                };
                let mut a = format!("{inner}<joint name=\"{name}\" type=\"{ty}\"");
                if kind != JointKind::Spherical {
                    let _ = write!(a, " axis=\"{}\"", v3(kj.axis.as_slice()));
                    if kind != JointKind::Continuous && kind != JointKind::Wheel
                        && let Some((lo, hi)) = limit_range(&kj.limits)
                    {
                        let _ = write!(a, " limited=\"true\" range=\"{} {}\"", f(lo), f(hi));
                    }
                }
                for (attr, v) in [("damping", p.damping), ("frictionloss", p.friction), ("armature", p.armature), ("stiffness", p.stiffness)] {
                    if v != 0.0 {
                        let _ = write!(a, " {attr}=\"{}\"", f(v));
                    }
                }
                if p.stiffness != 0.0 && p.rest != 0.0 {
                    let _ = write!(a, " springref=\"{}\"", f(p.rest));
                }
                a.push_str("/>\n");
                out.push_str(&a);
            }
        }
    }
    out.push_str(&indent(&geoms[link], depth + 2));
    out.push_str(&indent(&sites[link], depth + 2));
    for &c in &children[link] {
        write_body(m, c, children, map, geoms, sites, depth + 2, out);
    }
    let _ = writeln!(out, "{pad}</body>");
}
