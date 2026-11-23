//! Recording: the per-body wrench history for loads from simulation (RUST-ENGINES G3) and the
//! episode (time, joint values, actuator efforts) for replay and telemetry.
//!
//! A body receives wrenches at its joints (the parent joint, and the reaction of each child
//! joint) and at its contacts. Each is one [`WrenchHistory`] with the G3 fields, in the body
//! frame: `force` (N), `torque` (N m) about `at` (m, body frame), and the body acceleration
//! `accel` (`[ax, ay, az, alpha_x, alpha_y, alpha_z]`: linear acceleration of the body origin in
//! m/s^2 and angular acceleration in rad/s^2, body frame, gravity not included). `source` names
//! the wrench (`joint:<name>`, `contacts`). Gravity is the run's `gravity`; the inertial load of
//! a part is `m (g - a)`.

use serde::{Deserialize, Serialize};

use crate::actuator::ActuatorState;
use crate::dynamics::{Ws, base_acc};
use crate::model::PhysModel;
use crate::spatial::{V3, ang, lin};

/// Body acceleration `[ax, ay, az, alpha_x, alpha_y, alpha_z]`, body frame.
pub type Acc6 = [f64; 6];

/// Time history of the wrench a body receives at one joint or at its contacts, in the body
/// frame (RUST-ENGINES G3 shape plus `source`).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct WrenchHistory {
    pub body: String,
    #[serde(default)]
    pub source: String,
    pub t: Vec<f64>,
    pub force: Vec<[f64; 3]>,
    pub torque: Vec<[f64; 3]>,
    pub at: Vec<[f64; 3]>,
    pub accel: Vec<Acc6>,
}

impl WrenchHistory {
    fn push(&mut self, t: f64, f: V3, tq: V3, at: V3, acc: Acc6) {
        self.t.push(t);
        self.force.push([f.x, f.y, f.z]);
        self.torque.push([tq.x, tq.y, tq.z]);
        self.at.push([at.x, at.y, at.z]);
        self.accel.push(acc);
    }
}

/// The recorded episode.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Episode {
    pub t: Vec<f64>,
    pub q: Vec<Vec<f64>>,
    /// Actuator efforts (N m, N, or tendon tension N) per sample.
    pub effort: Vec<Vec<f64>>,
}

/// What to record and the records.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Recorder {
    /// Record every `every` steps (1: every step).
    pub every: u64,
    /// Links whose wrenches are recorded (empty: every moving link).
    pub bodies: Vec<usize>,
    pub wrenches: Vec<WrenchHistory>,
    pub episode: Episode,
    pub gravity: [f64; 3],
    #[serde(skip)]
    layout: Vec<(usize, Vec<(usize, usize)>, usize, usize)>,
}

impl Recorder {
    pub fn new(every: u64, bodies: Vec<usize>) -> Self {
        Recorder { every: every.max(1), bodies, ..Default::default() }
    }

    pub fn due(&self, step: u64) -> bool {
        step % self.every.max(1) == 0
    }

    fn setup(&mut self, m: &PhysModel) {
        let bodies: Vec<usize> = if self.bodies.is_empty() { (1..m.nlinks()).collect() } else { self.bodies.clone() };
        for &b in &bodies {
            let name = m.kin.links[b].name.clone();
            let parent = self.wrenches.len();
            self.wrenches.push(WrenchHistory { body: name.clone(), source: format!("joint:{}", m.kin.joints[b - 1].name), ..Default::default() });
            let mut children = vec![];
            for (j, jt) in m.joints.iter().enumerate() {
                if jt.parent == b {
                    children.push((j, self.wrenches.len()));
                    self.wrenches.push(WrenchHistory { body: name.clone(), source: format!("joint:{}", m.kin.joints[j].name), ..Default::default() });
                }
            }
            let contacts = self.wrenches.len();
            self.wrenches.push(WrenchHistory { body: name, source: "contacts".into(), ..Default::default() });
            self.layout.push((b, children, parent, contacts));
        }
    }

    /// One sample after an RNEA pass (`ws.f` joint forces, `ws.acc` accelerations with the
    /// base at `-g`). `contact_w[link]` = (world force, world torque about the world origin,
    /// sum of weighted points, sum of weights).
    pub(crate) fn push_sample(&mut self, m: &PhysModel, ws: &Ws, t: f64, g: &V3, contact_w: &[(V3, V3, V3, f64)], q: &[f64], act: &[ActuatorState]) {
        if self.layout.is_empty() {
            self.setup(m);
            self.gravity = [g.x, g.y, g.z];
        }
        for (b, children, parent, contacts) in &self.layout {
            let b = *b;
            let a_true = ws.acc[b] - ws.xw[b].motion(&base_acc(g));
            let vel = ws.vel[b];
            let la = lin(&a_true) + ang(&vel).cross(&lin(&vel));
            let aa = ang(&a_true);
            let acc = [la.x, la.y, la.z, aa.x, aa.y, aa.z];
            let f = ws.f[b];
            self.wrenches[*parent].push(t, lin(&f), ang(&f), V3::zeros(), acc);
            for &(j, idx) in children {
                let c = m.joints[j].child;
                let x = &ws.xj[j];
                let fp = -x.inv_force(&ws.f[c]);
                let at = x.r;
                let (fl, n) = (lin(&fp), ang(&fp) - at.cross(&lin(&fp)));
                self.wrenches[idx].push(t, fl, n, at, acc);
            }
            let (fw, tw, ps, wsum) = contact_w[b];
            let rot = ws.poses[b].rotation;
            let pos = ws.poses[b].translation.vector;
            let (fb, tb, atb) = if wsum > 0.0 {
                let at_w = ps / wsum;
                let t_at = tw - at_w.cross(&fw);
                (rot.inverse() * fw, rot.inverse() * t_at, rot.inverse() * (at_w - pos))
            } else {
                (V3::zeros(), V3::zeros(), V3::zeros())
            };
            self.wrenches[*contacts].push(t, fb, tb, atb, acc);
        }
        self.episode.t.push(t);
        self.episode.q.push(q.to_vec());
        self.episode.effort.push(act.iter().map(|a| a.effort).collect());
    }
}
