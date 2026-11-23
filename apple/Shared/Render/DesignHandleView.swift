import SwiftUI
import simd
#if os(macOS)
import AppKit
#endif

/// A Shapr3D-style distance handle: an arrow from the picked face (or the extrude profile's
/// centre) along its normal, with a round grip at the tip. Dragging the grip sets the distance
/// live through the tool's preview (`DesignModel.applyPreview`); the value card stays for
/// typing. From Select the handle arms Push / Pull and commits on release (one undo step).
///
/// Snapping: 0.5 mm steps; Shift snaps to 5 mm; Command (on the Mac) drags freely.
struct DesignDistanceHandle: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let point: SIMD3<Double>
    let normal: SIMD3<Double>
    let size: CGSize
    /// Touch: a 44 point grip.
    var touch = false
    @State private var startTip: CGPoint?

    var body: some View {
        let anchor = model.camera.project(point, size: size)
        let tip = Self.tip(model: model, point: point, normal: normal, size: size)
        let grip: CGFloat = touch ? 28 : 18
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            arrow(from: anchor, to: tip).allowsHitTesting(false)
            Circle()
                .fill(theme.accent)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: touch ? 13 : 9, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .rotationEffect(.radians(atan2(tip.x - anchor.x, -(tip.y - anchor.y))))
                )
                .frame(width: grip, height: grip)
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                .frame(width: touch ? 44 : 30, height: touch ? 44 : 30)
                .contentShape(Circle())
                .position(tip)
                .gesture(drag)
                #if os(macOS)
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                #endif
                .help("Drag to set the distance. Shift snaps to 5 mm, Command drags freely")
                .accessibilityLabel("Distance handle")
                .accessibilityValue(String(format: "%.1f mm", model.toolValue))
                .accessibilityAdjustableAction { dir in
                    model.beginHandleDrag()
                    model.dragHandle(by: dir == .increment ? 1 : -1, step: 0.5)
                    model.endHandleDrag()
                }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                if !model.handleDragging { model.beginHandleDrag() }
                let axis = model.handleScreenAxis(point: point, normal: normal, size: size)
                let along = Double(g.translation.width * axis.dir.dx + g.translation.height * axis.dir.dy)
                model.dragHandle(by: along / max(axis.perUnit, 1e-9), step: Self.step)
            }
            .onEnded { _ in model.endHandleDrag() }
    }

    /// The snapping step for the keys held now.
    private static var step: Double {
        #if os(macOS)
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) { return 0.01 }
        if mods.contains(.shift) { return 5 }
        #endif
        return 0.5
    }

    private func arrow(from a: CGPoint, to b: CGPoint) -> some View {
        Canvas { ctx, _ in
            let c = theme.accent
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            ctx.stroke(line, with: .color(c), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            let r: CGFloat = 4.5
            ctx.fill(Path(ellipseIn: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: a.x - r + 1.5, y: a.y - r + 1.5, width: (r - 1.5) * 2, height: (r - 1.5) * 2)), with: .color(c))
        }
    }

    /// Where the grip sits: the value along the axis on screen, at least 56 and at most 180
    /// points from the anchor so a small or huge value stays reachable; a negative value points
    /// the other way.
    static func tip(model: DesignModel, point: SIMD3<Double>, normal: SIMD3<Double>, size: CGSize) -> CGPoint {
        let a = model.camera.project(point, size: size)
        let axis = model.handleScreenAxis(point: point, normal: normal, size: size)
        let v = model.tool == .select ? 0 : model.toolValue
        let shown = min(max(abs(v) * axis.perUnit, 56), 180) * (v < 0 ? -1 : 1)
        return CGPoint(x: a.x + axis.dir.dx * shown, y: a.y + axis.dir.dy * shown)
    }
}
