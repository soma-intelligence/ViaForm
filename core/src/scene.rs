//! The 3D scene flattened to `f32` buffers a GPU takes as they are (Metal in the Swift apps,
//! WebGL in the Electron app).

use solidcraft_engine::Session;
use solidcraft_engine::render::{Camera, Rgb, Scene, SceneLine};
use solidcraft_engine::view;

/// One body's triangles and B-rep edges.
pub struct FlatMesh {
    /// The body this mesh draws.
    pub body: String,
    pub positions: Vec<f32>,
    pub normals: Vec<f32>,
    pub indices: Vec<u32>,
    /// B-rep face index per triangle.
    pub tri_face: Vec<u32>,
    /// B-rep edges (seams left out) as one point list, `edge_offsets[i]..edge_offsets[i + 1]`.
    pub edge_points: Vec<f32>,
    pub edge_offsets: Vec<u32>,
    pub color: [f32; 4],
}

/// One polyline (an edge, a sketch curve, an axis or a grid line).
pub struct FlatLine {
    pub points: Vec<f32>,
    pub color: [f32; 4],
    pub width: f32,
    pub on_top: bool,
}

pub struct FlatScene {
    pub meshes: Vec<FlatMesh>,
    pub lines: Vec<FlatLine>,
    pub grid: Vec<FlatLine>,
    pub radius: f32,
    /// Background gradient: top RGBA then bottom RGBA (all zero when the scene has none).
    pub background: [f32; 8],
}

fn rgba(c: Rgb, a: f32) -> [f32; 4] {
    let [r, g, b] = c.f();
    [r as f32, g as f32, b as f32, a]
}

fn edges(m: &solidcraft_engine::geom::Mesh) -> (Vec<f32>, Vec<u32>) {
    let mut points = Vec::new();
    let mut offsets = vec![0u32];
    for (i, e) in m.edges.iter().enumerate() {
        if m.seams.get(i).copied().unwrap_or(false) {
            continue;
        }
        points.extend(e.iter().flat_map(|p| [p.x as f32, p.y as f32, p.z as f32]));
        offsets.push((points.len() / 3) as u32);
    }
    (points, offsets)
}

fn line(l: &SceneLine) -> FlatLine {
    FlatLine {
        points: l.points.iter().flat_map(|p| [p.x as f32, p.y as f32, p.z as f32]).collect(),
        color: rgba(l.color, l.alpha),
        width: l.width as f32,
        on_top: l.on_top,
    }
}

fn flatten(scene: &Scene, names: Vec<String>) -> FlatScene {
    let meshes = scene
        .meshes
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let (edge_points, edge_offsets) = edges(&m.mesh);
            FlatMesh {
                body: names.get(i).cloned().unwrap_or_default(),
                positions: m.mesh.positions.iter().flat_map(|p| [p.x as f32, p.y as f32, p.z as f32]).collect(),
                normals: m.mesh.normals.iter().flat_map(|n| [n.x as f32, n.y as f32, n.z as f32]).collect(),
                indices: m.mesh.triangles.iter().flatten().copied().collect(),
                tri_face: m.mesh.tri_face.clone(),
                edge_points,
                edge_offsets,
                color: rgba(m.color, m.alpha() as f32),
            }
        })
        .collect();
    let mut background = [0.0; 8];
    if let Some((top, bottom)) = scene.background {
        background[..4].copy_from_slice(&rgba(top, 1.0));
        background[4..].copy_from_slice(&rgba(bottom, 1.0));
    }
    FlatScene {
        meshes,
        lines: scene.lines.iter().map(line).collect(),
        grid: scene.grid.iter().map(line).collect(),
        radius: scene.radius as f32,
        background,
    }
}

/// The scene seen from `camera` (the home view when `None`). The scene lists visible bodies in
/// model order, so each mesh carries the name of the body it draws. A model the engine cannot
/// evaluate gives an empty scene, so the views stay up while the error shows elsewhere.
pub fn build(s: &Session, camera: Option<Camera>) -> FlatScene {
    let built = (|| {
        let cam = match camera {
            Some(c) => c,
            None => view::home_camera(s)?,
        };
        let scene = view::scene(s, &cam)?;
        let state = s.world_state()?;
        let names = state.bodies.iter().filter(|b| s.body_visible(&b.name)).map(|b| b.name.clone()).collect();
        Ok::<_, solidcraft_engine::EngineError>(flatten(&scene, names))
    })();
    built.unwrap_or_else(|_| FlatScene { meshes: vec![], lines: vec![], grid: vec![], radius: 1.0, background: [0.0; 8] })
}
