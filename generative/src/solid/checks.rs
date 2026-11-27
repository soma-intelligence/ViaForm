//! Mesh checks on a candidate's surface before it is made (VIAFORM-SPEC 7.10.3, MESH CHECKS):
//! watertight, manifold, bodies, thinnest wall against the process minimum, overhangs along the
//! build direction (additive), tool access from the allowed tool axes (milling), enclosed voids
//! and the triangle count. Each check answers pass,
//! warning, fail or skipped, with its figure, the limit it was held to, a sentence, and where
//! the worst spot is so a front end can frame it.
//!
//! All of it is cheap next to a run: edge counting is a sort, the wall thickness casts one ray
//! inward from a sample of triangles through a uniform grid of the triangles (Amanatides and Woo
//! 1987 traversal, Moller and Trumbore 1997 intersection). The same pieces give the per-vertex
//! maps a canvas paints ([`super::maps`]). Units: mm, mm², degrees.

use std::time::Instant;

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use super::{Mesh, iso};

/// What the surface is checked against.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CheckRequest {
    /// How the part is made: `free`, `additive` (or `fdm`), `sls`, `resin`, `milling` (or
    /// `cnc`), `extrusion`. Sets the minimum wall and which checks apply.
    pub process: String,
    /// Build direction for additive processes (any length), default +z.
    pub build: Option<[f64; 3]>,
    /// Steepest overhang allowed, degrees from the build plate.
    pub overhang: f64,
    /// Thinnest wall allowed, mm; default the process minimum (none for `free`).
    pub min_wall: Option<f64>,
    /// Separate bodies allowed.
    pub max_bodies: usize,
    /// Faces within this of the lowest point along the build direction sit on the plate (for
    /// milling: on the table, along each tool axis), mm.
    pub plate_tolerance: f64,
    /// Triangles sampled for the wall thickness and the tool access (all of them when fewer).
    pub samples: usize,
    /// Directions the tool may come from for milling (any length; from the part toward the
    /// tool); default the build direction, else +z: a 3-axis machine cutting from the top.
    pub tool_axes: Option<Vec<[f64; 3]>>,
    /// A face tilted away from the tool by up to this much is still cut (smoothed voxel walls
    /// lean a little), degrees.
    pub undercut_tolerance: f64,
}

impl Default for CheckRequest {
    fn default() -> Self {
        Self { process: "free".into(), build: None, overhang: 45.0, min_wall: None, max_bodies: 1, plate_tolerance: 0.5, samples: 20_000, tool_axes: None, undercut_tolerance: 2.0 }
    }
}

impl CheckRequest {
    /// The process's own thinnest wall, mm, or none for a free shape.
    pub fn process_min_wall(&self) -> Option<f64> {
        match self.process.to_ascii_lowercase().as_str() {
            "additive" | "fdm" => Some(0.8),
            "sls" => Some(0.7),
            "resin" | "sla" => Some(0.5),
            "milling" | "cnc" | "cnc3" => Some(1.0),
            "extrusion" | "plate" => Some(1.0),
            _ => None,
        }
    }

    /// True for processes built layer on layer along `build`, where overhangs need support.
    pub fn layered(&self) -> bool {
        matches!(self.process.to_ascii_lowercase().as_str(), "additive" | "fdm" | "resin" | "sla")
    }

    /// True for machining, where a face must be in reach of the tool.
    pub fn machined(&self) -> bool {
        matches!(self.process.to_ascii_lowercase().as_str(), "milling" | "cnc" | "cnc3")
    }

    /// The build direction as a unit vector, +z when unset or degenerate.
    pub fn build_unit(&self) -> [f64; 3] {
        let b = self.build.unwrap_or([0.0, 0.0, 1.0]);
        let l = norm(b);
        if l > 0.0 && l.is_finite() { scale(b, 1.0 / l) } else { [0.0, 0.0, 1.0] }
    }

    /// The tool axes as unit vectors: those asked for, else the build direction (+z).
    pub fn tool_axes_unit(&self) -> Vec<[f64; 3]> {
        let axes: Vec<V> = self
            .tool_axes
            .iter()
            .flatten()
            .filter_map(|a| {
                let l = norm(*a);
                (l > 0.0 && l.is_finite()).then(|| scale(*a, 1.0 / l))
            })
            .collect();
        if axes.is_empty() { vec![self.build_unit()] } else { axes }
    }

    /// True for powder or resin processes, where a closed void traps material.
    pub fn traps(&self) -> bool {
        matches!(self.process.to_ascii_lowercase().as_str(), "sls" | "resin" | "sla" | "milling" | "cnc" | "cnc3")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pass,
    Warning,
    Fail,
    /// Does not apply to this process.
    Skipped,
}

/// A box around a problem, mm.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Spot {
    pub min: [f64; 3],
    pub max: [f64; 3],
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Check {
    /// `watertight`, `manifold`, `bodies`, `min_wall`, `overhangs`, `voids`, `triangles`.
    pub id: String,
    pub name: String,
    pub status: Status,
    /// The figure checked, in `unit` (null when it could not be measured).
    pub value: Option<f64>,
    pub limit: Option<f64>,
    pub unit: String,
    /// One sentence a person reads.
    pub detail: String,
    /// Where the worst of it is, to frame in the canvas.
    pub spot: Option<Spot>,
}

/// Every check on one surface, plus its figures.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MeshChecks {
    pub checks: Vec<Check>,
    pub triangles: usize,
    pub vertices: usize,
    pub area_mm2: f64,
    pub volume_mm3: f64,
    /// Edges on one triangle only, and on three or more.
    pub open_edges: usize,
    pub nonmanifold_edges: usize,
    pub bodies: usize,
    pub voids: usize,
    /// The wall thickness 99 % of the sampled surface reaches, mm (null: no ray came back).
    pub min_wall_mm: Option<f64>,
    /// The thinnest single sample, mm (a knife edge can read far under the wall).
    pub thinnest_sample_mm: Option<f64>,
    /// Share of the surface (by area) thinner than the wall limit.
    pub thin_share: f64,
    /// Wall samples cast.
    pub wall_samples: usize,
    pub overhang_mm2: f64,
    pub overhang_share: f64,
    /// Surface the tool cannot reach (milling only), mm², and its share of the sampled area.
    pub unreachable_mm2: f64,
    pub unreachable_share: f64,
    /// No check failed or warned.
    pub passed: bool,
    pub warnings: usize,
    pub failures: usize,
    pub seconds: f64,
}

/// Share of the surface allowed to overhang before the check warns (smoothing leaves a little).
pub const OVERHANG_SHARE: f64 = 0.02;
/// Share of the surface allowed out of the tool's reach before the check warns.
pub const UNREACHABLE_SHARE: f64 = 0.01;
/// Triangles over which the file is heavy for a slicer or a CAD import.
pub const HEAVY_TRIANGLES: usize = 3_000_000;

/// Runs every check on `mesh`.
pub fn check(mesh: &Mesh, req: &CheckRequest) -> MeshChecks {
    let t0 = Instant::now();
    let tris = Tris::new(mesh);
    let nt = tris.len();
    let (open, nonmanifold, open_at) = edge_counts(mesh);
    let closed = nt > 0 && iso::is_closed(mesh);
    let manifold = closed && iso::is_manifold(mesh);
    let (bodies, voids, void_spot) = shells(mesh, &tris);
    let wall_limit = req.min_wall.filter(|w| w.is_finite() && *w > 0.0).or_else(|| req.process_min_wall());
    let grid = (nt > 0).then(|| TriGrid::new(&tris));
    let picks = tris.sample(req.samples.max(1));
    let wall = match &grid {
        Some(g) => wall_thickness(&tris, &wall_hits(&tris, g, &picks), wall_limit),
        None => Wall { min: None, absolute: None, thin_share: 0.0, samples: 0 },
    };
    let overhang = if req.layered() { Some(overhangs(&tris, &overhang_faces(&tris, req))) } else { None };
    let access = match &grid {
        Some(g) if req.machined() => Some(unreachable(&tris, &access_faces(&tris, g, &req.tool_axes_unit(), req.undercut_tolerance, req.plate_tolerance, &picks))),
        _ => None,
    };
    let area = tris.area.iter().sum::<f64>();
    let mut checks = Vec::with_capacity(8);

    checks.push(Check {
        id: "watertight".into(),
        name: "Watertight".into(),
        status: if nt == 0 { Status::Fail } else if closed { Status::Pass } else { Status::Fail },
        value: Some(open as f64),
        limit: Some(0.0),
        unit: "open edges".into(),
        detail: if nt == 0 {
            "The surface has no triangles.".into()
        } else if closed {
            "Every edge joins two triangles: the surface is closed.".into()
        } else if open > 0 {
            format!("{open} edges border a hole: the surface is not closed.")
        } else {
            "Some edges run the same way on both triangles: the surface is not closed.".into()
        },
        spot: open_at.map(|p| around(p, 2.0)),
    });
    checks.push(Check {
        id: "manifold".into(),
        name: "Manifold".into(),
        status: if manifold { Status::Pass } else { Status::Fail },
        value: Some(nonmanifold as f64),
        limit: Some(0.0),
        unit: "shared edges".into(),
        detail: if manifold {
            "Each edge and corner belongs to one sheet of surface.".into()
        } else if nonmanifold > 0 {
            format!("{nonmanifold} edges are shared by three or more triangles.")
        } else if !closed {
            "Not checked further: the surface is open.".into()
        } else {
            "Two sheets of surface touch at a corner.".into()
        },
        spot: None,
    });
    let max_bodies = req.max_bodies.max(1);
    checks.push(Check {
        id: "bodies".into(),
        name: "Bodies".into(),
        status: if bodies == 0 { Status::Fail } else if bodies <= max_bodies { Status::Pass } else { Status::Warning },
        value: Some(bodies as f64),
        limit: Some(max_bodies as f64),
        unit: "bodies".into(),
        detail: match bodies {
            0 => "No closed body encloses material.".into(),
            1 => "One solid piece.".into(),
            n if n <= max_bodies => format!("{n} separate pieces, as the study allows."),
            n => format!("{n} separate pieces where the study allows {max_bodies}."),
        },
        spot: None,
    });
    checks.push(match (wall.min, wall_limit) {
        (None, _) => Check {
            id: "min_wall".into(),
            name: "Thinnest wall".into(),
            status: Status::Skipped,
            value: None,
            limit: wall_limit,
            unit: "mm".into(),
            detail: "No wall could be measured: the surface is open or empty.".into(),
            spot: None,
        },
        (Some((w, at)), Some(limit)) => Check {
            id: "min_wall".into(),
            name: "Thinnest wall".into(),
            status: if w + 1e-9 >= limit { Status::Pass } else { Status::Warning },
            // `w` leaves out the thinnest 1 % of the surface (knife edges); the share says how
            // much is under the limit.
            value: Some(w),
            limit: Some(limit),
            unit: "mm".into(),
            detail: if w + 1e-9 >= limit {
                format!("Walls are at least {limit:.1} mm, the process minimum, over 99 % of the surface.")
            } else {
                format!("{:.1} % of the surface is thinner than {limit:.1} mm.", 100.0 * wall.thin_share)
            },
            spot: Some(around(at, w.max(1.0) * 2.0)),
        },
        (Some((w, at)), None) => Check {
            id: "min_wall".into(),
            name: "Thinnest wall".into(),
            status: Status::Pass,
            value: Some(w),
            limit: None,
            unit: "mm".into(),
            detail: "No process minimum: pick a process to hold the walls to one.".into(),
            spot: Some(around(at, w.max(1.0) * 2.0)),
        },
    });
    checks.push(match overhang {
        None => Check {
            id: "overhangs".into(),
            name: "Overhangs".into(),
            status: Status::Skipped,
            value: None,
            limit: None,
            unit: "mm²".into(),
            detail: "Only checked for printed parts (a build direction).".into(),
            spot: None,
        },
        Some(o) => {
            let share = if area > 0.0 { o.area / area } else { 0.0 };
            Check {
                id: "overhangs".into(),
                name: "Overhangs".into(),
                status: if share <= OVERHANG_SHARE { Status::Pass } else { Status::Warning },
                value: Some(o.area),
                limit: Some(OVERHANG_SHARE * area),
                unit: "mm²".into(),
                detail: if o.area <= 0.0 {
                    format!("No face is flatter than {:.0}° from the build plate.", req.overhang)
                } else {
                    format!("{:.1} % of the surface is flatter than {:.0}° facing down and needs support.", 100.0 * share, req.overhang)
                },
                spot: o.spot,
            }
        }
    });
    checks.push(match access {
        None => Check {
            id: "tool_access".into(),
            name: "Tool access".into(),
            status: Status::Skipped,
            value: None,
            limit: None,
            unit: "mm²".into(),
            detail: "Only checked for milled parts (a tool axis).".into(),
            spot: None,
        },
        Some(a) => Check {
            id: "tool_access".into(),
            name: "Tool access".into(),
            status: if a.share <= UNREACHABLE_SHARE { Status::Pass } else { Status::Warning },
            value: Some(a.area),
            limit: Some(UNREACHABLE_SHARE * a.sampled),
            unit: "mm²".into(),
            detail: if a.area <= 0.0 {
                "The tool reaches every face from above.".into()
            } else {
                format!("{:.1} % of the surface is hidden from the tool: an undercut or a covered pocket.", 100.0 * a.share)
            },
            spot: a.spot,
        },
    });
    checks.push(Check {
        id: "voids".into(),
        name: "Voids".into(),
        status: if voids == 0 { Status::Pass } else { Status::Warning },
        value: Some(voids as f64),
        limit: Some(0.0),
        unit: "voids".into(),
        detail: match (voids, req.traps()) {
            (0, _) => "No closed cavity inside the part.".into(),
            (n, true) => format!("{n} closed cavities trap powder or resin, or hide from the tool."),
            (n, false) => format!("{n} closed cavities inside the part."),
        },
        spot: void_spot,
    });
    checks.push(Check {
        id: "triangles".into(),
        name: "Triangles".into(),
        status: if nt <= HEAVY_TRIANGLES { Status::Pass } else { Status::Warning },
        value: Some(nt as f64),
        limit: Some(HEAVY_TRIANGLES as f64),
        unit: "triangles".into(),
        detail: if nt <= HEAVY_TRIANGLES {
            format!("{nt} triangles, light enough for a slicer or CAD import.")
        } else {
            format!("{nt} triangles: heavy for a slicer or CAD import.")
        },
        spot: None,
    });

    let warnings = checks.iter().filter(|c| c.status == Status::Warning).count();
    let failures = checks.iter().filter(|c| c.status == Status::Fail).count();
    MeshChecks {
        passed: warnings == 0 && failures == 0,
        warnings,
        failures,
        triangles: nt,
        vertices: mesh.positions.len() / 3,
        area_mm2: area,
        volume_mm3: iso::volume(mesh),
        open_edges: open,
        nonmanifold_edges: nonmanifold,
        bodies,
        voids,
        min_wall_mm: wall.min.map(|w| w.0),
        thinnest_sample_mm: wall.absolute,
        thin_share: wall.thin_share,
        wall_samples: wall.samples,
        overhang_mm2: overhang.map_or(0.0, |o| o.area),
        overhang_share: overhang.map_or(0.0, |o| if area > 0.0 { o.area / area } else { 0.0 }),
        unreachable_mm2: access.map_or(0.0, |a| a.area),
        unreachable_share: access.map_or(0.0, |a| a.share),
        checks,
        seconds: t0.elapsed().as_secs_f64(),
    }
}

// MARK: geometry

pub(super) type V = [f64; 3];

fn sub(a: V, b: V) -> V {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn add(a: V, b: V) -> V {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn scale(a: V, s: f64) -> V {
    [a[0] * s, a[1] * s, a[2] * s]
}
fn dot(a: V, b: V) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: V, b: V) -> V {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
fn norm(a: V) -> f64 {
    dot(a, a).sqrt()
}

fn around(p: V, r: f64) -> Spot {
    Spot { min: [p[0] - r, p[1] - r, p[2] - r], max: [p[0] + r, p[1] + r, p[2] + r] }
}

/// The triangles that name three distinct existing vertices, with their corners, unit normals
/// and areas.
pub(super) struct Tris {
    pub(super) corners: Vec<[V; 3]>,
    pub(super) normal: Vec<V>,
    pub(super) area: Vec<f64>,
    /// Index into the mesh's triangles.
    pub(super) source: Vec<usize>,
    /// The mesh's vertex indices of each corner.
    pub(super) verts: Vec<[u32; 3]>,
}

impl Tris {
    pub(super) fn new(mesh: &Mesh) -> Self {
        let p = &mesh.positions;
        let nv = p.len() / 3;
        let at = |i: u32| -> Option<V> {
            let i = i as usize;
            (i < nv).then(|| [p[3 * i] as f64, p[3 * i + 1] as f64, p[3 * i + 2] as f64])
        };
        let rows: Vec<Option<([V; 3], V, f64, usize, [u32; 3])>> = mesh
            .indices
            .par_chunks_exact(3)
            .enumerate()
            .map(|(k, t)| {
                if t[0] == t[1] || t[1] == t[2] || t[0] == t[2] {
                    return None;
                }
                let (a, b, c) = (at(t[0])?, at(t[1])?, at(t[2])?);
                let n = cross(sub(b, a), sub(c, a));
                let l = norm(n);
                let unit = if l > 0.0 { scale(n, 1.0 / l) } else { [0.0; 3] };
                Some(([a, b, c], unit, 0.5 * l, k, [t[0], t[1], t[2]]))
            })
            .collect();
        let mut out = Tris { corners: Vec::new(), normal: Vec::new(), area: Vec::new(), source: Vec::new(), verts: Vec::new() };
        for (c, n, a, k, v) in rows.into_iter().flatten() {
            out.verts.push(v);
            out.corners.push(c);
            out.normal.push(n);
            out.area.push(a);
            out.source.push(k);
        }
        out
    }

    pub(super) fn len(&self) -> usize {
        self.corners.len()
    }

    pub(super) fn centroid(&self, t: usize) -> V {
        let [a, b, c] = self.corners[t];
        scale(add(add(a, b), c), 1.0 / 3.0)
    }

    /// About `samples` triangles spread evenly over the list (every one when fewer), leaving out
    /// those with no area.
    pub(super) fn sample(&self, samples: usize) -> Vec<usize> {
        let step = self.len().div_ceil(samples.max(1)).max(1);
        (0..self.len()).step_by(step).filter(|&t| self.area[t] > 0.0).collect()
    }
}

/// Undirected edges used once (open) and three or more times (non-manifold), and the middle of
/// one open edge.
fn edge_counts(mesh: &Mesh) -> (usize, usize, Option<V>) {
    let nv = (mesh.positions.len() / 3) as u32;
    let mut edges: Vec<u64> = mesh
        .indices
        .par_chunks_exact(3)
        .filter(|t| t.iter().all(|&i| i < nv) && t[0] != t[1] && t[1] != t[2] && t[0] != t[2])
        .flat_map_iter(|t| {
            (0..3).map(move |r| {
                let (a, b) = (t[r], t[(r + 1) % 3]);
                (u64::from(a.min(b)) << 32) | u64::from(a.max(b))
            })
        })
        .collect();
    edges.par_sort_unstable();
    let (mut open, mut many, mut first_open) = (0usize, 0usize, None);
    let mut i = 0;
    while i < edges.len() {
        let mut j = i + 1;
        while j < edges.len() && edges[j] == edges[i] {
            j += 1;
        }
        match j - i {
            1 => {
                open += 1;
                if first_open.is_none() {
                    let (a, b) = ((edges[i] >> 32) as usize, (edges[i] & 0xffff_ffff) as usize);
                    let p = &mesh.positions;
                    first_open = Some([0, 1, 2].map(|k| 0.5 * (p[3 * a + k] as f64 + p[3 * b + k] as f64)));
                }
            }
            2 => {}
            _ => many += 1,
        }
        i = j;
    }
    (open, many, first_open)
}

/// Connected shells: those enclosing material (positive volume) are bodies, those with negative
/// volume are cavities inside a body. Also a box around the largest cavity.
fn shells(mesh: &Mesh, tris: &Tris) -> (usize, usize, Option<Spot>) {
    let nv = mesh.positions.len() / 3;
    if tris.len() == 0 || nv == 0 {
        return (0, 0, None);
    }
    let mut parent: Vec<u32> = (0..nv as u32).collect();
    fn find(parent: &mut [u32], mut x: u32) -> u32 {
        while parent[x as usize] != x {
            let up = parent[parent[x as usize] as usize];
            parent[x as usize] = up;
            x = up;
        }
        x
    }
    let idx = &mesh.indices;
    for &k in &tris.source {
        let t = &idx[3 * k..3 * k + 3];
        let r0 = find(&mut parent, t[0]);
        for &b in &t[1..] {
            let rb = find(&mut parent, b);
            if rb != r0 {
                parent[rb.max(r0) as usize] = rb.min(r0);
            }
        }
    }
    // Signed volume and bounds per shell, about the first corner (precision far from the origin).
    let o = tris.corners[0][0];
    let mut acc: std::collections::HashMap<u32, (f64, V, V)> = Default::default();
    for (t, &k) in tris.source.iter().enumerate() {
        let r = find(&mut parent, idx[3 * k]);
        let [a, b, c] = tris.corners[t];
        let v = dot(sub(a, o), cross(sub(b, o), sub(c, o))) / 6.0;
        let e = acc.entry(r).or_insert((0.0, [f64::INFINITY; 3], [f64::NEG_INFINITY; 3]));
        e.0 += v;
        for q in [a, b, c] {
            for ax in 0..3 {
                e.1[ax] = e.1[ax].min(q[ax]);
                e.2[ax] = e.2[ax].max(q[ax]);
            }
        }
    }
    let bodies = acc.values().filter(|s| s.0 > 0.0).count();
    let cavities: Vec<&(f64, V, V)> = acc.values().filter(|s| s.0 < 0.0).collect();
    let spot = cavities.iter().min_by(|a, b| a.0.total_cmp(&b.0)).map(|s| Spot { min: s.1, max: s.2 });
    (bodies, cavities.len(), spot)
}

struct Wall {
    /// The wall thickness 99 % of the sampled surface (by area) reaches, and where a wall that
    /// thin starts: knife edges a voxel surface leaves where two voxels touch at an edge read as
    /// hair-thin walls over a sliver of area, so the thinnest 1 % is set aside.
    min: Option<(f64, V)>,
    /// The thinnest sample of all, mm.
    absolute: Option<f64>,
    /// Area share of the sampled triangles thinner than the limit.
    thin_share: f64,
    samples: usize,
}

/// Casts one ray inward from the centre of each picked triangle and keeps the distance to the
/// first triangle that faces away along it (the far side of the wall): (triangle, thickness mm
/// or none when no ray came back).
pub(super) fn wall_hits(tris: &Tris, grid: &TriGrid, picks: &[usize]) -> Vec<(usize, Option<f64>)> {
    picks
        .par_iter()
        .map(|&t| {
            let d = scale(tris.normal[t], -1.0);
            (t, grid.first_exit(tris, tris.centroid(t), d, t))
        })
        .collect()
}

/// The wall figures from the cast rays: the thickness 99 % of the sampled area reaches, the
/// thinnest sample and the share under `limit`.
fn wall_thickness(tris: &Tris, hits: &[(usize, Option<f64>)], limit: Option<f64>) -> Wall {
    let mut got: Vec<(f64, usize)> = hits.iter().filter_map(|(t, w)| w.map(|w| (w, *t))).collect();
    got.sort_by(|a, b| a.0.total_cmp(&b.0));
    let total: f64 = got.iter().map(|(_, t)| tris.area[*t]).sum();
    let thin: f64 = got.iter().filter(|(w, _)| limit.is_some_and(|l| *w < l)).map(|(_, t)| tris.area[*t]).sum();
    // Walk up from the thinnest until 1 % of the sampled area is behind.
    let mut seen = 0.0;
    let mut min = None;
    for (w, t) in &got {
        seen += tris.area[*t];
        if seen > 0.01 * total {
            min = Some((*w, tris.centroid(*t)));
            break;
        }
    }
    Wall { min, absolute: got.first().map(|g| g.0), thin_share: if total > 0.0 { thin / total } else { 0.0 }, samples: hits.len() }
}

#[derive(Clone, Copy)]
struct Overhang {
    area: f64,
    spot: Option<Spot>,
}

/// How each triangle faces the build plate.
pub(super) struct OverhangFaces {
    /// Cosine of the angle between the face's normal and straight down (-build): above
    /// `threshold` the face looks down flatter than the allowed overhang.
    pub(super) down: Vec<f64>,
    /// Every corner within the plate tolerance of the lowest point: the plate holds it up.
    pub(super) on_plate: Vec<bool>,
    pub(super) threshold: f64,
}

impl OverhangFaces {
    /// The face needs support: it looks down flatter than the limit, off the plate.
    pub(super) fn flagged(&self, t: usize) -> bool {
        self.down[t] > self.threshold && !self.on_plate[t]
    }

    /// The face's angle from the build plate, degrees, for a face looking down off the plate
    /// (0 a flat ceiling, 90 a wall); 90 for a face that looks up or sideways or rests on the
    /// plate (it needs no support).
    pub(super) fn angle(&self, t: usize) -> f64 {
        if self.down[t] <= 0.0 || self.on_plate[t] { 90.0 } else { self.down[t].clamp(0.0, 1.0).acos().to_degrees() }
    }
}

pub(super) fn overhang_faces(tris: &Tris, req: &CheckRequest) -> OverhangFaces {
    let b = req.build_unit();
    let floor = tris.corners.par_iter().map(|c| c.iter().map(|p| dot(*p, b)).fold(f64::INFINITY, f64::min)).reduce(|| f64::INFINITY, f64::min);
    // A face looking down at `a` degrees from the plate has its normal `a` degrees from straight
    // down, so it is flatter than `overhang` when -n.b > cos(overhang).
    let threshold = req.overhang.clamp(0.1, 90.0).to_radians().cos();
    let tol = req.plate_tolerance.max(0.0);
    let down = tris.normal.iter().map(|n| -dot(*n, b)).collect();
    let on_plate = tris.corners.iter().map(|c| c.iter().all(|p| dot(*p, b) - floor <= tol)).collect();
    OverhangFaces { down, on_plate, threshold }
}

/// Faces looking down flatter than the allowed overhang, off the build plate.
fn overhangs(tris: &Tris, faces: &OverhangFaces) -> Overhang {
    let flagged: Vec<usize> = (0..tris.len()).filter(|&t| faces.flagged(t)).collect();
    let area = flagged.iter().map(|&t| tris.area[t]).sum::<f64>();
    Overhang { area, spot: bounds(tris, &flagged) }
}

/// A box around the given triangles, or none when there are none.
fn bounds(tris: &Tris, list: &[usize]) -> Option<Spot> {
    let (mut lo, mut hi) = ([f64::INFINITY; 3], [f64::NEG_INFINITY; 3]);
    for &t in list {
        for p in tris.corners[t] {
            for a in 0..3 {
                lo[a] = lo[a].min(p[a]);
                hi[a] = hi[a].max(p[a]);
            }
        }
    }
    (!list.is_empty()).then_some(Spot { min: lo, max: hi })
}

/// Whether the tool reaches each picked triangle (none for triangles not picked). The model is a
/// line of sight per tool axis, the tool's own width and holder left out: a face is reached
/// along an axis when it does not turn away from the tool by more than `tolerance` degrees and a
/// straight line from its centre along the axis leaves the part without crossing the surface. A
/// face lying on the table (within `table` mm of the part's lowest point along the axis) is the
/// stock's base and counts as reached. With one axis (the default) that is a 3-axis machine
/// cutting from the top; each further axis is another setup.
/// Sine of the angle from the tool axis under which a face counts as a wall the tool runs
/// down (20 degrees from vertical for a tool from the top).
const WALL_SIN: f64 = 0.342;

pub(super) fn access_faces(tris: &Tris, grid: &TriGrid, axes: &[V], tolerance: f64, table: f64, picks: &[usize]) -> Vec<Option<bool>> {
    let lean = -tolerance.clamp(0.0, 89.0).to_radians().sin();
    let lift = 1e-4 * grid.cell.max(1e-3);
    let floors: Vec<f64> = axes
        .iter()
        .map(|a| tris.corners.par_iter().map(|c| c.iter().map(|p| dot(*p, *a)).fold(f64::INFINITY, f64::min)).reduce(|| f64::INFINITY, f64::min))
        .collect();
    let mut out = vec![None; tris.len()];
    let hits: Vec<(usize, bool)> = picks
        .par_iter()
        .map(|&t| {
            let n = tris.normal[t];
            let o = add(tris.centroid(t), scale(n, lift));
            let reached = axes.iter().zip(&floors).any(|(a, floor)| {
                let on_table = tris.corners[t].iter().all(|p| dot(*p, *a) - floor <= table.max(0.0));
                // A ray up a wall grazes the wall's own ripples and its rounded top edge (a
                // smoothed surface is never flat). On a closed surface only material the ray goes
                // into blocks it, and that is a face turned against the ray met before any face
                // it leaves by; so for a wall, faces turned along the ray and the same wall's
                // faces do not block. A ledge above still does: it faces down, not sideways.
                let wall = dot(n, *a).abs() < WALL_SIN;
                let passes = |h: usize| {
                    let along = dot(tris.normal[h], *a);
                    wall && (along >= 0.0 || (along.abs() < WALL_SIN && dot(tris.normal[h], n) > 0.0))
                };
                on_table || (dot(n, *a) >= lean && !grid.blocked_unless(tris, o, *a, t, passes))
            });
            (t, reached)
        })
        .collect();
    for (t, r) in hits {
        out[t] = Some(r);
    }
    out
}

#[derive(Clone, Copy)]
struct Unreachable {
    area: f64,
    /// Area of the triangles looked at.
    sampled: f64,
    share: f64,
    spot: Option<Spot>,
}

fn unreachable(tris: &Tris, faces: &[Option<bool>]) -> Unreachable {
    let hidden: Vec<usize> = (0..tris.len()).filter(|&t| faces[t] == Some(false)).collect();
    let sampled: f64 = (0..tris.len()).filter(|&t| faces[t].is_some()).map(|t| tris.area[t]).sum();
    let area_seen: f64 = hidden.iter().map(|&t| tris.area[t]).sum();
    let total: f64 = tris.area.iter().sum();
    let share = if sampled > 0.0 { area_seen / sampled } else { 0.0 };
    // The sampled share stands for the whole surface.
    Unreachable { area: share * total, sampled: total, share, spot: bounds(tris, &hidden) }
}

/// The triangles bucketed into a uniform grid of cubic cells over their bounds.
pub(super) struct TriGrid {
    origin: V,
    pub(super) cell: f64,
    n: [usize; 3],
    /// Start of each cell's list in `items` (`cells + 1` entries).
    start: Vec<u32>,
    items: Vec<u32>,
}

impl TriGrid {
    pub(super) fn new(tris: &Tris) -> Self {
        let mut lo = [f64::INFINITY; 3];
        let mut hi = [f64::NEG_INFINITY; 3];
        for c in &tris.corners {
            for p in c {
                for a in 0..3 {
                    lo[a] = lo[a].min(p[a]);
                    hi[a] = hi[a].max(p[a]);
                }
            }
        }
        let size = sub(hi, lo);
        // About two triangles per cell along the surface: a cell per triangle in volume terms
        // over-fills thin parts, so size it from the area.
        let area: f64 = tris.area.iter().sum();
        let per = (area / tris.len().max(1) as f64).sqrt().max(1e-6);
        let longest = size.iter().cloned().fold(0.0, f64::max).max(1e-6);
        let cell = (per * 2.0).max(longest / 256.0);
        let n = [0, 1, 2].map(|a| ((size[a] / cell).ceil() as usize).clamp(1, 512));
        let cells = n[0] * n[1] * n[2];
        let index = |p: V| -> [usize; 3] { [0, 1, 2].map(|a| (((p[a] - lo[a]) / cell).floor().max(0.0) as usize).min(n[a] - 1)) };
        let mut count = vec![0u32; cells + 1];
        let ranges: Vec<([usize; 3], [usize; 3])> = tris
            .corners
            .iter()
            .map(|c| {
                let mut a = [f64::INFINITY; 3];
                let mut b = [f64::NEG_INFINITY; 3];
                for p in c {
                    for k in 0..3 {
                        a[k] = a[k].min(p[k]);
                        b[k] = b[k].max(p[k]);
                    }
                }
                (index(a), index(b))
            })
            .collect();
        for (a, b) in &ranges {
            for k in a[2]..=b[2] {
                for j in a[1]..=b[1] {
                    for i in a[0]..=b[0] {
                        count[i + n[0] * (j + n[1] * k) + 1] += 1;
                    }
                }
            }
        }
        for c in 0..cells {
            count[c + 1] += count[c];
        }
        let mut fill = count.clone();
        let mut items = vec![0u32; count[cells] as usize];
        for (t, (a, b)) in ranges.iter().enumerate() {
            for k in a[2]..=b[2] {
                for j in a[1]..=b[1] {
                    for i in a[0]..=b[0] {
                        let c = i + n[0] * (j + n[1] * k);
                        items[fill[c] as usize] = t as u32;
                        fill[c] += 1;
                    }
                }
            }
        }
        TriGrid { origin: lo, cell, n, start: count, items }
    }

    /// Walks the cells a ray from `o` along `d` (unit) crosses, in order (Amanatides and Woo),
    /// handing `visit` each cell's triangles and the distance at which the ray leaves that cell;
    /// stops when `visit` answers true or the ray leaves the grid.
    fn walk(&self, o: V, d: V, mut visit: impl FnMut(&[u32], f64) -> bool) {
        let mut ijk = [0i64; 3];
        let mut step = [0i64; 3];
        let mut t_max = [f64::INFINITY; 3];
        let mut t_delta = [f64::INFINITY; 3];
        for a in 0..3 {
            let x = (o[a] - self.origin[a]) / self.cell;
            let c = (x.floor() as i64).clamp(0, self.n[a] as i64 - 1);
            ijk[a] = c;
            if d[a] > 0.0 {
                step[a] = 1;
                t_max[a] = ((c + 1) as f64 * self.cell + self.origin[a] - o[a]) / d[a];
                t_delta[a] = self.cell / d[a];
            } else if d[a] < 0.0 {
                step[a] = -1;
                t_max[a] = (c as f64 * self.cell + self.origin[a] - o[a]) / d[a];
                t_delta[a] = -self.cell / d[a];
            }
        }
        loop {
            let c = ijk[0] as usize + self.n[0] * (ijk[1] as usize + self.n[1] * ijk[2] as usize);
            let exit = t_max[0].min(t_max[1]).min(t_max[2]);
            if visit(&self.items[self.start[c] as usize..self.start[c + 1] as usize], exit) {
                return;
            }
            let a = if t_max[0] <= t_max[1] && t_max[0] <= t_max[2] {
                0
            } else if t_max[1] <= t_max[2] {
                1
            } else {
                2
            };
            if step[a] == 0 {
                return;
            }
            ijk[a] += step[a];
            if ijk[a] < 0 || ijk[a] >= self.n[a] as i64 {
                return;
            }
            t_max[a] += t_delta[a];
        }
    }

    /// Distance along `d` (unit) from `o` to the nearest triangle whose normal faces along `d`,
    /// leaving out `skip` and the triangles that share a corner with it (on a smoothed voxel
    /// surface a neighbour folded past a right angle would read as a wall a hair thick); none
    /// when the ray leaves the grid first.
    pub(super) fn first_exit(&self, tris: &Tris, o: V, d: V, skip: usize) -> Option<f64> {
        let eps = 1e-7 * self.cell.max(1.0);
        let mut best = f64::INFINITY;
        self.walk(o, d, |items, exit| {
            for &t in items {
                let t = t as usize;
                // The far wall faces roughly along the ray (within 60 degrees): a grazing hit is a
                // fold of the surface, not the other side of a wall.
                if t == skip || dot(tris.normal[t], d) <= 0.5 || tris.verts[t].iter().any(|v| tris.verts[skip].contains(v)) {
                    continue;
                }
                if let Some(h) = hit(tris.corners[t], o, d)
                    && h > eps
                    && h < best
                {
                    best = h;
                }
            }
            // The nearest hit inside this cell ends the walk: later cells are farther.
            best <= exit
        });
        best.is_finite().then_some(best)
    }

    /// True when a ray from `o` along `d` (unit) crosses any triangle but `skip` before it
    /// leaves the grid: the surface stands in the way.
    pub(super) fn blocked(&self, tris: &Tris, o: V, d: V, skip: usize) -> bool {
        self.blocked_unless(tris, o, d, skip, |_| false)
    }

    /// As `blocked`, leaving out the triangles `pass` lets through.
    pub(super) fn blocked_unless(&self, tris: &Tris, o: V, d: V, skip: usize, pass: impl Fn(usize) -> bool) -> bool {
        let eps = 1e-7 * self.cell.max(1.0);
        let mut found = false;
        self.walk(o, d, |items, _| {
            found = items.iter().any(|&t| {
                let t = t as usize;
                t != skip && !pass(t) && hit(tris.corners[t], o, d).is_some_and(|h| h > eps)
            });
            found
        });
        found
    }
}

/// Ray and triangle (Moller and Trumbore), both sides: the distance along `d`, or none.
fn hit(tri: [V; 3], o: V, d: V) -> Option<f64> {
    let [a, b, c] = tri;
    let e1 = sub(b, a);
    let e2 = sub(c, a);
    let p = cross(d, e2);
    let det = dot(e1, p);
    let scale_ = dot(e1, e1).max(dot(e2, e2));
    if det.abs() <= 1e-14 * scale_ {
        return None;
    }
    let inv = 1.0 / det;
    let s = sub(o, a);
    let u = dot(s, p) * inv;
    if !(-1e-9..=1.0 + 1e-9).contains(&u) {
        return None;
    }
    let q = cross(s, e1);
    let v = dot(d, q) * inv;
    if v < -1e-9 || u + v > 1.0 + 1e-9 {
        return None;
    }
    Some(dot(e2, q) * inv)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A box as 12 outward triangles; `flip` turns them inward (a cavity).
    fn cuboid(lo: V, hi: V, flip: bool, mesh: &mut Mesh) {
        let base = (mesh.positions.len() / 3) as u32;
        for k in 0..8 {
            let p = [if k & 1 == 0 { lo[0] } else { hi[0] }, if k & 2 == 0 { lo[1] } else { hi[1] }, if k & 4 == 0 { lo[2] } else { hi[2] }];
            mesh.positions.extend(p.map(|x| x as f32));
        }
        // Outward, counter-clockwise seen from outside.
        let faces: [[u32; 4]; 6] = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]];
        for f in faces {
            let tris = [[f[0], f[1], f[2]], [f[0], f[2], f[3]]];
            for mut t in tris {
                if flip {
                    t.swap(1, 2);
                }
                mesh.indices.extend(t.map(|i| base + i));
            }
        }
    }

    fn by<'a>(c: &'a MeshChecks, id: &str) -> &'a Check {
        c.checks.iter().find(|k| k.id == id).unwrap()
    }

    fn boxed(lo: V, hi: V) -> Mesh {
        let mut m = Mesh::default();
        cuboid(lo, hi, false, &mut m);
        m
    }

    #[test]
    fn a_box_is_closed_manifold_one_body_and_as_thick_as_it_is() {
        let m = boxed([0.0; 3], [20.0, 10.0, 4.0]);
        assert!(iso::volume(&m) > 0.0, "box winding is outward");
        let c = check(&m, &CheckRequest::default());
        assert_eq!(by(&c, "watertight").status, Status::Pass);
        assert_eq!(by(&c, "manifold").status, Status::Pass);
        assert_eq!(c.bodies, 1);
        assert_eq!(c.voids, 0);
        assert_eq!(c.triangles, 12);
        // The thinnest way through is the 4 mm height.
        let w = c.min_wall_mm.unwrap();
        assert!((w - 4.0).abs() < 1e-6, "{w}");
        assert!((c.area_mm2 - 2.0 * (200.0 + 80.0 + 40.0)).abs() < 1e-6);
        assert!((c.volume_mm3 - 800.0).abs() < 1e-3);
        assert!(c.passed, "{:?}", c.checks);
        assert_eq!(by(&c, "overhangs").status, Status::Skipped);
    }

    #[test]
    fn a_thin_plate_warns_under_the_wall_limit() {
        let m = boxed([0.0; 3], [30.0, 30.0, 0.6]);
        let fdm = check(&m, &CheckRequest { process: "fdm".into(), ..Default::default() });
        let w = by(&fdm, "min_wall");
        assert_eq!(w.status, Status::Warning);
        assert_eq!(w.limit, Some(0.8));
        assert!((w.value.unwrap() - 0.6).abs() < 1e-6);
        assert!(fdm.thin_share > 0.5);
        let resin = check(&m, &CheckRequest { process: "resin".into(), ..Default::default() });
        assert_eq!(by(&resin, "min_wall").status, Status::Pass);
        let asked = check(&m, &CheckRequest { min_wall: Some(0.5), process: "fdm".into(), ..Default::default() });
        assert_eq!(by(&asked, "min_wall").status, Status::Pass);
    }

    #[test]
    fn a_hole_is_not_watertight() {
        let mut m = boxed([0.0; 3], [10.0; 3]);
        m.indices.truncate(m.indices.len() - 3);
        let c = check(&m, &CheckRequest::default());
        let w = by(&c, "watertight");
        assert_eq!(w.status, Status::Fail);
        assert_eq!(c.open_edges, 3);
        assert!(w.spot.is_some());
        assert_eq!(by(&c, "manifold").status, Status::Fail);
        assert!(!c.passed && c.failures >= 2);
    }

    #[test]
    fn a_cavity_counts_as_a_void_and_thins_the_wall() {
        let mut m = boxed([0.0; 3], [20.0; 3]);
        cuboid([3.0; 3], [17.0; 3], true, &mut m);
        let c = check(&m, &CheckRequest { process: "sls".into(), ..Default::default() });
        assert_eq!(c.bodies, 1);
        assert_eq!(c.voids, 1);
        let v = by(&c, "voids");
        assert_eq!(v.status, Status::Warning);
        assert!(v.detail.contains("trap"));
        assert!(v.spot.is_some());
        assert!((c.min_wall_mm.unwrap() - 3.0).abs() < 1e-6, "{:?}", c.min_wall_mm);
        assert!((c.volume_mm3 - (8000.0 - 2744.0)).abs() < 1e-2);
    }

    #[test]
    fn two_pieces_warn_past_the_bodies_allowed() {
        let mut m = boxed([0.0; 3], [5.0; 3]);
        cuboid([10.0, 0.0, 0.0], [15.0, 5.0, 5.0], false, &mut m);
        let one = check(&m, &CheckRequest::default());
        assert_eq!(one.bodies, 2);
        assert_eq!(by(&one, "bodies").status, Status::Warning);
        let two = check(&m, &CheckRequest { max_bodies: 2, ..Default::default() });
        assert_eq!(by(&two, "bodies").status, Status::Pass);
    }

    #[test]
    fn overhangs_follow_the_build_direction_and_skip_the_plate() {
        // A slab lifted off the plate by a post: its underside overhangs along +z.
        let mut m = boxed([0.0, 0.0, 0.0], [4.0, 4.0, 10.0]);
        cuboid([-10.0, -10.0, 10.0], [14.0, 14.0, 12.0], false, &mut m);
        let up = check(&m, &CheckRequest { process: "fdm".into(), ..Default::default() });
        let o = by(&up, "overhangs");
        assert_eq!(o.status, Status::Warning);
        // The slab's whole underside (the post's top faces up, so it never counts).
        assert!((up.overhang_mm2 - 24.0 * 24.0).abs() < 1e-6, "{}", up.overhang_mm2);
        assert!(o.spot.is_some());
        // The post alone on the plate: its bottom rests on the plate, nothing overhangs.
        let post = boxed([0.0; 3], [4.0, 4.0, 10.0]);
        let p = check(&post, &CheckRequest { process: "fdm".into(), ..Default::default() });
        assert_eq!(by(&p, "overhangs").status, Status::Pass);
        assert_eq!(p.overhang_mm2, 0.0);
        // Built along -z the slab's top rests on the plate; only the post's end, buried in the
        // slab (the two boxes are separate shells), faces down off it.
        let down = check(&m, &CheckRequest { process: "fdm".into(), build: Some([0.0, 0.0, -1.0]), ..Default::default() });
        assert_eq!(down.overhang_mm2, 16.0);
        // A steep 60 degree limit leaves a 45 degree chamfer flagged, a 30 degree one does not.
        let mut wedge = Mesh::default();
        wedge.positions = vec![0.0, 0.0, 5.0, 10.0, 0.0, 15.0, 0.0, 10.0, 5.0, 10.0, 10.0, 15.0, 0.0, 0.0, 20.0, 0.0, 10.0, 20.0];
        // Only the slanted underside matters here (not closed): normal (1, 0, -1)/sqrt 2.
        wedge.indices = vec![0, 2, 1, 1, 2, 3];
        let tris = Tris::new(&wedge);
        assert!(tris.normal[0][2] < 0.0 && tris.normal[0][0] > 0.0);
        let steep = overhangs(&tris, &overhang_faces(&tris, &CheckRequest { overhang: 60.0, plate_tolerance: 0.0, ..Default::default() }));
        let mild = overhangs(&tris, &overhang_faces(&tris, &CheckRequest { overhang: 30.0, plate_tolerance: 0.0, ..Default::default() }));
        assert!(steep.area > 0.0 && mild.area == 0.0, "{} {}", steep.area, mild.area);
    }

    #[test]
    fn tool_access_is_checked_for_milling_only() {
        // A cup open at the top (a box with a cavity reaching through its top is not closed, so
        // use a slab over a post: the slab's underside hides from a tool above).
        let mut m = boxed([0.0, 0.0, 0.0], [4.0, 4.0, 10.0]);
        cuboid([-10.0, -10.0, 10.0], [14.0, 14.0, 12.0], false, &mut m);
        let free = check(&m, &CheckRequest::default());
        assert_eq!(by(&free, "tool_access").status, Status::Skipped);
        assert_eq!(free.unreachable_mm2, 0.0);
        let mill = check(&m, &CheckRequest { process: "milling".into(), ..Default::default() });
        let a = by(&mill, "tool_access");
        assert_eq!(a.status, Status::Warning);
        assert!(a.spot.is_some() && a.detail.contains("hidden"));
        // The slab's underside, the post's top and sides: everything under the slab. The post's
        // foot rests on the table.
        assert!((mill.unreachable_mm2 - (576.0 + 16.0 + 160.0)).abs() < 1e-6, "{}", mill.unreachable_mm2);
        // A lone box on the table: its bottom is the stock's base, so all of it is reached.
        let block = check(&boxed([0.0; 3], [10.0; 3]), &CheckRequest { process: "milling".into(), ..Default::default() });
        assert_eq!(by(&block, "tool_access").status, Status::Pass);
        // A second setup from below reaches the slab's underside and the post's sides; the
        // post's top stays covered.
        let two = check(&m, &CheckRequest { process: "cnc".into(), tool_axes: Some(vec![[0.0, 0.0, 1.0], [0.0, 0.0, -1.0]]), ..Default::default() });
        assert!((two.unreachable_mm2 - 16.0).abs() < 1e-6, "{}", two.unreachable_mm2);
    }

    /// A real optimised bracket on 2 mm voxels: closed, manifold, and the wall the surface keeps
    /// is a fair share of a voxel. Smoothing folds once read as walls a hundredth of a millimetre
    /// thick; smoothing does shrink one-voxel struts to about a quarter voxel, which is real.
    #[test]
    fn an_optimised_candidate_has_no_hairline_walls() {
        let study: super::super::Study = serde_json::from_value(serde_json::json!({
            "name": "Bracket", "min": [0, 0, 0], "max": [60, 20, 24], "voxel": 2.0,
            "iterations": 20, "volume_fraction": 0.25,
            "supports": [{"region": {"shape": "box", "min": [-0.1, -1, -1], "max": [0.1, 21, 25]}}],
            "cases": [{"name": "tip", "loads": [{"type": "force", "region": {"shape": "box", "min": [59.9, -1, 10], "max": [61, 21, 14]}, "force": [0, 0, -300]}]}]
        }))
        .unwrap();
        let o = super::super::generate(&study).unwrap();
        let c = &o.candidates[o.best];
        let r = check(&c.mesh, &CheckRequest { process: "fdm".into(), ..Default::default() });
        assert_eq!(by(&r, "watertight").status, Status::Pass);
        assert_eq!(by(&r, "manifold").status, Status::Pass);
        let w = r.min_wall_mm.unwrap();
        assert!(w > 0.4, "thinnest wall {w} mm on 2 mm voxels");
    }

    #[test]
    fn a_generated_surface_passes_its_checks() {
        // A sphere surfaced from voxels: closed, manifold, one body, as thick as it is wide.
        let grid = super::super::Grid::new([0.0; 3], [20.0; 3], 1.0);
        let density: Vec<f32> = (0..grid.elements())
            .map(|e| {
                let c = grid.element_center(e);
                let r = ((c[0] - 10.0).powi(2) + (c[1] - 10.0).powi(2) + (c[2] - 10.0).powi(2)).sqrt();
                if r < 7.0 { 1.0 } else { 0.0 }
            })
            .collect();
        let m = iso::surface(&grid, &density, 0.5, 4);
        let c = check(&m, &CheckRequest { process: "fdm".into(), ..Default::default() });
        assert_eq!(by(&c, "watertight").status, Status::Pass, "{:?}", c.checks);
        assert_eq!(by(&c, "manifold").status, Status::Pass);
        assert_eq!(c.bodies, 1);
        assert_eq!(c.voids, 0);
        let w = c.min_wall_mm.unwrap();
        // Every inward ray of a ball crosses near its centre: about its 14 mm diameter.
        assert!(w > 11.0 && w < 14.6, "{w}");
        assert!(c.wall_samples > 100);
        // The lower half of a ball faces down: an overhang off the plate.
        assert!(c.overhang_share > 0.05 && c.overhang_share < 0.5, "{}", c.overhang_share);
        assert!(c.seconds < 2.0);
    }
}
