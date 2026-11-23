import SwiftUI
import AppKit

let args = CommandLine.arguments
if args.count > 1, args[1] == "render" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let out = args.count > 2 ? args[2] : "screens"
        Renderer.run(outDir: out, only: args.count > 3 ? args[3] : nil)
    }
} else {
    HybridPipelineApp.main()
}
