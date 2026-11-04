//! The `.viaform` file: one project holding the 3D design and the electronics, so they open,
//! save and travel together. It is a zip with `viaform.json` (format and version),
//! `design.solidcraft` (the SolidCraft design file) and `board.pcbcraft` (the PCBCraft project).

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::Workspace;

pub const FORMAT_VERSION: u64 = 1;
const MANIFEST: &str = "viaform.json";
const DESIGN: &str = "design.solidcraft";
const BOARD: &str = "board.pcbcraft";

/// A scratch folder for the engines' own file commands, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Result<Self, String> {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
        let dir = std::env::temp_dir().join(format!("viaform-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        Ok(Self(dir))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Writes the workspace to `path` (written to a sibling file first, then moved into place).
pub fn save(ws: &mut Workspace, path: &Path) -> Result<Value, String> {
    let tmp = Scratch::new()?;
    let design = tmp.0.join(DESIGN);
    let board = tmp.0.join(BOARD);
    ws.cad_execute("file.save_as", &json!({"path": design}))
        .or_else(|_| ws.cad_execute("file.save", &json!({"path": design})))?;
    pcbcraft_io::save(&ws.pcb.project, &board)?;
    // The PCB revision travels with the file: the 3D board is tagged with it, so a reopened
    // project would otherwise read as out of date with a fresh session counter.
    let manifest = json!({"format": "viaform", "version": FORMAT_VERSION, "app": env!("CARGO_PKG_VERSION"), "pcb_revision": ws.pcb_revision()});

    let part = path.with_extension("viaform-part");
    {
        let file = std::fs::File::create(&part).map_err(|e| e.to_string())?;
        let mut zip = zip::ZipWriter::new(file);
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (name, bytes) in [
            (MANIFEST, serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?),
            (DESIGN, std::fs::read(&design).map_err(|e| e.to_string())?),
            (BOARD, std::fs::read(&board).map_err(|e| e.to_string())?),
        ] {
            zip.start_file(name, opts).map_err(|e| e.to_string())?;
            zip.write_all(&bytes).map_err(|e| e.to_string())?;
        }
        zip.finish().map_err(|e| e.to_string())?;
    }
    std::fs::rename(&part, path).map_err(|e| e.to_string())?;
    Ok(json!({"saved": path}))
}

/// Replaces the workspace with the project at `path`. A file from a newer ViaForm is refused
/// rather than half read.
pub fn open(ws: &mut Workspace, path: &Path) -> Result<Value, String> {
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a ViaForm project: {e}"))?;
    let mut read = |name: &str| -> Result<Vec<u8>, String> {
        let mut f = zip.by_name(name).map_err(|_| format!("{name} is missing from the project"))?;
        let mut v = Vec::new();
        f.read_to_end(&mut v).map_err(|e| e.to_string())?;
        Ok(v)
    };
    let manifest: Value = serde_json::from_slice(&read(MANIFEST)?).map_err(|e| e.to_string())?;
    if manifest.get("format").and_then(Value::as_str) != Some("viaform") {
        return Err("not a ViaForm project".into());
    }
    let version = manifest.get("version").and_then(Value::as_u64).unwrap_or(0);
    if version > FORMAT_VERSION {
        return Err(format!("this project was saved by a newer ViaForm (format {version}); update ViaForm to open it"));
    }
    let tmp = Scratch::new()?;
    let design = tmp.0.join(DESIGN);
    let board = tmp.0.join(BOARD);
    std::fs::write(&design, read(DESIGN)?).map_err(|e| e.to_string())?;
    std::fs::write(&board, read(BOARD)?).map_err(|e| e.to_string())?;

    let project = pcbcraft_io::load(&board)?;
    let mut fresh = Workspace::default();
    fresh.cad_execute("doc.open", &json!({"path": design}))?;
    fresh.pcb.replace(project).map_err(|e| e.to_string())?;
    if let Some(revision) = manifest.get("pcb_revision").and_then(Value::as_u64) {
        fresh.pcb.revision = revision;
    }
    *ws = fresh;
    Ok(json!({"opened": path, "version": version}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_project_round_trips() {
        let mut ws = Workspace::new(true);
        ws.cad_execute("solid.box", &json!({"length": 10, "width": 10, "height": 10, "body_name": "Cube"})).unwrap();
        crate::link::push(&mut ws.cad, &ws.pcb).unwrap();
        let dir = Scratch::new().unwrap();
        let path = dir.0.join("demo.viaform");
        save(&mut ws, &path).unwrap();

        let mut back = Workspace::default();
        open(&mut back, &path).unwrap();
        let names: Vec<String> = back.cad.world_state().unwrap().bodies.iter().map(|b| b.name.clone()).collect();
        assert!(names.iter().any(|n| n == "Cube"), "{names:?}");
        assert!(names.iter().any(|n| n == "PCB Board"), "{names:?}");
        assert_eq!(back.pcb.project, ws.pcb.project);
        assert!(crate::link::linked_revision(&mut back.cad, &back.pcb).is_some());
        assert_eq!(back.link_state()["out_of_date"], json!(false), "a reopened board is still in sync");
    }

    #[test]
    fn a_newer_format_is_refused() {
        let dir = Scratch::new().unwrap();
        let path = dir.0.join("future.viaform");
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&path).unwrap());
        zip.start_file(MANIFEST, zip::write::SimpleFileOptions::default()).unwrap();
        zip.write_all(br#"{"format":"viaform","version":99}"#).unwrap();
        zip.finish().unwrap();
        let err = open(&mut Workspace::default(), &path).unwrap_err();
        assert!(err.contains("newer ViaForm"), "{err}");
    }
}
