//! What a bill of materials costs and weighs for N builds: the offer each bought line is ordered
//! from (price breaks, MOQ), made against bought, the supplier carts, and every line that misses
//! data or a source.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::model::{Bom, Line, Offer, norm};

/// Data older than this many days is flagged stale.
pub const STALE_DAYS: i64 = 90;

/// How many to order from `offer` to get at least `need`, and at what unit price. Orders at least
/// the MOQ and the smallest break; buys up to a larger break when that costs less in all
/// (25 at 0.35 beats 10 at 1.00). None when the offer has no price.
pub fn price(offer: &Offer, need: u32) -> Option<Priced> {
    let mut floor = need.max(offer.moq).max(1);
    if let Some(p) = offer.pack.filter(|p| *p > 1) {
        floor = floor.div_ceil(p) * p;
    }
    if offer.breaks.is_empty() {
        let unit = offer.unit_price_usd?;
        return Some(Priced { order_qty: floor, unit_price: unit, extended: unit * floor as f64, break_qty: None, bumped: false });
    }
    let at = |qty: u32| -> Option<(f64, u32)> {
        offer.breaks.iter().rev().find(|b| b.qty <= qty).map(|b| (b.unit_price, b.qty)).or_else(|| offer.unit_price_usd.filter(|_| qty >= offer.moq).map(|p| (p, offer.moq)))
    };
    let first = offer.breaks[0].qty;
    let base = floor.max(if at(floor).is_none() { first } else { floor });
    let mut candidates = vec![base];
    candidates.extend(offer.breaks.iter().map(|b| b.qty).filter(|q| *q > base));
    let mut best: Option<Priced> = None;
    for q in candidates {
        let Some((unit, bq)) = at(q) else { continue };
        let ext = unit * q as f64;
        if best.as_ref().is_none_or(|b| ext < b.extended - 1e-9) {
            best = Some(Priced { order_qty: q, unit_price: unit, extended: ext, break_qty: Some(bq), bumped: q != base });
        }
    }
    best
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Priced {
    pub order_qty: u32,
    pub unit_price: f64,
    pub extended: f64,
    /// The break the unit price comes from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub break_qty: Option<u32>,
    /// Ordered past the need to reach a cheaper break.
    pub bumped: bool,
}

/// One line's figures for the build count.
#[derive(Clone, Debug, Default, Serialize)]
pub struct LineRoll {
    pub id: String,
    pub per_build: u32,
    pub need: u32,
    pub made: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supplier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sku: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub order_qty: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit_price: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extended: Option<f64>,
    /// What one build's share costs (the extended price over the build count).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub per_build_cost: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub break_qty: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mass_g: Option<f64>,
    pub flags: Vec<String>,
    /// Plain words for the flags.
    pub notes: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stock_note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lifecycle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checked_on: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub age_days: Option<i64>,
    pub excluded: bool,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct CartItem {
    pub line: String,
    pub reference: String,
    pub sku: String,
    pub mpn: String,
    pub manufacturer: String,
    pub description: String,
    pub qty: u32,
    pub unit_price: f64,
    pub extended: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Cart {
    pub supplier: String,
    pub items: Vec<CartItem>,
    pub total: f64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Totals {
    pub bought_cost: f64,
    pub made_cost: f64,
    pub total_cost: f64,
    pub cost_per_build: f64,
    /// One build's mass, from the lines that have one.
    pub mass_g: f64,
    pub mass_made_g: f64,
    pub mass_bought_g: f64,
    pub lines: usize,
    pub parts_per_build: u64,
    pub bought_lines: usize,
    pub made_lines: usize,
    pub flagged: usize,
    pub unsourced: usize,
    pub missing_price: usize,
    pub missing_mass: usize,
    pub stale: usize,
    pub excluded: usize,
    /// Whether every counted line had a price (else the cost is a floor).
    pub cost_complete: bool,
    pub mass_complete: bool,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Rollup {
    pub builds: u32,
    pub currency: String,
    pub today: String,
    pub lines: Vec<LineRoll>,
    pub totals: Totals,
    pub carts: Vec<Cart>,
}

/// Days since 1970-01-01 of an ISO date (`YYYY-MM-DD`, any time after it ignored).
pub fn days(date: &str) -> Option<i64> {
    let d = date.get(..10)?;
    let mut it = d.split('-');
    let (y, m, dd): (i64, i64, i64) = (it.next()?.parse().ok()?, it.next()?.parse().ok()?, it.next()?.parse().ok()?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&dd) {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + dd - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146097 + doe - 719468)
}

/// The ISO date of a day count since 1970-01-01.
pub fn date(z: i64) -> String {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}")
}

const LIFECYCLE: &[(&str, &str)] = &[
    ("obsolete", "Obsolete"),
    ("nrnd", "Not recommended for new designs"),
    ("not recommended", "Not recommended for new designs"),
    ("end of life", "End of life"),
    ("eol", "End of life"),
    ("discontinued", "Discontinued"),
    ("last time buy", "Last time buy"),
    ("ltb", "Last time buy"),
    ("closeout", "Closeout"),
];

/// A lifecycle warning found in the line's notes, stock notes or `lifecycle` spec.
fn lifecycle(l: &Line) -> Option<String> {
    let mut hay = vec![l.notes.to_lowercase()];
    hay.extend(l.offers.iter().filter_map(|o| o.stock_note.as_ref()).map(|s| s.to_lowercase()));
    if let Some(v) = l.key_specs.get("lifecycle").and_then(|v| v.as_str()) {
        hay.push(v.to_lowercase());
    }
    for h in &hay {
        let words: Vec<&str> = h.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
        for (k, label) in LIFECYCLE {
            let hit = if k.contains(' ') { h.contains(k) } else { words.contains(k) };
            if hit {
                return Some(label.to_string());
            }
        }
    }
    None
}

fn out_of_stock(o: &Offer) -> bool {
    o.stock.is_some_and(|s| s <= 0.0) || o.stock_note.as_deref().is_some_and(|n| {
        let n = n.to_lowercase();
        n.contains("out of stock") || n.contains("unavailable") || n.contains("sold out")
    })
}

/// The offer a bought line orders from: the user's pick (by supplier name), else the one that
/// costs least for `need`, else the first.
pub fn choose<'a>(l: &'a Line, need: u32) -> Option<(&'a Offer, Option<Priced>)> {
    if let Some(s) = &l.supplier
        && let Some(o) = l.offers.iter().find(|o| norm(&o.supplier) == norm(s))
    {
        return Some((o, price(o, need)));
    }
    let priced = l.offers.iter().filter_map(|o| price(o, need).map(|p| (o, p))).filter(|(o, _)| !out_of_stock(o)).min_by(|a, b| a.1.extended.total_cmp(&b.1.extended));
    if let Some((o, p)) = priced {
        return Some((o, Some(p)));
    }
    let any = l.offers.iter().filter_map(|o| price(o, need).map(|p| (o, p))).min_by(|a, b| a.1.extended.total_cmp(&b.1.extended));
    if let Some((o, p)) = any {
        return Some((o, Some(p)));
    }
    l.offers.first().map(|o| (o, None))
}

fn flag(r: &mut LineRoll, f: &str, note: String) {
    r.flags.push(f.into());
    r.notes.push(note);
}

/// Rolls the BOM up for its build count, as of `today` (for the stale flags).
pub fn rollup(bom: &Bom, today: &str) -> Rollup {
    let builds = bom.builds.max(1);
    let now = days(today);
    let mut t = Totals { cost_complete: true, mass_complete: true, ..Totals::default() };
    let mut carts: BTreeMap<String, Cart> = BTreeMap::new();
    let mut rows = vec![];
    for l in &bom.lines {
        let per_build = l.per_build();
        let need = per_build.saturating_mul(builds);
        let mut r = LineRoll { id: l.id.clone(), per_build, need, made: l.is_made(), excluded: l.excluded, checked_on: l.checked_on.clone(), ..LineRoll::default() };
        r.age_days = match (now, l.checked_on.as_deref().and_then(days)) {
            (Some(n), Some(c)) => Some(n - c),
            _ => None,
        };
        r.mass_g = l.mass_g.map(|m| m * per_build as f64);
        r.lifecycle = lifecycle(l);
        t.lines += 1;
        if l.excluded {
            t.excluded += 1;
            rows.push(r);
            continue;
        }
        t.parts_per_build += per_build as u64;
        if let Some(m) = r.mass_g {
            t.mass_g += m;
            if l.is_made() { t.mass_made_g += m } else { t.mass_bought_g += m }
        } else if per_build > 0 {
            t.missing_mass += 1;
            t.mass_complete = false;
            flag(&mut r, "no_mass", "No mass".into());
        }
        if let Some(made) = &l.made {
            t.made_lines += 1;
            if made.material.trim().is_empty() {
                flag(&mut r, "no_material", "Made part without a material".into());
            }
            match made.unit_cost_usd {
                Some(c) => {
                    let ext = c * need as f64;
                    r.unit_price = Some(c);
                    r.extended = Some(ext);
                    r.per_build_cost = Some(c * per_build as f64);
                    r.order_qty = need;
                    t.made_cost += ext;
                }
                None if per_build > 0 => {
                    t.missing_price += 1;
                    t.cost_complete = false;
                    flag(&mut r, "no_cost", "No cost estimate for the made part".into());
                }
                None => {}
            }
        } else {
            t.bought_lines += 1;
            if l.mpn.trim().is_empty() {
                flag(&mut r, "no_mpn", "No manufacturer part number".into());
            }
            match choose(l, need) {
                None => {
                    t.unsourced += 1;
                    t.cost_complete = false;
                    flag(&mut r, "unsourced", "No supplier offer".into());
                }
                Some((o, p)) => {
                    r.supplier = Some(o.supplier.clone());
                    r.sku = (!o.sku.is_empty()).then(|| o.sku.clone());
                    r.url = o.url.clone();
                    r.stock_note = o.stock_note.clone().or_else(|| o.stock.map(|s| format!("{} in stock", s as u64)));
                    if out_of_stock(o) {
                        flag(&mut r, "out_of_stock", format!("Out of stock at {}", o.supplier));
                    } else if let Some(s) = o.stock
                        && s < need as f64
                    {
                        flag(&mut r, "low_stock", format!("{} has {} of the {need} needed", o.supplier, s as u64));
                    }
                    match p {
                        None => {
                            t.missing_price += 1;
                            t.cost_complete = false;
                            flag(&mut r, "no_price", format!("{} offer has no price", o.supplier));
                        }
                        Some(p) => {
                            if p.order_qty > need && need > 0 {
                                let why = if p.bumped { "a cheaper price break" } else { "the minimum order" };
                                flag(&mut r, "moq_excess", format!("Orders {} for {need} ({why})", p.order_qty));
                            }
                            r.order_qty = p.order_qty;
                            r.unit_price = Some(p.unit_price);
                            r.extended = Some(p.extended);
                            r.per_build_cost = Some(p.extended / builds as f64);
                            r.break_qty = p.break_qty;
                            t.bought_cost += p.extended;
                            if need > 0 {
                                let cart = carts.entry(norm(&o.supplier)).or_insert_with(|| Cart { supplier: o.supplier.clone(), ..Cart::default() });
                                cart.total += p.extended;
                                cart.items.push(CartItem {
                                    line: l.id.clone(),
                                    reference: l.reference.clone(),
                                    sku: if o.sku.is_empty() { l.mpn.clone() } else { o.sku.clone() },
                                    mpn: l.mpn.clone(),
                                    manufacturer: l.manufacturer.clone(),
                                    description: l.description.clone(),
                                    qty: p.order_qty,
                                    unit_price: p.unit_price,
                                    extended: p.extended,
                                    url: o.url.clone(),
                                });
                            }
                        }
                    }
                }
            }
        }
        if let Some(lc) = r.lifecycle.clone() {
            flag(&mut r, "lifecycle", lc);
        }
        match r.age_days {
            Some(a) if a > STALE_DAYS => {
                t.stale += 1;
                flag(&mut r, "stale", format!("Checked {a} days ago"));
            }
            None if !l.is_made() => {
                t.stale += 1;
                flag(&mut r, "stale", "Never checked".into());
            }
            _ => {}
        }
        if l.unlisted {
            flag(&mut r, "not_in_file", format!("The assembly places {} but the component file has no {}", l.placed.unwrap_or(0), l.reference));
        } else if let Some(p) = l.placed {
            if p == 0 && per_build > 0 {
                flag(&mut r, "not_placed", "The assembly does not place it".into());
            } else if p != per_build as u64 {
                flag(&mut r, "placed_mismatch", format!("The design places {p}, the BOM counts {per_build}"));
            }
        }
        if !r.flags.is_empty() {
            t.flagged += 1;
        }
        rows.push(r);
    }
    t.total_cost = t.bought_cost + t.made_cost;
    t.cost_per_build = t.total_cost / builds as f64;
    let mut carts: Vec<Cart> = carts.into_values().collect();
    carts.sort_by(|a, b| b.total.total_cmp(&a.total));
    Rollup { builds, currency: bom.currency.clone(), today: today.to_string(), lines: rows, totals: t, carts }
}
