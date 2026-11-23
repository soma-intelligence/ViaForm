//! The beam element: a solid round bar between two nodes with six degrees of freedom each (three
//! translations, then three rotations), Euler-Bernoulli bending in both planes and Saint-Venant
//! torsion.
//!
//! A round section bends alike in every plane, so the element needs no local axes: with `n` the
//! unit axis from the first end to the second, `P = I - n nᵀ` and `X v = n × v`, the stiffness of
//! a bar of diameter `d` is `d² Ka + d⁴ Kb`, `Ka` the axial part and `Kb` the bending and torsion
//! part of a unit-diameter bar. End vectors are `[u1, θ1, u2, θ2]`, twelve numbers.

use std::f64::consts::PI;

pub type V3 = [f64; 3];

pub fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

pub fn scale(a: V3, s: f64) -> V3 {
    [a[0] * s, a[1] * s, a[2] * s]
}

pub fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

pub fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

pub fn norm(a: V3) -> f64 {
    dot(a, a).sqrt()
}

pub fn dist(a: V3, b: V3) -> f64 {
    norm(sub(a, b))
}

/// Where a bar lies: its unit axis, first end to second, and its length (mm).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Line {
    pub n: V3,
    pub len: f64,
}

impl Line {
    pub fn new(a: V3, b: V3) -> Self {
        let v = sub(b, a);
        let len = norm(v);
        Self { n: scale(v, 1.0 / len), len }
    }
}

/// Young's and shear moduli, MPa, and a factor on the bending and torsion stiffness (1 for the
/// real bars; small for a frame that should act as a pin-jointed truss, with just enough bending
/// left to hold its joints).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Elastic {
    pub e: f64,
    pub g: f64,
    pub bend: f64,
}

fn part(u: &[f64; 12], i: usize) -> V3 {
    [u[3 * i], u[3 * i + 1], u[3 * i + 2]]
}

fn put(out: &mut [f64; 12], i: usize, v: V3) {
    out[3 * i..3 * i + 3].copy_from_slice(&v);
}

/// End actions `Ka u` and `Kb u` of a unit-diameter bar for end displacements `u`.
pub fn actions_unit(line: &Line, el: &Elastic, u: &[f64; 12]) -> ([f64; 12], [f64; 12]) {
    let (n, l) = (line.n, line.len);
    let (u1, t1, u2, t2) = (part(u, 0), part(u, 1), part(u, 2), part(u, 3));
    let axial = el.e * PI / 4.0 / l;
    let ei = el.e * el.bend * PI / 64.0;
    let (b12, b6, b4, b2) = (12.0 * ei / (l * l * l), 6.0 * ei / (l * l), 4.0 * ei / l, 2.0 * ei / l);
    let gj = el.g * el.bend * PI / 32.0 / l;

    let delta = sub(u2, u1);
    let stretch = axial * dot(n, delta);
    let mut ka = [0.0; 12];
    put(&mut ka, 0, scale(n, -stretch));
    put(&mut ka, 2, scale(n, stretch));

    let across = sub(delta, scale(n, dot(n, delta)));
    let f2 = add(scale(across, b12), scale(cross(n, add(t1, t2)), b6));
    let turn = scale(cross(n, delta), -b6);
    let twist = gj * dot(n, sub(t1, t2));
    let p1 = sub(t1, scale(n, dot(n, t1)));
    let p2 = sub(t2, scale(n, dot(n, t2)));
    let m1 = add(add(turn, scale(n, twist)), add(scale(p1, b4), scale(p2, b2)));
    let m2 = add(add(turn, scale(n, -twist)), add(scale(p1, b2), scale(p2, b4)));
    let mut kb = [0.0; 12];
    put(&mut kb, 0, scale(f2, -1.0));
    put(&mut kb, 1, m1);
    put(&mut kb, 2, f2);
    put(&mut kb, 3, m2);
    (ka, kb)
}

/// End actions `K(d) u`.
pub fn actions(line: &Line, el: &Elastic, d: f64, u: &[f64; 12]) -> [f64; 12] {
    let (a, b) = actions_unit(line, el, u);
    let (d2, d4) = (d * d, d * d * d * d);
    std::array::from_fn(|i| d2 * a[i] + d4 * b[i])
}

/// `∂K/∂d u`.
pub fn actions_rate(line: &Line, el: &Elastic, d: f64, u: &[f64; 12]) -> [f64; 12] {
    let (a, b) = actions_unit(line, el, u);
    let (d1, d3) = (2.0 * d, 4.0 * d * d * d);
    std::array::from_fn(|i| d1 * a[i] + d3 * b[i])
}

/// The 12×12 stiffness of a bar of diameter `d`.
pub fn stiffness(line: &Line, el: &Elastic, d: f64) -> [[f64; 12]; 12] {
    let mut k = [[0.0; 12]; 12];
    for c in 0..12 {
        let mut e = [0.0; 12];
        e[c] = 1.0;
        let col = actions(line, el, d, &e);
        for (r, row) in k.iter_mut().enumerate() {
            row[c] = col[r];
        }
    }
    k
}

/// Equivalent end loads of a uniform line load `q` (N/mm) along the bar.
pub fn line_load(line: &Line, q: V3) -> [f64; 12] {
    let l = line.len;
    let half = scale(q, l / 2.0);
    let m = scale(cross(line.n, q), l * l / 12.0);
    let mut out = [0.0; 12];
    put(&mut out, 0, half);
    put(&mut out, 1, m);
    put(&mut out, 2, half);
    put(&mut out, 3, scale(m, -1.0));
    out
}

/// Cross-section area of a round bar, mm².
pub fn area(d: f64) -> f64 {
    PI * d * d / 4.0
}

/// Von Mises stress at one end of a bar of diameter `d` along `n` carrying end force `f` and end
/// moment `m`: the outer fibre, where axial and bending stress add and torsion shear peaks, MPa.
pub fn von_mises(n: V3, d: f64, f: V3, m: V3) -> f64 {
    let w = PI * d * d * d / 32.0;
    let torque = dot(m, n);
    let sigma = dot(f, n).abs() / area(d) + norm(sub(m, scale(n, torque))) / w;
    let tau = torque.abs() / (2.0 * w);
    (sigma * sigma + 3.0 * tau * tau).sqrt()
}

/// [`von_mises`] smoothed by `eps` (MPa) so it stays differentiable at zero, and its derivatives
/// by the end force, the end moment and the diameter (end actions held).
#[derive(Clone, Copy, Debug)]
pub struct EndStress {
    pub s: f64,
    pub df: V3,
    pub dm: V3,
    pub dd: f64,
}

pub fn end_stress(n: V3, d: f64, f: V3, m: V3, eps: f64) -> EndStress {
    let a = area(d);
    let w = PI * d * d * d / 32.0;
    let wt = 2.0 * w;
    let sn = dot(f, n) / a;
    let torque = dot(m, n);
    let bend = scale(sub(m, scale(n, torque)), 1.0 / w);
    let sm2 = dot(bend, bend);
    let st = torque / wt;
    let nn = (sn * sn + eps * eps).sqrt();
    let mm = (sm2 + eps * eps).sqrt();
    let sigma = nn + mm;
    let s = (sigma * sigma + 3.0 * st * st).sqrt();
    let by_sigma = sigma / s;
    let by_shear = 3.0 * st / s;
    EndStress {
        s,
        df: scale(n, by_sigma * sn / nn / a),
        dm: add(scale(bend, by_sigma / (w * mm)), scale(n, by_shear / wt)),
        dd: (by_sigma * (-2.0 * sn * sn / nn - 3.0 * sm2 / mm) - 3.0 * by_shear * st) / d,
    }
}
