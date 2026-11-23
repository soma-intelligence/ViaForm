#if os(iOS)
import SwiftUI

// The iPad's top capsule: the workspace dropdown button, title and revision, undo and redo, the
// Items | History switch, the jobs and share buttons (VIAFORM-SPEC 6.2, no pipeline strip).
// Every target is 44 points or more.

/// The name a tool shows on touch screens (no other product's command names).
extension Tool {
    var touchLabel: String {
        switch self {
        case .pressPull: "Push / Pull"
        case .centerRectangle: "Center Rect"
        default: label
        }
    }
}

/// Which card sits on the right: the stage's inspector, the items or the history.
enum TouchSideCard: String, CaseIterable, Identifiable {
    case items = "Items", history = "History"
    var id: String { rawValue }
}

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
                .font(.system(size: 17, weight: .medium))
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                .foregroundStyle(on ? theme.accentText : theme.ink)
                .background(on ? theme.accent.opacity(0.14) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct TouchTopCapsule: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: Workspace
    let title: String
    let canUndo: Bool
    let canRedo: Bool
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
        // Wide first, then Items | History in a menu.
        ViewThatFits(in: .horizontal) {
            row(switchInline: true)
            row(switchInline: false)
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 56)
        .vfSurface(.floating, radius: 28)
    }

    private func row(switchInline: Bool) -> some View {
        HStack(spacing: 4) {
            TouchWorkspaceButton(flow: flow, stage: stage, compact: compact, isOpen: $workspacesOpen, open: open)
            TouchBarButton(symbol: "sidebar.left", label: "Browser", action: showBrowser)
            titleBlock
            TouchBarButton(symbol: "arrow.uturn.backward", label: "Undo", action: undo).disabled(!canUndo)
            TouchBarButton(symbol: "arrow.uturn.forward", label: "Redo", action: redo).disabled(!canRedo)
            Spacer(minLength: 4)
            if showsSideSwitch {
                if switchInline { sideSwitch.fixedSize() } else { sideMenu }
            }
            TouchBarButton(symbol: "magnifyingglass", label: "Commands", action: showPalette)
            TouchJobsButton(flow: flow)
            share
        }
    }

    private var sideMenu: some View {
        Menu {
            ForEach(TouchSideCard.allCases) { c in
                Button { side = side == c ? nil : c } label: { Label(c.rawValue, systemImage: side == c ? "checkmark" : (c == .items ? "square.3.layers.3d" : "clock.arrow.circlepath")) }
            }
        } label: {
            Image(systemName: "square.3.layers.3d").font(.system(size: 17, weight: .medium))
                .foregroundStyle(side == nil ? theme.ink : theme.accentText)
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget).contentShape(Rectangle())
        }
        .accessibilityLabel("Items or History")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(1)
            if let rev = flow.revisionName(of: stage.stage) ?? flow.revisionName(of: "design") {
                Text(rev).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(theme.inkSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: compact ? 80 : 140, maxWidth: compact ? 120 : 210, alignment: .leading)
    }

    /// Items | History as a two-segment switch; tapping the open one closes it.
    private var sideSwitch: some View {
        HStack(spacing: 0) {
            ForEach(TouchSideCard.allCases) { c in
                let on = side == c
                Button { side = on ? nil : c } label: {
                    Text(c.rawValue).font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? theme.onAccent : theme.ink)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 64, minHeight: VFSize.touchTarget - 8)
                        .background(on ? theme.accent : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
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
    @Binding var isOpen: Bool
    let open: (Workspace) -> Void
    @State private var showGraph = false

    var body: some View {
        let badge = WorkspaceMenu.badge(flow, current: stage)
        Button { isOpen = true } label: {
            HStack(spacing: 6) {
                Image(systemName: stage.symbol).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.stageFill(stage.vfStage))
                if !compact {
                    Text(stage.title.uppercased()).font(.system(size: 13, weight: .semibold)).tracking(VFTypeScale.capsTracking)
                        .foregroundStyle(theme.ink).fixedSize()
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.inkSecondary)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)
            .background(Capsule().fill(theme.well))
            .overlay(alignment: .topTrailing) { WorkspaceBadgeView(badge: badge, size: 17).offset(x: 4, y: -2) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(WorkspaceMenu.spoken(current: stage, badge: badge))
        .accessibilityHint("Opens the list of stages")
        .modifier(TouchWorkspacePresenter(compact: compact, isOpen: $isOpen) { menu })
        .sheet(isPresented: $showGraph) {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    FlowGraphView(flow: flow, current: stage, open: { w in showGraph = false; open(w) })
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGraph = false } } }
            }
        }
    }

    private var menu: some View {
        ScrollView {
            WorkspaceMenuList(flow: flow, current: stage, touch: true,
                              open: { w in isOpen = false; open(w) },
                              updateAll: nil,
                              showFlow: {
                                  isOpen = false
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showGraph = true }
                              },
                              close: { isOpen = false })
        }
        .frame(minWidth: compact ? nil : 380, idealWidth: compact ? nil : 380)
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
                menu().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--landscape-render") {
            // The screenshot harness turns the shell a quarter; a popover lives in its own
            // window and would not turn with it, so the menu is drawn in place.
            content.overlay(alignment: .topLeading) {
                if isOpen {
                    menu().frame(width: 380, height: 640)
                        .vfSurface(.floating, radius: VFRadius.floating)
                        .offset(y: 56)
                        .fixedSize()
                }
            }
        } else {
            content.popover(isPresented: $isOpen, arrowEdge: .top) {
                menu().frame(width: 380, height: 640)
            }
        }
    }
}

/// "Jobs" with a count badge; the popover lists them with pause, resume and cancel.
struct TouchJobsButton: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 5) {
                if flow.queue.isEmpty {
                    Image(systemName: "list.bullet.circle").font(.system(size: 17, weight: .medium))
                } else {
                    ProgressView().controlSize(.small)
                    Text("\(flow.queue.count)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(theme.onAccent)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(theme.accent))
                }
            }
            .foregroundStyle(theme.ink)
            .frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(flow.queue.isEmpty ? "Jobs, none running" : "Jobs, \(flow.queue.count) running")
        .popover(isPresented: $open) {
            TouchJobList(flow: flow).frame(width: 360).padding(.vertical, 8)
        }
    }
}

struct TouchJobList: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VFCaption("Jobs").padding(.horizontal, 16).padding(.vertical, 8)
            if flow.queue.isEmpty {
                Text("Nothing running. Studies, training and renders show here with their progress.")
                    .font(.callout).foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            ForEach(flow.queue.jobs) { j in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(j.label.isEmpty ? j.verb : j.label).font(.system(size: 15, weight: .semibold))
                        ProgressView(value: j.determinate ? j.progress : nil)
                        Text(j.caption).font(.footnote).monospacedDigit().foregroundStyle(theme.inkSecondary)
                    }
                    if j.pausable {
                        TouchBarButton(symbol: j.paused ? "play.fill" : "pause.fill", label: j.paused ? "Resume" : "Pause") {
                            if j.paused { flow.resume(job: j.id) } else { flow.pause(job: j.id) }
                        }
                    }
                    TouchBarButton(symbol: "xmark", label: "Cancel") { flow.cancel(job: j.id) }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
}

/// The share menu: files of the design, of the board, the bill of materials and the libraries.
struct TouchShareMenu: View {
    @Environment(\.viaFormTheme) private var theme
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
            Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Share")
    }
}
#endif

#if os(iOS)
/// Hardware keyboard on the iPad (Magic Keyboard): Command-0 workspaces, Command-K commands, Command-1 to Command-9
/// stages, Command-] and Command-[ through them, Command-Z and Shift-Command-Z. Hidden buttons:
/// holding Command lists them in the system's shortcut overlay.
struct TouchKeyCommands: View {
    let stage: Workspace
    var open: (Workspace) -> Void
    var palette: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var workspaces: () -> Void = {}

    var body: some View {
        ZStack {
            Button("Show Workspaces", action: workspaces).keyboardShortcut("0", modifiers: .command)
            Button("Search Commands", action: palette).keyboardShortcut("k", modifiers: .command)
            Button("Undo", action: undo).keyboardShortcut("z", modifiers: .command)
            Button("Redo", action: redo).keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Next Stage") { step(1) }.keyboardShortcut("]", modifiers: .command)
            Button("Previous Stage") { step(-1) }.keyboardShortcut("[", modifiers: .command)
            ForEach(Workspace.allCases) { w in
                Button(w.title) { open(w) }.keyboardShortcut(w.shortcut, modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func step(_ d: Int) {
        let all = Workspace.allCases
        open(all[(stage.index + d + all.count) % all.count])
    }
}
#endif
