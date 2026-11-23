//! The library without the network: the KiCad fixtures of the PCB engine, the design engine's
//! hardware tables, and a fake HTTP that answers like the shops.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::{Value, json};
use viaform_library::Library;
use viaform_library::links::from_link;
use viaform_library::shops::{self, Http, Request, Sig, sigv4};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../engines/pcbcraft/crates/library/tests/fixtures")
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("viaform-library-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Answers each URL prefix with a fixed body, and records the requests.
struct Fake {
    answers: Vec<(&'static str, u16, String)>,
    seen: Mutex<Vec<(String, Vec<(String, String)>, Option<String>)>>,
}

impl Http for Fake {
    fn send(&self, r: Request) -> Result<(u16, String), String> {
        self.seen.lock().unwrap().push((r.url.clone(), r.headers.clone(), r.body.clone()));
        self.answers.iter().find(|(p, ..)| r.url.starts_with(p)).map(|(_, s, b)| (*s, b.clone())).ok_or(format!("no answer for {}", r.url))
    }
}

fn fake(answers: Vec<(&'static str, u16, Value)>) -> Box<Fake> {
    Box::new(Fake { answers: answers.into_iter().map(|(p, s, b)| (p, s, b.to_string())).collect(), seen: Mutex::new(vec![]) })
}

/// A KiCad tree like the installed one: symbols/, footprints/<lib>.pretty, 3dmodels/<lib>.3dshapes.
fn kicad_tree(dir: &PathBuf) -> PathBuf {
    let root = dir.join("kicad");
    std::fs::create_dir_all(root.join("symbols")).unwrap();
    std::fs::create_dir_all(root.join("footprints/Resistor_SMD.pretty")).unwrap();
    std::fs::create_dir_all(root.join("3dmodels/Resistor_SMD.3dshapes")).unwrap();
    for f in ["device.kicad_sym", "lm358.kicad_sym"] {
        std::fs::copy(fixtures().join(f), root.join("symbols").join(f)).unwrap();
    }
    std::fs::copy(fixtures().join("R_0805_2012Metric.kicad_mod"), root.join("footprints/Resistor_SMD.pretty/R_0805_2012Metric.kicad_mod")).unwrap();
    std::fs::write(root.join("3dmodels/Resistor_SMD.3dshapes/R_0805_2012Metric.step"), "ISO-10303-21;").unwrap();
    root
}

#[test]
fn kicad_symbols_footprints_and_models() {
    let dir = scratch("kicad");
    let root = kicad_tree(&dir);
    let mut lib = Library::with(dir.join("lib"), fake(vec![]), vec![root]).unwrap();
    let hits = lib.call("search", &json!({"query": "lm358", "only": ["kicad"]})).unwrap();
    let names: Vec<&str> = hits[0]["items"].as_array().unwrap().iter().map(|i| i["name"].as_str().unwrap()).collect();
    assert!(names.contains(&"LM358"), "{names:?}");
    let hits = lib.call("search", &json!({"query": "R_0805", "only": ["kicad"]})).unwrap();
    let fp = hits[0]["items"].as_array().unwrap().iter().find(|i| i["part_number"] == "Resistor_SMD:R_0805_2012Metric").expect("footprint");
    let kinds: Vec<&str> = fp["uses"].as_array().unwrap().iter().map(|u| u["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["kicad_footprint", "step"]);
    let state = lib.call("state", &json!({})).unwrap();
    let kicad = state["sources"].as_array().unwrap().iter().find(|s| s["id"] == "kicad").unwrap();
    assert_eq!(kicad["ready"], true);
}

#[test]
fn standard_hardware_from_the_engine() {
    let dir = scratch("hardware");
    let mut lib = Library::with(dir, fake(vec![]), vec![]).unwrap();
    let hits = lib.call("search", &json!({"query": "M3x12 shcs", "only": ["standard"]})).unwrap();
    let first = &hits[0]["items"][0];
    assert_eq!(first["uses"][0], json!({"kind": "hardware", "family": "socket_head_cap_screw", "size": "M3", "length": 12.0}));
    let bearing = lib.call("search", &json!({"query": "608", "only": ["standard"]})).unwrap();
    assert!(bearing[0]["items"].as_array().unwrap().iter().any(|i| i["category"].as_str().unwrap_or("").to_lowercase().contains("bearing")));
}

#[test]
fn saved_parts_attachments_and_settings() {
    let dir = scratch("store");
    let mut lib = Library::with(dir.join("lib"), fake(vec![]), vec![]).unwrap();
    let item = json!({"source": "mcmaster", "part_number": "91290A115", "name": "M3 x 10 SHCS", "domain": "mechanical", "url": "https://www.mcmaster.com/91290A115/"});
    let saved = lib.call("save", &json!({"item": item})).unwrap();
    assert_eq!(saved["key"], "mcmaster:91290A115");
    assert!(lib.call("save", &json!({"item": {"source": "custom", "part_number": "x", "domain": "both", "url": "file:///etc/passwd"}})).is_err());
    assert!(lib.call("save", &json!({"item": {"source": "nowhere", "part_number": "x", "domain": "both"}})).is_err());

    let step = dir.join("part.step");
    std::fs::write(&step, "ISO-10303-21;").unwrap();
    let it = lib.call("attach", &json!({"key": "mcmaster:91290A115", "path": step})).unwrap();
    assert_eq!(it["uses"][0]["kind"], "step");
    let sym = lib.call("attach", &json!({"key": "mcmaster:91290A115", "path": fixtures().join("lm358.kicad_sym")})).unwrap();
    assert_eq!(sym["uses"][0]["kind"], "kicad_symbol");
    let copied = PathBuf::from(it["files"][0]["path"].as_str().unwrap());
    assert!(copied.starts_with(dir.join("lib/files")));

    // Saved again from a search: the attachments stay.
    let again = lib.call("save", &json!({"item": item})).unwrap();
    assert_eq!(again["files"].as_array().unwrap().len(), 2);
    let found = lib.call("search", &json!({"query": "shcs", "only": ["mine"]})).unwrap();
    assert_eq!(found[0]["total"], 1);

    lib.call("enable", &json!({"id": "kicad", "on": false})).unwrap();
    // A second Library on the same folder reads what the first wrote.
    let mut reopened = Library::with(dir.join("lib"), fake(vec![]), vec![]).unwrap();
    let state = reopened.call("state", &json!({})).unwrap();
    assert_eq!(state["items"].as_array().unwrap().len(), 1);
    assert_eq!(state["sources"].as_array().unwrap().iter().find(|s| s["id"] == "kicad").unwrap()["enabled"], false);

    reopened.call("remove", &json!({"key": "mcmaster:91290A115"})).unwrap();
    assert!(!copied.exists());
    assert!(step.exists(), "the user's own file is never deleted");
}

#[test]
fn links_read_without_fetching() {
    let cases = [
        ("https://www.amazon.com/Some-Drill/dp/B07XYZ1234/ref=sr_1_1?tag=x", "amazon", "B07XYZ1234"),
        ("https://fr.aliexpress.com/item/1005004321987654.html?spm=a2g0o", "aliexpress", "1005004321987654"),
        ("https://www.alibaba.com/product-detail/Brushless-Motor_1600123456789.html", "alibaba", "1600123456789"),
        ("https://www.ebay.com/itm/284512345678?hash=item", "ebay", "284512345678"),
        ("https://www.mcmaster.com/91290A115/", "mcmaster", "91290A115"),
        ("https://www.digikey.com/en/products/detail/texas-instruments/LM358DR/381426", "digikey", "LM358DR"),
        ("https://www.mouser.com/ProductDetail/Texas-Instruments/LM358DR", "mouser", "LM358DR"),
        ("https://www.lcsc.com/product-detail/C7950.html", "lcsc", "C7950"),
    ];
    for (url, src, pn) in cases {
        let l = from_link(url).unwrap_or_else(|| panic!("{url}"));
        assert_eq!((l.source, l.part_number.as_str()), (src, pn), "{url}");
    }
    assert_eq!(from_link("https://www.amazon.com/x/dp/B07XYZ1234/ref=abc?tag=y").unwrap().url, "https://www.amazon.com/dp/B07XYZ1234");
    assert_eq!(from_link("https://example.org/thing").unwrap().source, "custom");
    assert!(from_link("javascript:alert(1)").is_none());
    assert!(from_link("file:///etc/passwd").is_none());
}

#[test]
fn shops_with_keys_passed_per_search() {
    let http = fake(vec![
        ("https://api.digikey.com/v1/oauth2/token", 200, json!({"access_token": "dk-token", "expires_in": 600})),
        ("https://api.digikey.com/products/v4/search/keyword", 200, json!({"ProductsCount": 1, "Products": [{
            "ManufacturerProductNumber": "LM358DR", "Manufacturer": {"Name": "Texas Instruments"},
            "Description": {"ProductDescription": "IC OPAMP GP 2 CIRCUIT 8SOIC"}, "ProductUrl": "https://www.digikey.com/x",
            "QuantityAvailable": 12000, "ProductVariations": [{"DigiKeyProductNumber": "296-1014-1-ND", "StandardPricing": [{"BreakQuantity": 1, "UnitPrice": 0.42}]}]}]})),
        ("https://api.mouser.com/", 401, json!({"Errors": [{"Message": "Invalid unique identifier."}]})),
    ]);
    let dir = scratch("shops");
    let mut lib = Library::with(dir, http, vec![]).unwrap();
    let keys = json!({
        "digikey": {"client_id": "id", "client_secret": "secret"},
        "mouser": {"api_key": "bad"},
        "amazon": {"access_key": "a"},
    });
    let hits = lib.call("search", &json!({"query": "lm358", "only": ["digikey", "mouser", "amazon"], "keys": keys})).unwrap();
    let by: HashMap<&str, &Value> = hits.as_array().unwrap().iter().map(|h| (h["source"].as_str().unwrap(), h)).collect();
    let dk = &by["digikey"]["items"][0];
    assert_eq!(dk["part_number"], "296-1014-1-ND");
    assert_eq!(dk["prices"][0]["price"], 0.42);
    assert!(by["mouser"]["error"].as_str().unwrap().contains("Invalid unique identifier"));
    assert!(!by.contains_key("amazon"), "a source without all its keys is not searched");
    shops::forget_tokens();
}

#[test]
fn aws_signature_v4_is_stable() {
    // 2026-01-02T03:04:05Z: the same request always signs the same way.
    let h = sigv4(&Sig {
        host: "webservices.amazon.com", path: "/paapi5/searchitems", body: "{}", target: "com.amazon.paapi5.v1.ProductAdvertisingAPIv1.SearchItems",
        access: "AKIDEXAMPLE", secret: "secret", region: "us-east-1", service: "ProductAdvertisingAPI", now: 1_767_323_045,
    });
    let get = |k: &str| h.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone()).unwrap();
    assert_eq!(get("x-amz-date"), "20260102T030405Z");
    let auth = get("Authorization");
    assert!(auth.starts_with("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260102/us-east-1/ProductAdvertisingAPI/aws4_request, SignedHeaders=content-encoding;content-type;host;x-amz-date;x-amz-target, Signature="));
    assert_eq!(auth.rsplit('=').next().unwrap().len(), 64);
}

#[test]
fn aliexpress_signature() {
    let p = vec![("b".to_string(), "2".to_string()), ("a".to_string(), "1".to_string())];
    // HMAC-SHA256("secret", "a1b2"), upper-case hex.
    let s = shops::ali_sign(&p, "secret");
    assert_eq!(s.len(), 64);
    assert_eq!(s, s.to_uppercase());
    assert_eq!(s, shops::ali_sign(&[("a".into(), "1".into()), ("b".into(), "2".into())], "secret"));
}
