import SwiftUI
import simd

// Glue between the theme and existing app types (the flow model, the Metal viewport).
// Kept apart from ThemeTokens.swift so the token test target compiles without the app.

extension FlowModel.Status {
    /// The theme's status for this pipeline state (same raw values).
    var vfStatus: VFStatus { VFStatus(rawValue: rawValue) ?? .empty }
}

extension VFStage {
    /// The stage for a core stage id ("design", "generate", ..., "make").
    init?(stageID: String) { self.init(rawValue: stageID) }
}

extension VFColor {
    var simd: SIMD4<Float> { SIMD4(Float(red), Float(green), Float(blue), Float(alpha)) }
}

extension ViaFormTheme {
    func color(_ s: FlowModel.Status) -> Color { status(s.vfStatus) }

    /// Metal viewport colours for this theme: gradient backdrop, accent highlight.
    var viewportTheme: ViewportTheme {
        let p = palette
        return ViewportTheme(
            backgroundTop: p.viewportTop.simd,
            backgroundBottom: p.viewportBottom.simd,
            highlight: p.accent.simd,
            hover: p.accent.opacity(0.55).simd,
            edge: (isDark ? VFColor(hex: 0x0B0C0E) : VFColor(hex: 0x2A2C31)).simd,
            gridOpacity: Float(p.gridOpacity))
    }
}
