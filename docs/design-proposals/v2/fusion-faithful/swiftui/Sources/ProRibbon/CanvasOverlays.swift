import SwiftUI

// MARK: - Viewport background

/// Light viewport: #DCE6F0 to white, faint perspective floor grid.
struct ViewportBackground: View {
    var floor = true
    var body: some View {
        ZStack {
            LinearGradient(colors: [VF.canvasTop, Color(hex: 0xEEF3F8), .white], startPoint: .top, endPoint: .bottom)
            if floor {
                Canvas { ctx, size in
                    let horizon = size.height * 0.42
                    let vanish = CGPoint(x: size.width * 0.5, y: horizon - size.height * 0.9)
                    var p = Path()
                    for i in -30...30 {
                        let x = size.width * 0.5 + CGFloat(i) * 90
                        p.move(to: CGPoint(x: x, y: size.height))
                        let t = (horizon - size.height) / (vanish.y - size.height)
                        p.addLine(to: CGPoint(x: x + (vanish.x - x) * t, y: horizon))
                    }
                    var y = size.height
                    var step: CGFloat = (size.height - horizon) * 0.145
                    while y > horizon, step > 1.5 {
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        y -= step
                        step = max(step * 0.86, 0)
                    }
                    ctx.stroke(p, with: .linearGradient(Gradient(colors: [Color(hex: 0x9FB3C8, alpha: 0), Color(hex: 0x9FB3C8, alpha: 0.28)]),
                                                        startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)),
                               lineWidth: 0.7)
                }
            }
        }
    }
}

// MARK: - Browser

struct BrowserOverlay: View {
    let rows: [TreeRow]
    var title = "BROWSER"
    var closable = false
    var width: CGFloat = 300
    var trailingEye = false
    var onSelect: (TreeRow) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: title, disclosure: !closable, trailing: closable ? "xmark" : nil)
            Hairline(color: VF.separator.opacity(0.6))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    BrowserRow(row: r, trailingEye: trailingEye)
                        .onTapGesture { onSelect(r) }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .frame(width: width)
        .floatingCard()
    }
}

struct BrowserRow: View {
    let row: TreeRow
    var trailingEye = false

    var body: some View {
        let fg = row.selected ? Color.white : VF.ink
        let sub = row.selected ? Color.white.opacity(0.85) : VF.secondary
        HStack(spacing: 7) {
            Color.clear.frame(width: CGFloat(row.level) * 14)
            Group {
                if let e = row.expanded {
                    Image(systemName: e ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            .foregroundStyle(sub)
            if !trailingEye {
                Image(systemName: row.eye ? "eye" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(row.eye ? sub : .clear)
                    .frame(width: 16)
            }
            Image(systemName: row.glyph)
                .font(.system(size: 13))
                .foregroundStyle(row.selected ? Color.white : Color(hex: 0x7A7F87))
                .frame(width: 16)
            Text(row.name).font(.system(size: 13)).foregroundStyle(fg).lineLimit(1)
            if let d = row.detail {
                Text(d).font(.system(size: 13)).foregroundStyle(sub).lineLimit(1)
            }
            Spacer(minLength: 0)
            if trailingEye {
                Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(sub)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: VF.macRow)
        .background(RoundedRectangle(cornerRadius: 4).fill(row.selected ? VF.accent : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - View cube

struct ViewCube: View {
    var size: CGFloat = 90
    var showHome = true

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showHome {
                Image(systemName: "house.fill").font(.system(size: 15)).foregroundStyle(Color(hex: 0x5D6470)).padding(.top, 4)
            }
            Canvas { ctx, s in
                let c = CGPoint(x: s.width / 2, y: s.height / 2)
                let a = s.width * 0.42
                let h = a * 0.5
                let top = CGPoint(x: c.x, y: c.y - a * 0.95)
                let left = CGPoint(x: c.x - a * 0.86, y: c.y - h)
                let right = CGPoint(x: c.x + a * 0.86, y: c.y - h)
                let mid = CGPoint(x: c.x, y: c.y)
                let bl = CGPoint(x: left.x, y: left.y + a)
                let br = CGPoint(x: right.x, y: right.y + a)
                let bot = CGPoint(x: c.x, y: c.y + a)
                func poly(_ pts: [CGPoint]) -> Path { var p = Path(); p.addLines(pts); p.closeSubpath(); return p }
                let topFace = poly([top, right, mid, left])
                let front = poly([left, mid, bot, bl])
                let side = poly([mid, right, br, bot])
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: .black.opacity(0.18), radius: 4, y: 3))
                    l.fill(poly([top, right, br, bot, bl, left]), with: .color(Color(hex: 0xE4E7EB)))
                }
                ctx.fill(topFace, with: .color(Color(hex: 0xF4F5F7)))
                ctx.fill(front, with: .color(Color(hex: 0xE2E5E9)))
                ctx.fill(side, with: .color(Color(hex: 0xD3D7DD)))
                for f in [topFace, front, side] { ctx.stroke(f, with: .color(Color(hex: 0xA9AFB8)), lineWidth: 0.8) }

                func label(_ t: String, at p: CGPoint, _ m: CGAffineTransform) {
                    var c2 = ctx
                    c2.translateBy(x: p.x, y: p.y)
                    c2.concatenate(m)
                    c2.draw(Text(t).font(.system(size: a * 0.24, weight: .medium)).foregroundColor(Color(hex: 0x5A606A)),
                            at: .zero)
                }
                let cx = (left.x + mid.x) / 2, cy = (left.y + bot.y) / 2
                label("TOP", at: CGPoint(x: c.x, y: c.y - h), CGAffineTransform(a: 0.86, b: -0.5, c: 0.86, d: 0.5, tx: 0, ty: 0))
                label("FRONT", at: CGPoint(x: cx, y: cy), CGAffineTransform(a: 0.86, b: 0.5, c: 0, d: 1, tx: 0, ty: 0))
                label("RIGHT", at: CGPoint(x: (mid.x + right.x) / 2, y: cy), CGAffineTransform(a: 0.86, b: -0.5, c: 0, d: 1, tx: 0, ty: 0))
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Navigation bar

struct NavBar: View {
    static let symbols = ["rotate.3d", "hand.raised", "plus.magnifyingglass", "viewfinder", "display", "grid", "square.split.2x2"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(NavBar.symbols, id: \.self) { s in
                Button {} label: {
                    Image(systemName: s).font(.system(size: 18)).foregroundStyle(Color(hex: 0x3A3A3C))
                        .frame(width: 44, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .floatingCard(radius: 10)
    }
}

// MARK: - Triad

struct Triad: View {
    var body: some View {
        Canvas { ctx, s in
            let o = CGPoint(x: 18, y: s.height - 16)
            func arrow(_ to: CGPoint, _ color: Color, _ label: String, _ lp: CGPoint) {
                var p = Path(); p.move(to: o); p.addLine(to: to)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                let ang = atan2(to.y - o.y, to.x - o.x)
                var h = Path()
                h.move(to: to)
                h.addLine(to: CGPoint(x: to.x - 7 * cos(ang - 0.4), y: to.y - 7 * sin(ang - 0.4)))
                h.addLine(to: CGPoint(x: to.x - 7 * cos(ang + 0.4), y: to.y - 7 * sin(ang + 0.4)))
                h.closeSubpath()
                ctx.fill(h, with: .color(color))
                ctx.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(color), at: lp)
            }
            arrow(CGPoint(x: 18, y: 10), Color(hex: 0x1F5EFF), "Z", CGPoint(x: 18, y: 2))
            arrow(CGPoint(x: 52, y: s.height - 36), Color(hex: 0x23A047), "Y", CGPoint(x: 60, y: s.height - 42))
            arrow(CGPoint(x: 62, y: s.height - 4), Color(hex: 0xE0342B), "X", CGPoint(x: 72, y: s.height - 4))
        }
        .frame(width: 80, height: 74)
    }
}

// MARK: - Command dialog

struct DialogRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let symbol: String
}

struct CommandDialog: View {
    let title: String
    let symbol: String
    let rows: [DialogRow]
    var onCancel: () -> Void = {}
    var onOK: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink)
                Text(title).font(.system(size: 13, weight: .semibold)).kerning(0.3)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(VF.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Hairline(color: VF.separator.opacity(0.7))
            VStack(spacing: 10) {
                ForEach(rows) { r in
                    HStack(spacing: 0) {
                        Text(r.label).font(.system(size: 13)).foregroundStyle(VF.ink).frame(width: 95, alignment: .leading)
                        PopupValue(symbol: r.symbol, value: r.value)
                    }
                }
            }
            .padding(14)
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel).buttonStyle(VFBordered(height: 34))
                Button("OK", action: onOK).buttonStyle(VFProminent(height: 34))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 310)
        .floatingCard()
    }
}

struct PopupValue: View {
    let symbol: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color(hex: 0x4A4F57)).frame(width: 18)
            Text(value).font(.system(size: 13)).foregroundStyle(VF.ink)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: 0xCFCFCF), lineWidth: 1))
    }
}

/// Small value tag anchored to a drag handle in the canvas.
struct ValueBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(VF.ink)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(VF.accent, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}
