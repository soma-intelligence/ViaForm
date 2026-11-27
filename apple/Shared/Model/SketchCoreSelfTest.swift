import CoreGraphics
import Foundation
import simd

/// Checks for drawing and selection on the canvas (B-6, B-8, B-11, B-12, M-8, M-9, M-10, M-16,
/// T-7, T-8, the edited extrude's profiles). Each runs real engine commands through DesignModel.
enum SketchCoreSelfTest {
    /// `--sketch-core-selftest`: runs only these checks, prints them and quits (before the lead
    /// wires them into SelfTest.swift). `--sketch-core-selftest-out=<path>` also writes them.
    @MainActor static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--sketch-core-selftest") else { return }
        DispatchQueue.main.async {
            let results = checks()
            let failures = results.filter { !$0.0 }.count
            let lines = results.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 } + [failures == 0 ? "ALL PASS" : "\(failures) FAILED"]
            print(lines.joined(separator: "\n"))
            fflush(stdout)
            if let out = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--sketch-core-selftest-out=") })?.dropFirst(27) {
                try? lines.joined(separator: "\n").write(toFile: String(out), atomically: true, encoding: .utf8)
            }
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// A model with a sketch open on XY, seen from the top around `centre`.
    @MainActor private static func sketching(_ centre: SIMD2<Double>, setup: (DesignModel) -> Void = { _ in }) -> DesignModel {
        let m = DesignModel()
        m.run("file.new", quiet: true)
        setup(m)
        m.viewSize = CGSize(width: 1000, height: 700)
        m.startSketch("XY")
        m.setView(.top)
        m.camera.target = SIMD3(centre.x, centre.y, 0)
        m.cameraChanged(final: true)
        return m
    }

    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let savedFilter = SelectionFilter.stored
        defer { UserDefaults.standard.set(savedFilter.rawValue, forKey: SelectionFilter.storageKey) }

        // B-6: a line drawn nearly level snaps level and gets a Horizontal constraint.
        let m = sketching(SIMD2(20, 10))
        guard let plane = m.sketchPlane else { return [(false, "a sketch opens on XY")] }
        func screen(_ q: SIMD2<Double>, _ model: DesignModel? = nil) -> CGPoint {
            let mm = model ?? m
            return mm.camera.project((mm.sketchPlane ?? plane).toWorld(q), size: mm.viewSize)
        }
        m.selectionFilter = .auto
        m.tool = .line
        m.click(at: screen(SIMD2(0, 0)), mode: .replace)
        m.hover(at: screen(SIMD2(30, 0.25)))
        let snapped = m.cursorHit?.kind
        let inference = m.inferenceLine != nil
        m.click(at: screen(SIMD2(30, 0.25)), mode: .replace)
        m.endChain()
        let names = m.sketchInfo?.glyphs.map(\.name) ?? []
        out.append((snapped == .horizontal && inference, "B-6 the cursor snaps level with the last click and shows the inference line (\(String(describing: snapped)))"))
        out.append((names.contains("Horizontal"), "B-6 the drawn line gets a Horizontal constraint (\(names))"))

        // B-8: a rectangle typed 40 x 20 adds two dimensions.
        m.tool = .rectangle
        let dims0 = m.sketchInfo?.dimensions.count ?? 0
        m.click(at: screen(SIMD2(50, 20)), mode: .replace)
        let fields = m.sizeFields.map(\.role)
        m.typeSize("40")
        m.sizeTab()
        m.typeSize("20")
        m.endChain()
        let dims = m.sketchInfo?.dimensions ?? []
        let values = dims.map(\.value).sorted()
        out.append((fields == ["width", "height"], "B-8 the rectangle shows width and height boxes (\(fields))"))
        out.append((dims.count - dims0 == 2 && values.contains { abs($0 - 40) < 1e-6 } && values.contains { abs($0 - 20) < 1e-6 },
                    "B-8 typed 40 x 20 adds two dimensions (\(dims0) to \(dims.count): \(values))"))

        // B-12: press and drag from the end of a line chain draws a tangent arc.
        m.tool = .line
        m.click(at: screen(SIMD2(0, -30)), mode: .replace)
        m.click(at: screen(SIMD2(20, -30)), mode: .replace)
        let began = m.beginTangentArc(at: screen(SIMD2(20, -30)))
        m.dragTangentArc(to: screen(SIMD2(30, -20)))
        let preview = m.rubberBand.first?.count ?? 0
        m.endTangentArc()
        let arcs = m.sketchInfo?.curves.filter { $0.kind == "arc" }.count ?? 0
        let goesOn = m.clicks.last.map { simd_distance($0, SIMD2(30, -20)) < 0.6 } ?? false
        out.append((began && preview > 2 && arcs == 1 && goesOn, "B-12 a drag from the chain end makes a tangent arc and the chain goes on (\(began), \(arcs) arcs)"))
        m.endChain()

        // M-16: a path dragged across a piece trims it.
        m.run("sketch.line", ["points": [[100, 0], [140, 0]]], quiet: true)
        m.run("sketch.line", ["points": [[120, -10], [120, 10]]], quiet: true)
        m.camera.target = SIMD3(120, 0, 0)
        m.cameraChanged(final: true)
        m.tool = .trim
        let trimmed = m.trimDrag(path: [screen(SIMD2(110, -4)), screen(SIMD2(110, 4))], size: m.viewSize)
        let leftGone = !(m.sketchInfo?.curves.contains { c in c.kind == "line" && c.polyline.contains { abs($0.x - 100) < 1e-6 && abs($0.y) < 1e-6 } } ?? true)
        out.append((trimmed >= 1 && leftGone, "M-16 a trim path across a piece removes it (\(trimmed) trimmed)"))
        m.tool = .select
        m.finishSketch()

        // B-11 Project and Mirror, M-8 box select in a sketch.
        let p = sketching(SIMD2(20, 10)) { m in
            m.run("solid.box", ["length": 20, "width": 20, "height": 10, "corner": [0, 0, 0], "body_name": "Block"], quiet: true)
        }
        p.tool = .project
        let before = p.sketchInfo?.curves.count ?? 0
        p.click(at: screen(SIMD2(10, 10), p), mode: .replace)
        let linked = p.sketchInfo?.curves.filter(\.linked).count ?? 0
        out.append(((p.sketchInfo?.curves.count ?? 0) > before && linked >= 4, "B-11 Project takes the face's edges in as linked curves (\(linked))"))
        p.run("sketch.line", ["points": [[30, -10], [30, 30]]], quiet: true)
        p.run("sketch.line", ["points": [[35, 0], [45, 0]]], quiet: true)
        guard let info = p.sketchInfo, let axis = info.curves.first(where: { $0.polyline.first == SIMD2(30, -10) }),
              let source = info.curves.first(where: { $0.polyline.first == SIMD2(35, 0) }) else {
            out.append((false, "B-11 the mirror lines are drawn"))
            return out
        }
        _ = axis
        p.tool = .select
        p.sketchSelection = [SketchPick(id: source.id, kind: .line)]
        p.tool = .sketchMirror
        let count0 = p.sketchInfo?.curves.count ?? 0
        let target = p.sketchOpTarget
        p.click(at: screen(SIMD2(30, 20), p), mode: .replace)
        let mirrored = p.sketchInfo?.curves.contains { c in c.polyline.contains { abs($0.x - 25) < 1e-6 && abs($0.y) < 1e-6 } } ?? false
        out.append((target && (p.sketchInfo?.curves.count ?? 0) == count0 + 1 && mirrored, "B-11 Mirror copies the picked line about the clicked line"))

        p.tool = .select
        p.camera.target = SIMD3(38, 0, 0)
        p.cameraChanged(final: true)
        func rect(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> CGRect {
            let s = screen(a, p), t = screen(b, p)
            return CGRect(x: min(s.x, t.x), y: min(s.y, t.y), width: abs(t.x - s.x), height: abs(t.y - s.y))
        }
        p.boxSelect(rect(SIMD2(33, -3), SIMD2(47, 3)), crossing: false, size: p.viewSize)
        let window = p.sketchSelection.filter(\.isCurve).count
        p.boxSelect(rect(SIMD2(28, -3), SIMD2(40, 3)), crossing: false, size: p.viewSize)
        let windowPart = p.sketchSelection.filter(\.isCurve).count
        p.boxSelect(rect(SIMD2(28, -3), SIMD2(40, 3)), crossing: true, size: p.viewSize)
        let crossing = p.sketchSelection.filter(\.isCurve).count
        let direction = SelectionBox.from(CGPoint(x: 100, y: 0), to: CGPoint(x: 0, y: 50)).crossing
        out.append((window == 1 && windowPart == 0 && crossing == 2 && direction,
                    "M-8 window takes what is inside, crossing what it touches (\(window), \(windowPart), \(crossing))"))
        p.finishSketch()

        // M-8 in 3D, M-9 filter and pick list.
        let q = DesignModel()
        q.run("file.new", quiet: true)
        q.run("solid.box", ["length": 10, "width": 10, "height": 10, "corner": [0, 0, 0], "body_name": "A"], quiet: true)
        q.run("solid.box", ["length": 10, "width": 10, "height": 10, "corner": [30, 0, 0], "body_name": "B"], quiet: true)
        q.viewSize = CGSize(width: 1000, height: 700)
        q.setView(.top)
        q.camera.target = SIMD3(20, 5, 0)
        q.cameraChanged(final: true)
        func w(_ x: Double, _ y: Double, _ z: Double = 10) -> CGPoint { q.camera.project(SIMD3(x, y, z), size: q.viewSize) }
        func box(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)) }
        q.selectionFilter = .auto
        q.boxSelect(box(w(-2, -2), w(12, 12)), crossing: false, size: q.viewSize)
        let one = q.selectedBodies
        q.boxSelect(box(w(5, 5), w(35, 6)), crossing: true, size: q.viewSize)
        let two = q.selectedBodies
        q.boxSelect(box(w(5, 5), w(35, 6)), crossing: false, size: q.viewSize)
        let none = q.selectedBodies
        out.append((one == ["A"] && two == ["A", "B"] && none.isEmpty, "M-8 bodies: window \(one.sorted()), crossing \(two.sorted()), window across \(none.sorted())"))

        q.selectedBodies = []
        q.selectionFilter = .edge
        q.click(at: w(5, 5), mode: .replace)
        let mid = q.selection.count
        q.click(at: w(5, 0.2), mode: .replace)
        let edgeOnly = q.selection.count == 1 && q.selection[0].isEdge
        q.selectionFilter = .face
        q.click(at: w(5, 0.2), mode: .replace)
        let faceOnly = q.selection.count == 1 && q.selection[0].isFace
        out.append((mid == 0 && edgeOnly && faceOnly, "M-9 the Edge filter picks only edges, the Face filter only faces"))
        q.selectionFilter = .auto
        let cands = q.pickCandidates(at: w(5, 0.2), size: q.viewSize)
        let kinds = Set(cands.map(\.kind))
        if let face = cands.first(where: { $0.kind == .face }) { q.choose(face) }
        out.append((kinds.isSuperset(of: [.edge, .face, .body]) && q.selection.first?.isFace == true,
                    "M-9 the pick list holds the edge, the faces and the body, and choosing one selects it (\(cands.map(\.label)))"))

        // M-10, T-7, T-8 and the edited extrude's profiles.
        let r = DesignModel()
        r.run("file.new", quiet: true)
        r.run("sketch.create", ["plane": "XY"], quiet: true)
        r.run("sketch.rectangle.two_point", ["p0": [0, 0], "p1": [20, 10]], quiet: true)
        r.run("sketch.finish", quiet: true)
        let first = r.snapshot.sketches.last?.id
        r.run("solid.extrude", ["distance": 5], quiet: true)
        r.run("sketch.create", ["plane": "XY"], quiet: true)
        r.run("sketch.circle.center", ["center": [60, 0], "radius": 4], quiet: true)
        r.run("sketch.circle.center", ["center": [80, 0], "radius": 4], quiet: true)
        r.run("sketch.finish", quiet: true)
        let second = r.snapshot.sketches.last?.id
        r.viewSize = CGSize(width: 1000, height: 700)
        r.setView(.top)
        r.camera.target = SIMD3(40, 5, 0)
        r.cameraChanged(final: true)
        let top = ScenePicker.pickFace(r.scene, camera: r.camera, at: r.camera.project(SIMD3(10, 5, 5), size: r.viewSize), size: r.viewSize)
        let owner = top.flatMap { r.owningFeature(ofFace: $0) }
        let extrudeName = r.snapshot.timeline.first { $0.type.lowercased().contains("extrude") }?.name
        out.append((owner != nil && owner?.feature == extrudeName && owner?.sketch == first,
                    "M-10 the top face names its extrude and sketch (\(String(describing: owner)), \(String(describing: extrudeName)), \(String(describing: first)))"))

        if let name = extrudeName {
            let s = FeatureSession.of(r)
            let opened = s.beginEdit(name)
            out.append((opened && r.sketchInfo?.id == first && first != second,
                        "Editing an extrude shows its own sketch's profiles, not the last sketch (\(String(describing: r.sketchInfo?.id)))"))
            s.cancelEdit()
        }

        let tapped = r.profileTap(at: r.camera.project(SIMD3(80, 0, 0), size: r.viewSize))
        out.append((tapped && r.tool == .extrude && r.extrudeSketch == second && r.extrudeProfiles.count == 1,
                    "T-8 a tap on a profile starts Extrude on that profile (\(r.extrudeProfiles))"))
        r.cancelTool()
        r.tool = .select
        r.faceDoubleTap(at: r.camera.project(SIMD3(10, 5, 5), size: r.viewSize))
        out.append((r.sketchOpen, "T-7 a double tap on a planar face starts a sketch on it"))
        r.finishSketch()
        out += reviewChecks()
        return out
    }

    /// Regressions from the code review (findings 2, 8, 10, 11).
    @MainActor private static func reviewChecks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        // 2: one selection space. A sketch on a block's top face, a line drawn beside the face.
        let m = sketching(SIMD2(30, 10)) { m in
            m.run("solid.box", ["length": 20, "width": 20, "height": 10, "corner": [0, 0, -10], "body_name": "Block"], quiet: true)
        }
        m.selectionFilter = .auto
        m.run("sketch.line", ["points": [[40, 0], [60, 0]]], quiet: true)
        func screen(_ q: SIMD2<Double>) -> CGPoint { m.camera.project((m.sketchPlane?.toWorld(q)) ?? .zero, size: m.viewSize) }
        m.tool = .select
        m.click(at: screen(SIMD2(50, 0)), mode: .replace)
        let line = m.sketchSelection.count
        m.click(at: screen(SIMD2(5, 15)), mode: .toggle)
        let face = m.selection.count
        out.append((line == 1 && face == 1 && m.sketchSelection.isEmpty,
                    "Review 2: a 3D pick after a sketch pick clears the sketch selection (\(line), \(face), \(m.sketchSelection.count))"))
        m.click(at: screen(SIMD2(50, 0)), mode: .add)
        out.append((m.sketchSelection.count == 1 && m.selection.isEmpty && m.selectedBodies.isEmpty,
                    "Review 2: a sketch pick after a 3D pick clears faces and bodies"))
        let curves = m.sketchInfo?.curves.count ?? 0
        m.selectedBodies = ["Block"]
        let dropped = m.sketchSelection.isEmpty
        m.deleteSelection()
        // Removing the body may close the sketch; its line must survive either way.
        out.append((dropped && (m.sketchInfo.map { $0.curves.count == curves } ?? true) && m.snapshot.bodies.isEmpty,
                    "Review 2: Delete with a body picked removes the body, not the hidden sketch line"))
        m.run("edit.undo", quiet: true)

        // 10: a finger tap on nothing clears the sketch selection.
        m.click(at: screen(SIMD2(50, 0)), mode: .replace)
        m.touchTaps = true
        m.click(at: screen(SIMD2(80, 30)), mode: .toggle)
        let cleared = m.sketchSelection.isEmpty
        m.touchTaps = false
        m.click(at: screen(SIMD2(50, 0)), mode: .replace)
        m.click(at: screen(SIMD2(80, 30)), mode: .toggle)
        out.append((cleared && m.sketchSelection.count == 1,
                    "Review 10: a tap on nothing clears the sketch selection; a Command-click on nothing keeps it"))

        // 8: a Pencil 10 points from a sketch point grabs it, so no box starts there.
        let near = screen(SIMD2(60, 0))
        let off = CGPoint(x: near.x, y: near.y - 10)
        out.append((m.sketchPointGrabbable(at: off, radius: 12) && !m.emptyCanvas(at: off, grab: 12),
                    "Review 8: a press within the Pencil's grab of a sketch point is not empty canvas"))
        m.finishSketch()

        // 11: the pick list goes when the tool, the scene or the view changes; a stale item is
        // ignored.
        let q = DesignModel()
        q.run("file.new", quiet: true)
        q.run("solid.box", ["length": 10, "width": 10, "height": 10, "corner": [0, 0, 0], "body_name": "A"], quiet: true)
        q.viewSize = CGSize(width: 1000, height: 700)
        q.setView(.top)
        q.camera.target = SIMD3(5, 5, 0)
        q.cameraChanged(final: true)
        let at = q.camera.project(SIMD3(5, 5, 10), size: q.viewSize)
        let opened = q.openPickList(at: at)
        q.tool = .fillet
        let afterTool = q.pickList == nil
        q.tool = .select
        q.openPickList(at: at)
        q.refresh()
        let afterRefresh = q.pickList == nil
        q.openPickList(at: at)
        q.camera.orbit(dx: 10, dy: 0)
        q.cameraChanged()
        let afterOrbit = q.pickList == nil
        out.append((opened && afterTool && afterRefresh && afterOrbit,
                    "Review 11: the pick list closes on a tool change, a refresh and an orbit"))
        let keep = q.selection
        q.choose(PickCandidate(id: "edge:9:9", label: "stale", kind: .edge, target: .entity(.edge(mesh: 9, edge: 9, point: .zero))))
        q.choose(PickCandidate(id: "edge:0:999", label: "stale", kind: .edge, target: .entity(.edge(mesh: 0, edge: 999, point: .zero))))
        q.choose(PickCandidate(id: "body:Gone", label: "Gone", kind: .body, target: .body("Gone")))
        out.append((q.selection == keep && q.selectedBodies.isEmpty, "Review 11: choosing a stale pick list item changes nothing"))
        return out
    }
}
