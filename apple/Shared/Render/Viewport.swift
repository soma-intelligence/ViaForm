import MetalKit
import SwiftUI

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// The 3D view: Metal draws the engine's scene, SwiftUI draws the sketch preview over it.
struct Viewport: View {
    let model: DesignModel
    let theme: ViewportTheme

    var body: some View {
        ZStack {
            MetalViewport(model: model, theme: theme)
            SketchOverlay(model: model, color: Color(theme.highlight)).allowsHitTesting(false)
        }
    }
}

extension Color {
    init(_ v: SIMD4<Float>) { self.init(red: Double(v.x), green: Double(v.y), blue: Double(v.z), opacity: Double(v.w)) }
}

/// The shape being drawn and the snapped cursor, on the sketch plane.
struct SketchOverlay: View {
    let model: DesignModel
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard let plane = model.sketchPlane else { return }
            let cam = model.camera
            func screen(_ p: SIMD2<Double>) -> CGPoint { cam.project(plane.toWorld(p), size: size) }
            for poly in model.rubberBand where poly.count > 1 {
                var path = Path()
                path.move(to: screen(poly[0]))
                for p in poly.dropFirst() { path.addLine(to: screen(p)) }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, dash: [5, 3]))
            }
            for c in model.clicks {
                let s = screen(c)
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6)), with: .color(color))
            }
            if model.tool.isSketchTool, let cur = model.cursor {
                let s = screen(cur)
                let r: CGFloat = model.cursorSnap == nil ? 3 : 5
                ctx.stroke(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)), with: .color(color), lineWidth: 1.5)
                let label = String(format: "%.2f, %.2f", cur.x, cur.y) + (model.cursorSnap.map { "  \($0)" } ?? "")
                ctx.draw(Text(label).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(color), at: CGPoint(x: s.x + 12, y: s.y - 12), anchor: .leading)
            }
        }
    }
}

final class ViewportCoordinator {
    let model: DesignModel
    var renderer: Renderer?
    private var lastLayout = Date.distantPast

    init(model: DesignModel) { self.model = model }

    func attach(_ view: MTKView, theme: ViewportTheme) {
        guard let r = Renderer(view: view, theme: theme) else { return }
        renderer = r
        view.delegate = r
        r.camera = model.camera
        r.update(scene: model.scene)
        model.onSceneChange = { [weak self] s in
            guard let self, let r = self.renderer else { return }
            r.camera = self.model.camera
            r.update(scene: s)
        }
        model.onHighlightChange = { [weak self] h in self?.renderer?.setHighlight(h) }
    }

    private var fitted = false

    func sync(size: CGSize) {
        if size.width > 0, size.height > 0 {
            model.viewSize = size
            // The first real size: frame the design for this view's shape.
            if !fitted { fitted = true; model.zoomToFit() }
        }
        renderer?.pointSize = size
        renderer?.camera = model.camera
    }

    /// The camera moved during a gesture: draw at once, lay the scene out again now and then.
    func moved(final: Bool = false) {
        renderer?.camera = model.camera
        if final || Date().timeIntervalSince(lastLayout) > 0.12 {
            lastLayout = Date()
            model.cameraChanged()
        }
    }

    func worldUnder(_ p: CGPoint) -> SIMD3<Double>? {
        ScenePicker.pickFace(model.scene, camera: model.camera, at: p, size: model.viewSize)?.point
    }
}

#if os(macOS)

final class CADView: MTKView {
    var coordinator: ViewportCoordinator?
    private var last: NSPoint = .zero
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        coordinator?.sync(size: bounds.size)
    }

    override func mouseMoved(with e: NSEvent) { coordinator?.model.hover(at: point(e)) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        last = point(e)
        guard !e.modifierFlags.contains(.option), !e.modifierFlags.contains(.command) else { return }
        if e.clickCount == 2 {
            coordinator?.model.doubleClick(at: last)
        } else {
            coordinator?.model.click(at: last, additive: e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.control))
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        if e.modifierFlags.contains(.option) { orbit(p) } else if e.modifierFlags.contains(.command) { pan(p) }
        last = p
    }

    override func mouseUp(with e: NSEvent) { coordinator?.moved(final: true) }

    private var rightDragged = false

    // A right click opens the marking menu; a right drag still orbits.
    override func rightMouseDown(with e: NSEvent) { last = point(e); rightDragged = false }
    override func rightMouseDragged(with e: NSEvent) {
        let p = point(e)
        if rightDragged || hypot(p.x - last.x, p.y - last.y) > 3 { rightDragged = true; orbit(p); last = p }
    }
    override func rightMouseUp(with e: NSEvent) {
        if rightDragged { coordinator?.moved(final: true) } else { coordinator?.model.markingMenu = point(e) }
    }

    override func otherMouseDown(with e: NSEvent) { last = point(e) }
    override func otherMouseDragged(with e: NSEvent) {
        let p = point(e)
        if e.modifierFlags.contains(.shift) { orbit(p) } else { pan(p) }
        last = p
    }
    override func otherMouseUp(with e: NSEvent) { coordinator?.moved(final: true) }

    private func orbit(_ p: CGPoint) {
        guard let c = coordinator else { return }
        c.model.camera.orbit(dx: Double(p.x - last.x), dy: Double(p.y - last.y))
        c.moved()
    }

    private func pan(_ p: CGPoint) {
        guard let c = coordinator else { return }
        c.model.camera.pan(dx: Double(p.x - last.x), dy: Double(p.y - last.y), viewHeight: Double(bounds.height))
        c.moved()
    }

    override func scrollWheel(with e: NSEvent) {
        guard let c = coordinator else { return }
        if e.hasPreciseScrollingDeltas, !e.modifierFlags.contains(.command) {
            // Trackpad: two fingers pan, Shift two fingers orbit.
            if e.modifierFlags.contains(.shift) {
                c.model.camera.orbit(dx: -Double(e.scrollingDeltaX), dy: -Double(e.scrollingDeltaY))
            } else {
                c.model.camera.pan(dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY), viewHeight: Double(bounds.height))
            }
        } else {
            let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            c.model.camera.zoom(exp(Double(d)), toward: c.worldUnder(point(e)))
        }
        c.moved(final: e.phase == .ended || e.momentumPhase == .ended)
    }

    override func magnify(with e: NSEvent) {
        guard let c = coordinator else { return }
        c.model.camera.zoom(1 + Double(e.magnification), toward: c.worldUnder(point(e)))
        c.moved(final: e.phase == .ended)
    }

    override func keyDown(with e: NSEvent) {
        guard let m = coordinator?.model else { return }
        switch e.keyCode {
        case 53 where m.markingMenu != nil: m.markingMenu = nil
        case 53: m.hasPreview ? m.cancelTool() : (m.tool.isSketchTool ? m.endChain() : m.cancelTool())
        case 36, 76: m.hasPreview ? m.commitTool() : m.endChain()
        case 51, 117: m.deleteSelection()
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "l": m.tool = .line
            case "r": m.tool = .rectangle
            case "c": m.tool = .circle
            case "e": m.tool = .extrude
            case "q": m.tool = .pressPull
            case "f": m.tool = .fillet
            case "s": m.toolboxOpen = true
            case "k": if !m.sketchOpen { m.tool = .sketch }
            case "6": m.setView(.iso)
            default: super.keyDown(with: e)
            }
        }
    }
}

struct MetalViewport: NSViewRepresentable {
    let model: DesignModel
    let theme: ViewportTheme

    func makeCoordinator() -> ViewportCoordinator { ViewportCoordinator(model: model) }

    func makeNSView(context: Context) -> CADView {
        let v = CADView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.coordinator = context.coordinator
        v.preferredFramesPerSecond = 60
        context.coordinator.attach(v, theme: theme)
        return v
    }

    func updateNSView(_ v: CADView, context: Context) {
        context.coordinator.renderer?.theme = theme
        context.coordinator.sync(size: v.bounds.size)
    }
}

#else

final class CADView: MTKView, UIGestureRecognizerDelegate {
    var coordinator: ViewportCoordinator?
    private var lastPan: CGPoint = .zero
    private var lastPinch: CGFloat = 1

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:)))
        orbit.maximumNumberOfTouches = 1
        orbit.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        for g in [tap, double, orbit, pan, pinch, hover] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        // Apple Pencil: a stroke on the canvas is a drag of the sketch cursor, not an orbit.
        let pencil = UIPanGestureRecognizer(target: self, action: #selector(pencilDrag(_:)))
        pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(pencil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.sync(size: bounds.size)
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        guard let m = coordinator?.model else { return }
        let p = g.location(in: self)
        m.hover(at: p)
        m.click(at: p, additive: true)
    }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        guard let m = coordinator?.model else { return }
        if m.tool.isSketchTool { m.endChain(); return }
        m.doubleClick(at: g.location(in: self))
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        coordinator?.model.hover(at: g.location(in: self))
    }

    @objc private func pencilDrag(_ g: UIPanGestureRecognizer) {
        guard let m = coordinator?.model else { return }
        let p = g.location(in: self)
        m.hover(at: p)
        if g.state == .began || g.state == .ended { m.click(at: p, additive: true) }
    }

    @objc private func orbit(_ g: UIPanGestureRecognizer) {
        guard let c = coordinator else { return }
        let p = g.translation(in: self)
        if g.state == .began { lastPan = .zero }
        c.model.camera.orbit(dx: Double(p.x - lastPan.x), dy: Double(p.y - lastPan.y))
        lastPan = p
        c.moved(final: g.state == .ended)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard let c = coordinator else { return }
        let p = g.translation(in: self)
        if g.state == .began { lastPan = .zero }
        c.model.camera.pan(dx: Double(p.x - lastPan.x), dy: Double(p.y - lastPan.y), viewHeight: Double(bounds.height))
        lastPan = p
        c.moved(final: g.state == .ended)
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard let c = coordinator else { return }
        if g.state == .began { lastPinch = 1 }
        let f = g.scale / lastPinch
        lastPinch = g.scale
        c.model.camera.zoom(Double(f), toward: c.worldUnder(g.location(in: self)))
        c.moved(final: g.state == .ended)
    }
}

struct MetalViewport: UIViewRepresentable {
    let model: DesignModel
    let theme: ViewportTheme

    func makeCoordinator() -> ViewportCoordinator { ViewportCoordinator(model: model) }

    func makeUIView(context: Context) -> CADView {
        let v = CADView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.coordinator = context.coordinator
        v.preferredFramesPerSecond = 60
        context.coordinator.attach(v, theme: theme)
        return v
    }

    func updateUIView(_ v: CADView, context: Context) {
        context.coordinator.renderer?.theme = theme
        context.coordinator.sync(size: v.bounds.size)
    }
}

#endif
