import Foundation
import Observation
import simd

// Typed options for the feature tools (B-7), editing a feature in its own dialog (M-2), the
// Extrude auto Cut and Objects To Cut (M-4), and the touch tool modes (T-10).
//
// The model (`DesignModel`) previews a tool's plain command on a checkpoint. When the dialog
// asks for more than the plain command carries (Symmetric, Through All, To Object, a taper, a
// G2 fillet, cut targets...), the session takes the preview over: it drops the model's preview
// and runs the full command on a checkpoint of its own, so the feature stays one undo step.
// Editing a feature runs `timeline.edit` on a checkpoint the same way. Every action is an engine
// command; the session only gathers the options.

/// The options a feature dialog shows beside its value, in Fusion's field order.
struct FeatureOptions: Equatable {
    /// One Side, Two Sides, or Symmetric about the sketch plane.
    enum Direction: String, CaseIterable, Identifiable {
        case oneSide, twoSides, symmetric
        var id: String { rawValue }
        var title: String {
            switch self {
            case .oneSide: String(localized: "One Side")
            case .twoSides: String(localized: "Two Sides")
            case .symmetric: String(localized: "Symmetric")
            }
        }
    }

    /// Where the feature ends: a distance (or angle), a picked face, or through everything.
    enum Extent: String, CaseIterable, Identifiable {
        case distance, toObject, all
        var id: String { rawValue }
        func title(revolve: Bool) -> String {
            switch self {
            case .distance: revolve ? String(localized: "Angle") : String(localized: "Distance")
            case .toObject: String(localized: "To Object")
            case .all: String(localized: "All")
            }
        }
    }

    /// Thin Extrude: where the wall sits against the sketch curves (Fusion's Side 1, Center, Side 2).
    enum WallLocation: String, CaseIterable, Identifiable {
        case inside, center, outside
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inside: String(localized: "Side 1")
            case .center: String(localized: "Center")
            case .outside: String(localized: "Side 2")
            }
        }
    }

    enum FilletType: String, CaseIterable, Identifiable {
        case constant, curvature, chord
        var id: String { rawValue }
        var title: String {
            switch self {
            case .constant: String(localized: "Constant Radius")
            case .curvature: String(localized: "Curvature (G2)")
            case .chord: String(localized: "Chord Length")
            }
        }
    }

    enum ChamferType: String, CaseIterable, Identifiable {
        case equal, twoDistances, distanceAngle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .equal: String(localized: "Equal Distance")
            case .twoDistances: String(localized: "Two Distances")
            case .distanceAngle: String(localized: "Distance and Angle")
            }
        }
    }

    enum ShellDirection: String, CaseIterable, Identifiable {
        case inside, outside, both
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inside: String(localized: "Inside")
            case .outside: String(localized: "Outside")
            case .both: String(localized: "Both")
            }
        }
    }

    // Extrude and Revolve
    var direction: Direction = .oneSide
    var extent: Extent = .distance
    /// Two Sides: the other side's distance (mm) or angle (degrees).
    var second: Double = 10
    /// Extrude taper angle in degrees (positive grows the profile).
    var taper: Double = 0
    /// To Object: a point on the face the feature ends at.
    var toPoint: [Double]?
    /// Objects To Cut (or join, or intersect): empty takes every body.
    var targets: [String] = []
    /// Thin Extrude: a wall along the sketch curves instead of the profiles.
    var thin = false
    var wallLocation: WallLocation = .center
    var wallThickness: Double = 1
    // Fillet
    var filletType: FilletType = .constant
    // Chamfer
    var chamferType: ChamferType = .equal
    var chamferDistance2: Double = 1
    var chamferAngle: Double = 45
    var flip = false
    // Fillet, Chamfer, Shell
    var tangentChain = true
    // Shell
    var shellDirection: ShellDirection = .inside

    /// The tools that have typed options.
    static let tools: Set<Tool> = [.extrude, .revolve, .fillet, .chamfer, .shell]

    /// What a fresh dialog shows for `tool`.
    static func defaults(for tool: Tool) -> FeatureOptions {
        var o = FeatureOptions()
        // Shell opens only the picked faces by default; blends follow tangent chains.
        if tool == .shell { o.tangentChain = false }
        if tool == .revolve { o.second = 90 }
        return o
    }

    /// True when the plain tool command (`DesignModel`'s preview) already says everything.
    func isDefault(for tool: Tool) -> Bool { self == Self.defaults(for: tool) }

    /// The options ask for a picked face that is not there yet.
    func missingInput(for tool: Tool) -> String? {
        if (tool == .extrude || tool == .revolve), extent == .toObject, toPoint == nil {
            return String(localized: "Pick the face to end at")
        }
        return nil
    }

    // MARK: Commands

    /// The full command a new feature runs: the model's own inputs (value, profiles, picks,
    /// operation, axis) plus these options.
    func command(tool: Tool, value: Double, operation: String, profiles: [Int], axis: String,
                 edges: [[Double]], faces: [[Double]]) -> (String, [String: Any])? {
        switch tool {
        case .extrude:
            var p: [String: Any] = [:]
            switch extent {
            case .all: p["through_all"] = true
            case .toObject:
                guard let toPoint else { return nil }
                p["to"] = toPoint
            case .distance: p["distance"] = value
            }
            switch direction {
            case .oneSide: break
            case .symmetric: p["direction"] = "symmetric"
            case .twoSides: p["distance2"] = second
            }
            if taper != 0 { p["taper"] = Self.deg(taper) }
            if operation != "auto" { p["operation"] = operation }
            if thin {
                // A thin extrude follows the sketch's curves; it takes no profiles.
                p["thin"] = true
                p["thickness"] = wallThickness
                if wallLocation != .center { p["side"] = wallLocation.rawValue }
            } else if !profiles.isEmpty {
                p["profiles"] = profiles
            }
            if !targets.isEmpty { p["targets"] = targets }
            return ("solid.extrude", p)
        case .revolve:
            var p: [String: Any] = ["axis": axis]
            switch extent {
            case .toObject:
                guard let toPoint else { return nil }
                p["to"] = toPoint
            case .all: p["angle"] = Self.deg(360)
            case .distance: p["angle"] = Self.deg(value)
            }
            switch direction {
            case .oneSide: break
            case .symmetric: p["direction"] = "symmetric"
            case .twoSides: p["angle2"] = Self.deg(second)
            }
            if operation != "auto" { p["operation"] = operation }
            if !targets.isEmpty { p["targets"] = targets }
            return ("solid.revolve", p)
        case .fillet:
            guard !edges.isEmpty else { return nil }
            var p: [String: Any] = ["edges": edges, "radius": value]
            if filletType != .constant { p["type"] = filletType.rawValue }
            if !tangentChain { p["tangent_chain"] = false }
            return ("solid.fillet", p)
        case .chamfer:
            guard !edges.isEmpty else { return nil }
            var p: [String: Any] = ["edges": edges, "distance": value]
            switch chamferType {
            case .equal: break
            case .twoDistances: p["distance2"] = chamferDistance2
            case .distanceAngle: p["angle"] = Self.deg(chamferAngle)
            }
            if flip { p["flip"] = true }
            if !tangentChain { p["tangent_chain"] = false }
            return ("solid.chamfer", p)
        case .shell:
            guard !faces.isEmpty else { return nil }
            var p: [String: Any] = ["faces": faces, "thickness": value]
            if shellDirection != .inside { p["direction"] = shellDirection.rawValue }
            if tangentChain { p["tangent_chain"] = true }
            return ("solid.shell", p)
        default:
            return nil
        }
    }

    /// The fields of a feature definition (as `timeline.inspect` returns it) these options set,
    /// by dotted key, for `timeline.edit`. `NSNull` clears an optional field.
    func definitionFields(tool: Tool) -> [String: Any] {
        var s: [String: Any] = [:]
        let none = NSNull()
        switch tool {
        case .extrude:
            s["extent.direction"] = direction == .symmetric ? "symmetric" : "positive"
            s["extent.distance2"] = direction == .twoSides ? second as Any : none
            s["extent.through_all"] = extent == .all
            if extent == .toObject, let toPoint { s["extent.to"] = toPoint } else { s["extent.to"] = none }
            s["extent.taper"] = taper != 0 ? Self.deg(taper) : none
            s["targets"] = targets
            if thin {
                s["thin.thickness"] = wallThickness
                s["thin.side"] = wallLocation.rawValue
            }
        case .revolve:
            s["symmetric"] = direction == .symmetric
            s["angle2"] = direction == .twoSides ? Self.deg(second) : none
            if extent == .toObject, let toPoint { s["to"] = toPoint } else { s["to"] = none }
            s["targets"] = targets
        case .fillet:
            s["style"] = ["type": filletType.rawValue]
            s["tangent_chain"] = tangentChain
        case .chamfer:
            s["distance2"] = chamferType == .twoDistances ? chamferDistance2 as Any : none
            s["angle"] = chamferType == .distanceAngle ? Self.deg(chamferAngle) : none
            s["flip"] = flip
            s["tangent_chain"] = tangentChain
        case .shell:
            s["direction"] = shellDirection == .inside ? "" : shellDirection.rawValue
            s["tangent_chain"] = tangentChain
        default:
            break
        }
        return s
    }

    /// Reads the options back from a feature definition (Edit Feature opens on them).
    static func from(definition d: [String: Any], tool: Tool) -> FeatureOptions {
        var o = defaults(for: tool)
        switch tool {
        case .extrude:
            let e = d["extent"] as? [String: Any] ?? [:]
            if e["direction"] as? String == "symmetric" { o.direction = .symmetric } else if let d2 = FeatureValues.number(e["distance2"]) {
                o.direction = .twoSides
                o.second = d2
            }
            if (e["through_all"] as? Bool) == true { o.extent = .all } else if let to = FeatureValues.vector(e["to"]) {
                o.extent = .toObject
                o.toPoint = to
            }
            o.taper = FeatureValues.number(e["taper"]) ?? 0
            o.targets = d["targets"] as? [String] ?? []
            if let t = d["thin"] as? [String: Any] {
                o.thin = true
                o.wallThickness = FeatureValues.number(t["thickness"]) ?? 1
                o.wallLocation = WallLocation(rawValue: t["side"] as? String ?? "center") ?? .center
            }
        case .revolve:
            o.targets = d["targets"] as? [String] ?? []
            if (d["symmetric"] as? Bool) == true { o.direction = .symmetric } else if let a2 = FeatureValues.number(d["angle2"]) {
                o.direction = .twoSides
                o.second = a2
            }
            if let to = FeatureValues.vector(d["to"]) {
                o.extent = .toObject
                o.toPoint = to
            } else if let a = FeatureValues.number(d["angle"]), abs(a - 360) < 1e-9 {
                o.extent = .all
            }
        case .fillet:
            let t = (d["style"] as? [String: Any])?["type"] as? String ?? "constant"
            o.filletType = FilletType(rawValue: t) ?? .constant
            o.tangentChain = d["tangent_chain"] as? Bool ?? true
        case .chamfer:
            if let d2 = FeatureValues.number(d["distance2"]) {
                o.chamferType = .twoDistances
                o.chamferDistance2 = d2
            } else if let a = FeatureValues.number(d["angle"]) {
                o.chamferType = .distanceAngle
                o.chamferAngle = a
            }
            o.flip = d["flip"] as? Bool ?? false
            o.tangentChain = d["tangent_chain"] as? Bool ?? true
        case .shell:
            o.shellDirection = ShellDirection(rawValue: d["direction"] as? String ?? "") ?? .inside
            o.tangentChain = d["tangent_chain"] as? Bool ?? false
        default:
            break
        }
        return o
    }

    static func deg(_ v: Double) -> String { "\(VFFormat.editable(v)) deg" }

    // MARK: Auto Cut (M-4)

    /// Extrude's operation after a value change: a distance into the material (negative, the
    /// sketch normal pointing out of the face it sits on) switches an automatic or joining
    /// extrude to Cut; coming back out undoes that switch. An operation the user picked stays.
    static func autoOperation(value: Double, operation: String, autoCut: Bool, userChose: Bool) -> (operation: String, autoCut: Bool) {
        if userChose { return (operation, false) }
        if value < 0, operation != "cut", operation != "intersect" { return ("cut", true) }
        if value >= 0, autoCut { return ("auto", false) }
        return (operation, autoCut)
    }
}

/// Reading values out of an engine definition.
enum FeatureValues {
    /// A number, or the leading number of an expression ("12.5", "12.5 mm", "90 deg").
    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.doubleValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            let head = t.prefix { "0123456789.-+eE".contains($0) }
            guard !head.isEmpty, let d = Double(head) else { return nil }
            let rest = t.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
            // A bare number or a number with its unit; anything else is an expression.
            return rest.isEmpty || rest.allSatisfy(\.isLetter) ? d : nil
        default: return nil
        }
    }

    static func vector(_ v: Any?) -> [Double]? {
        guard let a = v as? [Any], a.count == 3 else { return nil }
        let n = a.compactMap(number)
        return n.count == 3 ? n : nil
    }

    /// The value at a dotted key of a definition.
    static func value(at key: String, in d: [String: Any]) -> Any? {
        var cur: Any? = d
        for part in key.split(separator: ".") {
            cur = (cur as? [String: Any])?[String(part)]
        }
        return cur
    }

    /// Two definition values mean the same: numbers by value, units aside; a missing value as
    /// its default (`false`, empty, `positive`, the shell's inside).
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        let a = a is NSNull ? nil : a, b = b is NSNull ? nil : b
        switch (a, b) {
        case (nil, nil): return true
        case let (x as Bool, nil), let (nil, x as Bool): return x == false
        case let (x as [Any], nil), let (nil, x as [Any]): return x.isEmpty
        case let (x as String, nil), let (nil, x as String): return x.isEmpty || x == "positive"
        case let (x as [String: Any], y as [String: Any]):
            return Set(x.keys).union(y.keys).allSatisfy { same(x[$0], y[$0]) }
        case let (x as [String: Any], nil), let (nil, x as [String: Any]):
            return (x["type"] as? String) == "constant"
        case let (x as [Any], y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case let (x?, y?):
            if let p = number(x), let q = number(y) { return abs(p - q) < 1e-9 }
            if let p = x as? Bool, let q = y as? Bool { return p == q }
            if let p = x as? String, let q = y as? String { return p.trimmingCharacters(in: .whitespaces) == q.trimmingCharacters(in: .whitespaces) }
            return false
        default: return false
        }
    }
}

/// A feature open in its tool's dialog (M-2).
struct FeatureEditTarget: Equatable {
    var id: Int
    var name: String
    var tool: Tool
    var initialValue: Double
    var initialOperation: String
    var initialOptions: FeatureOptions
    /// The edges or faces the feature takes now, for the selection row.
    var picks: Int
}

/// The typed options and preview of the running feature tool, one per design model.
@MainActor
@Observable
final class FeatureSession {
    @ObservationIgnored private(set) weak var model: DesignModel?

    /// The options of the armed tool (`optionsTool`).
    var options = FeatureOptions() { didSet { if options != oldValue { optionsChanged() } } }
    /// The tool the options are for; a new tool starts from its defaults.
    private(set) var optionsTool: Tool = .select
    /// The feature being edited in its dialog, nil while making a new one.
    private(set) var editing: FeatureEditTarget?
    /// The value while editing (the model's own value drives a new feature).
    var editValue: Double = 0 { didSet { if editValue != oldValue { editValueChanged() } } }
    var editOperation: String = "join" { didSet { if editOperation != oldValue { previewEdit() } } }
    /// The To Object row waits for a face click.
    var pickingToObject = false
    /// The operation is Cut because the value went into the material, not by choice.
    private(set) var autoCut = false
    /// The user picked the operation; the auto switch leaves it alone.
    private(set) var userChoseOperation = false
    /// The engine's refusal of the last preview, for the dialog.
    private(set) var error: String?
    /// What the move gizmo has set while Move runs (B-13); nil for other tools.
    var move: MoveGizmoState?

    @ObservationIgnored private var checkpoint: Int?
    /// The session's preview is on the model (its feature is in the timeline).
    private(set) var applied = false { didSet { model?.sessionPreviewApplied = applied } }
    @ObservationIgnored private var appliedKey: String?

    private init(model: DesignModel) { self.model = model }

    private static var sessions: [ObjectIdentifier: FeatureSession] = [:]

    /// The session of `model`, made on first use.
    static func of(_ model: DesignModel) -> FeatureSession {
        let key = ObjectIdentifier(model)
        if let s = sessions[key], s.model === model { return s }
        let s = FeatureSession(model: model)
        sessions[key] = s
        sessions = sessions.filter { $0.value.model != nil }
        return s
    }

    // MARK: State

    /// The value the dialog shows: the edited feature's, or the model's tool value.
    var value: Double {
        get { editing != nil ? editValue : (model?.toolValue ?? 0) }
        set {
            if editing != nil { editValue = newValue } else { model?.toolValue = newValue }
        }
    }

    /// The operation the dialog shows.
    var operation: String {
        get { editing != nil ? editOperation : (model?.toolOperation ?? "auto") }
        set { chooseOperation(newValue) }
    }

    /// The session, not the model, holds the preview (typed options, or an edit).
    var ownsPreview: Bool {
        editing != nil || (model?.tool == optionsTool && FeatureOptions.tools.contains(optionsTool) && !options.isDefault(for: optionsTool))
    }

    /// A preview is on screen, the model's or the session's.
    var hasPreview: Bool { applied || (model?.hasPreview ?? false) }

    /// The session holds an edit or a checkpoint of its own (even after a refused preview).
    var holdsPreview: Bool { editing != nil || checkpoint != nil || applied }

    /// Return on the canvas: keeps the dialog's feature. False when no dialog runs a preview
    /// (the canvas then ends a line chain).
    @discardableResult
    func handleReturn() -> Bool {
        guard holdsPreview || hasPreview else { return false }
        commit()
        return true
    }

    /// Escape on the canvas: takes the dialog's preview back and leaves the tool. False when no
    /// dialog runs a preview.
    @discardableResult
    func handleEscape() -> Bool {
        guard holdsPreview || hasPreview else { return false }
        cancel()
        return true
    }

    /// The tool the dialog is for.
    var tool: Tool { editing?.tool ?? model?.tool ?? .select }

    // MARK: Sync with the model

    /// Follows the model after it changed (tool, value, profiles, picks): a new tool starts from
    /// its defaults, the auto Cut rule runs, and a preview the model laid over the session's is
    /// replaced by the full command. Views call it from `onChange`; it is cheap when nothing moved.
    func sync() {
        guard let m = model else { return }
        if let e = editing {
            if m.tool != e.tool { cancelEdit() }
            return
        }
        if m.tool != optionsTool {
            if checkpoint != nil {
                // The model may have laid the new tool's preview over the session's: take both
                // back, then let the model preview the new tool alone.
                let modelPreview = m.hasPreview
                if modelPreview { m.cancelPreview() }
                dropPreview()
                if modelPreview { m.applyPreview() }
            }
            optionsTool = m.tool
            move = m.tool == .move ? MoveGizmoState(pivot: Self.centre(of: m)) : nil
            options = FeatureOptions.defaults(for: m.tool)
            pickingToObject = false
            autoCut = false
            userChoseOperation = false
            error = nil
            // A new Extrude or Revolve starts on Automatic, whatever the last one used.
            if (m.tool == .extrude || m.tool == .revolve), m.toolOperation != "auto" {
                m.toolOperation = "auto"
                m.applyPreview()
            }
            return
        }
        if m.tool == .move, let g = move, g.isIdentity, !g.editingPivot {
            // A new pick before any drag: the gizmo goes to its centre.
            let c = Self.centre(of: m)
            if simd_distance(c, g.pivot) > 1e-9 { move?.pivot = c }
        }
        guard FeatureOptions.tools.contains(m.tool) else { return }
        if m.tool == .extrude {
            let r = FeatureOptions.autoOperation(value: m.toolValue, operation: m.toolOperation, autoCut: autoCut, userChose: userChoseOperation)
            if r.operation != m.toolOperation || r.autoCut != autoCut {
                autoCut = r.autoCut
                m.toolOperation = r.operation
                if !ownsPreview { m.applyPreview() }
            }
        }
        if ownsPreview { previewCreate() }
    }

    private func optionsChanged() {
        guard let m = model else { return }
        if editing != nil {
            previewEdit()
            return
        }
        guard FeatureOptions.tools.contains(m.tool), optionsTool == m.tool else { return }
        if ownsPreview {
            previewCreate()
        } else if applied {
            // Back to the plain command: the model previews it again.
            dropPreview()
            m.applyPreview()
        }
    }

    private func chooseOperation(_ op: String) {
        userChoseOperation = op != "auto"
        autoCut = false
        if editing != nil {
            editOperation = op
            return
        }
        guard let m = model else { return }
        m.toolOperation = op
        if ownsPreview { previewCreate() } else { m.applyPreview() }
    }

    // MARK: New feature preview

    /// The command the new feature runs with these options, from the model's inputs.
    func createCommand() -> (String, [String: Any])? {
        guard let m = model else { return nil }
        guard var cmd = options.command(tool: m.tool, value: m.toolValue, operation: m.toolOperation,
                                        profiles: m.extrudeProfiles.sorted(), axis: m.revolveAxis,
                                        edges: m.selection.filter(\.isEdge).map(\.points),
                                        faces: m.selection.filter(\.isFace).map(\.points)) else { return nil }
        // A profile tapped in an older sketch (T-8) extrudes from that sketch, not the last one.
        if m.tool == .extrude, let s = m.extrudeSketch, cmd.1["sketch"] == nil { cmd.1["sketch"] = s }
        return cmd
    }

    /// Runs the full command on the session's checkpoint, replacing the model's preview.
    private func previewCreate() {
        guard let m = model else { return }
        let cmd = createCommand()
        let key = cmd.map { Self.key($0.0, $0.1) }
        if !m.hasPreview, key == appliedKey, checkpoint != nil || cmd == nil { return }
        if m.hasPreview { m.cancelPreview() }
        restoreOwn()
        guard let (id, params) = cmd else {
            appliedKey = key
            finishPreview(m)
            return
        }
        do {
            m.notePreviewBaseline()
            let r = try m.engine.execute("edit.checkpoint") as? [String: Any]
            checkpoint = r?["checkpoint"] as? Int
            try m.engine.execute(id, params)
            applied = true
            error = nil
            m.flash(nil)
        } catch {
            self.error = error.localizedDescription
            m.flash(error.localizedDescription, error: true)
        }
        appliedKey = key
        finishPreview(m)
    }

    private func finishPreview(_ m: DesignModel) {
        let keep = m.selection
        m.refresh()
        let kept = keep.filter { $0.mesh < m.scene.meshes.count }
        if kept != m.selection { m.selection = kept }
    }

    /// Takes the session's preview back (the checkpoint is used up).
    private func restoreOwn() {
        guard let m = model, let cp = checkpoint else { return }
        _ = try? m.engine.execute("edit.restore_checkpoint", ["checkpoint": cp])
        checkpoint = nil
        applied = false
    }

    private func dropPreview() {
        guard checkpoint != nil, let m = model else { applied = false; appliedKey = nil; return }
        restoreOwn()
        appliedKey = nil
        finishPreview(m)
    }

    // MARK: Commit and cancel

    /// Keeps the feature the dialog shows: the edit, the session's preview or the model's.
    func commit() {
        guard let m = model else { return }
        if editing != nil {
            commitEdit()
            return
        }
        if ownsPreview || checkpoint != nil {
            // Make sure the last value is in.
            if m.hasPreview || appliedKey != createCommand().map({ Self.key($0.0, $0.1) }) { previewCreate() }
            // The engine refused the last preview: the dialog stays open on its message.
            if let error {
                m.flash(error, error: true)
                return
            }
            if let cp = checkpoint { _ = try? m.engine.execute("edit.restore_checkpoint", ["checkpoint": cp, "forget": true]) }
            checkpoint = nil
            applied = false
            appliedKey = nil
            m.selection = []
            m.tool = .select
            m.refresh()
            sync()
        } else if let e = m.previewError {
            m.flash(e, error: true)
        } else if m.hasPreview {
            m.commitTool()
            sync()
        } else {
            m.tool = .select
            sync()
        }
    }

    /// Takes the preview back and leaves the tool (Cancel, Escape).
    func cancel() {
        guard let m = model else { return }
        if editing != nil {
            cancelEdit()
            return
        }
        dropPreview()
        m.cancelTool()
        sync()
    }

    // MARK: To Object

    /// Uses the picked face (the selection's, or a click while the row waits) as To Object.
    func takeToObject(_ point: [Double]) {
        options.toPoint = point
        if options.extent != .toObject { options.extent = .toObject }
        pickingToObject = false
    }

    /// Starts the To Object pick; a face already picked is taken at once.
    func beginToObjectPick() {
        if let f = model?.selection.last(where: \.isFace) {
            takeToObject(f.points)
        } else {
            pickingToObject = true
        }
    }

    /// A click on the canvas while To Object waits: the face under it. Answers whether the click
    /// was taken (the canvas then does nothing else with it).
    @discardableResult
    func canvasTap(at p: CGPoint, size: CGSize) -> Bool {
        guard pickingToObject, let m = model else { return false }
        if case let .face(_, _, point, _)? = ScenePicker.pickFace(m.scene, camera: m.camera, at: p, size: size) {
            takeToObject([point.x, point.y, point.z])
        }
        return true
    }

    // MARK: Edit Feature (M-2)

    /// The dialog tool for an engine feature type.
    static func tool(forFeatureType type: String) -> Tool? {
        switch type {
        case "extrude": .extrude
        case "revolve": .revolve
        case "fillet": .fillet
        case "chamfer": .chamfer
        case "shell": .shell
        default: nil
        }
    }

    /// The definition key of the dialog's value.
    static func valueKey(_ tool: Tool) -> String {
        switch tool {
        case .extrude: "extent.distance"
        case .revolve: "angle"
        case .fillet: "radius"
        case .chamfer: "distance"
        case .shell: "thickness"
        default: ""
        }
    }

    /// Opens `feature` in its tool's dialog with its values. False when the feature has no
    /// dialog of its own (the caller shows the generic Edit Feature sheet) or the engine refused.
    func beginEdit(_ feature: String) -> Bool {
        guard let m = model else { return false }
        guard let r = (try? m.engine.execute("timeline.inspect", ["feature": feature])) as? [String: Any],
              let type = r["type"] as? String, let tool = Self.tool(forFeatureType: type),
              let def = r["definition"] as? [String: Any] else { return false }
        if m.sketchOpen { m.finishSketch() }
        if editing != nil { cancelEdit() }
        if m.tool != .select {
            dropPreview()
            m.tool = .select
        }
        let opts = FeatureOptions.from(definition: def, tool: tool)
        let value = FeatureValues.number(FeatureValues.value(at: Self.valueKey(tool), in: def)) ?? tool.value?.initial ?? 0
        let op = def["operation"] as? String ?? "join"
        let picks = ((def["edges"] ?? def["faces"]) as? [Any])?.count ?? 0
        let id = r["id"] as? Int ?? m.snapshot.timeline.first { $0.name == feature }?.id ?? 0
        let name = r["name"] as? String ?? feature
        editing = FeatureEditTarget(id: id, name: name, tool: tool, initialValue: value, initialOperation: op, initialOptions: opts, picks: picks)
        optionsTool = tool
        options = opts
        editValue = value
        editOperation = op
        error = nil
        pickingToObject = false
        autoCut = false
        userChoseOperation = false
        // Arm the tool without a preview of its own: its value stays 0, so the model never
        // previews a new feature while the dialog edits this one.
        m.selection = []
        m.armingQuietly = true
        m.tool = tool
        m.armingQuietly = false
        return true
    }

    private func editValueChanged() {
        guard let e = editing else { return }
        if e.tool == .extrude {
            let r = FeatureOptions.autoOperation(value: editValue, operation: editOperation, autoCut: autoCut, userChose: userChoseOperation)
            if r.autoCut != autoCut || r.operation != editOperation {
                autoCut = r.autoCut
                // "auto" is not a stored operation: going back out restores the feature's own.
                editOperation = r.operation == "auto" ? (e.initialOperation == "cut" ? "join" : e.initialOperation) : r.operation
            }
        }
        previewEdit()
    }

    /// The `set` the edit sends: the changed value, operation and options, and new picks.
    func editSet() -> [String: Any] {
        guard let e = editing, let m = model else { return [:] }
        var set: [String: Any] = [:]
        if abs(editValue - e.initialValue) > 1e-9 {
            set[Self.valueKey(e.tool)] = e.tool == .revolve ? FeatureOptions.deg(editValue) : editValue as Any
        }
        if (e.tool == .extrude || e.tool == .revolve), editOperation != e.initialOperation { set["operation"] = editOperation }
        let now = options.definitionFields(tool: e.tool)
        let before = e.initialOptions.definitionFields(tool: e.tool)
        for (k, v) in now where !FeatureValues.same(v, before[k]) { set[k] = v }
        // New picks replace the feature's edges or faces.
        switch e.tool {
        case .fillet, .chamfer:
            let edges = m.selection.filter(\.isEdge).map(\.points)
            if !edges.isEmpty { set["edges"] = edges }
        case .shell:
            let faces = m.selection.filter(\.isFace).map(\.points)
            if !faces.isEmpty { set["faces"] = faces }
        default: break
        }
        return set
    }

    /// Runs `timeline.edit` with the dialog's changes on the session's checkpoint.
    func previewEdit() {
        guard let e = editing, let m = model else { return }
        let set = editSet()
        let key = Self.key("timeline.edit", set)
        if key == appliedKey, checkpoint != nil || set.isEmpty { return }
        restoreOwn()
        appliedKey = key
        guard !set.isEmpty else {
            error = nil
            finishPreview(m)
            return
        }
        do {
            m.notePreviewBaseline()
            let r = try m.engine.execute("edit.checkpoint") as? [String: Any]
            checkpoint = r?["checkpoint"] as? Int
            try m.engine.execute("timeline.edit", ["feature": e.id, "set": set])
            applied = true
            error = nil
            m.flash(nil)
        } catch {
            self.error = error.localizedDescription
            m.flash(error.localizedDescription, error: true)
        }
        finishPreview(m)
    }

    /// Keeps the edit (one undo step) and closes the dialog.
    private func commitEdit() {
        guard let m = model else { return }
        previewEdit()
        if let error {
            m.flash(error, error: true)
            return
        }
        if let cp = checkpoint { _ = try? m.engine.execute("edit.restore_checkpoint", ["checkpoint": cp, "forget": true]) }
        endEdit(m)
    }

    /// Takes the edit back and closes the dialog.
    func cancelEdit() {
        guard let m = model else { return }
        restoreOwn()
        endEdit(m)
    }

    private func endEdit(_ m: DesignModel) {
        checkpoint = nil
        applied = false
        appliedKey = nil
        editing = nil
        pickingToObject = false
        m.selection = []
        if m.tool != .select { m.tool = .select }
        optionsTool = .select
        options = FeatureOptions()
        m.refresh()
    }

    // MARK: Required inputs (M-5)

    /// What the dialog still needs before OK, or nil when it can finish.
    func missingInput() -> String? {
        guard let m = model else { return nil }
        if editing != nil { return options.missingInput(for: tool) }
        switch m.tool {
        case .extrude, .revolve:
            if !m.sketchOpen, m.snapshot.sketches.isEmpty { return String(localized: "Draw a sketch first") }
            return options.missingInput(for: m.tool)
        case .pressPull:
            return m.selection.contains(where: \.isFace) ? nil : String(localized: "Select a face")
        case .fillet, .chamfer:
            return m.selection.contains(where: \.isEdge) ? nil : String(localized: "Select edges")
        case .shell:
            return m.selection.contains(where: \.isFace) ? nil : String(localized: "Select faces to open")
        case .move, .mirror:
            return m.bodiesInSelection.isEmpty ? String(localized: "Select bodies") : nil
        default:
            return nil
        }
    }

    // MARK: Move (B-13)

    /// The centre of the bodies the selection names, where the move gizmo starts.
    static func centre(of m: DesignModel) -> SIMD3<Double> {
        guard let box = AnchorLayout.bounds(of: Set(m.bodiesInSelection), in: m.scene) else { return .zero }
        return (box.min + box.max) / 2
    }

    /// OK while Move runs: one `solid.move` with the gizmo's translation, turn and copy flag.
    func commitMove() {
        guard let m = model else { return }
        if let c = move?.command(bodies: m.bodiesInSelection), !(move?.isIdentity ?? true) || (move?.copy ?? false) {
            m.run(c.id, c.params)
        }
        move = nil
        m.tool = .select
        sync()
    }

    // MARK: Helpers

    static func key(_ id: String, _ params: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return id + (String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Tool modes (T-10)

/// The modes of the running tool, for the touch mode pill ("Extrude, One Side" with a chevron).
/// Each mode is an engine variant: another tool (2-point or centre rectangle, line or arc,
/// fillet or chamfer) or the dialog's direction.
struct ToolMode: Identifiable {
    let id: String
    let title: String
    let on: Bool
    let pick: () -> Void
}

@MainActor
enum ToolModes {
    static func modes(_ model: DesignModel) -> [ToolMode] {
        let s = FeatureSession.of(model)
        func tool(_ t: Tool) -> ToolMode {
            ToolMode(id: t.rawValue, title: t.label, on: model.tool == t) { if model.tool != t { model.tool = t } }
        }
        switch model.tool {
        case .rectangle, .centerRectangle: return [tool(.rectangle), tool(.centerRectangle)]
        case .line, .arc: return [tool(.line), tool(.arc)]
        case .fillet, .chamfer:
            if s.editing == nil { return [tool(.fillet), tool(.chamfer)] }
        default: break
        }
        switch s.tool {
        case .extrude, .revolve:
            return FeatureOptions.Direction.allCases.map { d in
                ToolMode(id: d.rawValue, title: d.title, on: s.options.direction == d) { s.options.direction = d }
            }
        case .shell:
            return FeatureOptions.ShellDirection.allCases.map { d in
                ToolMode(id: d.rawValue, title: d.title, on: s.options.shellDirection == d) { s.options.shellDirection = d }
            }
        case .fillet:
            return FeatureOptions.FilletType.allCases.map { t in
                ToolMode(id: t.rawValue, title: t.title, on: s.options.filletType == t) { s.options.filletType = t }
            }
        case .chamfer:
            return FeatureOptions.ChamferType.allCases.map { t in
                ToolMode(id: t.rawValue, title: t.title, on: s.options.chamferType == t) { s.options.chamferType = t }
            }
        default:
            return []
        }
    }

    /// The current mode's name, or nil when the tool has one mode.
    static func current(_ model: DesignModel) -> String? {
        let m = modes(model)
        guard m.count > 1 else { return nil }
        return m.first(where: \.on)?.title
    }
}

/// One option of the running tool as a row of the iPad column, between Done and Cancel (the
/// reference's "Keep Originals" and "Projection Type" rows): a choice that shows its current
/// value, or a switch. The main mode stays on the canvas pill, the value and result on the chip.
struct ToolOptionRow: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// The values to pick from; empty for a switch.
    var choices: [ToolMode] = []
    var isOn = false
    var toggle: (() -> Void)?

    var value: String {
        if let c = choices.first(where: \.on) { return c.title }
        return isOn ? String(localized: "On") : String(localized: "Off")
    }
}

@MainActor
enum ToolOptionRows {
    static func rows(_ model: DesignModel) -> [ToolOptionRow] {
        guard !model.tool.isSketchTool else { return [] }
        let s = FeatureSession.of(model)
        func tangent(_ title: String) -> ToolOptionRow {
            ToolOptionRow(id: "tangent", title: title, symbol: "point.topleft.down.to.point.bottomright.curvepath",
                          isOn: s.options.tangentChain) { s.options.tangentChain.toggle() }
        }
        switch s.tool {
        case .extrude:
            var out: [ToolOptionRow] = []
            if s.editing == nil {
                out.append(ToolOptionRow(id: "type", title: String(localized: "Type"), symbol: "square.stack.3d.up", choices: [
                    ToolMode(id: "solid", title: String(localized: "Extrude"), on: !s.options.thin) { s.options.thin = false },
                    ToolMode(id: "thin", title: String(localized: "Thin Extrude"), on: s.options.thin) { s.options.thin = true },
                ]))
            }
            out.append(ToolOptionRow(id: "extent", title: String(localized: "Extent"), symbol: "arrow.up.to.line",
                                     choices: FeatureOptions.Extent.allCases.map { e in
                ToolMode(id: e.rawValue, title: e.title(revolve: false), on: s.options.extent == e) { s.options.extent = e }
            }))
            if s.options.thin {
                out.append(ToolOptionRow(id: "wall", title: String(localized: "Wall Location"), symbol: "square.split.2x1",
                                         choices: FeatureOptions.WallLocation.allCases.map { w in
                    ToolMode(id: w.rawValue, title: w.title, on: s.options.wallLocation == w) { s.options.wallLocation = w }
                }))
            }
            return out
        case .revolve:
            return [ToolOptionRow(id: "extent", title: String(localized: "Type"), symbol: "arrow.triangle.2.circlepath",
                                  choices: FeatureOptions.Extent.allCases.map { e in
                ToolMode(id: e.rawValue, title: e == .all ? String(localized: "Full") : e.title(revolve: true), on: s.options.extent == e) { s.options.extent = e }
            })]
        case .fillet:
            return [tangent(String(localized: "Include Tangent Edges"))]
        case .chamfer:
            return [tangent(String(localized: "Include Tangent Edges")),
                    ToolOptionRow(id: "flip", title: String(localized: "Flip"), symbol: "arrow.left.arrow.right",
                                  isOn: s.options.flip) { s.options.flip.toggle() }]
        case .shell:
            return [tangent(String(localized: "Tangent Chain"))]
        default:
            return []
        }
    }
}

// MARK: - Self test

/// Checks for the typed feature dialogs, run with the app's `--selftest` (wired in SelfTest).
enum FeatureDialogSelfTest {
    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        func volume(_ m: DesignModel) -> Double { m.snapshot.bodies.compactMap(\.volume_mm3).reduce(0, +) }
        func plate(_ m: DesignModel) {
            // A 20 x 10 rectangle on XY and a 40 x 40 x 10 slab above it (z 20 to 30).
            m.run("file.new", quiet: true)
            m.run("solid.box", ["length": 40, "width": 40, "height": 10, "corner": [-20, -20, 20], "body_name": "Slab"], quiet: true)
            m.run("sketch.create", ["plane": "XY"], quiet: true)
            m.run("sketch.rectangle.two_point", ["p0": [-10, -5], "p1": [10, 5]], quiet: true)
            m.run("sketch.finish", quiet: true)
        }

        // B-7: Symmetric extrude, 10 mm total about the sketch plane, through the dialog path.
        let m = DesignModel()
        let s = FeatureSession.of(m)
        plate(m)
        let slab = volume(m)
        m.tool = .extrude
        s.sync()
        m.toolValue = 10
        s.options.direction = .symmetric
        s.options.targets = []
        out.append((s.ownsPreview && s.applied, "B-7 Symmetric takes the preview over (one command, one undo step)"))
        out.append((m.snapshot.bodies.count == 2 && m.listedBodies.map(\.name) == ["Slab"],
                    "B-7 the previewed body stays out of the browser until OK (lists \(m.listedBodies.map(\.name)))"))
        s.commit()
        let sym = volume(m) - slab
        out.append((m.listedBodies.count == 2, "B-7 OK lists the new body"))
        out.append((abs(sym - 200 * 10) < 1, "B-7 Symmetric extrude builds 20 x 10 x 10 (got \(Int(sym)) mm³)"))
        m.run("edit.undo", quiet: true)
        out.append((abs(volume(m) - slab) < 1, "B-7 one undo takes the symmetric extrude back"))

        // B-7: Through All, as a cut, runs through the slab above.
        m.tool = .extrude
        s.sync()
        s.options.extent = .all
        s.operation = "cut"
        s.commit()
        let through = slab - volume(m)
        out.append((abs(through - 200 * 10) < 1, "B-7 Through All cut goes through the slab (removed \(Int(through)) mm³)"))
        m.run("edit.undo", quiet: true)

        // B-7: To Object ends at the slab's underside (z 20).
        m.tool = .extrude
        s.sync()
        s.options.extent = .toObject
        out.append((s.missingInput() != nil, "M-5 To Object without a face keeps OK greyed"))
        s.takeToObject([0, 0, 20])
        s.operation = "new_body"
        s.commit()
        let to = volume(m) - slab
        out.append((abs(to - 200 * 20) < 1, "B-7 To Object extrudes up to the picked face (got \(Int(to)) mm³)"))

        // T-10: the iPad column lists Extrude's options as rows; Thin adds Wall Location.
        m.run("edit.undo", quiet: true)
        m.tool = .extrude
        s.sync()
        let rowIDs = ToolOptionRows.rows(m).map(\.id)
        ToolOptionRows.rows(m).first { $0.id == "type" }?.choices.first { $0.id == "thin" }?.pick()
        out.append((rowIDs == ["type", "extent"] && s.options.thin && ToolOptionRows.rows(m).map(\.id) == ["type", "extent", "wall"],
                    "T-10 Extrude's options are column rows; picking Thin Extrude adds Wall Location (\(rowIDs))"))
        s.cancel()
        m.run("edit.redo", quiet: true)

        // B-7: Thin Extrude, a 1 mm wall centred on the 20 x 10 rectangle, 10 mm tall.
        m.run("edit.undo", quiet: true)
        let beforeThin = volume(m)
        m.tool = .extrude
        s.sync()
        m.toolValue = 10
        s.options.thin = true
        s.options.wallThickness = 1
        s.commit()
        let wall = volume(m) - beforeThin
        out.append((abs(wall - (21 * 11 - 19 * 9) * 10) < 1, "B-7 Thin Extrude builds a 1 mm wall along the curves (got \(Int(wall)) mm³)"))
        let thinFeature = m.snapshot.timeline.last?.name ?? ""
        out.append((s.beginEdit(thinFeature) && s.options.thin && s.options.wallThickness == 1, "B-7 Edit Feature reopens a thin extrude as thin"))
        s.cancel()

        // M-2: edit that extrude in its own dialog: 20 mm one side, then 8 mm with a preview.
        let feature = m.snapshot.timeline.last?.name ?? ""
        m.run("edit.undo", quiet: true)
        m.tool = .extrude
        s.sync()
        m.toolValue = 12
        s.commit()
        let made = m.snapshot.timeline.last?.name ?? ""
        out.append((s.beginEdit(made) && m.tool == .extrude && s.editing?.initialValue == 12,
                    "M-2 Edit Feature reopens Extrude with its distance (\(s.editing.map { String($0.initialValue) } ?? "none"))"))
        s.value = 8
        let previewed = volume(m) - slab
        out.append((s.applied && abs(previewed - 200 * 8) < 1, "M-2 the edit previews live (\(Int(previewed)) mm³)"))
        s.commit()
        out.append((s.editing == nil && m.tool == .select && abs(volume(m) - slab - 200 * 8) < 1, "M-2 OK commits the edit through timeline.edit"))
        m.run("edit.undo", quiet: true)
        out.append((abs(volume(m) - slab - 200 * 12) < 1, "M-2 one undo takes the edit back"))
        out.append((s.beginEdit(made), "M-2 Edit Feature opens again"))
        s.options.direction = .symmetric
        s.cancel()
        out.append((abs(volume(m) - slab - 200 * 12) < 1 && s.editing == nil, "M-2 Cancel leaves the feature as it was"))
        out.append((!feature.isEmpty, "B-7 the To Object feature was named (\(feature))"))
        out.append((!s.beginEdit(m.snapshot.timeline.first?.name ?? ""), "M-2 a box has no dialog: the generic sheet opens instead"))

        // M-4: the auto Cut rule.
        let a = FeatureOptions.autoOperation(value: -3, operation: "auto", autoCut: false, userChose: false)
        let b = FeatureOptions.autoOperation(value: 4, operation: a.operation, autoCut: a.autoCut, userChose: false)
        let c = FeatureOptions.autoOperation(value: -3, operation: "join", autoCut: false, userChose: true)
        out.append((a == ("cut", true) && b == ("auto", false) && c == ("join", false),
                    "M-4 into the material switches to Cut, out again switches back, a picked operation stays"))

        // M-4: a sketch on the slab's top face dragged down cuts a pocket.
        let p = DesignModel()
        let ps = FeatureSession.of(p)
        p.run("solid.box", ["length": 40, "width": 40, "height": 10, "center": [0, 0, 0], "body_name": "Block"], quiet: true)
        let block = volume(p)
        p.run("sketch.create", ["plane": ["face": [5, 5, 5]]], quiet: true)
        p.run("sketch.circle.center", ["center": [0, 0], "radius": 5], quiet: true)
        p.run("sketch.finish", quiet: true)
        p.tool = .extrude
        ps.sync()
        p.toolValue = -4
        ps.sync()
        out.append((p.toolOperation == "cut" && ps.autoCut, "M-4 a negative distance turns the extrude into a Cut"))
        ps.commit()
        let pocket = block - volume(p)
        out.append((abs(pocket - .pi * 25 * 4) < 2, "M-4 the auto Cut removes a 4 mm pocket (\(Int(pocket)) mm³)"))

        // Fillet: G2 type goes to the engine as a typed option.
        let f = FeatureOptions(filletType: .curvature)
        let cmd = f.command(tool: .fillet, value: 2, operation: "auto", profiles: [], axis: "x", edges: [[0, 0, 0]], faces: [])
        out.append((cmd?.1["type"] as? String == "curvature", "B-7 a G2 fillet sends type curvature"))
        out.append((FeatureDialogFields.targets([], all: ["A", "B", "C"], name: "B", on: false) == ["A", "C"]
                    && FeatureDialogFields.targets(["A", "C"], all: ["A", "B", "C"], name: "B", on: true) == [],
                    "M-4 Objects To Cut: unticking keeps the others, ticking all goes back to every body"))
        out += reviewChecks(plate: plate, volume: volume)
        return out
    }

    /// Regressions from the code review (findings 1, 4, 5, 6).
    @MainActor private static func reviewChecks(plate: (DesignModel) -> Void, volume: (DesignModel) -> Double) -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let m = DesignModel()
        let s = FeatureSession.of(m)
        plate(m)
        let slab = volume(m)

        // 1: with the session owning the preview, a value change runs one preview (the
        // session's), never the model's on top of it.
        m.tool = .extrude
        s.sync()
        m.toolValue = 10
        s.options.direction = .symmetric
        m.toolValue = 6
        out.append((s.applied && !m.hasPreview && abs(volume(m) - slab - 200 * 6) < 1,
                    "Review 1: a value change under typed options previews once, through the session (\(Int(volume(m) - slab)) mm³)"))
        // 4: Return keeps the session's feature.
        out.append((s.handleReturn() && m.tool == .select && abs(volume(m) - slab - 200 * 6) < 1,
                    "Review 4: Return commits the session's preview"))
        m.run("edit.undo", quiet: true)
        // 4: Escape takes the session's preview back.
        m.tool = .extrude
        s.sync()
        m.toolValue = 10
        s.options.direction = .symmetric
        out.append((s.handleEscape() && m.tool == .select && !s.holdsPreview && abs(volume(m) - slab) < 1,
                    "Review 4: Escape cancels the session's preview"))
        out.append((!s.handleReturn() && !s.handleEscape(), "Review 4: with no dialog Return and Escape fall through to the canvas"))

        // 1: while a feature is edited, the handle's value is the edit's; the model lays no new
        // feature preview over the edit.
        m.tool = .extrude
        s.sync()
        m.toolValue = 12
        s.commit()
        let made = m.snapshot.timeline.last?.name ?? ""
        let features = m.snapshot.timeline.count
        if s.beginEdit(made) {
            s.value = 8
            m.toolValue = 5
            out.append((s.editValue == 8 && !m.hasPreview && abs(volume(m) - slab - 200 * 8) < 1,
                        "Review 1: during an edit the handle drives the edit, the model previews nothing (\(Int(volume(m) - slab)) mm³)"))

            // 5: a refused preview keeps the dialog open on OK.
            s.value = 0
            let refused = s.error != nil
            s.commit()
            out.append((refused && s.editing != nil, "Review 5: OK after a refused preview keeps the dialog open (error \(refused))"))
            s.cancel()
            out.append((s.editing == nil && abs(volume(m) - slab - 200 * 12) < 1 && m.snapshot.timeline.count == features,
                        "Review 5: Cancel then leaves the feature as it was"))
        } else {
            out.append((false, "Review 1: the extrude opens in its dialog"))
        }

        // 6: undo while the session previews drops the preview first, then undoes the last step.
        m.tool = .extrude
        s.sync()
        m.toolValue = 10
        s.options.direction = .symmetric
        let previewing = s.applied
        m.undo()
        out.append((previewing && !s.holdsPreview && m.tool == .select && abs(volume(m) - slab) < 1
                    && m.snapshot.timeline.count == features - 1,
                    "Review 6: undo during a dialog cancels its preview, then undoes the last feature"))
        // 6: the same with the model's own preview (default options), and a new design.
        m.tool = .extrude
        s.sync()
        m.toolValue = 4
        let modelPreview = m.hasPreview
        m.newDesign()
        out.append((modelPreview && !m.hasPreview && m.tool == .select && m.snapshot.bodies.isEmpty,
                    "Review 6: a new design drops the tool's preview first"))
        return out
    }
}
