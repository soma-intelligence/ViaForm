import SwiftUI

enum ElectronicsStage {
    static let states: PipelineStates = [
        .design: .upToDate, .generative: .upToDate, .mechanics: .upToDate, .electronics: .upToDate,
        .simulation: .running, .training: .upToDate, .render: .upToDate, .manufacture: .stale,
    ]

    static var screen: StageScreen {
        StageScreen(
            project: "Drone 3in Mk2",
            workspace: .electronics,
            states: states,
            groups: [
                .init(title: "Place", tools: [.init(glyph: .symbol("cpu"), caption: "Component"), .init(glyph: .symbol("circle.circle"), caption: "Pad"), .init(glyph: .symbol("smallcircle.filled.circle"), caption: "Via"), .init(glyph: .symbol("textformat"), caption: "Text"), .init(glyph: .symbol("hexagon"), caption: "Polygon")]),
                .init(title: "Route", tools: [.init(glyph: .symbol("point.topleft.down.to.point.bottomright.curvepath", VF.accent), caption: "Track", isOn: true), .init(glyph: .symbol("scribble.variable"), caption: "Trace"), .init(glyph: .symbol("record.circle"), caption: "Via"), .init(glyph: .symbol("xmark"), caption: "Remove")]),
                .init(title: "Check", tools: [.init(glyph: .symbol("checkmark"), caption: "DRC"), .init(glyph: .symbol("bolt"), caption: "ERC"), .init(glyph: .symbol("list.bullet.rectangle"), caption: "Rules")]),
                .init(title: "Link", tools: [.init(glyph: .symbol("square.and.arrow.up"), caption: "Export"), .init(glyph: .symbol("square.and.arrow.down"), caption: "Import"), .init(glyph: .symbol("arrow.triangle.2.circlepath"), caption: "Sync")]),
            ],
            primary: [.init(title: "Push to 3D", symbol: "square.and.arrow.up.on.square", kind: .blue)],
            ribbonTrailing: AnyView(VFSegmented(items: ["Schematic", "PCB", "3D"], selected: 1, height: 34, fontSize: 13).padding(.trailing, 6)),
            rows: [
                .init(indent: 0, disclosure: .open, symbol: "folder", title: "Project", eye: .none, section: true),
                .init(indent: 1, disclosure: .open, symbol: "folder", title: "Schematic", eye: .none),
                .init(indent: 2, disclosure: .closed, symbol: "doc", title: "1 Power"),
                .init(indent: 2, disclosure: .closed, symbol: "doc", title: "2 MCU and Sensors"),
                .init(indent: 2, disclosure: .closed, symbol: "doc", title: "3 ESC Interface"),
                .init(indent: 1, disclosure: .open, symbol: "square.grid.3x3.square", symbolTint: VF.green, title: "Board FC rev C", selected: true),
                .init(indent: 2, disclosure: .open, symbol: "cpu", title: "Components", detail: "41", eye: .none, section: true),
                .init(indent: 3, disclosure: .closed, symbol: "cpu", title: "U1  MCU"),
                .init(indent: 3, disclosure: .closed, symbol: "cpu", title: "U2  IMU"),
                .init(indent: 3, disclosure: .closed, symbol: "cpu", title: "U3  BARO"),
                .init(indent: 3, disclosure: .closed, symbol: "cable.connector", title: "J1  USB"),
                .init(indent: 3, disclosure: .closed, symbol: "cable.connector", title: "J2  ESC"),
                .init(indent: 2, disclosure: .open, symbol: "point.3.connected.trianglepath.dotted", title: "Nets", eye: .none, section: true),
                .init(indent: 3, disclosure: .closed, symbol: "link", title: "VBAT"),
                .init(indent: 3, disclosure: .closed, symbol: "link", title: "GND"),
                .init(indent: 3, disclosure: .closed, symbol: "link", title: "SPI1"),
            ],
            outputs: [
                .init(symbol: "doc.plaintext", title: "Schematic", status: .upToDate),
                .init(symbol: "checkmark.shield", title: "DRC", status: .upToDate),
                .init(symbol: "shippingbox", title: "Manufacture", status: .stale),
                .init(symbol: "cube", title: "3D Sync", status: .running),
            ],
            inspector: AnyView(inspector),
            viewport: AnyView(PCBViewport()),
            bottom: AnyView(LayerBar()),
            bottomHeight: 48,
            status: StatusBar(
                leading: AnyView(HStack(spacing: 8) {
                    Text("ViaForm").fontWeight(.semibold)
                    Text("·").foregroundStyle(VF.secondary)
                    Text("Drone 3in Mk2")
                    Text("·").foregroundStyle(VF.secondary)
                    Text("Electronics")
                }),
                trailing: ["X: 7.42", "Y: 14.86", "mm", "Zoom 100%"],
                trailingDot: ("Ready", .upToDate))
        )
    }

    static var inspector: some View {
        InspectorPanel {
            InspectorSection(title: "Selection", showsDivider: false) {
                SelectionCard(symbol: "square.grid.3x3.square", title: "Board FC rev C", subtitle: "4 layers, 41 parts")
            }
            flowAndLinked(consumes: "Keep-in from Frame #12", produces: "Board body for Design", states: states, current: .electronics)
            InspectorSection(title: "Board") {
                KVRow(label: "Layers", value: "4")
                KVRow(label: "Thickness", value: "1.60", unit: "mm")
                KVRow(label: "Outline", value: "20 x 20", unit: "mm", divider: false)
            }
            InspectorSection(title: "3D link") {
                KVRow(label: "Mounted on", value: "Frame #12")
                KVRow(label: "Height", value: "12.00", unit: "mm", divider: false)
            }
            InspectorSection(title: "Checks") {
                CheckRow(symbol: "checkmark", tint: VF.green, label: "Design rules", value: "0 errors")
                CheckRow(symbol: "exclamationmark.triangle.fill", tint: VF.amber, label: "2 unrouted")
                CheckRow(symbol: "checkmark", tint: VF.green, label: "Fits keep-in")
            }
        }
    }
}

struct PCBViewport: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let k: CGFloat = min(size.height * 0.54, size.width * 0.42) / 20
            let origin = CGPoint(x: size.width * 0.40 - 10 * k, y: size.height * 0.56 - 10 * k)
            ZStack(alignment: .topLeading) {
                Color(hex: 0x141518)
                PCBGrid(k: k, origin: origin)
                PCBBoard(k: k, origin: origin)
                LinkInset().frame(width: 252).padding(16).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

struct PCBGrid: View {
    let k: CGFloat
    let origin: CGPoint
    var body: some View {
        Canvas { ctx, size in
            var x = origin.x.truncatingRemainder(dividingBy: k)
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)), with: .color(.white.opacity(0.035)))
                x += k
            }
            var y = origin.y.truncatingRemainder(dividingBy: k)
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)), with: .color(.white.opacity(0.035)))
                y += k
            }
        }
    }
}

/// 20 x 20 mm flight controller drawn in board millimetres.
struct PCBBoard: View {
    let k: CGFloat
    let origin: CGPoint

    var body: some View {
        Canvas { ctx, _ in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * k, y: origin.y + y * k) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: origin.x + x * k, y: origin.y + y * k, width: w * k, height: h * k) }
            func poly(_ pts: [(CGFloat, CGFloat)], _ c: Color, _ w: CGFloat = 0.16) {
                var path = Path()
                path.addLines(pts.map { p($0.0, $0.1) })
                ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: w * k, lineCap: .round, lineJoin: .round))
            }
            func via(_ x: CGFloat, _ y: CGFloat) {
                ctx.fill(Path(ellipseIn: r(x - 0.32, y - 0.32, 0.64, 0.64)), with: .color(Color(hex: 0xD7B56D)))
                ctx.fill(Path(ellipseIn: r(x - 0.14, y - 0.14, 0.28, 0.28)), with: .color(.black))
            }
            func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: Color = VF.silk, bold: Bool = true, anchor: UnitPoint = .center) {
                ctx.draw(Text(s).font(.system(size: size * k, weight: bold ? .bold : .medium)).foregroundColor(c), at: p(x, y), anchor: anchor)
            }

            // Keep-in from the frame (27 x 27) and the dimension line.
            let keep = Path(r(-3.5, -3.5, 27, 27))
            ctx.stroke(keep, with: .color(VF.accent), style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
            text("Keep-in 27 x 27 from Frame #12", -3.5, -4.3, 0.62, VF.accent, bold: false, anchor: .bottomLeading)
            var dim = Path()
            dim.move(to: p(0, -6.6)); dim.addLine(to: p(20, -6.6))
            dim.move(to: p(0, -7.3)); dim.addLine(to: p(0, -5.9))
            dim.move(to: p(20, -7.3)); dim.addLine(to: p(20, -5.9))
            ctx.stroke(dim, with: .color(VF.accent), lineWidth: 1.4)
            text("20.00", 10, -7.0, 0.7, VF.accent, bold: false, anchor: .bottom)

            // Board and soldermask.
            let board = Path(roundedRect: r(0, 0, 20, 20), cornerRadius: 1.6 * k)
            ctx.fill(board, with: .linearGradient(Gradient(colors: [Color(hex: 0x146B38), Color(hex: 0x0C4A27)]), startPoint: p(0, 0), endPoint: p(20, 20)))
            ctx.stroke(board, with: .color(VF.edge), lineWidth: 2)
            ctx.stroke(Path(roundedRect: r(0.35, 0.35, 19.3, 19.3), cornerRadius: 1.3 * k), with: .color(.white.opacity(0.06)), lineWidth: 1)

            // B.Cu (blue) under F.Cu (red).
            for i in 0..<5 {
                let y = 7.6 + CGFloat(i) * 0.7
                poly([(7.7, y), (5.6, y), (4.2, y - 1.4), (4.2, 3.6 + CGFloat(i) * 0.5)], VF.bCu)
                via(4.2, 3.6 + CGFloat(i) * 0.5)
            }
            for i in 0..<4 {
                let x = 9.0 + CGFloat(i) * 0.7
                poly([(x, 7.4), (x, 5.2), (x + 1.4, 3.8), (12.4, 3.8 - CGFloat(i) * 0.5)], VF.bCu)
            }
            for i in 0..<3 {
                poly([(15.8, 12.4 + CGFloat(i) * 0.6), (17.2, 12.4 + CGFloat(i) * 0.6), (17.8, 11.6 + CGFloat(i) * 0.6)], VF.bCu)
            }
            // F.Cu bundles: MCU to ESC connector, MCU to IMU and BARO, USB.
            for i in 0..<6 {
                let x = 8.2 + CGFloat(i) * 0.65
                poly([(x, 12.6), (x, 14.6), (7.0 + CGFloat(i) * 1.05, 15.9), (7.0 + CGFloat(i) * 1.05, 17.6)], VF.fCu)
            }
            for i in 0..<4 {
                let y = 8.4 + CGFloat(i) * 0.6
                poly([(12.4, y), (13.4, y), (13.4 + CGFloat(i) * 0.1, 7.0)], VF.fCu)
                poly([(12.4, y + 2.6), (13.0, y + 2.6), (13.6, 12.6)], VF.fCu)
            }
            for i in 0..<4 {
                let y = 9.6 + CGFloat(i) * 0.55
                poly([(12.4, y + 0.1), (16.2, y + 0.1), (17.2, y + 0.4), (18.2, y + 0.4)], VF.fCu, 0.2)
            }
            for (x, y) in [(5.0, 5.4), (6.0, 15.4), (15.6, 16.0), (16.6, 6.0), (6.6, 6.4), (3.4, 11.0), (12.6, 15.0), (17.2, 3.4)] as [(CGFloat, CGFloat)] {
                via(x, y)
            }

            // Fine fan-out: short stubs from the MCU pins to vias, both layers.
            for i in 0..<8 {
                let o = 7.7 + CGFloat(i + 1) * 4.7 / 11
                poly([(o, 7.0), (o - 0.2, 6.3)], VF.fCu, 0.11)
                poly([(o, 12.55), (o + 0.25, 13.3)], i % 2 == 0 ? VF.fCu : VF.bCu, 0.11)
            }
            for i in 0..<6 {
                let y = 4.6 + CGFloat(i) * 0.42
                poly([(13.1, y), (11.6, y), (10.9, y - 0.7)], VF.fCu, 0.11)
                poly([(16.7, y), (17.6, y), (18.2, y + 0.6)], VF.bCu, 0.11)
                let y2 = 13.0 + CGFloat(i) * 0.42
                poly([(16.7, y2), (17.2, y2 + 0.3)], VF.fCu, 0.11)
            }
            for i in 0..<5 {
                let x = 2.4 + CGFloat(i) * 0.5
                poly([(x, 9.8), (x, 11.6), (x + 0.6, 12.2)], i % 2 == 0 ? VF.fCu : VF.bCu, 0.11)
            }
            for (x, y) in [(10.9, 3.9), (11.3, 4.2), (18.2, 5.2), (18.4, 7.0), (3.2, 12.4), (4.4, 12.6), (8.0, 6.3), (9.7, 6.3), (11.4, 6.3), (9.0, 13.3), (11.0, 13.3)] as [(CGFloat, CGFloat)] {
                ctx.fill(Path(ellipseIn: r(x - 0.22, y - 0.22, 0.44, 0.44)), with: .color(Color(hex: 0xD7B56D)))
                ctx.fill(Path(ellipseIn: r(x - 0.09, y - 0.09, 0.18, 0.18)), with: .color(.black))
            }

            // Mounting holes.
            for (x, y) in [(2.2, 2.2), (17.8, 2.2), (2.2, 17.8), (17.8, 17.8)] as [(CGFloat, CGFloat)] {
                ctx.fill(Path(ellipseIn: r(x - 1.6, y - 1.6, 3.2, 3.2)), with: .color(Color(hex: 0xD8B25C)))
                ctx.fill(Path(ellipseIn: r(x - 1.05, y - 1.05, 2.1, 2.1)), with: .color(Color(hex: 0x0B0B0C)))
            }

            // Packages.
            func chip(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, pins: Int, _ name: String, _ part: String) {
                let pin = s / CGFloat(pins + 1)
                for i in 1...pins {
                    let o = CGFloat(i) * pin
                    for rr in [r(x + o - 0.1, y - 0.45, 0.2, 0.45), r(x + o - 0.1, y + s, 0.2, 0.45),
                               r(x - 0.45, y + o - 0.1, 0.45, 0.2), r(x + s, y + o - 0.1, 0.45, 0.2)] {
                        ctx.fill(Path(rr), with: .color(Color(hex: 0xC9CCD1)))
                    }
                }
                ctx.fill(Path(roundedRect: r(x, y, s, s), cornerRadius: 0.2 * k), with: .color(Color(hex: 0x1D1E21)))
                ctx.stroke(Path(roundedRect: r(x, y, s, s), cornerRadius: 0.2 * k), with: .color(.white.opacity(0.12)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: r(x + 0.35, y + 0.35, 0.3, 0.3)), with: .color(.white.opacity(0.3)))
                text(name, x + s / 2, y + s / 2 - 0.42, s * 0.16, .white.opacity(0.75), bold: false)
                text(part, x + s / 2, y + s / 2 + 0.42, s * 0.16, .white.opacity(0.75), bold: false)
            }
            chip(7.7, 7.4, 4.7, pins: 10, "U1", "MCU")
            chip(13.5, 4.2, 2.8, pins: 5, "U2", "IMU")
            chip(13.5, 12.6, 2.8, pins: 5, "U3", "BARO")

            // Passives.
            let passives: [(CGFloat, CGFloat, Bool)] = [
                (5.2, 2.0, true), (6.6, 2.0, true), (8.0, 2.0, true), (11.4, 2.0, true), (12.8, 2.0, true),
                (2.0, 5.6, false), (2.0, 7.2, false), (2.0, 8.8, false), (2.0, 12.6, false), (5.8, 6.6, false),
                (6.0, 9.2, false), (6.0, 10.8, false), (13.0, 7.6, true), (17.1, 7.4, false), (17.1, 14.6, false),
                (5.0, 15.6, true), (13.8, 16.6, true), (15.4, 16.6, true), (10.6, 5.6, true), (9.0, 5.6, true),
                (14.4, 2.0, true), (4.6, 4.0, false), (12.8, 11.6, false), (16.8, 10.0, false), (3.6, 17.2, true),
                (14.6, 18.0, true), (16.2, 18.0, true), (6.4, 12.8, true), (11.8, 15.6, true), (2.0, 10.4, false),
            ]
            for (x, y, h) in passives {
                let w: CGFloat = h ? 1.0 : 0.55, hh: CGFloat = h ? 0.55 : 1.0
                ctx.fill(Path(r(x, y, w, hh)), with: .color(Color(hex: 0x5A3E2B)))
                if h {
                    ctx.fill(Path(r(x, y, 0.25, hh)), with: .color(Color(hex: 0xD9DCE0)))
                    ctx.fill(Path(r(x + w - 0.25, y, 0.25, hh)), with: .color(Color(hex: 0xD9DCE0)))
                } else {
                    ctx.fill(Path(r(x, y, w, 0.25)), with: .color(Color(hex: 0xD9DCE0)))
                    ctx.fill(Path(r(x, y + hh - 0.25, w, 0.25)), with: .color(Color(hex: 0xD9DCE0)))
                }
            }
            // J1 USB on the right edge, J2 ESC connector at the bottom.
            ctx.fill(Path(roundedRect: r(18.2, 9.2, 2.4, 3.4), cornerRadius: 0.3 * k), with: .color(Color(hex: 0xBFC3C8)))
            ctx.fill(Path(roundedRect: r(18.9, 9.9, 1.4, 2.0), cornerRadius: 0.2 * k), with: .color(Color(hex: 0x2B2C2F)))
            text("J1", 18.45, 13.15, 0.62); text("USB", 18.45, 13.95, 0.62)
            ctx.fill(Path(roundedRect: r(6.3, 17.4, 7.2, 1.7), cornerRadius: 0.2 * k), with: .color(Color(hex: 0xE8E0C8)))
            for i in 0..<6 {
                ctx.fill(Path(r(6.9 + CGFloat(i) * 1.05, 17.6, 0.45, 1.0)), with: .color(Color(hex: 0xC59A3E)))
            }
            text("J2", 9.9, 19.55, 0.6); text("ESC", 9.9, 20.6, 0.62, VF.text.opacity(0.8), bold: false)

            // Silkscreen.
            text("VIAFORM", 2.2, 13.9, 0.72, anchor: .leading)
            text("FC 20x20", 2.2, 14.8, 0.72, anchor: .leading)
            text("REV C", 2.2, 15.7, 0.72, anchor: .leading)
        }
    }
}

struct LinkInset: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CapsLabel(text: "3D link", color: .white)
                Text("Mounted in Frame #12").font(.system(size: 11.5)).foregroundStyle(VF.accent)
            }
            Art.image("link3d").resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x17181C)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VF.accent.opacity(0.75), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

struct LayerBar: View {
    let layers: [(String, Color, Bool)] = [("F.Cu", VF.fCu, true), ("In1", VF.in1, false), ("In2", VF.in2, false),
                                          ("B.Cu", VF.bCu, true), ("Silk", VF.silk, true), ("Edge", VF.edge, true)]
    var body: some View {
        HStack(spacing: 8) {
            CapsLabel(text: "Layers", color: VF.text.opacity(0.78)).padding(.trailing, 4)
            ForEach(layers, id: \.0) { name, color, on in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(on ? color : color.opacity(0.25)).frame(width: 13, height: 13)
                    Text(name).font(.system(size: 12)).foregroundStyle(on ? VF.text : VF.secondary)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(VF.panel))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.white.opacity(0.16) : VF.hairline))
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                Text("DRC 0 errors").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(VF.green.opacity(0.85)))
        }
        .padding(.horizontal, 12)
    }
}
