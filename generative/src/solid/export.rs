//! Writing a surface: binary STL, OBJ, and 3MF (a stored zip written here, no dependency).
//!
//! Triangles that name a missing or repeated vertex are left out of every format.

use std::fmt::Write as _;

use rayon::prelude::*;

use super::Mesh;

/// Vertices or triangles formatted per parallel task.
const CHUNK: usize = 16_384;

/// Binary STL: an 80-byte header holding `name`, the triangle count, then per triangle its unit
/// normal (zero when it has no area), its corners and a zero attribute: `84 + 50 n` bytes.
pub fn stl(mesh: &Mesh, name: &str) -> Vec<u8> {
    let mut tris = triangles(mesh);
    tris.truncate(u32::MAX as usize);
    let mut out = vec![0u8; 84 + 50 * tris.len()];
    out[..80].copy_from_slice(&stl_header(name));
    out[80..84].copy_from_slice(&(tris.len() as u32).to_le_bytes());
    out[84..].par_chunks_mut(50).zip(tris.par_iter()).for_each(|(rec, t)| {
        let [a, b, c] = t.map(|i| vertex(mesh, i));
        let n = normal(a, b, c);
        for (k, x) in n.iter().chain(&a).chain(&b).chain(&c).enumerate() {
            rec[4 * k..4 * k + 4].copy_from_slice(&x.to_le_bytes());
        }
    });
    out
}

/// The header: `name`, cut to 80 bytes on a character boundary and padded with spaces. A name
/// starting with `solid` gets a prefix, so no reader takes the file for ASCII STL.
fn stl_header(name: &str) -> [u8; 80] {
    let mut text = String::new();
    if name.trim_start().get(..5).is_some_and(|s| s.eq_ignore_ascii_case("solid")) {
        text.push_str("binary STL ");
    }
    text.push_str(name);
    let mut end = text.len().min(80);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let mut h = [b' '; 80];
    h[..end].copy_from_slice(&text.as_bytes()[..end]);
    h
}

/// Wavefront OBJ: `v x y z` per vertex, then `f a b c` per triangle, numbered from 1.
pub fn obj(mesh: &Mesh) -> String {
    let nv = mesh.positions.len() / 3;
    let tris = triangles(mesh);
    let mut out = format!("# ViaForm surface: {nv} vertices, {} triangles\n", tris.len());
    let vs: Vec<String> = mesh.positions[..3 * nv]
        .par_chunks(3 * CHUNK)
        .map(|c| {
            let mut s = String::with_capacity(c.len() * 12);
            for p in c.as_chunks::<3>().0 {
                let _ = writeln!(s, "v {} {} {}", p[0], p[1], p[2]);
            }
            s
        })
        .collect();
    let fs: Vec<String> = tris
        .par_chunks(CHUNK)
        .map(|c| {
            let mut s = String::with_capacity(c.len() * 24);
            for t in c {
                let _ = writeln!(s, "f {} {} {}", u64::from(t[0]) + 1, u64::from(t[1]) + 1, u64::from(t[2]) + 1);
            }
            s
        })
        .collect();
    out.reserve(vs.iter().chain(&fs).map(String::len).sum());
    for s in vs.iter().chain(&fs) {
        out.push_str(s);
    }
    out
}

/// 3MF: a zip of stored (uncompressed) parts: the content types, the package relationships and
/// `3D/3dmodel.model`, one mesh object named `name` built once, in millimetres. Empty when the
/// model passes 4 GiB (no zip64).
pub fn three_mf(mesh: &Mesh, name: &str) -> Vec<u8> {
    let model = model_xml(mesh, name);
    let parts: [(&str, &[u8]); 3] =
        [("[Content_Types].xml", CONTENT_TYPES.as_bytes()), ("_rels/.rels", RELS.as_bytes()), ("3D/3dmodel.model", model.as_bytes())];
    zip_stored(&parts).unwrap_or_default()
}

const CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n \
<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n \
<Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>\n\
</Types>\n";

const RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n \
<Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>\n\
</Relationships>\n";

fn model_xml(mesh: &Mesh, name: &str) -> String {
    let nv = mesh.positions.len() / 3;
    let tris = triangles(mesh);
    let vs: Vec<String> = mesh.positions[..3 * nv]
        .par_chunks(3 * CHUNK)
        .map(|c| {
            let mut s = String::with_capacity(c.len() * 16);
            for p in c.as_chunks::<3>().0 {
                let _ = writeln!(s, "     <vertex x=\"{}\" y=\"{}\" z=\"{}\"/>", p[0], p[1], p[2]);
            }
            s
        })
        .collect();
    let ts: Vec<String> = tris
        .par_chunks(CHUNK)
        .map(|c| {
            let mut s = String::with_capacity(c.len() * 48);
            for t in c {
                let _ = writeln!(s, "     <triangle v1=\"{}\" v2=\"{}\" v3=\"{}\"/>", t[0], t[1], t[2]);
            }
            s
        })
        .collect();
    let mut x = String::with_capacity(512 + vs.iter().chain(&ts).map(String::len).sum::<usize>());
    x.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    x.push_str("<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n");
    x.push_str(" <metadata name=\"Application\">ViaForm</metadata>\n");
    let _ = writeln!(x, " <metadata name=\"Title\">{}</metadata>", esc(name));
    x.push_str(" <resources>\n");
    let _ = writeln!(x, "  <object id=\"1\" type=\"model\" name=\"{}\">", esc(name));
    x.push_str("   <mesh>\n    <vertices>\n");
    vs.iter().for_each(|s| x.push_str(s));
    x.push_str("    </vertices>\n    <triangles>\n");
    ts.iter().for_each(|s| x.push_str(s));
    x.push_str("    </triangles>\n   </mesh>\n  </object>\n </resources>\n");
    x.push_str(" <build>\n  <item objectid=\"1\"/>\n </build>\n</model>\n");
    x
}

/// `s` as XML text or attribute: markup escaped, characters XML 1.0 forbids dropped.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\t' | '\n' | '\r' => out.push(c),
            c if c < ' ' || c == '\u{FFFE}' || c == '\u{FFFF}' => {}
            c => out.push(c),
        }
    }
    out
}

/// The triangles that name three distinct vertices of the mesh.
fn triangles(mesh: &Mesh) -> Vec<[u32; 3]> {
    let nv = (mesh.positions.len() / 3) as u64;
    mesh.indices
        .par_chunks_exact(3)
        .filter_map(|t| {
            let t = [t[0], t[1], t[2]];
            let ok = t.iter().all(|&i| u64::from(i) < nv) && t[0] != t[1] && t[1] != t[2] && t[2] != t[0];
            ok.then_some(t)
        })
        .collect()
}

fn vertex(mesh: &Mesh, i: u32) -> [f32; 3] {
    let i = 3 * i as usize;
    [mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2]]
}

/// Unit normal of `a b c` by the right hand; zero when it has no area.
fn normal(a: [f32; 3], b: [f32; 3], c: [f32; 3]) -> [f32; 3] {
    let d = |p: [f32; 3]| [0, 1, 2].map(|k| f64::from(p[k]) - f64::from(a[k]));
    let (u, v) = (d(b), d(c));
    let n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    let l = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt();
    if l > 0.0 && l.is_finite() { n.map(|x| (x / l) as f32) } else { [0.0; 3] }
}

// ---------------------------------------------------------------- zip

/// Version needed to extract: 2.0.
const ZIP_VERSION: u16 = 20;
/// 1980-01-01 00:00 in DOS form, so the same mesh gives the same bytes.
const DOS_DATE: u16 = (1 << 5) | 1;
const DOS_TIME: u16 = 0;

/// A zip of `parts` (name, data), stored; `None` past the classic format's limits.
fn zip_stored(parts: &[(&str, &[u8])]) -> Option<Vec<u8>> {
    let total: usize = parts.iter().map(|(n, d)| 30 + 46 + 2 * n.len() + d.len()).sum::<usize>() + 22;
    if parts.len() > usize::from(u16::MAX) || total > u32::MAX as usize {
        return None;
    }
    let crcs: Vec<u32> = parts.par_iter().map(|(_, d)| crc32(d)).collect();
    let mut out = Vec::with_capacity(total);
    let mut offsets = Vec::with_capacity(parts.len());
    for ((name, data), &crc) in parts.iter().zip(&crcs) {
        offsets.push(out.len() as u32);
        put32(&mut out, 0x0403_4b50);
        put16(&mut out, ZIP_VERSION);
        put16(&mut out, 0); // flags
        put16(&mut out, 0); // stored
        put16(&mut out, DOS_TIME);
        put16(&mut out, DOS_DATE);
        put32(&mut out, crc);
        put32(&mut out, data.len() as u32);
        put32(&mut out, data.len() as u32);
        put16(&mut out, name.len() as u16);
        put16(&mut out, 0); // extra
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(data);
    }
    let directory = out.len() as u32;
    for (((name, data), &crc), &offset) in parts.iter().zip(&crcs).zip(&offsets) {
        put32(&mut out, 0x0201_4b50);
        put16(&mut out, ZIP_VERSION); // made by: MS-DOS, 2.0
        put16(&mut out, ZIP_VERSION);
        put16(&mut out, 0); // flags
        put16(&mut out, 0); // stored
        put16(&mut out, DOS_TIME);
        put16(&mut out, DOS_DATE);
        put32(&mut out, crc);
        put32(&mut out, data.len() as u32);
        put32(&mut out, data.len() as u32);
        put16(&mut out, name.len() as u16);
        put16(&mut out, 0); // extra
        put16(&mut out, 0); // comment
        put16(&mut out, 0); // disk
        put16(&mut out, 0); // internal attributes
        put32(&mut out, 0); // external attributes
        put32(&mut out, offset);
        out.extend_from_slice(name.as_bytes());
    }
    let size = out.len() as u32 - directory;
    put32(&mut out, 0x0605_4b50);
    put16(&mut out, 0); // this disk
    put16(&mut out, 0); // directory's disk
    put16(&mut out, parts.len() as u16);
    put16(&mut out, parts.len() as u16);
    put32(&mut out, size);
    put32(&mut out, directory);
    put16(&mut out, 0); // comment
    Some(out)
}

fn put16(out: &mut Vec<u8>, x: u16) {
    out.extend_from_slice(&x.to_le_bytes());
}

fn put32(out: &mut Vec<u8>, x: u32) {
    out.extend_from_slice(&x.to_le_bytes());
}

/// CRC-32 tables (reflected polynomial 0xEDB88320) for eight bytes at a time.
const CRC_TABLES: [[u32; 256]; 8] = {
    let mut t = [[0u32; 256]; 8];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            k += 1;
        }
        t[0][i] = c;
        i += 1;
    }
    let mut i = 0;
    while i < 256 {
        let mut s = 1;
        while s < 8 {
            t[s][i] = (t[s - 1][i] >> 8) ^ t[0][(t[s - 1][i] & 0xFF) as usize];
            s += 1;
        }
        i += 1;
    }
    t
};

/// The zip (IEEE 802.3) CRC-32 of `data`.
fn crc32(data: &[u8]) -> u32 {
    let t = &CRC_TABLES;
    let mut c = !0u32;
    let (chunks, rest) = data.as_chunks::<8>();
    for b in chunks {
        let lo = c ^ u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
        let hi = u32::from_le_bytes([b[4], b[5], b[6], b[7]]);
        c = t[7][(lo & 0xFF) as usize]
            ^ t[6][((lo >> 8) & 0xFF) as usize]
            ^ t[5][((lo >> 16) & 0xFF) as usize]
            ^ t[4][(lo >> 24) as usize]
            ^ t[3][(hi & 0xFF) as usize]
            ^ t[2][((hi >> 8) & 0xFF) as usize]
            ^ t[1][((hi >> 16) & 0xFF) as usize]
            ^ t[0][(hi >> 24) as usize];
    }
    for &b in rest {
        c = t[0][((c ^ u32::from(b)) & 0xFF) as usize] ^ (c >> 8);
    }
    !c
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A unit tetrahedron, outward-facing.
    fn tetra() -> Mesh {
        Mesh {
            positions: vec![0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            indices: vec![0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3],
            stress: Vec::new(),
        }
    }

    fn u16_at(b: &[u8], at: usize) -> usize {
        u16::from_le_bytes([b[at], b[at + 1]]) as usize
    }

    fn u32_at(b: &[u8], at: usize) -> usize {
        u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]) as usize
    }

    /// Reads a stored zip back through its central directory, checking every header against
    /// its local one and every CRC against the data: (name, data) per entry.
    pub(crate) fn unzip(z: &[u8]) -> Vec<(String, Vec<u8>)> {
        let end = z.len() - 22;
        assert_eq!(u32_at(z, end), 0x0605_4b50);
        let (count, size, mut at) = (u16_at(z, end + 10), u32_at(z, end + 12), u32_at(z, end + 16));
        assert_eq!(at + size, end);
        let mut out = Vec::new();
        for _ in 0..count {
            assert_eq!(u32_at(z, at), 0x0201_4b50);
            assert_eq!(u16_at(z, at + 10), 0, "stored");
            let (crc, csize, usize_) = (u32_at(z, at + 16), u32_at(z, at + 20), u32_at(z, at + 24));
            let (nlen, xlen, clen) = (u16_at(z, at + 28), u16_at(z, at + 30), u16_at(z, at + 32));
            let local = u32_at(z, at + 42);
            let name = String::from_utf8(z[at + 46..at + 46 + nlen].to_vec()).unwrap();
            assert_eq!(csize, usize_);
            assert_eq!(u32_at(z, local), 0x0403_4b50);
            assert_eq!(u32_at(z, local + 14), crc);
            assert_eq!(u32_at(z, local + 18), csize);
            assert_eq!(&z[local + 30..local + 30 + nlen], name.as_bytes());
            let data = &z[local + 30 + nlen + u16_at(z, local + 28)..][..csize];
            assert_eq!(crc32(data) as usize, crc, "{name}");
            out.push((name, data.to_vec()));
            at += 46 + nlen + xlen + clen;
        }
        out
    }

    #[test]
    fn crc_matches_the_check_value_and_the_bytewise_form() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b""), 0);
        let data: Vec<u8> = (0..1000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
        for n in [0, 1, 7, 8, 9, 63, 1000] {
            let mut c = !0u32;
            for &b in &data[..n] {
                c ^= u32::from(b);
                for _ in 0..8 {
                    c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
                }
            }
            assert_eq!(crc32(&data[..n]), !c, "{n} bytes");
        }
    }

    #[test]
    fn stl_is_84_plus_50_per_triangle() {
        let m = tetra();
        let b = stl(&m, "Bracket");
        assert_eq!(b.len(), 84 + 50 * 4);
        assert!(b.starts_with(b"Bracket "));
        assert_eq!(u32_at(&b, 80), 4);
        // The slanted face's normal, and its first corner.
        let f = |at: usize| f32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]);
        let r = 84 + 50 * 3;
        let s = 1.0 / 3f32.sqrt();
        for k in 0..3 {
            assert!((f(r + 4 * k) - s).abs() < 1e-6);
        }
        assert_eq!([f(r + 12), f(r + 16), f(r + 20)], [1.0, 0.0, 0.0]);
        assert_eq!(u16_at(&b, r + 48), 0);
        assert!(stl(&m, "solid part").starts_with(b"binary STL solid part"));
        assert_eq!(stl(&m, &"é".repeat(60)).len(), 284);
        // Bad triangles are left out, and an empty mesh is a valid empty file.
        let bad = Mesh { indices: vec![0, 1, 9, 0, 0, 1, 0, 2, 1], ..m.clone() };
        assert_eq!(stl(&bad, "x").len(), 84 + 50);
        assert_eq!(stl(&Mesh::default(), "x").len(), 84);
    }

    #[test]
    fn obj_counts_from_one() {
        let o = obj(&tetra());
        let v: Vec<&str> = o.lines().filter(|l| l.starts_with("v ")).collect();
        let f: Vec<&str> = o.lines().filter(|l| l.starts_with("f ")).collect();
        assert_eq!(v.len(), 4);
        assert_eq!(v[1], "v 1 0 0");
        assert_eq!(f, ["f 1 3 2", "f 1 2 4", "f 1 4 3", "f 2 3 4"]);
    }

    #[test]
    fn three_mf_is_a_stored_zip_of_the_three_parts() {
        let m = tetra();
        let z = three_mf(&m, "Bracket <A&B>");
        let parts = unzip(&z);
        let names: Vec<&str> = parts.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"]);
        let model = String::from_utf8(parts[2].1.clone()).unwrap();
        assert!(model.contains("unit=\"millimeter\""));
        assert!(model.contains("<object id=\"1\" type=\"model\" name=\"Bracket &lt;A&amp;B&gt;\">"));
        assert_eq!(model.matches("<vertex ").count(), 4);
        assert_eq!(model.matches("<triangle ").count(), 4);
        assert!(model.contains("<triangle v1=\"1\" v2=\"2\" v3=\"3\"/>"));
        assert!(model.contains("<item objectid=\"1\"/>"));
        // The same mesh, the same bytes.
        assert_eq!(three_mf(&m, "Bracket <A&B>"), z);
        // The system's unzip agrees, where there is one.
        let dir = std::env::temp_dir().join(format!("viaform-3mf-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.3mf");
        std::fs::write(&path, &z).unwrap();
        if let Ok(out) = std::process::Command::new("unzip").arg("-t").arg(&path).output() {
            assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stdout));
            assert!(String::from_utf8_lossy(&out.stdout).contains("No errors detected"));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn names_are_escaped() {
        assert_eq!(esc("a\"b'c\u{1}d\te"), "a&quot;b&apos;cd\te");
    }
}
