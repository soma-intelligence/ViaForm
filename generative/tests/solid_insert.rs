//! A meshed density field, written as STL, 3MF and OBJ, goes into a real SolidCraft session
//! through `file.insert_mesh`: each file adds one closed mesh body named after the file, whose
//! volume and bounds match the mesh.

use serde_json::{Value, json};
use solidcraft_engine::Session;
use viaform_generative::solid::{Grid, Mesh, export, iso};

/// A ball of radius 10 mm around `(5, -3, 12)` on 1 mm voxels, each voxel's density the share
/// of it inside.
fn ball() -> (Grid, Mesh) {
    let c = [5.0, -3.0, 12.0];
    let grid = Grid::new([c[0] - 13.0, c[1] - 13.0, c[2] - 13.0], [c[0] + 13.0, c[1] + 13.0, c[2] + 13.0], 1.0);
    let density: Vec<f32> = (0..grid.elements())
        .map(|e| {
            let [i, j, k] = grid.element_ijk(e);
            let inside = (0..64)
                .filter(|s| {
                    let o = [s % 4, (s / 4) % 4, s / 16];
                    let p: [f64; 3] = std::array::from_fn(|a| grid.origin[a] + grid.h * ([i, j, k][a] as f64 + (o[a] as f64 + 0.5) / 4.0));
                    (0..3).map(|a| (p[a] - c[a]).powi(2)).sum::<f64>() <= 100.0
                })
                .count();
            inside as f32 / 64.0
        })
        .collect();
    let mesh = iso::surface(&grid, &density, 0.5, 12);
    assert!(iso::is_closed(&mesh) && iso::is_manifold(&mesh));
    (grid, mesh)
}

fn point(v: &Value) -> [f64; 3] {
    let get = |k: usize, name: &str| v.get(k).or_else(|| v.get(name)).and_then(Value::as_f64).unwrap_or(f64::NAN);
    [get(0, "x"), get(1, "y"), get(2, "z")]
}

fn bodies(s: &mut Session) -> usize {
    let r = s.execute("inspect.measure", &json!({"names_only": true})).unwrap();
    r["body_count"].as_u64().unwrap() as usize
}

#[test]
fn a_meshed_ball_inserts_as_one_closed_mesh_body_per_file() {
    let (_, mesh) = ball();
    let volume = iso::volume(&mesh);
    let dir = std::env::temp_dir().join(format!("viaform-solid-insert-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let files = [
        ("BallStl.stl", export::stl(&mesh, "BallStl")),
        ("Ball3mf.3mf", export::three_mf(&mesh, "Ball3mf")),
        ("BallObj.obj", export::obj(&mesh).into_bytes()),
    ];
    let mut s = Session::default();
    for (k, (file, bytes)) in files.iter().enumerate() {
        let path = dir.join(file);
        std::fs::write(&path, bytes).unwrap();
        let before = bodies(&mut s);
        let r = s.execute("file.insert_mesh", &json!({"path": path.to_string_lossy()})).unwrap_or_else(|e| panic!("{file}: {e}"));
        assert_eq!(bodies(&mut s), before + 1, "{file}: {r}");
        assert_eq!(bodies(&mut s), k + 1);
        let warnings = r["warnings"].as_array().map_or(0, Vec::len);
        assert_eq!(warnings, 0, "{file}: {r}");
        let name = r["bodies"][0].as_str().unwrap_or_else(|| panic!("{file}: {r}")).to_string();
        let m = s.execute("inspect.measure", &json!({"bodies": [name]})).unwrap();
        let body = &m["bodies"][0];
        assert_eq!(body["closed"], true, "{file}: {body}");
        assert!(body["face_types"]["mesh"].as_u64().unwrap_or(0) > 0, "{file}: {body}");
        let v = body["volume_mm3"].as_f64().unwrap_or(f64::NAN);
        assert!((v / volume - 1.0).abs() < 1e-4, "{file}: SolidCraft {v} vs {volume}");
        let (lo, hi) = (point(&body["bbox"]["min"]), point(&body["bbox"]["max"]));
        for (a, c) in [5.0, -3.0, 12.0].into_iter().enumerate() {
            assert!((lo[a] - (c - 10.0)).abs() < 0.3 && (hi[a] - (c + 10.0)).abs() < 0.3, "{file}: {lo:?} {hi:?}");
        }
        eprintln!("{file}: {} bytes, body `{name}`, volume {v:.2} mm³ (mesh {volume:.2})", bytes.len());
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_field_cut_by_the_walls_inserts_closed() {
    // A bar running wall to wall: capped at both ends, still one closed body.
    let grid = Grid::new([0.0; 3], [40.0, 10.0, 10.0], 1.0);
    let density: Vec<f32> = (0..grid.elements())
        .map(|e| {
            let p = grid.element_center(e);
            if (p[1] - 5.0).hypot(p[2] - 5.0) < 3.5 { 1.0 } else { 0.0 }
        })
        .collect();
    let mesh = iso::surface(&grid, &density, 0.5, 8);
    assert!(iso::is_closed(&mesh) && iso::is_manifold(&mesh));
    let dir = std::env::temp_dir().join(format!("viaform-solid-insert-bar-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("Bar.3mf");
    std::fs::write(&path, export::three_mf(&mesh, "Bar")).unwrap();
    let mut s = Session::default();
    let r = s.execute("file.insert_mesh", &json!({"path": path.to_string_lossy()})).unwrap();
    let m = s.execute("inspect.measure", &json!({"bodies": [r["bodies"][0]]})).unwrap();
    let body = &m["bodies"][0];
    assert_eq!(body["closed"], true, "{body}");
    let (lo, hi) = (point(&body["bbox"]["min"]), point(&body["bbox"]["max"]));
    assert!(lo[0].abs() < 1e-6 && (hi[0] - 40.0).abs() < 1e-6, "{lo:?} {hi:?}");
    assert!((body["volume_mm3"].as_f64().unwrap() / iso::volume(&mesh) - 1.0).abs() < 1e-4, "{body}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn quirks_solidcraft_refuses() {
    // An empty surface still writes valid files; SolidCraft refuses them, and says why.
    let dir = std::env::temp_dir().join(format!("viaform-solid-insert-empty-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let empty = Mesh::default();
    let mut s = Session::default();
    for (file, bytes) in [("Empty.stl", export::stl(&empty, "Empty")), ("Empty.3mf", export::three_mf(&empty, "Empty"))] {
        let path = dir.join(file);
        std::fs::write(&path, bytes).unwrap();
        let e = s.execute("file.insert_mesh", &json!({"path": path.to_string_lossy()})).unwrap_err().to_string();
        eprintln!("{file}: {e}");
        assert!(!e.is_empty());
    }
    let _ = std::fs::remove_dir_all(&dir);
}
