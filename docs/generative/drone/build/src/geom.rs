//! Vectors, rigid transforms, closed meshes of simple bodies, mass properties.

use viaform_generative::solid::Mesh;

pub type V3 = [f64; 3];

pub fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
pub fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
pub fn scale(a: V3, k: f64) -> V3 {
    [a[0] * k, a[1] * k, a[2] * k]
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
pub fn unit(a: V3) -> V3 {
    let n = norm(a);
    if n > 0.0 { scale(a, 1.0 / n) } else { a }
}

/// Rigid transform: `r` row-major (columns are the local axes in the parent), then `t`.
#[derive(Clone, Copy, Debug)]
pub struct Tf {
    pub r: [[f64; 3]; 3],
    pub t: V3,
}

impl Tf {
    pub const ID: Tf = Tf { r: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], t: [0.0; 3] };
    pub fn trans(t: V3) -> Tf {
        Tf { t, ..Tf::ID }
    }
    /// Local axes x, y, z expressed in the parent, origin at `t`.
    pub fn axes(x: V3, y: V3, z: V3, t: V3) -> Tf {
        Tf { r: [[x[0], y[0], z[0]], [x[1], y[1], z[1]], [x[2], y[2], z[2]]], t }
    }
    pub fn rot(axis: V3, angle: f64, t: V3) -> Tf {
        let [x, y, z] = unit(axis);
        let (s, c) = angle.sin_cos();
        let k = 1.0 - c;
        Tf { r: [[c + x * x * k, x * y * k - z * s, x * z * k + y * s], [y * x * k + z * s, c + y * y * k, y * z * k - x * s], [z * x * k - y * s, z * y * k + x * s, c + z * z * k]], t }
    }
    pub fn vector(&self, v: V3) -> V3 {
        [0, 1, 2].map(|i| self.r[i][0] * v[0] + self.r[i][1] * v[1] + self.r[i][2] * v[2])
    }
    pub fn point(&self, p: V3) -> V3 {
        add(self.vector(p), self.t)
    }
    /// World point to local.
    pub fn inverse_point(&self, p: V3) -> V3 {
        let d = sub(p, self.t);
        [0, 1, 2].map(|j| self.r[0][j] * d[0] + self.r[1][j] * d[1] + self.r[2][j] * d[2])
    }
    pub fn matrix4(&self) -> [[f64; 4]; 4] {
        let r = &self.r;
        [[r[0][0], r[0][1], r[0][2], self.t[0]], [r[1][0], r[1][1], r[1][2], self.t[1]], [r[2][0], r[2][1], r[2][2], self.t[2]], [0.0, 0.0, 0.0, 1.0]]
    }
    pub fn pose12(&self) -> [f64; 12] {
        let r = &self.r;
        [r[0][0], r[0][1], r[0][2], self.t[0], r[1][0], r[1][1], r[1][2], self.t[1], r[2][0], r[2][1], r[2][2], self.t[2]]
    }
}

pub fn transformed(mesh: &Mesh, tf: &Tf) -> Mesh {
    let mut m = mesh.clone();
    for p in m.positions.chunks_mut(3) {
        let q = tf.point([p[0] as f64, p[1] as f64, p[2] as f64]);
        p.copy_from_slice(&q.map(|v| v as f32));
    }
    m
}

pub fn append(into: &mut Mesh, m: &Mesh) {
    let base = (into.positions.len() / 3) as u32;
    into.positions.extend_from_slice(&m.positions);
    into.indices.extend(m.indices.iter().map(|i| i + base));
    into.stress.clear();
}

fn push(m: &mut Mesh, p: V3) -> u32 {
    m.positions.extend(p.map(|x| x as f32));
    (m.positions.len() / 3 - 1) as u32
}

pub fn box_mesh(min: V3, max: V3) -> Mesh {
    let p = [
        [min[0], min[1], min[2]],
        [max[0], min[1], min[2]],
        [max[0], max[1], min[2]],
        [min[0], max[1], min[2]],
        [min[0], min[1], max[2]],
        [max[0], min[1], max[2]],
        [max[0], max[1], max[2]],
        [min[0], max[1], max[2]],
    ];
    let t: [[u32; 3]; 12] = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]];
    Mesh { positions: p.iter().flatten().map(|v| *v as f32).collect(), indices: t.iter().flatten().copied().collect(), stress: Vec::new() }
}

fn frame_of(ax: V3) -> (V3, V3) {
    let helper = if ax[0].abs() < 0.9 { [1.0, 0.0, 0.0] } else { [0.0, 1.0, 0.0] };
    let u = unit(cross(ax, helper));
    (u, cross(ax, u))
}

/// Closed cylinder from `a` to `b`.
pub fn cyl_mesh(a: V3, b: V3, r: f64, sides: usize) -> Mesh {
    let ax = unit(sub(b, a));
    let (u, v) = frame_of(ax);
    let mut m = Mesh::default();
    let ca = push(&mut m, a);
    let cb = push(&mut m, b);
    let ring: Vec<(u32, u32)> = (0..sides)
        .map(|k| {
            let t = k as f64 / sides as f64 * std::f64::consts::TAU;
            let d = add(scale(u, r * t.cos()), scale(v, r * t.sin()));
            (push(&mut m, add(a, d)), push(&mut m, add(b, d)))
        })
        .collect();
    for k in 0..sides {
        let (a0, b0) = ring[k];
        let (a1, b1) = ring[(k + 1) % sides];
        m.indices.extend([ca, a1, a0, cb, b0, b1, a0, a1, b1, a0, b1, b0]);
    }
    m
}

/// Closed tube (ring) from `a` to `b`, radii `ri` to `ro`.
pub fn ring_mesh(a: V3, b: V3, ri: f64, ro: f64, sides: usize) -> Mesh {
    let ax = unit(sub(b, a));
    let (u, v) = frame_of(ax);
    let mut m = Mesh::default();
    let ring: Vec<[u32; 4]> = (0..sides)
        .map(|k| {
            let t = k as f64 / sides as f64 * std::f64::consts::TAU;
            let d = add(scale(u, t.cos()), scale(v, t.sin()));
            [push(&mut m, add(a, scale(d, ri))), push(&mut m, add(a, scale(d, ro))), push(&mut m, add(b, scale(d, ri))), push(&mut m, add(b, scale(d, ro)))]
        })
        .collect();
    for k in 0..sides {
        let [i0, o0, i0t, o0t] = ring[k];
        let [i1, o1, i1t, o1t] = ring[(k + 1) % sides];
        m.indices.extend([o0, o1, o1t, o0, o1t, o0t, i0, i1t, i1, i0, i0t, i1t, i0, o1, o0, i0, i1, o1, i0t, o0t, o1t, i0t, o1t, i1t]);
    }
    m
}

/// Closed box along a local frame: centre `c`, axes `x`, `y` (z = x × y), half sizes `h`.
pub fn obox_mesh(c: V3, x: V3, y: V3, h: V3) -> Mesh {
    let z = cross(x, y);
    transformed(&box_mesh(scale(h, -1.0), h), &Tf::axes(x, y, z, c))
}

/// Volume, centroid and inertia tensor about the centroid per unit density (mm⁵) of a closed mesh.
pub fn mass_props(mesh: &Mesh) -> (f64, V3, [[f64; 3]; 3]) {
    let p = |i: u32| {
        let k = 3 * i as usize;
        [mesh.positions[k] as f64, mesh.positions[k + 1] as f64, mesh.positions[k + 2] as f64]
    };
    let (mut vol, mut c, mut s) = (0.0, [0.0; 3], [[0.0; 3]; 3]);
    for t in mesh.indices.chunks(3) {
        let (a, b, d) = (p(t[0]), p(t[1]), p(t[2]));
        let det = dot(a, cross(b, d));
        vol += det / 6.0;
        for i in 0..3 {
            c[i] += det / 24.0 * (a[i] + b[i] + d[i]);
            for j in 0..3 {
                s[i][j] += det / 120.0 * (2.0 * (a[i] * a[j] + b[i] * b[j] + d[i] * d[j]) + a[i] * b[j] + a[j] * b[i] + a[i] * d[j] + a[j] * d[i] + b[i] * d[j] + b[j] * d[i]);
            }
        }
    }
    let c = scale(c, 1.0 / vol);
    // Second moments about the centroid.
    for i in 0..3 {
        for j in 0..3 {
            s[i][j] -= vol * c[i] * c[j];
        }
    }
    let tr = s[0][0] + s[1][1] + s[2][2];
    let mut inertia = [[0.0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            inertia[i][j] = if i == j { tr - s[i][i] } else { -s[i][j] };
        }
    }
    (vol, c, inertia)
}

pub fn bounds(mesh: &Mesh) -> (V3, V3) {
    let (mut lo, mut hi) = ([f64::INFINITY; 3], [f64::NEG_INFINITY; 3]);
    for p in mesh.positions.chunks(3) {
        for i in 0..3 {
            lo[i] = lo[i].min(p[i] as f64);
            hi[i] = hi[i].max(p[i] as f64);
        }
    }
    (lo, hi)
}

/// Points on the surface, no further than `step` apart along each triangle (vertices, edge and
/// interior samples).
pub fn surface_samples(mesh: &Mesh, step: f64) -> Vec<V3> {
    let p = |i: u32| {
        let k = 3 * i as usize;
        [mesh.positions[k] as f64, mesh.positions[k + 1] as f64, mesh.positions[k + 2] as f64]
    };
    let mut out = Vec::new();
    for t in mesh.indices.chunks(3) {
        let (a, b, c) = (p(t[0]), p(t[1]), p(t[2]));
        let l = norm(sub(b, a)).max(norm(sub(c, b))).max(norm(sub(a, c)));
        let n = ((l / step).ceil() as usize).max(1);
        for i in 0..=n {
            for j in 0..=(n - i) {
                let (u, v) = (i as f64 / n as f64, j as f64 / n as f64);
                out.push(add(a, add(scale(sub(b, a), u), scale(sub(c, a), v))));
            }
        }
    }
    out
}
