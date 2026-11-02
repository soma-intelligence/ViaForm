//! ViaForm's shared core, used by every front end (the Swift apps through the C bridge, the
//! Electron app through the Node addon).
//!
//! A [`Workspace`] holds the two engines side by side: a SolidCraft design (3D CAD) and a
//! PCBCraft project (schematic and board). Everything that crosses between them lives here, so
//! both front ends behave as one product: the PCB file commands, the scene the 3D view draws,
//! the board to 3D link ([`link`]) and the single `.viaform` project file ([`project`]).

use serde_json::{Value, json};

pub mod link;
pub mod project;
pub mod scene;

pub use solidcraft_engine;
pub use pcbcraft_engine;

/// One open ViaForm project: the 3D design and the electronics, edited together.
#[derive(Default)]
pub struct Workspace {
    pub cad: solidcraft_engine::Session,
    pub pcb: pcbcraft_engine::Session,
}

impl Workspace {
    /// A workspace with an empty design and the PCB engine's sample board when `sample` is set.
    pub fn new(sample: bool) -> Self {
        let pcb = if sample { pcbcraft_engine::Session::sample().unwrap_or_default() } else { pcbcraft_engine::Session::default() };
        Self { cad: solidcraft_engine::Session::default(), pcb }
    }

    /// Runs one design command.
    pub fn cad_execute(&mut self, id: &str, params: &Value) -> Result<Value, String> {
        self.cad.execute(id, params).map_err(|e| e.to_string())
    }

    /// Runs one PCB command, with `undo`, `redo` and the PCB file commands on top of the engine's.
    pub fn pcb_execute(&mut self, id: &str, params: Value) -> Result<Value, String> {
        pcb_execute(&mut self.pcb, id, params)
    }

    /// The PCB project's revision: it moves on every change, undo and redo.
    pub fn pcb_revision(&self) -> u64 {
        self.pcb.inspect().get("revision").and_then(Value::as_u64).unwrap_or(0)
    }

    /// What a front end shows about the link: the revision the 3D board was built from, and
    /// whether the board changed since.
    pub fn link_state(&mut self) -> Value {
        let rev = self.pcb_revision();
        let linked = link::linked_revision(&mut self.cad, &self.pcb);
        json!({"linked_revision": linked, "revision": rev, "out_of_date": linked.is_some_and(|l| l != rev)})
    }
}

/// `undo`, `redo`, `file.open`, `file.save` (PCBCraft JSON project) and `file.export_kicad`
/// (a `.kicad_pcb` board), each file command with `{"path": ...}`, then the engine's commands.
pub fn pcb_execute(s: &mut pcbcraft_engine::Session, id: &str, p: Value) -> Result<Value, String> {
    match id {
        "undo" => s.undo().map_err(|e| e.to_string()),
        "redo" => s.redo().map_err(|e| e.to_string()),
        "file.open" | "file.save" | "file.export_kicad" => {
            let path = p.get("path").and_then(Value::as_str).ok_or("path is required")?;
            let path = std::path::Path::new(path);
            match id {
                "file.open" => pcbcraft_io::load(path).and_then(|project| s.replace(project).map_err(|e| e.to_string())),
                "file.save" => pcbcraft_io::save(&s.project, path).map(|()| json!({"saved": path})),
                _ => pcbcraft_io::kicad_board(&s.project)
                    .and_then(|text| pcbcraft_io::atomic_write(path, text.as_bytes()))
                    .map(|()| json!({"exported": path})),
            }
        }
        _ => s.execute(id, p, None).map_err(|e| e.to_string()),
    }
}
