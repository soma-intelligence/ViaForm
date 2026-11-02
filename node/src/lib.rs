//! Node addon over the ViaForm core: one `Workspace` per open project, holding the design and
//! the electronics. JSON crosses as JS values; the scene's buffers cross as typed arrays.

use napi::bindgen_prelude::{Float32Array, Uint32Array};
use napi::{Error, Result};
use napi_derive::napi;
use serde_json::{Value, json};
use viaform_core::solidcraft_engine::view;

fn fail(e: impl std::fmt::Display) -> Error {
    Error::from_reason(e.to_string())
}

#[napi(object)]
pub struct SceneMesh {
    pub body: String,
    pub positions: Float32Array,
    pub normals: Float32Array,
    pub indices: Uint32Array,
    pub tri_face: Uint32Array,
    pub edge_points: Float32Array,
    pub edge_offsets: Uint32Array,
    pub color: Vec<f64>,
}

#[napi(object)]
pub struct SceneLine {
    pub points: Float32Array,
    pub color: Vec<f64>,
    pub width: f64,
    pub on_top: bool,
}

#[napi(object)]
pub struct SceneData {
    pub meshes: Vec<SceneMesh>,
    pub lines: Vec<SceneLine>,
    pub radius: f64,
    pub background: Vec<f64>,
}

fn rgba(c: [f32; 4]) -> Vec<f64> {
    c.iter().map(|&x| f64::from(x)).collect()
}

/// The versions this build carries.
#[napi]
pub fn versions() -> Value {
    json!({
        "core": env!("CARGO_PKG_VERSION"),
        "solidcraft": env!("VIAFORM_SOLIDCRAFT"),
        "pcbcraft": env!("VIAFORM_PCBCRAFT"),
        "format": viaform_core::project::FORMAT_VERSION,
    })
}

#[napi]
pub struct Workspace {
    ws: viaform_core::Workspace,
}

#[napi]
impl Workspace {
    #[napi(constructor)]
    pub fn new(sample: Option<bool>) -> Self {
        Self { ws: viaform_core::Workspace::new(sample.unwrap_or(false)) }
    }

    /// Runs one design command; throws the engine's message when it refuses.
    #[napi(catch_unwind)]
    pub fn cad(&mut self, id: String, params: Option<Value>) -> Result<Value> {
        self.ws.cad_execute(&id, &params.unwrap_or_else(|| json!({}))).map_err(fail)
    }

    /// Runs one PCB command (with `undo`, `redo` and the PCB file commands).
    #[napi(catch_unwind)]
    pub fn pcb(&mut self, id: String, params: Option<Value>) -> Result<Value> {
        self.ws.pcb_execute(&id, params.unwrap_or_else(|| json!({}))).map_err(fail)
    }

    #[napi]
    pub fn pcb_inspect(&self) -> Value {
        self.ws.pcb.inspect()
    }

    #[napi]
    pub fn pcb_checks(&self) -> Value {
        self.ws.pcb.checks()
    }

    /// The design's command registry.
    #[napi]
    pub fn commands(&self) -> Value {
        Value::Array(
            viaform_core::solidcraft_engine::command_specs()
                .iter()
                .map(|c| json!({"id": c.id, "label": c.label, "tab": c.tab, "panel": c.panel, "icon": c.icon, "key": c.shortcut, "params": c.params}))
                .collect(),
        )
    }

    #[napi]
    pub fn bounds(&self) -> Value {
        let b = view::bounds(&self.ws.cad);
        if b.is_empty() { Value::Null } else { json!({"min": [b.min.x, b.min.y, b.min.z], "max": [b.max.x, b.max.y, b.max.z]}) }
    }

    #[napi]
    pub fn sketch_plane(&self) -> Value {
        view::open_sketch_plane(&self.ws.cad).map_or(Value::Null, |p| {
            json!({"origin": [p.origin.x, p.origin.y, p.origin.z], "x_dir": [p.x.x, p.x.y, p.x.z], "y_dir": [p.y.x, p.y.y, p.y.z]})
        })
    }

    /// The scene's bodies and lines (edges, sketch curves, axes).
    #[napi(catch_unwind)]
    pub fn scene(&self) -> SceneData {
        let s = viaform_core::scene::build(&self.ws.cad, None);
        SceneData {
            meshes: s
                .meshes
                .into_iter()
                .map(|m| SceneMesh {
                    body: m.body,
                    color: rgba(m.color),
                    positions: Float32Array::new(m.positions),
                    normals: Float32Array::new(m.normals),
                    indices: Uint32Array::new(m.indices),
                    tri_face: Uint32Array::new(m.tri_face),
                    edge_points: Float32Array::new(m.edge_points),
                    edge_offsets: Uint32Array::new(m.edge_offsets),
                })
                .collect(),
            lines: s
                .lines
                .into_iter()
                .map(|l| SceneLine { color: rgba(l.color), width: f64::from(l.width), on_top: l.on_top, points: Float32Array::new(l.points) })
                .collect(),
            radius: f64::from(s.radius),
            background: s.background.iter().map(|&x| f64::from(x)).collect(),
        }
    }

    /// Builds or rebuilds the board as a component of the design.
    #[napi(catch_unwind)]
    pub fn link_push(&mut self) -> Result<Value> {
        viaform_core::link::push(&mut self.ws.cad, &self.ws.pcb).map_err(fail)
    }

    /// Seats the board on a face of `body` at `point` with `normal`, held by a rigid group.
    #[napi(catch_unwind)]
    pub fn link_mount(&mut self, body: String, point: Vec<f64>, normal: Vec<f64>) -> Result<Value> {
        let v3 = |v: &[f64]| -> Result<[f64; 3]> { v.try_into().map_err(|_| fail("a point is three numbers")) };
        viaform_core::link::mount(&mut self.ws.cad, &self.ws.pcb, &body, v3(&point)?, v3(&normal)?).map_err(fail)
    }

    #[napi]
    pub fn link_state(&mut self) -> Value {
        self.ws.link_state()
    }

    /// Saves the whole project (design and electronics) as one `.viaform` file.
    #[napi(catch_unwind)]
    pub fn save(&mut self, path: String) -> Result<Value> {
        viaform_core::project::save(&mut self.ws, std::path::Path::new(&path)).map_err(fail)
    }

    #[napi(catch_unwind)]
    pub fn open(&mut self, path: String) -> Result<Value> {
        viaform_core::project::open(&mut self.ws, std::path::Path::new(&path)).map_err(fail)
    }
}
