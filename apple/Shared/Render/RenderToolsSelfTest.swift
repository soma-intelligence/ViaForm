import MetalKit
import simd

/// Checks for the on-canvas tools (B-13 handles and move gizmo, B-15 section view). They run
/// real engine commands through `DesignModel` and draw real frames offscreen.
enum RenderToolsSelfTest {
    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let size = CGSize(width: 800, height: 600)

        // Handles: a drag along the arrow maps to millimetres, snapped.
        var cam = OrbitCamera()
        cam.target = .zero
        cam.distance = 200
        let axis = HandleMath.screenAxis(camera: cam, point: .zero, direction: SIMD3(0, 0, 1), size: size)
        let along = CGSize(width: axis.dir.dx * axis.perUnit * 7.2, height: axis.dir.dy * axis.perUnit * 7.2)
        let v = HandleMath.linearValue(start: 2, translation: along, axis: axis, step: 0.5)
        out.append((abs(v - 9) < 1e-9, "B-13 a radius arrow dragged 7.2 mm from 2 mm snaps to 9 mm (got \(v))"))
        let unwrapped = HandleMath.unwrap(-170, near: 175)
        out.append((abs(unwrapped - 190) < 1e-9, "B-13 the angle arc unwraps past 180 degrees (got \(unwrapped))"))
        let tan = ToolHandlePlacement.tangent([SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 10, 0)], near: SIMD3(9, 6, 0))
        out.append((tan.map { simd_distance($0, SIMD3(0, 1, 0)) < 1e-9 } == true, "B-13 the fillet arrow reads the edge's direction at the pick"))

        // Move gizmo: an X arrow drag with Copy on is one solid.move with copy: true.
        let m = DesignModel()
        m.run("solid.box", ["length": 20, "width": 20, "height": 20, "corner": [-10, -10, 0], "body_name": "Cube"])
        m.viewSize = size
        m.setView(.iso)
        m.zoomToFit()
        var g = MoveGizmoState(pivot: SIMD3(0, 0, 10))
        g.copy = true
        let x = HandleMath.screenAxis(camera: m.camera, point: g.centre, direction: SIMD3(1, 0, 0), size: size)
        let drag = CGSize(width: x.dir.dx * x.perUnit * 30.2, height: x.dir.dy * x.perUnit * 30.2)
        g = MoveGizmoState.draggingArrow(g, axis: 0, translation: drag, camera: m.camera, size: size, step: 0.5)
        out.append((abs(g.translate.x - 30) < 1e-9 && g.translate.y == 0 && g.translate.z == 0,
                    "B-13 the gizmo's X arrow maps a drag to a 30 mm move (got \(g.translate))"))
        let cmd = g.command(bodies: ["Cube"])
        let t = cmd?.params["translate"] as? [Double] ?? []
        out.append((cmd?.id == "solid.move" && cmd?.params["copy"] as? Bool == true && t == [30, 0, 0] && cmd?.params["angle"] == nil,
                    "B-13 the gizmo sends solid.move with copy and the translation"))
        if let cmd { m.run(cmd.id, cmd.params) }
        // The engine's scene, not the model's: a slow first build may still be on the worker.
        let built = m.engine.scene(camera: m.camera)
        let names = built.meshes.map(\.body)
        let moved = built.meshes.first { $0.body != "Cube" }
        out.append((m.snapshot.bodies.count == 2 && names.contains("Cube") && abs(Double(moved?.lo.x ?? 0) - 20) < 0.01,
                    "B-13 Copy keeps the cube and adds a copy 30 mm along X (\(names), copy from x \(moved?.lo.x ?? .nan), \(m.message ?? "no message"))"))

        // A ring drag turns about the pivot: a quarter turn about Z keeps the centre.
        let r = DesignModel()
        r.run("solid.box", ["length": 60, "width": 20, "height": 10, "corner": [10, -10, 0], "body_name": "Bar"])
        r.viewSize = size
        r.setView(.top)
        r.zoomToFit()
        var q = MoveGizmoState(pivot: SIMD3(40, 0, 5))
        let ringR = 50.0
        let from = r.camera.project(q.centre + SIMD3(ringR, 0, 0), size: size)
        let to = r.camera.project(q.centre + SIMD3(0, ringR, 0), size: size)
        q = MoveGizmoState.draggingRing(q, axis: 2, from: from, to: to, camera: r.camera, size: size, step: 5)
        out.append((abs(q.angle - 90) < 1e-6, "B-13 a ring drag from +X to +Y is a 90 degree turn about Z (got \(q.angle))"))
        if let c = q.command(bodies: ["Bar"]) { r.run(c.id, c.params) }
        if let bar = r.engine.scene(camera: r.camera).meshes.first {
            let lo = SIMD3<Double>(bar.lo), hi = SIMD3<Double>(bar.hi)
            let centre = (lo + hi) / 2, ext = hi - lo
            out.append((simd_length(centre - SIMD3(40, 0, 5)) < 0.05 && abs(ext.x - 20) < 0.05 && abs(ext.y - 60) < 0.05 && r.snapshot.bodies.count == 1,
                        "B-13 the turn is about the pivot, not the origin (centre \(centre), size \(ext))"))
        } else {
            out.append((false, "B-13 the turned bar is in the scene"))
        }

        // Section: the plane clips the scene's triangles, the engine takes it, the GPU cuts.
        let s = DesignModel()
        s.run("solid.box", ["length": 60, "width": 40, "height": 20, "corner": [-30, -20, 0], "body_name": "Block"])
        s.viewSize = size
        s.setView(.iso)
        s.zoomToFit()
        let cut = SectionPlane(origin: .zero, normal: SIMD3(1, 0, 0))
        let block = s.engine.scene(camera: s.camera)
        let all = SectionClip.kept(block, plane: nil), half = SectionClip.kept(block, plane: cut)
        out.append((all.triangles > 0 && half.triangles < all.triangles && half.meshes == 1,
                    "B-15 a section through the middle clips triangles (\(half.triangles) of \(all.triangles) kept)"))
        let away = SectionClip.kept(block, plane: SectionPlane(origin: SIMD3(-100, 0, 0), normal: SIMD3(1, 0, 0)))
        out.append((away.meshes == 0 && away.triangles == 0, "B-15 a section past the body hides it (\(away.meshes) meshes)"))

        let section = SectionController.of(s)
        out.append((SectionController.of(s) === section, "B-15 one section controller per design"))
        let ok = section.set(cut, model: s)
        out.append((ok && section.plane == cut && s.lastRun?.id == "inspect.section" && s.lastRun?.ok == true,
                    "B-15 the engine takes the section plane and the controller reads it back"))
        _ = section.set(named: "XZ", offset: 5, model: s)
        let named = section.plane
        out.append((named.map { abs($0.origin.y - 5) < 1e-9 && abs(abs($0.normal.y) - 1) < 1e-9 } == true,
                    "B-15 a named plane with an offset reads back as origin and normal (\(String(describing: named)))"))
        _ = section.set(cut, model: s)

        // The drag arrow moves the cut on the GPU; the engine hears about it on release.
        section.beginDrag()
        section.drag(to: -12)
        out.append((section.plane.map { abs($0.origin.x + 12) < 1e-9 } == true, "B-15 the section arrow drags the plane along its normal"))
        section.endDrag(model: s)
        out.append((section.dragBase == nil && section.plane.map { abs($0.origin.x + 12) < 1e-9 } == true && s.lastRun?.id == "inspect.section",
                    "B-15 releasing the arrow sends the moved plane to the engine"))
        _ = section.set(cut, model: s)

        // Real frames, offscreen: the cut hides part of the block and caps it.
        if let device = MTLCreateSystemDefaultDevice() {
            let view = MTKView(frame: CGRect(origin: .zero, size: CGSize(width: 320, height: 240)), device: device)
            if let renderer = Renderer(view: view, theme: ViaFormTheme().viewportTheme) {
                renderer.camera = s.camera
                renderer.update(scene: block)
                section.bind(renderer)
                out.append((renderer.sectionPlane == cut && renderer.capCount == 1, "B-15 the bound renderer clips by the plane and caps the block"))
                let empty = Renderer(view: MTKView(frame: view.frame, device: device), theme: ViaFormTheme().viewportTheme)
                // The same grid with no bodies and no lines: what the frames are compared with.
                var bare = block
                bare.meshes = []
                bare.lines = []
                bare.serial = 0
                empty?.update(scene: bare)
                empty?.camera = s.camera
                let back = empty?.renderOffscreen(width: 320, height: 240)
                let cutFrame = renderer.renderOffscreen(width: 320, height: 240)
                renderer.sectionPlane = nil
                let full = renderer.renderOffscreen(width: 320, height: 240)
                renderer.sectionPlane = cut
                renderer.sectionHatch = false
                let plain = renderer.renderOffscreen(width: 320, height: 240)
                if let back, let cutFrame, let full, let plain {
                    let covFull = coverage(full, back), covCut = coverage(cutFrame, back)
                    out.append((covFull > 500 && covCut < covFull * 9 / 10 && covCut > covFull / 4,
                                "B-15 the section cuts the drawn block (\(covCut) of \(covFull) pixels left)"))
                    let hatchPixels = coverage(cutFrame, plain)
                    out.append((hatchPixels > 20, "B-15 the cap is hatched (\(hatchPixels) pixels differ from a plain cap)"))
                } else {
                    out.append((false, "B-15 offscreen frames render"))
                }
            } else {
                out.append((false, "B-15 a renderer starts offscreen"))
            }
        }
        section.clear(model: s)
        out.append((section.plane == nil && s.lastRun?.ok == true, "B-15 clearing turns the section off"))
        return out
    }

    /// Pixels of `a` that differ from `b` by more than a little.
    private static func coverage(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return 0 }
        var n = 0
        var i = 0
        while i + 3 < a.count {
            let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
            if d > 24 { n += 1 }
            i += 4
        }
        return n
    }
}
