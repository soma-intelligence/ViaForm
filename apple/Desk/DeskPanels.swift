#if os(macOS)
import AppKit
import SwiftUI

// MARK: Marking menu

/// The right-click wheel (M-7): eight commands on the Fusion compass around the cursor and an
/// overflow list under it. Moving the pointer toward a slice highlights its wedge and a click
/// anywhere in the wedge runs it; a right-drag flick runs a slice without the wheel
/// (`MarkingFlick`). The south slice opens the sketch submenu. Escape or a click outside closes it.
struct MarkingMenu: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let at: CGPoint
    /// The slice the pointer points at while the wheel is open.
    @State private var hover: Int?
    @State private var subOpen = false

    private let radius: CGFloat = 92
    /// Opened by the --show-marking screenshot hook: for its first 20 s a stray click on the window (the Mac
    /// is in use while the docs are captured) must not close it. Escape or a slot still does.
    private static let hookOpened = Date()
    private static var pinned: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-marking") && Date().timeIntervalSince(hookOpened) < 20
    }

    /// The highlighted slice: the flick's while a right-drag runs, else the pointer's.
    private var hot: Int? { MarkingFlick.shared.origin != nil ? MarkingFlick.shared.hot : hover }

    var body: some View {
        let wheel = MarkingWheel.slots(model)
        let overflow = MarkingWheel.overflow(model)
        ZStack {
            let _ = Self.hookOpened
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case let .active(p) = phase { hover = MarkingCompass.slice(from: at, to: p) } else { hover = nil }
                }
                .onTapGesture(coordinateSpace: .local) { p in
                    let d = hypot(p.x - at.x, p.y - at.y)
                    if d < radius * 1.6, let i = MarkingCompass.slice(from: at, to: p) { tap(wheel[i]) }
                    else if !Self.pinned { model.markingMenu = nil }
                }
            if let hot {
                MarkingCompass.wedge(hot, center: at, inner: 18, outer: radius * 0.78)
                    .fill(theme.accent.opacity(0.22))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            Circle().fill(theme.floating).frame(width: 30, height: 30)
                .overlay(Circle().stroke(theme.floatingStroke))
                .position(at)
                .accessibilityHidden(true)
            // Order: north, then clockwise.
            ForEach(Array(wheel.enumerated()), id: \.element.id) { i, slot in
                let a = -Double.pi / 2 + Double(i) * .pi / 4
                pill(slot, on: hot == i)
                    .position(x: at.x + radius * cos(a) * (i % 4 == 0 ? 1 : 1.25), y: at.y + radius * sin(a) * 0.82)
            }
            if subOpen, let south = wheel.first(where: { !$0.submenu.isEmpty }) {
                list(south.submenu)
                    .position(x: at.x + 150, y: at.y + radius * 0.82 + 20 + CGFloat(south.submenu.count) * (VFSize.macRow - 3) / 2)
            }
            list(overflow)
                .position(x: at.x, y: at.y + radius + 30 + CGFloat(overflow.count) * (VFSize.macRow - 3) / 2)
        }
        .onChange(of: model.markingMenu) { _, _ in subOpen = false }
    }

    private func list(_ slots: [MarkingSlot]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slots) { slot in
                Button { fire(slot) } label: {
                    Label { Text(slot.title) } icon: { CommandIcon(art: slot.art, symbol: slot.symbol, size: 12) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VFSpace.m).frame(minHeight: VFSize.macRow - 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!slot.enabled)
                .opacity(slot.enabled ? 1 : 0.45)
            }
        }
        .font(VFFont.row)
        .foregroundStyle(theme.ink)
        .frame(width: 190)
        .padding(.vertical, VFSpace.xs)
        .vfSurface(.floating, radius: VFRadius.card)
    }

    private func pill(_ slot: MarkingSlot, on: Bool) -> some View {
        Button { tap(slot) } label: {
            HStack(spacing: VFSpace.s) {
                CommandIcon(art: slot.art, symbol: slot.symbol, size: 12).frame(width: 20)
                Text(slot.title)
                if !slot.submenu.isEmpty {
                    Image(systemName: "chevron.down").font(VFFont.glyph(9, weight: .semibold)).accessibilityHidden(true)
                }
            }
            .font(VFFont.row)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.m).frame(minHeight: VFSize.macRow - 3)
            .vfSurface(.floating, radius: VFRadius.touchCapsule)
            .overlay(Capsule().strokeBorder(on ? theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(slot.title)
        .accessibilityHint(slot.submenu.isEmpty ? "" : String(localized: "Opens the sketch tools"))
    }

    /// A click on a slice: the submenu slice opens its list, the others run.
    private func tap(_ slot: MarkingSlot) {
        if !slot.submenu.isEmpty { subOpen.toggle(); return }
        fire(slot)
    }

    private func fire(_ slot: MarkingSlot) {
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
