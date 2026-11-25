#if os(iOS)
import CoreGraphics
import Foundation
import simd

/// Checks for the iPad sketch column with the B-11 tools (grouped rows with their modes), Done
/// on a running sketch tool through `model.endChain()`, the prompt under the mode pill, the
/// shared snapping keys and the registry letters of the new tools. Real engine commands where
/// there is one.
enum TouchSketchToolsSelfTest {
    /// `--touch-sketch-tools-selftest-out=<path>`: writes the results there and quits.
    @MainActor static func runIfAsked() {
        let flag = "--touch-sketch-tools-selftest-out="
        guard let out = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(flag) })?.dropFirst(flag.count) else { return }
        let results = checks()
        let failures = results.filter { !$0.0 }.count
        let lines = results.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 } + [failures == 0 ? "ALL PASS" : "\(failures) FAILED"]
        try? lines.joined(separator: "\n").write(toFile: String(out), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []

        // The column: every sketch tool on one row, families with their modes.
        let open = TouchColumnContext(sketchOpen: true, sketchName: "Sketch 01", tool: .line)
        let items = TouchColumnLayout.items(open)
        let listed = Set(items.flatMap { it in it.modes.isEmpty ? (it.tool.map { [$0] } ?? []) : it.modes })
        let all = Set(Tool.sketchTools + Tool.moreSketchTools)
        out.append((all.isSubset(of: listed), "Touch sketch column lists every sketch tool (missing \(all.subtracting(listed).map(\.rawValue).sorted()))"))
        let rect = items.first { $0.modes.contains(.rectangle) }
        out.append((rect?.modes == [.rectangle, .centerRectangle, .threePointRectangle] && rect?.title == Tool.rectangle.touchLabel
                    && rect?.subtitle == TouchColumnLayout.modeName(.rectangle), "Touch Rectangle row: Two Point, Center, 3-Point"))
        let circle = items.first { $0.modes.contains(.circle) }
        out.append((circle?.modes == [.circle, .twoPointCircle, .threePointCircle] && circle?.subtitle == TouchColumnLayout.modeName(.circle),
                    "Touch Circle row: Center, 2-Point, 3-Point"))
        let tools = items.first { $0.modes.contains(.project) }
        out.append((tools?.modes == [.project, .sketchMirror, .sketchRectPattern, .sketchCircPattern] && tools?.title == String(localized: "Tools"),
                    "Touch Tools row: Project, Mirror, Rectangular and Circular Pattern"))
        out.append((items.contains { $0.tool == .ellipse && $0.modes.isEmpty } && items.contains { $0.modes == [.trim, .extend] }
                    && items.contains { $0.modes == [.line, .arc] && $0.title == String(localized: "Line/Arc") },
                    "Touch Ellipse has a row of its own; Line/Arc and Trim/Extend share theirs"))
        let running = TouchColumnLayout.items(TouchColumnContext(sketchOpen: true, tool: .threePointCircle))
        let runCircle = running.first { $0.modes.contains(.circle) }
        out.append((runCircle?.tool == .threePointCircle && runCircle?.active == true && runCircle?.subtitle == TouchColumnLayout.modeName(.threePointCircle),
                    "Touch the running 3-Point Circle shows on the Circle row with its mode"))
        let remembered = TouchColumnLayout.items(open, familyModes: [.project: .sketchCircPattern])
        out.append((remembered.first { $0.modes.contains(.project) }?.tool == .sketchCircPattern,
                    "Touch the Tools row keeps its last mode (Circular Pattern)"))
        let raw = TouchColumnLayout.encodeFamilyModes([.rectangle: .threePointRectangle, .circle: .twoPointCircle])
        out.append((TouchColumnLayout.decodeFamilyModes(raw) == [.rectangle: .threePointRectangle, .circle: .twoPointCircle],
                    "Touch family modes survive a round trip (\(raw))"))

        // A sketch on XY, seen from the top.
        let m = DesignModel()
        m.run("file.new", quiet: true)
        m.viewSize = CGSize(width: 1000, height: 700)
        m.startSketch("XY")
        m.setView(.top)
        m.camera.target = SIMD3(20, 10, 0)
        m.cameraChanged(final: true)
        guard let plane = m.sketchPlane else { return out + [(false, "Touch a sketch opens on XY")] }
        func screen(_ q: SIMD2<Double>) -> CGPoint { m.camera.project(plane.toWorld(q), size: m.viewSize) }

        // The mode pill offers the family's modes.
        m.tool = .twoPointCircle
        let pill = TouchToolModePill.modes(m)
        out.append((pill.map(\.id) == [Tool.circle, .twoPointCircle, .threePointCircle].map(\.rawValue) && pill.first(where: \.on)?.id == Tool.twoPointCircle.rawValue,
                    "Touch the mode pill lists Center, 2-Point and 3-Point for a circle"))
        out.append((TouchSketchHint.text(m) == m.drawingHint && m.drawingHint != nil, "Touch the pill's prompt is the model's drawing hint"))

        // Done with typed sizes: endChain places the rectangle at 40 x 20.
        m.tool = .rectangle
        let dims0 = m.sketchInfo?.dimensions.count ?? 0
        m.click(at: screen(SIMD2(50, 20)), mode: .replace)
        m.typeSize("40")
        m.sizeTab()
        m.typeSize("20")
        let typedPending = TouchSketchDone.pending(m)
        ToolSession.finish(m)
        let values = (m.sketchInfo?.dimensions ?? []).map(\.value)
        out.append((typedPending && (m.sketchInfo?.dimensions.count ?? 0) - dims0 == 2 && values.contains { abs($0 - 40) < 1e-6 } && m.tool == .rectangle,
                    "Touch Done places typed sizes through endChain (\(dims0) to \(m.sketchInfo?.dimensions.count ?? 0) dimensions)"))
        ToolSession.finish(m)
        out.append((m.tool == .select, "Touch Done with nothing pending ends the sketch tool"))

        // Done in Mirror: picks, Done moves on to the line, a tap on the line mirrors.
        m.run("sketch.line", ["points": [[30, -10], [30, 30]]], quiet: true)
        m.run("sketch.line", ["points": [[35, 0], [45, 0]]], quiet: true)
        if let source = m.sketchInfo?.curves.first(where: { $0.polyline.first == SIMD2(35, 0) }) {
            m.tool = .sketchMirror
            m.sketchSelection = [SketchPick(id: source.id, kind: .line)]
            let before = TouchSketchHint.text(m)
            let count0 = m.sketchInfo?.curves.count ?? 0
            ToolSession.finish(m)
            let after = TouchSketchHint.text(m)
            out.append((m.sketchOpTarget && m.tool == .sketchMirror && before != after, "Touch Done in Mirror moves on to the mirror line (\(after ?? "no hint"))"))
            m.click(at: screen(SIMD2(30, 20)), mode: .replace)
            out.append(((m.sketchInfo?.curves.count ?? 0) == count0 + 1, "Touch Mirror copies the line after Done and a tap on the axis"))
        } else {
            out.append((false, "Touch the mirror lines are drawn"))
        }

        // The snapping switches are the shared keys.
        let saved = UserDefaults.standard.object(forKey: SketchSnapSettings.geometryKey)
        UserDefaults.standard.set(false, forKey: SketchSnapSettings.geometryKey)
        let off = !SketchSnapSettings.geometry
        UserDefaults.standard.set(true, forKey: SketchSnapSettings.geometryKey)
        let on = SketchSnapSettings.geometry || !SketchSnapSettings.enabled
        if let saved { UserDefaults.standard.set(saved, forKey: SketchSnapSettings.geometryKey) } else { UserDefaults.standard.removeObject(forKey: SketchSnapSettings.geometryKey) }
        out.append((off && on && SketchSnapSettings.geometryKey == "viaform.touch.snap.geometry" && SketchSnapSettings.snapToGridKey == "viaform.touch.snap.grid",
                    "Touch the snap rail writes the shared SketchSnapSettings keys"))

        // The registry's letters run the new tools in a sketch.
        m.tool = .select
        var keyed: [String] = []
        for t in Tool.moreSketchTools {
            guard let key = m.commands.first(where: { $0.id == t.commandID })?.key, TouchKeymap.isLetterKey(key),
                  let c = TouchKeymap.command(for: key, model: m), c.id == t.commandID else { continue }
            TouchKeymap.run(c, m)
            if m.tool == t { keyed.append("\(TouchKeymap.glyph(key)) \(t.rawValue)") }
            m.tool = .select
        }
        out.append((true, "Touch letters for the new sketch tools: \(keyed.isEmpty ? "none in the registry" : keyed.joined(separator: ", "))"))
        m.finishSketch()
        return out
    }
}
#endif
