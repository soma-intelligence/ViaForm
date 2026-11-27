import SwiftUI
import simd

/// The profiles of the sketch Extrude takes, on the canvas: the picked ones filled with the
/// accent, the others outlined so they read as pickable, the one under the pointer washed.
/// With an open sketch and Select, the sketch's points as small rings (they can be dragged).
struct SketchProfileLayer: View {
    @Environment(\.viaFormTheme) private var theme
    /// The Sketch Palette's Profile option: closed profiles of the open sketch shaded.
    @AppStorage(SketchDisplaySettings.profileKey) private var profileFill = true
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
            if profileFill, model.sketchOpen {
                for prof in info.profiles where prof.outline.count > 2 {
                    var shape = path(prof.outline)
                    for h in prof.holes where h.count > 2 { shape.addPath(path(h)) }
                    ctx.fill(shape, with: .color(color.opacity(0.08)), style: FillStyle(eoFill: true))
                }
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
        }
    }
}

/// The open sketch on the canvas (B-1, B-2, B-3, B-5, B-9): curves in the defined-state colour
/// pair (free: `accentText`, fully defined: `ink`; construction dashed in `inkTertiary`), the
/// selection and the hover as halos, points as rings (Select and Dimension), constraint glyphs
/// (when Show constraints is on: dimmed when redundant, `danger` when failing) and the Dimension
/// tool's preview. Picking reads the same layout (`SketchGlyphLayout`, `SketchPicker`).
struct SketchEntityLayer: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    /// The Sketch Palette's Points and Projected options.
    @AppStorage(SketchDisplaySettings.pointsKey) private var showPoints = true
    @AppStorage(SketchDisplaySettings.projectedKey) private var showProjected = true
    let model: DesignModel
    let color: Color

    var body: some View {
        let _ = units
        Canvas { ctx, size in
            guard model.sketchOpen, let info = model.sketchInfo else { return }
            let cam = model.camera
            func screen(_ p: SIMD2<Double>) -> CGPoint { cam.project(info.plane.toWorld(p), size: size) }
            func path(_ poly: [SIMD2<Double>]) -> Path {
                var p = Path()
                guard let first = poly.first else { return p }
                p.move(to: screen(first))
                for q in poly.dropFirst() { p.addLine(to: screen(q)) }
                return p
            }
            let picked = Set(model.sketchSelection.map(\.id)).union(model.dimensionPicks.map(\.id))
            let hovered = model.sketchHover?.id
            let state = model.sketchState
            for c in info.curves where showProjected || !c.linked {
                let shape = path(c.polyline)
                if picked.contains(c.id) {
                    ctx.stroke(shape, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                } else if hovered == c.id {
                    ctx.stroke(shape, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
                let ink = picked.contains(c.id) ? color : (c.linked && !c.construction ? SketchStateStyle.linked(theme)
                    : SketchStateStyle.curve(theme, determined: c.determined || state?.fullyConstrained == true, construction: c.construction))
                ctx.stroke(shape, with: .color(ink), style: c.construction
                    ? StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [6, 4])
                    : StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            if showPoints, model.tool == .select || model.tool == .dimension || model.tool.takesSketchEntities {
                for p in info.points {
                    let s = screen(p.at)
                    let on = picked.contains(p.id), over = hovered == p.id
                    let r: CGFloat = on || over ? 4.5 : 3.5
                    let dot = Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(on ? color : theme.onAccent))
                    ctx.stroke(dot, with: .color(p.fixed ? theme.inkTertiary
                        : (on || over ? color : SketchStateStyle.curve(theme, determined: p.determined, construction: false))), lineWidth: 1.4)
                }
            }
            if model.showConstraints, model.tool == .select {
                let half = SketchGlyphLayout.side / 2
                for spot in SketchGlyphLayout.spots(info, camera: cam, size: size) {
                    let g = spot.glyph
                    let on = picked.contains(g.id), over = hovered == g.id
                    let box = Path(roundedRect: CGRect(x: spot.at.x - half, y: spot.at.y - half, width: half * 2, height: half * 2),
                                   cornerRadius: VFRadius.mark)
                    let alpha = g.redundant && !on ? 0.45 : 1
                    ctx.fill(box, with: .color(on ? color : theme.panel.opacity(0.94 * alpha)))
                    ctx.stroke(box, with: .color(g.failing ? theme.danger : (over ? color : theme.hairline)), lineWidth: over || g.failing ? 1.4 : 1)
                    let ink = on ? theme.onAccent : (g.failing ? theme.danger : theme.inkSecondary.opacity(alpha))
                    ctx.draw(Text(Image(systemName: SketchConstraintCatalog.symbol(for: g.name))).font(VFFont.micro).foregroundStyle(ink),
                             at: spot.at, anchor: .center)
                }
            }
            if let prev = model.dimensionPreview {
                let a = screen(prev.from), b = screen(prev.to)
                var lead = Path()
                lead.move(to: a)
                lead.addLine(to: b)
                ctx.stroke(lead, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ctx.draw(Text(prev.text).font(VFFont.small.weight(.semibold)).foregroundStyle(color), at: CGPoint(x: b.x, y: b.y - 10), anchor: .bottom)
            }
        }
    }
}

/// The defined-state colour pair for sketch geometry (B-3): free geometry in the accent text
/// colour, fully defined geometry in ink, construction geometry in tertiary ink.
enum SketchStateStyle {
    static func curve(_ theme: ViaFormTheme, determined: Bool, construction: Bool) -> Color {
        if construction { return theme.inkTertiary }
        return determined ? theme.ink : theme.accentText
    }

    /// Projected and included geometry (linked to the model, B-11): its own colour.
    static func linked(_ theme: ViaFormTheme) -> Color { theme.success }

    /// The readout colour for a sketch state: danger when over-constrained.
    static func readout(_ theme: ViaFormTheme, _ state: SketchDefinedState) -> Color {
        state.overConstrained ? theme.danger : (state.fullyConstrained ? theme.ink : theme.accentText)
    }
}

/// The open sketch's defined state as a small readout on the canvas (B-3): "Fully defined",
/// "Under defined (3 DOF)" or "Over-constrained", with Show constraints beside it.
struct SketchStateBadge: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        if let state = model.sketchState {
            HStack(spacing: VFSpace.s) {
                Label(state.summary, systemImage: state.symbol)
                    .font(VFFont.micro)
                    .foregroundStyle(SketchStateStyle.readout(theme, state))
                Button {
                    model.showConstraints.toggle()
                } label: {
                    Image(systemName: model.showConstraints ? "eye" : "eye.slash")
                        .font(VFFont.micro)
                        .foregroundStyle(theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help(model.showConstraints ? "Hide constraints" : "Show constraints")
                .accessibilityLabel(model.showConstraints ? "Hide constraints" : "Show constraints")
                if model.constructionMode {
                    Image(systemName: "line.diagonal")
                        .font(VFFont.micro)
                        .foregroundStyle(theme.inkTertiary)
                        .help("Construction mode")
                        .accessibilityLabel("Construction mode")
                }
            }
            .padding(.horizontal, VFSpace.m)
            .frame(height: VFSize.chip)
            .background(Capsule().fill(theme.panel.opacity(0.94)))
            .overlay(Capsule().strokeBorder(state.overConstrained ? theme.danger : theme.hairline, lineWidth: VFSize.hairline))
            .accessibilityElement(children: .contain)
        }
    }
}

/// The open sketch's dimensions as text on the canvas, each one a value that can be typed in
/// place: click it, type a number, a number with its unit or an expression, Return applies it
/// (one undo step), Escape or a click elsewhere leaves it as it was.
struct SketchDimensionLayer: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    /// The typed field is a half step taller than the label chip, and never narrower than this.
    private static let fieldMinWidth: CGFloat = 64
    @State private var editing: String?
    @State private var text = ""
    @FocusState private var focused: Bool
    /// The Sketch Palette's Dimensions option, read live.
    @AppStorage(SketchDisplaySettings.dimensionsKey) private var shown = true

    var body: some View {
        let _ = units
        GeometryReader { geo in
            let size = geo.size
            if model.sketchOpen, shown, let info = model.sketchInfo {
                // The camera is read so the labels follow an orbit, a pan or a zoom.
                let cam = model.camera
                ZStack(alignment: .topLeading) {
                    Color.clear.allowsHitTesting(false)
                    ForEach(info.dimensions) { d in
                        let at = cam.project(info.plane.toWorld(d.at), size: size)
                        label(d).position(at)
                    }
                    if let offer = model.dimensionOffer {
                        drivenOffer(offer).position(cam.project(info.plane.toWorld(offer.at), size: size))
                    }
                }
            }
        }
        .onChange(of: model.sketchOpen) { _, open in if !open { editing = nil } }
        .onChange(of: model.dimensionToEdit) { _, id in openPlaced(id) }
        .onAppear { openPlaced(model.dimensionToEdit) }
    }

    /// A dimension the Dimension tool just placed opens for typing (B-5).
    private func openPlaced(_ id: String?) {
        guard let id, let d = model.sketchInfo?.dimensions.first(where: { $0.id == id }) else { return }
        model.dimensionToEdit = nil
        text = d.editText
        editing = d.id
    }

    /// A refused dimension (the sketch already determines it), offered as a driven one.
    private func drivenOffer(_ offer: DimensionOffer) -> some View {
        Button {
            model.placeDrivenDimension()
        } label: {
            Label("Add as driven", systemImage: "ruler")
                .font(VFFont.small.weight(.semibold))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, VFSpace.s)
                .frame(height: VFSize.chip)
                .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.panel.opacity(0.94)))
                .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(theme.warning, lineWidth: VFSize.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(offer.reason)
        .accessibilityHint("The sketch already sets this value; adds it as a reference dimension")
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
