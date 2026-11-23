//! The user's own library, on this machine only (the app's data folder, outside every project and
//! every Git repository): saved items in library.json, attached CAD files under files/, and the
//! settings of the sources. API keys are not here: the app keeps them in the macOS Keychain.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::kicad::read_symbols;
use crate::types::{FileRef, Item, Use};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub disabled: Vec<String>,
    #[serde(default)]
    pub kicad_roots: Vec<String>,
}

#[derive(Default, Serialize, Deserialize)]
struct Saved {
    #[serde(default)]
    items: Vec<Item>,
    #[serde(default)]
    settings: Settings,
}

pub struct Store {
    pub dir: PathBuf,
    data: Saved,
}

impl Store {
    pub fn open(dir: impl Into<PathBuf>) -> Result<Store, String> {
        let dir = dir.into();
        std::fs::create_dir_all(dir.join("files")).map_err(|e| format!("library folder {}: {e}", dir.display()))?;
        let data = std::fs::read_to_string(dir.join("library.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        Ok(Store { dir, data })
    }

    fn write(&self) -> Result<(), String> {
        let file = self.dir.join("library.json");
        let tmp = self.dir.join("library.json.tmp");
        let text = serde_json::to_string_pretty(&self.data).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, &file)).map_err(|e| format!("saving the library: {e}"))
    }

    pub fn items(&self) -> &[Item] {
        &self.data.items
    }

    pub fn settings(&self) -> &Settings {
        &self.data.settings
    }

    pub fn item(&self, key: &str) -> Option<&Item> {
        self.data.items.iter().find(|i| i.key == key)
    }

    /// Saves or replaces an item; a manual entry without a key gets one from its source and part number.
    pub fn save(&mut self, mut it: Item) -> Result<Item, String> {
        it.part_number = it.part_number.trim().to_string();
        if it.part_number.is_empty() {
            return Err("a part number is required".into());
        }
        if let Some(u) = &it.url {
            if !(u.starts_with("http://") || u.starts_with("https://")) {
                return Err("the link must start with http:// or https://".into());
            }
        }
        if it.key.is_empty() {
            it.key = format!("{}:{}", it.source, it.part_number);
        }
        it.saved_at = Some(SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0));
        // Files attached earlier stay attached when the item is saved again from a search.
        if let Some(i) = self.data.items.iter().position(|x| x.key == it.key) {
            let old = self.data.items.remove(i);
            it.files = merge(old.files, it.files);
            it.uses = merge(old.uses, it.uses);
            if it.notes.is_none() {
                it.notes = old.notes;
            }
        }
        self.data.items.insert(0, it.clone());
        self.write()?;
        Ok(it)
    }

    pub fn remove(&mut self, key: &str) -> Result<(), String> {
        let Some(i) = self.data.items.iter().position(|x| x.key == key) else { return Ok(()) };
        let it = self.data.items.remove(i);
        // Only the copies in our own files/ folder are deleted, never a file elsewhere on the disk.
        for f in &it.files {
            if self.owns(Path::new(&f.path)) {
                let _ = std::fs::remove_file(&f.path);
            }
        }
        self.write()
    }

    pub fn owns(&self, p: &Path) -> bool {
        let files = self.dir.join("files");
        p.parent().is_some_and(|d| d == files) && p.components().all(|c| !matches!(c, std::path::Component::ParentDir))
    }

    /// Copies `src` into files/ and attaches it to the item; a STEP file can then go into the
    /// design, a footprint onto a part, and a symbol into the schematic.
    pub fn attach(&mut self, key: &str, src: &Path) -> Result<Item, String> {
        let i = self.data.items.iter().position(|x| x.key == key).ok_or("save the item before attaching files")?;
        let name = src.file_name().and_then(|n| n.to_str()).ok_or("not a file")?;
        let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
        let safe = |s: &str| s.chars().map(|c| if c.is_ascii_alphanumeric() || "._-".contains(c) { c } else { '_' }).collect::<String>();
        let dest = self.dir.join("files").join(format!("{}-{}", safe(key), safe(name)));
        std::fs::copy(src, &dest).map_err(|e| format!("copying {name}: {e}"))?;
        let path = dest.to_string_lossy().to_string();
        let it = &mut self.data.items[i];
        let new = match ext.as_str() {
            "step" | "stp" => vec![Use::Step { path: path.clone() }],
            "kicad_mod" => vec![Use::KicadFootprint { path: path.clone() }],
            "kicad_sym" => {
                // A symbol downloaded for this part (SnapMagic, a maker's site): its first symbol is
                // placed, with the footprint attached earlier if there is one.
                let text = std::fs::read_to_string(&dest).map_err(|e| e.to_string())?;
                let lib = Path::new(name).file_stem().and_then(|s| s.to_str()).unwrap_or("");
                let Some(sym) = read_symbols(&text, lib, &dest).into_iter().next() else {
                    let _ = std::fs::remove_file(&dest);
                    return Err("no symbol in this file".into());
                };
                let footprint = it.uses.iter().find_map(|u| match u { Use::KicadFootprint { path } => Some(path.clone()), _ => None });
                it.uses.insert(0, Use::KicadSymbol { path: path.clone(), symbol: sym.name, footprint });
                vec![]
            }
            _ => vec![],
        };
        it.files = merge(std::mem::take(&mut it.files), vec![FileRef { label: name.into(), path }]);
        it.uses = merge(std::mem::take(&mut it.uses), new);
        let out = it.clone();
        self.write()?;
        Ok(out)
    }

    pub fn set_settings(&mut self, s: Settings) -> Result<(), String> {
        self.data.settings = s;
        self.write()
    }
}

fn merge<T: PartialEq>(mut a: Vec<T>, b: Vec<T>) -> Vec<T> {
    for x in b {
        if !a.contains(&x) {
            a.push(x);
        }
    }
    a
}
