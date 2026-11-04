//! C ABI over the ViaForm core (SolidCraft and PCBCraft), for the native Swift front ends.
//!
//! Everything the front end does goes through `sc_execute` (the engine's command registry), so
//! the Swift app stays as thin as the egui one: it builds parameters, runs commands and draws the
//! scene the engine describes. Strings cross as UTF-8 C strings; every string this library
//! returns is freed with `sc_string_free`. A panic inside the engine never unwinds into Swift:
//! each entry point catches it and answers with an error.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde_json::{Value, json};
use solidcraft_engine::Session;
use solidcraft_engine::render::Camera;
use viaform_core::scene::{FlatLine, FlatScene};
use solidcraft_engine::view;

/// An open design.
pub struct ScSession {
    session: Session,
}

/// A scene flattened to `f32` buffers the GPU can take as they are.
pub struct ScScene {
    flat: FlatScene,
    /// The body each mesh draws (the scene lists visible bodies in model order).
    body_names: Vec<CString>,
}

/// One body's triangles. Pointers stay valid until the scene is freed.
#[repr(C)]
pub struct ScMeshView {
    pub positions: *const f32,
    pub normals: *const f32,
    pub vertex_count: u32,
    pub indices: *const u32,
    pub index_count: u32,
    /// B-rep face index per triangle (`index_count / 3` entries).
    pub tri_face: *const u32,
    /// Edge polylines: `edge_count + 1` offsets (in points) into `edge_points` (xyz each).
    pub edge_points: *const f32,
    pub edge_offsets: *const u32,
    pub edge_count: u32,
    pub color: [f32; 4],
}

/// One polyline (an edge, a sketch curve, an axis or a grid line).
#[repr(C)]
pub struct ScLineView {
    pub points: *const f32,
    pub point_count: u32,
    pub color: [f32; 4],
    pub width: f32,
    pub on_top: bool,
}

fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

fn out(v: &Value) -> *mut c_char {
    CString::new(v.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `p` is null or a NUL-terminated string.
unsafe fn text<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    // SAFETY: the caller passes a NUL-terminated string that outlives this call.
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// A new, empty design.
#[unsafe(no_mangle)]
pub extern "C" fn sc_session_new() -> *mut ScSession {
    guard(std::ptr::null_mut(), || Box::into_raw(Box::new(ScSession { session: Session::default() })))
}

/// # Safety
/// `s` is null or came from `sc_session_new` and was not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_session_free(s: *mut ScSession) {
    if !s.is_null() {
        // SAFETY: `s` came from `Box::into_raw` in `sc_session_new`.
        drop(unsafe { Box::from_raw(s) });
    }
}

/// Runs one command. Answers `{"ok": reply}` or `{"error": message}`.
///
/// # Safety
/// `s` is a live session; `id` and `params` are NUL-terminated strings (`params` may be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_execute(s: *mut ScSession, id: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_mut() }) else { return out(&json!({"error": "no session"})) };
    // SAFETY: NUL-terminated strings, per the contract above.
    let (id, params) = unsafe { (text(id), text(params)) };
    let reply = guard(json!({"error": "the engine stopped on this command"}), || {
        let Some(id) = id else { return json!({"error": "no command id"}) };
        let p: Value = match params.map(serde_json::from_str).transpose() {
            Ok(p) => p.unwrap_or_else(|| json!({})),
            Err(e) => return json!({"error": format!("params: {e}")}),
        };
        match s.session.execute(id, &p) {
            Ok(v) => json!({"ok": v}),
            Err(e) => json!({"error": e.to_string()}),
        }
    });
    out(&reply)
}

/// Runs a script (`{"commands": [{"command", "params"}...]}`). Answers `{"ok": [replies]}`.
///
/// # Safety
/// `s` is a live session; `script` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_run_script(s: *mut ScSession, script: *const c_char) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_mut() }) else { return out(&json!({"error": "no session"})) };
    // SAFETY: NUL-terminated string, per the contract above.
    let script = unsafe { text(script) };
    let reply = guard(json!({"error": "the engine stopped on this script"}), || {
        let Some(script) = script else { return json!({"error": "no script"}) };
        let v: Value = match serde_json::from_str(script) {
            Ok(v) => v,
            Err(e) => return json!({"error": format!("script: {e}")}),
        };
        match s.session.run_script(&v) {
            Ok(r) => json!({"ok": r}),
            Err(e) => json!({"error": e.to_string()}),
        }
    });
    out(&reply)
}

/// The command registry: id, label, tab, panel, icon, shortcut and params doc of each command.
#[unsafe(no_mangle)]
pub extern "C" fn sc_commands() -> *mut c_char {
    out(&guard(json!([]), || {
        Value::Array(
            solidcraft_engine::command_specs()
                .iter()
                .map(|c| {
                    json!({
                        "id": c.id, "label": c.label, "tab": c.tab, "panel": c.panel,
                        "icon": c.icon, "key": c.shortcut, "params": c.params,
                    })
                })
                .collect(),
        )
    }))
}

/// The camera that frames the whole design, as JSON (the engine's `Camera`).
///
/// # Safety
/// `s` is a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_home_camera(s: *const ScSession) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_ref() }) else { return out(&Value::Null) };
    out(&guard(Value::Null, || serde_json::to_value(view::home_camera(&s.session).ok()).unwrap_or(Value::Null)))
}

/// The design's model bounds as `{"min": [x,y,z], "max": [x,y,z]}`, or null when empty.
///
/// # Safety
/// `s` is a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_bounds(s: *const ScSession) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_ref() }) else { return out(&Value::Null) };
    out(&guard(Value::Null, || {
        let Ok(b) = view::bounds(&s.session) else { return Value::Null };
        if b.is_empty() {
            Value::Null
        } else {
            json!({"min": [b.min.x, b.min.y, b.min.z], "max": [b.max.x, b.max.y, b.max.z]})
        }
    }))
}

/// The open sketch's plane as `{"origin", "x_dir", "y_dir"}` (world), or null with no sketch open.
///
/// # Safety
/// `s` is a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_sketch_plane(s: *const ScSession) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_ref() }) else { return out(&Value::Null) };
    out(&guard(Value::Null, || {
        view::open_sketch_plane(&s.session).ok().flatten().map_or(Value::Null, |p| {
            json!({"origin": [p.origin.x, p.origin.y, p.origin.z], "x_dir": [p.x.x, p.x.y, p.x.z], "y_dir": [p.y.x, p.y.y, p.y.z]})
        })
    }))
}

/// Builds the scene seen from `camera` (JSON `Camera`; null for the home view).
///
/// # Safety
/// `s` is a live session; `camera` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_build(s: *mut ScSession, camera: *const c_char) -> *mut ScScene {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_mut() }) else { return std::ptr::null_mut() };
    // SAFETY: NUL-terminated string or null, per the contract above.
    let camera = unsafe { text(camera) };
    guard(std::ptr::null_mut(), || {
        let cam: Option<Camera> = camera.and_then(|c| serde_json::from_str(c).ok());
        let flat = viaform_core::scene::build(&s.session, cam);
        let body_names = flat.meshes.iter().filter_map(|m| CString::new(m.body.as_str()).ok()).collect();
        let flat = ScScene { flat, body_names };
        Box::into_raw(Box::new(flat))
    })
}

/// # Safety
/// `sc` is null or came from `sc_scene_build` and was not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_free(sc: *mut ScScene) {
    if !sc.is_null() {
        // SAFETY: `sc` came from `Box::into_raw` in `sc_scene_build`.
        drop(unsafe { Box::from_raw(sc) });
    }
}

/// # Safety
/// `sc` is a live scene.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_radius(sc: *const ScScene) -> f32 {
    // SAFETY: the caller passes a live scene.
    unsafe { sc.as_ref() }.map_or(1.0, |sc| sc.flat.radius)
}

/// The background gradient: top RGBA then bottom RGBA (all zero when the scene has none).
///
/// # Safety
/// `sc` is a live scene; `out` points at 8 floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_background(sc: *const ScScene, out: *mut f32) {
    // SAFETY: the caller passes a live scene and room for 8 floats.
    if let (Some(sc), false) = (unsafe { sc.as_ref() }, out.is_null()) {
        unsafe { std::ptr::copy_nonoverlapping(sc.flat.background.as_ptr(), out, 8) };
    }
}

/// The name of the body mesh `i` draws (owned by the scene), or null.
///
/// # Safety
/// `sc` is a live scene.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_body_name(sc: *const ScScene, i: u32) -> *const c_char {
    // SAFETY: the caller passes a live scene.
    unsafe { sc.as_ref() }.and_then(|sc| sc.body_names.get(i as usize)).map_or(std::ptr::null(), |n| n.as_ptr())
}

/// # Safety
/// `sc` is a live scene.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_mesh_count(sc: *const ScScene) -> u32 {
    // SAFETY: the caller passes a live scene.
    unsafe { sc.as_ref() }.map_or(0, |sc| sc.flat.meshes.len() as u32)
}

/// # Safety
/// `sc` is a live scene; `out` points at an `ScMeshView`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_mesh(sc: *const ScScene, i: u32, out: *mut ScMeshView) -> bool {
    // SAFETY: the caller passes a live scene and a writable view.
    let (Some(sc), Some(out)) = (unsafe { sc.as_ref() }, unsafe { out.as_mut() }) else { return false };
    let Some(m) = sc.flat.meshes.get(i as usize) else { return false };
    *out = ScMeshView {
        positions: m.positions.as_ptr(),
        normals: m.normals.as_ptr(),
        vertex_count: (m.positions.len() / 3) as u32,
        indices: m.indices.as_ptr(),
        index_count: m.indices.len() as u32,
        tri_face: m.tri_face.as_ptr(),
        edge_points: m.edge_points.as_ptr(),
        edge_offsets: m.edge_offsets.as_ptr(),
        edge_count: (m.edge_offsets.len().saturating_sub(1)) as u32,
        color: m.color,
    };
    true
}

fn line_view(l: &FlatLine) -> ScLineView {
    ScLineView {
        points: l.points.as_ptr(),
        point_count: (l.points.len() / 3) as u32,
        color: l.color,
        width: l.width,
        on_top: l.on_top,
    }
}

/// # Safety
/// `sc` is a live scene.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_line_count(sc: *const ScScene, grid: bool) -> u32 {
    // SAFETY: the caller passes a live scene.
    unsafe { sc.as_ref() }.map_or(0, |sc| if grid { sc.flat.grid.len() } else { sc.flat.lines.len() } as u32)
}

/// Line `i` of the scene's lines, or of its ground grid when `grid` is set.
///
/// # Safety
/// `sc` is a live scene; `out` points at an `ScLineView`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_scene_line(sc: *const ScScene, grid: bool, i: u32, out: *mut ScLineView) -> bool {
    // SAFETY: the caller passes a live scene and a writable view.
    let (Some(sc), Some(out)) = (unsafe { sc.as_ref() }, unsafe { out.as_mut() }) else { return false };
    let list = if grid { &sc.flat.grid } else { &sc.flat.lines };
    let Some(l) = list.get(i as usize) else { return false };
    *out = line_view(l);
    true
}

/// # Safety
/// `p` is null or a string this library returned, not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_string_free(p: *mut c_char) {
    if !p.is_null() {
        // SAFETY: `p` came from `CString::into_raw` in `out`.
        drop(unsafe { CString::from_raw(p) });
    }
}

// MARK: PCB (PCBCraft engine, GPL-3.0-or-later)

/// An open PCB project: schematic, board and libraries.
pub struct PcbSession {
    session: pcbcraft_engine::Session,
}

/// A new PCB project, empty or the engine's sample (an LED indicator).
#[unsafe(no_mangle)]
pub extern "C" fn pcb_session_new(sample: bool) -> *mut PcbSession {
    guard(std::ptr::null_mut(), || {
        let session = if sample { pcbcraft_engine::Session::sample().unwrap_or_default() } else { pcbcraft_engine::Session::default() };
        Box::into_raw(Box::new(PcbSession { session }))
    })
}

/// # Safety
/// `s` is null or came from `pcb_session_new` and was not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pcb_session_free(s: *mut PcbSession) {
    if !s.is_null() {
        // SAFETY: `s` came from `Box::into_raw` in `pcb_session_new`.
        drop(unsafe { Box::from_raw(s) });
    }
}

/// Runs one PCB command. Answers `{"ok": reply}` or `{"error": message}`.
/// Besides the engine's commands: `undo`, `redo`, and the file commands `file.open`,
/// `file.save` (PCBCraft JSON project) and `file.export_kicad` (a `.kicad_pcb` board), each
/// with `{"path": ...}`.
///
/// # Safety
/// `s` is a live PCB session; `id` and `params` are NUL-terminated strings (`params` may be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pcb_execute(s: *mut PcbSession, id: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_mut() }) else { return out(&json!({"error": "no session"})) };
    // SAFETY: NUL-terminated strings, per the contract above.
    let (id, params) = unsafe { (text(id), text(params)) };
    let reply = guard(json!({"error": "the PCB engine stopped on this command"}), || {
        let Some(id) = id else { return json!({"error": "no command id"}) };
        let p: Value = match params.map(serde_json::from_str).transpose() {
            Ok(p) => p.unwrap_or_else(|| json!({})),
            Err(e) => return json!({"error": format!("params: {e}")}),
        };
        match viaform_core::pcb_execute(&mut s.session, id, p) {
            Ok(v) => json!({"ok": v}),
            Err(e) => json!({"error": e}),
        }
    });
    out(&reply)
}

/// The whole project (schematic, board, libraries) with history counts.
///
/// # Safety
/// `s` is a live PCB session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pcb_inspect(s: *const PcbSession) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_ref() }) else { return out(&Value::Null) };
    out(&guard(Value::Null, || s.session.inspect()))
}

/// ERC, DRC and airwires.
///
/// # Safety
/// `s` is a live PCB session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pcb_checks(s: *const PcbSession) -> *mut c_char {
    // SAFETY: the caller passes a live session.
    let Some(s) = (unsafe { s.as_ref() }) else { return out(&Value::Null) };
    out(&guard(Value::Null, || s.session.checks()))
}

/// The PCB command registry: id, description and input schema of each command.
#[unsafe(no_mangle)]
pub extern "C" fn pcb_commands() -> *mut c_char {
    out(&guard(json!([]), || serde_json::to_value(pcbcraft_engine::commands()).unwrap_or(Value::Null)))
}

// MARK: Board to 3D link (viaform-core), the same code the Electron app runs

fn link_reply(r: Result<Value, String>) -> *mut c_char {
    out(&match r {
        Ok(v) => json!({"ok": v}),
        Err(e) => json!({"error": e}),
    })
}

/// Builds or rebuilds the board of `pcb` as a component of the design `sc`.
///
/// # Safety
/// `sc` and `pcb` are live sessions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_link_push(sc: *mut ScSession, pcb: *const PcbSession) -> *mut c_char {
    // SAFETY: the caller passes live sessions.
    let (Some(sc), Some(pcb)) = (unsafe { sc.as_mut() }, unsafe { pcb.as_ref() }) else { return out(&json!({"error": "no session"})) };
    link_reply(guard(Err("the engine stopped while building the board".into()), || viaform_core::link::push(&mut sc.session, &pcb.session)))
}

/// Seats the board on the face of `body` at `point` (xyz) with `normal` (xyz), with a rigid group.
///
/// # Safety
/// `sc` and `pcb` are live sessions; `body` is a NUL-terminated string; `point` and `normal`
/// point at three doubles each.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_link_mount(sc: *mut ScSession, pcb: *const PcbSession, body: *const c_char, point: *const f64, normal: *const f64) -> *mut c_char {
    // SAFETY: the caller passes live sessions, a string and two arrays of three doubles.
    let (Some(sc), Some(pcb), Some(body)) = (unsafe { sc.as_mut() }, unsafe { pcb.as_ref() }, unsafe { text(body) }) else {
        return out(&json!({"error": "no session"}));
    };
    if point.is_null() || normal.is_null() {
        return out(&json!({"error": "no point"}));
    }
    let (p, n) = unsafe { (*(point as *const [f64; 3]), *(normal as *const [f64; 3])) };
    link_reply(guard(Err("the engine stopped while mounting the board".into()), || viaform_core::link::mount(&mut sc.session, &pcb.session, body, p, n)))
}

/// The PCB revision the design's board was built from (or -1 when the design has none).
///
/// # Safety
/// `sc` and `pcb` are live sessions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vf_link_revision(sc: *mut ScSession, pcb: *const PcbSession) -> i64 {
    // SAFETY: the caller passes live sessions.
    let (Some(sc), Some(pcb)) = (unsafe { sc.as_mut() }, unsafe { pcb.as_ref() }) else { return -1 };
    guard(None, || viaform_core::link::linked_revision(&mut sc.session, &pcb.session)).map_or(-1, |r| r as i64)
}
