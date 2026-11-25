#if os(iOS)
import SwiftUI
import UIKit

// The iPad's top capsule: the workspace dropdown button, title and revision, undo and redo, the
// Items | History switch, the jobs and share buttons (VIAFORM-SPEC 6.2, no pipeline strip).
// Every target is 44 points or more.

/// The name a tool shows on touch screens (no other product's command names).
extension Tool {
    var touchLabel: String {
        switch self {
        case .pressPull: String(localized: "Push / Pull")
        case .centerRectangle: String(localized: "Center Rect")
        default: label
        }
    }
}

/// Which card sits on the right: the stage's inspector, the items or the history.
enum TouchSideCard: String, CaseIterable, Identifiable {
    case items = "Items", history = "History"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .items: String(localized: "Items")
        case .history: String(localized: "History")
        }
    }

    var symbol: String { self == .items ? "square.3.layers.3d" : "clock.arrow.circlepath" }
}

// MARK: - Undo target

/// What the open stage undoes on the iPad: the design (Design, Assemble, Render, Make), the board
/// (Electronics) or the study (Generate). Other stages have no stack and say so.
struct TouchUndoTarget {
    var canUndo = false
    var canRedo = false
    /// "Extrude": the button reads "Undo Extrude".
    var undoName: String?
    var undo: () -> Void = {}
    var redo: () -> Void = {}

    static var none: TouchUndoTarget { TouchUndoTarget() }
}

/// The first responder of the key window, to leave Command-Z to a text field that is editing.
@MainActor
enum TouchResponder {
    fileprivate static var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.vfCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }

    /// A text field or text view has the keyboard focus.
    static var isEditingText: Bool {
        let r = current
        return r is UITextField || r is UITextView
    }

    /// Sends undo or redo to the editing field's own undo manager.
    static func textUndo(redo: Bool) {
        guard let manager = current?.undoManager else { return }
        if redo { if manager.canRedo { manager.redo() } } else if manager.canUndo { manager.undo() }
    }

    /// Ends editing so the field commits its value.
    static func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// A sheet, popover or alert is up over the window that holds `view`.
    static func isPresenting(in window: UIWindow?) -> Bool {
        window?.rootViewController?.presentedViewController != nil
    }
}

extension UIResponder {
    @objc fileprivate func vfCaptureFirstResponder(_ sender: Any?) {
        TouchResponder.found = self
    }
}

// MARK: - Bar button

/// A round 44 point button of the top capsule.
struct TouchBarButton: View {
    @Environment(\.viaFormTheme) private var theme
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(VFFont.glyph(17, weight: .medium))
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                .foregroundStyle(on ? theme.accentText : theme.ink)
                .background(on ? theme.accent.opacity(0.14) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.vfTouch)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct TouchTopCapsule: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: Workspace
    let title: String
    let undoTarget: TouchUndoTarget
    var compact = false
    @Binding var side: TouchSideCard?
    /// Items | History only where there is a design to list.
    var showsSideSwitch = true
    let open: (Workspace) -> Void
    let undo: () -> Void
    let redo: () -> Void
    let showBrowser: () -> Void
    let showPalette: () -> Void
    let share: AnyView
    /// The workspace dropdown is open (tap, or Command-0 on a hardware keyboard).
    @Binding var workspacesOpen: Bool

    var body: some View {
        Group {
            if compact {
                compactRow
            } else {
                // Wide first, then Items | History in a menu.
                ViewThatFits(in: .horizontal) {
                    row(switchInline: true)
                    row(switchInline: false)
                }
            }
        }
        .padding(.horizontal, VFSpace.s)
        .frame(minHeight: 56)
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }

    private var undoLabel: String {
        if let n = undoTarget.undoName, undoTarget.canUndo { return String(localized: "Undo \(n)") }
        return String(localized: "Undo")
    }

    private func row(switchInline: Bool) -> some View {
        HStack(spacing: VFSpace.xs) {
            TouchWorkspaceButton(flow: flow, stage: stage, compact: compact, isOpen: $workspacesOpen, open: open)
            TouchBarButton(symbol: "sidebar.left", label: String(localized: "Browser"), action: showBrowser)
            titleBlock
            TouchBarButton(symbol: "arrow.uturn.backward", label: undoLabel, action: undo)
                .vfDisabled(!undoTarget.canUndo, reason: String(localized: "Nothing to undo in \(stage.title)"))
            TouchBarButton(symbol: "arrow.uturn.forward", label: String(localized: "Redo"), action: redo)
                .vfDisabled(!undoTarget.canRedo, reason: String(localized: "Nothing to redo in \(stage.title)"))
            Spacer(minLength: VFSpace.xs)
            if showsSideSwitch {
                if switchInline { sideSwitch.fixedSize() } else { sideMenu }
            }
            TouchBarButton(symbol: "magnifyingglass", label: String(localized: "Commands"), action: showPalette)
            TouchJobsButton(flow: flow)
            share
        }
    }

    /// The iPhone bar fits its width: the stage, the title (it truncates), Undo, Redo, Share
    /// and one menu with the rest (Browser, Items, History, Commands). Nothing runs off screen.
    private var compactRow: some View {
        HStack(spacing: 0) {
            TouchWorkspaceButton(flow: flow, stage: stage, compact: true, isOpen: $workspacesOpen, open: open)
            Text(title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, VFSpace.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                .accessibilityAddTraits(.isHeader)
            TouchBarButton(symbol: "arrow.uturn.backward", label: undoLabel, action: undo)
                .vfDisabled(!undoTarget.canUndo, reason: String(localized: "Nothing to undo in \(stage.title)"))
            TouchBarButton(symbol: "arrow.uturn.forward", label: String(localized: "Redo"), action: redo)
                .vfDisabled(!undoTarget.canRedo, reason: String(localized: "Nothing to redo in \(stage.title)"))
            if !flow.queue.isEmpty { TouchJobsButton(flow: flow) }
            share
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Browser", systemImage: "sidebar.left", action: showBrowser)
            if showsSideSwitch {
                ForEach(TouchSideCard.allCases) { c in
                    Button { side = side == c ? nil : c } label: { Label(c.title, systemImage: side == c ? "checkmark" : c.symbol) }
                }
            }
            Divider()
            Button("Commands", systemImage: "magnifyingglass", action: showPalette)
        } label: {
            Image(systemName: "ellipsis.circle").font(VFFont.glyph(19, weight: .medium))
                .foregroundStyle(side == nil ? theme.ink : theme.accentText)
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget).contentShape(Rectangle())
        }
        .accessibilityLabel(Text("More"))
    }

    private var sideMenu: some View {
        Menu {
            ForEach(TouchSideCard.allCases) { c in
                Button { side = side == c ? nil : c } label: { Label(c.title, systemImage: side == c ? "checkmark" : c.symbol) }
            }
        } label: {
            Image(systemName: "square.3.layers.3d").font(VFFont.glyph(17, weight: .medium))
                .foregroundStyle(side == nil ? theme.ink : theme.accentText)
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget).contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("Items or History"))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(VFFont.title).foregroundStyle(theme.ink).lineLimit(1)
            if let rev = flow.revisionName(of: stage.stage) ?? flow.revisionName(of: "design") {
                Text(rev).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, VFSpace.s)
        .frame(minWidth: compact ? 80 : 140, maxWidth: compact ? 120 : 210, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Items | History as a two-segment switch; tapping the open one closes it.
    private var sideSwitch: some View {
        HStack(spacing: 0) {
            ForEach(TouchSideCard.allCases) { c in
                let on = side == c
                Button { side = on ? nil : c } label: {
                    Text(c.title).font(on ? VFFont.rowEmphasis : VFFont.row)
                        .foregroundStyle(on ? theme.onAccent : theme.ink)
                        .padding(.horizontal, VFSpace.l)
                        .frame(minWidth: 64, minHeight: VFSize.touchTarget)
                        .background(on ? theme.accent : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.vfTouch)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(VFSpace.xxs)
        .background(theme.well, in: Capsule())
    }
}

/// The workspace dropdown on touch: the open stage's icon in its accent, its name, a chevron and
/// the attention badge. It opens the same rows as the Mac (VIAFORM-SPEC 6.0) as a popover on the
/// iPad and a sheet on the iPhone.
struct TouchWorkspaceButton: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: Workspace
    var compact = false
    /// The iPad design screen's rail row: the workspace icon on its tile and its name floating
    /// beside it ("Modeling"), no capsule.
    var plain = false
    @Binding var isOpen: Bool
    let open: (Workspace) -> Void
    @State private var showGraph = false

    /// The rail's name for the stage: the 3D design is the Modeling workspace.
    static func railTitle(_ stage: Workspace) -> String {
        stage == .design ? String(localized: "Modeling") : stage.title
    }

    var body: some View {
        let badge = WorkspaceMenu.badge(flow, current: stage)
        Button { isOpen = true } label: {
            if plain {
                TouchRailRow(symbol: stage.symbol, title: Self.railTitle(stage), tint: theme.stageFill(stage.vfStage))
                    .overlay(alignment: .topLeading) { WorkspaceBadgeView(badge: badge, size: 15).offset(x: 30, y: 2) }
            } else {
                capsule(badge)
            }
        }
        .modifier(TouchRailPress(rail: plain))
        .accessibilityLabel(WorkspaceMenu.spoken(current: stage, badge: badge))
        .accessibilityHint(Text("Opens the list of stages"))
        .modifier(TouchWorkspacePresenter(compact: compact, isOpen: $isOpen) { menu })
        .sheet(isPresented: $showGraph) { graphSheet }
    }

    private var graphSheet: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                FlowGraphView(flow: flow, current: stage, open: { w in showGraph = false; open(w) })
            }
            .navigationTitle(Text("Flow"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGraph = false } } }
        }
        .viaFormTheme()
    }

    private func capsule(_ badge: WorkspaceBadge) -> some View {
            HStack(spacing: VFSpace.s) {
                Image(systemName: stage.symbol).font(VFFont.glyph(17, weight: .medium))
                    .foregroundStyle(theme.stageFill(stage.vfStage))
                if !compact {
                    Text(stage.title.uppercased()).font(VFFont.caps).tracking(VFTypeScale.capsTracking)
                        .foregroundStyle(theme.ink).fixedSize()
                }
                Image(systemName: "chevron.down").font(VFFont.glyph(10, weight: .bold)).foregroundStyle(theme.inkSecondary)
            }
            .padding(.horizontal, VFSpace.l)
            .frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)
            .background(Capsule().fill(theme.well))
            .overlay(alignment: .topTrailing) { WorkspaceBadgeView(badge: badge, size: 17).offset(x: 4, y: -2) }
            .contentShape(Capsule())
    }

    private var list: some View {
        WorkspaceMenuList(flow: flow, current: stage, touch: true,
                          open: { w in isOpen = false; open(w) },
                          updateAll: nil,
                          showFlow: {
                              isOpen = false
                              Task { @MainActor in
                                  try? await Task.sleep(for: .milliseconds(350))
                                  showGraph = true
                              }
                          },
                          close: { isOpen = false })
    }

    /// Sized to its rows (no empty band under the footer, P3-8); scrolls only when the window is
    /// too short for them (Stage Manager, Split View).
    private var menu: some View {
        ViewThatFits(in: .vertical) {
            list
            ScrollView { list }
        }
        .frame(minWidth: compact ? nil : 380, idealWidth: compact ? nil : 380, maxWidth: compact ? nil : 380)
        .background(theme.panel)
    }
}

/// A popover on the iPad, a sheet with detents on the iPhone.
private struct TouchWorkspacePresenter<Menu: View>: ViewModifier {
    let compact: Bool
    @Binding var isOpen: Bool
    @ViewBuilder var menu: () -> Menu

    func body(content: Content) -> some View {
        if compact {
            content.sheet(isPresented: $isOpen) {
                menu().presentationDetents([.medium, .large]).presentationDragIndicator(.visible).viaFormTheme()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--landscape-render") {
            // The screenshot harness turns the shell a quarter; a popover lives in its own
            // window and would not turn with it, so the menu is drawn in place.
            content.overlay(alignment: .topLeading) {
                if isOpen {
                    menu().frame(width: 380).frame(maxHeight: 640)
                        .fixedSize(horizontal: false, vertical: true)
                        .vfSurface(.floating, radius: VFRadius.touchFloating)
                        .offset(y: 56)
                }
            }
        } else {
            content.popover(isPresented: $isOpen, arrowEdge: .top) {
                menu().frame(maxHeight: 640).presentationCompactAdaptation(.popover).viaFormTheme()
            }
        }
    }
}

/// "Jobs" with a count badge; the popover lists them with pause, resume and stop.
struct TouchJobsButton: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: VFSpace.xs) {
                if flow.queue.isEmpty {
                    Image(systemName: "list.bullet.circle").font(VFFont.glyph(17, weight: .medium))
                } else {
                    ProgressView().controlSize(.small)
                    Text("\(flow.queue.count)").font(VFFont.micro.weight(.bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(theme.accent))
                }
            }
            .foregroundStyle(theme.ink)
            .frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.vfTouch)
        .accessibilityLabel(flow.queue.isEmpty ? String(localized: "Jobs, none running")
                                               : String(localized: "Jobs, \(flow.queue.count) running"))
        .popover(isPresented: $open) {
            TouchJobList(flow: flow).frame(width: 360).padding(.vertical, VFSpace.m)
                .presentationCompactAdaptation(.popover)
                .viaFormTheme()
        }
    }
}

struct TouchJobList: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VFCaption("Jobs").padding(.horizontal, VFSpace.xl).padding(.vertical, VFSpace.m)
            if flow.queue.isEmpty {
                Text("Nothing running. Studies, training and renders show here with their progress.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VFSpace.xl).padding(.bottom, VFSpace.l)
            }
            ForEach(flow.queue.jobs) { j in
                HStack(spacing: VFSpace.m) {
                    VStack(alignment: .leading, spacing: VFSpace.xs) {
                        Text(j.label.isEmpty ? j.verb : j.label).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                        ProgressView(value: j.determinate ? j.progress : nil)
                        Text(j.caption).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    }
                    if j.pausable {
                        TouchBarButton(symbol: j.paused ? "play.fill" : "pause.fill",
                                       label: j.paused ? String(localized: "Resume") : String(localized: "Pause")) {
                            if j.paused { flow.resume(job: j.id) } else { flow.pause(job: j.id) }
                        }
                    }
                    TouchBarButton(symbol: "stop.fill", label: String(localized: "Stop")) { flow.cancel(job: j.id) }
                }
                .padding(.horizontal, VFSpace.xl).padding(.vertical, VFSpace.m)
            }
        }
        .background(theme.panel)
    }
}

/// The share menu: files of the design, of the board, the bill of materials and the libraries.
struct TouchShareMenu: View {
    @Environment(\.viaFormTheme) private var theme
    /// The title pill's labelled accent "Share" button (T-6) instead of the bare icon.
    var prominent = false
    let export: (ExportKind) -> Void
    let showBom: () -> Void
    let showLibrary: () -> Void

    var body: some View {
        Menu {
            Section("Export") {
                Button("Save Design…", systemImage: "square.and.arrow.down") { export(.design) }
                Button("STEP…", systemImage: "cube") { export(.step) }
                Button("STL…", systemImage: "printer") { export(.stl) }
            }
            Section {
                Button("Bill of Materials", systemImage: "list.bullet.rectangle") { showBom() }
                Button("Libraries", systemImage: "books.vertical") { showLibrary() }
            }
        } label: {
            if prominent {
                // The title pill's word button: "Share" on a small accent plate.
                Text("Share").font(VFFont.small.weight(.semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, VFSpace.m)
                    .frame(minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(theme.accent))
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
            } else {
                Image(systemName: "square.and.arrow.up").font(VFFont.glyph(17, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                    .contentShape(Rectangle())
            }
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("Share"))
    }
}

// MARK: - Keyboard

/// What the focused iPad window lends the keyboard commands (the menu bar and the Command-hold
/// overlay list them, grouped). Each window publishes its own, so two windows never mix.
struct TouchFocus {
    var stage: Workspace
    var open: (Workspace) -> Void
    var workspaces: () -> Void
    var palette: () -> Void
    var shortcuts: () -> Void
    var undo: TouchUndoTarget
    /// Runs undo or redo through the window (feedback, text fields keep their own undo).
    var performUndo: () -> Void
    var performRedo: () -> Void
    /// The stage's main action ("Finish Extrude", "Run Study", "Fly"), when it has one.
    var primary: (title: String, run: () -> Void)?
    /// Stops the running job (Command-.); nil when nothing runs.
    var stopJob: (() -> Void)?
    var updateStale: (() -> Void)?
    var toggleInspector: () -> Void
    var showBom: () -> Void
    var showLibrary: () -> Void
    /// Escape: closes the palette, cancels the armed tool or clears the selection; nil while a
    /// job runs, a sheet is up or in Robot (where Escape is the e-stop's).
    var escape: (() -> Void)?
}

extension FocusedValues {
    @Entry var vfTouch: TouchFocus?
}

/// The iPad's keyboard commands as menus (iPadOS menu bar and Command-hold overlay), grouped as
/// on the Mac: Edit (undo), Workspace (stages, main action, stop, update) and View (panels).
/// Installed by the app's iOS scene with `.commands { TouchCommands() }`.
struct TouchCommands: Commands {
    @FocusedValue(\.vfTouch) private var touch

    @MainActor init() { TouchCommandsState.installed = true }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) { touch?.performUndo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(touch == nil)
            Button("Redo") { touch?.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(touch == nil)
        }
        CommandMenu("Workspace") {
            Button("Show Workspaces") { touch?.workspaces() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(touch == nil)
            ForEach(Workspace.allCases) { w in
                Button(w.title) { touch?.open(w) }
                    .keyboardShortcut(w.shortcut, modifiers: .command)
                    .disabled(touch == nil)
            }
            Button("Next Stage") { step(1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(touch == nil)
            Button("Previous Stage") { step(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(touch == nil)
            Divider()
            Button(touch?.primary.map { String(localized: "Run: \($0.title)") } ?? String(localized: "Run Stage Action")) { touch?.primary?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(touch?.primary == nil)
            Button("Stop Job") { touch?.stopJob?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(touch?.stopJob == nil)
            Button("Update Stale Stages") { touch?.updateStale?() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(touch?.updateStale == nil)
            Divider()
            Button("Search Commands…") { touch?.palette() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(touch == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { touch?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(touch == nil)
            Button("Bill of Materials") { touch?.showBom() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(touch == nil)
            Button("Libraries") { touch?.showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(touch == nil)
            Button("Clear Selection") { touch?.escape?() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(touch?.escape == nil)
            Divider()
            Button("Keyboard Shortcuts") { touch?.shortcuts() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(touch == nil)
        }
    }

    private var undoTitle: String {
        if let n = touch?.undo.undoName, touch?.undo.canUndo == true { return String(localized: "Undo \(n)") }
        return String(localized: "Undo")
    }

    private func step(_ d: Int) {
        guard let touch else { return }
        let all = Workspace.allCases
        touch.open(all[(touch.stage.index + d + all.count) % all.count])
    }
}

@MainActor
enum TouchCommandsState {
    /// The scene installed `TouchCommands`: the window's hidden key buttons stand down so no
    /// shortcut is registered twice.
    static var installed = false
}

/// The same shortcuts as hidden buttons in the window, used while the scene has no
/// `TouchCommands` (they then list ungrouped in the Command-hold overlay).
struct TouchKeyCommands: View {
    let focus: TouchFocus

    var body: some View {
        if !TouchCommandsState.installed {
            ZStack {
                Button("Show Workspaces", action: focus.workspaces).keyboardShortcut("0", modifiers: .command)
                Button("Search Commands", action: focus.palette).keyboardShortcut("k", modifiers: .command)
                Button("Undo", action: focus.performUndo).keyboardShortcut("z", modifiers: .command)
                Button("Redo", action: focus.performRedo).keyboardShortcut("z", modifiers: [.command, .shift])
                Button("Next Stage") { step(1) }.keyboardShortcut("]", modifiers: .command)
                Button("Previous Stage") { step(-1) }.keyboardShortcut("[", modifiers: .command)
                ForEach(Workspace.allCases) { w in
                    Button(w.title) { focus.open(w) }.keyboardShortcut(w.shortcut, modifiers: .command)
                }
                Button(focus.primary.map { String(localized: "Run: \($0.title)") } ?? String(localized: "Run Stage Action")) { focus.primary?.run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(focus.primary == nil)
                Button("Stop Job") { focus.stopJob?() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(focus.stopJob == nil)
                Button("Update Stale Stages") { focus.updateStale?() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(focus.updateStale == nil)
                Button("Toggle Inspector", action: focus.toggleInspector).keyboardShortcut("i", modifiers: [.command, .option])
                Button("Bill of Materials", action: focus.showBom).keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Libraries", action: focus.showLibrary).keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Keyboard Shortcuts", action: focus.shortcuts).keyboardShortcut("/", modifiers: .command)
                Button("Clear Selection") { focus.escape?() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(focus.escape == nil)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func step(_ d: Int) {
        let all = Workspace.allCases
        focus.open(all[(focus.stage.index + d + all.count) % all.count])
    }
}

/// Command-/: every shortcut of the iPad, grouped as in the menus.
struct TouchShortcutsSheet: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// The design's single-letter tool keys (`TouchKeymap.rows(model)`), listed under Tools.
    var toolRows: [(keys: String, title: String)] = []

    private struct Row: Identifiable { let keys: String; let title: String; var id: String { keys + title } }

    private var groups: [(String, [Row])] {
        [
            (String(localized: "Edit"), [
                Row(keys: "⌘Z", title: String(localized: "Undo in the open stage")),
                Row(keys: "⇧⌘Z", title: String(localized: "Redo")),
                Row(keys: "Esc", title: String(localized: "Cancel the tool or clear the selection")),
            ]),
            (String(localized: "Workspace"), [
                Row(keys: "⌘0", title: String(localized: "Show workspaces")),
                Row(keys: "⌘1 to ⌘9", title: String(localized: "Go to a stage")),
                Row(keys: "⌘[  ⌘]", title: String(localized: "Previous or next stage")),
                Row(keys: "⌘Return", title: String(localized: "Finish the tool or run the stage's main action")),
                Row(keys: "⌘.", title: String(localized: "Stop the running job")),
                Row(keys: "⇧⌘U", title: String(localized: "Update stale stages")),
                Row(keys: "⌘K", title: String(localized: "Search commands")),
            ]),
            (String(localized: "View"), [
                Row(keys: "⌥⌘I", title: String(localized: "Show or hide the inspector")),
                Row(keys: "⇧⌘B", title: String(localized: "Bill of materials")),
                Row(keys: "⇧⌘L", title: String(localized: "Libraries")),
                Row(keys: "⌘/", title: String(localized: "This list")),
            ]),
            (String(localized: "Tools"), toolRows.map { Row(keys: $0.keys, title: $0.title) }),
            (String(localized: "Gestures"), [
                Row(keys: String(localized: "Two-finger tap"), title: String(localized: "Undo, on the 3D view")),
                Row(keys: String(localized: "Long press"), title: String(localized: "More actions on a row or a step")),
                Row(keys: String(localized: "Press and hold"), title: String(localized: "Pick what lies under the finger, on the 3D view")),
            ]),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { r in
                            HStack {
                                Text(r.title).foregroundStyle(theme.ink)
                                Spacer()
                                Text(r.keys).font(VFFont.mono).foregroundStyle(theme.inkSecondary)
                            }
                            .frame(minHeight: VFSize.touchTarget)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle(Text("Keyboard Shortcuts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
