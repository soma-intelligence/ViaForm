#if os(iOS)
import SwiftUI
import UIKit
import MetalKit

// Floating pieces of the iPad stage: the tool column entry point, the context pill placed
// under the selection (off by default since T-4), the value bubble, the inspector card and the summary capsule.

// MARK: - Tool groups

/// One labelled column of tools (sketch or solid), 44 point targets with a caption under each.
struct PadToolGroup<Content: View>: View {
    @Environment(\.viaFormTheme) private var theme
    let title: String
    var maxHeight: CGFloat = 640
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 2) {
            VFCaption(title).lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 2)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) { content }.padding(.horizontal, 5).padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 76)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .vfSurface(.control, radius: VFRadius.touchFloating)
    }
}

/// A tool face: icon on its chip, caption under it, accent fill when active.
struct PadToolButton: View {
    @Environment(\.viaFormTheme) private var theme
    let label: String
    var symbol: String = "questionmark"
    var art: String?
    var commandIcon: (icon: String, id: String)?
    var tool: Tool?
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let tool { ToolChipIcon(tool: tool, size: 20) }
                    else if let c = commandIcon { ToolChipIcon(icon: c.icon, id: c.id, size: 20) }
                    else { ToolChipIcon(art: art, symbol: symbol, size: 20) }
                }
                .frame(height: 26)
                Text(label).font(VFFont.micro).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(active ? theme.onAccent : theme.ink)
            .background(active ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.vfTouch)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The design stage's tools on the iPad: the adaptive column (T-4, T-5, T-17), kept under its old
/// name so the root view's call site keeps working. New call sites use `TouchToolColumn`.
struct DesignToolGroups: View {
    let model: DesignModel
    @Binding var showCommands: Bool
    var extra: [ContextAction] = []
    var constraintSlot: AnyView?

    var body: some View {
        TouchToolColumn(model: model, showPalette: { showCommands = true }, extra: extra, constraintSlot: constraintSlot)
    }

    func activate(_ t: Tool) { TouchToolActions.activate(t, model) }
}

enum TouchToolActions {
    /// What tapping a tool does: combines, delete and measure act at once, the others arm.
    @MainActor static func activate(_ t: Tool, _ model: DesignModel) {
        switch t {
        case .union: model.combine("join")
        case .subtract: model.combine("cut")
        case .intersect: model.combine("intersect")
        case .delete: model.deleteSelection()
        case .measure: model.measureSelection()
        case .sketch where model.selection.contains(where: \.isFace): model.sketchOnSelectedFace()
        case .sketch where model.tool == .sketch: model.tool = .select
        default: model.tool = model.tool == t ? .select : t
        }
    }
}

/// A stage's catalog commands as tool groups (Assemble, Render): the ribbon's first groups.
struct CatalogToolGroups: View {
    let ribbon: [StageScreen.RibbonGroup]
    var groups = 2
    let run: (FlowModel.Command) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(ribbon.prefix(groups)) { g in
                PadToolGroup(title: Self.short(g.name)) {
                    ForEach(g.commands) { c in
                        PadToolButton(label: StageLabels.command(c.label), commandIcon: (c.icon, c.id)) { run(c) }
                    }
                }
            }
        }
    }

    /// "SOLID ASSEMBLE" reads "Assemble": the panel name, not the engine tab.
    static func short(_ group: String) -> String {
        (group.split(separator: " ").last.map(String.init) ?? group).capitalized
    }
}

// MARK: - Anchored overlays

/// Places a floating piece next to the projected selection: under it first (the hand is above
/// on a tablet), then beside it, then above; clamped to the view and clear of `avoid`.
enum TouchAnchor {
    static func place(_ size: CGSize, near sel: CGRect, in bounds: CGSize, avoid: [CGRect] = [], gap: CGFloat = 18, margin: CGFloat = 12) -> CGPoint {
        let candidates = [
            CGPoint(x: sel.midX - size.width / 2, y: sel.maxY + gap),
            CGPoint(x: sel.maxX + gap, y: sel.maxY + gap),
            CGPoint(x: sel.minX - size.width - gap, y: sel.maxY + gap),
            CGPoint(x: sel.maxX + gap, y: sel.midY - size.height / 2),
            CGPoint(x: sel.minX - size.width - gap, y: sel.midY - size.height / 2),
            CGPoint(x: sel.midX - size.width / 2, y: sel.minY - size.height - gap),
        ]
        let area = CGRect(x: margin, y: margin, width: bounds.width - 2 * margin, height: bounds.height - 2 * margin)
        func clamp(_ o: CGPoint) -> CGRect {
            CGRect(x: min(max(o.x, area.minX), max(area.minX, area.maxX - size.width)),
                   y: min(max(o.y, area.minY), max(area.minY, area.maxY - size.height)),
                   width: size.width, height: size.height)
        }
        let pick = candidates.first { o in
            let r = CGRect(origin: o, size: size)
            return area.contains(r) && !avoid.contains { $0.intersects(r) }
        } ?? candidates[0]
        let r = clamp(pick)
        return CGPoint(x: r.midX, y: r.midY)
    }
}

/// One action of the context pill.
struct ContextAction: Identifiable {
    let id: String
    let title: String
    var symbol = "circle"
    var tool: Tool?
    var on = false
    let run: () -> Void
}

/// The selection's verbs, under it: tall faces (60 points), icon over caption.
struct ContextPill: View {
    enum Height { case regular, tall
        var points: CGFloat { self == .tall ? 60 : 44 }
    }
    @Environment(\.viaFormTheme) private var theme
    let actions: [ContextAction]
    var height: Height = .tall
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(actions) { a in
                Button(action: a.run) {
                    VStack(spacing: 4) {
                        Group {
                            if let t = a.tool { ToolChipIcon(tool: t, size: 20) } else { Image(systemName: a.symbol).font(VFFont.glyph(18, weight: .medium)) }
                        }
                        .frame(height: 24)
                        Text(a.title).font(VFFont.micro).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(a.on ? theme.accentText : theme.ink)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 62, minHeight: height.points)
                    .background(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous).fill(a.on ? theme.accent.opacity(0.16) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous).strokeBorder(a.on ? theme.accent : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .accessibilityLabel(a.title)
                .accessibilityAddTraits(a.on ? .isSelected : [])
            }
            if let dismiss {
                VFHairline(vertical: true).frame(height: 32)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(VFFont.glyph(14, weight: .semibold)).foregroundStyle(theme.inkSecondary)
                        .frame(width: VFSize.touchTarget, height: height.points).contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .help(String(localized: "Clear selection"))
                .accessibilityLabel(Text("Clear selection"))
            }
        }
        .padding(VFSpace.s)
        .vfSurface(.control, radius: VFRadius.touchFloating)
    }
}

/// The value being dragged, in an accent capsule, with a dotted arc back to the anchor.
struct ValueBubble: View {
    @Environment(\.viaFormTheme) private var theme
    let text: String

    var body: some View {
        Text(text).font(VFFont.rowEmphasis)
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, VFSpace.l).frame(minHeight: 30)
            .background(Capsule().fill(theme.accent))
            .overlay(Capsule().strokeBorder(theme.onAccent.opacity(0.3)))
            .shadow(color: theme.accent.opacity(0.4), radius: 6)
    }
}

struct DottedArc: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 40)
        p.addQuadCurve(to: to, control: mid)
        return p
    }
}

/// The selection's context pill, value bubble and arc, placed over the viewport from the
/// selection's projected anchor (`AnchorLayout` of the spec, on the orbit camera).
struct DesignAnchorLayer: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let stage: Workspace
    /// Rectangles of the floating cards, in the same space, to keep clear of.
    var avoid: [CGRect] = []
    var extra: [ContextAction] = []
    /// The floating pill of verbs under the selection. Off on the iPad since T-4: the verbs live
    /// in the left tool column. Kept for layouts without the column.
    var showsPill = false

    var body: some View {
        let _ = units
        GeometryReader { geo in
            let size = geo.size
            // The picked face or edge, or the picked bodies' projected bounds (as on the Mac):
            // the pill goes by the selection, never down by the thumbs.
            let _ = (model.scene.revision, model.camera.yaw, model.camera.pitch, model.camera.distance)
            let found = AnchorLayout.anchor(model, size: size)
            let anchor = found?.screen
            let sel = found?.rect
            let actions = pillActions
            ZStack(alignment: .topLeading) {
                Color.clear
                // The distance handle: on the picked face from Select, on the face or the
                // extrude profile while the tool is armed. 44 point grip.
                if let axis = model.handleAxis, model.tool == .select || model.tool.value?.unit == "mm" {
                    DesignDistanceHandle(model: model, point: axis.point, normal: axis.normal, size: size, touch: true)
                }
                if let anchor, let v = model.tool.value, model.tool != .select {
                    let bubble = CGPoint(x: anchor.x + 120, y: anchor.y - 70)
                    DottedArc(from: anchor, to: bubble)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .allowsHitTesting(false)
                    Circle().fill(theme.accent).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(theme.onAccent, lineWidth: 2))
                        .position(anchor).allowsHitTesting(false)
                    // T-9: the value to type and the result menu (B's chip) on the handle.
                    let _ = v
                    TouchValueChip(model: model).position(bubble)
                }
                // B-13: the move gizmo while Move runs.
                TouchMoveGizmoLayer(model: model)
                if showsPill, !actions.isEmpty, model.tool == .select {
                    let w = CGFloat(actions.count) * 66 + 70, h: CGFloat = 76
                    let fallback = CGRect(x: size.width / 2 - 1, y: size.height - 260, width: 2, height: 2)
                    ContextPill(actions: actions, dismiss: { model.selection = []; model.selectedBodies = [] })
                        .fixedSize()
                        .position(TouchAnchor.place(CGSize(width: w, height: h), near: sel ?? fallback, in: size, avoid: avoid))
                }
            }
        }
        .ignoresSafeArea()
    }

    private var pillActions: [ContextAction] {
        var out: [ContextAction] = model.suggestions.prefix(5).map { t in
            ContextAction(id: t.rawValue, title: StageLabels.command(t.touchLabel), tool: t) { TouchToolActions.activate(t, model) }
        }
        out += extra
        return out
    }

    static func format(_ v: Double, _ unit: String) -> String {
        VFFormat.value(v, VFUnit(symbol: unit))
    }
}

// MARK: - Inspector card

/// The 320 point card on the right: a title row, value rows, an optional live slider and Done.
struct TouchInspectorCard<Content: View>: View {
    @Environment(\.viaFormTheme) private var theme
    let title: String
    var symbol = "cube"
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(VFFont.glyph(19)).foregroundStyle(theme.ink).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(VFFont.title).foregroundStyle(theme.ink).lineLimit(1)
                    if let subtitle { Text(subtitle).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 52)
            VFHairline()
            content
        }
        .padding(.horizontal, VFSpace.xl).padding(.vertical, VFSpace.m)
        .frame(width: VFSize.touchInspector)
        .vfSurface(.floating, radius: VFRadius.touchFloating)
    }
}

/// A label and its value, 48 points tall.
struct TouchKVRow: View {
    @Environment(\.viaFormTheme) private var theme
    let label: String
    let value: String
    var divider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(theme.inkSecondary)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(theme.ink).lineLimit(2).multilineTextAlignment(.trailing)
            }
            .font(VFFont.row)
            .frame(minHeight: 46)
            .accessibilityElement(children: .combine)
            if divider { VFHairline().opacity(0.7) }
        }
    }
}

/// The pipeline lines of the card: what the stage consumes and what it feeds, with the fix
/// when it is stale.
struct TouchFlowRows: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: Workspace
    let open: (Workspace) -> Void

    var body: some View {
        let nodes = flow.nodes(in: stage.stage)
        VStack(alignment: .leading, spacing: 6) {
            VFCaption("Flow").padding(.top, 10)
            ForEach(nodes) { n in
                HStack(spacing: 8) {
                    VFStatusDot(status: n.status.vfStatus, size: 7)
                    Text(n.revisionName ?? n.label).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Spacer()
                    Text(n.summary).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                }
                .frame(minHeight: 28)
                .accessibilityElement(children: .combine)
                .accessibilityValue(n.status.vfStatus.word)
                ForEach(n.consumes, id: \.id) { i in
                    HStack(spacing: VFSpace.s) {
                        // A moved input reads "Stale" with a triangle, never colour alone.
                        Image(systemName: i.current ? "arrow.down.right" : "exclamationmark.triangle.fill")
                            .font(VFFont.glyph(11)).foregroundStyle(i.current ? theme.inkTertiary : theme.warning)
                            .accessibilityHidden(true)
                        Text(i.now_name ?? i.id).font(VFFont.small).foregroundStyle(i.current ? theme.inkSecondary : theme.ink)
                        if !i.current { Text("Stale").font(VFFont.micro).foregroundStyle(theme.warning) }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
                if !n.reason.isEmpty, n.status == .stale || n.status == .failed {
                    Text(n.reason).font(VFFont.small).foregroundStyle(theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if let a = n.action, n.status == .stale {
                    Button(a.label) {
                        if let first = a.plan.first, let s = flow.node(first)?.stage, let w = Workspace(stage: s) { open(w) }
                    }
                        .buttonStyle(.vfPrimary)
                        .frame(minHeight: VFSize.touchTarget)
                }
            }
            if nodes.isEmpty {
                Text("This stage builds nothing yet.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Summary capsule

/// What the design holds, at the bottom: bodies, components, joints, motors, revision.
struct SummaryCapsule: View {
    @Environment(\.viaFormTheme) private var theme
    let items: [(symbol: String, text: String)]

    var body: some View {
        HStack(spacing: VFSpace.l) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                if i > 0 { VFHairline(vertical: true).frame(height: 20) }
                Label(it.text, systemImage: it.symbol).font(VFFont.row.weight(.medium))
                    .foregroundStyle(theme.ink).lineLimit(1)
            }
        }
        .padding(.horizontal, VFSpace.xl)
        .frame(minHeight: VFSize.touchTarget)
        .vfSurface(.floating, radius: VFRadius.touchCapsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gestures

/// A two-finger tap on the 3D view undoes, as in other drawing apps on iPad. The recognizer sits
/// on the window so it never takes touches from the viewport's own gestures, but it only begins
/// when both fingers land on the 3D view (not a card, a bar or a sheet) and nothing is presented.
struct TwoFingerTapUndo: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.coordinator = context.coordinator
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: Probe, context: Context) { context.coordinator.action = action }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire(_ g: UITapGestureRecognizer) { if g.state == .ended { action() } }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Only touches on the 3D view count.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = touch.view else { return false }
            return view is MTKView
        }

        /// Never under a sheet, popover or alert.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let window = g.view as? UIWindow else { return false }
            return !TouchResponder.isPresenting(in: window)
        }
    }

    final class Probe: UIView {
        weak var coordinator: Coordinator?
        private weak var installed: UIGestureRecognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, installed == nil, let coordinator else { return }
            let g = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.fire(_:)))
            g.numberOfTouchesRequired = 2
            g.cancelsTouchesInView = false
            g.delaysTouchesEnded = false
            g.delegate = coordinator
            window.addGestureRecognizer(g)
            installed = g
        }
        override func removeFromSuperview() {
            if let g = installed { g.view?.removeGestureRecognizer(g) }
            super.removeFromSuperview()
        }
    }
}
#endif
