#if os(macOS)
import AppKit
import SwiftUI

// MARK: Marking menu model (M-7)

/// One command of the marking menu: a compass slice or an overflow row. A slice with a
/// `submenu` (the Sketch slice, south) runs its first entry on a flick and opens the list on a click.
struct MarkingSlot: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var art: String? = nil
    var submenu: [MarkingSlot] = []
    /// False greys the row out (OK while the command still misses an input).
    var enabled = true
    let run: @MainActor (DesignModel) -> Void

    init(_ id: String, _ title: String, symbol: String, art: String? = nil, submenu: [MarkingSlot] = [],
         run: @escaping @MainActor (DesignModel) -> Void) {
        self.id = id; self.title = title; self.symbol = symbol; self.art = art; self.submenu = submenu; self.run = run
    }

    init(_ id: String, tool: Tool, title: String? = nil, run: (@MainActor (DesignModel) -> Void)? = nil) {
        self.init(id, title ?? tool.label, symbol: tool.symbol, art: ToolIcons.art(for: tool)) { m in
            if let run { run(m) } else { m.genericCommand = nil; m.tool = tool }
        }
    }
}

/// The eight compass slices, north first and clockwise, after the Fusion layout (fusion-desktop.md
/// 6.3): Repeat north, Press Pull north-east, Redo east, Hole south-east, the Sketch submenu
/// south, Move/Copy south-west, Undo west, Delete north-west. The open sketch keeps the same
/// frame (Repeat, Delete, Undo, Redo, the sketch tools south) and swaps the three modelling
/// slices for Finish Sketch, Line and Trim.
@MainActor
enum MarkingWheel {
    static let designIDs = ["repeat", "pressPull", "redo", "hole", "sketch", "move", "undo", "delete"]
    static let sketchIDs = ["repeat", "finishSketch", "redo", "line", "sketch", "trim", "undo", "delete"]

    static func ids(sketchOpen: Bool) -> [String] { sketchOpen ? sketchIDs : designIDs }

    static func slots(_ m: DesignModel) -> [MarkingSlot] {
        ids(sketchOpen: m.sketchOpen).map { slot($0, m) }
    }

    static func slot(_ id: String, _ m: DesignModel) -> MarkingSlot {
        switch id {
        case "repeat":
            let title = m.lastTool.map { String(localized: "Repeat \($0.label)") } ?? String(localized: "Repeat")
            return MarkingSlot("repeat", title, symbol: "repeat") { m in
                if let t = m.lastTool { m.genericCommand = nil; m.tool = t } else { m.flash(String(localized: "Nothing to repeat yet")) }
            }
        case "delete": return MarkingSlot("delete", tool: .delete) { $0.deleteSelection() }
        case "pressPull": return MarkingSlot("pressPull", tool: .pressPull)
        case "undo": return MarkingSlot("undo", String(localized: "Undo"), symbol: "arrow.uturn.backward") { $0.undo() }
        case "redo": return MarkingSlot("redo", String(localized: "Redo"), symbol: "arrow.uturn.forward") { $0.redo() }
        case "move": return MarkingSlot("move", tool: .move, title: String(localized: "Move/Copy"))
        case "hole":
            return MarkingSlot("hole", String(localized: "Hole"), symbol: "circle.bottomhalf.filled") { m in
                if let c = m.commands.first(where: { $0.id == "solid.hole" }) { CommandRouter.run(c, m) }
                else { m.flash(String(localized: "Hole is not in this engine build."), error: true) }
            }
        case "finishSketch":
            return MarkingSlot("finishSketch", String(localized: "Finish Sketch"), symbol: "checkmark.circle") { $0.finishSketch() }
        case "trim": return MarkingSlot("trim", tool: .trim)
        case "line": return MarkingSlot("line", tool: .line)
        default: return sketchSlot(m)
        }
    }

    /// South: the sketch submenu. Out of a sketch its first entry creates one (on the picked face
    /// when there is one); in a sketch it lists the drawing tools, Line first.
    static func sketchSlot(_ m: DesignModel) -> MarkingSlot {
        var sub: [MarkingSlot] = []
        if !m.sketchOpen {
            sub.append(MarkingSlot("sketch.create", tool: .sketch, title: String(localized: "Create Sketch")) { m in
                m.genericCommand = nil
                if m.selection.contains(where: \.isFace) { m.sketchOnSelectedFace() } else { m.tool = .sketch }
            })
        }
        for t: Tool in [.line, .rectangle, .circle, .arc, .polygon, .slot, .spline, .trim, .offset] where !(m.sketchOpen && t == .trim) {
            sub.append(MarkingSlot("sketch." + t.rawValue, tool: t) { m in
                m.genericCommand = nil
                m.tool = m.sketchOpen ? t : .sketch
            })
        }
        return MarkingSlot("sketch", String(localized: "Sketch"), symbol: Tool.sketch.symbol, art: ToolIcons.art(for: .sketch), submenu: sub) { m in
            sub.first?.run(m)
        }
    }

    /// The list under the wheel: what the selection allows, then Find in Browser and Timeline,
    /// then the window-wide items.
    static func overflow(_ m: DesignModel) -> [MarkingSlot] {
        var out: [MarkingSlot] = []
        // SolidWorks right-click OK: finishes the running command once its inputs are set.
        if m.tool != .select {
            var ok = MarkingSlot("ok", String(localized: "OK"), symbol: "checkmark") { CommandDialog.finish($0) }
            ok.enabled = CommandDialog.canFinish(m)
            out.append(ok)
        }
        let picked = !m.selection.isEmpty || !m.selectedBodies.isEmpty
        if picked {
            out.append(MarkingSlot("measure", tool: .measure, title: String(localized: "Mass Properties")) { m in
                NotificationCenter.default.post(name: .vfShowMassProperties, object: m)
            })
            if !m.selection.isEmpty {
                out.append(MarkingSlot("selectBody", String(localized: "Select Body"), symbol: "cube") { m in
                    m.selectedBodies = Set(m.bodiesInSelection)
                    m.selection = []
                })
            }
            out.append(MarkingSlot("clearSelection", String(localized: "Clear Selection"), symbol: "xmark.circle") { m in
                m.selection = []; m.selectedBodies = []
            })
            out.append(MarkingSlot("findBrowser", String(localized: "Find in Browser"), symbol: "sidebar.left") { m in
                let bodies = Set(m.bodiesInSelection).union(m.selectedBodies)
                if !bodies.isEmpty { m.selectedBodies = bodies }
                NotificationCenter.default.post(name: .vfRevealInBrowser, object: m, userInfo: ["bodies": Array(bodies)])
            })
        }
        if !m.snapshot.timeline.isEmpty {
            out.append(MarkingSlot("findTimeline", String(localized: "Find in Timeline"), symbol: "clock.arrow.circlepath") { m in
                NotificationCenter.default.post(name: .vfRevealInTimeline, object: m, userInfo: ["bodies": Array(Set(m.bodiesInSelection).union(m.selectedBodies))])
            })
        }
        out.append(MarkingSlot("fit", String(localized: "Fit"), symbol: "arrow.up.left.and.down.right.magnifyingglass") { $0.zoomToFit() })
        out.append(MarkingSlot("search", String(localized: "Search Commands"), symbol: "magnifyingglass") { $0.toolboxOpen = true })
        return out
    }
}

extension Notification.Name {
    /// Show the browser and the picked bodies in it (userInfo "bodies": [String]).
    static let vfRevealInBrowser = Notification.Name("viaform.revealInBrowser")
    /// Show the timeline and the features of the picked bodies (userInfo "bodies": [String]).
    static let vfRevealInTimeline = Notification.Name("viaform.revealInTimeline")
    /// Present the mass properties report for the model sent as the object.
    static let vfShowMassProperties = Notification.Name("viaform.showMassProperties")
}

/// Compass geometry: which slice a pointer offset from the wheel's centre points at.
enum MarkingCompass {
    /// Closer than this to the centre picks nothing.
    static let deadZone: CGFloat = 20

    /// Slice 0 is north, then clockwise in 45 degree steps; nil inside the dead zone. Screen y grows down.
    static func slice(dx: CGFloat, dy: CGFloat) -> Int? {
        guard hypot(dx, dy) >= deadZone else { return nil }
        let a = atan2(Double(dx), Double(-dy))
        let turn = (a + 2 * .pi + .pi / 8).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(turn / (.pi / 4)) % 8
    }

    static func slice(from o: CGPoint, to p: CGPoint) -> Int? { slice(dx: p.x - o.x, dy: p.y - o.y) }

    /// The wedge drawn behind a highlighted slice, centred on the wheel's centre.
    static func wedge(_ index: Int, center c: CGPoint, inner: CGFloat, outer: CGFloat) -> Path {
        let mid = -Double.pi / 2 + Double(index) * .pi / 4
        let a0 = Angle(radians: mid - .pi / 8), a1 = Angle(radians: mid + .pi / 8)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// The right-drag gesture over the viewport (SolidWorks mouse gestures, Fusion marking menu):
/// press the right button and drag toward a slice. A quick flick runs the slice on release and
/// never draws the wheel; holding past `holdToShow` draws it with the slice highlighted, and the
/// release still runs it. A release near the centre opens the wheel for a click.
///
/// The viewport feeds it from its right-mouse events (`begin`, `drag`, `end`); see the report
/// for the wiring in `Shared/Render/Viewport.swift`.
@MainActor
@Observable
final class MarkingFlick {
    static let shared = MarkingFlick()

    enum Outcome: Equatable { case ran(String), opened, ignored }

    private(set) var origin: CGPoint?
    /// The slice the drag points at, highlighted by the wheel while it is drawn.
    private(set) var hot: Int?
    private(set) var shown = false
    private var started = Date.distantPast
    private weak var model: DesignModel?
    static let holdToShow: TimeInterval = 0.25

    func begin(_ m: DesignModel, at p: CGPoint, now: Date = .now) {
        model = m; origin = p; started = now; hot = nil; shown = false
    }

    /// Follows the pointer. Answers true while a gesture is in progress.
    @discardableResult
    func drag(to p: CGPoint, now: Date = .now) -> Bool {
        guard let o = origin, let m = model else { return false }
        hot = MarkingCompass.slice(from: o, to: p)
        if !shown, now.timeIntervalSince(started) >= Self.holdToShow {
            shown = true
            m.markingMenu = o
        }
        return true
    }

    /// Ends the gesture: runs the slice under the pointer, else opens the wheel.
    @discardableResult
    func end(at p: CGPoint) -> Outcome {
        defer { reset() }
        guard let o = origin, let m = model else { return .ignored }
        if let i = MarkingCompass.slice(from: o, to: p) {
            let s = MarkingWheel.slots(m)[i]
            m.markingMenu = nil
            s.run(m)
            return .ran(s.id)
        }
        if !shown { m.markingMenu = p }
        return .opened
    }

    /// Drops the gesture (the drag became a camera move).
    func cancel() { reset() }

    private func reset() { origin = nil; hot = nil; shown = false; model = nil }
}
#endif
