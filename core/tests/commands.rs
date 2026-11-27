//! The command schemas (UI-UX-AUDIT P1-5) and the body rename (P1-12).

use serde_json::{Value, json};
use viaform_core::commands::{self, Kind};
use viaform_core::solidcraft_engine::{self, Session};

fn bodies(s: &mut Session) -> Vec<String> {
    let r = s.execute("document.inspect", &json!({})).expect("inspect");
    r["bodies"].as_array().map(|a| a.iter().filter_map(|b| b["name"].as_str().map(String::from)).collect()).unwrap_or_default()
}

fn run(s: &mut Session, id: &str, p: Value) -> Value {
    commands::execute(s, id, &p).unwrap_or_else(|e| panic!("{id} {p}: {e}"))
}

fn with_box(name: &str) -> Session {
    let mut s = Session::default();
    run(&mut s, "solid.box", json!({"length": 20, "width": 20, "height": 20, "body_name": name}));
    s
}

#[test]
fn every_schema_names_a_registry_command_and_only_keys_it_takes() {
    let specs = solidcraft_engine::command_specs();
    let all = commands::schemas();
    let map = all.as_object().expect("schemas object");
    assert!(map.len() >= 25, "the common commands have a schema ({} do)", map.len());
    for (id, fields) in map {
        let spec = specs.iter().find(|c| c.id == id).unwrap_or_else(|| panic!("{id} is not in the registry"));
        let fields = fields.as_array().expect("fields");
        assert!(!fields.is_empty(), "{id} has fields");
        let mut seen = std::collections::BTreeSet::new();
        for f in fields {
            let key = f["key"].as_str().expect("key");
            assert!(seen.insert(key.to_string()), "{id}: `{key}` twice");
            assert!(!f["label"].as_str().unwrap_or("").is_empty(), "{id}.{key} has a label");
            if let Some(contract) = spec.contract {
                assert!(contract.allowed_keys().contains(key), "{id} does not take `{key}`");
            } else {
                assert!(spec.params.contains(key), "{id}'s parameter doc does not mention `{key}`");
            }
            match f["kind"].as_str().unwrap() {
                "enum" => {
                    let options = f["options"].as_array().expect("enum options");
                    assert!(options.contains(&f["default"]), "{id}.{key}: the default is one of the options");
                }
                "length" | "point" => assert_eq!(f["unit"], "mm", "{id}.{key}"),
                "angle" => assert_eq!(f["unit"], "deg", "{id}.{key}"),
                _ => {}
            }
            if let (Some(d), Some(min)) = (f["default"].as_f64(), f["min"].as_f64()) {
                assert!(d >= min, "{id}.{key}: default under min");
            }
        }
    }
    // Commands outside the table keep the JSON form.
    assert!(commands::schema("sketch.spline.fit").is_none());
}

#[test]
fn the_schema_is_reachable_through_the_dispatch() {
    let mut s = Session::default();
    let one = run(&mut s, "command.schema", json!({"id": "solid.fillet"}));
    let keys: Vec<&str> = one.as_array().unwrap().iter().filter_map(|f| f["key"].as_str()).collect();
    assert_eq!(keys[..2], ["edges", "radius"]);
    assert_eq!(one[0]["kind"], "edges");
    assert_eq!(one[1]["kind"], "length");
    assert_eq!(run(&mut s, "command.schema", json!({"id": "no.such"})), Value::Null);
    assert!(run(&mut s, "command.schema", json!({}))["solid.box"].is_array());
}

#[test]
fn primitives_run_from_their_defaults() {
    for id in ["solid.box", "solid.cylinder", "solid.sphere", "solid.torus", "solid.cone"] {
        let mut s = Session::default();
        let p = commands::default_params(id).unwrap();
        run(&mut s, id, p);
        assert_eq!(bodies(&mut s).len(), 1, "{id} makes a body");
    }
}

#[test]
fn form_values_encode_with_units() {
    assert_eq!(commands::encode(Kind::Length, &json!(12.5)), Some(json!("12.5 mm")));
    assert_eq!(commands::encode(Kind::Angle, &json!(30)), Some(json!("30 deg")));
    assert_eq!(commands::encode(Kind::String, &json!("  ")), None);
    assert_eq!(commands::encode(Kind::Point, &json!([1, 2, 3])), Some(json!([1, 2, 3])));
}

#[test]
fn modify_commands_run_from_form_values() {
    // Patterns, mirror, move, scale and a plane, with the form's defaults and a body.
    let mut s = with_box("Block");
    let mut p = commands::default_params("solid.pattern.rectangular").unwrap();
    p["bodies"] = json!(["Block"]);
    p["spacing1"] = json!("30 mm");
    run(&mut s, "solid.pattern.rectangular", p);
    assert_eq!(bodies(&mut s).len(), 3, "3 copies along X");

    let mut s = with_box("Block");
    run(&mut s, "solid.box", json!({"length": 5, "width": 5, "height": 5, "corner": ["40 mm", "0 mm", "0 mm"], "operation": "new"}));
    let mut p = commands::default_params("solid.pattern.circular").unwrap();
    p["bodies"] = json!(["Block"]);
    p["count"] = json!(4);
    run(&mut s, "solid.pattern.circular", p);
    assert!(bodies(&mut s).len() >= 4);

    for id in ["solid.mirror", "solid.move", "solid.scale"] {
        let mut s = with_box("Block");
        let mut p = commands::default_params(id).unwrap();
        p["bodies"] = json!(["Block"]);
        run(&mut s, id, p);
    }

    let mut s = with_box("Block");
    run(&mut s, "construct.plane.offset", commands::default_params("construct.plane.offset").unwrap());
    run(&mut s, "construct.plane.at_angle", commands::default_params("construct.plane.at_angle").unwrap());

    // Fillet and chamfer take the edges a pick gives, a point on the edge.
    let mut s = with_box("Block");
    let mut p = commands::default_params("solid.fillet").unwrap();
    p["edges"] = json!([[10, 0, 20]]);
    run(&mut s, "solid.fillet", p);
    let mut p = commands::default_params("solid.chamfer").unwrap();
    p["edges"] = json!([[10, 20, 20]]);
    run(&mut s, "solid.chamfer", p);

    // Shell with the top face open.
    let mut s = with_box("Block");
    let mut p = commands::default_params("solid.shell").unwrap();
    p["faces"] = json!([[10, 10, 20]]);
    run(&mut s, "solid.shell", p);
}

#[test]
fn a_body_renames_and_undo_and_redo_follow() {
    let mut s = with_box("Block");
    let r = run(&mut s, "body.rename", json!({"body": "Block", "name": "  Lid  "}));
    assert_eq!(r["name"], "Lid", "the name is trimmed");
    assert_eq!(bodies(&mut s), ["Lid"]);
    run(&mut s, "edit.undo", json!({}));
    assert_eq!(bodies(&mut s), ["Block"], "undo gives the old name back");
    run(&mut s, "edit.redo", json!({}));
    assert_eq!(bodies(&mut s), ["Lid"], "redo renames again");
}

#[test]
fn a_bad_body_name_is_refused_and_changes_nothing() {
    let mut s = with_box("Block");
    run(&mut s, "solid.box", json!({"length": 5, "width": 5, "height": 5, "corner": [40, 0, 0], "operation": "new", "body_name": "Other"}));
    for bad in ["", "   ", "Two\nlines", "Tab\there", "Other"] {
        let e = commands::execute(&mut s, "body.rename", &json!({"body": "Block", "name": bad}));
        assert!(e.is_err(), "`{bad:?}` is refused");
    }
    let dup = commands::execute(&mut s, "body.rename", &json!({"body": "Block", "name": "Other"})).unwrap_err();
    assert_eq!(dup, "Another body is called `Other`.", "the reason reads as a sentence");
    assert!(commands::execute(&mut s, "body.rename", &json!({"body": "Nope", "name": "X"})).is_err(), "an unknown body is refused");
    assert!(commands::execute(&mut s, "body.rename", &json!({"name": "X"})).is_err(), "the body is required");
    let mut names = bodies(&mut s);
    names.sort();
    assert_eq!(names, ["Block", "Other"]);
}

#[test]
fn features_that_use_a_renamed_body_follow_it() {
    let mut s = with_box("Block");
    run(&mut s, "body.rename", json!({"body": "Block", "name": "Base"}));
    // A later feature that names the body by its new name works.
    run(&mut s, "solid.move", json!({"bodies": ["Base"], "translate": [5, 0, 0]}));
    assert_eq!(bodies(&mut s), ["Base"]);
}

#[test]
fn sketch_and_face_commands_run_from_form_values() {
    let sketch = |s: &mut Session| {
        run(s, "sketch.create", json!({"plane": "XY", "name": "Profile"}));
        run(s, "sketch.line", json!({"points": [[0, 0], [30, 0], [30, 20], [0, 20]], "closed": true}));
        run(s, "sketch.finish", json!({}));
    };
    let mut s = Session::default();
    sketch(&mut s);
    run(&mut s, "solid.extrude", commands::default_params("solid.extrude").unwrap());
    assert_eq!(bodies(&mut s).len(), 1, "extrude from the last sketch");

    let mut s = Session::default();
    sketch(&mut s);
    run(&mut s, "solid.revolve", commands::default_params("solid.revolve").unwrap());
    assert_eq!(bodies(&mut s).len(), 1, "revolve about the sketch's x axis");

    for (id, key, pick) in [
        ("solid.hole", "position", json!([10, 10, 20])),
        ("solid.press_pull", "face", json!([10, 10, 20])),
        ("solid.offset_face", "faces", json!([[10, 10, 20]])),
        ("solid.draft", "faces", json!([[10, 0, 10]])),
    ] {
        let mut s = with_box("Block");
        let mut p = commands::default_params(id).unwrap();
        p[key] = pick;
        run(&mut s, id, p);
    }

    let mut s = with_box("Block");
    run(&mut s, "solid.box", json!({"length": 5, "width": 5, "height": 5, "corner": [18, 0, 0], "operation": "new", "body_name": "Tool"}));
    let mut p = commands::default_params("solid.combine").unwrap();
    p["target"] = json!("Block");
    p["tools"] = json!(["Tool"]);
    run(&mut s, "solid.combine", p);
    assert_eq!(bodies(&mut s), ["Block"]);

    let mut s = with_box("Block");
    let mut p = commands::default_params("solid.split_body").unwrap();
    p["body"] = json!("Block");
    p["plane"] = json!("YZ");
    run(&mut s, "solid.box", json!({"length": 20, "width": 20, "height": 20, "corner": [-10, 30, 0], "operation": "new", "body_name": "Across"}));
    p["body"] = json!("Across");
    run(&mut s, "solid.split_body", p);
    assert_eq!(bodies(&mut s).len(), 3, "the box across YZ splits in two");

    let mut s = with_box("Block");
    run(&mut s, "solid.remove", json!({"bodies": ["Block"]}));
    assert!(bodies(&mut s).is_empty());

    let mut s = Session::default();
    run(&mut s, "parameters.add", json!({"name": "wall", "expression": "2 mm"}));
}
