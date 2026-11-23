//! Generative design through the workspace: a study, then its best candidate built as one body
//! in one undo step.

use serde_json::{Value, json};
use viaform_core::{Workspace, scene};

/// A 120 x 40 mm cantilever: held along its left edge, pulled down at the middle of its right edge.
fn cantilever(variants: usize) -> Value {
    json!({
        "method": "topology",
        "width": 120.0,
        "height": 40.0,
        "thickness": 6.0,
        "resolution": 4.0,
        "iterations": 30,
        "volume_fraction": 0.4,
        "variants": variants,
        "supports": [{"region": {"shape": "rect", "min": [0.0, 0.0], "max": [1.0, 40.0]}, "fix": "all"}],
        "cases": [{"name": "tip", "loads": [{"region": {"shape": "circle", "center": [120.0, 20.0], "radius": 2.0}, "force": [0.0, -500.0]}]}],
        "body_name": "Bracket",
    })
}

fn bodies(w: &Workspace) -> Vec<String> {
    scene::build(&w.cad, None).meshes.into_iter().map(|m| m.body).collect()
}

#[test]
fn study_answers_every_variant() {
    let out = viaform_core::generative::study(&cantilever(2)).expect("study");
    assert_eq!(out["candidates"].as_array().map(Vec::len), Some(2));
    assert!(out["best"].as_u64().is_some_and(|b| b < 2));
}

#[test]
fn builds_the_best_candidate_as_one_undo_step() {
    let mut w = Workspace::new(false);
    let undo = w.cad.undo.len();
    let r = w.generate(&cantilever(2), None).expect("build");
    assert_eq!(r["body"], "Bracket");
    assert!(r["commands"].as_u64().is_some_and(|n| n > 0));
    assert!(r["candidate"].get("shape").is_none());
    assert!(bodies(&w).iter().any(|b| b == "Bracket"));
    assert_eq!(w.cad.undo.len(), undo + 1);
    w.cad_execute("edit.undo", &json!({})).expect("undo");
    assert!(!bodies(&w).iter().any(|b| b == "Bracket"));
}

#[test]
fn a_refused_spec_leaves_the_design_alone() {
    let mut w = Workspace::new(false);
    let doc = w.cad.doc.clone();
    let err = w.generate(&json!({"supports": []}), None).unwrap_err();
    assert!(err.contains("support"), "{err}");
    assert!(std::sync::Arc::ptr_eq(&doc, &w.cad.doc));
    assert!(w.generate(&json!({"width": "wide"}), None).unwrap_err().starts_with("spec:"));
}
