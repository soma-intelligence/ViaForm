import SwiftUI

/// Shared Mac window: full-bleed viewport, glass title toolbar, optional ribbon, then the
/// workspace content laid out in the space under the chrome.
struct MacWindow<Content: View>: View {
    var project: String
    @Binding var workspace: Workspace
    var plate: PlateLayout?
    var ribbon = false
    @ViewBuilder var content: (Bool, Bool) -> Content
    @State private var showSidebar = true
    @State private var showInspector = true

    var body: some View {
        ZStack(alignment: .top) {
            ViewportBackground(plate: plate)
            VStack(spacing: 8) {
                TitleToolbar(project: project, workspace: $workspace, showSidebar: $showSidebar, showInspector: $showInspector)
                if ribbon { Ribbon() }
                content(showSidebar, showInspector)
            }
            .padding(Tok.inset)
        }
        .workspaceAccent(workspace)
        .environment(\.backdrop, plate)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Sample data

enum HandData {
    static let tree: [TreeRow] = [
        TreeRow(level: 0, label: "Hand Assembly v4", tool: "component", expanded: true),
        TreeRow(level: 1, label: "Palm", symbol: "folder", expanded: true),
        TreeRow(level: 1, label: "Index Finger", tool: "component", expanded: true, selected: true),
        TreeRow(level: 2, label: "Proximal", tool: "box", expanded: false),
        TreeRow(level: 2, label: "Middle", tool: "box", expanded: false),
        TreeRow(level: 2, label: "Distal", tool: "box", expanded: false),
        TreeRow(level: 2, label: "Joint MCP", tool: "joint", expanded: false),
        TreeRow(level: 2, label: "Joint PIP", tool: "joint", expanded: false),
        TreeRow(level: 2, label: "Joint DIP", tool: "joint", expanded: false),
        TreeRow(level: 2, label: "Motor M1", tool: "cylinder"),
        TreeRow(level: 2, label: "Motor M2", tool: "cylinder"),
        TreeRow(level: 2, label: "Motor M3", tool: "cylinder"),
        TreeRow(level: 1, label: "Middle Finger", symbol: "folder", expanded: false),
        TreeRow(level: 1, label: "Ring Finger", symbol: "folder", expanded: false),
        TreeRow(level: 1, label: "Little Finger", symbol: "folder", expanded: false),
        TreeRow(level: 1, label: "Thumb", symbol: "folder", expanded: false),
        TreeRow(level: 1, label: "Wrist", tool: "component", expanded: false),
        TreeRow(level: 1, label: "Tendons", tool: "rigid_group", expanded: false),
        TreeRow(level: 0, label: "Origin", symbol: "scope", expanded: false),
    ]
    static let timeline = ["sketch", "extrude", "revolve", "fillet", "shell", "combine", "joint", "presspull",
                           "chamfer", "joint", "rigid_group", "cylinder", "box", "mount", "fastener", "joint"]
}

// MARK: - Design workspace

struct DesignScreen: View {
    @Binding var workspace: Workspace
    @State private var angle = 42.0
    @State private var playhead = 7
    static let plate = PlateLayout(name: "hand", zoom: 0.84, shift: CGSize(width: 0, height: 66))

    var body: some View {
        MacWindow(project: "Humanoid Hand", workspace: $workspace, plate: Self.plate, ribbon: true) { sidebar, inspector in
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 0) {
                    if sidebar { browser.transition(.move(edge: .leading).combined(with: .opacity)) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            ViewCube(size: 108).padding(.top, 4)
                            if inspector { JointInspector().transition(.move(edge: .trailing).combined(with: .opacity)) }
                        }
                    }
                }
                Spacer(minLength: 0)
                NavCapsule()
                TimelineStrip(icons: HandData.timeline, playhead: $playhead)
            }
        }
        .overlay { selectionOverlay }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browser").font(Tok.title).foregroundStyle(Tok.primary)
                Spacer()
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12)).foregroundStyle(Tok.secondary)
            }
            .padding(.horizontal, Tok.pad).frame(height: 42)
            Hairline()
            VStack(spacing: 1) { ForEach(HandData.tree) { TreeRowView(row: $0) } }
                .padding(.vertical, 6)
        }
        .frame(width: 280)
        .glass()
    }

    /// Value chip and context pill, positioned from the projected selection anchor.
    private var selectionOverlay: some View {
        GeometryReader { geo in
            let gizmo = Self.plate.project(CGPoint(x: 690, y: 268), in: geo.size)
            ValueChip(value: $angle, unit: "deg")
                .position(x: gizmo.x + 50, y: gizmo.y + 6)
            ContextMenuPill(items: [("fillet", "Fillet"), ("joint", "Drive joint"), ("cylinder", "Edit motor")])
                .position(x: gizmo.x + 176, y: gizmo.y - 46)
        }
        .workspaceAccent(workspace)
    }
}

struct JointInspector: View {
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tool: "joint", title: "Joint PIP \u{00B7} Index", close: true)
            Hairline()
            VStack(spacing: 0) {
                KVRow(key: "Type", value: "Revolute", mono: false, picker: true)
                KVRow(key: "Limits", value: "0 to 95 deg", picker: true)
                KVRow(key: "Drive", value: "42.0 deg")
            }.padding(.vertical, 6)
            Hairline()
            VStack(spacing: 0) {
                KVRow(key: "Motor", value: "M2 Micro BLDC 12 mm", mono: false, picker: true)
                KVRow(key: "Torque", value: "0.18 N m")
                KVRow(key: "Gear", value: "1:64")
                KVRow(key: "Speed", value: "120 deg/s")
            }.padding(.vertical, 6)
            Hairline()
            VStack(spacing: 0) {
                KVRow(key: "Material", value: "PA12 lattice", picker: true)
                KVRow(key: "Mass", value: "6.4 g")
            }.padding(.vertical, 6)
            HStack(spacing: 8) {
                SecondaryButton(title: "Cancel")
                PrimaryButton(title: "Apply")
            }
            .padding(Tok.pad)
        }
        .frame(width: 300)
        .glass()
    }
}

struct TimelineStrip: View {
    var icons: [String]
    @Binding var playhead: Int
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ChromeButton(symbol: "backward.end.fill", size: 28)
                ChromeButton(symbol: "play.fill", size: 28)
                ChromeButton(symbol: "forward.end.fill", size: 28)
            }
            .padding(.horizontal, 10)
            Rectangle().fill(Tok.hairline).frame(width: 1, height: 36)
            GeometryReader { geo in
                let step = (geo.size.width - 40) / CGFloat(icons.count - 1)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                        .offset(x: 20, y: 35).frame(width: geo.size.width - 40)
                    Rectangle().fill(accent.opacity(0.8)).frame(width: step * CGFloat(playhead - 1), height: 2)
                        .offset(x: 20, y: 34.5)
                    ForEach(Array(icons.enumerated()), id: \.offset) { i, t in
                        let n = i + 1
                        VStack(spacing: 3) {
                            Text("\(n)").font(Tok.mono(10, n == playhead ? .bold : .regular))
                                .foregroundStyle(n == playhead ? accent : Tok.secondary)
                            Asset.tool(t).resizable().interpolation(.high).frame(width: 24, height: 24)
                                .padding(3)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0x23262C)))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(n == playhead ? accent : .white.opacity(0.10), lineWidth: n == playhead ? 1.5 : 1))
                                .opacity(n > playhead ? 0.38 : 1)
                        }
                        .position(x: 20 + step * CGFloat(i), y: 30)
                        .onTapGesture { withAnimation(.snappy) { playhead = n } }
                    }
                    // Playhead marker: drag rolls the model back to that feature.
                    VStack(spacing: 0) {
                        Capsule().fill(accent).frame(width: 2, height: 10)
                        Circle().fill(accent).frame(width: 9, height: 9).shadow(color: accent, radius: 4)
                    }
                    .position(x: 20 + step * CGFloat(playhead - 1), y: 58)
                }
            }
            .padding(.horizontal, 8)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.secondary)
                .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.06))).padding(.trailing, 12)
        }
        .frame(height: 68)
        .glass()
    }
}
