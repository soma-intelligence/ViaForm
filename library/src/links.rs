//! A product link the user pastes, read for its shop and the shop's own product number. Nothing is
//! fetched: only the text of the link is read. Tracking parameters are dropped.

pub struct Link {
    pub source: &'static str,
    pub part_number: String,
    pub url: String,
}

fn after<'a>(path: &'a str, marker: &str) -> Option<&'a str> {
    path.find(marker).map(|i| &path[i + marker.len()..])
}

fn take(s: &str, ok: impl Fn(char) -> bool) -> String {
    s.chars().take_while(|c| ok(*c)).collect()
}

fn digits(s: &str, min: usize) -> Option<String> {
    let d = take(s, |c| c.is_ascii_digit());
    (d.len() >= min).then_some(d)
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(x) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(x);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn from_link(raw: &str) -> Option<Link> {
    let raw = raw.trim();
    let rest = raw.strip_prefix("https://").or_else(|| raw.strip_prefix("http://"))?;
    let scheme = if raw.starts_with("https://") { "https" } else { "http" };
    let (authority, tail) = rest.split_once('/').map_or((rest, ""), |(a, t)| (a, t));
    let host_full = authority.rsplit('@').next()?.split(':').next()?.to_lowercase();
    if host_full.is_empty() {
        return None;
    }
    let host = host_full.strip_prefix("www.").unwrap_or(&host_full).to_string();
    let (path_raw, query) = tail.split_once('?').map_or((tail.split('#').next().unwrap_or(""), ""), |(p, q)| (p, q.split('#').next().unwrap_or("")));
    let path = format!("/{}", percent_decode(path_raw));
    let clean = format!("{scheme}://{host_full}/{path_raw}");
    let param = |name: &str| query.split('&').find_map(|kv| kv.strip_prefix(&format!("{name}=")).map(String::from));
    let is = |domain: &str| host == domain || host.ends_with(&format!(".{domain}"));
    let tld = |brand: &str| host.split('.').any(|p| p == brand);

    let (source, part): (&'static str, Option<String>) = if tld("amazon") || host == "a.co" || host == "amzn.to" {
        let asin = ["/dp/", "/gp/product/", "/gp/aw/d/", "/product/"].iter().find_map(|m| after(&path, m)).map(|s| take(s, |c| c.is_ascii_alphanumeric())).filter(|s| s.len() == 10).map(|s| s.to_uppercase());
        ("amazon", asin)
    } else if tld("aliexpress") {
        ("aliexpress", after(&path, "/item/").and_then(|s| digits(s, 6)))
    } else if is("alibaba.com") {
        let id = path.trim_end_matches(".html").rsplit(['_', '/']).next().and_then(|s| digits(s, 6));
        ("alibaba", id)
    } else if tld("ebay") {
        let tail = after(&path, "/itm/").unwrap_or("");
        let id = tail.split('/').find_map(|seg| digits(seg, 9).filter(|d| d.len() == seg.len()));
        ("ebay", id)
    } else if is("temu.com") {
        ("temu", after(&path, "-g-").and_then(|s| digits(s, 6)).or(param("goods_id")))
    } else if is("mcmaster.com") {
        let seg = take(path.trim_start_matches('/'), |c| c.is_ascii_alphanumeric()).to_uppercase();
        let ok = seg.len() >= 6 && seg.chars().any(|c| c.is_ascii_alphabetic()) && seg.chars().next().is_some_and(|c| c.is_ascii_digit());
        ("mcmaster", ok.then_some(seg))
    } else if tld("digikey") {
        let pn = after(&path, "/detail/").and_then(|s| s.split('/').nth(1)).map(String::from);
        ("digikey", pn)
    } else if tld("mouser") {
        let pn = after(&path, "/ProductDetail/").map(|s| s.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string());
        ("mouser", pn)
    } else if is("misumi-ec.com") {
        ("misumi", after(&path, "/detail/").map(|s| take(s, |c| c != '/')))
    } else if is("lcsc.com") {
        let c = path.find('C').map(|i| &path[i..]).and_then(|s| {
            let d = take(&s[1..], |c| c.is_ascii_digit());
            (d.len() >= 3).then(|| format!("C{d}"))
        });
        ("lcsc", c)
    } else {
        return Some(Link { source: "custom", part_number: String::new(), url: clean });
    };
    let part_number = part.filter(|p| !p.is_empty()).unwrap_or_default();
    let url = if source == "amazon" && !part_number.is_empty() { format!("{scheme}://{host_full}/dp/{part_number}") } else { clean };
    Some(Link { source, part_number, url })
}
