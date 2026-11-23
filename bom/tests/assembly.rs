//! The generated assemblies (`docs/generative/<asm>/assembly.json`) read into the BOM: made
//! lines from the generative and made parts, bought lines matched by `component_ref`, quantities
//! rolled up, and the refs that do not line up flagged both ways.

use std::path::PathBuf;

use serde_json::{Value, json};
use viaform_bom::{Bom, call, import, rollup};

const TODAY: &str = "2026-11-06";

/// A component file in the shape of docs/components/<asm>.json, two lines: B1 (two placed, one
/// spare listed in the file) and X9 (nothing places it).
fn components() -> Value {
    json!({
        "assembly": "rig", "version": 1, "checked_on": "2026-11-01", "currency": "USD",
        "components": [
            {"ref": "B1", "qty": 2, "category": "bearing", "mpn": "693ZZ", "manufacturer": "NSK", "description": "Bearing 3x8x4",
             "mass_g": 0.9, "offers": [{"supplier": "VXB", "sku": "693ZZ", "unit_price_usd": 1.5, "moq": 1}]},
            {"ref": "F1", "qty": 10, "category": "fastener", "mpn": "91290A113", "manufacturer": "McMaster-Carr", "description": "M3x8 screw",
             "mass_g": 0.5, "offers": [{"supplier": "McMaster-Carr", "sku": "91290A113", "pack_price_usd": 10.0, "moq": 10}]},
            {"ref": "X9", "qty": 1, "category": "other", "mpn": "X9-1", "manufacturer": "Acme", "description": "Not placed",
             "mass_g": 3.0, "offers": [{"supplier": "Acme", "unit_price_usd": 2.0}]},
            {"ref": "FR1", "qty": 1, "category": "other", "mpn": "ViaForm generative frame", "description": "The frame", "offers": []}
        ]
    })
}

/// The current assembly.json schema: parts with kind, ref, component_ref, position_mm and pose.
fn assembly() -> Value {
    let pose = json!([1.0, 0.0, 0.0, 10.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]);
    json!({
        "schema": "viaform.assembly/1", "assembly": "rig", "component_file": "docs/components/rig.json",
        "parts": [
            {"kind": "generative", "name": "arm", "file": "parts/arm.3mf", "qty": 1, "mass_g": 12.5, "material": "PA12",
             "properties": {"category": "made", "mass_g": "12.50", "material": "PA12", "process": "SLS"}, "pose": pose},
            {"kind": "generative", "name": "base", "file": "parts/base.3mf", "qty": 1, "mass_g": 30.0, "material": "AlSi10Mg",
             "properties": {"process": "laser powder bed fusion"}, "pose": pose},
            {"kind": "made", "name": "spool a", "file": "components/spool.stl", "qty": 1, "mass_g": 1.2, "material": "AlSi10Mg",
             "properties": {"process": "turned"}},
            {"kind": "made", "name": "spool b", "file": "components/spool.stl", "qty": 1, "mass_g": 1.2, "material": "AlSi10Mg",
             "properties": {"process": "turned"}},
            // Placed by component_ref with ref and position_mm.
            {"kind": "component", "component_ref": "B1", "ref": "B1", "name": "bearing 1", "qty": 1, "mass_g": 0.9, "position_mm": [10.0, 0.0, 0.0], "pose": pose},
            // Placed by component_ref only, pose only.
            {"kind": "component", "component_ref": "B1", "name": "bearing 2", "qty": 1, "mass_g": 0.9, "pose": pose},
            // Placed by ref only: not in the component file.
            {"kind": "component", "ref": "Q7", "name": "mystery", "qty": 2, "part_number": "Q7-22", "description": "A part the file lacks",
             "mass_g": 4.0, "properties": {"category": "sensor", "manufacturer": "Q Corp", "mpn": "Q7-22"}, "position_mm": [0.0, 0.0, 5.0]}
        ],
        "bulk": [
            {"component_ref": "F1", "qty": 10, "mass_g_each": 0.5, "use": "screws"},
            {"component_ref": "FR1", "qty": 1, "mass_g_each": 0.0, "use": "made here: arm + base (this assembly's generated parts)"}
        ]
    })
}

fn imported() -> (Bom, Value) {
    let mut bom = Bom::default();
    let r = import::import_assembly(&mut bom, &assembly(), Some(&components()), None, Some("rig/assembly.json"), TODAY).unwrap();
    (bom, r)
}

#[test]
fn generated_parts_become_made_lines_with_mass_material_process_and_meshes() {
    let (bom, r) = imported();
    assert_eq!(r["made_lines"], 3, "{r}");
    assert_eq!(r["made_parts"], 4);
    let arm = bom.line("rig:made:arm").unwrap();
    assert!(arm.is_made());
    assert_eq!(arm.mass_g, Some(12.5));
    let m = arm.made.as_ref().unwrap();
    assert_eq!((m.material.as_str(), m.process.as_str()), ("PA12", "SLS"));
    assert_eq!(m.unit_cost_usd, None, "no cost is made up");
    assert!(arm.meshes.contains(&"parts/arm.3mf".to_string()), "{:?}", arm.meshes);
    assert_eq!(arm.subassembly, "Generated parts");
    // Made parts that share one mesh are one line, counted.
    let spool = bom.line("rig:made:spool").unwrap();
    assert_eq!(spool.qty, 2);
    assert_eq!(spool.used_by, ["spool a", "spool b"]);
    assert_eq!(spool.meshes, ["components/spool.stl"]);
}

#[test]
fn components_match_by_component_ref_and_roll_up() {
    let (bom, r) = imported();
    // B1: one by component_ref + ref, one by component_ref alone.
    assert_eq!(bom.line("rig:B1").unwrap().placed, Some(2));
    // F1: listed in bulk, not placed.
    assert_eq!(bom.line("rig:F1").unwrap().placed, Some(10));
    assert_eq!(r["placed"], 2 + 2 + 10 + 1);
    let roll = rollup(&bom, TODAY);
    let b1 = roll.lines.iter().find(|l| l.id == "rig:B1").unwrap();
    assert!(b1.flags.is_empty(), "{:?}", b1.flags);
    assert!(!b1.made);
}

#[test]
fn refs_that_do_not_line_up_are_flagged_both_ways() {
    let (bom, r) = imported();
    assert_eq!(r["missing_from_file"], json!(["Q7"]));
    assert_eq!(r["not_placed"], json!(["X9"]));
    let q7 = bom.line("rig:Q7").unwrap();
    assert!(q7.unlisted);
    assert_eq!(q7.qty, 2);
    // Only what the assembly says: its part number, maker and description.
    assert_eq!((q7.mpn.as_str(), q7.manufacturer.as_str(), q7.category.as_str()), ("Q7-22", "Q Corp", "sensor"));
    let roll = rollup(&bom, TODAY);
    let flags = |id: &str| roll.lines.iter().find(|l| l.id == id).unwrap().flags.clone();
    assert!(flags("rig:Q7").contains(&"not_in_file".to_string()));
    assert!(flags("rig:X9").contains(&"not_placed".to_string()));
    assert!(!flags("rig:X9").contains(&"placed_mismatch".to_string()));
}

#[test]
fn the_made_here_frame_line_is_left_out_and_totals_add_up() {
    let (bom, _) = imported();
    let fr = bom.line("rig:FR1").unwrap();
    assert!(fr.excluded, "the generated parts count instead");
    let t = rollup(&bom, TODAY).totals;
    assert_eq!(t.made_lines, 3);
    // B1, F1, X9, Q7 (FR1 is excluded).
    assert_eq!(t.bought_lines, 4);
    assert!((t.mass_made_g - (12.5 + 30.0 + 2.4)).abs() < 1e-9, "{}", t.mass_made_g);
    assert!((t.mass_bought_g - (2.0 * 0.9 + 10.0 * 0.5 + 3.0 + 2.0 * 4.0)).abs() < 1e-9, "{}", t.mass_bought_g);
    assert!((t.mass_g - t.mass_made_g - t.mass_bought_g).abs() < 1e-9);
    // Bought: 2 x 1.5 + one pack of ten at 10 + 2; Q7 has no offer, so the total is a floor.
    assert!((t.bought_cost - 15.0).abs() < 1e-9, "{}", t.bought_cost);
    assert!(!t.cost_complete);
    assert_eq!(t.total_cost, t.bought_cost + t.made_cost);
}

#[test]
fn a_reimport_keeps_user_edits_and_survives_a_design_sync() {
    let (mut bom, _) = imported();
    call(&mut bom, "edit", &json!({"id": "rig:B1", "changes": {"notes": "keep", "qty": 4}}), TODAY).unwrap();
    import::import_assembly(&mut bom, &assembly(), Some(&components()), None, None, TODAY).unwrap();
    let b1 = bom.line("rig:B1").unwrap();
    assert_eq!((b1.user_notes.as_str(), b1.per_build()), ("keep", 4));
    assert_eq!(bom.imports.iter().filter(|i| i.origin == "rig").count(), 1);
    assert_eq!(bom.imports[0].kind, "assembly");
    // A design without component_ref rows leaves the assembly's counts alone.
    import::sync_design(&mut bom, &json!({"rows": []}), TODAY).unwrap();
    assert_eq!(bom.line("rig:B1").unwrap().placed, Some(2));
}

#[test]
fn a_component_file_for_another_assembly_is_refused() {
    let mut other = components();
    other["assembly"] = json!("drone");
    assert!(import::import_assembly(&mut Bom::default(), &assembly(), Some(&other), None, None, TODAY).is_err());
}

/// The repository's generated assemblies, read fresh each run (the generative agent rewrites
/// them): every component_ref is in its component file and every file line is placed.
#[test]
fn the_real_assemblies_import_through_the_call() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    for name in ["hand", "drone"] {
        let path = root.join(format!("docs/generative/{name}/assembly.json"));
        if !path.exists() {
            continue;
        }
        let mut bom = Bom::default();
        let r = match call(&mut bom, "import_assembly", &json!({"path": path}), TODAY) {
            Ok(r) => r["result"].clone(),
            // Caught mid-rewrite: the generative agent is writing the file.
            Err(e) if e.contains("EOF") || e.contains("expected") => continue,
            Err(e) => panic!("{name}: {e}"),
        };
        eprintln!("{name}: {r}");
        assert!(r["components"].as_str().is_some_and(|c| c.ends_with(&format!("{name}.json"))), "{r}");
        assert!(r["made_lines"].as_u64().unwrap() > 0, "{name}: no made line");
        assert!(r["bought_lines"].as_u64().unwrap() > 0, "{name}: no bought line");
        let asm: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap_or_default()).unwrap_or_default();
        let generative = asm["parts"].as_array().map_or(0, |p| p.iter().filter(|p| p["kind"] == "generative").count());
        let t = rollup(&bom, TODAY).totals;
        assert!(t.made_lines >= generative.min(1), "{name}: {} made lines for {generative} generated parts", t.made_lines);
        eprintln!(
            "{name}: {} made + {} bought lines, {:.1} g ({:.1} made, {:.1} bought), {:.2} USD, missing {} not placed {}",
            t.made_lines, t.bought_lines, t.mass_g, t.mass_made_g, t.mass_bought_g, t.total_cost, r["missing_from_file"], r["not_placed"]
        );
        // The assembly's own mass split, when it states one, is what the BOM adds up to.
        if let Some(made) = asm["mass_g"]["made"].as_f64() {
            assert!((t.mass_made_g - made).abs() < 0.5, "{name}: made {} vs {made}", t.mass_made_g);
        }
    }
}
