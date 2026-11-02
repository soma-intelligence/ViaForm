import CoreGraphics
import Foundation
import simd

/// The engine's camera (`solidcraft_render::Camera`), with the same math, so what Swift draws and
/// what the engine lays out (grid, sketch guides) agree. Z is up; yaw 0 looks along +Y.
struct OrbitCamera: Codable, Equatable {
    var target: SIMD3<Double> = .zero
    var yaw: Double = -.pi / 4
    var pitch: Double = 0.6154797086703874
    var roll: Double = 0
    var distance: Double = 200
    /// Vertical field of view in radians; 0 is orthographic.
    var fov: Double = 0
    var up: String = "z"

    enum CodingKeys: String, CodingKey { case target, yaw, pitch, roll, distance, fov, up }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode([Double].self, forKey: .target)
        target = t.count == 3 ? SIMD3(t[0], t[1], t[2]) : .zero
        yaw = try c.decode(Double.self, forKey: .yaw)
        pitch = try c.decode(Double.self, forKey: .pitch)
        roll = try c.decodeIfPresent(Double.self, forKey: .roll) ?? 0
        distance = try c.decode(Double.self, forKey: .distance)
        fov = try c.decodeIfPresent(Double.self, forKey: .fov) ?? 0
        up = try c.decodeIfPresent(String.self, forKey: .up) ?? "z"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([target.x, target.y, target.z], forKey: .target)
        try c.encode(yaw, forKey: .yaw)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(roll, forKey: .roll)
        try c.encode(distance, forKey: .distance)
        try c.encode(fov, forKey: .fov)
        try c.encode(up, forKey: .up)
    }

    var dictionary: [String: Any] {
        ["target": [target.x, target.y, target.z], "yaw": yaw, "pitch": pitch, "roll": roll, "distance": distance, "fov": fov, "up": up]
    }

    /// Direction from the target toward the eye.
    var back: SIMD3<Double> {
        let (cp, sp) = (cos(pitch), sin(pitch))
        return simd_normalize(SIMD3(-sin(yaw) * cp, -cos(yaw) * cp, sp))
    }

    var eye: SIMD3<Double> { target + back * distance }

    /// Right, up, back (orthonormal).
    var basis: (right: SIMD3<Double>, up: SIMD3<Double>, back: SIMD3<Double>) {
        let b = back
        let right = SIMD3(cos(yaw), -sin(yaw), 0)
        var u = simd_cross(b, right)
        u = simd_length(u) > 1e-12 ? simd_normalize(u) : SIMD3(0, 0, 1)
        let (s, c) = (sin(roll), cos(roll))
        return (right * c + u * s, u * c - right * s, b)
    }

    var halfHeight: Double { fov > 0 ? distance * tan(fov / 2) : distance * 0.4 }

    func clip(radius: Double) -> (near: Double, far: Double) {
        let r = max(radius, 1e-3)
        if fov > 0 { return (max(max(distance - r * 2, distance * 1e-3), 1e-3), distance + r * 2) }
        return (distance - r * 4 - 1, distance + r * 4 + 1)
    }

    func viewMatrix() -> simd_float4x4 {
        let (r, u, b) = basis
        let e = eye
        return simd_float4x4(columns: (
            SIMD4(Float(r.x), Float(u.x), Float(b.x), 0),
            SIMD4(Float(r.y), Float(u.y), Float(b.y), 0),
            SIMD4(Float(r.z), Float(u.z), Float(b.z), 0),
            SIMD4(Float(-simd_dot(r, e)), Float(-simd_dot(u, e)), Float(-simd_dot(b, e)), 1)
        ))
    }

    /// Metal clip space (depth 0…1).
    func projectionMatrix(aspect: Double, radius: Double) -> simd_float4x4 {
        let (n, f) = clip(radius: radius)
        if fov > 0 {
            let y = 1 / tan(fov / 2), x = y / aspect
            let z = f / (n - f)
            return simd_float4x4(columns: (
                SIMD4(Float(x), 0, 0, 0), SIMD4(0, Float(y), 0, 0),
                SIMD4(0, 0, Float(z), -1), SIMD4(0, 0, Float(z * n), 0)
            ))
        }
        let h = halfHeight, w = h * aspect
        return simd_float4x4(columns: (
            SIMD4(Float(1 / w), 0, 0, 0), SIMD4(0, Float(1 / h), 0, 0),
            SIMD4(0, 0, Float(1 / (n - f)), 0), SIMD4(0, 0, Float(n / (n - f)), 1)
        ))
    }

    /// The ray through a point of a `size` view (origin top-left, points).
    func ray(at p: CGPoint, size: CGSize) -> (origin: SIMD3<Double>, dir: SIMD3<Double>) {
        let (r, u, b) = basis
        let aspect = Double(size.width / max(size.height, 1))
        let nx = (Double(p.x) / Double(size.width)) * 2 - 1
        let ny = 1 - (Double(p.y) / Double(size.height)) * 2
        let h = halfHeight
        if fov > 0 {
            let dir = simd_normalize(-b + r * (nx * h / distance * aspect) + u * (ny * h / distance))
            return (eye, dir)
        }
        let origin = eye + r * (nx * h * aspect) + u * (ny * h)
        return (origin, -b)
    }

    /// A world point on screen (points, origin top-left), and its depth along the view.
    func project(_ w: SIMD3<Double>, size: CGSize) -> CGPoint {
        let (r, u, b) = basis
        let d = w - eye
        let aspect = Double(size.width / max(size.height, 1))
        var x = simd_dot(d, r), y = simd_dot(d, u)
        let z = -simd_dot(d, b)
        let h = halfHeight
        if fov > 0 {
            let s = distance / max(z, 1e-6)
            x *= s; y *= s
        }
        return CGPoint(x: (x / (h * aspect) + 1) / 2 * size.width, y: (1 - y / h) / 2 * size.height)
    }

    // MARK: Navigation

    mutating func orbit(dx: Double, dy: Double) {
        yaw += dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -.pi / 2), .pi / 2)
    }

    mutating func pan(dx: Double, dy: Double, viewHeight: Double) {
        let (r, u, _) = basis
        let k = halfHeight * 2 / max(viewHeight, 1)
        target += (-r * dx + u * dy) * k
    }

    /// Zooms by `factor` (>1 closer) toward a world point under the cursor.
    mutating func zoom(_ factor: Double, toward point: SIMD3<Double>? = nil) {
        let f = min(max(factor, 0.05), 20)
        let old = distance
        distance = min(max(distance / f, 0.05), 1e6)
        if let p = point {
            target += (p - target) * (1 - distance / old)
        }
    }

    mutating func standard(_ v: StandardView) {
        (yaw, pitch) = v.angles
        roll = 0
    }

    mutating func fit(min lo: SIMD3<Double>, max hi: SIMD3<Double>, aspect: Double) {
        target = (lo + hi) / 2
        let r = max(simd_length(hi - lo) / 2, 1)
        distance = fov > 0 ? r / sin(fov / 2) * 1.1 : r / 0.4 * 1.15
        if aspect > 0, aspect < 1 { distance /= aspect }
    }
}

enum StandardView: String, CaseIterable {
    case front, back, left, right, top, bottom, iso

    var angles: (Double, Double) {
        switch self {
        case .front: (0, 0)
        case .back: (.pi, 0)
        case .right: (-.pi / 2, 0)
        case .left: (.pi / 2, 0)
        case .top: (0, .pi / 2)
        case .bottom: (0, -.pi / 2)
        case .iso: (-.pi / 4, 0.6154797086703874)
        }
    }
}
