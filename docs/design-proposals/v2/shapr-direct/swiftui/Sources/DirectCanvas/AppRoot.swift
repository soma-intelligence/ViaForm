import SwiftUI

/// Interactive root: switches the workspace screen, owns keyboard shortcuts.
/// ⌘1 to ⌘8 workspaces, ⌘K command search, E F M J tool keys, Esc closes the palette.
struct RootView: View {
    @Bindable var studio: Studio

    var body: some View {
        screen
            .background(KeyCatcher(studio: studio))
            .ignoresSafeArea()
    }

    @ViewBuilder var screen: some View {
        switch studio.workspace {
        case .design: DesignScreen(studio: studio)
        case .generative: GenerativeScreen(studio: studio)
        case .simulation: SimulationScreen(studio: studio)
        case .electronics: ElectronicsScreen(studio: studio)
        default: WorkspaceStub(studio: studio)
        }
    }
}

/// Hidden buttons carrying the keyboard shortcuts.
struct KeyCatcher: View {
    @Bindable var studio: Studio
    var body: some View {
        ZStack {
            ForEach(Workspace.allCases) { w in
                Button("") { studio.workspace = w }.keyboardShortcut(w.shortcut, modifiers: .command)
            }
            Button("") { studio.palette.toggle() }.keyboardShortcut("k", modifiers: .command)
            Button("") { studio.palette = false }.keyboardShortcut(.escape, modifiers: [])
            ForEach([("e", "extrude"), ("f", "fillet"), ("m", "move"), ("j", "joint")], id: \.0) { k in
                Button("") { if !studio.palette { studio.activeTool[.design] = k.1 } }
                    .keyboardShortcut(KeyEquivalent(Character(k.0)), modifiers: [])
            }
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }
}

/// Mechanics, Training, Render and Manufacture share the same chrome; only the rail changes.
struct WorkspaceStub: View {
    @Bindable var studio: Studio
    var body: some View {
        MacShell(studio: studio, title: studio.workspace == .mechanics ? "Robotic Hand v3" : "Racer 3in") { cs in
            ZStack(alignment: .topLeading) {
                ModelImage(name: studio.workspace == .mechanics ? "hand_design" : "frame_stress",
                           rect: studio.workspace == .mechanics ? cs.rect(385, 172, 945, 912) : cs.rect(220, 150, 1085, 712))
                ToolRail(tools: Rails.mechanics, active: studio.activeTool[.mechanics] ?? "joint")
                    .padding(.leading, 16).padding(.top, 136)
                RightColumn {
                    ItemsHistoryCard(mode: $studio.sidebar, items: Sample.handItems, history: Sample.handHistory, selected: studio.selection)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(studio.workspace.rawValue).font(.system(size: 17, weight: .semibold))
                        Text("Same floating chrome, workspace tools in the rail.").font(.system(size: 13)).foregroundStyle(VF.secondary)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
                }
                ViewCubeSlot()
                BottomFurniture()
            }
        }
    }
}

/// Spotlight-style command search (⌘K).
struct CommandPalette: View {
    @Bindable var studio: Studio
    var body: some View {
        let q = studio.paletteQuery.lowercased()
        let hits = Sample.commands.filter { q.isEmpty || $0.0.lowercased().contains(q) }
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).onTapGesture { studio.palette = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(VF.secondary)
                    if studio.rendering {
                        HStack(spacing: 1) {
                            Rectangle().fill(VF.accent).frame(width: 2, height: 22)
                            Text("Search commands").foregroundStyle(VF.secondary)
                        }
                        .font(.system(size: 18))
                        Spacer()
                        Text("esc").font(.system(size: 11, weight: .medium)).foregroundStyle(VF.secondary)
                            .padding(.horizontal, 6).frame(height: 20).background(RoundedRectangle(cornerRadius: 5).fill(VF.track))
                    } else {
                        TextField("Search commands", text: $studio.paletteQuery)
                            .textFieldStyle(.plain).font(.system(size: 18))
                    }
                }
                .padding(.horizontal, 18).frame(height: 54)
                CardDivider()
                VStack(spacing: 2) {
                    ForEach(Array(hits.prefix(7).enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 12) {
                            Glyph(name: c.1, size: 15).frame(width: 22)
                            Text(c.0).font(.system(size: 14))
                            Spacer()
                            if !c.2.isEmpty {
                                Text(c.2).font(.system(size: 12, weight: .medium)).foregroundStyle(i == 0 ? .white : VF.secondary)
                                    .frame(width: 22, height: 20)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(i == 0 ? .white.opacity(0.2) : VF.track))
                            }
                        }
                        .foregroundStyle(i == 0 ? .white : VF.text)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(i == 0 ? VF.accent : .clear))
                    }
                }
                .padding(8)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
            .card(16)
            .padding(.top, 120)
        }
    }
}
