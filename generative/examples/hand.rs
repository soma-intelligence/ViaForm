//! A humanoid robotic hand, 1.15 x human size, built around the parts sourced in
//! docs/components/hand.json: 24 degrees of freedom, one motor each.
//!
//! - 22 ROBOTIS XC330-T288-T in a forearm bank, each turning a 6 mm spool that pulls a flexor
//!   and an extensor tendon (PowerPro 0.43 mm in PTFE sheaths) to its joint: MCP abduction,
//!   MCP flexion, PIP and DIP on each finger, CMC flexion, CMC abduction, MCP flexion, MCP
//!   abduction and IP on the thumb, and the palm arch (ring and little side cupping).
//! - 2 XM430-W350-T drive a wrist gimbal directly: flexion and extension (in the forearm
//!   frame), radial and ulnar deviation (on the gimbal cross).
//! - Joints: 3 x 16 mm pins pressed into the parent's lugs, two bearings in the child's tongue
//!   (693ZZ on finger and thumb axes, 623ZZ on the thumb CMC and the arch), joint pulleys of
//!   6 mm (8 mm round a 623ZZ). Wrist: 8 x 20 mm pins, two 688ZZ per idler.
//!
//! Every structural part is grown by the 3D engine: least mass, AlSi10Mg printed along +z with
//! no overhang past 45 deg, safety factor 2 on its 230 MPa yield, under the real loads: tendons
//! at the XC330 current limit (89 N on the pulled tendon with its pretension, so the tendon
//! keeps a safety factor of 2 on its terminated strength; the uncapped 12 V stall would be
//! 167 N + 20 N), the fingertip forces that cap holds, side pushes, a 100 g drop; the servo bank
//! carries every tendon's pull against its sheath stop bar. The two XM430s drive the wrist with
//! no tendon and are taken at their full 4.1 N m stall.
//!
//! `cargo run --release --example hand [-- --only word,word]` writes docs/generative/hand
//! (parts, assembly.json, hand.json).

mod common;

use common::*;
use serde_json::{Value, json};
use viaform_generative::solid::{self, Load, LoadCase, Manufacturing, Objective, Region, Study, Support};

/// Servo stall torque at 12 V on the 6 mm spool (uncapped, for the record), and the tendons'
/// pretension.
const T_STALL: f64 = 1000.0 / 6.0;
const T_PRE: f64 = 20.0;
const GRIP: f64 = 10.0;
const SIDE: f64 = 5.0;
/// Largest deflection of a finger or thumb link under its loads, mm.
const LINK_MAX_DISP: f64 = 0.25;
/// XM430-W350-T stall at 12 V (docs/components/hand.json M2: 4.1 N m).
const XM_STALL_NMM: f64 = 4100.0;
/// T1 (Spectra 100 lb, 0.46 mm) breaks at 445 N straight; terminated 40 to 70 %: 178 to 311 N.
const T1_BREAK_TERMINATED_N: f64 = 178.0;
/// The XC330's current limit (Current Limit, address 38) caps the spool pull so the tendon keeps
/// a safety factor of 2 on the terminated break: 89 N on the pulled tendon, its 20 N pretension
/// included, so the spool adds 69 N: 414 N mm, 41 % of the 1.0 N m stall, about 0.41 A on the
/// notes' torque and current points (register value and unit UNCONFIRMED: set it on a load
/// cell). Every tendon load case below takes this cap.
const TENDON_CAP_N: f64 = T1_BREAK_TERMINATED_N / 2.0;
/// The pulled tendon at the cap (pretension included), and the pair a spool pulls on its stop
/// (the pulled tendon and its antagonist at pretension).
const T_ACTIVE: f64 = TENDON_CAP_N;
const T_PAIR: f64 = T_ACTIVE + T_PRE;
/// The spool torque the cap allows, N mm, and the current that gives it (linear between the
/// notes' 0.5 A / 0.53 N m and 0.7 A / 0.78 N m points): UNCONFIRMED until calibrated.
const SPOOL_CAP_NMM: f64 = (T_ACTIVE - T_PRE) * SPOOL_R;
const XC_CAP_A: f64 = 0.5 - (530.0 - SPOOL_CAP_NMM) / ((780.0 - 530.0) / 0.2);

#[derive(Clone, Copy, Debug)]
struct Brg {
    reference: &'static str,
    bore: f64,
    od: f64,
    width: f64,
}

/// The bearings, as docs/components/hand.json sources them (checked against its descriptions
/// when the hand is built): B1 693ZZ 3 x 8 x 4, B2 623ZZ 3 x 10 x 4, B3 688ZZ 8 x 16 x 5.
const B693: Brg = Brg { reference: "B1", bore: 3.0, od: 8.0, width: 4.0 };
const B623: Brg = Brg { reference: "B2", bore: 3.0, od: 10.0, width: 4.0 };
const B688: Brg = Brg { reference: "B3", bore: 8.0, od: 16.0, width: 5.0 };

impl Brg {
    /// Half width of the tongue that holds two of them side by side, with a shoulder each side.
    fn tongue(&self) -> f64 {
        self.width + 0.6
    }
    /// Outer radius of the lugs the pin is pressed into.
    fn lug(&self) -> f64 {
        self.bore / 2.0 + if self.od >= 10.0 { 4.0 } else { 3.0 }
    }
    /// The joint pulley's radius: 6 mm, 8 mm round a 623ZZ.
    fn pulley(&self) -> f64 {
        if self.od >= 10.0 { 8.0 } else { 6.0 }
    }
}

fn bx(min: V3, max: V3) -> Region {
    Region::Box { min, max }
}

fn inverse(p: &Pose) -> Pose {
    let r = [0, 1, 2].map(|i| [0, 1, 2].map(|j| p.r[j][i]));
    let q = Pose { r, t: [0.0; 3] };
    Pose { r, t: scale(q.vector(p.t), -1.0) }
}

/// Keep-outs for bodies (boxes in their own frame) that move past a study: every voxel of the
/// study's grid whose centre comes within `margin` plus a half voxel diagonal of a body in any
/// of `poses` (body frame to study frame), as boxes on the voxel faces. Boxes are voided where
/// they touch and never cut as exact holes, so many overlapping places do not fight.
fn swept_out(st: &Study, bodies: &[[V3; 2]], poses: &[Pose], margin: f64) -> Vec<Region> {
    let g = solid::Grid::new(st.min, st.max, st.voxel);
    let e = margin + 0.87 * g.h;
    let inv: Vec<Pose> = poses.iter().map(inverse).collect();
    let hit = |c: V3| {
        inv.iter().any(|p| {
            let q = p.point(c);
            bodies.iter().any(|b| (0..3).all(|a| q[a] >= b[0][a] - e && q[a] <= b[1][a] + e))
        })
    };
    let [nx, ny, nz] = g.n;
    let mut out = Vec::new();
    let half = 0.5 * g.h - 0.005 * g.h;
    for k in 0..nz {
        // Runs along x per row, merged with the row before when they match.
        let mut open: Vec<(usize, usize, usize)> = Vec::new();
        for j in 0..=ny {
            let mut runs = Vec::new();
            if j < ny {
                let mut start = None;
                for i in 0..=nx {
                    let h = i < nx && hit(g.element_center(g.element(i, j, k)));
                    match (h, start) {
                        (true, None) => start = Some(i),
                        (false, Some(i0)) => {
                            runs.push((i0, i - 1));
                            start = None;
                        }
                        _ => {}
                    }
                }
            }
            let mut next = Vec::new();
            for &(i0, i1, j0) in &open {
                if runs.contains(&(i0, i1)) {
                    next.push((i0, i1, j0));
                } else {
                    let a = g.element_center(g.element(i0, j0, k));
                    let b = g.element_center(g.element(i1, j - 1, k));
                    out.push(bx(sub(a, [half; 3]), add(b, [half; 3])));
                }
            }
            for r in runs {
                if !next.iter().any(|&(i0, i1, _)| (i0, i1) == r) {
                    next.push((r.0, r.1, j));
                }
            }
            open = next;
        }
    }
    out
}

/// A turn by `deg` about the line through `c` along `a`.
fn turn(c: V3, a: V3, deg: f64) -> Pose {
    Pose::trans(c).then(&Pose::rot(a, deg.to_radians())).then(&Pose::trans(scale(c, -1.0)))
}

/// Forearm frame to palm frame at wrist flexion `fe` and deviation `ru` (deg): the cross turns
/// about y in the forearm, the palm about z in the cross, both through the origin.
fn forearm_to_palm(fe: f64, ru: f64) -> Pose {
    Pose::rot([0.0, 0.0, 1.0], -ru.to_radians()).then(&Pose::rot([0.0, 1.0, 0.0], -fe.to_radians()))
}

/// Samples from `lim[0]` to `lim[1]`, at most `step` apart, ends included.
fn samples(lim: [f64; 2], step: f64) -> Vec<f64> {
    let n = ((lim[1] - lim[0]) / step).ceil().max(1.0) as usize;
    (0..=n).map(|k| lim[0] + (lim[1] - lim[0]) * k as f64 / n as f64).collect()
}

const WRIST_FE: [f64; 2] = [-40.0, 40.0];
const WRIST_RU: [f64; 2] = [-25.0, 25.0];

/// One link of a finger or the thumb, in its own frame: x along it, its proximal joint at the
/// origin about `prox`, its distal joint at (len, 0, 0) about `dist`.
#[derive(Clone, Debug)]
struct Phalanx {
    name: String,
    dof: String,
    len: f64,
    w: f64,
    h: f64,
    prox: Ax,
    dist: Option<Ax>,
    /// The bearings in this link's tongue (its proximal joint).
    brg: Brg,
    /// The next link's bearings (sizes the clevis).
    next: Option<Brg>,
    /// Joints after this one: their tendons run through this link.
    down: usize,
    /// From the distal joint to the chain's fingertip along x (0 for the tip link).
    reach: f64,
    tip: bool,
    voxel: f64,
}

impl Phalanx {
    fn pad(&self) -> (V3, f64) {
        let r = 0.42 * self.h.min(self.w);
        ([self.len - r, 0.0, -0.1 * self.h], r)
    }

    fn tip_point(&self) -> V3 {
        if self.tip {
            let (c, r) = self.pad();
            [c[0] + 0.4 * r, 0.0, c[2] - 0.8 * r]
        } else {
            [self.len + self.reach, 0.0, 0.0]
        }
    }

    /// The tendon anchor on this link's own pulley, palmar (flexor) or dorsal side.
    fn anchor(&self, flexor: bool) -> (Region, V3) {
        let (r, t) = (self.brg.pulley(), self.brg.tongue());
        let s = if flexor { -1.0 } else { 1.0 };
        match self.prox {
            Ax::Y => (bx([-1.5, -t, if flexor { -r - 0.3 } else { r - 1.5 }], [1.5, t, if flexor { -r + 1.5 } else { r + 0.3 }]), [0.0, 0.0, s * r]),
            Ax::Z => (bx([-1.5, if flexor { -r - 0.3 } else { r - 1.5 }, -t], [1.5, if flexor { -r + 1.5 } else { r + 0.3 }, t]), [0.0, s * r, 0.0]),
        }
    }

    fn study(&self) -> Study {
        let (w2, h2) = (self.w / 2.0, self.h / 2.0);
        let o = [0.0; 3];
        let cd = [self.len, 0.0, 0.0];
        let ap = self.prox.v();
        let span = |a: Ax| if a == Ax::Y { w2 } else { h2 };
        let b = self.brg;
        let (t, drum) = (b.tongue(), b.pulley() + 0.3);
        let xmax = if self.tip { self.len + 0.5 } else { self.len + self.next.map_or(4.5, |n| n.lug()) + 0.6 };
        // The tongue: the pulley drum round two bearing seats, the pin's clearance through.
        let mut keep_in = vec![cyl(o, ap, -t, t, drum)];
        let mut keep_out = vec![cyl(o, ap, -b.width, b.width, b.od / 2.0), cyl(o, ap, -span(self.prox) - 1.0, span(self.prox) + 1.0, b.bore / 2.0 + 0.3)];
        // Room for the parent's lugs to turn beside the tongue.
        let parent_lug = b.lug() + 0.8;
        keep_out.push(cyl(o, ap, t + 0.4, span(self.prox) + 1.0, parent_lug));
        keep_out.push(cyl(o, ap, -span(self.prox) - 1.0, -t - 0.4, parent_lug));
        let mut lugs = Vec::new();
        if let (Some(ad), Some(n)) = (self.dist, self.next) {
            let a = ad.v();
            let s = span(ad);
            let gap = n.tongue() + 0.4;
            lugs = vec![tube(cd, a, gap, s, n.bore / 2.0, n.lug()), tube(cd, a, -s, -gap, n.bore / 2.0, n.lug())];
            keep_in.extend(lugs.iter().copied());
            // The pin, pressed in (nominal bore).
            keep_out.push(cyl(cd, a, -s - 1.0, s + 1.0, n.bore / 2.0));
            // The next link's drum and its swing.
            let swing = n.pulley() + 1.0;
            keep_out.push(cyl(cd, a, -gap, gap, swing));
            let (lo, hi) = (cd[0] - swing, xmax + 1.0);
            keep_out.push(match ad {
                Ax::Y => bx([lo, -gap, -h2 - 1.0], [hi, gap, h2 + 1.0]),
                Ax::Z => bx([lo, -w2 - 1.0, -gap], [hi, w2 + 1.0, gap]),
            });
        }
        // Channels for the tendons of the joints after this one: flexors palmar, extensors dorsal.
        if self.down > 0 {
            let (x0, x1) = (drum + 1.0, self.len - self.next.map_or(0.0, |n| n.pulley() + 1.5));
            let half = 0.5 * self.down as f64 + 0.2;
            if x1 > x0 {
                keep_out.push(bx([x0, -half, -h2 + 0.9], [x1, half, -h2 + 2.1]));
                keep_out.push(bx([x0, -half, h2 - 2.1], [x1, half, h2 - 0.9]));
            }
        }
        let pad = self.tip.then(|| {
            let (c, r) = self.pad();
            let p = Region::Sphere { center: c, radius: r };
            keep_in.push(p);
            // A core from the drum to the pad, so the pad is always joined to the bearings (the
            // optimiser once left it on grey material only). 3.6 mm square: at 2.8 the core alone
            // sat at the stress limit and the optimiser, which cannot thin a keep-in, could not
            // get the middle distal under it.
            let core = 1.8;
            keep_in.push(match self.prox {
                Ax::Y => bx([drum - 0.5, -core, c[2] - core], [c[0], core, c[2] + core]),
                Ax::Z => bx([drum - 0.5, -core, -core], [c[0], core, core]),
            });
            p
        });
        let tip = self.tip_point();
        // The reaction that holds this link's own pulley moment `m` (about `ap`): a force at
        // `q` square to the axis.
        let hold = |m: f64, q: V3| -> V3 {
            let qp = sub(q, scale(ap, dot(ap, q)));
            scale(cross(ap, qp), -m / dot(qp, qp))
        };
        let mut cases = Vec::new();
        for (name, flexor) in [("flexor at the tendon cap", true), ("extensor at the tendon cap", false)] {
            let mut loads = Vec::new();
            let mut m = 0.0;
            for (side, tension) in [(flexor, T_ACTIVE), (!flexor, T_PRE)] {
                let (region, p) = self.anchor(side);
                let f = [-tension, 0.0, 0.0];
                loads.push(Load::Force { region, force: f });
                m += dot(cross(p, f), ap);
            }
            match pad {
                // At the pad's centre, where the force spread on its nodes acts: the tendons'
                // moment about the joint is balanced exactly (the seat is held on all three
                // axes, so any left over would be taken by a pin that cannot take it).
                Some(p) => loads.push(Load::Force { region: p, force: hold(m, self.pad().0) }),
                None => {
                    // The next link held still: its push back, and the downstream tendons'
                    // pull through the pin.
                    let f = add(hold(m, cd), [-T_PAIR * self.down as f64, 0.0, 0.0]);
                    for l in &lugs {
                        loads.push(Load::Force { region: *l, force: scale(f, 0.5) });
                    }
                }
            }
            cases.push(LoadCase { name: name.into(), loads, acceleration: None, weight: 1.0 });
        }
        // A side push at the fingertip, tendons at pretension.
        let f = [0.0, SIDE, 0.0];
        let mut loads = Vec::new();
        for side in [true, false] {
            let (region, _) = self.anchor(side);
            loads.push(Load::Force { region, force: [-T_PRE, 0.0, 0.0] });
        }
        match pad {
            Some(p) => loads.push(Load::Force { region: p, force: f }),
            None => {
                let ad = self.dist.unwrap().v();
                let m = cross(sub(tip, cd), f);
                let mp = sub(m, scale(ad, dot(m, ad)));
                for l in &lugs {
                    loads.push(Load::Force { region: *l, force: add(scale(f, 0.5), [-T_PRE * self.down as f64, 0.0, 0.0]) });
                    if norm(mp) > 1e-9 {
                        loads.push(Load::Torque { region: *l, center: cd, axis: unit(mp), moment: 0.5 * norm(mp) });
                    }
                }
            }
        }
        cases.push(LoadCase { name: "side push".into(), loads, acceleration: None, weight: 1.0 });
        cases.push(LoadCase { name: "drop 100 g".into(), loads: Vec::new(), acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
        Study {
            name: self.name.clone(),
            min: [-drum - 0.6, -w2, -h2],
            max: [xmax, w2, h2],
            voxel: self.voxel,
            material: alsi10mg(),
            supports: vec![Support { region: tube(o, ap, -b.width, b.width, b.od / 2.0 - 0.05, b.od / 2.0 + 1.0), fix: [true; 3] }],
            cases,
            keep_in,
            keep_out,
            objective: Objective::Mass,
            volume_fraction: 0.5,
            safety_factor: 2.0,
            // The fingertip (or the next joint) moves no more than this under the tendon cases.
            max_displacement: Some(LINK_MAX_DISP),
            min_member: 1.2,
            manufacturing: Manufacturing::Additive { build: [0.0, 0.0, 1.0], overhang: 45.0 },
            iterations: 30,
            smoothing: 10,
            dynamics: solid::Dynamics { modes: 3, impacts: Vec::new() },
            ..Study::default()
        }
    }
}

/// A part placed in the hand.
struct Placed {
    study: Study,
    pose: Pose,
    parent: Option<String>,
    /// To the parent: name, origin and axis in the hand frame, limits (deg), the bearings in
    /// the child and the pin in the parent.
    joint: Option<(String, V3, V3, [f64; 2], Option<Brg>)>,
    tip: Option<Phalanx>,
    dof: Option<String>,
    /// The joint's angle in this pose, radians.
    rest: f64,
}

struct FingerDims {
    name: &'static str,
    prox: f64,
    mid: f64,
    dist: f64,
    w: [f64; 3],
    h: [f64; 3],
}

fn finger_links(f: &FingerDims) -> Vec<Phalanx> {
    let n = f.name;
    let reach = [f.prox + f.mid + f.dist, f.mid + f.dist, f.dist, 0.0];
    let link = |k: usize, name: &str, dof: &str, len: f64, w: f64, h: f64, prox: Ax, dist: Option<Ax>, down: usize, voxel: f64| Phalanx {
        name: format!("{n}_{name}"),
        dof: format!("{n}/{dof}"),
        len,
        w,
        h,
        prox,
        dist,
        brg: B693,
        next: dist.map(|_| B693),
        down,
        reach: reach[k],
        tip: dist.is_none(),
        voxel,
    };
    vec![
        link(0, "knuckle", "MCP_abd", 13.0, f.w[0] - 1.0, 18.0, Ax::Z, Some(Ax::Y), 3, 0.6),
        link(1, "proximal", "MCP_flex", f.prox, f.w[0], f.h[0], Ax::Y, Some(Ax::Y), 2, 0.55),
        link(2, "middle", "PIP", f.mid, f.w[1], f.h[1], Ax::Y, Some(Ax::Y), 1, 0.55),
        link(3, "distal", "DIP", f.dist, f.w[2], f.h[2], Ax::Y, None, 0, 0.5),
    ]
}

fn deg(d: f64) -> f64 {
    d.to_radians()
}

/// Places a chain from `base` (the first link's proximal joint frame in the hand), with joint
/// angles (radians, about each link's proximal axis).
fn place_chain(links: Vec<Phalanx>, base: Pose, angles: &[f64], limits: &[[f64; 2]], parent: &str, out: &mut Vec<Placed>) {
    let mut frame = base;
    let mut parent = parent.to_string();
    let mut prev: Option<Phalanx> = None;
    for (k, l) in links.into_iter().enumerate() {
        let pose = frame.then(&Pose::rot(l.prox.v(), angles[k]));
        let axis = pose.vector(l.prox.v());
        let joint = Some((format!("{}", l.dof), pose.t, axis, limits[k], Some(l.brg)));
        frame = pose.then(&Pose::trans([l.len, 0.0, 0.0]));
        let name = l.name.clone();
        let dof = Some(l.dof.clone());
        let mut study = l.study();
        // A flexion joint (y after y): the parent's palmar body behind the joint, beside the
        // tongue's slot from 5.5 mm (past its lugs) and in the slot from 7.5 mm (past the
        // child's drum swing), seen from the child over the joint's range: the child keeps out
        // of it, so the two links do not meet palmar side as the joint folds.
        if let Some(pp) = prev.as_ref().filter(|pp| l.prox == Ax::Y && pp.dist == Some(Ax::Y)) {
            let gap = l.brg.tongue() + 0.4;
            let (w, h) = (pp.w / 2.0, pp.h / 2.0);
            let back = pp.len - pp.brg.pulley() - 1.0;
            let bodies = [[[-back, gap, -h], [-5.5, w, 0.0]], [[-back, -w, -h], [-5.5, -gap, 0.0]], [[-back, -gap, -h], [-7.5, gap, 0.0]]];
            let poses: Vec<Pose> = samples(limits[k], 2.0).into_iter().map(|t| Pose::rot([0.0, 1.0, 0.0], -t.to_radians())).collect();
            let regions = swept_out(&study, &bodies, &poses, 0.3);
            study.keep_out.extend(regions);
        }
        out.push(Placed { study, pose, parent: Some(parent.clone()), joint, tip: l.tip.then(|| l.clone()), dof, rest: angles[k] });
        prev = Some(l);
        parent = name;
    }
}

/// A frame whose z is `a`, at `c`.
fn frame_z(a: V3, c: V3) -> Pose {
    let a = unit(a);
    let helper = if a[0].abs() < 0.9 { [1.0, 0.0, 0.0] } else { [0.0, 1.0, 0.0] };
    let u = unit(cross(helper, a));
    let v = cross(a, u);
    Pose::from_axes(u, v, a, c)
}

/// The external loads on a joint (tips downstream, their forces): the force and the moments
/// square to the axis on the bosses, the moment along it on `holders` (a motor's case), if any.
fn joint_loads(boss: &[Region], c: V3, a: V3, tips: &[(V3, V3)], holders: &[Region], loads: &mut Vec<Load>) {
    let (mut f, mut m) = ([0.0; 3], [0.0; 3]);
    for (p, fp) in tips {
        f = add(f, *fp);
        m = add(m, cross(sub(*p, c), *fp));
    }
    let ma = dot(m, a);
    let mp = sub(m, scale(a, ma));
    let k = 1.0 / boss.len() as f64;
    for b in boss {
        loads.push(Load::Force { region: *b, force: scale(f, k) });
        if norm(mp) > 1e-9 {
            loads.push(Load::Torque { region: *b, center: c, axis: unit(mp), moment: norm(mp) * k });
        }
    }
    if ma.abs() > 1e-9 && !holders.is_empty() {
        let k = 1.0 / holders.len() as f64;
        for r in holders {
            loads.push(Load::Torque { region: *r, center: c, axis: scale(a, -1.0), moment: ma * k });
        }
    }
}

fn base_study(name: &str, min: V3, max: V3, voxel: f64) -> Study {
    Study {
        name: name.into(),
        min,
        max,
        voxel,
        material: alsi10mg(),
        objective: Objective::Mass,
        // A cap the stress limit, not the budget, decides (0.4 starved the palm and the cross).
        volume_fraction: 0.6,
        safety_factor: 2.0,
        min_member: 1.8,
        manufacturing: Manufacturing::Additive { build: [0.0, 0.0, 1.0], overhang: 45.0 },
        iterations: 40,
        smoothing: 10,
        dynamics: solid::Dynamics { modes: 3, impacts: Vec::new() },
        ..Study::default()
    }
}

/// A clevis on a parent: two lugs about `a` at `c` for a child whose tongue holds `b`, the pin
/// pressed in, the child's drum free to turn, and its slot toward `toward`.
fn clevis(s: &mut Study, c: V3, a: V3, b: Brg, half: f64) -> [Region; 2] {
    let gap = b.tongue() + 0.4;
    let lugs = [tube(c, a, gap, half, b.bore / 2.0, b.lug()), tube(c, a, -half, -gap, b.bore / 2.0, b.lug())];
    s.keep_in.extend(lugs);
    s.keep_out.push(cyl(c, a, -half - 1.0, half + 1.0, b.bore / 2.0));
    s.keep_out.push(cyl(c, a, -gap, gap, b.pulley() + 1.0));
    lugs
}

/// A sheath stop: the sheaths butt on its back, their tendons go out through a slot; and the
/// channel the bundle comes in by, from `entry`.
fn sheath_stop(s: &mut Study, at: V3, entry: V3, sheaths: usize) -> Region {
    let d = unit(sub(at, entry));
    let r = (sheaths as f64 * 1.15).sqrt() + 0.4;
    let stop = bx(sub(at, [1.0, r + 1.5, r + 1.5]), add(at, [1.5, r + 1.5, r + 1.5]));
    s.keep_in.push(stop);
    s.keep_out.push(bx(sub(at, [1.5, r, 0.7]), add(at, [2.0, r, 0.7])));
    let len = norm(sub(at, entry)) - 1.0;
    s.keep_out.push(Region::Cylinder { base: entry, axis: d, radius: r, length: len });
    stop
}

/// The palm's wrist neck: it turns about z inside the gimbal cross, so between radius 9.6 and
/// 23.5 it keeps to a wedge of +-21 deg about +x (the cross's arms sweep the rest).
fn neck_keep_out(s: &mut Study) {
    let (zl, zh) = (-15.5, 15.5);
    for sy in [1.0, -1.0] {
        let y = |a: f64, b: f64| if sy > 0.0 { (a, b) } else { (-b, -a) };
        for (x0, x1, y0, y1) in [(-24.0, 8.0, 9.6, 23.6), (8.0, 16.0, 9.6, 22.1), (16.0, 23.5, 9.6, 17.3), (-9.6, -6.8, 6.8, 9.6), (6.8, 9.6, 6.8, 9.6), (9.6, 15.0, 3.7, 9.6), (15.0, 20.0, 5.8, 9.6), (20.0, 24.0, 7.7, 9.6)] {
            let (a, b) = y(y0, y1);
            s.keep_out.push(bx([x0, a, zl], [x1, b, zh]));
        }
    }
    s.keep_out.push(bx([-24.0, -9.6, zl], [-9.6, 9.6, zh]));
}

struct Hand {
    knuckles: [V3; 4],
    cmc: V3,
    cmc_axis: V3,
    /// Fingertips (index, middle, ring, little, thumb): point, grip force, side force.
    tips: Vec<(V3, V3, V3)>,
}

const ARCH_Y: f64 = -12.0;
/// The arch (ring and little side cupping, - cups): flattening past flat is of no use and, with
/// the fingers in the fist, turns the ring finger into the middle one.
const ARCH_LIM: [f64; 2] = [-25.0, 0.0];
/// The ulnar palm's tongue along the arch axis, and the palm's lug before it (ARCH_LUG to
/// ARCH_X[0] - 0.4). 3 mm further out than it was: at 24 mm the lug's lower edge came within
/// the flexion servo's swing at full flexion and ulnar deviation.
const ARCH_X: [f64; 2] = [33.4, 42.6];
const ARCH_LUG: f64 = 27.0;
/// Middle of the arch tongue (the joint), and the arch pin's middle (16 mm from the lug's end).
const ARCH_MID: f64 = 0.5 * (ARCH_X[0] + ARCH_X[1]);
const ARCH_PIN: f64 = ARCH_LUG + 8.0;
/// Where the sheath bundle comes into the palm (palmar side, past the wrist).
const ENTRY: V3 = [14.0, 0.0, -15.5];

fn stops(h: &Hand) -> ([V3; 4], V3, V3) {
    let f = h.knuckles.map(|k| [k[0] - 16.0, k[1], -4.0]);
    // The thumb's stop sits past the neck, clear of the forearm's lug as the wrist deviates.
    // The ring and little stop sits above the finger channels that run under it from ENTRY.
    (f, [25.0, 10.0, -8.0], [24.0, -4.0, -4.0])
}

/// The main palm: index and middle knuckles, the thumb's CMC lugs, the arch hinge, the wrist
/// (two 688ZZ round the deviation pin below, the XM430's horn above), the sheath stops.
fn palm_study(h: &Hand) -> Study {
    let mut s = base_study("palm", [-12.0, -18.0, -15.0], [88.0, 39.0, 15.0], 1.0);
    let z = [0.0, 0.0, 1.0];
    let o = [0.0; 3];
    let (fstop, tstop, astop) = stops(h);
    // Wrist: 688ZZ seats (two) round the deviation pin, the pin's end, the horn disc and its four
    // M2.5 screws (XM430 horn, 16 mm bolt circle: UNCONFIRMED), the gimbal's swing.
    let seat = tube(o, z, -14.6, -4.6, 7.95, 9.4);
    s.keep_in.push(cyl(o, z, -14.6, -2.0, 9.4));
    s.keep_out.push(cyl(o, z, -14.7, -4.6, B688.od / 2.0));
    s.keep_out.push(cyl(o, z, -4.7, -0.6, B688.bore / 2.0 + 0.3));
    let horn = cyl(o, z, 11.0, 15.0, 11.0);
    s.keep_in.push(horn);
    s.keep_out.push(cyl(o, z, 10.0, 16.0, 3.0));
    for k in 0..4 {
        let t = (k as f64 + 0.5) * std::f64::consts::FRAC_PI_2;
        s.keep_out.push(cyl([8.0 * t.cos(), 8.0 * t.sin(), 0.0], z, 10.0, 16.0, 1.35));
    }
    neck_keep_out(&mut s);
    // The forearm's fork when the hand bends +-40 deg: the flexion XM430 on -y, the idler arm
    // (behind the axis, |z| < 10) and its lug on +y.
    s.keep_out.push(bx([-13.0, -19.0, -16.0], [20.0, -14.5, 16.0]));
    s.keep_out.push(bx([20.0, -19.0, 6.0], [32.0, -14.5, 16.0]));
    s.keep_out.push(bx([20.0, -19.0, -16.0], [32.0, -14.5, -6.0]));
    s.keep_out.push(bx([-13.0, 20.3, -16.0], [0.0, 27.5, 16.0]));
    s.keep_out.push(bx([0.0, 20.3, 7.0], [13.0, 27.5, 16.0]));
    s.keep_out.push(bx([0.0, 20.3, -16.0], [13.0, 27.5, -7.0]));
    s.keep_out.push(cyl(o, [0.0, 1.0, 0.0], 20.3, 27.5, 10.5));
    // The cross's 688ZZ housing round the forearm's 8 mm pin, and the pin, as the palm turns
    // +-25 deg about z (radial and ulnar deviation).
    for k in 0..=8 {
        let a = deg(-25.0 + 6.25 * k as f64);
        let ay = [-a.sin(), a.cos(), 0.0];
        s.keep_out.push(cyl(o, ay, 9.4, 20.8, 11.0));
        // The forearm's idler lug past y 20.3 turns with it.
        s.keep_out.push(cyl(o, ay, 20.3, 27.5, 9.8));
    }
    // The pin itself (round about y, so the cross's flexion does not move it in the cross),
    // swept as voxel boxes: as nine exact cylinders their cut surfaces ran into each other.
    let ru: Vec<Pose> = samples(WRIST_RU, 2.5).into_iter().map(|r| forearm_to_palm(0.0, r)).collect();
    let pin = swept_out(&s, &[[[-4.0, 5.4, -4.0], [4.0, 20.3, 4.0]]], &ru, 0.3);
    s.keep_out.extend(pin);
    // The flexion servo (on the forearm) at every corner of the wrist's range.
    let wrist: Vec<Pose> = samples(WRIST_FE, 2.5).into_iter().flat_map(|f| samples(WRIST_RU, 2.5).into_iter().map(move |r| forearm_to_palm(f, r))).collect();
    let xm = swept_out(&s, &[xm_flex()], &wrist, 0.8);
    s.keep_out.extend(xm);
    s.supports = vec![Support { region: seat, fix: [true; 3] }, Support { region: horn, fix: [true; 3] }];
    // The ulnar palm's room, its tongue's swing, the arch lug.
    s.keep_out.push(bx([ARCH_X[0] - 0.6, -19.0, -16.0], [90.0, -5.0, 16.0]));
    s.keep_out.push(cyl([0.0, ARCH_Y, 0.0], [1.0, 0.0, 0.0], ARCH_X[0] - 0.6, ARCH_X[1] + 0.6, B623.pulley() + 1.0));
    let arch = tube([0.0, ARCH_Y, 0.0], [1.0, 0.0, 0.0], ARCH_LUG, ARCH_X[0] - 0.4, B623.bore / 2.0, B623.lug());
    s.keep_in.push(arch);
    s.keep_out.push(cyl([0.0, ARCH_Y, 0.0], [1.0, 0.0, 0.0], ARCH_LUG - 1.0, ARCH_PIN + 9.0, B623.bore / 2.0));
    let mut bosses = Vec::new();
    for k in &h.knuckles[..2] {
        let b = clevis(&mut s, *k, z, B693, 12.0);
        s.keep_out.push(bx([k[0] - B693.pulley() - 1.0, k[1] - 9.5, -B693.tongue() - 0.4], [90.0, k[1] + 9.5, B693.tongue() + 0.4]));
        bosses.push(b);
    }
    let cmc = clevis(&mut s, h.cmc, h.cmc_axis, B623, 10.5);
    // The saddle's body between the lugs (|z| under 5 in its frame, out to 12.7 mm from the
    // axis behind and beside the drum) turns in this slot.
    let gap = B623.tongue() + 0.4;
    s.keep_out.push(cyl(h.cmc, h.cmc_axis, -gap, gap, 13.0));
    // Sheath stops: 8 sheaths per finger, 10 for the thumb, 2 for the arch; the ring and little
    // bundles go on through to the ulnar palm.
    let fs: Vec<Region> = fstop[..2].iter().map(|p| sheath_stop(&mut s, *p, ENTRY, 8)).collect();
    let ts = sheath_stop(&mut s, tstop, ENTRY, 10);
    let asp = sheath_stop(&mut s, astop, ENTRY, 2);
    for p in &fstop[2..] {
        let r = (8.0f64 * 1.15).sqrt() + 0.4;
        s.keep_out.push(Region::Cylinder { base: ENTRY, axis: unit(sub(*p, ENTRY)), radius: r, length: norm(sub(*p, ENTRY)) - 1.0 });
    }
    let pull = |n: f64, stall: bool| n * if stall { T_PAIR } else { 2.0 * T_PRE };
    for (case, stall) in [("grip at the tendon cap", true), ("side push", false)] {
        let mut loads = Vec::new();
        let tip = |i: usize| (h.tips[i].0, if stall { h.tips[i].1 } else { h.tips[i].2 });
        for i in 0..2 {
            joint_loads(&bosses[i], h.knuckles[i], z, &[tip(i)], &[], &mut loads);
            let d = unit(sub(fstop[i], h.knuckles[i]));
            for l in &bosses[i] {
                loads.push(Load::Force { region: *l, force: scale(d, 0.5 * pull(4.0, stall)) });
            }
            loads.push(Load::Force { region: fs[i], force: scale(unit(sub(fstop[i], ENTRY)), pull(4.0, stall)) });
        }
        joint_loads(&cmc, h.cmc, h.cmc_axis, &[tip(4)], &[], &mut loads);
        let d = unit(sub(tstop, h.cmc));
        for l in &cmc {
            loads.push(Load::Force { region: *l, force: scale(d, 0.5 * pull(5.0, stall)) });
        }
        loads.push(Load::Force { region: ts, force: scale(unit(sub(tstop, ENTRY)), pull(5.0, stall)) });
        // The ulnar palm on its hinge (the arch tendon holds the moment about x).
        joint_loads(&[arch], [0.5 * (ARCH_LUG + ARCH_X[0] - 0.4), ARCH_Y, 0.0], [1.0, 0.0, 0.0], &[tip(2), tip(3)], &[], &mut loads);
        let d = unit(sub(astop, [ARCH_MID, ARCH_Y, -8.0]));
        loads.push(Load::Force { region: arch, force: scale(d, -pull(1.0, stall)) });
        loads.push(Load::Force { region: asp, force: scale(unit(sub(astop, ENTRY)), pull(1.0, stall)) });
        s.cases.push(LoadCase { name: case.into(), loads, acceleration: None, weight: 1.0 });
    }
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: Vec::new(), acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
    // The sheath stops take every tendon pair's pull (545 N on the thumb's at the cap): a mass
    // run under the stress limit once thinned the palm to 15.7 g at 895 MPa as built, so the
    // palm is grown stiffest for a fixed budget and the limit is checked on what it built.
    s.objective = Objective::Compliance;
    s.volume_fraction = 0.25;
    // Members of 1.8 mm met at voxel edges only (four bodies face to face); 2.5 mm joins them.
    s.min_member = 2.5;
    s
}

/// The ulnar palm: turns about x on the arch hinge (two 623ZZ in its tongue), carries the ring
/// and little knuckles and their sheath stops.
fn ulnar_study(h: &Hand) -> Study {
    let mut s = base_study("palm_ulnar", [ARCH_X[0], -44.0, -15.0], [86.0, -6.4, 15.0], 0.9);
    let z = [0.0, 0.0, 1.0];
    let ax = [1.0, 0.0, 0.0];
    let c = [0.0, ARCH_Y, 0.0];
    let (fstop, _, astop) = stops(h);
    s.keep_in.push(cyl(c, ax, ARCH_X[0], ARCH_X[1], B623.pulley() + 0.3));
    s.keep_out.push(cyl(c, ax, ARCH_X[0] + 0.6, ARCH_X[1] - 0.6, B623.od / 2.0));
    s.keep_out.push(cyl(c, ax, ARCH_X[0] - 1.0, ARCH_X[1] + 1.0, B623.bore / 2.0 + 0.3));
    s.supports = vec![Support { region: tube(c, ax, ARCH_X[0] + 0.6, ARCH_X[1] - 0.6, B623.od / 2.0 - 0.05, B623.od / 2.0 + 1.0), fix: [true; 3] }];
    let mut bosses = Vec::new();
    for k in &h.knuckles[2..] {
        let b = clevis(&mut s, *k, z, B693, 12.0);
        s.keep_out.push(bx([k[0] - B693.pulley() - 1.0, k[1] - 9.0, -B693.tongue() - 0.4], [90.0, k[1] + 9.0, B693.tongue() + 0.4]));
        bosses.push(b);
    }
    let fs: Vec<Region> = fstop[2..].iter().map(|p| sheath_stop(&mut s, *p, ENTRY, 8)).collect();
    // The flexion XM430 (on the forearm) at every corner of the wrist's and the arch's range.
    let mut poses = Vec::new();
    for a in samples(ARCH_LIM, 5.0) {
        let arch = turn(c, ax, -a);
        for f in samples(WRIST_FE, 2.5) {
            for r in samples(WRIST_RU, 2.5) {
                poses.push(arch.then(&forearm_to_palm(f, r)));
            }
        }
    }
    let xm = swept_out(&s, &[xm_flex()], &poses, 0.8);
    s.keep_out.extend(xm);
    // The arch tendon on the drum's palmar side, pulled toward its stop on the main palm.
    let anchor = bx([ARCH_MID - 1.5, ARCH_Y - 1.5, -B623.pulley() - 0.3], [ARCH_MID + 1.5, ARCH_Y + 1.5, -B623.pulley() + 1.5]);
    let ad = unit(sub(astop, [ARCH_MID, ARCH_Y, -8.0]));
    let pull = |n: f64, stall: bool| n * if stall { T_PAIR } else { 2.0 * T_PRE };
    for (case, stall) in [("grip at the tendon cap", true), ("side push", false)] {
        let mut loads = Vec::new();
        for i in 0..2 {
            let t = &h.tips[2 + i];
            joint_loads(&bosses[i], h.knuckles[2 + i], z, &[(t.0, if stall { t.1 } else { t.2 })], &[], &mut loads);
            let d = unit(sub(fstop[2 + i], h.knuckles[2 + i]));
            for l in &bosses[i] {
                loads.push(Load::Force { region: *l, force: scale(d, 0.5 * pull(4.0, stall)) });
            }
            loads.push(Load::Force { region: fs[i], force: scale(unit(sub(fstop[2 + i], ENTRY)), pull(4.0, stall)) });
        }
        loads.push(Load::Force { region: anchor, force: scale(ad, pull(1.0, stall)) });
        s.cases.push(LoadCase { name: case.into(), loads, acceleration: None, weight: 1.0 });
    }
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: Vec::new(), acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
    s
}

/// XM430-W350-T, 28.5 x 46.5 x 34 (W x H x D, shaft along D, 11.25 mm from one end of H).
const XM_W: f64 = 28.5;
const XM_H: f64 = 46.5;
const XM_D: f64 = 34.0;
const XM_SHAFT: f64 = 11.25;

/// The deviation servo on the cross: shaft down along -z, horn face at z = 15, its body above.
fn xm_dev() -> [V3; 2] {
    [[-(XM_H - XM_SHAFT), -XM_W / 2.0, 15.0], [XM_SHAFT, XM_W / 2.0, 15.0 + XM_D]]
}

/// The flexion servo in the forearm: shaft along +y, horn face at y = -15, its body back toward
/// the bank (along -x). Lying this way its far corner stays within 18 mm of the flexion axis on
/// the hand's side; standing (body below, as it was) its lower corner swung to 34 mm as the
/// hand flexed and met the palm, the ulnar palm and the arch pin in ulnar deviation.
fn xm_flex() -> [V3; 2] {
    [[-(XM_H - XM_SHAFT), -15.0 - XM_D, -XM_W / 2.0], [XM_SHAFT, -15.0, XM_W / 2.0]]
}

/// The gimbal cross: bolted to the flexion servo's horn on -y, two 688ZZ on +y round the
/// forearm's pin, the deviation pin pressed in below, the deviation servo above.
fn cross_study(h: &Hand) -> Study {
    let o = [0.0; 3];
    let (y, z) = ([0.0, 1.0, 0.0], [0.0, 0.0, 1.0]);
    let mut s = base_study("wrist_cross", [-37.0, -15.0, -22.0], [13.0, 20.2, 51.0], 1.0);
    // Horn plate and its four M2.5 screws.
    let horn = cyl(o, y, -15.0, -11.0, 11.0);
    s.keep_in.push(horn);
    s.keep_out.push(cyl(o, y, -16.0, -10.0, 3.0));
    for k in 0..4 {
        let t = (k as f64 + 0.5) * std::f64::consts::FRAC_PI_2;
        s.keep_out.push(cyl([8.0 * t.cos(), 0.0, 8.0 * t.sin()], y, -16.0, -10.0, 1.35));
    }
    // 688ZZ seats round the forearm's 8 mm pin.
    let seat = tube(o, y, 10.0, 20.0, 7.95, 9.0);
    s.keep_in.push(cyl(o, y, 10.0, 20.2, 10.5));
    s.keep_out.push(cyl(o, y, 9.9, 20.3, B688.od / 2.0));
    s.keep_out.push(cyl(o, y, 5.5, 10.0, B688.bore / 2.0 + 0.3));
    // The deviation pin's lug below.
    let lug = tube(o, z, -21.0, -15.0, B688.bore / 2.0, 9.0);
    s.keep_in.push(lug);
    s.keep_out.push(cyl(o, z, -22.0, -1.0, B688.bore / 2.0));
    // The deviation servo: its body, the top plate with four M2.5 screws, a side pad (+y).
    let body = xm_dev();
    s.keep_out.push(bx(sub(body[0], [0.5; 3]), [body[1][0] + 0.5, body[1][1] + 0.5, body[1][2]]));
    let top = bx([body[0][0] + 2.0, -12.0, body[1][2]], [body[1][0] - 2.0, 12.0, body[1][2] + 1.6]);
    s.keep_in.push(top);
    for (px, py) in [(-28.0, 8.0), (-28.0, -8.0), (4.0, 8.0), (4.0, -8.0)] {
        s.keep_out.push(cyl([px, py, 0.0], z, body[1][2] - 1.0, body[1][2] + 3.0, 1.35));
    }
    let side = bx([-30.0, body[1][1] + 0.5, 18.0], [-4.0, body[1][1] + 2.0, 46.0]);
    s.keep_in.push(side);
    // The palm turning inside: its core, its horn disc, its body beyond, its neck (+-21 deg).
    s.keep_out.push(cyl(o, z, -15.5, 15.5, 10.0));
    s.keep_out.push(cyl(o, z, 11.0, 15.0, 12.0));
    s.keep_out.push(bx([-38.0, -10.0, -15.5], [14.0, 10.0, 15.5]));
    s.keep_out.push(bx([10.5, -16.0, -15.5], [14.0, 21.0, 15.5]));
    s.keep_out.push(bx([-38.0, -16.0, -15.5], [-10.5, 21.0, 15.5]));
    s.supports = vec![Support { region: horn, fix: [true; 3] }, Support { region: seat, fix: [true; 3] }];
    for (case, grip) in [("grip at stall", true), ("side push", false)] {
        let mut loads = Vec::new();
        let tips: Vec<(V3, V3)> = h.tips.iter().map(|t| (t.0, if grip { t.1 } else { t.2 })).collect();
        joint_loads(&[lug, top], o, z, &tips, &[top, side], &mut loads);
        s.cases.push(LoadCase { name: case.into(), loads, acceleration: None, weight: 1.0 });
    }
    // The deviation servo held at stall (the hand blocked): its case turns the plate and pad
    // back with 4.1 N m about the shaft.
    s.cases.push(LoadCase { name: "deviation servo stall".into(), loads: vec![Load::Torque { region: top, center: o, axis: z, moment: 0.5 * XM_STALL_NMM }, Load::Torque { region: side, center: o, axis: z, moment: 0.5 * XM_STALL_NMM }], acceleration: None, weight: 1.0 });
    // The deviation servo (82 g) at 100 g on its plate and pad, and the hand below on the pin.
    let g = DROP_G * 9.81e-3;
    let drop = vec![
        Load::Force { region: top, force: [0.0, 0.0, -0.5 * 82.0 * g] },
        Load::Force { region: side, force: [0.0, 0.0, -0.5 * 82.0 * g] },
        Load::Force { region: lug, force: [0.0, 0.0, -HAND_G * g] },
    ];
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: drop, acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
    s
}

/// Palm, fingers, thumb and their bearings, pins and sensors, for the drop cases (g): the
/// grown parts' masses are not known before they are grown.
const HAND_G: f64 = 300.0;

/// The XC330 bank: 3 across, 4 along, two layers (horns up on top, down below), 22 of the 24
/// places used. XC330-T288-T: 20 (y) x 34 (x) x 26 (z, along the shaft); the horn's place along
/// the case is from memory (10 mm from the wrist end): UNCONFIRMED.
fn bank() -> Vec<(String, V3, f64)> {
    let mut out = Vec::new();
    for (layer, sz) in [("top", 1.0), ("bottom", -1.0)] {
        for (row, x) in [-106.5, -143.5, -180.5, -217.5].into_iter().enumerate() {
            for (col, y) in [-22.0, 0.0, 22.0].into_iter().enumerate() {
                if sz < 0.0 && row == 3 && col != 1 {
                    continue;
                }
                out.push((format!("{layer} r{} c{}", row + 1, col + 1), [x, y, sz * 2.0], sz));
            }
        }
    }
    out
}

const XC: [f64; 3] = [34.0, 20.0, 26.0];
const SPOOL_R: f64 = 6.0;
const BAR_X: [f64; 2] = [-88.0, -84.0];

fn servo_box(c: V3, sz: f64) -> [V3; 2] {
    let (a, b) = (c[2], c[2] + sz * XC[2]);
    [[c[0] - XC[0] / 2.0, c[1] - XC[1] / 2.0, a.min(b)], [c[0] + XC[0] / 2.0, c[1] + XC[1] / 2.0, a.max(b)]]
}

fn spool_at(c: V3, sz: f64) -> V3 {
    [c[0] + XC[0] / 2.0 - 10.0, c[1], c[2] + sz * XC[2]]
}

/// Boards on the ulnar side of the bank: OpenRB-150, two U2D2 Power Hubs, the U2D2.
fn boards() -> Vec<(&'static str, &'static str, [V3; 2])> {
    vec![
        ("U1", "OpenRB-150", [[-234.0, -45.0, -12.5], [-168.0, -35.0, 12.5]]),
        ("D1", "Power Hub A", [[-164.0, -45.0, -13.0], [-118.0, -33.0, 13.0]]),
        ("D1", "Power Hub B", [[-114.0, -45.0, -13.0], [-68.0, -33.0, 13.0]]),
        ("D2", "U2D2", [[-234.0, -51.0, 14.0], [-186.0, -33.0, 28.6]]),
    ]
}

/// The forearm frame: the 22 servos on pads with four M2 each, the sheath stop bar every tendon
/// pulls against, the flexion XM430 on a back plate (four M2.5), the idler lug with its 8 mm pin,
/// the boards, the flange to the arm (four M3), room for the gimbal to swing.
fn forearm_study(h: &Hand) -> Study {
    let (y, z) = ([0.0, 1.0, 0.0], [0.0, 0.0, 1.0]);
    let o = [0.0; 3];
    let mut s = base_study("forearm_frame", [-241.0, -54.0, -29.0], [10.0, 27.0, 29.0], 1.25);
    s.min_member = 2.5;
    // Stiffest for its mass: with the stress-constrained mass objective the long arm round the
    // gimbal to the idler lug starves early, the lug loads hang on grey material and MMA breaks
    // down (numbers that are not finite), as the drone's cage did.
    s.objective = Objective::Compliance;
    s.volume_fraction = 0.22;
    let mut pads = Vec::new();
    // Each servo kept out with 0.5 mm round it, 1 mm on a side that faces the next column: the
    // 2 mm between two columns is left empty (a wall there is under two voxels and its surface
    // ran into the cases). The outer sides keep 0.5 mm, so the wall to the boards stays thick.
    for (_, c, sz) in bank() {
        let b = servo_box(c, sz);
        let (ylo, yhi) = (if c[1] > -11.0 { 1.0 } else { 0.5 }, if c[1] < 11.0 { 1.0 } else { 0.5 });
        s.keep_out.push(bx(sub(b[0], [0.5, ylo, 0.5]), add(b[1], [0.5, yhi, 0.5])));
        let sp = spool_at(c, sz);
        s.keep_out.push(cyl(sp, z, if sz > 0.0 { 0.0 } else { -12.0 }, if sz > 0.0 { 12.0 } else { 0.0 }, SPOOL_R + 3.5));
        // The pad under the case (opposite the horn) and its four M2 screws.
        let pz = if sz > 0.0 { [c[2] - 2.0, c[2] - 0.5] } else { [c[2] + 0.5, c[2] + 2.0] };
        let pad = bx([b[0][0], b[0][1], pz[0]], [b[1][0], b[1][1], pz[1]]);
        s.keep_in.push(pad);
        for (dx, dy) in [(-12.0, -6.0), (-12.0, 6.0), (12.0, -6.0), (12.0, 6.0)] {
            s.keep_out.push(cyl([c[0] + dx, c[1] + dy, 0.0], z, pz[0] - 1.0, pz[1] + 1.0, 1.1));
        }
        pads.push((pad, [c[0], c[1], 0.5 * (pz[0] + pz[1])], sp));
    }
    let bar = bx([BAR_X[0], -32.0, -29.0], [BAR_X[1], 32.0, 29.0]);
    s.keep_in.push(bar);
    // The flexion servo, its back plate and four M2.5 screws (pattern UNCONFIRMED).
    let m = xm_flex();
    s.keep_out.push(bx(sub(m[0], [0.5; 3]), add(m[1], [0.5; 3])));
    // Two voxels and more thick, so the servo's keep-out beside it never voids it.
    let back = bx([m[0][0] + 2.5, m[0][1] - 4.0, -12.0], [m[1][0] - 2.5, m[0][1] - 0.5, 12.0]);
    s.keep_in.push(back);
    for (px, pz) in [(-28.0, -8.0), (-28.0, 8.0), (4.0, -8.0), (4.0, 8.0)] {
        s.keep_out.push(cyl([px, 0.0, pz], y, m[0][1] - 5.0, m[0][1] + 1.0, 1.35));
    }
    // The idler lug with the 8 x 20 pin pressed in (20.4 to 25.4, the pin's last mm standing
    // proud): past 25.4 the thumb's CMC drum swings by as the wrist deviates.
    let lug = tube(o, y, 20.4, 25.4, B688.bore / 2.0, 9.0);
    s.keep_in.push(lug);
    s.keep_out.push(cyl(o, y, 6.0, 28.0, B688.bore / 2.0));
    s.keep_out.push(cyl(o, y, 25.4, 29.0, 10.5));
    // The gimbal cross and the deviation servo swinging about y; on the idler side the arm
    // stays behind the axis and within |z| < 10, so the thumb's base swings clear.
    s.keep_out.push(cyl(o, y, -14.9, 20.3, 63.0));
    s.keep_out.push(bx([-63.0, 20.3, 10.0], [11.0, 28.0, 30.0]));
    s.keep_out.push(bx([-63.0, 20.3, -30.0], [11.0, 28.0, -10.0]));
    // The idler arm: from the lug back past the gimbal's swing to the frame, in the band the
    // swing leaves (y 20.3 to 27, |z| < 10), so the lug is always joined to the frame.
    s.keep_in.push(bx([-72.0, 20.8, -6.0], [-4.0, 26.6, 6.0]));
    // Each board on a pad under its outer face (two voxels and more thick); the U2D2, which sits
    // over the OpenRB-150, on a pad off the flange at its end.
    for (reference, _, b) in boards() {
        s.keep_out.push(bx(sub(b[0], [0.6, 0.3, 0.6]), add(b[1], [0.6, 0.3, 0.6])));
        if reference == "D2" {
            s.keep_in.push(bx([-238.5, b[0][1] + 2.0, b[0][2] + 1.0], [b[0][0] - 0.6, b[1][1] - 2.0, b[1][2] - 1.0]));
        } else {
            s.keep_in.push(bx([b[0][0] + 2.0, b[0][1] - 3.0, b[0][2] + 1.0], [b[1][0] - 2.0, b[0][1] - 0.3, b[1][2] - 1.0]));
        }
    }
    // Flange to the arm, four M3 (F3 into I2 inserts on the arm side).
    let flange = bx([-241.0, -32.0, -28.0], [-238.0, 22.0, 28.0]);
    s.keep_in.push(flange);
    for (py, pz) in [(-25.0, -20.0), (-25.0, 20.0), (15.0, -20.0), (15.0, 20.0)] {
        s.keep_out.push(Region::Cylinder { base: [-242.0, py, pz], axis: [1.0, 0.0, 0.0], radius: 1.6, length: 5.0 });
    }
    s.supports = vec![Support { region: flange, fix: [true; 3] }];
    // Every flexor at the tendon cap and its extensor at pretension: the servos pulled toward
    // the bar, the bar pushed back by the sheaths.
    let mut loads = Vec::new();
    let t = T_PAIR;
    for (pad, pc, sp) in &pads {
        let d = unit(sub([BAR_X[0], sp[1], sp[2]], *sp));
        let f = scale(d, t);
        loads.push(Load::Force { region: *pad, force: f });
        let mo = cross(sub(*sp, *pc), f);
        loads.push(Load::Torque { region: *pad, center: *pc, axis: unit(mo), moment: norm(mo) });
    }
    loads.push(Load::Force { region: bar, force: [-t * pads.len() as f64, 0.0, 0.0] });
    s.cases.push(LoadCase { name: "tendons at the cap".into(), loads, acceleration: None, weight: 1.0 });
    // The wrist's cases are small next to the 22 tendons; weighted up so the stiffest layout
    // does not leave the wrist on grey material.
    for (case, grip) in [("grip at the wrist", true), ("side push", false)] {
        let mut loads = Vec::new();
        let tips: Vec<(V3, V3)> = h.tips.iter().map(|t| (t.0, if grip { t.1 } else { t.2 })).collect();
        joint_loads(&[lug, back], o, y, &tips, &[back], &mut loads);
        s.cases.push(LoadCase { name: case.into(), loads, acceleration: None, weight: 20.0 });
    }
    // The flexion servo held at stall (the hand blocked): its case turns the back plate with
    // 4.1 N m about the shaft (y), into the four M2.5 screws.
    s.cases.push(LoadCase { name: "flexion servo stall".into(), loads: vec![Load::Torque { region: back, center: [0.0, xm_flex()[1][1], 0.0], axis: y, moment: XM_STALL_NMM }], acceleration: None, weight: 20.0 });
    let g = DROP_G * 9.81e-3;
    let mut drop: Vec<Load> = pads.iter().map(|(p, _, _)| Load::Force { region: *p, force: [0.0, 0.0, -23.0 * g] }).collect();
    drop.push(Load::Force { region: back, force: [0.0, 0.0, -82.0 * g] });
    drop.push(Load::Force { region: lug, force: [0.0, 0.0, -0.5 * (HAND_G + 82.0 + 60.0) * g] });
    drop.push(Load::Force { region: back, force: [0.0, 0.0, -0.5 * (HAND_G + 82.0 + 60.0) * g] });
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: drop, acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 10.0 });
    s
}

fn main() {
    let dir = out_dir("hand");
    let fingers = [
        FingerDims { name: "index", prox: 46.0, mid: 26.0, dist: 20.0, w: [18.0, 16.0, 14.0], h: [15.0, 14.0, 13.6] },
        FingerDims { name: "middle", prox: 51.0, mid: 30.0, dist: 21.0, w: [18.5, 16.5, 14.5], h: [15.5, 14.0, 13.6] },
        FingerDims { name: "ring", prox: 48.0, mid: 29.0, dist: 20.0, w: [17.0, 15.5, 14.0], h: [14.8, 14.0, 13.6] },
        FingerDims { name: "little", prox: 38.0, mid: 21.0, dist: 18.0, w: [15.0, 14.0, 13.6], h: [14.0, 13.6, 13.6] },
    ];
    // Hand frame: origin at the gimbal centre (both wrist axes), x to the fingers, y to the
    // thumb, z out of the back of the hand.
    let knuckles = [[80.0, 18.0, 0.0], [82.0, 0.0, 0.0], [79.0, -18.0, 0.0], [72.0, -35.0, 0.0]];
    let splay = [4.0, 0.0, -4.0, -9.0];
    let curl = [[10.0, 15.0, 10.0], [14.0, 20.0, 12.0], [18.0, 26.0, 14.0], [22.0, 30.0, 16.0]];
    // Joint limits from the straight finger (assembly.json writes them from the rest pose, as
    // the app's sliders read them). MCP abduction: free away from the neighbours, a few degrees
    // toward one (the links are as wide as the knuckle pitch, so a finger that turns toward its
    // neighbour meets it; +z turns toward the thumb). PIP: 105 deg on every finger, cleared by
    // the flexion carve in place_chain. Every value below is the swept probe's (no overlap over
    // 0.5 mm3 at 13 samples, in the fist, the spread and the wrist corners). One coupled limit is
    // left to the controller: with the index fully curled its abduction must stay at 4 deg or
    // less, past that the index middle link meets the middle finger's middle link.
    let abd = [[-2.0, 15.0], [-2.0, 2.0], [-3.0, 2.0], [-15.0, 3.0]];
    let pip_max = [105.0, 105.0, 105.0, 105.0];
    let mut parts: Vec<Placed> = Vec::new();
    for (i, f) in fingers.iter().enumerate() {
        let parent = if i < 2 { "palm" } else { "palm_ulnar" };
        let base = Pose::trans(knuckles[i]).then(&Pose::rot([0.0, 0.0, 1.0], deg(splay[i])));
        let angles = [0.0, deg(curl[i][0]), deg(curl[i][1]), deg(curl[i][2])];
        let limits = [abd[i], [-10.0, 90.0], [0.0, pip_max[i]], [0.0, 80.0]];
        place_chain(finger_links(f), base, &angles, &limits, parent, &mut parts);
    }
    // Thumb: CMC saddle, metacarpal, MCP yoke, proximal, distal.
    let cmc = [18.0, 31.0, -5.0];
    let tx = unit([0.55, 0.75, -0.35]);
    let ty = unit(cross([0.0, 0.0, 1.0], tx));
    let tz = cross(tx, ty);
    let thumb_base = Pose::from_axes(tx, ty, tz, cmc).then(&Pose::rot([1.0, 0.0, 0.0], deg(-35.0)));
    let (meta, tprox, tdist) = (53.0, 38.0, 27.0);
    let th = |name: &str, dof: &str, len: f64, w: f64, h: f64, prox: Ax, dist: Option<Ax>, brg: Brg, next: Option<Brg>, down: usize, reach: f64, voxel: f64| Phalanx {
        name: name.into(),
        dof: dof.into(),
        len,
        w,
        h,
        prox,
        dist,
        brg,
        next,
        down,
        reach,
        tip: dist.is_none(),
        voxel,
    };
    let thumb = vec![
        th("thumb_cmc_saddle", "thumb/CMC_abd", 16.0, 20.0, 20.0, Ax::Z, Some(Ax::Y), B623, Some(B623), 4, meta + 12.0 + tprox + tdist, 0.65),
        th("thumb_metacarpal", "thumb/CMC_flex", meta, 20.0, 18.0, Ax::Y, Some(Ax::Z), B623, Some(B693), 3, 12.0 + tprox + tdist, 0.7),
        th("thumb_mcp_yoke", "thumb/MCP_abd", 12.0, 18.0, 16.0, Ax::Z, Some(Ax::Y), B693, Some(B693), 2, tprox + tdist, 0.55),
        th("thumb_proximal", "thumb/MCP_flex", tprox, 18.0, 15.0, Ax::Y, Some(Ax::Y), B693, Some(B693), 1, tdist, 0.6),
        th("thumb_distal", "thumb/IP", tdist, 16.0, 14.0, Ax::Y, None, B693, None, 0, 0.0, 0.5),
    ];
    place_chain(thumb, thumb_base, &[0.0, deg(15.0), 0.0, deg(15.0), deg(10.0)], &[[-30.0, 45.0], [-20.0, 60.0], [-15.0, 15.0], [0.0, 70.0], [0.0, 80.0]], "palm", &mut parts);

    // The fingertips, from the placed tip links.
    let mut tips = Vec::new();
    for p in &parts {
        if let Some(l) = &p.tip {
            let q = p.pose.point(l.tip_point());
            let grip = p.pose.vector([0.0, 0.0, if l.name.starts_with("thumb") { 12.0 } else { GRIP }]);
            let side = p.pose.vector([0.0, SIDE, 0.0]);
            tips.push((q, grip, side));
        }
    }
    let hand = Hand { knuckles, cmc, cmc_axis: thumb_base.vector([0.0, 0.0, 1.0]), tips };
    let o = [0.0; 3];
    parts.push(Placed { study: palm_study(&hand), pose: Pose::ID, parent: Some("wrist_cross".into()), joint: Some(("wrist/radial_ulnar".into(), o, [0.0, 0.0, 1.0], [-25.0, 25.0], None)), tip: None, dof: Some("wrist/radial_ulnar".into()), rest: 0.0 });
    parts.push(Placed { study: ulnar_study(&hand), pose: Pose::ID, parent: Some("palm".into()), joint: Some(("palm/arch_CMC45".into(), [ARCH_MID, ARCH_Y, 0.0], [1.0, 0.0, 0.0], ARCH_LIM, Some(B623))), tip: None, dof: Some("palm/arch_CMC45".into()), rest: 0.0 });
    parts.push(Placed { study: cross_study(&hand), pose: Pose::ID, parent: Some("forearm_frame".into()), joint: Some(("wrist/flex_ext".into(), o, [0.0, 1.0, 0.0], [-40.0, 40.0], None)), tip: None, dof: Some("wrist/flex_ext".into()), rest: 0.0 });
    parts.push(Placed { study: forearm_study(&hand), pose: Pose::ID, parent: None, joint: None, tip: None, dof: None, rest: 0.0 });

    // Room for the links that turn next to the palms over their joints' whole range: the thumb's
    // saddle and metacarpal at the main palm, every proximal link at the palm that carries it.
    let sweeps: [(&str, &[&str], &str); 8] = [
        ("thumb_cmc_saddle", &["thumb_metacarpal"], "palm"),
        ("thumb_metacarpal", &["thumb_metacarpal"], "palm"),
        ("index_proximal", &["index_proximal"], "palm"),
        ("middle_proximal", &["middle_proximal"], "palm"),
        ("ring_proximal", &["ring_proximal"], "palm_ulnar"),
        ("little_proximal", &["little_proximal"], "palm_ulnar"),
        ("ring_knuckle", &["ring_proximal"], "palm_ulnar"),
        ("little_knuckle", &["little_proximal"], "palm_ulnar"),
    ];
    for (joint_of, moved, into) in sweeps {
        let regions = swept(&parts, joint_of, moved);
        if let Some(p) = parts.iter_mut().find(|p| p.study.name == into) {
            p.study.keep_out.extend(regions);
        }
    }
    // The thumb's CMC saddle turning in the palm's clevis: in its own frame it keeps out of the
    // lugs' slabs (|z| past the tongue) up to 7.5 mm from the axis and within 9 mm of it
    // sideways there, so near the joint it stays in the slot; past 7.5 mm its whole section
    // sweeps the palm over CMC abduction (voxel boxes, 2 deg apart).
    let t = B623.tongue() + 0.4;
    let saddle = parts.iter().position(|p| p.study.name == "thumb_cmc_saddle").unwrap();
    {
        let st = &mut parts[saddle].study;
        for (y0, y1, z0, z1) in [(-11.0, 11.0, t, 11.0), (-11.0, 11.0, -11.0, -t), (9.0, 11.0, -6.0, 6.0), (-11.0, -9.0, -6.0, 6.0)] {
            st.keep_out.push(bx([-10.0, y0, z0], [7.5, y1, z1]));
        }
    }
    let (sp, sst) = (parts[saddle].pose, parts[saddle].study.clone());
    let Some((_, sc, sa, slim, _)) = parts[saddle].joint.clone() else { unreachable!() };
    let srest = parts[saddle].rest.to_degrees();
    let body = [[7.5, sst.min[1], sst.min[2]], [sst.max[0], sst.max[1], sst.max[2]]];
    let poses: Vec<Pose> = samples([slim[0] - srest, slim[1] - srest], 2.0).into_iter().map(|d| turn(sc, sa, d).then(&sp)).collect();
    if let Some(p) = parts.iter_mut().find(|p| p.study.name == "palm") {
        let regions = swept_out(&p.study, &[body], &poses, 0.5);
        p.study.keep_out.extend(regions);
    }
    // The bearings the hand is built round are the sourced ones.
    let list = components("hand");
    for b in [B693, B623, B688] {
        let c = bought(&list, b.reference);
        let tag = format!("{}x{}x{}", b.bore, b.od, b.width);
        assert!(c.description.contains(&tag) && c.dims.first() == Some(&b.od), "{}: the hand uses {tag}, the component file says {} {:?}", b.reference, c.description, c.dims);
    }
    // `--check`: the keep-ins keep-outs swallow, per study, and stop (nothing is grown).
    if std::env::args().any(|a| a == "--check") {
        for p in &parts {
            let st = &p.study;
            let g = solid::Grid::new(st.min, st.max, st.voxel);
            let mut out = vec![false; g.elements()];
            let mut by = vec![usize::MAX; g.elements()];
            for (k, r) in st.keep_out.iter().enumerate() {
                for e in g.elements_touching(r) {
                    out[e] = true;
                    by[e] = k;
                }
            }
            for (k, r) in st.keep_in.iter().enumerate() {
                let es = g.elements_in(r);
                let lost = es.iter().filter(|&&e| out[e]).count();
                if !es.is_empty() && lost * 2 > es.len() {
                    let mut who: Vec<usize> = es.iter().filter(|&&e| out[e]).map(|&e| by[e]).collect();
                    who.sort();
                    who.dedup();
                    eprintln!("{}: keep-in {k} {:?} {lost} of {} voxels kept out by {:?}", st.name, r, es.len(), who.iter().map(|&i| (i, st.keep_out[i])).collect::<Vec<_>>());
                }
            }
            eprintln!("{}: {} voxels, {} keep-outs", st.name, g.elements(), st.keep_out.len());
        }
        return;
    }
    // Links that met their stress limit but not the 0.25 mm deflection one in 30
    // iterations once the tendon loads came down to the cap: more iterations.
    for p in parts.iter_mut() {
        if p.study.name == "middle_middle" {
            p.study.iterations = 50;
        }
        // Two where the least-mass run did not settle (one run feasible, the next at 3 mm of
        // deflection): grown stiffest for a fifth of their box instead, the limits checked on
        // what that builds.
        if ["index_middle", "thumb_proximal"].contains(&p.study.name.as_str()) {
            p.study.objective = Objective::Compliance;
            p.study.volume_fraction = 0.2;
            p.study.iterations = 50;
        }
    }
    // Grow every part.
    let mut results: Vec<(String, PartResult)> = Vec::new();
    for p in &parts {
        if !wanted(&p.study.name) {
            continue;
        }
        let r = run_part(&dir, &p.study);
        // Where the surface is most stressed (worst case), to find what a part over its limit
        // needs.
        if let Some((i, v)) = r.mesh.stress.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)) {
            let q = &r.mesh.positions[3 * i..3 * i + 3];
            eprintln!("  {}: peak surface stress {v:.0} MPa at [{:.1}, {:.1}, {:.1}]", p.study.name, q[0], q[1], q[2]);
        }
        results.push((p.study.name.clone(), r));
    }
    write_outputs(&dir, &parts, &results);
}

/// Cylinders round the links `moved` (by name) at seven angles across the limits of the joint
/// `joint_of` turns about: each link's body from 9.5 mm past its own joint (clear of the lugs it
/// turns in) to its far end, its larger half section plus 0.8 mm.
fn swept(parts: &[Placed], joint_of: &str, moved: &[&str]) -> Vec<Region> {
    let Some(j) = parts.iter().find(|p| p.study.name == joint_of) else { return Vec::new() };
    let Some((_, c, a, lim, _)) = &j.joint else { return Vec::new() };
    let mut out = Vec::new();
    for k in 0..7 {
        let angle = deg(lim[0] + (lim[1] - lim[0]) * k as f64 / 6.0) - j.rest;
        let turn = Pose::trans(*c).then(&Pose::rot(*a, angle)).then(&Pose::trans(scale(*c, -1.0)));
        for name in moved {
            let Some(p) = parts.iter().find(|p| p.study.name == *name) else { continue };
            let pose = turn.then(&p.pose);
            let st = &p.study;
            let r = st.min[1].abs().max(st.max[1]).max(st.min[2].abs()).max(st.max[2]) + 0.8;
            let (x0, x1) = (9.5, st.max[0]);
            if x1 > x0 {
                out.push(Region::Cylinder { base: pose.point([x0, 0.0, 0.0]), axis: pose.vector([1.0, 0.0, 0.0]), radius: r, length: x1 - x0 });
            }
        }
    }
    out
}

/// Rows of the earlier runs (a partial `--only` run keeps them).
fn previous(dir: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(dir.join("hand.json")).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()).and_then(|v| v["parts"].as_array().cloned()).unwrap_or_default()
}

fn write_outputs(dir: &std::path::Path, parts: &[Placed], results: &[(String, PartResult)]) {
    // Each load case's peak stress beside the part's figures, so a part over its limit says
    // which case does it.
    let mut rows: Vec<Value> = results
        .iter()
        .map(|(n, r)| {
            let names: Vec<String> = parts.iter().find(|p| &p.study.name == n).map(|p| p.study.cases.iter().map(|c| c.name.clone()).collect()).unwrap_or_default();
            let cases: serde_json::Map<String, Value> = names.into_iter().zip(r.analysis.max_stress.iter()).map(|(c, v)| (c, json!(v))).collect();
            result_json(r, json!({"case_max_stress_mpa": cases}))
        })
        .collect();
    for old in previous(dir) {
        if old["name"].as_str().is_some_and(|n| !results.iter().any(|(m, _)| m == n)) {
            rows.push(old);
        }
    }
    let row = |name: &str| rows.iter().find(|r| r["name"] == name).cloned();
    let list = components("hand");
    let mut asm = AssemblyFile::default();
    let mut structure = solid::Mesh::default();
    let mut picture = solid::Mesh::default();
    let material = alsi10mg().name;
    // Grown parts and their joints.
    for p in parts {
        let name = &p.study.name;
        let Some(r) = row(name) else { continue };
        let file = format!("parts/{name}.3mf");
        if let Ok(m) = std::fs::read(dir.join(format!("parts/{name}.stl"))) {
            if let Some(mesh) = read_stl(&m) {
                mesh_append(&mut structure, &mesh_transformed(&mesh, &p.pose));
            }
        }
        // limits_deg from the pose the part is written in (the app's slider 0), the anatomical
        // ones (from the straight finger) beside them.
        let joint = p.joint.as_ref().map(|(jn, origin, axis, lim, _)| {
            let r = p.rest.to_degrees();
            json!({"name": jn, "type": "revolute", "origin": origin, "axis": axis, "limits_deg": [lim[0] - r, lim[1] - r], "rest_deg": r, "limits_from_straight_deg": lim})
        });
        asm.made(name, &file, &p.pose, &material, "laser powder bed fusion, build +z", r["mass_g"].as_f64().unwrap_or(0.0), match (&p.parent, joint) {
            (Some(par), Some(j)) => Some((par.as_str(), j)),
            _ => None,
        });
    }
    // Bearings in each child's tongue, the pin pressed into the parent.
    let pin_mesh = |d: f64, l: f64| cylinder_mesh([0.0, 0.0, -l / 2.0], [0.0, 0.0, l / 2.0], d / 2.0, 16);
    let mut pins = 0;
    for p in parts {
        let (Some((jn, c, a, _, brg)), Some(parent)) = (&p.joint, &p.parent) else { continue };
        let name = &p.study.name;
        let b = match brg {
            Some(b) => *b,
            None => continue,
        };
        for (k, sign) in [(1, -1.0), (2, 1.0)] {
            let at = add(*c, scale(*a, if sign < 0.0 { -b.width } else { 0.0 }));
            let bb = bought(&list, b.reference);
            let mesh = ring_mesh(b.bore / 2.0, b.od / 2.0, b.width, 24);
            let pose = frame_z(*a, at);
            mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
            asm.bought(dir, bb, &format!("{jn} bearing {k}"), b.reference, &mesh, &pose, Some(name.as_str()), "bearing in the child's tongue");
        }
        pins += 1;
        let sh = bought(&list, "SH1");
        let mesh = pin_mesh(3.0, 16.0);
        // The arch pin is held by one lug on the palm (ARCH_LUG on): its 16 mm run from the lug
        // through the ulnar palm's tongue, not centred on the tongue.
        let centre = if jn == "palm/arch_CMC45" { [ARCH_PIN, ARCH_Y, 0.0] } else { *c };
        let pose = frame_z(*a, centre);
        mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
        asm.bought(dir, sh, &format!("{jn} pin"), "SH1", &mesh, &pose, Some(parent.as_str()), "3 x 16 pin pressed into the parent's lugs");
    }
    // Wrist: 688ZZ pairs (cross +y round the forearm pin, palm -z round the cross pin), the pins.

    let b3 = bought(&list, "B3");
    let sh2 = bought(&list, "SH2");
    for (holder, axis, from, pin_holder, pin_at) in [("wrist_cross", [0.0, 1.0, 0.0], 10.0, "forearm_frame", 16.4), ("palm", [0.0, 0.0, -1.0], 4.6, "wrist_cross", 11.0)] {
        for k in 0..2 {
            let at = scale(axis, from + 5.0 * k as f64);
            let mesh = ring_mesh(4.0, 8.0, 5.0, 24);
            let pose = frame_z(axis, at);
            mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
            asm.bought(dir, b3, &format!("{holder} 688ZZ {}", k + 1), "B3", &mesh, &pose, Some(holder), "688ZZ on the wrist idler");
        }
        let mesh = pin_mesh(8.0, 20.0);
        let pose = frame_z(axis, scale(axis, pin_at));
        mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
        asm.bought(dir, sh2, &format!("{pin_holder} 8 mm pin"), "SH2", &mesh, &pose, Some(pin_holder), "8 x 20 pin pressed into the lug");
    }
    // The servos, spools and boards.
    let m1 = bought(&list, "M1");
    let dofs: Vec<String> = parts.iter().filter_map(|p| p.dof.clone()).filter(|d| !d.starts_with("wrist")).collect();
    for (k, (slot, c, sz)) in bank().into_iter().enumerate() {
        let b = servo_box(c, sz);
        let mesh = box_mesh(scale(sub(b[1], b[0]), -0.5), scale(sub(b[1], b[0]), 0.5));
        let pose = Pose::trans(scale(add(b[0], b[1]), 0.5));
        mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
        let dof = dofs.get(k).cloned().unwrap_or_default();
        asm.bought(dir, m1, &format!("XC330 {dof} ({slot})"), "M1", &mesh, &pose, Some("forearm_frame"), &format!("drives {dof} through its spool and tendon pair, four M2 into the pad"));
        let sp = spool_at(c, sz);
        let mut spool = cylinder_mesh([0.0, 0.0, 0.0], [0.0, 0.0, 1.0], SPOOL_R + 2.5, 24);
        mesh_append(&mut spool, &cylinder_mesh([0.0, 0.0, 1.0], [0.0, 0.0, 7.0], SPOOL_R, 24));
        mesh_append(&mut spool, &cylinder_mesh([0.0, 0.0, 7.0], [0.0, 0.0, 8.0], SPOOL_R + 2.5, 24));
        let pose = Pose { r: if sz > 0.0 { Pose::ID.r } else { Pose::rot([1.0, 0.0, 0.0], std::f64::consts::PI).r }, t: sp };
        mesh_append(&mut picture, &mesh_transformed(&spool, &pose));
        // AlSi10Mg spool: two 8.5 mm flanges and a 6 mm drum, about 1.2 g.
        asm.simple(dir, &format!("spool {dof}"), "spool", &spool, &pose, &material, "turned or printed, four M2 to the horn", 1.2, "forearm_frame");
    }
    let m2 = bought(&list, "M2");
    for (name, b, holder, dof) in [("XM430 wrist flexion", xm_flex(), "forearm_frame", "wrist/flex_ext"), ("XM430 wrist deviation", xm_dev(), "wrist_cross", "wrist/radial_ulnar")] {
        let mesh = box_mesh(scale(sub(b[1], b[0]), -0.5), scale(sub(b[1], b[0]), 0.5));
        let pose = Pose::trans(scale(add(b[0], b[1]), 0.5));
        mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
        asm.bought(dir, m2, name, "M2", &mesh, &pose, Some(holder), &format!("drives {dof} directly, four M2.5 to the case plate, four to the horn"));
    }
    for (reference, name, b) in boards() {
        let bb = bought(&list, reference);
        let mesh = box_mesh(scale(sub(b[1], b[0]), -0.5), scale(sub(b[1], b[0]), 0.5));
        let pose = Pose::trans(scale(add(b[0], b[1]), 0.5));
        mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
        asm.bought(dir, bb, name, reference, &mesh, &pose, Some("forearm_frame"), "on its pad beside the servo bank");
    }
    // Fingertip FSRs on the pads.
    let s1 = bought(&list, "S1");
    for p in parts {
        let Some(l) = &p.tip else { continue };
        let (c, r) = l.pad();
        let at = p.pose.point([c[0], 0.0, c[2] - r]);
        let mesh = cylinder_mesh([0.0; 3], [0.0, 0.0, 0.4], 3.8, 24);
        let pose = frame_z(p.pose.vector([0.0, 0.0, -1.0]), at);
        mesh_append(&mut picture, &mesh_transformed(&mesh, &pose));
        asm.bought(dir, s1, &format!("FSR {}", l.name.trim_end_matches("_distal")), "S1", &mesh, &pose, Some(l.name.as_str()), "on the fingertip pad");
    }
    // The 12 V supply sits off the hand (robot base), grounded on its own.
    let p1 = bought(&list, "P1");
    let mesh = box_mesh([-107.5, -57.5, -15.0], [107.5, 57.5, 15.0]);
    asm.bought(dir, p1, "12 V supply", "P1", &mesh, &Pose::trans([-400.0, 0.0, -80.0]), None, "off the hand, in the robot base");
    // Lines with no placed geometry.
    for (reference, qty, use_) in [
        ("C1", 3, "bus cables: bus A, bus B, hub links"),
        ("P2", 1, "mains cord to the supply"),
        ("P3", 2, "12 V distribution lever connectors, one per polarity"),
        ("P4", 2, "12 V rail, red and black"),
        ("R1", 5, "FSR dividers on the OpenRB-150"),
        ("W1", 2, "FSR leads"),
        ("T1", 1, "tendon line: 44 tendons, flexor and extensor per DOF"),
        ("T2", 1, "PTFE sheaths: forearm stop bar to the palm's stops"),
        ("F1", 240, "M2 x 6: 88 servo pads (4 holes each), 88 spools to horns, the rest spare"),
        ("F2", 16, "M2.5 x 6: 2 XM430 x (4 case plate holes + 4 horn holes)"),
        ("F3", 60, "M3 x 8: 4 forearm flange holes, the rest to the arm and spare"),
        ("I1", 60, "M2 inserts (fingers, thumb, palm) as needed"),
        ("I2", 60, "M3 inserts on the arm side of the flange"),
        ("C2", 4, "EH housings: OpenRB-150 and hub bus links"),
        ("C3", 10, "EH crimp contacts for the housings, spares included"),
        ("PF1", 3, "10 A fuses, one per hub branch and a spare"),
        ("PF2", 2, "3 A fuses, OpenRB-150 branch and a spare"),
        ("PF3", 3, "in-line fuse holders, one per branch"),
        ("SW1", 1, "mains rocker switch, off the hand at the supply"),
        ("ES1", 1, "emergency stop station, off the hand at the operator"),
        ("T3", 2, "sheath end caps (bottles of 50): every sheath end at the stop bar and the palm stops"),
    ] {
        asm.loose(bought(&list, reference), qty, use_);
    }
    std::fs::write(dir.join("hand_structure.stl"), solid::export::stl(&structure, "HandStructure")).unwrap();
    std::fs::write(dir.join("hand_structure.3mf"), solid::export::three_mf(&structure, "HandStructure")).unwrap();
    std::fs::write(dir.join("hand_components.stl"), solid::export::stl(&picture, "HandComponents")).unwrap();
    let total: f64 = rows.iter().filter_map(|r| r["mass_g"].as_f64()).sum();
    let worst_sf = rows.iter().filter_map(|r| r["safety_factor"].as_f64()).fold(f64::INFINITY, f64::min);
    let joints: Vec<Value> = asm.joints.iter().filter(|j| j["type"] == "revolute").cloned().collect();
    let summary = json!({
        "product": "humanoid robotic hand, 1.15 x human, tendon driven (docs/components/hand.json)",
        "dof": joints.len(),
        "joints": joints,
        "parts": rows,
        "pin_joints": pins,
        "structure_mass_g": total,
        "lowest_safety_factor": worst_sf,
        "all_feasible": rows.iter().all(|r| r["feasible"].as_bool() == Some(true)),
        "material": "AlSi10Mg, laser powder bed, build +z, overhang 45 deg",
        "loads": {"tendon_active_n": T_ACTIVE, "tendon_pair_n": T_PAIR, "tendon_stall_n": T_STALL, "tendon_pretension_n": T_PRE, "fingertip_grip_n": GRIP, "side_push_n": SIDE, "drop_g": DROP_G, "wrist_servo_stall_nmm": XM_STALL_NMM, "link_max_displacement_mm": LINK_MAX_DISP},
        "tendon": {
            "component_ref": "T1",
            "break_terminated_n": [T1_BREAK_TERMINATED_N, 311.0],
            "uncapped_stall_plus_pretension_n": T_STALL + T_PRE,
            "uncapped_safety_factor": T1_BREAK_TERMINATED_N / (T_STALL + T_PRE),
            "pull_cap_n": TENDON_CAP_N,
            "capped_safety_factor": T1_BREAK_TERMINATED_N / TENDON_CAP_N,
            "spool_torque_cap_nmm": SPOOL_CAP_NMM,
            "spool_torque_cap_share_of_stall": SPOOL_CAP_NMM / (T_STALL * SPOOL_R),
            "xc330_current_limit_a": XC_CAP_A,
            "current_limit_register": "XC330-T288-T Current Limit, address 38: value and unit UNCONFIRMED, set on a load cell",
            "how": "XC330-T288-T Current Limit (address 38) set so the spool pulls no more than pull_cap_n on the pulled tendon with its pretension (spool torque spool_torque_cap_nmm, about xc330_current_limit_a by linear interpolation of the notes' torque and current points), calibrated on a load cell before first use (current per newton UNCONFIRMED); every tendon load case of the structure uses this cap",
        },
        "files": {"assembly": "assembly.json", "structure_stl": "hand_structure.stl", "structure_3mf": "hand_structure.3mf", "components_stl": "hand_components.stl"},
    });
    std::fs::write(dir.join("hand.json"), serde_json::to_string_pretty(&summary).unwrap()).unwrap();
    asm.write(dir, "hand", &list, json!({"base": "forearm_frame", "dof": joints.len()}));
    eprintln!("hand: {} parts in hand.json, structure {:.1} g, lowest safety factor {:.2}, {} revolute joints", rows.len(), total, worst_sf, joints.len());
}

/// Reads a binary STL back (the parts written by `run_part`).
fn read_stl(bytes: &[u8]) -> Option<solid::Mesh> {
    if bytes.len() < 84 {
        return None;
    }
    let n = u32::from_le_bytes(bytes[80..84].try_into().ok()?) as usize;
    if bytes.len() < 84 + 50 * n {
        return None;
    }
    let mut m = solid::Mesh::default();
    for t in 0..n {
        let b = 84 + 50 * t + 12;
        for v in 0..3 {
            for c in 0..3 {
                let o = b + 12 * v + 4 * c;
                m.positions.push(f32::from_le_bytes(bytes[o..o + 4].try_into().ok()?));
            }
            m.indices.push((3 * t + v) as u32);
        }
    }
    Some(m)
}
