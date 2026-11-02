import Foundation

/// A modelling tool the front ends offer. Each one ends in engine commands; the front end only
/// gathers clicks and numbers.
enum Tool: String, CaseIterable, Identifiable {
    case select
    // Sketch
    case line, rectangle, centerRectangle, circle, arc, polygon, slot, spline, point
    case sketchFillet, trim, offset
    // Solid
    case sketch, extrude, revolve, pressPull, fillet, chamfer, shell
    case box, cylinder, sphere, torus
    case union, subtract, intersect
    case move, mirror, delete
    case measure

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: "Select"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .centerRectangle: "Center Rectangle"
        case .circle: "Circle"
        case .arc: "Arc"
        case .polygon: "Polygon"
        case .slot: "Slot"
        case .spline: "Spline"
        case .point: "Point"
        case .sketchFillet: "Sketch Fillet"
        case .trim: "Trim"
        case .offset: "Offset"
        case .sketch: "Sketch"
        case .extrude: "Extrude"
        case .revolve: "Revolve"
        case .pressPull: "Press Pull"
        case .fillet: "Fillet"
        case .chamfer: "Chamfer"
        case .shell: "Shell"
        case .box: "Box"
        case .cylinder: "Cylinder"
        case .sphere: "Sphere"
        case .torus: "Torus"
        case .union: "Union"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        case .move: "Move"
        case .mirror: "Mirror"
        case .delete: "Delete"
        case .measure: "Measure"
        }
    }

    /// SF Symbols only: no other product's artwork.
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .centerRectangle: "rectangle.center.inset.filled"
        case .circle: "circle"
        case .arc: "rainbow"
        case .polygon: "hexagon"
        case .slot: "capsule"
        case .spline: "scribble"
        case .point: "smallcircle.filled.circle"
        case .sketchFillet: "arrow.turn.down.right"
        case .trim: "scissors"
        case .offset: "square.on.square.dashed"
        case .sketch: "pencil.and.outline"
        case .extrude: "square.stack.3d.up"
        case .revolve: "arrow.triangle.2.circlepath"
        case .pressPull: "arrow.up.and.down.square"
        case .fillet: "square.dashed.inset.filled"
        case .chamfer: "skew"
        case .shell: "cube.transparent"
        case .box: "cube"
        case .cylinder: "cylinder"
        case .sphere: "circle.circle"
        case .torus: "circle.dotted.circle"
        case .union: "square.on.square"
        case .subtract: "minus.square"
        case .intersect: "square.on.square.intersection.dashed"
        case .move: "move.3d"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .delete: "trash"
        case .measure: "ruler"
        }
    }

    var isSketchTool: Bool {
        switch self {
        case .line, .rectangle, .centerRectangle, .circle, .arc, .polygon, .slot, .spline, .point, .sketchFillet, .trim, .offset: true
        default: false
        }
    }

    /// Clicks on the sketch plane the tool needs (0 = open-ended, finished by the user).
    var clicks: Int {
        switch self {
        case .rectangle, .centerRectangle, .circle, .polygon: 2
        case .arc, .slot: 3
        case .point: 1
        case .line, .spline: 0
        default: 0
        }
    }

    /// The numeric value the tool asks for, with its default (mm or degrees).
    var value: (label: String, unit: String, initial: Double)? {
        switch self {
        case .extrude: ("Distance", "mm", 10)
        case .pressPull: ("Distance", "mm", 5)
        case .revolve: ("Angle", "deg", 360)
        case .fillet: ("Radius", "mm", 2)
        case .chamfer: ("Distance", "mm", 1)
        case .shell: ("Thickness", "mm", 1.5)
        case .offset: ("Distance", "mm", 2)
        case .sketchFillet: ("Radius", "mm", 2)
        case .box: ("Size", "mm", 20)
        case .cylinder: ("Height", "mm", 20)
        case .sphere: ("Diameter", "mm", 20)
        case .torus: ("Major diameter", "mm", 30)
        case .polygon: ("Sides", "", 6)
        default: nil
        }
    }

    /// The engine command behind the tool, for its help text and its toolbar place.
    var commandID: String? {
        switch self {
        case .line: "sketch.line"
        case .rectangle: "sketch.rectangle.two_point"
        case .centerRectangle: "sketch.rectangle.center"
        case .circle: "sketch.circle.center"
        case .arc: "sketch.arc.three_point"
        case .polygon: "sketch.polygon.inscribed"
        case .slot: "sketch.slot.center_to_center"
        case .spline: "sketch.spline.fit_point"
        case .point: "sketch.point"
        case .sketchFillet: "sketch.fillet"
        case .trim: "sketch.trim"
        case .offset: "sketch.offset"
        case .sketch: "sketch.create"
        case .extrude: "solid.extrude"
        case .revolve: "solid.revolve"
        case .pressPull: "solid.press_pull"
        case .fillet: "solid.fillet"
        case .chamfer: "solid.chamfer"
        case .shell: "solid.shell"
        case .box: "solid.box"
        case .cylinder: "solid.cylinder"
        case .sphere: "solid.sphere"
        case .torus: "solid.torus"
        case .union, .subtract, .intersect: "solid.combine"
        case .move: "solid.move"
        case .mirror: "solid.mirror"
        case .delete: "solid.remove"
        case .measure: "inspect.measure"
        case .select: nil
        }
    }

    static let sketchTools: [Tool] = [.line, .rectangle, .centerRectangle, .circle, .arc, .polygon, .slot, .spline, .point, .sketchFillet, .trim, .offset]
    static let solidTools: [Tool] = [.sketch, .extrude, .revolve, .pressPull, .fillet, .chamfer, .shell]
    static let primitiveTools: [Tool] = [.box, .cylinder, .sphere, .torus]
    static let combineTools: [Tool] = [.union, .subtract, .intersect, .move, .mirror, .delete]
}

/// SF Symbol for an engine icon name (the registry's `icon`), for the generic ribbon.
enum CommandSymbol {
    static func of(_ icon: String, id: String) -> String {
        if let t = Tool.allCases.first(where: { $0.commandID == id }) { return t.symbol }
        let table: [String: String] = [
            "sketch": "pencil.and.outline", "extrude": "square.stack.3d.up", "revolve": "arrow.triangle.2.circlepath",
            "sweep": "point.topleft.down.to.point.bottomright.curvepath", "loft": "square.3.layers.3d", "hole": "circle.bottomhalf.filled",
            "thread": "screwdriver", "pattern_rect": "square.grid.3x3", "pattern_circ": "circle.grid.cross", "mirror": "arrow.left.and.right",
            "box": "cube", "cylinder": "cylinder", "sphere": "circle.circle", "torus": "circle.dotted.circle", "cone": "cone",
            "pipe": "point.topleft.down.to.point.bottomright.curvepath.fill", "coil": "tornado", "rib": "rectangle.split.3x1",
            "web": "rectangle.split.2x2", "emboss": "textformat", "draft": "trapezoid.and.line.vertical", "scale": "arrow.up.left.and.arrow.down.right",
            "split_face": "square.split.diagonal", "split_body": "square.split.2x1", "move": "move.3d", "align": "align.horizontal.center",
            "delete": "trash", "material": "paintpalette", "appearance": "paintbrush", "params": "function", "compute": "arrow.clockwise",
            "offset_face": "square.on.square", "replace_face": "square.on.square.dashed", "delete_face": "square.slash",
            "combine": "square.on.square", "joint_origin": "scope", "dimension": "ruler", "constrainer": "lock",
            "trim": "scissors", "extend": "arrow.right.to.line", "offset": "square.on.square.dashed", "project": "arrow.down.to.line",
            "line": "line.diagonal", "rect": "rectangle", "circle": "circle", "arc3": "rainbow", "polygon": "hexagon", "slot": "capsule",
            "spline": "scribble", "point": "smallcircle.filled.circle", "ellipse": "oval", "finish": "checkmark.circle",
        ]
        if let s = table[icon] { return s }
        let prefixes: [(String, String)] = [
            ("c_coincident", "smallcircle.filled.circle"), ("c_parallel", "equal"), ("c_perpendicular", "angle"),
            ("c_equal", "equal.circle"), ("c_fix", "lock"), ("c_tangent", "circle.and.line.horizontal"),
            ("c_hv", "arrow.up.and.down.and.arrow.left.and.right"), ("c_midpoint", "circle.lefthalf.filled"),
            ("c_symmetry", "arrow.left.and.right"), ("c_concentric", "circle.circle"), ("c_", "link"),
            ("plane", "rectangle.on.rectangle.angled"), ("axis", "line.diagonal.arrow"), ("point", "smallcircle.filled.circle"),
            ("surface_", "square.3.layers.3d"), ("render", "camera.aperture"), ("import", "square.and.arrow.down"),
            ("mesh_export", "square.and.arrow.up"), ("component", "shippingbox"), ("fastener", "screwdriver"),
            ("bom", "list.bullet.rectangle"), ("explode", "arrow.up.left.and.arrow.down.right"), ("play", "play.circle"),
            ("timeline_play", "play.circle"), ("trace", "point.bottomleft.forward.to.point.topright.scurvepath"),
            ("zebra", "rectangle.split.3x1"), ("section", "square.split.diagonal.2x2"), ("interference", "exclamationmark.triangle"),
            ("center_of_mass", "scope"), ("measure", "ruler"), ("canvas", "photo"), ("decal", "photo"), ("svg", "doc.richtext"),
            ("sketch_dxf", "doc.richtext"), ("configuration_table", "tablecells"), ("colored_components", "paintpalette"),
            ("boss", "cylinder"), ("lip", "square.on.square"), ("snap_fit", "paperclip"), ("rest", "square.bottomhalf.filled"),
            ("plastic", "drop"), ("sheet", "doc.plaintext"), ("flange", "rectangle.portrait.and.arrow.right"), ("hem", "arrow.uturn.down"),
            ("unfold", "doc"), ("fold", "doc.on.doc"), ("refold", "doc.on.doc"), ("flat", "doc"), ("perforate", "circle.grid.3x3"),
            ("convert_sheet", "doc.badge.gearshape"), ("path_flange", "rectangle.portrait.and.arrow.right"), ("frame_member", "rectangle.split.3x1"),
            ("joint", "link"), ("as_built", "link"), ("rigid_group", "lock.square.stack"), ("drive", "steeringwheel"),
            ("motion_link", "link.badge.plus"), ("gear", "gearshape.2"), ("rack_pinion", "gearshape"), ("screw", "screwdriver"),
            ("cam", "circle.bottomhalf.filled"), ("contact", "hand.point.up.left"), ("capture", "camera.viewfinder"),
            ("revert", "arrow.uturn.backward"), ("accessibility", "eye"), ("continuity", "waveform.path"), ("curvature", "waveform.path.ecg"),
            ("min_radius", "circle.dashed"), ("iso", "grid"), ("draft_analysis", "trapezoid.and.line.vertical"), ("environment_map", "globe"),
            ("inspect", "magnifyingglass"), ("auto_constrain", "wand.and.stars"), ("sketch_cancel", "xmark.circle"),
            ("sketch_mirror", "arrow.left.and.right"), ("sketch_rect_pattern", "square.grid.3x3"), ("sketch_circ_pattern", "circle.grid.cross"),
            ("sketch_text", "textformat"), ("sketch_scale", "arrow.up.left.and.arrow.down.right"), ("sketch_chamfer", "skew"),
            ("sketch_move", "move.3d"), ("sketch_break", "scissors"), ("conic", "point.topleft.down.to.point.bottomright.curvepath"),
            ("centerline", "line.diagonal"), ("construction", "line.diagonal"), ("equation_curve", "function"), ("include", "arrow.down.to.line"),
            ("intersect", "plus"), ("iso_curve", "grid"), ("spun", "arrow.triangle.2.circlepath"), ("fit_section", "waveform"),
            ("line_mid", "line.diagonal"), ("blend", "point.topleft.down.to.point.bottomright.curvepath"), ("settings", "gearshape"),
        ]
        if let hit = prefixes.first(where: { icon.hasPrefix($0.0) }) { return hit.1 }
        if icon.hasPrefix("construction_line") { return "line.diagonal.arrow" }
        if icon.hasPrefix("circle") { return "circle" }
        if icon.hasPrefix("rect") { return "rectangle" }
        if icon.hasPrefix("arc") { return "rainbow" }
        if icon.hasPrefix("polygon") { return "hexagon" }
        if icon.hasPrefix("slot") { return "capsule" }
        if icon.hasPrefix("sketch_") { return "pencil.line" }
        if id.hasPrefix("inspect.") { return "magnifyingglass" }
        if id.hasPrefix("joint.") { return "link" }
        if id.hasPrefix("surface.") { return "square.3.layers.3d.down.right" }
        if id.hasPrefix("sheet.") { return "doc.plaintext" }
        if id.hasPrefix("render.") { return "camera.aperture" }
        return "square.dashed"
    }
}
