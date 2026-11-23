import SwiftUI

struct ElectronicsScreen: View {
    @Bindable var studio: Studio

    var body: some View {
        MacShell(studio: studio, title: "Flight Controller rev 196") { cs in
            let board = cs.rect(430, 187, 975, 800)
            ZStack(alignment: .topLeading) {
                PCBCanvas()
                    .frame(width: board.width, height: board.height)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                    .position(x: board.midX, y: board.midY)

                // vertical popover at the selected net (selection type: net)
                AnchorLayout(anchor: cs.p(930, 300), side: .trailing, gap: 4, insets: EdgeInsets(top: 70, leading: 16, bottom: 16, trailing: 320)) {
                    NetPopover()
                }
                .frame(width: cs.size.width, height: cs.size.height)

                ToolRail(tools: Rails.electronics, active: studio.activeTool[.electronics] ?? "route") { studio.activeTool[.electronics] = $0 }
                    .padding(.leading, 18).padding(.top, 110)

                RightColumn(width: 290) {
                    BoardLinkCard { studio.workspace = .mechanics; studio.selection = "board" }
                    ElectronicsItemsCard(mode: $studio.sidebar)
                }
                BottomFurniture(nav: true)
            }
        }
    }
}

struct NetPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("point.topleft.down.to.point.bottomright.curvepath", "Route", tint: VF.accent)
            HStack {
                Text("Width").foregroundStyle(VF.text.opacity(0.8))
                Text("0.2 mm").monospacedDigit().foregroundStyle(VF.text.opacity(0.8))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.secondary)
            }
            .font(.system(size: 13)).padding(.leading, 30).frame(height: 30)
            row("circle.circle", "Via")
            row("checkmark.shield", "Re-check clearance")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(width: 224)
        .card(14)
    }
    func row(_ g: String, _ t: String, tint: Color = VF.text) -> some View {
        HStack(spacing: 10) {
            Image(systemName: g).font(.system(size: 14)).frame(width: 20)
            Text(t).font(.system(size: 13, weight: tint == VF.accent ? .medium : .regular))
            Spacer()
        }
        .foregroundStyle(tint).frame(height: 30)
    }
}

struct BoardLinkCard: View {
    var onShow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("In Frame v8").font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(VF.secondary)
            }
            .foregroundStyle(VF.text)
            Asset.image("board_in_frame").resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(height: 178).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(action: onShow) {
                Text("Show in 3D").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 32)
                    .background(Capsule().fill(VF.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .card()
    }
}

struct ElectronicsItemsCard: View {
    @Binding var mode: SidebarMode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PillSegments(items: [(SidebarMode.items, "Items"), (.history, "History")], selection: $mode,
                         height: 34, font: 13, activeTint: VF.accent, expand: true)
            VStack(spacing: 0) {
                ForEach(Sample.electronics) { n in
                    HStack(spacing: 10) {
                        Glyph(name: n.glyph, size: 15, weight: .light).frame(width: 22)
                        Text(n.name)
                        if let d = n.detail { Text(d).foregroundStyle(VF.secondary) }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.secondary)
                    }
                    .font(.system(size: 13)).foregroundStyle(VF.text)
                    .padding(.horizontal, 8).frame(height: 32)
                }
            }
            CardDivider().padding(.vertical, 4)
            HStack(spacing: 10) {
                Image(systemName: "square.3.layers.3d").font(.system(size: 15, weight: .light)).frame(width: 22)
                Text("Layers").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.secondary)
            }
            .foregroundStyle(VF.text).padding(.horizontal, 8).frame(height: 30)
            ForEach(Sample.layers, id: \.0) { l in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(l.1)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.15)))
                        .frame(width: 18, height: 18)
                    Text(l.0).font(.system(size: 13)).foregroundStyle(VF.text)
                    Spacer()
                    Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(VF.text.opacity(0.55))
                }
                .padding(.leading, 40).padding(.trailing, 8).frame(height: 28)
            }
            CardDivider().padding(.vertical, 4)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(VF.ok).frame(width: 22)
                Text("DRC").font(.system(size: 13, weight: .medium))
                Text("0 errors").font(.system(size: 13)).monospacedDigit().foregroundStyle(VF.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.secondary)
            }
            .foregroundStyle(VF.text).padding(.horizontal, 8).frame(height: 32)
        }
        .padding(10)
        .card()
    }
}

/// 2D board drawn in board space (545 x 613 units, scaled to the view).
/// In the app: PCBCanvas from apple/Shared fed by the PCBCraft engine, top layer red,
/// bottom layer blue, highlighted net in the accent colour.
struct PCBCanvas: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 545, size.height / 613)
            ctx.scaleBy(x: s, y: s)
            let top = Color(hex: 0xE0453A), bottom = Color(hex: 0x3A78E8), gold = Color(hex: 0xF1C45B)
            // board
            let boardRect = CGRect(x: 0, y: 0, width: 545, height: 613)
            ctx.fill(Path(roundedRect: boardRect, cornerRadius: 40), with: .color(Color(hex: 0x1E6B3A)))
            ctx.fill(Path(roundedRect: boardRect.insetBy(dx: 6, dy: 6), cornerRadius: 36), with: .color(Color(hex: 0x1F7A41)))

            func poly(_ pts: [CGPoint], _ c: Color, _ w: CGFloat = 2.2) {
                var p = Path(); p.addLines(pts)
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            let u1 = CGRect(x: 195, y: 205, width: 135, height: 125)

            // bottom layer (blue) traces first
            for i in 0..<9 {
                let y = 230 + CGFloat(i) * 11
                poly([pt(330, y), pt(372 + CGFloat(i) * 6, y - 30), pt(470, y - 60 - CGFloat(i) * 3), pt(545, y - 70 - CGFloat(i) * 3)], bottom, 1.6)
            }
            for i in 0..<6 {
                let x = 210 + CGFloat(i) * 18
                poly([pt(x, 330), pt(x - 30, 380), pt(x - 120 - CGFloat(i) * 10, 420 + CGFloat(i) * 8), pt(0, 430 + CGFloat(i) * 12)], bottom, 1.5)
            }
            poly([pt(345, 345), pt(400, 420), pt(400, 470)], bottom, 1.6)
            poly([pt(290, 55), pt(292, 98)], bottom, 2.6)

            // top layer (red): left pads to U1, bottom pads to U1, top pads down
            for i in 0..<6 {
                let py = 182 + CGFloat(i) * 35
                poly([pt(30, py), pt(120 + CGFloat(i) * 6, py), pt(160, 215 + CGFloat(i) * 15), pt(195, 215 + CGFloat(i) * 15)], top)
            }
            for i in 0..<10 {
                let x = 205 + CGFloat(i) * 12
                let bx = 120 + CGFloat(i) * 30
                poly([pt(x, 330), pt(x, 370 + CGFloat(i % 3) * 6), pt(bx, 470), pt(bx, 540)], top, 1.8)
            }
            for (i, x) in [170.0, 228, 343].enumerated() {
                poly([pt(x, 55), pt(x, 120 + CGFloat(i) * 8), pt(210 + CGFloat(i) * 30, 170), pt(210 + CGFloat(i) * 30, 205)], top)
            }
            for i in 0..<4 {
                let y = 270 + CGFloat(i) * 33
                poly([pt(525, y), pt(470, y), pt(420, y - 40 + CGFloat(i) * 10), pt(330, 240 + CGFloat(i) * 20)], top)
            }
            poly([pt(330, 300), pt(450, 360), pt(545, 430)], top, 1.8)
            poly([pt(60, 120), pt(140, 120), pt(195, 170)], top, 1.8)

            // vias
            for v in [pt(150, 120), pt(255, 160), pt(395, 170), pt(140, 245), pt(450, 225), pt(265, 455), pt(305, 470),
                      pt(415, 400), pt(110, 420), pt(500, 330)] {
                ctx.fill(Path(ellipseIn: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)), with: .color(gold))
                ctx.fill(Path(ellipseIn: CGRect(x: v.x - 1.6, y: v.y - 1.6, width: 3.2, height: 3.2)), with: .color(Color(hex: 0x12452A)))
            }

            // highlighted net, accent colour with soft glow
            let net = [pt(285, 55), pt(292, 98), pt(325, 131), pt(395, 245), pt(395, 315), pt(330, 381), pt(283, 381)]
            var glow = ctx; glow.addFilter(.blur(radius: 5))
            var np = Path(); np.addLines(net)
            glow.stroke(np, with: .color(Color(hex: 0x8A93FF, opacity: 0.8)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            ctx.stroke(np, with: .color(Color(hex: 0x6E79F0)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            for e in [net[1], net.last!] {
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - 6, y: e.y - 6, width: 12, height: 12)), with: .color(.white))
                ctx.stroke(Path(ellipseIn: CGRect(x: e.x - 6, y: e.y - 6, width: 12, height: 12)), with: .color(VF.accent), lineWidth: 2.5)
            }

            // ICs
            func chip(_ r: CGRect, _ name: String, pins: Int) {
                let pinC = Color(hex: 0xD9D9DB)
                for k in 0..<pins {
                    let fx = r.minX + 8 + CGFloat(k) * (r.width - 16) / CGFloat(pins - 1)
                    let fy = r.minY + 8 + CGFloat(k) * (r.height - 16) / CGFloat(pins - 1)
                    ctx.fill(Path(CGRect(x: fx - 1, y: r.minY - 9, width: 2, height: 9)), with: .color(pinC))
                    ctx.fill(Path(CGRect(x: fx - 1, y: r.maxY, width: 2, height: 9)), with: .color(pinC))
                    ctx.fill(Path(CGRect(x: r.minX - 9, y: fy - 1, width: 9, height: 2)), with: .color(pinC))
                    ctx.fill(Path(CGRect(x: r.maxX, y: fy - 1, width: 9, height: 2)), with: .color(pinC))
                }
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x3A3B3F), Color(hex: 0x1C1D20)]), startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
                ctx.fill(Path(ellipseIn: CGRect(x: r.minX + 8, y: r.minY + 8, width: 7, height: 7)), with: .color(.white.opacity(0.18)))
                ctx.draw(Text(name).font(.system(size: 17, weight: .medium)).foregroundColor(.white.opacity(0.92)), at: CGPoint(x: r.midX, y: r.midY))
            }
            chip(u1, "U1", pins: 16)
            chip(CGRect(x: 358, y: 415, width: 64, height: 62), "U2", pins: 7)

            // passives
            let passives: [(CGFloat, CGFloat, Bool, String?)] = [
                (100, 72, false, nil), (122, 72, false, nil), (110, 125, true, "R7"), (155, 98, true, nil),
                (218, 140, false, nil), (370, 97, true, nil), (372, 125, false, "R12"), (458, 120, true, nil),
                (90, 282, false, "C12"), (100, 223, true, nil), (120, 420, false, "R9"), (105, 480, false, "C11"),
                (390, 365, true, "C15"), (420, 378, false, nil), (455, 440, false, "R18"), (425, 508, true, nil),
                (325, 465, false, nil), (328, 440, false, nil), (460, 182, false, "R12"), (24, 490, false, nil)
            ]
            for (x, y, horiz, label) in passives {
                let r = horiz ? CGRect(x: x - 11, y: y - 6, width: 22, height: 12) : CGRect(x: x - 6, y: y - 11, width: 12, height: 22)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Color(hex: 0x8E8A82)))
                let cap = horiz ? [CGRect(x: r.minX, y: r.minY, width: 5, height: r.height), CGRect(x: r.maxX - 5, y: r.minY, width: 5, height: r.height)]
                                : [CGRect(x: r.minX, y: r.minY, width: r.width, height: 5), CGRect(x: r.minX, y: r.maxY - 5, width: r.width, height: 5)]
                for c in cap { ctx.fill(Path(c), with: .color(Color(hex: 0xE4E4E6))) }
                if let l = label {
                    ctx.draw(Text(l).font(.system(size: 14)).foregroundColor(.white), at: CGPoint(x: x + (horiz ? 0 : 26), y: y + (horiz ? 22 : 0)))
                }
            }
            // crystal C8
            let c8 = CGRect(x: 398, y: 68, width: 44, height: 36)
            ctx.fill(Path(roundedRect: c8, cornerRadius: 4), with: .color(Color(hex: 0x2C2D30)))
            ctx.stroke(Path(roundedRect: c8, cornerRadius: 4), with: .color(gold), lineWidth: 2)
            ctx.draw(Text("C8").font(.system(size: 14)).foregroundColor(.white), at: CGPoint(x: 428, y: 45))
            let c3 = CGRect(x: 425, y: 125, width: 40, height: 30)
            ctx.fill(Path(roundedRect: c3, cornerRadius: 3), with: .color(Color(hex: 0xBFB6A3)))
            ctx.draw(Text("C3").font(.system(size: 14)).foregroundColor(.white), at: CGPoint(x: 70, y: 100))

            // mounting holes
            for c in [pt(47, 45), pt(498, 45), pt(47, 565), pt(498, 565)] {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 34, y: c.y - 34, width: 68, height: 68)), with: .color(gold))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 25, y: c.y - 25, width: 50, height: 50)), with: .color(Color(hex: 0xF4F4F2)))
            }
            // pads + labels
            func pad(_ c: CGPoint, _ label: String, _ lp: CGPoint, round: Bool = false) {
                let r = CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)
                ctx.fill(round ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: 3), with: .color(gold))
                if round { ctx.stroke(Path(ellipseIn: r), with: .color(Color(hex: 0x2F5BD0)), lineWidth: 2.5) }
                ctx.draw(Text(label).font(.system(size: 16, weight: .medium)).foregroundColor(.white), at: lp)
            }
            for (x, n) in [(170.0, "5V"), (228, "GND"), (285, "3V3"), (343, "VCC")] { pad(pt(x, 42), n, pt(x, 15)) }
            for i in 0..<6 { let y = 182 + CGFloat(i) * 35; pad(pt(17, y), "S\(i + 1)", pt(48, y)) }
            for (i, n) in ["TX", "RX", "5V", "GND"].enumerated() { let y = 270 + CGFloat(i) * 33; pad(pt(525, y), n, pt(490, y)) }
            for (i, n) in ["M1", "M2", "M3", "M4", "GND"].enumerated() { let x = 155 + CGFloat(i) * 51; pad(pt(x, 555), n, pt(x, 588)) }
            pad(pt(408, 555), "VBAT", pt(408, 588), round: true)
        }
    }
}
