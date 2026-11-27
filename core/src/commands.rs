//! The design commands as the front ends see them: a typed parameter schema per registry
//! command (so a form shows fields with units, toggles and pickers instead of raw JSON), and the
//! few commands the core runs in front of the engine.
//!
//! The engine's registry documents each command's parameters as one line of prose. The schema
//! here is the form a person fills: the fields worth asking for, in order, with a label, a unit,
//! a default and bounds. A command without a schema keeps the raw JSON form ("Advanced").
//!
//! Values a form sends: a length is an expression string in millimetres (`"12.5 mm"`), an angle
//! one in degrees (`"30 deg"`), so the design's own units never change their meaning; numbers,
//! integers and points (`[x, y, z]` in millimetres) are JSON numbers; entity references are names
//! (bodies), ids (sketches) or picked points (edges and faces). An optional field left at its default is not sent, so
//! the engine's own default applies; an optional field with no default is sent only once set.

use serde::Serialize;
use serde_json::{Value, json};
use solidcraft_engine::Session;

/// What a field holds, and so which control a form draws for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// A length in millimetres, typed with units and expressions.
    Length,
    /// An angle in degrees.
    Angle,
    /// A bare number (a factor).
    Number,
    /// A whole number (a count).
    Integer,
    Bool,
    /// One of `options`; an empty option means "the engine decides" (Automatic).
    Enum,
    String,
    /// One body, by name.
    Body,
    /// Several bodies, by name.
    Bodies,
    /// One sketch, by id.
    Sketch,
    /// Edges picked in the viewport, as points on them.
    Edges,
    /// Faces picked in the viewport, as points on them.
    Faces,
    /// A point `[x, y, z]` in millimetres (a position, or a pick on a face).
    Point,
    /// A direction `[x, y, z]` (unitless).
    Vector,
}

/// One parameter of a command's form.
#[derive(Clone, Debug, Serialize)]
pub struct Field {
    /// The parameter's key in the command's JSON.
    pub key: &'static str,
    pub label: &'static str,
    pub kind: Kind,
    /// `mm` for lengths and points, `deg` for angles.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<&'static str>,
    /// The value the form starts with. Null: no value until the user gives one.
    #[serde(skip_serializing_if = "Value::is_null")]
    pub default: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max: Option<f64>,
    /// One sentence under the field.
    #[serde(skip_serializing_if = "str::is_empty")]
    pub help: &'static str,
    /// The choices of an `enum` field, in order.
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub options: &'static [&'static str],
    /// Sent only when changed from `default` (or, with no default, once set).
    pub optional: bool,
}

impl Field {
    fn new(key: &'static str, label: &'static str, kind: Kind, default: Value) -> Self {
        let unit = match kind {
            Kind::Length | Kind::Point => Some("mm"),
            Kind::Angle => Some("deg"),
            _ => None,
        };
        Field { key, label, kind, unit, default, min: None, max: None, help: "", options: &[], optional: false }
    }
    fn optional(mut self) -> Self {
        self.optional = true;
        self
    }
    fn min(mut self, v: f64) -> Self {
        self.min = Some(v);
        self
    }
    fn max(mut self, v: f64) -> Self {
        self.max = Some(v);
        self
    }
    fn help(mut self, h: &'static str) -> Self {
        self.help = h;
        self
    }
}

fn length(key: &'static str, label: &'static str, v: f64) -> Field {
    Field::new(key, label, Kind::Length, json!(v))
}
/// A strictly positive length (the engine refuses zero sizes; the form's bound is a hair above).
fn size(key: &'static str, label: &'static str, v: f64) -> Field {
    length(key, label, v).min(0.001)
}
fn angle(key: &'static str, label: &'static str, v: f64) -> Field {
    Field::new(key, label, Kind::Angle, json!(v))
}
fn integer(key: &'static str, label: &'static str, v: i64) -> Field {
    Field::new(key, label, Kind::Integer, json!(v))
}
fn number(key: &'static str, label: &'static str, v: f64) -> Field {
    Field::new(key, label, Kind::Number, json!(v))
}
fn boolean(key: &'static str, label: &'static str, v: bool) -> Field {
    Field::new(key, label, Kind::Bool, json!(v)).optional()
}
fn choice(key: &'static str, label: &'static str, options: &'static [&'static str], v: &str) -> Field {
    let mut f = Field::new(key, label, Kind::Enum, json!(v));
    f.options = options;
    f
}
fn text(key: &'static str, label: &'static str) -> Field {
    Field::new(key, label, Kind::String, json!(""))
}
fn entity(key: &'static str, label: &'static str, kind: Kind) -> Field {
    Field::new(key, label, kind, Value::Null)
}
fn point(key: &'static str, label: &'static str, v: [f64; 3]) -> Field {
    Field::new(key, label, Kind::Point, json!(v))
}
fn vector(key: &'static str, label: &'static str, v: [f64; 3]) -> Field {
    Field::new(key, label, Kind::Vector, json!(v))
}

const AXES: &[&str] = &["X", "Y", "Z"];
const PLANES: &[&str] = &["XY", "XZ", "YZ"];
/// The boolean of a primitive: empty lets the engine choose (a new body, or a join where it lands
/// on one).
const PRIMITIVE_OPS: &[&str] = &["", "new", "join", "cut", "intersect"];

fn operation() -> Field {
    choice("operation", "Operation", PRIMITIVE_OPS, "").optional().help("Automatic makes a new body, or joins the body it touches.")
}
fn body_name() -> Field {
    text("body_name", "Body name").optional().help("Leave empty for the next free name.")
}
fn bodies() -> Field {
    entity("bodies", "Bodies", Kind::Bodies).help("The bodies selected in the model, or pick them here.")
}

/// The form of `id`, or `None` when the command has no schema (the form falls back to JSON).
pub fn schema(id: &str) -> Option<Vec<Field>> {
    let fields = match id {
        "solid.box" => vec![
            size("length", "Length", 20.0),
            size("width", "Width", 20.0),
            size("height", "Height", 20.0),
            point("corner", "Corner", [0.0, 0.0, 0.0]).optional(),
            operation(),
            body_name(),
        ],
        "solid.cylinder" => vec![
            size("diameter", "Diameter", 20.0),
            size("height", "Height", 20.0),
            point("base", "Base centre", [0.0, 0.0, 0.0]).optional(),
            choice("axis", "Axis", AXES, "Z").optional(),
            operation(),
            body_name(),
        ],
        "solid.sphere" => vec![size("diameter", "Diameter", 20.0), point("center", "Centre", [0.0, 0.0, 0.0]).optional(), operation(), body_name()],
        "solid.torus" => vec![
            size("major", "Major radius", 20.0).help("From the centre to the middle of the tube."),
            size("minor", "Minor radius", 5.0).help("The tube's radius, smaller than the major radius."),
            point("center", "Centre", [0.0, 0.0, 0.0]).optional(),
            operation(),
            body_name(),
        ],
        "solid.cone" => vec![
            size("diameter", "Base diameter", 20.0),
            length("top_diameter", "Top diameter", 0.0).min(0.0).optional().help("0 ends in a point."),
            size("height", "Height", 20.0),
            point("base", "Base centre", [0.0, 0.0, 0.0]).optional(),
            choice("axis", "Axis", AXES, "Z").optional(),
            operation(),
            body_name(),
        ],
        "solid.extrude" => vec![
            entity("sketch", "Sketch", Kind::Sketch).optional().help("Empty: the open or last sketch."),
            length("distance", "Distance", 10.0),
            choice("direction", "Direction", &["positive", "negative", "symmetric"], "positive").optional(),
            angle("taper", "Taper", 0.0).min(-89.0).max(89.0).optional(),
            choice("operation", "Operation", &["auto", "new", "join", "cut", "intersect"], "auto").optional(),
            body_name(),
        ],
        "solid.revolve" => vec![
            entity("sketch", "Sketch", Kind::Sketch).optional().help("Empty: the open or last sketch."),
            choice("axis", "Axis", &["x", "y", "X", "Y", "Z"], "x").help("Lower case: the sketch's own axes. Upper case: the world axes."),
            angle("angle", "Angle", 360.0).min(0.001).max(360.0).optional(),
            choice("operation", "Operation", &["auto", "new", "join", "cut", "intersect"], "auto").optional(),
            body_name(),
        ],
        "solid.fillet" => vec![
            entity("edges", "Edges", Kind::Edges).help("The edges picked in the viewport."),
            size("radius", "Radius", 2.0),
            boolean("tangent_chain", "Follow tangent edges", true),
            choice("fit", "When the radius does not fit", &["exact", "reduce", "taper"], "exact").optional(),
        ],
        "solid.chamfer" => vec![
            entity("edges", "Edges", Kind::Edges).help("The edges picked in the viewport."),
            size("distance", "Distance", 1.0),
            boolean("tangent_chain", "Follow tangent edges", true),
            boolean("flip", "Flip faces", false),
        ],
        "solid.shell" => vec![
            entity("faces", "Open faces", Kind::Faces).optional().help("None: a closed hollow body."),
            size("thickness", "Thickness", 2.0),
            choice("direction", "Direction", &["inside", "outside", "both"], "inside").optional(),
            entity("body", "Body", Kind::Body).optional().help("Needed with no open faces when there are several bodies."),
        ],
        "solid.draft" => vec![
            entity("faces", "Faces", Kind::Faces),
            angle("angle", "Angle", 3.0).min(-89.0).max(89.0),
            choice("neutral", "Neutral plane", PLANES, "XY"),
        ],
        "solid.offset_face" => vec![entity("faces", "Faces", Kind::Faces), length("distance", "Distance", 1.0).help("Positive moves the faces outward.")],
        "solid.press_pull" => vec![
            point("face", "Face", [0.0, 0.0, 0.0]).help("A point on the face: use the face picked in the viewport."),
            length("distance", "Distance", 5.0).help("Positive adds material, negative cuts."),
        ],
        "solid.hole" => vec![
            point("position", "Position", [0.0, 0.0, 0.0]).help("A point on the face: use the face picked in the viewport."),
            size("diameter", "Diameter", 6.0),
            entity("depth", "Depth", Kind::Length).min(0.001).optional().help("Off: through all."),
        ],
        "solid.pattern.rectangular" => vec![
            bodies(),
            vector("dir1", "Direction", [1.0, 0.0, 0.0]),
            integer("count1", "Count", 3).min(1.0).max(1000.0).help("The original counts as one."),
            size("spacing1", "Spacing", 20.0),
            vector("dir2", "Second direction", [0.0, 1.0, 0.0]),
            integer("count2", "Second count", 1).min(1.0).max(1000.0).optional(),
            size("spacing2", "Second spacing", 20.0).optional(),
        ],
        "solid.pattern.circular" => vec![
            bodies(),
            choice("axis", "Axis", AXES, "Z"),
            integer("count", "Count", 6).min(1.0).max(1000.0).help("The original counts as one."),
            angle("angle", "Angle", 360.0).min(0.001).max(360.0).optional(),
        ],
        "solid.mirror" => vec![bodies(), choice("plane", "Mirror plane", PLANES, "YZ"), boolean("combine", "Join with the original", false)],
        "solid.move" => vec![
            bodies(),
            point("translate", "Move by", [10.0, 0.0, 0.0]),
            vector("axis", "Rotation axis", [0.0, 0.0, 1.0]),
            angle("angle", "Rotation", 0.0).optional(),
            boolean("copy", "Move a copy", false),
        ],
        "solid.scale" => vec![
            bodies(),
            number("factor", "Factor", 2.0).min(0.0001),
            point("origin", "About", [0.0, 0.0, 0.0]).optional(),
        ],
        "solid.combine" => vec![
            entity("target", "Target", Kind::Body),
            entity("tools", "Tools", Kind::Bodies),
            choice("operation", "Operation", &["join", "cut", "intersect"], "join").optional(),
            boolean("keep_tools", "Keep the tools", false),
        ],
        "solid.split_body" => vec![entity("body", "Body", Kind::Body), choice("plane", "Split plane", PLANES, "XY")],
        "solid.remove" => vec![bodies().help("Removed from here on in the timeline (undoable).")],
        "body.rename" => vec![entity("body", "Body", Kind::Body), text("name", "New name").help("Features that use the body follow it.")],
        "construct.plane.offset" => vec![
            choice("base", "From", PLANES, "XY"),
            length("offset", "Offset", 10.0),
            text("name", "Name").optional(),
        ],
        "construct.plane.at_angle" => vec![
            choice("base", "From", PLANES, "XY"),
            choice("axis", "About", AXES, "X"),
            angle("angle", "Angle", 45.0),
            text("name", "Name").optional(),
        ],
        "parameters.add" => vec![
            text("name", "Name"),
            text("expression", "Expression").help("A number with its unit (10 mm), or an expression of other parameters."),
            text("comment", "Comment").optional(),
        ],
        _ => return None,
    };
    Some(fields)
}

/// Every command with a schema, as `{id: [fields]}`.
pub fn schemas() -> Value {
    let map: serde_json::Map<String, Value> = solidcraft_engine::command_specs()
        .iter()
        .filter_map(|c| schema(c.id).map(|f| (c.id.to_string(), json!(f))))
        .collect();
    Value::Object(map)
}

/// The parameters a form sends when nothing is changed (tests and previews): required fields at
/// their defaults, optional ones left out, entity references left out.
pub fn default_params(id: &str) -> Option<Value> {
    let mut out = serde_json::Map::new();
    for f in schema(id)? {
        if f.optional || f.default.is_null() {
            continue;
        }
        if let Some(v) = encode(f.kind, &f.default) {
            out.insert(f.key.to_string(), v);
        }
    }
    Some(Value::Object(out))
}

/// A form value as the engine takes it: lengths and angles become unit expressions. Points stay
/// numbers, in millimetres, as the engine reads picks and positions.
pub fn encode(kind: Kind, v: &Value) -> Option<Value> {
    match kind {
        Kind::Length => v.as_f64().map(|x| json!(format!("{x} mm"))),
        Kind::Angle => v.as_f64().map(|x| json!(format!("{x} deg"))),
        Kind::String => v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(|s| json!(s)),
        _ => Some(v.clone()),
    }
}

/// Renames body `body` to `name`, as one undoable step. The name is trimmed; it must not be empty,
/// hold a line break or other control character, or be another body's name. Answers
/// `{"body": old, "name": new}`.
pub fn rename_body(s: &mut Session, body: &str, name: &str) -> Result<Value, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("A body needs a name.".into());
    }
    if name.chars().any(char::is_control) {
        return Err("A body name cannot hold a line break or a tab.".into());
    }
    s.execute("body.rename", &json!({"body": body, "name": name})).map_err(|e| sentence(&e.to_string(), "body.rename"))
}

/// The engine's "invalid parameters for `cmd`: why" as a sentence a person reads beside a field.
fn sentence(error: &str, cmd: &str) -> String {
    let why = error.strip_prefix(&format!("invalid parameters for `{cmd}`: ")).unwrap_or(error);
    let mut chars = why.chars();
    let mut out: String = chars.next().map(|c| c.to_uppercase().collect()).unwrap_or_default();
    out.push_str(chars.as_str());
    if !out.ends_with('.') {
        out.push('.');
    }
    out
}

/// Runs one design command through the core: `command.schema` (`{id?}`: one command's fields, or
/// every schema) and `body.rename` (validated by [`rename_body`]) here, everything else in the
/// engine's registry.
pub fn execute(s: &mut Session, id: &str, p: &Value) -> Result<Value, String> {
    match id {
        "command.schema" => match p.get("id").and_then(Value::as_str) {
            Some(cmd) => Ok(schema(cmd).map_or(Value::Null, |f| json!(f))),
            None => Ok(schemas()),
        },
        "body.rename" => {
            let body = p.get("body").and_then(Value::as_str).ok_or("`body` must be a body name")?;
            let name = p.get("name").and_then(Value::as_str).ok_or("`name` must be the new name")?;
            rename_body(s, body, name)
        }
        _ => s.execute(id, p).map_err(|e| e.to_string()),
    }
}
