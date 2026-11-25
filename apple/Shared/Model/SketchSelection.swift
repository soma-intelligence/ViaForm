import CoreGraphics
import Foundation
import simd

// Sketch selection, constraints, dimensions and construction on the open sketch
// (gaps B-1 to B-5, B-9; T-3 in Viewport.swift).
//
// Public API for the surfaces (Mac ribbon and context pill, iPad constraint column, sketch
// palette, browser). Everything runs engine commands; nothing here computes geometry.
//
//   model.sketchSelection: [SketchPick]       picked points, curves and constraint glyphs, in
//                                             pick order (Select tool, open sketch). Cleared
//                                             when the sketch closes. Delete (deleteSelection)
//                                             sends `sketch.delete` for it.
//   model.sketchHover: SketchPick?            what the pointer is over.
//   model.sketchState: SketchDefinedState?    dof, fullyConstrained, overConstrained, summary,
//                                             symbol (nil without an open sketch).
//   model.constraintEntries                   SketchConstraintCatalog.entries(for: selection):
//                                             every constraint, in a fixed order, with id,
//                                             label, symbol, enabled.
//   SketchConstraintCatalog.valid(for:)       the enabled ones only (pure, SketchConstraints.swift).
//   model.applyConstraint(_ entry)            runs an entry (`sketch.constraint.*`); Symmetry with
//                                             two picks asks for the line as the next pick.
//   model.routeSketchCommand(_ commandID)     for a command router: runs sketch.construction,
//                                             sketch.delete and sketch.constraint.* from the
//                                             selection; false when it does not apply (then
//                                             the generic form is the fallback).
//   model.beginDimension()                    arms the Dimension tool (Tool.dimension, key D);
//                                             one or two picked entities seed it.
//   model.placeDrivenDimension()              adds the refused dimension (`dimensionOffer`) as
//                                             a driven one.
//   model.toggleConstruction()                selected curves switch normal / construction; with
//                                             no curve selected, toggles `constructionMode` (new
//                                             curves are drawn as construction).
//   model.showConstraints                     the "Show constraints" toggle (persisted).
//   model.deleteSketchSelection()             `sketch.delete` on the selection.

/// A sketch entity or constraint glyph on the canvas.
struct SketchPick: Hashable {
    enum Kind: String {
        case point, line, circle, arc
        /// Any other curve (spline, ellipse, conic).
        case curve
        /// A constraint glyph.
        case constraint

        init(curveType: String) {
            switch curveType {
            case "line": self = .line
            case "circle": self = .circle
            case "arc": self = .arc
            default: self = .curve
            }
        }
    }

    var id: String
    var kind: Kind

    var isCurve: Bool { kind != .point && kind != .constraint }
}

/// How defined the open sketch is (B-3), sketch level.
struct SketchDefinedState: Equatable {
    /// Degrees of freedom left (nil when the engine did not say).
    var dof: Int?
    var fullyConstrained: Bool
    /// Some constraints conflict (the solver could not satisfy them together).
    var overConstrained: Bool
    var conflicts: Int

    /// "Over-constrained", "Fully defined" or "Under defined (3 DOF)".
    var summary: String {
        if overConstrained { return String(localized: "Over-constrained") }
        if fullyConstrained { return String(localized: "Fully defined") }
        if let dof { return String(localized: "Under defined (\(dof) DOF)") }
        return String(localized: "Under defined")
    }

    /// SF Symbol for the state: a warning, a closed lock or an open pencil.
    var symbol: String {
        overConstrained ? "exclamationmark.triangle.fill" : (fullyConstrained ? "lock.fill" : "pencil.line")
    }
}

/// A dimension the engine refused because the sketch already determines it: the canvas offers
/// it again as a driven (reference) dimension at the same place.
struct DimensionOffer: Equatable {
    var entities: [String]
    var at: SIMD2<Double>
    var reason: String
}

extension DesignModel {
    // MARK: State

    var sketchState: SketchDefinedState? {
        guard sketchOpen, let info = sketchInfo else { return nil }
        let failing = info.glyphs.contains(where: \.failing) || info.dimensions.contains(where: \.failing)
        return SketchDefinedState(dof: info.dof, fullyConstrained: info.fullyConstrained && info.conflicts.isEmpty,
                                  overConstrained: !info.conflicts.isEmpty || failing, conflicts: info.conflicts.count)
    }

    /// Every constraint for the current selection, enabled where it fits.
    var constraintEntries: [SketchConstraintEntry] { SketchConstraintCatalog.entries(for: sketchSelection) }

    /// Pick radii: a finger needs more room than a pointer.
    var sketchPickRadii: (point: CGFloat, curve: CGFloat) {
        #if os(iOS)
        (16, 12)
        #else
        (8, 6)
        #endif
    }

    // MARK: Pointer (called from DesignModel.hover and click)

    /// Hover in an open sketch with Select or Dimension. True when the sketch took it.
    func sketchHoverHandled(at p: CGPoint) -> Bool {
        let filterTakesSketch = selectionFilter == .auto || selectionFilter == .sketch || tool == .dimension
        guard sketchOpen, tool == .select || tool == .dimension, filterTakesSketch, let info = sketchInfo else {
            if sketchHover != nil { sketchHover = nil }
            if dimensionCursor != nil { dimensionCursor = nil }
            return false
        }
        let r = sketchPickRadii
        let h = SketchPicker.pick(info, camera: camera, at: p, size: viewSize, glyphs: tool == .select && showConstraints,
                                  pointRadius: r.point, curveTolerance: r.curve)
        if h != sketchHover { sketchHover = h }
        if tool == .dimension {
            dimensionCursor = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize)
            if hover != nil { hover = nil }
            return true
        }
        guard h != nil else { return false }
        if hover != nil { hover = nil }
        return true
    }

    /// A click or tap in an open sketch with Select or Dimension. True when the sketch took it;
    /// false lets the 3D pick run (a click on nothing still clears the sketch selection).
    func sketchClickHandled(at p: CGPoint, mode: SelectMode) -> Bool {
        if tool == .dimension { dimensionClick(at: p); return true }
        guard sketchOpen, tool == .select, selectionFilter == .auto || selectionFilter == .sketch, let info = sketchInfo else { return false }
        let r = sketchPickRadii
        let hit = SketchPicker.pick(info, camera: camera, at: p, size: viewSize, glyphs: showConstraints && symmetryPending == nil,
                                    pointRadius: r.point, curveTolerance: r.curve)
        if let pending = symmetryPending {
            guard let hit, hit.kind == .line || hit.kind == .point else {
                flash(String(localized: "Pick the symmetry line"), error: true)
                return true
            }
            symmetryPending = nil
            if let e = SketchConstraintCatalog.entries(for: pending + [hit]).first(where: { $0.id == "symmetry" }), !e.calls.isEmpty {
                runConstraintCalls(e)
            }
            sketchSelection = []
            return true
        }
        guard let hit else {
            // A click on nothing clears the sketch selection; so does a finger tap, though taps
            // toggle (T-11).
            if mode == .replace || (touchTaps && mode == .toggle), !sketchSelection.isEmpty { sketchSelection = [] }
            return false
        }
        let present = sketchSelection.firstIndex(of: hit)
        switch mode {
        case .toggle:
            if let present { sketchSelection.remove(at: present) } else { sketchSelection.append(hit) }
        case .add:
            if present == nil { sketchSelection.append(hit) }
        case .replace:
            replaceSelection(sketch: [hit])
        }
        return true
    }

    // MARK: Lifecycle (called from DesignModel)

    /// The tool changed: the Dimension tool takes one or two picked entities as its first
    /// picks; a drawing tool drops the selection.
    func sketchToolChanged() {
        symmetryPending = nil
        dimensionOffer = nil
        dimensionCursor = nil
        if sketchHover != nil { sketchHover = nil }
        if tool == .dimension {
            let seed = sketchSelection.filter { $0.kind != .constraint }
            dimensionPicks = (1...2).contains(seed.count) ? seed : []
            if !sketchSelection.isEmpty { sketchSelection = [] }
        } else {
            if !dimensionPicks.isEmpty { dimensionPicks = [] }
            // Mirror and the patterns take the selection as their entities (SketchDrawing.swift).
            if tool != .select, !tool.takesSketchEntities, !sketchSelection.isEmpty { sketchSelection = [] }
        }
    }

    /// After the sketch is read again: drop picks that no longer exist, everything when the
    /// sketch closed.
    func pruneSketchSelection() {
        guard sketchOpen, let info = sketchInfo else {
            if !sketchSelection.isEmpty { sketchSelection = [] }
            if sketchHover != nil { sketchHover = nil }
            if !dimensionPicks.isEmpty { dimensionPicks = [] }
            if dimensionOffer != nil { dimensionOffer = nil }
            if symmetryPending != nil { symmetryPending = nil }
            if constructionMode { constructionMode = false }
            return
        }
        var ids = Set(info.points.map(\.id))
        ids.formUnion(info.curves.map(\.id))
        ids.formUnion(info.glyphs.map(\.id))
        let kept = sketchSelection.filter { ids.contains($0.id) }
        if kept != sketchSelection { sketchSelection = kept }
        let keptDims = dimensionPicks.filter { ids.contains($0.id) }
        if keptDims != dimensionPicks { dimensionPicks = keptDims }
        if let h = sketchHover, !ids.contains(h.id) { sketchHover = nil }
    }

    /// Escape: drops a pending third pick, the Dimension tool's picks, or the selection. True
    /// when something was dropped.
    func cancelSketchPicks() -> Bool {
        if symmetryPending != nil { symmetryPending = nil; flash(nil); return true }
        if !dimensionPicks.isEmpty || dimensionOffer != nil { dimensionPicks = []; dimensionOffer = nil; return true }
        if tool == .select, !sketchSelection.isEmpty { sketchSelection = []; return true }
        return false
    }

    // MARK: Delete

    func deleteSketchSelection() {
        let ids = sketchSelection.map(\.id)
        guard !ids.isEmpty else { return }
        sketchSelection = []
        sketchHover = nil
        run("sketch.delete", ["entities": ids])
    }

    // MARK: Constraints (B-4)

    /// Runs a constraint entry on the selection. Symmetry with two picks waits for the line.
    func applyConstraint(_ e: SketchConstraintEntry) {
        guard e.enabled, sketchOpen else { return }
        if e.awaitsThirdPick {
            symmetryPending = sketchSelection.filter { $0.kind != .constraint }
            flash(String(localized: "Pick the symmetry line"))
            return
        }
        runConstraintCalls(e)
        sketchSelection = []
    }

    /// Applies the entry with this id ("parallel", "horizontal"...) when the selection fits it.
    @discardableResult
    func applyConstraint(id: String) -> Bool {
        guard let e = constraintEntries.first(where: { $0.id == id }), e.enabled else { return false }
        applyConstraint(e)
        return true
    }

    private func runConstraintCalls(_ e: SketchConstraintEntry) {
        for c in e.calls where run(c.command, c.params, quiet: true) == nil { break }
    }

    /// A registry command as the sketch selection would run it: Normal/Construction, Delete,
    /// any `sketch.constraint.*` the selection fits, Dimension. False when it does not apply.
    @discardableResult
    func routeSketchCommand(_ commandID: String) -> Bool {
        guard sketchOpen else { return false }
        switch commandID {
        case "sketch.dimension":
            beginDimension()
            return true
        case "sketch.construction":
            toggleConstruction()
            return true
        case "sketch.delete":
            guard !sketchSelection.isEmpty else { return false }
            deleteSketchSelection()
            return true
        default:
            guard commandID.hasPrefix("sketch.constraint."),
                  let e = SketchConstraintCatalog.entry(command: commandID, for: sketchSelection) else { return false }
            applyConstraint(e)
            return true
        }
    }

    // MARK: Construction (B-9)

    func toggleConstruction() {
        guard sketchOpen else { return }
        let curves = sketchSelection.filter(\.isCurve).map(\.id)
        if curves.isEmpty {
            constructionMode.toggle()
            flash(constructionMode ? String(localized: "Construction: new curves are construction geometry") : String(localized: "Construction off"))
            return
        }
        run("sketch.construction", ["curves": curves], quiet: true)
    }

    /// Runs a sketch drawing command; in construction mode the new curves are construction
    /// geometry (asked of the command, and switched after when it did not take the flag).
    @discardableResult
    func drawSketch(_ id: String, _ params: [String: Any]) -> Any? {
        guard constructionMode else { return run(id, params, quiet: true) }
        var p = params
        p["construction"] = true
        let r = run(id, p, quiet: true)
        let reply = r as? [String: Any]
        let made = (reply?["created"] as? [String: Any])?["curves"] as? [String] ?? reply?["curves"] as? [String] ?? []
        let plain = made.filter { c in sketchInfo?.curves.first { $0.id == c }?.construction == false }
        if !plain.isEmpty { run("sketch.construction", ["curves": plain, "value": true], quiet: true) }
        return r
    }

    // MARK: Dimension tool (B-5)

    func beginDimension() {
        guard sketchOpen else { return }
        if tool == .dimension { sketchToolChanged() } else { tool = .dimension }
    }

    private func dimensionClick(at p: CGPoint) {
        guard sketchOpen, let info = sketchInfo,
              let q = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize) else { return }
        dimensionOffer = nil
        let r = sketchPickRadii
        let hit = SketchPicker.pick(info, camera: camera, at: p, size: viewSize, glyphs: false, pointRadius: r.point, curveTolerance: r.curve)
        if let hit, dimensionPicks.count < 2, !dimensionPicks.contains(hit) {
            dimensionPicks.append(hit)
            return
        }
        guard !dimensionPicks.isEmpty else {
            flash(String(localized: "Pick a curve or a point to dimension"))
            return
        }
        placeDimension(at: q)
    }

    /// Places the dimension on the picks with its text at `q`, then opens its value field.
    func placeDimension(at q: SIMD2<Double>) {
        let ids = dimensionPicks.map(\.id)
        dimensionPicks = []
        guard !ids.isEmpty else { return }
        let before = Set(sketchInfo?.dimensions.map(\.id) ?? [])
        let params: [String: Any] = ["entities": ids, "text_at": [q.x, q.y], "scale_sketch": true]
        if run("sketch.dimension", params, quiet: true) != nil {
            if let d = sketchInfo?.dimensions.first(where: { !before.contains($0.id) }), d.param != nil, !d.driven {
                dimensionToEdit = d.id
            }
        } else if messageIsError, let m = message, m.localizedCaseInsensitiveContains("already determined") {
            dimensionOffer = DimensionOffer(entities: ids, at: q, reason: m)
        }
    }

    /// Adds the refused dimension as a driven (reference) one.
    func placeDrivenDimension() {
        guard let o = dimensionOffer else { return }
        dimensionOffer = nil
        run("sketch.dimension", ["entities": o.entities, "text_at": [o.at.x, o.at.y], "if_redundant": "driven"], quiet: true)
    }

    /// The Dimension tool's preview: where it measures from, where the text would go, and the
    /// text (the current measure for one line, circle, arc or two points; else what it measures).
    var dimensionPreview: (from: SIMD2<Double>, to: SIMD2<Double>, text: String)? {
        guard tool == .dimension, let info = sketchInfo, let cur = dimensionCursor, !dimensionPicks.isEmpty else { return nil }
        func spot(_ k: SketchPick) -> SIMD2<Double>? {
            if k.kind == .point { return info.points.first { $0.id == k.id }?.at }
            guard let c = info.curves.first(where: { $0.id == k.id }), !c.polyline.isEmpty else { return nil }
            return c.polyline[c.polyline.count / 2]
        }
        let spots = dimensionPicks.compactMap(spot)
        guard !spots.isEmpty else { return nil }
        let from = spots.reduce(SIMD2<Double>.zero, +) / Double(spots.count)
        func point(_ id: String?) -> SIMD2<Double>? { id.flatMap { i in info.points.first { $0.id == i }?.at } }
        var text: String
        let kinds = dimensionPicks.map(\.kind)
        if dimensionPicks.count == 1, let c = info.curves.first(where: { $0.id == dimensionPicks[0].id }) {
            switch kinds[0] {
            case .line: text = SketchInfo.Dimension.shown(simd_distance(c.polyline[0], c.polyline[c.polyline.count - 1]), .length)
            case .circle: text = point(c.center).map { "D " + SketchInfo.Dimension.shown(2 * simd_distance($0, c.polyline[0]), .length) } ?? String(localized: "Diameter")
            case .arc: text = point(c.center).map { "R " + SketchInfo.Dimension.shown(simd_distance($0, c.polyline[0]), .length) } ?? String(localized: "Radius")
            default: text = String(localized: "Dimension")
            }
        } else if kinds == [.point, .point], spots.count == 2 {
            text = SketchInfo.Dimension.shown(simd_distance(spots[0], spots[1]), .length)
        } else if kinds == [.line, .line] {
            text = String(localized: "Angle")
        } else if dimensionPicks.count == 1 {
            text = String(localized: "Pick a second entity, or click to place")
        } else {
            text = String(localized: "Distance")
        }
        return (from, cur, text)
    }
}

// MARK: Self test

enum SketchSelfTest {
    /// `--sketch-selftest`: runs only these checks, prints them and quits (before the lead wires
    /// them into SelfTest.swift).
    @MainActor static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--sketch-selftest") else { return }
        DispatchQueue.main.async {
            let results = checks()
            let failures = results.filter { !$0.0 }.count
            let lines = results.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 } + [failures == 0 ? "ALL PASS" : "\(failures) FAILED"]
            print(lines.joined(separator: "\n"))
            fflush(stdout)
            // `--sketch-selftest-out=<path>` also writes them there (a launch through `open`).
            if let out = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--sketch-selftest-out=") })?.dropFirst(22) {
                try? lines.joined(separator: "\n").write(toFile: String(out), atomically: true, encoding: .utf8)
            }
            exit(failures == 0 ? 0 : 1)
        }
    }

    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let m = DesignModel()
        m.run("file.new", quiet: true)
        m.startSketch("XY")
        m.run("sketch.line", ["points": [[0, 0], [30, 10]]], quiet: true)
        m.tool = .select
        m.viewSize = CGSize(width: 1000, height: 700)
        m.setView(.top)
        m.camera.target = SIMD3(15, 5, 0)
        m.cameraChanged(final: true)
        guard let info = m.sketchInfo, let line = info.curves.first(where: { $0.kind == "line" }), let plane = m.sketchPlane else {
            return [(false, "B-1 a sketch with one line opens")]
        }
        func screen(_ q: SIMD2<Double>) -> CGPoint { m.camera.project(plane.toWorld(q), size: m.viewSize) }
        let mid = (line.polyline[0] + line.polyline[line.polyline.count - 1]) / 2
        m.click(at: screen(mid), mode: .replace)
        out.append((m.sketchSelection == [SketchPick(id: line.id, kind: .line)], "B-1 a click on the line selects it (\(m.sketchSelection))"))

        let valid = SketchConstraintCatalog.valid(for: m.sketchSelection).map(\.id)
        out.append((valid.contains("horizontal") && valid.contains("vertical") && valid.contains("fix") && !valid.contains("parallel"),
                    "B-4 one line offers Horizontal, Vertical and Fix, not Parallel (\(valid))"))
        let twoLines = [SketchPick(id: "a", kind: .line), SketchPick(id: "b", kind: .line)]
        let lc = [SketchPick(id: "c", kind: .circle), SketchPick(id: "l", kind: .line)]
        out.append((SketchConstraintCatalog.valid(for: twoLines).map(\.id).contains("parallel")
                    && SketchConstraintCatalog.valid(for: lc).map(\.id).contains("tangent")
                    && !SketchConstraintCatalog.valid(for: lc).map(\.id).contains("parallel"),
                    "B-4 two lines offer Parallel; a circle and a line offer Tangent, not Parallel"))

        let dof0 = m.sketchState?.dof ?? -1
        let applied = m.applyConstraint(id: "horizontal")
        let dof1 = m.sketchState?.dof ?? -1
        out.append((applied && dof1 == dof0 - 1, "B-3/B-4 Horizontal runs and the DOF drops (\(dof0) to \(dof1))"))
        let glyph = m.sketchInfo?.glyphs.first { $0.name == "Horizontal" }
        out.append((glyph != nil, "B-2 the Horizontal glyph appears"))

        if let glyph, let info2 = m.sketchInfo,
           let spot = SketchGlyphLayout.spots(info2, camera: m.camera, size: m.viewSize).first(where: { $0.glyph.id == glyph.id }) {
            m.click(at: spot.at, mode: .replace)
            out.append((m.sketchSelection == [SketchPick(id: glyph.id, kind: .constraint)], "B-2 a click on the glyph selects it"))
            m.deleteSelection()
            out.append((m.sketchInfo?.glyphs.contains { $0.id == glyph.id } == false && (m.sketchState?.dof ?? -1) == dof0,
                        "B-2 Delete removes the constraint and gives the DOF back"))
        } else {
            out.append((false, "B-2 the glyph has a place on screen"))
        }

        // Dimension by picking: the line, then a click beside it, then the value typed.
        m.tool = .dimension
        let line2 = m.sketchInfo?.curves.first { $0.id == line.id } ?? line
        let mid2 = (line2.polyline[0] + line2.polyline[line2.polyline.count - 1]) / 2
        m.click(at: screen(mid2), mode: .replace)
        out.append((m.dimensionPicks == [SketchPick(id: line.id, kind: .line)], "B-5 the Dimension tool picks the line"))
        m.hover(at: screen(mid2 + SIMD2(0, -12)))
        out.append((m.dimensionPreview != nil, "B-5 the dimension previews before it is placed"))
        m.click(at: screen(mid2 + SIMD2(0, -12)), mode: .replace)
        if let id = m.dimensionToEdit, let d = m.sketchInfo?.dimensions.first(where: { $0.id == id }) {
            m.dimensionToEdit = nil
            m.setDimension(d, to: "40")
            let v = m.sketchInfo?.dimensions.first { $0.id == id }?.value ?? 0
            out.append((abs(v - 40) < 1e-6, "B-5 the placed dimension opens for typing and takes 40 (\(v))"))
        } else {
            out.append((false, "B-5 a dimension is placed and opened for typing (\(m.message ?? "no message"))"))
        }
        m.tool = .select

        let line3 = m.sketchInfo?.curves.first { $0.id == line.id } ?? line2
        m.click(at: screen((line3.polyline[0] + line3.polyline[line3.polyline.count - 1]) / 2), mode: .replace)
        m.toggleConstruction()
        out.append((m.sketchInfo?.curves.first { $0.id == line.id }?.construction == true, "B-9 the selected line becomes construction"))
        m.sketchSelection = []
        m.toggleConstruction()
        out.append((m.constructionMode, "B-9 with nothing selected, the toggle arms construction mode"))
        m.tool = .line
        m.drawSketch("sketch.line", ["points": [[0, 20], [10, 20]]])
        let newest = m.sketchInfo?.curves.last
        out.append((newest?.construction == true, "B-9 a line drawn in construction mode is construction"))
        m.finishSketch()
        out.append((m.sketchSelection.isEmpty && !m.constructionMode, "B-1 finishing the sketch clears the selection"))
        return out
    }
}
