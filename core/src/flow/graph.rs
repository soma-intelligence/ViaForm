//! The shape of a project's pipeline: its stages and the artifacts each one builds from the
//! others. Every project carries its own graph (saved in `flow.json`), so a product can grow a
//! stage or an artifact without a new ViaForm; a project saved before graphs existed opens on
//! the drone chain.

use serde::{Deserialize, Serialize};

/// How revisions of an artifact are named: `Frame v12` or `Board rev C`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Scheme {
    #[default]
    Version,
    Letter,
}

impl Scheme {
    /// The readable name of revision `n` of an artifact labelled `label`.
    pub fn name(self, label: &str, n: u64) -> String {
        if n == 0 {
            return format!("{label}, not built");
        }
        match self {
            Scheme::Version => format!("{label} v{n}"),
            Scheme::Letter => format!("{label} rev {}", letters(n)),
        }
    }
}

/// 1 = A, 26 = Z, 27 = AA, like spreadsheet columns.
pub fn letters(mut n: u64) -> String {
    let mut out = Vec::new();
    while n > 0 {
        n -= 1;
        out.push(b'A' + (n % 26) as u8);
        n /= 26;
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StageDef {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactDef {
    pub id: String,
    pub stage: String,
    /// What the artifact is, in a sentence-case phrase ("Generated frame").
    pub name: String,
    /// The short word its revisions are named with ("Frame" for "Frame v12").
    pub label: String,
    #[serde(default)]
    pub scheme: Scheme,
    /// The artifacts it is built from.
    #[serde(default)]
    pub inputs: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Graph {
    /// The product the project builds ("Racer 3in", "Humanoid Hand").
    pub product: String,
    pub stages: Vec<StageDef>,
    pub artifacts: Vec<ArtifactDef>,
}

impl Default for Graph {
    fn default() -> Self {
        Self::drone()
    }
}

fn stage(id: &str, name: &str) -> StageDef {
    StageDef { id: id.into(), name: name.into() }
}

fn art(id: &str, stage: &str, name: &str, label: &str, scheme: Scheme, inputs: &[&str]) -> ArtifactDef {
    ArtifactDef {
        id: id.into(),
        stage: stage.into(),
        name: name.into(),
        label: label.into(),
        scheme,
        inputs: inputs.iter().map(|s| (*s).to_owned()).collect(),
    }
}

impl Graph {
    /// The eight stages in pipeline order, the chain every ViaForm product starts from.
    pub fn stages8() -> Vec<StageDef> {
        vec![
            stage("design", "Design"),
            stage("generate", "Generate"),
            stage("assemble", "Assemble"),
            stage("electronics", "Electronics"),
            stage("simulate", "Simulate"),
            stage("train", "Train"),
            stage("render", "Render"),
            stage("make", "Make"),
        ]
    }

    /// A drone: a design, a generated frame, a flight controller board, the assembly of the
    /// three, a flight, a trained policy, renders and the manufacturing bundle.
    pub fn drone() -> Self {
        use Scheme::{Letter, Version};
        Self {
            product: "Untitled".into(),
            stages: Self::stages8(),
            artifacts: vec![
                art("design.model", "design", "Design model", "Model", Version, &[]),
                art("generate.frame", "generate", "Generated frame", "Frame", Version, &["design.model"]),
                art("electronics.board", "electronics", "Flight controller board", "Board", Letter, &[]),
                art("assemble.assembly", "assemble", "Assembly", "Assembly", Version, &["design.model", "generate.frame", "electronics.board"]),
                art("simulate.flight", "simulate", "Flight log", "Flight", Version, &["assemble.assembly"]),
                art("train.policy", "train", "Flight policy", "Policy", Version, &["simulate.flight"]),
                art("render.shots", "render", "Renders", "Renders", Version, &["assemble.assembly"]),
                art("make.bundle", "make", "Manufacturing bundle", "Bundle", Version, &["generate.frame", "electronics.board", "assemble.assembly", "train.policy"]),
            ],
        }
    }

    /// A robot hand: no generated frame. The design, its servo board, the assembly of the two,
    /// a grasp test, the trained grasp policy, renders and the manufacturing bundle. The ids
    /// stay the drone's, so every workspace reports into either graph unchanged.
    pub fn hand() -> Self {
        use Scheme::{Letter, Version};
        Self {
            product: "Untitled".into(),
            stages: Self::stages8(),
            artifacts: vec![
                art("design.model", "design", "Design model", "Model", Version, &[]),
                art("electronics.board", "electronics", "Servo driver board", "Board", Letter, &[]),
                art("assemble.assembly", "assemble", "Assembly", "Assembly", Version, &["design.model", "electronics.board"]),
                art("simulate.flight", "simulate", "Grasp test", "Grasp test", Version, &["assemble.assembly"]),
                art("train.policy", "train", "Grasp policy", "Policy", Version, &["simulate.flight"]),
                art("render.shots", "render", "Renders", "Renders", Version, &["assemble.assembly"]),
                art("make.bundle", "make", "Manufacturing bundle", "Bundle", Version, &["electronics.board", "assemble.assembly", "train.policy"]),
            ],
        }
    }

    /// A graph by name: "drone" or "hand".
    pub fn preset(name: &str) -> Option<Self> {
        match name {
            "drone" => Some(Self::drone()),
            "hand" => Some(Self::hand()),
            _ => None,
        }
    }

    pub fn artifact(&self, id: &str) -> Option<&ArtifactDef> {
        self.artifacts.iter().find(|a| a.id == id)
    }

    pub fn stage(&self, id: &str) -> Option<&StageDef> {
        self.stages.iter().find(|s| s.id == id)
    }

    /// The artifacts built from `id`, directly.
    pub fn consumers(&self, id: &str) -> Vec<&str> {
        self.artifacts.iter().filter(|a| a.inputs.iter().any(|i| i == id)).map(|a| a.id.as_str()).collect()
    }

    /// Refuses a graph a pipeline cannot run: duplicate or unknown ids, an artifact on an
    /// unknown stage, inputs listed after their consumer (the list is the build order), so
    /// there is no cycle either.
    pub fn validate(&self) -> Result<(), String> {
        let mut seen_stages = std::collections::BTreeSet::new();
        for s in &self.stages {
            if !seen_stages.insert(s.id.as_str()) {
                return Err(format!("stage {} is listed twice", s.id));
            }
        }
        let mut built = std::collections::BTreeSet::new();
        for a in &self.artifacts {
            if !seen_stages.contains(a.stage.as_str()) {
                return Err(format!("{} is on unknown stage {}", a.id, a.stage));
            }
            for i in &a.inputs {
                if !built.contains(i.as_str()) {
                    return Err(if self.artifact(i).is_some() {
                        format!("{} is built from {i}, which must come before it", a.id)
                    } else {
                        format!("{} is built from unknown artifact {i}", a.id)
                    });
                }
            }
            if !built.insert(a.id.as_str()) {
                return Err(format!("artifact {} is listed twice", a.id));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revisions_read_like_people_say_them() {
        assert_eq!(Scheme::Version.name("Frame", 12), "Frame v12");
        assert_eq!(Scheme::Letter.name("Board", 3), "Board rev C");
        assert_eq!(letters(26), "Z");
        assert_eq!(letters(27), "AA");
        assert_eq!(letters(53), "BA");
    }

    #[test]
    fn the_drone_graph_is_valid_and_bad_graphs_are_refused() {
        Graph::drone().validate().unwrap();
        Graph::hand().validate().unwrap();
        assert!(Graph::hand().artifact("generate.frame").is_none());
        let mut g = Graph::drone();
        g.artifacts.swap(0, 1);
        assert!(g.validate().unwrap_err().contains("must come before"));
        let mut g = Graph::drone();
        g.artifacts[1].inputs.push("nope".into());
        assert!(g.validate().unwrap_err().contains("unknown artifact"));
        let mut g = Graph::drone();
        g.artifacts[1].stage = "space".into();
        assert!(g.validate().is_err());
    }
}
