import SceneKit
import SwiftUI

/// The Generate workspace's 3D view. A drag that starts on a region (in the Setup display)
/// moves it across the plane facing the camera; any other drag orbits. A click or tap picks a
/// region, or clears the pick on empty space. Mac: right or middle drag (or Shift) pans, the
/// wheel and pinch zoom. Touch: one finger orbits or moves, two pan, pinch zooms.
@MainActor
struct GenerateViewport {
    let model: GenerateModel
    let scene: GenerateScene

    func makeCoordinator() -> Coordinator { Coordinator(model: model, scene: scene) }

    @MainActor
    final class Coordinator: NSObject {
        let model: GenerateModel
        let scene: GenerateScene
        private var moving: (start: Vec3, origin: Vec3, normal: Vec3)?
        private var travelled: CGFloat = 0

        init(model: GenerateModel, scene: GenerateScene) {
            self.model = model
            self.scene = scene
        }

        private func region(at p: CGPoint, in view: SCNView) -> GenerateModel.RegionKey? {
            let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
            return hits.lazy.compactMap { GenerateScene.key(of: $0.node) }.first
        }

        /// A press at `p`: on a region in the Setup display it starts a move, else an orbit.
        func down(_ p: CGPoint, in view: SCNView) {
            travelled = 0
            moving = nil
            guard model.display == .setup, !model.running, let key = region(at: p, in: view), let r = model.region(key) else { return }
            let origin = r.middle, normal = scene.dragNormal
            guard let start = scene.hit(view, p, plane: origin, normal: normal) else { return }
            model.beginMove(key)
            moving = (start, origin, normal)
        }

        func drag(_ p: CGPoint, by d: CGSize, in view: SCNView) {
            travelled += abs(d.width) + abs(d.height)
            if let m = moving {
                if let h = scene.hit(view, p, plane: m.origin, normal: m.normal) { model.move(by: h - m.start) }
            } else {
                scene.orbit(dx: d.width, dy: d.height)
            }
        }

        func up(_ p: CGPoint, in view: SCNView) {
            if moving != nil {
                model.endMove()
                moving = nil
            }
            if travelled < 4 { click(p, in: view) }
        }

        func click(_ p: CGPoint, in view: SCNView) {
            model.select(region(at: p, in: view))
        }

        func pan(by d: CGSize, in view: SCNView) {
            scene.pan(dx: d.width, dy: d.height, height: view.bounds.height)
        }
    }
}

#if os(macOS)
extension GenerateViewport: NSViewRepresentable {
    func makeNSView(context: Context) -> GenerateSCNView {
        let v = GenerateSCNView()
        v.scene = scene.scene
        v.pointOfView = scene.cameraNode
        v.antialiasingMode = .multisampling4X
        v.coordinator = context.coordinator
        v.preferredFramesPerSecond = 120
        return v
    }

    func updateNSView(_ v: GenerateSCNView, context: Context) {}
}

final class GenerateSCNView: SCNView {
    var coordinator: GenerateViewport.Coordinator?
    private var last: CGPoint = .zero
    private var panning = false

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        coordinator?.scene.resized(width: newSize.width, height: newSize.height)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        last = point(e)
        panning = e.modifierFlags.contains(.shift)
        if !panning { coordinator?.down(last, in: self) }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        // View y grows upward on the Mac; drags read as on screen.
        let d = CGSize(width: p.x - last.x, height: p.y - last.y)
        last = p
        if panning { coordinator?.pan(by: d, in: self) } else { coordinator?.drag(p, by: CGSize(width: d.width, height: -d.height), in: self) }
    }

    override func mouseUp(with e: NSEvent) {
        if !panning { coordinator?.up(point(e), in: self) }
        panning = false
    }

    override func rightMouseDown(with e: NSEvent) { last = point(e) }
    override func otherMouseDown(with e: NSEvent) { last = point(e) }

    override func rightMouseDragged(with e: NSEvent) { panDrag(e) }
    override func otherMouseDragged(with e: NSEvent) { panDrag(e) }

    private func panDrag(_ e: NSEvent) {
        let p = point(e)
        coordinator?.pan(by: CGSize(width: p.x - last.x, height: p.y - last.y), in: self)
        last = p
    }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        coordinator?.scene.zoom(exp(-Double(dy) * 0.01))
    }

    override func magnify(with e: NSEvent) {
        coordinator?.scene.zoom(1 / max(1 + Double(e.magnification), 0.2))
    }
}
#else
extension GenerateViewport: UIViewRepresentable {
    func makeUIView(context: Context) -> GenerateSCNView {
        let v = GenerateSCNView()
        v.generateScene = scene
        v.scene = scene.scene
        v.pointOfView = scene.cameraNode
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 120
        let c = context.coordinator
        let one = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.oneFinger(_:)))
        one.maximumNumberOfTouches = 1
        let two = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.twoFingers(_:)))
        two.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        [one, two, pinch, tap].forEach(v.addGestureRecognizer)
        two.delegate = c
        pinch.delegate = c
        return v
    }

    func updateUIView(_ v: GenerateSCNView, context: Context) {}
}

/// Tells the scene its shape, so the framing fits the view's width as well as its height.
final class GenerateSCNView: SCNView {
    weak var generateScene: GenerateScene?

    override func layoutSubviews() {
        super.layoutSubviews()
        generateScene?.resized(width: bounds.width, height: bounds.height)
    }
}

extension GenerateViewport.Coordinator: UIGestureRecognizerDelegate {
    @objc func oneFinger(_ g: UIPanGestureRecognizer) {
        guard let v = g.view as? SCNView else { return }
        let p = g.location(in: v)
        switch g.state {
        case .began:
            let t = g.translation(in: v)
            down(CGPoint(x: p.x - t.x, y: p.y - t.y), in: v)
            drag(p, by: CGSize(width: t.x, height: t.y), in: v)
            g.setTranslation(.zero, in: v)
        case .changed:
            let t = g.translation(in: v)
            drag(p, by: CGSize(width: t.x, height: t.y), in: v)
            g.setTranslation(.zero, in: v)
        default:
            up(p, in: v)
        }
    }

    @objc func twoFingers(_ g: UIPanGestureRecognizer) {
        guard let v = g.view as? SCNView else { return }
        let t = g.translation(in: v)
        pan(by: CGSize(width: t.x, height: -t.y), in: v)
        g.setTranslation(.zero, in: v)
    }

    @objc func pinch(_ g: UIPinchGestureRecognizer) {
        guard g.scale > 0 else { return }
        scene.zoom(1 / Double(g.scale))
        g.scale = 1
    }

    @objc func tap(_ g: UITapGestureRecognizer) {
        guard let v = g.view as? SCNView else { return }
        click(g.location(in: v), in: v)
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
