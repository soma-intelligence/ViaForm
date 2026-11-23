//! Side libraries for ViaForm: the KiCad libraries on this Mac, the design engine's standard
//! hardware, the official APIs of distributors (DigiKey, Mouser, Octopart) and marketplaces
//! (Amazon, AliExpress, eBay), and the parts the user saves by hand from any other shop.
//!
//! The app drives it through one JSON call (`Library::call`), over the C bridge. API keys never
//! reach this crate's storage: the app reads them from the macOS Keychain and passes them with
//! each search. No shop is scraped: shops without an open API are searched in the browser and
//! saved from a pasted link or a typed part number.

pub mod hardware;
pub mod kicad;
pub mod links;
pub mod shops;
pub mod sources;
pub mod store;
pub mod types;

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::shops::{Http, Keys, Net};
use crate::sources::{Access, SOURCES, source};
use crate::store::Store;
use crate::types::{Hits, Item};

const LIMIT: usize = 40;

pub struct Library {
    store: Store,
    http: Box<dyn Http>,
    index: Option<kicad::Index>,
    families: Option<Vec<hardware::Family>>,
    /// KiCad folders found by default on this machine; the user's own folders are added to them.
    kicad_defaults: Vec<PathBuf>,
}

fn arg<T: for<'de> Deserialize<'de>>(p: &Value, name: &str) -> Result<T, String> {
    serde_json::from_value(p.get(name).cloned().unwrap_or(Value::Null)).map_err(|e| format!("{name}: {e}"))
}

impl Library {
    pub fn open(dir: impl Into<PathBuf>) -> Result<Library, String> {
        Ok(Library { store: Store::open(dir)?, http: Box::new(Net::default()), index: None, families: None, kicad_defaults: kicad::default_roots() })
    }

    /// For the tests: answers from `http` and KiCad folders of their own.
    pub fn with(dir: impl Into<PathBuf>, http: Box<dyn Http>, kicad_defaults: Vec<PathBuf>) -> Result<Library, String> {
        Ok(Library { store: Store::open(dir)?, http, index: None, families: None, kicad_defaults })
    }

    pub fn kicad_roots(&self) -> Vec<PathBuf> {
        let mut seen = BTreeSet::new();
        self.kicad_defaults.iter().cloned().chain(self.store.settings().kicad_roots.iter().map(PathBuf::from)).filter(|r| seen.insert(r.clone())).collect()
    }

    fn kicad(&mut self, refresh: bool) -> &kicad::Index {
        if self.index.is_none() || refresh {
            let roots = self.kicad_roots();
            self.index.get_or_insert_with(kicad::Index::default).rebuild(&roots);
        }
        self.index.as_ref().expect("built above")
    }

    fn hardware(&mut self) -> &[hardware::Family] {
        self.families.get_or_insert_with(hardware::families)
    }

    fn enabled(&self, id: &str) -> bool {
        !self.store.settings().disabled.iter().any(|d| d == id)
    }

    /// One JSON call from the app. `method` names the action; the answer is the value of `ok`.
    pub fn call(&mut self, method: &str, p: &Value) -> Result<Value, String> {
        let ok = |v: Value| Ok(v);
        match method {
            "state" => ok(self.state(&arg::<Option<Vec<String>>>(p, "keyed")?.unwrap_or_default())),
            "search" => {
                let keys: HashMap<String, Keys> = arg::<Option<_>>(p, "keys")?.unwrap_or_default();
                let hits = self.search(&arg::<String>(p, "query")?, arg(p, "only")?, &keys);
                ok(serde_json::to_value(hits).map_err(|e| e.to_string())?)
            }
            "save" => {
                let it: Item = arg(p, "item")?;
                if source(&it.source).is_none() {
                    return Err(format!("unknown source {}", it.source));
                }
                ok(serde_json::to_value(self.store.save(it)?).map_err(|e| e.to_string())?)
            }
            "remove" => self.store.remove(&arg::<String>(p, "key")?).map(|_| Value::Null),
            "attach" => {
                let it = self.store.attach(&arg::<String>(p, "key")?, Path::new(&arg::<String>(p, "path")?))?;
                ok(serde_json::to_value(it).map_err(|e| e.to_string())?)
            }
            "enable" => {
                let (id, on) = (arg::<String>(p, "id")?, arg::<bool>(p, "on")?);
                let mut s = self.store.settings().clone();
                s.disabled.retain(|d| *d != id);
                if !on {
                    s.disabled.push(id);
                }
                self.store.set_settings(s).map(|_| Value::Null)
            }
            "set_kicad_roots" => {
                let mut seen = BTreeSet::new();
                let roots: Vec<String> = arg::<Vec<String>>(p, "roots")?.into_iter().map(|r| r.trim().to_string()).filter(|r| !r.is_empty() && seen.insert(r.clone())).collect();
                let mut s = self.store.settings().clone();
                s.kicad_roots = roots;
                self.store.set_settings(s)?;
                self.index = None;
                ok(Value::Null)
            }
            "refresh_kicad" => {
                self.kicad(true);
                ok(Value::Null)
            }
            "forget_tokens" => {
                shops::forget_tokens();
                ok(Value::Null)
            }
            "from_link" => ok(self.from_link(&arg::<String>(p, "url")?).map_or(Value::Null, |it| serde_json::to_value(it).unwrap_or(Value::Null))),
            "footprint" => {
                let r = arg::<String>(p, "reference")?;
                ok(self.kicad(false).footprint_file(&r).map_or(Value::Null, |f| json!(f.to_string_lossy())))
            }
            "search_page" => ok(sources::search_page(&arg::<String>(p, "id")?, &arg::<String>(p, "query")?).map_or(Value::Null, Value::String)),
            _ => Err(format!("unknown library call {method}")),
        }
    }

    /// Every source with what the app shows about it. `keyed` lists the API sources whose required
    /// keys the app holds in the Keychain.
    pub fn state(&mut self, keyed: &[String]) -> Value {
        let mut out = vec![];
        for s in SOURCES {
            let enabled = self.enabled(s.id);
            let (ready, detail) = match (s.id, s.access) {
                ("kicad", _) => {
                    let ix = if enabled { Some(self.kicad(false)) } else { self.index.as_ref() };
                    match ix {
                        Some(ix) => (
                            !ix.symbols.is_empty() || !ix.footprints.is_empty(),
                            Some(format!("{} symbol libraries ({} symbols), {} footprint libraries, {} 3D model folders", ix.symbol_files.len(), ix.symbols.len(), ix.footprint_libs.len(), ix.model_libs.len())),
                        ),
                        None => (false, Some("Not indexed yet".into())),
                    }
                }
                ("standard", _) => (true, Some(format!("{} families", self.hardware().len()))),
                (_, Access::Api) => {
                    let ready = keyed.iter().any(|k| k == s.id);
                    (ready, Some(if ready { "Keys in the Keychain" } else { "No keys yet" }.into()))
                }
                _ => {
                    let n = self.store.items().iter().filter(|i| i.source == s.id).count();
                    (true, (n > 0).then(|| format!("{n} saved")))
                }
            };
            let mut v = serde_json::to_value(s).unwrap_or_default();
            v["enabled"] = json!(enabled);
            v["ready"] = json!(ready);
            if let Some(d) = detail {
                v["detail"] = json!(d);
            }
            out.push(v);
        }
        json!({ "sources": out, "items": self.store.items(), "kicad_roots": self.store.settings().kicad_roots })
    }

    /// Searches the user's saved parts and every enabled source that answers searches, or only
    /// those in `only`. The API sources run side by side, each with the keys the app passed.
    pub fn search(&mut self, q: &str, only: Option<Vec<String>>, keys: &HashMap<String, Keys>) -> Vec<Hits> {
        let q = q.trim();
        if q.is_empty() {
            return vec![];
        }
        let want = |me: &Self, id: &str| me.enabled(id) && only.as_ref().is_none_or(|o| o.iter().any(|x| x == id));
        let mut out = vec![];
        if want(self, "mine") {
            let items = self.search_saved(q);
            out.push(Hits { source: "mine".into(), total: items.len(), items, error: None });
        }
        if want(self, "kicad") {
            let (items, total) = self.kicad(false).search(q, LIMIT);
            out.push(Hits { source: "kicad".into(), items, total, error: None });
        }
        if want(self, "standard") {
            let (items, total) = hardware::search(self.hardware(), q, LIMIT);
            out.push(Hits { source: "standard".into(), items, total, error: None });
        }
        let apis: Vec<(&str, &Keys)> = SOURCES
            .iter()
            .filter(|s| s.access == Access::Api && want(self, s.id))
            .filter_map(|s| keys.get(s.id).filter(|k| sources::required(s).all(|id| k.get(id).is_some_and(|v| !v.trim().is_empty()))).map(|k| (s.id, k)))
            .collect();
        let http = self.http.as_ref();
        std::thread::scope(|scope| {
            let jobs: Vec<_> = apis.iter().map(|(id, k)| (*id, scope.spawn(move || shops::search(id, http, k, q)))).collect();
            for (id, job) in jobs {
                let hit = match job.join().ok().flatten() {
                    Some(Ok((items, total))) => Hits { source: id.into(), items, total, error: None },
                    Some(Err(e)) => Hits { source: id.into(), items: vec![], total: 0, error: Some(e) },
                    None => Hits { source: id.into(), items: vec![], total: 0, error: Some("the search stopped".into()) },
                };
                out.push(hit);
            }
        });
        out
    }

    fn search_saved(&self, q: &str) -> Vec<Item> {
        let words: Vec<String> = q.to_lowercase().split_whitespace().map(String::from).collect();
        self.store
            .items()
            .iter()
            .filter(|i| {
                let fields = [Some(&i.part_number), Some(&i.name), i.description.as_ref(), i.manufacturer.as_ref(), i.mpn.as_ref(), i.category.as_ref(), i.notes.as_ref()];
                let mut hay: Vec<&str> = fields.into_iter().flatten().map(String::as_str).collect();
                hay.extend(i.tags.iter().map(String::as_str));
                hay.extend(source(&i.source).map(|s| s.name));
                let hay = hay.join(" ").to_lowercase();
                words.iter().all(|w| hay.contains(w.as_str()))
            })
            .cloned()
            .collect()
    }

    /// A pasted product link read for its shop and part number; a part already saved comes back whole.
    pub fn from_link(&self, url: &str) -> Option<Item> {
        let l = links::from_link(url)?;
        if !l.part_number.is_empty() {
            if let Some(saved) = self.store.item(&format!("{}:{}", l.source, l.part_number)) {
                return Some(saved.clone());
            }
        }
        let domain = source(l.source).map_or(types::Domain::Both, |s| s.domain);
        let mut it = Item::new(l.source, l.part_number, "", domain);
        it.key = String::new();
        it.url = Some(l.url);
        Some(it)
    }
}
