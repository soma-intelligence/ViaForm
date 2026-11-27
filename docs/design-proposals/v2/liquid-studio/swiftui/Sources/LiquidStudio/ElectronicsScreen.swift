import SwiftUI

struct ElectronicsScreen: View {
    @Binding var workspace: Workspace
    @State private var crossSelected = true

    var body: some View {
        MacWindow(project: "Racer 3in", workspace: $workspace, plate: nil) { sidebar, inspector in
            ZStack {
                PCBCanvas(selected: crossSelected).frame(width: 540, height: 540).offset(x: -40, y: -10)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if sidebar { BoardSidebar() }
                        Spacer(minLength: 8)
                        PCBTools()
                    }
                    Spacer()
                    if inspector {
                        VStack(spacing: 8) {
                            LinkCard(selected: $crossSelected)
                            ComponentInspector()
                            Spacer(minLength: 0)
                        }
                    }
                }
                VStack {
                    Spacer()
                    StatusCapsule {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x34C759))
                        Text("DRC passed")
                        Dot()
                        Text("4 layers").font(Tok.mono(13))
                        Dot()
                        Text("36 x 36 mm").font(Tok.mono(13))
                        Dot()
                        Text("112 nets").font(Tok.mono(13))
                    }
                    .padding(.bottom, 12)
                }
                .offset(x: -40)
            }
        }
    }
}

struct BoardSidebar: View {
    let layers: [(String, UInt32)] = [("F.Cu", 0xF5A524), ("In1.Cu", 0x34C759), ("In2.Cu", 0x8B5CF6),
                                      ("B.Cu", 0x3B82F6), ("F.Silk", 0xF2F2F2), ("F.Mask", 0x6B7280)]
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "cpu", title: "Board rev 196")
            Hairline()
            VStack(spacing: 1) {
                TreeRowView(row: TreeRow(level: 0, label: "Layers", symbol: "square.3.layers.3d", expanded: true, eye: false))
                ForEach(layers, id: \.0) { n, c in
                    TreeRowView(row: TreeRow(level: 1, label: n, swatch: Color(hex: c)))
                }
            }.padding(.vertical, 4)
            Hairline()
            VStack(spacing: 1) {
                TreeRowView(row: TreeRow(level: 0, label: "Schematic sheets", symbol: "doc.plaintext", expanded: true, eye: false))
                ForEach(Array(["Power 5V 3V3", "MCU", "ESC 4 in 1", "Sensors"].enumerated()), id: \.offset) { i, s in
                    TreeRowView(row: TreeRow(level: 1, label: s, symbol: "doc", detail: "\(i + 1)", eye: false))
                }
            }.padding(.vertical, 4)
            Hairline()
            VStack(spacing: 1) {
                TreeRowView(row: TreeRow(level: 0, label: "Components", symbol: "cpu", expanded: true, detail: "64", eye: false))
                TreeRowView(row: TreeRow(level: 1, label: "U1  STM32F405", symbol: "cpu", selected: true, eye: false, chevronRight: true))
                TreeRowView(row: TreeRow(level: 1, label: "U2  ICM-42688", symbol: "cpu", eye: false))
                TreeRowView(row: TreeRow(level: 1, label: "J1  USB-C", symbol: "cable.connector", eye: false))
                TreeRowView(row: TreeRow(level: 1, label: "J2  XT30", symbol: "bolt", eye: false))
                TreeRowView(row: TreeRow(level: 1, label: "J3  Camera", symbol: "camera", eye: false))
            }.padding(.vertical, 4)
            Hairline()
            TreeRowView(row: TreeRow(level: 0, label: "Nets", symbol: "point.3.connected.trianglepath.dotted",
                                     expanded: false, detail: "112", eye: false))
                .padding(.vertical, 4)
        }
        .frame(width: 280)
        .glass()
    }
}

struct PCBTools: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array([("point.topleft.down.to.point.bottomright.curvepath", "Route"), ("circle.circle", "Via"),
                           ("square.dashed", "Zone"), ("ruler", "Measure"), ("checklist", "DRC")].enumerated()),
                    id: \.offset) { i, t in
                VStack(spacing: 4) {
                    Image(systemName: t.0).font(.system(size: 16, weight: .medium))
                    Text(t.1).font(Tok.caption())
                }
                .foregroundStyle(Tok.primary)
                .frame(width: 60, height: 54)
                .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(i == 0 ? 0.13 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(i == 0 ? 0.14 : 0), lineWidth: 1))
            }
        }
        .padding(6)
        .glass(16)
    }
}

/// Picture-in-picture 3D link: the board mounted in the frame. Click cross-selects U1 in 3D, double click opens Design.
struct LinkCard: View {
    @Binding var selected: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.primary)
                Text("3D link").font(Tok.body(.semibold)).foregroundStyle(Tok.primary)
                Dot()
                Text("Mounted in Frame v8").font(Tok.body()).foregroundStyle(Tok.secondary)
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11)).foregroundStyle(Tok.secondary)
            }
            Asset.plate("mounted").resizable().aspectRatio(contentMode: .fill)
                .frame(height: 196).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.and.right").font(.system(size: 9, weight: .bold))
                        Text("Clearance 0.6 mm").font(Tok.mono(11, .medium))
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9).frame(height: 24)
                    .glassCapsule(tint: 0.85)
                    .overlay(Capsule().strokeBorder(accent.opacity(0.8), lineWidth: 1))
                    .padding(8)
                }
                .overlay(alignment: .topLeading) {
                    Text("Live").font(Tok.caption(.semibold)).foregroundStyle(Tok.primary)
                        .padding(.horizontal, 7).frame(height: 18).glassCapsule(tint: 0.7).padding(8)
                }
                .onTapGesture { selected.toggle() }
        }
        .padding(Tok.pad).frame(width: 360)
        .glass()
    }
}

struct ComponentInspector: View {
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "cpu", title: "U1 \u{00B7} STM32F405", close: true)
            Hairline()
            VStack(spacing: 0) {
                KVRow(key: "Package", value: "LQFP64", picker: true)
                KVRow(key: "Layer", value: "Top", mono: false, picker: true, dot: Color(hex: 0xF5A524))
                KVRow(key: "Position", value: "15.25, 15.25 mm")
                KVRow(key: "Rotation", value: "45.0 deg")
            }.padding(.vertical, 6)
            Hairline()
            VStack(spacing: 0) {
                KVRow(key: "Nets", value: "48")
                KVRow(key: "Unrouted", value: "3")
                KVRow(key: "DRC", value: "0 errors", check: true)
            }.padding(.vertical, 6)
            HStack(spacing: 8) {
                PrimaryButton(title: "Route")
                SecondaryButton(title: "Show in 3D")
            }
            .padding(Tok.pad)
        }
        .frame(width: 360)
        .glass()
    }
}

/// 2D board canvas: 36 x 36 mm flight controller, four layers, U1 selected, an amber ratsnest.
struct PCBCanvas: View {
    var selected: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 40, o = CGPoint(x: 2 * s, y: 2 * s)
            func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
            func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: o.x + x * s, y: o.y + y * s, width: w * s, height: h * s) }
            let gold = Color(hex: 0xD4A94F), fcu = Color(hex: 0xE07B28), in1 = Color(hex: 0xC2362F), bcu = Color(hex: 0x3B6FD6)

            // Board
            let board = Path(roundedRect: R(0, 0, 36, 36), cornerRadius: 3 * s)
            ctx.drawLayer { g in
                g.addFilter(.shadow(color: .black.opacity(0.6), radius: 24, y: 12))
                g.fill(board, with: .color(Color(hex: 0x0F4D2C)))
            }
            ctx.fill(board, with: .linearGradient(Gradient(colors: [Color(hex: 0x15603A), Color(hex: 0x0B3D23)]),
                                                  startPoint: P(0, 0), endPoint: P(36, 36)))
            ctx.stroke(board, with: .color(Color(hex: 0x3D8F5C)), lineWidth: 1.5)

            // Inner-layer traces under everything (faint).
            var inner = Path()
            for i in 0..<9 {
                let y = 9.0 + Double(i) * 2.2
                inner.move(to: P(4, y)); inner.addLine(to: P(9, y)); inner.addLine(to: P(11, y + 2))
            }
            ctx.stroke(inner, with: .color(bcu.opacity(0.55)), lineWidth: 0.25 * s)

            // Traces from U1 fanning out.
            var seed: UInt64 = 11
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            for side in 0..<4 {
                for k in 0..<7 {
                    let t = -4.5 + Double(k) * 1.5
                    var p = Path()
                    let len = 4 + rnd() * 6
                    switch side {
                    case 0: p.move(to: P(18 + t, 12.5)); p.addLine(to: P(18 + t, 10.5)); p.addLine(to: P(18 + t * 1.8, 10.5 - len * 0.6)); p.addLine(to: P(18 + t * 1.8, 4.5))
                    case 1: p.move(to: P(23.5, 18 + t)); p.addLine(to: P(25.5, 18 + t)); p.addLine(to: P(25.5 + len * 0.6, 18 + t * 1.7)); p.addLine(to: P(32, 18 + t * 1.7))
                    case 2: p.move(to: P(18 + t, 23.5)); p.addLine(to: P(18 + t, 25.5)); p.addLine(to: P(18 + t * 1.6, 25.5 + len * 0.5)); p.addLine(to: P(18 + t * 1.6, 31))
                    default: p.move(to: P(12.5, 18 + t)); p.addLine(to: P(10.5, 18 + t)); p.addLine(to: P(10.5 - len * 0.5, 18 + t * 1.6)); p.addLine(to: P(4.5, 18 + t * 1.6))
                    }
                    ctx.stroke(p, with: .color((k % 3 == 0 ? in1 : fcu).opacity(0.9)), style: StrokeStyle(lineWidth: 0.22 * s, lineCap: .round, lineJoin: .round))
                    if k % 2 == 0, let end = p.currentPoint {
                        ctx.fill(Path(ellipseIn: CGRect(x: end.x - 0.45 * s, y: end.y - 0.45 * s, width: 0.9 * s, height: 0.9 * s)), with: .color(gold))
                        ctx.fill(Path(ellipseIn: CGRect(x: end.x - 0.2 * s, y: end.y - 0.2 * s, width: 0.4 * s, height: 0.4 * s)), with: .color(.black.opacity(0.7)))
                    }
                }
            }

            // Passives scattered around, avoiding the centre and corners.
            var placed: [CGRect] = [R(5.5, 1, 8, 4.5), R(22.5, 1, 8, 4.5), R(5.5, 30, 8, 5), R(22.5, 30, 8, 5), R(24.5, 8.4, 5, 5.2), R(13.5, 30.5, 9, 6)]
            for _ in 0..<160 {
                let x = 3 + rnd() * 29, y = 6 + rnd() * 25
                if abs(x - 18) < 7.5 && abs(y - 18) < 7.5 { continue }
                if (x < 7 || x > 29) && (y < 7 || y > 29) { continue }
                let vertical = rnd() > 0.5
                let big = rnd() > 0.8
                let w = vertical ? (big ? 1.3 : 0.9) : (big ? 2.2 : 1.6), h = vertical ? (big ? 2.2 : 1.6) : (big ? 1.3 : 0.9)
                let r = R(x, y, w, h)
                if placed.contains(where: { $0.intersects(r.insetBy(dx: -0.5 * s, dy: -0.5 * s)) }) { continue }
                placed.append(r)
                ctx.fill(Path(r), with: .color(rnd() > 0.3 ? Color(hex: 0x8A6A45) : Color(hex: 0x2A2A2E)))
                let cap = vertical ? CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.28) : CGRect(x: r.minX, y: r.minY, width: r.width * 0.28, height: r.height)
                ctx.fill(Path(cap), with: .color(Color(hex: 0xC9C9CF)))
                let cap2 = vertical ? cap.offsetBy(dx: 0, dy: r.height * 0.72) : cap.offsetBy(dx: r.width * 0.72, dy: 0)
                ctx.fill(Path(cap2), with: .color(Color(hex: 0xC9C9CF)))
            }

            // Mounting holes.
            for (x, y) in [(3.0, 3.0), (33.0, 3.0), (3.0, 33.0), (33.0, 33.0)] {
                ctx.fill(Path(ellipseIn: R(x - 2.4, y - 2.4, 4.8, 4.8)), with: .color(gold))
                ctx.fill(Path(ellipseIn: R(x - 1.6, y - 1.6, 3.2, 3.2)), with: .color(Color(hex: 0x121316)))
            }

            // Motor pads M1..M4 with silk boxes.
            for (i, (x, y)) in [(8.0, 2.0), (24.0, 2.0), (8.0, 32.0), (24.0, 32.0)].enumerated() {
                let box = Path(roundedRect: R(x - 0.6, y - 0.4, 5.2, 2.4), cornerRadius: 0.5 * s)
                ctx.stroke(box, with: .color(.white.opacity(0.8)), lineWidth: 1)
                for k in 0..<3 {
                    ctx.fill(Path(ellipseIn: R(x + Double(k) * 1.6, y + 0.1, 1.4, 1.4)), with: .color(gold))
                    ctx.fill(Path(ellipseIn: R(x + 0.45 + Double(k) * 1.6, y + 0.55, 0.5, 0.5)), with: .color(.black.opacity(0.6)))
                }
                let label = Text("M\(i + 1)").font(.system(size: 1.4 * s, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                ctx.draw(label, at: P(x + 2, y < 10 ? y + 3.4 : y - 1.4))
            }

            // U2 IMU.
            ctx.fill(Path(roundedRect: R(25, 9, 4, 4), cornerRadius: 2), with: .color(Color(hex: 0x1B1C20)))
            for k in 0..<5 {
                ctx.fill(Path(R(25.4 + Double(k) * 0.7, 8.6, 0.35, 0.4)), with: .color(Color(hex: 0xC9C9CF)))
                ctx.fill(Path(R(25.4 + Double(k) * 0.7, 13.0, 0.35, 0.4)), with: .color(Color(hex: 0xC9C9CF)))
            }
            ctx.draw(Text("U2").font(.system(size: 1.1 * s, design: .monospaced)).foregroundStyle(.white.opacity(0.7)), at: P(27, 11))

            // U1 QFP.
            let u1 = R(12.5, 12.5, 11, 11)
            for k in 0..<16 {
                let t = 13.2 + Double(k) * 0.62
                for r in [R(t, 11.4, 0.3, 1.1), R(t, 23.5, 0.3, 1.1), R(11.4, t, 1.1, 0.3), R(23.5, t, 1.1, 0.3)] {
                    ctx.fill(Path(r), with: .color(Color(hex: 0xD2D2D8)))
                }
            }
            ctx.fill(Path(roundedRect: u1, cornerRadius: 3), with: .linearGradient(Gradient(colors: [Color(hex: 0x2B2C31), Color(hex: 0x17181B)]),
                                                                                    startPoint: CGPoint(x: u1.minX, y: u1.minY), endPoint: CGPoint(x: u1.maxX, y: u1.maxY)))
            ctx.fill(Path(ellipseIn: R(13.4, 13.4, 1, 1)), with: .color(.white.opacity(0.25)))
            ctx.draw(Text("U1").font(.system(size: 1.3 * s, design: .monospaced)).foregroundStyle(.white.opacity(0.6)), at: P(18, 17))
            ctx.draw(Text("STM32F405").font(.system(size: 1.1 * s, design: .monospaced)).foregroundStyle(.white.opacity(0.5)), at: P(18, 19))
            if selected {
                let sel = Path(roundedRect: u1.insetBy(dx: -1.6 * s, dy: -1.6 * s), cornerRadius: 6)
                ctx.drawLayer { g in
                    g.addFilter(.shadow(color: accent, radius: 8))
                    g.stroke(sel, with: .color(accent), lineWidth: 2)
                }
            }

            // Ratsnest: unrouted connections in the accent.
            for (a, b) in [(P(9.4, 3.0), P(13.8, 12.0)), (P(31, 22), P(23.9, 19.4)), (P(26.5, 13.4), P(22.4, 11.6))] {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(accent), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                for q in [a, b] { ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)), with: .color(accent)) }
            }

            // USB-C at the bottom edge.
            let usb = R(14.5, 31.5, 7, 5.4)
            ctx.fill(Path(roundedRect: usb, cornerRadius: 0.6 * s), with: .linearGradient(Gradient(colors: [Color(hex: 0xE4E4EA), Color(hex: 0x8C8C94)]),
                                                                                         startPoint: CGPoint(x: usb.minX, y: usb.minY), endPoint: CGPoint(x: usb.minX, y: usb.maxY)))
            ctx.fill(Path(roundedRect: R(15.6, 34.0, 4.8, 1.6), cornerRadius: 0.8 * s), with: .color(Color(hex: 0x2A2A2E)))

            // Silkscreen.
            ctx.draw(Text("FC rev 196").font(.system(size: 1.5 * s, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.92)), at: P(18, 3.0))
            ctx.draw(Text("J1").font(.system(size: 1.3 * s, design: .monospaced)).foregroundStyle(.white.opacity(0.9)), at: P(12.6, 34.6))
            ctx.draw(Text("4R7").font(.system(size: 1.1 * s, design: .monospaced)).foregroundStyle(.white.opacity(0.7)), at: P(29.5, 18))
        }
    }
}
