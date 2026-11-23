use std::f64::consts::PI;
use std::time::Instant;

use super::beam::{self, Elastic, Line, V3, add, cross, dot, norm, scale, sub};
use super::ground::{self, point_distance, segment_distance};
use super::model::{Limits, Model, Setup};
use super::{design, layout, optimize};
use crate::solid::grid::unit;
use crate::solid::{Load, LoadCase, Method, Mesh, Objective, Region, Study, Support};

fn aluminium() -> Elastic {
    Elastic { e: 69_000.0, g: 69_000.0 / (2.0 * 1.33), bend: 1.0 }
}

/// A setup of the given nodes and beams, every beam its own group; `clamped` nodes hold all six.
fn setup(nodes: Vec<V3>, beams: Vec<[usize; 2]>, clamped: &[usize], loads: Vec<Vec<f64>>, accel: Vec<Option<V3>>) -> Setup {
    let n = nodes.len();
    let mut fixed = vec![false; 6 * n];
    for &v in clamped {
        fixed[6 * v..6 * v + 6].fill(true);
    }
    let cases = loads.len();
    Setup {
        group: (0..beams.len()).collect(),
        groups: beams.len(),
        cap: vec![f64::INFINITY; beams.len()],
        joint_cap: vec![f64::INFINITY; n],
        nodes,
        beams,
        fixed,
        loads,
        accel,
        weight: vec![1.0; cases],
    }
}

/// A rotation taking the x, y, z axes somewhere skew.
fn skew(p: V3) -> V3 {
    let (a, b) = (0.7f64, -0.4f64);
    let r1 = [p[0] * a.cos() - p[1] * a.sin(), p[0] * a.sin() + p[1] * a.cos(), p[2]];
    [r1[0], r1[1] * b.cos() - r1[2] * b.sin(), r1[1] * b.sin() + r1[2] * b.cos()]
}

#[test]
fn rigid_motions_cost_nothing_and_the_matrix_is_symmetric() {
    let line = Line::new([1.0, 2.0, 3.0], [31.0, -7.0, 18.0]);
    let el = aluminium();
    let k = beam::stiffness(&line, &el, 3.0);
    for r in 0..12 {
        for c in 0..12 {
            assert!((k[r][c] - k[c][r]).abs() <= 1e-9 * k[r][r].abs().max(k[c][c].abs()));
        }
    }
    let ends = [[1.0, 2.0, 3.0], [31.0, -7.0, 18.0]];
    let omega = [0.3, -0.2, 0.5];
    let shift = [0.1, 0.4, -0.7];
    let mut u = [0.0; 12];
    for (i, p) in ends.iter().enumerate() {
        let v = add(shift, cross(omega, *p));
        u[6 * i..6 * i + 3].copy_from_slice(&v);
        u[6 * i + 3..6 * i + 6].copy_from_slice(&omega);
    }
    let f = beam::actions(&line, &el, 3.0, &u);
    let scale_f = beam::actions(&line, &el, 3.0, &std::array::from_fn(|i| if i == 1 { 1.0 } else { 0.0 }));
    let big = scale_f.iter().fold(0.0f64, |a, x| a.max(x.abs()));
    assert!(f.iter().all(|x| x.abs() < 1e-9 * big), "{f:?}");
}

#[test]
fn cantilever_matches_beam_theory() {
    // Eight elements along a skew axis, clamped at the root: tip deflection under a transverse
    // force, stretch under an axial force and twist under a torque, against the closed forms.
    let (l, d, segments) = (200.0, 4.0, 8);
    let axis = unit(skew([1.0, 0.0, 0.0]));
    let side = unit(skew([0.0, 1.0, 0.0]));
    let nodes: Vec<V3> = (0..=segments).map(|i| scale(axis, l * i as f64 / segments as f64)).collect();
    let beams: Vec<[usize; 2]> = (0..segments).map(|i| [i, i + 1]).collect();
    let (p, t) = (10.0, 500.0);
    let tip = segments;
    let mut bend = vec![0.0; 6 * (segments + 1)];
    bend[6 * tip..6 * tip + 3].copy_from_slice(&scale(side, p));
    let mut pull = vec![0.0; 6 * (segments + 1)];
    pull[6 * tip..6 * tip + 3].copy_from_slice(&scale(axis, p));
    let mut twist = vec![0.0; 6 * (segments + 1)];
    twist[6 * tip + 3..6 * tip + 6].copy_from_slice(&scale(axis, t));
    let s = setup(nodes, beams, &[0], vec![bend, pull, twist], vec![None; 3]);
    let el = aluminium();
    let m = Model::new(&s, &[true; 8], el, 2.7e-9).unwrap();
    let (resp, _) = m.analyse(&[d; 8]).unwrap();
    let tip_m = m.origin.iter().position(|&v| v == tip).unwrap();
    let at = |c: usize, off: usize| -> V3 { std::array::from_fn(|a| resp.u[c][6 * tip_m + off + a]) };
    let (i, a, j) = (PI * d.powi(4) / 64.0, PI * d * d / 4.0, PI * d.powi(4) / 32.0);
    let bending = dot(at(0, 0), side);
    let stretch = dot(at(1, 0), axis);
    let turn = dot(at(2, 3), axis);
    let exact = [p * l.powi(3) / (3.0 * el.e * i), p * l / (el.e * a), t * l / (el.g * j)];
    for (got, want) in [bending, stretch, turn].iter().zip(exact) {
        assert!((got / want - 1.0).abs() < 1e-9, "{got} vs {want}");
    }
    // Root stress under the transverse force: M = P L on the outer fibre.
    let root = resp.stress[0][0][0];
    let want = p * l / (PI * d.powi(3) / 32.0);
    assert!((root / want - 1.0).abs() < 1e-9, "{root} vs {want}");
}

#[test]
fn two_bar_tower_carries_the_truss_forces() {
    // Two slender bars from clamped feet to an apex, loaded in their plane, tilted in 3D: the
    // axial forces match the pin-jointed truss to within the bending the rigid joints add. That
    // bending carries a share of the load of the order of the transverse to axial stiffness,
    // 12 I / (A L²) = (3/4) (d/L)², so the gap shrinks with the square of the diameter.
    let (a, b, c) = (skew([-60.0, 0.0, 0.0]), skew([45.0, 0.0, 0.0]), skew([0.0, 0.0, 100.0]));
    let f = add(scale(skew([1.0, 0.0, 0.0]), 300.0), scale(skew([0.0, 0.0, 1.0]), -800.0));
    let mut load = vec![0.0; 18];
    load[12..15].copy_from_slice(&f);
    let s = setup(vec![a, b, c], vec![[0, 2], [1, 2]], &[0, 1], vec![load], vec![None]);
    let m = Model::new(&s, &[true, true], aluminium(), 2.7e-9).unwrap();
    // Truss: T_a u_ca + T_b u_cb + f = 0, solved in the plane of the bars.
    let (ua, ub) = (unit(sub(a, c)), unit(sub(b, c)));
    let (aa, ab, bb) = (dot(ua, ua), dot(ua, ub), dot(ub, ub));
    let (fa, fb) = (-dot(f, ua), -dot(f, ub));
    let det = aa * bb - ab * ab;
    let ta = (fa * bb - fb * ab) / det;
    let tb = (aa * fb - ab * fa) / det;
    let shortest = norm(sub(b, c)).min(norm(sub(a, c)));
    let mut gaps = Vec::new();
    for dd in [3.0, 0.3] {
        let d = [dd, dd];
        let (resp, _) = m.analyse(&d).unwrap();
        let tol = 4.0 * (dd / shortest).powi(2);
        let mut gap = 0.0f64;
        for (e, want) in [(0, ta), (1, tb)] {
            let act = m.end_actions(0, e, d[e], &resp.u[0]);
            let tension = dot([act[6], act[7], act[8]], m.lines[e].n);
            assert!((tension / want - 1.0).abs() < tol, "d {dd}, bar {e}: {tension} vs {want}");
            gap = gap.max((tension / want - 1.0).abs());
        }
        gaps.push(gap);
    }
    // Ten times thinner, a hundred times closer to the truss.
    assert!(gaps[1] < 0.02 * gaps[0] && gaps[1] > 0.005 * gaps[0], "{gaps:?}");
}

#[test]
fn sparse_solve_matches_dense_elimination() {
    let study = cantilever(1.0);
    let anchors: Vec<V3> = vec![[0.0, 20.0, 20.0], [120.0, 20.0, 20.0]];
    let g = ground::build(&study, &anchors).unwrap();
    let n = g.nodes.len();
    let mut clamped = Vec::new();
    for (v, p) in g.nodes.iter().enumerate() {
        if p[0] == 0.0 {
            clamped.push(v);
        }
    }
    let mut load = vec![0.0; 6 * n];
    for (i, x) in load.iter_mut().enumerate() {
        *x = ((i * 7919) % 101) as f64 - 50.0;
    }
    let s = setup(g.nodes.clone(), g.beams.clone(), &clamped, vec![load.clone()], vec![None]);
    let keep = vec![true; g.beams.len()];
    let m = Model::new(&s, &keep, aluminium(), 2.7e-9).unwrap();
    let d: Vec<f64> = (0..m.ends.len()).map(|e| 1.0 + (e % 5) as f64).collect();
    let (resp, _) = m.analyse(&d).unwrap();
    // Dense K with held rows and columns as the identity.
    let dofs = m.dofs();
    let mut k = vec![vec![0.0; dofs]; dofs];
    for (e, &[a, b]) in m.ends.iter().enumerate() {
        let ke = beam::stiffness(&m.lines[e], &m.el, d[e]);
        let map: Vec<usize> = (0..12).map(|i| if i < 6 { 6 * a + i } else { 6 * b + i - 6 }).collect();
        for r in 0..12 {
            for c in 0..12 {
                k[map[r]][map[c]] += ke[r][c];
            }
        }
    }
    let mut rhs = m.loads[0].clone();
    for i in 0..dofs {
        if m.fixed[i] {
            for j in 0..dofs {
                k[i][j] = 0.0;
                k[j][i] = 0.0;
            }
            k[i][i] = 1.0;
            rhs[i] = 0.0;
        }
    }
    // Gaussian elimination with partial pivoting.
    for col in 0..dofs {
        let piv = (col..dofs).max_by(|&x, &y| k[x][col].abs().total_cmp(&k[y][col].abs())).unwrap();
        k.swap(col, piv);
        rhs.swap(col, piv);
        for r in col + 1..dofs {
            let f = k[r][col] / k[col][col];
            if f != 0.0 {
                for c in col..dofs {
                    k[r][c] -= f * k[col][c];
                }
                rhs[r] -= f * rhs[col];
            }
        }
    }
    let mut x = vec![0.0; dofs];
    for r in (0..dofs).rev() {
        let s: f64 = (r + 1..dofs).map(|c| k[r][c] * x[c]).sum();
        x[r] = (rhs[r] - s) / k[r][r];
    }
    let big = x.iter().fold(0.0f64, |a, v| a.max(v.abs()));
    let err = x.iter().zip(&resp.u[0]).fold(0.0f64, |a, (p, q)| a.max((p - q).abs()));
    assert!(err < 1e-8 * big, "{err} vs {big}");
}

#[test]
fn adjoint_gradient_matches_finite_differences() {
    let mut study = cantilever(1.0);
    study.max = [60.0, 30.0, 30.0];
    let anchors: Vec<V3> = vec![[0.0, 15.0, 15.0], [60.0, 15.0, 15.0]];
    let g = ground::build(&study, &anchors).unwrap();
    let n = g.nodes.len();
    let clamped: Vec<usize> = (0..n).filter(|&v| g.nodes[v][0] == 0.0).collect();
    let tip = (0..n).min_by(|&a, &b| beam::dist(g.nodes[a], [60.0, 15.0, 15.0]).total_cmp(&beam::dist(g.nodes[b], [60.0, 15.0, 15.0]))).unwrap();
    let mut push = vec![0.0; 6 * n];
    push[6 * tip + 2] = -400.0;
    push[6 * tip + 1] = 150.0;
    let mut turn = vec![0.0; 6 * n];
    turn[6 * tip + 3] = 2000.0;
    let s = setup(g.nodes.clone(), g.beams.clone(), &clamped, vec![push, turn], vec![Some([0.0, 0.0, -9810.0 * 50.0]), None]);
    let keep = vec![true; g.beams.len()];
    let m = Model::new(&s, &keep, aluminium(), 2.7e-9).unwrap();
    let d: Vec<f64> = (0..m.ends.len()).map(|e| 0.4 + 0.37 * (e % 11) as f64).collect();
    let lim = Limits { stress: 120.0, displacement: Some(0.05), p: 8.0, d_lo: 0.2, d_cut: 2.0 };
    let value = |d: &[f64]| {
        let (r, f) = m.analyse(d).unwrap();
        m.aggregate(d, &r, &f, &lim).value
    };
    let (r, f) = m.analyse(&d).unwrap();
    let agg = m.aggregate(&d, &r, &f, &lim);
    let mut checked = 0;
    for e in (0..m.ends.len()).step_by(7) {
        let h = 1e-6 * d[e];
        let mut up = d.clone();
        up[e] += h;
        let mut down = d.clone();
        down[e] -= h;
        let fd = (value(&up) - value(&down)) / (2.0 * h);
        let tol = 1e-4 * agg.grad.iter().fold(0.0f64, |a, g| a.max(g.abs()));
        assert!((fd - agg.grad[e]).abs() <= tol + 1e-4 * fd.abs(), "beam {e}: adjoint {} vs {fd}", agg.grad[e]);
        checked += 1;
    }
    assert!(checked > 10);
}

/// A 120 × 40 × 40 mm cantilever: held over its x = 0 face, pushed down at the far end's centre.
fn cantilever(voxel: f64) -> Study {
    Study {
        method: Method::Frame,
        objective: Objective::Mass,
        min: [0.0; 3],
        max: [120.0, 40.0, 40.0],
        voxel,
        supports: vec![Support { region: Region::Box { min: [-1.0, -1.0, -1.0], max: [1.0, 41.0, 41.0] }, fix: [true; 3] }],
        cases: vec![LoadCase { name: "tip".into(), loads: vec![Load::Force { region: Region::Box { min: [119.0, 15.0, 15.0], max: [121.0, 25.0, 25.0] }, force: [0.0, 0.0, -500.0] }], acceleration: None, weight: 1.0 }],
        ..Study::default()
    }
}

/// Every directed edge has its reverse: each part closed and consistently wound.
fn closed(mesh: &Mesh) -> bool {
    let mut edges = std::collections::HashMap::new();
    for t in mesh.indices.chunks(3) {
        for k in 0..3 {
            *edges.entry((t[k], t[(k + 1) % 3])).or_insert(0i32) += 1;
        }
    }
    edges.iter().all(|(&(a, b), &n)| n == 1 && edges.get(&(b, a)) == Some(&1))
}

fn volume(mesh: &Mesh) -> f64 {
    let p = |i: u32| -> V3 { std::array::from_fn(|a| mesh.positions[3 * i as usize + a] as f64) };
    mesh.indices.chunks(3).map(|t| dot(p(t[0]), cross(p(t[1]), p(t[2]))) / 6.0).sum()
}

#[test]
fn cantilever_space_truss_keeps_the_stress_limit() {
    let study = cantilever(1.0);
    let start = Instant::now();
    let frame = design(&study, study.seed).unwrap();
    let sized = start.elapsed().as_secs_f64();
    let out = layout(&study, &frame).unwrap();
    let total = start.elapsed().as_secs_f64();
    let allowable = study.material.allowable / study.safety_factor;
    let worst = frame.max_stress[0];
    // The two-bar truss to the wall's top and bottom edges: the lightest pin-jointed answer a
    // 40 mm deep wall allows for a load 120 mm out, V = 2 P (L² + h²/4) / (h σ).
    let (p, l, h) = (500.0, 120.0, 40.0);
    let two_bar = 2.0 * p * (l * l + h * h / 4.0) / (h * allowable) * study.material.density;
    println!(
        "cantilever: {} bars, {} joints, mass {:.2} g (two-bar truss {:.2} g), worst stress {:.1} / {:.1} MPa, tip {:.3} mm, {} iterations, sized {:.3} s, laid out {:.3} s",
        frame.beams.len(),
        frame.nodes.len(),
        frame.mass_g,
        two_bar,
        worst,
        allowable,
        frame.max_displacement[0],
        frame.history.len(),
        sized,
        total
    );
    assert!(frame.feasible);
    assert!(worst <= allowable * (1.0 + 1e-6), "{worst} > {allowable}");
    assert!(worst >= 0.5 * allowable, "the lightest frame is not near its limit: {worst}");
    assert!(frame.mass_g > 0.8 * two_bar && frame.mass_g < 4.0 * two_bar, "mass {} g vs two-bar {two_bar} g", frame.mass_g);
    assert!(frame.beams.iter().all(|b| b.diameter >= study.min_member));
    assert!(frame.history.len() <= study.iterations + 61);
    let filled = out.density.iter().filter(|&&x| x > 0.5).count();
    assert!(filled > 0 && filled < out.density.len() / 4);
    let mesh = out.mesh.as_ref().unwrap();
    assert!(closed(mesh));
    assert!(volume(mesh) > 0.0);
    assert_eq!(mesh.stress.len(), mesh.positions.len() / 3);
    // About 1.5 s on an idle machine; the bound leaves room for a machine shared with other
    // builds (a tight wall-clock bound failed at 3.04 s under load).
    if !cfg!(debug_assertions) {
        assert!(total < 10.0, "{total} s");
    }
}

#[test]
fn the_same_seed_gives_the_same_frame() {
    let mut study = cantilever(2.0);
    study.cases.push(LoadCase { name: "side".into(), loads: vec![Load::Torque { region: Region::Sphere { center: [120.0, 20.0, 20.0], radius: 3.0 }, center: [120.0, 20.0, 20.0], axis: [1.0, 0.0, 0.0], moment: 4000.0 }], acceleration: Some([0.0, -9810.0, 0.0]), weight: 1.0 });
    let a = optimize(&study, 7).unwrap();
    let b = optimize(&study, 7).unwrap();
    assert_eq!(a, b);
    let c = design(&study, 8).unwrap();
    assert!(c.feasible);
}

#[test]
fn keep_out_stays_empty() {
    let mut study = cantilever(1.0);
    let hole = Region::Cylinder { base: [60.0, -1.0, 20.0], axis: [0.0, 1.0, 0.0], radius: 9.0, length: 42.0 };
    study.keep_out.push(hole);
    let frame = design(&study, 1).unwrap();
    assert!(frame.feasible);
    for b in &frame.beams {
        let (p, q) = (frame.nodes[b.ends[0]], frame.nodes[b.ends[1]]);
        assert!(segment_distance(&hole, p, q) >= b.diameter / 2.0 - 1e-9);
    }
    for (p, &r) in frame.nodes.iter().zip(&frame.joints) {
        assert!(point_distance(&hole, *p) >= r - 1e-9);
    }
    let out = layout(&study, &frame).unwrap();
    for e in out.grid.elements_in(&hole) {
        assert_eq!(out.density[e], 0.0);
    }
}

#[test]
fn symmetry_ties_mirrored_bars() {
    let mut study = cantilever(1.0);
    study.max = [80.0, 40.0, 40.0];
    study.symmetry = [false, true, false];
    // An off-centre load: the design still mirrors across y = 20.
    study.cases[0].loads = vec![Load::Force { region: Region::Sphere { center: [80.0, 8.0, 20.0], radius: 2.0 }, force: [0.0, 0.0, -400.0] }];
    let frame = design(&study, 3).unwrap();
    assert!(frame.feasible);
    let mirror = |p: V3| [p[0], 40.0 - p[1], p[2]];
    let find = |p: V3| frame.nodes.iter().position(|&q| beam::dist(p, q) < 1e-6);
    for b in &frame.beams {
        let (ma, mb) = (find(mirror(frame.nodes[b.ends[0]])).unwrap(), find(mirror(frame.nodes[b.ends[1]])).unwrap());
        let twin = frame.beams.iter().find(|c| (c.ends == [ma, mb]) || (c.ends == [mb, ma])).expect("mirrored bar");
        assert_eq!(twin.diameter, b.diameter);
    }
    let out = layout(&study, &frame).unwrap();
    let odd = (0..out.grid.elements()).filter(|&e| out.density[e] != out.density[out.grid.mirror(e, study.symmetry)]).count();
    assert_eq!(odd, 0);
}

#[test]
fn bad_studies_are_errors() {
    let good = cantilever(2.0);
    let mut s = good.clone();
    s.max[1] = s.min[1];
    assert!(design(&s, 1).is_err());
    let mut s = good.clone();
    s.supports.clear();
    assert!(design(&s, 1).is_err());
    let mut s = good.clone();
    s.voxel = f64::NAN;
    assert!(design(&s, 1).is_err());
    let mut s = good.clone();
    s.cases[0].loads = vec![Load::Force { region: Region::Sphere { center: [100.0, 20.0, 20.0], radius: 1.0 }, force: [0.0, 0.0, 0.0] }];
    assert!(design(&s, 1).is_err());
    let mut s = good.clone();
    s.voxel = 1e-4;
    assert!(design(&s, 1).is_err());
    // Held along z only: free to slide, an error rather than a panic.
    let mut s = good.clone();
    s.supports[0].fix = [false, false, true];
    assert!(design(&s, 1).is_err());
    // A wall of keep-out between the support and the load.
    let mut s = good.clone();
    s.keep_out.push(Region::Box { min: [50.0, -5.0, -5.0], max: [60.0, 45.0, 45.0] });
    assert!(design(&s, 1).is_err());
    let mut s = good;
    s.material.e = -1.0;
    assert!(design(&s, 1).is_err());
}

#[test]
fn icosphere_and_prism_are_closed_and_outward() {
    let frame = super::Frame {
        nodes: vec![[0.0; 3], [10.0, 3.0, -4.0]],
        beams: vec![super::Beam { ends: [0, 1], diameter: 2.0, stress: 1.0 }],
        joints: vec![1.5, 1.5],
        compliance: vec![],
        max_stress: vec![],
        max_displacement: vec![],
        mass_g: 0.0,
        feasible: true,
        history: vec![],
    };
    let mesh = super::geometry::tubes(&frame);
    assert!(closed(&mesh));
    let l = norm(sub(frame.nodes[1], frame.nodes[0]));
    let prism = 0.5 * 12.0 * (2.0 * PI / 12.0).sin() * l;
    let v = volume(&mesh);
    assert!(v > prism && v < prism + 2.0 * 4.0 / 3.0 * PI * 1.5f64.powi(3), "{v}");
}

/// A 3-inch quad frame: 130 × 130 × 30 mm at 1 mm voxels, held at the centre stack, four motor
/// mounts on the diagonals with thrust and reaction torque, and a crash on one arm.
fn drone() -> Study {
    let mount = |x: f64, y: f64| Region::Cylinder { base: [x, y, 0.0], axis: [0.0, 0.0, 1.0], radius: 5.0, length: 8.0 };
    let corners = [(15.0, 15.0), (115.0, 15.0), (115.0, 115.0), (15.0, 115.0)];
    let mut thrust = Vec::new();
    for (k, &(x, y)) in corners.iter().enumerate() {
        thrust.push(Load::Force { region: mount(x, y), force: [0.0, 0.0, 12.0] });
        let spin = if k % 2 == 0 { 80.0 } else { -80.0 };
        thrust.push(Load::Torque { region: mount(x, y), center: [x, y, 4.0], axis: [0.0, 0.0, 1.0], moment: spin });
    }
    Study {
        method: Method::Frame,
        objective: Objective::Mass,
        min: [0.0; 3],
        max: [130.0, 130.0, 30.0],
        voxel: 1.0,
        supports: vec![Support { region: Region::Box { min: [50.0, 50.0, 0.0], max: [80.0, 80.0, 10.0] }, fix: [true; 3] }],
        cases: vec![
            LoadCase { name: "thrust".into(), loads: thrust, acceleration: Some([0.0, 0.0, -9810.0 * 4.0]), weight: 1.0 },
            LoadCase { name: "crash".into(), loads: vec![Load::Force { region: mount(115.0, 115.0), force: [-60.0, -60.0, -40.0] }], acceleration: None, weight: 1.0 },
        ],
        keep_out: vec![Region::Cylinder { base: [65.0, 65.0, 12.0], axis: [0.0, 0.0, 1.0], radius: 12.0, length: 18.0 }],
        min_member: 2.0,
        ..Study::default()
    }
}

#[test]
fn drone_frame_sizes_quickly_and_holds() {
    let study = drone();
    let start = Instant::now();
    let frame = design(&study, study.seed).unwrap();
    let sized = start.elapsed().as_secs_f64();
    let allowable = study.material.allowable / study.safety_factor;
    let worst = frame.max_stress.iter().copied().fold(0.0, f64::max);
    println!(
        "drone: {} bars, {} joints, mass {:.2} g, worst stress {:.1} / {:.1} MPa, displacement {:?} mm, {} iterations, sized {:.3} s",
        frame.beams.len(),
        frame.nodes.len(),
        frame.mass_g,
        worst,
        allowable,
        frame.max_displacement,
        frame.history.len(),
        sized
    );
    assert!(frame.feasible);
    assert!(worst <= allowable * (1.0 + 1e-6));
    assert!(frame.beams.iter().all(|b| b.diameter >= study.min_member));
    if !cfg!(debug_assertions) {
        assert!(sized < 30.0, "{sized} s");
    }
    // Stiffer than the stress alone makes it: the displacement limit holds too.
    let mut stiff = study.clone();
    stiff.max_displacement = Some(0.5);
    let frame = design(&stiff, stiff.seed).unwrap();
    println!("drone, 0.5 mm: {} bars, mass {:.2} g, displacement {:?} mm", frame.beams.len(), frame.mass_g, frame.max_displacement);
    assert!(frame.feasible);
    assert!(frame.max_displacement.iter().all(|&u| u <= 0.5 * (1.0 + 1e-6)));
}
