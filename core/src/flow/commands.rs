//! Every command of the eight stages in one list, and the search the command palette runs on it.
//!
//! The design and render commands come from SolidCraft's registry (`command_specs`), the board
//! commands from PCBCraft's (`commands`), and the stage verbs (run a study, use an outcome as
//! the frame, fly, train, render, export) are the pipeline's own: a front end routes each by its
//! `source` (`design`, `pcb` or `app`).

use std::sync::OnceLock;

use serde::Serialize;
use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Command {
    pub id: String,
    pub label: String,
    pub stage: String,
    /// The ribbon tab and panel, or the verb group of a stage ("STUDY", "FLIGHT").
    pub group: String,
    pub icon: String,
    /// The engine's shortcut ("E", "Ctrl+Z"), as written by the engine.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// `design` (sc_execute), `pcb` (pcb_execute) or `app` (the front end handles it).
    pub source: String,
    pub detail: String,
}

/// The stage a SolidCraft command belongs to, from its tab and panel.
fn design_stage(tab: &str, panel: &str) -> &'static str {
    if tab.starts_with("RENDER") {
        "render"
    } else if panel == "ASSEMBLE" || panel.starts_with("JOINT") || panel == "MOTION" {
        "assemble"
    } else {
        "design"
    }
}

/// "component.add" reads "Add component"; "board.rules.set" reads "Set board rules".
fn pcb_label(id: &str) -> String {
    match id {
        "component.place_library" => return "Place library part".into(),
        "component.value" => return "Set component value".into(),
        "object.delete" => return "Delete".into(),
        _ => {}
    }
    let parts: Vec<&str> = id.split('.').collect();
    let (verb, nouns) = parts.split_last().map_or(("", &[][..]), |(v, n)| (*v, n));
    let noun = nouns.join(" ").replace('_', " ");
    let s = format!("{verb} {noun}");
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

fn pcb_icon(id: &str) -> &'static str {
    match id.split('.').next().unwrap_or("") {
        "component" => "component",
        "footprint" => "footprint",
        "net" | "wire" => "wire",
        "track" => "track",
        "board" => "board",
        _ => "command",
    }
}

/// id, label, stage, group, icon, key.
type AppVerb = (&'static str, &'static str, &'static str, &'static str, &'static str, Option<&'static str>);

/// The pipeline's own verbs, routed by the front ends.
const APP: &[AppVerb] = &[
    ("generate.run", "Run Study", "generate", "STUDY", "generate", Some("G")),
    ("generate.use_as_frame", "Use as Frame", "generate", "OUTCOMES", "promote", None),
    ("generate.stress_here", "Stress Here", "generate", "LOADS", "load", None),
    ("generate.cancel", "Stop Study", "generate", "STUDY", "stop", None),
    ("simulate.fly", "Fly", "simulate", "FLIGHT", "fly", None),
    ("simulate.rerun", "Re-run on Current Frame", "simulate", "FLIGHT", "rerun", None),
    ("simulate.race", "Race", "simulate", "FLIGHT", "race", None),
    ("simulate.stress", "Stress Bench", "simulate", "BENCH", "stress", None),
    ("simulate.wind", "Wind", "simulate", "WORLD", "wind", None),
    ("simulate.record", "Record Video", "simulate", "FLIGHT", "record", None),
    ("train.start", "Start Training", "train", "TRAINING", "train", None),
    ("train.stop", "Stop Training", "train", "TRAINING", "stop", None),
    ("train.fly_policy", "Fly the Trained Policy", "train", "TRAINING", "fly", None),
    ("render.shots", "Render Shots", "render", "RENDER", "render", None),
    ("make.export", "Export Design", "make", "EXPORT", "export", None),
    ("make.bom", "Bill of Materials", "make", "EXPORT", "bom", None),
    ("make.kicad", "Export KiCad Board", "make", "EXPORT", "board", None),
    ("robot.connect", "Connect Robot", "robot", "CONNECT", "link", None),
    ("robot.estop", "Emergency Stop", "robot", "SAFETY", "stop", None),
    ("electronics.drc", "Design Rule Check", "electronics", "CHECK", "check", None),
    ("electronics.send_to_3d", "Send Board to 3D", "electronics", "LINK", "link", None),
    ("library.open", "Libraries", "design", "INSERT", "library", None),
    ("flow.update", "Update Stale Stages", "design", "PIPELINE", "update", None),
    ("flow.show", "Show Flow", "design", "PIPELINE", "flow", None),
];

/// The whole catalog, built once.
pub fn all() -> &'static [Command] {
    static ALL: OnceLock<Vec<Command>> = OnceLock::new();
    ALL.get_or_init(build)
}

fn build() -> Vec<Command> {
    let mut out = Vec::new();
    for (i, (id, name)) in super::graph::Graph::stages8().iter().map(|s| (s.id.clone(), s.name.clone())).enumerate() {
        out.push(Command {
            id: format!("stage.{id}"),
            label: format!("Go to {name}"),
            stage: id,
            group: "WORKSPACE".into(),
            icon: "stage".into(),
            key: Some(format!("Cmd+{}", i + 1)),
            source: "app".into(),
            detail: format!("Open the {name} workspace"),
        });
    }
    for c in solidcraft_engine::command_specs().iter().filter(|c| c.planned.is_none()) {
        out.push(Command {
            id: c.id.into(),
            label: c.label.into(),
            stage: design_stage(c.tab, c.panel).into(),
            group: if c.tab.is_empty() { "MORE".into() } else { format!("{} {}", c.tab, c.panel).trim().to_owned() },
            icon: c.icon.into(),
            key: c.shortcut.map(str::to_owned),
            source: "design".into(),
            detail: c.params.into(),
        });
    }
    for c in pcbcraft_engine::commands() {
        out.push(Command {
            id: format!("pcb.{}", c.id),
            label: pcb_label(c.id),
            stage: "electronics".into(),
            group: c.id.split('.').next().unwrap_or("").to_uppercase(),
            icon: pcb_icon(c.id).into(),
            key: None,
            source: "pcb".into(),
            detail: c.description.into(),
        });
    }
    for (id, label, stage, group, icon, key) in APP {
        out.push(Command {
            id: (*id).into(),
            label: (*label).into(),
            stage: (*stage).into(),
            group: (*group).into(),
            icon: (*icon).into(),
            key: key.map(str::to_owned),
            source: "app".into(),
            detail: String::new(),
        });
    }
    out
}

fn words(s: &str) -> impl Iterator<Item = &str> {
    s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty())
}

/// Whether the letters of `q` appear in order in `s`.
fn subsequence(q: &str, s: &str) -> bool {
    let mut it = s.chars();
    q.chars().all(|c| it.any(|x| x == c))
}

/// How well `c` answers `q` (lowercase); 0 = not at all.
fn score(c: &Command, q: &str) -> u32 {
    let label = c.label.to_lowercase();
    // A one letter query that is the command's single-key shortcut wins outright (E, F, M, J).
    if q.chars().count() == 1 && c.key.as_deref().is_some_and(|k| k.eq_ignore_ascii_case(q)) {
        return 1000;
    }
    let mut total = 0;
    for t in q.split_whitespace() {
        let s = if label == t {
            300
        } else if label.starts_with(t) {
            200
        } else if words(&label).any(|w| w.starts_with(t)) {
            120
        } else if label.contains(t) {
            80
        } else if c.id.to_lowercase().contains(t) {
            50
        } else if c.group.to_lowercase().contains(t) || c.stage.contains(t) {
            30
        } else if c.detail.to_lowercase().contains(t) {
            15
        } else if t.len() > 2 && t.chars().next().is_some_and(|c0| words(&label).any(|w| w.starts_with(c0))) && subsequence(t, &label) {
            // Fuzzy: the letters in order, and the query starts a word of the label.
            10
        } else {
            return 0;
        };
        total += s;
    }
    total
}

/// The best matches for `query`, the current `stage`'s commands first on a tie, at most
/// `limit`. An empty query lists the stage's commands that have a shortcut, then the others.
pub fn search(query: &str, stage: Option<&str>, limit: usize) -> Vec<Value> {
    let q = query.trim().to_lowercase();
    let mut hits: Vec<(u32, &Command)> = all()
        .iter()
        .filter_map(|c| {
            let here = stage.is_some_and(|s| s == c.stage);
            let base = if q.is_empty() {
                if !here {
                    return None;
                }
                if c.key.is_some() { 2 } else { 1 }
            } else {
                score(c, &q)
            };
            // The stage bonus only breaks ties between real label matches: a hit found in a
            // group, a description or a scattered subsequence never climbs above one.
            let bonus = if here && (q.is_empty() || base >= 80) { 25 } else { 0 };
            (base > 0).then_some((base + bonus, c))
        })
        .collect();
    // With label matches in hand, weak hits (group, description) are noise: drop them.
    if hits.iter().any(|(s, _)| *s >= 80) {
        hits.retain(|(s, _)| *s >= 50);
    }
    hits.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.label.len().cmp(&b.1.label.len())));
    hits.into_iter().take(limit).map(|(s, c)| json!({"score": s, "command": c})).collect()
}

/// The catalog as JSON, optionally for one stage.
pub fn list(stage: Option<&str>) -> Value {
    Value::Array(all().iter().filter(|c| stage.is_none_or(|s| s == c.stage)).map(|c| json!(c)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_stage_has_commands() {
        for s in super::super::graph::Graph::stages8() {
            assert!(all().iter().filter(|c| c.stage == s.id).count() >= 2, "{}", s.id);
        }
        assert!(all().iter().any(|c| c.source == "design" && c.stage == "design"));
        assert!(all().iter().any(|c| c.source == "pcb"));
        let mut ids: Vec<&str> = all().iter().map(|c| c.id.as_str()).collect();
        let n = ids.len();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), n, "command ids are unique");
    }

    #[test]
    fn pcb_ids_read_as_labels() {
        assert_eq!(pcb_label("component.add"), "Add component");
        assert_eq!(pcb_label("board.rules.set"), "Set board rules");
        assert_eq!(pcb_label("component.place_library"), "Place library part");
    }

    #[test]
    fn search_finds_by_label_shortcut_and_stage() {
        let top = |q: &str, s: Option<&str>| search(q, s, 5).first().map(|v| v["command"]["id"].as_str().unwrap().to_owned());
        assert_eq!(top("use as", None).as_deref(), Some("generate.use_as_frame"));
        assert_eq!(top("route", Some("electronics")).as_deref(), Some("pcb.track.route"));
        // A single key that is a shortcut finds its command first.
        let e = search("e", Some("design"), 1);
        assert_eq!(e[0]["command"]["key"], "E");
        assert!(search("zzzzqqq", None, 5).is_empty());
        // An empty query lists the stage's own commands.
        assert!(search("", Some("train"), 50).iter().all(|v| v["command"]["stage"] == "train"));
    }
}
