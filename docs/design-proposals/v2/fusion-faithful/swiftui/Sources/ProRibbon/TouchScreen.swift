import SwiftUI

/// iPad layout (rendered at 1366 x 1024 from the Mac target). No ribbon: floating top capsule,
/// left tool column, ITEMS card on the right, context pill near the selection, value bubble tied
/// to the handle by a dashed arc, history capsule at the bottom. Every target is 44 pt or more.
struct TouchScreen: View {
    @State private var workspace: Workspace = .design
    @State private var tool = "Sketch"
    @State private var selected = "Index Finger"

    static let tools: [(String, String)] = [("Sketch", "sketch"), ("Extrude", "extrude"), ("Fillet", "fillet"), ("Hole", "hole"),
                                            ("Joint", "joint"), ("Measure", "measure"), ("Section", "section"), ("Insert", "import")]

    var body: some View {
        ZStack {
            ViewportBackground()
            // The hand crop is 575 x 656 pt, drawn 1:1 with its top at y 236 (as in the concept).
            ViewportImage(name: "hand_touch")
                .frame(width: 575, height: 656)
                .position(x: 558, y: 564)
            selectionOverlay
            ZStack(alignment: .top) {
                StatusBar()
                TopCapsule(workspace: $workspace).padding(.top, 40)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            HStack(alignment: .top) {
                ToolColumn(tools: TouchScreen.tools, selected: $tool)
                Spacer()
                VStack(alignment: .trailing, spacing: 30) {
                    ViewCube(size: 96, showHome: false).padding(.trailing, 290)
                    ItemsCard(selected: $selected)
                }
            }
            .padding(.top, 112)
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity, alignment: .top)
            HistoryCapsule()
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 36)
        }
        .frame(width: 1366, height: 1024)
    }

    /// The pill and the value bubble are placed in the hand image's own coordinate space,
    /// as the real app would project the selection anchor to screen.
    private var selectionOverlay: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ContextPill()
                .position(x: 694, y: 222)
            // Dashed arc from the value bubble down to the drag handle, with an arrow head.
            Path { p in
                p.move(to: CGPoint(x: 430, y: 276))
                p.addQuadCurve(to: CGPoint(x: 474, y: 324), control: CGPoint(x: 436, y: 318))
            }
            .stroke(VF.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            Path { p in
                p.move(to: CGPoint(x: 464, y: 316))
                p.addLine(to: CGPoint(x: 474, y: 324))
                p.addLine(to: CGPoint(x: 462, y: 328))
            }
            .stroke(VF.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            Circle().fill(VF.accent).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .position(x: 485, y: 327)
            Text("35 deg")
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(VF.accent))
                .shadow(color: VF.accent.opacity(0.35), radius: 6, y: 2)
                .position(x: 414, y: 254)
        }
        .frame(width: 1366, height: 1024)
    }
}

struct StatusBar: View {
    var body: some View {
        HStack {
            Text("9:41").font(.system(size: 15, weight: .semibold))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 14, weight: .semibold))
            Text("100%").font(.system(size: 15, weight: .medium))
            Image(systemName: "battery.100").font(.system(size: 18))
        }
        .padding(.horizontal, 26)
        .frame(height: 30)
        .foregroundStyle(VF.ink)
    }
}

struct TopCapsule: View {
    @Binding var workspace: Workspace
    var body: some View {
        HStack(spacing: 6) {
            icon("list.bullet")
            Text("Robotic Hand v12").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 8)
            icon("arrow.uturn.backward")
            icon("arrow.uturn.forward", dim: true)
            HStack(spacing: 0) {
                ForEach(Workspace.allCases) { w in
                    let on = w == workspace
                    Button { workspace = w } label: {
                        Text(w.name)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : VF.ink.opacity(0.8))
                            .padding(.horizontal, 13)
                            .frame(height: 36)
                            .background(Capsule().fill(on ? VF.accent : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color(hex: 0xEEF0F3)))
            .padding(.horizontal, 6)
            icon("square.and.arrow.up", tint: VF.accent)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .touchGlass(radius: 14)
    }

    private func icon(_ s: String, dim: Bool = false, tint: Color = VF.ink) -> some View {
        Button {} label: {
            Image(systemName: s).font(.system(size: 19)).foregroundStyle(dim ? VF.secondary.opacity(0.5) : tint)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ToolColumn: View {
    let tools: [(String, String)]
    @Binding var selected: String
    var body: some View {
        VStack(spacing: 4) {
            ForEach(tools, id: \.0) { t in
                let on = t.0 == selected
                Button { selected = t.0 } label: {
                    VStack(spacing: 5) {
                        GlyphView(glyph: .tool(t.1), size: 40)
                        Text(t.0).font(.system(size: 13)).foregroundStyle(on ? VF.accent : VF.ink)
                    }
                    .frame(width: 78, height: 82)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? VF.accent.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .touchGlass(radius: 14)
    }
}

struct ItemsCard: View {
    @Binding var selected: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ITEMS").font(.system(size: 13, weight: .semibold)).kerning(0.5).foregroundStyle(VF.secondary)
                .padding(.horizontal, 18).frame(height: 46)
            Hairline(color: VF.separator.opacity(0.6))
            ForEach(Sample.itemsTouch, id: \.self) { name in
                let on = name == selected
                Button { selected = name } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? VF.accent : VF.secondary)
                        Image(systemName: "cube.fill").font(.system(size: 20))
                            .foregroundStyle(on ? VF.accent : Color(hex: 0x8A9099))
                        Text(name).font(.system(size: 17)).foregroundStyle(on ? VF.accent : VF.ink)
                        Spacer()
                        Image(systemName: "eye").font(.system(size: 17)).foregroundStyle(on ? VF.accent : Color(hex: 0x4A4F57))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: VF.touchRow)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? VF.accent.opacity(0.10) : .clear).padding(.horizontal, 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 0)
        }
        .padding(.bottom, 8)
        .frame(width: 290)
        .touchGlass(radius: 14)
    }
}

struct ContextPill: View {
    let items: [(String, String)] = [("Rotate", "arrow.clockwise"), ("Joint", "link"), ("Fillet", "square.on.square.squareshape.controlhandles"),
                                     ("Hide", "eye.slash"), ("More", "ellipsis")]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                Button {} label: {
                    VStack(spacing: 5) {
                        Image(systemName: it.1).font(.system(size: 21, weight: .medium)).frame(height: 26)
                        Text(it.0).font(.system(size: 13))
                    }
                    .foregroundStyle(i == 0 ? VF.accent : VF.ink)
                    .frame(width: 76, height: 62)
                    .background(RoundedRectangle(cornerRadius: 10).fill(i == 0 ? VF.accent.opacity(0.10) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < items.count - 1 { Hairline(vertical: true, color: VF.separator.opacity(0.7)).frame(height: 40) }
            }
        }
        .padding(6)
        .touchGlass(radius: 14)
    }
}

struct HistoryCapsule: View {
    let items: [Sample.FeatureKind] = [.sketch, .extrude, .fillet, .hole, .joint, .fillet, .pattern]
    var body: some View {
        HStack(spacing: 4) {
            Text("History").font(.system(size: 15, weight: .medium)).padding(.horizontal, 12)
            ForEach(Array(items.enumerated()), id: \.offset) { i, f in
                Button {} label: {
                    VStack(spacing: 4) {
                        GlyphView(glyph: .tool(f.icon), size: 34)
                        Text(f.rawValue).font(.system(size: 12))
                    }
                    .foregroundStyle(VF.ink)
                    .frame(width: 66, height: 70)
                    .background(RoundedRectangle(cornerRadius: 10).fill(i == 0 ? VF.accent.opacity(0.10) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < items.count - 1 {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .touchGlass(radius: 14)
    }
}
