#if os(macOS)
import Foundation
import simd

/// The showcase products built from the engine's own commands, for the Mac window's samples and
/// screenshots (the iPad has its own copy of the hand in Touch).
///
/// `--hand`: a humanoid hand, palm, wrist, motor pack, four fingers and a thumb of three
/// phalanges each (one component per phalanx, a knuckle on each).
/// `--drone`: a 3 inch frame (centre plate, four arms, motor bells), the sample board sent to
/// 3D and mounted on the plate.
/// `--select=<body>` selects a body, `--pick-top=<body>` picks its top face, `--tool=<tool>`
/// arms a tool (raw value, for example pressPull).
enum DeskSampleHand {
    /// One finger: name, centre along the palm, phalanx lengths (proximal, middle, distal).
    private static let fingers: [(String, Double, [Double])] = [
        ("Index", 11, [40, 26, 20]),
        ("Middle", 32, [44, 28, 21]),
        ("Ring", 53, [41, 26, 20]),
        ("Little", 74, [32, 20, 17]),
    ]
    private static let phalanx = ["Proximal", "Middle", "Distal"]
    static let width = 18.0
    static let palm = (length: 84.0, depth: 22.0, height: 92.0)

    /// Joints and motors the hand has (one motor a degree of freedom).
    static var joints: Int { fingers.count * 3 + 3 + 2 }

    @MainActor
    static func build(into model: DesignModel) {
        model.newDesign()
        var steps: [(String, [String: Any])] = []
        func component(_ name: String) {
            steps.append(("component.activate", ["component": "root"]))
            steps.append(("component.create", ["name": name]))
        }
        component("Palm")
        steps.append(("solid.box", ["length": palm.length, "width": palm.depth, "height": palm.height, "corner": [0, 0, 0], "body_name": "Palm"]))
        component("Wrist")
        steps.append(("solid.cylinder", ["base": [palm.length / 2, palm.depth / 2, -46], "axis": [0, 0, 1], "radius": 24, "height": 44, "operation": "new"]))
        component("Motor Pack")
        for i in 0..<4 {
            steps.append(("solid.box", ["length": 20, "width": 16, "height": 34, "corner": [Double(i) * 21 + 1, palm.depth + 1, 18], "body_name": "Motor \(i + 1)"]))
        }
        for (name, centre, lengths) in fingers {
            var z = palm.height + 2
            for (i, l) in lengths.enumerated() {
                component("\(name) \(phalanx[i])")
                let x0 = centre - width / 2
                steps.append(("solid.box", ["length": width, "width": width, "height": l, "corner": [x0, (palm.depth - width) / 2, z], "body_name": "\(name) \(phalanx[i])"]))
                steps.append(("solid.cylinder", ["base": [x0 - 1, palm.depth / 2, z + width / 2], "axis": [1, 0, 0], "radius": width / 2 + 1, "height": width + 2, "operation": "new"]))
                z += l + 2
            }
        }
        // The thumb leaves the palm sideways, its phalanges along -x.
        var x = -2.0
        for (i, l) in [34.0, 26, 20].enumerated() {
            let part = ["Metacarpal", "Proximal", "Distal"][i]
            component("Thumb \(part)")
            steps.append(("solid.box", ["length": l, "width": width, "height": width + 2, "corner": [x - l, (palm.depth - width) / 2, 24], "body_name": "Thumb \(part)"]))
            steps.append(("solid.cylinder", ["base": [x - width / 2, palm.depth / 2, 23], "axis": [0, 0, 1], "radius": width / 2 + 1, "height": width + 4, "operation": "new"]))
            x -= l + 2
        }
        steps.append(("component.activate", ["component": "root"]))
        for (id, p) in steps { model.run(id, p, quiet: true) }
        model.message = nil
        model.setView(.iso)
        model.zoomToFit()
    }
}

enum DeskSamples {
    @MainActor
    static func drone(_ model: DesignModel, pcb: PCBModel) {
        model.newDesign()
        guard let b = pcb.project?.board else { return }
        // The plate leaves 6 mm each side of the board along x and 4 mm along y.
        let plate = (x: b.width + 12, y: b.height + 8, z: 3.0)
        let arm = 64.0
        var steps: [(String, [String: Any])] = [
            ("component.activate", ["component": "root"]),
            ("component.create", ["name": "Frame"]),
            ("solid.box", ["length": plate.x, "width": plate.y, "height": plate.z, "corner": [-plate.x / 2, -plate.y / 2, 0], "body_name": "Frame"]),
            ("solid.box", ["length": arm * 2 + plate.x, "width": 8, "height": plate.z, "corner": [-arm - plate.x / 2, -4, 0], "body_name": "Arms X"]),
            ("solid.box", ["length": 8, "width": arm * 2 + plate.y, "height": plate.z, "corner": [-4, -arm - plate.y / 2, 0], "body_name": "Arms Y"]),
        ]
        for (i, c) in [(arm + plate.x / 2, 0.0), (-arm - plate.x / 2, 0.0), (0.0, arm + plate.y / 2), (0.0, -arm - plate.y / 2)].enumerated() {
            steps.append(("component.activate", ["component": "root"]))
            steps.append(("component.create", ["name": "Motor \(i + 1)"]))
            steps.append(("solid.cylinder", ["base": [c.0, c.1, plate.z], "axis": [0, 0, 1], "radius": 7, "height": 9, "operation": "new"]))
        }
        steps.append(("component.activate", ["component": "root"]))
        for (id, p) in steps { model.run(id, p, quiet: true) }
        pcb.sendTo3D(model)
        PCBLink.mount(pcb, in: model, body: "Frame", at: [0, 0, plate.z], normal: [0, 0, 1])
        pcb.message = nil
        model.message = nil
        model.setView(.iso)
        model.zoomToFit()
    }

    /// Selection and tool flags, after a sample is built.
    @MainActor
    static func applySelectionFlags(_ model: DesignModel) {
        let args = ProcessInfo.processInfo.arguments
        if let b = args.first(where: { $0.hasPrefix("--select=") })?.dropFirst(9) {
            model.selectedBodies = [String(b)]
        }
        if let b = args.first(where: { $0.hasPrefix("--pick-top=") })?.dropFirst(11) {
            pickTop(String(b), model)
        }
        if let t = args.first(where: { $0.hasPrefix("--tool=") })?.dropFirst(7), let tool = Tool(rawValue: String(t)) {
            model.tool = tool
        }
    }

    /// Picks the top face of a body (the triangle facing +z the highest up), as a click would.
    @MainActor
    static func pickTop(_ body: String, _ model: DesignModel) {
        let scene = model.scene
        var best: Pick?
        var bestZ = -Double.infinity
        for (mi, m) in scene.meshes.enumerated() where m.body == body {
            var i = 0
            while i + 2 < m.indices.count {
                let a = m.positions[Int(m.indices[i])], b = m.positions[Int(m.indices[i + 1])], c = m.positions[Int(m.indices[i + 2])]
                let n = simd_normalize(simd_cross(b - a, c - a))
                let z = Double(max(a.z, b.z, c.z))
                if n.z > 0.99, z > bestZ {
                    bestZ = z
                    let centre = (a + b + c) / 3
                    best = .face(mesh: mi, face: m.triFace[i / 3], point: SIMD3(Double(centre.x), Double(centre.y), Double(centre.z)),
                                 normal: SIMD3(Double(n.x), Double(n.y), Double(n.z)))
                }
                i += 3
            }
        }
        if let best { model.selection = [best] }
    }
}
#endif
