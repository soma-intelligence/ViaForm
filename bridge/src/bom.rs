//! The bill of materials (viaform-bom) for the Swift app: one handle per open BOM and one JSON
//! call. The design and PCB calls read the open sessions directly (`assembly.bom`, the PCB
//! project), and the project calls save or open the whole `.viaform` file with `bom.json` in it.
//! Prices refresh through the library handle (`vf_library_call` "search"): the app runs the
//! plan's searches there and hands the hits back with "apply_hits".

use std::ffi::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

use serde_json::{Value, json};
use viaform_bom::{Bom, project};
use viaform_core::Workspace;

use super::{PcbSession, ScSession, guard, out, text};

pub struct VfBom {
    bom: Bom,
}

#[unsafe(no_mangle)]
pub extern "C" fn vf_bom_new() -> *mut VfBom {
    Box::into_raw(Box::new(VfBom { bom: Bom::default() }))
}

/// # Safety
/// `b` is null or came from `vf_bom_new`, and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_bom_free(b: *mut VfBom) {
    if !b.is_null() {
        // SAFETY: `b` came from `Box::into_raw` in `vf_bom_new`.
        drop(unsafe { Box::from_raw(b) });
    }
}

/// Runs `f` on a workspace holding the two sessions, then gives them back, even when `f` panics.
fn with_workspace<T>(sc: &mut ScSession, pcb: &mut PcbSession, f: impl FnOnce(&mut Workspace) -> Result<T, String>) -> Result<T, String> {
    let mut ws = Workspace { cad: std::mem::take(&mut sc.session), pcb: std::mem::take(&mut pcb.session) };
    let r = catch_unwind(AssertUnwindSafe(|| f(&mut ws)));
    sc.session = ws.cad;
    pcb.session = ws.pcb;
    r.unwrap_or_else(|_| Err("the engine stopped on the project file".into()))
}

/// Runs `method` with `params` (JSON) on the BOM. Answers `{"ok": {"result", "state": {bom,
/// rollup}}}` (`export` answers `{"ok": {"text", "filename"}}`) or `{"error": message}`.
///
/// Besides the BOM's own calls (viaform_bom::call): `sync_design` reads `assembly.bom` from
/// `sc`, `sync_pcb` reads the PCB project of `pcb`, `save_project {path}` writes the whole
/// `.viaform` (design, board, bom.json) and `open_project {path}` replaces both sessions and the
/// BOM with the project's (a project without bom.json keeps an empty BOM).
///
/// # Safety
/// `b` is a live BOM; `sc` and `pcb` are null or live sessions; `method` and `params` are
/// NUL-terminated strings (`params` may be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_bom_call(b: *mut VfBom, sc: *mut ScSession, pcb: *mut PcbSession, method: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: the caller passes a live BOM and null or live sessions.
    let (Some(b), sc, pcb) = (unsafe { b.as_mut() }, unsafe { sc.as_mut() }, unsafe { pcb.as_mut() }) else { return out(&json!({"error": "no bill of materials"})) };
    // SAFETY: NUL-terminated strings, per the contract above.
    let (method, params) = unsafe { (text(method), text(params)) };
    let reply = guard(Err("the bill of materials stopped on this call".to_string()), || {
        let mut p: Value = match params {
            Some(p) if !p.trim().is_empty() => serde_json::from_str(p).map_err(|e| format!("params: {e}"))?,
            _ => json!({}),
        };
        let method = method.ok_or("no method")?;
        let today = viaform_bom::today();
        match method {
            "sync_design" => {
                let sc = sc.ok_or("no design is open")?;
                let reply = sc.session.execute("assembly.bom", &json!({})).map_err(|e| e.to_string())?;
                p["reply"] = reply;
            }
            "sync_pcb" => {
                let pcb = pcb.ok_or("no PCB project is open")?;
                p["inspect"] = pcb.session.inspect();
            }
            "save_project" | "open_project" => {
                let (Some(sc), Some(pcb)) = (sc, pcb) else { return Err("the design and the PCB must be open".into()) };
                let path = p.get("path").and_then(Value::as_str).ok_or("path is required")?.to_string();
                let path = Path::new(&path);
                let result = if method == "save_project" {
                    let bom = b.bom.clone();
                    with_workspace(sc, pcb, |ws| project::save(ws, path, &bom))?
                } else {
                    let found = with_workspace(sc, pcb, |ws| project::open(ws, path))?;
                    let had = found.is_some();
                    b.bom = found.unwrap_or_default();
                    json!({"opened": path, "bom": had})
                };
                return Ok(json!({"result": result, "state": viaform_bom::state(&b.bom, &today)}));
            }
            _ => {}
        }
        viaform_bom::call(&mut b.bom, method, &p, &today)
    });
    out(&match reply {
        Ok(v) => json!({ "ok": v }),
        Err(e) => json!({ "error": e }),
    })
}
