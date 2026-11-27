import Foundation

// Contextual constraints (B-4): a pure mapping from the sketch selection (kinds, count, pick
// order) to every constraint the app offers, each enabled or not, with the engine calls it runs.
// Fusion keeps only the applicable constraints enabled, Shapr3D greys the others: surfaces list
// `SketchConstraintCatalog.entries(for:)` in this fixed order and grey the disabled ones, or show
// `valid(for:)` only. `DesignModel.applyConstraint(_:)` runs an entry (see SketchSelection.swift).

/// One constraint the selection may take.
struct SketchConstraintEntry: Identifiable {
    /// Stable id: "horizontal", "vertical", "coincident", "tangent", "equal", "parallel",
    /// "perpendicular", "collinear", "midpoint", "concentric", "symmetry", "curvature", "fix".
    let id: String
    let label: String
    /// SF Symbol (the same one the glyph on the canvas uses).
    let symbol: String
    /// The engine command, for routing a registry command to this entry.
    let command: String
    let enabled: Bool
    /// What runs, in order (one call per line for Horizontal on several lines). Empty when the
    /// entry is disabled, or when it waits for a third pick.
    let calls: [(command: String, params: [String: Any])]
    /// Symmetry with two picks: applying it asks for the symmetry line as the next pick.
    let awaitsThirdPick: Bool
}

enum SketchConstraintCatalog {
    /// Every entry, in the order the surfaces list them.
    static let order: [(id: String, command: String)] = [
        ("horizontal", "sketch.constraint.horizontal_vertical"), ("vertical", "sketch.constraint.horizontal_vertical"),
        ("coincident", "sketch.constraint.coincident"), ("tangent", "sketch.constraint.tangent"),
        ("equal", "sketch.constraint.equal"), ("parallel", "sketch.constraint.parallel"),
        ("perpendicular", "sketch.constraint.perpendicular"), ("collinear", "sketch.constraint.collinear"),
        ("midpoint", "sketch.constraint.midpoint"), ("concentric", "sketch.constraint.concentric"),
        ("symmetry", "sketch.constraint.symmetry"), ("curvature", "sketch.constraint.curvature"),
        ("fix", "sketch.constraint.fix"),
    ]

    /// Every entry for `picks`, enabled where the selection fits. Picked glyphs (constraints)
    /// take no constraint: any in the selection disables them all.
    static func entries(for picks: [SketchPick]) -> [SketchConstraintEntry] {
        order.map { entry($0.id, $0.command, picks) }
    }

    /// The enabled entries only.
    static func valid(for picks: [SketchPick]) -> [SketchConstraintEntry] {
        entries(for: picks).filter(\.enabled)
    }

    /// The entry a registry command id runs for `picks`, when the selection fits it
    /// (Horizontal/Vertical lets the engine choose the nearer one).
    static func entry(command: String, for picks: [SketchPick]) -> SketchConstraintEntry? {
        if command == "sketch.constraint.horizontal_vertical" {
            guard let h = entries(for: picks).first(where: { $0.id == "horizontal" }), h.enabled else { return nil }
            let calls = h.calls.map { c -> (command: String, params: [String: Any]) in
                var p = c.params
                p["mode"] = nil
                return (c.command, p)
            }
            return SketchConstraintEntry(id: "horizontal_vertical", label: String(localized: "Horizontal/Vertical"), symbol: symbol(for: "Horizontal"),
                                         command: command, enabled: true, calls: calls, awaitsThirdPick: false)
        }
        return entries(for: picks).first { $0.command == command && $0.enabled }
    }

    private static func entry(_ id: String, _ command: String, _ picks: [SketchPick]) -> SketchConstraintEntry {
        let geo = picks.filter { $0.kind != .constraint }
        let ok = geo.count == picks.count && !geo.isEmpty
        let ids = geo.map(\.id)
        let n = geo.count
        let points = geo.filter { $0.kind == .point }.count
        let lines = geo.filter { $0.kind == .line }.count
        let round = geo.filter { $0.kind == .circle || $0.kind == .arc }.count
        let other = geo.filter { $0.kind == .curve }.count
        let pair: [String: Any] = n == 2 ? ["a": ids[0], "b": ids[1]] : [:]
        var calls: [(command: String, params: [String: Any])] = []
        var waits = false
        if ok {
            switch id {
            case "horizontal", "vertical":
                if lines == n {
                    calls = ids.map { (command, ["line": $0, "mode": id]) }
                } else if n == 2, points == 2 {
                    calls = [(command, ["points": ids, "mode": id])]
                }
            case "coincident":
                if n == 2, points >= 1 { calls = [(command, pair)] }
            case "tangent":
                if n == 2, points == 0, lines < 2 { calls = [(command, pair)] }
            case "equal":
                if n >= 2, lines == n || round == n { calls = [(command, ["curves": ids])] }
            case "parallel", "perpendicular", "collinear":
                if n == 2, lines == 2 { calls = [(command, pair)] }
            case "midpoint":
                if n == 2, (points == 1 && lines == 1) || lines == 2 { calls = [(command, pair)] }
            case "concentric":
                if n == 2, round == 2 || (round == 1 && points == 1) { calls = [(command, pair)] }
            case "symmetry":
                let firstTwo = geo.prefix(2)
                let samePair = firstTwo.count == 2 && (firstTwo.allSatisfy { $0.kind == .point } || firstTwo.allSatisfy { $0.kind != .point })
                if n == 3, samePair, geo[2].kind == .line || geo[2].kind == .point {
                    var p: [String: Any] = ["a": ids[0], "b": ids[1]]
                    p[geo[2].kind == .line ? "line" : "point"] = ids[2]
                    calls = [(command, p)]
                } else if n == 2, samePair {
                    waits = true
                }
            case "curvature":
                if n == 2, points == 0, lines < 2, round + other >= 1 { calls = [(command, pair)] }
            case "fix":
                calls = [(command, ["entities": ids])]
            default:
                break
            }
        }
        return SketchConstraintEntry(id: id, label: label(id), symbol: symbol(forEntry: id), command: command,
                                     enabled: !calls.isEmpty || waits, calls: calls, awaitsThirdPick: waits)
    }

    static func label(_ id: String) -> String {
        switch id {
        case "horizontal": String(localized: "Horizontal")
        case "vertical": String(localized: "Vertical")
        case "coincident": String(localized: "Coincident")
        case "tangent": String(localized: "Tangent")
        case "equal": String(localized: "Equal")
        case "parallel": String(localized: "Parallel")
        case "perpendicular": String(localized: "Perpendicular")
        case "collinear": String(localized: "Collinear")
        case "midpoint": String(localized: "Midpoint")
        case "concentric": String(localized: "Concentric")
        case "symmetry": String(localized: "Symmetry")
        case "curvature": String(localized: "Curvature")
        case "fix": String(localized: "Fix/Unfix")
        default: id
        }
    }

    private static func symbol(forEntry id: String) -> String {
        switch id {
        case "horizontal": symbol(for: "Horizontal")
        case "vertical": symbol(for: "Vertical")
        case "midpoint": symbol(for: "MidPoint")
        case "curvature": symbol(for: "Smooth")
        default: symbol(for: id.prefix(1).uppercased() + id.dropFirst())
        }
    }

    /// The SF Symbol for a constraint kind as the engine names it (`sketch.glyphs` `name`).
    static func symbol(for name: String) -> String {
        switch name {
        case "Horizontal": "arrow.left.and.right"
        case "Vertical": "arrow.up.and.down"
        case "Coincident": "smallcircle.filled.circle"
        case "Parallel": "pause"
        case "Perpendicular": "angle"
        case "Collinear": "ellipsis"
        case "Tangent": "circle.and.line.horizontal"
        case "Equal": "equal"
        case "Concentric": "circle.circle"
        case "MidPoint": "circle.lefthalf.filled"
        case "Symmetry": "align.horizontal.center"
        case "Fix": "lock.fill"
        case "Smooth": "waveform.path"
        case "Pattern": "square.grid.3x3"
        default: "link"
        }
    }
}
