//! The KiCad libraries on this machine, indexed by reading the files directly: a symbol library
//! is scanned for its top-level symbols and their description, keywords and footprint, a .pretty
//! folder for its footprints, a .3dshapes folder for its STEP models. Only the part the user
//! places is parsed in full, by the PCB engine (`component.place_library`, `footprint.assign`).

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::types::{Domain, FileRef, Item, Use};

#[derive(Clone, Debug, PartialEq)]
pub struct Symbol {
    pub lib: String,
    pub name: String,
    pub description: String,
    pub keywords: String,
    pub footprint: String,
    pub datasheet: String,
    pub path: PathBuf,
}

#[derive(Clone, Debug)]
pub struct Footprint {
    pub lib: String,
    pub name: String,
    pub path: PathBuf,
}

#[derive(Default)]
pub struct Index {
    pub symbol_files: Vec<PathBuf>,
    pub footprint_libs: Vec<PathBuf>,
    pub model_libs: Vec<PathBuf>,
    pub symbols: Vec<Symbol>,
    pub footprints: Vec<Footprint>,
    cache: HashMap<PathBuf, (Option<SystemTime>, Vec<Symbol>)>,
}

/// Where KiCad installs its libraries on macOS, and the folders its variables point to.
pub fn default_roots() -> Vec<PathBuf> {
    let mut roots = vec![PathBuf::from("/Applications/KiCad/KiCad.app/Contents/SharedSupport")];
    if let Some(home) = std::env::var_os("HOME") {
        roots.push(Path::new(&home).join("Library/Application Support/kicad"));
    }
    roots.extend(["/usr/share/kicad", "/usr/local/share/kicad"].map(PathBuf::from));
    for v in ["10", "9", "8"] {
        for k in ["SYMBOL_DIR", "FOOTPRINT_DIR", "3DMODEL_DIR"] {
            if let Some(p) = std::env::var_os(format!("KICAD{v}_{k}")) {
                roots.push(p.into());
            }
        }
    }
    let mut seen = BTreeSet::new();
    roots.retain(|r| seen.insert(r.clone()));
    roots
}

fn list(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).map(|d| d.flatten().map(|e| e.path()).collect()).unwrap_or_default()
}

fn stem(p: &Path) -> String {
    p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
}

fn ext(p: &Path) -> &str {
    p.extension().and_then(|s| s.to_str()).unwrap_or("")
}

impl Index {
    /// Rebuilds the index of `roots`, rereading only the symbol files that changed since last time.
    pub fn rebuild(&mut self, roots: &[PathBuf]) {
        let (mut syms, mut fps, mut models) = (BTreeSet::new(), BTreeSet::new(), BTreeSet::new());
        for root in roots.iter().filter(|r| r.is_dir()) {
            for dir in [root.clone(), root.join("symbols"), root.join("footprints"), root.join("3dmodels")] {
                for p in list(&dir) {
                    match ext(&p) {
                        "kicad_sym" if p.is_file() => { syms.insert(p); }
                        "pretty" if p.is_dir() => { fps.insert(p); }
                        "3dshapes" if p.is_dir() => { models.insert(p); }
                        _ => {}
                    }
                }
            }
        }
        let by_name = |s: BTreeSet<PathBuf>| {
            let mut v: Vec<_> = s.into_iter().collect();
            v.sort_by_key(|p| p.file_name().map(|n| n.to_os_string()));
            v
        };
        self.symbol_files = by_name(syms);
        self.footprint_libs = by_name(fps);
        self.model_libs = by_name(models);
        self.symbols.clear();
        for file in &self.symbol_files {
            let mtime = std::fs::metadata(file).and_then(|m| m.modified()).ok();
            let fresh = matches!(self.cache.get(file), Some((t, _)) if t.is_some() && *t == mtime);
            if !fresh {
                let parsed = std::fs::read_to_string(file).map(|t| read_symbols(&t, &stem(file), file)).unwrap_or_default();
                self.cache.insert(file.clone(), (mtime, parsed));
            }
            self.symbols.extend(self.cache[file].1.iter().cloned());
        }
        self.footprints.clear();
        for dir in &self.footprint_libs {
            let lib = stem(dir);
            for p in list(dir) {
                if ext(&p) == "kicad_mod" {
                    self.footprints.push(Footprint { lib: lib.clone(), name: stem(&p), path: p });
                }
            }
        }
    }

    /// `Library:Name` to the footprint file, when that library is installed.
    pub fn footprint_file(&self, reference: &str) -> Option<PathBuf> {
        let (lib, name) = reference.split_once(':')?;
        let dir = self.footprint_libs.iter().find(|d| stem(d) == lib)?;
        let f = dir.join(format!("{name}.kicad_mod"));
        f.is_file().then_some(f)
    }

    /// The STEP model KiCad ships for a footprint (`<lib>.3dshapes/<name>.step`), when installed.
    pub fn model_file(&self, lib: &str, name: &str) -> Option<PathBuf> {
        self.model_libs.iter().filter(|d| stem(d) == lib).find_map(|d| {
            ["step", "stp"].iter().map(|e| d.join(format!("{name}.{e}"))).find(|f| f.is_file())
        })
    }

    pub fn search(&self, query: &str, limit: usize) -> (Vec<Item>, usize) {
        let words: Vec<String> = query.to_lowercase().split_whitespace().map(String::from).collect();
        if words.is_empty() {
            return (vec![], 0);
        }
        let hit = |hay: String| words.iter().all(|w| hay.contains(w.as_str()));
        let mut syms: Vec<&Symbol> = self.symbols.iter().filter(|s| hit(format!("{} {} {} {}", s.lib, s.name, s.description, s.keywords).to_lowercase())).collect();
        let mut fps: Vec<&Footprint> = self.footprints.iter().filter(|f| hit(format!("{} {}", f.lib, f.name).to_lowercase())).collect();
        syms.sort_by(|a, b| rank(&words, &a.name).cmp(&rank(&words, &b.name)).then_with(|| a.name.cmp(&b.name)));
        fps.sort_by(|a, b| rank(&words, &a.name).cmp(&rank(&words, &b.name)).then_with(|| a.name.cmp(&b.name)));
        // Symbols first (what a schematic places), then footprints, half and half when both are many.
        let half = limit.div_ceil(2);
        let ns = if fps.is_empty() { limit } else { half.max(limit.saturating_sub(fps.len())) }.min(syms.len());
        let nf = (limit - ns).min(fps.len());
        let total = syms.len() + fps.len();
        let mut items: Vec<Item> = syms[..ns].iter().map(|s| self.symbol_item(s)).collect();
        items.extend(fps[..nf].iter().map(|f| self.footprint_item(f)));
        (items, total)
    }

    pub fn symbol_item(&self, s: &Symbol) -> Item {
        let mut it = Item::new("kicad", format!("{}:{}", s.lib, s.name), &s.name, Domain::Electronics);
        it.description = (!s.description.is_empty()).then(|| s.description.clone());
        it.category = Some(s.lib.clone());
        it.datasheet = (s.datasheet.starts_with("http://") || s.datasheet.starts_with("https://")).then(|| s.datasheet.clone());
        it.tags = s.keywords.split_whitespace().map(String::from).collect();
        it.files.push(FileRef { label: "Symbol".into(), path: s.path.to_string_lossy().into() });
        let fp = (!s.footprint.is_empty()).then(|| self.footprint_file(&s.footprint)).flatten();
        it.uses.push(Use::KicadSymbol { path: s.path.to_string_lossy().into(), symbol: s.name.clone(), footprint: fp.as_ref().map(|p| p.to_string_lossy().into()) });
        if let Some(fp) = fp {
            it.files.push(FileRef { label: format!("Footprint {}", s.footprint), path: fp.to_string_lossy().into() });
            let (lib, name) = s.footprint.split_once(':').unwrap_or_default();
            if let Some(step) = self.model_file(lib, name) {
                it.uses.push(Use::Step { path: step.to_string_lossy().into() });
                it.files.push(FileRef { label: "3D model".into(), path: step.to_string_lossy().into() });
            }
        }
        it
    }

    pub fn footprint_item(&self, f: &Footprint) -> Item {
        let mut it = Item::new("kicad", format!("{}:{}", f.lib, f.name), &f.name, Domain::Electronics);
        it.description = Some(format!("Footprint, {}", f.lib));
        it.category = Some(f.lib.clone());
        it.files.push(FileRef { label: "Footprint".into(), path: f.path.to_string_lossy().into() });
        it.uses.push(Use::KicadFootprint { path: f.path.to_string_lossy().into() });
        if let Some(step) = self.model_file(&f.lib, &f.name) {
            it.files.push(FileRef { label: "3D model".into(), path: step.to_string_lossy().into() });
            it.uses.push(Use::Step { path: step.to_string_lossy().into() });
        }
        it
    }
}

fn rank(words: &[String], name: &str) -> u8 {
    let n = name.to_lowercase();
    let q = words.join(" ");
    if n == q { 0 } else if n.starts_with(&q) { 1 } else if n.contains(&q) { 2 } else { 3 }
}

/// The top-level symbols of a .kicad_sym text with their properties. A small reader of
/// S-expressions: it follows the depth and the quoted strings, and keeps the symbols one level
/// under `kicad_symbol_lib` (the units, `R_0_1` and the like, sit deeper and are skipped).
pub fn read_symbols(text: &str, lib: &str, file: &Path) -> Vec<Symbol> {
    let b = text.as_bytes();
    let n = b.len();
    let mut i = 0;
    let mut depth = 0i32;
    let mut out = vec![];
    let mut current: Option<Symbol> = None;

    fn string(b: &[u8], i: &mut usize) -> String {
        let mut s = Vec::new();
        *i += 1;
        while *i < b.len() && b[*i] != b'"' {
            if b[*i] == b'\\' && *i + 1 < b.len() {
                *i += 1;
            }
            s.push(b[*i]);
            *i += 1;
        }
        *i += 1;
        String::from_utf8_lossy(&s).into_owned()
    }
    fn atom(b: &[u8], i: &mut usize) -> String {
        while *i < b.len() && b[*i].is_ascii_whitespace() {
            *i += 1;
        }
        if *i < b.len() && b[*i] == b'"' {
            return string(b, i);
        }
        let start = *i;
        while *i < b.len() && !b[*i].is_ascii_whitespace() && b[*i] != b'(' && b[*i] != b')' {
            *i += 1;
        }
        String::from_utf8_lossy(&b[start..*i]).into_owned()
    }

    while i < n {
        match b[i] {
            b'"' => {
                string(b, &mut i);
            }
            b')' => {
                depth -= 1;
                if depth == 1 {
                    if let Some(s) = current.take() {
                        out.push(s);
                    }
                }
                i += 1;
            }
            b'(' => {
                i += 1;
                depth += 1;
                let head = atom(b, &mut i);
                if head == "symbol" && depth == 2 {
                    current = Some(Symbol { lib: lib.into(), name: atom(b, &mut i), description: String::new(), keywords: String::new(), footprint: String::new(), datasheet: String::new(), path: file.into() });
                } else if head == "property" && depth == 3 {
                    if let Some(s) = current.as_mut() {
                        let (k, v) = (atom(b, &mut i), atom(b, &mut i));
                        match k.as_str() {
                            "Description" | "ki_description" if s.description.is_empty() => s.description = v,
                            "ki_keywords" => s.keywords = v,
                            "Footprint" => s.footprint = v,
                            "Datasheet" if v != "~" => s.datasheet = v,
                            _ => {}
                        }
                    }
                }
            }
            _ => i += 1,
        }
    }
    out
}
