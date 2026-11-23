//! Revisions of an artifact: every build, promotion ("Use as Frame") or restore leaves one, so
//! the pipeline can say "Frame v12 replaced v11" and a stage can go back to an older build.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// One build of an artifact.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Revision {
    /// 1, 2, 3... per artifact, never reused.
    pub number: u64,
    /// The active revision of each input when this was built.
    #[serde(default)]
    pub seen: BTreeMap<String, u64>,
    #[serde(default)]
    pub summary: String,
    /// `build` (a stage built it), `promote` (picked from results, "Use as Frame") or `edit`
    /// (an editor reported its content).
    #[serde(default = "build")]
    pub source: String,
    /// Where a promoted revision came from ("Outcome 13").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// A digest of the content, so an undo back to an earlier state finds that revision
    /// instead of making a new one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fingerprint: Option<String>,
    /// Figures the front end wants kept with the build (mass, cost, candidates...).
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub data: Value,
    /// Seconds since the Unix epoch.
    #[serde(default)]
    pub at: f64,
}

fn build() -> String {
    "build".into()
}

/// What changed between two revisions: their inputs, their summary and their figures.
pub fn diff(label: impl Fn(&str, u64) -> String, artifact: &str, a: &Revision, b: &Revision) -> Value {
    let mut inputs: Vec<Value> = Vec::new();
    let keys: std::collections::BTreeSet<&String> = a.seen.keys().chain(b.seen.keys()).collect();
    for k in keys {
        let (x, y) = (a.seen.get(k).copied().unwrap_or(0), b.seen.get(k).copied().unwrap_or(0));
        inputs.push(json!({"id": k, "from": label(k, x), "to": label(k, y), "changed": x != y}));
    }
    let mut figures: Vec<Value> = Vec::new();
    let empty = serde_json::Map::new();
    let (fa, fb) = (a.data.as_object().unwrap_or(&empty), b.data.as_object().unwrap_or(&empty));
    let keys: std::collections::BTreeSet<&String> = fa.keys().chain(fb.keys()).collect();
    for k in keys {
        let (x, y) = (fa.get(k).cloned().unwrap_or(Value::Null), fb.get(k).cloned().unwrap_or(Value::Null));
        if x != y {
            figures.push(json!({"key": k, "from": x, "to": y}));
        }
    }
    json!({
        "artifact": artifact,
        "from": label(artifact, a.number),
        "to": label(artifact, b.number),
        "summary": {"from": a.summary, "to": b.summary, "changed": a.summary != b.summary},
        "inputs": inputs,
        "figures": figures,
        "same_content": a.fingerprint.is_some() && a.fingerprint == b.fingerprint,
    })
}
