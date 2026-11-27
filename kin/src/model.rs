//! The kinematic model (RUST-ENGINES 4.1): a tree of links joined by joints, named tool frames,
//! actuators and the couplings (gears, linkages, tendons) that map actuators to joints.
//!
//! Conventions (stable, `phys` builds on them):
//! - SI units, right-handed, Z up. Poses are [`Iso3`] in f64.
//! - `links[0]` is the base, fixed to the world (its pose is the identity). A floating robot
//!   (drone, mobile base) uses a [`JointKind::Floating`] joint from the base (the world) to its body.
//! - Joint `i` joins `joints[i].parent` (a link index, `< i + 1`) to its child link `i + 1`, so
//!   `links.len() == joints.len() + 1` and links are in topological order.
//! - The child pose is `T_child = T_parent * origin * motion(q_i)`, the axis is expressed in the
//!   joint frame (`T_parent * origin`).
//! - Configuration `q` (length [`Model::nq`]) and velocity `v` (length [`Model::nv`]) are stacked
//!   joint by joint. Scalar joints use one entry in both. A spherical joint uses a unit quaternion
//!   `[w, x, y, z]` in `q` and an angular velocity in the child frame in `v` (3). A floating joint
//!   uses `[x, y, z, qw, qx, qy, qz]` in `q` (position in the joint frame) and
//!   `[vx, vy, vz, wx, wy, wz]` in the child frame in `v` (6). Integrate with [`Model::integrate`].
//! - Every movable scalar joint is driven by exactly one coupling. [`Model::normalize`] adds a
//!   motor actuator and an identity coupling for each joint the file leaves uncoupled
//!   ("motor per joint"), so actuator space is always explicit.

use nalgebra::DMatrix;
use serde::{Deserialize, Serialize};

use crate::error::{KinError, codes};
use crate::math::{Iso3, Vec3, serde_iso, serde_lower, serde_upper, serde_vec3};

/// Index of a tool frame in [`Model::end_effectors`].
pub type FrameId = usize;

/// The kinematic model.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Model {
    /// Free text name.
    #[serde(default)]
    pub name: String,
    /// Links; index 0 = base (fixed to the world).
    pub links: Vec<Link>,
    /// Joint `i` connects `joints[i].parent` to child link `i + 1`.
    pub joints: Vec<Joint>,
    /// Actuators (motors and tendons). Filled in by [`Model::normalize`] for uncoupled joints.
    #[serde(default)]
    pub actuators: Vec<Actuator>,
    /// Couplings from actuators to joints (E-13).
    #[serde(default)]
    pub couplings: Vec<Coupling>,
    /// Named tool frames (gripper tip, each fingertip).
    #[serde(default)]
    pub end_effectors: Vec<Frame>,
}

/// A rigid link.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Link {
    pub name: String,
    /// Mass properties, for `phys` (kin itself does not use them).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inertial: Option<Inertial>,
}

/// Mass properties of a link, in the link frame.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Inertial {
    /// kg.
    pub mass: f64,
    /// Centre of mass, m, link frame.
    #[serde(with = "serde_vec3")]
    pub com: Vec3,
    /// Inertia about the centre of mass, link axes, kg m^2: `[ixx, iyy, izz, ixy, ixz, iyz]`.
    pub inertia: [f64; 6],
}

/// A joint.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Joint {
    pub name: String,
    pub kind: JointKind,
    /// Parent link index (`< i + 1` for joint `i`).
    pub parent: usize,
    /// Joint frame in the parent link frame.
    #[serde(with = "serde_iso", default = "Iso3::identity")]
    pub origin: Iso3,
    /// Unit axis in the joint frame (revolute, continuous, wheel: rotation; prismatic:
    /// translation). Ignored by fixed, spherical and floating joints.
    #[serde(with = "serde_vec3", default = "Vec3::z")]
    pub axis: Vec3,
    #[serde(default)]
    pub limits: Limits,
}

/// Joint kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JointKind {
    /// Rotation about `axis`, rad, within limits.
    Revolute,
    /// Translation along `axis`, m, within limits.
    Prismatic,
    /// Rotation about `axis` without limits.
    Continuous,
    /// No motion.
    Fixed,
    /// Ball joint: 3 rotational DOF. `limits.upper`, when finite, is the largest rotation angle
    /// from the joint frame (a cone plus twist bound), rad.
    Spherical,
    /// 6 DOF free body (drone, mobile base).
    Floating,
    /// Continuous rotation about `axis` (a wheel; `phys` adds rolling contact).
    Wheel,
}

impl JointKind {
    /// Entries in `q`.
    pub fn nq(self) -> usize {
        match self {
            JointKind::Fixed => 0,
            JointKind::Spherical => 4,
            JointKind::Floating => 7,
            _ => 1,
        }
    }
    /// Entries in `v` (degrees of freedom).
    pub fn nv(self) -> usize {
        match self {
            JointKind::Fixed => 0,
            JointKind::Spherical => 3,
            JointKind::Floating => 6,
            _ => 1,
        }
    }
    /// One scalar coordinate (revolute, prismatic, continuous, wheel).
    pub fn is_scalar(self) -> bool {
        matches!(self, JointKind::Revolute | JointKind::Prismatic | JointKind::Continuous | JointKind::Wheel)
    }
    /// Has finite position limits that IK and paths honour.
    pub fn is_bounded(self) -> bool {
        matches!(self, JointKind::Revolute | JointKind::Prismatic)
    }
}

/// Joint (or actuator) limits. Missing bounds are infinite (written as `null`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Limits {
    /// rad or m.
    #[serde(with = "serde_lower", default = "neg_inf")]
    pub lower: f64,
    /// rad or m.
    #[serde(with = "serde_upper", default = "pos_inf")]
    pub upper: f64,
    /// rad/s or m/s.
    #[serde(with = "serde_upper", default = "pos_inf")]
    pub velocity: f64,
    /// N m or N.
    #[serde(with = "serde_upper", default = "pos_inf")]
    pub effort: f64,
}

fn neg_inf() -> f64 {
    f64::NEG_INFINITY
}
fn pos_inf() -> f64 {
    f64::INFINITY
}

impl Default for Limits {
    fn default() -> Self {
        Limits { lower: f64::NEG_INFINITY, upper: f64::INFINITY, velocity: f64::INFINITY, effort: f64::INFINITY }
    }
}

impl Limits {
    /// Clamps `x` into `[lower, upper]`.
    pub fn clamp(&self, x: f64) -> f64 {
        x.max(self.lower).min(self.upper)
    }
    /// Mid range (0 when a bound is infinite).
    pub fn mid(&self) -> f64 {
        if self.lower.is_finite() && self.upper.is_finite() { 0.5 * (self.lower + self.upper) } else { self.clamp(0.0) }
    }
}

/// A named tool frame rigidly attached to a link.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Frame {
    pub name: String,
    pub link: usize,
    /// Frame pose in the link frame.
    #[serde(with = "serde_iso", default = "Iso3::identity")]
    pub offset: Iso3,
}

/// How an actuator drives (E-13).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Drive {
    /// A motor (with optional gearing or linkage to several joints).
    Motor,
    /// A tendon pulled by a motor; the actuator value is the tendon excursion (m, pull positive).
    Tendon,
}

/// An actuator.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Actuator {
    pub name: String,
    pub drive: Drive,
    /// Range of the actuator value (rad for motors, m of excursion for tendons).
    #[serde(default)]
    pub limits: Limits,
}

/// Maps actuators to joints: for each listed joint `joints[r]`,
/// `q[joints[r]] = sum_c matrix[r * actuators.len() + c] * a[actuators[c]] + offset[r]`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Coupling {
    #[serde(default)]
    pub name: String,
    pub kind: CouplingKind,
    /// Actuator indices (columns).
    pub actuators: Vec<usize>,
    /// Joint indices (rows); scalar movable joints only.
    pub joints: Vec<usize>,
    /// Row-major `joints.len() x actuators.len()`. A tendon coupling may leave it empty: then
    /// [`Model::normalize`] fills it from the routing (see [`Model::tendon_matrix`]).
    #[serde(default)]
    pub matrix: Vec<f64>,
    /// Joint offsets (zeros when empty).
    #[serde(default)]
    pub offset: Vec<f64>,
}

/// Coupling kinds.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CouplingKind {
    /// Gears, belts, linkages: a fixed linear map.
    Linear,
    /// A tendon routed through via points. `stiffness` (N/m) and `slack` (m) are for `phys`;
    /// kin maps excursion to joints with the coupling matrix (slack is not modelled in kin).
    Tendon {
        routing: Vec<TendonPoint>,
        #[serde(default)]
        stiffness: f64,
        #[serde(default)]
        slack: f64,
    },
}

/// A tendon via point fixed on a link.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TendonPoint {
    pub link: usize,
    /// Point in the link frame, m.
    #[serde(with = "serde_vec3")]
    pub pos: Vec3,
}

/// The variables IK works in ("drive space"): every actuator, then every DOF of the passive
/// spherical and floating joints. `C` maps a drive step to a joint velocity step: `dv = C dz`.
#[derive(Clone, Debug)]
pub struct DriveMap {
    /// Number of actuators (the first `na` drive variables).
    pub na: usize,
    /// Number of drive variables.
    pub nz: usize,
    /// `nv x nz`.
    pub c: DMatrix<f64>,
    /// For each passive manifold joint: (joint, first v index, first z index, dof count).
    pub passive: Vec<(usize, usize, usize, usize)>,
    /// For each drive variable: the joints it moves (to honour `locked` joints).
    pub drives_joints: Vec<Vec<usize>>,
}

fn invalid(msg: impl Into<String>) -> KinError {
    KinError::new(codes::MODEL_INVALID, msg)
}

impl Model {
    /// Parses a model from JSON and [normalizes](Model::normalize) it.
    pub fn from_json(text: &str) -> Result<Model, KinError> {
        let mut m: Model = serde_json::from_str(text).map_err(|e| KinError::new(codes::MODEL_PARSE, e.to_string()))?;
        m.normalize()?;
        Ok(m)
    }

    /// Parses a model from a JSON value and normalizes it.
    pub fn from_value(v: &serde_json::Value) -> Result<Model, KinError> {
        let mut m: Model = serde_json::from_value(v.clone()).map_err(|e| KinError::new(codes::MODEL_PARSE, e.to_string()))?;
        m.normalize()?;
        Ok(m)
    }

    /// The model as JSON (round-trips through [`Model::from_json`]).
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_default()
    }

    /// Checks the model and completes it: normalises axes, opens the limits of continuous and
    /// wheel joints, adds a motor actuator and identity coupling for each uncoupled movable scalar
    /// joint, fills empty tendon matrices from their routing. Idempotent.
    pub fn normalize(&mut self) -> Result<(), KinError> {
        if self.links.is_empty() {
            return Err(invalid("a model needs at least the base link"));
        }
        if self.links.len() != self.joints.len() + 1 {
            return Err(invalid(format!("{} links for {} joints: joint i must have child link i + 1", self.links.len(), self.joints.len())));
        }
        for (i, j) in self.joints.iter_mut().enumerate() {
            if j.parent > i {
                return Err(invalid(format!("joint {} ({}) has parent link {}, which must be below {}", i, j.name, j.parent, i + 1)));
            }
            if j.kind.is_scalar() {
                let n = j.axis.norm();
                if !(n > 1e-12) || !n.is_finite() {
                    return Err(invalid(format!("joint {} has a zero axis", j.name)));
                }
                j.axis /= n;
            }
            if matches!(j.kind, JointKind::Continuous | JointKind::Wheel | JointKind::Floating | JointKind::Fixed) {
                j.limits.lower = f64::NEG_INFINITY;
                j.limits.upper = f64::INFINITY;
            }
            if j.kind == JointKind::Spherical {
                j.limits.lower = f64::NEG_INFINITY;
            }
            if j.limits.lower.is_nan() || j.limits.upper.is_nan() || j.limits.lower > j.limits.upper {
                return Err(invalid(format!("joint {} has limits lower > upper", j.name)));
            }
        }
        for f in &self.end_effectors {
            if f.link >= self.links.len() {
                return Err(invalid(format!("frame {} is on link {}, which does not exist", f.name, f.link)));
            }
        }
        // Couplings.
        let mut owner = vec![usize::MAX; self.joints.len()];
        for (ci, c) in self.couplings.iter_mut().enumerate() {
            if c.actuators.is_empty() || c.joints.is_empty() {
                return Err(invalid(format!("coupling {ci} needs actuators and joints")));
            }
            for &a in &c.actuators {
                if a >= self.actuators.len() {
                    return Err(invalid(format!("coupling {ci} uses actuator {a}, which does not exist")));
                }
            }
            for &j in &c.joints {
                let Some(joint) = self.joints.get(j) else { return Err(invalid(format!("coupling {ci} uses joint {j}, which does not exist"))) };
                if !joint.kind.is_scalar() {
                    return Err(invalid(format!("coupling {ci} drives joint {}, which is not a one-axis joint", joint.name)));
                }
                if owner[j] != usize::MAX {
                    return Err(invalid(format!("joint {} is driven by two couplings", joint.name)));
                }
                owner[j] = ci;
            }
            if c.offset.is_empty() {
                c.offset = vec![0.0; c.joints.len()];
            }
            if c.offset.len() != c.joints.len() {
                return Err(invalid(format!("coupling {ci}: offset needs {} values", c.joints.len())));
            }
            if let CouplingKind::Tendon { routing, .. } = &c.kind {
                for p in routing {
                    if p.link >= self.links.len() {
                        return Err(invalid(format!("coupling {ci}: tendon point on link {}, which does not exist", p.link)));
                    }
                }
                if c.matrix.is_empty() && routing.len() < 2 {
                    return Err(invalid(format!("coupling {ci}: a tendon without a matrix needs at least two via points")));
                }
            } else if c.matrix.is_empty() {
                return Err(invalid(format!("coupling {ci}: a linear coupling needs its matrix")));
            }
        }
        // Motor per joint for every uncoupled movable scalar joint.
        for j in 0..self.joints.len() {
            if self.joints[j].kind.is_scalar() && owner[j] == usize::MAX {
                let a = self.actuators.len();
                let joint = &self.joints[j];
                self.actuators.push(Actuator { name: joint.name.clone(), drive: Drive::Motor, limits: joint.limits });
                self.couplings.push(Coupling { name: joint.name.clone(), kind: CouplingKind::Linear, actuators: vec![a], joints: vec![j], matrix: vec![1.0], offset: vec![0.0] });
                owner[j] = self.couplings.len() - 1;
            }
        }
        // Tendon matrices from routing.
        for ci in 0..self.couplings.len() {
            if self.couplings[ci].matrix.is_empty() {
                if self.couplings[ci].actuators.len() != 1 {
                    return Err(invalid(format!("coupling {ci}: a matrix from routing needs exactly one actuator")));
                }
                let m = self.tendon_matrix(ci)?;
                self.couplings[ci].matrix = m;
            }
            let c = &self.couplings[ci];
            if c.matrix.len() != c.joints.len() * c.actuators.len() || c.matrix.iter().any(|v| !v.is_finite()) {
                return Err(invalid(format!("coupling {ci}: matrix needs {} finite values", c.joints.len() * c.actuators.len())));
            }
        }
        for a in &self.actuators {
            if a.limits.lower.is_nan() || a.limits.upper.is_nan() || a.limits.lower > a.limits.upper {
                return Err(invalid(format!("actuator {} has limits lower > upper", a.name)));
            }
        }
        Ok(())
    }

    /// Length of `q`.
    pub fn nq(&self) -> usize {
        self.joints.iter().map(|j| j.kind.nq()).sum()
    }

    /// Length of `v` (degrees of freedom).
    pub fn nv(&self) -> usize {
        self.joints.iter().map(|j| j.kind.nv()).sum()
    }

    /// Start of each joint's entries in `q`.
    pub fn q_offsets(&self) -> Vec<usize> {
        let mut o = Vec::with_capacity(self.joints.len());
        let mut k = 0;
        for j in &self.joints {
            o.push(k);
            k += j.kind.nq();
        }
        o
    }

    /// Start of each joint's entries in `v`.
    pub fn v_offsets(&self) -> Vec<usize> {
        let mut o = Vec::with_capacity(self.joints.len());
        let mut k = 0;
        for j in &self.joints {
            o.push(k);
            k += j.kind.nv();
        }
        o
    }

    /// The neutral configuration: scalar joints at 0 clamped into their limits, identity
    /// rotations, floating bodies at the joint frame.
    pub fn neutral(&self) -> Vec<f64> {
        let mut q = Vec::with_capacity(self.nq());
        for j in &self.joints {
            match j.kind {
                JointKind::Fixed => {}
                JointKind::Spherical => q.extend_from_slice(&[1.0, 0.0, 0.0, 0.0]),
                JointKind::Floating => q.extend_from_slice(&[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]),
                _ => q.push(j.limits.clamp(0.0)),
            }
        }
        q
    }

    /// Index of the link named `name`.
    pub fn link_index(&self, name: &str) -> Option<usize> {
        self.links.iter().position(|l| l.name == name)
    }
    /// Index of the joint named `name`.
    pub fn joint_index(&self, name: &str) -> Option<usize> {
        self.joints.iter().position(|j| j.name == name)
    }
    /// Index of the tool frame named `name`.
    pub fn frame_index(&self, name: &str) -> Option<FrameId> {
        self.end_effectors.iter().position(|f| f.name == name)
    }
    /// Index of the actuator named `name`.
    pub fn actuator_index(&self, name: &str) -> Option<usize> {
        self.actuators.iter().position(|a| a.name == name)
    }

    /// Checks `q` has length [`Model::nq`] and finite entries.
    pub fn check_q(&self, q: &[f64]) -> Result<(), KinError> {
        if q.len() != self.nq() {
            return Err(KinError::new(codes::BAD_VECTOR, format!("q has {} values, the model needs {}", q.len(), self.nq())));
        }
        if q.iter().any(|v| !v.is_finite()) {
            return Err(KinError::new(codes::BAD_VECTOR, "q has a value that is not finite"));
        }
        Ok(())
    }

    /// The drive space of IK (see [`DriveMap`]).
    pub fn drive_map(&self) -> DriveMap {
        let na = self.actuators.len();
        let vo = self.v_offsets();
        let mut passive = vec![];
        let mut nz = na;
        for (j, joint) in self.joints.iter().enumerate() {
            if matches!(joint.kind, JointKind::Spherical | JointKind::Floating) {
                passive.push((j, vo[j], nz, joint.kind.nv()));
                nz += joint.kind.nv();
            }
        }
        let mut c = DMatrix::zeros(self.nv(), nz);
        let mut drives_joints = vec![vec![]; nz];
        for cp in &self.couplings {
            let n = cp.actuators.len();
            for (r, &j) in cp.joints.iter().enumerate() {
                for (col, &a) in cp.actuators.iter().enumerate() {
                    let m = cp.matrix[r * n + col];
                    c[(vo[j], a)] = m;
                    if m != 0.0 {
                        drives_joints[a].push(j);
                    }
                }
            }
        }
        for &(j, v0, z0, d) in &passive {
            for k in 0..d {
                c[(v0 + k, z0 + k)] = 1.0;
                drives_joints[z0 + k].push(j);
            }
        }
        DriveMap { na, nz, c, passive, drives_joints }
    }

    /// Writes the coupled scalar joints of `q` from actuator values `a` (other entries of `q`
    /// are left as they are).
    pub fn apply_actuators(&self, a: &[f64], q: &mut [f64]) {
        let qo = self.q_offsets();
        for cp in &self.couplings {
            let n = cp.actuators.len();
            for (r, &j) in cp.joints.iter().enumerate() {
                let mut x = cp.offset[r];
                for (col, &ai) in cp.actuators.iter().enumerate() {
                    x += cp.matrix[r * n + col] * a[ai];
                }
                q[qo[j]] = x;
            }
        }
    }

    /// Joint configuration from actuator values: the neutral configuration with the actuated
    /// joints set from `a`.
    pub fn from_actuators(&self, a: &[f64]) -> Vec<f64> {
        let mut q = self.neutral();
        self.apply_actuators(a, &mut q);
        q
    }

    /// Actuator values for `q` (`Model::to_actuators` in the spec): each coupling solved in the
    /// least-squares sense, so a consistent `q` maps back exactly.
    pub fn to_actuators(&self, q: &[f64]) -> Vec<f64> {
        let qo = self.q_offsets();
        let mut a = vec![0.0; self.actuators.len()];
        for cp in &self.couplings {
            let (rows, cols) = (cp.joints.len(), cp.actuators.len());
            if rows == 1 && cols == 1 && cp.matrix[0] != 0.0 {
                a[cp.actuators[0]] = (q[qo[cp.joints[0]]] - cp.offset[0]) / cp.matrix[0];
                continue;
            }
            let m = DMatrix::from_row_slice(rows, cols, &cp.matrix);
            let b = nalgebra::DVector::from_iterator(rows, cp.joints.iter().enumerate().map(|(r, &j)| q[qo[j]] - cp.offset[r]));
            let svd = m.svd(true, true);
            if let Ok(x) = svd.solve(&b, 1e-12) {
                for (col, &ai) in cp.actuators.iter().enumerate() {
                    a[ai] = x[col];
                }
            }
        }
        a
    }

    /// Effective actuator bounds: the actuator's own limits intersected with the joint limits of
    /// every joint that this actuator alone moves (rows with one non-zero entry). Joints moved
    /// by several actuators at once are not bounded here.
    pub fn actuator_bounds(&self) -> Vec<(f64, f64)> {
        let mut b: Vec<(f64, f64)> = self.actuators.iter().map(|a| (a.limits.lower, a.limits.upper)).collect();
        for cp in &self.couplings {
            let n = cp.actuators.len();
            for (r, &j) in cp.joints.iter().enumerate() {
                let row = &cp.matrix[r * n..(r + 1) * n];
                let nz: Vec<usize> = (0..n).filter(|&c| row[c] != 0.0).collect();
                if nz.len() != 1 {
                    continue;
                }
                let (col, m) = (nz[0], row[nz[0]]);
                let l = &self.joints[j].limits;
                if !self.joints[j].kind.is_bounded() {
                    continue;
                }
                let (lo, hi) = ((l.lower - cp.offset[r]) / m, (l.upper - cp.offset[r]) / m);
                let (lo, hi) = if m > 0.0 { (lo, hi) } else { (hi, lo) };
                let ai = cp.actuators[col];
                b[ai].0 = b[ai].0.max(lo);
                b[ai].1 = b[ai].1.min(hi);
            }
        }
        b
    }

    /// Tendon path length for coupling `ci` at `q` (sum of the straight runs between via points).
    pub fn tendon_length(&self, q: &[f64], ci: usize) -> Result<f64, KinError> {
        let CouplingKind::Tendon { routing, .. } = &self.couplings.get(ci).ok_or_else(|| KinError::new(codes::UNKNOWN_NAME, format!("no coupling {ci}")))?.kind else {
            return Err(KinError::new(codes::PARAMS, format!("coupling {ci} is not a tendon")));
        };
        let poses = self.fk(q)?;
        let pts: Vec<Vec3> = routing.iter().map(|p| poses[p.link] * nalgebra::Point3::from(p.pos)).map(|p| p.coords).collect();
        Ok(pts.windows(2).map(|w| (w[1] - w[0]).norm()).sum())
    }

    /// Tendon moment arms at `q`: `r[k] = -dL/dv[k]` for every velocity index (zero for joints
    /// the tendon does not cross). Positive means pulling the tendon drives that DOF positive.
    pub fn tendon_moment_arms(&self, q: &[f64], ci: usize) -> Result<Vec<f64>, KinError> {
        let CouplingKind::Tendon { routing, .. } = &self.couplings.get(ci).ok_or_else(|| KinError::new(codes::UNKNOWN_NAME, format!("no coupling {ci}")))?.kind else {
            return Err(KinError::new(codes::PARAMS, format!("coupling {ci} is not a tendon")));
        };
        let poses = self.fk(q)?;
        let nv = self.nv();
        let mut r = vec![0.0; nv];
        let pts: Vec<Vec3> = routing.iter().map(|p| (poses[p.link] * nalgebra::Point3::from(p.pos)).coords).collect();
        let jac: Vec<nalgebra::Matrix3xX<f64>> = routing.iter().zip(&pts).map(|(p, w)| self.point_jacobian(&poses, p.link, w)).collect();
        for k in 0..pts.len().saturating_sub(1) {
            let d = pts[k + 1] - pts[k];
            let len = d.norm();
            if len < 1e-12 {
                continue;
            }
            let u = d / len;
            for c in 0..nv {
                let dv = jac[k + 1].column(c) - jac[k].column(c);
                r[c] -= u.dot(&dv);
            }
        }
        Ok(r)
    }

    /// The coupling matrix of a single-actuator tendon from its routing at the neutral
    /// configuration. Excursion `a = sum_j r_j q_j`; the joints share it as the minimum-norm
    /// solution `q_j = r_j a / sum_k r_k^2`, which is the equilibrium of equal return springs
    /// on every crossed joint (the usual underactuated finger).
    pub fn tendon_matrix(&self, ci: usize) -> Result<Vec<f64>, KinError> {
        let r = self.tendon_moment_arms(&self.neutral(), ci)?;
        let vo = self.v_offsets();
        let cp = &self.couplings[ci];
        let rr: Vec<f64> = cp.joints.iter().map(|&j| r[vo[j]]).collect();
        let s: f64 = rr.iter().map(|x| x * x).sum();
        if !(s > 1e-18) {
            return Err(invalid(format!("coupling {ci}: the tendon has no moment arm on its joints")));
        }
        Ok(rr.iter().map(|x| x / s).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn two_link() -> Model {
        let j = |name: &str, parent: usize, z: f64| Joint { name: name.into(), kind: JointKind::Revolute, parent, origin: crate::math::pose_xyz_rpy([0.0, 0.0, z], [0.0; 3]), axis: Vec3::x(), limits: Limits { lower: -1.0, upper: 2.0, ..Limits::default() } };
        let mut m = Model {
            name: "finger".into(),
            links: vec![Link { name: "palm".into(), inertial: None }, Link { name: "p1".into(), inertial: None }, Link { name: "p2".into(), inertial: None }],
            joints: vec![j("mcp", 0, 0.0), j("pip", 1, 0.05)],
            actuators: vec![Actuator { name: "flexor".into(), drive: Drive::Tendon, limits: Limits::default() }],
            couplings: vec![Coupling {
                name: "flexor".into(),
                kind: CouplingKind::Tendon {
                    routing: vec![
                        TendonPoint { link: 0, pos: Vec3::new(0.0, -0.008, -0.01) },
                        TendonPoint { link: 1, pos: Vec3::new(0.0, -0.008, 0.01) },
                        TendonPoint { link: 1, pos: Vec3::new(0.0, -0.006, 0.04) },
                        TendonPoint { link: 2, pos: Vec3::new(0.0, -0.006, 0.01) },
                    ],
                    stiffness: 1e4,
                    slack: 0.0,
                },
                actuators: vec![0],
                joints: vec![0, 1],
                matrix: vec![],
                offset: vec![],
            }],
            end_effectors: vec![],
        };
        m.normalize().unwrap();
        m
    }

    #[test]
    fn tendon_moment_arms_match_length_derivative() {
        let m = two_link();
        let q = vec![0.3, 0.5];
        let r = m.tendon_moment_arms(&q, 0).unwrap();
        for k in 0..2 {
            let h = 1e-7;
            let mut qp = q.clone();
            qp[k] += h;
            let mut qm = q.clone();
            qm[k] -= h;
            let fd = -(m.tendon_length(&qp, 0).unwrap() - m.tendon_length(&qm, 0).unwrap()) / (2.0 * h);
            assert!((fd - r[k]).abs() < 1e-7 * (1.0 + r[k].abs()), "{fd} vs {}", r[k]);
            assert!(r[k] > 0.004, "pull flexes: {}", r[k]);
        }
        // Matrix: min-norm split, excursion consistent at first order.
        let c = &m.couplings[0].matrix;
        let r0 = m.tendon_moment_arms(&m.neutral(), 0).unwrap();
        assert!(((r0[0] * c[0] + r0[1] * c[1]) - 1.0).abs() < 1e-12);
    }

    #[test]
    fn actuators_round_trip_and_motor_per_joint() {
        let mut m = two_link();
        m.couplings.clear();
        m.actuators.clear();
        m.normalize().unwrap();
        assert_eq!(m.actuators.len(), 2);
        assert_eq!(m.actuators[0].drive, Drive::Motor);
        let q = vec![0.2, -0.4];
        assert_eq!(m.to_actuators(&q), q);
        assert_eq!(m.from_actuators(&q), q);
        let text = m.to_json();
        let back = Model::from_json(&text).unwrap();
        assert_eq!(back.actuators.len(), 2);
        assert_eq!(back.couplings.len(), 2);
    }

    #[test]
    fn invalid_models_are_refused() {
        let mut m = two_link();
        m.joints[1].parent = 2;
        assert_eq!(m.normalize().unwrap_err().code, codes::MODEL_INVALID);
        let mut m = two_link();
        m.links.pop();
        assert!(m.normalize().is_err());
        assert_eq!(Model::from_json("{").unwrap_err().code, codes::MODEL_PARSE);
    }
}
