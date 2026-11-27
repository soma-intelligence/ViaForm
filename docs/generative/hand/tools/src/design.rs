//! The hand's layout and its studies: every structural part as a 3D generative study around the
//! real components of docs/components/hand.json (see ../SPEC.md). Ported from
//! generative/examples/hand.rs (not owned here), with the 2026-11-05 component revision:
//! 693ZZ 3x8x4 on finger and thumb axes (was B693ZZ 3x6x2.5), 4 mm compressionless housings
//! with 6 mm alloy end caps (was 2 mm PTFE), joint clearances for a closed fist, fingertip
//! strike impacts, and the forearm covers.

use crate::common::*;
use viaform_generative::solid::{self, Impact, Load, LoadCase, Manufacturing, Objective, Region, Study, Support};

/// Servo stall torque at 12 V on the 6 mm spool, and the tendons' pretension.
const T_STALL: f64 = 1000.0 / 6.0;
const T_PRE: f64 = 20.0;
const GRIP: f64 = 10.0;
const SIDE: f64 = 10.0;
/// A blow on the fingertip pad (N), as a 1 ms half-sine.
const STRIKE: f64 = 30.0;
/// Radius round a pin inside which a child link keeps only its tongue (its sides start beyond),
/// so the parent's lugs and side walls clear it through the whole flexion range.
const JOINT_CLEAR: f64 = 7.0;

#[derive(Clone, Copy, Debug)]
pub struct Brg {
    pub reference: &'static str,
    pub bore: f64,
    pub od: f64,
    pub width: f64,
}

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

/// One link of a finger or the thumb, in its own frame: x along it, its proximal joint at the
/// origin about `prox`, its distal joint at (len, 0, 0) about `dist`.
#[derive(Clone, Debug)]
pub struct Phalanx {
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
        let parent_lug = (b.lug() + 0.8).max(JOINT_CLEAR);
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
            let (lo, hi) = (cd[0] - swing.max(9.5), xmax + 1.0);
            keep_out.push(match ad {
                Ax::Y => bx([lo, -gap, -h2 - 1.0], [hi, gap, h2 + 1.0]),
                Ax::Z => bx([lo, -w2 - 1.0, -gap], [hi, w2 + 1.0, gap]),
            });
            // A flexion joint: the palmar corner behind the pin goes, so the next link folds
            // under it (the lugs, inside radius `lug`, stay).
            if ad == Ax::Y {
                keep_out.push(bx([cd[0] - 9.5, -w2 - 1.0, -h2 - 1.0], [hi, w2 + 1.0, -(n.lug() + 0.4)]));
            }
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
        for (name, flexor) in [("flexor stall", true), ("extensor stall", false)] {
            let mut loads = Vec::new();
            let mut m = 0.0;
            for (side, tension) in [(flexor, T_STALL), (!flexor, T_PRE)] {
                let (region, p) = self.anchor(side);
                let f = [-tension, 0.0, 0.0];
                loads.push(Load::Force { region, force: f });
                m += dot(cross(p, f), ap);
            }
            match pad {
                Some(p) => loads.push(Load::Force { region: p, force: hold(m, tip) }),
                None => {
                    // The next link held still: its push back, and the downstream tendons'
                    // pull through the pin.
                    let f = add(hold(m, cd), [-(T_STALL + T_PRE) * self.down as f64, 0.0, 0.0]);
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
        let mut impacts = Vec::new();
        if let Some(p) = pad {
            // A fingertip strike from the palmar side and the front, tendons at pretension.
            let mut loads = Vec::new();
            for side in [true, false] {
                let (region, _) = self.anchor(side);
                loads.push(Load::Force { region, force: [-T_PRE, 0.0, 0.0] });
            }
            loads.push(Load::Force { region: p, force: scale(unit([-0.6, 0.0, 0.8]), STRIKE) });
            impacts.push(Impact { case: cases.len(), duration: 1.0e-3, window: 3.0e-3, steps: 120, damping: 0.02 });
            cases.push(LoadCase { name: "tip strike 30 N".into(), loads, acceleration: None, weight: 0.5 });
        }
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
            min_member: 1.2,
            manufacturing: Manufacturing::Additive { build: [0.0, 0.0, 1.0], overhang: 45.0 },
            iterations: 30,
            smoothing: 10,
            dynamics: solid::Dynamics { modes: 3, impacts },
            ..Study::default()
        }
    }
}

/// A joint between a part and its parent: origin and axis in the parent's frame (as built,
/// every joint at 0), limits (deg), the bearings in the child, the motor that drives it.
#[derive(Clone, Debug)]
pub struct JointDef {
    pub dof: String,
    pub origin: V3,
    pub axis: V3,
    pub limits: [f64; 2],
    pub brg: Option<Brg>,
}

/// A part placed in the hand: its frame relative to its parent's at joint zero (the world pose
/// for the base).
#[derive(Clone, Debug)]
pub struct Placed {
    pub id: String,
    pub study: Study,
    pub rel: Pose,
    pub parent: Option<String>,
    pub joint: Option<JointDef>,
    pub tip: Option<Phalanx>,
    pub process: &'static str,
}

const LPBF: &str = "laser powder bed fusion (AlSi10Mg), build +z, 45 deg overhang, stress relieved, bores reamed";
const SLS: &str = "selective laser sintering (PA12), 45 deg overhang";

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
        link(1, "proximal", "MCP_flex", f.prox, f.w[0], f.h[0], Ax::Y, Some(Ax::Y), 2, 0.65),
        link(2, "middle", "PIP", f.mid, f.w[1], f.h[1], Ax::Y, Some(Ax::Y), 1, 0.55),
        link(3, "distal", "DIP", f.dist, f.w[2], f.h[2], Ax::Y, None, 0, 0.5),
    ]
}

fn deg(d: f64) -> f64 {
    d.to_radians()
}

/// Places a chain from `base` (the first link's proximal joint frame in the parent's frame), every
/// joint at zero.
fn place_chain(links: Vec<Phalanx>, base: Pose, limits: &[[f64; 2]], parent: &str, out: &mut Vec<Placed>) {
    let mut rel = base;
    let mut parent = parent.to_string();
    for (k, l) in links.into_iter().enumerate() {
        let joint = Some(JointDef { dof: l.dof.clone(), origin: rel.t, axis: rel.vector(l.prox.v()), limits: limits[k], brg: Some(l.brg) });
        let name = l.name.clone();
        out.push(Placed { id: name.clone(), study: l.study(), rel, parent: Some(parent.clone()), joint, tip: l.tip.then(|| l.clone()), process: LPBF });
        rel = Pose::trans([l.len, 0.0, 0.0]);
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
        volume_fraction: 0.4,
        safety_factor: 2.0,
        min_member: 1.8,
        manufacturing: Manufacturing::Additive { build: [0.0, 0.0, 1.0], overhang: 45.0 },
        iterations: 25,
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

/// GC4FA end cap: 6 mm across, 8 mm long, on a 4 mm LEX-SL housing.
pub const CAP_D: f64 = 6.0;
pub const CAP_L: f64 = 8.0;
pub const HOUSING_D: f64 = 4.0;
const CAP_PITCH: f64 = 6.4;

/// A sheath stop: a 3 mm plate facing -x at `at`, one 1.6 mm tendon hole per housing on a
/// 6.4 mm grid, the end caps' pocket in front of it (8 mm deep), and the channel the bundle comes
/// in by, from `entry`, sized for the 4 mm housings.
fn sheath_stop(s: &mut Study, at: V3, entry: V3, sheaths: usize) -> Region {
    let d = unit(sub(at, entry));
    let cols = (sheaths as f64).sqrt().ceil() as usize;
    let rows = sheaths.div_ceil(cols);
    let (hy, hz) = (cols as f64 * CAP_PITCH / 2.0, rows as f64 * CAP_PITCH / 2.0);
    let stop = bx(sub(at, [0.0, hy + 1.5, hz + 1.5]), add(at, [3.0, hy + 1.5, hz + 1.5]));
    s.keep_in.push(stop);
    for k in 0..sheaths {
        let (c, r) = (k % cols, k / cols);
        let y = at[1] + (c as f64 - (cols as f64 - 1.0) / 2.0) * CAP_PITCH;
        let z = at[2] + (r as f64 - (rows as f64 - 1.0) / 2.0) * CAP_PITCH;
        s.keep_out.push(Region::Cylinder { base: [at[0] - 1.0, y, z], axis: [1.0, 0.0, 0.0], radius: 0.8, length: 5.0 });
    }
    s.keep_out.push(bx(sub(at, [CAP_L + 0.5, hy, hz]), add(at, [0.0, hy, hz])));
    let r = HOUSING_D / 2.0 * (sheaths as f64 * 1.15).sqrt() + 0.5;
    let len = norm(sub(at, entry)) - CAP_L - 0.5;
    if len > 0.0 {
        s.keep_out.push(Region::Cylinder { base: entry, axis: d, radius: r, length: len });
    }
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

pub struct Hand {
    pub knuckles: [V3; 4],
    pub cmc: V3,
    pub cmc_axis: V3,
    /// Fingertips (index, middle, ring, little, thumb): point, grip force, side force.
    pub tips: Vec<(V3, V3, V3)>,
}

const ARCH_Y: f64 = -12.0;
const ARCH_X: [f64; 2] = [30.4, 39.6];
/// Where the sheath bundle comes into the palm (palmar side, past the wrist).
const ENTRY: V3 = [14.0, 0.0, -15.5];

fn stops(h: &Hand) -> ([V3; 4], V3, V3) {
    let f = h.knuckles.map(|k| [k[0] - 16.0, k[1], -4.0]);
    (f, [8.0, 26.0, -6.0], [24.0, -4.0, -8.0])
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
    s.supports = vec![Support { region: seat, fix: [true; 3] }, Support { region: horn, fix: [true; 3] }];
    // The ulnar palm's room, its tongue's swing, the arch lug.
    s.keep_out.push(bx([ARCH_X[0] - 0.6, -19.0, -16.0], [90.0, -5.0, 16.0]));
    s.keep_out.push(cyl([0.0, ARCH_Y, 0.0], [1.0, 0.0, 0.0], ARCH_X[0] - 0.6, ARCH_X[1] + 0.6, B623.pulley() + 1.0));
    let arch = tube([0.0, ARCH_Y, 0.0], [1.0, 0.0, 0.0], 24.0, 30.0, B623.bore / 2.0, B623.lug());
    s.keep_in.push(arch);
    s.keep_out.push(cyl([0.0, ARCH_Y, 0.0], [1.0, 0.0, 0.0], 23.0, 41.0, B623.bore / 2.0));
    let mut bosses = Vec::new();
    for k in &h.knuckles[..2] {
        let b = clevis(&mut s, *k, z, B693, 12.0);
        s.keep_out.push(bx([k[0] - B693.pulley() - 1.0, k[1] - 9.5, -B693.tongue() - 0.4], [90.0, k[1] + 9.5, B693.tongue() + 0.4]));
        bosses.push(b);
    }
    let cmc = clevis(&mut s, h.cmc, h.cmc_axis, B623, 10.5);
    // Sheath stops: 8 sheaths per finger, 10 for the thumb, 2 for the arch; the ring and little
    // bundles go on through to the ulnar palm.
    let fs: Vec<Region> = fstop[..2].iter().map(|p| sheath_stop(&mut s, *p, ENTRY, 8)).collect();
    let ts = sheath_stop(&mut s, tstop, ENTRY, 10);
    let asp = sheath_stop(&mut s, astop, ENTRY, 2);
    for p in &fstop[2..] {
        let r = HOUSING_D / 2.0 * (8.0f64 * 1.15).sqrt() + 0.5;
        s.keep_out.push(Region::Cylinder { base: ENTRY, axis: unit(sub(*p, ENTRY)), radius: r, length: norm(sub(*p, ENTRY)) - CAP_L - 0.5 });
    }
    let pull = |n: f64, stall: bool| n * if stall { T_STALL + T_PRE } else { 2.0 * T_PRE };
    for (case, stall) in [("grip at stall", true), ("side push", false)] {
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
        joint_loads(&[arch], [27.0, ARCH_Y, 0.0], [1.0, 0.0, 0.0], &[tip(2), tip(3)], &[], &mut loads);
        let d = unit(sub(astop, [35.0, ARCH_Y, -8.0]));
        loads.push(Load::Force { region: arch, force: scale(d, -pull(1.0, stall)) });
        loads.push(Load::Force { region: asp, force: scale(unit(sub(astop, ENTRY)), pull(1.0, stall)) });
        s.cases.push(LoadCase { name: case.into(), loads, acceleration: None, weight: 1.0 });
    }
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: Vec::new(), acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
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
    // The flexion XM430 when the hand bends.
    s.keep_out.push(bx([ARCH_X[0] - 1.0, -50.0, 10.0], [36.0, -14.5, 16.0]));
    s.keep_out.push(bx([ARCH_X[0] - 1.0, -50.0, -16.0], [36.0, -14.5, -10.0]));
    // The arch tendon on the drum's palmar side, pulled toward its stop on the main palm.
    let anchor = bx([33.5, ARCH_Y - 1.5, -B623.pulley() - 0.3], [36.5, ARCH_Y + 1.5, -B623.pulley() + 1.5]);
    let ad = unit(sub(astop, [35.0, ARCH_Y, -8.0]));
    let pull = |n: f64, stall: bool| n * if stall { T_STALL + T_PRE } else { 2.0 * T_PRE };
    for (case, stall) in [("grip at stall", true), ("side push", false)] {
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

/// The flexion servo in the forearm: shaft along +y, horn face at y = -15, its body below.
fn xm_flex() -> [V3; 2] {
    [[-XM_W / 2.0, -15.0 - XM_D, -(XM_H - XM_SHAFT)], [XM_W / 2.0, -15.0, XM_SHAFT]]
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
const BAR_X: [f64; 2] = [-90.0, -84.0];
/// The forearm flange to the arm (x), thick enough for the covers' M3 inserts.
const FLANGE_X: [f64; 2] = [-241.0, -235.2];
/// Cover screws: M3 into I2 inserts on the bar and the flange tops (and bottoms), y = +-20.
pub const COVER_SCREWS: [[f64; 2]; 4] = [[-87.0, -20.0], [-87.0, 20.0], [-238.1, -20.0], [-238.1, 20.0]];
/// The sheath bundle's tunnel under the wrist: 44 housings, 4 mm, packed (radius 15).
pub const TUNNEL: (V3, f64) = ([0.0, 0.0, -38.0], 15.0);

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
    let mut s = base_study("forearm_frame", [-241.0, -52.0, -29.0], [10.0, 34.0, 29.0], 1.25);
    s.min_member = 2.5;
    let mut pads = Vec::new();
    for (_, c, sz) in bank() {
        let b = servo_box(c, sz);
        s.keep_out.push(bx(sub(b[0], [0.3; 3]), add(b[1], [0.3; 3])));
        let sp = spool_at(c, sz);
        s.keep_out.push(cyl(sp, z, if sz > 0.0 { 0.0 } else { -12.0 }, if sz > 0.0 { 12.0 } else { 0.0 }, SPOOL_R + 3.5));
        // The pad under the case (opposite the horn) and its four M2 screws.
        let pz = if sz > 0.0 { [c[2] - 1.5, c[2] - 0.3] } else { [c[2] + 0.3, c[2] + 1.5] };
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
    let back = bx([-12.0, m[0][1] - 2.0, m[0][2] + 2.5], [12.0, m[0][1] - 0.5, m[1][2] - 2.5]);
    s.keep_in.push(back);
    for (px, pz) in [(-8.0, -28.0), (8.0, -28.0), (-8.0, 4.0), (8.0, 4.0)] {
        s.keep_out.push(cyl([px, 0.0, pz], y, m[0][1] - 3.0, m[0][1] + 1.0, 1.35));
    }
    // The idler lug with the 8 x 20 pin pressed in.
    let lug = tube(o, y, 20.4, 26.4, B688.bore / 2.0, 9.0);
    s.keep_in.push(lug);
    s.keep_out.push(cyl(o, y, 6.0, 28.0, B688.bore / 2.0));
    // The gimbal cross and the deviation servo swinging about y; on the idler side the arm
    // stays behind the axis and within |z| < 10, so the thumb's base swings clear.
    s.keep_out.push(cyl(o, y, -14.9, 20.3, 63.0));
    s.keep_out.push(bx([-63.0, 20.3, 10.0], [11.0, 28.0, 30.0]));
    s.keep_out.push(bx([-63.0, 20.3, -30.0], [11.0, 28.0, -10.0]));
    for (_, _, b) in boards() {
        s.keep_out.push(bx(sub(b[0], [0.3; 3]), add(b[1], [0.3; 3])));
        s.keep_in.push(bx([b[0][0] + 2.0, b[1][1] + 0.3, b[0][2] + 1.0], [b[1][0] - 2.0, b[1][1] + 1.5, b[1][2] - 1.0]));
    }
    // Flange to the arm, four M3 (F3 into I2 inserts on the arm side).
    let flange = bx([FLANGE_X[0], -32.0, -29.0], [FLANGE_X[1], 22.0, 29.0]);
    // M3 inserts (I2, 4.7 mm, 5.7 deep) for the covers, top and bottom.
    for [x, y] in COVER_SCREWS {
        s.keep_out.push(cyl([x, y, 0.0], z, 22.0, 30.0, 2.35));
        s.keep_out.push(cyl([x, y, 0.0], z, -30.0, -22.0, 2.35));
    }
    // The sheath tunnel under the wrist, from the stop bar forward.
    s.keep_out.push(Region::Cylinder { base: [BAR_X[1], TUNNEL.0[1], TUNNEL.0[2]], axis: [1.0, 0.0, 0.0], radius: TUNNEL.1, length: TUNNEL.0[0] + 8.0 - BAR_X[1] });
    s.keep_in.push(flange);
    for (py, pz) in [(-25.0, -20.0), (-25.0, 20.0), (15.0, -20.0), (15.0, 20.0)] {
        s.keep_out.push(Region::Cylinder { base: [-242.0, py, pz], axis: [1.0, 0.0, 0.0], radius: 1.6, length: 5.0 });
    }
    s.supports = vec![Support { region: flange, fix: [true; 3] }];
    // Every flexor at stall and its extensor at pretension: the servos pulled toward the bar,
    // the bar pushed back by the sheaths.
    let mut loads = Vec::new();
    let t = T_STALL + T_PRE;
    for (pad, pc, sp) in &pads {
        let d = unit(sub([BAR_X[0], sp[1], sp[2]], *sp));
        let f = scale(d, t);
        loads.push(Load::Force { region: *pad, force: f });
        let mo = cross(sub(*sp, *pc), f);
        loads.push(Load::Torque { region: *pad, center: *pc, axis: unit(mo), moment: norm(mo) });
    }
    loads.push(Load::Force { region: bar, force: [-t * pads.len() as f64, 0.0, 0.0] });
    s.cases.push(LoadCase { name: "tendons at stall".into(), loads, acceleration: None, weight: 1.0 });
    for (case, grip) in [("grip at the wrist", true), ("side push", false)] {
        let mut loads = Vec::new();
        let tips: Vec<(V3, V3)> = h.tips.iter().map(|t| (t.0, if grip { t.1 } else { t.2 })).collect();
        joint_loads(&[lug, back], o, y, &tips, &[back], &mut loads);
        s.cases.push(LoadCase { name: case.into(), loads, acceleration: None, weight: 1.0 });
    }
    let g = DROP_G * 9.81e-3;
    let mut drop: Vec<Load> = pads.iter().map(|(p, _, _)| Load::Force { region: *p, force: [0.0, 0.0, -23.0 * g] }).collect();
    drop.push(Load::Force { region: back, force: [0.0, 0.0, -82.0 * g] });
    drop.push(Load::Force { region: lug, force: [0.0, 0.0, -0.5 * (HAND_G + 82.0 + 60.0) * g] });
    drop.push(Load::Force { region: back, force: [0.0, 0.0, -0.5 * (HAND_G + 82.0 + 60.0) * g] });
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: drop, acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
    s
}

/// The forearm covers (PA12, top and bottom: one part, the bottom turned 180 deg about x):
/// a 2 mm skin with ribs grown behind it, kept clear of the spools, tendons, cables and boards,
/// held by four M3 tabs on the stop bar and the flange.
fn cover_study() -> Study {
    let z = [0.0, 0.0, 1.0];
    let mut s = base_study("forearm_cover", [-243.0, -56.0, 29.5], [-58.0, 56.0, 46.5], 1.0);
    s.material = pa12();
    s.min_member = 2.0;
    s.symmetry = [false, true, false];
    s.max_displacement = Some(1.2);
    // Inside: spools (to z 41), tendons, cables and the U2D2 stay clear by 1.5 mm; over the stop
    // bar and the flange the inside keeps out round the four screw tabs.
    s.keep_out.push(bx([FLANGE_X[1], -52.0, 29.0], [BAR_X[0], 52.0, 42.5]));
    s.keep_out.push(bx([BAR_X[1], -52.0, 29.0], [-62.0, 52.0, 42.5]));
    for (a, b) in [(-239.0, FLANGE_X[1]), (BAR_X[0], BAR_X[1])] {
        s.keep_out.push(bx([a, -52.0, 33.5], [b, 52.0, 42.5]));
        for (y0, y1) in [(-52.0, -25.0), (-15.0, 15.0), (25.0, 52.0)] {
            s.keep_out.push(bx([a, y0, 29.0], [b, y1, 33.5]));
        }
    }
    s.keep_in.push(bx([-243.0, -56.0, 44.6], [-58.0, 56.0, 46.5]));
    s.keep_in.push(bx([-243.0, -56.0, 29.5], [-58.0, -54.6, 46.5]));
    s.keep_in.push(bx([-243.0, 54.6, 29.5], [-58.0, 56.0, 46.5]));
    let mut tabs = Vec::new();
    for [x, y] in COVER_SCREWS {
        let (x0, x1) = if x > -150.0 { (BAR_X[0], BAR_X[1]) } else { (FLANGE_X[0], FLANGE_X[1]) };
        let tab = bx([x0, y - 5.0, 29.5], [x1, y + 5.0, 33.5]);
        s.keep_in.push(tab);
        s.keep_out.push(cyl([x, y, 0.0], z, 29.0, 47.0, 1.7));
        tabs.push(tab);
    }
    s.supports = tabs.iter().map(|t| Support { region: *t, fix: [true; 3] }).collect();
    // A fall onto an edge or a knee on the cover: 150 N on a 20 mm patch, middle and front; a
    // side blow of 100 N on the wall; the 100 g drop.
    for (name, c) in [("knock middle 150 N", [-160.0, 0.0]), ("knock front 150 N", [-110.0, 30.0])] {
        let patch = bx([c[0] - 10.0, c[1] - 10.0, 44.6], [c[0] + 10.0, c[1] + 10.0, 46.5]);
        s.cases.push(LoadCase { name: name.into(), loads: vec![Load::Force { region: patch, force: [0.0, 0.0, -150.0] }], acceleration: None, weight: 1.0 });
    }
    let wall = bx([-170.0, -56.0, 34.0], [-150.0, -54.6, 46.5]);
    s.cases.push(LoadCase { name: "side blow 100 N".into(), loads: vec![Load::Force { region: wall, force: [0.0, 100.0, 0.0] }], acceleration: None, weight: 1.0 });
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: Vec::new(), acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
    s
}

/// One tendon spool on an XC330 horn (frame: z along the shaft, horn face at z = 0, the
/// tendons leave toward +x): 6 mm drum, 8.5 mm flanges, four M2 to the horn on an 8 mm circle
/// (UNCONFIRMED against the ROBOTIS drawing), two M2 tendon clamp screws.
fn spool_study() -> Study {
    let z = [0.0, 0.0, 1.0];
    let o = [0.0; 3];
    let mut s = base_study("spool", [-9.0, -9.0, 0.0], [9.0, 9.0, 9.0], 0.36);
    s.min_member = 0.8;
    s.keep_in.push(tube(o, z, 1.2, 7.8, 4.6, SPOOL_R));
    s.keep_in.push(tube(o, z, 0.0, 1.2, 3.0, SPOOL_R + 2.5));
    s.keep_in.push(tube(o, z, 7.8, 9.0, 3.0, SPOOL_R + 2.5));
    s.keep_out.push(cyl(o, z, -1.0, 10.0, 1.6));
    let mut seat = Vec::new();
    for k in 0..4 {
        let t = k as f64 * std::f64::consts::FRAC_PI_2;
        let c = [4.0 * t.cos(), 4.0 * t.sin(), 0.0];
        s.keep_out.push(cyl(c, z, -1.0, 10.0, 1.1));
        seat.push(tube(c, z, 0.0, 1.2, 1.1, 2.4));
    }
    for t in [0.25, 1.25] {
        let a = t * std::f64::consts::PI;
        s.keep_out.push(cyl([4.0 * a.cos(), 4.0 * a.sin(), 0.0], z, -1.0, 10.0, 0.8));
    }
    s.supports = seat.iter().map(|r| Support { region: *r, fix: [true; 3] }).collect();
    let side = |y: f64| bx([-1.5, y - 0.8, 2.0], [1.5, y + 0.8, 7.0]);
    for (name, a, b) in [("flexor stall", -SPOOL_R, SPOOL_R), ("extensor stall", SPOOL_R, -SPOOL_R)] {
        let loads = vec![Load::Force { region: side(a), force: [T_STALL, 0.0, 0.0] }, Load::Force { region: side(b), force: [T_PRE, 0.0, 0.0] }];
        s.cases.push(LoadCase { name: name.into(), loads, acceleration: None, weight: 1.0 });
    }
    s.cases.push(LoadCase { name: "drop 100 g".into(), loads: Vec::new(), acceleration: Some([0.0, 0.0, -DROP_G * 9810.0]), weight: 0.5 });
    s
}

pub fn pa12() -> viaform_generative::Material {
    viaform_generative::Material { name: "PA12 (SLS)".into(), e: 1650.0, nu: 0.4, density: 1.01e-3, allowable: 48.0, color: "#3a3d42".into() }
}

/// Everything the hand is made of, placed, every joint at zero.
pub struct Design {
    pub parts: Vec<Placed>,
    pub hand: Hand,
    /// The servo bank: slot name, the case's centre on its pad, horn up (+1) or down (-1).
    pub bank: Vec<(String, V3, f64)>,
}

pub const FINGERS: [&str; 4] = ["index", "middle", "ring", "little"];

pub fn build() -> Design {
    let fingers = [
        FingerDims { name: "index", prox: 46.0, mid: 26.0, dist: 20.0, w: [18.0, 16.0, 14.0], h: [15.0, 14.0, 13.6] },
        FingerDims { name: "middle", prox: 51.0, mid: 30.0, dist: 21.0, w: [18.5, 16.5, 14.5], h: [15.5, 14.0, 13.6] },
        FingerDims { name: "ring", prox: 48.0, mid: 29.0, dist: 20.0, w: [17.5, 16.0, 14.4], h: [14.8, 14.0, 13.6] },
        FingerDims { name: "little", prox: 38.0, mid: 21.0, dist: 18.0, w: [16.0, 15.0, 14.4], h: [14.0, 13.6, 13.6] },
    ];
    // Hand frame: origin at the gimbal centre (both wrist axes), x to the fingers, y to the
    // thumb, z out of the back of the hand (a right hand, palm down).
    let knuckles = [[80.0, 18.0, 0.0], [82.0, 0.0, 0.0], [79.0, -18.0, 0.0], [72.0, -35.0, 0.0]];
    let splay = [4.0, 0.0, -4.0, -9.0];
    let mut parts: Vec<Placed> = Vec::new();
    for (i, f) in fingers.iter().enumerate() {
        let parent = if i < 2 { "palm" } else { "palm_ulnar" };
        let base = Pose::trans(knuckles[i]).then(&Pose::rot([0.0, 0.0, 1.0], deg(splay[i])));
        let abd = if i == 3 { [-20.0, 15.0] } else { [-15.0, 15.0] };
        let limits = [abd, [-10.0, 90.0], [0.0, 100.0], [0.0, 80.0]];
        place_chain(finger_links(f), base, &limits, parent, &mut parts);
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
    place_chain(thumb, thumb_base, &[[-30.0, 45.0], [-20.0, 60.0], [-15.0, 15.0], [0.0, 70.0], [-10.0, 80.0]], "palm", &mut parts);

    // The fingertips at joint zero, in the hand frame (palm, wrist and forearm load cases).
    let world = |id: &str, parts: &[Placed]| -> Pose {
        let mut chain = Vec::new();
        let mut at = Some(id.to_string());
        while let Some(n) = at {
            let p = parts.iter().find(|p| p.id == n).unwrap();
            chain.push(p.rel);
            at = p.parent.clone().filter(|q| parts.iter().any(|p| &p.id == q));
        }
        chain.iter().rev().fold(Pose::ID, |a, r| a.then(r))
    };
    let mut tips = Vec::new();
    for p in &parts {
        if let Some(l) = &p.tip {
            let w = world(&p.id, &parts);
            let q = w.point(l.tip_point());
            let grip = w.vector([0.0, 0.0, if l.name.starts_with("thumb") { 12.0 } else { GRIP }]);
            let side = w.vector([0.0, SIDE, 0.0]);
            tips.push((q, grip, side));
        }
    }
    let hand = Hand { knuckles, cmc, cmc_axis: thumb_base.vector([0.0, 0.0, 1.0]), tips };
    let o = [0.0; 3];
    let jd = |dof: &str, origin: V3, axis: V3, limits: [f64; 2], brg: Option<Brg>| Some(JointDef { dof: dof.into(), origin, axis, limits, brg });
    parts.push(Placed { id: "palm".into(), study: palm_study(&hand), rel: Pose::ID, parent: Some("wrist_cross".into()), joint: jd("wrist/radial_ulnar", o, [0.0, 0.0, 1.0], [-25.0, 25.0], None), tip: None, process: LPBF });
    parts.push(Placed { id: "palm_ulnar".into(), study: ulnar_study(&hand), rel: Pose::ID, parent: Some("palm".into()), joint: jd("palm/arch_CMC45", [ARCH_X[0], ARCH_Y, 0.0], [1.0, 0.0, 0.0], [-25.0, 5.0], Some(B623)), tip: None, process: LPBF });
    parts.push(Placed { id: "wrist_cross".into(), study: cross_study(&hand), rel: Pose::ID, parent: Some("forearm_frame".into()), joint: jd("wrist/flex_ext", o, [0.0, 1.0, 0.0], [-40.0, 40.0], None), tip: None, process: LPBF });
    parts.push(Placed { id: "forearm_frame".into(), study: forearm_study(&hand), rel: Pose::ID, parent: None, joint: None, tip: None, process: LPBF });
    let cover = cover_study();
    parts.push(Placed { id: "forearm_cover_top".into(), study: cover.clone(), rel: Pose::ID, parent: Some("forearm_frame".into()), joint: None, tip: None, process: SLS });
    parts.push(Placed { id: "forearm_cover_bottom".into(), study: cover, rel: Pose::rot([1.0, 0.0, 0.0], std::f64::consts::PI), parent: Some("forearm_frame".into()), joint: None, tip: None, process: SLS });
    // One spool per XC330 (the spool study is one part, placed 22 times).
    let spool = spool_study();
    for (k, (_, c, sz)) in bank().into_iter().enumerate() {
        let sp = spool_at(c, sz);
        let r = if sz > 0.0 { Pose::ID } else { Pose::rot([1.0, 0.0, 0.0], std::f64::consts::PI) };
        // Tendons leave toward +x (the stop bar).
        let rel = Pose { r: r.r, t: sp };
        parts.push(Placed { id: format!("spool_{:02}", k + 1), study: spool.clone(), rel, parent: Some("forearm_frame".into()), joint: None, tip: None, process: LPBF });
    }
    Design { parts, hand, bank: bank() }
}

pub fn spool_center(c: V3, sz: f64) -> V3 {
    spool_at(c, sz)
}
pub fn servo_envelope(c: V3, sz: f64) -> [V3; 2] {
    servo_box(c, sz)
}
pub fn xm_envelopes() -> [[V3; 2]; 2] {
    [xm_flex(), xm_dev()]
}
pub fn board_envelopes() -> Vec<(&'static str, &'static str, [V3; 2])> {
    boards()
}
pub const LOADS: [(&str, f64); 6] = [("tendon_stall_n", T_STALL), ("tendon_pretension_n", T_PRE), ("fingertip_grip_n", GRIP), ("side_push_n", SIDE), ("tip_strike_n", STRIKE), ("drop_g", DROP_G)];
pub const BEARINGS: [Brg; 3] = [B693, B623, B688];
