//! Standard hardware from the design engine's tables (`parts.library`): each family and size is
//! an item, inserted with `parts.insert`. Nothing is downloaded: the engine builds the solid.

use serde::Deserialize;
use serde_json::{Value, json};

use crate::types::{Domain, Item, Use};

#[derive(Clone, Debug, Deserialize)]
pub struct Family {
    pub family: String,
    pub name: String,
    pub standard: String,
    pub system: String,
    pub sizes: Vec<Size>,
    pub lengths: Option<Vec<f64>>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Size {
    pub size: String,
    pub default_length: Option<f64>,
}

/// The engine's standard part families, read from a scratch design so the project is untouched.
pub fn families() -> Vec<Family> {
    let mut s = solidcraft_engine::Session::default();
    s.execute("parts.library", &json!({}))
        .ok()
        .and_then(|v: Value| serde_json::from_value(v.get("families")?.clone()).ok())
        .unwrap_or_default()
}

/// Search words that name the kind of part, beyond the engine's family names (English, French).
fn aliases(family: &str) -> &'static str {
    match family {
        "socket_head_cap_screw" => "screw bolt shcs cap socket allen vis",
        "button_head_cap_screw" => "screw bhcs button vis",
        "hex_bolt" => "screw bolt hex vis",
        "hex_nut" => "nut ecrou hex",
        "washer" => "washer rondelle",
        "set_screw" => "screw grub set vis",
        "dowel_pin" => "pin dowel goupille",
        "bearing" => "bearing roulement ball",
        "hex_cap_screw_inch" => "screw bolt hex inch imperial",
        "hex_nut_inch" => "nut hex inch imperial",
        "washer_sae" => "washer inch sae",
        "washer_uss" => "washer inch uss",
        _ => "",
    }
}

fn number(s: &str) -> Option<f64> {
    (!s.is_empty() && s.chars().all(|c| c.is_ascii_digit() || c == '.')).then(|| s.parse().ok()).flatten()
}

/// `M3x12`, `M3 12`, `nut M5`, `608`: a size and a length. A bare number is a length, unless a
/// size equals it (bearing 608).
pub fn search(families: &[Family], query: &str, limit: usize) -> (Vec<Item>, usize) {
    let q = query.to_lowercase().replace(['×', '*'], "x");
    let mut length = None;
    let mut terms = vec![];
    for w in q.split_whitespace() {
        if let Some((size, len)) = w.split_once('x').filter(|(s, l)| s.starts_with('m') && number(&s[1..]).is_some() && number(l).is_some()) {
            terms.push(size.to_string());
            length = number(len);
        } else {
            terms.push(w.to_string());
        }
    }
    let (mut out, mut total) = (vec![], 0);
    for f in families {
        let text = format!("{} {} {} {}", f.family.replace('_', " "), f.name, f.standard, aliases(&f.family)).to_lowercase();
        for s in &f.sizes {
            let size = s.size.to_lowercase();
            let mut len = length;
            let ok = terms.iter().all(|t| {
                if size == *t {
                    return true;
                }
                if let (Some(x), Some(_)) = (number(t), &f.lengths) {
                    len = Some(x);
                    return true;
                }
                text.contains(t.as_str())
            });
            if !ok {
                continue;
            }
            if let (Some(l), Some(ls)) = (len, &f.lengths) {
                if !ls.contains(&l) {
                    continue;
                }
            }
            total += 1;
            if out.len() < limit {
                out.push(item(f, &s.size, f.lengths.as_ref().and(len.or(s.default_length))));
            }
        }
    }
    (out, total)
}

fn trim(x: f64) -> String {
    if x.fract() == 0.0 { format!("{x:.0}") } else { format!("{x}") }
}

pub fn item(f: &Family, size: &str, length: Option<f64>) -> Item {
    let inch = f.system == "inch";
    let label = match length {
        Some(l) if inch => format!("{size} x {}", trim(l)),
        Some(l) => format!("{size}x{}", trim(l)),
        None => size.to_string(),
    };
    let mut it = Item::new("standard", format!("{} {label}", f.standard), format!("{} {label}", f.name), Domain::Mechanical);
    it.key = format!("standard:{}:{size}{}", f.family, length.map(|l| format!(":{}", trim(l))).unwrap_or_default());
    it.description = Some(match length {
        Some(l) => format!("{}, length {} {}", f.standard, trim(l), if inch { "in" } else { "mm" }),
        None => f.standard.clone(),
    });
    it.category = Some(f.name.clone());
    it.uses.push(Use::Hardware { family: f.family.clone(), size: size.into(), length });
    it
}
