//! A small s-expression reader and writer for the KiCad file formats (public format docs).

use crate::error::{EngineError, Result};

#[derive(Clone, Debug, PartialEq)]
pub enum Sx {
    List(Vec<Sx>),
    Atom(String),
    Str(String),
}

impl Sx {
    /// The head symbol of a list: `(pad ...)` gives "pad".
    pub fn head(&self) -> Option<&str> {
        match self {
            Sx::List(v) => v.first().and_then(|h| h.text()),
            _ => None,
        }
    }
    pub fn text(&self) -> Option<&str> {
        match self {
            Sx::Atom(s) | Sx::Str(s) => Some(s),
            Sx::List(_) => None,
        }
    }
    pub fn items(&self) -> &[Sx] {
        match self {
            Sx::List(v) => v,
            _ => &[],
        }
    }
    /// The n-th element (0 is the head).
    pub fn at(&self, n: usize) -> Option<&Sx> {
        self.items().get(n)
    }
    pub fn num(&self, n: usize) -> Option<f64> {
        self.at(n)?.text()?.parse().ok()
    }
    pub fn str_at(&self, n: usize) -> Option<&str> {
        self.at(n)?.text()
    }
    /// First child list with this head.
    pub fn child(&self, head: &str) -> Option<&Sx> {
        self.items().iter().find(|c| c.head() == Some(head))
    }
    pub fn children<'a>(&'a self, head: &'a str) -> impl Iterator<Item = &'a Sx> + 'a {
        self.items().iter().filter(move |c| c.head() == Some(head))
    }
}

pub fn parse(src: &str) -> Result<Sx> {
    let b = src.as_bytes();
    let mut i = 0;
    let mut stack: Vec<Vec<Sx>> = vec![vec![]];
    while i < b.len() {
        let c = b[i];
        match c {
            b'(' => {
                stack.push(vec![]);
                i += 1;
            }
            b')' => {
                let l = stack.pop().ok_or_else(|| EngineError::new("parse", "unbalanced )"))?;
                stack.last_mut().ok_or_else(|| EngineError::new("parse", "unbalanced )"))?.push(Sx::List(l));
                i += 1;
            }
            b'"' => {
                i += 1;
                let mut s = Vec::new();
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' && i + 1 < b.len() {
                        i += 1;
                        s.push(match b[i] {
                            b'n' => b'\n',
                            b't' => b'\t',
                            o => o,
                        });
                    } else {
                        s.push(b[i]);
                    }
                    i += 1;
                }
                if i >= b.len() {
                    return Err(EngineError::new("parse", "unterminated string"));
                }
                i += 1;
                stack.last_mut().unwrap().push(Sx::Str(String::from_utf8_lossy(&s).into_owned()));
            }
            c if c.is_ascii_whitespace() => i += 1,
            _ => {
                let st = i;
                while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'(' && b[i] != b')' {
                    i += 1;
                }
                stack.last_mut().unwrap().push(Sx::Atom(String::from_utf8_lossy(&b[st..i]).into_owned()));
            }
        }
        if stack.is_empty() {
            return Err(EngineError::new("parse", "unbalanced )"));
        }
    }
    if stack.len() != 1 {
        return Err(EngineError::new("parse", "unbalanced ("));
    }
    let mut top = stack.pop().unwrap();
    if top.len() != 1 {
        return Err(EngineError::new("parse", "expected one top-level list"));
    }
    Ok(top.remove(0))
}

/// Quotes a string for a KiCad file.
pub fn q(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// Millimetres from nanometres, trimmed (KiCad writes up to 6 decimals).
pub fn n(v: i64) -> String {
    let neg = v < 0;
    let a = v.unsigned_abs();
    let (int, frac) = (a / 1_000_000, a % 1_000_000);
    let mut s = if frac == 0 { format!("{int}") } else { format!("{int}.{frac:06}").trim_end_matches('0').to_string() };
    if neg && s != "0" {
        s.insert(0, '-');
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nested() {
        let s = parse(r#"(a (b 1 2.5) (c "x \"y\"") d)"#).unwrap();
        assert_eq!(s.head(), Some("a"));
        assert_eq!(s.child("b").unwrap().num(2), Some(2.5));
        assert_eq!(s.child("c").unwrap().str_at(1), Some("x \"y\""));
        assert!(parse("(a").is_err());
    }

    #[test]
    fn number_format() {
        assert_eq!(n(2_540_000), "2.54");
        assert_eq!(n(-500_000), "-0.5");
        assert_eq!(n(0), "0");
        assert_eq!(n(30_000_000), "30");
    }
}
