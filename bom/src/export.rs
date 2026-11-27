//! CSV out of the bill of materials: the whole table, one supplier's cart, and the bulk-add
//! formats DigiKey and Mouser read.

use crate::model::{Bom, norm};
use crate::rollup::{Cart, Rollup};

/// One CSV field, quoted when it holds a comma, a quote or a line break.
pub fn field(s: &str) -> String {
    if s.contains([',', '"', '\n', '\r']) { format!("\"{}\"", s.replace('"', "\"\"")) } else { s.to_string() }
}

fn row(fields: &[String]) -> String {
    let mut s = fields.iter().map(|f| field(f)).collect::<Vec<_>>().join(",");
    s.push_str("\r\n");
    s
}

fn money(v: Option<f64>) -> String {
    v.map(|v| format!("{v:.4}")).unwrap_or_default()
}

/// Every line with its figures for the build count.
pub fn table(bom: &Bom, r: &Rollup) -> String {
    let mut out = row(&[
        "Ref", "Origin", "Subassembly", "Category", "Made/Bought", "Qty per build", "Qty needed", "Order qty", "MPN", "Manufacturer", "Description", "Supplier",
        "SKU", "Unit price USD", "Extended USD", "Per build USD", "Mass per build g", "Material", "Process", "Alternates", "Stock", "Checked on", "Flags", "Notes", "URL",
    ]
    .map(String::from));
    for (l, x) in bom.lines.iter().zip(&r.lines) {
        let made = l.made.as_ref();
        let notes = [l.notes.as_str(), l.user_notes.as_str()].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" | ");
        out.push_str(&row(&[
            l.reference.clone(),
            l.origin.clone(),
            l.subassembly.clone(),
            l.category.clone(),
            if l.excluded { "Excluded".into() } else if made.is_some() { "Made".into() } else { "Bought".into() },
            x.per_build.to_string(),
            x.need.to_string(),
            x.order_qty.to_string(),
            l.mpn.clone(),
            l.manufacturer.clone(),
            l.description.clone(),
            x.supplier.clone().unwrap_or_default(),
            x.sku.clone().unwrap_or_default(),
            money(x.unit_price),
            money(x.extended),
            money(x.per_build_cost),
            x.mass_g.map(|m| format!("{m:.2}")).unwrap_or_default(),
            made.map(|m| m.material.clone()).unwrap_or_default(),
            made.map(|m| m.process.clone()).unwrap_or_default(),
            l.alternates.join(" "),
            x.stock_note.clone().unwrap_or_default(),
            x.checked_on.clone().unwrap_or_default(),
            x.notes.join("; "),
            notes,
            x.url.clone().unwrap_or_default(),
        ]));
    }
    out
}

fn cart<'a>(r: &'a Rollup, supplier: &str) -> Option<&'a Cart> {
    r.carts.iter().find(|c| norm(&c.supplier) == norm(supplier))
}

/// One supplier's cart: what to order there for the build count.
pub fn supplier(r: &Rollup, supplier: &str) -> Result<String, String> {
    let c = cart(r, supplier).ok_or_else(|| format!("nothing is ordered from {supplier}"))?;
    let mut out = row(&["Supplier", "SKU", "MPN", "Manufacturer", "Description", "Qty", "Unit price USD", "Extended USD", "Ref", "URL"].map(String::from));
    for i in &c.items {
        out.push_str(&row(&[
            c.supplier.clone(),
            i.sku.clone(),
            i.mpn.clone(),
            i.manufacturer.clone(),
            i.description.clone(),
            i.qty.to_string(),
            format!("{:.4}", i.unit_price),
            format!("{:.4}", i.extended),
            i.reference.clone(),
            i.url.clone().unwrap_or_default(),
        ]));
    }
    Ok(out)
}

/// DigiKey's cart and BOM Manager upload: quantity, DigiKey part number, manufacturer part
/// number, customer reference (the BOM ref, kept on the order line).
pub fn digikey(r: &Rollup) -> Result<String, String> {
    let c = cart(r, "DigiKey").ok_or("nothing is ordered from DigiKey")?;
    let mut out = row(&["Quantity", "Digi-Key Part Number", "Manufacturer Part Number", "Customer Reference"].map(String::from));
    for i in &c.items {
        out.push_str(&row(&[i.qty.to_string(), i.sku.clone(), i.mpn.clone(), reference(&i.reference)]));
    }
    Ok(out)
}

/// Mouser's BOM import (cart upload): Mouser part number, manufacturer part number, quantity,
/// customer part number (the BOM ref).
pub fn mouser(r: &Rollup) -> Result<String, String> {
    let c = cart(r, "Mouser").ok_or("nothing is ordered from Mouser")?;
    let mut out = row(&["Mouser Part Number", "Manufacturer Part Number", "Quantity", "Customer Part Number"].map(String::from));
    for i in &c.items {
        out.push_str(&row(&[i.sku.clone(), i.mpn.clone(), i.qty.to_string(), reference(&i.reference)]));
    }
    Ok(out)
}

/// Customer references are short on both sites: the first designators, at most 32 characters.
fn reference(r: &str) -> String {
    if r.chars().count() <= 32 { r.to_string() } else { format!("{}...", r.chars().take(29).collect::<String>()) }
}
