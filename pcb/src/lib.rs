//! Clean-room PCB engine: schematic, board, rules, routing, KiCad and Gerber output.
//!
//! Written from ViaForm's own interface descriptions and public format documentation only
//! (see `CLEANROOM.md`). Licence MIT OR Apache-2.0.
//!
//! Entry points: [`Session`] (one project, JSON commands with undo and redo) and [`call`], the
//! stateless facade shared with the other engines.

pub mod checks;
pub mod copper;
pub mod engine;
pub mod error;
pub mod fab;
pub mod geom;
pub mod kicad;
pub mod library;
pub mod model;
pub mod netlist;
pub mod router;
pub mod sample;
pub mod sexpr;
pub mod zones;

pub use engine::{commands, from_vfpcb, to_vfpcb, Session};
pub use error::{EngineError, Result};
pub use model::Project;

use serde_json::{json, Value};

/// Stateless facade: `params.project` (a `.vfpcb` document, optional) is loaded, the command
/// runs, and the reply carries the command result plus the updated project.
pub fn call(op: &str, params: &Value) -> Result<Value> {
    if op == "commands" || op == "commands.list" {
        return Ok(commands());
    }
    let mut s = Session::new();
    if let Some(p) = params.get("project") {
        s.project = serde_json::from_value(p.clone()).map_err(|e| EngineError::new("format", format!("Bad project: {e}")))?;
    }
    let args = params.get("params").cloned().unwrap_or_else(|| json!({}));
    let out = s.call(op, &args)?;
    Ok(json!({"reply": out, "project": s.project}))
}
