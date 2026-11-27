//! Loads from simulation (RUST-ENGINES G3): a part's recorded wrench history, as the physics
//! engine (`viaform-phys`, `record.rs`) writes it, reduced to a few governing static load cases.
//!
//! # Input
//!
//! One or more interfaces of the part, each a [`WrenchHistory`] (SI, the part's link frame: force
//! N, torque N·m about `at` m, sampled at `t` s) and the [`Region`] of the study where that wrench
//! enters the part (a joint bore, a mounting face). The link frame sits in the study (world mm)
//! by a [`Placement`]. The struct has the same JSON shape as phys's `WrenchHistory`, so a phys
//! record maps onto it with no code in between ([`from_record`]); generative does not depend on
//! phys.
//!
//! # Method
//!
//! A static topology study cannot take thousands of time steps as load cases, and most of them
//! are dominated by a few: the classic reduction of a load time history keeps the instants where
//! some response quantity peaks (peak picking, or the "critical instant" approach), and an
//! equivalent static load set is then sized from them (Choi and Park 2002 on equivalent static
//! loads; Kang, Choi and Park 2001 on choosing the critical instants). Written here from first
//! principles:
//!
//! 1. Every sample becomes a wrench on each interface in study units: the force rotated into the
//!    study, and the moment moved to the interface's centre `c` (the point the study's torque
//!    acts about), `M_c = M_at + (at - c) × F`, then N·m to N·mm.
//! 2. Candidates, per interface: the sample of largest force norm, of largest moment norm, and
//!    the largest and smallest value of each force and moment component (twelve extremes). An
//!    extreme under `min_share` of its family's peak norm is noise and is dropped. These cover
//!    the magnitude envelope and its direction, since a part that sees +x and -x bending has to
//!    carry both.
//! 3. Each sample gets a normalised wrench vector (forces over the peak force norm, moments over
//!    the peak moment norm, per interface, so newtons and newton-millimetres weigh alike) and a
//!    severity, the sum of its normalised norms. Candidates are taken most severe first; one
//!    whose vector lies within `similarity` (cosine) of a case already kept merges into it, and
//!    the kept case is scaled up just enough to bound the merged one's force and moment norms.
//!    So every candidate is covered by a kept case in nearly the same direction and at least as
//!    large (a conservative envelope).
//! 4. At most `max_cases` are kept, the most severe. Every load is multiplied by the dynamic
//!    amplification factor (the ratio of the part's peak dynamic response to its static response
//!    under the same load, 1 when the record already resolves the dynamics) and by the load
//!    safety factor. The study's own `safety_factor` applies to stress on top: do not count the
//!    same margin twice.
//! 5. Optionally (`gravity` set, in the link frame) each case also carries the body load of the
//!    part's own mass, `g - a`, with `a` the recorded linear acceleration of the link origin. The
//!    angular acceleration's share (`alpha × r` across the part) is left out.
//!
//! `at: Some(t)` skips the reduction and gives the one sample nearest `t` ("Stress here").
//!
//! References: Choi, W. S., Park, G. J. Structural optimization using equivalent static loads at
//! all time intervals. Computer Methods in Applied Mechanics and Engineering 191, 2105 to 2122,
//! 2002. Kang, B. S., Choi, W. S., Park, G. J. Structural optimization under equivalent static
//! loads transformed from dynamic loads based on displacement. Computers and Structures 79,
//! 145 to 154, 2001.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::grid::unit;
use super::{Load, LoadCase, Region};

/// Time history of the wrench a body receives at one joint or at its contacts, in the body
/// frame: phys's record shape (SI).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WrenchHistory {
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub source: String,
    /// Sample times, s, non-decreasing.
    pub t: Vec<f64>,
    /// N.
    pub force: Vec<[f64; 3]>,
    /// N·m about `at` (empty: none).
    #[serde(default)]
    pub torque: Vec<[f64; 3]>,
    /// Point of application, m, body frame (empty: the body origin).
    #[serde(default)]
    pub at: Vec<[f64; 3]>,
    /// `[ax, ay, az, alpha_x, alpha_y, alpha_z]`, m/s² and rad/s², body frame, gravity not
    /// included (empty: none).
    #[serde(default)]
    pub accel: Vec<[f64; 6]>,
}

/// Where the link frame sits in the study: `p_study = origin + R p_link` (with `p_link` in mm).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Placement {
    /// Link origin in the study, mm.
    pub origin: [f64; 3],
    /// Link to study rotation, unit quaternion `[w, x, y, z]` (normalised here).
    pub rotation: [f64; 4],
}

impl Default for Placement {
    fn default() -> Self {
        Self { origin: [0.0; 3], rotation: [1.0, 0.0, 0.0, 0.0] }
    }
}

/// One place a recorded wrench enters the part.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Interface {
    pub history: WrenchHistory,
    /// Study region the force spreads over and the moment acts on, mm.
    pub region: Region,
    /// Point the moment is taken about, study mm; default the region's centre.
    #[serde(default)]
    pub center: Option<[f64; 3]>,
}

/// How the history is reduced.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Reduction {
    /// Most load cases kept.
    pub max_cases: usize,
    /// Cosine above which two candidates are one case.
    pub similarity: f64,
    /// Component extremes under this share of their family's peak norm are dropped.
    pub min_share: f64,
    /// Dynamic amplification factor on every load.
    pub dynamic_factor: f64,
    /// Load safety factor on every load.
    pub safety_factor: f64,
    /// Gravity in the link frame, m/s²: when set, each case carries the part's own body load.
    pub gravity: Option<[f64; 3]>,
    /// One case at the sample nearest this time, s, in place of the reduction.
    pub at: Option<f64>,
    /// Case name prefix (default: the body name).
    pub name: String,
}

impl Default for Reduction {
    fn default() -> Self {
        Self { max_cases: 8, similarity: 0.95, min_share: 0.05, dynamic_factor: 1.0, safety_factor: 1.0, gravity: None, at: None, name: String::new() }
    }
}

/// A governing load case and where it came from.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SimLoadCase {
    pub case: LoadCase,
    /// Time of the sample, s, and its index (on the first interface's samples).
    pub t: f64,
    pub sample: usize,
    /// What this case governs ("max |F|", "+Mz", ... with the interface's source).
    pub governs: Vec<String>,
    /// Applied force norm per interface, N, and moment norm, N·mm (factors included).
    pub force: Vec<f64>,
    pub moment: Vec<f64>,
    /// Extra scale from merged candidates (1: none), included in the loads.
    pub scale: f64,
}

/// The reduction's result.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SimLoads {
    pub cases: Vec<SimLoadCase>,
    /// Samples read.
    pub samples: usize,
    /// Peak force norm per interface over the run, N, and moment norm, N·mm (no factors).
    pub peak_force: Vec<f64>,
    pub peak_moment: Vec<f64>,
    /// Distinct cases beyond `max_cases`, not kept.
    pub dropped: usize,
}

impl SimLoads {
    /// The load cases alone, ready for a study's `cases`.
    pub fn load_cases(&self) -> Vec<LoadCase> {
        self.cases.iter().map(|c| c.case.clone()).collect()
    }
}

/// Reduces the interfaces' histories to governing load cases (see the module notes).
pub fn load_cases(interfaces: &[Interface], placement: &Placement, opt: &Reduction) -> Result<SimLoads, String> {
    if interfaces.is_empty() {
        return Err("no interface to read loads from".into());
    }
    for (name, v) in [("dynamic_factor", opt.dynamic_factor), ("safety_factor", opt.safety_factor)] {
        if !(v.is_finite() && v > 0.0) {
            return Err(format!("{name} must be a positive number"));
        }
    }
    if !(opt.similarity.is_finite() && opt.min_share.is_finite()) {
        return Err("similarity and min_share must be numbers".into());
    }
    for (i, f) in interfaces.iter().enumerate() {
        check_history(&f.history).map_err(|e| format!("interface {} ({}): {e}", i + 1, label(&f.history)))?;
    }
    let q = quat(placement.rotation)?;
    let master = &interfaces[0].history.t;
    let n = master.len();

    // Wrenches in study units per interface and sample: (force N, moment N·mm about the centre).
    let mut wf: Vec<Vec<[f64; 3]>> = Vec::with_capacity(interfaces.len());
    let mut wm: Vec<Vec<[f64; 3]>> = Vec::with_capacity(interfaces.len());
    for f in interfaces {
        let h = &f.history;
        let c_study = f.center.unwrap_or_else(|| f.region.center());
        let c_link = rotate_inv(q, sub(c_study, placement.origin)).map(|x| x / 1000.0);
        let (mut fs, mut ms) = (Vec::with_capacity(n), Vec::with_capacity(n));
        for &tk in master {
            let s = nearest(&h.t, tk);
            let force = h.force[s];
            let torque = h.torque.get(s).copied().unwrap_or([0.0; 3]);
            let at = h.at.get(s).copied().unwrap_or([0.0; 3]);
            let m = add(torque, cross(sub(at, c_link), force));
            fs.push(rotate(q, force));
            ms.push(rotate(q, m).map(|x| x * 1000.0));
        }
        wf.push(fs);
        wm.push(ms);
    }
    let peak = |w: &[[f64; 3]]| w.iter().map(|v| norm(*v)).fold(0.0, f64::max);
    let peak_force: Vec<f64> = wf.iter().map(|w| peak(w)).collect();
    let peak_moment: Vec<f64> = wm.iter().map(|w| peak(w)).collect();
    let fref: Vec<f64> = peak_force.iter().map(|&p| if p > 0.0 { p } else { 1.0 }).collect();
    let mref: Vec<f64> = peak_moment.iter().map(|&p| if p > 0.0 { p } else { 1.0 }).collect();

    // Normalised wrench vector and severity of a sample.
    let vector = |k: usize| -> Vec<f64> {
        let mut v = Vec::with_capacity(6 * interfaces.len());
        for i in 0..interfaces.len() {
            v.extend(wf[i][k].map(|x| x / fref[i]));
            v.extend(wm[i][k].map(|x| x / mref[i]));
        }
        v
    };
    let severity = |k: usize| (0..interfaces.len()).map(|i| norm(wf[i][k]) / fref[i] + norm(wm[i][k]) / mref[i]).sum::<f64>();

    // Candidates: (sample, what it governs).
    let multi = interfaces.len() > 1;
    let tag = |s: &str, i: usize| if multi { format!("{s} at {}", label(&interfaces[i].history)) } else { s.to_string() };
    let mut cand: Vec<(usize, String)> = Vec::new();
    if let Some(t) = opt.at {
        if !t.is_finite() {
            return Err("at must be a time in seconds".into());
        }
        cand.push((nearest(master, t), "at".into()));
    } else {
        let share = opt.min_share.max(0.0);
        for i in 0..interfaces.len() {
            for (w, family, pk) in [(&wf[i], 'F', peak_force[i]), (&wm[i], 'M', peak_moment[i])] {
                if pk <= 0.0 {
                    continue;
                }
                let k = (0..n).max_by(|&a, &b| norm(w[a]).total_cmp(&norm(w[b]))).unwrap_or(0);
                cand.push((k, tag(&format!("max |{family}|"), i)));
                for (a, axis) in ['x', 'y', 'z'].into_iter().enumerate() {
                    let hi = (0..n).max_by(|&p, &r| w[p][a].total_cmp(&w[r][a])).unwrap_or(0);
                    let lo = (0..n).min_by(|&p, &r| w[p][a].total_cmp(&w[r][a])).unwrap_or(0);
                    if w[hi][a] > 0.0 && w[hi][a] >= share * pk {
                        cand.push((hi, tag(&format!("+{family}{axis}"), i)));
                    }
                    if w[lo][a] < 0.0 && -w[lo][a] >= share * pk {
                        cand.push((lo, tag(&format!("-{family}{axis}"), i)));
                    }
                }
            }
        }
    }

    // One entry per sample, most severe first (earlier time on a tie).
    let mut samples: Vec<(usize, Vec<String>)> = Vec::new();
    for (k, t) in cand {
        match samples.iter_mut().find(|(s, _)| *s == k) {
            Some((_, tags)) => tags.push(t),
            None => samples.push((k, vec![t])),
        }
    }
    samples.sort_by(|a, b| severity(b.0).total_cmp(&severity(a.0)).then(a.0.cmp(&b.0)));

    // Greedy merge by direction.
    struct Kept {
        k: usize,
        u: Vec<f64>,
        scale: f64,
        tags: Vec<String>,
    }
    let mut kept: Vec<Kept> = Vec::new();
    for (k, tags) in samples {
        let u = unit_n(&vector(k));
        if opt.at.is_none() && u.iter().all(|&x| x == 0.0) {
            continue;
        }
        let best = kept.iter_mut().map(|c| (dot_n(&c.u, &u), c)).filter(|(cos, _)| *cos >= opt.similarity).max_by(|a, b| a.0.total_cmp(&b.0));
        match best {
            Some((_, c)) => {
                // Scale the kept case to bound this one's norms.
                for i in 0..interfaces.len() {
                    for (w, r) in [(&wf[i], fref[i]), (&wm[i], mref[i])] {
                        let (have, need) = (norm(w[c.k]), norm(w[k]));
                        if have > 1e-12 * r {
                            c.scale = c.scale.max(need / have);
                        }
                    }
                }
                c.tags.extend(tags);
            }
            None => kept.push(Kept { k, u, scale: 1.0, tags }),
        }
    }
    let max_cases = opt.max_cases.max(1);
    let dropped = kept.len().saturating_sub(max_cases);
    kept.truncate(max_cases);

    let prefix = if opt.name.is_empty() { interfaces[0].history.body.clone() } else { opt.name.clone() };
    let prefix = if prefix.is_empty() { "sim".to_string() } else { prefix };
    let base = opt.dynamic_factor * opt.safety_factor;
    let mut cases = Vec::with_capacity(kept.len());
    for c in kept {
        let factor = base * c.scale;
        let mut loads = Vec::new();
        let (mut fn_, mut mn) = (Vec::new(), Vec::new());
        for (i, f) in interfaces.iter().enumerate() {
            let force = wf[i][c.k].map(|x| x * factor);
            let m = wm[i][c.k].map(|x| x * factor);
            if norm(force) > 0.0 {
                loads.push(Load::Force { region: f.region, force });
            }
            if norm(m) > 1e-12 * mref[i] * factor {
                let center = f.center.unwrap_or_else(|| f.region.center());
                loads.push(Load::Torque { region: f.region, center, axis: unit(m), moment: norm(m) });
            }
            fn_.push(norm(force));
            mn.push(norm(m));
        }
        let acceleration = opt.gravity.map(|g| {
            let h = &interfaces[0].history;
            let a = h.accel.get(c.k).map_or([0.0; 3], |a| [a[0], a[1], a[2]]);
            rotate(q, sub(g, a)).map(|x| x * 1000.0 * factor)
        });
        let t = master[c.k];
        cases.push(SimLoadCase {
            case: LoadCase { name: format!("{prefix} t={t:.3} s ({})", c.tags.join(", ")), loads, acceleration, weight: 1.0 },
            t,
            sample: c.k,
            governs: c.tags,
            force: fn_,
            moment: mn,
            scale: c.scale,
        });
    }
    Ok(SimLoads { cases, samples: n, peak_force, peak_moment, dropped })
}

/// The history of `body` at `source` in a phys record: the `wrench_history` op's answer (an
/// array, bare or as `{"ok": [...]}`), a recorder (`{"wrenches": [...]}`), or one history.
/// `source` may be empty when the body has one history in the record.
pub fn from_record(record: &Value, body: &str, source: &str) -> Result<WrenchHistory, String> {
    let list: Vec<WrenchHistory> = match record {
        Value::Array(_) => serde_json::from_value(record.clone()).map_err(|e| format!("record: {e}"))?,
        Value::Object(o) if o.contains_key("ok") => return from_record(&o["ok"], body, source),
        Value::Object(o) if o.contains_key("wrenches") => return from_record(&o["wrenches"], body, source),
        Value::Object(_) => vec![serde_json::from_value(record.clone()).map_err(|e| format!("record: {e}"))?],
        _ => return Err("record: expected phys wrench histories".into()),
    };
    let hits: Vec<WrenchHistory> = list.into_iter().filter(|h| (body.is_empty() || h.body == body) && (source.is_empty() || h.source == source)).collect();
    match hits.len() {
        1 => Ok(hits.into_iter().next().unwrap_or_default()),
        0 => Err(format!("record: no wrench history for body '{body}' source '{source}'")),
        k => Err(format!("record: {k} histories match body '{body}' source '{source}': name the source")),
    }
}

/// The JSON op `loads_from_record`:
/// `{record, body, interfaces: [{source, region, center?}], placement?, max_cases?, similarity?,
/// min_share?, dynamic_factor?, safety_factor?, gravity?, at?, name?}` to [`SimLoads`] as JSON.
pub fn loads_from_record(request: &Value) -> Result<Value, String> {
    #[derive(Deserialize)]
    struct Side {
        #[serde(default)]
        source: String,
        region: Region,
        #[serde(default)]
        center: Option<[f64; 3]>,
    }
    #[derive(Deserialize)]
    struct Request {
        record: Value,
        #[serde(default)]
        body: String,
        interfaces: Vec<Side>,
        #[serde(default)]
        placement: Placement,
        #[serde(flatten)]
        reduction: Reduction,
    }
    let r: Request = serde_json::from_value(request.clone()).map_err(|e| format!("request: {e}"))?;
    let interfaces = r
        .interfaces
        .into_iter()
        .map(|s| Ok(Interface { history: from_record(&r.record, &r.body, &s.source)?, region: s.region, center: s.center }))
        .collect::<Result<Vec<_>, String>>()?;
    let out = load_cases(&interfaces, &r.placement, &r.reduction)?;
    serde_json::to_value(out).map_err(|e| e.to_string())
}

fn label(h: &WrenchHistory) -> String {
    match (h.body.is_empty(), h.source.is_empty()) {
        (false, false) => format!("{} {}", h.body, h.source),
        (false, true) => h.body.clone(),
        (true, false) => h.source.clone(),
        (true, true) => "history".into(),
    }
}

fn check_history(h: &WrenchHistory) -> Result<(), String> {
    let n = h.t.len();
    if n == 0 {
        return Err("no samples".into());
    }
    if h.force.len() != n {
        return Err(format!("{} forces for {n} times", h.force.len()));
    }
    for (name, len) in [("torques", h.torque.len()), ("points", h.at.len()), ("accelerations", h.accel.len())] {
        if len != 0 && len != n {
            return Err(format!("{len} {name} for {n} times"));
        }
    }
    if h.t.iter().any(|t| !t.is_finite()) || h.t.windows(2).any(|w| w[1] < w[0]) {
        return Err("times must be finite and non-decreasing".into());
    }
    let bad = |v: &[f64]| v.iter().any(|x| !x.is_finite());
    if h.force.iter().any(|v| bad(v)) || h.torque.iter().any(|v| bad(v)) || h.at.iter().any(|v| bad(v)) || h.accel.iter().any(|v| bad(v)) {
        return Err("a sample is not finite".into());
    }
    Ok(())
}

/// Index of the sample of `t` (sorted) nearest `x`.
fn nearest(t: &[f64], x: f64) -> usize {
    let i = t.partition_point(|&v| v < x);
    if i == 0 {
        0
    } else if i >= t.len() {
        t.len() - 1
    } else if (t[i] - x).abs() < (x - t[i - 1]).abs() {
        i
    } else {
        i - 1
    }
}

fn quat(q: [f64; 4]) -> Result<[f64; 4], String> {
    let n = q.iter().map(|x| x * x).sum::<f64>().sqrt();
    if !(n.is_finite() && n > 0.0) {
        return Err("placement rotation must be a non-zero quaternion [w, x, y, z]".into());
    }
    Ok(q.map(|x| x / n))
}

/// `q v q*` for a unit quaternion.
fn rotate(q: [f64; 4], v: [f64; 3]) -> [f64; 3] {
    let (w, u) = (q[0], [q[1], q[2], q[3]]);
    let t = cross(u, v).map(|x| 2.0 * x);
    add(add(v, t.map(|x| w * x)), cross(u, t))
}

fn rotate_inv(q: [f64; 4], v: [f64; 3]) -> [f64; 3] {
    rotate([q[0], -q[1], -q[2], -q[3]], v)
}

fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

fn norm(a: [f64; 3]) -> f64 {
    (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt()
}

fn dot_n(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn unit_n(v: &[f64]) -> Vec<f64> {
    let n = dot_n(v, v).sqrt();
    if n > 0.0 { v.iter().map(|x| x / n).collect() } else { vec![0.0; v.len()] }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const END: Region = Region::Box { min: [-1.0, -1.0, -1.0], max: [1.0, 1.0, 1.0] };

    fn history(t: Vec<f64>, force: Vec<[f64; 3]>, torque: Vec<[f64; 3]>) -> WrenchHistory {
        WrenchHistory { body: "arm".into(), source: "joint:tip".into(), t, force, torque, ..Default::default() }
    }

    fn one(h: WrenchHistory) -> Vec<Interface> {
        vec![Interface { history: h, region: END, center: None }]
    }

    fn force_of(c: &SimLoadCase) -> [f64; 3] {
        c.case.loads.iter().find_map(|l| if let Load::Force { force, .. } = l { Some(*force) } else { None }).unwrap_or([0.0; 3])
    }

    fn torque_of(c: &SimLoadCase) -> Option<([f64; 3], f64)> {
        c.case.loads.iter().find_map(|l| if let Load::Torque { axis, moment, .. } = l { Some((*axis, *moment)) } else { None })
    }

    /// A 1 N sine along x with a 10 N spike along z at t = 0.5 s: three cases, the spike (max
    /// |F| and +Fz), the sine's crest (+Fx) and trough (-Fx).
    #[test]
    fn a_spike_and_a_sine_give_three_cases_at_their_peaks() {
        let n = 1001;
        let t: Vec<f64> = (0..n).map(|k| k as f64 / 1000.0).collect();
        let force: Vec<[f64; 3]> = t.iter().map(|&s| [(2.0 * std::f64::consts::PI * s).sin(), 0.0, if (s - 0.5).abs() < 1e-9 { 10.0 } else { 0.0 }]).collect();
        let out = load_cases(&one(history(t, force, vec![])), &Placement::default(), &Reduction::default()).unwrap();
        println!("G3 synthetic: {} cases from {} samples: {:?}", out.cases.len(), out.samples, out.cases.iter().map(|c| (c.t, c.governs.join("|"))).collect::<Vec<_>>());
        assert_eq!(out.cases.len(), 3);
        let spike = &out.cases[0];
        assert_eq!(spike.t, 0.5);
        assert!(spike.governs.contains(&"max |F|".to_string()) && spike.governs.contains(&"+Fz".to_string()));
        assert!((force_of(spike)[2] - 10.0).abs() < 1e-12);
        let crest = out.cases.iter().find(|c| c.governs.contains(&"+Fx".to_string())).unwrap();
        assert!((crest.t - 0.25).abs() < 1e-12 && (force_of(crest)[0] - 1.0).abs() < 1e-9);
        let trough = out.cases.iter().find(|c| c.governs.contains(&"-Fx".to_string())).unwrap();
        assert!((trough.t - 0.75).abs() < 1e-12 && (force_of(trough)[0] + 1.0).abs() < 1e-9);
        assert!(out.cases.iter().all(|c| torque_of(c).is_none()));
        assert_eq!(out.peak_force, vec![10.0]);
    }

    /// Two samples in nearly the same direction, one with the larger force, the other with the
    /// larger moment: one case, scaled so it bounds both.
    #[test]
    fn similar_peaks_merge_into_one_bounding_case() {
        let h = history(vec![0.0, 0.1, 0.2], vec![[10.0, 0.0, 0.0], [9.5, 0.0, 0.0], [0.0; 3]], vec![[0.0, 0.0, 0.5], [0.0, 0.0, 0.6], [0.0; 3]]);
        let out = load_cases(&one(h), &Placement::default(), &Reduction::default()).unwrap();
        assert_eq!(out.cases.len(), 1, "{:?}", out.cases.iter().map(|c| &c.governs).collect::<Vec<_>>());
        let c = &out.cases[0];
        assert_eq!(c.sample, 1, "the more severe sample leads");
        assert!((c.scale - 10.0 / 9.5).abs() < 1e-12);
        assert!(norm(force_of(c)) >= 10.0 - 1e-9);
        let (axis, m) = torque_of(c).unwrap();
        assert!(m >= 600.0 && (axis[2] - 1.0).abs() < 1e-12, "moment {m} N mm about {axis:?}");
        assert!(c.governs.contains(&"max |F|".to_string()) && c.governs.contains(&"max |M|".to_string()));
        // Below the similarity they stay apart.
        let h = history(vec![0.0, 0.1], vec![[10.0, 0.0, 0.0], [0.0, 9.0, 0.0]], vec![]);
        assert_eq!(load_cases(&one(h), &Placement::default(), &Reduction::default()).unwrap().cases.len(), 2);
    }

    /// Units, the moment moved to the region centre, the placement's rotation, and factors.
    #[test]
    fn units_offset_rotation_and_factors() {
        // 10 N along z at x = 10 mm from the centre: -0.1 N m about y, -100 N mm.
        let mut h = history(vec![0.0], vec![[0.0, 0.0, 10.0]], vec![[0.0; 3]]);
        h.at = vec![[0.01, 0.0, 0.0]];
        let opt = Reduction { dynamic_factor: 1.3, safety_factor: 1.5, ..Reduction::default() };
        let out = load_cases(&one(h.clone()), &Placement::default(), &opt).unwrap();
        let c = &out.cases[0];
        assert!((force_of(c)[2] - 19.5).abs() < 1e-12);
        let (axis, m) = torque_of(c).unwrap();
        assert!((m - 195.0).abs() < 1e-9 && (axis[1] + 1.0).abs() < 1e-12, "{m} {axis:?}");
        // Link turned 90 degrees about z and moved: the region still sits on the link point.
        let s = std::f64::consts::FRAC_1_SQRT_2;
        let place = Placement { origin: [100.0, 0.0, 0.0], rotation: [s, 0.0, 0.0, s] };
        h.force = vec![[10.0, 0.0, 0.0]];
        h.at = vec![[0.0; 3]];
        let iface = vec![Interface { history: h, region: END, center: Some([100.0, 0.0, 0.0]) }];
        let c = &load_cases(&iface, &place, &Reduction::default()).unwrap().cases[0];
        let f = force_of(c);
        assert!(f[0].abs() < 1e-12 && (f[1] - 10.0).abs() < 1e-12, "{f:?}");
        assert!(torque_of(c).is_none());
    }

    #[test]
    fn at_picks_the_nearest_sample_and_gravity_loads_the_mass() {
        let mut h = history(vec![0.0, 0.1, 0.2], vec![[1.0, 0.0, 0.0], [2.0, 0.0, 0.0], [3.0, 0.0, 0.0]], vec![]);
        h.accel = vec![[0.0; 6], [0.0, 0.0, 2.0, 0.0, 0.0, 0.0], [0.0; 6]];
        let opt = Reduction { at: Some(0.12), gravity: Some([0.0, 0.0, -9.81]), ..Reduction::default() };
        let out = load_cases(&one(h), &Placement::default(), &opt).unwrap();
        assert_eq!(out.cases.len(), 1);
        let c = &out.cases[0];
        assert_eq!(c.sample, 1);
        assert_eq!(force_of(c), [2.0, 0.0, 0.0]);
        let a = c.case.acceleration.unwrap();
        assert!((a[2] + 11_810.0).abs() < 1e-9, "{a:?}");
    }

    #[test]
    fn bad_histories_are_reported() {
        let h = history(vec![0.0, 0.1], vec![[1.0, 0.0, 0.0]], vec![]);
        let e = load_cases(&one(h), &Placement::default(), &Reduction::default()).unwrap_err();
        assert!(e.contains("1 forces for 2 times"), "{e}");
        let h = history(vec![0.1, 0.0], vec![[1.0, 0.0, 0.0]; 2], vec![]);
        assert!(load_cases(&one(h), &Placement::default(), &Reduction::default()).is_err());
        assert!(load_cases(&[], &Placement::default(), &Reduction::default()).is_err());
    }

    /// The JSON op reads phys's `wrench_history` answer as it comes out of the facade.
    #[test]
    fn the_json_op_reads_a_phys_record() {
        let z3 = json!([[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]);
        let z6 = json!([[0.0, 0.0, 0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]]);
        let h = |source: &str, force: Value| json!({"body": "arm", "source": source, "t": [0.0, 0.1], "force": force, "torque": z3, "at": z3, "accel": z6});
        let rec = json!({"ok": [
            h("joint:base", json!([[0.0, 0.0, 5.0], [0.0, 0.0, 5.0]])),
            h("joint:tip", json!([[1.0, 0.0, 0.0], [0.0, 0.0, -4.0]])),
            h("contacts", z3.clone()),
        ]});
        let req = json!({"record": rec, "body": "arm", "interfaces": [{"source": "joint:tip", "region": {"shape": "sphere", "center": [0.0, 0.0, 0.0], "radius": 2.0}}], "safety_factor": 2.0});
        let out = loads_from_record(&req).unwrap();
        let cases = out["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 2);
        assert_eq!(cases[0]["case"]["loads"][0]["force"], json!([0.0, 0.0, -8.0]));
        let e = loads_from_record(&json!({"record": req["record"], "body": "arm", "interfaces": [{"region": {"shape": "sphere", "center": [0.0, 0.0, 0.0], "radius": 2.0}}]})).unwrap_err();
        assert!(e.contains("name the source"), "{e}");
    }
}
