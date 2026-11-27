import CoreGraphics
import Foundation
import simd

// Drawing in the open sketch (gaps B-6, B-8, B-11, B-12, M-16 trim drag).
//
// Public API for the surfaces. Everything runs engine commands; the Swift side only gathers
// clicks, previews the shape being drawn and turns typed sizes into the command's points.
//
//   SketchSnapSettings.geometry / .grid      the snapping switches both apps share: master
//                                            `snapKey` (Mac Sketch Palette), then `geometryKey` /
//                                            `snapToGridKey` (iPad rail). Sole owner of the keys.
//   SketchDisplaySettings                    Sketch Palette options, one key each, Mac and iPad:
//                                            points, dimensions, profile, projected, grid,
//                                            constraints, exitOnOrbit. Sole owner of the keys.
//   model.cursorHit: SnapHit?                what the cursor snaps to (point, midpoint, curve,
//                                            horizontal or vertical to the last click, grid).
//   model.inferenceLine                      the dashed alignment line to draw (B-6), or nil.
//   model.sizeFields: [SizeField]            the size boxes on the rubber band (B-8): line length
//                                            and angle, rectangle width and height, circle
//                                            diameter, polygon radius, slot length then width.
//   model.typeSize(_:) / sizeBackspace()     typing into the active box (digits, ".", "-", units).
//   model.sizeTab(backward:)                 Tab: keeps the typed value, moves to the next box.
//   model.setSize(_ role:, text:)            sets one box from a text field (iPad).
//   model.sizeCommit()                       Return: places the shape at the typed size; the
//                                            typed sizes become driving dimensions
//                                            (`sketch.draw.dimensioned`).
//   model.beginTangentArc(at:) / dragTangentArc(to:) / endTangentArc()
//                                            B-12: a press and drag from the end of a line chain
//                                            draws a tangent arc (`sketch.arc.tangent`).
//   model.trimDrag(path:size:)               M-16: trims every piece a drawn path crosses
//                                            (`sketch.trim.path`); `dragTrim(to:)` previews it.
//   model.drawingHint                        what the armed sketch tool waits for, in words.
//   Tool.moreSketchTools                     B-11: Project, Sketch Mirror, 3-Point Rectangle,
//                                            2-Point and 3-Point Circle, Ellipse, Extend,
//                                            Rectangular and Circular Pattern. Mirror and the
//                                            patterns take the picked entities (or the sketch
//                                            selection), then Return, then the line or place.
//
// Auto constraints (B-6): a line end that snapped to a midpoint gets a Midpoint constraint, one
// that snapped onto a curve gets a point-on-curve Coincident, and a line drawn horizontal or
// vertical gets that constraint (`infer`). Ends that land on a point are joined by the engine
// (`connect`).

/// The sketch snapping switches, one setting for both apps and the only owner of their keys:
/// the Mac Sketch Palette and the iPad snap rail bind these constants (@AppStorage) and nothing
/// else. `snapKey` (the Sketch Palette's Snap, Mac) turns all snapping off; the iPad snap rail's
/// two toggles (`geometryKey`, `snapToGridKey`) choose what it snaps to. Each a Bool, true by
/// default.
enum SketchSnapSettings {
    static let snapKey = "sketch.palette.snap"
    static let geometryKey = "viaform.touch.snap.geometry"
    /// Snap to the grid (not the grid's display: `SketchDisplaySettings.gridKey`).
    static let snapToGridKey = "viaform.touch.snap.grid"
    @available(*, deprecated, renamed: "snapToGridKey")
    static let gridKey = snapToGridKey
    /// Every key, for a reset or a test.
    static let allKeys = [snapKey, geometryKey, snapToGridKey]
    private static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static func set(_ on: Bool, for key: String) { UserDefaults.standard.set(on, forKey: key) }
    /// Snapping at all.
    static var enabled: Bool { flag(snapKey) }
    /// Snap to points, midpoints, curves and alignments.
    static var geometry: Bool { enabled && flag(geometryKey) }
    /// Snap to the grid when nothing else is near.
    static var grid: Bool { enabled && flag(snapToGridKey) }
}

/// What the open sketch shows, and how it behaves, for Mac and iPad: the only owner of these
/// keys. The Sketch Palette (Mac), the iPad sketch settings and the canvas layers bind the
/// constants (@AppStorage) and read them live; nothing keeps its own copy. Each a Bool, true
/// by default except `exitOnOrbitKey`.
enum SketchDisplaySettings {
    static let pointsKey = "sketch.palette.points"
    static let dimensionsKey = "sketch.palette.dimensions"
    static let profileKey = "sketch.palette.profile"
    static let projectedKey = "sketch.palette.projected"
    /// Show the sketch grid (not snapping to it: `SketchSnapSettings.snapToGridKey`).
    static let gridKey = "sketch.palette.grid"
    /// Draw constraint glyphs ("Show constraints"), mirrored by `DesignModel.showConstraints`.
    static let constraintsKey = "sketch.showConstraints"
    /// T-17: finish the sketch when the view rests more than 60 degrees away from its plane.
    /// Off by default (the iPad sketch settings toggle).
    static let exitOnOrbitKey = "viaform.touch.sketch.exitOnOrbit"
    /// Every key, for a reset or a test.
    static let allKeys = [pointsKey, dimensionsKey, profileKey, projectedKey, gridKey, constraintsKey, exitOnOrbitKey]
    private static func flag(_ key: String, _ fallback: Bool = true) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
    static func set(_ on: Bool, for key: String) { UserDefaults.standard.set(on, forKey: key) }
    static var points: Bool { flag(pointsKey) }
    static var dimensions: Bool { flag(dimensionsKey) }
    static var profile: Bool { flag(profileKey) }
    static var projected: Bool { flag(projectedKey) }
    static var grid: Bool { flag(gridKey) }
    static var constraints: Bool { flag(constraintsKey) }
    static var exitOnOrbit: Bool { flag(exitOnOrbitKey, false) }
}

/// What a click on the sketch plane snaps to (`sketch.snap`), with the ids it refers to.
struct SnapHit: Equatable {
    enum Kind: String {
        case coincident, midpoint, onCurve = "on_curve", horizontal, vertical, grid, none
    }

    var at: SIMD2<Double>
    var kind: Kind
    /// The existing point (coincident).
    var point: String?
    /// The curve (midpoint, on curve).
    var curve: String?
    /// The click it aligns with (horizontal, vertical).
    var from: SIMD2<Double>?

    /// The word shown beside the cursor.
    var label: String? {
        switch kind {
        case .coincident: String(localized: "Point")
        case .midpoint: String(localized: "Midpoint")
        case .onCurve: String(localized: "On curve")
        case .horizontal: String(localized: "Horizontal")
        case .vertical: String(localized: "Vertical")
        case .grid, .none: nil
        }
    }
}

/// Sizes typed while drawing (B-8).
struct SizeEntry: Equatable {
    /// Typed values by role, in millimetres or degrees.
    var values: [String: Double] = [:]
    /// The box keys go to (an index into `sizeFields`).
    var active = 0
    /// What is being typed into the active box.
    var text = ""

    var isEmpty: Bool { values.isEmpty && text.isEmpty }
}

/// One size box on the rubber band.
struct SizeField: Identifiable, Equatable {
    /// The `sketch.draw.dimensioned` role: length, angle, width, height, diameter, radius.
    var role: String
    var label: String
    /// The typed value, or the size as drawn.
    var value: Double
    var typed: Bool
    var active: Bool
    /// The text being typed, when this box is active and has some.
    var text: String?
    /// Where the box goes, in sketch coordinates.
    var anchor: SIMD2<Double>
    var isAngle: Bool

    var id: String { role }

    /// What the box shows: the text being typed, else the value in display units.
    var shown: String { text ?? (isAngle ? VFFormat.angle(value) : VFFormat.length(value)) }
}

/// A tangent arc being dragged from the end of a line chain (B-12).
struct TangentArcDrag: Equatable {
    /// The point the arc starts from (the chain's end).
    var start: String
    var from: SIMD2<Double>
    /// The unit direction the chain leaves `from` in.
    var tangent: SIMD2<Double>
    var end: SIMD2<Double>?
}

extension Tool {
    /// Tools that take picked sketch entities, then a line or a place.
    var takesSketchEntities: Bool { self == .sketchMirror || self == .sketchRectPattern || self == .sketchCircPattern }
}

extension DesignModel {
    // MARK: Snapping (B-6)

    private func pt(_ p: SIMD2<Double>) -> [Double] { [p.x, p.y] }

    private var snapRadius: Double { camera.halfHeight * 0.03 }

    private func engineSnaps(_ q: SIMD2<Double>, from: SIMD2<Double>?) -> [[String: Any]] {
        var p: [String: Any] = ["at": pt(q), "radius": snapRadius]
        if let from { p["from"] = pt(from) }
        let r = (try? engine.execute("sketch.snap", p)) as? [String: Any]
        return r?["snaps"] as? [[String: Any]] ?? []
    }

    /// Where a click at `q` lands: an existing point, a midpoint, an alignment with `from`, a
    /// curve, else the grid (each as the snapping switches allow).
    func snapHit(_ q: SIMD2<Double>, from: SIMD2<Double>? = nil) -> SnapHit {
        let grid = SketchSnapSettings.grid
        let s = gridStep / 2
        func onGrid(_ v: Double) -> Double { grid ? (v / s).rounded() * s : v }
        if SketchSnapSettings.geometry {
            let snaps = engineSnaps(q, from: from)
            let best = snaps.first { ($0["type"] as? String) != "on_curve" } ?? snaps.first
            if let best, let at = SketchInfo.vec2(best["at"]) {
                let kind = SnapHit.Kind(rawValue: best["type"] as? String ?? "") ?? .none
                var hit = SnapHit(at: at, kind: kind, point: best["point"] as? String, curve: best["curve"] as? String)
                switch kind {
                case .horizontal:
                    hit.from = from
                    hit.at.x = onGrid(q.x)
                case .vertical:
                    hit.from = from
                    hit.at.y = onGrid(q.y)
                default: break
                }
                return hit
            }
        }
        if grid { return SnapHit(at: SIMD2(onGrid(q.x), onGrid(q.y)), kind: .grid) }
        return SnapHit(at: q, kind: .none)
    }

    /// The curve under `q` (sketch coordinates), if any.
    func sketchCurve(near q: SIMD2<Double>) -> String? {
        engineSnaps(q, from: nil).compactMap { $0["curve"] as? String }.first
    }

    /// The sketch point under `q`, if any.
    func sketchPointRef(near q: SIMD2<Double>) -> String? {
        engineSnaps(q, from: nil).compactMap { $0["point"] as? String }.first
    }

    /// The dashed alignment line to draw from the cursor's snap (sketch coordinates).
    var inferenceLine: (from: SIMD2<Double>, to: SIMD2<Double>)? {
        guard tool.isSketchTool, let h = cursorHit, let f = h.from, h.kind == .horizontal || h.kind == .vertical else { return nil }
        return (f, h.at)
    }

    // MARK: Pointer (called from DesignModel.hover and click)

    /// The pointer moved with a sketch tool armed.
    func sketchToolHover(at p: CGPoint) {
        if tool == .project {
            cursor = nil
            hover = ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: true)
            return
        }
        if tool.takesSketchEntities || tool == .extend || tool == .trim, let info = sketchInfo {
            let h = SketchPicker.pick(info, camera: camera, at: p, size: viewSize, glyphs: false)
            if h != sketchHover { sketchHover = h }
        }
        guard let plane = sketchPlane, let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
        if tangentArc != nil { dragTangentArc(to: p); return }
        let hit = snapHit(q, from: tool == .line ? clicks.last : nil)
        cursor = hit.at
        cursorSnap = hit.label
        if hit != cursorHit { cursorHit = hit }
        if hover != nil { hover = nil }
    }

    /// A click or tap with a sketch tool armed.
    func sketchToolClick(at p: CGPoint, mode: SelectMode) {
        switch tool {
        case .project: projectClick(at: p); return
        case .sketchMirror, .sketchRectPattern, .sketchCircPattern: entityOpClick(at: p, mode: mode); return
        default: break
        }
        guard let plane = sketchPlane, let raw = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
        var hit = snapHit(raw, from: tool == .line ? clicks.last : nil)
        if !sizeEntry.isEmpty, !sizeFields.isEmpty {
            // Typed sizes win over the snap: the click only says which way the shape goes.
            commitSizeText()
            hit = SnapHit(at: sizedPoint(hit.at), kind: .none)
        }
        sketchClick(hit, raw: raw)
    }

    private func sketchClick(_ hit: SnapHit, raw: SIMD2<Double>) {
        let q = hit.at
        switch tool {
        case .line:
            if let last = clicks.last, let startHit = clickSnaps.last {
                guard simd_distance(last, q) > 1e-9 else { return }
                drawLine(from: last, startHit: startHit, to: hit)
                sizeEntry = SizeEntry()
                // Landing on an existing point closes the loop and ends the chain.
                if hit.kind == .coincident { clicks = []; clickSnaps = [] } else { clicks = [q]; clickSnaps = [hit] }
            } else {
                clicks = [q]
                clickSnaps = [hit]
            }
        case .spline:
            clicks.append(q)
            clickSnaps.append(hit)
        case .trim:
            if let c = sketchCurve(near: raw) { run("sketch.trim", ["curve": c, "at": pt(raw)]) }
        case .extend:
            if let c = sketchCurve(near: raw) { run("sketch.extend", ["curve": c, "at": pt(raw)]) }
        case .offset:
            if let c = sketchCurve(near: raw) { run("sketch.offset", ["curves": [c], "distance": toolValue]) }
        case .sketchFillet:
            if let p = sketchPointRef(near: raw) { run("sketch.fillet", ["point": p, "radius": toolValue]) }
        default:
            clicks.append(q)
            clickSnaps.append(hit)
            if clicks.count >= tool.clicks { commitSketchShape() }
        }
    }

    /// Runs `quietly` without flashing a failure (inferred constraints the sketch already has).
    private func tryRun(_ id: String, _ params: [String: Any]) -> Bool {
        (try? engine.execute(id, params)) != nil
    }

    private func createdCurves(_ reply: Any?) -> [String] {
        let r = reply as? [String: Any]
        return (r?["created"] as? [String: Any])?["curves"] as? [String] ?? r?["curves"] as? [String] ?? []
    }

    private func drawLine(from a: SIMD2<Double>, startHit: SnapHit, to hit: SnapHit) {
        var params: [String: Any] = ["points": [pt(a), pt(hit.at)]]
        let dims = typedDimensions(["length", "angle"])
        // An angle typed is the line's own: no Horizontal or Vertical on top of it.
        if dims["angle"] == nil { params["infer"] = true }
        let reply = draw("sketch.line", params, dims)
        guard let line = createdCurves(reply).first, let ends = sketchInfo?.curves.first(where: { $0.id == line })?.ends, ends.count == 2 else { return }
        var added = false
        for (h, end) in [(startHit, ends[0]), (hit, ends[1])] {
            switch h.kind {
            case .midpoint:
                if let c = h.curve, c != line { added = tryRun("sketch.constraint.midpoint", ["point": end, "line": c]) || added }
            case .onCurve:
                if let c = h.curve, c != line { added = tryRun("sketch.constraint.coincident", ["a": end, "b": c]) || added }
            default: break
            }
        }
        if added { refresh() }
    }

    /// Runs a creation command, with the typed sizes as driving dimensions when there are some.
    @discardableResult
    private func draw(_ command: String, _ params: [String: Any], _ dims: [String: Any]) -> Any? {
        guard !dims.isEmpty else { return drawSketch(command, params) }
        var p = params
        if constructionMode { p["construction"] = true }
        return run("sketch.draw.dimensioned", ["command": command, "params": p, "dimensions": dims], quiet: true)
    }

    /// The typed sizes among `roles`, as `sketch.draw.dimensioned` takes them.
    private func typedDimensions(_ roles: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for r in roles {
            guard let v = sizeEntry.values[r] else { continue }
            out[r] = r == "angle" ? "\(VFFormat.editable(v)) deg" : v as Any
        }
        return out
    }

    private func commitSketchShape() {
        let c = clicks
        clicks = []
        clickSnaps = []
        defer { sizeEntry = SizeEntry() }
        switch tool {
        case .rectangle:
            draw("sketch.rectangle.two_point", ["p0": pt(c[0]), "p1": pt(c[1])], typedDimensions(["width", "height"]))
        case .centerRectangle:
            draw("sketch.rectangle.center", ["center": pt(c[0]), "corner": pt(c[1])], typedDimensions(["width", "height"]))
        case .circle:
            let r = simd_distance(c[0], c[1])
            if r > 0 { draw("sketch.circle.center", ["center": pt(c[0]), "radius": r], typedDimensions(["diameter"])) }
        case .polygon:
            let r = simd_distance(c[0], c[1])
            let a = atan2(c[1].y - c[0].y, c[1].x - c[0].x) * 180 / .pi
            if r > 0 {
                draw("sketch.polygon.inscribed", ["center": pt(c[0]), "radius": r, "sides": max(3, Int(toolValue)), "angle": a],
                     typedDimensions(["radius"]))
            }
        case .arc:
            drawSketch("sketch.arc.three_point", ["start": pt(c[0]), "end": pt(c[1]), "through": pt(c[2])])
        case .slot:
            let d = c[1] - c[0]
            let len = simd_length(d)
            guard len > 0 else { return }
            let n = SIMD2(-d.y, d.x) / len
            let w = abs(simd_dot(c[2] - c[0], n)) * 2
            if w > 0 { draw("sketch.slot.center_to_center", ["p0": pt(c[0]), "p1": pt(c[1]), "width": w], typedDimensions(["length", "width"])) }
        case .point:
            drawSketch("sketch.point", ["point": pt(c[0])])
        case .threePointRectangle:
            drawSketch("sketch.rectangle.three_point", ["p0": pt(c[0]), "p1": pt(c[1]), "p2": pt(c[2])])
        case .twoPointCircle:
            if simd_distance(c[0], c[1]) > 0 { drawSketch("sketch.circle.two_point", ["p0": pt(c[0]), "p1": pt(c[1])]) }
        case .threePointCircle:
            drawSketch("sketch.circle.three_point", ["p0": pt(c[0]), "p1": pt(c[1]), "p2": pt(c[2])])
        case .ellipse:
            drawSketch("sketch.ellipse", ["center": pt(c[0]), "major": pt(c[1]), "minor": pt(c[2])])
        default:
            break
        }
    }

    /// Ends an open-ended tool (line chain, spline), as Return or Done does. Typed sizes are
    /// placed first; Mirror and the patterns move on to their line or place.
    func endChain() {
        // Escape in the Dimension tool drops its picks, then leaves the tool.
        if tool == .dimension { if !cancelSketchPicks() { tool = .select }; return }
        if !sizeEntry.isEmpty, !sizeFields.isEmpty { sizeCommit(); return }
        if tool.takesSketchEntities {
            if !sketchOpTarget, sketchSelection.contains(where: { $0.kind != .constraint }) {
                sketchOpTarget = true
                flash(drawingHint)
            }
            return
        }
        if tool == .spline, clicks.count >= 2 {
            drawSketch("sketch.spline.fit_point", ["points": clicks.map(pt)])
        }
        clicks = []
        clickSnaps = []
    }

    /// Escape while drawing: drops typed sizes, a tangent arc, the second step of Mirror or a
    /// pattern, or the pick list. True when something was dropped.
    func cancelDrawingStep() -> Bool {
        if pickList != nil { pickList = nil; return true }
        if tangentArc != nil { tangentArc = nil; return true }
        if !sizeEntry.isEmpty { sizeEntry = SizeEntry(); return true }
        if sketchOpTarget { sketchOpTarget = false; flash(nil); return true }
        return false
    }

    /// The tool changed: drawing state starts over. Mirror and the patterns take the current
    /// sketch selection as their entities.
    func drawingToolChanged() {
        clickSnaps = []
        cursorHit = nil
        sizeEntry = SizeEntry()
        tangentArc = nil
        trimPath = []
        sketchOpTarget = tool.takesSketchEntities && sketchSelection.contains { $0.kind != .constraint }
        if tool.takesSketchEntities { sketchSelection.removeAll { $0.kind == .constraint } }
    }

    /// What the armed sketch tool waits for, in the words of the platform's input: taps and
    /// Done on iPad and iPhone, clicks and Return on the Mac.
    var drawingHint: String? {
        #if os(iOS)
        drawingHint(touch: true)
        #else
        drawingHint(touch: false)
        #endif
    }

    /// What the armed sketch tool waits for. `touch` words it for fingers and the Pencil (Tap,
    /// Done) instead of the pointer and keyboard (Click, Return).
    func drawingHint(touch: Bool) -> String? {
        switch tool {
        case .project:
            return touch ? String(localized: "Tap model edges or faces to project them into the sketch")
                         : String(localized: "Click model edges or faces to project them into the sketch")
        case .sketchMirror:
            if touch { return sketchOpTarget ? String(localized: "Tap the mirror line") : String(localized: "Pick curves to mirror, then tap Done") }
            return sketchOpTarget ? String(localized: "Click the mirror line") : String(localized: "Pick curves to mirror, then press Return")
        case .sketchRectPattern:
            if touch { return sketchOpTarget ? String(localized: "Tap where the next copy goes") : String(localized: "Pick curves to pattern, then tap Done") }
            return sketchOpTarget ? String(localized: "Click where the next copy goes") : String(localized: "Pick curves to pattern, then press Return")
        case .sketchCircPattern:
            if touch { return sketchOpTarget ? String(localized: "Tap the pattern centre") : String(localized: "Pick curves to pattern, then tap Done") }
            return sketchOpTarget ? String(localized: "Click the pattern centre") : String(localized: "Pick curves to pattern, then press Return")
        case .extend:
            return touch ? String(localized: "Tap near the end of a curve to extend it")
                         : String(localized: "Click near the end of a curve to extend it")
        case .trim:
            return touch ? String(localized: "Tap a piece to remove it, or drag across several")
                         : String(localized: "Click a piece to remove it, or drag across several")
        case .threePointRectangle:
            return touch ? String(localized: "Tap the first edge's two ends, then the opposite side")
                         : String(localized: "Click the first edge's two ends, then the opposite side")
        case .threePointCircle:
            return touch ? String(localized: "Tap three points on the circle") : String(localized: "Click three points on the circle")
        case .twoPointCircle:
            return touch ? String(localized: "Tap the two ends of a diameter") : String(localized: "Click the two ends of a diameter")
        case .ellipse:
            return touch ? String(localized: "Tap the centre, the end of the major axis, then a point on the ellipse")
                         : String(localized: "Click the centre, the end of the major axis, then a point on the ellipse")
        case .line where !clicks.isEmpty:
            return touch ? String(localized: "Type a length, then the angle. Drag from the end for an arc")
                         : String(localized: "Type a length, Tab for the angle. Drag from the end for an arc")
        default:
            if sizeFields.isEmpty { return nil }
            return touch ? String(localized: "Type a size, then the next, and tap Done to place")
                         : String(localized: "Type a size, Tab for the next, Return to place")
        }
    }

    // MARK: Project (B-11)

    private func projectClick(at p: CGPoint) {
        guard let hit = ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: true), hit.mesh < scene.meshes.count else {
            flash(String(localized: "Pick a model edge or face to project"))
            return
        }
        var ref: [String: Any] = hit.isEdge ? ["edge": hit.points] : ["face": hit.points]
        ref["body"] = scene.meshes[hit.mesh].body
        run("sketch.project", ["refs": [ref]], quiet: true)
    }

    // MARK: Mirror and patterns (B-11)

    private func entityOpClick(at p: CGPoint, mode: SelectMode) {
        guard sketchOpen, let info = sketchInfo, let plane = sketchPlane else { return }
        let hit = SketchPicker.pick(info, camera: camera, at: p, size: viewSize, glyphs: false)
        guard sketchOpTarget else {
            guard let hit else { return }
            if let i = sketchSelection.firstIndex(of: hit) { sketchSelection.remove(at: i) } else { sketchSelection.append(hit) }
            return
        }
        let ids = sketchSelection.filter { $0.kind != .constraint }.map(\.id)
        guard !ids.isEmpty else { sketchOpTarget = false; return }
        let count = max(2, Int(toolValue))
        var done = false
        switch tool {
        case .sketchMirror:
            guard let hit, hit.kind == .line else { flash(String(localized: "Click the mirror line"), error: true); return }
            done = run("sketch.mirror", ["entities": ids, "line": hit.id], quiet: true) != nil
        case .sketchCircPattern:
            guard let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
            let s = snapHit(q)
            let center: Any = s.kind == .coincident ? (s.point ?? "") as Any : pt(s.at) as Any
            done = run("sketch.pattern.circular", ["entities": ids, "center": center, "count": count], quiet: true) != nil
        case .sketchRectPattern:
            guard let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
            let to = snapHit(q).at
            let base = entitiesCentre(ids, info)
            let d = to - base
            let len = simd_length(d)
            guard len > 1e-9 else { return }
            done = run("sketch.pattern.rectangular", ["entities": ids, "count": count, "spacing": len, "dir": pt(d / len)], quiet: true) != nil
        default: break
        }
        if done {
            sketchSelection = []
            sketchOpTarget = false
        }
    }

    /// The middle of the picked entities' points (where a rectangular pattern measures from).
    private func entitiesCentre(_ ids: [String], _ info: SketchInfo) -> SIMD2<Double> {
        var pts: [SIMD2<Double>] = []
        for id in ids {
            if let c = info.curves.first(where: { $0.id == id }) { pts += c.polyline } else if let q = info.points.first(where: { $0.id == id }) { pts.append(q.at) }
        }
        guard !pts.isEmpty else { return .zero }
        let lo = pts.reduce(pts[0]) { simd_min($0, $1) }, hi = pts.reduce(pts[0]) { simd_max($0, $1) }
        return (lo + hi) / 2
    }

    // MARK: Tangent arc (B-12)

    /// A press near the end of the line chain: the drag draws a tangent arc. True when it began.
    func beginTangentArc(at p: CGPoint, radius: CGFloat = 10) -> Bool {
        guard sketchOpen, tool == .line, let last = clicks.last, let info = sketchInfo, let plane = sketchPlane else { return false }
        let s = camera.project(plane.toWorld(last), size: viewSize)
        guard hypot(s.x - p.x, s.y - p.y) <= radius else { return false }
        let tol = 1e-6 * max(1, simd_length(last))
        guard let point = info.point(near: last, radius: tol),
              let c = info.curves.first(where: { $0.ends.contains(point.id) && $0.polyline.count >= 2 }) else { return false }
        let poly = c.polyline
        let atStart = simd_distance(poly[0], last) < simd_distance(poly[poly.count - 1], last)
        let d = atStart ? poly[0] - poly[1] : poly[poly.count - 1] - poly[poly.count - 2]
        guard simd_length(d) > 0 else { return false }
        tangentArc = TangentArcDrag(start: point.id, from: last, tangent: simd_normalize(d), end: nil)
        return true
    }

    func dragTangentArc(to p: CGPoint) {
        guard tangentArc != nil, let plane = sketchPlane, let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
        let hit = snapHit(q)
        tangentArc?.end = hit.at
        cursor = hit.at
        cursorSnap = hit.label
    }

    /// Ends the drag: the arc is drawn and the chain goes on from its end.
    func endTangentArc(at p: CGPoint? = nil) {
        if let p { dragTangentArc(to: p) }
        guard let arc = tangentArc else { return }
        tangentArc = nil
        guard let end = arc.end, simd_distance(end, arc.from) > 1e-6 else { return }
        let reply = run("sketch.arc.tangent", ["start": arc.start, "end": pt(end)], quiet: true)
        guard reply != nil else { return }
        if constructionMode {
            let made = createdCurves(reply)
            if !made.isEmpty { run("sketch.construction", ["curves": made, "value": true], quiet: true) }
        }
        clicks = [end]
        clickSnaps = [SnapHit(at: end, kind: .none)]
    }

    /// The tangent arc from `from` along `t` to `end`, as a polyline (a line when they are in a row).
    static func tangentArcPolyline(from a: SIMD2<Double>, tangent t: SIMD2<Double>, to b: SIMD2<Double>) -> [SIMD2<Double>] {
        let n = SIMD2(-t.y, t.x)
        let d = b - a
        let den = 2 * simd_dot(d, n)
        guard abs(den) > 1e-9 else { return [a, b] }
        let r = simd_dot(d, d) / den
        let c = a + n * r
        let a0 = atan2(a.y - c.y, a.x - c.x)
        var sweep = atan2(b.y - c.y, b.x - c.x) - a0
        // Counter-clockwise when the tangent turns left (r > 0).
        if r > 0 { while sweep <= 0 { sweep += 2 * .pi } } else { while sweep >= 0 { sweep -= 2 * .pi } }
        let radius = abs(r)
        return (0...40).map { i in
            let a = a0 + sweep * Double(i) / 40
            return c + SIMD2(cos(a), sin(a)) * radius
        }
    }

    // MARK: Trim by dragging (M-16)

    /// A point of the trim path under the pointer (`p` in viewport points).
    func dragTrim(to p: CGPoint) {
        guard sketchOpen, let plane = sketchPlane, let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
        trimPath.append(q)
    }

    /// Trims every piece the path (viewport points) crosses, one undo step. Answers how many.
    @discardableResult
    func trimDrag(path: [CGPoint], size: CGSize) -> Int {
        defer { trimPath = [] }
        guard sketchOpen, let plane = sketchPlane else { return 0 }
        var pts = path.compactMap { ScenePicker.onPlane(plane, camera: camera, at: $0, size: size) }
        if pts.count > 2000 { pts = stride(from: 0, to: pts.count, by: pts.count / 1000 + 1).map { pts[$0] } + [pts[pts.count - 1]] }
        guard pts.count >= 2 else { return 0 }
        let r = run("sketch.trim.path", ["points": pts.map(pt)], quiet: true) as? [String: Any]
        return (r?["trimmed"] as? [Any])?.count ?? 0
    }

    // MARK: Rubber band

    /// The preview of the shape being drawn, in sketch coordinates: polylines.
    var rubberBand: [[SIMD2<Double>]] {
        if let arc = tangentArc {
            guard let end = arc.end else { return [] }
            return [Self.tangentArcPolyline(from: arc.from, tangent: arc.tangent, to: end)]
        }
        if trimPath.count > 1 { return [trimPath] }
        guard let raw = cursor, !clicks.isEmpty else { return [] }
        let cur = sizedPoint(raw)
        let c = clicks
        switch tool {
        case .line: return [[c[c.count - 1], cur]]
        case .spline: return [c + [cur]]
        case .rectangle:
            let a = c[0], b = cur
            return [[a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y), a]]
        case .centerRectangle:
            let d = cur - c[0], a = c[0] - d, b = cur
            return [[a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y), a]]
        case .circle, .polygon:
            let r = simd_distance(c[0], cur)
            let n = tool == .polygon ? max(3, Int(toolValue)) : 64
            let a0 = atan2(cur.y - c[0].y, cur.x - c[0].x)
            return [ring(c[0], r, a0, n)]
        case .twoPointCircle:
            return [ring((c[0] + cur) / 2, simd_distance(c[0], cur) / 2, 0, 64)]
        case .threePointRectangle:
            if c.count == 1 { return [[c[0], cur]] }
            let u = c[1] - c[0]
            let len = simd_length(u)
            guard len > 0 else { return [] }
            let n = SIMD2(-u.y, u.x) / len
            let h = n * simd_dot(cur - c[0], n)
            return [[c[0], c[1], c[1] + h, c[0] + h, c[0]]]
        case .threePointCircle, .arc:
            if c.count == 1 { return [[c[0], cur]] }
            return tool == .arc ? [[c[0], cur, c[1]]] : [[c[0], c[1], cur]]
        case .ellipse:
            if c.count == 1 { return [[c[0], cur]] }
            let u = c[1] - c[0]
            let big = simd_length(u)
            guard big > 0 else { return [] }
            let ux = u / big, uy = SIMD2(-ux.y, ux.x)
            let small = abs(simd_dot(cur - c[0], uy))
            return [(0...64).map { i in
                let t = Double(i) / 64 * 2 * .pi
                return c[0] + ux * (big * cos(t)) + uy * (small * sin(t))
            }]
        case .slot: return c.count == 1 ? [[c[0], cur]] : [[c[0], c[1]], [c[1], cur]]
        default: return []
        }
    }

    private func ring(_ o: SIMD2<Double>, _ r: Double, _ a0: Double, _ n: Int) -> [SIMD2<Double>] {
        (0...n).map { i in
            let a = a0 + Double(i) / Double(n) * 2 * .pi
            return o + SIMD2(cos(a), sin(a)) * r
        }
    }

    // MARK: Typed sizes (B-8)

    /// The size roles of the current tool and step: (role, label, angle).
    private var sizeRoles: [(role: String, label: String, angle: Bool)] {
        guard tool.isSketchTool, sketchOpen, tangentArc == nil else { return [] }
        switch (tool, clicks.count) {
        case (.line, 1): return [("length", String(localized: "Length"), false), ("angle", String(localized: "Angle"), true)]
        case (.rectangle, 1), (.centerRectangle, 1): return [("width", String(localized: "Width"), false), ("height", String(localized: "Height"), false)]
        case (.circle, 1): return [("diameter", String(localized: "Diameter"), false)]
        case (.polygon, 1): return [("radius", String(localized: "Radius"), false)]
        case (.slot, 1): return [("length", String(localized: "Length"), false)]
        case (.slot, 2): return [("width", String(localized: "Width"), false)]
        default: return []
        }
    }

    /// The typed values, with the text in the active box read live.
    private var liveSizes: [String: Double] {
        var v = sizeEntry.values
        let roles = sizeRoles
        if !sizeEntry.text.isEmpty, roles.indices.contains(sizeEntry.active) {
            let r = roles[sizeEntry.active]
            if case .success(let x) = VFExpression(unit: r.angle ? .angle : .length).evaluate(sizeEntry.text) { v[r.role] = x }
        }
        return v
    }

    /// Where the shape's next click goes with the typed sizes: `cur` gives only the direction.
    func sizedPoint(_ cur: SIMD2<Double>) -> SIMD2<Double> {
        guard let a = clicks.last else { return cur }
        let v = liveSizes
        guard !v.isEmpty else { return cur }
        let d = cur - a
        func dir(_ d: SIMD2<Double>) -> SIMD2<Double> { simd_length(d) > 1e-12 ? simd_normalize(d) : SIMD2(1, 0) }
        switch (tool, clicks.count) {
        case (.line, 1):
            let len = v["length"] ?? simd_length(d)
            let ang = v["angle"].map { $0 * .pi / 180 } ?? atan2(dir(d).y, dir(d).x)
            return a + SIMD2(cos(ang), sin(ang)) * len
        case (.rectangle, 1), (.centerRectangle, 1):
            let half = tool == .centerRectangle ? 0.5 : 1
            let sx: Double = d.x < 0 ? -1 : 1, sy: Double = d.y < 0 ? -1 : 1
            let w = v["width"].map { $0 * half } ?? abs(d.x), h = v["height"].map { $0 * half } ?? abs(d.y)
            return a + SIMD2(sx * w, sy * h)
        case (.circle, 1):
            return a + dir(d) * (v["diameter"].map { $0 / 2 } ?? simd_length(d))
        case (.polygon, 1):
            return a + dir(d) * (v["radius"] ?? simd_length(d))
        case (.slot, 1):
            return a + dir(d) * (v["length"] ?? simd_length(d))
        case (.slot, 2):
            guard let w = v["width"] else { return cur }
            let u = clicks[1] - clicks[0]
            guard simd_length(u) > 0 else { return cur }
            let n = SIMD2(-u.y, u.x) / simd_length(u)
            let side: Double = simd_dot(cur - clicks[0], n) < 0 ? -1 : 1
            return clicks[0] + n * (side * w / 2)
        default:
            return cur
        }
    }

    /// The size boxes on the rubber band.
    var sizeFields: [SizeField] {
        let roles = sizeRoles
        guard !roles.isEmpty, let a = clicks.last else { return [] }
        let cur = sizedPoint(cursor ?? defaultCursor(a))
        let live = liveSizes
        let d = cur - a
        let active = min(sizeEntry.active, roles.count - 1)
        return roles.enumerated().map { i, r in
            var value = 0.0
            var anchor = (a + cur) / 2
            switch r.role {
            case "length" where tool == .line, "length" where tool == .slot:
                value = simd_length(d)
            case "angle":
                var deg = atan2(d.y, d.x) * 180 / .pi
                if deg < 0 { deg += 360 }
                value = deg
                anchor = a
            case "width" where tool == .slot:
                let u = clicks[1] - clicks[0]
                let n = simd_length(u) > 0 ? SIMD2(-u.y, u.x) / simd_length(u) : SIMD2(0, 1)
                value = abs(simd_dot(cur - clicks[0], n)) * 2
                anchor = cur
            case "width":
                value = abs(d.x) * (tool == .centerRectangle ? 2 : 1)
                anchor = SIMD2((a.x + cur.x) / 2, cur.y)
                if tool == .centerRectangle { anchor = SIMD2(a.x, cur.y) }
            case "height":
                value = abs(d.y) * (tool == .centerRectangle ? 2 : 1)
                anchor = SIMD2(cur.x, tool == .centerRectangle ? a.y : (a.y + cur.y) / 2)
            case "diameter":
                value = simd_length(d) * 2
            case "radius":
                value = simd_length(d)
            default: break
            }
            if let typed = live[r.role] { value = typed }
            let isActive = i == active
            return SizeField(role: r.role, label: r.label, value: value, typed: sizeEntry.values[r.role] != nil, active: isActive,
                             text: isActive && !sizeEntry.text.isEmpty ? sizeEntry.text : nil, anchor: anchor, isAngle: r.angle)
        }
    }

    private func defaultCursor(_ a: SIMD2<Double>) -> SIMD2<Double> {
        let s = max(gridStep, 1)
        return tool == .line || tool == .slot ? a + SIMD2(s, 0) : a + SIMD2(s, s)
    }

    /// Types into the active box: digits, a decimal point, a sign, an operator or a unit.
    func typeSize(_ s: String) {
        guard !sizeFields.isEmpty else { return }
        sizeEntry.text += s
    }

    /// Backspace in the active box. False when there was nothing to delete.
    @discardableResult
    func sizeBackspace() -> Bool {
        if !sizeEntry.text.isEmpty { sizeEntry.text.removeLast(); return true }
        let roles = sizeRoles
        if roles.indices.contains(sizeEntry.active), sizeEntry.values.removeValue(forKey: roles[sizeEntry.active].role) != nil { return true }
        return false
    }

    /// Keeps the text of the active box as its value. False when it is not a size.
    @discardableResult
    private func commitSizeText() -> Bool {
        let roles = sizeRoles
        guard !sizeEntry.text.isEmpty, roles.indices.contains(sizeEntry.active) else { sizeEntry.text = ""; return true }
        let r = roles[sizeEntry.active]
        switch VFExpression(unit: r.angle ? .angle : .length).evaluate(sizeEntry.text) {
        case .success(let v) where r.angle || v > 0:
            sizeEntry.values[r.role] = v
            sizeEntry.text = ""
            return true
        default:
            flash(String(localized: "Type a size, such as 40 or 1.5 in"), error: true)
            return false
        }
    }

    /// Tab: keeps the typed value and moves to the next box (Shift-Tab: the one before).
    func sizeTab(backward: Bool = false) {
        let n = sizeRoles.count
        guard n > 0, commitSizeText() else { return }
        sizeEntry.active = (sizeEntry.active + (backward ? n - 1 : 1)) % n
    }

    /// Sets one box from a text field. False when the text is not a size.
    @discardableResult
    func setSize(_ role: String, text: String) -> Bool {
        guard let i = sizeRoles.firstIndex(where: { $0.role == role }) else { return false }
        sizeEntry.active = i
        sizeEntry.text = text.trimmingCharacters(in: .whitespaces)
        if sizeEntry.text.isEmpty { sizeEntry.values[role] = nil; return true }
        return commitSizeText()
    }

    /// Return: places the shape at the typed sizes (toward the cursor), with their dimensions.
    func sizeCommit() {
        guard let a = clicks.last, commitSizeText() else { return }
        let target = sizedPoint(cursor ?? defaultCursor(a))
        sketchClick(SnapHit(at: target, kind: .none), raw: target)
    }
}
