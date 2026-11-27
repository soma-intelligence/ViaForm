//! The shapes that cross the bridge as JSON (snake_case fields, `Use` tagged by "kind").

use serde::{Deserialize, Serialize};

/// Electronics (symbols, footprints, distributors), mechanics (hardware, CAD models) or both.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Domain {
    Electronics,
    Mechanical,
    Both,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PriceBreak {
    pub quantity: f64,
    pub price: f64,
    pub currency: String,
}

/// What the app can do with an item, beyond keeping it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Use {
    /// Place a KiCad symbol in the schematic (`component.place_library`), with its footprint.
    KicadSymbol { path: String, symbol: String, #[serde(default, skip_serializing_if = "Option::is_none")] footprint: Option<String> },
    /// Give the selected part this footprint (`footprint.assign`).
    KicadFootprint { path: String },
    /// Insert a STEP model into the design (`file.insert_step`).
    Step { path: String },
    /// Insert a standard part built by the design engine (`parts.insert`).
    Hardware { family: String, size: String, #[serde(default, skip_serializing_if = "Option::is_none")] length: Option<f64> },
    /// Place one of the PCB engine's own parts (`component.add`).
    Schematic { part: String, value: String },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FileRef {
    pub label: String,
    pub path: String,
}

/// One part found in a source or saved in the user's library.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Item {
    /// Unique within the user's library: `<source>:<part number>`; empty for a new manual entry.
    #[serde(default)]
    pub key: String,
    pub source: String,
    /// The source's own part number (DigiKey number, ASIN, McMaster number, `Lib:Symbol`...).
    pub part_number: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mpn: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    pub domain: Domain,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub datasheet: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stock: Option<f64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub prices: Vec<PriceBreak>,
    /// CAD files the user attached (copied into the library folder), or found locally.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<FileRef>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub uses: Vec<Use>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    /// Seconds since 1970 when the item was saved; unset for a search result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_at: Option<u64>,
}

impl Item {
    pub fn new(source: &str, part_number: impl Into<String>, name: impl Into<String>, domain: Domain) -> Self {
        let part_number = part_number.into();
        Item {
            key: format!("{source}:{part_number}"),
            source: source.into(),
            part_number,
            name: name.into(),
            description: None,
            manufacturer: None,
            mpn: None,
            category: None,
            domain,
            url: None,
            datasheet: None,
            stock: None,
            prices: vec![],
            files: vec![],
            uses: vec![],
            notes: None,
            tags: vec![],
            saved_at: None,
        }
    }
}

/// What one source answered to a search.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Hits {
    pub source: String,
    pub items: Vec<Item>,
    pub total: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
