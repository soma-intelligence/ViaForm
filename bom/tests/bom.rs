use std::path::PathBuf;

use serde_json::{Value, json};
use viaform_bom::model::{Break, Offer};
use viaform_bom::rollup::{date, days, price};
use viaform_bom::{Bom, call, export, import, project, rollup};
use viaform_library::types::{Domain, Hits, Item, PriceBreak};

const TODAY: &str = "2026-11-04";

fn fixture(name: &str) -> Value {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(format!("{name}.json"));
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("viaform-bom-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn both() -> Bom {
    let mut bom = Bom::default();
    import::import_component_file(&mut bom, &fixture("hand"), None, TODAY).unwrap();
    import::import_component_file(&mut bom, &fixture("drone"), None, TODAY).unwrap();
    bom
}

fn offer(breaks: &[(u32, f64)], moq: u32) -> Offer {
    Offer { supplier: "DigiKey".into(), breaks: breaks.iter().map(|(q, p)| Break { qty: *q, unit_price: *p }).collect(), unit_price_usd: breaks.first().map(|b| b.1), moq, via: "file".into(), ..Offer::default() }
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-6
}

// MARK: Price breaks and MOQ

#[test]
fn price_breaks_pick_the_break_and_buy_up_when_it_costs_less() {
    let o = offer(&[(1, 1.00), (10, 0.80), (100, 0.50)], 1);
    let p = price(&o, 5).unwrap();
    assert_eq!((p.order_qty, p.break_qty, p.bumped), (5, Some(1), false));
    assert!(close(p.extended, 5.0));
    // 60 at 0.80 (48) beats 100 at 0.50 (50).
    let p = price(&o, 60).unwrap();
    assert_eq!((p.order_qty, p.bumped), (60, false));
    assert!(close(p.unit_price, 0.80));
    // 70 at 0.80 (56) loses to 100 at 0.50 (50): buy 100.
    let p = price(&o, 70).unwrap();
    assert_eq!((p.order_qty, p.bumped), (100, true));
    assert!(close(p.extended, 50.0));
    // 9 at 1.00 (9) loses to 10 at 0.80 (8).
    assert_eq!(price(&o, 9).unwrap().order_qty, 10);
}

#[test]
fn moq_and_a_first_break_above_one_set_the_smallest_order() {
    let mut o = offer(&[], 25);
    o.unit_price_usd = Some(0.2);
    let p = price(&o, 4).unwrap();
    assert_eq!(p.order_qty, 25);
    assert!(close(p.extended, 5.0));
    // Breaks that start at 10: ordering 3 means ordering 10.
    let o = Offer { unit_price_usd: None, ..offer(&[(10, 0.3), (50, 0.2)], 1) };
    assert_eq!(price(&o, 3).unwrap().order_qty, 10);
    // Sold by the pack of 10: 23 means three packs.
    let o = Offer { pack: Some(10), unit_price_usd: Some(0.139), ..offer(&[], 10) };
    assert_eq!(price(&o, 23).unwrap().order_qty, 30);
    // A component file's pack price gives the unit price and the pack.
    let mut f = fixture("drone");
    f["components"][1]["offers"][0] = json!({"supplier": "GetFPV", "sku": "x", "moq": 4, "pack_price_usd": 3.99});
    let (_, _, lines, _) = import::component_file(&f).unwrap();
    let p1 = &lines[1].offers[0];
    assert_eq!((p1.pack, p1.moq), (Some(4), 4));
    assert!(close(p1.unit_price_usd.unwrap(), 3.99 / 4.0));
    // No price at all.
    let o = Offer { unit_price_usd: None, ..offer(&[], 1) };
    assert!(price(&o, 3).is_none());
}

// MARK: Import

#[test]
fn a_component_file_becomes_lines_of_its_assembly() {
    let mut bom = Bom::default();
    let r = import::import_component_file(&mut bom, &fixture("hand"), Some("docs/components/hand.json"), TODAY).unwrap();
    assert_eq!(r["assembly"], "hand");
    assert_eq!(r["lines"], 7);
    assert_eq!(r["warnings"], json!([]));
    let m1 = bom.line("hand:M1").unwrap();
    assert_eq!((m1.qty, m1.category.as_str(), m1.subassembly.as_str()), (5, "motor", "finger"));
    assert_eq!(m1.offers[0].breaks.len(), 3);
    assert_eq!(m1.dims_mm, Some([10.0, 12.0, 34.0]));
    assert_eq!(m1.alternates, ["2373"]);
    assert!(bom.line("hand:P1").unwrap().is_made());
    assert_eq!(bom.imports[0].path.as_deref(), Some("docs/components/hand.json"));
    assert_eq!(bom.imports[0].checked_on.as_deref(), Some("2026-11-01"));
}

#[test]
fn bad_component_files_are_refused_or_warned() {
    let mut f = fixture("drone");
    f["version"] = json!(2);
    assert!(import::component_file(&f).unwrap_err().contains("newer"));
    let mut f = fixture("drone");
    f["currency"] = json!("EUR");
    assert!(import::component_file(&f).unwrap_err().contains("USD"));
    let mut f = fixture("drone");
    let first = f["components"][0].clone();
    f["components"].as_array_mut().unwrap().push(first);
    assert!(import::component_file(&f).unwrap_err().contains("used twice"));
    let mut f = fixture("drone");
    f["components"][0]["category"] = json!("thruster");
    let (_, _, _, warnings) = import::component_file(&f).unwrap();
    assert_eq!(warnings, ["M1: unknown category `thruster`"]);
}

#[test]
fn a_reimport_keeps_what_the_user_changed() {
    let mut bom = both();
    call(&mut bom, "edit", &json!({"id": "hand:M1", "changes": {"qty": 6, "notes": "one spare", "mass_g": 11.0}}), TODAY).unwrap();
    call(&mut bom, "edit", &json!({"id": "hand:U1", "changes": {"supplier": "Mouser"}}), TODAY).unwrap();
    let mut f = fixture("hand");
    f["components"][0]["description"] = json!("renamed upstream");
    f["components"][0]["mass_g"] = json!(99);
    import::import_component_file(&mut bom, &f, None, TODAY).unwrap();
    let m1 = bom.line("hand:M1").unwrap();
    assert_eq!((m1.per_build(), m1.user_notes.as_str(), m1.mass_g), (6, "one spare", Some(11.0)));
    assert_eq!(m1.description, "renamed upstream", "fields the user did not touch follow the file");
    assert_eq!(bom.line("hand:U1").unwrap().supplier.as_deref(), Some("Mouser"));
    // Setting the count back to the file's clears the override.
    call(&mut bom, "edit", &json!({"id": "hand:M1", "changes": {"qty": 5}}), TODAY).unwrap();
    assert_eq!(bom.line("hand:M1").unwrap().qty_override, None);
    // The drone lines stayed where they were.
    assert_eq!(bom.lines.iter().filter(|l| l.origin == "drone").count(), 5);
}

#[test]
fn every_component_file_in_a_folder_is_imported() {
    let dir = scratch("dir");
    std::fs::write(dir.join("hand.json"), fixture("hand").to_string()).unwrap();
    std::fs::write(dir.join("drone.json"), fixture("drone").to_string()).unwrap();
    std::fs::write(dir.join("notes.json"), "{\"other\": true}").unwrap();
    let mut bom = Bom::default();
    let r = viaform_bom::import_dir(&mut bom, &dir, TODAY).unwrap();
    assert_eq!(r["imported"].as_array().unwrap().len(), 2, "{r}");
    assert_eq!(r["errors"], json!([]));
    assert_eq!(bom.lines.len(), 12);
}

// MARK: Rollup

#[test]
fn the_rollup_counts_costs_and_weighs_for_n_builds() {
    let mut bom = both();
    let one = rollup(&bom, TODAY);
    let t = &one.totals;
    assert_eq!((t.lines, t.made_lines, t.bought_lines), (12, 2, 10));
    // Mass per build: every line has one.
    let mass = 5.0 * 10.5 + 3.0 * 0.1 + 10.0 * 0.3 + 24.0 * 0.25 + 2.0 + 5.0 * 0.08 + 5.0 * 3.2 + 4.0 * 9.6 + 4.0 * 1.4 + 8.0 + 78.0 + 22.0;
    assert!(close(t.mass_g, mass), "{} vs {mass}", t.mass_g);
    assert!(close(t.mass_made_g, 5.0 * 3.2 + 22.0));
    assert!(t.mass_complete);
    // Unsourced: the tendon. Unpriced: the sensor (offer without price) and the frame (no cost).
    assert_eq!(t.unsourced, 1);
    assert_eq!(t.missing_price, 2);
    assert!(!t.cost_complete);

    let line = |r: &viaform_bom::Rollup, id: &str| r.lines.iter().find(|l| l.id == id).cloned().unwrap();
    // The bearings: MOQ 20 for 10.
    let b1 = line(&one, "hand:B1");
    assert_eq!((b1.need, b1.order_qty), (10, 20));
    assert!(b1.flags.contains(&"moq_excess".to_string()));
    assert!(b1.flags.contains(&"stale".to_string()), "checked in June: {:?}", b1.flags);
    // The motors: the cheaper supplier is out of stock, so GetFPV.
    assert_eq!(line(&one, "drone:M1").supplier.as_deref(), Some("GetFPV"));
    // The sensor's NRND note.
    let s1 = line(&one, "hand:S1");
    assert_eq!(s1.lifecycle.as_deref(), Some("Not recommended for new designs"));
    assert!(s1.flags.contains(&"no_price".to_string()));
    assert!(line(&one, "hand:T1").flags.contains(&"unsourced".to_string()));
    assert!(line(&one, "hand:T1").flags.contains(&"no_mpn".to_string()));

    // Ten builds: the motor reaches its 10 and the driver its 25 break.
    bom.builds = 10;
    let ten = rollup(&bom, TODAY);
    let m1 = line(&ten, "hand:M1");
    assert_eq!((m1.need, m1.order_qty), (50, 50));
    assert!(close(m1.unit_price.unwrap(), 22.46));
    assert!(close(m1.per_build_cost.unwrap(), 22.46 * 5.0));
    let u1 = line(&ten, "hand:U1");
    assert_eq!((u1.need, u1.order_qty, u1.supplier.as_deref()), (30, 30, Some("DigiKey")));
    assert!(close(u1.unit_price.unwrap(), 1.38));
    // The screws come in packs of 100: 240 for ten builds.
    assert_eq!(line(&ten, "hand:F1").order_qty, 240);
    assert!(ten.totals.cost_per_build < one.totals.cost_per_build, "{} vs {}", ten.totals.cost_per_build, one.totals.cost_per_build);
    let sum: f64 = ten.carts.iter().map(|c| c.total).sum();
    assert!(close(sum, ten.totals.bought_cost));
    assert!(close(ten.totals.total_cost, ten.totals.bought_cost + ten.totals.made_cost));
}

#[test]
fn the_user_supplier_excluded_lines_and_placed_counts_change_the_rollup() {
    let mut bom = both();
    call(&mut bom, "edit", &json!({"id": "hand:U1", "changes": {"supplier": "Mouser"}}), TODAY).unwrap();
    call(&mut bom, "edit", &json!({"id": "drone:BAT1", "changes": {"excluded": true}}), TODAY).unwrap();
    let r = rollup(&bom, TODAY);
    let u1 = r.lines.iter().find(|l| l.id == "hand:U1").unwrap();
    assert_eq!(u1.supplier.as_deref(), Some("Mouser"));
    assert!(close(u1.extended.unwrap(), 3.0 * 2.20));
    assert_eq!(r.totals.excluded, 1);
    assert!(!r.carts.iter().any(|c| c.items.iter().any(|i| i.line == "drone:BAT1")));
    bom.line_mut("drone:M1").unwrap().placed = Some(3);
    let r = rollup(&bom, TODAY);
    assert!(r.lines.iter().find(|l| l.id == "drone:M1").unwrap().flags.contains(&"placed_mismatch".to_string()));
}

#[test]
fn dates_round_trip() {
    assert_eq!(days("1970-01-01"), Some(0));
    assert_eq!(days("2026-11-04").map(date).as_deref(), Some("2026-11-04"));
    assert_eq!(days("2024-02-29").map(date).as_deref(), Some("2024-02-29"));
    assert_eq!(days("2026-11-04").unwrap() - days("2026-08-06").unwrap(), 90);
    assert_eq!(days("soon"), None);
    assert_eq!(viaform_bom::today().len(), 10);
}

// MARK: Suppliers and exports

#[test]
fn carts_split_by_supplier_and_export_in_the_distributors_formats() {
    let mut bom = both();
    bom.builds = 2;
    let r = rollup(&bom, TODAY);
    let names: Vec<&str> = r.carts.iter().map(|c| c.supplier.as_str()).collect();
    for s in ["Pololu", "DigiKey", "AliExpress", "McMaster-Carr", "GetFPV", "Amazon", "RaceDayQuads"] {
        assert!(names.contains(&s), "{s} in {names:?}");
    }
    assert!(!names.contains(&"Mouser"), "the sensor's Mouser offer has no price: no cart line");
    let dk = export::digikey(&r).unwrap();
    assert_eq!(dk.lines().next(), Some("Quantity,Digi-Key Part Number,Manufacturer Part Number,Customer Reference"));
    assert_eq!(dk.lines().nth(1), Some("6,296-27581-1-ND,DRV8833PWPR,U1"));
    call(&mut bom, "edit", &json!({"id": "hand:U1", "changes": {"supplier": "Mouser"}}), TODAY).unwrap();
    let r = rollup(&bom, TODAY);
    let mo = export::mouser(&r).unwrap();
    assert_eq!(mo.lines().nth(1), Some("595-DRV8833PWPR,DRV8833PWPR,6,U1"));
    assert!(export::digikey(&r).unwrap_err().contains("DigiKey"));
    let table = export::table(&bom, &r);
    assert_eq!(table.lines().count(), 13);
    assert!(table.contains("\"Test fixture: 3 inch tri-blade propeller (pair = 2)\"") || table.contains("Test fixture: 3 inch tri-blade propeller (pair = 2)"));
    assert_eq!(export::field("a, \"b\""), "\"a, \"\"b\"\"\"");
    let gf = export::supplier(&r, "getfpv").unwrap();
    assert_eq!(gf.lines().count(), 3);
    let reply = call(&mut bom, "export", &json!({"format": "mouser"}), TODAY).unwrap();
    assert_eq!(reply["filename"], "bom-mouser.csv");
}

// MARK: Refresh through the library's sources

#[test]
fn library_hits_refresh_offers_with_price_breaks_and_stock() {
    let mut bom = both();
    let plan = import::refresh_plan(&bom);
    let queries: Vec<&str> = plan.as_array().unwrap().iter().map(|p| p["query"].as_str().unwrap()).collect();
    assert!(queries.contains(&"DRV8833PWPR"));
    assert!(!queries.contains(&""), "lines without an mpn are not searched");
    let mut it = Item::new("digikey", "296-27581-1-ND", "DRV8833PWPR", Domain::Electronics);
    it.mpn = Some("DRV8833PWPR".into());
    it.stock = Some(12_000.0);
    it.prices = vec![PriceBreak { quantity: 1.0, price: 2.05, currency: "USD".into() }, PriceBreak { quantity: 100.0, price: 1.10, currency: "USD".into() }];
    let mut other = Item::new("digikey", "X", "DRV8833C", Domain::Electronics);
    other.mpn = Some("DRV8833CPWPR".into());
    let hits = vec![Hits { source: "digikey".into(), total: 2, items: vec![it, other], error: None }, Hits { source: "mouser".into(), error: Some("no keys".into()), ..Hits::default() }];
    let r = call(&mut bom, "apply_hits", &json!({"mpn": "DRV8833PWPR", "hits": hits}), "2026-11-05").unwrap();
    assert_eq!(r["result"]["offers"], 1, "{r}");
    assert_eq!(r["result"]["errors"][0]["source"], "mouser");
    let u1 = bom.line("hand:U1").unwrap();
    let dk: Vec<&Offer> = u1.offers.iter().filter(|o| o.supplier == "DigiKey").collect();
    assert_eq!(dk.len(), 1, "the file's DigiKey offer is updated, not doubled");
    assert_eq!((dk[0].via.as_str(), dk[0].stock, dk[0].checked_on.as_deref()), ("digikey", Some(12_000.0), Some("2026-11-05")));
    assert_eq!(dk[0].url.as_deref(), Some("https://www.digikey.com/"), "the file's link is kept");
    assert_eq!(u1.checked_on.as_deref(), Some("2026-11-05"));
    // A re-import of the file keeps the refreshed offer.
    import::import_component_file(&mut bom, &fixture("hand"), None, TODAY).unwrap();
    let u1 = bom.line("hand:U1").unwrap();
    assert!(u1.offers.iter().any(|o| o.via == "digikey"), "{:?}", u1.offers);
}

// MARK: The design and the PCB

fn run(s: &mut solidcraft_engine::Session, id: &str, p: Value) -> Value {
    s.execute(id, &p).unwrap_or_else(|e| panic!("{id}: {e}"))
}

#[test]
fn design_rows_link_to_component_lines_or_become_made_parts() {
    let mut s = solidcraft_engine::Session::default();
    run(&mut s, "component.create", json!({"name": "Gearmotor"}));
    run(&mut s, "solid.box", json!({"length": 10, "width": 12, "height": 34}));
    run(&mut s, "component.activate", json!({"component": 0}));
    for x in [20, 40, 60, 80] {
        run(&mut s, "occurrence.copy", json!({"component": "Gearmotor", "translate": [x, 0, 0]}));
    }
    run(&mut s, "component.metadata.set", json!({"component": "Gearmotor", "properties": {"component_ref": "hand:M1"}}));
    run(&mut s, "component.create", json!({"name": "Palm"}));
    run(&mut s, "solid.box", json!({"length": 80, "width": 90, "height": 20}));
    run(&mut s, "component.activate", json!({"component": 0}));
    run(&mut s, "component.metadata.set", json!({"component": "Palm", "part_number": "PALM-1", "properties": {"material": "PA12", "process": "SLS", "mass_g": "48", "cost_usd": "31.5", "subassembly": "palm"}}));
    let reply = run(&mut s, "assembly.bom", json!({}));

    let mut bom = Bom::default();
    // The design first: its link waits for the component file.
    let r = import::sync_design(&mut bom, &reply, TODAY).unwrap();
    assert_eq!(r["unknown_refs"], json!(["hand:M1"]), "{r}");
    import::import_component_file(&mut bom, &fixture("hand"), None, TODAY).unwrap();
    let m1 = bom.line("hand:M1").unwrap();
    assert_eq!(m1.placed, Some(5), "four copies and the original");
    assert_eq!(m1.definitions, ["Gearmotor"]);
    assert!(!m1.components.is_empty());
    let palm = bom.line("design:PALM-1").unwrap();
    let made = palm.made.as_ref().unwrap();
    assert_eq!((made.material.as_str(), made.process.as_str(), made.unit_cost_usd), ("PA12", "SLS", Some(31.5)));
    assert_eq!((palm.mass_g, palm.subassembly.as_str(), palm.qty), (Some(48.0), "palm", 1));
    let r = rollup(&bom, TODAY);
    assert!(!r.lines.iter().find(|l| l.id == "hand:M1").unwrap().flags.contains(&"placed_mismatch".to_string()));
    // A second sync replaces the design's lines, not the file's.
    import::sync_design(&mut bom, &reply, TODAY).unwrap();
    assert_eq!(bom.lines.iter().filter(|l| l.origin == "design").count(), 1);
    assert_eq!(bom.line("hand:M1").unwrap().placed, Some(5));
}

#[test]
fn pcb_components_group_by_value_and_footprint() {
    let pcb = pcbcraft_engine::Session::sample().unwrap();
    let mut bom = Bom::default();
    let r = import::sync_pcb(&mut bom, &pcb.inspect(), TODAY).unwrap();
    assert!(r["components"].as_u64().unwrap() >= 3, "{r}");
    let board = bom.line("pcb:board").unwrap();
    assert_eq!((board.category.as_str(), board.qty), ("pcb", 1));
    assert!(bom.line("pcb:R1").is_some(), "{:?}", bom.lines.iter().map(|l| &l.id).collect::<Vec<_>>());
    let rl = rollup(&bom, TODAY);
    assert!(rl.lines.iter().find(|l| l.id == "pcb:R1").unwrap().flags.contains(&"no_mpn".to_string()));
}

// MARK: Persistence

#[test]
fn the_bom_travels_in_the_viaform_project_and_old_projects_still_open() {
    let dir = scratch("project");
    let path = dir.join("hand.viaform");
    let mut ws = viaform_core::Workspace::new(true);
    ws.cad_execute("solid.box", &json!({"length": 10, "width": 10, "height": 10, "body_name": "Cube"})).unwrap();
    // A project saved before the BOM existed: no bom.json, it reads as none.
    viaform_core::project::save(&mut ws, &path).unwrap();
    assert_eq!(project::read_from(&path).unwrap(), None);

    let mut bom = both();
    bom.name = "Hand".into();
    bom.builds = 3;
    call(&mut bom, "edit", &json!({"id": "hand:M1", "changes": {"qty": 6, "notes": "spare"}}), TODAY).unwrap();
    project::save(&mut ws, &path, &bom).unwrap();
    // The core still opens it as before.
    let mut back = viaform_core::Workspace::default();
    viaform_core::project::open(&mut back, &path).unwrap();
    let names: Vec<String> = back.cad.world_state().unwrap().bodies.iter().map(|b| b.name.clone()).collect();
    assert!(names.iter().any(|n| n == "Cube"), "{names:?}");
    // And the BOM comes back whole.
    let mut again = viaform_core::Workspace::default();
    let read = project::open(&mut again, &path).unwrap().unwrap();
    assert_eq!(read, bom);
    // Writing again replaces the entry (one bom.json).
    bom.builds = 5;
    project::write_into(&path, &bom).unwrap();
    assert_eq!(project::read_from(&path).unwrap().unwrap().builds, 5);
    let zip = zip::ZipArchive::new(std::fs::File::open(&path).unwrap()).unwrap();
    assert_eq!(zip.file_names().filter(|n| n.as_deref().is_ok_and(|n| n == "bom.json")).count(), 1);
    assert_eq!(zip.len(), 4);
    // Not a project: refused.
    let junk = dir.join("junk.viaform");
    std::fs::write(&junk, b"nope").unwrap();
    assert!(project::write_into(&junk, &bom).is_err());
}

#[test]
fn a_saved_bom_reads_back_and_a_newer_one_is_refused() {
    let dir = scratch("json");
    let path = dir.join("bom.json");
    let mut bom = both();
    call(&mut bom, "save", &json!({"path": path}), TODAY).unwrap();
    let mut back = Bom::default();
    call(&mut back, "load", &json!({"path": path}), TODAY).unwrap();
    assert_eq!(back, bom);
    let mut v: Value = serde_json::to_value(&bom).unwrap();
    v["version"] = json!(9);
    assert!(Bom::from_json(v).unwrap_err().contains("newer"));
    assert!(Bom::from_json(json!({"format": "other"})).is_err());
}

#[test]
fn manual_lines_and_the_call_surface() {
    let mut bom = Bom::default();
    let r = call(&mut bom, "add", &json!({"line": {"description": "Zip ties", "category": "other", "qty": 8, "mass_g": 0.4}}), TODAY).unwrap();
    assert_eq!(r["result"]["id"], "manual:X1");
    assert!(call(&mut bom, "add", &json!({"line": {"reference": "X1"}}), TODAY).is_err());
    call(&mut bom, "set", &json!({"builds": 4, "name": "Kit"}), TODAY).unwrap();
    let s = call(&mut bom, "state", &json!({}), TODAY).unwrap();
    assert_eq!(s["state"]["rollup"]["builds"], 4);
    assert_eq!(s["state"]["rollup"]["lines"][0]["need"], 32);
    assert!(call(&mut bom, "edit", &json!({"id": "manual:X1", "changes": {"colour": "red"}}), TODAY).is_err());
    call(&mut bom, "remove", &json!({"id": "manual:X1"}), TODAY).unwrap();
    assert!(bom.lines.is_empty());
    assert!(call(&mut bom, "nope", &json!({}), TODAY).is_err());
}

#[test]
fn the_real_component_files_import_when_present() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../docs/components");
    if !dir.join("hand.json").exists() && !dir.join("drone.json").exists() {
        return;
    }
    let mut bom = Bom::default();
    let r = viaform_bom::import_dir(&mut bom, &dir, TODAY).unwrap();
    assert_eq!(r["errors"], json!([]), "{r}");
    for i in r["imported"].as_array().unwrap() {
        assert!(i["lines"].as_u64().unwrap() > 0, "{i}");
        eprintln!("{}: {} lines, warnings {}", i["assembly"], i["lines"], i["warnings"]);
    }
    for b in [1, 10] {
        bom.builds = b;
        let t = rollup(&bom, TODAY).totals;
        eprintln!("{b} builds: {:.2} USD per build, {:.1} g, {} flagged, {} unsourced, {} unpriced", t.cost_per_build, t.mass_g, t.flagged, t.unsourced, t.missing_price);
        assert!(t.cost_per_build > 0.0);
    }
}
