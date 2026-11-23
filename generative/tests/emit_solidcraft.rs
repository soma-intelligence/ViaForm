//! Runs emitted candidates through a real SolidCraft session: every command succeeds, one body
//! named as the spec asks remains, and its volume, mass and bounds match the candidate.

use serde_json::{Value, json};
use solidcraft_engine::Session;
use viaform_generative::{Beam, Candidate, Material, Method, Shape, Spec, emit, geometry};

fn candidate(shape: Shape, method: Method) -> Candidate {
    Candidate {
        id: 0,
        method,
        mass_g: 0.0,
        compliance: 0.0,
        max_stress: 0.0,
        max_displacement: 0.0,
        volume_fraction: 0.0,
        feasible: true,
        history: Vec::new(),
        shape,
        outlines: Vec::new(),
    }
}

/// A density shape where `solid(i, j)` says which elements are solid.
fn density(nx: usize, ny: usize, cell: f64, solid: impl Fn(usize, usize) -> bool) -> Shape {
    let values = (0..nx * ny).map(|k| if solid(k % nx, k / nx) { 1.0 } else { 0.0 }).collect();
    Shape::Density { nx, ny, cell, values }
}

/// Builds the candidate in a fresh session and returns the session and the remaining body's measurement.
fn build(spec: &Spec, c: &Candidate) -> (Session, Value) {
    let mut s = Session::default();
    let cmds = emit::commands(spec, c);
    assert!(!cmds.is_empty());
    for (id, params) in &cmds {
        if let Err(e) = s.execute(id, params) {
            panic!("{id} {params} failed: {e}");
        }
    }
    let names = s.execute("inspect.measure", &json!({"names_only": true})).unwrap();
    assert_eq!(names["body_count"], 1, "{names}");
    assert_eq!(names["bodies"][0]["name"], spec.body_name.as_str(), "{names}");
    let m = s.execute("inspect.measure", &json!({"bodies": [spec.body_name]})).unwrap();
    let body = m["bodies"][0].clone();
    assert_eq!(body["closed"], true, "{body}");
    assert_eq!(body["material"], spec.material.name.as_str(), "{body}");
    (s, body)
}

fn point(v: &Value) -> [f64; 3] {
    let get = |k: usize, name: &str| v.get(k).or_else(|| v.get(name)).and_then(Value::as_f64).unwrap_or(f64::NAN);
    [get(0, "x"), get(1, "y"), get(2, "z")]
}

fn close(a: f64, b: f64, rel: f64) -> bool {
    (a - b).abs() <= rel * b.abs().max(1.0)
}

#[test]
fn density_l_bracket_builds_one_body() {
    let spec = Spec {
        width: 40.0,
        height: 30.0,
        thickness: 3.0,
        origin: [10.0, -5.0, 2.0],
        body_name: "Bracket".into(),
        material: Material { name: "Generated Alloy".into(), density: 2.7e-3, color: "#a0a8b0".into(), ..Material::default() },
        ..Spec::default()
    };
    // An L: the bottom five rows and the left five columns of a 20 by 15 grid of 2 mm elements.
    let shape = density(20, 15, 2.0, |i, j| j < 5 || i < 5);
    let c = candidate(shape, Method::Topology);
    let area = geometry::solid_area(&c.shape, &spec);
    assert_eq!(geometry::rects(&c.shape).len(), 2);
    let (_, body) = build(&spec, &c);
    let volume = body["volume_mm3"].as_f64().unwrap();
    assert!(close(volume, area * spec.thickness, 1e-6), "volume {volume} vs {}", area * spec.thickness);
    let mass = body["mass_g"].as_f64().unwrap();
    assert!(close(mass, area * spec.thickness * spec.material.density, 1e-6), "mass {mass}");
    let (min, max) = (point(&body["bbox"]["min"]), point(&body["bbox"]["max"]));
    let [ox, oy, oz] = spec.origin;
    let want = ([ox, oy, oz], [ox + spec.width, oy + spec.height, oz + spec.thickness]);
    for k in 0..3 {
        assert!((min[k] - want.0[k]).abs() < 1e-6 && (max[k] - want.1[k]).abs() < 1e-6, "bounds {min:?} {max:?} vs {want:?}");
    }
}

#[test]
fn density_with_holes_and_corner_contacts_stays_one_body() {
    // A ring with spokes, a hole, and two elements touching the ring only at a corner: many
    // rectangles, some meeting along an edge only.
    let spec = Spec { width: 48.0, height: 48.0, thickness: 4.0, body_name: "Wheel".into(), ..Spec::default() };
    let n = 24;
    let shape = density(n, n, 2.0, |i, j| {
        let (x, y) = (i as f64 + 0.5 - 12.0, j as f64 + 0.5 - 12.0);
        let r = x.hypot(y);
        (8.0..11.5).contains(&r) || (r < 8.0 && (x.abs() < 1.0 || y.abs() < 1.0) && r > 2.0) || (i, j) == (0, 0)
    });
    let c = candidate(shape, Method::Topology);
    let area = geometry::solid_area(&c.shape, &spec);
    let rects = geometry::rects(&c.shape).len();
    assert!(rects > 20, "{rects} rectangles");
    let (_, body) = build(&spec, &c);
    let volume = body["volume_mm3"].as_f64().unwrap();
    assert!(close(volume, area * spec.thickness, 1e-6), "volume {volume} vs {}", area * spec.thickness);
}

#[test]
fn frame_triangle_builds_one_body() {
    let spec = Spec { thickness: 5.0, origin: [-20.0, 30.0, 0.0], body_name: "Truss".into(), ..Spec::default() };
    let shape = Shape::Frame {
        nodes: vec![[0.0, 0.0], [120.0, 0.0], [60.0, 90.0], [200.0, 200.0]],
        beams: vec![
            Beam { a: 0, b: 1, width: 4.0 },
            Beam { a: 1, b: 2, width: 3.0 },
            Beam { a: 2, b: 0, width: 3.0 },
            // Removed by the optimiser: neither a beam nor a joint.
            Beam { a: 2, b: 3, width: 0.0 },
        ],
    };
    let c = candidate(shape, Method::Frame);
    let area = geometry::solid_area(&c.shape, &spec);
    let (_, body) = build(&spec, &c);
    let volume = body["volume_mm3"].as_f64().unwrap();
    // Overlaps and rounded joints move the volume a little off the beams' sum.
    assert!(close(volume, area * spec.thickness, 0.04), "volume {volume} vs {}", area * spec.thickness);
    let (min, max) = (point(&body["bbox"]["min"]), point(&body["bbox"]["max"]));
    let [ox, oy, _] = spec.origin;
    // The bottom beam's lower face is at y = -2 (half its width), the joints' circles reach x = -2 and 122.
    assert!((min[1] - (oy - 2.0)).abs() < 0.05 && (min[0] - (ox - 2.0)).abs() < 0.05, "{min:?}");
    assert!((max[0] - (ox + 122.0)).abs() < 0.05 && (max[2] - spec.thickness).abs() < 1e-6, "{max:?}");
    assert!(max[1] > oy + 90.0 && max[1] < oy + 92.0, "{max:?}");
}

#[test]
fn second_build_in_one_design_refuses_only_the_material() {
    let spec = Spec { body_name: "Plate".into(), ..Spec::default() };
    let c = candidate(density(4, 2, 5.0, |_, _| true), Method::Topology);
    let (mut s, _) = build(&spec, &c);
    let again = Spec { body_name: "Plate 2".into(), ..spec.clone() };
    for (id, params) in emit::commands(&again, &c) {
        match s.execute(&id, &params) {
            Ok(_) => assert_ne!(id, "material.create"),
            Err(e) => {
                assert_eq!(id, "material.create", "{e}");
                assert!(e.to_string().contains("already has a material"), "{e}");
            }
        }
    }
    let m = s.execute("inspect.measure", &json!({"bodies": ["Plate 2"]})).unwrap();
    assert_eq!(m["bodies"][0]["material"], spec.material.name.as_str());
}
