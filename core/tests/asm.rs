//! Assemble (phase 2): `assembly.json` round trips, the `.viaform` entry, the pipeline artifact,
//! one test per op, mass properties against SolidCraft, interference, the motion study, and the
//! MJCF and URDF round trips of the template arm.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use viaform_core::Workspace;
use viaform_core::asm::model::{Assembly, Component, Joint, JointType, Proxy};
use viaform_core::asm::{self, Asm, export, store, template};
use viaform_core::flow::{Build, Built, Flow, Graph, Status};

struct Tmp(PathBuf);

impl Tmp {
    fn new(tag: &str) -> Self {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("viaform-asm-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn arm() -> Asm {
    let mut a = Asm::default();
    a.call("template", &json!({"name": "arm"})).unwrap();
    a
}

fn close(a: f64, b: f64, tol: f64) -> bool {
    (a - b).abs() <= tol * (1.0 + a.abs().max(b.abs()))
}

fn boxes(a: [f64; 3], b: [f64; 3], c: [f64; 3], d: [f64; 3]) -> Assembly {
    let comp = |id: &str, min, max| Component { id: id.into(), proxy: Some(Proxy { min_mm: min, max_mm: max, mass_kg: Some(1.0) }), ..Component::default() };
    Assembly { components: vec![comp("a", a, b), comp("b", c, d)], ground: Some("a".into()), ..Assembly::default() }
}

// MARK: P2-1 model

#[test]
fn assembly_json_round_trips_and_keeps_unknown_fields() {
    let a = template::arm();
    a.validate().unwrap();
    let mut v = a.to_json();
    v["future_field"] = json!({"kept": true});
    let back = Assembly::from_json(&v).unwrap();
    assert_eq!(back.to_json(), v, "unknown fields survive (R-9)");
    let mut stripped = back.clone();
    stripped.extra.clear();
    assert_eq!(stripped, a);
    assert_eq!(a.joints.len(), 6);
    assert_eq!(a.dof(), 6);
    assert!(a.joints.iter().all(|j| j.drive() == "servo"));

    let mut newer = v.clone();
    newer["version"] = json!(2);
    assert!(Assembly::from_json(&newer).unwrap_err().contains("newer ViaForm"));
    assert!(Assembly::from_json(&json!({"format": "other"})).is_err());
}

#[test]
fn bad_models_are_refused() {
    let mut a = template::arm();
    a.joints[2].child = "shoulder".into();
    assert!(a.validate().unwrap_err().contains("placed by two joints"));
    let mut a = template::arm();
    a.joints[0].parent = "jaw".into();
    a.ground = None;
    assert!(a.validate().unwrap_err().contains("loop"));
    let mut a = template::arm();
    a.joints[2].limits.as_mut().unwrap().lower_deg = Some(200.0);
    assert!(a.validate().unwrap_err().contains("lower limit"));
    let mut a = template::arm();
    a.joints[3].axis = [0.0; 3];
    assert!(a.validate().unwrap_err().contains("no axis"));
    let mut a = template::arm();
    a.joints[0].child = "nowhere".into();
    assert!(a.validate().unwrap_err().contains("unknown component"));
}

#[test]
fn the_assembly_lives_in_the_viaform_file_beside_the_other_entries() {
    let dir = Tmp::new("zip");
    let path = dir.0.join("arm.viaform");
    let mut ws = Workspace::new(true);
    viaform_core::project::save(&mut ws, &path).unwrap();
    assert!(store::read_from(&path).unwrap().is_none(), "a project without assembly.json");

    let flow = Flow::with_graph(Graph::drone()).unwrap();
    viaform_core::flow::persist::write_into(&path, &flow).unwrap();
    let a = template::arm();
    store::write_into(&path, &a).unwrap();
    assert_eq!(store::read_from(&path).unwrap(), Some(a.clone()));
    assert!(viaform_core::flow::persist::read_from(&path).unwrap().is_some(), "flow.json kept");
    let mut back = Workspace::default();
    viaform_core::project::open(&mut back, &path).unwrap();
    assert_eq!(back.pcb.project, ws.pcb.project, "design and board kept");

    // Saving again replaces the entry rather than adding a second one.
    let mut b = a.clone();
    b.name = "arm v2".into();
    store::write_into(&path, &b).unwrap();
    assert_eq!(store::read_from(&path).unwrap().unwrap().name, "arm v2");
    let zip = zip::ZipArchive::new(std::fs::File::open(&path).unwrap()).unwrap();
    assert_eq!(zip.file_names().filter(|n| n.as_deref().is_ok_and(|n| n == "assembly.json")).count(), 1);

    // Through the facade too.
    let mut h = Asm::default();
    assert_eq!(h.call("open", &json!({"path": path})).unwrap()["found"], json!(true));
    assert_eq!(h.doc.name, "arm v2");
}

#[test]
fn the_assembly_is_a_flow_artifact_that_goes_stale_when_its_inputs_move() {
    let mut f = Flow::with_graph(Graph::drone()).unwrap();
    for id in ["design.model", "generate.frame", "electronics.board"] {
        f.produce(id, Build::summary("first")).unwrap();
    }
    let a = template::arm();
    assert_eq!(store::record(&mut f, &a).unwrap(), Built::New(1));
    assert_eq!(f.status(store::ARTIFACT), Status::Current);
    assert_eq!(store::record(&mut f, &a).unwrap(), Built::Unchanged(1), "same content, same revision");

    f.produce("generate.frame", Build::summary("thinner arms")).unwrap();
    assert_eq!(f.status(store::ARTIFACT), Status::Stale);
    assert_eq!(f.reason(store::ARTIFACT), "Frame v2 replaced v1");
    assert_eq!(f.status("simulate.flight"), Status::Empty);

    let mut b = a.clone();
    b.joints[2].damping = 0.05;
    assert!(matches!(store::record(&mut f, &b).unwrap(), Built::New(2)));
    assert_eq!(f.status(store::ARTIFACT), Status::Current);
    f.produce("design.model", Build::summary("longer forearm")).unwrap();
    assert_eq!(f.status(store::ARTIFACT), Status::Stale, "a design change marks it stale too");
    assert!(f.reason(store::ARTIFACT).contains("Model v2"), "{}", f.reason(store::ARTIFACT));

    // The command a front end sends to its pipeline handle does the same.
    let mut h = arm();
    let cmd = h.call("commit", &json!({})).unwrap()["produce"].clone();
    assert_eq!(cmd["artifact"], "assemble.assembly");
    let mut g = Flow::with_graph(Graph::drone()).unwrap();
    let r = g.command(&cmd);
    assert_eq!(r["result"], "new", "{r}");
}

// MARK: P2-2 ops

#[test]
fn op_components_add_edit_remove_and_undo() {
    let mut h = arm();
    let n = h.doc.components.len();
    h.call("add_component", &json!({"component": {"id": "camera", "parts": [{"part": "lib:arducam/ov5647", "mass_kg": 0.004}]}})).unwrap();
    assert_eq!(h.doc.components.len(), n + 1);
    assert!(h.call("add_component", &json!({"component": {"id": "camera"}})).is_err(), "duplicate id");
    h.call("edit_component", &json!({"id": "camera", "name": "Wrist camera"})).unwrap();
    assert_eq!(h.doc.component("camera").unwrap().name, "Wrist camera");
    h.call("add_joint", &json!({"joint": {"id": "camera_mount", "type": "fixed", "parent": "gripper", "child": "camera", "origin": [0, 20, 350]}})).unwrap();
    let r = h.call("remove_component", &json!({"id": "camera"})).unwrap();
    assert_eq!(r["joints_removed"], json!(["camera_mount"]));
    assert!(h.doc.component("camera").is_none());
    h.call("undo", &json!({})).unwrap();
    assert!(h.doc.component("camera").is_some() && h.doc.joint("camera_mount").is_some());
    h.call("redo", &json!({})).unwrap();
    assert!(h.doc.component("camera").is_none());
    assert!(h.call("remove_component", &json!({"id": "nope"})).is_err());
    h.call("set_ground", &json!({"component": "base"})).unwrap();
    assert!(h.call("set_ground", &json!({"component": "jaw"})).is_err(), "a placed component cannot be the ground");
}

#[test]
fn op_joints_add_edit_remove_and_drive() {
    let mut h = arm();
    let list = h.call("joints", &json!({})).unwrap();
    assert_eq!(list["joints"].as_array().unwrap().len(), 6);
    assert_eq!(list["joints"][0]["drive"], "servo");

    h.call("set_joint", &json!({"id": "elbow", "limits": {"lower_deg": -5.0, "upper_deg": 120.0, "velocity_dps": 200.0, "effort_nm": 2.9}, "damping": 0.1})).unwrap();
    let e = h.doc.joint("elbow").unwrap();
    assert_eq!(e.range(), Some((-5.0, 120.0)));
    assert_eq!(e.damping, 0.1);
    assert!(e.motor.is_some(), "an edit keeps the motor");
    assert!(h.call("set_joint", &json!({"id": "elbow", "child": "elbow"})).is_err(), "invalid edits are refused");
    assert_eq!(h.doc.joint("elbow").unwrap().child, "forearm", "and leave the joint as it was");

    let r = h.call("drive", &json!({"joint": "elbow", "value": 150.0})).unwrap();
    assert_eq!(h.q["elbow"], 120.0, "clamped at the limit");
    assert_eq!(r["held"][0]["why"], "limit");

    // A tendon drive on a new prismatic joint.
    h.call("add_component", &json!({"component": {"id": "slide", "proxy": {"min_mm": [-5, -5, 420], "max_mm": [5, 5, 430]}}})).unwrap();
    h.call("add_joint", &json!({"joint": {"id": "slider", "type": "prismatic", "parent": "jaw", "child": "slide", "origin": [0, 0, 420], "axis": [0, 0, 1],
        "limits": {"lower_mm": 0, "upper_mm": 10}, "tendon": {"actuator": "t1", "ratio": 1.0}}})).unwrap();
    assert_eq!(h.doc.joint("slider").unwrap().drive(), "tendon");
    h.call("drive", &json!({"q": {"slider": 4.0, "elbow": 0.0}})).unwrap();
    let fk = h.call("fk", &json!({})).unwrap();
    let slide = fk["poses"].as_array().unwrap().iter().find(|p| p["component"] == "slide").unwrap();
    assert!(close(slide["pos_mm"][2].as_f64().unwrap(), 4.0, 1e-9), "{slide}");
    h.call("remove_joint", &json!({"id": "slider"})).unwrap();
    assert!(h.doc.joint("slider").is_none() && !h.q.contains_key("slider"));
}

#[test]
fn op_forward_kinematics_turns_the_chain() {
    let mut h = arm();
    // Elbow at 90 degrees about +y: the forearm, straight up from (0, 0, 188), now points along +x.
    let fk = h.call("fk", &json!({"q": {"elbow": 90.0}})).unwrap();
    let pose = |id: &str| fk["poses"].as_array().unwrap().iter().find(|p| p["component"] == id).unwrap().clone();
    let m = pose("wrist")["matrix"].as_array().unwrap().iter().map(|x| x.as_f64().unwrap()).collect::<Vec<_>>();
    // The wrist's origin (0, 0, 288) maps to (100, 0, 188).
    let p = [m[0] * 0.0 + m[4] * 0.0 + m[8] * 288.0 + m[12], m[1] * 0.0 + m[5] * 0.0 + m[9] * 288.0 + m[13], m[2] * 0.0 + m[6] * 0.0 + m[10] * 288.0 + m[14]];
    assert!(close(p[0], 100.0, 1e-9) && close(p[1], 0.0, 1e-9) && close(p[2], 188.0, 1e-9), "{p:?}");
    assert_eq!(pose("upper_arm")["pos_mm"], json!([0.0, 0.0, 0.0]));
    // Saved poses drive it too.
    let ready = h.call("fk", &json!({"pose": "ready"})).unwrap();
    assert_eq!(ready["q"]["elbow"], 90.0);
}

#[test]
fn op_mass_props_adds_printed_parts_and_bought_servos_from_the_bom() {
    let mut h = arm();
    let r = h.call("mass_props", &json!({})).unwrap();
    let proxies: f64 = template::arm().components.iter().map(|c| c.proxy.as_ref().unwrap().mass_kg.unwrap()).sum();
    let servos = 6.0 * template::SERVO_MASS_G / 1000.0;
    assert!(close(r["total"]["mass_kg"].as_f64().unwrap(), proxies + servos, 1e-12), "{}", r["total"]);
    assert!(close(r["bought_mass_kg"].as_f64().unwrap(), servos, 1e-12));
    assert_eq!(r["warnings"], json!([]));
    let i = &r["total"]["inertia_kg_mm2"];
    for a in 0..3 {
        assert!(i[a][a].as_f64().unwrap() > 0.0);
        for b in 0..3 {
            assert!(close(i[a][b].as_f64().unwrap(), i[b][a].as_f64().unwrap(), 1e-12), "symmetric");
        }
    }
    // Straight up, the centre of mass sits on the z axis (the jaw is off to +x).
    let com = &r["total"]["center_of_mass_mm"];
    assert!(com[1].as_f64().unwrap().abs() < 1e-9 && com[2].as_f64().unwrap() > 40.0);
    // Folding the arm moves the centre, not the mass.
    let folded = h.call("mass_props", &json!({"pose": "ready"})).unwrap();
    assert!(close(folded["total"]["mass_kg"].as_f64().unwrap(), r["total"]["mass_kg"].as_f64().unwrap(), 1e-12));
    assert!(folded["total"]["center_of_mass_mm"][0].as_f64().unwrap() > com[0].as_f64().unwrap() + 5.0);

    // A mass override wins; a part without a mass is a warning.
    h.doc.mass_overrides.push(asm::MassOverride { component: "jaw".into(), mass_kg: 0.5, center_of_mass_mm: None, inertia_kg_mm2: None });
    h.doc.components[0].parts.push(asm::PartRef { part: "lib:unknown".into(), ..Default::default() });
    let r2 = h.call("mass_props", &json!({})).unwrap();
    assert!(close(r2["total"]["mass_kg"].as_f64().unwrap(), proxies + servos - 0.012 + 0.5, 1e-12));
    assert!(r2["warnings"][0].as_str().unwrap().contains("no mass"));

    // Body geometry at a density: 10 x 20 x 30 mm at 2.7 g/cm3 = 16.2 g.
    let mut g = Asm::new(Assembly { components: vec![Component { id: "plate".into(), bodies: vec!["Plate".into()], ..Default::default() }], ..Default::default() }).unwrap();
    let r3 = g.call("mass_props", &json!({"geometry": {"bodies": {"Plate": {"box": {"min": [0, 0, 0], "max": [10, 20, 30]}, "density_g_cm3": 2.7}}}})).unwrap();
    assert!(close(r3["total"]["mass_kg"].as_f64().unwrap(), 0.0162, 1e-9), "{}", r3["total"]);
    let ixx = 0.0162 * (400.0 + 900.0) / 12.0;
    assert!(close(r3["total"]["inertia_kg_mm2"][0][0].as_f64().unwrap(), ixx, 1e-9));
}

#[test]
fn op_mass_props_matches_solidcrafts_own_mass_query() {
    let mut ws = Workspace::new(false);
    ws.cad_execute("solid.box", &json!({"length": 40, "width": 20, "height": 10, "body_name": "Link"})).unwrap();
    ws.cad_execute("solid.cylinder", &json!({"radius": 6, "height": 30, "body_name": "Pin"})).unwrap();
    let mut h = Asm::new(Assembly { components: vec![Component { id: "link".into(), bodies: vec!["Link".into(), "Pin".into()], ..Default::default() }], ..Default::default() }).unwrap();
    let ours = h.call_with_cad("mass_props", &json!({}), &mut ws.cad).unwrap();
    assert_eq!(ours["warnings"], json!([]), "{ours}");
    let measured = ws.cad_execute("inspect.measure", &json!({"bodies": ["Link", "Pin"]})).unwrap();
    let theirs: f64 = measured["bodies"].as_array().unwrap().iter().map(|b| b["mass_g"].as_f64().unwrap() / 1000.0).sum();
    let m = ours["total"]["mass_kg"].as_f64().unwrap();
    assert!((m - theirs).abs() / theirs < 1e-3, "mass {m} vs SolidCraft {theirs}");
    let sc = ws.cad_execute("assembly.mass_properties", &json!({})).unwrap();
    let design = sc["occurrences"].as_array().unwrap().iter().find(|o| o["occurrence"] == 0).unwrap();
    let sm = &design["mass"];
    assert!((m - sm["mass_kg"].as_f64().unwrap()).abs() / m < 1e-3, "{sm}");
    for k in 0..3 {
        let a = ours["total"]["center_of_mass_mm"][k].as_f64().unwrap();
        let b = sm["center_of_mass_mm"][k].as_f64().unwrap();
        assert!((a - b).abs() < 1e-3 * (1.0 + b.abs()), "centre {k}: {a} vs {b}");
        let ia = ours["total"]["inertia_kg_mm2"][k][k].as_f64().unwrap();
        let ib = sm["inertia_world_kg_mm2"][k][k].as_f64().unwrap();
        assert!((ia - ib).abs() / ib < 1e-3, "inertia {k}: {ia} vs {ib}");
    }
}

#[test]
fn op_interference_reports_overlap_volumes_and_skips_joined_neighbours() {
    let mut h = Asm::new(boxes([0.0; 3], [10.0; 3], [5.0; 3], [15.0; 3])).unwrap();
    let r = h.call("interference", &json!({"cell_mm": 0.25})).unwrap();
    assert_eq!(r["pairs"].as_array().unwrap().len(), 1);
    let v = r["pairs"][0]["volume_mm3"].as_f64().unwrap();
    assert!((v - 125.0).abs() < 0.5, "{v}");
    // Apart, nothing.
    let mut apart = Asm::new(boxes([0.0; 3], [10.0; 3], [20.0; 3], [30.0; 3])).unwrap();
    assert_eq!(apart.call("interference", &json!({})).unwrap()["clear"], json!(true));
    // Joined, the touching pair is by design and left out unless asked.
    h.call("add_joint", &json!({"joint": {"id": "hinge", "parent": "a", "child": "b", "origin": [5, 5, 5], "axis": [0, 0, 1]}})).unwrap();
    assert_eq!(h.call("interference", &json!({})).unwrap()["clear"], json!(true));
    assert_eq!(h.call("interference", &json!({"include_adjacent": true})).unwrap()["pairs"].as_array().unwrap().len(), 1);
    // The template arm is clear at home.
    assert_eq!(arm().call("interference", &json!({})).unwrap()["clear"], json!(true));
}

#[test]
fn op_motion_study_sweeps_a_joint_and_finds_first_contact() {
    let mut h = arm();
    let r = h.call("motion_study", &json!({"study": "elbow_sweep"})).unwrap();
    let steps = r["steps"].as_array().unwrap();
    assert_eq!(steps.len(), 25);
    assert_eq!(steps[0]["value"], json!(-10.0));
    assert_eq!(steps[24]["value"], json!(135.0));
    assert_eq!(steps[0]["poses"].as_array().unwrap().len(), 7);
    assert_eq!(r["clear"], json!(true), "standing up, the elbow swings free");
    // The tip stays in the XZ plane, 232 mm (jaw origin) from the elbow at the home pose.
    let tip = steps[12]["end_effectors"].as_array().unwrap().iter().find(|e| e["component"] == "jaw").unwrap();
    assert!(tip["pos_mm"][1].as_f64().unwrap().abs() < 1e-9);

    // Upper arm laid flat along +x: folding the elbow brings the forearm down onto the base.
    h.call("save_pose", &json!({"id": "flat", "q_deg": {"shoulder_lift": 90.0}})).unwrap();
    let r = h.call("motion_study", &json!({"joint": "elbow", "pose": "flat", "steps": 30, "duration_s": 3.0})).unwrap();
    assert_eq!(r["steps"][0]["collisions"], json!([]), "clear at the start");
    let contacts = r["first_contacts"].as_array().unwrap();
    assert!(!contacts.is_empty(), "{}", r["first_contacts"]);
    assert!(contacts.iter().any(|c| c["a"] == "base" || c["b"] == "base"), "{contacts:?}");
    let first = contacts.iter().map(|c| c["value"].as_f64().unwrap()).fold(f64::INFINITY, f64::min);
    assert!(first > 30.0, "{contacts:?}");
    assert!(contacts.iter().all(|c| c["time_s"].as_f64().unwrap() > 0.0 && c["volume_mm3"].as_f64().unwrap() > 0.0));
    // An ad hoc study and a bad one.
    let r2 = h.call("motion_study", &json!({"joint": "shoulder_pan", "steps": 4, "from": 0, "to": 90})).unwrap();
    assert_eq!(r2["steps"].as_array().unwrap().len(), 5);
    assert_eq!(r2["clear"], json!(true));
    assert!(h.call("motion_study", &json!({"joint": "nope"})).is_err());
}

#[test]
fn op_save_pose_grasp_and_path() {
    let mut h = arm();
    h.call("drive", &json!({"q": {"shoulder_lift": -20.0, "elbow": 45.0}})).unwrap();
    h.call("save_pose", &json!({"id": "reach"})).unwrap();
    assert_eq!(h.doc.pose("reach").unwrap().q_deg["elbow"], 45.0);
    h.call("save_pose", &json!({"id": "reach", "q_deg": {"elbow": 400.0}})).unwrap();
    assert_eq!(h.doc.pose("reach").unwrap().q_deg["elbow"], 135.0, "saved poses are clamped, and replace by id");
    h.call("save_grasp", &json!({"grasp": {"id": "cylinder_30", "object": {"shape": "cylinder", "size_m": [0.03, 0.08]}}})).unwrap();
    h.call("save_path", &json!({"path": {"id": "pick_place", "waypoints": [{"pose": "home"}, {"pose": "reach"}]}})).unwrap();
    let back = Assembly::from_json(&h.doc.to_json()).unwrap();
    assert_eq!(back.grasps.len(), 1);
    assert_eq!(back.paths[0]["waypoints"][1]["pose"], "reach");
    assert!(h.call("save_grasp", &json!({"grasp": {}})).is_err());
}

#[test]
fn op_mate_cad_reads_the_designs_joints() {
    let mut h = Asm::new(Assembly {
        components: vec![Component { id: "Base".into(), ..Default::default() }],
        ground: Some("Base".into()),
        ..Default::default()
    })
    .unwrap();
    let inspect = json!({"joints": [
        {"name": "Hinge 1", "type": "revolute", "suppressed": false, "values": [{"name": "angle", "value": 0, "unit": "deg", "limits": [-45, 90]}],
         "a": {"occurrence_name": "Base", "component_name": "Base", "frame": {"origin": [0, 0, 10], "z": [0, 1, 0], "x": [1, 0, 0]}},
         "b": {"occurrence_name": "Arm:1", "component_name": "Arm", "frame": {"origin": [0, 0, 10], "z": [0, 1, 0], "x": [1, 0, 0]}}},
        {"name": "Cam", "type": "cam", "a": {}, "b": {}}
    ]});
    let r = h.call("mate_cad", &json!({"inspect": inspect})).unwrap();
    assert_eq!(r["warnings"].as_array().unwrap().len(), 1, "{r}");
    let j = &h.doc.joints[0];
    assert_eq!((j.id.as_str(), j.parent.as_str(), j.child.as_str()), ("hinge_1", "Base", "Arm:1"));
    assert_eq!(j.cad_joint.as_deref(), Some("Hinge 1"));
    assert_eq!(j.range(), Some((-45.0, 90.0)));
    // Mating again updates in place and keeps the drive.
    h.call("set_joint", &json!({"id": "hinge_1", "motor": {"part": "lib:feetech/STS3215"}})).unwrap();
    h.call("mate_cad", &json!({"inspect": inspect})).unwrap();
    assert_eq!(h.doc.joints.len(), 1);
    assert!(h.doc.joints[0].motor.is_some());

    // Against a real design: two parts and a revolute joint.
    let mut ws = Workspace::new(false);
    let mut run = |id: &str, p: Value| ws.cad_execute(id, &p).unwrap();
    run("component.create", json!({"name": "Base", "grounded": true}));
    run("solid.box", json!({"length": 20, "width": 20, "height": 10, "body_name": "Base Block"}));
    run("component.create", json!({"name": "Arm", "grounded": false}));
    run("solid.box", json!({"length": 10, "width": 10, "height": 40, "body_name": "Arm Block"}));
    let made = ws.cad_execute("joint.create", &json!({"type": "revolute", "a": {"occurrence": "Base", "point": [0, 0, 10]}, "b": {"occurrence": "Arm", "point": [0, 0, 10]}, "name": "Elbow"}));
    if made.is_ok() {
        let mut c = Asm::default();
        let r = c.call_with_cad("mate_cad", &json!({}), &mut ws.cad).unwrap();
        assert!(c.doc.joints.iter().any(|j| j.cad_joint.as_deref() == Some("Elbow")), "{r} {:?}", c.doc.joints);
    }
}

// MARK: P2-3 MJCF and URDF

fn same_joints(a: &Assembly, b: &Assembly) {
    assert_eq!(a.joints.len(), b.joints.len());
    for (x, y) in a.joints.iter().zip(&b.joints) {
        assert_eq!((&x.id, x.kind, &x.parent, &x.child), (&y.id, y.kind, &y.parent, &y.child));
        for k in 0..3 {
            assert!(close(x.origin[k], y.origin[k], 1e-9), "{} origin", x.id);
            assert!(close(x.axis[k], y.axis[k], 1e-12), "{} axis", x.id);
        }
        let (lx, ly) = (x.range().unwrap(), y.range().unwrap());
        assert!(close(lx.0, ly.0, 1e-9) && close(lx.1, ly.1, 1e-9), "{} range {lx:?} {ly:?}", x.id);
        assert!(close(x.effort().unwrap(), y.effort().unwrap(), 1e-12));
        assert!(close(x.velocity().unwrap(), y.velocity().unwrap(), 1e-9));
        assert!(close(x.damping, y.damping, 1e-12) && close(x.friction, y.friction, 1e-12));
        let (mx, my) = (x.motor.as_ref().unwrap(), y.motor.as_ref().unwrap());
        assert_eq!((&mx.part, mx.gear_ratio), (&my.part, my.gear_ratio));
    }
}

fn same_mass(a: &mut Asm, b: &mut Asm) {
    let ma = a.call("mass_props", &json!({"pose": "home"})).unwrap();
    let mb = b.call("mass_props", &json!({})).unwrap();
    assert!(close(ma["total"]["mass_kg"].as_f64().unwrap(), mb["total"]["mass_kg"].as_f64().unwrap(), 1e-12));
    for r in 0..3 {
        assert!(close(ma["total"]["center_of_mass_mm"][r].as_f64().unwrap(), mb["total"]["center_of_mass_mm"][r].as_f64().unwrap(), 1e-9));
        for k in 0..3 {
            let (x, y) = (ma["total"]["inertia_kg_mm2"][r][k].as_f64().unwrap(), mb["total"]["inertia_kg_mm2"][r][k].as_f64().unwrap());
            assert!((x - y).abs() < 1e-6 * (1.0 + x.abs()), "inertia {r}{k}: {x} vs {y}");
        }
    }
}

#[test]
fn template_arm_round_trips_through_urdf_with_six_joints() {
    let mut h = arm();
    let out = h.call("export_urdf", &json!({})).unwrap();
    assert_eq!(out["check"]["joints"], 6);
    assert_eq!(out["check"]["links"], 7);
    assert_eq!(out["check"]["root"], "base");
    assert_eq!(out["warnings"], json!([]));
    let text = out["text"].as_str().unwrap();
    assert_eq!(text.matches("<transmission").count(), 6);
    let mut back = Asm::default();
    back.call("import_urdf", &json!({"text": text})).unwrap();
    assert_eq!(back.doc.ground.as_deref(), Some("base"));
    same_joints(&h.doc, &back.doc);
    same_mass(&mut h, &mut back);
    // The import exports again to a URDF that imports to the same model.
    let again = back.call("export_urdf", &json!({})).unwrap();
    let mut third = Asm::default();
    third.call("import_urdf", &json!({"text": again["text"]})).unwrap();
    same_joints(&back.doc, &third.doc);
}

#[test]
fn template_arm_round_trips_through_mjcf_with_six_joints() {
    let mut h = arm();
    let out = h.call("export_mjcf", &json!({})).unwrap();
    assert_eq!(out["check"]["joints"], 6);
    assert_eq!(out["check"]["bodies"], 7);
    let text = out["text"].as_str().unwrap();
    assert_eq!(text.matches("<position ").count(), 6);
    let mut back = Asm::default();
    back.call("import_mjcf", &json!({"text": text})).unwrap();
    same_joints(&h.doc, &back.doc);
    same_mass(&mut h, &mut back);
    for (x, y) in h.doc.joints.iter().zip(&back.doc.joints) {
        assert_eq!(x.motor, y.motor, "every motor field travels in <custom>");
    }
    let again = back.call("export_mjcf", &json!({})).unwrap();
    let mut third = Asm::default();
    third.call("import_mjcf", &json!({"text": again["text"]})).unwrap();
    same_joints(&back.doc, &third.doc);
}

#[test]
fn exports_cover_every_joint_type() {
    let mut a = template::arm();
    a.components.push(Component { id: "wheel".into(), proxy: Some(Proxy { min_mm: [60.0, -5.0, 0.0], max_mm: [80.0, 5.0, 20.0], mass_kg: Some(0.05) }), ..Default::default() });
    a.components.push(Component { id: "rail".into(), proxy: Some(Proxy { min_mm: [-80.0, -5.0, 0.0], max_mm: [-60.0, 5.0, 20.0], mass_kg: Some(0.05) }), ..Default::default() });
    a.components.push(Component { id: "badge".into(), proxy: Some(Proxy { min_mm: [-5.0, 50.0, 10.0], max_mm: [5.0, 52.0, 20.0], mass_kg: Some(0.001) }), ..Default::default() });
    a.joints.push(Joint { id: "drive_wheel".into(), kind: JointType::Wheel, parent: "base".into(), child: "wheel".into(), origin: [70.0, 0.0, 10.0], axis: [0.0, 1.0, 0.0], ..Default::default() });
    a.joints.push(Joint {
        id: "rail_slide".into(),
        kind: JointType::Prismatic,
        parent: "base".into(),
        child: "rail".into(),
        origin: [-70.0, 0.0, 10.0],
        axis: [1.0, 0.0, 0.0],
        limits: Some(asm::Limits { lower_mm: Some(-20.0), upper_mm: Some(20.0), velocity_mmps: Some(50.0), effort_n: Some(30.0), ..Default::default() }),
        ..Default::default()
    });
    a.joints.push(Joint { id: "badge_mount".into(), kind: JointType::Fixed, parent: "base".into(), child: "badge".into(), origin: [0.0, 50.0, 10.0], ..Default::default() });
    let mut h = Asm::new(a.clone()).unwrap();
    h.bom = Some(template::arm_bom());
    for (exp, imp) in [("export_mjcf", "import_mjcf"), ("export_urdf", "import_urdf")] {
        let text = h.call(exp, &json!({})).unwrap()["text"].as_str().unwrap().to_owned();
        let mut back = Asm::default();
        back.call(imp, &json!({"text": text})).unwrap();
        for id in ["drive_wheel", "rail_slide", "badge_mount"] {
            let (x, y) = (a.joint(id).unwrap(), back.doc.joint(id).unwrap_or_else(|| panic!("{exp}: {id}")));
            assert_eq!((x.kind, &x.parent, &x.child), (y.kind, &y.parent, &y.child), "{exp}: {id}");
            assert_eq!(x.range(), y.range().map(|(l, u)| ((l * 1e9).round() / 1e9, (u * 1e9).round() / 1e9)), "{exp}: {id}");
        }
    }
    // A ball joint: MJCF keeps it, URDF warns.
    let mut b = template::arm();
    b.joints[4].kind = JointType::Ball;
    b.joints[4].limits = None;
    let mut hb = Asm::new(b).unwrap();
    let m = hb.call("export_mjcf", &json!({})).unwrap();
    let mut back = Asm::default();
    back.call("import_mjcf", &json!({"text": m["text"]})).unwrap();
    assert_eq!(back.doc.joint("wrist_roll").unwrap().kind, JointType::Ball);
    let u = hb.call("export_urdf", &json!({})).unwrap();
    assert!(u["warnings"].as_array().unwrap().iter().any(|w| w.as_str().unwrap().contains("no ball joint")), "{}", u["warnings"]);
}

#[test]
fn validators_refuse_broken_files() {
    let urdf = |body: &str| format!("<robot name=\"r\">{body}</robot>");
    let link = "<link name=\"a\"/><link name=\"b\"/>";
    assert!(export::validate_urdf("<robot name=\"r\"><link name=\"a\"></robot>").is_err(), "not well formed");
    assert!(export::validate_urdf("<robot><link name=\"a\"/></robot>").unwrap_err().contains("name"));
    assert!(export::validate_urdf(&urdf("<link name=\"a\"/><link name=\"a\"/>")).unwrap_err().contains("twice"));
    assert!(export::validate_urdf(&urdf(&format!("{link}<joint name=\"j\" type=\"hinge\"><parent link=\"a\"/><child link=\"b\"/></joint>"))).unwrap_err().contains("unknown type"));
    assert!(export::validate_urdf(&urdf(&format!("{link}<joint name=\"j\" type=\"revolute\"><parent link=\"a\"/><child link=\"b\"/></joint>"))).unwrap_err().contains("<limit>"));
    assert!(export::validate_urdf(&urdf(&format!("{link}<joint name=\"j\" type=\"fixed\"><parent link=\"a\"/><child link=\"c\"/></joint>"))).unwrap_err().contains("unknown link"));
    assert!(export::validate_urdf(&urdf(link)).unwrap_err().contains("one root"));
    assert!(export::validate_urdf(&urdf("<link name=\"a\"><inertial><mass value=\"1\"/></inertial></link>")).unwrap_err().contains("<inertia>"));
    assert!(export::validate_urdf(&urdf(&format!("{link}<joint name=\"j\" type=\"fixed\"><parent link=\"a\"/><child link=\"b\"/><origin xyz=\"1 2\"/></joint>"))).is_err());
    export::validate_urdf(&urdf(&format!("{link}<joint name=\"j\" type=\"fixed\"><parent link=\"a\"/><child link=\"b\"/></joint>"))).unwrap();

    let mj = |body: &str| format!("<mujoco><worldbody>{body}</worldbody></mujoco>");
    assert!(export::validate_mjcf("<mujoco/>").unwrap_err().contains("worldbody"));
    assert!(export::validate_mjcf(&mj("<body name=\"a\"/><body name=\"a\"/>")).unwrap_err().contains("twice"));
    assert!(export::validate_mjcf(&mj("<body name=\"a\"><body name=\"b\"><freejoint/></body></body>")).unwrap_err().contains("top-level"));
    assert!(export::validate_mjcf(&mj("<body name=\"a\"><joint name=\"j\" range=\"1 0\"/></body>")).unwrap_err().contains("range"));
    assert!(export::validate_mjcf(&mj("<body name=\"a\"><inertial mass=\"1\"/></body>")).unwrap_err().contains("inertia"));
    assert!(export::validate_mjcf(&format!("<mujoco><worldbody><body name=\"a\"><joint name=\"j\"/></body></worldbody><actuator><motor joint=\"k\"/></actuator></mujoco>")).unwrap_err().contains("unknown joint"));
    export::validate_mjcf(&mj("<body name=\"a\"><joint name=\"j\" axis=\"0 1 0\" range=\"-1 1\"/><geom type=\"box\" size=\"1 1 1\"/></body>")).unwrap();
}

// MARK: P2-5 arm preset and sample

#[test]
fn the_arm_preset_is_a_valid_graph_around_the_assembly() {
    let g = Graph::preset("arm").expect("arm preset");
    g.validate().unwrap();
    let asm = g.artifact("assemble.assembly").unwrap();
    for input in ["design.model", "generate.gripper", "generate.forearm", "electronics.board"] {
        assert!(asm.inputs.iter().any(|i| i == input), "{input}");
    }
    for out in ["simulate.reach", "simulate.pick", "train.policy", "render.shots", "make.bundle", "robot.session", "robot.demos"] {
        assert!(g.artifact(out).is_some(), "{out}");
    }
    let mut f = Flow::with_graph(g).unwrap();
    for id in ["design.model", "generate.gripper", "generate.forearm", "electronics.board"] {
        f.produce(id, Build::summary("first")).unwrap();
    }
    store::record(&mut f, &template::arm()).unwrap();
    f.produce("generate.gripper", Build::summary("wider jaw")).unwrap();
    assert_eq!(f.status("assemble.assembly"), Status::Stale);
    assert!(f.downstream("assemble.assembly").iter().any(|d| d == "robot.session"));
}

fn sample_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../docs/samples/arm")
}

/// The sample under docs/samples/arm is what the template generates. `VIAFORM_BLESS=1` rewrites it.
#[test]
fn the_arm_sample_matches_the_template() {
    let mut h = arm();
    let files = [
        ("assembly.json", serde_json::to_string_pretty(&h.doc.to_json()).unwrap() + "\n"),
        ("bom.json", serde_json::to_string_pretty(&template::arm_bom()).unwrap() + "\n"),
        ("flow.json", serde_json::to_string_pretty(&viaform_core::flow::persist::to_doc(&Flow::with_graph(Graph::preset("arm").unwrap()).unwrap())).unwrap() + "\n"),
        ("arm.urdf", h.call("export_urdf", &json!({})).unwrap()["text"].as_str().unwrap().to_owned()),
        ("arm.xml", h.call("export_mjcf", &json!({})).unwrap()["text"].as_str().unwrap().to_owned()),
    ];
    let dir = sample_dir();
    if std::env::var("VIAFORM_BLESS").is_ok() {
        std::fs::create_dir_all(&dir).unwrap();
        for (n, t) in &files {
            std::fs::write(dir.join(n), t).unwrap();
        }
    }
    for (n, t) in &files {
        let on_disk = std::fs::read_to_string(dir.join(n)).unwrap_or_else(|_| panic!("docs/samples/arm/{n} is missing; run with VIAFORM_BLESS=1"));
        if *n == "flow.json" {
            let a: Value = serde_json::from_str(&on_disk).unwrap();
            assert_eq!(a["graph"], serde_json::from_str::<Value>(t).unwrap()["graph"], "{n}");
        } else {
            assert_eq!(&on_disk, t, "docs/samples/arm/{n} is out of date; run with VIAFORM_BLESS=1");
        }
    }
    let back = Assembly::from_json(&serde_json::from_str(&std::fs::read_to_string(dir.join("assembly.json")).unwrap()).unwrap()).unwrap();
    assert_eq!(back, template::arm());
}
