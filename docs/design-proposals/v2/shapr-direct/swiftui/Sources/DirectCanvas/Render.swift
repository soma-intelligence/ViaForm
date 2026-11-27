import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Headless PNG export of the five screens with ImageRenderer at scale 2.
@MainActor
enum Renderer {
    static func run(out: URL, paletteToo: Bool) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mac = CGSize(width: 1600, height: 1000), pad = CGSize(width: 1366, height: 1024)
        var jobs: [(String, AnyView, CGSize)] = [
            ("1-design", AnyView(DesignScreen(studio: Studio(workspace: .design))), mac),
            ("2-generative", AnyView(GenerativeScreen(studio: Studio(workspace: .generative))), mac),
            ("3-simulation", AnyView(SimulationScreen(studio: Studio(workspace: .simulation))), mac),
            ("4-electronics", AnyView(ElectronicsScreen(studio: Studio(workspace: .electronics))), mac),
            ("5-ipad", AnyView(IPadScreen(studio: Studio(workspace: .design))), pad)
        ]
        if paletteToo {
            let s = Studio(workspace: .design); s.palette = true; s.rendering = true
            jobs.append(("6-command-search", AnyView(DesignScreen(studio: s)), mac))
        }
        for (name, view, size) in jobs {
            let r = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
            r.scale = 2
            guard let cg = r.cgImage else { print("render failed", name); continue }
            let url = out.appendingPathComponent("\(name).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            print("wrote", url.path, cg.width, "x", cg.height)
        }
    }

    /// Lists SF Symbol names used by the prototype that this OS does not have.
    static func checkSymbols() {
        var names = Set<String>()
        for r in [Rails.design, Rails.generative, Rails.simulation, Rails.electronics, Rails.mechanics] { r.forEach { names.insert($0.glyph) } }
        Sample.commands.forEach { names.insert($0.1) }
        (Sample.handItems + Sample.handHistory + Sample.electronics).forEach { names.insert($0.glyph) }
        ["arrow.triangle.2.circlepath", "cube.transparent", "checkmark.shield", "square.3.layers.3d", "rectangle.on.rectangle",
         "square.on.square.dashed", "slider.horizontal.3", "scope", "waveform.path.ecg", "rotate.3d", "plus.magnifyingglass"].forEach { names.insert($0) }
        let missing = names.filter { !$0.hasPrefix("vf.") && NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        print(missing.isEmpty ? "all \(names.count) symbols present" : "missing symbols: \(missing.sorted())")
    }
}
