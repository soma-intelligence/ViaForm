//! Grid A* maze router for two-layer boards, with vias and rip-up and retry.
//!
//! The board is sampled on a square grid (`rules.route_grid`). For each layer the router keeps
//! two owner maps: one for fixed copper (pads, user tracks, edges, keep-outs) and one for copper
//! it laid itself. A cell holds 0 (free), a net id, or -1 (blocked for every net). An object
//! claims every cell whose centre lies closer to it than clearance plus half the track width
//! plus a margin of half a grid diagonal, so any straight move between two free neighbouring
//! cells keeps the rule. Vias use a second pair of maps inflated by the via radius instead.
//!
//! Connections are the ratsnest airwires, shortest first. When one fails, a second search may
//! cross the router's own copper at a cost; the paths it crosses are ripped up and queued again.

use crate::checks::ratsnest;
use crate::copper::{collect, Item};
use crate::error::{EngineError, Result};
use crate::geom::*;
use crate::model::*;
use std::cmp::Reverse;
use std::collections::BinaryHeap;

const DIRS: [(i64, i64); 8] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)];
const STEP: u32 = 10;
const DIAG: u32 = 14;
const TURN45: u32 = 2;
const TURN90: u32 = 6;
const VIA_COST: u32 = 120;
const RIP_COST: u32 = 400;

#[derive(Clone, Debug, PartialEq)]
pub struct RoutedPath {
    pub net: Id,
    pub tracks: Vec<(Pt, Pt, usize)>,
    pub vias: Vec<Pt>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Report {
    pub connections: usize,
    pub routed: usize,
    pub failed: Vec<String>,
    pub ripups: usize,
    pub vias: usize,
}

pub struct Options {
    pub layers: Vec<String>,
    pub width: Nm,
    pub allow_vias: bool,
    pub ripup: bool,
}

struct Grid {
    nx: usize,
    ny: usize,
    step: Nm,
    margin: Nm,
    nl: usize,
    /// [layer][cell] owners: fixed and routed, for tracks and for vias.
    fixed: Vec<Vec<i64>>,
    fixed_via: Vec<Vec<i64>>,
    routed: Vec<Vec<i64>>,
    routed_via: Vec<Vec<i64>>,
}

fn claim(cell: &mut i64, net: i64) {
    *cell = match *cell {
        0 => net,
        c if c == net => c,
        _ => -1,
    };
}

impl Grid {
    fn idx(&self, i: usize, j: usize) -> usize {
        j * self.nx + i
    }
    fn centre(&self, k: usize) -> Pt {
        Pt::new((k % self.nx) as Nm * self.step, (k / self.nx) as Nm * self.step)
    }
    fn nearest(&self, p: Pt) -> usize {
        let i = ((p.x as f64 / self.step as f64).round() as i64).clamp(0, self.nx as i64 - 1) as usize;
        let j = ((p.y as f64 / self.step as f64).round() as i64).clamp(0, self.ny as i64 - 1) as usize;
        self.idx(i, j)
    }
    /// Marks cells whose centre is within `reach` of `prim` (by gap) as owned by `net`.
    fn stamp(map: &mut [i64], g: (usize, usize, Nm), prim: &Prim, reach: Nm, net: i64) {
        let (nx, ny, step) = g;
        let b = prim.aabb().grow(reach);
        let i0 = (b.min.x.div_euclid(step)).max(0) as usize;
        let j0 = (b.min.y.div_euclid(step)).max(0) as usize;
        let i1 = ((b.max.x.div_euclid(step) + 1).max(0) as usize).min(nx - 1);
        let j1 = ((b.max.y.div_euclid(step) + 1).max(0) as usize).min(ny - 1);
        if i0 > i1 || j0 > j1 {
            return;
        }
        for j in j0..=j1 {
            for i in i0..=i1 {
                let c = Pt::new(i as Nm * step, j as Nm * step);
                if Prim::circle(c, 0).signed_gap(prim) < reach as f64 {
                    claim(&mut map[j * nx + i], net);
                }
            }
        }
    }
}

struct Ctx<'a> {
    p: &'a Project,
    opt: &'a Options,
    clr: Nm,
    via_r: Nm,
    grid: Grid,
}

impl<'a> Ctx<'a> {
    fn new(p: &'a Project, opt: &'a Options, fixed_items: &[Item]) -> Ctx<'a> {
        let step = p.rules.route_grid.max(mm(0.025));
        let nx = (p.board.width / step) as usize + 1;
        let ny = (p.board.height / step) as usize + 1;
        let nl = opt.layers.len();
        let clr = p.net_classes.iter().map(|c| c.clearance).max().unwrap_or(0).max(p.rules.clearance);
        let margin = (step as f64 * std::f64::consts::FRAC_1_SQRT_2).ceil() as Nm + 1;
        let grid = Grid {
            nx,
            ny,
            step,
            margin,
            nl,
            fixed: vec![vec![0; nx * ny]; nl],
            fixed_via: vec![vec![0; nx * ny]; nl],
            routed: vec![vec![0; nx * ny]; nl],
            routed_via: vec![vec![0; nx * ny]; nl],
        };
        let mut c = Ctx { p, opt, clr, via_r: p.rules.via_diameter / 2, grid };
        c.build_fixed(fixed_items);
        c
    }

    fn track_reach(&self) -> Nm {
        self.clr + self.opt.width / 2 + self.grid.margin
    }
    fn via_reach(&self) -> Nm {
        self.clr + self.via_r + 1
    }

    fn build_fixed(&mut self, items: &[Item]) {
        let g = (self.grid.nx, self.grid.ny, self.grid.step);
        let (tr, vr) = (self.track_reach(), self.via_reach());
        for (li, layer) in self.opt.layers.clone().iter().enumerate() {
            for it in items.iter().filter(|it| it.on(layer)) {
                let net = it.net.map(|n| n as i64).unwrap_or(-1);
                Grid::stamp(&mut self.grid.fixed[li], g, &it.prim, tr, net);
                Grid::stamp(&mut self.grid.fixed_via[li], g, &it.prim, vr, net);
            }
        }
        // Holes of non plated pads block vias and tracks on every layer.
        for f in &self.p.board.footprints {
            for pad in f.pads.iter().filter(|q| q.kind == PadKind::Npth) {
                if let Some(d) = pad.drill {
                    let prim = Prim::circle(f.pad_position(pad), d / 2);
                    for li in 0..self.grid.nl {
                        Grid::stamp(&mut self.grid.fixed[li], g, &prim, tr, -1);
                        Grid::stamp(&mut self.grid.fixed_via[li], g, &prim, vr, -1);
                    }
                }
            }
        }
        // Board edge, outside and cutouts.
        let e = self.p.rules.edge_clearance;
        let outline = self.p.board.outline.clone();
        let mut edges: Vec<Prim> = ring_edges(&outline).into_iter().map(|(a, b)| Prim::Seg { a, b, r: 0 }).collect();
        for c in &self.p.board.cutouts {
            edges.push(Prim::circle(c.center, c.radius));
        }
        let track_edge = e + self.opt.width / 2 + self.grid.margin;
        let via_edge = e + self.via_r + 1;
        for k in 0..self.grid.nx * self.grid.ny {
            let c = self.grid.centre(k);
            let outside = !point_in_ring(c, &outline);
            let (mut bt, mut bv) = (outside, outside);
            if !outside {
                for ed in &edges {
                    let gap = Prim::circle(c, 0).signed_gap(ed);
                    bt |= gap < track_edge as f64;
                    bv |= gap < via_edge as f64;
                }
            }
            for li in 0..self.grid.nl {
                if bt {
                    self.grid.fixed[li][k] = -1;
                }
                if bv {
                    self.grid.fixed_via[li][k] = -1;
                }
            }
        }
        for ko in &self.p.board.keepouts {
            let prim = Prim::Poly { outer: ko.outline.clone(), holes: vec![], r: 0 };
            for (li, layer) in self.opt.layers.iter().enumerate() {
                if !ko.layers.is_empty() && !ko.layers.contains(layer) {
                    continue;
                }
                if ko.tracks {
                    Grid::stamp(&mut self.grid.fixed[li], g, &prim, self.opt.width / 2 + self.grid.margin, -1);
                }
                if ko.vias {
                    Grid::stamp(&mut self.grid.fixed_via[li], g, &prim, self.via_r + 1, -1);
                }
            }
        }
    }

    fn rebuild_routed(&mut self, paths: &[Option<RoutedPath>]) {
        for li in 0..self.grid.nl {
            self.grid.routed[li].iter_mut().for_each(|c| *c = 0);
            self.grid.routed_via[li].iter_mut().for_each(|c| *c = 0);
        }
        for path in paths.iter().flatten() {
            self.stamp_path(path);
        }
    }

    fn stamp_path(&mut self, path: &RoutedPath) {
        let g = (self.grid.nx, self.grid.ny, self.grid.step);
        let (tr, vr) = (self.track_reach(), self.via_reach());
        let w = self.opt.width / 2;
        for (a, b, li) in &path.tracks {
            let prim = Prim::Seg { a: *a, b: *b, r: w };
            Grid::stamp(&mut self.grid.routed[*li], g, &prim, tr, path.net as i64);
            Grid::stamp(&mut self.grid.routed_via[*li], g, &prim, vr, path.net as i64);
        }
        for v in &path.vias {
            let prim = Prim::circle(*v, self.via_r);
            for li in 0..self.grid.nl {
                Grid::stamp(&mut self.grid.routed[li], g, &prim, tr, path.net as i64);
                Grid::stamp(&mut self.grid.routed_via[li], g, &prim, vr, path.net as i64);
            }
        }
    }

    fn ok(owner: i64, net: i64) -> bool {
        owner == 0 || owner == net
    }

    /// A* from pad `a` to pad `b`. With `rip`, other nets' routed copper is passable at a cost.
    fn search(&self, net: Id, a: Pt, a_layers: &[usize], b: Pt, b_layers: &[usize], rip: bool) -> Option<Vec<(usize, usize)>> {
        let g = &self.grid;
        let n = g.nx * g.ny;
        let netv = net as i64;
        let (s, t) = (g.nearest(a), g.nearest(b));
        let (ti, tj) = ((t % g.nx) as i64, (t / g.nx) as i64);
        let state = |l: usize, k: usize, d: usize| (l * n + k) * 8 + d;
        let total = g.nl * n * 8;
        let mut cost = vec![u32::MAX; total];
        let mut prev = vec![u32::MAX; total];
        let mut heap: BinaryHeap<Reverse<(u32, u32, u32)>> = BinaryHeap::new();
        let h = |k: usize| -> u32 {
            let (i, j) = ((k % g.nx) as i64, (k / g.nx) as i64);
            let (dx, dy) = ((i - ti).unsigned_abs() as u32, (j - tj).unsigned_abs() as u32);
            let (lo, hi) = (dx.min(dy), dx.max(dy));
            lo * DIAG + (hi - lo) * STEP
        };
        let mut seq: u32 = 0;
        for &l in a_layers {
            for d in 0..8 {
                let st = state(l, s, d);
                cost[st] = 0;
                heap.push(Reverse((h(s), seq, st as u32)));
                seq += 1;
            }
        }
        let passable = |l: usize, k: usize| -> Option<u32> {
            if k == t && b_layers.contains(&l) {
                return Some(0);
            }
            if !Self::ok(g.fixed[l][k], netv) {
                return None;
            }
            if Self::ok(g.routed[l][k], netv) {
                Some(0)
            } else if rip {
                Some(RIP_COST)
            } else {
                None
            }
        };
        let via_ok = |k: usize| -> Option<u32> {
            let mut extra = 0;
            for l in 0..g.nl {
                if !Self::ok(g.fixed_via[l][k], netv) {
                    return None;
                }
                if !Self::ok(g.routed_via[l][k], netv) {
                    if rip { extra += RIP_COST } else { return None }
                }
            }
            Some(extra)
        };
        while let Some(Reverse((_, _, st))) = heap.pop() {
            let st = st as usize;
            let (l, k, d) = (st / 8 / n, (st / 8) % n, st % 8);
            let c = cost[st];
            if k == t && b_layers.contains(&l) {
                let mut out = vec![];
                let mut x = st;
                loop {
                    out.push(((x / 8) / n, (x / 8) % n));
                    if prev[x] == u32::MAX {
                        break;
                    }
                    x = prev[x] as usize;
                }
                out.reverse();
                out.dedup();
                return Some(out);
            }
            let (i, j) = ((k % g.nx) as i64, (k / g.nx) as i64);
            for (e, (dx, dy)) in DIRS.iter().enumerate() {
                let (a2, b2) = (i + dx, j + dy);
                if a2 < 0 || b2 < 0 || a2 >= g.nx as i64 || b2 >= g.ny as i64 {
                    continue;
                }
                let k2 = g.idx(a2 as usize, b2 as usize);
                let Some(extra) = passable(l, k2) else { continue };
                // A diagonal move may not cut between two blocked orthogonal neighbours.
                if e % 2 == 1 {
                    let (k3, k4) = (g.idx(a2 as usize, j as usize), g.idx(i as usize, b2 as usize));
                    if passable(l, k3).is_none() && passable(l, k4).is_none() {
                        continue;
                    }
                }
                let turn = { let t = (e as i64 - d as i64).rem_euclid(8); t.min(8 - t) };
                if turn > 2 {
                    continue;
                }
                let step = if e % 2 == 1 { DIAG } else { STEP };
                let pen = match turn { 0 => 0, 1 => TURN45, _ => TURN90 };
                let nc = c + step + pen + extra;
                let st2 = state(l, k2, e);
                if nc < cost[st2] {
                    cost[st2] = nc;
                    prev[st2] = st as u32;
                    heap.push(Reverse((nc + h(k2), seq, st2 as u32)));
                    seq += 1;
                }
            }
            if self.opt.allow_vias && g.nl > 1 && k != s && k != t {
                if let Some(extra) = via_ok(k) {
                    for l2 in 0..g.nl {
                        if l2 == l || passable(l2, k).is_none() {
                            continue;
                        }
                        let nc = c + VIA_COST + extra;
                        let st2 = state(l2, k, d);
                        if nc < cost[st2] {
                            cost[st2] = nc;
                            prev[st2] = st as u32;
                            heap.push(Reverse((nc + h(k), seq, st2 as u32)));
                            seq += 1;
                        }
                    }
                }
            }
        }
        None
    }

    fn to_path(&self, net: Id, a: Pt, b: Pt, cells: &[(usize, usize)]) -> RoutedPath {
        let g = &self.grid;
        let mut tracks = vec![];
        let mut vias = vec![];
        // Runs per layer; a layer change at a cell is a via there.
        let mut runs: Vec<(usize, Vec<Pt>)> = vec![];
        for (l, k) in cells {
            let c = g.centre(*k);
            match runs.last_mut() {
                Some((rl, pts)) if rl == l => pts.push(c),
                Some(_) => {
                    vias.push(c);
                    runs.push((*l, vec![c]));
                }
                None => runs.push((*l, vec![c])),
            }
        }
        let last = runs.len() - 1;
        for (ri, (l, mut pts)) in runs.into_iter().enumerate() {
            if ri == 0 {
                pts.insert(0, a);
            }
            if ri == last {
                pts.push(b);
            }
            pts.dedup();
            // Merge collinear points.
            let mut merged: Vec<Pt> = vec![];
            for p in pts {
                while merged.len() >= 2 {
                    let (u, v) = (merged[merged.len() - 2], merged[merged.len() - 1]);
                    let cross = (v.x - u.x) as i128 * (p.y - v.y) as i128 - (v.y - u.y) as i128 * (p.x - v.x) as i128;
                    let dot = (v.x - u.x) as i128 * (p.x - v.x) as i128 + (v.y - u.y) as i128 * (p.y - v.y) as i128;
                    if cross == 0 && dot >= 0 { merged.pop(); } else { break; }
                }
                merged.push(p);
            }
            for w in merged.windows(2) {
                if w[0] != w[1] {
                    tracks.push((w[0], w[1], l));
                }
            }
        }
        RoutedPath { net, tracks, vias }
    }

    fn conflicts(&self, a: &RoutedPath, b: &RoutedPath) -> bool {
        if a.net == b.net {
            return false;
        }
        let w = self.opt.width / 2;
        let prims = |p: &RoutedPath| -> Vec<(Prim, Option<usize>)> {
            let mut v: Vec<(Prim, Option<usize>)> = p.tracks.iter().map(|(s, e, l)| (Prim::Seg { a: *s, b: *e, r: w }, Some(*l))).collect();
            v.extend(p.vias.iter().map(|c| (Prim::circle(*c, self.via_r), None)));
            v
        };
        for (pa, la) in prims(a) {
            for (pb, lb) in prims(b) {
                if la.is_some() && lb.is_some() && la != lb {
                    continue;
                }
                if pa.signed_gap(&pb) < self.clr as f64 {
                    return true;
                }
            }
        }
        false
    }
}

fn pad_layers(p: &Project, object: Id, at: Pt, layers: &[String]) -> Vec<usize> {
    let mut out = vec![];
    if let Some(f) = p.footprint(object) {
        if let Some(pad) = f.pads.iter().find(|q| f.pad_position(q) == at) {
            for l in f.pad_layers(pad) {
                if let Some(i) = layers.iter().position(|x| x == l) {
                    out.push(i);
                }
            }
        }
    }
    if out.is_empty() {
        out = (0..layers.len()).collect();
    }
    out
}

/// Routes every unrouted connection and adds the tracks and vias to the board.
pub fn autoroute(p: &mut Project, opt: &Options) -> Result<Report> {
    if opt.layers.is_empty() {
        return Err(EngineError::invalid("no routing layer"));
    }
    let airwires = ratsnest(p);
    let items = collect(p);
    let mut report = Report { connections: airwires.len(), ..Default::default() };
    let mut order: Vec<usize> = (0..airwires.len()).collect();
    order.sort_by(|&x, &y| {
        let (a, b) = (&airwires[x], &airwires[y]);
        let (la, lb) = (a.from.dist(a.to), b.from.dist(b.to));
        la.partial_cmp(&lb).unwrap().then(x.cmp(&y))
    });
    let (paths, failed, ripups) = {
        let mut ctx = Ctx::new(p, opt, &items);
        let mut paths: Vec<Option<RoutedPath>> = vec![None; airwires.len()];
        let mut rips = vec![0u32; airwires.len()];
        let mut queue: std::collections::VecDeque<usize> = order.into_iter().collect();
        let mut failed = vec![];
        let mut ripups = 0;
        let mut budget = airwires.len() * 6 + 10;
        while let Some(i) = queue.pop_front() {
            if budget == 0 {
                failed.push(i);
                continue;
            }
            budget -= 1;
            let a = &airwires[i];
            let la = pad_layers(p, a.from_object, a.from, &opt.layers);
            let lb = pad_layers(p, a.to_object, a.to, &opt.layers);
            if let Some(cells) = ctx.search(a.net, a.from, &la, a.to, &lb, false) {
                let path = ctx.to_path(a.net, a.from, a.to, &cells);
                ctx.stamp_path(&path);
                paths[i] = Some(path);
                continue;
            }
            if !opt.ripup || rips[i] >= 3 {
                failed.push(i);
                continue;
            }
            rips[i] += 1;
            let Some(cells) = ctx.search(a.net, a.from, &la, a.to, &lb, true) else {
                failed.push(i);
                continue;
            };
            let path = ctx.to_path(a.net, a.from, a.to, &cells);
            let victims: Vec<usize> = (0..paths.len()).filter(|j| paths[*j].as_ref().map(|q| ctx.conflicts(&path, q)).unwrap_or(false)).collect();
            for v in &victims {
                paths[*v] = None;
                queue.push_back(*v);
                ripups += 1;
            }
            paths[i] = Some(path);
            ctx.rebuild_routed(&paths);
        }
        failed.sort();
        failed.dedup();
        (paths, failed, ripups)
    };
    report.ripups = ripups;
    for (i, path) in paths.iter().enumerate() {
        let Some(path) = path else { continue };
        report.routed += 1;
        for (a, b, l) in &path.tracks {
            let id = p.alloc();
            p.board.tracks.push(Track { id, net: path.net, start: *a, end: *b, width: opt.width, layer: opt.layers[*l].clone(), auto: true });
        }
        for v in &path.vias {
            let id = p.alloc();
            p.board.vias.push(Via { id, net: path.net, at: *v, diameter: p.rules.via_diameter, drill: p.rules.via_drill, auto: true });
            report.vias += 1;
        }
        let _ = i;
    }
    for i in failed {
        if paths[i].is_some() {
            continue;
        }
        let a = &airwires[i];
        report.failed.push(format!("{} ({:.2},{:.2})-({:.2},{:.2})", p.net_name(a.net), to_mm(a.from.x), to_mm(a.from.y), to_mm(a.to.x), to_mm(a.to.y)));
    }
    Ok(report)
}

/// Routes one connection between two pads on one layer (walkaround, no vias).
pub fn route_one(p: &mut Project, net: Id, a: (Id, Pt), b: (Id, Pt), layer: &str, width: Nm) -> Result<Vec<Id>> {
    let opt = Options { layers: vec![layer.to_string()], width, allow_vias: false, ripup: false };
    let items = collect(p);
    let ctx = Ctx::new(p, &opt, &items);
    for (f, at) in [a, b] {
        let on = p.footprint(f).and_then(|fp| fp.pads.iter().find(|q| fp.pad_position(q) == at).map(|q| fp.pad_layers(q).contains(&layer)));
        if on == Some(false) {
            return Err(EngineError::new("wrong_layer", format!("A pad of footprint {f} is not on {layer}")));
        }
    }
    let cells = ctx
        .search(net, a.1, &[0], b.1, &[0], false)
        .ok_or_else(|| EngineError::new("route_failed", format!("No path on {layer} between the two pads that keeps the clearance")))?;
    let path = ctx.to_path(net, a.1, b.1, &cells);
    let mut ids = vec![];
    for (s, e, _) in path.tracks {
        let id = p.alloc();
        p.board.tracks.push(Track { id, net, start: s, end: e, width, layer: layer.to_string(), auto: false });
        ids.push(id);
    }
    Ok(ids)
}
