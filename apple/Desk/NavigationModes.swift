#if os(macOS)
import simd
import SwiftUI

/// The navigation bar's modes (Fusion's Orbit, Pan, Zoom, Zoom Window and Look At): while one
/// is on, a left drag on the canvas drives it instead of selecting, until Esc or a click on its
/// button again.
enum NavMode: String, CaseIterable, Identifiable {
    case orbit, pan, zoom, zoomWindow, lookAt
    var id: String { rawValue }

    var hint: String {
        switch self {
        case .orbit: String(localized: "Orbit: drag to turn the view. Esc to stop.")
        case .pan: String(localized: "Pan: drag to move the view. Esc to stop.")
        case .zoom: String(localized: "Zoom: drag up to zoom in, down to zoom out. Esc to stop.")
        case .zoomWindow: String(localized: "Zoom Window: drag a box around what to fill the view with.")
        case .lookAt: String(localized: "Look At: click a flat face or a plane to look straight at it.")
        }
    }

    /// Zoom Window and Look At end after one use; the others stay on.
    var oneShot: Bool { self == .zoomWindow || self == .lookAt }
}

/// Camera moves the navigation bar and the view cube run through the engine, so the camera
/// the viewport shows is the one the engine answers with.
enum NavCamera {
    /// Look At the planar face under `p`: the face becomes the engine's selection and
    /// `view.normal_to` turns the camera square to it, keeping scale and projection.
    @discardableResult
    static func lookAt(_ model: DesignModel, at p: CGPoint, size: CGSize) -> Bool {
        guard case let .face(mi, _, pt, n)? = ScenePicker.pickFace(model.scene, camera: model.camera, at: p, size: size),
              model.scene.meshes.indices.contains(mi) else { return false }
        return lookAt(model, body: model.scene.meshes[mi].body, point: pt, normal: n)
    }

    @discardableResult
    static func lookAt(_ model: DesignModel, body: String, point: SIMD3<Double>, normal: SIMD3<Double>) -> Bool {
        let item: [String: Any] = ["type": "face", "body": body, "point": [point.x, point.y, point.z]]
        defer { _ = try? model.engine.execute("select.clear") }
        if (try? model.engine.execute("select.set", ["items": [item]])) != nil,
           let cam = CameraReply.camera(try? model.engine.execute("view.normal_to", ["camera": model.camera.dictionary])) {
            apply(model, cam)
            return true
        }
        // The engine did not take the face (a curved one): look along its normal at the point.
        model.look(along: normal)
        return true
    }

    static func apply(_ model: DesignModel, _ cam: OrbitCamera) {
        var c = cam
        c.up = model.camera.up
        model.camera = c
        model.cameraChanged(final: true)
    }

    /// Zoom Window: the box's centre becomes the target, on the plane through the old target
    /// facing the view, and the box fills the view.
    static func zoomWindow(_ model: DesignModel, _ box: CGRect, size: CGSize) {
        guard box.width > 4, box.height > 4, size.width > 0, size.height > 0 else { return }
        var cam = model.camera
        let (o, d) = cam.ray(at: CGPoint(x: box.midX, y: box.midY), size: size)
        let b = cam.basis.back
        let denom = simd_dot(d, b)
        if abs(denom) > 1e-9 {
            cam.target = o + d * (simd_dot(cam.target - o, b) / denom)
        }
        let ratio = Double(max(box.width / size.width, box.height / size.height))
        cam.distance = min(max(cam.distance * ratio, 0.05), 1e6)
        model.camera = cam
        model.cameraChanged(final: true)
    }
}

/// Over the viewport while a navigation mode is on: a left drag orbits, pans or zooms, draws
/// the Zoom Window box, or (a click) picks the face Look At turns to. A hint says what to do.
struct NavModeOverlay: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @Binding var mode: NavMode?
    @State private var last: CGPoint?
    @State private var box: CGRect?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drag(geo.size))
                if let box {
                    Rectangle()
                        .fill(theme.accent.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .allowsHitTesting(false)
                }
                if let mode {
                    HStack(spacing: VFSpace.s) {
                        Text(mode.hint).font(VFFont.small).foregroundStyle(theme.ink)
                        VFIconButton("xmark", label: String(localized: "Stop"), size: 9) { self.mode = nil }
                    }
                    .padding(.leading, VFSpace.l)
                    .padding(.trailing, VFSpace.xs)
                    .vfSurface(.control, radius: VFRadius.touchCapsule)
                    .padding(.top, VFSpace.overlayInset)
                }
                // Esc leaves the mode.
                Button("") { mode = nil }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(mode?.hint ?? ""))
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard let mode else { return }
                let from = last ?? g.startLocation
                let dx = Double(g.location.x - from.x), dy = Double(g.location.y - from.y)
                last = g.location
                switch mode {
                case .orbit:
                    model.camera.orbit(dx: dx, dy: dy)
                    model.cameraChanged()
                case .pan:
                    model.camera.pan(dx: dx, dy: dy, viewHeight: Double(size.height))
                    model.cameraChanged()
                case .zoom:
                    model.camera.zoom(exp(-dy * 0.01))
                    model.cameraChanged()
                case .zoomWindow:
                    box = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                 width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                case .lookAt:
                    break
                }
            }
            .onEnded { g in
                defer { last = nil; box = nil }
                guard let current = mode else { return }
                switch current {
                case .zoomWindow:
                    if let box { NavCamera.zoomWindow(model, box, size: size) }
                case .lookAt:
                    if hypot(g.translation.width, g.translation.height) < 4 {
                        if !NavCamera.lookAt(model, at: g.location, size: size) {
                            model.flash(String(localized: "Look At needs a face: click on the model."))
                            return
                        }
                    } else { return }
                default:
                    model.cameraChanged(final: true)
                }
                if current.oneShot { mode = nil }
            }
    }
}
#endif
