import SwiftUI

// MARK: - Application bar

struct AppBar: View {
    let document: String
    var jobs = 3
    var onData: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            if RenderMode.active { TrafficLights().padding(.leading, 14) } else { Color.clear.frame(width: 78) }
            Text("ViaForm")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VF.ink)
                .padding(.leading, 20)
            HStack(spacing: 6) {
                barButton("square.grid.3x3", action: onData)
                barButton("square.and.arrow.down")
                barButton("arrow.uturn.backward")
                barButton("arrow.uturn.forward", dim: true)
            }
            .padding(.leading, 18)
            DocumentTab(title: document).padding(.leading, 14)
            barButton("plus").padding(.leading, 4)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "tray.full").font(.system(size: 13))
                Text("Jobs").font(.system(size: 13))
                Text("\(jobs)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(VF.accent))
            }
            .foregroundStyle(VF.ink)
            barButton("bell").padding(.leading, 18)
            Text("JD")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(VF.accent))
                .padding(.leading, 18)
                .padding(.trailing, 16)
        }
        .frame(height: 40)
        .background(VF.chrome)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func barButton(_ symbol: String, dim: Bool = false, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(dim ? VF.secondary.opacity(0.6) : VF.ink)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12, height: 12)
            Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12, height: 12)
            Circle().fill(Color(hex: 0x28C840)).frame(width: 12, height: 12)
        }
    }
}

struct DocumentTab: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill").font(.system(size: 12)).foregroundStyle(VF.accent)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(VF.ink).lineLimit(1).fixedSize()
            Spacer(minLength: 16)
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 200).frame(height: 32).fixedSize(horizontal: true, vertical: false)
        .background(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).fill(Color.white))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).strokeBorder(VF.separator, lineWidth: 1))
        .offset(y: 4)
    }
}

// MARK: - Ribbon

struct Ribbon: View {
    let workspace: Workspace
    @Binding var tab: String
    var onWorkspace: (Workspace) -> Void = { _ in }
    var onFinish: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            WorkspaceSwitcher(workspace: workspace, onPick: onWorkspace)
                .padding(.leading, 14)
                .padding(.top, 12)
                .frame(width: 204, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                TabRow(tabs: workspace.tabs, selected: $tab)
                Hairline(color: VF.separator.opacity(0.7))
                PanelStrip(panels: workspace.panels, onFinish: onFinish)
            }
        }
        .frame(height: 140)
        .background(VF.chrome)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

struct WorkspaceSwitcher: View {
    let workspace: Workspace
    var onPick: (Workspace) -> Void

    var body: some View {
        DropMenu(items: Workspace.allCases.map { w in
            DropItem(title: w.name, symbol: w.symbol, shortcut: "\u{2318}\(w.rawValue + 1)") { onPick(w) }
        }) {
            HStack(spacing: 10) {
                Image(systemName: workspace.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(workspace.tint)
                    .frame(width: 26)
                Text(workspace.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VF.ink)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(VF.accent)
            }
            .padding(.horizontal, 12)
            .frame(width: 176, height: 44)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xC8C8C8), lineWidth: 1))
        }
    }
}

struct TabRow: View {
    let tabs: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { t in
                let on = t == selected
                Button { selected = t } label: {
                    Text(t)
                        .font(.system(size: 12, weight: .medium))
                        .kerning(0.2)
                        .foregroundStyle(on ? VF.accent : VF.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(on ? VF.accent : .clear).frame(height: 2).padding(.horizontal, 6)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 6)
        .frame(height: 38)
    }
}

/// The panel row. It never scrolls: under the available width it folds its right most panels
/// into a MORE dropdown, trying the full row first and then one fewer panel at a time.
struct PanelStrip: View {
    let panels: [RibbonPanel]
    var onFinish: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                row(panels.count)
                row(panels.count - 1)
                row(panels.count - 2)
                row(panels.count - 3)
                row(max(1, panels.count - 4))
                row(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FinishButton(action: onFinish)
                .padding(.horizontal, 18)
                .overlay(alignment: .leading) { Hairline(vertical: true).padding(.vertical, 10) }
        }
        .frame(height: 101)
    }

    @ViewBuilder
    private func row(_ count: Int) -> some View {
        let shown = Array(panels.prefix(max(1, count)))
        let hidden = Array(panels.dropFirst(max(1, count)))
        HStack(spacing: 0) {
            ForEach(shown) { p in
                PanelView(panel: p)
                    .overlay(alignment: .trailing) { Hairline(vertical: true).padding(.vertical, 10) }
            }
            if !hidden.isEmpty { OverflowPanel(hidden: hidden) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct PanelView: View {
    let panel: RibbonPanel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(panel.glyphs.enumerated()), id: \.offset) { _, g in
                    Button {} label: {
                        GlyphView(glyph: g, size: 42).frame(width: 50, height: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(ToolHover())
                }
            }
            DropMenu(items: panel.commands.map { DropItem(title: $0) }) {
                HStack(spacing: 5) {
                    Text(panel.title).font(VF.caps(12)).kerning(0.2).foregroundStyle(VF.ink)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(VF.accent)
                }
                .frame(height: 18)
            }
        }
        .padding(.horizontal, VF.panelPadding + 4)
        .padding(.top, 8)
    }
}

struct OverflowPanel: View {
    let hidden: [RibbonPanel]
    var body: some View {
        DropMenu(items: hidden.flatMap { p in p.commands.map { DropItem(title: "\(p.title.capitalized): \($0)") } }) {
            VStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(VF.ink)
                    .frame(width: 50, height: 50)
                HStack(spacing: 5) {
                    Text("MORE").font(VF.caps(12))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(VF.accent)
                }
                .frame(height: 18)
            }
            .padding(.horizontal, VF.panelPadding + 4)
            .padding(.top, 8)
        }
    }
}

struct ToolHover: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.black.opacity(0.06) : .clear))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .onHover { hover = $0 }
    }
}

struct FinishButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(VF.success)
                    Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
                .shadow(color: VF.success.opacity(0.35), radius: 4, y: 2)
                Text("FINISH").font(VF.caps(12)).foregroundStyle(VF.ink)
            }
            .padding(.top, 14)
            .frame(width: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timeline

struct TimelineBar: View {
    let features: [Sample.FeatureKind]
    @Binding var marker: Int

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                control("backward.end.fill")
                control("play.fill", size: 20)
                control("forward.end.fill")
            }
            .padding(.horizontal, 22)
            Hairline(vertical: true).padding(.vertical, 18)
            HScroll {
                FeatureRow(features: features, marker: $marker)
                    .padding(.horizontal, 14)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white).padding(.vertical, 10).padding(.horizontal, 8))
        }
        .frame(height: 110)
        .background(VF.timeline)
        .overlay(alignment: .top) { Hairline() }
    }

    private func control(_ s: String, size: CGFloat = 16) -> some View {
        Button {} label: {
            Image(systemName: s).font(.system(size: size)).foregroundStyle(Color(hex: 0x3A3A3C))
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FeatureRow: View {
    let features: [Sample.FeatureKind]
    @Binding var marker: Int
    private let cell: CGFloat = 62

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(features.enumerated()), id: \.offset) { i, f in
                VStack(spacing: 3) {
                    Text("\(i + 1)").font(.system(size: 9).monospacedDigit()).foregroundStyle(VF.secondary)
                    GlyphView(glyph: .tool(f.icon), size: 32)
                        .opacity(i < marker ? 1 : 0.32)
                        .saturation(i < marker ? 1 : 0)
                    Text(f.rawValue).font(.system(size: 10)).foregroundStyle(i < marker ? VF.ink : VF.secondary)
                }
                .frame(width: cell)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .topLeading) {
            Playhead()
                .offset(x: CGFloat(marker) * cell - 7)
                .gesture(DragGesture().onChanged { v in
                    marker = max(1, min(features.count, Int((v.location.x / cell).rounded())))
                })
        }
    }
}

struct Playhead: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 13))
                .foregroundStyle(VF.accent)
            Rectangle().fill(VF.accent).frame(width: 2, height: 68)
        }
        .frame(width: 14)
        .offset(y: 4)
        .contentShape(Rectangle())
    }
}
