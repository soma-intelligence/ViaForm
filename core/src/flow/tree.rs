//! The project tree of each stage and the selection that crosses stages.
//!
//! Each workspace reports what it holds (bodies, sketches, components, nets, runs...) as tree
//! items; the pipeline puts them under the stage's artifacts and keeps the eye and the lock of
//! every row, so they survive a relaunch. Items can carry link keys ("part:Frame",
//! "ref:U1"): selecting one in a stage lights the items with the same key in the others, which
//! is the linked selection.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct TreeItem {
    pub id: String,
    pub name: String,
    /// What it is ("body", "sketch", "component", "net", "run"): the icon follows it.
    #[serde(default)]
    pub kind: String,
    /// A parent item id, else the artifact it belongs to, else the stage's first artifact.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<String>,
    /// Keys shared with items of other stages that are the same thing.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<String>,
    /// A short figure after the name ("153 g", "rev C").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Flags {
    #[serde(default = "yes")]
    pub visible: bool,
    #[serde(default)]
    pub locked: bool,
}

fn yes() -> bool {
    true
}

impl Default for Flags {
    fn default() -> Self {
        Self { visible: true, locked: false }
    }
}

/// What is selected, in which stage, and the 3D point a context pill or a leader line anchors
/// to.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Selection {
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    pub ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor: Option<[f64; 3]>,
}

/// Every stage's reported items and the flags of every row.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Trees {
    pub items: BTreeMap<String, Vec<TreeItem>>,
    pub flags: BTreeMap<String, Flags>,
    pub selection: Selection,
}

impl Trees {
    pub fn report(&mut self, stage: &str, items: Vec<TreeItem>) {
        self.items.insert(stage.to_owned(), items);
    }

    pub fn flags(&self, id: &str) -> Flags {
        self.flags.get(id).copied().unwrap_or_default()
    }

    pub fn set_flags(&mut self, id: &str, visible: Option<bool>, locked: Option<bool>) -> Flags {
        let f = self.flags.entry(id.to_owned()).or_default();
        if let Some(v) = visible {
            f.visible = v;
        }
        if let Some(l) = locked {
            f.locked = l;
        }
        let f = *f;
        if f == Flags::default() {
            self.flags.remove(id);
        }
        f
    }

    /// Every item of every stage with its stage.
    fn all(&self) -> impl Iterator<Item = (&str, &TreeItem)> {
        self.items.iter().flat_map(|(s, v)| v.iter().map(move |i| (s.as_str(), i)))
    }

    fn find(&self, id: &str) -> Option<(&str, &TreeItem)> {
        self.all().find(|(_, i)| i.id == id)
    }

    /// The keys an item answers to: its own id and its link keys.
    fn keys(item: &TreeItem) -> impl Iterator<Item = &str> {
        std::iter::once(item.id.as_str()).chain(item.links.iter().map(String::as_str))
    }

    /// Where the selection shows in each other stage: `[{stage, count, ids, names}]`, only
    /// for stages where something matches.
    pub fn linked(&self, stage_order: &[String]) -> Vec<Value> {
        let sel = &self.selection;
        let mut keys: BTreeSet<&str> = BTreeSet::new();
        for id in &sel.ids {
            keys.insert(id.as_str());
            if let Some((_, item)) = self.find(id) {
                keys.extend(Self::keys(item));
            }
        }
        if keys.is_empty() {
            return Vec::new();
        }
        stage_order
            .iter()
            .filter(|s| **s != sel.stage)
            .filter_map(|s| {
                let hits: Vec<&TreeItem> = self.items.get(s)?.iter().filter(|i| Self::keys(i).any(|k| keys.contains(k))).collect();
                (!hits.is_empty()).then(|| {
                    json!({
                        "stage": s,
                        "count": hits.len(),
                        "ids": hits.iter().map(|i| &i.id).collect::<Vec<_>>(),
                        "names": hits.iter().take(3).map(|i| &i.name).collect::<Vec<_>>(),
                    })
                })
            })
            .collect()
    }

    pub fn selection_json(&self, stage_order: &[String]) -> Value {
        let s = &self.selection;
        let names: Vec<&str> = s.ids.iter().map(|id| self.find(id).map_or(id.as_str(), |(_, i)| i.name.as_str())).collect();
        json!({
            "stage": s.stage,
            "ids": s.ids,
            "names": names,
            "anchor": s.anchor,
            "linked": self.linked(stage_order),
        })
    }
}
