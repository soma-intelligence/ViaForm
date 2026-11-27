import SwiftUI
import Observation

/// Shared prototype state. In the app this is the document model fed by bridge/.
@Observable
final class Studio {
    var workspace: Workspace = .design
    var sidebar: SidebarMode = .items
    var selection: String? = "index.middle"
    var activeTool: [Workspace: String] = [.design: "select", .generative: "load", .electronics: "route", .simulation: "play", .mechanics: "joint"]
    var palette = false
    var paletteQuery = ""
    var variant = 0
    var promotedVariant: Int? = nil
    var time: Double = 19.7
    var wind: Double = 0.62
    var gusts = true
    var playing = true
    var padItems = true
    var padHistory = false
    /// Headless render: AppKit-backed controls (TextField) are swapped for drawn stand-ins.
    var rendering = false

    init(workspace: Workspace = .design) { self.workspace = workspace }
}

enum Sample {
    // Design: robotic hand, palm, fingers, phalanges, motors per DOF
    static let handItems: [TreeNode] = [
        .init(id: "palm", name: "Palm", glyph: "folder", expandable: true),
        .init(id: "thumb", name: "Thumb", glyph: "folder", expandable: true),
        .init(id: "index", name: "Index finger", glyph: "folder", expandable: true, expanded: true),
        .init(id: "index.proximal", name: "Proximal", glyph: "cube", depth: 1),
        .init(id: "index.middle", name: "Middle", glyph: "cube", depth: 1),
        .init(id: "index.distal", name: "Distal", glyph: "cube", depth: 1),
        .init(id: "middle", name: "Middle finger", glyph: "folder", expandable: true),
        .init(id: "ring", name: "Ring finger", glyph: "folder", expandable: true),
        .init(id: "little", name: "Little finger", glyph: "folder", expandable: true),
        .init(id: "wrist", name: "Wrist mount", glyph: "cube"),
        .init(id: "motors", name: "Motors (15)", glyph: "gearshape", expandable: true)
    ]

    static let handHistory: [TreeNode] = [
        .init(id: "h1", name: "Sketch palm outline", glyph: "scribble.variable"),
        .init(id: "h2", name: "Extrude palm 14 mm", glyph: "cube"),
        .init(id: "h3", name: "Lattice palm, 3 mm cells", glyph: "square.on.square.dashed"),
        .init(id: "h4", name: "Pattern fingers x4", glyph: "square.on.square"),
        .init(id: "h5", name: "Fillet joints 2.0 mm", glyph: "vf.fillet"),
        .init(id: "h6", name: "Shell phalanges 1.2 mm", glyph: "cube.transparent"),
        .init(id: "h7", name: "Joint revolute x15", glyph: "link"),
        .init(id: "h8", name: "Insert M2 micro BLDC x15", glyph: "gearshape"),
        .init(id: "h9", name: "Regenerate index middle", glyph: "arrow.clockwise")
    ]

    static let phalanx: [(String, String)] = [
        ("Material", "Ti-6Al-4V"),
        ("Mass", "4.2 g"),
        ("Joint", "Revolute, 0 to 95 deg"),
        ("Motor", "M2 micro BLDC")
    ]

    static let padItems: [TreeNode] = [
        .init(id: "palm", name: "Palm", glyph: "cube", expandable: true),
        .init(id: "thumb", name: "Thumb", glyph: "cube", expandable: true),
        .init(id: "index", name: "Index finger", glyph: "cube", expandable: true),
        .init(id: "middle", name: "Middle finger", glyph: "cube", expandable: true),
        .init(id: "ring", name: "Ring finger", glyph: "cube", expandable: true),
        .init(id: "little", name: "Little finger", glyph: "cube", expandable: true),
        .init(id: "wrist", name: "Wrist mount", glyph: "cube", expandable: true)
    ]

    // Generative: 3-inch FPV frame study
    static let variants: [(Int, Double)] = [(14, 11.6), (31, 12.3), (52, 13.1), (67, 12.9), (71, 12.4), (73, 12.8)]

    // Simulation telemetry over a 60 s run, sampled at 1 Hz
    static func wave(_ n: Int, base: Double, amp: Double, f: Double, phase: Double = 0, drift: Double = 0) -> [Double] {
        (0..<n).map { i in
            let t = Double(i)
            return base + drift * t / Double(n) + amp * sin(t * f + phase) + amp * 0.35 * sin(t * f * 2.7 + phase * 1.3)
        }
    }
    static let altitude = wave(48, base: 1.0, amp: 0.12, f: 0.45, drift: 0.7)
    static let speed = wave(48, base: 7.0, amp: 0.55, f: 0.9, phase: 0.6)
    static let rpm: [[Double]] = (0..<4).map { k in wave(48, base: 21500 - Double(k) * 1900, amp: 900, f: 1.3 + Double(k) * 0.12, phase: Double(k)) }

    static let electronics: [TreeNode] = [
        .init(id: "sch", name: "Schematic", glyph: "doc"),
        .init(id: "pwr", name: "Power", glyph: "bolt", detail: "5V 3V3"),
        .init(id: "mcu", name: "MCU", glyph: "cpu"),
        .init(id: "imu", name: "IMU", glyph: "cpu"),
        .init(id: "esc", name: "ESC 4 in 1", glyph: "cpu")
    ]

    static let layers: [(String, Color)] = [
        ("Top", Color(hex: 0xE5534B)), ("Inner 1", Color(hex: 0xF2C14E)), ("Inner 2", Color(hex: 0x3DBE67)),
        ("Bottom", Color(hex: 0x3D7BF0)), ("Silk", .white)
    ]

    static let commands: [(String, String, String)] = [
        ("Extrude", "cube", "E"), ("Fillet", "vf.fillet", "F"), ("Move", "arrow.up.and.down.and.arrow.left.and.right", "M"),
        ("Joint", "link", "J"), ("Shell", "cube.transparent", ""), ("Generate study", "sparkles", ""),
        ("Route net", "point.topleft.down.to.point.bottomright.curvepath", ""), ("Run flight", "play.fill", ""),
        ("Show in 3D", "cube", ""), ("Export STEP", "square.and.arrow.up", "")
    ]
}
