import SwiftUI

// MARK: - Workspaces and ribbon

struct RibbonPanel: Identifiable {
    var id: String { title }
    let title: String
    let glyphs: [Glyph]
    let commands: [String]
}

enum Workspace: Int, CaseIterable, Identifiable {
    case design, generative, mechanics, electronics, simulation, training, render, manufacture

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .design: "Design"
        case .generative: "Generative"
        case .mechanics: "Mechanics"
        case .electronics: "Electronics"
        case .simulation: "Simulation"
        case .training: "Training"
        case .render: "Render"
        case .manufacture: "Manufacture"
        }
    }

    var symbol: String {
        switch self {
        case .design: "cube"
        case .generative: "point.3.connected.trianglepath.dotted"
        case .mechanics: "gearshape.2"
        case .electronics: "cpu"
        case .simulation: "wind"
        case .training: "brain"
        case .render: "camera.aperture"
        case .manufacture: "printer"
        }
    }

    var tint: Color {
        switch self {
        case .design: VF.accent
        case .generative: Color(hex: 0x6E4BEA)
        case .mechanics: Color(hex: 0xE5781F)
        case .electronics: Color(hex: 0x1E9E5A)
        case .simulation: Color(hex: 0x0091C2)
        case .training: Color(hex: 0xD6336C)
        case .render: Color(hex: 0xC9921A)
        case .manufacture: Color(hex: 0x6B5A4E)
        }
    }

    var tabs: [String] {
        switch self {
        case .design: ["SOLID", "SURFACE", "MESH", "SHEET METAL", "PLASTIC", "UTILITIES"]
        case .generative: ["DEFINE", "STUDY", "EXPLORE"]
        case .mechanics: ["ASSEMBLE", "MOTION", "DRIVES"]
        case .electronics: ["SCHEMATIC", "PCB", "3D BOARD", "LIBRARY"]
        case .simulation: ["FLIGHT", "SCENARIO", "RESULTS"]
        case .training: ["POLICY", "CURRICULUM", "RUNS"]
        case .render: ["SCENE", "IN CANVAS", "GALLERY"]
        case .manufacture: ["SETUP", "TOOLPATH", "ADDITIVE", "EXPORT"]
        }
    }

    var panels: [RibbonPanel] {
        switch self {
        case .design:
            [RibbonPanel(title: "CREATE", glyphs: [.tool("sketch"), .tool("extrude"), .tool("revolve")],
                         commands: ["Create Sketch", "Extrude", "Revolve", "Sweep", "Loft", "Box", "Cylinder", "Pattern", "Mirror"]),
             RibbonPanel(title: "MODIFY", glyphs: [.tool("presspull"), .tool("fillet"), .tool("shell")],
                         commands: ["Press Pull", "Fillet", "Chamfer", "Shell", "Draft", "Combine", "Split Body", "Move / Copy"]),
             RibbonPanel(title: "ASSEMBLE", glyphs: [.tool("component"), .tool("joint"), .tool("rigid_group")],
                         commands: ["New Component", "Joint", "As-built Joint", "Rigid Group", "Drive Joints", "Motion Link"]),
             RibbonPanel(title: "CONSTRUCT", glyphs: [.tool("plane"), .tool("plane_angle"), .tool("axis_through_cylinder")],
                         commands: ["Offset Plane", "Plane at Angle", "Midplane", "Axis Through Cylinder", "Point at Vertex"]),
             RibbonPanel(title: "INSPECT", glyphs: [.tool("measure"), .tool("interference"), .tool("section")],
                         commands: ["Measure", "Interference", "Section Analysis", "Center of Mass", "Draft Analysis"]),
             RibbonPanel(title: "INSERT", glyphs: [.tool("import"), .tool("fastener"), .tool("library")],
                         commands: ["Insert Mesh", "Insert Fastener", "Part Library", "Insert Motor", "Decal"]),
             RibbonPanel(title: "SELECT", glyphs: [.tool("select")],
                         commands: ["Window Selection", "Paint Selection", "Select Through", "Selection Filters"])]
        case .generative:
            [RibbonPanel(title: "DESIGN SPACE", glyphs: [.tool("box"), .tool("delete")],
                         commands: ["Preserve Geometry", "Obstacle Geometry", "Starting Shape", "Obstacle Offset"]),
             RibbonPanel(title: "LOADS", glyphs: [.symbol("arrow.down.to.line"), .symbol("arrow.clockwise"), .tool("mount")],
                         commands: ["Structural Load", "Moment", "Bearing Load", "Remote Load", "Gravity"]),
             RibbonPanel(title: "CONSTRAINTS", glyphs: [.tool("joint"), .tool("rigid_group"), .tool("axis_through_cylinder")],
                         commands: ["Fixed", "Pin", "Frictionless", "Remote Constraint"]),
             RibbonPanel(title: "MATERIALS", glyphs: [.tool("library"), .tool("cube3d")],
                         commands: ["Study Materials", "Manage Physical Material"]),
             RibbonPanel(title: "OBJECTIVES", glyphs: [.symbol("scope"), .symbol("chart.bar.fill")],
                         commands: ["Minimize Mass", "Maximize Stiffness", "Safety Factor", "Displacement Limit"]),
             RibbonPanel(title: "GENERATE", glyphs: [.symbol("point.3.filled.connected.trianglepath.dotted"), .symbol("play.fill")],
                         commands: ["Preview", "Generate", "Generate Locally", "Generate on Cluster"]),
             RibbonPanel(title: "EXPLORE", glyphs: [.symbol("magnifyingglass"), .tool("cube3d")],
                         commands: ["Explore Outcomes", "Compare", "Create Design from Outcome"])]
        case .electronics:
            [RibbonPanel(title: "PLACE", glyphs: [.tool("cube3d"), .tool("board"), .tool("point_vertex")],
                         commands: ["Place Part", "Place Board", "Place Via", "Place Mounting Hole", "Align"]),
             RibbonPanel(title: "ROUTE", glyphs: [.symbol("point.topleft.down.to.point.bottomright.curvepath.fill"), .symbol("smallcircle.filled.circle"), .symbol("pencil.line")],
                         commands: ["Route Trace", "Differential Pair", "Via", "Polygon Pour", "Ripup"]),
             RibbonPanel(title: "RULES", glyphs: [.symbol("doc.text.fill"), .symbol("checkmark.shield.fill")],
                         commands: ["Design Rules", "Run DRC", "Run ERC", "Net Classes"]),
             RibbonPanel(title: "OUTPUT", glyphs: [.symbol("doc.badge.gearshape.fill"), .symbol("list.bullet.rectangle.fill")],
                         commands: ["Gerber and Drill", "Pick and Place", "Bill of Materials", "Fab Drawing"]),
             RibbonPanel(title: "3D LINK", glyphs: [.tool("cube3d"), .symbol("link")],
                         commands: ["Push to 3D", "Pull Outline from 3D", "Link to Component", "Unlink"])]
        case .simulation:
            [RibbonPanel(title: "SCENARIO", glyphs: [.tool("library")],
                         commands: ["Obstacle Course", "Hover Test", "Gust Rejection", "New Scenario"]),
             RibbonPanel(title: "ENVIRONMENT", glyphs: [.symbol("sun.max.fill"), .symbol("cloud.fill"), .symbol("wind")],
                         commands: ["Wind Field", "Gusting", "Air Density", "Lighting", "Terrain"]),
             RibbonPanel(title: "CONTROLLER", glyphs: [.symbol("gamecontroller.fill"), .symbol("slider.horizontal.3")],
                         commands: ["PID", "Trained Policy", "Manual (Gamepad)", "Tune Gains"]),
             RibbonPanel(title: "RUN", glyphs: [.symbol("play.fill"), .symbol("arrow.trianglehead.2.clockwise")],
                         commands: ["Run", "Run Batch (12)", "Replay", "Stop"]),
             RibbonPanel(title: "RESULTS", glyphs: [.symbol("chart.bar.fill"), .symbol("waveform.path.ecg")],
                         commands: ["Telemetry", "Compare Runs", "Export CSV", "Crash Loads to Study"])]
        case .mechanics:
            [RibbonPanel(title: "JOINTS", glyphs: [.tool("joint"), .tool("as_built"), .tool("rigid_group")], commands: ["Joint", "As-built Joint", "Rigid Group"]),
             RibbonPanel(title: "DRIVES", glyphs: [.tool("cylinder"), .tool("mount")], commands: ["Motor per DOF", "Tendon Route", "Gear Ratio"]),
             RibbonPanel(title: "MOTION", glyphs: [.symbol("play.fill"), .tool("interference")], commands: ["Motion Study", "Contact Sets", "Range of Motion"])]
        case .training:
            [RibbonPanel(title: "POLICY", glyphs: [.symbol("brain"), .tool("configuration_table")], commands: ["New Policy", "Observation Space", "Reward"]),
             RibbonPanel(title: "TRAIN", glyphs: [.symbol("play.fill"), .symbol("chart.xyaxis.line")], commands: ["Start Training", "Curriculum", "Resume"])]
        case .render:
            [RibbonPanel(title: "SETUP", glyphs: [.tool("cube3d"), .symbol("sun.max.fill")], commands: ["Appearance", "Environment", "Decal"]),
             RibbonPanel(title: "RENDER", glyphs: [.tool("capture"), .symbol("camera.fill")], commands: ["In-canvas Render", "Render", "Turntable"])]
        case .manufacture:
            [RibbonPanel(title: "SETUP", glyphs: [.tool("box"), .tool("plane")], commands: ["New Setup", "Stock", "WCS"]),
             RibbonPanel(title: "ADDITIVE", glyphs: [.tool("shell"), .symbol("printer.fill")], commands: ["Orient", "Supports", "Slice"]),
             RibbonPanel(title: "EXPORT", glyphs: [.tool("import"), .symbol("square.and.arrow.up.fill")], commands: ["Post Process", "Export 3MF", "Export STEP"])]
        }
    }
}

// MARK: - Browser tree

struct TreeRow: Identifiable {
    let id = UUID()
    var level = 0
    var name: String
    var detail: String? = nil
    var glyph: String = "folder.fill"
    var expanded: Bool? = false
    var eye = true
    var selected = false
}

enum Sample {
    static let handTree: [TreeRow] = [
        TreeRow(level: 0, name: "Robotic Hand v12", glyph: "cube.fill", expanded: true, eye: false),
        TreeRow(level: 1, name: "Document Settings", glyph: "gearshape.fill", eye: false),
        TreeRow(level: 1, name: "Named Views", glyph: "cube.transparent", eye: false),
        TreeRow(level: 1, name: "Origin", glyph: "folder.fill", eye: false),
        TreeRow(level: 1, name: "Palm", glyph: "folder.fill"),
        TreeRow(level: 1, name: "Thumb", glyph: "folder.fill"),
        TreeRow(level: 1, name: "Index Finger", glyph: "folder.fill", selected: true),
        TreeRow(level: 1, name: "Middle Finger", glyph: "folder.fill"),
        TreeRow(level: 1, name: "Ring Finger", glyph: "folder.fill"),
        TreeRow(level: 1, name: "Little Finger", glyph: "folder.fill"),
        TreeRow(level: 1, name: "Motors (15)", glyph: "gearshape.fill"),
        TreeRow(level: 1, name: "Tendons", glyph: "link"),
        TreeRow(level: 1, name: "Joints", glyph: "angle"),
    ]

    static let studyTree: [TreeRow] = [
        TreeRow(level: 0, name: "Drone Frame Study 2", glyph: "cube.fill", expanded: true, eye: false),
        TreeRow(level: 1, name: "Preserve Geometry", glyph: "folder.fill"),
        TreeRow(level: 1, name: "Obstacle Geometry", glyph: "folder.fill"),
        TreeRow(level: 1, name: "Starting Shape", glyph: "cube.fill"),
        TreeRow(level: 1, name: "Load Cases", glyph: "arrow.down.to.line", expanded: true),
        TreeRow(level: 2, name: "Hover", glyph: "arrow.down", expanded: nil),
        TreeRow(level: 2, name: "Punch Out", glyph: "arrow.down", expanded: nil),
        TreeRow(level: 2, name: "Crash 6 g", glyph: "arrow.down", expanded: nil),
        TreeRow(level: 1, name: "Materials", glyph: "cube.fill", expanded: true),
        TreeRow(level: 2, name: "Carbon Nylon", glyph: "cube", expanded: nil),
        TreeRow(level: 2, name: "Aluminium 7075", glyph: "cube", expanded: nil),
        TreeRow(level: 1, name: "Outcomes (24)", glyph: "point.3.connected.trianglepath.dotted", eye: false),
    ]

    static let simTree: [TreeRow] = [
        TreeRow(level: 0, name: "Scenario", detail: "Obstacle Course", glyph: "square.stack.3d.up.fill", expanded: true),
        TreeRow(level: 0, name: "Environment", detail: "Wind 6 m/s Gusting", glyph: "cloud.fill"),
        TreeRow(level: 0, name: "Gates (8)", glyph: "square.dashed"),
        TreeRow(level: 0, name: "Vehicle", detail: "FPV Drone 3in", glyph: "airplane"),
        TreeRow(level: 0, name: "Controller", detail: "PID", glyph: "gamecontroller.fill"),
        TreeRow(level: 0, name: "Runs (12)", glyph: "play.fill"),
    ]

    static let itemsTouch: [String] = ["Palm", "Thumb", "Index Finger", "Middle Finger", "Ring Finger", "Little Finger", "Motors"]

    // MARK: Timeline

    enum FeatureKind: String {
        case sketch = "Sketch", extrude = "Extrude", fillet = "Fillet", hole = "Hole", joint = "Joint",
             chamfer = "Chamfer", revolve = "Revolve", shell = "Shell", pattern = "Pattern"
        var icon: String {
            switch self {
            case .sketch: "sketch"
            case .extrude: "extrude"
            case .fillet: "fillet"
            case .hole: "hole"
            case .joint: "joint"
            case .chamfer: "chamfer"
            case .revolve: "revolve"
            case .shell: "shell"
            case .pattern: "configuration_table"
            }
        }
    }

    static let handHistory: [FeatureKind] = [.sketch, .extrude, .extrude, .fillet, .extrude, .hole, .extrude, .fillet,
                                             .sketch, .extrude, .extrude, .fillet, .joint, .extrude, .extrude, .fillet,
                                             .joint, .joint, .extrude, .extrude, .fillet, .chamfer, .shell]
    static let droneHistory: [FeatureKind] = [.sketch, .extrude, .extrude, .fillet, .extrude, .joint, .extrude, .fillet,
                                              .extrude, .hole, .joint, .extrude, .sketch, .extrude, .fillet, .extrude,
                                              .hole, .fillet, .joint, .extrude, .fillet, .chamfer]
    static let boardHistory: [FeatureKind] = [.sketch, .extrude, .fillet, .joint, .extrude, .fillet, .sketch, .extrude,
                                              .joint, .fillet, .hole, .extrude, .chamfer]

    // MARK: Generative outcomes

    struct Outcome: Identifiable {
        let id: Int
        let mass: Double
        let sf: Double
        let image: Int
    }

    static let outcomes: [Outcome] = [
        Outcome(id: 7, mass: 11.0, sf: 2.2, image: 0), Outcome(id: 11, mass: 12.4, sf: 1.8, image: 1),
        Outcome(id: 14, mass: 13.7, sf: 2.5, image: 2), Outcome(id: 18, mass: 10.8, sf: 2.0, image: 3),
        Outcome(id: 22, mass: 12.1, sf: 2.3, image: 4), Outcome(id: 26, mass: 14.9, sf: 1.9, image: 5),
    ]

    static let scatter: [(Double, Double)] = {
        var g = Rng(seed: 7)
        return (0..<26).map { _ in (9.2 + g.next() * 6.4, 1.6 + g.next() * 1.0) }
    }()

    // MARK: Telemetry (25 s run, 10 Hz)

    struct Sample1: Identifiable { let id = UUID(); let t: Double; let v: Double; let series: String }

    static let telemetryT: [Double] = stride(from: 0.0, through: 25.0, by: 0.1).map { $0 }

    static func series(_ name: String, base: Double, amp: Double, freq: Double, noise: Double, seed: UInt64, until: Double = 25) -> [Sample1] {
        var g = Rng(seed: seed)
        return telemetryT.filter { $0 <= until }.map { t in
            Sample1(t: t, v: base + amp * sin(t * freq + Double(seed)) + (g.next() - 0.5) * noise, series: name)
        }
    }

    static let altitude: [Sample1] = {
        var g = Rng(seed: 3)
        return telemetryT.map { t in
            let rise = min(1, t / 3) * 2.9
            return Sample1(t: t, v: rise + 0.25 * sin(t * 0.9) + (g.next() - 0.5) * 0.25, series: "Alt")
        }
    }()
    static let attitude: [Sample1] = series("Roll", base: 0, amp: 9, freq: 1.7, noise: 14, seed: 4)
        + series("Pitch", base: 0, amp: 7, freq: 1.3, noise: 12, seed: 5)
        + series("Yaw", base: 2, amp: 5, freq: 0.6, noise: 6, seed: 6)
    static let motors: [Sample1] = ["M1", "M2", "M3", "M4"].enumerated().flatMap { i, m in
        series(m, base: 9650 + Double(i) * 90, amp: 300, freq: 0.8, noise: 800, seed: UInt64(10 + i))
    }
    static let battery: [Sample1] = telemetryT.map { t in Sample1(t: t, v: 12.6 - t * 0.035 + 0.04 * sin(t * 3), series: "V") }
}

/// Small deterministic generator so every render is identical.
struct Rng {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}
