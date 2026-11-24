import Foundation
import simd

/// One sketch as the canvas draws it: its plane, points (for dragging), curves as polylines,
/// closed profiles (for extrude picking) and dimensions with where their text goes. Read from
/// `sketch.inspect` and `sketch.glyphs`, all in sketch coordinates (millimetres, radians for
/// angles as the engine stores them).
struct SketchInfo: Equatable {
    struct Point: Equatable, Identifiable {
        var id: String
        var at: SIMD2<Double>
        var fixed: Bool
    }

    struct Curve: Equatable, Identifiable {
        var id: String
        var kind: String
        var polyline: [SIMD2<Double>]
        var construction: Bool
    }

    struct Profile: Equatable, Identifiable {
        var index: Int
        var area: Double
        var centroid: SIMD2<Double>
        /// The outer loop, chained from its curves.
        var outline: [SIMD2<Double>]
        var holes: [[SIMD2<Double>]]
        var id: Int { index }

        /// Inside the outer loop and outside every hole.
        func contains(_ q: SIMD2<Double>) -> Bool {
            SketchInfo.inside(q, outline) && !holes.contains { SketchInfo.inside(q, $0) }
        }
    }

    struct Dimension: Equatable, Identifiable {
        var id: String
        /// "LinearDimension", "RadialDimension", "DiameterDimension", "AngularDimension"...
        var name: String
        var value: Double
        /// The parameter that drives it; editing the text changes this parameter.
        var param: String?
        var expression: String?
        var at: SIMD2<Double>
        var driven: Bool
        var failing: Bool

        var isAngle: Bool { name.hasPrefix("Angular") }

        /// The text drawn on the canvas, in the reader's display units (P2-23): "40", "R 6",
        /// "D 8", "30 deg" (lengths carry no unit; "1.575" with inches).
        var text: String {
            switch name {
            case "RadialDimension": "R " + Self.shown(value, .length)
            case "DiameterDimension", "LinearDiameterDimension": "D " + Self.shown(value, .length)
            case _ where isAngle: Self.shown(value * 180 / .pi, .angle) + " " + Self.angleWord
            default: Self.shown(value, .length)
            }
        }

        /// The value as it is typed back: the parameter's expression when it has one, else the
        /// value in the display unit with its unit ("40 mm", "1.575 in", "30 deg").
        var editText: String {
            if let e = expression, !e.isEmpty { return e }
            return isAngle ? Self.shown(value * 180 / .pi, .angle) + " " + Self.angleWord
                : Self.shown(value, .length) + " " + VFFormat.symbol(.length)
        }

        /// "deg" or "rad": typed back, so a word rather than the degree sign.
        static var angleWord: String { UnitSettings.current.angle == .deg ? "deg" : "rad" }

        /// A base value (mm or degrees) in the display unit, at 0.01 mm or 0.01 degree and the
        /// matching precision in larger units (0.001 in, 0.0001 rad), trailing zeros dropped.
        static func shown(_ v: Double, _ unit: VFUnit) -> String {
            let f = UnitSettings.current.inputFactor(for: unit)
            let digits = 2 + max(0, Int(log10(f).rounded()))
            return number(v / f, digits: digits)
        }

        static func number(_ v: Double, digits: Int = 2) -> String {
            let p = pow(10.0, Double(digits))
            let r = (v * p).rounded() / p
            guard r != r.rounded() else { return String(format: "%.0f", r) }
            var s = String(format: "%.\(digits)f", r)
            while s.hasSuffix("0") { s.removeLast() }
            return s
        }
    }

    var id: Int
    var plane: SketchPlane
    var points: [Point] = []
    var curves: [Curve] = []
    var profiles: [Profile] = []
    var dimensions: [Dimension] = []

    /// The sketch `id` (the open one when nil), or nil when the engine has none to show.
    static func load(_ engine: CADEngine, sketch id: Int?, plane open: SketchPlane?) -> SketchInfo? {
        var params: [String: Any] = [:]
        if let id { params["sketch"] = id }
        guard let r = (try? engine.execute("sketch.inspect", params)) as? [String: Any],
              let sid = r["id"] as? Int else { return nil }
        let rawPoints = r["points"] as? [[String: Any]] ?? []
        let points = rawPoints.compactMap { p -> Point? in
            guard let pid = p["id"] as? String, let at = vec2(p["at"]) else { return nil }
            return Point(id: pid, at: at, fixed: p["fixed"] as? Bool ?? false)
        }
        guard let plane = open ?? Self.plane(r["plane"]) ?? Self.plane(fromPoints: rawPoints) else { return nil }
        var info = SketchInfo(id: sid, plane: plane, points: points)
        info.curves = (r["curves"] as? [[String: Any]] ?? []).compactMap(curve)
        let byID = Dictionary(info.curves.map { ($0.id, $0.polyline) }, uniquingKeysWith: { a, _ in a })
        info.profiles = (r["profiles"] as? [[String: Any]] ?? []).compactMap { p in
            guard let index = p["index"] as? Int else { return nil }
            let outer = chain((p["curves"] as? [String] ?? []).compactMap { byID[$0] })
            let holes = (p["holes"] as? [[String]] ?? []).map { chain($0.compactMap { byID[$0] }) }
            return Profile(index: index, area: p["area_mm2"] as? Double ?? 0, centroid: vec2(p["centroid_sketch"]) ?? outer.first ?? .zero,
                           outline: outer, holes: holes)
        }
        // The expressions of the dimensions, by constraint id.
        var expressions: [String: String] = [:]
        for c in r["constraints"] as? [[String: Any]] ?? [] {
            if let cid = idText(c["id"]), let e = c["expression"] as? String { expressions[cid] = e }
        }
        let g = (try? engine.execute("sketch.glyphs", ["sketch": sid])) as? [String: Any]
        info.dimensions = (g?["glyphs"] as? [[String: Any]] ?? []).compactMap { d in
            guard d["dimension"] as? Bool == true, let cid = idText(d["id"]), let at = vec2(d["at"]),
                  let v = d["value"] as? Double else { return nil }
            return Dimension(id: cid, name: d["name"] as? String ?? "LinearDimension", value: v, param: d["param"] as? String,
                             expression: expressions[cid], at: at, driven: d["driven"] as? Bool ?? false, failing: d["failing"] as? Bool ?? false)
        }
        return info
    }

    // MARK: Geometry

    private static func idText(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? Int { return String(n) }
        return nil
    }

    static func vec2(_ v: Any?) -> SIMD2<Double>? {
        if let a = v as? [Double], a.count >= 2 { return SIMD2(a[0], a[1]) }
        if let d = v as? [String: Any], let x = d["x"] as? Double, let y = d["y"] as? Double { return SIMD2(x, y) }
        return nil
    }

    static func vec3(_ v: Any?) -> SIMD3<Double>? {
        if let a = v as? [Double], a.count >= 3 { return SIMD3(a[0], a[1], a[2]) }
        if let d = v as? [String: Any], let x = d["x"] as? Double, let y = d["y"] as? Double, let z = d["z"] as? Double { return SIMD3(x, y, z) }
        return nil
    }

    /// The plane as the engine serialises it (origin and the two in-plane axes).
    static func plane(_ v: Any?) -> SketchPlane? {
        guard let d = v as? [String: Any], let o = vec3(d["origin"]) else { return nil }
        guard let x = vec3(d["x"] ?? d["x_dir"] ?? d["u"]), let y = vec3(d["y"] ?? d["y_dir"] ?? d["v"]) else { return nil }
        return SketchPlane(origin: o, x: x, y: y)
    }

    /// The plane solved from points that carry both their sketch and world positions.
    static func plane(fromPoints raw: [[String: Any]]) -> SketchPlane? {
        let pairs = raw.compactMap { p -> (SIMD2<Double>, SIMD3<Double>)? in
            guard let a = vec2(p["at"]), let w = vec3(p["world"]) else { return nil }
            return (a, w)
        }
        guard let first = pairs.first else { return nil }
        for i in 1..<max(pairs.count, 1) {
            for j in (i + 1)..<max(pairs.count, i + 1) {
                let a1 = pairs[i].0 - first.0, a2 = pairs[j].0 - first.0
                let det = a1.x * a2.y - a1.y * a2.x
                guard abs(det) > 1e-6 else { continue }
                let w1 = pairs[i].1 - first.1, w2 = pairs[j].1 - first.1
                // [w1 w2] = [x y] * [[a1.x a2.x] [a1.y a2.y]]: invert the 2x2.
                let x = (w1 * a2.y - w2 * a1.y) / det
                let y = (w2 * a1.x - w1 * a2.x) / det
                let origin = first.1 - x * first.0.x - y * first.0.y
                return SketchPlane(origin: origin, x: x, y: y)
            }
        }
        return nil
    }

    private static func curve(_ c: [String: Any]) -> Curve? {
        guard let id = c["id"] as? String, let kind = c["type"] as? String else { return nil }
        var poly: [SIMD2<Double>] = []
        switch kind {
        case "line":
            if let a = vec2(c["start_at"]), let b = vec2(c["end_at"]) { poly = [a, b] }
        case "circle":
            if let o = vec2(c["center_at"]), let r = c["radius"] as? Double { poly = arc(o, r, 0, 2 * .pi) }
        case "arc":
            if let o = vec2(c["center_at"]), let a = vec2(c["start_at"]), let b = vec2(c["end_at"]) {
                let r = simd_distance(o, a)
                let a0 = atan2(a.y - o.y, a.x - o.x)
                var sweep = atan2(b.y - o.y, b.x - o.x) - a0
                while sweep <= 0 { sweep += 2 * .pi }
                poly = arc(o, r, a0, sweep)
                poly[0] = a
                poly[poly.count - 1] = b
            }
        case "ellipse":
            if let o = vec2(c["center_at"]), let m = vec2(c["major_at"]), let r = c["minor_radius"] as? Double {
                let u = m - o, R = simd_length(u)
                if R > 0 {
                    let ux = u / R, uy = SIMD2(-ux.y, ux.x)
                    poly = (0...64).map { i in
                        let t = Double(i) / 64 * 2 * .pi
                        return o + ux * (R * cos(t)) + uy * (r * sin(t))
                    }
                }
            }
        case "conic":
            if let a = vec2(c["start_at"]), let b = vec2(c["end_at"]), let p = vec2(c["apex_at"]) {
                poly = (0...24).map { i in
                    let t = Double(i) / 24
                    return a * ((1 - t) * (1 - t)) + p * (2 * t * (1 - t)) + b * (t * t)
                }
            }
        default:
            poly = (c["points_at"] as? [Any] ?? []).compactMap(vec2)
        }
        guard poly.count >= 2 else { return nil }
        return Curve(id: id, kind: kind, polyline: poly, construction: c["construction"] as? Bool ?? false)
    }

    private static func arc(_ o: SIMD2<Double>, _ r: Double, _ a0: Double, _ sweep: Double) -> [SIMD2<Double>] {
        let n = max(8, Int(abs(sweep) / (2 * .pi) * 72))
        return (0...n).map { i in
            let a = a0 + sweep * Double(i) / Double(n)
            return o + SIMD2(cos(a), sin(a)) * r
        }
    }

    /// The curves of a loop joined end to end into one closed polyline (each one reversed where
    /// it runs the other way).
    static func chain(_ parts: [[SIMD2<Double>]]) -> [SIMD2<Double>] {
        guard var out = parts.first else { return [] }
        var rest = Array(parts.dropFirst())
        let tol = 1e-4 * max(1, simd_length(out[0]))
        while !rest.isEmpty {
            let end = out[out.count - 1]
            var best = 0, flip = false, gap = Double.infinity
            for (i, p) in rest.enumerated() {
                let d0 = simd_distance(p[0], end), d1 = simd_distance(p[p.count - 1], end)
                if d0 < gap { gap = d0; best = i; flip = false }
                if d1 < gap { gap = d1; best = i; flip = true }
            }
            let next = flip ? Array(rest[best].reversed()) : rest[best]
            out += gap < tol * 100 ? Array(next.dropFirst()) : next
            rest.remove(at: best)
        }
        return out
    }

    /// Even-odd point in polygon.
    static func inside(_ q: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        guard poly.count >= 3 else { return false }
        var c = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    /// The innermost profile under `q` (the smallest that contains it).
    func profile(at q: SIMD2<Double>) -> Profile? {
        profiles.filter { $0.contains(q) }.min { $0.area < $1.area }
    }

    /// The point nearest `q` within `radius` (sketch units).
    func point(near q: SIMD2<Double>, radius: Double) -> Point? {
        points.filter { simd_distance($0.at, q) <= radius }.min { simd_distance($0.at, q) < simd_distance($1.at, q) }
    }
}
