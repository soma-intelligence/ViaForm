#if os(macOS)
import AppKit
import SwiftUI

// MARK: Marking menu

/// The right-click wheel: eight commands around the cursor and an overflow list under it.
/// Drag or click toward a slice to run it; Escape or a click outside closes it.
struct MarkingMenu: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let at: CGPoint

    private struct Slot: Identifiable {
        let id: String
        let symbol: String
        var art: String? = nil
        let run: (DesignModel) -> Void

        init(id: String, tool: Tool, run: @escaping (DesignModel) -> Void) {
            self.init(id: id, symbol: tool.symbol, art: ToolIcons.art(for: tool), run: run)
        }

        init(id: String, symbol: String, art: String? = nil, run: @escaping (DesignModel) -> Void) {
            self.id = id; self.symbol = symbol; self.art = art; self.run = run
        }
    }

    private var wheel: [Slot] {
        if model.sketchOpen {
            return [
                Slot(id: "Line", tool: .line) { $0.tool = .line },
                Slot(id: "Finish Sketch", symbol: "checkmark.circle") { $0.finishSketch() },
                Slot(id: "Rectangle", tool: .rectangle) { $0.tool = .rectangle },
                Slot(id: "Redo", symbol: "arrow.uturn.forward") { $0.redo() },
                Slot(id: "Trim", tool: .trim) { $0.tool = .trim },
                Slot(id: "Delete", tool: .delete) { $0.deleteSelection() },
                Slot(id: "Circle", tool: .circle) { $0.tool = .circle },
                Slot(id: "Undo", symbol: "arrow.uturn.backward") { $0.undo() },
            ]
        }
        return [
            Slot(id: "Sketch", tool: .sketch) { m in
                if m.selection.contains(where: \.isFace) { m.sketchOnSelectedFace() } else { m.tool = .sketch }
            },
            Slot(id: "Push / Pull", tool: .pressPull) { $0.tool = .pressPull },
            Slot(id: "Extrude", tool: .extrude) { $0.tool = .extrude },
            Slot(id: "Redo", symbol: "arrow.uturn.forward") { $0.redo() },
            Slot(id: "Move", tool: .move) { $0.tool = .move },
            Slot(id: "Delete", tool: .delete) { $0.deleteSelection() },
            Slot(id: "Fillet", tool: .fillet) { $0.tool = .fillet },
            Slot(id: "Undo", symbol: "arrow.uturn.backward") { $0.undo() },
        ]
    }

    private var overflow: [Slot] {
        [
            Slot(id: "Repeat Last", symbol: "repeat") { m in if let t = m.lastTool { m.tool = t } },
            Slot(id: "Fit", symbol: "arrow.up.left.and.down.right.magnifyingglass") { $0.zoomToFit() },
            Slot(id: "Measure", tool: .measure) { $0.measureSelection() },
            Slot(id: "Toolbox Search", symbol: "magnifyingglass") { $0.toolboxOpen = true },
        ]
    }

    private let radius: CGFloat = 92
    /// Opened by the --show-marking screenshot hook: for its first 20 s a stray click on the window (the Mac
    /// is in use while the docs are captured) must not close it. Escape or a slot still does.
    private static let hookOpened = Date()
    private static var pinned: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-marking") && Date().timeIntervalSince(hookOpened) < 20
    }

    var body: some View {
        ZStack {
            let _ = Self.hookOpened
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if !Self.pinned { model.markingMenu = nil } }
            Circle().fill(theme.floating).frame(width: 30, height: 30)
                .overlay(Circle().stroke(theme.floatingStroke))
                .position(at)
                .accessibilityHidden(true)
            // Order: top, top right, right, bottom right, bottom, bottom left, left, top left.
            ForEach(Array(wheel.enumerated()), id: \.element.id) { i, slot in
                let a = -Double.pi / 2 + Double(i) * .pi / 4
                pill(slot)
                    .position(x: at.x + radius * cos(a) * (i % 4 == 0 ? 1 : 1.25), y: at.y + radius * sin(a) * 0.82)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(overflow) { slot in
                    Button { fire(slot) } label: {
                        Label { Text(LocalizedStringKey(slot.id)) } icon: { CommandIcon(art: slot.art, symbol: slot.symbol, size: 12) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, VFSpace.m).frame(minHeight: VFSize.macRow - 3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(VFFont.row)
            .foregroundStyle(theme.ink)
            .frame(width: 170)
            .padding(.vertical, VFSpace.xs)
            .vfSurface(.floating, radius: VFRadius.card)
            .position(x: at.x, y: at.y + radius + 74)
        }
    }

    private func pill(_ slot: Slot) -> some View {
        Button { fire(slot) } label: {
            HStack(spacing: VFSpace.s) {
                CommandIcon(art: slot.art, symbol: slot.symbol, size: 12).frame(width: 20)
                Text(LocalizedStringKey(slot.id))
            }
            .font(VFFont.row)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.m).frame(minHeight: VFSize.macRow - 3)
            .vfSurface(.floating, radius: VFRadius.touchCapsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func fire(_ slot: Slot) {
        model.markingMenu = nil
        slot.run(model)
    }
}

// MARK: Toolbox search

/// S opens a search over every registry command; Return runs the first match.
struct ToolboxSearch: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [CommandInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(model.commands.filter { $0.key != nil }.prefix(12)) }
        return Array(model.commands.filter {
            $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q) || $0.panel.lowercased().contains(q)
        }.prefix(14))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VFSpace.m) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(VFFont.title.weight(.regular))
                    .focused($focused)
                    .onSubmit { if let c = matches.first { run(c) } }
                    .onExitCommand { close() }
            }
            .padding(.horizontal, VFSpace.l).frame(height: 40)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if matches.isEmpty {
                        Text("No command matches “\(query)”").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                            .frame(maxWidth: .infinity).padding(VFSpace.l)
                    }
                    ForEach(matches) { c in
                        Button { run(c) } label: {
                            HStack(spacing: VFSpace.m) {
                                CommandIcon(icon: c.icon, id: c.id, size: 13).frame(width: 22)
                                Text(StageLabels.command(c.label))
                                Spacer()
                                Text("\(c.tab.capitalized) · \(c.panel.capitalized)").foregroundStyle(theme.inkSecondary).font(VFFont.small)
                                if let k = c.key { Text(k).font(VFFont.mono).foregroundStyle(theme.inkSecondary) }
                            }
                            .font(VFFont.row)
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, VFSpace.l).frame(minHeight: VFSize.macRow).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 520)
        .vfSurface(.floating, radius: VFRadius.floating)
        .onAppear { focused = true }
    }

    private func run(_ c: CommandInfo) {
        close()
        CommandRouter.run(c, model)
    }

    private func close() {
        query = ""
        model.toolboxOpen = false
    }
}

// MARK: Data panel

/// The slide-in file panel: new design, the sample and the recent files.
struct DataPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @Binding var shown: Bool

    var body: some View {
        let recents = NSDocumentController.shared.recentDocumentURLs
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Data").font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
                VFIconButton("xmark", label: String(localized: "Close the Data panel")) { shown = false }
            }
            .padding(VFSpace.l)
            Divider()
            HStack(spacing: VFSpace.m) {
                Button("New Design") { FileActions.newDesign(model); shown = false }
                Button("Open…") { FileActions.open(model); shown = false }
            }
            .buttonStyle(.vfSecondary)
            .padding(VFSpace.l)
            VFCaption(String(localized: "Samples")).padding(.horizontal, VFSpace.l)
            tile(String(localized: "Bracket"), "cube.fill") { model.loadSample(); shown = false }
            VFCaption(String(localized: "Recent")).padding(.horizontal, VFSpace.l).padding(.top, VFSpace.m)
            if recents.isEmpty {
                Text("Designs you open or save show here.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, VFSpace.l).padding(.top, VFSpace.xs)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recents, id: \.self) { url in
                        tile(url.deletingPathExtension().lastPathComponent, "doc") { FileActions.open(url, model); shown = false }
                            .help(url.path)
                    }
                }
            }
            Spacer()
        }
        .frame(width: 260)
        .background(theme.panel)
    }

    private func tile(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: VFSpace.m) {
                Image(systemName: symbol)
                    .font(VFFont.glyph(18))
                    .foregroundStyle(theme.inkSecondary)
                    .frame(width: 44, height: 34)
                    .background(theme.well, in: RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous))
                Text(name).font(VFFont.row).foregroundStyle(theme.ink).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.xs).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
