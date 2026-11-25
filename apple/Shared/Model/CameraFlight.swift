import Foundation
import simd

// Camera flights: the view cube, its arrows, its Home view and the iPad view menu turn the camera
// to the new view over a short eased move instead of jumping, as in Shapr3D. Yaw and roll take
// the short way round. A drag, a scroll or any other camera move during a flight stops it where
// it is. Reduce Motion and the self tests get the jump. `setView(_:)` and `look(along:)` stay
// instant for every other caller.

@MainActor
enum CameraFlight {
    /// A quarter turn or more takes this long (seconds); smaller turns are quicker. Longer than a
    /// UI transition (VFMotion.ceiling): the eye must follow the model turning.
    static let duration: Double = 0.38

    private static var flights: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Jumps instead of flying: tests read the camera right after asking for a view.
    static var jumps: Bool {
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("selftest") }) { return true }
        return VFMotion.reduced
    }

    static func fly(_ model: DesignModel, to target: OrbitCamera) {
        let key = ObjectIdentifier(model)
        flights[key]?.cancel()
        flights[key] = nil
        let start = model.camera
        var end = target
        end.yaw = start.yaw + remainder(end.yaw - start.yaw, 2 * .pi)
        end.roll = start.roll + remainder(end.roll - start.roll, 2 * .pi)
        let turn = max(abs(end.yaw - start.yaw), abs(end.pitch - start.pitch), abs(end.roll - start.roll))
        guard !jumps, start != end else {
            model.camera = target
            model.cameraChanged(final: true)
            return
        }
        let seconds = duration * min(1, max(0.45, turn / (.pi / 2)))
        flights[key] = Task { @MainActor [weak model] in
            let clock = ContinuousClock()
            let began = clock.now
            var last = start
            while !Task.isCancelled, let model {
                // Someone else moved the camera (a drag, a pinch): leave it to them.
                let d = began.duration(to: clock.now).components
                let t = min(1, (Double(d.seconds) + Double(d.attoseconds) * 1e-18) / seconds)
                last = t >= 1 ? target : mix(start, end, ease(t))
                model.camera = last
                model.cameraChanged(final: t >= 1)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    /// Ease in and out (cubic): soft at both ends.
    static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The camera a fraction `t` of the way from `a` to `b` (angles already unwrapped).
    static func mix(_ a: OrbitCamera, _ b: OrbitCamera, _ t: Double) -> OrbitCamera {
        var c = b
        c.target = a.target + (b.target - a.target) * t
        c.yaw = a.yaw + (b.yaw - a.yaw) * t
        c.pitch = a.pitch + (b.pitch - a.pitch) * t
        c.roll = a.roll + (b.roll - a.roll) * t
        c.distance = a.distance + (b.distance - a.distance) * t
        // Orthographic and perspective do not blend: the switch happens at the end.
        c.fov = (a.fov == 0) != (b.fov == 0) ? a.fov : a.fov + (b.fov - a.fov) * t
        c.up = a.up
        return c
    }
}

@MainActor
extension DesignModel {
    /// Flies the camera to a standard view.
    func flyTo(_ v: StandardView) {
        var c = camera
        c.standard(v)
        CameraFlight.fly(self, to: c)
    }

    /// Flies the camera to look along `normal` (the same end as `look(along:)`).
    func fly(along normal: SIMD3<Double>) {
        let n = simd_normalize(normal)
        var c = camera
        c.pitch = asin(min(max(n.z, -1), 1))
        c.yaw = abs(n.z) > 0.9999 ? 0 : atan2(-n.x, -n.y)
        c.roll = 0
        CameraFlight.fly(self, to: c)
    }

    /// Flies the camera to any camera.
    func fly(to c: OrbitCamera) {
        CameraFlight.fly(self, to: c)
    }
}
