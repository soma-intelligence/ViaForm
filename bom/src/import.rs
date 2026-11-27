//! Where lines come from: component files (`docs/components/<assembly>.json`), the design's
//! assemblies (`assembly.bom` rows and their `component_ref` property), the PCB's components
//! (`pcb_inspect`), and the library's search results for a price and stock refresh.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use serde_json::{Map, Value, json};
use viaform_library::types::Hits;

use crate::model::{Bom, Break, DesignLink, Import, Line, Made, Offer, norm, same_offer};

// MARK: Component files

#[derive(Deserialize)]
struct FileBreak {
    qty: u32,
    #[serde(alias = "unit_price")]
    unit_price_usd: f64,
}

#[derive(Deserialize)]
struct FileOffer {
    supplier: String,
    #[serde(default)]
    sku: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    unit_price_usd: Option<f64>,
    #[serde(default)]
    moq: Option<u32>,
    #[serde(default)]
    stock_note: Option<String>,
    #[serde(default)]
    checked_on: Option<String>,
    #[serde(default, alias = "breaks")]
    price_breaks: Vec<FileBreak>,
    /// The price of one pack of `moq` (screws by ten, props by four).
    #[serde(default)]
    pack_price_usd: Option<f64>,
}

#[derive(Deserialize)]
struct FileComponent {
    #[serde(rename = "ref")]
    reference: String,
    qty: u32,
    #[serde(default)]
    category: String,
    #[serde(default)]
    mpn: String,
    #[serde(default)]
    manufacturer: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    key_specs: Map<String, Value>,
    #[serde(default)]
    dims_mm: Option<Vec<f64>>,
    #[serde(default)]
    mass_g: Option<f64>,
    #[serde(default)]
    datasheet_url: Option<String>,
    #[serde(default)]
    cad_source: Option<String>,
    #[serde(default)]
    offers: Vec<FileOffer>,
    #[serde(default)]
    alternates: Vec<String>,
    #[serde(default)]
    used_by: Vec<String>,
    #[serde(default)]
    notes: Option<String>,
    /// A part the project makes itself, rather than buys (`made: {material, process}`).
    #[serde(default)]
    made: Option<Made>,
}

#[derive(Deserialize)]
struct ComponentFile {
    assembly: String,
    version: u32,
    #[serde(default)]
    checked_on: Option<String>,
    #[serde(default)]
    currency: Option<String>,
    components: Vec<FileComponent>,
}

pub const CATEGORIES: &[&str] = &[
    "motor", "gearbox", "driver", "mcu", "sensor", "power", "battery", "bearing", "fastener", "insert", "tendon", "spring", "pulley", "shaft", "connector",
    "cable", "pcb", "propeller", "camera", "radio", "other",
];

/// The subassembly a component file's line belongs to: the first `used_by` entry, before any `/`.
fn subassembly_of(used_by: &[String], assembly: &str) -> String {
    used_by.first().and_then(|u| u.split(['/', ':']).next()).map(str::trim).filter(|s| !s.is_empty()).map(String::from).unwrap_or_else(|| assembly.to_string())
}

fn clean(s: Option<String>) -> Option<String> {
    s.map(|s| s.trim().to_string()).filter(|s| !s.is_empty() && s != "null")
}

/// Reads a component file into lines of its assembly. Answers the lines and what looked wrong
/// (unknown category, offers without price), which the rollup flags too. Refused: a newer file
/// version, a currency other than USD, two components with one ref.
pub fn component_file(v: &Value) -> Result<(String, Import, Vec<Line>, Vec<String>), String> {
    let f: ComponentFile = serde_json::from_value(v.clone()).map_err(|e| format!("component file: {e}"))?;
    if f.version > 1 {
        return Err(format!("component file version {} is newer than this ViaForm reads (1)", f.version));
    }
    if let Some(c) = &f.currency
        && !c.eq_ignore_ascii_case("USD")
    {
        return Err(format!("component file currency {c}: only USD is read"));
    }
    let assembly = f.assembly.trim().to_lowercase();
    if assembly.is_empty() {
        return Err("component file: assembly is empty".into());
    }
    let mut seen = BTreeSet::new();
    let mut warnings = vec![];
    let mut lines = vec![];
    for c in f.components {
        let r = c.reference.trim().to_string();
        if r.is_empty() {
            return Err("component file: a component has an empty ref".into());
        }
        if !seen.insert(r.clone()) {
            return Err(format!("component file: ref {r} is used twice"));
        }
        let category = c.category.trim().to_lowercase();
        if !CATEGORIES.contains(&category.as_str()) {
            warnings.push(format!("{r}: unknown category `{category}`"));
        }
        let offers: Vec<Offer> = c
            .offers
            .into_iter()
            .map(|o| {
                let mut breaks: Vec<Break> = o.price_breaks.into_iter().filter(|b| b.qty > 0 && b.unit_price_usd.is_finite() && b.unit_price_usd >= 0.0).map(|b| Break { qty: b.qty, unit_price: b.unit_price_usd }).collect();
                breaks.sort_by_key(|b| b.qty);
                let moq = o.moq.unwrap_or(1).max(1);
                let pack = (moq > 1 && o.pack_price_usd.is_some()).then_some(moq);
                let unit = o.unit_price_usd.or_else(|| o.pack_price_usd.map(|p| p / moq as f64));
                Offer {
                    supplier: o.supplier.trim().to_string(),
                    sku: o.sku.unwrap_or_default().trim().to_string(),
                    url: clean(o.url),
                    unit_price_usd: unit.filter(|p| p.is_finite() && *p >= 0.0),
                    breaks,
                    moq,
                    pack,
                    stock: None,
                    stock_note: clean(o.stock_note),
                    checked_on: clean(o.checked_on).or_else(|| f.checked_on.clone()),
                    via: "file".into(),
                }
            })
            .collect();
        let checked_on = offers.iter().filter_map(|o| o.checked_on.clone()).max().or_else(|| f.checked_on.clone());
        let dims_mm = c.dims_mm.filter(|d| d.len() == 3).map(|d| [d[0], d[1], d[2]]);
        lines.push(Line {
            id: format!("{assembly}:{r}"),
            origin: assembly.clone(),
            reference: r,
            qty: c.qty,
            category,
            mpn: c.mpn.trim().to_string(),
            manufacturer: c.manufacturer.trim().to_string(),
            description: c.description.trim().to_string(),
            key_specs: c.key_specs,
            dims_mm,
            mass_g: c.mass_g.filter(|m| m.is_finite() && *m >= 0.0),
            made: c.made,
            subassembly: subassembly_of(&c.used_by, &assembly),
            datasheet_url: clean(c.datasheet_url),
            cad_source: clean(c.cad_source),
            offers,
            alternates: c.alternates.into_iter().map(|a| a.trim().to_string()).filter(|a| !a.is_empty()).collect(),
            used_by: c.used_by,
            notes: c.notes.unwrap_or_default(),
            checked_on,
            ..Line::default()
        });
    }
    let import = Import { origin: assembly.clone(), kind: "component_file".into(), path: None, version: Some(f.version), checked_on: f.checked_on, lines: lines.len(), imported_on: String::new() };
    Ok((assembly, import, lines, warnings))
}

fn record(bom: &mut Bom, mut import: Import, today: &str) {
    import.imported_on = today.to_string();
    bom.imports.retain(|i| i.origin != import.origin);
    bom.imports.push(import);
}

/// Imports a component file into `bom`, replacing that assembly's lines (user edits kept).
pub fn import_component_file(bom: &mut Bom, v: &Value, path: Option<&str>, today: &str) -> Result<Value, String> {
    let (assembly, mut import, lines, warnings) = component_file(v)?;
    import.path = path.map(String::from);
    let n = lines.len();
    bom.replace_origin(&assembly, lines);
    record(bom, import, today);
    // A design synced before keeps its links to the refs of this file.
    relink(bom);
    Ok(json!({"assembly": assembly, "lines": n, "warnings": warnings}))
}

// MARK: The design

fn prop<'a>(p: &'a Value, names: &[&str]) -> Option<&'a str> {
    names.iter().find_map(|n| p.get(*n).and_then(Value::as_str)).map(str::trim).filter(|s| !s.is_empty())
}

fn num(p: &Value, names: &[&str]) -> Option<f64> {
    prop(p, names).and_then(|s| s.trim_end_matches(|c: char| c.is_alphabetic() || c == ' ').trim().parse::<f64>().ok()).filter(|n| n.is_finite() && *n >= 0.0)
}

const DESIGN: &str = "design";

/// Reads `assembly.bom` rows (`levels: flat`) into the BOM. A row whose components carry
/// `component_ref` (`M1` or `hand:M1`) counts toward that component file line (`placed`); a
/// purchased row or one with an `mpn` property is a bought line; any other row is a made part
/// (properties `material`, `process`, `mass_g`, `cost_usd`).
pub fn sync_design(bom: &mut Bom, reply: &Value, today: &str) -> Result<Value, String> {
    let rows = reply.get("rows").and_then(Value::as_array).ok_or("the design's bill of materials has no rows")?;
    let mut fresh: Vec<Line> = vec![];
    let mut refs: Vec<(String, u64, Vec<u64>, Vec<String>)> = vec![];
    for row in rows {
        let props = row.get("properties").cloned().unwrap_or(json!({}));
        let count = row.get("count").and_then(Value::as_u64).unwrap_or(0);
        let part_number = row.get("part_number").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let definition = row.get("definition").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let comps: Vec<u64> = row.get("components").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_u64).collect()).unwrap_or_default();
        let defs: Vec<String> = definition.split("; ").filter(|d| !d.is_empty()).map(String::from).collect();
        let bom_type = row.get("bom_type").and_then(Value::as_str).unwrap_or("normal");
        if let Some(cref) = prop(&props, &["component_ref"]) {
            refs.push((cref.to_string(), count, comps.clone(), defs.clone()));
            continue;
        }
        let key = if part_number.is_empty() { definition.clone() } else { part_number.clone() };
        let mpn = prop(&props, &["mpn"]).map(String::from).or_else(|| (bom_type == "purchased").then(|| part_number.clone())).unwrap_or_default();
        let bought = bom_type == "purchased" || !mpn.is_empty();
        let made = (!bought).then(|| Made {
            material: prop(&props, &["material"]).unwrap_or("").to_string(),
            process: prop(&props, &["process"]).unwrap_or("").to_string(),
            unit_cost_usd: num(&props, &["cost_usd", "unit_cost_usd"]),
        });
        let mut offers = vec![];
        if bought && let Some(s) = prop(&props, &["supplier"]) {
            offers.push(Offer {
                supplier: s.to_string(),
                sku: prop(&props, &["sku"]).unwrap_or("").to_string(),
                url: prop(&props, &["url"]).map(String::from),
                unit_price_usd: num(&props, &["unit_price_usd", "price_usd"]),
                moq: num(&props, &["moq"]).map_or(1, |m| (m as u32).max(1)),
                checked_on: prop(&props, &["checked_on"]).map(String::from),
                via: "file".into(),
                ..Offer::default()
            });
        }
        let row_desc = row.get("description").and_then(Value::as_str).unwrap_or("").trim().to_string();
        fresh.push(Line {
            id: format!("{DESIGN}:{key}"),
            origin: DESIGN.into(),
            reference: definition.clone(),
            qty: count as u32,
            category: prop(&props, &["category"]).unwrap_or(if bought { "other" } else { "made" }).to_string(),
            mpn,
            manufacturer: prop(&props, &["manufacturer"]).unwrap_or("").to_string(),
            description: if row_desc.is_empty() { definition.clone() } else { row_desc },
            mass_g: num(&props, &["mass_g"]).or_else(|| num(&props, &["mass_kg"]).map(|k| k * 1000.0)),
            made,
            subassembly: prop(&props, &["subassembly"]).unwrap_or("Design").to_string(),
            offers,
            notes: prop(&props, &["notes"]).unwrap_or("").to_string(),
            checked_on: prop(&props, &["checked_on"]).map(String::from),
            components: comps,
            definitions: defs,
            ..Line::default()
        });
    }
    let n = fresh.len();
    bom.replace_origin(DESIGN, fresh);
    let kept = assembly_origins(bom);
    bom.lines.iter_mut().for_each(|l| {
        if l.origin != DESIGN && !kept.contains(&l.origin) {
            l.placed = None;
            l.components.clear();
            l.definitions.clear();
        }
    });
    let mut unknown = vec![];
    let mut linked = 0;
    for (cref, count, comps, defs) in &refs {
        if link(bom, cref, *count, comps, defs) {
            linked += 1;
        } else {
            unknown.push(cref.clone());
        }
    }
    bom.design_links = refs.iter().map(|(r, c, comps, defs)| DesignLink { reference: r.clone(), count: *c, components: comps.clone(), definitions: defs.clone() }).collect();
    record(bom, Import { origin: DESIGN.into(), kind: "design".into(), lines: n, ..Default::default() }, today);
    Ok(json!({"lines": n, "linked": linked, "unknown_refs": unknown}))
}

/// Applies the design's saved component_ref links again (after a component file import).
fn relink(bom: &mut Bom) {
    let kept = assembly_origins(bom);
    for l in bom.lines.iter_mut().filter(|l| l.origin != DESIGN && !kept.contains(&l.origin)) {
        l.placed = None;
        l.components.clear();
        l.definitions.clear();
    }
    for d in bom.design_links.clone() {
        link(bom, &d.reference, d.count, &d.components, &d.definitions);
    }
}

/// Counts a design row toward the component file line `cref` names (`hand:M1`, or `M1` when
/// only one file has that ref).
fn link(bom: &mut Bom, cref: &str, count: u64, comps: &[u64], defs: &[String]) -> bool {
    let target = if cref.contains(':') {
        let (o, r) = cref.split_once(':').unwrap_or_default();
        bom.lines.iter().position(|l| l.origin.eq_ignore_ascii_case(o.trim()) && l.reference.eq_ignore_ascii_case(r.trim()))
    } else {
        let hits: Vec<usize> = bom.lines.iter().enumerate().filter(|(_, l)| l.origin != DESIGN && l.origin != "pcb" && l.reference.eq_ignore_ascii_case(cref)).map(|(i, _)| i).collect();
        (hits.len() == 1).then(|| hits[0])
    };
    let Some(i) = target else { return false };
    let l = &mut bom.lines[i];
    l.placed = Some(l.placed.unwrap_or(0) + count);
    l.components.extend_from_slice(comps);
    l.definitions.extend(defs.iter().cloned());
    true
}

/// The origins whose placements come from a generated assembly (kept across design syncs).
fn assembly_origins(bom: &Bom) -> BTreeSet<String> {
    bom.imports.iter().filter(|i| i.kind == "assembly").map(|i| i.origin.clone()).collect()
}

// MARK: Generated assemblies (docs/generative/<assembly>/assembly.json)

/// The ref a placed part counts toward: `component_ref`, else `ref`.
fn part_ref(p: &Value) -> Option<String> {
    ["component_ref", "ref"].iter().find_map(|k| p.get(*k).and_then(Value::as_str)).map(str::trim).filter(|s| !s.is_empty()).map(String::from)
}

fn text(p: &Value, k: &str) -> Option<String> {
    p.get(k).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty() && *s != "null").map(String::from)
}

fn pnum(p: &Value, k: &str) -> Option<f64> {
    match p.get(k)? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
    .filter(|n: &f64| n.is_finite() && *n >= 0.0)
}

/// The STL and 3MF files of a part: the one it names, and a sibling of the other kind with the
/// same stem when it is on disk. Resolved against the assembly's folder `dir` when given.
fn meshes(file: &str, dir: Option<&std::path::Path>) -> Vec<String> {
    let rel = std::path::Path::new(file);
    let Some(stem) = rel.file_stem().and_then(|s| s.to_str()) else { return vec![] };
    let parent = rel.parent().unwrap_or(std::path::Path::new(""));
    let mut out = vec![];
    for ext in ["stl", "3mf"] {
        let cand = parent.join(format!("{stem}.{ext}"));
        let full = dir.map_or_else(|| cand.clone(), |d| d.join(&cand));
        if cand == rel || (dir.is_some() && full.exists()) {
            out.push(full.to_string_lossy().into_owned());
        }
    }
    out
}

/// Reads a generated assembly (`assembly.json`, schema `viaform.assembly/1`) with its component
/// file into the lines of that assembly, replacing them (user edits kept):
///
/// - each `generative` part, and each group of `made` parts sharing one mesh, is a made line
///   with its mass, material, process and mesh files (STL, 3MF);
/// - each `component` part counts toward the component file line its `component_ref` (or `ref`)
///   names, and `bulk` entries (listed, not placed: screws, cables) add their quantity; the
///   rolled-up count is the line's `placed`, checked against the file's quantity;
/// - a ref the assembly places that the file lacks becomes a line flagged `not_in_file`, built
///   only from what the assembly says of it; a file line nothing places is flagged `not_placed`;
/// - a bulk entry the assembly marks "made here" (the drone's FR1: the generated frame itself)
///   is left out of the rollup, its made parts count instead.
///
/// `dir` is the assembly's folder, to resolve the mesh files.
pub fn import_assembly(bom: &mut Bom, asm: &Value, components: Option<&Value>, dir: Option<&std::path::Path>, path: Option<&str>, today: &str) -> Result<Value, String> {
    let name = asm.get("assembly").and_then(Value::as_str).map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).ok_or("assembly.json: no assembly name")?;
    let parts = asm.get("parts").and_then(Value::as_array).ok_or("assembly.json: no parts list")?;
    let (mut lines, mut warnings, file_import) = match components {
        Some(c) => {
            let (a, imp, lines, warnings) = component_file(c)?;
            if a != name {
                return Err(format!("the component file is for {a}, the assembly is {name}"));
            }
            (lines, warnings, Some(imp))
        }
        None => (vec![], vec![format!("{name}: no component file, bought lines come from the assembly only")], None),
    };
    // Placements and bulk counts per ref, with the first part that names each (for an unlisted ref).
    let mut placed: BTreeMap<String, u64> = BTreeMap::new();
    let mut first: BTreeMap<String, &Value> = BTreeMap::new();
    let mut made_here: BTreeMap<String, String> = BTreeMap::new();
    let mut made: Vec<(String, Line)> = vec![];
    let mut made_count = 0usize;
    for p in parts {
        let kind = p.get("kind").and_then(Value::as_str).unwrap_or("");
        let qty = p.get("qty").and_then(Value::as_u64).unwrap_or(1);
        match kind {
            "component" => {
                let Some(r) = part_ref(p) else {
                    warnings.push(format!("a component part has no component_ref: {}", text(p, "name").unwrap_or_default()));
                    continue;
                };
                *placed.entry(r.clone()).or_default() += qty;
                first.entry(r).or_insert(p);
            }
            "generative" | "made" => {
                made_count += qty as usize;
                let part = text(p, "name").unwrap_or_default();
                let file = text(p, "file").unwrap_or_default();
                let props = p.get("properties").cloned().unwrap_or(json!({}));
                let material = text(p, "material").or_else(|| text(&props, "material")).unwrap_or_default();
                let process = text(&props, "process").unwrap_or_default();
                // A generated part is its own line; made parts that share a mesh are one line.
                let key = if kind == "generative" || file.is_empty() {
                    part.clone()
                } else {
                    std::path::Path::new(&file).file_stem().and_then(|s| s.to_str()).unwrap_or(&part).to_string()
                };
                let mass = pnum(p, "mass_g").or_else(|| pnum(&props, "mass_g"));
                if let Some((_, l)) = made.iter_mut().find(|(k, l)| *k == key && l.made.as_ref().is_some_and(|m| m.material == material && m.process == process)) {
                    l.qty += qty as u32;
                    l.used_by.push(part);
                    continue;
                }
                made.push((
                    key.clone(),
                    Line {
                        id: format!("{name}:made:{key}"),
                        origin: name.clone(),
                        reference: key.clone(),
                        qty: qty as u32,
                        category: if kind == "generative" { "generative".into() } else { "made".into() },
                        description: if kind == "generative" { format!("{key} (generated)") } else { key.replace('_', " ") },
                        mass_g: mass,
                        made: Some(Made { material, process, unit_cost_usd: pnum(&props, "cost_usd").or_else(|| pnum(&props, "unit_cost_usd")) }),
                        subassembly: if kind == "generative" { "Generated parts".into() } else { "Made parts".into() },
                        meshes: if file.is_empty() { vec![] } else { meshes(&file, dir) },
                        used_by: vec![part],
                        ..Line::default()
                    },
                ));
            }
            _ => warnings.push(format!("part {} has an unknown kind `{kind}`", text(p, "name").unwrap_or_default())),
        }
    }
    for b in asm.get("bulk").and_then(Value::as_array).into_iter().flatten() {
        let Some(r) = part_ref(b) else { continue };
        *placed.entry(r.clone()).or_default() += b.get("qty").and_then(Value::as_u64).unwrap_or(0);
        first.entry(r.clone()).or_insert(b);
        if let Some(u) = text(b, "use").filter(|u| u.to_lowercase().starts_with("made here")) {
            made_here.insert(r, u);
        }
    }
    let mut not_placed = vec![];
    for l in lines.iter_mut() {
        let n = placed.get(&l.reference).copied().unwrap_or(0);
        l.placed = Some(n);
        if n == 0 {
            not_placed.push(l.reference.clone());
        }
        if let Some(u) = made_here.get(&l.reference) {
            l.excluded = true;
            l.notes = [l.notes.trim(), &format!("Left out: the assembly says {u}.")].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" ");
        }
    }
    let mut missing = vec![];
    for (r, n) in &placed {
        if lines.iter().any(|l| &l.reference == r) {
            continue;
        }
        missing.push(r.clone());
        let p = first[r];
        let props = p.get("properties").cloned().unwrap_or(json!({}));
        lines.push(Line {
            id: format!("{name}:{r}"),
            origin: name.clone(),
            reference: r.clone(),
            qty: *n as u32,
            category: text(&props, "category").unwrap_or_else(|| "other".into()),
            mpn: text(&props, "mpn").or_else(|| text(p, "part_number")).unwrap_or_default(),
            manufacturer: text(&props, "manufacturer").unwrap_or_default(),
            description: text(p, "description").or_else(|| text(p, "use")).or_else(|| text(p, "name")).unwrap_or_default(),
            mass_g: pnum(p, "mass_g").or_else(|| pnum(p, "mass_g_each")),
            subassembly: name.clone(),
            placed: Some(*n),
            unlisted: true,
            ..Line::default()
        });
    }
    let bought = lines.len();
    let made_lines = made.len();
    lines.extend(made.into_iter().map(|(_, l)| l));
    bom.replace_origin(&name, lines);
    let mut import = file_import.unwrap_or_else(|| Import { origin: name.clone(), ..Import::default() });
    import.kind = "assembly".into();
    import.path = path.map(String::from);
    import.lines = bought + made_lines;
    record(bom, import, today);
    Ok(json!({
        "assembly": name, "bought_lines": bought, "made_lines": made_lines, "made_parts": made_count,
        "placed": placed.values().sum::<u64>(), "missing_from_file": missing, "not_placed": not_placed, "warnings": warnings,
    }))
}

/// The component file an assembly names (`component_file`, from the repository root), found by
/// walking up from the assembly's folder; else `docs/components/<assembly>.json` the same way.
pub fn component_file_for(asm: &Value, asm_path: &std::path::Path) -> Option<std::path::PathBuf> {
    let name = asm.get("assembly").and_then(Value::as_str).unwrap_or("");
    let named = asm.get("component_file").and_then(Value::as_str).map(String::from);
    let fallback = format!("docs/components/{name}.json");
    let mut dir = asm_path.parent();
    while let Some(d) = dir {
        for rel in named.iter().chain(std::iter::once(&fallback)) {
            let c = d.join(rel);
            if c.is_file() {
                return Some(c.canonicalize().unwrap_or(c));
            }
        }
        dir = d.parent();
    }
    None
}

// MARK: The PCB

fn kind_category(kind: &str) -> &'static str {
    match kind {
        "connector" => "connector",
        "mcu" | "microcontroller" => "mcu",
        "sensor" => "sensor",
        "regulator" => "power",
        _ => "electronic",
    }
}

/// Reads the PCB's components (`pcb_inspect`) into lines, one per kind, value and footprint,
/// with every designator in the line's reference, plus one line for the bare board. Components
/// carry no manufacturer part number in PCBCraft: those lines are flagged until one is typed.
pub fn sync_pcb(bom: &mut Bom, inspect: &Value, today: &str) -> Result<Value, String> {
    let project = inspect.get("project").ok_or("the PCB project is empty")?;
    let comps = project.get("components").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut groups: BTreeMap<(String, String, String), Vec<String>> = BTreeMap::new();
    for c in &comps {
        let s = |k: &str| c.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
        let fp = c.pointer("/library_footprint/definition/name").and_then(Value::as_str).or_else(|| c.pointer("/library_footprint/library").and_then(Value::as_str)).unwrap_or("").to_string();
        groups.entry((s("kind"), s("value"), fp)).or_default().push(s("reference"));
    }
    let mut fresh = vec![];
    let name = project.get("name").and_then(Value::as_str).unwrap_or("Board").to_string();
    if !comps.is_empty() || project.get("board").is_some() {
        let w = project.pointer("/board/width").and_then(Value::as_f64);
        let h = project.pointer("/board/height").and_then(Value::as_f64);
        let size = match (w, h) {
            (Some(w), Some(h)) => format!(", {w} x {h} mm"),
            _ => String::new(),
        };
        fresh.push(Line {
            id: "pcb:board".into(),
            origin: "pcb".into(),
            reference: "PCB".into(),
            qty: 1,
            category: "pcb".into(),
            description: format!("{name} bare board{size}"),
            subassembly: "PCB".into(),
            notes: "Fabricated from the PCBCraft board; quote it with a board house".into(),
            ..Line::default()
        });
    }
    for ((kind, value, fp), mut refs) in groups {
        refs.sort_by(|a, b| natural(a).cmp(&natural(b)));
        let desc = [kind.as_str(), value.as_str()].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" ");
        let mut specs = Map::new();
        if !fp.is_empty() {
            specs.insert("footprint".into(), json!(fp));
        }
        fresh.push(Line {
            id: format!("pcb:{}", refs.first().cloned().unwrap_or_default()),
            origin: "pcb".into(),
            qty: refs.len() as u32,
            reference: refs.join(", "),
            category: kind_category(&kind).into(),
            description: desc,
            key_specs: specs,
            subassembly: "PCB".into(),
            ..Line::default()
        });
    }
    let n = fresh.len();
    bom.replace_origin("pcb", fresh);
    record(bom, Import { origin: "pcb".into(), kind: "pcb".into(), lines: n, ..Default::default() }, today);
    Ok(json!({"lines": n, "components": comps.len()}))
}

/// `R10` after `R9`.
fn natural(s: &str) -> (String, u64) {
    let i = s.find(|c: char| c.is_ascii_digit()).unwrap_or(s.len());
    (s[..i].to_string(), s[i..].parse().unwrap_or(0))
}

// MARK: Refresh through the library's sources

/// The display name of a library source in the BOM's supplier column.
pub fn supplier_name(source: &str) -> String {
    match source {
        "digikey" => "DigiKey",
        "mouser" => "Mouser",
        "nexar" => "Octopart",
        "amazon" => "Amazon",
        "aliexpress" => "AliExpress",
        "ebay" => "eBay",
        "mcmaster" => "McMaster-Carr",
        "lcsc" => "LCSC",
        other => other,
    }
    .to_string()
}

/// What to search for a refresh: each bought line with a part number, once per part number.
pub fn refresh_plan(bom: &Bom) -> Value {
    let mut seen = BTreeSet::new();
    let items: Vec<Value> = bom
        .lines
        .iter()
        .filter(|l| !l.is_made() && !l.excluded && !l.mpn.is_empty())
        .filter(|l| seen.insert(norm(&l.mpn)))
        .map(|l| json!({"line": l.id, "query": l.mpn}))
        .collect();
    json!(items)
}

/// Folds the library's search answers for `mpn` into every bought line with that part number:
/// each exact part number match becomes (or replaces) an offer with its price breaks and stock,
/// checked today. Answers how many offers came in and the sources' errors.
pub fn apply_hits(bom: &mut Bom, mpn: &str, hits: &[Hits], today: &str) -> Value {
    let want = norm(mpn);
    let mut offers = vec![];
    let mut errors = vec![];
    let mut skipped = 0;
    for h in hits {
        if let Some(e) = &h.error {
            errors.push(json!({"source": h.source, "error": e}));
        }
        for it in &h.items {
            let m = it.mpn.as_deref().unwrap_or(&it.name);
            if want.is_empty() || norm(m) != want {
                continue;
            }
            if it.prices.iter().any(|p| !p.currency.eq_ignore_ascii_case("USD")) {
                skipped += 1;
                continue;
            }
            let mut breaks: Vec<Break> = it.prices.iter().filter(|p| p.quantity >= 1.0 && p.price.is_finite()).map(|p| Break { qty: p.quantity as u32, unit_price: p.price }).collect();
            breaks.sort_by_key(|b| b.qty);
            breaks.dedup_by_key(|b| b.qty);
            let stock_note = it.stock.map(|s| if s <= 0.0 { "Out of stock".to_string() } else { format!("{} in stock", s as u64) });
            offers.push(Offer {
                supplier: supplier_name(&h.source),
                sku: it.part_number.clone(),
                url: it.url.clone(),
                unit_price_usd: breaks.first().map(|b| b.unit_price),
                moq: breaks.first().map_or(1, |b| b.qty.max(1)),
                pack: None,
                breaks,
                stock: it.stock,
                stock_note,
                checked_on: Some(today.to_string()),
                via: h.source.clone(),
            });
        }
    }
    let mut lines = 0;
    for l in bom.lines.iter_mut().filter(|l| !l.is_made() && norm(&l.mpn) == want && !want.is_empty()) {
        lines += 1;
        for o in &offers {
            if let Some(old) = l.offers.iter_mut().find(|x| same_offer(x, o) && (x.sku.is_empty() || x.via == o.via || norm(&x.sku) == norm(&o.sku))) {
                // A file offer keeps its link and notes when the API answers for the same SKU.
                let url = old.url.clone();
                *old = Offer { url: o.url.clone().or(url), ..o.clone() };
            } else {
                l.offers.push(o.clone());
            }
        }
        if !offers.is_empty() {
            l.checked_on = Some(today.to_string());
        }
    }
    bom.refreshed_on = Some(today.to_string());
    json!({"mpn": mpn, "offers": offers.len(), "lines": lines, "skipped_currency": skipped, "errors": errors})
}
