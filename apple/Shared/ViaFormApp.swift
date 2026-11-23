import SwiftUI

@main
struct ViaFormApp: App {
    #if os(macOS)
    @State private var model = DesignModel()
    @State private var pcb = PCBModel(sample: ProcessInfo.processInfo.arguments.contains("--sample"))
    #endif

    init() {
        LegacyDefaults.migrate()
        if ProcessInfo.processInfo.arguments.contains("--selftest") { SelfTest.run() }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            // The project window (pipeline toolbar, sidebar, inspector); the old layout behind
            // Settings > Legacy layout or --legacy-ui.
            DeskRoot(model: model, pcb: pcb)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            DeskWorkspaceCommands()
            SidebarCommands()
            InspectorCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Design") { FileActions.newDesign(model) }.keyboardShortcut("n").disabled(EngineGate.shared.shut)
                Button("Open…") { FileActions.open(model) }.keyboardShortcut("o").disabled(EngineGate.shared.shut)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { FileActions.save(model) }.keyboardShortcut("s").disabled(EngineGate.shared.shut)
                Button("Save As…") { FileActions.saveAs(model) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(EngineGate.shared.shut)
                Button("Export…") { FileActions.export(model) }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(EngineGate.shared.shut)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(EngineGate.shared.shut)
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(EngineGate.shared.shut)
            }
        }
        Settings { DeskSettingsView().viaFormTheme() }
        #else
        WindowGroup {
            TouchRootView()
                .tint(Color(red: 0.12, green: 0.47, blue: 0.98))
        }
        #endif
    }
}

/// The app shipped as SolidCraft (bundle ids `me.somalabs.solidcraft` and
/// `me.somalabs.solidcraft.mac`) before it took the ViaForm name. Its settings live in the old
/// defaults domain, so each key ViaForm reads is copied over once when the new domain lacks it.
/// The Mac app is not sandboxed and can read the old domain; on iOS the old container is out of
/// reach and the copy finds nothing.
enum LegacyDefaults {
    #if os(macOS)
    static let oldDomain = "me.somalabs.solidcraft.mac"
    #else
    static let oldDomain = "me.somalabs.solidcraft"
    #endif
    static let keys = ["viaform.theme.mode", "viaform.desk.legacyLayout", "generate.secondsPerElementSolve"]
    private static let doneKey = "viaform.legacyDefaultsMigrated"

    static func migrate(into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = UserDefaults(suiteName: oldDomain) {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
