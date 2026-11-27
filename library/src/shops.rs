//! The distributors' and marketplaces' official APIs. Each search is one or two HTTPS calls with
//! the user's own keys (read from the macOS Keychain by the app and passed in per call; never
//! stored here); the answers are mapped to items and nothing else is kept.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::sources::encode;
use crate::types::{Domain, Item, PriceBreak};

pub type Keys = HashMap<String, String>;

/// One HTTP request, so the tests can answer for the shops.
pub struct Request<'a> {
    pub method: &'a str,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

pub trait Http: Send + Sync {
    /// The status and the body text.
    fn send(&self, r: Request) -> Result<(u16, String), String>;
}

/// The real network: ureq with rustls, 15 s per call, HTTP errors returned as statuses.
pub struct Net(ureq::Agent);

impl Default for Net {
    fn default() -> Self {
        let config = ureq::Agent::config_builder().http_status_as_error(false).timeout_global(Some(Duration::from_secs(15))).build();
        Net(config.into())
    }
}

impl Http for Net {
    fn send(&self, r: Request) -> Result<(u16, String), String> {
        let mut res = if r.method == "GET" {
            let mut b = self.0.get(&r.url);
            for (k, v) in &r.headers {
                b = b.header(k, v);
            }
            b.call()
        } else {
            let mut b = self.0.post(&r.url);
            for (k, v) in &r.headers {
                b = b.header(k, v);
            }
            b.send(r.body.unwrap_or_default())
        }
        .map_err(|e| e.to_string())?;
        let status = res.status().as_u16();
        let text = res.body_mut().read_to_string().map_err(|e| e.to_string())?;
        Ok((status, text))
    }
}

fn call(http: &dyn Http, r: Request, who: &str) -> Result<Value, String> {
    let (status, text) = http.send(r).map_err(|e| format!("{who}: {e}"))?;
    let j: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    if !(200..300).contains(&status) {
        let detail = [
            j.pointer("/detail"), j.pointer("/error_description"), j.pointer("/ErrorMessage"), j.pointer("/Errors/0/Message"),
            j.pointer("/errors/0/message"), j.pointer("/message"),
        ]
        .into_iter()
        .flatten()
        .find_map(Value::as_str)
        .map(String::from)
        .unwrap_or_else(|| text.chars().take(200).collect());
        return Err(format!("{who}: {status} {detail}").trim().to_string());
    }
    Ok(j)
}

fn need(keys: &Keys, ids: &[&str], who: &str) -> Result<(), String> {
    let missing: Vec<&str> = ids.iter().copied().filter(|k| keys.get(*k).is_none_or(|v| v.trim().is_empty())).collect();
    if missing.is_empty() { Ok(()) } else { Err(format!("{who}: enter {} in the source settings", missing.join(", "))) }
}

fn k<'a>(keys: &'a Keys, id: &str) -> &'a str {
    keys.get(id).map(|s| s.trim()).unwrap_or("")
}

fn form(pairs: &[(&str, &str)]) -> String {
    pairs.iter().map(|(k, v)| format!("{}={}", encode(k), encode(v))).collect::<Vec<_>>().join("&")
}

fn num(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.chars().filter(|c| c.is_ascii_digit() || *c == '.').collect::<String>().parse().ok(),
        _ => None,
    }
}

fn s(v: &Value, p: &str) -> Option<String> {
    v.pointer(p).and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from)
}

/// OAuth tokens per client, kept until a minute before they expire.
static TOKENS: Mutex<Option<HashMap<String, (String, Instant)>>> = Mutex::new(None);

pub fn forget_tokens() {
    *TOKENS.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

fn token(http: &dyn Http, url: &str, id: &str, r: impl FnOnce() -> Request<'static>, who: &str) -> Result<String, String> {
    let cache_key = format!("{url}|{id}");
    if let Some((t, until)) = TOKENS.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|m| m.get(&cache_key).cloned()) {
        if until > Instant::now() {
            return Ok(t);
        }
    }
    let j = call(http, r(), who)?;
    let t = s(&j, "/access_token").ok_or(format!("{who}: no access token in the answer"))?;
    let life = j.get("expires_in").and_then(num).unwrap_or(600.0).max(120.0) - 60.0;
    TOKENS.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).insert(cache_key, (t.clone(), Instant::now() + Duration::from_secs_f64(life)));
    Ok(t)
}

fn client_credentials(http: &dyn Http, url: &'static str, keys: &Keys, scope: Option<&str>, who: &str) -> Result<String, String> {
    need(keys, &["client_id", "client_secret"], who)?;
    let (id, secret) = (k(keys, "client_id").to_string(), k(keys, "client_secret").to_string());
    let mut pairs = vec![("client_id", id.as_str()), ("client_secret", secret.as_str()), ("grant_type", "client_credentials")];
    if let Some(sc) = scope {
        pairs.push(("scope", sc));
    }
    let body = form(&pairs);
    token(http, url, &id, || Request { method: "POST", url: url.into(), headers: vec![("Content-Type".into(), "application/x-www-form-urlencoded".into())], body: Some(body) }, who)
}

pub type Found = (Vec<Item>, usize);

/// The API search of `source`, when there is one.
pub fn search(source: &str, http: &dyn Http, keys: &Keys, q: &str) -> Option<Result<Found, String>> {
    Some(match source {
        "digikey" => digikey(http, keys, q),
        "mouser" => mouser(http, keys, q),
        "nexar" => nexar(http, keys, q),
        "amazon" => amazon(http, keys, q, None),
        "aliexpress" => aliexpress(http, keys, q, None),
        "ebay" => ebay(http, keys, q),
        _ => return None,
    })
}

// MARK: DigiKey, Product Information API v4

pub fn digikey(http: &dyn Http, keys: &Keys, q: &str) -> Result<Found, String> {
    let t = client_credentials(http, "https://api.digikey.com/v1/oauth2/token", keys, None, "DigiKey")?;
    let j = call(http, Request {
        method: "POST",
        url: "https://api.digikey.com/products/v4/search/keyword".into(),
        headers: vec![
            ("Content-Type".into(), "application/json".into()),
            ("Authorization".into(), format!("Bearer {t}")),
            ("X-DIGIKEY-Client-Id".into(), k(keys, "client_id").into()),
            ("X-DIGIKEY-Locale-Site".into(), "US".into()),
            ("X-DIGIKEY-Locale-Language".into(), "en".into()),
            ("X-DIGIKEY-Locale-Currency".into(), "USD".into()),
        ],
        body: Some(json!({"Keywords": q, "Limit": 20, "Offset": 0}).to_string()),
    }, "DigiKey")?;
    let items = j["Products"].as_array().into_iter().flatten().map(digikey_item).collect();
    Ok((items, j["ProductsCount"].as_u64().unwrap_or(0) as usize))
}

pub fn digikey_item(p: &Value) -> Item {
    let v = &p["ProductVariations"][0];
    let mpn = s(p, "/ManufacturerProductNumber");
    let dk = s(v, "/DigiKeyProductNumber").or(s(p, "/DigiKeyProductNumber")).or(mpn.clone()).unwrap_or_default();
    let mut it = Item::new("digikey", dk.clone(), mpn.clone().unwrap_or(dk), Domain::Electronics);
    it.description = s(p, "/Description/ProductDescription").or(s(p, "/Description/DetailedDescription"));
    it.manufacturer = s(p, "/Manufacturer/Name");
    it.mpn = mpn;
    it.category = s(p, "/Category/Name");
    it.url = s(p, "/ProductUrl");
    it.datasheet = s(p, "/DatasheetUrl");
    it.stock = p.get("QuantityAvailable").and_then(num);
    let pricing = v.get("StandardPricing").or(p.get("StandardPricing")).and_then(Value::as_array);
    it.prices = pricing.into_iter().flatten().filter_map(|b| Some(PriceBreak { quantity: num(&b["BreakQuantity"])?, price: num(&b["UnitPrice"])?, currency: "USD".into() })).collect();
    if it.prices.is_empty() {
        if let Some(u) = p.get("UnitPrice").and_then(num).filter(|u| *u > 0.0) {
            it.prices.push(PriceBreak { quantity: 1.0, price: u, currency: "USD".into() });
        }
    }
    it
}

// MARK: Mouser, Search API v1

pub fn mouser(http: &dyn Http, keys: &Keys, q: &str) -> Result<Found, String> {
    need(keys, &["api_key"], "Mouser")?;
    let j = call(http, Request {
        method: "POST",
        url: format!("https://api.mouser.com/api/v1/search/keyword?apiKey={}", encode(k(keys, "api_key"))),
        headers: vec![("Content-Type".into(), "application/json".into()), ("Accept".into(), "application/json".into())],
        body: Some(json!({"SearchByKeywordRequest": {"keyword": q, "records": 20, "startingRecord": 0, "searchOptions": "", "searchWithYourSignUpLanguage": ""}}).to_string()),
    }, "Mouser")?;
    if let Some(e) = j["Errors"].as_array().filter(|e| !e.is_empty()) {
        return Err(format!("Mouser: {}", e.iter().filter_map(|x| x["Message"].as_str()).collect::<Vec<_>>().join("; ")));
    }
    let items = j.pointer("/SearchResults/Parts").and_then(Value::as_array).into_iter().flatten().map(mouser_item).collect();
    Ok((items, j.pointer("/SearchResults/NumberOfResult").and_then(Value::as_u64).unwrap_or(0) as usize))
}

pub fn mouser_item(p: &Value) -> Item {
    let mpn = s(p, "/ManufacturerPartNumber");
    let n = s(p, "/MouserPartNumber").or(mpn.clone()).unwrap_or_default();
    let mut it = Item::new("mouser", n.clone(), mpn.clone().unwrap_or(n), Domain::Electronics);
    it.description = s(p, "/Description");
    it.manufacturer = s(p, "/Manufacturer");
    it.mpn = mpn;
    it.category = s(p, "/Category");
    it.url = s(p, "/ProductDetailUrl");
    it.datasheet = s(p, "/DataSheetUrl");
    it.stock = p.get("AvailabilityInStock").and_then(num).or(p.get("Availability").and_then(num));
    it.prices = p["PriceBreaks"].as_array().into_iter().flatten()
        .filter_map(|b| Some(PriceBreak { quantity: num(&b["Quantity"])?, price: num(&b["Price"])?, currency: s(b, "/Currency").unwrap_or("USD".into()) }))
        .collect();
    it
}

// MARK: Octopart through Nexar, Supply GraphQL API

const NEXAR_QUERY: &str = "query Search($q: String!, $limit: Int!) { supSearch(q: $q, limit: $limit) { hits results { part { mpn name shortDescription octopartUrl totalAvail manufacturer { name } category { name } bestDatasheet { url } sellers(authorizedOnly: true) { company { name } offers { sku inventoryLevel clickUrl prices { quantity price currency } } } } } } }";

pub fn nexar(http: &dyn Http, keys: &Keys, q: &str) -> Result<Found, String> {
    let t = client_credentials(http, "https://identity.nexar.com/connect/token", keys, Some("supply.domain"), "Nexar")?;
    let j = call(http, Request {
        method: "POST",
        url: "https://api.nexar.com/graphql".into(),
        headers: vec![("Content-Type".into(), "application/json".into()), ("Authorization".into(), format!("Bearer {t}"))],
        body: Some(json!({"query": NEXAR_QUERY, "variables": {"q": q, "limit": 20}}).to_string()),
    }, "Nexar")?;
    if let Some(e) = j["errors"].as_array().filter(|e| !e.is_empty()) {
        return Err(format!("Nexar: {}", e.iter().filter_map(|x| x["message"].as_str()).collect::<Vec<_>>().join("; ")));
    }
    let r = &j["data"]["supSearch"];
    let items = r["results"].as_array().into_iter().flatten().map(|x| nexar_item(&x["part"])).collect();
    Ok((items, r["hits"].as_u64().unwrap_or(0) as usize))
}

pub fn nexar_item(p: &Value) -> Item {
    // The cheapest single-unit USD offer among authorized sellers gives the price breaks shown.
    let mut best: Option<(String, Vec<PriceBreak>)> = None;
    for seller in p["sellers"].as_array().into_iter().flatten() {
        for o in seller["offers"].as_array().into_iter().flatten() {
            let prices: Vec<PriceBreak> = o["prices"].as_array().into_iter().flatten()
                .filter(|x| x["currency"] == "USD")
                .filter_map(|x| Some(PriceBreak { quantity: num(&x["quantity"])?, price: num(&x["price"])?, currency: "USD".into() }))
                .collect();
            if !prices.is_empty() && best.as_ref().is_none_or(|b| prices[0].price < b.1[0].price) {
                best = Some((s(seller, "/company/name").unwrap_or_default(), prices));
            }
        }
    }
    let mpn = s(p, "/mpn").unwrap_or_default();
    let mfr = s(p, "/manufacturer/name");
    let mut it = Item::new("nexar", mpn.clone(), mpn.clone(), Domain::Electronics);
    it.key = format!("nexar:{}:{mpn}", mfr.clone().unwrap_or_default());
    it.description = s(p, "/shortDescription").or(s(p, "/name"));
    it.manufacturer = mfr;
    it.mpn = Some(mpn);
    it.category = s(p, "/category/name");
    it.url = s(p, "/octopartUrl");
    it.datasheet = s(p, "/bestDatasheet/url");
    it.stock = p.get("totalAvail").and_then(num);
    if let Some((seller, prices)) = best {
        it.prices = prices;
        it.notes = Some(format!("Prices from {seller}"));
    }
    it
}

// MARK: Amazon, Product Advertising API 5, signed with AWS Signature Version 4

type HmacSha256 = Hmac<Sha256>;

fn hmac(key: &[u8], data: &str) -> Vec<u8> {
    let mut m = HmacSha256::new_from_slice(key).expect("HMAC takes any key length");
    m.update(data.as_bytes());
    m.finalize().into_bytes().to_vec()
}

fn sha_hex(data: &str) -> String {
    hex::encode(Sha256::digest(data.as_bytes()))
}

/// `YYYYMMDDTHHMMSSZ` for `secs` since 1970 (UTC).
fn amz_date(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}{m:02}{d:02}T{:02}{:02}{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

pub struct Sig<'a> {
    pub host: &'a str,
    pub path: &'a str,
    pub body: &'a str,
    pub target: &'a str,
    pub access: &'a str,
    pub secret: &'a str,
    pub region: &'a str,
    pub service: &'a str,
    /// Seconds since 1970; the tests pass a fixed instant.
    pub now: u64,
}

/// The SigV4 headers of one POST, `Authorization` included.
pub fn sigv4(o: &Sig) -> Vec<(String, String)> {
    let date = amz_date(o.now);
    let day = &date[..8];
    let mut headers = vec![
        ("content-encoding", "amz-1.0".to_string()),
        ("content-type", "application/json; charset=utf-8".to_string()),
        ("host", o.host.to_string()),
        ("x-amz-date", date.clone()),
        ("x-amz-target", o.target.to_string()),
    ];
    headers.sort_by_key(|h| h.0);
    let names = headers.iter().map(|h| h.0).collect::<Vec<_>>().join(";");
    let canonical_headers: String = headers.iter().map(|(k, v)| format!("{k}:{v}\n")).collect();
    let canonical = format!("POST\n{}\n\n{canonical_headers}\n{names}\n{}", o.path, sha_hex(o.body));
    let scope = format!("{day}/{}/{}/aws4_request", o.region, o.service);
    let to_sign = format!("AWS4-HMAC-SHA256\n{date}\n{scope}\n{}", sha_hex(&canonical));
    let key = hmac(&hmac(&hmac(&hmac(format!("AWS4{}", o.secret).as_bytes(), day), o.region), o.service), "aws4_request");
    let signature = hex::encode(hmac(&key, &to_sign));
    let mut out: Vec<(String, String)> = headers.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
    out.push(("Authorization".into(), format!("AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={names}, Signature={signature}", o.access)));
    out
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// The PA-API host and region of each marketplace the user may pick.
fn amazon_market(m: &str) -> (&'static str, &'static str, &'static str) {
    match m {
        "www.amazon.ca" => ("www.amazon.ca", "webservices.amazon.ca", "us-east-1"),
        "www.amazon.co.uk" => ("www.amazon.co.uk", "webservices.amazon.co.uk", "eu-west-1"),
        "www.amazon.fr" => ("www.amazon.fr", "webservices.amazon.fr", "eu-west-1"),
        "www.amazon.de" => ("www.amazon.de", "webservices.amazon.de", "eu-west-1"),
        "www.amazon.co.jp" => ("www.amazon.co.jp", "webservices.amazon.co.jp", "us-west-2"),
        _ => ("www.amazon.com", "webservices.amazon.com", "us-east-1"),
    }
}

pub fn amazon(http: &dyn Http, keys: &Keys, q: &str, at: Option<u64>) -> Result<Found, String> {
    need(keys, &["access_key", "secret_key", "partner_tag"], "Amazon")?;
    let (market, host, region) = amazon_market(k(keys, "marketplace"));
    let body = json!({
        "Keywords": q, "PartnerTag": k(keys, "partner_tag"), "PartnerType": "Associates", "Marketplace": market, "ItemCount": 10,
        "Resources": ["ItemInfo.Title", "ItemInfo.ByLineInfo", "ItemInfo.Classifications", "Offers.Listings.Price", "Offers.Listings.Availability.Message"],
    })
    .to_string();
    let headers = sigv4(&Sig {
        host, path: "/paapi5/searchitems", body: &body, target: "com.amazon.paapi5.v1.ProductAdvertisingAPIv1.SearchItems",
        access: k(keys, "access_key"), secret: k(keys, "secret_key"), region, service: "ProductAdvertisingAPI", now: at.unwrap_or_else(now),
    });
    let j = call(http, Request { method: "POST", url: format!("https://{host}/paapi5/searchitems"), headers, body: Some(body) }, "Amazon")?;
    if j.get("SearchResult").is_none() {
        if let Some(m) = s(&j, "/Errors/0/Message") {
            return Err(format!("Amazon: {m}"));
        }
    }
    let items = j.pointer("/SearchResult/Items").and_then(Value::as_array).into_iter().flatten().map(amazon_item).collect();
    Ok((items, j.pointer("/SearchResult/TotalResultCount").and_then(Value::as_u64).unwrap_or(0) as usize))
}

pub fn amazon_item(p: &Value) -> Item {
    let asin = s(p, "/ASIN").unwrap_or_default();
    let offer = &p["Offers"]["Listings"][0];
    let mut it = Item::new("amazon", asin.clone(), s(p, "/ItemInfo/Title/DisplayValue").unwrap_or(asin), Domain::Both);
    it.manufacturer = s(p, "/ItemInfo/ByLineInfo/Brand/DisplayValue").or(s(p, "/ItemInfo/ByLineInfo/Manufacturer/DisplayValue"));
    it.category = s(p, "/ItemInfo/Classifications/ProductGroup/DisplayValue");
    it.description = s(offer, "/Availability/Message");
    it.url = s(p, "/DetailPageURL");
    if let Some(price) = offer.pointer("/Price/Amount").and_then(num) {
        it.prices.push(PriceBreak { quantity: 1.0, price, currency: s(offer, "/Price/Currency").unwrap_or("USD".into()) });
    }
    it
}

// MARK: AliExpress, affiliate API, signed with HMAC-SHA256

/// The Open Platform signature: HMAC-SHA256 of the sorted name+value pairs, upper-case hex.
pub fn ali_sign(params: &[(String, String)], secret: &str) -> String {
    let mut p = params.to_vec();
    p.sort();
    let text: String = p.iter().map(|(k, v)| format!("{k}{v}")).collect();
    hex::encode_upper(hmac(secret.as_bytes(), &text))
}

pub fn aliexpress(http: &dyn Http, keys: &Keys, q: &str, at: Option<u64>) -> Result<Found, String> {
    need(keys, &["app_key", "app_secret"], "AliExpress")?;
    let currency = if k(keys, "currency").is_empty() { "USD" } else { k(keys, "currency") };
    let mut params: Vec<(String, String)> = [
        ("method", "aliexpress.affiliate.product.query"), ("app_key", k(keys, "app_key")), ("sign_method", "sha256"),
        ("format", "json"), ("v", "2.0"), ("keywords", q), ("page_size", "20"), ("target_currency", currency), ("target_language", "EN"),
    ]
    .iter()
    .map(|(a, b)| (a.to_string(), b.to_string()))
    .collect();
    params.push(("timestamp".into(), (at.unwrap_or_else(now) * 1000).to_string()));
    if !k(keys, "tracking_id").is_empty() {
        params.push(("tracking_id".into(), k(keys, "tracking_id").into()));
    }
    let sign = ali_sign(&params, k(keys, "app_secret"));
    params.push(("sign".into(), sign));
    let body = params.iter().map(|(a, b)| format!("{}={}", encode(a), encode(b))).collect::<Vec<_>>().join("&");
    let j = call(http, Request {
        method: "POST",
        url: "https://api-sg.aliexpress.com/sync".into(),
        headers: vec![("Content-Type".into(), "application/x-www-form-urlencoded;charset=utf-8".into())],
        body: Some(body),
    }, "AliExpress")?;
    if let Some(e) = j.get("error_response") {
        return Err(format!("AliExpress: {}", s(e, "/msg").or(s(e, "/code")).unwrap_or_default()));
    }
    let r = &j["aliexpress_affiliate_product_query_response"]["resp_result"];
    if let Some(code) = r["resp_code"].as_i64().filter(|c| *c != 200) {
        return Err(format!("AliExpress: {}", s(r, "/resp_msg").unwrap_or(code.to_string())));
    }
    let products: Vec<Item> = r.pointer("/result/products/product").and_then(Value::as_array).into_iter().flatten().map(ali_item).collect();
    let total = r.pointer("/result/total_record_count").and_then(Value::as_u64).map_or(products.len(), |t| t as usize);
    Ok((products, total))
}

pub fn ali_item(p: &Value) -> Item {
    let id = match &p["product_id"] { Value::Number(n) => n.to_string(), v => v.as_str().unwrap_or_default().to_string() };
    let mut it = Item::new("aliexpress", id.clone(), s(p, "/product_title").unwrap_or(id), Domain::Both);
    it.category = s(p, "/second_level_category_name").or(s(p, "/first_level_category_name"));
    it.description = s(p, "/shop_name").map(|x| format!("Shop: {x}"));
    it.url = s(p, "/promotion_link").or(s(p, "/product_detail_url"));
    if let Some(price) = p.get("target_sale_price").or(p.get("sale_price")).and_then(num) {
        let currency = s(p, "/target_sale_price_currency").or(s(p, "/sale_price_currency")).unwrap_or("USD".into());
        it.prices.push(PriceBreak { quantity: 1.0, price, currency });
    }
    it
}

// MARK: eBay, Browse API, application token

pub fn ebay(http: &dyn Http, keys: &Keys, q: &str) -> Result<Found, String> {
    need(keys, &["client_id", "client_secret"], "eBay")?;
    let basic = base64::engine::general_purpose::STANDARD.encode(format!("{}:{}", k(keys, "client_id"), k(keys, "client_secret")));
    let body = form(&[("grant_type", "client_credentials"), ("scope", "https://api.ebay.com/oauth/api_scope")]);
    let t = token(http, "https://api.ebay.com/identity/v1/oauth2/token", k(keys, "client_id"), || Request {
        method: "POST",
        url: "https://api.ebay.com/identity/v1/oauth2/token".into(),
        headers: vec![("Content-Type".into(), "application/x-www-form-urlencoded".into()), ("Authorization".into(), format!("Basic {basic}"))],
        body: Some(body),
    }, "eBay")?;
    let market = if k(keys, "marketplace").is_empty() { "EBAY_US" } else { k(keys, "marketplace") };
    let j = call(http, Request {
        method: "GET",
        url: format!("https://api.ebay.com/buy/browse/v1/item_summary/search?q={}&limit=20", encode(q)),
        headers: vec![("Authorization".into(), format!("Bearer {t}")), ("X-EBAY-C-MARKETPLACE-ID".into(), market.into())],
        body: None,
    }, "eBay")?;
    let items = j["itemSummaries"].as_array().into_iter().flatten().map(ebay_item).collect();
    Ok((items, j["total"].as_u64().unwrap_or(0) as usize))
}

pub fn ebay_item(p: &Value) -> Item {
    let id = s(p, "/legacyItemId").or(s(p, "/itemId")).unwrap_or_default();
    let mut it = Item::new("ebay", id.clone(), s(p, "/title").unwrap_or(id), Domain::Both);
    it.category = s(p, "/categories/0/categoryName");
    let d: Vec<String> = [s(p, "/condition"), s(p, "/seller/username").map(|u| format!("Seller: {u}"))].into_iter().flatten().collect();
    it.description = (!d.is_empty()).then(|| d.join(" · "));
    it.url = s(p, "/itemWebUrl");
    if let Some(price) = p.pointer("/price/value").and_then(num) {
        it.prices.push(PriceBreak { quantity: 1.0, price, currency: s(p, "/price/currency").unwrap_or("USD".into()) });
    }
    it
}
