import AppKit
import SwiftUI

/// Mac root: one window, the workspace capsule switches the screen. Cmd+1 to Cmd+8 come from the capsule.
struct StudioRoot: View {
    @State var workspace: Workspace = .design

    var body: some View {
        Group {
            switch workspace {
            case .generative: GenerativeScreen(workspace: $workspace)
            case .simulation, .training: SimulationScreen(workspace: $workspace)
            case .electronics: ElectronicsScreen(workspace: $workspace)
            default: DesignScreen(workspace: $workspace)
            }
        }
    }
}

struct LiquidStudioApp: App {
    var body: some Scene {
        WindowGroup("ViaForm") {
            StudioRoot().frame(minWidth: 1280, minHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 1000)
        WindowGroup("ViaForm iPad", id: "ipad") {
            IPadHandScreen().frame(width: 1366, height: 1024)
        }
    }
}

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "render" {
            MainActor.assumeIsolated { Renderer.renderAll(only: Array(CommandLine.arguments.dropFirst(2))) }
            return
        }
        LiquidStudioApp.main()
    }
}

@MainActor
enum Renderer {
    static func renderAll(only: [String]) {
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("screens")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mac = CGSize(width: 1600, height: 1000), pad = CGSize(width: 1366, height: 1024)
        let jobs: [(String, CGSize, AnyView)] = [
            ("1-design", mac, AnyView(StudioRoot(workspace: .design))),
            ("2-generative", mac, AnyView(StudioRoot(workspace: .generative))),
            ("3-simulation", mac, AnyView(StudioRoot(workspace: .simulation))),
            ("4-electronics", mac, AnyView(StudioRoot(workspace: .electronics))),
            ("5-ipad-hand", pad, AnyView(IPadHandScreen())),
        ]
        for (name, size, view) in jobs where only.isEmpty || only.contains(where: { name.hasPrefix($0) }) {
            let r = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                .environment(\.staticRender, true).environment(\.colorScheme, .dark))
            r.scale = 2
            guard let cg = r.cgImage else { print(name, "render failed"); continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            let url = out.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(name, "->", url.path)
        }
    }
}
