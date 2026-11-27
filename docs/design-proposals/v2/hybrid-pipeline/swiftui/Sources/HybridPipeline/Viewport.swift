import SwiftUI

// MARK: - Viewport placeholder (the live app hosts the Metal view here)

struct ViewportBackground: View {
    var grid = true
    var body: some View {
        ZStack {
            LinearGradient(colors: [VF.viewTop, VF.viewBottom], startPoint: .top, endPoint: .bottom)
            if grid {
                Canvas { ctx, size in
                    // Perspective floor grid that fades toward the horizon.
                    let horizon = size.height * 0.42
                    let vp = CGPoint(x: size.width * 0.5, y: horizon - size.height * 0.9)
                    for i in -16...16 {
                        let xb = size.width * 0.5 + CGFloat(i) * size.width * 0.11
                        var p = Path()
                        p.move(to: CGPoint(x: xb, y: size.height))
                        let t = (horizon - size.height) / (vp.y - size.height)
                        p.addLine(to: CGPoint(x: xb + (vp.x - xb) * t, y: horizon))
                        ctx.stroke(p, with: .color(.white.opacity(0.045)), lineWidth: 1)
                    }
                    for j in 0..<14 {
                        let f = pow(CGFloat(j) / 13, 1.8)
                        let y = horizon + (size.height - horizon) * f
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(p, with: .color(.white.opacity(0.02 + 0.035 * f)), lineWidth: 1)
                    }
                }
                .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6)))
            }
        }
    }
}

struct ViewCube: View {
    var s: CGFloat = 40
    var body: some View {
        let c: CGFloat = 0.866
        ZStack(alignment: .topLeading) {
            face("TOP", fill: Color(hex: 0x6A6C72))
                .transformEffect(CGAffineTransform(a: c, b: -0.5, c: c, d: 0.5, tx: 0, ty: 0.5 * s))
            face("FRONT", fill: Color(hex: 0x505257))
                .transformEffect(CGAffineTransform(a: c, b: 0.5, c: 0, d: 1, tx: 0, ty: 0.5 * s))
            face("RIGHT", fill: Color(hex: 0x3E4045))
                .transformEffect(CGAffineTransform(a: c, b: -0.5, c: 0, d: 1, tx: c * s, ty: s))
        }
        .frame(width: 1.732 * s, height: 2 * s, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }

    private func face(_ label: String, fill: Color) -> some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: [fill.opacity(1), fill.opacity(0.82)], startPoint: .top, endPoint: .bottom))
            Rectangle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            Text(label).font(.system(size: s * 0.2, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: s, height: s)
    }
}

struct Triad: View {
    var body: some View {
        Canvas { ctx, size in
            let o = CGPoint(x: 10, y: size.height - 12)
            func axis(_ to: CGPoint, _ color: Color, _ label: String, _ lp: CGPoint) {
                var p = Path(); p.move(to: o); p.addLine(to: to)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ctx.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(color), at: lp)
            }
            axis(CGPoint(x: o.x + 34, y: o.y + 8), VF.red, "X", CGPoint(x: o.x + 44, y: o.y + 9))
            axis(CGPoint(x: o.x + 22, y: o.y - 14), VF.green, "Y", CGPoint(x: o.x + 30, y: o.y - 20))
            axis(CGPoint(x: o.x, y: o.y - 40), VF.accent, "Z", CGPoint(x: o.x, y: o.y - 50))
        }
        .frame(width: 64, height: 72)
    }
}

struct NavPill: View {
    var body: some View {
        HStack(spacing: 4) {
            item("rotate.3d", on: true)
            item("hand.raised")
            item("magnifyingglass")
            item("arrow.up.left.and.down.right.magnifyingglass")
            item("eye")
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(Capsule().fill(VF.floating))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
    private func item(_ s: String, on: Bool = false) -> some View {
        Image(systemName: s).font(.system(size: 14, weight: .medium))
            .foregroundStyle(on ? VF.accent : VF.text.opacity(0.86))
            .frame(width: 36, height: 32)
    }
}

// MARK: - Context pill (adaptive suggestions near the selection)

struct ContextAction: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    var png: String? = nil
    var isOn = false
}

struct ContextPill: View {
    let actions: [ContextAction]
    var header: String? = "Context"
    var buttonSize = CGSize(width: 44, height: 44)
    var horizontalLabels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header { CapsLabel(text: header, size: 10).padding(.leading, 4) }
            HStack(spacing: horizontalLabels ? 0 : 6) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                    if horizontalLabels && i > 0 { Hairline(vertical: true).frame(height: 22) }
                    button(a)
                }
            }
        }
        .padding(horizontalLabels ? 4 : 8)
        .floatingSurface(radius: 12)
    }

    @ViewBuilder private func button(_ a: ContextAction) -> some View {
        let icon = Group {
            if let png = a.png { ToolIcon(glyph: .png(png), size: buttonSize.height * 0.5) }
            else { Image(systemName: a.symbol).font(.system(size: buttonSize.height * 0.36, weight: .medium)) }
        }
        if horizontalLabels {
            HStack(spacing: 7) { icon; Text(a.title).font(.system(size: 12.5)) }
                .padding(.horizontal, 12).frame(height: 34)
        } else {
            VStack(spacing: 4) {
                icon.frame(height: buttonSize.height * 0.55)
                Text(a.title).font(.system(size: buttonSize.height > 50 ? 13 : 10.5)).lineLimit(1).fixedSize()
            }
            .frame(minWidth: buttonSize.width, minHeight: buttonSize.height)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 10).fill(a.isOn ? VF.accent.opacity(0.18) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(a.isOn ? VF.accent : .clear, lineWidth: 1.5))
        }
    }
}

enum Anchor {
    /// Places a floating element next to the projected selection bounds:
    /// above and to the right first, then the other corners, clamped to the
    /// viewport with a 12 pt margin and kept clear of the `avoid` rects.
    /// Returns the element's centre for `.position`.
    static func place(_ size: CGSize, near sel: CGRect, in bounds: CGSize,
                      avoid: [CGRect] = [], gap: CGFloat = 12, margin: CGFloat = 12) -> CGPoint {
        let candidates = [
            CGPoint(x: sel.maxX + gap, y: sel.minY - size.height - gap),
            CGPoint(x: sel.maxX - size.width * 0.6, y: sel.minY - size.height - gap),
            CGPoint(x: sel.midX - size.width / 2, y: sel.minY - size.height - gap),
            CGPoint(x: sel.maxX + gap, y: sel.maxY + gap),
            CGPoint(x: sel.minX - size.width - gap, y: sel.minY - size.height - gap),
            CGPoint(x: sel.midX - size.width / 2, y: sel.maxY + gap),
            CGPoint(x: sel.maxX + gap, y: sel.midY - size.height / 2),
        ]
        let area = CGRect(x: margin, y: margin, width: bounds.width - 2 * margin, height: bounds.height - 2 * margin)
        func clamp(_ o: CGPoint) -> CGRect {
            CGRect(x: min(max(o.x, area.minX), area.maxX - size.width),
                   y: min(max(o.y, area.minY), area.maxY - size.height),
                   width: size.width, height: size.height)
        }
        let pick = candidates.first { o in
            let r = CGRect(origin: o, size: size)
            return area.contains(r) && !avoid.contains { $0.intersects(r) } && !r.intersects(sel)
        } ?? candidates[0]
        let r = clamp(pick)
        return CGPoint(x: r.midX, y: r.midY)
    }
}

struct DimensionCallout: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(VF.accent))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
            .shadow(color: VF.accent.opacity(0.45), radius: 6)
    }
}

/// A blue dimension line between two points with arrow ticks.
struct DimensionLine: Shape {
    let a: CGPoint
    let b: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: a); p.addLine(to: b)
        let ang = atan2(b.y - a.y, b.x - a.x)
        for (pt, dir) in [(a, ang), (b, ang + .pi)] {
            for d in [-0.45, 0.45] {
                p.move(to: pt)
                p.addLine(to: CGPoint(x: pt.x + 8 * cos(dir + d), y: pt.y + 8 * sin(dir + d)))
            }
            let n = dir + .pi / 2
            p.move(to: CGPoint(x: pt.x + 7 * cos(n), y: pt.y + 7 * sin(n)))
            p.addLine(to: CGPoint(x: pt.x - 7 * cos(n), y: pt.y - 7 * sin(n)))
        }
        return p
    }
}

struct OverlayCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(12).floatingSurface(radius: 12)
    }
}
