//! MJCF export without MuJoCo: the sample arm scenario's model, and the stub backend.
//! `cargo test --release -p viaform-mujoco --test export`

use serde_json::{Value, json};
use viaform_mujoco::{MjPhys, call, load};

fn assembly() -> Value {
    serde_json::from_str(include_str!("../../docs/samples/arm/assembly.json")).unwrap()
}

fn params() -> Value {
    json!({"assembly": assembly(), "scenario": {"format": "viaform-scenario", "engine": "mujoco",
        "world": {"table": {"size_m": [0.8, 0.6], "height_m": 0.05},
                  "objects": [{"id": "cube", "shape": "box", "size_m": 0.03, "mass_kg": 0.02, "pose": {"xyz": [0.2, 0.0, 0.065]}}]},
        "initial": {"pose": "home"}}})
}

#[test]
fn sample_arm_exports_to_mjcf() {
    let ex = load::export(&params()).unwrap();
    let x = &ex.xml;
    for want in ["<mujoco model=\"arm\">", "<body name=\"jaw\"", "<joint name=\"elbow\" type=\"hinge\" axis=\"0 1 0\" limited=\"true\"", "<freejoint name=\"cube_free\"/>", "type=\"plane\"", "<general name=\"gripper\" joint=\"gripper\"", "biastype=\"affine\"", "inertiafromgeom=\"false\""] {
        assert!(x.contains(want), "missing {want}");
    }
    // phys's pair filter: no arm self pairs, no parent and child, nothing between fixed bodies.
    assert!(!x.contains("geom1=\"base\" geom2=\"shoulder\""));
    assert!(!x.contains("geom1=\"ground\" geom2=\"table\""));
    assert!(x.contains("geom1=\"table\" geom2=\"cube\""));
    assert_eq!(ex.map.bodies.len(), 9);
    assert_eq!(ex.map.actuators.len(), 6);
    println!("EX sample arm MJCF: {} bytes, {} pairs, notes {:?}", x.len(), x.matches("<pair ").count(), ex.map.notes);
}

#[test]
fn stub_or_backend_answers() {
    let mut mj = MjPhys::new();
    let r = call(&mut mj, "world_new", &params());
    if viaform_mujoco::BUILT {
        assert_eq!(r["ok"]["engine"], "mujoco", "{r}");
    } else {
        assert_eq!(r["code"], "engine.unavailable");
        assert!(r["error"].as_str().unwrap().contains("MuJoCo backend not built"));
    }
    // mjcf_export with a model works in both builds.
    let x = call(&mut mj, "mjcf_export", &json!({"builtin": "so101_arm"}));
    assert!(x["ok"]["xml"].as_str().unwrap().starts_with("<!--"), "{x}");
}

#[test]
fn drone_stays_on_phys() {
    let e = load::build(&json!({"drone": {}})).err().unwrap();
    assert_eq!(e.code, "engine.unsupported");
}
