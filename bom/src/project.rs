//! The BOM inside the `.viaform` project: one more zip entry, `bom.json`, next to the manifest,
//! the design and the board. A project without it opens as before (no BOM), and a ViaForm that
//! does not know the entry skips it, so the project format stays at its version.

use std::io::{Read, Write};
use std::path::Path;

use serde_json::Value;
use viaform_core::Workspace;

use crate::model::Bom;

pub const ENTRY: &str = "bom.json";

/// Writes `bom` into the project at `path`, keeping every other entry as it is. The project is
/// rewritten beside itself and moved into place.
pub fn write_into(path: &Path, bom: &Bom) -> Result<(), String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a ViaForm project: {e}"))?;
    if zip.by_name("viaform.json").is_err() {
        return Err("not a ViaForm project (no viaform.json)".into());
    }
    let part = path.with_extension("viaform-bom-part");
    {
        let out = std::fs::File::create(&part).map_err(|e| e.to_string())?;
        let mut w = zip::ZipWriter::new(out);
        for i in 0..zip.len() {
            let f = zip.by_index_raw(i).map_err(|e| e.to_string())?;
            if f.name().is_ok_and(|n| n == ENTRY) {
                continue;
            }
            w.raw_copy_file(f).map_err(|e| e.to_string())?;
        }
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        w.start_file(ENTRY, opts).map_err(|e| e.to_string())?;
        w.write_all(&serde_json::to_vec_pretty(bom).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        w.finish().map_err(|e| e.to_string())?;
    }
    std::fs::rename(&part, path).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        e.to_string()
    })
}

/// The BOM saved in the project at `path`; None for a project saved without one.
pub fn read_from(path: &Path) -> Result<Option<Bom>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a ViaForm project: {e}"))?;
    let Ok(mut f) = zip.by_name(ENTRY) else { return Ok(None) };
    let mut v = Vec::new();
    f.read_to_end(&mut v).map_err(|e| e.to_string())?;
    let json: Value = serde_json::from_slice(&v).map_err(|e| format!("bom.json: {e}"))?;
    Bom::from_json(json).map(Some)
}

/// Saves the whole project (the core's format) with the BOM in it.
pub fn save(ws: &mut Workspace, path: &Path, bom: &Bom) -> Result<Value, String> {
    let r = viaform_core::project::save(ws, path)?;
    write_into(path, bom)?;
    Ok(r)
}

/// Opens the project at `path` into `ws` and answers its BOM (None when it has none).
pub fn open(ws: &mut Workspace, path: &Path) -> Result<Option<Bom>, String> {
    viaform_core::project::open(ws, path)?;
    read_from(path)
}
