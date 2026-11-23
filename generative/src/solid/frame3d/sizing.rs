//! Sizing, for least mass under the stress and displacement limits.
//!
//! A fully stressed design from a uniform start spreads the material thinly over the whole ground
//! structure (the fans of a Michell truss), so cutting every bar under the narrowest member at once
//! cuts the load paths with them, and what a restored path leaves (a chain of bars in bending) no
//! diameter cap can save. So the fully stressed design is thinned to a truss first: reweighted
//! steps on the pin-jointed frame that gather each load onto the path already carrying most of it,
//! bars at the floor removed between rounds. The truss's bars thinner than the narrowest member
//! are then widened to it or cut (a few shares tried), and each frame gets a last fully stressed
//! pass: both ways while it settles, then growing only (the whole frame by the worst ratio when
//! the overstressed bars are at their caps) until every limit holds, then the least uniform scale
//! that still holds. MMA on mass under one aggregated limit (the p-norm of every stress and
//! displacement ratio, scaled each iteration to track the true maximum, adjoint sensitivities)
//! refines the lightest frame, kept when lighter still. When no thinned frame holds, every beam of
//! the ground structure is sized as the last resort.

use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::f64::consts::PI;

use super::beam::{Elastic, V3, dist, norm, scale};
use super::ground::{self, Ground};
use super::model::{Limits, Model, Response, Setup};
use super::{Beam, Frame};
use crate::solid::grid::unit;
use crate::solid::{Load, Region, Study};

/// Exponent of the aggregated limit.
const P_NORM: f64 = 8.0;

pub fn run(study: &Study, seed: u64) -> Result<Frame, String> {
    check(study)?;
    let sigma = study.max_stress.unwrap_or(study.material.allowable / study.safety_factor);
    let ground = ground::build(study, &anchors(study))?;
    let setup = setup(study, &ground);
    let el = Elastic { e: study.material.e, g: study.material.e / (2.0 * (1.0 + study.material.nu)), bend: 1.0 };
    let rho = study.material.density * 1e-6;
    let density = study.material.density;
    let d_hi = largest(study, &ground);
    let d_lo = 0.1 * study.min_member;
    let lim = Limits { stress: sigma, displacement: study.max_displacement, p: P_NORM, d_lo, d_cut: study.min_member };

    let all = vec![true; setup.beams.len()];
    let model = Model::new(&setup, &all, el, rho)?;
    let mut x: Vec<f64> = (0..setup.groups).map(|g| (0.5 * d_hi * jitter(seed, g)).clamp(d_lo, setup.cap[g])).collect();
    let mut history = Vec::new();
    let budget = study.iterations;

    // Fully stressed design over the whole ground structure.
    let fsd = budget.min((budget / 4).max(8));
    for _ in 0..fsd {
        let d = expand(&model, &x);
        let (resp, _) = model.analyse(&d)?;
        history.push(mass(&model, &d, density));
        if resize(&model, &resp, &mut x, &setup.cap, d_lo, &lim, false) < 1e-3 {
            break;
        }
    }
    let mut in_model = vec![false; setup.beams.len()];
    for &e in &model.beams {
        in_model[e] = true;
    }
    drop(model);

    // Thinned to a truss that carries the load.
    let ctx = Ctx { setup: &setup, el, rho, density, lim: &lim, floor: study.min_member };
    let (keep, x, steps) = thin_out(&ctx, &in_model, &x, d_lo);
    history.extend(steps);

    // The bars the truss left thinner than the narrowest member are widened to it, or go: a
    // fully stressed pass until the limits hold for each cut, and the lightest frame that holds
    // wins.
    let mut best: Option<Sized> = None;
    let mut tried: Vec<Vec<bool>> = Vec::new();
    for share in CUTS {
        let cut = share * study.min_member;
        let mut thinned: Vec<bool> = (0..setup.beams.len()).map(|e| keep[e] && x[setup.group[e]] >= cut).collect();
        restore(&setup, &keep, &mut thinned);
        prune(&setup, &mut thinned);
        if tried.contains(&thinned) {
            continue;
        }
        consider(settle(&ctx, &thinned, &x), &mut best);
        tried.push(thinned);
    }

    // MMA on mass under the aggregated limit over the best of them, and its last fully stressed
    // pass: kept when lighter.
    if let Some(b) = best.as_ref().filter(|b| b.feasible) {
        let keep = b.keep.clone();
        let from = b.x.clone();
        let mut steps = Vec::new();
        let x_mma = mma_sizing(&ctx, &b.model, &from, d_hi, budget.saturating_sub(history.len()), &mut steps);
        if let Some(mut c) = settle(&ctx, &keep, &x_mma) {
            steps.append(&mut c.history);
            c.history = steps;
            consider(Some(c), &mut best);
        }
    }

    // When nothing holds (bars at their caps), every beam of the ground structure, as the last
    // resort.
    if !best.as_ref().is_some_and(|b| b.feasible) {
        consider(settle(&ctx, &in_model, &x), &mut best);
    }
    let best = best.ok_or_else(|| "no subset of the ground structure stands under the loads".to_string())?;
    history.extend(best.history);
    Ok(frame(&best.model, &setup, &best.d, &best.resp, &lim, density, history))
}

/// Shares of the narrowest member under which the truss's thin bars go rather than widen.
const CUTS: [f64; 4] = [0.0, 0.25, 0.5, 0.75];

/// Keeps `cand` when it beats `best`: feasible first, then lighter, then less over its limits.
fn consider(cand: Option<Sized>, best: &mut Option<Sized>) {
    let Some(c) = cand else { return };
    let better = match best {
        None => true,
        Some(b) => match (c.feasible, b.feasible) {
            (true, false) => true,
            (false, true) => false,
            (true, true) => c.mass < b.mass,
            (false, false) => c.violation < b.violation,
        },
    };
    if better {
        *best = Some(c);
    }
}

/// MMA on mass under the aggregated limit for the model's beams, each between the narrowest
/// member and its cap, for at most `iterations` analyses (mass per analysis onto `history`).
/// Returns the diameters per group.
fn mma_sizing(ctx: &Ctx, model: &Model, start: &[f64], d_hi: f64, iterations: usize, history: &mut Vec<f64>) -> Vec<f64> {
    let setup = ctx.setup;
    let mut x = start.to_vec();
    let mut present = vec![false; setup.groups];
    for &g in &model.group {
        present[g] = true;
    }
    let vars: Vec<usize> = (0..setup.groups).filter(|&g| present[g]).collect();
    let lo = |g: usize| ctx.floor.min(setup.cap[g]);
    for &g in &vars {
        x[g] = x[g].clamp(lo(g), setup.cap[g].max(lo(g)));
    }
    let lower: Vec<f64> = vars.iter().map(|&g| lo(g) / d_hi).collect();
    let upper: Vec<f64> = vars.iter().map(|&g| setup.cap[g].max(lo(g)) / d_hi).collect();
    let mut mma = Mma::new(vars.len());
    let mut mass_ref = 0.0;
    let mut norm_scale: Option<f64> = None;
    for _ in 0..iterations {
        let d = expand(model, &x);
        let Ok((resp, factor)) = model.analyse(&d) else { break };
        let m = mass(model, &d, ctx.density);
        history.push(m);
        if mass_ref == 0.0 {
            mass_ref = m;
        }
        let agg = model.aggregate(&d, &resp, &factor, ctx.lim);
        if agg.value <= 0.0 || mass_ref <= 0.0 {
            break;
        }
        let c = match norm_scale {
            None => agg.max / agg.value,
            Some(prev) => 0.5 * agg.max / agg.value + 0.5 * prev,
        };
        norm_scale = Some(c);
        let mut dg = vec![0.0; setup.groups];
        let mut df = vec![0.0; setup.groups];
        for (e, &g) in model.group.iter().enumerate() {
            dg[g] += c * agg.grad[e] * d_hi;
            df[g] += ctx.density * PI / 2.0 * d[e] * model.lines[e].len * d_hi / mass_ref;
        }
        let xs: Vec<f64> = vars.iter().map(|&g| x[g] / d_hi).collect();
        let dfs: Vec<f64> = vars.iter().map(|&g| df[g]).collect();
        let dgs: Vec<f64> = vars.iter().map(|&g| dg[g]).collect();
        let constraint = c * agg.value - 1.0;
        let next = mma.step(&xs, &lower, &upper, &dfs, constraint, &dgs);
        let mut change = 0.0f64;
        for (k, &g) in vars.iter().enumerate() {
            change = change.max((next[k] - xs[k]).abs());
            x[g] = next[k] * d_hi;
        }
        if change < 1e-4 && constraint < 1e-3 {
            break;
        }
    }
    x
}

/// What sizing a frame needs besides the beams kept.
struct Ctx<'a> {
    setup: &'a Setup,
    el: Elastic,
    rho: f64,
    density: f64,
    lim: &'a Limits,
    floor: f64,
}

/// A thinned frame resized: its model, diameters and response.
struct Sized {
    model: Model,
    /// The setup's beams kept, and the diameters per group.
    keep: Vec<bool>,
    x: Vec<f64>,
    d: Vec<f64>,
    resp: Response,
    mass: f64,
    feasible: bool,
    /// The worst stress or displacement ratio to its limit.
    violation: f64,
    history: Vec<f64>,
}

/// Rounds of the thinning, at most.
const THIN_ROUNDS: usize = 10;

/// Sparse steps per round of the thinning.
const THIN_STEPS: usize = 5;

/// The quasi-norm the thinning's steps minimise: below 1, so that of two paths for a load the one
/// carrying more takes it all.
const THIN_P: f64 = 0.8;

/// The bending left in the truss the thinning analyses.
const TRUSS_BEND: f64 = 1e-6;

/// Thins the frame from `start` to the bars that carry the load. A fully stressed design spreads
/// its material thinly over the whole ground structure (the fans of a Michell truss), and cutting
/// every bar under the narrowest member at once cuts load paths with them. Fully stressed steps are
/// iteratively reweighted least squares for the least volume, `Σ L |N| / σ`; reweighting with
/// `|N|^(2-p)` instead, `p` below 1, minimises `Σ L |N|^p` and gathers each load onto the path that
/// already carries most of it: section `|N|/σ · (|N|/N_max)^(1-p)`, so the bars a load can do
/// without fade to the floor. Each round takes a few such steps, then removes the bars at the
/// floor (restoring a path wherever a load would lose its support, pruning dangling stubs).
/// Returns the beams kept, their diameters and the mass per round.
fn thin_out(ctx: &Ctx, avail: &[bool], start: &[f64], d_lo: f64) -> (Vec<bool>, Vec<f64>, Vec<f64>) {
    let setup = ctx.setup;
    let mut keep = avail.to_vec();
    let mut x = start.to_vec();
    let mut history: Vec<f64> = Vec::new();
    let truss = Elastic { bend: TRUSS_BEND, ..ctx.el };
    for _ in 0..THIN_ROUNDS {
        let Ok(model) = Model::new(setup, &keep, truss, ctx.rho) else { break };
        for _ in 0..THIN_STEPS {
            let d = expand(&model, &x);
            let Ok((resp, _)) = model.analyse(&d) else { break };
            sparse_step(&model, &resp, &mut x, &setup.cap, d_lo, ctx.lim);
        }
        let d = expand(&model, &x);
        history.push(mass(&model, &d, ctx.density));
        let gone = 1.5 * d_lo;
        let mut next: Vec<bool> = (0..setup.beams.len()).map(|e| keep[e] && x[setup.group[e]] >= gone).collect();
        restore(setup, &keep, &mut next);
        prune(setup, &mut next);
        if next == keep || Model::new(setup, &next, ctx.el, ctx.rho).is_err() {
            break;
        }
        keep = next;
    }
    (keep, x, history)
}

/// One step of the thinning: each group's section to `|N|/σ · (|N|/N_max)^(1-p)`, `|N|` its
/// largest axial force over its bars and the cases; within half and twice the diameter, and within
/// `floor` and the cap. The topology is a truss's: bending is left to the sizing that follows.
fn sparse_step(model: &Model, resp: &Response, x: &mut [f64], cap: &[f64], floor: f64, lim: &Limits) {
    let mut force = vec![f64::NAN; x.len()];
    for (e, &g) in model.group.iter().enumerate() {
        let n = model.lines[e].n;
        let mut f = 0.0f64;
        for (c, u) in resp.u.iter().enumerate() {
            let a = model.end_actions(c, e, x[g], u);
            f = f.max(super::beam::dot([a[6], a[7], a[8]], n).abs()).max(super::beam::dot([a[0], a[1], a[2]], n).abs());
        }
        force[g] = if force[g].is_nan() { f } else { force[g].max(f) };
    }
    let strongest = force.iter().copied().filter(|f| !f.is_nan()).fold(0.0, f64::max);
    if strongest <= 0.0 {
        return;
    }
    for g in 0..x.len() {
        if force[g].is_nan() {
            continue;
        }
        let area = force[g] / lim.stress * (force[g] / strongest).powf(1.0 - THIN_P);
        let d = (4.0 * area / PI).sqrt();
        x[g] = d.clamp(0.5 * x[g], 2.0 * x[g]).clamp(floor, cap[g].max(floor));
    }
}

/// The worst ratio of a stress or a displacement to its limit.
fn violation(resp: &Response, lim: &Limits) -> f64 {
    let s = resp.beam_stress().iter().fold(0.0, |a: f64, &v| a.max(v / lim.stress));
    let u = lim.displacement.map_or(0.0, |m| resp.displacement().iter().fold(0.0, |a: f64, &v| a.max(v / m)));
    s.max(u)
}

/// Resizes the beams marked in `keep` from `start` (each at least the narrowest member): fully
/// stressed steps both ways while they settle, then growing only until every limit holds; when the
/// overstressed groups can grow no more (at their caps), every group grows by the worst ratio's
/// cube root. `None` when the beams do not stand.
fn settle(ctx: &Ctx, keep: &[bool], start: &[f64]) -> Option<Sized> {
    let setup = ctx.setup;
    let model = Model::new(setup, keep, ctx.el, ctx.rho).ok()?;
    let mut x = start.to_vec();
    for &g in &model.group {
        x[g] = x[g].max(ctx.floor).min(setup.cap[g].max(ctx.floor));
    }
    let mut history = Vec::new();
    for _ in 0..15 {
        let d = expand(&model, &x);
        let (resp, _) = model.analyse(&d).ok()?;
        history.push(mass(&model, &d, ctx.density));
        if holds(&resp, ctx.lim) && violation(&resp, ctx.lim) > 0.97 {
            break;
        }
        if resize(&model, &resp, &mut x, &setup.cap, ctx.floor, ctx.lim, false) < 1e-3 {
            break;
        }
    }
    let mut last = None;
    for _ in 0..30 {
        let d = expand(&model, &x);
        let (resp, _) = model.analyse(&d).ok()?;
        history.push(mass(&model, &d, ctx.density));
        let v = violation(&resp, ctx.lim);
        let ok = holds(&resp, ctx.lim);
        let before = x.clone();
        let grown = (!ok).then(|| resize(&model, &resp, &mut x, &setup.cap, ctx.floor, ctx.lim, true));
        last = Some((before, d, resp, v));
        let Some(mut change) = grown else { break };
        if change < 1e-6 {
            change = grow_all(&model, &mut x, &setup.cap, v);
        }
        if change < 1e-9 {
            break;
        }
    }
    let (mut x, mut d, mut resp, mut v) = last?;
    let mut feasible = holds(&resp, ctx.lim);
    // Growing overshoots (bending stiffens as d⁴, a displacement limit binds the whole frame): the
    // least uniform scale of every diameter that still holds, by bisection.
    if feasible {
        let base = x.clone();
        let scaled = |s: f64| -> Vec<f64> {
            let mut y = base.clone();
            for &g in &model.group {
                y[g] = (base[g] * s).max(ctx.floor.min(base[g]));
            }
            y
        };
        let (mut lo, mut hi) = (0.5f64, 1.0f64);
        for _ in 0..TIGHTEN_STEPS {
            let mid = 0.5 * (lo + hi);
            let y = scaled(mid);
            let dy = expand(&model, &y);
            let Ok((r, _)) = model.analyse(&dy) else { break };
            history.push(mass(&model, &dy, ctx.density));
            if holds(&r, ctx.lim) {
                hi = mid;
                v = violation(&r, ctx.lim);
                (x, d, resp) = (y, dy, r);
            } else {
                lo = mid;
            }
        }
        feasible = holds(&resp, ctx.lim);
    }
    let m = mass(&model, &d, ctx.density);
    Some(Sized { model, keep: keep.to_vec(), x, d, resp, mass: m, feasible, violation: v, history })
}

/// Bisection steps of the uniform tightening after a frame holds.
const TIGHTEN_STEPS: usize = 7;

/// Every group of the model by the cube root of `ratio` (a margin over), within its cap. Returns
/// the largest change over the cap.
fn grow_all(model: &Model, x: &mut [f64], cap: &[f64], ratio: f64) -> f64 {
    let step = (1.02 * ratio.max(1.0)).cbrt();
    let mut seen = vec![false; x.len()];
    let mut change = 0.0f64;
    for &g in &model.group {
        if seen[g] {
            continue;
        }
        seen[g] = true;
        let t = (x[g] * step).min(cap[g]).max(x[g]);
        change = change.max((t - x[g]).abs() / cap[g]);
        x[g] = t;
    }
    change
}

/// Every limit kept.
fn holds(resp: &Response, lim: &Limits) -> bool {
    let tol = 1.0 + 1e-6;
    let stress = resp.stress.iter().flatten().all(|s| s[0] <= lim.stress * tol && s[1] <= lim.stress * tol);
    let disp = lim.displacement.is_none_or(|m| resp.displacement().iter().all(|&u| u <= m * tol));
    stress && disp
}

fn frame(model: &Model, setup: &Setup, d: &[f64], resp: &Response, lim: &Limits, density: f64, history: Vec<f64>) -> Frame {
    let stress = resp.beam_stress();
    let beams: Vec<Beam> = model.ends.iter().enumerate().map(|(e, &ends)| Beam { ends, diameter: d[e], stress: stress[e] }).collect();
    let mut radius = vec![0.0f64; model.nodes.len()];
    for (e, &[a, b]) in model.ends.iter().enumerate() {
        radius[a] = radius[a].max(d[e] / 2.0);
        radius[b] = radius[b].max(d[e] / 2.0);
    }
    let joints = radius.iter().enumerate().map(|(v, &r)| (1.1 * r).min(setup.joint_cap[model.origin[v]]).max(r)).collect();
    Frame {
        nodes: model.nodes.clone(),
        beams,
        joints,
        compliance: resp.compliance.iter().zip(&model.weight).map(|(c, w)| c * w).collect(),
        max_stress: resp.stress.iter().map(|c| c.iter().map(|s| s[0].max(s[1])).fold(0.0, f64::max)).collect(),
        max_displacement: resp.displacement(),
        mass_g: mass(model, d, density),
        feasible: holds(resp, lim),
        history,
    }
}

/// The thickest bar the lattice takes: half a spacing, and at least twice the narrowest member.
pub fn largest(study: &Study, ground: &Ground) -> f64 {
    (0.5 * ground.spacing).max(2.0 * study.min_member)
}

fn expand(model: &Model, x: &[f64]) -> Vec<f64> {
    model.group.iter().map(|&g| x[g]).collect()
}

/// Mass of the beams, g.
fn mass(model: &Model, d: &[f64], density: f64) -> f64 {
    model.lines.iter().zip(d).map(|(l, &d)| density * PI / 4.0 * d * d * l.len).sum()
}

/// One fully stressed step: each group's diameter times its worst stress ratio to the power 0.4
/// (between axial, 1/2, and bending, 1/3), or its square root when only growing, and every
/// diameter by the square root of the displacement ratio when over; within half and twice, and
/// within `floor` and the cap. Returns the largest change over the cap.
fn resize(model: &Model, resp: &Response, x: &mut [f64], cap: &[f64], floor: f64, lim: &Limits, grow_only: bool) -> f64 {
    let stress = resp.beam_stress();
    let mut ratio = vec![f64::NAN; x.len()];
    for (e, &g) in model.group.iter().enumerate() {
        let r = stress[e] / lim.stress;
        ratio[g] = if ratio[g].is_nan() { r } else { ratio[g].max(r) };
    }
    let over = lim.displacement.map_or(1.0, |m| resp.displacement().iter().fold(0.0, |a: f64, &u| a.max(u / m))).max(1.0);
    let mut change = 0.0f64;
    for g in 0..x.len() {
        if ratio[g].is_nan() {
            continue;
        }
        let r = ratio[g].max(1e-9);
        let step = if grow_only { if r > 1.0 { (1.01 * r).sqrt() } else { 1.0 } } else { r.powf(0.4) } * over.sqrt();
        let t = (x[g] * step).clamp(0.5 * x[g], 2.0 * x[g]).clamp(floor, cap[g]);
        change = change.max((t - x[g]).abs() / cap[g]);
        x[g] = t;
    }
    change
}

/// Restores, for every loaded node cut off from the supports, the cheapest path of removed beams
/// back to one (whole symmetry groups, so mirrored beams stay alike).
fn restore(setup: &Setup, avail: &[bool], keep: &mut [bool]) {
    let n = setup.nodes.len();
    let mut adj: Vec<Vec<(usize, usize)>> = vec![Vec::new(); n];
    for (e, &[a, b]) in setup.beams.iter().enumerate() {
        if avail[e] {
            adj[a].push((b, e));
            adj[b].push((a, e));
        }
    }
    let mut cost = vec![f64::INFINITY; n];
    let mut via = vec![usize::MAX; n];
    let mut heap = BinaryHeap::new();
    for v in 0..n {
        if setup.supported(v) && !adj[v].is_empty() {
            cost[v] = 0.0;
            heap.push(Near(0.0, v));
        }
    }
    while let Some(Near(c, v)) = heap.pop() {
        if c > cost[v] {
            continue;
        }
        for &(w, e) in &adj[v] {
            let step = if keep[e] { 0.0 } else { dist(setup.nodes[v], setup.nodes[w]) };
            if c + step < cost[w] {
                cost[w] = c + step;
                via[w] = e;
                heap.push(Near(c + step, w));
            }
        }
    }
    let mut groups = Vec::new();
    for v in 0..n {
        if !setup.loaded(v) || adj[v].is_empty() || cost[v] == 0.0 || !cost[v].is_finite() {
            continue;
        }
        let mut at = v;
        while cost[at] > 0.0 && via[at] != usize::MAX {
            let e = via[at];
            if !keep[e] {
                groups.push(setup.group[e]);
            }
            let [a, b] = setup.beams[e];
            at = if a == at { b } else { a };
        }
    }
    groups.sort_unstable();
    groups.dedup();
    for (e, k) in keep.iter_mut().enumerate() {
        if avail[e] && groups.binary_search(&setup.group[e]).is_ok() {
            *k = true;
        }
    }
}

/// Removes, group by group, beams hanging from a free end (no load, no support, nothing else).
fn prune(setup: &Setup, keep: &mut [bool]) {
    loop {
        let mut degree = vec![0usize; setup.nodes.len()];
        for (e, &[a, b]) in setup.beams.iter().enumerate() {
            if keep[e] {
                degree[a] += 1;
                degree[b] += 1;
            }
        }
        let loose = |v: usize| degree[v] == 1 && !setup.loaded(v) && !setup.supported(v);
        let mut stub = vec![true; setup.groups];
        for (e, &[a, b]) in setup.beams.iter().enumerate() {
            if keep[e] && !(loose(a) || loose(b)) {
                stub[setup.group[e]] = false;
            }
        }
        let mut changed = false;
        for (e, k) in keep.iter_mut().enumerate() {
            if *k && stub[setup.group[e]] {
                *k = false;
                changed = true;
            }
        }
        if !changed {
            return;
        }
    }
}

#[derive(PartialEq)]
struct Near(f64, usize);

impl Eq for Near {}

impl Ord for Near {
    fn cmp(&self, other: &Self) -> Ordering {
        other.0.total_cmp(&self.0).then(other.1.cmp(&self.1))
    }
}

impl PartialOrd for Near {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// A start between 0.8 and 1.2 times the uniform one, per group, from the seed.
fn jitter(seed: u64, g: usize) -> f64 {
    let mut z = seed.wrapping_add((g as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15));
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    0.8 + 0.4 * (z >> 11) as f64 / (1u64 << 53) as f64
}

/// The method of moving asymptotes (Svanberg 1987) for one constraint: convex separable
/// approximations about the current point, the subproblem solved through its one-dimensional dual.
struct Mma {
    low: Vec<f64>,
    upp: Vec<f64>,
    x1: Vec<f64>,
    x2: Vec<f64>,
    iter: usize,
}

impl Mma {
    fn new(n: usize) -> Self {
        Self { low: vec![0.0; n], upp: vec![0.0; n], x1: vec![0.0; n], x2: vec![0.0; n], iter: 0 }
    }

    /// The next point from `x` within `xmin..xmax`, for objective gradient `df`, constraint value
    /// `g` (kept at or below zero) and its gradient `dg`.
    fn step(&mut self, x: &[f64], xmin: &[f64], xmax: &[f64], df: &[f64], g: f64, dg: &[f64]) -> Vec<f64> {
        const INIT: f64 = 0.3;
        const MOVE: f64 = 0.2;
        let n = x.len();
        let mut alpha = vec![0.0; n];
        let mut beta = vec![0.0; n];
        let (mut p0, mut q0, mut p1, mut q1) = (vec![0.0; n], vec![0.0; n], vec![0.0; n], vec![0.0; n]);
        let mut r1 = g;
        for j in 0..n {
            let range = (xmax[j] - xmin[j]).max(1e-12);
            if self.iter < 2 {
                self.low[j] = x[j] - INIT * range;
                self.upp[j] = x[j] + INIT * range;
            } else {
                let trend = (x[j] - self.x1[j]) * (self.x1[j] - self.x2[j]);
                let gamma = if trend < 0.0 {
                    0.7
                } else if trend > 0.0 {
                    1.2
                } else {
                    1.0
                };
                self.low[j] = (x[j] - gamma * (self.x1[j] - self.low[j])).clamp(x[j] - 10.0 * range, x[j] - 0.01 * range);
                self.upp[j] = (x[j] + gamma * (self.upp[j] - self.x1[j])).clamp(x[j] + 0.01 * range, x[j] + 10.0 * range);
            }
            let (l, u) = (self.low[j], self.upp[j]);
            alpha[j] = xmin[j].max(l + 0.1 * (x[j] - l)).max(x[j] - MOVE * range);
            beta[j] = xmax[j].min(u - 0.1 * (u - x[j])).min(x[j] + MOVE * range);
            if beta[j] < alpha[j] {
                beta[j] = alpha[j];
            }
            let (ux, xl) = ((u - x[j]).powi(2), (x[j] - l).powi(2));
            let reg = 1e-5 / range;
            p0[j] = ux * (1.001 * df[j].max(0.0) + 0.001 * (-df[j]).max(0.0) + reg);
            q0[j] = xl * (0.001 * df[j].max(0.0) + 1.001 * (-df[j]).max(0.0) + reg);
            p1[j] = ux * (1.001 * dg[j].max(0.0) + 0.001 * (-dg[j]).max(0.0) + reg);
            q1[j] = xl * (0.001 * dg[j].max(0.0) + 1.001 * (-dg[j]).max(0.0) + reg);
            r1 -= p1[j] / (u - x[j]) + q1[j] / (x[j] - l);
        }
        let (low, upp) = (&self.low, &self.upp);
        let point = |lam: f64| -> Vec<f64> {
            (0..n)
                .map(|j| {
                    let (a, b) = ((p0[j] + lam * p1[j]).sqrt(), (q0[j] + lam * q1[j]).sqrt());
                    ((a * low[j] + b * upp[j]) / (a + b)).clamp(alpha[j], beta[j])
                })
                .collect()
        };
        let excess = |y: &[f64]| r1 + (0..n).map(|j| p1[j] / (upp[j] - y[j]) + q1[j] / (y[j] - low[j])).sum::<f64>();
        let mut next = point(0.0);
        if excess(&next) > 0.0 {
            let mut hi = 1.0;
            while excess(&point(hi)) > 0.0 && hi < 1e15 {
                hi *= 10.0;
            }
            let mut lo = 0.0f64;
            for _ in 0..100 {
                let mid = if lo > 0.0 { (lo * hi).sqrt() } else { hi / 1e6 };
                if excess(&point(mid)) > 0.0 {
                    lo = mid;
                } else {
                    hi = mid;
                }
                if hi - lo <= 1e-10 * hi {
                    break;
                }
            }
            next = point(hi);
        }
        self.x2 = std::mem::replace(&mut self.x1, x.to_vec());
        self.iter += 1;
        next
    }
}

/// The centres of the support and load regions: each gets a node.
fn anchors(study: &Study) -> Vec<V3> {
    let mut out: Vec<V3> = study.supports.iter().map(|s| s.region.center()).collect();
    for c in &study.cases {
        for l in &c.loads {
            out.push(load_region(l).center());
        }
    }
    out
}

fn load_region(l: &Load) -> &Region {
    match l {
        Load::Force { region, .. } | Load::Torque { region, .. } | Load::Pressure { region, .. } => region,
    }
}

/// The frame nodes in `region`; the node nearest its centre when none is.
fn region_nodes(study: &Study, nodes: &[V3], region: &Region) -> Vec<usize> {
    let inside: Vec<usize> = (0..nodes.len()).filter(|&v| region.contains(nodes[v])).collect();
    if !inside.is_empty() {
        return inside;
    }
    let c = region.center();
    let c: V3 = std::array::from_fn(|a| c[a].clamp(study.min[a], study.max[a]));
    (0..nodes.len()).min_by(|&a, &b| dist(nodes[a], c).total_cmp(&dist(nodes[b], c))).into_iter().collect()
}

/// Area of a region seen along unit `dir` (boxes clipped to the design space), mm².
fn projected_area(region: &Region, dir: V3, study: &Study) -> f64 {
    match region.hull() {
        Region::Tube { .. } => unreachable!("a hull is never a tube"),
        Region::Box { min, max } => {
            let s: V3 = std::array::from_fn(|a| (max[a].min(study.max[a]) - min[a].max(study.min[a])).max(0.0));
            dir[0].abs() * s[1] * s[2] + dir[1].abs() * s[0] * s[2] + dir[2].abs() * s[0] * s[1]
        }
        Region::Sphere { radius, .. } => PI * radius * radius,
        Region::Cylinder { axis, radius, length, .. } => {
            let c = super::beam::dot(unit(axis), dir).abs().min(1.0);
            PI * radius * radius * c + 2.0 * radius * length * (1.0 - c * c).sqrt()
        }
    }
}

/// Supports and loads on the ground structure's nodes, and each group's largest diameter.
fn setup(study: &Study, ground: &Ground) -> Setup {
    let n = ground.nodes.len();
    let d_hi = largest(study, ground);
    let mut cap = vec![d_hi; ground.groups];
    for (e, &g) in ground.group.iter().enumerate() {
        cap[g] = cap[g].min(2.0 * ground.clearance[e]);
    }
    let mut fixed = vec![false; 6 * n];
    for s in &study.supports {
        let all = s.fix.iter().all(|&f| f);
        for v in region_nodes(study, &ground.nodes, &s.region) {
            for a in 0..6 {
                if (a < 3 && s.fix[a]) || (a >= 3 && all) {
                    fixed[6 * v + a] = true;
                }
            }
        }
    }
    let loads = study
        .cases
        .iter()
        .map(|c| {
            let mut f = vec![0.0; 6 * n];
            for l in &c.loads {
                let (vector, offset) = match *l {
                    Load::Force { force, .. } => (force, 0),
                    Load::Torque { axis, moment, .. } => (scale(unit(axis), moment), 3),
                    Load::Pressure { ref region, direction, pressure } => {
                        let dir = unit(direction);
                        (scale(dir, pressure * projected_area(region, dir, study)), 0)
                    }
                };
                let nodes = region_nodes(study, &ground.nodes, load_region(l));
                let share = 1.0 / nodes.len() as f64;
                for v in nodes {
                    for a in 0..3 {
                        f[6 * v + offset + a] += vector[a] * share;
                    }
                }
            }
            f
        })
        .collect();
    Setup {
        nodes: ground.nodes.clone(),
        beams: ground.beams.clone(),
        group: ground.group.clone(),
        groups: ground.groups,
        cap,
        joint_cap: ground.node_clearance.clone(),
        fixed,
        loads,
        accel: study.cases.iter().map(|c| c.acceleration).collect(),
        weight: study.cases.iter().map(|c| c.weight).collect(),
    }
}

fn finite_region(r: &Region) -> bool {
    let ok = |v: &[f64]| v.iter().all(|x| x.is_finite());
    match r.hull() {
        Region::Tube { .. } => unreachable!("a hull is never a tube"),
        Region::Box { min, max } => ok(&min) && ok(&max),
        Region::Sphere { center, radius } => ok(&center) && radius.is_finite() && radius >= 0.0,
        Region::Cylinder { base, axis, radius, length } => ok(&base) && ok(&axis) && radius.is_finite() && radius >= 0.0 && length.is_finite() && length >= 0.0,
    }
}

/// Rejects a study the frame method cannot run.
fn check(study: &Study) -> Result<(), String> {
    let ok3 = |v: &[f64; 3]| v.iter().all(|x| x.is_finite());
    if !ok3(&study.min) || !ok3(&study.max) || (0..3).any(|a| study.max[a] <= study.min[a]) {
        return Err("the design space needs a finite max above min on every axis".into());
    }
    if !(study.voxel.is_finite() && study.voxel > 0.0) {
        return Err("the voxel edge must be a positive length".into());
    }
    let voxels: f64 = (0..3).map(|a| ((study.max[a] - study.min[a]) / study.voxel).round().max(1.0)).product();
    if voxels > 2e8 {
        return Err(format!("{voxels:.0} voxels is too many: choose a larger voxel"));
    }
    let m = &study.material;
    if !(m.e.is_finite() && m.e > 0.0) || !(m.nu > -1.0 && m.nu < 0.5) || !(m.density.is_finite() && m.density > 0.0) {
        return Err("the material needs a positive Young's modulus and density, and a Poisson's ratio in (-1, 0.5)".into());
    }
    let sigma = study.max_stress.unwrap_or(m.allowable / study.safety_factor);
    if !(sigma.is_finite() && sigma > 0.0) {
        return Err("the stress limit (max_stress, or the allowable over the safety factor) must be positive".into());
    }
    if study.max_displacement.is_some_and(|u| !(u.is_finite() && u > 0.0)) {
        return Err("the displacement limit must be positive".into());
    }
    if !(study.min_member.is_finite() && study.min_member > 0.0) {
        return Err("the narrowest member must be a positive diameter".into());
    }
    if study.supports.is_empty() {
        return Err("a frame needs at least one support".into());
    }
    if study.cases.is_empty() {
        return Err("a frame needs at least one load case".into());
    }
    let regions = study.supports.iter().map(|s| &s.region).chain(study.keep_out.iter()).chain(study.keep_in.iter()).chain(study.cases.iter().flat_map(|c| c.loads.iter().map(load_region)));
    for r in regions {
        if !finite_region(r) {
            return Err("every region needs finite coordinates and non-negative sizes".into());
        }
    }
    let mut any = false;
    for c in &study.cases {
        if c.acceleration.is_some_and(|a| !ok3(&a)) || !c.weight.is_finite() {
            return Err(format!("load case '{}' has a non-finite acceleration or weight", c.name));
        }
        for l in &c.loads {
            let size = match *l {
                Load::Force { force, .. } => norm(force),
                Load::Torque { axis, moment, .. } => norm(axis) * moment.abs(),
                Load::Pressure { direction, pressure, .. } => norm(direction) * pressure.abs(),
            };
            if !size.is_finite() {
                return Err(format!("load case '{}' has a non-finite load", c.name));
            }
            any |= size > 0.0;
        }
    }
    if !any {
        return Err("no load case applies a load".into());
    }
    Ok(())
}
