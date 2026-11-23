import SwiftUI
import simd

/// The profiles of the sketch Extrude takes, on the canvas: the picked ones filled with the
/// accent, the others outlined so they read as pickable, the one under the pointer washed.
/// With an open sketch and Select, the sketch's points as small rings (they can be dragged).
struct SketchProfileLayer: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard let info = model.sketchInfo else { return }
            let cam = model.camera
            func screen(_ p: SIMD2<Double>) -> CGPoint { cam.project(info.plane.toWorld(p), size: size) }
            func path(_ loop: [SIMD2<Double>]) -> Path {
                var p = Path()
                guard let first = loop.first else { return p }
                p.move(to: screen(first))
                for q in loop.dropFirst() { p.addLine(to: screen(q)) }
                p.closeSubpath()
                return p
            }
            if model.tool == .extrude, info.profiles.count > 0 {
                let all = model.extrudeProfiles.isEmpty
                for prof in info.profiles where prof.outline.count > 2 {
                    var shape = path(prof.outline)
                    for h in prof.holes where h.count > 2 { shape.addPath(path(h)) }
                    let picked = all || model.extrudeProfiles.contains(prof.index)
                    let hovered = model.hoverProfile == prof.index
                    if picked {
                        ctx.fill(shape, with: .color(color.opacity(hovered ? 0.34 : 0.24)), style: FillStyle(eoFill: true))
                        ctx.stroke(shape, with: .color(color), lineWidth: 2)
                    } else {
                        if hovered { ctx.fill(shape, with: .color(color.opacity(0.12)), style: FillStyle(eoFill: true)) }
                        ctx.stroke(shape, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    }
                }
            }
            if model.sketchOpen, model.tool == .select {
                for p in info.points {
                    let s = screen(p.at)
                    let r: CGFloat = 3.5
                    let dot = Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(theme.onAccent))
                    ctx.stroke(dot, with: .color(p.fixed ? theme.inkTertiary : color), lineWidth: 1.4)
                }
            }
        }
    }
}

/// The open sketch's dimensions as text on the canvas, each one a value that can be typed in
/// place: click it, type a number, a number with its unit or an expression, Return applies it
/// (one undo step), Escape or a click elsewhere leaves it as it was.
struct SketchDimensionLayer: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    /// The typed field is a half step taller than the label chip, and never narrower than this.
    private static let fieldMinWidth: CGFloat = 64
    @State private var editing: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if model.sketchOpen, let info = model.sketchInfo {
                // The camera is read so the labels follow an orbit, a pan or a zoom.
                let cam = model.camera
                ZStack(alignment: .topLeading) {
                    Color.clear.allowsHitTesting(false)
                    ForEach(info.dimensions) { d in
                        let at = cam.project(info.plane.toWorld(d.at), size: size)
                        label(d).position(at)
                    }
                }
            }
        }
        .onChange(of: model.sketchOpen) { _, open in if !open { editing = nil } }
    }

    @ViewBuilder private func label(_ d: SketchInfo.Dimension) -> some View {
        if editing == d.id {
            TextField("Value", text: $text)
                .textFieldStyle(.plain)
                .font(VFFont.small.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.ink)
                .frame(width: max(Self.fieldMinWidth, CGFloat(text.count) * VFSpace.m + VFSpace.xxl),
                       height: VFSize.chip + VFSpace.xxs)
                .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.panel))
                .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(theme.accent, lineWidth: 1.5))
                .focused($focused)
                .onSubmit { commit(d) }
                #if os(macOS)
                .onExitCommand { editing = nil }
                #endif
                .onChange(of: focused) { _, f in if !f, editing == d.id { editing = nil } }
                .onAppear { focused = true }
                .accessibilityLabel("Dimension value")
        } else {
            Button {
                text = d.editText
                editing = d.id
            } label: {
                Text(d.driven ? "(\(d.text))" : d.text)
                    .font(VFFont.small.weight(.semibold))
                    .foregroundStyle(d.failing ? theme.danger : (d.driven ? theme.inkSecondary : theme.ink))
                    .padding(.horizontal, VFSpace.s)
                    .frame(height: VFSize.chip)
                    .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.panel.opacity(0.94)))
                    .overlay(RoundedRectangle(cornerRadius: VFRadius.control)
                        .strokeBorder(d.failing ? theme.danger : theme.hairline, lineWidth: VFSize.hairline))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(d.param == nil || d.driven)
            .help(d.param == nil || d.driven ? "A driven dimension: it follows the sketch" : "Click to type a new value")
            .accessibilityLabel("Dimension \(d.text)")
            .accessibilityHint(d.param == nil || d.driven ? "" : "Edits the value")
        }
    }

    private func commit(_ d: SketchInfo.Dimension) {
        let t = text
        editing = nil
        model.setDimension(d, to: t)
    }
}
