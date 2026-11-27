//! JSON facade.

use serde_json::json;
use viaform_fluid::call;

#[test]
fn ops_and_errors() {
    assert_eq!(call("version", &json!({})).unwrap()["lattice"], "D3Q19");
    assert!(
        call("presets", &json!({})).unwrap()["air"]["viscosity"]
            .as_f64()
            .unwrap()
            > 1e-5
    );
    let u = call("units", &json!({"voxel_mm": 1.0, "inlet_velocity": 5.0})).unwrap();
    assert!((u["u_lattice"].as_f64().unwrap() - 0.1 / 3f64.sqrt()).abs() < 1e-12);
    assert_eq!(call("nope", &json!({})).unwrap_err().code, "unknown_op");
    assert_eq!(
        call("run", &json!({"domain_mm": [10, 10, 10]}))
            .unwrap_err()
            .code,
        "bad_params"
    );
    assert_eq!(
        call(
            "run",
            &json!({"domain_mm": [1000, 1000, 1000], "voxel_mm": 1, "inlet_velocity": 1})
        )
        .unwrap_err()
        .code,
        "too_large"
    );
    assert_eq!(
        call(
            "run",
            &json!({"domain_mm": [10, 10, 10], "voxel_mm": 1, "inlet_velocity": 1, "mask": [1, 0]})
        )
        .unwrap_err()
        .code,
        "bad_mask"
    );
}

#[test]
fn run_a_heated_block_in_water() {
    // A 4 mm cube in a 40 x 16 x 16 mm air channel at 0.5 m/s, held at 40 C, inlet 20 C.
    let r = call(
        "run",
        &json!({
            "domain_mm": [40, 16, 16],
            "voxel_mm": 0.5,
            "fluid": "air",
            "inlet_velocity": 0.5,
            "mach": 0.1,
            "obstacles": [{"type": "box", "min": [10, 6, 6], "max": [14, 10, 10]}],
            "steps": 6000,
            "tolerance": 1e-5,
            "thermal": {"inlet_c": 20, "obstacle_c": 40},
            "field_stride": 4
        }),
    )
    .unwrap();
    println!(
        "{}",
        serde_json::to_string_pretty(&{
            let mut v = r.clone();
            v["fields"] = json!("...");
            v
        })
        .unwrap()
    );
    assert_eq!(r["grid"], json!([80, 32, 32]));
    let drag = r["drag_n"].as_f64().unwrap();
    assert!(drag > 0.0);
    // Re about 150 on a 4 mm cube: cD of a cube is O(1), between 0.5 and 5 with this blockage.
    let cd = r["cd"].as_f64().unwrap();
    assert!(cd > 0.5 && cd < 5.0, "cd {cd}");
    assert!(
        r["lift_n"].as_f64().unwrap().abs() < 0.05 * drag,
        "a symmetric cube has no lift"
    );
    assert!(r["pressure_drop_pa"].as_f64().unwrap() > 0.0);
    assert!(r["max_velocity_ms"].as_f64().unwrap() > 0.5);
    let th = &r["thermal"];
    assert!(
        th["heat_w"].as_f64().unwrap() > 0.0,
        "heat flows into the air"
    );
    assert!(th["max_fluid_c"].as_f64().unwrap() <= 40.0 + 1e-9);
    assert!(th["outlet_mean_c"].as_f64().unwrap() > 20.0);
    assert_eq!(r["fields"]["dims"], json!([20, 8, 8]));
    assert_eq!(
        r["fields"]["velocity_ms"].as_array().unwrap().len(),
        20 * 8 * 8
    );
}
