//! ViaForm's bill of materials: one BOM per project, built from the design's assemblies (part
//! instances with `component_ref`, made parts with material and process), the PCB's components
//! and the component files (`docs/components/<assembly>.json`), rolled up for N builds with
//! price breaks, MOQ, mass and one cart per supplier. Prices and stock refresh through the side
//! libraries' sources ([`viaform_library`]); the BOM saves as `bom.json` in the `.viaform` file.
//!
//! The front ends drive it with one JSON call ([`call`]), like the library.

pub mod export;
pub mod import;
pub mod model;
pub mod project;
pub mod rollup;

use std::path::Path;

use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use viaform_library::types::Hits;

pub use model::{Bom, Line, Made, Offer};
pub use rollup::{Rollup, rollup};

/// Today's date (UTC) as `YYYY-MM-DD`.
pub fn today() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    rollup::date((secs / 86_400) as i64)
}

fn arg<T: DeserializeOwned>(p: &Value, name: &str) -> Result<T, String> {
    serde_json::from_value(p.get(name).cloned().unwrap_or(Value::Null)).map_err(|e| format!("{name}: {e}"))
}

/// The BOM and its rollup, as the front ends show them.
pub fn state(bom: &Bom, today: &str) -> Value {
    json!({"bom": bom, "rollup": rollup(bom, today)})
}

/// Reads a JSON file.
pub fn read_json(path: &Path) -> Result<Value, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

/// Imports every component file (`*.json` with an `assembly`) in `dir`, in name order.
pub fn import_dir(bom: &mut Bom, dir: &Path, today: &str) -> Result<Value, String> {
    let mut paths: Vec<_> = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "json")).collect();
    paths.sort();
    let mut done = vec![];
    let mut errors = vec![];
    for p in paths {
        let v = match read_json(&p) {
            Ok(v) => v,
            Err(e) => {
                errors.push(json!({"path": p, "error": e}));
                continue;
            }
        };
        if v.get("assembly").is_none() || v.get("components").is_none() {
            continue;
        }
        match import::import_component_file(bom, &v, p.to_str(), today) {
            Ok(r) => done.push(r),
            Err(e) => errors.push(json!({"path": p, "error": e})),
        }
    }
    Ok(json!({"imported": done, "errors": errors}))
}

/// Applies `changes` to the line `id`. Fields: qty (the per build count; the source's count
/// clears the override), notes (the user's own), supplier (null: cheapest), excluded, and the
/// source fields mpn, manufacturer, description, category, subassembly, mass_g, made, offers,
/// alternates, which then survive a re-import.
pub fn edit(bom: &mut Bom, id: &str, changes: &Value) -> Result<Value, String> {
    let l = bom.line_mut(id).ok_or_else(|| format!("no line {id}"))?;
    let obj = changes.as_object().ok_or("changes must be an object")?;
    let mut changed = vec![];
    for (k, v) in obj {
        let text = || v.as_str().map(|s| s.trim().to_string()).unwrap_or_default();
        match k.as_str() {
            "qty" => {
                let n = v.as_u64().ok_or("qty must be a whole number")? as u32;
                l.qty_override = (n != l.qty).then_some(n);
            }
            "notes" => l.user_notes = text(),
            "supplier" => l.supplier = v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(String::from),
            "excluded" => l.excluded = v.as_bool().unwrap_or(false),
            "mpn" => l.mpn = text(),
            "manufacturer" => l.manufacturer = text(),
            "description" => l.description = text(),
            "category" => l.category = text().to_lowercase(),
            "subassembly" => l.subassembly = text(),
            "mass_g" => l.mass_g = v.as_f64().filter(|m| m.is_finite() && *m >= 0.0),
            "made" => l.made = serde_json::from_value(v.clone()).map_err(|e| format!("made: {e}"))?,
            "offers" => l.offers = serde_json::from_value(v.clone()).map_err(|e| format!("offers: {e}"))?,
            "alternates" => l.alternates = serde_json::from_value(v.clone()).map_err(|e| format!("alternates: {e}"))?,
            other => return Err(format!("unknown field {other}")),
        }
        if !matches!(k.as_str(), "qty" | "notes" | "supplier" | "excluded") {
            l.edited.insert(k.clone());
        }
        changed.push(k.clone());
    }
    Ok(json!({"changed": changed}))
}

/// Adds a line typed by hand (origin `manual`).
pub fn add(bom: &mut Bom, line: &Value) -> Result<Value, String> {
    let mut base = json!({"id": "", "origin": "manual", "qty": 1});
    if let (Some(b), Some(o)) = (base.as_object_mut(), line.as_object()) {
        b.extend(o.clone());
    }
    let mut l: Line = serde_json::from_value(base).map_err(|e| format!("line: {e}"))?;
    l.origin = "manual".into();
    if l.reference.trim().is_empty() {
        let n = bom.lines.iter().filter(|x| x.origin == "manual").count() + 1;
        l.reference = format!("X{n}");
    }
    l.id = format!("manual:{}", l.reference.trim());
    if bom.line(&l.id).is_some() {
        return Err(format!("a line {} exists already", l.reference));
    }
    if l.subassembly.is_empty() {
        l.subassembly = "Other".into();
    }
    let id = l.id.clone();
    bom.lines.push(l);
    Ok(json!({"id": id}))
}

/// One JSON call from a front end. `method` names the action; the answer is the value the
/// front end shows (most calls answer the whole state, so one call refreshes the table).
/// The design and PCB calls take the engines' own replies (`assembly.bom`, `pcb_inspect`):
/// the bridge reads them from the open sessions.
pub fn call(bom: &mut Bom, method: &str, p: &Value, today: &str) -> Result<Value, String> {
    let result = match method {
        "state" => Value::Null,
        "new" => {
            *bom = Bom { name: arg::<Option<String>>(p, "name")?.unwrap_or_default(), ..Bom::default() };
            Value::Null
        }
        "set" => {
            if let Some(b) = arg::<Option<u32>>(p, "builds")? {
                bom.builds = b.max(1);
            }
            if let Some(n) = arg::<Option<String>>(p, "name")? {
                bom.name = n;
            }
            Value::Null
        }
        "import_file" => match arg::<Option<String>>(p, "path")? {
            Some(path) => import::import_component_file(bom, &read_json(Path::new(&path))?, Some(&path), today)?,
            None => import::import_component_file(bom, p.get("file").ok_or("path or file is required")?, None, today)?,
        },
        "import_assembly" => {
            let path = arg::<String>(p, "path")?;
            let asm_path = Path::new(&path);
            let asm = read_json(asm_path)?;
            let comps_path = match arg::<Option<String>>(p, "components")? {
                Some(c) => Some(std::path::PathBuf::from(c)),
                None => import::component_file_for(&asm, asm_path),
            };
            let comps = comps_path.as_deref().map(read_json).transpose()?;
            let mut r = import::import_assembly(bom, &asm, comps.as_ref(), asm_path.parent(), Some(&path), today)?;
            r["components"] = json!(comps_path.map(|c| c.to_string_lossy().into_owned()));
            r
        }
        "import_dir" => import_dir(bom, Path::new(&arg::<String>(p, "dir")?), today)?,
        "sync_design" => import::sync_design(bom, p.get("reply").ok_or("reply is required")?, today)?,
        "sync_pcb" => import::sync_pcb(bom, p.get("inspect").ok_or("inspect is required")?, today)?,
        "edit" => edit(bom, &arg::<String>(p, "id")?, p.get("changes").ok_or("changes is required")?)?,
        "add" => add(bom, p.get("line").unwrap_or(&json!({})))?,
        "remove" => {
            let id = arg::<String>(p, "id")?;
            let n = bom.lines.len();
            bom.lines.retain(|l| l.id != id);
            json!({"removed": n - bom.lines.len()})
        }
        "remove_origin" => {
            let o = arg::<String>(p, "origin")?;
            bom.lines.retain(|l| l.origin != o);
            bom.imports.retain(|i| i.origin != o);
            if o == "design" {
                bom.design_links.clear();
            }
            Value::Null
        }
        "refresh_plan" => import::refresh_plan(bom),
        "apply_hits" => import::apply_hits(bom, &arg::<String>(p, "mpn")?, &arg::<Vec<Hits>>(p, "hits")?, today),
        "export" => {
            let r = rollup(bom, today);
            let name = if bom.name.is_empty() { "bom".to_string() } else { bom.name.replace(['/', ':'], "-") };
            let (text, file) = match arg::<String>(p, "format")?.as_str() {
                "csv" => (export::table(bom, &r), format!("{name}.csv")),
                "digikey" => (export::digikey(&r)?, format!("{name}-digikey.csv")),
                "mouser" => (export::mouser(&r)?, format!("{name}-mouser.csv")),
                "supplier" => {
                    let s = arg::<String>(p, "supplier")?;
                    (export::supplier(&r, &s)?, format!("{name}-{}.csv", model::norm(&s)))
                }
                f => return Err(format!("unknown export {f}")),
            };
            return Ok(json!({"text": text, "filename": file}));
        }
        "save" => {
            let path = arg::<String>(p, "path")?;
            std::fs::write(&path, serde_json::to_vec_pretty(bom).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            json!({"saved": path})
        }
        "load" => {
            *bom = Bom::from_json(read_json(Path::new(&arg::<String>(p, "path")?))?)?;
            Value::Null
        }
        "write_into" => {
            let path = arg::<String>(p, "path")?;
            project::write_into(Path::new(&path), bom)?;
            json!({"saved": path})
        }
        "read_from" => {
            let path = arg::<String>(p, "path")?;
            match project::read_from(Path::new(&path))? {
                Some(b) => {
                    *bom = b;
                    json!({"found": true})
                }
                None => json!({"found": false}),
            }
        }
        _ => return Err(format!("unknown bom call {method}")),
    };
    Ok(json!({"result": result, "state": state(bom, today)}))
}
