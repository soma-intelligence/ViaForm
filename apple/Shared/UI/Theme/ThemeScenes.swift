import Metal
import SwiftUI
import simd
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Colours of the 3D scenes (SceneKit flight scene, Metal viewport clear colour) and the bridge
// from a token to a platform colour. Kept out of ThemeTokens.swift so the token test target stays
// Foundation only.

#if os(macOS)
extension NSColor {
    /// The platform colour of a token (same components, same colour space as `NSColor(red:...)`).
    convenience init(vf c: VFColor) {
        self.init(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }
}
#else
extension UIColor {
    /// The platform colour of a token.
    convenience init(vf c: VFColor) {
        self.init(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }
}
#endif

/// The flight scene of Simulate (SimScene). It is a night scene in every variant: the drone,
/// the course and the sensor rays are content, read against a fixed dark floor, so they do not
/// follow Light and Dark.
struct VFSimSceneColors: Sendable {
    let background: VFColor
    let ground: VFColor
    /// Faint one-metre grid on the floor.
    let grid: VFColor
    /// The planned route between waypoints.
    let route: VFColor
    /// Intermediate waypoints.
    let waypoint: VFColor
    /// The goal pad.
    let goal: VFColor
    /// The flown trail.
    let trail: VFColor
    /// The tracked target.
    let target: VFColor
    /// Range-sensor rays that hit.
    let rayHit: VFColor
    let carbon: VFColor
    let battery: VFColor
    /// Front rotors (the drone's heading) and rear rotors.
    let rotorFront: VFColor
    let rotorRear: VFColor
    /// Obstacle colour when the course file's colour does not parse.
    let fallback: VFColor

    static let standard = VFSimSceneColors(
        background: VFColor(red: 0.14, green: 0.15, blue: 0.17),
        ground: VFColor(red: 0.19, green: 0.21, blue: 0.23),
        grid: VFColor(red: 1, green: 1, blue: 1, alpha: 0.07),
        route: VFColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        waypoint: VFColor(red: 1, green: 1, blue: 1, alpha: 0.5),
        goal: VFColor(red: 0.2, green: 0.8, blue: 0.45),
        trail: VFColor(red: 0.35, green: 0.7, blue: 1),
        target: VFColor(red: 1, green: 0.62, blue: 0.1, alpha: 0.9),
        rayHit: VFColor(red: 1, green: 0.35, blue: 0.3, alpha: 0.85),
        carbon: VFColor(red: 0.12, green: 0.12, blue: 0.12),
        battery: VFColor(red: 0.85, green: 0.25, blue: 0.2),
        rotorFront: VFColor(red: 0.3, green: 0.75, blue: 1, alpha: 0.55),
        rotorRear: VFColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 0.5),
        fallback: VFColor(hex: 0x8B93A1))
}

extension ViewportTheme {
    /// The colour the Metal view clears to before the backdrop pass covers it: the backdrop's
    /// bottom, so a frame that shows the clear (resize, first frame) does not flash.
    var clearColor: MTLClearColor {
        MTLClearColorMake(Double(backgroundBottom.x), Double(backgroundBottom.y), Double(backgroundBottom.z), 1)
    }
}
