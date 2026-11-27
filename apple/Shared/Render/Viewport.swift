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
    /// The open sketch's defined-state readout at the top of the canvas (B-3). A layout that
    /// shows it elsewhere (a sketch palette, a status bar) turns this off.
    var sketchStatus = true

    private static var touch: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The Sketch Palette's Grid option: off hides the grid while a sketch is open.
    @AppStorage(SketchDisplaySettings.gridKey) private var sketchGrid = true

    private var drawnTheme: ViewportTheme {
        guard !sketchGrid, model.sketchOpen else { return theme }
        var t = theme
        t.gridOpacity = 0
        return t
    }

    var body: some View {
        ZStack {
            MetalViewport(model: model, theme: drawnTheme)
            SketchProfileLayer(model: model, color: Color(theme.highlight)).allowsHitTesting(false)
            SketchEntityLayer(model: model, color: Color(theme.highlight)).allowsHitTesting(false)
            SketchOverlay(model: model, color: Color(theme.highlight)).allowsHitTesting(false)
            SketchDimensionLayer(model: model)
            // Typed sizes on the rubber band (B-8), the selection box (M-8, T-11) and the
            // press-and-hold pick list (M-9).
            SketchSizeFieldsLayer(model: model)
            SelectionBoxLayer(model: model).allowsHitTesting(false)
            PickListLayer(model: model)
            // On-canvas value handles (B-13, B-15): the section arrow and the armed tool's drag.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if SectionController.of(model).isOn { SectionHandle(model: model, size: geo.size, touch: Self.touch) }
                    switch model.tool {
                    case .fillet, .chamfer, .shell, .revolve: ToolValueHandle(model: model, size: geo.size, touch: Self.touch)
                    default: EmptyView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            ViewportAccessibilityLayer(model: model)
        }
        .overlay(alignment: .top) {
            if sketchStatus { SketchStateBadge(model: model).padding(.top, VFSpace.m) }
        }
    }
}

extension Color {
    init(_ v: SIMD4<Float>) { self.init(red: Double(v.x), green: Double(v.y), blue: Double(v.z), opacity: Double(v.w)) }
}

/// The shape being drawn, the snapped cursor and the inference line (B-6), on the sketch plane.
struct SketchOverlay: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let color: Color

    var body: some View {
        let _ = units
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
            if let inf = model.inferenceLine {
                var line = Path()
                line.move(to: screen(inf.from))
                line.addLine(to: screen(inf.to))
                ctx.stroke(line, with: .color(theme.accent), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            for c in model.clicks {
                let s = screen(c)
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6)), with: .color(color))
            }
            if model.tool.isSketchTool, let cur = model.cursor {
                let s = screen(cur)
                let r: CGFloat = model.cursorSnap == nil ? 3 : 5
                ctx.stroke(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)), with: .color(color), lineWidth: 1.5)
                let label = VFFormat.lengths([cur.x, cur.y], separator: ", ", digits: 2) + (model.cursorSnap.map { "  \($0)" } ?? "")
                ctx.draw(Text(label).font(VFFont.micro).foregroundStyle(color), at: CGPoint(x: s.x + 12, y: s.y - 12), anchor: .leading)
            }
        }
    }
}

/// The size boxes on the rubber band (B-8). On the Mac the keyboard types into the active box
/// (digits, Tab, Return); on the iPad a tap on a box opens a field.
struct SketchSizeFieldsLayer: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @State private var editing: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let _ = units
        GeometryReader { geo in
            let fields = model.sizeFields
            if let plane = model.sketchPlane, !fields.isEmpty {
                ForEach(Array(fields.enumerated()), id: \.element.id) { i, f in
                    let s = model.camera.project(plane.toWorld(f.anchor), size: geo.size)
                    box(f)
                        .position(x: s.x, y: s.y - 22 + (i > 0 && f.anchor == fields[i - 1].anchor ? 26 : 0))
                }
            }
        }
        .allowsHitTesting(Self.touch)
    }

    private static var touch: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    @ViewBuilder private func box(_ f: SizeField) -> some View {
        if editing == f.role {
            TextField(f.label, text: $text)
                .font(VFFont.small.monospacedDigit())
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 84)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onSubmit {
                    model.setSize(f.role, text: text)
                    editing = nil
                }
                .padding(.horizontal, VFSpace.s)
                .padding(.vertical, VFSpace.xxs)
                .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.panel))
                .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(theme.accent, lineWidth: 1.5))
                .onAppear { focused = true }
        } else {
            HStack(spacing: VFSpace.xxs) {
                if f.typed { Image(systemName: "lock.fill").font(VFFont.micro).foregroundStyle(theme.inkSecondary).accessibilityHidden(true) }
                Text(f.shown).font(VFFont.small.monospacedDigit().weight(f.active ? .semibold : .regular))
                    .foregroundStyle(f.typed || f.active ? theme.ink : theme.inkSecondary)
            }
            .padding(.horizontal, VFSpace.s)
            .padding(.vertical, VFSpace.xxs)
            .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.panel.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(f.active ? theme.accent : theme.hairline,
                                                                                    lineWidth: f.active ? 1.5 : VFSize.hairline))
            .contentShape(Rectangle())
            .onTapGesture {
                text = f.typed ? f.shown : ""
                editing = f.role
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(f.label) \(f.shown)"))
        }
    }
}

/// The selection box being dragged: a solid outline for a window box (left to right), a dashed
/// one for a crossing box (right to left).
struct SelectionBoxLayer: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        Canvas { ctx, _ in
            guard let box = model.selectionBox else { return }
            let shape = Path(box.rect)
            let ink = box.crossing ? theme.success : theme.accent
            ctx.fill(shape, with: .color(ink.opacity(0.08)))
            ctx.stroke(shape, with: .color(ink), style: box.crossing ? StrokeStyle(lineWidth: 1, dash: [5, 3]) : StrokeStyle(lineWidth: 1))
        }
    }
}

/// What lies under the pointer after a press and hold (M-9): pick one to select it.
struct PickListLayer: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        GeometryReader { geo in
            if let list = model.pickList {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list.items.prefix(12)) { item in
                        Button {
                            model.choose(item)
                        } label: {
                            Label(item.label, systemImage: item.kind.symbol)
                                .font(VFFont.row)
                                .foregroundStyle(theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, VFSpace.m)
                                .padding(.vertical, VFSpace.xs)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, VFSpace.xs)
                .frame(width: 220)
                .vfSurface(.floating)
                .position(x: min(max(list.at.x + 118, 118), geo.size.width - 118),
                          y: min(list.at.y + CGFloat(min(list.items.count, 12)) * 14 + 12, geo.size.height - 20))
            }
        }
    }
}

final class ViewportCoordinator {
    let model: DesignModel
    var renderer: Renderer?

    init(model: DesignModel) { self.model = model }

    func attach(_ view: MTKView, theme: ViewportTheme) {
        guard let r = Renderer(view: view, theme: theme) else { return }
        renderer = r
        SectionController.of(model).bind(r)
        view.delegate = r
        r.camera = model.camera
        r.update(scene: model.scene)
        model.onSceneChange = { [weak self] s in
            guard let self, let r = self.renderer else { return }
            r.camera = self.model.camera
            r.update(scene: s)
        }
        model.onHighlightChange = { [weak self] h in self?.renderer?.setHighlight(h) }
        model.onCameraMove = { [weak self] c in self?.renderer?.camera = c }
        model.onGuidesChange = { [weak self] g in
            guard let self, let r = self.renderer else { return }
            r.camera = self.model.camera
            r.updateGuides(g)
        }
        PerfScript.viewportAttached(self)
    }

    private var fitted = false

    func sync(size: CGSize) {
        if size.width > 0, size.height > 0 {
            if model.viewSize != size { model.viewSize = size }
            // The first real size: frame the design for this view's shape.
            if !fitted { fitted = true; model.zoomToFit() }
        }
        renderer?.pointSize = size
        renderer?.camera = model.camera
    }

    /// The camera moved during a gesture: draw at once; the model decides when the grid and
    /// the axes follow (see `DesignModel.cameraChanged`).
    func moved(final: Bool = false) {
        renderer?.camera = model.camera
        model.cameraChanged(final: final)
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

    /// A sketch point is being dragged (Select in an open sketch), and whether it moved.
    private var sketchDragging = false
    private var sketchMoved = false
    /// How a press that grabbed a sketch point selects it when it is released without moving.
    private var sketchClickMode: DesignModel.SelectMode = .replace

    /// A Command-click without a drag toggles the hit (Command-drag pans in the ViaForm preset).
    private var commandClick = false
    private var leftMove: MousePreset.Move = .none

    /// Where a press on empty canvas with Select started: a drag from it draws a selection box.
    private var boxStart: CGPoint?
    /// A tangent arc dragged from the end of a line chain (B-12).
    private var arcDragging = false
    /// A trim path dragged across curves (M-16), in viewport points.
    private var trimPoints: [CGPoint]?
    /// Press and hold: the pick list opens when the press stays put (M-9).
    private var hold: DispatchWorkItem?
    private var holdFired = false
    private var downAt: CGPoint = .zero

    private func startHold(_ m: DesignModel, at p: CGPoint) {
        hold?.cancel()
        holdFired = false
        guard m.tool == .select else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, NSEvent.pressedMouseButtons & 1 == 1 else { return }
            if m.openPickList(at: p) {
                self.holdFired = true
                self.boxStart = nil
                m.selectionBox = nil
            }
        }
        hold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        last = point(e)
        downAt = last
        boxStart = nil
        guard let m = coordinator?.model else { return }
        if m.pickList != nil { m.pickList = nil }
        let flags = e.modifierFlags
        // Control-click is the Mac's secondary click: the marking menu.
        if flags.contains(.control) { m.markingMenu = last; return }
        leftMove = MousePreset.current.leftDrag(option: flags.contains(.option), command: flags.contains(.command))
        if flags.contains(.option) { return }
        if flags.contains(.command) { commandClick = true; return }
        if e.clickCount == 1, m.tool == .line, m.beginTangentArc(at: last) { arcDragging = true; return }
        if e.clickCount == 1, m.tool == .trim, m.sketchOpen {
            trimPoints = [last]
            m.trimPath = []
            m.dragTrim(to: last)
            return
        }
        if e.clickCount == 1, m.beginSketchDrag(at: last, curves: true) {
            sketchDragging = true
            sketchMoved = false
            sketchClickMode = flags.contains(.shift) ? .add : .replace
            startHold(m, at: last)
            return
        }
        if e.clickCount == 2 {
            m.doubleClick(at: last)
        } else {
            let empty = m.tool == .select && leftMove == .none && m.emptyCanvas(at: last)
            m.click(at: last, mode: flags.contains(.shift) ? .add : .replace)
            if empty { boxStart = last }
            startHold(m, at: last)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        guard let m = coordinator?.model else { return }
        if hypot(p.x - downAt.x, p.y - downAt.y) > 3 { hold?.cancel() }
        if holdFired { return }
        if arcDragging { m.dragTangentArc(to: p); return }
        if trimPoints != nil {
            trimPoints?.append(p)
            m.dragTrim(to: p)
            return
        }
        if sketchDragging {
            sketchMoved = true
            m.dragSketch(to: p)
            last = p
            return
        }
        if let start = boxStart, hypot(p.x - start.x, p.y - start.y) > 3 {
            m.selectionBox = .from(start, to: p)
            return
        }
        if commandClick, hypot(p.x - last.x, p.y - last.y) > 3 { commandClick = false }
        apply(leftMove, p)
        last = p
    }

    override func mouseUp(with e: NSEvent) {
        hold?.cancel()
        guard let m = coordinator?.model else { return }
        let p = point(e)
        if holdFired {
            holdFired = false
            if sketchDragging { sketchDragging = false; m.sketchDrag = nil }
            boxStart = nil
            return
        }
        if arcDragging {
            arcDragging = false
            m.endTangentArc(at: p)
            return
        }
        if let path = trimPoints {
            trimPoints = nil
            if hypot(p.x - downAt.x, p.y - downAt.y) > 4 {
                m.trimDrag(path: path + [p], size: bounds.size)
            } else {
                m.trimPath = []
                m.click(at: p, mode: .replace)
            }
            return
        }
        if sketchDragging {
            sketchDragging = false
            if sketchMoved {
                m.endSketchDrag()
            } else {
                // A press without a drag is a click: it selects the point or the curve.
                m.sketchDrag = nil
                m.click(at: p, mode: sketchClickMode)
            }
            return
        }
        if let box = m.selectionBox {
            boxStart = nil
            m.boxSelect(box.rect, crossing: box.crossing, size: bounds.size, additive: e.modifierFlags.contains(.shift))
            return
        }
        boxStart = nil
        if commandClick {
            commandClick = false
            m.click(at: p, mode: .toggle)
            return
        }
        coordinator?.moved(final: true)
    }

    private var rightDragged = false

    // A right click opens the marking menu; a right drag moves the camera as the preset says.
    // With no camera move on the right drag, a quick flick runs a marking menu slice (MarkingFlick).
    override func rightMouseDown(with e: NSEvent) {
        last = point(e)
        rightDragged = false
        if let m = coordinator?.model { MarkingFlick.shared.begin(m, at: last) }
    }
    override func rightMouseDragged(with e: NSEvent) {
        let p = point(e)
        let move = MousePreset.current.rightDrag(control: e.modifierFlags.contains(.control))
        guard move != .none else { MarkingFlick.shared.drag(to: p); return }
        if rightDragged || hypot(p.x - last.x, p.y - last.y) > 3 {
            if !rightDragged { MarkingFlick.shared.cancel() }
            rightDragged = true
            apply(move, p)
            last = p
        }
    }
    override func rightMouseUp(with e: NSEvent) {
        if rightDragged {
            coordinator?.moved(final: true)
        } else if MarkingFlick.shared.end(at: point(e)) == .ignored {
            coordinator?.model.markingMenu = point(e)
        }
    }

    override func otherMouseDown(with e: NSEvent) {
        last = point(e)
        // A double middle click fits the view (Fusion, M-6).
        if e.clickCount == 2, MousePreset.current.doubleMiddleFits { coordinator?.model.zoomToFit() }
    }
    override func otherMouseDragged(with e: NSEvent) {
        let p = point(e)
        apply(MousePreset.current.middleDrag(shift: e.modifierFlags.contains(.shift), control: e.modifierFlags.contains(.control)), p)
        last = p
    }
    override func otherMouseUp(with e: NSEvent) { coordinator?.moved(final: true) }

    private func apply(_ move: MousePreset.Move, _ p: CGPoint) {
        switch move {
        case .orbit: orbit(p)
        case .pan: pan(p)
        case .zoom:
            guard let c = coordinator else { return }
            c.model.camera.zoom(exp(Double(p.y - last.y) * 0.01), toward: nil)
            c.moved()
        case .none: break
        }
    }

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
            // Trackpad: two fingers pan or orbit, as the navigation preset says.
            let move = MousePreset.current.trackpad(shift: e.modifierFlags.contains(.shift), option: e.modifierFlags.contains(.option))
            if move == .orbit {
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
        let typing = !m.sizeFields.isEmpty
        let chars = e.charactersIgnoringModifiers ?? ""
        switch e.keyCode {
        case 53 where m.markingMenu != nil: m.markingMenu = nil
        case 53 where m.cancelDrawingStep(): break
        // Escape and Return go to the dialog's session first: it holds the preview with typed
        // options or while a feature is edited (the model's own preview goes through it too).
        case 53 where FeatureSession.of(m).handleEscape(): break
        case 53: m.tool.isSketchTool ? m.endChain() : m.cancelTool()
        case 48 where typing: m.sizeTab(backward: e.modifierFlags.contains(.shift))
        case 36 where FeatureSession.of(m).handleReturn(), 76 where FeatureSession.of(m).handleReturn(): break
        case 36, 76: m.endChain()
        case 51 where typing && m.sizeBackspace(): break
        case 51, 117: m.deleteSelection()
        // B-8: digits (and, once typing, units and operators) go to the active size box.
        case _ where typing && !e.modifierFlags.contains(.command)
            && (chars.allSatisfy { "0123456789.,".contains($0) } || !m.sizeEntry.text.isEmpty) && !chars.isEmpty:
            m.typeSize(chars)
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
            case "d" where m.sketchOpen: m.beginDimension()
            case "x" where m.sketchOpen: m.toggleConstruction()
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
        v.preferredFramesPerSecond = 120
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
    /// A one-finger or Pencil drag that started on a sketch point moves the point (T-3).
    private var sketchDragging = false
    /// Within this many points of a sketch point, a finger grabs it (a Pencil: `pencilGrab`).
    private static let fingerGrab: CGFloat = 22
    private static let pencilGrab: CGFloat = 12

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
        // Press and hold with Select lists what lies under the finger (M-9). Fingers only (a
        // Pencil drag draws a box or moves the cursor), and only while the finger stays put.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 4
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        hold.delegate = self
        addGestureRecognizer(hold)
        holdRecognizer = hold
    }

    private weak var holdRecognizer: UILongPressGestureRecognizer?

    /// The hold does not start on a sketch point a drag would grab (holding then moving drags
    /// it), nor while a box or a point drag runs.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === holdRecognizer else { return super.gestureRecognizerShouldBegin(g) }
        guard let m = coordinator?.model, m.tool == .select, !sketchDragging, m.selectionBox == nil, pencilMode == .none else { return false }
        return !m.sketchPointGrabbable(at: g.location(in: self), radius: Self.fingerGrab)
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
        if FeatureSession.of(m).canvasTap(at: p, size: bounds.size) { return }
        if m.pickList != nil { m.pickList = nil; return }
        // T-8: a tap on a closed profile with Select starts Extrude on it.
        if m.profileTap(at: p) { return }
        m.hover(at: p)
        m.click(at: p, additive: true)
    }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        // T-7: a planar face starts a sketch, anything else selects the body; a sketch tool
        // ends its chain.
        coordinator?.model.faceDoubleTap(at: g.location(in: self))
    }

    @objc private func hold(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let m = coordinator?.model, m.tool == .select else { return }
        m.openPickList(at: g.location(in: self))
    }

    /// What a Pencil stroke does: a tangent arc from the chain end, a trim path, a sketch point
    /// drag, a selection box on empty canvas (T-11), or the sketch cursor.
    private enum PencilMode { case none, arc, trim, box, cursor }
    private var pencilMode: PencilMode = .none
    private var pencilStart: CGPoint = .zero
    private var pencilPath: [CGPoint] = []

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        coordinator?.model.hover(at: g.location(in: self))
    }

    @objc private func pencilDrag(_ g: UIPanGestureRecognizer) {
        guard let m = coordinator?.model else { return }
        let p = g.location(in: self)
        if g.state == .began {
            let t = g.translation(in: self)
            pencilStart = CGPoint(x: p.x - t.x, y: p.y - t.y)
            pencilPath = [pencilStart]
            if m.tool == .line, m.beginTangentArc(at: pencilStart, radius: 16) {
                pencilMode = .arc
            } else if m.tool == .trim, m.sketchOpen {
                pencilMode = .trim
                m.trimPath = []
                m.dragTrim(to: pencilStart)
            } else if m.tool == .select, m.emptyCanvas(at: pencilStart, grab: Self.pencilGrab) {
                pencilMode = .box
            } else {
                pencilMode = .cursor
            }
        }
        switch pencilMode {
        case .arc:
            if g.state == .changed { m.dragTangentArc(to: p) }
            if g.state == .ended || g.state == .cancelled { m.endTangentArc(at: p); pencilMode = .none }
        case .trim:
            if g.state == .changed { pencilPath.append(p); m.dragTrim(to: p) }
            if g.state == .ended || g.state == .cancelled {
                m.trimDrag(path: pencilPath + [p], size: bounds.size)
                pencilMode = .none
            }
        case .box:
            if g.state == .changed { m.selectionBox = .from(pencilStart, to: p) }
            if g.state == .ended || g.state == .cancelled {
                // A box replaces the selection, as on the Mac without Shift.
                if let box = m.selectionBox { m.boxSelect(box.rect, crossing: box.crossing, size: bounds.size, additive: false) }
                pencilMode = .none
            }
        case .cursor, .none:
            if sketchDrag(g, grab: Self.pencilGrab) { return }
            m.hover(at: p)
            if g.state == .began || g.state == .ended { m.click(at: p, additive: true) }
            if g.state == .ended || g.state == .cancelled { pencilMode = .none }
        }
    }

    /// T-3: a pan that starts within `grab` points of a sketch point (Select, open sketch) drags
    /// it with live solver frames, one undo step on release. True while the pan is such a drag.
    private func sketchDrag(_ g: UIPanGestureRecognizer, grab: CGFloat) -> Bool {
        guard let m = coordinator?.model else { return false }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            // Where the finger went down: the pan begins a few points later.
            let t = g.translation(in: self)
            guard m.beginSketchDrag(at: CGPoint(x: p.x - t.x, y: p.y - t.y), radius: grab) else { return false }
            sketchDragging = true
            m.dragSketch(to: p)
            return true
        case .changed:
            guard sketchDragging else { return false }
            m.dragSketch(to: p)
            return true
        default:
            guard sketchDragging else { return false }
            sketchDragging = false
            m.endSketchDrag()
            return true
        }
    }

    @objc private func orbit(_ g: UIPanGestureRecognizer) {
        guard let c = coordinator else { return }
        if sketchDrag(g, grab: Self.fingerGrab) { return }
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
        v.preferredFramesPerSecond = 120
        context.coordinator.attach(v, theme: theme)
        return v
    }

    func updateUIView(_ v: CADView, context: Context) {
        context.coordinator.renderer?.theme = theme
        context.coordinator.sync(size: v.bounds.size)
    }
}

#endif
