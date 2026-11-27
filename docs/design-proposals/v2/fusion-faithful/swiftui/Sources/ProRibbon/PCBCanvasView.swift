import SwiftUI

/// 2D PCB editor surface: dark grid so copper reads, a 30 x 30 mm flight controller drawn in
/// Canvas (board, mounting holes, edge pads, MCU, IMU, passives, F.Cu and B.Cu traces, vias).
struct PCBCanvasView: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(VF.pcbBack))
            var minor = Path(), major = Path()
            for x in stride(from: 0.0, through: size.width, by: 20) {
                let target = Int(x) % 100 == 0 ? 1 : 0
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                if target == 1 { major.addPath(p) } else { minor.addPath(p) }
            }
            for y in stride(from: 0.0, through: size.height, by: 20) {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                if Int(y) % 100 == 0 { major.addPath(p) } else { minor.addPath(p) }
            }
            ctx.stroke(minor, with: .color(Color.white.opacity(0.05)), lineWidth: 0.5)
            ctx.stroke(major, with: .color(Color.white.opacity(0.10)), lineWidth: 0.7)

            let side: CGFloat = 380
            let b = CGRect(x: (size.width - side) / 2 - 20, y: (size.height - side) / 2 - 6, width: side, height: side)
            drawBoard(&ctx, b)
        }
    }

    private func drawBoard(_ ctx: inout GraphicsContext, _ b: CGRect) {
        let board = Path(roundedRect: b, cornerRadius: 26)
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.6), radius: 14, y: 6))
            l.fill(board, with: .color(Color(hex: 0x0E5F2E)))
        }
        ctx.fill(board, with: .linearGradient(Gradient(colors: [Color(hex: 0x157A3B), Color(hex: 0x0C5528)]),
                                               startPoint: b.origin, endPoint: CGPoint(x: b.maxX, y: b.maxY)))
        ctx.stroke(board, with: .color(Color(hex: 0x9BE3A8)), lineWidth: 2)

        let red = Color(hex: 0xE5484D), blue = Color(hex: 0x3B6BFF), gold = Color(hex: 0xD9B24C)
        let u1 = CGRect(x: b.midX - 48, y: b.midY - 52, width: 96, height: 96)
        let imu = CGRect(x: b.midX - 22, y: b.maxY - 92, width: 50, height: 46)

        // traces first, under the parts
        var g = Rng(seed: 21)
        var fcu = Path(), bcu = Path()
        let leftPads = (0..<7).map { CGPoint(x: b.minX + 16, y: b.minY + 82 + CGFloat($0) * 30) }
        let rightPads = (0..<9).map { CGPoint(x: b.maxX - 16, y: b.minY + 72 + CGFloat($0) * 29) }
        for (i, p) in leftPads.enumerated() {
            let pin = CGPoint(x: u1.minX - 6, y: u1.minY + 10 + CGFloat(i) * 12.5)
            var t = Path()
            t.move(to: p)
            let knee = CGPoint(x: p.x + 40 + CGFloat(i % 3) * 10, y: p.y)
            t.addLine(to: knee)
            t.addLine(to: CGPoint(x: knee.x + abs(pin.y - p.y) * 0.6, y: pin.y))
            t.addLine(to: pin)
            if i % 2 == 0 { fcu.addPath(t) } else { bcu.addPath(t) }
        }
        for (i, p) in rightPads.enumerated() {
            let pin = CGPoint(x: u1.maxX + 6, y: u1.minY + 6 + CGFloat(i) * 10.5)
            var t = Path()
            t.move(to: p)
            let knee = CGPoint(x: p.x - 34 - CGFloat(i % 4) * 8, y: p.y)
            t.addLine(to: knee)
            t.addLine(to: CGPoint(x: knee.x - abs(pin.y - p.y) * 0.5, y: pin.y))
            t.addLine(to: pin)
            if i % 3 == 1 { bcu.addPath(t) } else { fcu.addPath(t) }
        }
        // motor outputs to the corners and IMU bus
        let corners = [CGPoint(x: b.minX + 44, y: b.minY + 44), CGPoint(x: b.maxX - 44, y: b.minY + 44),
                       CGPoint(x: b.minX + 44, y: b.maxY - 44), CGPoint(x: b.maxX - 44, y: b.maxY - 44)]
        for (i, c) in corners.enumerated() {
            var t = Path()
            let pin = CGPoint(x: i % 2 == 0 ? u1.minX + 20 : u1.maxX - 20, y: i < 2 ? u1.minY - 6 : u1.maxY + 6)
            t.move(to: pin)
            t.addLine(to: CGPoint(x: pin.x, y: i < 2 ? b.minY + 70 : b.maxY - 110))
            t.addLine(to: CGPoint(x: c.x + (i % 2 == 0 ? 40 : -40), y: i < 2 ? b.minY + 70 : b.maxY - 110))
            t.addLine(to: CGPoint(x: c.x + (i % 2 == 0 ? 26 : -26), y: c.y + (i < 2 ? 20 : -20)))
            fcu.addPath(t)
        }
        for k in 0..<4 {
            var t = Path()
            let x = u1.midX - 18 + CGFloat(k) * 12
            t.move(to: CGPoint(x: x, y: u1.maxY + 6))
            t.addLine(to: CGPoint(x: x, y: imu.minY - 18))
            t.addLine(to: CGPoint(x: imu.minX + 8 + CGFloat(k) * 11, y: imu.minY - 4))
            if k % 2 == 0 { bcu.addPath(t) } else { fcu.addPath(t) }
        }
        ctx.stroke(bcu, with: .color(blue.opacity(0.95)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        ctx.stroke(fcu, with: .color(red), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

        // vias
        for _ in 0..<26 {
            let p = CGPoint(x: b.minX + 70 + g.next() * (b.width - 140), y: b.minY + 70 + g.next() * (b.height - 140))
            if u1.insetBy(dx: -10, dy: -10).contains(p) { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(gold))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(.black))
        }

        // passives
        for _ in 0..<30 {
            let p = CGPoint(x: b.minX + 70 + g.next() * (b.width - 150), y: b.minY + 30 + g.next() * (b.height - 70))
            let r = CGRect(x: p.x, y: p.y, width: g.next() > 0.5 ? 12 : 7, height: g.next() > 0.5 ? 7 : 12)
            if u1.insetBy(dx: -8, dy: -8).intersects(r) || imu.insetBy(dx: -6, dy: -6).intersects(r) { continue }
            ctx.fill(Path(r), with: .color(Color(hex: 0x2A2A2A)))
            let cap = r.width > r.height ? CGRect(x: r.minX, y: r.minY, width: 3, height: r.height) : CGRect(x: r.minX, y: r.minY, width: r.width, height: 3)
            let cap2 = r.width > r.height ? CGRect(x: r.maxX - 3, y: r.minY, width: 3, height: r.height) : CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3)
            ctx.fill(Path(cap), with: .color(Color(hex: 0xC8CCD2)))
            ctx.fill(Path(cap2), with: .color(Color(hex: 0xC8CCD2)))
        }

        // edge pads
        for p in leftPads + rightPads {
            let r = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(gold))
            ctx.fill(Path(ellipseIn: r.insetBy(dx: 5, dy: 5)), with: .color(Color(hex: 0x3A2E12)))
        }
        // mounting holes
        for c in corners {
            let r = CGRect(x: c.x - 24, y: c.y - 24, width: 48, height: 48)
            ctx.fill(Path(ellipseIn: r), with: .color(gold))
            ctx.fill(Path(ellipseIn: r.insetBy(dx: 11, dy: 11)), with: .color(Color(hex: 0x0B0B0C)))
        }
        // U1 QFP
        var pins = Path()
        for k in 0..<12 {
            let o = CGFloat(k) * 7.4 + 7
            pins.addRect(CGRect(x: u1.minX + o, y: u1.minY - 8, width: 3.2, height: 8))
            pins.addRect(CGRect(x: u1.minX + o, y: u1.maxY, width: 3.2, height: 8))
            pins.addRect(CGRect(x: u1.minX - 8, y: u1.minY + o, width: 8, height: 3.2))
            pins.addRect(CGRect(x: u1.maxX, y: u1.minY + o, width: 8, height: 3.2))
        }
        ctx.fill(pins, with: .color(Color(hex: 0xC9CDD3)))
        ctx.fill(Path(roundedRect: u1, cornerRadius: 3), with: .color(Color(hex: 0x1A1B1E)))
        ctx.fill(Path(ellipseIn: CGRect(x: u1.minX + 8, y: u1.minY + 8, width: 6, height: 6)), with: .color(Color(hex: 0x3A3C40)))
        ctx.draw(Text("U1").font(.system(size: 17, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: u1.midX, y: u1.midY))
        // IMU
        ctx.fill(Path(roundedRect: imu, cornerRadius: 3), with: .color(Color(hex: 0x1A1B1E)))
        ctx.stroke(Path(roundedRect: imu.insetBy(dx: -3, dy: -3), cornerRadius: 4), with: .color(Color(hex: 0xC9CDD3)), lineWidth: 1.5)
        ctx.draw(Text("IMU").font(.system(size: 13, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: imu.midX, y: imu.midY))

        // silkscreen
        func silk(_ t: String, _ p: CGPoint, _ s: CGFloat = 19) {
            ctx.draw(Text(t).font(.system(size: s, weight: .bold)).foregroundColor(.white), at: p)
        }
        silk("M1", CGPoint(x: b.minX + 84, y: b.minY + 22))
        silk("M2", CGPoint(x: b.maxX - 84, y: b.minY + 22))
        silk("M3", CGPoint(x: b.minX + 84, y: b.maxY - 22))
        silk("M4", CGPoint(x: b.maxX - 84, y: b.maxY - 22))
        silk("5V", CGPoint(x: b.minX + 48, y: b.midY + 14), 18)
        silk("GND", CGPoint(x: b.minX + 54, y: b.midY + 40), 18)
    }
}
