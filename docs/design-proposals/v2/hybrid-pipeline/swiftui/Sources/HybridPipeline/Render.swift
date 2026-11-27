import SwiftUI
import AppKit

@MainActor
enum Renderer {
    static var screens: [(name: String, size: CGSize, view: AnyView)] {
        let mac = CGSize(width: 1600, height: 1000)
        return [
            ("1-design", mac, AnyView(StaticMacWindow(screen: DesignStage.screen))),
        ] + extraScreens
    }

    static func run(outDir: String, only: String?) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for s in screens where only == nil || s.name.hasPrefix(only!) {
            let content = s.view
                .frame(width: s.size.width, height: s.size.height)
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: content)
            r.scale = 2
            r.proposedSize = ProposedViewSize(s.size)
            guard let cg = r.cgImage else { print("render failed: \(s.name)"); continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            let path = (outDir as NSString).appendingPathComponent("\(s.name).png")
            do {
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) \(cg.width)x\(cg.height)")
            } catch { print("write failed: \(error)") }
        }
    }
}
