import SwiftUI

/// iPad layout rendered at 1366 x 1024 on the Mac (the real one lives in apple/Touch).
/// Same glass language, larger targets: 56 pt round buttons, 64 pt tool cells, 64 pt sheet rows.
struct IPadHandScreen: View {
    @State private var workspace: Workspace = .design
    @State private var angle = 35.0
    @State private var tool = "joint"
    static let plate = PlateLayout(name: "ipadhand", zoom: 0.92, shift: CGSize(width: -150, height: 80))

    var body: some View {
        ZStack(alignment: .top) {
            ViewportBackground(plate: Self.plate)
            VStack(spacing: 0) {
                statusBar
                topRow.padding(.horizontal, 20).padding(.top, 6)
                HStack(alignment: .top, spacing: 0) {
                    toolColumn
                    Spacer()
                    JointSheet().padding(.top, 40)
                }
                .padding(.horizontal, 20).padding(.top, 34)
                Spacer()
                StatusCapsule {
                    Text("Hand Assembly v4").font(.system(size: 15, weight: .medium))
                    Dot()
                    Text("21 joints").font(.system(size: 15, design: .monospaced))
                    Dot()
                    Text("21 motors").font(.system(size: 15, design: .monospaced))
                }
                .scaleEffect(1.12)
                .padding(.bottom, 30)
            }
            selectionOverlay
        }
        .workspaceAccent(workspace)
        .environment(\.backdrop, Self.plate)
        .environment(\.windowSize, CGSize(width: 1366, height: 1024))
        .preferredColorScheme(.dark)
    }

    private var statusBar: some View {
        HStack {
            Text("9:41").font(.system(size: 15, weight: .semibold))
            Text("Tue Apr 22").font(.system(size: 15, weight: .medium))
            Spacer()
            Image(systemName: "cellularbars"); Image(systemName: "wifi")
            Text("100%").font(.system(size: 14, weight: .medium))
            Image(systemName: "battery.100percent")
        }
        .foregroundStyle(Tok.primary).font(.system(size: 14))
        .padding(.horizontal, 28).frame(height: 30)
    }

    private func round(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 21, weight: .regular)).foregroundStyle(Tok.primary)
            .frame(width: 56, height: 56).glassCircle()
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            round("sidebar.left"); round("arrow.uturn.backward"); round("arrow.uturn.forward")
            Spacer()
            WorkspaceCapsule(selection: $workspace, touch: true).glassCapsule(tint: 0.5)
            Spacer()
            round("cube"); round("clock.arrow.circlepath"); round("square.and.arrow.up")
            ViewCube(size: 76)
        }
    }

    private var toolColumn: some View {
        VStack(spacing: 6) {
            ForEach([("sketch", "Sketch"), ("extrude", "Extrude"), ("fillet", "Fillet"), ("shell", "Shell"),
                     ("joint", "Joint"), ("cylinder", "Motor"), ("measure", "Measure")], id: \.0) { t, label in
                ToolCell(tool: t, label: label, selected: t == tool).onTapGesture { tool = t }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .glass(26)
    }

    /// Suggestion bar, drag arrow value bubble: placed from the projected thumb anchor.
    private var selectionOverlay: some View {
        GeometryReader { geo in
            let arrow = Self.plate.project(CGPoint(x: 1124, y: 376), in: geo.size)
            SuggestionBar()
                .position(x: arrow.x - 300, y: arrow.y - 228)
            ValueChip(value: $angle, unit: "deg", large: true)
                .position(x: arrow.x + 34, y: arrow.y - 112)
        }
    }
}

struct ToolCell: View {
    var tool: String
    var label: String
    var selected: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 5) {
            Asset.tool(tool).resizable().interpolation(.high)
                .frame(width: 34, height: 34)
                .frame(width: 56, height: 56)
                .background(Circle().fill(selected ? accent : Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.3 : 0.10), lineWidth: 1))
                .shadow(color: selected ? accent.opacity(0.5) : .clear, radius: 10)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Tok.primary)
        }
        .frame(width: 72, height: 86)
    }
}

/// Adaptive suggestions for the current selection (a revolute joint): big pills, first one filled.
struct SuggestionBar: View {
    @Environment(\.accent) private var accent
    @Environment(\.onAccent) private var onAccent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array([("dial.medium", "Drive joint"), ("gauge.with.dots.needle.33percent", "Set limits"),
                           ("arrow.left.arrow.right", "Swap motor"), ("square.on.square.dashed", "Fillet")].enumerated()),
                    id: \.offset) { i, s in
                VStack(spacing: 6) {
                    Image(systemName: s.0).font(.system(size: 21, weight: .medium))
                    Text(s.1).font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(i == 0 ? onAccent : Tok.primary)
                .frame(width: 112, height: 74)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(i == 0 ? accent : Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(i == 0 ? 0.25 : 0.10), lineWidth: 1))
            }
        }
        .padding(7)
        .glass(22)
    }
}

struct JointSheet: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Asset.tool("joint").resizable().frame(width: 30, height: 30)
                Text("Thumb CMC joint").font(.system(size: 20, weight: .semibold)).foregroundStyle(Tok.primary)
                Spacer()
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Tok.secondary)
                    .frame(width: 32, height: 32).background(Circle().fill(.white.opacity(0.08)))
            }
            .padding(.horizontal, 6)
            VStack(spacing: 0) {
                ForEach(Array([("Type", "Revolute", false), ("Range", "0 to 70 deg", true), ("Drive", "35.0 deg", true),
                               ("Motor", "Micro BLDC 12 mm", false), ("Torque", "0.22 N m", true), ("Gear", "1:64", true)].enumerated()),
                        id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(Tok.hairline).frame(height: 1).padding(.leading, 18) }
                    HStack {
                        Text(r.0).font(.system(size: 17)).foregroundStyle(Tok.primary)
                        Spacer()
                        Text(r.1).font(r.2 ? .system(size: 16, design: .monospaced) : .system(size: 17)).foregroundStyle(Tok.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tok.tertiary)
                    }
                    .padding(.horizontal, 18).frame(height: 60)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            PrimaryButton(title: "Done", height: 54)
        }
        .padding(16).frame(width: 360)
        .glass(26)
    }
}
