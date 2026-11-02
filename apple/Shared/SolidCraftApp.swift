import SwiftUI

@main
struct SolidCraftApp: App {
    #if os(macOS)
    @State private var model = DesignModel()
    #endif

    init() {
        if ProcessInfo.processInfo.arguments.contains("--selftest") { SelfTest.run() }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            DeskRootView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.light)
                .tint(Color(red: 0.13, green: 0.55, blue: 0.95))
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Design") { model.newDesign() }.keyboardShortcut("n")
                Button("Open…") { FileActions.open(model) }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { FileActions.save(model) }.keyboardShortcut("s")
                Button("Export…") { FileActions.export(model) }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z")
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
        #else
        WindowGroup {
            TouchRootView()
                .tint(Color(red: 0.12, green: 0.47, blue: 0.98))
        }
        #endif
    }
}
