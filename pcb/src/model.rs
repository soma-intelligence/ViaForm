//! The data model: library, schematic, board, rules. Lengths in nanometres, angles in
//! millidegrees, ids are stable `u64` values from one counter per project (never reused).

use crate::geom::{MilliDeg, Nm, Pt};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub type Id = u64;

pub const FORMAT: &str = "viaform-pcb";
pub const FORMAT_VERSION: u32 = 1;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default, PartialOrd, Ord, Hash)]
#[serde(rename_all = "snake_case")]
pub enum PinKind {
    Input,
    Output,
    Bidirectional,
    TriState,
    #[default]
    Passive,
    Free,
    Unspecified,
    PowerIn,
    PowerOut,
    OpenCollector,
    OpenEmitter,
    NoConnect,
}

impl PinKind {
    pub fn parse(s: &str) -> PinKind {
        match s {
            "input" => PinKind::Input,
            "output" => PinKind::Output,
            "bidirectional" => PinKind::Bidirectional,
            "tri_state" => PinKind::TriState,
            "free" => PinKind::Free,
            "unspecified" => PinKind::Unspecified,
            "power_in" => PinKind::PowerIn,
            "power_out" => PinKind::PowerOut,
            "open_collector" => PinKind::OpenCollector,
            "open_emitter" => PinKind::OpenEmitter,
            "no_connect" => PinKind::NoConnect,
            _ => PinKind::Passive,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            PinKind::Input => "input",
            PinKind::Output => "output",
            PinKind::Bidirectional => "bidirectional",
            PinKind::TriState => "tri_state",
            PinKind::Passive => "passive",
            PinKind::Free => "free",
            PinKind::Unspecified => "unspecified",
            PinKind::PowerIn => "power_in",
            PinKind::PowerOut => "power_out",
            PinKind::OpenCollector => "open_collector",
            PinKind::OpenEmitter => "open_emitter",
            PinKind::NoConnect => "no_connect",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct SymbolPin {
    pub number: String,
    pub name: String,
    /// Connection point relative to the symbol origin (schematic, y up).
    pub position: Pt,
    pub kind: PinKind,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct SymbolDef {
    pub name: String,
    pub reference_prefix: String,
    pub value: String,
    pub description: String,
    /// Default footprint name in the project library.
    pub footprint: Option<String>,
    pub pins: Vec<SymbolPin>,
    /// Body half extents, for drawing.
    pub body: Pt,
    /// A power symbol names its net by its value (GND, 3V3...).
    #[serde(default)]
    pub power: bool,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum PadKind {
    Tht,
    Smd,
    Npth,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum PadShape {
    Circle,
    Rect,
    Oval,
    RoundRect,
}

impl PadShape {
    pub fn name(self) -> &'static str {
        match self {
            PadShape::Circle => "circle",
            PadShape::Rect => "rect",
            PadShape::Oval => "oval",
            PadShape::RoundRect => "roundrect",
        }
    }
    pub fn parse(s: &str) -> PadShape {
        match s {
            "rect" | "square" => PadShape::Rect,
            "oval" => PadShape::Oval,
            "roundrect" => PadShape::RoundRect,
            _ => PadShape::Circle,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct PadDef {
    pub number: String,
    pub kind: PadKind,
    pub shape: PadShape,
    /// Relative to the footprint origin (board, y down).
    pub offset: Pt,
    pub size: Pt,
    /// Rotation relative to the footprint.
    pub rotation: MilliDeg,
    pub drill: Option<Nm>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct FootprintDef {
    pub name: String,
    pub description: String,
    pub pads: Vec<PadDef>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
pub struct Library {
    pub symbols: BTreeMap<String, SymbolDef>,
    pub footprints: BTreeMap<String, FootprintDef>,
    /// Provenance notices, by symbol name.
    #[serde(default)]
    pub notices: BTreeMap<String, String>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Sheet {
    pub id: Id,
    pub name: String,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Component {
    pub id: Id,
    pub sheet: Id,
    pub reference: String,
    pub value: String,
    /// The built-in kind or the library symbol name.
    pub kind: String,
    pub symbol: String,
    pub footprint: Option<String>,
    pub position: Pt,
    pub rotation: MilliDeg,
    /// Pins marked "no connect" on purpose.
    #[serde(default)]
    pub no_connect: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug, PartialOrd, Ord, Hash)]
pub struct PinRef {
    pub component: Id,
    pub pin: String,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Wire {
    pub id: Id,
    pub from: PinRef,
    pub to: PinRef,
    /// Filled by netlist extraction.
    pub net: Id,
}

/// A net label attached to a pin: pins whose labels share a name are one net.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Label {
    pub id: Id,
    pub name: String,
    pub pin: PinRef,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Net {
    pub id: Id,
    pub name: String,
    /// Named by the user (net.create, a label, a power symbol) rather than by extraction.
    pub named: bool,
    /// Pins put on this net directly (net.connect).
    #[serde(default)]
    pub pins: Vec<PinRef>,
    #[serde(default)]
    pub class: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Side {
    Front,
    Back,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Pad {
    pub number: String,
    pub kind: PadKind,
    pub shape: PadShape,
    pub offset: Pt,
    pub size: Pt,
    pub rotation: MilliDeg,
    pub drill: Option<Nm>,
    pub net: Option<Id>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Footprint {
    pub id: Id,
    pub component: Id,
    pub name: String,
    pub position: Pt,
    pub rotation: MilliDeg,
    pub side: Side,
    pub pads: Vec<Pad>,
}

impl Footprint {
    /// Board position of a pad: mirrored in x on the back, then turned (KiCad convention).
    pub fn pad_position(&self, pad: &Pad) -> Pt {
        let o = if self.side == Side::Back { Pt::new(-pad.offset.x, pad.offset.y) } else { pad.offset };
        self.position.add(o.rotate_board(self.rotation))
    }
    pub fn pad_rotation(&self, pad: &Pad) -> MilliDeg {
        crate::geom::norm_mdeg(self.rotation + if self.side == Side::Back { -pad.rotation } else { pad.rotation })
    }
    /// Copper layers a pad sits on.
    pub fn pad_layers(&self, pad: &Pad) -> Vec<&'static str> {
        match pad.kind {
            PadKind::Tht => vec![FRONT_CU, BACK_CU],
            PadKind::Npth => vec![],
            PadKind::Smd => vec![if self.side == Side::Front { FRONT_CU } else { BACK_CU }],
        }
    }
}

pub const FRONT_CU: &str = "F.Cu";
pub const BACK_CU: &str = "B.Cu";
pub const COPPER: [&str; 2] = [FRONT_CU, BACK_CU];

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Track {
    pub id: Id,
    pub net: Id,
    pub start: Pt,
    pub end: Pt,
    pub width: Nm,
    pub layer: String,
    /// Made by the autorouter (it may rip these up again).
    #[serde(default)]
    pub auto: bool,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Via {
    pub id: Id,
    pub net: Id,
    pub at: Pt,
    pub diameter: Nm,
    pub drill: Nm,
    #[serde(default)]
    pub auto: bool,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Zone {
    pub id: Id,
    pub net: Id,
    pub layer: String,
    pub outline: Vec<Pt>,
    pub clearance: Nm,
    pub thermal_gap: Nm,
    pub spoke_width: Nm,
    pub min_width: Nm,
    /// Computed fill: shapes of outer ring plus holes.
    #[serde(default)]
    pub filled: Vec<Vec<Vec<Pt>>>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Keepout {
    pub id: Id,
    pub outline: Vec<Pt>,
    pub layers: Vec<String>,
    pub tracks: bool,
    pub vias: bool,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Cutout {
    pub id: Id,
    pub center: Pt,
    pub radius: Nm,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Board {
    pub width: Nm,
    pub height: Nm,
    /// Closed outline; a rectangle from (0, 0) to (width, height) unless set.
    pub outline: Vec<Pt>,
    pub thickness: Nm,
    pub cutouts: Vec<Cutout>,
    pub footprints: Vec<Footprint>,
    pub tracks: Vec<Track>,
    pub vias: Vec<Via>,
    pub zones: Vec<Zone>,
    pub keepouts: Vec<Keepout>,
}

impl Board {
    pub fn rect_outline(w: Nm, h: Nm) -> Vec<Pt> {
        vec![Pt::new(0, 0), Pt::new(w, 0), Pt::new(w, h), Pt::new(0, h)]
    }
}

impl Default for Board {
    fn default() -> Self {
        let (w, h) = (crate::geom::mm(50.0), crate::geom::mm(40.0));
        Board {
            width: w,
            height: h,
            outline: Board::rect_outline(w, h),
            thickness: crate::geom::mm(1.6),
            cutouts: vec![],
            footprints: vec![],
            tracks: vec![],
            vias: vec![],
            zones: vec![],
            keepouts: vec![],
        }
    }
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Rules {
    pub clearance: Nm,
    pub min_track_width: Nm,
    pub track_width: Nm,
    pub via_diameter: Nm,
    pub via_drill: Nm,
    pub min_annular_ring: Nm,
    pub min_drill: Nm,
    pub hole_to_hole: Nm,
    pub edge_clearance: Nm,
    /// Autorouter grid pitch.
    pub route_grid: Nm,
}

impl Default for Rules {
    fn default() -> Self {
        use crate::geom::mm;
        Rules {
            clearance: mm(0.2),
            min_track_width: mm(0.15),
            track_width: mm(0.3),
            via_diameter: mm(0.6),
            via_drill: mm(0.3),
            min_annular_ring: mm(0.13),
            min_drill: mm(0.2),
            hole_to_hole: mm(0.25),
            edge_clearance: mm(0.3),
            route_grid: mm(0.1),
        }
    }
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct NetClass {
    pub name: String,
    pub clearance: Nm,
    pub track_width: Nm,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Project {
    pub format: String,
    pub version: u32,
    pub name: String,
    pub next_id: Id,
    pub library: Library,
    pub sheets: Vec<Sheet>,
    pub components: Vec<Component>,
    pub wires: Vec<Wire>,
    pub labels: Vec<Label>,
    pub nets: Vec<Net>,
    pub board: Board,
    pub rules: Rules,
    pub net_classes: Vec<NetClass>,
}

impl Default for Project {
    fn default() -> Self {
        let mut p = Project {
            format: FORMAT.into(),
            version: FORMAT_VERSION,
            name: "Untitled".into(),
            next_id: 1,
            library: crate::library::builtin_library(),
            sheets: vec![],
            components: vec![],
            wires: vec![],
            labels: vec![],
            nets: vec![],
            board: Board::default(),
            rules: Rules::default(),
            net_classes: vec![],
        };
        let id = p.alloc();
        p.sheets.push(Sheet { id, name: "Root".into() });
        p
    }
}

impl Project {
    pub fn alloc(&mut self) -> Id {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
    pub fn component(&self, id: Id) -> Option<&Component> {
        self.components.iter().find(|c| c.id == id)
    }
    pub fn component_mut(&mut self, id: Id) -> Option<&mut Component> {
        self.components.iter_mut().find(|c| c.id == id)
    }
    pub fn footprint(&self, id: Id) -> Option<&Footprint> {
        self.board.footprints.iter().find(|f| f.id == id)
    }
    pub fn footprint_mut(&mut self, id: Id) -> Option<&mut Footprint> {
        self.board.footprints.iter_mut().find(|f| f.id == id)
    }
    pub fn net(&self, id: Id) -> Option<&Net> {
        self.nets.iter().find(|n| n.id == id)
    }
    pub fn net_name(&self, id: Id) -> String {
        self.net(id).map(|n| n.name.clone()).unwrap_or_default()
    }
    pub fn net_by_name(&self, name: &str) -> Option<&Net> {
        self.nets.iter().find(|n| n.name == name)
    }
    pub fn symbol_of(&self, c: &Component) -> Option<&SymbolDef> {
        self.library.symbols.get(&c.symbol)
    }
    /// Clearance and width for a net, from its class when it has one.
    pub fn net_rules(&self, net: Option<Id>) -> (Nm, Nm) {
        let class = net.and_then(|n| self.net(n)).and_then(|n| n.class.as_ref());
        match class.and_then(|c| self.net_classes.iter().find(|k| &k.name == c)) {
            Some(k) => (k.clearance.max(self.rules.clearance), k.track_width),
            None => (self.rules.clearance, self.rules.track_width),
        }
    }
}
