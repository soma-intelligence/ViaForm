import Foundation
import simd

/// The hand product's assembly for the grasp editor: the five-finger kinematic hand of kin
/// (`hand5`: 22 joints, tendon couplings on middle, ring and little) as one component per bone
/// and one joint per kin joint, at the home pose. Built once from kin's `model.info`,
/// `model.json` and `fk`, so the document, the canvas and the solver share one chain.
enum HandAssembly {
    struct Built {
        var json: String
        var links: [String]
        var joints: [String]
        /// Per bone, the points it reaches at home (children origins, fingertip), mm.
        var tips: [String: [SIMD3<Double>]]
        var frames: [String]
    }

    static func build(_ engine: AssembleEngine) throws -> Built {
        let info = try engine.kinCall("model.info")
        let model = try engine.kinCall("model.json")
        let links = info["links"] as? [String] ?? []
        let jinfo = info["joints"] as? [[String: Any]] ?? []
        let jmodel = model["joints"] as? [[String: Any]] ?? []
        let frames = model["end_effectors"] as? [[String: Any]] ?? []
        let nq = info["nq"] as? Int ?? jinfo.count
        let fk = try engine.kinCall("fk", ["q": Array(repeating: 0.0, count: nq)])
        let linkPoses = (fk["links"] as? [[String: Any]] ?? []).map(AssembleModel.matrix(pose:))
        let framePoses = (fk["frames"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? [String: Any]).map(AssembleModel.matrix(pose:)) }
        func pos(_ m: simd_float4x4) -> SIMD3<Double> { SIMD3(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z)) }

        var tips: [String: [SIMD3<Double>]] = [:]
        var joints: [[String: Any]] = []
        var jointNames: [String] = []
        for (i, j) in jinfo.enumerated() where i + 1 < links.count && i + 1 < linkPoses.count {
            let name = j["name"] as? String ?? "j\(i)"
            let parent = j["parent"] as? Int ?? 0
            let child = linkPoses[i + 1]
            let local = (i < jmodel.count ? jmodel[i]["axis"] as? [Double] : nil) ?? [0, 0, 1]
            let axis = simd_float3x3(columns: (SIMD3(child.columns.0.x, child.columns.0.y, child.columns.0.z),
                                               SIMD3(child.columns.1.x, child.columns.1.y, child.columns.1.z),
                                               SIMD3(child.columns.2.x, child.columns.2.y, child.columns.2.z))) * SIMD3(Float(local[0]), Float(local[1]), Float(local[2]))
            let o = pos(child)
            tips[links[parent], default: []].append(o)
            var joint: [String: Any] = [
                "id": name, "type": "revolute", "parent": links[parent], "child": links[i + 1],
                "origin": [o.x, o.y, o.z], "axis": [Double(axis.x), Double(axis.y), Double(axis.z)],
                "damping": 0.01, "friction": 0.02,
            ]
            let lim = j["limits"] as? [String: Any] ?? [:]
            if let lo = lim["lower"] as? Double, let hi = lim["upper"] as? Double {
                joint["limits"] = ["lower_deg": lo * 180 / .pi, "upper_deg": hi * 180 / .pi]
            }
            joints.append(joint)
            jointNames.append(name)
        }
        for f in frames {
            guard let name = f["name"] as? String, let link = f["link"] as? Int, link < links.count, let m = framePoses[name] else { continue }
            tips[links[link], default: []].append(pos(m))
        }
        let components: [[String: Any]] = links.enumerated().map { i, id in
            let o = i < linkPoses.count ? pos(linkPoses[i]) : .zero
            let pts = [o] + (tips[id] ?? [])
            let r = id == "palm" ? 14.0 : 7.0
            let lo = pts.reduce(SIMD3(repeating: Double.infinity)) { simd_min($0, $1) } - r
            let hi = pts.reduce(SIMD3(repeating: -Double.infinity)) { simd_max($0, $1) } + r
            return ["id": id, "name": id.replacingOccurrences(of: "_", with: " ").capitalized,
                    "proxy": ["min_mm": [lo.x, lo.y, lo.z], "max_mm": [hi.x, hi.y, hi.z], "mass_kg": id == "forearm" ? 0.3 : (id == "palm" ? 0.12 : 0.012)]]
        }
        let doc: [String: Any] = [
            "format": "viaform-asm", "version": 1, "name": "hand", "ground": links.first ?? "forearm",
            "components": components, "joints": joints,
            "poses": [["id": "home", "q_deg": [String: Double]()]],
        ]
        return Built(json: AssembleEngine.encode(doc), links: links, joints: jointNames, tips: tips,
                     frames: frames.compactMap { $0["name"] as? String })
    }
}

/// Puts the grasp object in the hand and one target per fingertip on its surface.
enum HandGrasp {
    static let fingers: [(frame: String, title: String)] = [
        ("thumb_tip", "Thumb"), ("index_tip", "Index"), ("middle_tip", "Middle"), ("ring_tip", "Ring"), ("pinky_tip", "Little"),
    ]

    static func place(_ m: AssembleModel) throws {
        let e = m.engine
        let info = try e.kinCall("model.info")
        let jinfo = info["joints"] as? [[String: Any]] ?? []
        let links = info["links"] as? [String] ?? []
        // A half-closed hand: every flexion joint at the middle of its range.
        var curled: [String: Double] = [:]
        for j in jinfo {
            guard let name = j["name"] as? String else { continue }
            let lim = j["limits"] as? [String: Any] ?? [:]
            let lo = lim["lower"] as? Double ?? 0, hi = lim["upper"] as? Double ?? 0
            let flex = !name.hasSuffix("_abd") && !name.hasPrefix("wrist")
            curled[name] = flex ? (lo + (hi - lo) * 0.62) * 180 / .pi : 0
        }
        let home = try frames(e, q: Array(repeating: 0, count: m.kinJoints.count))
        let qc = m.kinJoints.map { (curled[$0] ?? 0) * .pi / 180 }
        let bent = try frames(e, q: qc)
        let palmIndex = links.firstIndex(of: "palm") ?? 2
        let palm = home.links[min(palmIndex, home.links.count - 1)]
        let mid = home.frames["middle_tip"] ?? palm
        let span = simd_length(mid - palm)
        let df = simd_normalize(mid - palm)
        let c = fingers.compactMap { bent.frames[$0.frame] }.reduce(SIMD3<Double>.zero, +) / Double(max(1, fingers.count))
        var n = (c - palm) - simd_dot(c - palm, df) * df
        n = simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3(0, -1, 0)
        let idx = links.firstIndex(of: "index_abd_link").map { home.links[$0] } ?? palm + SIMD3(20, 0, 0)
        let pky = links.firstIndex(of: "pinky_abd_link").map { home.links[$0] } ?? palm - SIMD3(20, 0, 0)
        var a = idx - pky
        a -= simd_dot(a, df) * df + simd_dot(a, n) * n
        a = simd_length(a) > 1e-6 ? simd_normalize(a) : simd_normalize(simd_cross(df, n))
        let r = m.grasp.size.x / 2
        let center = palm + df * (0.42 * span) + n * (r + 8)
        var out: [AssembleModel.GraspFinger] = []
        for (i, f) in fingers.enumerated() {
            guard let t = bent.frames[f.frame] else { continue }
            let (p, nrm) = surface(of: m.grasp, center: center, axis: a, near: t)
            out.append(.init(frame: f.frame, title: f.title, priority: i + 1, point: p, normal: nrm))
        }
        m.setGraspPlacement(center: center, axis: a, fingers: out)
        try m.drive(Dictionary(uniqueKeysWithValues: m.kinJoints.map { ($0, curled[$0] ?? 0) }))
    }

    /// The closest point of the object's surface to `p`, and the outward normal there.
    static func surface(of g: AssembleModel.GraspState, center: SIMD3<Double>, axis a: SIMD3<Double>, near p: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let v = p - center
        switch g.shape {
        case "sphere":
            let n = simd_length(v) > 1e-9 ? simd_normalize(v) : SIMD3(0, 0, 1)
            return (center + n * g.size.x / 2, n)
        case "box":
            let h = g.size / 2
            var q = simd_clamp(v, -h, h)
            let d = h - simd_abs(q)
            var n = SIMD3<Double>(0, 0, 0)
            if d.x <= d.y && d.x <= d.z { q.x = v.x >= 0 ? h.x : -h.x; n.x = v.x >= 0 ? 1 : -1 }
            else if d.y <= d.z { q.y = v.y >= 0 ? h.y : -h.y; n.y = v.y >= 0 ? 1 : -1 }
            else { q.z = v.z >= 0 ? h.z : -h.z; n.z = v.z >= 0 ? 1 : -1 }
            return (center + q, n)
        default:
            let along = max(-g.size.y / 2, min(g.size.y / 2, simd_dot(v, a)))
            var radial = v - simd_dot(v, a) * a
            radial = simd_length(radial) > 1e-9 ? simd_normalize(radial) : simd_normalize(simd_cross(a, SIMD3(0, 0, 1)))
            return (center + along * a + radial * g.size.x / 2, radial)
        }
    }

    private static func frames(_ e: AssembleEngine, q: [Double]) throws -> (links: [SIMD3<Double>], frames: [String: SIMD3<Double>]) {
        let r = try e.kinCall("fk", ["q": q])
        func p(_ d: [String: Any]) -> SIMD3<Double> {
            let x = d["xyz"] as? [Double] ?? [0, 0, 0]
            return SIMD3(x[0], x[1], x[2]) * 1000
        }
        let links = (r["links"] as? [[String: Any]] ?? []).map(p)
        let frames = (r["frames"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? [String: Any]).map(p) }
        return (links, frames)
    }
}
