//! The pipeline inside the `.viaform` project: one more zip entry, `flow.json`, beside the
//! manifest, the design and the board (like `bom.json`). A project saved without it opens on a
//! fresh pipeline, and a ViaForm that does not know the entry skips it, so the project format
//! stays at its version. The same document is what a front end keeps between launches.
//!
//! Saved: the graph, every revision of every artifact and which one is in use, failures and
//! notes, the browser's eyes and locks, the reported tree items and the selection. Not saved:
//! running jobs. A job that was running when the project was saved comes back as a note on its
//! artifact, which keeps its last build.

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::Path;

use serde_json::{Value, json};

use super::tree::{Flags, Selection, TreeItem};
use super::{Flow, Graph, Node, Revision};

pub const ENTRY: &str = "flow.json";
pub const FORMAT: &str = "viaform-flow";
pub const VERSION: u64 = 1;

/// The pipeline as a JSON document.
pub fn to_doc(f: &Flow) -> Value {
    let nodes: BTreeMap<&str, Value> = f
        .nodes
        .iter()
        .filter(|(_, n)| !n.revisions.is_empty() || n.error.is_some() || n.note.is_some())
        .map(|(id, n)| (id.as_str(), json!({"active": n.active, "revisions": n.revisions, "error": n.error, "note": n.note})))
        .collect();
    json!({
        "format": FORMAT,
        "version": VERSION,
        "graph": f.graph,
        "nodes": nodes,
        "flags": f.trees.flags,
        "items": f.trees.items,
        "selection": f.trees.selection,
        "interrupted": f.jobs.iter().map(|j| json!({"artifact": j.artifact, "label": j.label})).collect::<Vec<_>>(),
    })
}

/// A pipeline from its document. A document from a newer ViaForm is refused rather than half
/// read; a document without a graph gets the drone chain.
pub fn from_doc(doc: &Value) -> Result<Flow, String> {
    if doc["format"].as_str() != Some(FORMAT) {
        return Err("not a ViaForm pipeline".into());
    }
    let version = doc["version"].as_u64().unwrap_or(0);
    if version > VERSION {
        return Err(format!("this pipeline was saved by a newer ViaForm (format {version}); update ViaForm to open it"));
    }
    let graph: Graph = match doc.get("graph").filter(|g| !g.is_null()) {
        Some(g) => serde_json::from_value(g.clone()).map_err(|e| format!("graph: {e}"))?,
        None => Graph::drone(),
    };
    let mut f = Flow::with_graph(graph)?;
    if let Some(nodes) = doc["nodes"].as_object() {
        for (id, n) in nodes {
            // An artifact the graph no longer has is dropped.
            let Some(slot) = f.nodes.get_mut(id) else { continue };
            let revisions: Vec<Revision> = serde_json::from_value(n["revisions"].clone()).map_err(|e| format!("{id}: {e}"))?;
            let active = n["active"].as_u64().unwrap_or(0);
            *slot = Node {
                active: if revisions.iter().any(|r| r.number == active) { active } else { revisions.last().map_or(0, |r| r.number) },
                revisions,
                error: n["error"].as_str().map(str::to_owned),
                note: n["note"].as_str().map(str::to_owned),
            };
        }
    }
    let flags: BTreeMap<String, Flags> = serde_json::from_value(doc.get("flags").cloned().unwrap_or(json!({}))).unwrap_or_default();
    let items: BTreeMap<String, Vec<TreeItem>> = serde_json::from_value(doc.get("items").cloned().unwrap_or(json!({}))).unwrap_or_default();
    let selection: Selection = serde_json::from_value(doc.get("selection").cloned().unwrap_or(json!({}))).unwrap_or_default();
    f.trees.flags = flags;
    f.trees.items = items;
    f.trees.selection = selection;
    for j in doc["interrupted"].as_array().into_iter().flatten() {
        if let Some(n) = j["artifact"].as_str().and_then(|a| f.nodes.get_mut(a)) {
            n.note = Some(format!("{} was running when the project was saved", j["label"].as_str().unwrap_or("A job")));
        }
    }
    Ok(f)
}

/// Writes the pipeline into the project at `path`, keeping every other entry as it is. The
/// project is rewritten beside itself and moved into place.
pub fn write_into(path: &Path, f: &Flow) -> Result<(), String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a ViaForm project: {e}"))?;
    if zip.by_name("viaform.json").is_err() {
        return Err("not a ViaForm project (no viaform.json)".into());
    }
    let part = path.with_extension("viaform-flow-part");
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
        w.write_all(&serde_json::to_vec_pretty(&to_doc(f)).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
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

/// The pipeline saved in the project at `path`; None for a project saved without one.
pub fn read_from(path: &Path) -> Result<Option<Flow>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a ViaForm project: {e}"))?;
    let Ok(mut entry) = zip.by_name(ENTRY) else { return Ok(None) };
    let mut v = Vec::new();
    entry.read_to_end(&mut v).map_err(|e| e.to_string())?;
    let doc: Value = serde_json::from_slice(&v).map_err(|e| format!("{ENTRY}: {e}"))?;
    from_doc(&doc).map(Some)
}
