//! The JSON `call(op, params)` facade (RUST-ENGINES 1 and 9.1), shared by the bridge, the node
//! addon, the agent and the CLI. One [`Kin`] state holds the loaded model and a drag session.
//!
//! References to frames, joints and actuators accept a name or an index. Poses are
//! `{"xyz": [..], "quat_wxyz": [..]}` or `{"xyz": [..], "rpy": [..]}` (radians). Errors carry the
//! stable code of [`crate::error::codes`].

use serde_json::{Value, json};

use crate::analytic::Analytic6R;
use crate::drag::{Drag, DragOptions};
use crate::error::{KinError, codes};
use crate::hand::{Fingertip, solve_grasp};
use crate::ik::{AxisMask, IkOptions, IkProblem, IkTask, solve};
use crate::math::{Iso3, Vec3, pose_from_json, pose_json};
use crate::model::{FrameId, Model};
use crate::models;
use crate::path::{PathOpts, Segment, cartesian_segments};

/// Facade state: the loaded model and the drag in progress.
#[derive(Default)]
pub struct Kin {
    pub model: Option<Model>,
    pub drag: Option<Drag>,
    /// Link poses of the last drag move (for the binary entry).
    pub drag_poses: Vec<Iso3>,
}

fn perr(msg: impl Into<String>) -> KinError {
    KinError::new(codes::PARAMS, msg)
}

fn get<'a>(p: &'a Value, k: &str) -> Option<&'a Value> {
    p.get(k).filter(|v| !v.is_null())
}

fn f64_or(p: &Value, k: &str, d: f64) -> Result<f64, KinError> {
    match get(p, k) {
        None => Ok(d),
        Some(v) => v.as_f64().ok_or_else(|| perr(format!("{k} must be a number"))),
    }
}

fn vec_f64(v: &Value, what: &str) -> Result<Vec<f64>, KinError> {
    serde_json::from_value(v.clone()).map_err(|e| perr(format!("{what}: {e}")))
}

fn pose_arg(v: &Value, what: &str) -> Result<Iso3, KinError> {
    pose_from_json(v).map_err(|e| perr(format!("{what}: {e}")))
}

fn index_ref(v: &Value, len: usize, by_name: impl Fn(&str) -> Option<usize>, what: &str) -> Result<usize, KinError> {
    let i = match v {
        Value::String(s) => by_name(s).ok_or_else(|| KinError::new(codes::UNKNOWN_NAME, format!("no {what} named {s}")))?,
        Value::Number(n) => n.as_u64().ok_or_else(|| perr(format!("{what} index must be a whole number")))? as usize,
        _ => return Err(perr(format!("{what} must be a name or an index"))),
    };
    if i >= len {
        return Err(KinError::new(codes::UNKNOWN_NAME, format!("no {what} {i}")));
    }
    Ok(i)
}

fn frame_ref(m: &Model, v: Option<&Value>) -> Result<FrameId, KinError> {
    match v {
        None => {
            if m.end_effectors.is_empty() {
                Err(perr("the model has no tool frame"))
            } else {
                Ok(0)
            }
        }
        Some(v) => index_ref(v, m.end_effectors.len(), |s| m.frame_index(s), "frame"),
    }
}

fn joint_refs(m: &Model, v: Option<&Value>) -> Result<Vec<usize>, KinError> {
    let Some(v) = v else { return Ok(vec![]) };
    let arr = v.as_array().ok_or_else(|| perr("locked must be a list"))?;
    arr.iter().map(|x| index_ref(x, m.joints.len(), |s| m.joint_index(s), "joint")).collect()
}

fn q_arg(m: &Model, p: &Value, k: &str) -> Result<Vec<f64>, KinError> {
    let q = match get(p, k) {
        None => m.neutral(),
        Some(v) => vec_f64(v, k)?,
    };
    m.check_q(&q)?;
    Ok(q)
}

fn ik_options(p: &Value) -> Result<IkOptions, KinError> {
    match get(p, "options") {
        None => Ok(IkOptions::default()),
        Some(v) => serde_json::from_value(v.clone()).map_err(|e| perr(format!("options: {e}"))),
    }
}

/// Model summary for the front ends.
pub fn model_info(m: &Model) -> Value {
    let qo = m.q_offsets();
    json!({
        "name": m.name,
        "nq": m.nq(),
        "nv": m.nv(),
        "links": m.links.iter().map(|l| &l.name).collect::<Vec<_>>(),
        "joints": m.joints.iter().enumerate().map(|(j, x)| json!({"name": x.name, "kind": x.kind, "parent": x.parent, "q_index": qo[j], "limits": x.limits})).collect::<Vec<_>>(),
        "frames": m.end_effectors.iter().map(|f| json!({"name": f.name, "link": f.link, "analytic": Analytic6R::applies(m, m.frame_index(&f.name).unwrap_or(0))})).collect::<Vec<_>>(),
        "actuators": m.actuators.iter().map(|a| json!({"name": a.name, "drive": a.drive, "limits": a.limits})).collect::<Vec<_>>(),
        "neutral": m.neutral(),
    })
}

fn ik_result_json(m: &Model, r: &crate::ik::IkResult) -> Value {
    let mut v = serde_json::to_value(r).unwrap_or_default();
    v["actuator_names"] = json!(m.actuators.iter().map(|a| &a.name).collect::<Vec<_>>());
    v
}

impl Kin {
    pub fn new() -> Self {
        Kin::default()
    }

    fn model(&self) -> Result<&Model, KinError> {
        self.model.as_ref().ok_or_else(|| KinError::new(codes::MODEL_NONE, "no model is loaded (model.load)"))
    }

    /// Runs one op. Ops: `model.load`, `model.info`, `model.json`, `fk`, `jacobian`, `ik`,
    /// `ik_hand`, `path.cartesian` (alias `cartesian_path`), `ik_drag_begin`, `ik_drag_move`,
    /// `ik_drag_end`.
    pub fn call(&mut self, op: &str, p: &Value) -> Result<Value, KinError> {
        match op {
            "model.load" => {
                let m = if let Some(b) = get(p, "builtin") {
                    let name = b.as_str().ok_or_else(|| perr("builtin must be a name"))?;
                    models::builtin(name).ok_or_else(|| KinError::new(codes::UNKNOWN_NAME, format!("no built-in model {name}")))?
                } else if let Some(v) = get(p, "model") {
                    Model::from_value(v)?
                } else if let Some(path) = get(p, "path").and_then(Value::as_str) {
                    let text = std::fs::read_to_string(path).map_err(|e| KinError::new(codes::MODEL_PARSE, format!("{path}: {e}")))?;
                    Model::from_json(&text)?
                } else {
                    return Err(perr("model.load needs builtin, model or path"));
                };
                let info = model_info(&m);
                self.model = Some(m);
                self.drag = None;
                Ok(info)
            }
            "model.info" => Ok(model_info(self.model()?)),
            "model.json" => Ok(serde_json::to_value(self.model()?).unwrap_or_default()),
            "fk" => {
                let m = self.model()?;
                let q = q_arg(m, p, "q")?;
                let poses = m.fk(&q)?;
                let frames: serde_json::Map<String, Value> = m.end_effectors.iter().map(|f| (f.name.clone(), pose_json(&(poses[f.link] * f.offset)))).collect();
                Ok(json!({"links": poses.iter().map(pose_json).collect::<Vec<_>>(), "frames": frames}))
            }
            "jacobian" => {
                let m = self.model()?;
                let q = q_arg(m, p, "q")?;
                let f = frame_ref(m, get(p, "frame"))?;
                let j = m.jacobian(&q, f)?;
                let data: Vec<f64> = (0..6).flat_map(|r| (0..j.ncols()).map(move |c| (r, c))).map(|(r, c)| j[(r, c)]).collect();
                Ok(json!({"rows": 6, "cols": j.ncols(), "row_major": data}))
            }
            "ik" => {
                let m = self.model()?;
                let q0 = q_arg(m, p, "q0")?;
                let tasks_v = get(p, "tasks").and_then(Value::as_array).ok_or_else(|| perr("ik needs tasks"))?;
                let mut tasks = vec![];
                for t in tasks_v {
                    let frame = frame_ref(m, get(t, "frame"))?;
                    let target = pose_arg(get(t, "target").ok_or_else(|| perr("task needs a target"))?, "target")?;
                    let mask = match get(t, "mask") {
                        Some(v) => serde_json::from_value::<AxisMask>(v.clone()).map_err(|e| perr(format!("mask: {e}")))?,
                        None if get(t, "position_only").and_then(Value::as_bool) == Some(true) => AxisMask::position(),
                        None => AxisMask::default(),
                    };
                    tasks.push(IkTask { frame, target, weight_pos: f64_or(t, "weight_pos", 1.0)?, weight_rot: f64_or(t, "weight_rot", 1.0)?, mask, priority: get(t, "priority").and_then(Value::as_u64).unwrap_or(1) as u32 });
                }
                let mut problem = IkProblem::new(tasks, q0);
                problem.posture = get(p, "posture").map(|v| vec_f64(v, "posture")).transpose()?;
                problem.posture_weight = f64_or(p, "posture_weight", 0.0)?;
                problem.locked = joint_refs(m, get(p, "locked"))?;
                let opts = ik_options(p)?;
                let want = get(p, "solver").and_then(Value::as_str).unwrap_or("auto");
                // Analytic first for a single full-pose task on a qualifying arm.
                let single_pose = problem.tasks.len() == 1 && problem.tasks[0].mask == AxisMask::default() && problem.locked.is_empty();
                if want != "numerical" && single_pose {
                    match Analytic6R::new(m, problem.tasks[0].frame) {
                        Ok(a) => {
                            let all = get(p, "all_solutions").and_then(Value::as_bool) == Some(true);
                            if let Some(q) = a.solve_nearest(&problem.tasks[0].target, &problem.q0) {
                                let r = crate::ik::IkResult { actuators: m.to_actuators(&q), q, converged: true, iterations: 0, restarts: 0, pos_err: vec![0.0], rot_err: vec![0.0] };
                                let mut v = ik_result_json(m, &r);
                                v["solver"] = json!("analytic");
                                if all {
                                    let hint: [f64; 6] = std::array::from_fn(|i| problem.q0[a.q_index[i]]);
                                    v["solutions"] = json!(a.solve_all(&problem.tasks[0].target, &hint));
                                }
                                return Ok(v);
                            }
                        }
                        Err(e) if want == "analytic" => return Err(e),
                        Err(_) => {}
                    }
                } else if want == "analytic" {
                    return Err(KinError::new(codes::ANALYTIC_UNSUPPORTED, "the analytic solver takes one full pose task and no locked joints"));
                }
                let r = solve(m, &problem, &opts)?;
                let mut v = ik_result_json(m, &r);
                v["solver"] = json!("numerical");
                Ok(v)
            }
            "ik_hand" => {
                let m = self.model()?;
                let q0 = q_arg(m, p, "q0")?;
                let tips_v = get(p, "fingertips").and_then(Value::as_array).ok_or_else(|| perr("ik_hand needs fingertips"))?;
                let mut tips = vec![];
                for t in tips_v {
                    let frame = frame_ref(m, get(t, "frame"))?;
                    let pt = vec_f64(get(t, "point").ok_or_else(|| perr("fingertip needs a point"))?, "point")?;
                    if pt.len() != 3 {
                        return Err(perr("point needs 3 values"));
                    }
                    tips.push(Fingertip { frame, point: Vec3::new(pt[0], pt[1], pt[2]), priority: get(t, "priority").and_then(Value::as_u64).unwrap_or(1) as u32 });
                }
                let opts = ik_options(p)?;
                let g = solve_grasp(m, &tips, q0, f64_or(p, "posture_weight", 0.02)?, &opts)?;
                let mut v = serde_json::to_value(&g).unwrap_or_default();
                v["ik"] = ik_result_json(m, &g.ik);
                Ok(v)
            }
            "path.cartesian" | "cartesian_path" => {
                let m = self.model()?;
                let q = q_arg(m, p, "q_start")?;
                let frame = frame_ref(m, get(p, "frame"))?;
                let opts: PathOpts = match get(p, "opts") {
                    Some(v) => serde_json::from_value(v.clone()).map_err(|e| perr(format!("opts: {e}")))?,
                    None => PathOpts::default(),
                };
                let mut segs = vec![];
                if let Some(ws) = get(p, "waypoints").and_then(Value::as_array) {
                    for w in ws {
                        segs.push(Segment::Line { to: pose_arg(w, "waypoint")? });
                    }
                }
                if let Some(ss) = get(p, "segments").and_then(Value::as_array) {
                    for s in ss {
                        if let Some(l) = get(s, "line") {
                            segs.push(Segment::Line { to: pose_arg(l, "line")? });
                        } else if let Some(a) = get(s, "arc") {
                            let via = vec_f64(get(a, "via").ok_or_else(|| perr("arc needs via"))?, "via")?;
                            if via.len() != 3 {
                                return Err(perr("via needs 3 values"));
                            }
                            segs.push(Segment::Arc { via: Vec3::new(via[0], via[1], via[2]), to: pose_arg(get(a, "to").ok_or_else(|| perr("arc needs to"))?, "to")? });
                        } else {
                            return Err(perr("a segment is {\"line\": pose} or {\"arc\": {\"via\", \"to\"}}"));
                        }
                    }
                }
                let tr = cartesian_segments(m, &q, &segs, frame, &opts)?;
                let mut v = serde_json::to_value(&tr).unwrap_or_default();
                v["duration"] = json!(tr.t.last().copied().unwrap_or(0.0));
                Ok(v)
            }
            "ik_drag_begin" => {
                let m = self.model()?;
                let q = q_arg(m, p, "q")?;
                let frames = match get(p, "frames").and_then(Value::as_array) {
                    Some(a) => a.iter().map(|f| frame_ref(m, Some(f))).collect::<Result<Vec<_>, _>>()?,
                    None => vec![frame_ref(m, get(p, "frame"))?],
                };
                let opts = DragOptions {
                    keep_orientation: get(p, "keep_orientation").and_then(Value::as_bool).unwrap_or(frames.len() == 1),
                    locked: joint_refs(m, get(p, "locked"))?,
                    posture_weight: if get(p, "posture").and_then(Value::as_str) == Some("mid_range") { 0.05 } else { f64_or(p, "posture_weight", 0.0)? },
                    iters: get(p, "iters").and_then(Value::as_u64).unwrap_or(10) as usize,
                    analytic: get(p, "analytic").and_then(Value::as_bool).unwrap_or(true),
                };
                let d = Drag::begin(m, frames, q, opts)?;
                let v = json!({"solver": d.solver, "frames": d.frames});
                self.drag = Some(d);
                Ok(v)
            }
            "ik_drag_move" => {
                let targets: Vec<Iso3> = match (get(p, "targets").and_then(Value::as_array), get(p, "target")) {
                    (Some(a), _) => a.iter().map(|t| pose_arg(t, "target")).collect::<Result<_, _>>()?,
                    (None, Some(t)) => vec![pose_arg(t, "target")?],
                    _ => return Err(perr("ik_drag_move needs target or targets")),
                };
                let r = self.drag_move(&targets)?;
                Ok(r)
            }
            "ik_drag_end" => {
                let d = self.drag.take().ok_or_else(|| perr("no drag in progress"))?;
                let cancel = get(p, "cancel").and_then(Value::as_bool) == Some(true);
                let q = if cancel { d.q_begin } else { d.q };
                Ok(json!({"q": q, "cancelled": cancel}))
            }
            other => Err(KinError::new(codes::UNKNOWN_OP, format!("unknown op {other}"))),
        }
    }

    /// One drag move; also stores the link poses for the binary entry.
    pub fn drag_move(&mut self, targets: &[Iso3]) -> Result<Value, KinError> {
        let m = self.model.as_ref().ok_or_else(|| KinError::new(codes::MODEL_NONE, "no model is loaded"))?;
        let d = self.drag.as_mut().ok_or_else(|| perr("no drag in progress (ik_drag_begin)"))?;
        let r = d.move_to(m, targets)?.clone();
        m.fk_into(&r.q, &mut self.drag_poses);
        let mut v = ik_result_json(m, &r);
        v["solver"] = json!(d.solver);
        Ok(v)
    }
}

/// One-shot form of [`Kin::call`] for callers without state: `{"ok": result}` or
/// `{"error": message, "code": code}`.
pub fn reply(r: Result<Value, KinError>) -> Value {
    match r {
        Ok(v) => json!({"ok": v}),
        Err(e) => {
            let mut v = json!({"error": e.message, "code": e.code});
            if let Some(i) = e.index {
                v["index"] = json!(i);
            }
            v
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn facade_round_trip() {
        let mut k = Kin::new();
        assert_eq!(k.call("fk", &json!({})).unwrap_err().code, codes::MODEL_NONE);
        let info = k.call("model.load", &json!({"builtin": "so101_arm"})).unwrap();
        assert_eq!(info["nq"], 6);
        assert_eq!(info["frames"][0]["analytic"], true);
        let q = json!([0.1, 0.2, 0.3, 0.4, 0.5, 0.6]);
        let fk = k.call("fk", &json!({"q": q})).unwrap();
        let target = fk["frames"]["gripper_tip"].clone();
        let r = k.call("ik", &json!({"q0": [0, 0, 0, 0, 0.1, 0], "tasks": [{"frame": "gripper_tip", "target": target}], "all_solutions": true})).unwrap();
        assert_eq!(r["solver"], "analytic");
        assert_eq!(r["converged"], true);
        let r = k.call("ik", &json!({"q0": [0, 0, 0, 0, 0.1, 0], "solver": "numerical", "tasks": [{"frame": 0, "target": target}]})).unwrap();
        assert_eq!(r["solver"], "numerical");
        assert_eq!(r["converged"], true);
        let j = k.call("jacobian", &json!({"q": q, "frame": "gripper_tip"})).unwrap();
        assert_eq!(j["row_major"].as_array().unwrap().len(), 36);
        // Drag, then Esc restores.
        k.call("ik_drag_begin", &json!({"q": q})).unwrap();
        let moved = k.call("ik_drag_move", &json!({"target": target})).unwrap();
        assert_eq!(moved["converged"], true);
        let end = k.call("ik_drag_end", &json!({"cancel": true})).unwrap();
        assert_eq!(end["q"], q);
        // Path: 5 cm line down.
        let mut down = target.clone();
        down["xyz"][2] = json!(down["xyz"][2].as_f64().unwrap() - 0.05);
        let path = k.call("path.cartesian", &json!({"q_start": q, "waypoints": [down]})).unwrap();
        assert!(path["duration"].as_f64().unwrap() > 0.25);
        assert!(path["max_deviation"].as_f64().unwrap() < 5e-4);
        let e = reply(k.call("nope", &json!({})));
        assert_eq!(e["code"], "op.unknown");
        // Hand.
        k.call("model.load", &json!({"builtin": "hand5"})).unwrap();
        let fk = k.call("fk", &json!({})).unwrap();
        let tip = fk["frames"]["index_tip"]["xyz"].clone();
        let g = k.call("ik_hand", &json!({"fingertips": [{"frame": "index_tip", "point": tip}]})).unwrap();
        assert_eq!(g["reached"][0], true);
    }
}
