//! Every source the library knows. The terms of each shop change: the caveats say what was not
//! checked, and nothing here scrapes a site. A shop without an open API is a `manual` source: the
//! user pastes the product link or types the part number, and downloads the CAD model themselves.

use serde::Serialize;

use crate::types::Domain;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Access {
    /// On this machine: nothing leaves it.
    Local,
    /// An official API, with keys the user enters (kept in the macOS Keychain by the app).
    Api,
    /// By hand: part number, link, notes and attached files.
    Manual,
}

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Key {
    pub id: &'static str,
    pub label: &'static str,
    pub optional: bool,
    #[serde(skip_serializing_if = "str::is_empty")]
    pub placeholder: &'static str,
}

const fn key(id: &'static str, label: &'static str) -> Key {
    Key { id, label, optional: false, placeholder: "" }
}
const fn opt(id: &'static str, label: &'static str, placeholder: &'static str) -> Key {
    Key { id, label, optional: true, placeholder }
}

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Source {
    pub id: &'static str,
    pub name: &'static str,
    pub domain: Domain,
    pub access: Access,
    pub summary: &'static str,
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub keys: &'static [Key],
    #[serde(skip_serializing_if = "str::is_empty")]
    pub signup: &'static str,
    #[serde(skip_serializing_if = "str::is_empty")]
    pub terms: &'static str,
    /// The shop's own search page, `{q}` for the query: opened in the browser, never fetched.
    #[serde(skip_serializing_if = "str::is_empty")]
    pub search_url: &'static str,
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub caveats: &'static [&'static str],
    /// Listed for later: no API wired yet.
    pub planned: bool,
}

const fn manual(id: &'static str, name: &'static str, domain: Domain, summary: &'static str, search_url: &'static str, caveats: &'static [&'static str], planned: bool) -> Source {
    Source { id, name, domain, access: Access::Manual, summary, keys: &[], signup: "", terms: "", search_url, caveats, planned }
}

use Domain::{Both, Electronics, Mechanical};

pub const SOURCES: &[Source] = &[
    // On this machine
    Source { id: "kicad", name: "KiCad libraries", domain: Electronics, access: Access::Local,
        summary: "The official KiCad symbols, footprints and 3D models installed on this Mac, plus any library folder you add. Placed parts carry their symbol and footprint into the project.",
        keys: &[], signup: "", terms: "https://www.kicad.org/libraries/license/", search_url: "",
        caveats: &["CC-BY-SA 4.0 with an exception for designs that use them; third-party libraries keep their own licenses."], planned: false },
    Source { id: "standard", name: "Standard hardware", domain: Mechanical, access: Access::Local,
        summary: "Screws, nuts, washers, set screws, dowel pins and ball bearings, built by the design engine from the ISO, ASME and ANSI dimension tables. No download.",
        keys: &[], signup: "", terms: "", search_url: "", caveats: &[], planned: false },
    // Distributors with an official API
    Source { id: "digikey", name: "DigiKey", domain: Electronics, access: Access::Api,
        summary: "Product Information API v4: price breaks, stock, datasheet and product page. You create the developer account and the app (client credentials) yourself.",
        keys: &[key("client_id", "Client ID"), key("client_secret", "Client secret")],
        signup: "https://developer.digikey.com/", terms: "https://developer.digikey.com/terms-and-conditions",
        search_url: "https://www.digikey.com/en/products/result?keywords={q}",
        caveats: &["Daily call limits and terms not checked by ViaForm: read them on the developer portal.", "Prices are read for the US site in USD."], planned: false },
    Source { id: "mouser", name: "Mouser", domain: Electronics, access: Access::Api,
        summary: "Search API v1: price breaks, stock, datasheet and product page, with a free Search API key from your Mouser account.",
        keys: &[key("api_key", "Search API key")],
        signup: "https://www.mouser.com/api-hub/", terms: "https://www.mouser.com/api-hub/",
        search_url: "https://www.mouser.com/c/?q={q}",
        caveats: &["Call limits and terms not checked by ViaForm.", "The API takes the key in the request URL: it goes to Mouser over HTTPS only."], planned: false },
    Source { id: "nexar", name: "Octopart (Nexar)", domain: Electronics, access: Access::Api,
        summary: "One search across many distributors (offers, stock, datasheets) through the Nexar Supply GraphQL API. A free tier exists with a monthly part limit.",
        keys: &[key("client_id", "Client ID"), key("client_secret", "Client secret")],
        signup: "https://portal.nexar.com/", terms: "https://nexar.com/legal",
        search_url: "https://octopart.com/search?q={q}",
        caveats: &["Free tier limits and terms not checked by ViaForm."], planned: false },
    // Marketplaces with an official API: tools, modules, motors, supplies
    Source { id: "amazon", name: "Amazon", domain: Both, access: Access::Api,
        summary: "Product Advertising API 5: title, brand, price and product page. Needs an Amazon Associates account; the keys and the partner tag come from Associates Central.",
        keys: &[key("access_key", "Access key"), key("secret_key", "Secret key"), key("partner_tag", "Partner tag"), opt("marketplace", "Marketplace", "www.amazon.com (or .fr, .de, .co.uk, .ca, .co.jp)")],
        signup: "https://affiliate-program.amazon.com/assoc_credentials/home", terms: "https://affiliate-program.amazon.com/help/operating/policies",
        search_url: "https://www.amazon.com/s?k={q}",
        caveats: &["Amazon grants and keeps API access only to Associates accounts with recent qualifying sales, and has announced changes to this API: check the current conditions.", "No scraping: without keys, the search opens on amazon.com and a pasted product link is saved by its ASIN."], planned: false },
    Source { id: "aliexpress", name: "AliExpress", domain: Both, access: Access::Api,
        summary: "AliExpress Open Platform, affiliate product search: title, price, shop and link. You register as an AliExpress affiliate and create an app for its key and secret.",
        keys: &[key("app_key", "App key"), key("app_secret", "App secret"), opt("tracking_id", "Tracking ID", ""), opt("currency", "Currency", "USD")],
        signup: "https://openservice.aliexpress.com/", terms: "https://portals.aliexpress.com/",
        search_url: "https://www.aliexpress.com/wholesale?SearchText={q}",
        caveats: &["App approval and call limits decided by AliExpress; terms not checked by ViaForm."], planned: false },
    Source { id: "ebay", name: "eBay", domain: Both, access: Access::Api,
        summary: "Browse API: listings with price, condition and seller, from a free eBay developer account (production keyset).",
        keys: &[key("client_id", "App ID (client ID)"), key("client_secret", "Cert ID (client secret)"), opt("marketplace", "Marketplace", "EBAY_US (or EBAY_FR, EBAY_DE, EBAY_GB)")],
        signup: "https://developer.ebay.com/my/keys", terms: "https://developer.ebay.com/join/api-license-agreement",
        search_url: "https://www.ebay.com/sch/i.html?_nkw={q}",
        caveats: &["Daily call limits apply; listings change fast, so prices are a snapshot."], planned: false },
    // By hand
    manual("mcmaster", "McMaster-Carr", Mechanical,
        "No public API. Paste the product link or type the part number, download the CAD model from the product page and attach it: the app never scrapes the site.",
        "https://www.mcmaster.com/{q}",
        &["Their terms limit automated extraction: to confirm in their conditions.", "McMaster gives some approved customers a Product Information API on request; not wired here."], false),
    manual("misumi", "MISUMI", Mechanical, "Configurable mechanical parts (shafts, linear guides, extrusions). Enter the configured part number and attach the CAD file you download.",
        "https://us.misumi-ec.com/vona2/result/?Keyword={q}", &["No public search API known; terms to check."], false),
    manual("alibaba", "Alibaba.com", Both, "Factory-direct parts in volume. No open search API for buyers: paste the product link to save it with its item number, MOQ and price in the notes.",
        "https://www.alibaba.com/trade/search?SearchText={q}", &["Terms limit automated extraction; the app only reads the link you paste."], false),
    manual("temu", "Temu", Both, "No public API. Paste the product link to save it.", "https://www.temu.com/search_result.html?search_key={q}", &[], false),
    manual("robotshop", "RobotShop", Both, "Motors, controllers, sensors and kits for robots. Manual entries for now.", "https://www.robotshop.com/search?q={q}", &["API access to study."], true),
    manual("adafruit", "Adafruit", Electronics, "Breakout boards and modules; most come with open KiCad or Eagle files on GitHub. Manual entries for now.", "https://www.adafruit.com/?q={q}",
        &["A public product listing exists; its terms of use to study before wiring it."], true),
    manual("sparkfun", "SparkFun", Electronics, "Breakout boards and modules with open hardware files (KiCad and Eagle) on GitHub. Manual entries for now.", "https://www.sparkfun.com/search/?term={q}", &["API access to study."], true),
    manual("lcsc", "LCSC / JLCPCB parts", Electronics, "The parts JLCPCB assembles from, with LCSC numbers (C-numbers) that go straight into an assembly order.", "https://www.lcsc.com/search?q={q}", &["No open API known for search; terms to check."], true),
    manual("farnell", "Farnell / element14 / Newark", Electronics, "Distributor with an official Product Search API (key from their partner portal). Manual entries until it is wired.", "https://www.farnell.com/search?st={q}", &[], true),
    manual("tme", "TME", Electronics, "European distributor with an official API (token and secret from your account). Manual entries until it is wired.", "https://www.tme.eu/en/katalog/?search={q}", &[], true),
    manual("snapmagic", "SnapMagic / Ultra Librarian / SamacSys", Electronics, "Symbols, footprints and 3D models made from datasheets, as KiCad files after a free sign-in. Download, then attach the .kicad_sym, .kicad_mod or .step here.",
        "https://www.snapeda.com/search/?q={q}", &["Each site has its own license for the models: check it per part."], false),
    manual("grabcad", "GrabCAD / Printables", Mechanical, "Community CAD models (STEP) of motors, modules and enclosures. Download the STEP and attach it.", "https://grabcad.com/library?query={q}",
        &["Each model has its own license, often non-commercial: check it per model."], false),
    manual("custom", "My parts", Both, "Anything else: a part number, a link, notes and the CAD files you attach.", "", &[], false),
];

pub fn source(id: &str) -> Option<&'static Source> {
    SOURCES.iter().find(|s| s.id == id)
}

/// The required keys of an API source (the optional ones may stay empty).
pub fn required(s: &Source) -> impl Iterator<Item = &'static str> {
    s.keys.iter().filter(|k| !k.optional).map(|k| k.id)
}

/// The shop's own search page for `q`, opened in the browser.
pub fn search_page(id: &str, q: &str) -> Option<String> {
    let s = source(id)?;
    (!s.search_url.is_empty()).then(|| s.search_url.replace("{q}", &encode(q.trim())))
}

/// Percent-encoding of a URL component (RFC 3986 unreserved characters kept).
pub fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}
