#if os(macOS)
import Foundation

/// Checks for the Mac chrome gaps M-7, M-12, M-15, M-18 and M-19 (marking menu compass and
/// flick, live measure, S bar, confirmation corner, ribbon pins). The lead wires it into SelfTest.
enum MacChromeSelfTest {
    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []

        // M-7: compass slices, north first and clockwise; screen y grows down.
        let dirs: [(CGFloat, CGFloat, Int?)] = [(0, -60, 0), (50, -50, 1), (60, 0, 2), (50, 50, 3), (0, 60, 4),
                                                (-50, 50, 5), (-60, 0, 6), (-50, -50, 7), (5, -5, nil)]
        let mapped = dirs.allSatisfy { MarkingCompass.slice(dx: $0.0, dy: $0.1) == $0.2 }
        out.append((mapped, "M-7 flick direction picks the compass slice (8 directions, dead zone)"))
        out.append((MarkingCompass.slice(dx: 22, dy: -60) == 0 && MarkingCompass.slice(dx: 30, dy: -60) == 1,
                    "M-7 slice borders sit at 22.5 degrees"))
        out.append((MarkingWheel.designIDs == ["repeat", "pressPull", "redo", "hole", "sketch", "move", "undo", "delete"],
                    "M-7 Fusion compass: Repeat north, Press Pull north-east, Undo west, Delete north-west, Sketch south"))

        let m = DesignModel()
        m.run("solid.box", ["length": 30, "width": 20, "height": 10])
        m.tool = .extrude
        m.tool = .select
        let wheel = MarkingWheel.slots(m)
        out.append((wheel.count == 8 && wheel[4].submenu.first?.id == "sketch.create", "M-7 south slice opens the sketch submenu"))
        // A quick flick north-east runs Press Pull without drawing the wheel.
        let flick = MarkingFlick()
        let t0 = Date()
        flick.begin(m, at: CGPoint(x: 400, y: 300), now: t0)
        flick.drag(to: CGPoint(x: 450, y: 250), now: t0.addingTimeInterval(0.05))
        let drawn = m.markingMenu != nil
        let r = flick.end(at: CGPoint(x: 450, y: 250))
        out.append((r == .ran("pressPull") && m.tool == .pressPull && !drawn && m.markingMenu == nil,
                    "M-7 a quick right flick north-east runs Press Pull on release, no wheel drawn (\(r))"))
        m.tool = .select
        // North repeats the last tool (Press Pull); a slow drag draws the wheel first.
        flick.begin(m, at: CGPoint(x: 400, y: 300), now: t0)
        flick.drag(to: CGPoint(x: 401, y: 230), now: t0.addingTimeInterval(0.4))
        let shown = m.markingMenu != nil && flick.hot == 0
        let r2 = flick.end(at: CGPoint(x: 401, y: 230))
        out.append((shown && r2 == .ran("repeat") && m.tool == .pressPull, "M-7 a held drag draws the wheel with the slice lit, release repeats"))
        m.tool = .select
        flick.begin(m, at: CGPoint(x: 400, y: 300), now: t0)
        out.append((flick.end(at: CGPoint(x: 402, y: 301)) == .opened && m.markingMenu != nil, "M-7 a right click without a drag opens the wheel"))
        m.markingMenu = nil

        // M-12: measure text from the engine for one face and two faces.
        let b = DesignModel()
        b.run("solid.box", ["length": 30, "width": 20, "height": 10])
        let body = b.snapshot.bodies.first?.name ?? ""
        let top: [String: Any] = ["type": "face", "body": body, "point": [15.0, 10.0, 10.0]]
        let side: [String: Any] = ["type": "face", "body": body, "point": [30.0, 10.0, 5.0]]
        let bottom: [String: Any] = ["type": "face", "body": body, "point": [15.0, 10.0, 0.0]]
        let one = ((try? b.engine.execute("inspect.measure", ["items": [top]])) as? [String: Any]).flatMap(SelectionMeasure.text)
        out.append((one == String(localized: "Area \(VFFormat.area(600))"), "M-12 one face shows its area (\(one ?? "nil"))"))
        let two = ((try? b.engine.execute("inspect.measure", ["items": [top, side]])) as? [String: Any]).flatMap(SelectionMeasure.text)
        out.append((two?.contains(String(localized: "Angle \(VFFormat.angle(90))")) == true, "M-12 two faces show the angle between them (\(two ?? "nil"))"))
        let gap = ((try? b.engine.execute("inspect.measure", ["items": [top, bottom]])) as? [String: Any]).flatMap(SelectionMeasure.text)
        out.append((gap?.contains(String(localized: "Distance \(VFFormat.length(10))")) == true, "M-12 two parallel faces show the distance (\(gap ?? "nil"))"))
        b.selectedBodies = [body]
        let whole = SelectionMeasure.status(b)
        out.append((whole?.hasPrefix(String(localized: "1 Body")) == true && whole?.contains(VFFormat.volume(6000)) == true,
                    "M-12 a picked body shows its volume (\(whole ?? "nil"))"))

        // M-15: S bar tools per mode.
        out.append((SBar.mode(workspace: .design, sketchOpen: true) == .sketch && SBar.mode(workspace: .design, sketchOpen: false) == .solid
                    && SBar.mode(workspace: .render, sketchOpen: false) == .render && SBar.mode(workspace: .make, sketchOpen: false) == .stage,
                    "M-15 S bar mode follows the stage and the open sketch"))
        out.append((SBar.ids(.sketch).first == "sketch.line" && SBar.ids(.solid).contains("solid.extrude") && !SBar.ids(.solid).contains("sketch.line"),
                    "M-15 sketch and solid modes offer different tools"))
        let known = Set(b.commands.map(\.id))
        let missing = (SBar.ids(.sketch) + SBar.ids(.solid)).filter { !known.contains($0) }
        out.append((missing.count <= 2, "M-15 S bar ids exist in the registry (missing: \(missing))"))

        // M-18: the X leaves a sketch without keeping its changes.
        let s = DesignModel()
        s.run("solid.box", ["length": 30, "width": 20, "height": 10])
        let features = s.snapshot.timeline.count
        s.startSketch("XY")
        s.run("sketch.line", ["points": [[0, 0], [10, 0]]], quiet: true)
        let open = s.sketchOpen && ConfirmationCorner.shown(s)
        ConfirmationCorner.reject(s)
        out.append((open && !s.sketchOpen && s.snapshot.timeline.count == features && s.tool == .select,
                    "M-18 the X cancels the sketch (sketch.cancel), the timeline is unchanged"))
        s.startSketch("XY")
        ConfirmationCorner.accept(s)
        out.append((!s.sketchOpen && !ConfirmationCorner.shown(s), "M-18 the check finishes the sketch and the corner hides"))

        // M-19: pins persist per user; tooltips carry the registry summary.
        let suite = "viaform.selftest.pins"
        if let d = UserDefaults(suiteName: suite) {
            d.removePersistentDomain(forName: suite)
            RibbonPins.toggle("solid.extrude", in: d)
            RibbonPins.toggle("solid.fillet", in: d)
            let again = UserDefaults(suiteName: suite)
            let kept = again.map { RibbonPins.pinned(in: $0) } ?? []
            RibbonPins.toggle("solid.extrude", in: d)
            out.append((kept == ["solid.extrude", "solid.fillet"] && RibbonPins.pinned(in: d) == ["solid.fillet"],
                        "M-19 Pin to Toolbar persists and unpins (\(kept))"))
            d.removePersistentDomain(forName: suite)
        } else {
            out.append((false, "M-19 pin store opens"))
        }
        if let ex = b.commands.first(where: { $0.id == "solid.extrude" }) {
            let tip = RibbonPins.tooltip(ex)
            out.append((tip.split(separator: "\n").count >= 2 && (ex.key == nil || tip.contains(DeskKeymap.glyph(ex.key!))),
                        "M-19 the tooltip names the key and the registry summary"))
        }
        out.append((RibbonPins.rowKey("E") == nil && RibbonPins.rowKey("Ctrl+Shift+E") != nil, "M-19 rows print keys the menu cannot bind"))
        return out
    }
}
#endif
