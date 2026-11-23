#if os(macOS)
import SwiftUI

/// What the focused project window lends the menu bar.
struct DeskFocus {
    var workspace: Workspace
    var open: (Workspace) -> Void
    var search: () -> Void
    /// Opens or closes the workspace dropdown (Command-0).
    var openWorkspaces: () -> Void = {}
    /// Shows the project start (templates and recent projects).
    var start: () -> Void = {}
    var toggleInspector: () -> Void = {}
    var toggleBottom: () -> Void = {}
    var shortcuts: () -> Void = {}
    /// The stage's main action ("Run Study", "Fly", "Render Shots"), when it has one.
    var primary: (title: String, run: () -> Void)?
    var updateStale: (() -> Void)?
}

struct DeskFocusKey: FocusedValueKey { typealias Value = DeskFocus }

extension FocusedValues {
    var vfDesk: DeskFocus? {
        get { self[DeskFocusKey.self] }
        set { self[DeskFocusKey.self] = newValue }
    }
}

/// The Workspace menu: Command-0 opens the workspace dropdown, Command-1 to Command-9 open the stages (the only Command-digit shortcuts
/// in the app, so they never collide), Command-] and Command-[ step through them, Command-Return
/// runs the stage's main action, Command-K searches every command, the panel toggles, and the
/// keyboard sheet (Command-/).
struct DeskWorkspaceCommands: Commands {
    @FocusedValue(\.vfDesk) private var desk

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New from Template\u{2026}") { desk?.start() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(desk == nil)
        }
        CommandMenu("Workspace") {
            Button("Show Workspaces") { desk?.openWorkspaces() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(desk == nil)
            Divider()
            ForEach(Workspace.allCases) { w in
                Button {
                    desk?.open(w)
                } label: {
                    if desk?.workspace == w { Label(w.title, systemImage: "checkmark") } else { Text(w.title) }
                }
                .keyboardShortcut(w.shortcut, modifiers: .command)
                .disabled(desk == nil)
            }
            Divider()
            Button("Next Stage") { step(1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(desk == nil)
            Button("Previous Stage") { step(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(desk == nil)
            Divider()
            Button(desk?.primary.map { "Run: \($0.title)" } ?? "Run Stage Action") { desk?.primary?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(desk?.primary == nil)
            Button("Update Stale Stages") { desk?.updateStale?() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(desk?.updateStale == nil)
            Divider()
            Button("Search Commands…") { desk?.search() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(desk == nil)
            Button("Toggle Inspector") { desk?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(desk == nil)
            Button("Toggle Bottom Panel") { desk?.toggleBottom() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(desk == nil)
            Divider()
            Button("Keyboard Shortcuts") { desk?.shortcuts() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(desk == nil)
        }
    }

    private func step(_ d: Int) {
        guard let desk else { return }
        let all = Workspace.allCases
        let i = (desk.workspace.index + d + all.count) % all.count
        desk.open(all[i])
    }
}

/// When the window opens on the project start: `--start`, or a launch with no flags at all
/// (opened from the Finder or the Dock, not from a script).
enum StartLaunch {
    static var atLaunch: Bool {
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        return args.contains("--start") || !args.contains { $0.hasPrefix("-") }
    }
}

/// The setting that keeps the old single-view window, and its launch flag.
enum DeskLayout {
    static let legacyKey = "viaform.desk.legacyLayout"

    static var launchLegacy: Bool { ProcessInfo.processInfo.arguments.contains("--legacy-ui") }
}

/// The window's root: the project window, or the old layout when asked for.
struct DeskRoot: View {
    @AppStorage(DeskLayout.legacyKey) private var legacy = false
    let model: DesignModel
    let pcb: PCBModel

    var body: some View {
        if legacy || DeskLayout.launchLegacy {
            DeskRootView(model: model, pcb: pcb)
                .viaFormTheme(.dark)
                .tint(Color(red: 0.24, green: 0.55, blue: 1.0))
        } else {
            ProjectWindow(model: model, pcb: pcb)
                .viaFormTheme()
        }
    }
}

/// Settings: appearance and layout.
struct DeskSettingsView: View {
    @AppStorage(DeskLayout.legacyKey) private var legacy = false

    var body: some View {
        Form {
            ThemeModePicker()
            Toggle("Legacy layout", isOn: $legacy)
            Text("The single-view window from before the pipeline toolbar. It opens on the next window, and with --legacy-ui at launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
    }
}
#endif
