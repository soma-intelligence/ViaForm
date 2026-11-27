//! The shapes of a bill of materials, as they are saved (`bom.json` in the `.viaform` project)
//! and as they cross the bridge (snake_case JSON).

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub const FORMAT: &str = "viaform-bom";
pub const VERSION: u32 = 1;

fn one() -> u32 {
    1
}
fn is_false(b: &bool) -> bool {
    !*b
}

/// One price at or above a quantity.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Break {
    pub qty: u32,
    pub unit_price: f64,
}

/// Where a bought part can be ordered, and for how much.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Offer {
    pub supplier: String,
    #[serde(default)]
    pub sku: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The price of one at the offer's smallest quantity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit_price_usd: Option<f64>,
    /// Price breaks, when the supplier publishes them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub breaks: Vec<Break>,
    #[serde(default = "one")]
    pub moq: u32,
    /// Sold in packs of this many (the file gave a pack price): orders round up to whole packs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pack: Option<u32>,
    /// Units the supplier reported in stock, when a refresh read it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stock: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stock_note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_on: Option<String>,
    /// `file` (from a component file or typed by hand) or the library source that refreshed it
    /// (`digikey`, `mouser`, `nexar`...).
    #[serde(default)]
    pub via: String,
}

/// A part made for the project (printed, machined, generated) rather than bought.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Made {
    #[serde(default)]
    pub material: String,
    #[serde(default)]
    pub process: String,
    /// An estimate of what one costs to make, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit_cost_usd: Option<f64>,
}

/// One row of the bill of materials.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Line {
    /// Stable across re-imports: `<origin>:<ref>` (`hand:M1`, `pcb:R1`, `design:<part>`...).
    pub id: String,
    /// `design`, `pcb`, `manual` or the assembly of a component file (`hand`, `drone`).
    pub origin: String,
    /// The component file's ref, the PCB designators, or the design's component names.
    #[serde(default)]
    pub reference: String,
    /// How many one build takes, as the source says.
    pub qty: u32,
    /// The user's own count, when it differs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub qty_override: Option<u32>,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub mpn: String,
    #[serde(default)]
    pub manufacturer: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub key_specs: Map<String, Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dims_mm: Option<[f64; 3]>,
    /// The mass of one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mass_g: Option<f64>,
    /// Set for a made part; a bought part has none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub made: Option<Made>,
    /// The subassembly it belongs to (first `used_by` entry, the design's subassembly, `PCB`).
    #[serde(default)]
    pub subassembly: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub datasheet_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cad_source: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub offers: Vec<Offer>,
    /// The supplier the user picked; else the cheapest offer for the build count wins.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supplier: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub alternates: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub used_by: Vec<String>,
    /// The source's notes (component file, design property).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub notes: String,
    /// The user's own notes, kept across re-imports.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub user_notes: String,
    /// When the line's data was last checked (the file's date, or a refresh).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_on: Option<String>,
    /// The design's component ids this line counts (to select them in the viewport).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub components: Vec<u64>,
    /// The design's component names this line counts.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub definitions: Vec<String>,
    /// For a component file's line: how many the design places with `component_ref` set to it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placed: Option<u64>,
    /// The part's mesh files (STL, 3MF) for a made line read from a generated assembly.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub meshes: Vec<String>,
    /// The assembly places this ref but the component file has no line for it.
    #[serde(default, skip_serializing_if = "is_false")]
    pub unlisted: bool,
    /// Fields the user changed by hand, kept when the source is imported again.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub edited: BTreeSet<String>,
    /// Left out of the rollup (kept in the table, greyed).
    #[serde(default, skip_serializing_if = "is_false")]
    pub excluded: bool,
}

impl Line {
    /// The count one build takes.
    pub fn per_build(&self) -> u32 {
        self.qty_override.unwrap_or(self.qty)
    }

    pub fn is_made(&self) -> bool {
        self.made.is_some()
    }
}

/// One source brought into the BOM, as the header lists it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Import {
    pub origin: String,
    /// `component_file`, `design` or `pcb`.
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_on: Option<String>,
    pub lines: usize,
    pub imported_on: String,
}

/// A project's bill of materials.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Bom {
    pub format: String,
    pub version: u32,
    #[serde(default)]
    pub name: String,
    /// How many builds the rollup prices.
    #[serde(default = "one")]
    pub builds: u32,
    #[serde(default = "usd")]
    pub currency: String,
    #[serde(default)]
    pub lines: Vec<Line>,
    #[serde(default)]
    pub imports: Vec<Import>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refreshed_on: Option<String>,
    /// The design's rows that point at a component file line (`component_ref`), from the last
    /// design sync: kept so a component file imported later links to them too.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub design_links: Vec<DesignLink>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct DesignLink {
    #[serde(rename = "ref")]
    pub reference: String,
    pub count: u64,
    #[serde(default)]
    pub components: Vec<u64>,
    #[serde(default)]
    pub definitions: Vec<String>,
}

fn usd() -> String {
    "USD".into()
}

impl Default for Bom {
    fn default() -> Self {
        Bom { format: FORMAT.into(), version: VERSION, name: String::new(), builds: 1, currency: usd(), lines: vec![], imports: vec![], refreshed_on: None, design_links: vec![] }
    }
}

impl Bom {
    pub fn line(&self, id: &str) -> Option<&Line> {
        self.lines.iter().find(|l| l.id == id)
    }

    pub fn line_mut(&mut self, id: &str) -> Option<&mut Line> {
        self.lines.iter_mut().find(|l| l.id == id)
    }

    /// Reads a saved BOM; a newer format is refused rather than half read.
    pub fn from_json(v: Value) -> Result<Bom, String> {
        let version = v.get("version").and_then(Value::as_u64).unwrap_or(0);
        if v.get("format").and_then(Value::as_str) != Some(FORMAT) {
            return Err("not a ViaForm bill of materials".into());
        }
        if version > VERSION as u64 {
            return Err(format!("this bill of materials was saved by a newer ViaForm (format {version})"));
        }
        serde_json::from_value(v).map_err(|e| format!("bill of materials: {e}"))
    }

    /// Replaces every line of `origin` with `fresh`, keeping what the user changed on lines that
    /// come back (count, notes, supplier, edited fields, refreshed offers).
    pub fn replace_origin(&mut self, origin: &str, fresh: Vec<Line>) {
        let old: Vec<Line> = self.lines.iter().filter(|l| l.origin == origin).cloned().collect();
        let mut merged = Vec::with_capacity(fresh.len());
        for mut l in fresh {
            if let Some(o) = old.iter().find(|o| o.id == l.id) {
                carry(o, &mut l);
            }
            merged.push(l);
        }
        // Keep the place of the origin in the table: where its first line was, else at the end.
        let at = self.lines.iter().position(|l| l.origin == origin).unwrap_or(self.lines.len());
        self.lines.retain(|l| l.origin != origin);
        let at = at.min(self.lines.len());
        self.lines.splice(at..at, merged);
    }
}

/// What the user set on `old` survives the re-import into `new`.
fn carry(old: &Line, new: &mut Line) {
    new.qty_override = old.qty_override;
    new.user_notes = old.user_notes.clone();
    new.supplier = old.supplier.clone();
    new.excluded = old.excluded;
    new.edited = old.edited.clone();
    for f in &old.edited {
        match f.as_str() {
            "mpn" => new.mpn = old.mpn.clone(),
            "manufacturer" => new.manufacturer = old.manufacturer.clone(),
            "description" => new.description = old.description.clone(),
            "category" => new.category = old.category.clone(),
            "mass_g" => new.mass_g = old.mass_g,
            "subassembly" => new.subassembly = old.subassembly.clone(),
            "made" => new.made = old.made.clone(),
            "offers" => new.offers = old.offers.clone(),
            _ => {}
        }
    }
    // Offers a refresh brought keep coming back: in place of the source's same offer when the
    // refresh is as recent or more, else beside it.
    for o in old.offers.iter().filter(|o| o.via != "file") {
        match new.offers.iter_mut().find(|n| same_offer(n, o)) {
            Some(n) if !later(n.checked_on.as_deref(), o.checked_on.as_deref()) => {
                let url = n.url.clone();
                *n = Offer { url: o.url.clone().or(url), ..o.clone() };
            }
            Some(_) => {}
            None => new.offers.push(o.clone()),
        }
    }
    if new.checked_on.is_none() || later(old.checked_on.as_deref(), new.checked_on.as_deref()) {
        if old.offers.iter().any(|o| o.via != "file") {
            new.checked_on = old.checked_on.clone();
        }
    }
}

pub fn same_offer(a: &Offer, b: &Offer) -> bool {
    norm(&a.supplier) == norm(&b.supplier) && (a.sku.is_empty() || b.sku.is_empty() || norm(&a.sku) == norm(&b.sku))
}

/// Whether `a` is a later date than `b` (ISO dates compare as text).
fn later(a: Option<&str>, b: Option<&str>) -> bool {
    matches!((a, b), (Some(a), Some(b)) if a > b)
}

/// Lowercase, without spaces, dashes or dots: how part numbers and supplier names are matched.
pub fn norm(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}
