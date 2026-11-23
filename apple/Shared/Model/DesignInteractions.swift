import Foundation
import simd

// Direct manipulation on the design canvas (VIAFORM-SPEC 7.1, IMPROVEMENTS front end 1 to 3):
// distance handles on the picked face and the extrude profile, profile picking for Extrude,
// sketch dimensions edited in place and sketch points dragged with live solver frames.
extension DesignModel {
    // MARK: Sketch on the canvas

    /// Reads the sketch the canvas draws: the open one, or the one Extrude takes.
    func reloadSketchInfo() {
        let info: SketchInfo?
        if sketchOpen {
            info = SketchInfo.load(engine, sketch: nil, plane: sketchPlane)
        } else if tool == .extrude, let last = snapshot.sketches.last {
            info = SketchInfo.load(engine, sketch: last.id, plane: nil)
        } else {
            info = nil
        }
        if info != sketchInfo { sketchInfo = info }
    }

    /// Adds or removes one profile from what Extrude takes. Picking every profile, or none,
    /// goes back to taking all of them.
    func toggleProfile(_ index: Int) {
        guard let all = sketchInfo?.profiles.map(\.index) else { return }
        var picked = extrudeProfiles
        if picked.isEmpty { picked = [index] } else if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
        if picked.count == all.count { picked = [] }
        extrudeProfiles = picked
        applyPreview()
    }

    /// The profiles Extrude takes now.
    var extrudedProfiles: [SketchInfo.Profile] {
        (sketchInfo?.profiles ?? []).filter { extrudeProfiles.isEmpty || extrudeProfiles.contains($0.index) }
    }

    /// What Extrude takes, in words for its dialog ("last sketch, 1 of 3 profiles").
    var extrudeProfileSummary: String {
        let total = sketchInfo?.profiles.count ?? 0
        if extrudeProfiles.isEmpty || total == 0 { return total > 1 ? "last sketch, all \(total) profiles, click to pick" : "last sketch, all profiles" }
        return "last sketch, \(extrudeProfiles.count) of \(total) profiles"
    }

    /// Changes a dimension to the typed value (a number, a number with its unit, or an
    /// expression). Answers false when the engine refused it.
    @discardableResult
    func setDimension(_ d: SketchInfo.Dimension, to text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != d.editText else { return false }
        guard let param = d.param else {
            flash("This dimension follows the sketch and cannot be typed", error: true)
            return false
        }
        // A bare number is a length in millimetres, or an angle in degrees.
        if Double(t) != nil { t += d.isAngle ? " deg" : " mm" }
        return run("parameters.change", ["name": param, "expression": t], quiet: true) != nil
    }

    /// Starts dragging the sketch point under `p`, when Select is the tool in an open sketch.
    func beginSketchDrag(at p: CGPoint) -> Bool {
        guard sketchOpen, tool == .select, let info = sketchInfo,
              let q = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize) else { return false }
        // 8 points on screen, in sketch millimetres.
        let radius = 2 * camera.halfHeight / max(Double(viewSize.height), 1) * 8
        guard let pt = info.point(near: q, radius: radius), !pt.fixed else { return false }
        sketchDrag = (pt.id, pt.at)
        return true
    }

    /// One live frame of a point drag: the solver moves the point toward the cursor within the
    /// sketch's constraints.
    func dragSketch(to p: CGPoint) {
        guard let d = sketchDrag, let plane = sketchInfo?.plane,
              let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
        do {
            let r = try engine.execute("sketch.drag", ["entity": d.entity, "from": [d.from.x, d.from.y], "to": [q.x, q.y], "live": true]) as? [String: Any]
            sketchDrag = (d.entity, SketchInfo.vec2(r?["at"]) ?? q)
        } catch {
            flash(error.localizedDescription, error: true)
        }
        refresh()
    }

    /// Ends a point drag: the model evaluates once.
    func endSketchDrag() {
        guard sketchDrag != nil else { return }
        sketchDrag = nil
        run("sketch.drag_end", quiet: true)
    }

    // MARK: Distance handles

    /// The picked face Push / Pull would move from Select (one face, nothing else picked).
    var showsFaceHandle: Bool {
        tool == .select && !sketchOpen && facePick == nil && selectedBodies.isEmpty && selection.count == 1 && selection[0].isFace
    }

    /// Where a distance handle starts and the direction it drags along: the picked face and
    /// its normal (Push / Pull), or the centre of the extruded profiles and the sketch normal.
    var handleAxis: (point: SIMD3<Double>, normal: SIMD3<Double>)? {
        switch tool {
        case .extrude:
            guard let info = sketchInfo else { return nil }
            let picked = extrudedProfiles
            guard !picked.isEmpty else { return nil }
            let area = picked.reduce(0) { $0 + max($1.area, 1e-9) }
            let c = picked.reduce(SIMD2<Double>.zero) { $0 + $1.centroid * max($1.area, 1e-9) } / area
            return (info.plane.toWorld(c), info.plane.normal)
        case .pressPull, .shell, .select:
            if tool == .select && !showsFaceHandle { return nil }
            guard case let .face(_, _, p, n)? = selection.last(where: \.isFace) else { return nil }
            return (p, simd_normalize(n))
        default:
            return nil
        }
    }

    /// The handle axis on screen: a unit direction and the points one millimetre spans along
    /// it. Looking straight down the axis, dragging up the screen adds.
    func handleScreenAxis(point: SIMD3<Double>, normal: SIMD3<Double>, size: CGSize) -> (dir: CGVector, perUnit: Double) {
        let a = camera.project(point, size: size)
        let b = camera.project(point + simd_normalize(normal), size: size)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let flat = Double(size.height) / max(2 * camera.halfHeight, 1e-9)
        if len < max(0.15 * flat, 0.5) { return (CGVector(dx: 0, dy: -1), flat) }
        return (CGVector(dx: dx / len, dy: dy / len), Double(len))
    }

    /// Starts a handle drag. From Select it arms Push / Pull on the picked face.
    func beginHandleDrag() {
        guard handleDrag == nil else { return }
        let implicit = tool == .select
        if implicit {
            armingQuietly = true
            tool = .pressPull
            armingQuietly = false
        }
        handleDrag = (toolValue, implicit)
    }

    /// Sets the value from the drag: `delta` millimetres from where the drag started, snapped
    /// to `step` (0 for none). Each new value replaces the preview (`applyPreview`), so the
    /// whole drag is one undo step.
    func dragHandle(by delta: Double, step: Double) {
        guard let h = handleDrag else { return }
        var v = h.start + delta
        if step > 0 { v = (v / step).rounded() * step }
        if abs(v - toolValue) > 1e-9 { toolValue = v }
    }

    /// Ends a handle drag. A drag that armed Push / Pull itself commits on release, one undo
    /// step; an armed tool keeps its preview and value card for typing (Return commits).
    func endHandleDrag() {
        guard let h = handleDrag else { return }
        handleDrag = nil
        guard h.implicit else { return }
        if hasPreview { commitTool() } else { tool = .select }
    }

    var handleDragging: Bool { handleDrag != nil }

    // MARK: Launch states for checks and screenshots

    /// `--design-demo=handles|profiles|dims` builds a small design in that state after launch.
    func applyDesignDemoFlag() {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--design-demo=") }) else { return }
        let which = String(arg.dropFirst("--design-demo=".count))
        do {
            switch which {
            case "handles":
                try engine.execute("file.new")
                try engine.execute("solid.box", ["length": 60, "width": 40, "height": 20, "corner": [-30, -20, 0], "body_name": "Block"])
                refresh()
                setView(.iso)
                zoomToFit()
                pickTopFace()
                if ProcessInfo.processInfo.arguments.contains("--handle-value") {
                    beginHandleDrag()
                    dragHandle(by: 12, step: 0.5)
                }
            case "profiles":
                try engine.execute("file.new")
                try engine.execute("sketch.create", ["plane": "XY", "name": "Plate"])
                try engine.execute("sketch.rectangle.two_point", ["p0": [-40, -25], "p1": [40, 25]])
                try engine.execute("sketch.circle.center", ["center": [-20, 0], "radius": 9])
                try engine.execute("sketch.circle.center", ["center": [20, 0], "radius": 9])
                try engine.execute("sketch.finish")
                refresh()
                setView(.iso)
                zoomToFit()
                tool = .extrude
                if let small = sketchInfo?.profiles.min(by: { $0.area < $1.area }) { toggleProfile(small.index) }
            case "dims":
                try engine.execute("file.new")
                try engine.execute("sketch.create", ["plane": "XY", "name": "Bracket"])
                let rect = try engine.execute("sketch.rectangle.two_point", ["p0": [0, 0], "p1": [60, 30]]) as? [String: Any]
                let circle = try engine.execute("sketch.circle.center", ["center": [42, 15], "radius": 6]) as? [String: Any]
                let lines = rect?["curves"] as? [String] ?? []
                if lines.count >= 2 {
                    _ = try? engine.execute("sketch.dimension", ["entities": [lines[0]], "text_at": [30, -8]])
                    _ = try? engine.execute("sketch.dimension", ["entities": [lines[1]], "text_at": [68, 15]])
                }
                if let c = (circle?["curves"] as? [String])?.first {
                    _ = try? engine.execute("sketch.dimension", ["entities": [c], "text_at": [52, 26]])
                }
                refresh()
                tool = .select
                setView(.top)
                zoomToFit()
                // `--dim-set=80` types 80 into the first dimension, as a click and Return would.
                if let v = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--dim-set=") })?.dropFirst(10),
                   let d = sketchInfo?.dimensions.first {
                    setDimension(d, to: String(v))
                    zoomToFit()
                }
            default:
                break
            }
        } catch {
            flash(error.localizedDescription, error: true)
        }
    }

    /// Picks the highest face looking up, as a click on it would.
    private func pickTopFace() {
        var best: Pick?
        var bestZ = -Double.infinity
        for (mi, m) in scene.meshes.enumerated() {
            var i = 0
            while i + 2 < m.indices.count {
                let a = m.positions[Int(m.indices[i])], b = m.positions[Int(m.indices[i + 1])], c = m.positions[Int(m.indices[i + 2])]
                let n = simd_normalize(simd_cross(b - a, c - a))
                let z = Double(max(a.z, b.z, c.z))
                if n.z > 0.99, z > bestZ, i / 3 < m.triFace.count {
                    bestZ = z
                    let centre = (a + b + c) / 3
                    best = .face(mesh: mi, face: m.triFace[i / 3], point: SIMD3(Double(centre.x), Double(centre.y), Double(centre.z)),
                                 normal: SIMD3(Double(n.x), Double(n.y), Double(n.z)))
                }
                i += 3
            }
        }
        if let best { selection = [best] }
    }
}
