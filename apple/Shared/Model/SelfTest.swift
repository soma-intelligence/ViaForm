import Foundation
import simd

/// `--selftest`: drives the model as a user would (clicks at screen points, tool values, done)
/// and prints what the engine reports, then quits. Run: `SolidCraft --selftest`.
enum SelfTest {
    static func run() -> Never {
        let m = DesignModel()
        m.viewSize = CGSize(width: 1200, height: 800)
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS" : "FAIL", what, ok ? "" : "(\(m.message ?? "no message"))")
            if !ok { failures += 1 }
        }
        func screen(_ w: SIMD3<Double>) -> CGPoint { m.camera.project(w, size: m.viewSize) }

        // Sketch a rectangle on XY by clicks, then extrude it.
        m.startSketch("XY")
        check(m.sketchOpen, "sketch opens on XY")
        m.tool = .rectangle
        m.click(at: screen([0, 0, 0]), additive: false)
        m.click(at: screen([30, 20, 0]), additive: false)
        m.finishSketch()
        check(m.snapshot.sketches.first?.profiles == 1, "rectangle by two clicks makes one profile")
        m.tool = .extrude
        m.toolValue = 12
        check(m.hasPreview && m.snapshot.bodies.count == 1, "extrude previews a body")
        m.commitTool()
        let v0 = m.snapshot.bodies.first?.volume_mm3 ?? 0
        check(abs(v0 - 30 * 20 * 12) < 1, "extruded volume is 7200 mm³ (got \(v0))")

        // Press pull the top face by picking it on screen.
        m.zoomToFit()
        m.tool = .pressPull
        m.click(at: screen([15, 10, 12]), additive: true)
        check(m.selection.first?.isFace == true, "click picks the top face")
        m.toolValue = 8
        m.commitTool()
        let v1 = m.snapshot.bodies.first?.volume_mm3 ?? 0
        check(abs(v1 - 30 * 20 * 20) < 1, "press pull +8 gives 12000 mm³ (got \(v1))")

        // Fillet a top edge picked on screen.
        m.tool = .fillet
        m.click(at: screen([15, 0, 20]), additive: true)
        check(m.selection.first?.isEdge == true, "click near an edge picks it")
        m.toolValue = 3
        m.commitTool()
        let v2 = m.snapshot.bodies.first?.volume_mm3 ?? 0
        check(v2 < v1 && v2 > v1 - 100, "fillet removes a little material (got \(v2))")

        // Undo goes back one step; a primitive lands where clicked on the ground.
        m.undo()
        check(abs((m.snapshot.bodies.first?.volume_mm3 ?? 0) - v1) < 1, "undo restores the press pull result")
        m.tool = .cylinder
        m.toolValue = 10
        m.click(at: screen([-40, 0, 0]), additive: false)
        check(m.snapshot.bodies.count == 2, "cylinder placed on the ground")
        let scene = m.scene
        check(scene.meshes.count == 2 && scene.meshes.allSatisfy { !$0.edges.isEmpty }, "scene has two meshes with edges")

        // Electronics: the KiCad flow on PCBCraft, by clicks in millimetres.
        let pcb = PCBModel()
        func pcbCheck(_ ok: Bool, _ what: String) {
            print(ok ? "PASS" : "FAIL", what, ok ? "" : "(\(pcb.message ?? "no message"))")
            if !ok { failures += 1 }
        }
        pcb.tool = .place("resistor")
        pcb.click(at: PCBPoint(x: 10.16, y: 10.16), scale: 10)
        pcb.tool = .place("led")
        pcb.click(at: PCBPoint(x: 30.48, y: 10.16), scale: 10)
        pcbCheck(pcb.project?.components.count == 2, "two parts placed by clicks")
        let parts = pcb.project?.components ?? []
        pcb.tool = .wire
        if parts.count == 2 {
            pcb.click(at: parts[0].pinPosition(parts[0].pins[1]), scale: 10)
            pcb.click(at: parts[1].pinPosition(parts[1].pins[0]), scale: 10)
            pcb.click(at: parts[0].pinPosition(parts[0].pins[0]), scale: 10)
            pcb.click(at: parts[1].pinPosition(parts[1].pins[1]), scale: 10)
        }
        pcbCheck(pcb.project?.wires.count == 2 && pcb.project?.nets.count == 2, "two wires by pin clicks make two nets")
        pcb.updateBoard()
        pcbCheck(pcb.project?.board.footprints.count == 2, "update board makes two footprints")
        pcbCheck((pcb.checks?.airwires.count ?? 0) == 2, "two airwires before routing")
        pcb.routeAll()
        pcbCheck(pcb.checks?.airwires.isEmpty == true && (pcb.project?.board.tracks.count ?? 0) >= 2, "route all leaves no airwire")
        let kicad = FileManager.default.temporaryDirectory.appendingPathComponent("viaform-selftest.kicad_pcb")
        try? FileManager.default.removeItem(at: kicad)
        pcb.exportKiCad(to: kicad)
        let text = (try? String(contentsOf: kicad, encoding: .utf8)) ?? ""
        pcbCheck(text.hasPrefix("(kicad_pcb"), "KiCad board exported (\(text.count) chars)")
        pcb.undo()
        pcbCheck(pcb.redoCount == 1, "PCB undo works")


        // ECAD to MCAD: the sample board goes into a 3D design, onto an enclosure, then follows a change.
        let d = DesignModel()
        let board = PCBModel(sample: true)
        d.run("solid.box", ["length": 80, "width": 60, "height": 10, "corner": [-10, -50, 0], "body_name": "Enclosure"])
        let pushErr = PCBLink.push(board, into: d)
        pcbCheck(pushErr == nil && d.snapshot.bodies.contains { $0.name == "PCB Board" } && d.snapshot.bodies.contains { $0.name == "PCB R1" },
                 "board, copper and parts built in 3D \(pushErr ?? "")")
        pcbCheck(PCBLink.linkedRevision(d, board) == board.revision && !board.boardOutOfDate, "3D board tagged with the PCB revision")
        let mountErr = PCBLink.mount(board, in: d, body: "Enclosure", at: [30, -20, 10], normal: [0, 0, 1])
        let joints = (try? d.engine.execute("joint.list") as? [String: Any])?["joints"] as? [[String: Any]] ?? []
        pcbCheck(mountErr == nil && !joints.isEmpty, "board mounted on the enclosure with a rigid group \(mountErr ?? "")")
        let comps = (try? d.engine.execute("component.list") as? [String: Any])?["components"] as? [[String: Any]] ?? []
        let tf = (comps.first { $0["name"] as? String == "PCB LED indicator" }?["occurrences"] as? [[String: Any]])?.first?["transform"] as? [[Double]]
        let seat = tf.flatMap { $0.count == 4 ? Array($0[3].prefix(3)) : nil } ?? []
        pcbCheck(seat.count == 3 && abs(seat[0]) < 1e-6 && abs(seat[1]) < 1e-6 && abs(seat[2] - 10) < 1e-6, "board seated on the enclosure top (at \(seat))")
        board.sheet = .board
        board.move(11, to: PCBPoint(x: 30, y: 30))
        pcbCheck(board.boardOutOfDate, "moving a footprint marks the 3D board out of date")
        let updErr = PCBLink.push(board, into: d)
        let joints2 = (try? d.engine.execute("joint.list") as? [String: Any])?["joints"] as? [[String: Any]] ?? []
        pcbCheck(updErr == nil && !board.boardOutOfDate && joints2.count == joints.count, "update keeps the assembly joint \(updErr ?? "")")

        // The same mount driven by a click, as the UI does it: a face of the enclosure's side.
        d.viewSize = CGSize(width: 1200, height: 800)
        d.setView(.front)
        d.zoomToFit()
        var shown = false
        board.startMount(d) { shown = true }
        d.click(at: d.camera.project([-5, -50, 3], size: d.viewSize), additive: false)
        pcbCheck(shown && d.facePick == nil && d.message?.contains("mounted") == true, "mount by clicking a face (\(d.message ?? ""))")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
