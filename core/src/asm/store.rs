//! The assembly inside the `.viaform` project (`assembly.json`, beside `flow.json` and
//! `bom.json`), and as the pipeline artifact `assemble.assembly`.
//!
//! Saving rewrites the project beside itself with every other entry copied as it is, then moves
//! it into place. Registering the assembly with the pipeline makes a revision ("Assembly v4")
//! built from the current design model, generated parts and board; when any of those moves on,
//! the pipeline reads the assembly as stale ("Frame v12 replaced v11") until it is saved again.

use std::io::{Read, Write};
use std::path::Path;

use serde_json::{Value, json};

use super::model::{Assembly, ENTRY};
use crate::flow::{Build, Built, Flow};

/// The pipeline artifact the assembly is.
pub const ARTIFACT: &str = "assemble.assembly";

/// Writes `assembly.json` into the project at `path`, keeping every other entry.
pub fn write_into(path: &Path, asm: &Assembly) -> Result<(), String> {
    asm.validate()?;
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a ViaForm project: {e}"))?;
    if zip.by_name("viaform.json").is_err() {
        return Err("not a ViaForm project (no viaform.json)".into());
    }
    let part = path.with_extension("viaform-asm-part");
    let written = (|| -> Result<(), String> {
        let out = std::fs::File::create(&part).map_err(|e| e.to_string())?;
        let mut w = zip::ZipWriter::new(out);
        for i in 0..zip.len() {
            let entry = zip.by_index_raw(i).map_err(|e| e.to_string())?;
            if entry.name().is_ok_and(|n| n == ENTRY) {
                continue;
            }
            w.raw_copy_file(entry).map_err(|e| e.to_string())?;
        }
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        w.start_file(ENTRY, opts).map_err(|e| e.to_string())?;
        w.write_all(&serde_json::to_vec_pretty(&asm.to_json()).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        w.finish().map_err(|e| e.to_string())?;
        Ok(())
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&part);
        return Err(e);
    }
    std::fs::rename(&part, path).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        e.to_string()
    })
}

/// The assembly saved in the project at `path`; None for a project saved without one.
pub fn read_from(path: &Path) -> Result<Option<Assembly>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a ViaForm project: {e}"))?;
    let Ok(mut entry) = zip.by_name(ENTRY) else { return Ok(None) };
    let mut v = Vec::new();
    entry.read_to_end(&mut v).map_err(|e| e.to_string())?;
    let doc: Value = serde_json::from_slice(&v).map_err(|e| format!("{ENTRY}: {e}"))?;
    Assembly::from_json(&doc).map(Some)
}

/// What the pipeline shows of an assembly revision.
pub fn summary(asm: &Assembly) -> (String, Value) {
    let driven = asm.joints.iter().filter(|j| j.drive() != "none").count();
    let text = format!("{} components, {} joints, {} DOF", asm.components.len(), asm.joints.len(), asm.dof());
    (text, json!({"components": asm.components.len(), "joints": asm.joints.len(), "dof": asm.dof(), "driven": driven}))
}

/// The `produce` command for `vf_flow_command`, so a front end registers the assembly with its
/// pipeline handle: `{"op": "produce", "artifact": "assemble.assembly", ...}`.
pub fn produce_command(asm: &Assembly) -> Value {
    let (text, data) = summary(asm);
    json!({"op": "produce", "artifact": ARTIFACT, "summary": text, "fingerprint": asm.fingerprint(), "data": data, "source": "edit", "amend_within": 30.0})
}

/// Records the assembly as a revision of `assemble.assembly`, built from the current revisions of
/// its inputs. Saving the same content again changes nothing; edits within 30 s fold into one
/// revision.
pub fn record(flow: &mut Flow, asm: &Assembly) -> Result<Built, String> {
    asm.validate()?;
    let (text, data) = summary(asm);
    flow.produce(ARTIFACT, Build { summary: Some(text), fingerprint: Some(asm.fingerprint()), amend_within: Some(30.0), data, source: Some("edit".into()), from: None })
}
