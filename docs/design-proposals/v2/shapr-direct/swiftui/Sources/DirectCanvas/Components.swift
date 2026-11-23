import SwiftUI

// MARK: Glyphs

/// SF Symbol, or one of our own line glyphs ("vf.*") where SF has no CAD symbol.
struct Glyph: View {
    let name: String
    var size: CGFloat = 17
    var weight: Font.Weight = .regular
    var body: some View {
        switch name {
        case "vf.fillet":
            CadGlyph(kind: .fillet).frame(width: size, height: size)
        case "vf.chamfer":
            CadGlyph(kind: .chamfer).frame(width: size, height: size)
        case "vf.arc":
            CadGlyph(kind: .arc).frame(width: size, height: size)
        default:
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }
}

struct CadGlyph: Shape {
    enum Kind { case fillet, chamfer, arc }
    let kind: Kind
    func path(in r: CGRect) -> Path {
        var p = Path()
        let i = r.insetBy(dx: r.width * 0.12, dy: r.height * 0.12)
        switch kind {
        case .fillet:
            let rad = i.width * 0.45
            p.move(to: CGPoint(x: i.minX, y: i.maxY))
            p.addLine(to: CGPoint(x: i.minX, y: i.minY + rad))
            p.addQuadCurve(to: CGPoint(x: i.minX + rad, y: i.minY), control: CGPoint(x: i.minX, y: i.minY))
            p.addLine(to: CGPoint(x: i.maxX, y: i.minY))
            p.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
            p.closeSubpath()
        case .chamfer:
            let c = i.width * 0.38
            p.move(to: CGPoint(x: i.minX, y: i.maxY))
            p.addLine(to: CGPoint(x: i.minX, y: i.minY + c))
            p.addLine(to: CGPoint(x: i.minX + c, y: i.minY))
            p.addLine(to: CGPoint(x: i.maxX, y: i.minY))
            p.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
            p.closeSubpath()
        case .arc:
            p.move(to: CGPoint(x: i.minX, y: i.maxY))
            p.addQuadCurve(to: CGPoint(x: i.maxX, y: i.minY), control: CGPoint(x: i.minX, y: i.minY))
        }
        return p.strokedPath(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }
}

// MARK: Tool rail

struct RailTool: Identifiable {
    let id: String
    let glyph: String
    var label: String? = nil
    var key: String? = nil
}

/// Floating vertical capsule. Icon-only on Mac (52 to 56 pt wide), labelled under the icon
/// in Generative. Tools change per workspace; the active one is an indigo rounded square.
struct ToolRail: View {
    let tools: [RailTool]
    var active: String
    var labelled = false
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: labelled ? 6 : 12) {
            ForEach(tools) { t in
                Button { onSelect(t.id) } label: {
                    VStack(spacing: 4) {
                        Glyph(name: t.glyph, size: labelled ? 19 : 18)
                        if labelled, let l = t.label { Text(l).font(.system(size: 11)) }
                    }
                    .foregroundStyle(t.id == active ? Color.white : VF.text)
                    .frame(width: labelled ? 56 : 36, height: labelled ? 62 : 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(t.id == active ? VF.accent : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.key.map { "\(t.label ?? t.id) (\($0))" } ?? (t.label ?? t.id))
            }
        }
        .padding(.vertical, labelled ? 10 : 10)
        .padding(.horizontal, labelled ? 8 : 9)
        .card(labelled ? 16 : 14)
    }
}

// MARK: Segmented switches (drawn, so ImageRenderer can render them; the app uses Picker(.segmented))

struct PillSegments<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 30
    var font: CGFloat = 12
    var activeTint: Color = VF.text
    var activeWeight: Font.Weight = .semibold
    var expand = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                let on = item.0 == selection
                Button { withAnimation(.snappy(duration: 0.22)) { selection = item.0 } } label: {
                    Text(item.1)
                        .font(.system(size: font, weight: on ? activeWeight : .regular))
                        .foregroundStyle(on ? activeTint : VF.text.opacity(0.78))
                        .padding(.horizontal, expand ? 0 : 14)
                        .frame(maxWidth: expand ? .infinity : nil)
                        .frame(height: height - 6)
                        .background {
                            if on {
                                Capsule().fill(.white)
                                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(VF.track))
    }
}

/// Capsule toggle (Gusts).
struct PillToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(.snappy) { isOn.toggle() } } label: {
            Capsule()
                .fill(isOn ? VF.accent : Color(hex: 0xD8D9DE))
                .frame(width: 38, height: 23)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Track + knob slider, drawn (the app uses Slider with .tint(VF.accent)).
struct TrackSlider: View {
    @Binding var value: Double
    var width: CGFloat = 160
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color(hex: 0xDADCE2)).frame(height: 4)
            Capsule().fill(VF.accent).frame(width: width * value, height: 4)
            Circle().fill(.white)
                .overlay(Circle().fill(VF.accent).padding(3.5))
                .frame(width: 15, height: 15)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .offset(x: width * value - 7.5)
        }
        .frame(width: width, height: 18)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            value = min(1, max(0, g.location.x / width))
        })
    }
}

// MARK: Tree

struct TreeNode: Identifiable {
    let id: String
    let name: String
    var glyph: String = "cube"
    var depth = 0
    var expandable = false
    var expanded = false
    var detail: String? = nil
    var visible = true
}

struct TreeRow: View {
    let node: TreeNode
    var selected = false
    var device: Device = .mac
    var showLock = false

    var body: some View {
        let fg: Color = selected ? .white : VF.text
        HStack(spacing: 9) {
            Group {
                if node.expandable {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: device == .mac ? 10 : 12, weight: .semibold))
                } else { Color.clear }
            }
            .frame(width: 12)
            .foregroundStyle(selected ? .white : VF.secondary)
            Glyph(name: node.glyph, size: device == .mac ? 15 : 19, weight: .light)
                .frame(width: 22)
            Text(node.name).font(.system(size: device.rowFont))
            if let d = node.detail {
                Text(d).font(.system(size: device.rowFont)).foregroundStyle(selected ? .white.opacity(0.8) : VF.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: node.visible ? "eye" : "eye.slash")
                .font(.system(size: device == .mac ? 12 : 15))
                .foregroundStyle(selected ? .white : VF.text.opacity(0.75))
                .frame(width: device == .mac ? 22 : 36, height: device == .mac ? 22 : 44)
            if showLock {
                Image(systemName: "lock")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? .white : VF.text.opacity(0.75))
                    .frame(width: 36, height: 44)
            }
        }
        .foregroundStyle(fg)
        .padding(.leading, 8 + CGFloat(node.depth) * 22)
        .padding(.trailing, 6)
        .frame(height: device.row)
        .background(
            RoundedRectangle(cornerRadius: device == .mac ? 7 : 10, style: .continuous)
                .fill(selected ? VF.accent : .clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: Properties

struct PropertyRows: View {
    let rows: [(String, String)]
    var labelWidth: CGFloat = 104
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(r.0).foregroundStyle(VF.secondary).frame(width: labelWidth, alignment: .leading)
                    Text(r.1).foregroundStyle(VF.text).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .frame(height: 32)
            }
        }
    }
}

struct KeyValueRows: View {
    let rows: [(String, String)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Rectangle().fill(VF.divider).frame(height: 1) }
                HStack {
                    Text(r.0).foregroundStyle(VF.text.opacity(0.8))
                    Spacer()
                    Text(r.1).foregroundStyle(VF.text).monospacedDigit()
                }
                .font(.system(size: 13))
                .frame(height: 31)
            }
        }
    }
}

struct CardDivider: View {
    var body: some View { Rectangle().fill(VF.divider).frame(height: 1) }
}

// MARK: Context capsule

struct ContextAction: Identifiable {
    let id: String
    let glyph: String
    let title: String
    var primary = false
    var tinted = false
}

/// Horizontal capsule placed at the selection's projected anchor.
/// Styles: icon over caption (Design), icon plus label (Generative, Simulation).
struct ContextCapsule: View {
    enum Style { case stacked, inline, tall }
    let actions: [ContextAction]
    var style: Style = .stacked
    var stepper: String? = nil
    var onAction: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: style == .inline ? 6 : 4) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                if style == .inline, i > 0, !actions[i - 1].primary {
                    Rectangle().fill(VF.divider).frame(width: 1, height: 18)
                }
                Button { onAction(a.id) } label: { item(a) }.buttonStyle(.plain)
            }
            if let s = stepper {
                Rectangle().fill(VF.divider).frame(width: 1, height: 34).padding(.horizontal, 6)
                ValueStepper(text: s)
            }
        }
        .padding(.horizontal, style == .tall ? 10 : 10)
        .padding(.vertical, style == .tall ? 10 : 7)
        .card(style == .tall ? 18 : 18)
    }

    @ViewBuilder func item(_ a: ContextAction) -> some View {
        let fg: Color = a.primary ? .white : (a.tinted ? VF.accent : VF.text)
        switch style {
        case .stacked:
            VStack(spacing: 5) {
                Glyph(name: a.glyph, size: 16, weight: .light).frame(height: 18)
                Text(a.title).font(.system(size: 11))
            }
            .foregroundStyle(fg)
            .frame(minWidth: 66).frame(height: 46)
        case .tall:
            VStack(spacing: 7) {
                Glyph(name: a.glyph, size: 22, weight: .light)
                Text(a.title).font(.system(size: 12))
            }
            .foregroundStyle(fg)
            .frame(minWidth: 72).padding(.horizontal, 4).frame(height: 66)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(a.primary ? VF.accent : .clear))
        case .inline:
            HStack(spacing: 8) {
                Glyph(name: a.glyph, size: 14)
                Text(a.title).font(.system(size: 13, weight: a.primary ? .medium : .regular))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(a.primary ? VF.accent : .clear))
        }
    }
}

/// Inline value field. In the app this is a TextField that evaluates arithmetic
/// ("2 + 0.5", "12/4 mm") through the core expression parser.
struct ValueStepper: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 13)).monospacedDigit().foregroundStyle(VF.text)
            VStack(spacing: 1) {
                Image(systemName: "chevron.up")
                Image(systemName: "chevron.down")
            }
            .font(.system(size: 8, weight: .bold)).foregroundStyle(VF.text.opacity(0.7))
        }
        .padding(.horizontal, 14).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(VF.hairline))
    }
}

// MARK: Mini chart

struct MiniChart: View {
    let series: [[Double]]
    let colors: [Color]
    let ticks: [String]
    let range: ClosedRange<Double>
    var cursor: Double? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                    Text(t).font(.system(size: 10)).monospacedDigit().foregroundStyle(VF.secondary).lineLimit(1).fixedSize()
                    if i < ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
            .frame(width: 36, alignment: .trailing)
            Canvas { ctx, size in
                var grid = Path()
                for k in 0..<ticks.count {
                    let y = size.height * CGFloat(k) / CGFloat(max(1, ticks.count - 1))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(.black.opacity(0.05)), lineWidth: 1)
                var axis = Path()
                axis.move(to: .zero); axis.addLine(to: CGPoint(x: 0, y: size.height))
                ctx.stroke(axis, with: .color(.black.opacity(0.12)), lineWidth: 1)
                for (si, s) in series.enumerated() {
                    var p = Path()
                    for (i, v) in s.enumerated() {
                        let x = size.width * CGFloat(i) / CGFloat(s.count - 1)
                        let y = size.height * (1 - CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)))
                        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                    }
                    ctx.stroke(p, with: .color(colors[si % colors.count]), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                if let c = cursor {
                    var cp = Path()
                    cp.move(to: CGPoint(x: size.width * c, y: 0)); cp.addLine(to: CGPoint(x: size.width * c, y: size.height))
                    ctx.stroke(cp, with: .color(VF.accent.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
        }
    }
}

// MARK: Small pieces

struct IconButton: View {
    let glyph: String
    var size: CGFloat = 15
    var tint: Color = VF.text
    var body: some View {
        Image(systemName: glyph).font(.system(size: size)).foregroundStyle(tint)
            .frame(width: 30, height: 30).contentShape(Rectangle())
    }
}

struct Avatar: View {
    var size: CGFloat = 30
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hex: 0x8C93E8), Color(hex: 0x4F5BD5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Text("QC").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(VF.text)
    }
}

struct ChoiceRow: View {
    let glyph: String?
    let title: String
    var value: String? = nil
    var dot: Color? = nil
    var selected = false
    var body: some View {
        HStack(spacing: 10) {
            if let d = dot { Circle().fill(d).frame(width: 9, height: 9).frame(width: 20) }
            if let g = glyph { Glyph(name: g, size: 16, weight: .light).frame(width: 22) }
            Text(title).font(.system(size: 13))
                .foregroundStyle(selected ? VF.accent : VF.text)
            if let v = value { Text(v).font(.system(size: 13)).monospacedDigit().foregroundStyle(selected ? VF.accent : VF.secondary) }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? VF.accent : VF.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? VF.accentSoft : .clear))
    }
}
