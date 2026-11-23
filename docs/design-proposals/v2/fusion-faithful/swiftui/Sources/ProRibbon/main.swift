import AppKit
import SwiftUI

/// `ProRibbon` opens the interactive prototype window.
/// `ProRibbon render [outDir]` draws the five screens to PNG at scale 2 and exits.
struct ProRibbonApp: App {
    var body: some Scene {
        WindowGroup("ViaForm") {
            MacWindow(workspace: .design)
                .frame(minWidth: 1100, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 1000)

        Window("ViaForm Touch", id: "touch") {
            TouchScreen()
        }
        .defaultSize(width: 1366, height: 1024)
    }
}

@MainActor
func renderAll(to dir: URL) {
    RenderMode.active = true
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mac = CGSize(width: 1600, height: 1000)
    let screens: [(String, AnyView, CGSize)] = [
        ("1-design", AnyView(MacWindow(workspace: .design)), mac),
        ("2-generative", AnyView(MacWindow(workspace: .generative)), mac),
        ("3-simulation", AnyView(MacWindow(workspace: .simulation)), mac),
        ("4-electronics", AnyView(MacWindow(workspace: .electronics)), mac),
        ("5-ipad-hand", AnyView(TouchScreen()), CGSize(width: 1366, height: 1024)),
    ]
    for (name, view, size) in screens {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        r.scale = 2
        guard let cg = r.cgImage else { print("failed", name); continue }
        let rep = NSBitmapImageRep(cgImage: cg)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote", url.path, cg.width, "x", cg.height)
    }
}

let args = CommandLine.arguments
if args.count > 1, args[1] == "render" {
    let out = args.count > 2 ? URL(fileURLWithPath: args[2])
        : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("screens")
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderAll(to: out) }
    exit(0)
} else {
    ProRibbonApp.main()
}
