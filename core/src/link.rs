//! The link between the electronics and the 3D design: the board becomes a component of the
//! design (board, copper, holes and simple part bodies), tagged with the PCB revision it was
//! built from. Updating rebuilds the bodies inside the same component, so its placement and the
//! joints that hold it in an assembly stay.

use serde::Deserialize;
use serde_json::{Value, json};

use pcbcraft_engine::Session as Pcb;
use solidcraft_engine::Session as Cad;

#[cfg(test)]
use crate::Workspace;

pub const TAG: &str = "Linked to ViaForm PCB";

#[derive(Deserialize, Clone, Copy)]
struct Pt {
    x: f64,
    y: f64,
}

impl Pt {
    fn rotated(self, degrees: f64) -> Pt {
        let (s, c) = degrees.to_radians().sin_cos();
        Pt { x: self.x * c - self.y * s, y: self.x * s + self.y * c }
    }
}

#[derive(Deserialize)]
struct Pad {
    offset: Pt,
    diameter: f64,
}

#[derive(Deserialize)]
struct Footprint {
    component: u64,
    position: Pt,
    rotation: f64,
    pads: Vec<Pad>,
}

impl Footprint {
    fn pad(&self, p: &Pad) -> Pt {
        let o = p.offset.rotated(self.rotation);
        Pt { x: self.position.x + o.x, y: self.position.y + o.y }
    }
}

#[derive(Deserialize)]
struct Track {
    start: Pt,
    end: Pt,
    width: f64,
    layer: String,
}

#[derive(Deserialize)]
struct Cutout {
    center: Pt,
    radius: f64,
}

#[derive(Deserialize)]
struct Board {
    width: f64,
    height: f64,
    cutouts: Vec<Cutout>,
    footprints: Vec<Footprint>,
    tracks: Vec<Track>,
}

#[derive(Deserialize)]
struct Part {
    id: u64,
    reference: String,
    kind: String,
}

#[derive(Deserialize)]
struct Project {
    name: Option<String>,
    components: Vec<Part>,
    board: Board,
}

fn project(pcb: &Pcb) -> Result<Project, String> {
    let v = pcb.inspect();
    serde_json::from_value(v.get("project").cloned().unwrap_or(Value::Null)).map_err(|e| format!("PCB project: {e}"))
}

/// The design component that holds the board.
pub fn component_name(name: Option<&str>) -> String {
    format!("PCB {}", name.filter(|n| !n.is_empty()).unwrap_or("Board"))
}

/// The PCB revision the design's board component was built from, if there is one.
pub fn linked_revision(cad: &mut Cad, pcb: &Pcb) -> Option<u64> {
    let p = project(pcb).ok()?;
    let r = cad.execute("component.metadata", &json!({"component": component_name(p.name.as_deref())})).ok()?;
    if r.get("description").and_then(Value::as_str) != Some(TAG) {
        return None;
    }
    r.get("revision")?.as_str()?.rsplit('-').next()?.parse().ok()
}

fn exec(cad: &mut Cad, id: &str, v: &Value) -> Result<Value, String> {
    cad.execute(id, v).map_err(|e| e.to_string())
}

fn revision(pcb: &Pcb) -> u64 {
    pcb.inspect().get("revision").and_then(Value::as_u64).unwrap_or(0)
}

fn components(cad: &mut Cad) -> Result<Vec<Value>, String> {
    let list = exec(cad, "component.list", &json!({}))?;
    Ok(list.get("components").and_then(Value::as_array).cloned().unwrap_or_default())
}

fn named<'a>(comps: &'a [Value], name: &str) -> Option<&'a Value> {
    comps.iter().find(|c| c.get("name").and_then(Value::as_str) == Some(name))
}

fn bodies(c: &Value) -> Vec<String> {
    c.get("bodies").and_then(Value::as_array).map(|a| a.iter().filter_map(|b| b.as_str().map(String::from)).collect()).unwrap_or_default()
}

/// Builds or rebuilds the board component from the current PCB revision.
pub fn push(cad: &mut Cad, pcb: &Pcb) -> Result<Value, String> {
    let p = project(pcb)?;
    let name = component_name(p.name.as_deref());
    let revision = revision(pcb);
    let first = {
        let comps = components(cad)?;
        match named(&comps, &name) {
            Some(existing) => {
                let old = bodies(existing);
                exec(cad, "component.activate", &json!({"component": name}))?;
                if !old.is_empty() {
                    exec(cad, "solid.remove", &json!({"bodies": old}))?;
                }
                false
            }
            None => {
                exec(cad, "component.create", &json!({"name": name, "parent": "root", "activate": true, "grounded": false}))?;
                true
            }
        }
    };
    let built = build(&p, cad);
    let _ = exec(cad, "component.activate", &json!({"component": "root"}));
    built?;
    exec(cad, 
        "component.metadata.set",
        &json!({"component": name, "description": TAG, "revision": format!("pcb-{revision}"), "part_number": p.name.as_deref().unwrap_or("PCB")}),
    )?;
    Ok(json!({"component": name, "revision": revision, "created": first}))
}

// Geometry, in the component's frame: PCB x to x, PCB y to -y, board top at z = T.
const T: f64 = 1.6;
const CU: f64 = 0.05;

fn w(q: Pt) -> [f64; 2] {
    [q.x, -q.y]
}

fn build(p: &Project, cad: &mut Cad) -> Result<(), String> {
    let mut run = |id: &str, v: Value| exec(cad, id, &v).map(|_| ());
    let b = &p.board;
    run("solid.box", json!({"length": b.width, "width": b.height, "height": T, "corner": [0, -b.height, 0], "body_name": "PCB Board"}))?;
    run("appearance.assign", json!({"bodies": ["PCB Board"], "color": "#1f5c3a"}))?;
    for c in &b.cutouts {
        let q = w(c.center);
        run("solid.cylinder", json!({"radius": c.radius, "height": T + 0.4, "base": [q[0], q[1], -0.2], "operation": "cut", "targets": ["PCB Board"]}))?;
    }

    // Copper: pad rings and tracks on the top (F.Cu) or under the board (B.Cu), one body.
    let mut copper = false;
    let mut add_copper = |run: &mut dyn FnMut(&str, Value) -> Result<(), String>, id: &str, mut q: Value| {
        if copper {
            q["operation"] = json!("join");
            q["targets"] = json!(["PCB Copper"]);
        } else {
            q["body_name"] = json!("PCB Copper");
        }
        run(id, q)?;
        copper = true;
        Ok::<(), String>(())
    };
    for f in &b.footprints {
        for pad in &f.pads {
            let q = w(f.pad(pad));
            add_copper(&mut run, "solid.cylinder", json!({"radius": pad.diameter / 2.0, "height": CU, "base": [q[0], q[1], T]}))?;
        }
    }
    for tr in &b.tracks {
        let (a, z) = (w(tr.start), w(tr.end));
        let top = if tr.layer == "F.Cu" { T } else { -CU };
        let hw = tr.width / 2.0;
        if (a[1] - z[1]).abs() < 1e-6 {
            add_copper(&mut run, "solid.box", json!({"length": (z[0] - a[0]).abs() + tr.width, "width": tr.width, "height": CU, "corner": [a[0].min(z[0]) - hw, a[1] - hw, top]}))?;
        } else if (a[0] - z[0]).abs() < 1e-6 {
            add_copper(&mut run, "solid.box", json!({"length": tr.width, "width": (z[1] - a[1]).abs() + tr.width, "height": CU, "corner": [a[0] - hw, a[1].min(z[1]) - hw, top]}))?;
        }
    }
    if copper {
        run("appearance.assign", json!({"bodies": ["PCB Copper"], "color": "#c9a54a", "pbr": {"metallic": 1, "roughness": 0.35, "dielectric_ior": 1.5}}))?;
    }

    // Plated holes through board and copper.
    let targets = if copper { json!(["PCB Board", "PCB Copper"]) } else { json!(["PCB Board"]) };
    for f in &b.footprints {
        for pad in &f.pads {
            let q = w(f.pad(pad));
            run("solid.cylinder", json!({"radius": pad.diameter * 0.22, "height": T + 0.6, "base": [q[0], q[1], -0.3], "operation": "cut", "targets": targets}))?;
        }
    }

    // Part bodies: simple stand-ins sized from the pad span, along the pad axis.
    for f in &b.footprints {
        let Some(c) = p.components.iter().find(|c| c.id == f.component) else { continue };
        let pts: Vec<[f64; 2]> = f.pads.iter().map(|pad| w(f.pad(pad))).collect();
        let (Some(first), Some(last)) = (pts.first(), pts.last()) else { continue };
        let mid = [(first[0] + last[0]) / 2.0, (first[1] + last[1]) / 2.0];
        let (dx, dy) = (last[0] - first[0], last[1] - first[1]);
        let len = dx.hypot(dy);
        let span = len.max(2.54);
        let axis = if len > 1e-6 { [dx / len, dy / len] } else { [1.0, 0.0] };
        let body = format!("PCB {}", c.reference);
        let top = T + CU;
        match c.kind.as_str() {
            "resistor" => {
                let (l, d) = (span * 0.62, 2.4);
                run("solid.cylinder", json!({"diameter": d, "height": l, "axis": [axis[0], axis[1], 0],
                    "base": [mid[0] - axis[0] * l / 2.0, mid[1] - axis[1] * l / 2.0, top + d / 2.0 + 0.4], "body_name": body}))?;
                run("appearance.assign", json!({"bodies": [body], "color": "#d8c39a"}))?;
            }
            "capacitor" => {
                run("solid.cylinder", json!({"diameter": 5, "height": 8, "base": [mid[0], mid[1], top], "body_name": body}))?;
                run("appearance.assign", json!({"bodies": [body], "color": "#2b4c8c"}))?;
            }
            "led" => {
                run("solid.cylinder", json!({"diameter": 5, "height": 5.5, "base": [mid[0], mid[1], top], "body_name": body}))?;
                run("solid.sphere", json!({"diameter": 4.8, "center": [mid[0], mid[1], top + 5.2], "operation": "join", "targets": [body]}))?;
                run("appearance.assign", json!({"bodies": [body], "color": "#46c66a", "opacity": 0.85}))?;
            }
            _ => {
                let along = axis[0].abs() >= axis[1].abs();
                let (l, wd) = if along { (span + 5.0, 6.0) } else { (6.0, span + 5.0) };
                run("solid.box", json!({"length": l, "width": wd, "height": 7, "corner": [mid[0] - l / 2.0, mid[1] - wd / 2.0, top], "body_name": body}))?;
                run("appearance.assign", json!({"bodies": [body], "color": "#2a2a2c"}))?;
            }
        }
    }
    Ok(())
}

// Assembly. Matrices are column-major, `m[col][row]`, as `component.list` writes placements
// (each column of the placement as one row, translation last).

type M4 = [[f64; 4]; 4];

const ID: M4 = [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]];

fn matrix(v: Option<&Value>) -> M4 {
    let mut m = ID;
    let Some(rows) = v.and_then(Value::as_array) else { return m };
    for (c, col) in rows.iter().take(4).enumerate() {
        for (r, x) in col.as_array().into_iter().flatten().take(4).enumerate() {
            m[c][r] = x.as_f64().unwrap_or(m[c][r]);
        }
    }
    m
}

fn mul(a: &M4, b: &M4) -> M4 {
    let mut m = [[0.0; 4]; 4];
    for c in 0..4 {
        for r in 0..4 {
            m[c][r] = (0..4).map(|k| a[k][r] * b[c][k]).sum();
        }
    }
    m
}

/// Inverse of an affine placement (3x3 linear part plus translation).
fn inverse(m: &M4) -> M4 {
    let a = |r: usize, c: usize| m[c][r];
    let det = a(0, 0) * (a(1, 1) * a(2, 2) - a(1, 2) * a(2, 1)) - a(0, 1) * (a(1, 0) * a(2, 2) - a(1, 2) * a(2, 0))
        + a(0, 2) * (a(1, 0) * a(2, 1) - a(1, 1) * a(2, 0));
    if det.abs() < 1e-12 {
        return ID;
    }
    let mut inv = ID;
    let cof = |r0: usize, c0: usize| {
        let rs: Vec<usize> = (0..3).filter(|&r| r != r0).collect();
        let cs: Vec<usize> = (0..3).filter(|&c| c != c0).collect();
        let d = a(rs[0], cs[0]) * a(rs[1], cs[1]) - a(rs[0], cs[1]) * a(rs[1], cs[0]);
        if (r0 + c0) % 2 == 0 { d } else { -d }
    };
    for r in 0..3 {
        for c in 0..3 {
            // inverse(r, c) = cofactor(c, r) / det
            inv[c][r] = cof(c, r) / det;
        }
    }
    for r in 0..3 {
        inv[3][r] = -(0..3).map(|k| inv[k][r] * m[3][k]).sum::<f64>();
    }
    inv
}

/// The rotation turning +z onto `n` (unit), as a 3x3 column-major matrix.
fn rotation_to(n: [f64; 3]) -> [[f64; 3]; 3] {
    let d = n[2];
    if d > 0.999_999 {
        return [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
    }
    if d < -0.999_999 {
        // Half a turn about x.
        return [[1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.0, 0.0, -1.0]];
    }
    // Rodrigues about k = z × n.
    let k = [-n[1], n[0], 0.0];
    let s = (k[0] * k[0] + k[1] * k[1]).sqrt();
    let k = [k[0] / s, k[1] / s, 0.0];
    let (c, v) = (d, 1.0 - d);
    let mut r = [[0.0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            let skew = match (i, j) {
                (0, 1) => -k[2] * s,
                (0, 2) => k[1] * s,
                (1, 0) => k[2] * s,
                (1, 2) => -k[0] * s,
                (2, 0) => -k[1] * s,
                (2, 1) => k[0] * s,
                _ => 0.0,
            };
            let rij = if i == j { c } else { 0.0 } + v * k[i] * k[j] + skew;
            r[j][i] = rij;
        }
    }
    r
}

/// Seats the board's bottom face on a picked face of another part, its z along that face's
/// normal, and holds it there with a rigid group. A body of the design's root is first made into
/// a component of its own, since joints join components.
pub fn mount(cad: &mut Cad, pcb: &Pcb, target: &str, point: [f64; 3], normal: [f64; 3]) -> Result<Value, String> {
    let p = project(pcb)?;
    let name = component_name(p.name.as_deref());
    let mut comps = components(cad)?;
    let board = named(&comps, &name).ok_or("Send the board to 3D first")?;
    let occ = board.get("occurrences").and_then(Value::as_array).and_then(|o| o.first()).ok_or("Send the board to 3D first")?;
    let occ_name = occ.get("name").and_then(Value::as_str).ok_or("The board has no placement")?.to_string();
    let current = matrix(occ.get("transform"));
    let owner = comps.iter().find(|c| bodies(c).iter().any(|b| b == target)).ok_or("Pick a face of another part")?;
    if owner.get("name").and_then(Value::as_str) == Some(name.as_str()) {
        return Err("Pick a face of another part, not the board".into());
    }
    if owner.get("id").and_then(Value::as_u64) == Some(0) {
        exec(cad, "component.from_bodies", &json!({"bodies": [target]}))?;
        comps = components(cad)?;
    }
    let host = comps
        .iter()
        .find(|c| bodies(c).iter().any(|b| b == target))
        .and_then(|c| c.get("occurrences")?.as_array()?.first()?.get("name")?.as_str().map(String::from))
        .ok_or("That part has no placement")?;

    // Delta = desired * current⁻¹, all in world space.
    let len = (normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]).sqrt().max(1e-12);
    let rot = rotation_to([normal[0] / len, normal[1] / len, normal[2] / len]);
    let centre = [p.board.width / 2.0, -p.board.height / 2.0, 0.0];
    let mut desired = ID;
    for c in 0..3 {
        desired[c][..3].copy_from_slice(&rot[c]);
    }
    for r in 0..3 {
        desired[3][r] = point[r] - (0..3).map(|k| rot[k][r] * centre[k]).sum::<f64>();
    }
    let delta = mul(&desired, &inverse(&current));
    let rows: Vec<Vec<f64>> = (0..3).map(|r| (0..4).map(|c| delta[c][r]).collect()).collect();
    exec(cad, "occurrence.move", &json!({"occurrence": occ_name, "space": "world", "matrix": rows}))?;
    exec(cad, "joint.rigid_group", &json!({"occurrences": [occ_name, host]}))?;
    Ok(json!({"board": occ_name, "host": host}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_turns_z_onto_the_normal() {
        for n in [[1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.6, 0.0, 0.8], [0.0, 0.0, -1.0]] {
            let r = rotation_to(n);
            for i in 0..3 {
                assert!((r[2][i] - n[i]).abs() < 1e-9, "{n:?} -> {r:?}");
            }
        }
    }

    #[test]
    fn inverse_undoes_a_placement() {
        let r = rotation_to([0.6, 0.0, 0.8]);
        let mut m = ID;
        for c in 0..3 {
            m[c][..3].copy_from_slice(&r[c]);
        }
        m[3] = [3.0, -4.0, 5.0, 1.0];
        let i = mul(&m, &inverse(&m));
        for c in 0..4 {
            for r in 0..4 {
                assert!((i[c][r] - ID[c][r]).abs() < 1e-9);
            }
        }
    }

    #[test]
    fn board_goes_to_3d_and_mounts_on_a_face() {
        let mut ws = Workspace::new(true);
        ws.cad_execute("solid.box", &json!({"length": 80, "width": 60, "height": 12, "corner": [0, -60, 0], "body_name": "Enclosure"})).unwrap();
        let r = push(&mut ws.cad, &ws.pcb).unwrap();
        assert_eq!(r["created"], json!(true));
        let rev = ws.pcb_revision();
        assert_eq!(linked_revision(&mut ws.cad, &ws.pcb), Some(rev));
        mount(&mut ws.cad, &ws.pcb, "Enclosure", [30.0, -20.0, 12.0], [0.0, 0.0, 1.0]).unwrap();
        let joints = ws.cad_execute("joint.list", &json!({})).unwrap();
        assert!(joints.to_string().contains("rigid"), "{joints}");

        // A board edit puts the 3D board out of date; updating keeps the joint.
        ws.pcb_execute("board.sync", json!({})).ok();
        ws.pcb_execute("component.add", json!({"kind": "resistor", "position": {"x": 60, "y": 30}})).unwrap();
        assert_eq!(ws.link_state()["out_of_date"], json!(true));
        let r = push(&mut ws.cad, &ws.pcb).unwrap();
        assert_eq!(r["created"], json!(false));
        assert_eq!(ws.link_state()["out_of_date"], json!(false));
        assert_eq!(ws.cad_execute("joint.list", &json!({})).unwrap(), joints);
    }
}
