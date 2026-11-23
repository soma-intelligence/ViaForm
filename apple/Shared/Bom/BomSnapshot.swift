#if os(macOS)
import AppKit
import SwiftUI

/// Docs hook: `--bom-snapshot=<file.png>` renders the BOM panel offscreen (works with the screen
/// locked) and writes a PNG; `--bom-snapshot-size=1600x1000` sets its size, `--bom-quit` quits after.
@MainActor
enum BomSnapshot {
    private static var window: NSWindow?

    static func runIfAsked(model: BomModel, design: DesignModel, pcb: PCBModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let a = args.first(where: { $0.hasPrefix("--bom-snapshot=") }) else { return }
        let path = String(a.dropFirst(15))
        var size = CGSize(width: 1600, height: 1000)
        if let s = args.first(where: { $0.hasPrefix("--bom-snapshot-size=") })?.dropFirst(20).split(separator: "x"), s.count == 2, let w = Double(s[0]), let h = Double(s[1]) {
            size = CGSize(width: w, height: h)
        }
        let view = BomPanel(model: model, design: design, pcb: pcb) {}
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .tint(Color(red: 0.24, green: 0.55, blue: 1.0))
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        window = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if args.contains("--bom-quit") { NSApp.terminate(nil) }
        }
    }
}
#endif
