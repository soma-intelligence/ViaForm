//! From a study's supports and load cases to the finite-element model's held degrees of freedom
//! and force vectors.
//!
//! A force spreads evenly over its region's nodes. A torque is a pure couple: tangential nodal
//! forces about the axis, each in proportion to its node's distance from it, so the moment is
//! exact and the net force zero. A pressure pushes the region's area projected along its
//! direction, spread evenly. A body acceleration loads each element's mass, an eighth to each of
//! its corners (the consistent load of a uniform field on a trilinear hexahedron).

use std::f64::consts::PI;

use rayon::prelude::*;

use super::grid::unit;
use super::{Grid, Load, LoadCase, Region, Support};

/// Per degree of freedom: held.
pub fn fixed_dofs(grid: &Grid, supports: &[Support]) -> Vec<bool> {
    let mut fixed = vec![false; grid.dofs()];
    for s in supports {
        for v in grid.nodes_in(&s.region) {
            for a in (0..3).filter(|&a| s.fix[a]) {
                fixed[3 * v + a] = true;
            }
        }
    }
    fixed
}

/// Nodal forces of the case's applied loads (forces, torques, pressures), N.
///
/// A torque whose nodes cannot carry a couple (one node, or all on one line along the axis) and a
/// load with a zero axis or direction add nothing: [`check`] reports them.
pub fn applied(grid: &Grid, case: &LoadCase) -> Vec<f64> {
    applied_on(grid, case, None)
}

/// As `applied`, the loads spread only on `live` nodes (those that touch material that can
/// exist: a node inside a keep-out hole would carry its share on nothing). A region with no
/// live node keeps all of its nodes.
pub fn applied_on(grid: &Grid, case: &LoadCase, live: Option<&[bool]>) -> Vec<f64> {
    applied_preferring(grid, case, None, live)
}

/// [`applied_on`], but a load whose region holds nodes of `solid` (nodes of material that is
/// always there, a keep-in) goes on those only: a load spread onto design voxels the optimiser
/// may thin to nothing pushes them through void stiffness and reads as an enormous stress.
pub fn applied_preferring(grid: &Grid, case: &LoadCase, solid: Option<&[bool]>, live: Option<&[bool]>) -> Vec<f64> {
    let nodes_of = |region: &Region| {
        let all = grid.nodes_in(region);
        if let Some(s) = solid {
            let kept: Vec<usize> = all.iter().copied().filter(|&v| s[v]).collect();
            if !kept.is_empty() {
                return kept;
            }
        }
        match live {
            Some(l) => {
                let kept: Vec<usize> = all.iter().copied().filter(|&v| l[v]).collect();
                if kept.is_empty() { all } else { kept }
            }
            None => all,
        }
    };
    let mut f = vec![0.0; grid.dofs()];
    for load in &case.loads {
        match load {
            Load::Force { region, force } => spread(&mut f, &nodes_of(region), *force),
            Load::Torque { region, center, axis, moment } => {
                let nodes = nodes_of(region);
                if let Some(forces) = couple(grid, &nodes, *center, *axis, *moment) {
                    for (&v, fv) in nodes.iter().zip(&forces) {
                        for a in 0..3 {
                            f[3 * v + a] += fv[a];
                        }
                    }
                }
            }
            Load::Pressure { region, direction, pressure } => {
                let d = unit(*direction);
                let total = pressure * projected_area(grid, region, d);
                spread(&mut f, &nodes_of(region), d.map(|x| x * total));
            }
        }
    }
    f
}

/// Nodal forces of the case's body acceleration on elements of mass density `rho` (t/mm³),
/// N; `None` when the case has no acceleration. Elements beyond `rho`'s length weigh nothing.
pub fn body(grid: &Grid, case: &LoadCase, rho: &[f64]) -> Option<Vec<f64>> {
    let acc = case.acceleration?;
    let mut f = vec![0.0; grid.dofs()];
    if grid.elements() == 0 {
        return Some(f);
    }
    let [nx, ny, nz] = grid.n;
    let share = grid.h.powi(3) / 8.0;
    // Gathered per node from its (up to) eight elements, so the nodes fill in parallel.
    f.par_chunks_mut(3).with_min_len(4096).enumerate().for_each(|(v, fv)| {
        let [i, j, k] = grid.node_ijk(v);
        let mut mass = 0.0;
        for kk in k.saturating_sub(1)..=k.min(nz - 1) {
            for jj in j.saturating_sub(1)..=j.min(ny - 1) {
                for ii in i.saturating_sub(1)..=i.min(nx - 1) {
                    mass += rho.get(grid.element(ii, jj, kk)).copied().unwrap_or(0.0);
                }
            }
        }
        for a in 0..3 {
            fv[a] = mass * share * acc[a];
        }
    });
    Some(f)
}

/// Whether the supports and load cases can be applied on `grid`: finite numbers, sensible
/// regions, non-zero axes and directions, a pressure with an area to push, a torque with nodes off
/// its axis, and at least one held degree of freedom.
pub fn check(grid: &Grid, supports: &[Support], cases: &[LoadCase]) -> Result<(), String> {
    if !(grid.h.is_finite() && grid.h > 0.0) || grid.elements() == 0 || !finite(&grid.origin) {
        return Err("the voxel grid is empty or its voxel edge is not positive".into());
    }
    if !supports.iter().any(|s| s.fix.iter().any(|&f| f)) {
        return Err("no support holds the part".into());
    }
    for (k, s) in supports.iter().enumerate() {
        region_ok(&s.region).map_err(|e| format!("support {}: {e}", k + 1))?;
    }
    for (c, case) in cases.iter().enumerate() {
        let name = if case.name.is_empty() { format!("load case {}", c + 1) } else { format!("load case '{}'", case.name) };
        if !(case.weight.is_finite() && case.weight >= 0.0) {
            return Err(format!("{name}: its weight must be a finite number, zero or more"));
        }
        if let Some(a) = case.acceleration
            && !finite(&a)
        {
            return Err(format!("{name}: its acceleration is not a finite vector"));
        }
        for (l, load) in case.loads.iter().enumerate() {
            let what = format!("{name}, load {}", l + 1);
            match load {
                Load::Force { region, force } => {
                    region_ok(region).map_err(|e| format!("{what}: {e}"))?;
                    if !finite(force) {
                        return Err(format!("{what}: the force is not a finite vector"));
                    }
                }
                Load::Torque { region, center, axis, moment } => {
                    region_ok(region).map_err(|e| format!("{what}: {e}"))?;
                    if !finite(center) || !finite(axis) || !moment.is_finite() {
                        return Err(format!("{what}: the torque's centre, axis or moment is not finite"));
                    }
                    if norm2(*axis) == 0.0 {
                        return Err(format!("{what}: the torque's axis is zero"));
                    }
                    if couple(grid, &grid.nodes_in(region), *center, *axis, 1.0).is_none() {
                        return Err(format!("{what}: the torque's region holds no nodes off its axis, so it cannot carry a moment"));
                    }
                }
                Load::Pressure { region, direction, pressure } => {
                    region_ok(region).map_err(|e| format!("{what}: {e}"))?;
                    if !finite(direction) || !pressure.is_finite() {
                        return Err(format!("{what}: the pressure or its direction is not finite"));
                    }
                    if norm2(*direction) == 0.0 {
                        return Err(format!("{what}: the pressure's direction is zero"));
                    }
                    if *pressure != 0.0 && projected_area(grid, region, unit(*direction)) <= 0.0 {
                        return Err(format!("{what}: the pressure's region has no area across its direction inside the design space"));
                    }
                }
            }
        }
    }
    Ok(())
}

/// The area of `region` seen along the unit `direction`, mm²: a box (clipped to the grid) shows
/// its three face areas weighted by the direction's components, a cylinder its end discs and its
/// side, a sphere its great circle.
pub fn projected_area(grid: &Grid, region: &Region, direction: [f64; 3]) -> f64 {
    let d = direction;
    match region.hull() {
        Region::Tube { .. } => unreachable!("a hull is never a tube"),
        Region::Box { min, max } => {
            let l: [f64; 3] = std::array::from_fn(|a| {
                let hi = grid.origin[a] + grid.n[a] as f64 * grid.h;
                (max[a].min(hi) - min[a].max(grid.origin[a])).max(0.0)
            });
            d[0].abs() * l[1] * l[2] + d[1].abs() * l[0] * l[2] + d[2].abs() * l[0] * l[1]
        }
        Region::Cylinder { axis, radius, length, .. } => {
            let (r, len) = (radius.max(0.0), length.max(0.0));
            let cos = dot(unit(axis), d).abs().min(1.0);
            let sin = (1.0 - cos * cos).max(0.0).sqrt();
            PI * r * r * cos + 2.0 * r * len * sin
        }
        Region::Sphere { radius, .. } => PI * radius.max(0.0).powi(2),
    }
}

/// The couple of `moment` (N·mm) about the unit `axis` carried by `nodes`: per node a force
/// tangential about the axis, in proportion to the node's distance from it, so that the forces'
/// moment about the axis is exactly `moment`. The axis runs through `center`, shifted across to the
/// nodes' centroid when they are not balanced about it, which keeps the net force zero (a balanced
/// set, a bore centred on the axis, gets `F_i = M r_i / Σ r_j²` and nodes on the axis get nothing).
/// `None` when the nodes cannot carry a couple about the axis.
fn couple(grid: &Grid, nodes: &[usize], center: [f64; 3], axis: [f64; 3], moment: f64) -> Option<Vec<[f64; 3]>> {
    let a = unit(axis);
    if norm2(a) == 0.0 || nodes.is_empty() {
        return None;
    }
    let radial: Vec<[f64; 3]> = nodes
        .iter()
        .map(|&v| {
            let d = sub(grid.node_position(v), center);
            let t = dot(d, a);
            [d[0] - t * a[0], d[1] - t * a[1], d[2] - t * a[2]]
        })
        .collect();
    let count = nodes.len() as f64;
    let mean = radial.iter().fold([0.0; 3], |s, r| [s[0] + r[0], s[1] + r[1], s[2] + r[2]]).map(|x| x / count);
    let offsets: Vec<[f64; 3]> = radial.iter().map(|r| sub(*r, mean)).collect();
    let polar: f64 = offsets.iter().map(|e| norm2(*e)).sum();
    if !(polar > 1e-18 * grid.h * grid.h * count) || !moment.is_finite() {
        return None;
    }
    let k = moment / polar;
    Some(offsets.iter().map(|e| cross(a, *e).map(|x| x * k)).collect())
}

/// Adds `force` shared evenly by `nodes`.
fn spread(f: &mut [f64], nodes: &[usize], force: [f64; 3]) {
    if nodes.is_empty() {
        return;
    }
    let share = force.map(|x| x / nodes.len() as f64);
    for &v in nodes {
        for a in 0..3 {
            f[3 * v + a] += share[a];
        }
    }
}

fn region_ok(region: &Region) -> Result<(), String> {
    match region.hull() {
        Region::Tube { .. } => unreachable!("a hull is never a tube"),
        Region::Box { min, max } => {
            if !finite(&min) || !finite(&max) {
                return Err("the box's corners are not finite".into());
            }
            if (0..3).any(|a| min[a] > max[a]) {
                return Err("the box's min corner is beyond its max corner".into());
            }
        }
        Region::Cylinder { base, axis, radius, length } => {
            if !finite(&base) || !finite(&axis) || !radius.is_finite() || !length.is_finite() {
                return Err("the cylinder's numbers are not finite".into());
            }
            if norm2(axis) == 0.0 {
                return Err("the cylinder's axis is zero".into());
            }
            if radius < 0.0 || length < 0.0 {
                return Err("the cylinder's radius and length must not be negative".into());
            }
        }
        Region::Sphere { center, radius } => {
            if !finite(&center) || !radius.is_finite() || radius < 0.0 {
                return Err("the sphere's centre and radius must be finite, the radius not negative".into());
            }
        }
    }
    Ok(())
}

fn finite(v: &[f64]) -> bool {
    v.iter().all(|x| x.is_finite())
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn norm2(a: [f64; 3]) -> f64 {
    dot(a, a)
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn case(loads: Vec<Load>, acceleration: Option<[f64; 3]>) -> LoadCase {
        LoadCase { name: "test".into(), loads, acceleration, weight: 1.0 }
    }

    fn total(f: &[f64]) -> [f64; 3] {
        let mut s = [0.0; 3];
        for (d, x) in f.iter().enumerate() {
            s[d % 3] += x;
        }
        s
    }

    /// The moment of the nodal forces about `point`.
    fn moment(grid: &Grid, f: &[f64], point: [f64; 3]) -> [f64; 3] {
        let mut m = [0.0; 3];
        for v in 0..grid.nodes() {
            let r = sub(grid.node_position(v), point);
            let c = cross(r, [f[3 * v], f[3 * v + 1], f[3 * v + 2]]);
            for a in 0..3 {
                m[a] += c[a];
            }
        }
        m
    }

    fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol * (1.0 + b.abs())
    }

    #[test]
    fn supports_hold_their_axes() {
        let g = Grid::new([0.0; 3], [4.0, 2.0, 2.0], 1.0);
        let face = Region::Box { min: [0.0; 3], max: [0.0, 2.0, 2.0] };
        let fixed = fixed_dofs(&g, &[Support { region: face, fix: [true, false, true] }]);
        assert_eq!(fixed.len(), g.dofs());
        assert_eq!(fixed.iter().filter(|&&f| f).count(), 9 * 2);
        for v in 0..g.nodes() {
            let on = g.node_ijk(v)[0] == 0;
            assert_eq!([fixed[3 * v], fixed[3 * v + 1], fixed[3 * v + 2]], [on, false, on]);
        }
    }

    #[test]
    fn forces_sum_to_the_load() {
        let g = Grid::new([0.0; 3], [10.0, 4.0, 4.0], 1.0);
        let end = Region::Box { min: [10.0, 0.0, 0.0], max: [10.0, 4.0, 4.0] };
        let point = Region::Sphere { center: [30.0, 30.0, 30.0], radius: 0.1 };
        let f = applied(
            &g,
            &case(vec![Load::Force { region: end, force: [1.0, -250.0, 3.5] }, Load::Force { region: point, force: [0.0, 0.0, 7.0] }], None),
        );
        let s = total(&f);
        assert!(close(s[0], 1.0, 1e-14) && close(s[1], -250.0, 1e-14) && close(s[2], 10.5, 1e-14), "{s:?}");
        // The region outside the grid lands on the nearest node, the far corner.
        assert_eq!(f[3 * g.nodes() - 1], 7.0 + 3.5 / 25.0);
        // Moment of the end load about the origin: the force at the end face's centre.
        let m = moment(&g, &applied(&g, &case(vec![Load::Force { region: end, force: [0.0, -250.0, 0.0] }], None)), [0.0; 3]);
        assert!(close(m[2], -2500.0, 1e-14) && close(m[0], 500.0, 1e-14), "{m:?}");
    }

    #[test]
    fn a_load_on_a_keep_in_stays_on_it() {
        let g = Grid::new([0.0; 3], [10.0, 4.0, 4.0], 1.0);
        let end = Region::Box { min: [8.0, 0.0, 0.0], max: [10.0, 4.0, 4.0] };
        // Only the nodes at x = 10 belong to the keep-in.
        let solid: Vec<bool> = (0..g.nodes()).map(|v| v % (g.n[0] + 1) == g.n[0]).collect();
        let f = applied_preferring(&g, &case(vec![Load::Force { region: end, force: [0.0, -100.0, 0.0] }], None), Some(&solid), None);
        assert!(close(total(&f)[1], -100.0, 1e-12));
        for v in 0..g.nodes() {
            assert!(solid[v] || f[3 * v + 1] == 0.0, "node {v} off the keep-in is loaded");
        }
    }

    #[test]
    fn torque_is_a_pure_couple() {
        // A bore of radius 3 along z through the middle of a 12 × 12 × 4 block.
        let g = Grid::new([0.0; 3], [12.0, 12.0, 4.0], 0.5);
        let center = [6.0, 6.0, 0.0];
        let bore = Region::Cylinder { base: center, axis: [0.0, 0.0, 1.0], radius: 3.0, length: 4.0 };
        let m0 = 1.5e4;
        let f = applied(&g, &case(vec![Load::Torque { region: bore, center, axis: [0.0, 0.0, 2.0], moment: m0 }], None));
        let s = total(&f);
        assert!(s.iter().all(|x| x.abs() < 1e-9 * m0), "net force {s:?}");
        let m = moment(&g, &f, center);
        assert!(close(m[2], m0, 1e-13) && m[0].abs() < 1e-9 * m0 && m[1].abs() < 1e-9 * m0, "{m:?}");
        // Balanced about the axis: F_i = M r_i / Σ r², tangential, nothing on the axis.
        let nodes = g.nodes_in(&bore);
        let r2: f64 = nodes.iter().map(|&v| sub(g.node_position(v), center)).map(|d| d[0] * d[0] + d[1] * d[1]).sum();
        for &v in &nodes {
            let d = sub(g.node_position(v), center);
            let r = (d[0] * d[0] + d[1] * d[1]).sqrt();
            let fv = [f[3 * v], f[3 * v + 1], f[3 * v + 2]];
            assert!(close(norm2(fv).sqrt(), m0 * r / r2, 1e-12) && fv[2] == 0.0);
            assert!((fv[0] * d[0] + fv[1] * d[1]).abs() < 1e-9);
        }
        // Off the axis and unbalanced (a pad to one side, a tilted axis): still a pure couple.
        let pad = Region::Box { min: [8.0, 1.0, 0.0], max: [11.0, 5.0, 2.0] };
        let axis = unit([0.2, -0.1, 1.0]);
        let f = applied(&g, &case(vec![Load::Torque { region: pad, center, axis, moment: -800.0 }], None));
        let s = total(&f);
        assert!(s.iter().all(|x| x.abs() < 1e-9), "net force {s:?}");
        for p in [center, [0.0; 3], [40.0, -3.0, 9.0]] {
            assert!(close(dot(moment(&g, &f, p), axis), -800.0, 1e-12));
        }
        // A single node cannot carry a couple.
        let lone = Region::Sphere { center: [-50.0, 0.0, 0.0], radius: 0.0 };
        assert!(applied(&g, &case(vec![Load::Torque { region: lone, center, axis, moment: 1.0 }], None)).iter().all(|&x| x == 0.0));
        let held = [Support { region: Region::Box { min: [0.0; 3], max: [0.0, 12.0, 4.0] }, fix: [true; 3] }];
        let bad = case(vec![Load::Torque { region: lone, center, axis, moment: 1.0 }], None);
        assert!(check(&g, &held, &[bad]).unwrap_err().contains("cannot carry a moment"));
    }

    #[test]
    fn pressure_pushes_the_projected_area() {
        let g = Grid::new([0.0; 3], [20.0, 10.0, 10.0], 1.0);
        let pi = PI;
        let cases = [
            // The top face (a slab sticking out of the grid is clipped to it): 20 × 10.
            (Region::Box { min: [-5.0, 0.0, 10.0], max: [20.0, 10.0, 12.0] }, [0.0, 0.0, -1.0], 200.0),
            // A box seen obliquely: the three faces weighted by the direction's components.
            (Region::Box { min: [2.0, 2.0, 2.0], max: [6.0, 5.0, 7.0] }, [1.0, 2.0, 2.0], (15.0 + 2.0 * 20.0 + 2.0 * 12.0) / 3.0),
            // A cylinder pushed across its axis: diameter × length; along it: the end disc.
            (Region::Cylinder { base: [5.0, 5.0, 2.0], axis: [0.0, 0.0, 1.0], radius: 2.0, length: 6.0 }, [1.0, 0.0, 0.0], 24.0),
            (Region::Cylinder { base: [5.0, 5.0, 2.0], axis: [0.0, 0.0, 1.0], radius: 2.0, length: 6.0 }, [0.0, 0.0, 3.0], 4.0 * pi),
            (Region::Sphere { center: [10.0, 5.0, 5.0], radius: 3.0 }, [0.0, 1.0, 0.0], 9.0 * pi),
        ];
        for (region, direction, area) in cases {
            let p = 0.75;
            let f = applied(&g, &case(vec![Load::Pressure { region, direction, pressure: p }], None));
            let s = total(&f);
            let d = unit(direction);
            for a in 0..3 {
                assert!(close(s[a], p * area * d[a], 1e-13), "{region:?}: {s:?} against {}", p * area);
            }
        }
    }

    #[test]
    fn body_force_is_mass_times_acceleration() {
        let g = Grid::new([0.0; 3], [7.0, 5.0, 3.0], 0.5);
        // Densities varying per element (aluminium scaled, t/mm³), so the lumping is checked.
        let rho: Vec<f64> = (0..g.elements()).map(|e| 2.7e-9 * (0.2 + (e % 7) as f64 / 7.0)).collect();
        let acc = [100.0, 0.0, -9810.0];
        let f = body(&g, &case(Vec::new(), Some(acc)), &rho).unwrap();
        let mass: f64 = rho.iter().sum::<f64>() * g.h.powi(3);
        let s = total(&f);
        for a in 0..3 {
            assert!(close(s[a], mass * acc[a], 1e-12), "{s:?}");
        }
        // The resultant acts at the centre of mass: compare the moments about the origin.
        let mut cm = [0.0; 3];
        for (e, &r) in rho.iter().enumerate() {
            let c = g.element_center(e);
            for a in 0..3 {
                cm[a] += r * g.h.powi(3) * c[a] / mass;
            }
        }
        let m = moment(&g, &f, [0.0; 3]);
        let expect = cross(cm, acc.map(|x| x * mass));
        for a in 0..3 {
            assert!(close(m[a], expect[a], 1e-12), "{m:?} against {expect:?}");
        }
        assert!(body(&g, &case(Vec::new(), None), &rho).is_none());
        // A short density list weighs only what it holds, without panicking.
        let short = body(&g, &case(Vec::new(), Some(acc)), &rho[..10]).unwrap();
        assert!(close(total(&short)[2], rho[..10].iter().sum::<f64>() * g.h.powi(3) * acc[2], 1e-12));
    }

    #[test]
    fn check_reports_bad_input() {
        let g = Grid::new([0.0; 3], [10.0, 4.0, 4.0], 1.0);
        let held = [Support { region: Region::Box { min: [0.0; 3], max: [0.0, 4.0, 4.0] }, fix: [true; 3] }];
        let end = Region::Box { min: [10.0, 0.0, 0.0], max: [10.0, 4.0, 4.0] };
        let good = case(vec![Load::Force { region: end, force: [0.0, 0.0, -10.0] }], Some([0.0, 0.0, -9810.0]));
        assert!(check(&g, &held, std::slice::from_ref(&good)).is_ok());
        assert!(check(&g, &[], std::slice::from_ref(&good)).is_err());
        let free = [Support { fix: [false; 3], ..held[0].clone() }];
        assert!(check(&g, &free, std::slice::from_ref(&good)).is_err());
        let nan = case(vec![Load::Force { region: end, force: [f64::NAN, 0.0, 0.0] }], None);
        assert!(check(&g, &held, &[nan]).is_err());
        let zero = case(vec![Load::Pressure { region: end, direction: [0.0; 3], pressure: 1.0 }], None);
        assert!(check(&g, &held, &[zero]).is_err());
        let inverted = case(vec![Load::Force { region: Region::Box { min: [1.0; 3], max: [0.0; 3] }, force: [1.0; 3] }], None);
        assert!(check(&g, &held, &[inverted]).is_err());
        let outside = case(vec![Load::Pressure { region: Region::Box { min: [20.0; 3], max: [30.0; 3] }, direction: [1.0, 0.0, 0.0], pressure: 1.0 }], None);
        assert!(check(&g, &held, &[outside]).is_err());
        let accel = case(Vec::new(), Some([0.0, f64::INFINITY, 0.0]));
        assert!(check(&g, &held, &[accel]).is_err());
    }
}
