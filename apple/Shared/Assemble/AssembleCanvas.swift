import SceneKit
import simd
import SwiftUI

/// The Assemble canvas: the SceneKit scene with its pointer rules, and the labels over it (the
/// selected joint's angle, the IK gap, the fingertip priorities, the motion study's time).
///
/// A press on a handle drives it: the gizmo (arrows move along an axis, rings turn, the centre
/// moves in the view plane), the selected joint's ring (turns the joint), a fingertip target
/// (slides on the object's surface). Anywhere else the camera orbits, pans and zooms.
struct AssembleCanvas: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: AssembleModel
    @State private var scene = AssembleScene()
    @State private var labels = AssembleLabels()

    var body: some View {
        let _ = units
        ZStack(alignment: .topLeading) {
            AssembleSceneView(model: model, scene: scene, labels: labels, dark: theme.isDark)
                .accessibilityElement()
                .accessibilityLabel(Text("Assembly viewport"))
                .accessibilityValue(Text(viewportSummary))
                .accessibilityHint(Text("Set joint values and the tip target in the inspector"))
            overlay
                .allowsHitTesting(false)
        }
        .background(theme.viewportGradient)
        .onAppear { scene.attach(model) }
        .overlay(alignment: .bottomLeading) { legend.padding(VFSpace.l) }
        .overlay(alignment: .top) { errorBanner }
    }

    @ViewBuilder private var overlay: some View {
        GeometryReader { _ in
            if let p = labels.jointPoint, let j = model.selected, model.tool != .dragTip, model.tool != .grasp {
                Text(AsmFormat.value(labels.jointValue ?? model.q[j.id] ?? 0, j))
                    .font(VFFont.rowEmphasis)
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, VFSpace.s).frame(height: VFSize.chip)
                    .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(theme.accent))
                    .position(x: p.x, y: p.y - 58)
            }
            if model.tool == .dragTip, labels.shortBy > 0.5, let p = labels.targetPoint {
                Label(String(localized: "\(VFFormat.length(labels.shortBy.rounded())) out of reach"), systemImage: "exclamationmark.triangle.fill")
                    .font(VFFont.row.weight(.medium))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, VFSpace.s).frame(height: VFSize.chip)
                    .vfSurface(.floating, radius: VFRadius.chip)
                    .position(x: p.x - 20, y: p.y - 22)
            }
            if model.tool == .grasp {
                ForEach(model.grasp.fingers) { f in
                    if let p = labels.tipPoints[f.frame] {
                        Text("\(f.priority)")
                            .font(VFFont.micro.weight(.bold))
                            .foregroundStyle(theme.onAccent)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(platform: AssembleScene.fingerColour(f.priority))))
                            .overlay(Circle().strokeBorder(theme.onAccent, lineWidth: 1.5))
                            .position(x: p.x + 16, y: p.y - 16)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: VFSpace.m) {
            if model.tool == .dragTip {
                Label(model.ik.reached ? String(localized: "Tip on target") : String(localized: "\(VFFormat.length(model.ik.shortBy.rounded())) short"),
                      systemImage: model.ik.reached ? "scope" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.ik.reached ? theme.inkSecondary : theme.warning)
                Text("Drag the arrows, rings or centre. Esc restores the pose.").foregroundStyle(theme.inkTertiary)
            } else if model.tool == .grasp {
                Text("Drag a numbered target on the object. The fingers follow.").foregroundStyle(theme.inkTertiary)
            } else if let j = model.selected {
                Text("Drag the blue ring to turn \(j.title.lowercased()).").foregroundStyle(theme.inkTertiary)
            }
        }
        .font(VFFont.small)
        .padding(.horizontal, VFSpace.m).frame(minHeight: VFSize.chip + 2)
        .vfSurface(.floating, radius: VFRadius.floating)
        .opacity(model.tool == .select && model.selected == nil ? 0 : 1)
        .accessibilityHidden(model.tool == .select && model.selected == nil)
    }

    /// What VoiceOver reads for the viewport: the tool and its state.
    private var viewportSummary: String {
        switch model.tool {
        case .dragTip:
            model.ik.reached ? String(localized: "Tip on target")
                             : String(localized: "Tip \(VFFormat.length(model.ik.shortBy.rounded())) out of reach")
        case .grasp:
            String(localized: "\(model.grasp.fingers.filter(\.reached).count) of \(model.grasp.fingers.count) fingertips reached")
        default:
            model.selected.map { String(localized: "\($0.title) at \(AsmFormat.value(model.q[$0.id] ?? 0, $0))") }
                ?? String(localized: "\(model.joints.count) joints")
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let e = model.error {
            ErrorBanner(message: e, retry: model.retry.map { r in { model.clearError(); r() } }, dismiss: { model.clearError() })
                .padding(.top, VFSpace.l)
                .padding(.horizontal, VFSpace.bannerInset)
        }
    }
}

extension Color {
    init(platform c: VFPlatformColor) {
        #if os(macOS)
        self.init(nsColor: c)
        #else
        self.init(uiColor: c)
        #endif
    }
}

/// Screen points of the things labelled over the canvas, updated at 30 Hz from the renderer.
@Observable
final class AssembleLabels {
    var jointPoint: CGPoint?
    var jointValue: Double?
    var targetPoint: CGPoint?
    var shortBy = 0.0
    var tipPoints: [String: CGPoint] = [:]
}

/// What a press on the canvas grabbed.
enum AssembleGrab {
    case axis(SIMD3<Double>, start: SIMD3<Double>)
    case ring(SIMD3<Double>, startRPY: SIMD3<Double>, startAngle: Double)
    case center(start: SIMD3<Double>)
    case joint(String, startValue: Double, startAngle: Double, sign: Double)
    case tip(String)
}

/// The pointer logic shared by the Mac and the touch views.
@MainActor
final class AssembleInteraction: NSObject, SCNSceneRendererDelegate {
    let model: AssembleModel
    let scene: AssembleScene
    let labels: AssembleLabels
    weak var view: SCNView?
    private var grab: AssembleGrab?
    private var start = CGPoint.zero
    private var lastLabels = 0.0
    /// UIKit's y grows downward, AppKit's upward: screen angles turn the other way.
    private let yDown: Bool

    init(model: AssembleModel, scene: AssembleScene, labels: AssembleLabels) {
        self.model = model
        self.scene = scene
        self.labels = labels
        #if os(macOS)
        yDown = false
        #else
        yDown = true
        #endif
    }

    var grabbing: Bool { grab != nil }

    /// A press: true when it caught a handle (the camera then stays still).
    func begin(at p: CGPoint) -> Bool {
        guard let view else { return false }
        let hits = view.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
                                             SCNHitTestOption.ignoreHiddenNodes: true])
        func named(_ prefix: String) -> (SCNHitTestResult, String)? {
            for h in hits {
                var n: SCNNode? = h.node
                while let x = n {
                    if let name = x.name, name.hasPrefix(prefix) { return (h, name) }
                    n = x.parent
                }
            }
            return nil
        }
        start = p
        if model.tool == .dragTip, model.product == .arm, !scene.gizmo.isHidden {
            if let (_, name) = named("gizmo.") {
                guard model.beginDrag() else { return false }
                let tip = model.ik.reached ? scene.tipNow(model) : model.ik.target
                if name.hasPrefix("gizmo.axis.") {
                    grab = .axis(axis(name.last), start: tip)
                } else if name.hasPrefix("gizmo.ring.") {
                    model.ik.keepOrientation = true
                    grab = .ring(axis(name.last), startRPY: model.ik.rpy, startAngle: screenAngle(p, around: tip))
                } else {
                    grab = .center(start: tip)
                }
                return true
            }
            return false
        }
        if model.tool == .grasp, let (_, name) = named("tip:") {
            grab = .tip(String(name.dropFirst(4)))
            return true
        }
        if let (_, name) = named("jring:"), let j = model.joints.first(where: { $0.id == String(name.dropFirst(6)) }) {
            let o = scene.root.simdConvertPosition(SIMD3(Float(j.origin[0]), Float(j.origin[1]), Float(j.origin[2])), to: nil)
            let center = world(model.poses[j.child], j.origin)
            let axisW = simd_normalize(scene.root.simdConvertVector(directionNow(j), to: nil))
            let toCam = simd_normalize(scene.cameraNode.simdWorldPosition - o)
            let sign: Double = simd_dot(axisW, toCam) >= 0 ? 1 : -1
            grab = .joint(j.id, startValue: model.q[j.id] ?? 0, startAngle: screenAngle(p, around: center), sign: sign)
            return true
        }
        return false
    }

    /// A click without drag: picks the component under the pointer and its joint.
    func click(at p: CGPoint) {
        guard let view, model.tool == .select || model.tool == .rotateJoint else { return }
        let hits = view.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
        var n: SCNNode? = hits.first?.node
        while let x = n {
            if let name = x.name, name.hasPrefix("comp:") {
                let id = String(name.dropFirst(5))
                if let j = model.joints.first(where: { $0.child == id }) { model.selectedJoint = j.id }
                return
            }
            n = x.parent
        }
    }

    func move(to p: CGPoint) {
        guard let grab else { return }
        switch grab {
        case let .axis(a, s):
            let along = screenAlong(p, axis: a, at: s)
            model.dragMove(to: s + a * along, rpy: model.ik.rpy)
        case let .ring(a, rpy0, ang0):
            let tip = model.ik.target
            let d = (screenAngle(p, around: tip) - ang0) * (yDown ? -1 : 1)
            let r0 = AssembleModel.quat(rpy: rpy0)
            let r = simd_quatd(angle: d * cameraFacing(a), axis: a) * r0
            let m = simd_float4x4(simd_quatf(ix: Float(r.imag.x), iy: Float(r.imag.y), iz: Float(r.imag.z), r: Float(r.real)))
            model.dragMove(to: tip, rpy: AssembleModel.rpy(m))
        case let .center(s):
            model.dragMove(to: viewPlane(p, through: s), rpy: model.ik.rpy)
        case let .joint(id, v0, ang0, sign):
            guard let j = model.joints.first(where: { $0.id == id }) else { return }
            let center = world(model.poses[j.child], j.origin)
            var d = (screenAngle(p, around: center) - ang0) * 180 / .pi
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            model.setJoint(id, value: v0 + d * sign * (yDown ? -1 : 1))
            scene.sync()
        case let .tip(frame):
            guard let view else { return }
            let hits = view.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            let g = model.grasp
            var point: SIMD3<Double>?
            for h in hits where h.node.name == "object" {
                let w = scene.root.simdConvertPosition(h.simdWorldCoordinates, from: nil)
                point = SIMD3(Double(w.x), Double(w.y), Double(w.z))
                break
            }
            if point == nil, let f = g.fingers.first(where: { $0.frame == frame }) {
                point = viewPlane(p, through: f.point)
            }
            guard let raw = point else { return }
            let (pt, n) = HandGrasp.surface(of: g, center: g.center, axis: g.axis, near: raw)
            scene.moveTip(frame, to: pt, normal: n)
            model.moveFingertip(frame, to: pt, normal: n, solve: true)
            scene.sync()
        }
    }

    func end(cancel: Bool = false) {
        guard let g = grab else { return }
        grab = nil
        switch g {
        case .axis, .ring, .center:
            model.endDrag(commit: !cancel)
        case .joint, .tip:
            break
        }
        scene.sync()
    }

    // MARK: Renderer

    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // The render thread: the labels and the gizmo size are worked out on the main thread.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.frameTick() } }
    }

    private func frameTick() {
        guard let view else { return }
        let h = view.bounds.height
        scene.scaleGizmo(viewHeight: h)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLabels > 1.0 / 30 else { return }
        lastLabels = now
        var joint: CGPoint?
        var value: Double?
        if let j = model.selected {
            let w = world(model.poses[j.child], j.origin)
            joint = screen(w)
            value = scene.liveQ[j.id] ?? model.q[j.id]
        }
        let target = model.tool == .dragTip ? screen(model.ik.dragging ? (scene.liveTarget ?? model.ik.target) : model.ik.target) : nil
        let short = model.ik.dragging ? scene.liveShortBy : model.ik.shortBy
        var tips: [String: CGPoint] = [:]
        if model.tool == .grasp { for f in model.grasp.fingers { tips[f.frame] = screen(f.point) } }
        labels.jointPoint = joint
        labels.jointValue = value
        labels.targetPoint = target
        labels.shortBy = short
        labels.tipPoints = tips
    }

    // MARK: Geometry

    private func axis(_ c: Character?) -> SIMD3<Double> {
        switch c { case "x": SIMD3(1, 0, 0); case "y": SIMD3(0, 1, 0); default: SIMD3(0, 0, 1) }
    }

    private func directionNow(_ j: AsmJoint) -> SIMD3<Float> {
        let m = model.poses[j.child] ?? matrix_identity_float4x4
        let a = SIMD3(Float(j.axis[0]), Float(j.axis[1]), Float(j.axis[2]))
        let r = simd_float3x3(columns: (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        return r * a
    }

    private func world(_ m: simd_float4x4?, _ o: [Double]) -> SIMD3<Double> {
        let p = (m ?? matrix_identity_float4x4) * SIMD4(Float(o[0]), Float(o[1]), Float(o[2]), 1)
        return SIMD3(Double(p.x), Double(p.y), Double(p.z))
    }

    /// A point of the assembly frame (mm) on screen.
    func screen(_ p: SIMD3<Double>) -> CGPoint? {
        guard let view else { return nil }
        let w = scene.root.simdConvertPosition(SIMD3(Float(p.x), Float(p.y), Float(p.z)), to: nil)
        let s = view.projectPoint(SCNVector3(w))
        guard s.z > 0, s.z < 1 else { return nil }
        #if os(macOS)
        return CGPoint(x: CGFloat(s.x), y: view.bounds.height - CGFloat(s.y))
        #else
        return CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
        #endif
    }

    private func projected(_ p: SIMD3<Double>) -> SIMD3<Double> {
        guard let view else { return .zero }
        let w = scene.root.simdConvertPosition(SIMD3(Float(p.x), Float(p.y), Float(p.z)), to: nil)
        let s = view.projectPoint(SCNVector3(w))
        return SIMD3(Double(s.x), Double(s.y), Double(s.z))
    }

    private func unprojected(_ x: CGFloat, _ y: CGFloat, _ z: Double) -> SIMD3<Double> {
        guard let view else { return .zero }
        let w = view.unprojectPoint(SCNVector3(x: .init(x), y: .init(y), z: .init(z)))
        let r = scene.root.simdConvertPosition(SIMD3(Float(w.x), Float(w.y), Float(w.z)), from: nil)
        return SIMD3(Double(r.x), Double(r.y), Double(r.z))
    }

    /// How far (mm) along `axis` from `at` the pointer has moved since the press.
    private func screenAlong(_ p: CGPoint, axis a: SIMD3<Double>, at s: SIMD3<Double>) -> Double {
        let p0 = projected(s), p1 = projected(s + a * 10)
        let dir = SIMD2(p1.x - p0.x, p1.y - p0.y)
        let len = simd_length(dir)
        guard len > 1e-3 else { return 0 }
        let delta = SIMD2(Double(p.x - start.x), Double(p.y - start.y))
        return simd_dot(delta, dir / len) / len * 10
    }

    /// The pointer on the plane through `s` facing the camera (mm).
    private func viewPlane(_ p: CGPoint, through s: SIMD3<Double>) -> SIMD3<Double> {
        let z = projected(s).z
        return unprojected(p.x, p.y, z)
    }

    private func screenAngle(_ p: CGPoint, around w: SIMD3<Double>) -> Double {
        let c = projected(w)
        return atan2(Double(p.y) - c.y, Double(p.x) - c.x)
    }

    private func cameraFacing(_ a: SIMD3<Double>) -> Double {
        let aw = scene.root.simdConvertVector(SIMD3(Float(a.x), Float(a.y), Float(a.z)), to: nil)
        let toCam = scene.cameraNode.simdWorldPosition - scene.gizmo.simdWorldPosition
        return simd_dot(aw, toCam) >= 0 ? 1 : -1
    }
}

#if os(macOS)
/// The SCNView of the Mac canvas: handles first, the camera otherwise; Esc cancels a drag.
final class AssembleSCNView: SCNView {
    var interaction: AssembleInteraction?
    private var handled = false
    private var downAt = CGPoint.zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        downAt = p
        handled = interaction?.begin(at: p) ?? false
        if !handled { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if handled { interaction?.move(to: convert(event.locationInWindow, from: nil)) } else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if handled { interaction?.end() } else {
            super.mouseUp(with: event)
            if hypot(p.x - downAt.x, p.y - downAt.y) < 3 { interaction?.click(at: p) }
        }
        handled = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, interaction?.grabbing == true {
            interaction?.end(cancel: true)
            handled = false
            return
        }
        super.keyDown(with: event)
    }
}

struct AssembleSceneView: NSViewRepresentable {
    let model: AssembleModel
    let scene: AssembleScene
    let labels: AssembleLabels
    let dark: Bool
    var tick = 0

    func makeCoordinator() -> AssembleInteraction { AssembleInteraction(model: model, scene: scene, labels: labels) }

    func makeNSView(context: Context) -> AssembleSCNView {
        let v = AssembleSCNView()
        v.scene = scene.scene
        v.pointOfView = scene.cameraNode
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = false
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.autoenablesDefaultLighting = false
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = false
        v.delegate = context.coordinator
        v.interaction = context.coordinator
        context.coordinator.view = v
        scene.attach(model)
        scene.dark = dark
        scene.sync()
        v.defaultCameraController.target = scene.root.simdConvertPosition(SIMD3(0, 0, 190), to: nil).scn
        return v
    }

    func updateNSView(_ v: AssembleSCNView, context: Context) {
        // Read what the scene depends on so SwiftUI calls this when it changes.
        _ = (model.documentRevision, model.poseRevision, model.tool, model.selectedJoint, model.tab, model.interference, model.grasp, model.ik.shortBy, tick)
        scene.dark = dark
        scene.sync()
        v.setNeedsDisplay(v.bounds)
    }
}
#else
final class AssembleSCNView: SCNView, UIGestureRecognizerDelegate {
    var interaction: AssembleInteraction?
    private lazy var pan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        g.maximumNumberOfTouches = 1
        g.delegate = self
        return g
    }()

    func install() {
        addGestureRecognizer(pan)
        for g in gestureRecognizers ?? [] where g !== pan { g.require(toFail: pan) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan else { return super.gestureRecognizerShouldBegin(g) }
        return interaction?.begin(at: g.location(in: self)) ?? false
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .changed: interaction?.move(to: g.location(in: self))
        case .ended: interaction?.end()
        case .cancelled, .failed: interaction?.end(cancel: true)
        default: break
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) { interaction?.click(at: g.location(in: self)) }
}

struct AssembleSceneView: UIViewRepresentable {
    let model: AssembleModel
    let scene: AssembleScene
    let labels: AssembleLabels
    let dark: Bool
    var tick = 0

    func makeCoordinator() -> AssembleInteraction { AssembleInteraction(model: model, scene: scene, labels: labels) }

    func makeUIView(context: Context) -> AssembleSCNView {
        let v = AssembleSCNView()
        v.scene = scene.scene
        v.pointOfView = scene.cameraNode
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.delegate = context.coordinator
        v.interaction = context.coordinator
        context.coordinator.view = v
        v.install()
        scene.attach(model)
        scene.dark = dark
        scene.sync()
        v.defaultCameraController.target = scene.root.simdConvertPosition(SIMD3(0, 0, 190), to: nil).scn
        return v
    }

    func updateUIView(_ v: AssembleSCNView, context: Context) {
        _ = (model.documentRevision, model.poseRevision, model.tool, model.selectedJoint, model.tab, model.interference, model.grasp, model.ik.shortBy, tick)
        scene.dark = dark
        scene.sync()
    }
}
#endif

extension SIMD3 where Scalar == Float {
    var scn: SCNVector3 { SCNVector3(self) }
}
