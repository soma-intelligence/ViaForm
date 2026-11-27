#if os(iOS)
import Foundation
import simd
import SwiftUI

/// Checks for the iPad chrome of gaps T-4, T-5, T-6, T-12, T-15, T-16, T-17 and T-18: the
/// column's content per selection and tool state, the keypad's arithmetic, the readout's measure,
/// the grid and normal-to commands and the tool keys, through real engine commands where there
/// is one.
enum TouchChromeSelfTest {
    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        func kinds(_ c: TouchColumnContext) -> [TouchColumnItem.Kind] { TouchColumnLayout.items(c).map(\.kind) }
        func tools(_ c: TouchColumnContext) -> [Tool] { TouchColumnLayout.items(c).compactMap(\.tool) }

        // T-5: nothing selected.
        let top = TouchColumnLayout.items(TouchColumnContext())
        out.append((top.map(\.kind) == [.search, .group(.sketch), .group(.add), .group(.transform), .group(.tools)],
                    "T-5 nothing selected: Search, Sketch, Add, Transform, Tools"))
        out.append((top.dropFirst().allSatisfy { $0.subtitle != nil }, "T-5 every group shows its mode in grey"))
        let remembered = TouchColumnLayout.items(TouchColumnContext(), modes: [.add: .cylinder])
        out.append((remembered.first { $0.kind == .group(.add) }?.subtitle == Tool.cylinder.touchLabel, "T-5 Add shows its remembered mode"))

        // T-4: a face, an edge, a body, two bodies, a running tool.
        let face = TouchColumnContext(faces: 1)
        out.append((kinds(face).prefix(2) == [.search, .deselect] && tools(face).contains(.pressPull) && tools(face).contains(.sketch)
                    && tools(face).contains(.delete), "T-4 a face: Search, Deselect All, Sketch, Push / Pull, Delete"))
        let edge = TouchColumnContext(edges: 1)
        out.append((kinds(edge).dropFirst().first == .deselect && tools(edge).contains(.fillet) && tools(edge).contains(.chamfer)
                    && !tools(edge).contains(.delete), "T-4 an edge: Fillet and Chamfer, no Delete"))
        let body = TouchColumnContext(bodies: 1, bodyName: "Body 02")
        let bodyItems = TouchColumnLayout.items(body)
        out.append((bodyItems.first { $0.kind == .deselect }?.subtitle == "Body 02" && tools(body).contains(.move) && tools(body).contains(.mirror)
                    && !tools(body).contains(.union), "T-4 a body: Deselect All (Body 02), Move, Mirror, no Union"))
        out.append((tools(TouchColumnContext(bodies: 2)).contains(.union), "T-4 two bodies offer Union"))
        let running = TouchColumnContext(faces: 1, tool: .extrude, toolMode: "ten")
        let runItems = TouchColumnLayout.items(running)
        out.append((runItems.map(\.kind) == [.search, .deselect, .tool(.extrude)] && runItems.last?.subtitle == "ten"
                    && runItems.last?.active == true, "T-4 a running tool shrinks the column to Search, Deselect All, the tool and its mode"))
        let extras = TouchColumnLayout.items(body, extras: [("fly", "Fly It", "wind")])
        out.append((extras.contains { $0.kind == .extra("fly") }, "T-4 cross-stage verbs join the column"))

        // T-17 + T-2 slot: an open sketch.
        let sketch = TouchColumnContext(sketchOpen: true, sketchName: "Sketch 01", tool: .centerRectangle)
        let sk = TouchColumnLayout.items(sketch)
        out.append((sk.first?.kind == .search && sk.dropFirst().first?.kind == .exitSketch && sk.dropFirst().first?.subtitle == "Sketch 01",
                    "T-17 Search, then Exit Sketching named after the sketch"))
        out.append((sk.contains { $0.kind == .constraintSlot } && sk.contains { $0.tool == .line },
                    "T-4 the sketch column lists the sketch tools and keeps the constraint slot"))
        let rect = sk.first { $0.modes.contains(.rectangle) }
        out.append((rect?.tool == .centerRectangle && rect?.active == true && rect?.subtitle == TouchColumnLayout.modeName(.centerRectangle)
                    && !sk.contains { $0.tool == .rectangle }, "T-5 Rectangle is one row with its mode (Center)"))

        // The rail (reference tablet layout): tiles and the fit on a 768 point tall iPad.
        let tiles = TouchColumnLayout.tiles(sk)
        out.append((tiles.first?.map(\.kind) == [.search] && tiles.dropFirst().first?.map(\.kind) == [.exitSketch]
                    && !tiles.joined().contains { $0.kind == .constraintSlot }, "Rail Search and Exit Sketching on tiles of their own, no constraint slot"))
        let rows = tiles.reduce(0) { $0 + $1.count } + 1 + TouchViewModeStack.rows(construction: true, isolate: true)
        let groups = tiles.count + 2
        let row = TouchRail.rowHeight(height: 768, fixed: TouchRail.leftFixed, rows: rows, groups: groups)
        let used = TouchRail.leftFixed + CGFloat(rows) * row + CGFloat(groups - 1) * TouchRail.gap
        out.append((row >= TouchRail.rowMin && used <= 768, "Rail the sketch column, Delete and the view modes fit 768 points without scrolling (\(rows) rows of \(row) pt, \(used) pt)"))
        let rightRow = TouchRail.rowHeight(height: 768, fixed: TouchRail.rightFixed, rows: TouchConstraintColumn.rowCount, groups: 2)
        out.append((rightRow >= TouchRail.rowMin, "Rail the constraint column fits 768 points (\(rightRow) pt rows)"))
        out.append((TouchRail.rowHeight(height: 1366, fixed: TouchRail.leftFixed, rows: 5, groups: 2) == TouchRail.rowMax,
                    "Rail rows stay 44 points where there is room"))

        // T-15: the keypad.
        var k = TouchKeypadState(value: 10, unit: .none)
        k.press([.d2, .d5, .plus, .d3, .multiply, .d2])
        if case let .success(v) = k.result { out.append((abs(v - 31) < 1e-9, "T-15 the keypad evaluates 25+3*2 = \(v)")) }
        else { out.append((false, "T-15 the keypad evaluates 25+3*2 (got \(k.result))")) }
        out.append((k.shown == "25+3×2", "T-15 the keypad shows × for *"))
        var s = TouchKeypadState(text: "12", unit: .none)
        s.press(.sign)
        s.press(.backspace)
        s.press(.d4)
        out.append((s.text == "-14", "T-15 plus or minus and backspace edit the text (\(s.text))"))
        var bad = TouchKeypadState(text: "1", unit: .none)
        bad.press([.divide, .d0])
        out.append((bad.result == .failure(.divideByZero), "T-15 dividing by zero is refused"))
        // The keypad opens on the field's shown text: the first digit replaces it, an operator follows it.
        var f = TouchKeypadState(text: "12.5", unit: .length, fresh: true)
        f.press(.d7)
        var g = TouchKeypadState(text: "12.5", unit: .length, fresh: true)
        g.press([.plus, .d1])
        out.append((f.text == "7" && g.text == "12.5+1", "T-15 a digit replaces the field's value, an operator carries on (\(f.text), \(g.text))"))
        var w = TouchKeypadState(text: "3", unit: .length, fresh: true)
        w.type("width")
        out.append((w.text == "width", "T-15 a parameter name replaces the fresh value (\(w.text))"))
        // One hook: NumberField reads `vfNumberKeypad`, set by the Touch root on a regular width.
        let hook = TouchNumberKeypad.hook
        var typed = ""
        let req = NumberKeypadRequest(label: "Distance", unit: .length, text: Binding(get: { typed }, set: { typed = $0 }),
                                      preview: nil, error: nil, parameterNames: [], commit: {}, cancel: {})
        _ = hook.content(req)
        var env = EnvironmentValues()
        env.vfNumberKeypad = hook
        out.append((env.vfNumberKeypad != nil && EnvironmentValues().vfNumberKeypad == nil,
                    "T-15 the keypad is one environment hook, nil (system keyboard) unless the Touch root sets it"))

        // T-12: the readout through inspect.measure, on a real box.
        let m = DesignModel()
        m.run("solid.box", ["length": 20, "width": 20, "height": 20, "corner": [0, 0, 0]])
        if let name = m.snapshot.bodies.first?.name {
            let edgeItem = TouchMeasureItem(face: false, body: name, point: [10, 0, 0])
            let r1 = TouchMeasure.readout(engine: m.engine, items: [edgeItem], bodies: [])
            out.append((r1?.title == TouchCount.edges(1) && r1?.value == VFFormat.length(20), "T-12 one edge reads its length (\(r1?.value ?? "none"))"))
            let faceA = TouchMeasureItem(face: true, body: name, point: [10, 10, 0])
            let faceB = TouchMeasureItem(face: true, body: name, point: [10, 10, 20])
            let r2 = TouchMeasure.readout(engine: m.engine, items: [faceA, faceB], bodies: [])
            out.append((r2?.value?.hasPrefix(VFFormat.length(20)) == true, "T-12 two faces read their distance (\(r2?.value ?? "none"))"))
            let r3 = TouchMeasure.readout(engine: m.engine, items: [], bodies: [name])
            out.append((r3?.title == name && r3?.value == VFFormat.volume(8000), "T-12 a body reads its volume (\(r3?.value ?? "none"))"))

            // T-17: view.normal_to through the engine on the top face.
            m.camera = OrbitCamera()
            let turned = TouchNormalTo.apply(m, body: name, point: [10, 10, 20])
            out.append((turned && abs(simd_dot(m.camera.back, [0, 0, 1]) - 1) < 1e-6, "T-17 view.normal_to turns the view square to the top face"))
        } else {
            out.append((false, "T-12 a 20 mm box to measure"))
        }
        out.append((pillShowsOffPlaneOnly(), "T-17 the Normal to Sketch pill shows only off the plane"))

        // T-16: view.grid.
        out.append((TouchSnapRail.setGrid(false, m) && TouchSnapRail.setGrid(true, m), "T-16 view.grid takes the grid switch"))

        // T-18: the tool keys.
        let e = TouchKeymap.command(for: "E", model: m)
        out.append((e?.id == "solid.extrude", "T-18 E runs Extrude (\(e?.id ?? "none"))"))
        out.append((TouchKeymap.rows(m).count > 5, "T-18 the shortcuts sheet lists \(TouchKeymap.rows(m).count) tool keys"))
        m.run("sketch.create", ["plane": "XY"])
        if let l = TouchKeymap.command(for: "L", model: m) {
            out.append((l.id.hasPrefix("sketch."), "T-18 L in a sketch runs a sketch command (\(l.id))"))
        }
        m.finishSketch()
        out.append((TouchHandedness.toolEdge(leftHanded: true) == .trailing && TouchHandedness.panelEdge(leftHanded: true) == .leading
                    && TouchHandedness.toolEdge(leftHanded: false) == .leading, "T-18 the left-handed layout swaps the zones"))
        return out
    }

    private static func pillShowsOffPlaneOnly() -> Bool {
        TouchNormalTo.isOffPlane(back: [0, 0.2, 1], normal: [0, 0, 1]) && !TouchNormalTo.isOffPlane(back: [0, 0, 1], normal: [0, 0, -1])
    }
}
#endif
