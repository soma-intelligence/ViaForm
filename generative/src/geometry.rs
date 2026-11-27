//! From a solved shape to geometry: outlines for previews, rectangles and beams for the CAD body.

use std::collections::HashMap;

use crate::spec::{Shape, Spec};

/// Density above which an element counts as solid.
pub const THRESHOLD: f64 = 0.5;

/// Closed outlines of the solid, domain coordinates. Each outline's last point joins its first
/// (the first point is not repeated). Outer boundaries run anticlockwise, holes clockwise.
///
/// Density: marching squares at [`THRESHOLD`] over the node-averaged densities, the field
/// padded with empty elements so every contour closes at the domain's border. Frame: each
/// beam's rectangle (overlaps are not merged).
pub fn outlines(shape: &Shape, spec: &Spec) -> Vec<Vec<[f64; 2]>> {
    let _ = spec;
    match shape {
        Shape::Density { nx, ny, cell, values } => contours(*nx, *ny, *cell, values),
        Shape::Frame { nodes, beams } => beams
            .iter()
            .filter_map(|b| {
                let (a, c) = (nodes.get(b.a)?, nodes.get(b.b)?);
                let (dx, dy) = (c[0] - a[0], c[1] - a[1]);
                let len = dx.hypot(dy);
                if !(len > 0.0 && b.width > 0.0) {
                    return None;
                }
                // Half the width, square to the beam (to its left).
                let (px, py) = (-dy / len * b.width / 2.0, dx / len * b.width / 2.0);
                Some(vec![[a[0] - px, a[1] - py], [c[0] - px, c[1] - py], [c[0] + px, c[1] + py], [a[0] + px, a[1] + py]])
            })
            .collect(),
    }
}

/// Solid area, mm². Density: the solid elements' area. Frame: each beam's length times width,
/// overlaps at the joints ignored.
pub fn solid_area(shape: &Shape, spec: &Spec) -> f64 {
    let _ = spec;
    match shape {
        Shape::Density { cell, values, .. } => values.iter().filter(|v| **v >= THRESHOLD).count() as f64 * cell * cell,
        Shape::Frame { nodes, beams } => beams
            .iter()
            .filter_map(|b| {
                let (a, c) = (nodes.get(b.a)?, nodes.get(b.b)?);
                Some((c[0] - a[0]).hypot(c[1] - a[1]) * b.width.max(0.0))
            })
            .sum(),
    }
}

/// Axis-aligned rectangles `[min_x, min_y, max_x, max_y]` covering the solid elements of a
/// density shape, merged greedily so a body needs few of them. Empty for frames.
///
/// Each row's solid runs are found; a run carries on the rectangle above it while the same run
/// repeats row after row. The rectangles cover exactly the solid elements and never overlap.
pub fn rects(shape: &Shape) -> Vec<[f64; 4]> {
    let Shape::Density { nx, ny, cell, values } = shape else { return Vec::new() };
    let (nx, ny, c) = (*nx, *ny, *cell);
    let solid = |i: usize, j: usize| values.get(j * nx + i).is_some_and(|v| *v >= THRESHOLD);
    let mut out = Vec::new();
    // Open rectangles: (first column, column past the last, first row).
    let mut open: Vec<(usize, usize, usize)> = Vec::new();
    let close = |(i0, i1, j0): (usize, usize, usize), j1: usize| [i0 as f64 * c, j0 as f64 * c, i1 as f64 * c, j1 as f64 * c];
    for j in 0..ny {
        let mut runs = Vec::new();
        let mut i = 0;
        while i < nx {
            if solid(i, j) {
                let start = i;
                while i < nx && solid(i, j) {
                    i += 1;
                }
                runs.push((start, i));
            } else {
                i += 1;
            }
        }
        let mut next = Vec::with_capacity(runs.len());
        for (i0, i1) in runs {
            match open.iter().position(|o| o.0 == i0 && o.1 == i1) {
                Some(k) => next.push(open.swap_remove(k)),
                None => next.push((i0, i1, j)),
            }
        }
        out.extend(open.drain(..).map(|o| close(o, j)));
        open = next;
    }
    out.extend(open.into_iter().map(|o| close(o, ny)));
    out
}

/// Marching squares over the node-averaged densities of an `nx` by `ny` grid of `cell` elements.
fn contours(nx: usize, ny: usize, cell: f64, values: &[f64]) -> Vec<Vec<[f64; 2]>> {
    if nx == 0 || ny == 0 || cell.is_nan() || cell <= 0.0 {
        return Vec::new();
    }
    // Element density, empty outside the domain.
    let rho = |i: isize, j: isize| -> f64 {
        if i < 0 || j < 0 || i >= nx as isize || j >= ny as isize {
            return 0.0;
        }
        values.get(j as usize * nx + i as usize).copied().filter(|v| v.is_finite()).unwrap_or(0.0)
    };
    // Nodes 0..=nx+2 along X: node p sits at (p - 1) * cell, the outer ring is a pad of zeros so
    // the contour closes at the border.
    let (gx, gy) = (nx + 3, ny + 3);
    let mut node = vec![0.0; gx * gy];
    for q in 1..gy - 1 {
        for p in 1..gx - 1 {
            let (i, j) = (p as isize - 1, q as isize - 1);
            node[q * gx + p] = (rho(i - 1, j - 1) + rho(i, j - 1) + rho(i - 1, j) + rho(i, j)) / 4.0;
        }
    }
    let at = |p: usize, q: usize| node[q * gx + p];
    let inside = |p: usize, q: usize| at(p, q) >= THRESHOLD;
    let pos = |p: usize, q: usize| [(p as f64 - 1.0) * cell, (q as f64 - 1.0) * cell];
    // Where the contour crosses the edge between two nodes.
    let cross = |a: (usize, usize), b: (usize, usize)| -> [f64; 2] {
        let (va, vb) = (at(a.0, a.1), at(b.0, b.1));
        let t = if (vb - va).abs() > 1e-12 { ((THRESHOLD - va) / (vb - va)).clamp(0.0, 1.0) } else { 0.5 };
        let (pa, pb) = (pos(a.0, a.1), pos(b.0, b.1));
        [pa[0] + (pb[0] - pa[0]) * t, pa[1] + (pb[1] - pa[1]) * t]
    };
    // Edge keys: horizontal edge from node (p, q) to (p + 1, q) is even, vertical to (p, q + 1) odd.
    let h = |p: usize, q: usize| 2 * (q * gx + p);
    let v = |p: usize, q: usize| 2 * (q * gx + p) + 1;
    // Segments with the solid on their left, keyed by the edge they start on: (end edge, start point).
    let mut next: HashMap<usize, (usize, [f64; 2])> = HashMap::new();
    for q in 0..gy - 1 {
        for p in 0..gx - 1 {
            // Corners and edges anticlockwise from the bottom left; edge k runs corner k to k + 1.
            let corners = [(p, q), (p + 1, q), (p + 1, q + 1), (p, q + 1)];
            let edges = [h(p, q), v(p + 1, q), h(p, q + 1), v(p, q)];
            let ins = corners.map(|(a, b)| inside(a, b));
            // Crossings in anticlockwise order: (edge index, leaving the solid).
            let crossings: Vec<(usize, bool)> = (0..4).filter(|&k| ins[k] != ins[(k + 1) % 4]).map(|k| (k, ins[k])).collect();
            if crossings.is_empty() {
                continue;
            }
            let n = crossings.len();
            // A saddle joins its solid corners when the cell's centre is solid.
            let joined = n == 4 && corners.iter().map(|&(a, b)| at(a, b)).sum::<f64>() / 4.0 >= THRESHOLD;
            for (idx, &(k, exit)) in crossings.iter().enumerate() {
                if !exit {
                    continue;
                }
                // From where the contour leaves the solid to where it enters it: the next entry
                // anticlockwise, or the previous one for a saddle split in two.
                let to = if n == 4 && !joined { crossings[(idx + n - 1) % n].0 } else { crossings[(idx + 1) % n].0 };
                let (a, b) = (corners[k], corners[(k + 1) % 4]);
                next.insert(edges[k], (edges[to], cross(a, b)));
            }
        }
    }
    // Stitch: follow each segment to the one starting where it ends.
    let mut starts: Vec<usize> = next.keys().copied().collect();
    starts.sort_unstable();
    let mut out = Vec::new();
    for start in starts {
        let mut loop_pts = Vec::new();
        let mut edge = start;
        while let Some((to, point)) = next.remove(&edge) {
            loop_pts.push(point);
            edge = to;
        }
        let loop_pts = simplify(loop_pts, cell * 1e-9);
        if loop_pts.len() >= 3 {
            out.push(loop_pts);
        }
    }
    out
}

/// Drops repeated points and points in line with their neighbours from a closed polyline.
fn simplify(mut pts: Vec<[f64; 2]>, eps: f64) -> Vec<[f64; 2]> {
    loop {
        let n = pts.len();
        if n < 3 {
            return pts;
        }
        let keep: Vec<bool> = (0..n)
            .map(|k| {
                let (a, b, c) = (pts[(k + n - 1) % n], pts[k], pts[(k + 1) % n]);
                let same = (b[0] - a[0]).abs() <= eps && (b[1] - a[1]).abs() <= eps;
                let cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
                // In line and going on the same way (a spike back is kept, so a thin sliver survives).
                let ahead = (b[0] - a[0]) * (c[0] - b[0]) + (b[1] - a[1]) * (c[1] - b[1]) >= 0.0;
                !(same || (cross.abs() <= eps * eps.max(1.0) && ahead))
            })
            .collect();
        if keep.iter().all(|k| *k) {
            return pts;
        }
        // Remove one point at a time per run so two neighbours are never dropped together.
        let mut dropped = vec![false; n];
        for k in 0..n {
            if !keep[k] && !dropped[(k + n - 1) % n] {
                dropped[k] = true;
            }
        }
        pts = pts.into_iter().zip(dropped).filter(|(_, d)| !d).map(|(p, _)| p).collect();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::Beam;

    /// A density shape from rows of `#` (solid) and `.` (empty), the first row at the top.
    fn grid(rows: &[&str], cell: f64) -> Shape {
        let ny = rows.len();
        let nx = rows[0].len();
        let mut values = vec![0.0; nx * ny];
        for (r, row) in rows.iter().enumerate() {
            let j = ny - 1 - r;
            for (i, ch) in row.chars().enumerate() {
                values[j * nx + i] = if ch == '#' { 1.0 } else { 0.0 };
            }
        }
        Shape::Density { nx, ny, cell, values }
    }

    fn signed_area(o: &[[f64; 2]]) -> f64 {
        (0..o.len()).map(|k| {
            let (a, b) = (o[k], o[(k + 1) % o.len()]);
            a[0] * b[1] - b[0] * a[1]
        })
        .sum::<f64>()
            / 2.0
    }

    const SHAPES: &[&[&str]] = &[
        &["####", "#..#", "####"],
        &["#.....", "#.....", "######"],
        &["#.#.#", ".#.#.", "#.#.#"],
        &["..##..", ".####.", "######", "#....#", "######"],
        &["......"],
        &["#"],
    ];

    #[test]
    fn rects_cover_exactly_the_solid_cells() {
        for rows in SHAPES {
            let shape = grid(rows, 2.0);
            let Shape::Density { nx, ny, cell, values } = &shape else { unreachable!() };
            let mut cover = vec![0; nx * ny];
            for r in rects(&shape) {
                let (i0, j0, i1, j1) = ((r[0] / cell) as usize, (r[1] / cell) as usize, (r[2] / cell) as usize, (r[3] / cell) as usize);
                assert!(i0 < i1 && j0 < j1, "{rows:?}: empty rectangle {r:?}");
                for j in j0..j1 {
                    for i in i0..i1 {
                        cover[j * nx + i] += 1;
                    }
                }
            }
            for (k, v) in values.iter().enumerate() {
                assert_eq!(cover[k], usize::from(*v >= THRESHOLD), "{rows:?}: element {k}");
            }
        }
    }

    #[test]
    fn rects_merge_runs_down_rows() {
        // A solid block is one rectangle; an L is two.
        assert_eq!(rects(&grid(&["###", "###"], 1.0)), vec![[0.0, 0.0, 3.0, 2.0]]);
        assert_eq!(rects(&grid(&["#..", "#..", "###"], 1.0)).len(), 2);
        assert!(rects(&Shape::Frame { nodes: vec![[0.0, 0.0]], beams: vec![] }).is_empty());
    }

    #[test]
    fn area_counts_solid_elements_and_beams() {
        let spec = Spec::default();
        assert_eq!(solid_area(&grid(&["##.", "#.."], 2.0), &spec), 12.0);
        let frame = Shape::Frame { nodes: vec![[0.0, 0.0], [30.0, 40.0]], beams: vec![Beam { a: 0, b: 1, width: 2.0 }] };
        assert!((solid_area(&frame, &spec) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn outlines_close_and_enclose_the_solid() {
        let spec = Spec::default();
        // A full block: one anticlockwise loop on the border, its corners cut by a cell's chamfer.
        let block = outlines(&grid(&["#####", "#####", "#####"], 2.0), &spec);
        assert_eq!(block.len(), 1);
        let a = signed_area(&block[0]);
        assert!((a - (10.0 * 6.0 - 2.0 * 4.0)).abs() < 1e-9, "{a}");
        assert_eq!(block[0].len(), 8, "{:?}", block[0]);
        for p in &block[0] {
            assert!((0.0..=10.0).contains(&p[0]) && (0.0..=6.0).contains(&p[1]), "{p:?} outside the domain");
        }
        // A ring: an outer loop and a clockwise hole (a lone empty element is below the
        // node-averaged field's resolution, so the hole is two by two).
        let ring = outlines(&grid(&["######", "######", "##..##", "##..##", "######", "######"], 1.0), &spec);
        assert_eq!(ring.len(), 2, "{ring:?}");
        let mut areas: Vec<f64> = ring.iter().map(|o| signed_area(o)).collect();
        areas.sort_by(f64::total_cmp);
        assert!(areas[0] < 0.0 && areas[1] > 0.0, "{areas:?}");
        // Every loop is closed: no point repeats and neighbours differ.
        for rows in SHAPES {
            for o in outlines(&grid(rows, 1.0), &spec) {
                assert!(o.len() >= 3);
                for k in 0..o.len() {
                    assert_ne!(o[k], o[(k + 1) % o.len()], "{rows:?}");
                }
                assert!(signed_area(&o).abs() > 0.0);
            }
        }
        assert!(outlines(&grid(&["....."], 1.0), &spec).is_empty());
    }

    #[test]
    fn frame_outlines_are_beam_rectangles() {
        let frame = Shape::Frame {
            nodes: vec![[0.0, 0.0], [10.0, 0.0], [0.0, 5.0]],
            beams: vec![Beam { a: 0, b: 1, width: 2.0 }, Beam { a: 1, b: 2, width: 0.0 }],
        };
        let o = outlines(&frame, &Spec::default());
        assert_eq!(o, vec![vec![[0.0, -1.0], [10.0, -1.0], [10.0, 1.0], [0.0, 1.0]]]);
        assert!((signed_area(&o[0]) - 20.0).abs() < 1e-9);
    }
}
