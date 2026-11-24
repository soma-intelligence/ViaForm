import SwiftUI

@main
struct ViaFormApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ViaFormAppDelegate.self) private var appDelegate
    #endif

    init() {
        LegacyDefaults.migrate()
        if ProcessInfo.processInfo.arguments.contains("--selftest") { SelfTest.run() }
        // These two used to start from the first window's models, so a scripted launch that
        // opens no window hung. Touching the models here runs them and exits.
        if ProcessInfo.processInfo.arguments.contains("--robot-selftest") { _ = RobotSafety.shared }
        if ProcessInfo.processInfo.arguments.contains("--flow-selftest") { _ = FlowModel() }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            // Each window owns its project: design, board, BOM, pipeline, undo and dirty state.
            DeskWindowRoot()
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            DeskFileCommands()
            DeskWorkspaceCommands()
            SidebarCommands()
            InspectorCommands()
        }
        Settings { DeskSettingsView().viaFormTheme() }
        #else
        WindowGroup {
            // TouchRootView applies the theme (System by default, D-20) and its accent tint.
            TouchRootView()
        }
        .commands { TouchCommands() }
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
