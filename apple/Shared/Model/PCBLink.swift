import Foundation
import simd

/// The link between the electronics project and the 3D design: the board becomes a component
/// of the design (board, copper, holes and simple part bodies), tagged with the PCB revision it
/// was built from. Updating rebuilds the bodies inside the same component, so its placement
/// and the joints that hold it in an assembly stay.
enum PCBLink {
    static let tag = "Linked to ViaForm PCB"

    static func componentName(_ p: PCBProject) -> String { "PCB " + ((p.name?.isEmpty == false) ? p.name! : "Board") }

    /// The PCB revision the design's board component was built from, if there is one.
    static func linkedRevision(_ design: DesignModel, _ p: PCBProject) -> Int? {
        guard let r = try? design.engine.execute("component.metadata", ["component": componentName(p)]) as? [String: Any],
              (r["description"] as? String) == tag,
              let rev = (r["revision"] as? String)?.split(separator: "-").last else { return nil }
        return Int(rev)
    }

    /// Builds or rebuilds the board component. Returns an error message, or nil.
    @discardableResult
    static func push(_ pcb: PCBModel, into design: DesignModel) -> String? {
        guard let p = pcb.project else { return "No PCB project" }
        let name = componentName(p)
        let e = design.engine
        do {
            let list = try e.execute("component.list") as? [String: Any]
            let comps = list?["components"] as? [[String: Any]] ?? []
            if let existing = comps.first(where: { $0["name"] as? String == name }) {
                try e.execute("component.activate", ["component": name])
                let old = existing["bodies"] as? [String] ?? []
                if !old.isEmpty { try e.execute("solid.remove", ["bodies": old]) }
            } else {
                try e.execute("component.create", ["name": name, "parent": "root", "activate": true, "grounded": false])
            }
            try build(p, e)
            try e.execute("component.activate", ["component": "root"])
            try e.execute("component.metadata.set", ["component": name, "description": tag, "revision": "pcb-\(pcb.revision)", "part_number": p.name ?? "PCB"])
        } catch {
            _ = try? e.execute("component.activate", ["component": "root"])
            design.refresh()
            return error.localizedDescription
        }
        design.refresh()
        pcb.linkedRevision = pcb.revision
        return nil
    }

    // MARK: Geometry, in the component's frame: PCB x to x, PCB y to -y, board top at z = t

    private static func world(_ q: PCBPoint) -> [Double] { [q.x, -q.y] }

    private static func build(_ p: PCBProject, _ e: CADEngine) throws {
        let b = p.board
        let t = 1.6
        try e.execute("solid.box", ["length": b.width, "width": b.height, "height": t, "corner": [0, -b.height, 0], "body_name": "PCB Board"])
        try e.execute("appearance.assign", ["bodies": ["PCB Board"], "color": "#1f5c3a"])
        for c in b.cutouts {
            let w = world(c.center)
            try e.execute("solid.cylinder", ["radius": c.radius, "height": t + 0.4, "base": [w[0], w[1], -0.2], "operation": "cut", "targets": ["PCB Board"]])
        }

        // Copper: pad rings and tracks on the top (F.Cu) or under the board (B.Cu), one body.
        var copper = false
        func addCopper(_ id: String, _ params: [String: Any]) throws {
            var q = params
            if copper { q["operation"] = "join"; q["targets"] = ["PCB Copper"] } else { q["body_name"] = "PCB Copper" }
            try e.execute(id, q)
            copper = true
        }
        let cu = 0.05
        for f in b.footprints {
            for pad in f.pads {
                let w = world(f.padPosition(pad))
                try addCopper("solid.cylinder", ["radius": pad.diameter / 2, "height": cu, "base": [w[0], w[1], t]])
            }
        }
        for tr in b.tracks {
            let a = world(tr.start), z = world(tr.end)
            let top = tr.layer == "F.Cu" ? t : -cu
            if abs(a[1] - z[1]) < 1e-6 {
                try addCopper("solid.box", ["length": abs(z[0] - a[0]) + tr.width, "width": tr.width, "height": cu,
                                            "corner": [min(a[0], z[0]) - tr.width / 2, a[1] - tr.width / 2, top]])
            } else if abs(a[0] - z[0]) < 1e-6 {
                try addCopper("solid.box", ["length": tr.width, "width": abs(z[1] - a[1]) + tr.width, "height": cu,
                                            "corner": [a[0] - tr.width / 2, min(a[1], z[1]) - tr.width / 2, top]])
            }
        }
        if copper { try e.execute("appearance.assign", ["bodies": ["PCB Copper"], "color": "#c9a54a", "pbr": ["metallic": 1, "roughness": 0.35, "dielectric_ior": 1.5]]) }

        // Plated holes through board and copper.
        for f in b.footprints {
            for pad in f.pads {
                let w = world(f.padPosition(pad))
                let targets = copper ? ["PCB Board", "PCB Copper"] : ["PCB Board"]
                try e.execute("solid.cylinder", ["radius": pad.diameter * 0.22, "height": t + 0.6, "base": [w[0], w[1], -0.3], "operation": "cut", "targets": targets])
            }
        }

        // Part bodies: simple stand-ins sized from the pad span, along the pad axis.
        for f in b.footprints {
            guard let c = p.components.first(where: { $0.id == f.component }) else { continue }
            let pts = f.pads.map { world(f.padPosition($0)) }
            guard let first = pts.first, let last = pts.last else { continue }
            let mid = [(first[0] + last[0]) / 2, (first[1] + last[1]) / 2]
            var axis = SIMD2(last[0] - first[0], last[1] - first[1])
            let span = max(simd_length(axis), 2.54)
            axis = simd_length(axis) > 1e-6 ? simd_normalize(axis) : SIMD2(1, 0)
            let body = "PCB " + c.reference
            let along = abs(axis.x) >= abs(axis.y)
            switch c.kind {
            case "resistor":
                let len = span * 0.62, d = 2.4
                try e.execute("solid.cylinder", ["diameter": d, "height": len, "axis": [axis.x, axis.y, 0],
                                                 "base": [mid[0] - axis.x * len / 2, mid[1] - axis.y * len / 2, t + cu + d / 2 + 0.4], "body_name": body])
                try e.execute("appearance.assign", ["bodies": [body], "color": "#d8c39a"])
            case "capacitor":
                try e.execute("solid.cylinder", ["diameter": 5, "height": 8, "base": [mid[0], mid[1], t + cu], "body_name": body])
                try e.execute("appearance.assign", ["bodies": [body], "color": "#2b4c8c"])
            case "led":
                try e.execute("solid.cylinder", ["diameter": 5, "height": 5.5, "base": [mid[0], mid[1], t + cu], "body_name": body])
                try e.execute("solid.sphere", ["diameter": 4.8, "center": [mid[0], mid[1], t + cu + 5.2], "operation": "join", "targets": [body]])
                try e.execute("appearance.assign", ["bodies": [body], "color": "#46c66a", "opacity": 0.85])
            default:
                let l = along ? span + 5 : 6, w = along ? 6 : span + 5
                try e.execute("solid.box", ["length": l, "width": w, "height": 7, "corner": [mid[0] - l / 2, mid[1] - w / 2, t + cu], "body_name": body])
                try e.execute("appearance.assign", ["bodies": [body], "color": "#2a2a2c"])
            }
        }
    }

    // MARK: Assembly

    /// Seats the board's bottom face on a picked face of another part, its z along that face's
    /// normal, and holds it there with a rigid group. A body of the design's root is first made
    /// into a component of its own, since joints join components.
    @discardableResult
    static func mount(_ pcb: PCBModel, in design: DesignModel, body target: String, at point: SIMD3<Double>, normal: SIMD3<Double>) -> String? {
        guard let p = pcb.project else { return "No PCB project" }
        let name = componentName(p)
        let e = design.engine
        do {
            func components() throws -> [[String: Any]] {
                (try e.execute("component.list") as? [String: Any])?["components"] as? [[String: Any]] ?? []
            }
            var comps = try components()
            guard let board = comps.first(where: { $0["name"] as? String == name }),
                  let boardOcc = (board["occurrences"] as? [[String: Any]])?.first,
                  let boardOccName = boardOcc["name"] as? String else { return "Send the board to 3D first" }
            guard let owner = comps.first(where: { ($0["bodies"] as? [String] ?? []).contains(target) }) else { return "Pick a face of another part" }
            if owner["name"] as? String == name { return "Pick a face of another part, not the board" }
            if (owner["id"] as? Int) == 0 {
                try e.execute("component.from_bodies", ["bodies": [target]])
                comps = try components()
            }
            guard let host = comps.first(where: { ($0["bodies"] as? [String] ?? []).contains(target) }),
                  let hostOcc = (host["occurrences"] as? [[String: Any]])?.first?["name"] as? String else { return "That part has no placement" }

            // Delta = desired * current⁻¹, all in world space.
            let current = matrix(boardOcc["transform"])
            let n = simd_normalize(normal)
            let rot = rotation(from: SIMD3(0, 0, 1), to: n)
            let centre = SIMD3(p.board.width / 2, -p.board.height / 2, 0)
            var desired = matrix_identity_double4x4
            let r3 = rot
            desired.columns.0 = SIMD4(r3.columns.0, 0)
            desired.columns.1 = SIMD4(r3.columns.1, 0)
            desired.columns.2 = SIMD4(r3.columns.2, 0)
            desired.columns.3 = SIMD4(point - r3 * centre, 1)
            let delta = desired * current.inverse
            let rows = (0..<3).map { r in (0..<4).map { c in delta[c][r] } }
            try e.execute("occurrence.move", ["occurrence": boardOccName, "space": "world", "matrix": rows])
            try e.execute("joint.rigid_group", ["occurrences": [boardOccName, hostOcc]])
        } catch {
            design.refresh()
            return error.localizedDescription
        }
        design.refresh()
        return nil
    }

    private static func matrix(_ any: Any?) -> simd_double4x4 {
        guard let rows = any as? [[Double]], rows.count >= 3 else { return matrix_identity_double4x4 }
        var m = matrix_identity_double4x4
        // component.list writes each column of the placement as one row (translation last).
        for col in 0..<min(rows.count, 4) { for r in 0..<min(rows[col].count, 4) { m[col][r] = rows[col][r] } }
        return m
    }

    private static func rotation(from a: SIMD3<Double>, to b: SIMD3<Double>) -> simd_double3x3 {
        let d = simd_dot(a, b)
        if d > 0.999999 { return matrix_identity_double3x3 }
        if d < -0.999999 { return simd_double3x3(simd_quatd(angle: .pi, axis: SIMD3(1, 0, 0))) }
        return simd_double3x3(simd_quatd(from: a, to: b))
    }
}
