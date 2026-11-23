//! A small XML tree, writer and parser: enough for URDF and MJCF (elements, attributes, text,
//! comments, the XML declaration and the five predefined entities). The parser refuses text
//! that is not well formed (unclosed or mismatched tags, a duplicate attribute, stray `<`).

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Element {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Element>,
    pub text: String,
}

impl Element {
    pub fn new(name: &str) -> Self {
        Self { name: name.into(), ..Self::default() }
    }

    pub fn attr(mut self, k: &str, v: impl Into<String>) -> Self {
        self.attrs.push((k.into(), v.into()));
        self
    }

    pub fn child(mut self, c: Element) -> Self {
        self.children.push(c);
        self
    }

    pub fn text(mut self, t: impl Into<String>) -> Self {
        self.text = t.into();
        self
    }

    pub fn push(&mut self, c: Element) {
        self.children.push(c);
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.attrs.iter().find(|(a, _)| a == k).map(|(_, v)| v.as_str())
    }

    pub fn first(&self, name: &str) -> Option<&Element> {
        self.children.iter().find(|c| c.name == name)
    }

    pub fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Element> + 'a {
        self.children.iter().filter(move |c| c.name == name)
    }

    /// Every element below this one, depth first.
    pub fn descendants(&self) -> Vec<&Element> {
        let mut out = Vec::new();
        let mut stack: Vec<&Element> = self.children.iter().rev().collect();
        while let Some(e) = stack.pop() {
            out.push(e);
            stack.extend(e.children.iter().rev());
        }
        out
    }

    pub fn to_string_pretty(&self) -> String {
        let mut s = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        self.write(&mut s, 0);
        s
    }

    fn write(&self, s: &mut String, depth: usize) {
        let pad = "  ".repeat(depth);
        s.push_str(&pad);
        s.push('<');
        s.push_str(&self.name);
        for (k, v) in &self.attrs {
            s.push_str(&format!(" {k}=\"{}\"", escape(v)));
        }
        if self.children.is_empty() && self.text.is_empty() {
            s.push_str("/>\n");
            return;
        }
        s.push('>');
        if self.children.is_empty() {
            s.push_str(&escape(&self.text));
        } else {
            s.push('\n');
            for c in &self.children {
                c.write(s, depth + 1);
            }
            s.push_str(&pad);
        }
        s.push_str(&format!("</{}>\n", self.name));
    }
}

pub fn escape(v: &str) -> String {
    v.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

fn unescape(v: &str) -> Result<String, String> {
    let mut out = String::with_capacity(v.len());
    let mut rest = v;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let end = rest[i..].find(';').ok_or("an & without its ;")? + i;
        let ent = &rest[i + 1..end];
        match ent {
            "amp" => out.push('&'),
            "lt" => out.push('<'),
            "gt" => out.push('>'),
            "quot" => out.push('"'),
            "apos" => out.push('\''),
            _ if ent.starts_with("#x") => out.push(u32::from_str_radix(&ent[2..], 16).ok().and_then(char::from_u32).ok_or("bad character reference")?),
            _ if ent.starts_with('#') => out.push(ent[1..].parse::<u32>().ok().and_then(char::from_u32).ok_or("bad character reference")?),
            _ => return Err(format!("unknown entity &{ent};")),
        }
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

struct Parser<'a> {
    s: &'a str,
    i: usize,
}

impl<'a> Parser<'a> {
    fn rest(&self) -> &'a str {
        &self.s[self.i..]
    }

    fn line(&self) -> usize {
        self.s[..self.i].matches('\n').count() + 1
    }

    fn err(&self, m: &str) -> String {
        format!("XML line {}: {m}", self.line())
    }

    fn skip_ws(&mut self) {
        let r = self.rest();
        self.i += r.len() - r.trim_start().len();
    }

    /// Skips comments, processing instructions and a doctype.
    fn skip_misc(&mut self) -> Result<(), String> {
        loop {
            self.skip_ws();
            let r = self.rest();
            let close = if r.starts_with("<!--") {
                "-->"
            } else if r.starts_with("<?") {
                "?>"
            } else if r.starts_with("<!DOCTYPE") {
                ">"
            } else {
                return Ok(());
            };
            let end = r.find(close).ok_or_else(|| self.err("unclosed comment or declaration"))?;
            self.i += end + close.len();
        }
    }

    fn name(&mut self) -> Result<String, String> {
        let r = self.rest();
        let n = r.find(|c: char| !(c.is_alphanumeric() || matches!(c, '_' | '-' | ':' | '.'))).unwrap_or(r.len());
        if n == 0 {
            return Err(self.err("expected a name"));
        }
        self.i += n;
        Ok(r[..n].to_owned())
    }

    fn element(&mut self) -> Result<Element, String> {
        if !self.rest().starts_with('<') {
            return Err(self.err("expected an element"));
        }
        self.i += 1;
        let mut e = Element::new(&self.name()?);
        loop {
            self.skip_ws();
            let r = self.rest();
            if r.starts_with("/>") {
                self.i += 2;
                return Ok(e);
            }
            if r.starts_with('>') {
                self.i += 1;
                break;
            }
            if r.is_empty() {
                return Err(self.err(&format!("<{}> is not closed", e.name)));
            }
            let k = self.name()?;
            self.skip_ws();
            if !self.rest().starts_with('=') {
                return Err(self.err(&format!("attribute {k} has no value")));
            }
            self.i += 1;
            self.skip_ws();
            let q = self.rest().chars().next().filter(|c| *c == '"' || *c == '\'').ok_or_else(|| self.err("attribute value must be quoted"))?;
            self.i += 1;
            let end = self.rest().find(q).ok_or_else(|| self.err("unclosed attribute value"))?;
            let raw = &self.rest()[..end];
            if raw.contains('<') {
                return Err(self.err("< inside an attribute value"));
            }
            let v = unescape(raw).map_err(|m| self.err(&m))?;
            self.i += end + 1;
            if e.get(&k).is_some() {
                return Err(self.err(&format!("attribute {k} is given twice")));
            }
            e.attrs.push((k, v));
        }
        loop {
            let r = self.rest();
            let lt = r.find('<').ok_or_else(|| self.err(&format!("<{}> is not closed", e.name)))?;
            let t = unescape(&r[..lt]).map_err(|m| self.err(&m))?;
            e.text.push_str(t.trim());
            self.i += lt;
            let r = self.rest();
            if r.starts_with("<!--") {
                let end = r.find("-->").ok_or_else(|| self.err("unclosed comment"))?;
                self.i += end + 3;
            } else if r.starts_with("</") {
                self.i += 2;
                let n = self.name()?;
                if n != e.name {
                    return Err(self.err(&format!("</{n}> closes <{}>", e.name)));
                }
                self.skip_ws();
                if !self.rest().starts_with('>') {
                    return Err(self.err("expected >"));
                }
                self.i += 1;
                return Ok(e);
            } else {
                let c = self.element()?;
                e.children.push(c);
            }
        }
    }
}

/// Parses a document with one root element.
pub fn parse(text: &str) -> Result<Element, String> {
    let mut p = Parser { s: text, i: 0 };
    p.skip_misc()?;
    let root = p.element()?;
    p.skip_misc()?;
    if !p.rest().trim().is_empty() {
        return Err(p.err("text after the root element"));
    }
    Ok(root)
}

/// `"1 2 3"` as numbers.
pub fn floats(v: &str) -> Result<Vec<f64>, String> {
    v.split_whitespace().map(|x| x.parse::<f64>().map_err(|_| format!("{x} is not a number"))).collect()
}

/// Shortest form that reads back to the same f64, with -0 written as 0.
pub fn num(x: f64) -> String {
    if x == 0.0 { "0".into() } else { format!("{x}") }
}

pub fn nums(xs: &[f64]) -> String {
    xs.iter().map(|x| num(*x)).collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_and_reads_back() {
        let e = Element::new("robot").attr("name", "a&b").child(Element::new("link").attr("name", "x")).child(Element::new("t").text("1 < 2"));
        let s = e.to_string_pretty();
        assert_eq!(parse(&s).unwrap(), e);
        assert!(parse("<a><b></a>").is_err());
        assert!(parse("<a x='1' x='2'/>").is_err());
        assert!(parse("<a>").is_err());
        assert!(parse("<a/><b/>").is_err());
        assert_eq!(parse("<!-- c --><a><!-- d --><b/></a>").unwrap().children.len(), 1);
    }
}
