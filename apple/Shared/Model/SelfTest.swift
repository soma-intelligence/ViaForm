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
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
