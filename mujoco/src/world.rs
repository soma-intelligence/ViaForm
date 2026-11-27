//! One environment on MuJoCo (feature `mujoco`): the MJCF export of a phys model in a [`Sim`],
//! with phys's state layout, actuator semantics and records.
//!
//! - State: `q` and `v` in phys's (kin's) layout. A free body's `q` is its pose relative to its
//!   joint frame and its linear velocity is in the body frame (MuJoCo: world pose, world linear
//!   velocity); spherical and scalar joints match MuJoCo one to one.
//! - Servos: MuJoCo's affine actuator gives the PD law with implicit damping
//!   (`implicitfast`). Each step the control is set to `a + e`, where `e` is phys's deadbanded
//!   error on the quantised encoder reading, and the force range to phys's torque-speed box at
//!   the present speed, so the deadband, the encoder steps and the speed-dependent torque limit
//!   match phys. Backlash is not modelled.
//! - Tendon motors: the excursion moves toward its target at the motor's top speed as in phys;
//!   the cable damping on the excursion rate goes into the control.
//! - Records: the G3 wrench history from MuJoCo's `cfrc_int` (the wrench from the parent,
//!   gravity, contacts and applied forces included, after `mj_rnePostConstraint`), `cacc` and
//!   `cvel`, reduced to phys's frames and sources, so `generative::solid::sim_loads` reads a
//!   MuJoCo run unchanged.

use std::sync::Arc;

use nalgebra::{Matrix3, Vector3};
use viaform_kin::math::{pose_from7, pose_to7};
use viaform_kin::model::JointKind;
use viaform_phys::actuator::ActuatorKind;
use viaform_phys::error::codes;
use viaform_phys::model::PhysModel;
use viaform_phys::record::{Episode, WrenchHistory};
use viaform_phys::world::ExtForce;
use viaform_phys::{PhysError, Settings, World};

use crate::mjcf::{self, ActOut, MjcfMap};
use crate::sim::Sim;

type V3 = Vector3<f64>;

/// Per-actuator wiring.
#[derive(Clone, Debug)]
struct ActWire {
    /// MuJoCo actuator id.
    id: usize,
    /// Joint qpos and dof address and phys's map `a = (q - offset) / gain` (joint actuators).
    joint: Option<(usize, usize, f64, f64)>,
}

/// A contact of the last step: bodies (phys links), distance, point, normal, force on body 2.
#[derive(Clone, Copy, Debug)]
pub struct MjContact {
    pub b1: usize,
    pub b2: usize,
    pub dist: f64,
    pub p: [f64; 3],
    pub n: [f64; 3],
    pub f: [f64; 3],
}

/// The wrench recorder (phys's `Recorder` output on MuJoCo's quantities).
#[derive(Clone, Debug, Default)]
pub struct MjRecorder {
    pub every: u64,
    pub bodies: Vec<usize>,
    pub wrenches: Vec<WrenchHistory>,
    pub episode: Episode,
    pub gravity: [f64; 3],
    /// (link, [(child joint, child link, history index)], parent history, contacts history).
    layout: Vec<(usize, Vec<(usize, usize, usize)>, usize, usize)>,
}

impl MjRecorder {
    pub fn new(every: u64, bodies: Vec<usize>) -> Self {
        MjRecorder { every: every.max(1), bodies, ..Default::default() }
    }

    pub fn due(&self, step: u64) -> bool {
        step % self.every.max(1) == 0
    }

    fn setup(&mut self, m: &PhysModel) {
        let bodies: Vec<usize> = if self.bodies.is_empty() { (1..m.nlinks()).collect() } else { self.bodies.clone() };
        for &b in &bodies {
            if b == 0 || b >= m.nlinks() {
                continue;
            }
            let name = m.kin.links[b].name.clone();
            let parent = self.wrenches.len();
            self.wrenches.push(WrenchHistory { body: name.clone(), source: format!("joint:{}", m.kin.joints[b - 1].name), ..Default::default() });
            let mut children = vec![];
            for (j, jt) in m.joints.iter().enumerate() {
                if jt.parent == b {
                    children.push((j, jt.child, self.wrenches.len()));
                    self.wrenches.push(WrenchHistory { body: name.clone(), source: format!("joint:{}", m.kin.joints[j].name), ..Default::default() });
                }
            }
            let contacts = self.wrenches.len();
            self.wrenches.push(WrenchHistory { body: name, source: "contacts".into(), ..Default::default() });
            self.layout.push((b, children, parent, contacts));
        }
    }
}

fn push(h: &mut WrenchHistory, t: f64, f: V3, tq: V3, at: V3, acc: [f64; 6]) {
    h.t.push(t);
    h.force.push([f.x, f.y, f.z]);
    h.torque.push([tq.x, tq.y, tq.z]);
    h.at.push([at.x, at.y, at.z]);
    h.accel.push(acc);
}

fn v3(s: &[f64], k: usize) -> V3 {
    V3::new(s[k], s[k + 1], s[k + 2])
}

/// One MuJoCo environment with phys's interface.
#[derive(Clone)]
pub struct MjWorld {
    pub sim: Sim,
    pub model: Arc<PhysModel>,
    pub settings: Settings,
    pub map: MjcfMap,
    pub xml: String,
    /// MuJoCo body id per phys link.
    body: Vec<usize>,
    /// phys link per MuJoCo body.
    link_of: Vec<usize>,
    /// (qpos address, dof address) per phys joint (`None` when fixed).
    joints: Vec<Option<(usize, usize)>>,
    acts: Vec<ActWire>,
    /// Actuator controls in phys's meaning.
    pub control: Vec<f64>,
    excursion: Vec<f64>,
    excursion_rate: Vec<f64>,
    /// Actuator efforts of the last step (N m, N, or tendon tension N).
    pub effort: Vec<f64>,
    pub t: f64,
    pub steps: u64,
    pub ext: Vec<ExtForce>,
    ext_on: bool,
    pub recorder: Option<MjRecorder>,
    bad: i32,
}

fn unsupported(msg: impl Into<String>) -> PhysError {
    PhysError::new(codes::ENGINE_UNSUPPORTED, msg)
}

impl MjWorld {
    /// The MuJoCo twin of a phys world: same model (exported to MJCF), state, controls and
    /// recording settings.
    pub fn from_phys(w: &World) -> Result<MjWorld, PhysError> {
        let ex = mjcf::export(&w.model, &w.settings)?;
        let sim = Sim::from_xml(&ex.xml).map_err(|e| PhysError::new(codes::MODEL_INVALID, format!("MuJoCo: {e}")))?;
        let m = w.model.clone();
        let mut body = vec![0usize; m.nlinks()];
        for l in 1..m.nlinks() {
            let id = sim.id(0, &ex.map.bodies[l]);
            if id < 0 {
                return Err(unsupported(format!("MuJoCo has no body {}", ex.map.bodies[l])));
            }
            body[l] = id as usize;
        }
        let mut link_of = vec![0usize; sim.n.nbody];
        for (l, &b) in body.iter().enumerate() {
            link_of[b] = l;
        }
        let mut joints = vec![None; m.joints.len()];
        for (j, name) in ex.map.joints.iter().enumerate() {
            if let Some(name) = name {
                let id = sim.id(1, name);
                if id < 0 {
                    return Err(unsupported(format!("MuJoCo has no joint {name}")));
                }
                joints[j] = Some((sim.jnt_qposadr(id), sim.jnt_dofadr(id)));
            }
        }
        if sim.n.nout != sim.n.nu {
            return Err(unsupported("MuJoCo actuators with several outputs are not used here"));
        }
        let mut acts = vec![];
        for (a, (name, _)) in ex.map.actuators.iter().enumerate() {
            let id = sim.id(2, name);
            if id < 0 {
                return Err(unsupported(format!("MuJoCo has no actuator {name}")));
            }
            let joint = m.actuator_map[a].as_ref().and_then(|am| joints[m.dof_joint[am.vi]].map(|(qa, da)| (qa, da, am.gain, am.offset)));
            acts.push(ActWire { id: id as usize, joint });
        }
        let na = m.actuators.len();
        let mut mw = MjWorld {
            sim,
            model: m,
            settings: w.settings.clone(),
            map: ex.map,
            xml: ex.xml,
            body,
            link_of,
            joints,
            acts,
            control: w.act.iter().map(|a| a.control).collect(),
            excursion: w.act.iter().map(|a| a.excursion).collect(),
            excursion_rate: vec![0.0; na],
            effort: vec![0.0; na],
            t: w.t,
            steps: w.steps,
            ext: w.ext.clone(),
            ext_on: false,
            recorder: w.recorder.as_ref().map(|r| MjRecorder::new(r.every, r.bodies.clone())),
            bad: 0,
        };
        mw.set_q(&w.q)?;
        mw.set_v(&w.v)?;
        mw.sim.set_time(w.t);
        mw.sim.forward();
        Ok(mw)
    }

    pub fn nlinks(&self) -> usize {
        self.model.nlinks()
    }

    /// Configuration in phys's layout.
    pub fn q(&self) -> Vec<f64> {
        let mut q = vec![0.0; self.model.nq()];
        let qpos = self.sim.qpos();
        for (j, jt) in self.model.joints.iter().enumerate() {
            let Some((qa, _)) = self.joints[j] else { continue };
            match jt.kind {
                JointKind::Fixed => {}
                JointKind::Spherical => q[jt.qo..jt.qo + 4].copy_from_slice(&qpos[qa..qa + 4]),
                JointKind::Floating => {
                    let world = pose_from7(&qpos[qa..qa + 7].try_into().unwrap());
                    let rel = jt.origin.inverse() * world;
                    q[jt.qo..jt.qo + 7].copy_from_slice(&pose_to7(&rel));
                }
                _ => q[jt.qo] = qpos[qa],
            }
        }
        q
    }

    /// Velocity in phys's layout.
    pub fn v(&self) -> Vec<f64> {
        let mut v = vec![0.0; self.model.nv()];
        let (qpos, qvel) = (self.sim.qpos(), self.sim.qvel());
        for (j, jt) in self.model.joints.iter().enumerate() {
            let Some((qa, da)) = self.joints[j] else { continue };
            match jt.kind {
                JointKind::Fixed => {}
                JointKind::Spherical => v[jt.vo..jt.vo + 3].copy_from_slice(&qvel[da..da + 3]),
                JointKind::Floating => {
                    let world = pose_from7(&qpos[qa..qa + 7].try_into().unwrap());
                    let lin = world.rotation.inverse() * v3(qvel, da);
                    v[jt.vo..jt.vo + 3].copy_from_slice(lin.as_slice());
                    v[jt.vo + 3..jt.vo + 6].copy_from_slice(&qvel[da + 3..da + 6]);
                }
                _ => v[jt.vo] = qvel[da],
            }
        }
        v
    }

    /// Sets the configuration (phys layout).
    pub fn set_q(&mut self, q: &[f64]) -> Result<(), PhysError> {
        self.model.kin.check_q(q)?;
        let m = self.model.clone();
        let joints = self.joints.clone();
        let qpos = self.sim.qpos_mut();
        for (j, jt) in m.joints.iter().enumerate() {
            let Some((qa, _)) = joints[j] else { continue };
            match jt.kind {
                JointKind::Fixed => {}
                JointKind::Spherical => qpos[qa..qa + 4].copy_from_slice(&q[jt.qo..jt.qo + 4]),
                JointKind::Floating => {
                    let rel = pose_from7(&q[jt.qo..jt.qo + 7].try_into().unwrap());
                    qpos[qa..qa + 7].copy_from_slice(&pose_to7(&(jt.origin * rel)));
                }
                _ => qpos[qa] = q[jt.qo],
            }
        }
        Ok(())
    }

    /// Sets the velocity (phys layout).
    pub fn set_v(&mut self, v: &[f64]) -> Result<(), PhysError> {
        if v.len() != self.model.nv() || v.iter().any(|x| !x.is_finite()) {
            return Err(crate::params(format!("v needs {} finite values", self.model.nv())));
        }
        let m = self.model.clone();
        let joints = self.joints.clone();
        let qpos: Vec<f64> = self.sim.qpos().to_vec();
        let qvel = self.sim.qvel_mut();
        for (j, jt) in m.joints.iter().enumerate() {
            let Some((qa, da)) = joints[j] else { continue };
            match jt.kind {
                JointKind::Fixed => {}
                JointKind::Spherical => qvel[da..da + 3].copy_from_slice(&v[jt.vo..jt.vo + 3]),
                JointKind::Floating => {
                    let world = pose_from7(&qpos[qa..qa + 7].try_into().unwrap());
                    let lin = world.rotation * v3(v, jt.vo);
                    qvel[da..da + 3].copy_from_slice(lin.as_slice());
                    qvel[da + 3..da + 6].copy_from_slice(&v[jt.vo + 3..jt.vo + 6]);
                }
                _ => qvel[da] = v[jt.vo],
            }
        }
        Ok(())
    }

    pub fn set_control(&mut self, a: usize, value: f64) {
        self.control[a] = value;
    }

    /// Link poses `[x, y, z, qw, qx, qy, qz]` per link into `out`; returns the links written.
    pub fn poses_flat(&mut self, out: &mut [f64]) -> usize {
        self.sim.kinematics();
        let n = (out.len() / 7).min(self.model.nlinks());
        let (xpos, xquat) = (self.sim.xpos(), self.sim.xquat());
        for l in 0..n {
            let b = self.body[l];
            out[7 * l..7 * l + 3].copy_from_slice(&xpos[3 * b..3 * b + 3]);
            out[7 * l + 3..7 * l + 7].copy_from_slice(&xquat[4 * b..4 * b + 4]);
        }
        n
    }

    /// Contacts of the last step, with phys link indices.
    pub fn contacts(&self) -> Vec<MjContact> {
        self.sim.contacts().into_iter().map(|(b1, b2, dist, p, n, f)| MjContact { b1: self.link_of[b1], b2: self.link_of[b2], dist, p, n, f }).collect()
    }

    /// Advances `n` steps.
    pub fn run(&mut self, n: usize) -> Result<(), PhysError> {
        for _ in 0..n {
            self.step()?;
        }
        Ok(())
    }

    /// One step: controls in phys's meaning to MuJoCo's, `mj_step`, efforts, records.
    pub fn step(&mut self) -> Result<(), PhysError> {
        let dt = self.settings.dt;
        let due = self.recorder.as_ref().is_some_and(|r| r.due(self.steps));
        let pre_q = if due { Some(self.q()) } else { None };
        let m = self.model.clone();
        // Controls.
        let (qpos, qvel): (Vec<f64>, Vec<f64>) = (self.sim.qpos().to_vec(), self.sim.qvel().to_vec());
        for a in 0..m.actuators.len() {
            let id = self.acts[a].id;
            let ctrl = match (&m.actuators[a], &self.map.actuators[a].1) {
                (ActuatorKind::TendonMotor { max_speed }, ActOut::Tendon { stiffness, damping, .. }) => {
                    let d = (self.control[a] - self.excursion[a]).clamp(-max_speed * dt, max_speed * dt);
                    self.excursion[a] += d;
                    self.excursion_rate[a] = d / dt;
                    self.excursion[a] + if *stiffness > 0.0 { damping / stiffness * self.excursion_rate[a] } else { 0.0 }
                }
                (ActuatorKind::Servo(p), _) => {
                    let (qa, da, gain, offset) = self.acts[a].joint.expect("servos drive a joint");
                    let pos = (qpos[qa] - offset) / gain;
                    let vel = qvel[da] / gain;
                    let e = p.error(self.control[a], p.measure(pos));
                    let (lo, hi) = p.torque_box(vel);
                    let fr = self.sim.forcerange_mut();
                    fr[2 * id] = lo;
                    fr[2 * id + 1] = hi;
                    pos + e
                }
                _ => self.control[a],
            };
            self.sim.ctrl_mut()[id] = ctrl;
        }
        // External forces (world force at a world point, plus a torque) on the body's centre.
        let active: Vec<ExtForce> = self.ext.iter().filter(|e| self.t < e.until && e.link < self.body.len()).cloned().collect();
        if !active.is_empty() || self.ext_on {
            self.sim.kinematics();
            let xipos = self.sim.xipos().to_vec();
            let body = self.body.clone();
            let xf = self.sim.xfrc_applied_mut();
            xf.iter_mut().for_each(|x| *x = 0.0);
            for e in &active {
                let b = body[e.link];
                let f = V3::from(e.force);
                let tq = V3::from(e.torque) + (V3::from(e.point) - v3(&xipos, 3 * b)).cross(&f);
                for k in 0..3 {
                    xf[6 * b + k] += f[k];
                    xf[6 * b + 3 + k] += tq[k];
                }
            }
            self.ext_on = !active.is_empty();
        }
        self.sim.step();
        let bad = self.sim.bad_state();
        if bad > self.bad || self.sim.qpos().iter().chain(self.sim.qvel()).any(|x| !x.is_finite()) {
            self.bad = bad;
            return Err(PhysError::new(codes::DIVERGED, format!("MuJoCo state diverged at t = {:.4} s", self.t)));
        }
        for a in 0..m.actuators.len() {
            let f = self.sim.act_force()[self.acts[a].id];
            self.effort[a] = match self.map.actuators[a].1 {
                ActOut::Tendon { routed: true, .. } => -f,
                _ => f,
            };
        }
        if let Some(q) = pre_q {
            self.record(&q);
        }
        self.t += dt;
        self.steps += 1;
        Ok(())
    }

    /// One wrench sample for the state before the last `mj_step` (MuJoCo keeps that step's
    /// kinematics, accelerations and contact forces in its data).
    fn record(&mut self, q: &[f64]) {
        let Some(mut rec) = self.recorder.take() else { return };
        let m = self.model.clone();
        if rec.layout.is_empty() {
            rec.setup(&m);
            rec.gravity = self.settings.gravity;
        }
        self.sim.rne_post();
        let g = V3::from(self.settings.gravity);
        let (xpos, xmat, cvel, cacc, cfrc, sub) = (self.sim.xpos(), self.sim.xmat(), self.sim.cvel(), self.sim.cacc(), self.sim.cfrc_int(), self.sim.subtree_com());
        let rot = |b: usize| Matrix3::from_row_slice(&xmat[9 * b..9 * b + 9]);
        let centre = |b: usize| v3(sub, 3 * self.sim.body_rootid(b));
        // Wrench `[torque; force]` about the subtree centre to (force, torque about point p).
        let wrench_at = |b: usize, p: &V3| {
            let (tc, f) = (v3(cfrc, 6 * b), v3(cfrc, 6 * b + 3));
            (f, tc + (centre(b) - p).cross(&f))
        };
        // Contacts per link: world force, torque about the origin, weighted points, weight.
        let mut cw = vec![(V3::zeros(), V3::zeros(), V3::zeros(), 0.0); m.nlinks()];
        for c in self.contacts() {
            let f = V3::from(c.f);
            let p = V3::from(c.p);
            for (link, f) in [(c.b2, f), (c.b1, -f)] {
                if link == 0 {
                    continue;
                }
                let e = &mut cw[link];
                e.0 += f;
                e.1 += p.cross(&f);
                e.2 += p * f.norm();
                e.3 += f.norm();
            }
        }
        for (link, children, parent, contacts) in &rec.layout {
            let b = self.body[*link];
            let r = rot(b);
            let rt = r.transpose();
            let p = v3(xpos, 3 * b);
            let c = centre(b);
            // Body acceleration without gravity (MuJoCo's base acceleration is -g).
            let (w, vc) = (v3(cvel, 6 * b), v3(cvel, 6 * b + 3));
            let (al, ac) = (v3(cacc, 6 * b), v3(cacc, 6 * b + 3) + g);
            let vp = vc + w.cross(&(p - c));
            let ap = ac + al.cross(&(p - c)) + w.cross(&vp);
            let (la, aa) = (rt * ap, rt * al);
            let acc = [la.x, la.y, la.z, aa.x, aa.y, aa.z];
            let (f, tq) = wrench_at(b, &p);
            push(&mut rec.wrenches[*parent], self.t, rt * f, rt * tq, V3::zeros(), acc);
            for &(_, child, idx) in children {
                let cb = self.body[child];
                let pc = v3(xpos, 3 * cb);
                let (f, tq) = wrench_at(cb, &pc);
                push(&mut rec.wrenches[idx], self.t, -(rt * f), -(rt * tq), rt * (pc - p), acc);
            }
            let (fw, tw, ps, wsum) = cw[*link];
            let (fb, tb, atb) = if wsum > 0.0 {
                let at_w = ps / wsum;
                (rt * fw, rt * (tw - at_w.cross(&fw)), rt * (at_w - p))
            } else {
                (V3::zeros(), V3::zeros(), V3::zeros())
            };
            push(&mut rec.wrenches[*contacts], self.t, fb, tb, atb, acc);
        }
        rec.episode.t.push(self.t);
        rec.episode.q.push(q.to_vec());
        rec.episode.effort.push(self.effort.clone());
        self.recorder = Some(rec);
    }
}
