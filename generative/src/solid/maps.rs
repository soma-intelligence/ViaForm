//! Per-vertex maps of a candidate's surface for a canvas to paint (VIAFORM-SPEC 7.10.3): the
//! overhang angle against the build plate (additive processes), the wall thickness, and whether
//! the milling tool reaches the surface. Each comes from the same computation as the matching
//! mesh check ([`super::checks`]), run on every triangle instead of a sample, then spread to the
//! vertices by area so the map shades smoothly.
//!
//! A vertex reads NaN where nothing was measured (no wall ray came back) or the map does not
//! apply to the process. Units: degrees, mm, and a 0 to 1 share for the tool access.

use std::time::Instant;

use serde::{Deserialize, Serialize};

use super::Mesh;
use super::checks::{self, CheckRequest, OverhangFaces, TriGrid, Tris};

/// Which maps to compute (each costs a pass over the surface; the wall and the tool access
/// cast a ray per triangle).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Wanted {
    pub overhang: bool,
    pub wall: bool,
    pub access: bool,
}

impl Wanted {
    pub const ALL: Wanted = Wanted { overhang: true, wall: true, access: true };
}

/// Most triangles a map casts rays from; a larger surface is sampled evenly and the vertices
/// between take their neighbours' values.
pub const MAX_RAYS: usize = 400_000;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct OverhangSummary {
    /// The process builds in layers, so the map applies.
    pub applies: bool,
    /// The steepest overhang allowed, degrees from the plate.
    pub limit_deg: f64,
    /// The build direction, unit.
    pub build: [f64; 3],
    /// Surface that needs support, mm², and its share of the whole.
    pub flagged_mm2: f64,
    pub flagged_share: f64,
    /// The flattest face looking down off the plate, degrees (null when none looks down).
    pub flattest_deg: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WallSummary {
    /// The thinnest wall allowed, mm (null for a free shape with no minimum asked).
    pub limit_mm: Option<f64>,
    /// The wall 99 % of the measured surface reaches (as the check reads it: knife edges left
    /// out), the thinnest single triangle, the thickest, and the median by area, mm.
    pub min_mm: Option<f64>,
    pub thinnest_mm: Option<f64>,
    pub max_mm: Option<f64>,
    pub median_mm: Option<f64>,
    /// Share of the measured area thinner than the limit.
    pub thin_share: f64,
    /// Share of the surface (by area) a ray came back from.
    pub measured_share: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct AccessSummary {
    /// The process is machined, so the map applies.
    pub applies: bool,
    /// The reach model in words.
    pub model: String,
    /// The tool axes, unit, from the part toward the tool.
    pub axes: Vec<[f64; 3]>,
    pub tolerance_deg: f64,
    /// Surface out of the tool's reach, mm², and its share of the whole.
    pub unreachable_mm2: f64,
    pub unreachable_share: f64,
}

/// The maps' figures, for a legend.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MapSummary {
    pub vertices: usize,
    pub triangles: usize,
    /// Triangles rays were cast from.
    pub rays: usize,
    pub overhang: Option<OverhangSummary>,
    pub wall: Option<WallSummary>,
    pub access: Option<AccessSummary>,
    pub seconds: f64,
}

/// Per-vertex values (empty when not asked for), and the figures.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshMaps {
    /// Angle from the build plate, degrees: under the limit needs support; 90 looks up, sideways
    /// or rests on the plate. NaN for every vertex when the process is not layered.
    pub overhang_deg: Vec<f32>,
    /// Wall thickness, mm; NaN where no ray came back.
    pub wall_mm: Vec<f32>,
    /// Share of the surrounding surface the tool reaches, 0 to 1; NaN for every vertex when the
    /// process is not machined.
    pub access: Vec<f32>,
    pub summary: MapSummary,
}

/// The reach model, as the legend says it.
pub const ACCESS_MODEL: &str = "Line of sight along each tool axis (3-axis from the top by default): a face is reached when it does not turn away from the tool and a straight line from it along the axis leaves the part; faces resting on the table count as the stock's base. The cutter's width and holder are not modelled.";

/// Computes the maps `want` asks for on `mesh`, held to `req` (the same request as the checks).
pub fn maps(mesh: &Mesh, req: &CheckRequest, want: Wanted) -> MeshMaps {
    let t0 = Instant::now();
    let nv = mesh.positions.len() / 3;
    let tris = Tris::new(mesh);
    let nt = tris.len();
    let total: f64 = tris.area.iter().sum();
    let grid = (nt > 0 && (want.wall || want.access)).then(|| TriGrid::new(&tris));
    let picks = tris.sample(MAX_RAYS);
    let mut out = MeshMaps { summary: MapSummary { vertices: nv, triangles: nt, ..Default::default() }, ..Default::default() };
    let share = |a: f64| if total > 0.0 { a / total } else { 0.0 };

    if want.overhang {
        let applies = req.layered();
        let mut s = OverhangSummary { applies, limit_deg: req.overhang.clamp(0.1, 90.0), build: req.build_unit(), ..Default::default() };
        if applies && nt > 0 {
            let faces: OverhangFaces = checks::overhang_faces(&tris, req);
            let angle: Vec<f64> = (0..nt).map(|t| faces.angle(t)).collect();
            s.flagged_mm2 = (0..nt).filter(|&t| faces.flagged(t)).map(|t| tris.area[t]).sum();
            s.flagged_share = share(s.flagged_mm2);
            s.flattest_deg = (0..nt).filter(|&t| faces.down[t] > 0.0 && !faces.on_plate[t]).map(|t| angle[t]).min_by(f64::total_cmp);
            out.overhang_deg = to_vertices(nv, &tris, &angle);
        } else {
            out.overhang_deg = vec![f32::NAN; nv];
        }
        out.summary.overhang = Some(s);
    }

    if want.wall {
        let limit = req.min_wall.filter(|w| w.is_finite() && *w > 0.0).or_else(|| req.process_min_wall());
        let mut s = WallSummary { limit_mm: limit, ..Default::default() };
        let mut per = vec![f64::NAN; nt];
        if let Some(g) = &grid {
            for (t, w) in checks::wall_hits(&tris, g, &picks) {
                if let Some(w) = w {
                    per[t] = w;
                }
            }
            let mut got: Vec<(f64, f64)> = (0..nt).filter(|&t| per[t].is_finite()).map(|t| (per[t], tris.area[t])).collect();
            got.sort_by(|a, b| a.0.total_cmp(&b.0));
            let measured: f64 = got.iter().map(|g| g.1).sum();
            let sampled: f64 = picks.iter().map(|&t| tris.area[t]).sum();
            let quantile = |q: f64| {
                let mut seen = 0.0;
                got.iter()
                    .find(|g| {
                        seen += g.1;
                        seen > q * measured
                    })
                    .map(|g| g.0)
            };
            s.min_mm = quantile(0.01);
            s.thinnest_mm = got.first().map(|g| g.0);
            s.max_mm = got.last().map(|g| g.0);
            s.median_mm = quantile(0.5);
            let thin: f64 = got.iter().filter(|g| limit.is_some_and(|l| g.0 < l)).map(|g| g.1).sum();
            s.thin_share = if measured > 0.0 { thin / measured } else { 0.0 };
            s.measured_share = if sampled > 0.0 { measured / sampled } else { 0.0 };
            out.summary.rays = picks.len();
        }
        out.wall_mm = to_vertices(nv, &tris, &per);
        fill_gaps(&mut out.wall_mm, &tris, 3);
        out.summary.wall = Some(s);
    }

    if want.access {
        let applies = req.machined();
        let axes = req.tool_axes_unit();
        let mut s = AccessSummary { applies, model: ACCESS_MODEL.into(), axes: axes.clone(), tolerance_deg: req.undercut_tolerance, ..Default::default() };
        match (&grid, applies) {
            (Some(g), true) => {
                let faces = checks::access_faces(&tris, g, &axes, req.undercut_tolerance, req.plate_tolerance, &picks);
                let per: Vec<f64> = faces.iter().map(|f| f.map_or(f64::NAN, |r| if r { 1.0 } else { 0.0 })).collect();
                let sampled: f64 = (0..nt).filter(|&t| faces[t].is_some()).map(|t| tris.area[t]).sum();
                let hidden: f64 = (0..nt).filter(|&t| faces[t] == Some(false)).map(|t| tris.area[t]).sum();
                s.unreachable_share = if sampled > 0.0 { hidden / sampled } else { 0.0 };
                s.unreachable_mm2 = s.unreachable_share * total;
                out.summary.rays = picks.len();
                out.access = to_vertices(nv, &tris, &per);
            }
            _ => out.access = vec![f32::NAN; nv],
        }
        out.summary.access = Some(s);
    }
    out.summary.seconds = t0.elapsed().as_secs_f64();
    out
}

/// Spreads per-triangle values to the vertices, weighted by area; NaN values are left out, and a
/// vertex with none around it reads NaN.
fn to_vertices(nv: usize, tris: &Tris, per: &[f64]) -> Vec<f32> {
    let mut sum = vec![0.0f64; nv];
    let mut weight = vec![0.0f64; nv];
    for (t, v) in tris.verts.iter().enumerate() {
        let x = per[t];
        if !x.is_finite() {
            continue;
        }
        let w = tris.area[t].max(1e-12);
        for &i in v {
            sum[i as usize] += w * x;
            weight[i as usize] += w;
        }
    }
    sum.iter().zip(&weight).map(|(s, w)| if *w > 0.0 { (s / w) as f32 } else { f32::NAN }).collect()
}

/// Gives a vertex with no value the mean of its measured neighbours, `passes` rings deep: a ray
/// that misses on a fold of the surface leaves a speck, not a hole in the map. Vertices farther
/// from any measurement stay NaN.
fn fill_gaps(values: &mut [f32], tris: &Tris, passes: usize) {
    for _ in 0..passes {
        let mut sum = vec![0.0f64; values.len()];
        let mut count = vec![0u32; values.len()];
        for v in &tris.verts {
            for a in 0..3 {
                let (i, j) = (v[a] as usize, v[(a + 1) % 3] as usize);
                if values[i].is_nan() && values[j].is_finite() {
                    sum[i] += f64::from(values[j]);
                    count[i] += 1;
                }
                if values[j].is_nan() && values[i].is_finite() {
                    sum[j] += f64::from(values[i]);
                    count[j] += 1;
                }
            }
        }
        let mut filled = false;
        for (k, v) in values.iter_mut().enumerate() {
            if v.is_nan() && count[k] > 0 {
                *v = (sum[k] / f64::from(count[k])) as f32;
                filled = true;
            }
        }
        if !filled {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Outward box, as in the checks' tests.
    fn cuboid(lo: [f64; 3], hi: [f64; 3], mesh: &mut Mesh) {
        let base = (mesh.positions.len() / 3) as u32;
        for k in 0..8 {
            let p = [if k & 1 == 0 { lo[0] } else { hi[0] }, if k & 2 == 0 { lo[1] } else { hi[1] }, if k & 4 == 0 { lo[2] } else { hi[2] }];
            mesh.positions.extend(p.map(|x| x as f32));
        }
        let faces: [[u32; 4]; 6] = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]];
        for f in faces {
            mesh.indices.extend([f[0], f[1], f[2], f[0], f[2], f[3]].map(|i| base + i));
        }
    }

    /// A post on the plate carrying a slab: a T standing up.
    fn tee() -> Mesh {
        let mut m = Mesh::default();
        cuboid([0.0, 0.0, 0.0], [4.0, 4.0, 10.0], &mut m);
        cuboid([-10.0, -10.0, 10.0], [14.0, 14.0, 12.0], &mut m);
        m
    }

    #[test]
    fn overhang_map_flags_the_slab_underside_only_for_printing() {
        let m = tee();
        let fdm = maps(&m, &CheckRequest { process: "fdm".into(), ..Default::default() }, Wanted { overhang: true, ..Default::default() });
        let s = fdm.summary.overhang.as_ref().unwrap();
        assert!(s.applies);
        // The same area as the check counts.
        let check = checks::check(&m, &CheckRequest { process: "fdm".into(), ..Default::default() });
        assert!((s.flagged_mm2 - check.overhang_mm2).abs() < 1e-9, "{} {}", s.flagged_mm2, check.overhang_mm2);
        assert_eq!(s.flattest_deg, Some(0.0));
        assert_eq!(fdm.overhang_deg.len(), 16);
        // The slab's lower corners touch only its underside (0 degrees) and its sides (90):
        // under the limit. The post's corners on the plate read 90 (the plate holds them).
        let slab_low = 8; // (-10, -10, 10)
        assert!(fdm.overhang_deg[slab_low] < 45.0, "{}", fdm.overhang_deg[slab_low]);
        assert!((fdm.overhang_deg[0] - 90.0).abs() < 1e-4, "{}", fdm.overhang_deg[0]);
        assert!(fdm.wall_mm.is_empty() && fdm.access.is_empty());
        // Milling has no overhang map: every vertex NaN, and the summary says so.
        let mill = maps(&m, &CheckRequest { process: "milling".into(), ..Default::default() }, Wanted { overhang: true, ..Default::default() });
        assert!(!mill.summary.overhang.as_ref().unwrap().applies);
        assert!(mill.overhang_deg.iter().all(|v| v.is_nan()));
    }

    #[test]
    fn wall_map_reads_the_thickness_at_every_vertex() {
        let mut m = Mesh::default();
        cuboid([0.0; 3], [30.0, 30.0, 0.6], &mut m);
        let r = maps(&m, &CheckRequest { process: "fdm".into(), ..Default::default() }, Wanted { wall: true, ..Default::default() });
        let s = r.summary.wall.as_ref().unwrap();
        assert_eq!(s.limit_mm, Some(0.8));
        assert!((s.min_mm.unwrap() - 0.6).abs() < 1e-6 && (s.thinnest_mm.unwrap() - 0.6).abs() < 1e-6);
        assert!(s.thin_share > 0.5 && s.measured_share > 0.99, "{s:?}");
        assert_eq!(r.wall_mm.len(), 8);
        // Every corner joins a broad face (0.6 mm through) and narrow sides (30 mm across): the
        // broad face's area holds the value down.
        assert!(r.wall_mm.iter().all(|w| w.is_finite() && *w < 4.0), "{:?}", r.wall_mm);
        assert_eq!(r.summary.rays, 12);
    }

    #[test]
    fn tool_access_from_the_top_misses_the_slab_underside() {
        let m = tee();
        let mill = CheckRequest { process: "milling".into(), ..Default::default() };
        let r = maps(&m, &mill, Wanted { access: true, ..Default::default() });
        let s = r.summary.access.as_ref().unwrap();
        assert!(s.applies && s.model.contains("3-axis"));
        assert_eq!(s.axes, vec![[0.0, 0.0, 1.0]]);
        // Hidden from the top: the slab's underside (faces down), the post's top and sides
        // (under the slab). The post's foot rests on the table.
        let hidden = 24.0 * 24.0 + 16.0 + 4.0 * 40.0;
        let total = 2.0 * (16.0 + 40.0 + 40.0) + 2.0 * (576.0 + 48.0 + 48.0);
        assert!((s.unreachable_share - hidden / total).abs() < 1e-9, "{}", s.unreachable_share);
        // The slab's top corners are reached, its lower corners are not wholly.
        assert!((r.access[12] - 1.0).abs() < 1e-6, "{}", r.access[12]);
        assert!(r.access[8] < 1.0);
        // The check agrees.
        let c = checks::check(&m, &mill);
        let t = c.checks.iter().find(|c| c.id == "tool_access").unwrap();
        assert_eq!(t.status, checks::Status::Warning);
        assert!((c.unreachable_share - s.unreachable_share).abs() < 1e-9);
        // A second setup from below reaches the undersides; the covered post top stays hidden.
        let two = CheckRequest { tool_axes: Some(vec![[0.0, 0.0, 1.0], [0.0, 0.0, -2.0]]), ..mill.clone() };
        let r2 = maps(&m, &two, Wanted { access: true, ..Default::default() });
        let s2 = r2.summary.access.unwrap();
        assert!((s2.unreachable_share - 16.0 / total).abs() < 1e-9, "{}", s2.unreachable_share);
        // Printing has no tool map.
        let fdm = maps(&m, &CheckRequest { process: "fdm".into(), ..Default::default() }, Wanted { access: true, ..Default::default() });
        assert!(!fdm.summary.access.unwrap().applies && fdm.access.iter().all(|v| v.is_nan()));
    }

    #[test]
    fn an_empty_surface_gives_empty_maps() {
        let r = maps(&Mesh::default(), &CheckRequest { process: "milling".into(), ..Default::default() }, Wanted::ALL);
        assert!(r.overhang_deg.is_empty() && r.wall_mm.is_empty() && r.access.is_empty());
        assert_eq!(r.summary.triangles, 0);
        assert!(r.summary.wall.unwrap().min_mm.is_none());
    }

    /// A surfaced ball printed: maps for every vertex, its lower half under the overhang limit,
    /// walls about its diameter.
    #[test]
    fn a_generated_surface_maps_every_vertex() {
        let grid = super::super::Grid::new([0.0; 3], [20.0; 3], 1.0);
        let density: Vec<f32> = (0..grid.elements())
            .map(|e| {
                let c = grid.element_center(e);
                let r = ((c[0] - 10.0).powi(2) + (c[1] - 10.0).powi(2) + (c[2] - 10.0).powi(2)).sqrt();
                if r < 7.0 { 1.0 } else { 0.0 }
            })
            .collect();
        let m = super::super::iso::surface(&grid, &density, 0.5, 4);
        let r = maps(&m, &CheckRequest { process: "fdm".into(), ..Default::default() }, Wanted::ALL);
        let nv = m.positions.len() / 3;
        assert_eq!(r.overhang_deg.len(), nv);
        assert!(r.overhang_deg.iter().all(|v| v.is_finite()));
        assert!(r.overhang_deg.iter().any(|v| *v < 45.0) && r.overhang_deg.iter().any(|v| *v >= 89.9));
        let w = r.summary.wall.as_ref().unwrap();
        assert!(w.median_mm.unwrap() > 10.0, "{w:?}");
        assert!(r.wall_mm.iter().filter(|v| v.is_finite()).count() > nv * 9 / 10);
        assert!(r.access.iter().all(|v| v.is_nan()));
        assert!(r.summary.seconds < 2.0);
    }

    #[test]
    fn a_missed_ray_is_filled_from_its_neighbours() {
        let mut m = Mesh::default();
        cuboid([0.0; 3], [10.0; 3], &mut m);
        let tris = Tris::new(&m);
        let mut v = vec![2.0f32; 8];
        v[3] = f32::NAN;
        fill_gaps(&mut v, &tris, 3);
        assert!((v[3] - 2.0).abs() < 1e-6, "{v:?}");
        // Nothing measured: nothing to fill from.
        let mut none = vec![f32::NAN; 8];
        fill_gaps(&mut none, &tris, 3);
        assert!(none.iter().all(|x| x.is_nan()));
    }
}
