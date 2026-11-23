//! The physical model: viaform-kin's kinematic tree plus what dynamics needs (spatial inertias,
//! motion subspaces, joint damping, friction, armature and springs), collision geometry,
//! actuators, tendons, rotors and drag elements.
//!
//! Every body is a link of the kin [`viaform_kin::Model`]; free objects (a cube on a table, the
//! drone's airframe) are links on a [`JointKind::Floating`] joint from the base, so one tree
//! holds the whole world and one set of algorithms runs it. Link 0 is the world (fixed).

use std::sync::Arc;

use nalgebra::{Point3, Unit};
use parry3d_f64::shape::SharedShape;
use serde::{Deserialize, Serialize};
use viaform_kin::model::{CouplingKind, Drive as KinDrive, Inertial, Joint, JointKind, Limits, Link};
use viaform_kin::{Iso3, Model as KinModel, Vec3};

use crate::actuator::{ActuatorKind, DcParams, ServoParams};
use crate::aero::{BodyDrag, Rotor};
use crate::error::{PhysError, invalid};
use crate::spatial::{M6, V6, inertia_matrix, rigid_inertia};

/// Per-joint dynamic parameters.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct JointParams {
    /// Viscous damping, N m s/rad or N s/m, treated implicitly.
    pub damping: f64,
    /// Coulomb (dry) friction, N m or N, a box constraint in the contact solver.
    pub friction: f64,
    /// Armature (reflected rotor inertia), kg m^2 or kg, added to the mass matrix diagonal.
    pub armature: f64,
    /// Spring to `rest`, N m/rad or N/m, treated implicitly (tendon finger return springs).
    pub stiffness: f64,
    /// Spring rest position, rad or m.
    pub rest: f64,
}

impl Default for JointParams {
    fn default() -> Self {
        JointParams { damping: 0.0, friction: 0.0, armature: 0.0, stiffness: 0.0, rest: 0.0 }
    }
}

/// A collision shape description (SI, in its own frame).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShapeSpec {
    /// A box with full edge lengths.
    Box { size: [f64; 3] },
    Sphere { radius: f64 },
    /// A capsule along the frame's z axis, `length` between the sphere centres.
    Capsule { length: f64, radius: f64 },
    /// A cylinder along the frame's z axis.
    Cylinder { length: f64, radius: f64 },
    /// The convex hull of points.
    ConvexHull { points: Vec<[f64; 3]> },
    /// A half space whose boundary passes through the frame origin, outward normal `normal`
    /// (the ground: normal +z).
    Plane {
        #[serde(default = "plus_z")]
        normal: [f64; 3],
    },
}

fn plus_z() -> [f64; 3] {
    [0.0, 0.0, 1.0]
}

impl ShapeSpec {
    /// The parry shape.
    pub fn build(&self) -> Result<SharedShape, PhysError> {
        let pos = |x: f64, what: &str| if x > 0.0 && x.is_finite() { Ok(x) } else { Err(invalid(format!("shape {what} must be positive"))) };
        Ok(match self {
            ShapeSpec::Box { size } => SharedShape::cuboid(pos(size[0], "size")? / 2.0, pos(size[1], "size")? / 2.0, pos(size[2], "size")? / 2.0),
            ShapeSpec::Sphere { radius } => SharedShape::ball(pos(*radius, "radius")?),
            ShapeSpec::Capsule { length, radius } => SharedShape::capsule_z(pos(*length, "length")? / 2.0, pos(*radius, "radius")?),
            ShapeSpec::Cylinder { length, radius } => SharedShape::cylinder(pos(*length, "length")? / 2.0, pos(*radius, "radius")?),
            ShapeSpec::ConvexHull { points } => {
                let pts: Vec<Point3<f64>> = points.iter().map(|p| Point3::new(p[0], p[1], p[2])).collect();
                SharedShape::convex_hull(&pts).ok_or_else(|| invalid("convex hull: the points span no volume"))?
            }
            ShapeSpec::Plane { normal } => {
                let n = Vec3::new(normal[0], normal[1], normal[2]);
                if !(n.norm() > 1e-12) {
                    return Err(invalid("plane normal is zero"));
                }
                SharedShape::halfspace(Unit::new_normalize(n))
            }
        })
    }

    /// The pose of the parry shape in the spec's frame: parry's cylinder runs along y, the
    /// spec's along z, so it turns a quarter turn about x; every other shape is identity.
    pub fn parry_frame(&self) -> Iso3 {
        match self {
            ShapeSpec::Cylinder { .. } => Iso3::rotation(Vec3::x() * std::f64::consts::FRAC_PI_2),
            _ => Iso3::identity(),
        }
    }

    /// The vertices of a polyhedral shape (box corners, hull points) in the spec's frame. A
    /// plane meets these vertex by vertex, which keeps every point of a face with more than four
    /// vertices (parry's polygon features stop at four).
    pub fn vertices(&self, shape: &SharedShape) -> Vec<Vec3> {
        match self {
            ShapeSpec::Box { size } => {
                let h = Vec3::new(size[0], size[1], size[2]) / 2.0;
                (0..8).map(|k| Vec3::new(if k & 1 == 0 { -h.x } else { h.x }, if k & 2 == 0 { -h.y } else { h.y }, if k & 4 == 0 { -h.z } else { h.z })).collect()
            }
            ShapeSpec::ConvexHull { .. } => shape.as_convex_polyhedron().map(|c| c.points().iter().map(|p| p.coords).collect()).unwrap_or_default(),
            _ => vec![],
        }
    }

    /// Whether the shape has a volume (a plane does not).
    pub fn has_volume(&self) -> bool {
        !matches!(self, ShapeSpec::Plane { .. })
    }
}

/// A collision geometry fixed on a link.
#[derive(Clone)]
pub struct Geom {
    pub name: String,
    pub link: usize,
    pub spec: ShapeSpec,
    pub shape: SharedShape,
    /// Pose of the shape in the link frame (the spec's frame).
    pub pose: Iso3,
    /// Pose of the parry shape in the link frame (`pose` times the spec's parry frame).
    pub shape_pose: Iso3,
    /// Polyhedron vertices in the link frame (empty for curved shapes and planes).
    pub vertices: Vec<Vec3>,
    /// Coulomb friction coefficient (pairs use the geometric mean).
    pub friction: f64,
}

impl std::fmt::Debug for Geom {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Geom").field("name", &self.name).field("link", &self.link).field("spec", &self.spec).finish()
    }
}

/// Contact compliance (Castro, Permenter and Han 2023, the SAP model): per contact point a
/// stiffness and a dissipation time scale, a near-rigid floor on the regularisation, and the
/// friction regularisation `sigma`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct ContactParams {
    /// Point stiffness, N/m.
    pub stiffness: f64,
    /// Dissipation time scale tau_d, s (Hunt-Crossley style linear damping `k tau_d`).
    pub dissipation: f64,
    /// Near-rigid parameter beta (SAP section V.C): the normal regularisation never goes below
    /// `beta^2 / (4 pi^2) w`, which keeps stiff contacts resolved by one time step.
    pub beta: f64,
    /// Friction regularisation sigma: tangential `R_t = sigma w`. Stiction creep is
    /// `sigma w F_t dt` per step.
    pub sigma: f64,
    /// Contacts are generated up to this separation, m (speculative contacts).
    pub margin: f64,
}

impl Default for ContactParams {
    fn default() -> Self {
        ContactParams { stiffness: 1e6, dissipation: 0.002, beta: 1.0, sigma: 1e-4, margin: 0.002 }
    }
}

/// One joint as dynamics sees it.
#[derive(Clone, Debug)]
pub struct JointInfo {
    pub kind: JointKind,
    /// Parent link.
    pub parent: usize,
    /// Child link (`joint index + 1`).
    pub child: usize,
    pub qo: usize,
    pub nq: usize,
    pub vo: usize,
    pub nv: usize,
    /// Motion subspace in the child frame, `[angular; linear]` columns `0..nv`.
    pub s: M6,
    /// First column (the whole subspace of a scalar joint).
    pub s0: V6,
    pub origin: Iso3,
    /// The root joint of this joint's articulation (the first joint below link 0).
    pub root: usize,
}

/// A fixed tendon or a routed tendon from a kin coupling (E-13, RUST-ENGINES 6.2).
#[derive(Clone, Debug)]
pub struct TendonModel {
    pub name: String,
    /// The kin coupling.
    pub coupling: usize,
    /// The tendon actuator (excursion, m, pull positive).
    pub actuator: usize,
    /// Cable stiffness, N/m.
    pub stiffness: f64,
    /// Slack, m.
    pub slack: f64,
    /// Cable damping, N s/m.
    pub damping: f64,
    /// Largest tension, N.
    pub max_tension: f64,
    /// Via points `(link, point in link frame)`; empty for a fixed tendon.
    pub routing: Vec<(usize, Vec3)>,
    /// Fixed moment arms per joint `(v index, r)` for a fixed tendon (`r = -dL/dq`).
    pub arms: Vec<(usize, f64)>,
    /// Path length at the neutral configuration, m.
    pub length0: f64,
}

/// An equality row that keeps a linkage's joints on their coupling ratio:
/// `q[a] - off_a = ratio (q[b] - off_b)`.
#[derive(Clone, Debug)]
pub struct Equality {
    pub qa: usize,
    pub va: usize,
    pub off_a: f64,
    pub qb: usize,
    pub vb: usize,
    pub off_b: f64,
    pub ratio: f64,
}

/// How an actuator drives its joint: `dof` and the scale `a = (q[dof] - offset) / gain`.
#[derive(Clone, Debug)]
pub struct ActuatorMap {
    pub qi: usize,
    pub vi: usize,
    pub gain: f64,
    pub offset: f64,
}

/// The physical model. Built with [`ModelBuilder`], shared by every world and batch env.
#[derive(Clone, Debug)]
pub struct PhysModel {
    pub kin: KinModel,
    pub joints: Vec<JointInfo>,
    pub inertia: Vec<M6>,
    pub mass: Vec<f64>,
    pub com: Vec<Vec3>,
    pub params: Vec<JointParams>,
    /// Per link, the velocity indices that move it (sorted).
    pub support: Vec<Vec<usize>>,
    /// Per velocity index, its joint.
    pub dof_joint: Vec<usize>,
    pub geoms: Vec<Geom>,
    pub contact: ContactParams,
    /// Collide links of one articulation with each other (adjacent links never collide).
    pub self_collision: bool,
    pub actuators: Vec<ActuatorKind>,
    pub actuator_map: Vec<Option<ActuatorMap>>,
    pub tendons: Vec<TendonModel>,
    pub equalities: Vec<Equality>,
    pub rotors: Vec<Rotor>,
    pub drags: Vec<BodyDrag>,
    /// Notes about defaults that were filled in (missing masses).
    pub notes: Vec<String>,
}

impl PhysModel {
    pub fn nq(&self) -> usize {
        self.kin.nq()
    }
    pub fn nv(&self) -> usize {
        self.kin.nv()
    }
    pub fn nlinks(&self) -> usize {
        self.kin.links.len()
    }
    pub fn link(&self, name: &str) -> Option<usize> {
        self.kin.link_index(name)
    }
    /// Joint index of the joint whose child is `link`.
    pub fn joint_of(&self, link: usize) -> Option<usize> {
        if link == 0 { None } else { Some(link - 1) }
    }
    /// Total mass of the moving links.
    pub fn total_mass(&self) -> f64 {
        self.mass.iter().skip(1).sum()
    }
    /// Whether `link` is an ancestor of `other` (or equal).
    pub fn is_ancestor(&self, link: usize, mut other: usize) -> bool {
        loop {
            if other == link {
                return true;
            }
            if other == 0 {
                return false;
            }
            other = self.joints[other - 1].parent;
        }
    }
}

/// Builds a [`PhysModel`] from a kin model plus free bodies, shapes, actuators and force elements.
#[derive(Clone, Debug)]
pub struct ModelBuilder {
    pub kin: KinModel,
    pub params: Vec<JointParams>,
    pub geoms: Vec<(usize, String, ShapeSpec, Iso3, f64)>,
    pub contact: ContactParams,
    pub self_collision: bool,
    pub actuators: Vec<Option<ActuatorKind>>,
    pub tendon_damping: Vec<(usize, f64)>,
    pub rotors: Vec<Rotor>,
    pub drags: Vec<BodyDrag>,
}

impl ModelBuilder {
    /// Starts from a kinematic model (normalised by kin).
    pub fn new(kin: KinModel) -> Self {
        let nj = kin.joints.len();
        let na = kin.actuators.len();
        ModelBuilder {
            kin,
            params: vec![JointParams::default(); nj],
            geoms: vec![],
            contact: ContactParams::default(),
            self_collision: false,
            actuators: vec![None; na],
            tendon_damping: vec![],
            rotors: vec![],
            drags: vec![],
        }
    }

    /// An empty world (only the fixed base link `world`).
    pub fn empty() -> Self {
        let kin = KinModel { name: "world".into(), links: vec![Link { name: "world".into(), inertial: None }], joints: vec![], actuators: vec![], couplings: vec![], end_effectors: vec![] };
        ModelBuilder::new(kin)
    }

    /// Adds a free rigid body (floating joint from the world) with the given mass properties;
    /// `pose` is its initial pose (written into the joint origin, so `q = 0` places it there).
    /// Returns the link index.
    pub fn free_body(&mut self, name: &str, mass: f64, com: Vec3, inertia: [f64; 6], pose: Iso3) -> usize {
        let link = self.kin.links.len();
        self.kin.links.push(Link { name: name.into(), inertial: Some(Inertial { mass, com, inertia }) });
        self.kin.joints.push(Joint { name: format!("{name}_free"), kind: JointKind::Floating, parent: 0, origin: pose, axis: Vec3::z(), limits: Limits::default() });
        self.params.push(JointParams::default());
        link
    }

    /// A free body with the mass properties of a shape of uniform density (kg/m^3), and that
    /// shape as its collision geometry.
    pub fn free_shape(&mut self, name: &str, spec: ShapeSpec, mass: f64, pose: Iso3, friction: f64) -> Result<usize, PhysError> {
        let shape = spec.build()?;
        let mp = shape.mass_properties(1.0);
        if !(mp.mass() > 0.0) {
            return Err(invalid(format!("{name}: the shape has no volume")));
        }
        let scale = mass / mp.mass();
        let r = spec.parry_frame().rotation.to_rotation_matrix();
        let i = r.matrix() * mp.reconstruct_inertia_matrix() * r.matrix().transpose() * scale;
        let c = r * mp.local_com.coords;
        let link = self.free_body(name, mass, c, [i[(0, 0)], i[(1, 1)], i[(2, 2)], i[(0, 1)], i[(0, 2)], i[(1, 2)]], pose);
        self.geoms.push((link, name.into(), spec, Iso3::identity(), friction));
        Ok(link)
    }

    /// Adds a collision shape on `link` at `pose` (link frame).
    pub fn geom(&mut self, link: usize, name: &str, spec: ShapeSpec, pose: Iso3, friction: f64) {
        self.geoms.push((link, name.into(), spec, pose, friction));
    }

    /// The ground plane z = 0 on the world.
    pub fn ground(&mut self, friction: f64) {
        self.geom(0, "ground", ShapeSpec::Plane { normal: [0.0, 0.0, 1.0] }, Iso3::identity(), friction);
    }

    pub fn joint_params(&mut self, joint: usize) -> &mut JointParams {
        &mut self.params[joint]
    }

    /// Sets how actuator `a` (kin actuator index) is driven.
    pub fn actuator(&mut self, a: usize, kind: ActuatorKind) {
        if self.actuators.len() < self.kin.actuators.len() {
            self.actuators.resize(self.kin.actuators.len(), None);
        }
        self.actuators[a] = Some(kind);
    }

    /// Finishes the model: normalises the kin model, computes inertias and subspaces, checks
    /// shapes and actuators.
    pub fn build(mut self) -> Result<Arc<PhysModel>, PhysError> {
        self.kin.normalize()?;
        let kin = self.kin;
        let nj = kin.joints.len();
        let mut params = self.params;
        params.resize(nj, JointParams::default());
        let mut notes = vec![];
        // Inertias.
        let mut inertia = Vec::with_capacity(kin.links.len());
        let mut mass = Vec::with_capacity(kin.links.len());
        let mut com = Vec::with_capacity(kin.links.len());
        for (li, l) in kin.links.iter().enumerate() {
            let (m, c, i) = match &l.inertial {
                Some(x) => (x.mass, x.com, inertia_matrix(&x.inertia)),
                None if li == 0 => (0.0, Vec3::zeros(), nalgebra::Matrix3::zeros()),
                None => {
                    notes.push(format!("link {} has no mass properties: 1 g, 1e-9 kg m^2 used", l.name));
                    (1e-3, Vec3::zeros(), nalgebra::Matrix3::identity() * 1e-9)
                }
            };
            if !(m >= 0.0) || !m.is_finite() || i.iter().any(|v| !v.is_finite()) {
                return Err(invalid(format!("link {} has an invalid mass or inertia", l.name)));
            }
            if li > 0 && m <= 0.0 {
                return Err(invalid(format!("link {} has zero mass", l.name)));
            }
            inertia.push(rigid_inertia(m, &c, &i));
            mass.push(m);
            com.push(c);
        }
        // Joints.
        let qo = kin.q_offsets();
        let vo = kin.v_offsets();
        let mut joints: Vec<JointInfo> = Vec::with_capacity(nj);
        let mut dof_joint = vec![0; kin.nv()];
        for (j, jt) in kin.joints.iter().enumerate() {
            let mut s = M6::zeros();
            let a = jt.axis;
            match jt.kind {
                JointKind::Revolute | JointKind::Continuous | JointKind::Wheel => s.set_column(0, &V6::new(a.x, a.y, a.z, 0.0, 0.0, 0.0)),
                JointKind::Prismatic => s.set_column(0, &V6::new(0.0, 0.0, 0.0, a.x, a.y, a.z)),
                JointKind::Spherical => {
                    for k in 0..3 {
                        s[(k, k)] = 1.0;
                    }
                }
                JointKind::Floating => {
                    // v = [v_lin; w] in the child frame, spatial = [w; v_lin].
                    for k in 0..3 {
                        s[(3 + k, k)] = 1.0;
                        s[(k, 3 + k)] = 1.0;
                    }
                }
                JointKind::Fixed => {}
            }
            let nv = jt.kind.nv();
            for k in 0..nv {
                dof_joint[vo[j] + k] = j;
            }
            let root = if jt.parent == 0 { j } else { joints[jt.parent - 1].root };
            joints.push(JointInfo { kind: jt.kind, parent: jt.parent, child: j + 1, qo: qo[j], nq: jt.kind.nq(), vo: vo[j], nv, s, s0: s.column(0).into_owned(), origin: jt.origin, root });
        }
        let mut support = vec![vec![]; kin.links.len()];
        for j in 0..nj {
            let mut sup = support[joints[j].parent].clone();
            sup.extend(joints[j].vo..joints[j].vo + joints[j].nv);
            sup.sort_unstable();
            support[j + 1] = sup;
        }
        // Geometry.
        let mut geoms = vec![];
        for (link, name, spec, pose, friction) in self.geoms {
            if link >= kin.links.len() {
                return Err(invalid(format!("shape {name} is on link {link}, which does not exist")));
            }
            if !spec.has_volume() && link != 0 {
                return Err(invalid(format!("shape {name}: a plane can only be fixed to the world")));
            }
            if !(friction >= 0.0) {
                return Err(invalid(format!("shape {name}: friction must be zero or more")));
            }
            let shape = spec.build()?;
            let vertices = spec.vertices(&shape).into_iter().map(|v| pose.transform_vector(&v) + pose.translation.vector).collect();
            let shape_pose = pose * spec.parry_frame();
            geoms.push(Geom { name, link, shape, spec, pose, shape_pose, vertices, friction });
        }
        // Actuators: map each to its coupling's first joint.
        let na = kin.actuators.len();
        let mut acts = self.actuators;
        acts.resize(na, None);
        let mut actuators = Vec::with_capacity(na);
        let mut actuator_map = vec![None; na];
        let mut equalities = vec![];
        let mut tendons = vec![];
        for (ci, cp) in kin.couplings.iter().enumerate() {
            let ncols = cp.actuators.len();
            match &cp.kind {
                CouplingKind::Linear if kin.actuators[cp.actuators[0]].drive == KinDrive::Motor || ncols > 1 => {
                    if ncols != 1 {
                        return Err(invalid(format!("coupling {}: phys drives a linkage from one actuator", cp.name)));
                    }
                    let m0 = cp.matrix[0];
                    if m0 == 0.0 {
                        return Err(invalid(format!("coupling {}: the first joint has a zero ratio", cp.name)));
                    }
                    let j0 = cp.joints[0];
                    actuator_map[cp.actuators[0]] = Some(ActuatorMap { qi: qo[j0], vi: vo[j0], gain: m0, offset: cp.offset[0] });
                    for r in 1..cp.joints.len() {
                        let jr = cp.joints[r];
                        equalities.push(Equality { qa: qo[jr], va: vo[jr], off_a: cp.offset[r], qb: qo[j0], vb: vo[j0], off_b: cp.offset[0], ratio: cp.matrix[r] / m0 });
                    }
                }
                _ => {
                    // A tendon: routed (kin tendon with via points) or fixed (moment arms from the
                    // matrix: q = m a with m = r / sum r^2, so r = m / sum m^2).
                    if ncols != 1 {
                        return Err(invalid(format!("tendon {}: one actuator per tendon", cp.name)));
                    }
                    let (routing, stiffness, slack) = match &cp.kind {
                        CouplingKind::Tendon { routing, stiffness, slack } => (routing.iter().map(|p| (p.link, p.pos)).collect::<Vec<_>>(), *stiffness, *slack),
                        CouplingKind::Linear => (vec![], 0.0, 0.0),
                    };
                    let m2: f64 = cp.matrix.iter().map(|x| x * x).sum();
                    let arms = if routing.len() >= 2 { vec![] } else { cp.joints.iter().zip(&cp.matrix).map(|(&j, &m)| (vo[j], m / m2)).collect() };
                    let a = cp.actuators[0];
                    let stiffness = if stiffness > 0.0 { stiffness } else { 2e4 };
                    let max_tension = kin.actuators[a].limits.effort;
                    let damping = self.tendon_damping.iter().find(|(c, _)| *c == ci).map(|x| x.1).unwrap_or(0.02 * stiffness.sqrt());
                    tendons.push(TendonModel { name: cp.name.clone(), coupling: ci, actuator: a, stiffness, slack, damping, max_tension, routing, arms, length0: 0.0 });
                }
            }
        }
        for (a, kind) in acts.into_iter().enumerate() {
            let is_tendon = tendons.iter().any(|t| t.actuator == a);
            let kind = match kind {
                Some(k) => k,
                None if is_tendon => ActuatorKind::TendonMotor { max_speed: f64::INFINITY },
                None => ActuatorKind::Torque,
            };
            match (&kind, is_tendon) {
                (ActuatorKind::TendonMotor { .. }, false) => return Err(invalid(format!("actuator {} is not a tendon", kin.actuators[a].name))),
                (ActuatorKind::TendonMotor { .. }, true) => {}
                (_, true) => return Err(invalid(format!("actuator {} drives a tendon: use a tendon motor", kin.actuators[a].name))),
                _ => {}
            }
            if let ActuatorKind::Servo(p) = &kind {
                p.check().map_err(|m| invalid(format!("servo {}: {m}", kin.actuators[a].name)))?;
            }
            if let ActuatorKind::Dc(p) = &kind {
                p.check().map_err(|m| invalid(format!("DC motor {}: {m}", kin.actuators[a].name)))?;
            }
            actuators.push(kind);
        }
        // Reflected rotor inertia of servos and DC motors.
        for (a, kind) in actuators.iter().enumerate() {
            let arm = match kind {
                ActuatorKind::Servo(ServoParams { rotor_inertia, gear_ratio, .. }) | ActuatorKind::Dc(DcParams { rotor_inertia, gear_ratio, .. }) => rotor_inertia * gear_ratio * gear_ratio,
                _ => 0.0,
            };
            if let (Some(m), true) = (&actuator_map[a], arm > 0.0) {
                let j = dof_joint[m.vi];
                params[j].armature += arm / (m.gain * m.gain);
            }
        }
        for r in &self.rotors {
            if r.link == 0 || r.link >= kin.links.len() {
                return Err(invalid(format!("rotor {} must be on a moving link", r.name)));
            }
        }
        for d in &self.drags {
            if d.link == 0 || d.link >= kin.links.len() {
                return Err(invalid("a drag element must be on a moving link"));
            }
        }
        let mut model = PhysModel {
            kin,
            joints,
            inertia,
            mass,
            com,
            params,
            support,
            dof_joint,
            geoms,
            contact: self.contact,
            self_collision: self.self_collision,
            actuators,
            actuator_map,
            tendons,
            equalities,
            rotors: self.rotors,
            drags: self.drags,
            notes,
        };
        // Neutral tendon lengths.
        let q0 = model.kin.neutral();
        let poses = model.kin.fk(&q0)?;
        for t in &mut model.tendons {
            t.length0 = crate::tendon::path_length(&t.routing, &poses);
        }
        Ok(Arc::new(model))
    }
}
