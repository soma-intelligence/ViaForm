import SwiftUI
import AppKit

struct DirectCanvasApp: App {
    @State private var studio = Studio()
    var body: some Scene {
        WindowGroup("ViaForm") {
            RootView(studio: studio)
                .frame(minWidth: 1280, minHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 1000)
    }
}

let args = CommandLine.arguments
if args.contains("render") {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let out = args.firstIndex(of: "--out").map { URL(fileURLWithPath: args[$0 + 1]) } ?? here.appendingPathComponent("screens")
    MainActor.assumeIsolated {
        Renderer.checkSymbols()
        Renderer.run(out: out, paletteToo: args.contains("--palette"))
    }
    exit(0)
} else {
    NSApplication.shared.setActivationPolicy(.regular)
    DirectCanvasApp.main()
}
