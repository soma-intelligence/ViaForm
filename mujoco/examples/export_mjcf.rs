//! Writes the MJCF of an assembly plus scenario, to open in MuJoCo's `simulate` viewer.
//! Needs no MuJoCo library.
//!
//! `cargo run --release -p viaform-mujoco --example export_mjcf -- [assembly.json] [scenario.json] [out.xml]`
//!
//! Defaults: the sample arm (`docs/samples/arm/assembly.json`) on a table with a cube, written
//! to `docs/samples/arm/arm-scene.mjcf.xml`.

use serde_json::{Value, json};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
    let args: Vec<String> = std::env::args().skip(1).collect();
    let asm_path = args.first().cloned().unwrap_or_else(|| format!("{root}/docs/samples/arm/assembly.json"));
    let assembly: Value = serde_json::from_str(&std::fs::read_to_string(&asm_path)?)?;
    let scenario: Value = match args.get(1) {
        Some(p) => serde_json::from_str(&std::fs::read_to_string(p)?)?,
        None => json!({
            "format": "viaform-scenario", "id": "arm-scene",
            "world": {"table": {"size_m": [0.8, 0.6], "height_m": 0.05},
                      "objects": [{"id": "cube", "shape": "box", "size_m": 0.03, "mass_kg": 0.02, "pose": {"xyz": [0.2, 0.0, 0.065]}}]},
            "initial": {"pose": "home"}
        }),
    };
    let out = args.get(2).cloned().unwrap_or_else(|| format!("{root}/docs/samples/arm/arm-scene.mjcf.xml"));
    let ex = viaform_mujoco::load::export(&json!({"assembly": assembly, "scenario": scenario}))?;
    std::fs::write(&out, &ex.xml)?;
    println!("wrote {out} ({} bytes)", ex.xml.len());
    for n in &ex.map.notes {
        println!("note: {n}");
    }
    Ok(())
}
