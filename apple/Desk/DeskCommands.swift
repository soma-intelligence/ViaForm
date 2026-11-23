#if os(macOS)
import AppKit
import SwiftUI

/// What the open stage undoes: the design, the assembly, the board or the study. The menu, the
/// toolbar and the palette all go through it, so Command-Z never reaches a document the reader
/// cannot see.
struct UndoTarget {
    var canUndo = false
    var canRedo = false
    /// "Study Change", "Extrude": the menu reads "Undo Study Change".
    var undoName: String?
    var redoName: String?
    var undo: () -> Void = {}
    var redo: () -> Void = {}

    static var none: UndoTarget { UndoTarget() }
}

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
    /// The window's design model: the File menu acts on this window's project.
    var design: DesignModel?
    var undo: UndoTarget = .none
    /// Stops the running job (Command-.); nil when nothing runs.
    var stopJob: (() -> Void)?
    var toggleSidebar: () -> Void = {}
    var showBom: () -> Void = {}
    var showLibraries: () -> Void = {}
    var showFlowGraph: () -> Void = {}
    /// Standard views and Zoom to Fit, in the 3D stages only.
    var setView: ((StandardView) -> Void)?
    var zoomToFit: (() -> Void)?
}

struct DeskFocusKey: FocusedValueKey { typealias Value = DeskFocus }

extension FocusedValues {
    var vfDesk: DeskFocus? {
        get { self[DeskFocusKey.self] }
        set { self[DeskFocusKey.self] = newValue }
    }
}

/// A text field is being edited in the key window: Edit menu items go to it, not the model.
@MainActor
private var textFieldEditing: Bool {
    NSApp.keyWindow?.firstResponder is NSText
}

/// File, Edit (undo), View, Workspace and Help commands of the project window. Every item acts on
/// the focused window's own models (DeskFocus), never on a model shared by all windows.
struct DeskFileCommands: Commands {
    @FocusedValue(\.vfDesk) private var desk

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Design") { if let d = desk?.design { FileActions.newDesign(d) } }
                .keyboardShortcut("n")
                .disabled(desk?.design == nil || EngineGate.shared.shut)
            Button("New from Template\u{2026}") { desk?.start() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(desk == nil)
            Button("Open\u{2026}") { if let d = desk?.design { FileActions.open(d) } }
                .keyboardShortcut("o")
                .disabled(desk?.design == nil || EngineGate.shared.shut)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { if let d = desk?.design { FileActions.save(d) } }
                .keyboardShortcut("s")
                .disabled(desk?.design == nil || EngineGate.shared.shut)
            Button("Save As\u{2026}") { if let d = desk?.design { FileActions.saveAs(d) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(desk?.design == nil || EngineGate.shared.shut)
            Button("Export\u{2026}") { if let d = desk?.design { FileActions.export(d) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(desk?.design == nil || EngineGate.shared.shut)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) {
                if textFieldEditing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { desk?.undo.undo() }
            }
            .keyboardShortcut("z")
            .disabled(!textFieldEditing && (!(desk?.undo.canUndo ?? false) || EngineGate.shared.shut))
            Button(redoTitle) {
                if textFieldEditing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { desk?.undo.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!textFieldEditing && (!(desk?.undo.canRedo ?? false) || EngineGate.shared.shut))
        }
        CommandGroup(replacing: .help) {
            Button("ViaForm Help") { HelpPages.open(nil) }
            Button("\(desk?.workspace.title ?? String(localized: "Stage")) Help") { HelpPages.open(desk?.workspace) }
                .disabled(desk == nil)
            Divider()
            Button("Keyboard Shortcuts") { desk?.shortcuts() }
                .disabled(desk == nil)
        }
    }

    private var undoTitle: String {
        if !textFieldEditing, let n = desk?.undo.undoName, desk?.undo.canUndo == true { return String(localized: "Undo \(n)") }
        return String(localized: "Undo")
    }

    private var redoTitle: String {
        if !textFieldEditing, let n = desk?.undo.redoName, desk?.undo.canRedo == true { return String(localized: "Redo \(n)") }
        return String(localized: "Redo")
    }
}

/// The Workspace menu: Command-0 opens the workspace dropdown, Command-1 to Command-9 open the
/// stages (the only Command-digit shortcuts in the app, so they never collide), Command-] and
/// Command-[ step through them, Command-Return runs the stage's main action, Command-. stops the
/// running job, Command-K searches every command.
struct DeskWorkspaceCommands: Commands {
    @FocusedValue(\.vfDesk) private var desk

    var body: some Commands {
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
            Button(desk?.primary.map { String(localized: "Run: \($0.title)") } ?? String(localized: "Run Stage Action")) { desk?.primary?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(desk?.primary == nil)
            Button("Stop Job") { desk?.stopJob?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(desk?.stopJob == nil)
            Button("Update Stale Stages") { desk?.updateStale?() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(desk?.updateStale == nil)
            Divider()
            Button("Search Commands\u{2026}") { desk?.search() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(desk == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { desk?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(desk == nil)
            Button("Toggle Bottom Panel") { desk?.toggleBottom() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(desk == nil)
            Divider()
            Button("Bill of Materials") { desk?.showBom() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(desk == nil)
            Button("Libraries") { desk?.showLibraries() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(desk == nil)
            Button("Flow Graph") { desk?.showFlowGraph() }
                .disabled(desk == nil)
            Divider()
            Button("Zoom to Fit") { desk?.zoomToFit?() }
                .disabled(desk?.zoomToFit == nil)
            Menu("Standard View") {
                ForEach(Array(StandardView.allCases.enumerated()), id: \.element) { i, v in
                    Button(v == .iso ? String(localized: "Isometric") : v.rawValue.capitalized) { desk?.setView?(v) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
                }
            }
            .disabled(desk?.setView == nil)
            Divider()
        }
    }

    private func step(_ d: Int) {
        guard let desk else { return }
        let all = Workspace.allCases
        let i = (desk.workspace.index + d + all.count) % all.count
        desk.open(all[i])
    }
}

/// Local help, one page per stage (FRONTEND-SPEC 7.7). Opens the docs in the bundle when they are
/// there, else the specification on the web.
@MainActor
enum HelpPages {
    static func open(_ w: Workspace?) {
        let name = w.map { "help-\($0.stage)" } ?? "help"
        if let url = Bundle.main.url(forResource: name, withExtension: "html") ?? Bundle.main.url(forResource: name, withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://github.com/soma-intelligence/viaform#readme") {
            NSWorkspace.shared.open(url)
        }
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

/// The setting that keeps the old single-view window, and its launch flag. Off the default path:
/// only `--legacy-ui` opens it (the Settings toggle is gone).
enum DeskLayout {
    static let legacyKey = "viaform.desk.legacyLayout"

    static var launchLegacy: Bool { ProcessInfo.processInfo.arguments.contains("--legacy-ui") }
}

/// One window: its own design and board (each window is its own project), then the project
/// window, or the old layout under `--legacy-ui`.
struct DeskWindowRoot: View {
    @State private var model = DesignModel()
    @State private var pcb = PCBModel(sample: ProcessInfo.processInfo.arguments.contains("--sample"))

    var body: some View {
        DeskRoot(model: model, pcb: pcb)
    }
}

/// The window's root: the project window, or the old layout when launched with `--legacy-ui`.
struct DeskRoot: View {
    let model: DesignModel
    let pcb: PCBModel

    var body: some View {
        if DeskLayout.launchLegacy {
            DeskRootView(model: model, pcb: pcb)
                .viaFormTheme(.dark)
        } else {
            ProjectWindow(model: model, pcb: pcb)
                .viaFormTheme()
        }
    }
}

/// Settings: General (appearance, units), Navigation (mouse and trackpad preset).
struct DeskSettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    LabeledContent("Appearance") { ThemeModePicker(showsLabel: false) }
                    Section {
                        Button("Show Stage Introductions Again") { StageIntro.resetAll() }
                    } footer: {
                        Text("Each stage shows a short introduction the first time you open it.")
                            .font(VFFont.small)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Navigation", systemImage: "computermouse") {
                NavigationSettings()
            }
        }
        .frame(width: 520, height: 380)
    }
}
#endif
